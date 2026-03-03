--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   Paper & Clay  +  RAE — Recursive Autonomous Engine  v2.0          ║
    ║   Deep Intelligence Edition                                          ║
    ║                                                                      ║
    ║   NEW IN v2.0:                                                       ║
    ║     StateSignature  — compact φ(S) with canonicalization/hashing    ║
    ║     LWM             — Living World Model ring buffer + delta track  ║
    ║     ETM             — Empirical Transition Model (Bayesian,         ║
    ║                        state-conditional, convergence-aware)         ║
    ║     CDG             — Causal Dependency Graph (effect size+conf)    ║
    ║     Risk-Adj MCTS   — E[U] − λVar[U] − μCost selection criterion   ║
    ║     Session Persist — _G persistence for IntelMem / ETM / CDG       ║
    ║     Brier Calibration — predicted-vs-actual confidence tracking     ║
    ║     Analytics Tab   — convergence map, CDG edges, calibration live  ║
    ║                                                                      ║
    ║   Tabs:                                                              ║
    ║     Overview · Player · Camera · World · Discovery                  ║
    ║     RAE · Recursive · Bridge · Analytics · Chain · Utilities · About║
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
        local function readInt32()
            local b1,b2,b3,b4 = string.byte(bytecode, pos, pos+3); pos=pos+4
            return b1+bit32.lshift(b2,8)+bit32.lshift(b3,16)+bit32.lshift(b4,24)
        end
        local function readVarInt()
            local res=0; local shift=0; local b
            repeat b=readByte(); res=bit32.bor(res,bit32.lshift(bit32.band(b,127),shift)); shift=shift+7 until b<128
            return res
        end
        local function readString()
            local len=readVarInt(); if len==0 then return "" end
            local s=string.sub(bytecode, pos, pos+len-1); pos=pos+len; return s
        end
        local version=readByte()
        if version==0 then return "Error: Luau Compilation failed" end
        if version>=4 then readByte() end
        local stringCount=readVarInt(); local strings={}
        for i=1,stringCount do strings[i]=readString() end
        local function readProto()
            local p={maxstack=readByte(),numparams=readByte(),numupvalues=readByte(),isvararg=readByte()}
            if version>=4 then readByte(); local ti=readVarInt(); if ti>0 then pos=pos+readVarInt() end end
            local sizecode=readVarInt(); p.code={}; for i=1,sizecode do p.code[i]=readInt32() end
            local sizek=readVarInt(); p.constants={}
            for i=1,sizek do
                local cType=readByte()
                if cType==0 then p.constants[i]="nil"
                elseif cType==1 then p.constants[i]=tostring(readByte()~=0)
                elseif cType==2 then pos=pos+8; p.constants[i]="<number>"
                elseif cType==3 then p.constants[i]='"'..(strings[readVarInt()] or "")..'"'
                elseif cType==4 then readInt32(); p.constants[i]="<import>"
                elseif cType==5 then local ts=readVarInt(); for _=1,ts do readVarInt() end; p.constants[i]="<table>"
                elseif cType==6 then readVarInt(); p.constants[i]="<closure>"
                else p.constants[i]="<unknown>" end
            end
            local sizep=readVarInt(); for i=1,sizep do readVarInt() end
            readVarInt(); readVarInt()
            if readByte()~=0 then local lg=readByte(); local iv=bit32.rshift(sizecode-1,lg)+1; pos=pos+sizecode+(iv*4) end
            if readByte()~=0 then
                local slv=readVarInt(); for i=1,slv do readVarInt() readVarInt() readVarInt() readByte() end
                local suv=readVarInt(); for i=1,suv do readVarInt() end
            end
            return p
        end
        local protoCount=readVarInt(); local protos={}
        for i=1,protoCount do protos[i]=readProto() end
        local out={"-- Luau VM Bytecode --"}
        for i,p in ipairs(protos) do
            table.insert(out,string.format("\n[Proto %d] Stack:%d Params:%d UpVals:%d",i-1,p.maxstack,p.numparams,p.numupvalues))
            if #p.constants>0 then table.insert(out,"; Constants"); for j,c in ipairs(p.constants) do table.insert(out,string.format("  k[%d]=%s",j-1,c)) end end
            table.insert(out,"; Instructions")
            for j,ins in ipairs(p.code) do
                local op=bit32.band(ins,0xFF); local a=bit32.band(bit32.rshift(ins,8),0xFF)
                local b=bit32.band(bit32.rshift(ins,16),0xFF); local c=bit32.band(bit32.rshift(ins,24),0xFF)
                table.insert(out,string.format("[%04d] OP_%02d A:%-3d B:%-3d C:%-3d",j,op,a,b,c))
            end
        end
        return table.concat(out,"\n")
    end)
    return success and result or ("-- Parse Failed: "..tostring(result))
end

-- ============================================================
-- RAE BACKEND — DEEP INTELLIGENCE EDITION
-- ============================================================

-- SHARED MATH
local function SampleGamma(alpha)
    if alpha < 1 then return SampleGamma(1+alpha)*(math.random()^(1/alpha)) end
    local d=alpha-1/3; local c=1/math.sqrt(9*d)
    while true do
        local u1=math.max(math.random(),1e-10); local u2=math.random()
        local x=math.sqrt(-2*math.log(u1))*math.cos(2*math.pi*u2); local v=1+c*x
        if v>0 then
            v=v*v*v; local u=math.random()
            if u<1-0.0331*(x*x)*(x*x) then return d*v end
            if math.log(u)<0.5*x*x+d*(1-v+math.log(v)) then return d*v end
        end
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

-- ── SEMANTIC CLASSIFIER ──────────────────────────────────────
local SEMANTIC_TAGS = {
    Economy  = {"coin","cash","money","gem","gold","credit","balance","point","currency","reward","earn","pay","buy","purchase","shop","cost"},
    Heal     = {"heal","health","hp","regen","revive","respawn","medkit"},
    Damage   = {"damage","hurt","hit","attack","strike","kill","death"},
    Movement = {"teleport","tp","move","position","warp","dash","blink","cframe","jump"},
    Cooldown = {"cooldown","timer","daily","claim","stamp","elapsed","reset","delay"},
    Admin    = {"kick","ban","admin","rank","mod","promote","demote","execute","run"},
    Save     = {"save","load","data","store","sync","persist","datastore"},
    Crafting = {"craft","recipe","forge","combine","brew","upgrade","build"},
    Loot     = {"loot","crate","box","spin","open","roll","drop","chest","unbox"},
    Trade    = {"trade","offer","accept","swap","exchange","deal"},
}
local function ClassifyRemote(name)
    local nl = name:lower()
    for tag, patterns in pairs(SEMANTIC_TAGS) do
        for _, p in ipairs(patterns) do
            if nl:find(p) then return tag end
        end
    end
    return "General"
end

-- ============================================================
-- NEW: STATE SIGNATURE φ(S)
-- Compact, canonical, hash-stable state token for ETM lookups.
-- ============================================================
local StateSignature = {}
local function _discretize(v, step) return math.floor((v or 0) / step) * step end

function StateSignature.Compute(ws)
    if not ws then return "null_sig" end
    local lp = ws.Agents and ws.Agents.LocalPlayer
    local totalFires, economySeen = 0, 0
    for _, r in ipairs(ws.Latent and ws.Latent.RemoteEvents or {}) do
        totalFires = totalFires + (r.FireCount or 0)
        if ClassifyRemote(r.Name) == "Economy" then economySeen = 1 end
    end
    local matchActive = 0
    for _ in pairs(ws.Latent and ws.Latent.MatchState or {}) do matchActive = 1; break end
    return string.format("h%d_p%d_c%d_f%d_e%d_m%d_i%d",
        _discretize(lp and lp.Health or 0, 20),
        _discretize(#(ws.Physics and ws.Physics.SimulatedAssemblies or {}), 5),
        #(ws.Physics and ws.Physics.ClientOwned or {}),
        _discretize(totalFires, 10),
        economySeen, matchActive,
        _discretize(ws.ObjectGraph and ws.ObjectGraph.TotalInstances or 0, 100))
end
function StateSignature.Diff(sigA, sigB)
    if sigA == sigB then return 0.0 end
    local partsA, partsB = {}, {}
    for p in sigA:gmatch("[^_]+") do table.insert(partsA, p) end
    for p in sigB:gmatch("[^_]+") do table.insert(partsB, p) end
    local diff = 0
    for i = 1, math.min(#partsA, #partsB) do
        if partsA[i] ~= partsB[i] then diff = diff + 1 end
    end
    return diff / math.max(#partsA, #partsB, 1)
end

-- ============================================================
-- NEW: LIVING WORLD MODEL (LWM)
-- Ring buffer of world-state snapshots. Temporal deltas,
-- rolling averages, and remote registry for co-firing analysis.
-- ============================================================
local LWM_Buffer         = {}
local LWM_RemoteRegistry = {}
local LWM_CFG            = { MaxSnapshots = 12 }
local LWM = {}

function LWM.Record(ws, sig)
    if not ws then return end
    local lp = ws.Agents and ws.Agents.LocalPlayer
    local totalFires = 0
    for _, r in ipairs(ws.Latent and ws.Latent.RemoteEvents or {}) do
        totalFires = totalFires + (r.FireCount or 0)
        if not LWM_RemoteRegistry[r.Name] then
            LWM_RemoteRegistry[r.Name] = { totalFires = 0, lastSeen = 0 }
        end
        LWM_RemoteRegistry[r.Name].totalFires = r.FireCount
        LWM_RemoteRegistry[r.Name].lastSeen   = os.clock()
    end
    table.insert(LWM_Buffer, {
        sig = sig, timestamp = os.clock(),
        metrics = {
            health        = lp and lp.Health or 0,
            physCount     = #(ws.Physics and ws.Physics.SimulatedAssemblies or {}),
            clientOwned   = #(ws.Physics and ws.Physics.ClientOwned or {}),
            remoteFires   = totalFires,
            scriptCount   = ws.ObjectGraph and ws.ObjectGraph.ScriptCount or 0,
            instanceCount = ws.ObjectGraph and ws.ObjectGraph.TotalInstances or 0,
            remoteCount   = #(ws.Latent and ws.Latent.RemoteEvents or {}),
        }
    })
    if #LWM_Buffer > LWM_CFG.MaxSnapshots then table.remove(LWM_Buffer, 1) end
end
function LWM.GetDelta()
    if #LWM_Buffer < 2 then return nil end
    local prev    = LWM_Buffer[#LWM_Buffer - 1].metrics
    local curr    = LWM_Buffer[#LWM_Buffer].metrics
    local elapsed = LWM_Buffer[#LWM_Buffer].timestamp - LWM_Buffer[#LWM_Buffer - 1].timestamp
    return {
        healthDelta   = curr.health        - prev.health,
        physDelta     = curr.physCount     - prev.physCount,
        ownedDelta    = curr.clientOwned   - prev.clientOwned,
        firesDelta    = curr.remoteFires   - prev.remoteFires,
        instanceDelta = curr.instanceCount - prev.instanceCount,
        elapsed       = math.max(elapsed, 0.001),
    }
end
function LWM.GetTemporalAverage(key, window)
    window = window or 5
    if #LWM_Buffer == 0 then return 0 end
    local sum, count = 0, 0
    for i = math.max(1, #LWM_Buffer - window + 1), #LWM_Buffer do
        local v = LWM_Buffer[i].metrics[key]
        if type(v) == "number" then sum = sum + v; count = count + 1 end
    end
    return count > 0 and (sum / count) or 0
end
function LWM.GetRecentSig()
    if #LWM_Buffer == 0 then return "null_sig" end
    return LWM_Buffer[#LWM_Buffer].sig
end
function LWM.GetSnapshotCount()      return #LWM_Buffer          end
function LWM.GetBuffer()             return LWM_Buffer            end
function LWM.GetRemoteRegistry()     return LWM_RemoteRegistry    end

-- ============================================================
-- NEW: EMPIRICAL TRANSITION MODEL (ETM)
-- P(success | cardID, stateSignature). State-conditional Beta
-- posteriors with Welford variance. Convergence criterion:
-- stddev < 0.08 AND n >= 10.
-- ============================================================
local ETM_Table = {}
local ETM_CFG   = { MinCount=10, ConvergenceStdDev=0.08, DecayRate=0.92 }
local ETM = {}

function ETM.GetOrInit(cardID, stateSig)
    if not ETM_Table[cardID] then ETM_Table[cardID] = {} end
    if not ETM_Table[cardID][stateSig] then
        ETM_Table[cardID][stateSig] = {
            alpha=1.0, beta=1.0, n=0, mean=0.5, M2=0.0,
            stddev=0.5, converged=false, lastUpdated=os.clock(),
        }
    end
    return ETM_Table[cardID][stateSig]
end
function ETM.Update(cardID, stateSig, success)
    local e = ETM.GetOrInit(cardID, stateSig)
    e.alpha = e.alpha * ETM_CFG.DecayRate
    e.beta  = e.beta  * ETM_CFG.DecayRate
    if success then e.alpha = e.alpha + 1.0 else e.beta = e.beta + 1.0 end
    e.n = e.n + 1
    local v  = success and 1.0 or 0.0
    local d1 = v - e.mean; e.mean = e.mean + d1 / e.n
    local d2 = v - e.mean; e.M2   = e.M2 + d1 * d2
    if e.n >= 2 then e.stddev = math.sqrt(e.M2 / (e.n - 1)) end
    e.converged   = (e.stddev < ETM_CFG.ConvergenceStdDev and e.n >= ETM_CFG.MinCount)
    e.lastUpdated = os.clock()
end
function ETM.Predict(cardID, stateSig)
    if not ETM_Table[cardID] then return 0.5, false, 0.5 end
    local e = ETM_Table[cardID][stateSig]
    if not e then
        local totalA, totalB, count = 0.0, 0.0, 0
        for _, se in pairs(ETM_Table[cardID]) do
            totalA = totalA + se.alpha; totalB = totalB + se.beta; count = count + 1
        end
        if count > 0 then return totalA / (totalA + totalB), false, 0.35 end
        return 0.5, false, 0.5
    end
    return e.alpha / (e.alpha + e.beta), e.converged, e.stddev
end
function ETM.GetConvergenceMap()
    local map = {}
    local gTotal, gConverged = 0, 0
    for cardID, sigs in pairs(ETM_Table) do
        local tot, conv = 0, 0
        for _, e in pairs(sigs) do tot = tot + 1; if e.converged then conv = conv + 1 end end
        map[cardID]  = { total=tot, converged=conv, rate=tot>0 and (conv/tot) or 0 }
        gTotal = gTotal + tot; gConverged = gConverged + conv
    end
    map["_global"] = { total=gTotal, converged=gConverged, rate=gTotal>0 and (gConverged/gTotal) or 0 }
    return map
end
function ETM.GetTableRef()   return ETM_Table   end
function ETM.SetTableRef(t)  ETM_Table = t      end

-- ============================================================
-- NEW: CAUSAL DEPENDENCY GRAPH (CDG)
-- Co-execution statistics for card pairs. Effect size = lift
-- in B's success probability given A succeeded vs baseline.
-- Used to causal-reorder chains before execution.
-- ============================================================
local CDG_Table = {}
local CDG = {}

function CDG.GetOrInitEdge(aID, bID)
    if not CDG_Table[aID] then CDG_Table[aID] = {} end
    if not CDG_Table[aID][bID] then
        CDG_Table[aID][bID] = {
            coFired=0, coSuccess=0, coFail=0, aFailBSuc=0,
            coTotal=0, effectSize=0.0, confidence=0.0, lastUpdated=0,
        }
    end
    return CDG_Table[aID][bID]
end
function CDG.UpdateFromLog(log)
    if not log or #log < 2 then return end
    for i = 1, #log - 1 do
        local aStep = log[i]
        for j = i + 1, math.min(i + 4, #log) do
            local bStep = log[j]
            local e = CDG.GetOrInitEdge(aStep.Step.ID, bStep.Step.ID)
            e.coFired = e.coFired + 1; e.coTotal = e.coTotal + 1
            if     aStep.Success and     bStep.Success then e.coSuccess = e.coSuccess + 1 end
            if     aStep.Success and not bStep.Success then e.coFail    = e.coFail    + 1 end
            if not aStep.Success and     bStep.Success then e.aFailBSuc = e.aFailBSuc + 1 end
            local pBgivenASucc = e.coFired > 0 and (e.coSuccess / e.coFired) or 0.5
            local baseline     = (e.coSuccess + e.aFailBSuc) / math.max(e.coTotal, 1)
            e.effectSize  = pBgivenASucc - baseline
            e.confidence  = math.min(e.coFired / 12.0, 1.0)
            e.lastUpdated = os.clock()
        end
    end
end
function CDG.GetStrongEdges(minConf)
    minConf = minConf or 0.25
    local edges = {}
    for aID, targets in pairs(CDG_Table) do
        for bID, e in pairs(targets) do
            if e.confidence >= minConf then
                table.insert(edges, {
                    FromID=aID, ToID=bID, EffectSize=e.effectSize,
                    Confidence=e.confidence, CoSuccess=e.coSuccess,
                    CoFail=e.coFail, CoFired=e.coFired,
                })
            end
        end
    end
    table.sort(edges, function(a, b) return math.abs(a.EffectSize) > math.abs(b.EffectSize) end)
    return edges
end
function CDG.GetCausalScore(cardID)
    if not CDG_Table[cardID] then return 0.0 end
    local score = 0.0
    for _, e in pairs(CDG_Table[cardID]) do score = score + e.effectSize * e.confidence end
    return score
end
function CDG.ReorderChain(chain)
    local scored = {}
    for i, card in ipairs(chain) do
        table.insert(scored, { card=card, idx=i, causal=CDG.GetCausalScore(card.ID) })
    end
    table.sort(scored, function(a, b)
        if math.abs(a.causal - b.causal) < 0.05 then return a.idx < b.idx end
        return a.causal > b.causal
    end)
    local out = {}
    for _, entry in ipairs(scored) do table.insert(out, entry.card) end
    return out
end
function CDG.GetTableRef()   return CDG_Table   end
function CDG.SetTableRef(t)  CDG_Table = t      end

-- ============================================================
-- WORLD STATE (chunked BFS scan)
-- ============================================================
local WorldState = {}
local WS_CHUNK   = 500

local function CaptureWorldState()
    local T  = os.clock()
    local lp = Players.LocalPlayer
    local char = lp and lp.Character
    local state = {
        T = T,
        SimConfig = {
            ServerTime       = Workspace:GetServerTimeNow(),
            FrameStep        = T,
            Gravity          = Workspace.Gravity,
            StreamingEnabled = Workspace.StreamingEnabled,
            StreamingRadius  = (function()
                local ok, val = pcall(function() return Workspace.StreamingTargetRadius end)
                return ok and val or 0
            end)(),
            NetworkOwnerRate = 1/60,
        },
        ObjectGraph = { TotalInstances=0, ScriptCount=0, EnabledScripts=0, DisabledScripts=0, TaggedInstances={}, AttributeMap={} },
        Physics     = { SimulatedAssemblies={}, ClientOwned={}, ServerOwned={}, TotalMass=0 },
        Agents      = { LocalPlayer=nil, OtherPlayers={} },
        Latent      = { RemoteEvents={}, RemoteFunctions={}, BindableEvents={}, ObservedFires={}, ValueObjects={}, MatchState={}, SpawnerState={} },
        Network     = { ReplicatedInstances=0, StreamedIn={}, StreamedOut={}, OwnershipMap={}, PendingRemotes={}, ReplicationLag=0 },
    }
    local knownRemotes = {}
    if RAE_State and RAE_State.WorldState then
        for _, entry in ipairs(RAE_State.WorldState.Latent.RemoteEvents or {}) do
            knownRemotes[entry.Name] = entry
        end
    end
    local allDesc = game:GetDescendants(); local n = 0
    for _, obj in ipairs(allDesc) do
        state.ObjectGraph.TotalInstances = state.ObjectGraph.TotalInstances + 1
        local cls = obj.ClassName
        if cls=="Script" or cls=="LocalScript" then
            state.ObjectGraph.ScriptCount = state.ObjectGraph.ScriptCount + 1
            if obj.Enabled then state.ObjectGraph.EnabledScripts = state.ObjectGraph.EnabledScripts + 1
            else state.ObjectGraph.DisabledScripts = state.ObjectGraph.DisabledScripts + 1 end
        elseif cls=="ModuleScript" then
            state.ObjectGraph.ScriptCount = state.ObjectGraph.ScriptCount + 1
            state.ObjectGraph.EnabledScripts = state.ObjectGraph.EnabledScripts + 1
        elseif cls=="IntValue" or cls=="NumberValue" or cls=="BoolValue" or cls=="StringValue" then
            table.insert(state.Latent.ValueObjects, { Name=obj.Name, Path=obj:GetFullName(), Value=obj.Value, Class=cls })
        end
        local tags = obj:GetTags()
        if #tags > 0 then
            table.insert(state.ObjectGraph.TaggedInstances, { Instance=obj, Name=obj.Name, Path=obj:GetFullName(), Tags=tags })
        end
        n = n + 1; if n >= WS_CHUNK then n = 0; task.wait() end
    end
    local wsDesc = Workspace:GetDescendants(); n = 0; local physCap = 0
    for _, obj in ipairs(wsDesc) do
        if obj:IsA("BasePart") then
            state.Physics.TotalMass = state.Physics.TotalMass + obj.AssemblyMass
            if not obj.Anchored and physCap < 200 then
                physCap = physCap + 1
                local entry = {
                    Instance=obj, Name=obj.Name, Path=obj:GetFullName(),
                    CFrame=obj.CFrame, Velocity=obj.AssemblyLinearVelocity,
                    AngularVel=obj.AssemblyAngularVelocity, Mass=obj.AssemblyMass,
                    Anchored=false, CanCollide=obj.CanCollide,
                }
                table.insert(state.Physics.SimulatedAssemblies, entry)
                local ok, owner = pcall(function() return obj:GetNetworkOwner() end)
                if ok then
                    if owner == lp then
                        table.insert(state.Physics.ClientOwned, entry)
                        state.Network.OwnershipMap[obj:GetFullName()] = "CLIENT"
                    else
                        table.insert(state.Physics.ServerOwned, entry)
                        state.Network.OwnershipMap[obj:GetFullName()] = "SERVER"
                    end
                end
            end
        end
        n = n + 1; if n >= WS_CHUNK then n = 0; task.wait() end
    end
    if char then
        local hrp  = char:FindFirstChild("HumanoidRootPart")
        local hum  = char:FindFirstChildOfClass("Humanoid")
        local tool = char:FindFirstChildOfClass("Tool")
        state.Agents.LocalPlayer = {
            Name=lp.Name, UserId=lp.UserId, Team=lp.Team and lp.Team.Name or "None",
            CFrame=hrp and hrp.CFrame or CFrame.new(),
            Velocity=hrp and hrp.AssemblyLinearVelocity or Vector3.new(),
            Health=hum and hum.Health or 0, MaxHealth=hum and hum.MaxHealth or 100,
            WalkSpeed=hum and hum.WalkSpeed or 16, JumpPower=hum and hum.JumpPower or 50,
            HumState=hum and tostring(hum:GetState()) or "Unknown",
            EquippedTool=tool and tool.Name or nil,
        }
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local pChar=p.Character
            local pHRP=pChar and pChar:FindFirstChild("HumanoidRootPart")
            local pHum=pChar and pChar:FindFirstChildOfClass("Humanoid")
            table.insert(state.Agents.OtherPlayers, {
                Name=p.Name, UserId=p.UserId, Team=p.Team and p.Team.Name or "None",
                CFrame=pHRP and pHRP.CFrame or CFrame.new(),
                Health=pHum and pHum.Health or 0, MaxHealth=pHum and pHum.MaxHealth or 100,
            })
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
                        local ex2 = knownRemotes[child.Name]
                        if ex2 and ex2.Instance == child then
                            table.insert(state.Latent.RemoteEvents, ex2)
                        else
                            local entry = { Instance=child, Name=child.Name, Path=child:GetFullName(), FireCount=0, LastArgs=nil, LastFire=0 }
                            table.insert(state.Latent.RemoteEvents, entry)
                            child.OnClientEvent:Connect(function(...)
                                entry.FireCount = entry.FireCount + 1
                                entry.LastArgs  = {...}
                                entry.LastFire  = os.clock()
                                table.insert(state.Latent.ObservedFires, { Remote=child.Name, Args={...}, Time=os.clock() })
                            end)
                        end
                    elseif cls == "RemoteFunction" then
                        table.insert(state.Latent.RemoteFunctions, { Instance=child, Name=child.Name, Path=child:GetFullName() })
                    elseif cls == "BindableEvent" then
                        table.insert(state.Latent.BindableEvents, { Instance=child, Name=child.Name, Path=child:GetFullName() })
                    end
                    local nl = child.Name:lower()
                    if nl:find("match") or nl:find("game") or nl:find("round") or nl:find("phase") or nl:find("timer") then
                        state.Latent.MatchState[child.Name] = { Instance=child, Class=cls, Path=child:GetFullName() }
                    end
                    if nl:find("spawn") or nl:find("wave") then
                        state.Latent.SpawnerState[child.Name] = { Instance=child, Class=cls, Path=child:GetFullName() }
                    end
                    table.insert(queue, { node=child, depth=depth+1 })
                    n = n + 1; if n >= WS_CHUNK then n = 0; task.wait() end
                end
            end
        end
    end
    state.Network.ReplicatedInstances = state.ObjectGraph.TotalInstances
    return state
end
WorldState.Capture = CaptureWorldState

-- ============================================================
-- CARD GENESIS
-- ============================================================
local CardGenesis = {}
local function NewCard(channel, name, description, preconditions, action, expectedOutcome, cost, metadata)
    return {
        ID=tostring(math.random(1e8,9e8)), Channel=channel, Name=name, Description=description,
        Preconditions=preconditions or {}, Action=action, ExpectedOutcome=expectedOutcome,
        Cost=cost or { CPU="low", Network="none", Disruption="none" },
        Metadata=metadata or {}, TelemetryLog={}, Born=os.clock(),
    }
end
local function PreCondAlwaysTrue() return true, "No preconditions." end
local function PreCondInstanceExists(instance)
    return function() local ok=pcall(function() return instance.Parent~=nil end); return ok, ok and "Instance exists." or "Instance missing." end
end

local function GenStructural(ws, cards)
    local og = ws.ObjectGraph
    if not og or og.TotalInstances == 0 then return end
    table.insert(cards, NewCard("Structural", "Architecture Profile",
        string.format("%d instances | %d scripts (%d enabled, %d disabled)",
            og.TotalInstances, og.ScriptCount, og.EnabledScripts, og.DisabledScripts),
        {PreCondAlwaysTrue},
        function(outputs)
            outputs = outputs or {}
            outputs["Structural"] = { TotalInstances=og.TotalInstances, ScriptCount=og.ScriptCount, EnabledScripts=og.EnabledScripts }
            return outputs["Structural"]
        end,
        "Caches architectural context for downstream cards.",
        {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
    if #og.TaggedInstances > 0 then
        local tagMap = {}
        for _, entry in ipairs(og.TaggedInstances) do
            for _, tag in ipairs(entry.Tags) do
                if not tagMap[tag] then tagMap[tag] = {} end
                table.insert(tagMap[tag], entry)
            end
        end
        table.insert(cards, NewCard("Structural", "Tagged Instance Map",
            string.format("%d tagged instances across %d tag types.",
                #og.TaggedInstances, (function() local n=0; for _ in pairs(tagMap) do n=n+1 end; return n end)()),
            {PreCondAlwaysTrue},
            function(outputs) outputs = outputs or {}; outputs["TagMap"] = tagMap; return tagMap end,
            "Builds tag-keyed lookup table for spatial and semantic targeting.",
            {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=95}))
    end
end

local function GenMetabolic(ws, cards)
    local sc = ws.SimConfig; if not sc then return end
    table.insert(cards, NewCard("Metabolic", "Simulation Config Snapshot",
        string.format("Gravity:%.1f | Streaming:%s | ServerTime:%.2f", sc.Gravity, tostring(sc.StreamingEnabled), sc.ServerTime),
        {PreCondAlwaysTrue},
        function(outputs)
            outputs = outputs or {}
            outputs["Metabolic"] = { Gravity=Workspace.Gravity, ServerTime=Workspace:GetServerTimeNow(), Streaming=sc.StreamingEnabled }
            return outputs["Metabolic"]
        end,
        "Captures live physics config.", {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
end

local function GenPhysics(ws, cards)
    local phys = ws.Physics; if not phys then return end
    for _, entry in ipairs(phys.ClientOwned or {}) do
        local inst = entry.Instance
        table.insert(cards, NewCard("Ownership", "Velocity Influence: " .. entry.Name,
            string.format("Client owns '%s' | Mass:%.1f | Vel:%.2f | %s",
                entry.Name, entry.Mass, entry.Velocity.Magnitude,
                entry.Mass > 50 and "Heavy — momentum carrier" or "Light — high maneuverability"),
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    local vel = inst.AssemblyLinearVelocity; local speed = vel.Magnitude; local newVel
                    if speed > 100 then newVel = vel.Unit * 80; inst.AssemblyLinearVelocity = newVel
                    elseif speed < 1 then newVel = Vector3.new(0,5,0); inst.AssemblyLinearVelocity = newVel
                    else newVel = vel end
                    return { Part=inst.Name, Mass=inst.AssemblyMass, VelBefore=speed, VelAfter=newVel.Magnitude, CFrame=inst.CFrame, Applied=speed>100 or speed<1 }
                end)
                return ok and result or {Error=tostring(result), Part=inst.Name}
            end,
            "Applies velocity normalization to client-owned part.",
            {CPU="medium", Network="low", Disruption="medium"}, {Risk="Medium", Confidence=80, Instance=inst, Path=entry.Path}))
    end
    if #phys.ServerOwned > 3 then
        table.insert(cards, NewCard("Ownership", "Server Physics Index",
            string.format("%d server-simulated parts.", #phys.ServerOwned),
            {PreCondAlwaysTrue},
            function(outputs)
                local buckets = {}
                for _, entry in ipairs(phys.ServerOwned) do
                    local pos = entry.CFrame.Position
                    local key = string.format("%d,%d,%d", math.floor(pos.X/16), math.floor(pos.Y/16), math.floor(pos.Z/16))
                    if not buckets[key] then buckets[key] = {} end
                    table.insert(buckets[key], entry.Name)
                end
                outputs = outputs or {}; outputs["PhysicsIndex"] = buckets
                return {BucketCount=(function() local n=0; for _ in pairs(buckets) do n=n+1 end; return n end)(), Buckets=buckets}
            end,
            "Builds spatial bucket index of server parts.",
            {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=80}))
    end
end

local function GenLatent(ws, cards)
    local lat = ws.Latent; if not lat then return end
    for _, remote in ipairs(lat.RemoteEvents or {}) do
        local inst = remote.Instance; local observed = remote.FireCount > 0
        local semantic = ClassifyRemote(remote.Name)
        local conf = observed and math.min(50 + remote.FireCount * 10, 90) or 35
        table.insert(cards, NewCard("Replication",
            string.format("[%s] %s", semantic, remote.Name),
            observed and string.format("Observed %d fires. Replay ready.", remote.FireCount)
                      or "Not yet observed. Probe-fire will attempt silent activation.",
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    if observed and remote.LastArgs and #remote.LastArgs > 0 then
                        local safeArgs = {}
                        for i, arg in ipairs(remote.LastArgs) do
                            local t = type(arg)
                            if t=="number" or t=="string" or t=="boolean" then table.insert(safeArgs, arg)
                            elseif t=="userdata" then
                                local ok2, resolved = pcall(function()
                                    return ReplicatedStorage:FindFirstChild(arg.Name, true) or Workspace:FindFirstChild(arg.Name, true)
                                end)
                                table.insert(safeArgs, ok2 and resolved or arg)
                            else table.insert(safeArgs, arg) end
                        end
                        inst:FireServer(unpack(safeArgs))
                        return { Action="Replay", Remote=remote.Name, ArgCount=#safeArgs, Semantic=semantic }
                    else
                        inst:FireServer()
                        return { Action="Probe", Remote=remote.Name, ArgCount=0, Semantic=semantic }
                    end
                end)
                return ok and result or {Error=tostring(result), Remote=remote.Name}
            end,
            observed and "Replay captured args at server." or "Probe-fire to map server behavior.",
            {CPU="low", Network=observed and "medium" or "low", Disruption=observed and "medium" or "low"},
            {Risk=observed and "Medium" or "Low", Confidence=conf, Semantic=semantic, Observed=observed, FireCount=remote.FireCount}))
    end
    for _, rfunc in ipairs(lat.RemoteFunctions or {}) do
        local inst = rfunc.Instance; local semantic = ClassifyRemote(rfunc.Name)
        table.insert(cards, NewCard("Replication",
            string.format("[Fn:%s] %s", semantic, rfunc.Name),
            "RemoteFunction — InvokeServer will capture return value.",
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    local ret = inst:InvokeServer()
                    local retStr = type(ret)=="table" and (function() local s,j=pcall(function() return HttpService:JSONEncode(ret) end); return s and j or "[table]" end)() or tostring(ret)
                    outputs = outputs or {}; outputs["RF_"..rfunc.Name] = ret
                    return { Action="Invoke", Remote=rfunc.Name, Return=retStr, Semantic=semantic }
                end)
                return ok and result or {Error=tostring(result), Remote=rfunc.Name}
            end,
            "Invokes RemoteFunction and captures return value.",
            {CPU="low", Network="medium", Disruption="low"}, {Risk="Low", Confidence=45, Semantic=semantic}))
    end
    if #lat.ValueObjects > 0 then
        table.insert(cards, NewCard("Latent", "Live Value State",
            string.format("%d value objects — live read.", #lat.ValueObjects),
            {PreCondAlwaysTrue},
            function(outputs)
                local snapshot = {}
                for _, vo in ipairs(lat.ValueObjects) do
                    local ok, current = pcall(function() local inst=game:FindFirstChild(vo.Name,true); return inst and inst.Value or vo.Value end)
                    snapshot[vo.Name] = { Path=vo.Path, Class=vo.Class, Cached=vo.Value, Current=ok and current or vo.Value, Drifted=ok and (current~=vo.Value) }
                end
                outputs = outputs or {}; outputs["ValueState"] = snapshot; return snapshot
            end,
            "Reads all value objects live.",
            {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=90}))
    end
    local mc = 0; for _ in pairs(lat.MatchState) do mc = mc + 1 end
    if mc > 0 then
        table.insert(cards, NewCard("Latent", "Match Phase Read",
            string.format("%d match/game state variables.", mc),
            {PreCondAlwaysTrue},
            function(outputs)
                local phases = {}
                for name, entry in pairs(lat.MatchState) do
                    local ok, val = pcall(function()
                        local inst = entry.Instance
                        if inst:IsA("IntValue") or inst:IsA("NumberValue") then return inst.Value
                        elseif inst:IsA("BoolValue") then return inst.Value
                        elseif inst:IsA("StringValue") then return inst.Value
                        else return tostring(inst) end
                    end)
                    phases[name] = { Value=ok and val or "unreadable", Class=entry.Class, Active=ok and val~=0 and val~=false and val~="" and val~=nil }
                end
                outputs = outputs or {}; outputs["MatchPhase"] = phases; return phases
            end,
            "Reads all match/game-phase variables live.",
            {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=85}))
    end
    local economyRemotes = {}
    for _, remote in ipairs(lat.RemoteEvents or {}) do
        if ClassifyRemote(remote.Name) == "Economy" then table.insert(economyRemotes, remote) end
    end
    if #economyRemotes > 0 then
        local names = {}; for _, r in ipairs(economyRemotes) do table.insert(names, r.Name) end
        table.insert(cards, NewCard("Latent", "Economy Surface Detected",
            string.format("%d economy-tagged remotes: %s", #economyRemotes, table.concat(names, ", ")),
            {PreCondAlwaysTrue},
            function(outputs)
                local results = {}
                for _, remote in ipairs(economyRemotes) do
                    local ok, r = pcall(function()
                        if remote.LastArgs and #remote.LastArgs > 0 then
                            remote.Instance:FireServer(unpack(remote.LastArgs)); return {Remote=remote.Name, Action="Replay", Args=#remote.LastArgs}
                        else remote.Instance:FireServer(); return {Remote=remote.Name, Action="Probe"} end
                    end)
                    table.insert(results, ok and r or {Remote=remote.Name, Error=tostring(r)}); task.wait(0.05)
                end
                outputs = outputs or {}; outputs["EconomyResult"] = results; return results
            end,
            "Fires all economy-tagged remotes.",
            {CPU="low", Network="high", Disruption="high"}, {Risk="High", Confidence=60, EconomyCount=#economyRemotes}))
    end
end

local function GenAgents(ws, cards)
    local agents = ws.Agents; if not agents or not agents.LocalPlayer then return end
    local lp = agents.LocalPlayer
    table.insert(cards, NewCard("Agent", "Local Player Sync",
        string.format("%s | HP:%.0f/%.0f | Speed:%.1f | Jump:%.1f | Tool:%s",
            lp.Name, lp.Health, lp.MaxHealth, lp.WalkSpeed, lp.JumpPower, lp.EquippedTool or "none"),
        {PreCondAlwaysTrue},
        function(outputs)
            local char = Players.LocalPlayer.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then return {Error="No humanoid found."} end
            local applied = {}
            if persistent.WalkSpeed and hum.WalkSpeed ~= persistent.WalkSpeed then pcall(function() hum.WalkSpeed=persistent.WalkSpeed end); table.insert(applied,"WalkSpeed→"..persistent.WalkSpeed) end
            if persistent.JumpPower and hum.JumpPower ~= persistent.JumpPower then pcall(function() hum.JumpPower=persistent.JumpPower end); table.insert(applied,"JumpPower→"..persistent.JumpPower) end
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local snapshot = { Name=Players.LocalPlayer.Name, Health=hum.Health, MaxHealth=hum.MaxHealth, WalkSpeed=hum.WalkSpeed, JumpPower=hum.JumpPower, HumState=tostring(hum:GetState()), Position=hrp and hrp.Position or Vector3.new(), Applied=applied }
            outputs = outputs or {}; outputs["AgentState"] = snapshot; return snapshot
        end,
        "Snapshots local player state and re-applies persistent movement settings.",
        {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=100}))
    if lp.Health > 0 then
        table.insert(cards, NewCard("Agent", "Spatial Context", "Local character position and velocity for spatial reasoning.",
            {PreCondAlwaysTrue},
            function(outputs)
                local char = Players.LocalPlayer.Character; local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if not hrp then return {Error="HumanoidRootPart not found."} end
                local pos = hrp.Position; local vel = hrp.AssemblyLinearVelocity
                local proximity = {}
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= Players.LocalPlayer and p.Character then
                        local oHRP = p.Character:FindFirstChild("HumanoidRootPart")
                        if oHRP then table.insert(proximity, { Name=p.Name, Dist=(oHRP.Position-pos).Magnitude }) end
                    end
                end
                table.sort(proximity, function(a,b) return a.Dist<b.Dist end)
                local result = { Position=pos, Velocity=vel, Speed=vel.Magnitude, Proximity=proximity,
                    Grounded=(function() local hum=char:FindFirstChildOfClass("Humanoid"); return hum and hum:GetState()==Enum.HumanoidStateType.Running end)() }
                outputs = outputs or {}; outputs["SpatialContext"] = result; return result
            end,
            "Builds spatial context.", {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=95}))
        if lp.EquippedTool then
            table.insert(cards, NewCard("Agent", "Activate Tool: " .. lp.EquippedTool,
                string.format("Tool '%s' equipped.", lp.EquippedTool),
                {PreCondAlwaysTrue},
                function(outputs)
                    local char = Players.LocalPlayer.Character; local tool = char and char:FindFirstChildOfClass("Tool")
                    if not tool then return {Error="Tool no longer equipped."} end
                    local activated = false; local ok = pcall(function() tool:Activate(); activated=true end)
                    if not ok then local handle=tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart"); if handle then activated=false end end
                    return { Tool=tool.Name, Activated=activated, Handle=tool:FindFirstChild("Handle")~=nil }
                end,
                "Activates currently equipped tool.",
                {CPU="low", Network="medium", Disruption="medium"}, {Risk="Medium", Confidence=70, ToolName=lp.EquippedTool}))
        end
    end
    for _, other in ipairs(agents.OtherPlayers or {}) do
        if lp.CFrame then
            local dist = (other.CFrame.Position - lp.CFrame.Position).Magnitude
            if dist < 60 then
                table.insert(cards, NewCard("Agent", "Track: " .. other.Name,
                    string.format("%s | HP:%.0f/%.0f | Dist:%.1fm", other.Name, other.Health, other.MaxHealth, dist),
                    {PreCondAlwaysTrue},
                    function(outputs)
                        local tp=Players:FindFirstChild(other.Name); local tc=tp and tp.Character
                        local tHRP=tc and tc:FindFirstChild("HumanoidRootPart"); local tHum=tc and tc:FindFirstChildOfClass("Humanoid")
                        local myChar=Players.LocalPlayer.Character; local myHRP=myChar and myChar:FindFirstChild("HumanoidRootPart")
                        local liveDist=(tHRP and myHRP) and (tHRP.Position-myHRP.Position).Magnitude or dist
                        local result = { Name=other.Name, Health=tHum and tHum.Health or other.Health, MaxHealth=tHum and tHum.MaxHealth or other.MaxHealth,
                            Distance=liveDist, Position=tHRP and tHRP.Position or other.CFrame.Position,
                            Alive=(tHum and tHum.Health>0) or other.Health>0,
                            Approach=liveDist<20 and "Close" or liveDist<50 and "Mid" or "Far" }
                        outputs = outputs or {}
                        if not outputs["TrackedPlayers"] then outputs["TrackedPlayers"]={} end
                        outputs["TrackedPlayers"][other.Name] = result; return result
                    end,
                    "Tracks player live.", {CPU="low", Network="none", Disruption="none"}, {Risk="None", Confidence=80, TargetName=other.Name}))
            end
        end
    end
end

local function GenNetwork(ws, cards)
    local lat = ws.Latent; if not lat then return end
    local evCount  = #(lat.RemoteEvents or {}); local fnCount = #(lat.RemoteFunctions or {})
    local observed = 0; for _, r in ipairs(lat.RemoteEvents or {}) do if r.FireCount>0 then observed=observed+1 end end
    if evCount + fnCount > 0 then
        table.insert(cards, NewCard("Network", "Network Surface Map",
            string.format("%d events (%d observed) | %d functions — surface mapped.", evCount, observed, fnCount),
            {PreCondAlwaysTrue},
            function(outputs)
                local surface = { Events=evCount, Functions=fnCount, Observed=observed, Coverage=math.floor(observed/math.max(evCount,1)*100) }
                outputs = outputs or {}; outputs["NetworkSurface"] = surface; return surface
            end,
            "Summarizes known network surface.",
            {CPU="none", Network="none", Disruption="none"}, {Risk="None", Confidence=95}))
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
-- MULTI-OBJECTIVE VALUE SYSTEM
-- ============================================================
local ValueWeights = { Reliability=1.0, InformationGain=0.8, Cost=0.7, Reversibility=0.9, Optionality=0.7, Stability=0.8 }
local ValueHistory = { WeightUpdates=0 }
local COST_SCORES  = { none=1.0, low=0.85, medium=0.65, high=0.40 }
local ValueSystem  = {}

function ValueSystem.ScoreCard(card, allCards, intelHistory)
    local h = intelHistory and intelHistory[card.ID]
    local reliability = h and (h.alpha/(h.alpha+h.beta)) or (card.Metadata.Confidence or 50)/100
    local conf = card.Metadata.Confidence or 50
    local infoGain = 1.0 - (conf/100)*0.6
    local cpu=COST_SCORES[card.Cost and card.Cost.CPU or "none"] or 1.0
    local net=COST_SCORES[card.Cost and card.Cost.Network or "none"] or 1.0
    local dis=COST_SCORES[card.Cost and card.Cost.Disruption or "none"] or 1.0
    local costScore=(cpu+net+dis)/3
    local risk=card.Metadata.Risk or "None"
    local reversibility = risk=="None" and 1.0 or risk=="Low" and 0.85 or risk=="Medium" and 0.60 or 0.30
    local downstream=0; for _,o in ipairs(allCards) do if o.Channel~=card.Channel then downstream=downstream+1 end end
    local optionality=math.clamp(downstream/math.max(#allCards,1),0,1)
    local stability = dis==1.0 and 1.0 or dis==0.85 and 0.80 or dis==0.65 and 0.55 or 0.25
    local totalWeight=0; for _,w in pairs(ValueWeights) do totalWeight=totalWeight+w end
    local score=(reliability*ValueWeights.Reliability + infoGain*ValueWeights.InformationGain + costScore*ValueWeights.Cost +
        reversibility*ValueWeights.Reversibility + optionality*ValueWeights.Optionality + stability*ValueWeights.Stability)/totalWeight
    return { Total=score, Reliability=reliability, InfoGain=infoGain, Cost=costScore, Reversibility=reversibility, Optionality=optionality, Stability=stability }
end
function ValueSystem.ScoreChain(chain, allCards, intelHistory)
    local total=0.0; local discount=1.0; local completedAll=true
    for i, step in ipairs(chain) do
        local axisScores=ValueSystem.ScoreCard(step.Card, allCards, intelHistory)
        local sv=axisScores.Total*(step.Success and 1.0 or 0.2)
        if not step.Success and i>1 and chain[i-1].Success then sv=sv*0.7 end
        total=total+sv*discount; discount=discount*0.95
        if not step.Success then completedAll=false end
    end
    if completedAll then total=total+0.15 end
    local maxVal=0; local d=1.0
    for _=1,#chain do maxVal=maxVal+d; d=d*0.95 end
    maxVal=maxVal+0.15
    return math.clamp(total/math.max(maxVal,0.001),0,1)
end
function ValueSystem.AdaptWeights(log, allCards)
    ValueHistory.WeightUpdates=ValueHistory.WeightUpdates+1
    for _, result in ipairs(log) do
        local axisScores=ValueSystem.ScoreCard(result.Step, allCards, nil)
        local axisMap={ Reliability=axisScores.Reliability, InformationGain=axisScores.InfoGain,
            Cost=axisScores.Cost, Reversibility=axisScores.Reversibility, Optionality=axisScores.Optionality, Stability=axisScores.Stability }
        for axis, score in pairs(axisMap) do
            local delta=result.Success and (score*0.02) or -(score*0.03)
            ValueWeights[axis]=math.clamp((ValueWeights[axis] or 1.0)+delta, 0.1, 2.0)
        end
    end
end

-- ============================================================
-- COGNITIVE INTELLIGENCE v3
-- ============================================================
local Intel    = {}
local CFG_INTEL = { MemoryDecayRate=0.88, PhaseShiftThreshold=0.25, OverfitDetectionWindow=4, VariancePenaltyCoeff=0.35 }
local IntelMem = {
    CardHistory={}, ChannelTimeseries={ Structural={},Metabolic={},Ownership={},Replication={},Latent={},Agent={},Network={} },
    ChannelWeights={ Structural=1.0,Metabolic=1.0,Ownership=1.0,Replication=1.0,Latent=1.0,Agent=1.0,Network=1.0 },
    FailureHeuristics={}, CalibrationLog={}, PhaseShifts={}, OverfitStreak=0, Cycles=0,
}
local function GetOrInitCard(id, initConf)
    if not IntelMem.CardHistory[id] then
        local p=math.clamp(initConf/100,0.01,0.99); local scale=8
        IntelMem.CardHistory[id]={ alpha=p*scale, beta=(1-p)*scale, n=0, mean=p, M2=0.0, StdDev=0.0, Timeline={}, Confidence=initConf }
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
local function ThompsonScore(card, h)
    local sample=SampleBeta(math.max(h.alpha,0.1),math.max(h.beta,0.1))
    local vp=h.StdDev*CFG_INTEL.VariancePenaltyCoeff
    local cw=IntelMem.ChannelWeights[card.Channel] or 1.0
    local pd=1.0
    for _,s in ipairs(IntelMem.PhaseShifts) do if s.Channel==card.Channel and IntelMem.Cycles-s.Cycle<=2 then pd=0.75; break end end
    local pat=card.Channel..":"..(card.Metadata.Condition or "general")
    local fh=IntelMem.FailureHeuristics[pat]
    local fp=fh and fh.penalty or 0.0
    return math.max((sample-vp)*cw*pd*(1-fp),0.0)
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
    for _,r in ipairs(log) do
        local ch=r.Step.Channel; if not chR[ch] then chR[ch]={total=0,success=0} end
        chR[ch].total=chR[ch].total+1; if r.Success then chR[ch].success=chR[ch].success+1 end
    end
    for ch, data in pairs(chR) do
        if IntelMem.ChannelTimeseries[ch] then
            local rate=data.success/math.max(data.total,1)
            table.insert(IntelMem.ChannelTimeseries[ch], rate)
            if #IntelMem.ChannelTimeseries[ch]>10 then table.remove(IntelMem.ChannelTimeseries[ch],1) end
        end
    end
    for _,r in ipairs(log) do
        local card=r.Step; local h=GetOrInitCard(card.ID, card.Metadata.Confidence or 50)
        table.insert(h.Timeline, {result=r.Success,cycle=cycle})
        WelfordUpdate(h, r.Success and 1.0 or 0.0)
        UpdatePosterior(h, r.Success)
        card.Metadata.Confidence=math.floor(h.Confidence)
        if not r.Success then
            local pat=card.Channel..":"..(card.Metadata.Condition or "general")
            if not IntelMem.FailureHeuristics[pat] then IntelMem.FailureHeuristics[pat]={count=0,penalty=0.0} end
            local fh=IntelMem.FailureHeuristics[pat]; fh.count=fh.count+1
            fh.penalty=math.min(fh.penalty*CFG_INTEL.MemoryDecayRate+0.15, 0.80)
        end
        local cw=IntelMem.ChannelWeights[card.Channel] or 1.0
        IntelMem.ChannelWeights[card.Channel]=math.clamp(cw+(r.Success and 0.04 or -0.07),0.2,2.0)
        local s=IntelMem.ChannelTimeseries[card.Channel]
        if s and #s>=4 then
            local rM=(s[#s]+s[#s-1])/2; local pM=(s[#s-2]+s[#s-3])/2
            if pM-rM>=CFG_INTEL.PhaseShiftThreshold then
                table.insert(IntelMem.PhaseShifts, {Channel=card.Channel,Cycle=cycle,PriorMean=pM,RecentMean=rM})
            end
        end
        table.insert(IntelMem.CalibrationLog, {Predicted=(card.Metadata.Confidence or 50)/100,Actual=r.Success and 1 or 0,Cycle=cycle})
    end
    local allCorrect=true
    for _,r in ipairs(log) do if ((r.Step.Metadata.Confidence or 50)>=60)~=r.Success then allCorrect=false; break end end
    IntelMem.OverfitStreak=allCorrect and IntelMem.OverfitStreak+1 or 0
    if IntelMem.OverfitStreak>=CFG_INTEL.OverfitDetectionWindow then IntelMem.OverfitStreak=0 end
end
function Intel.GetMemory() return IntelMem end

-- ============================================================
-- DYNAMICS MODEL
-- ============================================================
local DynamicsTable={}; local DynamicsModel={}
local function ExtractSig(ws)
    if not ws then return {} end
    return {
        PlayerHealth   = ws.Agents.LocalPlayer and ws.Agents.LocalPlayer.Health or 0,
        PhysicsCount   = #(ws.Physics.SimulatedAssemblies or {}),
        ClientOwned    = #(ws.Physics.ClientOwned or {}),
        RemoteFireTotal= (function() local t=0; for _,r in ipairs(ws.Latent.RemoteEvents or {}) do t=t+r.FireCount end; return t end)(),
        StreamedIn     = #(ws.Network.StreamedIn or {}),
    }
end
function DynamicsModel.Record(cardID, wsBefore, wsAfter, success)
    if not DynamicsTable[cardID] then DynamicsTable[cardID]={Deltas={},Successes=0,Attempts=0} end
    local e=DynamicsTable[cardID]; e.Attempts=e.Attempts+1
    if success then e.Successes=e.Successes+1 end
    if wsBefore and wsAfter then
        local sigB=ExtractSig(wsBefore); local sigA=ExtractSig(wsAfter)
        local delta={}; for k,v in pairs(sigB) do delta[k]=(sigA[k] or 0)-v end
        table.insert(e.Deltas, delta)
    end
end
function DynamicsModel.GetSuccessRate(cardID)
    local e=DynamicsTable[cardID]; if not e or e.Attempts==0 then return 0.5 end
    return e.Successes/e.Attempts
end

-- ============================================================
-- TRANSITION MODEL
-- ============================================================
local TransitionTable={}; local TransitionModel={}
local function GetOrInitPair(prevID, nextID)
    if not TransitionTable[prevID] then TransitionTable[prevID]={} end
    if not TransitionTable[prevID][nextID] then TransitionTable[prevID][nextID]={aGivenS=1.0,bGivenS=1.0,aGivenF=1.0,bGivenF=1.0,observations=0} end
    return TransitionTable[prevID][nextID]
end
function TransitionModel.Update(log)
    for i=1,#log-1 do
        local prev=log[i]; local nxt=log[i+1]; local pair=GetOrInitPair(prev.Step.ID,nxt.Step.ID)
        pair.observations=pair.observations+1
        if prev.Success then if nxt.Success then pair.aGivenS=pair.aGivenS+1 else pair.bGivenS=pair.bGivenS+1 end
        else if nxt.Success then pair.aGivenF=pair.aGivenF+1 else pair.bGivenF=pair.bGivenF+1 end end
    end
end
function TransitionModel.Sample(prevID, nextID, prevSucc)
    if not TransitionTable[prevID] or not TransitionTable[prevID][nextID] then return 0.5 end
    local p=TransitionTable[prevID][nextID]
    return prevSucc and SampleBetaApprox(p.aGivenS,p.bGivenS) or SampleBetaApprox(p.aGivenF,p.bGivenF)
end

-- ============================================================
-- CHAIN EXECUTOR (with CDG causal reordering)
-- ============================================================
local CausalOrder={"Structural","Metabolic","Ownership","Replication","Latent","Agent","Network"}
local CausalReasons={
    Structural="Architecture context required before behavioral reasoning.",
    Metabolic="Physics timing must be known before interaction.",
    Ownership="Authority must be resolved before replication targeting.",
    Replication="Network endpoints must be mapped before latent access.",
    Latent="Hidden state must be read before agent interaction.",
    Agent="Agent state must be confirmed before network operations.",
    Network="Replication boundary must be known before execution.",
}
local Executor={}
local function ValidatePreconditions(card, ws)
    for _,pre in ipairs(card.Preconditions or {}) do
        local ok, reason=pre(ws); if not ok then return false, reason or "Precondition failed." end
    end
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
    for _,card in ipairs(chain) do
        local risk=card.Metadata.Risk or "None"
        if risk=="High" or risk=="Medium" then return true end
        if card.Cost and (card.Cost.Disruption=="high" or card.Cost.Disruption=="medium") then return true end
    end
    return false
end
local function ExecuteFastPath(chain, ws)
    local log={}; local outputs={}
    for i, card in ipairs(chain) do
        if card._Skip then continue end
        local valid, reason=ValidatePreconditions(card, ws)
        if not valid then
            table.insert(log, {Step=card,Success=false,Reason=reason,Time=os.clock()})
            table.insert(card.TelemetryLog, {success=false,reason=reason,t=os.clock()})
            continue
        end
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
        local freshWS=WorldState.Capture()
        local valid, reason=ValidatePreconditions(card, freshWS)
        if not valid then
            table.insert(log, {Step=card,Success=false,Stage="Observe",Reason=reason,Time=os.clock()})
            table.insert(card.TelemetryLog, {success=false,stage="observe",t=os.clock()})
            continue
        end
        local probeSuccess=true; local probeReason="Probe passed."
        if card.Metadata.Instance then
            local ok=pcall(function() return card.Metadata.Instance.Parent~=nil end)
            probeSuccess=ok; probeReason=ok and "Target reachable." or "Target unreachable."
        end
        if not probeSuccess then
            table.insert(log, {Step=card,Success=false,Stage="Probe",Reason=probeReason,Time=os.clock()})
            table.insert(card.TelemetryLog, {success=false,stage="probe",t=os.clock()})
            continue
        end
        local success, output=pcall(function() return card.Action(outputs) end)
        if not success then
            table.insert(log, {Step=card,Success=false,Stage="Commit",Reason=tostring(output),Time=os.clock()})
            table.insert(card.TelemetryLog, {success=false,stage="commit",t=os.clock()})
            for j=i+1,#chain do if chain[j].Metadata.Instance==card.Metadata.Instance then chain[j]._Skip=true end end
            continue
        end
        if output then outputs[card.Channel]=output end
        task.wait(0.05)
        local verifyWS=WorldState.Capture()
        local verified=output==nil or type(output)=="table"
        local entry={Step=card,Success=verified,Output=verified and output or nil,Stage="Verify",
            Reason=verified and "Output valid." or "Output invalid.",Time=os.clock(),WorldStateAfter=verifyWS}
        table.insert(log, entry); table.insert(card.TelemetryLog, {success=verified,stage="verify",t=os.clock()})
    end
    return log
end
function Executor.Execute(selected, all, ws)
    assert(#selected>0, "[RAE:Executor] No cards selected.")
    local chain    = ResolveDeps(selected, all)
    local reordered = CDG.ReorderChain(chain)   -- CDG causal reordering
    if IsHighStakes(reordered) then return ExecuteStagedPath(reordered, ws)
    else return ExecuteFastPath(reordered, ws) end
end
function Executor.Preview(selected, all)
    local chain    = ResolveDeps(selected, all)
    local reordered = CDG.ReorderChain(chain)
    return reordered, IsHighStakes(reordered)
end

-- ============================================================
-- MCTS PLANNER v2 — Risk-adjusted: E[U] − λ·Var[U] − μ·Cost
-- ETM-blended rollouts. Confidence gating via ETM+IntelMem.
-- ============================================================
local MCTS_CFG = { Simulations=200, MaxDepth=6, UCB_C=1.41, MinCardConf=0.20 }
local RISK_CFG = { Lambda=0.25, Mu=0.12, ConfidenceGateThreshold=0.28 }

local function NewNode(card, parent, depth)
    return { Card=card, Parent=parent, Children={}, Depth=depth,
             Visits=0, TotalReward=0.0, MeanReward=0.0, TotalRewardSq=0.0, Variance=0.0 }
end
local function UCB1(node, parentVisits)
    if node.Visits==0 then return math.huge end
    local riskPenalty = RISK_CFG.Lambda * math.sqrt(math.max(node.Variance,0))
    local explore     = MCTS_CFG.UCB_C  * math.sqrt(math.log(parentVisits)/node.Visits)
    return (node.MeanReward - riskPenalty) + explore
end
local function Rollout(startNode, viable, allCards, intelHistory, maxDepth)
    local chain={}; local prevCard=startNode.Card; local prevSucc=true; local depth=startNode.Depth
    local node=startNode; local nc={}
    while node do if node.Card then table.insert(nc,1,{Card=node.Card,Success=true}) end; node=node.Parent end
    for _,s in ipairs(nc) do table.insert(chain,s) end
    local currentSig = LWM.GetRecentSig()
    while depth < maxDepth do
        if #viable==0 then break end
        local nextCard = viable[math.random(#viable)]
        local etmProb, etmConverged, _ = ETM.Predict(nextCard.ID, currentSig)
        local transProb = TransitionModel.Sample(prevCard.ID, nextCard.ID, prevSucc)
        local dynRate   = DynamicsModel.GetSuccessRate(nextCard.ID)
        local blended
        if etmConverged then blended = etmProb*0.70 + transProb*0.20 + dynRate*0.10
        else                 blended = etmProb*0.35 + transProb*0.40 + dynRate*0.25 end
        local simSucc = math.random() < blended
        table.insert(chain, {Card=nextCard,Success=simSucc})
        prevCard=nextCard; prevSucc=simSucc; depth=depth+1
    end
    return ValueSystem.ScoreChain(chain, allCards, intelHistory), chain
end

local Planner={}
function Planner.Plan(availableCards, lastLog, intelHistory)
    if lastLog and #lastLog>0 then TransitionModel.Update(lastLog) end
    local currentSig = LWM.GetRecentSig()
    local viable = {}
    for _, card in ipairs(availableCards) do
        local baseConf = (card.Metadata.Confidence or 50)/100
        if baseConf >= MCTS_CFG.MinCardConf then
            local etmProb, etmConverged, _ = ETM.Predict(card.ID, currentSig)
            local effectiveConf = etmConverged and etmProb or (baseConf*0.6 + etmProb*0.4)
            if effectiveConf >= RISK_CFG.ConfidenceGateThreshold then
                table.insert(viable, card)
            end
        end
    end
    if #viable==0 then return nil end
    local root = NewNode(nil,nil,0)
    for _=1,MCTS_CFG.Simulations do
        local node=root
        while #node.Children>0 and node.Visits>0 do
            local best,bestScore=nil,-math.huge
            for _,child in ipairs(node.Children) do local s=UCB1(child,node.Visits); if s>bestScore then bestScore=s; best=child end end
            node=best
        end
        local explored={}; for _,child in ipairs(node.Children) do if child.Card then explored[child.Card.ID]=true end end
        local unexplored={}; for _,card in ipairs(viable) do if not explored[card.ID] then table.insert(unexplored,card) end end
        local expandNode=node
        if #unexplored>0 then
            local nc=unexplored[math.random(#unexplored)]
            expandNode=NewNode(nc,node,node.Depth+1); table.insert(node.Children,expandNode)
        end
        local reward=0
        if expandNode.Card then reward,_=Rollout(expandNode,viable,availableCards,intelHistory,MCTS_CFG.MaxDepth) end
        local back=expandNode
        while back do
            back.Visits=back.Visits+1; back.TotalReward=back.TotalReward+reward
            back.TotalRewardSq=back.TotalRewardSq+reward*reward
            back.MeanReward=back.TotalReward/back.Visits
            back.Variance=(back.TotalRewardSq/back.Visits)-(back.MeanReward*back.MeanReward)
            back=back.Parent
        end
    end
    local bestChain={}; local node=root; local depth=0
    while #node.Children>0 and depth<MCTS_CFG.MaxDepth do
        local best,bestR=nil,-math.huge
        for _,child in ipairs(node.Children) do
            if child.Visits>0 then
                local riskAdj=child.MeanReward - RISK_CFG.Lambda*math.sqrt(math.max(child.Variance,0))
                if riskAdj>bestR then bestR=riskAdj; best=child end
            end
        end
        if not best then break end
        table.insert(bestChain, {Card=best.Card,ProjectedReward=best.MeanReward,Variance=best.Variance,Visits=best.Visits})
        node=best; depth=depth+1
    end
    return bestChain
end

-- ============================================================
-- SESSION PERSISTENCE (_G)
-- ============================================================
local PERSIST_VER   = "v2"
local PERSIST_INTEL = "RAE_IntelMem_"  .. PERSIST_VER
local PERSIST_ETM   = "RAE_ETM_Table_" .. PERSIST_VER
local PERSIST_CDG   = "RAE_CDG_Table_" .. PERSIST_VER

local function SaveSession()
    pcall(function()
        _G[PERSIST_INTEL] = IntelMem
        _G[PERSIST_ETM]   = ETM.GetTableRef()
        _G[PERSIST_CDG]   = CDG.GetTableRef()
    end)
end
local function LoadSession()
    pcall(function()
        if type(_G[PERSIST_INTEL])=="table" then
            local saved=_G[PERSIST_INTEL]
            if type(saved.CardHistory)=="table" then
                for id,h in pairs(saved.CardHistory) do if not IntelMem.CardHistory[id] then IntelMem.CardHistory[id]=h end end
            end
            if type(saved.ChannelWeights)=="table" then
                for ch,w in pairs(saved.ChannelWeights) do if type(w)=="number" then IntelMem.ChannelWeights[ch]=w end end
            end
            IntelMem.Cycles=math.max(IntelMem.Cycles, type(saved.Cycles)=="number" and saved.Cycles or 0)
        end
        if type(_G[PERSIST_ETM])=="table" then ETM.SetTableRef(_G[PERSIST_ETM]) end
        if type(_G[PERSIST_CDG])=="table" then CDG.SetTableRef(_G[PERSIST_CDG]) end
    end)
end

-- Brier Score: mean squared error of predicted prob vs actual outcome (last 100 entries)
local function ComputeBrierScore()
    local log = IntelMem.CalibrationLog
    if not log or #log==0 then return nil end
    local n=math.min(#log,100); local sum=0.0
    for i=#log-n+1,#log do
        local e=log[i]; if e then sum=sum+(e.Predicted-e.Actual)^2 end
    end
    return sum/n
end

-- ============================================================
-- RAE ENGINE STATE
-- ============================================================
local RAE_State = {
    Phase="DORMANT", WorldState=nil, Cards={}, SelectedCards={},
    LastLog=nil, LastPlan=nil, CycleCount=0, _IndexMap={},
    CurrentSig="null_sig",
}
local RAE_Callbacks  = { OnScan=nil, OnPlan=nil, OnCommit=nil, OnPhase=nil }
local RAE_SilentMode = false

local function RAE_SetPhase(phase)
    RAE_State.Phase=phase
    if RAE_Callbacks.OnPhase then RAE_Callbacks.OnPhase(phase) end
end
local function RAE_Scan()
    RAE_SetPhase("SCANNING")
    local ws  = WorldState.Capture()
    local sig = StateSignature.Compute(ws)
    RAE_State.WorldState = ws; RAE_State.CurrentSig = sig
    LWM.Record(ws, sig)
    local confidence=0
    if ws.ObjectGraph.TotalInstances>0 then confidence=confidence+20 end
    if ws.SimConfig.Gravity then confidence=confidence+20 end
    if #ws.Physics.SimulatedAssemblies>0 then confidence=confidence+20 end
    if #ws.Latent.RemoteEvents>0 then confidence=confidence+20 end
    if ws.Agents.LocalPlayer then confidence=confidence+20 end
    if confidence<40 then RAE_SetPhase("DORMANT"); return false end
    local cards=CardGenesis.Generate(ws)
    RAE_State.Cards=cards
    local idx=1; RAE_State._IndexMap={}
    for _,card in ipairs(cards) do RAE_State._IndexMap[idx]=card; idx=idx+1 end
    RAE_SetPhase("READY")
    if RAE_Callbacks.OnScan then RAE_Callbacks.OnScan(ws, cards) end
    return true
end
local function RAE_Plan()
    if RAE_State.Phase~="READY" then return nil end
    local plan=Planner.Plan(RAE_State.Cards, RAE_State.LastLog, Intel.GetMemory().CardHistory)
    RAE_State.LastPlan=plan
    if plan and #plan>0 then
        RAE_State.SelectedCards={}
        for _,step in ipairs(plan) do table.insert(RAE_State.SelectedCards, step.Card) end
        if RAE_Callbacks.OnPlan then RAE_Callbacks.OnPlan(plan) end
    end
    return plan
end
local function RAE_Commit()
    if #RAE_State.SelectedCards==0 then return nil end
    RAE_SetPhase("EXECUTING")
    local wsBefore=RAE_State.WorldState; local sigBefore=RAE_State.CurrentSig
    local log=Executor.Execute(RAE_State.SelectedCards, RAE_State.Cards, wsBefore)
    local wsAfter=WorldState.Capture(); local sigAfter=StateSignature.Compute(wsAfter)
    for _,r in ipairs(log) do
        DynamicsModel.Record(r.Step.ID, wsBefore, wsAfter, r.Success)
        ETM.Update(r.Step.ID, sigBefore, r.Success)
    end
    CDG.UpdateFromLog(log)
    LWM.Record(wsAfter, sigAfter)
    RAE_State.LastLog=log; RAE_State.CycleCount=RAE_State.CycleCount+1
    RAE_State.SelectedCards={}; RAE_State.CurrentSig=sigAfter
    Intel.ProcessFeedback(log, RAE_State.Cards)
    TransitionModel.Update(log)
    ValueSystem.AdaptWeights(log, RAE_State.Cards)
    SaveSession()
    RAE_SetPhase("COMPLETE"); RAE_SetPhase("READY")
    if RAE_Callbacks.OnCommit then RAE_Callbacks.OnCommit(log) end
    return log
end

-- ============================================================
-- UI ROOT / WINDOW
-- ============================================================
local screenGui = mk("ScreenGui", {
    Name="PaperClayUI", ResetOnSpawn=false, IgnoreGuiInset=true,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, Parent=playerGui,
})
local root = mk("Frame", { Name="Root", BackgroundTransparency=1, Size=UDim2.new(1,0,1,0), Parent=screenGui })
local window = mk("Frame", {
    Name="Window", BackgroundColor3=Color3.fromRGB(250,247,242), BorderSizePixel=0,
    AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,960,0,580),
    ZIndex=10, Parent=root,
})
addCorner(window, UDim.new(0,18)); addStroke(window,1,0.22); addShadow(window,10)
mk("UISizeConstraint", {MinSize=Vector2.new(720,440),MaxSize=Vector2.new(1200,820),Parent=window})
mk("UIGradient", {Rotation=90,Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(252,249,245)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(246,241,234))}),Parent=window})

-- ── Notification Engine ──────────────────────────────────────
local notifContainer = mk("Frame", {
    Name="NotifContainer", BackgroundTransparency=1,
    AnchorPoint=Vector2.new(1,0), Position=UDim2.new(1,-16,0,64),
    Size=UDim2.new(0,260,1,-80), ZIndex=100, Parent=window,
})
mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,HorizontalAlignment=Enum.HorizontalAlignment.Right,
    VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=notifContainer})

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
    task.delay(3.5,function()
        if toast and toast.Parent then
            tween(toast,TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.In),{BackgroundTransparency=1,Position=UDim2.new(0,50,0,0)})
            tween(strk,TweenInfo.new(0.25),{Transparency=1}); tween(iLabel,TweenInfo.new(0.25),{TextTransparency=1}); tween(tLabel,TweenInfo.new(0.25),{TextTransparency=1})
            task.delay(0.25,function() if toast then toast:Destroy() end end)
        end
    end)
end

RAE_Callbacks.OnPhase = function(phase)
    if RAE_SilentMode then return end
    if phase=="SCANNING"  then sendNotification("RAE: Scanning WorldState...", "Info")
    elseif phase=="READY" then sendNotification("RAE: Ready ("..#RAE_State.Cards.." cards)", "Success")
    elseif phase=="EXECUTING" then sendNotification("RAE: Executing chain...", "Info") end
end

-- ── Bytecode Viewer ──────────────────────────────────────────
local bytecodeViewer=mk("Frame",{Name="BytecodeViewer",BackgroundColor3=Color3.fromRGB(0,0,0),BackgroundTransparency=0.5,Size=UDim2.new(1,0,1,0),ZIndex=50,Visible=false,Parent=screenGui})
local bcWindow=mk("Frame",{BackgroundColor3=Color3.fromRGB(250,247,242),AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.new(0.5,0,0.5,0),Size=UDim2.new(0,700,0,500),Parent=bytecodeViewer})
addCorner(bcWindow,UDim.new(0,14)); addStroke(bcWindow,1,0.2); addShadow(bcWindow,50)
local bcTopbar=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,40),Parent=bcWindow})
local bcTitle=mk("TextLabel",{Text=" Bytecode VM Viewer",Font=Enum.Font.GothamBold,TextSize=14,TextColor3=Color3.fromRGB(40,40,40),BackgroundTransparency=1,Size=UDim2.new(1,-60,1,0),Position=UDim2.new(0,16,0,0),TextXAlignment=Enum.TextXAlignment.Left,Parent=bcTopbar})
local bcClose=mk("TextButton",{Text="✕",Font=Enum.Font.GothamBold,TextSize=14,TextColor3=Color3.fromRGB(40,40,40),BackgroundTransparency=1,Size=UDim2.new(0,40,0,40),AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,0,0,0),Parent=bcTopbar})
bcClose.MouseButton1Click:Connect(function() clickSound(); bytecodeViewer.Visible=false end)
local bcScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(240,238,235),BorderSizePixel=0,Position=UDim2.new(0,16,0,40),Size=UDim2.new(1,-32,1,-56),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=6,Parent=bcWindow})
addCorner(bcScroll,UDim.new(0,8)); addStroke(bcScroll,1,0.3)
local bcText=mk("TextBox",{Text="",Font=Enum.Font.Code,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,-16,0,0),AutomaticSize=Enum.AutomaticSize.Y,Position=UDim2.new(0,8,0,8),ClearTextOnFocus=false,TextEditable=false,MultiLine=true,Parent=bcScroll})
local function displayDecompiledScript(targetScript)
    if not targetScript then return end
    bcTitle.Text=" Bytecode: "..targetScript.Name; bcText.Text="Ripping bytecode..."; bytecodeViewer.Visible=true
    task.spawn(function()
        if getscriptbytecode then bcText.Text=disassembleBytecode(getscriptbytecode(targetScript))
        else bcText.Text="Error: getscriptbytecode missing from executor." end
    end)
end

-- ── UI Component Factories ────────────────────────────────────
local function makeButton(parent, text, size, iconText)
    local btn=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(246,242,236),BorderSizePixel=0,Size=size or UDim2.new(0,160,0,40),Font=Enum.Font.GothamSemibold,Text="",TextSize=14,Parent=parent})
    addCorner(btn,UDim.new(0,12)); addStroke(btn,1,0.25)
    mk("UIPadding",{PaddingLeft=UDim.new(0,12),PaddingRight=UDim.new(0,12),Parent=btn})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Left,VerticalAlignment=Enum.VerticalAlignment.Center,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=btn})
    local icon=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=iconText or "⬤",TextColor3=Color3.fromRGB(96,84,72),TextSize=14,Size=UDim2.new(0,18,0,18),Parent=btn})
    local label=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamSemibold,Text=text or "Button",TextColor3=Color3.fromRGB(52,47,42),TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-30,1,0),Parent=btn})
    hookHover(btn,btn.BackgroundColor3,Color3.fromRGB(252,249,244),0.25,0.1)
    return {Button=btn,Label=label,Icon=icon}
end
local function makeSection(parent, titleText)
    local card=mk("Frame",{BackgroundColor3=Color3.fromRGB(247,243,237),BorderSizePixel=0,Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=parent})
    addCorner(card,UDim.new(0,14)); addStroke(card,1,0.35)
    mk("UIPadding",{PaddingTop=UDim.new(0,14),PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,14),PaddingBottom=UDim.new(0,14),Parent=card})
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=titleText or "Section",TextColor3=Color3.fromRGB(52,47,42),TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),Parent=card})
    local holder=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,26),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=card})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,HorizontalAlignment=Enum.HorizontalAlignment.Left,VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=holder})
    return card, holder
end
local function makeToggle(parent, text, defaultOn, onChanged)
    local row=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,34),Parent=parent})
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text=text or "Toggle",TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-70,1,0),Parent=row})
    local btn=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(238,231,221),BorderSizePixel=0,AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,0,0.5,0),Size=UDim2.new(0,56,0,26),Text="",Parent=row})
    addCorner(btn,UDim.new(0,999)); addStroke(btn,1,0.45)
    local knob=mk("Frame",{BackgroundColor3=Color3.fromRGB(250,247,242),BorderSizePixel=0,AnchorPoint=Vector2.new(0,0.5),Position=UDim2.new(0,3,0.5,0),Size=UDim2.new(0,20,0,20),Parent=btn})
    addCorner(knob,UDim.new(0,999)); addStroke(knob,1,0.6)
    local state=defaultOn and true or false
    local function render()
        if state then tween(btn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(220,212,202)}); tween(knob,TweenInfo.new(0.12),{Position=UDim2.new(1,-23,0.5,0)})
        else tween(btn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(238,231,221)}); tween(knob,TweenInfo.new(0.12),{Position=UDim2.new(0,3,0.5,0)}) end
    end
    render(); btn.MouseButton1Click:Connect(function() clickSound(); state=not state; render(); if onChanged then onChanged(state) end end)
    return {Root=row, Set=function(v) state=(v==true); render(); if onChanged then onChanged(state) end end, Get=function() return state end}
end
local function makeSlider(parent, text, min, max, defaultValue, onChanged)
    min=tonumber(min) or 0; max=tonumber(max) or 100; defaultValue=tonumber(defaultValue) or min
    local row=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,52),Parent=parent})
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text=text or "Slider",TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-70,0,16),Parent=row})
    local valueLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=tostring(defaultValue),TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextXAlignment=Enum.TextXAlignment.Right,AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,0,0,0),Size=UDim2.new(0,66,0,16),Parent=row})
    local track=mk("Frame",{BackgroundColor3=Color3.fromRGB(238,231,221),BorderSizePixel=0,Position=UDim2.new(0,0,0,26),Size=UDim2.new(1,0,0,18),Parent=row})
    addCorner(track,UDim.new(0,999)); addStroke(track,1,0.5)
    local fill=mk("Frame",{BackgroundColor3=Color3.fromRGB(190,170,150),BorderSizePixel=0,Size=UDim2.new(0,0,1,0),Parent=track})
    addCorner(fill,UDim.new(0,999))
    local knob=mk("Frame",{BackgroundColor3=Color3.fromRGB(250,247,242),BorderSizePixel=0,AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.new(0,0,0.5,0),Size=UDim2.new(0,18,0,18),Parent=track})
    addCorner(knob,UDim.new(0,999)); addStroke(knob,1,0.6)
    local dragging=false; local value=defaultValue
    local function setValue(v,fire)
        v=math.clamp(v,min,max); value=v; valueLabel.Text=tostring(math.floor(v*100+0.5)/100)
        local alpha=(v-min)/(max-min); local px=math.floor(alpha*track.AbsoluteSize.X+0.5)
        fill.Size=UDim2.new(0,px,1,0); knob.Position=UDim2.new(0,px,0.5,0)
        if fire and onChanged then onChanged(v) end
    end
    local function updateFromX(x,fire)
        local rel=math.clamp(x-track.AbsolutePosition.X,0,track.AbsoluteSize.X)
        local alpha=track.AbsoluteSize.X==0 and 0 or rel/track.AbsoluteSize.X
        setValue(min+(max-min)*alpha,fire)
    end
    track.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then clickSound(); dragging=true; updateFromX(i.Position.X,true) end end)
    track.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end)
    UserInputService.InputChanged:Connect(function(i) if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then updateFromX(i.Position.X,true) end end)
    task.defer(function() setValue(defaultValue,false); if onChanged then onChanged(defaultValue) end end)
    return {Root=row, Set=function(v) setValue(v,true) end, Get=function() return value end}
end

-- ── Character Helpers ─────────────────────────────────────────
local function getCharacter() return player.Character or player.CharacterAdded:Wait() end
local function getHumanoid() local ch=getCharacter(); return ch:FindFirstChildOfClass("Humanoid") or ch:WaitForChild("Humanoid",5) end
local function applyHumanoidSetting(field, value) local hum=getHumanoid(); if hum then pcall(function() hum[field]=value end) end end
local persistent={WalkSpeed=16,JumpPower=50,AutoJumpEnabled=true,FOV=70,MinZoom=player.CameraMinZoomDistance,MaxZoom=player.CameraMaxZoomDistance}
player.CharacterAdded:Connect(function()
    task.wait(0.25); applyHumanoidSetting("WalkSpeed",persistent.WalkSpeed)
    applyHumanoidSetting("JumpPower",persistent.JumpPower); applyHumanoidSetting("AutoJumpEnabled",persistent.AutoJumpEnabled)
end)
local blur=Lighting:FindFirstChild("PaperClay_Blur") :: BlurEffect?
if not blur then blur=mk("BlurEffect",{Name="PaperClay_Blur",Size=0,Parent=Lighting}) end

-- ── Topbar ────────────────────────────────────────────────────
local topbar=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,56),Parent=window})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,0),Size=UDim2.new(1,-260,1,0),Font=Enum.Font.GothamBold,Text="Paper & Clay  ⊕  RAE  v2",TextColor3=Color3.fromRGB(46,42,38),TextSize=16,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,30),Size=UDim2.new(1,-260,0,20),Font=Enum.Font.GothamMedium,Text="Soft UI · Recursive Autonomous Engine · Deep Intelligence Edition",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})
local controls=mk("Frame",{BackgroundTransparency=1,AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-14,0,12),Size=UDim2.new(0,220,0,32),Parent=topbar})
mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Right,VerticalAlignment=Enum.VerticalAlignment.Center,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=controls})
local function makeCtrl(text,bg)
    local b=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=bg,BorderSizePixel=0,Size=UDim2.new(0,44,0,32),Font=Enum.Font.GothamBold,Text=text,TextColor3=Color3.fromRGB(54,49,44),TextSize=14,Parent=controls})
    addCorner(b,UDim.new(0,10)); addStroke(b,1,0.35); hookHover(b,b.BackgroundColor3,Color3.fromRGB(255,252,248),0.35,0.18); return b
end
local btnMin=makeCtrl("—",Color3.fromRGB(244,239,232)); local btnClose=makeCtrl("✕",Color3.fromRGB(244,233,228))

-- ── Body / Sidebar / Pages ────────────────────────────────────
local body=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,56),Size=UDim2.new(1,0,1,-56),Parent=window})
local bodyRow=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,16,0,12),Size=UDim2.new(1,-32,1,-24),Parent=body})
mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Left,VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,14),Parent=bodyRow})
local sidebar=mk("Frame",{BackgroundColor3=Color3.fromRGB(245,239,231),BorderSizePixel=0,Size=UDim2.new(0,200,1,0),Parent=bodyRow})
addCorner(sidebar,UDim.new(0,16)); addStroke(sidebar,1,0.32)
mk("UIPadding",{PaddingTop=UDim.new(0,14),PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,14),PaddingBottom=UDim.new(0,14),Parent=sidebar})
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="Tabs",TextColor3=Color3.fromRGB(64,58,52),TextSize=13,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sidebar})
local navHolder=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,1,-30),Position=UDim2.new(0,0,0,28),Parent=sidebar})
mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,HorizontalAlignment=Enum.HorizontalAlignment.Center,VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,8),Parent=navHolder})
local contentCard=mk("Frame",{BackgroundColor3=Color3.fromRGB(250,247,242),BorderSizePixel=0,Size=UDim2.new(1,-214,1,0),Parent=bodyRow})
addCorner(contentCard,UDim.new(0,16)); addStroke(contentCard,1,0.25); addShadow(contentCard,10)
mk("UIPadding",{PaddingTop=UDim.new(0,16),PaddingLeft=UDim.new(0,16),PaddingRight=UDim.new(0,16),PaddingBottom=UDim.new(0,16),Parent=contentCard})
local headerRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,52),Parent=contentCard})
local panelTitle=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="Overview",TextColor3=Color3.fromRGB(46,42,38),TextSize=16,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(0.6,0,1,0),Parent=headerRow})
mk("Frame",{BackgroundColor3=Color3.fromRGB(225,218,209),BorderSizePixel=0,Size=UDim2.new(1,0,0,1),BackgroundTransparency=0.25,Parent=contentCard})
local pagesFolder=mk("Folder",{Name="Pages",Parent=contentCard})
local function makePage(name)
    local scroller=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,60),Size=UDim2.new(1,0,1,-60),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=6,ScrollingDirection=Enum.ScrollingDirection.Y,Visible=false,Parent=pagesFolder})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,HorizontalAlignment=Enum.HorizontalAlignment.Left,VerticalAlignment=Enum.VerticalAlignment.Top,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,14),Parent=scroller})
    return scroller
end

local pageOverview  = makePage("Overview")
local pagePlayer    = makePage("Player")
local pageCamera    = makePage("Camera")
local pageWorld     = makePage("World")
local pageDiscovery = makePage("Discovery")
local pageRAE       = makePage("RAE")
local pageRecursive = makePage("Recursive")
local pageBridge    = makePage("Bridge")
local pageAnalytics = makePage("Analytics")
local pageChain     = makePage("Chain")
local pageUtils     = makePage("Utilities")
local pageAbout     = makePage("About")

-- ============================================================
-- PAGE: Overview
-- ============================================================
do
    local _, s1=makeSection(pageOverview,"Welcome")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Welcome to Paper & Clay + RAE v2 — Deep Intelligence Edition.\n\nNew in v2: LWM (Living World Model ring buffer), ETM (Empirical Transition Model with convergence), CDG (Causal Dependency Graph), risk-adjusted MCTS planning, session persistence via _G, and Brier Score calibration tracking. See the Analytics tab for live intelligence dashboards.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,96),Parent=s1})
    local _, s2=makeSection(pageOverview,"Quick Actions")
    local b1=makeButton(s2,"Reset Character",UDim2.new(0,200,0,40),"↺")
    b1.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b1.Button); local hum=getHumanoid(); if hum then hum.Health=0 end end)
    local b2=makeButton(s2,"Center Window",UDim2.new(0,200,0,40),"◎")
    b2.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b2.Button); window.Position=UDim2.new(0.5,0,0.5,0) end)
    local _, s3=makeSection(pageOverview,"Live Status")
    local statusLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Loading...",TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,108),Parent=s3})
    task.spawn(function()
        while statusLabel and statusLabel.Parent do
            local char=player.Character; local hum=char and char:FindFirstChildOfClass("Humanoid")
            local cam=Workspace.CurrentCamera
            local cmap=ETM.GetConvergenceMap(); local gcov=cmap["_global"] or {total=0,converged=0,rate=0}
            local brier=ComputeBrierScore()
            statusLabel.Text=string.format(
                "WalkSpeed: %d   JumpPower: %d   FOV: %d\nRAE Phase: %s   Cycle: %d   Cards: %d\nSig: %s\nLWM: %d snapshots   ETM: %d/%d conv (%.0f%%)\nBrier: %s   CDG edges: %d",
                hum and hum.WalkSpeed or 0, hum and hum.JumpPower or 0,
                cam and cam.FieldOfView or persistent.FOV,
                RAE_State.Phase, RAE_State.CycleCount, #RAE_State.Cards,
                RAE_State.CurrentSig,
                LWM.GetSnapshotCount(), gcov.converged, gcov.total, gcov.rate*100,
                brier and string.format("%.4f",brier) or "N/A",
                #CDG.GetStrongEdges(0.1))
            task.wait(0.5)
        end
    end)
end

-- ============================================================
-- PAGE: Player
-- ============================================================
do
    local _, s=makeSection(pagePlayer,"Movement")
    makeSlider(s,"WalkSpeed",0,60,persistent.WalkSpeed,function(v) persistent.WalkSpeed=v; applyHumanoidSetting("WalkSpeed",v) end)
    makeSlider(s,"JumpPower",0,120,persistent.JumpPower,function(v) persistent.JumpPower=v; applyHumanoidSetting("JumpPower",v) end)
    makeToggle(s,"AutoJump",persistent.AutoJumpEnabled,function(on) persistent.AutoJumpEnabled=on; applyHumanoidSetting("AutoJumpEnabled",on) end)
    local _, s2=makeSection(pagePlayer,"Character")
    local resetBtn=makeButton(s2,"Reset Character",UDim2.new(0,200,0,40),"↺")
    resetBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(resetBtn.Button); local hum=getHumanoid(); if hum then hum.Health=0 end end)
    local sitBtn=makeButton(s2,"Toggle Sit",UDim2.new(0,200,0,40),"▢")
    sitBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(sitBtn.Button); local hum=getHumanoid(); if hum then hum.Sit=not hum.Sit end end)
end

-- ============================================================
-- PAGE: Camera
-- ============================================================
do
    local _, s=makeSection(pageCamera,"Camera")
    makeSlider(s,"Field of View",40,110,persistent.FOV,function(v) persistent.FOV=v; local cam=Workspace.CurrentCamera; if cam then cam.FieldOfView=v end end)
    makeSlider(s,"Min Zoom",0.5,50,persistent.MinZoom,function(v) persistent.MinZoom=v; pcall(function() player.CameraMinZoomDistance=v end) end)
    makeSlider(s,"Max Zoom",5,200,persistent.MaxZoom,function(v) persistent.MaxZoom=v; pcall(function() player.CameraMaxZoomDistance=v end) end)
    local _, s2=makeSection(pageCamera,"Convenience")
    local recenter=makeButton(s2,"Recenter Camera",UDim2.new(0,320,0,40),"◎")
    recenter.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(recenter.Button)
        local ch=getCharacter(); local hrp=ch and ch:FindFirstChild("HumanoidRootPart"); local cam=Workspace.CurrentCamera
        if hrp and cam then cam.CFrame=CFrame.new(cam.CFrame.Position,cam.CFrame.Position+hrp.CFrame.LookVector) end
    end)
    task.spawn(function()
        while true do task.wait(0.25); local cam=Workspace.CurrentCamera; if cam and math.abs(cam.FieldOfView-persistent.FOV)>0.5 then cam.FieldOfView=persistent.FOV end end
    end)
end

-- ============================================================
-- PAGE: World
-- ============================================================
do
    local _, s=makeSection(pageWorld,"Lighting")
    makeToggle(s,"Toggle Fog",false,function(on) if on then Lighting.FogStart=0; Lighting.FogEnd=80 else Lighting.FogStart=0; Lighting.FogEnd=100000 end end)
    makeSlider(s,"Brightness",0,10,Lighting.Brightness,function(v) Lighting.Brightness=v end)
    makeSlider(s,"Time of Day (0-24)",0,24,tonumber(Lighting.ClockTime) or 14,function(v) Lighting.ClockTime=v end)
    makeToggle(s,"Blur Effect",false,function(on) blur.Size=on and 12 or 0 end)
end

-- ============================================================
-- PAGE: Discovery
-- ============================================================
do
    local _, sScan=makeSection(pageDiscovery,"Remote Endpoint Scanner")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Scans for RemoteEvents and RemoteFunctions. Discovered remotes feed into RAE's Replication channel on next scan.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,48),Parent=sScan})
    local scanBtn=makeButton(sScan,"Scan All Remotes",UDim2.new(1,0,0,40),"🔍"); scanBtn.Button.BackgroundColor3=Color3.fromRGB(220,220,255)
    local remoteScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,280),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sScan})
    addCorner(remoteScroll,UDim.new(0,8)); addStroke(remoteScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=remoteScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=remoteScroll})
    scanBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(scanBtn.Button)
        remoteScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=remoteScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=remoteScroll})
        local found=0
        task.defer(function()
            for _,rootObj in ipairs({ReplicatedStorage,Workspace}) do
                for _,v in ipairs(rootObj:GetDescendants()) do
                    if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
                        found=found+1
                        local card=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,50),Parent=remoteScroll})
                        addCorner(card,UDim.new(0,6)); addStroke(card,1,0.2)
                        mk("TextLabel",{Text=v.Name,Font=Enum.Font.GothamBold,TextSize=13,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,10,0,8),Size=UDim2.new(1,-130,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=card})
                        mk("TextLabel",{Text=v.ClassName.." | "..v:GetFullName(),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(150,150,150),Position=UDim2.new(0,10,0,26),Size=UDim2.new(1,-130,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=card})
                        local fireBtn=mk("TextButton",{Text="Fire",Font=Enum.Font.GothamBold,TextSize=11,BackgroundColor3=Color3.fromRGB(230,240,230),Size=UDim2.new(0,80,0,30),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-10,0.5,0),Parent=card})
                        addCorner(fireBtn,UDim.new(0,6))
                        fireBtn.MouseButton1Click:Connect(function()
                            clickSound(); pulseClick(fireBtn)
                            if v:IsA("RemoteEvent") then
                                local ok,err=pcall(function() v:FireServer() end)
                                sendNotification(ok and ("Fired: "..v.Name) or ("Error: "..tostring(err)), ok and "Success" or "Error")
                            else
                                task.spawn(function()
                                    local ok,res=pcall(function() return v:InvokeServer() end)
                                    sendNotification(ok and ("Returned: "..tostring(res)) or ("Error: "..tostring(res)), ok and "Success" or "Error")
                                end)
                            end
                        end)
                    end
                end
            end
            sendNotification("Scan complete. Found "..found.." remotes.", "Success")
        end)
    end)
    local _, sTV=makeSection(pageDiscovery,"Trust Vector Analysis")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Classifies remotes by semantic keyword categories. Patterns are reflected in RAE's card system.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,48),Parent=sTV})
    local tvBtn=makeButton(sTV,"Classify Remotes",UDim2.new(1,0,0,40),"🔎"); tvBtn.Button.BackgroundColor3=Color3.fromRGB(220,235,255)
    local tvScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,200),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sTV})
    addCorner(tvScroll,UDim.new(0,8)); addStroke(tvScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=tvScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=tvScroll})
    local trustVectors={
        Economy={"addcoin","addcash","money","currency","damage","heal","cost","gems","coins","credits","balance","gold"},
        State={"isadmin","isvip","isdead","stunned","ragdoll","god","invincible"},
        Time={"daily","claim","reward","cooldown","timer","stamp","elapsed"},
        Physics={"velocity","force","impulse","constraint","mass","size","scale"},
        Combat={"hit","damage","attack","shoot","projectile","bullet","strike","melee"},
        Movement={"teleport","tp","move","position","cframe","warp","dash"},
        DataValidation={"submit","update","equip","hit","chat","msg"},
    }
    tvBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(tvBtn.Button)
        tvScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=tvScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=tvScroll})
        local found=0
        task.defer(function()
            for _,rootObj in ipairs({ReplicatedStorage,Workspace}) do
                for _,v in ipairs(rootObj:GetDescendants()) do
                    if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
                        local nl=v.Name:lower()
                        for vType,patterns in pairs(trustVectors) do
                            for _,pat in ipairs(patterns) do
                                if nl:find(pat) then
                                    found=found+1
                                    local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,36),Parent=tvScroll})
                                    addCorner(row,UDim.new(0,6)); addStroke(row,1,0.25)
                                    mk("TextLabel",{Text=string.format("[%s] %s",vType,v.Name),Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
                                    mk("TextLabel",{Text=v:GetFullName(),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(150,150,150),Position=UDim2.new(0,8,0,20),Size=UDim2.new(1,-16,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=row})
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if found==0 then mk("TextLabel",{Text="No semantic matches found.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=tvScroll}) end
            sendNotification("Classification complete. "..found.." matches.", "Success")
        end)
    end)
end

-- ============================================================
-- PAGE: RAE (Main Control)
-- ============================================================
do
    local _, sWS = makeSection(pageRAE, "WorldState(T)")
    local wsLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code, Text="No scan yet.",
        TextColor3=Color3.fromRGB(72,66,60), TextSize=11, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,150), Parent=sWS
    })

    local _, sCtrl = makeSection(pageRAE, "Controls")
    local ctrlGrid = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sCtrl})
    mk("UIGridLayout", {CellSize=UDim2.new(0.48,0,0,44), CellPadding=UDim2.new(0.04,0,0,10), SortOrder=Enum.SortOrder.LayoutOrder, Parent=ctrlGrid})

    local function makeRAEBtn(label, icon, color, fn)
        local b = makeButton(ctrlGrid, label, UDim2.new(1,0,0,44), icon)
        b.Button.BackgroundColor3 = color
        hookHover(b.Button, color, Color3.fromRGB(255,252,248), 0.25, 0.1)
        b.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b.Button); fn() end)
        return b
    end

    makeRAEBtn("Scan", "🔍", Color3.fromRGB(220,230,255), function()
        task.spawn(function() RAE_SilentMode=false; RAE_Scan() end)
    end)
    makeRAEBtn("Plan (MCTS)", "🧠", Color3.fromRGB(220,255,230), function()
        task.spawn(function()
            RAE_SilentMode=false
            local plan = RAE_Plan()
            if plan and #plan>0 then sendNotification("Plan ready: "..#plan.." steps.", "Success")
            else sendNotification("No viable plan generated.", "Warning") end
        end)
    end)
    makeRAEBtn("Commit", "▶", Color3.fromRGB(230,255,230), function()
        task.spawn(function()
            if #RAE_State.SelectedCards==0 then sendNotification("Nothing selected. Run Plan first.", "Warning"); return end
            RAE_SilentMode=false
            local log = RAE_Commit()
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Cycle #%d: %d/%d passed.", RAE_State.CycleCount, p, #log), p==#log and "Success" or "Warning")
            end
        end)
    end)
    makeRAEBtn("Manual Rescan", "↺", Color3.fromRGB(245,240,230), function()
        task.spawn(function()
            RAE_SilentMode=false
            sendNotification("RAE: Manual rescan started...", "Info")
            if RAE_Scan() then
                task.wait(0.5); local plan=RAE_Plan()
                if plan and #plan>0 then
                    task.wait(0.5); local log=RAE_Commit()
                    if log then
                        local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                        sendNotification(string.format("Rescan complete — %d cards, %d/%d passed.", #RAE_State.Cards, p, #log), p==#log and "Success" or "Warning")
                    end
                else sendNotification("Rescan complete. No plan generated.", "Info") end
            else sendNotification("Rescan failed.", "Error") end
        end)
    end)

    local _, sCards = makeSection(pageRAE, "Action Cards")
    local cardScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(245,242,238), Size=UDim2.new(1,0,0,320),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sCards
    })
    addCorner(cardScroll, UDim.new(0,8)); addStroke(cardScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=cardScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=cardScroll})

    local function refreshCardBrowser()
        cardScroll:ClearAllChildren()
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=cardScroll})
        mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=cardScroll})
        if #RAE_State.Cards == 0 then
            mk("TextLabel", {Text="No cards yet. Run Scan first.", BackgroundTransparency=1, Font=Enum.Font.GothamMedium, TextSize=12, TextColor3=Color3.fromRGB(150,150,150), Size=UDim2.new(1,0,0,24), Parent=cardScroll})
            return
        end
        local currentSig = RAE_State.CurrentSig
        for i, card in ipairs(RAE_State.Cards) do
            local vs = ValueSystem.ScoreCard(card, RAE_State.Cards, Intel.GetMemory().CardHistory)
            local etmProb, etmConv, etmStd = ETM.Predict(card.ID, currentSig)
            local causalScore = CDG.GetCausalScore(card.ID)
            local selected = false
            for _, sc in ipairs(RAE_State.SelectedCards) do if sc.ID==card.ID then selected=true; break end end
            local cf = mk("Frame", {
                BackgroundColor3=selected and Color3.fromRGB(220,240,220) or Color3.fromRGB(255,255,255),
                Size=UDim2.new(1,0,0,84), Parent=cardScroll
            })
            addCorner(cf, UDim.new(0,6)); addStroke(cf, 1, selected and 0.1 or 0.25)
            mk("TextLabel", {Text=string.format("[%s] %s", card.Channel, card.Name), Font=Enum.Font.GothamBold, TextSize=12, TextColor3=Color3.fromRGB(50,50,50), Position=UDim2.new(0,10,0,6), Size=UDim2.new(1,-120,0,14), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cf})
            mk("TextLabel", {Text=string.format("Risk:%s  Conf:%d%%  Val:%.2f", card.Metadata.Risk or "N/A", card.Metadata.Confidence or 0, vs.Total), Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(100,100,100), Position=UDim2.new(0,10,0,24), Size=UDim2.new(1,-120,0,12), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cf})
            mk("TextLabel", {
                Text=string.format("ETM p=%.2f σ=%.3f %s | CDG=%.3f", etmProb, etmStd, etmConv and "✓conv" or "~est", causalScore),
                Font=Enum.Font.Code, TextSize=10,
                TextColor3=etmConv and Color3.fromRGB(60,140,60) or Color3.fromRGB(120,100,80),
                Position=UDim2.new(0,10,0,40), Size=UDim2.new(1,-120,0,12),
                TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cf
            })
            mk("TextLabel", {Text=card.Description, Font=Enum.Font.GothamMedium, TextSize=10, TextColor3=Color3.fromRGB(130,120,110), Position=UDim2.new(0,10,0,56), Size=UDim2.new(1,-120,0,12), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, TextTruncate=Enum.TextTruncate.AtEnd, Parent=cf})
            mk("TextLabel", {Text=string.format("Born: %.1fs ago", os.clock() - (card.Born or 0)), Font=Enum.Font.Code, TextSize=9, TextColor3=Color3.fromRGB(170,160,150), Position=UDim2.new(0,10,0,70), Size=UDim2.new(1,-120,0,10), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cf})
            local selBtn = mk("TextButton", {
                Text=selected and "✓ Sel" or "Select", Font=Enum.Font.GothamBold, TextSize=11,
                BackgroundColor3=selected and Color3.fromRGB(180,230,180) or Color3.fromRGB(230,240,230),
                Size=UDim2.new(0,80,0,30), AnchorPoint=Vector2.new(1,0.5), Position=UDim2.new(1,-10,0.5,0), Parent=cf
            })
            addCorner(selBtn, UDim.new(0,6))
            selBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(selBtn)
                if selected then
                    local ns={}; for _,sc in ipairs(RAE_State.SelectedCards) do if sc.ID~=card.ID then table.insert(ns,sc) end end
                    RAE_State.SelectedCards=ns
                else table.insert(RAE_State.SelectedCards, card) end
                refreshCardBrowser()
            end)
        end
    end

    RAE_Callbacks.OnScan = function(ws, cards)
        local totalFires = 0
        for _, r in ipairs(ws.Latent.RemoteEvents) do totalFires = totalFires + r.FireCount end
        local matchVarCount = 0; for _ in pairs(ws.Latent.MatchState) do matchVarCount = matchVarCount + 1 end
        wsLabel.Text = string.format(
            "T: %.2f  |  Sig: %s\nInstances: %d  |  Scripts: %d  |  Gravity: %.1f\nPhysics: %d  |  ClientOwned: %d  |  ServerOwned: %d\nRemotes: %d  |  Fns: %d  |  ObsFires: %d\nValue Objs: %d  |  Match Vars: %d  |  Agents: %d\nStreaming: %s  |  LWM Snaps: %d  |  CDG Edges: %d",
            ws.T, RAE_State.CurrentSig,
            ws.ObjectGraph.TotalInstances, ws.ObjectGraph.ScriptCount, ws.SimConfig.Gravity,
            #ws.Physics.SimulatedAssemblies, #ws.Physics.ClientOwned, #ws.Physics.ServerOwned,
            #ws.Latent.RemoteEvents, #ws.Latent.RemoteFunctions, totalFires,
            #ws.Latent.ValueObjects, matchVarCount, 1+#ws.Agents.OtherPlayers,
            tostring(ws.SimConfig.StreamingEnabled), LWM.GetSnapshotCount(), #CDG.GetStrongEdges(0.1))
        refreshCardBrowser()
    end
    RAE_Callbacks.OnPlan   = function() refreshCardBrowser() end
    RAE_Callbacks.OnCommit = function() refreshCardBrowser() end
end

-- ============================================================
-- PAGE: Recursive (Cognitive Brain)
-- ============================================================
do
    local _, sBrain = makeSection(pageRecursive, "Cognitive Brain (Thompson Sampling v3)")
    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
        Text="Live cognitive state of RAE. Posteriors show Bayesian learning per card. Channel weights reflect cumulative success rates. Phase shifts show detected environment drift events. ETM convergence shows how many cards have reached reliable prediction (stddev < 0.08, n ≥ 10).",
        TextColor3=Color3.fromRGB(92,84,76), TextSize=12, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,72), Parent=sBrain})

    local refreshBtn = makeButton(sBrain, "Refresh State", UDim2.new(0,200,0,40), "↻")
    refreshBtn.Button.BackgroundColor3 = Color3.fromRGB(220,220,255)

    local stateScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(245,242,238), Size=UDim2.new(1,0,0,460),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sBrain
    })
    addCorner(stateScroll, UDim.new(0,8)); addStroke(stateScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=stateScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=stateScroll})

    local function refreshRecursive()
        stateScroll:ClearAllChildren()
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=stateScroll})
        mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=stateScroll})
        local mem = Intel.GetMemory()

        -- Summary row
        local cmap = ETM.GetConvergenceMap(); local gcov = cmap["_global"] or {total=0,converged=0,rate=0}
        local brier = ComputeBrierScore()
        local sumFrame = mk("Frame", {BackgroundColor3=Color3.fromRGB(240,250,240), Size=UDim2.new(1,0,0,68), Parent=stateScroll})
        addCorner(sumFrame, UDim.new(0,6)); addStroke(sumFrame, 1, 0.2)
        mk("TextLabel", {Text="INTELLIGENCE SUMMARY", Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(60,100,60), Position=UDim2.new(0,10,0,6), Size=UDim2.new(1,-20,0,14), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=sumFrame})
        mk("TextLabel", {
            Text=string.format("Cycles: %d  |  Overfit Streak: %d  |  Phase Shifts: %d\nETM Conv: %d/%d (%.0f%%)  |  Brier Score: %s  |  CDG Edges: %d",
                mem.Cycles, mem.OverfitStreak, #mem.PhaseShifts,
                gcov.converged, gcov.total, gcov.rate*100,
                brier and string.format("%.4f",brier) or "N/A",
                #CDG.GetStrongEdges(0.1)),
            Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(50,50,50),
            Position=UDim2.new(0,10,0,24), Size=UDim2.new(1,-20,0,36),
            TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, TextWrapped=true, Parent=sumFrame
        })

        -- Channel weights with bar graphs
        local cwFrame = mk("Frame", {BackgroundColor3=Color3.fromRGB(255,255,255), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=stateScroll})
        addCorner(cwFrame, UDim.new(0,6)); addStroke(cwFrame, 1, 0.25)
        mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), PaddingBottom=UDim.new(0,8), Parent=cwFrame})
        mk("TextLabel", {Text="CHANNEL WEIGHTS", Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(80,60,40), Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cwFrame})
        local cwHolder = mk("Frame", {BackgroundTransparency=1, Position=UDim2.new(0,0,0,22), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=cwFrame})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=cwHolder})
        for _, ch in ipairs({"Structural","Metabolic","Ownership","Replication","Latent","Agent","Network"}) do
            local w = mem.ChannelWeights[ch] or 1.0
            local pct = math.clamp((w - 0.2) / (2.0 - 0.2), 0, 1)
            local row = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,20), Parent=cwHolder})
            mk("TextLabel", {Text=ch, Font=Enum.Font.GothamMedium, TextSize=10, TextColor3=Color3.fromRGB(70,60,50), Size=UDim2.new(0,100,1,0), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=row})
            local track = mk("Frame", {BackgroundColor3=Color3.fromRGB(235,228,218), BorderSizePixel=0, Position=UDim2.new(0,104,0,4), Size=UDim2.new(1,-170,0,12), Parent=row})
            addCorner(track, UDim.new(0,6))
            local fill = mk("Frame", {BackgroundColor3=w>=1.0 and Color3.fromRGB(120,180,120) or Color3.fromRGB(200,140,100), BorderSizePixel=0, Size=UDim2.new(pct,0,1,0), Parent=track})
            addCorner(fill, UDim.new(0,6))
            mk("TextLabel", {Text=string.format("%.3f", w), Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(80,70,60), AnchorPoint=Vector2.new(1,0.5), Position=UDim2.new(1,0,0.5,0), Size=UDim2.new(0,60,1,0), TextXAlignment=Enum.TextXAlignment.Right, BackgroundTransparency=1, Parent=row})
        end

        -- Value axis weights
        local vwFrame = mk("Frame", {BackgroundColor3=Color3.fromRGB(255,255,255), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=stateScroll})
        addCorner(vwFrame, UDim.new(0,6)); addStroke(vwFrame, 1, 0.25)
        mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), PaddingBottom=UDim.new(0,8), Parent=vwFrame})
        mk("TextLabel", {Text="VALUE AXIS WEIGHTS  (updates: "..ValueHistory.WeightUpdates..")", Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(60,60,100), Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=vwFrame})
        local vwHolder = mk("Frame", {BackgroundTransparency=1, Position=UDim2.new(0,0,0,22), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=vwFrame})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=vwHolder})
        for axis, w in pairs(ValueWeights) do
            local pct = math.clamp((w - 0.1) / (2.0 - 0.1), 0, 1)
            local row = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,20), Parent=vwHolder})
            mk("TextLabel", {Text=axis, Font=Enum.Font.GothamMedium, TextSize=10, TextColor3=Color3.fromRGB(60,60,80), Size=UDim2.new(0,120,1,0), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=row})
            local track = mk("Frame", {BackgroundColor3=Color3.fromRGB(228,228,238), BorderSizePixel=0, Position=UDim2.new(0,124,0,4), Size=UDim2.new(1,-190,0,12), Parent=row})
            addCorner(track, UDim.new(0,6))
            local fill = mk("Frame", {BackgroundColor3=Color3.fromRGB(120,130,200), BorderSizePixel=0, Size=UDim2.new(pct,0,1,0), Parent=track})
            addCorner(fill, UDim.new(0,6))
            mk("TextLabel", {Text=string.format("%.3f", w), Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(60,60,80), AnchorPoint=Vector2.new(1,0.5), Position=UDim2.new(1,0,0.5,0), Size=UDim2.new(0,60,1,0), TextXAlignment=Enum.TextXAlignment.Right, BackgroundTransparency=1, Parent=row})
        end

        -- Card posteriors
        local posteriorCount = 0
        for _ in pairs(mem.CardHistory) do posteriorCount = posteriorCount + 1 end
        if posteriorCount > 0 then
            local cpFrame = mk("Frame", {BackgroundColor3=Color3.fromRGB(255,255,255), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=stateScroll})
            addCorner(cpFrame, UDim.new(0,6)); addStroke(cpFrame, 1, 0.25)
            mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), PaddingBottom=UDim.new(0,8), Parent=cpFrame})
            mk("TextLabel", {Text=string.format("CARD POSTERIORS  (%d cards learned)", posteriorCount), Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(80,60,40), Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cpFrame})
            local cpHolder = mk("Frame", {BackgroundTransparency=1, Position=UDim2.new(0,0,0,22), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=cpFrame})
            mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=cpHolder})
            local shown = 0
            for id, h in pairs(mem.CardHistory) do
                if shown >= 20 then break end
                shown = shown + 1
                local mean = h.alpha / (h.alpha + h.beta)
                local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(248,246,242), Size=UDim2.new(1,0,0,18), Parent=cpHolder})
                addCorner(row, UDim.new(0,4))
                mk("TextLabel", {
                    Text=string.format("id:...%s  α=%.2f β=%.2f  μ=%.3f  σ=%.3f  n=%d",
                        id:sub(-6), h.alpha, h.beta, mean, h.StdDev or 0, h.n),
                    Font=Enum.Font.Code, TextSize=9, TextColor3=Color3.fromRGB(80,70,60),
                    Size=UDim2.new(1,-8,1,0), Position=UDim2.new(0,4,0,0),
                    TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=row
                })
            end
            if posteriorCount > 20 then
                mk("TextLabel", {Text=string.format("...and %d more cards", posteriorCount-20), Font=Enum.Font.GothamMedium, TextSize=10, TextColor3=Color3.fromRGB(140,130,120), Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cpHolder})
            end
        end

        -- Phase shift log
        if #mem.PhaseShifts > 0 then
            local psFrame = mk("Frame", {BackgroundColor3=Color3.fromRGB(255,248,235), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=stateScroll})
            addCorner(psFrame, UDim.new(0,6)); addStroke(psFrame, 1, 0.25)
            mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), PaddingBottom=UDim.new(0,8), Parent=psFrame})
            mk("TextLabel", {Text="PHASE SHIFTS DETECTED", Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(140,100,20), Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=psFrame})
            local psHolder = mk("Frame", {BackgroundTransparency=1, Position=UDim2.new(0,0,0,22), Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=psFrame})
            mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=psHolder})
            for _, s in ipairs(mem.PhaseShifts) do
                mk("TextLabel", {
                    Text=string.format("Cycle %d | %s | prior=%.3f → recent=%.3f (Δ=%.3f)",
                        s.Cycle, s.Channel, s.PriorMean, s.RecentMean, s.PriorMean - s.RecentMean),
                    Font=Enum.Font.Code, TextSize=10, TextColor3=Color3.fromRGB(140,90,20),
                    Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=psHolder
                })
            end
        end
    end

    refreshBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(refreshBtn.Button); refreshRecursive() end)
    local _origOnCommit = RAE_Callbacks.OnCommit
    RAE_Callbacks.OnCommit = function(log)
        if _origOnCommit then _origOnCommit(log) end
        refreshRecursive()
    end
    task.defer(refreshRecursive)
end

-- ============================================================
-- PAGE: Bridge (Staged Execution)
-- ============================================================
do
    local _, sBridge = makeSection(pageBridge, "Chain Executor — Staged Bridge")
    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
        Text="Select cards in the RAE tab, then Preview to inspect the resolved dependency chain (CDG-reordered). Execute Chain runs Observe→Probe→Commit→Verify for high-risk steps, fast-path otherwise.",
        TextColor3=Color3.fromRGB(92,84,76), TextSize=12, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,60), Parent=sBridge})

    local bridgeStateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="State: Idle", TextColor3=Color3.fromRGB(100,90,80),
        TextSize=13, TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,0,0,20), Parent=sBridge
    })

    local previewScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(245,242,238), Size=UDim2.new(1,0,0,180),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sBridge
    })
    addCorner(previewScroll, UDim.new(0,8)); addStroke(previewScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=previewScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=previewScroll})

    local logScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(240,238,234), Size=UDim2.new(1,0,0,200),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sBridge
    })
    addCorner(logScroll, UDim.new(0,8)); addStroke(logScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=logScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=logScroll})

    local function clearScroll(s)
        s:ClearAllChildren()
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=s})
        mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=s})
    end
    local function addLogLine(scroll, text, color)
        mk("TextLabel", {
            Text=text, Font=Enum.Font.Code, TextSize=11,
            TextColor3=color or Color3.fromRGB(60,55,50),
            Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left,
            BackgroundTransparency=1, TextWrapped=true, Parent=scroll
        })
    end

    local btnGrid = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sBridge})
    mk("UIGridLayout", {CellSize=UDim2.new(0.48,0,0,42), CellPadding=UDim2.new(0.04,0,0,8), SortOrder=Enum.SortOrder.LayoutOrder, Parent=btnGrid})

    local previewBtn = makeButton(btnGrid, "Preview Chain", UDim2.new(1,0,0,42), "👁")
    previewBtn.Button.BackgroundColor3 = Color3.fromRGB(220,225,255)
    hookHover(previewBtn.Button, previewBtn.Button.BackgroundColor3, Color3.fromRGB(235,238,255), 0.25, 0.1)

    local execBtn = makeButton(btnGrid, "Execute Chain", UDim2.new(1,0,0,42), "▶")
    execBtn.Button.BackgroundColor3 = Color3.fromRGB(220,245,220)
    hookHover(execBtn.Button, execBtn.Button.BackgroundColor3, Color3.fromRGB(235,255,235), 0.25, 0.1)

    previewBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(previewBtn.Button)
        clearScroll(previewScroll); clearScroll(logScroll)
        if #RAE_State.SelectedCards == 0 then
            bridgeStateLabel.Text = "State: No cards selected."
            addLogLine(previewScroll, "Select cards in the RAE tab first.", Color3.fromRGB(180,100,100))
            return
        end
        local chain, staged = Executor.Preview(RAE_State.SelectedCards, RAE_State.Cards)
        bridgeStateLabel.Text = string.format("State: Previewed — %d steps (%s path)", #chain, staged and "STAGED" or "FAST")
        for i, card in ipairs(chain) do
            local isOrig = false
            for _, sc in ipairs(RAE_State.SelectedCards) do if sc.ID == card.ID then isOrig = true; break end end
            addLogLine(previewScroll,
                string.format("[%d] %s [%s] %s  Risk:%s  Conf:%d%%  %s",
                    i, card.Channel, isOrig and "SEL" or "DEP", card.Name,
                    card.Metadata.Risk or "None", card.Metadata.Confidence or 0,
                    staged and "→STAGED" or "→FAST"),
                isOrig and Color3.fromRGB(40,120,40) or Color3.fromRGB(100,100,160))
        end
    end)

    execBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(execBtn.Button)
        if #RAE_State.SelectedCards == 0 then
            sendNotification("Nothing selected. Select cards in RAE tab.", "Warning"); return
        end
        bridgeStateLabel.Text = "State: Executing..."
        clearScroll(logScroll)
        task.spawn(function()
            local log = RAE_Commit()
            if not log then
                bridgeStateLabel.Text = "State: Commit failed."
                addLogLine(logScroll, "RAE_Commit returned nil.", Color3.fromRGB(200,80,80))
                return
            end
            local passed, failed = 0, 0
            for _, r in ipairs(log) do
                if r.Success then passed = passed + 1 else failed = failed + 1 end
                addLogLine(logScroll,
                    string.format("%s [%s] %s%s",
                        r.Success and "✓" or "✗",
                        r.Step.Channel, r.Step.Name,
                        r.Stage and ("  stage:"..r.Stage) or ""),
                    r.Success and Color3.fromRGB(40,140,40) or Color3.fromRGB(200,80,80))
                if not r.Success then
                    addLogLine(logScroll, "   ↳ "..tostring(r.Reason), Color3.fromRGB(160,100,60))
                end
            end
            bridgeStateLabel.Text = string.format("State: Complete — %d passed, %d failed", passed, failed)
        end)
    end)
end

-- ============================================================
-- PAGE: Analytics (NEW v2 — Deep Intelligence Dashboards)
-- ============================================================
do
    local _, sHeader = makeSection(pageAnalytics, "Deep Intelligence Analytics")
    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
        Text="Real-time view of RAE's learned intelligence. ETM shows convergence of state-conditional transition predictions per card. CDG shows strongest causal edges discovered between action pairs. Calibration shows Brier Score trend and predicted-vs-actual accuracy.",
        TextColor3=Color3.fromRGB(92,84,76), TextSize=12, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,72), Parent=sHeader})

    local refreshAnalyticsBtn = makeButton(sHeader, "Refresh Analytics", UDim2.new(0,220,0,40), "📊")
    refreshAnalyticsBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)

    -- LWM Panel
    local _, sLWM = makeSection(pageAnalytics, "Living World Model (LWM)")
    local lwmLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code, Text="No data yet.",
        TextColor3=Color3.fromRGB(72,66,60), TextSize=11, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sLWM})

    -- ETM Convergence Panel
    local _, sETM = makeSection(pageAnalytics, "ETM Convergence Map")
    local etmScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(245,242,238), Size=UDim2.new(1,0,0,220),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sETM
    })
    addCorner(etmScroll, UDim.new(0,8)); addStroke(etmScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=etmScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=etmScroll})

    -- CDG Edges Panel
    local _, sCDG = makeSection(pageAnalytics, "Causal Dependency Graph — Strongest Edges")
    local cdgScroll = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(245,242,238), Size=UDim2.new(1,0,0,220),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4, Parent=sCDG
    })
    addCorner(cdgScroll, UDim.new(0,8)); addStroke(cdgScroll, 1, 0.3)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=cdgScroll})
    mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=cdgScroll})

    -- Brier Calibration Panel
    local _, sCal = makeSection(pageAnalytics, "Brier Calibration")
    local calLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code, Text="No calibration data yet.",
        TextColor3=Color3.fromRGB(72,66,60), TextSize=11, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sCal})

    local function refreshAnalytics()
        -- LWM
        local buf = LWM.GetBuffer()
        if #buf == 0 then
            lwmLabel.Text = "No LWM snapshots yet. Run a Scan first."
        else
            local delta = LWM.GetDelta()
            local avgHealth = LWM.GetTemporalAverage("health", 5)
            local avgFires  = LWM.GetTemporalAverage("remoteFires", 5)
            lwmLabel.Text = string.format(
                "Snapshots: %d/%d  |  Oldest: %.1fs ago  |  Latest sig: %s\nΔHealth: %s  |  ΔPhysics: %s  |  ΔFires: %s\nAvg Health (5-snap): %.1f  |  Avg RemoteFires (5-snap): %.1f",
                #buf, 12,
                buf[1] and (os.clock() - buf[1].timestamp) or 0,
                LWM.GetRecentSig(),
                delta and string.format("%+.1f", delta.healthDelta) or "N/A",
                delta and string.format("%+d",   delta.physDelta)   or "N/A",
                delta and string.format("%+d",   delta.firesDelta)  or "N/A",
                avgHealth, avgFires)
        end

        -- ETM
        etmScroll:ClearAllChildren()
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=etmScroll})
        mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=etmScroll})
        local cmap = ETM.GetConvergenceMap()
        local gcov = cmap["_global"] or {total=0,converged=0,rate=0}
        mk("TextLabel", {
            Text=string.format("Global: %d/%d converged (%.0f%%)  |  Not yet converged: %d",
                gcov.converged, gcov.total, gcov.rate*100, gcov.total - gcov.converged),
            Font=Enum.Font.GothamBold, TextSize=11,
            TextColor3=gcov.rate>=0.5 and Color3.fromRGB(40,140,40) or Color3.fromRGB(140,100,40),
            Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=etmScroll
        })
        for cardID, data in pairs(cmap) do
            if cardID ~= "_global" then
                local row = mk("Frame", {BackgroundColor3=data.converged>0 and Color3.fromRGB(240,255,240) or Color3.fromRGB(255,252,240), Size=UDim2.new(1,0,0,18), Parent=etmScroll})
                addCorner(row, UDim.new(0,4))
                mk("TextLabel", {
                    Text=string.format("...%s  sigs:%d  conv:%d  (%.0f%%)", cardID:sub(-8), data.total, data.converged, data.rate*100),
                    Font=Enum.Font.Code, TextSize=10,
                    TextColor3=data.converged>0 and Color3.fromRGB(40,120,40) or Color3.fromRGB(120,100,40),
                    Size=UDim2.new(1,-8,1,0), Position=UDim2.new(0,4,0,0),
                    TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=row
                })
            end
        end

        -- CDG
        cdgScroll:ClearAllChildren()
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4), Parent=cdgScroll})
        mk("UIPadding", {PaddingTop=UDim.new(0,6), PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=cdgScroll})
        local edges = CDG.GetStrongEdges(0.1)
        if #edges == 0 then
            mk("TextLabel", {Text="No causal edges yet. Run multiple Commit cycles to build CDG.", Font=Enum.Font.GothamMedium, TextSize=11, TextColor3=Color3.fromRGB(150,140,130), Size=UDim2.new(1,0,0,20), BackgroundTransparency=1, Parent=cdgScroll})
        else
            mk("TextLabel", {
                Text=string.format("%d edges (conf ≥ 0.10)  |  Showing top %d", #edges, math.min(#edges, 25)),
                Font=Enum.Font.GothamBold, TextSize=11, TextColor3=Color3.fromRGB(60,60,100),
                Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=cdgScroll
            })
            for i, e in ipairs(edges) do
                if i > 25 then break end
                local row = mk("Frame", {
                    BackgroundColor3=e.EffectSize>0 and Color3.fromRGB(240,255,240) or Color3.fromRGB(255,240,240),
                    Size=UDim2.new(1,0,0,18), Parent=cdgScroll
                })
                addCorner(row, UDim.new(0,4))
                mk("TextLabel", {
                    Text=string.format("...%s → ...%s  effect=%+.3f  conf=%.2f  co=%d  ✓=%d  ✗=%d",
                        e.FromID:sub(-6), e.ToID:sub(-6),
                        e.EffectSize, e.Confidence, e.CoFired, e.CoSuccess, e.CoFail),
                    Font=Enum.Font.Code, TextSize=9,
                    TextColor3=e.EffectSize>0 and Color3.fromRGB(40,110,40) or Color3.fromRGB(160,60,60),
                    Size=UDim2.new(1,-8,1,0), Position=UDim2.new(0,4,0,0),
                    TextXAlignment=Enum.TextXAlignment.Left, BackgroundTransparency=1, Parent=row
                })
            end
        end

        -- Brier Calibration
        local brier = ComputeBrierScore()
        local calLog = IntelMem.CalibrationLog
        local totalEntries = calLog and #calLog or 0
        local correctPredictions = 0
        if calLog then
            for _, e in ipairs(calLog) do
                if (e.Predicted >= 0.5) == (e.Actual == 1) then correctPredictions = correctPredictions + 1 end
            end
        end
        calLabel.Text = string.format(
            "Brier Score: %s  (lower = better; 0.25 = random, 0.0 = perfect)\nCalibration log entries: %d  |  Correct direction: %d/%d (%.0f%%)\nMCTS λ (risk-aversion): %.2f  |  Gate threshold: %.2f",
            brier and string.format("%.4f",brier) or "N/A",
            totalEntries, correctPredictions, totalEntries,
            totalEntries>0 and (correctPredictions/totalEntries*100) or 0,
            RISK_CFG.Lambda, RISK_CFG.ConfidenceGateThreshold)
    end

    refreshAnalyticsBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(refreshAnalyticsBtn.Button); refreshAnalytics()
    end)
    -- Auto-refresh analytics after each commit
    local _prevOnCommit = RAE_Callbacks.OnCommit
    RAE_Callbacks.OnCommit = function(log)
        if _prevOnCommit then _prevOnCommit(log) end
        task.defer(refreshAnalytics)
    end
    task.defer(refreshAnalytics)
end

-- ============================================================
-- PAGE: RAE (Main Control)
-- ============================================================
do
    local _, sWS=makeSection(pageRAE,"WorldState(T)")
    local wsLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No scan yet.",TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,148),Parent=sWS})

    local _, sCtrl=makeSection(pageRAE,"Controls")
    local ctrlGrid=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=sCtrl})
    mk("UIGridLayout",{CellSize=UDim2.new(0.48,0,0,44),CellPadding=UDim2.new(0.04,0,0,10),SortOrder=Enum.SortOrder.LayoutOrder,Parent=ctrlGrid})

    local function makeRAEBtn(label, icon, color, fn)
        local b=makeButton(ctrlGrid,label,UDim2.new(1,0,0,44),icon)
        b.Button.BackgroundColor3=color
        hookHover(b.Button,color,Color3.fromRGB(255,252,248),0.25,0.1)
        b.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b.Button); fn() end)
        return b
    end

    makeRAEBtn("Scan","🔍",Color3.fromRGB(220,230,255),function()
        task.spawn(function() RAE_SilentMode=false; RAE_Scan() end)
    end)
    makeRAEBtn("Plan (MCTS)","🧠",Color3.fromRGB(220,255,230),function()
        task.spawn(function()
            RAE_SilentMode=false
            local plan=RAE_Plan()
            if plan and #plan>0 then sendNotification("Plan ready: "..#plan.." steps.", "Success")
            else sendNotification("No plan generated.", "Warning") end
        end)
    end)
    makeRAEBtn("Commit","▶",Color3.fromRGB(230,255,230),function()
        task.spawn(function()
            if #RAE_State.SelectedCards==0 then sendNotification("Nothing selected. Run Plan first.", "Warning"); return end
            RAE_SilentMode=false
            local log=RAE_Commit()
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Cycle #%d: %d/%d passed.",RAE_State.CycleCount,p,#log), p==#log and "Success" or "Warning")
            end
        end)
    end)
    makeRAEBtn("Manual Rescan","↺",Color3.fromRGB(245,240,230),function()
        task.spawn(function()
            RAE_SilentMode=false
            sendNotification("RAE: Manual rescan started...", "Info")
            if RAE_Scan() then
                task.wait(0.5)
                local plan=RAE_Plan()
                if plan and #plan>0 then
                    task.wait(0.5)
                    local log=RAE_Commit()
                    if log then
                        local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                        sendNotification(string.format("Rescan complete — %d cards, %d/%d passed.",#RAE_State.Cards,p,#log), p==#log and "Success" or "Warning")
                    end
                else sendNotification("Rescan complete. No plan generated.", "Info") end
            else sendNotification("Rescan failed.", "Error") end
        end)
    end)

    local _, sCards=makeSection(pageRAE,"Action Cards")
    local cardScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,300),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sCards})
    addCorner(cardScroll,UDim.new(0,8)); addStroke(cardScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=cardScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=cardScroll})

    local function refreshCardBrowser()
        cardScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=cardScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=cardScroll})
        if #RAE_State.Cards==0 then
            mk("TextLabel",{Text="No cards yet. Run Scan first.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=cardScroll})
            return
        end
        local currentSig=RAE_State.CurrentSig
        for _,card in ipairs(RAE_State.Cards) do
            local vs=ValueSystem.ScoreCard(card,RAE_State.Cards,Intel.GetMemory().CardHistory)
            local etmProb,etmConv,etmStd=ETM.Predict(card.ID,currentSig)
            local causalScore=CDG.GetCausalScore(card.ID)
            local selected=false
            for _,sc in ipairs(RAE_State.SelectedCards) do if sc.ID==card.ID then selected=true; break end end
            local cf=mk("Frame",{BackgroundColor3=selected and Color3.fromRGB(220,240,220) or Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,80),Parent=cardScroll})
            addCorner(cf,UDim.new(0,6)); addStroke(cf,1,selected and 0.1 or 0.25)
            mk("TextLabel",{Text=string.format("[%s] %s",card.Channel,card.Name),Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,10,0,6),Size=UDim2.new(1,-120,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=cf})
            mk("TextLabel",{Text=string.format("Risk:%s  Conf:%d%%  Val:%.2f",card.Metadata.Risk or "N/A",card.Metadata.Confidence or 0,vs.Total),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(100,100,100),Position=UDim2.new(0,10,0,24),Size=UDim2.new(1,-120,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=cf})
            mk("TextLabel",{
                Text=string.format("ETM p=%.2f σ=%.3f %s | CDG %.3f",etmProb,etmStd,etmConv and "✓" or "~",causalScore),
                Font=Enum.Font.Code,TextSize=10,
                TextColor3=etmConv and Color3.fromRGB(60,140,60) or Color3.fromRGB(130,110,80),
                Position=UDim2.new(0,10,0,40),Size=UDim2.new(1,-120,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=cf})
            mk("TextLabel",{Text=card.Description,Font=Enum.Font.GothamMedium,TextSize=10,TextColor3=Color3.fromRGB(120,112,104),Position=UDim2.new(0,10,0,56),Size=UDim2.new(1,-120,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=cf})
            local selBtn=mk("TextButton",{Text=selected and "✓ Sel" or "Select",Font=Enum.Font.GothamBold,TextSize=11,BackgroundColor3=selected and Color3.fromRGB(180,230,180) or Color3.fromRGB(230,240,230),Size=UDim2.new(0,80,0,30),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-10,0.5,0),Parent=cf})
            addCorner(selBtn,UDim.new(0,6))
            selBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(selBtn)
                if selected then
                    local ns={}; for _,sc in ipairs(RAE_State.SelectedCards) do if sc.ID~=card.ID then table.insert(ns,sc) end end
                    RAE_State.SelectedCards=ns
                else table.insert(RAE_State.SelectedCards,card) end
                refreshCardBrowser()
            end)
        end
    end

    RAE_Callbacks.OnScan=function(ws,cards)
        wsLabel.Text=string.format(
            "T:%.2f  Sig:%s\nInstances:%d  Scripts:%d\nPhysics:%d  Remotes:%d  Agents:%d\nValueObjs:%d  MatchState:%d vars\nStreaming:%s  Gravity:%.1f\nLWM Snapshots:%d  ETM Keys:%d",
            ws.T, RAE_State.CurrentSig,
            ws.ObjectGraph.TotalInstances, ws.ObjectGraph.ScriptCount,
            #ws.Physics.SimulatedAssemblies, #ws.Latent.RemoteEvents, 1+#ws.Agents.OtherPlayers,
            #ws.Latent.ValueObjects,
            (function() local t=0; for _ in pairs(ws.Latent.MatchState) do t=t+1 end; return t end)(),
            tostring(ws.SimConfig.StreamingEnabled), ws.SimConfig.Gravity,
            LWM.GetSnapshotCount(),
            (function() local t=0; for _ in pairs(ETM.GetTableRef()) do t=t+1 end; return t end)())
        refreshCardBrowser()
    end
    RAE_Callbacks.OnPlan   = function(_)   refreshCardBrowser() end
    RAE_Callbacks.OnCommit = function(_)   refreshCardBrowser() end
end

-- ============================================================
-- PAGE: Recursive (Cognitive State)
-- ============================================================
do
    local _, sBrain=makeSection(pageRecursive,"Cognitive State")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Live RAE cognitive state. Updates after every Commit cycle. Shows Bayesian posteriors per card, channel weights, phase shifts, value axis weights, ETM convergence summary, and Brier calibration score.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=sBrain})
    local refreshBtn=makeButton(sBrain,"Refresh",UDim2.new(0,200,0,40),"↻")
    refreshBtn.Button.BackgroundColor3=Color3.fromRGB(220,220,255)

    local stateScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,500),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sBrain})
    addCorner(stateScroll,UDim.new(0,8)); addStroke(stateScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=stateScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=stateScroll})

    local function refreshRecursive()
        stateScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=stateScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=stateScroll})
        local mem=Intel.GetMemory()
        local cmap=ETM.GetConvergenceMap(); local gcov=cmap["_global"] or {total=0,converged=0,rate=0}
        local brier=ComputeBrierScore()

        -- Summary row
        local summaryFrame=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,72),Parent=stateScroll})
        addCorner(summaryFrame,UDim.new(0,6)); addStroke(summaryFrame,1,0.2)
        mk("TextLabel",{Text=string.format(
            "Cycles: %d   PhaseShifts: %d   OverfitStreak: %d\nETM Converged: %d/%d (%.0f%%)   Brier Score: %s\nValueWeightUpdates: %d   CDG Edges: %d",
            mem.Cycles, #mem.PhaseShifts, mem.OverfitStreak,
            gcov.converged, gcov.total, gcov.rate*100,
            brier and string.format("%.4f",brier) or "N/A",
            ValueHistory.WeightUpdates, #CDG.GetStrongEdges(0.1)),
            Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),
            Position=UDim2.new(0,10,0,8),Size=UDim2.new(1,-20,1,-16),
            TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
            BackgroundTransparency=1,TextWrapped=true,Parent=summaryFrame})

        -- Channel weights
        local chFrame=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=stateScroll})
        addCorner(chFrame,UDim.new(0,6)); addStroke(chFrame,1,0.2)
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10),PaddingBottom=UDim.new(0,8),Parent=chFrame})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,Padding=UDim.new(0,4),Parent=chFrame})
        mk("TextLabel",{Text="Channel Weights",Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=chFrame})
        for _,ch in ipairs({"Structural","Metabolic","Ownership","Replication","Latent","Agent","Network"}) do
            local w=mem.ChannelWeights[ch] or 1.0
            local barRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,22),Parent=chFrame})
            mk("TextLabel",{Text=string.format("%-12s  %.3f",ch,w),Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(70,70,70),Size=UDim2.new(0,180,1,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=barRow})
            local barBg=mk("Frame",{BackgroundColor3=Color3.fromRGB(235,230,225),Size=UDim2.new(1,-190,0,10),Position=UDim2.new(0,190,0.5,-5),Parent=barRow}); addCorner(barBg,UDim.new(0,5))
            local pct=math.clamp((w-0.2)/(2.0-0.2),0,1)
            local barFill=mk("Frame",{BackgroundColor3=Color3.fromRGB(160,200,160),Size=UDim2.new(pct,0,1,0),Parent=barBg}); addCorner(barFill,UDim.new(0,5))
        end

        -- Value axis weights
        local vwFrame=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=stateScroll})
        addCorner(vwFrame,UDim.new(0,6)); addStroke(vwFrame,1,0.2)
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10),PaddingBottom=UDim.new(0,8),Parent=vwFrame})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,Padding=UDim.new(0,4),Parent=vwFrame})
        mk("TextLabel",{Text="Value Axis Weights",Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=vwFrame})
        for _,axis in ipairs({"Reliability","InformationGain","Cost","Reversibility","Optionality","Stability"}) do
            local w=ValueWeights[axis] or 1.0
            local axRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,22),Parent=vwFrame})
            mk("TextLabel",{Text=string.format("%-16s %.3f",axis,w),Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(70,70,70),Size=UDim2.new(0,200,1,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=axRow})
            local axBg=mk("Frame",{BackgroundColor3=Color3.fromRGB(235,230,225),Size=UDim2.new(1,-210,0,10),Position=UDim2.new(0,210,0.5,-5),Parent=axRow}); addCorner(axBg,UDim.new(0,5))
            local pct=math.clamp((w-0.1)/(2.0-0.1),0,1)
            local axFill=mk("Frame",{BackgroundColor3=Color3.fromRGB(180,160,220),Size=UDim2.new(pct,0,1,0),Parent=axBg}); addCorner(axFill,UDim.new(0,5))
        end

        -- Card posteriors (top 20 most active)
        local sortedCards={}
        for id,h in pairs(mem.CardHistory) do table.insert(sortedCards,{ID=id,H=h}) end
        table.sort(sortedCards,function(a,b) return a.H.n>b.H.n end)
        if #sortedCards>0 then
            local postFrame=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=stateScroll})
            addCorner(postFrame,UDim.new(0,6)); addStroke(postFrame,1,0.2)
            mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10),PaddingBottom=UDim.new(0,8),Parent=postFrame})
            mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,Padding=UDim.new(0,3),Parent=postFrame})
            mk("TextLabel",{Text="Card Posteriors (top 20 by n)",Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=postFrame})
            mk("TextLabel",{Text=string.format("%-18s %5s %5s %5s %5s  %4s","ID[:8]","α","β","mean","σ","n"),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(120,120,120),Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=postFrame})
            for i=1,math.min(20,#sortedCards) do
                local entry=sortedCards[i]; local h=entry.H
                local mean=h.alpha/(h.alpha+h.beta)
                mk("TextLabel",{
                    Text=string.format("%-18s %5.2f %5.2f %5.3f %5.3f %4d",
                        entry.ID:sub(1,8), h.alpha, h.beta, mean, h.StdDev or 0, h.n),
                    Font=Enum.Font.Code,TextSize=10,
                    TextColor3=mean>=0.6 and Color3.fromRGB(60,140,60) or Color3.fromRGB(140,80,80),
                    Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=postFrame})
            end
        end

        -- Phase shift log
        if #mem.PhaseShifts>0 then
            local psFrame=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=stateScroll})
            addCorner(psFrame,UDim.new(0,6)); addStroke(psFrame,1,0.2)
            mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10),PaddingBottom=UDim.new(0,8),Parent=psFrame})
            mk("UIListLayout",{FillDirection=Enum.FillDirection.Vertical,Padding=UDim.new(0,3),Parent=psFrame})
            mk("TextLabel",{Text="Phase Shift Log",Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=psFrame})
            local shown=math.min(8,#mem.PhaseShifts)
            for i=#mem.PhaseShifts-shown+1,#mem.PhaseShifts do
                local ps=mem.PhaseShifts[i]
                mk("TextLabel",{
                    Text=string.format("Cycle %d  [%s]  prior=%.3f → recent=%.3f",ps.Cycle,ps.Channel,ps.PriorMean,ps.RecentMean),
                    Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(180,100,50),
                    Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=psFrame})
            end
        end
    end

    refreshBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(refreshBtn.Button); refreshRecursive() end)
    local prevOnCommit=RAE_Callbacks.OnCommit
    RAE_Callbacks.OnCommit=function(log)
        if prevOnCommit then prevOnCommit(log) end
        refreshRecursive()
    end
end

-- ============================================================
-- PAGE: Bridge (Staged Execution)
-- ============================================================
do
    local _, sBridge=makeSection(pageBridge,"Staged Chain Execution")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Preview then execute the selected card chain. Chains containing Medium/High risk cards follow the Staged path: Observe → Probe → Commit → Verify. CDG causal reordering is applied automatically.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,64),Parent=sBridge})

    local bridgeStateLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="State: Idle",TextColor3=Color3.fromRGB(92,84,76),TextSize=13,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sBridge})
    local previewScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,200),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sBridge})
    addCorner(previewScroll,UDim.new(0,8)); addStroke(previewScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=previewScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=previewScroll})

    local logScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,160),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sBridge})
    addCorner(logScroll,UDim.new(0,8)); addStroke(logScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=logScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})

    local function clearScroller(s)
        s:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=s})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=s})
    end

    local btnRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sBridge})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,12),Parent=btnRow})
    local previewBtn=makeButton(btnRow,"Preview Chain",UDim2.new(0,200,0,40),"👁")
    previewBtn.Button.BackgroundColor3=Color3.fromRGB(220,230,255)
    local execBtn=makeButton(btnRow,"Execute Chain",UDim2.new(0,200,0,40),"▶")
    execBtn.Button.BackgroundColor3=Color3.fromRGB(220,255,220)

    previewBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(previewBtn.Button)
        if #RAE_State.SelectedCards==0 then sendNotification("No cards selected. Use the RAE tab to select.", "Warning"); return end
        clearScroller(previewScroll)
        local chain,staged=Executor.Preview(RAE_State.SelectedCards, RAE_State.Cards)
        bridgeStateLabel.Text=string.format("State: Previewed  |  %d steps  |  Path: %s  |  CDG reordered",#chain,staged and "STAGED" or "FAST")
        for i,card in ipairs(chain) do
            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,38),Parent=previewScroll})
            addCorner(row,UDim.new(0,5)); addStroke(row,1,0.25)
            local risk=card.Metadata.Risk or "None"
            local riskColor=risk=="High" and Color3.fromRGB(200,80,80) or risk=="Medium" and Color3.fromRGB(200,160,60) or Color3.fromRGB(80,180,80)
            mk("TextLabel",{Text=string.format("%d. [%s] %s",i,card.Channel,card.Name),Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-110,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
            mk("TextLabel",{Text=string.format("Risk:%s Conf:%d%% CDG:%.2f",risk,card.Metadata.Confidence or 0,CDG.GetCausalScore(card.ID)),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(100,100,100),Position=UDim2.new(0,8,0,22),Size=UDim2.new(1,-110,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
            local tag=mk("TextLabel",{Text=(staged and risk~="None") and "STAGED" or "FAST",Font=Enum.Font.GothamBold,TextSize=10,TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=riskColor,AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-8,0.5,0),Size=UDim2.new(0,56,0,22),Parent=row})
            addCorner(tag,UDim.new(0,5))
        end
    end)

    execBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(execBtn.Button)
        if #RAE_State.SelectedCards==0 then sendNotification("No cards selected.", "Warning"); return end
        bridgeStateLabel.Text="State: Executing..."
        clearScroller(logScroll)
        task.spawn(function()
            local log=RAE_Commit()
            if not log then bridgeStateLabel.Text="State: Error — no log returned."; return end
            local passed,failed=0,0
            for _,r in ipairs(log) do
                if r.Success then passed=passed+1 else failed=failed+1 end
                local row=mk("Frame",{BackgroundColor3=r.Success and Color3.fromRGB(240,255,240) or Color3.fromRGB(255,235,235),Size=UDim2.new(1,0,0,32),Parent=logScroll})
                addCorner(row,UDim.new(0,5)); addStroke(row,1,0.2)
                mk("TextLabel",{Text=string.format("%s  [%s] %s — %s%s",r.Success and "✓" or "✕",r.Step.Channel,r.Step.Name,r.Reason or "?",r.Stage and (" ["..r.Stage.."]") or ""),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,1,-8),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextWrapped=true,Parent=row})
            end
            bridgeStateLabel.Text=string.format("State: Complete  |  ✓ %d  ✕ %d  |  Cycle #%d",passed,failed,RAE_State.CycleCount)
        end)
    end)
end

-- ============================================================
-- PAGE: Analytics (NEW v2 — Deep Intelligence Dashboard)
-- ============================================================
do
    local _, sHdr=makeSection(pageAnalytics,"Deep Intelligence Analytics")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Live view of ETM convergence map, CDG causal dependency edges, LWM temporal deltas, and Brier calibration score. Data accumulates across Commit cycles and persists in _G between sessions.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=sHdr})
    local refreshAnalytics=makeButton(sHdr,"Refresh Analytics",UDim2.new(0,220,0,40),"📊")
    refreshAnalytics.Button.BackgroundColor3=Color3.fromRGB(220,240,255)

    -- ETM Convergence
    local _, sETM=makeSection(pageAnalytics,"ETM Convergence Map")
    local etmScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,200),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sETM})
    addCorner(etmScroll,UDim.new(0,8)); addStroke(etmScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=etmScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=etmScroll})

    -- CDG Edges
    local _, sCDG=makeSection(pageAnalytics,"Causal Dependency Graph — Strong Edges")
    local cdgScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,220),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sCDG})
    addCorner(cdgScroll,UDim.new(0,8)); addStroke(cdgScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=cdgScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=cdgScroll})

    -- LWM Temporal
    local _, sLWM=makeSection(pageAnalytics,"Living World Model — Temporal Deltas")
    local lwmLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No snapshots yet.",TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,96),Parent=sLWM})

    -- Calibration
    local _, sCal=makeSection(pageAnalytics,"Brier Score Calibration")
    local calLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No calibration data yet.",TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,64),Parent=sCal})

    local function doRefreshAnalytics()
        -- ETM
        etmScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=etmScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=etmScroll})
        local cmap=ETM.GetConvergenceMap()
        local gcov=cmap["_global"] or {total=0,converged=0,rate=0}
        local sumRow=mk("Frame",{BackgroundColor3=Color3.fromRGB(230,240,255),Size=UDim2.new(1,0,0,26),Parent=etmScroll})
        addCorner(sumRow,UDim.new(0,5))
        mk("TextLabel",{Text=string.format("GLOBAL: %d/%d converged (%.0f%%)  — threshold: σ<%.2f, n≥%d",
            gcov.converged,gcov.total,gcov.rate*100,ETM_CFG.ConvergenceStdDev,ETM_CFG.MinCount),
            Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(50,50,90),
            Size=UDim2.new(1,-16,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=sumRow})
        for cardID,stats in pairs(cmap) do
            if cardID~="_global" then
                local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,22),Parent=etmScroll})
                addCorner(row,UDim.new(0,4)); addStroke(row,1,0.3)
                local convColor=stats.converged>0 and Color3.fromRGB(60,160,60) or Color3.fromRGB(160,100,60)
                mk("TextLabel",{Text=string.format("Card %s  |  sigs: %d  |  conv: %d  |  rate: %.0f%%",cardID:sub(1,8),stats.total,stats.converged,stats.rate*100),
                    Font=Enum.Font.Code,TextSize=10,TextColor3=convColor,
                    Size=UDim2.new(1,-16,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=row})
            end
        end
        if gcov.total==0 then mk("TextLabel",{Text="No ETM data yet. Run Scan → Plan → Commit to populate.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=etmScroll}) end

        -- CDG
        cdgScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=cdgScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=cdgScroll})
        local hdr=mk("TextLabel",{Text=string.format("%-10s  %-10s  %6s  %5s  %5s  %5s","FromID[:8]","ToID[:8]","Effect","Conf","CoSuc","CoFai"),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(120,120,120),Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=cdgScroll})
        local edges=CDG.GetStrongEdges(0.10)
        if #edges==0 then
            mk("TextLabel",{Text="No causal edges with confidence ≥ 0.10 yet. Run more cycles.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=cdgScroll})
        else
            for _,e in ipairs(edges) do
                local effColor=e.EffectSize>0 and Color3.fromRGB(60,140,60) or Color3.fromRGB(160,60,60)
                local eRow=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,22),Parent=cdgScroll})
                addCorner(eRow,UDim.new(0,4)); addStroke(eRow,1,0.3)
                mk("TextLabel",{Text=string.format("%-10s  %-10s  %+6.3f  %5.2f  %5d  %5d",e.FromID:sub(1,8),e.ToID:sub(1,8),e.EffectSize,e.Confidence,e.CoSuccess,e.CoFail),
                    Font=Enum.Font.Code,TextSize=10,TextColor3=effColor,
                    Size=UDim2.new(1,-16,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=eRow})
            end
        end

        -- LWM
        local buf=LWM.GetBuffer()
        if #buf<2 then lwmLabel.Text="Less than 2 snapshots — run more cycles to see deltas."
        else
            local delta=LWM.GetDelta()
            local avgHealth=LWM.GetTemporalAverage("health",5)
            local avgPhys=LWM.GetTemporalAverage("physCount",5)
            local avgFires=LWM.GetTemporalAverage("remoteFires",5)
            lwmLabel.Text=string.format(
                "Snapshots: %d  |  Current sig: %s\nΔ health: %+.1f  Δ physics: %+d  Δ fires: %+d  Δ elapsed: %.2fs\nAvg health (5): %.1f  Avg physics: %.1f  Avg fires: %.1f\nRemote registry: %d tracked",
                #buf, LWM.GetRecentSig(),
                delta and delta.healthDelta or 0, delta and delta.physDelta or 0,
                delta and delta.firesDelta or 0, delta and delta.elapsed or 0,
                avgHealth, avgPhys, avgFires,
                (function() local t=0; for _ in pairs(LWM.GetRemoteRegistry()) do t=t+1 end; return t end)())
        end

        -- Calibration
        local calLog=Intel.GetMemory().CalibrationLog
        local brier=ComputeBrierScore()
        if not brier or #calLog==0 then calLabel.Text="No calibration data yet. Run Commit cycles to populate."
        else
            local buckets={}; local bN=10
            for i=1,bN do buckets[i]={predicted=0,actual=0,count=0} end
            for _,e in ipairs(calLog) do
                local b=math.clamp(math.floor(e.Predicted*bN)+1,1,bN)
                buckets[b].predicted=buckets[b].predicted+e.Predicted
                buckets[b].actual=buckets[b].actual+e.Actual
                buckets[b].count=buckets[b].count+1
            end
            local lines={}
            table.insert(lines,string.format("Brier Score: %.4f  (last %d entries)  |  0.0=perfect, 1.0=worst",brier,math.min(#calLog,100)))
            table.insert(lines,"Calibration buckets (predicted prob → actual freq):")
            for i=1,bN do
                local b=buckets[i]
                if b.count>0 then
                    local avgPred=b.predicted/b.count; local avgAct=b.actual/b.count
                    local bar=string.rep("█",math.floor(avgAct*20))..string.rep("░",20-math.floor(avgAct*20))
                    table.insert(lines,string.format("[%.1f-%.1f] pred=%.2f act=%.2f n=%d  %s",
                        (i-1)/bN, i/bN, avgPred, avgAct, b.count, bar))
                end
            end
            calLabel.Text=table.concat(lines,"\n")
            calLabel.Size=UDim2.new(1,0,0,math.max(64,#lines*14+8))
        end
    end

    refreshAnalytics.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(refreshAnalytics.Button); doRefreshAnalytics() end)
    local prevOnCommit2=RAE_Callbacks.OnCommit
    RAE_Callbacks.OnCommit=function(log)
        if prevOnCommit2 then prevOnCommit2(log) end
        doRefreshAnalytics()
    end
end

-- ============================================================
-- PAGE: Chain (Visual Node Editor)
-- ============================================================
do
    local _, sChain=makeSection(pageChain,"Visual Chain Editor")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Drag and connect nodes to build execution chains. Supported node types: Start, Wait, Fire Remote, Check Inventory, RAE Scan, RAE Plan, RAE Commit. Run executes the chain sequentially.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=sChain})

    local canvas=mk("Frame",{BackgroundColor3=Color3.fromRGB(240,237,232),Size=UDim2.new(1,0,0,340),Parent=sChain})
    addCorner(canvas,UDim.new(0,10)); addStroke(canvas,1,0.3)
    local canvasNodes={}; local connections={}

    local nodeTypes={
        {Name="Start",      Color=Color3.fromRGB(180,230,180), Icon="▶"},
        {Name="Wait",       Color=Color3.fromRGB(220,220,180), Icon="⏱"},
        {Name="Fire Remote",Color=Color3.fromRGB(200,220,255), Icon="🔥"},
        {Name="Check Inv",  Color=Color3.fromRGB(255,220,200), Icon="🎒"},
        {Name="RAE Scan",   Color=Color3.fromRGB(220,200,255), Icon="🔍"},
        {Name="RAE Plan",   Color=Color3.fromRGB(200,255,220), Icon="🧠"},
        {Name="RAE Commit", Color=Color3.fromRGB(255,230,200), Icon="▶"},
    }

    local nodeActions={
        ["Start"]       = function() return true end,
        ["Wait"]        = function() task.wait(1); return true end,
        ["Fire Remote"] = function()
            local ws=RAE_State.WorldState
            if ws and #ws.Latent.RemoteEvents>0 then
                local r=ws.Latent.RemoteEvents[1]; pcall(function() r.Instance:FireServer() end); return true
            end; return false
        end,
        ["Check Inv"]   = function() local char=player.Character; return char and char:FindFirstChildOfClass("Tool")~=nil end,
        ["RAE Scan"]    = function() return RAE_Scan() end,
        ["RAE Plan"]    = function() return RAE_Plan()~=nil end,
        ["RAE Commit"]  = function() return RAE_Commit()~=nil end,
    }

    local paletteRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sChain})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),Parent=paletteRow})

    local function addNode(nodeType, posX, posY)
        posX=posX or math.random(30,200); posY=posY or math.random(20,260)
        local nodeFrame=mk("Frame",{BackgroundColor3=nodeType.Color,Size=UDim2.new(0,110,0,44),Position=UDim2.new(0,posX,0,posY),Parent=canvas})
        addCorner(nodeFrame,UDim.new(0,8)); addStroke(nodeFrame,1,0.2)
        local nodeLabel=mk("TextLabel",{Text=nodeType.Icon.." "..nodeType.Name,Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,-8,0,16),Position=UDim2.new(0,4,0,4),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=nodeFrame})
        local inDot=mk("Frame",{BackgroundColor3=Color3.fromRGB(100,100,200),Size=UDim2.new(0,12,0,12),Position=UDim2.new(0,-6,0.5,-6),Parent=nodeFrame}); addCorner(inDot,UDim.new(0,999))
        local outDot=mk("Frame",{BackgroundColor3=Color3.fromRGB(200,100,100),Size=UDim2.new(0,12,0,12),Position=UDim2.new(1,-6,0.5,-6),Parent=nodeFrame}); addCorner(outDot,UDim.new(0,999))
        local idLabel=mk("TextLabel",{Text="id:"..tostring(#canvasNodes+1),Font=Enum.Font.Code,TextSize=9,TextColor3=Color3.fromRGB(120,120,120),Size=UDim2.new(1,-8,0,12),Position=UDim2.new(0,4,1,-16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=nodeFrame})
        local node={Frame=nodeFrame,Type=nodeType.Name,Action=nodeActions[nodeType.Name],dragging=false,dragOffset=Vector2.new()}
        table.insert(canvasNodes,node)
        nodeFrame.InputBegan:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 then
                node.dragging=true; node.dragOffset=i.Position-Vector2.new(nodeFrame.AbsolutePosition.X,nodeFrame.AbsolutePosition.Y)
            end
        end)
        nodeFrame.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then node.dragging=false end end)
        UserInputService.InputChanged:Connect(function(i)
            if node.dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
                local newPos=Vector2.new(i.Position.X,i.Position.Y)-node.dragOffset
                local relX=newPos.X-canvas.AbsolutePosition.X; local relY=newPos.Y-canvas.AbsolutePosition.Y
                nodeFrame.Position=UDim2.new(0,math.clamp(relX,0,canvas.AbsoluteSize.X-114),0,math.clamp(relY,0,canvas.AbsoluteSize.Y-48))
            end
        end)
        return node
    end

    for i,nt in ipairs(nodeTypes) do
        local pb=mk("TextButton",{Text=nt.Icon.." "..nt.Name,Font=Enum.Font.GothamBold,TextSize=11,BackgroundColor3=nt.Color,Size=UDim2.new(0,100,0,36),Parent=paletteRow})
        addCorner(pb,UDim.new(0,8)); addStroke(pb,1,0.3)
        local ntCapture=nt
        pb.MouseButton1Click:Connect(function() clickSound(); addNode(ntCapture) end)
    end

    local ctrlRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sChain})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,12),Parent=ctrlRow})
    local runBtn=makeButton(ctrlRow,"Run Chain",UDim2.new(0,160,0,40),"▶"); runBtn.Button.BackgroundColor3=Color3.fromRGB(220,255,220)
    local clearBtn=makeButton(ctrlRow,"Clear",UDim2.new(0,120,0,40),"✕"); clearBtn.Button.BackgroundColor3=Color3.fromRGB(255,230,230)
    local chainStatusLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Chain idle.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sChain})

    runBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(runBtn.Button)
        if #canvasNodes==0 then sendNotification("No nodes in chain.", "Warning"); return end
        task.spawn(function()
            chainStatusLabel.Text="Running chain..."
            local passed,failed=0,0
            for i,node in ipairs(canvasNodes) do
                local prevBg=node.Frame.BackgroundColor3
                tween(node.Frame,TweenInfo.new(0.1),{BackgroundColor3=Color3.fromRGB(255,255,180)})
                local ok,result=pcall(function() return node.Action and node.Action() end)
                local success=ok and result~=false
                if success then passed=passed+1 else failed=failed+1 end
                tween(node.Frame,TweenInfo.new(0.2),{BackgroundColor3=success and Color3.fromRGB(180,255,180) or Color3.fromRGB(255,180,180)})
                task.wait(0.35)
                tween(node.Frame,TweenInfo.new(0.2),{BackgroundColor3=prevBg})
                task.wait(0.1)
            end
            chainStatusLabel.Text=string.format("Chain complete. ✓ %d  ✕ %d",passed,failed)
        end)
    end)
    clearBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(clearBtn.Button)
        for _,node in ipairs(canvasNodes) do node.Frame:Destroy() end
        canvasNodes={}; connections={}; chainStatusLabel.Text="Chain cleared."
    end)
    -- Seed with Start node
    addNode(nodeTypes[1], 20, 140)
end

-- ============================================================
-- PAGE: Utilities
-- ============================================================
do
    -- Performance
    local _, sPerf=makeSection(pageUtils,"Performance Monitor")
    local fpsLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="FPS: --  Frame: --ms",TextColor3=Color3.fromRGB(72,66,60),TextSize=12,Size=UDim2.new(1,0,0,20),Parent=sPerf})
    local fpsAccum=0; local fpsFrames=0; local fpsLast=os.clock()
    RunService.RenderStepped:Connect(function(dt)
        fpsAccum=fpsAccum+dt; fpsFrames=fpsFrames+1
        if os.clock()-fpsLast>=0.5 then
            local fps=fpsFrames/(os.clock()-fpsLast)
            fpsLabel.Text=string.format("FPS: %.0f  Frame: %.2fms",fps,1000/math.max(fps,0.001))
            fpsAccum=0; fpsFrames=0; fpsLast=os.clock()
        end
    end)

    -- System Overrides
    local _, sSys=makeSection(pageUtils,"System Overrides")
    local purgeBtn=makeButton(sSys,"Purge Event Hooks",UDim2.new(0,240,0,40),"🗑")
    purgeBtn.Button.BackgroundColor3=Color3.fromRGB(255,230,230)
    purgeBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(purgeBtn.Button)
        local purged=0
        local function tryPurge(sig)
            if sig and type(getconnections)=="function" then
                pcall(function() for _,c in ipairs(getconnections(sig)) do c:Disconnect(); purged=purged+1 end end)
            end
        end
        tryPurge(RunService.RenderStepped); tryPurge(RunService.Stepped)
        tryPurge(RunService.Heartbeat)
        local char=player.Character; local hum=char and char:FindFirstChildOfClass("Humanoid")
        if hum then tryPurge(hum.HealthChanged) end
        sendNotification(string.format("Purged %d event hooks.",purged), "Success")
    end)

    -- Network Utilities
    local _, sNet=makeSection(pageUtils,"Network Utilities")
    local SpoofMetrics=false; local ReplayAmplifier=false; local SanitizeTables=false; local CallbackCapture=false; local CloneAmount=1
    makeToggle(sNet,"Metric Spoof (60fps / 45ms)",false,function(on) SpoofMetrics=on end)
    makeToggle(sNet,"Sanitize Tables",false,function(on) SanitizeTables=on end)
    makeToggle(sNet,"Callback Capture",false,function(on) CallbackCapture=on end)
    makeSlider(sNet,"Replay Clone Amount",1,10,1,function(v) CloneAmount=math.floor(v); ReplayAmplifier=CloneAmount>1 end)

    -- Cipher Decrypter
    local _, sCipher=makeSection(pageUtils,"Cipher Decrypter")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Paste a Base64 or JSON string to decode.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sCipher})
    local cipherInput=mk("TextBox",{PlaceholderText="Paste encoded string here...",Text="",BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,36),Font=Enum.Font.Code,TextSize=12,Parent=sCipher})
    addCorner(cipherInput,UDim.new(0,8)); addStroke(cipherInput,1,0.3)
    local cipherBtn=makeButton(sCipher,"Decode",UDim2.new(0,160,0,36),"🔓"); cipherBtn.Button.BackgroundColor3=Color3.fromRGB(220,255,220)
    local cipherOut=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="",TextColor3=Color3.fromRGB(60,60,60),TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,48),Parent=sCipher})
    cipherBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(cipherBtn.Button)
        local t,result=tryDecode(cipherInput.Text)
        if t then
            local disp=type(result)=="table" and (function() local s,j=pcall(function() return HttpService:JSONEncode(result) end); return s and j or "[table]" end)() or tostring(result)
            cipherOut.Text=string.format("[%s] %s",t,disp)
        else cipherOut.Text="Could not decode. Not Base64 or JSON." end
    end)

    -- Hidden UI Inspector
    local _, sUI=makeSection(pageUtils,"Hidden UI Inspector")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Scans PlayerGui for hidden ScreenGui / GuiObjects.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sUI})
    local uiScanBtn=makeButton(sUI,"Scan Hidden UI",UDim2.new(0,200,0,36),"👁"); uiScanBtn.Button.BackgroundColor3=Color3.fromRGB(220,220,255)
    local uiScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,160),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sUI})
    addCorner(uiScroll,UDim.new(0,8)); addStroke(uiScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=uiScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=uiScroll})
    uiScanBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(uiScanBtn.Button)
        uiScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=uiScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=uiScroll})
        local found=0
        for _,obj in ipairs(playerGui:GetDescendants()) do
            local hidden=(obj:IsA("ScreenGui") and not obj.Enabled) or (obj:IsA("GuiObject") and not obj.Visible)
            if hidden then
                found=found+1
                local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,36),Parent=uiScroll})
                addCorner(row,UDim.new(0,5)); addStroke(row,1,0.25)
                mk("TextLabel",{Text=obj.ClassName..": "..obj:GetFullName(),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(60,60,60),Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-90,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=row})
                local showBtn=mk("TextButton",{Text="Show",Font=Enum.Font.GothamBold,TextSize=10,BackgroundColor3=Color3.fromRGB(220,240,220),Size=UDim2.new(0,68,0,24),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-8,0.5,0),Parent=row})
                addCorner(showBtn,UDim.new(0,5))
                local objCapture=obj
                showBtn.MouseButton1Click:Connect(function()
                    clickSound(); pulseClick(showBtn)
                    if objCapture:IsA("ScreenGui") then objCapture.Enabled=not objCapture.Enabled; showBtn.Text=objCapture.Enabled and "Hide" or "Show"
                    elseif objCapture:IsA("GuiObject") then objCapture.Visible=not objCapture.Visible; showBtn.Text=objCapture.Visible and "Hide" or "Show" end
                end)
            end
        end
        if found==0 then mk("TextLabel",{Text="No hidden UI found.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=uiScroll}) end
        sendNotification("UI scan complete. Found "..found.." hidden elements.", found>0 and "Warning" or "Info")
    end)

    -- Tool Utilities
    local _, sTool=makeSection(pageUtils,"Tool Utilities")
    local dropBtn=makeButton(sTool,"Force Drop Tool",UDim2.new(0,200,0,36),"🗑")
    dropBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(dropBtn.Button)
        local char=player.Character; local tool=char and char:FindFirstChildOfClass("Tool")
        if tool then pcall(function() tool.Parent=player.Backpack end); sendNotification("Tool unequipped: "..tool.Name, "Success")
        else sendNotification("No tool equipped.", "Warning") end
    end)
    local unlockBtn=makeButton(sTool,"Unlock All Droppable",UDim2.new(0,200,0,36),"🔓")
    unlockBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(unlockBtn.Button)
        local count=0
        for _,obj in ipairs(player.Backpack:GetChildren()) do
            if obj:IsA("Tool") then pcall(function() obj.CanBeDropped=true; count=count+1 end) end
        end
        sendNotification(string.format("Unlocked %d tools.",count), "Success")
    end)
    local ghostBtn=makeButton(sTool,"Ghost Equip",UDim2.new(0,200,0,36),"👻")
    ghostBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(ghostBtn.Button)
        local char=player.Character; local tool=char and char:FindFirstChildOfClass("Tool")
        if not tool then sendNotification("No tool equipped.", "Warning"); return end
        local count=0
        for _,part in ipairs(tool:GetDescendants()) do
            if part:IsA("BasePart") then pcall(function() part:Destroy(); count=count+1 end) end
        end
        sendNotification(string.format("Ghost equip: destroyed %d parts in '%s'.",count,tool.Name), "Success")
    end)

    -- Chrono Bypass
    local _, sChrono=makeSection(pageUtils,"Chrono-Bypass")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Hooks tick/os.time/time to return modified values for cooldown bypass.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,36),Parent=sChrono})
    local ChronoMode="off"
    local function makeChronoBtn(label, mode, color)
        local b=makeButton(sChrono,label,UDim2.new(0,180,0,36),"⏱"); b.Button.BackgroundColor3=color
        b.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(b.Button); ChronoMode=mode
            if hookfunction and type(hookfunction)=="function" then
                if mode=="past" then
                    pcall(function() hookfunction(tick, function() return 1 end) end)
                    pcall(function() hookfunction(os.time, function() return 1 end) end)
                    pcall(function() hookfunction(time, function() return 1 end) end)
                elseif mode=="future" then
                    pcall(function() hookfunction(tick, function() return 1000000 end) end)
                    pcall(function() hookfunction(os.time, function() return 1000000 end) end)
                    pcall(function() hookfunction(time, function() return 1000000 end) end)
                end
            end
            sendNotification("Chrono mode: "..mode, "Info")
        end)
    end
    local chronoRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,40),Parent=sChrono})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=chronoRow})
    makeChronoBtn("Past (freeze)",  "past",   Color3.fromRGB(200,220,255))
    makeChronoBtn("Future (unlock)","future", Color3.fromRGB(220,255,200))

    -- Physics & Fling
    local _, sPhys=makeSection(pageUtils,"Physics & Fling")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Tool Fling Aura: removes RightGrip, adds NoCollisionConstraints, applies extreme velocity.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,36),Parent=sPhys})
    local flingBtn=makeButton(sPhys,"Tool Fling Aura",UDim2.new(0,200,0,36),"💥"); flingBtn.Button.BackgroundColor3=Color3.fromRGB(255,220,220)
    flingBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(flingBtn.Button)
        local char=player.Character; local tool=char and char:FindFirstChildOfClass("Tool")
        if not tool then sendNotification("No tool equipped for fling.", "Warning"); return end
        local count=0
        pcall(function()
            local grip=char:FindFirstChild("RightGrip"); if grip then grip:Destroy() end
            for _,part in ipairs(tool:GetDescendants()) do
                if part:IsA("BasePart") then
                    local nc=Instance.new("NoCollisionConstraint"); nc.Part0=part
                    local hrp=char:FindFirstChild("HumanoidRootPart"); if hrp then nc.Part1=hrp end
                    nc.Parent=part; part.AssemblyLinearVelocity=Vector3.new(50000,50000,50000); count=count+1
                end
            end
        end)
        sendNotification(string.format("Fling aura applied to %d parts.",count), "Warning")
    end)

    -- Signal Viewer
    local _, sSig=makeSection(pageUtils,"Signal Viewer")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Click a part in the workspace to view its connected signals. Requires getconnections.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,36),Parent=sSig})
    local sigListening=false; local sigToggle=makeButton(sSig,"Start Listening",UDim2.new(0,200,0,36),"👂"); sigToggle.Button.BackgroundColor3=Color3.fromRGB(220,240,220)
    local sigScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,140),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sSig})
    addCorner(sigScroll,UDim.new(0,8)); addStroke(sigScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=sigScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=sigScroll})
    local sigConn=nil
    sigToggle.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(sigToggle.Button)
        sigListening=not sigListening; sigToggle.Label.Text=sigListening and "Stop Listening" or "Start Listening"
        if sigListening then
            sigConn=UserInputService.InputBegan:Connect(function(i)
                if not sigListening then return end
                if i.UserInputType~=Enum.UserInputType.MouseButton1 then return end
                local cam=Workspace.CurrentCamera; local mouse=player:GetMouse()
                local ray=cam:ScreenPointToRay(mouse.X, mouse.Y)
                local result=Workspace:Raycast(ray.Origin, ray.Direction*500)
                if result and result.Instance then
                    local part=result.Instance
                    sigScroll:ClearAllChildren()
                    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=sigScroll})
                    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=sigScroll})
                    local titleRow=mk("TextLabel",{Text="Signals for: "..part.Name,Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=sigScroll})
                    local signals={"Touched","TouchEnded","Changed"}
                    for _,sigName in ipairs(signals) do
                        local sig=part[sigName]
                        if sig and type(getconnections)=="function" then
                            local conns; pcall(function() conns=getconnections(sig) end)
                            if conns and #conns>0 then
                                for ci,conn in ipairs(conns) do
                                    local connRow=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,26),Parent=sigScroll})
                                    addCorner(connRow,UDim.new(0,4)); addStroke(connRow,1,0.3)
                                    mk("TextLabel",{Text=string.format("[%s] conn%d",sigName,ci),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(60,60,60),Size=UDim2.new(1,-80,1,0),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=connRow})
                                    local decompBtn=mk("TextButton",{Text="Decompile",Font=Enum.Font.GothamBold,TextSize=9,BackgroundColor3=Color3.fromRGB(220,220,255),Size=UDim2.new(0,72,0,20),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-4,0.5,0),Parent=connRow})
                                    addCorner(decompBtn,UDim.new(0,4))
                                    local connCapture=conn
                                    decompBtn.MouseButton1Click:Connect(function()
                                        clickSound()
                                        local src; pcall(function() src=connCapture.Function end)
                                        if src and getfenv then
                                            local env; pcall(function() env=getfenv(src) end)
                                            if env and env.script then displayDecompiledScript(env.script); return end
                                        end
                                        sendNotification("Could not resolve script for this connection.", "Warning")
                                    end)
                                end
                            end
                        end
                    end
                end
            end)
        else if sigConn then sigConn:Disconnect(); sigConn=nil end end
    end)

    -- UI Scale
    local _, sScale=makeSection(pageUtils,"UI Scale")
    makeSlider(sScale,"Window Scale",0.7,1.3,1.0,function(v)
        local sz=window.Size; window.Size=UDim2.new(0,math.floor(960*v),0,math.floor(580*v))
    end)
end

-- ============================================================
-- PAGE: About
-- ============================================================
do
    local _, sAbout=makeSection(pageAbout,"About")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Paper & Clay + RAE v2.0 — Deep Intelligence Edition\n\nRAE (Recursive Autonomous Engine) is a 7-layer autonomous agent extended with four new deep intelligence modules:\n\n• StateSignature φ(S): Compact, canonical, hash-stable state token enabling state-conditional learning.\n• LWM (Living World Model): Ring-buffer temporal model with delta tracking and remote co-firing registry.\n• ETM (Empirical Transition Model): State-conditional Bayesian P(success|card, φ(S)) with Welford variance and convergence detection.\n• CDG (Causal Dependency Graph): Co-execution effect size and confidence tracking for causal chain reordering.\n• Risk-Adjusted MCTS: E[U(π)] − λ·Var[U(π)] planning criterion with ETM-blended rollouts.\n• Session Persistence: IntelMem, ETM, CDG tables stored in _G across sessions.\n• Brier Calibration: Predicted probability vs actual outcome tracking.",
        TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,200),Parent=sAbout})
    local _, sLinks=makeSection(pageAbout,"Quick Nav")
    local navLinks={{"Open RAE Tab","RAE"},{"Open Analytics Tab","Analytics"},{"Open Recursive Tab","Recursive"}}
    for _,nl in ipairs(navLinks) do
        local nb=makeButton(sLinks,nl[1],UDim2.new(0,220,0,36),"→"); nb.Button.BackgroundColor3=Color3.fromRGB(220,230,255)
        local targetName=nl[2]
        nb.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(nb.Button)
            for _, page in ipairs(pagesFolder:GetChildren()) do page.Visible=false end
            local pages={
                Overview=pageOverview, Player=pagePlayer, Camera=pageCamera, World=pageWorld,
                Discovery=pageDiscovery, RAE=pageRAE, Recursive=pageRecursive, Bridge=pageBridge,
                Analytics=pageAnalytics, Chain=pageChain, Utilities=pageUtils, About=pageAbout
            }
            if pages[targetName] then pages[targetName].Visible=true; panelTitle.Text=targetName end
        end)
    end
end

-- ============================================================
-- NAVIGATION SYSTEM
-- ============================================================
local TAB_DEFS = {
    { Name="Overview",   Page=pageOverview,  Icon="⊙" },
    { Name="Player",     Page=pagePlayer,    Icon="♟" },
    { Name="Camera",     Page=pageCamera,    Icon="📷" },
    { Name="World",      Page=pageWorld,     Icon="🌍" },
    { Name="Discovery",  Page=pageDiscovery, Icon="🔍" },
    { Name="RAE",        Page=pageRAE,       Icon="⚡" },
    { Name="Recursive",  Page=pageRecursive, Icon="🧠" },
    { Name="Bridge",     Page=pageBridge,    Icon="🔗" },
    { Name="Analytics",  Page=pageAnalytics, Icon="📊" },
    { Name="Chain",      Page=pageChain,     Icon="⛓" },
    { Name="Utilities",  Page=pageUtils,     Icon="🔧" },
    { Name="About",      Page=pageAbout,     Icon="ℹ" },
}
local activeTab=nil

local function switchTab(tabDef)
    if activeTab == tabDef then return end
    for _, page in ipairs(pagesFolder:GetChildren()) do page.Visible=false end
    tabDef.Page.Visible=true
    panelTitle.Text=tabDef.Name
    for _, td in ipairs(TAB_DEFS) do
        if td._btn then
            local isActive = (td == tabDef)
            tween(td._btn, TweenInfo.new(0.12), {BackgroundColor3=isActive and Color3.fromRGB(236,229,219) or Color3.fromRGB(245,239,231)})
            if td._stroke then tween(td._stroke, TweenInfo.new(0.12), {Transparency=isActive and 0.0 or 0.6}) end
        end
    end
    activeTab=tabDef
end

for _, tabDef in ipairs(TAB_DEFS) do
    local btn=mk("TextButton",{
        AutoButtonColor=false, BackgroundColor3=Color3.fromRGB(245,239,231),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,34), Font=Enum.Font.GothamSemibold,
        Text=tabDef.Icon.."  "..tabDef.Name, TextColor3=Color3.fromRGB(52,47,42),
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=navHolder,
    })
    mk("UIPadding",{PaddingLeft=UDim.new(0,10),Parent=btn})
    addCorner(btn,UDim.new(0,10))
    local st=addStroke(btn,1,0.6); tabDef._btn=btn; tabDef._stroke=st
    hookHover(btn,btn.BackgroundColor3,Color3.fromRGB(252,246,238),0.6,0.35)
    btn.MouseButton1Click:Connect(function() clickSound(); switchTab(tabDef) end)
end

-- Default to Overview
switchTab(TAB_DEFS[1])

-- ============================================================
-- WINDOW DRAG / RESIZE
-- ============================================================
do
    local dragging=false; local dragStart; local startPos
    topbar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true; dragStart=i.Position
            startPos=Vector2.new(window.Position.X.Offset, window.Position.Y.Offset)
        end
    end)
    topbar.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
            local delta=Vector2.new(i.Position.X-dragStart.X, i.Position.Y-dragStart.Y)
            window.AnchorPoint=Vector2.new(0,0)
            window.Position=UDim2.new(0,startPos.X+delta.X,0,startPos.Y+delta.Y)
        end
    end)
end
do
    local grip=mk("TextButton",{Text="↘",Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(160,150,140),BackgroundColor3=Color3.fromRGB(240,235,228),AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,0,1,0),Size=UDim2.new(0,28,0,28),ZIndex=20,Parent=window})
    addCorner(grip,UDim.new(0,8)); addStroke(grip,1,0.5)
    local resizing=false; local resStart; local resStartSz
    grip.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then
            resizing=true; resStart=Vector2.new(i.Position.X,i.Position.Y)
            resStartSz=Vector2.new(window.AbsoluteSize.X,window.AbsoluteSize.Y)
        end
    end)
    grip.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then resizing=false end end)
    UserInputService.InputChanged:Connect(function(i)
        if resizing and i.UserInputType==Enum.UserInputType.MouseMovement then
            local delta=Vector2.new(i.Position.X-resStart.X,i.Position.Y-resStart.Y)
            local nw=math.clamp(resStartSz.X+delta.X,720,1200)
            local nh=math.clamp(resStartSz.Y+delta.Y,440,820)
            window.Size=UDim2.new(0,nw,0,nh)
        end
    end)
end

-- ============================================================
-- MINIMIZE / CLOSE
-- ============================================================
local isMinimized=false
btnMin.MouseButton1Click:Connect(function()
    clickSound(); pulseClick(btnMin)
    isMinimized=not isMinimized
    tween(body, TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out), {Size=isMinimized and UDim2.new(1,0,0,0) or UDim2.new(1,0,1,-56)})
end)
btnClose.MouseButton1Click:Connect(function()
    clickSound(); pulseClick(btnClose)
    tween(window, TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.In), {BackgroundTransparency=1,Size=window.Size+UDim2.fromOffset(0,-20)})
    task.delay(0.25, function() screenGui:Destroy() end)
end)

-- ============================================================
-- INTRO ANIMATION
-- ============================================================
window.AnchorPoint=Vector2.new(0.5,0.5)
window.Position=UDim2.new(0.5,0,0.5,0)
window.Size=UDim2.new(0,0,0,0)
window.BackgroundTransparency=1
tween(window, TweenInfo.new(0.35,Enum.EasingStyle.Back,Enum.EasingDirection.Out), {
    Size=UDim2.new(0,960,0,580), BackgroundTransparency=0,
})

-- ============================================================
-- MASTER METATABLE HOOK
-- ============================================================
local SpoofedItems={}; local FakeCache={}; local TokenForge={}
local SpoofMetrics=false; local ReplayAmplifier=false; local SanitizeTables=false
local CallbackCaptureEnabled=false; local CloneAmount=1

if getrawmetatable and hookmetamethod and checkcaller then
    local mt=getrawmetatable(game)
    local oldNewindex=mt.__newindex
    local oldNamecall=mt.__namecall
    local oldIndex=mt.__index

    hookmetamethod(game,"__newindex",function(self,key,value)
        if not checkcaller() then
            if type(value)=="function" and key=="OnClientInvoke" then
                if CallbackCaptureEnabled then
                    local orig=value
                    value=function(...)
                        local args={...}
                        local disp={}
                        for i,v in ipairs(args) do disp[i]=type(v)=="table" and "[table]" or type(v)=="userdata" and "[instance]" or tostring(v) end
                        sendNotification("CB Capture ["..tostring(self).."] args: "..table.concat(disp,", "),"Info")
                        return orig(...)
                    end
                end
            end
        end
        return oldNewindex(self,key,value)
    end)

    hookmetamethod(game,"__namecall",function(self,...)
        if not checkcaller() then
            local method=getnamecallmethod()
            local args={...}

            if method=="FindFirstChild" or method=="WaitForChild" then
                local name=args[1]
                if SpoofedItems[name] then
                    local parent=self
                    if parent==player.Backpack or parent==player.Character then
                        if not FakeCache[name] then
                            local ft=Instance.new("Tool"); ft.Name=name; FakeCache[name]=ft
                        end
                        return FakeCache[name]
                    end
                end
            end

            if method=="FireServer" then
                local remote=self
                local fireArgs={...}
                if SanitizeTables then
                    local cleaned={}; for i,a in ipairs(fireArgs) do cleaned[i]=type(a)=="table" and cleanTable(a) or a end
                    fireArgs=cleaned
                end
                for i,a in ipairs(fireArgs) do
                    if type(a)=="string" and #a>3 then
                        local t,decoded=tryDecode(a)
                        if t then TokenForge[remote]=a end
                    end
                end
                if ReplayAmplifier and CloneAmount>1 then
                    for _=2,CloneAmount do
                        pcall(function() oldNamecall(remote,"FireServer",table.unpack(fireArgs)) end)
                    end
                end
                if SpoofMetrics then
                    local rname=tostring(remote.Name):lower()
                    if rname:find("ping") or rname:find("fps") or rname:find("heartbeat") or rname:find("analytic") then
                        local cleaned={}
                        for i,a in ipairs(fireArgs) do
                            if type(a)=="number" then
                                if rname:find("fps") then cleaned[i]=math.min(a,60)
                                elseif rname:find("ping") or rname:find("heartbeat") then cleaned[i]=math.max(a,45)
                                else cleaned[i]=a end
                            else cleaned[i]=a end
                        end
                        fireArgs=cleaned
                    end
                end
                return oldNamecall(remote,"FireServer",table.unpack(fireArgs))
            end
        end
        return oldNamecall(self,...)
    end)

    hookmetamethod(game,"__index",function(self,key)
        if not checkcaller() then
            if SpoofedItems[key] then
                local parent=self
                if parent==player.Backpack or parent==player.Character then
                    if not FakeCache[key] then
                        local ft=Instance.new("Tool"); ft.Name=key; FakeCache[key]=ft
                    end
                    return FakeCache[key]
                end
            end
        end
        return oldIndex(self,key)
    end)
end

-- ============================================================
-- GLOBAL RAE API
-- ============================================================
_G.RAE_Engine = {
    Scan   = RAE_Scan,
    Plan   = RAE_Plan,
    Commit = RAE_Commit,
    State  = RAE_State,
    ETM    = ETM,
    CDG    = CDG,
    LWM    = LWM,
    Intel  = Intel,
    StateSignature = StateSignature,
    SaveSession    = SaveSession,
    LoadSession    = LoadSession,
    ComputeBrierScore = ComputeBrierScore,
}

-- ============================================================
-- SESSION LOAD + AUTO-START
-- ============================================================
-- Restore any previously learned state from _G
LoadSession()

-- Boot scan: fires 3 seconds after character is available
local function bootRAE()
    task.wait(3)
    RAE_SilentMode=true
    if RAE_Scan() then
        task.wait(0.5)
        local plan=RAE_Plan()
        if plan and #plan>0 then
            task.wait(0.5)
            local log=RAE_Commit()
            RAE_SilentMode=false
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Boot complete — %d cards, %d/%d passed.",#RAE_State.Cards,p,#log),"Success")
            end
        else RAE_SilentMode=false; sendNotification("Boot scan complete. No plan generated.","Info") end
    else RAE_SilentMode=false; sendNotification("Boot scan — insufficient confidence.","Warning") end
end

if player.Character then task.spawn(bootRAE)
else player.CharacterAdded:Connect(function() task.spawn(bootRAE) end) end

-- END OF SCRIPT
