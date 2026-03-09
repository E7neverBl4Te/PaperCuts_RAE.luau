-- ============================================================
--   Paper & Clay + RAE v2 + SARP v4 + PR v5 — Loader
--   Fetches each chunk from the private repo and runs it.
--   Each chunk has its own fresh register budget.
-- ============================================================

local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/PaperCuts_RAE.luau/refs/heads/PaperTree/"
local HttpService = game:GetService("HttpService")

local chunks = {
    "core.lua",      -- services, helpers, LWM/ETM/CDG, RAE backend
    "ui_base.lua",   -- GUI scaffold, page declarations
    "ui_pages.lua",  -- page builders: Overview → About
    "forge.lua",     -- Forge backend + UI
    "sarp.lua",      -- SARP v4 engine
    "pr.lua",        -- PR v5 module (protocol reconstruction)
    "pr_ui.lua",     -- PR UI tab
    "avd_sentry.lua",     -- AVD: independent observer
    "avd_translator.lua", -- AVD: data normalization
    "avd_strategist.lua", -- AVD: intelligence & generation
    "avd_operator.lua",   -- AVD: execution & lifecycle
    "avd_ui.lua",         -- AVD: dashboard UI
    "rsm.lua",             -- RSM: Remote Signature Mapping engine
    "rsm_ui.lua",          -- RSM: dashboard UI
    "sr.lua",              -- SR: State Reconstruction engine
    "sr_ui.lua",           -- SR: dashboard UI
    "sbi.lua",             -- SBI: Server Behavior Inference engine
    "sbi_ui.lua",          -- SBI: dashboard UI
    "ape.lua",             -- APE: Active Probing Engine
    "ape_ui.lua",          -- APE: dashboard UI
    "csk.lua",             -- CSK: Cross-Session Knowledge engine
    "csk_ui.lua",          -- CSK: dashboard UI
    "ase.lua",             -- ASE: Autonomous Strategy Engine
    "ase_ui.lua",
    "shadow_binder.lua",          -- ASE: Script Execution Panel
    "tsr_registry.lua",   -- TSR: 100-intent library + binding table
    "tsr_binder.lua",     -- TSR: verification + binding engine
    "tsr_runtime.lua",    -- TSR: transaction manager + sovereign API
    "tsr_ui.lua",         -- TSR: dashboard
    "boot.lua",      -- navigation, drag, global API, bootRAE
}

for _, file in ipairs(chunks) do
    local ok, err = pcall(function()
        local code = game:HttpGet(BASE .. file)
        local fn, loadErr = loadstring(code)
        if not fn then
            error("Syntax error in " .. file .. ": " .. tostring(loadErr))
        end
        fn()
    end)
    if not ok then
        warn("[PaperCuts Loader] FAILED: " .. file)
        warn(tostring(err))
    else
        print("[PaperCuts Loader] OK: " .. file)
    end
end

print("[PaperCuts Loader] All chunks loaded.")
