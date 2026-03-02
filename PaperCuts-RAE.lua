--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   Paper & Clay  +  RAE — Recursive Autonomous Engine                ║
    ║   Combined Edition                                                   ║
    ║                                                                      ║
    ║   UI:  Paper & Clay shell — soft material, responsive layout        ║
    ║   RAE: 7-layer autonomous engine embedded as live backend           ║
    ║                                                                      ║
    ║   Tabs:                                                              ║
    ║     Overview · Player · Camera · World · Discovery                  ║
    ║     RAE · Recursive · Bridge · Utilities · About                    ║
    ║                                                                      ║
    ║   RAE Architecture:                                                  ║
    ║     Foundation — WorldState(T): 6-layer formal state vector         ║
    ║     Layer 1    — Living Scan                                         ║
    ║     Layer 2    — Card Genesis: Executable hypotheses                ║
    ║     Layer 3    — Chain Executor: Fast path + Staged path            ║
    ║     Layer 4    — Intelligence v3: Thompson sampling + drift         ║
    ║     Layer 5    — Environment Dynamics: P(S_t+1 | S_t, A_t)         ║
    ║     Layer 6    — Multi-Objective Value: 6-axis vector               ║
    ║     Layer 7    — MCTS Planner: World-simulation rollouts            ║
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

-- Cleanup existing UI
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
                local bx=bit32.band(bit32.rshift(ins,16),0xFFFF)
                table.insert(out,string.format("[%04d] OP_%02d A:%-3d B:%-3d C:%-3d",j,op,a,b,c))
            end
        end
        return table.concat(out,"\n")
    end)
    return success and result or ("-- Parse Failed: "..tostring(result))
end

-- ============================================================
-- ██████╗  █████╗ ███████╗
-- ██╔══██╗██╔══██╗██╔════╝
-- ██████╔╝███████║█████╗
-- ██╔══██╗██╔══██║██╔══╝
-- ██║  ██║██║  ██║███████╗
-- ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
-- RECURSIVE AUTONOMOUS ENGINE — FULL EMBEDDED BACKEND
-- ============================================================

-- SHARED MATH: Beta Distribution Sampling
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

-- ── WORLD STATE ──────────────────────────────────────────────
-- ── WORLD STATE ──────────────────────────────────────────────
-- All heavy iteration is chunked: yields every CHUNK_SIZE instances
-- so the scan spreads across multiple frames instead of stalling one.
local WorldState = {}
local WS_CHUNK = 500  -- instances processed before yielding (larger = fewer interruptions)

local function CaptureWorldState()
    local T = os.clock()
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

    -- ── Layer 2: Object Graph (chunked) ──────────────────────
    -- We only track already-connected remotes on re-scans to avoid
    -- stacking duplicate OnClientEvent listeners.
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
        if #tags > 0 then
            table.insert(state.ObjectGraph.TaggedInstances, { Instance=obj, Name=obj.Name, Path=obj:GetFullName(), Tags=tags })
        end

        n = n + 1
        if n >= WS_CHUNK then n = 0; task.wait() end
    end

    -- ── Layer 3: Physics (chunked, Workspace only) ────────────
    -- Cap unanchored parts at 200 to avoid runaway scans in large worlds.
    local wsDesc = Workspace:GetDescendants()
    n = 0
    local physCap = 0
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
        n = n + 1
        if n >= WS_CHUNK then n = 0; task.wait() end
    end

    -- ── Layer 4: Agents (instant — small list) ────────────────
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
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

    -- ── Layer 5: Latent (shallow BFS, chunked) ────────────────
    -- Iterates only direct children of each parent up to depth 6.
    -- Reuses existing remote listener entries rather than reconnecting.
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
                        -- reuse existing listener entry if already tracking this remote
                        local existing = knownRemotes[child.Name]
                        if existing and existing.Instance == child then
                            table.insert(state.Latent.RemoteEvents, existing)
                        else
                            local entry = { Instance=child, Name=child.Name, Path=child:GetFullName(), FireCount=0, LastArgs=nil, LastFire=0 }
                            table.insert(state.Latent.RemoteEvents, entry)
                            child.OnClientEvent:Connect(function(...)
                                entry.FireCount=entry.FireCount+1
                                entry.LastArgs={...}
                                entry.LastFire=os.clock()
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
                    n = n + 1
                    if n >= WS_CHUNK then n = 0; task.wait() end
                end
            end
        end
    end

    -- ── Layer 6: Network (lightweight — no full iteration) ──
    state.Network.ReplicatedInstances = state.ObjectGraph.TotalInstances

    return state
end
WorldState.Capture = CaptureWorldState

-- ── CARD GENESIS ─────────────────────────────────────────────
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

-- ── Semantic keyword classifier for remote naming ─────────────
-- Priority order matters: more specific categories checked first
-- so "ban" hits Identity before Ambiguous, "buy" hits Purchase before Economy, etc.
local TRUST_VECTORS = {
    Identity = {
        "kick","ban","admin","rank","user","target","role","debug","execute","run","mod",
        "sudo","su","root","op","owner","creator","staff","supervisor","guard","police",
        "chief","boss","commander","overseer","auth","authenticate","login","signin","verify",
        "verification","whitelist","blacklist","permission","perms","privilege","privs","access",
        "clearance","is_dev","is_tester","qa","beta_tester",
    },
    AntiCheat = {
        "anti","detect","security","crash","log","watchdog","warden","shield","protect","defense",
        "safeguard","firewall","scan","monitor","tracker","flag","alert","warn","violation","cheat",
        "hack","exploit","inject","injector","hook","spy","telemetry","analytics","metrics","heartbeat",
        "ping","latency","chk","check_integrity","verify_client","tamper","memcheck",
    },
    SaveLoad = {
        "save","load","syncdata","data","datastore","ds","db","database","sql","cache","memory",
        "profile","playerdata","pdata","usrdata","session","flush","dump","commit","fetch","push","override",
    },
    Purchase = {
        "buy","purchase","shop","checkout","basket","sell","vend","vendor","market","merchant","trader",
    },
    Economy = {
        "addcoin","addcash","money","currency","cost","gems","coins","points","credits",
        "balance","gold","bux","robux","tix","creds","tokens","tickets","vbucks","ebucks",
        "diamonds","jewels","emerald","sapphire","ruby","pearl","silver","copper","bronze",
        "iron","plat","platinum","cash","bucks","bills","moula","wallet","bal","purse","funds",
        "wealth","capital","salary","paycheck","wages","income","ec","pc","gc",
    },
    Bank = {
        "bank","vault","deposit","withdraw","storage","stash","inv","bag","backpack","sack","pouch","holding",
    },
    Loot = {
        "crate","box","case","spin","unbox","open","roll","rng","drop","seed","random","luck","chance",
        "gacha","pull","chest","safe","coffer","treasure","prize","gift","bonus","wheel","jackpot",
        "lottery","raffle","ticket_spin",
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
        "quest","mission","objective","task","progress","q","obj","goal","bounty","contract","errand",
        "chore","job","duty","milestone","achievement","badge","trophy","title","step","turnin",
    },
    Combat = {
        "hit","damage","attack","shoot","projectile","bullet","impact","strike","melee","dmg","atk",
        "def","armor","hp","mana","mp","stamina","energy","sp","xp","exp","lvl","level","hitbox",
        "hurtbox","raycast","trace","proj","missile","arrow","swing","slash","stab","punch","kick",
        "kill","slay","fatality","death","die","respawn","revive","crit","critical","bleed","poison","burn","freeze",
    },
    Movement = {
        "teleport","tp","move","position","cframe","warp","dash","blink","dodge","jump","fly","glide",
        "hover","pos","coord","loc","location","dest","destination",
    },
    Physics = {
        "velocity","force","impulse","constraint","mass","size","scale","physics","vector","vel","accel",
        "push","weight","grav",
    },
    Vehicles = {
        "seat","vehicle","car","drive","occupant","mount","ride","boat","plane",
    },
    Regions = {
        "zone","region","area","enter","leave","boundary","door","room","stage","map","world","realm",
        "bounds","portal","gate","transition",
    },
    State = {
        "isadmin","isvip","isdead","stunned","ragdoll","god","invincible",
    },
    Time = {
        "daily","claim","reward","cooldown","timer","stamp","elapsed",
    },
    DataValidation = {
        "submit","update","equip","unequip","chat","msg",
    },
    Ambiguous = {
        "doaction","main","network","remote","sync","handler","event",
    },
}

-- Priority list: checked in order so specific categories win over broad ones
local TRUST_PRIORITY = {
    "Identity","AntiCheat","SaveLoad","Purchase","Economy","Bank","Loot","Trade",
    "Crafting","Quest","Combat","Movement","Physics","Vehicles","Regions",
    "State","Time","DataValidation","Ambiguous",
}

local function ClassifyRemote(name)
    local nl = name:lower()
    for _, category in ipairs(TRUST_PRIORITY) do
        for _, pattern in ipairs(TRUST_VECTORS[category]) do
            if nl:find(pattern, 1, true) then  -- plain find (no Lua patterns), faster and safer
                return category
            end
        end
    end
    return "General"
end

-- ── CARD GENESIS — STRUCTURAL ─────────────────────────────────
local function GenStructural(ws, cards)
    local og = ws.ObjectGraph
    if not og or og.TotalInstances == 0 then return end

    -- Architecture profile: reads and caches — no side effects
    table.insert(cards, NewCard("Structural", "Architecture Profile",
        string.format("%d instances | %d scripts (%d enabled, %d disabled)",
            og.TotalInstances, og.ScriptCount, og.EnabledScripts, og.DisabledScripts),
        {PreCondAlwaysTrue},
        function(outputs)
            outputs = outputs or {}
            outputs["Structural"] = {
                TotalInstances = og.TotalInstances,
                ScriptCount    = og.ScriptCount,
                EnabledScripts = og.EnabledScripts,
            }
            return outputs["Structural"]
        end,
        "Caches architectural context for downstream cards.",
        {CPU="low", Network="none", Disruption="none"},
        {Risk="None", Confidence=100}))

    -- Tagged instance map: builds a lookup by tag name for other cards to use
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
            function(outputs)
                outputs = outputs or {}
                outputs["TagMap"] = tagMap
                return tagMap
            end,
            "Builds tag-keyed lookup table for spatial and semantic targeting.",
            {CPU="low", Network="none", Disruption="none"},
            {Risk="None", Confidence=95}))
    end
end

-- ── CARD GENESIS — METABOLIC ──────────────────────────────────
local function GenMetabolic(ws, cards)
    local sc = ws.SimConfig
    if not sc then return end

    -- Gravity probe: reads current gravity and checks if it can be changed client-side
    table.insert(cards, NewCard("Metabolic", "Simulation Config Snapshot",
        string.format("Gravity:%.1f | Streaming:%s | ServerTime:%.2f",
            sc.Gravity, tostring(sc.StreamingEnabled), sc.ServerTime),
        {PreCondAlwaysTrue},
        function(outputs)
            local currentGravity = Workspace.Gravity
            local currentTime    = Workspace:GetServerTimeNow()
            outputs = outputs or {}
            outputs["Metabolic"] = {
                Gravity     = currentGravity,
                ServerTime  = currentTime,
                Streaming   = sc.StreamingEnabled,
            }
            return outputs["Metabolic"]
        end,
        "Captures live physics config as context for physics and network cards.",
        {CPU="none", Network="none", Disruption="none"},
        {Risk="None", Confidence=100}))
end

-- ── CARD GENESIS — PHYSICS ────────────────────────────────────
local function GenPhysics(ws, cards)
    local phys = ws.Physics
    if not phys then return end

    -- Client-owned parts: actually apply velocity influence
    for _, entry in ipairs(phys.ClientOwned or {}) do
        local inst = entry.Instance
        table.insert(cards, NewCard("Ownership", "Velocity Influence: " .. entry.Name,
            string.format("Client owns '%s' | Mass:%.1f | Vel:%.2f | %s",
                entry.Name, entry.Mass, entry.Velocity.Magnitude,
                entry.Mass > 50 and "Heavy — momentum carrier" or "Light — high maneuverability"),
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    -- Read current state
                    local vel  = inst.AssemblyLinearVelocity
                    local cf   = inst.CFrame
                    local mass = inst.AssemblyMass

                    -- Apply influence: dampen extreme velocities, boost low ones
                    local speed = vel.Magnitude
                    local newVel
                    if speed > 100 then
                        -- Dampen runaway velocity
                        newVel = vel.Unit * 80
                        inst.AssemblyLinearVelocity = newVel
                    elseif speed < 1 then
                        -- Give stationary parts a small directional nudge aligned to local up
                        newVel = Vector3.new(0, 5, 0)
                        inst.AssemblyLinearVelocity = newVel
                    else
                        newVel = vel  -- already in healthy range, just snapshot
                    end

                    return {
                        Part       = inst.Name,
                        Mass       = mass,
                        VelBefore  = speed,
                        VelAfter   = newVel.Magnitude,
                        CFrame     = cf,
                        Applied    = speed > 100 or speed < 1,
                    }
                end)
                if ok then return result
                else return {Error = tostring(result), Part = inst.Name} end
            end,
            "Applies velocity normalization to client-owned part. Dampens runaway, nudges stationary.",
            {CPU="medium", Network="low", Disruption="medium"},
            {Risk="Medium", Confidence=80, Instance=inst, Path=entry.Path}))
    end

    -- Server-owned boundary: builds a spatial index for targeting
    if #phys.ServerOwned > 3 then
        table.insert(cards, NewCard("Ownership", "Server Physics Index",
            string.format("%d server-simulated parts. Spatial index available.", #phys.ServerOwned),
            {PreCondAlwaysTrue},
            function(outputs)
                -- Build a spatial bucket index (16-stud cells)
                local buckets = {}
                for _, entry in ipairs(phys.ServerOwned) do
                    local pos = entry.CFrame.Position
                    local key = string.format("%d,%d,%d",
                        math.floor(pos.X/16), math.floor(pos.Y/16), math.floor(pos.Z/16))
                    if not buckets[key] then buckets[key] = {} end
                    table.insert(buckets[key], entry.Name)
                end
                outputs = outputs or {}
                outputs["PhysicsIndex"] = buckets
                return {BucketCount = (function() local n=0; for _ in pairs(buckets) do n=n+1 end; return n end)(), Buckets = buckets}
            end,
            "Builds spatial bucket index of server parts for proximity reasoning.",
            {CPU="low", Network="none", Disruption="none"},
            {Risk="None", Confidence=80}))
    end
end

-- ── CARD GENESIS — LATENT (REMOTES + STATE) ───────────────────
local function GenLatent(ws, cards)
    local lat = ws.Latent
    if not lat then return end

    -- RemoteEvents: generate one card per remote with full action logic
    for _, remote in ipairs(lat.RemoteEvents or {}) do
        local inst     = remote.Instance
        local observed = remote.FireCount > 0
        local semantic = ClassifyRemote(remote.Name)
        local conf     = observed and math.min(50 + remote.FireCount * 10, 90) or 35

        table.insert(cards, NewCard("Replication",
            string.format("[%s] %s", semantic, remote.Name),
            observed
                and string.format("Observed %d fires. Last args: %s. Replay ready.",
                    remote.FireCount,
                    remote.LastArgs and HttpService:JSONEncode(
                        (function()
                            local safe = {}
                            for i, v in ipairs(remote.LastArgs) do
                                safe[i] = type(v) == "table" and "[table]"
                                       or type(v) == "userdata" and "[instance]"
                                       or tostring(v)
                            end
                            return safe
                        end)()) or "nil")
                or "Not yet observed. Probe-fire will attempt silent activation.",
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    if observed and remote.LastArgs and #remote.LastArgs > 0 then
                        -- Replay with captured argument types, substituting safe values
                        -- where instance refs may have become stale
                        local safeArgs = {}
                        for i, arg in ipairs(remote.LastArgs) do
                            local t = type(arg)
                            if t == "number" or t == "string" or t == "boolean" then
                                table.insert(safeArgs, arg)
                            elseif t == "userdata" then
                                -- Try to re-resolve by name within ReplicatedStorage/Workspace
                                local ok2, resolved = pcall(function()
                                    return ReplicatedStorage:FindFirstChild(arg.Name, true)
                                        or Workspace:FindFirstChild(arg.Name, true)
                                end)
                                table.insert(safeArgs, ok2 and resolved or arg)
                            else
                                table.insert(safeArgs, arg)
                            end
                        end
                        inst:FireServer(unpack(safeArgs))
                        return {
                            Action   = "Replay",
                            Remote   = remote.Name,
                            ArgCount = #safeArgs,
                            Semantic = semantic,
                        }
                    else
                        -- Probe fire: no args, maps server response
                        inst:FireServer()
                        return {
                            Action   = "Probe",
                            Remote   = remote.Name,
                            ArgCount = 0,
                            Semantic = semantic,
                        }
                    end
                end)
                return ok and result or {Error = tostring(result), Remote = remote.Name}
            end,
            observed and "Replay captured args at server." or "Probe-fire to map server behavior.",
            {CPU="low", Network= observed and "medium" or "low", Disruption= observed and "medium" or "low"},
            {Risk= observed and "Medium" or "Low", Confidence=conf,
             Semantic=semantic, Observed=observed, FireCount=remote.FireCount}))
    end

    -- RemoteFunctions: invoke and capture return value
    for _, rfunc in ipairs(lat.RemoteFunctions or {}) do
        local inst     = rfunc.Instance
        local semantic = ClassifyRemote(rfunc.Name)
        table.insert(cards, NewCard("Replication",
            string.format("[Fn:%s] %s", semantic, rfunc.Name),
            "RemoteFunction — InvokeServer will capture return value.",
            {PreCondInstanceExists(inst)},
            function(outputs)
                local ok, result = pcall(function()
                    local ret = inst:InvokeServer()
                    local retStr
                    if type(ret) == "table" then
                        local s, j = pcall(function() return HttpService:JSONEncode(ret) end)
                        retStr = s and j or "[table]"
                    else
                        retStr = tostring(ret)
                    end
                    outputs = outputs or {}
                    outputs["RF_"..rfunc.Name] = ret
                    return {
                        Action   = "Invoke",
                        Remote   = rfunc.Name,
                        Return   = retStr,
                        Semantic = semantic,
                    }
                end)
                return ok and result or {Error = tostring(result), Remote = rfunc.Name}
            end,
            "Invokes RemoteFunction and captures server return value.",
            {CPU="low", Network="medium", Disruption="low"},
            {Risk="Low", Confidence=45, Semantic=semantic}))
    end

    -- Value objects: read live values and detect changes from last scan
    if #lat.ValueObjects > 0 then
        table.insert(cards, NewCard("Latent", "Live Value State",
            string.format("%d value objects — live read.", #lat.ValueObjects),
            {PreCondAlwaysTrue},
            function(outputs)
                local snapshot = {}
                for _, vo in ipairs(lat.ValueObjects) do
                    local ok, current = pcall(function()
                        local inst = game:FindFirstChild(vo.Name, true)
                        return inst and inst.Value or vo.Value
                    end)
                    snapshot[vo.Name] = {
                        Path    = vo.Path,
                        Class   = vo.Class,
                        Cached  = vo.Value,
                        Current = ok and current or vo.Value,
                        Drifted = ok and (current ~= vo.Value),
                    }
                end
                outputs = outputs or {}
                outputs["ValueState"] = snapshot
                return snapshot
            end,
            "Reads all value objects live and flags any that drifted since scan.",
            {CPU="low", Network="none", Disruption="none"},
            {Risk="None", Confidence=90}))
    end

    -- Match state: read and interpret game phase variables
    local mc = 0; for _ in pairs(lat.MatchState) do mc = mc + 1 end
    if mc > 0 then
        table.insert(cards, NewCard("Latent", "Match Phase Read",
            string.format("%d match/game state variables — live interpretation.", mc),
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
                    phases[name] = {
                        Value  = ok and val or "unreadable",
                        Class  = entry.Class,
                        Active = ok and val ~= 0 and val ~= false and val ~= "" and val ~= nil,
                    }
                end
                outputs = outputs or {}
                outputs["MatchPhase"] = phases
                return phases
            end,
            "Reads all match/game-phase variables live. Flags active phases.",
            {CPU="low", Network="none", Disruption="none"},
            {Risk="None", Confidence=85}))
    end

    -- Economy surface: catches Economy, Purchase, Bank, and Loot remotes
    local economyRemotes = {}
    local ECONOMY_CATEGORIES = { Economy=true, Purchase=true, Bank=true, Loot=true }
    for _, remote in ipairs(lat.RemoteEvents or {}) do
        if ECONOMY_CATEGORIES[ClassifyRemote(remote.Name)] then
            table.insert(economyRemotes, remote)
        end
    end
    if #economyRemotes > 0 then
        table.insert(cards, NewCard("Latent", "Economy Surface Detected",
            string.format("%d economy-tagged remotes found: %s",
                #economyRemotes,
                table.concat((function()
                    local names = {}
                    for _, r in ipairs(economyRemotes) do table.insert(names, r.Name) end
                    return names
                end)(), ", ")),
            {PreCondAlwaysTrue},
            function(outputs)
                -- Fire each economy remote with its captured args or probe
                local results = {}
                for _, remote in ipairs(economyRemotes) do
                    local ok, r = pcall(function()
                        if remote.LastArgs and #remote.LastArgs > 0 then
                            remote.Instance:FireServer(unpack(remote.LastArgs))
                            return {Remote=remote.Name, Action="Replay", Args=#remote.LastArgs}
                        else
                            remote.Instance:FireServer()
                            return {Remote=remote.Name, Action="Probe"}
                        end
                    end)
                    table.insert(results, ok and r or {Remote=remote.Name, Error=tostring(r)})
                    task.wait(0.05)
                end
                outputs = outputs or {}
                outputs["EconomyResult"] = results
                return results
            end,
            "Fires all economy-tagged remotes with captured or probe args.",
            {CPU="low", Network="high", Disruption="high"},
            {Risk="High", Confidence=60, EconomyCount=#economyRemotes}))
    end
end

-- ── CARD GENESIS — AGENTS ─────────────────────────────────────
local function GenAgents(ws, cards)
    local agents = ws.Agents
    if not agents or not agents.LocalPlayer then return end
    local lp = agents.LocalPlayer

    -- Local player state: reads AND pushes persistent settings
    table.insert(cards, NewCard("Agent", "Local Player Sync",
        string.format("%s | HP:%.0f/%.0f | Speed:%.1f | Jump:%.1f | Tool:%s",
            lp.Name, lp.Health, lp.MaxHealth, lp.WalkSpeed, lp.JumpPower,
            lp.EquippedTool or "none"),
        {PreCondAlwaysTrue},
        function(outputs)
            local char = Players.LocalPlayer.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then return {Error="No humanoid found."} end

            -- Re-apply persistent movement settings in case they were reset
            local applied = {}
            if persistent.WalkSpeed and hum.WalkSpeed ~= persistent.WalkSpeed then
                pcall(function() hum.WalkSpeed = persistent.WalkSpeed end)
                table.insert(applied, "WalkSpeed→"..persistent.WalkSpeed)
            end
            if persistent.JumpPower and hum.JumpPower ~= persistent.JumpPower then
                pcall(function() hum.JumpPower = persistent.JumpPower end)
                table.insert(applied, "JumpPower→"..persistent.JumpPower)
            end

            -- Snapshot current state
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local snapshot = {
                Name       = Players.LocalPlayer.Name,
                Health     = hum.Health,
                MaxHealth  = hum.MaxHealth,
                WalkSpeed  = hum.WalkSpeed,
                JumpPower  = hum.JumpPower,
                HumState   = tostring(hum:GetState()),
                Position   = hrp and hrp.Position or Vector3.new(),
                Applied    = applied,
            }
            outputs = outputs or {}
            outputs["AgentState"] = snapshot
            return snapshot
        end,
        "Snapshots local player state and re-applies persistent movement settings if drifted.",
        {CPU="none", Network="none", Disruption="none"},
        {Risk="None", Confidence=100}))

    -- Character physics: reads HRP position and velocity for spatial reasoning
    if lp.Health > 0 then
        table.insert(cards, NewCard("Agent", "Spatial Context",
            "Local character position and velocity available for spatial reasoning.",
            {PreCondAlwaysTrue},
            function(outputs)
                local char = Players.LocalPlayer.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if not hrp then return {Error="HumanoidRootPart not found."} end

                local pos = hrp.Position
                local vel = hrp.AssemblyLinearVelocity

                -- Build proximity map: distances to all other players
                local proximity = {}
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= Players.LocalPlayer and p.Character then
                        local otherHRP = p.Character:FindFirstChild("HumanoidRootPart")
                        if otherHRP then
                            table.insert(proximity, {
                                Name = p.Name,
                                Dist = (otherHRP.Position - pos).Magnitude,
                            })
                        end
                    end
                end
                table.sort(proximity, function(a, b) return a.Dist < b.Dist end)

                local result = {
                    Position  = pos,
                    Velocity  = vel,
                    Speed     = vel.Magnitude,
                    Proximity = proximity,
                    Grounded  = (function()
                        local hum = char:FindFirstChildOfClass("Humanoid")
                        return hum and hum:GetState() == Enum.HumanoidStateType.Running
                    end)(),
                }
                outputs = outputs or {}
                outputs["SpatialContext"] = result
                return result
            end,
            "Builds spatial context: local position, velocity, and proximity to all players.",
            {CPU="low", Network="none", Disruption="none"},
            {Risk="None", Confidence=95}))

        -- Tool activation: if player has a tool equipped, actually activate it
        if lp.EquippedTool then
            table.insert(cards, NewCard("Agent", "Activate Tool: " .. lp.EquippedTool,
                string.format("Tool '%s' equipped. Activation available.", lp.EquippedTool),
                {PreCondAlwaysTrue},
                function(outputs)
                    local char = Players.LocalPlayer.Character
                    local tool = char and char:FindFirstChildOfClass("Tool")
                    if not tool then return {Error="Tool no longer equipped."} end

                    -- Fire the tool's Activated event client-side
                    local activated = false
                    local ok = pcall(function()
                        tool:Activate()
                        activated = true
                    end)
                    if not ok then
                        -- Fallback: find and fire the Handle's touch directly
                        local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
                        if handle then
                            -- just record it as available
                            activated = false
                        end
                    end

                    return {
                        Tool      = tool.Name,
                        Activated = activated,
                        Handle    = tool:FindFirstChild("Handle") ~= nil,
                    }
                end,
                "Activates currently equipped tool.",
                {CPU="low", Network="medium", Disruption="medium"},
                {Risk="Medium", Confidence=70, ToolName=lp.EquippedTool}))
        end
    end

    -- Nearby players: proximity tracking with live distance
    for _, other in ipairs(agents.OtherPlayers or {}) do
        if lp.CFrame then
            local dist = (other.CFrame.Position - lp.CFrame.Position).Magnitude
            if dist < 60 then
                table.insert(cards, NewCard("Agent", "Track: " .. other.Name,
                    string.format("%s | HP:%.0f/%.0f | Dist:%.1fm",
                        other.Name, other.Health, other.MaxHealth, dist),
                    {PreCondAlwaysTrue},
                    function(outputs)
                        -- Get live position
                        local targetPlayer = Players:FindFirstChild(other.Name)
                        local targetChar   = targetPlayer and targetPlayer.Character
                        local targetHRP    = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
                        local targetHum    = targetChar and targetChar:FindFirstChildOfClass("Humanoid")

                        local myChar = Players.LocalPlayer.Character
                        local myHRP  = myChar and myChar:FindFirstChild("HumanoidRootPart")

                        local liveDist = (targetHRP and myHRP)
                            and (targetHRP.Position - myHRP.Position).Magnitude
                            or dist

                        local result = {
                            Name      = other.Name,
                            Health    = targetHum and targetHum.Health or other.Health,
                            MaxHealth = targetHum and targetHum.MaxHealth or other.MaxHealth,
                            Distance  = liveDist,
                            Position  = targetHRP and targetHRP.Position or other.CFrame.Position,
                            Alive     = (targetHum and targetHum.Health > 0) or other.Health > 0,
                            Approach  = liveDist < 20 and "Close" or liveDist < 50 and "Mid" or "Far",
                        }
                        outputs = outputs or {}
                        if not outputs["TrackedPlayers"] then outputs["TrackedPlayers"] = {} end
                        outputs["TrackedPlayers"][other.Name] = result
                        return result
                    end,
                    "Tracks player live — updates position, health, and approach zone.",
                    {CPU="low", Network="none", Disruption="none"},
                    {Risk="None", Confidence=80, TargetName=other.Name}))
            end
        end
    end
end

-- ── CARD GENESIS — NETWORK ────────────────────────────────────
local function GenNetwork(ws, cards)
    -- Generate a network surface summary using what we already know from remotes
    local lat = ws.Latent
    if not lat then return end
    local evCount  = #(lat.RemoteEvents or {})
    local fnCount  = #(lat.RemoteFunctions or {})
    local observed = 0
    for _, r in ipairs(lat.RemoteEvents or {}) do if r.FireCount > 0 then observed = observed + 1 end end

    if evCount + fnCount > 0 then
        table.insert(cards, NewCard("Network", "Network Surface Map",
            string.format("%d events (%d observed) | %d functions — surface mapped.",
                evCount, observed, fnCount),
            {PreCondAlwaysTrue},
            function(outputs)
                local surface = {
                    Events    = evCount,
                    Functions = fnCount,
                    Observed  = observed,
                    Coverage  = math.floor(observed / math.max(evCount, 1) * 100),
                }
                outputs = outputs or {}
                outputs["NetworkSurface"] = surface
                return surface
            end,
            "Summarizes known network surface. Coverage = observed/total events.",
            {CPU="none", Network="none", Disruption="none"},
            {Risk="None", Confidence=95}))
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

-- ── MULTI-OBJECTIVE VALUE SYSTEM ─────────────────────────────
local ValueWeights = { Reliability=1.0, InformationGain=0.8, Cost=0.7, Reversibility=0.9, Optionality=0.7, Stability=0.8 }
local ValueHistory = { WeightUpdates=0 }
local COST_SCORES = { none=1.0, low=0.85, medium=0.65, high=0.40 }

local ValueSystem = {}
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
    local downstream=0; for _, o in ipairs(allCards) do if o.Channel~=card.Channel then downstream=downstream+1 end end
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

-- ── COGNITIVE INTELLIGENCE v3 ─────────────────────────────────
local Intel = {}
local CFG_INTEL = { MemoryDecayRate=0.88, PhaseShiftThreshold=0.25, OverfitDetectionWindow=4, VariancePenaltyCoeff=0.35 }
local IntelMem = {
    CardHistory={}, ChannelTimeseries={ Structural={},Metabolic={},Ownership={},Replication={},Latent={},Agent={},Network={} },
    ChannelWeights={ Structural=1.0,Metabolic=1.0,Ownership=1.0,Replication=1.0,Latent=1.0,Agent=1.0,Network=1.0 },
    FailureHeuristics={}, CalibrationLog={}, PhaseShifts={}, OverfitStreak=0, Cycles=0,
}

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

local function ThompsonScore(card, h)
    local sample=SampleBeta(math.max(h.alpha,0.1),math.max(h.beta,0.1))
    local vp=h.StdDev*CFG_INTEL.VariancePenaltyCoeff
    local cw=IntelMem.ChannelWeights[card.Channel] or 1.0
    local pd=1.0
    for _, s in ipairs(IntelMem.PhaseShifts) do if s.Channel==card.Channel and IntelMem.Cycles-s.Cycle<=2 then pd=0.75; break end end
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
    for _, r in ipairs(log) do
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
    for _, r in ipairs(log) do
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
        -- Phase shift
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
    for _, r in ipairs(log) do if ((r.Step.Metadata.Confidence or 50)>=60)~=r.Success then allCorrect=false; break end end
    IntelMem.OverfitStreak=allCorrect and IntelMem.OverfitStreak+1 or 0
    if IntelMem.OverfitStreak>=CFG_INTEL.OverfitDetectionWindow then IntelMem.OverfitStreak=0 end
end

function Intel.GetMemory() return IntelMem end

-- ── DYNAMICS MODEL ────────────────────────────────────────────
local DynamicsTable={}
local DynamicsModel={}

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

-- ── TRANSITION MODEL ─────────────────────────────────────────
local TransitionTable={}
local TransitionModel={}

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

-- ── CHAIN EXECUTOR ────────────────────────────────────────────
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
    for _, pre in ipairs(card.Preconditions or {}) do
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
    local chain=ResolveDeps(selected, all)
    if IsHighStakes(chain) then return ExecuteStagedPath(chain, ws)
    else return ExecuteFastPath(chain, ws) end
end

function Executor.Preview(selected, all)
    local chain=ResolveDeps(selected, all)
    local staged=IsHighStakes(chain)
    return chain, staged
end

-- ── MCTS PLANNER ─────────────────────────────────────────────
local MCTS_CFG={ Simulations=200, MaxDepth=6, UCB_C=1.41, MinCardConf=0.20 }

local function NewNode(card, parent, depth)
    return {Card=card,Parent=parent,Children={},Depth=depth,Visits=0,TotalReward=0.0,MeanReward=0.0}
end

local function UCB1(node, parentVisits)
    if node.Visits==0 then return math.huge end
    return node.MeanReward + MCTS_CFG.UCB_C * math.sqrt(math.log(parentVisits)/node.Visits)
end

local function Rollout(startNode, viable, allCards, intelHistory, maxDepth)
    local chain={}; local prevCard=startNode.Card; local prevSucc=true; local depth=startNode.Depth
    local node=startNode; local nc={}
    while node do if node.Card then table.insert(nc,1,{Card=node.Card,Success=true}) end; node=node.Parent end
    for _,s in ipairs(nc) do table.insert(chain,s) end
    while depth<maxDepth do
        if #viable==0 then break end
        local nextCard=viable[math.random(#viable)]
        local succProb=TransitionModel.Sample(prevCard.ID, nextCard.ID, prevSucc)
        local dynRate=DynamicsModel.GetSuccessRate(nextCard.ID)
        if dynRate~=0.5 then succProb=(succProb+dynRate)/2 end
        local simSucc=math.random()<succProb
        table.insert(chain, {Card=nextCard,Success=simSucc})
        prevCard=nextCard; prevSucc=simSucc; depth=depth+1
    end
    return ValueSystem.ScoreChain(chain, allCards, intelHistory), chain
end

local Planner={}
function Planner.Plan(availableCards, lastLog, intelHistory)
    if lastLog and #lastLog>0 then TransitionModel.Update(lastLog) end
    local viable={}
    for _,card in ipairs(availableCards) do
        if (card.Metadata.Confidence or 50)/100>=MCTS_CFG.MinCardConf then table.insert(viable, card) end
    end
    if #viable==0 then return nil end
    local root=NewNode(nil,nil,0)
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
        while back do back.Visits=back.Visits+1; back.TotalReward=back.TotalReward+reward; back.MeanReward=back.TotalReward/back.Visits; back=back.Parent end
    end
    local bestChain={}; local node=root; local depth=0
    while #node.Children>0 and depth<MCTS_CFG.MaxDepth do
        local best,bestR=nil,-math.huge
        for _,child in ipairs(node.Children) do if child.Visits>0 and child.MeanReward>bestR then bestR=child.MeanReward; best=child end end
        if not best then break end
        table.insert(bestChain, {Card=best.Card,ProjectedReward=best.MeanReward,Visits=best.Visits})
        node=best; depth=depth+1
    end
    return bestChain
end

-- ── RAE ENGINE STATE ─────────────────────────────────────────
local RAE_State = {
    Phase="DORMANT", WorldState=nil, Cards={}, SelectedCards={},
    LastLog=nil, LastPlan=nil, CycleCount=0, _IndexMap={},
}
local RAE_Callbacks  = { OnScan=nil, OnPlan=nil, OnCommit=nil, OnPhase=nil }
local RAE_SilentMode = false   -- true during autonomous background cycles

local function RAE_SetPhase(phase)
    RAE_State.Phase=phase
    if RAE_Callbacks.OnPhase then RAE_Callbacks.OnPhase(phase) end
end

local function RAE_Scan()
    RAE_SetPhase("SCANNING")
    local ws=WorldState.Capture()
    RAE_State.WorldState=ws
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
    local wsBefore=RAE_State.WorldState
    local log=Executor.Execute(RAE_State.SelectedCards, RAE_State.Cards, wsBefore)
    local wsAfter=WorldState.Capture()
    for _,r in ipairs(log) do DynamicsModel.Record(r.Step.ID, wsBefore, wsAfter, r.Success) end
    RAE_State.LastLog=log; RAE_State.CycleCount=RAE_State.CycleCount+1; RAE_State.SelectedCards={}
    Intel.ProcessFeedback(log, RAE_State.Cards)
    TransitionModel.Update(log)
    ValueSystem.AdaptWeights(log, RAE_State.Cards)
    RAE_SetPhase("COMPLETE"); RAE_SetPhase("READY")
    if RAE_Callbacks.OnCommit then RAE_Callbacks.OnCommit(log) end
    return log
end

-- ============================================================
-- UI ROOT
-- ============================================================
local screenGui = mk("ScreenGui", {
    Name="PaperClayUI", ResetOnSpawn=false, IgnoreGuiInset=true,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, Parent=playerGui,
})
local root = mk("Frame", { Name="Root", BackgroundTransparency=1, Size=UDim2.new(1,0,1,0), Parent=screenGui })

-- ── Window ───────────────────────────────────────────────────
local window = mk("Frame", {
    Name="Window", BackgroundColor3=Color3.fromRGB(250,247,242), BorderSizePixel=0,
    AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,960,0,580),
    ZIndex=10, Parent=root,
})
addCorner(window, UDim.new(0,18)); addStroke(window,1,0.22); addShadow(window,10)
mk("UISizeConstraint", {MinSize=Vector2.new(720,440),MaxSize=Vector2.new(1200,820),Parent=window})
mk("UIGradient", {Rotation=90,Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(252,249,245)),ColorSequenceKeypoint.new(1,Color3.fromRGB(246,241,234))}),Parent=window})

-- ── Notification Engine ──────────────────────────────────────
local notifContainer = mk("Frame", {
    Name="NotifContainer", BackgroundTransparency=1,
    AnchorPoint=Vector2.new(1,0), Position=UDim2.new(1,-16,0,64),
    Size=UDim2.new(0,260,1,-80), ZIndex=100, Parent=window,
})
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
    task.delay(3.5,function()
        if toast and toast.Parent then
            tween(toast,TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.In),{BackgroundTransparency=1,Position=UDim2.new(0,50,0,0)})
            tween(strk,TweenInfo.new(0.25),{Transparency=1}); tween(iLabel,TweenInfo.new(0.25),{TextTransparency=1}); tween(tLabel,TweenInfo.new(0.25),{TextTransparency=1})
            task.delay(0.25,function() if toast then toast:Destroy() end end)
        end
    end)
end

-- ── RAE Phase → Notification (suppressed in silent/autonomous mode) ──
RAE_Callbacks.OnPhase = function(phase)
    if RAE_SilentMode then return end
    if phase=="SCANNING" then sendNotification("RAE: Scanning WorldState...", "Info")
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

-- ── UI Components ─────────────────────────────────────────────
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

local function makeRemoteInput(parent, placeholderText)
    local container=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,32),AutomaticSize=Enum.AutomaticSize.Y,Parent=parent})
    local tb=mk("TextBox",{Text="",PlaceholderText=placeholderText,BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,-40,0,32),Font=Enum.Font.GothamMedium,TextSize=14,Parent=container})
    addCorner(tb,UDim.new(0,8)); addStroke(tb,1,0.3)
    local ddBtn=mk("TextButton",{Text="▼",BackgroundColor3=Color3.fromRGB(240,235,230),Size=UDim2.new(0,36,0,32),Position=UDim2.new(1,-36,0,0),Font=Enum.Font.GothamBold,TextColor3=Color3.fromRGB(100,100,100),TextSize=14,Parent=container})
    addCorner(ddBtn,UDim.new(0,8)); addStroke(ddBtn,1,0.3)
    local listHolder=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(250,247,242),BorderSizePixel=0,Size=UDim2.new(1,0,0,140),Position=UDim2.new(0,0,0,36),AutomaticCanvasSize=Enum.AutomaticSize.Y,CanvasSize=UDim2.new(0,0,0,0),ScrollBarThickness=4,Visible=false,ZIndex=5,Parent=container})
    addCorner(listHolder,UDim.new(0,8)); addStroke(listHolder,1,0.4)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=listHolder})
    mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=listHolder})
    local isOpen=false
    ddBtn.MouseButton1Click:Connect(function()
        clickSound(); isOpen=not isOpen; listHolder.Visible=isOpen; ddBtn.Text=isOpen and "▲" or "▼"
        if isOpen then
            listHolder:ClearAllChildren()
            mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=listHolder})
            mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=listHolder})
            local fc=0
            for _,rootObj in ipairs({ReplicatedStorage,Workspace}) do
                for _,v in ipairs(rootObj:GetDescendants()) do
                    if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
                        fc=fc+1
                        local rb=mk("TextButton",{Text="  "..v.Name.." ("..v.ClassName:sub(7)..")",BackgroundTransparency=1,Size=UDim2.new(1,0,0,26),Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(60,60,60),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,Parent=listHolder})
                        hookHover(rb,Color3.fromRGB(250,247,242),Color3.fromRGB(230,225,220),1,1)
                        rb.MouseButton1Click:Connect(function() clickSound(); tb.Text=v.Name; isOpen=false; listHolder.Visible=false; ddBtn.Text="▼" end)
                    end
                end
            end
            if fc==0 then mk("TextLabel",{Text="No remotes found.",BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=listHolder}) end
        end
    end)
    return tb
end

-- ── Character Helpers ─────────────────────────────────────────
local function getCharacter() return player.Character or player.CharacterAdded:Wait() end
local function getHumanoid() local ch=getCharacter(); return ch:FindFirstChildOfClass("Humanoid") or ch:WaitForChild("Humanoid",5) end
local function applyHumanoidSetting(field, value) local hum=getHumanoid(); if hum then pcall(function() hum[field]=value end) end end
local persistent={WalkSpeed=16,JumpPower=50,AutoJumpEnabled=true,FOV=70,MinZoom=player.CameraMinZoomDistance,MaxZoom=player.CameraMaxZoomDistance}
player.CharacterAdded:Connect(function() task.wait(0.25); applyHumanoidSetting("WalkSpeed",persistent.WalkSpeed); applyHumanoidSetting("JumpPower",persistent.JumpPower); applyHumanoidSetting("AutoJumpEnabled",persistent.AutoJumpEnabled) end)
local blur=Lighting:FindFirstChild("PaperClay_Blur") :: BlurEffect?
if not blur then blur=mk("BlurEffect",{Name="PaperClay_Blur",Size=0,Parent=Lighting}) end

-- ── Topbar ────────────────────────────────────────────────────
local topbar=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,56),Parent=window})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,0),Size=UDim2.new(1,-260,1,0),Font=Enum.Font.GothamBold,Text="Paper & Clay  ⊕  RAE",TextColor3=Color3.fromRGB(46,42,38),TextSize=16,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})
mk("TextLabel",{BackgroundTransparency=1,Position=UDim2.new(0,18,0,30),Size=UDim2.new(1,-260,0,20),Font=Enum.Font.GothamMedium,Text="Soft UI · Recursive Autonomous Engine · 6-axis value system",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Parent=topbar})
local controls=mk("Frame",{BackgroundTransparency=1,AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-14,0,12),Size=UDim2.new(0,220,0,32),Parent=topbar})
mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Right,VerticalAlignment=Enum.VerticalAlignment.Center,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,10),Parent=controls})
local function makeCtrl(text,bg)
    local b=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=bg,BorderSizePixel=0,Size=UDim2.new(0,44,0,32),Font=Enum.Font.GothamBold,Text=text,TextColor3=Color3.fromRGB(54,49,44),TextSize=14,Parent=controls})
    addCorner(b,UDim.new(0,10)); addStroke(b,1,0.35); hookHover(b,b.BackgroundColor3,Color3.fromRGB(255,252,248),0.35,0.18); return b
end
local btnMin=makeCtrl("—",Color3.fromRGB(244,239,232)); local btnClose=makeCtrl("✕",Color3.fromRGB(244,233,228))

-- ── Body + Sidebar + Pages ────────────────────────────────────
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

local pageOverview   = makePage("Overview")
local pagePlayer     = makePage("Player")
local pageCamera     = makePage("Camera")
local pageWorld      = makePage("World")
local pageDiscovery  = makePage("Discovery")
local pageRAE        = makePage("RAE")
local pageRecursive  = makePage("Recursive")
local pageBridge     = makePage("Bridge")
local pageUtils      = makePage("Utilities")
local pageAbout      = makePage("About")

-- ============================================================
-- PAGE: Overview
-- ============================================================
do
    local _, s1=makeSection(pageOverview,"Welcome")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Welcome to Paper & Clay + RAE.\n\nRAE (Recursive Autonomous Engine) runs as a live backend — use the RAE tab to scan, plan, and execute. The Recursive tab shows cognitive state in real time.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,80),Parent=s1})
    local _, s2=makeSection(pageOverview,"Quick Actions")
    local b1=makeButton(s2,"Reset Character",UDim2.new(0,200,0,40),"↺")
    b1.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b1.Button); local hum=getHumanoid(); if hum then hum.Health=0 end end)
    local b2=makeButton(s2,"Center Window",UDim2.new(0,200,0,40),"◎")
    b2.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b2.Button); window.Position=UDim2.new(0.5,0,0.5,0) end)
    local _, s3=makeSection(pageOverview,"Status")
    local statusLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Loading...",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=s3})
    task.spawn(function()
        while statusLabel and statusLabel.Parent do
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local cam = Workspace.CurrentCamera
            statusLabel.Text = string.format(
                "WalkSpeed: %d   JumpPower: %d   FOV: %d\nRAE Phase: %s   Cycle: %d   Cards: %d",
                hum and hum.WalkSpeed or 0, hum and hum.JumpPower or 0,
                cam and cam.FieldOfView or persistent.FOV,
                RAE_State.Phase, RAE_State.CycleCount, #RAE_State.Cards)
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
    recenter.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(recenter.Button); local ch=getCharacter(); local hrp=ch and ch:FindFirstChild("HumanoidRootPart"); local cam=Workspace.CurrentCamera; if hrp and cam then cam.CFrame=CFrame.new(cam.CFrame.Position,cam.CFrame.Position+hrp.CFrame.LookVector) end end)
    -- FOV enforcement: only re-apply if it drifts, checked at 4Hz not 60Hz
    task.spawn(function()
        while true do
            task.wait(0.25)
            local cam = Workspace.CurrentCamera
            if cam and math.abs(cam.FieldOfView - persistent.FOV) > 0.5 then
                cam.FieldOfView = persistent.FOV
            end
        end
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
-- PAGE: Discovery (Remote Scanner → feeds RAE)
-- ============================================================
do
    local _, sScan=makeSection(pageDiscovery,"Remote Endpoint Scanner")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Scans for RemoteEvents and RemoteFunctions. Discovered remotes are automatically fed into RAE's Replication channel on next scan.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,48),Parent=sScan})
    local scanBtn=makeButton(sScan,"Scan All Remotes",UDim2.new(1,0,0,40),"🔍")
    scanBtn.Button.BackgroundColor3=Color3.fromRGB(220,220,255)
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

    -- Trust vector scanner (from original Recursive tab — kept here, non-destructive only)
    local _, sTV=makeSection(pageDiscovery,"Trust Vector Analysis")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Classifies remotes by semantic keyword categories. Results are informational — discovered patterns are reflected in RAE's card system.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,48),Parent=sTV})
    local tvBtn=makeButton(sTV,"Classify Remotes",UDim2.new(1,0,0,40),"🔎")
    tvBtn.Button.BackgroundColor3=Color3.fromRGB(220,235,255)
    local tvScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,200),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sTV})
    addCorner(tvScroll,UDim.new(0,8)); addStroke(tvScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=tvScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=tvScroll})

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
                        local category = ClassifyRemote(v.Name)
                        if category ~= "General" then
                            found=found+1
                            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,36),Parent=tvScroll})
                            addCorner(row,UDim.new(0,6)); addStroke(row,1,0.25)
                            mk("TextLabel",{Text=string.format("[%s] %s",category,v.Name),Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
                            mk("TextLabel",{Text=v:GetFullName(),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(150,150,150),Position=UDim2.new(0,8,0,20),Size=UDim2.new(1,-16,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=row})
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
    -- WorldState summary
    local _, sWS=makeSection(pageRAE,"WorldState(T)")
    local wsLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No scan yet.",TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,120),Parent=sWS})

    -- Controls
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

    makeRAEBtn("Scan",        "🔍", Color3.fromRGB(220,230,255), function()
        task.spawn(function() RAE_SilentMode=false; RAE_Scan() end)
    end)
    makeRAEBtn("Plan (MCTS)", "🧠", Color3.fromRGB(220,255,230), function()
        task.spawn(function()
            RAE_SilentMode=false
            local plan=RAE_Plan()
            if plan and #plan>0 then
                sendNotification("Plan ready: "..#plan.." steps.", "Success")
            else
                sendNotification("No plan generated.", "Warning")
            end
        end)
    end)
    makeRAEBtn("Commit",      "▶", Color3.fromRGB(230,255,230), function()
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
    makeRAEBtn("Manual Rescan", "↺", Color3.fromRGB(245,240,230), function()
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
                else
                    sendNotification("Rescan complete. No plan generated.", "Info")
                end
            else
                sendNotification("Rescan failed.", "Error")
            end
        end)
    end)

    -- Card browser
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
        for i,card in ipairs(RAE_State.Cards) do
            local vs=ValueSystem.ScoreCard(card, RAE_State.Cards, Intel.GetMemory().CardHistory)
            local selected=false
            for _,sc in ipairs(RAE_State.SelectedCards) do if sc.ID==card.ID then selected=true; break end end
            local cf=mk("Frame",{BackgroundColor3=selected and Color3.fromRGB(220,240,220) or Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,62),Parent=cardScroll})
            addCorner(cf,UDim.new(0,6)); addStroke(cf,1,selected and 0.1 or 0.25)
            mk("TextLabel",{Text=string.format("[%s] %s",card.Channel,card.Name),Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,10,0,6),Size=UDim2.new(1,-120,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=cf})
            mk("TextLabel",{Text=string.format("Risk:%s Conf:%d%% Val:%.2f",card.Metadata.Risk or "N/A",card.Metadata.Confidence or 0,vs.Total),Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(100,100,100),Position=UDim2.new(0,10,0,24),Size=UDim2.new(1,-120,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=cf})
            mk("TextLabel",{Text=card.Description,Font=Enum.Font.GothamMedium,TextSize=10,TextColor3=Color3.fromRGB(120,112,104),Position=UDim2.new(0,10,0,40),Size=UDim2.new(1,-120,0,12),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=cf})
            local selBtn=mk("TextButton",{Text=selected and "✓ Sel" or "Select",Font=Enum.Font.GothamBold,TextSize=11,BackgroundColor3=selected and Color3.fromRGB(180,230,180) or Color3.fromRGB(230,240,230),Size=UDim2.new(0,80,0,30),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-10,0.5,0),Parent=cf})
            addCorner(selBtn,UDim.new(0,6))
            selBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(selBtn)
                if selected then
                    local ns={}; for _,sc in ipairs(RAE_State.SelectedCards) do if sc.ID~=card.ID then table.insert(ns,sc) end end
                    RAE_State.SelectedCards=ns
                else
                    table.insert(RAE_State.SelectedCards, card)
                end
                refreshCardBrowser()
            end)
        end
    end

    RAE_Callbacks.OnScan = function(ws, cards)
        -- Update WorldState label
        wsLabel.Text=string.format(
            "T: %.2f  |  Instances: %d  |  Scripts: %d\nPhysics: %d  |  Remotes: %d  |  Agents: %d\nValue Objects: %d  |  Match State: %d vars\nStreaming: %s  |  Gravity: %.1f",
            ws.T, ws.ObjectGraph.TotalInstances, ws.ObjectGraph.ScriptCount,
            #ws.Physics.SimulatedAssemblies, #ws.Latent.RemoteEvents, 1+#ws.Agents.OtherPlayers,
            #ws.Latent.ValueObjects,
            (function() local t=0; for _ in pairs(ws.Latent.MatchState) do t=t+1 end; return t end)(),
            tostring(ws.SimConfig.StreamingEnabled), ws.SimConfig.Gravity)
        refreshCardBrowser()
    end

    RAE_Callbacks.OnPlan = function(plan)
        refreshCardBrowser()
    end

    RAE_Callbacks.OnCommit = function(log)
        refreshCardBrowser()
    end
end

-- ============================================================
-- PAGE: Recursive (RAE Cognitive State)
-- ============================================================
do
    local _, sBrain=makeSection(pageRecursive,"Cognitive Brain (Thompson Sampling)")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Live cognitive state of RAE. Updates after every Commit cycle. Posteriors show Bayesian learning per card. Channel weights reflect success rates. Phase shifts indicate environment drift.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=sBrain})

    local refreshBtn=makeButton(sBrain,"Refresh State",UDim2.new(0,200,0,40),"↻")
    refreshBtn.Button.BackgroundColor3=Color3.fromRGB(220,220,255)

    local stateScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,400),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sBrain})
    addCorner(stateScroll,UDim.new(0,8)); addStroke(stateScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=stateScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=stateScroll})

    local function addStateRow(parent, text, color)
        local row=mk("Frame",{BackgroundColor3=color or Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,22),Parent=parent})
        addCorner(row,UDim.new(0,4))
        mk("TextLabel",{Text=text,Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-10,1,0),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,Parent=row})
    end

    local function refreshState()
        stateScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=stateScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=stateScroll})

        local mem=Intel.GetMemory()
        addStateRow(stateScroll,string.format("Cycles: %d  |  Phase Shifts: %d  |  Overfit Streak: %d",mem.Cycles,#mem.PhaseShifts,mem.OverfitStreak),Color3.fromRGB(235,245,255))
        addStateRow(stateScroll,"─── Channel Weights ───",Color3.fromRGB(245,240,235))
        for ch,w in pairs(mem.ChannelWeights) do
            local bar=string.rep("█",math.floor(w*5))..string.rep("░",10-math.floor(w*5))
            addStateRow(stateScroll,string.format("%-14s %.3f  %s",ch,w,bar))
        end
        addStateRow(stateScroll,"─── Value Axis Weights ───",Color3.fromRGB(245,240,235))
        for axis,w in pairs(ValueWeights) do
            addStateRow(stateScroll,string.format("%-18s %.3f",axis,w))
        end
        if next(mem.CardHistory) then
            addStateRow(stateScroll,"─── Card Posteriors ───",Color3.fromRGB(245,240,235))
            for id,h in pairs(mem.CardHistory) do
                addStateRow(stateScroll,string.format("%-10s α=%.2f β=%.2f mean=%.0f%% σ=%.3f n=%d",
                    id:sub(1,10),h.alpha,h.beta,h.Confidence,h.StdDev,h.n))
            end
        end
        if #mem.PhaseShifts>0 then
            addStateRow(stateScroll,"─── Phase Shifts ───",Color3.fromRGB(255,245,235))
            for _,s in ipairs(mem.PhaseShifts) do
                addStateRow(stateScroll,string.format("Cycle %d: %s %.0f%%→%.0f%%",s.Cycle,s.Channel,s.PriorMean*100,s.RecentMean*100),Color3.fromRGB(255,240,220))
            end
        end
        addStateRow(stateScroll,string.format("Value Weight Updates: %d",ValueHistory.WeightUpdates),Color3.fromRGB(240,255,240))
    end

    refreshBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(refreshBtn.Button); refreshState() end)
    -- Also update after each commit
    local origOnCommit=RAE_Callbacks.OnCommit
    RAE_Callbacks.OnCommit=function(log)
        if origOnCommit then origOnCommit(log) end
        refreshState()
    end
end

-- ============================================================
-- PAGE: Bridge (RAE Staged Execution + Telemetry)
-- ============================================================
do
    local _, sLink=makeSection(pageBridge,"Staged Chain Execution")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Execute RAE chains through the staged path: Observe → Probe → Commit → Verify → Rollback. High-risk chains use staged path automatically.",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,56),Parent=sLink})

    local bridgeStatusLabel=mk("TextLabel",{Text="Bridge State: Idle",Font=Enum.Font.GothamBold,TextSize=13,TextColor3=Color3.fromRGB(100,100,160),Size=UDim2.new(1,0,0,24),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=sLink})

    local previewBtn=makeButton(sLink,"Preview Selected Chain",UDim2.new(1,0,0,40),"👁")
    local commitBtn=makeButton(sLink,"Execute Chain",UDim2.new(1,0,0,40),"▶")
    commitBtn.Button.BackgroundColor3=Color3.fromRGB(220,240,220)

    local logScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),Size=UDim2.new(1,0,0,220),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sLink})
    addCorner(logScroll,UDim.new(0,8)); addStroke(logScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=logScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})

    local function addLogRow(text, color)
        local row=mk("Frame",{BackgroundColor3=color or Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,20),Parent=logScroll})
        addCorner(row,UDim.new(0,4))
        mk("TextLabel",{Text=text,Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-8,1,0),Position=UDim2.new(0,6,0,0),BackgroundTransparency=1,Parent=row})
    end

    previewBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(previewBtn.Button)
        logScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=logScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})
        if #RAE_State.SelectedCards==0 then addLogRow("No cards selected. Use RAE tab to select."); return end
        local chain,staged=Executor.Preview(RAE_State.SelectedCards, RAE_State.Cards)
        addLogRow(string.format("Path: %s  |  %d steps",staged and "STAGED" and "⚠ STAGED" or "FAST",#chain), staged and Color3.fromRGB(255,245,225) or Color3.fromRGB(225,245,255))
        local selIDs={}; for _,c in ipairs(RAE_State.SelectedCards) do selIDs[c.ID]=true end
        for i,card in ipairs(chain) do
            local mark=selIDs[card.ID] and "← SELECTED" or "← DEPENDENCY"
            addLogRow(string.format("[%d] [%s] %s | Risk:%s | %s",i,card.Channel,card.Name,card.Metadata.Risk or "N/A",mark))
        end
        bridgeStatusLabel.Text="Bridge State: Previewed ("..#chain.." steps)"
        sendNotification("Chain preview loaded.", "Info")
    end)

    commitBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(commitBtn.Button)
        if #RAE_State.SelectedCards==0 then sendNotification("No cards selected.", "Warning"); return end
        bridgeStatusLabel.Text="Bridge State: Executing..."
        task.spawn(function()
            local log=RAE_Commit()
            if not log then bridgeStatusLabel.Text="Bridge State: Failed"; return end
            logScroll:ClearAllChildren()
            mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=logScroll})
            mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})
            local passed=0
            for _,r in ipairs(log) do
                if r.Success then passed=passed+1 end
                addLogRow(
                    string.format("%s [%s] %s | %s",r.Success and "✓" or "✗",r.Step.Channel,r.Step.Name,r.Reason),
                    r.Success and Color3.fromRGB(230,250,230) or Color3.fromRGB(255,230,230))
            end
            bridgeStatusLabel.Text=string.format("Bridge State: Complete — %d/%d passed (Cycle #%d)",passed,#log,RAE_State.CycleCount)
        end)
    end)
end

-- ============================================================
-- PAGE: Utilities
-- ============================================================
local fpsLabel, netLabel
do
    -- Performance Monitor
    local _, s=makeSection(pageUtils,"Performance")
    fpsLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="FPS: --",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,16),Parent=s})
    netLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,Text="Frame time: -- ms",TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,16),Parent=s})

    -- System Overrides
    local _, sOverrides=makeSection(pageUtils,"System Overrides")
    local purgeBtn=makeButton(sOverrides,"Purge Event Hooks",UDim2.new(0,200,0,40),"⚠")
    purgeBtn.Button.BackgroundColor3=Color3.fromRGB(255,235,235)
    purgeBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(purgeBtn.Button)
        if not getconnections then sendNotification("getconnections() missing.", "Error"); return end
        local count=0
        for _,sig in ipairs({RunService.RenderStepped,RunService.Stepped,RunService.Heartbeat}) do
            for _,conn in ipairs(getconnections(sig)) do if conn.Disable then conn:Disable() else conn:Disconnect() end count=count+1 end
        end
        local hum=getHumanoid()
        if hum then
            for _,conn in ipairs(getconnections(hum.HealthChanged)) do if conn.Disable then conn:Disable() else conn:Disconnect() end count=count+1 end
        end
        sendNotification("Purged "..count.." hooks.", "Success")
    end)

    -- Network Utilities
    local _, sNetwork=makeSection(pageUtils,"Network Utilities")
    local MetricSpoofEnabled=false; local ReplayAmplifierEnabled=false; local CloneAmount=1
    local SanitizeTablesEnabled=false; local AutoDecryptEnabled=false; local DecryptedLogsCount=0
    local ReplayAmplifierToggleRef
    makeToggle(sNetwork,"Spoof Metrics (Anti-Cheat)",false,function(on) MetricSpoofEnabled=on; if on then sendNotification("Metrics spoofing: 60FPS/45ms","Info") end end)
    local rAt=makeToggle(sNetwork,"Amplify Next Packet",false,function(on) ReplayAmplifierEnabled=on; if on then sendNotification("Listening for next remote...","Info") end end)
    ReplayAmplifierToggleRef=rAt
    makeSlider(sNetwork,"Replay Count",1,10,1,function(v) CloneAmount=math.floor(v) end)
    makeToggle(sNetwork,"Sanitize Outbound Tables",false,function(on) SanitizeTablesEnabled=on; if on then sendNotification("Table sanitizer active.","Success") end end)

    -- Callback Capture
    local _, sCallback=makeSection(pageUtils,"Callback Capture (Invoke Hijacker)")
    local CallbackCaptureEnabled=false; local CallbackLogsCount=0
    makeToggle(sCallback,"Enable OnClientInvoke Capture",false,function(on) CallbackCaptureEnabled=on; if on then sendNotification("Capturing Server->Client Invokes.","Info") end end)
    local cbListFrame=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,120),ClipsDescendants=true,Parent=sCallback})
    local cbScroll=mk("ScrollingFrame",{BackgroundTransparency=1,Size=UDim2.new(1,0,1,0),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=cbListFrame})
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=cbScroll})
    local function logCallback(rName,args)
        if CallbackLogsCount>30 then for _,v in ipairs(cbScroll:GetChildren()) do if v:IsA("Frame") then v:Destroy(); break end end else CallbackLogsCount=CallbackLogsCount+1 end
        task.defer(function()
            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(235,240,245),Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,Parent=cbScroll})
            addCorner(row,UDim.new(0,6)); addStroke(row,1,0.4)
            mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=row})
            mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=row})
            mk("TextLabel",{Text="[INVOKE] "..rName,Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(80,100,150),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,Parent=row})
            local ca={}; for i,v in ipairs(args) do ca[i]=cleanTable(v) end
            local s,ds=pcall(function() return HttpService:JSONEncode(ca) end); if not s then ds=tostring(ca) end
            mk("TextBox",{Text=ds,Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(40,40,40),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1,ClearTextOnFocus=false,TextEditable=false,MultiLine=true,Parent=row})
        end)
    end
    local clearCbBtn=makeButton(sCallback,"Clear Logs",UDim2.new(1,0,0,30),"✕")
    clearCbBtn.Button.MouseButton1Click:Connect(function() clickSound(); cbScroll:ClearAllChildren(); mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=cbScroll}); CallbackLogsCount=0 end)

    -- Cipher Decrypter
    local _, sCipher=makeSection(pageUtils,"Payload Cipher Decrypter")
    makeToggle(sCipher,"Auto-Decrypt Network Strings",false,function(on) AutoDecryptEnabled=on; if on then sendNotification("Decryptor Active.","Success") end end)
    local cipherList=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,120),ClipsDescendants=true,Parent=sCipher})
    local cipherScroll=mk("ScrollingFrame",{BackgroundTransparency=1,Size=UDim2.new(1,0,1,0),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=cipherList})
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=cipherScroll})
    local function logDecrypted(rName,cType,orig,dec)
        if DecryptedLogsCount>30 then for _,v in ipairs(cipherScroll:GetChildren()) do if v:IsA("Frame") then v:Destroy(); break end end else DecryptedLogsCount=DecryptedLogsCount+1 end
        task.defer(function()
            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(240,235,230),Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,Parent=cipherScroll})
            addCorner(row,UDim.new(0,6)); addStroke(row,1,0.4)
            mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=row})
            mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=row})
            mk("TextLabel",{Text=string.format("[%s] %s",cType,rName),Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(150,80,80),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,Parent=row})
            local dd=type(dec)=="table" and HttpService:JSONEncode(dec) or tostring(dec)
            mk("TextBox",{Text=dd,Font=Enum.Font.Code,TextSize=11,TextColor3=Color3.fromRGB(40,40,40),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1,ClearTextOnFocus=false,TextEditable=false,MultiLine=true,Parent=row})
        end)
    end
    local clearCipherBtn=makeButton(sCipher,"Clear Logs",UDim2.new(1,0,0,30),"✕")
    clearCipherBtn.Button.MouseButton1Click:Connect(function() clickSound(); cipherScroll:ClearAllChildren(); mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=cipherScroll}); DecryptedLogsCount=0 end)

    -- Hidden UI Inspector
    local _, sUIExploits=makeSection(pageUtils,"UI Inspector (Hidden Interface Revealer)")
    local scanUIBtn=makeButton(sUIExploits,"Scan for Hidden UI",UDim2.new(1,0,0,40),"👁")
    local uiListFrame=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,140),ClipsDescendants=true,Parent=sUIExploits})
    local uiListScroll=mk("ScrollingFrame",{BackgroundTransparency=1,Size=UDim2.new(1,0,1,0),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=uiListFrame})
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=uiListScroll})
    scanUIBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(scanUIBtn.Button); uiListScroll:ClearAllChildren(); mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=uiListScroll})
        local fc=0
        local function addEntry(obj,prop)
            fc=fc+1
            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(240,235,230),Size=UDim2.new(1,0,0,30),Parent=uiListScroll})
            addCorner(row,UDim.new(0,6))
            mk("TextLabel",{Text=obj.Name,Font=Enum.Font.GothamBold,TextSize=12,TextColor3=Color3.fromRGB(60,60,60),TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(0.6,0,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,Parent=row})
            local tb=mk("TextButton",{Text=obj[prop] and "ON" or "OFF",Font=Enum.Font.GothamBold,TextSize=11,BackgroundColor3=obj[prop] and Color3.fromRGB(200,230,200) or Color3.fromRGB(230,200,200),Size=UDim2.new(0,40,0,22),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-6,0.5,0),Parent=row})
            addCorner(tb,UDim.new(0,4))
            tb.MouseButton1Click:Connect(function() clickSound(); obj[prop]=not obj[prop]; tb.Text=obj[prop] and "ON" or "OFF"; tb.BackgroundColor3=obj[prop] and Color3.fromRGB(200,230,200) or Color3.fromRGB(230,200,200) end)
        end
        for _,sg in ipairs(playerGui:GetChildren()) do
            if sg:IsA("ScreenGui") and sg.Name~="PaperClayUI" then
                if not sg.Enabled then addEntry(sg,"Enabled")
                else for _,f in ipairs(sg:GetChildren()) do if f:IsA("GuiObject") and not f.Visible then addEntry(f,"Visible") end end end
            end
        end
        if fc==0 then mk("TextLabel",{Text="No hidden interfaces found.",Size=UDim2.new(1,0,0,20),BackgroundTransparency=1,TextColor3=Color3.fromRGB(150,150,150),Font=Enum.Font.GothamMedium,TextSize=12,Parent=uiListScroll}) end
        sendNotification("Scan Complete. Found: "..fc, "Success")
    end)

    -- Tool Dropper
    local _, sTools=makeSection(pageUtils,"Tool Dropper")
    local dropBtn=makeButton(sTools,"Force Drop Equipped",UDim2.new(0,220,0,40),"▼")
    dropBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(dropBtn.Button)
        local ch=getCharacter(); local tool=ch and ch:FindFirstChildOfClass("Tool")
        if tool then tool.CanBeDropped=true; tool.Parent=Workspace; sendNotification("Dropped: "..tool.Name,"Success")
        else sendNotification("No tool equipped.","Warning") end
    end)
    local unlockBtn=makeButton(sTools,"Unlock All Tools",UDim2.new(0,220,0,40),"🔓")
    unlockBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(unlockBtn.Button); local count=0; local list={}
        if player.Character then table.insert(list,player.Character) end
        if player.Backpack then table.insert(list,player.Backpack) end
        for _,parent in ipairs(list) do for _,t in ipairs(parent:GetChildren()) do if t:IsA("Tool") then t.CanBeDropped=true; count=count+1 end end end
        sendNotification("Unlocked "..count.." tools.","Success")
    end)

    -- Ghost Equip
    local _, sFake=makeSection(pageUtils,"Fake Equip (Ghost Mode)")
    local GhostEquipEnabled=false
    makeToggle(sFake,"Enable Ghost Equip",false,function(on) GhostEquipEnabled=on; if on then sendNotification("Ghost Mode Active","Success") end end)
    local function onCharAdded(char)
        char.ChildAdded:Connect(function(child)
            if GhostEquipEnabled and child:IsA("Tool") then
                task.wait()
                for _,desc in ipairs(child:GetDescendants()) do if desc:IsA("BasePart") or desc:IsA("MeshPart") or desc:IsA("UnionOperation") then desc:Destroy() end end
                sendNotification("Ghost Equipped: "..child.Name,"Info")
            end
        end)
    end
    if player.Character then onCharAdded(player.Character) end
    player.CharacterAdded:Connect(onCharAdded)

    -- Chrono-Bypass
    local _, sChrono=makeSection(pageUtils,"Chrono-Bypass (Cooldown Freezer)")
    local ChronoEnabled=false; local ChronoMode="Past"
    makeToggle(sChrono,"Enable Time Hook",false,function(on) ChronoEnabled=on; if on then sendNotification("Chrono Active: "..ChronoMode,"Success") end end)
    makeToggle(sChrono,"Future Mode",false,function(on) ChronoMode=on and "Future" or "Past"; if ChronoEnabled then sendNotification("Chrono Mode: "..ChronoMode,"Info") end end)
    if not _G.ChronoHookInstalled and hookfunction and checkcaller then
        _G.ChronoHookInstalled=true
        local ot,oos,otm
        ot=hookfunction(tick,function(...) if ChronoEnabled and not checkcaller() then return ChronoMode=="Past" and 1 or ot()+1000000 end return ot(...) end)
        oos=hookfunction(os.time,function(...) if ChronoEnabled and not checkcaller() then return ChronoMode=="Past" and 1 or oos()+1000000 end return oos(...) end)
        otm=hookfunction(time,function(...) if ChronoEnabled and not checkcaller() then return ChronoMode=="Past" and 1 or otm()+1000000 end return otm(...) end)
    end

    -- Physics & Fling
    local _, sPhysics=makeSection(pageUtils,"Physics & Fling")
    local FlingEnabled=false; local FlingConnection=nil; local FlingTool=nil; local FlingNoCols={}
    makeToggle(sPhysics,"Tool Fling Aura (Equip First)",false,function(on)
        FlingEnabled=on
        if on then
            local char=getCharacter(); local tool=char and char:FindFirstChildOfClass("Tool")
            local handle=tool and (tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart"))
            if not tool or not handle then sendNotification("Equip a tool first.","Error"); FlingEnabled=false; return end
            FlingTool=tool; sendNotification("Fling Aura Active!","Success")
            local rg=char:FindFirstChild("RightGrip",true); if rg then rg:Destroy() end
            for _,part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then local nc=Instance.new("NoCollisionConstraint"); nc.Part0=handle; nc.Part1=part; nc.Parent=handle; table.insert(FlingNoCols,nc) end
            end
            FlingConnection=RunService.Heartbeat:Connect(function()
                if char and char:FindFirstChild("HumanoidRootPart") and handle and handle.Parent then
                    handle.CFrame=char.HumanoidRootPart.CFrame
                    handle.AssemblyLinearVelocity=Vector3.new(50000,50000,50000)
                    handle.AssemblyAngularVelocity=Vector3.new(50000,50000,50000)
                    handle.CanCollide=true
                else if FlingConnection then FlingConnection:Disconnect() end end
            end)
        else
            if FlingConnection then FlingConnection:Disconnect(); FlingConnection=nil end
            for _,nc in ipairs(FlingNoCols) do nc:Destroy() end; FlingNoCols={}
            if FlingTool and FlingTool.Parent then FlingTool.Parent=player.Backpack end
            sendNotification("Fling Aura Disabled.","Info")
        end
    end)

    -- Signal Viewer
    local _, sSignals=makeSection(pageUtils,"Signal Viewer")
    local SelectorEnabled=false
    local SelectionBox=mk("SelectionBox",{LineThickness=0.05,Color3=Color3.fromRGB(255,100,100),SurfaceTransparency=0.8,Parent=playerGui})
    local signalList=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,120),Parent=sSignals,ClipsDescendants=true})
    local signalScroll=mk("ScrollingFrame",{BackgroundTransparency=1,Size=UDim2.new(1,0,1,0),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=signalList})
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=signalScroll})
    local function analyzeSignals(target)
        signalScroll:ClearAllChildren(); mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=signalScroll})
        if not getconnections then mk("TextLabel",{Text="getconnections() missing",Size=UDim2.new(1,0,0,20),BackgroundTransparency=1,TextColor3=Color3.fromRGB(150,50,50),Font=Enum.Font.GothamBold,TextSize=12,Parent=signalScroll}); return end
        local found=0
        local function check(obj,eventName)
            if not obj then return end; local ev=obj[eventName]
            for _,conn in ipairs(getconnections(ev)) do
                found=found+1; local func=conn.Function; local scriptName="Unknown"; local scriptObj=nil
                if func then local env=getfenv(func); if env and env.script then scriptName=env.script.Name; scriptObj=env.script else scriptName=debug.info(func,"s") end end
                local row=mk("TextButton",{Text="",AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(240,235,230),Size=UDim2.new(1,0,0,22),Parent=signalScroll})
                addCorner(row,UDim.new(0,4))
                mk("TextLabel",{Text=string.format("  %s -> %s",eventName,scriptName),TextColor3=Color3.fromRGB(60,60,60),Font=Enum.Font.Code,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,-30,1,0),BackgroundTransparency=1,Parent=row})
                hookHover(row,Color3.fromRGB(240,235,230),Color3.fromRGB(230,225,220),1,1)
                row.MouseButton1Click:Connect(function() clickSound(); if scriptObj then displayDecompiledScript(scriptObj) else sendNotification("Cannot locate Script for decompilation.","Warning") end end)
            end
        end
        check(target,"Touched"); check(target,"TouchEnded"); check(target,"MouseClick")
        for _,c in ipairs(target:GetChildren()) do
            if c:IsA("ClickDetector") then check(c,"MouseClick") end
            if c:IsA("ProximityPrompt") then check(c,"Triggered") end
        end
        if found==0 then mk("TextLabel",{Text="No local connections found.",Size=UDim2.new(1,0,0,20),BackgroundTransparency=1,TextColor3=Color3.fromRGB(150,150,150),Font=Enum.Font.GothamMedium,TextSize=12,Parent=signalScroll}) end
    end
    makeToggle(sSignals,"Enable Selector",false,function(on) SelectorEnabled=on; SelectionBox.Adornee=nil; if on then sendNotification("Click a part to view signals.","Info") end end)
    RunService.RenderStepped:Connect(function()
        if not SelectorEnabled then return end
        local mouse=player:GetMouse(); local target=mouse.Target
        if target then SelectionBox.Adornee=target else SelectionBox.Adornee=nil end
    end)
    UserInputService.InputBegan:Connect(function(input,processed)
        if processed then return end
        if SelectorEnabled and input.UserInputType==Enum.UserInputType.MouseButton1 then
            local target=SelectionBox.Adornee; if target then clickSound(); analyzeSignals(target) end
        end
    end)

    -- UI Scale
    local _, s2=makeSection(pageUtils,"UI Scale")
    makeSlider(s2,"Scale",0.7,1.3,1.0,function(v) local scale=screenGui:FindFirstChild("UIScale") or mk("UIScale",{Parent=screenGui}); scale.Scale=v end)

    -- MASTER HOOK
    local SpoofedItems={}; local FakeCache={}
    local TokenForgerEnabled=false; local TokenCache={}; local TokenCacheLabel=nil
    if not _G.PaperClayHookInstalled and getrawmetatable and hookmetamethod and checkcaller then
        _G.PaperClayHookInstalled=true
        local mt=getrawmetatable(game)
        local old_nc,old_idx=mt.__namecall,mt.__index
        local old_nidx=mt.__newindex
        setreadonly(mt,false)
        mt.__newindex=newcclosure(function(self,idx,val)
            if not checkcaller() and typeof(self)=="Instance" and self:IsA("RemoteFunction") and idx=="OnClientInvoke" and type(val)=="function" then
                local orig=val
                val=newcclosure(function(...)
                    if CallbackCaptureEnabled then local args={...}; logCallback(self.Name,args) end
                    return orig(...)
                end)
            end
            return old_nidx(self,idx,val)
        end)
        mt.__namecall=newcclosure(function(self,...)
            local method=getnamecallmethod(); local args={...}
            if not checkcaller() then
                if method=="FindFirstChild" or method=="WaitForChild" then
                    local name=args[1]
                    if SpoofedItems[name] and (self==player.Backpack or self==player.Character) then
                        local real=old_nc(self,...)
                        if real then return real end
                        if not FakeCache[name] then local f=Instance.new("Tool"); f.Name=name; FakeCache[name]=f end
                        return FakeCache[name]
                    end
                end
                if method=="FireServer" then
                    local rName=self.Name
                    if SanitizeTablesEnabled then local ca={}; for i,v in ipairs(args) do ca[i]=cleanTable(v) end; args=ca end
                    if AutoDecryptEnabled then
                        for _,v in ipairs(args) do if type(v)=="string" and #v>5 then local ct,dec=tryDecode(v); if ct then logDecrypted(rName,ct,v,dec) end end end
                    end
                    if TokenForgerEnabled then
                        local lt=nil; for i=#args,1,-1 do if type(args[i])=="string" and #args[i]>5 then lt=args[i]; break end end
                        if lt then TokenCache[rName]=lt; if TokenCacheLabel then TokenCacheLabel.Text="Cached: "..rName.." ("..lt:sub(1,6).."...)" end end
                    end
                    if ReplayAmplifierEnabled then
                        ReplayAmplifierEnabled=false; if ReplayAmplifierToggleRef then ReplayAmplifierToggleRef.Set(false) end
                        if CloneAmount>1 then for i=1,CloneAmount-1 do old_nc(self,unpack(args)) end end
                        return old_nc(self,unpack(args))
                    end
                    if MetricSpoofEnabled then
                        local n=self.Name:lower()
                        if n:find("ping") or n:find("fps") or n:find("heartbeat") or n:find("analytic") then
                            local na={}; for i,v in ipairs(args) do if type(v)=="number" then if v>65 then table.insert(na,60) elseif v<40 then table.insert(na,45) else table.insert(na,v) end else table.insert(na,v) end end
                            return old_nc(self,unpack(na))
                        end
                    end
                    if SanitizeTablesEnabled then return old_nc(self,unpack(args)) end
                end
            end
            return old_nc(self,...)
        end)
        mt.__index=newcclosure(function(self,index)
            if not checkcaller() and SpoofedItems[index] and (self==player.Backpack or self==player.Character) then
                local real=old_idx(self,index); if real then return real end
                if not FakeCache[index] then local f=Instance.new("Tool"); f.Name=index; FakeCache[index]=f end
                return FakeCache[index]
            end
            return old_idx(self,index)
        end)
    end
end

-- FPS counter
do
    local acc,frames=0,0
    RunService.RenderStepped:Connect(function(dt)
        acc=acc+dt; frames=frames+1
        if acc>=0.5 then
            if fpsLabel then fpsLabel.Text=string.format("FPS: %d",math.floor(frames/acc+0.5)) end
            if netLabel then netLabel.Text=string.format("Frame time: %.1f ms",dt*1000) end
            acc=0; frames=0
        end
    end)
end

-- ============================================================
-- PAGE: Chain Builder (Visual Node Editor — powered by RAE)
-- ============================================================
local pageChain = makePage("Chain")
pageChain.ScrollingEnabled = false

do
    local editorFrame=mk("Frame",{Name="EditorCanvas",BackgroundColor3=Color3.fromRGB(242,238,232),BorderSizePixel=0,ClipsDescendants=true,Size=UDim2.new(1,0,1,-50),Position=UDim2.new(0,0,0,50),Parent=pageChain})
    addCorner(editorFrame,UDim.new(0,12)); addStroke(editorFrame,1,0.2)
    local container=mk("Frame",{Name="Container",BackgroundTransparency=1,Size=UDim2.new(0,0,0,0),Position=UDim2.new(0.5,0,0.5,0),Parent=editorFrame})
    local linesFolder=mk("Folder",{Name="Lines",Parent=container})
    local toolbar=mk("Frame",{Name="Toolbar",BackgroundTransparency=1,Size=UDim2.new(1,0,0,40),Parent=pageChain})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Left,VerticalAlignment=Enum.VerticalAlignment.Center,Padding=UDim.new(0,10),Parent=toolbar})

    local nodes,connections,draggingNode,activeConnectionLine,connectingFrom={},{},nil,nil,nil
    local function generateId() return HttpService:GenerateGUID(false) end

    local function drawLine(p1,p2,parent,existingLine)
        local v=p2-p1; local center=(p1+p2)/2; local length=v.Magnitude; local angle=math.atan2(v.Y,v.X)
        local line=existingLine
        if not line then line=mk("Frame",{BackgroundColor3=Color3.fromRGB(100,90,80),BorderSizePixel=0,AnchorPoint=Vector2.new(0.5,0.5),ZIndex=1,Parent=parent}) end
        line.Size=UDim2.new(0,length,0,2); line.Position=UDim2.new(0,center.X,0,center.Y); line.Rotation=math.deg(angle)
        return line
    end

    local function updateConnections()
        for _,conn in ipairs(connections) do
            local n1,n2=nodes[conn.From],nodes[conn.To]
            if n1 and n2 and n1.UI and n2.UI then
                local outDot,inDot=n1.UI:FindFirstChild("OutDot",true),n2.UI:FindFirstChild("InDot",true)
                if outDot and inDot then
                    local p1,p2=outDot.AbsolutePosition+outDot.AbsoluteSize/2,inDot.AbsolutePosition+inDot.AbsoluteSize/2
                    local cAbs=container.AbsolutePosition
                    conn.LineUI=drawLine(p1-cAbs,p2-cAbs,linesFolder,conn.LineUI)
                end
            end
        end
    end

    local function spawnNode(nType, posOffset)
        local id=generateId(); local nodeWidth=150
        local nodeFrame=mk("Frame",{Name="Node_"..nType,BackgroundColor3=Color3.fromRGB(250,248,245),Size=UDim2.new(0,nodeWidth,0,0),AutomaticSize=Enum.AutomaticSize.Y,Position=posOffset or UDim2.new(0,-70,0,-50),ZIndex=5,Parent=container})
        addCorner(nodeFrame,UDim.new(0,8)); addStroke(nodeFrame,1,0.4); addShadow(nodeFrame,4)
        local header=mk("TextButton",{Text="  "..nType,AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(235,230,222),Size=UDim2.new(1,0,0,24),Font=Enum.Font.GothamBold,TextColor3=Color3.fromRGB(60,55,50),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Parent=nodeFrame})
        addCorner(header,UDim.new(0,8)); mk("Frame",{BackgroundColor3=header.BackgroundColor3,BorderSizePixel=0,Position=UDim2.new(0,0,1,-4),Size=UDim2.new(1,0,0,4),Parent=header})
        local content=mk("Frame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,28),Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=nodeFrame})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=content})
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=content})

        local data={}
        if nType~="Start" then
            local inp=mk("TextBox",{Text="",PlaceholderText=nType=="Fire Remote" and "Remote name..." or nType=="Wait" and "Seconds..." or "Item name...",BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,22),Font=Enum.Font.GothamMedium,TextSize=12,Parent=content})
            addCorner(inp,UDim.new(0,6)); addStroke(inp,1,0.4)
            data.Input=inp; data.Value=inp.Text
            inp:GetPropertyChangedSignal("Text"):Connect(function() data.Value=inp.Text end)
        end

        local dotRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,16),Parent=content})
        local inDot=mk("Frame",{Name="InDot",BackgroundColor3=Color3.fromRGB(160,140,120),Size=UDim2.new(0,12,0,12),AnchorPoint=Vector2.new(0,0.5),Position=UDim2.new(0,-4,0.5,0),ZIndex=6,Parent=dotRow})
        addCorner(inDot,UDim.new(0,999))
        local outDot=mk("TextButton",{Name="OutDot",Text="",AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(120,160,120),Size=UDim2.new(0,12,0,12),AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,4,0.5,0),ZIndex=6,Parent=dotRow})
        addCorner(outDot,UDim.new(0,999))

        local node={ID=id,Type=nType,UI=nodeFrame,Data=data,Next=nil}
        nodes[id]=node

        outDot.InputBegan:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then
                connectingFrom=id
                activeConnectionLine=mk("Frame",{BackgroundColor3=Color3.fromRGB(100,90,80),BorderSizePixel=0,AnchorPoint=Vector2.new(0.5,0.5),ZIndex=1,Parent=linesFolder})
            end
        end)

        inDot.InputBegan:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 and connectingFrom and connectingFrom~=id then
                nodes[connectingFrom].Next=id
                table.insert(connections,{From=connectingFrom,To=id})
                connectingFrom=nil
                if activeConnectionLine then activeConnectionLine:Destroy(); activeConnectionLine=nil end
                updateConnections()
            end
        end)

        header.InputBegan:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then draggingNode=id end
        end)
        header.InputEnded:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then draggingNode=nil end
        end)

        return node
    end

    RunService.RenderStepped:Connect(function()
        if draggingNode and nodes[draggingNode] then
            local mouse=player:GetMouse(); local cAbs=container.AbsolutePosition
            nodes[draggingNode].UI.Position=UDim2.new(0,mouse.X-cAbs.X-75,0,mouse.Y-cAbs.Y-12)
            updateConnections()
        end
        if connectingFrom and activeConnectionLine and nodes[connectingFrom] then
            local mouse=player:GetMouse(); local outDot=nodes[connectingFrom].UI:FindFirstChild("OutDot",true)
            if outDot then
                local cAbs=container.AbsolutePosition
                local p1=outDot.AbsolutePosition+outDot.AbsoluteSize/2-cAbs
                local p2=Vector2.new(mouse.X-cAbs.X,mouse.Y-cAbs.Y)
                drawLine(p1,p2,linesFolder,activeConnectionLine)
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then
            if connectingFrom and not activeConnectionLine then connectingFrom=nil end
        end
    end)

    -- RAE-powered chain execution
    local function runChain()
        local current=nil
        for _,n in pairs(nodes) do if n.Type=="Start" then current=n; break end end
        if not current then sendNotification("No Start node found!","Warning"); return end
        sendNotification("Running Chain...","Info")
        task.spawn(function()
            while current do
                local oldColor=current.UI.BackgroundColor3
                tween(current.UI,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(200,255,200)})
                if current.Type=="Wait" then task.wait(tonumber(current.Data.Value) or 1)
                elseif current.Type=="Fire Remote" then
                    local rName=current.Data.Value
                    local rem=ReplicatedStorage:FindFirstChild(rName,true)
                    if rem and rem:IsA("RemoteEvent") then
                        rem:FireServer(); sendNotification("Fired: "..rName,"Success")
                    else sendNotification("Remote not found: "..(rName or ""),"Error") end
                elseif current.Type=="Check Inventory" then
                    local item=current.Data.Value
                    if not(player.Backpack:FindFirstChild(item) or (player.Character and player.Character:FindFirstChild(item))) then
                        sendNotification("Missing: "..item,"Warning")
                        tween(current.UI,TweenInfo.new(0.5),{BackgroundColor3=oldColor}); break
                    end
                elseif current.Type=="RAE Scan" then
                    sendNotification("Chain: RAE Scan","Info")
                    RAE_Scan(); task.wait(0.5)
                elseif current.Type=="RAE Plan" then
                    sendNotification("Chain: RAE Plan","Info")
                    RAE_Plan(); task.wait(0.5)
                elseif current.Type=="RAE Commit" then
                    sendNotification("Chain: RAE Commit","Info")
                    if #RAE_State.SelectedCards>0 then RAE_Commit(); task.wait(1) end
                end
                tween(current.UI,TweenInfo.new(0.5),{BackgroundColor3=oldColor})
                current=current.Next and nodes[current.Next] or nil
            end
            sendNotification("Chain Finished.","Success")
        end)
    end

    local function addToolBtn(txt,func)
        local b=makeButton(toolbar,txt,UDim2.new(0,110,0,32),"＋")
        b.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(b.Button); func() end)
    end

    addToolBtn("Wait",         function() spawnNode("Wait") end)
    addToolBtn("Fire Remote",  function() spawnNode("Fire Remote") end)
    addToolBtn("Check Inv.",   function() spawnNode("Check Inventory") end)
    addToolBtn("RAE Scan",     function() spawnNode("RAE Scan") end)
    addToolBtn("RAE Plan",     function() spawnNode("RAE Plan") end)
    addToolBtn("RAE Commit",   function() spawnNode("RAE Commit") end)

    local runBtn=makeButton(toolbar,"Run",UDim2.new(0,90,0,32),"▶")
    runBtn.Button.BackgroundColor3=Color3.fromRGB(220,235,220)
    runBtn.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(runBtn.Button); runChain() end)

    local clearBtn=makeButton(toolbar,"Clear",UDim2.new(0,80,0,32),"✕")
    clearBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(clearBtn.Button)
        for _,n in pairs(nodes) do if n.Type~="Start" then n.UI:Destroy() end end
        nodes={}; connections={}; linesFolder:ClearAllChildren()
        spawnNode("Start",UDim2.new(0.5,-70,0.5,-150))
    end)

    spawnNode("Start",UDim2.new(0.5,-70,0.5,-150))
end

-- ============================================================
-- PAGE: About
-- ============================================================
do
    local _, s=makeSection(pageAbout,"About")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Paper & Clay + RAE Combined Edition.\n\nRAE: Recursive Autonomous Engine — a 7-layer autonomous AI agent that discovers the game environment, generates action cards, plans with Monte Carlo Tree Search, executes with causal dependency resolution, and learns through Bayesian inference.\n\nBuilt from the ground up. Every cycle it gets smarter.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,0,0,120),Parent=s})
    local _, s2=makeSection(pageAbout,"Quick Links")
    local b1=makeButton(s2,"Open RAE",UDim2.new(0,220,0,40),"🧠"); b1.Button.Name="GoRAE"
    local b2=makeButton(s2,"Toggle Minimize",UDim2.new(0,220,0,40),"—"); b2.Button.Name="DoMinimize"
end

-- ============================================================
-- NAVIGATION
-- ============================================================
local pagesByName={
    Overview=pageOverview, Player=pagePlayer, Camera=pageCamera, World=pageWorld,
    Discovery=pageDiscovery, RAE=pageRAE, Recursive=pageRecursive,
    Bridge=pageBridge, Chain=pageChain, Utilities=pageUtils, About=pageAbout,
}
local navButtons={}; local currentPage

local function setActive(name)
    if currentPage==name then return end
    for n,p in pairs(pagesByName) do p.Visible=(n==name) end
    panelTitle.Text=name
    for n,btn in pairs(navButtons) do
        if n==name then
            tween(btn,TweenInfo.new(0.15,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=Color3.fromRGB(252,249,244)})
            local st=btn:FindFirstChildOfClass("UIStroke"); if st then tween(st,TweenInfo.new(0.15,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Transparency=0.1}) end
        else
            tween(btn,TweenInfo.new(0.15,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=Color3.fromRGB(246,242,236)})
            local st=btn:FindFirstChildOfClass("UIStroke"); if st then tween(st,TweenInfo.new(0.15,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Transparency=0.25}) end
        end
    end
    contentCard.Position=contentCard.Position+UDim2.fromOffset(0,6)
    tween(contentCard,TweenInfo.new(0.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Position=contentCard.Position-UDim2.fromOffset(0,6)})
    currentPage=name
end

local function addNav(name,icon)
    local ui=makeButton(navHolder,name,UDim2.new(1,0,0,36),icon)
    navButtons[name]=ui.Button
    ui.Button.MouseButton1Click:Connect(function() clickSound(); pulseClick(ui.Button); setActive(name) end)
end

addNav("Overview","◫"); addNav("Player","☻"); addNav("Camera","⌁"); addNav("World","☼")
addNav("Discovery","🔍"); addNav("RAE","⊕"); addNav("Recursive","🧠")
addNav("Bridge","🌉"); addNav("Chain","☍"); addNav("Utilities","▦"); addNav("About","ℹ")
setActive("Overview")

-- About page link wiring
for _,d in ipairs(pageAbout:GetDescendants()) do
    if d:IsA("TextButton") and d.Name=="GoRAE" then d.MouseButton1Click:Connect(function() clickSound(); pulseClick(d); setActive("RAE") end) end
    if d:IsA("TextButton") and d.Name=="DoMinimize" then d.MouseButton1Click:Connect(function() clickSound(); pulseClick(d); minimize() end) end
end

-- ============================================================
-- WINDOW: Drag, Resize, Minimize, Close
-- ============================================================
local dragging,dragStart,startPos=false,nil,nil
topbar.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true; dragStart=input.Position; startPos=window.Position end end)
topbar.InputEnded:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then
        window.Position=startPos+UDim2.fromOffset((input.Position-dragStart).X,(input.Position-dragStart).Y)
    end
end)

local resizeGrip=mk("TextButton",{Name="ResizeGrip",AutoButtonColor=false,BackgroundTransparency=1,Size=UDim2.new(0,22,0,22),AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-8,1,-8),Text="⤢",Font=Enum.Font.GothamBold,TextSize=14,TextColor3=Color3.fromRGB(140,130,120),Parent=window,ZIndex=20})
local resizing,resizeStartMouse,resizeStartSize
resizeGrip.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then clickSound(); resizing=true; resizeStartMouse=input.Position; resizeStartSize=window.AbsoluteSize end end)
resizeGrip.InputEnded:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then resizing=false end end)
UserInputService.InputChanged:Connect(function(input)
    if resizing and input.UserInputType==Enum.UserInputType.MouseMovement then
        local delta=input.Position-resizeStartMouse
        local newW,newH=resizeStartSize.X+delta.X,resizeStartSize.Y+delta.Y
        local c=window:FindFirstChildOfClass("UISizeConstraint")
        if c then newW=math.clamp(newW,c.MinSize.X,c.MaxSize.X); newH=math.clamp(newH,c.MinSize.Y,c.MaxSize.Y) end
        window.Size=UDim2.new(0,newW,0,newH)
    end
end)

local minimized=false; local windowOpenSize=window.Size; local windowOpenPos=window.Position
local function minimize()
    if minimized then
        minimized=false; window.Size=UDim2.new(windowOpenSize.X.Scale,windowOpenSize.X.Offset,0,56); window.Position=windowOpenPos; body.Visible=true
        tween(window,TweenInfo.new(0.22,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=windowOpenSize})
    else
        minimized=true; windowOpenSize=window.Size; windowOpenPos=window.Position
        tween(window,TweenInfo.new(0.22,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=UDim2.new(0,window.AbsoluteSize.X,0,56)})
        task.delay(0.12,function() body.Visible=false end)
    end
end

local function close()
    clickSound()
    tween(window,TweenInfo.new(0.18,Enum.EasingStyle.Quad,Enum.EasingDirection.In),{Size=UDim2.new(0,math.max(540,window.AbsoluteSize.X-120),0,math.max(360,window.AbsoluteSize.Y-80))})
    tween(window,TweenInfo.new(0.18,Enum.EasingStyle.Quad,Enum.EasingDirection.In),{Position=window.Position+UDim2.fromOffset(0,10)})
    task.delay(0.18,function() if screenGui then screenGui:Destroy() end end)
end

btnMin.MouseButton1Click:Connect(function() clickSound(); pulseClick(btnMin); minimize() end)
btnClose.MouseButton1Click:Connect(function() pulseClick(btnClose); close() end)

-- ============================================================
-- INTRO ANIMATION
-- ============================================================
do
    local startSize=window.Size
    window.Size=UDim2.new(0,window.AbsoluteSize.X-60,0,window.AbsoluteSize.Y-50)
    window.Position=UDim2.new(0.5,0,0.5,8)
    tween(window,TweenInfo.new(0.22,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=startSize,Position=UDim2.new(0.5,0,0.5,0)})
    task.defer(function() task.wait(0.15); setActive("Overview") end)
    task.defer(function() task.wait(0.4); sendNotification("Paper & Clay + RAE Loaded.","Success") end)
end

-- ============================================================
-- RAE AUTO-START (one-shot boot scan, then manual-only)
-- ============================================================
_G.RAE_Engine = {
    Scan   = RAE_Scan,
    Plan   = RAE_Plan,
    Commit = RAE_Commit,
    State  = RAE_State,
}

task.spawn(function()
    if not player.Character then player.CharacterAdded:Wait() end
    task.wait(3)

    -- Full boot scan — fully visible, player sees every step
    RAE_SilentMode = false
    sendNotification("RAE: Initializing full boot scan...", "Info")
    task.wait(0.5)

    if RAE_Scan() then
        task.wait(0.5)
        local plan = RAE_Plan()
        if plan and #plan > 0 then
            task.wait(0.5)
            local log = RAE_Commit()
            if log then
                local p = 0
                for _, r in ipairs(log) do if r.Success then p = p + 1 end end
                sendNotification(
                    string.format("RAE: Boot complete — %d cards, %d/%d passed.", #RAE_State.Cards, p, #log),
                    p == #log and "Success" or "Warning"
                )
            end
        else
            sendNotification("RAE: Boot scan complete. No plan generated.", "Info")
        end
    else
        sendNotification("RAE: Boot scan failed. Try Manual Rescan.", "Error")
    end

    -- RAE is now idle. All future cycles are user-initiated via the RAE tab.
end)
