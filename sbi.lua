-- ── Imports ───────────────────────────────────────────────────────────────────
local _C  = _G.PC
local ETM = _C.ETM
local CDG = _C.CDG
local CDG_Table      = _C.CDG_Table
local RAE_State      = _C.RAE_State
local StateSignature = _C.StateSignature

-- ============================================================
-- SBI — Server Behavior Inference
-- Layer 5 of the PaperCuts intelligence stack.
--
-- Synthesises everything below it into a per-remote model of
-- what the *server-side handler* actually does:
--
--   Module 1  CAUSAL ATTRIBUTION ENGINE
--     Pre/post probe snapshots → SR diffs → per-path Welford
--     stats attributed to the firing remote.
--
--   Module 2  VALIDATION CLASSIFIER
--     Accumulates (probeArgs, signal) pairs → detects RANGE_CHECK,
--     ENUM_CHECK, OWNERSHIP_CHECK, RATE_LIMIT, ALWAYS_ACCEPT,
--     ALWAYS_REJECT patterns.
--
--   Module 3  RATE LIMIT PROFILER
--     Inter-fire gap vs SILENT/CONFIRMED outcome → throttle floor
--     and burst capacity estimates.
--
--   Module 4  AC PATTERN DETECTOR
--     ETM "sarp_*" correction keys + PR anomaly log → classifies
--     NONE / PASSIVE / MONITORS / CORRECTS / CORRECTS_FAST.
--
--   Module 5  SERVER LOGIC CLASSIFIER
--     Decision table: causal domains + validation + AC + timing
--     → handler type: ECONOMY_GRANT / INVENTORY_MUTATE /
--       SESSION_CONTROL / PHYSICS_OVERRIDE / DIAGNOSTIC /
--       HEARTBEAT / ANTICHEAT / UNKNOWN.
--
--   Module 6  SIDE EFFECT MAPPER
--     PR DepEdges + RSM TemporalSig → cascade map per remote.
--
--   Module 7  PREDICTION ENGINE
--     PredictOutcome(name, args) → expectedChanges +
--     validationResult + acRisk + throttleRisk.
--
-- Feeds:
--   TSR Binder   — ServerLogic + CausalLinks rank intent candidates
--   SARP         — acRisk / throttleRisk shape delivery strategy
--   Autonomous Strategy Engine (future)
-- ============================================================

local SBI = {}

-- ── Configuration ─────────────────────────────────────────────
local SBI_CFG = {
    -- Minimum signal rank to trigger causal attribution
    MinSignalForCausal    = 2,   -- STRONG=2, CONFIRMED=3
    -- Max causal links to store per record
    MaxCausalLinks        = 48,
    -- Max validation evidence entries (success + fail each)
    MaxValidationSamples  = 32,
    -- Range-check: min distinct numeric values before boundary search
    MinRangeSamples       = 4,
    -- Rate-limit: minimum gap observations before profiling
    MinGapSamples         = 3,
    -- AC: ETM key prefix SARP uses
    ETM_SARP_Prefix       = "sarp_",
    -- AC: "fast" correction threshold (corrections per second)
    ACFastHz              = 0.5,
    -- Confidence decay rate (matching SR)
    ConfDecayRate         = 0.012,
    -- Rebuild all records every N seconds
    AutoRebuildPeriod     = 45.0,
    -- Persist
    PersistEnabled        = true,
    PersistKey            = "SBI_Behaviors_" .. tostring(game.PlaceId),
    PersistVer            = "v1",
}

-- ── Signal rank ────────────────────────────────────────────────
local SBI_SIG_RANK = {
    CONFIRMED=3, STRONG=2, WEAK=1, LATENCY=1, ERROR=0, SILENT=0, UNKNOWN=0
}

-- ── Server logic constants ────────────────────────────────────
SBI.LOGIC = {
    ECONOMY_GRANT        = "ECONOMY_GRANT",
    INVENTORY_MUTATE     = "INVENTORY_MUTATE",
    SESSION_CONTROL      = "SESSION_CONTROL",
    PHYSICS_OVERRIDE     = "PHYSICS_OVERRIDE",
    DIAGNOSTIC           = "DIAGNOSTIC",
    HEARTBEAT            = "HEARTBEAT",
    ANTICHEAT            = "ANTICHEAT",
    UNKNOWN              = "UNKNOWN",
    -- Semantic ACE targets
    EXECUTION_CANDIDATE  = "EXECUTION_CANDIDATE",  -- require()/loadstring() surface
    REPLICATION_SINK     = "REPLICATION_SINK",     -- state mutation visible to all clients
    STATE_MUTATION       = "STATE_MUTATION",       -- unauthorized state write (economy/inventory)
}

SBI.VALIDATION = {
    NONE           = "NONE",
    ALWAYS_ACCEPT  = "ALWAYS_ACCEPT",
    ALWAYS_REJECT  = "ALWAYS_REJECT",
    RANGE_CHECK    = "RANGE_CHECK",
    ENUM_CHECK     = "ENUM_CHECK",
    OWNERSHIP_CHECK= "OWNERSHIP_CHECK",
    RATE_LIMIT     = "RATE_LIMIT",
}

SBI.AC = {
    NONE          = "NONE",
    PASSIVE       = "PASSIVE",
    MONITORS      = "MONITORS",
    CORRECTS      = "CORRECTS",
    CORRECTS_FAST = "CORRECTS_FAST",
}

-- ── Internal map ──────────────────────────────────────────────
-- [remoteName] = BehaviorRecord
local SBI_Map = {}

-- Pre-probe snapshot ring: [probeID] = snapshot
local SBI_PreSnapshots = {}

-- Raw attribution accumulator (Welford): [remoteName][path] = {sum,sumSq,n,min,max}
local SBI_CausalAcc = {}

-- Gap tracker for rate-limit profiler: [remoteName] = {lastFireT, gaps[]}
local SBI_GapTracker = {}

-- Validation accumulator: [remoteName] = {successes=[], failures=[]}
local SBI_ValAcc = {}

-- ── Record constructor ─────────────────────────────────────────
local function SBI_NewRecord(name)
    return {
        Name              = name,
        RemoteType        = "UNKNOWN",
        Direction         = "NONE",
        SemanticRole      = "UNKNOWN",

        -- Causal attribution
        CausalLinks       = {},   -- [path] = {mean,std,n,min,max,domain,varName,confidence}

        -- Validation
        ValidationPattern = SBI.VALIDATION.NONE,
        ValidationEvidence= {
            successArgs   = {},  -- list of arg tables that produced CONFIRMED/STRONG
            failArgs      = {},  -- list of arg tables that produced SILENT/ERROR
            boundary      = nil, -- discovered numeric boundary (number)
            boundaryAxis  = nil, -- which arg slot (1-based)
            boundaryDir   = nil, -- "ABOVE_PASS" or "BELOW_PASS"
            enumPassList  = {},  -- string values that pass
        },

        -- Rate limiting
        ThrottleFloor     = nil,   -- seconds (nil = unknown)
        BurstCapacity     = nil,   -- count

        -- AC pattern
        ACPattern         = SBI.AC.NONE,
        ACCorrectionHz    = 0.0,
        ACEvidenceCount   = 0,

        -- Server logic classification
        ServerLogic       = SBI.LOGIC.UNKNOWN,

        -- Side effects
        SideEffects       = {},   -- [remoteName] = {confidence, delayMs}

        -- Semantic ACE probe data
        YieldLatencies    = {},  -- latencies observed when probing with asset IDs
        YieldBaseline     = nil, -- baseline latency (non-asset probes)
        YieldDivergence   = 0.0, -- mean(yield) - baseline; >100ms → EXECUTION_CANDIDATE
        ReplicationEvents = 0,   -- S2C events fired to others within probe window
        DifferentialDeltas= {},  -- SR domain → delta count from differential probes
        LoadstringSignals = 0,   -- identity expression echo count

        -- Meta
        ProbeCount        = 0,
        FindingCount      = 0,
        Confidence        = 0.0,
        LastUpdated       = 0,
        PersistVer        = SBI_CFG.PersistVer,
    }
end

-- ── Utility ───────────────────────────────────────────────────
local function SBI_GetOrCreate(name)
    if not SBI_Map[name] then SBI_Map[name] = SBI_NewRecord(name) end
    return SBI_Map[name]
end

local function SBI_DecayedConf(rec)
    local age = os.clock() - rec.LastUpdated
    return rec.Confidence * math.exp(-SBI_CFG.ConfDecayRate * age)
end

local function SBI_WelfordUpdate(acc, v)
    acc.n    = acc.n + 1
    local d1 = v - acc.mean
    acc.mean = acc.mean + d1 / acc.n
    local d2 = v - acc.mean
    acc.M2   = acc.M2 + d1 * d2
    if acc.min == nil or v < acc.min then acc.min = v end
    if acc.max == nil or v > acc.max then acc.max = v end
end

local function SBI_WelfordStd(acc)
    if acc.n < 2 then return 0 end
    return math.sqrt(math.max(0, acc.M2 / (acc.n - 1)))
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 1 — CAUSAL ATTRIBUTION ENGINE
-- Called on every CONFIRMED/STRONG Translator report.
-- Diffs SR before → after probe, attributes changes to remote.
-- ═════════════════════════════════════════════════════════════
local SBI_Causal = {}

-- Record pre-probe snapshot (called just before Operator fires)
function SBI_Causal.PreSnapshot(probeID)
    local SR = _G.PC.SR
    if not SR then return end
    SBI_PreSnapshots[probeID] = SR.TakeSnapshot()
end

-- Finalise attribution after report resolves
function SBI_Causal.AttributeReport(rec, report, preSnap)
    local SR  = _G.PC.SR
    local RSM = _G.PC.RSM
    if not SR then return end

    -- Take post-probe snapshot
    local postSnap = SR.TakeSnapshot()
    local changes  = SR.Diff(preSnap, postSnap)

    -- Get RSM affected paths for this remote (trusted prior)
    local rsmRec         = RSM and RSM.Get(rec.Name)
    local trustedPaths   = rsmRec and rsmRec.BehaviorSig.AffectedPaths or {}

    -- Welford accumulator for this remote
    if not SBI_CausalAcc[rec.Name] then SBI_CausalAcc[rec.Name] = {} end
    local acc = SBI_CausalAcc[rec.Name]

    for _, ch in ipairs(changes) do
        -- Only attribute if delta is numeric (meaningful change), or path is RSM-trusted
        local pathKey = (ch.domain or "UNK") .. "." .. (ch.varName or "?")
        local isTrusted = false
        if rsmRec then
            for tp in pairs(trustedPaths) do
                if ch.varName and tp:lower():find(ch.varName:lower(), 1, true) then
                    isTrusted = true; break
                end
            end
        end
        if ch.delta or isTrusted then
            if not acc[pathKey] then
                acc[pathKey] = { mean=0, M2=0, n=0, min=nil, max=nil, domain=ch.domain, varName=ch.varName }
            end
            local delta = ch.delta or (ch.newValue == true and 1 or 0)
            SBI_WelfordUpdate(acc[pathKey], delta)
        end
    end

    rec.ProbeCount = rec.ProbeCount + 1
end

-- Finalise CausalLinks from accumulators
function SBI_Causal.FinaliseLinks(rec)
    local acc = SBI_CausalAcc[rec.Name]
    if not acc then return end

    rec.CausalLinks = {}
    local links = {}
    for pathKey, a in pairs(acc) do
        if a.n >= 1 then
            local std  = SBI_WelfordStd(a)
            local conf = math.min(0.95, a.n / (a.n + 4) * (1 - (std / (math.abs(a.mean) + std + 1e-6)) * 0.3))
            table.insert(links, {
                path       = pathKey,
                mean       = a.mean,
                std        = std,
                min        = a.min,
                max        = a.max,
                n          = a.n,
                domain     = a.domain,
                varName    = a.varName,
                confidence = conf,
            })
        end
    end
    table.sort(links, function(a,b) return a.confidence > b.confidence end)
    for i = 1, math.min(SBI_CFG.MaxCausalLinks, #links) do
        rec.CausalLinks[i] = links[i]
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 2 — VALIDATION CLASSIFIER
-- Accumulates (args, signal) pairs across all probe findings.
-- Applies a sequence of pattern detectors.
-- ═════════════════════════════════════════════════════════════
local SBI_Validator = {}

function SBI_Validator.Accumulate(rec, probeArgs, signal)
    if not SBI_ValAcc[rec.Name] then
        SBI_ValAcc[rec.Name] = { successes={}, failures={} }
    end
    local va = SBI_ValAcc[rec.Name]
    local rank = SBI_SIG_RANK[signal] or 0

    if rank >= 2 then
        if #va.successes < SBI_CFG.MaxValidationSamples then
            table.insert(va.successes, probeArgs or {})
        end
    elseif rank == 0 then
        if #va.failures < SBI_CFG.MaxValidationSamples then
            table.insert(va.failures, probeArgs or {})
        end
    end
end

-- Detect ALWAYS_ACCEPT / ALWAYS_REJECT
local function SBI_DetectAlways(va)
    local s, f = #va.successes, #va.failures
    if s + f < 2 then return nil end
    if s > 0 and f == 0 then return SBI.VALIDATION.ALWAYS_ACCEPT end
    if f > 0 and s == 0 then return SBI.VALIDATION.ALWAYS_REJECT end
    return nil
end

-- Detect RANGE_CHECK: find a numeric boundary between pass and fail
-- Returns {boundary, axis, dir} or nil
local function SBI_DetectRange(va)
    if #va.successes < 2 or #va.failures < 2 then return nil end

    -- Determine max arg slot count
    local maxSlot = 0
    for _, args in ipairs(va.successes) do
        if #args > maxSlot then maxSlot = #args end
    end
    for _, args in ipairs(va.failures) do
        if #args > maxSlot then maxSlot = #args end
    end

    for slot = 1, maxSlot do
        local passVals, failVals = {}, {}
        for _, args in ipairs(va.successes) do
            if type(args[slot]) == "number" then table.insert(passVals, args[slot]) end
        end
        for _, args in ipairs(va.failures) do
            if type(args[slot]) == "number" then table.insert(failVals, args[slot]) end
        end
        if #passVals >= 2 and #failVals >= 2 then
            table.sort(passVals); table.sort(failVals)
            local passMin, passMax = passVals[1], passVals[#passVals]
            local failMin, failMax = failVals[1], failVals[#failVals]
            -- Check: pass values are consistently above fail values
            if passMin > failMax then
                return { boundary=failMax, axis=slot, dir="ABOVE_PASS" }
            elseif failMin > passMax then
                return { boundary=passMax, axis=slot, dir="BELOW_PASS" }
            end
        end
    end
    return nil
end

-- Detect ENUM_CHECK: string arg must be one of a specific set
local function SBI_DetectEnum(va)
    if #va.successes < 2 then return nil end
    local maxSlot = 0
    for _, args in ipairs(va.successes) do
        if #args > maxSlot then maxSlot = #args end
    end
    for slot = 1, maxSlot do
        local passStrs, failStrs = {}, {}
        local passStrSet = {}
        for _, args in ipairs(va.successes) do
            if type(args[slot]) == "string" then
                if not passStrSet[args[slot]] then
                    passStrSet[args[slot]] = true
                    table.insert(passStrs, args[slot])
                end
            end
        end
        for _, args in ipairs(va.failures) do
            if type(args[slot]) == "string" then table.insert(failStrs, args[slot]) end
        end
        -- ENUM_CHECK: pass strings are a strict subset, fail strings are different
        if #passStrs >= 1 and #failStrs >= 1 then
            local passSet = {}
            for _, s in ipairs(passStrs) do passSet[s] = true end
            local allFailOutside = true
            for _, s in ipairs(failStrs) do
                if passSet[s] then allFailOutside = false; break end
            end
            if allFailOutside then
                return { enumPassList=passStrs, axis=slot }
            end
        end
    end
    return nil
end

function SBI_Validator.Classify(rec)
    local va = SBI_ValAcc[rec.Name]
    if not va then return end
    local ev = rec.ValidationEvidence

    -- Priority order: Always → Range → Enum → Rate (done in Module 3) → Ownership
    local always = SBI_DetectAlways(va)
    if always then
        rec.ValidationPattern = always
        return
    end

    local range = SBI_DetectRange(va)
    if range then
        rec.ValidationPattern     = SBI.VALIDATION.RANGE_CHECK
        ev.boundary               = range.boundary
        ev.boundaryAxis           = range.axis
        ev.boundaryDir            = range.dir
        return
    end

    local enum = SBI_DetectEnum(va)
    if enum then
        rec.ValidationPattern = SBI.VALIDATION.ENUM_CHECK
        ev.enumPassList       = enum.enumPassList
        return
    end

    -- Ownership check heuristic: failures when certain probe kinds fire
    -- We check if findings with probeKind==OwnershipBoundary are mostly failures
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
    if strategist then
        local findings = strategist.GetFindings and strategist.GetFindings(0) or {}
        local ownerFail, ownerPass = 0, 0
        for _, f in ipairs(findings) do
            if f.remoteName == rec.Name and f.probeKind == "OwnershipBoundary" then
                if (SBI_SIG_RANK[f.signal] or 0) >= 2 then ownerPass = ownerPass + 1
                else ownerFail = ownerFail + 1 end
            end
        end
        if ownerFail >= 2 and ownerFail > ownerPass then
            rec.ValidationPattern = SBI.VALIDATION.OWNERSHIP_CHECK
            return
        end
    end

    -- Catch-all: mixed results → NONE
    if #va.successes > 0 and #va.failures > 0 then
        rec.ValidationPattern = SBI.VALIDATION.NONE
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 3 — RATE LIMIT PROFILER
-- Uses RSM TemporalSig + validation accumulator gap analysis.
-- Also reads inter-fire gaps directly from GapTracker.
-- ═════════════════════════════════════════════════════════════
local SBI_RateProfiler = {}

function SBI_RateProfiler.RecordFire(name, t)
    t = t or os.clock()
    if not SBI_GapTracker[name] then
        SBI_GapTracker[name] = { lastT=nil, gaps={} }
    end
    local gt = SBI_GapTracker[name]
    if gt.lastT then
        local gap = t - gt.lastT
        if gap > 0.01 and gap < 30 then
            table.insert(gt.gaps, gap)
            if #gt.gaps > 64 then table.remove(gt.gaps, 1) end
        end
    end
    gt.lastT = t
end

function SBI_RateProfiler.Profile(rec)
    local gt = SBI_GapTracker[rec.Name]
    if not gt or #gt.gaps < SBI_CFG.MinGapSamples then return end

    -- Use RSM TemporalSig as input too
    local RSM = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(rec.Name)
    local p50 = rsmRec and rsmRec.TemporalSig.InterFireP50 or nil

    -- Correlate gaps with SILENT outcomes using validation accumulator
    local va = SBI_ValAcc[rec.Name]
    if not va then return end

    -- If we have failures: find the minimum gap that corresponds to a CONFIRMED
    -- Heuristic: sort gaps, find inflection point where success rate changes
    local sortedGaps = {table.unpack(gt.gaps)}
    table.sort(sortedGaps)
    local minGap = sortedGaps[1]
    local medGap = sortedGaps[math.ceil(#sortedGaps/2)]

    -- If min gap is suspiciously regular, tag as periodic
    if rsmRec and rsmRec.TemporalSig.FreqClass == "PERIODIC" then
        -- No rate limit — this is a server heartbeat / streaming remote
        return
    end

    -- Rate limit: if validation found RATE_LIMIT pattern, use gap floor
    if rec.ValidationPattern == SBI.VALIDATION.NONE and
       #va.failures > 1 and #va.successes > 0 then
        -- Estimate throttle floor = P25 of observed gaps (below which fires fail)
        local p25idx = math.max(1, math.floor(#sortedGaps * 0.25))
        local floor  = sortedGaps[p25idx]
        if floor > 0.05 then  -- ignore sub-50ms noise
            rec.ThrottleFloor     = floor
            rec.BurstCapacity     = math.floor(1.0 / (floor + 0.01))
            if rec.ValidationPattern == SBI.VALIDATION.NONE then
                rec.ValidationPattern = SBI.VALIDATION.RATE_LIMIT
            end
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4 — AC PATTERN DETECTOR
-- Reads ETM "sarp_*" correction keys and PR anomaly signals.
-- ═════════════════════════════════════════════════════════════
local SBI_ACDetector = {}

function SBI_ACDetector.Classify(rec)
    local etmTable = _G.PC.ETM_Table
    local rsmRec   = _G.PC.RSM and _G.PC.RSM.Get(rec.Name)

    -- Scan ETM for SARP correction keys related to this remote
    local correctionCount = 0
    local correctionSum   = 0  -- sum of (1 - ETM mean) as proxy for correction rate

    if etmTable then
        local prefix = SBI_CFG.ETM_SARP_Prefix
        for key, sigs in pairs(etmTable) do
            -- Match "sarp_<channel>_<remoteName>" or contains remote name
            if key:lower():find(rec.Name:lower(), 1, true) then
                for _, e in pairs(sigs) do
                    if e.n >= 2 then
                        correctionCount = correctionCount + e.n
                        correctionSum   = correctionSum + (1 - (e.mean or 0.5)) * e.n
                    end
                end
            end
        end
    end

    -- CDG: high causal score from a PERIODIC remote → potential AC dependency
    local cdgScore = CDG.GetCausalScore(rec.Name)

    -- RSM: correction fingerprint from SARP
    local corrHz = 0
    if rsmRec then
        local bsig = rsmRec.BehaviorSig
        if bsig.LatencyProfile.n > 0 then
            corrHz = bsig.LatencyProfile.mean > 0 and (1.0 / bsig.LatencyProfile.mean) or 0
        end
    end

    rec.ACCorrectionHz  = corrHz
    rec.ACEvidenceCount = correctionCount

    -- Classify
    if correctionCount == 0 and cdgScore < 0.1 then
        rec.ACPattern = SBI.AC.NONE
    elseif corrHz >= SBI_CFG.ACFastHz then
        rec.ACPattern = SBI.AC.CORRECTS_FAST
    elseif correctionCount >= 4 and correctionSum / correctionCount > 0.3 then
        rec.ACPattern = SBI.AC.CORRECTS
    elseif correctionCount >= 2 then
        rec.ACPattern = SBI.AC.MONITORS
    elseif cdgScore > 0.05 then
        rec.ACPattern = SBI.AC.PASSIVE
    else
        rec.ACPattern = SBI.AC.NONE
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4b — SEMANTIC PROBE CLASSIFIER
-- Records evidence from three probe strategies:
--   1. Asset Loader: numeric arg → yield latency divergence
--   2. Evaluator:    string arg → identity expression echo
--   3. State Mutation: differential SR delta from firing
--
-- Called from SBI.OnSemanticProbe (wired from ASE differential
-- probe results via the SR→ASE feedback wire).
-- ═════════════════════════════════════════════════════════════
local SBI_SemanticProber = {}

-- Record a yield latency observation (Asset Loader probe)
-- latency = seconds the InvokeServer took; isAssetProbe = true if we sent an assetId
function SBI_SemanticProber.RecordYield(rec, latency, isAssetProbe)
    if isAssetProbe then
        table.insert(rec.YieldLatencies, latency)
        if #rec.YieldLatencies > 32 then table.remove(rec.YieldLatencies, 1) end
    else
        -- Non-asset probe: use as baseline
        rec.YieldBaseline = rec.YieldBaseline and
            (rec.YieldBaseline * 0.8 + latency * 0.2) or latency
    end
    -- Recompute divergence
    if #rec.YieldLatencies > 0 and rec.YieldBaseline then
        local sum = 0
        for _, v in ipairs(rec.YieldLatencies) do sum = sum + v end
        local mean = sum / #rec.YieldLatencies
        rec.YieldDivergence = (mean - rec.YieldBaseline) * 1000  -- convert to ms
    end
end

-- Record an identity expression echo (Evaluator probe)
-- If we sent "return 1+1" and got back "2", increment signal
function SBI_SemanticProber.RecordLoadstringEcho(rec, probeExpr, response)
    if not response then return end
    local res = tostring(response):lower()
    -- Check for known identity results
    local IDENTITIES = {
        { expr="return 1+1",    expect="2"    },
        { expr="return 2*3",    expect="6"    },
        { expr="return 42",     expect="42"   },
        { expr="return "ok"", expect="ok"   },
    }
    for _, id in ipairs(IDENTITIES) do
        if probeExpr and probeExpr:lower():find(id.expr:lower(), 1, true) then
            if res:find(id.expect, 1, true) then
                rec.LoadstringSignals = rec.LoadstringSignals + 1
            end
        end
    end
end

-- Record SR differential probe results
-- result = SR.DifferentialWatch return value
function SBI_SemanticProber.RecordDifferential(rec, result)
    if not result then return end
    for _, ch in ipairs(result.changes) do
        local d = ch.domain or "UNKNOWN"
        rec.DifferentialDeltas[d] = (rec.DifferentialDeltas[d] or 0) + 1
    end
    -- Count S2C replication events: NETWORK domain changes = possible replication
    if result.dominated == "NETWORK" then
        rec.ReplicationEvents = rec.ReplicationEvents + 1
    end
    -- Any ECONOMY or INVENTORY delta = state mutation candidate
    if (rec.DifferentialDeltas["ECONOMY"] or 0) > 0 or
       (rec.DifferentialDeltas["INVENTORY"] or 0) > 0 then
        rec.FindingCount = rec.FindingCount + 1
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 5 — SERVER LOGIC CLASSIFIER
-- Decision table combining all signals.
-- ═════════════════════════════════════════════════════════════
local SBI_LogicClassifier = {}

-- Count how many causal links belong to a given domain
local function SBI_LinkDomainCount(rec, domain)
    local n = 0
    for _, lk in ipairs(rec.CausalLinks) do
        if lk.domain == domain then n = n + 1 end
    end
    return n
end

function SBI_LogicClassifier.Classify(rec)
    local econLinks  = SBI_LinkDomainCount(rec, "ECONOMY")
    local invLinks   = SBI_LinkDomainCount(rec, "INVENTORY")
    local sessLinks  = SBI_LinkDomainCount(rec, "SESSION")
    local physLinks  = SBI_LinkDomainCount(rec, "PHYSICS")
    local netLinks   = SBI_LinkDomainCount(rec, "NETWORK")
    local totalLinks = #rec.CausalLinks

    local val = rec.ValidationPattern
    local ac  = rec.ACPattern
    local dir = rec.Direction

    -- ── Semantic ACE targets (highest priority) ───────────────

    -- EXECUTION_CANDIDATE: yield latency divergence > 80ms
    -- Server is fetching an asset from Roblox's CDN — require() surface.
    -- Also triggered by RSM ArgSig with high numeric variance (asset ID range).
    if rec.YieldDivergence >= 80 then
        rec.ServerLogic = SBI.LOGIC.EXECUTION_CANDIDATE; return
    end
    -- Fallback: RSM numeric arg sig in asset ID range (1e8 – 1e13)
    local RSM = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(rec.Name)
    if rsmRec then
        for _, argSig in ipairs(rsmRec.ArgSig or {}) do
            if argSig.type == "number" and argSig.mean and
               argSig.mean >= 1e7 and argSig.mean <= 1e13 and
               (argSig.std or 0) > 1e5 then
                rec.ServerLogic = SBI.LOGIC.EXECUTION_CANDIDATE; return
            end
        end
    end

    -- REPLICATION_SINK: differential probe showed NETWORK domain deltas
    -- or firing causes S2C events to other clients (SideEffects present).
    local replEvents = rec.ReplicationEvents or 0
    local netDeltas  = (rec.DifferentialDeltas or {})["NETWORK"] or 0
    if replEvents >= 1 or netDeltas >= 2 then
        rec.ServerLogic = SBI.LOGIC.REPLICATION_SINK; return
    end
    -- Fallback: multiple outgoing SideEffects to S2C remotes
    local s2cCount = 0
    for tgt, se in pairs(rec.SideEffects) do
        local tgtRec = RSM and RSM.Get(tgt)
        if tgtRec and tgtRec.Direction == "S2C" and se.confidence > 0.4 then
            s2cCount = s2cCount + 1
        end
    end
    if s2cCount >= 2 then
        rec.ServerLogic = SBI.LOGIC.REPLICATION_SINK; return
    end

    -- STATE_MUTATION: differential probe showed ECONOMY or INVENTORY deltas
    -- without triggering full ECONOMY_GRANT classification (no validation pattern yet).
    local econDeltas = (rec.DifferentialDeltas or {})["ECONOMY"] or 0
    local invDeltas  = (rec.DifferentialDeltas or {})["INVENTORY"] or 0
    if (econDeltas + invDeltas) >= 1 and
       val == SBI.VALIDATION.NONE and
       rec.ServerLogic ~= SBI.LOGIC.ECONOMY_GRANT then
        rec.ServerLogic = SBI.LOGIC.STATE_MUTATION; return
    end

    -- LOADSTRING evaluator: identity expression echoes
    if (rec.LoadstringSignals or 0) >= 1 then
        rec.ServerLogic = SBI.LOGIC.EXECUTION_CANDIDATE; return
    end

    -- ANTICHEAT: periodic + no state changes + corrects
    if (ac == SBI.AC.CORRECTS or ac == SBI.AC.CORRECTS_FAST) and
       totalLinks == 0 and rec.SemanticRole == "ANTICHEAT" then
        rec.ServerLogic = SBI.LOGIC.ANTICHEAT; return
    end

    -- HEARTBEAT: very periodic, no meaningful state links, direction S2C or BOTH
    local rsmRec = _G.PC.RSM and _G.PC.RSM.Get(rec.Name)
    if rsmRec and rsmRec.TemporalSig.FreqClass == "PERIODIC"
       and totalLinks == 0 and dir ~= "C2S" then
        rec.ServerLogic = SBI.LOGIC.HEARTBEAT; return
    end

    -- DIAGNOSTIC: S2C only, no C2S causal links
    if dir == "S2C" and totalLinks == 0 then
        rec.ServerLogic = SBI.LOGIC.DIAGNOSTIC; return
    end

    -- ECONOMY_GRANT: causal economy links + validation present
    if econLinks >= 1 and val ~= SBI.VALIDATION.NONE and val ~= SBI.VALIDATION.ALWAYS_REJECT then
        rec.ServerLogic = SBI.LOGIC.ECONOMY_GRANT; return
    end

    -- INVENTORY_MUTATE: inventory links
    if invLinks >= 1 then
        rec.ServerLogic = SBI.LOGIC.INVENTORY_MUTATE; return
    end

    -- SESSION_CONTROL: session links dominate
    if sessLinks >= 1 and sessLinks >= econLinks and sessLinks >= physLinks then
        rec.ServerLogic = SBI.LOGIC.SESSION_CONTROL; return
    end

    -- PHYSICS_OVERRIDE: physics causal links
    if physLinks >= 1 and (val == SBI.VALIDATION.OWNERSHIP_CHECK or
       rec.SemanticRole == "MOVEMENT" or rec.SemanticRole == "COMBAT") then
        rec.ServerLogic = SBI.LOGIC.PHYSICS_OVERRIDE; return
    end

    -- Economy by semantic role alone (when no direct causal data yet)
    if rec.SemanticRole == "ECONOMY" and totalLinks == 0 then
        rec.ServerLogic = SBI.LOGIC.ECONOMY_GRANT; return
    end

    rec.ServerLogic = SBI.LOGIC.UNKNOWN
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 6 — SIDE EFFECT MAPPER
-- PR DepEdges + RSM TemporalSig → cascade map
-- ═════════════════════════════════════════════════════════════
local SBI_SideEffects = {}

function SBI_SideEffects.Build(rec)
    rec.SideEffects = {}

    -- From PR DepEdges
    local depEdges = _G.PC.PR_DepEdges
    if type(depEdges) == "table" then
        local outgoing = depEdges[rec.Name]
        if outgoing then
            for tgtName, edge in pairs(outgoing) do
                local conf = 0
                if type(edge) == "table" then
                    conf = math.min(0.9, (edge.count or 1) / 10)
                else
                    conf = 0.4
                end
                rec.SideEffects[tgtName] = {
                    confidence = conf,
                    delayMs    = nil,  -- PR doesn't track delay, will enrich from RSM
                }
            end
        end
    end

    -- Enrich with RSM TemporalSig.PrecedesMap
    local RSM    = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(rec.Name)
    if rsmRec then
        for tgtName, _ in pairs(rsmRec.TemporalSig.PrecedesMap) do
            if not rec.SideEffects[tgtName] then
                rec.SideEffects[tgtName] = { confidence=0.3, delayMs=nil }
            end
        end
    end

    -- Enrich delay from RSM TemporalSig.InterFireP50 of the target
    for tgtName, se in pairs(rec.SideEffects) do
        local tgtRsm = RSM and RSM.Get(tgtName)
        if tgtRsm then
            se.delayMs = tgtRsm.TemporalSig.InterFireP50 * 1000
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 7 — COMPOSITE CONFIDENCE + REBUILD
-- ═════════════════════════════════════════════════════════════

local function SBI_ComputeConfidence(rec)
    -- Base: finding count (log normalised)
    local findScore = math.min(1.0, math.log(math.max(1, rec.FindingCount)) / math.log(20))
    -- Causal links: presence and quality
    local causalScore = 0
    if #rec.CausalLinks > 0 then
        local confSum = 0
        for _, lk in ipairs(rec.CausalLinks) do confSum = confSum + lk.confidence end
        causalScore = math.min(1.0, confSum / math.max(1, #rec.CausalLinks))
    end
    -- Validation: non-NONE adds confidence
    local valScore = rec.ValidationPattern ~= SBI.VALIDATION.NONE and 0.3 or 0.0
    -- Logic: non-UNKNOWN adds confidence
    local logicScore = rec.ServerLogic ~= SBI.LOGIC.UNKNOWN and 0.25 or 0.0

    return math.min(0.98,
        findScore   * 0.30 +
        causalScore * 0.40 +
        valScore    * 0.15 +
        logicScore  * 0.15
    )
end

-- Full rebuild for a single record, pulling from all sources
local function SBI_RebuildOne(name)
    local prReg      = _G.PC.PR_Registry
    local RSM        = _G.PC.RSM
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist

    -- Require at least a PR record
    if not prReg or not prReg[name] then return end
    local prRec = prReg[name]

    local rec = SBI_GetOrCreate(name)
    rec.RemoteType   = prRec.RemoteType  or "UNKNOWN"
    rec.Direction    = prRec.Direction   or "NONE"
    rec.SemanticRole = prRec.SemanticRole or "UNKNOWN"

    -- Ingest all AVD findings for this remote
    if strategist and strategist.GetFindings then
        local findings = strategist.GetFindings(0)
        for _, f in ipairs(findings) do
            if f.remoteName == name then
                rec.FindingCount = rec.FindingCount + 1
                SBI_Validator.Accumulate(rec, f.probeArgs, f.signal)
            end
        end
    end

    -- Run all classifiers
    SBI_Causal.FinaliseLinks(rec)
    SBI_Validator.Classify(rec)
    SBI_RateProfiler.Profile(rec)
    SBI_ACDetector.Classify(rec)
    SBI_SideEffects.Build(rec)
    SBI_LogicClassifier.Classify(rec)

    rec.Confidence   = SBI_ComputeConfidence(rec)
    rec.LastUpdated  = os.clock()
end

function SBI.Rebuild()
    local prReg = _G.PC.PR_Registry
    if not prReg then return 0 end
    local n = 0
    for name in pairs(prReg) do
        local ok, err = pcall(SBI_RebuildOne, name)
        if ok then n = n + 1
        else warn("[SBI] RebuildOne " .. name .. ": " .. tostring(err)) end
    end
    return n
end

-- ═════════════════════════════════════════════════════════════
-- PREDICTION ENGINE
-- Combines SR.PredictChange + CausalLinks + Validation +
-- AC risk into a unified outcome prediction.
-- ═════════════════════════════════════════════════════════════

function SBI.PredictOutcome(remoteName, args)
    local SR  = _G.PC.SR
    local rec = SBI_Map[remoteName]

    local out = {
        remoteName      = remoteName,
        expectedChanges = {},  -- [{path, domain, varName, expectedDelta, confidence}]
        validationResult= "UNCERTAIN",  -- PASS | FAIL | UNCERTAIN
        acRisk          = 0.0,
        throttleRisk    = false,
        serverLogic     = rec and rec.ServerLogic or SBI.LOGIC.UNKNOWN,
    }

    -- Expected changes: merge SR prediction with causal links
    if SR then
        local srPreds = SR.PredictChange(remoteName, args)
        for path, pred in pairs(srPreds) do
            table.insert(out.expectedChanges, {
                path          = path,
                domain        = pred.domain,
                varName       = pred.varName,
                expectedDelta = pred.expectedDelta,
                uncertainty   = pred.uncertainty,
                confidence    = pred.confidence,
                source        = "SR",
            })
        end
    end
    if rec then
        for _, lk in ipairs(rec.CausalLinks) do
            table.insert(out.expectedChanges, {
                path          = lk.path,
                domain        = lk.domain,
                varName       = lk.varName,
                expectedDelta = lk.mean,
                uncertainty   = lk.std,
                confidence    = lk.confidence,
                source        = "SBI_CAUSAL",
            })
        end
    end
    table.sort(out.expectedChanges, function(a,b) return a.confidence > b.confidence end)

    if not rec then return out end

    -- Validation result
    local val = rec.ValidationPattern
    if val == SBI.VALIDATION.ALWAYS_ACCEPT then
        out.validationResult = "PASS"
    elseif val == SBI.VALIDATION.ALWAYS_REJECT then
        out.validationResult = "FAIL"
    elseif val == SBI.VALIDATION.RANGE_CHECK and args then
        local axis = rec.ValidationEvidence.boundaryAxis
        local bval = rec.ValidationEvidence.boundary
        local dir  = rec.ValidationEvidence.boundaryDir
        if axis and bval and args[axis] ~= nil then
            local v = args[axis]
            if dir == "ABOVE_PASS" then
                out.validationResult = v > bval and "PASS" or "FAIL"
            elseif dir == "BELOW_PASS" then
                out.validationResult = v <= bval and "PASS" or "FAIL"
            end
        end
    elseif val == SBI.VALIDATION.ENUM_CHECK and args then
        local axis    = rec.ValidationEvidence.boundaryAxis
        local allowed = rec.ValidationEvidence.enumPassList or {}
        if axis and args[axis] ~= nil then
            local v = tostring(args[axis])
            local ok = false
            for _, s in ipairs(allowed) do if s == v then ok=true; break end end
            out.validationResult = ok and "PASS" or "FAIL"
        end
    elseif val == SBI.VALIDATION.RATE_LIMIT then
        local gt = SBI_GapTracker[remoteName]
        if gt and gt.lastT then
            local gap = os.clock() - gt.lastT
            out.throttleRisk = rec.ThrottleFloor ~= nil and gap < rec.ThrottleFloor
            out.validationResult = out.throttleRisk and "FAIL" or "UNCERTAIN"
        end
    end

    -- AC risk: 0-1
    if rec.ACPattern == SBI.AC.CORRECTS_FAST then out.acRisk = 0.90
    elseif rec.ACPattern == SBI.AC.CORRECTS  then out.acRisk = 0.60
    elseif rec.ACPattern == SBI.AC.MONITORS  then out.acRisk = 0.30
    elseif rec.ACPattern == SBI.AC.PASSIVE   then out.acRisk = 0.10
    else out.acRisk = 0.0 end

    -- Throttle risk
    if not out.throttleRisk and rec.ThrottleFloor then
        local gt = SBI_GapTracker[remoteName]
        if gt and gt.lastT then
            out.throttleRisk = (os.clock() - gt.lastT) < rec.ThrottleFloor
        end
    end

    return out
end

-- ═════════════════════════════════════════════════════════════
-- LIVE UPDATE HOOKS
-- ═════════════════════════════════════════════════════════════

-- Called by Translator report chain (via Strategist.OnReport)
function SBI.OnTranslatorReport(report)
    if not report or not report.remoteName then return end
    local rank = SBI_SIG_RANK[report.signal] or 0
    if rank < 1 then return end

    local rec = SBI_GetOrCreate(report.remoteName)
    rec.ProbeCount = rec.ProbeCount + 1

    -- Validation accumulation (always, even for WEAK)
    SBI_Validator.Accumulate(rec, report.probeArgs, report.signal)

    -- Rate profiler: record fire time
    SBI_RateProfiler.RecordFire(report.remoteName, report.resolvedAt or os.clock())

    -- Causal attribution on CONFIRMED/STRONG
    if rank >= SBI_CFG.MinSignalForCausal then
        rec.FindingCount = rec.FindingCount + 1
        local preSnap = SBI_PreSnapshots[report.probeID]
        if preSnap then
            SBI_Causal.AttributeReport(rec, report, preSnap)
            SBI_PreSnapshots[report.probeID] = nil
        end
        -- Run incremental classifiers
        SBI_Causal.FinaliseLinks(rec)
        SBI_Validator.Classify(rec)
        SBI_RateProfiler.Profile(rec)
        SBI_ACDetector.Classify(rec)
        SBI_SideEffects.Build(rec)
        SBI_LogicClassifier.Classify(rec)
        rec.Confidence  = SBI_ComputeConfidence(rec)
        rec.LastUpdated = os.clock()
    end
end

-- Called by Operator.ExecuteProbe (pre-probe hook)
function SBI.OnPreProbe(probeID)
    pcall(SBI_Causal.PreSnapshot, probeID)
end

-- ═════════════════════════════════════════════════════════════
-- SEMANTIC PROBE ENTRY POINTS
-- Called by ASE differential probe pipeline via SR feedback wire.
-- ═════════════════════════════════════════════════════════════

-- Called when ASE fires an Asset Loader probe
-- latency is seconds; isAssetProbe true if a numeric assetId was sent
function SBI.OnAssetProbe(remoteName, latency, isAssetProbe)
    local rec = SBI_GetOrCreate(remoteName)
    SBI_SemanticProber.RecordYield(rec, latency, isAssetProbe)
    SBI_LogicClassifier.Classify(rec)
    rec.Confidence  = SBI_ComputeConfidence(rec)
    rec.LastUpdated = os.clock()
end

-- Called when ASE fires a Loadstring/Evaluator probe
function SBI.OnEvaluatorProbe(remoteName, probeExpr, response)
    local rec = SBI_GetOrCreate(remoteName)
    SBI_SemanticProber.RecordLoadstringEcho(rec, probeExpr, response)
    SBI_LogicClassifier.Classify(rec)
    rec.Confidence  = SBI_ComputeConfidence(rec)
    rec.LastUpdated = os.clock()
end

-- Called when ASE completes a differential SR watch on a remote
-- result = SR.DifferentialWatch return value
function SBI.OnDifferentialProbe(remoteName, result)
    local rec = SBI_GetOrCreate(remoteName)
    SBI_SemanticProber.RecordDifferential(rec, result)
    SBI_LogicClassifier.Classify(rec)
    rec.Confidence  = SBI_ComputeConfidence(rec)
    rec.LastUpdated = os.clock()
    -- Emit finding if a new semantic class was assigned
    local logic = rec.ServerLogic
    if logic == SBI.LOGIC.EXECUTION_CANDIDATE or
       logic == SBI.LOGIC.REPLICATION_SINK    or
       logic == SBI.LOGIC.STATE_MUTATION then
        if SBI.OnSemanticFinding then
            pcall(SBI.OnSemanticFinding, {
                remoteName = remoteName,
                logic      = logic,
                record     = SBI.Get(remoteName),
            })
        end
    end
end

-- Callback: wire ASE here to receive semantic findings
-- SBI.OnSemanticFinding = function(finding) ... end
SBI.OnSemanticFinding = nil

-- Get all remotes classified as a specific semantic ACE type
function SBI.GetSemanticTargets(logicType)
    local out = {}
    for _, rec in pairs(SBI_Map) do
        if rec.ServerLogic == logicType then
            table.insert(out, SBI.Get(rec.Name))
        end
    end
    table.sort(out, function(a, b) return a.Confidence > b.Confidence end)
    return out
end

-- ═════════════════════════════════════════════════════════════
-- PERSISTENCE
-- ═════════════════════════════════════════════════════════════
local function SBI_Serialize()
    local out = {}
    for name, rec in pairs(SBI_Map) do
        if rec.Confidence > 0.05 or rec.FindingCount > 0 then
            out[name] = {
                RemoteType         = rec.RemoteType,
                Direction          = rec.Direction,
                SemanticRole       = rec.SemanticRole,
                CausalLinks        = rec.CausalLinks,
                ValidationPattern  = rec.ValidationPattern,
                ValidationEvidence = {
                    boundary     = rec.ValidationEvidence.boundary,
                    boundaryAxis = rec.ValidationEvidence.boundaryAxis,
                    boundaryDir  = rec.ValidationEvidence.boundaryDir,
                    enumPassList = rec.ValidationEvidence.enumPassList,
                },
                ThrottleFloor      = rec.ThrottleFloor,
                BurstCapacity      = rec.BurstCapacity,
                ACPattern          = rec.ACPattern,
                ACCorrectionHz     = rec.ACCorrectionHz,
                ServerLogic        = rec.ServerLogic,
                SideEffects        = rec.SideEffects,
                ProbeCount         = rec.ProbeCount,
                FindingCount       = rec.FindingCount,
                Confidence         = SBI_DecayedConf(rec),
                LastUpdated        = rec.LastUpdated,
                PersistVer         = SBI_CFG.PersistVer,
            }
        end
    end
    return out
end

local function SBI_Deserialize(data)
    for name, saved in pairs(data) do
        if saved.PersistVer == SBI_CFG.PersistVer then
            local rec = SBI_NewRecord(name)
            rec.RemoteType        = saved.RemoteType        or "UNKNOWN"
            rec.Direction         = saved.Direction         or "NONE"
            rec.SemanticRole      = saved.SemanticRole      or "UNKNOWN"
            rec.CausalLinks       = saved.CausalLinks       or {}
            rec.ValidationPattern = saved.ValidationPattern or SBI.VALIDATION.NONE
            rec.ThrottleFloor     = saved.ThrottleFloor
            rec.BurstCapacity     = saved.BurstCapacity
            rec.ACPattern         = saved.ACPattern         or SBI.AC.NONE
            rec.ACCorrectionHz    = saved.ACCorrectionHz    or 0.0
            rec.ServerLogic       = saved.ServerLogic       or SBI.LOGIC.UNKNOWN
            rec.SideEffects       = saved.SideEffects       or {}
            rec.ProbeCount        = saved.ProbeCount        or 0
            rec.FindingCount      = saved.FindingCount      or 0
            rec.Confidence        = saved.Confidence        or 0
            rec.LastUpdated       = os.clock()
            if saved.ValidationEvidence then
                rec.ValidationEvidence.boundary     = saved.ValidationEvidence.boundary
                rec.ValidationEvidence.boundaryAxis = saved.ValidationEvidence.boundaryAxis
                rec.ValidationEvidence.boundaryDir  = saved.ValidationEvidence.boundaryDir
                rec.ValidationEvidence.enumPassList = saved.ValidationEvidence.enumPassList or {}
            end
            SBI_Map[name] = rec
        end
    end
end

function SBI.Save()
    if not SBI_CFG.PersistEnabled then return end
    pcall(function() _G[SBI_CFG.PersistKey] = SBI_Serialize() end)
end

function SBI.Load()
    pcall(function()
        local saved = _G[SBI_CFG.PersistKey]
        if type(saved) == "table" then
            SBI_Deserialize(saved)
            local n = 0; for _ in pairs(SBI_Map) do n = n + 1 end
            print(string.format("[SBI] Loaded %d persisted BehaviorRecords.", n))
        end
    end)
end

-- ═════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════

function SBI.Get(remoteName)
    local rec = SBI_Map[remoteName]
    if not rec then return nil end
    return {
        Name              = rec.Name,
        RemoteType        = rec.RemoteType,
        Direction         = rec.Direction,
        SemanticRole      = rec.SemanticRole,
        CausalLinks       = rec.CausalLinks,
        ValidationPattern = rec.ValidationPattern,
        ValidationEvidence= rec.ValidationEvidence,
        ThrottleFloor     = rec.ThrottleFloor,
        BurstCapacity     = rec.BurstCapacity,
        ACPattern         = rec.ACPattern,
        ACCorrectionHz    = rec.ACCorrectionHz,
        ServerLogic       = rec.ServerLogic,
        SideEffects       = rec.SideEffects,
        ProbeCount        = rec.ProbeCount,
        FindingCount      = rec.FindingCount,
        Confidence        = SBI_DecayedConf(rec),
        LastUpdated       = rec.LastUpdated,
    }
end

function SBI.GetAll(minConf)
    minConf = minConf or 0.0
    local out = {}
    for _, rec in pairs(SBI_Map) do
        if SBI_DecayedConf(rec) >= minConf then
            table.insert(out, SBI.Get(rec.Name))
        end
    end
    table.sort(out, function(a,b) return a.Confidence > b.Confidence end)
    return out
end

-- Per-handler-type summary for dashboard
function SBI.GetLogicSummary()
    local counts = {}
    for _, v in pairs(SBI.LOGIC) do counts[v] = 0 end
    for _, rec in pairs(SBI_Map) do
        local lv = rec.ServerLogic or SBI.LOGIC.UNKNOWN
        counts[lv] = (counts[lv] or 0) + 1
    end
    return counts
end

-- Per-validation-type summary
function SBI.GetValidationSummary()
    local counts = {}
    for _, v in pairs(SBI.VALIDATION) do counts[v] = 0 end
    for _, rec in pairs(SBI_Map) do
        local vp = rec.ValidationPattern or SBI.VALIDATION.NONE
        counts[vp] = (counts[vp] or 0) + 1
    end
    return counts
end

-- Per-AC-pattern summary
function SBI.GetACSummary()
    local counts = {}
    for _, v in pairs(SBI.AC) do counts[v] = 0 end
    for _, rec in pairs(SBI_Map) do
        local ap = rec.ACPattern or SBI.AC.NONE
        counts[ap] = (counts[ap] or 0) + 1
    end
    return counts
end

function SBI.Count()
    local n = 0; for _ in pairs(SBI_Map) do n = n + 1 end; return n
end

-- ═════════════════════════════════════════════════════════════
-- STARTUP
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    local function waitFor(getter, label, timeout)
        local t0 = os.clock()
        while not getter() do
            if os.clock()-t0 > timeout then
                warn("[SBI] Timeout waiting for " .. label); return false
            end
            task.wait(0.5)
        end
        return true
    end

    waitFor(function() return _G.PC.PR_Registry end,                    "PR_Registry",   20)
    waitFor(function() return _G.PC.RSM end,                             "RSM",           25)
    waitFor(function() return _G.PC.SR end,                              "SR",            25)
    waitFor(function() return _G.PC.AVD and _G.PC.AVD.Strategist end,   "AVD.Strategist",20)

    SBI.Load()

    -- Hook 1: Strategist.OnReport — post-probe attribution
    local strategist = _G.PC.AVD.Strategist
    if strategist.OnReport then
        local orig = strategist.OnReport
        strategist.OnReport = function(report)
            pcall(orig, report)
            pcall(SBI.OnTranslatorReport, report)
        end
        print("[SBI] Hooked Strategist.OnReport")
    end

    -- Hook 2: Operator.ExecuteProbe — pre-probe snapshot
    -- The Operator doesn't expose OnPreProbe, so we wrap its RegisterProbe
    -- call path via Translator.RegisterProbe (called before fire in Operator)
    local translator = _G.PC.AVD and _G.PC.AVD.Translator
    if translator and translator.RegisterProbe then
        local origReg = translator.RegisterProbe
        translator.RegisterProbe = function(pid, meta)
            pcall(SBI.OnPreProbe, pid)
            return origReg(pid, meta)
        end
        print("[SBI] Hooked Translator.RegisterProbe for pre-probe snapshots")
    end

    -- Initial rebuild
    task.wait(1.5)
    local n = SBI.Rebuild()
    print(string.format("[SBI] Initial rebuild: %d BehaviorRecords.", n))

    -- Auto-rebuild loop
    task.spawn(function()
        while true do
            task.wait(SBI_CFG.AutoRebuildPeriod)
            pcall(SBI.Rebuild)
            pcall(SBI.Save)
        end
    end)
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.SBI = SBI
_G.PC.SBI_Causal     = SBI_Causal
_G.PC.SBI_Validator  = SBI_Validator
_G.PC.SBI_ACDetector = SBI_ACDetector
print("[SBI] Server Behavior Inference ready.")
