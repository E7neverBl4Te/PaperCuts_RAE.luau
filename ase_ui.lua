-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC
local _U = _G.PCU
local mk               = _C.mk
local addCorner        = _C.addCorner
local addStroke        = _C.addStroke
local pulseClick       = _C.pulseClick
local hookHover        = _C.hookHover
local tween            = _C.tween
local clickSound       = _C.clickSound
local makeButton       = _U.makeButton
local makeChip         = _U.makeChip
local makeSection      = _U.makeSection
local sendNotification = _U.sendNotification
local pageASE          = _U.pageASE

-- ============================================================
-- PAGE: ASE — Autonomous Strategy Engine
-- Sub-tabs: Overview · Goals · Bedrock · Directives · Panel
--
-- The Script Execution Panel (Panel tab) is hidden by default
-- and only becomes active after Bedrock confirmation.
-- It contains:
--   Semantic Shell  — TSR intent autocomplete + execution
--   Protocol Forge  — hidden-by-default raw payload view
--   Transaction Buffer — live causal trace
--   Bedrock Heartbeat — circuit status indicator
-- Mastery Gate protects the dual-mode via typed passphrase.
-- ============================================================

do
    local COL = {
        -- Outer UI: warm parchment to match system palette
        BG     = Color3.fromRGB(246, 243, 238),
        CARD   = Color3.fromRGB(239, 235, 229),
        BORDER = Color3.fromRGB(200, 193, 184),
        TEXT   = Color3.fromRGB(46, 40, 34),
        MUTED  = Color3.fromRGB(122, 112, 100),
        -- Accent colors (kept vibrant for status/mode indicators)
        GREEN  = Color3.fromRGB(40, 168, 68),
        AMBER  = Color3.fromRGB(204, 142, 28),
        RED    = Color3.fromRGB(204, 54, 54),
        BLUE   = Color3.fromRGB(54, 114, 204),
        PURP   = Color3.fromRGB(132, 72, 196),
        TEAL   = Color3.fromRGB(34, 154, 144),
        ORANGE = Color3.fromRGB(208, 94, 38),
        -- Dark: used only inside Panel tab workspaces (Shell/Forge/TxBuffer)
        DARK   = Color3.fromRGB(28, 26, 32),
    }

    -- Dark terminal aesthetic for ASE
    local function mkDark(class, props)
        props.BackgroundColor3 = props.BackgroundColor3 or COL.CARD
        return mk(class, props)
    end
    local function confBar(parent, frac, lo, col)
        local bg = mk("Frame", {BackgroundColor3=Color3.fromRGB(200,194,184),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,4), LayoutOrder=lo or 99, Parent=parent})
        addCorner(bg, UDim.new(0,2))
        local fill = mk("Frame", {BackgroundColor3=col or COL.GREEN, BorderSizePixel=0,
            Size=UDim2.new(math.clamp(frac,0,1),0,1,0), Parent=bg})
        addCorner(fill, UDim.new(0,2))
        return bg, fill
    end
    local function statusDot(parent, color)
        local d = mk("Frame", {BackgroundColor3=color, BorderSizePixel=0,
            Size=UDim2.new(0,8,0,8), Parent=parent})
        addCorner(d, UDim.new(0,999))
        return d
    end

    -- ── Sub-tab system ─────────────────────────────────────────────────────────
    local SUB_TABS = {"Overview","Goals","Bedrock","Directives","AACG","Panel"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab = nil

    local tabBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(237,232,224),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,38), Parent=pageASE})
    addStroke(tabBar, 1, 0.6)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})
    mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {BackgroundColor3=Color3.fromRGB(246,243,238), BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageASE})

    local function makeSubPage()
        local p = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=3,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(80,80,90), Visible=false, Parent=subContent})
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,10), Parent=p})
        return p
    end

    local PANEL_SUB = "Panel"
    for _, name in ipairs(SUB_TABS) do
        local isPanelTab = (name == PANEL_SUB)
        local btn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(225,220,212), BorderSizePixel=0,
            Size=UDim2.new(0,96,0,28), Font=Enum.Font.GothamMedium,
            Text= isPanelTab and "⬛ Panel" or (name == "AACG" and "⚡ AACG" or name),
            TextColor3=Color3.fromRGB(90,80,70),
            TextSize=11, Parent=tabBar})
        addCorner(btn, UDim.new(0,6)); addStroke(btn, 1, 0.4)

        -- Panel and AACG tabs are raw Frames (not scroll) — built custom
        if isPanelTab or name == "AACG" then
            local p = mk("Frame", {BackgroundColor3=COL.BG, BorderSizePixel=0,
                Size=UDim2.new(1,0,1,0), ClipsDescendants=true,
                Visible=false, Parent=subContent})
            subTabPages[name] = p
        else
            subTabPages[name] = makeSubPage()
        end
        subTabBtns[name] = btn
    end

    local function switchSubTab(name)
        if activeSubTab == name then return end
        for n, p in pairs(subTabPages) do p.Visible = (n==name) end
        for n, b in pairs(subTabBtns) do
            local active = (n==name)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = active and Color3.fromRGB(200,194,184) or Color3.fromRGB(225,220,212),
                TextColor3       = active and Color3.fromRGB(40,34,28) or Color3.fromRGB(90,80,70),
            })
        end
        activeSubTab = name
    end
    for name, btn in pairs(subTabBtns) do
        local n = name
        btn.MouseButton1Click:Connect(function() clickSound(); switchSubTab(n) end)
    end

    -- ── Heartbeat pulsing indicator (shared state) ─────────────────────────────
    local heartbeatDot = nil  -- set in Panel tab, pulsed from loop

    -- ── TAB: Overview ──────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Overview"]

        local _, sStatus = makeSection(pg, "Engine Status")
        sStatus.BackgroundColor3 = COL.CARD; addStroke(sStatus, 1, 0.5)

        local statusGrid = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sStatus})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=statusGrid})
        local statsLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="Loading...", TextColor3=COL.MUTED,
            TextSize=11, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=statusGrid})

        -- Risk budget bar
        local _, sRisk = makeSection(pg, "Session Risk Budget")
        sRisk.BackgroundColor3 = COL.CARD; addStroke(sRisk, 1, 0.5)
        local riskLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=COL.AMBER, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,16), Parent=sRisk})
        local _, riskFill = confBar(sRisk, 0, 99, COL.GREEN)

        -- Forward declare so mode-button closures can close over it
        local doRefreshOverview

        -- Mode selector
        local _, sModeRow = makeSection(pg, "Execution Mode")
        sModeRow.BackgroundColor3 = COL.CARD; addStroke(sModeRow, 1, 0.5)
        local modeRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,36), Parent=sModeRow})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,8), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=modeRow})

        local MODE_BTNS = {
            { label="⬛ Compiled", mode="COMPILED", col=COL.BLUE  },
            { label="⚙ Raw",      mode="RAW",      col=COL.ORANGE },
            { label="⚡ Mastery", mode="MASTERY",  col=COL.PURP  },
        }
        local modeButtons = {}
        for _, mb in ipairs(MODE_BTNS) do
            local btn = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=Color3.fromRGB(225,220,212), BorderSizePixel=0,
                Font=Enum.Font.GothamMedium, Text=mb.label,
                TextColor3=Color3.fromRGB(90,80,70), TextSize=11,
                Size=UDim2.new(0,110,0,30), Parent=modeRow})
            addCorner(btn, UDim.new(0,8)); addStroke(btn, 1, 0.4)
            local bmode = mb.mode; local bcol = mb.col
            modeButtons[bmode] = { btn=btn, col=bcol }
            btn.MouseButton1Click:Connect(function()
                clickSound()
                local ASE = _G.PC.ASE
                if not ASE then return end
                if bmode == "MASTERY" and not ASE.IsMasteryUnlocked() then
                    -- Show mastery gate overlay (built below)
                    _G._ASE_ShowMasteryGate = true
                    return
                end
                -- Already in this mode — just refresh visuals, no error
                if ASE.GetMode() == bmode then
                    if doRefreshOverview then doRefreshOverview() end
                    return
                end
                local ok, err = ASE.SetMode(bmode)
                if ok then
                    sendNotification("Mode: " .. bmode, "Success")
                    if doRefreshOverview then doRefreshOverview() end
                else
                    sendNotification(tostring(err), "Warning")
                end
            end)
        end

        doRefreshOverview = function()
            local ASE = _G.PC.ASE
            if not ASE then statsLabel.Text = "ASE not loaded."; return end
            local stats = ASE.GetStats()
            statsLabel.Text = string.format(
                "Mode: %-12s  Mastery: %s\n"..
                "Panel: %-10s  Heartbeat: %s\n"..
                "Active Sink: %s\n"..
                "Feedback:    %s\n"..
                "Goals: %d active / %d total   Directives: %d",
                stats.Mode, tostring(stats.MasteryUnlocked),
                tostring(stats.PanelVisible), tostring(stats.HeartbeatAlive),
                stats.ActiveSink or "none",
                stats.ActiveFeedback or "none",
                stats.ActiveGoals, stats.GoalCount, stats.DirectiveCount)

            local rb = ASE.GetRiskBudget()
            riskLabel.Text = string.format("%.0f%% consumed  (%.3f / %.3f)",
                rb.pct*100, rb.consumed, rb.total)
            riskFill.Size  = UDim2.new(math.clamp(rb.pct,0,1),0,1,0)
            riskFill.BackgroundColor3 = rb.pct < 0.5 and COL.GREEN
                or rb.pct < 0.8 and COL.AMBER or COL.RED

            -- Highlight active mode button
            local mode = stats.Mode
            for bmode, mb in pairs(modeButtons) do
                local active = (bmode == mode)
                tween(mb.btn, TweenInfo.new(0.1), {
                    BackgroundColor3 = active and mb.col or Color3.fromRGB(225,220,212),
                    TextColor3       = active and Color3.fromRGB(255,255,255) or COL.MUTED,
                })
            end
        end

        local btnRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,10), Parent=btnRow})
        local btnRef  = makeButton(btnRow, "Refresh",      UDim2.new(0,110,0,32), "🔄")
        local btnSave = makeButton(btnRow, "Save",         UDim2.new(0,100,0,32), "💾")
        local btnReset= makeButton(btnRow, "Reset Budget", UDim2.new(0,130,0,32), "↺")
        for _, b in ipairs({btnRef,btnSave,btnReset}) do
            b.Button.BackgroundColor3 = COL.CARD
            b.Button.TextColor3 = COL.TEXT
            addStroke(b.Button, 1, 0.5)
        end
        btnRef.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRef.Button); doRefreshOverview()
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); local ASE = _G.PC.ASE
            if ASE then ASE.Save(); sendNotification("ASE state saved.", "Success") end
        end)
        btnReset.Button.MouseButton1Click:Connect(function()
            clickSound(); local ASE = _G.PC.ASE
            if ASE then ASE.ResetRiskBudget(); doRefreshOverview() end
        end)
        task.defer(doRefreshOverview)
    end

    -- ── TAB: Goals ─────────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Goals"]

        local _, sGL = makeSection(pg, "Goal Queue")
        sGL.BackgroundColor3 = COL.CARD; addStroke(sGL, 1, 0.5)
        local goalHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sGL})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=goalHolder})

        local STATUS_COL = {
            PENDING=COL.MUTED,  RUNNING=COL.BLUE, COMPLETE=COL.GREEN,
            FAILED=COL.RED, ABORTED=COL.AMBER,
        }

        -- Tracks which card is currently selected (for highlight reset)
        local selectedCard = nil

        -- Forward-declare remoteBox2 so buildGoalCard closures can close over it
        local remoteBox2

        local function buildGoalCard(g, order)
            local isComplete = g.status == "COMPLETE"
            local isDiscover = g.goalType == "DISCOVER"
            local remoteName = g.params and (g.params.remoteName or g.params.sinkRemote) or ""
            local selectable = isComplete and isDiscover and remoteName ~= ""

            -- Card height: taller for selectable (extra action row)
            local cardH = selectable and 72 or 52

            local card = mk("Frame", {
                BackgroundColor3 = selectable
                    and Color3.fromRGB(236,248,240)   -- soft green tint for complete discovers
                    or  Color3.fromRGB(235,232,227),  -- warm neutral for everything else
                BorderSizePixel=0, Size=UDim2.new(1,0,0,cardH),
                LayoutOrder=order, Parent=goalHolder})
            addCorner(card, UDim.new(0,8))
            addStroke(card, selectable and 1.5 or 1, selectable and 0.3 or 0.4)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), SortOrder=Enum.SortOrder.LayoutOrder,
                Parent=card})

            -- Row 1: id + type + status dot + status text + duration
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("[%d] %s", g.id, g.goalType),
                TextColor3=STATUS_COL[g.status] or COL.TEXT, TextSize=11,
                Size=UDim2.new(0,160,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            statusDot(r1, STATUS_COL[g.status] or COL.MUTED)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=g.status, TextColor3=STATUS_COL[g.status] or COL.MUTED, TextSize=10,
                Size=UDim2.new(0,80,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            if g.endT and g.startT then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("%.1fs", g.endT - g.startT),
                    TextColor3=COL.MUTED, TextSize=9,
                    Size=UDim2.new(0,50,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})
            end

            -- Row 2: detail / remote name
            local detail = g.error or
                (g.result and (g.result.confirmed ~= nil)
                    and (g.result.confirmed and "✓ " .. tostring(g.result.feedbackRemote) or "✗ no return")
                    or (g.result and g.result.status or ""))
                or remoteName
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=tostring(detail):sub(1,70), TextColor3=COL.MUTED, TextSize=9,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=card})

            -- Row 3 (selectable complete DISCOVER only): remote chip + action buttons
            if selectable then
                local r3 = mk("Frame", {BackgroundTransparency=1,
                    Size=UDim2.new(1,0,0,22), LayoutOrder=3, Parent=card})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6),
                    Parent=r3})

                -- Remote name chip
                local chip = mk("TextLabel", {
                    BackgroundColor3=Color3.fromRGB(210,240,220), BorderSizePixel=0,
                    Font=Enum.Font.Code, Text=" 📡 " .. remoteName .. " ",
                    TextColor3=Color3.fromRGB(30,100,50), TextSize=9,
                    Size=UDim2.new(0, math.min(#remoteName*6+32, 200), 0, 18),
                    Parent=r3})
                addCorner(chip, UDim.new(0,4))

                -- Select button: fills remoteBox2
                local selBtn = mk("TextButton", {AutoButtonColor=false,
                    BackgroundColor3=COL.TEAL, BorderSizePixel=0,
                    Font=Enum.Font.GothamMedium, Text="Select",
                    TextColor3=Color3.fromRGB(255,255,255), TextSize=9,
                    Size=UDim2.new(0,52,0,18), Parent=r3})
                addCorner(selBtn, UDim.new(0,4))

                -- Quick Bedrock button: select + push Bedrock in one click
                local brBtn = mk("TextButton", {AutoButtonColor=false,
                    BackgroundColor3=Color3.fromRGB(34,154,144), BorderSizePixel=0,
                    Font=Enum.Font.GothamBold, Text="→ Bedrock",
                    TextColor3=Color3.fromRGB(255,255,255), TextSize=9,
                    Size=UDim2.new(0,72,0,18), Parent=r3})
                addCorner(brBtn, UDim.new(0,4))

                -- Select handler: highlight card + fill input
                selBtn.MouseButton1Click:Connect(function()
                    clickSound()
                    -- Reset previous selection
                    if selectedCard and selectedCard ~= card then
                        pcall(function()
                            addStroke(selectedCard, 1.5, 0.3)
                            selectedCard.BackgroundColor3 = Color3.fromRGB(236,248,240)
                        end)
                    end
                    selectedCard = card
                    -- Highlight this card with a teal border
                    addStroke(card, 2, 0.0)
                    card.BackgroundColor3 = Color3.fromRGB(220,245,232)
                    -- Fill the input
                    remoteBox2.Text = remoteName
                    sendNotification(remoteName .. " selected.", "Success")
                end)

                -- One-click Bedrock handler
                brBtn.MouseButton1Click:Connect(function()
                    clickSound(); pulseClick(brBtn)
                    remoteBox2.Text = remoteName
                    local ASE2 = _G.PC.ASE
                    if ASE2 then
                        ASE2.PursueBedrock(remoteName)
                        sendNotification("Bedrock goal pushed for " .. remoteName, "Success")
                        task.wait(0.3)
                        if doRefreshGoals then doRefreshGoals() end
                    end
                end)

                -- Also make the whole card clickable as a Select shortcut
                card.InputBegan:Connect(function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                        if selectedCard and selectedCard ~= card then
                            pcall(function()
                                addStroke(selectedCard, 1.5, 0.3)
                                selectedCard.BackgroundColor3 = Color3.fromRGB(236,248,240)
                            end)
                        end
                        selectedCard = card
                        addStroke(card, 2, 0.0)
                        card.BackgroundColor3 = Color3.fromRGB(220,245,232)
                        remoteBox2.Text = remoteName
                    end
                end)
            end
        end

        -- Forward declare so push-button closures can close over it
        local doRefreshGoals

        local _, sPush = makeSection(pg, "Push Goal")
        sPush.BackgroundColor3 = COL.CARD; addStroke(sPush, 1, 0.5)
        remoteBox2 = mk("TextBox", {BackgroundColor3=Color3.fromRGB(232,228,220),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText="Remote name for BEDROCK / DISCOVER...",
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEXT,
            TextSize=11, Size=UDim2.new(1,0,0,30), Parent=sPush})
        addCorner(remoteBox2, UDim.new(0,6)); addStroke(remoteBox2, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=remoteBox2})
        local pushBtnRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,32), Parent=sPush})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,8), Parent=pushBtnRow})
        local PUSH_BTNS = {
            {label="Bedrock",   fn=function(n) if _G.PC.ASE then _G.PC.ASE.PursueBedrock(n) end end,  col=COL.TEAL},
            {label="Discover",  fn=function(n) if _G.PC.ASE then _G.PC.ASE.Discover(n)      end end,  col=COL.BLUE},
            {label="Recompile", fn=function(n) if _G.PC.ASE then _G.PC.ASE.Recompile(n)     end end,  col=COL.AMBER},
        }
        for _, pb in ipairs(PUSH_BTNS) do
            local b = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=pb.col, BorderSizePixel=0,
                Font=Enum.Font.GothamMedium, Text=pb.label,
                TextColor3=Color3.fromRGB(255,255,255), TextSize=11,
                Size=UDim2.new(0,92,0,30), Parent=pushBtnRow})
            addCorner(b, UDim.new(0,8))
            local pfn = pb.fn
            b.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(b)
                local name = remoteBox2.Text:match("^%s*(.-)%s*$")
                if name == "" then sendNotification("Enter a remote name.", "Warning"); return end
                pfn(name)
                sendNotification("Goal pushed: " .. pb.label, "Success")
                task.wait(0.3); doRefreshGoals()
            end)
        end

        doRefreshGoals = function()
            for _, c in ipairs(goalHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local ASE = _G.PC.ASE
            if not ASE then return end
            local goals = ASE.GetGoals()
            if #goals == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="No goals yet.", TextColor3=COL.MUTED, TextSize=11,
                    Size=UDim2.new(1,0,0,24), Parent=goalHolder})
                return
            end
            for i, g in ipairs(goals) do
                buildGoalCard(g, i)
                if i >= 24 then break end
            end
        end

        local btnRefG = makeButton(pg, "Refresh", UDim2.new(0,110,0,30), "🔄")
        btnRefG.Button.BackgroundColor3 = COL.CARD
        btnRefG.Button.TextColor3 = COL.TEXT
        addStroke(btnRefG.Button, 1, 0.5)
        btnRefG.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefG.Button); doRefreshGoals()
        end)
        -- Re-wire Goals button: switch page AND refresh cards
        subTabBtns["Goals"].MouseButton1Click:Connect(function()
            clickSound()
            switchSubTab("Goals")
            if doRefreshGoals then doRefreshGoals() end
        end)
    end

    -- ── TAB: Bedrock ────────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Bedrock"]

        local _, sBP = makeSection(pg, "Confirmed Bedrock Pairs (A → Server → B)")
        sBP.BackgroundColor3 = COL.CARD; addStroke(sBP, 1, 0.5)
        local pairHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sBP})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=pairHolder})

        local function buildPairCard(pair, order)
            local alive = pair.confidence >= 0.8
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(18,22,18),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,64),
                LayoutOrder=order, Parent=pairHolder})
            addCorner(card, UDim.new(0,8))
            addStroke(card, 1.5, alive and 0.2 or 0.6)
            if alive then card.BackgroundColor3 = Color3.fromRGB(18,26,20) end
            mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=card})

            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,8), Parent=r1})
            statusDot(r1, alive and COL.GREEN or COL.RED)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=pair.sinkRemote, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,150,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="→", TextColor3=COL.TEAL, TextSize=14,
                Size=UDim2.new(0,16,1,0), TextXAlignment=Enum.TextXAlignment.Center, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=pair.feedbackRemote or "?", TextColor3=COL.TEAL, TextSize=12,
                Size=UDim2.new(0,150,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=alive and "LIVE" or "DEAD",
                TextColor3=alive and COL.GREEN or COL.RED, TextSize=11,
                Size=UDim2.new(0,48,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("nonce prefix: %s   conf: %.0f%%",
                    pair.nonce and pair.nonce:sub(1,8) or "?",
                    (pair.confidence or 0)*100),
                TextColor3=COL.MUTED, TextSize=9,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=card})

            confBar(card, pair.confidence or 0, 3, alive and COL.GREEN or COL.RED)
        end

        local _, sCandidates = makeSection(pg, "Bedrock Candidates (from AVD findings)")
        sCandidates.BackgroundColor3 = COL.CARD; addStroke(sCandidates, 1, 0.5)
        local candLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Loading...", TextColor3=COL.MUTED, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,60), Parent=sCandidates})

        local function doRefreshBedrock()
            for _, c in ipairs(pairHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local ASE = _G.PC.ASE
            if not ASE then return end
            local pairs2 = ASE.GetBedrockPairs()
            if #pairs2 == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="No confirmed pairs yet.\nRun a Bedrock goal from the Goals tab.",
                    TextColor3=COL.MUTED, TextSize=11,
                    Size=UDim2.new(1,0,0,36), Parent=pairHolder})
            else
                for i, p in ipairs(pairs2) do buildPairCard(p, i) end
            end

            -- Candidates: AVD findings above threshold
            local strat = _G.PC.AVD and _G.PC.AVD.Strategist
            if strat then
                local findings = strat.GetFindings and strat.GetFindings(0.65) or {}
                local lines = {}
                for i, f in ipairs(findings) do
                    table.insert(lines, string.format("  [%.2f] %s  (%s / %s)",
                        f.exploitScore or 0, f.remoteName,
                        f.signal or "?", f.technique or "?"))
                    if i >= 8 then table.insert(lines, "  ..."); break end
                end
                candLabel.Text = #lines > 0 and table.concat(lines, "\n")
                    or "No high-confidence findings yet — run AVD."
                candLabel.Size = UDim2.new(1,0,0, math.max(60, #lines*14+8))
            end
        end

        local btnRefBR = makeButton(pg, "Refresh", UDim2.new(0,110,0,30), "🔄")
        btnRefBR.Button.BackgroundColor3 = COL.CARD
        btnRefBR.Button.TextColor3 = COL.TEXT
        addStroke(btnRefBR.Button, 1, 0.5)
        btnRefBR.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefBR.Button); doRefreshBedrock()
        end)
        subTabBtns["Bedrock"].MouseButton1Click:Connect(doRefreshBedrock)
    end

    -- ── TAB: Directives ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Directives"]

        local _, sDL = makeSection(pg, "Finalized Static Directives (Lifted from Raw)")
        sDL.BackgroundColor3 = COL.CARD; addStroke(sDL, 1, 0.5)
        local dirHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sDL})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,5), Parent=dirHolder})

        local function buildDirectiveCard(d, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(22,22,28),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,54),
                LayoutOrder=order, Parent=dirHolder})
            addCorner(card, UDim.new(0,8)); addStroke(card, 1, 0.4)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,8), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=d.name, TextColor3=COL.TEAL, TextSize=12,
                Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="[" .. (d.category or "Custom") .. "]",
                TextColor3=COL.PURP, TextSize=10,
                Size=UDim2.new(0,80,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="TSR ✓", TextColor3=COL.GREEN, TextSize=10,
                Size=UDim2.new(0,40,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            local envelopeStr = type(d.envelope) == "table"
                and tostring(next(d.envelope)) ~= nil
                and ("{" .. (function()
                    local parts = {}
                    for k,v in pairs(d.envelope) do
                        table.insert(parts, tostring(k).."="..tostring(v):sub(1,12))
                        if #parts >= 3 then table.insert(parts, "..."); break end
                    end
                    return table.concat(parts, ", ")
                end)() .. "}")
                or tostring(d.envelope)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="sink: " .. tostring(d.sinkRemote) .. "   " .. envelopeStr:sub(1,50),
                TextColor3=COL.MUTED, TextSize=9, TextWrapped=false,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=card})
        end

        local function doRefreshDirectives()
            for _, c in ipairs(dirHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local ASE = _G.PC.ASE
            if not ASE then return end
            local dirs = ASE.GetDirectives()
            if #dirs == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="No finalized directives yet.\nForge a raw payload and click Finalize.",
                    TextColor3=COL.MUTED, TextSize=11,
                    Size=UDim2.new(1,0,0,36), Parent=dirHolder})
                return
            end
            for i, d in ipairs(dirs) do buildDirectiveCard(d, i) end
        end

        local btnRefD2 = makeButton(pg, "Refresh", UDim2.new(0,110,0,30), "🔄")
        btnRefD2.Button.BackgroundColor3 = COL.CARD
        btnRefD2.Button.TextColor3 = COL.TEXT
        addStroke(btnRefD2.Button, 1, 0.5)
        btnRefD2.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefD2.Button); doRefreshDirectives()
        end)
        subTabBtns["Directives"].MouseButton1Click:Connect(doRefreshDirectives)
    end

    
    -- ── TAB: AACG — Autonomous Action Card Generator ─────────────────────────
    do
        local pg = subTabPages["AACG"]

        -- Dark base background
        pg.BackgroundColor3 = Color3.fromRGB(12, 11, 17)

        local COL_AACG = {
            BG       = Color3.fromRGB(12, 11, 17),
            CARD_BG  = Color3.fromRGB(20, 19, 28),
            CARD_BDR = Color3.fromRGB(38, 35, 52),
            HEADER   = Color3.fromRGB(80, 75, 110),
            TEXT     = Color3.fromRGB(210, 206, 235),
            MUTED    = Color3.fromRGB(75, 70, 95),
            TEAL     = Color3.fromRGB(40, 200, 155),
            AMBER    = Color3.fromRGB(220, 165, 40),
            RED      = Color3.fromRGB(220, 65, 65),
            PURP     = Color3.fromRGB(150, 100, 240),
            GOLD     = Color3.fromRGB(255, 195, 40),
            BLUE     = Color3.fromRGB(80, 150, 240),
            GREEN    = Color3.fromRGB(60, 200, 100),
        }

        -- Tier colors
        local TIER_COL = {
            LOCALIZED = COL_AACG.TEAL,
            SERVER    = COL_AACG.BLUE,
            OWNER     = COL_AACG.PURP,
        }
        local TIER_LABEL = {
            LOCALIZED = "Localized Server-Side",
            SERVER    = "Server-Side (All Players)",
            OWNER     = "⚡ Game Owner Rights",
        }

        -- ── TOP BAR: tier + category selectors ─────────────────────────────────
        local topBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(16,15,22),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,82), Parent=pg})
        addStroke(topBar, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=topBar})
        mk("UIListLayout", {Padding=UDim.new(0,8), Parent=topBar})

        -- Tier selector row
        local tierRowLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, Text="TIER",
            TextColor3=COL_AACG.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,12),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=topBar})

        local tierRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=2, Parent=topBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,6), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=tierRow})

        -- Category selector row
        local catRowLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, Text="CATEGORY",
            TextColor3=COL_AACG.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,12),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=3, Parent=topBar})

        local catRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,24), LayoutOrder=4, Parent=topBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,5), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=catRow})

        -- ── State ──────────────────────────────────────────────────────────────
        local selectedTier = "LOCALIZED"
        local selectedCat  = nil
        local tierBtns     = {}
        local catBtns      = {}
        local currentCards = {}
        local generatedLabel = nil

        -- ── Tier chips ─────────────────────────────────────────────────────────
        local TIERS = {"LOCALIZED", "SERVER", "OWNER"}
        local CAT_MAP = {
            LOCALIZED = {"Tools & Items", "Client Editing", "WorldState Control"},
            SERVER    = {"Admin Tools", "Player Editing", "WorldState Control"},
            OWNER     = {"Everything"},
        }

        local function refreshCatRow()
            for _, c in ipairs(catRow:GetChildren()) do
                if c:IsA("TextButton") then c:Destroy() end
            end
            catBtns = {}
            selectedCat = nil
            local cats = CAT_MAP[selectedTier] or {}
            for _, cat in ipairs(cats) do
                local cname = cat
                local cb = mk("TextButton", {AutoButtonColor=false,
                    BackgroundColor3=Color3.fromRGB(22,20,30), BorderSizePixel=0,
                    Font=Enum.Font.GothamMedium, Text=cname,
                    TextColor3=COL_AACG.MUTED, TextSize=10,
                    Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
                    Parent=catRow})
                addCorner(cb, UDim.new(0,5))
                addStroke(cb, 1, 0.5)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                    Parent=cb})
                catBtns[cname] = cb
                local ccat = cname
                cb.MouseButton1Click:Connect(function()
                    clickSound()
                    selectedCat = ccat
                    for n, b in pairs(catBtns) do
                        local active = (n == ccat)
                        local tcol = TIER_COL[selectedTier] or COL_AACG.TEAL
                        tween(b, TweenInfo.new(0.12), {
                            BackgroundColor3 = active
                                and Color3.fromRGB(28,26,38) or Color3.fromRGB(22,20,30),
                            TextColor3 = active and tcol or COL_AACG.MUTED,
                        })
                        if b:FindFirstChildOfClass("UIStroke") then
                            b:FindFirstChildOfClass("UIStroke").Color =
                                active and tcol or COL_AACG.CARD_BDR
                        end
                    end
                end)
            end
            -- Auto-select first category
            if #cats > 0 then
                catBtns[cats[1]].MouseButton1Click:Fire()
            end
        end

        for _, tierKey in ipairs(TIERS) do
            local tk = tierKey
            local tcol = TIER_COL[tk]
            local tb = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=Color3.fromRGB(22,20,30), BorderSizePixel=0,
                Font=Enum.Font.GothamMedium, Text=TIER_LABEL[tk],
                TextColor3=COL_AACG.MUTED, TextSize=10,
                Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
                Parent=tierRow})
            addCorner(tb, UDim.new(0,5))
            addStroke(tb, 1, 0.5)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                Parent=tb})
            tierBtns[tk] = tb
            tb.MouseButton1Click:Connect(function()
                clickSound()
                -- Owner tier requires Mastery
                if tk == "OWNER" then
                    local ASE2 = _G.PC and _G.PC.ASE
                    if not ASE2 or not ASE2.IsMasteryUnlocked() then
                        sendNotification("⚡ Mastery required for Game Owner tier.", "Warning")
                        return
                    end
                end
                selectedTier = tk
                for n, b in pairs(tierBtns) do
                    local active = (n == tk)
                    local ac = TIER_COL[n]
                    tween(b, TweenInfo.new(0.12), {
                        BackgroundColor3 = active
                            and Color3.fromRGB(28,26,38) or Color3.fromRGB(22,20,30),
                        TextColor3 = active and ac or COL_AACG.MUTED,
                    })
                    if b:FindFirstChildOfClass("UIStroke") then
                        b:FindFirstChildOfClass("UIStroke").Color =
                            active and ac or COL_AACG.CARD_BDR
                    end
                end
                refreshCatRow()
            end)
        end

        -- Select first tier by default
        tierBtns["LOCALIZED"].MouseButton1Click:Fire()

        -- ── GENERATE button bar ────────────────────────────────────────────────
        local genBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(16,15,22),
            BorderSizePixel=0,
            Position=UDim2.new(0,0,0,82), Size=UDim2.new(1,0,0,38),
            Parent=pg})
        addStroke(genBar, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=genBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,10), Parent=genBar})

        local genBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL_AACG.TEAL, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="⚡ Generate Cards",
            TextColor3=Color3.fromRGB(10,10,14), TextSize=11,
            Size=UDim2.new(0,140,1,-8), Parent=genBar})
        addCorner(genBtn, UDim.new(0,6))

        generatedLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="Select a tier and category, then generate.",
            TextColor3=COL_AACG.MUTED, TextSize=10,
            Size=UDim2.new(1,-158,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=genBar})

        -- ── CARD GRID ─────────────────────────────────────────────────────────
        local cardScroll = mk("ScrollingFrame", {
            BackgroundColor3=COL_AACG.BG, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,120), Size=UDim2.new(1,0,1,-120),
            ScrollBarThickness=3, CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(50,48,70),
            Parent=pg})
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=cardScroll})
        mk("UIGridLayout", {CellSize=UDim2.new(0.5,-6,0,96),
            CellPadding=UDim2.new(0,8,0,8),
            FillDirection=Enum.FillDirection.Horizontal,
            HorizontalAlignment=Enum.HorizontalAlignment.Left,
            SortOrder=Enum.SortOrder.LayoutOrder,
            Parent=cardScroll})

        -- ── Card builder ───────────────────────────────────────────────────────
        local function buildCard(card, idx)
            local AACG2   = _G.PC and _G.PC.AACG
            local tierCol = TIER_COL[card.tier] or COL_AACG.TEAL
            local confPct = math.clamp(card.confidence, 0, 1)
            local confCol = confPct >= 0.75 and COL_AACG.GREEN
                         or confPct >= 0.45 and COL_AACG.AMBER
                         or                     COL_AACG.RED

            local cFrame = mk("Frame", {BackgroundColor3=COL_AACG.CARD_BG,
                BorderSizePixel=0, LayoutOrder=idx, Parent=cardScroll})
            addCorner(cFrame, UDim.new(0,8))
            addStroke(cFrame, 1, 0)
            if cFrame:FindFirstChildOfClass("UIStroke") then
                cFrame:FindFirstChildOfClass("UIStroke").Color = COL_AACG.CARD_BDR
            end

            -- Left tier accent strip
            local strip = mk("Frame", {BackgroundColor3=tierCol,
                BorderSizePixel=0, Size=UDim2.new(0,3,1,0), Parent=cFrame})
            addCorner(strip, UDim.new(0,4))

            local body = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,1,0),
                Parent=cFrame})
            mk("UIPadding", {PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7),
                PaddingRight=UDim.new(0,4), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=body})

            -- Card name + favorite star
            local nameRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,4), Parent=nameRow})

            local nameLabel = mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.GothamBold, Text=card.name:sub(1,22),
                TextColor3=COL_AACG.TEXT, TextSize=11,
                Size=UDim2.new(1,-22,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=nameRow})

            local starBtn = mk("TextButton", {AutoButtonColor=false,
                BackgroundTransparency=1, BorderSizePixel=0,
                Font=Enum.Font.GothamBold,
                Text= card.favorited and "⭐" or "☆",
                TextColor3= card.favorited and COL_AACG.GOLD or COL_AACG.MUTED,
                TextSize=14, Size=UDim2.new(0,18,1,0),
                TextXAlignment=Enum.TextXAlignment.Center, Parent=nameRow})

            -- Description
            mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.Code, Text=card.description:sub(1,72),
                TextColor3=COL_AACG.MUTED, TextSize=9,
                TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,22), LayoutOrder=2, Parent=body})

            -- Remote + conf row
            local metaRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,14), LayoutOrder=3, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,6), Parent=metaRow})

            mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.Code, Text=card.remote:sub(1,18),
                TextColor3=tierCol, TextSize=9,
                Size=UDim2.new(1,-50,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=metaRow})

            mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.Code,
                Text=string.format("%.0f%%", confPct*100),
                TextColor3=confCol, TextSize=9,
                Size=UDim2.new(0,44,1,0),
                TextXAlignment=Enum.TextXAlignment.Right, Parent=metaRow})

            -- Fire button
            local fireBtn = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=tierCol, BorderSizePixel=0,
                Font=Enum.Font.GothamBold, Text="▶ Fire",
                TextColor3=Color3.fromRGB(10,10,14), TextSize=10,
                Size=UDim2.new(1,0,0,20), LayoutOrder=4, Parent=body})
            addCorner(fireBtn, UDim.new(0,5))

            -- Favorite toggle logic
            starBtn.MouseButton1Click:Connect(function()
                clickSound()
                if AACG2 then
                    if card.favorited then
                        AACG2.Unfavorite(card)
                        starBtn.Text = "☆"
                        starBtn.TextColor3 = COL_AACG.MUTED
                        tween(cFrame:FindFirstChildOfClass("UIStroke"), TweenInfo.new(0.2),
                            {Color=COL_AACG.CARD_BDR, Thickness=1})
                    else
                        AACG2.Favorite(card)
                        starBtn.Text = "⭐"
                        starBtn.TextColor3 = COL_AACG.GOLD
                        tween(cFrame:FindFirstChildOfClass("UIStroke"), TweenInfo.new(0.2),
                            {Color=COL_AACG.GOLD, Thickness=1.5})
                        sendNotification("⭐ Favorited: " .. card.name, "Success")
                    end
                end
            end)

            -- Fire logic
            fireBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(fireBtn)
                fireBtn.Text = "Firing..."
                fireBtn.BackgroundColor3 = COL_AACG.AMBER
                if AACG2 then
                    AACG2.Execute(card, function(ok, msg)
                        if ok then
                            fireBtn.Text = "✓ Done"
                            tween(fireBtn, TweenInfo.new(0.2),
                                {BackgroundColor3=COL_AACG.GREEN})
                            sendNotification("✓ " .. card.name .. " executed.", "Success")
                        else
                            fireBtn.Text = "✗ Failed"
                            tween(fireBtn, TweenInfo.new(0.2),
                                {BackgroundColor3=COL_AACG.RED})
                            sendNotification("✗ " .. tostring(msg):sub(1,48), "Warning")
                        end
                        -- Reset button after 2.5s
                        task.delay(2.5, function()
                            fireBtn.Text = "▶ Fire"
                            tween(fireBtn, TweenInfo.new(0.3),
                                {BackgroundColor3=tierCol})
                        end)
                    end)
                end
            end)

            -- Highlight favorited cards on spawn
            if card.favorited then
                if cFrame:FindFirstChildOfClass("UIStroke") then
                    cFrame:FindFirstChildOfClass("UIStroke").Color = COL_AACG.GOLD
                    cFrame:FindFirstChildOfClass("UIStroke").Thickness = 1.5
                end
            end

            return cFrame
        end

        -- ── Generate button logic ──────────────────────────────────────────────
        genBtn.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(genBtn)

            if not selectedTier or not selectedCat then
                generatedLabel.Text = "Select a tier and category first."
                generatedLabel.TextColor3 = COL_AACG.AMBER
                return
            end

            genBtn.Text = "Generating..."
            genBtn.BackgroundColor3 = COL_AACG.AMBER

            -- Clear existing cards
            for _, c in ipairs(cardScroll:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end

            task.spawn(function()
                local AACG2 = _G.PC and _G.PC.AACG
                if not AACG2 then
                    generatedLabel.Text = "AACG module not loaded."
                    generatedLabel.TextColor3 = COL_AACG.RED
                    genBtn.Text = "⚡ Generate Cards"
                    genBtn.BackgroundColor3 = COL_AACG.TEAL
                    return
                end

                local ASE2   = _G.PC and _G.PC.ASE
                local mastery = ASE2 and ASE2.IsMasteryUnlocked() or false
                local cards, err = AACG2.Generate(selectedTier, selectedCat, mastery)

                currentCards = cards

                if err or #cards == 0 then
                    local msg = err or "No cards generated for this category."
                    generatedLabel.Text = msg
                    generatedLabel.TextColor3 = COL_AACG.AMBER
                    genBtn.Text = "⚡ Generate Cards"
                    genBtn.BackgroundColor3 = COL_AACG.TEAL
                    return
                end

                -- Populate grid
                for i, card in ipairs(cards) do
                    pcall(buildCard, card, i)
                end

                -- Update gen label
                local favCount = 0
                for _, c in ipairs(cards) do if c.favorited then favCount=favCount+1 end end
                generatedLabel.Text = string.format(
                    "%d card(s) generated  •  %d favorited",
                    #cards, favCount)
                generatedLabel.TextColor3 = TIER_COL[selectedTier] or COL_AACG.TEAL

                genBtn.Text = "⚡ Generate Cards"
                tween(genBtn, TweenInfo.new(0.3), {BackgroundColor3=COL_AACG.TEAL})
            end)
        end)
    end

    -- ── TAB: Panel — Script Execution Panel ────────────────────────────────────
    do
        local pg = subTabPages["Panel"]

        -- ── Lock overlay ────────────────────────────────────────────────────────
        local lockOverlay = mk("Frame", {BackgroundColor3=Color3.fromRGB(14,13,18),
            BorderSizePixel=0, Size=UDim2.new(1,0,1,0), ZIndex=50, Parent=pg})
        mk("UIListLayout", {VerticalAlignment=Enum.VerticalAlignment.Center,
            HorizontalAlignment=Enum.HorizontalAlignment.Center,
            Padding=UDim.new(0,10), Parent=lockOverlay})
        local lockIcon = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, Text="◈",
            TextColor3=Color3.fromRGB(55,50,70), TextSize=48,
            Size=UDim2.new(1,0,0,52), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=lockOverlay})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Script Execution Panel",
            TextColor3=Color3.fromRGB(90,85,110), TextSize=16,
            Size=UDim2.new(1,0,0,24), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=lockOverlay})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Awaiting Bedrock confirmation.\nEstablish a pipeline to activate.",
            TextColor3=Color3.fromRGB(55,50,70), TextSize=11, TextWrapped=true,
            Size=UDim2.new(0.7,0,0,36), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=lockOverlay})

        -- ── Main panel ──────────────────────────────────────────────────────────
        local mainPanel = mk("Frame", {BackgroundColor3=Color3.fromRGB(14,13,18),
            BorderSizePixel=0, Size=UDim2.new(1,0,1,0), Visible=false, Parent=pg})

        -- ════════════════════════════════════════════════════════════════════════
        -- STATUS BAR — circuit identity strip across the top
        -- Shows: heartbeat pulse · SINK · via ANTECEDENT · ORIGIN chip · conf bar
        -- ════════════════════════════════════════════════════════════════════════
        local statusBar = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(18,17,24),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,44), Parent=mainPanel})
        addStroke(statusBar, 1, 0.6)

        -- Left: heartbeat + sink identity
        local hbPulseRing = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(0,0,0), BackgroundTransparency=1,
            BorderSizePixel=0, Size=UDim2.new(0,44,1,0),
            Position=UDim2.new(0,0,0,0), Parent=statusBar})
        heartbeatDot = mk("Frame", {
            BackgroundColor3=COL.RED, BorderSizePixel=0,
            Size=UDim2.new(0,12,0,12),
            Position=UDim2.new(0.5,-6,0.5,-6), Parent=hbPulseRing})
        addCorner(heartbeatDot, UDim.new(0,999))
        -- Pulse ring (expands on heartbeat)
        local hbRing = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(0,0,0), BackgroundTransparency=1,
            BorderSizePixel=0, Size=UDim2.new(0,24,0,24),
            Position=UDim2.new(0.5,-12,0.5,-12), Parent=hbPulseRing})
        addCorner(hbRing, UDim.new(0,999))
        addStroke(hbRing, 1.5, 0.5)
        local hbRingStroke = hbRing:FindFirstChildOfClass("UIStroke")
        if hbRingStroke then hbRingStroke.Color = COL.GREEN end

        -- Circuit identity labels
        local identityBlock = mk("Frame", {BackgroundTransparency=1,
            BorderSizePixel=0, Position=UDim2.new(0,48,0,0),
            Size=UDim2.new(1,-48,0,44), Parent=statusBar})

        local sinkRow = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,-8,0,22), Position=UDim2.new(0,0,0,3),
            Parent=identityBlock})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=sinkRow})

        local sinkNameLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, Text="SINK: —",
            TextColor3=Color3.fromRGB(220,215,255), TextSize=12,
            Size=UDim2.new(0,200,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=sinkRow})

        local antecedentLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="via —",
            TextColor3=Color3.fromRGB(80,200,140), TextSize=11,
            Size=UDim2.new(0,160,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=sinkRow})

        -- Origin chip (GHOST_HANDSHAKE / TWO_STAGE / STATE_GATE / etc)
        local originChip = mk("TextLabel", {
            BackgroundColor3=Color3.fromRGB(30,28,40), BorderSizePixel=0,
            Font=Enum.Font.Code, Text="—",
            TextColor3=Color3.fromRGB(140,120,200), TextSize=9,
            Size=UDim2.new(0,130,0,18),
            TextXAlignment=Enum.TextXAlignment.Center, Parent=sinkRow})
        addCorner(originChip, UDim.new(0,4))
        addStroke(originChip, 1, 0.5)

        -- Mode chip
        local modeChip = mk("TextLabel", {
            BackgroundColor3=Color3.fromRGB(25,40,65), BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="COMPILED",
            TextColor3=COL.BLUE, TextSize=9,
            Size=UDim2.new(0,72,0,18),
            TextXAlignment=Enum.TextXAlignment.Center, Parent=sinkRow})
        addCorner(modeChip, UDim.new(0,4))
        addStroke(modeChip, 1, 0.5)

        -- Second row: conf bar
        local confRow = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,-8,0,14), Position=UDim2.new(0,0,0,26),
            Parent=identityBlock})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=confRow})

        local confTextLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="conf: —",
            TextColor3=Color3.fromRGB(100,95,120), TextSize=9,
            Size=UDim2.new(0,54,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=confRow})

        local confBg = mk("Frame", {BackgroundColor3=Color3.fromRGB(28,26,36),
            BorderSizePixel=0, Size=UDim2.new(1,-70,0,4), Parent=confRow})
        addCorner(confBg, UDim.new(0,2))
        local confFill = mk("Frame", {BackgroundColor3=COL.GREEN, BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0), Parent=confBg})
        addCorner(confFill, UDim.new(0,2))

        -- ════════════════════════════════════════════════════════════════════════
        -- MAIN CONTENT AREA — three-zone layout
        --   Left  55%: Semantic Shell  (primary interaction surface)
        --   Right 45%: split vertically
        --     Right-top  42%: Protocol Forge
        --     Right-bot  58%: Transaction Buffer
        -- ════════════════════════════════════════════════════════════════════════
        local contentArea = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,44), Size=UDim2.new(1,0,1,-44),
            Parent=mainPanel})

        local SEP = 1  -- separator px
        local LEFT_W = 0.55

        -- ── LEFT: Semantic Shell ───────────────────────────────────────────────
        local shellPane = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(16,15,22),
            BorderSizePixel=0, Size=UDim2.new(LEFT_W,-SEP,1,0), Parent=contentArea})
        addStroke(shellPane, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=shellPane})
        mk("UIListLayout", {Padding=UDim.new(0,8), Parent=shellPane})

        -- Shell header
        local shellHdr = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=shellPane})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=shellHdr})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="◈ Semantic Shell", TextColor3=COL.TEAL, TextSize=12,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=shellHdr})

        -- Intent input row
        local intentRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,30), LayoutOrder=2, Parent=shellPane})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=intentRow})

        local intentBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(22,20,30), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText="Economy.AddCurrency...",
            PlaceholderColor3=Color3.fromRGB(65,60,80),
            Text="", TextColor3=COL.TEAL,
            TextSize=11, Size=UDim2.new(1,0,1,0), Parent=intentRow})
        addCorner(intentBox, UDim.new(0,6))
        addStroke(intentBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=intentBox})

        -- Autocomplete dropdown
        local acHolder = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(20,18,28),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,0),
            AutomaticSize=Enum.AutomaticSize.Y,
            Visible=false, LayoutOrder=3, Parent=shellPane})
        addCorner(acHolder, UDim.new(0,6))
        addStroke(acHolder, 1, 0.4)
        mk("UIListLayout", {Padding=UDim.new(0,1), Parent=acHolder})
        mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4),
            Parent=acHolder})

        local function updateAutocomplete(query)
            for _, c in ipairs(acHolder:GetChildren()) do
                if c:IsA("TextButton") then c:Destroy() end
            end
            if query == "" then acHolder.Visible = false; return end
            local TSR = _G.PC.TSR
            if not TSR or not TSR.Runtime then return end
            local callable = TSR.Runtime.GetCallable and TSR.Runtime.GetCallable() or {}
            local ASE2 = _G.PC.ASE
            local directives = ASE2 and ASE2.GetDirectives() or {}
            for _, d in ipairs(directives) do table.insert(callable, d.name) end
            local q = query:lower()
            local shown = 0
            for _, name in ipairs(callable) do
                if name:lower():find(q,1,true) then
                    local btn = mk("TextButton", {AutoButtonColor=false,
                        BackgroundTransparency=1, BorderSizePixel=0,
                        Font=Enum.Font.Code, Text="  " .. name,
                        TextColor3=COL.TEAL, TextSize=11,
                        Size=UDim2.new(1,0,0,22),
                        TextXAlignment=Enum.TextXAlignment.Left, Parent=acHolder})
                    local bname = name
                    btn.MouseButton1Click:Connect(function()
                        intentBox.Text = bname; acHolder.Visible = false
                    end)
                    hookHover(btn,
                        Color3.fromRGB(30,28,40), Color3.fromRGB(0,0,0),
                        Color3.fromRGB(0,0,0), Color3.fromRGB(0,0,0))
                    shown = shown + 1
                    if shown >= 7 then break end
                end
            end
            acHolder.Visible = shown > 0
        end
        intentBox:GetPropertyChangedSignal("Text"):Connect(function()
            updateAutocomplete(intentBox.Text)
        end)

        -- Args input
        local argsBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(22,20,30), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText='args: "Gold", 5000',
            PlaceholderColor3=Color3.fromRGB(65,60,80),
            Text="", TextColor3=Color3.fromRGB(200,195,230),
            TextSize=11, Size=UDim2.new(1,0,0,30),
            LayoutOrder=4, Parent=shellPane})
        addCorner(argsBox, UDim.new(0,6))
        addStroke(argsBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=argsBox})

        -- Execute button
        local shellExecBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.TEAL, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="▶  Execute Directive",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=12,
            Size=UDim2.new(1,0,0,32), LayoutOrder=5, Parent=shellPane})
        addCorner(shellExecBtn, UDim.new(0,6))

        -- Result label
        local shellResultLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="", TextColor3=COL.GREEN, TextSize=10,
            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,32), LayoutOrder=6, Parent=shellPane})

        -- Live raw preview strip
        local livePreviewLabel = mk("TextLabel", {
            BackgroundColor3=Color3.fromRGB(20,18,26),
            BorderSizePixel=0, Font=Enum.Font.Code,
            Text="— raw payload preview —",
            TextColor3=Color3.fromRGB(70,65,90), TextSize=9,
            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top,
            Size=UDim2.new(1,0,0,40), LayoutOrder=7, Parent=shellPane})
        addCorner(livePreviewLabel, UDim.new(0,4))
        addStroke(livePreviewLabel, 1, 0.6)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,5),
            Parent=livePreviewLabel})

        shellExecBtn.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(shellExecBtn)
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local intent = intentBox.Text:match("^%s*(.-)%s*$")
            if intent == "" then
                shellResultLabel.Text = "Enter an intent name."
                shellResultLabel.TextColor3 = COL.AMBER; return
            end
            local argsStr = argsBox.Text:match("^%s*(.-)%s*$")
            local args = {}
            if argsStr ~= "" then
                local ok, parsed = pcall(load("return {" .. argsStr .. "}"))
                if ok and type(parsed) == "function" then
                    local ok2, res = pcall(parsed)
                    if ok2 and type(res) == "table" then args = res end
                end
            end
            local ok, result = ASE2.Execute(intent, args)
            shellResultLabel.Text = ok
                and string.format("✓  %s", intent)
                or  "✗  " .. tostring(result)
            shellResultLabel.TextColor3 = ok and COL.GREEN or COL.RED
        end)

        intentBox:GetPropertyChangedSignal("Text"):Connect(function()
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local t = intentBox.Text:match("^%s*(.-)%s*$")
            if t ~= "" then
                livePreviewLabel.Text = string.format(
                    'Remote:FireServer({__intent="%s", __payload={...}})', t)
            else
                livePreviewLabel.Text = "— raw payload preview —"
            end
        end)

        -- ── RIGHT COLUMN ───────────────────────────────────────────────────────
        local rightCol = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(LEFT_W,SEP,0,0),
            Size=UDim2.new(1-LEFT_W,-SEP,1,0), Parent=contentArea})

        local FORGE_H = 0.40  -- forge takes 40% of right col height

        -- ── RIGHT-TOP: Protocol Forge ──────────────────────────────────────────
        local forgePane = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(16,12,10),
            BorderSizePixel=0, Size=UDim2.new(1,0,FORGE_H,-SEP), Parent=rightCol})
        addStroke(forgePane, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=forgePane})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=forgePane})

        -- Forge header
        local forgeHdr = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=forgePane})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=forgeHdr})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⚙ Protocol Forge", TextColor3=COL.ORANGE, TextSize=11,
            Size=UDim2.new(0,130,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=forgeHdr})

        local viewMode = "LUA"
        local luaBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.ORANGE, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="Lua",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=9,
            Size=UDim2.new(0,36,0,18), Parent=forgeHdr})
        addCorner(luaBtn, UDim.new(0,4))
        local byteBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(26,20,16), BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="0xFF",
            TextColor3=COL.MUTED, TextSize=9,
            Size=UDim2.new(0,36,0,18), Parent=forgeHdr})
        addCorner(byteBtn, UDim.new(0,4))
        addStroke(byteBtn, 1, 0.5)

        luaBtn.MouseButton1Click:Connect(function()
            viewMode = "LUA"
            tween(luaBtn, TweenInfo.new(0.1), {BackgroundColor3=COL.ORANGE})
            tween(byteBtn, TweenInfo.new(0.1), {BackgroundColor3=Color3.fromRGB(26,20,16)})
        end)
        byteBtn.MouseButton1Click:Connect(function()
            viewMode = "BYTE"
            tween(byteBtn, TweenInfo.new(0.1), {BackgroundColor3=COL.ORANGE})
            tween(luaBtn, TweenInfo.new(0.1), {BackgroundColor3=Color3.fromRGB(26,20,16)})
        end)

        -- Raw input
        local forgeBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(20,16,12), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText='{[1]="cmd", [2]={["amt"]=5000}}',
            PlaceholderColor3=Color3.fromRGB(70,55,40),
            Text="", TextColor3=COL.ORANGE,
            TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top,
            MultiLine=true, TextWrapped=true,
            Size=UDim2.new(1,0,0,56), LayoutOrder=2, Parent=forgePane})
        addCorner(forgeBox, UDim.new(0,5))
        addStroke(forgeBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,5), Parent=forgeBox})

        -- Action buttons
        local forgeBtnRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=3, Parent=forgePane})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,5), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=forgeBtnRow})

        local function forgeBtn(parent, text, col, fn)
            local b = mk("TextButton", {AutoButtonColor=false, BackgroundColor3=col,
                BorderSizePixel=0, Font=Enum.Font.GothamMedium, Text=text,
                TextColor3=Color3.fromRGB(255,255,255), TextSize=10,
                Size=UDim2.new(0,76,0,24), Parent=parent})
            addCorner(b, UDim.new(0,5))
            b.MouseButton1Click:Connect(function() clickSound(); pulseClick(b); fn() end)
            return b
        end

        forgeBtn(forgeBtnRow, "▶ Fire Raw", COL.ORANGE, function()
            local ASE2 = _G.PC.ASE
            local sink = ASE2 and ASE2.Panel.ActiveSink
            if not sink then sendNotification("No active Bedrock sink.", "Warning"); return end
            local raw = forgeBox.Text:match("^%s*(.-)%s*$")
            if raw == "" then sendNotification("Enter a raw payload.", "Warning"); return end
            local parsed = (viewMode == "BYTE") and (ASE2 and ASE2.ParseByteString(raw)) or nil
            local args = parsed or {raw}
            local ok, result = ASE2.FireRaw(sink, args)
            sendNotification(ok and "✓ Fired raw." or ("✗ " .. tostring(result)),
                ok and "Success" or "Warning")
        end)
        forgeBtn(forgeBtnRow, "⬆ Finalize", COL.TEAL, function()
            local ASE2 = _G.PC.ASE
            local sink = ASE2 and ASE2.Panel.ActiveSink
            if not sink then sendNotification("No active Bedrock sink.", "Warning"); return end
            local raw = forgeBox.Text:match("^%s*(.-)%s*$")
            if raw == "" then sendNotification("Enter a payload to finalize.", "Warning"); return end
            local parsed = ASE2 and ASE2.ParseByteString(raw)
            if not parsed then sendNotification("Could not parse payload.", "Warning"); return end
            local dname = intentBox.Text:match("^%s*(.-)%s*$")
            if dname == "" then dname = "Custom_" .. tostring(math.random(1000,9999)) end
            ASE2.FinalizeDirective(dname, parsed, sink, "Custom")
            sendNotification("Finalized: " .. dname, "Success")
        end)
        forgeBtn(forgeBtnRow, "↺ Recompile", COL.AMBER, function()
            local ASE2 = _G.PC.ASE
            local sink = ASE2 and ASE2.Panel.ActiveSink
            if sink then ASE2.Recompile(sink) end
        end)

        -- ── RIGHT-BOTTOM: Transaction Buffer ──────────────────────────────────
        local txPane = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(14,14,20),
            BorderSizePixel=0,
            Position=UDim2.new(0,0,FORGE_H,SEP),
            Size=UDim2.new(1,0,1-FORGE_H,-SEP), Parent=rightCol})
        addStroke(txPane, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=txPane})
        mk("UIListLayout", {Padding=UDim.new(0,5), Parent=txPane})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⧗ Transaction Buffer", TextColor3=Color3.fromRGB(80,75,110),
            TextSize=10, Size=UDim2.new(1,0,0,16),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=txPane})

        local txScroll = mk("ScrollingFrame", {BackgroundTransparency=1,
            BorderSizePixel=0, Size=UDim2.new(1,0,1,-24),
            ScrollBarThickness=2,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(50,48,70),
            LayoutOrder=2, Parent=txPane})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,3), Parent=txScroll})

        local TX_COLORS = {
            ok    = Color3.fromRGB(60,200,100),
            fail  = Color3.fromRGB(220,70,70),
            info  = Color3.fromRGB(90,140,220),
            warn  = Color3.fromRGB(210,160,40),
            muted = Color3.fromRGB(65,62,85),
        }

        local function rebuildTxBuffer()
            for _, c in ipairs(txScroll:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local entries = ASE2.GetTxBuffer(28)
            for i, e in ipairs(entries) do
                local resultStr = tostring(e.result or "")
                local isOk    = resultStr:find("✓") ~= nil
                local isFail  = resultStr:find("✗") ~= nil
                local accentCol = isOk and TX_COLORS.ok
                               or isFail and TX_COLORS.fail
                               or TX_COLORS.info

                local row = mk("Frame", {
                    BackgroundColor3=Color3.fromRGB(20,19,28),
                    BorderSizePixel=0, Size=UDim2.new(1,0,0,0),
                    AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=i, Parent=txScroll})
                addCorner(row, UDim.new(0,4))
                -- Left accent bar
                local accent = mk("Frame", {BackgroundColor3=accentCol,
                    BorderSizePixel=0, Size=UDim2.new(0,2,1,0),
                    Position=UDim2.new(0,0,0,0), Parent=row})
                addCorner(accent, UDim.new(0,2))

                local innerPad = mk("Frame", {BackgroundTransparency=1,
                    BorderSizePixel=0, Position=UDim2.new(0,8,0,0),
                    Size=UDim2.new(1,-10,0,0),
                    AutomaticSize=Enum.AutomaticSize.Y, Parent=row})
                mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4),
                    Parent=innerPad})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=innerPad})

                -- Directive name
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=tostring(e.directive or ""):sub(1,42),
                    TextColor3=Color3.fromRGB(200,196,230), TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=1, Parent=innerPad})
                -- Result
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=resultStr:sub(1,52),
                    TextColor3=accentCol, TextSize=8,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,10), LayoutOrder=2, Parent=innerPad})
                -- Timestamp
                if e.t then
                    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=string.format("t+%.1fs", e.t % 1000),
                        TextColor3=TX_COLORS.muted, TextSize=8,
                        TextXAlignment=Enum.TextXAlignment.Left,
                        Size=UDim2.new(1,0,0,10), LayoutOrder=3, Parent=innerPad})
                end
            end
        end

        -- ════════════════════════════════════════════════════════════════════════
        -- STATUS UPDATE + HEARTBEAT PULSE LOOP
        -- ════════════════════════════════════════════════════════════════════════
        task.spawn(function()
            local ORIGIN_COLORS = {
                LINGER_GHOST_HANDSHAKE = Color3.fromRGB(80,220,160),
                GHOST_HANDSHAKE        = Color3.fromRGB(80,220,160),
                TWO_STAGE_SEQUENCE     = Color3.fromRGB(100,180,255),
                STATE_GATE             = Color3.fromRGB(200,160,80),
                STATE_NUDGE            = Color3.fromRGB(180,120,220),
                LINGER_VERIFY          = Color3.fromRGB(120,160,220),
            }
            local ORIGIN_LABELS = {
                LINGER_GHOST_HANDSHAKE = "GHOST HANDSHAKE",
                GHOST_HANDSHAKE        = "GHOST HANDSHAKE",
                TWO_STAGE_SEQUENCE     = "TWO-STAGE SEQ",
                STATE_GATE             = "STATE GATE",
                STATE_NUDGE            = "STATE NUDGE",
                LINGER_VERIFY          = "NONCE ECHO",
            }

            while true do
                task.wait(1.5)
                local ASE2 = _G.PC.ASE
                if not ASE2 then continue end
                local stats = ASE2.GetStats()

                -- Show/hide main panel vs lock overlay
                local shouldShow = stats.PanelVisible or stats.ActiveSink ~= nil
                if shouldShow ~= mainPanel.Visible then
                    mainPanel.Visible   = shouldShow
                    lockOverlay.Visible = not shouldShow
                    if shouldShow then
                        subTabBtns["Panel"].Text = "✓ Panel"
                        subTabBtns["Panel"].TextColor3 = COL.GREEN
                    end
                end

                -- Status bar
                if stats.ActiveSink then
                    sinkNameLabel.Text = "SINK  " .. tostring(stats.ActiveSink):sub(1,22)
                end
                if stats.ActiveFeedback then
                    antecedentLabel.Text = "via " .. tostring(stats.ActiveFeedback):sub(1,20)
                else
                    antecedentLabel.Text = ""
                end

                -- Origin chip
                local pairs2 = ASE2.GetBedrockPairs and ASE2.GetBedrockPairs() or {}
                local origin = nil
                for _, p in ipairs(pairs2) do
                    if p.sinkRemote == stats.ActiveSink then
                        origin = p.origin; break
                    end
                end
                if origin then
                    local oLabel = ORIGIN_LABELS[origin] or origin:sub(1,16)
                    local oColor = ORIGIN_COLORS[origin] or Color3.fromRGB(140,120,200)
                    originChip.Text = oLabel
                    originChip.TextColor3 = oColor
                    addStroke(originChip, 1, 0)
                    if originChip:FindFirstChildOfClass("UIStroke") then
                        originChip:FindFirstChildOfClass("UIStroke").Color = oColor
                    end
                end

                -- Mode chip
                local modeCol = stats.Mode=="COMPILED" and COL.BLUE
                             or stats.Mode=="RAW"      and COL.ORANGE
                             or                            COL.PURP
                modeChip.Text = stats.Mode or "—"
                modeChip.TextColor3 = modeCol

                -- Conf bar
                local conf = stats.BedrockConf or 0
                confTextLabel.Text = string.format("conf: %.0f%%", conf * 100)
                tween(confFill, TweenInfo.new(0.4),
                    {Size=UDim2.new(math.clamp(conf,0,1),0,1,0)})
                local confCol = conf >= 0.9 and COL.GREEN
                             or conf >= 0.5 and COL.AMBER
                             or                 COL.RED
                tween(confFill, TweenInfo.new(0.4), {BackgroundColor3=confCol})

                -- Heartbeat pulse
                if heartbeatDot then
                    local alive = stats.HeartbeatAlive
                    if alive then
                        -- Dot pulses bright then dims
                        tween(heartbeatDot, TweenInfo.new(0.25),
                            {BackgroundColor3=COL.GREEN,
                             Size=UDim2.new(0,14,0,14),
                             Position=UDim2.new(0.5,-7,0.5,-7)})
                        -- Ring expands and fades
                        if hbRingStroke then
                            tween(hbRing, TweenInfo.new(0.5),
                                {Size=UDim2.new(0,36,0,36),
                                 Position=UDim2.new(0.5,-18,0.5,-18)})
                            tween(hbRingStroke, TweenInfo.new(0.5),
                                {Color=COL.GREEN, Transparency=0.0})
                        end
                        task.wait(0.35)
                        tween(heartbeatDot, TweenInfo.new(0.4),
                            {BackgroundColor3=Color3.fromRGB(20,80,35),
                             Size=UDim2.new(0,10,0,10),
                             Position=UDim2.new(0.5,-5,0.5,-5)})
                        if hbRingStroke then
                            tween(hbRing, TweenInfo.new(0.6),
                                {Size=UDim2.new(0,24,0,24),
                                 Position=UDim2.new(0.5,-12,0.5,-12)})
                            tween(hbRingStroke, TweenInfo.new(0.6), {Transparency=1.0})
                        end
                    else
                        tween(heartbeatDot, TweenInfo.new(0.3),
                            {BackgroundColor3=COL.RED,
                             Size=UDim2.new(0,10,0,10),
                             Position=UDim2.new(0.5,-5,0.5,-5)})
                    end
                end

                -- Rebuild TxBuffer
                if shouldShow then pcall(rebuildTxBuffer) end
            end
        end)

        -- ── MASTERY GATE OVERLAY ──────────────────────────────────────────────
        local _screenGui = _G.PCU and _G.PCU.screenGui
                           or game:GetService("Players").LocalPlayer
                              :WaitForChild("PlayerGui"):WaitForChild("PaperCuts_RAE", 10)
        local masteryGate = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(8,8,12), BackgroundTransparency=0.05,
            BorderSizePixel=0, Size=UDim2.new(1,0,1,0),
            Position=UDim2.new(0,0,0,0), ZIndex=9999, Visible=false,
            Parent=_screenGui or pageASE})
        local blur = Instance.new("BlurEffect")
        blur.Size = 0; blur.Parent = game:GetService("Lighting")
        mk("UIListLayout", {VerticalAlignment=Enum.VerticalAlignment.Center,
            HorizontalAlignment=Enum.HorizontalAlignment.Center,
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,14), Parent=masteryGate})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⚡  Autonomous Mastery",
            TextColor3=COL.PURP, TextSize=22,
            Size=UDim2.new(0.8,0,0,32), TextXAlignment=Enum.TextXAlignment.Center,
            LayoutOrder=1, ZIndex=10000, Parent=masteryGate})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
            Text="You are about to unlock Autonomous Mastery.\nTo proceed, type the following exactly:",
            TextColor3=COL.MUTED, TextSize=12, TextWrapped=true,
            Size=UDim2.new(0.75,0,0,40), TextXAlignment=Enum.TextXAlignment.Center,
            LayoutOrder=2, ZIndex=10000, Parent=masteryGate})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text='"I am responsible for my actions"',
            TextColor3=Color3.fromRGB(210,200,255), TextSize=14,
            Size=UDim2.new(0.75,0,0,22), TextXAlignment=Enum.TextXAlignment.Center,
            LayoutOrder=3, ZIndex=10000, Parent=masteryGate})
        local passphraseBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(20,18,28), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Type the phrase above...",
            PlaceholderColor3=Color3.fromRGB(80,70,100),
            Text="", TextColor3=Color3.fromRGB(200,190,255),
            TextSize=12, Size=UDim2.new(0.65,0,0,36),
            LayoutOrder=4, ZIndex=10000, Parent=masteryGate})
        addCorner(passphraseBox, UDim.new(0,8))
        addStroke(passphraseBox, 1.5, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), Parent=passphraseBox})
        local masterySubmitBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.PURP, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="Unlock Autonomous Mastery",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=12,
            Size=UDim2.new(0.5,0,0,38), LayoutOrder=5, ZIndex=10000, Parent=masteryGate})
        addCorner(masterySubmitBtn, UDim.new(0,10))
        local masteryCancelBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundTransparency=1, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="Cancel",
            TextColor3=COL.MUTED, TextSize=11,
            Size=UDim2.new(0.3,0,0,28), LayoutOrder=6, ZIndex=10000, Parent=masteryGate})
        local masteryError = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="", TextColor3=COL.RED, TextSize=11,
            Size=UDim2.new(0.7,0,0,20), TextXAlignment=Enum.TextXAlignment.Center,
            LayoutOrder=7, ZIndex=10000, Parent=masteryGate})

        local function showMasteryGate(show)
            masteryGate.Visible = show
            tween(blur, TweenInfo.new(0.3), {Size = show and 24 or 0})
            if show then passphraseBox.Text = ""; masteryError.Text = "" end
        end
        masterySubmitBtn.MouseButton1Click:Connect(function()
            clickSound()
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local phrase = passphraseBox.Text:match("^%s*(.-)%s*$")
            if ASE2.UnlockMastery(phrase) then
                showMasteryGate(false)
                ASE2.SetMode("MASTERY")
                sendNotification("⚡ Autonomous Mastery unlocked.", "Success")
            else
                masteryError.Text = "Incorrect. Try again."
                tween(passphraseBox, TweenInfo.new(0.05), {Position=UDim2.new(0.175,-8,0,0)})
                task.wait(0.05)
                tween(passphraseBox, TweenInfo.new(0.05), {Position=UDim2.new(0.175,8,0,0)})
                task.wait(0.05)
                tween(passphraseBox, TweenInfo.new(0.05), {Position=UDim2.new(0.175,0,0,0)})
            end
        end)
        masteryCancelBtn.MouseButton1Click:Connect(function()
            clickSound(); showMasteryGate(false)
        end)
        task.spawn(function()
            while true do
                task.wait(0.2)
                if _G._ASE_ShowMasteryGate then
                    _G._ASE_ShowMasteryGate = nil
                    showMasteryGate(true)
                end
            end
        end)
    end

    switchSubTab("Overview")
end
