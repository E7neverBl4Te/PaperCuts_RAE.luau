-- ── Imports ──────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- AVD TRANSLATOR — Data Normalization Layer
-- Sits between the Sentry's raw event stream and the
-- Strategist's interpretation logic.
-- Responsibilities:
--   1. Ingest raw Sentry events
--   2. Correlate events to probe timestamps
--   3. Filter baseline noise from probe-caused signals
--   4. Produce clean, typed Correlation Reports
--   5. Classify signal strength (SILENT / WEAK / STRONG / CONFIRMED)
-- ============================================================

local TRANSLATOR_CFG = {
    -- How long after a probe to watch for ripples (seconds)
    CorrelationWindow   = 3.0,
    -- Minimum event delta from baseline to count as signal
    -- (events that happen at this rate during baseline are noise)
    BaselineNoiseFloor  = 0.05,  -- events per second
    -- Signal classification thresholds
    WeakThreshold       = 1,     -- at least 1 non-baseline event
    StrongThreshold     = 3,     -- at least 3 correlated events
    ConfirmedThreshold  = 1,     -- at least 1 Tier 1 or Tier 3 event
    -- Latency spike multiplier over baseline to flag as execution evidence
    LatencySpikeMultiplier = 1.8,
    -- Max reports to keep in memory
    ReportCap           = 256,
}

-- ── State ─────────────────────────────────────────────────────────────────────
local AVD_Translator = {}

-- Pending probe slots waiting for correlation
-- [probeID] = { probeTime, remoteName, channel, timeout, events={} }
local T_PendingProbes = {}

-- Completed correlation reports
local T_Reports    = {}
local T_ReportPtr  = 0

-- Baseline noise profile per container path
-- [path] = { eventCount, windowStart, ratePerSec }
local T_BaselineNoise = {}

-- ── Signal classification ─────────────────────────────────────────────────────
-- SILENT    — no events correlated, or all events match baseline rate
-- WEAK      — events occurred but indistinguishable from noise
-- STRONG    — clear above-baseline activity in correlation window
-- CONFIRMED — Tier 1 or Tier 3 event directly correlated (highest confidence)
-- LATENCY   — no state change but execution-time spike detected
-- ERROR     — server returned an error-pattern response

local SIGNAL = {
    SILENT    = "SILENT",
    WEAK      = "WEAK",
    STRONG    = "STRONG",
    CONFIRMED = "CONFIRMED",
    LATENCY   = "LATENCY",
    ERROR     = "ERROR",
}

-- ── Baseline noise profiler ───────────────────────────────────────────────────
local function T_UpdateNoise(event)
    if not event.isBaseline then return end
    local path = event.path or "unknown"
    if not T_BaselineNoise[path] then
        T_BaselineNoise[path] = { count=0, windowStart=event.t }
    end
    local n = T_BaselineNoise[path]
    n.count = n.count + 1
    local elapsed = event.t - n.windowStart
    if elapsed > 0 then
        n.ratePerSec = n.count / elapsed
    end
end

local function T_IsNoise(event)
    local path = event.path or "unknown"
    local n    = T_BaselineNoise[path]
    if not n or not n.ratePerSec then return false end
    -- If this path fires at >= noiseFloor during baseline, treat as noise
    return n.ratePerSec >= TRANSLATOR_CFG.BaselineNoiseFloor
end

-- ── Report constructor ────────────────────────────────────────────────────────
local function T_NewReport(probeID, probeMeta)
    return {
        probeID      = probeID,
        remoteName   = probeMeta.remoteName,
        remoteType   = probeMeta.remoteType,
        channel      = probeMeta.channel,
        probeKind    = probeMeta.probeKind,
        probeArgs    = probeMeta.probeArgs,
        probeTime    = probeMeta.probeTime,
        resolvedAt   = nil,

        -- Signal classification
        signal       = SIGNAL.SILENT,
        confidence   = 0.0,  -- 0.0 to 1.0

        -- Evidence buckets
        tier1Events  = {},   -- property / attribute changes
        tier2Events  = {},   -- new descendants
        tier3Events  = {},   -- debris (transient instances)
        tier4Events  = {},   -- latency spikes
        noiseEvents  = {},   -- filtered out as baseline noise

        -- Summary fields for Strategist consumption
        totalSignals = 0,
        affectedPaths= {},   -- which DataModel paths changed
        latencyDelta = nil,  -- ms over baseline (if any)
        debrisClasses= {},   -- class names of transient instances seen

        -- Raw correlated events (unfiltered)
        rawEvents    = {},
    }
end

-- ── Event ingestion (called by Sentry on every new event) ────────────────────
function AVD_Translator.Ingest(event)
    -- Always update noise profile during baseline
    T_UpdateNoise(event)

    -- Route to any pending probe windows that are still open
    local now = os.clock()
    for probeID, slot in pairs(T_PendingProbes) do
        if event.t >= slot.probeTime and
           event.t <= slot.probeTime + TRANSLATOR_CFG.CorrelationWindow then
            table.insert(slot.events, event)
        end
    end
end

-- ── Probe registration ────────────────────────────────────────────────────────
-- Called by the Operator when it fires a probe.
-- Opens a correlation window for this probe.
function AVD_Translator.RegisterProbe(probeID, meta)
    -- meta = { remoteName, remoteType, channel, probeKind, probeArgs, probeTime }
    T_PendingProbes[probeID] = {
        probeTime  = meta.probeTime or os.clock(),
        remoteName = meta.remoteName,
        remoteType = meta.remoteType,
        channel    = meta.channel,
        probeKind  = meta.probeKind,
        probeArgs  = meta.probeArgs,
        events     = {},
    }

    -- Auto-resolve after correlation window closes
    task.delay(TRANSLATOR_CFG.CorrelationWindow + 0.1, function()
        AVD_Translator.Resolve(probeID)
    end)
end

-- ── Resolution: classify the signal from a closed probe window ───────────────
function AVD_Translator.Resolve(probeID)
    local slot = T_PendingProbes[probeID]
    if not slot then return nil end
    T_PendingProbes[probeID] = nil

    local report = T_NewReport(probeID, slot)
    report.resolvedAt = os.clock()
    report.rawEvents  = slot.events

    -- Bucket events by tier, filter noise
    local signalCount = 0
    for _, ev in ipairs(slot.events) do
        if T_IsNoise(ev) then
            table.insert(report.noiseEvents, ev)
        else
            if ev.tier == 1 then
                table.insert(report.tier1Events, ev)
                signalCount = signalCount + 1
                -- Track affected paths
                if ev.path and not table.find(report.affectedPaths, ev.path) then
                    table.insert(report.affectedPaths, ev.path)
                end
            elseif ev.tier == 2 then
                table.insert(report.tier2Events, ev)
                signalCount = signalCount + 1
            elseif ev.tier == 3 then
                table.insert(report.tier3Events, ev)
                signalCount = signalCount + 1
                -- Track debris classes
                if ev.property and not table.find(report.debrisClasses, ev.property) then
                    table.insert(report.debrisClasses, ev.property)
                end
            elseif ev.tier == 4 then
                table.insert(report.tier4Events, ev)
                -- Check for latency spike
                local baseline = _G.PC.AVD and _G.PC.AVD.Sentry
                    and _G.PC.AVD.Sentry.GetLatencyBaseline()
                if baseline and ev.newValue then
                    local ratio = ev.newValue / baseline
                    if ratio >= TRANSLATOR_CFG.LatencySpikeMultiplier then
                        report.latencyDelta = ev.newValue - baseline
                        signalCount = signalCount + 1
                    end
                end
            end
        end
    end

    report.totalSignals = signalCount

    -- ── Signal classification logic ───────────────────────────────────────────
    local hasTier1or3 = #report.tier1Events > 0 or #report.tier3Events > 0
    local hasLatency  = report.latencyDelta ~= nil
    local hasError    = false

    -- Check for error patterns in tier1 events (StringValue changes
    -- that contain error-like text, or property revert patterns)
    for _, ev in ipairs(report.tier1Events) do
        if type(ev.newValue) == "string" then
            local low = ev.newValue:lower()
            if low:find("error") or low:find("fail") or low:find("invalid") or
               low:find("denied") or low:find("reject") then
                hasError = true
            end
        end
        -- Revert pattern: value returned to exactly what it was before
        if ev.oldValue ~= nil and ev.newValue == ev.oldValue then
            -- This is a correction — server accepted then rolled back
            -- Actually this is useful data — mark differently
        end
    end

    if hasError then
        report.signal     = SIGNAL.ERROR
        report.confidence = 0.6
    elseif hasTier1or3 then
        report.signal     = SIGNAL.CONFIRMED
        report.confidence = 0.85 + math.min(0.14, signalCount * 0.02)
    elseif signalCount >= TRANSLATOR_CFG.StrongThreshold then
        report.signal     = SIGNAL.STRONG
        report.confidence = 0.6 + math.min(0.24, signalCount * 0.05)
    elseif hasLatency then
        report.signal     = SIGNAL.LATENCY
        report.confidence = 0.55
    elseif signalCount >= TRANSLATOR_CFG.WeakThreshold then
        report.signal     = SIGNAL.WEAK
        report.confidence = 0.25 + math.min(0.24, signalCount * 0.05)
    else
        report.signal     = SIGNAL.SILENT
        report.confidence = 0.0
    end

    -- Store report
    T_ReportPtr = (T_ReportPtr % TRANSLATOR_CFG.ReportCap) + 1
    T_Reports[T_ReportPtr] = report

    -- Forward to Strategist
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
    if strategist and strategist.OnReport then
        pcall(strategist.OnReport, report)
    end

    return report
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Get all completed reports, optionally filtered by signal type
function AVD_Translator.GetReports(signalFilter)
    local out = {}
    for i = 1, math.min(#T_Reports, TRANSLATOR_CFG.ReportCap) do
        local r = T_Reports[i]
        if r then
            if not signalFilter or r.signal == signalFilter then
                table.insert(out, r)
            end
        end
    end
    table.sort(out, function(a,b) return (a.probeTime or 0) < (b.probeTime or 0) end)
    return out
end

-- Get reports for a specific remote
function AVD_Translator.GetReportsFor(remoteName)
    local out = {}
    for i = 1, #T_Reports do
        local r = T_Reports[i]
        if r and r.remoteName == remoteName then
            table.insert(out, r)
        end
    end
    return out
end

-- Quick summary: how many of each signal type do we have?
function AVD_Translator.GetSummary()
    local s = { SILENT=0, WEAK=0, STRONG=0, CONFIRMED=0, LATENCY=0, ERROR=0, total=0 }
    for i = 1, #T_Reports do
        local r = T_Reports[i]
        if r and r.signal then
            s[r.signal] = (s[r.signal] or 0) + 1
            s.total     = s.total + 1
        end
    end
    return s
end

-- Get the highest-confidence report for a remote
function AVD_Translator.GetBestReport(remoteName)
    local reports = AVD_Translator.GetReportsFor(remoteName)
    local best = nil
    for _, r in ipairs(reports) do
        if not best or r.confidence > best.confidence then best = r end
    end
    return best
end

-- Get noise profile for a path
function AVD_Translator.GetNoiseRate(path)
    local n = T_BaselineNoise[path]
    return n and n.ratePerSec or 0
end

-- Signal constants exposed for Strategist
AVD_Translator.SIGNAL = SIGNAL

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.AVD then _G.PC.AVD = {} end
_G.PC.AVD.Translator = AVD_Translator

print("[AVD Translator] Ready.")
