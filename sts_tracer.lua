-- ══════════════════════════════════════════════════════════════════════════════
-- STS_TRACER — Source-to-Sink Chain Tracer
-- PaperCuts RAE — Passive Security Audit Module
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Maps the full five-step Source-to-Sink data flow path through a game's
-- server architecture. Operates passively — no probe fires, no naked payloads,
-- no watchdog pressure. Works entirely from:
--   (a) Static analysis of STS-collected script sources
--   (b) Live observation of BindableEvent / MessagingService traffic
--   (c) RSM fire log correlation
--
-- The five hops:
--   Step 1 — Ingress        : RemoteEvent / RemoteFunction (client boundary)
--   Step 2 — Local Dispatch : BindableEvent / BindableFunction (trust elevation)
--   Step 3 — Fleet Broadcast: MessagingService (trust amplification)
--   Step 4 — Control Exec  : require(AssetID) (trust execution)
--   Step 5 — Egress        : HttpService (trust egress / C2)
--
-- Output: ranked chain map — each confirmed chain scored by hop count,
-- sanitization gaps, and terminal sink severity.
--
-- ══════════════════════════════════════════════════════════════════════════════

local TRCR = {}
TRCR.VERSION = "1.0.0"

-- ── State ─────────────────────────────────────────────────────────────────────
TRCR.STATE = {
    IDLE      = "IDLE",
    SCANNING  = "SCANNING",   -- static source analysis pass
    OBSERVING = "OBSERVING",  -- live traffic observation pass
    CORRELATE = "CORRELATE",  -- merging static + dynamic findings
    DONE      = "DONE",
    ERROR     = "ERROR",
}
TRCR.CurrentState = TRCR.STATE.IDLE

-- ── Configuration ─────────────────────────────────────────────────────────────
local CFG = {
    -- Static analysis
    ObserveWindow       = 30,     -- seconds of live observation
    ObserveInterval     = 0.5,    -- polling interval during observation

    -- Scoring weights
    W_UNSANITIZED_HOP   = 25,     -- per hop with no sanitization
    W_BINDABLE_PASS     = 20,     -- BindableEvent passes args through
    W_MESSAGING_REACH   = 35,     -- MessagingService reachable
    W_REQUIRE_DYNAMIC   = 50,     -- require() with non-literal AssetID
    W_HTTP_EGRESS       = 40,     -- HttpService reached
    W_FULL_CHAIN        = 30,     -- bonus for all 5 hops confirmed

    -- Severity thresholds
    SEV_CRITICAL        = 120,
    SEV_HIGH            = 80,
    SEV_MEDIUM          = 40,
    SEV_LOW             = 10,

    -- Static pattern matching
    -- Patterns that indicate sanitization is present
    SanitizationPatterns = {
        "type%(", "typeof%(", "tostring%(", "tonumber%(",
        "assert%(", "pcall%(", "error%(", "error%b()",
        "string%.len", "string%.sub", "string%.match",
        "#.-%s*[<>=]",  -- length check
        "if%s+type",    -- type guard
    },
}

-- ── Sink severity map ──────────────────────────────────────────────────────────
local SINK_SEVERITY = {
    RemoteEvent      = { level = 1, label = "INGRESS",    score = 0  },
    RemoteFunction   = { level = 1, label = "INGRESS",    score = 0  },
    BindableEvent    = { level = 2, label = "DISPATCH",   score = 20 },
    BindableFunction = { level = 2, label = "DISPATCH",   score = 20 },
    MessagingService = { level = 3, label = "BROADCAST",  score = 35 },
    require          = { level = 4, label = "EXEC",       score = 50 },
    HttpService      = { level = 5, label = "EGRESS",     score = 40 },
}

-- ── Storage ───────────────────────────────────────────────────────────────────
TRCR.Chains      = {}   -- confirmed source-to-sink chains
TRCR.Fragments   = {}   -- partial chains (1-4 hops)
TRCR.StaticFinds = {}   -- raw static analysis hits
TRCR.LiveFinds   = {}   -- live observation hits
TRCR.Stats = {
    scriptsScanned   = 0,
    remotesFound     = 0,
    bindablesFound   = 0,
    messagingFound   = 0,
    requireFound     = 0,
    httpFound        = 0,
    chainsConfirmed  = 0,
    sanitizationGaps = 0,
}

-- ── Callbacks ─────────────────────────────────────────────────────────────────
TRCR.OnStateChange  = nil  -- (new, old)
TRCR.OnChain        = nil  -- (chain)
TRCR.OnFragment     = nil  -- (fragment)
TRCR.OnLog          = nil  -- (level, msg)
TRCR.OnProgress     = nil  -- (pct, label)
TRCR.OnDone         = nil  -- (chains, fragments)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function setState(s)
    local old = TRCR.CurrentState
    TRCR.CurrentState = s
    if TRCR.OnStateChange then pcall(TRCR.OnStateChange, s, old) end
end

local function log(level, msg)
    if TRCR.OnLog then pcall(TRCR.OnLog, level, msg) end
    print(string.format("[TRCR][%s] %s", level, msg))
end

local function progress(pct, label)
    if TRCR.OnProgress then pcall(TRCR.OnProgress, pct, label) end
end

-- ── Sanitization detector ─────────────────────────────────────────────────────
-- Scans a code block for sanitization patterns near a given line.
-- Returns true if a sanitization call exists within 8 lines of the match.
local function hasSanitizationNear(source, matchPos, windowLines)
    windowLines = windowLines or 8
    -- Extract a window of lines around matchPos
    local lineStart = matchPos
    local lineEnd   = matchPos
    local newlines  = 0
    -- Walk back to find window start
    local pos = matchPos
    while pos > 1 and newlines < windowLines do
        pos = pos - 1
        if source:sub(pos, pos) == "\n" then
            newlines = newlines + 1
        end
    end
    lineStart = pos
    -- Walk forward to find window end
    newlines = 0
    pos = matchPos
    while pos < #source and newlines < windowLines do
        pos = pos + 1
        if source:sub(pos, pos) == "\n" then
            newlines = newlines + 1
        end
    end
    lineEnd = pos

    local window = source:sub(lineStart, lineEnd)
    for _, pat in ipairs(CFG.SanitizationPatterns) do
        if window:find(pat) then
            return true, pat
        end
    end
    return false, nil
end

-- ── Argument passthrough detector ────────────────────────────────────────────
-- Checks whether a found hop passes its argument through without rebinding.
-- A rebind looks like: local safeVal = sanitize(args[1])
-- A passthrough looks like: bindable:Fire(args[1]) or bindable:Fire(data)
-- where data was directly assigned from remote args.
local function detectPassthrough(source, hopPos)
    -- Extract the line containing the hop
    local lineStart = hopPos
    while lineStart > 1 and source:sub(lineStart-1, lineStart-1) ~= "\n" do
        lineStart = lineStart - 1
    end
    local lineEnd = source:find("\n", hopPos) or #source
    local line = source:sub(lineStart, lineEnd)

    -- If the call passes a variable without any transformation, it's a passthrough
    -- Patterns: :Fire(args), :Fire(data), :Fire(msg), :PostAsync(args)
    -- Not a passthrough: :Fire({safe=true, id=userId}) — reconstructed table
    local passthrough_patterns = {
        ":Fire%(args",
        ":Fire%(data",
        ":Fire%(msg",
        ":Fire%(payload",
        ":Fire%(input",
        ":Fire%(value",
        ":Invoke%(args",
        ":Invoke%(data",
        ":PostAsync%(args",
        ":PostAsync%(data",
        ":PublishAsync%(.-, args",
        ":PublishAsync%(.-, data",
        "require%(args",
        "require%(data",
        "require%(assetId",
        "require%(id",
    }

    for _, pat in ipairs(passthrough_patterns) do
        if line:lower():find(pat:lower()) then
            return true, line:match("^%s*(.-)%s*$")
        end
    end
    return false, line:match("^%s*(.-)%s*$")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1 — STATIC ANALYSIS PASS
-- ══════════════════════════════════════════════════════════════════════════════

-- Patterns for each hop type
local HOP_PATTERNS = {
    -- Step 1: RemoteEvent handlers
    {
        step    = 1,
        type    = "RemoteEvent",
        label   = "Ingress",
        patterns = {
            "OnServerEvent:Connect",
            "OnServerInvoke%s*=",
            ":BindToClose",
        },
    },
    -- Step 2: BindableEvent dispatch
    {
        step    = 2,
        type    = "BindableEvent",
        label   = "Local Dispatch",
        patterns = {
            ":Fire%(",
            ":Invoke%(",
            "BindableEvent",
            "BindableFunction",
            "Event:Fire",
        },
    },
    -- Step 3: MessagingService
    {
        step    = 3,
        type    = "MessagingService",
        label   = "Fleet Broadcast",
        patterns = {
            "MessagingService",
            ":PublishAsync%(",
            ":SubscribeAsync%(",
            "GlobalSystemAnnouncements",
            "GetService.*Messaging",
        },
    },
    -- Step 4: Dynamic require
    {
        step    = 4,
        type    = "require",
        label   = "Control Exec",
        patterns = {
            "require%(%s*[^%d\"]",   -- require with non-literal (variable)
            "require%(%s*assetId",
            "require%(%s*id",
            "require%(%s*data",
            "require%(%s*args",
            "require%(%s*msg",
            "require%(%s*moduleId",
            "require%(%s*asset",
        },
    },
    -- Step 5: HttpService egress
    {
        step    = 5,
        type    = "HttpService",
        label   = "Egress",
        patterns = {
            "HttpService",
            ":PostAsync%(",
            ":GetAsync%(",
            ":RequestAsync%(",
            "GetService.*Http",
        },
    },
}

local function scanSource(scriptName, source)
    local findings = {}   -- {step, type, label, pos, line, sanitized, passthrough}
    if not source or #source < 10 then return findings end

    for _, hopDef in ipairs(HOP_PATTERNS) do
        for _, pat in ipairs(hopDef.patterns) do
            local searchPos = 1
            while true do
                local s, e = source:find(pat, searchPos)
                if not s then break end

                -- Get the actual line
                local lineStart = s
                while lineStart > 1 and
                      source:sub(lineStart-1, lineStart-1) ~= "\n" do
                    lineStart = lineStart - 1
                end
                local lineEnd = source:find("\n", s) or #source
                local line = source:sub(lineStart, lineEnd):match("^%s*(.-)%s*$")

                -- Skip comment lines
                if not line:match("^%-%-") then
                    local sanitized, sanPat = hasSanitizationNear(source, s)
                    local passthrough, ptLine = detectPassthrough(source, s)

                    table.insert(findings, {
                        step        = hopDef.step,
                        type        = hopDef.type,
                        label       = hopDef.label,
                        pattern     = pat,
                        pos         = s,
                        line        = line,
                        sanitized   = sanitized,
                        sanPattern  = sanPat,
                        passthrough = passthrough,
                        script      = scriptName,
                        lineNum     = select(2, source:sub(1,s):gsub("\n","\n")),
                    })
                end

                searchPos = e + 1
            end
        end
    end

    return findings
end

function TRCR.RunStaticPass()
    setState(TRCR.STATE.SCANNING)
    log("INFO", "Static analysis pass started")
    progress(0, "Static: collecting sources")

    TRCR.StaticFinds = {}
    local sources = {}

    -- Source 1: STS script sources
    local STS = _G.PC and _G.PC.STS
    if STS and STS.Report and STS.Report.scriptSources then
        for name, src in pairs(STS.Report.scriptSources) do
            table.insert(sources, {name=name, source=src, origin="STS"})
        end
        log("INFO", string.format("STS sources: %d scripts", #sources))
    end

    -- Source 2: STS module index
    if STS and STS.Report and STS.Report.moduleIndex then
        for _, entry in ipairs(STS.Report.moduleIndex) do
            if entry.source and entry.name then
                table.insert(sources, {
                    name   = entry.name,
                    source = entry.source,
                    origin = "STS_MODULE",
                })
            end
        end
    end

    -- Source 3: Live DataModel script walk
    -- Read Script and ModuleScript source where accessible
    local function walkScripts(inst, depth)
        if depth > 10 then return end
        for _, child in ipairs(inst:GetChildren()) do
            local isScript = child:IsA("Script") or
                             child:IsA("LocalScript") or
                             child:IsA("ModuleScript")
            if isScript then
                local ok, src = pcall(function() return child.Source end)
                if ok and src and #src > 20 then
                    table.insert(sources, {
                        name   = child:GetFullName(),
                        source = src,
                        origin = "LIVE",
                    })
                end
            end
            walkScripts(child, depth + 1)
        end
    end

    for _, svcName in ipairs({
        "ServerScriptService","ServerStorage",
        "ReplicatedStorage","ReplicatedFirst"
    }) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then pcall(walkScripts, svc, 0) end
    end

    log("INFO", string.format("Total sources to scan: %d", #sources))

    -- Deduplicate by name
    local seen = {}
    local deduped = {}
    for _, s in ipairs(sources) do
        if not seen[s.name] then
            seen[s.name] = true
            table.insert(deduped, s)
        end
    end
    sources = deduped

    -- Scan each source
    for i, entry in ipairs(sources) do
        TRCR.Stats.scriptsScanned = TRCR.Stats.scriptsScanned + 1
        local pct = i / #sources
        progress(pct * 0.5, string.format(
            "Static: scanning %s (%d/%d)", entry.name, i, #sources))

        local findings = scanSource(entry.name, entry.source)

        for _, f in ipairs(findings) do
            table.insert(TRCR.StaticFinds, f)

            -- Update stats
            if f.step == 1 then TRCR.Stats.remotesFound   = TRCR.Stats.remotesFound   + 1 end
            if f.step == 2 then TRCR.Stats.bindablesFound  = TRCR.Stats.bindablesFound  + 1 end
            if f.step == 3 then TRCR.Stats.messagingFound  = TRCR.Stats.messagingFound  + 1 end
            if f.step == 4 then TRCR.Stats.requireFound    = TRCR.Stats.requireFound    + 1 end
            if f.step == 5 then TRCR.Stats.httpFound       = TRCR.Stats.httpFound       + 1 end
            if not f.sanitized then
                TRCR.Stats.sanitizationGaps = TRCR.Stats.sanitizationGaps + 1
            end
        end

        if #findings > 0 then
            log("INFO", string.format(
                "[%s] %d hop markers found (step coverage: %s)",
                entry.name, #findings,
                (function()
                    local steps = {}
                    for _, f in ipairs(findings) do steps[f.step] = true end
                    local s = {}
                    for k in pairs(steps) do table.insert(s, k) end
                    table.sort(s)
                    return table.concat(s, "→")
                end)()))
        end

        if i % 10 == 0 then task.wait(0) end
    end

    log("INFO", string.format(
        "Static pass complete — %d scripts  %d hop markers  %d sanitization gaps",
        TRCR.Stats.scriptsScanned, #TRCR.StaticFinds,
        TRCR.Stats.sanitizationGaps))

    return TRCR.StaticFinds
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2 — LIVE OBSERVATION PASS
-- ══════════════════════════════════════════════════════════════════════════════
-- Passively monitors RSM fire logs and script output for runtime evidence
-- of the chain executing under real game traffic.

function TRCR.RunObservationPass()
    setState(TRCR.STATE.OBSERVING)
    log("INFO", string.format(
        "Observation pass started — window: %ds", CFG.ObserveWindow))
    progress(0.5, "Observing live traffic")

    TRCR.LiveFinds = {}

    local RSM = _G.PC and _G.PC.RSM
    local startTime = os.clock()
    local baseline  = {}

    -- Snapshot RSM state at start
    if RSM and RSM.GetRegistry then
        local ok, reg = pcall(RSM.GetRegistry)
        if ok and reg then
            for name, entry in pairs(reg) do
                baseline[name] = entry.fireCount or 0
            end
        end
    end

    -- Observe for window duration
    local elapsed = 0
    while elapsed < CFG.ObserveWindow do
        task.wait(CFG.ObserveInterval)
        elapsed = os.clock() - startTime

        local pct = 0.5 + (elapsed / CFG.ObserveWindow) * 0.35
        progress(pct, string.format(
            "Observing: %.0fs / %ds", elapsed, CFG.ObserveWindow))

        -- Check RSM for new fires
        if RSM and RSM.GetRegistry then
            local ok, reg = pcall(RSM.GetRegistry)
            if ok and reg then
                for name, entry in pairs(reg) do
                    local baseCount = baseline[name] or 0
                    local newFires  = (entry.fireCount or 0) - baseCount

                    if newFires > 0 then
                        -- This remote fired during observation
                        table.insert(TRCR.LiveFinds, {
                            type      = "REMOTE_FIRE",
                            remote    = name,
                            newFires  = newFires,
                            timestamp = os.clock(),
                            step      = 1,
                        })
                        baseline[name] = entry.fireCount or 0
                    end
                end
            end
        end

        -- Observe MessagingService subscriptions if accessible
        -- Note: we cannot intercept MessagingService traffic directly from client.
        -- We log known subscription topics from static finds instead.
    end

    log("INFO", string.format(
        "Observation complete — %d live events captured", #TRCR.LiveFinds))

    return TRCR.LiveFinds
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3 — CHAIN ASSEMBLY (CORRELATION)
-- ══════════════════════════════════════════════════════════════════════════════
-- Groups static finds and live observations into chains.
-- A chain is a sequence of findings where:
--   - Each step is higher than the previous (1 → 2 → 3 → 4 → 5)
--   - Findings share a script or a script that connects to another via remote/bindable
-- Chains are scored and classified by severity.

local function scoreChain(chain)
    local score = 0
    local maxStep = 0

    for _, hop in ipairs(chain.hops) do
        maxStep = math.max(maxStep, hop.step)
        local sinkDef = SINK_SEVERITY[hop.type]
        if sinkDef then score = score + sinkDef.score end

        -- Bonus for passthrough (unsanitized hop)
        if not hop.sanitized then
            score = score + CFG.W_UNSANITIZED_HOP
        end
        if hop.passthrough then
            score = score + CFG.W_BINDABLE_PASS
        end
    end

    -- Bonus for reaching high-severity sinks
    if maxStep >= 3 then score = score + CFG.W_MESSAGING_REACH end
    if maxStep >= 4 then score = score + CFG.W_REQUIRE_DYNAMIC  end
    if maxStep >= 5 then score = score + CFG.W_HTTP_EGRESS       end
    if maxStep == 5 then score = score + CFG.W_FULL_CHAIN        end

    -- Severity classification
    local severity
    if score >= CFG.SEV_CRITICAL then
        severity = "CRITICAL"
    elseif score >= CFG.SEV_HIGH then
        severity = "HIGH"
    elseif score >= CFG.SEV_MEDIUM then
        severity = "MEDIUM"
    else
        severity = "LOW"
    end

    return score, severity, maxStep
end

local function assembleChainsFromScript(scriptName, findings)
    -- Group findings from this script by step
    local byStep = {}
    for _, f in ipairs(findings) do
        if f.script == scriptName then
            byStep[f.step] = byStep[f.step] or {}
            table.insert(byStep[f.step], f)
        end
    end

    -- Build chains: find sequences of consecutive steps
    local chains = {}
    local steps  = {}
    for step in pairs(byStep) do table.insert(steps, step) end
    table.sort(steps)

    if #steps < 2 then
        -- Single step — fragment only
        if #steps == 1 then
            local step = steps[1]
            for _, f in ipairs(byStep[step]) do
                table.insert(chains, {
                    id       = string.format("FRAG_%s_S%d", scriptName:sub(-20), step),
                    script   = scriptName,
                    hops     = {f},
                    complete = false,
                    liveConfirmed = false,
                })
            end
        end
        return chains
    end

    -- Build chain from all found steps in this script
    local hops = {}
    for _, step in ipairs(steps) do
        -- Take the highest-confidence hop per step (unsanitized passthrough wins)
        local best = byStep[step][1]
        for _, f in ipairs(byStep[step]) do
            if (not f.sanitized and best.sanitized) or
               (f.passthrough and not best.passthrough) then
                best = f
            end
        end
        table.insert(hops, best)
    end

    local maxStep = steps[#steps]
    table.insert(chains, {
        id       = string.format("CHAIN_%s_S1S%d", scriptName:sub(-20), maxStep),
        script   = scriptName,
        hops     = hops,
        complete = maxStep == 5,
        liveConfirmed = false,
        steps    = steps,
    })

    return chains
end

function TRCR.RunCorrelation()
    setState(TRCR.STATE.CORRELATE)
    log("INFO", "Correlation pass started")
    progress(0.85, "Correlating static + live findings")

    TRCR.Chains    = {}
    TRCR.Fragments = {}

    -- Group static finds by script
    local scriptNames = {}
    local seenScripts = {}
    for _, f in ipairs(TRCR.StaticFinds) do
        if not seenScripts[f.script] then
            seenScripts[f.script] = true
            table.insert(scriptNames, f.script)
        end
    end

    -- Assemble chains per script
    for _, scriptName in ipairs(scriptNames) do
        local chains = assembleChainsFromScript(scriptName, TRCR.StaticFinds)
        for _, chain in ipairs(chains) do
            -- Cross-reference with live observation
            for _, live in ipairs(TRCR.LiveFinds) do
                if live.type == "REMOTE_FIRE" then
                    for _, hop in ipairs(chain.hops) do
                        if hop.line and hop.line:find(live.remote, 1, true) then
                            chain.liveConfirmed = true
                            chain.liveRemote    = live.remote
                            chain.liveFireCount = live.newFires
                            break
                        end
                    end
                end
            end

            -- Score
            local score, severity, maxStep = scoreChain(chain)
            chain.score    = score
            chain.severity = severity
            chain.maxStep  = maxStep

            -- Classify
            if chain.complete then
                table.insert(TRCR.Chains, chain)
                TRCR.Stats.chainsConfirmed = TRCR.Stats.chainsConfirmed + 1
                log("CHAIN", string.format(
                    "[%s] FULL CHAIN  score=%d  severity=%s  live=%s",
                    chain.id, score, severity,
                    tostring(chain.liveConfirmed)))
                if TRCR.OnChain then pcall(TRCR.OnChain, chain) end
            elseif #chain.hops >= 2 then
                table.insert(TRCR.Fragments, chain)
                log("FRAG", string.format(
                    "[%s] Fragment S%s  score=%d  severity=%s",
                    chain.id,
                    table.concat(chain.steps or {}, "→"),
                    score, severity))
                if TRCR.OnFragment then pcall(TRCR.OnFragment, chain) end
            end
        end
    end

    -- Sort by score descending
    table.sort(TRCR.Chains,    function(a,b) return a.score > b.score end)
    table.sort(TRCR.Fragments, function(a,b) return a.score > b.score end)

    log("INFO", string.format(
        "Correlation complete — %d full chains  %d fragments",
        #TRCR.Chains, #TRCR.Fragments))

    progress(1.0, "Done")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FULL RUN
-- ══════════════════════════════════════════════════════════════════════════════
function TRCR.Run()
    if TRCR.CurrentState ~= TRCR.STATE.IDLE and
       TRCR.CurrentState ~= TRCR.STATE.DONE and
       TRCR.CurrentState ~= TRCR.STATE.ERROR then
        return false, "Already running (state: " .. TRCR.CurrentState .. ")"
    end

    -- Reset
    TRCR.Chains      = {}
    TRCR.Fragments   = {}
    TRCR.StaticFinds = {}
    TRCR.LiveFinds   = {}
    TRCR.Stats = {
        scriptsScanned=0, remotesFound=0, bindablesFound=0,
        messagingFound=0, requireFound=0, httpFound=0,
        chainsConfirmed=0, sanitizationGaps=0,
    }

    log("INFO", "Source-to-Sink Tracer v" .. TRCR.VERSION .. " started")

    task.spawn(function()
        local ok, err = pcall(function()
            -- Phase 1: Static
            TRCR.RunStaticPass()
            task.wait(0)

            -- Phase 2: Live observation (runs concurrently with nothing else)
            TRCR.RunObservationPass()
            task.wait(0)

            -- Phase 3: Correlate
            TRCR.RunCorrelation()

            setState(TRCR.STATE.DONE)

            log("INFO", string.format(
                "Run complete — %d chains  %d fragments  %d gaps",
                #TRCR.Chains, #TRCR.Fragments, TRCR.Stats.sanitizationGaps))

            if TRCR.OnDone then
                pcall(TRCR.OnDone, TRCR.Chains, TRCR.Fragments)
            end
        end)

        if not ok then
            setState(TRCR.STATE.ERROR)
            log("ERROR", tostring(err))
        end
    end)

    return true, nil
end

-- ── Static-only mode (no observation window) ───────────────────────────────
function TRCR.RunStatic()
    if TRCR.CurrentState ~= TRCR.STATE.IDLE and
       TRCR.CurrentState ~= TRCR.STATE.DONE and
       TRCR.CurrentState ~= TRCR.STATE.ERROR then
        return false, "Already running"
    end

    TRCR.Chains      = {}
    TRCR.Fragments   = {}
    TRCR.StaticFinds = {}
    TRCR.LiveFinds   = {}
    TRCR.Stats = {
        scriptsScanned=0, remotesFound=0, bindablesFound=0,
        messagingFound=0, requireFound=0, httpFound=0,
        chainsConfirmed=0, sanitizationGaps=0,
    }

    task.spawn(function()
        local ok, err = pcall(function()
            TRCR.RunStaticPass()
            task.wait(0)
            TRCR.RunCorrelation()
            setState(TRCR.STATE.DONE)
            if TRCR.OnDone then
                pcall(TRCR.OnDone, TRCR.Chains, TRCR.Fragments)
            end
        end)
        if not ok then
            setState(TRCR.STATE.ERROR)
            log("ERROR", tostring(err))
        end
    end)

    return true, nil
end

-- ── Reset ──────────────────────────────────────────────────────────────────────
function TRCR.Reset()
    setState(TRCR.STATE.IDLE)
    TRCR.Chains      = {}
    TRCR.Fragments   = {}
    TRCR.StaticFinds = {}
    TRCR.LiveFinds   = {}
    TRCR.Stats = {
        scriptsScanned=0, remotesFound=0, bindablesFound=0,
        messagingFound=0, requireFound=0, httpFound=0,
        chainsConfirmed=0, sanitizationGaps=0,
    }
    log("INFO", "TRCR reset")
end

-- ── GetStats ───────────────────────────────────────────────────────────────────
function TRCR.GetStats()
    return {
        state            = TRCR.CurrentState,
        scriptsScanned   = TRCR.Stats.scriptsScanned,
        remotesFound     = TRCR.Stats.remotesFound,
        bindablesFound   = TRCR.Stats.bindablesFound,
        messagingFound   = TRCR.Stats.messagingFound,
        requireFound     = TRCR.Stats.requireFound,
        httpFound        = TRCR.Stats.httpFound,
        chainsConfirmed  = TRCR.Stats.chainsConfirmed,
        sanitizationGaps = TRCR.Stats.sanitizationGaps,
        chains           = #TRCR.Chains,
        fragments        = #TRCR.Fragments,
        staticFinds      = #TRCR.StaticFinds,
        liveFinds        = #TRCR.LiveFinds,
    }
end

-- ── Export ─────────────────────────────────────────────────────────────────────
_G.PC        = _G.PC or {}
_G.PC.TRCR   = TRCR
print(string.format("[TRCR] Source-to-Sink Tracer v%s ready.", TRCR.VERSION))
