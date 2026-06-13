-- ============================================================
--   PaperCuts — Design Shell Loader
--   Framework only: core, UI scaffold, pages, boot.
-- ============================================================

local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/PaperCuts_RAE.luau/refs/heads/PaperTree/"

local chunks = {
    "core.lua",      -- services, helpers, global API
    "ui_base.lua",   -- GUI scaffold, page system, nav
    "ui_pages.lua",  -- Overview, About, base pages
    "sts_tracer.lua",    -- TRCR: Source-to-Sink chain tracer engine
    "sts_tracer_ui.lua", -- TRCR: S2S tracer interface (self-registering)
    "boot.lua",      -- navigation, drag, bootRAE
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

print("[PaperCuts Loader] Shell loaded.")
