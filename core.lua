--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   Paper & Clay  +  RAE — Recursive Autonomous Engine  v2.0          ║
    ║   Deep Intelligence Edition                                          ║
    ║                                                                      ║
    ║   NEW IN v3.0:                                                       ║
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
-- ============================================================
-- MASTER SEMANTIC CLASSIFICATION TABLE (v3 — 18 categories)
-- Shared by RAE card genesis, Discovery trust vectors, and
-- the PayloadForge Analyzer. Single source of truth.
-- ============================================================
local SEMANTIC_TAGS = {
    Identity = {
        "kick","ban","admin","rank","user","target","role","debug","execute","run","mod",
        "sudo","su","root","op","owner","creator","staff","supervisor","guard","police",
        "chief","boss","commander","overseer","auth","authenticate","login","signin","verify",
        "verification","whitelist","blacklist","permission","perms","privilege","privs","access",
        "clearance","is_dev","is_tester","qa","beta_tester",
    },
    Economy = {
        "addcoin","addcash","money","currency","cost","gems","coins","points","credits",
        "balance","gold","bux","robux","tix","creds","tokens","tickets","vbucks","ebucks",
        "diamonds","jewels","emerald","sapphire","ruby","pearl","silver","copper","bronze",
        "iron","plat","platinum","cash","bucks","bills","moula","wallet","bal","purse","funds",
        "wealth","capital","salary","paycheck","wages","income","ec","pc","gc","revenue",
    },
    State = {
        "isadmin","isvip","isdead","stunned","ragdoll","god","invincible",
    },
    Time = {
        "daily","claim","reward","cooldown","timer","stamp","elapsed",
    },
    AntiCheat = {
        "anti","detect","security","crash","log","watchdog","warden","shield","protect","defense",
        "safeguard","firewall","scan","monitor","tracker","flag","alert","warn","violation","cheat",
        "hack","exploit","inject","injector","hook","spy","telemetry","analytics","metrics","heartbeat",
        "ping","latency","chk","check_integrity","verify_client","tamper","memcheck",
    },
    Ambiguous = {
        "doaction","main","network","remote","sync","handler","event",
    },
    DataValidation = {
        "submit","update","equip","unequip","chat","msg",
    },
    Trade = {
        "trade","offer","accept","swap","exchange","trx","transaction","deal","barter","haggle",
        "decline","confirm","req",
    },
    Crafting = {
        "craft","recipe","forge","combine","brew","upgrade","anvil","smelt","cook","mix","blend",
        "assemble","dismantle","scrap","salvage","recycle","breakdown",
    },
    Quest = {
        "quest","mission","objective","task","progress","obj","goal","bounty","contract","errand",
        "chore","job","duty","milestone","achievement","badge","trophy","title","step","turnin",
    },
    Bank = {
        "bank","vault","deposit","withdraw","storage","stash","inv","bag","backpack","sack","pouch",
        "holding",
    },
    Loot = {
        "crate","box","case","spin","open","roll","rng","drop","seed","luck","chance",
        "gacha","pull","unbox","chest","safe","coffer","treasure","prize","gift","bonus","wheel",
        "jackpot","lottery","raffle","ticket_spin",
    },
    SaveLoad = {
        "save","load","syncdata","data","datastore","ds","db","database","sql","cache","memory",
        "profile","playerdata","pdata","usrdata","session","flush","dump","commit","fetch","push","override",
    },
    Purchase = {
        "buy","purchase","shop","checkout","basket","sell","vend","vendor","market","merchant","trader",
    },
    Physics = {
        "velocity","force","impulse","constraint","mass","size","scale","physics","vector","vel","accel",
        "push","weight","grav",
    },
    Combat = {
        "hit","damage","attack","shoot","projectile","bullet","impact","strike","melee","dmg","atk",
        "def","armor","hp","mana","mp","stamina","energy","sp","xp","exp","lvl","level","hitbox",
        "hurtbox","raycast","trace","proj","missile","arrow","swing","slash","stab","punch",
        "kill","slay","death","die","respawn","revive","crit","critical","bleed","poison","burn","freeze",
    },
    Movement = {
        "teleport","tp","move","position","cframe","warp","dash","blink","dodge","jump","fly","glide",
        "hover","pos","coord","loc","location","dest","destination",
    },
    Vehicles = {
        "seat","vehicle","car","drive","occupant","mount","ride","boat","plane",
    },
    Regions = {
        "zone","region","area","enter","leave","boundary","door","room","stage","map","world","realm",
        "bounds","portal","gate","transition",
    },
}

-- AntiCheat remotes are flagged as high-risk — forge treats them as caution signals
local ANTICHEAT_RISK_GATE = true

local function ClassifyRemote(name)
    local nl = name:lower()
    for tag, patterns in pairs(SEMANTIC_TAGS) do
        for _, p in ipairs(patterns) do
            if nl:find(p) then return tag end
        end
    end
    return "General"
end

-- Returns risk level for a given category (used by Forge Simulator)
local function CategoryRisk(category)
    if category == "AntiCheat"     then return "Critical" end
    if category == "Identity"      then return "High"     end
    if category == "DataValidation" or category == "SaveLoad" then return "Medium" end
    if category == "Economy"  or category == "Purchase" or category == "Bank"  then return "Medium" end
    if category == "Combat"   or category == "Physics"  or category == "Movement" then return "Low"  end
    return "Low"
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
            -- PR Bridge: protocol-derived fields injected by the PR layer.
            -- These are zero when PR is not loaded, non-zero once PR.Start() runs.
            -- Allows LWM temporal averages to track protocol knowledge growth.
            pr_periodic   = type(_G.PR_LWM_INJECT)=="table" and (_G.PR_LWM_INJECT.pr_periodic   or 0) or 0,
            pr_c2s        = type(_G.PR_LWM_INJECT)=="table" and (_G.PR_LWM_INJECT.pr_c2s        or 0) or 0,
            pr_s2c        = type(_G.PR_LWM_INJECT)=="table" and (_G.PR_LWM_INJECT.pr_s2c        or 0) or 0,
            pr_payloadRdy = type(_G.PR_LWM_INJECT)=="table" and (_G.PR_LWM_INJECT.pr_payloadRdy or 0) or 0,
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
-- ============================================================
-- CHUNK EXPORTS
-- ============================================================
_G.PC = {
    Players=Players, TweenService=TweenService, RunService=RunService,
    UserInputService=UserInputService, Lighting=Lighting, SoundService=SoundService,
    ReplicatedStorage=ReplicatedStorage, HttpService=HttpService,
    LogService=LogService, TextChatService=TextChatService, Workspace=Workspace,
    player=player, playerGui=playerGui, existing=existing,
    tween=tween, mk=mk, addCorner=addCorner, addStroke=addStroke,
    addShadow=addShadow, pulseClick=pulseClick, hookHover=hookHover,
    clickSound=clickSound, uiClickSound=uiClickSound,
    cleanTable=cleanTable, base64_decode=base64_decode,
    tryDecode=tryDecode, disassembleBytecode=disassembleBytecode,
    SEMANTIC_TAGS=SEMANTIC_TAGS, ANTICHEAT_RISK_GATE=ANTICHEAT_RISK_GATE,
    ClassifyRemote=ClassifyRemote, CategoryRisk=CategoryRisk,
    StateSignature=StateSignature,
    LWM=LWM, LWM_Buffer=LWM_Buffer, LWM_RemoteRegistry=LWM_RemoteRegistry, LWM_CFG=LWM_CFG,
    ETM=ETM, ETM_Table=ETM_Table, ETM_CFG=ETM_CFG,
    CDG=CDG, CDG_Table=CDG_Table,
    WorldState=WorldState, WS_CHUNK=WS_CHUNK, CaptureWorldState=CaptureWorldState,
    CardGenesis=CardGenesis, NewCard=NewCard,
    PreCondAlwaysTrue=PreCondAlwaysTrue, PreCondInstanceExists=PreCondInstanceExists,
    GenStructural=GenStructural, GenMetabolic=GenMetabolic, GenPhysics=GenPhysics,
    GenLatent=GenLatent, GenAgents=GenAgents, GenNetwork=GenNetwork,
    ValueWeights=ValueWeights, ValueHistory=ValueHistory,
    COST_SCORES=COST_SCORES, ValueSystem=ValueSystem, RISK_CFG=RISK_CFG,
    Intel=Intel, CFG_INTEL=CFG_INTEL, IntelMem=IntelMem,
    GetOrInitCard=GetOrInitCard, WelfordUpdate=WelfordUpdate,
    UpdatePosterior=UpdatePosterior, ThompsonScore=ThompsonScore,
    ComputeBrierScore=ComputeBrierScore,
    DynamicsTable=DynamicsTable, DynamicsModel=DynamicsModel,
    TransitionTable=TransitionTable, TransitionModel=TransitionModel,
    CausalOrder=CausalOrder, CausalReasons=CausalReasons, Executor=Executor,
    MCTSPlanner=MCTSPlanner,
    RAE_State=RAE_State, RAE_Callbacks=RAE_Callbacks,
    RAE_Scan=RAE_Scan, RAE_Plan=RAE_Plan, RAE_Commit=RAE_Commit,
    SaveSession=SaveSession, LoadSession=LoadSession,
    rae = { SilentMode = false },
}
