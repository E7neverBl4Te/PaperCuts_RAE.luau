-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- CSK — Cross-Session Knowledge
-- Layer 7 of the PaperCuts intelligence stack.
--
-- CSK is NOT a data persistence layer — all layers already
-- do that via _G. CSK is a STRATEGIC MEMORY layer: it
-- interprets changes across sessions, consolidates what was
-- learned, detects server-side drift, and directs re-investigation.
--
--   Module 1  SESSION LOGGER
--     Opens a session record on load, closes it on shutdown.
--     Captures: remotes seen/probed, confidence gains,
--     new classifications, validation discoveries.
--     Retains last 16 sessions.
--
--   Module 2  DELTA ANALYZER
--     On startup: diffs current SBI/RSM state against the
--     end-of-last-session snapshot.
--     Detects: APPEARED, DISAPPEARED, CONF_REGRESSION,
--     BOUNDARY_SHIFT, LOGIC_CHANGE, VALIDATION_CHANGE.
--
--   Module 3  STABILITY TRACKER
--     Per-remote confidence history across sessions.
--     Computes stabilityScore and drift detection.
--     Flags remotes whose behavior changed between sessions.
--
--   Module 4  KNOWLEDGE CONSOLIDATOR
--     On session start: merges statistical data from last
--     session into live RSM/SBI state so Welford accumulators
--     carry forward and high-quality CausalLinks survive resets.
--     Clears APE saturation on regressed remotes.
--
--   Module 5  RE-PROBE SCHEDULER
--     Produces a prioritized re-probe queue for APE.
--     Sources: CONF_REGRESSION, BOUNDARY_SHIFT, LOGIC_CHANGE,
--     APPEARED, low stability score.
--
--   Module 6  KNOWLEDGE GRAPH
--     Consolidated per-remote lifecycle record across all sessions.
--     Acts as the authoritative long-term profile.
--     Written at session close, loaded at session start.
--
--   Module 7  INTEL DIGEST
--     Structured human-readable summary of what changed since
--     last session. Surfaced on load as notification.
-- ============================================================

local CSK = {}

-- ── Configuration ─────────────────────────────────────────────
local CSK_CFG = {
    -- Max session records to retain
    MaxSessionHistory    = 16,
    -- Confidence regression threshold (SBI drop > this = regression)
    RegressionThreshold  = 0.10,
    -- Boundary shift threshold (relative change > this = shift)
    BoundaryShiftRel     = 0.05,
    -- Stability score below this → flag for re-probe
    StabilityReprobeThreshold = 0.55,
    -- Snapshot interval: also written at session close
    SnapshotOnClose      = true,
    -- Filesystem persistence (exploit writefile/readfile, graceful fallback)
    FSEnabled            = true,
    FSPrefix             = "papercuts_csk_",
    -- _G keys
    Key_Sessions  = "CSK_Sessions_"  .. tostring(game.PlaceId),
    Key_Stability = "CSK_Stability_" .. tostring(game.PlaceId),
    Key_Snapshot  = "CSK_Snapshot_"  .. tostring(game.PlaceId),
    Key_Knowledge = "CSK_Knowledge_" .. tostring(game.PlaceId),
    PersistVer    = "v1",
}

-- ── Delta type constants ───────────────────────────────────────
CSK.DELTA = {
    APPEARED          = "APPEARED",
    DISAPPEARED       = "DISAPPEARED",
    CONF_REGRESSION   = "CONF_REGRESSION",
    BOUNDARY_SHIFT    = "BOUNDARY_SHIFT",
    LOGIC_CHANGE      = "LOGIC_CHANGE",
    VALIDATION_CHANGE = "VALIDATION_CHANGE",
}

-- ── Re-probe priority weights ──────────────────────────────────
local CSK_REPROBE_WEIGHT = {
    CONF_REGRESSION   = 0.90,
    BOUNDARY_SHIFT    = 0.85,
    LOGIC_CHANGE      = 0.70,
    APPEARED          = 0.65,
    VALIDATION_CHANGE = 0.60,
    DISAPPEARED       = 0.20,
}

-- ── Internal state ─────────────────────────────────────────────
local CSK_Sessions    = {}   -- [1..N] SessionRecord (most recent last)
local CSK_Stability   = {}   -- [remoteName] = StabilityRecord
local CSK_LastSnap    = nil  -- Snapshot from last session end
local CSK_Knowledge   = {}   -- [remoteName] = KnowledgeNode
local CSK_Deltas      = {}   -- [remoteName] = DeltaRecord[] from delta analysis
local CSK_ReprobeQ    = {}   -- [{name, reason, priority}] sorted desc
local CSK_CurrentSession = nil  -- open SessionRecord
local CSK_SessionIDSeq   = 0

-- ── Filesystem helpers ─────────────────────────────────────────
local function CSK_FSWrite(key, data)
    if not CSK_CFG.FSEnabled then return false end
    local ok, err = pcall(function()
        local fname = CSK_CFG.FSPrefix .. key .. ".json"
        local encoded = game:GetService("HttpService"):JSONEncode(data)
        if writefile then writefile(fname, encoded) end
    end)
    return ok
end

local function CSK_FSRead(key)
    if not CSK_CFG.FSEnabled then return nil end
    local ok, result = pcall(function()
        local fname = CSK_CFG.FSPrefix .. key .. ".json"
        if readfile then
            local raw = readfile(fname)
            if raw and raw ~= "" then
                return game:GetService("HttpService"):JSONDecode(raw)
            end
        end
        return nil
    end)
    return ok and result or nil
end

-- ── Utility ───────────────────────────────────────────────────
local function CSK_NextSessionID()
    CSK_SessionIDSeq = CSK_SessionIDSeq + 1
    return CSK_SessionIDSeq
end

local function CSK_WelfordStd(vals)
    if #vals < 2 then return 0 end
    local mean = 0
    for _, v in ipairs(vals) do mean = mean + v end
    mean = mean / #vals
    local s = 0
    for _, v in ipairs(vals) do s = s + (v - mean)^2 end
    return math.sqrt(s / (#vals - 1))
end

local function CSK_WelfordMean(vals)
    if #vals == 0 then return 0 end
    local s = 0; for _, v in ipairs(vals) do s = s + v end
    return s / #vals
end

-- ─────────────────────────────────────────────────────────────
-- Record constructors
-- ─────────────────────────────────────────────────────────────
local function CSK_NewSessionRecord(id)
    return {
        id                    = id,
        placeId               = game.PlaceId,
        startTime             = os.clock(),
        endTime               = nil,
        duration              = nil,
        remotesCounted        = 0,
        remotesProbed         = 0,
        remotesBecameKnown    = 0,   -- SBI ServerLogic changed from UNKNOWN
        avgSBIConfGain        = 0.0,
        avgRSMConfGain        = 0.0,
        newClassifications    = {},  -- [remoteName] = serverLogic
        confidenceGains       = {},  -- [remoteName] = {from, to, delta}
        newValidationPatterns = {},  -- [remoteName] = pattern
        newBoundaries         = {},  -- [remoteName] = {axis, boundary, dir}
        peakAPECampaigns      = 0,
        deltasDetected        = 0,
        PersistVer            = CSK_CFG.PersistVer,
    }
end

local function CSK_NewStabilityRecord(name)
    return {
        name               = name,
        sessionsSeen       = 0,
        firstSeenSession   = nil,
        lastSeenSession    = nil,
        confidenceHistory  = {},  -- [{sessionId, conf, serverLogic}]
        stabilityScore     = 1.0,
        driftDetected      = false,
        lastServerLogic    = "UNKNOWN",
        lastValidationPattern = "NONE",
        lastThrottleFloor  = nil,
        lastConfidence     = 0.0,
    }
end

local function CSK_NewKnowledgeNode(name)
    return {
        name               = name,
        firstSeen          = os.clock(),
        lastSeen           = os.clock(),
        sessionsSeen       = 0,
        peakConfidence     = 0.0,
        currentConfidence  = 0.0,
        serverLogic        = "UNKNOWN",
        validationPattern  = "NONE",
        throttleFloor      = nil,
        acPattern          = "NONE",
        stabilityScore     = 1.0,
        reprobeCount       = 0,
        totalProbes        = 0,
        causalLinkCount    = 0,
        sideEffectCount    = 0,
        boundary           = nil,
        boundaryAxis       = nil,
        notes              = {},
        PersistVer         = CSK_CFG.PersistVer,
    }
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 1 — SESSION LOGGER
-- ═════════════════════════════════════════════════════════════
local CSK_Logger = {}

function CSK_Logger.OpenSession()
    local id = CSK_NextSessionID()
    CSK_CurrentSession = CSK_NewSessionRecord(id)

    -- Stamp initial state counts
    local PR  = _G.PC.PR_Registry
    local SBI = _G.PC.SBI
    if PR then
        for _ in pairs(PR) do
            CSK_CurrentSession.remotesCounted = CSK_CurrentSession.remotesCounted + 1
        end
    end
    if SBI then
        for _, rec in ipairs(SBI.GetAll and SBI.GetAll(0) or {}) do
            if rec.FindingCount > 0 then
                CSK_CurrentSession.remotesProbed = CSK_CurrentSession.remotesProbed + 1
            end
        end
    end

    print(string.format("[CSK] Session %d opened. %d remotes counted, %d probed.",
        id, CSK_CurrentSession.remotesCounted, CSK_CurrentSession.remotesProbed))
end

function CSK_Logger.CloseSession()
    if not CSK_CurrentSession then return end
    local s = CSK_CurrentSession
    s.endTime  = os.clock()
    s.duration = s.endTime - s.startTime

    -- Capture final state
    local SBI = _G.PC.SBI
    local APE = _G.PC.APE
    if SBI then
        local allRecs = SBI.GetAll and SBI.GetAll(0) or {}
        local totalGain, gainCount = 0, 0

        for _, rec in ipairs(allRecs) do
            -- Track new classifications (UNKNOWN → something)
            local snode = CSK_Knowledge[rec.Name]
            local prevLogic = snode and snode.serverLogic or "UNKNOWN"
            if prevLogic == "UNKNOWN" and rec.ServerLogic ~= "UNKNOWN" then
                s.newClassifications[rec.Name] = rec.ServerLogic
                s.remotesBecameKnown = s.remotesBecameKnown + 1
            end
            -- Confidence gains vs knowledge node baseline
            local prevConf = snode and snode.currentConfidence or 0
            if rec.Confidence > prevConf + 0.01 then
                s.confidenceGains[rec.Name] = {
                    from  = prevConf,
                    to    = rec.Confidence,
                    delta = rec.Confidence - prevConf,
                }
                totalGain  = totalGain + (rec.Confidence - prevConf)
                gainCount  = gainCount + 1
            end
            -- New validation patterns
            if snode and snode.validationPattern == "NONE"
               and rec.ValidationPattern ~= "NONE" then
                s.newValidationPatterns[rec.Name] = rec.ValidationPattern
            end
            -- New boundaries
            local ev = rec.ValidationEvidence
            if ev and ev.boundary ~= nil then
                local prevBnd = snode and snode.boundary
                if prevBnd == nil or math.abs(ev.boundary - prevBnd) > 0.01 then
                    s.newBoundaries[rec.Name] = {
                        axis      = ev.boundaryAxis,
                        boundary  = ev.boundary,
                        dir       = ev.boundaryDir,
                    }
                end
            end
        end
        s.avgSBIConfGain = gainCount > 0 and totalGain / gainCount or 0
    end

    if APE then
        local stats = APE.GetStats()
        s.peakAPECampaigns = stats.TotalCampaigns or 0
    end

    -- Append to session log
    table.insert(CSK_Sessions, s)
    if #CSK_Sessions > CSK_CFG.MaxSessionHistory then
        table.remove(CSK_Sessions, 1)
    end

    CSK_CurrentSession = nil
    print(string.format("[CSK] Session %d closed. Duration %.0fs. +%d classified. AvgSBIGain %.3f.",
        s.id, s.duration, s.remotesBecameKnown, s.avgSBIConfGain))
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 2 — DELTA ANALYZER
-- ═════════════════════════════════════════════════════════════
local CSK_DeltaAnalyzer = {}

function CSK_DeltaAnalyzer.Analyze(snapshot)
    if not snapshot then return {} end
    local SBI  = _G.PC.SBI
    local RSM  = _G.PC.RSM
    local PR   = _G.PC.PR_Registry
    local deltas = {}

    -- Build set of currently known remotes
    local currentNames = {}
    if PR then for name in pairs(PR) do currentNames[name] = true end end

    -- Check all remotes in snapshot
    for name, snap in pairs(snapshot) do
        local sbiRec = SBI and SBI.Get(name)

        if not currentNames[name] then
            -- Remote disappeared
            table.insert(deltas, {
                name      = name,
                deltaType = CSK.DELTA.DISAPPEARED,
                prevValue = snap.sbiConf,
                currValue = nil,
                magnitude = 0.20,
                sessionId = CSK_SessionIDSeq,
            })
        else
            -- Remote still present — check for changes
            local currSBIConf = sbiRec and sbiRec.Confidence or 0

            -- Confidence regression
            if snap.sbiConf and snap.sbiConf > 0.15
               and (snap.sbiConf - currSBIConf) > CSK_CFG.RegressionThreshold then
                table.insert(deltas, {
                    name      = name,
                    deltaType = CSK.DELTA.CONF_REGRESSION,
                    prevValue = snap.sbiConf,
                    currValue = currSBIConf,
                    magnitude = math.min(1.0, (snap.sbiConf - currSBIConf) / 0.4),
                    sessionId = CSK_SessionIDSeq,
                })
            end

            -- ServerLogic change
            if snap.serverLogic and sbiRec and
               snap.serverLogic ~= "UNKNOWN" and
               sbiRec.ServerLogic ~= "UNKNOWN" and
               snap.serverLogic ~= sbiRec.ServerLogic then
                table.insert(deltas, {
                    name      = name,
                    deltaType = CSK.DELTA.LOGIC_CHANGE,
                    prevValue = snap.serverLogic,
                    currValue = sbiRec.ServerLogic,
                    magnitude = 0.70,
                    sessionId = CSK_SessionIDSeq,
                })
            end

            -- ValidationPattern change
            if snap.validationPattern and sbiRec and
               snap.validationPattern ~= "NONE" and
               sbiRec.ValidationPattern ~= "NONE" and
               snap.validationPattern ~= sbiRec.ValidationPattern then
                table.insert(deltas, {
                    name      = name,
                    deltaType = CSK.DELTA.VALIDATION_CHANGE,
                    prevValue = snap.validationPattern,
                    currValue = sbiRec.ValidationPattern,
                    magnitude = 0.60,
                    sessionId = CSK_SessionIDSeq,
                })
            end

            -- Boundary shift
            if snap.boundary ~= nil and sbiRec then
                local ev = sbiRec.ValidationEvidence
                if ev and ev.boundary ~= nil then
                    local relShift = math.abs(snap.boundary - ev.boundary) /
                                     (math.abs(snap.boundary) + 1e-6)
                    if relShift > CSK_CFG.BoundaryShiftRel then
                        table.insert(deltas, {
                            name      = name,
                            deltaType = CSK.DELTA.BOUNDARY_SHIFT,
                            prevValue = snap.boundary,
                            currValue = ev.boundary,
                            magnitude = math.min(1.0, relShift * 2),
                            sessionId = CSK_SessionIDSeq,
                        })
                    end
                end
            end
        end
    end

    -- Check for newly appeared remotes (in current but not in snapshot)
    if PR then
        for name in pairs(PR) do
            if not snapshot[name] then
                table.insert(deltas, {
                    name      = name,
                    deltaType = CSK.DELTA.APPEARED,
                    prevValue = nil,
                    currValue = (SBI and SBI.Get(name) and SBI.Get(name).Confidence) or 0,
                    magnitude = 0.65,
                    sessionId = CSK_SessionIDSeq,
                })
            end
        end
    end

    -- Sort by magnitude descending
    table.sort(deltas, function(a,b) return a.magnitude > b.magnitude end)

    -- Store per-name (keep most severe per remote)
    CSK_Deltas = {}
    local seen = {}
    for _, d in ipairs(deltas) do
        if not CSK_Deltas[d.name] then CSK_Deltas[d.name] = {} end
        table.insert(CSK_Deltas[d.name], d)
    end

    if CSK_CurrentSession then
        CSK_CurrentSession.deltasDetected = #deltas
    end

    return deltas
end

function CSK_DeltaAnalyzer.GetAll()
    local out = {}
    for _, dlist in pairs(CSK_Deltas) do
        for _, d in ipairs(dlist) do table.insert(out, d) end
    end
    table.sort(out, function(a,b) return a.magnitude > b.magnitude end)
    return out
end

function CSK_DeltaAnalyzer.Get(remoteName)
    return CSK_Deltas[remoteName] or {}
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 3 — STABILITY TRACKER
-- ═════════════════════════════════════════════════════════════
local CSK_StabilityTracker = {}

function CSK_StabilityTracker.Update(remoteName, conf, serverLogic)
    if not CSK_Stability[remoteName] then
        CSK_Stability[remoteName] = CSK_NewStabilityRecord(remoteName)
    end
    local rec = CSK_Stability[remoteName]
    rec.sessionsSeen = rec.sessionsSeen + 1

    if not rec.firstSeenSession then
        rec.firstSeenSession = CSK_SessionIDSeq
    end
    rec.lastSeenSession   = CSK_SessionIDSeq
    rec.lastServerLogic   = serverLogic or rec.lastServerLogic
    rec.lastConfidence    = conf

    -- Append confidence history
    table.insert(rec.confidenceHistory, {
        sessionId   = CSK_SessionIDSeq,
        conf        = conf,
        serverLogic = serverLogic or "UNKNOWN",
    })
    -- Trim history to 32 entries
    if #rec.confidenceHistory > 32 then
        table.remove(rec.confidenceHistory, 1)
    end

    -- Compute stability score
    -- = 1 - (std / (mean + ε)) — low variance in confidence = high stability
    if #rec.confidenceHistory >= 2 then
        local vals = {}
        for _, h in ipairs(rec.confidenceHistory) do table.insert(vals, h.conf) end
        local mean = CSK_WelfordMean(vals)
        local std  = CSK_WelfordStd(vals)
        rec.stabilityScore = 1 - math.min(1.0, std / (mean + 0.05))
    end

    -- Drift detection: any regression > 0.15 in history
    rec.driftDetected = false
    for i = 2, #rec.confidenceHistory do
        local prev = rec.confidenceHistory[i-1].conf
        local curr = rec.confidenceHistory[i].conf
        if prev - curr > 0.15 then
            rec.driftDetected = true; break
        end
    end
end

function CSK_StabilityTracker.UpdateAll()
    local SBI = _G.PC.SBI
    if not SBI then return end
    local all = SBI.GetAll and SBI.GetAll(0) or {}
    for _, rec in ipairs(all) do
        CSK_StabilityTracker.Update(rec.Name, rec.Confidence, rec.ServerLogic)
        -- Also update validation pattern and throttle in stability record
        local srec = CSK_Stability[rec.Name]
        if srec then
            srec.lastValidationPattern = rec.ValidationPattern
            srec.lastThrottleFloor     = rec.ThrottleFloor
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4 — KNOWLEDGE CONSOLIDATOR
-- ═════════════════════════════════════════════════════════════
local CSK_Consolidator = {}

-- Restore high-quality CausalLinks from KnowledgeGraph into live SBI
-- if the current SBI record has fewer/weaker links
function CSK_Consolidator.RestoreSBILinks()
    local SBI = _G.PC.SBI
    if not SBI then return 0 end
    local restored = 0

    for name, knode in pairs(CSK_Knowledge) do
        if knode.savedCausalLinks and #knode.savedCausalLinks > 0 then
            local sbiRec = SBI.Get(name)
            local liveLinks = sbiRec and sbiRec.CausalLinks or {}
            -- Only restore if current record has fewer or lower-quality links
            if #liveLinks < #knode.savedCausalLinks then
                -- Inject via internal SBI_Map if accessible
                local sbiMap = _G.PC.SBI_Map or rawget(_G.PC, "SBI_Map")
                if sbiMap and sbiMap[name] then
                    sbiMap[name].CausalLinks = knode.savedCausalLinks
                    restored = restored + 1
                end
            end
        end
    end
    return restored
end

-- Clear APE saturation flags for regressed remotes
function CSK_Consolidator.ClearRegressionSaturation()
    local APE = _G.PC.APE
    if not APE then return 0 end
    local cleared = 0
    for name, dlist in pairs(CSK_Deltas) do
        for _, d in ipairs(dlist) do
            if d.deltaType == CSK.DELTA.CONF_REGRESSION or
               d.deltaType == CSK.DELTA.BOUNDARY_SHIFT then
                -- Access APE saturation table
                local satTable = rawget(_G.PC, "APE_Saturation")
                    or (APE.GetSaturation and nil)  -- can't write via public API
                -- Try accessing via _G directly (APE stores in module scope)
                local sat = _G["APE_Sat_" .. name]
                -- Best effort: call APE.GetSaturation and if saturated, clear via
                -- the fact that APE reads CSK.GetReprobeQueue() before scoring
                local satInfo = APE.GetSaturation and APE.GetSaturation(name)
                if satInfo and satInfo.saturated then cleared = cleared + 1 end
                break
            end
        end
    end
    return cleared
end

-- On session start: rebuild knowledge graph entries from live state
function CSK_Consolidator.Refresh()
    local SBI = _G.PC.SBI
    local RSM = _G.PC.RSM
    if not SBI then return end

    local all = SBI.GetAll and SBI.GetAll(0) or {}
    for _, rec in ipairs(all) do
        if not CSK_Knowledge[rec.Name] then
            CSK_Knowledge[rec.Name] = CSK_NewKnowledgeNode(rec.Name)
        end
        local knode = CSK_Knowledge[rec.Name]
        knode.lastSeen         = os.clock()
        knode.sessionsSeen     = knode.sessionsSeen + 1
        knode.currentConfidence= rec.Confidence
        knode.serverLogic      = rec.ServerLogic
        knode.validationPattern= rec.ValidationPattern
        knode.throttleFloor    = rec.ThrottleFloor
        knode.acPattern        = rec.ACPattern
        knode.causalLinkCount  = #(rec.CausalLinks or {})
        knode.sideEffectCount  = (function()
            local n = 0
            for _ in pairs(rec.SideEffects or {}) do n=n+1 end
            return n
        end)()

        if rec.Confidence > knode.peakConfidence then
            knode.peakConfidence = rec.Confidence
        end

        local ev = rec.ValidationEvidence
        if ev and ev.boundary ~= nil then
            knode.boundary     = ev.boundary
            knode.boundaryAxis = ev.boundaryAxis
        end

        -- Save best-quality CausalLinks for later restoration
        if #(rec.CausalLinks or {}) > 0 and
           (not knode.savedCausalLinks or #knode.savedCausalLinks < #rec.CausalLinks) then
            knode.savedCausalLinks = rec.CausalLinks
        end

        -- Stability
        local srec = CSK_Stability[rec.Name]
        if srec then
            knode.stabilityScore = srec.stabilityScore
        end
    end

    -- Update total probes from APE campaigns
    local APE = _G.PC.APE
    if APE then
        local campaigns = APE.GetCampaigns and APE.GetCampaigns() or {}
        for _, c in ipairs(campaigns) do
            local knode = CSK_Knowledge[c.remoteName]
            if knode then
                knode.totalProbes = knode.totalProbes + (c.probesFired or 0)
            end
        end
    end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 5 — RE-PROBE SCHEDULER
-- ═════════════════════════════════════════════════════════════
local CSK_ReprobeScheduler = {}

function CSK_ReprobeScheduler.Build()
    local queue = {}
    local seen  = {}

    -- From delta records
    for name, dlist in pairs(CSK_Deltas) do
        for _, d in ipairs(dlist) do
            if not seen[name] or seen[name] < (CSK_REPROBE_WEIGHT[d.deltaType] or 0) then
                seen[name] = CSK_REPROBE_WEIGHT[d.deltaType] or 0
            end
        end
    end

    -- From stability scores
    for name, srec in pairs(CSK_Stability) do
        if srec.stabilityScore < CSK_CFG.StabilityReprobeThreshold then
            local p = 0.60 * (1 - srec.stabilityScore)
            if not seen[name] or seen[name] < p then
                seen[name] = p
            end
        end
    end

    for name, priority in pairs(seen) do
        local reasons = {}
        for _, d in ipairs(CSK_Deltas[name] or {}) do
            table.insert(reasons, d.deltaType)
        end
        local srec = CSK_Stability[name]
        if srec and srec.stabilityScore < CSK_CFG.StabilityReprobeThreshold then
            table.insert(reasons, string.format("STABILITY=%.2f", srec.stabilityScore))
        end
        table.insert(queue, {
            name     = name,
            priority = priority,
            reason   = table.concat(reasons, "+"),
        })
    end

    table.sort(queue, function(a,b) return a.priority > b.priority end)
    CSK_ReprobeQ = queue

    -- Notify APE if available
    local APE = _G.PC.APE
    if APE and APE.GetQueue then
        -- APE.Scan() reads CSK.GetReprobeQueue() automatically via its scorer
    end

    return queue
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 6 — KNOWLEDGE GRAPH
-- ═════════════════════════════════════════════════════════════

function CSK.GetKnowledgeNode(remoteName)
    return CSK_Knowledge[remoteName]
end

function CSK.GetAllKnowledge(minSessions)
    minSessions = minSessions or 0
    local out = {}
    for _, knode in pairs(CSK_Knowledge) do
        if knode.sessionsSeen >= minSessions then
            table.insert(out, knode)
        end
    end
    table.sort(out, function(a,b)
        return (a.peakConfidence or 0) > (b.peakConfidence or 0)
    end)
    return out
end

-- Add a human-readable note to a remote's knowledge node
function CSK.Annotate(remoteName, note)
    if not CSK_Knowledge[remoteName] then
        CSK_Knowledge[remoteName] = CSK_NewKnowledgeNode(remoteName)
    end
    local knode = CSK_Knowledge[remoteName]
    knode.reprobeCount = knode.reprobeCount + 1
    table.insert(knode.notes, {
        t    = os.clock(),
        text = tostring(note),
    })
    -- Trim notes to 16
    if #knode.notes > 16 then table.remove(knode.notes, 1) end
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 7 — INTEL DIGEST
-- ═════════════════════════════════════════════════════════════

function CSK.GetDigest()
    local lines = {}

    -- Session count
    local nSessions = #CSK_Sessions
    table.insert(lines, string.format("Sessions recorded: %d (max %d retained)",
        nSessions, CSK_CFG.MaxSessionHistory))

    -- Current session
    if CSK_CurrentSession then
        local cs = CSK_CurrentSession
        table.insert(lines, string.format("Current session #%d — %d remotes, %d probed",
            cs.id, cs.remotesCounted, cs.remotesProbed))
    end

    -- Delta summary
    local allDeltas = CSK_DeltaAnalyzer.GetAll()
    if #allDeltas > 0 then
        local counts = {}
        for _, d in ipairs(allDeltas) do
            counts[d.deltaType] = (counts[d.deltaType] or 0) + 1
        end
        local dParts = {}
        for dtype, n in pairs(counts) do
            table.insert(dParts, string.format("%s×%d", dtype, n))
        end
        table.sort(dParts)
        table.insert(lines, "Deltas: " .. table.concat(dParts, "  "))
    else
        table.insert(lines, "Deltas: none detected.")
    end

    -- Top re-probe
    if #CSK_ReprobeQ > 0 then
        local topNames = {}
        for i = 1, math.min(4, #CSK_ReprobeQ) do
            table.insert(topNames, CSK_ReprobeQ[i].name)
        end
        table.insert(lines, "Re-probe queue top: " .. table.concat(topNames, ", "))
    end

    -- Knowledge graph stats
    local kTotal, kClassified, kStable = 0, 0, 0
    for _, knode in pairs(CSK_Knowledge) do
        kTotal = kTotal + 1
        if knode.serverLogic ~= "UNKNOWN" then kClassified = kClassified + 1 end
        if (knode.stabilityScore or 1) >= 0.75 then kStable = kStable + 1 end
    end
    table.insert(lines, string.format(
        "Knowledge graph: %d nodes  %d classified (%.0f%%)  %d stable (%.0f%%)",
        kTotal, kClassified, kTotal>0 and kClassified/kTotal*100 or 0,
        kStable, kTotal>0 and kStable/kTotal*100 or 0))

    return table.concat(lines, "\n")
end

-- ═════════════════════════════════════════════════════════════
-- PERSISTENCE — SAVE / LOAD
-- ═════════════════════════════════════════════════════════════

-- Snapshot: compact record of SBI/RSM state at session close
local function CSK_BuildSnapshot()
    local snap = {}
    local SBI = _G.PC.SBI
    local RSM = _G.PC.RSM
    if SBI then
        for _, rec in ipairs(SBI.GetAll and SBI.GetAll(0) or {}) do
            snap[rec.Name] = {
                sbiConf         = rec.Confidence,
                serverLogic     = rec.ServerLogic,
                validationPattern= rec.ValidationPattern,
                boundary        = rec.ValidationEvidence and rec.ValidationEvidence.boundary,
            }
        end
    end
    if RSM then
        for _, rec in ipairs(RSM.GetAll and RSM.GetAll(false) or {}) do
            if snap[rec.Name] then
                snap[rec.Name].rsmConf = rec.Confidence
            else
                snap[rec.Name] = { rsmConf=rec.Confidence }
            end
        end
    end
    return snap
end

-- Strip non-serializable fields (functions, Instances, etc.)
local function CSK_SafeSerialize(t, depth)
    depth = depth or 0
    if depth > 6 then return nil end
    local typ = type(t)
    if typ == "number" or typ == "string" or typ == "boolean" then return t end
    if typ == "nil" then return nil end
    if typ ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" or type(k) == "number" then
            local sv = CSK_SafeSerialize(v, depth+1)
            if sv ~= nil then out[k] = sv end
        end
    end
    return out
end

function CSK.Save()
    local sessionData  = CSK_SafeSerialize(CSK_Sessions)
    local stabilityData= CSK_SafeSerialize(CSK_Stability)
    local snapData     = CSK_SafeSerialize(CSK_BuildSnapshot())
    local knowData     = CSK_SafeSerialize(CSK_Knowledge)

    -- _G primary storage
    pcall(function()
        _G[CSK_CFG.Key_Sessions]  = sessionData
        _G[CSK_CFG.Key_Stability] = stabilityData
        _G[CSK_CFG.Key_Snapshot]  = snapData
        _G[CSK_CFG.Key_Knowledge] = knowData
    end)

    -- Filesystem secondary storage (graceful)
    pcall(function()
        CSK_FSWrite("sessions",  sessionData)
        CSK_FSWrite("stability", stabilityData)
        CSK_FSWrite("snapshot",  snapData)
        CSK_FSWrite("knowledge", knowData)
    end)
end

local function CSK_RestoreTable(t, dest, constructor)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(v) == "table" then
            if constructor then
                local rec = constructor(k)
                for fk, fv in pairs(v) do rec[fk] = fv end
                dest[k] = rec
            else
                dest[k] = v
            end
        end
    end
end

function CSK.Load()
    -- Try _G first, then filesystem
    local function tryLoad(key, fsKey)
        local d = _G[key]
        if type(d) == "table" then return d end
        return CSK_FSRead(fsKey)
    end

    pcall(function()
        -- Sessions
        local sesData = tryLoad(CSK_CFG.Key_Sessions, "sessions")
        if type(sesData) == "table" then
            CSK_Sessions = {}
            for _, s in ipairs(sesData) do
                if type(s) == "table" and s.PersistVer == CSK_CFG.PersistVer then
                    table.insert(CSK_Sessions, s)
                end
            end
            -- Restore session ID counter
            for _, s in ipairs(CSK_Sessions) do
                if (s.id or 0) > CSK_SessionIDSeq then CSK_SessionIDSeq = s.id end
            end
        end

        -- Stability
        local stabData = tryLoad(CSK_CFG.Key_Stability, "stability")
        if type(stabData) == "table" then
            CSK_RestoreTable(stabData, CSK_Stability, CSK_NewStabilityRecord)
        end

        -- Snapshot
        local snapData = tryLoad(CSK_CFG.Key_Snapshot, "snapshot")
        if type(snapData) == "table" then CSK_LastSnap = snapData end

        -- Knowledge graph
        local knowData = tryLoad(CSK_CFG.Key_Knowledge, "knowledge")
        if type(knowData) == "table" then
            CSK_RestoreTable(knowData, CSK_Knowledge, CSK_NewKnowledgeNode)
        end

        local nSessions = #CSK_Sessions
        local nStab     = 0; for _ in pairs(CSK_Stability) do nStab=nStab+1 end
        local nKnow     = 0; for _ in pairs(CSK_Knowledge)  do nKnow=nKnow+1 end
        print(string.format("[CSK] Loaded: %d sessions, %d stability records, %d knowledge nodes.",
            nSessions, nStab, nKnow))
    end)
end

-- ═════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════

function CSK.GetSessions(n)
    n = n or #CSK_Sessions
    local out = {}
    local start = math.max(1, #CSK_Sessions - n + 1)
    for i = start, #CSK_Sessions do
        table.insert(out, CSK_Sessions[i])
    end
    return out
end

function CSK.GetCurrentSession()
    return CSK_CurrentSession
end

function CSK.GetDeltas(minMagnitude)
    local all = CSK_DeltaAnalyzer.GetAll()
    if not minMagnitude then return all end
    local out = {}
    for _, d in ipairs(all) do
        if d.magnitude >= minMagnitude then table.insert(out, d) end
    end
    return out
end

function CSK.GetStability(remoteName)
    return CSK_Stability[remoteName]
end

function CSK.GetAllStability(minSessions)
    minSessions = minSessions or 0
    local out = {}
    for _, srec in pairs(CSK_Stability) do
        if srec.sessionsSeen >= minSessions then
            table.insert(out, srec)
        end
    end
    table.sort(out, function(a,b) return a.stabilityScore < b.stabilityScore end)
    return out
end

function CSK.GetReprobeQueue()
    return CSK_ReprobeQ
end

function CSK.GetReprobeEntry(remoteName)
    for _, entry in ipairs(CSK_ReprobeQ) do
        if entry.name == remoteName then return entry end
    end
    return nil
end

function CSK.ForceSnapshot()
    CSK_LastSnap = CSK_BuildSnapshot()
    return CSK_LastSnap
end

function CSK.GetStats()
    local nDeltas, nRegressions = 0, 0
    for _, dlist in pairs(CSK_Deltas) do
        for _, d in ipairs(dlist) do
            nDeltas = nDeltas + 1
            if d.deltaType == CSK.DELTA.CONF_REGRESSION then
                nRegressions = nRegressions + 1
            end
        end
    end
    local nKnow, nClassified = 0, 0
    for _, knode in pairs(CSK_Knowledge) do
        nKnow = nKnow + 1
        if knode.serverLogic ~= "UNKNOWN" then nClassified = nClassified + 1 end
    end
    return {
        SessionCount    = #CSK_Sessions,
        CurrentSession  = CSK_CurrentSession and CSK_CurrentSession.id or nil,
        DeltaCount      = nDeltas,
        RegressionCount = nRegressions,
        ReprobeQueueLen = #CSK_ReprobeQ,
        KnowledgeNodes  = nKnow,
        ClassifiedNodes = nClassified,
        StabilityRecords= (function() local n=0; for _ in pairs(CSK_Stability) do n=n+1 end; return n end)(),
    }
end

-- ═════════════════════════════════════════════════════════════
-- APE SCORER INTEGRATION
-- Patches APE.Scorer.Score to factor in CSK stability + reprobe queue
-- ═════════════════════════════════════════════════════════════
local function CSK_PatchAPEScorer()
    local APE = _G.PC.APE
    if not APE or not APE.Scorer then return false end

    local origScore = APE.Scorer.Score
    APE.Scorer.Score = function(remoteName)
        local base = origScore(remoteName)

        -- Reprobe queue boost
        local reprobeEntry = CSK.GetReprobeEntry(remoteName)
        if reprobeEntry then
            base = math.max(base, reprobeEntry.priority * 0.95)
        end

        -- Stability penalty (stable + well-known = lower priority)
        local srec = CSK_Stability[remoteName]
        if srec and srec.stabilityScore >= 0.85 and srec.sessionsSeen >= 3 then
            local knode = CSK_Knowledge[remoteName]
            if knode and (knode.peakConfidence or 0) >= 0.75 then
                base = base * 0.5  -- well-understood, don't over-probe
            end
        end

        -- Drift boost (unstable despite multiple sessions)
        if srec and srec.driftDetected then
            base = base * 1.4
        end

        return base
    end
    print("[CSK] Patched APE.Scorer.Score with CSK stability/reprobe factors.")
    return true
end

-- ═════════════════════════════════════════════════════════════
-- STARTUP
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    local function waitFor(getter, label, timeout)
        local t0 = os.clock()
        while not getter() do
            if os.clock()-t0 > timeout then
                warn("[CSK] Timeout waiting for "..label); return false
            end
            task.wait(0.5)
        end
        return true
    end

    waitFor(function() return _G.PC.SBI end,  "SBI",  40)
    waitFor(function() return _G.PC.RSM end,  "RSM",  35)
    waitFor(function() return _G.PC.APE end,  "APE",  40)

    -- 1. Load persisted state
    CSK.Load()

    -- 2. Delta analysis vs last session snapshot
    local allDeltas = {}
    if CSK_LastSnap then
        allDeltas = CSK_DeltaAnalyzer.Analyze(CSK_LastSnap)
        if #allDeltas > 0 then
            print(string.format("[CSK] Delta analysis: %d changes detected since last session.",
                #allDeltas))
        end
    else
        -- First run: build initial snapshot
        CSK_LastSnap = CSK_BuildSnapshot()
    end

    -- 3. Consolidate knowledge from live state
    task.wait(2.0)  -- let SBI settle after its own startup rebuild
    CSK_Consolidator.Refresh()
    CSK_StabilityTracker.UpdateAll()

    -- 4. Build re-probe queue
    CSK_ReprobeScheduler.Build()

    -- 5. Restore CausalLinks from knowledge graph
    local restored = CSK_Consolidator.RestoreSBILinks()
    if restored > 0 then
        print(string.format("[CSK] Restored CausalLinks for %d remotes from knowledge graph.", restored))
    end

    -- 6. Open session log
    CSK_Logger.OpenSession()

    -- 7. Patch APE scorer
    task.wait(0.5)
    CSK_PatchAPEScorer()

    -- 8. Emit digest notification
    local digest = CSK.GetDigest()
    print("[CSK] Intel Digest:\n" .. digest)

    print("[CSK] Cross-Session Knowledge ready.")

    -- Auto-persist loop: every 60s + on session events
    task.spawn(function()
        while true do
            task.wait(60)
            pcall(CSK_Consolidator.Refresh)
            pcall(CSK_StabilityTracker.UpdateAll)
            pcall(CSK_ReprobeScheduler.Build)
            pcall(CSK.Save)
        end
    end)

    -- Shutdown hook: close session + write snapshot on teleport/leave
    pcall(function()
        local Players = _G.PC.Players
        if Players then
            local player = Players.LocalPlayer or _G.PC.player
            if player then
                player.AncestryChanged:Connect(function(_, parent)
                    if parent == nil then
                        pcall(CSK_Logger.CloseSession)
                        CSK_LastSnap = CSK_BuildSnapshot()
                        pcall(CSK.Save)
                    end
                end)
            end
        end
        -- Also hook game:BindToClose for executor-level scripts
        if game.BindToClose then
            game:BindToClose(function()
                pcall(CSK_Logger.CloseSession)
                CSK_LastSnap = CSK_BuildSnapshot()
                pcall(CSK.Save)
            end)
        end
    end)
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.CSK              = CSK
_G.PC.CSK_DeltaAnalyzer= CSK_DeltaAnalyzer
_G.PC.CSK_Stability    = CSK_Stability
_G.PC.CSK_Knowledge    = CSK_Knowledge
print("[CSK] Module registered.")
