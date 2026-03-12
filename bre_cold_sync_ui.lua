-- ══════════════════════════════════════════════════════════════════════════════
-- BCS_UI — Cold Re-Sync Interface
-- Self-registering standalone page.
-- ══════════════════════════════════════════════════════════════════════════════

local _U2     = _G.PCU
local pageBCS = _U2.makePage("BCS")

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
        Text="❄  BCS",
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
        pageBCS.Visible = true
        panelTitle.Text = "BCS"
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
    _G.PCU.pageBCS = pageBCS
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
        ICE     = Color3.fromRGB(140,210,255),  -- cold channel color
        COLD    = Color3.fromRGB(80,160,220),
        ABORT   = Color3.fromRGB(220,100,38),
        ERROR   = Color3.fromRGB(215,55,55),
    }

    local STATE_COLORS = {
        IDLE          = C.DIM,
        TUNNEL_SCAN   = C.COLD,
        HANDSHAKE     = C.ICE,
        OVERLAY_PROBE = C.CYAN,
        PTR_LEAK      = C.PURP,
        DONE          = C.GREEN,
        ERROR         = C.ERROR,
    }

    pageBCS.BackgroundColor3 = C.BG

    -- ── Top Bar ───────────────────────────────────────────────────────────────
    local topBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,52), Parent=pageBCS})
    addStroke(topBar, 1, 0.5)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,12), Parent=topBar})

    local titleBlock = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.36,0,1,0), Parent=topBar})
    mk("UIListLayout", {Padding=UDim.new(0,2), Parent=titleBlock})
    mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="❄  Cold-Boot Re-Sync",
        TextColor3=C.ICE, TextSize=14,
        Size=UDim2.new(1,0,0,22),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=titleBlock})
    local stateLabel = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="STATE: IDLE  ·  Awaiting trigger",
        TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(1,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=2, Parent=titleBlock})

    -- Stat chips
    local statsRow = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(0.42,0,1,0), Parent=topBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=statsRow})

    local chips = {}
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

    chips.candidates = makeChip(statsRow, "Candidates", C.COLD)
    chips.fires      = makeChip(statsRow, "Fires",      C.CYAN)
    chips.anomalies  = makeChip(statsRow, "Anomalies",  C.AMBER)
    chips.aborts     = makeChip(statsRow, "Aborts",     C.ABORT)
    chips.leaks      = makeChip(statsRow, "Leaks",      C.PURP)

    local runBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text="❄  Re-Sync",
        TextColor3=C.MUTED, TextSize=12,
        Size=UDim2.new(0,140,0,36), Parent=topBar})
    addCorner(runBtn, UDim.new(0,8))
    addStroke(runBtn, 1, 0.5)

    local resetBtn = mk("TextButton", {
        AutoButtonColor=false,
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="↺",
        TextColor3=C.MUTED, TextSize=14,
        Size=UDim2.new(0,32,0,36), Parent=topBar})
    addCorner(resetBtn, UDim.new(0,8))

    -- ── Step progress strip ───────────────────────────────────────────────────
    local stepStrip = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,52), Size=UDim2.new(1,0,0,32),
        Parent=pageBCS})
    addStroke(stepStrip, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=stepStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=stepStrip})

    local STEPS = {
        {state="TUNNEL_SCAN",   label="Tunnel Scan"},
        {state="HANDSHAKE",     label="→  Handshake"},
        {state="OVERLAY_PROBE", label="→  Overlay Probe"},
        {state="PTR_LEAK",      label="→  Ptr Leak"},
        {state="DONE",          label="→  Done"},
    }
    local stepLbls = {}
    for _, s in ipairs(STEPS) do
        local lbl = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=s.label, TextColor3=C.DIM, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Left, Parent=stepStrip})
        stepLbls[s.state] = lbl
    end

    -- Progress bar
    local progBg = mk("Frame", {
        BackgroundColor3=C.DIM, BorderSizePixel=0,
        Size=UDim2.new(0.28,0,0,6), Parent=stepStrip})
    addCorner(progBg, UDim.new(0,3))
    local progFill = mk("Frame", {
        BackgroundColor3=C.ICE, BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0), Parent=progBg})
    addCorner(progFill, UDim.new(0,3))

    -- ── Channel info strip ────────────────────────────────────────────────────
    local chanStrip = mk("Frame", {
        BackgroundColor3=C.CARD, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,84), Size=UDim2.new(1,0,0,22),
        Parent=pageBCS})
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
        PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=chanStrip})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,20), Parent=chanStrip})

    local function chanField(label, col)
        local f = mk("Frame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=chanStrip})
        mk("UIListLayout", {
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,5), Parent=f})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=label, TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=f})
        local val = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="—", TextColor3=col, TextSize=9,
            Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X,
            Parent=f})
        return val
    end

    local chanRemote  = chanField("Cold Remote:", C.ICE)
    local chanAnchor  = chanField("New Anchor:",  C.PURP)
    local chanCeiling = chanField("Ceiling:",     C.ABORT)
    chanCeiling.Text = "150ms"

    -- ── Tab bar ───────────────────────────────────────────────────────────────
    local CONTENT_TOP = 106
    local tabBar = mk("Frame", {
        BackgroundColor3=C.SURFACE, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP), Size=UDim2.new(1,0,0,34),
        Parent=pageBCS})
    addStroke(tabBar, 1, 0.6)
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar})

    local TABS = {
        {key="overview",  label="Overview"  },
        {key="candidates",label="Candidates"},
        {key="overlays",  label="Overlays"  },
        {key="leaks",     label="Leaks"     },
        {key="log",       label="Log"       },
    }

    local tabBtns   = {}
    local tabPages2 = {}
    local activeTab = nil
    local tabBuilders = {}

    local contentArea = mk("Frame", {
        BackgroundColor3=C.BG, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,CONTENT_TOP+34),
        Size=UDim2.new(1,0,1,-(CONTENT_TOP+34)),
        ClipsDescendants=true, Parent=pageBCS})

    local function makeTabPage2()
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
            Size=UDim2.new(0,84,0,26), Parent=tabBar})
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
                TextColor3       = on and C.ICE     or C.MUTED,
            })
            local st = b:FindFirstChildOfClass("UIStroke")
            if st then
                tween(st, TweenInfo.new(0.1),
                    {Color = on and C.ICE or C.BORDER})
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

    -- ── Shared helpers ────────────────────────────────────────────────────────
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

    -- ── Overview tab ──────────────────────────────────────────────────────────
    local function buildOverview()
        local pg = tabPages2["overview"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 then return end

        local stats   = BCS2.GetStats()
        local stateCol= STATE_COLORS[stats.state] or C.MUTED
        local lo = 1

        -- State banner
        local banner = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(10,8,16), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,52), LayoutOrder=lo, Parent=pg})
        addCorner(banner, UDim.new(0,8))
        addStroke(banner, 2, 0)
        if banner:FindFirstChildOfClass("UIStroke") then
            banner:FindFirstChildOfClass("UIStroke").Color = stateCol
        end
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,16), PaddingTop=UDim.new(0,8),
            PaddingBottom=UDim.new(0,8), Parent=banner})
        mk("UIListLayout", {Padding=UDim.new(0,4), Parent=banner})
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=stats.state, TextColor3=stateCol, TextSize=16,
            Size=UDim2.new(1,0,0,22),
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=1, Parent=banner})

        local stateDescs = {
            IDLE          = "Awaiting trigger. Run after guard page collapse.",
            TUNNEL_SCAN   = "Step 1: Scanning STS topology for untouched cold remotes.",
            HANDSHAKE     = "Step 1: Re-establishing Bedrock handshake on cold remote.",
            OVERLAY_PROBE = "Step 2: Partial overlay probing with 150ms latency ceiling.",
            PTR_LEAK      = "Step 3: Extracting new code pointer from overlay anomalies.",
            DONE          = "Re-Sync complete. Cold channel active. BGH anchor updated.",
            ERROR         = "Re-Sync failed. Check Log tab. Reset and retry.",
        }
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=stateDescs[stats.state] or "",
            TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=2, Parent=banner})

        -- Step progress
        secHdr(pg, "Step Progress", C.ICE, lo); lo = lo + 1

        local STEP_DEFS = {
            {n=1, label="Tunnel Re-Sync",    desc="Find cold remote + Bedrock handshake",
             done = stats.coldRemote ~= nil},
            {n=2, label="Overlay Probing",   desc="Partial type-confusion probes at 150ms ceiling",
             done = stats.overlayFires > 0},
            {n=3, label="Pointer Leak",      desc="Extract and confirm new code anchor",
             done = stats.confirmed},
        }

        local stepBlock = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=pg})
        addCorner(stepBlock, UDim.new(0,7))
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8),
            Parent=stepBlock})
        mk("UIListLayout", {Padding=UDim.new(0,6), Parent=stepBlock})

        for i, step in ipairs(STEP_DEFS) do
            local row = mk("Frame", {
                BackgroundColor3=step.done and Color3.fromRGB(10,18,14) or C.CARD,
                BorderSizePixel=0,
                Size=UDim2.new(1,0,0,36), LayoutOrder=i, Parent=stepBlock})
            addCorner(row, UDim.new(0,5))
            if step.done then
                addStroke(row, 1, 0.5)
                if row:FindFirstChildOfClass("UIStroke") then
                    row:FindFirstChildOfClass("UIStroke").Color = C.GREEN
                end
            end
            local strip = mk("Frame", {
                BackgroundColor3=step.done and C.GREEN or C.DIM,
                BorderSizePixel=0, Size=UDim2.new(0,3,1,0), Parent=row})
            addCorner(strip, UDim.new(0,3))
            local inner = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Position=UDim2.new(0,10,0,0), Size=UDim2.new(1,-70,1,0),
                Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=inner})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Step %d  —  %s", step.n, step.label),
                TextColor3=step.done and C.GREEN or C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=inner})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=step.desc, TextColor3=C.DIM, TextSize=9,
                Size=UDim2.new(1,0,0,14),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=inner})
            local chip = mk("TextLabel", {
                BackgroundColor3=step.done and Color3.fromRGB(12,22,16) or C.DIM,
                BorderSizePixel=0, Font=Enum.Font.GothamBold,
                Text=step.done and "✓ DONE" or "PENDING",
                TextColor3=step.done and C.GREEN or C.MUTED, TextSize=8,
                Size=UDim2.new(0,56,0,18), TextXAlignment=Enum.TextXAlignment.Center,
                Parent=row})
            addCorner(chip, UDim.new(0,4))
            chip.Position = UDim2.new(1,-62,0.5,-9)
        end

        -- Stats
        secHdr(pg, "Runtime Stats", C.CYAN, lo); lo = lo + 1
        local statsCard = mk("Frame", {
            BackgroundColor3=C.CARD, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=lo, Parent=pg})
        addCorner(statsCard, UDim.new(0,7))
        lo = lo + 1
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12),
            PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=statsCard})
        mk("UIListLayout", {Padding=UDim.new(0,3), Parent=statsCard})

        local statsData = {
            {"Cold Remote",    stats.coldRemote or "—"},
            {"New Anchor",     stats.newAnchor and
                               string.format("0x%X", stats.newAnchor) or "—"},
            {"Remotes Scanned",tostring(stats.remotesScanned)},
            {"Candidates Tried",tostring(stats.candidatesTried)},
            {"Overlay Fires",  tostring(stats.overlayFires)},
            {"Overlay Anomalies",tostring(stats.overlayAnomalies)},
            {"Latency Aborts", tostring(stats.latencyAborts)},
            {"Leak Attempts",  tostring(stats.leakAttempts)},
            {"Confirmed",      tostring(stats.confirmed)},
        }

        for i, sd in ipairs(statsData) do
            local r = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,14), LayoutOrder=i, Parent=statsCard})
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=r})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=sd[1], TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(0,150,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=r})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=sd[2], TextColor3=C.TEXT, TextSize=9,
                Size=UDim2.new(1,-158,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=r})
        end
    end

    -- ── Overlays tab ──────────────────────────────────────────────────────────
    local function buildOverlays()
        local pg = tabPages2["overlays"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 or #BCS2.Anomalies == 0 then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No overlay anomalies yet.",
                TextColor3=C.MUTED, TextSize=11,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
            return
        end

        local lo = 1
        for _, a in ipairs(BCS2.Anomalies) do
            local col = a.aScore >= 0.50 and C.AMBER or C.CYAN
            local card = mk("Frame", {
                BackgroundColor3=C.CARD, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.5)
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
                Text=string.format("[%.2f]  %s  #%d",
                    a.aScore, a.mutation or "?", a.index or 0),
                TextColor3=col, TextSize=11,
                Size=UDim2.new(1,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=a.aReason or "",
                TextColor3=C.TEXT, TextSize=9, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=body})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("latency=%.0fms", (a.latency or 0)*1000),
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,12),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=3, Parent=body})
        end
    end

    -- ── Leaks tab ─────────────────────────────────────────────────────────────
    local function buildLeaks()
        local pg = tabPages2["leaks"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 then return end
        local stats = BCS2.GetStats()
        local lo = 1

        if stats.newAnchor then
            -- Confirmed anchor card
            local card = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(10,18,12), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,8))
            addStroke(card, 2, 0.1)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = C.GREEN
            end
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,16), PaddingRight=UDim.new(0,16),
                PaddingTop=UDim.new(0,12), PaddingBottom=UDim.new(0,12),
                Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=card})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text="✓  New Anchor Confirmed",
                TextColor3=C.GREEN, TextSize=13,
                Size=UDim2.new(1,0,0,18),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=card})

            local addrLabel = mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("0x%X", stats.newAnchor),
                TextColor3=C.PURP, TextSize=14,
                Size=UDim2.new(1,0,0,20),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=card})

            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="BGH anchor updated. Start new Gadget Hunt from BGH page.",
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,14),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=3, Parent=card})

            -- Copy button
            local copyBtn = mk("TextButton", {
                AutoButtonColor=false,
                BackgroundColor3=C.DIM, BorderSizePixel=0,
                Font=Enum.Font.Code, Text="⎘  Copy Address",
                TextColor3=C.GREEN, TextSize=10,
                Size=UDim2.new(0,120,0,24), LayoutOrder=4, Parent=card})
            addCorner(copyBtn, UDim.new(0,5))
            local capturedAnchor = stats.newAnchor
            copyBtn.MouseButton1Click:Connect(function()
                clickSound()
                pcall(function()
                    game:GetService("GuiService"):SetClipboard(
                        string.format("0x%X", capturedAnchor))
                end)
                copyBtn.Text = "✓ Copied"
                task.delay(1.5, function() copyBtn.Text = "⎘  Copy Address" end)
            end)
        else
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="No confirmed pointer yet. Pointer leak requires successful overlay anomalies.",
                TextColor3=C.MUTED, TextSize=11, TextWrapped=true,
                Size=UDim2.new(1,0,0,40), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Center, Parent=pg})
        end
    end

    -- ── Candidates tab ────────────────────────────────────────────────────────
    local function buildCandidates()
        local pg = tabPages2["candidates"]
        for _, c in ipairs(pg:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 then return end
        local stats = BCS2.GetStats()
        local lo = 1

        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=string.format(
                "%d remotes scanned  ·  %d candidates tried  ·  Cold remote: %s",
                stats.remotesScanned, stats.candidatesTried,
                stats.coldRemote or "—"),
            TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            LayoutOrder=lo, Parent=pg})
        lo = lo + 1

        if stats.coldRemote then
            local card = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(10,14,20), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,48), LayoutOrder=lo, Parent=pg})
            addCorner(card, UDim.new(0,7))
            addStroke(card, 1, 0.3)
            if card:FindFirstChildOfClass("UIStroke") then
                card:FindFirstChildOfClass("UIStroke").Color = C.ICE
            end
            lo = lo + 1
            mk("UIPadding", {
                PaddingLeft=UDim.new(0,14), PaddingTop=UDim.new(0,8),
                Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text="✓  " .. stats.coldRemote,
                TextColor3=C.ICE, TextSize=12,
                Size=UDim2.new(1,0,0,18),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=1, Parent=card})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="Active cold channel  ·  Bedrock handshake confirmed",
                TextColor3=C.MUTED, TextSize=9,
                Size=UDim2.new(1,0,0,14),
                TextXAlignment=Enum.TextXAlignment.Left,
                LayoutOrder=2, Parent=card})
        end
    end

    -- ── Log tab ───────────────────────────────────────────────────────────────
    local logScroll
    local logLo = 1

    local LOG_COLORS = {
        INFO    = Color3.fromRGB(160,156,190),
        ANOMALY = Color3.fromRGB(220,165,38),
        ABORT   = Color3.fromRGB(210,100,38),
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

    -- ── Callbacks ─────────────────────────────────────────────────────────────
    local function wireCallbacks()
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 then return end

        BCS2.OnLog = function(level, msg)
            appendLog(level, msg)
        end

        BCS2.OnStateChange = function(newState, oldState)
            local col = STATE_COLORS[newState] or C.MUTED
            stateLabel.Text  = "STATE: " .. newState
            stateLabel.TextColor3 = col

            -- Phase label colors
            local stateRank = {
                IDLE=0, TUNNEL_SCAN=1, HANDSHAKE=2,
                OVERLAY_PROBE=3, PTR_LEAK=4, DONE=5
            }
            local cur = stateRank[newState] or 0
            for state, lbl in pairs(stepLbls) do
                local rank = stateRank[state] or 0
                tween(lbl, TweenInfo.new(0.2), {
                    TextColor3 = (state==newState) and col or
                                 (rank < cur) and C.GREEN or C.DIM})
            end

            -- Progress fill
            local pct = (stateRank[newState] or 0) / 5
            tween(progFill, TweenInfo.new(0.4),
                {Size=UDim2.new(math.clamp(pct,0,1),0,1,0)})

            -- Run button
            if newState == "DONE" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.GREEN})
                runBtn.Text = "❄  Done"
                runBtn.TextColor3 = Color3.fromRGB(6,8,6)
            elseif newState == "IDLE" or newState == "ERROR" then
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
                runBtn.Text = "❄  Re-Sync"
                runBtn.TextColor3 = C.MUTED
            else
                tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.COLD})
                runBtn.Text = "◌  Running..."
                runBtn.TextColor3 = Color3.fromRGB(4,6,8)
            end

            task.defer(buildOverview)
        end

        BCS2.OnTunnelFound = function(remoteName, coldScore)
            chanRemote.Text = remoteName .. string.format("  (%.2f)", coldScore)
            chips.candidates.Text = tostring(BCS2.GetStats().candidatesTried)
            appendLog("INFO", string.format(
                "Cold tunnel: %s  score=%.2f", remoteName, coldScore))
            task.defer(buildCandidates)
        end

        BCS2.OnAnomaly = function(anomaly)
            local stats = BCS2.GetStats()
            chips.fires.Text     = tostring(stats.overlayFires)
            chips.anomalies.Text = tostring(stats.overlayAnomalies)
            chips.aborts.Text    = tostring(stats.latencyAborts)
            appendLog("ANOMALY", string.format(
                "[%s #%d] score=%.2f  %.0fms",
                anomaly.mutation or "?", anomaly.index or 0,
                anomaly.aScore, (anomaly.latency or 0)*1000))
        end

        BCS2.OnAnchorLeaked = function(address)
            local addrStr = string.format("0x%X", address)
            chanAnchor.Text = addrStr
            chips.leaks.Text = "1"
            appendLog("INFO", "New anchor confirmed: " .. addrStr)
            sendNotif("❄ Anchor leaked: " .. addrStr, "Success")
            task.defer(buildLeaks)
            task.defer(buildOverview)
        end

        BCS2.OnDone = function(result)
            if result.confirmed then
                tween(progFill, TweenInfo.new(0.5), {Size=UDim2.new(1,0,1,0)})
            end
            task.defer(buildOverview)
            task.defer(buildLeaks)
            task.defer(buildCandidates)
        end
    end

    -- ── Buttons ───────────────────────────────────────────────────────────────
    runBtn.MouseButton1Click:Connect(function()
        clickSound()
        local BCS2 = _G.PC and _G.PC.BCS
        if not BCS2 then
            sendNotif("BCS module not loaded.", "Warning"); return
        end
        local ok, err = BCS2.Run()
        if not ok then
            sendNotif("✗ " .. tostring(err), "Warning")
        else
            sendNotif("❄ Cold Re-Sync started", "Success")
            switchTab("overview")
        end
    end)

    resetBtn.MouseButton1Click:Connect(function()
        clickSound()
        local BCS2 = _G.PC and _G.PC.BCS
        if BCS2 then
            BCS2.Reset()
            chips.candidates.Text = "0"
            chips.fires.Text      = "0"
            chips.anomalies.Text  = "0"
            chips.aborts.Text     = "0"
            chips.leaks.Text      = "0"
            chanRemote.Text  = "—"
            chanAnchor.Text  = "—"
            tween(progFill, TweenInfo.new(0.3), {Size=UDim2.new(0,0,1,0)})
            sendNotif("BCS reset", "Success")
        end
    end)

    -- Enable run button always (BCS can run even after BRE collapse)
    tween(runBtn, TweenInfo.new(0.3), {BackgroundColor3=C.ICE})
    runBtn.TextColor3 = Color3.fromRGB(4,6,8)

    -- ── Init ──────────────────────────────────────────────────────────────────
    tabBuilders["overview"]   = buildOverview
    tabBuilders["candidates"] = buildCandidates
    tabBuilders["overlays"]   = buildOverlays
    tabBuilders["leaks"]      = buildLeaks

    wireCallbacks()
    setupLog()
    buildOverview()
    switchTab("overview")
end
