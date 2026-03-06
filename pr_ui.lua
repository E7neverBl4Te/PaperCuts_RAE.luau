-- ── Imports ─────────────────────────────────────────────────────────────────
local _C = _G.PC
local _U = _G.PCU
local mk             = _C.mk
local addCorner      = _C.addCorner
local addStroke      = _C.addStroke
local pulseClick     = _C.pulseClick
local clickSound     = _C.clickSound
local sendNotification = _U.sendNotification
local makeButton     = _U.makeButton
local makeSection    = _U.makeSection
local makeToggle     = _U.makeToggle
local pagePR         = _U.pagePR
local PR_CFG              = _C.PR_CFG
local PR_Registry         = _C.PR_Registry
local PR_SchemaInfer      = _C.PR_SchemaInfer
local PR_DepGraph         = _C.PR_DepGraph
local PR_ManifestBuilder  = _C.PR_ManifestBuilder
local PR_Bridge           = _C.PR_Bridge
local PR_Analytics        = _C.PR_Analytics
local PR_Classifier       = _C.PR_Classifier
local PR_AnomalyDetector  = _C.PR_AnomalyDetector
local PR_EchoCalibrator   = _C.PR_EchoCalibrator
local PR_ProtocolFingerprint = _C.PR_ProtocolFingerprint
local PR_PFP              = _C.PR_PFP
local window              = _G.PCU.window

-- ============================================================
-- PAGE: PR — Protocol Reconstruction
-- ============================================================
do
    local function mkL(parent, text, size, color)
        return mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamMedium,
            Text=text,TextColor3=color or Color3.fromRGB(70,70,90),TextSize=size or 11,
            TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,size and size*2.5 or 28),Parent=parent})
    end
    local _, sHdr = makeSection(pagePR, "PR — Protocol Reconstruction")
    mkL(sHdr,"Passive + active protocol layer. Intercepts remotes, classifies by role and frequency, detects AC anomalies, and feeds calibrated echo-window estimates into SARP.",12,Color3.fromRGB(60,80,120))
    local prFPLabel  = mkL(sHdr,"Fingerprint: initializing...",11,Color3.fromRGB(80,100,160))
    prFPLabel.Size   = UDim2.new(1,0,0,16)
    local prStatLabel = mkL(sHdr,"Remotes: 0",11,Color3.fromRGB(70,70,90))
    prStatLabel.Size  = UDim2.new(1,0,0,16)

    -- Echo Calibrator
    local _, sCalib = makeSection(pagePR, "Echo Calibrator")
    local calibLabel = mkL(sCalib,"Waiting for PERIODIC S2C remote...",11,Color3.fromRGB(70,110,80))
    calibLabel.Size  = UDim2.new(1,0,0,48)
    local calibRow   = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,34),Parent=sCalib})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=calibRow})
    local calibForceBtn = makeButton(calibRow,"Force Calibrate",UDim2.new(0,170,0,30),"")
    calibForceBtn.Button.BackgroundColor3 = Color3.fromRGB(220,240,210)
    local calibPushBtn  = makeButton(calibRow,"Push to SARP",UDim2.new(0,150,0,30),"")
    calibPushBtn.Button.BackgroundColor3  = Color3.fromRGB(200,220,240)
    calibForceBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(calibForceBtn.Button)
        local best = PR_EchoCalibrator.SelectBest()
        if best then
            local ok = PR_EchoCalibrator.Attach(best)
            sendNotification(ok and ("Calibrator: "..best.Name) or "No eligible remote.", ok and "Info" or "Warning")
        else sendNotification("No PERIODIC S2C remote available.", "Warning") end
    end)
    calibPushBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(calibPushBtn.Button)
        local refined = PR_Bridge.CalibrateSARP()
        if refined then sendNotification(string.format("Echo window: %.4fs", refined), "Success")
        else sendNotification("Need more samples.", "Warning") end
    end)

    -- Anomaly Detector
    local _, sAnomaly = makeSection(pagePR, "Anomaly Detector")
    local acBadge = mk("TextLabel",{Text="AC STATUS: UNKNOWN",Font=Enum.Font.GothamBold,TextSize=11,
        TextColor3=Color3.fromRGB(255,255,255),BackgroundColor3=Color3.fromRGB(120,120,120),
        Size=UDim2.new(1,0,0,26),TextXAlignment=Enum.TextXAlignment.Center,Parent=sAnomaly})
    addCorner(acBadge,UDim.new(0,6))
    local anomalyScroll = mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(248,244,240),
        Size=UDim2.new(1,0,0,140),CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sAnomaly})
    addCorner(anomalyScroll,UDim.new(0,6)); addStroke(anomalyScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=anomalyScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=anomalyScroll})
    local anomCtrlRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,30),Parent=sAnomaly})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),Parent=anomCtrlRow})
    local anomRefreshBtn = makeButton(anomCtrlRow,"Refresh",UDim2.new(0,110,0,28),"")
    anomRefreshBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)
    local anomSweepBtn   = makeButton(anomCtrlRow,"Force Sweep",UDim2.new(0,130,0,28),"")
    anomSweepBtn.Button.BackgroundColor3   = Color3.fromRGB(255,240,210)

    local function refreshAnomalies()
        for _, ch in ipairs(anomalyScroll:GetChildren()) do
            if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
        end
        local events = PR_AnomalyDetector.GetRecentEvents(15)
        for i = #events, 1, -1 do
            local e = events[i]
            local row = mk("Frame",{BackgroundColor3=Color3.fromRGB(255,244,238),
                Size=UDim2.new(1,0,0,34),Parent=anomalyScroll})
            addCorner(row,UDim.new(0,4))
            local desc = e.kind=="RATE_SPIKE" and string.format("SPIKE z=%.1f (%.2f->%.2fHz)",e.zScore,e.baselineHz or 0,e.currentHz or 0)
                      or e.kind=="SILENCE"    and string.format("SILENCE %.0fs",e.silenceSec or 0)
                      or e.kind
            mk("TextLabel",{Text=string.format("[%s] %s — %s",e.role,e.name:sub(1,24),desc),
                Font=Enum.Font.GothamBold,TextSize=10,TextColor3=Color3.fromRGB(50,40,40),
                Position=UDim2.new(0,6,0,4),Size=UDim2.new(1,-80,0,14),
                TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
            mk("TextLabel",{Text=string.format("%.0fs ago",os.clock()-e.t),
                Font=Enum.Font.Code,TextSize=9,TextColor3=Color3.fromRGB(130,120,120),
                Position=UDim2.new(1,-72,0,6),Size=UDim2.new(0,66,0,12),
                TextXAlignment=Enum.TextXAlignment.Right,BackgroundTransparency=1,Parent=row})
        end
        if #events == 0 then
            mk("TextLabel",{Text="No anomalies.",BackgroundTransparency=1,
                Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=Color3.fromRGB(140,140,140),
                Size=UDim2.new(1,0,0,22),Parent=anomalyScroll})
        end
        local acFlag = PR_AnomalyDetector.HasACPattern()
        if acFlag then
            acBadge.Text="⚠ AC PATTERN DETECTED — AttachmentBridge recommended"
            acBadge.BackgroundColor3=Color3.fromRGB(200,60,60)
        else
            acBadge.Text="✓ AC STATUS: NOMINAL"
            acBadge.BackgroundColor3=Color3.fromRGB(60,160,80)
        end
    end
    anomRefreshBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshAnomalies() end)
    anomSweepBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(anomSweepBtn.Button)
        PR_AnomalyDetector.SweepAll(); refreshAnomalies()
    end)

    -- Remote Manifest Browser
    local _, sManifest = makeSection(pagePR, "Remote Manifest Browser")
    local ROLE_COLORS = {
        MOVEMENT=Color3.fromRGB(210,240,255),COMBAT=Color3.fromRGB(255,220,215),
        ECONOMY=Color3.fromRGB(220,255,225),ANTICHEAT=Color3.fromRGB(255,235,200),
        UI=Color3.fromRGB(240,230,255),SYNC=Color3.fromRGB(225,245,225),
        HEARTBEAT=Color3.fromRGB(255,245,215),CHAT=Color3.fromRGB(240,255,245),
        SPAWN=Color3.fromRGB(235,235,255),UNKNOWN=Color3.fromRGB(242,240,238),
    }
    local roleFilters  = {"ALL","MOVEMENT","COMBAT","ECONOMY","ANTICHEAT","UI","SYNC","HEARTBEAT","SPAWN","UNKNOWN"}
    local classFilters = {"ALL","PERIODIC","BURST","EVENT","RARE"}
    local dirFilters   = {"ALL","S2C","C2S","BOTH"}
    local rfIdx,cfIdx,dfIdx = 1,1,1
    local PR_FilterRole="ALL"; local PR_FilterClass="ALL"; local PR_FilterDir="ALL"
    local filterRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,30),Parent=sManifest})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),Parent=filterRow})
    local roleBtn  = makeButton(filterRow,"Role:ALL", UDim2.new(0,105,0,26),"")
    roleBtn.Button.BackgroundColor3  = Color3.fromRGB(225,220,255)
    local classBtn = makeButton(filterRow,"Class:ALL",UDim2.new(0,105,0,26),"")
    classBtn.Button.BackgroundColor3 = Color3.fromRGB(220,230,255)
    local dirBtn   = makeButton(filterRow,"Dir:ALL",  UDim2.new(0,80,0,26),"")
    dirBtn.Button.BackgroundColor3   = Color3.fromRGB(220,240,230)
    local srchBox  = mk("TextBox",{PlaceholderText="name...",Text="",
        BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(0,120,0,26),
        Font=Enum.Font.Code,TextSize=11,ClearTextOnFocus=false,Parent=filterRow})
    addCorner(srchBox,UDim.new(0,5)); addStroke(srchBox,1,0.3)
    mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=srchBox})

    local manifestScroll = mk("ScrollingFrame",{BackgroundColor3=Color3.fromRGB(246,244,240),
        Size=UDim2.new(1,0,0,280),CanvasSize=UDim2.new(0,0,0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Parent=sManifest})
    addCorner(manifestScroll,UDim.new(0,6)); addStroke(manifestScroll,1,0.3)
    mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2),Parent=manifestScroll})
    mk("UIPadding",{PaddingTop=UDim.new(0,4),PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4),Parent=manifestScroll})

    local function refreshManifest()
        for _, ch in ipairs(manifestScroll:GetChildren()) do
            if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
        end
        local sl = srchBox.Text:lower()
        local sorted = {}
        for name, rec in pairs(PR_Registry) do table.insert(sorted,{name=name,rec=rec}) end
        table.sort(sorted, function(a,b) return a.rec.FireCount > b.rec.FireCount end)
        local shown = 0
        for _, entry in ipairs(sorted) do
            local name, rec = entry.name, entry.rec
            local skip = false
            if PR_FilterRole  ~= "ALL" and rec.SemanticRole ~= PR_FilterRole  then skip=true end
            if PR_FilterClass ~= "ALL" and rec.FreqClass    ~= PR_FilterClass  then skip=true end
            if PR_FilterDir   ~= "ALL" and rec.Direction    ~= PR_FilterDir    then skip=true end
            if sl ~= "" and not name:lower():find(sl,1,true) then skip=true end
            if not skip then
                shown=shown+1; if shown>100 then break end
                local role   = rec.SemanticRole or "UNKNOWN"
                local rowCol = ROLE_COLORS[role] or ROLE_COLORS.UNKNOWN
                local row = mk("Frame",{BackgroundColor3=rowCol,Size=UDim2.new(1,0,0,50),Parent=manifestScroll})
                addCorner(row,UDim.new(0,4)); addStroke(row,1,0.12)
                mk("TextLabel",{Text=string.format("[%s] %s",role:sub(1,3),name:sub(1,36)),
                    Font=Enum.Font.GothamBold,TextSize=11,TextColor3=Color3.fromRGB(30,30,50),
                    Position=UDim2.new(0,6,0,3),Size=UDim2.new(1,-12,0,14),
                    TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
                mk("TextLabel",{
                    Text=string.format("F:%d S2C:%d C2S:%d Dir:%-4s Class:%-8s Hz:%.2f",
                        rec.FireCount,rec.S2CCount,rec.C2SCount,rec.Direction,rec.FreqClass,rec.AvgHz),
                    Font=Enum.Font.Code,TextSize=9,TextColor3=Color3.fromRGB(60,60,80),
                    Position=UDim2.new(0,6,0,18),Size=UDim2.new(1,-12,0,12),
                    TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
                local sch = PR_SchemaInfer.GetSchemaStr(rec)
                if #sch>48 then sch=sch:sub(1,45).."..." end
                mk("TextLabel",{Text=string.format("Echo:%.2f Pay:%.2f | %s",
                    rec.EchoRelevance or 0,rec.PayloadScore or 0,sch),
                    Font=Enum.Font.Code,TextSize=9,TextColor3=Color3.fromRGB(90,80,110),
                    Position=UDim2.new(0,6,0,32),Size=UDim2.new(1,-12,0,12),
                    TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=row})
            end
        end
        if shown==0 then
            mk("TextLabel",{Text="No remotes match filter.",BackgroundTransparency=1,
                Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=Color3.fromRGB(140,140,140),
                Size=UDim2.new(1,0,0,24),Parent=manifestScroll})
        end
    end
    roleBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); rfIdx=(rfIdx%#roleFilters)+1
        PR_FilterRole=roleFilters[rfIdx]; roleBtn.Label.Text="Role:"..PR_FilterRole; refreshManifest()
    end)
    classBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); cfIdx=(cfIdx%#classFilters)+1
        PR_FilterClass=classFilters[cfIdx]; classBtn.Label.Text="Class:"..PR_FilterClass; refreshManifest()
    end)
    dirBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); dfIdx=(dfIdx%#dirFilters)+1
        PR_FilterDir=dirFilters[dfIdx]; dirBtn.Label.Text="Dir:"..PR_FilterDir; refreshManifest()
    end)
    srchBox:GetPropertyChangedSignal("Text"):Connect(function() refreshManifest() end)
    local mCtrlRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,30),Parent=sManifest})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),Parent=mCtrlRow})
    local mRefBtn = makeButton(mCtrlRow,"Refresh List",   UDim2.new(0,130,0,28),"")
    mRefBtn.Button.BackgroundColor3  = Color3.fromRGB(220,230,255)
    local mRebBtn = makeButton(mCtrlRow,"Rebuild Manifest",UDim2.new(0,160,0,28),"")
    mRebBtn.Button.BackgroundColor3  = Color3.fromRGB(230,220,255)
    mRefBtn.Button.MouseButton1Click:Connect(function() clickSound(); refreshManifest() end)
    mRebBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(mRebBtn.Button)
        PR_ManifestBuilder.Rebuild(); PR_Classifier.ClassifyAll(); PR_ProtocolFingerprint.Compute()
        refreshManifest()
        sendNotification("Manifest rebuilt. "..PR_ProtocolFingerprint.GetStr(), "Info")
    end)

    -- Dependency chain viewer
    local _, sChain = makeSection(pagePR, "Dependency Chain Viewer")
    local chainResult = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="",
        TextColor3=Color3.fromRGB(50,50,80),TextSize=11,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,60),Parent=sChain})
    local cRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,28),Parent=sChain})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),Parent=cRow})
    local cBox = mk("TextBox",{PlaceholderText="Remote name...",Text="",
        BackgroundColor3=Color3.fromRGB(255,255,255),Size=UDim2.new(0,200,0,26),
        Font=Enum.Font.Code,TextSize=11,ClearTextOnFocus=false,Parent=cRow})
    addCorner(cBox,UDim.new(0,5)); addStroke(cBox,1,0.3)
    mk("UIPadding",{PaddingLeft=UDim.new(0,6),Parent=cBox})
    local cTraceBtn = makeButton(cRow,"Trace",UDim2.new(0,90,0,26),"→")
    cTraceBtn.Button.BackgroundColor3=Color3.fromRGB(220,235,255)
    local cEPBtn    = makeButton(cRow,"Entry Points",UDim2.new(0,130,0,26),"")
    cEPBtn.Button.BackgroundColor3=Color3.fromRGB(230,240,220)
    cTraceBtn.Button.MouseButton1Click:Connect(function()
        clickSound()
        local name = cBox.Text; if name=="" then return end
        local chain = PR_DepGraph.GetChain(name)
        if #chain==0 then chainResult.Text="No chain for: "..name; return end
        local parts = {"Chain from "..name..":"}
        for i, n in ipairs(chain) do
            local rec = PR_Registry[n]
            table.insert(parts, string.format("  [%d] %s (%s)",i,n,rec and rec.SemanticRole or "?"))
        end
        chainResult.Text = table.concat(parts,"
")
    end)
    cEPBtn.Button.MouseButton1Click:Connect(function()
        clickSound()
        local eps = PR_DepGraph.GetEntryPoints()
        if #eps==0 then chainResult.Text="No entry points yet."; return end
        local parts = {"Entry points:"}
        for i, ep in ipairs(eps) do
            if i>6 then break end
            table.insert(parts, string.format("  [%d] %s (%d fires)",i,ep.Name,ep.FireCount))
        end
        chainResult.Text = table.concat(parts,"
")
    end)

    -- PR Settings
    local _, sPRSet = makeSection(pagePR, "PR Settings")
    local psRow = mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,10),
        AutomaticSize=Enum.AutomaticSize.Y,Parent=sPRSet})
    mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,10),Parent=psRow})
    makeToggle(psRow,"Active Probe",false,function(on) if PR_CFG then PR_CFG.ProbeEnabled=on end end)
    makeToggle(psRow,"Persist",true,function(on) if PR_CFG then PR_CFG.PersistEnabled=on end end)
    local clrBtn = makeButton(psRow,"Clear Persist",UDim2.new(0,140,0,32),"")
    clrBtn.Button.BackgroundColor3=Color3.fromRGB(255,230,230)
    clrBtn.Button.MouseButton1Click:Connect(function()
        clickSound(); pulseClick(clrBtn.Button)
        pcall(function() if PR_CFG then _G[PR_CFG.PersistKey]=nil end end)
        pcall(function() if PR_PFP then _G[PR_PFP.Key]=nil end end)
        pcall(function() _G.PR_ECHO_WINDOW_REFINED=nil end)
        sendNotification("PR persist cleared.", "Warning")
    end)

    -- Auto-refresh on tab open
    pagePR:GetPropertyChangedSignal("Visible"):Connect(function()
        if not pagePR.Visible then return end
        local cal = PR_EchoCalibrator.GetStatus()
        calibLabel.Text = cal.Active
            and string.format("Remote: %s | Samples: %d | Hz: %.2f | Window: %s",
                cal.RemoteName or "?", cal.SampleCount or 0, cal.RefinedHz or 0,
                cal.RefinedWindow and string.format("%.4fs",cal.RefinedWindow) or "pending")
            or "No calibrator attached."
        prFPLabel.Text  = PR_ProtocolFingerprint.GetStr()
        local s = PR_Analytics.GetSummary()
        prStatLabel.Text = string.format("Remotes:%d  PERIODIC:%d  C2S:%d",
            s.TotalRemotes or 0, s.PERIODIC or 0, s.C2S or 0)
        refreshAnomalies()
        refreshManifest()
    end)
end
