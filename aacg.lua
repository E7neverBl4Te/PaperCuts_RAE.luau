-- ══════════════════════════════════════════════════════════════════════════════
-- AACG — Autonomous Action Card Generator
-- Module Layer: ASE subsystem
-- ══════════════════════════════════════════════════════════════════════════════
-- Analyzes the live RSM / SBI / CDG / PR_Registry to infer what server-side
-- actions the game supports, then synthesizes ready-to-fire Action Cards
-- organized by Tier and Category.
--
-- Tiers:
--   LOCALIZED  — server fires effect to local client only (invisible to others)
--   SERVER     — server broadcasts effect visible to all players
--   OWNER      — unrestricted (requires Mastery unlock)
--
-- Categories per tier:
--   LOCALIZED:  Tools & Items | Client Editing | WorldState Control
--   SERVER:     Admin Tools   | Player Editing | WorldState Control
--   OWNER:      Everything    (no category filter)
--
-- Card lifecycle:
--   Generate → Display → Fire (one-shot) → optional Favorite → auto-Directive
-- ══════════════════════════════════════════════════════════════════════════════

local AACG = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
AACG.TIER = {
    LOCALIZED = "LOCALIZED",
    SERVER    = "SERVER",
    OWNER     = "OWNER",
}

AACG.CATEGORY = {
    -- Localized tier
    TOOLS      = "Tools & Items",
    CLIENT_EDIT= "Client Editing",
    WORLD_CTRL = "WorldState Control",
    -- Server tier
    ADMIN      = "Admin Tools",
    PLAYER_EDIT= "Player Editing",
    WORLD_SV   = "WorldState Control",
    -- Owner tier
    EVERYTHING = "Everything",
}

AACG.TIER_CATEGORIES = {
    [AACG.TIER.LOCALIZED] = {
        AACG.CATEGORY.TOOLS,
        AACG.CATEGORY.CLIENT_EDIT,
        AACG.CATEGORY.WORLD_CTRL,
    },
    [AACG.TIER.SERVER] = {
        AACG.CATEGORY.ADMIN,
        AACG.CATEGORY.PLAYER_EDIT,
        AACG.CATEGORY.WORLD_SV,
    },
    [AACG.TIER.OWNER] = {
        AACG.CATEGORY.EVERYTHING,
    },
}

-- ── Persist key ───────────────────────────────────────────────────────────────
local PERSIST_KEY  = "__AACG_Favorites_v1"
local AACG_Favorites = {}   -- { [cardId] = CardRecord }
local AACG_Cards     = {}   -- cache of last generated set, keyed by id

-- ── Classifier keyword tables ─────────────────────────────────────────────────
-- Each entry: { patterns={...}, tier=T, category=C, weight=N }
-- Patterns are matched against the lowercase remote name.
-- Highest cumulative weight wins.
local CLASSIFIERS = {
    -- ── LOCALIZED: Tools & Items ───────────────────────────────────────────
    { patterns={"giveitem","grantitem","additem","equipitem","spawnitem",
                "givetool","granttool","addtool","equiptool","spawntool",
                "givegear","grantgear","addgear"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.TOOLS, weight=10 },
    { patterns={"give","grant","award","equip","spawn","tool","item",
                "weapon","gun","sword","gear","accessory","hat","shirt","pants"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.TOOLS, weight=4 },

    -- ── LOCALIZED: Client Editing ──────────────────────────────────────────
    { patterns={"localui","clientui","localeffect","clienteffect",
                "localnotif","clientnotif","localdisplay","clientdisplay",
                "screengui","playerui","hudupdate","headsup"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.CLIENT_EDIT, weight=10 },
    { patterns={"notification","notify","alert","message","dialog",
                "popup","hud","overlay","display","local","client"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.CLIENT_EDIT, weight=3 },

    -- ── LOCALIZED: WorldState Control ─────────────────────────────────────
    { patterns={"setstat","addstat","updatestat","modifystat",
                "setcurrency","addcurrency","givecurrency","grantcurrency",
                "setpoints","addpoints","givepoints",
                "setgold","addgold","givegold",
                "setcash","addcash","givecash",
                "setcoins","addcoins","givecoins",
                "setlevel","addlevel","setxp","addxp","setrank","addrank"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.WORLD_CTRL, weight=10 },
    { patterns={"stat","currency","economy","points","gold","cash",
                "coins","level","xp","rank","score","balance"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.WORLD_CTRL, weight=4 },

    -- ── SERVER: Admin Tools ────────────────────────────────────────────────
    { patterns={"kick","ban","mute","unmute","unban","warn","teleportplayer",
                "tpplayer","admincommand","servercommand","modcommand"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.ADMIN, weight=10 },
    { patterns={"admin","mod","moderator","command","manage","control",
                "enforce","punishment","report"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.ADMIN, weight=4 },

    -- ── SERVER: Player Editing ─────────────────────────────────────────────
    { patterns={"teleport","warp","moveplayer","setposition","setpos",
                "respawn","revive","setcharacter","editplayer","setplayerdata",
                "updateplayer","playerupdate","sethealth","addhealth",
                "sethp","addhp","setspeed","setjump","setwalkspeed"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.PLAYER_EDIT, weight=10 },
    { patterns={"player","character","health","speed","jump","move",
                "position","respawn","revive","heal","damage"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.PLAYER_EDIT, weight=3 },

    -- ── SERVER: WorldState Control ─────────────────────────────────────────
    { patterns={"setmap","loadmap","changemap","changelevel","loadlevel",
                "startround","endround","setround","newround",
                "setgame","startgame","endgame","restartgame",
                "setweather","settime","setlighting","setambient",
                "worldevent","triggerevent","fireworldevent",
                "seteconomy","updateeconomy","economyupdate",
                "setshop","updateshop","shopupdate",
                "broadcast","serverbroadcast","globalbroadcast"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.WORLD_SV, weight=10 },
    { patterns={"world","map","round","game","event","weather","time",
                "lighting","economy","shop","broadcast","global","server"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.WORLD_SV, weight=3 },
}

-- ── Name humanizer ─────────────────────────────────────────────────────────────
-- Converts CamelCase / snake_case remote names into readable card titles.
local function humanizeName(name)
    -- Insert spaces before uppercase letters (CamelCase split)
    local s = name:gsub("(%l)(%u)", "%1 %2")
    -- Replace underscores/hyphens with spaces
    s = s:gsub("[_%-]+", " ")
    -- Capitalize each word
    s = s:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return s:match("^%s*(.-)%s*$")
end

-- ── Description generator ──────────────────────────────────────────────────────
local function inferDescription(name, category, argSig)
    local low = name:lower()
    local argHint = ""
    if argSig and #argSig > 0 then
        local parts = {}
        for i, sig in ipairs(argSig) do
            if sig.DominantType == "number" and #(sig.SuccessValues or {}) > 0 then
                table.insert(parts, string.format("amount=%s", tostring(sig.SuccessValues[1])))
            elseif sig.DominantType == "string" and #(sig.SuccessStrings or {}) > 0 then
                table.insert(parts, string.format('value="%s"', sig.SuccessStrings[1]))
            elseif sig.DominantType == "boolean" then
                table.insert(parts, "flag=true")
            end
            if #parts >= 2 then break end
        end
        if #parts > 0 then
            argHint = "  (" .. table.concat(parts, ", ") .. ")"
        end
    end

    if category == AACG.CATEGORY.TOOLS or category == AACG.CATEGORY.TOOLS then
        if low:find("give") or low:find("grant") or low:find("award") then
            return "Grants an item or tool to the local player" .. argHint
        elseif low:find("equip") then
            return "Equips a weapon or tool on the player" .. argHint
        elseif low:find("spawn") then
            return "Spawns an item or object in the world" .. argHint
        end
        return "Provides a weapon, tool, or item" .. argHint

    elseif category == AACG.CATEGORY.CLIENT_EDIT then
        if low:find("notif") or low:find("alert") or low:find("message") then
            return "Sends a notification or message to the local client" .. argHint
        elseif low:find("hud") or low:find("ui") or low:find("display") then
            return "Updates a UI element or HUD component" .. argHint
        end
        return "Applies a local client-side change or effect" .. argHint

    elseif category == AACG.CATEGORY.WORLD_CTRL then
        if low:find("currenc") or low:find("gold") or low:find("cash") or low:find("coin") then
            return "Modifies the player's in-game currency balance" .. argHint
        elseif low:find("xp") or low:find("level") or low:find("rank") then
            return "Adjusts player progression — level, XP, or rank" .. argHint
        elseif low:find("stat") then
            return "Directly sets or increments a player stat value" .. argHint
        end
        return "Modifies a tracked player or world stat" .. argHint

    elseif category == AACG.CATEGORY.ADMIN then
        if low:find("kick") then return "Removes a player from the server" .. argHint
        elseif low:find("ban") then return "Bans a player from the game" .. argHint
        elseif low:find("mute") then return "Silences a player's chat output" .. argHint
        elseif low:find("teleport") or low:find("tp") then
            return "Teleports a specific player to a location" .. argHint
        end
        return "Executes a server-side moderation or admin command" .. argHint

    elseif category == AACG.CATEGORY.PLAYER_EDIT then
        if low:find("teleport") or low:find("warp") then
            return "Moves the player to a new position in the world" .. argHint
        elseif low:find("health") or low:find("hp") or low:find("heal") then
            return "Sets or modifies the player's health/HP value" .. argHint
        elseif low:find("speed") or low:find("walkspeed") then
            return "Changes the player's walk speed attribute" .. argHint
        elseif low:find("respawn") or low:find("revive") then
            return "Forces the player to respawn or revives them in place" .. argHint
        end
        return "Applies a server-replicated change to the player character" .. argHint

    elseif category == AACG.CATEGORY.WORLD_SV then
        if low:find("round") then
            return "Controls the game round state — start, end, or reset" .. argHint
        elseif low:find("map") or low:find("level") then
            return "Changes or loads a new game map or level" .. argHint
        elseif low:find("broadcast") then
            return "Sends a server-wide message or event broadcast" .. argHint
        elseif low:find("weather") or low:find("time") or low:find("light") then
            return "Alters the world environment — time, weather, or lighting" .. argHint
        elseif low:find("econom") or low:find("shop") then
            return "Modifies the game's economy state or shop inventory" .. argHint
        end
        return "Triggers a server-side world state change visible to all players" .. argHint

    elseif category == AACG.CATEGORY.EVERYTHING then
        return "Full-access card — executes unrestricted server-side action" .. argHint
    end

    return "Executes a server-side action via the Bedrock pipeline" .. argHint
end

-- ── Remote classifier ─────────────────────────────────────────────────────────
-- Returns { tier, category, score } for a remote name.
-- Returns nil if score below threshold.
local function classifyRemote(name, rec)
    local low = name:lower()
    local scores = {}  -- { [tier.."|"..cat] = weight }

    for _, clf in ipairs(CLASSIFIERS) do
        for _, pat in ipairs(clf.patterns) do
            if low:find(pat, 1, true) then
                local key = clf.tier .. "|" .. clf.category
                scores[key] = (scores[key] or 0) + clf.weight
            end
        end
    end

    -- Find winner
    local bestKey, bestScore = nil, 0
    for k, v in pairs(scores) do
        if v > bestScore then bestKey, bestScore = k, v end
    end

    if not bestKey or bestScore < 3 then return nil end

    local tier, cat = bestKey:match("^(.+)|(.+)$")
    return { tier=tier, category=cat, score=bestScore }
end

-- ── Args builder ──────────────────────────────────────────────────────────────
-- Builds a best-guess args table from RSM ArgSig SuccessValues.
local function buildArgs(rsmRec)
    if not rsmRec or not rsmRec.ArgSig then return {} end
    local args = {}
    for i, sig in ipairs(rsmRec.ArgSig) do
        if sig.DominantType == "number" and #(sig.SuccessValues or {}) > 0 then
            args[i] = sig.SuccessValues[1]
        elseif sig.DominantType == "string" and #(sig.SuccessStrings or {}) > 0 then
            args[i] = sig.SuccessStrings[1]
        elseif sig.DominantType == "boolean" then
            args[i] = true
        elseif sig.DominantType == "table" then
            args[i] = {}
        end
    end
    return args
end

-- ── Card ID generator ─────────────────────────────────────────────────────────
local function cardId(remote, category)
    return string.format("aacg_%s_%s_%d",
        remote:gsub("[^%w]",""):sub(1,12),
        category:gsub("[^%w]",""):sub(1,8),
        math.random(1000,9999))
end

-- ── GENERATE ──────────────────────────────────────────────────────────────────
-- Analyzes live RSM/SBI/CDG/PR data and returns a list of Action Cards
-- for the given tier + category combination.
-- masteryUnlocked=true → generates OWNER tier cards (no filter).
function AACG.Generate(tier, category, masteryUnlocked)
    local RSM  = _G.PC and _G.PC.RSM
    local SBI  = _G.PC and _G.PC.SBI
    local PR   = _G.PC and _G.PC.PR_Registry
    local CDG  = _G.PC and _G.PC.CDG

    if not RSM or not PR then
        return {}, "RSM or PR_Registry not available."
    end

    local cards = {}
    local seen  = {}

    -- Collect all known remotes from RSM + PR
    local remoteNames = {}
    local rsmAll = RSM.GetAll and RSM.GetAll() or {}
    for name, _ in pairs(rsmAll) do
        if not seen[name] then seen[name]=true; table.insert(remoteNames, name) end
    end
    for name, _ in pairs(PR) do
        if not seen[name] then seen[name]=true; table.insert(remoteNames, name) end
    end

    for _, name in ipairs(remoteNames) do
        local rsmRec = RSM.Get and RSM.Get(name)
        local sbiRec = SBI and SBI.Get and SBI.Get(name)
        local prRec  = PR[name]

        -- Skip S2C-only remotes (server → client, not fireable by us)
        if prRec and prRec.Direction == "S2C" then
            -- only include for LOCALIZED tier (server pushes to our client)
            if tier ~= AACG.TIER.LOCALIZED and tier ~= AACG.TIER.OWNER then
                goto continue_remote
            end
        end

        -- Skip if no RSM record (we have no arg data — can't build payload)
        if not rsmRec and tier ~= AACG.TIER.OWNER then
            goto continue_remote
        end

        -- OWNER tier: include everything
        if tier == AACG.TIER.OWNER and masteryUnlocked then
            local conf = (sbiRec and sbiRec.Confidence) or 0.5
            local args = buildArgs(rsmRec)
            local id   = cardId(name, AACG.CATEGORY.EVERYTHING)
            local card = {
                id          = id,
                name        = humanizeName(name),
                remote      = name,
                description = inferDescription(name, AACG.CATEGORY.EVERYTHING,
                                rsmRec and rsmRec.ArgSig),
                category    = AACG.CATEGORY.EVERYTHING,
                tier        = AACG.TIER.OWNER,
                args        = args,
                confidence  = conf,
                favorited   = AACG_Favorites[name] ~= nil,
                generatedAt = os.clock(),
                argCount    = rsmRec and #(rsmRec.ArgSig or {}) or 0,
            }
            table.insert(cards, card)
            AACG_Cards[id] = card
            goto continue_remote
        end

        -- Classify the remote
        do
            local cls = classifyRemote(name, prRec)
            if not cls then goto continue_remote end
            if cls.tier ~= tier then goto continue_remote end
            if cls.category ~= category then goto continue_remote end

            local conf = (sbiRec and sbiRec.Confidence) or
                         (cls.score / 20.0)
            conf = math.clamp(conf, 0.1, 1.0)

            -- Suppress very low confidence unless Owner
            if conf < 0.25 and tier ~= AACG.TIER.OWNER then
                goto continue_remote
            end

            local args = buildArgs(rsmRec)
            local id   = cardId(name, category)
            local card = {
                id          = id,
                name        = humanizeName(name),
                remote      = name,
                description = inferDescription(name, category,
                                rsmRec and rsmRec.ArgSig),
                category    = category,
                tier        = tier,
                args        = args,
                confidence  = conf,
                favorited   = AACG_Favorites[name] ~= nil,
                generatedAt = os.clock(),
                argCount    = rsmRec and #(rsmRec.ArgSig or {}) or 0,
                classScore  = cls.score,
            }
            table.insert(cards, card)
            AACG_Cards[id] = card
        end

        ::continue_remote::
    end

    -- Sort: favorites first, then by confidence desc, then by classScore desc
    table.sort(cards, function(a, b)
        if a.favorited ~= b.favorited then return a.favorited end
        if math.abs(a.confidence - b.confidence) > 0.05 then
            return a.confidence > b.confidence
        end
        return (a.classScore or 0) > (b.classScore or 0)
    end)

    return cards, nil
end

-- ── EXECUTE ───────────────────────────────────────────────────────────────────
-- Fires a card one-shot through the SARP pipeline.
-- onResult(ok, err) called on completion.
function AACG.Execute(card, onResult)
    local SARP = _G.PC and _G.PC.SARP
    local PR   = _G.PC and _G.PC.PR_Registry
    local ASE  = _G.PC and _G.PC.ASE

    if not card then
        if onResult then onResult(false, "No card provided") end
        return
    end

    if not SARP or not PR then
        if onResult then onResult(false, "SARP or PR not available") end
        return
    end

    if not PR[card.remote] then
        if onResult then onResult(false, "Remote not in PR: " .. tostring(card.remote)) end
        return
    end

    -- Prefer routing through ASE Bedrock pipeline if active
    local bedrockActive = ASE and ASE.Panel and ASE.Panel.HeartbeatAlive
    if bedrockActive and ASE.Panel.ActiveSink == card.remote then
        -- The card IS the active sink — fire directly through Execute
        local ok, result = ASE.Execute(card.name, card.args)
        if onResult then onResult(ok, tostring(result)) end
        return
    end

    -- Standard SARP fire
    local wrapped, sim, err = SARP.Build("Attribute", card.args, nil, nil, card.remote)
    if not wrapped then
        if onResult then onResult(false, "SARP.Build: " .. tostring(err)) end
        return
    end

    SARP.Execute(wrapped, sim, card.remote, function(ok, result, ferr)
        local msg = ok and ("OK — " .. tostring(result)) or tostring(ferr)
        print(string.format("[AACG] Card fired: %s → %s  result=%s",
            card.name, card.remote, msg))
        if onResult then onResult(ok, msg) end
    end)
end

-- ── FAVORITE / UNFAVORITE ─────────────────────────────────────────────────────
function AACG.Favorite(card)
    if not card then return end
    card.favorited = true
    AACG_Favorites[card.remote] = {
        remote      = card.remote,
        name        = card.name,
        description = card.description,
        category    = card.category,
        tier        = card.tier,
        args        = card.args,
        confidence  = card.confidence,
        savedAt     = os.clock(),
    }
    AACG.Save()

    -- Auto-promote to Directive
    local ASE = _G.PC and _G.PC.ASE
    local sink = ASE and ASE.Panel and ASE.Panel.ActiveSink
    if ASE and sink then
        local ok = pcall(function()
            ASE.FinalizeDirective(
                "AACG_" .. card.name:gsub("%s+","_"),
                card.args,
                card.remote,
                "AACG:" .. card.category,
                nil, nil)
        end)
        if ok then
            print(string.format("[AACG] ⭐ Favorited + promoted to Directive: %s", card.name))
        end
    end
end

function AACG.Unfavorite(card)
    if not card then return end
    card.favorited = false
    AACG_Favorites[card.remote] = nil
    AACG.Save()
end

function AACG.GetFavorites()
    local out = {}
    for _, fav in pairs(AACG_Favorites) do
        table.insert(out, fav)
    end
    table.sort(out, function(a,b) return (a.savedAt or 0) > (b.savedAt or 0) end)
    return out
end

function AACG.IsFavorited(remote)
    return AACG_Favorites[remote] ~= nil
end

-- ── PERSISTENCE ───────────────────────────────────────────────────────────────
function AACG.Save()
    pcall(function()
        local safe = {}
        for k, v in pairs(AACG_Favorites) do
            safe[k] = {
                remote      = v.remote,
                name        = v.name,
                description = v.description,
                category    = v.category,
                tier        = v.tier,
                args        = v.args,
                confidence  = v.confidence,
                savedAt     = v.savedAt,
            }
        end
        _G[PERSIST_KEY] = safe
    end)
end

function AACG.Load()
    pcall(function()
        local d = _G[PERSIST_KEY]
        if type(d) ~= "table" then return end
        for k, v in pairs(d) do
            if type(v) == "table" and v.remote then
                AACG_Favorites[k] = v
            end
        end
        local count = 0
        for _ in pairs(AACG_Favorites) do count = count + 1 end
        if count > 0 then
            print(string.format("[AACG] Loaded %d favorite card(s).", count))
        end
    end)
end

-- ── STATS ─────────────────────────────────────────────────────────────────────
function AACG.GetStats()
    local favCount = 0
    for _ in pairs(AACG_Favorites) do favCount = favCount + 1 end
    return {
        FavoriteCount = favCount,
        CardCacheSize = (function() local n=0; for _ in pairs(AACG_Cards) do n=n+1 end; return n end)(),
    }
end

-- ── STARTUP ───────────────────────────────────────────────────────────────────
AACG.Load()

-- ── Export ────────────────────────────────────────────────────────────────────
_G.PC = _G.PC or {}
_G.PC.AACG = AACG
print("[AACG] Autonomous Action Card Generator ready.")
