local _C = _G.PC
local _U = _G.PCU
local mk             = _C.mk
local addCorner      = _C.addCorner
local addStroke      = _C.addStroke
local tween          = _C.tween
local pulseClick     = _C.pulseClick
local hookHover      = _C.hookHover
local clickSound     = _C.clickSound
local cleanTable     = _C.cleanTable
local tryDecode      = _C.tryDecode
local player         = _C.player
local UserInputService = _C.UserInputService
local RAE_State      = _C.RAE_State
local RAE_Callbacks  = _C.RAE_Callbacks
local RAE_Scan       = _C.RAE_Scan
local RAE_Plan       = _C.RAE_Plan
local RAE_Commit     = _C.RAE_Commit
local SaveSession    = _C.SaveSession
local LoadSession    = _C.LoadSession
local CDG            = _C.CDG
local ETM            = _C.ETM
local LWM            = _C.LWM
local Intel          = _C.Intel
local StateSignature = _C.StateSignature
local ComputeBrierScore = _C.ComputeBrierScore
local sendNotification = _U.sendNotification
local window         = _U.window
local screenGui      = _U.screenGui
local topbar         = _U.topbar
local btnMin         = _U.btnMin
local btnClose       = _U.btnClose
local body           = _U.body
local sidebar        = _U.sidebar
local navHolder      = _U.navHolder
local panelTitle     = _U.panelTitle
local contentCard    = _U.contentCard
local pagesFolder    = _U.pagesFolder
local bodyRow        = _U.bodyRow
local pageOverview   = _U.pageOverview
local pagePlayer     = _U.pagePlayer
local pageCamera     = _U.pageCamera
local pageWorld      = _U.pageWorld
local pageDiscovery  = _U.pageDiscovery
local pageRAE        = _U.pageRAE
local pageRecursive  = _U.pageRecursive
local pageBridge     = _U.pageBridge
local pageAnalytics  = _U.pageAnalytics
local pageChain      = _U.pageChain
local pageUtils      = _U.pageUtils
local pageAbout      = _U.pageAbout
local pageForge      = _U.pageForge
local pageRSM        = _U.pageRSM
local pageSR         = _U.pageSR
local pageSBI        = _U.pageSBI
local pageCSK        = _U.pageCSK
local pageASE        = _U.pageASE
local pageSR         = _U.pageSR
local pageSARP       = _U.pageSARP
local pagePR         = _U.pagePR
local pageAVD        = _U.pageAVD
local pageTSR        = _U.pageTSR
local SARP           = _G.PC.SARP


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
    { Name="Forge",      Page=pageForge,     Icon="⚙" },
    { Name="PR",         Page=pagePR,        Icon="📡" },
    { Name="AVD",        Page=pageAVD,       Icon="🔬" },
    { Name="TSR",        Page=pageTSR,       Icon="👑" },
    { Name="RSM",        Page=pageRSM,       Icon="🗺" },
    { Name="SR",         Page=pageSR,        Icon="🧠" },
    { Name="SBI",        Page=pageSBI,       Icon="🕵" },
    { Name="CSK",        Page=pageCSK,       Icon="🧬" },
    { Name="ASE",        Page=pageASE,       Icon="⚡" },

    { Name="SARP",       Page=pageSARP,      Icon="🔥" },
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
        BorderSizePixel=0, Size=UDim2.new(1,0,0,30), Font=Enum.Font.GothamSemibold,
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
    _C.rae.SilentMode=true
    if RAE_Scan() then
        task.wait(0.5)
        local plan=RAE_Plan()
        if plan and #plan>0 then
            task.wait(0.5)
            local log=RAE_Commit()
            _C.rae.SilentMode=false
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Boot complete — %d cards, %d/%d passed.",#RAE_State.Cards,p,#log),"Success")
            end
        else _C.rae.SilentMode=false; sendNotification("Boot scan complete. No plan generated.","Info") end
    else _C.rae.SilentMode=false; sendNotification("Boot scan — insufficient confidence.","Warning") end
end

if player.Character then task.spawn(bootRAE)
else player.CharacterAdded:Connect(function() task.spawn(bootRAE) end) end
