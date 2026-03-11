-- ══════════════════════════════════════════════════════════════════════════════
-- BRE_UI — BedRock Execution Interface
-- Self-registering standalone page. Requires no changes to ui_base or boot.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Self-register page ────────────────────────────────────────────────────────
local _U2    = _G.PCU
local pageBRE = _U2.makePage("BRE")

-- ── Self-inject nav button ────────────────────────────────────────────────────
do
    local _C2       = _G.PC
    local mk2       = _C2.mk
    local addCorner2= _C2.addCorner
    local addStroke2= _C2.addStroke
    local hookHover2= _C2.hookHover
    local tween2    = _C2.tween
    local navHolder  = _U2.navHolder
    local pagesFolder= _U2.pagesFolder
    local panelTitle = _U2.panelTitle

    local navBtn = mk2("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=Color3.fromRGB(245,239,231),
        BorderSizePixel=0, Size=UDim2.new(1,0,0,34),
        Font=Enum.Font.GothamSemibold,
        Text="⚡  BRE",
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
        pageBRE.Visible = true
        panelTitle.Text = "BRE"
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

    _G.PCU.pageBRE = pageBRE
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UI BLOCK
-- ══════════════════════════════════════════════════════════════════════════════
do
    local _C = _G.PC
    local _U = _G.PCU
    local mk            = _C.mk
    local addCorner     = _C.addCorner
    local addStroke     = _C.addStroke
    local pulseClick    = _C.pulseClick
    local tween         = _C.tween
    local clickSound    = _C.clickSound
    local sendNotif     = _U.sendNotification

    -- ── Palette ───────────────────────────────────────────────────────────────
    local C = {
        BG       = Color3.fromRGB(8,7,12),
        SURFACE  = Color3.fromRGB(14,12,20),
        CARD     = Color3.fromRGB(18,16,26),
        BORDER   = Color3.fromRGB(32,28,46),
        TEXT     = Color3.fromRGB(210,206,235),
        MUTED    = Color3.fromRGB(72,68,95),
        DIM      = Color3.fromRGB(40,36,58),
        RED      = Color3.fromRGB(215,55,55),
        AMBER    = Color3.fromRGB(220,165,38),
        GREEN    = Color3.fromRGB(48,196,88),
        TEAL     = Color3.fromRGB(38,196,150),
        CYAN     = Color3.fromRGB(48,210,220),
        PURP     = Color3.fromRGB(148,98,238),
        BLUE     = Color3.fromRGB(75,145,240),
        GOLD     = Color3.fromRGB(255,192,38),
        ORANGE   = Color3.fromRGB(210,100,38),
        -- BRE-specific
        ACTIVE   = Color3.fromRGB(38,220,100),  -- command surface live
        PROBE    = Color3.fromRGB(220,168,38),  -- probing
        PRIM     = Color3.fromRGB(148,98,238),  -- primitive found
        CHAIN    = Color3.fromRGB(75,145,240),  -- chain building
        ERROR    = Color3.fromRGB(215,55,55),   -- error
    }

    local STATE_COLORS = {
        IDLE        = C.DIM,
        PROBING     = C.PROBE,
        PRIMITIVE   = C.PRIM,
        GADGET_SCAN = C.BLUE,
        CHAIN_BUILD = C.CHAIN,
        CHAIN_FIRE  = C.AMBER,
        ACTIVE      = C.ACTIVE,
        ERROR       = C.ERROR,
    }

    pageBRE.BackgroundColor3 = C.BG

    -- ══════════════════════════════════════════════════════════════════════════
    -- TOP BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,52), Parent=pageBRE})
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
        Size=UDim2.new(0.4,0,1,0), Parent=topBar})
    mk("UIListLayout", {Padding=UDim.new(0,2), Parent=titleBlock})
    mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="⚡  BedRock Execution",
        TextColor3=C.ACTIVE, TextSize=15,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=titleBlock})
    local stateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="STATE: IDLE  ·  Awaiting Bedrock confirmation",
        TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(1,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=2, Parent=titleBlock})

    -- Stat chips
    local statsRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.38,0,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=statsRow})

    local statChips = {}
    local function makeStatChip(parent, label, col)
        local chip = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(0,68,0,32), Parent=parent})
        addCorner(chip, UDim.new(0,6))
        addStroke(chip, 1, 0)
        if chip:FindFirstChildOfClass("UIStroke") then
            chip:FindFirstChildOfClass("UIStroke").Color = col
        end
        mk("UIPadding", {
            PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3),
            PaddingLeft=UDim.new(0,6), Parent=chip})
        mk("UIListLayout", {Padding=UDim.new(0,0), Parent=chip})
        local valL = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="0", TextColor3=col, TextSize=14,
            Size=UDim2.new(1,0,0,16),
            TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=chip})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=label, TextColor3=C.MUTED, TextSize=8,
            Size=UDim2.new(1,0,0,10),
            TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=chip})
        return valL
    end

    statChips.probes    = makeStatChip(statsRow, "Probes",    C.PROBE)
    statChips.anomalies = makeStatChip(statsRow, "Anomalies", C.AMBER)
    statChips.prims     = makeStatChip(statsRow, "Primitives",C.PRIM)
    statChips.gadgets   = makeStatChip(statsRow, "Gadgets",   C.BLUE)
    statChips.chains    = makeStatChip(statsRow, "Chains",    C.CHAIN)

    -- Run button
    local runBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="⚡  Execute BRE",
        TextColor3=C.MUTED, TextSize=12,
        Size=UDim2.new(0,150,0,36), Parent=topBar})
    addCorner(runBtn, UDim.new(0,8))
    addStroke(runBtn, 1, 0.5)

    -- Reset button
    local resetBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="↺",
        TextColor3=C.MUTED, TextSize=14,
        Size=UDim2.new(0,32,0,36), Parent=topBar})
    addCorner(resetBtn, UDim.new(0,8))

    -- ══════════════════════════════════════════════════════════════════════════
    -- PROGRESS STRIP (phase indicator)
    -- ══════════════════════════════════════════════════════════════════════════
    local progressStrip = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,52), Size=UDim2.new(1,0,0,32),
        Parent=pageBRE})
    addStroke(progressStrip, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=progressStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,8), Parent=progressStrip})

    -- Phase dots
    local PHASES = {
        { label="Baseline",  state="PROBING"     },
        { label="Probe",     state="PROBING"     },
        { label="Primitive", state="PRIMITIVE"   },
        { label="Gadgets",   state="GADGET_SCAN" },
        { label="Chain",     state="CHAIN_BUILD" },
        { label="Fire",      state="CHAIN_FIRE"  },
        { label="ACTIVE",    state="ACTIVE"      },
    }
    local phaseDots = {}
    for i, ph in ipairs(PHASES) do
        local dot = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=progressStrip})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,4), Parent=dot})
        local circle = mk("Frame", {
            BackgroundColor3=C.DIM, BorderSizePixel=0,
            Size=UDim2.new(0,8,0,8), Parent=dot})
        addCorner(circle, UDim.new(0.5,0))
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=ph.label, TextColor3=C.DIM, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=dot})
        if i < #PHASES then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="→", TextColor3=C.DIM, TextSize=9,
                Size=UDim2.new(0,12,1,0),
                TextXAlignment=Enum.TextXAlignment.Center, Parent=dot})
        end
        phaseDots[ph.state] = { circle=circle, label=dot:FindFirstChildOfClass("TextLabel") }
    end

    -- Phase progress bar
    local phaseBg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(0.3,0,0,6), Parent=progressStrip})
    addCorner(phaseBg, UDim.new(0,3))
    local phaseFill = mk("Frame", {
        BackgroundColor3=C.ACTIVE, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=phaseBg})
    addCorner(phaseFill, UDim.new(0,3))

    local phaseLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="", TextColor3=C.MUTED, TextSize=9,
        Size=UDim2.new(0.3,0,1,0),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=progressStrip})

    -- ══════════════════════════════════════════════════════════════════════════
    -- TAB BAR
    -- ══════════════════════════════════════════════════════════════════════════
    local CONTENT_TOP = 84  -- 52 topBar + 32 progress

    local tabBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP), Size=UDim2.new(1,0,0,34),
        Parent=pageBRE})
    addStroke(tabBar, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})

    local TABS = {
        { key="overview",  label="Overview"  },
        { key="probes",    label="Probes"    },
        { key="anomalies", label="Anomalies" },
        { key="primitives",label="Primitives"},
        { key="gadgets",   label="Gadgets"   },
        { key="chain",     label="Chain"     },
        { key="console",   label="Console"   },
        { key="log",       label="Log"       },
    }

    local tabBtns  = {}
    local tabPages2 = {}
    local activeTab = nil

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP+34),
        Size=UDim2.new(1,0,1,-(CONTENT_TOP+34)),
        ClipsDescendants=true, Parent=pageBRE})

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

    for _, tab in ipairs(TABS) do
        local t = tab
        local btn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Font=Enum.Font.GothamMedium, Text=t.label,
            TextColor3=C.MUTED, TextSize=11,
            Size=UDim2.new(0,78,0,26), Parent=tabBar})
        addCorner(btn, UDim.new(0,6))
        addStroke(btn, 1, 0.5)
        tabBtns[t.key]   = btn
        tabPages2[t.key] = makeTabPage2()
    end

    local tabBuilders = {}  -- populated at init after builders defined

    local function switchTab(key)
        if activeTab == key then return end
        for k, p in pairs(tabPages2) do p.Visible = (k==key) end
        for k, b in pairs(tabBtns) do
            local on = (k==key)
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = on and C.SURFACE or C.CARD,
                TextColor3       = on and C.ACTIVE  or C.MUTED,
            })
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then
                tween(st, TweenInfo.new(0.1),
                    {Color = on and C.ACTIVE or C.BORDER})
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
    switchTab("overview")

    -- ══════════════════════════════════════════════════════════════════════════
    -- SHARED UI HELPERS
    -- ══════════════════════════════════════════════════════════════════════════
    local function secHdr(parent, title, col, lo)
        local h = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(16,14,24), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), LayoutOrder=lo or 1, Parent=parent})
        addCorner(h, UDim.new(0,5))
        addStroke(h, 1, 0.4)
        if h:FindFirstChildOfClass("UIStroke") then
            h:FindFirstChildOfClass("UIStroke").Color = col or C.MUTED
        end
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=h})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=title, TextColor3=col or C.MUTED, TextSize=11,
            Size=UDim2.new(1,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=h})
        return h
    end

    local function infoCard(parent, fields, lo)
        local card = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo or 1, Parent=parent})
        addCorner(card, UDim.new(0,7))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
        mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})
        local i = 1
        for label, value in pairs(fields) do
            local row = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,16), LayoutOrder=i, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=label, TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(0,130,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                Text=tostring(value), TextColor3=C.TEXT, TextSize=9,
                Size=UDim2.new(1,-146,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            i = i + 1
        end
        return card
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- OVERVIEW TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildOverview()
        local pg = tabPages2["overview"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 then return end
        local stats = BRE2.GetStats()
        local lo = 1

        -- State banner
        local stateCol = STATE_COLORS[stats.state] or C.MUTED
        local banner = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(12,10,18), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,48), LayoutOrder=lo, Parent=pg})
        addCorner(banner, UDim.new(0,8))
        addStroke(banner, 2, 0)
        if banner:FindFirstChildOfClass("UIStroke") then
            banner:FindFirstChildOfClass("UIStroke").Color = stateCol
        end
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,16), PaddingRight=UDim.new(0,16),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=banner})
        mk("UIListLayout", {Padding=UDim.new(0,4), Parent=banner})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=stats.state, TextColor3=stateCol, TextSize=16,
            Size=UDim2.new(1,0,0,22),
            TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=banner})

        local stateDescs = {
            IDLE        = "Awaiting execution. Confirm Bedrock handshake then press Execute BRE.",
            PROBING     = "Layer 2: Deserializer probe engine running — systematically testing C++ boundary.",
            PRIMITIVE   = "Layer 3: AAR/AAW primitive surface confirmed. Advancing to gadget scan.",
            GADGET_SCAN = "Layer 4a: Scanning STS module data and RSM history for ROP gadget candidates.",
            CHAIN_BUILD = "Layer 4b: Assembling ROP chain from confirmed gadgets.",
            CHAIN_FIRE  = "Layer 4c: Firing ROP chain through Bedrock channel.",
            ACTIVE      = "Layer 5: COMMAND SURFACE LIVE. Server executing our instruction chain.",
            ERROR       = "Execution error. Check Log tab for details. Reset and retry.",
        }
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=stateDescs[stats.state] or "",
            TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=banner})

        -- Layer progress
        secHdr(pg, "Layer Progress", C.ACTIVE, lo); lo = lo + 1

        local LAYER_DEFS = {
            { n=1, label="Semantic Surface",      desc="Remote catalog, fire signatures, SBI confidence",  done=true                          },
            { n=2, label="WalkOut (Probe)",        desc="Deserializer boundary probing",                    done=stats.totalProbes > 0         },
            { n=3, label="Primitive (AAR/AAW)",    desc="Confirmed read/write surface",                     done=stats.confirmedPrims > 0      },
            { n=4, label="Gadget / ROP Chain",     desc="Gadgets found, chain assembled and fired",         done=stats.chainsFired > 0         },
            { n=5, label="Command Surface",        desc="Sustained execution loop — architect mode",         done=stats.state=="ACTIVE"         },
        }

        local layerBlock = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=pg})
        addCorner(layerBlock, UDim.new(0,7))
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=layerBlock})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=layerBlock})

        for i, layer in ipairs(LAYER_DEFS) do
            local row = mk("Frame", {
                BackgroundColor3=layer.done and Color3.fromRGB(14,22,16) or C.CARD,
                BorderSizePixel=0, Size=UDim2.new(1,0,0,36), LayoutOrder=i, Parent=layerBlock})
            addCorner(row, UDim.new(0,5))
            if layer.done then
                addStroke(row, 1, 0.4)
                if row:FindFirstChildOfClass("UIStroke") then
                    row:FindFirstChildOfClass("UIStroke").Color = C.GREEN
                end
            end

            local strip = mk("Frame", {
                BackgroundColor3=layer.done and C.GREEN or C.DIM,
                BorderSizePixel=0, Size=UDim2.new(0,3,1,0), Parent=row})
            addCorner(strip, UDim.new(0,3))

            local inner = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,1,0), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=inner})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Layer %d  —  %s", layer.n, layer.label),
                TextColor3=layer.done and C.GREEN or C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=inner})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=layer.desc,
                TextColor3=layer.done and C.MUTED or C.DIM, TextSize=9,
                Size=UDim2.new(1,0,0,14),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=inner})

            local statusChip = mk("TextLabel", {
                BackgroundColor3=layer.done and Color3.fromRGB(16,28,18) or C.DIM,
                BorderSizePixel=0, Font=Enum.Font.GothamBold,
                Text=layer.done and "✓ DONE" or "PENDING",
                TextColor3=layer.done and C.GREEN or C.MUTED, TextSize=8,
                Size=UDim2.new(0,60,0,18),
                TextXAlignment=Enum.TextXAlignment.Center, Parent=row})
            addCorner(statusChip, UDim.new(0,4))
            statusChip.Position = UDim2.new(1,-68,0.5,-9)
        end

        -- Stats grid
        secHdr(pg, "Runtime Stats", C.CYAN, lo); lo = lo + 1
        infoCard(pg, {
            ["Total Probes"]     = stats.totalProbes,
            ["Anomalies"]        = stats.anomalies,
            ["Confirmed Prims"]  = stats.confirmedPrims,
            ["Gadgets Found"]    = stats.gadgetsFound,
            ["Chain Length"]     = stats.chainLen,
            ["Chains Fired"]     = stats.chainsFired,
            ["Commands Sent"]    = stats.commandsSent,
            ["Probe Log Size"]   = stats.probeLog,
            ["Command Log Size"] = stats.commandLog,
        }, lo)
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- PROBES TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildProbes()
        local pg = tabPages2["probes"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 or #BRE2.ProbeLog == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No probes fired yet. Run BRE to begin.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        -- Group by category
        local byCat = {}
        local catOrder = {}
        for _, probe in ipairs(BRE2.ProbeLog) do
            if not byCat[probe.category] then
                byCat[probe.category] = { total=0, anomalies=0, avgLatency=0, probes={} }
                table.insert(catOrder, probe.category)
            end
            local c2 = byCat[probe.category]
            c2.total = c2.total + 1
            c2.avgLatency = c2.avgLatency + probe.latency
            if probe.anomalyScore >= 0.35 then c2.anomalies = c2.anomalies + 1 end
            if c2.total <= 20 then table.insert(c2.probes, probe) end
        end

        local lo = 1
        for _, catId in ipairs(catOrder) do
            local cat = byCat[catId]
            cat.avgLatency = cat.avgLatency / math.max(cat.total, 1)
            local hasAnom = cat.anomalies > 0

            local col = hasAnom and C.AMBER or C.MUTED
            secHdr(pg, string.format("%s  (%d probes  %d anomalies  avg=%.3fs)",
                catId, cat.total, cat.anomalies, cat.avgLatency), col, lo)
            lo = lo + 1

            local block = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(block, UDim.new(0,6))
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=block})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=block})

            for pi, probe in ipairs(cat.probes) do
                local isAnom = probe.anomalyScore >= 0.35
                local row = mk("Frame", {
                    BackgroundColor3=isAnom and Color3.fromRGB(22,18,12) or C.CARD,
                    BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,16), LayoutOrder=pi, Parent=block})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center,
                    Padding=UDim.new(0,6), Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("#%-3d", probe.index),
                    TextColor3=C.DIM, TextSize=9,
                    Size=UDim2.new(0,36,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("%.3fs", probe.latency),
                    TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(0,50,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("anom=%.2f", probe.anomalyScore),
                    TextColor3=isAnom and C.AMBER or C.DIM, TextSize=9,
                    Size=UDim2.new(0,80,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=(probe.anomalyReason or ""):sub(1,80),
                    TextColor3=isAnom and C.TEXT or C.DIM, TextSize=9,
                    Size=UDim2.new(1,-180,1,0),
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
            end

            if cat.total > 20 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("  ... %d more probes", cat.total - 20),
                    TextColor3=C.MUTED, TextSize=9,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=21,
                    TextXAlignment=Enum.TextXAlignment.Left, Parent=block})
            end
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- ANOMALIES TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildAnomalies()
        local pg = tabPages2["anomalies"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 or #BRE2.Anomalies == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No anomalies detected yet.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        local lo = 1
        for _, anom in ipairs(BRE2.Anomalies) do
            local col = anom.score >= 0.70 and C.RED or
                        anom.score >= 0.50 and C.AMBER or C.PROBE

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

            local strip = mk("Frame", {
                BackgroundColor3=col, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,3))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,7), PaddingBottom=UDim.new(0,7),
                PaddingRight=UDim.new(0,8), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=body})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("[%.2f]  %s  probe #%d",
                    anom.score, anom.category, anom.probe.index),
                TextColor3=col, TextSize=11,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=anom.reason or "",
                TextColor3=C.TEXT, TextSize=9, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("latency=%.3fs", anom.probe.latency),
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,12),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=3, Parent=body})
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- PRIMITIVES TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildPrimitives()
        local pg = tabPages2["primitives"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 or #BRE2.Primitives == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No confirmed primitives yet. Anomaly score ≥ 0.70 required.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        local lo = 1
        for _, prim in ipairs(BRE2.Primitives) do
            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,8))
            addStroke(card, 2, 0.2)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = C.PRIM
            end
            lo = lo + 1

            mk("UIPadding", {
                PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
                PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,5), Parent=card})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=prim.id .. "  —  " .. prim.category,
                TextColor3=C.PRIM, TextSize=13,
                Size=UDim2.new(1,0,0,18),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=card})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=prim.desc, TextColor3=C.TEXT, TextSize=10, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=card})

            local chipRow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,24), LayoutOrder=3, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,6), Parent=chipRow})

            local function chip(text, col)
                local c2 = mk("TextLabel", {
                    BackgroundColor3=Color3.fromRGB(14,12,22), BorderSizePixel=0,
                    Font=Enum.Font.GothamBold, Text=text,
                    TextColor3=col, TextSize=9,
                    Size=UDim2.new(0,0,0,20), AutomaticSize=Enum.AutomaticSize.X,
                    TextXAlignment=Enum.TextXAlignment.Center, Parent=chipRow})
                addCorner(c2, UDim.new(0,4))
                mk("UIPadding", {
                    PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), Parent=c2})
            end

            chip(string.format("conf=%.0f%%", prim.confidence*100), C.GREEN)
            if prim.hasRead  then chip("AAR", C.CYAN) end
            if prim.hasWrite then chip("AAW", C.RED) end
            chip(prim.sinkRemote or "?", C.MUTED)
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- GADGETS TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildGadgets()
        local pg = tabPages2["gadgets"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 or #BRE2.Gadgets == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No gadgets found yet. Primitive required before gadget scan.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        local lo = 1
        for _, g in ipairs(BRE2.Gadgets) do
            local scoreCol = g.score >= 0.80 and C.GREEN or
                             g.score >= 0.60 and C.AMBER or C.MUTED

            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.4)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = scoreCol
            end
            lo = lo + 1

            local strip = mk("Frame", {
                BackgroundColor3=scoreCol, BorderSizePixel=0,
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
                Text=string.format("[%.2f]  %s  —  %s",
                    g.score, g.id, g.patternLabel),
                TextColor3=scoreCol, TextSize=11,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=g.desc, TextColor3=C.TEXT, TextSize=9, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=body})

            local srcInfo = g.source == "MODULE" and
                (g.module or "?") .. "  " .. (g.modulePath or ""):sub(1,50) or
                "BEHAVIORAL — " .. (g.remote or "?")
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=srcInfo, TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,12),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=3, Parent=body})

            if g.matchedSignals and #g.matchedSignals > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="signals: " .. table.concat(g.matchedSignals, "  "):sub(1,150),
                    TextColor3=C.BLUE, TextSize=9,
                    Size=UDim2.new(1,0,0,12),
                    TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=4, Parent=body})
            end
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- CHAIN TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local function buildChain()
        local pg = tabPages2["chain"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 or #BRE2.Chain == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No chain assembled yet. Gadget scan required.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        -- Fire chain button
        local fireBtnFrame = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,40), LayoutOrder=1, Parent=pg})
        local fireChainBtn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(12,22,18), BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="⚡ Fire ROP Chain",
            TextColor3=C.ACTIVE, TextSize=12,
            Size=UDim2.new(0,160,0,34), Parent=fireBtnFrame})
        addCorner(fireChainBtn, UDim.new(0,8))
        addStroke(fireChainBtn, 1, 0.3)
        if fireChainBtn:FindFirstChildOfClass("UIStroke") then
            fireChainBtn:FindFirstChildOfClass("UIStroke").Color = C.ACTIVE
        end
        fireChainBtn.MouseButton1Click:Connect(function()
            clickSound()
            local ok, err = BRE2.FireChain()
            if not ok then
                sendNotif("✗ " .. tostring(err), "Warning")
            else
                sendNotif("⚡ ROP Chain fired", "Success")
            end
        end)

        local lo = 2
        for _, link in ipairs(BRE2.Chain) do
            local roleColors = {
                ANCHOR   = C.PROBE,
                PIVOT    = C.PURP,
                DELIVERY = C.ACTIVE,
                KEEPALIVE= C.CYAN,
            }
            local roleCol = roleColors[link.role] or C.MUTED

            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.4)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = roleCol
            end
            lo = lo + 1

            local strip = mk("Frame", {
                BackgroundColor3=roleCol, BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Parent=card})
            addCorner(strip, UDim.new(0,3))

            local body = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-14,0,0),
                AutomaticSize=Enum.AutomaticSize.Y, Parent=card})
            mk("UIPadding", {
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
                PaddingRight=UDim.new(0,8), Parent=body})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=body})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Link %d  —  %s  [%s]",
                    link.order, link.role,
                    link.gadget and link.gadget.id or "?"),
                TextColor3=roleCol, TextSize=11,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=1, Parent=body})

            if link.gadget then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=link.gadget.patternLabel or link.gadget.patternId or "?",
                    TextColor3=C.TEXT, TextSize=9,
                    Size=UDim2.new(1,0,0,12),
                    TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=2, Parent=body})
            end
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- CONSOLE TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local consoleOutput
    local consoleInput

    local function setupConsole()
        local pg = tabPages2["console"]
        for _, c in ipairs(pg:GetChildren()) do c:Destroy() end

        -- Status bar
        local statusBar = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,28), LayoutOrder=1, Parent=pg})
        addCorner(statusBar, UDim.new(0,6))
        mk("UIPadding", {PaddingLeft=UDim.new(0,10), Parent=statusBar})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=statusBar})

        local statusDot = mk("Frame", {
            BackgroundColor3=C.DIM, BorderSizePixel=0,
            Size=UDim2.new(0,8,0,8), Parent=statusBar})
        addCorner(statusDot, UDim.new(0.5,0))
        local statusText = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Command surface inactive",
            TextColor3=C.MUTED, TextSize=10,
            Size=UDim2.new(1,-20,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=statusBar})

        -- Output scroll
        consoleOutput = mk("ScrollingFrame", {
            BackgroundColor3=Color3.fromRGB(6,5,10), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,240), LayoutOrder=2,
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3,
            ScrollBarImageColor3=C.MUTED,
            Parent=pg})
        addCorner(consoleOutput, UDim.new(0,6))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            Parent=consoleOutput})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,2), Parent=consoleOutput})

        -- Input row
        local inputRow = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,36), LayoutOrder=3, Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=inputRow})

        local promptLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="BRE >", TextColor3=C.ACTIVE, TextSize=11,
            Size=UDim2.new(0,46,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=inputRow})

        consoleInput = mk("TextBox", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Font=Enum.Font.Code, PlaceholderText="Enter command...",
            PlaceholderColor3=C.DIM, Text="",
            TextColor3=C.TEXT, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left,
            ClearTextOnFocus=false,
            Size=UDim2.new(1,-120,0,30), Parent=inputRow})
        addCorner(consoleInput, UDim.new(0,6))
        addStroke(consoleInput, 1, 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=consoleInput})

        local sendBtn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(12,22,16), BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="Send",
            TextColor3=C.ACTIVE, TextSize=11,
            Size=UDim2.new(0,62,0,30), Parent=inputRow})
        addCorner(sendBtn, UDim.new(0,6))
        addStroke(sendBtn, 1, 0.4)
        if sendBtn:FindFirstChildOfClass("UIStroke") then
            sendBtn:FindFirstChildOfClass("UIStroke").Color = C.ACTIVE
        end

        -- Console output helper
        local conLo = 1
        local function consoleWrite(text, col)
            local line = mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=text, TextColor3=col or C.TEXT, TextSize=10,
                TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=conLo, Parent=consoleOutput})
            conLo = conLo + 1
            -- Auto-scroll
            task.defer(function()
                consoleOutput.CanvasPosition = Vector2.new(0, 99999)
            end)
        end

        consoleWrite("BRE Command Console — v" .. (_G.PC.BRE and _G.PC.BRE.VERSION or "?"), C.ACTIVE)
        consoleWrite("Command surface must be ACTIVE to send commands.", C.MUTED)
        consoleWrite("", C.DIM)

        -- State watcher
        task.spawn(function()
            while true do
                task.wait(1)
                local BRE2 = _G.PC and _G.PC.BRE
                if not BRE2 then break end
                local active = BRE2.CurrentState == "ACTIVE"
                statusDot.BackgroundColor3 = active and C.ACTIVE or C.DIM
                statusText.Text = active and "Command surface LIVE" or
                    "State: " .. BRE2.CurrentState
                statusText.TextColor3 = active and C.ACTIVE or C.MUTED
            end
        end)

        -- BRE command result callback
        if _G.PC.BRE then
            _G.PC.BRE.OnCommandResult = function(result)
                consoleWrite(string.format("[%s] %s  %.3fs  ok=%s",
                    result.cmdId, result.cmdType, result.latency, tostring(result.ok)),
                    result.ok and C.GREEN or C.RED)
                if result.result ~= nil then
                    consoleWrite("  result: " .. tostring(result.result):sub(1,120), C.TEXT)
                end
            end
        end

        local function sendCommand()
            local BRE2 = _G.PC and _G.PC.BRE
            if not BRE2 then return end

            local raw = consoleInput.Text:match("^%s*(.-)%s*$")
            if raw == "" then return end
            consoleInput.Text = ""

            consoleWrite("BRE > " .. raw, C.ACTIVE)

            if BRE2.CurrentState ~= "ACTIVE" then
                consoleWrite("  [error] Command surface not active (state: " ..
                    BRE2.CurrentState .. ")", C.RED)
                return
            end

            -- Parse: "type data" or just "type"
            local cmdType, cmdData = raw:match("^(%S+)%s*(.*)")
            cmdType = cmdType or raw
            cmdData = cmdData ~= "" and cmdData or nil

            local ok, result = BRE2.SendCommand(cmdType, cmdData)
        end

        sendBtn.MouseButton1Click:Connect(function()
            clickSound(); sendCommand()
        end)
        consoleInput.FocusLost:Connect(function(enterPressed)
            if enterPressed then sendCommand() end
        end)

        -- Pre-built command buttons
        local quickRow = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,30), LayoutOrder=4, Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=quickRow})

        local quickCmds = {
            { label="echo",      cmd="echo ping",           col=C.TEAL  },
            { label="dump_env",  cmd="dump_env",            col=C.PURP  },
            { label="list_svcs", cmd="list_services",       col=C.BLUE  },
            { label="keepalive", cmd="keepalive",           col=C.GREEN },
        }
        for _, qc in ipairs(quickCmds) do
            local qb = mk("TextButton", {
                AutoButtonColor=false,
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Font=Enum.Font.Code, Text=qc.label,
                TextColor3=qc.col, TextSize=9,
                Size=UDim2.new(0,76,0,24), Parent=quickRow})
            addCorner(qb, UDim.new(0,5))
            local qs = qc.cmd
            qb.MouseButton1Click:Connect(function()
                clickSound()
                consoleInput.Text = qs
                sendCommand()
            end)
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- LOG TAB
    -- ══════════════════════════════════════════════════════════════════════════
    local logLines = {}
    local logScroll

    local function setupLog()
        local pg = tabPages2["log"]
        for _, c in ipairs(pg:GetChildren()) do c:Destroy() end

        logScroll = mk("ScrollingFrame", {
            BackgroundColor3=Color3.fromRGB(6,5,10), BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0),
            CanvasSize=UDim2.new(0,0,0,0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollBarThickness=3,
            ScrollBarImageColor3=C.MUTED,
            Parent=pg})
        addCorner(logScroll, UDim.new(0,6))
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            Parent=logScroll})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,1), Parent=logScroll})
    end

    local logLo = 1
    local LOG_COLORS = {
        INFO    = C.TEXT,
        ANOMALY = C.AMBER,
        PRIMITIVE=C.PRIM,
        GADGET  = C.BLUE,
        ACTIVE  = C.ACTIVE,
        CMD     = C.CYAN,
        WARN    = C.ORANGE,
        ERROR   = C.RED,
    }

    local function appendLog(level, msg)
        if not logScroll then return end
        local col = LOG_COLORS[level] or C.MUTED
        local t = os.clock()
        local line = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format("[%7.2f][%-9s] %s", t, level, msg),
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
    -- BRE CALLBACKS
    -- ══════════════════════════════════════════════════════════════════════════
    local function wireCallbacks()
        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 then return end

        BRE2.OnLog = function(level, msg)
            appendLog(level, msg)
        end

        BRE2.OnStateChange = function(newState, oldState)
            -- Update top bar state label
            local col = STATE_COLORS[newState] or C.MUTED
            stateLabel.Text = string.format("STATE: %s", newState)
            stateLabel.TextColor3 = col

            -- Update run button
            if newState == "ACTIVE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.ACTIVE})
                runBtn.Text = "⚡  ACTIVE"
                runBtn.TextColor3 = Color3.fromRGB(8,10,8)
            elseif newState == "IDLE" or newState == "ERROR" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                runBtn.Text = "⚡  Execute BRE"
                runBtn.TextColor3 = C.MUTED
            else
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.PROBE})
                runBtn.Text = "◌  Running..."
                runBtn.TextColor3 = Color3.fromRGB(10,8,4)
            end

            -- Update phase dots
            local phaseOrder = {
                "PROBING","PROBING","PRIMITIVE","GADGET_SCAN",
                "CHAIN_BUILD","CHAIN_FIRE","ACTIVE"
            }
            local stateReached = {
                IDLE=0, PROBING=2, PRIMITIVE=3,
                GADGET_SCAN=4, CHAIN_BUILD=5, CHAIN_FIRE=6, ACTIVE=7
            }
            local current = stateReached[newState] or 0
            for state, dot in pairs(phaseDots) do
                local rank = stateReached[state] or 0
                local done = rank <= current
                local active = state == newState
                if dot.circle then
                    tween(dot.circle, TweenInfo.new(0.2), {
                        BackgroundColor3 = active and C.ACTIVE or
                                           done and C.GREEN or C.DIM})
                end
            end

            -- Progress fill
            local pct = (stateReached[newState] or 0) / 7
            tween(phaseFill, TweenInfo.new(0.4),
                {Size=UDim2.new(math.clamp(pct,0,1),0,1,0)})

            -- Refresh overview
            task.defer(buildOverview)

            appendLog("INFO", string.format("State: %s → %s", oldState, newState))
        end

        BRE2.OnProbeResult = function(probe)
            -- Update stat chips
            local stats = BRE2.GetStats()
            statChips.probes.Text    = tostring(stats.totalProbes)
            statChips.anomalies.Text = tostring(stats.anomalies)
            phaseLabel.Text = string.format("%s  probe #%d", probe.category, probe.index)
        end

        BRE2.OnAnomaly = function(anomaly)
            local stats = BRE2.GetStats()
            statChips.anomalies.Text = tostring(stats.anomalies)
            appendLog("ANOMALY", string.format("[%s] score=%.2f  %s",
                anomaly.category, anomaly.score, (anomaly.reason or ""):sub(1,60)))
            task.defer(function() buildAnomalies() end)
        end

        BRE2.OnPrimitive = function(primitive)
            local stats = BRE2.GetStats()
            statChips.prims.Text = tostring(stats.confirmedPrims)
            appendLog("PRIMITIVE", string.format("CONFIRMED: %s  conf=%.0f%%",
                primitive.id, primitive.confidence*100))
            task.defer(function() buildPrimitives() end)
        end

        BRE2.OnGadget = function(gadget)
            local stats = BRE2.GetStats()
            statChips.gadgets.Text = tostring(stats.gadgetsFound)
            appendLog("GADGET", string.format("[%s] %s  score=%.2f",
                gadget.id, gadget.patternLabel, gadget.score))
            task.defer(function() buildGadgets() end)
        end

        BRE2.OnChainFired = function(result)
            local stats = BRE2.GetStats()
            statChips.chains.Text = tostring(stats.chainsFired)
            appendLog("INFO", string.format("Chain #%d fired — %d links",
                result.chainId, #result.links))
            task.defer(function() buildChain() end)
        end
    end

    -- ══════════════════════════════════════════════════════════════════════════
    -- RUN BUTTON LOGIC
    -- ══════════════════════════════════════════════════════════════════════════
    local breReady = false

    runBtn.MouseButton1Click:Connect(function()
        if not breReady then return end
        clickSound(); pulseClick(runBtn)

        local BRE2 = _G.PC and _G.PC.BRE
        if not BRE2 then
            sendNotif("BRE module not loaded.", "Warning"); return
        end

        local ok, err = BRE2.Run()
        if not ok then
            sendNotif("✗ " .. tostring(err), "Warning")
        else
            sendNotif("⚡ BRE execution initiated", "Success")
            switchTab("overview")
        end
    end)

    resetBtn.MouseButton1Click:Connect(function()
        clickSound()
        local BRE2 = _G.PC and _G.PC.BRE
        if BRE2 then
            BRE2.Reset()
            -- Clear all tabs
            buildOverview()
            buildProbes()
            buildAnomalies()
            buildPrimitives()
            buildGadgets()
            buildChain()
            statChips.probes.Text    = "0"
            statChips.anomalies.Text = "0"
            statChips.prims.Text     = "0"
            statChips.gadgets.Text   = "0"
            statChips.chains.Text    = "0"
            tween(phaseFill, TweenInfo.new(0.3), {Size=UDim2.new(0,0,1,0)})
            phaseLabel.Text = ""
            sendNotif("BRE reset", "Success")
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- BEDROCK WATCHER — enable/disable run button
    -- ══════════════════════════════════════════════════════════════════════════
    task.spawn(function()
        while true do
            task.wait(2)
            local ASE2 = _G.PC and _G.PC.ASE
            if not ASE2 then continue end
            local stats = ASE2.GetStats and ASE2.GetStats()
            local alive = stats and stats.HeartbeatAlive == true
            local BRE2  = _G.PC and _G.PC.BRE
            local idle  = BRE2 and (BRE2.CurrentState == "IDLE" or
                                    BRE2.CurrentState == "ERROR")

            breReady = alive and idle

            if breReady then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.ACTIVE})
                runBtn.TextColor3 = Color3.fromRGB(8,10,8)
                runBtn.Text = "⚡  Execute BRE"
                local sink = stats.ActiveSink or "?"
                stateLabel.Text = string.format(
                    "STATE: %s  ·  SINK: %s  ·  Ready",
                    BRE2 and BRE2.CurrentState or "IDLE",
                    tostring(sink):sub(1,24))
                stateLabel.TextColor3 = C.ACTIVE
            elseif not alive then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                runBtn.TextColor3 = C.MUTED
                if BRE2 and BRE2.CurrentState == "IDLE" then
                    stateLabel.Text = "Awaiting Bedrock confirmation"
                    stateLabel.TextColor3 = C.MUTED
                end
            end
        end
    end)

    -- ══════════════════════════════════════════════════════════════════════════
    -- INIT
    -- ══════════════════════════════════════════════════════════════════════════
    tabBuilders["overview"]   = buildOverview
    tabBuilders["probes"]     = buildProbes
    tabBuilders["anomalies"]  = buildAnomalies
    tabBuilders["primitives"] = buildPrimitives
    tabBuilders["gadgets"]    = buildGadgets
    tabBuilders["chain"]      = buildChain

    wireCallbacks()
    setupConsole()
    setupLog()
    buildOverview()
end
