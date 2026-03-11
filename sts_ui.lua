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
        0.6,
        0.0)

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
    -- VIEW SOURCE OVERLAY
    -- ══════════════════════════════════════════════════════════════════════════
    local viewerOverlay = mk("Frame", {
        BackgroundColor3=Color3.fromRGB(8,7,12), BorderSizePixel=0,
        Size=UDim2.new(1,0,1,0), ZIndex=20,
        Visible=false, Parent=pageSTS})
    addStroke(viewerOverlay, 1, 0.3)

    local vHeader = mk("Frame", {
        BackgroundColor3=Color3.fromRGB(14,13,20), BorderSizePixel=0,
        Size=UDim2.new(1,0,0,40), ZIndex=20, Parent=viewerOverlay})
    addStroke(vHeader, 1, 0.5)
    mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,10),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=vHeader})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,8), Parent=vHeader})

    local vIcon = mk("TextLabel", {
        BackgroundColor3=Color3.fromRGB(18,14,28), BorderSizePixel=0,
        Font=Enum.Font.Code, Text="◈ SRC", TextColor3=C.PURP, TextSize=10,
        Size=UDim2.new(0,52,0,24), TextXAlignment=Enum.TextXAlignment.Center,
        ZIndex=20, Parent=vHeader})
    addCorner(vIcon, UDim.new(0,4))

    local vTitle = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text="script.lua", TextColor3=C.TEXT, TextSize=13,
        Size=UDim2.new(0.5,0,1,0),
        TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=vHeader})

    local vMeta = mk("TextLabel", {
        BackgroundTransparency=1, Font=Enum.Font.Code,
        Text="", TextColor3=C.MUTED, TextSize=9,
        Size=UDim2.new(0.3,0,1,0),
        TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=vHeader})

    local vCopyBtn = mk("TextButton", {
        AutoButtonColor=false, BackgroundColor3=C.DIM, BorderSizePixel=0,
        Font=Enum.Font.GothamMedium, Text="Copy", TextColor3=C.MUTED, TextSize=10,
        Size=UDim2.new(0,64,0,26), ZIndex=20, Parent=vHeader})
    addCorner(vCopyBtn, UDim.new(0,6))

    local vCloseBtn = mk("TextButton", {
        AutoButtonColor=false, BackgroundColor3=Color3.fromRGB(40,16,16),
        BorderSizePixel=0, Font=Enum.Font.GothamBold,
        Text="X", TextColor3=C.RED, TextSize=12,
        Size=UDim2.new(0,32,0,26), ZIndex=20, Parent=vHeader})
    addCorner(vCloseBtn, UDim.new(0,6))

    local vBody = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,40), Size=UDim2.new(1,0,1,-40),
        ZIndex=20, Parent=viewerOverlay})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Parent=vBody})

    local vSourcePane = mk("Frame", {
        BackgroundColor3=Color3.fromRGB(10,9,14), BorderSizePixel=0,
        Size=UDim2.new(0.68,0,1,0), ZIndex=20, Parent=vBody})
    addStroke(vSourcePane, 1, 0.6)

    local vScroll = mk("ScrollingFrame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(1,0,1,0),
        CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=3, ScrollingDirection=Enum.ScrollingDirection.Y,
        ScrollBarImageColor3=C.MUTED, ZIndex=20, Parent=vSourcePane})
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
        PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=vScroll})
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,0), Parent=vScroll})

    local vAnalysisPane = mk("ScrollingFrame", {
        BackgroundColor3=Color3.fromRGB(13,12,18), BorderSizePixel=0,
        Size=UDim2.new(0.32,0,1,0),
        CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=3, ScrollingDirection=Enum.ScrollingDirection.Y,
        ScrollBarImageColor3=C.MUTED, ZIndex=20, Parent=vBody})
    mk("UIPadding", {
        PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
        PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=vAnalysisPane})
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,4), Parent=vAnalysisPane})

    -- ── Lightweight per-line colorizer ────────────────────────────────────────
    local LUA_KEYWORDS = {
        ["local"]=true,["function"]=true,["end"]=true,["if"]=true,
        ["then"]=true,["else"]=true,["elseif"]=true,["for"]=true,
        ["while"]=true,["do"]=true,["return"]=true,["not"]=true,
        ["and"]=true,["or"]=true,["true"]=true,["false"]=true,
        ["nil"]=true,["repeat"]=true,["until"]=true,["in"]=true,
        ["break"]=true,["continue"]=true,
    }
    local function lineColor(line)
        if line:match("^%s*%-%-") then return C.DIM end
        if line:match([=[^%s*[%w_]+%s*=?%s*["']]=]) then return C.GREEN end
        if line:match("^%s*local%s+function") or line:match("^%s*function%s+") then return C.PURP end
        if line:match("^%s*return%s") then return C.AMBER end
        local first = line:match("^%s*([%w_]+)")
        if first and LUA_KEYWORDS[first] then return C.BLUE end
        if line:match(":FireServer") or line:match(":InvokeServer") or
           line:match(":FireClient") or line:match(":FireAllClients") then return C.TEAL end
        return C.TEXT
    end

    -- ── Analysis pane builder ─────────────────────────────────────────────────
    local function buildAnalysisPane(analysis)
        for _, c in ipairs(vAnalysisPane:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        if not analysis or analysis.unavailable or analysis.empty then
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="Source not available in this environment.",
                TextColor3=C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,24), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20,
                Parent=vAnalysisPane})
            return
        end
        local alo = 1
        local function aSection(title, col)
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=title, TextColor3=col or C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,18), LayoutOrder=alo, ZIndex=20,
                TextXAlignment=Enum.TextXAlignment.Left, Parent=vAnalysisPane})
            alo = alo + 1
        end
        local function aEntry(text, col)
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=text, TextColor3=col or C.MUTED, TextSize=9,
                TextWrapped=true, Size=UDim2.new(1,0,0,0),
                AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=alo, ZIndex=20,
                TextXAlignment=Enum.TextXAlignment.Left, Parent=vAnalysisPane})
            alo = alo + 1
        end

        aEntry(string.format("%d lines  %d fn  %d bytes",
            analysis.lineCount or 0, #(analysis.functions or {}),
            analysis.byteCount or 0), C.MUTED)

        local flags = {}
        if analysis.usesPlayerLocal then table.insert(flags, "LocalPlayer") end
        if analysis.usesTween       then table.insert(flags, "Tween") end
        if analysis.usesRunService  then table.insert(flags, "RunService") end
        if analysis.usesPhysics     then table.insert(flags, "Physics") end
        if #flags > 0 then aEntry("flags: " .. table.concat(flags, "  "), C.CYAN) end

        if analysis.functions and #analysis.functions > 0 then
            aSection("Functions", C.PURP)
            for _, fn in ipairs(analysis.functions) do
                aEntry(string.format("  %s(%s)", fn.name, fn.args or ""), C.TEXT)
            end
        end
        if analysis.services and #analysis.services > 0 then
            aSection("Services", C.BLUE)
            for _, s in ipairs(analysis.services) do aEntry("  "..s, C.TEXT) end
        end
        if analysis.remoteCallTypes and #analysis.remoteCallTypes > 0 then
            aSection("Remote Calls", C.TEAL)
            aEntry("  "..table.concat(analysis.remoteCallTypes,"  "), C.TEAL)
        end
        if analysis.waitForChildRefs and #analysis.waitForChildRefs > 0 then
            aSection("WaitForChild", C.CYAN)
            for _, r in ipairs(analysis.waitForChildRefs) do aEntry("  "..r, C.TEXT) end
        end
        if analysis.findFirstChildRefs and #analysis.findFirstChildRefs > 0 then
            aSection("FindFirstChild", C.CYAN)
            for _, r in ipairs(analysis.findFirstChildRefs) do aEntry("  "..r, C.TEXT) end
        end
        if analysis.connections and #analysis.connections > 0 then
            aSection("Connections", C.AMBER)
            aEntry("  "..table.concat(analysis.connections,"  "):sub(1,200), C.AMBER)
        end
        if analysis.datastoreRefs and #analysis.datastoreRefs > 0 then
            aSection("DataStores", C.GOLD)
            for _, ds in ipairs(analysis.datastoreRefs) do aEntry("  "..ds, C.TEXT) end
            if analysis.datastoreKeys and #analysis.datastoreKeys > 0 then
                aEntry("  keys: "..table.concat(analysis.datastoreKeys,", "):sub(1,120), C.MUTED)
            end
        end
        if analysis.instanceNews and #analysis.instanceNews > 0 then
            aSection("Instance.new", C.GREEN)
            aEntry("  "..table.concat(analysis.instanceNews,"  "):sub(1,200), C.TEXT)
        end
        if analysis.httpRefs and #analysis.httpRefs > 0 then
            aSection("HTTP", C.ORANGE)
            for _, h in ipairs(analysis.httpRefs) do aEntry("  "..h:sub(1,80), C.TEXT) end
        end
        if analysis.requireChain and #analysis.requireChain > 0 then
            aSection("require()", C.PURP)
            for _, r in ipairs(analysis.requireChain) do aEntry("  "..r, C.TEXT) end
        end
        if analysis.globalWrites and #analysis.globalWrites > 0 then
            aSection("_G Writes", C.RED)
            aEntry("  "..table.concat(analysis.globalWrites,"  "):sub(1,120), C.TEXT)
        end
        if analysis.suspiciousKeys and #analysis.suspiciousKeys > 0 then
            aSection("Suspicious", C.RED)
            for _, s in ipairs(analysis.suspiciousKeys) do aEntry("  "..s, C.RED) end
        end
    end

    -- ── Source renderer ───────────────────────────────────────────────────────
    local _viewerCurrentSource = nil

    local function renderSource(source, scriptName, analysis)
        for _, c in ipairs(vScroll:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        vTitle.Text = scriptName
        buildAnalysisPane(analysis)

        if not source or #source == 0 then
            vMeta.Text = "[source unavailable]"
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="Source not exposed in this executor environment.",
                TextColor3=C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,24), LayoutOrder=1,
                TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=vScroll})
            return
        end

        local srcLines = {}
        local idx2 = 1
        while idx2 <= #source do
            local nl = source:find("\n", idx2, true)
            if nl then
                table.insert(srcLines, source:sub(idx2, nl-1))
                idx2 = nl + 1
            else
                table.insert(srcLines, source:sub(idx2))
                break
            end
        end

        vMeta.Text = string.format("%d lines  %d bytes", #srcLines, #source)

        local MAX_RENDERED = 1200
        local lo = 1
        local limit = math.min(#srcLines, MAX_RENDERED)
        for i = 1, limit do
            local line = srcLines[i]
            local row = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,13), LayoutOrder=lo, ZIndex=20,
                Parent=vScroll})
            lo = lo + 1
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%4d", i),
                TextColor3=C.DIM, TextSize=9,
                Size=UDim2.new(0,34,1,0),
                TextXAlignment=Enum.TextXAlignment.Right, ZIndex=20, Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=" "..line:sub(1,120),
                TextColor3=lineColor(line), TextSize=9,
                Size=UDim2.new(1,-38,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=row})
        end
        if #srcLines > MAX_RENDERED then
            local note = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,18), LayoutOrder=lo, ZIndex=20, Parent=vScroll})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("... %d more lines (copy for full)", #srcLines - MAX_RENDERED),
                TextColor3=C.AMBER, TextSize=9,
                Size=UDim2.new(1,0,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=note})
        end
    end

    local function openViewer(scriptName, source, analysis)
        _viewerCurrentSource = source
        renderSource(source, scriptName, analysis)
        viewerOverlay.Visible = true
    end

    local function closeViewer()
        viewerOverlay.Visible = false
        _viewerCurrentSource = nil
    end

    vCloseBtn.MouseButton1Click:Connect(function()
        clickSound(); closeViewer()
    end)

    vCopyBtn.MouseButton1Click:Connect(function()
        clickSound()
        if _viewerCurrentSource and #_viewerCurrentSource > 0 then
            local ok = pcall(function()
                game:GetService("GuiService"):SetClipboard(_viewerCurrentSource)
            end)
            vCopyBtn.Text = ok and "OK" or "Fail"
            vCopyBtn.TextColor3 = ok and C.GREEN or C.RED
            task.delay(1.8, function()
                vCopyBtn.Text = "Copy"
                vCopyBtn.TextColor3 = C.MUTED
            end)
        end
    end)

    local function triggerViewSource(scriptName, source, analysis)
        openViewer(scriptName, source, analysis)
    end

    -- ── Intel viewer for remotes ──────────────────────────────────────────────
    -- Builds a rich text dump of all pipeline intel and renders it in the
    -- source pane as plain text, with the analysis pane showing live stats.

    local function buildIntelText(entry)
        local lines = {}
        local function ln(text) table.insert(lines, text or "") end

        ln("══ Remote Intel Report ══")
        ln(string.format("Name      : %s", entry.name))
        ln(string.format("Class     : %s", entry.className))
        ln(string.format("Path      : %s", entry.path))
        ln(string.format("Service   : %s", entry.service))
        ln(string.format("IntelScore: %.4f", entry.intelScore or 0))
        ln("")

        -- RSM
        if entry.rsmSig then
            local r = entry.rsmSig
            ln("── RSM Signature ──")
            ln(string.format("  FireCount   : %d", r.fireCount or 0))
            ln(string.format("  SuccessRate : %.1f%%", (r.successRate or 0)*100))
            ln(string.format("  ArgCount    : %d", r.argCount or 0))
            if r.lastSeen then
                ln(string.format("  LastSeen    : %s", tostring(r.lastSeen)))
            end
            ln("")
        else
            ln("── RSM Signature ──")
            ln("  No RSM data — remote not observed through pipeline")
            ln("")
        end

        -- SBI
        if entry.sbiConf then
            ln("── SBI Confidence ──")
            ln(string.format("  Confidence  : %.1f%%", entry.sbiConf*100))
            -- Confidence tier label
            local tier = entry.sbiConf >= 0.85 and "HIGH"
                      or entry.sbiConf >= 0.60 and "MEDIUM"
                      or entry.sbiConf >= 0.35 and "LOW"
                      or "VERY LOW"
            ln(string.format("  Tier        : %s", tier))
            ln("")
        else
            ln("── SBI Confidence ──")
            ln("  No SBI data")
            ln("")
        end

        -- CDG edges
        if entry.cdgEdges and #entry.cdgEdges > 0 then
            ln("── CDG Causal Edges ──")
            for i, e in ipairs(entry.cdgEdges) do
                ln(string.format("  [%d] antecedent : %s", i, e.ante or "?"))
                ln(string.format("      confidence  : %.4f", e.conf or 0))
                ln(string.format("      co-fires    : %d", e.coFired or 0))
            end
            ln("")
        else
            ln("── CDG Causal Edges ──")
            ln("  No CDG edges recorded")
            ln("")
        end

        -- Bedrock pair
        if entry.bedrockPair then
            local bp = entry.bedrockPair
            ln("── Bedrock Pair ──")
            ln(string.format("  Sink Remote     : %s", bp.sink or "?"))
            ln(string.format("  Feedback Remote : %s", bp.feedback or "?"))
            ln(string.format("  Origin          : %s", bp.origin or "?"))
            ln(string.format("  Confidence      : %.1f%%", (bp.conf or 0)*100))
            ln("")
        else
            ln("── Bedrock Pair ──")
            ln("  Not part of a confirmed Bedrock pair")
            ln("")
        end

        -- PR record
        if entry.prRecord then
            local p = entry.prRecord
            ln("── PR Record ──")
            ln(string.format("  Direction  : %s", p.direction or "?"))
            ln(string.format("  FireCount  : %d", p.fireCount or 0))
            if p.lastArgs then
                ln(string.format("  Last Args  : %s", tostring(p.lastArgs):sub(1,80)))
            end
            ln("")
        else
            ln("── PR Record ──")
            ln("  No PR record")
            ln("")
        end

        ln("══ End of Report ══")
        return table.concat(lines, "\n")
    end

    local function buildIntelAnalysisPane(entry)
        for _, c in ipairs(vAnalysisPane:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local alo = 1
        local function aSection(title, col)
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=title, TextColor3=col or C.MUTED, TextSize=10,
                Size=UDim2.new(1,0,0,18), LayoutOrder=alo, ZIndex=20,
                TextXAlignment=Enum.TextXAlignment.Left, Parent=vAnalysisPane})
            alo = alo + 1
        end
        local function aEntry(text, col)
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=text, TextColor3=col or C.MUTED, TextSize=9,
                TextWrapped=true, Size=UDim2.new(1,0,0,0),
                AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=alo, ZIndex=20,
                TextXAlignment=Enum.TextXAlignment.Left, Parent=vAnalysisPane})
            alo = alo + 1
        end

        -- Intel score bar
        local score = entry.intelScore or 0
        aSection("Intel Score", C.TEAL)
        aEntry(string.format("  %.0f / 100", score * 100),
            score >= 0.7 and C.GREEN or score >= 0.4 and C.AMBER or C.RED)

        -- Class chip
        aSection("Class", entry.className == "RemoteFunction" and C.CYAN or C.TEAL)
        aEntry("  " .. entry.className,
            entry.className == "RemoteFunction" and C.CYAN or C.TEAL)

        -- RSM
        if entry.rsmSig then
            aSection("RSM", C.CYAN)
            aEntry(string.format("  %d fires  %.0f%% success  %d args",
                entry.rsmSig.fireCount or 0,
                (entry.rsmSig.successRate or 0)*100,
                entry.rsmSig.argCount or 0), C.TEXT)
        end

        -- SBI
        if entry.sbiConf then
            aSection("SBI", C.PURP)
            local tier = entry.sbiConf >= 0.85 and "HIGH"
                      or entry.sbiConf >= 0.60 and "MEDIUM"
                      or entry.sbiConf >= 0.35 and "LOW" or "VERY LOW"
            local tierCol = entry.sbiConf >= 0.85 and C.GREEN
                         or entry.sbiConf >= 0.60 and C.TEAL
                         or entry.sbiConf >= 0.35 and C.AMBER or C.RED
            aEntry(string.format("  %.0f%%  %s", entry.sbiConf*100, tier), tierCol)
        end

        -- CDG
        if entry.cdgEdges and #entry.cdgEdges > 0 then
            aSection(string.format("CDG  (%d edges)", #entry.cdgEdges), C.AMBER)
            for _, e in ipairs(entry.cdgEdges) do
                aEntry(string.format("  %s  %.2f", (e.ante or "?"):sub(1,22), e.conf or 0), C.TEXT)
            end
        end

        -- Bedrock
        if entry.bedrockPair then
            aSection("Bedrock Pair", C.GREEN)
            aEntry("  " .. (entry.bedrockPair.sink or "?"), C.GREEN)
            aEntry("  fb: " .. (entry.bedrockPair.feedback or "?"), C.MUTED)
            aEntry("  " .. (entry.bedrockPair.origin or "?"), C.MUTED)
        end

        -- PR
        if entry.prRecord then
            aSection("PR Record", C.BLUE)
            aEntry("  " .. (entry.prRecord.direction or "?"), C.TEXT)
            aEntry(string.format("  %d fires", entry.prRecord.fireCount or 0), C.MUTED)
        end

        -- Path
        aSection("Path", C.DIM)
        aEntry("  " .. entry.path, C.MUTED)
    end

    local function triggerViewIntel(entry)
        -- Build the intel text and render it in the source pane as plain text
        local intelText = buildIntelText(entry)
        _viewerCurrentSource = intelText

        -- Clear source pane
        for _, c in ipairs(vScroll:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end

        vTitle.Text = entry.name .. "  —  Intel"
        vMeta.Text = entry.className .. "  ·  " .. entry.service

        -- Render intel text line by line (re-uses same line renderer)
        local intelLines = {}
        local idx2 = 1
        while idx2 <= #intelText do
            local nl = intelText:find("\n", idx2, true)
            if nl then
                table.insert(intelLines, intelText:sub(idx2, nl-1))
                idx2 = nl + 1
            else
                table.insert(intelLines, intelText:sub(idx2))
                break
            end
        end

        -- Color logic for intel lines
        local function intelLineColor(line)
            if line:match("^══") then return C.TEAL end
            if line:match("^──") then return C.PURP end
            if line:match("BEDROCK") or line:match("Bedrock") then return C.GREEN end
            if line:match("CDG") then return C.AMBER end
            if line:match("SBI") then return C.PURP end
            if line:match("RSM") then return C.CYAN end
            if line:match("HIGH") then return C.GREEN end
            if line:match("MEDIUM") then return C.AMBER end
            if line:match("LOW") then return C.RED end
            if line:match("^  ") then return C.TEXT end
            return C.MUTED
        end

        for i, line in ipairs(intelLines) do
            local row = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,13), LayoutOrder=i, ZIndex=20,
                Parent=vScroll})
            mk("UIListLayout", {
                FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%4d", i),
                TextColor3=C.DIM, TextSize=9,
                Size=UDim2.new(0,34,1,0),
                TextXAlignment=Enum.TextXAlignment.Right, ZIndex=20, Parent=row})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=" " .. line:sub(1,120),
                TextColor3=intelLineColor(line), TextSize=9,
                Size=UDim2.new(1,-38,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, ZIndex=20, Parent=row})
        end

        -- Populate analysis pane with live stats
        buildIntelAnalysisPane(entry)

        viewerOverlay.Visible = true
    end


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
                ilo = ilo + 1
            end

            -- View Intel button
            local intelBtnRow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,28), LayoutOrder=ilo, Parent=body})
            local intelBtn = mk("TextButton", {
                AutoButtonColor=false,
                BackgroundColor3=Color3.fromRGB(14,22,20), BorderSizePixel=0,
                Font=Enum.Font.GothamMedium, Text="▷ View Intel",
                TextColor3=C.TEAL, TextSize=10,
                Size=UDim2.new(0,108,0,22), Parent=intelBtnRow})
            addCorner(intelBtn, UDim.new(0,5))
            addStroke(intelBtn, 1, 0.4)
            if intelBtn:FindFirstChildOfClass("UIStroke") then
                intelBtn:FindFirstChildOfClass("UIStroke").Color = C.TEAL
            end

            -- Capture entry for closure
            local capturedEntry = entry
            intelBtn.MouseButton1Click:Connect(function()
                clickSound()
                triggerViewIntel(capturedEntry)
            end)
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

            -- Feature flags
            local flags = {}
            if a.usesPlayerLocal then table.insert(flags,"LocalPlayer") end
            if a.usesTween       then table.insert(flags,"Tween") end
            if a.usesRunService  then table.insert(flags,"RunService") end
            if a.usesPhysics     then table.insert(flags,"Physics") end
            if #flags > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="flags  " .. table.concat(flags,"  "),
                    TextColor3=C.CYAN, TextSize=9,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Functions
            if a.functions and #a.functions > 0 then
                local fnNames = {}
                for _, fn in ipairs(a.functions) do
                    table.insert(fnNames, fn.name)
                end
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="fn  " .. table.concat(fnNames, "  ·  "):sub(1,180),
                    TextColor3=C.PURP, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Remote call types
            if a.remoteCallTypes and #a.remoteCallTypes > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="remote  " .. table.concat(a.remoteCallTypes, "  "):sub(1,180),
                    TextColor3=C.TEAL, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Services used
            if a.services and #a.services > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="svc  " .. table.concat(a.services, "  "):sub(1,180),
                    TextColor3=C.BLUE, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- WaitForChild / FindFirstChild refs
            if a.waitForChildRefs and #a.waitForChildRefs > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="wfc  " .. table.concat(a.waitForChildRefs, "  "):sub(1,180),
                    TextColor3=C.CYAN, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- Connections
            if a.connections and #a.connections > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="conn  " .. table.concat(a.connections, "  "):sub(1,180),
                    TextColor3=C.AMBER, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- DataStores
            if a.datastoreRefs and #a.datastoreRefs > 0 then
                local dsText = "ds  " .. table.concat(a.datastoreRefs, "  "):sub(1,120)
                if a.datastoreKeys and #a.datastoreKeys > 0 then
                    dsText = dsText .. "  keys: " .. table.concat(a.datastoreKeys,","):sub(1,60)
                end
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=dsText, TextColor3=C.GOLD, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- HTTP
            if a.httpRefs and #a.httpRefs > 0 then
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
            if a.suspiciousKeys and #a.suspiciousKeys > 0 then
                mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="⚠  " .. table.concat(a.suspiciousKeys, "  "):sub(1,180),
                    TextColor3=C.RED, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=ilo, Parent=body})
                ilo = ilo + 1
            end

            -- View Source button row
            local btnRow = mk("Frame", {
                BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,28), LayoutOrder=ilo, Parent=body})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,6), Parent=btnRow})

            local canView = mod.source and #mod.source > 0
            local viewBtn = mk("TextButton", {
                AutoButtonColor=false,
                BackgroundColor3= canView and Color3.fromRGB(20,16,30) or C.CARD,
                BorderSizePixel=0,
                Font=Enum.Font.GothamMedium,
                Text= canView and "▷ View Source" or "Source unavailable",
                TextColor3= canView and C.PURP or C.DIM,
                TextSize=10,
                Size=UDim2.new(0,128,0,22), Parent=btnRow})
            addCorner(viewBtn, UDim.new(0,5))
            addStroke(viewBtn, 1, canView and 0.4 or 0.7)
            if viewBtn:FindFirstChildOfClass("UIStroke") then
                viewBtn:FindFirstChildOfClass("UIStroke").Color =
                    canView and C.PURP or C.DIM
            end

            if canView then
                -- Capture for closure
                local capturedMod = mod
                viewBtn.MouseButton1Click:Connect(function()
                    clickSound()
                    triggerViewSource(capturedMod.name, capturedMod.source, capturedMod.analysis)
                end)
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
        local STS_ref = _G.PC and _G.PC.STS
        for _, svcEntry in ipairs(STS_ref and STS_ref.SCAN_SERVICES or {}) do
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
                tween(scanBtnStroke, TweenInfo.new(0.3), {Color=C.TEAL})
                tween(scanBtnStroke, TweenInfo.new(0.3), {Transparency=0.3})
            end
        else
            tween(scanBtn, TweenInfo.new(0.3), {BackgroundColor3=C.DIM})
            scanBtn.TextColor3 = C.MUTED
            scanBtn.Text = "⬛  Decompile Server"
            if scanBtnStroke then
                tween(scanBtnStroke, TweenInfo.new(0.3), {Color=C.BORDER})
                tween(scanBtnStroke, TweenInfo.new(0.3), {Transparency=0.5})
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