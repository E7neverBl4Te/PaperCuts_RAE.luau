-- ── Imports ──────────────────────────────────────────────────────────────────
local _C       = _G.PC
local Registry = _G.PC.TSR.Registry

-- ============================================================
-- TSR RUNTIME — Transaction Manager + Sovereign API
-- The public-facing execution layer of TSR.
-- Responsibilities:
--   1. Expose the clean TSR.IntentName(args) API
--   2. Execute atomic bindings via SARP
--   3. Execute compound bindings as managed transactions
--   4. Enforce transactional constraints + rollback flags
--   5. Enforce risk-level confirmation gates
--   6. Record outcomes back to Registry
--   7. Trigger Binder refresh when new AVD data arrives
-- ============================================================

local RUNTIME_CFG = {
    -- Default SARP channel when PR_Bridge has no suggestion
    DefaultChannel        = "Attribute",
    -- Delay between steps in a compound transaction (seconds)
    StepDelay             = 0.4,
    -- Max retries per step before transaction abort
    MaxStepRetries        = 2,
    -- Whether to auto-start Binder when Runtime starts
    AutoStartBinder       = true,
    -- Whether to auto-start AVD when Runtime starts
    AutoStartAVD          = true,
    -- Sanity cap enforcement: clamp input to [sanityMin, sanityMax]
    EnforceSanityCap      = true,
    -- Confirmation callback for CRITICAL/HIGH intents
    -- Replace with UI dialog hook in tsr_ui.lua
    ConfirmationCallback  = nil,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local TSR_Runtime = {}

local R_Running       = false
local R_TxLog         = {}   -- transaction history ring buffer
local R_TxPtr         = 0
local R_TxCap         = 128
local R_CallCount     = 0
local R_SuccessCount  = 0

-- ── Transaction record ────────────────────────────────────────────────────────
local function R_NewTx(intentName, args, binding)
    R_TxPtr = (R_TxPtr % R_TxCap) + 1
    local tx = {
        id         = R_TxPtr,
        intentName = intentName,
        args       = args,
        binding    = binding,
        startTime  = os.clock(),
        endTime    = nil,
        success    = nil,
        steps      = {},   -- for compound transactions
        error      = nil,
    }
    R_TxLog[R_TxPtr] = tx
    return tx
end

-- ── Sanity cap enforcement ────────────────────────────────────────────────────
local function R_ClampArgs(intent, args, binding)
    if not RUNTIME_CFG.EnforceSanityCap then return args end
    if not binding.sanityMax then return args end
    local out = { table.unpack(args) }
    for i, param in ipairs(intent.Parameters or {}) do
        if param.kind == "number" and out[i] ~= nil then
            if binding.sanityMin then
                out[i] = math.max(binding.sanityMin, out[i])
            end
            if binding.sanityMax then
                out[i] = math.min(binding.sanityMax, out[i])
            end
        end
    end
    return out
end

-- ── Argument builder from named params ───────────────────────────────────────
-- Converts { speed=100 } or positional { 100 } to ordered arg list
local function R_BuildArgList(intent, namedArgs, binding)
    local argMap = binding.argMap or {}
    local out    = {}

    -- Determine max slot
    local maxSlot = #(intent.Parameters or {})
    for _, slot in pairs(argMap) do
        if slot > maxSlot then maxSlot = slot end
    end

    -- Fill from named args first
    if type(namedArgs) == "table" then
        -- Check if it's positional (integer keys) or named (string keys)
        local isPositional = true
        for k in pairs(namedArgs) do
            if type(k) ~= "number" then isPositional = false; break end
        end

        if isPositional then
            for i = 1, maxSlot do out[i] = namedArgs[i] end
        else
            -- Named args — map to slots
            for i, param in ipairs(intent.Parameters or {}) do
                out[i] = namedArgs[param.name]
            end
            -- Also accept direct slot overrides
            for k, v in pairs(namedArgs) do
                if type(k) == "number" then out[k] = v end
            end
        end
    end

    -- Fill missing slots with defaults
    for i, param in ipairs(intent.Parameters or {}) do
        if out[i] == nil then
            if param.kind == "number"  then out[i] = 1
            elseif param.kind == "string"  then out[i] = ""
            elseif param.kind == "boolean" then out[i] = true
            elseif param.kind == "Vector3" then out[i] = Vector3.new()
            end
        end
    end

    return R_ClampArgs(intent, out, binding)
end

-- ── SARP delivery wrapper ─────────────────────────────────────────────────────
local function R_DeliverViaSARP(remoteName, remoteObj, remoteType, args)
    local SARP = _C.SARP
    if not SARP then
        -- Fallback: fire directly
        if remoteType == "RemoteEvent" then
            return pcall(function() remoteObj:FireServer(table.unpack(args)) end)
        elseif remoteType == "RemoteFunction" then
            return pcall(function() return remoteObj:InvokeServer(table.unpack(args)) end)
        end
        return false, "No SARP and unknown remoteType"
    end

    -- Get best channel
    local channel = RUNTIME_CFG.DefaultChannel
    local prBridge = _C.PR_Bridge
    if prBridge and prBridge.GetSuggestedChannel then
        channel = prBridge.GetSuggestedChannel() or channel
    end

    -- Wrap payload
    local wrapped, wrapErr
    if channel == "Attribute" then
        wrapped, wrapErr = SARP.Crafter.WrapAttribute(args, nil, nil)
    elseif channel == "OwnedCarrier" then
        wrapped, wrapErr = SARP.Crafter.WrapOwnedCarrier(args, nil)
    elseif channel == "AttachmentBridge" then
        wrapped, wrapErr = SARP.Crafter.WrapAttachmentBridge(args, remoteName)
    end

    if not wrapped then
        -- Fallback to direct fire
        if remoteType == "RemoteEvent" then
            return pcall(function() remoteObj:FireServer(table.unpack(args)) end)
        end
        return false, wrapErr
    end

    -- Simulate + execute
    local simResult = SARP.Simulator and SARP.Simulator.Simulate(wrapped, remoteName)
    local success   = false
    SARP.Execute(wrapped, simResult, remoteName, function(outcome)
        success = outcome and outcome.Success or false
    end)

    return success, nil
end

-- ── ATOMIC execution ──────────────────────────────────────────────────────────
local function R_ExecuteAtomic(tx, intent, args, binding)
    local remoteObj = binding.remoteObj
    -- Re-resolve remote from PR registry if stale
    if not remoteObj then
        local rec = _C.PR_Registry and _C.PR_Registry[binding.remoteName]
        remoteObj = rec and rec.Remote
    end
    if not remoteObj then
        tx.error   = "Remote object not found: " .. tostring(binding.remoteName)
        tx.success = false
        return false
    end

    local ok, err = R_DeliverViaSARP(
        binding.remoteName, remoteObj, binding.remoteType, args)

    tx.success = ok
    tx.error   = ok and nil or tostring(err)
    tx.endTime = os.clock()
    return ok
end

-- ── COMPOUND execution (Transaction Manager) ──────────────────────────────────
local function R_ExecuteCompound(tx, intent, args, binding)
    local chainMap = binding.chainMap or {}
    local steps    = intent.Steps or {}
    local prReg    = _C.PR_Registry

    -- Snapshot state before transaction
    local snapBefore = {}
    local sentry = _C.AVD and _C.AVD.Sentry
    if sentry then
        for _, target in ipairs(intent.WatchTargets or {}) do
            local ok, val = pcall(function()
                return sentry.SnapshotInstance and sentry.SnapshotInstance(target) or nil
            end)
            snapBefore[target] = ok and val or nil
        end
    end

    local allOk   = true
    local lastErr = nil

    for stepIdx, step in ipairs(steps) do
        local remoteName = chainMap[step.ActionID] or binding.remoteName
        local rec        = prReg and prReg[remoteName]
        local remoteObj  = rec and rec.Remote
        local remoteType = rec and rec.RemoteType or binding.remoteType

        local stepRecord = {
            actionID   = step.ActionID,
            remoteName = remoteName,
            attempted  = false,
            success    = false,
            error      = nil,
        }
        table.insert(tx.steps, stepRecord)

        -- Skip optional steps if prior required step failed
        if not allOk and not step.Optional then
            stepRecord.error = "Skipped: prior required step failed"
            if intent.Constraint == "Transactional" then
                break
            end
        end

        if not remoteObj then
            stepRecord.error = "Remote not found: " .. tostring(remoteName)
            if not step.Optional then
                allOk   = false
                lastErr = stepRecord.error
                if intent.Constraint == "Transactional" then break end
            end
            goto continue
        end

        -- Build step-specific args (token consistency: same args flow through all steps)
        local stepArgs = args

        stepRecord.attempted = true
        local retries = 0
        local stepOk  = false

        while retries <= RUNTIME_CFG.MaxStepRetries do
            stepOk = R_DeliverViaSARP(remoteName, remoteObj, remoteType, stepArgs)
            if stepOk then break end
            retries = retries + 1
            if retries <= RUNTIME_CFG.MaxStepRetries then
                task.wait(0.3 * retries)
            end
        end

        stepRecord.success = stepOk
        if not stepOk then
            stepRecord.error = "Step failed after " .. retries .. " retries"
            if not step.Optional then
                allOk   = false
                lastErr = stepRecord.error
                if intent.Constraint == "Transactional" then break end
            end
        end

        ::continue::
        if stepIdx < #steps then
            task.wait(RUNTIME_CFG.StepDelay)
        end
    end

    tx.success = allOk
    tx.error   = lastErr
    tx.endTime = os.clock()
    return allOk
end

-- ── Confirmation gate ─────────────────────────────────────────────────────────
local function R_ConfirmRisk(intent, args)
    local risk = intent.RiskLevel
    if not intent.RequiresConfirmation then return true end
    if not risk then return true end

    -- If UI has registered a confirmation callback, use it
    local cb = RUNTIME_CFG.ConfirmationCallback
    if cb then
        return cb(intent.Intent, risk, args)
    end

    -- Default: CRITICAL requires explicit confirmation, others pass
    if risk == "CRITICAL" then
        warn(string.format("[TSR Runtime] CRITICAL intent '%s' requires confirmation. Set RUNTIME_CFG.ConfirmationCallback.", intent.Intent))
        return false
    end
    return true
end

-- ── Core execute ──────────────────────────────────────────────────────────────
local function R_Execute(intentName, namedArgs)
    R_CallCount = R_CallCount + 1

    local intent = Registry.GetIntent(intentName)
    if not intent then
        warn("[TSR Runtime] Unknown intent: " .. tostring(intentName))
        return false, "Unknown intent"
    end

    local binding = Registry.GetBinding(intentName)
    if not binding then
        warn(string.format("[TSR Runtime] Intent '%s' is not bound for this game.", intentName))
        -- Queue it for binding
        local binder = _C.TSR and _C.TSR.Binder
        if binder then binder.BindIntent(intentName) end
        return false, "Not bound"
    end

    -- Risk confirmation gate
    if not R_ConfirmRisk(intent, namedArgs) then
        return false, "Confirmation required"
    end

    -- Build arg list
    local args = R_BuildArgList(intent, namedArgs or {}, binding)

    -- Create transaction record
    local tx = R_NewTx(intentName, args, binding)

    -- Execute
    local ok, err
    if intent.Type == "Compound" and not binding.wasLeaky then
        ok, err = R_ExecuteCompound(tx, intent, args, binding)
    else
        ok, err = R_ExecuteAtomic(tx, intent, args, binding)
    end

    -- Record outcome
    Registry.RecordOutcome(intentName, ok)
    if ok then R_SuccessCount = R_SuccessCount + 1 end

    -- If failure, invalidate binding confidence
    if not ok and binding then
        binding.confidence = (binding.confidence or 1.0) * 0.85
        if binding.confidence < 0.40 then
            -- Confidence has degraded — re-queue for rebinding
            Registry.Bind(intentName, nil)  -- clear binding
            local binder = _C.TSR and _C.TSR.Binder
            if binder then binder.BindIntent(intentName) end
        end
    end

    return ok, err
end

-- ── Sovereign API generation ──────────────────────────────────────────────────
-- Dynamically generates TSR.IntentName(args) callables for all 100 intents

local SovereignAPI = {}

local function R_MakeSovereign()
    for intentName, intent in pairs(Registry.GetIntents()) do
        -- Generate a typed callable
        SovereignAPI[intentName] = function(...)
            local args = {...}
            -- Accept either positional args or a single named-arg table
            if #args == 1 and type(args[1]) == "table" then
                return R_Execute(intentName, args[1])
            else
                return R_Execute(intentName, args)
            end
        end
    end
end

-- ── Batch execution ───────────────────────────────────────────────────────────
-- Execute multiple intents in sequence with optional delay between
function TSR_Runtime.Batch(intentList, delayBetween)
    delayBetween = delayBetween or 0.5
    local results = {}
    for _, item in ipairs(intentList) do
        -- item = { intent=name, args={...} } or just a string
        local intentName = type(item) == "string" and item or item.intent
        local args       = type(item) == "table" and item.args or {}
        local ok, err    = R_Execute(intentName, args)
        table.insert(results, { intent=intentName, ok=ok, err=err })
        if delayBetween > 0 then task.wait(delayBetween) end
    end
    return results
end

-- ── Macro system ──────────────────────────────────────────────────────────────
-- Define reusable sequences of intents
local R_Macros = {}

function TSR_Runtime.DefineMacro(name, intentList)
    R_Macros[name] = intentList
end

function TSR_Runtime.RunMacro(name, delay)
    local macro = R_Macros[name]
    if not macro then
        warn("[TSR Runtime] Unknown macro: " .. tostring(name))
        return nil
    end
    return TSR_Runtime.Batch(macro, delay or 0.5)
end

function TSR_Runtime.GetMacros()
    local names = {}
    for n in pairs(R_Macros) do table.insert(names, n) end
    return names
end

-- ── Built-in macros ───────────────────────────────────────────────────────────
TSR_Runtime.DefineMacro("MaxCharacter", {
    { intent="SetWalkSpeed",  args={speed=100}   },
    { intent="SetJumpPower",  args={power=100}   },
    { intent="SetHealth",     args={value=99999} },
    { intent="SetMaxHealth",  args={value=99999} },
    { intent="ToggleGodMode", args={enabled=true}},
})

TSR_Runtime.DefineMacro("MaxEconomy", {
    { intent="AddCurrency",         args={type="Coins",  amount=999999} },
    { intent="AddCurrency",         args={type="Cash",   amount=999999} },
    { intent="GrantPremiumCurrency",args={amount=999999} },
    { intent="SetLevel",            args={level=999}    },
    { intent="SetRebirthCount",     args={count=999}    },
})

TSR_Runtime.DefineMacro("CleanState", {
    { intent="SetHealth",    args={value=100} },
    { intent="ClearDebuff",  args={debuffType="all"} },
    { intent="ReviveCharacter", args={} },
})

-- ── Confirmation callback registration ───────────────────────────────────────
function TSR_Runtime.SetConfirmationCallback(fn)
    RUNTIME_CFG.ConfirmationCallback = fn
end

-- ── AVD feedback loop ─────────────────────────────────────────────────────────
-- Called when AVD produces new high-confidence findings
-- Triggers Binder to refresh and attempt new bindings
function TSR_Runtime.OnAVDFinding(finding)
    if (finding.confidence or 0) < 0.65 then return end
    local binder = _C.TSR and _C.TSR.Binder
    if binder then
        binder.RefreshQueue()
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Primary execution entry point
function TSR_Runtime.Execute(intentName, args)
    return R_Execute(intentName, args)
end

-- Check if an intent is ready to call
function TSR_Runtime.IsReady(intentName)
    return Registry.IsBound(intentName)
end

-- Get all currently callable intents
function TSR_Runtime.GetCallable()
    local out = {}
    for name in pairs(Registry.GetAllBindings()) do
        table.insert(out, name)
    end
    table.sort(out)
    return out
end

-- Get transaction log
function TSR_Runtime.GetTxLog(limit)
    local out = {}
    for i = 1, math.min(R_TxCap, limit or R_TxCap) do
        if R_TxLog[i] then table.insert(out, R_TxLog[i]) end
    end
    table.sort(out, function(a,b) return (a.startTime or 0) > (b.startTime or 0) end)
    return out
end

function TSR_Runtime.GetStats()
    return {
        Running      = R_Running,
        CallCount    = R_CallCount,
        SuccessCount = R_SuccessCount,
        SuccessRate  = R_CallCount > 0 and R_SuccessCount/R_CallCount or 0,
        BoundIntents = (function()
            local n=0; for _ in pairs(Registry.GetAllBindings()) do n=n+1 end; return n
        end)(),
    }
end

function TSR_Runtime.GetCFG()
    return RUNTIME_CFG
end

-- ── Startup ───────────────────────────────────────────────────────────────────
local function R_Start()
    if R_Running then return end
    R_Running = true

    -- Build the Sovereign API
    R_MakeSovereign()

    -- Auto-start subsystems
    if RUNTIME_CFG.AutoStartAVD then
        local op = _C.AVD and _C.AVD.Operator
        if op and not op.GetStats().Running then
            task.spawn(op.Start)
        end
    end
    if RUNTIME_CFG.AutoStartBinder then
        local binder = _C.TSR and _C.TSR.Binder
        if binder then
            task.spawn(binder.Start)
        end
    end

    -- Hook AVD Strategist to forward findings to Runtime
    local strategist = _C.AVD and _C.AVD.Strategist
    if strategist then
        local origOnReport = strategist.OnReport
        strategist.OnReport = function(report)
            if origOnReport then origOnReport(report) end
            TSR_Runtime.OnAVDFinding(report)
        end
    end

    print("[TSR Runtime] Sovereign API ready. Callable intents: " ..
        #TSR_Runtime.GetCallable())
end

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.TSR then _G.PC.TSR = {} end
_G.PC.TSR.Runtime   = TSR_Runtime
_G.PC.TSR.Call      = SovereignAPI   -- TSR.Call.SetWalkSpeed(100)
_G.PC.TSR.Execute   = TSR_Runtime.Execute

-- Convenience shorthand — TSR("SetWalkSpeed", {speed=100})
_G.TSR = function(intentName, args)
    return TSR_Runtime.Execute(intentName, args)
end

R_Start()
print("[TSR Runtime] Ready.")
