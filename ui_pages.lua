-- ── Imports from core.lua ────────────────────────────────────────────────────
local _C = _G.PC
local mk = _C.mk
local addCorner = _C.addCorner
local addStroke = _C.addStroke
local pulseClick = _C.pulseClick
local hookHover = _C.hookHover
local tween = _C.tween
local clickSound = _C.clickSound
local tryDecode = _C.tryDecode
local HttpService = _C.HttpService
local RunService = _C.RunService
local ReplicatedStorage = _C.ReplicatedStorage
local player = _C.player
local playerGui = _C.playerGui
local Lighting = _C.Lighting
local UserInputService = _C.UserInputService
local Workspace = _C.Workspace
local LWM = _C.LWM
local ETM = _C.ETM
local ETM_CFG = _C.ETM_CFG
local CDG = _C.CDG
local StateSignature = _C.StateSignature
local WorldState = _C.WorldState
local RAE_State = _C.RAE_State
local RAE_Callbacks = _C.RAE_Callbacks
local RAE_Scan = _C.RAE_Scan
local RAE_Plan = _C.RAE_Plan
local RAE_Commit = _C.RAE_Commit
local CardGenesis = _C.CardGenesis
local ValueWeights = _C.ValueWeights
local ValueHistory = _C.ValueHistory
local ValueSystem = _C.ValueSystem
local RISK_CFG = _C.RISK_CFG
local Intel = _C.Intel
local IntelMem = _C.IntelMem
local Executor = _C.Executor
local MCTSPlanner = _C.MCTSPlanner
local ComputeBrierScore = _C.ComputeBrierScore
local DynamicsModel = _C.DynamicsModel
local TransitionModel = _C.TransitionModel
-- RAE_SilentMode lives in _C.rae.SilentMode (table field — mutations shared)
-- ── Imports from ui_base.lua ─────────────────────────────────────────────────
local _U = _G.PCU
local sendNotification = _U.sendNotification
local makeButton = _U.makeButton
local makeSection = _U.makeSection
local makeToggle = _U.makeToggle
local makeSlider = _U.makeSlider
local getCharacter = _U.getCharacter
local getHumanoid = _U.getHumanoid
local applyHumanoidSetting = _U.applyHumanoidSetting
local persistent = _U.persistent
local blur = _U.blur
local displayDecompiledScript = _U.displayDecompiledScript
local bcText = _U.bcText
local bytecodeViewer = _U.bytecodeViewer
local pageOverview = _U.pageOverview
local pagePlayer = _U.pagePlayer
local pageCamera = _U.pageCamera
local pageWorld = _U.pageWorld
local pageDiscovery = _U.pageDiscovery
local pageRAE = _U.pageRAE
local pageRecursive = _U.pageRecursive
local pageBridge = _U.pageBridge
local pageAnalytics = _U.pageAnalytics
local pageChain = _U.pageChain
local pageUtils = _U.pageUtils
local pageAbout = _U.pageAbout
local contentCard = _U.contentCard
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
        task.spawn(function() _C.rae.SilentMode=false; RAE_Scan() end)
    end)
    makeRAEBtn("Plan (MCTS)", "🧠", Color3.fromRGB(220,255,230), function()
        task.spawn(function()
            _C.rae.SilentMode=false
            local plan = RAE_Plan()
            if plan and #plan>0 then sendNotification("Plan ready: "..#plan.." steps.", "Success")
            else sendNotification("No viable plan generated.", "Warning") end
        end)
    end)
    makeRAEBtn("Commit", "▶", Color3.fromRGB(230,255,230), function()
        task.spawn(function()
            if #RAE_State.SelectedCards==0 then sendNotification("Nothing selected. Run Plan first.", "Warning"); return end
            _C.rae.SilentMode=false
            local log = RAE_Commit()
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Cycle #%d: %d/%d passed.", RAE_State.CycleCount, p, #log), p==#log and "Success" or "Warning")
            end
        end)
    end)
    makeRAEBtn("Manual Rescan", "↺", Color3.fromRGB(245,240,230), function()
        task.spawn(function()
            _C.rae.SilentMode=false
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
        task.spawn(function() _C.rae.SilentMode=false; RAE_Scan() end)
    end)
    makeRAEBtn("Plan (MCTS)","🧠",Color3.fromRGB(220,255,230),function()
        task.spawn(function()
            _C.rae.SilentMode=false
            local plan=RAE_Plan()
            if plan and #plan>0 then sendNotification("Plan ready: "..#plan.." steps.", "Success")
            else sendNotification("No plan generated.", "Warning") end
        end)
    end)
    makeRAEBtn("Commit","▶",Color3.fromRGB(230,255,230),function()
        task.spawn(function()
            if #RAE_State.SelectedCards==0 then sendNotification("Nothing selected. Run Plan first.", "Warning"); return end
            _C.rae.SilentMode=false
            local log=RAE_Commit()
            if log then
                local p=0; for _,r in ipairs(log) do if r.Success then p=p+1 end end
                sendNotification(string.format("Cycle #%d: %d/%d passed.",RAE_State.CycleCount,p,#log), p==#log and "Success" or "Warning")
            end
        end)
    end)
    makeRAEBtn("Manual Rescan","↺",Color3.fromRGB(245,240,230),function()
        task.spawn(function()
            _C.rae.SilentMode=false
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
    local navLinks={{"Open RAE Tab","RAE"},{"Open Analytics Tab","Analytics"},{"Open Recursive Tab","Recursive"},{"Open Forge Tab","Forge"},{"Open SARP Tab","SARP"}}
    for _,nl in ipairs(navLinks) do
        local nb=makeButton(sLinks,nl[1],UDim2.new(0,220,0,36),"→"); nb.Button.BackgroundColor3=Color3.fromRGB(220,230,255)
        local targetName=nl[2]
        nb.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(nb.Button)
            for _, page in ipairs(pagesFolder:GetChildren()) do page.Visible=false end
            local pages={
                Overview=pageOverview, Player=pagePlayer, Camera=pageCamera, World=pageWorld,
                Discovery=pageDiscovery, RAE=pageRAE, Recursive=pageRecursive, Bridge=pageBridge,
                Analytics=pageAnalytics, Chain=pageChain, Utilities=pageUtils, About=pageAbout,
                Forge=pageForge, SARP=pageSARP
            }
            if pages[targetName] then pages[targetName].Visible=true; panelTitle.Text=targetName end
        end)
    end
end

-- ============================================================
-- ██████╗  █████╗ ██╗   ██╗██╗      ██████╗  █████╗ ██████╗
-- ██╔══██╗██╔══██╗╚██╗ ██╔╝██║     ██╔═══██╗██╔══██╗██╔══██╗
-- ██████╔╝███████║ ╚████╔╝ ██║     ██║   ██║███████║██║  ██║
-- ██╔═══╝ ██╔══██║  ╚██╔╝  ██║     ██║   ██║██╔══██║██║  ██║
-- ██║     ██║  ██║   ██║   ███████╗╚██████╔╝██║  ██║██████╔╝
-- ╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝