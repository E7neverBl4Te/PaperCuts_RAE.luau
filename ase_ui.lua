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
    local SUB_TABS = {"Overview","Goals","Bedrock","Directives","Panel"}
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
            Text= isPanelTab and "⬛ Panel" or name,
            TextColor3=Color3.fromRGB(90,80,70),
            TextSize=11, Parent=tabBar})
        addCorner(btn, UDim.new(0,6)); addStroke(btn, 1, 0.4)

        -- Panel tab is a raw Frame (not scroll) — we build it custom
        if isPanelTab then
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
            PENDING="",  RUNNING=COL.BLUE, COMPLETE=COL.GREEN,
            FAILED=COL.RED, ABORTED=COL.AMBER,
        }

        -- Tracks which card is currently selected (for highlight reset)
        local selectedCard = nil

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
        local remoteBox2 = mk("TextBox", {BackgroundColor3=Color3.fromRGB(232,228,220),
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
        subTabBtns["Goals"].MouseButton1Click:Connect(doRefreshGoals)
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

    -- ── TAB: Panel — Script Execution Panel ────────────────────────────────────
    do
        local pg = subTabPages["Panel"]

        -- Panel lock overlay (shown when Bedrock not confirmed)
        local lockOverlay = mk("Frame", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, Size=UDim2.new(1,0,1,0),
            ZIndex=50, Parent=pg})
        addCorner(lockOverlay, UDim.new(0,0))
        mk("UIListLayout", {VerticalAlignment=Enum.VerticalAlignment.Center,
            HorizontalAlignment=Enum.HorizontalAlignment.Center, Parent=lockOverlay})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⬛  Script Execution Panel",
            TextColor3=COL.MUTED, TextSize=18,
            Size=UDim2.new(1,0,0,30), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=lockOverlay})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Awaiting Bedrock confirmation.\nRun a Bedrock goal to establish the pipeline.\nThis panel will appear automatically.",
            TextColor3=Color3.fromRGB(70,70,80), TextSize=12, TextWrapped=true,
            Size=UDim2.new(0.7,0,0,60), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=lockOverlay})

        -- Main execution panel (hidden until Bedrock confirmed)
        local mainPanel = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), Visible=false, Parent=pg})

        -- ── Status bar ─────────────────────────────────────────────────────────
        local statusBar = mk("Frame", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, Size=UDim2.new(1,0,0,32), Parent=mainPanel})
        addStroke(statusBar, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=statusBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,10), Parent=statusBar})

        heartbeatDot = mk("Frame", {BackgroundColor3=COL.RED,
            BorderSizePixel=0, Size=UDim2.new(0,10,0,10), Parent=statusBar})
        addCorner(heartbeatDot, UDim.new(0,999))

        local sinkLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="SINK: —   FEEDBACK: —", TextColor3=COL.TEXT, TextSize=10,
            Size=UDim2.new(0.5,0,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=statusBar})

        local modeChip = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="COMPILED", TextColor3=COL.BLUE, TextSize=10,
            Size=UDim2.new(0,80,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=statusBar})

        local confLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="conf: —%", TextColor3=COL.MUTED, TextSize=10,
            Size=UDim2.new(0,60,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=statusBar})

        -- ── Split: Semantic Shell (top) / Forge (bottom) ───────────────────────
        local splitContainer = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,32), Size=UDim2.new(1,0,1,-32), Parent=mainPanel})

        -- Left column: input area (60%)
        local leftCol = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(0.60,0,1,0), Parent=splitContainer})
        mk("UIListLayout", {Padding=UDim.new(0,0), Parent=leftCol})

        -- Right column: transaction buffer (40%)
        local rightCol = mk("Frame", {BackgroundColor3=COL.DARK, BorderSizePixel=0,
            Position=UDim2.new(0.60,1,0,0), Size=UDim2.new(0.40,-1,1,0), Parent=splitContainer})
        addStroke(rightCol, 1, 0.5)

        -- ── SEMANTIC SHELL ─────────────────────────────────────────────────────
        local shellArea = mk("Frame", {BackgroundColor3=COL.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0.5,0), Parent=leftCol})
        addStroke(shellArea, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=shellArea})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=shellArea})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⬛ Semantic Shell", TextColor3=COL.BLUE, TextSize=11,
            Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=shellArea})

        -- Intent autocomplete row
        local intentRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,28), LayoutOrder=2, Parent=shellArea})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=intentRow})
        local intentBox = mk("TextBox", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText="Economy.AddCurrency...",
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEAL,
            TextSize=11, Size=UDim2.new(1,-80,1,0), Parent=intentRow})
        addCorner(intentBox, UDim.new(0,6)); addStroke(intentBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=intentBox})

        -- Autocomplete suggestions
        local acHolder = mk("Frame", {BackgroundColor3=Color3.fromRGB(20,20,26),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,10),
            AutomaticSize=Enum.AutomaticSize.Y, LayoutOrder=3, Parent=shellArea})
        addCorner(acHolder, UDim.new(0,6)); addStroke(acHolder, 1, 0.5)
        mk("UIListLayout", {Padding=UDim.new(0,2), Parent=acHolder})

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
                        TextColor3=COL.TEAL, TextSize=10,
                        Size=UDim2.new(1,0,0,20),
                        TextXAlignment=Enum.TextXAlignment.Left, Parent=acHolder})
                    local bname = name
                    btn.MouseButton1Click:Connect(function()
                        intentBox.Text = bname
                        acHolder.Visible = false
                    end)
                    shown = shown + 1
                    if shown >= 6 then break end
                end
            end
            acHolder.Visible = shown > 0
        end
        intentBox:GetPropertyChangedSignal("Text"):Connect(function()
            updateAutocomplete(intentBox.Text)
        end)

        -- Args input
        local argsBox = mk("TextBox", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText='args: "Gold", 5000',
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEXT,
            TextSize=11, Size=UDim2.new(1,0,0,26),
            LayoutOrder=4, Parent=shellArea})
        addCorner(argsBox, UDim.new(0,6)); addStroke(argsBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=argsBox})

        -- Execute button
        local shellExecBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.BLUE, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="▶  Execute Directive",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=11,
            Size=UDim2.new(1,0,0,28), LayoutOrder=5, Parent=shellArea})
        addCorner(shellExecBtn, UDim.new(0,6))

        local shellResultLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="", TextColor3=COL.GREEN, TextSize=10,
            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,28), LayoutOrder=6, Parent=shellArea})

        shellExecBtn.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(shellExecBtn)
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local intent = intentBox.Text:match("^%s*(.-)%s*$")
            if intent == "" then
                shellResultLabel.Text = "Enter an intent name."
                shellResultLabel.TextColor3 = COL.AMBER; return
            end
            -- Parse args
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
                and string.format("✓  %s  [nonce: %s]", intent, tostring(result):sub(1,16))
                or  "✗  " .. tostring(result)
            shellResultLabel.TextColor3 = ok and COL.GREEN or COL.RED
        end)

        -- ── PROTOCOL FORGE ─────────────────────────────────────────────────────
        local forgeArea = mk("Frame", {BackgroundColor3=Color3.fromRGB(20,16,14),
            BorderSizePixel=0, Size=UDim2.new(1,0,0.5,0), Parent=leftCol})
        addStroke(forgeArea, 1.5, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=forgeArea})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=forgeArea})

        -- Forge header row with view toggle
        local forgeHdr = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=forgeArea})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,8), Parent=forgeHdr})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⚙ Protocol Forge", TextColor3=COL.ORANGE, TextSize=11,
            Size=UDim2.new(0,130,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=forgeHdr})

        -- Lua / Byte-string view toggle
        local viewMode = "LUA"
        local luaBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.ORANGE, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="Lua",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=10,
            Size=UDim2.new(0,40,0,18), Parent=forgeHdr})
        addCorner(luaBtn, UDim.new(0,4))
        local byteBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=COL.DARK, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="0xFF",
            TextColor3=COL.MUTED, TextSize=10,
            Size=UDim2.new(0,40,0,18), Parent=forgeHdr})
        addCorner(byteBtn, UDim.new(0,4)); addStroke(byteBtn, 1, 0.5)

        -- Raw input box
        local forgeBox = mk("TextBox", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText='{[1]="cmd", [2]={["amt"]=5000}}',
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.ORANGE,
            TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top,
            MultiLine=true, TextWrapped=true,
            Size=UDim2.new(1,0,0,60), LayoutOrder=2, Parent=forgeArea})
        addCorner(forgeBox, UDim.new(0,6)); addStroke(forgeBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=forgeBox})

        -- Live raw preview (shown under Semantic Shell input)
        local livePreviewLabel = mk("TextLabel", {BackgroundColor3=COL.DARK,
            BorderSizePixel=0, Font=Enum.Font.Code,
            Text="— raw payload preview —", TextColor3=Color3.fromRGB(90,80,60),
            TextSize=9, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top,
            Size=UDim2.new(1,0,0,36), LayoutOrder=3, Parent=forgeArea})
        addCorner(livePreviewLabel, UDim.new(0,4))
        mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingTop=UDim.new(0,4), Parent=livePreviewLabel})

        -- Update live preview from Semantic Shell
        intentBox:GetPropertyChangedSignal("Text"):Connect(function()
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local t = intentBox.Text:match("^%s*(.-)%s*$")
            if t ~= "" then
                if viewMode == "LUA" then
                    livePreviewLabel.Text = string.format(
                        'Remote:FireServer({__intent="%s", __payload={...}})', t)
                else
                    livePreviewLabel.Text = ASE2.ToByteString({__intent=t, __payload={}}):sub(1,120)
                end
            else
                livePreviewLabel.Text = "— raw payload preview —"
            end
        end)

        luaBtn.MouseButton1Click:Connect(function()
            viewMode = "LUA"
            luaBtn.BackgroundColor3  = COL.ORANGE; luaBtn.TextColor3 = Color3.fromRGB(10,10,14)
            byteBtn.BackgroundColor3 = COL.DARK;   byteBtn.TextColor3 = COL.MUTED
            forgeBox.TextColor3 = COL.ORANGE
        end)
        byteBtn.MouseButton1Click:Connect(function()
            viewMode = "BYTE"
            byteBtn.BackgroundColor3 = COL.ORANGE; byteBtn.TextColor3 = Color3.fromRGB(10,10,14)
            luaBtn.BackgroundColor3  = COL.DARK;   luaBtn.TextColor3 = COL.MUTED
            forgeBox.TextColor3 = Color3.fromRGB(180,120,80)
            -- Convert current box content to byte-string view
            local ASE2 = _G.PC.ASE
            if ASE2 and forgeBox.Text ~= "" then
                local parsed = ASE2.ParseByteString(forgeBox.Text)
                if parsed then
                    forgeBox.Text = ASE2.ToByteString(parsed)
                end
            end
        end)

        -- Forge action buttons
        local forgeBtnRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,28), LayoutOrder=4, Parent=forgeArea})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,6), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=forgeBtnRow})

        local function forgeActionBtn(parent, text, col, fn)
            local b = mk("TextButton", {AutoButtonColor=false, BackgroundColor3=col,
                BorderSizePixel=0, Font=Enum.Font.GothamMedium, Text=text,
                TextColor3=Color3.fromRGB(255,255,255), TextSize=10,
                Size=UDim2.new(0,80,0,24), Parent=parent})
            addCorner(b, UDim.new(0,6))
            b.MouseButton1Click:Connect(function() clickSound(); pulseClick(b); fn() end)
            return b
        end
        forgeActionBtn(forgeBtnRow, "▶ Fire Raw", COL.ORANGE, function()
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
        forgeActionBtn(forgeBtnRow, "⬆ Finalize", COL.TEAL, function()
            local ASE2 = _G.PC.ASE
            local sink = ASE2 and ASE2.Panel.ActiveSink
            if not sink then sendNotification("No active Bedrock sink.", "Warning"); return end
            local raw = forgeBox.Text:match("^%s*(.-)%s*$")
            if raw == "" then sendNotification("Enter a payload to finalize.", "Warning"); return end
            local parsed = ASE2 and ASE2.ParseByteString(raw)
            if not parsed then sendNotification("Could not parse payload.", "Warning"); return end
            -- Prompt for name via intentBox
            local dname = intentBox.Text:match("^%s*(.-)%s*$")
            if dname == "" then dname = "Custom_" .. tostring(math.random(1000,9999)) end
            ASE2.FinalizeDirective(dname, parsed, sink, "Custom")
            sendNotification("Finalized: " .. dname, "Success")
        end)
        forgeActionBtn(forgeBtnRow, "↺ Recompile", COL.AMBER, function()
            local ASE2 = _G.PC.ASE
            local sink = ASE2 and ASE2.Panel.ActiveSink
            if sink then ASE2.Recompile(sink) end
        end)

        -- ── TRANSACTION BUFFER (right column) ─────────────────────────────────
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=rightCol})
        mk("UIListLayout", {Padding=UDim.new(0,4), Parent=rightCol})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="⧗ Transaction Buffer", TextColor3=COL.MUTED, TextSize=10,
            Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=rightCol})

        local txScroll = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,-24), ScrollBarThickness=2,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(60,60,70),
            LayoutOrder=2, Parent=rightCol})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,4),
            Parent=txScroll})

        local function rebuildTxBuffer()
            for _, c in ipairs(txScroll:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local ASE2 = _G.PC.ASE
            if not ASE2 then return end
            local entries = ASE2.GetTxBuffer(24)
            for i, e in ipairs(entries) do
                local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(22,22,28),
                    BorderSizePixel=0, Size=UDim2.new(1,0,0,10),
                    AutomaticSize=Enum.AutomaticSize.Y, LayoutOrder=i, Parent=txScroll})
                addCorner(row, UDim.new(0,4)); addStroke(row, 1, 0.5)
                mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6),
                    PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})
                local isOk = tostring(e.result or ""):find("✓") ~= nil
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=tostring(e.directive or ""):sub(1,28),
                    TextColor3=COL.TEXT, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=1, Parent=row})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=tostring(e.result or ""):sub(1,36),
                    TextColor3=isOk and COL.GREEN or COL.RED, TextSize=8,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,10), LayoutOrder=2, Parent=row})
            end
        end

        -- ── Panel show/hide and status update loop ─────────────────────────────
        task.spawn(function()
            while true do
                task.wait(1.5)
                local ASE2 = _G.PC.ASE
                if not ASE2 then continue end
                local stats = ASE2.GetStats()

                -- Show/hide main panel vs lock overlay
                local panelShouldBeVisible = stats.PanelVisible or stats.ActiveSink ~= nil
                if panelShouldBeVisible ~= mainPanel.Visible then
                    mainPanel.Visible  = panelShouldBeVisible
                    lockOverlay.Visible= not panelShouldBeVisible
                    if panelShouldBeVisible then
                        -- Update Panel tab label
                        subTabBtns["Panel"].Text = "✓ Panel"
                        subTabBtns["Panel"].TextColor3 = COL.GREEN
                    end
                end

                -- Status bar update
                if stats.ActiveSink then
                    sinkLabel.Text = string.format("SINK: %s   FB: %s",
                        stats.ActiveSink:sub(1,20),
                        (stats.ActiveFeedback or "?"):sub(1,20))
                end
                modeChip.Text = stats.Mode
                modeChip.TextColor3 = stats.Mode=="COMPILED" and COL.BLUE
                    or stats.Mode=="RAW" and COL.ORANGE or COL.PURP
                confLabel.Text = string.format("conf: %.0f%%", (stats.BedrockConf or 0)*100)

                -- Heartbeat dot
                if heartbeatDot then
                    local alive = stats.HeartbeatAlive
                    if alive then
                        -- Pulse green
                        tween(heartbeatDot, TweenInfo.new(0.4), {BackgroundColor3=COL.GREEN})
                        task.wait(0.4)
                        tween(heartbeatDot, TweenInfo.new(0.4), {BackgroundColor3=Color3.fromRGB(20,80,30)})
                    else
                        heartbeatDot.BackgroundColor3 = COL.RED
                    end
                end

                -- Rebuild tx buffer
                if panelShouldBeVisible then
                    pcall(rebuildTxBuffer)
                end
            end
        end)

        -- ── MASTERY GATE OVERLAY ──────────────────────────────────────────────
        -- Mastery gate lives in screenGui so it covers the full screen
        local _screenGui = _G.PCU and _G.PCU.screenGui
                           or game:GetService("Players").LocalPlayer
                              :WaitForChild("PlayerGui"):WaitForChild("PaperCuts_RAE", 10)
        local masteryGate = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(8,8,12), BackgroundTransparency=0.05,
            BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            Position=UDim2.new(0,0,0,0),
            ZIndex=9999,
            Visible=false,
            Parent=_screenGui or pageASE})
        -- Blur handled by BlurEffect in Lighting
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
                -- Flash the mode button purple
                local mb = modeButtons and modeButtons["MASTERY"]
                if mb then
                    pulseClick(mb.btn)
                end
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

        -- Poll for gate show request from mode buttons
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
