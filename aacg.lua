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
    -- Localized Server-Side tier
    S2C_EXEC   = "Server-Side Executions",   -- replicated fx sent to local client
    LOC_TOOLS  = "Admin / Player Tools",      -- god-mode gear, admin panels, vehicles
    LOC_CLIENT = "Local Client Editing",      -- model swaps, GUI overlays, FOV, anims
    LOC_WORLD  = "WorldState Control",        -- props, weather, NPC summons, gravity
    -- Server-Side (All Players) tier
    SV_TOOLS   = "Server Admin / Player Tools", -- permanent admin, ban/kick, force-equip
    SV_PLAYER  = "Player Editing",              -- leaderstats, XP, skins, team swaps
    SV_WORLD   = "WorldState Controlling",      -- economy, shop, terrain, game modes
    -- Owner tier
    EVERYTHING = "Everything",
}

AACG.TIER_CATEGORIES = {
    [AACG.TIER.LOCALIZED] = {
        AACG.CATEGORY.S2C_EXEC,
        AACG.CATEGORY.LOC_TOOLS,
        AACG.CATEGORY.LOC_CLIENT,
        AACG.CATEGORY.LOC_WORLD,
    },
    [AACG.TIER.SERVER] = {
        AACG.CATEGORY.SV_TOOLS,
        AACG.CATEGORY.SV_PLAYER,
        AACG.CATEGORY.SV_WORLD,
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
-- Patterns matched against lowercase remote name. Highest cumulative weight wins.
local CLASSIFIERS = {

    -- ══════════════════════════════════════════════════════════════════════════
    -- LOCALIZED SERVER-SIDE TIER
    -- ══════════════════════════════════════════════════════════════════════════

    -- Category: Server-Side Executions
    -- Replicated character animations, global sound broadcasts, particle triggers,
    -- status effect icons, synced lighting, broadcast chat, tool equip anims, hitmarkers
    { patterns={"replicateanim","replicateanimation","charanimation","characteranim",
                "syncanim","syncanimation","equipeanimation","toolequipanim"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"soundbroadcast","globalSound","playsound","soundreplicate",
                "replicatesound","triggersound","broadcastsound"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"particletrigger","triggerparticle","spawnparticle","particleeffect",
                "fireparticle","replicateparticle","emitterfire"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"statuseffect","statusicon","applyeffect","effectapply",
                "buffeffect","debuffeffect","statusreplicate"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"synclighting","lightingchange","ambientchange","replicatelighting",
                "setlighting","lightupdate","lightreplicate"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"broadcastchat","chatbroadcast","systemmessage","chatmessage",
                "sendchat","globalchat","serverchat","chatannounce"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"hitmarker","hitreplicate","replicatehit","hiteffect",
                "damageeffect","hitvisual","hitconfirm"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=12 },
    { patterns={"replicate","broadcast","sync","notify","clientevent",
                "clientfire","localfire","s2c","sendclient"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.S2C_EXEC, weight=4 },

    -- Category: Admin / Player Tools (Localized)
    -- God-mode swords, infinite-ammo guns, admin panels, teleport batons,
    -- vehicle spawners, force-fields, invisibility, speed boosts, explosives, healing
    { patterns={"godmode","godsword","infammo","infiniteammo","admingun",
                "godgun","cheatweapon","devweapon","adminweapon"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"adminpanel","admincommand","adminmenu","devpanel","devtool",
                "commandpanel","modpanel","staffpanel"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"teleportbaton","tpbaton","teleporttool","tptool","warpbaton",
                "vehiclespawner","spawnvehicle","spawncustom"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"forcefield","forceShield","shieldtool","invisibilitycloak",
                "inviztool","cloaktool","invisibletool"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"speedboost","speedgadget","boosttool","speedhack","speedtool",
                "explosive","throwable","bombitem","grenadeitem"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"healstaff","healingtool","healtool","healitem","staffheal",
                "healwand","medtool"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=12 },
    { patterns={"giveitem","grantitem","additem","equipitem","spawnitem",
                "givetool","granttool","addtool","equiptool","spawntool",
                "giveweapon","grantweapon","spawnweapon","addweapon",
                "givegear","grantgear","givesword","grantgun"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=10 },
    { patterns={"sword","gun","weapon","tool","item","gear","baton","wand",
                "shield","vehicle","explosive","grenade","staff","gadget"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_TOOLS, weight=3 },

    -- Category: Local Client Editing
    -- Character model swaps, GUI overlays, crosshairs, name tags, FOV,
    -- walk animations, headshot markers, health bar reskins
    { patterns={"modelswap","charswap","characterswap","swapcmodel",
                "skinswap","charmodel","setcharactermodel","replacemodel"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=12 },
    { patterns={"guioverlay","overlayinject","injectgui","customgui",
                "screenoverlaya","uiinject","insertgui","guiinsert"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=12 },
    { patterns={"crosshair","customcrosshair","crosshairswap","setcrosshair",
                "nametag","nametagmod","tagoverride","usernametag"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=12 },
    { patterns={"fovoverride","setfov","camerafov","fovchange","fovset",
                "walkanim","walkreplace","animreplace","locomotionanim"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=12 },
    { patterns={"headshotmarker","headmarker","hsmarker","custommarker",
                "healthbarreskin","hpreskin","healthbarskin","hbreskin"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=12 },
    { patterns={"localmodel","localchar","localui","localoverlay","clientmodel",
                "clientgui","clientanim","clientskin","clientfov"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=8 },
    { patterns={"model","gui","overlay","crosshair","fov","camera","skin",
                "anim","reskin","marker","nametag","hud","bar"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_CLIENT, weight=3 },

    -- Category: WorldState Control (Localized)
    -- Temp prop spawns, weather shifts, time-of-day, billboards, NPC summons,
    -- explosion visuals, gravity flip zones, color filter overlays
    { patterns={"spawnprop","tempprop","propspawn","spawndecor","spawnobject",
                "envprop","worldprop","sceneobject"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"weathershift","setweather","weatherchange","weatherupdate",
                "timeofday","settime","daycycle","timecycle","setday"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"billboard","floatingtext","textbillboard","worldtext",
                "billboardgui","floating","worldlabel","namebillboard"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"npcspawn","spawnnpc","summon","npcSummon","summonentity",
                "spawnentity","spawnbot","entityspawn"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"explosionvisual","localexplosion","explodevisual","boomeffect",
                "gravityflip","setgravity","gravityzONE","gravitychange"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"colorfilter","coloroverlay","screencolor","colorgrade",
                "colorcorrect","tintoverlay","colorshift"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=12 },
    { patterns={"weather","gravity","billboard","npc","prop","explosion",
                "visual","environment","color","filter","time","day"},
      tier=AACG.TIER.LOCALIZED, category=AACG.CATEGORY.LOC_WORLD, weight=3 },

    -- ══════════════════════════════════════════════════════════════════════════
    -- SERVER-SIDE (ALL PLAYERS) TIER
    -- ══════════════════════════════════════════════════════════════════════════

    -- Category: Server Admin / Player Tools
    -- Permanent admin menus, ban/kick, spawn-any-item, weapon stat modifiers,
    -- infinite inventory, force-equip, announcement horns, global teleport, ownership transfer
    { patterns={"permanentadmin","adminmenuserver","globaladmin","serveradmin",
                "admincommandserver","fullAdmin","ownerAdmin"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"ban","kick","kickplayer","banplayer","permaban","tempban",
                "globalban","serverban","forceban","kickall"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"spawnanyitem","spawnall","universalspawn","forceSpawnItem",
                "weaponstatmod","statmodifier","weaponmodifier","weaponstats"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"infinventory","infiniteinv","unlimitedinventory","invbag",
                "forceequip","forcetool","servertool","globalequip"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"announce","announcement","globalannounce","serverannounce",
                "broadcastannounce","horn","serverhorn","alertall"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"globalteleport","tpall","teleportall","massTeleport",
                "ownership","transferowner","ownerTransfer","ownerorb"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=12 },
    { patterns={"admin","ban","kick","mute","announce","ownership","serverop",
                "globalequip","forceequip","spawnany"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_TOOLS, weight=4 },

    -- Category: Player Editing (Server)
    -- Leaderstat money, kill/death resets, level/XP overrides, inventory unlocks,
    -- skin changes, username tag overrides, team swaps, stat multipliers
    { patterns={"leaderstat","addmoney","setmoney","givemoney","grantmoney",
                "addcash","setcash","addcoins","setcoins","addcurrency","setcurrency"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"resetkills","resetdeaths","resetkd","kdReset","killreset",
                "deathreset","statReset","resetstat"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"setlevel","addlevel","leveloverride","setxp","addxp",
                "xpoverride","levelup","grantxp","grantlevel"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"inventoryunlock","unlockinventory","invunlock","unlockslot",
                "inventoryslot","addslot","grantslot"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"skinchange","permanentskin","charskin","playerskin",
                "usernameoverride","tagoverride","nametag","nameoverride"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"teamswap","changeteam","setteam","teamchange","teamassign",
                "statmultiplier","multiplier","multistats","booststat"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=12 },
    { patterns={"leaderstat","xp","level","kill","death","inventory","skin",
                "team","multiplier","stat","money","coins","cash","currency"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_PLAYER, weight=3 },

    -- Category: WorldState Controlling (Server)
    -- Shop prices, currency drop rates, economy resets, terrain sculpting,
    -- game mode switches, round timers, spawn points, leaderboard locks,
    -- resource nodes, door/state persistence
    { patterns={"shopprice","setprice","pricemultiplier","shopupdate","updateshop",
                "storeprice","itemcost","pricechange"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"currencydrop","dropratechange","droprate","currencyrate",
                "economyreset","reseteconomy","globaleconomy","economyupdate"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"terrainsculpt","mapedit","terrainEdit","worldterrain",
                "gamemodeswitch","setgamemode","chanegamemode","modeswitch"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"roundtimer","setTimer","timeroverride","roundtime","timeoverride",
                "spawnpoint","setspawn","spawnlocation","relocatespawn"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"leaderboardlock","lockleaderboard","lbLock","statlock",
                "resourcenode","nodemodify","resourcemodify","nodestate"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"doorstate","persiststate","statelock","doorpersist",
                "worldstate","statepersist","editstate","globalstate"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=12 },
    { patterns={"shop","economy","price","terrain","map","gamemode","round",
                "timer","spawn","leaderboard","resource","door","state","world"},
      tier=AACG.TIER.SERVER, category=AACG.CATEGORY.SV_WORLD, weight=3 },

    -- ══════════════════════════════════════════════════════════════════════════
    -- OWNER TIER — matched against everything (masteryUnlocked gate in Generate)
    -- ══════════════════════════════════════════════════════════════════════════
    { patterns={"shutdown","servershutdown","forceShutdown","globalshutdown",
                "datawipe","wipeplayer","wipedata","permanentwipe",
                "scripaccess","backendaccess","consoleexec","serverConsole"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
    { patterns={"forcerestart","serverrestart","globalrestart","restartall",
                "hiddenmodule","devmodule","ownermodule","secretmodule"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
    { patterns={"worldreset","globalreset","resetworld","fullreset",
                "gamepassinject","injectgamepass","passoverride","passunlock"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
    { patterns={"accountoverride","fullAccountoverride","playerAccountEdit",
                "devtoolactivate","activatedevtool","hiddentool","devactivate"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
    { patterns={"economydatabase","databaserewrite","fulleconomy","econdb",
                "mapfilereplacement","replacemap","filemap","mapoverride"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
    { patterns={"bypassgamerule","ruleBypass","enforcebypass","adminbypass",
                "universaladmin","unlockadmin","fulladmin","owneradmin"},
      tier=AACG.TIER.OWNER, category=AACG.CATEGORY.EVERYTHING, weight=12 },
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

        -- Gate: S2C-only remotes only allowed for LOCALIZED / OWNER tier
        local s2cBlocked = prRec and prRec.Direction == "S2C"
            and tier ~= AACG.TIER.LOCALIZED
            and tier ~= AACG.TIER.OWNER

        -- Gate: no RSM record → can't build a payload (except OWNER)
        local noRsmBlocked = not rsmRec and tier ~= AACG.TIER.OWNER

        if not s2cBlocked and not noRsmBlocked then
            -- OWNER tier: include everything, no classifier needed
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
            else
                -- Classify and filter by tier + category
                local cls = classifyRemote(name, prRec)
                if cls and cls.tier == tier and cls.category == category then
                    local conf = (sbiRec and sbiRec.Confidence) or
                                 (cls.score / 20.0)
                    conf = math.clamp(conf, 0.1, 1.0)

                    -- Suppress very low confidence
                    if conf >= 0.25 then
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
                end
            end
        end
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
