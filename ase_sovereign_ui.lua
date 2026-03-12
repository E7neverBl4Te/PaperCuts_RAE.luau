-- ══════════════════════════════════════════════════════════════════════════════
-- SOVEREIGN_UI — Sovereign ACE Interface
-- Self-registering standalone page. Dark terminal aesthetic.
-- ══════════════════════════════════════════════════════════════════════════════

local _U2        = _G.PCU
local pageSov    = _U2.makePage("Sovereign")

-- ── Nav button ────────────────────────────────────────────────────────────────
do
    local _C2        = _G.PC
    local mk2        = _C2.mk
    local addCorner2 = _C2.addCorner
    local addStroke2 = _C2.addStroke
    local hookHover2 = _C2.hookHover
    local tween2     = _C2.tween
    local navHolder  = _U2.navHolder
    local pagesFolder= _U2.pagesFolder
    local panelTitle = _U2.panelTitle

    local navBtn = mk2("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=Color3.fromRGB(245,239,231),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,34),
        Font=Enum.Font.GothamSemibold,
        Text="⚡  Sovereign",
        TextColor3=Color3.fromRGB(52,47,42),
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=navHolder,
    })
    mk2("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=navBtn})
    addCorner2(navBtn, UDim.new(0,10))
    local navStroke = addStroke2(navBtn, 1, 0.6)
    hookHover2(navBtn,
        Color3.fromRGB(245,239,231),
        Color3.fromRGB(236,229,219), 0.6, 0.0)

    navBtn.MouseButton1Click:Connect(function()
        _C2.clickSound()
        for _, p in ipairs(pagesFolder:GetChildren()) do p.Visible = false end
        pageSov.Visible = true
        panelTitle.Text = "Sovereign"
        for _, child in ipairs(navHolder:GetChildren()) do
            if child:IsA("TextButton") and child ~= navBtn then
                tween2(child, TweenInfo.new(0.12),
                    {BackgroundColor3=Color3.fromRGB(245,239,231)})
                local st = child:FindFirstChildOfClass("UIStroke")
                if st then tween2(st, TweenInfo.new(0.12), {Transparency=0.6}) end
            end
        end
        tween2(navBtn, TweenInfo.new(0.12),
            {BackgroundColor3=Color3.fromRGB(236,229,219)})
        if navStroke then
            tween2(navStroke, TweenInfo.new(0.12), {Transparency=0.0})
        end
    end)
    _G.PCU.pageSovereign = pageSov
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UI
-- ══════════════════════════════════════════════════════════════════════════════
do
    local _C         = _G.PC
    local _U         = _G.PCU
    local mk         = _C.mk
    local addCorner  = _C.addCorner
    local addStroke  = _C.addStroke
    local tween      = _C.tween
    local clickSound = _C.clickSound
    local sendNotif  = _U.sendNotification

    local C = {
        BG      = Color3.fromRGB(8, 7, 12),
        SURFACE = Color3.fromRGB(14, 12, 20),
        CARD    = Color3.fromRGB(18, 16, 26),
        BORDER  = Color3.fromRGB(32, 28, 46),
        TEXT    = Color3.fromRGB(210, 206, 235),
        MUTED   = Color3.fromRGB(72, 68, 95),
        DIM     = Color3.fromRGB(40, 36, 58),
        RED     = Color3.fromRGB(215, 55, 55),
        AMBER   = Color3.fromRGB(220, 165, 38),
        GREEN   = Color3.fromRGB(48, 196, 88),
        TEAL    = Color3.fromRGB(38, 196, 150),
        CYAN    = Color3.fromRGB(48, 210, 220),
        PURP    = Color3.fromRGB(148, 98, 238),
        BLUE    = Color3.fromRGB(75, 145, 240),
        GOLD    = Color3.fromRGB(240, 188, 48),   -- sovereign accent
        SOV     = Color3.fromRGB(168, 108, 255),  -- sovereign purple
        REQUIRE = Color3.fromRGB(75, 175, 240),   -- require track
        LOAD    = Color3.fromRGB(48, 210, 148),   -- loadstring track
        ERROR   = Color3.fromRGB(215, 55, 55),
    }

    local PHASE_COLORS = {
        SOVEREIGN_SCAN    = C.CYAN,
        SOVEREIGN_PROBE   = C.SOV,
        SOVEREIGN_EXECUTE = C.GOLD,
    }

    pageSov.BackgroundColor3 = C.BG

    -- ── Utility helpers ───────────────────────────────────────────────────────
    local function secHdr(parent, title, col, lo)
        local h = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(16,14,24), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), LayoutOrder=lo or 1, Parent=parent})
        addCorner(h, UDim.new(0,5))
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=h})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=title, TextColor3=col or C.MUTED, TextSize=11,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=h})
        return h
    end

    local function dataRow(parent, key, val, col, lo)
        local row = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,18), LayoutOrder=lo or 99, Parent=parent})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=row})
        local kLbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=key, TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(0.40,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        local vLbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=tostring(val), TextColor3=col or C.TEXT, TextSize=10,
            Size=UDim2.new(0.60,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        return vLbl
    end

    local function confPip(parent, frac, col, lo)
        local bg = mk("Frame", {
            BackgroundColor3=C.DIM, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,4), LayoutOrder=lo or 99, Parent=parent})
        addCorner(bg, UDim.new(0,2))
        local fill = mk("Frame", {
            BackgroundColor3=col or C.GREEN, BorderSizePixel=0,
            Size=UDim2.new(math.clamp(frac,0,1),0,1,0), Parent=bg})
        addCorner(fill, UDim.new(0,2))
        return fill
    end

    local function trackBadge(parent, track)
        local isReq = track == "REQUIRE_PROBE"
        local col   = isReq and C.REQUIRE or C.LOAD
        local label = isReq and "REQ" or "LOAD"
        local badge = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(0,42,0,16), Parent=parent})
        addCorner(badge, UDim.new(0,4))
        local st = addStroke(badge, 1, 0)
        if st then st.Color = col end
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=label, TextColor3=col, TextSize=9,
            Size=UDim2.new(1,0,1,0), Parent=badge})
        return badge
    end

    -- ── Top Bar ───────────────────────────────────────────────────────────────
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,52), Parent=pageSov})
    addStroke(topBar, 1, 0.5)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,10), Parent=topBar})

    local titleBlock = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.32,0,1,0), Parent=topBar})
    mk("UIListLayout", {Padding=UDim.new(0,2), Parent=titleBlock})
    mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="⚡  Sovereign ACE",
        TextColor3=C.GOLD, TextSize=14,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=titleBlock})
    local stateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="PHASE: —",
        TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(1,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=2, Parent=titleBlock})

    -- Stat chips
    local statsRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.46,0,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,5), Parent=statsRow})

    local function makeTopChip(parent, label, col)
        local chip = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(0,68,0,32), Parent=parent})
        addCorner(chip, UDim.new(0,6))
        local st = addStroke(chip, 1, 0)
        if st then st.Color = col end
        mk("UIPadding", {
            PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3),
            PaddingLeft=UDim.new(0,6), Parent=chip})
        mk("UIListLayout", {Padding=UDim.new(0,0), Parent=chip})
        local val = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="0", TextColor3=col, TextSize=14,
            Size=UDim2.new(1,0,0,16),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=chip})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=label, TextColor3=C.MUTED, TextSize=8,
            Size=UDim2.new(1,0,0,10),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=chip})
        return val
    end

    local chips = {}
    chips.candidates = makeTopChip(statsRow, "Candidates", C.CYAN)
    chips.probes     = makeTopChip(statsRow, "Probes",     C.SOV)
    chips.tiers      = makeTopChip(statsRow, "Tiers Hit",  C.BLUE)
    chips.confirmed  = makeTopChip(statsRow, "Confirmed",  C.GOLD)
    chips.deliveries = makeTopChip(statsRow, "Deliveries", C.GREEN)

    -- Action buttons
    local btnRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0,220,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=btnRow})

    local runBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="⚡  Run All",
        TextColor3=C.MUTED, TextSize=12,
        Size=UDim2.new(0,110,0,36), Parent=btnRow})
    addCorner(runBtn, UDim.new(0,8))
    addStroke(runBtn, 1, 0.5)

    local scanBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="Scan",
        TextColor3=C.MUTED, TextSize=11,
        Size=UDim2.new(0,52,0,36), Parent=btnRow})
    addCorner(scanBtn, UDim.new(0,8))
    addStroke(scanBtn, 1, 0.5)

    local resetBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="↺",
        TextColor3=C.MUTED, TextSize=14,
        Size=UDim2.new(0,36,0,36), Parent=btnRow})
    addCorner(resetBtn, UDim.new(0,8))

    -- ── Phase strip ───────────────────────────────────────────────────────────
    local phaseStrip = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,52), Size=UDim2.new(1,0,0,28),
        Parent=pageSov})
    addStroke(phaseStrip, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=phaseStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=phaseStrip})

    local PHASES = {
        {phase="SOVEREIGN_SCAN",    label="Scan"},
        {phase="SOVEREIGN_PROBE",   label="→  Probe"},
        {phase="SOVEREIGN_EXECUTE", label="→  Execute"},
        {phase="DONE",              label="→  Done"},
    }
    local phaseLbls = {}
    for _, p in ipairs(PHASES) do
        local lbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=p.label, TextColor3=C.DIM, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=phaseStrip})
        phaseLbls[p.phase] = lbl
    end

    local progBg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(0.25,0,0,5), Parent=phaseStrip})
    addCorner(progBg, UDim.new(0,3))
    local progFill = mk("Frame", {
        BackgroundColor3=C.GOLD, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=progBg})
    addCorner(progFill, UDim.new(0,3))

    -- ── Tab bar ───────────────────────────────────────────────────────────────
    local CONTENT_TOP = 80
    local tabBar2 = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP), Size=UDim2.new(1,0,0,34),
        Parent=pageSov})
    addStroke(tabBar2, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar2})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar2})

    local TABS = {
        {key="overview",   label="Overview"},
        {key="candidates", label="Candidates"},
        {key="probes",     label="Probes"},
        {key="delivery",   label="Delivery"},
        {key="log",        label="Log"},
    }

    local tabBtns  = {}
    local tabPages = {}
    local activeTab = nil

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP+34),
        Size=UDim2.new(1,0,1,-(CONTENT_TOP+34)),
        ClipsDescendants=true, Parent=pageSov})

    local function makeTabPage()
        local p = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3, ScrollBarImageColor3=C.MUTED,
            Visible=false, Parent=contentArea})
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=p})
        return p
    end

    for _, tab in ipairs(TABS) do
        local btn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text=tab.label,
            TextColor3=C.MUTED, TextSize=11,
            Size=UDim2.new(0,84,0,26), Parent=tabBar2})
        addCorner(btn, UDim.new(0,6))
        addStroke(btn, 1, 0.5)
        tabBtns[tab.key]  = btn
        tabPages[tab.key] = makeTabPage()
    end

    local function switchTab(key)
        if activeTab == key then return end
        for k, p in pairs(tabPages) do p.Visible = (k==key) end
        for k, b in pairs(tabBtns) do
            local on = (k==key)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = on and C.SURFACE or C.CARD,
                TextColor3       = on and C.GOLD    or C.MUTED,
            })
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then
                tween(st, TweenInfo.new(0.1),
                    {Color = on and C.GOLD or C.BORDER})
            end
        end
        activeTab = key
    end
    for _, tab in ipairs(TABS) do
        local k = tab.key
        tabBtns[k].MouseButton1Click:Connect(function()
            clickSound(); switchTab(k)
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB: Overview
    -- ══════════════════════════════════════════════════════════════════════════
    do
        local pg = tabPages["overview"]

        -- Status block
        secHdr(pg, "Engine Status", C.GOLD, 1)
        local statusCard = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=2, Parent=pg})
        addCorner(statusCard, UDim.new(0,8))
        addStroke(statusCard, 1, 0.4)
        mk("UIPadding", {
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10),
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12), Parent=statusCard})
        mk("UIListLayout", {Padding=UDim.new(0,5), Parent=statusCard})

        local vPhase     = dataRow(statusCard, "Phase",          "—",   C.GOLD,    1)
        local vCands     = dataRow(statusCard, "Candidates",     "0",   C.CYAN,    2)
        local vProbes    = dataRow(statusCard, "Probes Fired",   "0",   C.SOV,     3)
        local vTiers     = dataRow(statusCard, "Tiers Hit",      "0",   C.BLUE,    4)
        local vConfirmed = dataRow(statusCard, "Confirmed",      "0",   C.GOLD,    5)
        local vDelivery  = dataRow(statusCard, "Deliveries",     "0",   C.GREEN,   6)

        -- Confirmed surfaces list
        secHdr(pg, "Confirmed Sovereign Surfaces", C.GOLD, 3)
        local confCard = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=4, Parent=pg})
        addCorner(confCard, UDim.new(0,8))
        addStroke(confCard, 1, 0.4)
        mk("UIPadding", {
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12), Parent=confCard})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=confCard})

        local confEmpty = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="No confirmed surfaces yet.", TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,0,0,16), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=confCard})

        local confRows = {}

        local function refreshOverview()
            local SOV = _G.PC and _G.PC.Sovereign
            if not SOV then return end
            local stats = SOV.GetStats()
            vPhase.Text     = stats.phase or "—"
            vPhase.TextColor3 = (stats.phase and PHASE_COLORS[stats.phase]) or C.MUTED
            vCands.Text     = tostring(stats.candidatesFound or 0)
            vProbes.Text    = tostring(stats.probesFired or 0)
            vTiers.Text     = tostring(stats.tiersHit or 0)
            vConfirmed.Text = tostring(stats.confirmed or 0)
            vDelivery.Text  = tostring(stats.deliveries or 0)
            chips.candidates.Text = tostring(stats.candidatesFound or 0)
            chips.probes.Text     = tostring(stats.probesFired or 0)
            chips.tiers.Text      = tostring(stats.tiersHit or 0)
            chips.confirmed.Text  = tostring(stats.confirmed or 0)
            chips.deliveries.Text = tostring(stats.deliveries or 0)

            -- Confirmed surfaces
            for _, r in ipairs(confRows) do r:Destroy() end
            confRows = {}
            local pairs_ = SOV.GetPairs()
            local any = false
            for name, rec in pairs(pairs_) do
                any = true
                local row = mk("Frame", {
                    BackgroundColor3=C.SURFACE, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                    Parent=confCard})
                addCorner(row, UDim.new(0,6))
                addStroke(row, 1, 0.3)
                mk("UIPadding", {
                    PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                    PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,4), Parent=row})
                table.insert(confRows, row)

                local hdr = mk("Frame", {
                    BackgroundTransparency=1, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=row})
                mk("UIListLayout", {
                    FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,6), Parent=hdr})
                local isReq = rec.track == "REQUIRE_PROBE"
                local tcol  = isReq and C.REQUIRE or C.LOAD
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=name, TextColor3=tcol, TextSize=11,
                    Size=UDim2.new(0.7,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=hdr})
                local confPct = math.floor(rec.confidence * 100)
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("%.0f%%", confPct),
                    TextColor3=confPct >= 90 and C.GREEN or C.AMBER, TextSize=11,
                    Size=UDim2.new(0.3,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right, LayoutOrder=2, Parent=hdr})

                trackBadge(row, rec.track)
                confPip(row, rec.confidence, tcol, 10)
            end
            confEmpty.Visible = not any
        end

        -- Auto-refresh loop
        task.spawn(function()
            while true do
                if pageSov.Visible and activeTab == "overview" then
                    pcall(refreshOverview)
                end
                task.wait(1.5)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB: Candidates
    -- ══════════════════════════════════════════════════════════════════════════
    do
        local pg = tabPages["candidates"]
        secHdr(pg, "Phase 1 — Sovereign Scan Candidates", C.CYAN, 1)

        local empty = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Run Scan to populate candidates.",
            TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,0,0,20), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=pg})

        local listHolder = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=3, Parent=pg})
        mk("UIListLayout", {Padding=UDim.new(0,5), Parent=listHolder})

        local renderedCands = {}

        local function renderCandidates()
            local SOV = _G.PC and _G.PC.Sovereign
            if not SOV then return end
            for _, r in ipairs(renderedCands) do r:Destroy() end
            renderedCands = {}

            local cands = SOV.GetCandidates()
            empty.Visible = (#cands == 0)

            for i, c in ipairs(cands) do
                local card = mk("Frame", {
                    BackgroundColor3=C.CARD, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=i, Parent=listHolder})
                addCorner(card, UDim.new(0,7))
                addStroke(card, 1, 0.3)
                mk("UIPadding", {
                    PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                    PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=card})
                mk("UIListLayout", {Padding=UDim.new(0,4), Parent=card})
                table.insert(renderedCands, card)

                -- Header row
                local hdr = mk("Frame", {
                    BackgroundTransparency=1, Size=UDim2.new(1,0,0,18),
                    LayoutOrder=1, Parent=card})
                mk("UIListLayout", {
                    FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,6), Parent=hdr})

                local isReq = c.track == "REQUIRE_PROBE"
                local tcol  = isReq and C.REQUIRE or C.LOAD
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("#%d  %s", i, c.name),
                    TextColor3=tcol, TextSize=11,
                    Size=UDim2.new(0.7,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=1, Parent=hdr})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("prior=%.0f%%", c.priorScore*100),
                    TextColor3=C.AMBER, TextSize=10,
                    Size=UDim2.new(0.3,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right,
                    LayoutOrder=2, Parent=hdr})

                -- Track badge
                trackBadge(card, c.track)

                -- Reasons
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=c.reasons or "—", TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=10, Parent=card})

                -- Prior bar
                confPip(card, c.priorScore, tcol, 20)
            end
        end

        task.spawn(function()
            while true do
                if pageSov.Visible and activeTab == "candidates" then
                    pcall(renderCandidates)
                end
                task.wait(2)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB: Probes
    -- ══════════════════════════════════════════════════════════════════════════
    do
        local pg = tabPages["probes"]
        secHdr(pg, "Phase 2 — Probe Results", C.SOV, 1)

        local empty = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="No probe results yet.",
            TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,0,0,20), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=pg})

        local probeList = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=3, Parent=pg})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=probeList})

        local renderedProbes = {}

        local function renderProbes()
            local SOV = _G.PC and _G.PC.Sovereign
            if not SOV then return end
            for _, r in ipairs(renderedProbes) do r:Destroy() end
            renderedProbes = {}

            local log = SOV.GetProbeLog(20)
            empty.Visible = (#log == 0)

            for i, rec in ipairs(log) do
                local isReq = rec.track == "REQUIRE_PROBE"
                local tcol  = isReq and C.REQUIRE or C.LOAD
                local confPct = math.floor((rec.confidence or 0) * 100)
                local cleared = confPct >= 70

                local card = mk("Frame", {
                    BackgroundColor3=C.CARD, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=i, Parent=probeList})
                addCorner(card, UDim.new(0,7))
                local bstroke = addStroke(card, 1, cleared and 0.0 or 0.4)
                if bstroke then bstroke.Color = cleared and C.GOLD or C.BORDER end
                mk("UIPadding", {
                    PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                    PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=card})
                mk("UIListLayout", {Padding=UDim.new(0,4), Parent=card})
                table.insert(renderedProbes, card)

                -- Header
                local hdr = mk("Frame", {
                    BackgroundTransparency=1, Size=UDim2.new(1,0,0,18),
                    LayoutOrder=1, Parent=card})
                mk("UIListLayout", {
                    FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,6), Parent=hdr})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=rec.remote or "?",
                    TextColor3=cleared and C.GOLD or tcol, TextSize=11,
                    Size=UDim2.new(0.65,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=1, Parent=hdr})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("%.0f%%", confPct),
                    TextColor3=confPct >= 90 and C.GREEN
                        or confPct >= 70 and C.GOLD
                        or confPct >= 40 and C.AMBER or C.MUTED,
                    TextSize=11,
                    Size=UDim2.new(0.35,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right,
                    LayoutOrder=2, Parent=hdr})

                trackBadge(card, rec.track)
                confPip(card, rec.confidence or 0, tcol, 5)

                -- Evidence items
                if rec.evidence and #rec.evidence > 0 then
                    for j, ev in ipairs(rec.evidence) do
                        mk("TextLabel", {
                            BackgroundTransparency=1, Font=Enum.Font.Code,
                            Text="  ✓  " .. ev:sub(1,100),
                            TextColor3=C.TEAL, TextSize=9,
                            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                            TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                            LayoutOrder=10+j, Parent=card})
                    end
                end
            end
        end

        task.spawn(function()
            while true do
                if pageSov.Visible and activeTab == "probes" then
                    pcall(renderProbes)
                end
                task.wait(2)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB: Delivery
    -- ══════════════════════════════════════════════════════════════════════════
    do
        local pg = tabPages["delivery"]
        secHdr(pg, "Phase 3 — Sovereign Delivery", C.GOLD, 1)

        -- Empty/awaiting notice
        local awaiting = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Awaiting confirmed surface. Run Probe phase first.",
            TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,0,0,20), TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=pg})

        local delivHolder = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=3, Parent=pg})
        mk("UIListLayout", {Padding=UDim.new(0,8), Parent=delivHolder})

        local delivRows = {}

        local function renderDelivery()
            local SOV = _G.PC and _G.PC.Sovereign
            if not SOV then return end
            for _, r in ipairs(delivRows) do r:Destroy() end
            delivRows = {}

            local pairs_ = SOV.GetPairs()
            local anyConfirmed = false

            for name, rec in pairs(pairs_) do
                anyConfirmed = true
                local isReq     = rec.track == "REQUIRE_PROBE"
                local tcol      = isReq and C.REQUIRE or C.LOAD
                local hasResult = rec.deliveryResult ~= nil
                local achieved  = hasResult and (
                    rec.deliveryResult.achieved or rec.deliveryResult.ok)

                local card = mk("Frame", {
                    BackgroundColor3=C.CARD, BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                    Parent=delivHolder})
                addCorner(card, UDim.new(0,8))
                local bst = addStroke(card, 1, achieved and 0.0 or 0.4)
                if bst then bst.Color = achieved and C.GREEN or C.BORDER end
                mk("UIPadding", {
                    PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10),
                    PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12), Parent=card})
                mk("UIListLayout", {Padding=UDim.new(0,5), Parent=card})
                table.insert(delivRows, card)

                -- Title
                local hdr = mk("Frame", {
                    BackgroundTransparency=1, Size=UDim2.new(1,0,0,20),
                    LayoutOrder=1, Parent=card})
                mk("UIListLayout", {
                    FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,8), Parent=hdr})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=name, TextColor3=achieved and C.GREEN or tcol, TextSize=12,
                    Size=UDim2.new(0.65,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=1, Parent=hdr})
                local statusTxt = not hasResult and "PENDING" or
                                  achieved       and "✓  ACE ACHIEVED" or "✗  FAILED"
                local statusCol = not hasResult and C.MUTED or
                                  achieved       and C.GREEN or C.RED
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=statusTxt, TextColor3=statusCol, TextSize=11,
                    Size=UDim2.new(0.35,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right,
                    LayoutOrder=2, Parent=hdr})

                trackBadge(card, rec.track)

                -- Confidence
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("Probe confidence: %.0f%%", rec.confidence*100),
                    TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(1,0,0,14),
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=5, Parent=card})
                confPip(card, rec.confidence, tcol, 6)

                -- Delivery result detail
                if rec.deliveryResult then
                    local dr = rec.deliveryResult
                    if dr.track == "LOADSTRING" then
                        -- Stage ladder
                        secHdr(card, "Stage Progression", C.LOAD, 7)
                        local stageNames = {"RECON","SERVICE_ACCESS","WORKSPACE_READ","HEARTBEAT_PROBE"}
                        if rec.stages then
                            for si, st in ipairs(rec.stages) do
                                local scol = st.confirmed and C.GREEN or C.RED
                                local stageRow = mk("Frame", {
                                    BackgroundTransparency=1, Size=UDim2.new(1,0,0,16),
                                    LayoutOrder=8+si, Parent=card})
                                mk("UIListLayout", {
                                    FillDirection=Enum.FillDirection.Horizontal,
                                    VerticalAlignment=Enum.VerticalAlignment.Center,
                                    Padding=UDim.new(0,6), Parent=stageRow})
                                mk("TextLabel", {
                                    BackgroundTransparency=1, Font=Enum.Font.Code,
                                    Text=(st.confirmed and "✓" or "✗") .. "  " .. st.label,
                                    TextColor3=scol, TextSize=10,
                                    Size=UDim2.new(0.5,0,1,0),
                                    TextXAlignment=Enum.TextXAlignment.Left,
                                    LayoutOrder=1, Parent=stageRow})
                                mk("TextLabel", {
                                    BackgroundTransparency=1, Font=Enum.Font.Code,
                                    Text=tostring(st.res):sub(1,40),
                                    TextColor3=C.MUTED, TextSize=9,
                                    Size=UDim2.new(0.5,0,1,0),
                                    TextXAlignment=Enum.TextXAlignment.Left,
                                    LayoutOrder=2, Parent=stageRow})
                            end
                        else
                            mk("TextLabel", {
                                BackgroundTransparency=1, Font=Enum.Font.Code,
                                Text=string.format("Highest stage: %d", dr.highestStage or 0),
                                TextColor3=C.MUTED, TextSize=10,
                                Size=UDim2.new(1,0,0,14),
                                LayoutOrder=9, Parent=card})
                        end
                    elseif dr.track == "REQUIRE" then
                        mk("TextLabel", {
                            BackgroundTransparency=1, Font=Enum.Font.Code,
                            Text=string.format("assetId=%d  ok=%s  lat=%.0fms",
                                dr.assetId or 0, tostring(dr.ok), (dr.lat or 0)*1000),
                            TextColor3=C.MUTED, TextSize=10,
                            Size=UDim2.new(1,0,0,14),
                            LayoutOrder=9, Parent=card})
                        if dr.res then
                            mk("TextLabel", {
                                BackgroundTransparency=1, Font=Enum.Font.Code,
                                Text="res: " .. tostring(dr.res):sub(1,80),
                                TextColor3=C.TEAL, TextSize=9,
                                Size=UDim2.new(1,0,0,14),
                                LayoutOrder=10, Parent=card})
                        end
                    end
                end

                -- Manual deliver button (if not yet attempted)
                if not hasResult then
                    local dbtn = mk("TextButton", {
                        AutoButtonColor=false,
                        BackgroundColor3=C.DIM, BorderSizePixel=0,
                        Font=Enum.Font.GothamBold, Text="⚡  Deliver",
                        TextColor3=C.GOLD, TextSize=11,
                        Size=UDim2.new(0,110,0,30),
                        LayoutOrder=20, Parent=card})
                    addCorner(dbtn, UDim.new(0,6))
                    addStroke(dbtn, 1, 0.4)
                    local recRef = rec
                    dbtn.MouseButton1Click:Connect(function()
                        clickSound()
                        local SOV = _G.PC and _G.PC.Sovereign
                        if not SOV then return end
                        task.spawn(function()
                            pcall(SOV.Deliver, recRef)
                        end)
                        sendNotif("Delivery initiated: " .. name, "Info")
                    end)
                end
            end

            awaiting.Visible = not anyConfirmed
        end

        task.spawn(function()
            while true do
                if pageSov.Visible and activeTab == "delivery" then
                    pcall(renderDelivery)
                end
                task.wait(2)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB: Log
    -- ══════════════════════════════════════════════════════════════════════════
    do
        local pg = tabPages["log"]
        secHdr(pg, "Operation Log", C.MUTED, 1)

        local logScroll = mk("ScrollingFrame", {
            BackgroundColor3=C.SURFACE, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,420),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3, ScrollBarImageColor3=C.MUTED,
            LayoutOrder=2, Parent=pg})
        addCorner(logScroll, UDim.new(0,6))
        addStroke(logScroll, 1, 0.4)
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=logScroll})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,2), Parent=logScroll})

        local LOG_BUF = {}
        local logLines = {}
        local LOG_MAX  = 200

        local LOG_COLORS = {
            INFO    = C.TEXT,
            WARN    = C.AMBER,
            ERROR   = C.RED,
            ANOMALY = C.GOLD,
        }

        local function appendLog(level, msg)
            table.insert(LOG_BUF, 1, {level=level, msg=msg, t=os.clock()})
            if #LOG_BUF > LOG_MAX then LOG_BUF[LOG_MAX+1] = nil end
        end

        local function rebuildLog()
            for _, l in ipairs(logLines) do l:Destroy() end
            logLines = {}
            for i, entry in ipairs(LOG_BUF) do
                local col = LOG_COLORS[entry.level] or C.MUTED
                local lbl = mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format(
                        "[ %6.1f][%s] %s",
                        entry.t, entry.level, entry.msg),
                    TextColor3=col, TextSize=9,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=i, Parent=logScroll})
                table.insert(logLines, lbl)
            end
        end

        -- Wire Sovereign OnLog callback
        task.defer(function()
            local SOV = _G.PC and _G.PC.Sovereign
            if SOV then
                SOV.OnLog = function(level, msg)
                    appendLog(level, msg)
                end
            end
        end)

        task.spawn(function()
            while true do
                if pageSov.Visible and activeTab == "log" then
                    pcall(rebuildLog)
                end
                task.wait(1.5)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- BUTTON WIRING
    -- ══════════════════════════════════════════════════════════════════════════

    local running = false

    local function setRunning(state)
        running = state
        tween(runBtn, TweenInfo.new(0.15), {
            BackgroundColor3 = state and C.SOV  or C.DIM,
            TextColor3       = state and C.TEXT or C.MUTED,
        })
        local st = runBtn:FindFirstChildOfClass("UIStroke")
        if st then
            tween(st, TweenInfo.new(0.15), {Transparency = state and 0.0 or 0.5})
        end
        runBtn.Text = state and "⏳  Running…" or "⚡  Run All"
    end

    runBtn.MouseButton1Click:Connect(function()
        if running then return end
        clickSound()
        local SOV = _G.PC and _G.PC.Sovereign
        if not SOV then
            sendNotif("Sovereign module not loaded.", "Warning"); return
        end
        setRunning(true)
        switchTab("overview")
        task.spawn(function()
            local ok, err = pcall(SOV.Run)
            setRunning(false)
            if ok then
                sendNotif("Sovereign run complete.", "Success")
            else
                sendNotif("Sovereign error: " .. tostring(err), "Warning")
            end
        end)
    end)

    scanBtn.MouseButton1Click:Connect(function()
        if running then return end
        clickSound()
        local SOV = _G.PC and _G.PC.Sovereign
        if not SOV then return end
        setRunning(true)
        switchTab("candidates")
        task.spawn(function()
            local ok, err = pcall(SOV.RunScan)
            setRunning(false)
            if not ok then
                sendNotif("Scan error: " .. tostring(err), "Warning")
            else
                sendNotif("Scan complete.", "Info")
            end
        end)
    end)

    resetBtn.MouseButton1Click:Connect(function()
        clickSound()
        local SOV = _G.PC and _G.PC.Sovereign
        if not SOV then return end
        SOV.Pairs      = {}
        SOV.Candidates = {}
        SOV.ProbeLog   = {}
        SOV.Stats = {
            candidatesScanned=0, probesFired=0,
            tiersHit=0, confirmed=0, deliveries=0,
        }
        SOV.CurrentPhase = nil
        sendNotif("Sovereign state reset.", "Info")
    end)

    -- ── Phase strip update (driven by Sovereign callbacks) ────────────────────
    task.defer(function()
        local SOV = _G.PC and _G.PC.Sovereign
        if not SOV then return end

        SOV.OnPhaseChange = function(phase)
            stateLabel.Text = "PHASE: " .. tostring(phase)
            local col = PHASE_COLORS[phase] or C.MUTED
            tween(stateLabel, TweenInfo.new(0.2), {TextColor3=col})

            -- Highlight phase strip
            for phKey, lbl in pairs(phaseLbls) do
                local on = (phKey == phase)
                tween(lbl, TweenInfo.new(0.15), {
                    TextColor3 = on and (PHASE_COLORS[phKey] or C.GOLD) or C.DIM,
                })
            end

            -- Progress fill
            local prog = 0
            if phase == "SOVEREIGN_SCAN"    then prog = 0.25
            elseif phase == "SOVEREIGN_PROBE"   then prog = 0.55
            elseif phase == "SOVEREIGN_EXECUTE" then prog = 0.85
            end
            tween(progFill, TweenInfo.new(0.3), {Size=UDim2.new(prog,0,1,0)})
        end

        SOV.OnConfirmed = function(rec)
            -- Flash the title gold on confirmation
            tween(stateLabel, TweenInfo.new(0.15), {TextColor3=C.GOLD})
            tween(progFill, TweenInfo.new(0.5), {
                Size=UDim2.new(1,0,1,0),
                BackgroundColor3=C.GREEN,
            })
        end
    end)

    -- ── Initial tab ───────────────────────────────────────────────────────────
    switchTab("overview")
end
