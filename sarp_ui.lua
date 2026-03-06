local _C = _G.PC
local mk = _C.mk
local addCorner = _C.addCorner
local addStroke = _C.addStroke
local pulseClick = _C.pulseClick
local hookHover = _C.hookHover
local tween = _C.tween
local clickSound = _C.clickSound
local player = _C.player
local LWM = _C.LWM
local ETM = _C.ETM
local CDG = _C.CDG
local RAE_State = _C.RAE_State
local existing = _C.existing
local _U = _G.PCU
local sendNotification = _U.sendNotification
local makeButton = _U.makeButton
local makeSection = _U.makeSection
local makeToggle = _U.makeToggle
local makeSlider = _U.makeSlider
local pageSARP = _U.pageSARP
local contentCard = _U.contentCard
local SARP = _G.PC.SARP
local SARP_CFG = _G.PC.SARP_CFG
-- PAGE: SARP (UI)
-- ============================================================
do
    -- ── Header ───────────────────────────────────────────────
    local _, sHdr = makeSection(pageSARP, "SARP — Phoenix Edition")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Self Autonomous Replication Payload. Delivers payloads via the replication boundary using three channels: Attribute write (with junk camouflage), Owned Carrier (BasePart ownership anchor), and Attachment Bridge (CFrame-encoded echo). The Phoenix Loop adaptively reshapes failed payloads guided by server correction signals, ETM confidence, and CDG causal data.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,72),Parent=sHdr})

    local sarpStatusLabel = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Status: Idle  |  Sessions: 0  |  Log: 0 entries  |  ETM keys: 0",
        TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sHdr})

    local function updateSARPStatus()
        local sesCount = 0; for _ in pairs(SARPSessions) do sesCount=sesCount+1 end
        local etmKeys  = 0
        for k in pairs(ETM.GetTableRef()) do
            if k:find("^sarp_") then etmKeys=etmKeys+1 end
        end
        sarpStatusLabel.Text = string.format(
            "Status: Ready  |  Sessions: %d  |  Log: %d  |  ETM keys: %d  |  Mode: %s",
            sesCount, #SARPLog, etmKeys, SARP_CFG.Mode)
    end

    -- ── Target + Mode Row ─────────────────────────────────────
    local _, sTgt = makeSection(pageSARP, "Target & Delivery Mode")
    local tgtRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),
        AutomaticSize=Enum.AutomaticSize.Y,Parent=sTgt})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,12),Parent=tgtRow})

    -- Target dropdown (simulated with scroll buttons)
    local tgtFrame = mk("Frame",{BackgroundColor3=Color3.fromRGB(250,247,243),
        Size=UDim2.new(0,220,0,36),Parent=tgtRow})
    addCorner(tgtFrame,UDim.new(0,8)); addStroke(tgtFrame,1,0.3)
    local tgtLabel = mk("TextLabel",{Text="👤 Self",Font=Enum.Font.GothamBold,TextSize=12,
        TextColor3=Color3.fromRGB(52,47,42),Size=UDim2.new(1,-40,1,0),Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=tgtFrame})
    local tgtCycleBtn = mk("TextButton",{Text="↕",Font=Enum.Font.GothamBold,TextSize=14,
        BackgroundColor3=Color3.fromRGB(220,230,255),Size=UDim2.new(0,32,1,0),
        AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,0,0,0),Parent=tgtFrame})
    addCorner(tgtCycleBtn,UDim.new(0,6))

    -- Risk badge
    local riskBadge = mk("TextLabel",{Text="RISK: LOW",Font=Enum.Font.GothamBold,TextSize=10,
        TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=Color3.fromRGB(80,180,80),
        Size=UDim2.new(0,90,0,28),TextXAlignment=Enum.TextXAlignment.Center,Parent=tgtRow})
    addCorner(riskBadge,UDim.new(0,8))

    -- Mode toggle
    local modeBtn = makeButton(tgtRow,"Mode: MANUAL",UDim2.new(0,160,0,36),"⚙")
    modeBtn.Button.BackgroundColor3 = Color3.fromRGB(220,240,220)

    -- Auto-select button
    local autoSelBtn = makeButton(tgtRow,"🔄 Auto-Select",UDim2.new(0,140,0,36),"")
    autoSelBtn.Button.BackgroundColor3 = Color3.fromRGB(240,230,255)

    local SARP_CurrentTarget = "Self"
    local SARP_TargetList    = {}

    local function refreshTargetList()
        SARP_TargetList = SARP.TargetResolver.GetAll()
    end
    refreshTargetList()

    local tgtIdx = 1
    tgtCycleBtn.MouseButton1Click:Connect(function()
        clickSound(); refreshTargetList()
        tgtIdx = (tgtIdx % #SARP_TargetList) + 1
        local entry = SARP_TargetList[tgtIdx]
        SARP_CurrentTarget = entry.Name
        tgtLabel.Text = (entry.IsSelf and "👤 Self" or "👥 " .. entry.Name)
            .. (entry.Distance and entry.Distance < math.huge
                and string.format(" (%.0fm)", entry.Distance) or "")
        local badge, badgeCol = SARP.TargetResolver.RiskBadge(SARP_CurrentTarget)
        riskBadge.Text = "RISK: " .. badge
        riskBadge.BackgroundColor3 = badgeCol
    end)

    autoSelBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(autoSelBtn.Button)
        local best = SARP.TargetResolver.AutoSelect()
        SARP_CurrentTarget = best.Name
        tgtLabel.Text = best.IsSelf and "👤 Self" or "👥 " .. best.Name
        local badge, badgeCol = SARP.TargetResolver.RiskBadge(SARP_CurrentTarget)
        riskBadge.Text = "RISK: " .. badge
        riskBadge.BackgroundColor3 = badgeCol
        sendNotification(string.format("Auto-selected: %s (score %.2f)", best.Name, best.Score), "Info")
    end)

    modeBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(modeBtn.Button)
        SARP_CFG.Mode = SARP_CFG.Mode == "MANUAL" and "AUTO" or "MANUAL"
        modeBtn.Label.Text = "Mode: " .. SARP_CFG.Mode
        modeBtn.Button.BackgroundColor3 = SARP_CFG.Mode == "AUTO"
            and Color3.fromRGB(255,230,200) or Color3.fromRGB(220,240,220)
        updateSARPStatus()
    end)

    -- ── Channel Selector ──────────────────────────────────────
    local _, sChan = makeSection(pageSARP, "Delivery Channel")
    local chanRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sChan})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=chanRow})
    local SARP_CurrentChannel = "Attribute"
    local channelDefs = {
        { Name="Attribute",        Icon="🔑", Desc="Attr write + junk camo. Layer 1 echo.",      Color=Color3.fromRGB(220,230,255) },
        { Name="OwnedCarrier",     Icon="📦", Desc="Transient BasePart. Layer 2 ownership.",      Color=Color3.fromRGB(220,255,230) },
        { Name="AttachmentBridge", Icon="🔗", Desc="Attachment CFrame echo. Layer 1+2 combined.", Color=Color3.fromRGB(255,240,220) },
    }
    local chanBtns = {}
    for _, cd in ipairs(channelDefs) do
        local cb = makeButton(chanRow, cd.Icon.." "..cd.Name, UDim2.new(0,0,0,40), "")
        cb.Button.Size = UDim2.new(0,170,0,40)
        cb.Button.BackgroundColor3 = cd.Name == SARP_CurrentChannel
            and Color3.fromRGB(200,210,240) or cd.Color
        addStroke(cb.Button, 1, 0.3)
        local cdCapture = cd
        cb.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(cb.Button)
            SARP_CurrentChannel = cdCapture.Name
            for _, b in ipairs(chanBtns) do
                b.Button.BackgroundColor3 = (b == cb)
                    and Color3.fromRGB(200,210,240) or channelDefs[_].Color
            end
        end)
        table.insert(chanBtns, cb)
    end
    -- Channel description label
    local chanDescLabel = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Attribute: writes payload to instance attributes. Junk key triggers server dump; real payload key survives the echo window before correction arrives.",
        TextColor3=Color3.fromRGB(100,92,84),TextSize=11,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,32),Parent=sChan})

    -- ── Script / Payload Input ────────────────────────────────
    local _, sScript = makeSection(pageSARP, "Payload & Trash Camo")

    local payloadRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),
        AutomaticSize=Enum.AutomaticSize.Y,Parent=sScript})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=payloadRow})

    -- Box 1: Payload content
    local payloadBox = mk("TextBox",{
        PlaceholderText="Payload value (string, number, or expression)...",
        Text="test_payload_" .. tostring(math.random(1000,9999)),
        BackgroundColor3=Color3.fromRGB(255,255,255),
        Size=UDim2.new(0,0,0,60),Font=Enum.Font.Code,TextSize=11,
        TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Top,ClearTextOnFocus=false,
        Parent=payloadRow})
    payloadBox.Size = UDim2.new(0.55,0,0,60)
    addCorner(payloadBox,UDim.new(0,6)); addStroke(payloadBox,1,0.3)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingTop=UDim.new(0,6),Parent=payloadBox})

    local payloadLabel = mk("TextLabel",{Text="📦 Payload",Font=Enum.Font.GothamBold,TextSize=10,
        TextColor3=Color3.fromRGB(80,80,80),BackgroundTransparency=1,
        Size=UDim2.new(0.55,0,0,14),Parent=sScript})

    -- Box 2: Trash camo
    local trashCol = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),
        AutomaticSize=Enum.AutomaticSize.Y,Parent=sScript})
    local trashBox = mk("TextBox",{
        PlaceholderText="Trash camo value (NaN vector, oversized string, etc)...",
        Text="",BackgroundColor3=Color3.fromRGB(255,252,248),
        Size=UDim2.new(1,0,0,44),Font=Enum.Font.Code,TextSize=11,
        TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Top,ClearTextOnFocus=false,
        Parent=trashCol})
    addCorner(trashBox,UDim.new(0,6)); addStroke(trashBox,1,0.3)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingTop=UDim.new(0,6),Parent=trashBox})
    mk("TextLabel",{Text="🗑 Trash Camo (blank = auto NaN vector)",Font=Enum.Font.GothamBold,TextSize=10,
        TextColor3=Color3.fromRGB(80,80,80),BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,14),Parent=trashCol})

    -- Phoenix config row
    local phxRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),
        AutomaticSize=Enum.AutomaticSize.Y,Parent=sScript})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,16),Parent=phxRow})
    local _tAC = makeToggle(phxRow,"AC Gate",true,function(on) SARP_CFG.AntiCheatGate=on end)
    if _tAC and _tAC.Root then _tAC.Root.Size = UDim2.new(0,120,0,34) end
    local _tHum = makeToggle(phxRow,"Humanize Delays",true,function(on)
        SARP_CFG.ReshapeNoiseScale = on and 0.05 or 0.0
    end)
    if _tHum and _tHum.Root then _tHum.Root.Size = UDim2.new(0,160,0,34) end

    -- Phoenix max depth slider
    local phxDepthRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sScript})
    makeSlider(phxDepthRow,"Phoenix Depth",1,8,5,function(v)
        SARP_CFG.PhoenixMaxDepth = math.floor(v)
    end)

    -- ── Simulation Preview Pane ───────────────────────────────
    local _, sSim = makeSection(pageSARP, "Simulation Preview")
    local simPreviewLabel = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Run Simulate to see projected outcome before launch.",
        TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,80),Parent=sSim})

    local simBtn = makeButton(sSim,"⚙ Simulate",UDim2.new(0,180,0,40),"")
    simBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)

    local SARP_CurrentSim     = nil
    local SARP_CurrentWrapped = nil

    simBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(simBtn.Button)
        local payload = payloadBox.Text
        if #payload == 0 then
            sendNotification("Payload box is empty.", "Warning"); return
        end
        local wrapped, simResult, err = SARP.Build(
            SARP_CurrentChannel, payload, nil, nil, SARP_CurrentTarget)
        if err then
            sendNotification("SARP Build error: " .. err, "Error"); return
        end
        SARP_CurrentSim     = simResult
        SARP_CurrentWrapped = wrapped

        local riskCol = simResult.Risk == "High" and Color3.fromRGB(200,80,80)
            or simResult.Risk == "Medium" and Color3.fromRGB(200,160,60)
            or Color3.fromRGB(60,160,60)
        local acCol   = simResult.ACRisk == "ELEVATED"
            and Color3.fromRGB(200,80,80) or Color3.fromRGB(60,160,60)

        simPreviewLabel.Text = string.format(
            "Channel: %s -> Target: %s | %s | Wrapper: %s | Depth: %d | Reshape est: %d | LWM: %d snaps | Sig: %s",
            SARP_CurrentChannel, SARP_CurrentTarget,
            simResult.Summary,
            wrapped.Desc,
            SARP_CFG.PhoenixMaxDepth, simResult.ReshapeEst,
            simResult.LWMDepth, simResult.Sig)
        simPreviewLabel.TextColor3 = Color3.fromRGB(50,50,80)
        sendNotification("Simulation ready. " .. simResult.Summary, "Info")
    end)

    -- ── Execution Steps ───────────────────────────────────────
    local _, sExec = makeSection(pageSARP, "Execution  —  Wrap → Fly → Phoenix")

    local stepRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,52),Parent=sExec})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=stepRow})

    -- Step indicators
    local function makeStepBadge(parent, icon, label, color)
        local f = mk("Frame",{BackgroundColor3=color,Size=UDim2.new(0,100,0,48),Parent=parent})
        addCorner(f,UDim.new(0,8)); addStroke(f,1,0.3)
        mk("TextLabel",{Text=icon,Font=Enum.Font.GothamBold,TextSize=18,
            TextColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,24),
            Position=UDim2.new(0,0,0,4),BackgroundTransparency=1,
            TextXAlignment=Enum.TextXAlignment.Center,Parent=f})
        local lbl = mk("TextLabel",{Text=label,Font=Enum.Font.GothamBold,TextSize=10,
            TextColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,16),
            Position=UDim2.new(0,0,0,28),BackgroundTransparency=1,
            TextXAlignment=Enum.TextXAlignment.Center,Parent=f})
        return f, lbl
    end

    local step1Frame, step1Lbl = makeStepBadge(stepRow,"🔒","Wrap",Color3.fromRGB(140,160,220))
    local step2Frame, step2Lbl = makeStepBadge(stepRow,"🚀","Fly", Color3.fromRGB(140,200,140))
    local step3Frame, step3Lbl = makeStepBadge(stepRow,"🔥","Phoenix",Color3.fromRGB(200,130,80))

    -- Arrow decorators
    local function mkArrow(parent)
        mk("TextLabel",{Text="→",Font=Enum.Font.GothamBold,TextSize=20,
            TextColor3=Color3.fromRGB(180,170,160),BackgroundTransparency=1,
            Size=UDim2.new(0,24,0,48),Parent=parent})
    end
    -- Insert arrows (done after badges so layout order is correct)
    -- We'll use a grid layout with arrows inline
    local arrowA = mk("TextLabel",{Text="→",Font=Enum.Font.GothamBold,TextSize=20,
        TextColor3=Color3.fromRGB(160,155,148),BackgroundTransparency=1,
        Size=UDim2.new(0,20,0,48),LayoutOrder=2,Parent=stepRow})
    local arrowB = mk("TextLabel",{Text="→",Font=Enum.Font.GothamBold,TextSize=20,
        TextColor3=Color3.fromRGB(160,155,148),BackgroundTransparency=1,
        Size=UDim2.new(0,20,0,48),LayoutOrder=4,Parent=stepRow})
    step1Frame.LayoutOrder=1; step2Frame.LayoutOrder=3; step3Frame.LayoutOrder=5

    local execStateLabel = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="State: Idle",TextColor3=Color3.fromRGB(92,84,76),TextSize=13,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sExec})

    -- Progress bar
    local progBg = mk("Frame",{BackgroundColor3=Color3.fromRGB(230,225,220),
        Size=UDim2.new(1,0,0,8),Parent=sExec})
    addCorner(progBg,UDim.new(0,4))
    local progFill = mk("Frame",{BackgroundColor3=Color3.fromRGB(140,200,140),
        Size=UDim2.new(0,0,1,0),Parent=progBg})
    addCorner(progFill,UDim.new(0,4))

    local function setProgress(pct, color)
        tween(progFill, TweenInfo.new(0.3), {
            Size=UDim2.new(math.clamp(pct,0,1),0,1,0),
            BackgroundColor3=color or Color3.fromRGB(140,200,140)
        })
    end

    -- Main Launch button
    local launchBtnRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sExec})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,12),Parent=launchBtnRow})

    local simFirstToggle = {Value=true}
    local _simToggle = makeToggle(launchBtnRow,"Sim First",true,function(on) simFirstToggle.Value=on end)
    if _simToggle and _simToggle.Root then
        _simToggle.Root.Size = UDim2.new(0,110,0,40)
    end

    local launchBtn = makeButton(launchBtnRow,"🚀 Launch Phoenix",UDim2.new(0,200,0,40),"")
    launchBtn.Button.BackgroundColor3 = Color3.fromRGB(200,240,200)
    addStroke(launchBtn.Button,1,0.2)

    local abortBtn = makeButton(launchBtnRow,"✕ Abort",UDim2.new(0,100,0,40),"")
    abortBtn.Button.BackgroundColor3 = Color3.fromRGB(255,220,220)

    local SARP_Running = false

    abortBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); SARP_Running=false
        SARP.Cleanup()
        execStateLabel.Text="State: Aborted"
        setProgress(0, Color3.fromRGB(220,160,80))
        sendNotification("SARP aborted. Watchers cleared.", "Warning")
    end)

    launchBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(launchBtn.Button)
        if SARP_Running then sendNotification("SARP already running.", "Warning"); return end
        local payload = payloadBox.Text
        if #payload == 0 then sendNotification("Payload is empty.", "Warning"); return end

        -- Build if no existing sim or if payload changed
        if not SARP_CurrentWrapped then
            local wrapped, simResult, err = SARP.Build(
                SARP_CurrentChannel, payload, nil, nil, SARP_CurrentTarget)
            if err then sendNotification("SARP Build: " .. err, "Error"); return end
            SARP_CurrentSim     = simResult
            SARP_CurrentWrapped = wrapped
        end

        -- Sim-first gate
        if simFirstToggle.Value and SARP_CurrentSim then
            simPreviewLabel.Text = SARP_CurrentSim.Summary
        end

        SARP_Running = true
        execStateLabel.Text = "State: Wrapping..."
        tween(step1Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(80,100,200)})
        setProgress(0.12, Color3.fromRGB(140,160,220))
        task.wait(0.2)

        execStateLabel.Text = "State: Flying..."
        tween(step1Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(140,160,220)})
        tween(step2Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(60,160,60)})
        setProgress(0.40, Color3.fromRGB(140,200,140))

        task.spawn(function()
            SARP.Execute(SARP_CurrentWrapped, SARP_CurrentSim, SARP_CurrentTarget,
                function(success, sessionRec, finalStr)
                    SARP_Running = false

                    -- Update step indicators
                    if success then
                        tween(step2Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(140,200,140)})
                        tween(step3Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(60,180,60)})
                        setProgress(1.0, Color3.fromRGB(100,220,100))
                        execStateLabel.Text = string.format(
                            "State: ✓ SUCCESS — %s (depth %d)",
                            SARP_CurrentTarget,
                            sessionRec and sessionRec.FinalDepth or 1)
                    else
                        tween(step3Frame,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(200,80,80)})
                        setProgress(1.0, Color3.fromRGB(220,100,100))
                        execStateLabel.Text = "State: ✕ FAILED — " .. (finalStr or "no result")
                    end

                    -- Session record
                    if sessionRec then
                        SARPSessions[tostring(sessionRec.ID)] = sessionRec
                    end

                    -- Notification
                    local depthStr = sessionRec
                        and string.format(" (%d attempt%s)", #sessionRec.Attempts,
                            #sessionRec.Attempts~=1 and "s" or "") or ""
                    sendNotification(
                        string.format("SARP [%s→%s]%s — %s",
                            SARP_CurrentChannel, SARP_CurrentTarget, depthStr,
                            success and "Payload lingered ✓" or (finalStr or "failed")),
                        success and "Success" or "Warning")

                    -- Reset wrapped so next launch re-builds fresh
                    SARP_CurrentWrapped = nil
                    SARP_CurrentSim     = nil
                    updateSARPStatus()
                end
            )
        end)
    end)

    -- ── Outcome Log ───────────────────────────────────────────
    local _, sLog = makeSection(pageSARP, "Session Log")
    local logScroll = mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),
        Size=UDim2.new(1,0,0,240),CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sLog})
    addCorner(logScroll,UDim.new(0,8)); addStroke(logScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=logScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),
        PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})

    local function appendSARPLog(entry)
        local row = mk("Frame",{
            BackgroundColor3 = entry.Success
                and Color3.fromRGB(235,255,235) or Color3.fromRGB(255,238,235),
            Size=UDim2.new(1,0,0,48),Parent=logScroll})
        addCorner(row,UDim.new(0,5)); addStroke(row,1,0.2)
        mk("TextLabel",{
            Text=string.format("%s  [%s→%s]  d%d  %s",
                entry.Success and "✓" or "✕",
                entry.Channel, entry.Target,
                entry.Depth,
                entry.Pattern),
            Font=Enum.Font.GothamBold,TextSize=11,
            TextColor3=Color3.fromRGB(50,50,50),
            Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,0,14),
            TextXAlignment=Enum.TextXAlignment.Left,
            BackgroundTransparency=1,Parent=row})
        mk("TextLabel",{
            Text=string.format("ETM key: %s  |  T: +%.2fs",
                entry.ETMKey, entry.T - (SARPLog[1] and SARPLog[1].T or entry.T)),
            Font=Enum.Font.Code,TextSize=10,
            TextColor3=Color3.fromRGB(100,100,100),
            Position=UDim2.new(0,8,0,22),Size=UDim2.new(1,-16,0,12),
            TextXAlignment=Enum.TextXAlignment.Left,
            BackgroundTransparency=1,Parent=row})
        mk("TextLabel",{
            Text="Session " .. tostring(entry.SessionID),
            Font=Enum.Font.Code,TextSize=9,
            TextColor3=Color3.fromRGB(150,150,150),
            Position=UDim2.new(0,8,0,36),Size=UDim2.new(1,-80,0,10),
            TextXAlignment=Enum.TextXAlignment.Left,
            BackgroundTransparency=1,Parent=row})
    end

    -- Log refresh button
    local logCtrlRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,40),Parent=sLog})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=logCtrlRow})
    local refreshLogBtn = makeButton(logCtrlRow,"Refresh Log",UDim2.new(0,160,0,36),"↻")
    refreshLogBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)
    local clearLogBtn2 = makeButton(logCtrlRow,"Clear Log",UDim2.new(0,120,0,36),"🗑")
    clearLogBtn2.Button.BackgroundColor3 = Color3.fromRGB(255,230,230)

    local function doRefreshLog()
        logScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,4),Parent=logScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),
            PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=logScroll})
        if #SARPLog == 0 then
            mk("TextLabel",{Text="No launches yet.",BackgroundTransparency=1,
                Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(150,150,150),
                Size=UDim2.new(1,0,0,24),Parent=logScroll})
            return
        end
        for i = #SARPLog, math.max(1, #SARPLog-30), -1 do
            appendSARPLog(SARPLog[i])
        end
    end

    refreshLogBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(refreshLogBtn.Button); doRefreshLog(); updateSARPStatus()
    end)
    clearLogBtn2.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(clearLogBtn2.Button)
        SARPLog = {}; doRefreshLog(); updateSARPStatus()
        sendNotification("SARP log cleared.", "Info")
    end)

    -- ── Phoenix Intelligence Panel ────────────────────────────
    local _, sPhxIntel = makeSection(pageSARP, "Phoenix Intelligence — Pattern Registry")
    local patternScroll = mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),
        Size=UDim2.new(1,0,0,160),CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sPhxIntel})
    addCorner(patternScroll,UDim.new(0,8)); addStroke(patternScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=patternScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),
        PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=patternScroll})

    local refreshPtnBtn = makeButton(sPhxIntel,"Refresh Patterns",UDim2.new(0,180,0,36),"🔄")
    refreshPtnBtn.Button.BackgroundColor3 = Color3.fromRGB(220,240,255)

    local function doRefreshPatterns()
        patternScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=patternScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),
            PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=patternScroll})
        local count = 0
        for _, p in pairs(SARPPatterns) do count=count+1 end
        if count == 0 then
            mk("TextLabel",{Text="No patterns learned yet. Run launches to build pattern registry.",
                BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=11,
                TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=patternScroll})
            return
        end
        -- Header
        mk("TextLabel",{
            Text=string.format("%-22s %6s %6s %6s  Reshape", "Pattern","Total","✓","Rate"),
            Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(120,120,120),
            Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,
            TextXAlignment=Enum.TextXAlignment.Left,Parent=patternScroll})
        local sorted = {}
        for _, p in pairs(SARPPatterns) do table.insert(sorted, p) end
        table.sort(sorted, function(a,b) return a.totalCount > b.totalCount end)
        for _, p in ipairs(sorted) do
            local rate = p.totalCount > 0 and (p.successCount / p.totalCount) or 0
            local rateCol = rate >= 0.6 and Color3.fromRGB(60,160,60)
                or rate >= 0.3 and Color3.fromRGB(180,130,60)
                or Color3.fromRGB(180,60,60)
            local pRow = mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),
                Size=UDim2.new(1,0,0,20),Parent=patternScroll})
            addCorner(pRow,UDim.new(0,4)); addStroke(pRow,1,0.3)
            mk("TextLabel",{
                Text=string.format("%-22s %6d %6d %5.0f%%  %s",
                    p.Pattern:sub(1,22), p.totalCount, p.successCount, rate*100,
                    p.reshapeDesc or "-"),
                Font=Enum.Font.Code,TextSize=10,TextColor3=rateCol,
                Size=UDim2.new(1,-16,1,0),Position=UDim2.new(0,8,0,0),
                BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,
                TextTruncate=Enum.TextTruncate.AtEnd,Parent=pRow})
        end
    end

    refreshPtnBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(refreshPtnBtn.Button); doRefreshPatterns()
    end)

    -- ── ETM Convergence (SARP keys only) ─────────────────────
    local _, sETMSARP = makeSection(pageSARP, "ETM — SARP Convergence")
    local etmSARPLabel = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="No ETM data for SARP keys yet.",TextColor3=Color3.fromRGB(72,66,60),
        TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,0,0,60),Parent=sETMSARP})
    local etmSARPBtn = makeButton(sETMSARP,"Refresh ETM",UDim2.new(0,160,0,36),"📊")
    etmSARPBtn.Button.BackgroundColor3 = Color3.fromRGB(220,240,255)

    local function doRefreshETMSARP()
        local cmap = ETM.GetConvergenceMap()
        local lines = {}
        local sarpKeys = 0
        local sarpConv = 0
        for cardID, stats in pairs(cmap) do
            if cardID ~= "_global" and cardID:find("^sarp_") then
                sarpKeys = sarpKeys + 1
                if stats.converged > 0 then sarpConv = sarpConv + 1 end
                local p, conv, std = ETM.Predict(cardID, RAE_State.CurrentSig or "unknown")
                table.insert(lines, string.format("%-32s  p=%.2f σ=%.3f %s",
                    cardID:sub(1,32), p, std, conv and "✓" or "~"))
            end
        end
        if #lines == 0 then
            etmSARPLabel.Text = "No ETM data for SARP keys yet. Run launches to populate."
        else
            table.insert(lines, 1, string.format("SARP ETM keys: %d  |  Converged: %d  |  Rate: %.0f%%",
                sarpKeys, sarpConv, sarpKeys>0 and (sarpConv/sarpKeys*100) or 0))
            etmSARPLabel.Text = table.concat(lines, "\n")
            etmSARPLabel.Size = UDim2.new(1,0,0,math.max(60, #lines*14+8))
        end
    end

    etmSARPBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(etmSARPBtn.Button); doRefreshETMSARP()
    end)

    -- Auto-refresh ETM and log after any SARP launch (via SARPLog growth)
    -- Done by polling in the launch callback above (updateSARPStatus triggers downstream)


    -- ── Live Heat / Correction Dashboard ─────────────────────
    local _, sHeat = makeSection(pageSARP, "Live Heat & Correction Dashboard")

    -- Status grid: 6 live metrics updated on Refresh
    local heatGridData = {
        { Key="AC Heat",         Val="--",  Col=Color3.fromRGB(72,66,60) },
        { Key="Correction Rate", Val="--",  Col=Color3.fromRGB(72,66,60) },
        { Key="Echo Window",     Val="--",  Col=Color3.fromRGB(72,66,60) },
        { Key="Evasion Score",   Val="--",  Col=Color3.fromRGB(72,66,60) },
        { Key="Linger Rate",     Val="--",  Col=Color3.fromRGB(72,66,60) },
        { Key="Cascade Success", Val="--",  Col=Color3.fromRGB(72,66,60) },
    }
    local heatGrid = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,10),AutomaticSize=Enum.AutomaticSize.Y,Parent=sHeat})
    mk("UIGridLayout",{CellSize=UDim2.new(0.5,-6,0,48),CellPadding=UDim2.new(0,6,0,6),
        SortOrder=Enum.SortOrder.LayoutOrder,Parent=heatGrid})
    local heatCells = {}
    for idx, entry in ipairs(heatGridData) do
        local cell = mk("Frame",{BackgroundColor3=Color3.fromRGB(248,245,240),
            Size=UDim2.new(0,1,0,1),LayoutOrder=idx,Parent=heatGrid})
        addCorner(cell,UDim.new(0,8)); addStroke(cell,1,0.3)
        local keyLbl = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=entry.Key,TextColor3=Color3.fromRGB(130,120,110),TextSize=10,
            Position=UDim2.new(0,8,0,6),Size=UDim2.new(1,-16,0,14),
            TextXAlignment=Enum.TextXAlignment.Left,Parent=cell})
        local valLbl = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=entry.Val,TextColor3=entry.Col,TextSize=16,
            Position=UDim2.new(0,8,0,22),Size=UDim2.new(1,-16,0,20),
            TextXAlignment=Enum.TextXAlignment.Left,Parent=cell})
        heatCells[idx] = { Cell=cell, ValLbl=valLbl, KeyLbl=keyLbl }
    end

    -- Correction history sparkline (last 20 sessions: green=lingered, red=corrected)
    local _, sSparkline = makeSection(pageSARP, "Correction History")
    local sparkRow = mk("Frame",{BackgroundColor3=Color3.fromRGB(242,238,232),
        Size=UDim2.new(1,0,0,28),Parent=sSparkline})
    addCorner(sparkRow,UDim.new(0,6)); addStroke(sparkRow,1,0.3)
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,2),
        VerticalAlignment=Enum.VerticalAlignment.Center,Parent=sparkRow})
    mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),
        PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=sparkRow})
    local sparkBars = {}
    for i = 1, 20 do
        local bar = mk("Frame",{BackgroundColor3=Color3.fromRGB(210,205,198),
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.None,
            LayoutOrder=i,Parent=sparkRow})
        bar.Size = UDim2.new(0, 12, 0, 18)
        addCorner(bar,UDim.new(0,3))
        sparkBars[i] = bar
    end

    local sparkNoteLbl = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="No history yet. Launch payloads to populate.",
        TextColor3=Color3.fromRGB(150,145,138),TextSize=10,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,0,0,14),Parent=sSparkline})

    local function doRefreshHeat()
        -- ── AC Heat ────────────────────────────────────────────
        -- Derived from LWM remoteFires temporal average vs threshold
        local avgFires = LWM.GetTemporalAverage("remoteFires", 3) or 0
        local heat = math.min(100, math.floor(avgFires / SARP_CFG.ACFiresThreshold * 100))
        local heatStr = tostring(heat) .. "%"
        local heatCol = heat > 70 and Color3.fromRGB(220,60,60)
            or heat > 40 and Color3.fromRGB(220,150,40)
            or Color3.fromRGB(60,180,80)

        -- ── Correction Rate ────────────────────────────────────
        -- Fraction of SARPLog entries where success=false
        local total, corrected = 0, 0
        for _, e in ipairs(SARPLog) do
            total = total + 1
            if not e.Success then corrected = corrected + 1 end
        end
        local corrRate = total > 0 and math.floor(corrected/total*100) or 0
        local corrStr  = tostring(corrRate) .. "% (" .. tostring(corrected) .. "/" .. tostring(total) .. ")"
        local corrCol  = corrRate > 60 and Color3.fromRGB(220,60,60)
            or corrRate > 30 and Color3.fromRGB(220,150,40)
            or Color3.fromRGB(60,180,80)

        -- ── Echo Window ────────────────────────────────────────
        local echoWin = SARP_CFG.EchoWindowEst or 0.06
        -- Combine per-channel estimates
        local ewAttr = SARP_GetEchoWindow("Attribute")
        local ewOC   = SARP_GetEchoWindow("OwnedCarrier")
        local ewAB   = SARP_GetEchoWindow("AttachmentBridge")
        local ewStr  = string.format("A:%.0fms OC:%.0fms AB:%.0fms",
            ewAttr*1000, ewOC*1000, ewAB*1000)
        local ewCol  = Color3.fromRGB(72,120,200)

        -- ── Evasion Score (Brier-calibrated) ──────────────────
        -- Uses ETM Brier score if available; lower Brier = better calibration
        -- Evasion = 1 - correctionRate (adjusted by ETM mean confidence)
        local etmKeys, etmSum = 0, 0
        for cardID, _ in pairs(ETM.GetTableRef()) do
            if cardID:find("^sarp_") then
                local p, _, _ = ETM.Predict(cardID, RAE_State.CurrentSig or "unknown")
                etmSum = etmSum + p; etmKeys = etmKeys + 1
            end
        end
        local etmMean    = etmKeys > 0 and (etmSum / etmKeys) or 0.5
        local evasionPct = math.floor(etmMean * (1 - corrRate/100) * 100)
        local evasionStr = tostring(evasionPct) .. "%"
        local evasionCol = evasionPct > 65 and Color3.fromRGB(60,180,80)
            or evasionPct > 35 and Color3.fromRGB(220,150,40)
            or Color3.fromRGB(220,60,60)

        -- ── Linger Rate ───────────────────────────────────────
        local lingerCount = total - corrected
        local lingerPct   = total > 0 and math.floor(lingerCount/total*100) or 0
        local lingerStr   = tostring(lingerPct) .. "% (" .. tostring(lingerCount) .. " lingered)"
        local lingerCol   = lingerPct > 60 and Color3.fromRGB(60,180,80)
            or lingerPct > 30 and Color3.fromRGB(220,150,40)
            or Color3.fromRGB(220,60,60)

        -- ── Cascade Success ───────────────────────────────────
        local casTotal, casOK = 0, 0
        for _, e in ipairs(SARP_CascadeLog) do
            casTotal = casTotal + 1
            if e.success then casOK = casOK + 1 end
        end
        local casPct = casTotal > 0 and math.floor(casOK/casTotal*100) or 0
        local casStr = casTotal > 0
            and (tostring(casPct) .. "% (" .. tostring(casOK) .. "/" .. tostring(casTotal) .. ")")
            or "No cascade runs"
        local casCol = casPct > 60 and Color3.fromRGB(60,180,80)
            or casPct > 30 and Color3.fromRGB(220,150,40)
            or Color3.fromRGB(140,140,140)

        -- Apply to grid cells
        local vals = {
            { heatStr,    heatCol    },
            { corrStr,    corrCol    },
            { ewStr,      ewCol      },
            { evasionStr, evasionCol },
            { lingerStr,  lingerCol  },
            { casStr,     casCol     },
        }
        for i, cell in ipairs(heatCells) do
            cell.ValLbl.Text           = vals[i][1]
            cell.ValLbl.TextColor3     = vals[i][2]
            cell.Cell.BackgroundColor3 = Color3.fromRGB(248,245,240)
        end

        -- Highlight AC Heat cell if elevated
        if heat > 70 then
            heatCells[1].Cell.BackgroundColor3 = Color3.fromRGB(255,235,235)
        end

        -- ── Sparkline ─────────────────────────────────────────
        local recentLog = {}
        for i = math.max(1, #SARPLog-19), #SARPLog do
            table.insert(recentLog, SARPLog[i])
        end
        sparkNoteLbl.Text = #recentLog == 0
            and "No history yet. Launch payloads to populate."
            or string.format("Last %d launches  |  green=lingered  red=corrected  grey=pending", #recentLog)

        for i = 1, 20 do
            local bar = sparkBars[i]
            local entry = recentLog[i]
            if entry then
                bar.BackgroundColor3 = entry.Success
                    and Color3.fromRGB(80, 200, 100)
                    or  Color3.fromRGB(220, 80, 80)
            else
                bar.BackgroundColor3 = Color3.fromRGB(210, 205, 198)
            end
        end
    end

    -- Refresh heat button
    local heatRefreshRow = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,40),Parent=sHeat})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        Padding=UDim.new(0,10),Parent=heatRefreshRow})
    local heatRefreshBtn = makeButton(heatRefreshRow,"Refresh Heat",UDim2.new(0,160,0,36),"🌡")
    heatRefreshBtn.Button.BackgroundColor3 = Color3.fromRGB(255,235,210)
    local cascadeTestBtn = makeButton(heatRefreshRow,"Run Cascade",UDim2.new(0,150,0,36),"📡")
    cascadeTestBtn.Button.BackgroundColor3 = Color3.fromRGB(220,235,255)

    heatRefreshBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(heatRefreshBtn.Button)
        doRefreshHeat()
    end)

    cascadeTestBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(cascadeTestBtn.Button)
        if not SARP_CurrentWrapped then
            sendNotification("Build a payload first (Simulate), then run Cascade.", "Warning")
            return
        end
        local payload = SARP_CurrentWrapped.Payload or ""
        local payloadStr = type(payload)=="string" and payload or tostring(payload)
        sendNotification("Cascade starting — targeting nearby players...", "Info")
        SARP.Cascade.Run(payloadStr, 3, function(results, status)
            local ok = 0
            for _, r in ipairs(results) do if r.Success then ok=ok+1 end end
            sendNotification(string.format(
                "Cascade %s — %d/%d targets lingered",
                status, ok, #results), ok > 0 and "Success" or "Warning")
            doRefreshHeat()
            updateSARPStatus()
        end)
    end)

    -- Seed patterns on load
    task.defer(function()
        doRefreshPatterns()
        doRefreshETMSARP()
        doRefreshHeat()
        updateSARPStatus()
    end)
end
