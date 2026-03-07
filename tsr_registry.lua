-- ── Imports ──────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- TSR REGISTRY — Semantic Intent Library + Binding Table
-- Defines all 100 known Intents and maintains per-game
-- bindings discovered through AVD/SARP convergence.
-- ============================================================

local REGISTRY_CFG = {
    PersistKey      = "TSR_Bindings_" .. tostring(game.PlaceId),
    PersistEnabled  = true,
    -- Minimum causal confidence to store a binding
    MinBindConfidence = 0.65,
}

-- ── Verification strategy constants ──────────────────────────────────────────
local VERIFY = {
    LinearityProbe      = "LinearityProbe",
    InvariantStateProbe = "InvariantStateProbe",
    ToggleProbe         = "ToggleProbe",
}

-- ── Relationship constants ────────────────────────────────────────────────────
local REL = {
    Linear      = "Linear",
    Direct      = "Direct",
    Boolean     = "Boolean",
    Categorical = "Categorical",
}

-- ── Risk levels (Administrative intents) ─────────────────────────────────────
local RISK = {
    LOW      = "LOW",
    MEDIUM   = "MEDIUM",
    HIGH     = "HIGH",
    CRITICAL = "CRITICAL",
}

-- ============================================================
-- STANDARD INTENT LIBRARY — 100 Definitions
-- ============================================================
local TSR_Intents = {}

-- ── ECONOMY (E01–E30) ─────────────────────────────────────────────────────────
TSR_Intents["AddCurrency"] = {
    Intent="AddCurrency", Category="Economy", Type="Atomic",
    Parameters   = { {name="type",kind="string"}, {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.Currency", "leaderstats.Coins", "leaderstats.Cash", "leaderstats.Gold" },
    Relationship = REL.Linear, Verification = VERIFY.LinearityProbe,
    SanityCapDetect = true,
}
TSR_Intents["SetCurrency"] = {
    Intent="SetCurrency", Category="Economy", Type="Atomic",
    Parameters   = { {name="type",kind="string"}, {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Currency", "leaderstats.*" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect = true,
}
TSR_Intents["SetInventoryItem"] = {
    Intent="SetInventoryItem", Category="Economy", Type="Atomic",
    Parameters   = { {name="itemId",kind="string"}, {name="quantity",kind="number"} },
    WatchTargets = { "PlayerData.Inventory", "ReplicatedStorage.PlayerInventory" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
    SanityCapDetect = true,
}
TSR_Intents["AddInventoryItem"] = {
    Intent="AddInventoryItem", Category="Economy", Type="Atomic",
    Parameters   = { {name="itemId",kind="string"}, {name="quantity",kind="number"} },
    WatchTargets = { "PlayerData.Inventory" },
    Relationship = REL.Linear, Verification = VERIFY.InvariantStateProbe,
    SanityCapDetect = true,
}
TSR_Intents["UnlockProduct"] = {
    Intent="UnlockProduct", Category="Economy", Type="Atomic",
    Parameters   = { {name="productId",kind="string"} },
    WatchTargets = { "PlayerData.Owned", "PlayerData.Unlocked" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["ForceCraft"] = {
    Intent="ForceCraft", Category="Economy", Type="Compound",
    Parameters   = { {name="recipeId",kind="string"} },
    Steps        = {
        { ActionID="ValidateMaterials", Args={"recipeId"}, Optional=false },
        { ActionID="DeductIngredients", Args={"recipeId"}, Optional=true  },
        { ActionID="GrantCraftResult",  Args={"recipeId"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Inventory" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["ClaimDailyReward"] = {
    Intent="ClaimDailyReward", Category="Economy", Type="Atomic",
    Parameters   = {},
    WatchTargets = { "PlayerData.LastClaim", "leaderstats.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ClaimQuestReward"] = {
    Intent="ClaimQuestReward", Category="Economy", Type="Compound",
    Parameters   = { {name="questId",kind="string"} },
    Steps        = {
        { ActionID="ValidateQuestComplete", Args={"questId"}, Optional=false },
        { ActionID="GrantQuestReward",      Args={"questId"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Quests", "PlayerData.Currency" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["BypassShopPurchase"] = {
    Intent="BypassShopPurchase", Category="Economy", Type="Compound",
    Parameters   = { {name="itemId",kind="string"}, {name="price",kind="number"} },
    Steps        = {
        { ActionID="ValidateFunds",  Args={"itemId","price"}, Optional=false },
        { ActionID="DeductCurrency", Args={"price"},          Optional=true  },
        { ActionID="GrantPurchase",  Args={"itemId"},         Optional=false },
    },
    WatchTargets = { "PlayerData.Inventory", "PlayerData.Currency" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["GrantGamepass"] = {
    Intent="GrantGamepass", Category="Economy", Type="Atomic",
    Parameters   = { {name="gamepassId",kind="number"} },
    WatchTargets = { "PlayerData.Gamepasses", "PlayerData.Owned" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetExperiencePoints"] = {
    Intent="SetExperiencePoints", Category="Economy", Type="Atomic",
    Parameters   = { {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.XP", "leaderstats.XP" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["AddExperiencePoints"] = {
    Intent="AddExperiencePoints", Category="Economy", Type="Atomic",
    Parameters   = { {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.XP", "leaderstats.XP" },
    Relationship = REL.Linear, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetLevel"] = {
    Intent="SetLevel", Category="Economy", Type="Atomic",
    Parameters   = { {name="level",kind="number"} },
    WatchTargets = { "PlayerData.Level", "leaderstats.Level" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["UnlockSkill"] = {
    Intent="UnlockSkill", Category="Economy", Type="Atomic",
    Parameters   = { {name="skillId",kind="string"} },
    WatchTargets = { "PlayerData.Skills", "PlayerData.Abilities" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetSkillPoints"] = {
    Intent="SetSkillPoints", Category="Economy", Type="Atomic",
    Parameters   = { {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.SkillPoints" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["ForceTradeAccept"] = {
    Intent="ForceTradeAccept", Category="Economy", Type="Compound",
    Parameters   = { {name="tradeId",kind="string"} },
    Steps        = {
        { ActionID="ValidateTrade",  Args={"tradeId"}, Optional=false },
        { ActionID="AcceptTrade",    Args={"tradeId"}, Optional=false },
        { ActionID="TransferItems",  Args={"tradeId"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Inventory" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["ClaimAchievement"] = {
    Intent="ClaimAchievement", Category="Economy", Type="Atomic",
    Parameters   = { {name="achievementId",kind="string"} },
    WatchTargets = { "PlayerData.Achievements", "PlayerData.Currency" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetPrestige"] = {
    Intent="SetPrestige", Category="Economy", Type="Atomic",
    Parameters   = { {name="prestigeLevel",kind="number"} },
    WatchTargets = { "PlayerData.Prestige", "leaderstats.Prestige" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["UnlockZone"] = {
    Intent="UnlockZone", Category="Economy", Type="Atomic",
    Parameters   = { {name="zoneId",kind="string"} },
    WatchTargets = { "PlayerData.UnlockedZones", "PlayerData.Areas" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["RefillShopStock"] = {
    Intent="RefillShopStock", Category="Economy", Type="Atomic",
    Parameters   = { {name="shopId",kind="string"} },
    WatchTargets = { "ReplicatedStorage.ShopData" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetRebirthCount"] = {
    Intent="SetRebirthCount", Category="Economy", Type="Atomic",
    Parameters   = { {name="count",kind="number"} },
    WatchTargets = { "PlayerData.Rebirths", "leaderstats.Rebirths" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["GrantPremiumCurrency"] = {
    Intent="GrantPremiumCurrency", Category="Economy", Type="Atomic",
    Parameters   = { {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.Gems", "PlayerData.Premium", "leaderstats.Gems" },
    Relationship = REL.Linear, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetMultiplier"] = {
    Intent="SetMultiplier", Category="Economy", Type="Atomic",
    Parameters   = { {name="type",kind="string"}, {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Multipliers" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["ClaimSeasonReward"] = {
    Intent="ClaimSeasonReward", Category="Economy", Type="Compound",
    Parameters   = { {name="seasonId",kind="string"}, {name="tier",kind="number"} },
    Steps        = {
        { ActionID="ValidateSeasonProgress", Args={"seasonId","tier"}, Optional=false },
        { ActionID="GrantSeasonReward",      Args={"seasonId","tier"}, Optional=false },
    },
    WatchTargets = { "PlayerData.SeasonPass", "PlayerData.Inventory" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["ForceAuctionWin"] = {
    Intent="ForceAuctionWin", Category="Economy", Type="Compound",
    Parameters   = { {name="auctionId",kind="string"}, {name="bid",kind="number"} },
    Steps        = {
        { ActionID="PlaceBid",       Args={"auctionId","bid"}, Optional=false },
        { ActionID="ValidateWinner", Args={"auctionId"},       Optional=false },
        { ActionID="TransferItem",   Args={"auctionId"},       Optional=false },
    },
    WatchTargets = { "PlayerData.Inventory", "PlayerData.Currency" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["SetStatPoint"] = {
    Intent="SetStatPoint", Category="Economy", Type="Atomic",
    Parameters   = { {name="stat",kind="string"}, {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Stats" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["UnlockRecipe"] = {
    Intent="UnlockRecipe", Category="Economy", Type="Atomic",
    Parameters   = { {name="recipeId",kind="string"} },
    WatchTargets = { "PlayerData.Recipes", "PlayerData.CraftingBook" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetTokenBalance"] = {
    Intent="SetTokenBalance", Category="Economy", Type="Atomic",
    Parameters   = { {name="tokenType",kind="string"}, {name="amount",kind="number"} },
    WatchTargets = { "PlayerData.Tokens" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["ClaimReferralBonus"] = {
    Intent="ClaimReferralBonus", Category="Economy", Type="Atomic",
    Parameters   = { {name="referralCode",kind="string"} },
    WatchTargets = { "PlayerData.Currency", "PlayerData.Bonuses" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ForceEnchant"] = {
    Intent="ForceEnchant", Category="Economy", Type="Compound",
    Parameters   = { {name="itemId",kind="string"}, {name="enchantId",kind="string"} },
    Steps        = {
        { ActionID="ValidateEnchantable", Args={"itemId"},             Optional=false },
        { ActionID="ConsumeEnchantMats",  Args={"enchantId"},          Optional=true  },
        { ActionID="ApplyEnchant",        Args={"itemId","enchantId"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Inventory", "PlayerData.Equipment" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}

-- ── WORLD INTERACTION (W01–W20) ───────────────────────────────────────────────
TSR_Intents["FireProximityPrompt"] = {
    Intent="FireProximityPrompt", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="promptPath",kind="string"} },
    WatchTargets = { "Workspace.*", "ReplicatedStorage.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["TriggerTouch"] = {
    Intent="TriggerTouch", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="partPath",kind="string"} },
    WatchTargets = { "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ClaimPlot"] = {
    Intent="ClaimPlot", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="plotId",kind="string"} },
    WatchTargets = { "Workspace.Plots", "ReplicatedStorage.PlotData" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["RemoteClick"] = {
    Intent="RemoteClick", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="buttonId",kind="string"} },
    WatchTargets = { "Workspace.*", "PlayerData.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["CollectSpawnable"] = {
    Intent="CollectSpawnable", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="spawnableId",kind="string"} },
    WatchTargets = { "PlayerData.Currency", "PlayerData.Inventory" },
    Relationship = REL.Linear, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["OpenDoor"] = {
    Intent="OpenDoor", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="doorId",kind="string"} },
    WatchTargets = { "Workspace.Doors.*" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["ActivateMechanism"] = {
    Intent="ActivateMechanism", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="mechanismId",kind="string"} },
    WatchTargets = { "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["TeleportToZone"] = {
    Intent="TeleportToZone", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="zoneId",kind="string"} },
    WatchTargets = { "Character.HumanoidRootPart.Position" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["HarvestResource"] = {
    Intent="HarvestResource", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="nodeId",kind="string"} },
    Steps        = {
        { ActionID="ValidateHarvestable", Args={"nodeId"}, Optional=false },
        { ActionID="GrantHarvestYield",   Args={"nodeId"}, Optional=false },
        { ActionID="DepleteNode",         Args={"nodeId"}, Optional=true  },
    },
    WatchTargets = { "PlayerData.Inventory", "Workspace.ResourceNodes" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["PlaceStructure"] = {
    Intent="PlaceStructure", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="structureId",kind="string"}, {name="position",kind="Vector3"} },
    Steps        = {
        { ActionID="ValidatePlacement", Args={"structureId","position"}, Optional=false },
        { ActionID="DeductBuildCost",   Args={"structureId"},            Optional=true  },
        { ActionID="SpawnStructure",    Args={"structureId","position"}, Optional=false },
    },
    WatchTargets = { "Workspace.PlayerPlots", "PlayerData.Structures" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["DestroyStructure"] = {
    Intent="DestroyStructure", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="structureId",kind="string"} },
    WatchTargets = { "Workspace.PlayerPlots" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["UpgradeStructure"] = {
    Intent="UpgradeStructure", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="structureId",kind="string"}, {name="level",kind="number"} },
    Steps        = {
        { ActionID="ValidateUpgrade",   Args={"structureId","level"}, Optional=false },
        { ActionID="DeductUpgradeCost", Args={"structureId"},         Optional=true  },
        { ActionID="ApplyUpgrade",      Args={"structureId","level"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Structures", "Workspace.PlayerPlots" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["StartMinigame"] = {
    Intent="StartMinigame", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="minigameId",kind="string"} },
    WatchTargets = { "ReplicatedStorage.GameState", "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ForceMinigameComplete"] = {
    Intent="ForceMinigameComplete", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="minigameId",kind="string"}, {name="score",kind="number"} },
    Steps        = {
        { ActionID="SubmitScore",         Args={"minigameId","score"}, Optional=false },
        { ActionID="ValidateCompletion",  Args={"minigameId"},         Optional=false },
        { ActionID="GrantMinigameReward", Args={"minigameId","score"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Currency", "PlayerData.Scores" },
    Relationship = REL.Linear, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true, SanityCapDetect=true,
}
TSR_Intents["SpawnNPC"] = {
    Intent="SpawnNPC", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="npcId",kind="string"}, {name="position",kind="Vector3"} },
    WatchTargets = { "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["RemoveNPC"] = {
    Intent="RemoveNPC", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="npcId",kind="string"} },
    WatchTargets = { "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["TriggerCutscene"] = {
    Intent="TriggerCutscene", Category="WorldInteraction", Type="Atomic",
    Parameters   = { {name="cutsceneId",kind="string"} },
    WatchTargets = { "ReplicatedStorage.CutsceneState" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["OpenChest"] = {
    Intent="OpenChest", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="chestId",kind="string"} },
    Steps        = {
        { ActionID="ValidateChestAvailable", Args={"chestId"}, Optional=false },
        { ActionID="GrantChestContents",     Args={"chestId"}, Optional=false },
        { ActionID="MarkChestOpened",        Args={"chestId"}, Optional=true  },
    },
    WatchTargets = { "PlayerData.Inventory", "Workspace.Chests" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["CompleteDungeon"] = {
    Intent="CompleteDungeon", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="dungeonId",kind="string"} },
    Steps        = {
        { ActionID="ValidateDungeonRun",  Args={"dungeonId"}, Optional=false },
        { ActionID="GrantDungeonRewards", Args={"dungeonId"}, Optional=false },
        { ActionID="RecordCompletion",    Args={"dungeonId"}, Optional=true  },
    },
    WatchTargets = { "PlayerData.Currency", "PlayerData.Inventory" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["ForceEventComplete"] = {
    Intent="ForceEventComplete", Category="WorldInteraction", Type="Compound",
    Parameters   = { {name="eventId",kind="string"} },
    Steps        = {
        { ActionID="ValidateEventActive",  Args={"eventId"}, Optional=false },
        { ActionID="SubmitEventProgress",  Args={"eventId"}, Optional=false },
        { ActionID="GrantEventReward",     Args={"eventId"}, Optional=false },
    },
    WatchTargets = { "PlayerData.Events", "PlayerData.Currency" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}

-- ── CHARACTER STATE (CS01–CS15) ───────────────────────────────────────────────
TSR_Intents["SetHealth"] = {
    Intent="SetHealth", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "Character.Humanoid.Health" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetMaxHealth"] = {
    Intent="SetMaxHealth", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "Character.Humanoid.MaxHealth" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetMana"] = {
    Intent="SetMana", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Mana", "Character.Humanoid.*" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetStamina"] = {
    Intent="SetStamina", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Stamina", "Character.*" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["ClearDebuff"] = {
    Intent="ClearDebuff", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="debuffType",kind="string"} },
    WatchTargets = { "PlayerData.StatusEffects", "Character.*" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["ToggleGodMode"] = {
    Intent="ToggleGodMode", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.Humanoid.Health" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetCharacterSize"] = {
    Intent="SetCharacterSize", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="scale",kind="number"} },
    WatchTargets = { "Character.Humanoid.BodyDepthScale" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["ReviveCharacter"] = {
    Intent="ReviveCharacter", Category="CharacterState", Type="Atomic",
    Parameters   = {},
    WatchTargets = { "Character.Humanoid.Health" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetTeam"] = {
    Intent="SetTeam", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="teamName",kind="string"} },
    WatchTargets = { "Players.LocalPlayer.Team" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ToggleInvisibility"] = {
    Intent="ToggleInvisibility", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.*.Transparency" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetRespawnTime"] = {
    Intent="SetRespawnTime", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="seconds",kind="number"} },
    WatchTargets = { "Players.LocalPlayer.RespawnLocation" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["ForceEmote"] = {
    Intent="ForceEmote", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="emoteId",kind="string"} },
    WatchTargets = { "Character.Animate.*" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetShield"] = {
    Intent="SetShield", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "PlayerData.Shield", "Character.*" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["ApplyStatusEffect"] = {
    Intent="ApplyStatusEffect", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="effectId",kind="string"}, {name="duration",kind="number"} },
    WatchTargets = { "PlayerData.StatusEffects", "Character.*" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetRagdoll"] = {
    Intent="SetRagdoll", Category="CharacterState", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.Humanoid.RigType" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}

-- ── CHARACTER PHYSICAL (CP01–CP15) ────────────────────────────────────────────
TSR_Intents["SetWalkSpeed"] = {
    Intent="SetWalkSpeed", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="speed",kind="number"} },
    WatchTargets = { "Character.Humanoid.WalkSpeed" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetJumpPower"] = {
    Intent="SetJumpPower", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="power",kind="number"} },
    WatchTargets = { "Character.Humanoid.JumpPower" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["ToggleFlight"] = {
    Intent="ToggleFlight", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.Humanoid.PlatformStand", "Character.HumanoidRootPart.Velocity" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetGravity"] = {
    Intent="SetGravity", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "Workspace.Gravity" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["TeleportTo"] = {
    Intent="TeleportTo", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="position",kind="Vector3"} },
    WatchTargets = { "Character.HumanoidRootPart.CFrame" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ToggleNoClip"] = {
    Intent="ToggleNoClip", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.*.CanCollide" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetSwimSpeed"] = {
    Intent="SetSwimSpeed", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="speed",kind="number"} },
    WatchTargets = { "Character.Humanoid.WalkSpeed" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["SetVelocity"] = {
    Intent="SetVelocity", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="velocity",kind="Vector3"} },
    WatchTargets = { "Character.HumanoidRootPart.AssemblyLinearVelocity" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["FreezeCharacter"] = {
    Intent="FreezeCharacter", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.HumanoidRootPart.Anchored" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetAirControl"] = {
    Intent="SetAirControl", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="value",kind="number"} },
    WatchTargets = { "Character.Humanoid.*" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}
TSR_Intents["TeleportToPlayer"] = {
    Intent="TeleportToPlayer", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="targetPlayer",kind="string"} },
    WatchTargets = { "Character.HumanoidRootPart.CFrame" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["LaunchCharacter"] = {
    Intent="LaunchCharacter", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="force",kind="Vector3"} },
    WatchTargets = { "Character.HumanoidRootPart.AssemblyLinearVelocity" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetClimbSpeed"] = {
    Intent="SetClimbSpeed", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="speed",kind="number"} },
    WatchTargets = { "Character.Humanoid.WalkSpeed" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    SanityCapDetect=true,
}
TSR_Intents["TogglePlatformStand"] = {
    Intent="TogglePlatformStand", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="enabled",kind="boolean"} },
    WatchTargets = { "Character.Humanoid.PlatformStand" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}
TSR_Intents["SetHipHeight"] = {
    Intent="SetHipHeight", Category="CharacterPhysical", Type="Atomic",
    Parameters   = { {name="height",kind="number"} },
    WatchTargets = { "Character.Humanoid.HipHeight" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
}

-- ── SOCIAL / IDENTITY (SI01–SI10) ─────────────────────────────────────────────
TSR_Intents["SetDisplayMorph"] = {
    Intent="SetDisplayMorph", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="morphId",kind="string"} },
    WatchTargets = { "Character.*", "PlayerData.Appearance" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ForceEquipApparel"] = {
    Intent="ForceEquipApparel", Category="SocialIdentity", Type="Compound",
    Parameters   = { {name="apparelId",kind="string"} },
    Steps        = {
        { ActionID="ValidateOwnership", Args={"apparelId"}, Optional=false },
        { ActionID="EquipApparel",      Args={"apparelId"}, Optional=false },
    },
    WatchTargets = { "Character.*", "PlayerData.Equipped" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    Constraint="Transactional", CausalPruning=true,
}
TSR_Intents["SetPlayerRank"] = {
    Intent="SetPlayerRank", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="rankName",kind="string"} },
    WatchTargets = { "PlayerData.Rank", "PlayerData.Role" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["InitiateTrade"] = {
    Intent="InitiateTrade", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="targetPlayer",kind="string"} },
    WatchTargets = { "ReplicatedStorage.TradeRequests" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SendSystemMessage"] = {
    Intent="SendSystemMessage", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="message",kind="string"} },
    WatchTargets = { "ReplicatedStorage.SystemMessages", "StarterGui.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetNameTag"] = {
    Intent="SetNameTag", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="displayName",kind="string"} },
    WatchTargets = { "Character.Head.*", "PlayerData.DisplayName" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetGuildMembership"] = {
    Intent="SetGuildMembership", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="guildId",kind="string"} },
    WatchTargets = { "PlayerData.Guild", "PlayerData.Clan" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["ForceFollowPlayer"] = {
    Intent="ForceFollowPlayer", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="targetPlayer",kind="string"} },
    WatchTargets = { "Workspace.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["SetTitle"] = {
    Intent="SetTitle", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="titleId",kind="string"} },
    WatchTargets = { "PlayerData.Title", "Character.Head.*" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
}
TSR_Intents["UnlockCosmetic"] = {
    Intent="UnlockCosmetic", Category="SocialIdentity", Type="Atomic",
    Parameters   = { {name="cosmeticId",kind="string"} },
    WatchTargets = { "PlayerData.Cosmetics", "PlayerData.Owned" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
}

-- ── ADMINISTRATIVE (A01–A10) ──────────────────────────────────────────────────
TSR_Intents["ServerKick"] = {
    Intent="ServerKick", Category="Administrative", Type="Atomic",
    Parameters   = { {name="targetPlayer",kind="string"}, {name="reason",kind="string"} },
    WatchTargets = { "Players.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.CRITICAL, RequiresConfirmation=true,
}
TSR_Intents["GlobalAnnouncement"] = {
    Intent="GlobalAnnouncement", Category="Administrative", Type="Atomic",
    Parameters   = { {name="message",kind="string"} },
    WatchTargets = { "ReplicatedStorage.Announcements", "StarterGui.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.HIGH, RequiresConfirmation=true,
}
TSR_Intents["SetTimeOfDay"] = {
    Intent="SetTimeOfDay", Category="Administrative", Type="Atomic",
    Parameters   = { {name="timeValue",kind="number"} },
    WatchTargets = { "Lighting.TimeOfDay", "Lighting.ClockTime" },
    Relationship = REL.Direct, Verification = VERIFY.LinearityProbe,
    RiskLevel=RISK.MEDIUM,
}
TSR_Intents["GiveBypass"] = {
    Intent="GiveBypass", Category="Administrative", Type="Atomic",
    Parameters   = { {name="permissionId",kind="string"} },
    WatchTargets = { "PlayerData.Permissions", "PlayerData.Flags" },
    Relationship = REL.Boolean, Verification = VERIFY.ToggleProbe,
    RiskLevel=RISK.CRITICAL, RequiresConfirmation=true,
}
TSR_Intents["ExecuteString"] = {
    Intent="ExecuteString", Category="Administrative", Type="Atomic",
    Parameters   = { {name="code",kind="string"} },
    WatchTargets = { "Workspace.*", "ReplicatedStorage.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.CRITICAL, RequiresConfirmation=true,
}
TSR_Intents["SetWeather"] = {
    Intent="SetWeather", Category="Administrative", Type="Atomic",
    Parameters   = { {name="weatherType",kind="string"} },
    WatchTargets = { "Lighting.*", "Workspace.Atmosphere.*" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.LOW,
}
TSR_Intents["ForceMapLoad"] = {
    Intent="ForceMapLoad", Category="Administrative", Type="Atomic",
    Parameters   = { {name="mapId",kind="string"} },
    WatchTargets = { "Workspace.*", "ReplicatedStorage.MapState" },
    Relationship = REL.Categorical, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.HIGH, RequiresConfirmation=true,
}
TSR_Intents["SetServerVariable"] = {
    Intent="SetServerVariable", Category="Administrative", Type="Atomic",
    Parameters   = { {name="varName",kind="string"}, {name="value",kind="string"} },
    WatchTargets = { "ReplicatedStorage.*", "Workspace.*" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.HIGH, RequiresConfirmation=true,
}
TSR_Intents["TeleportAllPlayers"] = {
    Intent="TeleportAllPlayers", Category="Administrative", Type="Atomic",
    Parameters   = { {name="position",kind="Vector3"} },
    WatchTargets = { "Players.*.Character.HumanoidRootPart.CFrame" },
    Relationship = REL.Direct, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.HIGH, RequiresConfirmation=true,
}
TSR_Intents["GlobalShutdown"] = {
    Intent="GlobalShutdown", Category="Administrative", Type="Atomic",
    Parameters   = {},
    WatchTargets = { "Players.*" },
    Relationship = REL.Boolean, Verification = VERIFY.InvariantStateProbe,
    RiskLevel=RISK.CRITICAL, RequiresConfirmation=true,
}

-- ============================================================
-- BINDING TABLE — Per-game discovered bindings
-- ============================================================
-- BindingRecord structure:
-- {
--   intentName    : string
--   remoteName    : string
--   remoteType    : string
--   argMap        : { [paramName] = argSlotIndex }
--   chainMap      : { [stepActionID] = remoteName } (compound only)
--   confidence    : number (0-1)
--   sanityMin     : number | nil
--   sanityMax     : number | nil
--   boundAt       : number (os.clock())
--   fireCount     : number
--   successCount  : number
-- }

local TSR_Registry = {}

-- Per-game binding table
local T_Bindings = {}  -- [intentName] = BindingRecord

-- ── Public API ────────────────────────────────────────────────────────────────

-- Get an Intent definition by name
function TSR_Registry.GetIntent(name)
    return TSR_Intents[name]
end

-- Get all Intent definitions, optionally filtered by category
function TSR_Registry.GetIntents(category)
    if not category then return TSR_Intents end
    local out = {}
    for name, intent in pairs(TSR_Intents) do
        if intent.Category == category then out[name] = intent end
    end
    return out
end

-- Get all category names
function TSR_Registry.GetCategories()
    local cats = {}
    for _, intent in pairs(TSR_Intents) do
        if not table.find(cats, intent.Category) then
            table.insert(cats, intent.Category)
        end
    end
    table.sort(cats)
    return cats
end

-- Store a confirmed binding
function TSR_Registry.Bind(intentName, bindingRecord)
    if not TSR_Intents[intentName] then
        warn("[TSR Registry] Unknown intent: " .. intentName)
        return false
    end
    if (bindingRecord.confidence or 0) < REGISTRY_CFG.MinBindConfidence then
        return false
    end
    bindingRecord.intentName = intentName
    bindingRecord.boundAt    = os.clock()
    bindingRecord.fireCount  = 0
    bindingRecord.successCount = 0
    T_Bindings[intentName]   = bindingRecord
    print(string.format("[TSR Registry] Bound: %s → %s (conf=%.2f)",
        intentName, bindingRecord.remoteName or "compound", bindingRecord.confidence))
    TSR_Registry.Save()
    return true
end

-- Get a binding for an intent
function TSR_Registry.GetBinding(intentName)
    return T_Bindings[intentName]
end

-- Get all bindings
function TSR_Registry.GetAllBindings()
    return T_Bindings
end

-- Check if an intent is bound
function TSR_Registry.IsBound(intentName)
    return T_Bindings[intentName] ~= nil
end

-- Record a fire outcome against a binding
function TSR_Registry.RecordOutcome(intentName, success)
    local b = T_Bindings[intentName]
    if not b then return end
    b.fireCount    = (b.fireCount or 0) + 1
    b.successCount = (b.successCount or 0) + (success and 1 or 0)
end

-- Get unbound intents (candidates for Binder to work on)
function TSR_Registry.GetUnbound()
    local out = {}
    for name, intent in pairs(TSR_Intents) do
        if not T_Bindings[name] then table.insert(out, intent) end
    end
    return out
end

-- Get binding success rate
function TSR_Registry.GetSuccessRate(intentName)
    local b = T_Bindings[intentName]
    if not b or (b.fireCount or 0) == 0 then return nil end
    return b.successCount / b.fireCount
end

-- Summary stats
function TSR_Registry.GetSummary()
    local total   = 0
    local bound   = 0
    local byCat   = {}
    for name, intent in pairs(TSR_Intents) do
        total = total + 1
        local cat = intent.Category
        if not byCat[cat] then byCat[cat] = {total=0, bound=0} end
        byCat[cat].total = byCat[cat].total + 1
        if T_Bindings[name] then
            bound = bound + 1
            byCat[cat].bound = byCat[cat].bound + 1
        end
    end
    return { total=total, bound=bound, unbound=total-bound, byCategory=byCat }
end

-- Persist bindings to _G
function TSR_Registry.Save()
    if not REGISTRY_CFG.PersistEnabled then return end
    pcall(function()
        local save = {}
        for name, b in pairs(T_Bindings) do
            save[name] = {
                remoteName   = b.remoteName,
                remoteType   = b.remoteType,
                argMap       = b.argMap,
                chainMap     = b.chainMap,
                confidence   = b.confidence,
                sanityMin    = b.sanityMin,
                sanityMax    = b.sanityMax,
                fireCount    = b.fireCount,
                successCount = b.successCount,
            }
        end
        _G[REGISTRY_CFG.PersistKey] = save
    end)
end

-- Load bindings from _G
function TSR_Registry.Load()
    pcall(function()
        local saved = _G[REGISTRY_CFG.PersistKey]
        if type(saved) ~= "table" then return end
        local count = 0
        for name, b in pairs(saved) do
            if TSR_Intents[name] then
                b.intentName = name
                b.boundAt    = os.clock()
                T_Bindings[name] = b
                count = count + 1
            end
        end
        if count > 0 then
            print(string.format("[TSR Registry] Loaded %d persisted bindings.", count))
        end
    end)
end

-- Constants exposed for other modules
TSR_Registry.VERIFY = VERIFY
TSR_Registry.REL    = REL
TSR_Registry.RISK   = RISK

-- ── Export ────────────────────────────────────────────────────────────────────
if not _G.PC.TSR then _G.PC.TSR = {} end
_G.PC.TSR.Registry = TSR_Registry
_G.PC.TSR.Intents  = TSR_Intents

TSR_Registry.Load()
print(string.format("[TSR Registry] Ready. %d intents loaded.", (function()
    local n=0; for _ in pairs(TSR_Intents) do n=n+1 end; return n
end)()))
