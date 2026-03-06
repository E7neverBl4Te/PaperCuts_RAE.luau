-- ── Imports from core.lua ────────────────────────────────────────────────────
local _C = _G.PC
local mk = _C.mk
local addCorner = _C.addCorner
local addStroke = _C.addStroke
local addShadow = _C.addShadow
local pulseClick = _C.pulseClick
local hookHover = _C.hookHover
local tween = _C.tween
local clickSound = _C.clickSound
local uiClickSound = _C.uiClickSound
local disassembleBytecode = _C.disassembleBytecode
local tryDecode = _C.tryDecode
local player = _C.player
local playerGui = _C.playerGui
local Lighting = _C.Lighting
local UserInputService = _C.UserInputService
local RAE_State = _C.RAE_State
local RAE_Callbacks = _C.RAE_Callbacks
local WorldState = _C.WorldState
-- RAE_SilentMode lives in _C.rae.SilentMode (table field — mutations shared)
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
    if _C.rae.SilentMode then return end
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
local pageForge     = makePage("Forge")
local pageSARP      = makePage("SARP")
local pagePR        = makePage("PR")

-- ============================================================
-- ── ui_base exports ─────────────────────────────────────────────────────────
_G.PCU = {
    sendNotification=sendNotification,
    makeButton=makeButton, makeSection=makeSection, makePage=makePage,
    makeToggle=makeToggle, makeSlider=makeSlider,
    displayDecompiledScript=displayDecompiledScript,
    bytecodeViewer=bytecodeViewer, bcText=bcText,
    getCharacter=getCharacter, getHumanoid=getHumanoid,
    applyHumanoidSetting=applyHumanoidSetting,
    persistent=persistent, blur=blur,
    screenGui=screenGui, window=window, topbar=topbar, controls=controls,
    btnMin=btnMin, btnClose=btnClose,
    body=body, bodyRow=bodyRow, sidebar=sidebar,
    navHolder=navHolder, contentCard=contentCard,
    headerRow=headerRow, panelTitle=panelTitle, pagesFolder=pagesFolder,
    pageOverview=pageOverview, pagePlayer=pagePlayer, pageCamera=pageCamera,
    pageWorld=pageWorld, pageDiscovery=pageDiscovery, pageRAE=pageRAE,
    pageRecursive=pageRecursive, pageBridge=pageBridge, pageAnalytics=pageAnalytics,
    pageChain=pageChain, pageUtils=pageUtils, pageAbout=pageAbout,
    pageForge=pageForge, pageSARP=pageSARP, pagePR=pagePR,
}
