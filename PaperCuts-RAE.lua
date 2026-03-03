--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   Paper & Clay  +  RAE — Recursive Autonomous Engine V2             ║
    ║   Combined Edition — Deep Intelligence Upgrade                       ║
    ║                                                                      ║
    ║   UI:  Paper & Clay shell — soft material, responsive layout        ║
    ║   RAE: 11-module autonomous engine with deep learning backend       ║
    ║                                                                      ║
    ║   Tabs: Overview · Player · Camera · World · Discovery              ║
    ║         RAE · Recursive · Bridge · Utilities · About                ║
    ║                                                                      ║
    ║   RAE V2 Architecture (11 Modules):                                 ║
    ║     Module 1  — Perception/Scanner: State capture                   ║
    ║     Module 2  — Living World Model (LWM): N-snapshot temporal       ║
    ║     Module 3  — State Signature φ(S): Compact feature extraction    ║
    ║     Module 4  — Enhanced Transition Model (ETM): P(S_t+1|S_t,A_t)  ║
    ║     Module 5  — Causal Dependency Graph (CDG): Causal edges         ║
    ║     Module 6  — Multi-Objective Value System: 6-axis vector         ║
    ║     Module 7  — MCTS Planner: Model-based rollouts                  ║
    ║     Module 8  — Chain Executor: Fast + Staged paths                 ║
    ║     Module 9  — Intelligence v4: Thompson + Drift + Calibration     ║
    ║     Module 10 — Learning & Memory: Session persistence              ║
    ║     Module 11 — Telemetry & Explainability                          ║
    ╚══════════════════════════════════════════════════════════════════════╝
--]]

-- ============================================================
-- SERVICES
-- ============================================================
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")
local SoundService      = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local LogService        = game:GetService("LogService")
local TextChatService   = game:GetService("TextChatService")
local Workspace         = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local existing = playerGui:FindFirstChild("PaperClayUI")
if existing then existing:Destroy() end

-- ============================================================
-- UI HELPERS
-- ============================================================
local function tween(inst, ti, props)
    local t = TweenService:Create(inst, ti, props); t:Play(); return t
end

local function mk(className, props, children)
    local obj = Instance.new(className)
    pcall(function() obj.AutoLocalize = false end)
    for k, v in pairs(props or {}) do obj[k] = v end
    if children then for _, c in ipairs(children) do c.Parent = obj end end
    return obj
end

local function addCorner(parent, radius)
    return mk("UICorner", { CornerRadius = radius or UDim.new(0, 14), Parent = parent })
end

local function addStroke(parent, thickness, transparency)
    return mk("UIStroke", {
        Thickness = thickness or 1, Transparency = transparency or 0.2,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = parent,
    })
end

local function addShadow(parent, zIndex)
    local sh = mk("Frame", {
        Name = "Shadow", BackgroundColor3 = Color3.fromRGB(0,0,0),
        BackgroundTransparency = 0.88, BorderSizePixel = 0,
        Size = UDim2.new(1,10,1,12), Position = UDim2.new(0,-5,0,6),
        ZIndex = (zIndex or parent.ZIndex) - 1, Parent = parent,
    })
    addCorner(sh, UDim.new(0, 18)); return sh
end

local function pulseClick(btn)
    local s0 = btn.Size
    tween(btn, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = s0 + UDim2.fromOffset(2,2) })
    task.delay(0.09, function() if btn and btn.Parent then tween(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = s0 }) end end)
end

local function hookHover(btn, baseBg, hoverBg, baseStrokeT, hoverStrokeT)
    local stroke = btn:FindFirstChildOfClass("UIStroke")
    btn.MouseEnter:Connect(function()
        tween(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundColor3 = hoverBg })
        if stroke then tween(stroke, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = hoverStrokeT }) end
    end)
    btn.MouseLeave:Connect(function()
        tween(btn, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundColor3 = baseBg })
        if stroke then tween(stroke, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = baseStrokeT }) end
    end)
end

local uiClickSound = mk("Sound", { Name="PaperClay_Click", SoundId="rbxassetid://911342077", Volume=0.25, Parent=SoundService })
local function clickSound() if uiClickSound then uiClickSound:Play() end end

-- ============================================================
-- PARSING ENGINES
-- ============================================================
local function cleanTable(t, seen)
    seen = seen or {}
    if type(t) ~= "table" then return t end
    if seen[t] then return "[Cycle]" end
    seen[t] = true
    local n = {}
    for k, v in pairs(t) do n[cleanTable(k, seen)] = cleanTable(v, seen) end
    return n
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_decode(data)
    data = string.gsub(data, '[^'..b64chars..'=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b64chars:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c=0; for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local function tryDecode(str)
    if (str:sub(1,1)=="{"and str:sub(-1)=="}")or(str:sub(1,1)=="["and str:sub(-1)=="]") then
        local s, res = pcall(function() return HttpService:JSONDecode(str) end)
        if s then return "JSON", res end
    end
    if #str>=4 and #str%4==0 and not str:match("[^%w%+/=]") then
        local s, res = pcall(base64_decode, str)
        if s and #res>0 and res:match("[%w%p%s]+") then
            if (res:sub(1,1)=="{"and res:sub(-1)=="}")or(res:sub(1,1)=="["and res:sub(-1)=="]") then
                local s2, res2 = pcall(function() return HttpService:JSONDecode(res) end)
                if s2 then return "Base64->JSON", res2 end
            end
            return "Base64", res
        end
    end
    return nil, str
end

local function disassembleBytecode(bytecode)
    if type(bytecode) ~= "string" or #bytecode == 0 then return "-- Invalid Bytecode --" end
    if type(disassemble) == "function" then
        local s, r = pcall(disassemble, bytecode)
        if s and type(r)=="string" and #r>0 then return r end
    end
    local success, result = pcall(function()
        local pos = 1
        local function readByte() local b = string.byte(bytecode, pos, pos); pos=pos+1; return b end
        local function readVarInt()
            local res=0; local shift=0; local b
            repeat b=readByte(); res=bit32.bor(res,bit32.lshift(bit32.band(b,127),shift)); shift=shift+7 until b<128
            return res
        end
        local output={"-- Luau Bytecode Disassembly --"}
        local version=readByte()
        if version==0 or version>5 then table.insert(output,"Error: unsupported version "..tostring(version)) return table.concat(output,"\n") end
        table.insert(output,"-- Version: "..version)
        local typeCount=readVarInt()
        for i=1,typeCount do local len=readVarInt(); pos=pos+len end
        local stringCount=readVarInt(); local strings={}
        for i=1,stringCount do local len=readVarInt(); local str=bytecode:sub(pos,pos+len-1); strings[i]=str; pos=pos+len end
        for i,s in ipairs(strings) do table.insert(output,"S"..i..": \""..s:gsub("[^%w%p ]","?"):sub(1,60)..(#s>60 and "..." or "").."\"") end
        return table.concat(output,"\n")
    end)
    return success and result or "-- Disassembly failed --"
end

-- ============================================================
-- STATISTICAL SAMPLING
-- ============================================================
local function SampleGamma(shape)
    if shape<1 then return SampleGamma(1+shape)*math.random()^(1/shape) end
    local d=shape-1/3; local c=1/math.sqrt(9*d)
    while true do
        local x,v; repeat x=math.sqrt(-2*math.log(math.random()))*math.cos(2*math.pi*math.random()); v=1+c*x until v>0
        v=v*v*v; local u=math.random()
        if u<1-0.0331*(x*x)*(x*x) or math.log(u)<0.5*x*x+d*(1-v+math.log(v)) then return d*v end
    end
end

local function SampleBeta(alpha, beta)
    local ga=SampleGamma(math.max(alpha,0.1)); local gb=SampleGamma(math.max(beta,0.1))
    local total=ga+gb; if total==0 then return 0.5 end; return ga/total
end

local function SampleBetaApprox(alpha, beta)
    local a=math.max(alpha,0.1); local b=math.max(beta,0.1)
    local mean=a/(a+b); local var=(a*b)/((a+b)^2*(a+b+1))
    local noise=math.sqrt(var)*(math.random()*2-1)*1.7
    return math.clamp(mean+noise, 0.01, 0.99)
end

-- ============================================================
-- MODULE 10: SESSION PERSISTENCE
-- ============================================================
local PersistenceKey = "RAE_V2_Session_" .. tostring(player.UserId)

local function LoadSession()
    return _G[PersistenceKey] or nil
end

local function SaveSession(data)
    _G[PersistenceKey] = data
end

local savedSession = LoadSession()

-- ============================================================
-- MODULE 2: LIVING WORLD MODEL (LWM)
-- ============================================================
local LWM_CONFIG = {
    MaxSnapshots = 10, DeltaThreshold = 0.05, CoFireWindow = 5, TemporalDecay = 0.92,
}

local LivingWorldModel = {
    Snapshots = {}, Deltas = {}, RemoteRegistry = {}, CoFireMap = {},
    TemporalAggregates = {}, CurrentIndex = 0,
}

if savedSession and savedSession.LWM then
    LivingWorldModel.RemoteRegistry = savedSession.LWM.RemoteRegistry or {}
    LivingWorldModel.CoFireMap = savedSession.LWM.CoFireMap or {}
    LivingWorldModel.TemporalAggregates = savedSession.LWM.TemporalAggregates or {}
end

function LivingWorldModel.AddSnapshot(ws)
    LivingWorldModel.CurrentIndex = (LivingWorldModel.CurrentIndex % LWM_CONFIG.MaxSnapshots) + 1
    local idx = LivingWorldModel.CurrentIndex
    local snapshot = { T = ws.T, Signature = nil, WorldState = ws }
    
    if LivingWorldModel.Snapshots[idx] then
        local prev = LivingWorldModel.Snapshots[idx]
        local delta = LivingWorldModel.ComputeDelta(prev.WorldState, ws)
        table.insert(LivingWorldModel.Deltas, { T = ws.T, FromT = prev.T, Delta = delta })
        if #LivingWorldModel.Deltas > LWM_CONFIG.MaxSnapshots * 2 then table.remove(LivingWorldModel.Deltas, 1) end
    end
    
    LivingWorldModel.Snapshots[idx] = snapshot
    
    for _, remote in ipairs(ws.Latent.RemoteEvents or {}) do
        local name = remote.Name
        if not LivingWorldModel.RemoteRegistry[name] then
            LivingWorldModel.RemoteRegistry[name] = { FirstSeen = ws.T, TotalFires = 0, FireTimes = {} }
        end
        local entry = LivingWorldModel.RemoteRegistry[name]
        entry.TotalFires = entry.TotalFires + (remote.FireCount - (entry.LastFireCount or 0))
        entry.LastFireCount = remote.FireCount
        if remote.LastFire > 0 then
            table.insert(entry.FireTimes, remote.LastFire)
            if #entry.FireTimes > 20 then table.remove(entry.FireTimes, 1) end
        end
    end
    
    LivingWorldModel.UpdateCoFireMap(ws)
    LivingWorldModel.UpdateTemporalAggregates(ws)
    return snapshot
end

function LivingWorldModel.ComputeDelta(wsBefore, wsAfter)
    local delta = { DeltaT = wsAfter.T - wsBefore.T, HealthChange = 0, PhysicsChange = 0, RemoteFireChange = 0, InstanceChange = 0 }
    local hpBefore = wsBefore.Agents.LocalPlayer and wsBefore.Agents.LocalPlayer.Health or 0
    local hpAfter = wsAfter.Agents.LocalPlayer and wsAfter.Agents.LocalPlayer.Health or 0
    delta.HealthChange = hpAfter - hpBefore
    delta.PhysicsChange = #(wsAfter.Physics.SimulatedAssemblies or {}) - #(wsBefore.Physics.SimulatedAssemblies or {})
    local firesBefore, firesAfter = 0, 0
    for _, r in ipairs(wsBefore.Latent.RemoteEvents or {}) do firesBefore = firesBefore + r.FireCount end
    for _, r in ipairs(wsAfter.Latent.RemoteEvents or {}) do firesAfter = firesAfter + r.FireCount end
    delta.RemoteFireChange = firesAfter - firesBefore
    delta.InstanceChange = wsAfter.ObjectGraph.TotalInstances - wsBefore.ObjectGraph.TotalInstances
    return delta
end

function LivingWorldModel.UpdateCoFireMap(ws)
    local now = ws.T
    local recentFires = {}
    for name, entry in pairs(LivingWorldModel.RemoteRegistry) do
        for _, fireTime in ipairs(entry.FireTimes or {}) do
            if now - fireTime <= LWM_CONFIG.CoFireWindow then table.insert(recentFires, { Name = name, Time = fireTime }) end
        end
    end
    for i = 1, #recentFires do
        for j = i + 1, #recentFires do
            local a, b = recentFires[i].Name, recentFires[j].Name
            if a > b then a, b = b, a end
            local key = a .. "|" .. b
            if not LivingWorldModel.CoFireMap[key] then LivingWorldModel.CoFireMap[key] = { Count = 0, LastSeen = 0 } end
            LivingWorldModel.CoFireMap[key].Count = LivingWorldModel.CoFireMap[key].Count + 1
            LivingWorldModel.CoFireMap[key].LastSeen = now
        end
    end
end

function LivingWorldModel.UpdateTemporalAggregates(ws)
    local agg = LivingWorldModel.TemporalAggregates
    local decay = LWM_CONFIG.TemporalDecay
    if not agg.AvgRemoteFires then agg.AvgRemoteFires = 0 end
    if not agg.AvgHealth then agg.AvgHealth = 100 end
    if not agg.AvgPhysics then agg.AvgPhysics = 0 end
    local totalFires = 0
    for _, r in ipairs(ws.Latent.RemoteEvents or {}) do totalFires = totalFires + r.FireCount end
    agg.AvgRemoteFires = agg.AvgRemoteFires * decay + totalFires * (1 - decay)
    local hp = ws.Agents.LocalPlayer and ws.Agents.LocalPlayer.Health or 0
    agg.AvgHealth = agg.AvgHealth * decay + hp * (1 - decay)
    agg.AvgPhysics = agg.AvgPhysics * decay + #(ws.Physics.SimulatedAssemblies or {}) * (1 - decay)
end

function LivingWorldModel.GetLatestDelta()
    return #LivingWorldModel.Deltas > 0 and LivingWorldModel.Deltas[#LivingWorldModel.Deltas] or nil
end

function LivingWorldModel.GetCoFireScore(remoteA, remoteB)
    local a, b = remoteA, remoteB
    if a > b then a, b = b, a end
    local key = a .. "|" .. b
    local entry = LivingWorldModel.CoFireMap[key]
    return entry and entry.Count or 0
end

-- ============================================================
-- MODULE 3: STATE SIGNATURE φ(S)
-- ============================================================
local StateSignature = {}

function StateSignature.Extract(ws)
    if not ws then return nil end
    local sig = {
        PlayerHealth = 0, HealthRatio = 0, TotalRemoteFires = 0, PhysicsCount = 0,
        ClientOwnedCount = 0, InstanceCount = 0, StreamedInCount = 0,
        HasEconomy = false, HasMatchState = false, IsGrounded = false, HasTool = false,
        AvgFireRate = 0, RecentDeltaHealth = 0, DiscreteHash = "",
    }
    if ws.Agents.LocalPlayer then
        sig.PlayerHealth = ws.Agents.LocalPlayer.Health or 0
        sig.HealthRatio = sig.PlayerHealth / math.max(ws.Agents.LocalPlayer.MaxHealth or 100, 1)
        sig.HasTool = ws.Agents.LocalPlayer.EquippedTool ~= nil
        sig.IsGrounded = tostring(ws.Agents.LocalPlayer.HumState):find("Running") ~= nil
    end
    local totalFires, hasEconomy = 0, false
    for _, r in ipairs(ws.Latent.RemoteEvents or {}) do
        totalFires = totalFires + r.FireCount
        local nl = r.Name:lower()
        if nl:find("coin") or nl:find("cash") or nl:find("gold") or nl:find("money") then hasEconomy = true end
    end
    sig.TotalRemoteFires = totalFires
    sig.HasEconomy = hasEconomy
    sig.PhysicsCount = #(ws.Physics.SimulatedAssemblies or {})
    sig.ClientOwnedCount = #(ws.Physics.ClientOwned or {})
    sig.InstanceCount = ws.ObjectGraph.TotalInstances or 0
    sig.StreamedInCount = #(ws.Network.StreamedIn or {})
    local matchCount = 0
    for _ in pairs(ws.Latent.MatchState or {}) do matchCount = matchCount + 1 end
    sig.HasMatchState = matchCount > 0
    sig.AvgFireRate = LivingWorldModel.TemporalAggregates.AvgRemoteFires or 0
    local lastDelta = LivingWorldModel.GetLatestDelta()
    if lastDelta then sig.RecentDeltaHealth = lastDelta.Delta.HealthChange or 0 end
    local healthBucket = math.floor(sig.HealthRatio * 4)
    local fireBucket = math.min(math.floor(sig.TotalRemoteFires / 10), 5)
    local physicsBucket = math.min(math.floor(sig.PhysicsCount / 20), 5)
    sig.DiscreteHash = string.format("%d_%d_%d_%s_%s", healthBucket, fireBucket, physicsBucket,
        sig.HasEconomy and "E" or "N", sig.HasMatchState and "M" or "N")
    return sig
end

function StateSignature.Canonicalize(sig) return sig.DiscreteHash end

function StateSignature.Distance(sigA, sigB)
    if not sigA or not sigB then return 1.0 end
    local diff = (sigA.HealthRatio - sigB.HealthRatio)^2
    diff = diff + ((sigA.TotalRemoteFires - sigB.TotalRemoteFires) / 100)^2
    diff = diff + ((sigA.PhysicsCount - sigB.PhysicsCount) / 50)^2
    diff = diff + (sigA.HasEconomy ~= sigB.HasEconomy and 0.25 or 0)
    diff = diff + (sigA.HasMatchState ~= sigB.HasMatchState and 0.25 or 0)
    return math.sqrt(diff)
end

-- ============================================================
-- MODULE 4: ENHANCED TRANSITION MODEL (ETM)
-- ============================================================
local ETM_CONFIG = {
    ConvergenceThreshold = 0.08, MinObservations = 10, MemoryDecay = 0.95,
    PriorAlpha = 1.0, PriorBeta = 1.0,
}

local EnhancedTransitionModel = {
    Table = {},
    GlobalStats = { TotalObservations = 0, GlobalSuccessRate = 0.5 },
}

if savedSession and savedSession.ETM then
    EnhancedTransitionModel.Table = savedSession.ETM.Table or {}
    EnhancedTransitionModel.GlobalStats = savedSession.ETM.GlobalStats or EnhancedTransitionModel.GlobalStats
end

function EnhancedTransitionModel.GetKey(cardID, stateSig)
    local sigKey = stateSig and stateSig.DiscreteHash or "GLOBAL"
    return cardID .. "_" .. sigKey
end

function EnhancedTransitionModel.GetOrInit(cardID, stateSig)
    local key = EnhancedTransitionModel.GetKey(cardID, stateSig)
    if not EnhancedTransitionModel.Table[key] then
        EnhancedTransitionModel.Table[key] = {
            alpha = ETM_CONFIG.PriorAlpha, beta = ETM_CONFIG.PriorBeta,
            n = 0, mean = 0.5, M2 = 0, StdDev = 0.5,
            Deltas = {}, Converged = false, LastUpdate = os.clock(),
        }
    end
    return EnhancedTransitionModel.Table[key]
end

function EnhancedTransitionModel.Update(cardID, stateSigBefore, stateSigAfter, success)
    local entry = EnhancedTransitionModel.GetOrInit(cardID, stateSigBefore)
    entry.alpha = entry.alpha * ETM_CONFIG.MemoryDecay
    entry.beta = entry.beta * ETM_CONFIG.MemoryDecay
    if success then entry.alpha = entry.alpha + 1 else entry.beta = entry.beta + 1 end
    local outcome = success and 1.0 or 0.0
    entry.n = entry.n + 1
    local delta1 = outcome - entry.mean
    entry.mean = entry.mean + delta1 / entry.n
    local delta2 = outcome - entry.mean
    entry.M2 = entry.M2 + delta1 * delta2
    if entry.n >= 2 then entry.StdDev = math.sqrt(entry.M2 / (entry.n - 1)) end
    if stateSigBefore and stateSigAfter then
        local stateDelta = {
            HealthChange = stateSigAfter.PlayerHealth - stateSigBefore.PlayerHealth,
            FireChange = stateSigAfter.TotalRemoteFires - stateSigBefore.TotalRemoteFires,
            Success = success,
        }
        table.insert(entry.Deltas, stateDelta)
        if #entry.Deltas > 20 then table.remove(entry.Deltas, 1) end
    end
    entry.Converged = entry.StdDev < ETM_CONFIG.ConvergenceThreshold and entry.n >= ETM_CONFIG.MinObservations
    entry.LastUpdate = os.clock()
    EnhancedTransitionModel.GlobalStats.TotalObservations = EnhancedTransitionModel.GlobalStats.TotalObservations + 1
    local gs = EnhancedTransitionModel.GlobalStats
    gs.GlobalSuccessRate = gs.GlobalSuccessRate * 0.99 + (success and 0.01 or 0)
    return entry
end

function EnhancedTransitionModel.Predict(cardID, stateSig)
    local entry = EnhancedTransitionModel.GetOrInit(cardID, stateSig)
    local p = entry.alpha / (entry.alpha + entry.beta)
    return {
        SuccessProbability = p, StdDev = entry.StdDev,
        Confidence = 1.0 - entry.StdDev, Converged = entry.Converged, Observations = entry.n,
    }
end

function EnhancedTransitionModel.Sample(cardID, stateSig)
    local entry = EnhancedTransitionModel.GetOrInit(cardID, stateSig)
    return SampleBeta(entry.alpha, entry.beta)
end

function EnhancedTransitionModel.GetConvergenceMap()
    local map = { Converged = 0, Total = 0 }
    for _, entry in pairs(EnhancedTransitionModel.Table) do
        map.Total = map.Total + 1
        if entry.Converged then map.Converged = map.Converged + 1 end
    end
    return map
end

function EnhancedTransitionModel.PredictStateDelta(cardID, stateSig)
    local entry = EnhancedTransitionModel.GetOrInit(cardID, stateSig)
    if #entry.Deltas == 0 then return { HealthChange = 0, FireChange = 0, Confidence = 0 } end
    local sumH, sumF, count = 0, 0, 0
    for _, d in ipairs(entry.Deltas) do
        if d.Success then sumH = sumH + d.HealthChange; sumF = sumF + d.FireChange; count = count + 1 end
    end
    if count == 0 then return { HealthChange = 0, FireChange = 0, Confidence = 0 } end
    return { HealthChange = sumH / count, FireChange = sumF / count, Confidence = count / #entry.Deltas }
end

-- ============================================================
-- MODULE 5: CAUSAL DEPENDENCY GRAPH (CDG)
-- ============================================================
local CDG_CONFIG = { EdgeDecay = 0.98, MinCoTotal = 3, CausalThreshold = 0.6, TemporalWindow = 10 }

local CausalDependencyGraph = { Edges = {}, ActionHistory = {} }

if savedSession and savedSession.CDG then
    CausalDependencyGraph.Edges = savedSession.CDG.Edges or {}
    CausalDependencyGraph.ActionHistory = savedSession.CDG.ActionHistory or {}
end

function CausalDependencyGraph.GetEdgeKey(cardA, cardB) return cardA .. "|" .. cardB end

function CausalDependencyGraph.GetOrInitEdge(cardA, cardB)
    local key = CausalDependencyGraph.GetEdgeKey(cardA, cardB)
    if not CausalDependencyGraph.Edges[key] then
        CausalDependencyGraph.Edges[key] = {
            FromCard = cardA, ToCard = cardB,
            coSuccess = 0, coFail = 0, coTotal = 0,
            correlation = 0, effectSize = 0, confidence = 0, lastTested = 0,
            temporal = { ABeforeB = 0, BBeforeA = 0 },
        }
    end
    return CausalDependencyGraph.Edges[key]
end

function CausalDependencyGraph.RecordAction(cardID, success)
    table.insert(CausalDependencyGraph.ActionHistory, { cardID = cardID, time = os.clock(), success = success })
    if #CausalDependencyGraph.ActionHistory > 100 then table.remove(CausalDependencyGraph.ActionHistory, 1) end
end

function CausalDependencyGraph.UpdateFromLog(log)
    local now = os.clock()
    for _, r in ipairs(log) do CausalDependencyGraph.RecordAction(r.Step.ID, r.Success) end
    for i = 1, #log do
        for j = i + 1, #log do
            local cardA, cardB = log[i].Step.ID, log[j].Step.ID
            local successA, successB = log[i].Success, log[j].Success
            local edge = CausalDependencyGraph.GetOrInitEdge(cardA, cardB)
            edge.coSuccess = edge.coSuccess * CDG_CONFIG.EdgeDecay
            edge.coFail = edge.coFail * CDG_CONFIG.EdgeDecay
            edge.coTotal = edge.coTotal * CDG_CONFIG.EdgeDecay + 1
            if successA and successB then edge.coSuccess = edge.coSuccess + 1 else edge.coFail = edge.coFail + 1 end
            edge.temporal.ABeforeB = edge.temporal.ABeforeB + 1
            if edge.coTotal >= CDG_CONFIG.MinCoTotal then
                local pAB = edge.coSuccess / edge.coTotal
                local pA = (edge.coSuccess + edge.coFail * 0.5) / edge.coTotal
                edge.correlation = (pAB - pA * pA) / math.max(math.sqrt(pA * (1 - pA) * pA * (1 - pA)), 0.01)
                edge.effectSize = pAB - (1 - pAB)
                edge.confidence = math.min(edge.coTotal / 10, 1.0)
            end
            edge.lastTested = now
        end
    end
end

function CausalDependencyGraph.GetCausalScore(cardA, cardB)
    local edge = CausalDependencyGraph.Edges[CausalDependencyGraph.GetEdgeKey(cardA, cardB)]
    if not edge or edge.coTotal < CDG_CONFIG.MinCoTotal then return 0, 0 end
    local conditionalSuccess = edge.coSuccess / edge.coTotal
    local temporalBias = edge.temporal.ABeforeB / math.max(edge.temporal.ABeforeB + edge.temporal.BBeforeA, 1)
    return conditionalSuccess * 0.7 + temporalBias * 0.3, edge.confidence
end

function CausalDependencyGraph.GetCausalChainOrder(cards)
    local scored = {}
    for _, card in ipairs(cards) do
        local totalCausalScore = 0
        for _, other in ipairs(cards) do
            if other.ID ~= card.ID then
                local score, conf = CausalDependencyGraph.GetCausalScore(card.ID, other.ID)
                totalCausalScore = totalCausalScore + score * conf
            end
        end
        table.insert(scored, { Card = card, CausalScore = totalCausalScore })
    end
    table.sort(scored, function(a, b) return a.CausalScore > b.CausalScore end)
    local ordered = {}
    for _, s in ipairs(scored) do table.insert(ordered, s.Card) end
    return ordered
end

function CausalDependencyGraph.GetStats()
    local stats = { TotalEdges = 0, StrongEdges = 0, AvgCorrelation = 0 }
    local sumCorr = 0
    for _, edge in pairs(CausalDependencyGraph.Edges) do
        stats.TotalEdges = stats.TotalEdges + 1
        sumCorr = sumCorr + math.abs(edge.correlation)
        if edge.correlation > CDG_CONFIG.CausalThreshold then stats.StrongEdges = stats.StrongEdges + 1 end
    end
    if stats.TotalEdges > 0 then stats.AvgCorrelation = sumCorr / stats.TotalEdges end
    return stats
end

-- ============================================================
-- WORLD STATE (Module 1)
-- ============================================================
local WorldState = {}
local WS_CHUNK = 500

local RAE_State = {
    Phase = "IDLE", WorldState = nil, Cards = {}, SelectedCards = {},
    LastPlan = nil, LastLog = nil, CycleCount = 0, _IndexMap = {},
    ETMConvergence = { Converged = 0, Total = 0 },
    CDGStats = { TotalEdges = 0, StrongEdges = 0 },
    CalibrationStats = { BrierScore = 0, Accuracy = 0 },
}

local RAE_Callbacks = { OnPhase=nil, OnScan=nil, OnPlan=nil, OnCommit=nil }
local RAE_SilentMode = false

local function CaptureWorldState()
    local T = os.clock()
    local lp = Players.LocalPlayer
    local char = lp and lp.Character
    local state = {
        T = T,
        SimConfig = {
            ServerTime = Workspace:GetServerTimeNow(), FrameStep = T, Gravity = Workspace.Gravity,
            StreamingEnabled = Workspace.StreamingEnabled,
            StreamingRadius = (function() local ok, val = pcall(function() return Workspace.StreamingTargetRadius end); return ok and val or 0 end)(),
            NetworkOwnerRate = 1/60,
        },
        ObjectGraph = { TotalInstances=0, ScriptCount=0, EnabledScripts=0, DisabledScripts=0, TaggedInstances={}, AttributeMap={} },
        Physics = { SimulatedAssemblies={}, ClientOwned={}, ServerOwned={}, TotalMass=0 },
        Agents = { LocalPlayer=nil, OtherPlayers={} },
        Latent = { RemoteEvents={}, RemoteFunctions={}, BindableEvents={}, ObservedFires={}, ValueObjects={}, MatchState={}, SpawnerState={} },
        Network = { ReplicatedInstances=0, StreamedIn={}, StreamedOut={}, OwnershipMap={}, PendingRemotes={}, ReplicationLag=0 },
    }

    local knownRemotes = {}
    if RAE_State and RAE_State.WorldState then
        for _, entry in ipairs(RAE_State.WorldState.Latent.RemoteEvents or {}) do
            knownRemotes[entry.Name] = entry
        end
    end

    local allDesc = game:GetDescendants()
    local n = 0
    for _, obj in ipairs(allDesc) do
        state.ObjectGraph.TotalInstances = state.ObjectGraph.TotalInstances + 1
        local cls = obj.ClassName
        if cls == "Script" or cls == "LocalScript" then
            state.ObjectGraph.ScriptCount = state.ObjectGraph.ScriptCount + 1
            if obj.Enabled then state.ObjectGraph.EnabledScripts = state.ObjectGraph.EnabledScripts + 1
            else state.ObjectGraph.DisabledScripts = state.ObjectGraph.DisabledScripts + 1 end
        elseif cls == "ModuleScript" then
            state.ObjectGraph.ScriptCount = state.ObjectGraph.ScriptCount + 1
            state.ObjectGraph.EnabledScripts = state.ObjectGraph.EnabledScripts + 1
        elseif cls == "IntValue" or cls == "NumberValue" or cls == "BoolValue" or cls == "StringValue" then
            table.insert(state.Latent.ValueObjects, { Name=obj.Name, Path=obj:GetFullName(), Value=obj.Value, Class=cls })
        end
        local tags = obj:GetTags()
        if #tags > 0 then table.insert(state.ObjectGraph.TaggedInstances, { Instance=obj, Name=obj.Name, Path=obj:GetFullName(), Tags=tags }) end
        n = n + 1
        if n >= WS_CHUNK then n = 0; task.wait() end
    end

    local wsDesc = Workspace:GetDescendants()
    n = 0
    local physCap = 0
    for _, obj in ipairs(wsDesc) do
        if obj:IsA("BasePart") then
            state.Physics.TotalMass = state.Physics.TotalMass + obj.AssemblyMass
            if not obj.Anchored and physCap < 200 then
                physCap = physCap + 1
                local entry = { Instance=obj, Name=obj.Name, Path=obj:GetFullName(), CFrame=obj.CFrame, Velocity=obj.AssemblyLinearVelocity, AngularVel=obj.AssemblyAngularVelocity, Mass=obj.AssemblyMass, Anchored=false, CanCollide=obj.CanCollide }
                table.insert(state.Physics.SimulatedAssemblies, entry)
                local ok, owner = pcall(function() return obj:GetNetworkOwner() end)
                if ok then
                    if owner == lp then table.insert(state.Physics.ClientOwned, entry); state.Network.OwnershipMap[obj:GetFullName()] = "CLIENT"
                    else table.insert(state.Physics.ServerOwned, entry); state.Network.OwnershipMap[obj:GetFullName()] = "SERVER" end
                end
            end
        end
        n = n + 1
        if n >= WS_CHUNK then n = 0; task.wait() end
    end

    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        local tool = char:FindFirstChildOfClass("Tool")
        state.Agents.LocalPlayer = {
            Name=lp.Name, UserId=lp.UserId, Team=lp.Team and lp.Team.Name or "None",
            CFrame=hrp and hrp.CFrame or CFrame.new(), Velocity=hrp and hrp.AssemblyLinearVelocity or Vector3.new(),
            Health=hum and hum.Health or 0, MaxHealth=hum and hum.MaxHealth or 100,
            WalkSpeed=hum and hum.WalkSpeed or 16, JumpPower=hum and hum.JumpPower or 50,
            HumState=hum and tostring(hum:GetState()) or "Unknown", EquippedTool=tool and tool.Name or nil,
        }
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local pChar=p.Character; local pHRP=pChar and pChar:FindFirstChild("HumanoidRootPart"); local pHum=pChar and pChar:FindFirstChildOfClass("Humanoid")
            table.insert(state.Agents.OtherPlayers, { Name=p.Name, UserId=p.UserId, Team=p.Team and p.Team.Name or "None", CFrame=pHRP and pHRP.CFrame or CFrame.new(), Health=pHum and pHum.Health or 0, MaxHealth=pHum and pHum.MaxHealth or 100 })
        end
    end

    local queue = { {node=ReplicatedStorage, depth=0}, {node=Workspace, depth=0} }
    local qi = 1; n = 0
    while qi <= #queue do
        local item = queue[qi]; qi = qi + 1
        local parent = item.node; local depth = item.depth
        if depth <= 6 then
            local ok, children = pcall(function() return parent:GetChildren() end)
            if ok then
                for _, child in ipairs(children) do
                    local cls = child.ClassName
                    if cls == "RemoteEvent" then
                        local existing = knownRemotes[child.Name]
                        if existing and existing.Instance == child then table.insert(state.Latent.RemoteEvents, existing)
                        else
                            local entry = { Instance=child, Name=child.Name, Path=child:GetFullName(), FireCount=0, LastArgs=nil, LastFire=0 }
                            table.insert(state.Latent.RemoteEvents, entry)
                            child.OnClientEvent:Connect(function(...) entry.FireCount=entry.FireCount+1; entry.LastArgs={...}; entry.LastFire=os.clock(); table.insert(state.Latent.ObservedFires, { Remote=child.Name, Args={...}, Time=os.clock() }) end)
                        end
                    elseif cls == "RemoteFunction" then table.insert(state.Latent.RemoteFunctions, { Instance=child, Name=child.Name, Path=child:GetFullName() })
                    elseif cls == "BindableEvent" then table.insert(state.Latent.BindableEvents, { Instance=child, Name=child.Name, Path=child:GetFullName() }) end
                    local nl = child.Name:lower()
                    if nl:find("match") or nl:find("game") or nl:find("round") or nl:find("phase") or nl:find("timer") then state.Latent.MatchState[child.Name] = { Instance=child, Class=cls, Path=child:GetFullName() } end
                    if nl:find("spawn") or nl:find("wave") then state.Latent.SpawnerState[child.Name] = { Instance=child, Class=cls, Path=child:GetFullName() } end
                    table.insert(queue, { node=child, depth=depth+1 })
                    n = n + 1
                    if n >= WS_CHUNK then n = 0; task.wait() end
                end
            end
        end
    end

    state.Network.ReplicatedInstances = state.ObjectGraph.TotalInstances
    LivingWorldModel.AddSnapshot(state)
    return state
end
WorldState.Capture = CaptureWorldState

-- ============================================================
-- CARD GENESIS
-- ============================================================
local CardGenesis = {}
local function NewCard(channel, name, description, preconditions, action, expectedOutcome, cost, metadata)
    return { ID=tostring(math.random(1e8,9e8)), Channel=channel, Name=name, Description=description, Preconditions=preconditions or {}, Action=action, ExpectedOutcome=expectedOutcome, Cost=cost or { CPU="low", Network="none", Disruption="none" }, Metadata=metadata or {}, TelemetryLog={}, Born=os.clock() }
end

local function PreCondAlwaysTrue() return true, "No preconditions." end
local function PreCondInstanceExists(instance)
    return function() local ok=pcall(function() return instance.Parent~=nil end); return ok, ok and "Instance exists." or "Instance missing." end
end

local SEMANTIC_TAGS = {
    Economy={"coin","cash","money","gem","gold","credit","balance","point","currency","reward","earn","pay","buy","purchase","shop","cost"},
    Heal={"heal","health","hp","regen","revive","respawn","medkit"}, Damage={"damage","hurt","hit","attack","strike","kill","death"},
    Movement={"teleport","tp","move","position","warp","dash","blink","cframe","jump"}, Cooldown={"cooldown","timer","daily","claim","stamp","elapsed","reset","delay"},
    Admin={"kick","ban","admin","rank","mod","promote","demote","execute","run"}, Save={"save","load","data","store","sync","persist","datastore"},
    Crafting={"craft","recipe","forge","combine","brew","upgrade","build"}, Loot={"loot","crate","box","spin","open","roll","drop","chest","unbox"},
    Trade={"trade","offer","accept","swap","exchange","deal"},
}

local function ClassifyRemote(name)
    local nl = name:lower()
    for tag, patterns in pairs(SEMANTIC_TAGS) do for _, p in ipairs(patterns) do if nl:find(p) then return tag end end end
    return "General"
end

local function GenStructural(ws, cards)
    local og = ws.ObjectGraph
    if not og or og.TotalInstances == 0 then return end
    table.insert(cards, NewCard("Structural", "Architecture Profile", string.format("%d instances | %d scripts", og.TotalInstances, og.ScriptCount), {PreCondAlwaysTrue}, function(outputs) outputs = outputs or {}; outputs["Structural"] = { TotalInstances = og.TotalInstances, ScriptCount = og.ScriptCount }; return outputs["Structural"] end, "Caches architectural context.", {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
end

local function GenMetabolic(ws, cards)
    local sc = ws.SimConfig
    if not sc then return end
    table.insert(cards, NewCard("Metabolic", "Simulation Config", string.format("Gravity:%.1f | Streaming:%s", sc.Gravity, tostring(sc.StreamingEnabled)), {PreCondAlwaysTrue}, function(outputs) outputs = outputs or {}; outputs["Metabolic"] = { Gravity = Workspace.Gravity, ServerTime = Workspace:GetServerTimeNow() }; return outputs["Metabolic"] end, "Captures live physics config.", {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
end

local function GenPhysics(ws, cards)
    local phys = ws.Physics
    if not phys then return end
    for _, entry in ipairs(phys.ClientOwned or {}) do
        if entry.Instance and entry.Instance.Parent then
            table.insert(cards, NewCard("Ownership", "Client Part: "..entry.Name, string.format("Mass:%.1f | Vel:%.1f", entry.Mass, entry.Velocity.Magnitude), {PreCondInstanceExists(entry.Instance)}, function(outputs) local part = entry.Instance; if not part or not part.Parent then return {Error="Part missing"} end; outputs = outputs or {}; outputs["Physics_"..entry.Name] = { Position=part.Position }; return outputs["Physics_"..entry.Name] end, "Reads client-owned physics.", {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=90}))
        end
    end
end

local function GenLatent(ws, cards)
    local lat = ws.Latent
    if not lat then return end
    for _, remote in ipairs(lat.RemoteEvents or {}) do
        local inst = remote.Instance
        local observed = remote.FireCount > 0
        local semantic = ClassifyRemote(remote.Name)
        local conf = observed and math.min(50 + remote.FireCount * 10, 90) or 35
        local currentSig = StateSignature.Extract(ws)
        local etmPred = EnhancedTransitionModel.Predict(remote.Name, currentSig)
        if etmPred.Converged then conf = math.floor(etmPred.SuccessProbability * 100) end
        table.insert(cards, NewCard("Replication", string.format("[%s] %s", semantic, remote.Name), observed and string.format("Observed %d fires. ETM: %.0f%%", remote.FireCount, etmPred.SuccessProbability * 100) or "Not yet observed.", {PreCondInstanceExists(inst)}, function(outputs) local ok, result = pcall(function() if observed and remote.LastArgs and #remote.LastArgs > 0 then inst:FireServer(unpack(remote.LastArgs)); return { Action="Replay", Remote=remote.Name } else inst:FireServer(); return { Action="Probe", Remote=remote.Name } end end); return ok and result or {Error = tostring(result)} end, observed and "Replay at server." or "Probe-fire.", {CPU="low", Network=observed and "medium" or "low", Disruption=observed and "medium" or "low"}, {Risk=observed and "Medium" or "Low", Confidence=conf, Semantic=semantic, ETMConverged=etmPred.Converged}))
    end
    for _, rfunc in ipairs(lat.RemoteFunctions or {}) do
        local inst = rfunc.Instance
        table.insert(cards, NewCard("Replication", string.format("[Fn] %s", rfunc.Name), "RemoteFunction — InvokeServer.", {PreCondInstanceExists(inst)}, function(outputs) local ok, result = pcall(function() local ret = inst:InvokeServer(); outputs = outputs or {}; outputs["RF_"..rfunc.Name] = ret; return { Action="Invoke", Remote=rfunc.Name } end); return ok and result or {Error = tostring(result)} end, "Invokes RemoteFunction.", {CPU="low", Network="medium", Disruption="low"}, {Risk="Low", Confidence=45}))
    end
end

local function GenAgents(ws, cards)
    local agents = ws.Agents
    if not agents or not agents.LocalPlayer then return end
    local lp = agents.LocalPlayer
    table.insert(cards, NewCard("Agent", "Local Player Sync", string.format("%s | HP:%.0f/%.0f", lp.Name, lp.Health, lp.MaxHealth), {PreCondAlwaysTrue}, function(outputs) local char = Players.LocalPlayer.Character; local hum = char and char:FindFirstChildOfClass("Humanoid"); if not hum then return {Error="No humanoid"} end; outputs = outputs or {}; outputs["AgentState"] = { Health=hum.Health }; return outputs["AgentState"] end, "Snapshots local player.", {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
end

local function GenNetwork(ws, cards)
    local net = ws.Network; local lat = ws.Latent
    if not net or not lat then return end
    local totalRemotes = #(lat.RemoteEvents or {}) + #(lat.RemoteFunctions or {})
    if totalRemotes > 0 then
        local observed = 0
        for _, r in ipairs(lat.RemoteEvents or {}) do if r.FireCount > 0 then observed = observed + 1 end end
        table.insert(cards, NewCard("Network", "Network Surface", string.format("%d remotes (%d observed)", totalRemotes, observed), {PreCondAlwaysTrue}, function(outputs) outputs = outputs or {}; outputs["NetworkSurface"] = { TotalRemotes=totalRemotes, Observed=observed }; return outputs["NetworkSurface"] end, "Summarizes network surface.", {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=95}))
    end
end

function CardGenesis.Generate(ws)
    assert(ws, "[RAE:Genesis] Requires WorldState.")
    local cards={}
    GenStructural(ws,cards); GenMetabolic(ws,cards); GenPhysics(ws,cards)
    GenLatent(ws,cards); GenAgents(ws,cards); GenNetwork(ws,cards)
    table.sort(cards, function(a,b) return (a.Metadata.Confidence or 0)>(b.Metadata.Confidence or 0) end)
    return cards
end

-- ============================================================
-- MODULE 6: VALUE SYSTEM
-- ============================================================
local ValueWeights = { Reliability=1.0, InformationGain=0.8, Cost=0.7, Reversibility=0.9, Optionality=0.7, Stability=0.8 }
local ValueHistory = { WeightUpdates=0 }
local COST_SCORES = { none=1.0, low=0.85, medium=0.65, high=0.40 }
if savedSession and savedSession.ValueWeights then ValueWeights = savedSession.ValueWeights end

local ValueSystem = {}
function ValueSystem.ScoreCard(card, allCards, intelHistory)
    local h = intelHistory and intelHistory[card.ID]
    local reliability = h and (h.alpha/(h.alpha+h.beta)) or (card.Metadata.Confidence or 50)/100
    local currentSig = RAE_State and RAE_State.WorldState and StateSignature.Extract(RAE_State.WorldState) or nil
    local etmPred = EnhancedTransitionModel.Predict(card.ID, currentSig)
    if etmPred.Converged then reliability = etmPred.SuccessProbability * 0.7 + reliability * 0.3 end
    local conf = card.Metadata.Confidence or 50
    local infoGain = 1.0 - (conf/100)*0.6
    local cpu=COST_SCORES[card.Cost and card.Cost.CPU or "none"] or 1.0
    local net=COST_SCORES[card.Cost and card.Cost.Network or "none"] or 1.0
    local dis=COST_SCORES[card.Cost and card.Cost.Disruption or "none"] or 1.0
    local costScore=(cpu+net+dis)/3
    local risk=card.Metadata.Risk or "None"
    local reversibility = risk=="None" and 1.0 or risk=="Low" and 0.85 or risk=="Medium" and 0.60 or 0.30
    local downstream=0; for _, o in ipairs(allCards) do if o.Channel~=card.Channel then downstream=downstream+1 end end
    local optionality=math.clamp(downstream/math.max(#allCards,1),0,1)
    local stability = dis==1.0 and 1.0 or dis==0.85 and 0.80 or dis==0.65 and 0.55 or 0.25
    local totalWeight=0; for _,w in pairs(ValueWeights) do totalWeight=totalWeight+w end
    local score=(reliability*ValueWeights.Reliability + infoGain*ValueWeights.InformationGain + costScore*ValueWeights.Cost + reversibility*ValueWeights.Reversibility + optionality*ValueWeights.Optionality + stability*ValueWeights.Stability)/totalWeight
    return { Total=score, Reliability=reliability, InfoGain=infoGain, Cost=costScore, Reversibility=reversibility, Optionality=optionality, Stability=stability, ETMConverged=etmPred.Converged }
end

function ValueSystem.AdaptWeights(log, allCards)
    ValueHistory.WeightUpdates=ValueHistory.WeightUpdates+1
    for _, result in ipairs(log) do
        local axisScores=ValueSystem.ScoreCard(result.Step, allCards, nil)
        local axisMap={ Reliability=axisScores.Reliability, InformationGain=axisScores.InfoGain, Cost=axisScores.Cost, Reversibility=axisScores.Reversibility, Optionality=axisScores.Optionality, Stability=axisScores.Stability }
        for axis, score in pairs(axisMap) do
            local delta=result.Success and (score*0.02) or -(score*0.03)
            ValueWeights[axis]=math.clamp((ValueWeights[axis] or 1.0)+delta, 0.1, 2.0)
        end
    end
end

-- ============================================================
-- MODULE 9: INTELLIGENCE v4
-- ============================================================
local Intel = {}
local CFG_INTEL = { MemoryDecayRate=0.88, PhaseShiftThreshold=0.25, OverfitDetectionWindow=4, VariancePenaltyCoeff=0.35 }
local IntelMem = {
    CardHistory={}, ChannelTimeseries={ Structural={},Metabolic={},Ownership={},Replication={},Latent={},Agent={},Network={} },
    ChannelWeights={ Structural=1.0,Metabolic=1.0,Ownership=1.0,Replication=1.0,Latent=1.0,Agent=1.0,Network=1.0 },
    FailureHeuristics={}, CalibrationLog={}, PhaseShifts={}, OverfitStreak=0, Cycles=0,
    CalibrationBuckets = {}, BrierScore = 0, BrierHistory = {},
}
if savedSession and savedSession.IntelMem then IntelMem = savedSession.IntelMem end

local function GetOrInitCard(id, initConf)
    if not IntelMem.CardHistory[id] then
        local p=math.clamp(initConf/100,0.01,0.99); local scale=8
        IntelMem.CardHistory[id]={ alpha=p*scale,beta=(1-p)*scale, n=0,mean=p,M2=0.0,StdDev=0.0, Timeline={},Confidence=initConf }
    end
    return IntelMem.CardHistory[id]
end

local function WelfordUpdate(h,v)
    h.n=h.n+1; local d1=v-h.mean; h.mean=h.mean+d1/h.n; local d2=v-h.mean; h.M2=h.M2+d1*d2
    if h.n>=2 then h.StdDev=math.sqrt(h.M2/(h.n-1)) end
end

local function UpdatePosterior(h,success)
    h.alpha=h.alpha*CFG_INTEL.MemoryDecayRate; h.beta=h.beta*CFG_INTEL.MemoryDecayRate
    if success then h.alpha=h.alpha+1 else h.beta=h.beta+1 end
    h.Confidence=(h.alpha/(h.alpha+h.beta))*100
end

local function UpdateCalibration(predicted, actual)
    local bucket = math.floor(predicted * 10)
    if not IntelMem.CalibrationBuckets[bucket] then IntelMem.CalibrationBuckets[bucket] = { correct = 0, total = 0 } end
    local b = IntelMem.CalibrationBuckets[bucket]
    b.total = b.total + 1
    if (predicted >= 0.5 and actual) or (predicted < 0.5 and not actual) then b.correct = b.correct + 1 end
    local brierContrib = (predicted - (actual and 1 or 0))^2
    IntelMem.BrierScore = IntelMem.BrierScore * 0.95 + brierContrib * 0.05
    table.insert(IntelMem.BrierHistory, { time = os.clock(), score = brierContrib })
    if #IntelMem.BrierHistory > 100 then table.remove(IntelMem.BrierHistory, 1) end
end

local function ThompsonScore(card, h)
    local sample=SampleBeta(math.max(h.alpha,0.1),math.max(h.beta,0.1))
    local vp=h.StdDev*CFG_INTEL.VariancePenaltyCoeff
    local cw=IntelMem.ChannelWeights[card.Channel] or 1.0
    local pd=1.0
    for _, s in ipairs(IntelMem.PhaseShifts) do if s.Channel==card.Channel and IntelMem.Cycles-s.Cycle<=2 then pd=0.75; break end end
    local pat=card.Channel..":"..(card.Metadata.Condition or "general")
    local fh=IntelMem.FailureHeuristics[pat]
    local fp=fh and fh.penalty or 0.0
    local etmBonus = card.Metadata.ETMConverged and 0.1 or 0
    return math.max((sample-vp)*cw*pd*(1-fp) + etmBonus, 0.0)
end

function Intel.SelectStrategy(cards)
    local scored={}
    for _, card in ipairs(cards) do
        local h=GetOrInitCard(card.ID, card.Metadata.Confidence or 50)
        table.insert(scored, { Card=card, Score=ThompsonScore(card,h), Mean=h.alpha/(h.alpha+h.beta) })
    end
    table.sort(scored, function(a,b) return a.Score>b.Score end)
    local w=scored[1]
    local strategy=(w and w.Mean>=0.60) and "EXPLOIT" or "EXPLORE"
    return scored, strategy
end

function Intel.ProcessFeedback(log, cards)
    IntelMem.Cycles=IntelMem.Cycles+1; local cycle=IntelMem.Cycles
    local chR={}
    for _, r in ipairs(log) do local ch=r.Step.Channel; if not chR[ch] then chR[ch]={total=0,success=0} end; chR[ch].total=chR[ch].total+1; if r.Success then chR[ch].success=chR[ch].success+1 end end
    for ch, data in pairs(chR) do if IntelMem.ChannelTimeseries[ch] then local rate=data.success/math.max(data.total,1); table.insert(IntelMem.ChannelTimeseries[ch], rate); if #IntelMem.ChannelTimeseries[ch]>10 then table.remove(IntelMem.ChannelTimeseries[ch],1) end end end
    for _, r in ipairs(log) do
        local card=r.Step; local h=GetOrInitCard(card.ID, card.Metadata.Confidence or 50)
        table.insert(h.Timeline, {result=r.Success,cycle=cycle})
        WelfordUpdate(h, r.Success and 1.0 or 0.0)
        UpdatePosterior(h, r.Success)
        local predicted = (card.Metadata.Confidence or 50) / 100
        UpdateCalibration(predicted, r.Success)
        card.Metadata.Confidence=math.floor(h.Confidence)
        if not r.Success then
            local pat=card.Channel..":"..(card.Metadata.Condition or "general")
            if not IntelMem.FailureHeuristics[pat] then IntelMem.FailureHeuristics[pat]={count=0,penalty=0.0} end
            local fh=IntelMem.FailureHeuristics[pat]; fh.count=fh.count+1; fh.penalty=math.min(fh.penalty*CFG_INTEL.MemoryDecayRate+0.15, 0.80)
        end
        local cw=IntelMem.ChannelWeights[card.Channel] or 1.0
        IntelMem.ChannelWeights[card.Channel]=math.clamp(cw+(r.Success and 0.04 or -0.07),0.2,2.0)
        local s=IntelMem.ChannelTimeseries[card.Channel]
        if s and #s>=4 then local rM=(s[#s]+s[#s-1])/2; local pM=(s[#s-2]+s[#s-3])/2; if pM-rM>=CFG_INTEL.PhaseShiftThreshold then table.insert(IntelMem.PhaseShifts, {Channel=card.Channel,Cycle=cycle,PriorMean=pM,RecentMean=rM}) end end
        table.insert(IntelMem.CalibrationLog, {Predicted=(card.Metadata.Confidence or 50)/100,Actual=r.Success and 1 or 0,Cycle=cycle})
    end
    CausalDependencyGraph.UpdateFromLog(log)
end

function Intel.GetMemory() return IntelMem end

function Intel.GetCalibrationStats()
    local stats = { BrierScore = IntelMem.BrierScore, BucketAccuracy = {}, OverallAccuracy = 0, TotalPredictions = 0 }
    local totalCorrect, totalTotal = 0, 0
    for bucket, data in pairs(IntelMem.CalibrationBuckets) do
        stats.BucketAccuracy[bucket] = data.total > 0 and (data.correct / data.total) or 0
        totalCorrect = totalCorrect + data.correct; totalTotal = totalTotal + data.total
    end
    stats.TotalPredictions = totalTotal
    stats.OverallAccuracy = totalTotal > 0 and (totalCorrect / totalTotal) or 0
    return stats
end

-- ============================================================
-- DYNAMICS & TRANSITION MODELS
-- ============================================================
local DynamicsTable={}
local DynamicsModel={}

function DynamicsModel.Record(cardID, wsBefore, wsAfter, success)
    if not DynamicsTable[cardID] then DynamicsTable[cardID]={Deltas={},Successes=0,Attempts=0} end
    local e=DynamicsTable[cardID]; e.Attempts=e.Attempts+1
    if success then e.Successes=e.Successes+1 end
    local sigBefore = StateSignature.Extract(wsBefore)
    local sigAfter = StateSignature.Extract(wsAfter)
    EnhancedTransitionModel.Update(cardID, sigBefore, sigAfter, success)
end

local TransitionTable={}
local TransitionModel={}

function TransitionModel.Update(log)
    for i=1,#log-1 do
        local prev=log[i]; local nxt=log[i+1]
        local prevID, nextID = prev.Step.ID, nxt.Step.ID
        if not TransitionTable[prevID] then TransitionTable[prevID]={} end
        if not TransitionTable[prevID][nextID] then TransitionTable[prevID][nextID]={aGivenS=1.0,bGivenS=1.0,aGivenF=1.0,bGivenF=1.0,observations=0} end
        local pair = TransitionTable[prevID][nextID]
        pair.observations=pair.observations+1
        if prev.Success then if nxt.Success then pair.aGivenS=pair.aGivenS+1 else pair.bGivenS=pair.bGivenS+1 end
        else if nxt.Success then pair.aGivenF=pair.aGivenF+1 else pair.bGivenF=pair.bGivenF+1 end end
    end
end

-- ============================================================
-- MODULE 7: MCTS PLANNER
-- ============================================================
local MCTS_CONFIG = { Iterations = 50, ExplorationConstant = 1.4, RolloutDepth = 5, DiscountFactor = 0.95, RiskAversion = 0.3 }

local Planner = {}

function Planner.SimulateRollout(startCard, cards, currentSig, depth)
    local totalValue = 0
    local discount = 1.0
    local currentCard = startCard
    for d = 1, math.min(depth, MCTS_CONFIG.RolloutDepth) do
        local etmPred = EnhancedTransitionModel.Predict(currentCard.ID, currentSig)
        local success = math.random() < etmPred.SuccessProbability
        local cardValue = ValueSystem.ScoreCard(currentCard, cards, IntelMem.CardHistory)
        local stepValue = cardValue.Total * (success and 1.0 or 0.2)
        totalValue = totalValue + stepValue * discount
        discount = discount * MCTS_CONFIG.DiscountFactor
        if #cards > 1 then currentCard = cards[math.random(1, #cards)] end
    end
    return totalValue
end

function Planner.Plan(cards, lastLog, cardHistory)
    if not cards or #cards == 0 then return {} end
    local currentSig = RAE_State and RAE_State.WorldState and StateSignature.Extract(RAE_State.WorldState) or nil
    local orderedCards = CausalDependencyGraph.GetCausalChainOrder(cards)
    local scored, strategy = Intel.SelectStrategy(orderedCards)
    local plan = {}
    for i, entry in ipairs(scored) do
        if i <= 5 then
            local etmPred = EnhancedTransitionModel.Predict(entry.Card.ID, currentSig)
            table.insert(plan, { Card = entry.Card, ExpectedValue = entry.Score, Confidence = entry.Mean, Variance = 0, ETMPrediction = etmPred.SuccessProbability })
        end
    end
    return plan
end

-- ============================================================
-- MODULE 8: EXECUTOR
-- ============================================================
local CausalOrder={"Structural","Metabolic","Ownership","Replication","Latent","Agent","Network"}

local Executor={}

local function ValidatePreconditions(card, ws)
    for _, pre in ipairs(card.Preconditions or {}) do local ok, reason=pre(ws); if not ok then return false, reason or "Precondition failed." end end
    return true, "OK"
end

local function ResolveDeps(selected, all)
    local required={}; for _,c in ipairs(selected) do required[c.Channel]=true end
    local chIdx={}; for i,ch in ipairs(CausalOrder) do chIdx[ch]=i end
    for ch in pairs(required) do local idx=chIdx[ch] or 0; for i=1,idx-1 do required[CausalOrder[i]]=true end end
    local chain={}; local seen={}
    for _,ch in ipairs(CausalOrder) do if required[ch] then for _,card in ipairs(all) do if card.Channel==ch and not seen[card.ID] then table.insert(chain,card); seen[card.ID]=true; break end end end end
    for _,card in ipairs(selected) do if not seen[card.ID] then table.insert(chain,card); seen[card.ID]=true end end
    return chain
end

local function IsHighStakes(chain)
    for _,card in ipairs(chain) do local risk=card.Metadata.Risk or "None"; if risk=="High" or risk=="Medium" then return true end; if card.Cost and (card.Cost.Disruption=="high" or card.Cost.Disruption=="medium") then return true end end
    return false
end

local function ExecuteFastPath(chain, ws)
    local log={}; local outputs={}
    for i, card in ipairs(chain) do
        if card._Skip then continue end
        local valid, reason=ValidatePreconditions(card, ws)
        if not valid then table.insert(log, {Step=card,Success=false,Reason=reason,Time=os.clock()}); table.insert(card.TelemetryLog, {success=false,reason=reason,t=os.clock()}); continue end
        local success, output=pcall(function() return card.Action(outputs) end)
        local entry={Step=card,Success=success,Output=success and output or nil,Reason=success and "OK" or tostring(output),Time=os.clock()}
        table.insert(log, entry); table.insert(card.TelemetryLog, {success=success,t=os.clock()})
        if success and output then outputs[card.Channel]=output end
        task.wait()
    end
    return log
end

local function ExecuteStagedPath(chain, ws)
    local log={}; local outputs={}
    for i, card in ipairs(chain) do
        if card._Skip then continue end
        local valid, reason=ValidatePreconditions(card, ws)
        if not valid then table.insert(log, {Step=card,Success=false,Reason="[OBSERVE] "..reason,Time=os.clock(),Stage="Observe"}); continue end
        local probeOK = true
        if card.Metadata.Risk == "High" then
            local etmPred = EnhancedTransitionModel.Predict(card.ID, StateSignature.Extract(ws))
            if etmPred.SuccessProbability < 0.3 and etmPred.Converged then
                probeOK = false
                table.insert(log, {Step=card,Success=false,Reason="[PROBE] ETM predicts low success",Time=os.clock(),Stage="Probe"})
            end
        end
        if not probeOK then continue end
        local success, output=pcall(function() return card.Action(outputs) end)
        local entry={Step=card,Success=success,Output=success and output or nil,Reason=success and "[COMMIT] OK" or "[COMMIT] "..tostring(output),Time=os.clock(),Stage="Commit"}
        table.insert(log, entry); table.insert(card.TelemetryLog, {success=success,t=os.clock()})
        if success and output then outputs[card.Channel]=output end
        task.wait(0.1)
    end
    return log
end

function Executor.Preview(selected, all) local chain=ResolveDeps(selected, all); return chain, IsHighStakes(chain) end
function Executor.Execute(selected, all, ws) local chain=ResolveDeps(selected, all); return IsHighStakes(chain) and ExecuteStagedPath(chain, ws) or ExecuteFastPath(chain, ws) end

-- ============================================================
-- RAE CONTROL FUNCTIONS
-- ============================================================
local function RAE_SetPhase(phase) RAE_State.Phase = phase; if RAE_Callbacks.OnPhase then RAE_Callbacks.OnPhase(phase) end end

local function RAE_Scan()
    RAE_SetPhase("SCANNING")
    local ws = WorldState.Capture()
    RAE_State.WorldState = ws
    local confidence = 0
    if ws.ObjectGraph.TotalInstances > 0 then confidence = confidence + 30 end
    if #ws.Latent.RemoteEvents > 0 then confidence = confidence + 30 end
    if ws.Agents.LocalPlayer then confidence = confidence + 20 end
    if confidence < 40 then RAE_SetPhase("DORMANT"); return false end
    local cards = CardGenesis.Generate(ws)
    RAE_State.Cards = cards
    local idx = 1; RAE_State._IndexMap = {}
    for _, card in ipairs(cards) do RAE_State._IndexMap[idx] = card; idx = idx + 1 end
    RAE_State.ETMConvergence = EnhancedTransitionModel.GetConvergenceMap()
    RAE_State.CDGStats = CausalDependencyGraph.GetStats()
    RAE_State.CalibrationStats = Intel.GetCalibrationStats()
    RAE_SetPhase("READY")
    if RAE_Callbacks.OnScan then RAE_Callbacks.OnScan(ws, cards) end
    return true
end

local function RAE_Plan()
    if RAE_State.Phase ~= "READY" then return nil end
    local plan = Planner.Plan(RAE_State.Cards, RAE_State.LastLog, Intel.GetMemory().CardHistory)
    RAE_State.LastPlan = plan
    if plan and #plan > 0 then RAE_State.SelectedCards = {}; for _, step in ipairs(plan) do table.insert(RAE_State.SelectedCards, step.Card) end; if RAE_Callbacks.OnPlan then RAE_Callbacks.OnPlan(plan) end end
    return plan
end

local function RAE_Commit()
    if #RAE_State.SelectedCards == 0 then return nil end
    RAE_SetPhase("EXECUTING")
    local wsBefore = RAE_State.WorldState
    local log = Executor.Execute(RAE_State.SelectedCards, RAE_State.Cards, wsBefore)
    local wsAfter = WorldState.Capture()
    for _, r in ipairs(log) do DynamicsModel.Record(r.Step.ID, wsBefore, wsAfter, r.Success) end
    RAE_State.LastLog = log; RAE_State.CycleCount = RAE_State.CycleCount + 1; RAE_State.SelectedCards = {}
    Intel.ProcessFeedback(log, RAE_State.Cards)
    TransitionModel.Update(log)
    ValueSystem.AdaptWeights(log, RAE_State.Cards)
    SaveSession({ LWM = { RemoteRegistry = LivingWorldModel.RemoteRegistry, CoFireMap = LivingWorldModel.CoFireMap, TemporalAggregates = LivingWorldModel.TemporalAggregates }, ETM = { Table = EnhancedTransitionModel.Table, GlobalStats = EnhancedTransitionModel.GlobalStats }, CDG = { Edges = CausalDependencyGraph.Edges, ActionHistory = CausalDependencyGraph.ActionHistory }, IntelMem = IntelMem, ValueWeights = ValueWeights, Version = 2 })
    RAE_SetPhase("COMPLETE"); RAE_SetPhase("READY")
    if RAE_Callbacks.OnCommit then RAE_Callbacks.OnCommit(log) end
    return log
end

-- Character helpers
local function getCharacter() return player.Character or player.CharacterAdded:Wait() end
local function getHumanoid() local ch=getCharacter(); return ch:FindFirstChildOfClass("Humanoid") or ch:WaitForChild("Humanoid",5) end
local function applyHumanoidSetting(field, value) local hum=getHumanoid(); if hum then pcall(function() hum[field]=value end) end end
local persistent={WalkSpeed=16,JumpPower=50,AutoJumpEnabled=true,FOV=70,MinZoom=player.CameraMinZoomDistance,MaxZoom=player.CameraMaxZoomDistance}
player.CharacterAdded:Connect(function() task.wait(0.25); applyHumanoidSetting("WalkSpeed",persistent.WalkSpeed); applyHumanoidSetting("JumpPower",persistent.JumpPower); applyHumanoidSetting("AutoJumpEnabled",persistent.AutoJumpEnabled) end)

-- Global exports
_G.RAE_Engine = { Scan = RAE_Scan, Plan = RAE_Plan, Commit = RAE_Commit, State = RAE_State, LWM = LivingWorldModel, ETM = EnhancedTransitionModel, CDG = CausalDependencyGraph, StateSignature = StateSignature, Intel = Intel, Planner = Planner }

-- ============================================================
-- UI (Compact version - essential elements)
-- ============================================================
local screenGui = mk("ScreenGui", { Name="PaperClayUI", ResetOnSpawn=false, IgnoreGuiInset=true, ZIndexBehavior=Enum.ZIndexBehavior.Sibling, Parent=playerGui })
local root = mk("Frame", { Name="Root", BackgroundTransparency=1, Size=UDim2.new(1,0,1,0), Parent=screenGui })

local window = mk("Frame", { Name="Window", BackgroundColor3=Color3.fromRGB(250,247,242), BorderSizePixel=0, AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,960,0,580), ZIndex=10, Parent=root })
addCorner(window, UDim.new(0,18)); addStroke(window,1,0.22); addShadow(window,10)
mk("UISizeConstraint", {MinSize=Vector2.new(720,440),MaxSize=Vector2.new(1200,820),Parent=window})

local notifContainer = mk("Frame", { Name="NotifContainer", BackgroundTransparency=1, AnchorPoint=Vector2.new(1,0), Position=UDim2.new(1,-16,0,64), Size=UDim2.new(0,260,1,-80), ZIndex=100, Parent=window })
mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,HorizontalAlignment=Enum.HorizontalAlignment.Right,VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=notifContainer})

local function sendNotification(msg, nType)
    local bgColor=Color3.fromRGB(246,242,236); local strokeColor=Color3.fromRGB(180,180,180); local icon="ℹ"
    if nType=="Success" then bgColor=Color3.fromRGB(230,245,230); strokeColor=Color3.fromRGB(120,200,120); icon="✓"
    elseif nType=="Error" then bgColor=Color3.fromRGB(250,225,225); strokeColor=Color3.fromRGB(200,120,120); icon="✕"
    elseif nType=="Warning" then bgColor=Color3.fromRGB(250,240,210); strokeColor=Color3.fromRGB(200,180,100); icon="⚠" end
    local toast=mk("Frame",{BackgroundColor3=bgColor,BorderSizePixel=0,Size=UDim2.new(0,260,0,48),Parent=notifContainer,BackgroundTransparency=1})
    addCorner(toast,UDim.new(0,10))
    local strk=addStroke(toast,1,1); strk.Color=strokeColor
    local iLabel=mk("TextLabel",{Text=icon,Font=Enum.Font.GothamBold,TextSize=16,TextColor3=strokeColor,Size=UDim2.new(0,36,1,0),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,TextTransparency=1,Parent=toast})
    local tLabel=mk("TextLabel",{Text=msg,Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-48,1,0),Position=UDim2.new(0,42,0,0),BackgroundTransparency=1,TextWrapped=true,TextTransparency=1,Parent=toast})
    toast.Position=UDim2.new(0,50,0,0)
    tween(toast,TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency=0,Position=UDim2.new(0,0,0,0)})
    tween(strk,TweenInfo.new(0.25),{Transparency=0}); tween(iLabel,TweenInfo.new(0.25),{TextTransparency=0}); tween(tLabel,TweenInfo.new(0.25),{TextTransparency=0})
    task.delay(3.5,function() if toast and toast.Parent then tween(toast,TweenInfo.new(0.25),{BackgroundTransparency=1}); task.delay(0.25,function() if toast then toast:Destroy() end end) end end)
end

RAE_Callbacks.OnPhase = function(phase)
    if RAE_SilentMode then return end
    if phase=="SCANNING" then sendNotification("RAE V2: Scanning...", "Info")
    elseif phase=="READY" then sendNotification("RAE V2: Ready ("..#RAE_State.Cards.." cards)", "Success")
    elseif phase=="EXECUTING" then sendNotification("RAE V2: Executing...", "Info") end
end

-- Topbar
local topbar=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,56),Parent=window})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,0),Size=UDim2.new(1,-260,1,0),Font=Enum.Font.GothamBold,Text="Paper & Clay ⊕ RAE V2",TextColor3=Color3.fromRGB(46,42,38),TextSize=16,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,30),Size=UDim2.new(1,-260,0,20),Font=Enum.Font.GothamMedium,Text="Deep Intelligence · LWM · ETM · CDG · MCTS",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})

local btnMin=mk("TextButton",{AutoButtonColor=false,BackgroundTransparency=1,Size=UDim2.new(0,40,0,40),AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-46,0,8),Text="—",Font=Enum.Font.GothamBold,TextSize=16,TextColor3=Color3.fromRGB(120,110,100),Parent=topbar})
local btnClose=mk("TextButton",{AutoButtonColor=false,BackgroundTransparency=1,Size=UDim2.new(0,40,0,40),AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-6,0,8),Text="✕",Font=Enum.Font.GothamBold,TextSize=16,TextColor3=Color3.fromRGB(120,110,100),Parent=topbar})

-- Body
local body=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,56),Size=UDim2.new(1,0,1,-56),Parent=window})
local mainContent=mk("Frame",{BackgroundColor3=Color3.fromRGB(252,250,247),BorderSizePixel=0,Position=UDim2.new(0,10,0,0),Size=UDim2.new(1,-20,1,-10),Parent=body})
addCorner(mainContent,UDim.new(0,14)); addStroke(mainContent,1,0.25)

local contentScroll=mk("ScrollingFrame",{BackgroundTransparency=1,Position=UDim2.new(0,10,0,10),Size=UDim2.new(1,-20,1,-20),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=mainContent})
mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,Padding=UDim.new(0,14),Parent=contentScroll})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,10),PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),Parent=contentScroll})

-- Controls Section
local ctrlSection=mk("Frame",{BackgroundColor3=Color3.fromRGB(247,243,237),Size=UDim2.new(1,0,0,180),Parent=contentScroll})
addCorner(ctrlSection,UDim.new(0,14)); addStroke(ctrlSection,1,0.35)
mk("UIPadding",{PaddingTop=UDim.new(0,14),PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,14),PaddingBottom=UDim.new(0,14),Parent=ctrlSection})
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="RAE V2 Controls",TextColor3=Color3.fromRGB(52,47,42),TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),Parent=ctrlSection})

local ctrlGrid=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,30),Size=UDim2.new(1,0,0,120),Parent=ctrlSection})
mk("UIGridLayout",{CellSize=UDim2.new(0.48,0,0,44),CellPadding=UDim2.new(0.04,0,0,10),SortOrder=Enum.SortOrder.LayoutOrder,Parent=ctrlGrid})

local function makeRAEBtn(parent, label, icon, color, fn)
    local btn=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=color,BorderSizePixel=0,Size=UDim2.new(1,0,0,44),Font=Enum.Font.GothamSemibold,Text="",TextSize=14,Parent=parent})
    addCorner(btn,UDim.new(0,12)); addStroke(btn,1,0.25)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=icon,TextColor3=Color3.fromRGB(96,84,72),TextSize=14,Size=UDim2.new(0,30,1,0),Position=UDim2.new(0,10,0,0),Parent=btn})
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamSemibold,Text=label,TextColor3=Color3.fromRGB(52,47,42),TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-50,1,0),Position=UDim2.new(0,40,0,0),Parent=btn})
    btn.MouseButton1Click:Connect(function() clickSound(); pulseClick(btn); fn() end)
    return btn
end

makeRAEBtn(ctrlGrid, "Scan", "🔍", Color3.fromRGB(220,230,255), function() task.spawn(function() RAE_SilentMode=false; RAE_Scan() end) end)
makeRAEBtn(ctrlGrid, "Plan (MCTS)", "🧠", Color3.fromRGB(220,255,230), function() task.spawn(function() RAE_SilentMode=false; local plan=RAE_Plan(); if plan and #plan>0 then sendNotification("Plan ready: "..#plan.." steps", "Success") else sendNotification("No plan generated", "Warning") end end) end)
makeRAEBtn(ctrlGrid, "Commit", "▶", Color3.fromRGB(230,255,230), function() task.spawn(function() if #RAE_State.SelectedCards==0 then sendNotification("Nothing selected", "Warning"); return end; RAE_SilentMode=false; local log=RAE_Commit(); if log then local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end; sendNotification(string.format("Cycle #%d: %d/%d passed",RAE_State.CycleCount,p,#log), p==#log and "Success" or "Warning") end end) end)
makeRAEBtn(ctrlGrid, "Full Cycle", "↺", Color3.fromRGB(245,240,230), function() task.spawn(function() RAE_SilentMode=false; sendNotification("RAE V2: Full cycle...", "Info"); if RAE_Scan() then task.wait(0.5); local plan=RAE_Plan(); if plan and #plan>0 then task.wait(0.5); local log=RAE_Commit(); if log then local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end; sendNotification(string.format("Complete — %d/%d passed",p,#log), p==#log and "Success" or "Warning") end else sendNotification("No plan generated", "Info") end else sendNotification("Scan failed", "Error") end end) end)

-- Status Section
local statusSection=mk("Frame",{BackgroundColor3=Color3.fromRGB(247,243,237),Size=UDim2.new(1,0,0,120),Parent=contentScroll})
addCorner(statusSection,UDim.new(0,14)); addStroke(statusSection,1,0.35)
mk("UIPadding",{PaddingTop=UDim.new(0,14),PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,14),PaddingBottom=UDim.new(0,14),Parent=statusSection})
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="Deep Intelligence Status",TextColor3=Color3.fromRGB(52,47,42),TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),Parent=statusSection})

local statusLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Awaiting first scan...",TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Position=UDim2.new(0,0,0,26),Size=UDim2.new(1,0,0,70),Parent=statusSection})

RAE_Callbacks.OnScan = function(ws, cards)
    local etmMap = EnhancedTransitionModel.GetConvergenceMap()
    local cdgStats = CausalDependencyGraph.GetStats()
    local calStats = Intel.GetCalibrationStats()
    statusLabel.Text = string.format("T: %.2f | Instances: %d | Remotes: %d | Cards: %d\nLWM Snapshots: %d | ETM Converged: %d/%d\nCDG Edges: %d (Strong: %d) | Brier: %.4f\nCycles: %d | Session: %s", ws.T, ws.ObjectGraph.TotalInstances, #ws.Latent.RemoteEvents, #cards, #LivingWorldModel.Snapshots, etmMap.Converged, etmMap.Total, cdgStats.TotalEdges, cdgStats.StrongEdges, calStats.BrierScore, IntelMem.Cycles, savedSession and "Restored" or "New")
end

-- Window controls
local dragging,dragStart,startPos=false,nil,nil
topbar.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true; dragStart=input.Position; startPos=window.Position end end)
topbar.InputEnded:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end)
UserInputService.InputChanged:Connect(function(input) if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then window.Position=startPos+UDim2.fromOffset((input.Position-dragStart).X,(input.Position-dragStart).Y) end end)

local minimized=false; local windowOpenSize=window.Size
local function minimize()
    if minimized then minimized=false; body.Visible=true; tween(window,TweenInfo.new(0.22),{Size=windowOpenSize})
    else minimized=true; windowOpenSize=window.Size; tween(window,TweenInfo.new(0.22),{Size=UDim2.new(0,window.AbsoluteSize.X,0,56)}); task.delay(0.12,function() body.Visible=false end) end
end

btnMin.MouseButton1Click:Connect(function() clickSound(); pulseClick(btnMin); minimize() end)
btnClose.MouseButton1Click:Connect(function() clickSound(); pulseClick(btnClose); tween(window,TweenInfo.new(0.18),{Size=window.Size-UDim2.fromOffset(60,40)}); task.delay(0.18,function() if screenGui then screenGui:Destroy() end end) end)

-- Intro animation
do
    local startSize=window.Size
    window.Size=UDim2.new(0,window.AbsoluteSize.X-60,0,window.AbsoluteSize.Y-50)
    window.Position=UDim2.new(0.5,0,0.5,8)
    tween(window,TweenInfo.new(0.22,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=startSize,Position=UDim2.new(0.5,0,0.5,0)})
    task.defer(function() task.wait(0.4); sendNotification("Paper & Clay + RAE V2 Loaded", "Success") end)
end

-- Boot scan
task.spawn(function()
    if not player.Character then player.CharacterAdded:Wait() end
    task.wait(3)
    RAE_SilentMode = false
    sendNotification("RAE V2: Deep intelligence boot scan...", "Info")
    task.wait(0.5)
    if RAE_Scan() then
        task.wait(0.5)
        local plan = RAE_Plan()
        if plan and #plan > 0 then
            task.wait(0.5)
            local log = RAE_Commit()
            if log then
                local p = 0; for _, r in ipairs(log) do if r.Success then p = p + 1 end end
                local etmMap = EnhancedTransitionModel.GetConvergenceMap()
                sendNotification(string.format("Boot complete — %d cards, %d/%d passed. ETM: %d converged", #RAE_State.Cards, p, #log, etmMap.Converged), p == #log and "Success" or "Warning")
            end
        else sendNotification("Boot scan complete. No plan generated.", "Info") end
    else sendNotification("Boot scan failed.", "Error") end
end)

print("[RAE V2] ══════════════════════════════════════════════════")
print("[RAE V2] Paper & Clay + RAE V2 — Deep Intelligence Edition")
print("[RAE V2] Modules: LWM · ETM · CDG · MCTS · Intel v4")
print("[RAE V2] Session: " .. (savedSession and "Restored" or "New"))
print("[RAE V2] ══════════════════════════════════════════════════")
