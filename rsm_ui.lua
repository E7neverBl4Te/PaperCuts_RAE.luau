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
local makeToggle     = _U.makeToggle
local sendNotification = _U.sendNotification
local pageRSM        = (_U.pageRSM) or _U.makePage("RSM")

-- ============================================================
-- PAGE: RSM — Remote Signature Mapping
-- Sub-tabs: Overview · Signatures · Arg Inspector · Behavior · Temporal · Causal
-- ============================================================

do
    local COL = {
        BG      = Color3.fromRGB(250, 247, 242),
        CARD    = Color3.fromRGB(244, 240, 234),
        ACCENT  = Color3.fromRGB(210, 190, 155),
        TEXT    = Color3.fromRGB(52, 47, 42),
        MUTED   = Color3.fromRGB(130, 120, 108),
        GREEN   = Color3.fromRGB(60, 180, 80),
        AMBER   = Color3.fromRGB(210, 150, 40),
        RED     = Color3.fromRGB(210, 65, 65),
        BLUE    = Color3.fromRGB(60, 120, 210),
        PURPLE  = Color3.fromRGB(140, 80, 200),
    }

    -- ── Helpers ───────────────────────────────────────────────────────────────
    local function confColor(conf)
        if conf >= 0.7 then return COL.GREEN
        elseif conf >= 0.4 then return COL.AMBER
        else return COL.RED end
    end

    local function sigColor(sc)
        if sc == "CONFIRMED" then return COL.GREEN
        elseif sc == "STRONG" then return COL.BLUE
        elseif sc == "WEAK"   then return COL.AMBER
        elseif sc == "ERROR"  then return COL.RED
        else return COL.MUTED end
    end

    local function confBar(parent, conf)
        local bg = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(230,225,218), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,6), Parent=parent,
        })
        addCorner(bg, UDim.new(0,3))
        local fill = mk("Frame", {
            BackgroundColor3=confColor(conf), BorderSizePixel=0,
            Size=UDim2.new(math.clamp(conf,0,1),0,1,0), Parent=bg,
        })
        addCorner(fill, UDim.new(0,3))
        return bg, fill
    end

    -- ── Sub-tab system ────────────────────────────────────────────────────────
    local SUB_TABS = {"Overview", "Signatures", "Args", "Behavior", "Temporal", "Causal"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab = nil

    local tabBar = mk("Frame", {
        BackgroundColor3=Color3.fromRGB(242,237,230), BorderSizePixel=0,
        Size=UDim2.new(1,0,0,38), Parent=pageRSM,
    })
    addStroke(tabBar, 1, 0.4)
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        HorizontalAlignment=Enum.HorizontalAlignment.Left,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar,
    })
    mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,4),
        PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageRSM,
    })
    local function makeSubPage()
        local p = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=4,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(180,170,158),
            Visible=false, Parent=subContent,
        })
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,10), Parent=p})
        return p
    end

    for _, name in ipairs(SUB_TABS) do
        local btn = mk("TextButton", {
            AutoButtonColor=false, BackgroundColor3=Color3.fromRGB(248,244,238),
            BorderSizePixel=0, Size=UDim2.new(0,90,0,28),
            Font=Enum.Font.GothamMedium, Text=name,
            TextColor3=COL.MUTED, TextSize=11, Parent=tabBar,
        })
        addCorner(btn, UDim.new(0,8)); addStroke(btn, 1, 0.4)
        local page = makeSubPage()
        subTabBtns[name]  = btn
        subTabPages[name] = page
    end

    local function switchSubTab(name)
        if activeSubTab == name then return end
        for n, p in pairs(subTabPages) do p.Visible = (n == name) end
        for n, b in pairs(subTabBtns)  do
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = n==name and Color3.fromRGB(236,230,220) or Color3.fromRGB(248,244,238),
                TextColor3       = n==name and COL.TEXT or COL.MUTED,
            })
        end
        activeSubTab = name
    end
    for name, btn in pairs(subTabBtns) do
        btn.MouseButton1Click:Connect(function() clickSound(); switchSubTab(name) end)
    end

    -- ── State ─────────────────────────────────────────────────────────────────
    local selectedRemote = nil  -- currently inspected RSM record

    -- ── TAB: Overview ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Overview"]

        local _, sStats = makeSection(pg, "Signature Map — Summary")
        local statsLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="Building...",
            TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,64), Parent=sStats,
        })

        -- Confidence distribution sparkline (10 buckets: 0-10%, 10-20% … 90-100%)
        local _, sSpark = makeSection(pg, "Confidence Distribution")
        local sparkRow = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(242,237,230), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,52), Parent=sSpark,
        })
        addCorner(sparkRow, UDim.new(0,8)); addStroke(sparkRow, 1, 0.3)
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Bottom,
            Padding=UDim.new(0,3), Parent=sparkRow})
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=sparkRow})

        local sparkBars = {}
        local sparkLabels = {}
        for i = 1, 10 do
            local col = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.None,
                LayoutOrder=i, Parent=sparkRow})
            col.Size = UDim2.new(0, 28, 1, 0)
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,
                VerticalAlignment=Enum.VerticalAlignment.Bottom, Parent=col})
            local bar = mk("Frame", {BackgroundColor3=COL.ACCENT, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,2), LayoutOrder=1, Parent=col})
            addCorner(bar, UDim.new(0,3))
            local lbl = mk("TextLabel", {BackgroundTransparency=1,
                Font=Enum.Font.Code, Text=tostring((i-1)*10).."%",
                TextColor3=COL.MUTED, TextSize=8, Size=UDim2.new(1,0,0,12),
                LayoutOrder=2, Parent=col})
            sparkBars[i]   = bar
            sparkLabels[i] = lbl
        end

        -- Signal class breakdown
        local _, sSig = makeSection(pg, "Signal Class Breakdown")
        local sigBreakLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,40), Parent=sSig,
        })

        local function doRefreshOverview()
            local RSM = _G.PC.RSM
            if not RSM then statsLabel.Text = "RSM not loaded."; return end

            local all    = RSM.GetAll()
            local total  = #all
            local conf70 = 0
            local conf40 = 0
            local sigCounts = {CONFIRMED=0, STRONG=0, WEAK=0, LATENCY=0, SILENT=0, ERROR=0, UNKNOWN=0}
            local buckets = {0,0,0,0,0,0,0,0,0,0}

            for _, rec in ipairs(all) do
                local c = rec.Confidence
                if c >= 0.7 then conf70 = conf70 + 1
                elseif c >= 0.4 then conf40 = conf40 + 1 end
                local bi = math.min(10, math.floor(c * 10) + 1)
                buckets[bi] = buckets[bi] + 1
                local sc = rec.BehaviorSig.SignalClass or "UNKNOWN"
                sigCounts[sc] = (sigCounts[sc] or 0) + 1
            end

            statsLabel.Text = string.format(
                "Total signatures: %d\n" ..
                "High confidence (≥70%%): %d   Mid (40–70%%): %d   Low (<40%%): %d\n" ..
                "Last rebuilt: now",
                total, conf70, conf40, total-conf70-conf40)

            -- Update sparkline
            local maxBucket = 1
            for _, v in ipairs(buckets) do if v > maxBucket then maxBucket = v end end
            for i, bar in ipairs(sparkBars) do
                local frac = buckets[i] / maxBucket
                tween(bar, TweenInfo.new(0.2), {
                    Size = UDim2.new(1, 0, math.max(0.04, frac), -14),
                    BackgroundColor3 = (i >= 8) and COL.GREEN or (i >= 5) and COL.AMBER or COL.RED,
                })
            end

            -- Signal breakdown
            local sigParts = {}
            for sc, cnt in pairs(sigCounts) do
                if cnt > 0 then
                    table.insert(sigParts, string.format("%s: %d", sc, cnt))
                end
            end
            sigBreakLabel.Text = table.concat(sigParts, "  •  ")
        end

        local row = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,40), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=row})
        local btnRefresh = makeButton(row, "Rebuild Now", UDim2.new(0,160,0,36), "🔄")
        btnRefresh.Button.BackgroundColor3 = Color3.fromRGB(220,235,255)
        local btnSave    = makeButton(row, "Save Signatures", UDim2.new(0,160,0,36), "💾")
        btnSave.Button.BackgroundColor3 = Color3.fromRGB(220,255,220)

        btnRefresh.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefresh.Button)
            local RSM = _G.PC.RSM
            if RSM then
                local n = RSM.Rebuild()
                sendNotification(string.format("RSM rebuild complete — %d signatures.", n), "Success")
                doRefreshOverview()
            end
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSave.Button)
            local RSM = _G.PC.RSM
            if RSM then RSM.Save(); sendNotification("RSM signatures saved.", "Success") end
        end)

        task.defer(doRefreshOverview)
    end

    -- ── TAB: Signatures — remote list with confidence badges ─────────────────
    do
        local pg = subTabPages["Signatures"]

        local _, sSearch = makeSection(pg, "Filter & Select")
        local searchInput = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(248,244,238), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Filter by name or role...",
            PlaceholderColor3=COL.MUTED,
            Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sSearch,
        })
        addCorner(searchInput, UDim.new(0,8)); addStroke(searchInput, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=searchInput})

        local minConfSlider = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,28), Parent=sSearch})
        local minConfLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
            Text="Min confidence: 0%", TextColor3=COL.MUTED, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,1,0), Parent=minConfSlider,
        })
        local minConfValue = 0.0

        local _, sList = makeSection(pg, "Remote Signatures")
        local listHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            Parent=sList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=listHolder})

        local function buildRemoteRow(rec)
            local row = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(248,244,238), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,54), Parent=listHolder,
            })
            addCorner(row, UDim.new(0,10)); addStroke(row, 1, 0.35)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,
                Padding=UDim.new(0,3), Parent=row})

            -- Top row: name + chips
            local topRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,6), Parent=topRow})
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=rec.Name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,200,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=topRow,
            })
            local chip1 = makeChip(topRow, rec.RemoteType)
            chip1.Size = UDim2.new(0,56,0,20)
            local chip2 = makeChip(topRow, rec.Direction)
            chip2.Size = UDim2.new(0,52,0,20)
            local chip3 = makeChip(topRow, rec.BehaviorSig.SignalClass)
            chip3.Size = UDim2.new(0,90,0,20)
            chip3.BackgroundColor3 = sigColor(rec.BehaviorSig.SignalClass)

            -- Bottom row: confidence bar + stats
            local botRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,18), Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,
                Padding=UDim.new(0,2), Parent=botRow})
            confBar(botRow, rec.Confidence)
            mk("TextLabel", {
                BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("conf %.0f%%  obs %d  %.2fHz  %s",
                    rec.Confidence*100, rec.ObsCount,
                    rec.TemporalSig.AvgHz, rec.SemanticRole),
                TextColor3=COL.MUTED, TextSize=10,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), Parent=botRow,
            })

            -- Clickable — sets selectedRemote and switches to detail tabs
            local hitbox = mk("TextButton", {
                BackgroundTransparency=1, Text="", BorderSizePixel=0,
                Size=UDim2.new(1,0,1,0), ZIndex=2, Parent=row,
            })
            hookHover(row, row.BackgroundColor3, Color3.fromRGB(255,251,245), 0.35, 0.15)
            hitbox.MouseButton1Click:Connect(function()
                clickSound()
                selectedRemote = rec
                switchSubTab("Args")
            end)

            return row
        end

        local function doRefreshSignatures()
            for _, c in ipairs(listHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local RSM = _G.PC.RSM
            if not RSM then return end

            local filter = searchInput.Text:lower()
            local all    = RSM.GetAll()
            local shown  = 0
            for _, rec in ipairs(all) do
                if rec.Confidence >= minConfValue then
                    local nameMatch = filter == "" or rec.Name:lower():find(filter, 1, true)
                    local roleMatch = filter == "" or (rec.SemanticRole or ""):lower():find(filter, 1, true)
                    if nameMatch or roleMatch then
                        buildRemoteRow(rec)
                        shown = shown + 1
                        if shown >= 60 then break end  -- cap for performance
                    end
                end
            end
            if shown == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No signatures match the current filter.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,32), Parent=listHolder})
            end
        end

        searchInput:GetPropertyChangedSignal("Text"):Connect(function()
            task.defer(doRefreshSignatures)
        end)

        local row2 = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=row2})
        local btnRefresh2 = makeButton(row2, "Refresh List", UDim2.new(0,150,0,34), "🔄")
        btnRefresh2.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefresh2.Button); doRefreshSignatures()
        end)
        task.defer(doRefreshSignatures)
    end

    -- ── TAB: Args — argument schema inspector ─────────────────────────────────
    do
        local pg = subTabPages["Args"]

        local nameLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a remote from the Signatures tab.",
            TextColor3=COL.MUTED, TextSize=13,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,20), Parent=pg,
        })

        local _, sArgs = makeSection(pg, "Argument Schema")
        local argsHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
            Parent=sArgs})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,8), Parent=argsHolder})

        local _, sRaw = makeSection(pg, "Fingerprint")
        local rawLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,110), Parent=sRaw,
        })

        local function buildArgSlotCard(parent, idx, slot, order)
            local card = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(244,240,234), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=parent,
            })
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.3)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
                Padding=UDim.new(0,4), Parent=card})

            -- Slot header
            local headerRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,22), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center,
                Padding=UDim.new(0,8), Parent=headerRow})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("Arg %d", idx), TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,48,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=headerRow})
            local typeChip = makeChip(headerRow, slot.DominantType)
            typeChip.Size = UDim2.new(0,90,0,20)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("n=%d", slot.SampleCount),
                TextColor3=COL.MUTED, TextSize=10,
                Size=UDim2.new(0,60,1,0), Parent=headerRow})

            -- Number range
            if slot.NumberMin ~= nil then
                local numLine = mk("TextLabel", {
                    BackgroundTransparency=1, Font=Enum.Font.Code, TextWrapped=true,
                    Text=string.format("Range: %.3g – %.3g   μ=%.3g   σ=%.3g",
                        slot.NumberMin, slot.NumberMax,
                        slot.NumberMean, math.sqrt(math.max(0, slot.NumberM2 / math.max(1, slot.NumberN-1)))),
                    TextColor3=COL.TEXT, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=card,
                })
            end

            -- Success value distribution
            if #slot.SuccessValues > 0 then
                local sortedSV = {table.unpack(slot.SuccessValues)}
                table.sort(sortedSV)
                local succ = {}
                for i = 1, math.min(6, #sortedSV) do
                    succ[i] = string.format("%.3g", sortedSV[i])
                end
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="✓ Success vals: " .. table.concat(succ, ", "),
                    TextColor3=COL.GREEN, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=3, Parent=card})
            end

            -- Fail value distribution
            if #slot.FailValues > 0 then
                local sortedFV = {table.unpack(slot.FailValues)}
                table.sort(sortedFV)
                local fail = {}
                for i = 1, math.min(6, #sortedFV) do
                    fail[i] = string.format("%.3g", sortedFV[i])
                end
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="✗ Fail vals: " .. table.concat(fail, ", "),
                    TextColor3=COL.RED, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=4, Parent=card})
            end

            -- Success strings
            if #slot.SuccessStrings > 0 then
                local ss = {}
                for i = 1, math.min(4, #slot.SuccessStrings) do
                    ss[i] = '"'..slot.SuccessStrings[i]..'"'
                end
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text="✓ Strings: " .. table.concat(ss, ", "),
                    TextColor3=COL.GREEN, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=5, Parent=card})
            end

            return card
        end

        local function doRefreshArgs()
            for _, c in ipairs(argsHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local rec = selectedRemote
            if not rec then
                nameLabel.Text = "Select a remote from the Signatures tab."
                rawLabel.Text  = "—"
                return
            end

            nameLabel.Text = rec.Name .. "  (" .. rec.RemoteType .. " · " .. rec.Direction .. ")"

            if #rec.ArgSig == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No argument schema observed yet.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,24), LayoutOrder=1, Parent=argsHolder})
            else
                for i, slot in ipairs(rec.ArgSig) do
                    buildArgSlotCard(argsHolder, i, slot, i)
                end
            end

            local RSM = _G.PC.RSM
            rawLabel.Text = RSM and RSM.GetFingerprint(rec.Name) or "RSM not loaded."
        end

        local refreshBtn = makeButton(pg, "Refresh Inspector", UDim2.new(0,180,0,34), "🔍")
        refreshBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(refreshBtn.Button); doRefreshArgs()
        end)
        -- Auto-refresh when sub-tab becomes active
        for name, btn in pairs(subTabBtns) do
            if name == "Args" then
                btn.MouseButton1Click:Connect(doRefreshArgs)
            end
        end
    end

    -- ── TAB: Behavior — BehaviorSig inspector ────────────────────────────────
    do
        local pg = subTabPages["Behavior"]

        local nameLabel2 = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a remote from Signatures.", TextColor3=COL.MUTED,
            TextSize=13, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,20), Parent=pg,
        })

        local _, sAP = makeSection(pg, "Affected DataModel Paths")
        local pathsLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,64), Parent=sAP,
        })

        local _, sPD = makeSection(pg, "Path Delta Distributions")
        local pathDeltaLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=sPD,
        })

        local _, sLat = makeSection(pg, "Latency Profile & Debris")
        local latLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,48), Parent=sLat,
        })

        local function doRefreshBehavior()
            local rec = selectedRemote
            if not rec then
                nameLabel2.Text = "Select a remote from Signatures."
                pathsLabel.Text = "—"; pathDeltaLabel.Text = "—"; latLabel.Text = "—"
                return
            end
            nameLabel2.Text = rec.Name

            local bs = rec.BehaviorSig
            local paths = {}
            for p in pairs(bs.AffectedPaths) do table.insert(paths, p) end
            table.sort(paths)
            pathsLabel.Text = #paths > 0 and table.concat(paths, "\n") or "None observed"
            pathsLabel.Size = UDim2.new(1,0,0,math.max(24, #paths*14+4))

            local deltaLines = {}
            for path, pd in pairs(bs.PathDeltas) do
                table.insert(deltaLines, string.format("%-40s  μ=%+.3g  σ=%.3g  [%.3g,%.3g]  n=%d",
                    path:sub(1,40), pd.mean, pd.std, pd.min, pd.max, pd.n))
            end
            table.sort(deltaLines)
            pathDeltaLabel.Text = #deltaLines > 0 and table.concat(deltaLines, "\n") or "No numeric deltas recorded."
            pathDeltaLabel.Size = UDim2.new(1,0,0,math.max(24,#deltaLines*13+4))

            local lp      = bs.LatencyProfile
            local debris  = {}
            for cls in pairs(bs.DebrisClasses) do table.insert(debris, cls) end
            table.sort(debris)
            latLabel.Text = string.format(
                "Signal: %s  Conf: %.0f%%  Probes: %d\n" ..
                "Latency spike: μ=%.1fms  σ=%.1fms  n=%d\n" ..
                "Debris: %s",
                bs.SignalClass, bs.SignalConfidence*100, bs.ProbeCount,
                lp.mean, lp.std, lp.n,
                #debris > 0 and table.concat(debris, ", ") or "none")
        end

        local btnB = makeButton(pg, "Refresh", UDim2.new(0,140,0,34), "📊")
        btnB.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnB.Button); doRefreshBehavior()
        end)
        subTabBtns["Behavior"].MouseButton1Click:Connect(doRefreshBehavior)
    end

    -- ── TAB: Temporal ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Temporal"]

        local nameLabel3 = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a remote from Signatures.", TextColor3=COL.MUTED,
            TextSize=13, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,20), Parent=pg,
        })

        local _, sT = makeSection(pg, "Temporal Profile")
        local tempLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,64), Parent=sT,
        })

        local _, sSeq = makeSection(pg, "Sequencing Neighbours")
        local seqLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,80), Parent=sSeq,
        })

        local function doRefreshTemporal()
            local rec = selectedRemote
            if not rec then
                nameLabel3.Text = "Select a remote from Signatures."
                tempLabel.Text = "—"; seqLabel.Text = "—"
                return
            end
            nameLabel3.Text = rec.Name
            local ts = rec.TemporalSig

            tempLabel.Text = string.format(
                "Rate: %.4f Hz  Class: %s\n" ..
                "Median inter-fire: %.1f ms\n" ..
                "Burst score (Fano): %.3f  %s",
                ts.AvgHz, ts.FreqClass,
                ts.InterFireP50 * 1000,
                ts.BurstScore,
                ts.BurstScore > 2 and "⚠ bursty" or ts.BurstScore < 0.3 and "✓ periodic" or "~")

            local seqLines = {}
            local prec = {}
            for n in pairs(ts.PrecedesMap) do table.insert(prec, "  → " .. n) end
            local foll = {}
            for n in pairs(ts.FollowsMap)  do table.insert(foll, "  ← " .. n) end
            table.sort(prec); table.sort(foll)
            if #prec > 0 then
                table.insert(seqLines, "Precedes:")
                for _, l in ipairs(prec) do table.insert(seqLines, l) end
            end
            if #foll > 0 then
                table.insert(seqLines, "Follows:")
                for _, l in ipairs(foll) do table.insert(seqLines, l) end
            end
            seqLabel.Text = #seqLines > 0 and table.concat(seqLines,"\n") or "No sequencing data."
            seqLabel.Size = UDim2.new(1,0,0,math.max(24,#seqLines*13+4))
        end

        local btnT = makeButton(pg, "Refresh", UDim2.new(0,140,0,34), "⏱")
        btnT.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnT.Button); doRefreshTemporal()
        end)
        subTabBtns["Temporal"].MouseButton1Click:Connect(doRefreshTemporal)
    end

    -- ── TAB: Causal ───────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Causal"]

        local nameLabel4 = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text="Select a remote from Signatures.", TextColor3=COL.MUTED,
            TextSize=13, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,20), Parent=pg,
        })

        local _, sC = makeSection(pg, "ETM & CDG")
        local causalLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.TEXT, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,60), Parent=sC,
        })

        local _, sEdges = makeSection(pg, "CDG Edge Neighbours")
        local edgeHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sEdges})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=edgeHolder})

        local function doRefreshCausal()
            for _, c in ipairs(edgeHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local rec = selectedRemote
            if not rec then
                nameLabel4.Text = "Select a remote from Signatures."
                causalLabel.Text = "—"
                return
            end
            nameLabel4.Text = rec.Name
            local cs = rec.CausalSig

            causalLabel.Text = string.format(
                "ETM confidence: %.0f%%  Converged: %s\n" ..
                "CDG causal score: %.4f\n" ..
                "CDG neighbours: %d",
                cs.ETMConfidence * 100, cs.ETMConverged and "yes" or "no",
                cs.CDGScore, #cs.CDGEdges)

            for i, edge in ipairs(cs.CDGEdges) do
                local erow = mk("Frame", {
                    BackgroundColor3=Color3.fromRGB(244,240,234), BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,36), LayoutOrder=i, Parent=edgeHolder,
                })
                addCorner(erow, UDim.new(0,8)); addStroke(erow, 1, 0.3)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                    PaddingTop=UDim.new(0,4), Parent=erow})
                mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
                    Padding=UDim.new(0,2), Parent=erow})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=edge.Neighbour, TextColor3=COL.TEXT, TextSize=11,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=erow})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("effect=%.3f  conf=%.0f%%",
                        edge.EffectSize, edge.Confidence*100),
                    TextColor3=COL.MUTED, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=erow})
                confBar(erow, edge.Confidence)
            end

            if #cs.CDGEdges == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No CDG edges for this remote.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,24), Parent=edgeHolder})
            end
        end

        local btnC = makeButton(pg, "Refresh", UDim2.new(0,140,0,34), "🔬")
        btnC.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnC.Button); doRefreshCausal()
        end)
        subTabBtns["Causal"].MouseButton1Click:Connect(doRefreshCausal)
    end

    -- ── Default sub-tab ───────────────────────────────────────────────────────
    switchSubTab("Overview")
end
