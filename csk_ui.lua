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
local pageCSK        = _U.pageCSK

-- ============================================================
-- PAGE: CSK — Cross-Session Knowledge
-- Sub-tabs: Overview · Sessions · Deltas · Stability · Knowledge
-- ============================================================

do
    local COL = {
        BG    = Color3.fromRGB(244, 240, 234),
        TEXT  = Color3.fromRGB(46, 40, 34),
        MUTED = Color3.fromRGB(122, 112, 100),
        GREEN = Color3.fromRGB(48, 171, 68),
        AMBER = Color3.fromRGB(204, 142, 28),
        RED   = Color3.fromRGB(204, 54, 54),
        BLUE  = Color3.fromRGB(54, 114, 204),
        PURP  = Color3.fromRGB(132, 72, 196),
        TEAL  = Color3.fromRGB(34, 154, 144),
        ORANGE= Color3.fromRGB(208, 94, 38),
    }

    local DELTA_COL = {
        APPEARED          = Color3.fromRGB(48,171,68),
        DISAPPEARED       = Color3.fromRGB(122,112,100),
        CONF_REGRESSION   = Color3.fromRGB(204,54,54),
        BOUNDARY_SHIFT    = Color3.fromRGB(204,142,28),
        LOGIC_CHANGE      = Color3.fromRGB(54,114,204),
        VALIDATION_CHANGE = Color3.fromRGB(132,72,196),
    }

    local function confColor(c)
        if c >= 0.70 then return COL.GREEN
        elseif c >= 0.40 then return COL.AMBER
        else return COL.RED end
    end
    local function stabilityColor(s)
        if s >= 0.75 then return COL.GREEN
        elseif s >= 0.50 then return COL.AMBER
        else return COL.RED end
    end
    local function confBar(parent, frac, lo, col)
        local bg = mk("Frame", {BackgroundColor3=Color3.fromRGB(220,214,206),
            BorderSizePixel=0, Size=UDim2.new(1,0,0,5), LayoutOrder=lo or 99, Parent=parent})
        addCorner(bg, UDim.new(0,3))
        local fill = mk("Frame", {BackgroundColor3=col or confColor(frac),
            BorderSizePixel=0, Size=UDim2.new(math.clamp(frac,0,1),0,1,0), Parent=bg})
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
    local SUB_TABS = {"Overview","Sessions","Deltas","Stability","Knowledge"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab = nil

    local tabBar = mk("Frame", {BackgroundColor3=Color3.fromRGB(237,232,224),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,38), Parent=pageCSK})
    addStroke(tabBar, 1, 0.4)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,4), Parent=tabBar})
    mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageCSK})

    local function makeSubPage()
        local p = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=4,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(168,158,146), Visible=false, Parent=subContent})
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,10), Parent=p})
        return p
    end

    for _, name in ipairs(SUB_TABS) do
        local btn = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(245,240,234), BorderSizePixel=0,
            Size=UDim2.new(0,94,0,28), Font=Enum.Font.GothamMedium,
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
                BackgroundColor3 = n==name and Color3.fromRGB(230,224,214) or Color3.fromRGB(245,240,234),
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

        local _, sStats = makeSection(pg, "Cross-Session Intelligence — Summary")
        local statsLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Loading...", TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=sStats})

        local _, sDigest = makeSection(pg, "Intel Digest")
        local digestLabel = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=sDigest})

        -- Re-probe queue preview
        local _, sRP = makeSection(pg, "Re-Probe Queue (top 6)")
        local rpHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sRP})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,5), Parent=rpHolder})

        local function doRefreshOverview()
            local CSK = _G.PC.CSK
            if not CSK then statsLabel.Text = "CSK not loaded."; return end

            local stats = CSK.GetStats()
            statsLabel.Text = string.format(
                "Sessions recorded: %d   Current session: %s\n"..
                "Knowledge nodes: %d   Classified: %d\n"..
                "Deltas this session: %d   Regressions: %d\n"..
                "Re-probe queue: %d   Stability records: %d",
                stats.SessionCount,
                stats.CurrentSession and tostring(stats.CurrentSession) or "none",
                stats.KnowledgeNodes, stats.ClassifiedNodes,
                stats.DeltaCount, stats.RegressionCount,
                stats.ReprobeQueueLen, stats.StabilityRecords)

            digestLabel.Text = CSK.GetDigest()
            digestLabel.Size = UDim2.new(1,0,0, math.max(80, select(2, digestLabel.Text:gsub("\n",""))*16+16))

            -- Re-probe top-6
            for _, c in ipairs(rpHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local rq = CSK.GetReprobeQueue()
            if #rq == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="Queue empty — no re-investigation needed.",
                    TextColor3=COL.MUTED, TextSize=11,
                    Size=UDim2.new(1,0,0,24), Parent=rpHolder})
            else
                for i = 1, math.min(6, #rq) do
                    local entry = rq[i]
                    local row = mk("Frame", {BackgroundColor3=Color3.fromRGB(242,237,230),
                        BorderSizePixel=0, Size=UDim2.new(1,0,0,32), LayoutOrder=i, Parent=rpHolder})
                    addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
                    mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                        PaddingTop=UDim.new(0,5), Parent=row})
                    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                        VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=row})
                    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                        Text=entry.name, TextColor3=COL.TEXT, TextSize=10,
                        Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=entry.reason, TextColor3=COL.MUTED, TextSize=9,
                        Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                    mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                        Text=string.format("%.2f", entry.priority),
                        TextColor3=confColor(entry.priority), TextSize=11,
                        Size=UDim2.new(0,36,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=row})
                end
            end
        end

        local btnRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=btnRow})
        local btnSnap = makeButton(btnRow, "Force Snapshot", UDim2.new(0,150,0,34), "📸")
        local btnSave = makeButton(btnRow, "Save All",       UDim2.new(0,110,0,34), "💾")
        local btnRef  = makeButton(btnRow, "Refresh",        UDim2.new(0,110,0,34), "🔄")
        btnSnap.Button.BackgroundColor3 = Color3.fromRGB(220,235,255)
        btnSave.Button.BackgroundColor3 = Color3.fromRGB(220,255,220)

        btnSnap.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSnap.Button)
            local CSK2 = _G.PC.CSK
            if CSK2 then
                CSK2.ForceSnapshot()
                sendNotification("Snapshot captured.", "Success")
            end
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSave.Button)
            local CSK2 = _G.PC.CSK
            if CSK2 then CSK2.Save(); sendNotification("CSK state saved.", "Success") end
        end)
        btnRef.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRef.Button); doRefreshOverview()
        end)
        task.defer(doRefreshOverview)
    end

    -- ── TAB: Sessions ──────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Sessions"]

        local _, sList = makeSection(pg, "Session History (most recent first)")
        local sessHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,7), Parent=sessHolder})

        local function buildSessionCard(s, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,238,231),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=sessHolder})
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Header
            local hdr = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=hdr})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Session #%d", s.id or 0),
                TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,100,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})
            local dur = s.duration and string.format("%.0fs", s.duration) or "open"
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=dur, TextColor3=COL.MUTED, TextSize=10,
                Size=UDim2.new(0,50,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})

            -- Stats
            local nNew = 0; for _ in pairs(s.newClassifications or {}) do nNew=nNew+1 end
            local nGain = 0; for _ in pairs(s.confidenceGains or {}) do nGain=nGain+1 end
            local nBnd  = 0; for _ in pairs(s.newBoundaries or {}) do nBnd=nBnd+1 end
            local nVal  = 0; for _ in pairs(s.newValidationPatterns or {}) do nVal=nVal+1 end

            local statsText = string.format(
                "Remotes: %d counted / %d probed   +%d classified   AvgSBIGain: %.3f\n"..
                "Confidence gains: %d   New boundaries: %d   New validations: %d   Deltas: %d",
                s.remotesCounted or 0, s.remotesProbed or 0, nNew,
                s.avgSBIConfGain or 0,
                nGain, nBnd, nVal, s.deltasDetected or 0)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=statsText, TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,28), LayoutOrder=2, Parent=card})

            -- New classifications preview
            if nNew > 0 then
                local clRow = mk("Frame", {BackgroundTransparency=1,
                    Size=UDim2.new(1,0,0,20), LayoutOrder=3, Parent=card})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    Padding=UDim.new(0,4), Parent=clRow})
                local shown = 0
                for name, logic in pairs(s.newClassifications or {}) do
                    if shown >= 5 then
                        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                            Text=string.format("+%d more", nNew-5),
                            TextColor3=COL.MUTED, TextSize=9,
                            Size=UDim2.new(0,50,1,0), Parent=clRow})
                        break
                    end
                    local chip = colorChip(clRow, name:sub(1,14), COL.TEAL)
                    chip.Size = UDim2.new(0,100,0,18)
                    shown = shown + 1
                end
            end
        end

        local function doRefreshSessions()
            for _, c in ipairs(sessHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local CSK = _G.PC.CSK
            if not CSK then return end
            local sessions = CSK.GetSessions(16)
            if #sessions == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No session history yet.", TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=sessHolder})
                return
            end
            -- Most recent first
            for i = #sessions, 1, -1 do
                buildSessionCard(sessions[i], #sessions - i + 1)
            end
        end

        local btnRefS = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRefS.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefS.Button); doRefreshSessions()
        end)
        subTabBtns["Sessions"].MouseButton1Click:Connect(doRefreshSessions)
    end

    -- ── TAB: Deltas ────────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Deltas"]

        local _, sDFilter = makeSection(pg, "Filter")
        local filterBox = mk("TextBox", {BackgroundColor3=Color3.fromRGB(246,241,236),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name or delta type...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sDFilter})
        addCorner(filterBox, UDim.new(0,8)); addStroke(filterBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=filterBox})

        local _, sDList = makeSection(pg, "Inter-Session Deltas")
        local deltaHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sDList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=deltaHolder})

        local function buildDeltaCard(d, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,238,231),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,60), LayoutOrder=order, Parent=deltaHolder})
            addCorner(card, UDim.new(0,9)); addStroke(card, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Row 1: name + delta type chip + magnitude
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=d.name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            local dchip = colorChip(r1, d.deltaType, DELTA_COL[d.deltaType])
            dchip.Size = UDim2.new(0,140,0,20)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("⚡%.2f", d.magnitude),
                TextColor3=confColor(d.magnitude), TextSize=11,
                Size=UDim2.new(0,48,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            -- Row 2: prev → curr
            local prevStr = d.prevValue ~= nil and tostring(d.prevValue):sub(1,30) or "nil"
            local currStr = d.currValue ~= nil and tostring(d.currValue):sub(1,30) or "nil"
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%s  →  %s", prevStr, currStr),
                TextColor3=COL.MUTED, TextSize=9, TextWrapped=false,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=card})

            confBar(card, d.magnitude, 3, DELTA_COL[d.deltaType])
        end

        local function doRefreshDeltas()
            for _, c in ipairs(deltaHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local CSK = _G.PC.CSK
            if not CSK then return end
            local filter  = filterBox.Text:lower()
            local deltas  = CSK.GetDeltas(0)
            if #deltas == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No deltas detected since last session.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=deltaHolder})
                return
            end
            local shown = 0
            for _, d in ipairs(deltas) do
                local match = filter == ""
                    or d.name:lower():find(filter,1,true)
                    or d.deltaType:lower():find(filter,1,true)
                if match then
                    buildDeltaCard(d, shown+1); shown=shown+1
                    if shown >= 50 then break end
                end
            end
        end

        filterBox:GetPropertyChangedSignal("Text"):Connect(function() task.defer(doRefreshDeltas) end)
        local btnRefD = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRefD.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefD.Button); doRefreshDeltas()
        end)
        subTabBtns["Deltas"].MouseButton1Click:Connect(doRefreshDeltas)
    end

    -- ── TAB: Stability ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Stability"]

        local _, sSF = makeSection(pg, "Filter")
        local stabFilter = mk("TextBox", {BackgroundColor3=Color3.fromRGB(246,241,236),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sSF})
        addCorner(stabFilter, UDim.new(0,8)); addStroke(stabFilter, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=stabFilter})

        local _, sStabList = makeSection(pg, "Stability Records (least stable first)")
        local stabHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sStabList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=stabHolder})

        local function buildStabCard(srec, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,238,231),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,68), LayoutOrder=order, Parent=stabHolder})
            addCorner(card, UDim.new(0,9)); addStroke(card, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Row 1: name + stability score + drift badge
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=srec.name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,200,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            local stab = srec.stabilityScore or 1
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("%.0f%%", stab*100),
                TextColor3=stabilityColor(stab), TextSize=13,
                Size=UDim2.new(0,40,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})
            if srec.driftDetected then
                local dchip = colorChip(r1, "⚠ DRIFT", COL.RED)
                dchip.Size = UDim2.new(0,70,0,18)
            end

            -- Row 2: meta info
            local meta = string.format("Sessions: %d   Logic: %s   Val: %s   Throttle: %s",
                srec.sessionsSeen,
                srec.lastServerLogic or "UNKNOWN",
                srec.lastValidationPattern or "NONE",
                srec.lastThrottleFloor and string.format("%.2fs", srec.lastThrottleFloor) or "?")
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=meta, TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,13), LayoutOrder=2, Parent=card})

            -- Confidence history sparkline (text-based)
            local sparkParts = {}
            local SPARK_CHARS = {"▁","▂","▃","▄","▅","▆","▇","█"}
            local hist = srec.confidenceHistory or {}
            local max = 0.01
            for _, h in ipairs(hist) do if h.conf > max then max = h.conf end end
            for i = math.max(1, #hist-15), #hist do
                local h = hist[i]
                local idx = math.max(1, math.min(8, math.floor(h.conf/max*8)))
                table.insert(sparkParts, SPARK_CHARS[idx])
            end
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="Conf history: " .. table.concat(sparkParts),
                TextColor3=stabilityColor(stab), TextSize=10,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,13), LayoutOrder=3, Parent=card})

            -- Stability bar
            confBar(card, stab, 4, stabilityColor(stab))
        end

        local function doRefreshStability()
            for _, c in ipairs(stabHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local CSK = _G.PC.CSK
            if not CSK then return end
            local filter = stabFilter.Text:lower()
            local all    = CSK.GetAllStability(1)
            local shown  = 0
            for _, srec in ipairs(all) do
                local match = filter == "" or srec.name:lower():find(filter,1,true)
                if match then
                    buildStabCard(srec, shown+1); shown=shown+1
                    if shown >= 50 then break end
                end
            end
            if shown == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No stability records yet — requires multiple sessions.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=stabHolder})
            end
        end

        stabFilter:GetPropertyChangedSignal("Text"):Connect(function() task.defer(doRefreshStability) end)
        local btnRefSt = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRefSt.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefSt.Button); doRefreshStability()
        end)
        subTabBtns["Stability"].MouseButton1Click:Connect(doRefreshStability)
    end

    -- ── TAB: Knowledge ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Knowledge"]

        local _, sKF = makeSection(pg, "Filter")
        local knowFilter = mk("TextBox", {BackgroundColor3=Color3.fromRGB(246,241,236),
            BorderSizePixel=0, ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Remote name, logic type...", PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sKF})
        addCorner(knowFilter, UDim.new(0,8)); addStroke(knowFilter, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=knowFilter})

        local _, sKL = makeSection(pg, "Knowledge Graph — Lifecycle Records")
        local knowHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sKL})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,7), Parent=knowHolder})

        local LOGIC_COL = {
            ECONOMY_GRANT    = Color3.fromRGB(48,171,68),
            INVENTORY_MUTATE = Color3.fromRGB(132,72,196),
            SESSION_CONTROL  = Color3.fromRGB(54,114,204),
            PHYSICS_OVERRIDE = Color3.fromRGB(208,94,38),
            DIAGNOSTIC       = Color3.fromRGB(34,154,144),
            HEARTBEAT        = Color3.fromRGB(88,168,255),
            ANTICHEAT        = Color3.fromRGB(204,54,54),
            UNKNOWN          = Color3.fromRGB(122,112,100),
        }

        local function buildKnowledgeCard(knode, order)
            local card = mk("Frame", {BackgroundColor3=Color3.fromRGB(243,238,231),
                BorderSizePixel=0, Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=knowHolder})
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.30)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Row 1: name + logic chip + peak conf
            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=knode.name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,180,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            local lchip = colorChip(r1, knode.serverLogic or "UNKNOWN",
                LOGIC_COL[knode.serverLogic] or COL.MUTED)
            lchip.Size = UDim2.new(0,130,0,20)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("peak %.0f%%", (knode.peakConfidence or 0)*100),
                TextColor3=confColor(knode.peakConfidence or 0), TextSize=11,
                Size=UDim2.new(0,60,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            -- Row 2: lifecycle stats
            local r2 = string.format(
                "Sessions: %d   Probes: %d   CausalLinks: %d   SideEffects: %d   Stability: %.0f%%",
                knode.sessionsSeen or 0, knode.totalProbes or 0,
                knode.causalLinkCount or 0, knode.sideEffectCount or 0,
                (knode.stabilityScore or 1)*100)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=r2, TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,13), LayoutOrder=2, Parent=card})

            -- Row 3: validation + throttle + boundary
            local r3Parts = {}
            if knode.validationPattern and knode.validationPattern ~= "NONE" then
                table.insert(r3Parts, "Val: " .. knode.validationPattern)
            end
            if knode.throttleFloor then
                table.insert(r3Parts, string.format("Throttle: %.2fs", knode.throttleFloor))
            end
            if knode.boundary ~= nil then
                table.insert(r3Parts, string.format("Bnd[%d]=%.4g", knode.boundaryAxis or 1, knode.boundary))
            end
            if knode.acPattern and knode.acPattern ~= "NONE" then
                table.insert(r3Parts, "AC: " .. knode.acPattern)
            end
            if #r3Parts > 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=table.concat(r3Parts, "  "), TextColor3=COL.TEAL, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,13), LayoutOrder=3, Parent=card})
            end

            -- Notes
            if knode.notes and #knode.notes > 0 then
                local lastNote = knode.notes[#knode.notes]
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="Note: " .. tostring(lastNote.text):sub(1,80),
                    TextColor3=COL.AMBER, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=4, Parent=card})
            end

            -- Confidence bar
            confBar(card, knode.currentConfidence or 0, 5)
        end

        local function doRefreshKnowledge()
            for _, c in ipairs(knowHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local CSK = _G.PC.CSK
            if not CSK then return end
            local filter = knowFilter.Text:lower()
            local all    = CSK.GetAllKnowledge(0)
            local shown  = 0
            for _, knode in ipairs(all) do
                local match = filter == ""
                    or knode.name:lower():find(filter,1,true)
                    or (knode.serverLogic or ""):lower():find(filter,1,true)
                    or (knode.validationPattern or ""):lower():find(filter,1,true)
                if match then
                    buildKnowledgeCard(knode, shown+1); shown=shown+1
                    if shown >= 60 then break end
                end
            end
            if shown == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No knowledge nodes yet.", TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=knowHolder})
            end
        end

        knowFilter:GetPropertyChangedSignal("Text"):Connect(function() task.defer(doRefreshKnowledge) end)
        local btnRefK = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        btnRefK.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefK.Button); doRefreshKnowledge()
        end)
        subTabBtns["Knowledge"].MouseButton1Click:Connect(doRefreshKnowledge)
    end

    switchSubTab("Overview")
end
