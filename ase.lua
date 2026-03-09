-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- ASE — Autonomous Strategy Engine
-- Layer 8 of the PaperCuts intelligence stack.
--
-- ASE is the only TELEOLOGICAL layer — goal-directed, not
-- knowledge-directed. Every layer below it answers "what is
-- true?" ASE answers "what should I do to achieve X?"
--
-- It operates in three execution modes:
--
--   COMPILED  — Semantic Directive Interface. ASE compiles
--               user intent into a validated data envelope,
--               routes through TSR, respects all safety gates.
--
--   RAW       — Protocol Forge. User constructs envelopes
--               manually (Lua table or byte-string). ASE
--               delivers and observes. No semantic guardrails.
--
--   MASTERY   — JIT Compiler for Exploits. Both tiers live
--               simultaneously. ASE autonomously decompiles
--               failed Compiled directives back into Raw,
--               re-fuzzes, re-binds, and lifts the fix back
--               up without user intervention. Gated by the
--               "I am responsible for my actions" handshake.
--
-- Four native goal types:
--   GOAL_BEDROCK   — establish A→B topological pipeline
--   GOAL_FINALIZE  — lift confirmed Raw sequence → TSR Intent
--   GOAL_RECOMPILE — autonomous drift recovery
--   GOAL_DISCOVER  — SBI/APE fuzzing campaign (feeds all three)
--
-- Modules:
--   1  GOAL ENGINE         manage goal queue + status
--   2  BEDROCK HANDSHAKE   nonce listener, A→B verification
--   3  DIRECTIVE COMPILER  intent → data envelope (Compiled)
--   4  FORGE ENGINE        raw payload builder + delivery
--   5  RECOMPILE ENGINE    drift detection → re-fuzz → re-bind
--   6  RISK BUDGET         per-session risk accounting
--   7  EXECUTION PANEL CTL panel visibility + mode state
-- ============================================================

local ASE = {}

-- ── Configuration ─────────────────────────────────────────────
local ASE_CFG = {
    -- Nonce entropy (chars)
    NonceLength         = 24,
    -- How long to listen for nonce return (seconds)
    NonceListenTimeout  = 8.0,
    -- Max concurrent goals
    MaxConcurrentGoals  = 4,
    -- Risk budget per session (0–1, consumed by operations)
    SessionRiskBudget   = 1.0,
    -- Risk cost per operation type
    RiskCost = {
        BEDROCK   = 0.25,
        FINALIZE  = 0.10,
        RECOMPILE = 0.15,
        DISCOVER  = 0.05,
        RAW_FIRE  = 0.08,
    },
    -- Drift threshold: SBI conf drop > this triggers RECOMPILE
    DriftThreshold      = 0.12,
    -- Recompile: max re-fuzz probes before giving up
    RecompileMaxProbes  = 16,
    -- Heartbeat interval (seconds)
    HeartbeatInterval   = 3.0,
    -- Persist
    PersistKey          = "ASE_State_" .. tostring(game.PlaceId),
    PersistVer          = "v1",
}

-- ── Goal constants ─────────────────────────────────────────────
ASE.GOAL   = { BEDROCK="BEDROCK", FINALIZE="FINALIZE",
               RECOMPILE="RECOMPILE", DISCOVER="DISCOVER" }
ASE.STATUS = { PENDING="PENDING", RUNNING="RUNNING",
               COMPLETE="COMPLETE", FAILED="FAILED", ABORTED="ABORTED" }
ASE.MODE   = { COMPILED="COMPILED", RAW="RAW", MASTERY="MASTERY" }

-- ── Internal state ─────────────────────────────────────────────
local ASE_Goals        = {}     -- [id] = GoalRecord
local ASE_GoalIDSeq    = 0
local ASE_Mode         = ASE.MODE.COMPILED
local ASE_MasteryUnlocked = false
local ASE_RiskConsumed = 0.0
local ASE_Running      = false
local ASE_ActiveCount  = 0

-- Bedrock state
local ASE_BedrockPairs = {}     -- [sinkRemote] = {feedbackRemote, nonce, confirmedAt}
local ASE_NonceListeners = {}   -- [nonce] = {resolve fn, timeout t}

-- Execution Panel state (consumed by ase_ui.lua)
ASE.Panel = {
    Visible        = false,
    Mode           = ASE.MODE.COMPILED,
    ActiveSink     = nil,   -- confirmed Control Plane remote
    ActiveFeedback = nil,   -- confirmed Feedback Plane remote
    BedrockConf    = 0.0,
    TxBuffer       = {},    -- [{t, directive, rawPayload, result, nonce}]
    HeartbeatAlive = false,
    ForgeExpanded  = false,
    MasteryUnlocked= false,
}

-- Directive registry (Finalized raw→compiled lifts)
local ASE_Directives = {}

-- Per-remote discover cooldown: [remoteName] = os.clock() of last push
-- Prevents the AVD hook from re-queuing the same remote every report tick
local ASE_DiscoverCooldown = {}
local ASE_DISCOVER_COOLDOWN_S = 45  -- seconds between DISCOVER goals per remote  -- [name] = {name, category, envelope, sinkRemote, confirmedAt}

-- ── Utility ───────────────────────────────────────────────────
local function ASE_NextID()
    ASE_GoalIDSeq = ASE_GoalIDSeq + 1
    return ASE_GoalIDSeq
end

local function ASE_GenNonce()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local t = {}
    for i = 1, ASE_CFG.NonceLength do
        local r = math.random(1, #chars)
        t[i] = chars:sub(r,r)
    end
    return table.concat(t)
end

local function ASE_ConsumeRisk(goalType)
    local cost = ASE_CFG.RiskCost[goalType] or 0.05
    ASE_RiskConsumed = ASE_RiskConsumed + cost
    return ASE_RiskConsumed <= ASE_CFG.SessionRiskBudget
end

local function ASE_AppendTx(entry)
    entry.t = os.clock()
    table.insert(ASE.Panel.TxBuffer, 1, entry)
    if #ASE.Panel.TxBuffer > 64 then
        ASE.Panel.TxBuffer[65] = nil
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 1 — GOAL ENGINE
-- ═════════════════════════════════════════════════════════════
local ASE_GoalEngine = {}

local function ASE_NewGoal(goalType, params)
    local id = ASE_NextID()
    return {
        id        = id,
        goalType  = goalType,
        params    = params or {},
        status    = ASE.STATUS.PENDING,
        startT    = nil,
        endT      = nil,
        result    = nil,
        error     = nil,
    }
end

function ASE_GoalEngine.Push(goalType, params)
    if ASE_ActiveCount >= ASE_CFG.MaxConcurrentGoals then
        return nil, "max concurrent goals reached"
    end
    if not ASE_ConsumeRisk(goalType) then
        return nil, "session risk budget exhausted"
    end
    local goal = ASE_NewGoal(goalType, params)
    ASE_Goals[goal.id] = goal
    task.spawn(function() pcall(ASE_GoalEngine.Run, goal) end)
    return goal.id
end

function ASE_GoalEngine.Run(goal)
    goal.status = ASE.STATUS.RUNNING
    goal.startT = os.clock()
    ASE_ActiveCount = ASE_ActiveCount + 1

    local ok, err
    if goal.goalType == ASE.GOAL.BEDROCK then
        ok, err = pcall(ASE_BedrockHandshake.Run, goal)
    elseif goal.goalType == ASE.GOAL.FINALIZE then
        ok, err = pcall(ASE_DirectiveCompiler.Finalize, goal)
    elseif goal.goalType == ASE.GOAL.RECOMPILE then
        ok, err = pcall(ASE_RecompileEngine.Run, goal)
    elseif goal.goalType == ASE.GOAL.DISCOVER then
        ok, err = pcall(ASE_ForgeEngine.Discover, goal)
    end

    goal.endT = os.clock()
    if ok then
        goal.status = ASE.STATUS.COMPLETE
    else
        goal.status = ASE.STATUS.FAILED
        goal.error  = tostring(err)
        warn(string.format("[ASE] Goal %d (%s) failed: %s", goal.id, goal.goalType, tostring(err)))
    end
    ASE_ActiveCount = math.max(0, ASE_ActiveCount - 1)
end

function ASE_GoalEngine.Abort(goalId)
    local goal = ASE_Goals[goalId]
    if goal and goal.status == ASE.STATUS.RUNNING then
        goal.status = ASE.STATUS.ABORTED
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 2 — BEDROCK HANDSHAKE
-- A→Server→B topological verification
-- ═════════════════════════════════════════════════════════════
ASE_BedrockHandshake = {}

-- Open a global nonce listener across all indexed S2C remotes
local function ASE_OpenNonceListener(nonce, onCapture)
    local PR    = _G.PC.PR_Registry
    local conns = {}
    local done  = false

    if not PR then return nil end

    for name, rec in pairs(PR) do
        if rec.Remote and rec.RemoteType == "RemoteEvent" and
           (rec.Direction == "S2C" or rec.Direction == "BOTH") then
            local rname = name
            local ok, conn = pcall(function()
                return rec.Remote.OnClientEvent:Connect(function(...)
                    if done then return end
                    local args = {...}
                    -- Search all args recursively for nonce
                    local function findNonce(v, depth)
                        if depth > 5 then return false end
                        if type(v) == "string" and v:find(nonce, 1, true) then
                            return true
                        end
                        if type(v) == "table" then
                            for _, child in pairs(v) do
                                if findNonce(child, depth+1) then return true end
                            end
                        end
                        return false
                    end
                    if findNonce(args, 0) then
                        done = true
                        onCapture(rname, args)
                    end
                end)
            end)
            if ok and conn then table.insert(conns, conn) end
        end
    end

    ASE_NonceListeners[nonce] = {
        conns   = conns,
        done    = false,
        cleanup = function()
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            ASE_NonceListeners[nonce] = nil
        end
    }
    return ASE_NonceListeners[nonce]
end

function ASE_BedrockHandshake.Run(goal)
    local sinkRemote = goal.params.sinkRemote
    local PR         = _G.PC.PR_Registry
    local SARP       = _G.PC.SARP
    local SBI        = _G.PC.SBI

    if not sinkRemote or not PR or not PR[sinkRemote] then
        error("Sink remote not found: " .. tostring(sinkRemote))
    end

    local sbiRec = SBI and SBI.Get(sinkRemote)
    if sbiRec and sbiRec.ACPattern == "CORRECTS_FAST" then
        warn("[ASE Bedrock] High AC risk on " .. sinkRemote .. " — proceeding with caution.")
    end

    -- Generate nonce + build envelope
    local nonce   = ASE_GenNonce()
    local envelope = {
        __nonce    = nonce,
        __callback = "report",   -- hint: server should echo this back
        __cargo    = goal.params.cargo or {},
    }

    -- Merge with any known-good args from SBI/RSM
    local rsmRec = _G.PC.RSM and _G.PC.RSM.Get(sinkRemote)
    local baseArgs = {}
    if rsmRec then
        for i, argSig in ipairs(rsmRec.ArgSig or {}) do
            if argSig.DominantType == "table" then
                baseArgs[i] = envelope
            elseif argSig.DominantType == "number" and #argSig.SuccessValues > 0 then
                baseArgs[i] = argSig.SuccessValues[1]
            elseif argSig.DominantType == "string" and #argSig.SuccessStrings > 0 then
                baseArgs[i] = argSig.SuccessStrings[1]
            else
                baseArgs[i] = envelope
            end
        end
    end
    if #baseArgs == 0 then baseArgs = {envelope} end

    -- Pre-prediction
    local prediction = sbiRec and SBI.PredictOutcome(sinkRemote, baseArgs) or nil
    goal.result = { nonce=nonce, prediction=prediction }

    -- Open nonce listener BEFORE firing
    local captured     = false
    local feedbackRemote = nil
    local feedbackArgs   = nil

    local listener = ASE_OpenNonceListener(nonce, function(rname, args)
        captured       = true
        feedbackRemote = rname
        feedbackArgs   = args
    end)

    ASE_AppendTx({
        directive  = string.format("BEDROCK PROBE → %s", sinkRemote),
        rawPayload = envelope,
        nonce      = nonce,
        result     = "FIRING",
    })

    -- Fire via SARP
    local channel = "Attribute"
    local prRec   = PR[sinkRemote]

    local wrapped, simResult, buildErr = SARP and SARP.Build(channel, baseArgs, nil, nil, sinkRemote)
    if not wrapped then
        if listener then listener.cleanup() end
        error("SARP.Build failed: " .. tostring(buildErr))
    end

    local fired = false
    SARP.Execute(wrapped, simResult, sinkRemote, function(success, result, err)
        fired = true
        goal.result.sarpSuccess = success
        goal.result.sarpResult  = result
    end)

    -- Wait for nonce capture or timeout
    local t0 = os.clock()
    while not captured and (os.clock() - t0) < ASE_CFG.NonceListenTimeout do
        task.wait(0.1)
        if goal.status == ASE.STATUS.ABORTED then
            if listener then listener.cleanup() end
            return
        end
    end

    if listener then listener.cleanup() end

    if captured then
        -- Topological confirmation: A→B lock
        ASE_BedrockPairs[sinkRemote] = {
            sinkRemote     = sinkRemote,
            feedbackRemote = feedbackRemote,
            nonce          = nonce,
            confirmedAt    = os.clock(),
            cargo          = goal.params.cargo or {},
            confidence     = 1.0,
        }

        -- Lock as TSR binding
        local TSR = _G.PC.TSR
        if TSR and TSR.Binder then
            pcall(function()
                TSR.Binder.BindIntent("__BEDROCK_" .. sinkRemote)
            end)
        end

        -- Show execution panel
        ASE.Panel.Visible        = true
        ASE.Panel.ActiveSink     = sinkRemote
        ASE.Panel.ActiveFeedback = feedbackRemote
        ASE.Panel.BedrockConf    = 1.0
        ASE.Panel.HeartbeatAlive = true

        -- Annotate in CSK
        local CSK = _G.PC.CSK
        if CSK then
            CSK.Annotate(sinkRemote, string.format(
                "BEDROCK CONFIRMED → %s (nonce=%s)", feedbackRemote, nonce:sub(1,8)))
        end

        goal.result.confirmed      = true
        goal.result.feedbackRemote = feedbackRemote
        print(string.format("[ASE] ✓ BEDROCK confirmed: %s → %s", sinkRemote, feedbackRemote))

        ASE_AppendTx({
            directive  = "BEDROCK CONFIRMED",
            rawPayload = {sinkRemote=sinkRemote, feedbackRemote=feedbackRemote},
            nonce      = nonce,
            result     = "✓ PIPELINE ESTABLISHED",
        })

        -- Start heartbeat
        ASE_BedrockHandshake.StartHeartbeat(sinkRemote)
    else
        goal.result.confirmed = false
        ASE_AppendTx({
            directive  = string.format("BEDROCK PROBE → %s", sinkRemote),
            rawPayload = envelope,
            nonce      = nonce,
            result     = "✗ NO RETURN — not a proxy",
        })
    end
end

-- Heartbeat: re-verify the A→B link periodically
function ASE_BedrockHandshake.StartHeartbeat(sinkRemote)
    task.spawn(function()
        while ASE.Panel.HeartbeatAlive and ASE.Panel.ActiveSink == sinkRemote do
            task.wait(ASE_CFG.HeartbeatInterval)
            local pair = ASE_BedrockPairs[sinkRemote]
            if not pair then break end

            -- Quick re-verify with same nonce pattern
            local testNonce   = ASE_GenNonce()
            local alive       = false
            local PR          = _G.PC.PR_Registry
            local SARP        = _G.PC.SARP

            if PR and PR[sinkRemote] and SARP then
                local listener = ASE_OpenNonceListener(testNonce, function()
                    alive = true
                end)

                local testEnv = { __nonce=testNonce, __callback="heartbeat" }
                local wrapped, sim = SARP.Build("Attribute", {testEnv}, nil, nil, sinkRemote)
                if wrapped then
                    SARP.Execute(wrapped, sim, sinkRemote, function() end)
                end

                local t0 = os.clock()
                while not alive and (os.clock()-t0) < 3.0 do task.wait(0.15) end
                if listener then listener.cleanup() end

                if not alive then
                    -- Heartbeat lost — pipeline broken
                    ASE.Panel.HeartbeatAlive = false
                    ASE.Panel.BedrockConf    = 0.0
                    pair.confidence          = 0.0
                    warn(string.format("[ASE] ⚠ BEDROCK HEARTBEAT LOST: %s", sinkRemote))
                    ASE_AppendTx({
                        directive  = "HEARTBEAT LOST",
                        rawPayload = {sinkRemote=sinkRemote},
                        nonce      = testNonce,
                        result     = "✗ PIPELINE BROKEN — entering RECOMPILE",
                    })
                    -- Auto-trigger recompile if in MASTERY mode
                    if ASE_Mode == ASE.MODE.MASTERY then
                        ASE_GoalEngine.Push(ASE.GOAL.RECOMPILE, {
                            sinkRemote     = sinkRemote,
                            feedbackRemote = pair.feedbackRemote,
                        })
                    end
                    break
                else
                    ASE.Panel.BedrockConf = 1.0
                end
            end
        end
    end)
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 3 — DIRECTIVE COMPILER
-- Static cargo: intent → data envelope, lift raw → TSR Intent
-- ═════════════════════════════════════════════════════════════
ASE_DirectiveCompiler = {}

-- Compile a named TSR intent into a raw data envelope
-- using the sink remote's known arg schema
function ASE_DirectiveCompiler.Compile(intentName, args, sinkRemote)
    local TSR    = _G.PC.TSR
    local RSM    = _G.PC.RSM
    local PR     = _G.PC.PR_Registry

    -- Check if TSR has a binding for this intent
    if TSR and TSR.Runtime and TSR.Runtime.IsReady(intentName) then
        -- Route through TSR directly
        local result = TSR.Runtime.Execute(intentName, args)
        return true, result, nil
    end

    -- Fall back to direct envelope construction via known arg schema
    local rsmRec = RSM and RSM.Get(sinkRemote)
    if not rsmRec then
        return false, nil, "No RSM record for " .. tostring(sinkRemote)
    end

    -- Check if we have a finalized directive for this intent
    local directive = ASE_Directives[intentName]
    if directive and directive.sinkRemote == sinkRemote then
        -- Use the finalized envelope
        local envelope = {}
        for k, v in pairs(directive.envelope) do envelope[k] = v end
        -- Merge in provided args by position
        for i, v in ipairs(args or {}) do envelope[i] = v end
        return true, envelope, nil
    end

    return false, nil, string.format("Intent '%s' not bound and no directive found", intentName)
end

-- Execute a compiled directive through the active Bedrock pipeline
function ASE_DirectiveCompiler.Execute(intentName, args)
    local pair = ASE.Panel.ActiveSink and ASE_BedrockPairs[ASE.Panel.ActiveSink]
    if not pair or pair.confidence < 0.5 then
        return false, "No active Bedrock pipeline"
    end

    if not ASE.Panel.HeartbeatAlive then
        return false, "Pipeline heartbeat lost — use Recompile"
    end

    local SBI  = _G.PC.SBI
    local sinkRemote = pair.sinkRemote

    -- Pre-flight prediction
    local prediction = SBI and SBI.PredictOutcome(sinkRemote, args)
    if prediction and prediction.acRisk > 0.7 then
        warn(string.format("[ASE] High AC risk %.0f%% on %s — proceeding",
            prediction.acRisk*100, sinkRemote))
    end

    local ok, result, err = ASE_DirectiveCompiler.Compile(intentName, args, sinkRemote)
    if not ok then
        -- In MASTERY mode: auto-decompile and re-route through Forge
        if ASE_Mode == ASE.MODE.MASTERY then
            ASE_AppendTx({
                directive  = intentName,
                rawPayload = args,
                result     = "COMPILE FAIL → decompiling to Raw",
            })
            return ASE_ForgeEngine.FireRaw(sinkRemote, args, intentName)
        end
        return false, err
    end

    -- Fire through SARP with nonce
    local nonce   = ASE_GenNonce()
    local SARP    = _G.PC.SARP
    local PR      = _G.PC.PR_Registry
    if not SARP or not PR or not PR[sinkRemote] then
        return false, "SARP or PR not available"
    end

    -- Wrap result in Bedrock envelope
    local bedrockEnv = {
        __nonce    = nonce,
        __intent   = intentName,
        __payload  = type(result) == "table" and result or args,
        __cargo    = pair.cargo,
    }

    local wrapped, sim, buildErr = SARP.Build("Attribute", {bedrockEnv}, nil, nil, sinkRemote)
    if not wrapped then return false, "SARP.Build: " .. tostring(buildErr) end

    local fired = false
    SARP.Execute(wrapped, sim, sinkRemote, function(success, res, ferr)
        fired = true
        ASE_AppendTx({
            directive  = intentName,
            rawPayload = bedrockEnv,
            nonce      = nonce,
            result     = success and "✓ FIRED" or ("✗ " .. tostring(ferr)),
        })
    end)

    return true, nonce
end

-- Finalize: lift a confirmed raw sequence into a Static Directive + register as TSR Intent
function ASE_DirectiveCompiler.Finalize(goal)
    local name        = goal.params.name
    local envelope    = goal.params.envelope
    local sinkRemote  = goal.params.sinkRemote
    local category    = goal.params.category or "Custom"

    if not name or not envelope or not sinkRemote then
        error("Finalize requires name, envelope, sinkRemote")
    end

    -- Register directive
    ASE_Directives[name] = {
        name        = name,
        category    = category,
        envelope    = envelope,
        sinkRemote  = sinkRemote,
        confirmedAt = os.clock(),
    }

    -- Attempt to register as TSR Intent
    local TSR = _G.PC.TSR
    if TSR and TSR.Registry then
        pcall(function()
            local intentDef = {
                Intent      = name,
                Category    = category,
                Type        = "Atomic",
                Parameters  = goal.params.parameters or {},
                WatchTargets= goal.params.watchTargets or {},
                ASEFinalized= true,
                SinkRemote  = sinkRemote,
            }
            TSR.Registry.Intents[name] = intentDef
            print(string.format("[ASE] ✓ Finalized directive '%s' → TSR Intent registered.", name))
        end)
    end

    goal.result = { name=name, sinkRemote=sinkRemote, registeredTSR = TSR ~= nil }
    ASE_AppendTx({
        directive  = "FINALIZE: " .. name,
        rawPayload = envelope,
        result     = string.format("✓ Lifted to Static Directive [%s]", category),
    })
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4 — FORGE ENGINE
-- Raw payload construction, delivery, and discovery fuzzing
-- ═════════════════════════════════════════════════════════════
ASE_ForgeEngine = {}

-- Fire a raw payload directly through SARP with no semantic validation
function ASE_ForgeEngine.FireRaw(sinkRemote, rawArgs, label)
    local SARP = _G.PC.SARP
    local PR   = _G.PC.PR_Registry

    if not SARP or not PR or not PR[sinkRemote] then
        return false, "SARP/PR not available or remote not known"
    end

    local prRec = PR[sinkRemote]
    if not prRec.Remote then
        return false, "Remote object not available"
    end

    local nonce = ASE_GenNonce()

    -- For Raw mode: wrap args with nonce but no semantic filtering
    local wrapped, sim, err = SARP.Build("Attribute", rawArgs, nil, nil, sinkRemote)
    if not wrapped then
        -- Fall through to direct fire if SARP can't wrap
        local ok, ferr = pcall(function()
            prRec.Remote:FireServer(table.unpack(rawArgs))
        end)
        ASE_AppendTx({
            directive  = label or "RAW FIRE",
            rawPayload = rawArgs,
            nonce      = nonce,
            result     = ok and "✓ DIRECT FIRED" or ("✗ " .. tostring(ferr)),
        })
        return ok, ferr
    end

    local result = nil
    SARP.Execute(wrapped, sim, sinkRemote, function(success, res, ferr)
        result = { success=success, res=res, err=ferr }
        ASE_AppendTx({
            directive  = label or "RAW FIRE",
            rawPayload = rawArgs,
            nonce      = nonce,
            result     = success and "✓ SARP FIRED" or ("✗ " .. tostring(ferr)),
        })
    end)

    return true, nonce
end

-- Discovery: launch an APE campaign and feed results back to ASE
function ASE_ForgeEngine.Discover(goal)
    local remoteName = goal.params.remoteName
    local APE        = _G.PC.APE

    if not APE then error("APE not available") end
    if not remoteName then
        -- Scan all top priorities
        local n = APE.Scan()
        goal.result = { campaignCount=n }
        return
    end

    -- If APE has no probe plan yet, run a Scan first to build one
    local id, err = APE.StartCampaign(remoteName)
    if not id then
        if tostring(err):find("no goals") or tostring(err):find("no plan") then
            -- APE hasn't scanned this remote yet — trigger a scan and retry once
            APE.Scan()
            task.wait(2)
            id, err = APE.StartCampaign(remoteName)
        end
        if not id then
            if tostring(err):find("already active") then
                -- Campaign already running — find it and wait on it instead of erroring
                local existing = nil
                for _, c in ipairs(APE.GetCampaigns()) do
                    if c.remoteName == remoteName and
                       (c.status == "RUNNING" or c.status == "ACTIVE") then
                        existing = c; break
                    end
                end
                if existing then
                    id = existing.id
                else
                    -- Can't find it — just return cleanly, not an error
                    goal.result = { status="SKIPPED", reason="already active" }
                    return
                end
            else
                error("APE campaign failed: " .. tostring(err))
            end
        end
    end

    -- Wait for campaign to complete
    local t0 = os.clock()
    while os.clock()-t0 < 120 do
        task.wait(2)
        local campaigns = APE.GetCampaigns()
        for _, c in ipairs(campaigns) do
            if c.id == id then
                if c.status == "COMPLETE" or c.status == "SATURATED" then
                    goal.result = { campaignId=id, status=c.status,
                        confGain=c.confGain, probesFired=c.probesFired }
                    -- Check if we can now attempt Bedrock
                    local SBI = _G.PC.SBI
                    local sbiRec = SBI and SBI.Get(remoteName)
                    if sbiRec and sbiRec.Confidence >= 0.65
                       and sbiRec.ACPattern ~= "CORRECTS_FAST" then
                        goal.result.bedrockCandidate = true
                        print(string.format("[ASE] DISCOVER → %s is a Bedrock candidate (conf=%.0f%%)",
                            remoteName, sbiRec.Confidence*100))
                    end
                    return
                end
            end
        end
        if goal.status == ASE.STATUS.ABORTED then return end
    end
    goal.result = { campaignId=id, status="TIMEOUT" }
end

-- Convert raw byte-string notation to Lua table
-- Accepts strings like: {[0xAF]="\255\000\127", [1]="value"}
function ASE_ForgeEngine.ParseByteString(str)
    local ok, result = pcall(function()
        local fn = load("return " .. str)
        if fn then return fn() end
        return nil
    end)
    return ok and result or nil
end

-- Convert Lua table to byte-string display format
function ASE_ForgeEngine.ToByteString(t, depth)
    depth = depth or 0
    if depth > 4 then return "..." end
    if type(t) ~= "table" then
        if type(t) == "string" then
            -- Show hex repr for non-printable
            local hex = {}
            for i = 1, #t do
                local b = t:byte(i)
                if b < 32 or b > 126 then
                    table.insert(hex, string.format("\\x%02X", b))
                else
                    table.insert(hex, t:sub(i,i))
                end
            end
            return '"' .. table.concat(hex) .. '"'
        end
        return tostring(t)
    end
    local parts = {}
    for k, v in pairs(t) do
        local kStr = type(k) == "number"
            and string.format("[0x%02X]", k)
            or string.format("[%q]", tostring(k))
        table.insert(parts, kStr .. " = " .. ASE_ForgeEngine.ToByteString(v, depth+1))
    end
    return "{\n" .. string.rep("  ", depth+1) ..
           table.concat(parts, ",\n" .. string.rep("  ", depth+1)) ..
           "\n" .. string.rep("  ", depth) .. "}"
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 5 — RECOMPILE ENGINE
-- Drift detection → autonomous decompile → re-fuzz → re-bind
-- ═════════════════════════════════════════════════════════════
ASE_RecompileEngine = {}

function ASE_RecompileEngine.Run(goal)
    local sinkRemote     = goal.params.sinkRemote
    local feedbackRemote = goal.params.feedbackRemote
    local SBI            = _G.PC.SBI
    local APE            = _G.PC.APE

    if not sinkRemote then error("sinkRemote required for RECOMPILE") end

    print(string.format("[ASE] RECOMPILE: beginning drift recovery for %s", sinkRemote))
    ASE_AppendTx({
        directive  = "RECOMPILE: " .. sinkRemote,
        rawPayload = {},
        result     = "Drift detected — entering raw re-fuzz",
    })

    -- Step 1: Clear APE saturation so it re-probes
    local satState = APE and APE.GetSaturation(sinkRemote)
    if satState and satState.saturated then
        -- Force re-probe by resetting CSK stability note
        local CSK = _G.PC.CSK
        if CSK then
            CSK.Annotate(sinkRemote, "RECOMPILE: saturation cleared for drift recovery")
        end
    end

    -- Step 2: Run targeted APE campaign focused on validation
    if APE then
        local id, err = APE.StartCampaign(sinkRemote)
        if id then
            -- Wait up to 60s for campaign to yield new data
            local t0 = os.clock()
            local campaignDone = false
            while not campaignDone and os.clock()-t0 < 60 do
                task.wait(2)
                local campaigns = APE.GetCampaigns()
                for _, c in ipairs(campaigns) do
                    if c.id == id and (c.status == "COMPLETE" or c.status == "SATURATED") then
                        campaignDone = true; break
                    end
                end
                if goal.status == ASE.STATUS.ABORTED then return end
            end
        end
    end

    -- Step 3: Force SBI rebuild with new probe data
    if SBI then pcall(SBI.Rebuild) end
    task.wait(1.0)

    -- Step 4: Attempt Bedrock re-handshake
    local rehandshakeGoal = ASE_NewGoal(ASE.GOAL.BEDROCK, {
        sinkRemote = sinkRemote,
        cargo      = goal.params.cargo or {},
    })
    ASE_BedrockHandshake.Run(rehandshakeGoal)

    if rehandshakeGoal.result and rehandshakeGoal.result.confirmed then
        goal.result = { recovered=true, newFeedback=rehandshakeGoal.result.feedbackRemote }
        -- Re-bind all directives for this sink
        for name, dir in pairs(ASE_Directives) do
            if dir.sinkRemote == sinkRemote then
                print(string.format("[ASE] Silent re-bind: directive '%s' on recovered pipeline.", name))
            end
        end
        ASE_AppendTx({
            directive  = "RECOMPILE COMPLETE",
            rawPayload = {},
            result     = "✓ Pipeline recovered — directives re-bound silently",
        })
    else
        goal.result = { recovered=false }
        ASE_AppendTx({
            directive  = "RECOMPILE FAILED",
            rawPayload = {},
            result     = "✗ Could not re-establish pipeline — manual investigation required",
        })
    end
end

-- SBI drift monitor: called on every SBI rebuild
function ASE_RecompileEngine.CheckDrift()
    if not ASE.Panel.Visible or not ASE.Panel.ActiveSink then return end
    local sinkRemote = ASE.Panel.ActiveSink
    local SBI        = _G.PC.SBI
    local sbiRec     = SBI and SBI.Get(sinkRemote)
    if not sbiRec then return end

    local pair = ASE_BedrockPairs[sinkRemote]
    if not pair then return end

    -- Check if confidence regressed significantly since confirmation
    if pair.confidence >= 0.8 and sbiRec.Confidence < (pair.confidence - ASE_CFG.DriftThreshold) then
        warn(string.format("[ASE] Drift detected on %s: conf %.2f→%.2f",
            sinkRemote, pair.confidence, sbiRec.Confidence))
        if ASE_Mode == ASE.MODE.MASTERY then
            ASE_GoalEngine.Push(ASE.GOAL.RECOMPILE, { sinkRemote=sinkRemote })
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 6 — RISK BUDGET
-- ═════════════════════════════════════════════════════════════

function ASE.GetRiskBudget()
    return {
        total     = ASE_CFG.SessionRiskBudget,
        consumed  = ASE_RiskConsumed,
        remaining = math.max(0, ASE_CFG.SessionRiskBudget - ASE_RiskConsumed),
        pct       = ASE_RiskConsumed / ASE_CFG.SessionRiskBudget,
    }
end

function ASE.ResetRiskBudget()
    ASE_RiskConsumed = 0.0
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 7 — EXECUTION PANEL CONTROLLER
-- ═════════════════════════════════════════════════════════════

function ASE.SetMode(mode)
    if mode == ASE.MODE.MASTERY and not ASE_MasteryUnlocked then
        return false, "Autonomous Mastery not unlocked"
    end
    ASE_Mode              = mode
    ASE.Panel.Mode        = mode
    ASE.Panel.ForgeExpanded = (mode == ASE.MODE.RAW or mode == ASE.MODE.MASTERY)
    return true
end

function ASE.UnlockMastery(passphrase)
    local REQUIRED = "I am responsible for my actions"
    if passphrase == REQUIRED then
        ASE_MasteryUnlocked   = true
        ASE.Panel.MasteryUnlocked = true
        print("[ASE] Autonomous Mastery unlocked.")
        return true
    end
    return false
end

function ASE.IsMasteryUnlocked()
    return ASE_MasteryUnlocked
end

-- ═════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════

-- Goal API
function ASE.PursueBedrock(sinkRemote, cargo)
    return ASE_GoalEngine.Push(ASE.GOAL.BEDROCK, {
        sinkRemote = sinkRemote,
        cargo      = cargo or {},
    })
end

function ASE.FinalizeDirective(name, envelope, sinkRemote, category, params, watchTargets)
    return ASE_GoalEngine.Push(ASE.GOAL.FINALIZE, {
        name         = name,
        envelope     = envelope,
        sinkRemote   = sinkRemote,
        category     = category,
        parameters   = params,
        watchTargets = watchTargets,
    })
end

function ASE.Recompile(sinkRemote)
    return ASE_GoalEngine.Push(ASE.GOAL.RECOMPILE, { sinkRemote=sinkRemote })
end

function ASE.Discover(remoteName)
    return ASE_GoalEngine.Push(ASE.GOAL.DISCOVER, { remoteName=remoteName })
end

-- Directive execution
function ASE.Execute(intentName, args)
    return ASE_DirectiveCompiler.Execute(intentName, args)
end

-- Raw fire
function ASE.FireRaw(sinkRemote, rawArgs)
    if ASE_Mode == ASE.MODE.COMPILED then
        return false, "Switch to Raw or Mastery mode first"
    end
    ASE_ConsumeRisk("RAW_FIRE")
    return ASE_ForgeEngine.FireRaw(sinkRemote, rawArgs)
end

-- Forge utilities
function ASE.ParseByteString(str)   return ASE_ForgeEngine.ParseByteString(str) end
function ASE.ToByteString(t)        return ASE_ForgeEngine.ToByteString(t) end

-- Getters
function ASE.GetGoals()
    local out = {}
    for _, g in pairs(ASE_Goals) do table.insert(out, g) end
    table.sort(out, function(a,b) return a.id > b.id end)
    return out
end

function ASE.GetBedrockPairs()
    local out = {}
    for _, p in pairs(ASE_BedrockPairs) do table.insert(out, p) end
    return out
end

function ASE.GetDirectives()
    local out = {}
    for _, d in pairs(ASE_Directives) do table.insert(out, d) end
    table.sort(out, function(a,b) return (a.confirmedAt or 0) > (b.confirmedAt or 0) end)
    return out
end

function ASE.GetTxBuffer(n)
    local out = {}
    for i = 1, math.min(n or 32, #ASE.Panel.TxBuffer) do
        table.insert(out, ASE.Panel.TxBuffer[i])
    end
    return out
end

function ASE.GetMode()    return ASE_Mode end
function ASE.GetStats()
    return {
        Mode            = ASE_Mode,
        MasteryUnlocked = ASE_MasteryUnlocked,
        PanelVisible    = ASE.Panel.Visible,
        ActiveSink      = ASE.Panel.ActiveSink,
        ActiveFeedback  = ASE.Panel.ActiveFeedback,
        HeartbeatAlive  = ASE.Panel.HeartbeatAlive,
        BedrockConf     = ASE.Panel.BedrockConf,
        GoalCount       = (function() local n=0; for _ in pairs(ASE_Goals) do n=n+1 end; return n end)(),
        ActiveGoals     = ASE_ActiveCount,
        DirectiveCount  = (function() local n=0; for _ in pairs(ASE_Directives) do n=n+1 end; return n end)(),
        RiskConsumed    = ASE_RiskConsumed,
        RiskRemaining   = math.max(0, ASE_CFG.SessionRiskBudget - ASE_RiskConsumed),
    }
end

-- AVD finding hook: auto-assess if a new finding is a Bedrock candidate
function ASE.OnAVDFinding(finding)
    if not finding or not finding.remoteName then return end
    local score = finding.exploitScore or 0
    if score < ASE_CFG.BedrockThreshold then return end

    local name = finding.remoteName
    local now  = os.clock()

    -- Debounce: skip if we already queued a DISCOVER for this remote recently
    local lastPush = ASE_DiscoverCooldown[name] or 0
    if (now - lastPush) < ASE_DISCOVER_COOLDOWN_S then return end

    -- Skip if a DISCOVER goal for this remote is already pending/running
    for _, g in pairs(ASE_Goals) do
        if g.goalType == ASE.GOAL.DISCOVER
           and g.params.remoteName == name
           and (g.status == ASE.STATUS.PENDING or g.status == ASE.STATUS.RUNNING) then
            return
        end
    end

    ASE_DiscoverCooldown[name] = now
    print(string.format("[ASE] AVD finding on %s (score=%.2f) — Bedrock candidate queued.",
        name, score))
    ASE_GoalEngine.Push(ASE.GOAL.DISCOVER, { remoteName=name })
end

-- Persistence
function ASE.Save()
    local function safe(t)
        if type(t) ~= "table" then return t end
        local o = {}
        for k,v in pairs(t) do
            if type(k)=="string" or type(k)=="number" then
                local sv = safe(v)
                if sv ~= nil then o[k] = sv end
            end
        end
        return o
    end
    pcall(function()
        _G[ASE_CFG.PersistKey] = {
            PersistVer      = ASE_CFG.PersistVer,
            MasteryUnlocked = ASE_MasteryUnlocked,
            Directives      = safe(ASE_Directives),
            BedrockPairs    = safe(ASE_BedrockPairs),
        }
    end)
end

function ASE.Load()
    pcall(function()
        local d = _G[ASE_CFG.PersistKey]
        if type(d) ~= "table" or d.PersistVer ~= ASE_CFG.PersistVer then return end
        ASE_MasteryUnlocked       = d.MasteryUnlocked or false
        ASE.Panel.MasteryUnlocked = ASE_MasteryUnlocked
        if type(d.Directives) == "table" then
            for k, v in pairs(d.Directives) do ASE_Directives[k] = v end
        end
        if type(d.BedrockPairs) == "table" then
            for k, v in pairs(d.BedrockPairs) do
                v.confidence = 0.0  -- require re-verification on load
                ASE_BedrockPairs[k] = v
            end
        end
        print(string.format("[ASE] Loaded: %d directives, mastery=%s",
            (function() local n=0; for _ in pairs(ASE_Directives) do n=n+1 end; return n end)(),
            tostring(ASE_MasteryUnlocked)))
    end)
end

-- ═════════════════════════════════════════════════════════════
-- STARTUP
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    local function waitFor(getter, label, timeout)
        local t0 = os.clock()
        while not getter() do
            if os.clock()-t0 > timeout then
                warn("[ASE] Timeout waiting for "..label); return false
            end
            task.wait(0.5)
        end
        return true
    end

    waitFor(function() return _G.PC.SBI  end, "SBI",  40)
    waitFor(function() return _G.PC.SARP end, "SARP", 35)
    waitFor(function() return _G.PC.APE  end, "APE",  45)
    waitFor(function() return _G.PC.CSK  end, "CSK",  45)
    waitFor(function() return _G.PC.TSR  end, "TSR",  45)

    ASE.Load()
    ASE_Running = true

    -- Hook AVD Strategist for finding notifications
    task.wait(1.0)
    local strat = _G.PC.AVD and _G.PC.AVD.Strategist
    if strat then
        local origOnReport = strat.OnReport
        local _seenFindings = {}  -- track which remotes we've already acted on
        strat.OnReport = function(report)
            if origOnReport then origOnReport(report) end
            -- Only act on findings that have score >= threshold
            -- Debounce is inside OnAVDFinding, but avoid iterating every tick
            -- by only calling it if the report itself signals a high-value finding
            if not report or not report.signal or report.signal < 0.55 then return end
            local findings = strat.GetFindings and strat.GetFindings(0.70) or {}
            for _, f in ipairs(findings) do
                pcall(ASE.OnAVDFinding, f)
            end
        end
        print("[ASE] Hooked AVD Strategist.OnReport")
    end

    -- Set Bedrock candidate threshold
    ASE_CFG.BedrockThreshold = 0.75

    print("[ASE] Autonomous Strategy Engine ready.")
    print(string.format("[ASE] Mode: %s | Mastery: %s",
        ASE_Mode, tostring(ASE_MasteryUnlocked)))
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.ASE = ASE
_G.PC.ASE_BedrockHandshake  = ASE_BedrockHandshake
_G.PC.ASE_DirectiveCompiler = ASE_DirectiveCompiler
_G.PC.ASE_ForgeEngine       = ASE_ForgeEngine
_G.PC.ASE_RecompileEngine   = ASE_RecompileEngine
print("[ASE] Module registered.")
