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
            Font=Enum.Font.RobotoMono, Text='"' .. topic .. '"',
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
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
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
    mk("TextLabel",{BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
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

-- EXPORT MSE
_G.PC.MSE = MSE
