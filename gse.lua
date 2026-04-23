-- ============================================================
-- gse.lua  —  Game Service Edit tab
-- Requires: _G.PC (backend) + _G.PCU (UI / pages)
--
-- Systems:
--   Products        — discovered dev product IDs + async info
--   GamePasses      — discovered game pass IDs + async info
--   Log             — timestamped event log (max 200 entries)
--   FireMode        — "RECEIPT" | "REMOTE"
--   SelectedRemote  — chosen PR Bridge remote for REMOTE mode
--   PurchaseRemotes — PR_Registry candidates (purchase keywords)
--
-- Session persistence: _G["PaperClay_GSE_v1"]
--
-- Scanner sources:
--   "namecall"       — __namecall hook on MPS method calls
--   "purchase_event" — PromptProductPurchaseFinished signal
--   "source_scan"    — LocalScript/ModuleScript text scan
--   "manual_prompt"  — user-triggered prompt button
-- ============================================================

local _C = _G.PC
local _U = _G.PCU

-- ── From _G.PC (backend helpers) ──────────────────────────────
local mk          = _C.mk
local addCorner   = _C.addCorner
local addStroke   = _C.addStroke
local tween       = _C.tween
local pulseClick  = _C.pulseClick
local hookHover   = _C.hookHover
local clickSound  = _C.clickSound

-- ── From _G.PCU (UI / pages) ──────────────────────────────────
local makeSection = _U.makeSection
local pageGSE     = _U.pageGSE

-- ============================================================
-- PERSIST
-- ============================================================
local GSE_PERSIST_KEY = "PaperClay_GSE_v1"

local GSE = {
    Products        = {},
    GamePasses      = {},
    Log             = {},
    FireMode        = "RECEIPT",
    SelectedRemote  = nil,
    PurchaseRemotes = {},
    Hooks           = {},
    InfoCache       = {},
}

local function GSE_Save()
    pcall(function()
        _G[GSE_PERSIST_KEY] = {
            Products       = GSE.Products,
            GamePasses     = GSE.GamePasses,
            FireMode       = GSE.FireMode,
            SelectedRemote = GSE.SelectedRemote,
        }
    end)
end

local function GSE_Load()
    pcall(function()
        local s = _G[GSE_PERSIST_KEY]
        if type(s) ~= "table" then return end
        if type(s.Products)       == "table" then GSE.Products       = s.Products       end
        if type(s.GamePasses)     == "table" then GSE.GamePasses     = s.GamePasses     end
        if type(s.FireMode)       == "string" then GSE.FireMode      = s.FireMode       end
        if type(s.SelectedRemote) == "string" then GSE.SelectedRemote = s.SelectedRemote end
    end)
end

GSE_Load()

-- ============================================================
-- LOGGING
-- ============================================================
local GSE_LogCallbacks = {}

local function GSE_Log(tag, msg)
    local entry = { time = os.clock(), tag = tag, msg = msg }
    table.insert(GSE.Log, 1, entry)
    if #GSE.Log > 200 then table.remove(GSE.Log) end
    for _, cb in ipairs(GSE_LogCallbacks) do pcall(cb, entry) end
end

-- ============================================================
-- MARKETPLACESERVICE
-- ============================================================
local MPS = game:GetService("MarketplaceService")

-- ── Async product info (cached) ───────────────────────────────
local function GSE_FetchInfo(id, productType, callback)
    id = tonumber(id)
    if not id then callback(nil); return end
    local cacheKey = (productType or "product") .. "_" .. id
    if GSE.InfoCache[cacheKey] ~= nil then
        callback(GSE.InfoCache[cacheKey]); return
    end
    task.spawn(function()
        local ok, info = pcall(function()
            return MPS:GetProductInfo(id,
                productType == "gamepass"
                    and Enum.InfoType.GamePass
                    or  Enum.InfoType.Product)
        end)
        if ok and info then
            local e = { name = info.Name or "Unknown", price = info.PriceInRobux or 0 }
            GSE.InfoCache[cacheKey] = e
            callback(e)
        else
            GSE.InfoCache[cacheKey] = false
            callback(nil)
        end
    end)
end

-- ── Register discovered product ───────────────────────────────
local function GSE_RegisterProduct(id, source)
    id = tostring(tonumber(id) or id)
    if GSE.Products[id] then return end
    GSE.Products[id] = { id=id, name="...", price=0,
                          source=source or "scan", firstSeen=os.clock() }
    GSE_Log("SCAN", "Product: " .. id .. "  [" .. (source or "scan") .. "]")
    GSE_Save()
    GSE_FetchInfo(id, "product", function(info)
        if info and GSE.Products[id] then
            GSE.Products[id].name  = info.name
            GSE.Products[id].price = info.price
            GSE_Log("INFO", "Product " .. id .. " = " ..
                    info.name .. "  (" .. info.price .. " R$)")
        end
    end)
end

local function GSE_RegisterGamePass(id, source)
    id = tostring(tonumber(id) or id)
    if GSE.GamePasses[id] then return end
    GSE.GamePasses[id] = { id=id, name="...", price=0,
                             source=source or "scan", firstSeen=os.clock() }
    GSE_Log("SCAN", "GamePass: " .. id .. "  [" .. (source or "scan") .. "]")
    GSE_Save()
    GSE_FetchInfo(id, "gamepass", function(info)
        if info and GSE.GamePasses[id] then
            GSE.GamePasses[id].name  = info.name
            GSE.GamePasses[id].price = info.price
            GSE_Log("INFO", "GamePass " .. id .. " = " .. info.name)
        end
    end)
end

-- ============================================================
-- __NAMECALL HOOK
-- Intercepts PromptProductPurchase / PromptGamePassPurchase
-- called by the game and auto-registers the IDs.
-- ============================================================
local function GSE_InstallNamecallHook()
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            if method == "PromptProductPurchase" then
                local args = {...}
                local pid = args[2] or args[1]
                if pid then pcall(GSE_RegisterProduct, tostring(pid), "namecall") end
            elseif method == "PromptGamePassPurchase" then
                local args = {...}
                local gpid = args[2] or args[1]
                if gpid then pcall(GSE_RegisterGamePass, tostring(gpid), "namecall") end
            end
            if oldNC then return oldNC(self, ...) end
        end
        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then GSE_Log("WARN", "Namecall hook failed: " .. tostring(err)) end
end

GSE_InstallNamecallHook()

-- ============================================================
-- PURCHASE EVENT LISTENERS
-- ============================================================
local GSE_PurchaseResultCallbacks = {}

table.insert(GSE.Hooks, MPS.PromptProductPurchaseFinished:Connect(
    function(_, id, bought)
        local idStr = tostring(id)
        GSE_Log("EVENT", "ProductPurchaseFinished  id=" .. idStr ..
                "  " .. (bought and "PURCHASED" or "CANCELLED"))
        if not GSE.Products[idStr] then GSE_RegisterProduct(idStr, "purchase_event") end
        for _, cb in ipairs(GSE_PurchaseResultCallbacks) do
            pcall(cb, id, bought, "product")
        end
    end))

table.insert(GSE.Hooks, MPS.PromptGamePassPurchaseFinished:Connect(
    function(_, id, bought)
        local idStr = tostring(id)
        GSE_Log("EVENT", "GamePassPurchaseFinished  id=" .. idStr ..
                "  " .. (bought and "PURCHASED" or "CANCELLED"))
        if not GSE.GamePasses[idStr] then GSE_RegisterGamePass(idStr, "purchase_event") end
        for _, cb in ipairs(GSE_PurchaseResultCallbacks) do
            pcall(cb, id, bought, "gamepass")
        end
    end))

table.insert(GSE.Hooks, MPS.PromptPremiumPurchaseFinished:Connect(
    function(p)
        GSE_Log("EVENT", "PremiumPurchaseFinished  membership="
                .. tostring(p.MembershipType))
        for _, cb in ipairs(GSE_PurchaseResultCallbacks) do
            pcall(cb, 0, p.MembershipType == Enum.MembershipType.Premium, "premium")
        end
    end))

-- ============================================================
-- SIGNAL METHODS
-- ============================================================
local function GSE_SignalViaReceipt(productId, success)
    local cb = MPS.ProcessReceipt
    if type(cb) ~= "function" then
        GSE_Log("WARN", "No ProcessReceipt callback registered by this game"); return
    end
    local receiptInfo = {
        PlayerId              = game:GetService("Players").LocalPlayer.UserId,
        PlaceIdWherePurchased = game.PlaceId,
        PurchaseId            = "GSE_" .. tostring(os.clock()):gsub("%.", ""),
        ProductId             = tonumber(productId),
        CurrencySpent         = 0,
        CurrencyType          = Enum.CurrencyType.Robux,
    }
    local ok, result = pcall(cb, receiptInfo)
    if ok then
        GSE_Log("SIGNAL", "ProcessReceipt → " .. tostring(result) ..
                "  (id=" .. tostring(productId) .. ")")
    else
        GSE_Log("WARN", "ProcessReceipt error: " .. tostring(result))
    end
end

local function GSE_SignalViaRemote(productId, purchased)
    local remoteName = GSE.SelectedRemote
    if not remoteName then
        GSE_Log("WARN", "No purchase remote selected"); return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry"); return
    end
    local ok, err = pcall(function()
        if rec.RemoteType == "RemoteFunction" then
            rec.Remote:InvokeServer(tonumber(productId), purchased)
        else
            rec.Remote:FireServer(tonumber(productId), purchased)
        end
    end)
    if ok then
        GSE_Log("SIGNAL", "Fired " .. remoteName ..
                "  id=" .. tostring(productId) ..
                "  purchased=" .. tostring(purchased))
    else
        GSE_Log("WARN", "Remote fire failed: " .. tostring(err))
    end
end

-- ============================================================
-- WORKSPACE SOURCE SCAN
-- ============================================================
local function GSE_ScanWorkspaceForIds()
    local found = 0
    local function scanScript(s)
        local ok, src = pcall(function() return s.Source end)
        if not ok or type(src) ~= "string" then return end
        for id in src:gmatch("PromptProductPurchase%s*%([^,]+,%s*(%d+)") do
            GSE_RegisterProduct(id, "source_scan"); found = found + 1
        end
        for id in src:gmatch("PromptGamePassPurchase%s*%([^,]+,%s*(%d+)") do
            GSE_RegisterGamePass(id, "source_scan"); found = found + 1
        end
        for id in src:gmatch("[Pp]roduct[Ii]d%s*[=:]%s*(%d%d%d+)") do
            GSE_RegisterProduct(id, "source_scan"); found = found + 1
        end
    end
    local roots = {
        game:GetService("Players").LocalPlayer:FindFirstChild("PlayerScripts"),
        game:GetService("ReplicatedStorage"),
    }
    for _, root in ipairs(roots) do
        if root then
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
                    pcall(scanScript, desc)
                end
            end
        end
    end
    GSE_Log("SCAN", "Script scan done — " .. found .. " id(s) extracted")
end

-- ============================================================
-- PR BRIDGE SCAN
-- ============================================================
local GSE_PURCHASE_KEYWORDS = {
    "purchase","buy","product","receipt","shop",
    "store","payment","robux","market","checkout",
    "order","item","gamepass","pass","cash",
}

local function GSE_ScanPRForPurchaseRemotes()
    local reg = _G.PC and _G.PC.PR_Registry
    if not reg then
        GSE_Log("WARN", "PR_Registry not available yet"); return
    end
    GSE.PurchaseRemotes = {}
    for name in pairs(reg) do
        local lower = name:lower()
        for _, kw in ipairs(GSE_PURCHASE_KEYWORDS) do
            if lower:find(kw, 1, true) then
                table.insert(GSE.PurchaseRemotes, name); break
            end
        end
    end
    table.sort(GSE.PurchaseRemotes)
    GSE_Log("SCAN", "PR Bridge: " .. #GSE.PurchaseRemotes ..
            " purchase remote(s) found")
end

task.delay(2, GSE_ScanPRForPurchaseRemotes)

-- ============================================================
-- UI HELPERS (local, consistent with Paper Cuts cream theme)
-- ============================================================
local C = {
    BTN     = Color3.fromRGB(236,229,219),
    BTNHOV  = Color3.fromRGB(252,246,238),
    TEXT    = Color3.fromRGB(46,42,38),
    SUBTEXT = Color3.fromRGB(120,112,100),
    SUCCESS = Color3.fromRGB(220,240,225),
    FAIL    = Color3.fromRGB(248,225,220),
    BLUE    = Color3.fromRGB(210,225,245),
    GP      = Color3.fromRGB(225,235,250),
    CHIP    = Color3.fromRGB(235,225,210),
    INPUT   = Color3.fromRGB(245,239,231),
    LOG_BG  = Color3.fromRGB(240,234,226),
}

local TAG_COLORS = {
    EVENT  = Color3.fromRGB(80,160,100),
    SCAN   = Color3.fromRGB(80,120,200),
    SIGNAL = Color3.fromRGB(180,100,50),
    PROMPT = Color3.fromRGB(140,80,180),
    INFO   = Color3.fromRGB(110,110,110),
    WARN   = Color3.fromRGB(200,80,60),
    MODE   = Color3.fromRGB(60,130,180),
}

local function gseBtn(parent, text, bg, hov, lo)
    bg = bg or C.BTN; hov = hov or C.BTNHOV
    local b = mk("TextButton",{
        AutoButtonColor=false, BackgroundColor3=bg, BorderSizePixel=0,
        Font=Enum.Font.GothamSemibold, Text=text, TextColor3=C.TEXT,
        TextSize=11, Size=UDim2.new(0,120,0,28), LayoutOrder=lo or 0,
        Parent=parent,
    })
    addCorner(b, UDim.new(0,8)); addStroke(b, 1, 0.4)
    hookHover(b, bg, hov, 0.4, 0.2)
    b.MouseButton1Click:Connect(function() pulseClick(b); clickSound() end)
    return b
end

local function gseLabel(parent, text, size, bold, color)
    return mk("TextLabel",{
        BackgroundTransparency=1,
        Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham,
        Text=text, TextColor3=color or C.TEXT, TextSize=size or 12,
        TextXAlignment=Enum.TextXAlignment.Left,
        AutomaticSize=Enum.AutomaticSize.XY, Parent=parent,
    })
end

local function gseInput(parent, placeholder, lo)
    local b = mk("TextBox",{
        BackgroundColor3=C.INPUT, BorderSizePixel=0,
        Font=Enum.Font.Gotham, PlaceholderText=placeholder or "",
        PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT,
        TextSize=11, Size=UDim2.new(1,-16,0,26),
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=lo or 0, ClearTextOnFocus=false, Parent=parent,
    })
    addCorner(b, UDim.new(0,7)); addStroke(b, 1, 0.45)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=b})
    return b
end

local function gseRow(parent, lo)
    local f = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,-16,0,32), AutomaticSize=Enum.AutomaticSize.Y,
        LayoutOrder=lo or 0, Parent=parent})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,8), Parent=f})
    return f
end

local function gseHScroll(parent, h)
    local s = mk("ScrollingFrame",{
        BackgroundColor3=C.INPUT, BorderSizePixel=0,
        Size=UDim2.new(1,-16,0,h or 52),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.X,
        ScrollBarThickness=4, ScrollingDirection=Enum.ScrollingDirection.X,
        Parent=parent,
    })
    addCorner(s, UDim.new(0,8)); addStroke(s, 1, 0.4)
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Center,
        Padding=UDim.new(0,6), Parent=s})
    mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=s})
    return s
end

local function gseChip(parent, text, bg, callback)
    local c = mk("TextButton",{
        AutoButtonColor=false, BackgroundColor3=bg or C.CHIP,
        BorderSizePixel=0, Font=Enum.Font.GothamSemibold, Text=text,
        TextColor3=C.TEXT, TextSize=10,
        AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,36),
        Parent=parent,
    })
    addCorner(c, UDim.new(0,8)); addStroke(c, 1, 0.5)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),Parent=c})
    hookHover(c, c.BackgroundColor3, C.BTNHOV, 0.5, 0.2)
    if callback then
        c.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(c); callback(c)
        end)
    end
    return c
end

-- ============================================================
-- SECTION 1: Developer Products — Scanner
-- ============================================================
local _, sScan = makeSection(pageGSE, "⚙  Developer Products — Scanner")
gseLabel(sScan,
    "Auto-detects product IDs via namecall hook, source scan, and purchase events.",
    11, false, C.SUBTEXT)

local scanRow   = gseRow(sScan)
local btnScanWS    = gseBtn(scanRow, "🔍 Scan Scripts",   C.BTN, C.BTNHOV, 1)
local btnScanPR    = gseBtn(scanRow, "🔗 Scan PR Bridge", C.BTN, C.BTNHOV, 2)
local btnClearProd = gseBtn(scanRow, "✕ Clear List",      C.BTN, C.BTNHOV, 3)

local prodList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=true, Parent=sScan,
})
addCorner(prodList, UDim.new(0,8)); addStroke(prodList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0), SortOrder=Enum.SortOrder.LayoutOrder, Parent=prodList})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=prodList})

local prodEmpty = gseLabel(prodList, "  No products discovered yet.", 11, false, C.SUBTEXT)
prodEmpty.Size = UDim2.new(1,0,0,26)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=prodEmpty})

local prodNameRefs = {}

local function GSE_RebuildProductList()
    for _, ref in pairs(prodNameRefs) do
        if ref and ref.Parent and ref.Parent.Parent == prodList then
            ref.Parent:Destroy()
        end
    end
    prodNameRefs = {}
    local count = 0
    for id, entry in pairs(GSE.Products) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,26), LayoutOrder=count, Parent=prodList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),Parent=row})
        local idBadge = mk("TextLabel",{
            BackgroundColor3=C.CHIP, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text=id, TextColor3=C.TEXT, TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,18), Parent=row,
        })
        addCorner(idBadge, UDim.new(0,4))
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5),Parent=idBadge})
        local nameRef = mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.Gotham,
            Text=entry.name .. (entry.price>0 and ("  —  "..entry.price.." R$") or ""),
            TextColor3=C.TEXT, TextSize=11, AutomaticSize=Enum.AutomaticSize.X,
            Size=UDim2.new(0,0,0,18), TextXAlignment=Enum.TextXAlignment.Left,
            Parent=row,
        })
        mk("TextLabel",{
            BackgroundColor3=Color3.fromRGB(220,240,225), BorderSizePixel=0,
            Font=Enum.Font.Gotham, Text=entry.source, TextColor3=C.SUBTEXT, TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,16), Parent=row,
        })
        prodNameRefs[id] = nameRef
    end
    prodEmpty.Visible = (count == 0)
end

GSE_RebuildProductList()

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "INFO" then
        for id, rec in pairs(GSE.Products) do
            if prodNameRefs[id] then
                prodNameRefs[id].Text =
                    rec.name .. (rec.price>0 and ("  —  "..rec.price.." R$") or "")
            end
        end
    end
    if entry.tag == "SCAN" then GSE_RebuildProductList() end
end)

btnScanWS.MouseButton1Click:Connect(function()
    btnScanWS.Text = "⏳ Scanning..."
    task.spawn(function()
        GSE_ScanWorkspaceForIds()
        task.wait(0.3); btnScanWS.Text = "🔍 Scan Scripts"
    end)
end)

btnScanPR.MouseButton1Click:Connect(function()
    btnScanPR.Text = "⏳ Scanning..."
    task.spawn(function()
        GSE_ScanPRForPurchaseRemotes()
        task.wait(0.3); btnScanPR.Text = "🔗 Scan PR Bridge"
    end)
end)

btnClearProd.MouseButton1Click:Connect(function()
    GSE.Products = {}; GSE_Save(); GSE_RebuildProductList()
    GSE_Log("INFO", "Product list cleared")
end)

-- ============================================================
-- SECTION 2: Product — Prompt & Signal
-- ============================================================
local _, sAct = makeSection(pageGSE, "🎯  Product — Prompt & Signal")
gseLabel(sAct, "Type a product ID or pick from the scanner, then prompt or signal a result.",
    11, false, C.SUBTEXT)

local prodIdInput = gseInput(sAct, "Product ID (numeric)", 1)

gseLabel(sAct, "Quick-pick from scanner:", 11, false, C.SUBTEXT)
local prodPickScroll = gseHScroll(sAct, 52)

local function GSE_RebuildProdQuickPick()
    for _, ch in ipairs(prodPickScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    local any = false
    for id, entry in pairs(GSE.Products) do
        any = true
        gseChip(prodPickScroll,
            id .. (entry.name ~= "..." and ("  " .. entry.name) or ""),
            C.CHIP, function() prodIdInput.Text = id end)
    end
    if not any then
        gseLabel(prodPickScroll, "  Scan first.", 11, false, C.SUBTEXT)
    end
end

GSE_RebuildProdQuickPick()

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "SCAN" then GSE_RebuildProdQuickPick() end
end)

local actRow    = gseRow(sAct)
local btnPrompt  = gseBtn(actRow, "💳 Prompt",         C.BTN,    C.BTNHOV,                    1)
local btnSuccess = gseBtn(actRow, "✅ Signal Success", C.SUCCESS, Color3.fromRGB(200,235,210), 2)
local btnFail    = gseBtn(actRow, "❌ Signal Fail",    C.FAIL,   Color3.fromRGB(240,210,205),  3)

btnPrompt.MouseButton1Click:Connect(function()
    local id = tonumber(prodIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid product ID"); return end
    local ok, err = pcall(function()
        MPS:PromptProductPurchase(game:GetService("Players").LocalPlayer, id)
    end)
    if ok then
        GSE_Log("PROMPT", "PromptProductPurchase(" .. id .. ") called")
        GSE_RegisterProduct(tostring(id), "manual_prompt")
    else GSE_Log("WARN", "Prompt failed: " .. tostring(err)) end
end)

btnSuccess.MouseButton1Click:Connect(function()
    local id = tonumber(prodIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid product ID"); return end
    if GSE.FireMode == "RECEIPT" then GSE_SignalViaReceipt(id, true)
    else GSE_SignalViaRemote(id, true) end
end)

btnFail.MouseButton1Click:Connect(function()
    local id = tonumber(prodIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid product ID"); return end
    if GSE.FireMode == "RECEIPT" then GSE_SignalViaReceipt(id, false)
    else GSE_SignalViaRemote(id, false) end
end)

-- ============================================================
-- SECTION 3: Signal Mode
-- ============================================================
local _, sMode = makeSection(pageGSE, "📡  Signal Mode")
gseLabel(sMode,
    "ProcessReceipt — calls the game's server receipt callback with a spoofed receipt.\n"
    .. "Remote Fire   — fires through a selected PR Bridge purchase remote.",
    11, false, C.SUBTEXT)

local modeRow = gseRow(sMode)
local btnModeReceipt = gseBtn(modeRow, "ProcessReceipt",
    GSE.FireMode == "RECEIPT" and Color3.fromRGB(210,230,215) or C.BTN, C.BTNHOV, 1)
local btnModeRemote  = gseBtn(modeRow, "Remote Fire",
    GSE.FireMode == "REMOTE"  and C.BLUE or C.BTN, C.BTNHOV, 2)
local modeLabel = gseLabel(modeRow, "Active: " .. GSE.FireMode, 11, true, C.SUBTEXT)

local function GSE_SetMode(mode)
    GSE.FireMode = mode; GSE_Save()
    modeLabel.Text = "Active: " .. mode
    tween(btnModeReceipt, TweenInfo.new(0.12), {
        BackgroundColor3 = mode=="RECEIPT" and Color3.fromRGB(210,230,215) or C.BTN })
    tween(btnModeRemote,  TweenInfo.new(0.12), {
        BackgroundColor3 = mode=="REMOTE"  and C.BLUE or C.BTN })
    GSE_Log("MODE", "Signal mode → " .. mode)
end

btnModeReceipt.MouseButton1Click:Connect(function() GSE_SetMode("RECEIPT") end)
btnModeRemote.MouseButton1Click:Connect(function()  GSE_SetMode("REMOTE")  end)

gseLabel(sMode, "Purchase remotes from PR Bridge:", 11, false, C.SUBTEXT)
local remoteScroll   = gseHScroll(sMode, 52)
local remoteChipRefs = {}

local function GSE_RebuildRemoteChips()
    for _, ch in ipairs(remoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    remoteChipRefs = {}
    if #GSE.PurchaseRemotes == 0 then
        gseLabel(remoteScroll,
            "  No purchase remotes found — run Scan PR Bridge.", 11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(GSE.PurchaseRemotes) do
        local isSel = (GSE.SelectedRemote == name)
        local chip = gseChip(remoteScroll, name, isSel and C.BLUE or C.CHIP)
        remoteChipRefs[name] = chip
        chip.MouseButton1Click:Connect(function()
            GSE.SelectedRemote = name; GSE_Save()
            GSE_Log("MODE", "Selected remote: " .. name)
            for n, c in pairs(remoteChipRefs) do
                tween(c, TweenInfo.new(0.1), {
                    BackgroundColor3 = (n == name) and C.BLUE or C.CHIP })
            end
        end)
    end
end

GSE_RebuildRemoteChips()

local rescanRow = gseRow(sMode)
local btnRescan = gseBtn(rescanRow, "↻ Rescan PR Bridge", C.BTN, C.BTNHOV, 1)
btnRescan.MouseButton1Click:Connect(function()
    btnRescan.Text = "⏳ Scanning..."
    task.spawn(function()
        GSE_ScanPRForPurchaseRemotes(); GSE_RebuildRemoteChips()
        task.wait(0.3); btnRescan.Text = "↻ Rescan PR Bridge"
    end)
end)

-- ============================================================
-- SECTION 4: Game Passes
-- ============================================================
local _, sGP = makeSection(pageGSE, "🎫  Game Passes")
gseLabel(sGP, "Prompt, signal, or check ownership of game passes.", 11, false, C.SUBTEXT)

local gpIdInput    = gseInput(sGP, "Game Pass ID (numeric)", 1)

gseLabel(sGP, "Quick-pick from scanner:", 11, false, C.SUBTEXT)
local gpPickScroll = gseHScroll(sGP, 52)

local function GSE_RebuildGPQuickPick()
    for _, ch in ipairs(gpPickScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    local any = false
    for id, entry in pairs(GSE.GamePasses) do
        any = true
        gseChip(gpPickScroll,
            id .. (entry.name ~= "..." and ("  " .. entry.name) or ""),
            C.GP, function() gpIdInput.Text = id end)
    end
    if not any then
        gseLabel(gpPickScroll, "  No game passes discovered yet.", 11, false, C.SUBTEXT)
    end
end

GSE_RebuildGPQuickPick()

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "SCAN" then GSE_RebuildGPQuickPick() end
end)

local gpRow = gseRow(sGP)
local btnGPPrompt  = gseBtn(gpRow, "🎫 Prompt",         C.BTN,    C.BTNHOV,                    1)
local btnGPSuccess = gseBtn(gpRow, "✅ Signal Success", C.SUCCESS, Color3.fromRGB(200,235,210), 2)
local btnGPFail    = gseBtn(gpRow, "❌ Signal Fail",    C.FAIL,   Color3.fromRGB(240,210,205),  3)
local btnGPCheck   = gseBtn(gpRow, "🔍 Check Owned",    C.BTN,    C.BTNHOV,                    4)
local gpStatusLabel = gseLabel(sGP, "", 11, false, C.SUBTEXT)

btnGPPrompt.MouseButton1Click:Connect(function()
    local id = tonumber(gpIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid game pass ID"); return end
    local ok, err = pcall(function()
        MPS:PromptGamePassPurchase(game:GetService("Players").LocalPlayer, id)
    end)
    if ok then
        GSE_Log("PROMPT", "PromptGamePassPurchase(" .. id .. ") called")
        GSE_RegisterGamePass(tostring(id), "manual_prompt")
    else GSE_Log("WARN", "GP Prompt failed: " .. tostring(err)) end
end)

btnGPSuccess.MouseButton1Click:Connect(function()
    local id = tonumber(gpIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid game pass ID"); return end
    if GSE.FireMode == "RECEIPT" then GSE_SignalViaReceipt(id, true)
    else GSE_SignalViaRemote(id, true) end
end)

btnGPFail.MouseButton1Click:Connect(function()
    local id = tonumber(gpIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid game pass ID"); return end
    if GSE.FireMode == "RECEIPT" then GSE_SignalViaReceipt(id, false)
    else GSE_SignalViaRemote(id, false) end
end)

btnGPCheck.MouseButton1Click:Connect(function()
    local id = tonumber(gpIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid game pass ID"); return end
    task.spawn(function()
        local ok, owned = pcall(function()
            return MPS:UserOwnsGamePassAsync(
                game:GetService("Players").LocalPlayer.UserId, id)
        end)
        if ok then
            gpStatusLabel.Text = "Pass " .. id .. ": " ..
                (owned and "✅ Owned" or "❌ Not owned")
            GSE_Log("INFO", "GamePass " .. id .. " owned=" .. tostring(owned))
        else
            gpStatusLabel.Text = "Check failed"
            GSE_Log("WARN", "Ownership check: " .. tostring(owned))
        end
    end)
end)

-- ============================================================
-- SECTION 5: Premium
-- ============================================================
local _, sPrem   = makeSection(pageGSE, "💎  Premium")
local premStatus = gseLabel(sPrem, "Membership: checking...", 12, false, C.SUBTEXT)
local premRow    = gseRow(sPrem)
local btnPremPrompt = gseBtn(premRow, "💎 Prompt Premium", C.BTN, C.BTNHOV, 1)
local btnPremCheck  = gseBtn(premRow, "🔍 Check Status",   C.BTN, C.BTNHOV, 2)

local function GSE_RefreshPremium()
    local lp     = game:GetService("Players").LocalPlayer
    local isPrem = lp.MembershipType == Enum.MembershipType.Premium
    premStatus.Text = "Local player Premium: " ..
        (isPrem and "✅ Yes" or "❌ No") ..
        "   (MembershipType: " .. tostring(lp.MembershipType) .. ")"
end

GSE_RefreshPremium()

btnPremPrompt.MouseButton1Click:Connect(function()
    local ok, err = pcall(function()
        MPS:PromptPremiumPurchase(game:GetService("Players").LocalPlayer)
    end)
    if ok then GSE_Log("PROMPT", "PromptPremiumPurchase called")
    else GSE_Log("WARN", "Premium prompt failed: " .. tostring(err)) end
end)

btnPremCheck.MouseButton1Click:Connect(function()
    GSE_RefreshPremium()
    GSE_Log("INFO", "Premium checked: " ..
        tostring(game:GetService("Players").LocalPlayer.MembershipType))
end)

table.insert(GSE_PurchaseResultCallbacks, function(_, _, ptype)
    if ptype == "premium" then task.delay(0.5, GSE_RefreshPremium) end
end)

-- ============================================================
-- SECTION 6: Event Log
-- ============================================================
local _, sLog   = makeSection(pageGSE, "📋  Event Log")
local logTopRow = gseRow(sLog)
local btnClearLog = gseBtn(logTopRow, "🗑 Clear Log", C.BTN, C.BTNHOV, 1)
btnClearLog.Size = UDim2.new(0,90,0,24)

local logScroller = mk("ScrollingFrame",{
    BackgroundColor3=C.LOG_BG, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,180),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=5, ScrollingDirection=Enum.ScrollingDirection.Y,
    Parent=sLog,
})
addCorner(logScroller, UDim.new(0,8)); addStroke(logScroller, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,2), SortOrder=Enum.SortOrder.LayoutOrder, Parent=logScroller})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingTop=UDim.new(0,4),
    PaddingBottom=UDim.new(0,4),PaddingRight=UDim.new(0,8),Parent=logScroller})

local logRows  = {}
local logOrder = 0

local function GSE_AddLogRow(entry)
    logOrder = logOrder + 1
    local row = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        LayoutOrder=logOrder, Parent=logScroller})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Top,
        Padding=UDim.new(0,5), Parent=row})
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamMono,
        Text=string.format("[%.1f]", entry.time), TextColor3=C.SUBTEXT, TextSize=9,
        Size=UDim2.new(0,46,0,16), TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
    local tagColor = TAG_COLORS[entry.tag] or C.SUBTEXT
    local tagLbl = mk("TextLabel",{
        BackgroundColor3=tagColor, BorderSizePixel=0,
        Font=Enum.Font.GothamBold, Text=entry.tag,
        TextColor3=Color3.fromRGB(255,255,255), TextSize=8,
        Size=UDim2.new(0,46,0,14), TextXAlignment=Enum.TextXAlignment.Center,
        Parent=row,
    })
    addCorner(tagLbl, UDim.new(0,4))
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.Gotham,
        Text=entry.msg, TextColor3=C.TEXT, TextSize=10,
        AutomaticSize=Enum.AutomaticSize.XY, Size=UDim2.new(0,0,0,0),
        TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true, Parent=row})
    table.insert(logRows, row)
    if #logRows > 100 then
        local old = table.remove(logRows, 1)
        if old and old.Parent then old:Destroy() end
    end
end

table.insert(GSE_LogCallbacks, function(entry) GSE_AddLogRow(entry) end)

btnClearLog.MouseButton1Click:Connect(function()
    GSE.Log = {}
    for _, r in ipairs(logRows) do if r and r.Parent then r:Destroy() end end
    logRows = {}; logOrder = 0
end)

for i = #GSE.Log, 1, -1 do GSE_AddLogRow(GSE.Log[i]) end


-- ============================================================
-- BADGE SERVICE EDIT (BSE)
-- ============================================================

-- ── State ─────────────────────────────────────────────────────
local BSE = {
    Badges        = {},  -- [id] = { id, name, description, enabled, source, firstSeen }
    AwardRemotes  = {},  -- PR_Registry candidates matching badge keywords
    InfoCache     = {},  -- [id] = { name, description, enabled } | false
    SelectedRemote= nil,
}

-- Persist BSE inside the existing GSE persist key
local function BSE_Save()
    pcall(function()
        local saved = _G[GSE_PERSIST_KEY] or {}
        saved.BSE_Badges         = BSE.Badges
        saved.BSE_SelectedRemote = BSE.SelectedRemote
        _G[GSE_PERSIST_KEY]      = saved
    end)
end

local function BSE_Load()
    pcall(function()
        local s = _G[GSE_PERSIST_KEY]
        if type(s) ~= "table" then return end
        if type(s.BSE_Badges)         == "table"  then BSE.Badges         = s.BSE_Badges         end
        if type(s.BSE_SelectedRemote) == "string" then BSE.SelectedRemote = s.BSE_SelectedRemote end
    end)
end

BSE_Load()

-- ── BadgeService reference ────────────────────────────────────
local BadgeSvc = game:GetService("BadgeService")

-- ── Async badge info fetch (cached) ──────────────────────────
local function BSE_FetchInfo(id, callback)
    id = tonumber(id)
    if not id then callback(nil); return end
    if BSE.InfoCache[id] ~= nil then callback(BSE.InfoCache[id]); return end
    task.spawn(function()
        local ok, info = pcall(function()
            return BadgeSvc:GetBadgeInfoAsync(id)
        end)
        if ok and info then
            local e = {
                name        = info.Name        or "Unknown",
                description = info.Description or "",
                enabled     = info.IsEnabled   ~= false,
            }
            BSE.InfoCache[id] = e
            callback(e)
        else
            BSE.InfoCache[id] = false
            callback(nil)
        end
    end)
end

-- ── Register a discovered badge ID ───────────────────────────
local BSE_NameRefs = {}  -- [id] = TextLabel ref for live updates

local function BSE_RegisterBadge(id, source)
    id = tostring(tonumber(id) or id)
    if BSE.Badges[id] then return end
    BSE.Badges[id] = {
        id          = id,
        name        = "...",
        description = "",
        enabled     = true,
        source      = source or "scan",
        firstSeen   = os.clock(),
    }
    GSE_Log("BADGE", "Badge discovered: " .. id .. "  [" .. (source or "scan") .. "]")
    BSE_Save()
    BSE_FetchInfo(id, function(info)
        if info and BSE.Badges[id] then
            BSE.Badges[id].name        = info.name
            BSE.Badges[id].description = info.description
            BSE.Badges[id].enabled     = info.enabled
            GSE_Log("INFO", "Badge " .. id .. " = " .. info.name ..
                    (info.enabled and "" or "  [DISABLED]"))
            -- Update name label if rendered
            if BSE_NameRefs[id] then
                BSE_NameRefs[id].Text =
                    info.name .. (info.enabled and "" or "  ⛔")
            end
        end
    end)
end

-- ── Namecall hook extension ───────────────────────────────────
-- Extends the existing GSE namecall hook to also intercept
-- BadgeService:AwardBadge and BadgeService:UserHasBadgeAsync
-- calls the game makes, auto-registering badge IDs.
local function BSE_InstallNamecallHook()
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            if method == "AwardBadge" then
                local args = {...}
                -- AwardBadge(userId, badgeId) — badgeId is arg 2 or 1
                local bid = args[2] or args[1]
                if bid then pcall(BSE_RegisterBadge, tostring(bid), "namecall") end
            elseif method == "UserHasBadgeAsync" or method == "HasBadge" then
                local args = {...}
                local bid = args[2] or args[1]
                if bid then pcall(BSE_RegisterBadge, tostring(bid), "namecall") end
            end
            if oldNC then return oldNC(self, ...) end
        end
        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then
        GSE_Log("WARN", "BSE namecall hook failed: " .. tostring(err))
    end
end

BSE_InstallNamecallHook()

-- ── Script source scan ────────────────────────────────────────
local function BSE_ScanWorkspaceForIds()
    local found = 0
    local function scanScript(s)
        local ok, src = pcall(function() return s.Source end)
        if not ok or type(src) ~= "string" then return end
        -- AwardBadge(userId, DIGITS)
        for id in src:gmatch("AwardBadge%s*%([^,]+,%s*(%d+)") do
            BSE_RegisterBadge(id, "source_scan"); found = found + 1
        end
        -- UserHasBadgeAsync(userId, DIGITS)
        for id in src:gmatch("UserHasBadgeAsync%s*%([^,]+,%s*(%d+)") do
            BSE_RegisterBadge(id, "source_scan"); found = found + 1
        end
        -- badgeId = DIGITS or badgeId: DIGITS
        for id in src:gmatch("[Bb]adge[Ii]d%s*[=:]%s*(%d%d%d+)") do
            BSE_RegisterBadge(id, "source_scan"); found = found + 1
        end
        -- BADGE_ID = DIGITS (common naming convention)
        for id in src:gmatch("BADGE[_]?ID%s*=%s*(%d%d%d+)") do
            BSE_RegisterBadge(id, "source_scan"); found = found + 1
        end
    end
    local roots = {
        game:GetService("Players").LocalPlayer:FindFirstChild("PlayerScripts"),
        game:GetService("ReplicatedStorage"),
    }
    for _, root in ipairs(roots) do
        if root then
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
                    pcall(scanScript, desc)
                end
            end
        end
    end
    GSE_Log("BADGE", "Badge script scan — " .. found .. " id(s) found")
end

-- ── PR Bridge scan ────────────────────────────────────────────
local BSE_BADGE_KEYWORDS = {
    "badge","award","achievement","trophy","unlock",
    "earn","reward","medal","complete","milestone",
}

local function BSE_ScanPRForAwardRemotes()
    local reg = _G.PC and _G.PC.PR_Registry
    if not reg then
        GSE_Log("WARN", "PR_Registry not available"); return
    end
    BSE.AwardRemotes = {}
    for name in pairs(reg) do
        local lower = name:lower()
        for _, kw in ipairs(BSE_BADGE_KEYWORDS) do
            if lower:find(kw, 1, true) then
                table.insert(BSE.AwardRemotes, name)
                break
            end
        end
    end
    table.sort(BSE.AwardRemotes)
    GSE_Log("BADGE", "PR Bridge: " .. #BSE.AwardRemotes ..
            " badge-related remote(s) found")
end

task.delay(2.5, BSE_ScanPRForAwardRemotes)

-- ── Award via remote ──────────────────────────────────────────
-- Fires the selected PR Bridge remote with the badge ID.
-- Most games fire AwardBadge(player.UserId, badgeId) server-side
-- after receiving a client signal — we replicate that signal here.
local function BSE_AwardViaRemote(badgeId)
    local remoteName = BSE.SelectedRemote
    if not remoteName then
        GSE_Log("WARN", "No badge remote selected"); return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry"); return
    end
    local ok, err = pcall(function()
        if rec.RemoteType == "RemoteFunction" then
            rec.Remote:InvokeServer(tonumber(badgeId))
        else
            rec.Remote:FireServer(tonumber(badgeId))
        end
    end)
    if ok then
        GSE_Log("SIGNAL", "Fired " .. remoteName ..
                "  badgeId=" .. tostring(badgeId))
    else
        GSE_Log("WARN", "Badge remote fire failed: " .. tostring(err))
    end
end

-- Add BADGE to TAG_COLORS
TAG_COLORS["BADGE"] = Color3.fromRGB(200,150,50)

-- ── Colour additions for BSE ──────────────────────────────────
C.BADGE    = Color3.fromRGB(255,245,220)   -- warm gold tint for badge cards
C.BADGECHIP= Color3.fromRGB(240,228,198)   -- badge chip background
C.BADGESEL = Color3.fromRGB(255,235,160)   -- selected badge chip

-- ============================================================
-- UI — SECTION: Badge Scanner
-- ============================================================
local _, sBadgeScan = makeSection(pageGSE,
    "🏅  BadgeService — Scanner")

gseLabel(sBadgeScan,
    "Discovers badge IDs via namecall hook, script scan, and PR Bridge." ..
    " Fetches name, description, and enabled state from BadgeService.",
    11, false, C.SUBTEXT)

local bScanRow = gseRow(sBadgeScan)
local btnBScanWS  = gseBtn(bScanRow, "🔍 Scan Scripts",   C.BTN, C.BTNHOV, 1)
local btnBScanPR  = gseBtn(bScanRow, "🔗 Scan PR Bridge", C.BTN, C.BTNHOV, 2)
local btnBClear   = gseBtn(bScanRow, "✕ Clear List",      C.BTN, C.BTNHOV, 3)

-- Badge list frame
local badgeList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=true, Parent=sBadgeScan,
})
addCorner(badgeList, UDim.new(0,8)); addStroke(badgeList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0), SortOrder=Enum.SortOrder.LayoutOrder,
    Parent=badgeList})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),
    Parent=badgeList})

local badgeEmpty = gseLabel(badgeList,
    "  No badges discovered yet — run a scan or trigger a badge check.",
    11, false, C.SUBTEXT)
badgeEmpty.Size = UDim2.new(1,0,0,26)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=badgeEmpty})

local function BSE_RebuildBadgeList()
    -- Destroy old rows, preserving the empty label
    for id in pairs(BSE_NameRefs) do
        local ref = BSE_NameRefs[id]
        if ref and ref.Parent and ref.Parent.Parent == badgeList then
            ref.Parent:Destroy()
        end
    end
    BSE_NameRefs = {}
    local count = 0
    for id, entry in pairs(BSE.Badges) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            LayoutOrder=count, Parent=badgeList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),
            PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=row})

        -- ID badge
        local idBadge = mk("TextLabel",{
            BackgroundColor3=C.BADGECHIP, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text=id, TextColor3=C.TEXT,
            TextSize=10, AutomaticSize=Enum.AutomaticSize.X,
            Size=UDim2.new(0,0,0,18), Parent=row,
        })
        addCorner(idBadge, UDim.new(0,4))
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5),
            Parent=idBadge})

        -- Name (updated when info arrives)
        local nameRef = mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.Gotham,
            Text=entry.name .. (entry.enabled == false and "  ⛔" or ""),
            TextColor3=C.TEXT, TextSize=11,
            AutomaticSize=Enum.AutomaticSize.X,
            Size=UDim2.new(0,0,0,18),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row,
        })
        BSE_NameRefs[id] = nameRef

        -- Source tag
        mk("TextLabel",{
            BackgroundColor3=Color3.fromRGB(255,240,200),
            BorderSizePixel=0, Font=Enum.Font.Gotham,
            Text=entry.source, TextColor3=C.SUBTEXT, TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X,
            Size=UDim2.new(0,0,0,16), Parent=row,
        })

        -- Description (second line, if present and fetched)
        if entry.description and entry.description ~= "" then
            local descRow = mk("Frame",{BackgroundTransparency=1,
                Size=UDim2.new(1,0,0,16), LayoutOrder=count+1000, Parent=badgeList})
            mk("UIPadding",{PaddingLeft=UDim.new(0,58),Parent=descRow})
            mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.Gotham,
                Text=entry.description, TextColor3=C.SUBTEXT, TextSize=9,
                Size=UDim2.new(1,0,1,0), TextXAlignment=Enum.TextXAlignment.Left,
                TextTruncate=Enum.TextTruncate.AtEnd, Parent=descRow})
        end
    end
    badgeEmpty.Visible = (count == 0)
end

BSE_RebuildBadgeList()

-- Rebuild when scan log fires
table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "BADGE" then BSE_RebuildBadgeList() end
    if entry.tag == "INFO"  then
        -- Live update name labels
        for id, rec in pairs(BSE.Badges) do
            if BSE_NameRefs[id] then
                BSE_NameRefs[id].Text =
                    rec.name .. (rec.enabled == false and "  ⛔" or "")
            end
        end
    end
end)

btnBScanWS.MouseButton1Click:Connect(function()
    btnBScanWS.Text = "⏳ Scanning..."
    task.spawn(function()
        BSE_ScanWorkspaceForIds()
        task.wait(0.3); btnBScanWS.Text = "🔍 Scan Scripts"
    end)
end)

btnBScanPR.MouseButton1Click:Connect(function()
    btnBScanPR.Text = "⏳ Scanning..."
    task.spawn(function()
        BSE_ScanPRForAwardRemotes()
        task.wait(0.3); btnBScanPR.Text = "🔗 Scan PR Bridge"
    end)
end)

btnBClear.MouseButton1Click:Connect(function()
    BSE.Badges = {}; BSE_NameRefs = {}; BSE_Save()
    BSE_RebuildBadgeList()
    GSE_Log("INFO", "Badge list cleared")
end)

-- ============================================================
-- UI — SECTION: Badge Actions
-- ============================================================
local _, sBadgeAct = makeSection(pageGSE, "🎖  Badge — Check & Award")

gseLabel(sBadgeAct,
    "Check whether the local player owns a badge, fetch its info," ..
    " or fire the game's award remote to trigger a server-side award.",
    11, false, C.SUBTEXT)

local badgeIdInput = gseInput(sBadgeAct, "Badge ID (numeric)", 1)

-- Quick-pick chips from scanner
gseLabel(sBadgeAct, "Quick-pick from scanner:", 11, false, C.SUBTEXT)
local badgePickScroll = gseHScroll(sBadgeAct, 52)

local function BSE_RebuildQuickPick()
    for _, ch in ipairs(badgePickScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    local any = false
    for id, entry in pairs(BSE.Badges) do
        any = true
        gseChip(badgePickScroll,
            id .. (entry.name ~= "..." and ("  " .. entry.name) or ""),
            C.BADGECHIP,
            function() badgeIdInput.Text = id end)
    end
    if not any then
        gseLabel(badgePickScroll, "  Scan first.", 11, false, C.SUBTEXT)
    end
end

BSE_RebuildQuickPick()

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "BADGE" then BSE_RebuildQuickPick() end
end)

-- Action buttons
local badgeActRow = gseRow(sBadgeAct)
local btnBCheck   = gseBtn(badgeActRow, "🔍 Check Owned",  C.BTN,    C.BTNHOV,                    1)
local btnBFetch   = gseBtn(badgeActRow, "📋 Fetch Info",   C.BTN,    C.BTNHOV,                    2)
local btnBAward   = gseBtn(badgeActRow, "🏅 Award Remote", C.BADGE,  Color3.fromRGB(255,240,190),  3)

local badgeStatusLabel = gseLabel(sBadgeAct, "", 11, false, C.SUBTEXT)

-- Check owned
btnBCheck.MouseButton1Click:Connect(function()
    local id = tonumber(badgeIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid badge ID"); return end
    badgeStatusLabel.Text = "Checking..."
    task.spawn(function()
        local ok, owned = pcall(function()
            return BadgeSvc:UserHasBadgeAsync(
                game:GetService("Players").LocalPlayer.UserId, id)
        end)
        if ok then
            badgeStatusLabel.Text = "Badge " .. id .. ": " ..
                (owned and "✅ Owned" or "❌ Not owned")
            GSE_Log("BADGE", "UserHasBadgeAsync(" .. id .. ") → " .. tostring(owned))
            -- Auto-register if new
            BSE_RegisterBadge(tostring(id), "ownership_check")
        else
            badgeStatusLabel.Text = "Check failed"
            GSE_Log("WARN", "UserHasBadgeAsync error: " .. tostring(owned))
        end
    end)
end)

-- Fetch info
btnBFetch.MouseButton1Click:Connect(function()
    local id = tonumber(badgeIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid badge ID"); return end
    badgeStatusLabel.Text = "Fetching..."
    -- Clear cache so we force a fresh fetch
    BSE.InfoCache[id] = nil
    BSE_FetchInfo(id, function(info)
        if info then
            badgeStatusLabel.Text =
                info.name ..
                (info.enabled and "" or "  [DISABLED]") ..
                (info.description ~= "" and ("  —  " .. info.description:sub(1,60)) or "")
            GSE_Log("BADGE", "Info: " .. tostring(id) ..
                    " = " .. info.name ..
                    (info.enabled and "" or " [DISABLED]"))
            BSE_RegisterBadge(tostring(id), "info_fetch")
        else
            badgeStatusLabel.Text = "Fetch failed (badge may not exist)"
            GSE_Log("WARN", "GetBadgeInfoAsync(" .. id .. ") failed")
        end
    end)
end)

-- Award via remote
btnBAward.MouseButton1Click:Connect(function()
    local id = tonumber(badgeIdInput.Text)
    if not id then GSE_Log("WARN", "Invalid badge ID"); return end
    BSE_AwardViaRemote(id)
end)

-- ============================================================
-- UI — SECTION: Badge Award Remote Selector
-- ============================================================
local _, sBadgeRemote = makeSection(pageGSE, "📡  Badge Award Remote")

gseLabel(sBadgeRemote,
    "Select the remote the game uses to trigger badge awards server-side.\n" ..
    "Scanned from PR Bridge using badge/award/achievement keywords.",
    11, false, C.SUBTEXT)

local badgeRemoteScroll = gseHScroll(sBadgeRemote, 52)
local badgeRemoteChipRefs = {}

local function BSE_RebuildRemoteChips()
    for _, ch in ipairs(badgeRemoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    badgeRemoteChipRefs = {}
    if #BSE.AwardRemotes == 0 then
        gseLabel(badgeRemoteScroll,
            "  No badge remotes found — run Scan PR Bridge.",
            11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(BSE.AwardRemotes) do
        local isSel = (BSE.SelectedRemote == name)
        local chip  = gseChip(badgeRemoteScroll, name,
            isSel and C.BADGESEL or C.BADGECHIP)
        badgeRemoteChipRefs[name] = chip
        chip.MouseButton1Click:Connect(function()
            BSE.SelectedRemote = name; BSE_Save()
            GSE_Log("BADGE", "Selected remote: " .. name)
            for n, c in pairs(badgeRemoteChipRefs) do
                tween(c, TweenInfo.new(0.1), {
                    BackgroundColor3 = (n == name) and C.BADGESEL or C.BADGECHIP
                })
            end
        end)
    end
end

BSE_RebuildRemoteChips()

local bRescanRow = gseRow(sBadgeRemote)
local btnBRescan = gseBtn(bRescanRow, "↻ Rescan PR Bridge", C.BTN, C.BTNHOV, 1)
local bSelectedLabel = gseLabel(bRescanRow,
    BSE.SelectedRemote and ("Selected: " .. BSE.SelectedRemote) or "None selected",
    11, false, C.SUBTEXT)

btnBRescan.MouseButton1Click:Connect(function()
    btnBRescan.Text = "⏳ Scanning..."
    task.spawn(function()
        BSE_ScanPRForAwardRemotes()
        BSE_RebuildRemoteChips()
        task.wait(0.3); btnBRescan.Text = "↻ Rescan PR Bridge"
    end)
end)

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "BADGE" and BSE.SelectedRemote then
        bSelectedLabel.Text = "Selected: " .. BSE.SelectedRemote
    end
end)

-- ============================================================
-- EXPORT BSE alongside GSE
-- ============================================================
_G.PC.BSE               = BSE
_G.PC.BSE_Log           = GSE_Log
_G.PC.BSE_RegisterBadge = BSE_RegisterBadge



-- ============================================================
-- DATA STORE SERVICE EDIT (DSE)
-- ============================================================
-- DataStoreService is entirely server-side. The client cannot
-- call GetAsync/SetAsync directly. The exploit surface is:
--   1. Script scanning — detect store names and key patterns
--   2. PR Bridge — identify load/save remotes by name keywords
--   3. Read relay  — fire the game's load remote, display data
--   4. Write relay — fire the game's save remote with modified
--      key/value pairs to influence what the server writes back
-- ============================================================

-- ── State ─────────────────────────────────────────────────────
local DSE = {
    -- Discovered DataStore names: [name] = { name, source, firstSeen }
    Stores          = {},
    -- Discovered key patterns: [pattern] = { pattern, store, source }
    Keys            = {},
    -- PR Bridge candidates: { name, type } sorted by keyword match
    LoadRemotes     = {},   -- remotes that look like data loaders
    SaveRemotes     = {},   -- remotes that look like data savers
    -- Last read result: raw value returned by the load remote
    LastReadResult  = nil,
    -- Selected remotes
    SelectedLoad    = nil,
    SelectedSave    = nil,
    -- Flat key/value edit table built from LastReadResult
    EditBuffer      = {},   -- [key] = { key, displayValue, editBox }
}

-- Persist DSE inside the shared GSE persist key
local function DSE_Save()
    pcall(function()
        local saved = _G[GSE_PERSIST_KEY] or {}
        saved.DSE_Stores       = DSE.Stores
        saved.DSE_Keys         = DSE.Keys
        saved.DSE_SelectedLoad = DSE.SelectedLoad
        saved.DSE_SelectedSave = DSE.SelectedSave
        _G[GSE_PERSIST_KEY]    = saved
    end)
end

local function DSE_Load()
    pcall(function()
        local s = _G[GSE_PERSIST_KEY]
        if type(s) ~= "table" then return end
        if type(s.DSE_Stores)       == "table"  then DSE.Stores       = s.DSE_Stores       end
        if type(s.DSE_Keys)         == "table"  then DSE.Keys         = s.DSE_Keys         end
        if type(s.DSE_SelectedLoad) == "string" then DSE.SelectedLoad = s.DSE_SelectedLoad end
        if type(s.DSE_SelectedSave) == "string" then DSE.SelectedSave = s.DSE_SelectedSave end
    end)
end

DSE_Load()

-- ── Register a discovered DataStore name ─────────────────────
local function DSE_RegisterStore(name, source)
    if not name or name == "" then return end
    name = tostring(name)
    if DSE.Stores[name] then return end
    DSE.Stores[name] = { name=name, source=source or "scan", firstSeen=os.clock() }
    GSE_Log("DSE", "DataStore: \"" .. name .. "\"  [" .. (source or "scan") .. "]")
    DSE_Save()
end

-- ── Register a discovered key pattern ────────────────────────
local function DSE_RegisterKey(pattern, storeName, source)
    if not pattern or pattern == "" then return end
    pattern = tostring(pattern)
    local key = (storeName or "?") .. ":" .. pattern
    if DSE.Keys[key] then return end
    DSE.Keys[key] = { pattern=pattern, store=storeName or "?", source=source or "scan" }
    GSE_Log("DSE", "Key pattern: \"" .. pattern .. "\"  store=" ..
            (storeName or "?") .. "  [" .. (source or "scan") .. "]")
    DSE_Save()
end

-- ── Namecall hook — intercept DataStoreService calls ─────────
-- Can't intercept server-side GetAsync/SetAsync but can catch
-- client-side GetDataStore calls that reveal store names,
-- and any wrapped DataStore calls in LocalScripts.
local function DSE_InstallNamecallHook()
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            -- GetDataStore("StoreName") or GetDataStore("StoreName","scope")
            if method == "GetDataStore" or method == "GetOrderedDataStore" then
                local args = {...}
                local storeName = args[1]
                if storeName then
                    pcall(DSE_RegisterStore, tostring(storeName),
                        method == "GetOrderedDataStore"
                            and "namecall_ordered" or "namecall")
                end
            end
            if oldNC then return oldNC(self, ...) end
        end
        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then
        GSE_Log("WARN", "DSE namecall hook failed: " .. tostring(err))
    end
end

DSE_InstallNamecallHook()

-- ── Script source scan ────────────────────────────────────────
-- Scans LocalScripts and ModuleScripts for:
--   GetDataStore("StoreName")
--   key patterns like "Player_"..userId, "data_"..name
--   Common constant key names
local function DSE_ScanWorkspaceForIds()
    local storesFound, keysFound = 0, 0
    local function scanScript(s)
        local ok, src = pcall(function() return s.Source end)
        if not ok or type(src) ~= "string" then return end

        -- GetDataStore("Name") or GetDataStore('Name')
        for name in src:gmatch('[Gg]et[Dd]ata[Ss]tore%s*%(%s*["\']([^"\']+)["\']') do
            DSE_RegisterStore(name, "source_scan"); storesFound = storesFound + 1
        end

        -- GetOrderedDataStore("Name")
        for name in src:gmatch('[Gg]et[Oo]rdered[Dd]ata[Ss]tore%s*%(%s*["\']([^"\']+)["\']') do
            DSE_RegisterStore(name, "source_scan_ordered"); storesFound = storesFound + 1
        end

        -- Key patterns: string literals passed to GetAsync/SetAsync/UpdateAsync
        -- Catches: dataStore:GetAsync("player_"..id) → extracts "player_"
        for key in src:gmatch('[GgSsUuRrIi][EeEeTt][TtSsEeEe][AaAaAa][SsSs][Yy][Cc]?%s*%(%s*["\']([^"\']+)["\']') do
            DSE_RegisterKey(key, nil, "source_scan"); keysFound = keysFound + 1
        end

        -- Common constant key names stored in variables
        -- e.g. local KEY = "PlayerData" or local STORE_KEY = "stats"
        for key in src:gmatch('[Kk][Ee][Yy]%s*=%s*["\']([^"\']+)["\']') do
            DSE_RegisterKey(key, nil, "source_scan"); keysFound = keysFound + 1
        end

        -- DataStore variable names often reveal store names
        -- e.g. local playerDataStore = game:GetService("DataStoreService"):GetDataStore("PlayerData")
        for name in src:gmatch('[Dd]ata[Ss]tore[Ss]ervice[^:]*:[Gg]et[Dd]ata[Ss]tore%s*%(%s*["\']([^"\']+)["\']') do
            DSE_RegisterStore(name, "source_scan"); storesFound = storesFound + 1
        end
    end

    local roots = {
        game:GetService("Players").LocalPlayer:FindFirstChild("PlayerScripts"),
        game:GetService("ReplicatedStorage"),
    }
    for _, root in ipairs(roots) do
        if root then
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
                    pcall(scanScript, desc)
                end
            end
        end
    end
    GSE_Log("DSE", "Script scan — " .. storesFound ..
            " store(s), " .. keysFound .. " key pattern(s)")
end

-- ── PR Bridge scan ────────────────────────────────────────────
-- Two keyword sets: one for load remotes, one for save remotes.
local DSE_LOAD_KEYWORDS = {
    "load","get","fetch","read","request","retrieve",
    "data","profile","stats","playerdata","savedata",
}
local DSE_SAVE_KEYWORDS = {
    "save","set","write","update","store","commit",
    "sync","push","flush","persist",
}

local function DSE_ScanPRForRemotes()
    local reg = _G.PC and _G.PC.PR_Registry
    if not reg then
        GSE_Log("WARN", "PR_Registry not available"); return
    end

    DSE.LoadRemotes = {}
    DSE.SaveRemotes = {}

    for name in pairs(reg) do
        local lower = name:lower()
        local isLoad, isSave = false, false

        for _, kw in ipairs(DSE_LOAD_KEYWORDS) do
            if lower:find(kw, 1, true) then isLoad = true; break end
        end
        for _, kw in ipairs(DSE_SAVE_KEYWORDS) do
            if lower:find(kw, 1, true) then isSave = true; break end
        end

        -- A remote with both load and save keywords goes to both lists
        if isLoad then table.insert(DSE.LoadRemotes, name) end
        if isSave then table.insert(DSE.SaveRemotes, name) end
    end

    table.sort(DSE.LoadRemotes)
    table.sort(DSE.SaveRemotes)

    GSE_Log("DSE", "PR Bridge — " ..
            #DSE.LoadRemotes .. " load remote(s), " ..
            #DSE.SaveRemotes .. " save remote(s)")
end

task.delay(3, DSE_ScanPRForRemotes)

-- ── Value serialiser — table → readable string ───────────────
-- Converts a DataStore result (arbitrary Lua value) into a
-- human-readable string for display in the inspector.
local function DSE_Serialise(val, depth)
    depth = depth or 0
    local indent = string.rep("  ", depth)
    local t = type(val)
    if t == "nil"     then return "nil" end
    if t == "boolean" then return tostring(val) end
    if t == "number"  then
        if val == math.floor(val) then return tostring(math.floor(val))
        else return string.format("%.4f", val) end
    end
    if t == "string"  then return '"' .. val:sub(1, 80) .. '"' end
    if t == "table"   then
        if depth >= 4 then return "{...}" end
        local parts = {}
        -- Check if array-like
        local isArr = (#val > 0)
        if isArr then
            for i, v in ipairs(val) do
                parts[#parts+1] = indent .. "  [" .. i .. "] = " ..
                    DSE_Serialise(v, depth+1)
            end
        else
            for k, v in pairs(val) do
                parts[#parts+1] = indent .. "  " .. tostring(k) ..
                    " = " .. DSE_Serialise(v, depth+1)
            end
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "<" .. t .. ">"
end

-- ── Build flat edit buffer from DataStore result ─────────────
-- Flattens top-level keys of the result table into editable
-- string pairs. Nested tables are shown as read-only JSON-ish
-- strings since we can only fire a whole payload at once.
local function DSE_BuildEditBuffer(data)
    DSE.EditBuffer = {}
    if type(data) ~= "table" then
        -- Scalar result — single editable entry
        DSE.EditBuffer["__value"] = {
            key          = "__value",
            displayValue = DSE_Serialise(data),
            rawValue     = data,
        }
        return
    end
    for k, v in pairs(data) do
        DSE.EditBuffer[tostring(k)] = {
            key          = tostring(k),
            displayValue = DSE_Serialise(v),
            rawValue     = v,
        }
    end
end

-- ── Fire load remote and capture result ──────────────────────
local DSE_ReadCallbacks = {}

local function DSE_FireLoadRemote(callback)
    local remoteName = DSE.SelectedLoad
    if not remoteName then
        GSE_Log("WARN", "No load remote selected"); return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry"); return
    end

    GSE_Log("DSE", "Firing load remote: " .. remoteName)

    task.spawn(function()
        local ok, result = pcall(function()
            if rec.RemoteType == "RemoteFunction" then
                return rec.Remote:InvokeServer()
            else
                -- RemoteEvent: fire and wait for a response event
                -- Games typically send data back on the same or companion remote
                rec.Remote:FireServer()
                return nil
            end
        end)

        if ok then
            DSE.LastReadResult = result
            DSE_BuildEditBuffer(result)
            local preview = DSE_Serialise(result, 0)
            GSE_Log("DSE", "Load result received  (" ..
                    #preview .. " chars)")
            for _, cb in ipairs(DSE_ReadCallbacks) do pcall(cb, result) end
        else
            GSE_Log("WARN", "Load remote error: " .. tostring(result))
        end
    end)
end

-- ── Fire save remote with current edit buffer ────────────────
local function DSE_FireSaveRemote()
    local remoteName = DSE.SelectedSave
    if not remoteName then
        GSE_Log("WARN", "No save remote selected"); return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry"); return
    end

    -- Reconstruct payload from edit buffer
    -- Attempt to parse numeric strings back to numbers
    local payload = {}
    for k, entry in pairs(DSE.EditBuffer) do
        local numVal = tonumber(entry.displayValue)
        if numVal then
            payload[k == "__value" and 1 or k] = numVal
        elseif entry.displayValue == "true" then
            payload[k == "__value" and 1 or k] = true
        elseif entry.displayValue == "false" then
            payload[k == "__value" and 1 or k] = false
        elseif entry.displayValue:sub(1,1) == '"' then
            -- Strip quotes
            payload[k == "__value" and 1 or k] =
                entry.displayValue:sub(2, -2)
        else
            payload[k == "__value" and 1 or k] = entry.displayValue
        end
    end

    local ok, err = pcall(function()
        if rec.RemoteType == "RemoteFunction" then
            rec.Remote:InvokeServer(payload)
        else
            rec.Remote:FireServer(payload)
        end
    end)

    if ok then
        GSE_Log("SIGNAL", "Save fired → " .. remoteName ..
                "  keys=" .. tostring(#payload))
    else
        GSE_Log("WARN", "Save remote error: " .. tostring(err))
    end
end

-- Add DSE to TAG_COLORS
TAG_COLORS["DSE"] = Color3.fromRGB(60,160,180)

-- Colour additions for DSE
C.DSE_STORE  = Color3.fromRGB(220,240,248)
C.DSE_KEY    = Color3.fromRGB(235,245,250)
C.DSE_SEL    = Color3.fromRGB(180,225,240)
C.DSE_EDIT   = Color3.fromRGB(248,252,255)

-- ============================================================
-- UI — SECTION: DataStore Scanner
-- ============================================================
local _, sDSEScan = makeSection(pageGSE, "🗄  DataStoreService — Scanner")

gseLabel(sDSEScan,
    "Discovers DataStore names and key patterns via namecall hook and script scan.\n" ..
    "All actual reads/writes are server-side — we route through PR Bridge remotes.",
    11, false, C.SUBTEXT)

local dseScanRow = gseRow(sDSEScan)
local btnDSEScanWS = gseBtn(dseScanRow, "🔍 Scan Scripts",   C.BTN, C.BTNHOV, 1)
local btnDSEScanPR = gseBtn(dseScanRow, "🔗 Scan PR Bridge", C.BTN, C.BTNHOV, 2)
local btnDSEClear  = gseBtn(dseScanRow, "✕ Clear",           C.BTN, C.BTNHOV, 3)

-- Store list
gseLabel(sDSEScan, "Discovered DataStore names:", 11, true, C.TEXT)

local storeList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=true, Parent=sDSEScan,
})
addCorner(storeList, UDim.new(0,8)); addStroke(storeList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=storeList})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=storeList})

local storeEmpty = gseLabel(storeList,
    "  No DataStore names found yet.", 11, false, C.SUBTEXT)
storeEmpty.Size = UDim2.new(1,0,0,22)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=storeEmpty})

local function DSE_RebuildStoreList()
    for _, ch in ipairs(storeList:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    local count = 0
    for name, entry in pairs(DSE.Stores) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,24), LayoutOrder=count, Parent=storeList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=row})

        local nameBadge = mk("TextLabel",{
            BackgroundColor3=C.DSE_STORE, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text='"' .. name .. '"',
            TextColor3=C.TEXT, TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,18),
            Parent=row,
        })
        addCorner(nameBadge, UDim.new(0,4))
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5),
            Parent=nameBadge})

        mk("TextLabel",{BackgroundColor3=Color3.fromRGB(220,235,245),
            BorderSizePixel=0, Font=Enum.Font.Gotham, Text=entry.source,
            TextColor3=C.SUBTEXT, TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,16),
            Parent=row,
        })
    end
    storeEmpty.Visible = (count == 0)
end

DSE_RebuildStoreList()

-- Key pattern list
gseLabel(sDSEScan, "Discovered key patterns:", 11, true, C.TEXT)

local keyList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=true, Parent=sDSEScan,
})
addCorner(keyList, UDim.new(0,8)); addStroke(keyList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=keyList})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),Parent=keyList})

local keyEmpty = gseLabel(keyList,
    "  No key patterns found yet.", 11, false, C.SUBTEXT)
keyEmpty.Size = UDim2.new(1,0,0,22)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=keyEmpty})

local function DSE_RebuildKeyList()
    for _, ch in ipairs(keyList:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    local count = 0
    for _, entry in pairs(DSE.Keys) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,24), LayoutOrder=count, Parent=keyList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=row})

        local keyBadge = mk("TextLabel",{
            BackgroundColor3=C.DSE_KEY, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text='"' .. entry.pattern .. '"',
            TextColor3=C.TEXT, TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,18),
            Parent=row,
        })
        addCorner(keyBadge, UDim.new(0,4))
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5),
            Parent=keyBadge})

        if entry.store ~= "?" then
            mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.Gotham,
                Text="store: " .. entry.store, TextColor3=C.SUBTEXT, TextSize=9,
                AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,16),
                TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
        end
    end
    keyEmpty.Visible = (count == 0)
end

DSE_RebuildKeyList()

-- Wire scan log updates to rebuilds
table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "DSE" then
        DSE_RebuildStoreList()
        DSE_RebuildKeyList()
    end
end)

btnDSEScanWS.MouseButton1Click:Connect(function()
    btnDSEScanWS.Text = "⏳ Scanning..."
    task.spawn(function()
        DSE_ScanWorkspaceForIds()
        task.wait(0.3); btnDSEScanWS.Text = "🔍 Scan Scripts"
    end)
end)

btnDSEScanPR.MouseButton1Click:Connect(function()
    btnDSEScanPR.Text = "⏳ Scanning..."
    task.spawn(function()
        DSE_ScanPRForRemotes()
        task.wait(0.3); btnDSEScanPR.Text = "🔗 Scan PR Bridge"
    end)
end)

btnDSEClear.MouseButton1Click:Connect(function()
    DSE.Stores = {}; DSE.Keys = {}; DSE_Save()
    DSE_RebuildStoreList(); DSE_RebuildKeyList()
    GSE_Log("INFO", "DataStore scanner cleared")
end)

-- ============================================================
-- UI — SECTION: Data Inspector (Load + Read)
-- ============================================================
local _, sDSERead = makeSection(pageGSE, "🔎  Data Inspector — Load & Read")

gseLabel(sDSERead,
    "Select the game's data load remote from PR Bridge, fire it, and inspect" ..
    " the returned player data structure.",
    11, false, C.SUBTEXT)

-- Load remote selector
gseLabel(sDSERead, "Load remote:", 11, true, C.TEXT)
local loadRemoteScroll = gseHScroll(sDSERead, 52)
local loadChipRefs = {}

local function DSE_RebuildLoadChips()
    for _, ch in ipairs(loadRemoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    loadChipRefs = {}
    if #DSE.LoadRemotes == 0 then
        gseLabel(loadRemoteScroll,
            "  No load remotes found — run Scan PR Bridge.", 11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(DSE.LoadRemotes) do
        local isSel = (DSE.SelectedLoad == name)
        local chip  = gseChip(loadRemoteScroll, name,
            isSel and C.DSE_SEL or C.DSE_STORE)
        loadChipRefs[name] = chip
        chip.MouseButton1Click:Connect(function()
            DSE.SelectedLoad = name; DSE_Save()
            GSE_Log("DSE", "Load remote selected: " .. name)
            for n, c in pairs(loadChipRefs) do
                tween(c, TweenInfo.new(0.1), {
                    BackgroundColor3=(n==name) and C.DSE_SEL or C.DSE_STORE})
            end
        end)
    end
end

DSE_RebuildLoadChips()

local loadRow = gseRow(sDSERead)
local btnDSELoad    = gseBtn(loadRow, "📥 Fire Load Remote", C.DSE_STORE,
                        Color3.fromRGB(200,235,245), 1)
local btnDSERefresh = gseBtn(loadRow, "↻ Rescan PR Bridge", C.BTN, C.BTNHOV, 2)

btnDSERefresh.MouseButton1Click:Connect(function()
    btnDSERefresh.Text = "⏳ Scanning..."
    task.spawn(function()
        DSE_ScanPRForRemotes()
        DSE_RebuildLoadChips()
        task.wait(0.3); btnDSERefresh.Text = "↻ Rescan PR Bridge"
    end)
end)

-- Inspector display
gseLabel(sDSERead, "Last load result:", 11, true, C.TEXT)

local inspectorFrame = mk("ScrollingFrame",{
    BackgroundColor3=Color3.fromRGB(36,40,46),  -- dark code-editor style
    BorderSizePixel=0, Size=UDim2.new(1,-16,0,200),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=5, ScrollingDirection=Enum.ScrollingDirection.Y,
    Parent=sDSERead,
})
addCorner(inspectorFrame, UDim.new(0,8))
mk("UIListLayout",{Padding=UDim.new(0,0), Parent=inspectorFrame})
mk("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingTop=UDim.new(0,8),
    PaddingBottom=UDim.new(0,8),PaddingRight=UDim.new(0,8),Parent=inspectorFrame})

local inspectorLabel = mk("TextLabel",{
    BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
    Text="-- Fire a load remote to see data here",
    TextColor3=Color3.fromRGB(140,160,140), TextSize=11,
    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left,
    TextWrapped=true, Parent=inspectorFrame,
})

-- Wire load button
btnDSELoad.MouseButton1Click:Connect(function()
    inspectorLabel.Text = "-- Loading..."
    inspectorLabel.TextColor3 = Color3.fromRGB(180,180,100)
    DSE_FireLoadRemote(function(result)
        local serialised = DSE_Serialise(result, 0)
        inspectorLabel.Text = serialised
        inspectorLabel.TextColor3 = Color3.fromRGB(180,220,180)
    end)
end)

-- Callback to update inspector when load completes
table.insert(DSE_ReadCallbacks, function(result)
    local serialised = DSE_Serialise(result, 0)
    inspectorLabel.Text = serialised
    inspectorLabel.TextColor3 = Color3.fromRGB(180,220,180)
end)

-- ============================================================
-- UI — SECTION: Write Relay (Edit & Save)
-- ============================================================
local _, sDSEWrite = makeSection(pageGSE, "✏️  Write Relay — Edit & Save")

gseLabel(sDSEWrite,
    "Edit top-level keys from the last load result and fire them back through" ..
    " the game's save remote. Load data first to populate the editor.",
    11, false, C.SUBTEXT)

-- Save remote selector
gseLabel(sDSEWrite, "Save remote:", 11, true, C.TEXT)
local saveRemoteScroll = gseHScroll(sDSEWrite, 52)
local saveChipRefs = {}

local function DSE_RebuildSaveChips()
    for _, ch in ipairs(saveRemoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    saveChipRefs = {}
    if #DSE.SaveRemotes == 0 then
        gseLabel(saveRemoteScroll,
            "  No save remotes found — run Scan PR Bridge.", 11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(DSE.SaveRemotes) do
        local isSel = (DSE.SelectedSave == name)
        local chip  = gseChip(saveRemoteScroll, name,
            isSel and C.DSE_SEL or C.DSE_KEY)
        saveChipRefs[name] = chip
        chip.MouseButton1Click:Connect(function()
            DSE.SelectedSave = name; DSE_Save()
            GSE_Log("DSE", "Save remote selected: " .. name)
            for n, c in pairs(saveChipRefs) do
                tween(c, TweenInfo.new(0.1), {
                    BackgroundColor3=(n==name) and C.DSE_SEL or C.DSE_KEY})
            end
        end)
    end
end

DSE_RebuildSaveChips()

-- Edit buffer frame — populated after a successful load
gseLabel(sDSEWrite, "Edit values (load data first):", 11, true, C.TEXT)

local editFrame = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=false, Parent=sDSEWrite,
})
addCorner(editFrame, UDim.new(0,8)); addStroke(editFrame, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,4),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=editFrame})
mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),
    PaddingTop=UDim.new(0,6),PaddingBottom=UDim.new(0,6),Parent=editFrame})

local editEmpty = gseLabel(editFrame,
    "No data loaded yet — fire a load remote first.", 11, false, C.SUBTEXT)

local function DSE_RebuildEditFrame()
    -- Clear rows except empty label
    for _, ch in ipairs(editFrame:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end

    local count = 0
    for key, entry in pairs(DSE.EditBuffer) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,28), LayoutOrder=count, Parent=editFrame})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=row})

        -- Key label
        mk("TextLabel",{BackgroundTransparency=1,
            Font=Enum.Font.GothamMono, Text=key,
            TextColor3=C.TEXT, TextSize=10,
            Size=UDim2.new(0,120,0,24),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

        -- Value edit box
        local box = mk("TextBox",{
            BackgroundColor3=C.DSE_EDIT, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text=entry.displayValue,
            TextColor3=Color3.fromRGB(40,80,120), TextSize=10,
            Size=UDim2.new(1,-136,0,24),
            TextXAlignment=Enum.TextXAlignment.Left,
            ClearTextOnFocus=false, Parent=row,
        })
        addCorner(box, UDim.new(0,5)); addStroke(box, 1, 0.5)
        mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=box})

        -- Update edit buffer when user changes value
        box.FocusLost:Connect(function()
            if DSE.EditBuffer[key] then
                DSE.EditBuffer[key].displayValue = box.Text
            end
        end)

        entry.editBox = box
    end

    editEmpty.Visible = (count == 0)
end

DSE_RebuildEditFrame()

-- Rebuild edit frame when new data loads
table.insert(DSE_ReadCallbacks, function(_)
    DSE_RebuildEditFrame()
end)

-- Manual key/value entry for games that don't return structured data
gseLabel(sDSEWrite, "Or add a manual key/value pair:", 11, false, C.SUBTEXT)

local manualRow = gseRow(sDSEWrite)
local manualKeyInput = mk("TextBox",{
    BackgroundColor3=C.DSE_EDIT, BorderSizePixel=0,
    Font=Enum.Font.GothamMono, PlaceholderText="key",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT,
    TextSize=11, Size=UDim2.new(0,100,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=manualRow,
})
addCorner(manualKeyInput, UDim.new(0,6)); addStroke(manualKeyInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=manualKeyInput})

local manualValInput = mk("TextBox",{
    BackgroundColor3=C.DSE_EDIT, BorderSizePixel=0,
    Font=Enum.Font.GothamMono, PlaceholderText="value",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT,
    TextSize=11, Size=UDim2.new(0,120,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=manualRow,
})
addCorner(manualValInput, UDim.new(0,6)); addStroke(manualValInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=manualValInput})

local btnAddKV = gseBtn(manualRow, "+ Add", C.BTN, C.BTNHOV, 3)
btnAddKV.Size = UDim2.new(0,60,0,26)

btnAddKV.MouseButton1Click:Connect(function()
    local k = manualKeyInput.Text
    local v = manualValInput.Text
    if k == "" then GSE_Log("WARN", "Key cannot be empty"); return end
    DSE.EditBuffer[k] = { key=k, displayValue=v, rawValue=v }
    DSE_RebuildEditFrame()
    manualKeyInput.Text = ""; manualValInput.Text = ""
    GSE_Log("DSE", "Manual key added: " .. k .. " = " .. v)
end)

-- Save row
local saveActionRow = gseRow(sDSEWrite)
local btnDSESave  = gseBtn(saveActionRow, "💾 Fire Save Remote",
    Color3.fromRGB(220,245,225), Color3.fromRGB(200,238,210), 1)
local btnDSEClearBuf = gseBtn(saveActionRow, "✕ Clear Buffer",
    C.BTN, C.BTNHOV, 2)

btnDSESave.MouseButton1Click:Connect(function()
    if not next(DSE.EditBuffer) then
        GSE_Log("WARN", "Edit buffer is empty — load data or add manual keys first")
        return
    end
    DSE_FireSaveRemote()
end)

btnDSEClearBuf.MouseButton1Click:Connect(function()
    DSE.EditBuffer = {}
    DSE_RebuildEditFrame()
    GSE_Log("INFO", "Edit buffer cleared")
end)

-- ============================================================
-- EXPORT DSE
-- ============================================================
_G.PC.DSE                 = DSE
_G.PC.DSE_RegisterStore   = DSE_RegisterStore
_G.PC.DSE_RegisterKey     = DSE_RegisterKey



-- ============================================================
-- MESSAGING SERVICE EDIT (MSE)
-- ============================================================
-- MessagingService operates at cross-server scope.
-- PublishAsync(topic, message) — broadcast to ALL servers
-- SubscribeAsync(topic, callback) — receive from ANY server
--
-- Both are server-side only. Client leverage points:
--   1. Topic discovery  — script scan for topic string literals
--   2. Message observer — watch PR Bridge remotes the server
--      uses to relay received cross-server messages to clients
--   3. Publish relay    — fire a remote that triggers the server
--      to call PublishAsync with our payload, broadcasting to
--      every running game server simultaneously
--   4. Message log      — capture every relayed message arrival
-- ============================================================

local MSE = {
    -- Discovered topics: [topic] = { topic, source, firstSeen }
    Topics           = {},
    -- PR Bridge candidates
    PublishRemotes   = {},   -- remotes that trigger a publish
    ObserveRemotes   = {},   -- remotes the server fires to relay messages down
    -- Active observers: [remoteName] = RBXScriptConnection
    ActiveObservers  = {},
    -- Message log entries: { time, topic, payload, source }
    MessageLog       = {},
    -- Selected remotes
    SelectedPublish  = nil,
    -- Publish payload compose buffer
    PayloadBuffer    = "",
    -- Topic input for publish
    TopicBuffer      = "",
}

-- Persist inside the shared GSE key
local function MSE_Save()
    pcall(function()
        local saved = _G[GSE_PERSIST_KEY] or {}
        saved.MSE_Topics          = MSE.Topics
        saved.MSE_SelectedPublish = MSE.SelectedPublish
        saved.MSE_TopicBuffer     = MSE.TopicBuffer
        _G[GSE_PERSIST_KEY]       = saved
    end)
end

local function MSE_Load()
    pcall(function()
        local s = _G[GSE_PERSIST_KEY]
        if type(s) ~= "table" then return end
        if type(s.MSE_Topics)          == "table"  then MSE.Topics          = s.MSE_Topics          end
        if type(s.MSE_SelectedPublish) == "string" then MSE.SelectedPublish = s.MSE_SelectedPublish end
        if type(s.MSE_TopicBuffer)     == "string" then MSE.TopicBuffer     = s.MSE_TopicBuffer     end
    end)
end

MSE_Load()

-- ── Register a discovered topic ───────────────────────────────
local MSE_TopicListRebuildCallbacks = {}

local function MSE_RegisterTopic(topic, source)
    if not topic or topic == "" then return end
    topic = tostring(topic)
    if MSE.Topics[topic] then return end
    MSE.Topics[topic] = { topic=topic, source=source or "scan", firstSeen=os.clock() }
    GSE_Log("MSE", "Topic: \"" .. topic .. "\"  [" .. (source or "scan") .. "]")
    MSE_Save()
    for _, cb in ipairs(MSE_TopicListRebuildCallbacks) do pcall(cb) end
end

-- ── Namecall hook — intercept any client-side MPS calls ──────
-- MessagingService calls are server-only in normal games, but
-- some games wrap them in ModuleScripts accessible from
-- LocalScripts. Hook catches those edge cases.
local function MSE_InstallNamecallHook()
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            if method == "PublishAsync" or method == "SubscribeAsync" then
                local args = {...}
                local topic = args[1]
                if topic then
                    pcall(MSE_RegisterTopic, tostring(topic),
                        "namecall_" .. method:lower():gsub("async",""))
                end
            end
            if oldNC then return oldNC(self, ...) end
        end
        mt.__namecall = newcclosure and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then
        GSE_Log("WARN", "MSE namecall hook failed: " .. tostring(err))
    end
end

MSE_InstallNamecallHook()

-- ── Script source scan ────────────────────────────────────────
-- Scans for SubscribeAsync("topic") and PublishAsync("topic")
-- string literals, plus common MessagingService topic constants.
local function MSE_ScanWorkspaceForTopics()
    local found = 0
    local function scanScript(s)
        local ok, src = pcall(function() return s.Source end)
        if not ok or type(src) ~= "string" then return end

        -- SubscribeAsync("topic") or SubscribeAsync('topic')
        for topic in src:gmatch('[Ss]ubscribe[Aa]sync%s*%(%s*["\']([^"\']+)["\']') do
            MSE_RegisterTopic(topic, "source_subscribe"); found = found + 1
        end

        -- PublishAsync("topic", ...) 
        for topic in src:gmatch('[Pp]ublish[Aa]sync%s*%(%s*["\']([^"\']+)["\']') do
            MSE_RegisterTopic(topic, "source_publish"); found = found + 1
        end

        -- Topic constant assignments: local TOPIC = "name" or TOPIC_NAME = "name"
        for topic in src:gmatch('[Tt][Oo][Pp][Ii][Cc][%w_]*%s*=%s*["\']([^"\']+)["\']') do
            MSE_RegisterTopic(topic, "source_const"); found = found + 1
        end

        -- MessagingService variable access pattern:
        -- local ms = game:GetService("MessagingService")
        -- ms:SubscribeAsync("topic") → already caught above
        -- Also catch: game.MessagingService:SubscribeAsync("topic")
        for topic in src:gmatch('[Mm]essaging[Ss]ervice%s*:%s*[Ss]ubscribe[Aa]sync%s*%(%s*["\']([^"\']+)["\']') do
            MSE_RegisterTopic(topic, "source_subscribe"); found = found + 1
        end
    end

    local roots = {
        game:GetService("Players").LocalPlayer:FindFirstChild("PlayerScripts"),
        game:GetService("ReplicatedStorage"),
    }
    for _, root in ipairs(roots) do
        if root then
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
                    pcall(scanScript, desc)
                end
            end
        end
    end
    GSE_Log("MSE", "Script scan — " .. found .. " topic(s) extracted")
end

-- ── PR Bridge scan ────────────────────────────────────────────
-- Two keyword sets:
--   Publish keywords: remotes the client fires to trigger server PublishAsync
--   Observe keywords: remotes the server fires to relay received messages down
local MSE_PUBLISH_KEYWORDS = {
    "publish","broadcast","announce","send","message",
    "global","crossserver","cross_server","notify","alert",
}
local MSE_OBSERVE_KEYWORDS = {
    "message","receive","incoming","relay","dispatch",
    "broadcast","announce","global","notify","alert",
    "notification","event","update",
}

local function MSE_ScanPRForRemotes()
    local reg = _G.PC and _G.PC.PR_Registry
    if not reg then
        GSE_Log("WARN", "PR_Registry not available"); return
    end

    MSE.PublishRemotes = {}
    MSE.ObserveRemotes = {}

    for name, rec in pairs(reg) do
        local lower = name:lower()
        local isPub, isObs = false, false

        for _, kw in ipairs(MSE_PUBLISH_KEYWORDS) do
            if lower:find(kw, 1, true) then isPub = true; break end
        end
        for _, kw in ipairs(MSE_OBSERVE_KEYWORDS) do
            if lower:find(kw, 1, true) then isObs = true; break end
        end

        -- Heuristic: RemoteFunctions are more likely to be publish relays
        -- (client invokes, server publishes, returns result)
        -- RemoteEvents from server to client are observe candidates
        if isPub then
            table.insert(MSE.PublishRemotes, name)
        end
        -- Observe: server→client RemoteEvents only
        -- Check rec.Direction if PR_Bridge tracks direction, else use all
        if isObs then
            table.insert(MSE.ObserveRemotes, name)
        end
    end

    table.sort(MSE.PublishRemotes)
    table.sort(MSE.ObserveRemotes)

    GSE_Log("MSE", "PR Bridge — " ..
            #MSE.PublishRemotes .. " publish remote(s), " ..
            #MSE.ObserveRemotes .. " observe remote(s)")
end

task.delay(3.5, MSE_ScanPRForRemotes)

-- ── Message log helpers ───────────────────────────────────────
local MSE_MessageLogCallbacks = {}

local function MSE_LogMessage(topic, payload, source)
    local entry = {
        time    = os.clock(),
        topic   = topic   or "unknown",
        payload = payload,
        source  = source  or "unknown",
    }
    table.insert(MSE.MessageLog, 1, entry)
    if #MSE.MessageLog > 100 then table.remove(MSE.MessageLog) end
    GSE_Log("MSE", "[" .. entry.topic .. "] " ..
            tostring(DSE_Serialise and DSE_Serialise(payload, 0)
                     or tostring(payload)):sub(1, 80))
    for _, cb in ipairs(MSE_MessageLogCallbacks) do pcall(cb, entry) end
end

-- ── Observer attachment ───────────────────────────────────────
-- Connects to a server→client RemoteEvent in PR_Registry to
-- capture any cross-server messages the server relays down.
-- We extract the topic from the first argument if it's a string,
-- or label it with the remote name if the format is unknown.
local function MSE_AttachObserver(remoteName)
    if MSE.ActiveObservers[remoteName] then
        GSE_Log("MSE", "Already observing: " .. remoteName)
        return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry")
        return
    end
    -- Only connect to RemoteEvents (OnClientEvent)
    if rec.Remote.ClassName ~= "RemoteEvent" then
        GSE_Log("WARN", remoteName .. " is not a RemoteEvent — cannot observe")
        return
    end

    local conn = rec.Remote.OnClientEvent:Connect(function(...)
        local args = {...}
        -- Try to extract topic from first string arg, else use remote name
        local topic   = (type(args[1]) == "string" and args[1]) or remoteName
        local payload = (type(args[1]) == "string" and args[2]) or args[1]
        MSE_LogMessage(topic, payload, "observer:" .. remoteName)
        -- Auto-register topic if it looks like one
        if type(topic) == "string" and #topic < 64 then
            MSE_RegisterTopic(topic, "observer")
        end
    end)

    MSE.ActiveObservers[remoteName] = conn
    GSE_Log("MSE", "Observer attached: " .. remoteName)
end

local function MSE_DetachObserver(remoteName)
    local conn = MSE.ActiveObservers[remoteName]
    if conn then
        pcall(function() conn:Disconnect() end)
        MSE.ActiveObservers[remoteName] = nil
        GSE_Log("MSE", "Observer detached: " .. remoteName)
    end
end

local function MSE_DetachAllObservers()
    for name in pairs(MSE.ActiveObservers) do
        MSE_DetachObserver(name)
    end
    GSE_Log("MSE", "All observers detached")
end

-- ── Fire publish relay ────────────────────────────────────────
-- Fires the selected publish remote with topic + message payload.
-- The server receives this and calls MessagingService:PublishAsync,
-- broadcasting the message to every running server.
local function MSE_FirePublishRelay(topic, payload)
    local remoteName = MSE.SelectedPublish
    if not remoteName then
        GSE_Log("WARN", "No publish remote selected"); return
    end
    local reg = _G.PC and _G.PC.PR_Registry
    local rec  = reg and reg[remoteName]
    if not rec or not rec.Remote then
        GSE_Log("WARN", "Remote '" .. remoteName .. "' not in PR registry"); return
    end

    local ok, err = pcall(function()
        if rec.RemoteType == "RemoteFunction" then
            rec.Remote:InvokeServer(topic, payload)
        else
            rec.Remote:FireServer(topic, payload)
        end
    end)

    if ok then
        GSE_Log("SIGNAL", "Published → topic=\"" .. tostring(topic) ..
                "\"  payload=" .. tostring(payload):sub(1,60))
        MSE_LogMessage(topic, payload, "self_publish")
    else
        GSE_Log("WARN", "Publish relay error: " .. tostring(err))
    end
end

-- Add MSE to TAG_COLORS
TAG_COLORS["MSE"] = Color3.fromRGB(140,90,200)

-- MSE colours
C.MSE_TOPIC  = Color3.fromRGB(235,225,255)
C.MSE_SEL    = Color3.fromRGB(210,190,250)
C.MSE_OBS    = Color3.fromRGB(220,245,230)
C.MSE_OBSACT = Color3.fromRGB(160,230,180)   -- active observer highlight
C.MSE_LOG    = Color3.fromRGB(38,34,52)       -- dark purple log background

-- ============================================================
-- UI — SECTION: MessagingService — Topic Scanner
-- ============================================================
local _, sMSEScan = makeSection(pageGSE, "📨  MessagingService — Topic Scanner")

gseLabel(sMSEScan,
    "Discovers cross-server topic names via namecall hook and script scan.\n" ..
    "Topics are the channels games use for server-to-server communication.",
    11, false, C.SUBTEXT)

local mseScanRow = gseRow(sMSEScan)
local btnMSEScanWS = gseBtn(mseScanRow, "🔍 Scan Scripts",   C.BTN, C.BTNHOV, 1)
local btnMSEScanPR = gseBtn(mseScanRow, "🔗 Scan PR Bridge", C.BTN, C.BTNHOV, 2)
local btnMSEClear  = gseBtn(mseScanRow, "✕ Clear Topics",    C.BTN, C.BTNHOV, 3)

-- Topic list
local topicList = mk("Frame",{
    BackgroundColor3=C.INPUT, BorderSizePixel=0,
    Size=UDim2.new(1,-16,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    ClipsDescendants=true, Parent=sMSEScan,
})
addCorner(topicList, UDim.new(0,8)); addStroke(topicList, 1, 0.4)
mk("UIListLayout",{Padding=UDim.new(0,0),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=topicList})
mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingBottom=UDim.new(0,4),
    Parent=topicList})

local topicEmpty = gseLabel(topicList,
    "  No topics discovered yet.", 11, false, C.SUBTEXT)
topicEmpty.Size = UDim2.new(1,0,0,22)
mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=topicEmpty})

local function MSE_RebuildTopicList()
    for _, ch in ipairs(topicList:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    local count = 0
    for topic, entry in pairs(MSE.Topics) do
        count = count + 1
        local row = mk("Frame",{BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,24), LayoutOrder=count, Parent=topicList})
        mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=row})
        mk("UIPadding",{PaddingLeft=UDim.new(0,8),Parent=row})

        local badge = mk("TextLabel",{
            BackgroundColor3=C.MSE_TOPIC, BorderSizePixel=0,
            Font=Enum.Font.GothamMono, Text='"' .. topic .. '"',
            TextColor3=C.TEXT, TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,18),
            Parent=row,
        })
        addCorner(badge, UDim.new(0,4))
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5),
            Parent=badge})

        mk("TextLabel",{BackgroundColor3=Color3.fromRGB(230,220,250),
            BorderSizePixel=0, Font=Enum.Font.Gotham,
            Text=entry.source, TextColor3=C.SUBTEXT, TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,16),
            Parent=row,
        })
    end
    topicEmpty.Visible = (count == 0)
end

MSE_RebuildTopicList()

table.insert(MSE_TopicListRebuildCallbacks, function()
    MSE_RebuildTopicList()
end)

table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "MSE" then MSE_RebuildTopicList() end
end)

btnMSEScanWS.MouseButton1Click:Connect(function()
    btnMSEScanWS.Text = "⏳ Scanning..."
    task.spawn(function()
        MSE_ScanWorkspaceForTopics()
        task.wait(0.3); btnMSEScanWS.Text = "🔍 Scan Scripts"
    end)
end)

btnMSEScanPR.MouseButton1Click:Connect(function()
    btnMSEScanPR.Text = "⏳ Scanning..."
    task.spawn(function()
        MSE_ScanPRForRemotes()
        task.wait(0.3); btnMSEScanPR.Text = "🔗 Scan PR Bridge"
    end)
end)

btnMSEClear.MouseButton1Click:Connect(function()
    MSE.Topics = {}; MSE_Save()
    MSE_RebuildTopicList()
    GSE_Log("INFO", "Topic list cleared")
end)

-- ============================================================
-- UI — SECTION: Message Observer
-- ============================================================
local _, sMSEObs = makeSection(pageGSE, "👁  Message Observer")

gseLabel(sMSEObs,
    "Attach to server→client RemoteEvents that relay incoming cross-server\n" ..
    "messages. Every message received is captured in the message log below.",
    11, false, C.SUBTEXT)

gseLabel(sMSEObs, "Observe candidates from PR Bridge:", 11, true, C.TEXT)
local obsRemoteScroll = gseHScroll(sMSEObs, 52)
local obsChipRefs     = {}

local function MSE_RebuildObsChips()
    for _, ch in ipairs(obsRemoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    obsChipRefs = {}
    if #MSE.ObserveRemotes == 0 then
        gseLabel(obsRemoteScroll,
            "  No observe remotes found — run Scan PR Bridge.", 11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(MSE.ObserveRemotes) do
        local isActive = MSE.ActiveObservers[name] ~= nil
        local chip = gseChip(obsRemoteScroll, name,
            isActive and C.MSE_OBSACT or C.MSE_OBS)
        obsChipRefs[name] = chip
        -- Toggle observe on click
        chip.MouseButton1Click:Connect(function()
            if MSE.ActiveObservers[name] then
                MSE_DetachObserver(name)
                tween(chip, TweenInfo.new(0.1),
                    {BackgroundColor3=C.MSE_OBS})
            else
                MSE_AttachObserver(name)
                tween(chip, TweenInfo.new(0.1),
                    {BackgroundColor3=C.MSE_OBSACT})
            end
        end)
    end
end

MSE_RebuildObsChips()

local obsRow = gseRow(sMSEObs)
local btnObsRescan    = gseBtn(obsRow, "↻ Rescan PR Bridge",   C.BTN,     C.BTNHOV,                    1)
local btnObsDetachAll = gseBtn(obsRow, "⏹ Detach All",         C.FAIL,    Color3.fromRGB(240,210,205),  2)

local obsCountLabel = gseLabel(obsRow,
    "Active: 0", 11, true, C.SUBTEXT)

btnObsRescan.MouseButton1Click:Connect(function()
    btnObsRescan.Text = "⏳ Scanning..."
    task.spawn(function()
        MSE_ScanPRForRemotes()
        MSE_RebuildObsChips()
        task.wait(0.3); btnObsRescan.Text = "↻ Rescan PR Bridge"
    end)
end)

btnObsDetachAll.MouseButton1Click:Connect(function()
    MSE_DetachAllObservers()
    -- Restyle all chips to inactive
    for _, chip in pairs(obsChipRefs) do
        tween(chip, TweenInfo.new(0.1), {BackgroundColor3=C.MSE_OBS})
    end
    obsCountLabel.Text = "Active: 0"
end)

-- Update active observer count label in log callback
table.insert(GSE_LogCallbacks, function(entry)
    if entry.tag == "MSE" then
        local count = 0
        for _ in pairs(MSE.ActiveObservers) do count = count + 1 end
        obsCountLabel.Text = "Active: " .. count
    end
end)

-- ============================================================
-- UI — SECTION: Publish Relay
-- ============================================================
local _, sMSEPub = makeSection(pageGSE, "📡  Publish Relay")

gseLabel(sMSEPub,
    "Fire a discovered publish remote to have the server call\n" ..
    "MessagingService:PublishAsync — broadcasting your message to ALL servers.",
    11, false, C.SUBTEXT)

-- Publish remote selector
gseLabel(sMSEPub, "Publish remote:", 11, true, C.TEXT)
local pubRemoteScroll = gseHScroll(sMSEPub, 52)
local pubChipRefs     = {}

local function MSE_RebuildPubChips()
    for _, ch in ipairs(pubRemoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    pubChipRefs = {}
    if #MSE.PublishRemotes == 0 then
        gseLabel(pubRemoteScroll,
            "  No publish remotes found — run Scan PR Bridge.", 11, false, C.SUBTEXT)
        return
    end
    for _, name in ipairs(MSE.PublishRemotes) do
        local isSel = (MSE.SelectedPublish == name)
        local chip  = gseChip(pubRemoteScroll, name,
            isSel and C.MSE_SEL or C.MSE_TOPIC)
        pubChipRefs[name] = chip
        chip.MouseButton1Click:Connect(function()
            MSE.SelectedPublish = name; MSE_Save()
            GSE_Log("MSE", "Publish remote selected: " .. name)
            for n, c in pairs(pubChipRefs) do
                tween(c, TweenInfo.new(0.1), {
                    BackgroundColor3=(n==name) and C.MSE_SEL or C.MSE_TOPIC})
            end
        end)
    end
end

MSE_RebuildPubChips()

-- Topic input
gseLabel(sMSEPub, "Topic:", 11, false, C.SUBTEXT)
local topicInput = gseInput(sMSEPub, "Topic name  e.g.  GlobalAnnounce", 1)
topicInput.Text  = MSE.TopicBuffer

-- Quick-pick from discovered topics
gseLabel(sMSEPub, "Quick-pick topic:", 11, false, C.SUBTEXT)
local topicPickScroll = gseHScroll(sMSEPub, 44)

local function MSE_RebuildTopicPicks()
    for _, ch in ipairs(topicPickScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    local any = false
    for topic in pairs(MSE.Topics) do
        any = true
        gseChip(topicPickScroll, topic, C.MSE_TOPIC, function()
            topicInput.Text = topic
            MSE.TopicBuffer = topic; MSE_Save()
        end)
    end
    if not any then
        gseLabel(topicPickScroll, "  Scan first.", 11, false, C.SUBTEXT)
    end
end

MSE_RebuildTopicPicks()

table.insert(MSE_TopicListRebuildCallbacks, function()
    MSE_RebuildTopicPicks()
end)

topicInput.FocusLost:Connect(function()
    MSE.TopicBuffer = topicInput.Text; MSE_Save()
end)

-- Payload input
gseLabel(sMSEPub, "Message payload (string or JSON-ish):", 11, false, C.SUBTEXT)
local payloadInput = gseInput(sMSEPub, "e.g.  {\"action\":\"ban\",\"userId\":123}", 2)
payloadInput.Text  = MSE.PayloadBuffer

payloadInput.FocusLost:Connect(function()
    MSE.PayloadBuffer = payloadInput.Text
end)

-- Publish row
local pubActionRow = gseRow(sMSEPub)
local btnPublish   = gseBtn(pubActionRow, "📡 Publish to All Servers",
    Color3.fromRGB(235,220,255), Color3.fromRGB(220,200,250), 1)
btnPublish.Size = UDim2.new(0,180,0,28)

local btnPubRescan = gseBtn(pubActionRow, "↻ Rescan", C.BTN, C.BTNHOV, 2)

local pubStatusLabel = gseLabel(sMSEPub, "", 11, false, C.SUBTEXT)

btnPublish.MouseButton1Click:Connect(function()
    local topic   = topicInput.Text
    local payload = payloadInput.Text
    if topic == "" then
        pubStatusLabel.Text = "⚠ Topic cannot be empty"
        GSE_Log("WARN", "Publish: topic is empty")
        return
    end
    MSE_RegisterTopic(topic, "manual_publish")
    MSE_FirePublishRelay(topic, payload)
    pubStatusLabel.Text = "📡 Published → \"" .. topic .. "\""
end)

btnPubRescan.MouseButton1Click:Connect(function()
    btnPubRescan.Text = "⏳..."
    task.spawn(function()
        MSE_ScanPRForRemotes()
        MSE_RebuildPubChips()
        task.wait(0.3); btnPubRescan.Text = "↻ Rescan"
    end)
end)

-- ============================================================
-- UI — SECTION: Message Log
-- ============================================================
local _, sMSELog = makeSection(pageGSE, "📬  Cross-Server Message Log")

gseLabel(sMSELog,
    "Captures every cross-server message observed via attached RemoteEvent\n" ..
    "observers and every publish you fire. Timestamped, topic-labelled.",
    11, false, C.SUBTEXT)

local msgLogTopRow = gseRow(sMSELog)
local btnMsgClear  = gseBtn(msgLogTopRow, "🗑 Clear", C.BTN, C.BTNHOV, 1)
btnMsgClear.Size   = UDim2.new(0,80,0,24)
local msgCountLabel = gseLabel(msgLogTopRow, "0 messages", 11, false, C.SUBTEXT)

local msgScroller = mk("ScrollingFrame",{
    BackgroundColor3=C.MSE_LOG,
    BorderSizePixel=0, Size=UDim2.new(1,-16,0,200),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=5, ScrollingDirection=Enum.ScrollingDirection.Y,
    Parent=sMSELog,
})
addCorner(msgScroller, UDim.new(0,8))
mk("UIListLayout",{Padding=UDim.new(0,3),
    SortOrder=Enum.SortOrder.LayoutOrder, Parent=msgScroller})
mk("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingTop=UDim.new(0,6),
    PaddingBottom=UDim.new(0,6),PaddingRight=UDim.new(0,8),Parent=msgScroller})

local msgRows   = {}
local msgOrder  = 0

local function MSE_AddMessageRow(entry)
    msgOrder = msgOrder + 1
    local row = mk("Frame",{BackgroundTransparency=1,
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        LayoutOrder=msgOrder, Parent=msgScroller})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,
        VerticalAlignment=Enum.VerticalAlignment.Top,
        Padding=UDim.new(0,6), Parent=row})

    -- Time
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamMono,
        Text=string.format("[%.1f]", entry.time),
        TextColor3=Color3.fromRGB(100,100,130), TextSize=9,
        Size=UDim2.new(0,46,0,16),
        TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

    -- Topic badge
    local topicBadge = mk("TextLabel",{
        BackgroundColor3=C.MSE_TOPIC, BorderSizePixel=0,
        Font=Enum.Font.GothamBold,
        Text=entry.topic:sub(1, 24),
        TextColor3=Color3.fromRGB(80,40,140), TextSize=9,
        AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,14),
        TextXAlignment=Enum.TextXAlignment.Center, Parent=row,
    })
    addCorner(topicBadge, UDim.new(0,4))
    mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),
        Parent=topicBadge})

    -- Source tag
    local srcColor = entry.source:find("self_publish")
        and Color3.fromRGB(200,180,255)
        or  Color3.fromRGB(180,230,190)
    local srcBadge = mk("TextLabel",{
        BackgroundColor3=srcColor, BorderSizePixel=0,
        Font=Enum.Font.Gotham, Text=entry.source:sub(1,20),
        TextColor3=Color3.fromRGB(60,60,60), TextSize=8,
        AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,0,14),
        Parent=row,
    })
    addCorner(srcBadge, UDim.new(0,4))
    mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),
        Parent=srcBadge})

    -- Payload
    local payloadStr = DSE_Serialise and
        DSE_Serialise(entry.payload, 0) or tostring(entry.payload)
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamMono,
        Text=payloadStr:sub(1, 120),
        TextColor3=Color3.fromRGB(160,220,255), TextSize=9,
        AutomaticSize=Enum.AutomaticSize.XY, Size=UDim2.new(0,0,0,0),
        TextXAlignment=Enum.TextXAlignment.Left,
        TextWrapped=true, Parent=row})

    table.insert(msgRows, row)
    if #msgRows > 100 then
        local old = table.remove(msgRows, 1)
        if old and old.Parent then old:Destroy() end
    end

    msgCountLabel.Text = #MSE.MessageLog .. " message(s)"
end

-- Wire message log callbacks to UI
table.insert(MSE_MessageLogCallbacks, function(entry)
    MSE_AddMessageRow(entry)
end)

btnMsgClear.MouseButton1Click:Connect(function()
    MSE.MessageLog = {}
    for _, r in ipairs(msgRows) do if r and r.Parent then r:Destroy() end end
    msgRows = {}; msgOrder = 0
    msgCountLabel.Text = "0 messages"
end)

-- Restore message log from session
for i = #MSE.MessageLog, 1, -1 do MSE_AddMessageRow(MSE.MessageLog[i]) end

-- ============================================================
-- EXPORT MSE
-- ============================================================
_G.PC.MSE                = MSE
_G.PC.MSE_RegisterTopic  = MSE_RegisterTopic
_G.PC.MSE_LogMessage     = MSE_LogMessage



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
    Font=Enum.Font.GothamMono,
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
                Font=Enum.Font.GothamMono, Text=text, TextColor3=C.TEXT,
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
    Font=Enum.Font.GothamMono, PlaceholderText="arg#",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,46,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=supAddRow,
})
addCorner(supFieldInput, UDim.new(0,6)); addStroke(supFieldInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=supFieldInput})

local supPatternInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.GothamMono, PlaceholderText="pattern",
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
                Font=Enum.Font.GothamMono, Text=text, TextColor3=C.TEXT,
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
    Font=Enum.Font.GothamMono, PlaceholderText="arg#",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,40,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=modAddRow,
})
addCorner(modFieldInput, UDim.new(0,6)); addStroke(modFieldInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=modFieldInput})

local modPatternInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.GothamMono, PlaceholderText="match",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT, TextSize=10,
    Size=UDim2.new(0,80,0,26), TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=modAddRow,
})
addCorner(modPatternInput, UDim.new(0,6)); addStroke(modPatternInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=modPatternInput})

local modReplInput = mk("TextBox",{BackgroundColor3=C.INPUT,BorderSizePixel=0,
    Font=Enum.Font.GothamMono, PlaceholderText="replace",
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
                Font=mono and Enum.Font.GothamMono or Enum.Font.Gotham,
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
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamMono,
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
        Font=Enum.Font.GothamMono, Text=methodShort,
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
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.GothamMono,
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


-- ============================================================
-- EXPORT
-- ============================================================
_G.PC.GSE                  = GSE
_G.PC.GSE_Log              = GSE_Log
_G.PC.GSE_RegisterProduct  = GSE_RegisterProduct
_G.PC.GSE_RegisterGamePass = GSE_RegisterGamePass
