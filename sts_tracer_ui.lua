-- ══════════════════════════════════════════════════════════════════════════════
-- STS_TRACER_UI — Source-to-Sink Tracer Interface
-- Self-registering standalone page.
-- ══════════════════════════════════════════════════════════════════════════════

local _U2      = _G.PCU
local pageTRCR = _U2.makePage("TRCR")

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
        Text="⟶  S2S",
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
        pageTRCR.Visible = true
        panelTitle.Text  = "S2S Tracer"
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
    _G.PCU.pageTRCR = pageTRCR
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

    -- ── Palette ───────────────────────────────────────────────────────────────
    local C = {
        BG       = Color3.fromRGB(8,7,12),
        SURFACE  = Color3.fromRGB(14,12,20),
        CARD     = Color3.fromRGB(18,16,26),
        BORDER   = Color3.fromRGB(32,28,46),
        TEXT     = Color3.fromRGB(210,206,235),
        MUTED    = Color3.fromRGB(72,68,95),
        DIM      = Color3.fromRGB(40,36,58),
        -- Step colors
        S1       = Color3.fromRGB(75,145,240),   -- Ingress (blue)
        S2       = Color3.fromRGB(140,100,240),  -- Dispatch (violet)
        S3       = Color3.fromRGB(220,165,38),   -- Broadcast (amber)
        S4       = Color3.fromRGB(215,75,55),    -- Exec (red-orange)
        S5       = Color3.fromRGB(215,55,55),    -- Egress (red)
        -- Severity
        CRITICAL = Color3.fromRGB(215,55,55),
        HIGH     = Color3.fromRGB(210,100,38),
        MEDIUM   = Color3.fromRGB(220,165,38),
        LOW      = Color3.fromRGB(72,68,95),
        -- Status
        GREEN    = Color3.fromRGB(48,196,88),
        TEAL     = Color3.fromRGB(38,196,150),
        LIVE     = Color3.fromRGB(48,210,220),
    }

    local STEP_COLORS = {C.S1, C.S2, C.S3, C.S4, C.S5}
    local STEP_LABELS = {"Ingress", "Dispatch", "Broadcast", "Exec", "Egress"}
    local SEV_COLORS  = {
        CRITICAL = C.CRITICAL,
        HIGH     = C.HIGH,
        MEDIUM   = C.MEDIUM,
        LOW      = C.LOW,
    }

    local STATE_COLORS = {
        IDLE      = C.DIM,
        SCANNING  = C.S1,
        OBSERVING = C.LIVE,
        CORRELATE = C.S3,
        DONE      = C.GREEN,
        ERROR     = C.CRITICAL,
    }

    pageTRCR.BackgroundColor3 = C.BG

    -- ══════════════════════════════════════════════════════════════════════════
    -- TOP BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,52), Parent=pageTRCR})
    addStroke(topBar, 1, 0.5)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,12), Parent=topBar})

    -- Title block
    local titleBlock = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.34,0,1,0), Parent=topBar})
    mk("UIListLayout", {Padding=UDim.new(0,2), Parent=titleBlock})
    mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="⟶  Source-to-Sink Tracer",
        TextColor3=C.S3, TextSize=14,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=titleBlock})
    local stateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="STATE: IDLE  ·  Ready",
        TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(1,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=2, Parent=titleBlock})

    -- Stat chips
    local statsRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.44,0,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,5), Parent=statsRow})

    local chips = {}
    local function makeChip(parent, label, col)
        local chip = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(0,64,0,32), Parent=parent})
        addCorner(chip, UDim.new(0,6))
        addStroke(chip, 1, 0)
        if chip:FindFirstChildOfClass("UIStroke") then
            chip:FindFirstChildOfClass("UIStroke").Color = col
        end
        mk("UIPadding", {
            PaddingTop=UDim.new(0,3), PaddingLeft=UDim.new(0,6), Parent=chip})
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

    chips.scripts  = makeChip(statsRow, "Scripts",  C.MUTED)
    chips.chains   = makeChip(statsRow, "Chains",   C.CRITICAL)
    chips.frags    = makeChip(statsRow, "Frags",    C.MEDIUM)
    chips.gaps     = makeChip(statsRow, "Gaps",     C.HIGH)
    chips.live     = makeChip(statsRow, "Live",     C.LIVE)

    -- Run buttons
    local runBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.S3, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="⟶  Run Full Trace",
        TextColor3=Color3.fromRGB(6,4,2), TextSize=12,
        Size=UDim2.new(0,136,0,36), Parent=topBar})
    addCorner(runBtn, UDim.new(0,8))

    local staticBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="Static",
        TextColor3=C.MUTED, TextSize=11,
        Size=UDim2.new(0,52,0,36), Parent=topBar})
    addCorner(staticBtn, UDim.new(0,8))
    addStroke(staticBtn, 1, 0.5)

    local resetBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="↺",
        TextColor3=C.MUTED, TextSize=14,
        Size=UDim2.new(0,32,0,36), Parent=topBar})
    addCorner(resetBtn, UDim.new(0,8))

    -- ── Progress bar ──────────────────────────────────────────────────────────
    local progStrip = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,52), Size=UDim2.new(1,0,0,28),
        Parent=pageTRCR})
    addStroke(progStrip, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=progStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,10), Parent=progStrip})

    local progBg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(0.55,0,0,6), Parent=progStrip})
    addCorner(progBg, UDim.new(0,3))
    local progFill = mk("Frame", {
        BackgroundColor3=C.S3, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=progBg})
    addCorner(progFill, UDim.new(0,3))

    local progLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="Awaiting run", TextColor3=C.MUTED, TextSize=9,
        Size=UDim2.new(0.44,0,1,0),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=progStrip})

    -- ── Phase indicator strip ─────────────────────────────────────────────────
    local phaseStrip = mk("Frame", {
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,80), Size=UDim2.new(1,0,0,22),
        Parent=pageTRCR})
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=phaseStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,16), Parent=phaseStrip})

    local PHASES = {
        {state="SCANNING",  label="Static Scan"},
        {state="OBSERVING", label="→  Live Observe"},
        {state="CORRELATE", label="→  Correlate"},
        {state="DONE",      label="→  Done"},
    }
    local phaseLbls = {}
    for _, ph in ipairs(PHASES) do
        local lbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=ph.label, TextColor3=C.DIM, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=phaseStrip})
        phaseLbls[ph.state] = lbl
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local CONTENT_TOP = 102
    local tabBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP), Size=UDim2.new(1,0,0,34),
        Parent=pageTRCR})
    addStroke(tabBar, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})

    local TABS = {
        {key="chains",   label="Chains"   },
        {key="fragments",label="Fragments"},
        {key="static",   label="Static"   },
        {key="live",     label="Live"     },
        {key="about",    label="About"    },
    }

    local tabBtns   = {}
    local tabPages2 = {}
    local activeTab = nil
    local tabBuilders = {}

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP+34),
        Size=UDim2.new(1,0,1,-(CONTENT_TOP+34)),
        ClipsDescendants=true, Parent=pageTRCR})

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
            Size=UDim2.new(0,80,0,26), Parent=tabBar})
        addCorner(btn, UDim.new(0,6))
        addStroke(btn, 1, 0.5)
        tabBtns[tab.key]   = btn
        tabPages2[tab.key] = makeTabPage()
    end

    local function switchTab(key)
        if activeTab == key then return end
        for k, p in pairs(tabPages2) do p.Visible = (k==key) end
        for k, b in pairs(tabBtns) do
            local on = (k==key)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = on and C.SURFACE or C.CARD,
                TextColor3       = on and C.S3      or C.MUTED,
            })
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then tween(st, TweenInfo.new(0.1),
                {Color = on and C.S3 or C.BORDER}) end
        end
        activeTab = key
        if tabBuilders[key] then task.defer(tabBuilders[key]) end
    end

    for _, tab in ipairs(TABS) do
        local k = tab.key
        tabBtns[k].MouseButton1Click:Connect(function()
            clickSound(); switchTab(k)
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- SHARED BUILDER HELPERS
    -- ══════════════════════════════════════════════════════════════════════════
    local function clearPage(pg)
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") or
               c:IsA("ScrollingFrame") then c:Destroy() end
        end
    end

    local function emptyMsg(pg, msg)
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=msg, TextColor3=C.MUTED, TextSize=11,
            Size=UDim2.new(1,0,0,40), LayoutOrder=1,
            TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
    end

    local function hopPill(parent, stepNum, label, sanitized, passthrough)
        local col = STEP_COLORS[stepNum] or C.MUTED
        local pill = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(14,12,22), BorderSizePixel=0,
            Size=UDim2.new(0,0,0,20), AutomaticSize=Enum.AutomaticSize.X,
            Parent=parent})
        addCorner(pill, UDim.new(0,4))
        addStroke(pill, 1, 0.2)
        if pill:FindFirstChildOfClass("UIStroke") then
            pill:FindFirstChildOfClass("UIStroke").Color = col
        end
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
            Parent=pill})
        -- Warning icon if unsanitized passthrough
        local icon = (not sanitized and passthrough) and "⚠ " or
                     (not sanitized) and "· " or "✓ "
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("%sS%d %s", icon, stepNum, label),
            TextColor3=col, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=pill})
        return pill
    end

    -- Chain card builder
    local function buildChainCard(parent, chain, lo)
        local sevCol = SEV_COLORS[chain.severity] or C.MUTED

        local card = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=parent})
        addCorner(card, UDim.new(0,8))
        addStroke(card, 1, 0.3)
        if card:FindFirstChildOfClass("UIStroke") then
            card:FindFirstChildOfClass("UIStroke").Color = sevCol
        end

        -- Color strip
        local strip = mk("Frame", {
            BackgroundColor3=sevCol, BorderSizePixel=0,
            Size=UDim2.new(0,3,1,0), Parent=card})
        addCorner(strip, UDim.new(0,3))

        local body = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
            AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
        mk("UIPadding", {
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            PaddingRight=UDim.new(0,10), Parent=body})
        mk("UIListLayout", {Padding=UDim.new(0,5), Parent=body})

        -- Header
        local hdr = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=body})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=hdr})

        -- Severity chip
        local sevChip = mk("TextLabel", {
            BackgroundColor3=Color3.fromRGB(12,10,18), BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text=chain.severity or "?",
            TextColor3=sevCol, TextSize=9,
            Size=UDim2.new(0,0,0,18), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Center, Parent=hdr})
        addCorner(sevChip, UDim.new(0,4))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), Parent=sevChip})

        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=string.format("score=%d", chain.score or 0),
            TextColor3=sevCol, TextSize=11,
            Size=UDim2.new(0,70,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})

        if chain.liveConfirmed then
            local liveChip = mk("TextLabel", {
                BackgroundColor3=Color3.fromRGB(8,18,20), BorderSizePixel=0,
                Font=Enum.Font.Code, Text="◉ LIVE",
                TextColor3=C.LIVE, TextSize=9,
                Size=UDim2.new(0,0,0,18), AutomaticSize=Enum.AutomaticSize.X,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=hdr})
            addCorner(liveChip, UDim.new(0,4))
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
                Parent=liveChip})
        end

        -- Script name
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=chain.script or "unknown",
            TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=body})

        -- Hop pills
        local pillRow = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,24), LayoutOrder=3, Parent=body})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,4), Parent=pillRow})

        for i, hop in ipairs(chain.hops) do
            -- Arrow between hops
            if i > 1 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="→", TextColor3=C.DIM, TextSize=9,
                    Size=UDim2.new(0,12,1,0),
                    TextXAlignment=Enum.TextXAlignment.Center, Parent=pillRow})
            end
            hopPill(pillRow, hop.step, hop.label or hop.type,
                hop.sanitized, hop.passthrough)
        end

        -- Hop detail lines
        for i, hop in ipairs(chain.hops) do
            local col = STEP_COLORS[hop.step] or C.MUTED
            local sanTag = hop.sanitized and " [sanitized]" or
                           hop.passthrough and " ⚠ passthrough" or " [unsanitized]"
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("  S%d  %s  —  %s%s",
                    hop.step,
                    hop.type or "?",
                    (hop.line or ""):sub(1, 60),
                    sanTag),
                TextColor3=hop.sanitized and C.MUTED or col,
                TextSize=8, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=3+i, Parent=body})
        end

        return card
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- CHAINS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildChains()
        local pg = tabPages2["chains"]
        clearPage(pg)
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 or #TRCR2.Chains == 0 then
            emptyMsg(pg, "No complete chains found yet. Run a trace to scan.")
            return
        end

        local lo = 1
        -- Summary
        local summ = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), LayoutOrder=lo, Parent=pg})
        addCorner(summ, UDim.new(0,6))
        lo = lo + 1
        mk("UIPadding", {PaddingLeft=UDim.new(0,12), Parent=summ})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format(
                "%d complete chains  ·  Sorted by severity score",
                #TRCR2.Chains),
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=summ})

        for _, chain in ipairs(TRCR2.Chains) do
            buildChainCard(pg, chain, lo)
            lo = lo + 1
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- FRAGMENTS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildFragments()
        local pg = tabPages2["fragments"]
        clearPage(pg)
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 or #TRCR2.Fragments == 0 then
            emptyMsg(pg, "No chain fragments found yet.")
            return
        end

        local lo = 1
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format(
                "%d partial chains (2+ hops, not reaching Step 5)",
                #TRCR2.Fragments),
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,18), LayoutOrder=lo, Parent=pg})
        lo = lo + 1

        for _, frag in ipairs(TRCR2.Fragments) do
            buildChainCard(pg, frag, lo)
            lo = lo + 1
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- STATIC FINDS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildStatic()
        local pg = tabPages2["static"]
        clearPage(pg)
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 or #TRCR2.StaticFinds == 0 then
            emptyMsg(pg, "No static analysis results yet.")
            return
        end

        local lo = 1
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format(
                "%d hop markers found across %d scripts",
                #TRCR2.StaticFinds, TRCR2.GetStats().scriptsScanned),
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,18), LayoutOrder=lo, Parent=pg})
        lo = lo + 1

        -- Group by step
        local byStep = {}
        for _, f in ipairs(TRCR2.StaticFinds) do
            byStep[f.step] = byStep[f.step] or {}
            table.insert(byStep[f.step], f)
        end

        for step = 1, 5 do
            local finds = byStep[step]
            if not finds or #finds == 0 then continue end

            local col = STEP_COLORS[step] or C.MUTED

            -- Section header
            local secH = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(16,14,24), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,22), LayoutOrder=lo, Parent=pg})
            addCorner(secH, UDim.new(0,5))
            lo = lo + 1
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=secH})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format(
                    "Step %d — %s  (%d hits)",
                    step, STEP_LABELS[step] or "?", #finds),
                TextColor3=col, TextSize=11,
                Size=UDim2.new(1,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=secH})

            -- Individual finds (cap at 20 per step to keep UI fast)
            for i, f in ipairs(finds) do
                if i > 20 then
                    mk("TextLabel", {
                        BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=string.format("  … and %d more", #finds-20),
                        TextColor3=C.MUTED, TextSize=9,
                        Size=UDim2.new(1,0,0,14), LayoutOrder=lo, Parent=pg})
                    lo = lo + 1
                    break
                end

                local row = mk("Frame", {
                    BackgroundColor3=f.sanitized and C.CARD or
                        Color3.fromRGB(20,14,14), BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=lo, Parent=pg})
                addCorner(row, UDim.new(0,5))
                lo = lo + 1
                mk("UIPadding", {
                    PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                    PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5),
                    Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=f.script or "?",
                    TextColor3=C.MUTED, TextSize=8,
                    Size=UDim2.new(1,0,0,11),
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=1, Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=(f.line or ""):sub(1,80),
                    TextColor3=f.sanitized and C.MUTED or col,
                    TextSize=9, TextWrapped=true,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=2, Parent=row})
                if not f.sanitized then
                    mk("TextLabel", {
                        BackgroundTransparency=1, Font=Enum.Font.Code,
                        Text=f.passthrough and
                            "⚠  Passthrough — args forwarded unsanitized" or
                            "·  No sanitization detected in window",
                        TextColor3=f.passthrough and C.HIGH or C.MEDIUM,
                        TextSize=8,
                        Size=UDim2.new(1,0,0,11),
                        TextXAlignment=Enum.TextXAlignment.Left,
                        LayoutOrder=3, Parent=row})
                end
            end
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- LIVE FINDS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildLive()
        local pg = tabPages2["live"]
        clearPage(pg)
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 or #TRCR2.LiveFinds == 0 then
            emptyMsg(pg, "No live observations captured yet. Run full trace with observation window.")
            return
        end

        local lo = 1
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("%d live events captured", #TRCR2.LiveFinds),
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,18), LayoutOrder=lo, Parent=pg})
        lo = lo + 1

        for _, live in ipairs(TRCR2.LiveFinds) do
            local row = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,36), LayoutOrder=lo, Parent=pg})
            addCorner(row, UDim.new(0,6))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
                PaddingTop=UDim.new(0,6), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=live.remote or "?",
                TextColor3=C.LIVE, TextSize=10,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format(
                    "%d new fires  ·  t=%.1f",
                    live.newFires or 0, live.timestamp or 0),
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,12),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=row})
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- ABOUT TAB — the five-step threat model
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildAbout()
        local pg = tabPages2["about"]
        clearPage(pg)
        local lo = 1

        local STEPS_DEF = {
            {n=1, col=C.S1, label="Ingress (RemoteEvent)",
             desc="Client sends crafted payload through RemoteEvent/RemoteFunction. The external trust boundary. Server receives whatever the client sends."},
            {n=2, col=C.S2, label="Local Dispatch (BindableEvent)",
             desc="Receiving script dispatches client data internally via BindableEvent. Downstream scripts assume data is already validated — origin is stripped, trust is silently elevated."},
            {n=3, col=C.S3, label="Fleet Broadcast (MessagingService)",
             desc="Server script publishes the laundered data to a MessagingService topic. Every server instance receives it simultaneously. Local compromise becomes global."},
            {n=4, col=C.S4, label="Control Exec (require)",
             desc="Subscriber script passes broadcasted data into require(). If AssetID is not strictly validated, the operator's module loads and executes fleet-wide with full server context."},
            {n=5, col=C.S5, label="Egress (HttpService)",
             desc="Loaded module calls HttpService to establish C2 connection. Exfiltrates DataStore keys, session tokens, player lists. Pulls further instructions. Server becomes a persistent agent."},
        }

        local trustNote = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(16,14,24), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=pg})
        addCorner(trustNote, UDim.new(0,7))
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10),
            Parent=trustNote})
        mk("UIListLayout", {Padding=UDim.new(0,4), Parent=trustNote})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Trust Domain Cascade",
            TextColor3=C.S3, TextSize=12,
            Size=UDim2.new(1,0,0,18),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=trustNote})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="The chain succeeds because each link assumes the previous link sanitized. No single hop is malicious in isolation — the vulnerability is structural.",
            TextColor3=C.TEXT, TextSize=9, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=trustNote})

        for _, step in ipairs(STEPS_DEF) do
            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.4)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = step.col
            end
            lo = lo + 1

            local strip = mk("Frame", {
                BackgroundColor3=step.col, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,3))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                PaddingRight=UDim.new(0,8), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Step %d  —  %s", step.n, step.label),
                TextColor3=step.col, TextSize=11,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=step.desc, TextColor3=C.TEXT,
                TextSize=9, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=body})
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- CALLBACKS
    -- ══════════════════════════════════════════════════════════════════════════
    local function wireCallbacks()
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 then return end

        TRCR2.OnStateChange = function(newState, oldState)
            local col = STATE_COLORS[newState] or C.MUTED
            stateLabel.Text      = "STATE: " .. newState
            stateLabel.TextColor3= col

            local stateRank = {
                IDLE=0, SCANNING=1, OBSERVING=2, CORRELATE=3, DONE=4
            }
            local cur = stateRank[newState] or 0
            for state, lbl in pairs(phaseLbls) do
                local rank = stateRank[state] or 0
                tween(lbl, TweenInfo.new(0.2), {
                    TextColor3 = (state==newState) and col or
                                 (rank < cur) and C.GREEN or C.DIM})
            end

            if newState == "DONE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.GREEN})
                runBtn.Text = "⟶  Done"
                task.defer(buildChains)
                task.defer(buildFragments)
                task.defer(buildStatic)
                task.defer(buildLive)
                local s = TRCR2.GetStats()
                sendNotif(string.format(
                    "S2S: %d chains  %d fragments  %d gaps",
                    s.chains, s.fragments, s.sanitizationGaps), "Success")
            elseif newState == "ERROR" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.CRITICAL})
                runBtn.Text = "⟶  Error"
            elseif newState == "IDLE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.S3})
                runBtn.Text = "⟶  Run Full Trace"
                runBtn.TextColor3 = Color3.fromRGB(6,4,2)
            else
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                runBtn.Text = "◌  Running..."
                runBtn.TextColor3 = C.TEXT
            end
        end

        TRCR2.OnProgress = function(pct, label)
            tween(progFill, TweenInfo.new(0.4),
                {Size=UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)})
            progLabel.Text = label or ""
        end

        TRCR2.OnChain = function(chain)
            local s = TRCR2.GetStats()
            chips.chains.Text = tostring(s.chains)
        end

        TRCR2.OnFragment = function(frag)
            local s = TRCR2.GetStats()
            chips.frags.Text = tostring(s.fragments)
            chips.gaps.Text  = tostring(s.sanitizationGaps)
        end

        TRCR2.OnDone = function(chains, frags)
            local s = TRCR2.GetStats()
            chips.scripts.Text = tostring(s.scriptsScanned)
            chips.chains.Text  = tostring(s.chains)
            chips.frags.Text   = tostring(s.fragments)
            chips.gaps.Text    = tostring(s.sanitizationGaps)
            chips.live.Text    = tostring(s.liveFinds)
            tween(progFill, TweenInfo.new(0.5), {Size=UDim2.new(1,0,1,0)})
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- BUTTONS
    -- ══════════════════════════════════════════════════════════════════════════
    runBtn.MouseButton1Click:Connect(function()
        clickSound()
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 then sendNotif("TRCR not loaded.", "Warning"); return end
        local ok, err = TRCR2.Run()
        if not ok then
            sendNotif("✗ " .. tostring(err), "Warning")
        else
            sendNotif("⟶  S2S Trace started (30s observe window)", "Success")
            switchTab("chains")
        end
    end)

    staticBtn.MouseButton1Click:Connect(function()
        clickSound()
        local TRCR2 = _G.PC and _G.PC.TRCR
        if not TRCR2 then sendNotif("TRCR not loaded.", "Warning"); return end
        local ok, err = TRCR2.RunStatic()
        if not ok then
            sendNotif("✗ " .. tostring(err), "Warning")
        else
            sendNotif("⟶  Static-only trace started", "Success")
            switchTab("static")
        end
    end)

    resetBtn.MouseButton1Click:Connect(function()
        clickSound()
        local TRCR2 = _G.PC and _G.PC.TRCR
        if TRCR2 then
            TRCR2.Reset()
            chips.scripts.Text = "0"
            chips.chains.Text  = "0"
            chips.frags.Text   = "0"
            chips.gaps.Text    = "0"
            chips.live.Text    = "0"
            tween(progFill, TweenInfo.new(0.3), {Size=UDim2.new(0,0,1,0)})
            progLabel.Text = "Awaiting run"
            buildChains()
            sendNotif("TRCR reset", "Success")
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- INIT
    -- ══════════════════════════════════════════════════════════════════════════
    tabBuilders["chains"]    = buildChains
    tabBuilders["fragments"] = buildFragments
    tabBuilders["static"]    = buildStatic
    tabBuilders["live"]      = buildLive
    tabBuilders["about"]     = buildAbout

    wireCallbacks()
    buildAbout()
    switchTab("about")
end
