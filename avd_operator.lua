-- ── Imports ──────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- AVD OPERATOR — Execution & Lifecycle
-- The only AVD module that touches remotes directly.
-- Responsibilities:
--   1. Pull probe plans from Strategist queue
--   2. Execute probes safely (passive + active modes)
--   3. Manage fire rate to avoid triggering rate limiters
--   4. Report timing to Translator
--   5. Deliver confirmed payloads to SARP
-- ============================================================

local OPERATOR_CFG = {
    -- Passive mode: observe only, no active firing
    PassiveOnly          = false,
    -- Delay between consecutive probe fires (seconds)
    ProbeCooldown        = 0.8,
    -- Max probes per second across all remotes
    GlobalRateCap        = 2,
    -- Timeout for RemoteFunction invoke (seconds)
    RFTimeout            = 3.0,
    -- Max concurrent probe slots open at once
    MaxConcurrent        = 3,
    -- Whether to use PR_Bridge channel suggestion for SARP handoff
    UsePRBridgeChannel   = true,
    -- Retry a failed probe this many times before skipping
    MaxRetries           = 2,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local AVD_Operator = {}

local O_Running       = false
local O_ActiveCount   = 0       -- currently open probe windows
local O_LastFireTime  = 0       -- os.clock() of last fire
local O_TotalFired    = 0
local O_TotalFailed   = 0
local O_PassiveConns  = {}      -- passive listener connections
local O_PassiveActive = false

-- ── Passive mode: listen to existing remote traffic ──────────────────────────
-- Passive mode hooks OnClientEvent for S2C remotes and watches
-- RemoteFunction returns without firing anything new.
local function O_StartPassive()
    if O_PassiveActive then return end
    O_PassiveActive = true

    local registry = _G.PC.PR_Registry
    if not registry then return end

    for name, rec in pairs(registry) do
        -- Only hook S2C remotes passively
        if rec.Remote and rec.RemoteType == "RemoteEvent" and
           (rec.Direction == "S2C" or rec.Direction == "BOTH") then
            local ok, conn = pcall(function()
                return rec.Remote.OnClientEvent:Connect(function(...)
                    local args = {...}
                    local now  = os.clock()
                    -- Register this as a passive "probe" with the Translator
                    -- so it can build a richer baseline correlation
                    local translator = _G.PC.AVD and _G.PC.AVD.Translator
                    if translator then
                        local pid = "PASSIVE_" .. name .. "_" .. tostring(now)
                        translator.RegisterProbe(pid, {
                            remoteName = name,
                            remoteType = "RemoteEvent",
                            channel    = "S2C_Passive",
                            probeKind  = "PassiveObserve",
                            probeArgs  = args,
                            probeTime  = now,
                        })
                    end
                end)
            end)
            if ok and conn then
                table.insert(O_PassiveConns, conn)
            end
        end
    end

    print(string.format("[AVD Operator] Passive mode: hooked %d S2C remotes.", #O_PassiveConns))
end

-- ── Rate limiter ──────────────────────────────────────────────────────────────
local O_FireTimes = {}  -- ring buffer of recent fire timestamps

local function O_CanFire()
    if OPERATOR_CFG.PassiveOnly then return false end
    if O_ActiveCount >= OPERATOR_CFG.MaxConcurrent then return false end

    local now     = os.clock()
    local minGap  = 1.0 / OPERATOR_CFG.GlobalRateCap
    if now - O_LastFireTime < minGap then return false end
    if now - O_LastFireTime < OPERATOR_CFG.ProbeCooldown then return false end

    return true
end

local function O_RecordFire()
    O_LastFireTime = os.clock()
    O_TotalFired   = O_TotalFired + 1
    O_ActiveCount  = O_ActiveCount + 1
end

local function O_RecordClose()
    O_ActiveCount = math.max(0, O_ActiveCount - 1)
end

-- ── Safe fire helpers ─────────────────────────────────────────────────────────
local function O_FireRemoteEvent(remote, args)
    local ok, err = pcall(function()
        remote:FireServer(table.unpack(args))
    end)
    return ok, err
end

local function O_InvokeRemoteFunction(remote, args, timeout)
    local result, err = nil, nil
    local done = false
    task.spawn(function()
        local ok, ret = pcall(function()
            return remote:InvokeServer(table.unpack(args))
        end)
        if ok then result = ret else err = ret end
        done = true
    end)
    -- Wait up to timeout
    local start = os.clock()
    while not done and (os.clock() - start) < (timeout or OPERATOR_CFG.RFTimeout) do
        task.wait(0.05)
    end
    if not done then
        return false, "TIMEOUT", nil
    end
    return err == nil, err, result
end

local function O_FireBindable(bindable, args)
    local ok, err = pcall(function()
        if bindable:IsA("BindableEvent") then
            bindable:Fire(table.unpack(args))
        elseif bindable:IsA("BindableFunction") then
            bindable:Invoke(table.unpack(args))
        end
    end)
    return ok, err
end

-- ── Probe execution ───────────────────────────────────────────────────────────
local function O_ExecuteProbe(probeRequest)
    local probeID = probeRequest.probeID
    local target  = probeRequest.target
    local plan    = probeRequest.plan

    if not target.remote then
        return false, "No remote object"
    end

    -- Register with Translator BEFORE firing
    local translator = _G.PC.AVD and _G.PC.AVD.Translator
    local fireTime   = os.clock()

    if translator then
        translator.RegisterProbe(probeID, {
            remoteName = target.name,
            remoteType = target.remoteType,
            channel    = plan.kind,
            probeKind  = plan.kind,
            probeArgs  = plan.args,
            probeTime  = fireTime,
        })
    end

    O_RecordFire()

    local ok, err, returnVal = false, nil, nil
    local remoteType = target.remoteType

    -- Handle repeat probes (RateAbuse, RedundancyProbe)
    local repeatCount = plan.repeatCount or 1
    local repeatDelay = plan.repeatDelay or 0

    for i = 1, repeatCount do
        if remoteType == "RemoteEvent" then
            ok, err = O_FireRemoteEvent(target.remote, plan.args or {})
        elseif remoteType == "RemoteFunction" then
            ok, err, returnVal = O_InvokeRemoteFunction(
                target.remote, plan.args or {}, OPERATOR_CFG.RFTimeout
            )
        elseif remoteType == "BindableEvent" or remoteType == "BindableFunction" then
            ok, err = O_FireBindable(target.remote, plan.args or {})
        end

        if i < repeatCount and repeatDelay > 0 then
            task.wait(repeatDelay)
        end
    end

    -- Record latency for RemoteFunctions
    if remoteType == "RemoteFunction" and translator then
        local latencyMs = (os.clock() - fireTime) * 1000
        local sentry = _G.PC.AVD and _G.PC.AVD.Sentry
        if sentry then
            sentry.RecordLatency(target.name, latencyMs)
        end
    end

    -- If probe captured a return value, push it as a special event
    if returnVal ~= nil then
        local sentry = _G.PC.AVD and _G.PC.AVD.Sentry
        if sentry then
            -- Manually push a synthetic event for the return value
            local retStr = type(returnVal) == "string" and returnVal
                        or type(returnVal) == "table"  and "table"
                        or tostring(returnVal)
            -- This gets picked up by translator in next ingest cycle
            task.spawn(function()
                if translator then
                    -- Inject a synthetic PROPERTY event carrying the return value
                    translator.Ingest({
                        t        = os.clock(),
                        tier     = 1,
                        kind     = "PROPERTY",
                        path     = target.name .. ".ReturnValue",
                        property = "ReturnValue",
                        newValue = retStr,
                        oldValue = nil,
                        isBaseline = false,
                    })
                end
            end)
        end
    end

    if not ok then
        O_TotalFailed = O_TotalFailed + 1
    end

    -- Close active count after correlation window
    task.delay(
        (translator and translator.SIGNAL and 3.5) or 3.5,
        O_RecordClose
    )

    return ok, err
end

-- ── Main probe loop ───────────────────────────────────────────────────────────
local function O_ProbeLoop()
    while O_Running do
        local strategist = _G.PC.AVD and _G.PC.AVD.Strategist

        if strategist and O_CanFire() then
            local probeRequest = strategist.NextProbe()
            if probeRequest then
                task.spawn(function()
                    local ok, err = O_ExecuteProbe(probeRequest)
                    if not ok then
                        print(string.format("[AVD Operator] Probe %s failed: %s",
                            probeRequest.probeID, tostring(err)))
                    end
                end)
            end
        end

        task.wait(OPERATOR_CFG.ProbeCooldown)
    end
end

-- ── SARP delivery ─────────────────────────────────────────────────────────────
function AVD_Operator.SARPDeliver(handoff)
    local SARP = _G.PC.SARP
    if not SARP then
        warn("[AVD Operator] SARP not available for handoff.")
        return false
    end

    -- Determine best channel via PR_Bridge if available
    local channel = handoff.channel or "Attribute"
    if OPERATOR_CFG.UsePRBridgeChannel then
        local prBridge = _G.PC.PR_Bridge
        if prBridge and prBridge.GetSuggestedChannel then
            local suggested = prBridge.GetSuggestedChannel()
            if suggested then channel = suggested end
        end
    end

    -- Build wrapped payload via SARP Crafter
    local payload   = handoff.payload or {}
    local wrapped, wrapErr

    if channel == "Attribute" then
        wrapped, wrapErr = SARP.Crafter.WrapAttribute(payload, nil, nil)
    elseif channel == "OwnedCarrier" then
        wrapped, wrapErr = SARP.Crafter.WrapOwnedCarrier(payload, nil)
    elseif channel == "AttachmentBridge" then
        wrapped, wrapErr = SARP.Crafter.WrapAttachmentBridge(payload, handoff.remoteName)
    end

    if not wrapped or wrapErr then
        warn(string.format("[AVD Operator] Wrap failed for %s: %s",
            handoff.remoteName, tostring(wrapErr)))
        return false
    end

    -- Simulate before flying
    local simResult = SARP.Simulator and SARP.Simulator.Simulate(wrapped, handoff.remoteName)

    -- Fly via SARP
    SARP.Execute(wrapped, simResult, handoff.remoteName, function(outcome)
        print(string.format("[AVD Operator] SARP outcome for %s: %s",
            handoff.remoteName, tostring(outcome and outcome.Success)))
    end)

    return true
end

-- ── Public API ────────────────────────────────────────────────────────────────
function AVD_Operator.Start()
    if O_Running then return end
    O_Running = true

    -- Wait for Sentry baseline before firing anything active
    task.spawn(function()
        local sentry = _G.PC.AVD and _G.PC.AVD.Sentry
        if sentry then
            while not sentry.IsBaselineDone() do
                task.wait(0.5)
            end
        end

        -- Start passive observation immediately
        O_StartPassive()

        -- Wait a beat then begin active probing
        if not OPERATOR_CFG.PassiveOnly then
            task.wait(2.0)

            -- Ingest targets from RAE and PR
            local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
            if strategist then
                local raeCount = strategist.IngestFromRAE()
                local prCount  = strategist.IngestFromPR()
                print(string.format("[AVD Operator] Targets ingested — RAE: %d  PR: %d",
                    raeCount, prCount))
            end

            O_ProbeLoop()
        end
    end)

    print("[AVD Operator] Started. PassiveOnly=" .. tostring(OPERATOR_CFG.PassiveOnly))
end

function AVD_Operator.Stop()
    O_Running = false
    -- Disconnect passive listeners
    for _, conn in ipairs(O_PassiveConns) do
        pcall(function() conn:Disconnect() end)
    end
    O_PassiveConns  = {}
    O_PassiveActive = false
    print("[AVD Operator] Stopped.")
end

function AVD_Operator.SetPassiveOnly(val)
    OPERATOR_CFG.PassiveOnly = val
end

function AVD_Operator.GetStats()
    return {
        Running      = O_Running,
        PassiveOnly  = OPERATOR_CFG.PassiveOnly,
        TotalFired   = O_TotalFired,
        TotalFailed  = O_TotalFailed,
        ActiveCount  = O_ActiveCount,
        PassiveConns = #O_PassiveConns,
    }
end

function AVD_Operator.GetCFG()
    return OPERATOR_CFG
end

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.AVD then _G.PC.AVD = {} end
_G.PC.AVD.Operator = AVD_Operator

print("[AVD Operator] Ready.")
