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


        doRefreshOverview = function()
            local ASE = _G.PC.ASE
            if not ASE then statsLabel.Text = "ASE not loaded."; return end
            local stats = ASE.GetStats()
            statsLabel.Text = string.format(
                "Panel: %-10s  Heartbeat: %s\n"..
                "Active Sink: %s\n"..
                "Feedback:    %s\n"..
                "Goals: %d active / %d total   Directives: %d",
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
        pg.BackgroundColor3 = Color3.fromRGB(12, 11, 17)

        local CA = {
            BG       = Color3.fromRGB(12, 11, 17),
            CARD_BG  = Color3.fromRGB(20, 19, 28),
            CARD_BDR = Color3.fromRGB(38, 35, 52),
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
        local TIER_COL = {
            LOCALIZED = CA.TEAL,
            SERVER    = CA.BLUE,
            OWNER     = CA.PURP,
        }
        local TIER_LABEL = {
            LOCALIZED = "Localized Server-Side",
            SERVER    = "Server-Side  (All Players)",
            OWNER     = "⚡ Game Owner Rights",
        }
        local CAT_MAP = {
            LOCALIZED = {
                "Server-Side Executions",   -- replicated fx, sounds, particles, hitmarkers
                "Admin / Player Tools",     -- god-mode gear, admin panels, vehicles
                "Local Client Editing",     -- model swaps, GUI overlays, FOV, anims
                "WorldState Control",       -- props, weather, NPCs, gravity, color filters
            },
            SERVER = {
                "Server Admin / Player Tools", -- permanent admin, ban/kick, force-equip
                "Player Editing",              -- leaderstats, XP, skins, team swaps
                "WorldState Controlling",      -- economy, shop, terrain, game modes
            },
            OWNER = {
                "Everything",
            },
        }

        -- ── State ──────────────────────────────────────────────────────────────
        local selectedTier  = "LOCALIZED"
        local selectedCat   = nil
        local tierBtns      = {}
        local catBtns       = {}   -- dict keyed by category name
        local currentCards  = {}
        local generatedLabel = nil

        -- ── TOP BAR ────────────────────────────────────────────────────────────
        local topBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(16,15,22),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,112), Parent=pg})
        addStroke(topBar, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,6), Parent=topBar})
        mk("UIListLayout", {Padding=UDim.new(0,8), Parent=topBar})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="TIER", TextColor3=CA.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,12), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=topBar})

        local tierRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=2, Parent=topBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,6), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=tierRow})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="CATEGORY", TextColor3=CA.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,12), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=3, Parent=topBar})

        local catRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,24), LayoutOrder=4, Parent=topBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,5), VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=catRow})

        -- ── Category selector (no :Fire — called as plain function) ────────────
        local function doSelectCat(cname)
            selectedCat = cname
            local tcol = TIER_COL[selectedTier] or CA.TEAL
            for n, b in pairs(catBtns) do
                local active = (n == cname)
                tween(b, TweenInfo.new(0.12), {
                    BackgroundColor3 = active
                        and Color3.fromRGB(28,26,38) or Color3.fromRGB(22,20,30),
                    TextColor3 = active and tcol or CA.MUTED,
                })
                local stroke = b:FindFirstChildOfClass("UIStroke")
                if stroke then
                    stroke.Color = active and tcol or CA.CARD_BDR
                end
            end
        end

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
                    TextColor3=CA.MUTED, TextSize=10,
                    Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
                    Parent=catRow})
                addCorner(cb, UDim.new(0,5))
                addStroke(cb, 1, 0.5)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                    Parent=cb})
                catBtns[cname] = cb
                cb.MouseButton1Click:Connect(function()
                    clickSound()
                    doSelectCat(cname)
                end)
            end
            -- Auto-select first category directly — no :Fire()
            if cats[1] then
                doSelectCat(cats[1])
            end
        end

        -- ── Tier selector (no :Fire — called as plain function) ─────────────────
        local function doSelectTier(tkey)
            -- Owner requires Mastery
            if tkey == "OWNER" then
                local ASE2 = _G.PC and _G.PC.ASE
                if not ASE2 or not ASE2.IsMasteryUnlocked() then
                    sendNotification("⚡ Mastery required for Game Owner tier.", "Warning")
                    return
                end
            end
            selectedTier = tkey
            for n, b in pairs(tierBtns) do
                local active = (n == tkey)
                local ac = TIER_COL[n]
                tween(b, TweenInfo.new(0.12), {
                    BackgroundColor3 = active
                        and Color3.fromRGB(28,26,38) or Color3.fromRGB(22,20,30),
                    TextColor3 = active and ac or CA.MUTED,
                })
                local stroke = b:FindFirstChildOfClass("UIStroke")
                if stroke then
                    stroke.Color = active and ac or CA.CARD_BDR
                end
            end
            refreshCatRow()
        end

        -- Build tier buttons
        for _, tkey in ipairs({"LOCALIZED","SERVER","OWNER"}) do
            local tk = tkey
            local tb = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=Color3.fromRGB(22,20,30), BorderSizePixel=0,
                Font=Enum.Font.GothamMedium, Text=TIER_LABEL[tk],
                TextColor3=CA.MUTED, TextSize=10,
                Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
                Parent=tierRow})
            addCorner(tb, UDim.new(0,5))
            addStroke(tb, 1, 0.5)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                Parent=tb})
            tierBtns[tk] = tb
            tb.MouseButton1Click:Connect(function()
                clickSound()
                doSelectTier(tk)
            end)
        end

        -- Auto-select LOCALIZED on init — direct call, no :Fire()
        doSelectTier("LOCALIZED")

        -- ── GENERATE BAR ───────────────────────────────────────────────────────
        local genBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(16,15,22),
            BorderSizePixel=0,
            Position=UDim2.new(0,0,0,112), Size=UDim2.new(1,0,0,38),
            Parent=pg})
        addStroke(genBar, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=genBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,10), Parent=genBar})

        local genBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=CA.TEAL, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="⚡ Generate Cards",
            TextColor3=Color3.fromRGB(10,10,14), TextSize=11,
            Size=UDim2.new(0,140,1,-8), Parent=genBar})
        addCorner(genBtn, UDim.new(0,6))

        generatedLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code,
            Text="Select a tier and category, then generate.",
            TextColor3=CA.MUTED, TextSize=10,
            Size=UDim2.new(1,-158,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=genBar})

        -- ── CARD SCROLL ────────────────────────────────────────────────────────
        local cardScroll = mk("ScrollingFrame", {
            BackgroundColor3=CA.BG, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,150), Size=UDim2.new(1,0,1,-150),
            ScrollBarThickness=3,
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(50,48,70),
            Parent=pg})
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10),
            Parent=cardScroll})
        mk("UIGridLayout", {
            CellSize=UDim2.new(0.5,-6,0,100),
            CellPadding=UDim2.new(0,8,0,8),
            FillDirection=Enum.FillDirection.Horizontal,
            HorizontalAlignment=Enum.HorizontalAlignment.Left,
            SortOrder=Enum.SortOrder.LayoutOrder,
            Parent=cardScroll})

        -- ── Card builder ───────────────────────────────────────────────────────
        local function buildCard(card, idx)
            local AACG2   = _G.PC and _G.PC.AACG
            local tierCol = TIER_COL[card.tier] or CA.TEAL
            local confPct = math.clamp(card.confidence or 0, 0, 1)
            local confCol = confPct >= 0.75 and CA.GREEN
                         or confPct >= 0.45 and CA.AMBER
                         or                    CA.RED

            local cFrame = mk("Frame", {BackgroundColor3=CA.CARD_BG,
                BorderSizePixel=0, LayoutOrder=idx, Parent=cardScroll})
            addCorner(cFrame, UDim.new(0,8))
            addStroke(cFrame, 1, 0)
            local cStroke = cFrame:FindFirstChildOfClass("UIStroke")
            if cStroke then cStroke.Color = CA.CARD_BDR end

            -- Tier accent strip
            local strip = mk("Frame", {BackgroundColor3=tierCol,
                BorderSizePixel=0, Size=UDim2.new(0,3,1,0), Parent=cFrame})
            addCorner(strip, UDim.new(0,4))

            local body = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,1,0),
                Parent=cFrame})
            mk("UIPadding", {PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7),
                PaddingRight=UDim.new(0,4), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=body})

            -- Name row + star
            local nameRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,4), Parent=nameRow})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=tostring(card.name or ""):sub(1,22),
                TextColor3=CA.TEXT, TextSize=11,
                Size=UDim2.new(1,-22,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=nameRow})

            local starBtn = mk("TextButton", {AutoButtonColor=false,
                BackgroundTransparency=1, BorderSizePixel=0,
                Font=Enum.Font.GothamBold,
                Text=card.favorited and "⭐" or "☆",
                TextColor3=card.favorited and CA.GOLD or CA.MUTED,
                TextSize=14, Size=UDim2.new(0,18,1,0),
                TextXAlignment=Enum.TextXAlignment.Center, Parent=nameRow})

            -- Description
            mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.Code,
                Text=tostring(card.description or ""):sub(1,72),
                TextColor3=CA.MUTED, TextSize=9,
                TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,22), LayoutOrder=2, Parent=body})

            -- Remote + conf
            local metaRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,14), LayoutOrder=3, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,6), Parent=metaRow})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=tostring(card.remote or ""):sub(1,18),
                TextColor3=tierCol, TextSize=9,
                Size=UDim2.new(1,-50,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=metaRow})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
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

            -- Favorite toggle
            starBtn.MouseButton1Click:Connect(function()
                clickSound()
                if not AACG2 then return end
                if card.favorited then
                    AACG2.Unfavorite(card)
                    starBtn.Text = "☆"
                    starBtn.TextColor3 = CA.MUTED
                    if cStroke then
                        tween(cStroke, TweenInfo.new(0.2), {Color=CA.CARD_BDR, Thickness=1})
                    end
                else
                    AACG2.Favorite(card)
                    starBtn.Text = "⭐"
                    starBtn.TextColor3 = CA.GOLD
                    if cStroke then
                        tween(cStroke, TweenInfo.new(0.2), {Color=CA.GOLD, Thickness=1.5})
                    end
                    sendNotification("⭐ Favorited: " .. tostring(card.name), "Success")
                end
            end)

            -- Fire card
            fireBtn.MouseButton1Click:Connect(function()
                clickSound()
                pulseClick(fireBtn)
                fireBtn.Text = "Firing..."
                tween(fireBtn, TweenInfo.new(0.15), {BackgroundColor3=CA.AMBER})
                if not AACG2 then return end
                AACG2.Execute(card, function(ok, msg)
                    if ok then
                        fireBtn.Text = "✓ Done"
                        tween(fireBtn, TweenInfo.new(0.2), {BackgroundColor3=CA.GREEN})
                        sendNotification("✓ " .. tostring(card.name) .. " executed.", "Success")
                    else
                        fireBtn.Text = "✗ Failed"
                        tween(fireBtn, TweenInfo.new(0.2), {BackgroundColor3=CA.RED})
                        sendNotification("✗ " .. tostring(msg):sub(1,48), "Warning")
                    end
                    task.delay(2.5, function()
                        fireBtn.Text = "▶ Fire"
                        tween(fireBtn, TweenInfo.new(0.3), {BackgroundColor3=tierCol})
                    end)
                end)
            end)

            -- Gold border if already favorited
            if card.favorited and cStroke then
                cStroke.Color     = CA.GOLD
                cStroke.Thickness = 1.5
            end
        end

        -- ── Generate button ────────────────────────────────────────────────────
        genBtn.MouseButton1Click:Connect(function()
            clickSound()
            pulseClick(genBtn)
            if not selectedTier or not selectedCat then
                generatedLabel.Text = "Select a tier and category first."
                generatedLabel.TextColor3 = CA.AMBER
                return
            end
            genBtn.Text = "Generating..."
            tween(genBtn, TweenInfo.new(0.15), {BackgroundColor3=CA.AMBER})

            for _, c in ipairs(cardScroll:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end

            task.spawn(function()
                local AACG2 = _G.PC and _G.PC.AACG
                if not AACG2 then
                    generatedLabel.Text = "AACG module not loaded."
                    generatedLabel.TextColor3 = CA.RED
                    genBtn.Text = "⚡ Generate Cards"
                    tween(genBtn, TweenInfo.new(0.2), {BackgroundColor3=CA.TEAL})
                    return
                end
                local ASE2    = _G.PC and _G.PC.ASE
                local mastery = ASE2 and ASE2.IsMasteryUnlocked() or false
                local cards, err = AACG2.Generate(selectedTier, selectedCat, mastery)
                currentCards = cards or {}

                if err or #currentCards == 0 then
                    generatedLabel.Text = err or "No cards found for this category."
                    generatedLabel.TextColor3 = CA.AMBER
                    genBtn.Text = "⚡ Generate Cards"
                    tween(genBtn, TweenInfo.new(0.2), {BackgroundColor3=CA.TEAL})
                    return
                end

                for i, card in ipairs(currentCards) do
                    pcall(buildCard, card, i)
                end

                local favCount = 0
                for _, c in ipairs(currentCards) do
                    if c.favorited then favCount = favCount + 1 end
                end
                generatedLabel.Text = string.format(
                    "%d card(s)  •  %d favorited", #currentCards, favCount)
                generatedLabel.TextColor3 = TIER_COL[selectedTier] or CA.TEAL
                genBtn.Text = "⚡ Generate Cards"
                tween(genBtn, TweenInfo.new(0.3), {BackgroundColor3=CA.TEAL})
            end)
        end)
    end

    -- ── TAB: Panel — Exploit Executor ─────────────────────────────────────────
    do
        local pg = subTabPages["Panel"]

        -- ── Color palette (matches existing dark theme) ──────────────────────────
        local CA = {
            BG      = Color3.fromRGB(14, 13, 18),
            SURFACE = Color3.fromRGB(18, 17, 24),
            CARD    = Color3.fromRGB(22, 20, 30),
            BORDER  = Color3.fromRGB(36, 32, 50),
            TEXT    = Color3.fromRGB(210, 206, 235),
            MUTED   = Color3.fromRGB(80, 75, 105),
            DIM     = Color3.fromRGB(48, 44, 64),
            GREEN   = Color3.fromRGB(48, 210, 100),
            AMBER   = Color3.fromRGB(220, 168, 40),
            RED     = Color3.fromRGB(215, 60, 60),
            BLUE    = Color3.fromRGB(80, 150, 240),
            TEAL    = Color3.fromRGB(40, 200, 155),
            ORANGE  = Color3.fromRGB(215, 100, 40),
            PURP    = Color3.fromRGB(148, 98, 238),
            GOLD    = Color3.fromRGB(240, 188, 48),
        }

        -- ── Lock overlay ─────────────────────────────────────────────────────────
        local lockOverlay = mk("Frame", {
            BackgroundColor3=CA.BG, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ZIndex=50, Parent=pg})
        mk("UIListLayout", {
            VerticalAlignment=Enum.VerticalAlignment.Center,
            HorizontalAlignment=Enum.HorizontalAlignment.Center,
            Padding=UDim.new(0,10), Parent=lockOverlay})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="◈", TextColor3=Color3.fromRGB(55,50,70), TextSize=48,
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

        -- ── Main executor panel ───────────────────────────────────────────────────
        local mainPanel = mk("Frame", {
            BackgroundColor3=CA.BG, BorderSizePixel=0,
            Active=true,
            Size=UDim2.new(1,0,1,0), Visible=false, Parent=pg})

        -- ═══════════════════════════════════════════════════════════════════════════
        -- STATUS BAR
        -- ═══════════════════════════════════════════════════════════════════════════
        local statusBar = mk("Frame", {
            BackgroundColor3=CA.SURFACE, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,36), Parent=mainPanel})
        addStroke(statusBar, 1, 0.6)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=statusBar})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=statusBar})

        -- Heartbeat dot
        local heartbeatDot = mk("Frame", {
            BackgroundColor3=CA.RED, BorderSizePixel=0,
            Size=UDim2.new(0,10,0,10), Parent=statusBar})
        addCorner(heartbeatDot, UDim.new(0,999))

        local sinkLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, Text="SINK: —",
            TextColor3=CA.TEXT, TextSize=11,
            Size=UDim2.new(0,180,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=statusBar})

        local antLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.Code, Text="via —",
            TextColor3=CA.TEAL, TextSize=10,
            Size=UDim2.new(0,160,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=statusBar})

        local originChip = mk("TextLabel", {
            BackgroundColor3=CA.CARD, BorderSizePixel=0,
            Font=Enum.Font.Code, Text="—",
            TextColor3=CA.PURP, TextSize=9,
            Size=UDim2.new(0,120,0,20),
            TextXAlignment=Enum.TextXAlignment.Center, Parent=statusBar})
        addCorner(originChip, UDim.new(0,4))
        addStroke(originChip, 1, 0.4)



        -- Conf bar (right side)
        local confBg = mk("Frame", {
            BackgroundColor3=CA.DIM, BorderSizePixel=0,
            Size=UDim2.new(1,-620,0,4), Parent=statusBar})
        addCorner(confBg, UDim.new(0,2))
        local confFill = mk("Frame", {
            BackgroundColor3=CA.GREEN, BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0), Parent=confBg})
        addCorner(confFill, UDim.new(0,2))

        -- ═══════════════════════════════════════════════════════════════════════════
        -- TARGET BAR — remote selector + asset ID input
        -- ═══════════════════════════════════════════════════════════════════════════
        local targetBar = mk("Frame", {
            BackgroundColor3=CA.CARD, BorderSizePixel=0,
            Active=true,
            Position=UDim2.new(0,0,0,36), Size=UDim2.new(1,0,0,30),
            Parent=mainPanel})
        addStroke(targetBar, 1, 0.55)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=targetBar})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=targetBar})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="TARGET:", TextColor3=CA.MUTED, TextSize=9,
            Size=UDim2.new(0,52,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=targetBar})

        local targetBox = mk("TextBox", {
            BackgroundColor3=CA.BG, BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText="RetrieveCommands",
            PlaceholderColor3=CA.MUTED,
            Text="", TextColor3=CA.TEAL, TextSize=10,
            Active=true, Selectable=true,
            Size=UDim2.new(0,180,1,0), Parent=targetBar})
        addCorner(targetBox, UDim.new(0,4))
        addStroke(targetBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,6), Parent=targetBox})

        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="ASSET ID:", TextColor3=CA.MUTED, TextSize=9,
            Size=UDim2.new(0,58,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=targetBar})

        local assetBox = mk("TextBox", {
            BackgroundColor3=CA.BG, BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.Code,
            PlaceholderText="1281234852",
            PlaceholderColor3=CA.MUTED,
            Text="1281234852", TextColor3=CA.GOLD, TextSize=10,
            Active=true, Selectable=true,
            Size=UDim2.new(0,120,1,0), Parent=targetBar})
        addCorner(assetBox, UDim.new(0,4))
        addStroke(assetBox, 1, 0.4)
        mk("UIPadding", {PaddingLeft=UDim.new(0,6), Parent=assetBox})

        -- Quick-target buttons for confirmed sovereign surfaces
        local function makeTargetBtn(parent, label, col)
            local b = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=CA.BG, BorderSizePixel=0,
                Font=Enum.Font.Code, Text=label,
                TextColor3=col, TextSize=9,
                Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
                Parent=parent})
            addCorner(b, UDim.new(0,4))
            local st = addStroke(b, 1, 0)
            if st then st.Color = col end
            mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6),
                Parent=b})
            return b
        end

        local btnRetrieve = makeTargetBtn(targetBar, "RetrieveCommands", CA.GOLD)
        btnRetrieve.MouseButton1Click:Connect(function()
            clickSound(); targetBox.Text = "RetrieveCommands"
        end)

        local btnFetch = makeTargetBtn(targetBar, "fetchMutators", CA.TEAL)
        btnFetch.MouseButton1Click:Connect(function()
            clickSound(); targetBox.Text = "fetchMutators"
        end)

        -- ═══════════════════════════════════════════════════════════════════════════
        -- MAIN CONTENT — editor left, output right
        -- ═══════════════════════════════════════════════════════════════════════════
        local CONTENT_TOP = 66
        local contentArea = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,CONTENT_TOP),
            Size=UDim2.new(1,0,1,-(CONTENT_TOP+44)), -- leave 44px for bottom bar
            Parent=mainPanel})

        local EDITOR_W = 0.62

        -- ── Editor pane ───────────────────────────────────────────────────────────
        local editorPane = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(12,11,18), BorderSizePixel=0,
            Size=UDim2.new(EDITOR_W,-1,1,0), Parent=contentArea})
        addStroke(editorPane, 1, 0.5)

        -- Editor tab bar
        local editorTabBar = mk("Frame", {
            BackgroundColor3=CA.SURFACE, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,26), Parent=editorPane})
        addStroke(editorTabBar, 1, 0.6)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,6), PaddingTop=UDim.new(0,4),
            PaddingBottom=UDim.new(0,4), Parent=editorTabBar})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,4), Parent=editorTabBar})

        -- Script tabs (3 slots)
        local SCRIPT_TABS = {"Script 1", "Script 2", "Script 3"}
        local scriptContents = {"", "", ""}
        local activeScriptTab = 1
        local scriptTabBtns = {}

        local function makeScriptTabBtn(label, idx)
            local b = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=CA.BG, BorderSizePixel=0,
                Font=Enum.Font.Code, Text=label,
                TextColor3=CA.MUTED, TextSize=10,
                Size=UDim2.new(0,80,0,18), Parent=editorTabBar})
            addCorner(b, UDim.new(0,4))
            addStroke(b, 1, 0.5)
            return b
        end

        for i, label in ipairs(SCRIPT_TABS) do
            local b = makeScriptTabBtn(label, i)
            scriptTabBtns[i] = b
        end

        -- Script editor textarea
        local editorScroll = mk("ScrollingFrame", {
            BackgroundColor3=Color3.fromRGB(12,11,18), BorderSizePixel=0,
            Position=UDim2.new(0,0,0,26),
            Size=UDim2.new(1,0,1,-26),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3,
            ScrollBarImageColor3=CA.MUTED,
            Parent=editorPane})

        local editorBox = mk("TextBox", {
            BackgroundTransparency=1, BorderSizePixel=0,
            ClearTextOnFocus=false,
            Font=Enum.Font.Code,
            PlaceholderText="-- Script executes server-side via require()\n-- Return values appear in the output console.\n\nreturn game.PlaceId",
            PlaceholderColor3=CA.MUTED,
            Text="",
            TextColor3=Color3.fromRGB(200,220,200),
            TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top,
            MultiLine=true, TextWrapped=false,
            Active=true, Selectable=true,
            Size=UDim2.new(1,-8,0,0),
            AutomaticSize=Enum.AutomaticSize.Y,
            Parent=editorScroll})
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,8),
            PaddingRight=UDim.new(0,4), Parent=editorBox})

        -- Tab switching
        local function switchScriptTab(idx)
            -- Save current content
            scriptContents[activeScriptTab] = editorBox.Text
            activeScriptTab = idx
            editorBox.Text  = scriptContents[idx]
            for i, b in ipairs(scriptTabBtns) do
                local on = (i == idx)
                tween(b, TweenInfo.new(0.1), {
                    BackgroundColor3 = on and CA.CARD or CA.BG,
                    TextColor3       = on and CA.TEXT or CA.MUTED,
                })
            end
        end
        for i, b in ipairs(scriptTabBtns) do
            local idx = i
            b.MouseButton1Click:Connect(function()
                clickSound(); switchScriptTab(idx)
            end)
        end
        switchScriptTab(1)

        -- ── Output pane ───────────────────────────────────────────────────────────
        local outputPane = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(10,10,16), BorderSizePixel=0,
            Position=UDim2.new(EDITOR_W,1,0,0),
            Size=UDim2.new(1-EDITOR_W,-1,1,0), Parent=contentArea})
        addStroke(outputPane, 1, 0.5)

        -- Output header
        local outputHdr = mk("Frame", {
            BackgroundColor3=CA.SURFACE, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,26), Parent=outputPane})
        addStroke(outputHdr, 1, 0.6)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=outputHdr})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=outputHdr})
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Output", TextColor3=CA.MUTED, TextSize=10,
            Size=UDim2.new(1,-40,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=outputHdr})

        local clearOutBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=CA.DIM, BorderSizePixel=0,
            Font=Enum.Font.Code, Text="Clear",
            TextColor3=CA.MUTED, TextSize=9,
            Size=UDim2.new(0,36,0,18), Parent=outputHdr})
        addCorner(clearOutBtn, UDim.new(0,4))

        -- Output scroll
        local outputScroll = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(0,0,0,26),
            Size=UDim2.new(1,0,1,-26),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3,
            ScrollBarImageColor3=CA.MUTED,
            Parent=outputPane})
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,6),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6),
            Parent=outputScroll})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,3), Parent=outputScroll})

        local outputLineCount = 0
        local function addOutputLine(text, col, prefix)
            outputLineCount = outputLineCount + 1
            local lineCol = col or CA.TEXT
            local lbl = mk("TextLabel", {
                BackgroundTransparency=1,
                Font=Enum.Font.Code,
                Text=(prefix or "") .. tostring(text):sub(1,300),
                TextColor3=lineCol,
                TextSize=10,
                TextXAlignment=Enum.TextXAlignment.Left,
                TextYAlignment=Enum.TextYAlignment.Top,
                TextWrapped=true,
                Size=UDim2.new(1,0,0,0),
                AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=outputLineCount,
                Parent=outputScroll})
            -- Scroll to bottom
            task.defer(function()
                local canvas = outputScroll.AbsoluteCanvasSize
                outputScroll.CanvasPosition = Vector2.new(0, canvas.Y)
            end)
            return lbl
        end

        local function addOutputSep()
            outputLineCount = outputLineCount + 1
            local sep = mk("Frame", {
                BackgroundColor3=CA.DIM, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,1),
                LayoutOrder=outputLineCount, Parent=outputScroll})
        end

        clearOutBtn.MouseButton1Click:Connect(function()
            clickSound()
            for _, c in ipairs(outputScroll:GetChildren()) do
                if c:IsA("TextLabel") or c:IsA("Frame") then c:Destroy() end
            end
            outputLineCount = 0
        end)

        -- ═══════════════════════════════════════════════════════════════════════════
        -- BOTTOM ACTION BAR
        -- ═══════════════════════════════════════════════════════════════════════════
        local bottomBar = mk("Frame", {
            BackgroundColor3=CA.SURFACE, BorderSizePixel=0,
            Position=UDim2.new(0,0,1,-44),
            Size=UDim2.new(1,0,0,44), Parent=mainPanel})
        addStroke(bottomBar, 1, 0.5)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=bottomBar})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=bottomBar})

        -- Execute button (primary)
        local execBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=CA.TEAL, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="▶  Execute",
            TextColor3=Color3.fromRGB(255,255,255), TextSize=13,
            Size=UDim2.new(0,120,0,32), Parent=bottomBar})
        addCorner(execBtn, UDim.new(0,8))

        -- Fire Raw button (fires args directly, no asset ID wrapper)
        local fireRawBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=CA.CARD, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="Fire Raw",
            TextColor3=CA.ORANGE, TextSize=11,
            Size=UDim2.new(0,88,0,32), Parent=bottomBar})
        addCorner(fireRawBtn, UDim.new(0,8))
        addStroke(fireRawBtn, 1, 0.3)

        -- Clear editor button
        local clearEdBtn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=CA.CARD, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text="Clear",
            TextColor3=CA.MUTED, TextSize=11,
            Size=UDim2.new(0,64,0,32), Parent=bottomBar})
        addCorner(clearEdBtn, UDim.new(0,8))
        addStroke(clearEdBtn, 1, 0.4)

        -- Separator
        mk("Frame", {BackgroundColor3=CA.DIM, BorderSizePixel=0,
            Size=UDim2.new(0,1,0,28), Parent=bottomBar})

        -- Quick snippets
        local function quickBtn(label, snippet, col)
            local b = mk("TextButton", {AutoButtonColor=false,
                BackgroundColor3=CA.CARD, BorderSizePixel=0,
                Font=Enum.Font.Code, Text=label,
                TextColor3=col or CA.MUTED, TextSize=9,
                Size=UDim2.new(0,0,0,32), AutomaticSize=Enum.AutomaticSize.X,
                Parent=bottomBar})
            addCorner(b, UDim.new(0,6))
            addStroke(b, 1, 0.4)
            mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
                Parent=b})
            b.MouseButton1Click:Connect(function()
                clickSound()
                scriptContents[activeScriptTab] = snippet
                editorBox.Text = snippet
            end)
            return b
        end

        quickBtn("PlaceId",
            "return game.PlaceId",
            CA.BLUE)
        quickBtn("Players",
            'local Players = game:GetService("Players")\nlocal names = {}\nfor _, p in ipairs(Players:GetPlayers()) do\n    table.insert(names, p.Name)\nend\nreturn names',
            CA.TEAL)
        quickBtn("DataStores",
            'local DS = game:GetService("DataStoreService")\nreturn DS:GetDataStore("PlayerData"):GetAsync("test_key")',
            CA.GOLD)
        quickBtn("Workspace",
            'return game:GetService("Workspace").Name .. " @ " .. tostring(workspace.DistributedGameTime)',
            CA.PURP)

        -- ── Execution logic ────────────────────────────────────────────────────────
        local function resolveTarget()
            -- Priority: targetBox text → active sovereign surface → active sink
            local t = targetBox.Text:match("^%s*(.-)%s*$")
            if t ~= "" then return t end
            local SOV = _G.PC and _G.PC.Sovereign
            if SOV then
                for name, _ in pairs(SOV.GetPairs()) do return name end
            end
            local ASE2 = _G.PC and _G.PC.ASE
            return ASE2 and ASE2.Panel and ASE2.Panel.ActiveSink
        end

        local function doExecute()
            local ASE2 = _G.PC and _G.PC.ASE
            if not ASE2 then
                addOutputLine("ASE not loaded.", CA.RED, "✗ ")
                return
            end

            local remote = resolveTarget()
            if not remote then
                addOutputLine("No target remote. Set TARGET or establish Bedrock.", CA.AMBER, "⚠ ")
                return
            end

            local assetIdStr = assetBox.Text:match("^%s*(.-)%s*$")
            local assetId    = tonumber(assetIdStr)
            local script     = scriptContents[activeScriptTab]
            if script == "" then script = editorBox.Text end

            addOutputSep()
            addOutputLine(string.format("▶ Execute → %s  assetId=%s",
                remote, assetId and tostring(assetId) or "none"), CA.MUTED)

            -- Fire: if assetId provided, use it directly (REQUIRE track)
            -- Script text is informational here — the server runs the published module
            local ok, result, lat
            local PR = _G.PC and _G.PC.PR_Registry
            if PR and PR[remote] and PR[remote].Remote then
                local inst = PR[remote].Remote
                local t0   = os.clock()
                if assetId then
                    ok, result = pcall(function()
                        if inst:IsA("RemoteFunction") then
                            return inst:InvokeServer(assetId)
                        else
                            inst:FireServer(assetId)
                            return nil
                        end
                    end)
                else
                    ok, result = pcall(function()
                        if inst:IsA("RemoteFunction") then
                            return inst:InvokeServer(script)
                        else
                            inst:FireServer(script)
                            return nil
                        end
                    end)
                end
                lat = os.clock() - t0
            else
                -- Fall through to ASE.FireRaw
                ok, result = ASE2.FireRaw(remote, assetId and {assetId} or {script})
                lat = 0
            end

            if ok then
                local resStr = tostring(result)
                if resStr == "nil" or resStr == "" then
                    addOutputLine(string.format("ok=true  lat=%.0fms  (no return value)",
                        (lat or 0)*1000), CA.MUTED, "  ")
                else
                    -- Pretty-print tables
                    if type(result) == "table" then
                        addOutputLine("table {", CA.GREEN, "✓ ")
                        local count = 0
                        for k, v in pairs(result) do
                            addOutputLine(string.format("  [%s] = %s", tostring(k), tostring(v)),
                                CA.TEXT)
                            count = count + 1
                            if count >= 32 then
                                addOutputLine(string.format("  ... (%d more keys)", count), CA.MUTED)
                                break
                            end
                        end
                        addOutputLine("}", CA.GREEN)
                    else
                        addOutputLine(resStr, CA.GREEN, "✓ ")
                    end
                    addOutputLine(string.format("  lat=%.0fms", (lat or 0)*1000), CA.MUTED)
                end
            else
                addOutputLine(tostring(result):sub(1,200), CA.RED, "✗ ")
            end
        end

        local function doFireRaw()
            local ASE2 = _G.PC and _G.PC.ASE
            if not ASE2 then return end
            local remote = resolveTarget()
            if not remote then
                addOutputLine("No target remote.", CA.AMBER, "⚠ "); return
            end
            local script = scriptContents[activeScriptTab]
            if script == "" then script = editorBox.Text end

            addOutputSep()
            addOutputLine(string.format("⚙ FireRaw → %s", remote), CA.ORANGE)

            -- Parse as Lua table if possible, else send as string
            local args
            local ok2, parsed = pcall(load("return {" .. script .. "}"))
            if ok2 and type(parsed) == "function" then
                local ok3, res3 = pcall(parsed)
                if ok3 and type(res3) == "table" then
                    args = res3
                    addOutputLine("  parsed as args table", CA.MUTED)
                end
            end
            if not args then
                args = {script}
                addOutputLine("  sending as raw string arg", CA.MUTED)
            end

            local ok, result = ASE2.FireRaw(remote, args)
            addOutputLine(ok and "✓ fired" or ("✗ " .. tostring(result)),
                ok and CA.GREEN or CA.RED)
        end

        execBtn.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(execBtn)
            task.spawn(doExecute)
        end)

        fireRawBtn.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(fireRawBtn)
            task.spawn(doFireRaw)
        end)

        clearEdBtn.MouseButton1Click:Connect(function()
            clickSound()
            scriptContents[activeScriptTab] = ""
            editorBox.Text = ""
        end)

        -- Sync editorBox → scriptContents on every keystroke
        editorBox:GetPropertyChangedSignal("Text"):Connect(function()
            scriptContents[activeScriptTab] = editorBox.Text
        end)

        -- ═══════════════════════════════════════════════════════════════════════════
        -- STATUS UPDATE LOOP
        -- ═══════════════════════════════════════════════════════════════════════════
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

        task.spawn(function()
            while true do
                task.wait(1.5)
                local ASE2 = _G.PC and _G.PC.ASE
                if not ASE2 then continue end
                local stats = ASE2.GetStats()

                -- Lock/unlock
                local shouldShow = stats.PanelVisible or stats.ActiveSink ~= nil
                if shouldShow ~= mainPanel.Visible then
                    mainPanel.Visible   = shouldShow
                    lockOverlay.Visible = not shouldShow
                    if shouldShow then
                        subTabBtns["Panel"].Text = "✓ Panel"
                        subTabBtns["Panel"].TextColor3 = COL.GREEN
                        -- Auto-populate target if sovereign surface exists
                        local SOV = _G.PC and _G.PC.Sovereign
                        if SOV and targetBox.Text == "" then
                            for name, _ in pairs(SOV.GetPairs()) do
                                targetBox.Text = name; break
                            end
                        end
                        if targetBox.Text == "" and stats.ActiveSink then
                            targetBox.Text = stats.ActiveSink
                        end
                    end
                end

                -- Status bar
                if stats.ActiveSink then
                    sinkLabel.Text = "SINK  " .. tostring(stats.ActiveSink):sub(1,22)
                end
                antLabel.Text = stats.ActiveFeedback
                    and ("via " .. tostring(stats.ActiveFeedback):sub(1,20))
                    or ""

                local pairs2 = ASE2.GetBedrockPairs and ASE2.GetBedrockPairs() or {}
                local origin = nil
                for _, p in ipairs(pairs2) do
                    if p.sinkRemote == stats.ActiveSink then
                        origin = p.origin; break
                    end
                end
                if origin then
                    local oLabel = ORIGIN_LABELS[origin] or origin:sub(1,16)
                    local oColor = ORIGIN_COLORS[origin] or CA.PURP
                    originChip.Text = oLabel
                    originChip.TextColor3 = oColor
                end



                local confPct = stats.BedrockConf or 0
                tween(confFill, TweenInfo.new(0.4), {
                    Size=UDim2.new(math.clamp(confPct,0,1),0,1,0)})

                -- Heartbeat dot pulse
                if stats.HeartbeatAlive then
                    tween(heartbeatDot, TweenInfo.new(0.1),
                        {BackgroundColor3=CA.GREEN})
                    task.delay(0.25, function()
                        tween(heartbeatDot, TweenInfo.new(0.3),
                            {BackgroundColor3=CA.MUTED})
                    end)
                end
            end
        end)
    end

    switchSubTab("Overview")
end