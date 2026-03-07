-- ── Imports ──────────────────────────────────────────────────────────────────
local _C = _G.PC
local RunService     = _C.RunService
local Players        = _C.Players
local ReplicatedStorage = _C.ReplicatedStorage
local Workspace      = _C.Workspace

-- ============================================================
-- AVD SENTRY — Independent State Observer
-- Runs constantly in the background regardless of probe state.
-- Watches the DataModel for ANY change, timestamps it, and
-- streams raw events to the Translator.
-- Never touches remotes. Never fires anything. Only watches.
-- ============================================================

local SENTRY_CFG = {
    -- How many raw events to keep in the ring buffer
    EventCap         = 512,
    -- How deep to watch the DataModel tree
    WatchDepth       = 6,
    -- Containers to watch for ChildAdded / DescendantAdded
    WatchRoots       = {
        "ReplicatedStorage",
        "Workspace",
        "Players",
        "Lighting",
        "ReplicatedFirst",
    },
    -- Properties to watch per class (surgical Tier 1 observation)
    PropertyMap = {
        NumberValue     = { "Value" },
        IntValue        = { "Value" },
        BoolValue       = { "Value" },
        StringValue     = { "Value" },
        Vector3Value    = { "Value" },
        CFrameValue     = { "Value" },
        ObjectValue     = { "Value" },
        Humanoid        = { "Health", "WalkSpeed", "JumpPower", "MaxHealth" },
        BasePart        = { "CFrame", "Position", "Anchored", "CanCollide" },
        Tool            = { "Enabled" },
        Model           = { "PrimaryPart" },
    },
    -- Transient instance lifetime threshold (seconds)
    -- Instances that live shorter than this are flagged as debris
    DebrisThreshold  = 2.0,
    -- Baseline window: how long to observe before probes start (seconds)
    BaselineWindow   = 8.0,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local AVD_Sentry = {}

-- Raw event ring buffer
local S_Events    = {}
local S_EventPtr  = 0
local S_EventCount = 0

-- Baseline snapshot: property values before any probe
local S_Baseline  = {}

-- Active property watchers: [instance][property] = connection
local S_Watchers  = {}

-- Debris tracker: [instance] = spawnTime
local S_Debris    = {}

-- Connection cleanup list
local S_Conns     = {}

-- Timing
local S_StartTime    = os.clock()
local S_BaselineDone = false
local S_Running      = false

-- ── Event types ───────────────────────────────────────────────────────────────
-- Each raw event has:
--   t          : os.clock() timestamp
--   tier       : 1-5 (which observation tier caught it)
--   kind       : "PROPERTY" | "CHILD_ADDED" | "CHILD_REMOVED" |
--                "DEBRIS" | "ATTRIBUTE" | "LATENCY" | "DESCENDANT"
--   path       : full DataModel path string
--   instance   : the Instance involved (if still exists)
--   property   : property name (for PROPERTY events)
--   oldValue   : value before change (for PROPERTY events)
--   newValue   : value after change
--   isBaseline : true if captured during baseline window

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function S_GetPath(inst)
    local parts = {}
    local cur = inst
    local depth = 0
    while cur and cur ~= game and depth < SENTRY_CFG.WatchDepth do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
        depth = depth + 1
    end
    return table.concat(parts, ".")
end

local function S_Push(event)
    event.t          = event.t or os.clock()
    event.isBaseline = not S_BaselineDone
    S_EventPtr       = (S_EventPtr % SENTRY_CFG.EventCap) + 1
    S_Events[S_EventPtr] = event
    S_EventCount     = math.min(S_EventCount + 1, SENTRY_CFG.EventCap)

    -- Forward to Translator immediately if available
    local translator = _G.PC and _G.PC.AVD and _G.PC.AVD.Translator
    if translator and translator.Ingest then
        pcall(translator.Ingest, event)
    end
end

-- ── Tier 1: Surgical property watchers ───────────────────────────────────────
local function S_WatchProperties(inst)
    if not inst or not inst.Parent then return end
    local className = inst.ClassName
    local props = SENTRY_CFG.PropertyMap[className]
    if not props then return end

    if not S_Watchers[inst] then S_Watchers[inst] = {} end

    for _, prop in ipairs(props) do
        if not S_Watchers[inst][prop] then
            local ok, conn = pcall(function()
                -- Snapshot baseline value
                local baseline_ok, bval = pcall(function() return inst[prop] end)
                if baseline_ok then
                    if not S_Baseline[inst] then S_Baseline[inst] = {} end
                    S_Baseline[inst][prop] = bval
                end

                return inst:GetPropertyChangedSignal(prop):Connect(function()
                    local ok2, newVal = pcall(function() return inst[prop] end)
                    if not ok2 then return end
                    local oldVal = S_Baseline[inst] and S_Baseline[inst][prop]
                    -- Update baseline
                    if not S_Baseline[inst] then S_Baseline[inst] = {} end
                    S_Baseline[inst][prop] = newVal
                    S_Push({
                        tier     = 1,
                        kind     = "PROPERTY",
                        path     = S_GetPath(inst),
                        instance = inst,
                        property = prop,
                        oldValue = oldVal,
                        newValue = newVal,
                    })
                end)
            end)
            if ok and conn then
                S_Watchers[inst][prop] = conn
                table.insert(S_Conns, conn)
            end
        end
    end
end

-- Watch instance attributes (replicate independently)
local function S_WatchAttributes(inst)
    if not inst or not inst.Parent then return end
    local ok, conn = pcall(function()
        return inst.AttributeChanged:Connect(function(attrName)
            local attrOk, val = pcall(function() return inst:GetAttribute(attrName) end)
            S_Push({
                tier     = 1,
                kind     = "ATTRIBUTE",
                path     = S_GetPath(inst),
                instance = inst,
                property = attrName,
                newValue = attrOk and val or nil,
            })
        end)
    end)
    if ok and conn then table.insert(S_Conns, conn) end
end

-- ── Tier 2: Broad container watchers ─────────────────────────────────────────
local function S_WatchContainer(container)
    if not container then return end

    -- Watch existing descendants
    local ok, descendants = pcall(function() return container:GetDescendants() end)
    if ok then
        for _, desc in ipairs(descendants) do
            pcall(S_WatchProperties, desc)
            pcall(S_WatchAttributes, desc)
        end
    end

    -- Watch new children
    local ok2, conn2 = pcall(function()
        return container.DescendantAdded:Connect(function(desc)
            local addTime = os.clock()
            local path    = S_GetPath(desc)

            S_Push({
                tier     = 2,
                kind     = "DESCENDANT",
                path     = path,
                instance = desc,
                newValue = desc.ClassName,
            })

            -- Tier 3: debris tracking
            S_Debris[desc] = addTime
            task.delay(SENTRY_CFG.DebrisThreshold, function()
                if S_Debris[desc] then
                    -- Still exists after threshold — not debris
                    S_Debris[desc] = nil
                end
            end)

            -- Wire surgical watchers on the new instance
            pcall(S_WatchProperties, desc)
            pcall(S_WatchAttributes, desc)
        end)
    end)
    if ok2 and conn2 then table.insert(S_Conns, conn2) end

    -- Tier 3: catch debris (instances removed before DebrisThreshold)
    local ok3, conn3 = pcall(function()
        return container.DescendantRemoving:Connect(function(desc)
            local spawnTime = S_Debris[desc]
            if spawnTime then
                local lifetime = os.clock() - spawnTime
                S_Push({
                    tier     = 3,
                    kind     = "DEBRIS",
                    path     = S_GetPath(desc),
                    instance = desc,
                    newValue = lifetime,  -- lifetime in seconds
                    property = desc.ClassName,
                })
                S_Debris[desc] = nil
            end

            -- Clean up watchers for this instance
            if S_Watchers[desc] then
                for _, c in pairs(S_Watchers[desc]) do
                    pcall(function() c:Disconnect() end)
                end
                S_Watchers[desc] = nil
                S_Baseline[desc] = nil
            end
        end)
    end)
    if ok3 and conn3 then table.insert(S_Conns, conn3) end
end

-- ── Tier 4: Latency baseline tracker ─────────────────────────────────────────
-- Tracks round-trip timing for RemoteFunctions to establish baseline latency.
-- AVD Operator reports actual probe times; Sentry provides the baseline.
local S_LatencyLog    = {}  -- ring buffer of {t, latency}
local S_LatencyPtr    = 0
local S_LatencyBaseline = nil  -- rolling mean (ms)

function AVD_Sentry.RecordLatency(remoteType, latencyMs)
    S_LatencyPtr = (S_LatencyPtr % 64) + 1
    S_LatencyLog[S_LatencyPtr] = { t=os.clock(), ms=latencyMs, remote=remoteType }
    -- Update rolling mean (Welford)
    if not S_LatencyBaseline then
        S_LatencyBaseline = { mean=latencyMs, m2=0, n=1 }
    else
        local b = S_LatencyBaseline
        b.n = b.n + 1
        local delta = latencyMs - b.mean
        b.mean = b.mean + delta / b.n
        b.m2   = b.m2 + delta * (latencyMs - b.mean)
    end
    S_Push({
        tier     = 4,
        kind     = "LATENCY",
        path     = remoteType,
        newValue = latencyMs,
        oldValue = S_LatencyBaseline and S_LatencyBaseline.mean,
    })
end

function AVD_Sentry.GetLatencyBaseline()
    if not S_LatencyBaseline or S_LatencyBaseline.n < 5 then return nil end
    return S_LatencyBaseline.mean
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Get all events in the ring buffer, optionally filtered by time window
function AVD_Sentry.GetEvents(sinceTime, tier)
    local out = {}
    for i = 1, math.min(S_EventCount, SENTRY_CFG.EventCap) do
        local e = S_Events[i]
        if e then
            local timeOk = not sinceTime or e.t >= sinceTime
            local tierOk = not tier      or e.tier == tier
            if timeOk and tierOk then
                table.insert(out, e)
            end
        end
    end
    -- Sort by timestamp
    table.sort(out, function(a,b) return a.t < b.t end)
    return out
end

-- Get only baseline events (captured before any probe)
function AVD_Sentry.GetBaseline()
    return AVD_Sentry.GetEvents(nil, nil)  -- filtered by isBaseline in caller
end

-- Get events in a time window around a probe timestamp
-- Used by Translator to correlate probe → response
function AVD_Sentry.GetWindow(probeTime, windowSec)
    windowSec = windowSec or 2.0
    return AVD_Sentry.GetEvents(probeTime, nil)
end

-- Snapshot current state of a specific instance for baseline
function AVD_Sentry.SnapshotInstance(inst)
    if not inst then return nil end
    local snap = { path=S_GetPath(inst), className=inst.ClassName, t=os.clock() }
    local props = SENTRY_CFG.PropertyMap[inst.ClassName]
    if props then
        snap.properties = {}
        for _, p in ipairs(props) do
            local ok, v = pcall(function() return inst[p] end)
            if ok then snap.properties[p] = v end
        end
    end
    -- Capture all attributes
    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if ok then snap.attributes = attrs end
    return snap
end

-- Check if baseline collection period is done
function AVD_Sentry.IsBaselineDone()
    return S_BaselineDone
end

-- Get event count since a timestamp (quick signal strength check)
function AVD_Sentry.GetActivitySince(t)
    local count = 0
    for i = 1, math.min(S_EventCount, SENTRY_CFG.EventCap) do
        local e = S_Events[i]
        if e and e.t >= t and not e.isBaseline then
            count = count + 1
        end
    end
    return count
end

-- Force-watch a specific instance (called by Strategist when targeting)
function AVD_Sentry.Watch(inst)
    if not inst then return end
    pcall(S_WatchProperties, inst)
    pcall(S_WatchAttributes, inst)
end

-- Clear all events (called between probe sessions)
function AVD_Sentry.Flush()
    S_Events    = {}
    S_EventPtr  = 0
    S_EventCount = 0
end

function AVD_Sentry.GetCFG()
    return SENTRY_CFG
end

-- ── Startup ───────────────────────────────────────────────────────────────────
local function S_Start()
    if S_Running then return end
    S_Running = true

    -- Wire all configured root containers
    for _, rootName in ipairs(SENTRY_CFG.WatchRoots) do
        local ok, container = pcall(function()
            return game:GetService(rootName)
        end)
        if ok and container then
            pcall(S_WatchContainer, container)
        end
    end

    -- Watch each player's character as it spawns
    local function watchCharacter(char)
        if not char then return end
        pcall(S_WatchContainer, char)
    end
    local function watchPlayer(p)
        if p.Character then watchCharacter(p.Character) end
        p.CharacterAdded:Connect(watchCharacter)
    end
    for _, p in ipairs(Players:GetPlayers()) do watchPlayer(p) end
    Players.PlayerAdded:Connect(watchPlayer)

    -- Baseline window timer
    task.delay(SENTRY_CFG.BaselineWindow, function()
        S_BaselineDone = true
        print(string.format("[AVD Sentry] Baseline complete. %d events captured.", S_EventCount))
    end)

    print("[AVD Sentry] Running. Baseline window: " .. SENTRY_CFG.BaselineWindow .. "s")
end

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.AVD then _G.PC.AVD = {} end
_G.PC.AVD.Sentry = AVD_Sentry

S_Start()
