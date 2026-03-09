-- shadow_binder.lua
-- SHADOW BINDER - Phase 1 of Sovereign Runtime
-- Silently locks CDG causal edges into TSR without exposing any UI.
-- StealthConfidence >= PanelRevealThreshold gates Phase 3 Panel reveal.

local ShadowBinder = {}

local SB_CFG = {
    CycleInterval        = 45.0,
    MinCDGConfidence     = 0.35,
    MinSBIConfidence     = 0.45,
    MaxBindsPerCycle     = 4,
    PanelRevealThreshold = 0.75,
    CDGWeight            = 0.40,
    TSRWeight            = 0.35,
    SBIWeight            = 0.25,
}

local SB_Running        = false
local SB_Cycle          = 0
local SB_TotalAttempts  = 0
local SB_TotalSucceeded = 0
local SB_PromotedEdges  = {}
local SB_StealthScore   = 0.0
local SB_PanelReady     = false
local SB_BrierSum       = 0.0
local SB_BrierCount     = 0

local function SB_Log(fmt, ...)
    print(string.format("[Shadow Binder] " .. fmt, ...))
end

local function SB_ComputeStealthScore()
    local CDG   = _G.PC and _G.PC.CDG
    local SBI   = _G.PC and _G.PC.SBI

    local cdgScore = 0.0
    if CDG then
        local edges = CDG.GetStrongEdges(SB_CFG.MinCDGConfidence)
        if #edges > 0 then
            local sum = 0
            for _, e in ipairs(edges) do sum = sum + e.Confidence end
            cdgScore = math.min(1.0, sum / #edges)
        end
    end

    local tsrScore = SB_TotalAttempts > 0
        and (SB_TotalSucceeded / SB_TotalAttempts) or 0.0

    local promoted, backed = 0, 0
    for _, rec in pairs(SB_PromotedEdges) do
        promoted = promoted + 1
        if SBI then
            local sbiRec = SBI.Get(rec.edge.ToID)
            if sbiRec and (sbiRec.Confidence or 0) >= SB_CFG.MinSBIConfidence then
                backed = backed + 1
            end
        end
    end
    local sbiScore = promoted > 0 and (backed / promoted) or 0.0

    local score = cdgScore * SB_CFG.CDGWeight
                + tsrScore * SB_CFG.TSRWeight
                + sbiScore * SB_CFG.SBIWeight

    if SB_BrierCount > 0 then
        local brierMean = SB_BrierSum / SB_BrierCount
        score = score * (1.0 - math.max(0, brierMean - 0.15) * 0.5)
    end

    return math.clamp(score, 0.0, 1.0)
end

local function SB_RunCycle()
    SB_Cycle = SB_Cycle + 1
    local CDG    = _G.PC and _G.PC.CDG
    local SBI    = _G.PC and _G.PC.SBI
    local Binder = _G.PC and _G.PC.TSR_Binder

    if not CDG or not Binder then return end

    local edges = CDG.GetStrongEdges(SB_CFG.MinCDGConfidence)
    if #edges == 0 then return end

    table.sort(edges, function(a, b)
        return (a.Confidence * (a.EffectSize or 1)) > (b.Confidence * (b.EffectSize or 1))
    end)

    local bound = 0
    for _, edge in ipairs(edges) do
        if bound >= SB_CFG.MaxBindsPerCycle then break end

        local key      = edge.FromID .. "->" .. edge.ToID
        local promoted = SB_PromotedEdges[key] ~= nil

        if not promoted then
            local sbiOk = false
            if SBI then
                local sbiRec = SBI.Get(edge.ToID)
                sbiOk = sbiRec and (sbiRec.Confidence or 0) >= SB_CFG.MinSBIConfidence
            end

            if sbiOk or (edge.Confidence >= 0.65) then
                local predicted = edge.Confidence
                SB_TotalAttempts = SB_TotalAttempts + 1

                local ok = pcall(function()
                    Binder.BindIntent(edge.ToID)
                end)

                local outcome = ok and 1 or 0
                if ok then SB_TotalSucceeded = SB_TotalSucceeded + 1 end

                SB_BrierSum   = SB_BrierSum + (predicted - outcome)^2
                SB_BrierCount = SB_BrierCount + 1

                SB_PromotedEdges[key] = {
                    edge       = edge,
                    promotedAt = os.clock(),
                    bindResult = ok,
                    predicted  = predicted,
                    outcome    = outcome,
                }

                if ok then
                    SB_Log("Bound %s -> %s (conf=%.2f)", edge.FromID, edge.ToID, edge.Confidence)
                    bound = bound + 1
                else
                    SB_Log("Bind failed: %s -> %s", edge.FromID, edge.ToID)
                end
            end
        end
    end

    SB_StealthScore = SB_ComputeStealthScore()

    if not SB_PanelReady and SB_StealthScore >= SB_CFG.PanelRevealThreshold then
        SB_PanelReady = true
        SB_Log("StealthConfidence %.0f%% >= threshold -- Panel gate OPEN.", SB_StealthScore * 100)
        local ASE = _G.PC and _G.PC.ASE
        if ASE then
            ASE.Panel.StealthReady = true
        end
    end

    if bound > 0 then
        SB_Log("Cycle %d: %d bound. Stealth=%.0f%% Brier=%.3f",
            SB_Cycle, bound, SB_StealthScore * 100,
            SB_BrierCount > 0 and SB_BrierSum / SB_BrierCount or 0)
    end
end

function ShadowBinder.Start()
    if SB_Running then return end
    SB_Running = true
    SB_Log("Started. PanelRevealThreshold=%.0f%% CycleInterval=%ds",
        SB_CFG.PanelRevealThreshold * 100, SB_CFG.CycleInterval)

    task.spawn(function()
        local t0 = os.clock()
        while os.clock() - t0 < 60 do
            local ready = _G.PC and _G.PC.CDG and _G.PC.SBI and _G.PC.TSR_Binder
            if ready then break end
            task.wait(2.0)
        end
        task.wait(8.0)
        SB_RunCycle()

        while SB_Running do
            local jitter = (math.random() - 0.5) * SB_CFG.CycleInterval * 0.40
            task.wait(SB_CFG.CycleInterval + jitter)
            if SB_Running then pcall(SB_RunCycle) end
        end
    end)
end

function ShadowBinder.Stop()
    SB_Running = false
end

function ShadowBinder.GetStealthScore()
    return SB_StealthScore
end

function ShadowBinder.IsPanelReady()
    return SB_PanelReady
end

function ShadowBinder.GetStats()
    local promoted = 0
    for _ in pairs(SB_PromotedEdges) do promoted = promoted + 1 end
    return {
        Running        = SB_Running,
        Cycle          = SB_Cycle,
        TotalAttempts  = SB_TotalAttempts,
        TotalSucceeded = SB_TotalSucceeded,
        PromotedEdges  = promoted,
        StealthScore   = SB_StealthScore,
        PanelReady     = SB_PanelReady,
        BrierMean      = SB_BrierCount > 0 and (SB_BrierSum / SB_BrierCount) or 0,
    }
end

function ShadowBinder.GetPromotedEdges()
    local out = {}
    for _, rec in pairs(SB_PromotedEdges) do table.insert(out, rec) end
    table.sort(out, function(a, b) return a.promotedAt > b.promotedAt end)
    return out
end

function ShadowBinder.ForceReveal()
    SB_PanelReady = true
    local ASE = _G.PC and _G.PC.ASE
    if ASE then ASE.Panel.StealthReady = true end
    SB_Log("Panel gate forced open by operator.")
end

_G.PC.ShadowBinder = ShadowBinder
print("[Shadow Binder] Module registered.")

task.delay(6.0, function()
    pcall(ShadowBinder.Start)
end)
