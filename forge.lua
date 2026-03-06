local _C = _G.PC
local mk = _C.mk
local addCorner = _C.addCorner
local addStroke = _C.addStroke
local pulseClick = _C.pulseClick
local hookHover = _C.hookHover
local clickSound = _C.clickSound
local HttpService = _C.HttpService
local Players = _C.Players
local player = _C.player
local Lighting = _C.Lighting
local LWM = _C.LWM
local ETM = _C.ETM
local CDG = _C.CDG
local RAE_State = _C.RAE_State
local RAE_Callbacks = _C.RAE_Callbacks
local WorldState = _C.WorldState
local ClassifyRemote = _C.ClassifyRemote
local CategoryRisk = _C.CategoryRisk
local ANTICHEAT_RISK_GATE = _C.ANTICHEAT_RISK_GATE
local SEMANTIC_TAGS = _C.SEMANTIC_TAGS
local cleanTable = _C.cleanTable
local tryDecode = _C.tryDecode
local _U = _G.PCU
local sendNotification = _U.sendNotification
local makeButton = _U.makeButton
local makeSection = _U.makeSection
local makeToggle = _U.makeToggle
local pageForge = _U.pageForge
local contentCard = _U.contentCard
-- FORGE — Autonomous Payload Builder
-- Rides on top of RAE v2. Does not modify RAE internals.
-- Modules: Analyzer · Generator · Simulator · Queue · FeedbackLoop · ResponseProbe
-- ============================================================

local PayloadForge = {}

-- ── Persistence keys ─────────────────────────────────────────
local FORGE_PERSIST_VER       = "v1"
local FORGE_PERSIST_OUTCOMES  = "PF_Outcomes_"  .. FORGE_PERSIST_VER
local FORGE_PERSIST_TEMPLATES = "PF_Templates_" .. FORGE_PERSIST_VER
local FORGE_PERSIST_FINGERPRINTS = "PF_Fingerprints_" .. FORGE_PERSIST_VER

-- ── Internal state ────────────────────────────────────────────
local ForgeOutcomes     = {}   -- [remoteName] = { {payload, success, response, sig, timestamp} }
local ForgeTemplates    = {}   -- [category]   = { {shape, weight, successCount, totalCount} }
local ForgeFingerprints = {}   -- [remoteName] = { [responseHash] = {count, payloadsThatCaused} }
local ForgeQueue        = {}   -- [remoteName] = { top scored payload entries }
local ForgeLog          = {}   -- flat ordered log of all launches

local function SaveForge()
    pcall(function()
        _G[FORGE_PERSIST_OUTCOMES]     = ForgeOutcomes
        _G[FORGE_PERSIST_TEMPLATES]    = ForgeTemplates
        _G[FORGE_PERSIST_FINGERPRINTS] = ForgeFingerprints
    end)
end

local function LoadForge()
    pcall(function()
        if type(_G[FORGE_PERSIST_OUTCOMES])     == "table" then ForgeOutcomes     = _G[FORGE_PERSIST_OUTCOMES]     end
        if type(_G[FORGE_PERSIST_TEMPLATES])    == "table" then ForgeTemplates    = _G[FORGE_PERSIST_TEMPLATES]    end
        if type(_G[FORGE_PERSIST_FINGERPRINTS]) == "table" then ForgeFingerprints = _G[FORGE_PERSIST_FINGERPRINTS] end
    end)
end

-- ── Utility: simple hash of a string response for fingerprinting ──
local function HashResponse(str)
    if type(str) ~= "string" then str = tostring(str) end
    local h = 5381
    for i = 1, #str do h = bit32.band(h * 33 + string.byte(str, i), 0xFFFFFFFF) end
    return string.format("%08X", h)
end

-- ── Utility: read a value from any accessible IntValue/NumberValue/StringValue ──
local function ReadValueObject(name)
    local found = game:FindFirstChild(name, true)
    if found and (found:IsA("IntValue") or found:IsA("NumberValue") or found:IsA("BoolValue") or found:IsA("StringValue")) then
        return found.Value
    end
    return nil
end

-- ============================================================
-- MODULE 1: ANALYZER
-- Infers expected argument shape for a remote from:
--   1. Observed fire logs (LastArgs)
--   2. UI scan cross-reference (value objects, leaderstat names)
--   3. Category-based structural heuristics
--   4. ETM + CDG context from RAE
-- ============================================================
PayloadForge.Analyzer = {}

-- Infer Lua type tag from a runtime value
local function InferTypeTag(v)
    local t = type(v)
    if t == "number"  then return v == math.floor(v) and "integer" or "float" end
    if t == "string"  then return #v > 20 and "string_long" or "string_short" end
    if t == "boolean" then return "boolean" end
    if t == "table"   then return "table" end
    if t == "userdata" then
        local ok, cls = pcall(function() return v.ClassName end)
        return ok and ("instance:"..cls) or "userdata"
    end
    return t
end

-- Scrape the game world for contextually valid string/number values
-- Returns a context table keyed by semantic hint
local function BuildWorldContext()
    local ctx = {
        playerName    = Players.LocalPlayer.Name,
        userId        = Players.LocalPlayer.UserId,
        toolNames     = {},
        inventoryIds  = {},
        leaderstats   = {},
        uiTextValues  = {},
        valueObjects  = {},
        otherPlayers  = {},
        position      = Vector3.new(0,0,0),
        cframe        = CFrame.new(),
    }
    local char = Players.LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then ctx.position = hrp.Position; ctx.cframe = hrp.CFrame end
    -- Tools
    for _, t in ipairs(Players.LocalPlayer.Backpack:GetChildren()) do
        if t:IsA("Tool") then table.insert(ctx.toolNames, t.Name) end
    end
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then table.insert(ctx.toolNames, t.Name) end
        end
    end
    -- Leaderstats
    local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            ctx.leaderstats[v.Name] = v.Value
        end
    end
    -- Value objects from LWM registry
    local ws = RAE_State.WorldState
    if ws then
        for _, vo in ipairs(ws.Latent.ValueObjects or {}) do
            ctx.valueObjects[vo.Name] = vo.Value
        end
    end
    -- Other player names
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= Players.LocalPlayer then table.insert(ctx.otherPlayers, p.Name) end
    end
    -- UI text values from visible TextLabels/TextBoxes
    for _, obj in ipairs(Players.LocalPlayer.PlayerGui:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextBox")) and obj.Visible then
            local txt = obj.Text
            if txt and #txt > 0 and #txt < 64 then
                local num = tonumber(txt)
                if num then table.insert(ctx.uiTextValues, num)
                else table.insert(ctx.uiTextValues, txt) end
            end
        end
    end
    return ctx
end

-- Analyze a single remote entry and return an inference record
function PayloadForge.Analyzer.Analyze(remoteEntry)
    local category = ClassifyRemote(remoteEntry.Name)
    local risk      = CategoryRisk(category)
    local ctx       = BuildWorldContext()
    local observed  = remoteEntry.LastArgs and #remoteEntry.LastArgs > 0

    -- Build type signature from observed args if available
    local inferredShape = {}
    if observed then
        for i, arg in ipairs(remoteEntry.LastArgs) do
            inferredShape[i] = {
                position = i,
                typeTag  = InferTypeTag(arg),
                sample   = arg,
                source   = "observed",
            }
        end
    end

    -- ETM confidence for this remote's cards
    local etmConf, etmConv = 0.5, false
    for _, card in ipairs(RAE_State.Cards or {}) do
        if card.Metadata.Semantic == category or card.Name:find(remoteEntry.Name, 1, true) then
            local p, c, _ = ETM.Predict(card.ID, RAE_State.CurrentSig)
            if c then etmConv = true end
            etmConf = math.max(etmConf, p)
        end
    end

    -- CDG causal score: how much does this remote influence downstream state
    local causalInfluence = 0.0
    for _, card in ipairs(RAE_State.Cards or {}) do
        if card.Name:find(remoteEntry.Name, 1, true) then
            causalInfluence = causalInfluence + CDG.GetCausalScore(card.ID)
        end
    end

    return {
        Name             = remoteEntry.Name,
        Instance         = remoteEntry.Instance,
        Category         = category,
        Risk             = risk,
        ObservedArgs     = remoteEntry.LastArgs or {},
        InferredShape    = inferredShape,
        FireCount        = remoteEntry.FireCount or 0,
        Context          = ctx,
        ETMConf          = etmConf,
        ETMConverged     = etmConv,
        CausalInfluence  = causalInfluence,
        IsAntiCheat      = (category == "AntiCheat"),
        Priority         = (function()
            if category == "AntiCheat" then return 0.0 end
            local base = 0.3
            if category == "Economy"  or category == "Purchase" or category == "Bank"    then base = 0.90 end
            if category == "Identity" or category == "SaveLoad"                          then base = 0.75 end
            if category == "Loot"     or category == "Crafting" or category == "Trade"   then base = 0.65 end
            if category == "Quest"    or category == "Regions"  or category == "Vehicles" then base = 0.50 end
            if category == "Combat"   or category == "Movement" or category == "Physics"  then base = 0.45 end
            return math.clamp(base + etmConf * 0.1 + math.min(causalInfluence, 0.1), 0, 1.0)
        end)(),
    }
end

-- ============================================================
-- MODULE 2: GENERATOR
-- Builds 10–20 payload variants per remote.
-- Sources: observed args (replay), category templates, world
-- context (GUI mimic), mutation of known-good shapes, and
-- boundary/overflow probes for bounds detection.
-- ============================================================
PayloadForge.Generator = {}

-- Category-specific template factories
local CATEGORY_TEMPLATES = {
    Economy = function(ctx)
        local base = ctx.leaderstats["Cash"] or ctx.leaderstats["Coins"] or ctx.leaderstats["Money"] or 100
        return {
            { {base + 1000},              label="Increment +1000",       risk="Low"      },
            { {base * 2},                 label="Double current",         risk="Low"      },
            { {math.huge},                label="Infinity probe",         risk="Medium"   },
            { {-1},                       label="Negative bypass",        risk="Medium"   },
            { {0},                        label="Zero probe",             risk="Low"      },
            { {2^31 - 1},                 label="MAX_INT probe",          risk="Medium"   },
            { {99999999},                 label="Large value",            risk="Medium"   },
            { {math.floor(base * 1.5)},   label="1.5x current",           risk="Low"      },
        }
    end,
    Purchase = function(ctx)
        local items = #ctx.toolNames > 0 and ctx.toolNames or {"item_1","weapon_1","tool_basic"}
        local results = {}
        for _, name in ipairs(items) do
            table.insert(results, { {name, 1},     label="Buy x1: "..name,    risk="Low"  })
            table.insert(results, { {name, 99},    label="Buy x99: "..name,   risk="Medium" })
            table.insert(results, { {name, -1},    label="Negative qty: "..name, risk="Medium" })
        end
        table.insert(results, { {ctx.uiTextValues[1] or "item_special", 1}, label="UI-inferred item", risk="Low" })
        return results
    end,
    Identity = function(ctx)
        return {
            { {ctx.playerName},                          label="Self-target",          risk="High" },
            { {ctx.playerName, "admin"},                 label="Self + admin rank",    risk="High" },
            { {ctx.playerName, true},                    label="Self + bool true",     risk="High" },
            { {ctx.userId},                              label="UserId numeric",       risk="High" },
            { {"all"},                                   label='"all" broadcast',      risk="High" },
        }
    end,
    Loot = function(ctx)
        return {
            { {},                                       label="Empty probe",           risk="Low"   },
            { {1},                                      label="Quantity 1",            risk="Low"   },
            { {10},                                     label="Quantity 10",           risk="Low"   },
            { {math.random(1000,9999)},                 label="Random ID",             risk="Low"   },
            { {"premium"},                              label='"premium" type',        risk="Medium" },
            { {"legendary"},                            label='"legendary" type',      risk="Medium" },
        }
    end,
    Crafting = function(ctx)
        local items = #ctx.toolNames > 0 and ctx.toolNames or {"material_1","ore_iron","plank"}
        local results = {}
        for _, name in ipairs(items) do
            table.insert(results, { {name},       label="Craft: "..name,        risk="Low" })
            table.insert(results, { {name, 1},    label="Craft x1: "..name,     risk="Low" })
            table.insert(results, { {name, 99},   label="Craft x99: "..name,    risk="Medium" })
        end
        return results
    end,
    Trade = function(ctx)
        local target = ctx.otherPlayers[1] or "Player1"
        return {
            { {target},                            label="Target: "..target,     risk="Low"    },
            { {target, 1},                         label="Offer x1 to "..target, risk="Low"    },
            { {target, -1},                        label="Negative offer",        risk="Medium" },
            { {target, "accept"},                  label="Force accept",          risk="Medium" },
            { {target, "cancel"},                  label="Force cancel",          risk="Low"    },
        }
    end,
    SaveLoad = function(ctx)
        return {
            { {},                                  label="Empty flush",           risk="Medium" },
            { {ctx.playerName},                    label="Self data key",         risk="Medium" },
            { {ctx.userId},                        label="UserId key",            risk="Medium" },
            { {"override", true},                  label="Override flag",         risk="High"   },
            { {"push"},                            label='"push" command',        risk="Medium" },
        }
    end,
    Quest = function(ctx)
        return {
            { {1},                                 label="Quest ID 1",            risk="Low"  },
            { {math.random(1,50)},                 label="Random quest ID",       risk="Low"  },
            { {"complete"},                        label='"complete" string',     risk="Low"  },
            { {"turnin"},                          label='"turnin" string',       risk="Low"  },
            { {ctx.playerName, 1},                 label="Player + quest 1",      risk="Low"  },
        }
    end,
    Movement = function(ctx)
        local pos = ctx.position
        return {
            { {pos},                                          label="Current position",       risk="Low"    },
            { {Vector3.new(0, 1000, 0)},                      label="High altitude",          risk="Medium" },
            { {Vector3.new(pos.X+50, pos.Y, pos.Z+50)},       label="Offset +50",             risk="Low"    },
            { {ctx.cframe},                                   label="Current CFrame",         risk="Low"    },
            { {Vector3.new(0,0,0)},                           label="World origin",           risk="Low"    },
        }
    end,
    Combat = function(ctx)
        return {
            { {999},                                label="Damage 999",            risk="Medium" },
            { {-999},                               label="Negative damage",       risk="Medium" },
            { {ctx.playerName, 100},               label="Self-hit 100",          risk="Medium" },
            { {0},                                 label="Zero damage",            risk="Low"    },
            { {2^31-1},                            label="MAX dmg probe",          risk="High"   },
        }
    end,
    Bank = function(ctx)
        local bal = ctx.leaderstats["Cash"] or ctx.leaderstats["Gold"] or 0
        return {
            { {"deposit", bal},                    label="Deposit all",           risk="Low"    },
            { {"withdraw", bal},                   label="Withdraw all",          risk="Low"    },
            { {"withdraw", 99999999},              label="Withdraw MAX",          risk="Medium" },
            { {"deposit", -1},                     label="Deposit negative",      risk="Medium" },
            { {"withdraw", -1},                    label="Withdraw negative",     risk="Medium" },
        }
    end,
    DataValidation = function(ctx)
        local tools = ctx.toolNames
        return {
            { {tools[1] or "sword"},               label="Equip first tool",      risk="Low"    },
            { {"unequip"},                         label="Unequip command",       risk="Low"    },
            { {ctx.playerName, "update"},          label="Player update",         risk="Medium" },
            { {true},                              label="Bool true",             risk="Low"    },
            { {false},                             label="Bool false",            risk="Low"    },
        }
    end,
    Vehicles = function(ctx)
        return {
            { {ctx.playerName},                    label="Self-mount",            risk="Low"  },
            { {"eject"},                           label='"eject" command',       risk="Low"  },
            { {1},                                 label="Seat ID 1",             risk="Low"  },
        }
    end,
    Regions = function(ctx)
        return {
            { {ctx.playerName},                    label="Self-enter",            risk="Low"  },
            { {"lobby"},                           label='"lobby" target',        risk="Low"  },
            { {"main"},                            label='"main" target',         risk="Low"  },
            { {1},                                 label="Region ID 1",           risk="Low"  },
        }
    end,
}

-- Generate a replay variant from observed args (most trusted source)
local function GenObservedVariants(analysis)
    local variants = {}
    if #analysis.ObservedArgs > 0 then
        -- Exact replay
        table.insert(variants, {
            args    = analysis.ObservedArgs,
            label   = "Observed Replay (exact)",
            source  = "observed",
            risk    = "Low",
            confidence = 0.85,
        })
        -- Numeric mutation: try +1 and -1 on any number arg
        for i, arg in ipairs(analysis.ObservedArgs) do
            if type(arg) == "number" then
                local argsPlus = {}; for j, a in ipairs(analysis.ObservedArgs) do argsPlus[j] = a end
                argsPlus[i] = arg + 1
                table.insert(variants, {
                    args    = argsPlus,
                    label   = string.format("Observed +1 (arg %d)", i),
                    source  = "mutation",
                    risk    = "Low",
                    confidence = 0.65,
                })
                local argsMinus = {}; for j, a in ipairs(analysis.ObservedArgs) do argsMinus[j] = a end
                argsMinus[i] = arg - 1
                table.insert(variants, {
                    args    = argsMinus,
                    label   = string.format("Observed -1 (arg %d)", i),
                    source  = "mutation",
                    risk    = "Low",
                    confidence = 0.60,
                })
                -- Bounds probe
                local argsZero = {}; for j, a in ipairs(analysis.ObservedArgs) do argsZero[j] = a end
                argsZero[i] = 0
                table.insert(variants, {
                    args    = argsZero,
                    label   = string.format("Observed zero probe (arg %d)", i),
                    source  = "boundary",
                    risk    = "Medium",
                    confidence = 0.45,
                })
            end
        end
    end
    return variants
end

-- Generate category-template variants, contextualised with world data
local function GenTemplateVariants(analysis)
    local variants = {}
    local factory  = CATEGORY_TEMPLATES[analysis.Category]
    if not factory then
        -- Generic fallback: probe with empty, true/false, and player name
        local ctx = analysis.Context
        local fallbacks = {
            { {},                  label="Empty probe",      risk="Low",    confidence=0.30 },
            { {ctx.playerName},    label="Player name",      risk="Low",    confidence=0.35 },
            { {true},              label="Bool true",        risk="Low",    confidence=0.25 },
            { {false},             label="Bool false",       risk="Low",    confidence=0.25 },
            { {1},                 label="Int 1",            risk="Low",    confidence=0.20 },
        }
        for _, fb in ipairs(fallbacks) do
            table.insert(variants, { args=fb[1], label=fb.label, source="fallback", risk=fb.risk, confidence=fb.confidence })
        end
        return variants
    end
    local templates = factory(analysis.Context)
    for _, tmpl in ipairs(templates) do
        table.insert(variants, {
            args       = tmpl[1],
            label      = tmpl.label,
            source     = "template",
            risk       = tmpl.risk or "Low",
            confidence = 0.50,
        })
    end
    return variants
end

-- Incorporate learned template weights from FeedbackLoop
local function ApplyLearnedWeights(variants, remoteName, category)
    local outcomes = ForgeOutcomes[remoteName] or {}
    local successMap = {}
    for _, outcome in ipairs(outcomes) do
        if outcome.success then
            local key = HttpService:JSONEncode(outcome.payload or {})
            successMap[key] = (successMap[key] or 0) + 1
        end
    end
    for _, variant in ipairs(variants) do
        local ok, key = pcall(function() return HttpService:JSONEncode(variant.args) end)
        if ok and successMap[key] then
            variant.confidence = math.min(variant.confidence + successMap[key] * 0.12, 0.99)
            variant.label = variant.label .. " ★"
        end
    end
    -- Also apply category-level template weights
    local catTemplates = ForgeTemplates[category] or {}
    for _, tmpl in ipairs(catTemplates) do
        if tmpl.totalCount > 0 then
            local rate = tmpl.successCount / tmpl.totalCount
            for _, variant in ipairs(variants) do
                if variant.label == tmpl.shape then
                    variant.confidence = math.clamp(variant.confidence * 0.5 + rate * 0.5, 0.01, 0.99)
                end
            end
        end
    end
    return variants
end

function PayloadForge.Generator.Generate(analysis)
    if analysis.IsAntiCheat and ANTICHEAT_RISK_GATE then
        return {}  -- Never generate payloads for AntiCheat remotes
    end
    local variants = {}
    -- 1. Observed-arg variants (highest trust)
    for _, v in ipairs(GenObservedVariants(analysis))  do table.insert(variants, v) end
    -- 2. Category-template variants
    for _, v in ipairs(GenTemplateVariants(analysis))  do table.insert(variants, v) end
    -- 3. Apply learned weights from prior sessions
    variants = ApplyLearnedWeights(variants, analysis.Name, analysis.Category)
    -- 4. Sort by confidence descending, cap at 20
    table.sort(variants, function(a, b) return a.confidence > b.confidence end)
    if #variants > 20 then
        local trimmed = {}
        for i = 1, 20 do trimmed[i] = variants[i] end
        variants = trimmed
    end
    return variants
end

-- ============================================================
-- MODULE 3: SIMULATOR
-- Dry-runs each variant against the world model.
-- Scores by: confidence, risk penalty, ETM prior, outcome history.
-- Culls low-scorers, returns top N.
-- ============================================================
PayloadForge.Simulator = {}

local RISK_PENALTY = { Low=0.0, Medium=0.12, High=0.30, Critical=1.00 }

local function SimScore(variant, analysis)
    local base       = variant.confidence or 0.5
    local riskPen    = RISK_PENALTY[variant.risk or "Low"] or 0.0
    local etmBonus   = analysis.ETMConf * 0.15
    local causalBon  = math.min(analysis.CausalInfluence * 0.05, 0.10)
    local firePrior  = math.min((analysis.FireCount or 0) * 0.02, 0.10)
    -- History bonus: if this exact payload succeeded before, score higher
    local histBonus  = 0.0
    local outcomes   = ForgeOutcomes[analysis.Name] or {}
    for _, o in ipairs(outcomes) do
        if o.success then
            local ok, k1 = pcall(function() return HttpService:JSONEncode(variant.args) end)
            local ok2, k2 = pcall(function() return HttpService:JSONEncode(o.payload) end)
            if ok and ok2 and k1 == k2 then histBonus = histBonus + 0.15 end
        end
    end
    return math.clamp(base + etmBonus + causalBon + firePrior + histBonus - riskPen, 0.01, 0.99)
end

function PayloadForge.Simulator.Score(variants, analysis, topN)
    topN = topN or 5
    local scored = {}
    for _, variant in ipairs(variants) do
        local score = SimScore(variant, analysis)
        table.insert(scored, {
            args         = variant.args,
            label        = variant.label,
            source       = variant.source,
            risk         = variant.risk,
            confidence   = variant.confidence,
            SimScore     = score,
            ProjectedUtility = string.format("%.0f%%", score * 100),
        })
    end
    table.sort(scored, function(a, b) return a.SimScore > b.SimScore end)
    local top = {}
    for i = 1, math.min(topN, #scored) do top[i] = scored[i] end
    return top
end

-- ============================================================
-- MODULE 4: FEEDBACK LOOP
-- Records outcome after a user-launched payload.
-- Updates template weights and fingerprint map.
-- ============================================================
PayloadForge.FeedbackLoop = {}

function PayloadForge.FeedbackLoop.Record(remoteName, category, payload, success, responseRaw)
    if not ForgeOutcomes[remoteName] then ForgeOutcomes[remoteName] = {} end
    local fp = HashResponse(tostring(responseRaw or ""))
    -- Fingerprint
    if not ForgeFingerprints[remoteName] then ForgeFingerprints[remoteName] = {} end
    if not ForgeFingerprints[remoteName][fp] then
        ForgeFingerprints[remoteName][fp] = { count=0, payloads={}, isError=tostring(responseRaw):lower():find("error")~=nil }
    end
    local fpEntry = ForgeFingerprints[remoteName][fp]
    fpEntry.count = fpEntry.count + 1
    local ok, pKey = pcall(function() return HttpService:JSONEncode(payload) end)
    if ok then
        local found = false
        for _, p in ipairs(fpEntry.payloads) do if p == pKey then found=true; break end end
        if not found then table.insert(fpEntry.payloads, pKey) end
    end
    -- Outcome record
    table.insert(ForgeOutcomes[remoteName], {
        payload      = payload,
        success      = success,
        response     = tostring(responseRaw or ""),
        fingerprint  = fp,
        sig          = RAE_State.CurrentSig,
        timestamp    = os.clock(),
    })
    -- Cap history per remote at 50
    if #ForgeOutcomes[remoteName] > 50 then table.remove(ForgeOutcomes[remoteName], 1) end
    -- Category template weight update
    if not ForgeTemplates[category] then ForgeTemplates[category] = {} end
    local pKeyStr = ok and HttpService:JSONEncode(payload) or "?"
    local found = false
    for _, tmpl in ipairs(ForgeTemplates[category]) do
        if tmpl.shape == pKeyStr then
            found = true
            tmpl.totalCount   = tmpl.totalCount + 1
            if success then tmpl.successCount = tmpl.successCount + 1 end
            break
        end
    end
    if not found then
        table.insert(ForgeTemplates[category], { shape=pKeyStr, weight=success and 0.6 or 0.3, successCount=success and 1 or 0, totalCount=1 })
    end
    -- Add to flat log
    table.insert(ForgeLog, {
        Remote    = remoteName,
        Category  = category,
        Payload   = payload,
        Success   = success,
        Response  = tostring(responseRaw or ""),
        FP        = fp,
        T         = os.clock(),
    })
    if #ForgeLog > 200 then table.remove(ForgeLog, 1) end
    SaveForge()
end

-- ============================================================
-- MODULE 5: RESPONSE PROBE
-- After firing a payload, intercepts any detectable state change
-- (health delta, leaderstats delta, error from namecall) and
-- returns a structured outcome signal for FeedbackLoop.
-- ============================================================
PayloadForge.ResponseProbe = {}

function PayloadForge.ResponseProbe.CaptureBaseline()
    local char = Players.LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local ls   = Players.LocalPlayer:FindFirstChild("leaderstats")
    local snap = {
        health     = hum and hum.Health or 0,
        tools      = {},
        leaderstats = {},
        timestamp  = os.clock(),
    }
    for _, t in ipairs(Players.LocalPlayer.Backpack:GetChildren()) do
        if t:IsA("Tool") then snap.tools[t.Name] = true end
    end
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            snap.leaderstats[v.Name] = v.Value
        end
    end
    return snap
end

function PayloadForge.ResponseProbe.CompareToBaseline(baseline, responseRaw)
    local char = Players.LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local ls   = Players.LocalPlayer:FindFirstChild("leaderstats")
    local changes = {}
    -- Health delta
    local newHealth = hum and hum.Health or 0
    if math.abs(newHealth - baseline.health) > 0.5 then
        table.insert(changes, string.format("Health: %+.1f", newHealth - baseline.health))
    end
    -- Leaderstats delta
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            local prev = baseline.leaderstats[v.Name]
            if prev ~= nil and v.Value ~= prev then
                table.insert(changes, string.format("%s: %s → %s", v.Name, tostring(prev), tostring(v.Value)))
            end
        end
    end
    -- New tools
    for _, t in ipairs(Players.LocalPlayer.Backpack:GetChildren()) do
        if t:IsA("Tool") and not baseline.tools[t.Name] then
            table.insert(changes, "New tool: " .. t.Name)
        end
    end
    local responseStr = tostring(responseRaw or "")
    local isError = responseStr:lower():find("error") ~= nil
        or responseStr:lower():find("invalid") ~= nil
        or responseStr:lower():find("fail") ~= nil
    local success = #changes > 0 and not isError
    return {
        success   = success,
        changes   = changes,
        isError   = isError,
        errorHint = isError and responseStr or nil,
        summary   = #changes > 0 and table.concat(changes, "  |  ") or (isError and "Error: "..responseStr or "No observable change"),
    }
end

-- ============================================================
-- FORGE ORCHESTRATOR
-- Top-level entry point: Analyze → Generate → Simulate → Queue
-- ============================================================
function PayloadForge.BuildQueue(remoteEntry)
    local analysis = PayloadForge.Analyzer.Analyze(remoteEntry)
    if analysis.IsAntiCheat then
        return nil, "AntiCheat remote — skipped for safety."
    end
    local variants  = PayloadForge.Generator.Generate(analysis)
    local topScored = PayloadForge.Simulator.Score(variants, analysis, 5)
    ForgeQueue[remoteEntry.Name] = {
        Analysis  = analysis,
        Payloads  = topScored,
        Built     = os.clock(),
    }
    return ForgeQueue[remoteEntry.Name], nil
end

-- Launch a specific queued payload; returns outcome record
function PayloadForge.Launch(remoteName, payloadEntry)
    local qEntry = ForgeQueue[remoteName]
    if not qEntry then return nil, "Remote not in queue." end
    local analysis  = qEntry.Analysis
    local remote    = analysis.Instance
    if not remote or not pcall(function() return remote.Parent ~= nil end) then
        return nil, "Remote instance no longer accessible."
    end
    local baseline   = PayloadForge.ResponseProbe.CaptureBaseline()
    local responseRaw = nil
    local fireOk, fireErr = pcall(function()
        if remote:IsA("RemoteFunction") then
            responseRaw = remote:InvokeServer(table.unpack(payloadEntry.args or {}))
        else
            remote:FireServer(table.unpack(payloadEntry.args or {}))
        end
    end)
    if not fireOk then responseRaw = fireErr end
    task.wait(0.45)  -- allow server round-trip and state replication
    local outcome = PayloadForge.ResponseProbe.CompareToBaseline(baseline, responseRaw)
    PayloadForge.FeedbackLoop.Record(remoteName, analysis.Category, payloadEntry.args, outcome.success, responseRaw or "")
    -- Feed result back into RAE's ETM and CDG via a synthetic log entry
    for _, card in ipairs(RAE_State.Cards or {}) do
        if card.Name:find(remoteName, 1, true) then
            ETM.Update(card.ID, RAE_State.CurrentSig, outcome.success)
        end
    end
    return outcome, nil
end

-- ============================================================
-- PAGE: Forge (UI)
-- ============================================================
do
    local _, sHdr = makeSection(pageForge, "Payload Forge")
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
        Text="Autonomous payload builder. Reads RAE's discovered remotes, infers expected argument shapes from observed fires and world context, generates ranked variants, and queues them for manual launch. AntiCheat remotes are automatically gated.",
        TextColor3=Color3.fromRGB(92,84,76),TextSize=12,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,64),Parent=sHdr})

    -- Status bar
    local forgeStatusLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Status: Idle  |  Queue: 0 remotes  |  Log: 0 launches",
        TextColor3=Color3.fromRGB(72,66,60),TextSize=11,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,20),Parent=sHdr})

    local function updateForgeStatus()
        local qcount=0; for _ in pairs(ForgeQueue) do qcount=qcount+1 end
        forgeStatusLabel.Text=string.format("Status: Ready  |  Queue: %d remotes  |  Log: %d launches",qcount,#ForgeLog)
    end

    -- ── Remote list + Forge buttons ──────────────────────────
    local _, sRemotes = makeSection(pageForge, "Discovered Remotes")
    local forgeRemoteScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),
        Size=UDim2.new(1,0,0,240),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4,Parent=sRemotes})
    addCorner(forgeRemoteScroll,UDim.new(0,8)); addStroke(forgeRemoteScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,5),Parent=forgeRemoteScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=forgeRemoteScroll})

    -- ── Payload Queue panel ───────────────────────────────────
    local _, sQueue = makeSection(pageForge, "Payload Queue")
    local queueRemoteLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="Select a remote above to view its queue.",
        TextColor3=Color3.fromRGB(72,66,60),TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,0,0,20),Parent=sQueue})
    local queueScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),
        Size=UDim2.new(1,0,0,220),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4,Parent=sQueue})
    addCorner(queueScroll,UDim.new(0,8)); addStroke(queueScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,5),Parent=queueScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=queueScroll})

    -- ── Outcome Log ───────────────────────────────────────────
    local _, sOutcome = makeSection(pageForge, "Launch Outcome Log")
    local outcomeScroll=mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(245,242,238),
        Size=UDim2.new(1,0,0,180),CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=4,Parent=sOutcome})
    addCorner(outcomeScroll,UDim.new(0,8)); addStroke(outcomeScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=outcomeScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=outcomeScroll})

    -- Adds a row to the outcome log
    local function appendOutcomeLog(remoteName, payloadEntry, outcome)
        local row=mk("Frame",{
            BackgroundColor3=outcome.success and Color3.fromRGB(230,255,230) or Color3.fromRGB(255,240,235),
            Size=UDim2.new(1,0,0,46),Parent=outcomeScroll})
        addCorner(row,UDim.new(0,5)); addStroke(row,1,0.2)
        mk("TextLabel",{
            Text=string.format("%s  [%s]  %s",outcome.success and "✓" or "✕",remoteName,payloadEntry.label),
            Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(50,50,50),
            Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,0,14),
            TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
        mk("TextLabel",{
            Text=outcome.summary,
            Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(80,80,80),
            Position=UDim2.new(0,8,0,22),Size=UDim2.new(1,-16,0,20),
            TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextWrapped=true,Parent=row})
    end

    -- Rebuild queue panel for a specific remote
    local function showQueueFor(remoteName)
        queueRemoteLabel.Text="Queue for: "..remoteName
        queueScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,5),Parent=queueScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=queueScroll})
        local qEntry=ForgeQueue[remoteName]
        if not qEntry or #qEntry.Payloads==0 then
            mk("TextLabel",{Text="No payloads generated yet. Click 'Forge' on a remote first.",
                BackgroundTransparency=1,Font=Enum.Font.GothamMedium,TextSize=11,
                TextColor3=Color3.fromRGB(150,150,150),Size=UDim2.new(1,0,0,24),Parent=queueScroll})
            return
        end
        local analysis=qEntry.Analysis
        -- Analysis summary row
        local anaRow=mk("Frame",{BackgroundColor3=Color3.fromRGB(240,245,255),Size=UDim2.new(1,0,0,42),Parent=queueScroll})
        addCorner(anaRow,UDim.new(0,5)); addStroke(anaRow,1,0.2)
        mk("TextLabel",{
            Text=string.format("Category: %s  |  Risk: %s  |  Priority: %.0f%%  |  ETM: %.2f %s  |  CDG: %.3f",
                analysis.Category, analysis.Risk, analysis.Priority*100,
                analysis.ETMConf, analysis.ETMConverged and "✓" or "~", analysis.CausalInfluence),
            Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(60,60,100),
            Position=UDim2.new(0,8,0,4),Size=UDim2.new(1,-16,0,14),
            TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=anaRow})
        mk("TextLabel",{
            Text=string.format("Fires observed: %d  |  Variants scored: %d  |  Built: %.1fs ago",
                analysis.FireCount, #qEntry.Payloads, os.clock()-qEntry.Built),
            Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(80,80,80),
            Position=UDim2.new(0,8,0,22),Size=UDim2.new(1,-16,0,14),
            TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=anaRow})

        -- Payload cards
        for rank, pe in ipairs(qEntry.Payloads) do
            local riskColor=pe.risk=="High" and Color3.fromRGB(200,80,80) or pe.risk=="Medium" and Color3.fromRGB(200,160,60) or Color3.fromRGB(80,180,80)
            local pCard=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,72),Parent=queueScroll})
            addCorner(pCard,UDim.new(0,6)); addStroke(pCard,1,0.2)

            -- Rank badge
            local badge=mk("TextLabel",{Text="#"..rank,Font=Enum.Font.GothamBold,TextSize=14,
                TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=Color3.fromRGB(100,120,200),
                Size=UDim2.new(0,28,1,0),TextXAlignment=Enum.TextXAlignment.Center,Parent=pCard})
            addCorner(badge,UDim.new(0,6))

            mk("TextLabel",{Text=pe.label,Font=Enum.Font.GothamBold,TextSize=11,
                TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,36,0,5),
                Size=UDim2.new(1,-130,0,14),TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=pCard})

            -- Projected utility bar
            local utilPct = pe.SimScore or 0.5
            local barBg=mk("Frame",{BackgroundColor3=Color3.fromRGB(235,230,225),
                Position=UDim2.new(0,36,0,22),Size=UDim2.new(0.55,0,0,10),Parent=pCard})
            addCorner(barBg,UDim.new(0,5))
            local barFill=mk("Frame",{BackgroundColor3=Color3.fromRGB(120,200,120),
                Size=UDim2.new(utilPct,0,1,0),Parent=barBg})
            addCorner(barFill,UDim.new(0,5))
            mk("TextLabel",{Text=pe.ProjectedUtility,Font=Enum.Font.GothamBold,TextSize=10,
                TextColor3=Color3.fromRGB(80,80,80),Position=UDim2.new(0.58,0,0,20),
                Size=UDim2.new(0,50,0,14),BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Parent=pCard})

            -- Args preview
            local argsStr="args: "
            if pe.args and #pe.args>0 then
                local parts={}
                for _, a in ipairs(pe.args) do
                    if type(a)=="userdata" then table.insert(parts,"[Vector3/CF]")
                    elseif type(a)=="table" then table.insert(parts,"[table]")
                    else table.insert(parts, tostring(a)) end
                end
                argsStr = argsStr .. table.concat(parts, ", ")
            else argsStr = argsStr .. "none" end
            mk("TextLabel",{Text=argsStr,Font=Enum.Font.Code,TextSize=9,TextColor3=Color3.fromRGB(100,100,100),
                Position=UDim2.new(0,36,0,36),Size=UDim2.new(1,-130,0,12),
                TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=pCard})

            -- Risk tag
            local rtag=mk("TextLabel",{Text=pe.risk,Font=Enum.Font.GothamBold,TextSize=9,
                TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=riskColor,
                Position=UDim2.new(1,-108,0,5),Size=UDim2.new(0,56,0,18),
                TextXAlignment=Enum.TextXAlignment.Center,Parent=pCard})
            addCorner(rtag,UDim.new(0,5))

            -- Source tag
            local srcColor=pe.source=="observed" and Color3.fromRGB(80,160,200) or pe.source=="mutation" and Color3.fromRGB(160,120,200) or Color3.fromRGB(160,160,160)
            local stag=mk("TextLabel",{Text=pe.source or "?",Font=Enum.Font.GothamBold,TextSize=9,
                TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=srcColor,
                Position=UDim2.new(1,-108,0,26),Size=UDim2.new(0,56,0,18),
                TextXAlignment=Enum.TextXAlignment.Center,Parent=pCard})
            addCorner(stag,UDim.new(0,5))

            -- Launch button
            local launchBtn=mk("TextButton",{Text="▶ Launch",Font=Enum.Font.GothamBold,TextSize=10,
                BackgroundColor3=Color3.fromRGB(200,240,200),Size=UDim2.new(0,80,0,28),
                AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-8,0.5,0),Parent=pCard})
            addCorner(launchBtn,UDim.new(0,6)); addStroke(launchBtn,1,0.3)
            hookHover(launchBtn,launchBtn.BackgroundColor3,Color3.fromRGB(180,255,180),0.3,0.1)

            local peCapture=pe; local rnCapture=remoteName
            launchBtn.MouseButton1Click:Connect(function()
                clickSound(); pulseClick(launchBtn)
                launchBtn.Text="..."; launchBtn.BackgroundColor3=Color3.fromRGB(220,220,180)
                task.spawn(function()
                    local outcome, err = PayloadForge.Launch(rnCapture, peCapture)
                    if err then
                        sendNotification("Forge: "..err, "Error")
                        launchBtn.Text="✕ Err"; launchBtn.BackgroundColor3=Color3.fromRGB(255,200,200)
                    else
                        local icon = outcome.success and "✓" or "✕"
                        sendNotification(string.format("Forge [%s] %s — %s",rnCapture,icon,outcome.summary), outcome.success and "Success" or "Warning")
                        launchBtn.Text=icon.." Done"
                        launchBtn.BackgroundColor3=outcome.success and Color3.fromRGB(180,255,180) or Color3.fromRGB(255,200,200)
                        appendOutcomeLog(rnCapture, peCapture, outcome)
                        updateForgeStatus()
                        -- Refresh queue scores after feedback
                        task.wait(0.3)
                        local qe=ForgeQueue[rnCapture]
                        if qe then
                            local newScored=PayloadForge.Simulator.Score(
                                PayloadForge.Generator.Generate(qe.Analysis), qe.Analysis, 5)
                            qe.Payloads=newScored
                            showQueueFor(rnCapture)
                        end
                    end
                end)
            end)
        end
    end

    -- Build the remote list from RAE's current WorldState
    local function refreshForgeRemotes()
        forgeRemoteScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,5),Parent=forgeRemoteScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8),Parent=forgeRemoteScroll})
        local ws=RAE_State.WorldState
        if not ws or #ws.Latent.RemoteEvents==0 then
            mk("TextLabel",{Text="No remotes found. Run RAE Scan first.",BackgroundTransparency=1,
                Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=Color3.fromRGB(150,150,150),
                Size=UDim2.new(1,0,0,24),Parent=forgeRemoteScroll})
            return
        end
        -- Sort by analysis priority descending
        local remoteList={}
        for _, r in ipairs(ws.Latent.RemoteEvents) do
            local cat=ClassifyRemote(r.Name)
            local pri=(function()
                if cat=="AntiCheat" then return -1 end
                if cat=="Economy" or cat=="Purchase" or cat=="Bank" then return 0.9 end
                if cat=="Identity" or cat=="SaveLoad" then return 0.75 end
                if cat=="Loot" or cat=="Crafting" or cat=="Trade" then return 0.65 end
                return 0.4
            end)()
            table.insert(remoteList, {Remote=r, Category=cat, Priority=pri})
        end
        table.sort(remoteList, function(a,b) return a.Priority > b.Priority end)
        for _, item in ipairs(remoteList) do
            local r   = item.Remote
            local cat = item.Category
            local isAC = cat == "AntiCheat"
            local catColor=isAC and Color3.fromRGB(255,200,200)
                or cat=="Economy" and Color3.fromRGB(220,255,220)
                or cat=="Identity" and Color3.fromRGB(255,220,220)
                or cat=="Loot" and Color3.fromRGB(255,240,200)
                or Color3.fromRGB(240,240,255)
            local row=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(1,0,0,48),Parent=forgeRemoteScroll})
            addCorner(row,UDim.new(0,6)); addStroke(row,1,0.2)
            -- Category badge
            local cbadge=mk("TextLabel",{Text=cat,Font=Enum.Font.GothamBold,TextSize=9,
                TextColor3=Color3.fromRGB(50,50,50),BackgroundColor3=catColor,
                Position=UDim2.new(0,8,0,5),Size=UDim2.new(0,82,0,16),
                TextXAlignment=Enum.TextXAlignment.Center,Parent=row})
            addCorner(cbadge,UDim.new(0,4))
            mk("TextLabel",{Text=r.Name,Font=Enum.Font.GothamBold,TextSize=12,
                TextColor3=Color3.fromRGB(50,50,50),Position=UDim2.new(0,98,0,5),
                Size=UDim2.new(1,-280,0,14),TextXAlignment=Enum.TextXAlignment.Left,
                BackgroundTransparency=1,TextTruncate=Enum.TextTruncate.AtEnd,Parent=row})
            mk("TextLabel",{
                Text=string.format("Fires:%d  %s",r.FireCount or 0,r.FireCount>0 and "✓ observed" or "unobserved"),
                Font=Enum.Font.Code,TextSize=10,TextColor3=Color3.fromRGB(100,100,100),
                Position=UDim2.new(0,98,0,22),Size=UDim2.new(1,-280,0,12),
                TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
            if isAC then
                local acWarn=mk("TextLabel",{Text="⚠ AntiCheat — gated",Font=Enum.Font.GothamBold,TextSize=10,
                    TextColor3=Color3.fromRGB(180,50,50),AnchorPoint=Vector2.new(1,0.5),
                    Position=UDim2.new(1,-8,0.5,0),Size=UDim2.new(0,140,0,24),
                    TextXAlignment=Enum.TextXAlignment.Right,BackgroundTransparency=1,Parent=row})
            else
                local btnRow2=mk("Frame",{BackgroundTransparency=1,AnchorPoint=Vector2.new(1,0.5),
                    Position=UDim2.new(1,-8,0.5,0),Size=UDim2.new(0,164,0,32),Parent=row})
                mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,HorizontalAlignment=Enum.HorizontalAlignment.Right,
                    VerticalAlignment=Enum.VerticalAlignment.Center,Padding=UDim.new(0,6),Parent=btnRow2})
                -- Forge button
                local forgeBtn=mk("TextButton",{Text="⚙ Forge",Font=Enum.Font.GothamBold,TextSize=10,
                    BackgroundColor3=Color3.fromRGB(220,220,255),Size=UDim2.new(0,76,0,28),Parent=btnRow2})
                addCorner(forgeBtn,UDim.new(0,6)); addStroke(forgeBtn,1,0.3)
                hookHover(forgeBtn,forgeBtn.BackgroundColor3,Color3.fromRGB(200,200,255),0.3,0.1)
                -- View Queue button
                local viewBtn=mk("TextButton",{Text="📋 View",Font=Enum.Font.GothamBold,TextSize=10,
                    BackgroundColor3=Color3.fromRGB(220,240,220),Size=UDim2.new(0,76,0,28),Parent=btnRow2})
                addCorner(viewBtn,UDim.new(0,6)); addStroke(viewBtn,1,0.3)
                hookHover(viewBtn,viewBtn.BackgroundColor3,Color3.fromRGB(180,240,180),0.3,0.1)
                local rCapture=r
                forgeBtn.MouseButton1Click:Connect(function()
                    clickSound(); pulseClick(forgeBtn)
                    forgeBtn.Text="⏳ ..."
                    task.spawn(function()
                        local qResult, err = PayloadForge.BuildQueue(rCapture)
                        if err then
                            sendNotification("Forge: "..err,"Error")
                            forgeBtn.Text="✕ Err"
                        else
                            sendNotification(string.format("Forge built %d payloads for [%s]",#qResult.Payloads,rCapture.Name),"Success")
                            forgeBtn.Text="✓ Done"
                            forgeBtn.BackgroundColor3=Color3.fromRGB(200,255,200)
                            updateForgeStatus()
                            showQueueFor(rCapture.Name)
                        end
                    end)
                end)
                viewBtn.MouseButton1Click:Connect(function()
                    clickSound(); pulseClick(viewBtn)
                    showQueueFor(rCapture.Name)
                end)
            end
        end
        updateForgeStatus()
    end

    -- Top control row
    local ctrlRow=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,44),Parent=sHdr})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=ctrlRow})
    local refreshBtn=makeButton(ctrlRow,"Refresh Remotes",UDim2.new(0,200,0,40),"🔄")
    refreshBtn.Button.BackgroundColor3=Color3.fromRGB(220,230,255)
    local forgeAllBtn=makeButton(ctrlRow,"Forge All",UDim2.new(0,160,0,40),"⚙")
    forgeAllBtn.Button.BackgroundColor3=Color3.fromRGB(220,255,220)
    local clearLogBtn=makeButton(ctrlRow,"Clear Log",UDim2.new(0,140,0,40),"🗑")
    clearLogBtn.Button.BackgroundColor3=Color3.fromRGB(255,235,235)

    refreshBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(refreshBtn.Button); refreshForgeRemotes()
    end)
    forgeAllBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(forgeAllBtn.Button)
        local ws=RAE_State.WorldState
        if not ws then sendNotification("Run RAE Scan first.","Warning"); return end
        task.spawn(function()
            local built=0
            for _, r in ipairs(ws.Latent.RemoteEvents or {}) do
                local cat=ClassifyRemote(r.Name)
                if cat~="AntiCheat" then
                    PayloadForge.BuildQueue(r)
                    built=built+1
                    task.wait(0.02)
                end
            end
            sendNotification(string.format("Forge All complete — %d remotes queued.",built),"Success")
            refreshForgeRemotes()
        end)
    end)
    clearLogBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(clearLogBtn.Button)
        ForgeLog={}
        outcomeScroll:ClearAllChildren()
        mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,3),Parent=outcomeScroll})
        mk("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,6),Parent=outcomeScroll})
        updateForgeStatus()
        sendNotification("Forge log cleared.","Info")
    end)

    -- Auto-refresh remote list after RAE scan
    local prevOnScanForge = RAE_Callbacks.OnScan
    RAE_Callbacks.OnScan = function(ws, cards)
        if prevOnScanForge then prevOnScanForge(ws, cards) end
        refreshForgeRemotes()
    end

    -- Expose Forge in global API (added after _G.RAE_Engine assignment below)
    task.defer(function()
        if _G.RAE_Engine then _G.RAE_Engine.Forge = PayloadForge end
    end)

    -- Seed remote list on first open if RAE already has data
    if RAE_State.WorldState then refreshForgeRemotes() end
end

-- Load persisted Forge data
LoadForge()

-- ============================================================