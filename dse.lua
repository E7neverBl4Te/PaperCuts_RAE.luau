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
            Font=Enum.Font.RobotoMono, Text='"' .. name .. '"',
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
            Font=Enum.Font.RobotoMono, Text='"' .. entry.pattern .. '"',
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
            Font=Enum.Font.RobotoMono, Text=key,
            TextColor3=C.TEXT, TextSize=10,
            Size=UDim2.new(0,120,0,24),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=row})

        -- Value edit box
        local box = mk("TextBox",{
            BackgroundColor3=C.DSE_EDIT, BorderSizePixel=0,
            Font=Enum.Font.RobotoMono, Text=entry.displayValue,
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
    Font=Enum.Font.RobotoMono, PlaceholderText="key",
    PlaceholderColor3=C.SUBTEXT, Text="", TextColor3=C.TEXT,
    TextSize=11, Size=UDim2.new(0,100,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,
    ClearTextOnFocus=false, Parent=manualRow,
})
addCorner(manualKeyInput, UDim.new(0,6)); addStroke(manualKeyInput, 1, 0.45)
mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=manualKeyInput})

local manualValInput = mk("TextBox",{
    BackgroundColor3=C.DSE_EDIT, BorderSizePixel=0,
    Font=Enum.Font.RobotoMono, PlaceholderText="value",
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

-- EXPORT DSE
_G.PC.DSE = DSE
_G.PC.DSE_Serialise = DSE_Serialise
