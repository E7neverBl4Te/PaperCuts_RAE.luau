-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC

local RunService        = _C.RunService
local ETM               = _C.ETM
local CDG               = _C.CDG
local CDG_Table         = _C.CDG_Table
local LWM               = _C.LWM
local LWM_RemoteRegistry= _C.LWM_RemoteRegistry
local RAE_State         = _C.RAE_State
local StateSignature    = _C.StateSignature

-- ============================================================
-- RSM — Remote Signature Mapping
-- Layer 3 of the PaperCuts intelligence stack.
--
-- Synthesises all upstream observations into a unified,
-- per-remote fingerprint that captures:
--   ArgSig      — argument schema enriched with success/fail
--                 distributions from AVD probe outcomes
--   BehaviorSig — which DataModel paths change, by how much,
--                 what debris appears, latency profile
--   TemporalSig — fire rate, burst score, sequencing neighbours
--   CausalSig   — ETM confidence, CDG effect strength, edges
--
-- Feeds downstream to:
--   TSR Binder  — richer candidate scoring for intent binding
--   AVD Strategist — payload refinement from value distributions
--   SARP Simulator  — pre-flight AC risk from BehaviorSig
-- ============================================================

local RSM = {}

-- ── Persistence ───────────────────────────────────────────────
local RSM_PERSIST_KEY = "RSM_Signatures_" .. tostring(game.PlaceId)
local RSM_PERSIST_VER = "v1"

-- ── Internal map ──────────────────────────────────────────────
-- [remoteName] = RSM_Record
local RSM_Map = {}

-- Ring buffer of recent inter-fire timestamps per remote
-- [remoteName] = {t1, t2, ...} (cap 64)
local RSM_InterFireBuf = {}
local RSM_IFBufCap     = 64

-- Accumulator for BehaviorSig path delta distributions
-- [remoteName][path] = {sum, sumSq, n}
local RSM_PathDeltaAcc = {}

-- ── Configuration ─────────────────────────────────────────────
local RSM_CFG = {
    -- Minimum PR fire count before we build a signature
    MinFireCount        = 3,
    -- Minimum AVD probe reports before BehaviorSig is populated
    MinProbeReports     = 1,
    -- How many StringSamples to carry in ArgSig per slot
    MaxStringSamples    = 8,
    -- How many CDG edge neighbours to surface in CausalSig
    MaxCDGNeighbours    = 5,
    -- Composite confidence weights
    ConfW_FireCount     = 0.20,   -- normalised log(fireCount)
    ConfW_Signal        = 0.35,   -- CONFIRMED=1 STRONG=0.7 WEAK=0.35 LATENCY=0.2 SILENT=0
    ConfW_ETM           = 0.25,   -- ETM mean confidence
    ConfW_Schema        = 0.20,   -- fraction of arg slots with DominantType != unknown
    -- Auto-rebuild period (seconds).  0 = only on explicit Rebuild()
    AutoRebuildPeriod   = 30.0,
    -- Persist across sessions
    PersistEnabled      = true,
}

-- ── Record constructor ─────────────────────────────────────────
local function RSM_NewRecord(name)
    return {
        Name        = name,
        RemoteType  = "UNKNOWN",
        Direction   = "NONE",
        SemanticRole= "UNKNOWN",

        -- Argument signature
        ArgSig      = {},   -- [slotIdx] = ArgSlot (see below)
        ArgCountMin = 999,
        ArgCountMax = 0,

        -- Behaviour signature
        BehaviorSig = {
            AffectedPaths  = {},   -- [path] = true
            PathDeltas     = {},   -- [path] = {mean, std, n}
            DebrisClasses  = {},   -- [className] = true
            LatencyProfile = { mean=0, std=0, n=0 },
            SignalClass    = "UNKNOWN",
            SignalConfidence = 0.0,
            ProbeCount     = 0,
        },

        -- Temporal signature
        TemporalSig = {
            AvgHz      = 0,
            FreqClass  = "RARE",
            InterFireP50 = 0,
            BurstScore = 0,        -- Var/Mean of inter-fire deltas (0 = perfectly periodic)
            PrecedesMap= {},       -- [otherName] = avgDelaySeconds
            FollowsMap = {},       -- [otherName] = avgDelaySeconds
        },

        -- Causal signature
        CausalSig = {
            ETMConfidence = 0.5,
            ETMConverged  = false,
            CDGScore      = 0.0,
            CDGEdges      = {},    -- [{Neighbour, EffectSize, Confidence}]
        },

        -- Composite
        Confidence   = 0.0,
        ObsCount     = 0,
        LastUpdated  = 0,
        PersistVer   = RSM_PERSIST_VER,
    }
end

local function RSM_NewArgSlot()
    return {
        DominantType     = "unknown",
        TypeCounts       = {},
        NumberMin        = nil,
        NumberMax        = nil,
        NumberMean       = 0,
        NumberM2         = 0,    -- Welford M2 for stddev
        NumberN          = 0,
        StringSamples    = {},
        SeenCFrame       = false,
        SeenVector3      = false,
        SeenBool         = false,
        SeenInstance     = false,
        SampleCount      = 0,
        -- Enrichment from AVD outcomes
        SuccessValues    = {},   -- number values that appeared in CONFIRMED probes
        FailValues       = {},   -- number values that appeared in SILENT/ERROR probes
        SuccessStrings   = {},   -- string values that appeared in CONFIRMED probes
    }
end

-- ── Utility: Welford online mean/variance ─────────────────────
local function RSM_WelfordUpdate(slot, v)
    slot.NumberN  = slot.NumberN + 1
    local delta   = v - slot.NumberMean
    slot.NumberMean = slot.NumberMean + delta / slot.NumberN
    local delta2  = v - slot.NumberMean
    slot.NumberM2 = slot.NumberM2 + delta * delta2
end

local function RSM_WelfordStd(slot)
    if slot.NumberN < 2 then return 0 end
    return math.sqrt(slot.NumberM2 / (slot.NumberN - 1))
end

-- ── Utility: percentile from sorted list ──────────────────────
local function RSM_P50(sorted)
    if #sorted == 0 then return 0 end
    local mid = math.ceil(#sorted / 2)
    return sorted[mid]
end

-- ── Utility: burst score (index of dispersion) ────────────────
local function RSM_BurstScore(deltas)
    if #deltas < 3 then return 0 end
    local sum, sumSq, n = 0, 0, #deltas
    for _, d in ipairs(deltas) do sum = sum + d; sumSq = sumSq + d*d end
    local mean = sum / n
    if mean <= 0 then return 0 end
    local variance = (sumSq / n) - (mean * mean)
    return math.max(0, variance / mean)  -- Fano factor
end

-- ── Utility: composite confidence ────────────────────────────
local function RSM_ComputeConfidence(rec)
    -- Fire count contribution: log-normalised to ~0-1 over 1-1000 fires
    local fireScore = 0
    local pr = _G.PC.PR_Registry
    if pr and pr[rec.Name] then
        local fc = pr[rec.Name].FireCount or 0
        fireScore = math.min(1.0, math.log(math.max(1, fc)) / math.log(200))
    end

    -- Signal class contribution
    local signalScore = 0
    local sc = rec.BehaviorSig.SignalClass
    if     sc == "CONFIRMED" then signalScore = 1.0
    elseif sc == "STRONG"    then signalScore = 0.7
    elseif sc == "WEAK"      then signalScore = 0.35
    elseif sc == "LATENCY"   then signalScore = 0.2
    else                          signalScore = 0.0 end

    -- ETM contribution
    local etmScore = rec.CausalSig.ETMConfidence or 0.5
    -- Penalise cold ETM (not converged)
    if not rec.CausalSig.ETMConverged then etmScore = etmScore * 0.6 end

    -- Schema coverage: fraction of slots with known type
    local schemaScore = 0
    local slotCount = math.max(rec.ArgCountMax, 1)
    local knownSlots = 0
    for _, slot in ipairs(rec.ArgSig) do
        if slot.DominantType ~= "unknown" then knownSlots = knownSlots + 1 end
    end
    schemaScore = knownSlots / slotCount

    return math.min(1.0,
        fireScore   * RSM_CFG.ConfW_FireCount +
        signalScore * RSM_CFG.ConfW_Signal    +
        etmScore    * RSM_CFG.ConfW_ETM       +
        schemaScore * RSM_CFG.ConfW_Schema
    )
end

-- ── Utility: get or create record ─────────────────────────────
local function RSM_GetOrCreate(name)
    if not RSM_Map[name] then
        RSM_Map[name] = RSM_NewRecord(name)
    end
    return RSM_Map[name]
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 1 — ARG SIG BUILDER
-- Ingests PR ArgSchema and enriches with AVD probe outcomes.
-- ═════════════════════════════════════════════════════════════
local RSM_ArgSig = {}

-- Copy and enrich a PR ArgSlot into an RSM ArgSlot
local function RSM_IngestPRSlot(rsmSlot, prSlot)
    rsmSlot.DominantType  = prSlot.DominantType or "unknown"
    rsmSlot.TypeCounts    = prSlot.TypeCounts   or {}
    rsmSlot.NumberMin     = prSlot.NumberMin
    rsmSlot.NumberMax     = prSlot.NumberMax
    rsmSlot.SeenCFrame    = prSlot.SeenCFrame   or false
    rsmSlot.SeenVector3   = prSlot.SeenVector3  or false
    rsmSlot.SeenBool      = prSlot.SeenBool     or false
    rsmSlot.SeenInstance  = prSlot.SeenInstance or false
    rsmSlot.SampleCount   = prSlot.SampleCount  or 0

    -- Copy string samples (capped)
    rsmSlot.StringSamples = {}
    for i = 1, math.min(RSM_CFG.MaxStringSamples, #(prSlot.StringSamples or {})) do
        rsmSlot.StringSamples[i] = prSlot.StringSamples[i]
    end

    -- Rebuild Welford from Min/Max if we have no samples yet
    if prSlot.NumberMin and rsmSlot.NumberN == 0 then
        local mid = (prSlot.NumberMin + prSlot.NumberMax) / 2
        RSM_WelfordUpdate(rsmSlot, prSlot.NumberMin)
        RSM_WelfordUpdate(rsmSlot, prSlot.NumberMax)
        RSM_WelfordUpdate(rsmSlot, mid)
    end
end

-- Enrich slots with probe outcome (from AVD Translator report)
-- success=true → CONFIRMED/STRONG, success=false → SILENT/ERROR
function RSM_ArgSig.EnrichFromProbe(rec, probeArgs, success)
    if not probeArgs then return end
    for i, v in ipairs(probeArgs) do
        if not rec.ArgSig[i] then rec.ArgSig[i] = RSM_NewArgSlot() end
        local slot = rec.ArgSig[i]
        if type(v) == "number" then
            RSM_WelfordUpdate(slot, v)
            if slot.NumberMin == nil or v < slot.NumberMin then slot.NumberMin = v end
            if slot.NumberMax == nil or v > slot.NumberMax then slot.NumberMax = v end
            if success then
                table.insert(slot.SuccessValues, v)
                if #slot.SuccessValues > 32 then table.remove(slot.SuccessValues, 1) end
            else
                table.insert(slot.FailValues, v)
                if #slot.FailValues > 32 then table.remove(slot.FailValues, 1) end
            end
        elseif type(v) == "string" then
            if success then
                -- Track which string values produced confirmed responses
                local found = false
                for _, s in ipairs(slot.SuccessStrings) do if s == v then found=true; break end end
                if not found then
                    table.insert(slot.SuccessStrings, v)
                    if #slot.SuccessStrings > RSM_CFG.MaxStringSamples then
                        table.remove(slot.SuccessStrings, 1)
                    end
                end
            end
        end
    end
end

-- Build the ArgSig for a record from PR data
function RSM_ArgSig.BuildFromPR(rec)
    local prReg = _G.PC.PR_Registry
    if not prReg or not prReg[rec.Name] then return end
    local prRec = prReg[rec.Name]

    rec.RemoteType  = prRec.RemoteType  or "UNKNOWN"
    rec.Direction   = prRec.Direction   or "NONE"
    rec.SemanticRole= prRec.SemanticRole or "UNKNOWN"
    rec.ArgCountMin = prRec.ArgCountMin or 0
    rec.ArgCountMax = prRec.ArgCountMax or 0

    -- Ensure we have a slot for every observed position
    for i = 1, prRec.ArgCountMax or 0 do
        if not rec.ArgSig[i] then rec.ArgSig[i] = RSM_NewArgSlot() end
        if prRec.ArgSchema[i] then
            RSM_IngestPRSlot(rec.ArgSig[i], prRec.ArgSchema[i])
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 2 — BEHAVIOR SIG BUILDER
-- Consumes AVD Translator reports to build path delta
-- distributions and classify the server-side response.
-- ═════════════════════════════════════════════════════════════
local RSM_BehaviorSig = {}

-- Signal class → numeric weight for best-report tracking
local SIG_RANK = {
    CONFIRMED = 6, STRONG = 4, LATENCY = 3, WEAK = 2, ERROR = 1, SILENT = 0, UNKNOWN = 0
}

function RSM_BehaviorSig.IngestReport(rec, report)
    local bsig = rec.BehaviorSig
    bsig.ProbeCount = bsig.ProbeCount + 1
    rec.ObsCount    = rec.ObsCount + 1
    rec.LastUpdated = os.clock()

    -- Update signal class (keep the strongest ever seen)
    local newRank = SIG_RANK[report.signal] or 0
    local curRank = SIG_RANK[bsig.SignalClass] or 0
    if newRank > curRank then
        bsig.SignalClass     = report.signal
        bsig.SignalConfidence= report.confidence or 0.0
    elseif newRank == curRank and (report.confidence or 0) > bsig.SignalConfidence then
        bsig.SignalConfidence = report.confidence
    end

    -- Ingest Tier 1 events: property/attribute path changes
    for _, ev in ipairs(report.tier1Events or {}) do
        local path = ev.path
        if path then
            bsig.AffectedPaths[path] = true
            -- Track numeric deltas for this path
            if type(ev.newValue) == "number" and type(ev.oldValue) == "number" then
                local delta = ev.newValue - ev.oldValue
                if not RSM_PathDeltaAcc[rec.Name] then RSM_PathDeltaAcc[rec.Name] = {} end
                if not RSM_PathDeltaAcc[rec.Name][path] then
                    RSM_PathDeltaAcc[rec.Name][path] = { sum=0, sumSq=0, n=0, min=delta, max=delta }
                end
                local acc = RSM_PathDeltaAcc[rec.Name][path]
                acc.n     = acc.n + 1
                acc.sum   = acc.sum + delta
                acc.sumSq = acc.sumSq + delta * delta
                if delta < acc.min then acc.min = delta end
                if delta > acc.max then acc.max = delta end
            end
        end
    end

    -- Ingest Tier 3 events: debris (transient instances)
    for _, ev in ipairs(report.tier3Events or {}) do
        if ev.property then
            bsig.DebrisClasses[ev.property] = true
        end
    end

    -- Ingest Tier 4: latency spike
    if report.latencyDelta and report.latencyDelta > 0 then
        local lp    = bsig.LatencyProfile
        lp.n        = lp.n + 1
        local delta = report.latencyDelta - lp.mean
        lp.mean     = lp.mean + delta / lp.n
        local delta2= report.latencyDelta - lp.mean
        lp.std      = math.sqrt(
            math.max(0, ((lp.std * lp.std * (lp.n-1)) + delta * delta2) / lp.n)
        )
    end

    -- Enrich ArgSig with this probe's outcome
    local success = (report.signal == "CONFIRMED" or report.signal == "STRONG")
    RSM_ArgSig.EnrichFromProbe(rec, report.probeArgs, success)
end

-- Finalise PathDeltas from accumulators
function RSM_BehaviorSig.FinalisePaths(rec)
    local acc = RSM_PathDeltaAcc[rec.Name]
    if not acc then return end
    for path, a in pairs(acc) do
        if a.n > 0 then
            local mean = a.sum / a.n
            local var  = math.max(0, (a.sumSq / a.n) - (mean * mean))
            rec.BehaviorSig.PathDeltas[path] = {
                mean = mean,
                std  = math.sqrt(var),
                min  = a.min,
                max  = a.max,
                n    = a.n,
            }
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 3 — TEMPORAL SIG BUILDER
-- Maintains an inter-fire ring buffer and derives:
--   AvgHz, InterFireP50, BurstScore, PrecedesMap, FollowsMap
-- Called on every observed fire (from PR hook or LWM).
-- ═════════════════════════════════════════════════════════════
local RSM_TemporalSig = {}
local RSM_LastFireT   = {}  -- [remoteName] = os.clock() of last observed fire

function RSM_TemporalSig.RecordFire(name, t)
    t = t or os.clock()
    local rec = RSM_Map[name]
    if not rec then return end

    if RSM_LastFireT[name] then
        local delta = t - RSM_LastFireT[name]
        if delta > 0.002 and delta < 30 then  -- ignore noise and very long gaps
            if not RSM_InterFireBuf[name] then RSM_InterFireBuf[name] = {} end
            table.insert(RSM_InterFireBuf[name], delta)
            if #RSM_InterFireBuf[name] > RSM_IFBufCap then
                table.remove(RSM_InterFireBuf[name], 1)
            end
        end
    end
    RSM_LastFireT[name] = t
    rec.ObsCount = rec.ObsCount + 1
end

function RSM_TemporalSig.Compute(rec)
    local prReg = _G.PC.PR_Registry
    local prRec = prReg and prReg[rec.Name]

    if prRec then
        rec.TemporalSig.AvgHz     = prRec.AvgHz or 0
        rec.TemporalSig.FreqClass = prRec.FreqClass or "RARE"
    end

    local buf = RSM_InterFireBuf[rec.Name]
    if buf and #buf >= 3 then
        local sorted = {table.unpack(buf)}
        table.sort(sorted)
        rec.TemporalSig.InterFireP50 = RSM_P50(sorted)
        rec.TemporalSig.BurstScore   = RSM_BurstScore(buf)
    end

    -- DepEdges → PrecedesMap, FollowsMap
    -- PR_DepEdges[A][B] = true means A was observed before B
    local depEdges = _G.PC.PR_DepEdges  -- exposed by pr.lua (check export)
    if type(depEdges) == "table" then
        -- What rec.Name precedes
        local outgoing = depEdges[rec.Name]
        if outgoing then
            for tgtName, _ in pairs(outgoing) do
                -- We don't have per-edge delay data from PR, so record link existence
                rec.TemporalSig.PrecedesMap[tgtName] =
                    rec.TemporalSig.PrecedesMap[tgtName] or 0
            end
        end
        -- What precedes rec.Name
        for srcName, targets in pairs(depEdges) do
            if targets[rec.Name] and srcName ~= rec.Name then
                rec.TemporalSig.FollowsMap[srcName] =
                    rec.TemporalSig.FollowsMap[srcName] or 0
            end
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4 — CAUSAL SIG BUILDER
-- Pulls ETM and CDG data for the remote.
-- ═════════════════════════════════════════════════════════════
local RSM_CausalSig = {}

function RSM_CausalSig.Compute(rec)
    local csig   = rec.CausalSig
    local curSig = RAE_State.CurrentSig or "unknown"

    -- ETM: mean prediction across all observed state signatures
    local etmSum, etmN, etmConvergedAny = 0, 0, false
    local etmTable = _G.PC.ETM_Table
    if etmTable and etmTable[rec.Name] then
        for sig, e in pairs(etmTable[rec.Name]) do
            local p = e.mean or 0.5
            etmSum = etmSum + p
            etmN   = etmN + 1
            if e.converged then etmConvergedAny = true end
        end
    end
    -- Also check the sarp_ namespaced key PR uses
    local prKey = "sarp_" .. rec.Name
    if etmTable and etmTable[prKey] then
        for sig, e in pairs(etmTable[prKey]) do
            etmSum = etmSum + (e.mean or 0.5)
            etmN   = etmN + 1
            if e.converged then etmConvergedAny = true end
        end
    end
    csig.ETMConfidence = etmN > 0 and (etmSum / etmN) or 0.5
    csig.ETMConverged  = etmConvergedAny

    -- CDG: score and top neighbours
    csig.CDGScore = CDG.GetCausalScore(rec.Name)

    csig.CDGEdges = {}
    local cdgRow = CDG_Table and CDG_Table[rec.Name]
    if cdgRow then
        local edges = {}
        for neighbour, e in pairs(cdgRow) do
            table.insert(edges, {
                Neighbour  = neighbour,
                EffectSize = e.effectSize or 0,
                Confidence = e.confidence or 0,
            })
        end
        table.sort(edges, function(a, b)
            return (a.EffectSize * a.Confidence) > (b.EffectSize * b.Confidence)
        end)
        for i = 1, math.min(RSM_CFG.MaxCDGNeighbours, #edges) do
            csig.CDGEdges[i] = edges[i]
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 5 — REBUILD ENGINE
-- Full signature rebuild for one or all remotes.
-- Iterates PR_Registry + AVD Translator reports.
-- ═════════════════════════════════════════════════════════════

local function RSM_RebuildOne(name)
    local prReg = _G.PC.PR_Registry
    if not prReg or not prReg[name] then return end

    local prRec = prReg[name]
    if (prRec.FireCount or 0) < RSM_CFG.MinFireCount then return end

    local rec = RSM_GetOrCreate(name)

    -- Step 1: ArgSig from PR
    RSM_ArgSig.BuildFromPR(rec)

    -- Step 2: BehaviorSig from AVD Translator reports
    local translator = _G.PC.AVD and _G.PC.AVD.Translator
    if translator then
        local reports = translator.GetReportsFor(name)
        for _, report in ipairs(reports) do
            RSM_BehaviorSig.IngestReport(rec, report)
        end
        RSM_BehaviorSig.FinalisePaths(rec)
    end

    -- Step 3: TemporalSig
    RSM_TemporalSig.Compute(rec)

    -- Step 4: CausalSig
    RSM_CausalSig.Compute(rec)

    -- Step 5: Composite confidence
    rec.Confidence  = RSM_ComputeConfidence(rec)
    rec.LastUpdated = os.clock()
end

function RSM.Rebuild()
    local prReg = _G.PC.PR_Registry
    if not prReg then return 0 end

    local built = 0
    for name, _ in pairs(prReg) do
        local ok, err = pcall(RSM_RebuildOne, name)
        if ok then built = built + 1
        else warn("[RSM] RebuildOne failed for " .. name .. ": " .. tostring(err)) end
    end

    return built
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 6 — LIVE UPDATE HOOKS
-- Called by PR/AVD on each new observation so the map
-- stays current without waiting for a full Rebuild().
-- ═════════════════════════════════════════════════════════════

-- Called by PR when a new fire is logged
function RSM.OnRemoteFired(name, args, direction, t)
    local prReg = _G.PC.PR_Registry
    if not prReg or not prReg[name] then return end

    -- Lazy-create the record
    local rec = RSM_GetOrCreate(name)

    -- Record fire for temporal sig
    RSM_TemporalSig.RecordFire(name, t)

    -- If we now have enough fires, do a lightweight ArgSig refresh
    local fc = prReg[name].FireCount or 0
    if fc >= RSM_CFG.MinFireCount then
        pcall(RSM_ArgSig.BuildFromPR, rec)
        rec.LastUpdated = os.clock()
    end
end

-- Called by AVD Translator when a probe resolves
function RSM.OnTranslatorReport(report)
    if not report or not report.remoteName then return end
    local rec = RSM_GetOrCreate(report.remoteName)
    RSM_BehaviorSig.IngestReport(rec, report)
    RSM_BehaviorSig.FinalisePaths(rec)
    RSM_CausalSig.Compute(rec)
    rec.Confidence = RSM_ComputeConfidence(rec)
    rec.LastUpdated = os.clock()
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 7 — PERSISTENCE
-- Serialises RSM_Map to _G for cross-session continuity.
-- Full record serialisation; restores on next load.
-- ═════════════════════════════════════════════════════════════
local function RSM_Serialize()
    local out = {}
    for name, rec in pairs(RSM_Map) do
        -- Compact the record: drop the runtime-heavy tables that will be rebuilt,
        -- keep the statistical distributions that took many sessions to learn.
        local argSigOut = {}
        for i, slot in ipairs(rec.ArgSig) do
            argSigOut[i] = {
                DominantType  = slot.DominantType,
                NumberMin     = slot.NumberMin,
                NumberMax     = slot.NumberMax,
                NumberMean    = slot.NumberMean,
                NumberN       = slot.NumberN,
                SampleCount   = slot.SampleCount,
                SuccessValues = slot.SuccessValues,
                FailValues    = slot.FailValues,
                SuccessStrings= slot.SuccessStrings,
            }
        end
        local pathDeltaOut = {}
        for path, pd in pairs(rec.BehaviorSig.PathDeltas) do
            pathDeltaOut[path] = pd
        end
        out[name] = {
            RemoteType   = rec.RemoteType,
            Direction    = rec.Direction,
            SemanticRole = rec.SemanticRole,
            ArgCountMin  = rec.ArgCountMin,
            ArgCountMax  = rec.ArgCountMax,
            ArgSig       = argSigOut,
            BehaviorSig  = {
                AffectedPaths    = rec.BehaviorSig.AffectedPaths,
                PathDeltas       = pathDeltaOut,
                DebrisClasses    = rec.BehaviorSig.DebrisClasses,
                LatencyProfile   = rec.BehaviorSig.LatencyProfile,
                SignalClass      = rec.BehaviorSig.SignalClass,
                SignalConfidence = rec.BehaviorSig.SignalConfidence,
                ProbeCount       = rec.BehaviorSig.ProbeCount,
            },
            TemporalSig  = {
                AvgHz         = rec.TemporalSig.AvgHz,
                FreqClass     = rec.TemporalSig.FreqClass,
                InterFireP50  = rec.TemporalSig.InterFireP50,
                BurstScore    = rec.TemporalSig.BurstScore,
                PrecedesMap   = rec.TemporalSig.PrecedesMap,
                FollowsMap    = rec.TemporalSig.FollowsMap,
            },
            CausalSig    = rec.CausalSig,
            Confidence   = rec.Confidence,
            ObsCount     = rec.ObsCount,
            LastUpdated  = rec.LastUpdated,
            PersistVer   = RSM_PERSIST_VER,
        }
    end
    return out
end

local function RSM_Deserialize(data)
    for name, saved in pairs(data) do
        if saved.PersistVer == RSM_PERSIST_VER then
            local rec = RSM_NewRecord(name)
            rec.RemoteType   = saved.RemoteType   or "UNKNOWN"
            rec.Direction    = saved.Direction    or "NONE"
            rec.SemanticRole = saved.SemanticRole or "UNKNOWN"
            rec.ArgCountMin  = saved.ArgCountMin  or 999
            rec.ArgCountMax  = saved.ArgCountMax  or 0
            rec.Confidence   = saved.Confidence   or 0
            rec.ObsCount     = saved.ObsCount     or 0
            rec.LastUpdated  = saved.LastUpdated  or 0

            -- ArgSig
            for i, slotData in ipairs(saved.ArgSig or {}) do
                local slot = RSM_NewArgSlot()
                slot.DominantType   = slotData.DominantType   or "unknown"
                slot.NumberMin      = slotData.NumberMin
                slot.NumberMax      = slotData.NumberMax
                slot.NumberMean     = slotData.NumberMean     or 0
                slot.NumberN        = slotData.NumberN        or 0
                slot.SampleCount    = slotData.SampleCount    or 0
                slot.SuccessValues  = slotData.SuccessValues  or {}
                slot.FailValues     = slotData.FailValues     or {}
                slot.SuccessStrings = slotData.SuccessStrings or {}
                rec.ArgSig[i] = slot
            end

            -- BehaviorSig
            if saved.BehaviorSig then
                local bs = rec.BehaviorSig
                bs.AffectedPaths    = saved.BehaviorSig.AffectedPaths    or {}
                bs.PathDeltas       = saved.BehaviorSig.PathDeltas       or {}
                bs.DebrisClasses    = saved.BehaviorSig.DebrisClasses    or {}
                bs.LatencyProfile   = saved.BehaviorSig.LatencyProfile   or { mean=0, std=0, n=0 }
                bs.SignalClass      = saved.BehaviorSig.SignalClass      or "UNKNOWN"
                bs.SignalConfidence = saved.BehaviorSig.SignalConfidence or 0
                bs.ProbeCount       = saved.BehaviorSig.ProbeCount       or 0
            end

            -- TemporalSig
            if saved.TemporalSig then
                rec.TemporalSig = {
                    AvgHz        = saved.TemporalSig.AvgHz       or 0,
                    FreqClass    = saved.TemporalSig.FreqClass   or "RARE",
                    InterFireP50 = saved.TemporalSig.InterFireP50 or 0,
                    BurstScore   = saved.TemporalSig.BurstScore  or 0,
                    PrecedesMap  = saved.TemporalSig.PrecedesMap or {},
                    FollowsMap   = saved.TemporalSig.FollowsMap  or {},
                }
            end

            -- CausalSig
            if saved.CausalSig then
                rec.CausalSig = {
                    ETMConfidence = saved.CausalSig.ETMConfidence or 0.5,
                    ETMConverged  = saved.CausalSig.ETMConverged  or false,
                    CDGScore      = saved.CausalSig.CDGScore      or 0.0,
                    CDGEdges      = saved.CausalSig.CDGEdges      or {},
                }
            end

            RSM_Map[name] = rec
        end
    end
end

function RSM.Save()
    if not RSM_CFG.PersistEnabled then return end
    pcall(function()
        _G[RSM_PERSIST_KEY] = RSM_Serialize()
    end)
end

function RSM.Load()
    pcall(function()
        local saved = _G[RSM_PERSIST_KEY]
        if type(saved) == "table" then
            RSM_Deserialize(saved)
            local n = 0; for _ in pairs(RSM_Map) do n = n + 1 end
            print(string.format("[RSM] Loaded %d persisted signatures.", n))
        end
    end)
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 8 — PUBLIC API
-- ═════════════════════════════════════════════════════════════

-- Get a single signature record
function RSM.Get(remoteName)
    return RSM_Map[remoteName]
end

-- Get all signatures, optionally sorted by confidence desc
function RSM.GetAll(sortByConf)
    local out = {}
    for _, rec in pairs(RSM_Map) do table.insert(out, rec) end
    if sortByConf ~= false then
        table.sort(out, function(a, b) return a.Confidence > b.Confidence end)
    end
    return out
end

-- Get only signatures meeting minimum confidence
function RSM.GetConfident(minConf)
    minConf = minConf or 0.4
    local out = {}
    for _, rec in pairs(RSM_Map) do
        if rec.Confidence >= minConf then table.insert(out, rec) end
    end
    table.sort(out, function(a,b) return a.Confidence > b.Confidence end)
    return out
end

-- Find best-matching signatures for a given intent's arg schema.
-- intentArgTypes: list of type strings e.g. {"number","string"}
-- Returns list of {Record, Score} sorted by match score desc.
function RSM.MatchIntent(intentArgTypes, minConf)
    minConf = minConf or 0.0
    local results = {}
    for _, rec in pairs(RSM_Map) do
        if rec.Confidence >= minConf then
            local matchScore = 0
            local total = #intentArgTypes
            if total == 0 then
                -- No arg constraint — score purely on confidence
                matchScore = rec.Confidence
            else
                local matched = 0
                for i, wantType in ipairs(intentArgTypes) do
                    local slot = rec.ArgSig[i]
                    if slot and (slot.DominantType == wantType or wantType == "any") then
                        matched = matched + 1
                    end
                end
                -- Penalise arg count mismatch
                local argCountMatch = (rec.ArgCountMin <= total and rec.ArgCountMax >= total) and 1.0 or 0.5
                matchScore = (matched / total) * argCountMatch * rec.Confidence
            end
            if matchScore > 0 then
                table.insert(results, { Record=rec, Score=matchScore })
            end
        end
    end
    table.sort(results, function(a,b) return a.Score > b.Score end)
    return results
end

-- Get a human-readable fingerprint string for a remote
function RSM.GetFingerprint(remoteName)
    local rec = RSM_Map[remoteName]
    if not rec then return "No signature for " .. remoteName end

    local parts = {}
    table.insert(parts, string.format("[%s] %s • %s • %s",
        rec.RemoteType, rec.Name, rec.Direction, rec.SemanticRole))
    table.insert(parts, string.format("  Conf: %.0f%%  Obs: %d  Signal: %s (%.0f%%)",
        rec.Confidence*100, rec.ObsCount,
        rec.BehaviorSig.SignalClass, rec.BehaviorSig.SignalConfidence*100))

    -- ArgSig summary
    local argParts = {}
    for i, slot in ipairs(rec.ArgSig) do
        local t = slot.DominantType
        if t == "number" and slot.NumberMin then
            t = string.format("num[%.0f–%.0f μ=%.1f]", slot.NumberMin, slot.NumberMax, slot.NumberMean)
        elseif t == "string" and #slot.SuccessStrings > 0 then
            t = string.format("str(%s)", slot.SuccessStrings[1])
        end
        argParts[i] = t
    end
    if #argParts > 0 then
        table.insert(parts, "  Args: (" .. table.concat(argParts, ", ") .. ")")
    end

    -- BehaviorSig summary
    local pathList = {}
    for path in pairs(rec.BehaviorSig.AffectedPaths) do
        table.insert(pathList, path)
    end
    if #pathList > 0 then
        table.insert(parts, "  Affects: " .. table.concat(pathList, ", "):sub(1,80))
    end

    -- TemporalSig
    table.insert(parts, string.format("  Temporal: %.2fHz %s P50=%.0fms Burst=%.2f",
        rec.TemporalSig.AvgHz, rec.TemporalSig.FreqClass,
        rec.TemporalSig.InterFireP50 * 1000,
        rec.TemporalSig.BurstScore))

    -- CausalSig
    table.insert(parts, string.format("  Causal: ETM=%.0f%%%s CDG=%.3f",
        rec.CausalSig.ETMConfidence * 100,
        rec.CausalSig.ETMConverged and "✓" or "~",
        rec.CausalSig.CDGScore))

    return table.concat(parts, "\n")
end

-- Get config (for UI settings)
function RSM.GetCFG() return RSM_CFG end

-- Count signatures
function RSM.Count()
    local n = 0; for _ in pairs(RSM_Map) do n = n + 1 end; return n
end

-- ═════════════════════════════════════════════════════════════
-- STARTUP — hook into AVD Translator and start auto-rebuild
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    -- Wait for PR to be ready
    local waitStart = os.clock()
    while not _G.PC.PR_Registry do
        if os.clock() - waitStart > 20 then
            warn("[RSM] PR_Registry not found after 20s — some features limited.")
            break
        end
        task.wait(0.5)
    end

    -- Wait for AVD translator
    waitStart = os.clock()
    while not (_G.PC.AVD and _G.PC.AVD.Translator) do
        if os.clock() - waitStart > 20 then break end
        task.wait(0.5)
    end

    -- Hook into Translator: wrap OnReport to also notify RSM
    local translator = _G.PC.AVD and _G.PC.AVD.Translator
    if translator then
        local original = translator.GetReports  -- GetReports is pure, hook Resolve instead
        -- We'll hook via the Strategist's OnReport callback chain:
        -- AVD_Strategist.OnReport is called by Translator.Resolve.
        -- We install a secondary hook alongside it.
        local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
        if strategist and strategist.OnReport then
            local origOnReport = strategist.OnReport
            strategist.OnReport = function(report)
                pcall(origOnReport, report)
                pcall(RSM.OnTranslatorReport, report)
            end
        end
    end

    -- Load persisted signatures
    RSM.Load()

    -- Initial rebuild from whatever PR and AVD have at this point
    task.wait(1.0)
    local built = RSM.Rebuild()
    print(string.format("[RSM] Initial rebuild: %d signatures.", built))

    -- Auto-rebuild loop
    if RSM_CFG.AutoRebuildPeriod > 0 then
        while true do
            task.wait(RSM_CFG.AutoRebuildPeriod)
            pcall(RSM.Rebuild)
            pcall(RSM.Save)
        end
    end
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.RSM = RSM
print("[RSM] Remote Signature Mapping ready.")
