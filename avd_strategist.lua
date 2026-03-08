-- ── Imports ──────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- AVD STRATEGIST — Intelligence & Generation
-- The brain of AVD. Never touches remotes directly.
-- Responsibilities:
--   1. Receive targets from RAE/PR
--   2. Generate probe plans (what to send and why)
--   3. Interpret Correlation Reports from Translator
--   4. Rank confirmed vulnerabilities by exploitability
--   5. Dispatch confirmed payloads to SARP via Operator
-- ============================================================

local STRATEGIST_CFG = {
    -- Max probes per remote before giving up
    MaxProbesPerRemote   = 24,
    -- Min confidence to escalate to active probing
    PassiveEscalateMin   = 0.3,
    -- Min confidence to flag as exploitable
    ExploitableThreshold = 0.6,
    -- Min confidence to hand to SARP
    SARPHandoffThreshold = 0.75,
    -- Probe generation: max variants per technique
    MaxVariantsPerTech   = 4,
    -- How long to wait between active probes (seconds)
    ActiveProbeCooldown  = 0.8,
    -- Persist findings across sessions
    PersistKey           = "AVD_Findings_" .. tostring(game.PlaceId),
    PersistEnabled       = true,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local AVD_Strategist = {}

-- Target registry: [remoteName] = TargetRecord
local S_Targets  = {}

-- Vulnerability findings: [remoteName] = FindingRecord
local S_Findings = {}

-- Probe plan queue per remote: [remoteName] = { ProbePlan, ... }
local S_ProbePlans = {}

-- Probe counter per remote
local S_ProbeCount = {}

-- Probe ID counter
local S_ProbeIDCounter = 0

local function S_NextProbeID()
    S_ProbeIDCounter = S_ProbeIDCounter + 1
    return string.format("P%06d", S_ProbeIDCounter)
end

-- ── Target record ─────────────────────────────────────────────────────────────
local function S_NewTarget(name, remoteObj, remoteType, schema, category)
    return {
        name        = name,
        remote      = remoteObj,
        remoteType  = remoteType,   -- "RemoteEvent" | "RemoteFunction" | "BindableEvent" etc
        schema      = schema or {},  -- arg slots from PR/RAE
        category    = category or "UNKNOWN",
        addedAt     = os.clock(),
        probeCount  = 0,
        status      = "QUEUED",     -- QUEUED | PASSIVE | ACTIVE | DONE | SKIP
        bestSignal  = "SILENT",
        bestConf    = 0.0,
    }
end

-- ── Finding record ─────────────────────────────────────────────────────────────
local function S_NewFinding(target, report, technique)
    return {
        remoteName    = target.name,
        remoteType    = target.remoteType,
        category      = target.category,
        technique     = technique,     -- which probe technique found it
        signal        = report.signal,
        confidence    = report.confidence,
        affectedPaths = report.affectedPaths,
        debrisClasses = report.debrisClasses,
        latencyDelta  = report.latencyDelta,
        probeArgs     = report.probeArgs,
        probeKind     = report.probeKind,
        foundAt       = os.clock(),
        -- Exploitability scoring (computed below)
        exploitScore  = 0.0,
        sarpReady     = false,
    }
end

-- ── Probe technique library ───────────────────────────────────────────────────
-- Each technique is a function: (target) -> list of ProbePlan
-- ProbePlan = { kind, args, expectedSignal, description, technique }

local Techniques = {}

-- 1. Nil injection — fewer args than expected
Techniques.NilInjection = function(target)
    local plans = {}
    local slots = #target.schema
    if slots == 0 then return plans end
    -- Send progressively fewer args
    for drop = 1, math.min(slots, STRATEGIST_CFG.MaxVariantsPerTech) do
        local args = {}
        for i = 1, slots - drop do
            local slot = target.schema[i]
            table.insert(args, S_DefaultForSlot(slot))
        end
        table.insert(plans, {
            kind        = "NilInjection",
            args        = args,
            description = string.format("Drop last %d arg(s) of %d", drop, slots),
            technique   = "NilInjection",
            expectedSignal = "ERROR",
        })
    end
    return plans
end

-- 2. Type confusion — wrong type per slot
Techniques.TypeConfusion = function(target)
    local plans = {}
    local WRONG_TYPES = {
        number  = {"string", "boolean", "{}"},
        string  = {"number", "boolean", "{}"},
        boolean = {"number", "string"},
        CFrame  = {"string", "number"},
        Vector3 = {"string", "number"},
        Instance= {"string", "number"},
    }
    for i, slot in ipairs(target.schema) do
        local wrongs = WRONG_TYPES[slot.DominantType]
        if wrongs then
            for _, wrongType in ipairs(wrongs) do
                local args = {}
                for j, s in ipairs(target.schema) do
                    if j == i then
                        args[j] = S_WrongValueForType(wrongType)
                    else
                        args[j] = S_DefaultForSlot(s)
                    end
                end
                table.insert(plans, {
                    kind        = "TypeConfusion",
                    args        = args,
                    description = string.format("Slot %d: %s→%s", i, slot.DominantType, wrongType),
                    technique   = "TypeConfusion",
                    expectedSignal = "ERROR",
                })
                if #plans >= STRATEGIST_CFG.MaxVariantsPerTech then break end
            end
        end
        if #plans >= STRATEGIST_CFG.MaxVariantsPerTech then break end
    end
    return plans
end

-- 3. Boundary violation — numbers at extremes
Techniques.BoundaryViolation = function(target)
    local plans = {}
    local BOUNDS = { -1, 0, 1, math.huge, -math.huge, 2^31-1, -(2^31), 0.0001, 9999999 }
    for i, slot in ipairs(target.schema) do
        if slot.DominantType == "number" then
            for _, bval in ipairs(BOUNDS) do
                local args = {}
                for j, s in ipairs(target.schema) do
                    args[j] = j == i and bval or S_DefaultForSlot(s)
                end
                table.insert(plans, {
                    kind        = "BoundaryViolation",
                    args        = args,
                    description = string.format("Slot %d = %s", i, tostring(bval)),
                    technique   = "BoundaryViolation",
                    expectedSignal = "STRONG",
                })
                if #plans >= STRATEGIST_CFG.MaxVariantsPerTech then break end
            end
        end
        if #plans >= STRATEGIST_CFG.MaxVariantsPerTech then break end
    end
    return plans
end

-- 4. Replay attack — resend a previously observed valid payload
Techniques.Replay = function(target)
    local plans = {}
    -- Pull observed args from PR registry
    local pr = _G.PC.PR_Registry
    if pr and pr[target.name] then
        local rec = pr[target.name]
        -- Build a valid-looking payload from schema
        local args = {}
        for _, slot in ipairs(rec.ArgSchema or {}) do
            table.insert(args, S_DefaultForSlot(slot))
        end
        if #args > 0 then
            table.insert(plans, {
                kind        = "Replay",
                args        = args,
                description = "Replay observed valid payload",
                technique   = "Replay",
                expectedSignal = "CONFIRMED",
            })
        end
    end
    return plans
end

-- 5. Privilege escalation — inject a player reference that isn't the local player
Techniques.PrivilegeEscalation = function(target)
    local plans = {}
    local Players = _G.PC.Players
    if not Players then return plans end
    local others = Players:GetPlayers()
    local others_filtered = {}
    for _, p in ipairs(others) do
        if p ~= _G.PC.player then table.insert(others_filtered, p) end
    end
    if #others_filtered == 0 then return plans end
    for i, slot in ipairs(target.schema) do
        if slot.DominantType == "Instance" or slot.SeenInstance then
            local victim = others_filtered[1]
            local args = {}
            for j, s in ipairs(target.schema) do
                args[j] = j == i and victim or S_DefaultForSlot(s)
            end
            table.insert(plans, {
                kind        = "PrivilegeEscalation",
                args        = args,
                description = string.format("Slot %d: inject other player", i),
                technique   = "PrivilegeEscalation",
                expectedSignal = "CONFIRMED",
            })
            break
        end
    end
    return plans
end

-- 6. Rate abuse — fire rapidly to test rate limiting
Techniques.RateAbuse = function(target)
    -- Returns a single plan marked for rapid repeat (Operator handles repetition)
    local args = {}
    for _, slot in ipairs(target.schema) do
        table.insert(args, S_DefaultForSlot(slot))
    end
    return {{
        kind        = "RateAbuse",
        args        = args,
        description = "Rapid-fire to test rate limiting",
        technique   = "RateAbuse",
        expectedSignal = "LATENCY",
        repeatCount = 8,
        repeatDelay = 0.05,
    }}
end

-- 7. Sequence breaking — fire in wrong order relative to another remote
Techniques.SequenceBreak = function(target)
    -- Fire this remote before its known predecessor
    -- Requires dep graph from PR
    local prDeps = _G.PC.PR_DepEdges
    if not prDeps then return {} end
    -- Check if any remote has this as a dependency target
    local predecessor = nil
    for from, targets in pairs(prDeps) do
        if targets[target.name] then predecessor = from; break end
    end
    if not predecessor then return {} end
    local args = {}
    for _, slot in ipairs(target.schema) do table.insert(args, S_DefaultForSlot(slot)) end
    return {{
        kind        = "SequenceBreak",
        args        = args,
        description = string.format("Fire before expected predecessor: %s", predecessor),
        technique   = "SequenceBreak",
        expectedSignal = "STRONG",
        predecessor = predecessor,
    }}
end

-- 8. Echo differential — fire and immediately read replicated values
Techniques.EchoDifferential = function(target)
    local args = {}
    for _, slot in ipairs(target.schema) do table.insert(args, S_DefaultForSlot(slot)) end
    return {{
        kind        = "EchoDifferential",
        args        = args,
        description = "Fire and watch for immediate state delta",
        technique   = "EchoDifferential",
        expectedSignal = "CONFIRMED",
        watchWindow = 1.5,
    }}
end

-- 9. Ownership boundary — attempt on an instance not owned by local player
Techniques.OwnershipBoundary = function(target)
    local args = {}
    for _, slot in ipairs(target.schema) do
        if slot.DominantType == "Instance" then
            -- Try to pass a part the server owns
            local ws = _G.PC.Workspace
            if ws then
                local ok, part = pcall(function()
                    for _, obj in ipairs(ws:GetDescendants()) do
                        if obj:IsA("BasePart") and obj.Name ~= "Terrain" then
                            return obj
                        end
                    end
                end)
                table.insert(args, (ok and part) or nil)
            else
                table.insert(args, S_DefaultForSlot(slot))
            end
        else
            table.insert(args, S_DefaultForSlot(slot))
        end
    end
    return {{
        kind        = "OwnershipBoundary",
        args        = args,
        description = "Pass server-owned instance to test ownership check",
        technique   = "OwnershipBoundary",
        expectedSignal = "STRONG",
    }}
end

-- 10. Return value mining — for RemoteFunctions, probe for error leakage
Techniques.ReturnValueMining = function(target)
    if target.remoteType ~= "RemoteFunction" then return {} end
    local variants = {
        { nil },
        { "" },
        { 0 },
        { "'; DROP TABLE--" },
    }
    local plans = {}
    for _, v in ipairs(variants) do
        table.insert(plans, {
            kind        = "ReturnValueMining",
            args        = v,
            description = "Probe RF return for error leakage",
            technique   = "ReturnValueMining",
            expectedSignal = "ERROR",
            captureReturn = true,
        })
    end
    return plans
end

-- 11. Redundancy / replay dedup test
Techniques.RedundancyProbe = function(target)
    local args = {}
    for _, slot in ipairs(target.schema) do table.insert(args, S_DefaultForSlot(slot)) end
    return {{
        kind        = "RedundancyProbe",
        args        = args,
        description = "Send identical payload twice, check if server deduplicates",
        technique   = "RedundancyProbe",
        expectedSignal = "STRONG",
        repeatCount = 2,
        repeatDelay = 0.02,
    }}
end

-- ── Slot value helpers ────────────────────────────────────────────────────────
function S_DefaultForSlot(slot)
    if not slot then return nil end
    local t = slot.DominantType
    if t == "number"   then return slot.NumberMin or 1 end
    if t == "string"   then return slot.StringSamples and slot.StringSamples[1] or "test" end
    if t == "boolean"  then return true end
    if t == "CFrame"   then return CFrame.new() end
    if t == "Vector3"  then return Vector3.new() end
    if t == "Instance" then
        -- Try local player's character
        local p = _G.PC.player
        return p and p.Character or nil
    end
    return nil
end

function S_WrongValueForType(wrongType)
    if wrongType == "number"  then return 42 end
    if wrongType == "string"  then return "injected" end
    if wrongType == "boolean" then return false end
    if wrongType == "{}"      then return {} end
    return nil
end

-- ── Technique selector ────────────────────────────────────────────────────────
-- Chooses which techniques to run based on remote metadata
local function S_SelectTechniques(target)
    local selected = {}

    -- Always run these
    table.insert(selected, Techniques.EchoDifferential)
    table.insert(selected, Techniques.Replay)

    -- Schema-dependent
    if #target.schema > 0 then
        table.insert(selected, Techniques.NilInjection)
        table.insert(selected, Techniques.TypeConfusion)
        for _, slot in ipairs(target.schema) do
            if slot.DominantType == "number" then
                table.insert(selected, Techniques.BoundaryViolation)
                break
            end
        end
        for _, slot in ipairs(target.schema) do
            if slot.DominantType == "Instance" or slot.SeenInstance then
                table.insert(selected, Techniques.PrivilegeEscalation)
                table.insert(selected, Techniques.OwnershipBoundary)
                break
            end
        end
    end

    -- Type-dependent
    if target.remoteType == "RemoteFunction" then
        table.insert(selected, Techniques.ReturnValueMining)
    end

    -- Category-dependent
    local cat = target.category
    if cat == "ECONOMY" or cat == "COMBAT" then
        table.insert(selected, Techniques.RateAbuse)
        table.insert(selected, Techniques.RedundancyProbe)
    end
    if cat == "SYNC" or cat == "HEARTBEAT" then
        table.insert(selected, Techniques.SequenceBreak)
    end

    return selected
end

-- ── Probe plan generation ─────────────────────────────────────────────────────
local function S_GeneratePlans(target)
    local allPlans = {}
    local techniques = S_SelectTechniques(target)
    for _, tech in ipairs(techniques) do
        local plans = pcall and select(2, pcall(tech, target)) or tech(target)
        if type(plans) == "table" then
            for _, plan in ipairs(plans) do
                table.insert(allPlans, plan)
            end
        end
    end
    return allPlans
end

-- ── Exploitability scorer ─────────────────────────────────────────────────────
local function S_ScoreExploitability(finding)
    local score = finding.confidence

    -- Boost for high-value categories
    local catBoost = {
        ECONOMY  = 0.20,
        COMBAT   = 0.15,
        MOVEMENT = 0.10,
        ANTICHEAT= 0.05,
        SPAWN    = 0.10,
    }
    score = score + (catBoost[finding.category] or 0)

    -- Boost for direct state confirmation
    if finding.signal == "CONFIRMED" then score = score + 0.10 end

    -- Boost for debris (server ran code we triggered)
    if #finding.debrisClasses > 0 then score = score + 0.08 end

    -- Boost for latency spike (execution evidence)
    if finding.latencyDelta and finding.latencyDelta > 100 then
        score = score + 0.06
    end

    -- Boost for multiple affected paths (wide impact)
    if #finding.affectedPaths > 2 then score = score + 0.05 end

    finding.exploitScore = math.min(1.0, score)
    finding.sarpReady    = finding.exploitScore >= STRATEGIST_CFG.SARPHandoffThreshold
    return finding.exploitScore
end

-- ── Report handler (called by Translator) ────────────────────────────────────
function AVD_Strategist.OnReport(report)
    local name   = report.remoteName
    local target = S_Targets[name]
    if not target then return end

    -- Update target best signal
    if report.confidence > target.bestConf then
        target.bestConf   = report.confidence
        target.bestSignal = report.signal
    end

    -- Only create findings for signals above noise floor
    if report.signal == "SILENT" or report.signal == "WEAK" then
        -- Check if we've exhausted probes
        local count = S_ProbeCount[name] or 0
        if count >= STRATEGIST_CFG.MaxProbesPerRemote then
            target.status = "DONE"
        end
        return
    end

    -- Determine which technique produced this report
    local technique = report.probeKind or "Unknown"

    -- Create or update finding
    if not S_Findings[name] then
        S_Findings[name] = S_NewFinding(target, report, technique)
    else
        -- Update if this report is better
        if report.confidence > S_Findings[name].confidence then
            local f = S_Findings[name]
            f.signal        = report.signal
            f.confidence    = report.confidence
            f.technique     = technique
            f.affectedPaths = report.affectedPaths
            f.debrisClasses = report.debrisClasses
            f.latencyDelta  = report.latencyDelta
            f.probeArgs     = report.probeArgs
            f.probeKind     = report.probeKind
            f.foundAt       = os.clock()
        end
    end

    local finding = S_Findings[name]
    S_ScoreExploitability(finding)

    -- Hand off to SARP if threshold met
    if finding.sarpReady then
        AVD_Strategist.HandoffToSARP(finding, report)
        target.status = "DONE"
    end

    -- Persist
    if STRATEGIST_CFG.PersistEnabled then
        pcall(function() AVD_Strategist.SaveFindings() end)
    end
end

-- ── SARP handoff ──────────────────────────────────────────────────────────────
function AVD_Strategist.HandoffToSARP(finding, report)
    local operator = _G.PC.AVD and _G.PC.AVD.Operator
    if not operator or not operator.SARPDeliver then return false end

    print(string.format("[AVD Strategist] Handing off %s → SARP (score=%.2f)",
        finding.remoteName, finding.exploitScore))

    return pcall(operator.SARPDeliver, {
        remoteName  = finding.remoteName,
        payload     = report.probeArgs,
        channel     = "Attribute",  -- default; Operator may override via PR_Bridge
        confidence  = finding.confidence,
        exploitScore= finding.exploitScore,
        technique   = finding.technique,
    })
end

-- ── Target ingestion ──────────────────────────────────────────────────────────
function AVD_Strategist.AddTarget(name, remoteObj, remoteType, schema, category)
    if S_Targets[name] then return end  -- already queued

    local target = S_NewTarget(name, remoteObj, remoteType, schema, category)
    S_Targets[name] = target
    S_ProbeCount[name] = 0

    -- Generate probe plans immediately
    local plans = S_GeneratePlans(target)
    S_ProbePlans[name] = plans

    print(string.format("[AVD Strategist] Target added: %s (%s) — %d probe plans",
        name, remoteType, #plans))
end

-- Ingest targets from RAE world state
function AVD_Strategist.IngestFromRAE()
    local rae = _G.PC.RAE_State
    if not rae or not rae.WorldState then return 0 end
    local count = 0
    for _, remote in ipairs(rae.WorldState.Remotes or {}) do
        local prRec = _G.PC.PR_Registry and _G.PC.PR_Registry[remote.Name]
        local schema   = prRec and prRec.ArgSchema or {}
        local category = prRec and prRec.SemanticRole or "UNKNOWN"
        AVD_Strategist.AddTarget(
            remote.Name, remote.Object, remote.Type, schema, category
        )
        count = count + 1
    end
    return count
end

-- Ingest targets from PR manifest
function AVD_Strategist.IngestFromPR()
    local registry = _G.PC.PR_Registry
    if not registry then return 0 end
    local count = 0
    for name, rec in pairs(registry) do
        if rec.RemoteType == "RemoteEvent" or rec.RemoteType == "RemoteFunction" then
            if rec.FireCount > 0 and not S_Targets[name] then
                AVD_Strategist.AddTarget(
                    name, rec.Remote, rec.RemoteType,
                    rec.ArgSchema or {}, rec.SemanticRole or "UNKNOWN"
                )
                count = count + 1
            end
        end
    end
    return count
end

-- ── Next probe request (called by Operator polling) ──────────────────────────
function AVD_Strategist.NextProbe()
    for name, plans in pairs(S_ProbePlans) do
        local target = S_Targets[name]
        if target and target.status ~= "DONE" and target.status ~= "SKIP" then
            local count = S_ProbeCount[name] or 0
            if count < #plans and count < STRATEGIST_CFG.MaxProbesPerRemote then
                local plan = plans[count + 1]
                S_ProbeCount[name] = count + 1
                local probeID = S_NextProbeID()

                -- Update target status
                if target.status == "QUEUED" then
                    target.status = (target.bestConf >= STRATEGIST_CFG.PassiveEscalateMin)
                        and "ACTIVE" or "PASSIVE"
                end

                return {
                    probeID    = probeID,
                    target     = target,
                    plan       = plan,
                }
            else
                target.status = "DONE"
            end
        end
    end
    return nil  -- nothing left to probe
end

-- ── Public API ────────────────────────────────────────────────────────────────
function AVD_Strategist.GetFindings(minScore)
    local out = {}
    for _, f in pairs(S_Findings) do
        if not minScore or f.exploitScore >= minScore then
            table.insert(out, f)
        end
    end
    table.sort(out, function(a,b) return a.exploitScore > b.exploitScore end)
    return out
end

function AVD_Strategist.GetTargetStatus()
    local s = { QUEUED=0, PASSIVE=0, ACTIVE=0, DONE=0, SKIP=0, total=0 }
    for _, t in pairs(S_Targets) do
        s[t.status] = (s[t.status] or 0) + 1
        s.total     = s.total + 1
    end
    return s
end

function AVD_Strategist.GetFindingSummary()
    local findings = AVD_Strategist.GetFindings(0)
    local s = { total=#findings, sarpReady=0, highConfidence=0 }
    for _, f in ipairs(findings) do
        if f.sarpReady           then s.sarpReady      = s.sarpReady + 1 end
        if f.confidence >= 0.75  then s.highConfidence = s.highConfidence + 1 end
    end
    return s
end

function AVD_Strategist.SaveFindings()
    if not STRATEGIST_CFG.PersistEnabled then return end
    local save = {}
    for name, f in pairs(S_Findings) do
        save[name] = {
            signal=f.signal, confidence=f.confidence,
            exploitScore=f.exploitScore, technique=f.technique,
            category=f.category, sarpReady=f.sarpReady,
        }
    end
    pcall(function() _G[STRATEGIST_CFG.PersistKey] = save end)
end

function AVD_Strategist.LoadFindings()
    pcall(function()
        local saved = _G[STRATEGIST_CFG.PersistKey]
        if type(saved) ~= "table" then return end
        for name, f in pairs(saved) do
            if not S_Findings[name] then
                S_Findings[name] = f
            end
        end
        print(string.format("[AVD Strategist] Loaded %d persisted findings.", #saved))
    end)
end

-- ── APE extension hooks ───────────────────────────────────────────────────────
-- Append additional probe plans to an existing target (used by APE).
function AVD_Strategist.AppendPlans(name, extraPlans)
    if not S_ProbePlans[name] then S_ProbePlans[name] = {} end
    for _, plan in ipairs(extraPlans) do
        table.insert(S_ProbePlans[name], plan)
    end
    -- If target was DONE, re-open it so Operator picks it up again
    if S_Targets[name] and (S_Targets[name].status == "DONE" or
                             S_Targets[name].status == "SKIP") then
        S_Targets[name].status = "QUEUED"
    end
end

-- Reset a target's probe counter and status so APE can re-run it.
function AVD_Strategist.ResetTarget(name)
    if S_Targets[name] then
        S_Targets[name].status = "QUEUED"
        S_ProbeCount[name]     = 0
    end
end

function AVD_Strategist.GetCFG()
    return STRATEGIST_CFG
end

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.AVD then _G.PC.AVD = {} end
_G.PC.AVD.Strategist = AVD_Strategist

AVD_Strategist.LoadFindings()
print("[AVD Strategist] Ready.")
