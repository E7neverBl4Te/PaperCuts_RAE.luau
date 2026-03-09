-- ── Imports ────────────────────────────────────────────────────────────────
local _C = _G.PC
local RunService = _C.RunService

-- ============================================================
-- PR — PROTOCOL RECONSTRUCTION MODULE
-- ============================================================

local PR_CFG = {
    SeqLogCap      = 200,
    ProbeEnabled   = false,
    PersistEnabled = true,
    BridgePollSec  = 15,
    PersistKey     = "PR_Data_" .. tostring(game.PlaceId),
    ShowPanel      = false,
}

local PR_Registry  = {}
local PR_SeqLog    = {}
local PR_SeqLogPtr = 0
local PR_DepEdges  = {}
local PR_Manifest  = {}
local PR_Hooks_PR  = {}
local PR_LastProbe = 0
local PR_Started   = false

local PR_EC        = { Deltas={}, Remote=nil, Conn=nil, LastT=0,
                       MinSamples=12, MaxSamples=64, RefinedHz=0, Active=false }
local PR_Anomaly   = { Baseline={}, Log={}, ZThresh=3.2, SilenceSec=12.0 }
local PR_PFP       = { Key="PR_Fingerprint_"..tostring(game.PlaceId),
                       Current=nil, Last=nil }

-- ── Record constructors ──────────────────────────────────────────────────────
local function PR_NewArgSlot()
    return { DominantType="unknown", TypeCounts={}, NumberMin=nil, NumberMax=nil,
             StringSamples={}, SeenCFrame=false, SeenVector3=false,
             SeenBool=false, SeenInstance=false, SampleCount=0 }
end
local function PR_NewRecord(name, remoteObj, remoteType)
    return {
        Name=name, Remote=remoteObj, RemoteType=remoteType,
        FireCount=0, S2CCount=0, C2SCount=0, Direction="NONE",
        FirstFireTime=0, LastFireTime=0, AvgHz=0,
        FreqClass="RARE", EchoRelevance=0, PayloadScore=0, DepImportance=0,
        ArgSchema={}, ArgCountMin=999, ArgCountMax=0,
        SemanticRole="UNKNOWN",
    }
end

-- ── Schema inferrer ──────────────────────────────────────────────────────────
local PR_SchemaInfer = {}
function PR_SchemaInfer.InferType(v)
    local t = type(v)
    if t=="number"   then return "number" end
    if t=="string"   then return "string" end
    if t=="boolean"  then return "boolean" end
    if t=="nil"      then return "nil" end
    if typeof then
        local tv = typeof(v)
        if tv=="CFrame"   then return "CFrame" end
        if tv=="Vector3"  then return "Vector3" end
        if tv=="Instance" then return "Instance" end
        if tv=="Color3"   then return "Color3" end
        if tv=="UDim2"    then return "UDim2" end
        return tv
    end
    return "userdata"
end
function PR_SchemaInfer.UpdateSlot(slot, value)
    local t = PR_SchemaInfer.InferType(value)
    slot.TypeCounts[t] = (slot.TypeCounts[t] or 0) + 1
    slot.SampleCount   = slot.SampleCount + 1
    if t=="number" then
        slot.NumberMin = slot.NumberMin and math.min(slot.NumberMin,value) or value
        slot.NumberMax = slot.NumberMax and math.max(slot.NumberMax,value) or value
    elseif t=="string" and #slot.StringSamples < 4 then
        table.insert(slot.StringSamples, value:sub(1,32))
    elseif t=="CFrame"  then slot.SeenCFrame   = true
    elseif t=="Vector3" then slot.SeenVector3  = true
    elseif t=="boolean" then slot.SeenBool     = true
    elseif t=="Instance" then slot.SeenInstance= true
    end
end
function PR_SchemaInfer.FinalizeSlot(slot)
    local best, bestN = "unknown", 0
    for t, n in pairs(slot.TypeCounts) do if n > bestN then best=t; bestN=n end end
    slot.DominantType = best
end
function PR_SchemaInfer.UpdateRecord(rec, args, dir)
    local n = #args
    if n < rec.ArgCountMin then rec.ArgCountMin = n end
    if n > rec.ArgCountMax then rec.ArgCountMax = n end
    for i, v in ipairs(args) do
        if not rec.ArgSchema[i] then rec.ArgSchema[i] = PR_NewArgSlot() end
        PR_SchemaInfer.UpdateSlot(rec.ArgSchema[i], v)
    end
end
function PR_SchemaInfer.GetSchemaStr(rec)
    local parts = {}
    for _, slot in ipairs(rec.ArgSchema) do
        PR_SchemaInfer.FinalizeSlot(slot)
        local s = slot.DominantType
        if slot.NumberMin then s = s..string.format("[%.0f-%.0f]",slot.NumberMin,slot.NumberMax) end
        table.insert(parts, s)
    end
    return #parts>0 and table.concat(parts,", ") or "(no args)"
end

-- ── Frequency profiler ───────────────────────────────────────────────────────
local PR_FreqProfiler = {}
function PR_FreqProfiler.RecordDelta(rec, now)
    if rec.LastFireTime > 0 then
        local delta = now - rec.LastFireTime
        if delta > 0.005 then
            local hz = 1/delta
            rec.AvgHz = rec.AvgHz * 0.85 + hz * 0.15
        end
    end
    if rec.FirstFireTime == 0 then rec.FirstFireTime = now end
    rec.LastFireTime = now
end
function PR_FreqProfiler.Classify(rec)
    local hz = rec.AvgHz
    if hz >= 3   then rec.FreqClass = "PERIODIC"
    elseif hz >= 0.5 then rec.FreqClass = "BURST"
    elseif hz >= 0.05 then rec.FreqClass = "EVENT"
    else rec.FreqClass = "RARE" end
    -- Echo relevance: periodic S2C = best calibrators
    rec.EchoRelevance = 0
    if rec.FreqClass=="PERIODIC" and (rec.Direction=="S2C" or rec.Direction=="BOTH") then
        rec.EchoRelevance = math.min(1, hz/20)
    end
    -- Payload score: C2S with args
    rec.PayloadScore = rec.C2SCount > 0 and math.min(1, rec.ArgCountMax/5) or 0
    return rec.FreqClass
end

-- ── Sequence analyzer ────────────────────────────────────────────────────────
local PR_SeqAnalyzer = {}
function PR_SeqAnalyzer.Record(name, dir, argCount)
    local t = os.clock()
    PR_SeqLogPtr = (PR_SeqLogPtr % PR_CFG.SeqLogCap) + 1
    PR_SeqLog[PR_SeqLogPtr] = {name=name, dir=dir, t=t, argCount=argCount}
end
function PR_SeqAnalyzer.UpdateEdges()
    local n = #PR_SeqLog
    if n < 2 then return end
    local prev = PR_SeqLog[n-1]; local curr = PR_SeqLog[n]
    if not prev then return end
    local delay = curr.t - prev.t
    if delay < 0 or delay > 2 then return end
    if not PR_DepEdges[prev.name] then PR_DepEdges[prev.name] = {} end
    local e = PR_DepEdges[prev.name][curr.name]
    if not e then
        PR_DepEdges[prev.name][curr.name] = {count=1,totalDelay=delay,minDelay=delay,maxDelay=delay}
    else
        e.count=e.count+1; e.totalDelay=e.totalDelay+delay
        e.minDelay=math.min(e.minDelay,delay); e.maxDelay=math.max(e.maxDelay,delay)
    end
end

-- ── Dependency graph ─────────────────────────────────────────────────────────
local PR_DepGraph = {}
function PR_DepGraph.GetEntryPoints()
    local hasPred = {}
    for _, targets in pairs(PR_DepEdges) do
        for tgt in pairs(targets) do hasPred[tgt] = true end
    end
    local eps = {}
    for name, rec in pairs(PR_Registry) do
        if not hasPred[name] and rec.FireCount > 2 then
            table.insert(eps, {Name=name, FireCount=rec.FireCount})
        end
    end
    table.sort(eps, function(a,b) return a.FireCount > b.FireCount end)
    return eps
end
function PR_DepGraph.GetChain(startName, depth)
    depth = depth or 6
    local chain = {startName}
    local visited = {[startName]=true}
    local cur = startName
    for _ = 1, depth do
        local best, bestCount = nil, 0
        if PR_DepEdges[cur] then
            for tgt, edge in pairs(PR_DepEdges[cur]) do
                if not visited[tgt] and edge.count > bestCount then
                    best=tgt; bestCount=edge.count
                end
            end
        end
        if not best then break end
        table.insert(chain, best); visited[best]=true; cur=best
    end
    return chain
end
function PR_DepGraph.GetImportanceScore(name)
    local score = 0
    for _, targets in pairs(PR_DepEdges) do
        if targets[name] then score = score + targets[name].count end
    end
    return score
end

-- ── Interceptor ──────────────────────────────────────────────────────────────
local PR_Interceptor = {}
function PR_Interceptor.OnFire(name, dir, args, remoteObj, remoteType)
    local rec = PR_Registry[name]
    if not rec then
        rec = PR_NewRecord(name, remoteObj, remoteType)
        PR_Registry[name] = rec
    end
    rec.FireCount = rec.FireCount + 1
    local now = os.clock()
    PR_FreqProfiler.RecordDelta(rec, now)
    if dir=="S2C" then rec.S2CCount=rec.S2CCount+1
    elseif dir=="C2S" then rec.C2SCount=rec.C2SCount+1 end
    if rec.S2CCount>0 and rec.C2SCount>0 then rec.Direction="BOTH"
    elseif rec.S2CCount>0 then rec.Direction="S2C"
    elseif rec.C2SCount>0 then rec.Direction="C2S" end
    if args then PR_SchemaInfer.UpdateRecord(rec, args, dir) end
    PR_SeqAnalyzer.Record(name, dir, args and #args or 0)
    PR_SeqAnalyzer.UpdateEdges()
end
function PR_Interceptor.HookIncoming()
    local rs = game:GetService("ReplicatedStorage")
    local function hookRE(re)
        local conn = re.OnClientEvent:Connect(function(...)
            PR_Interceptor.OnFire(re.Name, "S2C", {...}, re, "RemoteEvent")
        end)
        table.insert(PR_Hooks_PR, conn)
    end
    local function hookRF(rf)
        local origInvoke = rf.InvokeServer
        local ok = pcall(function()
            rf.InvokeServer = function(self, ...)
                PR_Interceptor.OnFire(rf.Name, "C2S", {...}, rf, "RemoteFunction")
                return origInvoke(self, ...)
            end
        end)
    end
    local function scanFolder(folder)
        local ok, children = pcall(function() return folder:GetDescendants() end)
        if not ok then return end
        for _, obj in ipairs(children) do
            if obj:IsA("RemoteEvent")    then pcall(hookRE, obj)
            elseif obj:IsA("RemoteFunction") then pcall(hookRF, obj) end
        end
    end
    scanFolder(rs)
    return true
end
function PR_Interceptor.HookOutgoing()
    local mt = getrawmetatable and getrawmetatable(game)
    if not mt then return false end
    local oldIndex = mt.__namecall
    local ok = pcall(function()
        setreadonly(mt, false)
        mt.__namecall = function(self, ...)
            local method = getnamecallmethod and getnamecallmethod() or ""
            if method == "FireServer" and self:IsA("RemoteEvent") then
                PR_Interceptor.OnFire(self.Name, "C2S", {...}, self, "RemoteEvent")
            end
            return oldIndex(self, ...)
        end
        setreadonly(mt, true)
    end)
    return ok
end
function PR_Interceptor.ScanRoots()
    local count = 0
    local rs = game:GetService("ReplicatedStorage")
    local function scan(parent)
        local ok, children = pcall(function() return parent:GetChildren() end)
        if not ok then return end
        for _, obj in ipairs(children) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                if not PR_Registry[obj.Name] then
                    PR_Registry[obj.Name] = PR_NewRecord(obj.Name, obj, obj.ClassName)
                    count = count + 1
                end
            elseif obj:IsA("Folder") or obj:IsA("Model") then
                scan(obj)
            end
        end
    end
    scan(rs); scan(game:GetService("Players"))
    PR_Interceptor.HookIncoming()
    return count
end
function PR_Interceptor.WatchForNew()
    local rs = game:GetService("ReplicatedStorage")
    rs.DescendantAdded:Connect(function(obj)
        if obj:IsA("RemoteEvent") and not PR_Registry[obj.Name] then
            PR_Registry[obj.Name] = PR_NewRecord(obj.Name, obj, "RemoteEvent")
            pcall(function()
                local conn = obj.OnClientEvent:Connect(function(...)
                    PR_Interceptor.OnFire(obj.Name, "S2C", {...}, obj, "RemoteEvent")
                end)
                table.insert(PR_Hooks_PR, conn)
            end)
        end
    end)
end

-- ── Active prober ─────────────────────────────────────────────────────────────
local PR_ActiveProber = {}
function PR_ActiveProber.GenPermutations(rec)
    local perms = {{}}
    for _, slot in ipairs(rec.ArgSchema) do
        local t = slot.DominantType
        local val = t=="number" and (slot.NumberMin or 0)
                 or t=="string" and (slot.StringSamples[1] or "test")
                 or t=="boolean" and true
                 or t=="CFrame" and CFrame.new()
                 or t=="Vector3" and Vector3.new()
                 or nil
        for _, p in ipairs(perms) do table.insert(p, val) end
    end
    return perms
end
function PR_ActiveProber.ProbeRemote(rec)
    if rec.RemoteType ~= "RemoteEvent" or not rec.Remote then return false end
    local perms = PR_ActiveProber.GenPermutations(rec)
    for _, args in ipairs(perms) do
        pcall(function() rec.Remote:FireServer(table.unpack(args)) end)
        task.wait(0.2)
    end
    return true
end
function PR_ActiveProber.SweepTopCandidates(n)
    local candidates = {}
    for name, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0.3 then table.insert(candidates, rec) end
    end
    table.sort(candidates, function(a,b) return a.PayloadScore > b.PayloadScore end)
    local probed = 0
    for i = 1, math.min(n, #candidates) do
        if PR_ActiveProber.ProbeRemote(candidates[i]) then probed = probed + 1 end
        task.wait(1)
    end
    return probed
end

-- ── Manifest builder ─────────────────────────────────────────────────────────
local PR_ManifestBuilder = {}
function PR_ManifestBuilder.Rebuild()
    PR_Manifest = {}
    for name, rec in pairs(PR_Registry) do
        PR_FreqProfiler.Classify(rec)
        rec.DepImportance = PR_DepGraph.GetImportanceScore(name)
        table.insert(PR_Manifest, rec)
    end
    table.sort(PR_Manifest, function(a,b) return a.FireCount > b.FireCount end)
    return #PR_Manifest
end

-- ── Persistence ──────────────────────────────────────────────────────────────
local PR_Persist = {}
function PR_Persist.Serialize()
    local out = {}
    for name, rec in pairs(PR_Registry) do
        out[name] = {
            FireCount=rec.FireCount, S2CCount=rec.S2CCount, C2SCount=rec.C2SCount,
            Direction=rec.Direction, AvgHz=rec.AvgHz, FreqClass=rec.FreqClass,
            EchoRelevance=rec.EchoRelevance, PayloadScore=rec.PayloadScore,
            SemanticRole=rec.SemanticRole,
        }
    end
    return out
end
function PR_Persist.Restore(data)
    for name, saved in pairs(data) do
        local rec = PR_Registry[name]
        if rec then
            rec.FireCount=saved.FireCount or rec.FireCount
            rec.S2CCount=saved.S2CCount or rec.S2CCount
            rec.C2SCount=saved.C2SCount or rec.C2SCount
            rec.Direction=saved.Direction or rec.Direction
            rec.AvgHz=saved.AvgHz or rec.AvgHz
            rec.FreqClass=saved.FreqClass or rec.FreqClass
            rec.EchoRelevance=saved.EchoRelevance or rec.EchoRelevance
            rec.PayloadScore=saved.PayloadScore or rec.PayloadScore
            rec.SemanticRole=saved.SemanticRole or rec.SemanticRole
        end
    end
end
function PR_Persist.Save()
    if not PR_CFG.PersistEnabled then return end
    pcall(function() _G[PR_CFG.PersistKey] = PR_Persist.Serialize() end)
end
function PR_Persist.Load()
    pcall(function()
        local saved = _G[PR_CFG.PersistKey]
        if type(saved) == "table" then PR_Persist.Restore(saved) end
    end)
end

-- ── Analytics ────────────────────────────────────────────────────────────────
local PR_Analytics = {}
function PR_Analytics.GetSummary()
    local s = {TotalRemotes=0, PERIODIC=0, BURST=0, EVENT=0, RARE=0, C2S=0, S2C=0, BOTH=0}
    for _, rec in pairs(PR_Registry) do
        s.TotalRemotes = s.TotalRemotes + 1
        s[rec.FreqClass] = (s[rec.FreqClass] or 0) + 1
        if rec.Direction=="C2S" then s.C2S=s.C2S+1
        elseif rec.Direction=="S2C" then s.S2C=s.S2C+1
        elseif rec.Direction=="BOTH" then s.BOTH=s.BOTH+1 end
    end
    return s
end
function PR_Analytics.GetReport()
    local s = PR_Analytics.GetSummary()
    return string.format("[PR] Remotes:%d  PERIODIC:%d BURST:%d EVENT:%d RARE:%d  C2S:%d S2C:%d BOTH:%d",
        s.TotalRemotes,s.PERIODIC,s.BURST,s.EVENT,s.RARE,s.C2S,s.S2C,s.BOTH)
end
function PR_Analytics.Print() print(PR_Analytics.GetReport()) end

-- ── Bridge ───────────────────────────────────────────────────────────────────
-- Forward declarations — PR_Bridge.Sync references these before they are defined
local PR_Classifier
local PR_AnomalyDetector
local PR_ProtocolFingerprint

local PR_Bridge = {}
function PR_Bridge.FeedETM()
    local ETM = _G.PC and _G.PC.ETM
    if not ETM then return end
    for _, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0.4 and rec.C2SCount > 0 then
            pcall(function() ETM.RecordObservation(rec.Name, true, 0.6) end)
        end
    end
end
function PR_Bridge.FeedCDG()
    local CDG = _G.PC and _G.PC.CDG
    if not CDG then return end
    for from, targets in pairs(PR_DepEdges) do
        for to, edge in pairs(targets) do
            if edge.count > 3 then
                pcall(function() CDG.RecordCoExecution(from, to, true) end)
            end
        end
    end
end
function PR_Bridge.FeedLWM()
    local LWM = _G.PC and _G.PC.LWM
    if not LWM then return end
    pcall(function()
        _G.PR_LWM_INJECT = {remoteCount=#PR_Manifest, periodicCount=0}
        for _, rec in pairs(PR_Registry) do
            if rec.FreqClass=="PERIODIC" then
                _G.PR_LWM_INJECT.periodicCount = _G.PR_LWM_INJECT.periodicCount + 1
            end
        end
    end)
end
function PR_Bridge.GetPayloadCandidates(n)
    local out = {}
    for _, rec in pairs(PR_Registry) do
        if rec.PayloadScore > 0.3 then table.insert(out, rec) end
    end
    table.sort(out, function(a,b) return a.PayloadScore > b.PayloadScore end)
    local result = {}
    for i = 1, math.min(n or 5, #out) do table.insert(result, out[i]) end
    return result
end
function PR_Bridge.GetBestEchoCalibrator()
    local best, bestScore = nil, -1
    for _, rec in pairs(PR_Registry) do
        if rec.FreqClass=="PERIODIC" and rec.S2CCount > 4 and rec.EchoRelevance > bestScore then
            best=rec; bestScore=rec.EchoRelevance
        end
    end
    return best
end
function PR_Bridge.CalibrateSARP()
    local period = (function()
        local d = PR_EC.Deltas
        local n = #d
        if n < PR_EC.MinSamples then return nil end
        local sorted = {}
        for _, v in ipairs(d) do table.insert(sorted, v) end
        table.sort(sorted)
        local trim = math.max(1, math.floor(n*0.1))
        local sum, count = 0, 0
        for i = trim+1, n-trim do sum=sum+sorted[i]; count=count+1 end
        return count > 0 and sum/count or nil
    end)()
    if not period then return nil end
    local refined = period * 0.35
    _G.PR_ECHO_WINDOW_REFINED = refined
    pcall(function()
        local key = "SARP_EchoWin_"..tostring(game.PlaceId)
        if not _G[key] or math.abs(_G[key]-refined) > 0.005 then _G[key]=refined end
    end)
    return refined
end
function PR_Bridge.GetSuggestedChannel()
    local acFlag = (function()
        for i=#PR_Anomaly.Log, math.max(1,#PR_Anomaly.Log-5), -1 do
            local e = PR_Anomaly.Log[i]
            if e and e.kind=="RATE_SPIKE" and (e.role=="ANTICHEAT" or e.role=="HEARTBEAT") then
                if os.clock()-e.t < 30 then return true end
            end
        end
        return false
    end)()
    if acFlag then return "AttachmentBridge" end
    local best = PR_Bridge.GetBestEchoCalibrator()
    if best and best.EchoRelevance > 0.6 then return "Attribute" end
    local c2sCount = 0
    for _, rec in pairs(PR_Registry) do if rec.C2SCount>0 then c2sCount=c2sCount+1 end end
    if c2sCount == 0 then return "OwnedCarrier" end
    return nil
end
function PR_Bridge.Sync()
    PR_ManifestBuilder.Rebuild()
    PR_Classifier.ClassifyAll()
    PR_AnomalyDetector.SweepAll()
    PR_ProtocolFingerprint.Compute()
    PR_Bridge.FeedETM(); PR_Bridge.FeedCDG(); PR_Bridge.FeedLWM()
    PR_Bridge.CalibrateSARP()
    PR_ProtocolFingerprint.Save()
    PR_Persist.Save()
end

-- ── Classifier ────────────────────────────────────────────────────────────────
local PR_ROLE_KW = {
    MOVEMENT ={"move","walk","run","jump","dash","fly","swim","tele","warp","pos","cframe","velocity","sprint"},
    COMBAT   ={"shoot","fire","damage","hurt","kill","attack","hit","bullet","weapon","gun","sword","ability","cast","explode"},
    ECONOMY  ={"buy","sell","purchase","trade","coin","cash","credit","gem","currency","reward","shop","store","price","gold","money"},
    ANTICHEAT={"ac","anticheat","check","verify","report","kick","ban","detect","monitor","flag","trust","auth","token"},
    UI       ={"gui","ui","menu","open","close","show","hide","button","click","tab","panel","hud","notif","popup","dialog"},
    SYNC     ={"sync","update","replicate","state","status","refresh","init","ready","tick","frame","interval","poll"},
    HEARTBEAT={"heart","ping","pong","alive","keepalive","pulse","beat"},
    CHAT     ={"chat","message","msg","say","whisper","channel","voice"},
    SPAWN    ={"spawn","respawn","load","join","enter","leave","exit","char","character"},
}
PR_Classifier = {}
function PR_Classifier.ClassifyByName(name)
    local lower = name:lower()
    for role, kws in pairs(PR_ROLE_KW) do
        for _, kw in ipairs(kws) do
            if lower:find(kw,1,true) then return role end
        end
    end
    return nil
end
function PR_Classifier.ClassifyByPattern(rec)
    if rec.FreqClass=="PERIODIC" and rec.AvgHz>0.5 and rec.ArgCountMax<=2 then return "HEARTBEAT" end
    if rec.FreqClass=="PERIODIC" and rec.Direction=="S2C" and rec.ArgCountMax<=3 then return "ANTICHEAT" end
    if rec.FreqClass=="PERIODIC" and (rec.Direction=="C2S" or rec.Direction=="BOTH") then
        for _, slot in ipairs(rec.ArgSchema) do
            if slot.DominantType=="CFrame" or slot.DominantType=="Vector3" then return "MOVEMENT" end
        end
    end
    if rec.FreqClass=="BURST" and rec.C2SCount>0 then
        for _, slot in ipairs(rec.ArgSchema) do
            if slot.DominantType=="number" and slot.NumberMin and slot.NumberMin>=0 then return "ECONOMY" end
        end
    end
    if rec.Direction=="S2C" and rec.FreqClass~="RARE" then return "SYNC" end
    return nil
end
function PR_Classifier.Classify(rec)
    local role = PR_Classifier.ClassifyByName(rec.Name)
    if not role then
        for _, slot in ipairs(rec.ArgSchema) do
            PR_SchemaInfer.FinalizeSlot(slot)
            if slot.DominantType=="CFrame" or slot.DominantType=="Vector3" then role="MOVEMENT"; break end
        end
    end
    if not role then role = PR_Classifier.ClassifyByPattern(rec) end
    rec.SemanticRole = role or "UNKNOWN"
    return rec.SemanticRole
end
function PR_Classifier.ClassifyAll()
    for _, rec in pairs(PR_Registry) do PR_Classifier.Classify(rec) end
end

-- ── Anomaly detector ──────────────────────────────────────────────────────────
PR_AnomalyDetector = {}
function PR_AnomalyDetector.UpdateBaseline(name, rec)
    if rec.AvgHz <= 0 then return end
    if not PR_Anomaly.Baseline[name] then PR_Anomaly.Baseline[name]={mean=rec.AvgHz,m2=0,n=0} end
    local b = PR_Anomaly.Baseline[name]
    b.n = b.n+1
    local delta = rec.AvgHz - b.mean
    b.mean = b.mean + delta/b.n
    b.m2   = b.m2 + delta*(rec.AvgHz-b.mean)
end
function PR_AnomalyDetector.CheckSpike(name, rec)
    local b = PR_Anomaly.Baseline[name]
    if not b or b.n < 8 then return end
    local variance = b.n>1 and (b.m2/(b.n-1)) or 0
    local stddev   = variance>0 and math.sqrt(variance) or 0
    if stddev < 1e-6 then return end
    local z = math.abs(rec.AvgHz - b.mean) / stddev
    if z >= PR_Anomaly.ZThresh then
        local ev = {t=os.clock(),name=name,kind=rec.AvgHz>b.mean and "RATE_SPIKE" or "RATE_DROP",
            zScore=z,currentHz=rec.AvgHz,baselineHz=b.mean,role=rec.SemanticRole or "UNKNOWN"}
        table.insert(PR_Anomaly.Log, ev)
        if #PR_Anomaly.Log > 50 then table.remove(PR_Anomaly.Log,1) end
    end
end
function PR_AnomalyDetector.CheckSilence(name, rec, now)
    if rec.FreqClass~="PERIODIC" or rec.LastFireTime<=0 then return end
    local elapsed = now - rec.LastFireTime
    if elapsed > PR_Anomaly.SilenceSec then
        local last = PR_Anomaly.Log[#PR_Anomaly.Log]
        if last and last.name==name and last.kind=="SILENCE" then return end
        local ev = {t=now,name=name,kind="SILENCE",zScore=0,silenceSec=elapsed,role=rec.SemanticRole or "UNKNOWN"}
        table.insert(PR_Anomaly.Log, ev)
        if #PR_Anomaly.Log > 50 then table.remove(PR_Anomaly.Log,1) end
    end
end
function PR_AnomalyDetector.SweepAll()
    local now = os.clock()
    for name, rec in pairs(PR_Registry) do
        PR_FreqProfiler.Classify(rec)
        PR_AnomalyDetector.UpdateBaseline(name, rec)
        PR_AnomalyDetector.CheckSpike(name, rec)
        PR_AnomalyDetector.CheckSilence(name, rec, now)
    end
end
function PR_AnomalyDetector.GetRecentEvents(n)
    n = n or 10
    local out = {}
    for i = math.max(1,#PR_Anomaly.Log-n+1), #PR_Anomaly.Log do
        table.insert(out, PR_Anomaly.Log[i])
    end
    return out
end
function PR_AnomalyDetector.HasACPattern()
    for i=#PR_Anomaly.Log, math.max(1,#PR_Anomaly.Log-5), -1 do
        local e = PR_Anomaly.Log[i]
        if e and e.kind=="RATE_SPIKE" and (e.role=="ANTICHEAT" or e.role=="HEARTBEAT") then
            if os.clock()-e.t < 30 then return true, e end
        end
    end
    return false, nil
end

-- ── Echo calibrator ───────────────────────────────────────────────────────────
local PR_EchoCalibrator = {}
function PR_EchoCalibrator.SelectBest()
    local best, bestScore = nil, -1
    for _, rec in pairs(PR_Registry) do
        if rec.FreqClass=="PERIODIC" and rec.S2CCount>4 and rec.EchoRelevance>bestScore then
            best=rec; bestScore=rec.EchoRelevance
        end
    end
    return best
end
function PR_EchoCalibrator.Attach(rec)
    if PR_EC.Conn then pcall(function() PR_EC.Conn:Disconnect() end); PR_EC.Conn=nil end
    if not rec or rec.RemoteType~="RemoteEvent" then return false end
    local ok, conn = pcall(function()
        return rec.Remote.OnClientEvent:Connect(function()
            local now = os.clock()
            if PR_EC.LastT > 0 then
                local delta = now - PR_EC.LastT
                if delta>0.005 and delta<5.0 then
                    table.insert(PR_EC.Deltas, delta)
                    if #PR_EC.Deltas > PR_EC.MaxSamples then table.remove(PR_EC.Deltas,1) end
                end
            end
            PR_EC.LastT = now
        end)
    end)
    if ok and conn then PR_EC.Conn=conn; PR_EC.Remote=rec; PR_EC.Active=true; return true end
    return false
end
function PR_EchoCalibrator.PushToSARP()
    local refined = PR_Bridge.CalibrateSARP()
    if not refined then return false end
    PR_EC.RefinedHz = refined > 0 and (1/refined) or 0
    if type(_G.PR_LWM_INJECT)=="table" then
        _G.PR_LWM_INJECT.pr_calibratorHz = PR_EC.RefinedHz
        _G.PR_LWM_INJECT.pr_echoRefined  = refined
    end
    return true
end
function PR_EchoCalibrator.Start()
    task.spawn(function()
        task.wait(5)
        while true do
            local best = PR_EchoCalibrator.SelectBest()
            if best and best~=PR_EC.Remote then PR_EchoCalibrator.Attach(best) end
            PR_EchoCalibrator.PushToSARP()
            task.wait(30)
        end
    end)
end
function PR_EchoCalibrator.GetStatus()
    return {Active=PR_EC.Active, RemoteName=PR_EC.Remote and PR_EC.Remote.Name or nil,
        SampleCount=#PR_EC.Deltas, RefinedHz=PR_EC.RefinedHz,
        RefinedWindow=_G.PR_ECHO_WINDOW_REFINED}
end

-- ── Protocol fingerprint ──────────────────────────────────────────────────────
PR_ProtocolFingerprint = {}
function PR_ProtocolFingerprint.Compute()
    local entries = {}
    for name, rec in pairs(PR_Registry) do
        if rec.FireCount > 0 then
            table.insert(entries, name..":"..rec.FreqClass..":"..rec.Direction)
        end
    end
    table.sort(entries)
    local concat = table.concat(entries,"|")
    local hash = 2166136261
    for i = 1, #concat do
        hash = bit32.bxor(hash, string.byte(concat,i))
        hash = (hash * 16777619) % (2^32)
    end
    local roleMap = {}
    for _, rec in pairs(PR_Registry) do
        if rec.SemanticRole then roleMap[rec.SemanticRole]=(roleMap[rec.SemanticRole] or 0)+1 end
    end
    local count = 0; for _ in pairs(PR_Registry) do count=count+1 end
    PR_PFP.Current = {hash=string.format("%08X",hash), remoteCount=count,
                      roleMap=roleMap, builtAt=os.clock()}
    return PR_PFP.Current
end
function PR_ProtocolFingerprint.Save()
    if PR_CFG.PersistEnabled and PR_PFP.Current then
        pcall(function() _G[PR_PFP.Key] = PR_PFP.Current end)
    end
end
function PR_ProtocolFingerprint.Load()
    pcall(function()
        local saved = _G[PR_PFP.Key]
        if saved and type(saved)=="table" then PR_PFP.Last=saved end
    end)
end
function PR_ProtocolFingerprint.GetStr()
    if not PR_PFP.Current then return "not built" end
    local drift = PR_PFP.Last and (PR_PFP.Last.hash~=PR_PFP.Current.hash and " DRIFT" or " STABLE") or ""
    return string.format("FP:%s|%d remotes%s", PR_PFP.Current.hash, PR_PFP.Current.remoteCount, drift)
end

-- ── Status panel ──────────────────────────────────────────────────────────────
local function PR_BuildPanel()
    if not PR_CFG.ShowPanel then return end
    local screenGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    local sg = Instance.new("ScreenGui"); sg.Name="PR_Panel"; sg.ResetOnSpawn=false; sg.Parent=screenGui
    local frame = Instance.new("Frame"); frame.BackgroundColor3=Color3.fromRGB(30,30,40)
    frame.BackgroundTransparency=0.2; frame.Size=UDim2.new(0,260,0,60)
    frame.Position=UDim2.new(0,10,1,-70); frame.Parent=sg
    Instance.new("UICorner",frame).CornerRadius=UDim.new(0,6)
    local lbl = Instance.new("TextLabel"); lbl.BackgroundTransparency=1
    lbl.Font=Enum.Font.Code; lbl.TextSize=10; lbl.TextColor3=Color3.fromRGB(200,220,200)
    lbl.Size=UDim2.new(1,-8,1,0); lbl.Position=UDim2.new(0,4,0,0)
    lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.TextWrapped=true; lbl.Parent=frame
    task.spawn(function()
        while frame.Parent do
            local s = PR_Analytics.GetSummary()
            local cal = PR_EchoCalibrator.GetStatus()
            local acFlag = PR_AnomalyDetector.HasACPattern()
            lbl.Text = string.format("[PR] R:%d P:%d C2S:%d\nCAL:%s FP:%s %s",
                s.TotalRemotes,s.PERIODIC,s.C2S,
                cal.Active and string.format("%.1fHz",cal.RefinedHz) or "idle",
                PR_PFP.Current and PR_PFP.Current.hash:sub(1,6) or "??",
                acFlag and "⚠AC" or "")
            task.wait(2)
        end
    end)
end

-- ── PR Start ──────────────────────────────────────────────────────────────────
local function PR_Start()
    if PR_Started then return end
    PR_Started = true
    task.spawn(function()
        local discovered = PR_Interceptor.ScanRoots()
        print(string.format("[PR] Discovered %d remotes.", discovered))
        PR_Persist.Load()
        PR_ProtocolFingerprint.Load()
        local outOk = PR_Interceptor.HookOutgoing()
        print(outOk and "[PR] C2S hook active." or "[PR] C2S hook unavailable.")
        PR_Interceptor.WatchForNew()
        task.wait(2)
        PR_ManifestBuilder.Rebuild()
        PR_Classifier.ClassifyAll()
        PR_ProtocolFingerprint.Compute()
        print("[PR] Manifest built. " .. PR_ProtocolFingerprint.GetStr())
        PR_Analytics.Print()
        PR_EchoCalibrator.Start()
        task.spawn(function()
            while PR_Started do
                task.wait(PR_CFG.BridgePollSec)
                PR_Bridge.Sync()
            end
        end)
        task.spawn(function()
            task.wait(10)
            while PR_Started do
                if PR_CFG.ProbeEnabled then PR_ActiveProber.SweepTopCandidates(3) end
                task.wait(30)
            end
        end)
        task.spawn(function()
            while PR_Started do
                task.wait(15)
                for _, rec in pairs(PR_Registry) do PR_FreqProfiler.Classify(rec) end
                PR_Classifier.ClassifyAll()
                PR_AnomalyDetector.SweepAll()
            end
        end)
        PR_BuildPanel()
    end)
end

-- ── Export PR to shared namespace ────────────────────────────────────────────
_G.PC.PR_CFG       = PR_CFG
_G.PC.PR_Registry  = PR_Registry
_G.PC.PR_SchemaInfer   = PR_SchemaInfer
_G.PC.PR_FreqProfiler  = PR_FreqProfiler
_G.PC.PR_DepGraph      = PR_DepGraph
_G.PC.PR_ManifestBuilder = PR_ManifestBuilder
_G.PC.PR_Bridge        = PR_Bridge
_G.PC.PR_Analytics     = PR_Analytics
_G.PC.PR_Classifier    = PR_Classifier
_G.PC.PR_AnomalyDetector   = PR_AnomalyDetector
_G.PC.PR_EchoCalibrator    = PR_EchoCalibrator
_G.PC.PR_ProtocolFingerprint = PR_ProtocolFingerprint
_G.PC.PR_PFP = PR_PFP

PR_Start()
