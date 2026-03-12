-- ══════════════════════════════════════════════════════════════════════════════
-- BGH_UI — BedRock Gadget Hunt Interface
-- Self-registering standalone page. No changes to ui_base or boot required.
-- ══════════════════════════════════════════════════════════════════════════════

local _U2     = _G.PCU
local pageBGH = _U2.makePage("BGH")

-- ── Self-inject nav button ────────────────────────────────────────────────────
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
        Text="◈  BGH",
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
        0.6, 0.0)

    navBtn.MouseButton1Click:Connect(function()
        _C2.clickSound()
        for _, page in ipairs(pagesFolder:GetChildren()) do
            page.Visible = false
        end
        pageBGH.Visible = true
        panelTitle.Text = "BGH"
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

    _G.PCU.pageBGH = pageBGH
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UI BLOCK
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
        BG      = Color3.fromRGB(8,7,12),
        SURFACE = Color3.fromRGB(14,12,20),
        CARD    = Color3.fromRGB(18,16,26),
        BORDER  = Color3.fromRGB(32,28,46),
        TEXT    = Color3.fromRGB(210,206,235),
        MUTED   = Color3.fromRGB(72,68,95),
        DIM     = Color3.fromRGB(40,36,58),
        RED     = Color3.fromRGB(215,55,55),
        AMBER   = Color3.fromRGB(220,165,38),
        GREEN   = Color3.fromRGB(48,196,88),
        TEAL    = Color3.fromRGB(38,196,150),
        CYAN    = Color3.fromRGB(48,210,220),
        PURP    = Color3.fromRGB(148,98,238),
        BLUE    = Color3.fromRGB(75,145,240),
        GOLD    = Color3.fromRGB(255,192,38),
        ORANGE  = Color3.fromRGB(210,100,38),
        -- BGH-specific
        SCAN    = Color3.fromRGB(38,196,150),   -- scanning active
        RET     = Color3.fromRGB(220,165,38),   -- RET found
        GADGET  = Color3.fromRGB(148,98,238),   -- gadget confirmed
        PE      = Color3.fromRGB(75,145,240),   -- PE hunt
        ERROR   = Color3.fromRGB(215,55,55),
    }

    local STATE_COLORS = {
        IDLE        = C.DIM,
        PE_HUNT     = C.PE,
        TEXT_LOCATE = C.CYAN,
        SCANNING    = C.SCAN,
        DONE        = C.GREEN,
        ERROR       = C.ERROR,
    }

    -- Score color
    local function scoreColor(score)
        if score >= 0.85 then return C.GREEN end
        if score >= 0.70 then return C.TEAL  end
        if score >= 0.55 then return C.AMBER end
        return C.MUTED
    end

    pageBGH.BackgroundColor3 = C.BG

    -- ══════════════════════════════════════════════════════════════════════════
    -- TOP BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,52), Parent=pageBGH})
    addStroke(topBar, 1, 0.5)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,12), Parent=topBar})

    -- Title
    local titleBlock = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.36,0,1,0), Parent=topBar})
    mk("UIListLayout", {Padding=UDim.new(0,2), Parent=titleBlock})
    mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="◈  BedRock Gadget Hunt",
        TextColor3=C.GADGET, TextSize=14,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=titleBlock})
    local stateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="STATE: IDLE  ·  Awaiting BRE ACTIVE",
        TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(1,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=2, Parent=titleBlock})

    -- Stat chips
    local statsRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.40,0,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=statsRow})

    local statChips = {}
    local function makeChip(parent, label, col)
        local chip = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(0,72,0,32), Parent=parent})
        addCorner(chip, UDim.new(0,6))
        addStroke(chip, 1, 0)
        if chip:FindFirstChildOfClass("UIStroke") then
            chip:FindFirstChildOfClass("UIStroke").Color = col
        end
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

    statChips.pages   = makeChip(statsRow, "Pages",   C.PE)
    statChips.bytes   = makeChip(statsRow, "Bytes",   C.SCAN)
    statChips.rets    = makeChip(statsRow, "RETs",    C.RET)
    statChips.gadgets = makeChip(statsRow, "Gadgets", C.GADGET)
    statChips.errors  = makeChip(statsRow, "Errors",  C.RED)

    -- Run / Stop buttons
    local runBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="◈  Start Hunt",
        TextColor3=C.MUTED, TextSize=12,
        Size=UDim2.new(0,140,0,36), Parent=topBar})
    addCorner(runBtn, UDim.new(0,8))
    addStroke(runBtn, 1, 0.5)

    local stopBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="■",
        TextColor3=C.RED, TextSize=14,
        Size=UDim2.new(0,32,0,36), Parent=topBar})
    addCorner(stopBtn, UDim.new(0,8))
    addStroke(stopBtn, 1, 0.6)
    if stopBtn:FindFirstChildOfClass("UIStroke") then
        stopBtn:FindFirstChildOfClass("UIStroke").Color = C.RED
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- PROGRESS BAR + SCAN INFO STRIP
    -- ══════════════════════════════════════════════════════════════════════════
    local progStrip = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,52), Size=UDim2.new(1,0,0,38),
        Parent=pageBGH})
    addStroke(progStrip, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6),
        Parent=progStrip})
    mk("UIListLayout", {Padding=UDim.new(0,8), Parent=progStrip})

    -- Phase label row
    local phaseRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,14), LayoutOrder=1, Parent=progStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,14), Parent=phaseRow})

    local PHASE_LABELS = {
        {key="PE_HUNT",     label="PE Hunt"},
        {key="TEXT_LOCATE", label="→  .text Locate"},
        {key="SCANNING",    label="→  Byte Scan"},
        {key="DONE",        label="→  Done"},
    }
    local phaseLbls = {}
    for _, ph in ipairs(PHASE_LABELS) do
        local lbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=ph.label, TextColor3=C.DIM, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=phaseRow})
        phaseLbls[ph.key] = lbl
    end

    -- Progress bar
    local progBg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,6), LayoutOrder=2, Parent=progStrip})
    addCorner(progBg, UDim.new(0,3))
    local progFill = mk("Frame", {
        BackgroundColor3=C.GADGET, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=progBg})
    addCorner(progFill, UDim.new(0,3))

    local progLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="", TextColor3=C.MUTED, TextSize=9,
        Size=UDim2.new(1,0,0,10), LayoutOrder=3,
        TextXAlignment=Enum.TextXAlignment.Left, Parent=progStrip})

    -- ══════════════════════════════════════════════════════════════════════════
    -- PE / .TEXT INFO STRIP
    -- ══════════════════════════════════════════════════════════════════════════
    local addrStrip = mk("Frame", {
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,90), Size=UDim2.new(1,0,0,22),
        Parent=pageBGH})
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=addrStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,24), Parent=addrStrip})

    local function addrField(label, col)
        local f = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=addrStrip})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=f})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=label, TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=f})
        local val = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=col, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=f})
        return val
    end

    local addrAnchor  = addrField("Anchor:",   C.MUTED)
    local addrPEBase  = addrField("PE Base:",  C.PE)
    local addrTxtBase = addrField(".text:",    C.SCAN)
    local addrTxtSize = addrField("Size:",     C.MUTED)
    local addrCurrent = addrField("Cursor:",   C.GADGET)

    addrAnchor.Text = string.format("0x%X", 0x7FF7684D1030)

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local CONTENT_TOP = 112

    local tabBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP), Size=UDim2.new(1,0,0,34),
        Parent=pageBGH})
    addStroke(tabBar, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})

    local TABS = {
        {key="gadgets",  label="Gadgets"  },
        {key="memory",   label="Memory"   },
        {key="pe",       label="PE Map"   },
        {key="log",      label="Log"      },
        {key="settings", label="Settings" },
    }

    local tabBtns   = {}
    local tabPages2 = {}
    local activeTab = nil

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP+34),
        Size=UDim2.new(1,0,1,-(CONTENT_TOP+34)),
        ClipsDescendants=true, Parent=pageBGH})

    local function makeTabPage2()
        local p = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3,
            ScrollBarImageColor3=C.MUTED,
            Visible=false, Parent=contentArea})
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=p})
        return p
    end

    local tabBuilders = {}

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
        tabPages2[tab.key] = makeTabPage2()
    end

    local function switchTab(key)
        if activeTab == key then return end
        for k, p in pairs(tabPages2) do p.Visible = (k==key) end
        for k, b in pairs(tabBtns) do
            local on = (k==key)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = on and C.SURFACE or C.CARD,
                TextColor3       = on and C.GADGET  or C.MUTED,
            })
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then
                tween(st, TweenInfo.new(0.1),
                    {Color = on and C.GADGET or C.BORDER})
            end
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
    -- GADGETS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildGadgets()
        local pg = tabPages2["gadgets"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local BGH2 = _G.PC and _G.PC.BGH
        if not BGH2 or #BGH2.Gadgets == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No gadgets found yet. Start the hunt to scan .text segment.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        -- Summary header
        local stats = BGH2.GetStats()
        local summHdr = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,32), LayoutOrder=1, Parent=pg})
        addCorner(summHdr, UDim.new(0,6))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,6), Parent=summHdr})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format(
                "%d gadgets  ·  %d RETs scanned  ·  %d forbidden discarded  ·  %d read errors",
                stats.confirmed, stats.retFound, stats.forbidden, stats.readErrors),
            TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=summHdr})

        local lo = 2
        for _, g in ipairs(BGH2.Gadgets) do
            local col = scoreColor(g.score)

            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.4)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = col
            end
            lo = lo + 1

            -- Color accent strip
            local strip = mk("Frame", {
                BackgroundColor3=col, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,3))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0),
                Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                PaddingRight=UDim.new(0,10), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=body})

            -- Header row: ID + class + score
            local hdrRow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=body})
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=hdrRow})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=g.id, TextColor3=col, TextSize=11,
                Size=UDim2.new(0,72,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=hdrRow})

            local clsChip = mk("TextLabel", {
                BackgroundColor3=Color3.fromRGB(14,12,22), BorderSizePixel=0,
                Font=Enum.Font.GothamBold, Text=g.class or "UNKNOWN",
                TextColor3=col, TextSize=9,
                Size=UDim2.new(0,0,0,18), AutomaticSize=Enum.AutomaticSize.X,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=hdrRow})
            addCorner(clsChip, UDim.new(0,4))
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
                Parent=clsChip})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("score=%.2f", g.score),
                TextColor3=col, TextSize=9,
                Size=UDim2.new(0,70,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=hdrRow})

            -- Address row
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format(
                    "addr=0x%X  ret=0x%X  depth=%d  bytes=%d",
                    g.address or 0, g.retAddr or 0,
                    g.depth or 0, g.byteCount or 0),
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,12),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=body})

            -- Hex dump
            local hexFrame = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(10,8,16), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,20), LayoutOrder=3, Parent=body})
            addCorner(hexFrame, UDim.new(0,4))
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
                PaddingTop=UDim.new(0,4), Parent=hexFrame})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=g.hex or "??",
                TextColor3=C.TEAL, TextSize=10,
                Size=UDim2.new(1,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=hexFrame})

            -- Copy address button
            local copyBtn = mk("TextButton", {
                AutoButtonColor=false,
                BackgroundColor3=C.DIM, BorderSizePixel=0,
                Font=Enum.Font.Code, Text="⎘ addr",
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(0,58,0,18), LayoutOrder=4, Parent=body})
            addCorner(copyBtn, UDim.new(0,4))

            local capturedAddr = g.address
            local capturedHex  = g.hex
            copyBtn.MouseButton1Click:Connect(function()
                clickSound()
                pcall(function()
                    game:GetService("GuiService"):SetClipboard(
                        string.format("0x%X  [%s]", capturedAddr, capturedHex))
                end)
                copyBtn.Text = "✓ OK"
                task.delay(1.5, function() copyBtn.Text = "⎘ addr" end)
            end)
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- MEMORY TAB — live byte stream view
    -- ══════════════════════════════════════════════════════════════════════════
    local memLines    = {}
    local memScroll
    local memLo       = 1

    local function setupMemory()
        local pg = tabPages2["memory"]
        for _, c in ipairs(pg:GetChildren()) do c:Destroy() end

        local hdr = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=pg})
        addCorner(hdr, UDim.new(0,6))
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=hdr})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Live byte stream  ·  RET bytes highlighted  ·  last 512 reads",
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=hdr})

        memScroll = mk("ScrollingFrame", {
            BackgroundColor3=Color3.fromRGB(6,5,10), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,320), LayoutOrder=2,
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3, ScrollBarImageColor3=C.MUTED,
            Parent=pg})
        addCorner(memScroll, UDim.new(0,6))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            Parent=memScroll})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,1), Parent=memScroll})
    end

    local MEM_MAX = 512
    local memBuffer = {}  -- circular: {addr, byte, isRet}

    local function appendMemLine(addr, byte, isRet)
        if not memScroll then return end

        table.insert(memBuffer, {addr=addr, byte=byte, isRet=isRet})
        if #memBuffer > MEM_MAX then
            -- Remove oldest displayed line
            local oldest = memScroll:FindFirstChildOfClass("Frame")
            if oldest then oldest:Destroy() end
            table.remove(memBuffer, 1)
        end

        local col = isRet and C.RET or
                    (byte == 0x00 and C.DIM or C.TEXT)

        local row = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,12), LayoutOrder=memLo, ZIndex=1,
            Parent=memScroll})
        memLo = memLo + 1
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Parent=row})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("0x%X", addr),
            TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(0,130,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("0x%02X", byte) ..
                 (isRet and "  ← RET" or ""),
            TextColor3=col, TextSize=9,
            Size=UDim2.new(1,-134,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

        task.defer(function()
            if memScroll then
                memScroll.CanvasPosition = Vector2.new(0, 99999)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- PE MAP TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildPEMap()
        local pg = tabPages2["pe"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local BGH2 = _G.PC and _G.PC.BGH
        local lo = 1

        local function row(label, value, col)
            local r = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=lo, Parent=pg})
            lo = lo + 1
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=r})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=label, TextColor3=C.MUTED, TextSize=10,
                Size=UDim2.new(0,160,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=r})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=value, TextColor3=col or C.TEXT, TextSize=10,
                Size=UDim2.new(1,-176,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=r})
        end

        row("Anchor Address",
            string.format("0x%X", 0x7FF7684D1030), C.MUTED)
        row("Page Size",  "0x1000  (4 KB)", C.MUTED)
        row("Max Walk",   "512 pages  (~2 MB)", C.MUTED)

        if BGH2 then
            local stats = BGH2.GetStats()
            row("PE Base (MZ)",
                stats.peBase and string.format("0x%X", stats.peBase) or "—",
                C.PE)
            row(".text Base",
                stats.textBase and string.format("0x%X", stats.textBase) or "—",
                C.SCAN)
            row(".text Size",
                stats.textSize and string.format(
                    "0x%X  (%.2f MB)", stats.textSize, stats.textSize/1048576) or "—",
                C.MUTED)
            row(".text End",
                (stats.textBase and stats.textSize) and
                string.format("0x%X",
                    stats.textBase + stats.textSize) or "—",
                C.MUTED)
            row("Pages Walked",   tostring(stats.pagesWalked), C.PE)
            row("Bytes Read",     tostring(stats.bytesRead),   C.SCAN)
            row("Cache Hits",     tostring(stats.cacheHits),   C.TEAL)
            row("RETs Found",     tostring(stats.retFound),    C.RET)
            row("Seqs Checked",   tostring(stats.sequencesChecked), C.MUTED)
            row("Forbidden Disc.",tostring(stats.forbidden),   C.RED)
            row("Confirmed",      tostring(stats.confirmed),   C.GADGET)
            row("Read Errors",    tostring(stats.readErrors),  C.RED)
        else
            row("BGH Module", "Not loaded", C.RED)
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- LOG TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local logScroll
    local logLo = 1

    local LOG_COLORS = {
        INFO    = Color3.fromRGB(170,166,200),
        GADGET  = Color3.fromRGB(148,98,238),
        WARN    = Color3.fromRGB(210,100,38),
        ERROR   = Color3.fromRGB(215,55,55),
    }

    local function setupLog()
        local pg = tabPages2["log"]
        for _, c in ipairs(pg:GetChildren()) do c:Destroy() end

        logScroll = mk("ScrollingFrame", {
            BackgroundColor3=Color3.fromRGB(6,5,10), BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3, ScrollBarImageColor3=C.MUTED,
            Parent=pg})
        addCorner(logScroll, UDim.new(0,6))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            Parent=logScroll})
        mk("UIListLayout", {
            SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,1), Parent=logScroll})
    end

    local function appendLog(level, msg)
        if not logScroll then return end
        local col = LOG_COLORS[level] or C.MUTED
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("[%7.2f][%-6s] %s", os.clock(), level, msg),
            TextColor3=col, TextSize=9, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=logLo, Parent=logScroll})
        logLo = logLo + 1
        task.defer(function()
            if logScroll then
                logScroll.CanvasPosition = Vector2.new(0, 99999)
            end
        end)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- SETTINGS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildSettings()
        local pg = tabPages2["settings"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local BGH2 = _G.PC and _G.PC.BGH
        local lo = 1

        local function secHdr(title, col)
            local h = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(16,14,24), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,22), LayoutOrder=lo, Parent=pg})
            addCorner(h, UDim.new(0,5))
            lo = lo + 1
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=h})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=title, TextColor3=col or C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=h})
        end

        local function settingRow(label, value, desc)
            local r = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(r, UDim.new(0,5))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=r})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=r})
            local lrow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=r})
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=lrow})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=label, TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(0.5,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=lrow})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                Text=tostring(value), TextColor3=C.CYAN, TextSize=9,
                Size=UDim2.new(0.5,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=lrow})
            if desc and #desc > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=desc, TextColor3=C.DIM, TextSize=8, TextWrapped=true,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    LayoutOrder=2, Parent=r})
            end
        end

        secHdr("PE Hunt", C.PE)
        settingRow("Anchor", string.format("0x%X", 0x7FF7684D1030),
            "Known address inside .text segment")
        settingRow("Page Size", "0x1000 (4 KB)", "Windows page alignment")
        settingRow("Max Walk Pages", "512", "~2 MB backward walk limit")

        secHdr("Scan Depth", C.GADGET)
        settingRow("Min Depth", "5 instructions",
            "Minimum backward instructions from RET")
        settingRow("Max Depth", "8 instructions",
            "Maximum — keeps side effects bounded")
        settingRow("Batch Size", "64 bytes", "Addresses per yield cycle")
        settingRow("Read Interval", "0.04s", "25 reads/sec maximum")
        settingRow("Read Retries", "3", "Per-address retry count")

        secHdr("Filters", C.RED)
        settingRow("Forbidden", "nested RET, INT, SYSCALL, SYSENTER, FAR RET",
            "Any sequence containing these is discarded")

        secHdr("Gadget Classes (by score)", C.CYAN)
        local classes = {
            {"MOV_MEM_WRITE", "0.95", "AAW primitive — highest value"},
            {"MOV_MEM_READ",  "0.90", "AAR primitive"},
            {"CALL_REG",      "0.88", "Dispatch pivot"},
            {"LEA",           "0.82", "Address computation"},
            {"POP_R*",        "0.78", "Stack pivot"},
            {"XOR_*",         "0.65", "Register manipulation"},
            {"ADD / SUB",     "0.60", "Arithmetic"},
            {"GENERIC",       "0.45", "Unclassified"},
        }
        for _, cls in ipairs(classes) do
            settingRow(cls[1], cls[2], cls[3])
        end

        -- Manual .text override
        secHdr("Manual Override", C.AMBER)
        local overrideNote = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="If PE parsing produces imprecise results, call BGH.SetTextBounds(base, size) from the console to skip PE hunt and scan directly.",
            TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=lo, Parent=pg})
        lo = lo + 1
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- BGH CALLBACKS
    -- ══════════════════════════════════════════════════════════════════════════
    local function wireCallbacks()
        local BGH2 = _G.PC and _G.PC.BGH
        if not BGH2 then return end

        BGH2.OnLog = function(level, msg)
            appendLog(level, msg)
        end

        BGH2.OnStateChange = function(newState, oldState)
            local col = STATE_COLORS[newState] or C.MUTED
            stateLabel.Text = string.format("STATE: %s", newState)
            stateLabel.TextColor3 = col

            -- Update phase dot colors
            for key, lbl in pairs(phaseLbls) do
                tween(lbl, TweenInfo.new(0.2), {
                    TextColor3 = (key == newState) and col or
                                 (key == oldState) and C.GREEN or C.DIM
                })
            end

            -- Run button
            if newState == "SCANNING" or newState == "PE_HUNT" or
               newState == "TEXT_LOCATE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.SCAN})
                runBtn.Text = "◌  Scanning..."
                runBtn.TextColor3 = Color3.fromRGB(6,8,6)
            elseif newState == "DONE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.GREEN})
                runBtn.Text = "◈  Hunt Done"
                runBtn.TextColor3 = Color3.fromRGB(6,8,6)
            elseif newState == "ERROR" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.ERROR})
                runBtn.Text = "✕  Error"
                runBtn.TextColor3 = C.TEXT
            else
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                runBtn.Text = "◈  Start Hunt"
                runBtn.TextColor3 = C.MUTED
            end

            task.defer(buildPEMap)
            appendLog("INFO", string.format(
                "State: %s → %s", oldState, newState))
        end

        BGH2.OnByteRead = function(address, byte)
            local isRet = (byte == 0xC3 or byte == 0xC2)
            appendMemLine(address, byte, isRet)

            -- Update cursor in addr strip
            addrCurrent.Text = string.format("0x%X", address)

            -- Update stat chips
            local stats = BGH2.GetStats()
            statChips.bytes.Text   = tostring(stats.bytesRead)
            statChips.rets.Text    = tostring(stats.retFound)
            statChips.errors.Text  = tostring(stats.readErrors)
        end

        BGH2.OnGadget = function(gadget)
            local stats = BGH2.GetStats()
            statChips.gadgets.Text = tostring(stats.confirmed)

            appendLog("GADGET", string.format(
                "[%s] %s  @0x%X  score=%.2f  [%s]",
                gadget.id, gadget.class, gadget.address,
                gadget.score, gadget.hex))

            -- Live-append to gadgets tab
            task.defer(buildGadgets)
        end

        BGH2.OnProgress = function(bytesScanned, totalBytes, gadgetsFound)
            local pct = totalBytes > 0 and bytesScanned / totalBytes or 0
            tween(progFill, TweenInfo.new(0.5),
                {Size=UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)})
            progLabel.Text = string.format(
                "%.1f%%  ·  %d / %d bytes  ·  %d gadgets",
                pct * 100, bytesScanned, totalBytes, gadgetsFound)

            local stats = BGH2.GetStats()
            statChips.pages.Text = tostring(stats.pagesWalked)
        end

        BGH2.OnDone = function(gadgets)
            tween(progFill, TweenInfo.new(0.5), {Size=UDim2.new(1,0,1,0)})
            progLabel.Text = string.format(
                "Scan complete — %d gadgets confirmed", #gadgets)

            -- Update PE base and .text addr displays
            local stats = BGH2.GetStats()
            if stats.peBase then
                addrPEBase.Text  = string.format("0x%X", stats.peBase)
            end
            if stats.textBase then
                addrTxtBase.Text = string.format("0x%X", stats.textBase)
            end
            if stats.textSize then
                addrTxtSize.Text = string.format("0x%X  (%.2f MB)",
                    stats.textSize, stats.textSize / 1048576)
            end

            task.defer(buildGadgets)
            task.defer(buildPEMap)

            sendNotif(string.format(
                "◈ BGH done — %d gadgets found", #gadgets), "Success")
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- RUN / STOP BUTTONS
    -- ══════════════════════════════════════════════════════════════════════════
    local bghReady = false

    runBtn.MouseButton1Click:Connect(function()
        if not bghReady then return end
        clickSound()

        local BGH2 = _G.PC and _G.PC.BGH
        if not BGH2 then
            sendNotif("BGH module not loaded.", "Warning"); return
        end

        local ok, err = BGH2.Run()
        if not ok then
            sendNotif("✗ " .. tostring(err), "Warning")
        else
            sendNotif("◈ Gadget Hunt started", "Success")
            switchTab("memory")
        end
    end)

    stopBtn.MouseButton1Click:Connect(function()
        clickSound()
        local BGH2 = _G.PC and _G.PC.BGH
        if BGH2 then
            BGH2.Reset()
            tween(progFill, TweenInfo.new(0.3), {Size=UDim2.new(0,0,1,0)})
            progLabel.Text = ""
            statChips.pages.Text   = "0"
            statChips.bytes.Text   = "0"
            statChips.rets.Text    = "0"
            statChips.gadgets.Text = "0"
            statChips.errors.Text  = "0"
            addrPEBase.Text  = "—"
            addrTxtBase.Text = "—"
            addrTxtSize.Text = "—"
            addrCurrent.Text = "—"
            sendNotif("BGH stopped", "Success")
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- BRE ACTIVE WATCHER — enable run button only when BRE command surface live
    -- ══════════════════════════════════════════════════════════════════════════
    task.spawn(function()
        while true do
            task.wait(2)
            local BRE2  = _G.PC and _G.PC.BRE
            local BGH2  = _G.PC and _G.PC.BGH
            local breActive = BRE2 and BRE2.CurrentState == "ACTIVE"
            local bghIdle   = BGH2 and (BGH2.CurrentState == "IDLE" or
                                        BGH2.CurrentState == "DONE" or
                                        BGH2.CurrentState == "ERROR")

            bghReady = breActive and bghIdle

            if bghReady then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.GADGET})
                runBtn.TextColor3 = Color3.fromRGB(6,4,10)
                runBtn.Text = "◈  Start Hunt"
                stateLabel.Text = string.format(
                    "STATE: %s  ·  BRE ACTIVE  ·  Ready",
                    BGH2 and BGH2.CurrentState or "IDLE")
                stateLabel.TextColor3 = C.GADGET
            elseif not breActive then
                if BGH2 and BGH2.CurrentState == "IDLE" then
                    stateLabel.Text = "Awaiting BRE ACTIVE state"
                    stateLabel.TextColor3 = C.MUTED
                    tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                    runBtn.TextColor3 = C.MUTED
                end
            end
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- INIT
    -- ══════════════════════════════════════════════════════════════════════════
    tabBuilders["gadgets"]  = buildGadgets
    tabBuilders["pe"]       = buildPEMap
    tabBuilders["settings"] = buildSettings

    wireCallbacks()
    setupMemory()
    setupLog()
    buildSettings()
    switchTab("gadgets")
end
