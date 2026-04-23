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

local PC = _G.PC
if not PC or not PC.makeSection then
    warn("[GSE] _G.PC.makeSection not found — ensure ui_base.lua loaded.")
    return
end

-- ── Imports from _G.PC ────────────────────────────────────────
local mk          = PC.mk
local addCorner   = PC.addCorner
local addStroke   = PC.addStroke
local tween       = PC.tween
local pulseClick  = PC.pulseClick
local hookHover   = PC.hookHover
local clickSound  = PC.clickSound
local makeSection = PC.makeSection
local makePage    = PC.makePage

-- Create our own page — ui_base.lua is at its local limit
-- so we create pageGSE here and export it for boot.lua
local pageGSE = makePage("GameServiceEdit")
PC.pageGSE    = pageGSE

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
            Font=Enum.Font.RobotoMono, Text=id, TextColor3=C.TEXT, TextSize=10,
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
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
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
-- EXPORT (gse.lua core)
-- ============================================================
_G.PC.GSE                   = GSE
_G.PC.GSE_Log               = GSE_Log
_G.PC.GSE_LogCallbacks      = GSE_LogCallbacks
_G.PC.GSE_RegisterProduct   = GSE_RegisterProduct
_G.PC.GSE_RegisterGamePass  = GSE_RegisterGamePass
_G.PC.GSE_PERSIST_KEY       = GSE_PERSIST_KEY
_G.PC.TAG_COLORS            = TAG_COLORS
_G.PC.C                     = C
_G.PC.gseBtn                = gseBtn
_G.PC.gseLabel              = gseLabel
_G.PC.gseInput              = gseInput
_G.PC.gseRow                = gseRow
_G.PC.gseHScroll            = gseHScroll
_G.PC.gseChip               = gseChip
_G.PC.pageGSE               = pageGSE
