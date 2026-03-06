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
    "sarp_ui.lua",   -- SARP UI tab
    "pr.lua",        -- PR v5 module (protocol reconstruction)
    "pr_ui.lua",     -- PR UI tab
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
