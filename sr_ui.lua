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
local pageSR         = (_U.pageSR) or _U.makePage("SR")

-- ============================================================
-- PAGE: SR — State Reconstruction
-- Sub-tabs: Overview · Domain · Variables · Predict · Diff
-- ============================================================

do
    local COL = {
        BG      = Color3.fromRGB(247, 244, 238),
        CARD    = Color3.fromRGB(240, 236, 229),
        ACCENT  = Color3.fromRGB(120, 160, 210),
        TEXT    = Color3.fromRGB(50, 45, 40),
        MUTED   = Color3.fromRGB(128, 118, 105),
        GREEN   = Color3.fromRGB(55, 175, 75),
        AMBER   = Color3.fromRGB(210, 148, 35),
        RED     = Color3.fromRGB(210, 60, 60),
        BLUE    = Color3.fromRGB(60, 120, 210),
        PURPLE  = Color3.fromRGB(138, 78, 200),
        TEAL    = Color3.fromRGB(40, 160, 150),
    }

    local DOMAIN_COLORS = {
        ECONOMY   = Color3.fromRGB(55, 185, 90),
        INVENTORY = Color3.fromRGB(145, 80, 205),
        SESSION   = Color3.fromRGB(60, 130, 215),
        PHYSICS   = Color3.fromRGB(215, 100, 45),
        NETWORK   = Color3.fromRGB(50, 165, 155),
        UNKNOWN   = Color3.fromRGB(140, 130, 118),
    }

    local SOURCE_COLORS = {
        DIRECT         = Color3.fromRGB(55, 175, 75),
        INFERRED_PROBE = Color3.fromRGB(60, 120, 210),
        INFERRED_RSM   = Color3.fromRGB(138, 78, 200),
        LWM            = Color3.fromRGB(50, 165, 155),
        PREDICTED      = Color3.fromRGB(210, 148, 35),
        NONE           = Color3.fromRGB(140, 130, 118),
    }

    local function confColor(c)
        if c >= 0.70 then return COL.GREEN
        elseif c >= 0.40 then return COL.AMBER
        else return COL.RED end
    end

    local function confBar(parent, conf, layoutOrder)
        local bg = mk("Frame", {
            BackgroundColor3=Color3.fromRGB(225,220,212), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,5), LayoutOrder=layoutOrder or 99, Parent=parent,
        })
        addCorner(bg, UDim.new(0,3))
        local fill = mk("Frame", {
            BackgroundColor3=confColor(conf), BorderSizePixel=0,
            Size=UDim2.new(math.clamp(conf,0,1),0,1,0), Parent=bg,
        })
        addCorner(fill, UDim.new(0,3))
        return bg, fill
    end

    local function valueStr(v)
        if v == nil then return "nil"
        elseif type(v) == "number" then
            if v == math.floor(v) then return tostring(math.floor(v))
            else return string.format("%.4g", v) end
        elseif type(v) == "boolean" then return v and "true" or "false"
        else return tostring(v):sub(1,32) end
    end

    -- ── Sub-tab system ────────────────────────────────────────────────────────
    local SUB_TABS = {"Overview", "Domain", "Variables", "Predict", "Diff"}
    local subTabBtns  = {}
    local subTabPages = {}
    local activeSubTab= nil

    local tabBar = mk("Frame", {
        BackgroundColor3=Color3.fromRGB(240,235,228), BorderSizePixel=0,
        Size=UDim2.new(1,0,0,38), Parent=pageSR,
    })
    addStroke(tabBar, 1, 0.4)
    mk("UIListLayout", {
        FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,4), Parent=tabBar,
    })
    mk("UIPadding", {PaddingLeft=UDim.new(0,8),
        PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), Parent=tabBar})

    local subContent = mk("Frame", {
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,0,0,38), Size=UDim2.new(1,0,1,-38),
        ClipsDescendants=true, Parent=pageSR,
    })

    local function makeSubPage()
        local p = mk("ScrollingFrame", {
            BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,1,0), ScrollBarThickness=4,
            CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
            ScrollingDirection=Enum.ScrollingDirection.Y,
            ScrollBarImageColor3=Color3.fromRGB(175,165,152), Visible=false, Parent=subContent,
        })
        mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingRight=UDim.new(0,14),
            PaddingTop=UDim.new(0,10), PaddingBottom=UDim.new(0,10), Parent=p})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,10), Parent=p})
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
        subTabBtns[name]  = btn
        subTabPages[name] = makeSubPage()
    end

    local function switchSubTab(name)
        if activeSubTab == name then return end
        for n, p in pairs(subTabPages) do p.Visible = (n==name) end
        for n, b in pairs(subTabBtns) do
            tween(b, TweenInfo.new(0.1), {
                BackgroundColor3 = n==name and Color3.fromRGB(234,228,218) or Color3.fromRGB(248,244,238),
                TextColor3       = n==name and COL.TEXT or COL.MUTED,
            })
        end
        activeSubTab = name
    end

    for name, btn in pairs(subTabBtns) do
        btn.MouseButton1Click:Connect(function() clickSound(); switchSubTab(name) end)
    end

    -- Shared filter state for domain tab
    local selectedDomain = "ECONOMY"

    -- ── TAB: Overview ─────────────────────────────────────────────────────────
    do
        local pg = subTabPages["Overview"]

        -- Live state clock display
        local _, sLive = makeSection(pg, "Live State Model")
        local liveLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="Building...",
            TextColor3=COL.MUTED, TextSize=11, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,52), Parent=sLive,
        })

        -- Domain summary bars
        local _, sDomains = makeSection(pg, "Domain Confidence")
        local DOMAIN_ORDER = {"ECONOMY","INVENTORY","SESSION","PHYSICS","NETWORK","UNKNOWN"}
        local domRows = {}
        for i, d in ipairs(DOMAIN_ORDER) do
            local row = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(244,240,233), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,38), LayoutOrder=i, Parent=sDomains,
            })
            addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.3)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,6), PaddingBottom=UDim.new(0,6), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,4), Parent=row})

            local topRow = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,16), LayoutOrder=1, Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,8), Parent=topRow})

            local dot = mk("Frame", {BackgroundColor3=DOMAIN_COLORS[d] or COL.MUTED,
                BorderSizePixel=0, Size=UDim2.new(0,10,0,10), Parent=topRow})
            addCorner(dot, UDim.new(0,999))
            local nameL = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=d, TextColor3=COL.TEXT, TextSize=11, Size=UDim2.new(0,100,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=topRow})
            local statsL = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text="—", TextColor3=COL.MUTED, TextSize=10, Size=UDim2.new(0,200,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=topRow})

            local _, barFill = confBar(row, 0, 2)
            domRows[d] = { statsL=statsL, barFill=barFill }
        end

        -- Source breakdown
        local _, sSrc = makeSection(pg, "Sources")
        local srcLabel = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code, Text="—",
            TextColor3=COL.MUTED, TextSize=10, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,48), Parent=sSrc,
        })

        local function doRefreshOverview()
            local SR = _G.PC.SR
            if not SR then liveLabel.Text = "SR not loaded."; return end

            local total = SR.Count()
            local summary = SR.GetDomainSummary()

            liveLabel.Text = string.format(
                "Total StateVars: %d   High conf (≥70%%): %d   Mid (40-70%%): %d\nPipelines: DIRECT · INFERRED_PROBE · INFERRED_RSM · LWM",
                total,
                #SR.GetAll(0.70),
                #SR.GetAll(0.40) - #SR.GetAll(0.70))

            local srcCounts = {}
            for _, sv in ipairs(SR.GetAll()) do
                srcCounts[sv.source] = (srcCounts[sv.source] or 0) + 1
            end
            local srcParts = {}
            for src, cnt in pairs(srcCounts) do
                table.insert(srcParts, src.."="..cnt)
            end
            srcLabel.Text = table.concat(srcParts, "  ")

            for d, row in pairs(domRows) do
                local info = summary[d]
                if info and info.varCount > 0 then
                    row.statsL.Text = string.format("%d vars  avg %.0f%%  direct=%d",
                        info.varCount, info.avgConf*100, info.directCount)
                    tween(row.barFill, TweenInfo.new(0.25), {
                        Size=UDim2.new(math.clamp(info.avgConf,0,1),0,1,0),
                        BackgroundColor3=confColor(info.avgConf),
                    })
                else
                    row.statsL.Text = "no data"
                    tween(row.barFill, TweenInfo.new(0.25), {Size=UDim2.new(0,0,1,0)})
                end
            end
        end

        local rowB = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=rowB})
        local btnScan    = makeButton(rowB, "Full Scan", UDim2.new(0,140,0,34), "🔍")
        local btnSave    = makeButton(rowB, "Save", UDim2.new(0,110,0,34), "💾")
        local btnSnap    = makeButton(rowB, "Snapshot", UDim2.new(0,120,0,34), "📷")
        btnScan.Button.BackgroundColor3  = Color3.fromRGB(220,235,255)
        btnSave.Button.BackgroundColor3  = Color3.fromRGB(220,255,220)
        btnSnap.Button.BackgroundColor3  = Color3.fromRGB(245,235,255)

        btnScan.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnScan.Button)
            local SR = _G.PC.SR
            if SR then
                SR.Scan()
                sendNotification(string.format("SR scan: %d vars.", SR.Count()), "Success")
                doRefreshOverview()
            end
        end)
        btnSave.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSave.Button)
            local SR = _G.PC.SR
            if SR then SR.Save(); sendNotification("SR state saved.", "Success") end
        end)
        btnSnap.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSnap.Button)
            local SR = _G.PC.SR
            if SR then
                SR.TakeSnapshot()
                sendNotification("Snapshot taken.", "Success")
            end
        end)
        task.defer(doRefreshOverview)
    end

    -- ── TAB: Domain — domain selector + variable list ─────────────────────────
    do
        local pg = subTabPages["Domain"]

        -- Domain selector row
        local _, sDSel = makeSection(pg, "Select Domain")
        local domSelRow = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,36), Parent=sDSel})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
            Padding=UDim.new(0,6), Parent=domSelRow})
        local DOMAIN_ORDER2 = {"ECONOMY","INVENTORY","SESSION","PHYSICS","NETWORK","UNKNOWN"}
        local domBtns = {}
        for _, d in ipairs(DOMAIN_ORDER2) do
            local btn = mk("TextButton", {
                AutoButtonColor=false, BackgroundColor3=Color3.fromRGB(248,244,238),
                BorderSizePixel=0, Size=UDim2.new(0,86,0,32),
                Font=Enum.Font.GothamMedium, Text=d,
                TextColor3=COL.MUTED, TextSize=10, Parent=domSelRow,
            })
            addCorner(btn, UDim.new(0,8)); addStroke(btn, 1, 0.35)
            domBtns[d] = btn
        end

        local _, sDVars = makeSection(pg, "Domain Variables")
        local dvHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sDVars})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,6), Parent=dvHolder})

        local function buildVarCard(sv, order)
            local card = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(246,242,236), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                LayoutOrder=order, Parent=dvHolder,
            })
            addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.3)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
            mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

            -- Top row: name + source chip + conf
            local top = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,20), LayoutOrder=1, Parent=card})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=top})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=sv.name, TextColor3=COL.TEXT, TextSize=12,
                Size=UDim2.new(0,160,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=top})
            local srcChip = makeChip(top, sv.source)
            srcChip.Size = UDim2.new(0,120,0,20)
            srcChip.BackgroundColor3 = SOURCE_COLORS[sv.source] or COL.MUTED
            if srcChip:FindFirstChildOfClass("TextLabel") then
                srcChip:FindFirstChildOfClass("TextLabel").TextColor3 = Color3.fromRGB(255,255,255)
            end
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("%.0f%%", sv.confidence*100),
                TextColor3=confColor(sv.confidence), TextSize=12,
                Size=UDim2.new(0,40,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=top})

            -- Value display
            local valStr = valueStr(sv.value)
            local prevStr = sv.prevValue ~= nil and ("prev: "..valueStr(sv.prevValue)) or ""
            local deltaStr = sv.delta ~= nil and (sv.delta >= 0 and "▲"..string.format("%.4g",sv.delta)
                or "▼"..string.format("%.4g",math.abs(sv.delta))) or ""
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("value: %s  %s  %s", valStr, deltaStr, prevStr),
                TextColor3=COL.TEXT, TextSize=10, TextWrapped=true,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=card})

            -- Numeric distribution
            if sv.numN > 0 and sv.numMin ~= nil then
                local std = sv.numN >= 2 and math.sqrt(math.max(0,
                    (sv.numM2 or (sv.numN*(sv.numMin+sv.numMax)/2)) -- fallback
                ) / (sv.numN-1)) or 0
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("μ=%.4g  σ=%.4g  [%.4g,%.4g]  n=%d",
                        sv.numMean, std, sv.numMin, sv.numMax, sv.numN),
                    TextColor3=COL.MUTED, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=3, Parent=card})
            end

            -- Path/remote binding
            if sv.pathBinding or sv.remoteBinding then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=string.format("path: %s  remote: %s",
                        sv.pathBinding or "—", sv.remoteBinding or "—"),
                    TextColor3=COL.MUTED, TextSize=9, TextWrapped=true,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,13), LayoutOrder=4, Parent=card})
            end

            -- Confidence bar
            confBar(card, sv.confidence, 5)
            return card
        end

        local function doRefreshDomain()
            for _, c in ipairs(dvHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SR = _G.PC.SR
            if not SR then return end

            -- Update button states
            for d, btn in pairs(domBtns) do
                tween(btn, TweenInfo.new(0.1), {
                    BackgroundColor3 = d==selectedDomain and Color3.fromRGB(236,230,220) or Color3.fromRGB(248,244,238),
                    TextColor3       = d==selectedDomain and COL.TEXT or COL.MUTED,
                })
            end

            local vars = SR.GetDomain(selectedDomain)
            if #vars == 0 then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No StateVars observed for "..selectedDomain.." yet.",
                    TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,28), Parent=dvHolder})
                return
            end
            for i, sv in ipairs(vars) do
                buildVarCard(sv, i)
                if i >= 40 then break end
            end
        end

        for d, btn in pairs(domBtns) do
            btn.MouseButton1Click:Connect(function()
                clickSound(); selectedDomain = d; doRefreshDomain()
            end)
        end

        local domRefBtn = makeButton(pg, "Refresh", UDim2.new(0,130,0,34), "🔄")
        domRefBtn.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(domRefBtn.Button); doRefreshDomain()
        end)
        subTabBtns["Domain"].MouseButton1Click:Connect(doRefreshDomain)
    end

    -- ── TAB: Variables — searchable full list ─────────────────────────────────
    do
        local pg = subTabPages["Variables"]

        local _, sF = makeSection(pg, "Search & Filter")
        local searchBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(248,244,238), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Search name, path, remote...",
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sF,
        })
        addCorner(searchBox, UDim.new(0,8)); addStroke(searchBox, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=searchBox})

        local minConfLabel = mk("TextLabel", {BackgroundTransparency=1,
            Font=Enum.Font.GothamMedium, Text="Show: All",
            TextColor3=COL.MUTED, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,16), Parent=sF})
        local showMinConf = 0.0

        local _, sList = makeSection(pg, "State Variables")
        local varHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sList})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
            Padding=UDim.new(0,5), Parent=varHolder})

        local function buildVarRow(sv, order)
            local row = mk("Frame", {
                BackgroundColor3=Color3.fromRGB(246,242,236), BorderSizePixel=0,
                Size=UDim2.new(1,0,0,42), LayoutOrder=order, Parent=varHolder,
            })
            addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
            mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=row})
            mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})

            local r1 = mk("Frame", {BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=row})
            mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,5), Parent=r1})

            -- Domain dot
            local dot = mk("Frame", {
                BackgroundColor3=DOMAIN_COLORS[sv.domain] or COL.MUTED,
                BorderSizePixel=0, Size=UDim2.new(0,8,0,8), Parent=r1,
            })
            addCorner(dot, UDim.new(0,999))

            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=sv.name, TextColor3=COL.TEXT, TextSize=11,
                Size=UDim2.new(0,150,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=valueStr(sv.value),
                TextColor3=COL.TEXT, TextSize=11, Size=UDim2.new(0,120,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=string.format("%.0f%%", sv.confidence*100),
                TextColor3=confColor(sv.confidence), TextSize=11,
                Size=UDim2.new(0,36,1,0), TextXAlignment=Enum.TextXAlignment.Right, Parent=r1})

            local r2 = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=string.format("%s · %s · upd=%d · %s",
                    sv.domain, sv.source, sv.updateCount, sv.remoteBinding or "—"),
                TextColor3=COL.MUTED, TextSize=9, TextWrapped=false,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,0,0,12), LayoutOrder=2, Parent=row})
        end

        local function doRefreshVars()
            for _, c in ipairs(varHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SR = _G.PC.SR
            if not SR then return end

            local filter = searchBox.Text:lower()
            local all    = SR.GetAll(showMinConf)
            local shown  = 0
            for _, sv in ipairs(all) do
                local match = filter == ""
                    or (sv.name or ""):lower():find(filter, 1, true)
                    or (sv.pathBinding or ""):lower():find(filter, 1, true)
                    or (sv.remoteBinding or ""):lower():find(filter, 1, true)
                if match then
                    buildVarRow(sv, shown + 1)
                    shown = shown + 1
                    if shown >= 80 then break end
                end
            end
            minConfLabel.Text = string.format("Showing %d vars (conf ≥ %.0f%%)", shown, showMinConf*100)
        end

        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            task.defer(doRefreshVars)
        end)

        local filterRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,8), Parent=filterRow})
        local function makeConfFilter(label, val)
            local btn = makeButton(filterRow, label, UDim2.new(0,80,0,32), "")
            btn.Button.MouseButton1Click:Connect(function()
                clickSound(); showMinConf = val; doRefreshVars()
            end)
            return btn
        end
        makeConfFilter("All",  0.0)
        makeConfFilter(">40%", 0.4)
        makeConfFilter(">70%", 0.7)

        local btnRefV = makeButton(pg, "Refresh", UDim2.new(0,120,0,34), "🔄")
        btnRefV.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnRefV.Button); doRefreshVars()
        end)
        subTabBtns["Variables"].MouseButton1Click:Connect(doRefreshVars)
    end

    -- ── TAB: Predict — PredictChange for a given remote ──────────────────────
    do
        local pg = subTabPages["Predict"]

        local _, sInput = makeSection(pg, "Remote to Predict")
        local remoteInput = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(248,244,238), BorderSizePixel=0,
            ClearTextOnFocus=false, Font=Enum.Font.GothamMedium,
            PlaceholderText="Enter remote name...",
            PlaceholderColor3=COL.MUTED, Text="", TextColor3=COL.TEXT, TextSize=12,
            Size=UDim2.new(1,0,0,32), Parent=sInput,
        })
        addCorner(remoteInput, UDim.new(0,8)); addStroke(remoteInput, 1, 0.3)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=remoteInput})

        local _, sPred = makeSection(pg, "Predicted State Changes")
        local predHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sPred})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,6), Parent=predHolder})

        local function doPredict()
            for _, c in ipairs(predHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SR = _G.PC.SR
            if not SR then return end

            local remoteName = remoteInput.Text:match("^%s*(.-)%s*$")
            if remoteName == "" then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="Enter a remote name above.", TextColor3=COL.MUTED, TextSize=12,
                    Size=UDim2.new(1,0,0,24), Parent=predHolder})
                return
            end

            local preds = SR.PredictChange(remoteName)
            if not next(preds) then
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="No prediction available — RSM has not mapped this remote yet.",
                    TextColor3=COL.MUTED, TextSize=12, TextWrapped=true,
                    Size=UDim2.new(1,0,0,36), Parent=predHolder})
                return
            end

            local order = 0
            -- Sort by confidence desc
            local sortedPreds = {}
            for path, pred in pairs(preds) do
                table.insert(sortedPreds, {path=path, pred=pred})
            end
            table.sort(sortedPreds, function(a,b) return a.pred.confidence > b.pred.confidence end)

            for _, entry in ipairs(sortedPreds) do
                order = order + 1
                local path = entry.path
                local pred = entry.pred
                local card = mk("Frame", {
                    BackgroundColor3=Color3.fromRGB(244,240,233), BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y,
                    LayoutOrder=order, Parent=predHolder,
                })
                addCorner(card, UDim.new(0,10)); addStroke(card, 1, 0.3)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10),
                    PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,8), Parent=card})
                mk("UIListLayout", {Padding=UDim.new(0,3), Parent=card})

                -- Domain dot + path
                local top = mk("Frame", {BackgroundTransparency=1,
                    Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=card})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=top})
                local dot = mk("Frame", {
                    BackgroundColor3=DOMAIN_COLORS[pred.domain] or COL.MUTED,
                    BorderSizePixel=0, Size=UDim2.new(0,8,0,8), Parent=top})
                addCorner(dot, UDim.new(0,999))
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=path:sub(1,60), TextColor3=COL.TEXT, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(0.85,0,1,0), Parent=top})
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=string.format("%.0f%%", pred.confidence*100),
                    TextColor3=confColor(pred.confidence), TextSize=11,
                    Size=UDim2.new(0.15,0,1,0),
                    TextXAlignment=Enum.TextXAlignment.Right, Parent=top})

                -- Delta / uncertainty
                local deltaStr = pred.expectedDelta ~= 0 and
                    string.format("Δ %+.4g ± %.4g", pred.expectedDelta, pred.uncertainty) or
                    "no numeric delta"
                local valStr2 = pred.expectedValue ~= nil and
                    string.format("  →  %.4g", pred.expectedValue) or ""
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=deltaStr .. valStr2 .. "   [" .. pred.domain .. "]",
                    TextColor3=COL.MUTED, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=card})

                confBar(card, pred.confidence, 3)
            end
        end

        local btnPredict = makeButton(pg, "Predict", UDim2.new(0,140,0,34), "🔮")
        btnPredict.Button.BackgroundColor3 = Color3.fromRGB(245,235,255)
        btnPredict.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnPredict.Button); doPredict()
        end)
    end

    -- ── TAB: Diff — recent state changes ─────────────────────────────────────
    do
        local pg = subTabPages["Diff"]

        local _, sDC = makeSection(pg, "Recent State Changes")
        local dcInfo = mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.Code,
            Text="Take snapshots to enable diff.", TextColor3=COL.MUTED, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,20), Parent=sDC,
        })

        local diffHolder = mk("Frame", {BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,10), AutomaticSize=Enum.AutomaticSize.Y, Parent=sDC})
        mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,5), Parent=diffHolder})

        local function doRefreshDiff()
            for _, c in ipairs(diffHolder:GetChildren()) do
                if c:IsA("Frame") then c:Destroy() end
            end
            local SR = _G.PC.SR
            if not SR then return end

            local changes = SR.RecentDiff(4)
            if #changes == 0 then
                dcInfo.Text = "No changes detected between recent snapshots."
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamMedium,
                    Text="Take two snapshots and refresh.",
                    TextColor3=COL.MUTED, TextSize=12, Size=UDim2.new(1,0,0,24), Parent=diffHolder})
                return
            end
            dcInfo.Text = string.format("%d state variable changes in recent snapshot window.", #changes)

            for i, ch in ipairs(changes) do
                local row = mk("Frame", {
                    BackgroundColor3=Color3.fromRGB(246,242,236), BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,38), LayoutOrder=i, Parent=diffHolder,
                })
                addCorner(row, UDim.new(0,8)); addStroke(row, 1, 0.28)
                mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,8),
                    PaddingTop=UDim.new(0,5), PaddingBottom=UDim.new(0,5), Parent=row})
                mk("UIListLayout", {Padding=UDim.new(0,2), Parent=row})

                local r1 = mk("Frame", {BackgroundTransparency=1,
                    Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=row})
                mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
                    VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,6), Parent=r1})

                local dot = mk("Frame", {BackgroundColor3=DOMAIN_COLORS[ch.domain] or COL.MUTED,
                    BorderSizePixel=0, Size=UDim2.new(0,8,0,8), Parent=r1})
                addCorner(dot, UDim.new(0,999))
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                    Text=ch.varName, TextColor3=COL.TEXT, TextSize=11,
                    Size=UDim2.new(0,150,1,0), TextXAlignment=Enum.TextXAlignment.Left, Parent=r1})

                -- Change arrow
                local changeText
                if ch.delta then
                    local arrow = ch.delta >= 0 and "▲" or "▼"
                    changeText = string.format("%s  %s%s → %s",
                        ch.domain, arrow, string.format("%.4g",math.abs(ch.delta)),
                        valueStr(ch.newValue))
                else
                    changeText = string.format("%s  %s → %s",
                        ch.domain, valueStr(ch.prevValue), valueStr(ch.newValue))
                end
                mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                    Text=changeText, TextColor3=COL.MUTED, TextSize=10,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    Size=UDim2.new(1,0,0,14), LayoutOrder=2, Parent=row})
            end
        end

        local btnSnap2  = makeButton(pg, "Snapshot", UDim2.new(0,120,0,34), "📷")
        local btnDiff   = makeButton(pg, "Diff", UDim2.new(0,100,0,34), "Δ")
        local diffRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,36), Parent=pg})
        mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,10), Parent=diffRow})
        btnSnap2.Button.Parent = diffRow; btnDiff.Button.Parent = diffRow

        btnSnap2.Button.BackgroundColor3 = Color3.fromRGB(245,235,255)
        btnDiff.Button.BackgroundColor3  = Color3.fromRGB(220,235,255)
        btnSnap2.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnSnap2.Button)
            local SR = _G.PC.SR
            if SR then SR.TakeSnapshot(); sendNotification("Snapshot taken.", "Success") end
        end)
        btnDiff.Button.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(btnDiff.Button); doRefreshDiff()
        end)
        subTabBtns["Diff"].MouseButton1Click:Connect(doRefreshDiff)
    end

    -- ── Default ───────────────────────────────────────────────────────────────
    switchSubTab("Overview")
end
