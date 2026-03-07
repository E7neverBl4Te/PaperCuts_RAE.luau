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
local pageAVD        = _U.pageAVD

-- ============================================================
-- PAGE: AVD — Autonomous Vulnerability Debugger
-- Real-time dashboard for all four AVD modules.
-- Tabs: Overview · Findings · Sentry · Probes · Settings
-- ============================================================

do
    -- ── Colour palette ────────────────────────────────────────────────────────
    local COL = {
        BG        = Color3.fromRGB(250, 247, 242),
        CARD      = Color3.fromRGB(244, 240, 234),
        BORDER    = Color3.fromRGB(210, 200, 188),
        TEXT      = Color3.fromRGB(46,  42,  38),
        MUTED     = Color3.fromRGB(130, 120, 110),
        CONFIRMED = Color3.fromRGB(60,  160, 80),
        STRONG    = Color3.fromRGB(80,  120, 200),
        WEAK      = Color3.fromRGB(180, 150, 60),
        SILENT    = Color3.fromRGB(160, 155, 150),
        LATENCY   = Color3.fromRGB(200, 120, 40),
        ERROR_COL = Color3.fromRGB(200, 60,  60),
        SARP      = Color3.fromRGB(60,  140, 200),
    }

    local SIGNAL_COLOR = {
        CONFIRMED = COL.CONFIRMED,
        STRONG    = COL.STRONG,
        WEAK      = COL.WEAK,
        SILENT    = COL.SILENT,
        LATENCY   = COL.LATENCY,
        ERROR     = COL.ERROR_COL,
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
        mk("UIListLayout", {
            SortOrder  = Enum.SortOrder.LayoutOrder,
            Padding    = UDim.new(0, 3),
            Parent     = s,
        })
        mk("UIPadding", {
            PaddingTop   = UDim.new(0, 4),
            PaddingLeft  = UDim.new(0, 6),
            PaddingRight = UDim.new(0, 6),
            Parent       = s,
        })
        return s
    end

    -- ── Sub-tab system ────────────────────────────────────────────────────────
    local SUB_TABS    = { "Overview", "Findings", "Sentry", "Probes", "Settings" }
    local subPages    = {}
    local activeSubTab = nil

    local tabBarHolder = mk("Frame", {
        BackgroundTransparency = 1,
        Size   = UDim2.new(1, -24, 0, 32),
        Position = UDim2.new(0, 12, 0, 8),
        Parent = pageAVD,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding       = UDim.new(0, 6),
        Parent        = tabBarHolder,
    })

    local pageHolder = mk("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 0, 48),
        Size     = UDim2.new(1, 0, 1, -48),
        Parent   = pageAVD,
    })

    local subTabBtns = {}
    local function switchSubTab(name)
        for n, pg in pairs(subPages) do pg.Visible = n == name end
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
            Parent           = tabBarHolder,
        })
        addCorner(btn, UDim.new(0, 8))
        addStroke(btn, 1, 0.5)
        hookHover(btn, btn.BackgroundColor3, Color3.fromRGB(252, 246, 238), 0.5, 0.3)
        subTabBtns[name] = btn

        local pg = mk("ScrollingFrame", {
            BackgroundTransparency  = 1,
            BorderSizePixel         = 0,
            Size                    = UDim2.new(1, 0, 1, 0),
            CanvasSize              = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize     = Enum.AutomaticSize.Y,
            ScrollBarThickness      = 6,
            Visible                 = false,
            Parent                  = pageHolder,
        })
        mk("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding   = UDim.new(0, 8),
            Parent    = pg,
        })
        mk("UIPadding", {
            PaddingTop    = UDim.new(0, 8),
            PaddingLeft   = UDim.new(0, 12),
            PaddingRight  = UDim.new(0, 12),
            PaddingBottom = UDim.new(0, 8),
            Parent        = pg,
        })
        subPages[name] = pg

        btn.MouseButton1Click:Connect(function()
            clickSound()
            switchSubTab(name)
        end)
    end

    -- ── TAB 1: Overview ───────────────────────────────────────────────────────
    do
        local pg = subPages["Overview"]
        local _, sStatus = makeSection(pg, "AVD Status")

        -- Status row
        local statusRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 34),
            Parent = sStatus,
        })
        mk("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding       = UDim.new(0, 8),
            Parent        = statusRow,
        })

        local runBadge = mk("TextLabel", {
            Text             = "● IDLE",
            Font             = Enum.Font.GothamBold,
            TextSize         = 11,
            TextColor3       = COL.MUTED,
            BackgroundColor3 = COL.CARD,
            Size             = UDim2.new(0, 100, 0, 28),
            TextXAlignment   = Enum.TextXAlignment.Center,
            Parent           = statusRow,
        })
        addCorner(runBadge, UDim.new(0, 6))

        local baselineBadge = mk("TextLabel", {
            Text             = "BASELINE: waiting",
            Font             = Enum.Font.GothamMedium,
            TextSize         = 10,
            TextColor3       = COL.MUTED,
            BackgroundColor3 = COL.CARD,
            Size             = UDim2.new(0, 140, 0, 28),
            TextXAlignment   = Enum.TextXAlignment.Center,
            Parent           = statusRow,
        })
        addCorner(baselineBadge, UDim.new(0, 6))

        -- Stat grid
        local _, sStats = makeSection(pg, "Session Stats")
        local statGrid = mk("Frame", {
            BackgroundTransparency = 1,
            Size                   = UDim2.new(1, 0, 0, 80),
            Parent                 = sStats,
        })
        mk("UIGridLayout", {
            CellSize    = UDim2.new(0.5, -4, 0, 36),
            CellPadding = UDim2.new(0, 6, 0, 6),
            Parent      = statGrid,
        })

        local statLabels = {}
        local statDefs = {
            { key="targets",   label="Targets" },
            { key="probes",    label="Probes Fired" },
            { key="findings",  label="Findings" },
            { key="sarpReady", label="SARP Ready" },
        }
        for _, def in ipairs(statDefs) do
            local card = mkCard(statGrid, 36)
            mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=card })
            mkLabel(card, def.label, 9, COL.MUTED)
            local val = mkLabel(card, "—", 14, COL.TEXT, true)
            val.Position = UDim2.new(0, 8, 0, 16)
            val.Size     = UDim2.new(1, -12, 0, 18)
            statLabels[def.key] = val
        end

        -- Signal breakdown
        local _, sSig = makeSection(pg, "Signal Breakdown")
        local sigGrid = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 60),
            Parent = sSig,
        })
        mk("UIGridLayout", {
            CellSize    = UDim2.new(0.33, -4, 0, 28),
            CellPadding = UDim2.new(0, 4, 0, 4),
            Parent      = sigGrid,
        })
        local sigLabels = {}
        for _, sig in ipairs({"CONFIRMED","STRONG","WEAK","SILENT","LATENCY","ERROR"}) do
            local card = mkCard(sigGrid, 28)
            card.BackgroundColor3 = SIGNAL_COLOR[sig] or COL.CARD
            card.BackgroundTransparency = 0.75
            mk("UIPadding", { PaddingLeft=UDim.new(0,6), Parent=card })
            local lbl = mkLabel(card, sig..": 0", 9, COL.TEXT, true)
            lbl.Size = UDim2.new(1,-4,1,0)
            sigLabels[sig] = lbl
        end

        -- Control row
        local ctrlRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 34),
            Parent = pg,
        })
        mk("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding       = UDim.new(0, 8),
            Parent        = ctrlRow,
        })
        local startBtn = makeButton(ctrlRow, "▶ Start AVD",   UDim2.new(0, 130, 0, 30), "")
        local stopBtn  = makeButton(ctrlRow, "■ Stop",        UDim2.new(0, 90,  0, 30), "")
        local ingestBtn= makeButton(ctrlRow, "⟳ Re-Ingest",  UDim2.new(0, 110, 0, 30), "")
        startBtn.Button.BackgroundColor3  = Color3.fromRGB(210, 240, 215)
        stopBtn.Button.BackgroundColor3   = Color3.fromRGB(255, 225, 220)
        ingestBtn.Button.BackgroundColor3 = Color3.fromRGB(220, 230, 255)

        startBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(startBtn.Button)
            local op = _G.PC.AVD and _G.PC.AVD.Operator
            if op then
                op.Start()
                runBadge.Text       = "● RUNNING"
                runBadge.TextColor3 = COL.CONFIRMED
                sendNotification("AVD started.", "Success")
            else
                sendNotification("AVD Operator not loaded.", "Warning")
            end
        end)
        stopBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local op = _G.PC.AVD and _G.PC.AVD.Operator
            if op then
                op.Stop()
                runBadge.Text       = "● STOPPED"
                runBadge.TextColor3 = COL.ERROR_COL
            end
        end)
        ingestBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(ingestBtn.Button)
            local s = _G.PC.AVD and _G.PC.AVD.Strategist
            if s then
                local r = s.IngestFromRAE()
                local p = s.IngestFromPR()
                sendNotification(string.format("Ingested %d RAE + %d PR targets.", r, p), "Info")
            end
        end)

        -- Auto-refresh overview stats when tab is visible
        local function refreshOverview()
            local avd = _G.PC.AVD
            if not avd then return end

            local sentry     = avd.Sentry
            local strategist = avd.Strategist
            local operator   = avd.Operator
            local translator = avd.Translator

            -- Baseline badge
            if sentry then
                if sentry.IsBaselineDone() then
                    baselineBadge.Text       = "BASELINE: ✓ done"
                    baselineBadge.TextColor3 = COL.CONFIRMED
                else
                    local elapsed = math.floor(os.clock() - (sentry.GetCFG and sentry.GetCFG().BaselineWindow or 8))
                    baselineBadge.Text       = "BASELINE: collecting"
                    baselineBadge.TextColor3 = COL.LATENCY
                end
            end

            -- Target status
            if strategist then
                local ts = strategist.GetTargetStatus()
                statLabels["targets"].Text = tostring(ts.total)
                local fs = strategist.GetFindingSummary()
                statLabels["findings"].Text  = tostring(fs.total)
                statLabels["sarpReady"].Text = tostring(fs.sarpReady)
            end

            -- Probe stats
            if operator then
                local stats = operator.GetStats()
                statLabels["probes"].Text = tostring(stats.TotalFired)
            end

            -- Signal breakdown
            if translator then
                local summary = translator.GetSummary()
                for sig, lbl in pairs(sigLabels) do
                    lbl.Text = sig .. ": " .. tostring(summary[sig] or 0)
                end
            end
        end

        pageAVD:GetPropertyChangedSignal("Visible"):Connect(function()
            if pageAVD.Visible then refreshOverview() end
        end)
        -- Periodic refresh when visible
        task.spawn(function()
            while true do
                task.wait(3)
                if pageAVD.Visible and activeSubTab == "Overview" then
                    pcall(refreshOverview)
                end
            end
        end)
    end

    -- ── TAB 2: Findings ───────────────────────────────────────────────────────
    do
        local pg = subPages["Findings"]
        local _, sF = makeSection(pg, "Vulnerability Findings")
        mkLabel(sF, "Sorted by exploit score. Green = SARP-ready.", 10, COL.MUTED)

        local findScroll = mkScroll(sF, 340)

        local fCtrlRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 30),
            Parent = sF,
        })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=fCtrlRow })
        local fRefBtn   = makeButton(fCtrlRow, "Refresh",      UDim2.new(0,110,0,28), "")
        local fSARPBtn  = makeButton(fCtrlRow, "Send Top→SARP",UDim2.new(0,150,0,28), "")
        local fClearBtn = makeButton(fCtrlRow, "Clear Persist", UDim2.new(0,130,0,28), "")
        fRefBtn.Button.BackgroundColor3   = Color3.fromRGB(220,230,255)
        fSARPBtn.Button.BackgroundColor3  = Color3.fromRGB(200,230,255)
        fClearBtn.Button.BackgroundColor3 = Color3.fromRGB(255,230,225)

        local function refreshFindings()
            for _, ch in ipairs(findScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
            if not strategist then
                mkLabel(findScroll, "Strategist not loaded.", 11, COL.MUTED)
                return
            end
            local findings = strategist.GetFindings(0)
            if #findings == 0 then
                mkLabel(findScroll, "No findings yet.", 11, COL.MUTED)
                return
            end
            for _, f in ipairs(findings) do
                local sigColor = SIGNAL_COLOR[f.signal] or COL.CARD
                local row = mk("Frame", {
                    BackgroundColor3 = sigColor,
                    BackgroundTransparency = 0.7,
                    Size   = UDim2.new(1, 0, 0, 58),
                    Parent = findScroll,
                })
                addCorner(row, UDim.new(0, 5))
                addStroke(row, 1, 0.2)
                if f.sarpReady then
                    addStroke(row, 2, 0, Color3.fromRGB(60,160,80))
                end
                mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=row })

                -- Name + signal
                mkLabel(row, string.format("[%s] %s", f.signal, f.remoteName:sub(1,38)),
                    11, COL.TEXT, true).Size = UDim2.new(1,-12,0,14)

                -- Score + technique
                local line2 = mkLabel(row,
                    string.format("Score:%.2f  Tech:%s  Cat:%s%s",
                        f.exploitScore, f.technique or "?", f.category or "?",
                        f.sarpReady and "  ✓SARP" or ""),
                    9, COL.MUTED)
                line2.Position = UDim2.new(0,8,0,18)
                line2.Size     = UDim2.new(1,-12,0,12)

                -- Affected paths
                local paths = #f.affectedPaths > 0
                    and table.concat(f.affectedPaths, ", "):sub(1,60)
                    or  (f.latencyDelta and string.format("+%.0fms latency", f.latencyDelta))
                    or  "no state change observed"
                local line3 = mkLabel(row, paths, 9, COL.MUTED)
                line3.Position = UDim2.new(0,8,0,32)
                line3.Size     = UDim2.new(1,-12,0,12)
            end
        end

        fRefBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshFindings() end)
        fSARPBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(fSARPBtn.Button)
            local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
            local operator   = _G.PC.AVD and _G.PC.AVD.Operator
            if not strategist or not operator then return end
            local findings = strategist.GetFindings(0.75)
            if #findings == 0 then
                sendNotification("No SARP-ready findings.", "Warning")
                return
            end
            local top = findings[1]
            operator.SARPDeliver({
                remoteName   = top.remoteName,
                payload      = top.probeArgs or {},
                confidence   = top.confidence,
                exploitScore = top.exploitScore,
                technique    = top.technique,
            })
            sendNotification("Sent " .. top.remoteName .. " → SARP", "Success")
        end)
        fClearBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local s = _G.PC.AVD and _G.PC.AVD.Strategist
            if s then
                pcall(function()
                    _G[s.GetCFG().PersistKey] = nil
                end)
                sendNotification("AVD findings persist cleared.", "Warning")
            end
        end)
    end

    -- ── TAB 3: Sentry ─────────────────────────────────────────────────────────
    do
        local pg = subPages["Sentry"]
        local _, sSentry = makeSection(pg, "Sentry Event Stream")
        mkLabel(sSentry, "Live events from the 5-tier observer. Baseline events shown in grey.", 10, COL.MUTED)

        local TIER_COLORS = {
            [1] = Color3.fromRGB(210,240,255),
            [2] = Color3.fromRGB(225,255,220),
            [3] = Color3.fromRGB(255,240,210),
            [4] = Color3.fromRGB(240,220,255),
            [5] = Color3.fromRGB(255,220,220),
        }

        local sentryScroll = mkScroll(sSentry, 300)
        local filterTier   = 0  -- 0 = all

        local sCtrlRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 30),
            Parent = sSentry,
        })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,6), Parent=sCtrlRow })
        local sRefBtn    = makeButton(sCtrlRow, "Refresh",   UDim2.new(0,100,0,28), "")
        local sTierBtn   = makeButton(sCtrlRow, "Tier: ALL", UDim2.new(0,90, 0,28), "")
        local sFlushBtn  = makeButton(sCtrlRow, "Flush",     UDim2.new(0,80, 0,28), "")
        sRefBtn.Button.BackgroundColor3   = Color3.fromRGB(220,235,255)
        sTierBtn.Button.BackgroundColor3  = Color3.fromRGB(240,230,255)
        sFlushBtn.Button.BackgroundColor3 = Color3.fromRGB(255,230,225)

        local function refreshSentry()
            for _, ch in ipairs(sentryScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local sentry = _G.PC.AVD and _G.PC.AVD.Sentry
            if not sentry then mkLabel(sentryScroll,"Sentry not loaded.",11,COL.MUTED); return end

            local events = sentry.GetEvents(nil, filterTier > 0 and filterTier or nil)
            -- Show most recent 40
            local start = math.max(1, #events - 39)
            if #events == 0 then
                mkLabel(sentryScroll, "No events captured yet.", 11, COL.MUTED)
                return
            end
            for i = #events, start, -1 do
                local ev = events[i]
                local tColor = TIER_COLORS[ev.tier] or COL.CARD
                local row = mk("Frame", {
                    BackgroundColor3       = ev.isBaseline and COL.CARD or tColor,
                    BackgroundTransparency = ev.isBaseline and 0.3 or 0.6,
                    Size   = UDim2.new(1, 0, 0, 36),
                    Parent = sentryScroll,
                })
                addCorner(row, UDim.new(0, 4))
                mk("UIPadding", { PaddingLeft=UDim.new(0,6), PaddingTop=UDim.new(0,3), Parent=row })

                local tag = ev.isBaseline and "[BASE]" or "[LIVE]"
                mkLabel(row,
                    string.format("%s T%d %-10s %s", tag, ev.tier, ev.kind, (ev.path or ""):sub(1,36)),
                    10, ev.isBaseline and COL.MUTED or COL.TEXT, true
                ).Size = UDim2.new(1,-8,0,14)

                local val = ev.kind == "PROPERTY"
                    and string.format("%s: %s → %s", ev.property or "?",
                        tostring(ev.oldValue):sub(1,16), tostring(ev.newValue):sub(1,16))
                    or ev.kind == "DEBRIS"
                    and string.format("class:%s lived %.2fs", ev.property or "?", ev.newValue or 0)
                    or ev.kind == "LATENCY"
                    and string.format("%.1fms (baseline %.1fms)", ev.newValue or 0, ev.oldValue or 0)
                    or tostring(ev.newValue or ""):sub(1,50)

                mkLabel(row, val, 9, COL.MUTED).Position = UDim2.new(0,6,0,18)
            end
        end

        local tierCycle = {0,1,2,3,4,5}
        local tierIdx   = 1
        sTierBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            tierIdx     = (tierIdx % #tierCycle) + 1
            filterTier  = tierCycle[tierIdx]
            sTierBtn.Label.Text = filterTier == 0 and "Tier: ALL" or ("Tier: " .. filterTier)
            refreshSentry()
        end)
        sRefBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshSentry() end)
        sFlushBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local sentry = _G.PC.AVD and _G.PC.AVD.Sentry
            if sentry then sentry.Flush(); refreshSentry() end
        end)
    end

    -- ── TAB 4: Probes ─────────────────────────────────────────────────────────
    do
        local pg = subPages["Probes"]
        local _, sProbes = makeSection(pg, "Correlation Reports")
        mkLabel(sProbes, "Each row = one probe window resolved by the Translator.", 10, COL.MUTED)

        local probeScroll = mkScroll(sProbes, 320)

        local pCtrlRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 30),
            Parent = sProbes,
        })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=pCtrlRow })
        local pRefBtn  = makeButton(pCtrlRow, "Refresh",     UDim2.new(0,110,0,28), "")
        local pSigBtn  = makeButton(pCtrlRow, "Sig: ALL",    UDim2.new(0,100,0,28), "")
        pRefBtn.Button.BackgroundColor3  = Color3.fromRGB(220,235,255)
        pSigBtn.Button.BackgroundColor3  = Color3.fromRGB(240,225,255)

        local sigFilter = nil
        local sigCycle  = {nil,"CONFIRMED","STRONG","WEAK","LATENCY","ERROR","SILENT"}
        local sigIdx    = 1

        local function refreshProbes()
            for _, ch in ipairs(probeScroll:GetChildren()) do
                if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
            end
            local translator = _G.PC.AVD and _G.PC.AVD.Translator
            if not translator then mkLabel(probeScroll,"Translator not loaded.",11,COL.MUTED); return end

            local reports = translator.GetReports(sigFilter)
            if #reports == 0 then
                mkLabel(probeScroll, "No reports yet.", 11, COL.MUTED); return
            end
            -- Most recent 50
            for i = #reports, math.max(1, #reports-49), -1 do
                local r = reports[i]
                local sigColor = SIGNAL_COLOR[r.signal] or COL.CARD
                local row = mk("Frame", {
                    BackgroundColor3       = sigColor,
                    BackgroundTransparency = 0.72,
                    Size   = UDim2.new(1, 0, 0, 52),
                    Parent = probeScroll,
                })
                addCorner(row, UDim.new(0, 5))
                addStroke(row, 1, 0.2)
                mk("UIPadding", { PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4), Parent=row })

                mkLabel(row,
                    string.format("[%s] %s  conf:%.0f%%",
                        r.signal, (r.remoteName or "?"):sub(1,32),
                        (r.confidence or 0)*100),
                    11, COL.TEXT, true
                ).Size = UDim2.new(1,-12,0,14)

                mkLabel(row,
                    string.format("kind:%-16s  t1:%d t2:%d t3:%d t4:%d  noise:%d",
                        (r.probeKind or "?"):sub(1,16),
                        #(r.tier1Events or {}), #(r.tier2Events or {}),
                        #(r.tier3Events or {}), #(r.tier4Events or {}),
                        #(r.noiseEvents or {})),
                    9, COL.MUTED
                ).Position = UDim2.new(0,8,0,18)

                local detail = #(r.affectedPaths or {}) > 0
                    and ("paths: " .. table.concat(r.affectedPaths,","):sub(1,52))
                    or  (r.latencyDelta and string.format("+%.0fms", r.latencyDelta))
                    or  "no indirect signal"
                mkLabel(row, detail, 9, COL.MUTED).Position = UDim2.new(0,8,0,32)
            end
        end

        pRefBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshProbes() end)
        pSigBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            sigIdx     = (sigIdx % #sigCycle) + 1
            sigFilter  = sigCycle[sigIdx]
            pSigBtn.Label.Text = "Sig: " .. (sigFilter or "ALL")
            refreshProbes()
        end)
    end

    -- ── TAB 5: Settings ───────────────────────────────────────────────────────
    do
        local pg = subPages["Settings"]
        local _, sOpCfg = makeSection(pg, "Operator Settings")

        local togRow = mk("Frame", {
            BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y,
            Size   = UDim2.new(1, 0, 0, 10),
            Parent = sOpCfg,
        })
        mk("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding       = UDim.new(0, 12),
            Parent        = togRow,
        })

        makeToggle(togRow, "Passive Only", false, function(on)
            local op = _G.PC.AVD and _G.PC.AVD.Operator
            if op then op.SetPassiveOnly(on) end
        end)
        makeToggle(togRow, "PR Channel", true, function(on)
            local op = _G.PC.AVD and _G.PC.AVD.Operator
            if op then op.GetCFG().UsePRBridgeChannel = on end
        end)

        local _, sSenCfg = makeSection(pg, "Sentry Settings")
        local debrisRow = mk("Frame", {
            BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y,
            Size   = UDim2.new(1, 0, 0, 10),
            Parent = sSenCfg,
        })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,12), Parent=debrisRow })
        makeToggle(debrisRow, "Watch Characters", true, function(on)
            -- Toggling character watching requires restart — just note it
            sendNotification("Restart AVD to apply character watching change.", "Info")
        end)

        local _, sSave = makeSection(pg, "Persist")
        local saveRow = mk("Frame", {
            BackgroundTransparency = 1,
            Size   = UDim2.new(1, 0, 0, 34),
            Parent = sSave,
        })
        mk("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=saveRow })
        local saveBtn  = makeButton(saveRow, "Save Findings",  UDim2.new(0,140,0,30), "")
        local clearBtn = makeButton(saveRow, "Clear All",      UDim2.new(0,110,0,30), "")
        saveBtn.Button.BackgroundColor3  = Color3.fromRGB(215,240,215)
        clearBtn.Button.BackgroundColor3 = Color3.fromRGB(255,225,220)

        saveBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(saveBtn.Button)
            local s = _G.PC.AVD and _G.PC.AVD.Strategist
            if s then s.SaveFindings(); sendNotification("AVD findings saved.", "Success") end
        end)
        clearBtn.Button.MouseButton1Click:Connect(function()
            clickSound()
            local s = _G.PC.AVD and _G.PC.AVD.Strategist
            if s then
                pcall(function() _G[s.GetCFG().PersistKey] = nil end)
                sendNotification("All AVD persist cleared.", "Warning")
            end
        end)
    end

    -- Default to Overview
    switchSubTab("Overview")
end
