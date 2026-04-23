-- ============================================================
-- ui_pages_ext.lua
-- Extended page declarations for modules that read from _G.PCU
-- but whose pages couldn't be created in ui_base.lua due to
-- the Lua 5.1 200-local-variable limit.
--
-- Runs immediately after ui_base.lua so all _U.pageXXX reads
-- in the module UI files resolve correctly.
--
-- Modules covered:
--   CSK  — Cross-Session Knowledge
--   SR   — State Reconstruction
--   RSM  — Remote Signature Mapping
--   SBI  — Server Behavior Inference
--   APE  — Active Probing Engine
--   ASE  — Autonomous Strategy Engine
-- ============================================================

local PC       = _G.PC
local PCU      = _G.PCU
if not PC or not PC.makePage then
    warn("[ui_pages_ext] PC.makePage not available — skipping")
    return
end

local makePage = PC.makePage

-- Create each page and export to both PC and PCU so files
-- using either _C.pageXXX or _U.pageXXX can find them.
local pageCSK = makePage("CSK")
local pageSR  = makePage("SR")
local pageRSM = makePage("RSM")
local pageSBI = makePage("SBI")
local pageAPE = makePage("APE")
local pageASE = makePage("ASE")

-- Export to PC
PC.pageCSK = pageCSK
PC.pageSR  = pageSR
PC.pageRSM = pageRSM
PC.pageSBI = pageSBI
PC.pageAPE = pageAPE
PC.pageASE = pageASE

-- Export to PCU (alias — same table as PC since _G.PCU = PC)
-- Explicit assignment in case any file captured PCU before
-- the alias was set.
if PCU then
    PCU.pageCSK = pageCSK
    PCU.pageSR  = pageSR
    PCU.pageRSM = pageRSM
    PCU.pageSBI = pageSBI
    PCU.pageAPE = pageAPE
    PCU.pageASE = pageASE
end

print("[PaperCuts] ui_pages_ext.lua: 6 extended pages ready")
