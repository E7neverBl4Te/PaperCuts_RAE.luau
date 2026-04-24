-- ============================================================
-- cscp.lua — Correctly Structured Crafted Packet
-- Sub-section within the PR Bridge page.
--
-- Workflow:
--   1. Select a remote from the PR Manifest Browser and click
--      "Craft →" — or pick one from the CSCP remote selector.
--   2. CSCP reads the remote's captured schema from
--      PR_SchemaInfer and auto-populates the field builder.
--   3. Edit any field manually — type, value, position.
--   4. Validate → Fire (single remote) or Broadcast (multi).
--   5. Packet stored in history for recall and re-fire.
--
-- Schema inference:
--   Uses PR_SchemaInfer.GetSchema(rec) for type information.
--   Token detection layer identifies:
--     - Incrementing integers      → SequenceNumber
--     - Fixed-length strings       → SessionToken
--     - LocalPlayer.UserId match   → PlayerRef
--     - Consistent boolean         → Flag
--     - Consistent table shape     → Struct (recursed)
-- ============================================================

local _C = _G.PC
local _U = _G.PCU
if not _C or not _U then
    warn("[CSCP] _G.PC/_G.PCU not available"); return
end
if not _U.pagePR then
    warn("[CSCP] pagePR not found — ensure pr_ui.lua loaded"); return
end

local mk              = _C.mk
local addCorner       = _C.addCorner
local addStroke       = _C.addStroke
local pulseClick      = _C.pulseClick
local clickSound      = _C.clickSound
local tween           = _C.tween
local hookHover       = _C.hookHover
local makeSection     = _U.makeSection
local makeButton      = _U.makeButton
local sendNotification= _U.sendNotification
local pagePR          = _U.pagePR  -- kept for guard check
local prPageCSCP      = (_G.PC and _G.PC.prPageCSCP)
if not prPageCSCP then
    -- pr_ui.lua runs before cscp.lua, so prPageCSCP must exist
    warn("[CSCP] prPageCSCP not found — ensure pr_ui.lua loaded first")
    return
end
local PR_Registry     = _C.PR_Registry
local PR_SchemaInfer  = _C.PR_SchemaInfer

-- ============================================================
-- CSCP STATE
-- ============================================================
local CSCP = {
    SelectedRemote  = nil,   -- name string
    Fields          = {},    -- [i] = { pos, type, value, label, tokenHint }
    History         = {},    -- [i] = { time, remote, fields, result }
    BroadcastList   = {},    -- [name] = true
    InferCaptures   = {},    -- [remoteName] = { [captureIdx] = {args...} }
    AutoMode        = true,
}

-- Persist key
local CSCP_KEY = "PaperClay_CSCP_v1"
local function CSCP_Save()
    pcall(function()
        _G[CSCP_KEY] = {
            SelectedRemote = CSCP.SelectedRemote,
            History        = CSCP.History,
            AutoMode       = CSCP.AutoMode,
        }
    end)
end
local function CSCP_Load()
    pcall(function()
        local s = _G[CSCP_KEY]
        if type(s) ~= "table" then return end
        if type(s.SelectedRemote) == "string" then CSCP.SelectedRemote = s.SelectedRemote end
        if type(s.History)        == "table"  then CSCP.History        = s.History        end
        if type(s.AutoMode)       == "boolean" then CSCP.AutoMode      = s.AutoMode       end
    end)
end
CSCP_Load()

-- ── Token detection heuristics ────────────────────────────────
local LP = game:GetService("Players").LocalPlayer

local function CSCP_DetectTokenHint(val, captureHistory, pos)
    local t = type(val)
    -- PlayerRef: matches LocalPlayer UserId
    if t == "number" and val == LP.UserId then
        return "PlayerRef"
    end
    -- SequenceNumber: integer that increments across captures
    if t == "number" and val == math.floor(val) then
        if captureHistory and #captureHistory >= 2 then
            local prev = captureHistory[#captureHistory - 1]
            if prev and type(prev[pos]) == "number" then
                local delta = val - prev[pos]
                if delta > 0 and delta <= 10 then
                    return "SeqNum(+" .. tostring(delta) .. ")"
                end
            end
        end
    end
    -- SessionToken: fixed-length string 8-64 chars, not changing
    if t == "string" and #val >= 8 and #val <= 64 then
        if captureHistory and #captureHistory >= 2 then
            local allSame = true
            for _, cap in ipairs(captureHistory) do
                if cap[pos] ~= val then allSame = false; break end
            end
            if allSame then return "SessionToken" end
        end
        -- Looks like a hash/token even without history
        if val:match("^[a-fA-F0-9]+$") and #val >= 16 then
            return "HexToken"
        end
    end
    return nil
end

-- ── Schema → field list ───────────────────────────────────────
local function CSCP_InferFields(remoteName)
    local fields = {}
    local rec = PR_Registry and PR_Registry[remoteName]
    if not rec then return fields end

    local captures = CSCP.InferCaptures[remoteName] or {}

    -- Try PR_SchemaInfer first
    local schema = nil
    if PR_SchemaInfer and PR_SchemaInfer.GetSchema then
        pcall(function() schema = PR_SchemaInfer.GetSchema(rec) end)
    end

    if schema and type(schema) == "table" and #schema > 0 then
        for i, argDef in ipairs(schema) do
            local hint = nil
            local sampleVal = argDef.Sample or argDef.Default
            if sampleVal ~= nil then
                hint = CSCP_DetectTokenHint(sampleVal, captures, i)
            end
            fields[i] = {
                pos       = i,
                argType   = argDef.Type or "unknown",
                value     = sampleVal ~= nil and tostring(sampleVal) or "",
                label     = argDef.Name or ("arg" .. i),
                tokenHint = hint,
                optional  = argDef.Optional or false,
            }
        end
    elseif #captures > 0 then
        -- Fall back to capture analysis
        local latest = captures[#captures]
        for i, v in ipairs(latest) do
            local hint = CSCP_DetectTokenHint(v, captures, i)
            fields[i] = {
                pos       = i,
                argType   = type(v),
                value     = tostring(v),
                label     = "arg" .. i,
                tokenHint = hint,
                optional  = false,
            }
        end
    end

    return fields
end

-- ── Record a capture for a remote ────────────────────────────
-- Called by the __namecall hook when the game fires a remote
local function CSCP_RecordCapture(remoteName, args)
    if not CSCP.InferCaptures[remoteName] then
        CSCP.InferCaptures[remoteName] = {}
    end
    local caps = CSCP.InferCaptures[remoteName]
    table.insert(caps, args)
    if #caps > 20 then table.remove(caps, 1) end
    -- If this is the currently selected remote and auto mode,
    -- re-infer schema on every new capture
    if CSCP.AutoMode and CSCP.SelectedRemote == remoteName then
        CSCP.Fields = CSCP_InferFields(remoteName)
        if _G.PC.CSCP_RebuildFieldUI then
            pcall(_G.PC.CSCP_RebuildFieldUI)
        end
    end
end

-- Hook into __namecall to capture native FireServer/InvokeServer calls
local function CSCP_InstallCaptureHook()
    local ok, err = pcall(function()
        local mt    = getrawmetatable(game)
        local oldNC = rawget(mt, "__namecall")
        setreadonly(mt, false)
        local function newNC(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" or method == "InvokeServer" then
                local name = self.Name
                if name and PR_Registry and PR_Registry[name] then
                    local args = {...}
                    pcall(CSCP_RecordCapture, name, args)
                end
            end
            if oldNC then return oldNC(self, ...) end
        end
        mt.__namecall = (type(newcclosure)=="function") and newcclosure(newNC) or newNC
        setreadonly(mt, true)
    end)
    if not ok then
        warn("[CSCP] Capture hook failed: " .. tostring(err))
    end
end
CSCP_InstallCaptureHook()

-- ── Parse a value string back into a Lua value ───────────────
local function CSCP_ParseValue(str, argType)
    if argType == "number" then
        return tonumber(str) or 0
    elseif argType == "boolean" then
        return str == "true"
    elseif argType == "nil" then
        return nil
    elseif argType == "table" then
        -- Attempt JSON-ish parse
        local ok, result = pcall(function()
            return game:GetService("HttpService"):JSONDecode(str)
        end)
        if ok then return result end
        return {}
    else
        -- String: strip surrounding quotes if present
        if str:sub(1,1) == '"' and str:sub(-1) == '"' then
            return str:sub(2,-2)
        end
        return str
    end
end

-- ── Build argument table from fields ─────────────────────────
local function CSCP_BuildArgs()
    local args = {}
    for _, field in ipairs(CSCP.Fields) do
        args[field.pos] = CSCP_ParseValue(field.value, field.argType)
    end
    return args
end

-- ── Validate fields before fire ──────────────────────────────
local function CSCP_Validate()
    local issues = {}
    for _, field in ipairs(CSCP.Fields) do
        if not field.optional and field.value == "" then
            table.insert(issues, "arg" .. field.pos .. " is empty")
        end
        if field.argType == "number" and field.value ~= "" then
            if tonumber(field.value) == nil then
                table.insert(issues, "arg" .. field.pos .. " expects number")
            end
        end
    end
    return issues
end

-- ── Fire the packet ───────────────────────────────────────────
local function CSCP_Fire(remoteName, args)
    local rec = PR_Registry and PR_Registry[remoteName]
    if not rec or not rec.Remote then
        return false, "Remote not in registry"
    end
    local ok, err = pcall(function()
        if rec.Remote.ClassName == "RemoteFunction" then
            rec.Remote:InvokeServer(table.unpack(args))
        else
            rec.Remote:FireServer(table.unpack(args))
        end
    end)
    return ok, ok and "OK" or tostring(err)
end

-- ── Add to history ────────────────────────────────────────────
local function CSCP_AddHistory(remoteName, fields, results)
    table.insert(CSCP.History, 1, {
        time    = os.clock(),
        remote  = remoteName,
        fields  = fields,
        results = results,
    })
    if #CSCP.History > 50 then table.remove(CSCP.History) end
    CSCP_Save()
end

-- ============================================================
-- UI
-- ============================================================
local C = {
    BG      = Color3.fromRGB(250,245,238),
    CARD    = Color3.fromRGB(255,252,246),
    TEXT    = Color3.fromRGB(40,36,30),
    SUB     = Color3.fromRGB(110,100,90),
    SEP     = Color3.fromRGB(225,218,208),
    ACTIVE  = Color3.fromRGB(200,120,50),
    SUCCESS = Color3.fromRGB(80,170,100),
    FAIL    = Color3.fromRGB(190,70,60),
    TOKEN   = Color3.fromRGB(255,240,200),
    SEQ     = Color3.fromRGB(220,235,255),
    PLAYER  = Color3.fromRGB(220,255,230),
    AUTO    = Color3.fromRGB(225,240,225),
    MANUAL  = Color3.fromRGB(240,230,255),
    BCAST   = Color3.fromRGB(255,235,215),
    HIST    = Color3.fromRGB(40,36,34),
    INPUT   = Color3.fromRGB(248,244,238),
    FIELD   = Color3.fromRGB(244,240,234),
}

local HINT_COLORS = {
    SessionToken = C.TOKEN,
    HexToken     = C.TOKEN,
    SeqNum       = C.SEQ,
    PlayerRef    = C.PLAYER,
}
local function HintColor(hint)
    if not hint then return C.FIELD end
    for k, col in pairs(HINT_COLORS) do
        if hint:find(k, 1, true) then return col end
    end
    return C.FIELD
end

local function cscpLabel(parent, text, size, bold, color)
    return mk("TextLabel", {
        BackgroundTransparency = 1,
        Font    = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
        Text    = text,
        TextColor3 = color or C.TEXT,
        TextSize   = size or 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutomaticSize  = Enum.AutomaticSize.XY,
        Parent  = parent,
    })
end

local function cscpInput(parent, placeholder, width)
    local b = mk("TextBox", {
        BackgroundColor3 = C.INPUT, BorderSizePixel = 0,
        Font             = Enum.Font.RobotoMono,
        PlaceholderText  = placeholder or "",
        PlaceholderColor3= C.SUB,
        Text             = "", TextColor3 = C.TEXT,
        TextSize         = 10,
        Size             = UDim2.new(0, width or 140, 0, 24),
        TextXAlignment   = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        Parent           = parent,
    })
    addCorner(b, UDim.new(0, 5))
    addStroke(b, 1, 0.4)
    mk("UIPadding", {PaddingLeft=UDim.new(0,6), Parent=b})
    return b
end

local function cscpBtn(parent, text, bg, lo)
    bg = bg or Color3.fromRGB(236,229,220)
    local hov = Color3.fromRGB(255,250,242)
    local b = mk("TextButton", {
        AutoButtonColor  = false,
        BackgroundColor3 = bg, BorderSizePixel = 0,
        Font             = Enum.Font.GothamSemibold,
        Text             = text, TextColor3 = C.TEXT,
        TextSize         = 11,
        AutomaticSize    = Enum.AutomaticSize.X,
        Size             = UDim2.new(0, 0, 0, 28),
        LayoutOrder      = lo or 0,
        Parent           = parent,
    })
    addCorner(b, UDim.new(0, 8))
    addStroke(b, 1, 0.4)
    hookHover(b, bg, hov, 0.4, 0.2)
    b.MouseButton1Click:Connect(function() pulseClick(b); clickSound() end)
    mk("UIPadding", {PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=b})
    return b
end

local function row(parent, lo)
    local f = mk("Frame", {
        BackgroundTransparency = 1,
        Size        = UDim2.new(1, -16, 0, 32),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = lo or 0, Parent = parent,
    })
    mk("UIListLayout", {
        FillDirection       = Enum.FillDirection.Horizontal,
        VerticalAlignment   = Enum.VerticalAlignment.Center,
        Padding             = UDim.new(0, 8), Parent = f,
    })
    return f
end

-- ── SECTION: CSCP Header + Remote Selector ───────────────────
local _, sHeader = makeSection(prPageCSCP, "📦  CSCP — Packet Crafter")

cscpLabel(sHeader,
    "Builds structurally correct packets for any discovered remote.\n" ..
    "Auto-mode infers schema from live captures. Manual mode for full control.",
    11, false, C.SUB)

-- Mode toggle
local modeRow = row(sHeader)
local btnAuto   = cscpBtn(modeRow, "⚡ Auto",   CSCP.AutoMode  and C.AUTO   or nil, 1)
local btnManual = cscpBtn(modeRow, "✏  Manual", not CSCP.AutoMode and C.MANUAL or nil, 2)
local modeLbl   = cscpLabel(modeRow,
    "Mode: " .. (CSCP.AutoMode and "Auto" or "Manual"), 11, true, C.SUB)

local function CSCP_SetMode(auto)
    CSCP.AutoMode = auto; CSCP_Save()
    modeLbl.Text = "Mode: " .. (auto and "Auto" or "Manual")
    tween(btnAuto,   TweenInfo.new(0.12), {BackgroundColor3 = auto  and C.AUTO   or Color3.fromRGB(236,229,220)})
    tween(btnManual, TweenInfo.new(0.12), {BackgroundColor3 = not auto and C.MANUAL or Color3.fromRGB(236,229,220)})
end

btnAuto.MouseButton1Click:Connect(function()   CSCP_SetMode(true)  end)
btnManual.MouseButton1Click:Connect(function() CSCP_SetMode(false) end)

-- Remote selector
cscpLabel(sHeader, "Active remote:", 11, true, C.TEXT)
local remoteScroll = mk("ScrollingFrame", {
    BackgroundColor3    = C.INPUT, BorderSizePixel = 0,
    Size                = UDim2.new(1, -16, 0, 52),
    CanvasSize          = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollBarThickness  = 4,
    ScrollingDirection  = Enum.ScrollingDirection.X,
    Parent              = sHeader,
})
addCorner(remoteScroll, UDim.new(0, 8))
addStroke(remoteScroll, 1, 0.4)
mk("UIListLayout", {
    FillDirection       = Enum.FillDirection.Horizontal,
    VerticalAlignment   = Enum.VerticalAlignment.Center,
    Padding             = UDim.new(0, 6), Parent = remoteScroll,
})
mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), Parent=remoteScroll})

local remoteChipRefs = {}
local activeRemoteLabel = cscpLabel(sHeader,
    CSCP.SelectedRemote and ("Selected: " .. CSCP.SelectedRemote) or "No remote selected",
    11, false, C.SUB)

local function CSCP_RebuildRemoteChips()
    for _, ch in ipairs(remoteScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    remoteChipRefs = {}
    if not PR_Registry then return end
    for name in pairs(PR_Registry) do
        local isSel = (CSCP.SelectedRemote == name)
        local chip = mk("TextButton", {
            AutoButtonColor  = false,
            BackgroundColor3 = isSel and C.ACTIVE or Color3.fromRGB(235,228,218),
            BorderSizePixel  = 0,
            Font             = Enum.Font.GothamSemibold,
            Text             = name:sub(1,28),
            TextColor3       = isSel and Color3.fromRGB(255,252,245) or C.TEXT,
            TextSize         = 10,
            AutomaticSize    = Enum.AutomaticSize.X,
            Size             = UDim2.new(0, 0, 0, 36),
            Parent           = remoteScroll,
        })
        addCorner(chip, UDim.new(0, 8))
        addStroke(chip, 1, isSel and 0.1 or 0.5)
        mk("UIPadding", {PaddingLeft=UDim.new(0,8), PaddingRight=UDim.new(0,8), Parent=chip})
        remoteChipRefs[name] = chip

        chip.MouseButton1Click:Connect(function()
            clickSound(); pulseClick(chip)
            _G.PC.CSCP_LoadRemote(name)
        end)
    end
end

-- Scan button
local remoteHeaderRow = row(sHeader)
local btnScanRemotes = cscpBtn(remoteHeaderRow, "↻ Refresh Remotes", nil, 1)
local captureCountLbl = cscpLabel(remoteHeaderRow, "0 captures", 11, false, C.SUB)

btnScanRemotes.MouseButton1Click:Connect(function()
    CSCP_RebuildRemoteChips()
    local total = 0
    for _, caps in pairs(CSCP.InferCaptures) do total = total + #caps end
    captureCountLbl.Text = total .. " capture(s) across all remotes"
end)

-- ── SECTION: Field Builder ────────────────────────────────────
local _, sBuilder = makeSection(prPageCSCP, "🔧  Packet Field Builder")

cscpLabel(sBuilder,
    "Each row is one argument. Types auto-inferred from captures.\n" ..
    "Token hints shown in colour. Edit any value manually.",
    11, false, C.SUB)

-- Field list scroll
local fieldScroll = mk("ScrollingFrame", {
    BackgroundColor3    = Color3.fromRGB(246,242,235),
    BorderSizePixel     = 0,
    Size                = UDim2.new(1, -16, 0, 220),
    CanvasSize          = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness  = 5,
    ScrollingDirection  = Enum.ScrollingDirection.Y,
    Parent              = sBuilder,
})
addCorner(fieldScroll, UDim.new(0, 8))
addStroke(fieldScroll, 1, 0.4)
mk("UIListLayout", {
    Padding     = UDim.new(0, 3),
    SortOrder   = Enum.SortOrder.LayoutOrder,
    Parent      = fieldScroll,
})
mk("UIPadding", {
    PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6),
    PaddingTop=UDim.new(0,6),  PaddingBottom=UDim.new(0,6),
    Parent=fieldScroll,
})

local fieldEmpty = mk("TextLabel", {
    BackgroundTransparency = 1,
    Font       = Enum.Font.Gotham,
    Text       = "  Select a remote to populate fields.",
    TextColor3 = C.SUB, TextSize = 11,
    Size       = UDim2.new(1, 0, 0, 28),
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent     = fieldScroll,
})

-- Header row
local fieldHeaderRow = mk("Frame", {
    BackgroundColor3 = Color3.fromRGB(238,232,222),
    BorderSizePixel  = 0,
    Size             = UDim2.new(1, -16, 0, 22),
    Parent           = sBuilder,
})
addCorner(fieldHeaderRow, UDim.new(0, 6))
mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, Parent=fieldHeaderRow})
mk("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=fieldHeaderRow})
local function hCell(text, w)
    mk("TextLabel", {
        BackgroundTransparency = 1,
        Font       = Enum.Font.GothamBold,
        Text       = text, TextColor3 = C.SUB, TextSize = 9,
        Size       = UDim2.new(0, w, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent     = fieldHeaderRow,
    })
end
hCell("#",    24)
hCell("LABEL",70)
hCell("TYPE", 64)
hCell("VALUE",150)
hCell("HINT", 90)

-- Field row references for live updates
local fieldRowRefs = {}

local function CSCP_RebuildFieldUI()
    for _, ch in ipairs(fieldScroll:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    fieldRowRefs = {}

    local count = #CSCP.Fields
    fieldEmpty.Visible = (count == 0)

    for i, field in ipairs(CSCP.Fields) do
        local hintCol = HintColor(field.tokenHint)
        local row_f = mk("Frame", {
            BackgroundColor3 = hintCol,
            BorderSizePixel  = 0,
            Size             = UDim2.new(1, 0, 0, 30),
            LayoutOrder      = i,
            Parent           = fieldScroll,
        })
        addCorner(row_f, UDim.new(0, 5))
        addStroke(row_f, 1, 0.25)
        mk("UIListLayout", {
            FillDirection     = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding           = UDim.new(0, 4),
            Parent            = row_f,
        })
        mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,4), Parent=row_f})

        -- Position number
        mk("TextLabel", {
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=tostring(i), TextColor3=C.SUB, TextSize=10,
            Size=UDim2.new(0,20,0,24), TextXAlignment=Enum.TextXAlignment.Center,
            Parent=row_f,
        })

        -- Label input
        local lblBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(252,248,242), BorderSizePixel=0,
            Font=Enum.Font.GothamSemibold, Text=field.label,
            TextColor3=C.TEXT, TextSize=10,
            Size=UDim2.new(0,68,0,22),
            TextXAlignment=Enum.TextXAlignment.Left,
            ClearTextOnFocus=false, Parent=row_f,
        })
        addCorner(lblBox, UDim.new(0,4)); addStroke(lblBox, 1, 0.4)
        mk("UIPadding",{PaddingLeft=UDim.new(0,4),Parent=lblBox})
        lblBox.FocusLost:Connect(function()
            if CSCP.Fields[i] then CSCP.Fields[i].label = lblBox.Text end
        end)

        -- Type cycle button
        local TYPE_CYCLE = {"string","number","boolean","table","nil"}
        local typeIdx = 1
        for ti, tn in ipairs(TYPE_CYCLE) do
            if tn == field.argType then typeIdx = ti; break end
        end
        local typeBtn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(228,220,255),
            BorderSizePixel=0, Font=Enum.Font.GothamSemibold,
            Text=field.argType, TextColor3=C.TEXT, TextSize=9,
            Size=UDim2.new(0,60,0,22), Parent=row_f,
        })
        addCorner(typeBtn, UDim.new(0,4)); addStroke(typeBtn, 1, 0.4)
        typeBtn.MouseButton1Click:Connect(function()
            typeIdx = (typeIdx % #TYPE_CYCLE) + 1
            local newType = TYPE_CYCLE[typeIdx]
            if CSCP.Fields[i] then CSCP.Fields[i].argType = newType end
            typeBtn.Text = newType
        end)

        -- Value input
        local valBox = mk("TextBox", {
            BackgroundColor3=Color3.fromRGB(255,254,250), BorderSizePixel=0,
            Font=Enum.Font.RobotoMono, Text=field.value,
            TextColor3=Color3.fromRGB(30,60,120), TextSize=10,
            Size=UDim2.new(0,148,0,22),
            TextXAlignment=Enum.TextXAlignment.Left,
            ClearTextOnFocus=false, Parent=row_f,
        })
        addCorner(valBox, UDim.new(0,4)); addStroke(valBox, 1, 0.4)
        mk("UIPadding",{PaddingLeft=UDim.new(0,5),Parent=valBox})
        valBox.FocusLost:Connect(function()
            if CSCP.Fields[i] then CSCP.Fields[i].value = valBox.Text end
        end)

        -- Token hint badge
        if field.tokenHint then
            local hBadge = mk("TextLabel", {
                BackgroundColor3=hintCol, BorderSizePixel=0,
                Font=Enum.Font.GothamSemibold,
                Text=field.tokenHint:sub(1,12),
                TextColor3=Color3.fromRGB(80,60,20), TextSize=8,
                AutomaticSize=Enum.AutomaticSize.X,
                Size=UDim2.new(0,0,0,18), Parent=row_f,
            })
            addCorner(hBadge, UDim.new(0,4))
            mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),Parent=hBadge})
        end

        -- Delete field button
        local delBtn = mk("TextButton", {
            AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(248,220,215),
            BorderSizePixel=0, Font=Enum.Font.GothamBold,
            Text="✕", TextColor3=Color3.fromRGB(160,50,50), TextSize=10,
            Size=UDim2.new(0,20,0,20), Parent=row_f,
        })
        addCorner(delBtn, UDim.new(0,5))
        local idx = i
        delBtn.MouseButton1Click:Connect(function()
            table.remove(CSCP.Fields, idx)
            CSCP_RebuildFieldUI()
        end)

        fieldRowRefs[i] = { row=row_f, valBox=valBox, typeBtn=typeBtn }
    end
end

-- Export rebuild for auto-mode updates
_G.PC.CSCP_RebuildFieldUI = CSCP_RebuildFieldUI

-- Add field button
local addFieldRow = row(sBuilder)
local btnAddField = cscpBtn(addFieldRow, "+ Add Field", nil, 1)
local btnClearFields = cscpBtn(addFieldRow, "✕ Clear All", nil, 2)
local btnReinfer = cscpBtn(addFieldRow, "↻ Re-Infer", Color3.fromRGB(225,240,225), 3)

btnAddField.MouseButton1Click:Connect(function()
    local nextPos = #CSCP.Fields + 1
    table.insert(CSCP.Fields, {
        pos=nextPos, argType="string", value="",
        label="arg"..nextPos, tokenHint=nil, optional=false,
    })
    CSCP_RebuildFieldUI()
end)

btnClearFields.MouseButton1Click:Connect(function()
    CSCP.Fields = {}
    CSCP_RebuildFieldUI()
end)

btnReinfer.MouseButton1Click:Connect(function()
    if not CSCP.SelectedRemote then return end
    CSCP.Fields = CSCP_InferFields(CSCP.SelectedRemote)
    CSCP_RebuildFieldUI()
    local total = #(CSCP.InferCaptures[CSCP.SelectedRemote] or {})
    sendNotification("CSCP: Re-inferred from " .. total .. " capture(s)", "Info")
end)

-- ── SECTION: Validation + Fire ────────────────────────────────
local _, sFireSection = makeSection(prPageCSCP, "🚀  Validate & Fire")

cscpLabel(sFireSection,
    "Validates type correctness before firing. Results logged to history.",
    11, false, C.SUB)

-- Validation result label
local validLabel = mk("TextLabel", {
    BackgroundTransparency = 1,
    Font       = Enum.Font.GothamSemibold,
    Text       = "Ready to validate.",
    TextColor3 = C.SUB, TextSize = 11,
    Size       = UDim2.new(1, -16, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextWrapped = true,
    Parent     = sFireSection,
})

-- Fire row
local fireRow = row(sFireSection)
local btnValidate = cscpBtn(fireRow, "✓ Validate",       Color3.fromRGB(225,238,250), 1)
local btnFire     = cscpBtn(fireRow, "🚀 Fire Packet",   Color3.fromRGB(255,235,210), 2)
local btnBroadcast= cscpBtn(fireRow, "📡 Broadcast",     C.BCAST,                     3)

local fireResultLabel = mk("TextLabel", {
    BackgroundTransparency = 1,
    Font       = Enum.Font.RobotoMono,
    Text       = "",
    TextColor3 = C.TEXT, TextSize = 10,
    Size       = UDim2.new(1, -16, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextWrapped = true,
    Parent     = sFireSection,
})

btnValidate.MouseButton1Click:Connect(function()
    local issues = CSCP_Validate()
    if #issues == 0 then
        validLabel.Text = "✅ All fields valid — ready to fire"
        validLabel.TextColor3 = C.SUCCESS
    else
        validLabel.Text = "⚠ " .. table.concat(issues, "  |  ")
        validLabel.TextColor3 = C.FAIL
    end
end)

btnFire.MouseButton1Click:Connect(function()
    if not CSCP.SelectedRemote then
        fireResultLabel.Text = "⚠ No remote selected"
        fireResultLabel.TextColor3 = C.FAIL
        return
    end
    local issues = CSCP_Validate()
    if #issues > 0 then
        fireResultLabel.Text = "⚠ Validation failed: " .. issues[1]
        fireResultLabel.TextColor3 = C.FAIL
        return
    end
    local args    = CSCP_BuildArgs()
    local ok, res = CSCP_Fire(CSCP.SelectedRemote, args)
    fireResultLabel.Text = (ok and "✅ " or "❌ ") ..
        CSCP.SelectedRemote .. " → " .. res
    fireResultLabel.TextColor3 = ok and C.SUCCESS or C.FAIL
    CSCP_AddHistory(CSCP.SelectedRemote, CSCP.Fields, {[CSCP.SelectedRemote]=res})
    if _G.PC.CSCP_RebuildHistoryUI then
        pcall(_G.PC.CSCP_RebuildHistoryUI)
    end
end)

-- Broadcast: fire to all checked remotes simultaneously
btnBroadcast.MouseButton1Click:Connect(function()
    local targets = {}
    for name in pairs(CSCP.BroadcastList) do
        if PR_Registry and PR_Registry[name] then
            table.insert(targets, name)
        end
    end
    if #targets == 0 then
        fireResultLabel.Text = "⚠ No broadcast targets selected"
        fireResultLabel.TextColor3 = C.FAIL
        return
    end
    local issues = CSCP_Validate()
    if #issues > 0 then
        fireResultLabel.Text = "⚠ Validate first: " .. issues[1]
        fireResultLabel.TextColor3 = C.FAIL
        return
    end
    local args    = CSCP_BuildArgs()
    local results = {}
    for _, name in ipairs(targets) do
        local ok, res = CSCP_Fire(name, args)
        results[name] = (ok and "OK" or res)
    end
    local summary = #targets .. " fired"
    for n, r in pairs(results) do
        summary = summary .. "  [" .. n:sub(1,12) .. ":" .. r:sub(1,6) .. "]"
    end
    fireResultLabel.Text = "📡 " .. summary
    fireResultLabel.TextColor3 = C.ACTIVE
    CSCP_AddHistory("BROADCAST[" .. #targets .. "]", CSCP.Fields, results)
    if _G.PC.CSCP_RebuildHistoryUI then
        pcall(_G.PC.CSCP_RebuildHistoryUI)
    end
end)

-- ── SECTION: Broadcast Target Selector ───────────────────────
local _, sBcast = makeSection(prPageCSCP, "📡  Broadcast Targets")

cscpLabel(sBcast,
    "Select multiple remotes to fire the same packet to all simultaneously.",
    11, false, C.SUB)

local bcastScroll = mk("ScrollingFrame", {
    BackgroundColor3    = Color3.fromRGB(250,245,238),
    BorderSizePixel     = 0,
    Size                = UDim2.new(1, -16, 0, 120),
    CanvasSize          = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness  = 5,
    ScrollingDirection  = Enum.ScrollingDirection.Y,
    Parent              = sBcast,
})
addCorner(bcastScroll, UDim.new(0, 8))
addStroke(bcastScroll, 1, 0.4)
mk("UIListLayout", {
    Padding   = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent    = bcastScroll,
})
mk("UIPadding", {
    PaddingLeft=UDim.new(0,6), PaddingTop=UDim.new(0,4), Parent=bcastScroll,
})

local bcastEmpty = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Gotham,
    Text="  Refresh to populate targets.",
    TextColor3=C.SUB, TextSize=11,
    Size=UDim2.new(1,0,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,
    Parent=bcastScroll,
})

local function CSCP_RebuildBroadcastList()
    for _, ch in ipairs(bcastScroll:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    if not PR_Registry then return end
    local count = 0
    for name in pairs(PR_Registry) do
        count = count + 1
        local isSel = CSCP.BroadcastList[name] == true
        local rowF = mk("Frame", {
            BackgroundColor3 = isSel and C.BCAST or Color3.fromRGB(246,242,235),
            BorderSizePixel=0,
            Size=UDim2.new(1,-8,0,24), LayoutOrder=count, Parent=bcastScroll,
        })
        addCorner(rowF, UDim.new(0,4)); addStroke(rowF, 1, 0.25)
        mk("UIListLayout",{
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=rowF,
        })
        mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=rowF})

        -- Checkbox dot
        local dot = mk("Frame",{
            BackgroundColor3= isSel and C.ACTIVE or Color3.fromRGB(200,195,188),
            BorderSizePixel=0, Size=UDim2.new(0,10,0,10), Parent=rowF,
        })
        addCorner(dot, UDim.new(1,0))

        mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
            Text=name:sub(1,44), TextColor3=C.TEXT, TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=rowF,
        })

        -- Make the whole row a button
        local hitBtn = mk("TextButton",{
            BackgroundTransparency=1, BorderSizePixel=0,
            Text="", Size=UDim2.new(1,0,1,0),
            Position=UDim2.new(0,0,0,0),
            ZIndex=rowF.ZIndex+1, Parent=rowF,
        })
        local n = name
        hitBtn.MouseButton1Click:Connect(function()
            clickSound()
            CSCP.BroadcastList[n] = not CSCP.BroadcastList[n]
            local sel = CSCP.BroadcastList[n]
            tween(rowF, TweenInfo.new(0.1), {
                BackgroundColor3 = sel and C.BCAST or Color3.fromRGB(246,242,235)
            })
            tween(dot, TweenInfo.new(0.1), {
                BackgroundColor3 = sel and C.ACTIVE or Color3.fromRGB(200,195,188)
            })
        end)
    end
    bcastEmpty.Visible = (count == 0)
end

local bcastRow = row(sBcast)
local btnBcastRefresh = cscpBtn(bcastRow, "↻ Refresh", nil, 1)
local btnBcastClear   = cscpBtn(bcastRow, "✕ Clear Selection", nil, 2)
local bcastCountLbl   = cscpLabel(bcastRow, "0 selected", 11, false, C.SUB)

btnBcastRefresh.MouseButton1Click:Connect(function()
    CSCP_RebuildBroadcastList()
    local sel = 0
    for _ in pairs(CSCP.BroadcastList) do sel = sel + 1 end
    bcastCountLbl.Text = sel .. " selected"
end)

btnBcastClear.MouseButton1Click:Connect(function()
    CSCP.BroadcastList = {}
    CSCP_RebuildBroadcastList()
    bcastCountLbl.Text = "0 selected"
end)

-- ── SECTION: Packet History ───────────────────────────────────
local _, sHist = makeSection(prPageCSCP, "📜  Packet History")

cscpLabel(sHist,
    "Last 50 crafted packets. One-click recall loads fields back into the builder.",
    11, false, C.SUB)

local histScroll = mk("ScrollingFrame", {
    BackgroundColor3    = C.HIST,
    BorderSizePixel     = 0,
    Size                = UDim2.new(1, -16, 0, 200),
    CanvasSize          = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness  = 5,
    ScrollingDirection  = Enum.ScrollingDirection.Y,
    Parent              = sHist,
})
addCorner(histScroll, UDim.new(0, 8))
mk("UIListLayout", {
    Padding   = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent    = histScroll,
})
mk("UIPadding", {
    PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,6),
    PaddingBottom=UDim.new(0,6), PaddingRight=UDim.new(0,6),
    Parent=histScroll,
})

local histRows = {}
local histOrder = 0

local function CSCP_RebuildHistoryUI()
    for _, r in ipairs(histRows) do if r and r.Parent then r:Destroy() end end
    histRows = {}; histOrder = 0

    for i, entry in ipairs(CSCP.History) do
        histOrder = histOrder + 1
        local hRow = mk("Frame", {
            BackgroundColor3 = Color3.fromRGB(50,46,40),
            BorderSizePixel  = 0,
            Size             = UDim2.new(1, 0, 0, 0),
            AutomaticSize    = Enum.AutomaticSize.Y,
            LayoutOrder      = histOrder,
            Parent           = histScroll,
        })
        addCorner(hRow, UDim.new(0, 5))
        addStroke(hRow, 1, 0.2)
        mk("UIListLayout", {
            Padding   = UDim.new(0, 2),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent    = hRow,
        })
        mk("UIPadding", {
            PaddingLeft=UDim.new(0,8), PaddingTop=UDim.new(0,5),
            PaddingBottom=UDim.new(0,5), PaddingRight=UDim.new(0,6),
            Parent=hRow,
        })

        -- Header: time + remote name
        local topRow_h = mk("Frame", {
            BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,18), LayoutOrder=1, Parent=hRow,
        })
        mk("UIListLayout",{
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,8), Parent=topRow_h,
        })
        mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
            Text=string.format("[%.1f]", entry.time),
            TextColor3=Color3.fromRGB(100,100,120), TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=topRow_h,
        })
        mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=entry.remote:sub(1,36),
            TextColor3=Color3.fromRGB(255,210,140), TextSize=10,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=topRow_h,
        })

        -- Field summary
        local fieldSummary = {}
        for _, f in ipairs(entry.fields or {}) do
            fieldSummary[#fieldSummary+1] = f.label .. "=" .. tostring(f.value):sub(1,12)
        end
        mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
            Text=table.concat(fieldSummary, "  "):sub(1,80),
            TextColor3=Color3.fromRGB(160,200,160), TextSize=9,
            Size=UDim2.new(1,0,0,14), LayoutOrder=2,
            TextXAlignment=Enum.TextXAlignment.Left,
            TextWrapped=true, Parent=hRow,
        })

        -- Result row + recall button
        local botRow_h = mk("Frame",{
            BackgroundTransparency=1,
            Size=UDim2.new(1,0,0,22), LayoutOrder=3, Parent=hRow,
        })
        mk("UIListLayout",{
            FillDirection=Enum.FillDirection.Horizontal,
            VerticalAlignment=Enum.VerticalAlignment.Center,
            Padding=UDim.new(0,6), Parent=botRow_h,
        })

        -- Results summary
        local resSummary = {}
        for n, r in pairs(entry.results or {}) do
            resSummary[#resSummary+1] = n:sub(1,10) .. ":" .. r:sub(1,8)
        end
        mk("TextLabel",{
            BackgroundTransparency=1, Font=Enum.Font.RobotoMono,
            Text=table.concat(resSummary, "  "):sub(1,50),
            TextColor3=Color3.fromRGB(140,180,140), TextSize=9,
            AutomaticSize=Enum.AutomaticSize.X, Size=UDim2.new(0,0,1,0),
            TextXAlignment=Enum.TextXAlignment.Left, Parent=botRow_h,
        })

        -- Recall button
        local idx = i
        local recallBtn = mk("TextButton",{
            AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(60,80,100),
            BorderSizePixel=0, Font=Enum.Font.GothamSemibold,
            Text="↩ Recall", TextColor3=Color3.fromRGB(200,220,255), TextSize=9,
            Size=UDim2.new(0,70,0,20), Parent=botRow_h,
        })
        addCorner(recallBtn, UDim.new(0,5))
        recallBtn.MouseButton1Click:Connect(function()
            clickSound()
            local h = CSCP.History[idx]
            if not h then return end
            -- Recall: load remote and fields
            if PR_Registry and PR_Registry[h.remote] then
                CSCP.SelectedRemote = h.remote
                activeRemoteLabel.Text = "Selected: " .. h.remote
            end
            CSCP.Fields = {}
            for _, f in ipairs(h.fields or {}) do
                table.insert(CSCP.Fields, {
                    pos=f.pos, argType=f.argType, value=f.value,
                    label=f.label, tokenHint=f.tokenHint, optional=f.optional,
                })
            end
            CSCP_RebuildFieldUI()
            sendNotification("CSCP: Packet recalled from history", "Info")
        end)

        table.insert(histRows, hRow)
    end
end

_G.PC.CSCP_RebuildHistoryUI = CSCP_RebuildHistoryUI

local histTopRow = row(sHist)
local btnHistClear = cscpBtn(histTopRow, "🗑 Clear History", nil, 1)
local histCountLbl = cscpLabel(histTopRow, "0 packets", 11, false, C.SUB)

btnHistClear.MouseButton1Click:Connect(function()
    CSCP.History = {}
    CSCP_RebuildHistoryUI()
    histCountLbl.Text = "0 packets"
    CSCP_Save()
end)

-- Rebuild history on load
CSCP_RebuildHistoryUI()
histCountLbl.Text = #CSCP.History .. " packet(s)"

-- ============================================================
-- PUBLIC: CSCP_LoadRemote
-- Called by pr_ui.lua "Craft →" button and remote chip clicks
-- ============================================================
_G.PC.CSCP_LoadRemote = function(remoteName)
    if not remoteName or not PR_Registry then return end
    CSCP.SelectedRemote = remoteName
    activeRemoteLabel.Text = "Selected: " .. remoteName
    CSCP_Save()

    -- Update chip highlights
    for name, chip in pairs(remoteChipRefs) do
        local isSel = (name == remoteName)
        tween(chip, TweenInfo.new(0.12), {
            BackgroundColor3 = isSel and C.ACTIVE or Color3.fromRGB(235,228,218),
            TextColor3       = isSel and Color3.fromRGB(255,252,245) or C.TEXT,
        })
    end

    -- Infer fields from schema + captures
    if CSCP.AutoMode then
        CSCP.Fields = CSCP_InferFields(remoteName)
        CSCP_RebuildFieldUI()
    end

    local captures = CSCP.InferCaptures[remoteName] or {}
    local capCount = #captures
    sendNotification(
        "CSCP: Loaded " .. remoteName ..
        " (" .. #CSCP.Fields .. " fields, " ..
        capCount .. " capture(s))", "Info")
end

-- Export CSCP state for other modules
_G.PC.CSCP = CSCP

print("[PaperCuts] cscp.lua: Packet Crafter ready")
