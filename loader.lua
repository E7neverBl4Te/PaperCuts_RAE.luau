-- ============================================================
--   PaperCuts — Full Loader
--   Fetches each chunk from the private repo and runs it.
--   Each chunk has its own fresh register budget.
-- ============================================================

local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/PaperCuts_RAE.luau/refs/heads/PaperTree/"
local HttpService = game:GetService("HttpService")

local chunks = {
    -- ── Core foundation ───────────────────────────────────────
    "core.lua",             -- services, helpers, LWM/ETM/CDG, RAE backend
    "ui_base.lua",          -- GUI scaffold, page declarations, PCU alias

    -- ── Page content ─────────────────────────────────────────
    "ui_pages_ext.lua",     -- Extended page declarations (CSK/SR/RSM/SBI/APE/ASE)
    "ui_pages.lua",         -- Overview → About page builders

    -- ── Standalone backends ───────────────────────────────────
    "aacg.lua",             -- AACG module
    "shadow_binder.lua",    -- Shadow binding layer
    "c2_implant.lua",       -- C2 implant module

    -- ── Forge ────────────────────────────────────────────────
    "forge.lua",            -- Forge backend + UI

    -- ── SARP ─────────────────────────────────────────────────
    "sarp.lua",             -- SARP v4 engine

    -- ── PR (Protocol Reconstruction) ─────────────────────────
    "pr.lua",               -- PR v5 module
    "pr_ui.lua",
    "cscp.lua",           -- CSCP: Packet Crafter (PR Bridge sub-section)            -- PR UI tab

    -- ── BRE (Breach / Recon Engine) ──────────────────────────
    "bre.lua",              -- BRE core engine
    "bre_cold_sync.lua",    -- BRE: cold sync module
    "bre_gadget_hunt.lua",  -- BRE: gadget hunt module
    "bre_ui.lua",           -- BRE: main dashboard UI
    "bre_cold_sync_ui.lua", -- BRE: cold sync UI
    "bre_gadget_hunt_ui.lua",-- BRE: gadget hunt UI

    -- ── CSK ──────────────────────────────────────────────────
    "csk.lua",              -- CSK backend
    "csk_ui.lua",           -- CSK UI

    -- ── SR (Script Recon) ─────────────────────────────────────
    "sr.lua",               -- SR backend
    "sr_ui.lua",            -- SR UI

    -- ── RSM (Remote State Monitor) ────────────────────────────
    "rsm.lua",              -- RSM backend
    "rsm_ui.lua",           -- RSM UI

    -- ── SBI ──────────────────────────────────────────────────
    "sbi.lua",              -- SBI backend
    "sbi_ui.lua",           -- SBI UI

    -- ── STS ──────────────────────────────────────────────────
    "sts.lua",              -- STS backend
    "sts_ui.lua",           -- STS UI

    -- ── APE ──────────────────────────────────────────────────
    "ape.lua",              -- APE backend
    "ape_ui.lua",           -- APE UI

    -- ── AVD (Autonomous Vulnerability Debugger) ───────────────
    "avd_sentry.lua",       -- AVD: independent observer
    "avd_translator.lua",   -- AVD: data normalisation
    "avd_strategist.lua",   -- AVD: intelligence & generation
    "avd_operator.lua",     -- AVD: execution & lifecycle
    "avd_ui.lua",           -- AVD: dashboard UI

    -- ── TSR (The Sovereign Runtime) ───────────────────────────
    "tsr_registry.lua",     -- TSR: 100-intent library + binding table
    "tsr_binder.lua",       -- TSR: verification + binding engine
    "tsr_runtime.lua",      -- TSR: transaction manager + sovereign API
    "tsr_ui.lua",           -- TSR: dashboard

    -- ── ASE Sovereign ────────────────────────────────────────
    "ase_sovereign.lua",    -- ASE sovereign backend
    "ase_sovereign_ui.lua", -- ASE sovereign UI
    "ase_ui.lua",           -- ASE UI

    -- ── GSE (Game Service Edit) ───────────────────────────────
    "gse.lua",              -- GSE core: MarketplaceService + sub-tab system
    "bse.lua",              -- BadgeService
    "dse.lua",              -- DataStoreService
    "mse.lua",              -- MessagingService
    "ase.lua",              -- AnalyticsService

    -- ── Boot (always last) ────────────────────────────────────
    "boot.lua",             -- navigation, drag, global API, bootRAE
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
