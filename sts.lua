-- ══════════════════════════════════════════════════════════════════════════════
-- STS — Server Topology Scanner
-- PaperCuts RAE — Intelligence Layer 9
-- ══════════════════════════════════════════════════════════════════════════════
-- Performs a full client-visible DataModel traversal once Bedrock is confirmed.
-- Extracts, annotates, and synthesizes everything the server exposes:
--
--   Phase 1 — DataModel Walk
--     Recursive traversal of all reachable services. Every Instance recorded:
--     class, name, full path, depth, children count, properties where readable.
--
--   Phase 2 — Deep Extraction
--     ModuleScript.Source (replicated modules are fully readable client-side)
--     RemoteEvent / RemoteFunction topology + PR_Registry cross-reference
--     Value objects (StringValue, NumberValue, BoolValue, etc.) with live values
--     Configuration folders, BindableEvent/BindableFunction topology
--     LocalScript presence in StarterGui / StarterPlayer (reveals client arch)
--     Attribute dumps on key instances
--
--   Phase 3 — Intelligence Synthesis
--     Each Remote annotated with RSM signature, SBI confidence, CDG edges
--     ModuleScript sources pattern-analyzed: function names, RemoteEvent refs,
--     DataStore calls, HTTP calls, require() chains
--     Topology cross-referenced against ASE Bedrock pairs
--     Final synthesis: service map, remote catalog, module index, value schema
--
-- Output: STS.Report — structured table, queryable by service / class / type
-- Gated: requires ASE Bedrock confirmation (HeartbeatAlive) before scan
-- ══════════════════════════════════════════════════════════════════════════════

local STS = {}

-- ── Services ──────────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local ReplicatedFirst  = game:GetService("ReplicatedFirst")
local StarterGui       = game:GetService("StarterGui")
local StarterPack      = game:GetService("StarterPack")
local StarterPlayer    = game:GetService("StarterPlayer")
local Workspace        = game:GetService("Workspace")
local Lighting         = game:GetService("Lighting")
local SoundService     = game:GetService("SoundService")
local Teams            = game:GetService("Teams")
local MarketplaceService = game:GetService("MarketplaceService")

-- ── Constants ─────────────────────────────────────────────────────────────────
STS.VERSION = "1.0.0"

STS.SCAN_SERVICES = {
    { name="ReplicatedStorage",  svc=ReplicatedStorage,  priority=1 },
    { name="ReplicatedFirst",    svc=ReplicatedFirst,    priority=2 },
    { name="StarterGui",         svc=StarterGui,         priority=3 },
    { name="StarterPack",        svc=StarterPack,        priority=4 },
    { name="StarterPlayer",      svc=StarterPlayer,      priority=5 },
    { name="Workspace",          svc=Workspace,          priority=6 },
    { name="Lighting",           svc=Lighting,           priority=7 },
    { name="SoundService",       svc=SoundService,       priority=8 },
    { name="Teams",              svc=Teams,              priority=9 },
    { name="Players",            svc=Players,            priority=10 },
}

-- Classes that carry intelligence value
STS.INTEREST_CLASSES = {
    RemoteEvent       = "REMOTE",
    RemoteFunction    = "REMOTE",
    BindableEvent     = "BINDABLE",
    BindableFunction  = "BINDABLE",
    ModuleScript      = "MODULE",
    LocalScript       = "LOCALSCRIPT",
    Script            = "SCRIPT",
    StringValue       = "VALUE",
    NumberValue       = "VALUE",
    BoolValue         = "VALUE",
    IntValue          = "VALUE",
    ObjectValue       = "VALUE",
    Color3Value       = "VALUE",
    Vector3Value      = "VALUE",
    CFrameValue       = "VALUE",
    Configuration     = "CONFIG",
    Folder            = "FOLDER",
    Model             = "MODEL",
    Sound             = "SOUND",
    Animation         = "ANIMATION",
    Team              = "TEAM",
}

-- Max depth to traverse (prevents infinite loops on circular refs)
local MAX_DEPTH = 32
-- Max instances per service (per-service cap — prevents one service starving others)
local MAX_INSTANCES = 4000
-- Max source bytes to read from a ModuleScript
local MAX_SOURCE_BYTES = 64000

-- ── State ─────────────────────────────────────────────────────────────────────
STS.Report       = nil   -- populated after scan
STS.ScanState    = "IDLE"  -- IDLE | SCANNING | COMPLETE | ERROR
STS.Progress     = { phase=0, service="", count=0, total=0 }
STS.OnProgress   = nil   -- callback(phase, service, count, total)
STS.OnComplete   = nil   -- callback(report)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function notify(phase, svc, count, total)
    STS.Progress = { phase=phase, service=svc, count=count, total=total }
    if STS.OnProgress then
        pcall(STS.OnProgress, phase, svc, count, total)
    end
end

local function safeProp(instance, prop)
    local ok, val = pcall(function() return instance[prop] end)
    return ok and val or nil
end

local function instancePath(instance)
    local parts = {}
    local cur = instance
    local depth = 0
    while cur and cur ~= game and depth < 20 do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
        depth = depth + 1
    end
    return table.concat(parts, ".")
end

-- ── Module Source Analyzer ────────────────────────────────────────────────────
-- Scans ModuleScript source for patterns of interest.
local function analyzeSource(source)
    if not source or #source == 0 then
        return { empty=true }
    end

    local analysis = {
        lineCount       = 0,
        byteCount       = #source,
        functions       = {},
        remoteRefs      = {},
        datastoreRefs   = {},
        httpRefs        = {},
        requireChain    = {},
        marketplaceRefs = {},
        globalWrites    = {},
        suspiciousKeys  = {},
        empty           = false,
    }

    -- Line count
    for _ in source:gmatch("\n") do
        analysis.lineCount = analysis.lineCount + 1
    end
    analysis.lineCount = analysis.lineCount + 1

    -- Function declarations
    for fname in source:gmatch("function%s+([%w_%.]+)%s*%(") do
        table.insert(analysis.functions, fname)
    end
    for fname in source:gmatch("local%s+function%s+([%w_]+)%s*%(") do
        table.insert(analysis.functions, fname)
    end
    -- Deduplicate
    local seen = {}
    local uniq = {}
    for _, f in ipairs(analysis.functions) do
        if not seen[f] then seen[f]=true; table.insert(uniq, f) end
    end
    analysis.functions = uniq

    -- RemoteEvent/RemoteFunction references
    for ref in source:gmatch(":FireServer%(") do
        table.insert(analysis.remoteRefs, "FireServer")
    end
    for ref in source:gmatch(":InvokeServer%(") do
        table.insert(analysis.remoteRefs, "InvokeServer")
    end
    for ref in source:gmatch(":FireAllClients%(") do
        table.insert(analysis.remoteRefs, "FireAllClients")
    end
    for ref in source:gmatch(":FireClient%(") do
        table.insert(analysis.remoteRefs, "FireClient")
    end
    for name in source:gmatch("RemoteEvent[\"']?:?%s*([%w_]+)") do
        table.insert(analysis.remoteRefs, name)
    end
    -- Deduplicate remote refs
    seen = {}; uniq = {}
    for _, r in ipairs(analysis.remoteRefs) do
        if not seen[r] then seen[r]=true; table.insert(uniq, r) end
    end
    analysis.remoteRefs = uniq

    -- DataStore references
    for dsname in source:gmatch("GetDataStore%([\"']([^\"']+)[\"']%)") do
        table.insert(analysis.datastoreRefs, dsname)
    end
    for dsname in source:gmatch("GetOrderedDataStore%([\"']([^\"']+)[\"']%)") do
        table.insert(analysis.datastoreRefs, "ORDERED:" .. dsname)
    end
    if source:find("DataStoreService") then
        if #analysis.datastoreRefs == 0 then
            table.insert(analysis.datastoreRefs, "[DataStoreService referenced]")
        end
    end

    -- HTTP references
    if source:find("HttpService") or source:find("HttpGet") or source:find("PostAsync") then
        for url in source:gmatch("[\"'](https?://[^\"']+)[\"']") do
            table.insert(analysis.httpRefs, url:sub(1,120))
        end
        if #analysis.httpRefs == 0 then
            table.insert(analysis.httpRefs, "[HttpService referenced]")
        end
    end

    -- require() chains
    for req in source:gmatch("require%s*%(([^%)]+)%)") do
        table.insert(analysis.requireChain, req:match("^%s*(.-)%s*$"):sub(1,60))
    end

    -- MarketplaceService
    if source:find("MarketplaceService") then
        for prod in source:gmatch("GetProductInfo%s*%(([^%)]+)%)") do
            table.insert(analysis.marketplaceRefs, prod:sub(1,40))
        end
        if #analysis.marketplaceRefs == 0 then
            table.insert(analysis.marketplaceRefs, "[MarketplaceService referenced]")
        end
    end

    -- Global writes (_G assignments)
    for key in source:gmatch("_G%.([%w_]+)%s*=") do
        table.insert(analysis.globalWrites, key)
    end

    -- Suspicious patterns
    local suspPatterns = {
        { pat="getfenv",     label="getfenv() — environment access" },
        { pat="setfenv",     label="setfenv() — environment override" },
        { pat="loadstring",  label="loadstring() — dynamic execution" },
        { pat="rawset",      label="rawset() — bypass __newindex" },
        { pat="rawget",      label="rawget() — bypass __index" },
        { pat="debug%.info", label="debug.info — stack introspection" },
        { pat="coroutine",   label="coroutine usage" },
    }
    for _, sp in ipairs(suspPatterns) do
        if source:find(sp.pat) then
            table.insert(analysis.suspiciousKeys, sp.label)
        end
    end

    return analysis
end

-- ── Phase 1 + 2: Instance Walker ──────────────────────────────────────────────
local function walkService(serviceEntry, allRemotes, instanceCount)
    local svc     = serviceEntry.svc
    local svcName = serviceEntry.name
    local nodes   = {}
    local count   = instanceCount or {n=0}

    local function walk(inst, depth, parentPath)
        if depth > MAX_DEPTH then return end
        if count.n >= MAX_INSTANCES then return end

        local ok, children = pcall(function() return inst:GetChildren() end)
        if not ok then return end

        for _, child in ipairs(children) do
            if count.n >= MAX_INSTANCES then break end
            count.n = count.n + 1

            local className  = safeProp(child, "ClassName") or "Unknown"
            local name       = safeProp(child, "Name") or "?"
            local fullPath   = parentPath .. "." .. name
            local interestType = STS.INTEREST_CLASSES[className]

            local node = {
                name        = name,
                className   = className,
                path        = fullPath,
                depth       = depth,
                service     = svcName,
                interestType= interestType,
                childCount  = 0,
                -- enriched in phase 2
                source      = nil,
                sourceAnalysis = nil,
                value       = nil,
                attributes  = {},
                remoteIntel = nil,
            }

            -- Count children
            local cok, clist = pcall(function() return child:GetChildren() end)
            if cok then node.childCount = #clist end

            -- ── Phase 2: Deep extraction by class ─────────────────────────────

            -- ModuleScript: read source (may be unavailable in executor context)
            if className == "ModuleScript" then
                local msrc = safeProp(child, "Source")
                if msrc and #msrc > 0 then
                    node.source = msrc:sub(1, MAX_SOURCE_BYTES)
                    node.sourceAnalysis = analyzeSource(node.source)
                else
                    -- Source not exposed — record module presence with stub analysis
                    node.sourceAnalysis = {
                        empty        = false,
                        unavailable  = true,
                        lineCount    = 0,
                        byteCount    = 0,
                        functions    = {},
                        remoteRefs   = {},
                        datastoreRefs= {},
                        httpRefs     = {},
                        requireChain = {},
                        globalWrites = {},
                        suspiciousKeys={},
                    }
                end

            -- Value objects: capture live value
            elseif interestType == "VALUE" then
                node.value = safeProp(child, "Value")

            -- Remotes: register in allRemotes catalog
            elseif className == "RemoteEvent" or className == "RemoteFunction" then
                local entry = {
                    name      = name,
                    className = className,
                    path      = fullPath,
                    service   = svcName,
                    -- Intel filled in Phase 3
                    rsmSig    = nil,
                    sbiConf   = nil,
                    cdgEdges  = nil,
                    bedrockPair = nil,
                    prRecord  = nil,
                }
                table.insert(allRemotes, entry)
                node.remoteRef = entry

            -- Scripts: note presence (source not readable server-side)
            elseif className == "Script" then
                node.note = "Server Script — source server-only"
            elseif className == "LocalScript" then
                local src = safeProp(child, "Source")
                if src and #src > 0 then
                    node.source = src:sub(1, MAX_SOURCE_BYTES)
                    node.sourceAnalysis = analyzeSource(node.source)
                else
                    node.note = "LocalScript — source not exposed"
                end
            end

            -- Attribute dump (safe)
            local aok, attrs = pcall(function() return child:GetAttributes() end)
            if aok and attrs then
                for k, v in pairs(attrs) do
                    node.attributes[k] = tostring(v):sub(1,80)
                end
            end

            table.insert(nodes, node)

            -- Recurse
            walk(child, depth + 1, fullPath)
        end
    end

    walk(svc, 1, svcName)
    return nodes
end

-- ── Phase 3: Intelligence Synthesis ──────────────────────────────────────────
local function synthesize(serviceMap, allRemotes)
    local RSM = _G.PC and _G.PC.RSM
    local SBI = _G.PC and _G.PC.SBI
    local CDG = _G.PC and _G.PC.CDG
    local PR  = _G.PC and _G.PC.PR_Registry
    local ASE = _G.PC and _G.PC.ASE

    -- Annotate each remote with live pipeline intel
    local remoteCatalog = {}
    for _, entry in ipairs(allRemotes) do
        local name = entry.name

        -- RSM signature
        if RSM and RSM.Get then
            local rOk, sig = pcall(RSM.Get, RSM, name)
            if rOk and sig then
                entry.rsmSig = {
                    fireCount   = sig.FireCount or 0,
                    successRate = sig.SuccessRate or 0,
                    argCount    = sig.ArgSig and #sig.ArgSig or 0,
                    lastSeen    = sig.LastSeen,
                }
            end
        end

        -- SBI confidence
        if SBI and SBI.Get then
            local sOk, conf = pcall(SBI.Get, SBI, name)
            if sOk and conf then
                entry.sbiConf = conf.Confidence or 0
            end
        end

        -- CDG edges
        if CDG and CDG.GetEdgesFor then
            local ok, edges = pcall(CDG.GetEdgesFor, CDG, name)
            if ok and edges then
                entry.cdgEdges = {}
                for _, e in ipairs(edges) do
                    table.insert(entry.cdgEdges, {
                        ante       = e.antecedent,
                        conf       = e.confidence,
                        coFired    = e.coFired,
                    })
                end
            end
        end

        -- PR record
        if PR and PR[name] then
            local rec = PR[name]
            entry.prRecord = {
                direction  = rec.Direction,
                fireCount  = rec.FireCount,
                lastArgs   = rec.LastArgs,
            }
        end

        -- ASE Bedrock pair
        if ASE and ASE.GetBedrockPairs then
            local ok, pairs2 = pcall(ASE.GetBedrockPairs)
            if ok and pairs2 then
                for _, p in ipairs(pairs2) do
                    if p.sinkRemote == name or p.feedbackRemote == name then
                        entry.bedrockPair = {
                            sink     = p.sinkRemote,
                            feedback = p.feedbackRemote,
                            origin   = p.origin,
                            conf     = p.confidence,
                        }
                        break
                    end
                end
            end
        end

        -- Overall intelligence score (0–1) for sorting
        local score = 0
        if entry.sbiConf   then score = score + entry.sbiConf * 0.4 end
        if entry.rsmSig    then score = score + math.min((entry.rsmSig.fireCount or 0) / 20, 1) * 0.3 end
        if entry.cdgEdges  then score = score + math.min(#entry.cdgEdges / 3, 1) * 0.2 end
        if entry.bedrockPair then score = score + 0.1 end
        entry.intelScore = score

        remoteCatalog[name] = entry
    end

    -- Sort remotes by intel score descending
    local sortedRemotes = {}
    for _, entry in pairs(remoteCatalog) do
        table.insert(sortedRemotes, entry)
    end
    table.sort(sortedRemotes, function(a, b)
        return (a.intelScore or 0) > (b.intelScore or 0)
    end)

    -- Module index: all modules with source analysis
    local moduleIndex = {}
    for _, svcNodes in pairs(serviceMap) do
        for _, node in ipairs(svcNodes) do
            if node.className == "ModuleScript" and node.sourceAnalysis and not node.sourceAnalysis.empty then
                table.insert(moduleIndex, {
                    name        = node.name,
                    path        = node.path,
                    analysis    = node.sourceAnalysis,
                    source      = node.source,
                    unavailable = node.sourceAnalysis.unavailable,
                })
            end
        end
    end
    table.sort(moduleIndex, function(a, b)
        return (a.analysis.lineCount or 0) > (b.analysis.lineCount or 0)
    end)

    -- Value schema: all value objects with current values
    local valueSchema = {}
    for _, svcNodes in pairs(serviceMap) do
        for _, node in ipairs(svcNodes) do
            if node.interestType == "VALUE" and node.value ~= nil then
                table.insert(valueSchema, {
                    name    = node.name,
                    path    = node.path,
                    class   = node.className,
                    value   = tostring(node.value):sub(1,100),
                    service = node.service,
                })
            end
        end
    end

    -- Config folders
    local configFolders = {}
    for _, svcNodes in pairs(serviceMap) do
        for _, node in ipairs(svcNodes) do
            if node.className == "Configuration" then
                table.insert(configFolders, {
                    name     = node.name,
                    path     = node.path,
                    children = node.childCount,
                    service  = node.service,
                    attrs    = node.attributes,
                })
            end
        end
    end

    -- Service summary
    local serviceSummary = {}
    for svcName, nodes in pairs(serviceMap) do
        local classCounts = {}
        for _, node in ipairs(nodes) do
            classCounts[node.className] = (classCounts[node.className] or 0) + 1
        end
        serviceSummary[svcName] = {
            totalInstances = #nodes,
            classCounts    = classCounts,
        }
    end

    -- Topology stats
    local totalInstances = 0
    for _, nodes in pairs(serviceMap) do totalInstances = totalInstances + #nodes end

    return {
        version         = STS.VERSION,
        scannedAt       = os.clock(),
        totalInstances  = totalInstances,
        totalRemotes    = #sortedRemotes,
        totalModules    = #moduleIndex,
        totalValues     = #valueSchema,
        totalConfigs    = #configFolders,
        serviceMap      = serviceMap,
        serviceSummary  = serviceSummary,
        remoteCatalog   = remoteCatalog,
        sortedRemotes   = sortedRemotes,
        moduleIndex     = moduleIndex,
        valueSchema     = valueSchema,
        configFolders   = configFolders,
    }
end

-- ── SCAN ──────────────────────────────────────────────────────────────────────
function STS.Scan()
    if STS.ScanState == "SCANNING" then
        return false, "Scan already in progress."
    end

    -- Bedrock gate
    local ASE = _G.PC and _G.PC.ASE
    if not ASE then
        return false, "ASE not loaded."
    end
    local stats = ASE.GetStats and ASE.GetStats()
    if not stats or not stats.HeartbeatAlive then
        return false, "Bedrock pipeline not confirmed. Establish a handshake first."
    end

    STS.ScanState = "SCANNING"
    STS.Report    = nil

    task.spawn(function()
        local ok, err = pcall(function()
            local serviceMap  = {}
            local allRemotes  = {}
            local totalSvcs   = #STS.SCAN_SERVICES
            local instanceCount = {n=0}

            -- Phase 1 + 2: Walk all services (fresh cap per service)
            for i, svcEntry in ipairs(STS.SCAN_SERVICES) do
                notify(1, svcEntry.name, i, totalSvcs)
                local nodes = walkService(svcEntry, allRemotes, {n=0})
                serviceMap[svcEntry.name] = nodes
                instanceCount.n = instanceCount.n + #nodes
                -- Yield to avoid frame budget exhaustion
                task.wait()
            end

            -- Also walk character if present
            local char = Players.LocalPlayer and Players.LocalPlayer.Character
            if char then
                notify(1, "Character", totalSvcs, totalSvcs)
                local charEntry = { name="Character", svc=char, priority=99 }
                local charNodes = walkService(charEntry, allRemotes, {n=0})
                serviceMap["Character"] = charNodes
                instanceCount.n = instanceCount.n + #charNodes
            end

            -- Phase 3: Intelligence synthesis
            notify(2, "Synthesizing", 0, #allRemotes)
            local report = synthesize(serviceMap, allRemotes)
            task.wait()

            notify(3, "Complete", report.totalInstances, report.totalInstances)
            STS.Report    = report
            STS.ScanState = "COMPLETE"

            -- Export to _G for external access
            _G.PC.STS_Report = report

            print(string.format(
                "[STS] Scan complete — %d instances, %d remotes, %d modules, %d values",
                report.totalInstances, report.totalRemotes,
                report.totalModules, report.totalValues))

            if STS.OnComplete then
                pcall(STS.OnComplete, report)
            end
        end)

        if not ok then
            STS.ScanState = "ERROR"
            warn("[STS] Scan error: " .. tostring(err))
            if STS.OnProgress then
                pcall(STS.OnProgress, -1, "ERROR: " .. tostring(err):sub(1,80), 0, 0)
            end
        end
    end)

    return true, nil
end

-- ── EXPORT ────────────────────────────────────────────────────────────────────
-- Serializes the report into a human-readable string for clipboard export.
function STS.Export(format)
    local report = STS.Report
    if not report then return nil, "No report available." end

    format = format or "SUMMARY"

    if format == "SUMMARY" then
        local lines = {}
        table.insert(lines, string.format(
            "═══ PaperCuts STS Report ═══\nScanned: %.1fs ago  |  Instances: %d  |  Remotes: %d  |  Modules: %d  |  Values: %d\n",
            os.clock() - (report.scannedAt or 0),
            report.totalInstances, report.totalRemotes,
            report.totalModules, report.totalValues))

        -- Service summary
        table.insert(lines, "── Services ──")
        for svcName, summary in pairs(report.serviceSummary) do
            table.insert(lines, string.format("  %-22s  %d instances", svcName, summary.totalInstances))
        end

        -- Top remotes by intel score
        table.insert(lines, "\n── Top Remotes by Intel Score ──")
        local shown = 0
        for _, entry in ipairs(report.sortedRemotes) do
            if shown >= 20 then break end
            local conf = entry.sbiConf and string.format("conf=%.0f%%", entry.sbiConf*100) or "conf=?"
            local bp   = entry.bedrockPair and " ◈BEDROCK" or ""
            table.insert(lines, string.format(
                "  [%.2f] %-28s  %-8s  %s%s",
                entry.intelScore or 0,
                entry.name:sub(1,28),
                entry.className,
                conf, bp))
            shown = shown + 1
        end

        -- Module index
        if #report.moduleIndex > 0 then
            table.insert(lines, "\n── Module Scripts ──")
            for _, mod in ipairs(report.moduleIndex) do
                local a = mod.analysis
                table.insert(lines, string.format(
                    "  %-28s  %d lines  %d fn  %d remotes  path: %s",
                    mod.name:sub(1,28), a.lineCount or 0,
                    #a.functions, #a.remoteRefs,
                    mod.path:sub(1,60)))
                if #a.datastoreRefs > 0 then
                    table.insert(lines, string.format(
                        "    DataStores: %s", table.concat(a.datastoreRefs, ", "):sub(1,80)))
                end
                if #a.httpRefs > 0 then
                    table.insert(lines, string.format(
                        "    HTTP: %s", table.concat(a.httpRefs, ", "):sub(1,80)))
                end
            end
        end

        -- Value schema (first 30)
        if #report.valueSchema > 0 then
            table.insert(lines, "\n── Value Objects ──")
            local vshown = 0
            for _, v in ipairs(report.valueSchema) do
                if vshown >= 30 then break end
                table.insert(lines, string.format(
                    "  %-20s  %-16s  = %s",
                    v.name:sub(1,20), v.class, tostring(v.value):sub(1,40)))
                vshown = vshown + 1
            end
        end

        return table.concat(lines, "\n"), nil

    elseif format == "REMOTES" then
        local lines = {"═══ STS Remote Catalog ═══\n"}
        for _, entry in ipairs(report.sortedRemotes) do
            table.insert(lines, string.format("[%.2f] %s (%s)  path=%s",
                entry.intelScore or 0, entry.name, entry.className, entry.path))
            if entry.rsmSig then
                table.insert(lines, string.format(
                    "  RSM: fires=%d  success=%.0f%%  args=%d",
                    entry.rsmSig.fireCount, (entry.rsmSig.successRate or 0)*100,
                    entry.rsmSig.argCount))
            end
            if entry.sbiConf then
                table.insert(lines, string.format("  SBI: conf=%.0f%%", entry.sbiConf*100))
            end
            if entry.cdgEdges and #entry.cdgEdges > 0 then
                for _, e in ipairs(entry.cdgEdges) do
                    table.insert(lines, string.format(
                        "  CDG: ante=%-20s  conf=%.2f  coFired=%d",
                        e.ante, e.conf or 0, e.coFired or 0))
                end
            end
            if entry.bedrockPair then
                table.insert(lines, string.format(
                    "  BEDROCK: sink=%s  feedback=%s  origin=%s  conf=%.0f%%",
                    entry.bedrockPair.sink, entry.bedrockPair.feedback,
                    entry.bedrockPair.origin, (entry.bedrockPair.conf or 0)*100))
            end
            table.insert(lines, "")
        end
        return table.concat(lines, "\n"), nil

    elseif format == "MODULES" then
        local lines = {"═══ STS Module Index ═══\n"}
        for _, mod in ipairs(report.moduleIndex) do
            local a = mod.analysis
            table.insert(lines, string.format("── %s  (%s)  %d lines ──",
                mod.name, mod.path, a.lineCount or 0))
            if #a.functions > 0 then
                table.insert(lines, "  Functions: " ..
                    table.concat(a.functions, ", "):sub(1,200))
            end
            if #a.remoteRefs > 0 then
                table.insert(lines, "  RemoteRefs: " ..
                    table.concat(a.remoteRefs, ", "):sub(1,200))
            end
            if #a.datastoreRefs > 0 then
                table.insert(lines, "  DataStores: " ..
                    table.concat(a.datastoreRefs, ", "):sub(1,200))
            end
            if #a.httpRefs > 0 then
                table.insert(lines, "  HTTP: " ..
                    table.concat(a.httpRefs, ", "):sub(1,200))
            end
            if #a.requireChain > 0 then
                table.insert(lines, "  require(): " ..
                    table.concat(a.requireChain, ", "):sub(1,200))
            end
            if #a.globalWrites > 0 then
                table.insert(lines, "  _G writes: " ..
                    table.concat(a.globalWrites, ", "):sub(1,100))
            end
            if #a.suspiciousKeys > 0 then
                table.insert(lines, "  ⚠ Suspicious: " ..
                    table.concat(a.suspiciousKeys, ", "):sub(1,200))
            end
            table.insert(lines, "")
        end
        return table.concat(lines, "\n"), nil
    end

    return nil, "Unknown format: " .. tostring(format)
end

-- ── QUERY ─────────────────────────────────────────────────────────────────────
-- Quick lookup helpers for use by AACG and other systems.
function STS.GetRemote(name)
    if not STS.Report then return nil end
    return STS.Report.remoteCatalog[name]
end

function STS.GetModule(name)
    if not STS.Report then return nil end
    for _, mod in ipairs(STS.Report.moduleIndex) do
        if mod.name == name then return mod end
    end
    return nil
end

function STS.GetValues(service)
    if not STS.Report then return {} end
    local out = {}
    for _, v in ipairs(STS.Report.valueSchema) do
        if not service or v.service == service then
            table.insert(out, v)
        end
    end
    return out
end

function STS.GetStats()
    if not STS.Report then
        return {
            state         = STS.ScanState,
            totalInstances= 0,
            totalRemotes  = 0,
            totalModules  = 0,
            totalValues   = 0,
        }
    end
    return {
        state          = STS.ScanState,
        totalInstances = STS.Report.totalInstances,
        totalRemotes   = STS.Report.totalRemotes,
        totalModules   = STS.Report.totalModules,
        totalValues    = STS.Report.totalValues,
        totalConfigs   = STS.Report.totalConfigs,
        scannedAt      = STS.Report.scannedAt,
    }
end

-- ── Export ────────────────────────────────────────────────────────────────────
_G.PC = _G.PC or {}
_G.PC.STS = STS
print("[STS] Server Topology Scanner ready.")
