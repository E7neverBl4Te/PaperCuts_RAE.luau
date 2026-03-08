-- ── Imports ───────────────────────────────────────────────────────────────────
local _C            = _G.PC
local RunService    = _C.RunService
local ETM           = _C.ETM
local CDG           = _C.CDG
local RAE_State     = _C.RAE_State
local StateSignature= _C.StateSignature

-- ============================================================
-- SR — State Reconstruction
-- Layer 4 of the PaperCuts intelligence stack.
--
-- Maintains a continuously-updated, per-domain belief model
-- of server-side game state by synthesising four pipelines:
--
--   PIPELINE 1 — Direct observation (Sentry tier1/2 events)
--     Real property/attribute changes seen on the local tree.
--     Source = "DIRECT". Highest confidence.
--
--   PIPELINE 2 — Probe inference (AVD Translator reports)
--     State changes that appeared within the probe correlation
--     window. Source = "INFERRED_PROBE". High confidence when
--     signal = CONFIRMED | STRONG.
--
--   PIPELINE 3 — RSM statistical inference
--     PathDeltas learned by RSM over many probe sessions.
--     Applied when a remote fires to form soft priors on what
--     server-side variables changed. Source = "INFERRED_RSM".
--
--   PIPELINE 4 — LWM aggregate metrics
--     Health, physics counts, remote fire rates from the LWM
--     ring buffer. Source = "LWM".
--
-- Feeds downstream:
--   SBI  — snapshot diffs expose causal remote→variable links
--   TSR  — PredictChange informs intent candidate ranking
--   SARP — predicted path deltas feed pre-flight risk model
-- ============================================================

local SR = {}

-- ── Domains ───────────────────────────────────────────────────
SR.DOMAIN = {
    ECONOMY   = "ECONOMY",
    INVENTORY = "INVENTORY",
    SESSION   = "SESSION",
    PHYSICS   = "PHYSICS",
    NETWORK   = "NETWORK",
    UNKNOWN   = "UNKNOWN",
}

-- ── Configuration ─────────────────────────────────────────────
local SR_CFG = {
    -- StateVar history ring size
    HistorySize         = 16,
    -- Confidence decay rate per second (applied on read)
    ConfidenceDecayRate = 0.015,   -- ~50% half-life ≈ 46 seconds
    -- Minimum signal class to ingest from Translator reports
    MinSignalScore      = 1,       -- WEAK=1 STRONG=2 CONFIRMED=3
    -- EMA alpha for INFERRED_RSM updates (lower = smoother)
    RSM_EMA_Alpha       = 0.25,
    -- Max StateVars to keep per domain before pruning oldest
    MaxVarsPerDomain    = 128,
    -- Snapshot ring for diff engine
    SnapshotRingSize    = 32,
    -- LWM poll interval (seconds)
    LWM_PollInterval    = 2.0,
    -- Auto-scan period for RSM-driven priors
    RSM_PriorInterval   = 15.0,
    -- Persist
    PersistEnabled      = true,
    PersistKey          = "SR_Model_" .. tostring(game.PlaceId),
    PersistVer          = "v1",
}

-- ── State model ───────────────────────────────────────────────
-- [domain][varName] = StateVar
local SR_Model = {
    ECONOMY   = {},
    INVENTORY = {},
    SESSION   = {},
    PHYSICS   = {},
    NETWORK   = {},
    UNKNOWN   = {},
}

-- Snapshot ring for diff engine
local SR_Snapshots    = {}
local SR_SnapshotPtr  = 0
local SR_SnapshotCount= 0

-- ── Path → domain + varName classifier ────────────────────────
-- Priority-ordered rules. First match wins.
local SR_PATH_RULES = {
    -- ECONOMY
    { pattern="leaderstats",                      domain="ECONOMY" },
    { pattern="currency",                          domain="ECONOMY" },
    { pattern="currencies",                        domain="ECONOMY" },
    { pattern="wallet",                            domain="ECONOMY" },
    { pattern="coins?%f[^a-z]",                   domain="ECONOMY" },
    { pattern="cash",                              domain="ECONOMY" },
    { pattern="gold",                              domain="ECONOMY" },
    { pattern="gems?%f[^a-z]",                    domain="ECONOMY" },
    { pattern="credits?%f[^a-z]",                 domain="ECONOMY" },
    { pattern="tokens?%f[^a-z]",                  domain="ECONOMY" },
    { pattern="points?%f[^a-z]",                  domain="ECONOMY" },
    { pattern="xp%f[^a-z]",                       domain="ECONOMY" },
    { pattern="exp%f[^a-z]",                       domain="ECONOMY" },
    { pattern="level%f[^a-z]",                    domain="ECONOMY" },
    { pattern="rank%f[^a-z]",                     domain="ECONOMY" },
    -- INVENTORY
    { pattern="inventor",                          domain="INVENTORY" },
    { pattern="backpack",                          domain="INVENTORY" },
    { pattern="equippe?d?",                        domain="INVENTORY" },
    { pattern="weapon",                            domain="INVENTORY" },
    { pattern="armor",                             domain="INVENTORY" },
    { pattern="item",                              domain="INVENTORY" },
    { pattern="tool%f[^a-z]",                      domain="INVENTORY" },
    { pattern="unlock",                            domain="INVENTORY" },
    { pattern="owned",                             domain="INVENTORY" },
    { pattern="purchas",                           domain="INVENTORY" },
    { pattern="gamepass",                          domain="INVENTORY" },
    -- SESSION
    { pattern="match",                             domain="SESSION" },
    { pattern="round",                             domain="SESSION" },
    { pattern="session",                           domain="SESSION" },
    { pattern="gamemode",                          domain="SESSION" },
    { pattern="phase%f[^a-z]",                    domain="SESSION" },
    { pattern="timer%f[^a-z]",                    domain="SESSION" },
    { pattern="score%f[^a-z]",                    domain="SESSION" },
    { pattern="team%f[^a-z]",                     domain="SESSION" },
    { pattern="lobby",                             domain="SESSION" },
    { pattern="alive",                             domain="SESSION" },
    { pattern="spawner",                           domain="SESSION" },
    -- PHYSICS
    { pattern="humanoid",                          domain="PHYSICS" },
    { pattern="health",                            domain="PHYSICS" },
    { pattern="walkspeed",                         domain="PHYSICS" },
    { pattern="jumppow",                           domain="PHYSICS" },
    { pattern="character",                         domain="PHYSICS" },
    { pattern="position",                          domain="PHYSICS" },
    { pattern="velocity",                          domain="PHYSICS" },
    { pattern="cframe",                            domain="PHYSICS" },
    { pattern="rootpart",                          domain="PHYSICS" },
    -- NETWORK
    { pattern="remote",                            domain="NETWORK" },
    { pattern="replicate",                         domain="NETWORK" },
    { pattern="stream",                            domain="NETWORK" },
    { pattern="network",                           domain="NETWORK" },
    { pattern="owner",                             domain="NETWORK" },
    { pattern="ping",                              domain="NETWORK" },
    { pattern="anticheat",                         domain="NETWORK" },
    { pattern="serverside",                        domain="NETWORK" },
}

-- Signal rank map (shared with RSM, duplicated for independence)
local SR_SIG_RANK = {
    CONFIRMED=3, STRONG=2, WEAK=1, LATENCY=1, ERROR=0, SILENT=0, UNKNOWN=0
}

-- ── Utility: classify a DataModel path ────────────────────────
local function SR_ClassifyPath(path)
    if not path then return SR.DOMAIN.UNKNOWN, "unknown" end
    local lower = path:lower()
    for _, rule in ipairs(SR_PATH_RULES) do
        if lower:find(rule.pattern) then
            -- Extract a variable name: last meaningful segment of the path
            local varName = path:match("([^./]+)$") or path
            return rule.domain, varName
        end
    end
    local varName = path:match("([^./]+)$") or path
    return SR.DOMAIN.UNKNOWN, varName
end

-- Enrich with RSM SemanticRole if path is in a remote's AffectedPaths
local function SR_EnrichDomain(domain, path)
    if domain ~= SR.DOMAIN.UNKNOWN then return domain end
    local RSM = _G.PC.RSM
    if not RSM then return domain end
    for _, rec in ipairs(RSM.GetAll()) do
        if rec.BehaviorSig.AffectedPaths[path] then
            local role = rec.SemanticRole or "UNKNOWN"
            if role == "ECONOMY"  then return SR.DOMAIN.ECONOMY  end
            if role == "COMBAT"   then return SR.DOMAIN.PHYSICS   end
            if role == "MOVEMENT" then return SR.DOMAIN.PHYSICS   end
        end
    end
    return domain
end

-- ── StateVar constructor ───────────────────────────────────────
local function SR_NewVar(domain, varName, pathBinding)
    return {
        domain        = domain,
        name          = varName,
        value         = nil,
        prevValue     = nil,
        confidence    = 0.0,
        lastUpdated   = os.clock(),
        source        = "NONE",
        method        = "LAST",
        delta         = nil,     -- last numeric change
        updateCount   = 0,
        history       = {},      -- ring buffer [{value,t,source,delta}]
        histPtr       = 0,
        -- Statistical tracking for numeric vars
        numMean       = 0,
        numM2         = 0,
        numN          = 0,
        numMin        = nil,
        numMax        = nil,
        -- Path/remote binding
        pathBinding   = pathBinding or nil,
        remoteBinding = nil,
        -- String frequency table
        strFreq       = {},
    }
end

-- ── StateVar registry access ───────────────────────────────────
local function SR_GetOrCreate(domain, varName, pathBinding)
    local domMap = SR_Model[domain]
    if not domMap then
        SR_Model[domain] = {}
        domMap = SR_Model[domain]
    end
    if not domMap[varName] then
        domMap[varName] = SR_NewVar(domain, varName, pathBinding)
    end
    return domMap[varName]
end

-- ── Confidence: apply decay on read ───────────────────────────
local function SR_DecayedConf(sv)
    local age = os.clock() - sv.lastUpdated
    return sv.confidence * math.exp(-SR_CFG.ConfidenceDecayRate * age)
end

-- ── History push ──────────────────────────────────────────────
local function SR_PushHistory(sv, value, source, delta)
    sv.histPtr = (sv.histPtr % SR_CFG.HistorySize) + 1
    sv.history[sv.histPtr] = { value=value, t=os.clock(), source=source, delta=delta }
end

-- ── Welford update for numeric vars ───────────────────────────
local function SR_WelfordUpdate(sv, v)
    sv.numN = sv.numN + 1
    local d1 = v - sv.numMean
    sv.numMean = sv.numMean + d1 / sv.numN
    local d2 = v - sv.numMean
    sv.numM2   = sv.numM2 + d1 * d2
    if sv.numMin == nil or v < sv.numMin then sv.numMin = v end
    if sv.numMax == nil or v > sv.numMax then sv.numMax = v end
end

-- ── Core update function ───────────────────────────────────────
-- Applies a new observation to a StateVar, updating value,
-- confidence, and statistics. Confidence is capped at the
-- source's maximum believability.
local SR_SOURCE_MAX_CONF = {
    DIRECT         = 0.95,
    INFERRED_PROBE = 0.80,
    INFERRED_RSM   = 0.55,
    PREDICTED      = 0.40,
    LWM            = 0.70,
    NONE           = 0.0,
}

local function SR_Apply(sv, newValue, confidence, source)
    -- Only update if confidence is meaningfully better or newer
    local curConf = SR_DecayedConf(sv)
    local cap     = SR_SOURCE_MAX_CONF[source] or 0.5
    local clampedConf = math.min(cap, confidence)

    local prevVal = sv.value
    local delta   = nil

    -- Value update logic by type
    if type(newValue) == "number" then
        sv.method = "WELFORD"
        SR_WelfordUpdate(sv, newValue)
        if sv.value ~= nil and type(sv.value) == "number" then
            delta = newValue - sv.value
        end
        -- EMA for INFERRED_RSM (smooth prior); last-value for DIRECT
        if source == "INFERRED_RSM" then
            sv.value = sv.value ~= nil and
                (sv.value * (1 - SR_CFG.RSM_EMA_Alpha) + newValue * SR_CFG.RSM_EMA_Alpha)
                or newValue
        else
            sv.value = newValue
        end
    elseif type(newValue) == "boolean" then
        sv.method = "LAST"
        sv.value  = newValue
    elseif type(newValue) == "string" then
        sv.method = "FREQUENCY"
        sv.strFreq[newValue] = (sv.strFreq[newValue] or 0) + 1
        -- Dominant string = most frequent
        local bestStr, bestCnt = nil, 0
        for s, cnt in pairs(sv.strFreq) do
            if cnt > bestCnt then bestStr=s; bestCnt=cnt end
        end
        sv.value = bestStr
    else
        sv.method = "LAST"
        sv.value  = newValue
    end

    -- Update tracking
    if sv.value ~= prevVal then sv.prevValue = prevVal end
    sv.delta       = delta
    sv.confidence  = math.max(curConf, clampedConf)
    sv.lastUpdated = os.clock()
    sv.source      = source
    sv.updateCount = sv.updateCount + 1
    SR_PushHistory(sv, sv.value, source, delta)
end

-- ═════════════════════════════════════════════════════════════
-- PIPELINE 1 — Direct observation (Sentry events)
-- Called in real-time via Sentry's push-to-translator hook.
-- Only tier1 (PROPERTY, ATTRIBUTE) and tier2 (CHILD_ADDED)
-- carry enough information to update StateVars directly.
-- ═════════════════════════════════════════════════════════════
local SR_Ingester = {}

function SR_Ingester.SentryEvent(event)
    if not event or not event.path then return end
    local kind = event.kind or ""
    if kind ~= "PROPERTY" and kind ~= "ATTRIBUTE" and kind ~= "CHILD_ADDED" then return end

    local domain, varName = SR_ClassifyPath(event.path)
    domain = SR_EnrichDomain(domain, event.path)

    local sv = SR_GetOrCreate(domain, varName, event.path)
    sv.remoteBinding = sv.remoteBinding  -- unchanged (set by Pipeline 3)

    local value = event.newValue
    if value == nil and kind == "CHILD_ADDED" then value = true end
    if value == nil then return end

    -- DIRECT observations get top confidence
    SR_Apply(sv, value, 0.90, "DIRECT")
end

-- ═════════════════════════════════════════════════════════════
-- PIPELINE 2 — Probe inference (Translator reports)
-- Called by RSM's OnTranslatorReport hook (which we extend).
-- ═════════════════════════════════════════════════════════════
function SR_Ingester.TranslatorReport(report)
    if not report then return end
    local sigRank = SR_SIG_RANK[report.signal] or 0
    if sigRank < SR_CFG.MinSignalScore then return end

    -- Confidence from signal class and report.confidence
    local baseConf = (sigRank / 3) * (report.confidence or 0.5)

    -- Ingest tier1 events (property changes correlated with this probe)
    for _, ev in ipairs(report.tier1Events or {}) do
        if ev.path and ev.newValue ~= nil then
            local domain, varName = SR_ClassifyPath(ev.path)
            domain = SR_EnrichDomain(domain, ev.path)
            local sv = SR_GetOrCreate(domain, varName, ev.path)
            sv.remoteBinding = report.remoteName
            SR_Apply(sv, ev.newValue, baseConf, "INFERRED_PROBE")
        end
    end

    -- Ingest affectedPaths with newValue from tier1 if we missed them
    for _, path in ipairs(report.affectedPaths or {}) do
        local domain, varName = SR_ClassifyPath(path)
        domain = SR_EnrichDomain(domain, path)
        local sv = SR_GetOrCreate(domain, varName, path)
        if sv.updateCount == 0 then
            -- Path was affected but no direct value — mark as alive with low conf
            SR_Apply(sv, true, baseConf * 0.4, "INFERRED_PROBE")
        end
        sv.remoteBinding = report.remoteName
    end

    -- Latency observation → NETWORK domain
    if report.latencyDelta and report.latencyDelta > 0 then
        local lv = SR_GetOrCreate(SR.DOMAIN.NETWORK, "ProbeLatencyDelta", nil)
        SR_Apply(lv, report.latencyDelta, 0.70, "INFERRED_PROBE")
    end
end

-- ═════════════════════════════════════════════════════════════
-- PIPELINE 3 — RSM statistical priors
-- Periodic: iterates all RSM signatures, applies PathDelta
-- distributions as soft priors on StateVars.
-- Called every RSM_PriorInterval seconds.
-- ═════════════════════════════════════════════════════════════
function SR_Ingester.RSMPriors()
    local RSM = _G.PC.RSM
    if not RSM then return end

    for _, rec in ipairs(RSM.GetAll()) do
        if rec.Confidence >= 0.25 then

        -- PathDeltas → StateVar soft priors
        for path, pd in pairs(rec.BehaviorSig.PathDeltas) do
            if pd.n >= 2 then
                local domain, varName = SR_ClassifyPath(path)
                domain = SR_EnrichDomain(domain, path)
                local sv = SR_GetOrCreate(domain, varName, path)
                -- Only apply if DIRECT/PROBE confidence has decayed significantly
                local curConf = SR_DecayedConf(sv)
                if curConf < 0.3 then
                    -- Estimate current value: last known + mean delta (if we have a prior)
                    local est = nil
                    if sv.value ~= nil and type(sv.value) == "number" then
                        est = sv.value + pd.mean
                    elseif pd.mean ~= 0 then
                        est = pd.mean
                    end
                    if est then
                        local rsm_conf = rec.Confidence * 0.5  -- capped by source max
                        SR_Apply(sv, est, rsm_conf, "INFERRED_RSM")
                    end
                end
                -- Always mark remote binding
                if sv.remoteBinding == nil then
                    sv.remoteBinding = rec.Name
                end
            end
        end

        -- AffectedPaths with no delta data — mark existence
        for path in pairs(rec.BehaviorSig.AffectedPaths) do
            if not rec.BehaviorSig.PathDeltas[path] then
                local domain, varName = SR_ClassifyPath(path)
                domain = SR_EnrichDomain(domain, path)
                local sv = SR_GetOrCreate(domain, varName, path)
                if sv.updateCount == 0 then
                    SR_Apply(sv, true, rec.Confidence * 0.3, "INFERRED_RSM")
                end
                if sv.remoteBinding == nil then sv.remoteBinding = rec.Name end
            end
        end

        end  -- confidence gate
    end
end

-- ═════════════════════════════════════════════════════════════
-- PIPELINE 4 — LWM aggregate metrics
-- Polls LWM_Buffer for the latest snapshot and maps its
-- well-typed metrics into the PHYSICS and NETWORK domains.
-- ═════════════════════════════════════════════════════════════
function SR_Ingester.LWMSnapshot()
    local lwmBuf = _G.PC.LWM_Buffer
    if not lwmBuf or #lwmBuf == 0 then return end

    local snap = lwmBuf[#lwmBuf]
    if not snap or not snap.metrics then return end
    local m = snap.metrics

    local function lwmApply(domain, name, value)
        if value == nil then return end
        local sv = SR_GetOrCreate(domain, name, nil)
        SR_Apply(sv, value, 0.70, "LWM")
    end

    lwmApply(SR.DOMAIN.PHYSICS,  "LocalHealth",       m.health)
    lwmApply(SR.DOMAIN.PHYSICS,  "PhysicsCount",      m.physCount)
    lwmApply(SR.DOMAIN.PHYSICS,  "ClientOwned",       m.clientOwned)
    lwmApply(SR.DOMAIN.NETWORK,  "TotalRemoteFires",  m.remoteFires)
    lwmApply(SR.DOMAIN.NETWORK,  "ScriptCount",       m.scriptCount)
    lwmApply(SR.DOMAIN.NETWORK,  "InstanceCount",     m.instanceCount)
    lwmApply(SR.DOMAIN.NETWORK,  "RemoteCount",       m.remoteCount)

    -- Pull from WorldState if available
    local ws = RAE_State and RAE_State.WorldState
    if ws then
        local lp = ws.Agents and ws.Agents.LocalPlayer
        if lp then
            lwmApply(SR.DOMAIN.PHYSICS, "Health",      lp.Health)
            lwmApply(SR.DOMAIN.SESSION, "Team",        lp.TeamColor)
            lwmApply(SR.DOMAIN.PHYSICS, "WalkSpeed",   lp.WalkSpeed)
            lwmApply(SR.DOMAIN.PHYSICS, "JumpPower",   lp.JumpPower)
        end
        -- leaderstats directly visible in WorldState.Latent.ValueObjects
        for _, vo in ipairs(ws.Latent and ws.Latent.ValueObjects or {}) do
            local path = vo.Path or ""
            local domain, varName = SR_ClassifyPath(path)
            domain = SR_EnrichDomain(domain, path)
            local sv = SR_GetOrCreate(domain, varName, path)
            SR_Apply(sv, vo.Value, 0.80, "LWM")
        end
        -- Replication lag
        lwmApply(SR.DOMAIN.NETWORK, "ReplicationLag", ws.Network and ws.Network.ReplicationLag)
    end
end

-- ═════════════════════════════════════════════════════════════
-- PREDICTION ENGINE
-- Given a remote name (and optional args), returns the
-- expected state changes as a map:
--   {path → {expectedValue, expectedDelta, uncertainty, confidence, domain, varName}}
-- ═════════════════════════════════════════════════════════════
local SR_Predictor = {}

function SR_Predictor.PredictChange(remoteName, args)
    local RSM = _G.PC.RSM
    if not RSM then return {} end

    local rec = RSM.Get(remoteName)
    if not rec then return {} end

    -- Base probability from ETM
    local etmConf = rec.CausalSig.ETMConfidence or 0.5
    -- Blend RSM confidence with ETM
    local weight  = rec.Confidence * etmConf

    local out = {}
    for path, pd in pairs(rec.BehaviorSig.PathDeltas) do
        if pd.n >= 2 then
            local domain, varName = SR_ClassifyPath(path)
            domain = SR_EnrichDomain(domain, path)

            -- Current known value for this var
            local curVal = nil
            local sv = SR_Model[domain] and SR_Model[domain][varName]
            if sv then curVal = sv.value end

            local expectedDelta = pd.mean
            local expectedValue = (type(curVal) == "number") and (curVal + expectedDelta) or nil
            local uncertainty   = pd.std

            out[path] = {
                expectedDelta = expectedDelta,
                expectedValue = expectedValue,
                uncertainty   = uncertainty,
                confidence    = math.min(0.90, weight * (pd.n / (pd.n + 5))),
                domain        = domain,
                varName       = varName,
            }
        end
    end

    -- If no PathDeltas, fall back to AffectedPaths with zero-delta
    if not next(out) then
        for path in pairs(rec.BehaviorSig.AffectedPaths) do
            local domain, varName = SR_ClassifyPath(path)
            domain = SR_EnrichDomain(domain, path)
            out[path] = {
                expectedDelta = 0,
                expectedValue = nil,
                uncertainty   = 1e9,  -- totally unknown
                confidence    = math.min(0.3, weight * 0.4),
                domain        = domain,
                varName       = varName,
            }
        end
    end

    return out
end

-- ═════════════════════════════════════════════════════════════
-- SNAPSHOT & DIFF ENGINE
-- Takes periodic StateModel snapshots and computes diffs.
-- Used by SBI to identify which remotes causally drive which
-- state variables.
-- ═════════════════════════════════════════════════════════════
local SR_SnapEngine = {}

-- Take a lightweight snapshot of the current model
function SR_SnapEngine.TakeSnapshot()
    local snap = { t = os.clock(), vars = {} }
    for domain, domMap in pairs(SR_Model) do
        snap.vars[domain] = {}
        for varName, sv in pairs(domMap) do
            snap.vars[domain][varName] = {
                value      = sv.value,
                confidence = SR_DecayedConf(sv),
                source     = sv.source,
                updateCount= sv.updateCount,
            }
        end
    end

    SR_SnapshotPtr   = (SR_SnapshotPtr % SR_CFG.SnapshotRingSize) + 1
    SR_Snapshots[SR_SnapshotPtr] = snap
    SR_SnapshotCount = math.min(SR_SnapshotCount + 1, SR_CFG.SnapshotRingSize)
    return snap
end

-- Get ordered snapshot history (newest last)
function SR_SnapEngine.GetHistory(n)
    n = n or SR_CFG.SnapshotRingSize
    local out = {}
    local count = math.min(n, SR_SnapshotCount)
    for i = count, 1, -1 do
        local idx = ((SR_SnapshotPtr - i) % SR_CFG.SnapshotRingSize) + 1
        local snap = SR_Snapshots[idx]
        if snap then table.insert(out, 1, snap) end
    end
    return out
end

-- Diff two snapshots: returns list of changed vars
-- {domain, varName, prevValue, newValue, delta, confidence}
function SR_SnapEngine.Diff(snapA, snapB)
    if not snapA or not snapB then return {} end
    local changes = {}
    for domain, domB in pairs(snapB.vars) do
        local domA = snapA.vars[domain] or {}
        for varName, svB in pairs(domB) do
            local svA = domA[varName]
            local prevVal = svA and svA.value or nil
            if svB.value ~= prevVal then
                local delta = nil
                if type(svB.value) == "number" and type(prevVal) == "number" then
                    delta = svB.value - prevVal
                end
                table.insert(changes, {
                    domain     = domain,
                    varName    = varName,
                    prevValue  = prevVal,
                    newValue   = svB.value,
                    delta      = delta,
                    confidence = svB.confidence,
                    source     = svB.source,
                })
            end
        end
    end
    table.sort(changes, function(a,b) return a.confidence > b.confidence end)
    return changes
end

-- Get diff between the last N snapshots
function SR_SnapEngine.RecentDiff(n)
    n = n or 2
    local hist = SR_SnapEngine.GetHistory(n)
    if #hist < 2 then return {} end
    return SR_SnapEngine.Diff(hist[1], hist[#hist])
end

-- ═════════════════════════════════════════════════════════════
-- PERSISTENCE
-- ═════════════════════════════════════════════════════════════
local function SR_Serialize()
    local out = {}
    for domain, domMap in pairs(SR_Model) do
        out[domain] = {}
        for varName, sv in pairs(domMap) do
            -- Only persist vars that have been observed and have meaningful confidence
            if sv.updateCount >= 1 and SR_DecayedConf(sv) > 0.05 then
                out[domain][varName] = {
                    value         = type(sv.value) == "table" and nil or sv.value,
                    prevValue     = type(sv.prevValue) == "table" and nil or sv.prevValue,
                    confidence    = SR_DecayedConf(sv),
                    source        = sv.source,
                    method        = sv.method,
                    updateCount   = sv.updateCount,
                    pathBinding   = sv.pathBinding,
                    remoteBinding = sv.remoteBinding,
                    numMean       = sv.numMean,
                    numN          = sv.numN,
                    numMin        = sv.numMin,
                    numMax        = sv.numMax,
                    persistVer    = SR_CFG.PersistVer,
                }
            end
        end
    end
    return out
end

local function SR_Deserialize(data)
    for domain, domData in pairs(data) do
        if not SR_Model[domain] then SR_Model[domain] = {} end
        for varName, saved in pairs(domData) do
            if saved.persistVer == SR_CFG.PersistVer then
                local sv = SR_NewVar(domain, varName, saved.pathBinding)
                sv.value         = saved.value
                sv.prevValue     = saved.prevValue
                sv.confidence    = saved.confidence or 0
                sv.lastUpdated   = os.clock()  -- mark fresh on load
                sv.source        = saved.source or "NONE"
                sv.method        = saved.method or "LAST"
                sv.updateCount   = saved.updateCount or 0
                sv.pathBinding   = saved.pathBinding
                sv.remoteBinding = saved.remoteBinding
                sv.numMean       = saved.numMean or 0
                sv.numN          = saved.numN or 0
                sv.numMin        = saved.numMin
                sv.numMax        = saved.numMax
                SR_Model[domain][varName] = sv
            end
        end
    end
end

function SR.Save()
    if not SR_CFG.PersistEnabled then return end
    pcall(function()
        _G[SR_CFG.PersistKey] = SR_Serialize()
    end)
end

function SR.Load()
    pcall(function()
        local saved = _G[SR_CFG.PersistKey]
        if type(saved) == "table" then
            SR_Deserialize(saved)
            local total = 0
            for d, dm in pairs(SR_Model) do for _ in pairs(dm) do total = total + 1 end end
            print(string.format("[SR] Loaded %d persisted StateVars.", total))
        end
    end)
end

-- ═════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════

-- Get single variable (confidence is decay-adjusted on read)
function SR.GetVar(domain, varName)
    local dm = SR_Model[domain]
    if not dm then return nil end
    local sv = dm[varName]
    if not sv then return nil end
    -- Return a view with live confidence
    return {
        domain        = sv.domain,
        name          = sv.name,
        value         = sv.value,
        prevValue     = sv.prevValue,
        confidence    = SR_DecayedConf(sv),
        source        = sv.source,
        method        = sv.method,
        delta         = sv.delta,
        updateCount   = sv.updateCount,
        pathBinding   = sv.pathBinding,
        remoteBinding = sv.remoteBinding,
        numMean       = sv.numMean,
        numN          = sv.numN,
        numMin        = sv.numMin,
        numMax        = sv.numMax,
        history       = sv.history,
    }
end

-- Get all vars in a domain sorted by confidence desc
function SR.GetDomain(domain)
    local dm = SR_Model[domain]
    if not dm then return {} end
    local out = {}
    for varName, sv in pairs(dm) do
        table.insert(out, {
            domain        = sv.domain,
            name          = varName,
            value         = sv.value,
            prevValue     = sv.prevValue,
            confidence    = SR_DecayedConf(sv),
            source        = sv.source,
            method        = sv.method,
            delta         = sv.delta,
            updateCount   = sv.updateCount,
            pathBinding   = sv.pathBinding,
            remoteBinding = sv.remoteBinding,
            numMean       = sv.numMean,
            numN          = sv.numN,
            numMin        = sv.numMin,
            numMax        = sv.numMax,
        })
    end
    table.sort(out, function(a,b) return a.confidence > b.confidence end)
    return out
end

-- Get all vars across all domains, sorted by confidence
function SR.GetAll(minConf)
    minConf = minConf or 0.0
    local out = {}
    for domain in pairs(SR_Model) do
        for _, sv in ipairs(SR.GetDomain(domain)) do
            if sv.confidence >= minConf then
                table.insert(out, sv)
            end
        end
    end
    table.sort(out, function(a,b) return a.confidence > b.confidence end)
    return out
end

-- Per-domain summary
function SR.GetDomainSummary()
    local out = {}
    for domain, dm in pairs(SR_Model) do
        local count, confSum, directCount = 0, 0, 0
        for _, sv in pairs(dm) do
            count = count + 1
            confSum = confSum + SR_DecayedConf(sv)
            if sv.source == "DIRECT" then directCount = directCount + 1 end
        end
        out[domain] = {
            domain      = domain,
            varCount    = count,
            avgConf     = count > 0 and (confSum / count) or 0,
            directCount = directCount,
        }
    end
    return out
end

-- Get total StateVar count
function SR.Count()
    local n = 0
    for _, dm in pairs(SR_Model) do for _ in pairs(dm) do n = n + 1 end end
    return n
end

-- Prediction: expected state changes from firing a remote
function SR.PredictChange(remoteName, args)
    return SR_Predictor.PredictChange(remoteName, args)
end

-- Snapshot and diff API (for SBI)
function SR.TakeSnapshot()
    return SR_SnapEngine.TakeSnapshot()
end
function SR.GetSnapshotHistory(n)
    return SR_SnapEngine.GetHistory(n)
end
function SR.Diff(snapA, snapB)
    return SR_SnapEngine.Diff(snapA, snapB)
end
function SR.RecentDiff(n)
    return SR_SnapEngine.RecentDiff(n)
end

-- On-demand scan: runs all 4 pipelines once
function SR.Scan()
    pcall(SR_Ingester.LWMSnapshot)
    pcall(SR_Ingester.RSMPriors)
    pcall(SR_SnapEngine.TakeSnapshot)
end

-- Live event hook (called by Sentry's push pipeline)
function SR.OnSentryEvent(event)
    pcall(SR_Ingester.SentryEvent, event)
end

-- Probe result hook (called alongside RSM's OnTranslatorReport)
function SR.OnTranslatorReport(report)
    pcall(SR_Ingester.TranslatorReport, report)
end

-- ═════════════════════════════════════════════════════════════
-- STARTUP
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    -- Wait for dependencies
    local function waitFor(getter, label, timeout)
        local t0 = os.clock()
        while not getter() do
            if os.clock()-t0 > timeout then warn("[SR] Timeout waiting for "..label); return false end
            task.wait(0.5)
        end
        return true
    end

    waitFor(function() return _G.PC.PR_Registry end,      "PR_Registry",   20)
    waitFor(function() return _G.PC.AVD and _G.PC.AVD.Translator end, "AVD.Translator", 20)
    waitFor(function() return _G.PC.RSM end,               "RSM",           25)

    -- Load persisted state
    SR.Load()

    -- Hook 1: Sentry event stream
    -- We install a secondary hook alongside Translator.Ingest
    -- (Sentry already calls translator.Ingest in its S_Push)
    local translator = _G.PC.AVD and _G.PC.AVD.Translator
    if translator and translator.Ingest then
        local origIngest = translator.Ingest
        translator.Ingest = function(event)
            pcall(origIngest, event)
            pcall(SR.OnSentryEvent, event)
        end
        print("[SR] Hooked into Sentry event stream via Translator.Ingest")
    end

    -- Hook 2: Translator report resolution (via Strategist.OnReport)
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
    if strategist and strategist.OnReport then
        local origOnReport = strategist.OnReport
        strategist.OnReport = function(report)
            pcall(origOnReport, report)
            pcall(SR.OnTranslatorReport, report)
        end
        print("[SR] Hooked into Strategist.OnReport")
    end

    -- Initial scan
    task.wait(1.0)
    SR.Scan()
    print(string.format("[SR] Initial scan complete — %d StateVars.", SR.Count()))

    -- LWM poll loop
    task.spawn(function()
        while true do
            task.wait(SR_CFG.LWM_PollInterval)
            pcall(SR_Ingester.LWMSnapshot)
        end
    end)

    -- RSM prior application loop
    task.spawn(function()
        while true do
            task.wait(SR_CFG.RSM_PriorInterval)
            pcall(SR_Ingester.RSMPriors)
            pcall(SR_SnapEngine.TakeSnapshot)
            pcall(SR.Save)
        end
    end)
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.SR = SR
_G.PC.SR_Ingester  = SR_Ingester
_G.PC.SR_SnapEngine = SR_SnapEngine
print("[SR] State Reconstruction ready.")
