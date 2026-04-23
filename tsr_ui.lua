-- ── Imports ──────────────────────────────────────────────────────────────────
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
local makeSection    = _U.makeSection
local makeToggle     = _U.makeToggle
local sendNotification = _U.sendNotification
local makePage       = _C.makePage
local pageTSR        = _U.pageTSR or makePage("TSR")
_G.PCU.pageTSR       = pageTSR
_G.PC.pageTSR        = pageTSR

-- ============================================================
-- PAGE: TSR — The Sovereign Runtime
-- Tabs: Overview · Bindings · Execute · Macros · Log
-- ============================================================

do
    local COL = {
        BG        = Color3.fromRGB(250, 247, 242),
        CARD      = Color3.fromRGB(244, 240, 234),
        BORDER    = Color3.fromRGB(210, 200, 188),
        TEXT      = Color3.fromRGB(46,  42,  38),
        MUTED     = Color3.fromRGB(130, 120, 110),
        BOUND     = Color3.fromRGB(60,  170, 90),
        UNBOUND   = Color3.fromRGB(180, 145, 60),
        ACTIVE    = Color3.fromRGB(70,  130, 200),
        FAIL      = Color3.fromRGB(200, 65,  65),
        CRITICAL  = Color3.fromRGB(200, 60,  60),
        HIGH      = Color3.fromRGB(210, 120, 40),
        MEDIUM    = Color3.fromRGB(180, 160, 40),
        LOW       = Color3.fromRGB(80,  170, 80),
    }

    local RISK_COL = {
        CRITICAL = COL.CRITICAL, HIGH = COL.HIGH,
        MEDIUM   = COL.MEDIUM,   LOW  = COL.LOW,
    }

    local CAT_ICONS = {
        Economy          = "💰",
        WorldInteraction = "🌍",
        CharacterState   = "❤️",
        CharacterPhysical= "⚡",
        SocialIdentity   = "👤",
        Administrative   = "🔑",
    }

    -- ── Helpers ───────────────────────────────────────────────────────────────
    local function mkLabel(parent, text, size, color, bold)
        return mk("TextLabel", {
            BackgroundTransparency = 1,
            Font      = bold and Enum.Font.GothamBold or Enum.Font.GothamMedium,
            Text      = text,
            TextColor3= color or COL.TEXT,
            TextSize  = size or 11,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            Size      = UDim2.new(1, 0, 0, (size or 11) * 2.2),
            Parent    = parent,
        })
    end

    local function mkScroll(parent, height)
        local s = mk("ScrollingFrame", {
            BackgroundColor3    = COL.BG,
            Size                = UDim2.new(1, 0, 0, height),
            CanvasSize          = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness  = 4,
            BorderSizePixel     = 0,
            Parent              = parent,
        })
        addCorner(s, UDim.new(0, 6))
        addStroke(s, 1, 0.2)
        mk("UIListLayout", { SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=s })
        mk("UIPadding", { PaddingTop=UDim.new(0,4), PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), Parent=s })
        return s
    end

    local function mkCard(parent, height)
        local c = mk("Frame", {
            BackgroundColor3 = COL.CARD,
            Size = UDim2.new(1, 0, 0, height or 40),
            Parent = parent,
        })
        addCorner(c, UDim.new(0, 6))
        addStroke(c, 1, 0.25)
        return c
    end

    local function mkInput(parent, placeholder, width, height)
        local box = mk("TextBox", {
            BackgroundColor3     = Color3.fromRGB(252, 249, 244),
            BorderSizePixel      = 0,
            ClearTextOnFocus     = false,
            Font                 = Enum.Font.GothamMedium,
            PlaceholderText      = placeholder or "",
            PlaceholderColor3    = COL.MUTED,
            Text                 = "",
            TextColor3           = COL.TEXT,
            TextSize             = 11,
            TextXAlignment       = Enum.TextXAlignment.Left,
            Size                 = UDim2.new(0, width or 180, 0, height or 28),
            Parent               = parent,
        })
        addCorner(box, UDim.new(0, 6))
        addStroke(box, 1, 0.3)
        mk("UIPadding", { PaddingLeft=UDim.new(0,8), Parent=box })
        return box
    end

    -- ── Sub-tab system ────────────────────────────────────────────────────────
    local SUB_TABS = { "Overview", "Bindings", "Execute", "Macros", "Log" }
    local subPages = {}
    local subTabBtns = {}
    local activeSubTab = nil

    local tabBar = mk("Frame", {
        BackgroundTransparency = 1,
        Size     = UDim2.new(1, -24, 0, 32),
        Position = UDim2.new(0, 12, 0, 8),
        Parent   = pageTSR,
    })
    mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,6), Parent=tabBar })

    local pageHolder = mk("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 0, 48),
        Size     = UDim2.new(1, 0, 1, -48),
        Parent   = pageTSR,
    })

    local function switchSubTab(name)
        for n, pg in pairs(subPages)    do pg.Visible = n == name end
        for n, btn in pairs(subTabBtns) do
            tween(btn, TweenInfo.new(0.1), {
                BackgroundColor3 = n == name
                    and Color3.fromRGB(236, 229, 219)
                    or  Color3.fromRGB(245, 239, 231)
            })
        end
        activeSubTab = name
    end

    for _, name in ipairs(SUB_TABS) do
        local btn = mk("TextButton", {
            AutoButtonColor  = false,
            BackgroundColor3 = Color3.fromRGB(245, 239, 231),
            BorderSizePixel  = 0,
            Size             = UDim2.new(0, 88, 0, 28),
            Font             = Enum.Font.GothamSemibold,
            Text             = name,
            TextColor3       = COL.TEXT,
            TextSize         = 11,
            Parent           = tabBar,
        })
        addCorner(btn, UDim.new(0, 8))
        addStroke(btn, 1, 0.5)
        hookHover(btn, btn.BackgroundColor3, Color3.fromRGB(252,246,238), 0.5, 0.3)
        subTabBtns[name] = btn

        local pg = mk("ScrollingFrame", {
            BackgroundTransparency = 1,
            BorderSizePixel        = 0,
            Size                   = UDim2.new(1, 0, 1, 0),
            CanvasSize             = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize    = Enum.AutomaticSize.Y,
            ScrollBarThickness     = 6,
            Visible                = false,
            Parent                 = pageHolder,
        })
        mk("UIListLayout", { SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,8), Parent=pg })
        mk("UIPadding", { PaddingTop=UDim.new(0,8), PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12), PaddingBottom=UDim.new(0,8), Parent=pg })
        subPages[name] = pg

        btn.MouseButton1Click:Connect(function()
            clickSound(); switchSubTab(name)
        end)
    end

    -- ── TAB 1: Overview ───────────────────────────────────────────────────────
    do
        local pg = subPages["Overview"]

        -- Status + controls
        local _, sStatus = makeSection(pg, "Sovereign Runtime")
        mkLabel(sStatus, "TSR discovers, binds, and executes game intents autonomously.", 10, COL.MUTED)

        local ctrlRow = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,34), Parent=sStatus })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=ctrlRow })

        local startBtn   = makeButton(ctrlRow, "▶ Start TSR",    UDim2.new(0,130,0,30), "")
        local bindBtn    = makeButton(ctrlRow, "⟳ Refresh Bind", UDim2.new(0,140,0,30), "")
        local saveBtn    = makeButton(ctrlRow, "💾 Save",         UDim2.new(0,80,0,30),  "")
        startBtn.Button.BackgroundColor3 = Color3.fromRGB(210,240,215)
        bindBtn.Button.BackgroundColor3  = Color3.fromRGB(220,230,255)
        saveBtn.Button.BackgroundColor3  = Color3.fromRGB(240,235,255)

        -- Stats grid
        local _, sStats = makeSection(pg, "Session Stats")
        local statGrid  = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,80), Parent=sStats })
        mk("UIGridLayout", { CellSize=UDim2.new(0.5,-4,0,36), CellPadding=UDim2.new(0,6,0,6), Parent=statGrid })

        local statLabels = {}
        for _, def in ipairs({
            {key="bound",    label="Bound Intents"},
            {key="calls",    label="Total Calls"},
            {key="success",  label="Successes"},
            {key="rate",     label="Success Rate"},
        }) do
            local card = mkCard(statGrid, 36)
            mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=card })
            mkLabel(card, def.label, 9, COL.MUTED)
            local val = mkLabel(card, "—", 14, COL.TEXT, true)
            val.Position = UDim2.new(0,8,0,16)
            val.Size     = UDim2.new(1,-12,0,18)
            statLabels[def.key] = val
        end

        -- Category progress
        local _, sCats = makeSection(pg, "Binding Progress by Category")
        local catScroll = mkScroll(sCats, 180)
        local catRows   = {}

        local function refreshOverview()
            local reg     = _C.TSR and _C.TSR.Registry
            local runtime = _C.TSR and _C.TSR.Runtime
            if not reg or not runtime then return end

            local summary = reg.GetSummary()
            local stats   = runtime.GetStats()

            statLabels["bound"].Text   = tostring(summary.bound)
            statLabels["calls"].Text   = tostring(stats.CallCount)
            statLabels["success"].Text = tostring(stats.SuccessCount)
            statLabels["rate"].Text    = string.format("%.0f%%", stats.SuccessRate * 100)

            -- Category rows
            for _, ch in ipairs(catScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            for cat, data in pairs(summary.byCategory or {}) do
                local pct = data.total > 0 and data.bound/data.total or 0
                local row = mk("Frame", {
                    BackgroundColor3 = COL.CARD,
                    Size = UDim2.new(1,0,0,32),
                    Parent = catScroll,
                })
                addCorner(row, UDim.new(0,5))
                mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=row })

                local icon = CAT_ICONS[cat] or "•"
                mkLabel(row,
                    string.format("%s %-20s %d/%d (%.0f%%)",
                        icon, cat, data.bound, data.total, pct*100),
                    10, pct >= 0.5 and COL.BOUND or COL.UNBOUND, true
                ).Size = UDim2.new(1,-12, 0, 22)

                -- Progress bar
                local bar = mk("Frame", {
                    BackgroundColor3 = pct >= 0.5 and COL.BOUND or COL.UNBOUND,
                    Size = UDim2.new(pct, 0, 0, 2),
                    Position = UDim2.new(0, 0, 1, -3),
                    BackgroundTransparency = 0.4,
                    Parent = row,
                })
                addCorner(bar, UDim.new(0,2))
            end
        end

        startBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(startBtn.Button)
            local rt = _C.TSR and _C.TSR.Runtime
            if rt then
                sendNotification("TSR Runtime already running.", "Info")
            else
                sendNotification("TSR modules not loaded.", "Warning")
            end
            refreshOverview()
        end)
        bindBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(bindBtn.Button)
            local binder = _C.TSR and _C.TSR.Binder
            if binder then
                local n = binder.RefreshQueue()
                sendNotification(string.format("Queued %d intents for binding.", n), "Info")
            end
        end)
        saveBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local reg = _C.TSR and _C.TSR.Registry
            if reg then reg.Save(); sendNotification("TSR bindings saved.", "Success") end
        end)

        task.spawn(function()
            while true do
                task.wait(4)
                if pageTSR.Visible and activeSubTab == "Overview" then
                    pcall(refreshOverview)
                end
            end
        end)
    end

    -- ── TAB 2: Bindings ───────────────────────────────────────────────────────
    do
        local pg = subPages["Bindings"]
        local _, sB = makeSection(pg, "Intent Binding Browser")
        mkLabel(sB, "Green = bound and callable. Orange = not yet bound.", 10, COL.MUTED)

        -- Filter row
        local filterRow = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,30), Parent=sB })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=filterRow })
        local catFilter = nil
        local cats = { nil, "Economy", "WorldInteraction", "CharacterState",
                        "CharacterPhysical", "SocialIdentity", "Administrative" }
        local catIdx = 1
        local catBtn = makeButton(filterRow, "Cat: ALL",   UDim2.new(0,120,0,28), "")
        local showBtn = makeButton(filterRow, "Bound Only", UDim2.new(0,110,0,28), "")
        local refBtn  = makeButton(filterRow, "Refresh",    UDim2.new(0,90, 0,28), "")
        catBtn.Button.BackgroundColor3  = Color3.fromRGB(230,225,255)
        showBtn.Button.BackgroundColor3 = Color3.fromRGB(215,240,215)
        refBtn.Button.BackgroundColor3  = Color3.fromRGB(220,235,255)

        local showBoundOnly = false
        local bindScroll = mkScroll(sB, 320)

        local function refreshBindings()
            for _, ch in ipairs(bindScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local reg = _C.TSR and _C.TSR.Registry
            if not reg then mkLabel(bindScroll,"Registry not loaded.",11,COL.MUTED); return end

            local intents  = reg.GetIntents(catFilter)
            local bindings = reg.GetAllBindings()
            local rows     = {}

            for name, intent in pairs(intents) do
                local binding = bindings[name]
                if not showBoundOnly or binding then
                    table.insert(rows, { name=name, intent=intent, binding=binding })
                end
            end
            table.sort(rows, function(a,b)
                -- Bound first, then alphabetical
                local ab, bb = a.binding~=nil, b.binding~=nil
                if ab ~= bb then return ab end
                return a.name < b.name
            end)

            if #rows == 0 then
                mkLabel(bindScroll, "No intents match filter.", 11, COL.MUTED); return
            end

            for _, row in ipairs(rows) do
                local bound   = row.binding ~= nil
                local intent  = row.intent
                local binding = row.binding
                local risk    = intent.RiskLevel
                local icon    = CAT_ICONS[intent.Category] or "•"

                local card = mk("Frame", {
                    BackgroundColor3 = bound
                        and Color3.fromRGB(235,248,238)
                        or  Color3.fromRGB(252,246,235),
                    BackgroundTransparency = 0.4,
                    Size   = UDim2.new(1,0,0,52),
                    Parent = bindScroll,
                })
                addCorner(card, UDim.new(0,5))
                addStroke(card, 1, bound and 0.3 or 0.4,
                    bound and COL.BOUND or COL.UNBOUND)
                mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=card })

                -- Header row
                mkLabel(card,
                    string.format("%s [%s] %s%s",
                        icon,
                        bound and "✓" or "○",
                        row.name,
                        risk and (" ["..risk.."]") or ""),
                    11, bound and COL.BOUND or COL.UNBOUND, true
                ).Size = UDim2.new(1,-12, 0, 14)

                -- Detail row
                local detail = bound
                    and string.format("→ %s  conf:%.0f%%  fires:%d  %s",
                        binding.remoteName or "compound",
                        (binding.confidence or 0)*100,
                        binding.fireCount or 0,
                        binding.strategy or "")
                    or  string.format("params: %s | %s",
                        intent.Type,
                        table.concat((function()
                            local ps={}
                            for _,p in ipairs(intent.Parameters or {}) do
                                table.insert(ps, p.name..":"..p.kind)
                            end
                            return ps
                        end)(), ", "):sub(1,48))

                mkLabel(card, detail, 9, COL.MUTED
                ).Position = UDim2.new(0,8,0,20)

                -- Bind now button (if unbound)
                if not bound then
                    local bBtn = mk("TextButton", {
                        AutoButtonColor  = false,
                        BackgroundColor3 = Color3.fromRGB(230,225,255),
                        Size             = UDim2.new(0,70,0,18),
                        Position         = UDim2.new(1,-80,0,4),
                        Font             = Enum.Font.GothamMedium,
                        Text             = "Bind Now",
                        TextColor3       = COL.TEXT,
                        TextSize         = 9,
                        Parent           = card,
                    })
                    addCorner(bBtn, UDim.new(0,4))
                    bBtn.MouseButton1Click:Connect(function()
                        clickSound()
                        local binder = _C.TSR and _C.TSR.Binder
                        if binder then
                            binder.BindIntent(row.name)
                            sendNotification("Queued: " .. row.name, "Info")
                        end
                    end)
                end
            end
        end

        catBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            catIdx     = (catIdx % #cats) + 1
            catFilter  = cats[catIdx]
            catBtn.Label.Text = "Cat: " .. (catFilter and catFilter:sub(1,8) or "ALL")
            refreshBindings()
        end)
        showBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            showBoundOnly = not showBoundOnly
            showBtn.Label.Text = showBoundOnly and "All Intents" or "Bound Only"
            refreshBindings()
        end)
        refBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshBindings() end)
    end

    -- ── TAB 3: Execute ────────────────────────────────────────────────────────
    do
        local pg = subPages["Execute"]
        local _, sExec = makeSection(pg, "Execute Intent")
        mkLabel(sExec, "Call any bound intent directly. Args as JSON-like: {amount=100}", 10, COL.MUTED)

        local exRow = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,34), Parent=sExec })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=exRow })

        local intentInput = mkInput(exRow, "IntentName e.g. SetWalkSpeed", 200, 30)
        local argsInput   = mkInput(exRow, "Args e.g. speed=100", 160, 30)
        local execBtn     = makeButton(exRow, "▶ Execute", UDim2.new(0,100,0,30), "")
        execBtn.Button.BackgroundColor3 = Color3.fromRGB(210,240,215)

        local resultLabel = mkLabel(sExec, "", 11, COL.MUTED)

        -- Quick-call grid for top bound intents
        local _, sQuick = makeSection(pg, "Quick Call")
        mkLabel(sQuick, "Most recently bound intents.", 10, COL.MUTED)
        local quickScroll = mkScroll(sQuick, 260)

        local function refreshQuick()
            for _, ch in ipairs(quickScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local rt = _C.TSR and _C.TSR.Runtime
            if not rt then return end
            local callable = rt.GetCallable()
            if #callable == 0 then
                mkLabel(quickScroll, "No bound intents yet.", 11, COL.MUTED); return
            end
            for _, name in ipairs(callable) do
                local reg    = _C.TSR.Registry
                local intent = reg and reg.GetIntent(name)
                if intent then
                    local row = mk("Frame", {
                        BackgroundColor3 = COL.CARD,
                        BackgroundTransparency = 0.3,
                        Size   = UDim2.new(1,0,0,42),
                        Parent = quickScroll,
                    })
                    addCorner(row, UDim.new(0,5))
                    addStroke(row, 1, 0.2)
                    mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=row })

                    local icon = CAT_ICONS[intent.Category] or "•"
                    mkLabel(row, icon.." "..name, 11, COL.BOUND, true
                    ).Size = UDim2.new(0.7,0,0,14)

                    local paramStr = table.concat((function()
                        local ps={}
                        for _,p in ipairs(intent.Parameters or {}) do
                            table.insert(ps, p.name)
                        end
                        return ps
                    end)(), ", ")
                    mkLabel(row, paramStr:sub(1,40), 9, COL.MUTED
                    ).Position = UDim2.new(0,8,0,20)

                    local callBtn = mk("TextButton", {
                        AutoButtonColor  = false,
                        BackgroundColor3 = Color3.fromRGB(210,240,215),
                        Size             = UDim2.new(0,60,0,22),
                        Position         = UDim2.new(1,-68,0,10),
                        Font             = Enum.Font.GothamSemibold,
                        Text             = "Call",
                        TextColor3       = COL.TEXT,
                        TextSize         = 10,
                        Parent           = row,
                    })
                    addCorner(callBtn, UDim.new(0,4))

                    local capturedName = name
                    callBtn.MouseButton1Click:Connect(function()
                        clickSound(); pulseClick(callBtn)
                        intentInput.Text = capturedName
                        switchSubTab("Execute")
                    end)
                end
            end
        end

        -- Parse simple key=value args string
        local function parseArgs(str)
            local args = {}
            for key, val in str:gmatch("(%w+)%s*=%s*([^,}]+)") do
                local n = tonumber(val)
                if n then
                    args[key] = n
                elseif val == "true" then
                    args[key] = true
                elseif val == "false" then
                    args[key] = false
                else
                    args[key] = val:gsub("^[\"']",""):gsub("[\"']$","")
                end
            end
            return args
        end

        execBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(execBtn.Button)
            local intentName = intentInput.Text:match("^%s*(.-)%s*$")
            local argsStr    = argsInput.Text
            if intentName == "" then
                resultLabel.Text      = "⚠ Enter an intent name."
                resultLabel.TextColor3= COL.FAIL
                return
            end
            local args = parseArgs(argsStr)
            local rt   = _C.TSR and _C.TSR.Runtime
            if not rt then
                resultLabel.Text       = "⚠ Runtime not loaded."
                resultLabel.TextColor3 = COL.FAIL
                return
            end
            local ok, err = rt.Execute(intentName, args)
            if ok then
                resultLabel.Text       = "✓ " .. intentName .. " executed successfully."
                resultLabel.TextColor3 = COL.BOUND
                sendNotification(intentName .. " ✓", "Success")
            else
                resultLabel.Text       = "✗ Failed: " .. tostring(err)
                resultLabel.TextColor3 = COL.FAIL
                sendNotification(intentName .. " failed: " .. tostring(err), "Warning")
            end
            refreshQuick()
        end)

        pageTSR:GetPropertyChangedSignal("Visible"):Connect(function()
            if pageTSR.Visible then pcall(refreshQuick) end
        end)
    end

    -- ── TAB 4: Macros ─────────────────────────────────────────────────────────
    do
        local pg = subPages["Macros"]
        local _, sMac = makeSection(pg, "Built-in Macros")
        mkLabel(sMac, "Run sequences of intents in one click.", 10, COL.MUTED)

        local macroScroll = mkScroll(sMac, 240)

        local function refreshMacros()
            for _, ch in ipairs(macroScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local rt = _C.TSR and _C.TSR.Runtime
            if not rt then mkLabel(macroScroll,"Runtime not loaded.",11,COL.MUTED); return end

            for _, macroName in ipairs(rt.GetMacros()) do
                local row = mk("Frame", {
                    BackgroundColor3 = COL.CARD,
                    Size   = UDim2.new(1,0,0,38),
                    Parent = macroScroll,
                })
                addCorner(row, UDim.new(0,5))
                addStroke(row, 1, 0.2)
                mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,6), Parent=row })

                mkLabel(row, "⚙ "..macroName, 11, COL.TEXT, true
                ).Size = UDim2.new(0.7,0,0,16)

                local runBtn = mk("TextButton", {
                    AutoButtonColor  = false,
                    BackgroundColor3 = Color3.fromRGB(210,240,215),
                    Size             = UDim2.new(0,70,0,24),
                    Position         = UDim2.new(1,-80,0,7),
                    Font             = Enum.Font.GothamSemibold,
                    Text             = "▶ Run",
                    TextColor3       = COL.TEXT,
                    TextSize         = 10,
                    Parent           = row,
                })
                addCorner(runBtn, UDim.new(0,4))

                local capturedName = macroName
                runBtn.MouseButton1Click:Connect(function()
                    clickSound(); pulseClick(runBtn)
                    local results = rt.RunMacro(capturedName, 0.5)
                    local ok = 0; local total = results and #results or 0
                    if results then
                        for _, r in ipairs(results) do if r.ok then ok=ok+1 end end
                    end
                    sendNotification(string.format("%s: %d/%d steps ok", capturedName, ok, total),
                        ok == total and "Success" or "Warning")
                end)
            end
        end

        -- Custom macro builder
        local _, sCustom = makeSection(pg, "Custom Macro")
        mkLabel(sCustom, "Name your macro and list intents (comma separated).", 10, COL.MUTED)

        local macRow = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,34), Parent=sCustom })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=macRow })
        local macNameInput   = mkInput(macRow, "MacroName", 120, 30)
        local macIntentInput = mkInput(macRow, "Intent1, Intent2, ...", 200, 30)
        local macSaveBtn     = makeButton(macRow, "Save", UDim2.new(0,70,0,30), "")
        macSaveBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)

        macSaveBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local name     = macNameInput.Text:match("^%s*(.-)%s*$")
            local intents  = macIntentInput.Text
            if name == "" or intents == "" then return end
            local intentList = {}
            for part in intents:gmatch("[^,]+") do
                local trimmed = part:match("^%s*(.-)%s*$")
                if trimmed ~= "" then
                    table.insert(intentList, { intent=trimmed, args={} })
                end
            end
            local rt = _C.TSR and _C.TSR.Runtime
            if rt and #intentList > 0 then
                rt.DefineMacro(name, intentList)
                sendNotification("Macro '"..name.."' saved with "..#intentList.." steps.", "Success")
                refreshMacros()
            end
        end)

        pageTSR:GetPropertyChangedSignal("Visible"):Connect(function()
            if pageTSR.Visible then pcall(refreshMacros) end
        end)
    end

    -- ── TAB 5: Log ────────────────────────────────────────────────────────────
    do
        local pg = subPages["Log"]
        local _, sLog = makeSection(pg, "Transaction Log")
        mkLabel(sLog, "Most recent executions. Green = success, Red = failed.", 10, COL.MUTED)

        local logScroll = mkScroll(sLog, 340)
        local logCtrl = mk("Frame", {
            BackgroundTransparency=1, Size=UDim2.new(1,0,0,30), Parent=sLog })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=logCtrl })
        local logRefBtn = makeButton(logCtrl, "Refresh",     UDim2.new(0,100,0,28), "")
        local logFail   = makeButton(logCtrl, "Failures Only",UDim2.new(0,130,0,28), "")
        logRefBtn.Button.BackgroundColor3 = Color3.fromRGB(220,235,255)
        logFail.Button.BackgroundColor3   = Color3.fromRGB(255,225,220)

        local showFailOnly = false

        local function refreshLog()
            for _, ch in ipairs(logScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local rt = _C.TSR and _C.TSR.Runtime
            if not rt then mkLabel(logScroll,"Runtime not loaded.",11,COL.MUTED); return end

            local txLog = rt.GetTxLog(64)
            if #txLog == 0 then
                mkLabel(logScroll, "No transactions yet.", 11, COL.MUTED); return
            end
            for _, tx in ipairs(txLog) do
                if not showFailOnly or tx.success == false then
                    local row = mk("Frame", {
                        BackgroundColor3 = tx.success == true
                            and Color3.fromRGB(235,248,238)
                            or  tx.success == false
                            and Color3.fromRGB(255,235,235)
                            or  COL.CARD,
                        BackgroundTransparency = 0.4,
                        Size   = UDim2.new(1,0,0,52),
                        Parent = logScroll,
                    })
                    addCorner(row, UDim.new(0,5))
                    addStroke(row, 1, 0.2)
                    mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=row })

                    local statusIcon = tx.success == true and "✓" or tx.success == false and "✗" or "…"
                    mkLabel(row,
                        string.format("[%s] %s", statusIcon, tx.intentName or "?"),
                        11, tx.success and COL.BOUND or COL.FAIL, true
                    ).Size = UDim2.new(1,-12,0,14)

                    local dur = tx.endTime and tx.startTime
                        and string.format("%.2fs", tx.endTime - tx.startTime) or "…"
                    local binding = tx.binding
                    mkLabel(row,
                        string.format("via %s  dur:%s  steps:%d",
                            binding and binding.remoteName or "?",
                            dur,
                            tx.steps and #tx.steps or 0),
                        9, COL.MUTED
                    ).Position = UDim2.new(0,8,0,18)

                    if tx.error then
                        mkLabel(row, "err: "..tostring(tx.error):sub(1,60), 9, COL.FAIL
                        ).Position = UDim2.new(0,8,0,32)
                    end
                end
            end
        end

        logRefBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshLog() end)
        logFail.Button.MouseButton1Click:Connect(function()
            clickSound()
            showFailOnly = not showFailOnly
            logFail.Label.Text = showFailOnly and "All Tx" or "Failures Only"
            refreshLog()
        end)
    end

    -- Register TSR confirmation callback with the UI
    task.defer(function()
        local rt = _C.TSR and _C.TSR.Runtime
        if not rt then return end
        rt.SetConfirmationCallback(function(intentName, risk, args)
            -- For CRITICAL intents, require the user to explicitly
            -- call TSR_Runtime.Confirm() from the console.
            -- For now, warn and block.
            warn(string.format(
                "[TSR UI] Intent '%s' has RiskLevel %s. To run, call: _G.PC.TSR.Runtime.Execute('%s', args) from the console with intent confirmed.",
                intentName, risk, intentName))
            if risk == "CRITICAL" then return false end
            return true  -- HIGH and below pass through
        end)
    end)

    -- Default to Overview
    switchSubTab("Overview")
end
