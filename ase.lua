local PC              = _G.PC
local GSE_Log         = PC.GSE_Log
local GSE_LogCallbacks= PC.GSE_LogCallbacks
local GSE_PERSIST_KEY = PC.GSE_PERSIST_KEY
local TAG_COLORS      = PC.TAG_COLORS
local C               = PC.C
local gseBtn          = PC.gseBtn
local gseLabel        = PC.gseLabel
local gseInput        = PC.gseInput
local gseRow          = PC.gseRow
local gseHScroll      = PC.gseHScroll
local gseChip         = PC.gseChip
local pageGSE         = PC.pageGSE
local mk              = PC.mk
local addCorner       = PC.addCorner
local addStroke       = PC.addStroke
local hookHover       = PC.hookHover
local tween           = PC.tween
local makeSection     = PC.makeSection
local clickSound      = PC.clickSound
local pulseClick      = PC.pulseClick
local DSE_Serialise = PC.DSE_Serialise

-- ============================================================
-- ANALYTICS SERVICE EDIT (ASE)
-- ============================================================
-- AnalyticsService is the developer's telemetry layer.
-- Games call it to annotate significant events for their
-- own dashboards. For GSE the value is:
--
--   OBSERVATION:  Hook all Fire* methods to build a live
--                 economy ledger and event map — the developer
--                 annotated their own game for us.
--
--   MANIPULATION: Intercept and modify calls before they fire.
--                 Two modes:
--                   PASSTHROUGH — log but don't alter
--                   MODIFY      — rewrite specific fields
--                   SUPPRESS    — silently drop the call
--
--   CLOAKING:     Suppress or modify economy events that
--                 would trip anti-cheat analytics sensors
--                 on large gain/sink amounts.
--
-- Four hooked methods:
--   FireCustomEvent(player, eventCategory, customFields?)
--   FireLogEvent(player, logLevel, message)
--   FireEconomyEvent(player, itemSku, currencyType, amount,
--                    flowType, transactionType, fields?)
--   FireProgressionEvent(player, status, step1, step2?, step3?)
-- ============================================================

local ASE = {
    -- Raw event log: { time, method, args, modified, suppressed }
    Events           = {},
    -- Economy ledger: [itemSku] = { sku, currency, totalSource,
    --                               totalSink, count, lastSeen }
    Ledger           = {},
    -- Suppression rules: [index] = { method, field, pattern }
    SuppressionRules = {},
    -- Modification rules: [index] = { method, field, pattern,
    --                                  replacement }
    ModRules         = {},
    -- Master hook mode: "PASSTHROUGH" | "MODIFY" | "SUPPRESS_ALL"
    HookMode         = "PASSTHROUGH",
    -- Economy gain threshold for auto-cloaking (0 = disabled)
    CloakThreshold   = 0,
    -- Whether the hook is currently installed
    HookInstalled    = false,
}

-- Persist inside the shared GSE key
local function ASE_Save()
    pcall(function()
        local saved = _G[GSE_PERSIST_KEY] or {}
        saved.ASE_HookMode       = ASE.HookMode
        saved.ASE_CloakThreshold = ASE.CloakThreshold
        saved.ASE_SupRules       = ASE.SuppressionRules
        saved.ASE_ModRules       = ASE.ModRules
        _G[GSE_PERSIST_KEY]      = saved
    end)
end

local function ASE_Load()
    pcall(function()
        local s = _G[GSE_PERSIST_KEY]
        if type(s) ~= "table" then return end
        if type(s.ASE_HookMode)       == "string" then ASE.HookMode       = s.ASE_HookMode       end
        if type(s.ASE_CloakThreshold) == "number" then ASE.CloakThreshold = s.ASE_CloakThreshold end
        if type(s.ASE_SupRules)       == "table"  then ASE.SuppressionRules = s.ASE_SupRules     end
        if type(s.ASE_ModRules)       == "table"  then ASE.ModRules       = s.ASE_ModRules       end
    end)
end

ASE_Load()

-- ── Event log helpers ─────────────────────────────────────────
local ASE_EventCallbacks = {}
local ASE_LedgerCallbacks = {}

local function ASE_LogEvent(method, args, modified, suppressed)
    local entry = {
        time       = os.clock(),
        method     = method,
        args       = args,
        modified   = modified   or false,
        suppressed = suppressed or false,
    }
    table.insert(ASE.Events, 1, entry)
    if #ASE.Events > 200 then table.remove(ASE.Events) end
    local tag = suppressed and "SUPPRESS" or (modified and "MODIFY" or "OBSERVE")
    GSE_Log("ASE", "[" .. tag .. "] " .. method .. "  " ..
            (args[2] and tostring(args[2]):sub(1,40) or ""))
    for _, cb in ipairs(ASE_EventCallbacks) do pcall(cb, entry) end
end

-- ── Economy ledger update ─────────────────────────────────────
local function ASE_UpdateLedger(sku, currency, amount, flowType)
    sku      = tostring(sku      or "unknown")
    currency = tostring(currency or "unknown")
    amount   = tonumber(amount)  or 0

    if not ASE.Ledger[sku] then
        ASE.Ledger[sku] = {
            sku         = sku,
            currency    = currency,
            totalSource = 0,
            totalSink   = 0,
            count       = 0,
            lastSeen    = 0,
        }
    end

    local rec = ASE.Ledger[sku]
    rec.count    = rec.count + 1
    rec.lastSeen = os.clock()
    rec.currency = currency

    -- flowType is Enum.AnalyticsEconomyFlowType
    -- .Source = player gained, .Sink = player spent
    local ftStr = tostring(flowType):lower()
    if ftStr:find("source") then
        rec.totalSource = rec.totalSource + amount
    else
        rec.totalSink = rec.totalSink + amount
    end

    for _, cb in ipairs(ASE_LedgerCallbacks) do pcall(cb, sku, rec) end
end

-- ── Check if a call should be suppressed ─────────────────────
local function ASE_ShouldSuppress(method, args)
    if ASE.HookMode == "SUPPRESS_ALL" then return true end

    -- Auto-cloak: suppress FireEconomyEvent when gain > threshold
    if ASE.CloakThreshold > 0 and method == "FireEconomyEvent" then
        local amount  = tonumber(args[4]) or 0
        local ftStr   = tostring(args[5]):lower()
        if ftStr:find("source") and amount > ASE.CloakThreshold then
            return true
        end
    end

    -- Check user-defined suppression rules
    for _, rule in ipairs(ASE.SuppressionRules) do
        if rule.method == "ALL" or rule.method == method then
            -- rule.field is arg index (1-based) or "ALL"
            local fieldVal = rule.field == "ALL"
                and table.concat(args, "|")
                or  tostring(args[tonumber(rule.field)] or "")
            if fieldVal:lower():find(rule.pattern:lower(), 1, true) then
                return true
            end
        end
    end

    return false
end

-- ── Apply modification rules to args ─────────────────────────
-- Returns modified args table and a boolean indicating if
-- anything was changed.
local function ASE_ApplyModRules(method, args)
    if ASE.HookMode ~= "MODIFY" then return args, false end
    local changed = false
    local newArgs = {}
    for i, v in ipairs(args) do newArgs[i] = v end

    for _, rule in ipairs(ASE.ModRules) do
        if rule.method == "ALL" or rule.method == method then
            local idx = tonumber(rule.field)
            if idx and newArgs[idx] ~= nil then
                local cur = tostring(newArgs[idx])
                if cur:lower():find(rule.pattern:lower(), 1, true) then
                    -- Try numeric replacement first
                    local numRep = tonumber(rule.replacement)
                    newArgs[idx] = numRep or rule.replacement
                    changed = true
                end
            end
        end
    end

    return newArgs, changed
end

-- ── Core namecall hook ────────────────────────────────────────
-- Intercepts all four AnalyticsService Fire* methods.
-- Runs suppression and modification checks before passing
-- through to the original call (or dropping it entirely).
local function ASE_InstallHook()
    if ASE.HookInstalled then return end
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)

        local ANALYTICS_METHODS = {
            FireCustomEvent     = true,
            FireLogEvent        = true,
            FireEconomyEvent    = true,
            FireProgressionEvent= true,
        }

        local function newNC(self, ...)
            local method = getnamecallmethod()

            if not ANALYTICS_METHODS[method] then
                if oldNC then return oldNC(self, ...) end
                return
            end

            local args = {...}

            -- Economy ledger update (before any modification)
            if method == "FireEconomyEvent" then
                -- args: player, itemSku, currencyType, amount,
                --       flowType, transactionType, fields?
                pcall(ASE_UpdateLedger, args[2], args[3],
                      args[4], args[5])
            end

            -- Suppression check
            if ASE_ShouldSuppress(method, args) then
                ASE_LogEvent(method, args, false, true)
                return  -- Drop the call entirely
            end

            -- Modification check
            local finalArgs, wasModified = ASE_ApplyModRules(method, args)

            -- Log the event
            ASE_LogEvent(method, finalArgs, wasModified, false)

            -- Pass through to original
            if oldNC then
                return oldNC(self, table.unpack(finalArgs))
            end
        end

        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)

    if ok then
        ASE.HookInstalled = true
        GSE_Log("ASE", "AnalyticsService hook installed  mode=" .. ASE.HookMode)
    else
        GSE_Log("WARN", "ASE hook failed: " .. tostring(err))
    end
end

-- Install immediately
ASE_InstallHook()

-- Add ASE to TAG_COLORS
TAG_COLORS["ASE"]      = Color3.fromRGB(220,140,40)
TAG_COLORS["SUPPRESS"] = Color3.fromRGB(180,60,60)
TAG_COLORS["MODIFY"]   = Color3.fromRGB(60,140,200)
TAG_COLORS["OBSERVE"]  = Color3.fromRGB(100,180,100)

-- ASE colours
C.ASE_BG      = Color3.fromRGB(255,248,235)
C.ASE_CARD    = Color3.fromRGB(252,244,228)
C.ASE_SOURCE  = Color3.fromRGB(210,240,215)   -- green for gains
C.ASE_SINK    = Color3.fromRGB(248,220,215)   -- red for spends
C.ASE_PASS    = Color3.fromRGB(230,245,230)
C.ASE_MOD     = Color3.fromRGB(225,235,250)
C.ASE_SUP     = Color3.fromRGB(250,225,225)
C.ASE_LOG     = Color3.fromRGB(30,28,24)      -- dark log bg

-- ============================================================
-- UI — SECTION: Hook Mode Control
-- ============================================================
local _, sASEMode = makeSection(pageGSE, "📊  AnalyticsService — Hook Control")

gseLabel(sASEMode,
    "Intercepts all AnalyticsService Fire* calls. Choose how to handle them:\n" ..
    "Passthrough = observe only.  Modify = rewrite fields.  Suppress All = drop everything.",
    11, false, C.SUBTEXT)

-- Hook status indicator
local hookStatusRow = gseRow(sASEMode)
local hookStatusDot = mk("Frame",{
    BackgroundColor3 = ASE.HookInstalled
        and Color3.fromRGB(80,200,100)
        or  Color3.fromRGB(200,80,80),
    BorderSizePixel=0,
    Size=UDim2.new(0,10,0,10),
    Parent=hookStatusRow,
})
addCorner(hookStatusDot, UDim.new(1,0))
local hookStatusLabel = gseLabel(hookStatusRow,
    ASE.HookInstalled and "Hook active" or "Hook not installed",
    11, true,
    ASE.HookInstalled
        and Color3.fromRGB(60,160,80)
        or  Color3.fromRGB(180,60,60))

local btnReinstall = gseBtn(hookStatusRow, "↻ Reinstall Hook", C.BTN, C.BTNHOV, 3)
btnReinstall.MouseButton1Click:Connect(function()
    ASE.HookInstalled = false
    ASE_InstallHook()
    tween(hookStatusDot, TweenInfo.new(0.15), {
        BackgroundColor3 = ASE.HookInstalled
            and Color3.fromRGB(80,200,100)
            or  Color3.fromRGB(200,80,80)
    })
    hookStatusLabel.Text = ASE.HookInstalled and "Hook active" or "Hook not installed"
    hookStatusLabel.TextColor3 = ASE.HookInstalled
        and Color3.fromRGB(60,160,80) or Color3.fromRGB(180,60,60)
end)

-- Mode toggle row
local modeRow = gseRow(sASEMode)
local btnPass  = gseBtn(modeRow, "👁 Passthrough",
    ASE.HookMode=="PASSTHROUGH"  and C.ASE_PASS or C.BTN, C.BTNHOV, 1)
local btnMod   = gseBtn(modeRow, "✏ Modify",
    ASE.HookMode=="MODIFY"       and C.ASE_MOD  or C.BTN, C.BTNHOV, 2)
local btnSupAll= gseBtn(modeRow, "🚫 Suppress All",
    ASE.HookMode=="SUPPRESS_ALL" and C.ASE_SUP  or C.BTN, C.BTNHOV, 3)

local modeLabel = gseLabel(modeRow, "Mode: " .. ASE.HookMode, 11, true, C.SUBTEXT)

local function ASE_SetMode(mode)
    ASE.HookMode = mode; ASE_Save()
    modeLabel.Text = "Mode: " .. mode
    tween(btnPass,   TweenInfo.new(0.12), {BackgroundColor3 = mode=="PASSTHROUGH"  and C.ASE_PASS or C.BTN})
    tween(btnMod,    TweenInfo.new(0.12), {BackgroundColor3 = mode=="MODIFY"       and C.ASE_MOD  or C.BTN})
    tween(btnSupAll, TweenInfo.new(0.12), {BackgroundColor3 = mode=="SUPPRESS_ALL" and C.ASE_SUP  or C.BTN})
    GSE_Log("ASE", "Hook mode → " .. mode)
end

btnPass.MouseButton1Click:Connect(function()   ASE_SetMode("PASSTHROUGH")  end)
btnMod.MouseButton1Click:Connect(function()    ASE_SetMode("MODIFY")       end)
btnSupAll.MouseButton1Click:Connect(function() ASE_SetMode("SUPPRESS_ALL") end)

-- Cloak threshold row
local cloakRow = gseRow(sASEMode)
gseLabel(cloakRow, "Auto-cloak economy gains above:", 11, false, C.SUBTEXT)
local cloakInput = mk("TextBox",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Font=Enum.Font.RobotoMono,
    PlaceholderText="0 = disabled",
    PlaceholderColor3=C.SUBTEXT,
    Text=ASE.CloakThreshold > 0 and tostring(ASE.CloakThreshold) or "",
    TextColor3=C.TEXT, TextSize=11,
    Size=UDim2.new(0,120,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=cloakRow,
})
addCorner(cloakInput, UDim.new(0,6)); addStroke(cloakInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=cloakInput})

cloakInput.FocusLost:Connect(function()
    ASE.CloakThreshold = tonumber(cloakInput.Text) or 0
    ASE_Save()
    GSE_Log("ASE", "Cloak threshold → " ..
            (ASE.CloakThreshold > 0 and tostring(ASE.CloakThreshold) or "disabled"))
end)

gseLabel(cloakRow, "(suppresses FireEconomyEvent source calls silently)", 10, false, C.SUBTEXT)

-- ============================================================
-- UI — SECTION: Suppression Rules
-- ============================================================
local _, sASESup = makeSection(pageGSE, "🚫  Suppression Rules")

gseLabel(sASESup,
    "Drop specific analytics calls before they reach the service.\n" ..
    "Match by method + argument index + pattern string.",
    11, false, C.SUBTEXT)

-- Rule list
local supRuleList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=false, Parent=sASESup,
})
addCorner(supRuleList, UDim.new(0,8)); addStroke(supRuleList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,3),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=supRuleList})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),
    PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=supRuleList})

local supEmpty = gseLabel(supRuleList, "No suppression rules defined.", 11, false, C.SUBTEXT)

local function ASE_RebuildSupRules()
    for _, ch in ipairs(supRuleList:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    local count = 0
    for i, rule in ipairs(ASE.SuppressionRules) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=i, Parent=supRuleList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})

        local function badge(text, bg)
            local b = mk("TextLabel",{BackgroundColor3=bg,BorderSizePixel=0,
                Font=Enum.Font.RobotoMono, Text=text, TextColor3=C.TEXT,
                TextSize=9, AutomaticSize=Enum.AutomaticSize.X,
                Size=UDim2.new(0,0,0,18), Parent=row})
            addCorner(b, UDim.new(0,4))
            mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),Parent=b})
        end

        badge(rule.method, C.ASE_SUP)
        badge("arg" .. rule.field, Color3.fromRGB(245,235,220))
        badge('"' .. rule.pattern .. '"', Color3.fromRGB(235,215,215))

        -- Delete button
        local idx = i
        local btnDel = mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(240,200,195),
            BorderSizePixel=0, Font=Enum.Font.GothamBold,
            Text="✕", TextColor3=Color3.fromRGB(160,40,40), TextSize=11,
            Size=UDim2.new(0,22,0,22), Parent=row,
        })
        addCorner(btnDel, UDim.new(0,6))
        btnDel.MouseButton1Click:Connect(function()
            table.remove(ASE.SuppressionRules, idx)
            ASE_Save(); ASE_RebuildSupRules()
            GSE_Log("ASE", "Suppression rule removed")
        end)
    end
    supEmpty.Visible = (count == 0)
end

ASE_RebuildSupRules()

-- Add rule form
local supAddRow = gseRow(sASESup)

local supMethodDropStr = {"ALL","FireCustomEvent","FireLogEvent",
                           "FireEconomyEvent","FireProgressionEvent"}
local supMethodIdx = 1

local btnSupMethod = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ASE_SUP, BorderSizePixel=0,
    Font=Enum.Font.GothamSemibold, Text=supMethodDropStr[supMethodIdx],
    TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,140,0,26), Parent=supAddRow,
})
addCorner(btnSupMethod, UDim.new(0,7)); addStroke(btnSupMethod, 1, 0.4)
btnSupMethod.MouseButton1Click:Connect(function()
    supMethodIdx = (supMethodIdx % #supMethodDropStr) + 1
    btnSupMethod.Text = supMethodDropStr[supMethodIdx]
end)

local supFieldInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="arg#",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,46,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=supAddRow,
})
addCorner(supFieldInput, UDim.new(0,6)); addStroke(supFieldInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=supFieldInput})

local supPatternInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="pattern",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,100,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=supAddRow,
})
addCorner(supPatternInput, UDim.new(0,6)); addStroke(supPatternInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=supPatternInput})

local btnAddSup = gseBtn(supAddRow, "+ Add Rule", C.ASE_SUP,
    Color3.fromRGB(248,210,210), 4)
btnAddSup.Size = UDim2.new(0,80,0,26)

btnAddSup.MouseButton1Click:Connect(function()
    local field   = supFieldInput.Text == "" and "ALL" or supFieldInput.Text
    local pattern = supPatternInput.Text
    if pattern == "" then GSE_Log("WARN", "Pattern cannot be empty"); return end
    table.insert(ASE.SuppressionRules, {
        method  = supMethodDropStr[supMethodIdx],
        field   = field,
        pattern = pattern,
    })
    ASE_Save(); ASE_RebuildSupRules()
    supFieldInput.Text = ""; supPatternInput.Text = ""
    GSE_Log("ASE", "Suppression rule added: " ..
            supMethodDropStr[supMethodIdx] ..
            " arg=" .. field .. " pattern=" .. pattern)
end)

-- ============================================================
-- UI — SECTION: Modification Rules
-- ============================================================
local _, sASEMod = makeSection(pageGSE, "✏️  Modification Rules")

gseLabel(sASEMod,
    "Rewrite specific argument values before the call fires.\n" ..
    "Active only in Modify mode. Pattern-matched, replacement applied.",
    11, false, C.SUBTEXT)

local modRuleList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=false, Parent=sASEMod,
})
addCorner(modRuleList, UDim.new(0,8)); addStroke(modRuleList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,3),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=modRuleList})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),
    PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=modRuleList})

local modEmpty = gseLabel(modRuleList, "No modification rules defined.", 11, false, C.SUBTEXT)

local function ASE_RebuildModRules()
    for _, ch in ipairs(modRuleList:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    local count = 0
    for i, rule in ipairs(ASE.ModRules) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=i, Parent=modRuleList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,5), Parent=row})

        local function badge(text, bg)
            local b = mk("TextLabel",{BackgroundColor3=bg,BorderSizePixel=0,
                Font=Enum.Font.RobotoMono, Text=text, TextColor3=C.TEXT,
                TextSize=9, AutomaticSize=Enum.AutomaticSize.X,
                Size=UDim2.new(0,0,0,18), Parent=row})
            addCorner(b, UDim.new(0,4))
            mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),Parent=b})
        end

        badge(rule.method, C.ASE_MOD)
        badge("arg" .. rule.field, Color3.fromRGB(230,238,250))
        badge('"' .. rule.pattern .. '"', Color3.fromRGB(220,230,248))
        gseLabel(row, "→", 10, true, C.SUBTEXT)
        badge('"' .. rule.replacement .. '"', Color3.fromRGB(210,240,215))

        local idx = i
        local btnDel = mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(240,200,195),
            BorderSizePixel=0, Font=Enum.Font.GothamBold,
            Text="✕", TextColor3=Color3.fromRGB(160,40,40), TextSize=11,
            Size=UDim2.new(0,22,0,22), Parent=row,
        })
        addCorner(btnDel, UDim.new(0,6))
        btnDel.MouseButton1Click:Connect(function()
            table.remove(ASE.ModRules, idx)
            ASE_Save(); ASE_RebuildModRules()
            GSE_Log("ASE", "Modification rule removed")
        end)
    end
    modEmpty.Visible = (count == 0)
end

ASE_RebuildModRules()

-- Add mod rule form
local modAddRow = gseRow(sASEMod)

local modMethodDropStr = {"ALL","FireCustomEvent","FireLogEvent",
                           "FireEconomyEvent","FireProgressionEvent"}
local modMethodIdx = 1

local btnModMethod = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ASE_MOD, BorderSizePixel=0,
    Font=Enum.Font.GothamSemibold, Text=modMethodDropStr[modMethodIdx],
    TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,140,0,26), Parent=modAddRow,
})
addCorner(btnModMethod, UDim.new(0,7)); addStroke(btnModMethod, 1, 0.4)
btnModMethod.MouseButton1Click:Connect(function()
    modMethodIdx = (modMethodIdx % #modMethodDropStr) + 1
    btnModMethod.Text = modMethodDropStr[modMethodIdx]
end)

local modFieldInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="arg#",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,40,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=modAddRow,
})
addCorner(modFieldInput, UDim.new(0,6)); addStroke(modFieldInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=modFieldInput})

local modPatternInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="match",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,80,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=modAddRow,
})
addCorner(modPatternInput, UDim.new(0,6)); addStroke(modPatternInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=modPatternInput})

local modReplInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="replace",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,80,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=modAddRow,
})
addCorner(modReplInput, UDim.new(0,6)); addStroke(modReplInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=modReplInput})

local btnAddMod = gseBtn(modAddRow, "+ Add", C.ASE_MOD,
    Color3.fromRGB(205,220,248), 5)
btnAddMod.Size = UDim2.new(0,60,0,26)

btnAddMod.MouseButton1Click:Connect(function()
    local field   = modFieldInput.Text == "" and "ALL" or modFieldInput.Text
    local pattern = modPatternInput.Text
    local repl    = modReplInput.Text
    if pattern == "" then GSE_Log("WARN", "Pattern cannot be empty"); return end
    if repl    == "" then GSE_Log("WARN", "Replacement cannot be empty"); return end
    table.insert(ASE.ModRules, {
        method      = modMethodDropStr[modMethodIdx],
        field       = field,
        pattern     = pattern,
        replacement = repl,
    })
    ASE_Save(); ASE_RebuildModRules()
    modFieldInput.Text = ""; modPatternInput.Text = ""; modReplInput.Text = ""
    GSE_Log("ASE", "Mod rule added: " ..
            modMethodDropStr[modMethodIdx] ..
            " arg=" .. field ..
            " \"" .. pattern .. "\" → \"" .. repl .. "\"")
end)

-- ============================================================
-- UI — SECTION: Economy Ledger
-- ============================================================
local _, sASELedger = makeSection(pageGSE, "💰  Economy Ledger")

gseLabel(sASELedger,
    "Built automatically from FireEconomyEvent calls. Shows every item SKU the\n" ..
    "game tracks, total gains (Source) and spends (Sink), and call count.",
    11, false, C.SUBTEXT)

local ledgerClearRow = gseRow(sASELedger)
local btnLedgerClear = gseBtn(ledgerClearRow, "🗑 Clear Ledger", C.BTN, C.BTNHOV, 1)
local ledgerCountLbl = gseLabel(ledgerClearRow, "0 items", 11, false, C.SUBTEXT)

-- Ledger table header
local ledgerHeader = mk("Frame",{BackgroundColor3=Color3.fromRGB(240,232,218),
    BorderSizePixel=0, Size=UDim2.new(1,-16,0,22), Parent=sASELedger})
addCorner(ledgerHeader, UDim.new(0,6))
mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal, Parent=ledgerHeader})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=ledgerHeader})

local function hdrCell(text, w)
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamBold,
        Text=text, TextColor3=C.SUBTEXT, TextSize=9,
        Size=UDim2.new(0,w,1,0), TextXAlignment=Enum.TextXAlignment.Left,
        Parent=ledgerHeader})
end

hdrCell("ITEM SKU",    160)
hdrCell("CURRENCY",    70)
hdrCell("▲ SOURCE",    80)
hdrCell("▼ SINK",      80)
hdrCell("NET",         70)
hdrCell("CALLS",       45)

-- Ledger scroll
local ledgerScroll = mk("ScrollingFrame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,160),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=5, ScrollingDirection=Enum.ScrollingDirection.Y,
    Parent=sASELedger,
})
addCorner(ledgerScroll, UDim.new(0,8)); addStroke(ledgerScroll, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=ledgerScroll})

local ledgerEmpty = mk("TextLabel",{BackgroundTransparency=1,
    Font=Enum.Font.Gotham, Text="  No economy events observed yet.",
    TextColor3=C.SUBTEXT, TextSize=11,
    Size=UDim2.new(1,0,0,30), TextXAlignment=Enum.TextXAlignment.Left,
    Parent=ledgerScroll})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=ledgerEmpty})

local ledgerRowRefs = {}  -- [sku] = row Frame ref

local function ASE_UpdateLedgerRow(sku, rec)
    local isNew = ledgerRowRefs[sku] == nil
    local net   = rec.totalSource - rec.totalSink
    local netPos = net >= 0

    if isNew then
        local count = 0
        for _ in pairs(ledgerRowRefs) do count = count + 1 end
        local row = mk("Frame",{
            BackgroundColor3 = count%2==0
                and Color3.fromRGB(252,248,242)
                or  Color3.fromRGB(246,240,232),
            BorderSizePixel=0,
            Size=UDim2.new(1,0,0,24), LayoutOrder=count+1, Parent=ledgerScroll})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal, Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=row})

        local function cell(text, w, color, mono)
            return mk("TextLabel",{BackgroundTransparency=1,
                Font=mono and Enum.Font.RobotoMono or Enum.Font.Gotham,
                Text=text, TextColor3=color or C.TEXT, TextSize=10,
                Size=UDim2.new(0,w,1,0),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        end

        cell(sku:sub(1,22), 160, C.TEXT, true)
        cell(rec.currency:sub(1,10), 70, C.SUBTEXT, false)
        local srcCell  = cell(tostring(rec.totalSource), 80, Color3.fromRGB(40,140,70), true)
        local sinkCell = cell(tostring(rec.totalSink),   80, Color3.fromRGB(180,60,60), true)
        local netCell  = cell((netPos and "+" or "") .. tostring(net), 70,
            netPos and Color3.fromRGB(40,140,70) or Color3.fromRGB(180,60,60), true)
        local cntCell  = cell(tostring(rec.count), 45, C.SUBTEXT, true)

        ledgerRowRefs[sku] = {
            row=row, srcCell=srcCell, sinkCell=sinkCell,
            netCell=netCell, cntCell=cntCell
        }
    else
        local refs = ledgerRowRefs[sku]
        refs.srcCell.Text  = tostring(rec.totalSource)
        refs.sinkCell.Text = tostring(rec.totalSink)
        refs.netCell.Text  = (netPos and "+" or "") .. tostring(net)
        refs.netCell.TextColor3 = netPos
            and Color3.fromRGB(40,140,70) or Color3.fromRGB(180,60,60)
        refs.cntCell.Text  = tostring(rec.count)
    end

    local itemCount = 0
    for _ in pairs(ledgerRowRefs) do itemCount = itemCount + 1 end
    ledgerCountLbl.Text = itemCount .. " item(s)"
    ledgerEmpty.Visible = (itemCount == 0)
end

-- Wire ledger callbacks
table.insert(ASE_LedgerCallbacks, function(sku, rec)
    ASE_UpdateLedgerRow(sku, rec)
end)

btnLedgerClear.MouseButton1Click:Connect(function()
    ASE.Ledger = {}
    for _, refs in pairs(ledgerRowRefs) do
        if refs.row and refs.row.Parent then refs.row:Destroy() end
    end
    ledgerRowRefs = {}
    ledgerCountLbl.Text = "0 items"
    ledgerEmpty.Visible = true
    GSE_Log("ASE", "Economy ledger cleared")
end)

-- Restore ledger from session
for sku, rec in pairs(ASE.Ledger) do
    ASE_UpdateLedgerRow(sku, rec)
end

-- ============================================================
-- UI — SECTION: Analytics Event Log
-- ============================================================
local _, sASELog = makeSection(pageGSE, "📋  Analytics Event Log")

gseLabel(sASELog,
    "Every intercepted Fire* call. Colour-coded by disposition:\n" ..
    "green = passthrough,  blue = modified,  red = suppressed.",
    11, false, C.SUBTEXT)

local aseLogTopRow = gseRow(sASELog)
local btnASEClear  = gseBtn(aseLogTopRow, "🗑 Clear", C.BTN, C.BTNHOV, 1)
btnASEClear.Size   = UDim2.new(0,80,0,24)
local aseLogCount  = gseLabel(aseLogTopRow, "0 events", 11, false, C.SUBTEXT)

local aseLogScroll = mk("ScrollingFrame",{
    BackgroundColor3=C.ASE_LOG,
    BorderSizePixel=0, Size=UDim2.new(1,-16,0,200),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=5, ScrollingDirection=Enum.ScrollingDirection.Y,
    Parent=sASELog,
})
addCorner(aseLogScroll, UDim.new(0,8))
mk("UIListLayout",{Padding=UDim.new(0,2),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=aseLogScroll})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingTop=UDim.new(0,6),
    PaddingBottom=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=aseLogScroll})

local aseLogRows  = {}
local aseLogOrder = 0

local function ASE_AddEventRow(entry)
    aseLogOrder = aseLogOrder + 1
    local row = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        LayoutOrder=aseLogOrder, Parent=aseLogScroll})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Top,
        Padding=UDim.new(0,5), Parent=row})

    -- Time
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
        Text=string.format("[%.1f]", entry.time),
        TextColor3=Color3.fromRGB(90,90,90), TextSize=9,
        Size=UDim2.new(0,46,0,16),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

    -- Disposition badge
    local dispColor = entry.suppressed
        and Color3.fromRGB(200,70,70)
        or (entry.modified
            and Color3.fromRGB(70,130,200)
            or  Color3.fromRGB(70,170,90))
    local dispText = entry.suppressed and "SUPP"
        or (entry.modified and "MOD" or "PASS")
    local dispBadge = mk("TextLabel",{
        BackgroundColor3=dispColor, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text=dispText,
        TextColor3=Color3.fromRGB(255,255,255), TextSize=8,
        Size=UDim2.new(0,36,0,14),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=row,
    })
    addCorner(dispBadge, UDim.new(0,4))

    -- Method badge
    local methodShort = entry.method
        :gsub("Fire",""):gsub("Event",""):sub(1,10)
    local methodBadge = mk("TextLabel",{
        BackgroundColor3=Color3.fromRGB(50,45,40), BorderSizePixel=0,
        Font=Enum.Font.RobotoMono, Text=methodShort,
        TextColor3=Color3.fromRGB(200,190,170), TextSize=8,
        AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=row,
    })
    addCorner(methodBadge, UDim.new(0,4))
    mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),
        Parent=methodBadge})

    -- Args summary
    local argStrs = {}
    for i, v in ipairs(entry.args) do
        if i > 1 then  -- skip player arg
            argStrs[#argStrs+1] = tostring(v):sub(1,20)
        end
        if #argStrs >= 4 then argStrs[#argStrs+1] = "..."; break end
    end
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
        Text=table.concat(argStrs, "  |  "),
        TextColor3=Color3.fromRGB(170,200,170), TextSize=9,
        AutomaticSize=Enum.AutomaticSize.XY, Size=UDim2.new(0,0,0,0),
        TextXAlignment=Enum.TextXAlignment.Left,
        TextWrapped=true, Parent=row})

    table.insert(aseLogRows, row)
    if #aseLogRows > 100 then
        local old = table.remove(aseLogRows, 1)
        if old and old.Parent then old:Destroy() end
    end

    aseLogCount.Text = #ASE.Events .. " event(s)"
end

-- Wire event callbacks to UI
table.insert(ASE_EventCallbacks, function(entry)
    ASE_AddEventRow(entry)
end)

btnASEClear.MouseButton1Click:Connect(function()
    ASE.Events = {}
    for _, r in ipairs(aseLogRows) do
        if r and r.Parent then r:Destroy() end
    end
    aseLogRows = {}; aseLogOrder = 0
    aseLogCount.Text = "0 events"
end)

-- Restore event log from session
for i = #ASE.Events, 1, -1 do ASE_AddEventRow(ASE.Events[i]) end

-- ============================================================
-- EXPORT ASE
-- ============================================================
_G.PC.ASE = ASE

-- EXPORT ASE
_G.PC.ASE = ASE
