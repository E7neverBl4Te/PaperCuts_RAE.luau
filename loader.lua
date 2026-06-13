-- ══════════════════════════════════════════════════════════════════════════════
--   PaperCuts RAE — Full Framework Loader
--   34-module stack + BCS + BGH + TRCR
-- ══════════════════════════════════════════════════════════════════════════════

local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/PaperCuts_RAE.luau/refs/heads/PaperTree/"

local chunks = {
    -- ── Core ──────────────────────────────────────────────────────────────
    "core.lua",             -- services, helpers, global API
    "ui_base.lua",          -- GUI scaffold, page system, nav
    "ui_pages.lua",         -- Overview, About, base pages

    -- ── SARP / PR ─────────────────────────────────────────────────────────
    "forge.lua",            -- payload forge utilities
    "sarp.lua",             -- SARP: Server-side Anomaly Response Profiler
    "pr.lua",               -- PR: Persistence & Reconnect engine
    "pr_ui.lua",            -- PR: UI (self-registering)

    -- ── AVD Stack ─────────────────────────────────────────────────────────
    "avd_sentry.lua",       -- AVD: Sentry (anomaly detection)
    "avd_translator.lua",   -- AVD: Translator (payload normalization)
    "avd_strategist.lua",   -- AVD: Strategist (response planning)
    "avd_operator.lua",     -- AVD: Operator (execution coordinator)
    "avd_ui.lua",           -- AVD: UI (self-registering)

    -- ── RSM / SR / SBI ────────────────────────────────────────────────────
    "rsm.lua",              -- RSM: Remote Session Monitor
    "rsm_ui.lua",           -- RSM: UI (self-registering)
    "sr.lua",               -- SR: Session Recorder
    "sr_ui.lua",            -- SR: UI (self-registering)
    "sbi.lua",              -- SBI: Server Behavior Intelligence
    "sbi_ui.lua",           -- SBI: UI (self-registering)

    -- ── APE / CSK ─────────────────────────────────────────────────────────
    "ape.lua",              -- APE: Adaptive Probe Engine
    "ape_ui.lua",           -- APE: UI (self-registering)
    "csk.lua",              -- CSK: Cryptographic Session Keying
    "csk_ui.lua",           -- CSK: UI (self-registering)

    -- ── ASE / AACG ────────────────────────────────────────────────────────
    "ase.lua",              -- ASE: Adaptive Sink Establisher (Bedrock handshake)
    "aacg.lua",             -- AACG: Adaptive Augmented Chain Generator
    "ase_ui.lua",           -- ASE: UI (self-registering)

    -- ── Shadow Binder / TSR ───────────────────────────────────────────────
    "shadow_binder.lua",    -- Shadow Binder: covert event relay
    "tsr_registry.lua",     -- TSR: Type Signature Registry
    "tsr_binder.lua",       -- TSR: Binder
    "tsr_runtime.lua",      -- TSR: Runtime executor
    "tsr_ui.lua",           -- TSR: UI (self-registering)

    -- ── STS ───────────────────────────────────────────────────────────────
    "sts.lua",              -- STS: Server Topology Scanner
    "sts_ui.lua",           -- STS: UI (self-registering)

    -- ── BRE ───────────────────────────────────────────────────────────────
    "bre.lua",              -- BRE: BedRock Execution Engine (Layer 5)
    "bre_ui.lua",           -- BRE: UI (self-registering)

    -- ── BGH ───────────────────────────────────────────────────────────────
    "bre_gadget_hunt.lua",  -- BGH: Binary .text gadget scanner (Layer 4 BRCE)
    "bre_gadget_hunt_ui.lua", -- BGH: UI (self-registering)

    -- ── BCS ───────────────────────────────────────────────────────────────
    "bre_cold_sync.lua",    -- BCS: Cold-Boot Re-Sync engine (guard page recovery)
    "bre_cold_sync_ui.lua", -- BCS: UI (self-registering)

    -- ── Source-to-Sink Tracer ─────────────────────────────────────────────
    "sts_tracer.lua",       -- TRCR: Source-to-Sink chain tracer engine
    "sts_tracer_ui.lua",    -- TRCR: S2S tracer UI (self-registering)

    -- ── Boot ──────────────────────────────────────────────────────────────
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

print("[PaperCuts Loader] Full RAE stack loaded.")
