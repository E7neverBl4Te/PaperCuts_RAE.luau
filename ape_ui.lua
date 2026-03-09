-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC
local _U = _G.PCU
local mk             = _C.mk
local addCorner      = _C.addCorner
local addStroke      = _C.addStroke
local pulseClick     = _C.pulseClick
local hookHover      = _C.hookHover
local tween          = _C.tween
local clickSound     = _C.clickSound
local makeButton     = _U.makeButton
local makeChip       = _U.makeChip
local makeSection    = _U.makeSection
local sendNotification = _U.sendNotification
local pageAPE        = _U.pageAPE

-- ============================================================
-- PAGE: APE — Active Probing Engine
-- Sub-tabs: Overview · Queue · Campaigns · Techniques · Launch
-- ============================================================

do
    local COL = {
        BG    = Color3.fromRGB(245, 241, 235),
        CARD  = Color3.fromRGB(238, 233, 226),
        TEXT  = Color3.fromRGB(48, 42, 36),
        MUTED = Color3.fromRGB(124, 114, 102),
        GREEN = Color3.fromRGB(50, 173, 70),
        AMBER = Color3.fromRGB(206, 144, 30),
        RED   = Color3.fromRGB(206, 56, 56),
        BLUE  = Color3.fromRGB(56, 116, 206),
        PURP  = Color3.fromRGB(134, 74, 198),
        TEAL  = Color3.fromRGB(36, 156, 146),
        ORANGE= Color3.fromRGB(210, 96, 40),
    }

    local STATUS_COL = {
        PENDING   = Color3.fromRGB(124,114,102),
        RUNNING   = Color3.fromRGB(56,116,206),
        COMPLETE  = Color3.fromRGB(50,173,70),
        SATURATED = Color3.fromRGB(206,144,30),
        ABORTED   = Color3.fromRGB(206,56,56),
    }
    local GOAL_COL = {
        CAUSAL       = Color3.fromRGB(56,116,206),
        VALIDATION   = Color3.fromRGB(206,144,30),
        RATE_PROFILE = Color3.fromRGB(134,74,198),
        AC_PROFILE   = Color3.fromRGB(206,56,56),
        CLASSIFY     = Color3.fromRGB(50,173,70),
    }

    local function confColor(c)
        if c >= 0.70 then return COL.GREEN
        elseif c >= 0.40 then return COL.AMBER
        else return COL.RED end
    end
    local function confBar(parent, conf, lo)
        local bg = mk("Frame", {BackgroundColor3=Color3.fromRGB(222,216,208),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,5), LayoutOrder=lo or 99, Parent=parent})
        addCorner(bg, UDim.new(0,3))
        local fill = mk("Frame", {BackgroundColor3=confColor(conf), BorderSizePixel=0,
            Size=UDim2.new(math.clamp(conf,0,1),0,1,0), Parent=bg})
        addCorner(fill, UDim.new(0,3))
        return bg, fill
    end
    local function colorChip(parent, text, color)
        local chip = makeChip(parent, text)
        chip.BackgroundColor3 = color or COL.MUTED
        local lbl = chip:FindFirstChildOfClass("TextLabel")
        if lbl then lbl.TextColor3 = Color3.fromRGB(255,255,255) end
        return chip
    end

    -- ── Sub-tab system ─────────────────────────────────────────────────────────
    local SUB_TABS = {"Overview","Queue","Campaigns","Techniques","Launch"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab = nil

    local tabBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(238,233,225),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,38), Parent=pageAPE})
    addStroke(tabBar, 1, 0.4)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,4), Parent=tabBar})
    mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageAPE})

    local function makeSubPage()
        local p = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=4,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(170,160,148), Visible=false, Parent=subContent})
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,10), Parent=p})
        return p
    end

    for _, name in ipairs(SUB_TABS) do
        local btn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(246,241,236), BorderSizePixel=0,
            Size=UDim2.new(0,96,0,28), Font=Enum.Font.GothamMedium,
            Text=name, TextColor3=COL.MUTED, TextSize=11, Parent=tabBar})
        addCorner(btn, UDim.new(0,8)); addStroke(btn, 1, 0.4)
        subTabBtns[name]  = btn
        subTabPages[name] = makeSubPage()
    end

    local function switchSubTab(name)
        if activeSubTab == name then return end
        for n, p in pairs(subTabPages) do p.Visible = (n==name) end
        for n, b in pairs(subTabBtns) do
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = n==name and Color3.fromRGB(232,226,216) or Color3.fromRGB(246,241,236),
                TextColor3       = n==name and COL.TEXT or COL.MUTED,
            })
        end
        activeSubTab = name
    end
    for name, btn in pairs(subTabBtns) do
        btn.MouseButton1Click:Connect(function() clickSound(); switchSubTab(name) end)
    end

    -- ── TAB: Overview ──────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Overview"]

        local _, sStats = makeSection(pg, "Engine Status")
        local statsLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Loading...", TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,64), Parent=sStats})

        -- Status indicator row
        local statusRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,28), Parent=sStats})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,8), Parent=statusRow})
        local runIndicator = mk("Frame", {BackgroundColor3=COL.RED,
            BorderSizePixel=0, Size=UDim2.new(0,12,0,12), Parent=statusRow})
        addCorner(runIndicator, UDim.new(0,999))
        local runLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="STOPPED", TextColor3=COL.RED, TextSize=12,
            Size=UDim2.new(0,80,0,20), TextXAlignment=Enum.TextXAlignment.Left,
            Parent=statusRow})

        -- Technique breakdown
        local _, sTech = makeSection(pg, "APE-Native Techniques")
        local TECH_NAMES = {
            "RSMBoundaryRefinement",
            "RSMEnumExpansion",
            "SpacedRateProbe",
            "CausalIsolationProbe",
            "CascadeProbe",
            "ValidationCrossCheck",
        }
        local TECH_DESC = {
            "Binary-searches numeric boundaries using RSM SuccessValues/FailValues",
            "Expands known passing strings with suffix/prefix/case variants",
            "Fires at geometric time intervals to profile throttle floor curve",
            "EchoDiff with 3s quiescence wait for clean causal attribution",
            "Fires primary then immediately fires known cascade target chain",
            "Probes at boundary ± ε to sharpen RANGE_CHECK boundary precision",
        }
        local TECH_COL2 = {COL.BLUE, COL.PURP, COL.TEAL, COL.GREEN, COL.ORANGE, COL.AMBER}
        for i, name in ipairs(TECH_NAMES) do
            local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(242,237,230),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,38),
                LayoutOrder=i, Parent=sTech})
            addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                PaddingTop=UDim.new(0,5), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            local dot = mk("Frame", {BackgroundColor3=TECH_COL2[i],
                BorderSizePixel=0, Size=UDim2.new(0,8,0,8), Parent=r1})
            addCorner(dot, UDim.new(0,999))
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=name, TextColor3=COL.TEXT, TextSize=10,
                Size=UDim2.new(1,0,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=TECH_DESC[i], TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=row})
        end

        local function doRefreshOverview()
            local APE = _G.PC.APE
            if not APE then statsLabel.Text = "APE not loaded."; return end
            local stats = APE.GetStats()
            statsLabel.Text = string.format(
                "Running: %s\nActive campaigns: %d / %d max   Total: %d\n"..
                "Total probes fired: %d   Queue depth: %d   Saturated: %d",
                tostring(stats.Running),
                stats.ActiveCampaigns, 3, stats.TotalCampaigns,
                stats.TotalProbesFired, stats.QueueDepth, stats.SaturatedRemotes)
            local running = stats.Running
            tween(runIndicator, TweenInfo.new(0.2), {BackgroundColor3=running and COL.GREEN or COL.RED})
            runLabel.Text  = running and "RUNNING" or "STOPPED"
            runLabel.TextColor3 = running and COL.GREEN or COL.RED
        end

        local btnRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=btnRow})
        local btnScan   = makeButton(btnRow, "Scan Now", UDim2.new(0,130,0,34), "🔍")
        local btnStop   = makeButton(btnRow, "Stop", UDim2.new(0,90,0,34), "■")
        local btnResume = makeButton(btnRow, "Resume", UDim2.new(0,100,0,34), "▶")
        local btnSave   = makeButton(btnRow, "Save", UDim2.new(0,90,0,34), "💾")
        btnScan.Button.BackgroundColor3   = Color3.fromRGB(220,235,255)
        btnStop.Button.BackgroundColor3   = Color3.fromRGB(255,225,220)
        btnResume.Button.BackgroundColor3 = Color3.fromRGB(220,255,220)

        btnScan.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnScan.Button)
            local APE = _G.PC.APE
            if APE then
                local n = APE.Scan()
                sendNotification(string.format("APE scan: launched %d campaign(s).", n), "Info")
                doRefreshOverview()
            end
        end)
        btnStop.Button.MouseButton1Click:Connect(function()
            clickSound(); local APE = _G.PC.APE
            if APE then APE.Stop(); doRefreshOverview() end
        end)
        btnResume.Button.MouseButton1Click:Connect(function()
            clickSound(); local APE = _G.PC.APE
            if APE then APE.Resume(); doRefreshOverview() end
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); local APE = _G.PC.APE
            if APE then APE.Save(); sendNotification("APE state saved.", "Success") end
        end)
        task.defer(doRefreshOverview)
    end

    -- ── TAB: Queue — priority-ranked remote list ───────────────────────────────
    do
        local pg = subTabPages["Queue"]

        local _, sQ = makeSection(pg, "Priority Queue (ranked by information need)")
        local qHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sQ})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,5), Parent=qHolder})

        local function buildQueueRow(entry, order)
            local APE = _G.PC.APE
            local SBI = _G.PC.SBI
            local RSM = _G.PC.RSM
            local sbiRec = SBI and SBI.Get(entry.name)
            local rsmRec = RSM and RSM.Get(entry.name)
            local sat    = APE and APE.GetSaturation(entry.name)

            local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(244,239,233),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,54), LayoutOrder=order, Parent=qHolder})
            addCorner(row, UDim.new(0,10)); addStroke(row, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=row})

            -- Row 1: rank + name + score + SBI conf
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("#%d", order), TextColor3=COL.MUTED, TextSize=10,
                Size=UDim2.new(0,28,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=entry.name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,200,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("⚡%.3f", entry.score),
                TextColor3=confColor(math.min(1,entry.score)), TextSize=11,
                Size=UDim2.new(0,60,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            -- Row 2: SBI conf + RSM conf + saturation + goals
            local r2info = string.format("SBI %.0f%%  RSM %.0f%%  %s",
                (sbiRec and sbiRec.Confidence or 0)*100,
                (rsmRec and rsmRec.Confidence or 0)*100,
                (sat and sat.saturated) and "⚠ SATURATED" or "")
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=r2info, TextColor3=COL.MUTED, TextSize=9,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(0.7,0,0,12), LayoutOrder=2, Parent=row})

            -- Score bar
            confBar(row, math.min(1, entry.score / 1.5), 3)

            -- Launch button
            local launchBtn = mk("TextButton", {
                AutoButtonColor=false, BackgroundColor3=Color3.fromRGB(220,235,255),
                BorderSizePixel=0, Font=Enum.Font.GothamMedium,
                Text="▶ Campaign", TextColor3=COL.BLUE, TextSize=10,
                Size=UDim2.new(0,90,0,22), ZIndex=3,
                Position=UDim2.new(1,-94,0,5), Parent=row,
            })
            addCorner(launchBtn, UDim.new(0,6))
            hookHover(launchBtn, launchBtn.BackgroundColor3, Color3.fromRGB(200,220,255), 0.30, 0.12)
            launchBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(launchBtn)
                local APE2 = _G.PC.APE
                if APE2 then
                    local id, err = APE2.StartCampaign(entry.name)
                    if id then
                        sendNotification(string.format("Campaign #%d launched for %s", id, entry.name), "Success")
                    else
                        sendNotification("Could not launch: " .. tostring(err), "Warning")
                    end
                end
            end)
        end

        local function doRefreshQueue()
            for _, c in ipairs(qHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local APE = _G.PC.APE
            if not APE then return end
            local q = APE.GetQueue()
            if #q == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="Queue empty — all remotes are saturated or done.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=qHolder})
                return
            end
            for i, entry in ipairs(q) do
                buildQueueRow(entry, i)
                if i >= 40 then break end
            end
        end

        local btnRefQ = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRefQ.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefQ.Button); doRefreshQueue()
        end)
        subTabBtns["Queue"].MouseButton1Click:Connect(doRefreshQueue)
    end

    -- ── TAB: Campaigns — active + historical campaign list ─────────────────────
    do
        local pg = subTabPages["Campaigns"]

        local _, sCamp = makeSection(pg, "Campaigns")
        local campHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sCamp})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,7), Parent=campHolder})

        local function buildCampaignCard(c, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(244,239,233),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=campHolder})
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Header: id + name + status chip
            local hdr = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=hdr})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("[%d]", c.id), TextColor3=COL.MUTED, TextSize=10,
                Size=UDim2.new(0,28,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=c.remoteName, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,195,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})
            local schip = colorChip(hdr, c.status, STATUS_COL[c.status])
            schip.Size = UDim2.new(0,90,0,20)

            -- Goals row
            local gRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=2, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,4), Parent=gRow})
            for _, goal in ipairs(c.goals or {}) do
                local gStatus = c.goalStatus and c.goalStatus[goal] or "PENDING"
                local gc = colorChip(gRow, goal:sub(1,4), GOAL_COL[goal] or COL.MUTED)
                gc.Size = UDim2.new(0,52,0,18)
                if gStatus == "COMPLETE" or gStatus == "MET" then
                    gc.BackgroundColor3 = COL.GREEN
                end
            end

            -- Progress line
            local prog = string.format("Plans: %d/%d   Probes: %d   Conf: %.0f%%→%.0f%% (+%.0f%%)",
                c.planPtr, c.planCount, c.probesFired,
                (c.preConf or 0)*100, (c.lastConf or 0)*100, (c.confGain or 0)*100)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=prog, TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,13), LayoutOrder=3, Parent=card})

            -- Progress bar
            local pct = c.planCount > 0 and (c.planPtr / c.planCount) or 0
            confBar(card, pct, 4)
        end

        local showCompleted = true
        local function doRefreshCampaigns()
            for _, ch in ipairs(campHolder:GetChildren()) do
                if ch:IsA("Frame") then ch:Destroy() end
            end
            local APE = _G.PC.APE
            if not APE then return end
            local all = APE.GetCampaigns()
            if #all == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No campaigns yet. Use Queue or Launch tab.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=campHolder})
                return
            end
            local shown = 0
            for _, c in ipairs(all) do
                if showCompleted or c.status == "RUNNING" or c.status == "PENDING" then
                    buildCampaignCard(c, shown+1)
                    shown = shown + 1
                    if shown >= 30 then break end
                end
            end
        end

        local btnRefC = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        local btnToggle = makeButton(pg, "Hide Done", UDim2.new(0,120,0,34), "")
        btnRefC.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefC.Button); doRefreshCampaigns()
        end)
        btnToggle.Button.MouseButton1Click:Connect(function()
            clickSound()
            showCompleted = not showCompleted
            btnToggle.Button.Text = showCompleted and "Hide Done" or "Show All"
            doRefreshCampaigns()
        end)
        subTabBtns["Campaigns"].MouseButton1Click:Connect(doRefreshCampaigns)
    end

    -- ── TAB: Techniques — test individual APE techniques ──────────────────────
    do
        local pg = subTabPages["Techniques"]

        local _, sTE = makeSection(pg, "Generate Plans from APE Technique")
        local remoteBox = mk("TextBox", {BackgroundColor3=Color3.fromRGB(246,241,236),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sTE})
        addCorner(remoteBox, UDim.new(0,8)); addStroke(remoteBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=remoteBox})

        local TECH_BTN_NAMES = {
            "RSMBoundaryRefinement","RSMEnumExpansion","SpacedRateProbe",
            "CausalIsolationProbe","CascadeProbe","ValidationCrossCheck",
        }

        local _, sTBtns = makeSection(pg, "Select Technique")
        local tbtnRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sTBtns})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            FillDirection=Enum.FillDirection.Horizontal, Wraps=true,
            Wraps=true, Padding=UDim.new(0,6), Parent=tbtnRow})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Wraps=true, Padding=UDim.new(0,6), Parent=tbtnRow})

        local _, sPOut = makeSection(pg, "Generated Plans")
        local planOutLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Select a technique above.", TextColor3=COL.MUTED, TextSize=10,
            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,200), Parent=sPOut})

        local function runTech(techName)
            local APE = _G.PC.APE
            if not APE then return end
            local name = remoteBox.Text:match("^%s*(.-)%s*$")
            if name == "" then
                planOutLabel.Text = "Enter a remote name first."
                return
            end
            local techFn = APE.Techniques[techName]
            if not techFn then
                planOutLabel.Text = "Technique not found: " .. techName
                return
            end
            local RSM = _G.PC.RSM
            local PR  = _G.PC.PR_Registry
            local rsmRec = RSM and RSM.Get(name)
            local prRec  = PR and PR[name]
            local schema = {}
            if rsmRec and rsmRec.ArgSig then
                for _, a in ipairs(rsmRec.ArgSig) do
                    table.insert(schema, {
                        DominantType  = a.DominantType,
                        NumberMean    = a.NumberMean,
                        StringSamples = a.SuccessStrings,
                    })
                end
            elseif prRec and prRec.ArgSchema then
                schema = prRec.ArgSchema
            end

            local ok, plans = pcall(techFn, name, schema)
            if not ok then
                planOutLabel.Text = "Error: " .. tostring(plans)
                return
            end
            if type(plans) ~= "table" or #plans == 0 then
                planOutLabel.Text = "No plans generated. RSM/SBI data may be insufficient for this technique."
                return
            end

            local lines = {string.format("Generated %d plan(s) via %s:", #plans, techName), ""}
            for i, p in ipairs(plans) do
                table.insert(lines, string.format("[%d] kind=%s  expected=%s",
                    i, p.kind, p.expectedSignal or "?"))
                table.insert(lines, string.format("    %s", p.description or ""))
                if p.preDelay then
                    table.insert(lines, string.format("    preDelay=%.2fs", p.preDelay))
                end
                if i >= 12 then
                    table.insert(lines, string.format("    ... (%d more)", #plans - 12))
                    break
                end
            end
            planOutLabel.Text = table.concat(lines, "\n")
            planOutLabel.Size = UDim2.new(1,0,0, math.max(200, #lines * 14 + 10))
        end

        for i, techName in ipairs(TECH_BTN_NAMES) do
            local btn = makeButton(tbtnRow, techName:sub(1,18), UDim2.new(0,160,0,30), "")
            btn.Button.LayoutOrder = i
            btn.Button.BackgroundColor3 = Color3.fromRGB(236,230,220)
            local tn = techName
            btn.Button.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(btn.Button); runTech(tn)
            end)
        end
    end

    -- ── TAB: Launch — manual campaign launcher ─────────────────────────────────
    do
        local pg = subTabPages["Launch"]

        local _, sL = makeSection(pg, "Manual Campaign Launch")
        local launchBox = mk("TextBox", {BackgroundColor3=Color3.fromRGB(246,241,236),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sL})
        addCorner(launchBox, UDim.new(0,8)); addStroke(launchBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=launchBox})

        local _, sGoalSel = makeSection(pg, "Campaign Preview")
        local previewLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Enter a remote name and press Preview.", TextColor3=COL.MUTED, TextSize=10,
            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,120), Parent=sGoalSel})

        local function doPreview()
            local APE = _G.PC.APE
            if not APE then return end
            local name = launchBox.Text:match("^%s*(.-)%s*$")
            if name == "" then
                previewLabel.Text = "Enter a remote name."
                return
            end
            local score = APE.Score(name)
            local goals = APE.GoalPlanner.PlanGoals(name)
            local sat   = APE.GetSaturation(name)
            local SBI   = _G.PC.SBI
            local sbiRec = SBI and SBI.Get(name)

            local lines = {
                string.format("Remote:       %s", name),
                string.format("Priority:     %.4f", score),
                string.format("SBI conf:     %.0f%%  Logic: %s",
                    (sbiRec and sbiRec.Confidence or 0)*100,
                    (sbiRec and sbiRec.ServerLogic) or "UNKNOWN"),
                string.format("Saturated:    %s  (avg gain %.4f)",
                    tostring(sat.saturated),
                    sat.avgGain or 0),
                string.format("Goals (%d):   %s", #goals, table.concat(goals, ", ")),
            }
            if #goals == 0 then
                table.insert(lines, "⚠  No goals found — remote may already be sufficiently profiled.")
            end
            previewLabel.Text = table.concat(lines, "\n")
            previewLabel.Size = UDim2.new(1,0,0, math.max(120, #lines*16+8))
        end

        local btnPrev = makeButton(pg, "Preview", UDim2.new(0,130,0,34), "👁")
        local btnLaunch = makeButton(pg, "Launch Campaign", UDim2.new(0,170,0,34), "🚀")
        local btnRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=btnRow})
        btnPrev.Button.Parent = btnRow
        btnLaunch.Button.Parent = btnRow
        btnLaunch.Button.BackgroundColor3 = Color3.fromRGB(220,255,220)

        btnPrev.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnPrev.Button); doPreview()
        end)
        btnLaunch.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnLaunch.Button)
            local APE = _G.PC.APE
            if not APE then return end
            local name = launchBox.Text:match("^%s*(.-)%s*$")
            if name == "" then
                sendNotification("Enter a remote name.", "Warning"); return
            end
            local id, err = APE.StartCampaign(name)
            if id then
                sendNotification(string.format("Campaign #%d launched for %s.", id, name), "Success")
                switchSubTab("Campaigns")
            else
                sendNotification("Launch failed: " .. tostring(err), "Warning")
            end
        end)
    end

    -- ── Default ────────────────────────────────────────────────────────────────
    switchSubTab("Overview")
end
