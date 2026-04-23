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
local bsePage = (PC.GSE_SubPages and PC.GSE_SubPages["Badge"])
if not bsePage then warn("[BSE] sub-page not found"); return end
local mk              = PC.mk
local addCorner       = PC.addCorner
local addStroke       = PC.addStroke
local hookHover       = PC.hookHover
local tween           = PC.tween
local makeSection     = PC.makeSection
local clickSound      = PC.clickSound
local pulseClick      = PC.pulseClick

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
local _, sBadgeScan = makeSection(bsePage,
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
            Font=Enum.Font.RobotoMono, Text=id, TextColor3=C.TEXT,
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
local _, sBadgeAct = makeSection(bsePage, "🎖  Badge — Check & Award")

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
local _, sBadgeRemote = makeSection(bsePage, "📡  Badge Award Remote")

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

-- EXPORT BSE
_G.PC.BSE = BSE
