-- ── Imports ──────────────────────────────────────────────────────────────────
local _C         = _G.PC
local Registry   = _G.PC.TSR.Registry

-- ============================================================
-- TSR BINDER — Binding Discovery & Verification Engine
-- Consumes AVD findings + PR schema data and attempts to
-- bind each unbound Intent to a confirmed remote+payload.
-- Runs three verification strategies:
--   LinearityProbe      — for Direct/Linear numeric intents
--   InvariantStateProbe — for Categorical/compound intents
--   ToggleProbe         — for Boolean intents
-- Performs Causal Pruning on Compound intents to detect
-- leaky servers and downgrade to Atomic where possible.
-- ============================================================

local BINDER_CFG = {
    -- Calibration values used during LinearityProbe
    LinearCalibrationValues = { 10, 50, 100 },
    -- Tolerance for linearity check (ratio must be within this of expected)
    LinearTolerance         = 0.15,
    -- How long to observe after a calibration fire (seconds)
    ObservationWindow       = 3.5,
    -- How many AVD findings to consider per intent
    MaxCandidatesPerIntent  = 5,
    -- Min AVD confidence to attempt binding
    MinAVDConfidence        = 0.55,
    -- Delay between calibration probes (seconds)
    CalibrationDelay        = 1.2,
    -- Max concurrent binding attempts
    MaxConcurrent           = 2,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local TSR_Binder = {}

local B_Running       = false
local B_ActiveCount   = 0
local B_TotalAttempts = 0
local B_TotalBound    = 0
local B_Queue         = {}   -- { intent, candidate } pairs to verify
local B_InProgress    = {}   -- [intentName] = true

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Resolve a WatchTarget path to an actual instance value
local function B_ReadWatchTarget(targetPath)
    -- targetPath examples:
    --   "Character.Humanoid.WalkSpeed"
    --   "PlayerData.Currency"
    --   "leaderstats.Coins"
    local player = _C.player
    if not player then return nil end

    local roots = {
        Character  = player.Character,
        PlayerData = player:FindFirstChild("PlayerData") or
                     player:FindFirstChild("Data"),
        leaderstats= player:FindFirstChild("leaderstats"),
        Players    = _C.Players,
        Workspace  = _C.Workspace,
        ReplicatedStorage = _C.ReplicatedStorage,
    }

    local parts = targetPath:split(".")
    local root  = parts[1]
    local cur   = roots[root]
    if not cur then return nil end

    for i = 2, #parts do
        local seg = parts[i]
        if seg == "*" then break end  -- wildcard — return parent
        local ok, child = pcall(function()
            return cur:FindFirstChild(seg) or (cur[seg] ~= nil and {value=cur[seg]}) or nil
        end)
        if not ok or not child then return nil end
        -- If it's an instance, descend; if it's a property table, extract
        if typeof(child) == "Instance" then
            cur = child
        elseif type(child) == "table" and child.value ~= nil then
            return child.value
        else
            cur = child
        end
    end

    -- Try to read .Value for value objects
    if typeof(cur) == "Instance" then
        local ok, val = pcall(function() return cur.Value end)
        if ok then return val end
        -- Return the instance itself as a proxy for "exists"
        return cur
    end
    return cur
end

-- Read the first resolvable WatchTarget from an intent's list
local function B_ReadIntent(intent)
    for _, target in ipairs(intent.WatchTargets or {}) do
        local val = B_ReadWatchTarget(target)
        if val ~= nil then return val, target end
    end
    return nil, nil
end

-- Fire a probe via AVD Operator with a synthetic plan
local function B_FireProbe(remoteName, remoteObj, remoteType, args, probeKind)
    local operator   = _C.AVD and _C.AVD.Operator
    local translator = _C.AVD and _C.AVD.Translator
    if not operator or not translator then return nil end

    local probeID = "TSR_" .. remoteName .. "_" .. tostring(os.clock())
    local fireTime = os.clock()

    translator.RegisterProbe(probeID, {
        remoteName = remoteName,
        remoteType = remoteType,
        channel    = "TSR_Binder",
        probeKind  = probeKind or "TSR_Calibration",
        probeArgs  = args,
        probeTime  = fireTime,
    })

    -- Fire directly
    local ok = false
    if remoteType == "RemoteEvent" then
        ok = pcall(function() remoteObj:FireServer(table.unpack(args)) end)
    elseif remoteType == "RemoteFunction" then
        ok = pcall(function() remoteObj:InvokeServer(table.unpack(args)) end)
    end

    -- Wait for observation window
    task.wait(BINDER_CFG.ObservationWindow)

    -- Get the resolved report
    local report = translator.Resolve(probeID)
    return report, ok
end

-- Build an argument list from an AVD finding's probeArgs + intent parameter map
local function B_BuildArgs(intent, finding, overrideParam, overrideValue)
    local args = {}
    if finding and finding.probeArgs then
        for i, v in ipairs(finding.probeArgs) do
            args[i] = v
        end
    else
        -- Build from intent parameter defaults
        for i, param in ipairs(intent.Parameters or {}) do
            if param.kind == "number"  then args[i] = 1
            elseif param.kind == "string"  then args[i] = "test"
            elseif param.kind == "boolean" then args[i] = true
            elseif param.kind == "Vector3" then args[i] = Vector3.new()
            end
        end
    end

    -- Override a specific parameter by name
    if overrideParam and overrideValue ~= nil then
        for i, param in ipairs(intent.Parameters or {}) do
            if param.name == overrideParam then
                args[i] = overrideValue
                break
            end
        end
    end

    return args
end

-- ── VERIFICATION STRATEGY 1: LinearityProbe ──────────────────────────────────
-- For Direct/Linear numeric intents.
-- Fires the remote with 2-3 calibration values and checks if the
-- WatchTarget changes proportionally.
-- Also detects SanityCap (max value the server will accept).

local function B_LinearityProbe(intent, candidate)
    local remoteName = candidate.remoteName
    local remoteObj  = candidate.remoteObj
    local remoteType = candidate.remoteType
    local finding    = candidate.finding

    -- Find the numeric parameter to probe
    local numParamName = nil
    for _, param in ipairs(intent.Parameters or {}) do
        if param.kind == "number" then numParamName = param.name; break end
    end
    if not numParamName then return nil end

    local calValues  = BINDER_CFG.LinearCalibrationValues
    local results    = {}  -- { inputVal, observedVal }
    local sanityMax  = nil

    for _, calVal in ipairs(calValues) do
        local args     = B_BuildArgs(intent, finding, numParamName, calVal)
        local before   = B_ReadIntent(intent)
        local report   = B_FireProbe(remoteName, remoteObj, remoteType, args, "LinearityProbe")
        local after    = B_ReadIntent(intent)

        task.wait(BINDER_CFG.CalibrationDelay)

        if type(before) == "number" and type(after) == "number" then
            local delta = after - before
            table.insert(results, { input=calVal, delta=delta, after=after })
            -- Sanity cap detection: if a larger value produces the same delta as a smaller
            if #results >= 2 then
                local prev = results[#results - 1]
                if math.abs(delta) <= math.abs(prev.delta) * 0.1 and calVal > prev.input then
                    sanityMax = prev.input
                end
            end
        elseif type(after) == "number" and type(before) ~= "number" then
            -- First measurement — just record
            table.insert(results, { input=calVal, delta=0, after=after })
        end
    end

    if #results < 2 then return nil end

    -- Check linearity: input ratio should match output ratio within tolerance
    local r1, r2    = results[1], results[2]
    local confirmed = false
    local confidence= 0

    if r1.delta ~= 0 and r2.delta ~= 0 then
        local inputRatio  = r2.input / r1.input
        local outputRatio = r2.delta / r1.delta
        local ratio       = math.abs(outputRatio / inputRatio - 1)
        if ratio <= BINDER_CFG.LinearTolerance then
            confirmed  = true
            confidence = 0.80 + math.min(0.18, (1 - ratio) * 0.2)
        end
    elseif r2.after ~= nil and r2.after == r2.input then
        -- Direct assignment confirmed
        confirmed  = true
        confidence = 0.85
    end

    -- Find the numeric param slot index for argMap
    local argMap = {}
    for i, param in ipairs(intent.Parameters or {}) do
        argMap[param.name] = i
    end

    return confirmed and {
        confirmed   = true,
        confidence  = confidence,
        argMap      = argMap,
        sanityMin   = 0,
        sanityMax   = sanityMax,
        calibration = results,
        strategy    = "LinearityProbe",
    } or nil
end

-- ── VERIFICATION STRATEGY 2: InvariantStateProbe ─────────────────────────────
-- For Categorical/Compound intents.
-- Fires the remote and checks if the WatchTarget changed at all.
-- For Compound intents, performs Causal Pruning first.

local function B_InvariantStateProbe(intent, candidate)
    local remoteName = candidate.remoteName
    local remoteObj  = candidate.remoteObj
    local remoteType = candidate.remoteType
    local finding    = candidate.finding
    local args       = B_BuildArgs(intent, finding)

    -- Snapshot WatchTargets before
    local snapBefore = {}
    for _, target in ipairs(intent.WatchTargets or {}) do
        local val = B_ReadWatchTarget(target)
        snapBefore[target] = val
    end

    local report = B_FireProbe(remoteName, remoteObj, remoteType, args, "InvariantStateProbe")

    -- Snapshot after
    local snapAfter = {}
    local changed   = false
    for _, target in ipairs(intent.WatchTargets or {}) do
        local val = B_ReadWatchTarget(target)
        snapAfter[target] = val
        if snapBefore[target] ~= val then changed = true end
    end

    if not changed and (not report or report.signal == "SILENT") then
        return nil
    end

    -- Build argMap
    local argMap = {}
    for i, param in ipairs(intent.Parameters or {}) do
        argMap[param.name] = i
    end

    local confidence = (report and report.confidence) or (changed and 0.70) or 0.55
    return {
        confirmed  = true,
        confidence = confidence,
        argMap     = argMap,
        strategy   = "InvariantStateProbe",
        snapBefore = snapBefore,
        snapAfter  = snapAfter,
    }
end

-- ── CAUSAL PRUNING for Compound intents ──────────────────────────────────────
-- Attempts to fire only the final step of a compound chain.
-- If the final step succeeds alone, the server is leaky and the
-- intent can be downgraded to Atomic.

local function B_CausalPrune(intent, candidate, chainMap)
    if intent.Type ~= "Compound" or not intent.CausalPruning then
        return false, chainMap
    end

    local steps    = intent.Steps or {}
    if #steps < 2  then return false, chainMap end

    local finalStep     = steps[#steps]
    local finalRemote   = chainMap[finalStep.ActionID]
    if not finalRemote  then return false, chainMap end

    local remoteRec = _C.PR_Registry and _C.PR_Registry[finalRemote]
    if not remoteRec then return false, chainMap end

    -- Try firing only the final step
    local args   = B_BuildArgs(intent, candidate.finding)

    local snapBefore = {}
    for _, target in ipairs(intent.WatchTargets or {}) do
        snapBefore[target] = B_ReadWatchTarget(target)
    end

    pcall(function()
        if remoteRec.RemoteType == "RemoteEvent" then
            remoteRec.Remote:FireServer(table.unpack(args))
        elseif remoteRec.RemoteType == "RemoteFunction" then
            remoteRec.Remote:InvokeServer(table.unpack(args))
        end
    end)
    task.wait(BINDER_CFG.ObservationWindow)

    -- Check if state changed
    local leaky = false
    for _, target in ipairs(intent.WatchTargets or {}) do
        local after = B_ReadWatchTarget(target)
        if snapBefore[target] ~= after then
            leaky = true; break
        end
    end

    if leaky then
        print(string.format("[TSR Binder] Causal Pruning: %s is leaky — downgrading to Atomic via %s",
            intent.Intent, finalRemote))
        -- Return a simplified single-remote chainMap
        return true, { [finalStep.ActionID] = finalRemote }
    end

    return false, chainMap
end

-- ── VERIFICATION STRATEGY 3: ToggleProbe ─────────────────────────────────────
-- For Boolean intents.
-- Fires with true, observes, fires with false, observes.
-- Confirms if WatchTarget changes in both directions.

local function B_ToggleProbe(intent, candidate)
    local remoteName = candidate.remoteName
    local remoteObj  = candidate.remoteObj
    local remoteType = candidate.remoteType
    local finding    = candidate.finding

    -- Find the boolean parameter
    local boolParamName = nil
    for _, param in ipairs(intent.Parameters or {}) do
        if param.kind == "boolean" then boolParamName = param.name; break end
    end

    local results = {}
    for _, val in ipairs({true, false}) do
        local args   = B_BuildArgs(intent, finding,
            boolParamName, boolParamName and val or nil)
        local before = B_ReadIntent(intent)
        B_FireProbe(remoteName, remoteObj, remoteType, args, "ToggleProbe")
        local after  = B_ReadIntent(intent)
        table.insert(results, { val=val, before=before, after=after, changed=before~=after })
        task.wait(BINDER_CFG.CalibrationDelay)
    end

    local confirmed = results[1].changed or results[2].changed
    local bothChanged = results[1].changed and results[2].changed
    local confidence  = bothChanged and 0.88 or (confirmed and 0.68) or 0

    if not confirmed then return nil end

    local argMap = {}
    for i, param in ipairs(intent.Parameters or {}) do argMap[param.name] = i end

    return {
        confirmed  = true,
        confidence = confidence,
        argMap     = argMap,
        strategy   = "ToggleProbe",
        bothToggled= bothChanged,
    }
end

-- ── Candidate builder ─────────────────────────────────────────────────────────
-- Pulls AVD findings and PR registry entries that could satisfy an intent,
-- then ranks them by confidence.

local function B_BuildCandidates(intent)
    local candidates = {}
    local strategist = _C.AVD and _C.AVD.Strategist
    local prRegistry = _C.PR_Registry

    -- From AVD findings
    if strategist then
        local findings = strategist.GetFindings(BINDER_CFG.MinAVDConfidence)
        for _, f in ipairs(findings) do
            -- Match by WatchTarget overlap
            local prRec = prRegistry and prRegistry[f.remoteName]
            if prRec and prRec.Remote then
                -- Score by: AVD confidence + WatchTarget path overlap
                local score = f.confidence
                for _, target in ipairs(intent.WatchTargets or {}) do
                    local stem = target:split(".")[1]
                    if f.remoteName:lower():find(stem:lower()) or
                       (prRec.SemanticRole or ""):lower():find(
                           intent.Category:lower():sub(1,5)) then
                        score = score + 0.10
                    end
                end
                for _, path in ipairs(f.affectedPaths or {}) do
                    for _, target in ipairs(intent.WatchTargets or {}) do
                        if path:find(target:split(".")[2] or "") then
                            score = score + 0.15
                        end
                    end
                end
                table.insert(candidates, {
                    remoteName = f.remoteName,
                    remoteObj  = prRec.Remote,
                    remoteType = prRec.RemoteType,
                    finding    = f,
                    score      = score,
                    source     = "AVD",
                })
            end
        end
    end

    -- From PR registry (semantic role matching)
    if prRegistry then
        local intentLower = intent.Intent:lower()
        for name, rec in pairs(prRegistry) do
            if rec.Remote and rec.RemoteType ~= "BindableEvent" then
                local nameLower = name:lower()
                local roleLower = (rec.SemanticRole or ""):lower()
                local catLower  = intent.Category:lower()

                local score = 0
                -- Name heuristics
                if nameLower:find(intentLower:sub(1,6)) then score = score + 0.30 end
                if roleLower:find(catLower:sub(1,4)) then score = score + 0.20 end
                -- Category heuristics
                if intent.Category == "Economy" and
                   (nameLower:find("currency") or nameLower:find("coin") or
                    nameLower:find("cash")     or nameLower:find("item") or
                    nameLower:find("reward")   or nameLower:find("give")) then
                    score = score + 0.25
                end
                if intent.Category == "CharacterPhysical" and
                   (nameLower:find("speed")   or nameLower:find("move") or
                    nameLower:find("jump")     or nameLower:find("tele") or
                    nameLower:find("fly")      or nameLower:find("tp")) then
                    score = score + 0.25
                end
                if intent.Category == "CharacterState" and
                   (nameLower:find("health")  or nameLower:find("hp") or
                    nameLower:find("mana")    or nameLower:find("stamina") or
                    nameLower:find("revive")  or nameLower:find("buff")) then
                    score = score + 0.25
                end

                if score >= 0.20 then
                    -- Avoid duplicates with AVD candidates
                    local dup = false
                    for _, c in ipairs(candidates) do
                        if c.remoteName == name then dup=true; break end
                    end
                    if not dup then
                        table.insert(candidates, {
                            remoteName = name,
                            remoteObj  = rec.Remote,
                            remoteType = rec.RemoteType,
                            finding    = nil,
                            score      = score,
                            source     = "PR",
                        })
                    end
                end
            end
        end
    end

    -- Sort by score descending
    table.sort(candidates, function(a,b) return a.score > b.score end)

    -- Cap
    local out = {}
    for i = 1, math.min(#candidates, BINDER_CFG.MaxCandidatesPerIntent) do
        table.insert(out, candidates[i])
    end
    return out
end

-- ── Chain map builder for compound intents ────────────────────────────────────
-- Attempts to map each Step.ActionID to a remote in the PR registry
local function B_BuildChainMap(intent, topCandidate)
    if intent.Type ~= "Compound" then return nil end
    local prRegistry = _C.PR_Registry
    if not prRegistry then return nil end

    local chainMap = {}
    for _, step in ipairs(intent.Steps or {}) do
        local bestName  = nil
        local bestScore = 0
        local stepLow   = step.ActionID:lower()
        for name, rec in pairs(prRegistry) do
            if rec.Remote then
                local score = 0
                local nLow  = name:lower()
                -- Match ActionID fragments
                for _, frag in ipairs(stepLow:split("_")) do
                    if nLow:find(frag) then score = score + 0.2 end
                end
                if score > bestScore then
                    bestScore = score
                    bestName  = name
                end
            end
        end
        -- Fallback: use top candidate for all steps
        chainMap[step.ActionID] = bestName or topCandidate.remoteName
    end
    return chainMap
end

-- ── Core binding attempt ──────────────────────────────────────────────────────
local function B_AttemptBind(intent)
    if B_InProgress[intent.Intent] then return end
    B_InProgress[intent.Intent] = true
    B_ActiveCount  = B_ActiveCount + 1
    B_TotalAttempts = B_TotalAttempts + 1

    local function finish()
        B_InProgress[intent.Intent] = nil
        B_ActiveCount = math.max(0, B_ActiveCount - 1)
    end

    local candidates = B_BuildCandidates(intent)
    if #candidates == 0 then
        finish(); return
    end

    for _, candidate in ipairs(candidates) do
        local result = nil
        local verification = intent.Verification

        if verification == Registry.VERIFY.LinearityProbe then
            result = B_LinearityProbe(intent, candidate)
        elseif verification == Registry.VERIFY.ToggleProbe then
            result = B_ToggleProbe(intent, candidate)
        else
            result = B_InvariantStateProbe(intent, candidate)
        end

        if result and result.confirmed then
            -- Handle compound chain map + causal pruning
            local chainMap = nil
            local isLeaky  = false
            if intent.Type == "Compound" then
                chainMap = B_BuildChainMap(intent, candidate)
                if chainMap then
                    isLeaky, chainMap = B_CausalPrune(intent, candidate, chainMap)
                end
            end

            -- Commit binding to Registry
            local bound = Registry.Bind(intent.Intent, {
                remoteName   = candidate.remoteName,
                remoteObj    = candidate.remoteObj,
                remoteType   = candidate.remoteType,
                argMap       = result.argMap,
                chainMap     = chainMap,
                confidence   = result.confidence,
                sanityMin    = result.sanityMin,
                sanityMax    = result.sanityMax,
                strategy     = result.strategy,
                wasLeaky     = isLeaky,
                source       = candidate.source,
            })

            if bound then
                B_TotalBound = B_TotalBound + 1
                print(string.format("[TSR Binder] ✓ Bound %s → %s [%s] conf=%.2f%s",
                    intent.Intent, candidate.remoteName, result.strategy,
                    result.confidence, isLeaky and " (leaky→atomic)" or ""))
                finish(); return
            end
        end

        task.wait(0.3)  -- brief pause between candidates
    end

    finish()
end

-- ── Binding queue loop ────────────────────────────────────────────────────────
local function B_ProcessQueue()
    while B_Running do
        if B_ActiveCount < BINDER_CFG.MaxConcurrent and #B_Queue > 0 then
            local item = table.remove(B_Queue, 1)
            if item and not Registry.IsBound(item.Intent) then
                task.spawn(B_AttemptBind, item)
            end
        end
        task.wait(0.5)
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Start the binder — queues all unbound intents
function TSR_Binder.Start()
    if B_Running then return end
    B_Running = true

    task.spawn(function()
        -- ── Guard 1: wait for the full AVD module stack to be registered ─────
        -- avd_strategist.lua sets _G.PC.AVD.Strategist at the bottom of its
        -- file, after LoadFindings(). Since chunk load order is sequential but
        -- task.spawns from earlier chunks may still be in flight, we poll until
        -- the Strategist, Translator, and Operator are all present.
        local avdWaitStart = os.clock()
        local AVD_TIMEOUT  = 15.0
        while true do
            local avd = _C.AVD
            if avd and avd.Sentry and avd.Translator and avd.Strategist and avd.Operator then
                break
            end
            if os.clock() - avdWaitStart > AVD_TIMEOUT then
                warn("[TSR Binder] AVD stack not ready after " .. AVD_TIMEOUT .. "s — proceeding without AVD data.")
                break
            end
            task.wait(0.25)
        end

        -- ── Guard 2: wait for Sentry baseline window to close ─────────────────
        local sentry = _C.AVD and _C.AVD.Sentry
        if sentry then
            while not sentry.IsBaselineDone() do task.wait(0.5) end
        end

        -- ── Guard 3: wait for Strategist to have at least attempted a scan ────
        -- GetFindings() returns an empty table until the Strategist has processed
        -- at least one Translator report. Give it a brief grace window.
        local strategist = _C.AVD and _C.AVD.Strategist
        if strategist then
            local graceStart = os.clock()
            while #strategist.GetFindings(0) == 0 and (os.clock() - graceStart) < 5.0 do
                task.wait(0.5)
            end
        end

        task.wait(1.0)

        -- Enqueue all unbound intents
        local unbound = Registry.GetUnbound()
        for _, intent in ipairs(unbound) do
            table.insert(B_Queue, intent)
        end
        print(string.format("[TSR Binder] Queued %d unbound intents.", #B_Queue))

        B_ProcessQueue()
    end)

    print("[TSR Binder] Started.")
end

function TSR_Binder.Stop()
    B_Running = false
    B_Queue   = {}
    print("[TSR Binder] Stopped.")
end

-- Force-queue a specific intent for immediate binding
function TSR_Binder.BindIntent(intentName)
    local intent = Registry.GetIntent(intentName)
    if not intent then
        warn("[TSR Binder] Unknown intent: " .. intentName)
        return
    end
    if Registry.IsBound(intentName) then
        print("[TSR Binder] Already bound: " .. intentName)
        return
    end
    table.insert(B_Queue, 1, intent)  -- priority insert
end

-- Re-queue all unbound intents (call after new AVD findings arrive)
function TSR_Binder.RefreshQueue()
    local unbound = Registry.GetUnbound()
    local added   = 0
    for _, intent in ipairs(unbound) do
        -- Don't re-add what's already queued or in progress
        local alreadyQueued = false
        for _, q in ipairs(B_Queue) do
            if q.Intent == intent.Intent then alreadyQueued=true; break end
        end
        if not alreadyQueued and not B_InProgress[intent.Intent] then
            table.insert(B_Queue, intent)
            added = added + 1
        end
    end
    print(string.format("[TSR Binder] Refresh: %d intents added to queue.", added))
    return added
end

function TSR_Binder.GetStats()
    return {
        Running       = B_Running,
        QueueLength   = #B_Queue,
        ActiveCount   = B_ActiveCount,
        TotalAttempts = B_TotalAttempts,
        TotalBound    = B_TotalBound,
        InProgress    = (function()
            local n=0; for _ in pairs(B_InProgress) do n=n+1 end; return n
        end)(),
    }
end

function TSR_Binder.GetCFG()
    return BINDER_CFG
end

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.TSR then _G.PC.TSR = {} end
_G.PC.TSR.Binder = TSR_Binder

print("[TSR Binder] Ready.")
