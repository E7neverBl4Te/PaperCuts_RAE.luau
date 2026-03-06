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
    ScanRoots         = { ReplicatedStorage, Workspace },
    ScanDepthLimit    = 8,
    MaxTrackedRemotes = 256,
    MaxArgSamples     = 32,
    MaxArgPositions   = 16,
    StringSampleCap   = 12,
    DeltaCap          = 64,
    SeqLogCap         = 512,
    CoFireWindowSec   = 0.25,
    MinCoFireCount    = 3,
    MaxPredecessors   = 8,
    PeriodicCVThresh  = 0.18,
    BurstGapRatio     = 4.0,
    RareFireCap       = 5,
    ProbeEnabled      = false,
    ProbeRateLimit    = 0.8,
    ProbeMaxPerRemote = 6,
    ProbeSafeRE       = true,
    PersistEnabled    = true,
    PersistKey        = "PR_Manifest_" .. tostring(game.PlaceId),
    BridgePollSec     = 8.0,
    ShowPanel         = true,
    PanelRefreshSec   = 3.0,
}

-- ── PR Core State ─────────────────────────────────────────────
local PR_Registry  = {}   -- [remoteName] = RemoteRecord
local PR_SeqLog    = {}   -- ring buffer: {name, dir, t, argCount}
local PR_SeqLogPtr = 0
local PR_DepEdges  = {}   -- [fromName][toName] = {count, totalDelay, minDelay, maxDelay}
local PR_Manifest  = {}
local PR_Hooks_PR  = {}   -- connection cleanup list (named to avoid collision)
local PR_LastProbe = 0
local PR_Started   = false

-- ── Record constructor ────────────────────────────────────────
local function PR_NewRecord(name, remote, path, remoteType)
    return {
        Name=name, Remote=remote, Path=path or remote:GetFullName(),
        RemoteType=remoteType or "RemoteEvent",
        FireCount=0, S2CCount=0, C2SCount=0, LastFireTime=0,
        Deltas={}, DeltaPtr=0, Direction="UNKNOWN",
        ArgSchema={},
        ArgCountMin=math.huge, ArgCountMax=0, ArgCountSum=0, ArgCountSamples=0,
        FreqClass="UNKNOWN", AvgHz=0, AvgDeltaSec=0, DeltaCV=0,
        ProbeResults={}, Predecessors={}, Successors={},
        EchoRelevance=0, PayloadScore=0, DepImportance=0,
        FirstSeen=os.clock(), LastSeen=os.clock(),
    }
end

-- ── Arg slot constructor ──────────────────────────────────────
local function PR_NewArgSlot()
    return {
        TypeFreq={}, DominantType="unknown", Nullable=false,
        Samples={}, StringSet={},
        NumberMin=math.huge, NumberMax=-math.huge,
        NumberSum=0, NumberCount=0,
        IsEnum=false, TotalCount=0,
    }
end

-- ============================================================
-- SCHEMA INFERENCER
-- ============================================================
local PR_SchemaInfer = {}

function PR_SchemaInfer.InferType(v)
    if v == nil then return "nil" end
    local t = typeof(v)
    if t == "number"    then return "number"    end
    if t == "string"    then return "string"    end
    if t == "boolean"   then return "boolean"   end
    if t == "table"     then return "table"     end
    if t == "function"  then return "function"  end
    if t == "Vector3"   then return "Vector3"   end
    if t == "Vector2"   then return "Vector2"   end
    if t == "CFrame"    then return "CFrame"    end
    if t == "Color3"    then return "Color3"    end
    if t == "UDim2"     then return "UDim2"     end
    if t == "EnumItem"  then return "EnumItem"  end
    if t == "BrickColor" then return "BrickColor" end
    if t == "Instance"  then
        local ok, cn = pcall(function() return v.ClassName end)
        return ok and ("Instance:"..cn) or "Instance:?"
    end
    return t
end

function PR_SchemaInfer.UpdateSlot(slot, v)
    slot.TotalCount = slot.TotalCount + 1
    local typeName = PR_SchemaInfer.InferType(v)
    slot.TypeFreq[typeName] = (slot.TypeFreq[typeName] or 0) + 1
    if v == nil then slot.Nullable = true; return end
    if #slot.Samples < PR_CFG.MaxArgSamples then
        table.insert(slot.Samples, v)
    end
    if typeName == "number" then
        slot.NumberMin   = math.min(slot.NumberMin, v)
        slot.NumberMax   = math.max(slot.NumberMax, v)
        slot.NumberSum   = slot.NumberSum + v
        slot.NumberCount = slot.NumberCount + 1
    elseif typeName == "string" then
        if not slot.StringSet[v] then
            local setSize = 0
            for _ in pairs(slot.StringSet) do setSize = setSize + 1 end
            if setSize < PR_CFG.StringSampleCap then
                slot.StringSet[v] = 1
            end
        else
            slot.StringSet[v] = slot.StringSet[v] + 1
        end
    end
end

function PR_SchemaInfer.FinalizeSlot(slot)
    local bestType, bestCount = "unknown", 0
    for t, c in pairs(slot.TypeFreq) do
        if c > bestCount then bestType = t; bestCount = c end
    end
    slot.DominantType = bestType
    if bestType == "string" then
        local setSize = 0
        for _ in pairs(slot.StringSet) do setSize = setSize + 1 end
        slot.IsEnum = (setSize > 0 and setSize <= 8)
    end
    if slot.NumberCount > 0 then
        slot.NumberAvg = slot.NumberSum / slot.NumberCount
    end
end

function PR_SchemaInfer.UpdateRecord(record, args)
    local n = #args
    record.ArgCountSamples = record.ArgCountSamples + 1
    record.ArgCountMin     = math.min(record.ArgCountMin, n)
    record.ArgCountMax     = math.max(record.ArgCountMax, n)
    record.ArgCountSum     = record.ArgCountSum + n
    local cap = math.min(n, PR_CFG.MaxArgPositions)
    for i = 1, cap do
        if not record.ArgSchema[i] then record.ArgSchema[i] = PR_NewArgSlot() end
        PR_SchemaInfer.UpdateSlot(record.ArgSchema[i], args[i])
    end
    for i = n + 1, #record.ArgSchema do
        record.ArgSchema[i].Nullable = true
    end
end

function PR_SchemaInfer.GetSchemaStr(record)
    if #record.ArgSchema == 0 then return "(no args observed)" end
    local parts = {}
    for i, slot in ipairs(record.ArgSchema) do
        PR_SchemaInfer.FinalizeSlot(slot)
        local s = slot.DominantType
        if slot.IsEnum then
            local keys = {}
            for k in pairs(slot.StringSet) do table.insert(keys, k) end
            s = "enum{" .. table.concat(keys, "|") .. "}"
        elseif s == "number" and slot.NumberCount > 1 then
            s = string.format("number[%.1f\226\128\147%.1f]", slot.NumberMin, slot.NumberMax)
        end
        if slot.Nullable then s = s .. "?" end
        table.insert(parts, string.format("[%d]%s", i, s))
    end
    return table.concat(parts, ", ")
end

-- ============================================================
-- FREQUENCY PROFILER
-- ============================================================
local PR_FreqProfiler = {}

function PR_FreqProfiler.RecordDelta(record, t)
    if record.LastFireTime > 0 then
        local delta = t - record.LastFireTime
        if delta > 0 and delta < 300 then
            record.DeltaPtr = record.DeltaPtr + 1
            if record.DeltaPtr > PR_CFG.DeltaCap then record.DeltaPtr = 1 end
            record.Deltas[record.DeltaPtr] = delta
        end
    end
end

function PR_FreqProfiler.Classify(record)
    local n = #record.Deltas
    if record.FireCount < PR_CFG.RareFireCap then record.FreqClass = "RARE"; return end
    if n < 3 then record.FreqClass = "EVENT"; return end
    local sum, sumSq = 0, 0
    local dMin, dMax = math.huge, -math.huge
    for _, d in ipairs(record.Deltas) do
        sum = sum + d; sumSq = sumSq + d*d
        dMin = math.min(dMin, d); dMax = math.max(dMax, d)
    end
    local mean     = sum / n
    local variance = (sumSq / n) - (mean * mean)
    local stddev   = variance > 0 and math.sqrt(variance) or 0
    local cv       = mean > 0 and (stddev / mean) or 1
    record.AvgDeltaSec = mean
    record.AvgHz       = mean > 0 and (1 / mean) or 0
    record.DeltaCV     = cv
    if cv < PR_CFG.PeriodicCVThresh then
        record.FreqClass = "PERIODIC"
    elseif dMax / math.max(mean, 0.001) > PR_CFG.BurstGapRatio then
        record.FreqClass = "BURST"
    else
        record.FreqClass = "EVENT"
    end
end

-- ============================================================
-- SEQUENCE ANALYZER
-- ============================================================
local PR_SeqAnalyzer = {}

function PR_SeqAnalyzer.Record(name, dir, t, argCount)
    PR_SeqLogPtr = PR_SeqLogPtr + 1
    if PR_SeqLogPtr > PR_CFG.SeqLogCap then PR_SeqLogPtr = 1 end
    PR_SeqLog[PR_SeqLogPtr] = { name=name, dir=dir, t=t, argc=argCount }
end

function PR_SeqAnalyzer.UpdateEdges(targetName, targetTime)
    local window = PR_CFG.CoFireWindowSec
    local ptr    = PR_SeqLogPtr - 1
    local count  = 0
    while count < PR_CFG.SeqLogCap do
        if ptr < 1 then ptr = PR_CFG.SeqLogCap end
        local entry = PR_SeqLog[ptr]
        if not entry then break end
        local age = targetTime - entry.t
        if age > window then break end
        if entry.name ~= targetName and age > 0 then
            local from = entry.name
            if not PR_DepEdges[from] then PR_DepEdges[from] = {} end
            if not PR_DepEdges[from][targetName] then
                PR_DepEdges[from][targetName] = {
                    count=0, totalDelay=0, minDelay=math.huge, maxDelay=0
                }
            end
            local edge = PR_DepEdges[from][targetName]
            edge.count      = edge.count + 1
            edge.totalDelay = edge.totalDelay + age
            edge.minDelay   = math.min(edge.minDelay, age)
            edge.maxDelay   = math.max(edge.maxDelay, age)
        end
        ptr = ptr - 1; count = count + 1
    end
end

function PR_SeqAnalyzer.FlushEdges()
    for fromName, targets in pairs(PR_DepEdges) do
        for toName, edge in pairs(targets) do
            if edge.count >= PR_CFG.MinCoFireCount then
                local fromRec = PR_Registry[fromName]
                local toRec   = PR_Registry[toName]
                if fromRec and toRec then
                    fromRec.Successors[toName] = {
                        count=edge.count,
                        avgDelay=edge.totalDelay/edge.count,
                        minDelay=edge.minDelay, maxDelay=edge.maxDelay,
                    }
                    local predCount = 0
                    for _ in pairs(toRec.Predecessors) do predCount = predCount + 1 end
                    if predCount < PR_CFG.MaxPredecessors then
                        toRec.Predecessors[fromName] = {
                            count=edge.count,
                            avgDelay=edge.totalDelay/edge.count,
                        }
                    end
                end
            end
        end
    end
end

-- ============================================================
-- DEPENDENCY GRAPH
-- ============================================================
local PR_DepGraph = {}

function PR_DepGraph.GetEntryPoints()
    local entries = {}
    for name, rec in pairs(PR_Registry) do
        local predCount = 0
        for _ in pairs(rec.Predecessors) do predCount = predCount + 1 end
        if predCount == 0 and rec.FireCount > 0 then
            table.insert(entries, { Name=name, Record=rec, FireCount=rec.FireCount })
        end
    end
    table.sort(entries, function(a, b) return a.FireCount > b.FireCount end)
    return entries
end

function PR_DepGraph.GetChain(startName, visited, depth)
    visited = visited or {}; depth = depth or 0
    if depth > 10 or visited[startName] then return {} end
    visited[startName] = true
    local rec = PR_Registry[startName]
    if not rec then return {} end
    local chain = { startName }
    local bestSucc, bestCount = nil, 0
    for succName, edge in pairs(rec.Successors) do
        if edge.count > bestCount then bestSucc=succName; bestCount=edge.count end
    end
    if bestSucc then
        local rest = PR_DepGraph.GetChain(bestSucc, visited, depth + 1)
        for _, n in ipairs(rest) do table.insert(chain, n) end
    end
    return chain
end

function PR_DepGraph.GetImportanceScore(record)
    local score = 0
    for _, edge in pairs(record.Successors) do
        score = score + math.log(1 + edge.count) * (1 / math.max(edge.avgDelay, 0.001))
    end
    return score
end

-- ============================================================
-- INTERCEPTOR
-- ============================================================
local PR_Interceptor = {}

function PR_Interceptor.OnFire(name, direction, args, t)
    local rec = PR_Registry[name]
    if not rec then return end
    rec.FireCount = rec.FireCount + 1
    rec.LastSeen  = t
    if direction == "S2C" then
        rec.S2CCount = rec.S2CCount + 1
        if rec.Direction == "UNKNOWN" then rec.Direction = "S2C"
        elseif rec.Direction == "C2S"  then rec.Direction = "BOTH" end
    elseif direction == "C2S" then
        rec.C2SCount = rec.C2SCount + 1
        if rec.Direction == "UNKNOWN" then rec.Direction = "C2S"
        elseif rec.Direction == "S2C"  then rec.Direction = "BOTH" end
    end
    PR_SchemaInfer.UpdateRecord(rec, args)
    PR_FreqProfiler.RecordDelta(rec, t)
    rec.LastFireTime = t
    if rec.FireCount % 8 == 0 then PR_FreqProfiler.Classify(rec) end
    PR_SeqAnalyzer.Record(name, direction, t, #args)
    PR_SeqAnalyzer.UpdateEdges(name, t)
end

function PR_Interceptor.HookIncoming(rec)
    if rec.RemoteType ~= "RemoteEvent" then return end
    local ok, conn = pcall(function()
        return rec.Remote.OnClientEvent:Connect(function(...)
            PR_Interceptor.OnFire(rec.Name, "S2C", {...}, os.clock())
        end)
    end)
    if ok and conn then table.insert(PR_Hooks_PR, conn) end
end

function PR_Interceptor.HookOutgoing()
    if not (getrawmetatable and setreadonly and getnamecallmethod) then
        warn("[PR] C2S hook unavailable — executor missing getrawmetatable/getnamecallmethod")
        return false
    end
    local ok, err = pcall(function()
        local mt  = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")  -- use rawget so nil is valid
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" or method == "InvokeServer" then
                local name
                local nameOk = pcall(function() name = self.Name end)
                if nameOk and name and PR_Registry[name] then
                    PR_Interceptor.OnFire(name, "C2S", {...}, os.clock())
                end
            end
            -- Guard: only call oldNC if it exists and is callable
            if oldNC then
                return oldNC(self, ...)
            end
        end
        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then warn("[PR] C2S hook failed: " .. tostring(err)); return false end
    return true
end

function PR_Interceptor.ScanRoots()
    local discovered = 0
    local queue = {}
    for _, root in ipairs(PR_CFG.ScanRoots) do
        table.insert(queue, { node=root, depth=0 })
    end
    local qi = 1
    while qi <= #queue do
        local item = queue[qi]; qi = qi + 1
        if item.depth <= PR_CFG.ScanDepthLimit then
            local ok, children = pcall(function() return item.node:GetChildren() end)
            if ok then
                for _, child in ipairs(children) do
                    local cls = child.ClassName
                    if cls == "RemoteEvent" or cls == "RemoteFunction" then
                        local name = child.Name
                        if not PR_Registry[name] and discovered < PR_CFG.MaxTrackedRemotes then
                            local rec = PR_NewRecord(name, child, child:GetFullName(), cls)
                            PR_Registry[name] = rec
                            PR_Interceptor.HookIncoming(rec)
                            discovered = discovered + 1
                        end
                    end
                    table.insert(queue, { node=child, depth=item.depth + 1 })
                end
            end
        end
        if qi % 200 == 0 then task.wait() end
    end
    return discovered
end

function PR_Interceptor.WatchForNew()
    for _, root in ipairs(PR_CFG.ScanRoots) do
        local conn = root.DescendantAdded:Connect(function(desc)
            local cls = desc.ClassName
            if cls == "RemoteEvent" or cls == "RemoteFunction" then
                local name = desc.Name
                if not PR_Registry[name] then
                    local rec = PR_NewRecord(name, desc, desc:GetFullName(), cls)
                    PR_Registry[name] = rec
                    PR_Interceptor.HookIncoming(rec)
                end
            end
        end)
        table.insert(PR_Hooks_PR, conn)
    end
end

-- ============================================================
-- ACTIVE PROBER
-- ============================================================
local PR_ActiveProber = {}

function PR_ActiveProber.GenPermutations(record)
    local perms = {}
    local schema = record.ArgSchema
    if #schema == 0 then table.insert(perms, {}); return perms end
    local baseline = {}
    for i, slot in ipairs(schema) do
        PR_SchemaInfer.FinalizeSlot(slot)
        local dt = slot.DominantType
        if dt == "number" then baseline[i] = slot.NumberAvg or 0
        elseif dt == "string" then
            baseline[i] = next(slot.StringSet) or ""
        elseif dt == "boolean" then baseline[i] = true
        else baseline[i] = nil end
    end
    table.insert(perms, baseline)
    for i = 1, math.min(#schema, 4) do
        if not schema[i].Nullable then
            local perm = {}
            for j, v in ipairs(baseline) do perm[j] = v end
            perm[i] = nil
            table.insert(perms, perm)
            if #perms >= PR_CFG.ProbeMaxPerRemote then break end
        end
    end
    for i, slot in ipairs(schema) do
        if #perms >= PR_CFG.ProbeMaxPerRemote then break end
        local perm = {}
        for j, v in ipairs(baseline) do perm[j] = v end
        if slot.DominantType == "number" then perm[i] = "pr_probe"
        elseif slot.DominantType == "string" then perm[i] = 0 end
        table.insert(perms, perm)
    end
    return perms
end

function PR_ActiveProber.ProbeRemote(name)
    if not PR_CFG.ProbeEnabled then return end
    local now = os.clock()
    if now - PR_LastProbe < PR_CFG.ProbeRateLimit then return end
    PR_LastProbe = now
    local rec = PR_Registry[name]
    if not rec then return end
    if PR_CFG.ProbeSafeRE and rec.C2SCount == 0 then return end
    if rec.RemoteType ~= "RemoteEvent" then return end
    local perms = PR_ActiveProber.GenPermutations(rec)
    for _, args in ipairs(perms) do
        task.spawn(function()
            local outcome = "ok"
            local ok, err = pcall(function() rec.Remote:FireServer(table.unpack(args)) end)
            if not ok then outcome = "error:" .. tostring(err):sub(1, 60) end
            table.insert(rec.ProbeResults, { args=args, outcome=outcome, t=os.clock() })
            if #rec.ProbeResults > 32 then table.remove(rec.ProbeResults, 1) end
        end)
        task.wait(0.1)
    end
end

function PR_ActiveProber.SweepTopCandidates(n)
    if not PR_CFG.ProbeEnabled then return end
    n = n or 5
    local candidates = {}
    for name, rec in pairs(PR_Registry) do
        if rec.C2SCount > 0 and rec.RemoteType == "RemoteEvent" then
            table.insert(candidates, { Name=name, Score=rec.C2SCount })
        end
    end
    table.sort(candidates, function(a, b) return a.Score > b.Score end)
    for i = 1, math.min(n, #candidates) do
        task.spawn(function()
            task.wait((i-1) * 1.5)
            PR_ActiveProber.ProbeRemote(candidates[i].Name)
        end)
    end
end

-- ============================================================
-- MANIFEST BUILDER
-- ============================================================
local PR_ManifestBuilder = {}

function PR_ManifestBuilder.Rebuild()
    PR_SeqAnalyzer.FlushEdges()
    local manifest = {
        PlaceId      = tostring(game.PlaceId),
        BuiltAt      = os.clock(),
        TotalRemotes = 0,
        ByFreqClass  = { PERIODIC={}, BURST={}, EVENT={}, RARE={}, UNKNOWN={} },
        ByDirection  = { S2C={}, C2S={}, BOTH={}, UNKNOWN={} },
        EntryPoints  = PR_DepGraph.GetEntryPoints(),
        TopByFires   = {},
        TopByPayload = {},
        DepChains    = {},
        Remotes      = {},
    }
    for name, rec in pairs(PR_Registry) do
        PR_FreqProfiler.Classify(rec)
        for _, slot in ipairs(rec.ArgSchema) do PR_SchemaInfer.FinalizeSlot(slot) end
        rec.DepImportance = PR_DepGraph.GetImportanceScore(rec)
        -- EchoRelevance: stable periodic S2C remotes are best for timing calibration
        local echoScore = 0
        if rec.FreqClass == "PERIODIC" and rec.S2CCount > 0 then
            echoScore = math.clamp(1 - rec.DeltaCV, 0, 1)
        end
        rec.EchoRelevance = echoScore
        -- PayloadScore: C2S remotes with string args make good carriers
        local payScore = 0
        if rec.C2SCount > 2 then
            for _, slot in ipairs(rec.ArgSchema) do
                if slot.DominantType == "string" then payScore = payScore + 0.3 end
            end
            payScore = math.clamp(payScore, 0, 1)
        end
        rec.PayloadScore = payScore
        manifest.TotalRemotes = manifest.TotalRemotes + 1
        if manifest.ByFreqClass[rec.FreqClass] then
            table.insert(manifest.ByFreqClass[rec.FreqClass], name)
        end
        if manifest.ByDirection[rec.Direction] then
            table.insert(manifest.ByDirection[rec.Direction], name)
        end
        local predCount, succCount = 0, 0
        for _ in pairs(rec.Predecessors) do predCount = predCount + 1 end
        for _ in pairs(rec.Successors)   do succCount  = succCount  + 1 end
        manifest.Remotes[name] = {
            Path=rec.Path, Type=rec.RemoteType, Direction=rec.Direction,
            FireCount=rec.FireCount, S2CCount=rec.S2CCount, C2SCount=rec.C2SCount,
            FreqClass=rec.FreqClass, AvgHz=rec.AvgHz, DeltaCV=rec.DeltaCV,
            ArgCountMin=rec.ArgCountMin, ArgCountMax=rec.ArgCountMax,
            SchemaStr=PR_SchemaInfer.GetSchemaStr(rec),
            EchoRelevance=rec.EchoRelevance, PayloadScore=rec.PayloadScore,
            DepImportance=rec.DepImportance, PredCount=predCount, SuccCount=succCount,
        }
    end
    local byFires = {}
    for name, rec in pairs(PR_Registry) do
        table.insert(byFires, { name=name, fires=rec.FireCount })
    end
    table.sort(byFires, function(a, b) return a.fires > b.fires end)
    for i = 1, math.min(10, #byFires) do table.insert(manifest.TopByFires, byFires[i]) end
    local byPayload = {}
    for name, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0 then
            table.insert(byPayload, { name=name, score=rec.PayloadScore })
        end
    end
    table.sort(byPayload, function(a, b) return a.score > b.score end)
    for i = 1, math.min(10, #byPayload) do table.insert(manifest.TopByPayload, byPayload[i]) end
    for _, ep in ipairs(manifest.EntryPoints) do
        local chain = PR_DepGraph.GetChain(ep.Name)
        if #chain > 1 then table.insert(manifest.DepChains, chain) end
        if #manifest.DepChains >= 8 then break end
    end
    PR_Manifest = manifest
    return manifest
end

-- ============================================================
-- PERSISTENCE
-- ============================================================
local PR_Persist = {}

function PR_Persist.Serialize()
    local data = { version="PR_v1", placeId=tostring(game.PlaceId), savedAt=os.clock(), remotes={} }
    for name, rec in pairs(PR_Registry) do
        local schema = {}
        for i, slot in ipairs(rec.ArgSchema) do
            PR_SchemaInfer.FinalizeSlot(slot)
            schema[i] = {
                DominantType=slot.DominantType, Nullable=slot.Nullable,
                IsEnum=slot.IsEnum, StringSet=slot.StringSet,
                NumberMin=slot.NumberMin~=math.huge and slot.NumberMin or nil,
                NumberMax=slot.NumberMax~=-math.huge and slot.NumberMax or nil,
                NumberAvg=slot.NumberAvg, TypeFreq=slot.TypeFreq,
                TotalCount=slot.TotalCount,
            }
        end
        local preds, succs = {}, {}
        for k, v in pairs(rec.Predecessors) do preds[k]={count=v.count,avgDelay=v.avgDelay} end
        for k, v in pairs(rec.Successors) do
            succs[k]={count=v.count,avgDelay=v.avgDelay,minDelay=v.minDelay,maxDelay=v.maxDelay}
        end
        data.remotes[name] = {
            Path=rec.Path, RemoteType=rec.RemoteType,
            FireCount=rec.FireCount, S2CCount=rec.S2CCount, C2SCount=rec.C2SCount,
            Direction=rec.Direction, FreqClass=rec.FreqClass,
            AvgHz=rec.AvgHz, DeltaCV=rec.DeltaCV,
            EchoRelevance=rec.EchoRelevance, PayloadScore=rec.PayloadScore,
            DepImportance=rec.DepImportance, ArgSchema=schema,
            Predecessors=preds, Successors=succs, FirstSeen=rec.FirstSeen,
        }
    end
    return data
end

function PR_Persist.Restore(data)
    if not data or data.version~="PR_v1" or data.placeId~=tostring(game.PlaceId) then return end
    for name, saved in pairs(data.remotes) do
        local rec = PR_Registry[name]
        if rec then
            rec.FireCount     = math.max(rec.FireCount, saved.FireCount)
            rec.S2CCount      = math.max(rec.S2CCount,  saved.S2CCount)
            rec.C2SCount      = math.max(rec.C2SCount,  saved.C2SCount)
            if rec.Direction == "UNKNOWN" then rec.Direction = saved.Direction end
            rec.FreqClass     = saved.FreqClass
            rec.AvgHz         = saved.AvgHz
            rec.DeltaCV       = saved.DeltaCV
            rec.EchoRelevance = saved.EchoRelevance
            rec.PayloadScore  = saved.PayloadScore
            rec.DepImportance = saved.DepImportance
            for i, savedSlot in ipairs(saved.ArgSchema or {}) do
                if not rec.ArgSchema[i] then rec.ArgSchema[i] = PR_NewArgSlot() end
                local slot = rec.ArgSchema[i]
                for t, c in pairs(savedSlot.TypeFreq or {}) do
                    slot.TypeFreq[t] = (slot.TypeFreq[t] or 0) + c
                end
                slot.TotalCount = slot.TotalCount + (savedSlot.TotalCount or 0)
                if savedSlot.Nullable then slot.Nullable = true end
                if savedSlot.IsEnum   then slot.IsEnum   = true end
                for k, v in pairs(savedSlot.StringSet or {}) do
                    slot.StringSet[k] = (slot.StringSet[k] or 0) + v
                end
                if savedSlot.NumberMin then
                    slot.NumberMin = math.min(slot.NumberMin, savedSlot.NumberMin)
                end
                if savedSlot.NumberMax then
                    slot.NumberMax = math.max(slot.NumberMax, savedSlot.NumberMax)
                end
                PR_SchemaInfer.FinalizeSlot(slot)
            end
            for pred, edge in pairs(saved.Predecessors or {}) do
                rec.Predecessors[pred] = rec.Predecessors[pred] or edge
            end
            for succ, edge in pairs(saved.Successors or {}) do
                rec.Successors[succ] = rec.Successors[succ] or edge
            end
        end
    end
end

function PR_Persist.Save()
    if not PR_CFG.PersistEnabled then return end
    pcall(function() _G[PR_CFG.PersistKey] = PR_Persist.Serialize() end)
end

function PR_Persist.Load()
    if not PR_CFG.PersistEnabled then return end
    pcall(function()
        local saved = _G[PR_CFG.PersistKey]
        if saved then PR_Persist.Restore(saved) end
    end)
end

-- ============================================================
-- BRIDGE — integration with ETM / CDG / LWM
-- ============================================================
local PR_Bridge = {}

function PR_Bridge.FeedETM()
    local topEcho = {}
    for name, rec in pairs(PR_Registry) do
        if rec.FreqClass == "PERIODIC" and rec.EchoRelevance > 0.4 then
            table.insert(topEcho, { name=name, score=rec.EchoRelevance })
        end
    end
    table.sort(topEcho, function(a, b) return a.score > b.score end)
    local echoCtx = ""
    for i = 1, math.min(3, #topEcho) do
        echoCtx = echoCtx .. "|PR_ECHO:" .. topEcho[i].name
    end
    local topPay = {}
    for name, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0.3 then
            table.insert(topPay, { name=name, score=rec.PayloadScore })
        end
    end
    table.sort(topPay, function(a, b) return a.score > b.score end)
    local payCtx = ""
    for i = 1, math.min(2, #topPay) do
        payCtx = payCtx .. "|PR_PAY:" .. topPay[i].name
    end
    _G.PR_ETM_CONTEXT = echoCtx .. payCtx
    -- Protocol health tracking through ETM
    local totalSeen, periodicCount = 0, 0
    for _, rec in pairs(PR_Registry) do
        totalSeen = totalSeen + 1
        if rec.FreqClass == "PERIODIC" then periodicCount = periodicCount + 1 end
    end
    local sig = string.format("n%d_p%d", totalSeen, periodicCount)
    ETM.Update("PR_ProtocolHealth", sig, totalSeen > 5 and periodicCount > 0)
end

function PR_Bridge.FeedCDG()
    for fromName, targets in pairs(PR_DepEdges) do
        for toName, edge in pairs(targets) do
            if edge.count >= PR_CFG.MinCoFireCount then
                local cdgEdge = CDG.GetOrInitEdge(fromName, toName)
                cdgEdge.confidence  = math.min(edge.count / 20.0, 1.0)
                local tightness     = math.exp(-(edge.totalDelay/math.max(edge.count,1)) / 0.1)
                cdgEdge.effectSize  = tightness * cdgEdge.confidence
                cdgEdge.coFired     = edge.count
                cdgEdge.lastUpdated = os.clock()
            end
        end
    end
end

function PR_Bridge.FeedLWM()
    local classCount = { PERIODIC=0, BURST=0, EVENT=0, RARE=0, UNKNOWN=0 }
    local c2sCount, s2cCount, payloadReady, total = 0, 0, 0, 0
    for _, rec in pairs(PR_Registry) do
        total = total + 1
        if classCount[rec.FreqClass] then classCount[rec.FreqClass] = classCount[rec.FreqClass] + 1 end
        if rec.C2SCount > 0 then c2sCount = c2sCount + 1 end
        if rec.S2CCount > 0 then s2cCount = s2cCount + 1 end
        if rec.PayloadScore > 0.4 then payloadReady = payloadReady + 1 end
    end
    _G.PR_LWM_INJECT = {
        pr_periodic   = classCount.PERIODIC,
        pr_burst      = classCount.BURST,
        pr_c2s        = c2sCount,
        pr_s2c        = s2cCount,
        pr_payloadRdy = payloadReady,
        pr_totalSeen  = total,
    }
end

function PR_Bridge.GetPayloadCandidates()
    local candidates = {}
    for name, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0.25 and rec.C2SCount > 0 then
            table.insert(candidates, {
                Name=name, Remote=rec.Remote, Path=rec.Path,
                PayloadScore=rec.PayloadScore,
                SchemaStr=PR_SchemaInfer.GetSchemaStr(rec),
                ArgSchema=rec.ArgSchema,
            })
        end
    end
    table.sort(candidates, function(a, b) return a.PayloadScore > b.PayloadScore end)
    return candidates
end

function PR_Bridge.GetBestEchoCalibrator()
    local best, bestScore = nil, -1
    for _, rec in pairs(PR_Registry) do
        if rec.EchoRelevance > bestScore then best=rec; bestScore=rec.EchoRelevance end
    end
    return best
end

function PR_Bridge.Sync()
    PR_ManifestBuilder.Rebuild()
    PR_Bridge.FeedETM()
    PR_Bridge.FeedCDG()
    PR_Bridge.FeedLWM()
    PR_Persist.Save()
end

-- ============================================================
-- ANALYTICS
-- ============================================================
local PR_Analytics = {}

function PR_Analytics.GetSummary()
    local m = PR_Manifest
    if not m or not m.Remotes then m = PR_ManifestBuilder.Rebuild() end
    return {
        TotalRemotes = m.TotalRemotes or 0,
        PERIODIC     = m.ByFreqClass and #(m.ByFreqClass.PERIODIC or {}) or 0,
        BURST        = m.ByFreqClass and #(m.ByFreqClass.BURST    or {}) or 0,
        EVENT        = m.ByFreqClass and #(m.ByFreqClass.EVENT    or {}) or 0,
        RARE         = m.ByFreqClass and #(m.ByFreqClass.RARE     or {}) or 0,
        C2S          = m.ByDirection and #(m.ByDirection.C2S      or {}) or 0,
        S2C          = m.ByDirection and #(m.ByDirection.S2C      or {}) or 0,
        BOTH         = m.ByDirection and #(m.ByDirection.BOTH     or {}) or 0,
        TopByFires   = m.TopByFires or {},
        TopByPayload = m.TopByPayload or {},
        EntryPoints  = m.EntryPoints or {},
        DepChains    = m.DepChains or {},
        BuiltAt      = m.BuiltAt,
    }
end

function PR_Analytics.GetReport()
    local s = PR_Analytics.GetSummary()
    local lines = {
        string.format("[PR] Protocol Manifest — PlaceId: %s", tostring(game.PlaceId)),
        string.format("  Remotes: %d  |  PERIODIC:%d  BURST:%d  EVENT:%d  RARE:%d",
            s.TotalRemotes, s.PERIODIC, s.BURST, s.EVENT, s.RARE),
        string.format("  Directions: S2C:%d  C2S:%d  BOTH:%d", s.S2C, s.C2S, s.BOTH),
    }
    if #s.TopByFires > 0 then
        table.insert(lines, "  Top by fires:")
        for i = 1, math.min(5, #s.TopByFires) do
            local e = s.TopByFires[i]
            table.insert(lines, string.format("    [%d] %s (%d)", i, e.name, e.fires))
        end
    end
    if #s.TopByPayload > 0 then
        table.insert(lines, "  Top payload carriers:")
        for i = 1, math.min(3, #s.TopByPayload) do
            local e = s.TopByPayload[i]
            table.insert(lines, string.format("    [%d] %s (%.2f)", i, e.name, e.score))
        end
    end
    if #s.DepChains > 0 then
        table.insert(lines, "  Dep chains:")
        for i = 1, math.min(3, #s.DepChains) do
            table.insert(lines, "    " .. table.concat(s.DepChains[i], " -> "))
        end
    end
    return table.concat(lines, "\n")
end

function PR_Analytics.Print() print(PR_Analytics.GetReport()) end

-- ============================================================
-- STATUS PANEL (inline, reuses existing mk/addCorner helpers)
-- ============================================================
local function PR_BuildPanel()
    if not PR_CFG.ShowPanel then return end
    pcall(function()
        local pg = player:WaitForChild("PlayerGui", 10)
        if not pg then return end
        local ex = pg:FindFirstChild("PR_Panel"); if ex then ex:Destroy() end
        local sg = mk("ScreenGui", { Name="PR_Panel", ResetOnSpawn=false,
            ZIndexBehavior=Enum.ZIndexBehavior.Sibling, DisplayOrder=998, Parent=pg })
        local frame = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(10,12,20),
            BackgroundTransparency=0.1, BorderSizePixel=0,
            Size=UDim2.new(0,272,0,185),
            Position=UDim2.new(1,-288,0,14), Parent=sg,
        })
        addCorner(frame, UDim.new(0,10))
        local stroke = mk("UIStroke", { Thickness=1, Color=Color3.fromRGB(70,130,255),
            Transparency=0.5, Parent=frame })
        mk("TextLabel", { BackgroundTransparency=1, Size=UDim2.new(1,0,0,22),
            Position=UDim2.new(0,0,0,4), Font=Enum.Font.GothamBold, TextSize=11,
            TextColor3=Color3.fromRGB(90,160,255),
            Text="  \226\151\136  PR — Protocol Reconstruction", Parent=frame })
        local body = mk("TextLabel", { Name="Body", BackgroundTransparency=1,
            Size=UDim2.new(1,-10,1,-30), Position=UDim2.new(0,5,0,28),
            Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(195,205,225),
            TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
            TextWrapped=true, Text="Initializing...", Parent=frame })
        -- Drag
        local dragging, dragStart, startPos = false, nil, nil
        frame.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging=true; dragStart=i.Position; startPos=frame.Position
            end
        end)
        frame.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging=false end
        end)
        game:GetService("UserInputService").InputChanged:Connect(function(i)
            if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
                local d = i.Position - dragStart
                frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X,
                    startPos.Y.Scale, startPos.Y.Offset+d.Y)
            end
        end)
        -- Refresh loop
        task.spawn(function()
            while sg and sg.Parent do
                local s = PR_Analytics.GetSummary()
                local elapsed = s.BuiltAt and string.format("%.0fs ago", os.clock()-s.BuiltAt) or "pending"
                local topFire = s.TopByFires[1] and
                    string.format("%s (%d)", s.TopByFires[1].name, s.TopByFires[1].fires) or "\226\128\148"
                local topPay  = s.TopByPayload[1] and
                    string.format("%s (%.2f)", s.TopByPayload[1].name, s.TopByPayload[1].score) or "\226\128\148"
                local chainStr = s.DepChains[1] and table.concat(s.DepChains[1],"->"):sub(1,30) or "\226\128\148"
                if body and body.Parent then
                    body.Text = table.concat({
                        string.format("Remotes: %d  (sync: %s)", s.TotalRemotes, elapsed),
                        string.format("PERIODIC:%-3d BURST:%-3d EVENT:%d", s.PERIODIC,s.BURST,s.EVENT),
                        string.format("S2C:%-4d C2S:%-4d BOTH:%d", s.S2C, s.C2S, s.BOTH),
                        "",
                        "Top fired: " .. topFire,
                        "Top pay:   " .. topPay,
                        "Dep chain: " .. chainStr,
                        string.format("Probe: %s", PR_CFG.ProbeEnabled and "ON" or "off"),
                    }, "\n")
                end
                task.wait(PR_CFG.PanelRefreshSec)
            end
        end)
    end)
end

-- ============================================================
-- PR — STARTUP SEQUENCE
-- ============================================================
local function PR_Start()
    if PR_Started then return end
    PR_Started = true
    task.spawn(function()
        local discovered = PR_Interceptor.ScanRoots()
        print(string.format("[PR] Discovered %d remotes.", discovered))
        PR_Persist.Load()
        local outOk = PR_Interceptor.HookOutgoing()
        print(outOk and "[PR] C2S hook active." or "[PR] C2S hook unavailable — S2C only.")
        PR_Interceptor.WatchForNew()
        task.wait(2)
        PR_ManifestBuilder.Rebuild()
        print("[PR] Initial manifest built.")
        PR_Analytics.Print()
        -- Bridge sync loop
        task.spawn(function()
            while PR_Started do
                task.wait(PR_CFG.BridgePollSec)
                PR_Bridge.Sync()
            end
        end)
        -- Active prober loop
        task.spawn(function()
            task.wait(10)
            while PR_Started do
                if PR_CFG.ProbeEnabled then PR_ActiveProber.SweepTopCandidates(3) end
                task.wait(30)
            end
        end)
        -- Frequency reclassification loop
        task.spawn(function()
            while PR_Started do
                task.wait(15)
                for _, rec in pairs(PR_Registry) do PR_FreqProfiler.Classify(rec) end
            end
        end)
        PR_BuildPanel()
    end)
end

PR_Start()

-- ============================================================
--  ███████╗ █████╗ ██████╗ ██████╗ 
--  ██╔════╝██╔══██╗██╔══██╗██╔══██╗
--  ███████╗███████║██████╔╝██████╔╝
--  ╚════██║██╔══██║██╔══██╗██╔═══╝ 
--  ███████║██║  ██║██║  ██║██║     
--  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     
--  SARP — Self Autonomous Replication Payload · Phoenix Edition
--
--  Architecture:
--    Layer 1 — Broadcast-before-correction  (echo propagation window)
--    Layer 2 — Ownership-anchor carrier     (client-authoritative BasePart)
--    Layer 3 — Adaptive Phoenix reshape     (correction-signal driven retry)
--
--  Modules: TargetResolver · Crafter · Simulator · Flyer
--           PhoenixLoop · Orchestrator
--  Hooks into: ETM · CDG · LWM · StateSignature · IntelMem · PR
-- ============================================================

-- ── SARP is initialized inside an IIFE so all internal locals
-- ── live in function scope (avoids main-chunk register exhaustion)
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
    -- PR channel suggestion
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
