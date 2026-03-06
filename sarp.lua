local _C = _G.PC
local mk = _C.mk
local addCorner = _C.addCorner
local addStroke = _C.addStroke
local player = _C.player
local Players = _C.Players
local RunService = _C.RunService
local UserInputService = _C.UserInputService
local Workspace = _C.Workspace
local ReplicatedStorage = _C.ReplicatedStorage
local LWM = _C.LWM
local ETM = _C.ETM
local CDG = _C.CDG
local Intel = _C.Intel
local IntelMem = _C.IntelMem
local StateSignature = _C.StateSignature
local RAE_State = _C.RAE_State
local existing = _C.existing
local SARP = (function()
local SARP = {}

-- ── Persistence ───────────────────────────────────────────────
local SARP_PERSIST_VER      = "v1"
local SARP_PERSIST_SESSIONS = "SARP_Sessions_" .. SARP_PERSIST_VER
local SARP_PERSIST_RESHAPES = "SARP_Reshapes_" .. SARP_PERSIST_VER
local SARP_PERSIST_PATTERNS = "SARP_Patterns_" .. SARP_PERSIST_VER
local SARP_PERSIST_ECHO_WIN = "SARP_EchoWin_" .. tostring(game.PlaceId) -- per-PlaceId echo window

local SARPSessions   = {}   -- [sessionID] = full session record
local SARPReshapes   = {}   -- [channel:sig] = reshape history
local SARPPatterns   = {}   -- [patternHash] = {strategy, successRate, totalCount, successCount}
local SARPLog        = {}   -- flat ordered launch log (cap 200)
local SARPCarrier    = nil  -- active owned-carrier BasePart ref
local SARPWatchers   = {}   -- active GetAttributeChangedSignal connections
local SARP_SessionID = 0    -- monotonic session counter

-- ── v4 State ──────────────────────────────────────────────────
local SARP_SubTickPhase  = 0       -- measured Stepped→flush offset (seconds)
local SARP_PhaseReady    = false   -- true once sub-tick phase calibrated
local SARP_PhaseSamples  = {}      -- {s=steppedT, h=heartbeatT} calibration pairs
local SARP_ProbeResults  = {}      -- ring buffer of probe latencies per channel
local SARP_SurfaceIdx    = 0       -- surface rotation cursor

-- ── Configuration ─────────────────────────────────────────────
local SARP_CFG = {
    Mode                  = "MANUAL",  -- "MANUAL" | "AUTO"
    AutoThreshold         = 0.72,      -- ETM floor for AUTO mode
    PhoenixMaxDepth       = 5,         -- max reshape iterations per flight
    DesyncBaseDelay       = 0.18,      -- base window (seconds) before ownership hand-off
    DesyncGammaShape      = 2.0,       -- Gamma k for delay jitter
    DesyncGammaScale      = 0.08,      -- Gamma θ for delay jitter
    OwnershipTimeout      = 3.0,       -- seconds to hold carrier ownership
    CorrectionWatchWindow = 1.5,       -- seconds to listen for server correction signal
    BroadcastMode         = "SELF",    -- "SELF" | "NEARBY" | "ALL"
    EchoRadius            = 50,        -- studs for NEARBY mode
    AntiCheatGate         = true,      -- abort on elevated remoteFires delta
    ACFiresThreshold      = 20,        -- remoteFires/tick above which AC is flagged
    ReshapeNoiseScale     = 0.05,      -- Gamma noise per reshape iteration
    CarrierSize           = Vector3.new(0.5, 0.5, 0.5),
    -- ── v4 Upgrade Configuration ─────────────────────────────
    BurstCount             = 3,        -- writes per burst in echo window
    BurstIntervalScale     = 0.38,     -- fraction of echoWin between burst writes
    ProbeEnabled           = true,     -- mandatory pre-flight probe gate
    ProbeTimeoutSec        = 1.2,      -- max wait (seconds) for probe correction signal
    ParallelRacingEnabled  = false,    -- launch all channels simultaneously; cancel losers
    FragmentThreshold      = 48,       -- chars above which payload fragmentation activates
    SurfaceRotationEnabled = true,     -- rotate write surface across owned instance pool
    PlaceIdPersistEnabled  = true,     -- persist EchoWindowEst per PlaceId across sessions
    SubTickPhaseSamples    = 12,       -- Heartbeat frames to sample for sub-tick phase lock
}

-- ── Gamma sampler (Marsaglia–Tsang, matches Intel sampler style) ──
local function SARP_SampleGamma(k, theta)
    if k < 1 then return SARP_SampleGamma(1 + k, theta) * math.random()^(1/k) end
    local d = k - 1/3
    local c = 1 / math.sqrt(9 * d)
    while true do
        local x, v
        repeat x = (math.random() * 2 - 1) * 3; v = 1 + c * x until v > 0
        v = v^3
        local u = math.random()
        if u < 1 - 0.0331*(x^2)^2 then return d*v*theta end
        if math.log(u) < 0.5*x^2 + d*(1 - v + math.log(v)) then return d*v*theta end
    end
end

-- ── Simple djb2 hash for correction pattern keys ──────────────
local function SARP_HashStr(str)
    local h = 5381
    for i = 1, #str do h = bit32.band(h*33 + string.byte(str,i), 0xFFFFFFFF) end
    return string.format("P%08X", h)
end

-- ── v4 Utility: Sub-tick phase measurement ────────────────────
-- Samples the delta between RunService.Stepped (pre-physics) and
-- RunService.Heartbeat (post-physics) over SubTickPhaseSamples frames
-- to estimate where the replication flush sits within the tick cycle.
-- Writes placed just AFTER the flush boundary get maximum runway before
-- the server's next validation pass.
local function SARP_StartPhaseMeasurement()
    local conn
    conn = RunService.Stepped:Connect(function()
        local steppedT = os.clock()
        local hbConn
        hbConn = RunService.Heartbeat:Connect(function()
            hbConn:Disconnect()
            local heartbeatT = os.clock()
            table.insert(SARP_PhaseSamples, { s = steppedT, h = heartbeatT })
            if #SARP_PhaseSamples >= SARP_CFG.SubTickPhaseSamples then
                conn:Disconnect()
                local sum = 0
                for _, p in ipairs(SARP_PhaseSamples) do
                    sum = sum + (p.h - p.s)
                end
                SARP_SubTickPhase = sum / #SARP_PhaseSamples
                SARP_PhaseReady   = true
            end
        end)
        table.insert(SARPWatchers, hbConn)
    end)
    table.insert(SARPWatchers, conn)
end

-- ── v4 Utility: Phase-locked write helper ───────────────────────
-- Waits for Stepped, then delays by the measured flush-phase offset
-- so the write lands just AFTER the replication flush boundary.
-- Falls back to Heartbeat alignment during phase calibration.
local function SARP_PhaseWrite(writeFn, onDone)
    if not SARP_PhaseReady then
        -- Fallback: Heartbeat alignment while phase is being calibrated
        local conn
        conn = RunService.Heartbeat:Connect(function()
            conn:Disconnect()
            local ok, err = pcall(writeFn)
            if onDone then onDone(ok, err) end
        end)
        table.insert(SARPWatchers, conn)
        return
    end
    -- Stepped alignment + phase offset for optimal flush placement
    local conn
    conn = RunService.Stepped:Connect(function()
        conn:Disconnect()
        task.delay(SARP_SubTickPhase * 1.05, function()
            local ok, err = pcall(writeFn)
            if onDone then onDone(ok, err) end
        end)
    end)
    table.insert(SARPWatchers, conn)
end

-- ── v4 Utility: Live server load factor ────────────────────────
-- Weights recent LWM fields to produce a real-time load estimate.
-- High load → correction takes longer → wider usable echo window.
-- Returns a multiplier applied to EchoWindowEst before each flight.
local function SARP_GetLiveLoadFactor()
    local recentFires = LWM.GetTemporalAverage("remoteFires", 3) or 0
    local delta       = LWM.GetDelta()
    local recentPhys  = math.abs(delta and delta.physDelta or 0)
    local playerCount = #Players:GetPlayers()
    local fireFactor  = math.clamp(recentFires / math.max(SARP_CFG.ACFiresThreshold, 1), 0, 1)
    local physFactor  = math.clamp(recentPhys  / 15, 0, 1)
    local playerFactor= math.clamp((playerCount - 1) / 10, 0, 0.30)
    -- PR Bridge: when Protocol Reconstruction is loaded, more observed C2S
    -- remotes → server is handling more protocol traffic → widen load estimate.
    local prAdjust = 0
    local prInject = _G.PR_LWM_INJECT
    if type(prInject) == "table" then
        prAdjust = math.clamp((prInject.pr_c2s or 0) / 10, 0, 0.15)
    end
    return 0.75 + fireFactor * 0.35 + physFactor * 0.20 + playerFactor * 0.10 + prAdjust
end

-- ── v4 Utility: ETM context enrichment ─────────────────────────
-- Extends the state signature with live LWM bucketed fields so ETM
-- learns state-conditional (not just signature-conditional) distributions.
-- Buckets: remoteFires (lo/md/hi), physDelta (lo/md/hi), player count (sm/md/lg)
local function SARP_BuildETMContext(baseSig)
    local fires   = LWM.GetTemporalAverage("remoteFires", 2) or 0
    local delta   = LWM.GetDelta()
    local physD   = math.abs(delta and delta.physDelta or 0)
    local players = #Players:GetPlayers()
    local fBucket = fires  < 5   and "F:lo" or fires  < 15 and "F:md" or "F:hi"
    local pBucket = physD  < 2.0 and "P:lo" or physD  < 8  and "P:md" or "P:hi"
    local nBucket = players <= 4 and "N:sm" or players <= 10 and "N:md" or "N:lg"
    -- PR Bridge: append Protocol Reconstruction context tag when available.
    -- PR module writes _G.PR_ETM_CONTEXT with echo-calibrator + payload tags.
    -- This makes ETM predictions state-conditional on PROTOCOL KNOWLEDGE,
    -- not just timing buckets — the core gain of the PR layer.
    local prCtx = ""
    if type(_G.PR_ETM_CONTEXT) == "string" and #_G.PR_ETM_CONTEXT > 0 then
        prCtx = _G.PR_ETM_CONTEXT
    end
    return (baseSig or "unknown") .. "|" .. fBucket .. "|" .. pBucket .. "|" .. nBucket .. prCtx
end

-- ── v4 Utility: Write surface rotation pool ─────────────────────
-- Returns an ordered pool of client-writable instances, cycling through
-- them per session to avoid per-instance attribute write rate limits.
-- Priority: HRP → other character parts → backpack tools
local function SARP_GetWriteSurfaces()
    local pool = {}
    local char  = player.Character
    local hrp   = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then table.insert(pool, hrp) end
    if char then
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") and part ~= hrp then
                table.insert(pool, part)
                if #pool >= 4 then break end
            end
        end
    end
    local backpack = player:FindFirstChild("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then
                table.insert(pool, tool)
                if #pool >= 6 then break end
            end
        end
    end
    return pool
end

-- ── v4 Utility: Payload fragmentation ──────────────────────────
-- Splits payloads above FragmentThreshold across multiple attribute
-- keys. Each fragment travels the replication path independently —
-- partial propagation remains useful and the write pattern avoids
-- looking like a single large anomalous event.
-- Returns: list of {key, value, isFrag, index, total} tables
local function SARP_FragmentPayload(payloadStr, sessionID, chunkSize)
    chunkSize = chunkSize or 32
    if #payloadStr <= SARP_CFG.FragmentThreshold then
        return {{ key="sarp_p_"..tostring(sessionID), value=payloadStr,
                  isFrag=false, index=1, total=1 }}
    end
    local frags      = {}
    local totalChunks = math.ceil(#payloadStr / chunkSize)
    for i = 1, totalChunks do
        local s = (i-1)*chunkSize + 1
        table.insert(frags, {
            key   = string.format("sarp_f%d_%d_%d", i, sessionID, totalChunks),
            value = payloadStr:sub(s, s + chunkSize - 1),
            isFrag= true,
            index = i,
            total = totalChunks,
        })
    end
    return frags
end

-- ── v4 Utility: Correction fingerprinting ──────────────────────
-- Analyzes the corrected-to value to infer the server's validation
-- policy. This tells future reshapes which attribute types are safest
-- to use as payload envelopes (e.g. if server zeros numbers, use strings).
local function SARP_FingerprintCorrection(correctedTo)
    if correctedTo == nil           then return "POLICY:CLEAR"   end
    local s = tostring(correctedTo)
    if s == "0" or s == "0.0"      then return "POLICY:ZERO"    end
    if s == "false"                 then return "POLICY:FALSE"   end
    if s == ""                      then return "POLICY:EMPTY"   end
    if s ~= "nil" and #s > 0       then
        return "POLICY:REVERT:" .. s:sub(1, 20)
    end
    return "POLICY:UNKNOWN"
end

-- ── Save / Load ───────────────────────────────────────────────
local function SaveSARP()
    pcall(function()
        _G[SARP_PERSIST_SESSIONS] = SARPSessions
        _G[SARP_PERSIST_RESHAPES] = SARPReshapes
        _G[SARP_PERSIST_PATTERNS] = SARPPatterns
        -- Persist calibrated echo window per PlaceId so future sessions start warm
        if SARP_CFG.PlaceIdPersistEnabled and type(SARP_CFG.EchoWindowEst) == "number" then
            _G[SARP_PERSIST_ECHO_WIN] = SARP_CFG.EchoWindowEst
        end
    end)
end

local function LoadSARP()
    pcall(function()
        if type(_G[SARP_PERSIST_SESSIONS]) == "table" then SARPSessions = _G[SARP_PERSIST_SESSIONS] end
        if type(_G[SARP_PERSIST_RESHAPES]) == "table" then SARPReshapes = _G[SARP_PERSIST_RESHAPES] end
        if type(_G[SARP_PERSIST_PATTERNS]) == "table" then SARPPatterns = _G[SARP_PERSIST_PATTERNS] end
        -- Warm-start echo window from prior session calibration for this PlaceId
        if SARP_CFG.PlaceIdPersistEnabled and type(_G[SARP_PERSIST_ECHO_WIN]) == "number" then
            SARP_CFG.EchoWindowEst = _G[SARP_PERSIST_ECHO_WIN]
        end
        if type(_G.PR_ECHO_WINDOW_REFINED) == "number" and _G.PR_ECHO_WINDOW_REFINED > 0.01 then
            SARP_CFG.EchoWindowEst = _G.PR_ECHO_WINDOW_REFINED
        end
    end)
end

-- ============================================================
-- MODULE 1 — TARGET RESOLVER
-- ============================================================
SARP.TargetResolver = {}

function SARP.TargetResolver.GetAll()
    local list = {{ Name="Self", Player=player, IsSelf=true, Distance=0 }}
    local selfChar = player.Character
    local selfHRP  = selfChar and selfChar:FindFirstChild("HumanoidRootPart")
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player then
            local char = p.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            local dist = math.huge
            if hrp and selfHRP then
                dist = (hrp.Position - selfHRP.Position).Magnitude
            end
            table.insert(list, { Name=p.Name, Player=p, IsSelf=false, Distance=dist })
        end
    end
    table.sort(list, function(a,b) return a.Distance < b.Distance end)
    return list
end

-- Auto-select: highest ETM-predicted success + LWM desync score
function SARP.TargetResolver.AutoSelect()
    local buf   = LWM.GetBuffer()
    local delta = LWM.GetDelta()
    local physD = math.abs(delta and delta.physDelta or 0)
    -- Self is always baseline candidate
    local best = { Name="Self", Player=player, IsSelf=true,
        Score = 0.40 + math.min(physD / 15, 0.25) }
    local sig  = RAE_State.CurrentSig or "unknown"
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player then
            local key = "sarp_echo_" .. p.Name
            local prob, _, _ = ETM.Predict(key, sig)
            if prob > best.Score then
                best = { Name=p.Name, Player=p, IsSelf=false, Score=prob }
            end
        end
    end
    return best
end

-- Risk badge: ETM variance for a named target
function SARP.TargetResolver.RiskBadge(targetName)
    local key = (targetName == "Self") and "sarp_attr_self"
                or ("sarp_echo_" .. targetName)
    local _, _, stddev = ETM.Predict(key, RAE_State.CurrentSig or "unknown")
    local v = (stddev or 0.2)^2
    if v > 0.12 then return "HIGH",   Color3.fromRGB(220, 80,  80)
    elseif v > 0.06 then return "MED", Color3.fromRGB(220, 160, 60)
    else              return "LOW",    Color3.fromRGB(80,  180, 80) end
end

-- ============================================================
-- MODULE 2 — CRAFTER
-- Wraps a payload into one of three delivery envelopes
-- ============================================================
SARP.Crafter = {}

-- Strategy A: Attribute write — embeds payload in instance attributes
-- Uses junk outer key to mask the real payload key (dump-trigger camouflage)
function SARP.Crafter.WrapAttribute(payload, trashCamo, instanceOverride)
    local inst = instanceOverride
    if not inst then
        local char = player.Character
        inst = char and char:FindFirstChild("HumanoidRootPart")
    end
    if not inst or not inst.Parent then return nil, "No accessible target instance" end
    local junkKey    = "sarp_j_" .. tostring(math.random(1000,9999))
    local payloadKey = "sarp_p_" .. tostring(SARP_SessionID)
    -- Junk value: anomalous vector intended to trigger server validation dump
    local junkVal = trashCamo or Vector3.new(math.huge, math.huge, math.huge)
    return {
        Channel    = "Attribute",
        Instance   = inst,
        JunkKey    = junkKey,
        PayloadKey = payloadKey,
        JunkValue  = junkVal,
        Payload    = payload,
        Desc       = string.format("[Attribute] %s — junk '%s' + payload '%s'",
            inst:GetFullName(), junkKey, payloadKey),
    }, nil
end

-- Strategy B: Owned-carrier — creates a transient BasePart under client ownership,
-- embeds payload in its attributes during the ownership window, then releases
function SARP.Crafter.WrapOwnedCarrier(payload, desyncDelayOverride)
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil, "No HumanoidRootPart" end
    local delay = desyncDelayOverride
        or (SARP_CFG.DesyncBaseDelay + SARP_SampleGamma(SARP_CFG.DesyncGammaShape, SARP_CFG.DesyncGammaScale))
    return {
        Channel      = "OwnedCarrier",
        AnchorPart   = hrp,
        DesyncDelay  = delay,
        Payload      = payload,
        Desc         = string.format("[OwnedCarrier] HRP-anchored carrier — desync window %.3fs", delay),
    }, nil
end

-- Strategy C: Attachment bridge — creates a WeldConstraint/Attachment on an owned part,
-- encodes state in its CFrame/attributes for FE echo propagation to nearby clients
function SARP.Crafter.WrapAttachmentBridge(payload, echoPlayerName)
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil, "No HumanoidRootPart" end
    local echoPlayer = nil
    if echoPlayerName and echoPlayerName ~= "Self" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name == echoPlayerName then echoPlayer = p; break end
        end
    end
    return {
        Channel     = "AttachmentBridge",
        AnchorPart  = hrp,
        EchoPlayer  = echoPlayer,
        Payload     = payload,
        Desc        = string.format("[AttachmentBridge] HRP attachment — echo target: %s",
            echoPlayer and echoPlayer.Name or "local only"),
    }, nil
end

-- ============================================================
-- MODULE 3 — SIMULATOR
-- LWM-grounded dry-run: projects linger, success probability, AC risk
-- ============================================================
SARP.Simulator = {}

function SARP.Simulator.Simulate(wrapped, targetName)
    local buf    = LWM.GetBuffer()
    local delta  = LWM.GetDelta()
    local sig    = RAE_State.CurrentSig or "unknown"
    local ch     = wrapped.Channel
    local tgt    = targetName or "Self"

    -- ETM key for this channel+target combination
    local etmKey   = string.format("sarp_%s_%s", ch:lower(), tgt:lower())
    local etmProb, etmConv, etmStd = ETM.Predict(etmKey, sig)

    -- LWM linger estimate: physDelta is the best proxy for active desync activity
    local physD        = delta and math.abs(delta.physDelta) or 0
    local lingerBase   = math.max(0.4, 0.8 + physD * 0.10)
    local lingerTicks  = lingerBase + (etmProb - 0.5) * 0.9
    lingerTicks        = math.max(0.1, lingerTicks)

    -- CDG causal score for this channel card
    local cdgScore = CDG.GetCausalScore(etmKey)

    -- Variance → risk level
    local variance = (etmStd or 0.2)^2
    local risk     = variance > 0.12 and "High" or variance > 0.06 and "Medium" or "Low"

    -- AntiCheat spike detection from LWM
    local avgFires = LWM.GetTemporalAverage("remoteFires", 3)
    local acRisk   = (avgFires and avgFires > SARP_CFG.ACFiresThreshold)
        and "ELEVATED" or "NOMINAL"

    -- Phoenix reshape estimate: how many iterations before convergence?
    local reshapeEst = math.max(1, math.ceil((1 - etmProb) / 0.18))

    return {
        Channel      = ch,
        Target       = tgt,
        ETMProb      = etmProb,
        ETMConverged = etmConv,
        ETMStdDev    = etmStd,
        LingerTicks  = lingerTicks,
        CDGScore     = cdgScore,
        Risk         = risk,
        ACRisk       = acRisk,
        ReshapeEst   = reshapeEst,
        LWMDepth     = #buf,
        Sig          = sig,
        Summary      = string.format(
            "P(success): %.0f%% %s | Linger: ~%.1f ticks | Risk: %s | AC: %s | Reshape est: %d | CDG: %.3f",
            etmProb*100, etmConv and "✓" or "~", lingerTicks, risk, acRisk, reshapeEst, cdgScore),
    }
end

-- ============================================================
-- MODULE 4 — FLYER
-- Executes the three delivery channels with correction watching
-- ============================================================
SARP.Flyer = {}

-- ── Correction latency tracker — feeds echo window calibration ──
-- Stored as a ring buffer of observed (writeTime → correctionTime) deltas.
-- Used to calibrate SARP_CFG.EchoWindowEst and phase writes to tick boundaries.
local SARP_CorrLatency = {}  -- {delta, channel, t}
local SARP_CorrLatencyMax = 30

local function SARP_RecordCorrLatency(delta, channel)
    table.insert(SARP_CorrLatency, {delta=delta, channel=channel, t=os.clock()})
    if #SARP_CorrLatency > SARP_CorrLatencyMax then table.remove(SARP_CorrLatency, 1) end
    -- Recompute rolling estimate for this channel
    local sum, n = 0, 0
    for _, r in ipairs(SARP_CorrLatency) do
        if r.channel == channel then sum = sum + r.delta; n = n + 1 end
    end
    if n > 0 then SARP_CFG.EchoWindowEst = math.max(0.04, (sum/n) * 0.72) end
end

-- Returns the estimated echo window for a given channel (seconds).
-- Echo window = fraction of observed correction latency during which
-- replication has already propagated to other clients.
local function SARP_GetEchoWindow(channel)
    local sum, n = 0, 0
    for _, r in ipairs(SARP_CorrLatency) do
        if r.channel == channel then sum = sum + r.delta; n = n + 1 end
    end
    if n >= 2 then return math.max(0.03, (sum/n) * 0.68) end
    return SARP_CFG.EchoWindowEst or 0.06  -- cold-start fallback
end

-- ── Heartbeat-aligned write helper (preserved for compatibility) ──
-- Now delegates to SARP_PhaseWrite which uses Stepped + sub-tick phase
-- locking when calibration is complete, falling back to Heartbeat alignment.
local function SARP_HeartbeatWrite(writeFn, onDone)
    SARP_PhaseWrite(writeFn, onDone)
end

-- ── Baseline snapshot ───────────────────────────────────────────
local function SARP_Baseline()
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local ls   = player:FindFirstChild("leaderstats")
    local snap = { health=hum and hum.Health or 0, leaderstats={}, timestamp=os.clock() }
    if ls then for _, v in ipairs(ls:GetChildren()) do snap.leaderstats[v.Name]=v.Value end end
    return snap
end

-- ── Correction signal listener ──────────────────────────────────
-- Connects GetAttributeChangedSignal on the written key.
-- Records correction latency for echo window calibration.
-- onResult(corrected: bool, correctedToValue: any, latencySeconds: number)
local function SARP_WatchCorrection(instance, key, writtenValue, windowSec, channel, onResult)
    if not instance or not instance.Parent then onResult(true, nil, 0); return end
    local done      = false
    local writeTime = os.clock()
    local conn

    local timeoutConn = task.delay(windowSec, function()
        if done then return end
        done = true
        if conn then pcall(function() conn:Disconnect() end) end
        -- No correction arrived in window — attribute lingered
        onResult(false, nil, os.clock() - writeTime)
    end)

    pcall(function()
        conn = instance:GetAttributeChangedSignal(key):Connect(function()
            if done then return end
            local newVal = instance:GetAttribute(key)
            local serverOverwrote = (tostring(newVal) ~= tostring(writtenValue))
            if serverOverwrote then
                done = true
                local latency = os.clock() - writeTime
                pcall(function() conn:Disconnect() end)
                -- Feed latency into echo window calibrator
                SARP_RecordCorrLatency(latency, channel or "unknown")
                onResult(true, newVal, latency)
            end
        end)
        table.insert(SARPWatchers, conn)
    end)
end

-- ── Ownership handshake verifier ────────────────────────────────
-- Polls GetNetworkOwner() up to maxWait seconds to confirm the handshake
-- completed. Calls onConfirmed(true) when ownership is ours,
-- onConfirmed(false) on timeout.
local function SARP_WaitForOwnership(part, maxWait, onConfirmed)
    local deadline = os.clock() + maxWait
    local function poll()
        if not part or not part.Parent then onConfirmed(false); return end
        local ok, owner = pcall(function() return part:GetNetworkOwner() end)
        if ok and owner == player then
            onConfirmed(true)
        elseif os.clock() >= deadline then
            onConfirmed(false)  -- handshake timed out
        else
            task.wait(0.05)
            poll()
        end
    end
    task.spawn(poll)
end

-- ── Re-assertion loop ───────────────────────────────────────────
-- While the client holds ownership of `part`, re-writes `key` to `value`
-- on every Heartbeat. Fights server corrections by re-asserting faster
-- than the server can overwrite. Returns a stop function.
local function SARP_StartReassertLoop(part, key, value, maxDuration)
    local running   = true
    local deadline  = os.clock() + maxDuration
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not running or os.clock() > deadline then
            conn:Disconnect()
            return
        end
        if not part or not part.Parent then
            running = false; conn:Disconnect(); return
        end
        pcall(function() part:SetAttribute(key, value) end)
    end)
    table.insert(SARPWatchers, conn)
    return function()
        running = false
        pcall(function() conn:Disconnect() end)
    end
end

-- ── Carrier factory ─────────────────────────────────────────────
-- Creates a ghost (invisible, non-collide, unanchored) BasePart near the
-- player's HumanoidRootPart, suitable for network ownership operations.
-- Returns the part, or nil on failure.
local function SARP_MakeCarrier(sessionID)
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local p = Instance.new("Part")
    p.Name          = "sarp_c_" .. tostring(sessionID)
    p.Size          = SARP_CFG.CarrierSize
    p.Anchored      = false
    p.CanCollide    = false
    p.CanTouch      = false
    p.CanQuery      = false
    p.Transparency  = 1.0
    p.CastShadow    = false
    p.Massless      = true
    -- Position near HRP but offset so physics doesn't interact
    p.CFrame        = hrp.CFrame * CFrame.new(0, 4, 0)
    p.Parent        = Workspace
    return p
end

-- ── Pre-flight probe (mandatory gate) ─────────────────────────
-- Sends a sacrificial write to a throwaway attribute on the HRP and
-- measures live correction latency. This fresh measurement replaces
-- historical ring-buffer data as the primary echo window input for
-- the upcoming flight (weighted 75% fresh, 25% historical).
-- onResult(probeLatency: number|nil, fingerprint: string)
local function SARP_RunProbe(channel, onResult)
    if not SARP_CFG.ProbeEnabled then onResult(nil, "PROBE_DISABLED"); return end
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then onResult(nil, "NO_HRP"); return end

    local probeKey  = "sarp_probe_" .. tostring(SARP_SessionID)
                        .. "_" .. tostring(math.random(100, 999))
    local probeVal  = "probe_" .. tostring(math.floor(os.clock() * 1000))
    local writeTime = os.clock()
    local done      = false

    SARP_PhaseWrite(function()
        pcall(function() hrp:SetAttribute(probeKey, probeVal) end)
    end, function(ok)
        if not ok then onResult(nil, "PROBE_WRITE_FAILED"); return end

        local conn
        -- Timeout: if no correction arrives the server has a very wide window
        local timeoutHandle = task.delay(SARP_CFG.ProbeTimeoutSec, function()
            if done then return end
            done = true
            pcall(function() if conn then conn:Disconnect() end end)
            pcall(function() hrp:SetAttribute(probeKey, nil) end)
            -- Probe lingered — server is slow/busy. Use conservative estimate.
            onResult(nil, "PROBE_LINGERED")
        end)

        pcall(function()
            conn = hrp:GetAttributeChangedSignal(probeKey):Connect(function()
                if done then return end
                local newVal = hrp:GetAttribute(probeKey)
                if tostring(newVal) ~= probeVal then
                    done = true
                    pcall(function() conn:Disconnect() end)
                    task.cancel(timeoutHandle)
                    local latency     = os.clock() - writeTime
                    local fingerprint = SARP_FingerprintCorrection(newVal)
                    -- Feed fresh latency into ring buffer
                    SARP_RecordCorrLatency(latency, channel or "Probe")
                    -- Weight fresh measurement 75% vs historical 25%
                    local freshWin = math.max(0.03, latency * 0.70)
                    SARP_CFG.EchoWindowEst = (SARP_CFG.EchoWindowEst or 0.06) * 0.25
                                            + freshWin * 0.75
                    -- Record in probe ring buffer
                    table.insert(SARP_ProbeResults, {
                        latency=latency, channel=channel,
                        fingerprint=fingerprint, t=os.clock()
                    })
                    if #SARP_ProbeResults > 30 then
                        table.remove(SARP_ProbeResults, 1)
                    end
                    pcall(function() hrp:SetAttribute(probeKey, nil) end)
                    onResult(latency, fingerprint)
                end
            end)
            table.insert(SARPWatchers, conn)
        end)
    end)
end

-- ── Delivery Channel A: Attribute (v4) ────────────────────────
-- Layer 1 (Broadcast before correction) + Layer 3 (Adaptive reshape).
-- v4 upgrades: mandatory probe gate → live load-adjusted echo window →
-- surface rotation → payload fragmentation → multi-burst write pattern →
-- correction fingerprinting feeds reshape policy inference.
local function SARP_FlyAttribute(wrapped, onResult)
    local baseline   = SARP_Baseline()
    local payloadStr = type(wrapped.Payload)=="string" and wrapped.Payload or tostring(wrapped.Payload)

    -- ── Surface rotation ────────────────────────────────────
    -- Cycle across the owned-instance pool to avoid per-surface rate limits.
    local inst = wrapped.Instance
    if SARP_CFG.SurfaceRotationEnabled then
        local pool = SARP_GetWriteSurfaces()
        if #pool > 0 then
            SARP_SurfaceIdx = (SARP_SurfaceIdx % #pool) + 1
            local candidate = pool[SARP_SurfaceIdx]
            if candidate and candidate.Parent then inst = candidate end
        end
    end
    if not inst or not inst.Parent then onResult(false, "INSTANCE_GONE", nil); return end

    -- ── Mandatory probe gate ────────────────────────────────
    -- Probe fires first; its fresh latency replaces historical echo window data.
    SARP_RunProbe("Attribute", function(probeLatency, fingerprint)
        baseline.probeLatency = probeLatency
        baseline.fingerprint  = fingerprint

        -- Live load-adjusted echo window
        local loadFactor = SARP_GetLiveLoadFactor()
        local echoWin    = SARP_GetEchoWindow("Attribute") * loadFactor

        -- Fragment payload if above threshold
        local fragments  = SARP_FragmentPayload(payloadStr, SARP_SessionID)
        local junkKey    = wrapped.JunkKey
        local junkVal    = wrapped.JunkValue

        -- ── Phase-locked junk write ─────────────────────────
        -- Junk key travels the replication path first, loading the
        -- server's validation queue before the real fragments arrive.
        SARP_PhaseWrite(function()
            pcall(function() inst:SetAttribute(junkKey, junkVal) end)
        end, function()

            -- ── Multi-burst fragment write ──────────────────
            -- BurstCount writes of all fragments, spaced by BurstIntervalScale
            -- fractions of the echo window. Probability that at least one
            -- burst lands on a replication flush approaches 1 - (miss_rate^N).
            local burstCount    = SARP_CFG.BurstCount
            local burstInterval = echoWin * SARP_CFG.BurstIntervalScale
            local burstsDone    = 0

            local function doNextBurst(burstIdx)
                if burstIdx > burstCount then
                    -- All bursts fired — watch correction on the last fragment key
                    local lastFrag = fragments[#fragments]
                    SARP_WatchCorrection(inst, lastFrag.key, lastFrag.value,
                        SARP_CFG.CorrectionWatchWindow, "Attribute",
                        function(corrected, correctedTo, latency)
                            -- Clean up all keys
                            pcall(function() inst:SetAttribute(junkKey, nil) end)
                            for _, fr in ipairs(fragments) do
                                pcall(function() inst:SetAttribute(fr.key, nil) end)
                            end
                            -- Fingerprint server correction policy
                            local fp = (correctedTo ~= nil)
                                and SARP_FingerprintCorrection(correctedTo) or fingerprint
                            baseline.corrLatency  = latency
                            baseline.echoWinUsed  = echoWin
                            baseline.fingerprint  = fp
                            baseline.burstsFired  = burstCount
                            baseline.fragCount    = #fragments
                            local pattern = corrected
                                and ("CORRECTED_TO:" .. tostring(correctedTo))
                                or  "LINGERED"
                            onResult(not corrected, pattern, baseline)
                        end
                    )
                    return
                end

                -- Wait before this burst (first burst waits echoWin, rest wait burstInterval)
                local waitSec = (burstIdx == 1) and echoWin or burstInterval
                task.wait(waitSec)

                -- Write all fragments in this burst
                for _, frag in ipairs(fragments) do
                    pcall(function() inst:SetAttribute(frag.key, frag.value) end)
                end

                -- Gamma-sampled humanization jitter between bursts
                local jitter = SARP_SampleGamma(1.5, burstInterval * 0.18)
                task.delay(jitter, function() doNextBurst(burstIdx + 1) end)
            end

            doNextBurst(1)
        end)
    end)
end

-- ── Delivery Channel B: OwnedCarrier (v4) ─────────────────────
-- Layer 2 (Ownership anchor): creates a weld-stabilized ghost carrier,
-- verifies handshake, re-asserts payload every Heartbeat during ownership.
-- v4 upgrades: mandatory probe gate → live load factor → weld-anchored
-- carrier for ownership stability → fingerprint-enriched baseline.
local function SARP_FlyOwnedCarrier(wrapped, onResult)
    local baseline = SARP_Baseline()
    local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then onResult(false, "ANCHOR_GONE", nil); return end

    -- ── Mandatory probe gate ────────────────────────────────
    SARP_RunProbe("OwnedCarrier", function(probeLatency, fingerprint)
        baseline.probeLatency = probeLatency
        baseline.fingerprint  = fingerprint
        local loadFactor = SARP_GetLiveLoadFactor()

        -- Layer 2a: Carrier factory — ghost part
        local carrier = SARP_MakeCarrier(SARP_SessionID)
        if not carrier then onResult(false, "CARRIER_CREATE_FAILED", nil); return end
        SARPCarrier = carrier

        -- ── v4: Weld-anchored carrier ────────────────────────
        -- WeldConstraint keeps carrier co-located with HRP during the
        -- ownership window, preventing drift and server GC cleanup.
        -- Ownership is requested AFTER welding so the handshake sees
        -- a stable, physics-linked part.
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = carrier
        weld.Part1 = hrp
        weld.Parent = carrier

        -- Layer 2b: Request network ownership
        pcall(function()
            if carrier.SetNetworkOwner then
                carrier:SetNetworkOwner(player)
            end
        end)

        -- Layer 2c: Verify handshake
        SARP_WaitForOwnership(carrier, 1.2, function(confirmed)
            baseline.ownershipConfirmed = confirmed

            local payloadKey = "sarp_oc_" .. tostring(SARP_SessionID)
            local payloadStr = type(wrapped.Payload)=="string"
                and wrapped.Payload or tostring(wrapped.Payload)

            -- Layer 2d: Phase-locked write during ownership window
            SARP_PhaseWrite(function()
                carrier:SetAttribute(payloadKey, payloadStr)
                carrier:SetAttribute("sarp_oc_session", SARP_SessionID)
                -- Micro-CFrame nudge exercises the full replication path
                carrier.CFrame = hrp.CFrame * CFrame.new(
                    SARP_SampleGamma(1.2, 0.02) - 0.01,
                    4 + SARP_SampleGamma(1.2, 0.01),
                    SARP_SampleGamma(1.2, 0.02) - 0.01
                )
            end, function(writeOK)
                if not writeOK then
                    pcall(function() carrier:Destroy() end)
                    SARPCarrier = nil
                    onResult(false, "OC_WRITE_FAILED", baseline)
                    return
                end

                -- Layer 2e: Re-assertion loop (load-factor extended)
                -- Desync delay scaled by live load factor for wider window on busy servers
                local extendedDesync = wrapped.DesyncDelay * loadFactor
                local stopReassert   = SARP_StartReassertLoop(
                    carrier, payloadKey, payloadStr, extendedDesync)

                -- Layer 3: Correction watcher + ownership handoff
                SARP_WatchCorrection(carrier, payloadKey, payloadStr,
                    SARP_CFG.CorrectionWatchWindow, "OwnedCarrier",
                    function(corrected, correctedTo, latency)
                        stopReassert()
                        -- Fingerprint the server's correction policy
                        local fp = correctedTo ~= nil
                            and SARP_FingerprintCorrection(correctedTo) or fingerprint
                        -- Release ownership so server inherits final state as baseline
                        pcall(function()
                            if carrier and carrier.Parent and carrier.SetNetworkOwner then
                                carrier:SetNetworkOwner(nil)
                            end
                        end)
                        task.delay(0.4, function()
                            pcall(function()
                                if carrier and carrier.Parent then carrier:Destroy() end
                            end)
                            if SARPCarrier == carrier then SARPCarrier = nil end
                        end)
                        baseline.corrLatency        = latency
                        baseline.fingerprint        = fp
                        baseline.extendedDesync     = extendedDesync
                        local pattern = corrected
                            and ("OC_CORRECTED:" .. tostring(correctedTo))
                            or  "OC_LINGERED"
                        onResult(not corrected, pattern, baseline)
                    end
                )
            end)
        end)
    end)
end

-- ── Delivery Channel C: AttachmentBridge (v4) ─────────────────
-- Layer 1 + Layer 2 combined: HRP Attachment with client authority.
-- v4 upgrades: mandatory probe gate → live load-adjusted echo window →
-- multi-burst re-assertion pattern (BurstCount writes) → fingerprinting.
local function SARP_FlyAttachmentBridge(wrapped, onResult)
    local baseline = SARP_Baseline()
    local anchor   = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not anchor then onResult(false, "ANCHOR_GONE", nil); return end

    -- ── Mandatory probe gate ────────────────────────────────
    SARP_RunProbe("AttachmentBridge", function(probeLatency, fingerprint)
        baseline.probeLatency = probeLatency
        baseline.fingerprint  = fingerprint
        local loadFactor = SARP_GetLiveLoadFactor()

        local att  = Instance.new("Attachment")
        att.Name   = "sarp_ab_" .. tostring(SARP_SessionID)
        att.Parent = anchor

        local payloadStr    = type(wrapped.Payload)=="string"
            and wrapped.Payload or tostring(wrapped.Payload)
        local echoWin       = SARP_GetEchoWindow("AttachmentBridge") * loadFactor
        local burstInterval = echoWin * SARP_CFG.BurstIntervalScale

        -- ── Phase-locked initial write ──────────────────────
        -- CFrame + all attributes written in same Stepped-aligned tick
        SARP_PhaseWrite(function()
            local noiseX = SARP_SampleGamma(1.5, 0.004) - 0.002
            local noiseY = SARP_SampleGamma(1.5, 0.004) - 0.002
            att.CFrame = CFrame.new(noiseX, noiseY, 0)
            att:SetAttribute("sarp_ab_payload", payloadStr)
            att:SetAttribute("sarp_ab_session", SARP_SessionID)
            att:SetAttribute("sarp_ab_echo",
                wrapped.EchoPlayer and wrapped.EchoPlayer.Name or "local")
        end, function(writeOK)
            if not writeOK then
                pcall(function() att:Destroy() end)
                onResult(false, "AB_WRITE_FAILED", baseline)
                return
            end

            -- ── Multi-burst re-assertion ────────────────────
            -- BurstCount additional writes spaced by BurstIntervalScale × echoWin.
            -- Each burst re-asserts both the CFrame and attributes so both
            -- replication paths are exercised on every pass.
            local function doBurst(burstIdx)
                if burstIdx > SARP_CFG.BurstCount then
                    -- All bursts fired — watch for correction
                    SARP_WatchCorrection(att, "sarp_ab_payload", payloadStr,
                        SARP_CFG.CorrectionWatchWindow, "AttachmentBridge",
                        function(corrected, correctedTo, latency)
                            local fp = correctedTo ~= nil
                                and SARP_FingerprintCorrection(correctedTo) or fingerprint
                            task.delay(0.5, function()
                                pcall(function()
                                    if att and att.Parent then att:Destroy() end
                                end)
                            end)
                            baseline.corrLatency  = latency
                            baseline.echoWinUsed  = echoWin
                            baseline.fingerprint  = fp
                            baseline.burstsFired  = SARP_CFG.BurstCount
                            local pattern = corrected
                                and ("AB_CORRECTED:" .. tostring(correctedTo))
                                or  "AB_LINGERED"
                            onResult(not corrected, pattern, baseline)
                        end
                    )
                    return
                end

                local waitSec = (burstIdx == 1) and echoWin or burstInterval
                task.wait(waitSec)

                if att and att.Parent then
                    pcall(function()
                        local nx = SARP_SampleGamma(1.5, 0.003) - 0.0015
                        local ny = SARP_SampleGamma(1.5, 0.003) - 0.0015
                        att.CFrame = CFrame.new(nx, ny, 0)
                        att:SetAttribute("sarp_ab_payload", payloadStr)
                        att:SetAttribute("sarp_ab_session", SARP_SessionID)
                    end)
                end

                local jitter = SARP_SampleGamma(1.5, burstInterval * 0.15)
                task.delay(jitter, function() doBurst(burstIdx + 1) end)
            end

            doBurst(1)
        end)
    end)
end

function SARP.Flyer.Fly(wrapped, targetName, onResult)
    SARP_SessionID = SARP_SessionID + 1
    local ch = wrapped.Channel
    if     ch == "Attribute"        then SARP_FlyAttribute(wrapped, onResult)
    elseif ch == "OwnedCarrier"     then SARP_FlyOwnedCarrier(wrapped, onResult)
    elseif ch == "AttachmentBridge" then SARP_FlyAttachmentBridge(wrapped, onResult)
    else   onResult(false, "UNKNOWN_CHANNEL:" .. tostring(ch), nil) end
end

-- ── v4: Parallel channel racing ─────────────────────────────────
-- Launches all provided wrapped channels simultaneously when
-- ParallelRacingEnabled is true. The first channel to linger wins;
-- remaining channels are abandoned (their corrections don't matter).
-- This maximises success rate in AC-heavy environments where only one
-- clean window may be available across all channels.
-- Falls back to sequential Fly on first element when disabled.
function SARP.Flyer.FlyParallel(wrappedList, targetName, onResult)
    if not SARP_CFG.ParallelRacingEnabled or #wrappedList == 0 then
        -- Parallel disabled or no list: use standard sequential Fly
        SARP_SessionID = SARP_SessionID + 1
        local w = wrappedList[1]
        local ch = w and w.Channel or ""
        if     ch == "Attribute"        then SARP_FlyAttribute(w, onResult)
        elseif ch == "OwnedCarrier"     then SARP_FlyOwnedCarrier(w, onResult)
        elseif ch == "AttachmentBridge" then SARP_FlyAttachmentBridge(w, onResult)
        else   onResult(false, "PARALLEL_NO_VALID_CHANNEL", nil) end
        return
    end

    local resolved  = false
    local pending   = #wrappedList
    local allResults= {}

    for i, wrapped in ipairs(wrappedList) do
        SARP_SessionID = SARP_SessionID + 1
        local ch = wrapped.Channel

        local function handleResult(success, correctionStr, baseline)
            allResults[i] = { success=success, correctionStr=correctionStr,
                              baseline=baseline, channel=ch }
            if success and not resolved then
                resolved = true
                onResult(true, correctionStr, baseline)
                return
            end
            pending = pending - 1
            if pending <= 0 and not resolved then
                resolved = true
                -- All failed — return the most informative result
                local best = allResults[1]
                for _, r in ipairs(allResults) do
                    if r then best = r; break end
                end
                onResult(false,
                    best and best.correctionStr or "PARALLEL_ALL_FAILED",
                    best and best.baseline)
            end
        end

        -- Each channel runs in its own thread
        if     ch == "Attribute"        then task.spawn(SARP_FlyAttribute,        wrapped, handleResult)
        elseif ch == "OwnedCarrier"     then task.spawn(SARP_FlyOwnedCarrier,     wrapped, handleResult)
        elseif ch == "AttachmentBridge" then task.spawn(SARP_FlyAttachmentBridge, wrapped, handleResult)
        else   handleResult(false, "UNKNOWN_CHANNEL:" .. tostring(ch), nil) end
    end
end

-- ── Multi-client cascade ─────────────────────────────────────
-- After a confirmed linger on any channel, propagates the payload
-- to nearby players via AttachmentBridge writes on their characters.
-- CDG causal score determines sequencing: highest-score targets first,
-- since CDG edges encode which target ordering produced the best echo
-- propagation in prior sessions.
-- Each cascade step is separated by a Gamma-sampled humanization delay
-- to avoid uniform burst timing that could trigger AC detection.
SARP.Cascade = {}

local SARP_CascadeLog = {}  -- {sessionID, target, success, t}

local function SARP_CascadeToTarget(targetPlayer, payloadStr, sessionID, onDone)
    if not targetPlayer or not targetPlayer.Character then
        onDone(false, "NO_CHAR"); return
    end
    local hrp = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then onDone(false, "NO_HRP"); return end

    -- Create a transient Attachment on their HRP
    -- We can parent Attachments to instances we don't own via the client tree;
    -- whether it replicates depends on the game's network ownership config,
    -- but the write always exercises our local replication path outward.
    local att = Instance.new("Attachment")
    att.Name   = "sarp_cas_" .. tostring(sessionID) .. "_" .. targetPlayer.Name
    att.Parent = hrp

    local echoWin = SARP_GetEchoWindow("AttachmentBridge")

    SARP_HeartbeatWrite(function()
        local noiseX = SARP_SampleGamma(1.5, 0.003) - 0.0015
        att.CFrame = CFrame.new(noiseX, 0, 0)
        att:SetAttribute("sarp_cas_payload", payloadStr)
        att:SetAttribute("sarp_cas_session", sessionID)
        att:SetAttribute("sarp_cas_origin",  player.Name)
    end, function(ok)
        if not ok then
            pcall(function() att:Destroy() end)
            onDone(false, "WRITE_FAILED")
            return
        end
        -- Watch for correction on the cascade attachment
        SARP_WatchCorrection(att, "sarp_cas_payload", payloadStr,
            SARP_CFG.CorrectionWatchWindow, "Cascade",
            function(corrected, correctedTo, latency)
                task.delay(0.35, function()
                    pcall(function() if att and att.Parent then att:Destroy() end end)
                end)
                table.insert(SARP_CascadeLog, {
                    sessionID = sessionID,
                    target    = targetPlayer.Name,
                    success   = not corrected,
                    latency   = latency,
                    t         = os.clock(),
                })
                if #SARP_CascadeLog > 100 then table.remove(SARP_CascadeLog, 1) end
                onDone(not corrected, corrected and ("CORRECTED:"..tostring(correctedTo)) or "LINGERED")
            end
        )
    end)
end

function SARP.Cascade.Run(payloadStr, maxTargets, onComplete)
    maxTargets = math.min(maxTargets or 3, 5)  -- hard cap at 5
    local selfHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")

    -- Build candidate list: nearby players sorted by CDG causal score
    -- (higher score = this target has historically produced better echo propagation)
    local candidates = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            local dist = math.huge
            if hrp and selfHRP then
                dist = (hrp.Position - selfHRP.Position).Magnitude
            end
            if dist <= SARP_CFG.EchoRadius then
                local cdgKey   = "sarp_cas_" .. p.Name:lower()
                local cdgScore = CDG.GetCausalScore(cdgKey)
                -- ETM probability for cascade success on this target
                local etmP, _, _ = ETM.Predict(cdgKey, RAE_State.CurrentSig or "unknown")
                table.insert(candidates, {
                    Player   = p,
                    Distance = dist,
                    CDGScore = cdgScore,
                    ETMProb  = etmP,
                    -- Combined priority: CDG lift + ETM confidence + proximity bonus
                    Priority = cdgScore * 0.5 + etmP * 0.35 + math.max(0, 1 - dist/SARP_CFG.EchoRadius) * 0.15,
                })
            end
        end
    end

    -- Sort by priority descending
    table.sort(candidates, function(a, b) return a.Priority > b.Priority end)

    local selected = {}
    for i = 1, math.min(maxTargets, #candidates) do
        table.insert(selected, candidates[i])
    end

    if #selected == 0 then
        onComplete({}, "NO_TARGETS_IN_RANGE")
        return
    end

    -- Execute cascade sequentially with Gamma-sampled inter-step delays
    local results = {}
    local idx     = 0
    local sesID   = SARP_SessionID

    local function nextStep()
        idx = idx + 1
        if idx > #selected then
            onComplete(results, "CASCADE_COMPLETE")
            return
        end
        local entry = selected[idx]
        SARP_CascadeToTarget(entry.Player, payloadStr, sesID, function(success, pattern)
            table.insert(results, {
                Target  = entry.Player.Name,
                Success = success,
                Pattern = pattern,
                Priority= entry.Priority,
            })
            -- Feed ETM with cascade outcome
            local cdgKey = "sarp_cas_" .. entry.Player.Name:lower()
            ETM.Update(cdgKey, RAE_State.CurrentSig or "unknown", success)
            -- Humanization delay between cascade steps
            local delay = 0.18 + SARP_SampleGamma(SARP_CFG.DesyncGammaShape, 0.09)
            task.delay(delay, nextStep)
        end)
    end

    nextStep()
end


-- ============================================================
-- MODULE 5 — PHOENIX LOOP
-- Client-side adaptive retry: correction signal → reshape → retry
-- This is the reconstruction layer. It lives entirely on the client.
-- Each reshape iteration mutates the payload guided by the pattern
-- that the server correction revealed about validation boundaries.
-- ============================================================
SARP.Phoenix = {}

-- Classify what the server correction reveals
local function SARP_InferPattern(correctionStr)
    if not correctionStr or correctionStr == "LINGERED"
        or correctionStr == "OC_LINGERED" or correctionStr == "BRIDGE_LINGERED"
        then return "LINGERED" end
    local s = correctionStr:lower()
    if s:find("nan") or s:find("inf") or s:find("huge")    then return "BOUNDS_REJECT" end
    if s:find("corrected_to:nil") or s:find("attr_cleared") then return "ATTR_CLEARED"  end
    if s:find("corrected")                                  then return "SERVER_OVERRIDE" end
    if s:find("instance_gone") or s:find("anchor_gone")    then return "INSTANCE_LOST"  end
    if s:find("setattr_failed")                            then return "WRITE_BLOCKED"   end
    return "UNKNOWN_" .. SARP_HashStr(correctionStr)
end

-- Reshape the payload and delivery params based on what the correction pattern reveals
local function SARP_Reshape(payload, pattern, depth, channel)
    local noise  = SARP_SampleGamma(SARP_CFG.DesyncGammaShape, SARP_CFG.ReshapeNoiseScale * depth)
    local newDesync = SARP_CFG.DesyncBaseDelay + depth * 0.08
        + SARP_SampleGamma(SARP_CFG.DesyncGammaShape, SARP_CFG.DesyncGammaScale)
    local newPayload = payload
    local reshapeDesc = "passthrough"

    if pattern == "BOUNDS_REJECT" then
        -- Server rejected anomalous value (NaN/inf): reshape to bounded variant + noise
        if type(payload) == "number" then
            newPayload = math.clamp(payload + noise, -1e5, 1e5)
            reshapeDesc = string.format("bounds_clamp[%.4f] d%d", noise, depth)
        elseif type(payload) == "string" then
            newPayload = payload:sub(1, 64) .. "_r" .. depth
            reshapeDesc = "string_truncate+suffix"
        end
    elseif pattern == "SERVER_OVERRIDE" then
        -- Server actively overwrote: widen desync window and re-assert same value
        newDesync = newDesync + 0.15 * depth
        reshapeDesc = string.format("wider_desync[%.3fs] d%d", newDesync, depth)
    elseif pattern == "ATTR_CLEARED" then
        -- Server deleted attribute: rotate to a different key name
        if type(payload) == "string" then
            newPayload = payload .. "_k" .. depth
        end
        reshapeDesc = "key_rotation d" .. depth
    elseif pattern == "WRITE_BLOCKED" then
        -- Attribute write was blocked: escalate to OwnedCarrier if currently on Attribute
        reshapeDesc = "channel_escalate[OwnedCarrier] d" .. depth
    else
        -- Unknown pattern: inject Beta-sampled noise
        if type(payload) == "number" then
            newPayload = payload + noise
            reshapeDesc = string.format("noise_inject[%.4f] d%d", noise, depth)
        elseif type(payload) == "string" then
            newPayload = payload .. math.floor(noise * 1000)
            reshapeDesc = "string_noise d" .. depth
        end
    end
    return newPayload, newDesync, reshapeDesc
end

function SARP.Phoenix.Run(wrappedPayload, targetName, simResult, onComplete)
    local maxD       = SARP_CFG.PhoenixMaxDepth
    local depth      = 0
    local channel    = wrappedPayload.Channel
    local etmKey     = string.format("sarp_%s_%s", channel:lower(), (targetName or "self"):lower())
    local sessionRec = {
        ID         = SARP_SessionID,
        Channel    = channel,
        Target     = targetName or "Self",
        Attempts   = {},
        StartTime  = os.clock(),
        FinalResult= nil,
    }

    local function attempt(currentPayload, currentWrapped, currentDesync)
        if depth >= maxD then
            sessionRec.FinalResult = "MAX_DEPTH"
            onComplete(false, sessionRec, "Phoenix max depth reached (" .. maxD .. ")")
            SaveSARP()
            return
        end
        depth = depth + 1

        -- AntiCheat gate: elevated remoteFires delta = abort
        if SARP_CFG.AntiCheatGate then
            local recentFires = LWM.GetTemporalAverage("remoteFires", 2)
            if recentFires and recentFires > SARP_CFG.ACFiresThreshold then
                sessionRec.FinalResult = "AC_ABORT"
                onComplete(false, sessionRec, "AC spike detected — Phoenix aborted")
                return
            end
        end

        -- Humanized inter-attempt delay: Gamma jitter prevents timing fingerprinting
        if depth > 1 then
            task.wait(0.25 + SARP_SampleGamma(2.0, 0.12))
        end

        -- Apply current depth's desync delay to the wrapper
        local activeWrapped = {}
        for k, v in pairs(currentWrapped) do activeWrapped[k] = v end
        activeWrapped.Payload     = currentPayload
        activeWrapped.DesyncDelay = currentDesync

        SARP.Flyer.Fly(activeWrapped, targetName, function(success, correctionStr, baseline)
            local pattern = SARP_InferPattern(correctionStr)

            -- Record attempt
            local rec = {
                Depth         = depth,
                Success       = success,
                Pattern       = pattern,
                CorrectionStr = correctionStr,
                DesyncUsed    = currentDesync,
                Timestamp     = os.clock(),
            }
            table.insert(sessionRec.Attempts, rec)

            -- Feed ETM with this outcome (state-conditional learning)
            local sig = RAE_State.CurrentSig or "unknown"
            ETM.Update(etmKey, SARP_BuildETMContext(sig), success)

            -- Feed CDG: causal edge between depth N-1 and depth N attempts
            if depth > 1 then
                CDG.UpdateFromLog({
                    { ID=etmKey.."_d"..(depth-1), Success=(not success) },
                    { ID=etmKey.."_d"..depth,     Success=success        },
                })
            end

            -- Update pattern registry (learn which patterns map to which reshape success)
            local patHash = SARP_HashStr(pattern)
            if not SARPPatterns[patHash] then
                SARPPatterns[patHash] = {
                    Pattern=pattern, totalCount=0, successCount=0, reshapeDesc=""
                }
            end
            SARPPatterns[patHash].totalCount   = SARPPatterns[patHash].totalCount + 1
            if success then SARPPatterns[patHash].successCount = SARPPatterns[patHash].successCount + 1 end

            -- Log entry
            table.insert(SARPLog, {
                SessionID = sessionRec.ID,
                Depth     = depth,
                Channel   = channel,
                Target    = targetName,
                Success   = success,
                Pattern   = pattern,
                ETMKey    = etmKey,
                T         = os.clock(),
            })
            if #SARPLog > 200 then table.remove(SARPLog, 1) end

            if success then
                sessionRec.FinalResult = "SUCCESS"
                sessionRec.FinalDepth  = depth
                onComplete(true, sessionRec, correctionStr)
                SaveSARP()
                return
            end

            -- ETM collapse check: if ETM confidence falls too low, abandon
            local newProb, _, _ = ETM.Predict(etmKey, SARP_BuildETMContext(sig))
            if newProb < 0.18 and depth >= 3 then
                sessionRec.FinalResult = "ETM_COLLAPSE"
                onComplete(false, sessionRec, string.format(
                    "ETM confidence %.0f%% < floor after %d attempts — abort", newProb*100, depth))
                SaveSARP()
                return
            end

            -- Reshape for next attempt
            local newPayload, newDesync, reshapeDesc = SARP_Reshape(
                currentPayload, pattern, depth, channel)
            SARPPatterns[patHash].reshapeDesc = reshapeDesc

            -- Escalate channel if write was blocked on Attribute
            if pattern == "WRITE_BLOCKED" and channel == "Attribute" then
                local escalated, escalateErr = SARP.Crafter.WrapOwnedCarrier(newPayload, newDesync)
                if escalated then
                    activeWrapped = escalated
                end
            end

            attempt(newPayload, activeWrapped, newDesync)
        end)
    end

    attempt(wrappedPayload.Payload, wrappedPayload, SARP_CFG.DesyncBaseDelay)
end

-- ============================================================
-- SARP ORCHESTRATOR
-- ============================================================
function SARP.Build(channel, payload, trashCamo, deliveryParams, targetName)
    local wrapped, err
    if channel == "Attribute" then
        local inst = deliveryParams and deliveryParams.Instance or nil
        wrapped, err = SARP.Crafter.WrapAttribute(payload, trashCamo, inst)
    elseif channel == "OwnedCarrier" then
        local delay = deliveryParams and deliveryParams.DesyncDelay or nil
        wrapped, err = SARP.Crafter.WrapOwnedCarrier(payload, delay)
    elseif channel == "AttachmentBridge" then
        wrapped, err = SARP.Crafter.WrapAttachmentBridge(payload, targetName)
    else
        return nil, nil, "Unknown channel: " .. tostring(channel)
    end
    if err then return nil, nil, err end
    local simResult = SARP.Simulator.Simulate(wrapped, targetName)
    return wrapped, simResult, nil
end

function SARP.Execute(wrapped, simResult, targetName, onComplete)
    if SARP_CFG.Mode == "AUTO" then
        if not simResult or simResult.ETMProb < SARP_CFG.AutoThreshold then
            local pct = simResult and math.floor(simResult.ETMProb*100) or 0
            onComplete(false, nil, string.format(
                "AUTO mode: ETM %d%% < threshold %d%%", pct,
                math.floor(SARP_CFG.AutoThreshold*100)))
            return
        end
    end
    local _prBridge = _G.PC and _G.PC.PR_Bridge
    if _prBridge and _prBridge.GetSuggestedChannel then
        local prChan = _prBridge.GetSuggestedChannel()
        if prChan and prChan ~= wrapped.Channel then
            local rw, re
            if prChan == "Attribute" then rw,re = SARP.Crafter.WrapAttribute(wrapped.Payload,nil,nil)
            elseif prChan == "OwnedCarrier" then rw,re = SARP.Crafter.WrapOwnedCarrier(wrapped.Payload,nil)
            elseif prChan == "AttachmentBridge" then rw,re = SARP.Crafter.WrapAttachmentBridge(wrapped.Payload,targetName) end
            if rw and not re then wrapped = rw end
        end
    end
    SARP.Phoenix.Run(wrapped, targetName, simResult, onComplete)
end

function SARP.Cleanup()
    for _, c in ipairs(SARPWatchers) do pcall(function() c:Disconnect() end) end
    SARPWatchers = {}
    if SARPCarrier and SARPCarrier.Parent then
        pcall(function() SARPCarrier:Destroy() end)
        SARPCarrier = nil
    end
end

-- ============================================================
-- Export SARP
_G.PC.SARP = SARP
_G.PC.SARP_CFG = SARP_CFG
_G.PC.SARP_PERSIST_ECHO_WIN = SARP_PERSIST_ECHO_WIN
