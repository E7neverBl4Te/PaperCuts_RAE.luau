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
local pageSBI        = _U.pageSBI

-- ============================================================
-- PAGE: SBI — Server Behavior Inference
-- Sub-tabs: Overview · Behaviors · Causal · Validation · Predict
-- ============================================================

do
    local COL = {
        BG    = Color3.fromRGB(246, 243, 238),
        CARD  = Color3.fromRGB(239, 235, 229),
        TEXT  = Color3.fromRGB(50, 44, 38),
        MUTED = Color3.fromRGB(126, 116, 104),
        GREEN = Color3.fromRGB(52, 175, 72),
        AMBER = Color3.fromRGB(208, 146, 32),
        RED   = Color3.fromRGB(208, 58, 58),
        BLUE  = Color3.fromRGB(58, 118, 208),
        PURP  = Color3.fromRGB(136, 76, 200),
        TEAL  = Color3.fromRGB(38, 158, 148),
        ORANGE= Color3.fromRGB(212, 98, 42),
    }

    local LOGIC_COL = {
        ECONOMY_GRANT    = Color3.fromRGB(52,175,72),
        INVENTORY_MUTATE = Color3.fromRGB(136,76,200),
        SESSION_CONTROL  = Color3.fromRGB(58,118,208),
        PHYSICS_OVERRIDE = Color3.fromRGB(212,98,42),
        DIAGNOSTIC       = Color3.fromRGB(38,158,148),
        HEARTBEAT        = Color3.fromRGB(90,170,255),
        ANTICHEAT        = Color3.fromRGB(208,58,58),
        UNKNOWN          = Color3.fromRGB(126,116,104),
    }
    local VAL_COL = {
        NONE            = Color3.fromRGB(126,116,104),
        ALWAYS_ACCEPT   = Color3.fromRGB(52,175,72),
        ALWAYS_REJECT   = Color3.fromRGB(208,58,58),
        RANGE_CHECK     = Color3.fromRGB(208,146,32),
        ENUM_CHECK      = Color3.fromRGB(136,76,200),
        OWNERSHIP_CHECK = Color3.fromRGB(212,98,42),
        RATE_LIMIT      = Color3.fromRGB(58,118,208),
    }
    local AC_COL = {
        NONE          = Color3.fromRGB(126,116,104),
        PASSIVE       = Color3.fromRGB(90,170,255),
        MONITORS      = Color3.fromRGB(208,146,32),
        CORRECTS      = Color3.fromRGB(212,98,42),
        CORRECTS_FAST = Color3.fromRGB(208,58,58),
    }

    local function confColor(c)
        if c >= 0.70 then return COL.GREEN
        elseif c >= 0.40 then return COL.AMBER
        else return COL.RED end
    end
    local function confBar(parent, conf, lo)
        local bg = mk("Frame", {BackgroundColor3=Color3.fromRGB(224,218,210),
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

    -- ── Sub-tab system ────────────────────────────────────────────────────────
    local SUB_TABS = {"Overview","Behaviors","Causal","Validation","Predict"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab= nil

    local tabBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(239,234,227),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,38), Parent=pageSBI})
    addStroke(tabBar, 1, 0.4)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,4), Parent=tabBar})
    mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageSBI})

    local function makeSubPage()
        local p = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=4,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(172,162,150), Visible=false, Parent=subContent})
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,10), Parent=p})
        return p
    end

    for _, name in ipairs(SUB_TABS) do
        local btn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(247,243,238), BorderSizePixel=0,
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
                BackgroundColor3 = n==name and Color3.fromRGB(233,227,217) or Color3.fromRGB(247,243,238),
                TextColor3       = n==name and COL.TEXT or COL.MUTED,
            })
        end
        activeSubTab = name
    end
    for name, btn in pairs(subTabBtns) do
        btn.MouseButton1Click:Connect(function() clickSound(); switchSubTab(name) end)
    end

    local selectedRecord = nil  -- currently inspected BehaviorRecord

    -- ── TAB: Overview ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Overview"]

        local _, sStats = makeSection(pg, "Behavior Inference — Summary")
        local statsLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Building...", TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,40), Parent=sStats})

        -- Server logic breakdown
        local _, sLogic = makeSection(pg, "Server Logic Breakdown")
        local LOGIC_ORDER = {"ECONOMY_GRANT","INVENTORY_MUTATE","SESSION_CONTROL",
                              "PHYSICS_OVERRIDE","DIAGNOSTIC","HEARTBEAT","ANTICHEAT","UNKNOWN"}
        local logicRows = {}
        for i, l in ipairs(LOGIC_ORDER) do
            local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,238,232),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,32), LayoutOrder=i, Parent=sLogic})
            addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,8), Parent=row})
            local dot = mk("Frame", {BackgroundColor3=LOGIC_COL[l] or COL.MUTED,
                BorderSizePixel=0, Size=UDim2.new(0,10,0,10), Parent=row})
            addCorner(dot, UDim.new(0,999))
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=l, TextColor3=COL.TEXT, TextSize=10, Size=UDim2.new(0,160,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            local countL = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text="0", TextColor3=LOGIC_COL[l] or COL.MUTED, TextSize=12,
                Size=UDim2.new(0,40,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=row})
            logicRows[l] = countL
        end

        -- AC and validation breakdown
        local _, sACV = makeSection(pg, "AC & Validation Breakdown")
        local acvLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=COL.MUTED, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,48), Parent=sACV})

        local function doRefreshOverview()
            local SBI = _G.PC.SBI
            if not SBI then statsLabel.Text = "SBI not loaded."; return end
            local all    = SBI.GetAll()
            local total  = #all
            local hi70   = 0
            for _, r in ipairs(all) do if r.Confidence >= 0.70 then hi70 = hi70 + 1 end end

            statsLabel.Text = string.format(
                "Total BehaviorRecords: %d   High conf (≥70%%): %d\nFindings processed via AVD probe pipeline.",
                total, hi70)

            local lsum = SBI.GetLogicSummary()
            for l, cl in pairs(logicRows) do
                cl.Text = tostring(lsum[l] or 0)
            end

            local asum = SBI.GetACSummary()
            local vsum = SBI.GetValidationSummary()
            local acParts, vParts = {}, {}
            for k, v in pairs(asum) do if v > 0 then table.insert(acParts, k.."="..v) end end
            for k, v in pairs(vsum) do if v > 0 then table.insert(vParts, k.."="..v) end end
            table.sort(acParts); table.sort(vParts)
            acvLabel.Text = "AC: " .. table.concat(acParts, "  ") ..
                            "\nVal: " .. table.concat(vParts, "  ")
        end

        local btnRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=btnRow})
        local btnRebuild = makeButton(btnRow, "Rebuild All", UDim2.new(0,150,0,34), "🔄")
        local btnSave    = makeButton(btnRow, "Save", UDim2.new(0,110,0,34), "💾")
        btnRebuild.Button.BackgroundColor3 = Color3.fromRGB(220,235,255)
        btnSave.Button.BackgroundColor3    = Color3.fromRGB(220,255,220)

        btnRebuild.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRebuild.Button)
            local SBI = _G.PC.SBI
            if SBI then
                local n = SBI.Rebuild()
                sendNotification(string.format("SBI rebuild: %d records.", n), "Success")
                doRefreshOverview()
            end
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSave.Button)
            local SBI = _G.PC.SBI
            if SBI then SBI.Save(); sendNotification("SBI saved.", "Success") end
        end)
        task.defer(doRefreshOverview)
    end

    -- ── TAB: Behaviors — browsable record list ────────────────────────────────
    do
        local pg = subTabPages["Behaviors"]

        local _, sF = makeSection(pg, "Filter")
        local searchBox = mk("TextBox", {BackgroundColor3=Color3.fromRGB(247,243,238),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name, logic type, role...",
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sF})
        addCorner(searchBox, UDim.new(0,8)); addStroke(searchBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=searchBox})

        local _, sList = makeSection(pg, "Behavior Records")
        local listHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,7), Parent=listHolder})

        local function buildRecordCard(rec, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(246,241,235),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,68), LayoutOrder=order, Parent=listHolder})
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.32)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Row 1: name + logic chip + conf %
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=rec.Name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            local lchip = colorChip(r1, rec.ServerLogic, LOGIC_COL[rec.ServerLogic])
            lchip.Size = UDim2.new(0,130,0,20)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("%.0f%%", rec.Confidence*100),
                TextColor3=confColor(rec.Confidence), TextSize=12,
                Size=UDim2.new(0,40,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            -- Row 2: val chip + AC chip + type
            local r2 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=2, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,5), Parent=r2})
            local vchip = colorChip(r2, rec.ValidationPattern, VAL_COL[rec.ValidationPattern])
            vchip.Size = UDim2.new(0,120,0,18)
            local achip = colorChip(r2, rec.ACPattern, AC_COL[rec.ACPattern])
            achip.Size = UDim2.new(0,110,0,18)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%s · %s · links=%d · findings=%d",
                    rec.RemoteType, rec.Direction, #rec.CausalLinks, rec.FindingCount),
                TextColor3=COL.MUTED, TextSize=9, TextWrapped=false,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(0.5,0,1,0), Parent=r2})

            -- Row 3: conf bar
            confBar(card, rec.Confidence, 3)

            -- Click → inspect
            local hit = mk("TextButton", {BackgroundTransparency=1, Text="",
                BorderSizePixel=0, Size=UDim2.new(1,0,1,0), ZIndex=2, Parent=card})
            hookHover(card, card.BackgroundColor3, Color3.fromRGB(254,250,244), 0.35, 0.15)
            hit.MouseButton1Click:Connect(function()
                clickSound(); selectedRecord = rec; switchSubTab("Causal")
            end)
        end

        local function doRefreshBehaviors()
            for _, c in ipairs(listHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SBI = _G.PC.SBI
            if not SBI then return end
            local filter = searchBox.Text:lower()
            local all    = SBI.GetAll()
            local shown  = 0
            for _, rec in ipairs(all) do
                local match = filter == ""
                    or rec.Name:lower():find(filter,1,true)
                    or rec.ServerLogic:lower():find(filter,1,true)
                    or (rec.SemanticRole or ""):lower():find(filter,1,true)
                if match then
                    buildRecordCard(rec, shown+1)
                    shown = shown + 1
                    if shown >= 60 then break end
                end
            end
            if shown == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No records match.", TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=listHolder})
            end
        end

        searchBox:GetPropertyChangedSignal("Text"):Connect(function() task.defer(doRefreshBehaviors) end)
        local btnRef = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRef.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRef.Button); doRefreshBehaviors()
        end)
        subTabBtns["Behaviors"].MouseButton1Click:Connect(doRefreshBehaviors)
    end

    -- ── TAB: Causal — causal link inspector ───────────────────────────────────
    do
        local pg = subTabPages["Causal"]

        local nameLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a record from Behaviors.", TextColor3=COL.MUTED, TextSize=13,
            TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,20), Parent=pg})

        local _, sLinks = makeSection(pg, "Causal Links (path → Δ distribution)")
        local linksHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sLinks})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=linksHolder})

        local _, sSE = makeSection(pg, "Side Effects (cascade)")
        local seHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sSE})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,5), Parent=seHolder})

        local function buildLinkCard(lk, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,239,232),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=linksHolder})
            addCorner(card, UDim.new(0,9)); addStroke(card, 1, 0.28)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            local domColor = LOGIC_COL[lk.domain] or COL.MUTED
            local dot = mk("Frame", {BackgroundColor3=domColor, BorderSizePixel=0,
                Size=UDim2.new(0,8,0,8), Parent=r1})
            addCorner(dot, UDim.new(0,999))
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=lk.path or lk.varName or "?", TextColor3=COL.TEXT, TextSize=11,
                Size=UDim2.new(0.75,0,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("%.0f%%", (lk.confidence or 0)*100),
                TextColor3=confColor(lk.confidence or 0), TextSize=11,
                Size=UDim2.new(0.25,0,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("μ=%+.4g  σ=%.4g  [%.4g, %.4g]  n=%d  domain=%s",
                    lk.mean, lk.std, lk.min or 0, lk.max or 0, lk.n, lk.domain or "?"),
                TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=card})
            confBar(card, lk.confidence or 0, 3)
        end

        local function doRefreshCausal()
            for _, c in ipairs(linksHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            for _, c in ipairs(seHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local rec = selectedRecord
            if not rec then
                nameLabel.Text = "Select a record from Behaviors."
                return
            end
            nameLabel.Text = rec.Name .. "  →  " .. rec.ServerLogic

            if #rec.CausalLinks == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No causal links attributed yet — more probes needed.",
                    TextColor3=COL.MUTED, TextSize=12, TextWrapped=true,
                    Size=UDim2.new(1,0,0,32), Parent=linksHolder})
            else
                for i, lk in ipairs(rec.CausalLinks) do
                    buildLinkCard(lk, i)
                end
            end

            -- Side effects
            local seCount = 0
            for tgtName, se in pairs(rec.SideEffects) do
                seCount = seCount + 1
                local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,239,232),
                    BorderSizePixel=0, Size=UDim2.new(1,0,0,32), LayoutOrder=seCount, Parent=seHolder})
                addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                    PaddingTop=UDim.new(0,5), Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=tgtName, TextColor3=COL.TEXT, TextSize=11,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=row})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("conf %.0f%%  delay %s",
                        (se.confidence or 0)*100,
                        se.delayMs and string.format("~%.0fms", se.delayMs) or "unknown"),
                    TextColor3=COL.MUTED, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=row})
            end
            if seCount == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No cascade side-effects detected.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,24), Parent=seHolder})
            end
        end

        local btnC = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔬")
        btnC.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnC.Button); doRefreshCausal()
        end)
        subTabBtns["Causal"].MouseButton1Click:Connect(doRefreshCausal)
    end

    -- ── TAB: Validation — validation details ──────────────────────────────────
    do
        local pg = subTabPages["Validation"]

        local nameLabel2 = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a record from Behaviors.", TextColor3=COL.MUTED, TextSize=13,
            TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,20), Parent=pg})

        local _, sVD = makeSection(pg, "Validation Details")
        local valDetail = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=COL.TEXT, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=sVD})

        local _, sRL = makeSection(pg, "Rate Limit & AC")
        local rlDetail = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=COL.TEXT, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,52), Parent=sRL})

        local function doRefreshValidation()
            local rec = selectedRecord
            if not rec then
                nameLabel2.Text = "Select a record from Behaviors."
                valDetail.Text = "—"; rlDetail.Text = "—"
                return
            end
            nameLabel2.Text = rec.Name

            local ev = rec.ValidationEvidence
            local lines = {
                "Pattern: " .. rec.ValidationPattern,
            }
            if rec.ValidationPattern == "RANGE_CHECK" and ev.boundary ~= nil then
                table.insert(lines, string.format("Boundary: arg[%d] %s %.4g",
                    ev.boundaryAxis or 1,
                    ev.boundaryDir == "ABOVE_PASS" and "must be >" or "must be ≤",
                    ev.boundary))
            elseif rec.ValidationPattern == "ENUM_CHECK" then
                local s = ev.enumPassList and table.concat(ev.enumPassList, ", ") or "?"
                table.insert(lines, "Accepted values: " .. s)
            elseif rec.ValidationPattern == "OWNERSHIP_CHECK" then
                table.insert(lines, "Server verifies network ownership or session membership.")
            end

            local va = _G.PC.SBI and rawget(_G.PC, "SBI") and _G["SBI_ValAcc"] and _G["SBI_ValAcc"][rec.Name]
            -- Access via internal (not publicly exported; show totals from record)
            table.insert(lines, string.format("Probe count: %d   Findings: %d",
                rec.ProbeCount, rec.FindingCount))
            valDetail.Text = table.concat(lines, "\n")
            valDetail.Size = UDim2.new(1,0,0,math.max(48, #lines*16+4))

            local rlLines = {
                string.format("Throttle floor: %s",
                    rec.ThrottleFloor and string.format("%.2fs", rec.ThrottleFloor) or "unknown"),
                string.format("Burst capacity: %s",
                    rec.BurstCapacity and tostring(rec.BurstCapacity) or "unknown"),
                string.format("AC pattern: %s   Corr Hz: %.3f   Evidence: %d",
                    rec.ACPattern, rec.ACCorrectionHz or 0, rec.ACEvidenceCount or 0),
            }
            rlDetail.Text = table.concat(rlLines, "\n")
        end

        local btnV = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔎")
        btnV.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnV.Button); doRefreshValidation()
        end)
        subTabBtns["Validation"].MouseButton1Click:Connect(doRefreshValidation)
    end

    -- ── TAB: Predict — PredictOutcome ─────────────────────────────────────────
    do
        local pg = subTabPages["Predict"]

        local _, sInput = makeSection(pg, "Remote & Args")
        local remoteBox = mk("TextBox", {BackgroundColor3=Color3.fromRGB(247,243,238),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sInput})
        addCorner(remoteBox, UDim.new(0,8)); addStroke(remoteBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=remoteBox})

        local _, sOut = makeSection(pg, "Predicted Outcome")
        local outcomeLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Enter a remote name above and press Predict.",
            TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,52), Parent=sOut})

        local _, sEC = makeSection(pg, "Expected State Changes")
        local ecHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sEC})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,5), Parent=ecHolder})

        local function doPredict()
            for _, c in ipairs(ecHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SBI = _G.PC.SBI
            if not SBI then return end
            local name = remoteBox.Text:match("^%s*(.-)%s*$")
            if name == "" then
                outcomeLabel.Text = "Enter a remote name."
                return
            end
            local outcome = SBI.PredictOutcome(name, nil)

            -- Validation result color
            local vColor = COL.MUTED
            if outcome.validationResult == "PASS" then vColor = COL.GREEN
            elseif outcome.validationResult == "FAIL" then vColor = COL.RED end

            outcomeLabel.Text = string.format(
                "Logic:       %s\n" ..
                "Validation:  %s\n" ..
                "AC risk:     %.0f%%   Throttle risk: %s",
                outcome.serverLogic,
                outcome.validationResult,
                outcome.acRisk * 100,
                outcome.throttleRisk and "YES ⚠" or "no")

            -- Color validation line
            local lines = outcomeLabel.Text:split("\n")
            outcomeLabel.TextColor3 = COL.TEXT

            -- Expected changes
            if #outcome.expectedChanges == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No expected changes mapped yet.",
                    TextColor3=COL.MUTED, TextSize=12, TextWrapped=true,
                    Size=UDim2.new(1,0,0,28), Parent=ecHolder})
                return
            end
            for i, ch in ipairs(outcome.expectedChanges) do
                if i > 20 then break end
                local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,239,232),
                    BorderSizePixel=0, Size=UDim2.new(1,0,0,36), LayoutOrder=i, Parent=ecHolder})
                addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                    PaddingTop=UDim.new(0,5), Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})

                local r1 = mk("Frame", {BackgroundTransparency=1,
                    Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=row})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,5), Parent=r1})
                local domC = LOGIC_COL[ch.domain] or COL.MUTED
                local dot = mk("Frame", {BackgroundColor3=domC, BorderSizePixel=0,
                    Size=UDim2.new(0,8,0,8), Parent=r1})
                addCorner(dot, UDim.new(0,999))
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=(ch.varName or ch.path or "?"):sub(1,50),
                    TextColor3=COL.TEXT, TextSize=10, Size=UDim2.new(0.75,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("%.0f%%", ch.confidence*100),
                    TextColor3=confColor(ch.confidence), TextSize=11,
                    Size=UDim2.new(0.25,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

                local arrow = (ch.expectedDelta or 0) >= 0 and "▲" or "▼"
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("%s%+.4g ± %.4g  [%s]  src=%s",
                        arrow, ch.expectedDelta or 0, ch.uncertainty or 0,
                        ch.domain or "?", ch.source or "?"),
                    TextColor3=COL.MUTED, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=row})
            end
        end

        local btnP = makeButton(pg, "Predict Outcome", UDim2.new(0,160,0,34), "🔮")
        btnP.Button.BackgroundColor3 = Color3.fromRGB(245,235,255)
        btnP.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnP.Button); doPredict()
        end)
    end

    switchSubTab("Overview")
end
