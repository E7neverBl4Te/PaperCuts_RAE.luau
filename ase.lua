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
        VERIFY    = 0.08,
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
               RECOMPILE="RECOMPILE", DISCOVER="DISCOVER",
               VERIFY="VERIFY" }
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

-- Per-remote linger dedup: prevents multiple VERIFY goals for same remote
local ASE_LingerPending = {}  -- [remoteName] = true while VERIFY in flight

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
    elseif goal.goalType == ASE.GOAL.VERIFY then
        ok, err = pcall(ASE_VerifyCircuit.Run, goal)
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

-- ══════════════════════════════════════════════════════════════════════════════
-- MODULE 2.5 — LINGER WATCH + PROPERTY STEERING
-- Activated the moment OC_LINGERED is confirmed on a remote.
-- Monitors the four client-writable surfaces LWM is blind to:
--   1. LocalPlayer attributes
--   2. Character part/humanoid properties
--   3. PlayerGui descendant Value objects
--   4. Character descendant Value objects
--
-- Detects "Unusual Deltas" — properties that changed after linger confirmation
-- and stayed changed — which indicate the server communicated via replication
-- rather than a RemoteEvent/RemoteFunction.
--
-- ASE_PropertySteerer then attempts to satisfy the dependency by writing back
-- to each unusual delta candidate and watching for linger resolution.
-- ══════════════════════════════════════════════════════════════════════════════

local ASE_LingerWatch   = {}
local ASE_LW_Sessions   = {}   -- [remoteName] = session record

local LW_SAMPLE_RATE    = 0.05   -- 50ms high-frequency sampling
local LW_MAX_DURATION   = 12.0   -- max watch window per linger
local LW_MAX_SNAPSHOTS  = 60     -- ring buffer depth
local LW_ENTROPY_THRESH = 0.5    -- min "unusualness" score to flag a delta

-- Snapshot the four monitored surfaces into a flat key=value table
local function LW_Snapshot()
    local snap   = {}
    local Players = game:GetService("Players")
    local lp     = Players and Players.LocalPlayer
    if not lp then return snap end

    -- Surface 1: LocalPlayer attributes
    local attrs = lp:GetAttributes()
    for k, v in pairs(attrs) do
        if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            snap["LP_ATTR:" .. k] = v
        end
    end

    -- Surface 2: Character properties (position, humanoid state, health)
    local char = lp.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            snap["CHAR:HRP.X"]  = math.floor(hrp.Position.X * 10) / 10
            snap["CHAR:HRP.Y"]  = math.floor(hrp.Position.Y * 10) / 10
            snap["CHAR:HRP.Z"]  = math.floor(hrp.Position.Z * 10) / 10
        end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            snap["CHAR:HUM.Health"]    = math.floor(hum.Health)
            snap["CHAR:HUM.MaxHealth"] = math.floor(hum.MaxHealth)
            snap["CHAR:HUM.State"]     = tostring(hum:GetState())
            snap["CHAR:HUM.WalkSpeed"] = hum.WalkSpeed
            snap["CHAR:HUM.JumpPower"] = hum.JumpPower
        end

        -- Surface 4: Character descendant Value objects
        for _, obj in ipairs(char:GetDescendants()) do
            if obj:IsA("BoolValue") or obj:IsA("StringValue")
               or obj:IsA("IntValue") or obj:IsA("NumberValue") then
                snap["CHAR_VAL:" .. obj.Name] = obj.Value
            end
        end
    end

    -- Surface 3: PlayerGui descendant Value objects
    local gui = lp:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, obj in ipairs(gui:GetDescendants()) do
            if obj:IsA("BoolValue") or obj:IsA("StringValue")
               or obj:IsA("IntValue") or obj:IsA("NumberValue") then
                snap["GUI_VAL:" .. obj.Name] = obj.Value
            end
        end
    end

    return snap
end

-- Compute delta between two snapshots — returns list of changed keys + magnitude
local function LW_ComputeDelta(baseline, current)
    local deltas = {}
    for k, currVal in pairs(current) do
        local baseVal = baseline[k]
        if baseVal == nil then
            -- New key appeared after linger — high signal
            table.insert(deltas, {
                key       = k,
                from      = nil,
                to        = currVal,
                kind      = "APPEARED",
                magnitude = 1.0,
            })
        elseif currVal ~= baseVal then
            local mag = 0.5
            if type(currVal) == "number" and type(baseVal) == "number" then
                local range = math.abs(baseVal) + 1
                mag = math.min(1.0, math.abs(currVal - baseVal) / range)
            elseif type(currVal) == "boolean" then
                mag = 1.0   -- boolean flip is always high signal
            end
            table.insert(deltas, {
                key       = k,
                from      = baseVal,
                to        = currVal,
                kind      = "CHANGED",
                magnitude = mag,
            })
        end
    end
    -- Check for keys that disappeared
    for k, baseVal in pairs(baseline) do
        if current[k] == nil then
            table.insert(deltas, {
                key       = k,
                from      = baseVal,
                to        = nil,
                kind      = "VANISHED",
                magnitude = 0.8,
            })
        end
    end
    table.sort(deltas, function(a, b) return a.magnitude > b.magnitude end)
    return deltas
end

-- Start a linger watch session for a remote
function ASE_LingerWatch.Start(remoteName)
    if ASE_LW_Sessions[remoteName] then return end  -- already watching

    local session = {
        remoteName    = remoteName,
        startT        = os.clock(),
        baseline      = LW_Snapshot(),
        snapshots     = {},
        unusualDeltas = {},
        active        = true,
        resolved      = false,
    }
    ASE_LW_Sessions[remoteName] = session

    print(string.format("[LW] Linger watch started on %s — monitoring %d baseline keys",
        remoteName, (function() local n=0; for _ in pairs(session.baseline) do n=n+1 end; return n end)()))

    task.spawn(function()
        local t0 = os.clock()
        while session.active and (os.clock() - t0) < LW_MAX_DURATION do
            task.wait(LW_SAMPLE_RATE)
            if not session.active then break end

            local snap = LW_Snapshot()
            table.insert(session.snapshots, { t = os.clock(), data = snap })
            if #session.snapshots > LW_MAX_SNAPSHOTS then
                table.remove(session.snapshots, 1)
            end

            -- Recompute unusual deltas from baseline
            local deltas = LW_ComputeDelta(session.baseline, snap)
            local unusual = {}
            for _, d in ipairs(deltas) do
                if d.magnitude >= LW_ENTROPY_THRESH then
                    table.insert(unusual, d)
                end
            end

            if #unusual > 0 then
                session.unusualDeltas = unusual
            end
        end
        session.active = false
    end)
end

-- Stop the watch session
function ASE_LingerWatch.Stop(remoteName)
    local session = ASE_LW_Sessions[remoteName]
    if session then
        session.active = false
    end
end

-- Get ranked unusual delta candidates for a remote
function ASE_LingerWatch.GetUnusualDeltas(remoteName)
    local session = ASE_LW_Sessions[remoteName]
    return session and session.unusualDeltas or {}
end

-- ── Property Steerer ──────────────────────────────────────────────────────────
-- For each unusual delta candidate, attempts to write the value back to its
-- pre-linger state (or invert it for booleans) and watches for linger resolution.

local ASE_PropertySteerer = {}

-- Resolve a surface key back to the actual Roblox instance + property name
local function LW_ResolveKey(key)
    local Players = game:GetService("Players")
    local lp = Players and Players.LocalPlayer
    if not lp then return nil, nil end

    local surface, name = key:match("^([^:]+):(.+)$")
    if not surface then return nil, nil end

    if surface == "LP_ATTR" then
        -- LocalPlayer attribute — write via SetAttribute
        return lp, name   -- special handling: attribute path

    elseif surface == "CHAR_VAL" then
        local char = lp.Character
        if char then
            local obj = char:FindFirstChild(name, true)
            if obj and obj:IsA("ValueBase") then return obj, "Value" end
        end

    elseif surface == "GUI_VAL" then
        local gui = lp:FindFirstChildOfClass("PlayerGui")
        if gui then
            local obj = gui:FindFirstChild(name, true)
            if obj and obj:IsA("ValueBase") then return obj, "Value" end
        end

    elseif surface == "CHAR" then
        -- HumanoidRootPart or Humanoid property
        local char = lp.Character
        if char then
            if name:find("^HRP%.") then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                local prop = name:gsub("^HRP%.", "")
                return hrp, prop
            elseif name:find("^HUM%.") then
                local hum = char:FindFirstChildOfClass("Humanoid")
                local prop = name:gsub("^HUM%.", "")
                return hum, prop
            end
        end
    end

    return nil, nil
end

-- Attempt to steer each unusual delta candidate and watch for resolution
function ASE_PropertySteerer.Try(remoteName, onResolved)
    local deltas = ASE_LingerWatch.GetUnusualDeltas(remoteName)
    if #deltas == 0 then
        print(string.format("[PS] No unusual deltas for %s — cannot steer.", remoteName))
        return
    end

    print(string.format("[PS] Attempting property steering on %s — %d candidate(s)",
        remoteName, #deltas))

    task.spawn(function()
        for _, delta in ipairs(deltas) do
            -- Compute steering value: invert booleans, revert others to baseline
            local steerVal
            if type(delta.from) == "boolean" then
                steerVal = not delta.to  -- invert the current state
            elseif delta.to == nil and delta.from ~= nil then
                steerVal = delta.from    -- revert vanished key
            else
                steerVal = delta.from    -- revert to pre-linger baseline
            end
            if steerVal == nil then continue end

            -- Write the steered value
            local surface = delta.key:match("^([^:]+):")
            local obj, prop = LW_ResolveKey(delta.key)
            local writeOk = false

            if obj and prop then
                if surface == "LP_ATTR" then
                    writeOk = pcall(function()
                        obj:SetAttribute(prop, steerVal)
                    end)
                else
                    writeOk = pcall(function()
                        obj[prop] = steerVal
                    end)
                end
            end

            if writeOk then
                print(string.format("[PS] Steered %s: %s -> %s",
                    delta.key, tostring(delta.to), tostring(steerVal)))

                -- Watch for 2s to see if linger resolves
                local resolveT = os.clock()
                local resolved = false
                while (os.clock() - resolveT) < 2.0 do
                    task.wait(0.1)
                    -- Check if ASE confirmed the linger resolved
                    -- (BedrockPair locked or Panel became active)
                    if ASE.Panel.HeartbeatAlive or
                       (ASE_BedrockPairs[remoteName] and
                        ASE_BedrockPairs[remoteName].confidence >= 1.0) then
                        resolved = true
                        break
                    end
                end

                if resolved then
                    print(string.format(
                        "[PS] STEERING RESOLVED: %s unblocked by property %s",
                        remoteName, delta.key))
                    ASE_LingerWatch.Stop(remoteName)
                    ASE_AppendTx({
                        directive  = "PROPERTY STEERING RESOLVED",
                        rawPayload = { key=delta.key, from=delta.to, to=steerVal },
                        result     = string.format("DEPENDENCY SATISFIED: %s", delta.key),
                    })
                    if onResolved then onResolved(delta) end
                    return
                end
            end
        end

        print(string.format("[PS] All %d steering attempts exhausted on %s — "
            .. "pivoting to State-Nudge.", #deltas, remoteName))
        -- Property steering exhausted — physical state is the next hypothesis
        ASE_StateNudge.Try(remoteName)
    end)
end

-- Export
ASE_LingerWatch.Steerer = ASE_PropertySteerer

-- ══════════════════════════════════════════════════════════════════════════════
-- MODULE 2.6 — STATE-NUDGE ENGINE
-- Activated when both Ghost Handshake and Property Steering fail.
-- Hypothesis: the server is yielded on a physical precondition —
-- player position, velocity, Humanoid state, or NetworkOwnership —
-- rather than a network packet or replicated value.
--
-- Strategy: cycle through a ranked sequence of physical state mutations
-- during the linger window. After each nudge, poll for 1.5s to see if
-- the lingered thread resolves. On resolution, record the winning nudge
-- as the "State Key" and lock Bedrock with origin = "STATE_NUDGE".
--
-- Nudge sequence (ordered by likelihood for a Teleport-class remote):
--   1. STILLNESS    — zero velocity, WalkSpeed=0, brief anchor
--   2. IDLE_STATE   — force Humanoid to Idle enum state
--   3. POSITION_ADJ — CFrame toward last LWM-sampled position delta
--   4. SPEED_RESTORE— restore WalkSpeed after stillness nudge
--   5. JUMP_INHIBIT — JumpPower=0 to suppress in-air state
--   6. ANCHOR_CYCLE — Anchor then immediately unanchor RootPart
-- ══════════════════════════════════════════════════════════════════════════════

local ASE_StateNudge = {}

local SN_POLL_INTERVAL = 0.10   -- poll rate during resolve watch (seconds)
local SN_NUDGE_WINDOW  = 1.5    -- seconds to watch after each nudge
local SN_RESTORE_DELAY = 0.3    -- seconds before restoring mutated properties

-- Safely read a Humanoid and HumanoidRootPart from LocalPlayer
local function SN_GetPhysics()
    local Players = game:GetService("Players")
    local lp      = Players and Players.LocalPlayer
    if not lp then return nil, nil end
    local char = lp.Character
    if not char then return nil, nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return hum, hrp
end

-- Poll for linger resolution: returns true if Bedrock locked or Panel active
local function SN_PollResolved(remoteName, window)
    local t0 = os.clock()
    while (os.clock() - t0) < window do
        task.wait(SN_POLL_INTERVAL)
        local pair = ASE_BedrockPairs[remoteName]
        if ASE.Panel.HeartbeatAlive then return true end
        if pair and pair.confidence >= 0.90 then return true end
    end
    return false
end

-- Individual nudge implementations ────────────────────────────────────────────

-- STILLNESS: zero velocity, WalkSpeed=0, anchor briefly, then restore
local function SN_Nudge_Stillness(remoteName)
    local hum, hrp = SN_GetPhysics()
    if not hum or not hrp then return false end

    local origSpeed  = hum.WalkSpeed
    local origJump   = hum.JumpPower
    local origAnchor = hrp.Anchored

    -- Apply stillness
    pcall(function() hum.WalkSpeed  = 0 end)
    pcall(function() hum.JumpPower  = 0 end)
    pcall(function() hrp.AssemblyLinearVelocity  = Vector3.new(0, 0, 0) end)
    pcall(function() hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
    pcall(function() hrp.Anchored   = true end)

    print(string.format("[SN] STILLNESS nudge applied on %s", remoteName))
    local resolved = SN_PollResolved(remoteName, SN_NUDGE_WINDOW)

    -- Restore regardless of outcome
    task.delay(SN_RESTORE_DELAY, function()
        pcall(function() hum.WalkSpeed = origSpeed end)
        pcall(function() hum.JumpPower = origJump  end)
        pcall(function() hrp.Anchored  = origAnchor end)
    end)

    return resolved
end

-- IDLE_STATE: force Humanoid into Idle state
local function SN_Nudge_IdleState(remoteName)
    local hum, _ = SN_GetPhysics()
    if not hum then return false end

    pcall(function()
        hum:ChangeState(Enum.HumanoidStateType.None)
    end)
    task.wait(0.05)
    pcall(function()
        hum:ChangeState(Enum.HumanoidStateType.Landed)
    end)

    print(string.format("[SN] IDLE_STATE nudge applied on %s", remoteName))
    return SN_PollResolved(remoteName, SN_NUDGE_WINDOW)
end

-- POSITION_ADJ: nudge CFrame toward most recent LWM position delta
-- If no delta available, nudge slightly downward (land-on-ground heuristic)
local function SN_Nudge_PositionAdj(remoteName)
    local _, hrp = SN_GetPhysics()
    if not hrp then return false end

    local origCF = hrp.CFrame
    local nudgeCF

    -- Check LingerWatch for position deltas
    local deltas = ASE_LingerWatch.GetUnusualDeltas(remoteName)
    local dX, dY, dZ = 0, -2, 0  -- default: settle downward 2 studs
    for _, d in ipairs(deltas) do
        if d.key == "CHAR:HRP.X" and d.from then dX = d.from - (d.to or d.from) end
        if d.key == "CHAR:HRP.Y" and d.from then dY = d.from - (d.to or d.from) end
        if d.key == "CHAR:HRP.Z" and d.from then dZ = d.from - (d.to or d.from) end
    end

    nudgeCF = origCF * CFrame.new(dX, dY, dZ)
    pcall(function() hrp.CFrame = nudgeCF end)

    print(string.format("[SN] POSITION_ADJ nudge applied on %s (dX=%.1f dY=%.1f dZ=%.1f)",
        remoteName, dX, dY, dZ))
    local resolved = SN_PollResolved(remoteName, SN_NUDGE_WINDOW)

    -- Restore position if not resolved
    if not resolved then
        pcall(function() hrp.CFrame = origCF end)
    end
    return resolved
end

-- JUMP_INHIBIT: suppress JumpPower to prevent in-air state detection
local function SN_Nudge_JumpInhibit(remoteName)
    local hum, _ = SN_GetPhysics()
    if not hum then return false end

    local origJump = hum.JumpPower
    pcall(function() hum.JumpPower = 0 end)

    print(string.format("[SN] JUMP_INHIBIT nudge applied on %s", remoteName))
    local resolved = SN_PollResolved(remoteName, SN_NUDGE_WINDOW)

    task.delay(SN_RESTORE_DELAY, function()
        pcall(function() hum.JumpPower = origJump end)
    end)
    return resolved
end

-- ANCHOR_CYCLE: anchor then immediately release — triggers NetworkOwnership reassign
local function SN_Nudge_AnchorCycle(remoteName)
    local _, hrp = SN_GetPhysics()
    if not hrp then return false end

    local origAnchor = hrp.Anchored
    pcall(function() hrp.Anchored = true  end)
    task.wait(0.05)
    pcall(function() hrp.Anchored = false end)

    print(string.format("[SN] ANCHOR_CYCLE nudge applied on %s", remoteName))
    local resolved = SN_PollResolved(remoteName, SN_NUDGE_WINDOW)

    if not resolved then
        pcall(function() hrp.Anchored = origAnchor end)
    end
    return resolved
end

-- Nudge sequence table — ordered by likelihood for Teleport-class remotes
local SN_SEQUENCE = {
    { name = "STILLNESS",    fn = SN_Nudge_Stillness    },
    { name = "IDLE_STATE",   fn = SN_Nudge_IdleState    },
    { name = "POSITION_ADJ", fn = SN_Nudge_PositionAdj  },
    { name = "JUMP_INHIBIT", fn = SN_Nudge_JumpInhibit  },
    { name = "ANCHOR_CYCLE", fn = SN_Nudge_AnchorCycle  },
}

-- Main entry: run nudge sequence for a lingered remote
function ASE_StateNudge.Try(remoteName, onResolved)
    print(string.format("[SN] Starting State-Nudge sequence on %s (%d nudge(s))",
        remoteName, #SN_SEQUENCE))

    ASE_AppendTx({
        directive  = string.format("STATE-NUDGE: %s", remoteName),
        rawPayload = {},
        result     = string.format("Cycling %d physical state nudges...", #SN_SEQUENCE),
    })

    task.spawn(function()
        for _, nudge in ipairs(SN_SEQUENCE) do
            -- Check if already resolved by another path
            if ASE.Panel.HeartbeatAlive or
               (ASE_BedrockPairs[remoteName] and
                ASE_BedrockPairs[remoteName].confidence >= 0.90) then
                print(string.format("[SN] Already resolved before %s nudge — stopping.",
                    nudge.name))
                return
            end

            local ok, resolved = pcall(nudge.fn, remoteName)
            if ok and resolved then
                print(string.format(
                    "[SN] RESOLVED: %s unblocked by nudge %s",
                    remoteName, nudge.name))

                -- Lock as Bedrock with STATE_NUDGE origin
                ASE_BedrockPairs[remoteName] = {
                    sinkRemote     = remoteName,
                    feedbackRemote = nil,
                    nonce          = nil,
                    confirmedAt    = os.clock(),
                    cargo          = {},
                    confidence     = 0.85,
                    origin         = "STATE_NUDGE",
                    nudgeKey       = nudge.name,
                }
                ASE.Panel.Visible        = true
                ASE.Panel.ActiveSink     = remoteName
                ASE.Panel.ActiveFeedback = nil
                ASE.Panel.BedrockConf    = 0.85
                ASE.Panel.HeartbeatAlive = true

                local CSK = _G.PC.CSK
                if CSK then
                    CSK.Annotate(remoteName, string.format(
                        "BEDROCK via STATE_NUDGE: key=%s", nudge.name))
                end

                ASE_AppendTx({
                    directive  = "STATE-NUDGE RESOLVED",
                    rawPayload = { nudge = nudge.name },
                    result     = string.format("BEDROCK [STATE_NUDGE:%s]", nudge.name),
                })

                ASE_LingerWatch.Stop(remoteName)
                if onResolved then onResolved(nudge.name) end
                return
            elseif not ok then
                print(string.format("[SN] Nudge %s errored: %s",
                    nudge.name, tostring(resolved)))
            end
        end

        -- All nudges exhausted
        print(string.format(
            "[SN] All nudges exhausted on %s — linger is server-internal.",
            remoteName))
        ASE_AppendTx({
            directive  = string.format("STATE-NUDGE EXHAUSTED: %s", remoteName),
            rawPayload = {},
            result     = "Dependency is server-internal — cooldown or global state.",
        })
        ASE_LingerWatch.Stop(remoteName)
    end)
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

    if not sinkRemote then
        error("Sink remote not specified for BEDROCK goal")
    end

    -- PR_Registry may not yet contain remotes discovered only via APE/SBI probing.
    -- Fall back to RSM or APE campaign data before hard-failing.
    if not PR or not PR[sinkRemote] then
        local RSM = _G.PC.RSM
        local APE = _G.PC.APE
        local knownViaRSM = RSM and RSM.Get(sinkRemote) ~= nil
        local knownViaAPE = false
        if APE then
            for _, c in ipairs(APE.GetCampaigns() or {}) do
                if c.remoteName == sinkRemote then knownViaAPE = true; break end
            end
        end
        if not knownViaRSM and not knownViaAPE then
            error("Sink remote not found in PR/RSM/APE: " .. tostring(sinkRemote))
        end
        -- Known via RSM or APE — proceed with caution, no PR data available
        warn(string.format(
            "[ASE Bedrock] %s not in PR_Registry — proceeding from %s data only.",
            sinkRemote, knownViaRSM and "RSM" or "APE"))
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

    -- ── Wait for APE to finish its own boot sequence ──────────────────────────
    -- APE bootstraps itself asynchronously after its dependencies (SBI, RSM, SR,
    -- AVD) are ready. DISCOVER goals pushed early by OnAVDFinding arrive before
    -- APE_Running flips true, causing every StartCampaign to fail with
    -- "APE not running". We wait up to 60 s before giving up.
    local APE = nil
    local waitT0 = os.clock()
    while os.clock() - waitT0 < 60 do
        APE = _G.PC.APE
        if APE and APE.GetStats and APE.GetStats().Running then break end
        task.wait(1.0)
    end

    if not APE then error("APE module never registered in _G.PC.APE") end
    if not APE.GetStats().Running then
        error("APE not running after 60 s wait — dependencies may have failed to load")
    end

    if not remoteName then
        -- No specific remote: trigger a full priority scan
        local n = APE.Scan()
        goal.result = { campaignCount=n }
        return
    end

    -- ── Attempt to start the campaign ─────────────────────────────────────────
    local id, err = APE.StartCampaign(remoteName)

    if not id then
        local errStr = tostring(err)

        if errStr:find("no goals") or errStr:find("no plan") then
            -- APE is running but hasn't built a probe plan for this remote yet.
            -- Force a Scan to populate the scorer, then retry once.
            print(string.format("[ASE DISCOVER] No probe plan for %s — forcing Scan + retry.", remoteName))
            APE.Scan()
            task.wait(3)
            id, err = APE.StartCampaign(remoteName)
            errStr = tostring(err)
        end

        if not id then
            if errStr:find("already active") then
                -- A campaign for this remote is already in flight.
                -- Locate it and wait on it rather than erroring.
                local existing = nil
                for _, c in ipairs(APE.GetCampaigns()) do
                    if c.remoteName == remoteName and
                       (c.status == "RUNNING" or c.status == "ACTIVE") then
                        existing = c; break
                    end
                end
                if existing then
                    print(string.format(
                        "[ASE DISCOVER] Campaign for %s already active (id=%s) — attaching.", remoteName, tostring(existing.id)))
                    id = existing.id
                else
                    goal.result = { status="SKIPPED", reason="already active, not found" }
                    return
                end
            elseif errStr:find("max concurrent") then
                -- APE is at campaign capacity — back off and retry once
                print("[ASE DISCOVER] APE at max concurrent campaigns — waiting 10 s.")
                task.wait(10)
                id, err = APE.StartCampaign(remoteName)
                if not id then
                    error("APE campaign failed after backoff: " .. tostring(err))
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
-- MODULE 4B — VERIFY TOPOLOGICAL CIRCUIT
-- Triggered by LINGERED: sends a high-entropy nonce shaped to
-- the remote's RSM arg signature, listens on all S2C remotes
-- for the nonce to return. Only on confirmed return does ASE
-- promote the remote to a full BEDROCK pipeline.
--
--   LINGERED  →  "server held the thread, didn't reject"
--   BEDROCK   →  "server echoed our nonce on a different channel"
-- ═════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════════════════════
-- GHOST HANDSHAKE BUFFER
-- Pre-fire infrastructure for closing the Temporal Deadlock.
--
-- The server fires a RemoteEvent:FireClient() challenge immediately after
-- executing the anchor payload. Because the challenge arrives in the window
-- between SARP.Execute and any listener setup, the client misses it and the
-- server thread suspends. This buffer is opened BEFORE SARP fires, so the
-- fast-path responder is already live when the challenge arrives.
--
-- ASE_QueryBuddyRemotes   — CDG + temporal co-occurrence buddy lookup
-- ASE_OpenHandshakeBuffer — pre-fire S2C listeners that capture & respond
-- ══════════════════════════════════════════════════════════════════════════════

-- Query CDG and PR for remotes that are causally adjacent to sinkName.
-- Returns a list of {name, confidence, kind} sorted by confidence desc.
-- kind: "CDG_INBOUND", "CDG_OUTBOUND", "TEMPORAL_BUDDY"
local function ASE_QueryBuddyRemotes(sinkName)
    local CDG = _G.PC and _G.PC.CDG
    local PR  = _G.PC.PR_Registry
    local out = {}
    local seen = {}

    -- 1. CDG strong edges: both inbound (X->sink) and outbound (sink->X)
    if CDG then
        local edges = CDG.GetStrongEdges(0.20)
        for _, edge in ipairs(edges) do
            -- Inbound: something fires just before sink — likely the trigger
            if edge.ToID == sinkName and not seen[edge.FromID] then
                seen[edge.FromID] = true
                table.insert(out, {
                    name       = edge.FromID,
                    confidence = edge.Confidence,
                    kind       = "CDG_INBOUND",
                })
            end
            -- Outbound: sink fires just before something — likely the resolver
            if edge.FromID == sinkName and not seen[edge.ToID] then
                seen[edge.ToID] = true
                table.insert(out, {
                    name       = edge.ToID,
                    confidence = edge.Confidence,
                    kind       = "CDG_OUTBOUND",
                })
            end
        end
    end

    -- 2. PR temporal co-occurrence: remotes that fire within 120ms of sinkName
    -- PR_Registry stores LastFired timestamps per remote; compare them
    if PR then
        local sinkRec = PR[sinkName]
        local sinkT   = sinkRec and sinkRec.LastFired or 0
        for name, rec in pairs(PR) do
            if name ~= sinkName and not seen[name] and rec.LastFired then
                local gap = math.abs(rec.LastFired - sinkT)
                if gap <= 0.120 then
                    seen[name] = true
                    table.insert(out, {
                        name       = name,
                        confidence = math.max(0.20, 1.0 - gap / 0.120),
                        kind       = "TEMPORAL_BUDDY",
                    })
                end
            end
        end
    end

    -- Sort descending by confidence
    table.sort(out, function(a, b) return a.confidence > b.confidence end)
    return out
end

-- Open fast-path S2C responders on all buddy remotes BEFORE the anchor fires.
-- Each responder:
--   1. Captures the server's challenge args the moment they arrive
--   2. Mirrors any high-entropy tokens (GUIDs, timestamps, position vectors)
--      back into the Stage 2 resolver payload
--   3. Fires the resolver immediately — no task.wait — in the same Lua
--      resumption cycle so the server's micro-window is satisfied
--
-- Returns a buffer handle: { cleanup(), handshakeCompleted, resolverFired,
--                             capturedArgs, resolverName }
local function ASE_OpenHandshakeBuffer(sinkName, anchorEnvelope, nonce, buddies)
    local PR   = _G.PC.PR_Registry
    local SARP = _G.PC.SARP
    local conns = {}
    local done  = false

    local handle = {
        handshakeCompleted = false,
        resolverFired      = false,
        capturedArgs       = nil,
        resolverName       = nil,
        cleanup            = function() end,
    }

    if not PR then return handle end

    -- Parameter mirror: extract high-entropy tokens from server challenge args
    -- and splice them into a resolver payload alongside the original anchor args
    local function ASE_MirrorParams(challengeArgs, resolverRec)
        local RSM = _G.PC.RSM
        local rsmRec = RSM and RSM.Get(resolverRec.Name or "")
        local payload = {}

        -- Start from known-good anchor args as baseline
        for i, v in ipairs(anchorEnvelope) do payload[i] = v end

        -- Walk challenge args: look for GUIDs, timestamps, high-entropy strings
        -- and splice into matching resolver slots
        local function isHighEntropy(v)
            if type(v) == "string" and #v >= 8 then return true end
            if type(v) == "number" and v > 100000 then return true end  -- timestamp-like
            return false
        end

        local function walkChallenge(args, depth)
            if depth > 4 then return end
            for _, v in ipairs(args) do
                if type(v) == "table" then
                    walkChallenge(v, depth + 1)
                elseif isHighEntropy(v) then
                    -- Find first empty or placeholder slot in payload to inject
                    if rsmRec and rsmRec.ArgSig then
                        for slot, sig in ipairs(rsmRec.ArgSig) do
                            if type(v) == type(payload[slot] or v) then
                                -- Only override if this slot type matches
                                if not payload[slot] or payload[slot] == 0 or payload[slot] == "" then
                                    payload[slot] = v
                                end
                            end
                        end
                    else
                        -- No RSM — just append the token
                        table.insert(payload, v)
                    end
                end
            end
        end
        walkChallenge(challengeArgs, 0)

        -- Always embed the nonce in a __handshake field so server can match
        if type(payload[1]) == "table" then
            payload[1].__handshake = nonce
            payload[1].__stage     = 2
        end

        return payload
    end

    -- Build multimodal listenTargets:
    --   RE targets  — all S2C/BOTH RemoteEvents (OnClientEvent listeners)
    --   RF targets  — all RemoteFunctions + buddies (InvokeServer return path)
    -- These are kept separate so each path gets the right handler.
    local listenTargets_RE = {}   -- RemoteEvent targets
    local listenTargets_RF = {}   -- RemoteFunction targets

    -- Seed with CDG buddies first
    for _, buddy in ipairs(buddies) do
        local rec = PR[buddy.name]
        if rec then
            if rec.RemoteType == "RemoteFunction" then
                listenTargets_RF[buddy.name] = true
            else
                listenTargets_RE[buddy.name] = true
            end
        end
    end

    -- Wide net: all S2C/BOTH RemoteEvents
    for name, rec in pairs(PR) do
        if rec.RemoteType == "RemoteEvent" and
           (rec.Direction == "S2C" or rec.Direction == "BOTH") then
            listenTargets_RE[name] = true
        end
    end

    -- Wide net: ALL RemoteFunctions — their return value is the challenge
    -- The sink itself is included here; InvokeServer on the sink returns
    -- the server's response inline — no separate FireClient.
    for name, rec in pairs(PR) do
        if rec.RemoteType == "RemoteFunction" then
            listenTargets_RF[name] = true
        end
    end

    -- Unified view for the OnClientEvent loop below
    local listenTargets = listenTargets_RE

    for rname, _ in pairs(listenTargets) do
        local rec = PR[rname]
        if rec and rec.Remote then
            local ok, conn = pcall(function()
                return rec.Remote.OnClientEvent:Connect(function(...)
                    if done then return end
                    local challengeArgs = {...}

                    -- Check if this looks like a challenge aimed at our anchor
                    -- Heuristic: contains nonce, OR arrived within 1.5s of buffer open
                    local isChallenge = false
                    local function scanForNonce(v, depth)
                        if depth > 4 then return end
                        if type(v) == "string" and v:find(nonce, 1, true) then
                            isChallenge = true; return
                        end
                        if type(v) == "table" then
                            for _, child in pairs(v) do
                                scanForNonce(child, depth + 1)
                                if isChallenge then return end
                            end
                        end
                    end
                    scanForNonce(challengeArgs, 0)

                    -- Also treat any S2C fire from a buddy remote as a potential
                    -- challenge — even without nonce, timing correlation is enough
                    if not isChallenge then
                        for _, buddy in ipairs(buddies) do
                            if buddy.name == rname and buddy.confidence >= 0.40 then
                                isChallenge = true
                                break
                            end
                        end
                    end

                    if isChallenge then
                        done = true
                        handle.capturedArgs = challengeArgs
                        handle.resolverName = rname

                        -- ── FAST-PATH RESPONSE ─────────────────────────────
                        -- Build Stage 2 resolver payload and fire immediately.
                        -- This runs in the same Lua resumption — no yield.
                        local resolverRec = PR[rname]
                        if resolverRec and resolverRec.Remote and SARP then
                            local stage2Payload = ASE_MirrorParams(challengeArgs, {Name=rname})
                            local wrapped2, sim2 = pcall(function()
                                return SARP.Build("Attribute", stage2Payload, nil, nil, rname)
                            end)
                            if wrapped2 and sim2 then
                                -- Fire without waiting — same scheduler frame
                                pcall(SARP.Execute, sim2, nil, rname, function(ok2)
                                    handle.resolverFired      = ok2
                                    handle.handshakeCompleted = ok2
                                end)
                            else
                                -- SARP.Build returned (ok, wrapped, sim) — pcall wrapping issue
                                -- Fallback: direct FireServer with mirrored payload
                                pcall(function()
                                    resolverRec.Remote:FireServer(table.unpack(stage2Payload))
                                end)
                                handle.resolverFired      = true
                                handle.handshakeCompleted = true
                            end

                            print(string.format(
                                "[ASE VERIFY] Ghost handshake caught on %s — Stage 2 fired immediately.",
                                rname))
                        end
                    end
                end)
            end)
            if ok and conn then table.insert(conns, conn) end
        end
    end

    -- ── RemoteFunction invoke path ────────────────────────────────────────────
    -- Iterates over listenTargets_RF — every RF in the registry, including the
    -- sink itself. For a RF, InvokeServer IS the handshake: the return value is
    -- the server's challenge. No separate FireClient is ever sent.
    -- Each invoke runs in its own task.spawn so they race in parallel.
    -- First one to capture a non-nil return wins; others drop out via done guard.
    local RFInvokeTimeout = 3.0
    for rname, _ in pairs(listenTargets_RF) do
        local rec = PR[rname]
        if rec and rec.Remote and rec.RemoteType == "RemoteFunction" then
            task.spawn(function()
                if done then return end
                -- Build the invoke payload: use anchor envelope as baseline
                -- (the RF likely expects the same arg shape as the sink)
                local invokePayload = {}
                for i, v in ipairs(anchorEnvelope) do invokePayload[i] = v end

                -- Fire InvokeServer — return value IS the server's challenge
                local invokeOk, returnVal = pcall(function()
                    return rec.Remote:InvokeServer(table.unpack(invokePayload))
                end)

                if done then return end  -- another path already resolved

                if invokeOk and returnVal ~= nil then
                    -- Normalize return into an args table
                    local challengeArgs = type(returnVal) == "table"
                        and returnVal or { returnVal }

                    done = true
                    handle.capturedArgs = challengeArgs
                    handle.resolverName = rname

                    -- Build Stage 2 payload with mirrored tokens
                    local stage2Payload = ASE_MirrorParams(challengeArgs, {Name = rname})

                    -- Fire Stage 2 resolver — same task, no additional yield
                    local resolverRec = PR[rname]
                    if resolverRec and resolverRec.Remote then
                        if resolverRec.RemoteType == "RemoteFunction" then
                            -- RF resolver: InvokeServer with stage 2 payload
                            local s2ok = pcall(function()
                                resolverRec.Remote:InvokeServer(table.unpack(stage2Payload))
                            end)
                            handle.resolverFired      = s2ok
                            handle.handshakeCompleted = s2ok
                        else
                            -- RE resolver: FireServer with stage 2 payload
                            pcall(function()
                                resolverRec.Remote:FireServer(table.unpack(stage2Payload))
                            end)
                            handle.resolverFired      = true
                            handle.handshakeCompleted = true
                        end
                    end

                    print(string.format(
                        "[ASE VERIFY] RF invoke path: challenge captured on %s — Stage 2 fired.",
                        rname))
                end
            end)
        end
    end

    handle.cleanup = function()
        done = true
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    end

    return handle
end

ASE_VerifyCircuit = {}

function ASE_VerifyCircuit.Run(goal)
    local remoteName = goal.params.remoteName
    local PR         = _G.PC.PR_Registry
    local RSM        = _G.PC.RSM
    local SARP       = _G.PC.SARP
    local SBI        = _G.PC.SBI

    if not remoteName then error("VERIFY requires remoteName") end
    if not PR or not PR[remoteName] then
        error("Remote not in PR registry: " .. tostring(remoteName))
    end

    print(string.format("[ASE VERIFY] Beginning topological circuit check on %s", remoteName))

    -- ── STEP 1: Build nonce + shaped anchor envelope ───────────────────────
    local nonce    = ASE_GenNonce()
    local rsmRec   = RSM and RSM.Get(remoteName)
    local envelope = {}

    if rsmRec and rsmRec.ArgSig and #rsmRec.ArgSig > 0 then
        local embedded = false
        for i, argSig in ipairs(rsmRec.ArgSig) do
            if argSig.DominantType == "table" then
                envelope[i] = { __nonce = nonce, __verify = true }
                embedded = true
            elseif argSig.DominantType == "number" and #(argSig.SuccessValues or {}) > 0 then
                envelope[i] = argSig.SuccessValues[1]
            elseif argSig.DominantType == "string" then
                if not embedded and i == 1 then
                    envelope[i] = nonce
                    embedded = true
                elseif #(argSig.SuccessStrings or {}) > 0 then
                    envelope[i] = argSig.SuccessStrings[1]
                end
            end
        end
        if not embedded then
            envelope = { __nonce = nonce, __verify = true }
        end
    else
        envelope = { __nonce = nonce, __verify = true }
    end

    goal.result = { nonce=nonce, remoteName=remoteName }

    -- ── STEP 2: Query buddy remotes for Handshake Buffer ──────────────────
    -- Done before any wire activity so buffer is primed when server challenge
    -- arrives in the micro-window immediately after the anchor fires.
    local buddies = ASE_QueryBuddyRemotes(remoteName)
    if #buddies > 0 then
        local bnames = {}
        for _, b in ipairs(buddies) do
            table.insert(bnames, string.format("%s(%s,%.2f)", b.name, b.kind, b.confidence))
        end
        print(string.format("[ASE VERIFY] Handshake buffer arming — %d buddy(s): %s",
            #buddies, table.concat(bnames, ", ")))
    else
        print("[ASE VERIFY] No CDG buddies — buffer will cast wide net on all S2C remotes.")
    end

    -- ── STEP 3: Open Handshake Buffer BEFORE SARP fires ───────────────────
    -- This is the critical inversion. The buffer is live when the server sends
    -- its challenge, so the fast-path responder can reply in the same frame.
    local buffer = ASE_OpenHandshakeBuffer(remoteName, envelope, nonce, buddies)

    -- ── STEP 4: Open passive nonce echo listener (fallback path) ──────────
    -- If the server does push a nonce outward on a different channel (original
    -- VERIFY model), this catches it as before.
    local captured       = false
    local feedbackRemote = nil

    local listener = ASE_OpenNonceListener(nonce, function(rname, args)
        captured       = true
        feedbackRemote = rname
    end)

    ASE_AppendTx({
        directive  = string.format("VERIFY CIRCUIT: %s", remoteName),
        rawPayload = envelope,
        nonce      = nonce,
        result     = string.format("Buffer armed (%d buddies) — firing anchor...", #buddies),
    })

    -- ── STEP 5: Fire anchor via SARP ──────────────────────────────────────
    local wrapped, sim, buildErr = SARP and SARP.Build("Attribute", envelope, nil, nil, remoteName)
    if not wrapped then
        buffer.cleanup()
        if listener then listener.cleanup() end
        ASE_LingerPending[remoteName] = nil
        error("VERIFY SARP.Build failed: " .. tostring(buildErr))
    end

    SARP.Execute(wrapped, sim, remoteName, function(success, result, err)
        goal.result.sarpSuccess = success
    end)

    -- ── STEP 6: Wait for confirmation ─────────────────────────────────────
    -- Three resolution paths (checked in priority order):
    --   A. Ghost handshake completed — buffer caught challenge + fired Stage 2
    --   B. Nonce echo received — server pushed nonce on outbound channel
    --   C. Timeout — neither path resolved within NonceListenTimeout
    local t0 = os.clock()
    while not buffer.handshakeCompleted and not captured
          and (os.clock() - t0) < ASE_CFG.NonceListenTimeout do
        task.wait(0.10)
        if goal.status == ASE.STATUS.ABORTED then
            buffer.cleanup()
            if listener then listener.cleanup() end
            ASE_LingerPending[remoteName] = nil
            return
        end
    end

    buffer.cleanup()
    if listener then listener.cleanup() end
    ASE_LingerPending[remoteName] = nil

    -- Determine confirmation source
    local confirmed    = false
    local resolvedVia  = nil
    local resolverName = nil

    if buffer.handshakeCompleted then
        -- Path A: Ghost handshake — two-stage execution chain closed
        confirmed    = true
        resolvedVia  = "GHOST_HANDSHAKE"
        resolverName = buffer.resolverName
        feedbackRemote = resolverName
        print(string.format(
            "[ASE VERIFY] GHOST HANDSHAKE CLOSED: %s stage-2 via %s",
            remoteName, tostring(resolverName)))
    elseif captured then
        -- Path B: Classic nonce echo
        confirmed   = true
        resolvedVia = "NONCE_ECHO"
        print(string.format(
            "[ASE VERIFY] NONCE ECHO CONFIRMED: %s feedback via %s",
            remoteName, tostring(feedbackRemote)))
    end

    if confirmed then
        -- ── CIRCUIT CONFIRMED ─────────────────────────────────────────────
        local origin = resolvedVia == "GHOST_HANDSHAKE"
            and "LINGER_GHOST_HANDSHAKE"
            or  "LINGER_VERIFY"

        ASE_BedrockPairs[remoteName] = {
            sinkRemote     = remoteName,
            feedbackRemote = feedbackRemote,
            nonce          = nonce,
            confirmedAt    = os.clock(),
            cargo          = {},
            confidence     = 1.0,
            origin         = origin,
            resolvedVia    = resolvedVia,
            capturedArgs   = buffer.capturedArgs,
        }

        ASE.Panel.Visible        = true
        ASE.Panel.ActiveSink     = remoteName
        ASE.Panel.ActiveFeedback = feedbackRemote
        ASE.Panel.BedrockConf    = 1.0
        ASE.Panel.HeartbeatAlive = true

        local CSK = _G.PC.CSK
        if CSK then
            CSK.Annotate(remoteName, string.format(
                "BEDROCK via %s: %s (nonce=%s)",
                origin, tostring(feedbackRemote), nonce:sub(1,8)))
        end

        goal.result.confirmed      = true
        goal.result.feedbackRemote = feedbackRemote
        goal.result.resolvedVia    = resolvedVia

        ASE_AppendTx({
            directive  = "CIRCUIT CONFIRMED",
            rawPayload = {sink=remoteName, feedback=feedbackRemote, via=resolvedVia},
            nonce      = nonce,
            result     = string.format("BEDROCK [%s] — Panel active", resolvedVia),
        })

        ASE_BedrockHandshake.StartHeartbeat(remoteName)
    else
        -- ── NO CIRCUIT RESOLVED ───────────────────────────────────────────
        -- Log whether buffer caught anything (ghost challenge seen but Stage 2 failed)
        local bufferNote = buffer.capturedArgs
            and string.format(" (ghost challenge caught on %s — Stage 2 did not complete)",
                tostring(buffer.resolverName))
            or  " (no challenge captured)"

        print(string.format(
            "[ASE VERIFY] %s lingered but circuit did not close%s",
            remoteName, bufferNote))

        goal.result.confirmed     = false
        goal.result.bufferCaptured = buffer.capturedArgs ~= nil

        ASE_AppendTx({
            directive  = string.format("VERIFY FAILED: %s", remoteName),
            rawPayload = { bufferCaught = buffer.capturedArgs ~= nil },
            nonce      = nonce,
            result     = "LINGERED — circuit open" .. bufferNote,
        })

        -- Ghost handshake and nonce echo both failed.
        -- Escalate to Property Steering: check LingerWatch for unusual deltas
        -- on the four client-writable surfaces and attempt to satisfy the
        -- server's in-process dependency directly.
        local unusualDeltas = ASE_LingerWatch.GetUnusualDeltas(remoteName)
        if #unusualDeltas > 0 then
            print(string.format(
                "[ASE VERIFY] %d unusual delta(s) detected — escalating to Property Steering.",
                #unusualDeltas))
            ASE_PropertySteerer.Try(remoteName, function(resolvedDelta)
                -- Property steering resolved — lock as Bedrock with STATE_GATE origin
                ASE_BedrockPairs[remoteName] = {
                    sinkRemote     = remoteName,
                    feedbackRemote = nil,
                    nonce          = nonce,
                    confirmedAt    = os.clock(),
                    cargo          = {},
                    confidence     = 0.90,
                    origin         = "STATE_GATE",
                    resolvedDelta  = resolvedDelta,
                }
                ASE.Panel.Visible        = true
                ASE.Panel.ActiveSink     = remoteName
                ASE.Panel.ActiveFeedback = nil
                ASE.Panel.BedrockConf    = 0.90
                ASE.Panel.HeartbeatAlive = true
                local CSK = _G.PC.CSK
                if CSK then
                    CSK.Annotate(remoteName, string.format(
                        "BEDROCK via STATE_GATE: dependency=%s", resolvedDelta.key))
                end
            end)
        else
            -- No replication deltas found — pivot to State-Nudge.
            -- The dependency is physical rather than data-driven.
            print(string.format(
                "[ASE VERIFY] No unusual deltas on %s — pivoting to State-Nudge.",
                remoteName))
            ASE_StateNudge.Try(remoteName)
        end
    end
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

-- Linger escalation entry point: called by AVD Operator when SARP returns LINGERED
-- Triggers VERIFY_TOPOLOGICAL_CIRCUIT to confirm whether the linger means
-- the server is acting as a steering proxy (Bedrock) or just slow (Warm Lead only)
function ASE.OnLingerConfirmed(remoteName, sarpResult)
    if not remoteName then return end

    -- Deduplicate: skip if already verifying this remote
    if ASE_LingerPending[remoteName] then
        return
    end

    -- Skip if already a confirmed Bedrock pair with live heartbeat
    local existing = ASE_BedrockPairs[remoteName]
    if existing and existing.confidence >= 0.8 and ASE.Panel.HeartbeatAlive then
        return
    end

    print(string.format(
        "[ASE] LINGER confirmed on %s — queuing VERIFY_TOPOLOGICAL_CIRCUIT.", remoteName))

    -- Start linger watch immediately — before VERIFY runs — so we capture
    -- any property deltas that occur in the linger window
    ASE_LingerWatch.Start(remoteName)

    ASE_LingerPending[remoteName] = true
    ASE_GoalEngine.Push(ASE.GOAL.VERIFY, { remoteName=remoteName, sarpResult=sarpResult })
end

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
_G.PC.ASE_VerifyCircuit     = ASE_VerifyCircuit
_G.PC.ASE_LingerWatch       = ASE_LingerWatch
_G.PC.ASE_PropertySteerer   = ASE_PropertySteerer
_G.PC.ASE_StateNudge        = ASE_StateNudge
print("[ASE] Module registered.")
