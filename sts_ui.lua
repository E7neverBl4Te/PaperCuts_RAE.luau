-- ══════════════════════════════════════════════════════════════════════════════
-- STS_UI — Server Topology Scanner Interface
-- Self-registering: creates pageSTS, injects nav button, needs no ui_base edit.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Self-register page ────────────────────────────────────────────────────────
local _U2 = _G.PCU
local pageSTS = _U2.makePage("STS")

-- ── Self-inject nav button ────────────────────────────────────────────────────
-- Mirrors the exact button style used in boot.lua TAB_DEFS loop.
do
    local _C2      = _G.PC
    local mk2      = _C2.mk
    local addCorner2 = _C2.addCorner
    local addStroke2 = _C2.addStroke
    local hookHover2 = _C2.hookHover
    local tween2   = _C2.tween
    local navHolder  = _U2.navHolder
    local pagesFolder= _U2.pagesFolder
    local panelTitle = _U2.panelTitle

    local navBtn = mk2("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=Color3.fromRGB(245,239,231),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,34),
        Font=Enum.Font.GothamSemibold,
        Text="◈  STS",
        TextColor3=Color3.fromRGB(52,47,42),
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=navHolder,
    })
    mk2("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=navBtn})
    addCorner2(navBtn, UDim.new(0,10))
    local navStroke = addStroke2(navBtn, 1, 0.6)

    hookHover2(navBtn,
        Color3.fromRGB(245,239,231),
        Color3.fromRGB(236,229,219),
        Color3.fromRGB(52,47,42),
        Color3.fromRGB(52,47,42))

    navBtn.MouseButton1Click:Connect(function()
        _C2.clickSound()
        -- Hide all pages, show STS
        for _, page in ipairs(pagesFolder:GetChildren()) do
            page.Visible = false
        end
        pageSTS.Visible = true
        panelTitle.Text = "STS"
        -- Deactivate all other nav buttons
        for _, child in ipairs(navHolder:GetChildren()) do
            if child:IsA("TextButton") and child ~= navBtn then
                tween2(child, TweenInfo.new(0.12),
                    {BackgroundColor3=Color3.fromRGB(245,239,231)})
                local st = child:FindFirstChildOfClass("UIStroke")
                if st then
                    tween2(st, TweenInfo.new(0.12), {Transparency=0.6})
                end
            end
        end
        -- Activate this button
        tween2(navBtn, TweenInfo.new(0.12),
            {BackgroundColor3=Color3.fromRGB(236,229,219)})
        if navStroke then
            tween2(navStroke, TweenInfo.new(0.12), {Transparency=0.0})
        end
    end)

    -- Export reference
    _G.PCU.pageSTS = pageSTS
end

do
    local _C = _G.PC
    local _U = _G.PCU
    local mk               = _C.mk
    local addCorner        = _C.addCorner
    local addStroke        = _C.addStroke
    local pulseClick       = _C.pulseClick
    local tween            = _C.tween
    local clickSound       = _C.clickSound
    local sendNotification = _U.sendNotification
    local pageSTS          = _U.pageSTS

    -- ── Palette ────────────────────────────────────────────────────────────────
    local C = {
        BG         = Color3.fromRGB(10, 9, 14),
        SURFACE    = Color3.fromRGB(16, 15, 22),
        CARD       = Color3.fromRGB(20, 19, 28),
        BORDER     = Color3.fromRGB(36, 33, 50),
        TEXT       = Color3.fromRGB(210, 206, 235),
        MUTED      = Color3.fromRGB(72, 68, 95),
        DIM        = Color3.fromRGB(45, 42, 62),
        GREEN      = Color3.fromRGB(55, 200, 100),
        AMBER      = Color3.fromRGB(220, 168, 40),
        RED        = Color3.fromRGB(215, 60, 60),
        BLUE       = Color3.fromRGB(75, 145, 240),
        TEAL       = Color3.fromRGB(38, 196, 150),
        PURP       = Color3.fromRGB(148, 98, 238),
        GOLD       = Color3.fromRGB(255, 192, 38),
        ORANGE     = Color3.fromRGB(210, 100, 38),
        CYAN       = Color3.fromRGB(48, 210, 220),
    }

    -- Class type accent colors
    local CLASS_COL = {
        REMOTE      = C.TEAL,
        BINDABLE    = C.BLUE,
        MODULE      = C.PURP,
        LOCALSCRIPT = C.AMBER,
        SCRIPT      = C.ORANGE,
        VALUE       = C.GREEN,
        CONFIG      = C.GOLD,
        FOLDER      = C.MUTED,
        MODEL       = C.CYAN,
        SOUND       = C.BLUE,
        ANIMATION   = C.DIM,
        TEAM        = C.RED,
    }

    pageSTS.BackgroundColor3 = C.BG

    -- ══════════════════════════════════════════════════════════════════════════
    -- TOP BAR — title + scan button + status strip
    -- ══════════════════════════════════════════════════════════════════════════
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,56), Parent=pageSTS})
    addStroke(topBar, 1, 0.5)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=topBar})

    -- Title
    local titleLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="◈  Server Topology Scanner",
        TextColor3=C.TEAL, TextSize=15,
        Position=UDim2.new(0,0,0,0), Size=UDim2.new(0.5,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=topBar})

    local subtitleLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="Bedrock required — awaiting confirmation",
        TextColor3=C.MUTED, TextSize=10,
        Position=UDim2.new(0,0,0,24), Size=UDim2.new(0.7,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=topBar})

    -- Scan button
    local scanBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="⬛  Decompile Server",
        TextColor3=C.MUTED, TextSize=12,
        Position=UDim2.new(1,-200,0,6), Size=UDim2.new(0,192,0,36),
        Parent=topBar})
    addCorner(scanBtn, UDim.new(0,8))
    addStroke(scanBtn, 1, 0.5)
    local scanBtnStroke = scanBtn:FindFirstChildOfClass("UIStroke")

    -- Export row (right side, appears after scan)
    local exportRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,0), Size=UDim2.new(1,-210,0,40),
        Visible=false, Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        HorizontalAlignment=Enum.HorizontalAlignment.Right,
        Padding=UDim.new(0,6), Parent=exportRow})

    local function makeExportBtn(label, col, fmt)
        local b = mk("TextButton", {
            AutoButtonColor=false, BackgroundColor3=C.CARD,
            BorderSizePixel=0, Font=Enum.Font.GothamMedium,
            Text=label, TextColor3=col, TextSize=10,
            Size=UDim2.new(0,88,0,28), Parent=exportRow})
        addCorner(b, UDim.new(0,6))
        addStroke(b, 1, 0.4)
        b.MouseButton1Click:Connect(function()
            clickSound()
            local STS2 = _G.PC and _G.PC.STS
            if not STS2 then return end
            local text, err = STS2.Export(fmt)
            if text then
                local ok = pcall(function()
                    game:GetService("GuiService"):SetClipboard(text)
                end)
                sendNotification(ok and ("✓ " .. fmt .. " copied to clipboard") or
                    "✓ Export ready (see _G.PC.STS_Report)", "Success")
            else
                sendNotification("✗ " .. tostring(err), "Warning")
            end
        end)
        return b
    end
    makeExportBtn("Summary", C.TEAL, "SUMMARY")
    makeExportBtn("Remotes", C.CYAN, "REMOTES")
    makeExportBtn("Modules", C.PURP, "MODULES")

    -- ══════════════════════════════════════════════════════════════════════════
    -- PROGRESS BAR (visible during scan)
    -- ══════════════════════════════════════════════════════════════════════════
    local progressBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,56), Size=UDim2.new(1,0,0,28),
        Visible=false, Parent=pageSTS})
    addStroke(progressBar, 1, 0.6)
    mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=progressBar})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,10), Parent=progressBar})

    local progressFill_bg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(0.55,0,0,8), Parent=progressBar})
    addCorner(progressFill_bg, UDim.new(0,4))
    local progressFill = mk("Frame", {
        BackgroundColor3=C.TEAL, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=progressFill_bg})
    addCorner(progressFill, UDim.new(0,4))

    local progressLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="Initializing...", TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(0.44,0,1,0),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=progressBar})

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB BAR — Results views
    -- ══════════════════════════════════════════════════════════════════════════
    local CONTENT_Y = 56  -- shifts down when progress bar visible

    local tabBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_Y), Size=UDim2.new(1,0,0,34),
        Parent=pageSTS})
    addStroke(tabBar, 1, 0.6)
    mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})

    local RESULT_TABS = {
        { key="overview",  label="Overview"  },
        { key="remotes",   label="Remotes"   },
        { key="modules",   label="Modules"   },
        { key="values",    label="Values"    },
        { key="tree",      label="Tree"      },
    }

    local tabBtns  = {}
    local tabPages = {}
    local activeTab = nil

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_Y+34),
        Size=UDim2.new(1,0,1,-(CONTENT_Y+34)),
        ClipsDescendants=true, Parent=pageSTS})

    local function makeTabPage()
        local p = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            ScrollBarThickness=3,
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=C.MUTED,
            Visible=false, Parent=contentArea})
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10),
            Parent=p})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=p})
        return p
    end

    for _, tab in ipairs(RESULT_TABS) do
        local t = tab
        local btn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text=t.label,
            TextColor3=C.MUTED, TextSize=11,
            Size=UDim2.new(0,86,0,26), Parent=tabBar})
        addCorner(btn, UDim.new(0,6))
        addStroke(btn, 1, 0.5)
        tabBtns[t.key]  = btn
        tabPages[t.key] = makeTabPage()
    end

    local function switchTab(key)
        if activeTab == key then return end
        for k, p in pairs(tabPages) do p.Visible = (k==key) end
        for k, b in pairs(tabBtns) do
            local active = (k==key)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = active and C.SURFACE or C.CARD,
                TextColor3       = active and C.TEAL or C.MUTED,
            })
            if b:FindFirstChildOfClass("UIStroke") then
                b:FindFirstChildOfClass("UIStroke").Color =
                    active and C.TEAL or C.BORDER
            end
        end
        activeTab = key
    end

    for _, tab in ipairs(RESULT_TABS) do
        local k = tab.key
        tabBtns[k].MouseButton1Click:Connect(function()
            clickSound(); switchTab(k)
        end)
    end
    switchTab("overview")

    -- ══════════════════════════════════════════════════════════════════════════
    -- LOCKED OVERLAY — shown until scan completes
    -- ══════════════════════════════════════════════════════════════════════════
    local lockOverlay = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_Y+34),
        Size=UDim2.new(1,0,1,-(CONTENT_Y+34)),
        ZIndex=10, Parent=pageSTS})
    mk("UIListLayout", {
        VerticalAlignment=Enum.VerticalAlignment.Center,
        HorizontalAlignment=Enum.HorizontalAlignment.Center,
        Padding=UDim.new(0,12), Parent=lockOverlay})

    local lockIcon = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="◈", TextColor3=C.DIM, TextSize=52,
        Size=UDim2.new(1,0,0,60),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=lockOverlay})

    local lockTitle = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="Server Topology Scanner",
        TextColor3=C.MUTED, TextSize=15,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=lockOverlay})

    local lockSub = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="Confirm a Bedrock handshake, then press\n\"Decompile Server\" to begin the full scan.",
        TextColor3=C.DIM, TextSize=11, TextWrapped=true,
        Size=UDim2.new(0.6,0,0,36),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=lockOverlay})

    -- ══════════════════════════════════════════════════════════════════════════
    -- RESULT BUILDERS
    -- ══════════════════════════════════════════════════════════════════════════

    -- ── Shared: section header ─────────────────────────────────────────────
    local function sectionHeader(parent, title, color, lo)
        local hdr = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(18,17,26), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), LayoutOrder=lo or 1, Parent=parent})
        addCorner(hdr, UDim.new(0,5))
        addStroke(hdr, 1, 0.4)
        if hdr:FindFirstChildOfClass("UIStroke") then
            hdr:FindFirstChildOfClass("UIStroke").Color = color or C.MUTED
        end
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=hdr})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=title, TextColor3=color or C.MUTED, TextSize=11,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})
        return hdr
    end

    -- ── Shared: info row ──────────────────────────────────────────────────
    local function infoRow(parent, label, value, valColor, lo)
        local row = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,18), LayoutOrder=lo or 99, Parent=parent})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=row})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=label, TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(0,170,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
            Text=tostring(value), TextColor3=valColor or C.TEXT, TextSize=10,
            Size=UDim2.new(1,-186,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        return row
    end

    -- ── BUILD: Overview tab ────────────────────────────────────────────────
    local function buildOverview(report)
        local pg = tabPages["overview"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local lo = 1

        -- Stats cards row
        local statsRow = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,56), LayoutOrder=lo, Parent=pg})
        lo = lo + 1
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,8), Parent=statsRow})

        local function statCard(parent, label, value, col)
            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(0.2,-8,1,0), Parent=parent})
            addCorner(card, UDim.new(0,8))
            addStroke(card, 1, 0)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = col
            end
            mk("UIPadding", {
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,4),
                PaddingLeft=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=card})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=tostring(value), TextColor3=col, TextSize=18,
                Size=UDim2.new(1,0,0,24),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=card})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=label, TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,14),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=card})
        end

        statCard(statsRow, "Instances",    report.totalInstances, C.TEAL)
        statCard(statsRow, "Remotes",      report.totalRemotes,   C.CYAN)
        statCard(statsRow, "Modules",      report.totalModules,   C.PURP)
        statCard(statsRow, "Values",       report.totalValues,    C.GREEN)
        statCard(statsRow, "Configs",      report.totalConfigs or 0, C.GOLD)

        -- Service breakdown
        sectionHeader(pg, "Service Breakdown", C.TEAL, lo)
        lo = lo + 1

        local svcFrame = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=pg})
        addCorner(svcFrame, UDim.new(0,6))
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=svcFrame})
        mk("UIListLayout", {Padding=UDim.new(0,3), Parent=svcFrame})

        local svcList = {}
        for svcName, summary in pairs(report.serviceSummary) do
            table.insert(svcList, {name=svcName, n=summary.totalInstances, s=summary})
        end
        table.sort(svcList, function(a,b) return a.n > b.n end)

        for i, svc in ipairs(svcList) do
            local row = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=i, Parent=svcFrame})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                Text=svc.name, TextColor3=C.TEXT, TextSize=10,
                Size=UDim2.new(0,180,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            local barBg = mk("Frame", {
                BackgroundColor3=C.DIM, BorderSizePixel=0,
                Size=UDim2.new(1,-240,0,6), Parent=row})
            addCorner(barBg, UDim.new(0,3))
            local maxN = svcList[1].n
            local fill = mk("Frame", {
                BackgroundColor3=C.TEAL, BorderSizePixel=0,
                Size=UDim2.new(math.clamp(svc.n/math.max(maxN,1),0,1),0,1,0),
                Parent=barBg})
            addCorner(fill, UDim.new(0,3))
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=tostring(svc.n), TextColor3=C.MUTED, TextSize=10,
                Size=UDim2.new(0,50,1,0),
                TextXAlignment=Enum.TextXAlignment.Right, Parent=row})
        end

        -- Top remotes by intel score
        if report.totalRemotes > 0 then
            sectionHeader(pg, "Top Remotes  (by Intel Score)", C.CYAN, lo)
            lo = lo + 1

            local remFrame = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(remFrame, UDim.new(0,6))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=remFrame})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=remFrame})

            local shown = 0
            for _, entry in ipairs(report.sortedRemotes) do
                if shown >= 12 then break end
                local row = mk("Frame", {
                    BackgroundColor3=Color3.fromRGB(18,17,26), BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,28), LayoutOrder=shown+1, Parent=remFrame})
                addCorner(row, UDim.new(0,5))

                local accent = mk("Frame", {
                    BackgroundColor3=entry.className=="RemoteFunction" and C.CYAN or C.TEAL,
                    BorderSizePixel=0, Size=UDim2.new(0,3,1,0), Parent=row})
                addCorner(accent, UDim.new(0,3))

                local inner = mk("Frame", {
                    BackgroundTransparency=1, BorderSizePixel=0,
                    Position=UDim2.new(0,8,0,0), Size=UDim2.new(1,-12,1,0), Parent=row})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,8), Parent=inner})

                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=entry.name:sub(1,26), TextColor3=C.TEXT, TextSize=10,
                    Size=UDim2.new(0,180,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=inner})

                local confStr = entry.sbiConf
                    and string.format("%.0f%%", entry.sbiConf*100) or "—"
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="conf " .. confStr, TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(0,60,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=inner})

                if entry.bedrockPair then
                    local chip = mk("TextLabel", {
                        BackgroundColor3=Color3.fromRGB(20,36,28), BorderSizePixel=0,
                        Font=Enum.Font.GothamBold, Text="◈ BEDROCK",
                        TextColor3=C.GREEN, TextSize=8,
                        Size=UDim2.new(0,70,0,16),
                        TextXAlignment=Enum.TextXAlignment.Center, Parent=inner})
                    addCorner(chip, UDim.new(0,4))
                end

                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("[%.2f]", entry.intelScore or 0),
                    TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(0,40,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right, Parent=inner})

                shown = shown + 1
            end
        end
    end

    -- ── BUILD: Remotes tab ─────────────────────────────────────────────────
    local function buildRemotes(report)
        local pg = tabPages["remotes"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end

        local lo = 1
        for _, entry in ipairs(report.sortedRemotes) do
            local isRF = entry.className == "RemoteFunction"
            local accentCol = isRF and C.CYAN or C.TEAL

            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = C.BORDER
            end
            lo = lo + 1

            local strip = mk("Frame", {
                BackgroundColor3=accentCol, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,4))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7),
                PaddingRight=UDim.new(0,8), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=body})

            -- Header row
            local hdrRow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=hdrRow})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=entry.name, TextColor3=C.TEXT, TextSize=11,
                Size=UDim2.new(0.5,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=hdrRow})

            local classChip = mk("TextLabel", {
                BackgroundColor3=isRF and Color3.fromRGB(18,28,36) or Color3.fromRGB(16,28,26),
                BorderSizePixel=0, Font=Enum.Font.Code,
                Text=entry.className, TextColor3=accentCol, TextSize=9,
                Size=UDim2.new(0,110,0,16),
                TextXAlignment=Enum.TextXAlignment.Center, Parent=hdrRow})
            addCorner(classChip, UDim.new(0,4))

            if entry.bedrockPair then
                local bp = mk("TextLabel", {
                    BackgroundColor3=Color3.fromRGB(18,32,22), BorderSizePixel=0,
                    Font=Enum.Font.GothamBold, Text="◈ BEDROCK",
                    TextColor3=C.GREEN, TextSize=9,
                    Size=UDim2.new(0,76,0,16),
                    TextXAlignment=Enum.TextXAlignment.Center, Parent=hdrRow})
                addCorner(bp, UDim.new(0,4))
            end

            -- Path
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=entry.path, TextColor3=C.MUTED, TextSize=9,
                TextWrapped=false, TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=body})

            -- Intel rows
            local ilo = 3
            if entry.rsmSig then
                local r = entry.rsmSig
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format(
                        "RSM  fires=%-4d  success=%.0f%%  args=%d",
                        r.fireCount, (r.successRate or 0)*100, r.argCount),
                    TextColor3=C.CYAN, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end
            if entry.sbiConf then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("SBI  confidence=%.0f%%", entry.sbiConf*100),
                    TextColor3=C.PURP, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end
            if entry.cdgEdges and #entry.cdgEdges > 0 then
                for _, e in ipairs(entry.cdgEdges) do
                    mk("TextLabel", {
                        BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=string.format(
                            "CDG  ante=%-22s  conf=%.2f  co=%d",
                            e.ante:sub(1,22), e.conf or 0, e.coFired or 0),
                        TextColor3=C.AMBER, TextSize=9,
                        TextXAlignment=Enum.TextXAlignment.Left,
                        Size=UDim2.new(1,0,0,12), LayoutOrder=ilo, Parent=body})
                    ilo = ilo + 1
                end
            end
            if entry.bedrockPair then
                local bp = entry.bedrockPair
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format(
                        "BEDROCK  feedback=%-20s  origin=%s  conf=%.0f%%",
                        bp.feedback or "?", bp.origin or "?",
                        (bp.conf or 0)*100),
                    TextColor3=C.GREEN, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=ilo, Parent=body})
            end
        end
    end

    -- ── BUILD: Modules tab ─────────────────────────────────────────────────
    local function buildModules(report)
        local pg = tabPages["modules"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end

        if #report.moduleIndex == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No readable ModuleScripts found in replicated services.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        local lo = 1
        for _, mod in ipairs(report.moduleIndex) do
            local a = mod.analysis
            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = C.BORDER
            end
            lo = lo + 1

            local strip = mk("Frame", {
                BackgroundColor3=C.PURP, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,4))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                PaddingRight=UDim.new(0,8), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=body})

            -- Module name + stats row
            local hdr = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=hdr})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=mod.name, TextColor3=C.TEXT, TextSize=12,
                Size=UDim2.new(0.5,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%d lines  %d fn  %d bytes",
                    a.lineCount or 0, #a.functions, a.byteCount or 0),
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(0.5,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Right, Parent=hdr})

            -- Path
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=mod.path, TextColor3=C.DIM, TextSize=9,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=body})

            local ilo = 3

            -- Functions
            if #a.functions > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="fn  " .. table.concat(a.functions, "  ·  "):sub(1,180),
                    TextColor3=C.PURP, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Remote refs
            if #a.remoteRefs > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="remote  " .. table.concat(a.remoteRefs, "  "):sub(1,180),
                    TextColor3=C.TEAL, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- DataStores
            if #a.datastoreRefs > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="ds  " .. table.concat(a.datastoreRefs, "  "):sub(1,180),
                    TextColor3=C.AMBER, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- HTTP
            if #a.httpRefs > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="http  " .. table.concat(a.httpRefs, "  "):sub(1,180),
                    TextColor3=C.ORANGE, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Suspicious
            if #a.suspiciousKeys > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="⚠  " .. table.concat(a.suspiciousKeys, "  "):sub(1,180),
                    TextColor3=C.RED, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
            end
        end
    end

    -- ── BUILD: Values tab ──────────────────────────────────────────────────
    local function buildValues(report)
        local pg = tabPages["values"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end

        if #report.valueSchema == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No value objects found in replicated services.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        -- Group by service
        local bySvc = {}
        local svcOrder = {}
        for _, v in ipairs(report.valueSchema) do
            if not bySvc[v.service] then
                bySvc[v.service] = {}
                table.insert(svcOrder, v.service)
            end
            table.insert(bySvc[v.service], v)
        end

        local lo = 1
        for _, svcName in ipairs(svcOrder) do
            sectionHeader(pg, svcName, C.GREEN, lo)
            lo = lo + 1

            local block = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(block, UDim.new(0,6))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6),
                Parent=block})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=block})

            for i, v in ipairs(bySvc[svcName]) do
                local row = mk("Frame", {
                    BackgroundTransparency=1, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,18), LayoutOrder=i, Parent=block})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,8), Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text=v.name:sub(1,24), TextColor3=C.TEXT, TextSize=10,
                    Size=UDim2.new(0,160,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                local classChip = mk("TextLabel", {
                    BackgroundColor3=C.DIM, BorderSizePixel=0,
                    Font=Enum.Font.Code, Text=v.class:gsub("Value",""),
                    TextColor3=C.MUTED, TextSize=8,
                    Size=UDim2.new(0,56,0,14),
                    TextXAlignment=Enum.TextXAlignment.Center, Parent=row})
                addCorner(classChip, UDim.new(0,3))
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=tostring(v.value):sub(1,60),
                    TextColor3=C.GREEN, TextSize=10,
                    Size=UDim2.new(1,-240,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            end
        end
    end

    -- ── BUILD: Tree tab ────────────────────────────────────────────────────
    local function buildTree(report)
        local pg = tabPages["tree"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local lo = 1
        for _, svcEntry in ipairs(STS.SCAN_SERVICES) do
            local nodes = report.serviceMap[svcEntry.name]
            if not nodes or #nodes == 0 then continue end

            sectionHeader(pg, svcEntry.name ..
                string.format("  (%d)", #nodes), C.BLUE, lo)
            lo = lo + 1

            local block = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(block, UDim.new(0,6))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,8),
                PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4),
                Parent=block})
            mk("UIListLayout", {Padding=UDim.new(0,1), Parent=block})

            -- Show up to 200 nodes per service in tree view
            local shown = 0
            for _, node in ipairs(nodes) do
                if shown >= 200 then
                    mk("TextLabel", {
                        BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=string.format("  ... %d more nodes", #nodes - shown),
                        TextColor3=C.MUTED, TextSize=9,
                        Size=UDim2.new(1,0,0,14), LayoutOrder=shown+1,
                        TextXAlignment=Enum.TextXAlignment.Left, Parent=block})
                    break
                end
                shown = shown + 1

                local indent = string.rep("  ", math.min(node.depth-1, 8))
                local typeCol = (node.interestType and CLASS_COL[node.interestType])
                             or C.MUTED

                local row = mk("Frame", {
                    BackgroundTransparency=1, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=shown, Parent=block})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Parent=row})

                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=indent .. node.name,
                    TextColor3=typeCol, TextSize=9,
                    Size=UDim2.new(0.65,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=node.className,
                    TextColor3=C.DIM, TextSize=8,
                    Size=UDim2.new(0.35,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            end
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- SCAN BUTTON LOGIC
    -- ══════════════════════════════════════════════════════════════════════════
    local scanActive = false

    local function setScanReady(ready)
        if ready then
            tween(scanBtn, TweenInfo.new(0.3), {BackgroundColor3=C.TEAL})
            scanBtn.TextColor3 = Color3.fromRGB(10,10,14)
            scanBtn.Text = "◈  Decompile Server"
            if scanBtnStroke then
                tween(scanBtnStroke, TweenInfo.new(0.3), {Color=C.TEAL, Transparency=0.3})
            end
        else
            tween(scanBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
            scanBtn.TextColor3 = C.MUTED
            scanBtn.Text = "⬛  Decompile Server"
            if scanBtnStroke then
                tween(scanBtnStroke, TweenInfo.new(0.3), {Color=C.BORDER, Transparency=0.5})
            end
        end
    end

    scanBtn.MouseButton1Click:Connect(function()
        if scanActive then return end
        clickSound(); pulseClick(scanBtn)

        local STS2 = _G.PC and _G.PC.STS
        if not STS2 then
            sendNotification("STS module not loaded.", "Warning"); return
        end

        local ok, err = STS2.Scan()
        if not ok then
            sendNotification("✗ " .. tostring(err), "Warning"); return
        end

        -- UI: scanning state
        scanActive = true
        scanBtn.Text = "Scanning..."
        tween(scanBtn, TweenInfo.new(0.2), {BackgroundColor3=C.AMBER})
        progressBar.Visible = true
        lockOverlay.Visible = true

        -- Reposition tab bar and content area down
        tween(tabBar, TweenInfo.new(0.2),
            {Position=UDim2.new(0,0,0,CONTENT_Y+28)})
        tween(contentArea, TweenInfo.new(0.2),
            {Position=UDim2.new(0,0,0,CONTENT_Y+28+34),
             Size=UDim2.new(1,0,1,-(CONTENT_Y+28+34))})

        -- Wire progress callback
        STS2.OnProgress = function(phase, svc, count, total)
            if phase == 1 then
                local frac = total > 0 and (count/total) or 0
                tween(progressFill, TweenInfo.new(0.3),
                    {Size=UDim2.new(math.clamp(frac,0,1),0,1,0)})
                progressLabel.Text = string.format(
                    "Phase 1  Walking: %s  (%d/%d)", svc, count, total)
            elseif phase == 2 then
                tween(progressFill, TweenInfo.new(0.3), {Size=UDim2.new(0.85,0,1,0)})
                progressLabel.Text = string.format(
                    "Phase 2  Synthesizing — %d remotes", count)
            elseif phase == 3 then
                tween(progressFill, TweenInfo.new(0.4), {Size=UDim2.new(1,0,1,0)})
                progressLabel.Text = string.format(
                    "Complete — %d instances", count)
            elseif phase == -1 then
                progressLabel.Text = "ERROR: " .. svc
                progressLabel.TextColor3 = C.RED
            end
        end

        -- Wire completion callback
        STS2.OnComplete = function(report)
            scanActive = false
            lockOverlay.Visible = false
            exportRow.Visible = true

            -- Restore positions
            tween(tabBar, TweenInfo.new(0.3),
                {Position=UDim2.new(0,0,0,CONTENT_Y+28)})

            -- Update subtitle
            subtitleLabel.Text = string.format(
                "Last scan: %d instances · %d remotes · %d modules · %d values",
                report.totalInstances, report.totalRemotes,
                report.totalModules, report.totalValues)
            subtitleLabel.TextColor3 = C.TEAL

            -- Update scan button
            tween(scanBtn, TweenInfo.new(0.3), {BackgroundColor3=C.TEAL})
            scanBtn.Text = "↺  Rescan"
            scanBtn.TextColor3 = Color3.fromRGB(10,10,14)

            -- Populate all tabs
            pcall(buildOverview, report)
            pcall(buildRemotes,  report)
            pcall(buildModules,  report)
            pcall(buildValues,   report)
            pcall(buildTree,     report)

            switchTab("overview")
            sendNotification(string.format(
                "◈ Scan complete — %d instances, %d remotes, %d modules",
                report.totalInstances, report.totalRemotes, report.totalModules),
                "Success")

            -- Hide progress bar after a beat
            task.delay(1.5, function()
                progressBar.Visible = false
                tween(tabBar, TweenInfo.new(0.2),
                    {Position=UDim2.new(0,0,0,CONTENT_Y)})
                tween(contentArea, TweenInfo.new(0.2),
                    {Position=UDim2.new(0,0,0,CONTENT_Y+34),
                     Size=UDim2.new(1,0,1,-(CONTENT_Y+34))})
            end)
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- BEDROCK WATCHER — enable/disable scan button based on pipeline state
    -- ══════════════════════════════════════════════════════════════════════════
    task.spawn(function()
        while true do
            task.wait(2)
            if scanActive then continue end
            local ASE2 = _G.PC and _G.PC.ASE
            if not ASE2 then continue end
            local stats = ASE2.GetStats and ASE2.GetStats()
            local bedrockAlive = stats and stats.HeartbeatAlive
            setScanReady(bedrockAlive == true)
            if bedrockAlive then
                subtitleLabel.Text = string.format(
                    "Bedrock confirmed  ·  SINK: %s  ·  Ready to scan",
                    tostring(stats.ActiveSink or "?"):sub(1,24))
                subtitleLabel.TextColor3 = C.GREEN
                lockIcon.TextColor3 = C.TEAL
            else
                subtitleLabel.Text = "Awaiting Bedrock confirmation — run a Goal to establish pipeline"
                subtitleLabel.TextColor3 = C.MUTED
                lockIcon.TextColor3 = C.DIM
            end
        end
    end)
end