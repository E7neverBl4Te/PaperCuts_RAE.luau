-- ── Imports ───────────────────────────────────────────────────────────────────
local _C = _G.PC

-- ============================================================
-- APE — Active Probing Engine
-- Layer 6 of the PaperCuts intelligence stack.
--
-- APE is a pure orchestration layer. It does not replace
-- AVD Strategist or Operator — it directs them.
--
--   Strategist  — target registry, technique execution, findings
--   Operator    — actual remote firing, rate limiting, passive hooks
--   APE         — WHO to probe, WHAT goal, WHICH technique,
--                  WHEN to stop (saturation), HOW to schedule
--                  (throttle-aware, AC-aware)
--
-- It also contributes 6 SBI/RSM-informed probe techniques that
-- Strategist's generic library cannot produce, injected via the
-- new Strategist.AppendPlans() hook.
--
-- Modules:
--   1  PRIORITY SCORER        rank every known remote by info need
--   2  GOAL PLANNER           determine what gap to fill per remote
--   3  TECHNIQUE LIBRARY      6 APE-native plan generators
--   4  CAMPAIGN MANAGER       structured probe sequences w/ goals
--   5  SATURATION DETECTOR    stop when marginal info gain → 0
--   6  THROTTLE-AWARE SCHEDULER respect SBI.ThrottleFloor
--   7  AC-AWARE GATE          back off under CORRECTS_FAST
-- ============================================================

local APE = {}

-- ── Configuration ─────────────────────────────────────────────
local APE_CFG = {
    -- Max simultaneous active campaigns
    MaxConcurrentCampaigns  = 3,
    -- How many top-priority remotes Scan() launches at once
    ScanBatchSize           = 5,
    -- Saturation: rolling window size
    SatWindowSize           = 4,
    -- Saturation: mean |ΔConf| below this → saturated
    SatThreshold            = 0.015,
    -- Minimum SBI confidence to consider a remote "done enough" (skip it)
    DoneThreshold           = 0.82,
    -- Auto-scan period (seconds) — kept for reference / manual calls
    AutoScanPeriod          = 60.0,
    -- NHPP scan cadence bounds (seconds)
    NHPPMinWait             = 12.0,   -- floor: never scan faster than this
    NHPPMaxWait             = 300.0,  -- ceiling: never go longer than this idle
    -- Plans per campaign maximum
    MaxPlansPerCampaign     = 32,
    -- Per-plan fire timeout (seconds, used by campaign runner)
    PlanFireTimeout         = 4.0,
    -- Inter-plan base delay inside a campaign (seconds)
    InterPlanDelay          = 0.4,
    -- AC gate delays per pattern
    ACDelay = {
        CORRECTS_FAST = 2.0,
        CORRECTS      = 1.0,
        MONITORS      = 0.3,
        PASSIVE       = 0.0,
        NONE          = 0.0,
    },
    -- Persist
    PersistEnabled = true,
    PersistKey     = "APE_State_" .. tostring(game.PlaceId),
    PersistVer     = "v1",
}

-- ── Goal constants ─────────────────────────────────────────────
APE.GOAL = {
    CAUSAL       = "CAUSAL",        -- build CausalLinks
    VALIDATION   = "VALIDATION",    -- determine ValidationPattern
    RATE_PROFILE = "RATE_PROFILE",  -- measure ThrottleFloor
    AC_PROFILE   = "AC_PROFILE",    -- measure AC correction rate
    CLASSIFY     = "CLASSIFY",      -- reach ServerLogic classification
}

-- ── Campaign status ────────────────────────────────────────────
APE.STATUS = {
    PENDING   = "PENDING",
    RUNNING   = "RUNNING",
    COMPLETE  = "COMPLETE",
    SATURATED = "SATURATED",
    ABORTED   = "ABORTED",
}

-- ── Semantic weights for priority scoring ─────────────────────
local APE_SEMANTIC_WEIGHT = {
    ECONOMY  = 1.00,
    COMBAT   = 0.85,
    MOVEMENT = 0.70,
    SESSION  = 0.65,
    PHYSICS  = 0.60,
    SPAWN    = 0.70,
    ANTICHEAT= 0.50,
    UNKNOWN  = 0.40,
}

-- ── Internal state ─────────────────────────────────────────────
local APE_Campaigns      = {}   -- [id] = Campaign
local APE_CampaignIDSeq  = 0
local APE_Saturation     = {}   -- [remoteName] = {gains[], ptr, saturated}
local APE_LastFireT      = {}   -- [remoteName] = os.clock()
local APE_Running        = false
local APE_ActiveCount    = 0
local APE_TotalCampaigns = 0
local APE_TotalProbesFired = 0

-- ── Utility ───────────────────────────────────────────────────
local function APE_NextID()
    APE_CampaignIDSeq = APE_CampaignIDSeq + 1
    return APE_CampaignIDSeq
end

-- ── Natural Distribution Sampler ─────────────────────────────────────────────
-- Replaces uniform/boundary arg generation with ETM/RSM frequency-weighted
-- sampling. Makes probe arg entropy look like a slightly glitchy player rather
-- than an automated fuzzer.
--
-- For numbers  : Gaussian centered on observed mean, σ from SuccessValues spread.
--                Clamps to [min-10%, max+10%] of observed range.
-- For strings  : Frequency-weighted selection from SuccessStrings history.
--                Earlier (more frequent) entries get higher weight via Zipf-like
--                decay — matches real traffic distributions.
-- For booleans : Biased 80/20 toward the more commonly observed value.
-- ─────────────────────────────────────────────────────────────────────────────

-- Box-Muller Gaussian sample
local function APE_SampleGaussian(mean, sigma)
    local u1 = math.max(1e-10, math.random())
    local u2 = math.random()
    local z  = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    return mean + sigma * z
end

-- Zipf-weighted string selection: index 1 gets weight N, index 2 gets N/2, etc.
local function APE_SampleZipfString(strs)
    if #strs == 0 then return "" end
    if #strs == 1 then return strs[1] end
    local weights = {}
    local total   = 0
    for i = 1, #strs do
        local w = #strs / i   -- Zipf: weight ∝ 1/rank, scaled by N
        weights[i] = w
        total = total + w
    end
    local r = math.random() * total
    local cum = 0
    for i, w in ipairs(weights) do
        cum = cum + w
        if r <= cum then return strs[i] end
    end
    return strs[#strs]
end

function APE_DefaultArgs(schema)
    local args = {}
    for _, slot in ipairs(schema or {}) do
        local t = slot.DominantType or "number"
        if t == "number" then
            local vals = slot.SuccessValues or {}
            if #vals >= 2 then
                -- Gaussian from observed distribution
                local sum, sum2 = 0, 0
                for _, v in ipairs(vals) do sum = sum + v; sum2 = sum2 + v*v end
                local mean  = sum / #vals
                local var   = math.max(0, sum2/#vals - mean*mean)
                local sigma = math.sqrt(var) * 0.6  -- slightly tighter than raw std
                local lo    = math.min(table.unpack(vals))
                local hi    = math.max(table.unpack(vals))
                local margin= (hi - lo) * 0.1
                local sample= APE_SampleGaussian(mean, math.max(sigma, 0.1))
                table.insert(args, math.clamp(sample, lo - margin, hi + margin))
            elseif #vals == 1 then
                -- Single observed value — add small Gaussian noise
                table.insert(args, APE_SampleGaussian(vals[1], math.abs(vals[1]) * 0.05 + 0.1))
            else
                table.insert(args, slot.NumberMean or 0)
            end

        elseif t == "string" then
            local strs = slot.SuccessStrings or slot.StringSamples or {}
            if #strs > 0 then
                table.insert(args, APE_SampleZipfString(strs))
            else
                table.insert(args, "")
            end

        elseif t == "boolean" then
            -- 80/20 bias toward true (most game remotes expect true for ability flags)
            table.insert(args, math.random() < 0.80)

        else
            table.insert(args, nil)
        end
    end
    return args
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 1 — PRIORITY SCORER
-- ═════════════════════════════════════════════════════════════
local APE_Scorer = {}

function APE_Scorer.Score(remoteName)
    local SBI = _G.PC.SBI
    local RSM = _G.PC.RSM
    local PR  = _G.PC.PR_Registry

    local sbiRec = SBI and SBI.Get(remoteName)
    local rsmRec = RSM and RSM.Get(remoteName)
    local prRec  = PR  and PR[remoteName]

    if not prRec then return 0 end  -- not even catalogued

    -- Saturation penalty
    local sat = APE_Saturation[remoteName]
    local satPenalty = sat and sat.saturated and 5.0 or 0.0

    -- SBI confidence gap
    local sbiConf = sbiRec and sbiRec.Confidence or 0.0
    if sbiConf >= APE_CFG.DoneThreshold then return 0 end  -- done enough

    -- Semantic weight
    local role   = (sbiRec and sbiRec.SemanticRole) or (prRec and prRec.SemanticRole) or "UNKNOWN"
    local weight = APE_SEMANTIC_WEIGHT[role] or APE_SEMANTIC_WEIGHT.UNKNOWN

    -- RSM signal boost: high-RSM-confidence means we know it exists but SBI doesn't know what it does
    local rsmBoost = 0
    if rsmRec and rsmRec.Confidence >= 0.4 and sbiConf < 0.3 then
        rsmBoost = 0.15
    end

    -- Frequency boost: high-fire-rate remotes are more important
    local hzBoost = 0
    if rsmRec then
        local hz = rsmRec.TemporalSig.AvgHz or 0
        hzBoost = math.min(0.10, hz * 0.02)
    end

    local raw = (1 - sbiConf) * weight + rsmBoost + hzBoost
    return raw / (satPenalty + 1)
end

function APE_Scorer.GetRanked(minScore)
    minScore = minScore or 0.01
    local PR = _G.PC.PR_Registry
    if not PR then return {} end

    local out = {}
    for name in pairs(PR) do
        local s = APE_Scorer.Score(name)
        if s >= minScore then
            table.insert(out, { name=name, score=s })
        end
    end
    table.sort(out, function(a,b) return a.score > b.score end)
    return out
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 2 — GOAL PLANNER
-- ═════════════════════════════════════════════════════════════
local APE_GoalPlanner = {}

function APE_GoalPlanner.PlanGoals(remoteName)
    local SBI = _G.PC.SBI
    local RSM = _G.PC.RSM
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist

    local sbiRec = SBI and SBI.Get(remoteName)
    local rsmRec = RSM and RSM.Get(remoteName)
    local goals  = {}

    -- GOAL_CAUSAL: no CausalLinks yet, but we've seen signal
    if sbiRec then
        if #(sbiRec.CausalLinks or {}) == 0 and (sbiRec.FindingCount or 0) >= 1 then
            table.insert(goals, APE.GOAL.CAUSAL)
        end
    elseif rsmRec and rsmRec.Confidence >= 0.3 then
        -- RSM knows it exists but SBI has never been run on it
        table.insert(goals, APE.GOAL.CAUSAL)
    end

    -- GOAL_VALIDATION: pattern unknown after several probes
    if sbiRec and (sbiRec.ValidationPattern == "NONE" or not sbiRec.ValidationPattern) then
        if (sbiRec.ProbeCount or 0) >= 4 or (rsmRec and rsmRec.ArgSig and #rsmRec.ArgSig > 0) then
            table.insert(goals, APE.GOAL.VALIDATION)
        end
    end

    -- GOAL_RATE_PROFILE: ThrottleFloor unknown and we've seen at least one SILENT
    if sbiRec and sbiRec.ThrottleFloor == nil then
        local findings = strategist and strategist.GetFindings and strategist.GetFindings(0) or {}
        local seenSilent = false
        for _, f in ipairs(findings) do
            if f.remoteName == remoteName and f.signal == "SILENT" then
                seenSilent = true; break
            end
        end
        if seenSilent then
            table.insert(goals, APE.GOAL.RATE_PROFILE)
        end
    end

    -- GOAL_AC_PROFILE: ACPattern still NONE after enough probes
    if sbiRec and sbiRec.ACPattern == "NONE" and (sbiRec.FindingCount or 0) >= 3 then
        table.insert(goals, APE.GOAL.AC_PROFILE)
    end

    -- GOAL_CLASSIFY: ServerLogic still unknown but SBI conf is building
    if sbiRec and sbiRec.ServerLogic == "UNKNOWN" and (sbiRec.Confidence or 0) >= 0.25 then
        table.insert(goals, APE.GOAL.CLASSIFY)
    end

    return goals
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 3 — TECHNIQUE LIBRARY (APE-native)
-- Each returns plans[], compatible with Strategist plan format.
-- New fields: preDelay, cascadeTargets (handled by campaign runner)
-- ═════════════════════════════════════════════════════════════
local APE_Techniques = {}

-- 1. RSMBoundaryRefinement
-- Binary-searches the numeric boundary around RSM's SuccessValues/FailValues.
APE_Techniques.RSMBoundaryRefinement = function(remoteName, schema)
    local RSM    = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(remoteName)
    if not rsmRec then return {} end

    local plans = {}
    for slotIdx, argSig in ipairs(rsmRec.ArgSig) do
        if argSig.DominantType == "number" and
           #argSig.SuccessValues > 0 and #argSig.FailValues > 0 then

            -- Sort values to find the boundary region
            local sv = {table.unpack(argSig.SuccessValues)}
            local fv = {table.unpack(argSig.FailValues)}
            table.sort(sv); table.sort(fv)
            local minSuccess = sv[1]
            local maxFail    = fv[#fv]

            -- Geometric probe points around midpoint
            local mid = (minSuccess + maxFail) / 2
            local eps = math.max(1, math.abs(mid) * 0.02)
            local probeVals = {
                mid, mid - eps, mid + eps,
                mid * 0.5, mid * 1.5,
                maxFail + eps, minSuccess - eps,
                maxFail, minSuccess,
            }

            for _, v in ipairs(probeVals) do
                local args = APE_DefaultArgs(schema)
                args[slotIdx] = v
                table.insert(plans, {
                    kind           = "RSMBoundaryRefinement",
                    args           = args,
                    technique      = "RSMBoundaryRefinement",
                    description    = string.format("Boundary refinement slot %d: v=%.4g (mid=%.4g)", slotIdx, v, mid),
                    expectedSignal = v >= minSuccess and "CONFIRMED" or "SILENT",
                    boundarySlot   = slotIdx,
                    probeVal       = v,
                })
            end
        end
    end
    return plans
end

-- 2. RSMEnumExpansion
-- Generates variants of known passing string values to find additional enum entries.
APE_Techniques.RSMEnumExpansion = function(remoteName, schema)
    local RSM    = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(remoteName)
    if not rsmRec then return {} end

    local SUFFIXES = {"_v2","_admin","_god","_max","_debug","_test","_hack","_bypass","2","3"}
    local PREFIXES = {"get_","set_","buy_","give_","use_","cheat_","debug_"}
    local plans = {}

    for slotIdx, argSig in ipairs(rsmRec.ArgSig) do
        if argSig.DominantType == "string" and #argSig.SuccessStrings > 0 then
            local seen = {}
            local variants = {}

            for _, s in ipairs(argSig.SuccessStrings) do
                -- Case variants
                for _, v in ipairs({s:lower(), s:upper(), s:sub(1,1):upper()..s:sub(2):lower()}) do
                    if not seen[v] then seen[v]=true; table.insert(variants, v) end
                end
                -- Suffix variants
                for _, suf in ipairs(SUFFIXES) do
                    local v = s .. suf
                    if not seen[v] then seen[v]=true; table.insert(variants, v) end
                end
                -- Prefix variants
                for _, pre in ipairs(PREFIXES) do
                    local v = pre .. s
                    if not seen[v] then seen[v]=true; table.insert(variants, v) end
                end
            end

            -- Trim to max 16 variants
            for i = 1, math.min(16, #variants) do
                local v = variants[i]
                local args = APE_DefaultArgs(schema)
                args[slotIdx] = v
                table.insert(plans, {
                    kind           = "RSMEnumExpansion",
                    args           = args,
                    technique      = "RSMEnumExpansion",
                    description    = string.format("Enum expansion slot %d: \"%s\"", slotIdx, v),
                    expectedSignal = "CONFIRMED",
                    enumSlot       = slotIdx,
                    enumVal        = v,
                })
            end
        end
    end
    return plans
end

-- 3. SpacedRateProbe
-- Fires with geometrically-spaced pre-delays to profile the throttle floor curve.
APE_Techniques.SpacedRateProbe = function(remoteName, schema)
    local args  = APE_DefaultArgs(schema)
    local delays = {0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0}
    local plans = {}
    for _, d in ipairs(delays) do
        table.insert(plans, {
            kind           = "SpacedRateProbe",
            args           = args,
            technique      = "SpacedRateProbe",
            description    = string.format("Rate probe with %.2fs pre-delay", d),
            expectedSignal = "CONFIRMED",
            preDelay       = d,   -- APE campaign runner enforces this
            rateGap        = d,
        })
    end
    return plans
end

-- 4. CausalIsolationProbe
-- EchoDifferential variant with long pre-wait to let world settle.
-- Produces cleaner causal attribution via SR.Diff.
APE_Techniques.CausalIsolationProbe = function(remoteName, schema)
    local RSM    = _G.PC.RSM
    local rsmRec = RSM and RSM.Get(remoteName)
    local args = {}

    -- Prefer RSM SuccessValues for each slot
    if rsmRec then
        for i, argSig in ipairs(rsmRec.ArgSig) do
            if argSig.DominantType == "number" and #argSig.SuccessValues > 0 then
                args[i] = argSig.SuccessValues[1]
            elseif argSig.DominantType == "string" and #argSig.SuccessStrings > 0 then
                args[i] = argSig.SuccessStrings[1]
            else
                args[i] = APE_DefaultArgs({argSig})[1]
            end
        end
    else
        args = APE_DefaultArgs(schema)
    end

    return {{
        kind           = "CausalIsolationProbe",
        args           = args,
        technique      = "CausalIsolationProbe",
        description    = "Isolated EchoDifferential with 3s pre-quiescence wait",
        expectedSignal = "CONFIRMED",
        preDelay       = 3.0,    -- wait for world quiescence
        watchWindow    = 2.5,
    }}
end

-- 5. CascadeProbe
-- Fires primary remote then quickly fires known SBI cascade targets.
APE_Techniques.CascadeProbe = function(remoteName, schema)
    local SBI    = _G.PC.SBI
    local sbiRec = SBI and SBI.Get(remoteName)
    if not sbiRec or not next(sbiRec.SideEffects or {}) then return {} end

    local RSM  = _G.PC.RSM
    local PR   = _G.PC.PR_Registry
    local args = APE_DefaultArgs(schema)
    local plans = {}

    for cascadeName, se in pairs(sbiRec.SideEffects) do
        if (se.confidence or 0) >= 0.25 then
            -- Build args for cascade target
            local cascRsm    = RSM and RSM.Get(cascadeName)
            local cascPR     = PR and PR[cascadeName]
            local cascSchema = cascRsm and cascRsm.ArgSig or
                               (cascPR and cascPR.ArgSchema) or {}
            local cascArgs   = APE_DefaultArgs(cascSchema)

            table.insert(plans, {
                kind           = "CascadeProbe",
                args           = args,
                technique      = "CascadeProbe",
                description    = string.format("Cascade: %s → %s (conf %.0f%%)",
                    remoteName, cascadeName, (se.confidence or 0)*100),
                expectedSignal = "STRONG",
                cascadeTargets = {{ name=cascadeName, args=cascArgs }},
                cascadeDelayMs = se.delayMs or 200,
            })
        end
    end
    return plans
end

-- 6. ValidationCrossCheck
-- Fires at boundary ± epsilon values to sharpen RANGE_CHECK boundary confidence.
APE_Techniques.ValidationCrossCheck = function(remoteName, schema)
    local SBI    = _G.PC.SBI
    local sbiRec = SBI and SBI.Get(remoteName)
    if not sbiRec then return {} end

    local ev  = sbiRec.ValidationEvidence
    if sbiRec.ValidationPattern ~= "RANGE_CHECK" or ev.boundary == nil then return {} end

    local bnd  = ev.boundary
    local axis = ev.boundaryAxis or 1
    local dir  = ev.boundaryDir  or "ABOVE_PASS"
    local eps  = math.max(1, math.abs(bnd) * 0.01)
    local plans = {}

    local probeVals = {
        { val=bnd - eps*10, label="boundary-10ε" },
        { val=bnd - eps,    label="boundary-ε"   },
        { val=bnd,          label="boundary"      },
        { val=bnd + eps,    label="boundary+ε"    },
        { val=bnd + eps*10, label="boundary+10ε"  },
    }

    for _, pv in ipairs(probeVals) do
        local args = APE_DefaultArgs(schema)
        args[axis] = pv.val
        local expectedPass = (dir == "ABOVE_PASS" and pv.val > bnd) or
                             (dir == "BELOW_PASS" and pv.val <= bnd)
        table.insert(plans, {
            kind           = "ValidationCrossCheck",
            args           = args,
            technique      = "ValidationCrossCheck",
            description    = string.format("CrossCheck %s: axis=%d val=%.4g (%s)",
                dir, axis, pv.val, pv.label),
            expectedSignal = expectedPass and "CONFIRMED" or "SILENT",
            crossCheckVal  = pv.val,
            crossCheckAxis = axis,
        })
    end
    return plans
end

-- ─── Technique selector for a given goal ─────────────────────
local function APE_TechsForGoal(goal, remoteName, schema)
    local plans = {}
    if goal == APE.GOAL.CAUSAL then
        local p1 = APE_Techniques.CausalIsolationProbe(remoteName, schema)
        for _, p in ipairs(p1) do table.insert(plans, p) end
    elseif goal == APE.GOAL.VALIDATION then
        local rsm = _G.PC.RSM and _G.PC.RSM.Get(remoteName)
        local hasNum, hasStr = false, false
        for _, a in ipairs(rsm and rsm.ArgSig or {}) do
            if a.DominantType == "number" then hasNum = true end
            if a.DominantType == "string" then hasStr = true end
        end
        -- First check if SBI already has a boundary (cross-check it)
        local sbi = _G.PC.SBI and _G.PC.SBI.Get(remoteName)
        if sbi and sbi.ValidationPattern == "RANGE_CHECK" and sbi.ValidationEvidence.boundary ~= nil then
            for _, p in ipairs(APE_Techniques.ValidationCrossCheck(remoteName, schema)) do
                table.insert(plans, p)
            end
        end
        if hasNum then
            for _, p in ipairs(APE_Techniques.RSMBoundaryRefinement(remoteName, schema)) do
                table.insert(plans, p)
            end
        end
        if hasStr then
            for _, p in ipairs(APE_Techniques.RSMEnumExpansion(remoteName, schema)) do
                table.insert(plans, p)
            end
        end
    elseif goal == APE.GOAL.RATE_PROFILE then
        for _, p in ipairs(APE_Techniques.SpacedRateProbe(remoteName, schema)) do
            table.insert(plans, p)
        end
    elseif goal == APE.GOAL.AC_PROFILE then
        -- Use CausalIsolationProbe with tight timing for AC response measurement
        for _, p in ipairs(APE_Techniques.CausalIsolationProbe(remoteName, schema)) do
            table.insert(plans, p)
        end
    elseif goal == APE.GOAL.CLASSIFY then
        -- CascadeProbe + CausalIsolation to add causal evidence
        for _, p in ipairs(APE_Techniques.CascadeProbe(remoteName, schema)) do
            table.insert(plans, p)
        end
        for _, p in ipairs(APE_Techniques.CausalIsolationProbe(remoteName, schema)) do
            table.insert(plans, p)
        end
    end
    return plans
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 4 — CAMPAIGN MANAGER
-- ═════════════════════════════════════════════════════════════
local APE_Campaign = {}

local function APE_NewCampaign(remoteName, goals, plans)
    local id  = APE_NextID()
    local gs  = {}
    for _, g in ipairs(goals) do gs[g] = APE.STATUS.PENDING end
    return {
        id              = id,
        remoteName      = remoteName,
        goals           = goals,
        goalStatus      = gs,
        plans           = plans,
        planPtr         = 0,
        status          = APE.STATUS.PENDING,
        startT          = os.clock(),
        probesFired     = 0,
        probesSucceeded = 0,
        preConf         = 0.0,   -- SBI conf at campaign start
        lastConf        = 0.0,   -- SBI conf after last probe
    }
end

-- Build a fresh plan list for a remote based on its goals
local function APE_BuildPlans(remoteName, goals)
    local RSM = _G.PC.RSM
    local PR  = _G.PC.PR_Registry

    -- Derive schema from RSM ArgSig or PR ArgSchema
    local rsmRec = RSM and RSM.Get(remoteName)
    local prRec  = PR and PR[remoteName]
    local schema = {}
    if rsmRec and rsmRec.ArgSig then
        for _, a in ipairs(rsmRec.ArgSig) do
            table.insert(schema, {
                DominantType = a.DominantType,
                NumberMean   = a.NumberMean,
                StringSamples= a.SuccessStrings,
            })
        end
    elseif prRec and prRec.ArgSchema then
        schema = prRec.ArgSchema
    end

    local allPlans = {}
    for _, goal in ipairs(goals) do
        local gPlans = APE_TechsForGoal(goal, remoteName, schema)
        for _, p in ipairs(gPlans) do
            table.insert(allPlans, p)
            if #allPlans >= APE_CFG.MaxPlansPerCampaign then break end
        end
        if #allPlans >= APE_CFG.MaxPlansPerCampaign then break end
    end
    return allPlans
end

-- Execute a single plan within a campaign (runs in its own task.spawn)
local function APE_ExecutePlan(campaign, plan)
    local name       = campaign.remoteName
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
    local PR         = _G.PC.PR_Registry
    local prRec      = PR and PR[name]

    -- Pre-delay (throttle + AC gate enforcement)
    local sbiRec = _G.PC.SBI and _G.PC.SBI.Get(name)
    local acDelay = APE_CFG.ACDelay[(sbiRec and sbiRec.ACPattern) or "NONE"] or 0
    local preDelay = math.max(plan.preDelay or 0, acDelay)

    -- Throttle-aware wait
    local lastT = APE_LastFireT[name]
    if lastT and sbiRec and sbiRec.ThrottleFloor then
        local elapsed = os.clock() - lastT
        if elapsed < sbiRec.ThrottleFloor then
            preDelay = math.max(preDelay, sbiRec.ThrottleFloor - elapsed + 0.05)
        end
    end
    if preDelay > 0 then task.wait(preDelay) end

    -- Inject plan into Strategist via AppendPlans, then nudge NextProbe
    if strategist and strategist.AppendPlans then
        -- Ensure target is registered
        if prRec and prRec.Remote and not (strategist.GetTargetStatus()[name]) then
            strategist.AddTarget(name, prRec.Remote, prRec.RemoteType,
                prRec.ArgSchema or {}, prRec.SemanticRole or "UNKNOWN")
        end
        strategist.AppendPlans(name, {plan})

        -- Record pre-probe SBI confidence for saturation tracking
        local preSBIConf = (sbiRec and sbiRec.Confidence) or 0

        -- Nudge Operator
        local operator = _G.PC.AVD and _G.PC.AVD.Operator
        if operator then
            -- Spin-wait for Operator's rate limiter (up to PlanFireTimeout)
            local t0  = os.clock()
            local fired = false
            while os.clock()-t0 < APE_CFG.PlanFireTimeout do
                local probeReq = strategist.NextProbe()
                if probeReq and probeReq.target and probeReq.target.name == name then
                    -- Direct execute via Operator internals isn't exposed,
                    -- so we rely on Operator's own loop picking it up.
                    fired = true; break
                end
                task.wait(0.1)
            end
            APE_LastFireT[name] = os.clock()
            campaign.probesFired = campaign.probesFired + 1
            APE_TotalProbesFired = APE_TotalProbesFired + 1

            -- Post-probe: check SBI confidence delta for saturation
            task.wait(APE_CFG.InterPlanDelay + 0.2)  -- let Translator resolve
            local postSBIRec  = _G.PC.SBI and _G.PC.SBI.Get(name)
            local postConf    = (postSBIRec and postSBIRec.Confidence) or preSBIConf
            local deltaConf   = math.abs(postConf - preSBIConf)
            campaign.lastConf = postConf

            -- Feed saturation detector
            APE_Saturation[name] = APE_Saturation[name] or
                { gains={}, ptr=0, saturated=false }
            local sat = APE_Saturation[name]
            sat.ptr = (sat.ptr % APE_CFG.SatWindowSize) + 1
            sat.gains[sat.ptr] = deltaConf
            if #sat.gains >= APE_CFG.SatWindowSize then
                local sum = 0
                for _, g in ipairs(sat.gains) do sum = sum + g end
                if sum / #sat.gains < APE_CFG.SatThreshold then
                    sat.saturated = true
                end
            end

            -- Handle cascade targets
            if plan.cascadeTargets and fired then
                local cascDelay = (plan.cascadeDelayMs or 200) / 1000
                task.wait(cascDelay)
                for _, ct in ipairs(plan.cascadeTargets) do
                    local cascPR = PR and PR[ct.name]
                    if cascPR and cascPR.Remote then
                        pcall(function()
                            cascPR.Remote:FireServer(table.unpack(ct.args or {}))
                        end)
                    end
                end
            end
        end
    end
end

-- Run a campaign to completion
local function APE_RunCampaign(campaign)
    campaign.status = APE.STATUS.RUNNING
    APE_ActiveCount = APE_ActiveCount + 1

    local sbiRec = _G.PC.SBI and _G.PC.SBI.Get(campaign.remoteName)
    campaign.preConf  = (sbiRec and sbiRec.Confidence) or 0
    campaign.lastConf = campaign.preConf

    local stratStatus = _G.PC.AVD and _G.PC.AVD.Strategist and
        _G.PC.AVD.Strategist.GetTargetStatus() or {}

    -- Ensure target is registered with Strategist
    local PR    = _G.PC.PR_Registry
    local prRec = PR and PR[campaign.remoteName]
    if prRec and prRec.Remote and not stratStatus[campaign.remoteName] then
        local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
        if strategist then
            strategist.AddTarget(campaign.remoteName, prRec.Remote,
                prRec.RemoteType, prRec.ArgSchema or {}, prRec.SemanticRole or "UNKNOWN")
        end
    end

    -- Reset target if previously DONE
    local strategist = _G.PC.AVD and _G.PC.AVD.Strategist
    if strategist and strategist.ResetTarget then
        strategist.ResetTarget(campaign.remoteName)
    end

    -- Execute plans sequentially
    for i, plan in ipairs(campaign.plans) do
        campaign.planPtr = i

        -- Check saturation before each plan
        local sat = APE_Saturation[campaign.remoteName]
        if sat and sat.saturated then
            campaign.status = APE.STATUS.SATURATED
            break
        end

        -- Check AC skip gate
        local latestSBI = _G.PC.SBI and _G.PC.SBI.Get(campaign.remoteName)
        local acSkip = latestSBI and latestSBI.ACPattern == "CORRECTS_FAST"
                       and plan.kind ~= "CausalIsolationProbe"

        if not acSkip then
            -- Execute
            local ok, err = pcall(APE_ExecutePlan, campaign, plan)
            if not ok then
                warn(string.format("[APE] Campaign %d plan %d error: %s",
                    campaign.id, i, tostring(err)))
            end

            -- Inter-plan delay
            task.wait(APE_CFG.InterPlanDelay)
        end
    end

    -- Finalise
    if campaign.status == APE.STATUS.RUNNING then
        local finalSBI = _G.PC.SBI and _G.PC.SBI.Get(campaign.remoteName)
        campaign.lastConf = (finalSBI and finalSBI.Confidence) or campaign.lastConf
        campaign.status   = APE.STATUS.COMPLETE
    end

    APE_ActiveCount = math.max(0, APE_ActiveCount - 1)

    -- Trigger SBI rebuild to ensure all attributions are finalised
    if _G.PC.SBI then pcall(_G.PC.SBI.Rebuild) end
end

function APE_Campaign.Launch(remoteName)
    -- Don't launch if already running a campaign for this remote
    for _, c in pairs(APE_Campaigns) do
        if c.remoteName == remoteName and
           (c.status == APE.STATUS.RUNNING or c.status == APE.STATUS.PENDING) then
            return nil, "already active"
        end
    end

    -- Goal planning
    local goals = APE_GoalPlanner.PlanGoals(remoteName)
    if #goals == 0 then return nil, "no goals" end

    -- Plan generation
    local plans = APE_BuildPlans(remoteName, goals)
    if #plans == 0 then return nil, "no plans generated" end

    local campaign = APE_NewCampaign(remoteName, goals, plans)
    APE_Campaigns[campaign.id] = campaign
    APE_TotalCampaigns = APE_TotalCampaigns + 1

    task.spawn(function() pcall(APE_RunCampaign, campaign) end)
    return campaign.id
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 5 — SATURATION DETECTOR (state managed in Campaign)
-- ═════════════════════════════════════════════════════════════

function APE.GetSaturation(remoteName)
    local sat = APE_Saturation[remoteName]
    if not sat then return { saturated=false, avgGain=nil, samples=0 } end
    local sum, n = 0, 0
    for _, g in ipairs(sat.gains) do sum = sum + g; n = n + 1 end
    return {
        saturated = sat.saturated,
        avgGain   = n > 0 and sum/n or nil,
        samples   = n,
    }
end

-- ═════════════════════════════════════════════════════════════
-- MODULE 6 — THROTTLE-AWARE SCHEDULER (inline in ExecutePlan)
-- ═════════════════════════════════════════════════════════════
-- (Implemented inline in APE_ExecutePlan above via APE_LastFireT + SBI.ThrottleFloor)

-- ═════════════════════════════════════════════════════════════
-- MODULE 7 — AC-AWARE GATE (inline in ExecutePlan + RunCampaign)
-- ═════════════════════════════════════════════════════════════
-- (Implemented inline in APE_RunCampaign and APE_ExecutePlan above)

-- ═════════════════════════════════════════════════════════════
-- PERSISTENCE
-- ═════════════════════════════════════════════════════════════
local function APE_Serialize()
    local sat = {}
    for name, s in pairs(APE_Saturation) do
        sat[name] = { gains=s.gains, ptr=s.ptr, saturated=s.saturated }
    end
    return {
        PersistVer        = APE_CFG.PersistVer,
        Saturation        = sat,
        TotalCampaigns    = APE_TotalCampaigns,
        TotalProbesFired  = APE_TotalProbesFired,
    }
end

local function APE_Deserialize(data)
    if data.PersistVer ~= APE_CFG.PersistVer then return end
    for name, s in pairs(data.Saturation or {}) do
        APE_Saturation[name] = { gains=s.gains or {}, ptr=s.ptr or 0, saturated=s.saturated or false }
    end
    APE_TotalCampaigns   = data.TotalCampaigns  or 0
    APE_TotalProbesFired = data.TotalProbesFired or 0
end

function APE.Save()
    if not APE_CFG.PersistEnabled then return end
    pcall(function() _G[APE_CFG.PersistKey] = APE_Serialize() end)
end

function APE.Load()
    pcall(function()
        local d = _G[APE_CFG.PersistKey]
        if type(d) == "table" then APE_Deserialize(d) end
    end)
end

-- ═════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════

-- Launch a targeted campaign for a specific remote
function APE.StartCampaign(remoteName)
    if not APE_Running then return nil, "APE not running" end
    if APE_ActiveCount >= APE_CFG.MaxConcurrentCampaigns then
        return nil, "max concurrent campaigns"
    end
    return APE_Campaign.Launch(remoteName)
end

-- Re-score all remotes, launch campaigns for top-N
function APE.Scan()
    if not APE_Running then return 0 end
    local ranked  = APE_Scorer.GetRanked(0.05)
    local launched = 0
    for _, entry in ipairs(ranked) do
        if APE_ActiveCount >= APE_CFG.MaxConcurrentCampaigns then break end
        if launched >= APE_CFG.ScanBatchSize then break end
        local id, err = APE_Campaign.Launch(entry.name)
        if id then launched = launched + 1 end
    end
    return launched
end

-- Priority queue
function APE.GetQueue(minScore)
    return APE_Scorer.GetRanked(minScore or 0.02)
end

-- All campaigns
function APE.GetCampaigns()
    local out = {}
    for _, c in pairs(APE_Campaigns) do
        table.insert(out, {
            id              = c.id,
            remoteName      = c.remoteName,
            status          = c.status,
            goals           = c.goals,
            goalStatus      = c.goalStatus,
            planCount       = #c.plans,
            planPtr         = c.planPtr,
            probesFired     = c.probesFired,
            probesSucceeded = c.probesSucceeded,
            startT          = c.startT,
            preConf         = c.preConf,
            lastConf        = c.lastConf,
            confGain        = c.lastConf - c.preConf,
        })
    end
    table.sort(out, function(a,b) return a.id > b.id end)
    return out
end

function APE.Score(remoteName) return APE_Scorer.Score(remoteName) end

function APE.GetStats()
    return {
        Running           = APE_Running,
        ActiveCampaigns   = APE_ActiveCount,
        TotalCampaigns    = APE_TotalCampaigns,
        TotalProbesFired  = APE_TotalProbesFired,
        QueueDepth        = #APE_Scorer.GetRanked(0.02),
        SaturatedRemotes  = (function()
            local n = 0
            for _, s in pairs(APE_Saturation) do if s.saturated then n=n+1 end end
            return n
        end)(),
    }
end

function APE.Stop()
    APE_Running = false
    print("[APE] Stopped.")
end

function APE.Resume()
    APE_Running = true
    print("[APE] Resumed.")
end

-- Expose internals for UI
APE.Scorer      = APE_Scorer
APE.GoalPlanner = APE_GoalPlanner
APE.Techniques  = APE_Techniques

-- ═════════════════════════════════════════════════════════════
-- STARTUP
-- ═════════════════════════════════════════════════════════════
task.spawn(function()
    local function waitFor(getter, label, timeout)
        local t0 = os.clock()
        while not getter() do
            if os.clock()-t0 > timeout then
                warn("[APE] Timeout waiting for "..label); return false
            end
            task.wait(0.5)
        end
        return true
    end

    waitFor(function() return _G.PC.SBI end,                            "SBI",        35)
    waitFor(function() return _G.PC.RSM end,                            "RSM",        30)
    waitFor(function() return _G.PC.SR end,                             "SR",         30)
    waitFor(function() return _G.PC.AVD and _G.PC.AVD.Strategist end,  "Strategist", 25)
    waitFor(function() return _G.PC.AVD and _G.PC.AVD.Operator end,    "Operator",   25)

    -- Verify the strategist patch landed
    local strat = _G.PC.AVD.Strategist
    if not strat.AppendPlans then
        warn("[APE] Strategist.AppendPlans not found — patch may not have loaded.")
    end

    APE.Load()
    APE_Running = true
    print("[APE] Active Probing Engine ready.")

    -- Initial scan after everything settles
    task.wait(5.0)
    local n = APE.Scan()
    print(string.format("[APE] Initial scan: launched %d campaign(s).", n))

    -- ── NHPP scan cadence ──────────────────────────────────────────────────
    -- Non-Homogeneous Poisson Process: scan rate tracks real player activity
    -- via LWM firesDelta + physDelta. When the player is idle the probe rate
    -- drops to near-zero. When they are active, probes hide in the noise.
    --
    -- lam(t) = lam_base + lam_activity * activity_signal          (scans per second)
    -- wait  = -ln(U) / lam(t)    clamped to [APE_CFG.NHPPMinWait, NHPPMaxWait]
    task.spawn(function()
        -- NHPP parameters (tunable via APE_CFG)
        local lam_base     = 1.0 / 180.0   -- one scan per 3 min at idle
        local lam_activity = 1.0 / 30.0    -- up to one scan per 30 s at peak activity
        local minWait    = APE_CFG.NHPPMinWait or 12.0
        local maxWait    = APE_CFG.NHPPMaxWait or 300.0

        while true do
            -- Sample activity signal from LWM
            local LWM    = _G.PC and _G.PC.LWM
            local delta  = LWM and LWM.GetDelta()
            local fires  = math.abs(delta and delta.firesDelta or 0)
            local phys   = math.abs(delta and delta.physDelta  or 0)
            -- Normalize: fires saturates at 30, phys at 10
            local actSig = math.clamp(fires/30.0, 0, 1) * 0.7
                         + math.clamp(phys /10.0, 0, 1) * 0.3

            local lambda = lam_base + lam_activity * actSig
            -- Poisson inter-arrival: exponential with rate λ
            local u      = math.max(1e-10, math.random())
            local wait   = math.clamp(-math.log(u) / lambda, minWait, maxWait)

            -- Add small Gamma jitter (shape=2, scale=1s) to prevent fixed-period fingerprint
            local g1 = -math.log(math.max(1e-10, math.random()))
            local g2 = -math.log(math.max(1e-10, math.random()))
            wait = wait + (g1 + g2) * 0.5   -- Gamma(2,1) mean=1s jitter

            task.wait(wait)
            if APE_Running then
                pcall(APE.Scan)
                pcall(APE.Save)
            end
        end
    end)
end)

-- ── Export ────────────────────────────────────────────────────
_G.PC.APE = APE
print("[APE] Module registered.")
