-- ============================================================
-- PrivateAuraFrames v4.5.0  –  WoW Midnight 12.0.5
-- ============================================================

local ADDON_NAME = "PrivateAuraFrames"

-- ──────────────────────────────────────────────────────────────
-- Root frame
-- ──────────────────────────────────────────────────────────────
local Root = CreateFrame("Frame", "PrivateAuraFramesRoot", UIParent)
Root:SetAllPoints(UIParent)
Root:SetFrameStrata("BACKGROUND")

-- ──────────────────────────────────────────────────────────────
-- Saved-variable defaults
-- ──────────────────────────────────────────────────────────────
local DEFAULTS = {
    debug = false,
    party = {
        enabled              = true,
        Width                = 35,
        Height               = 35,
        Spacing              = 2,
        xOffset              = 0,
        yOffset              = 0,
        Anchor               = "CENTER",
        relativeTo           = "CENTER",
        GrowDirection        = "RIGHT",
        PerRow               = 5,
        RowGrowDirection     = "UP",
        HideBorder           = false,
        BorderScale          = 2,
        ShowCountdownFrame   = true,   -- spiral cooldown animation
        ShowCountdownNumbers = false,  -- numbers on the spiral
        ShowDurationText     = false,  -- separate FontString below the icon
        HideTooltip          = false,
        RangeFade            = true,  -- fade containers when unit out of range
        RangeFadeAlpha       = 0.4,    -- alpha when out of range (0..1)
        Limit                = 5,
    },
    raid = {
        enabled              = true,
        Width                = 25,
        Height               = 25,
        Spacing              = 2,
        xOffset              = 0,
        yOffset              = 0,
        Anchor               = "CENTER",
        relativeTo           = "CENTER",
        GrowDirection        = "RIGHT",
        PerRow               = 5,
        RowGrowDirection     = "UP",
        HideBorder           = false,
        BorderScale          = 2,
        ShowCountdownFrame   = true,
        ShowCountdownNumbers = false,
        ShowDurationText     = false,
        HideTooltip          = false,
        RangeFade            = true,
        RangeFadeAlpha       = 0.4,
        Limit                = 5,
    },
}

local ANCHOR_POINTS = {
    "TOPLEFT","TOP","TOPRIGHT","LEFT","CENTER",
    "RIGHT","BOTTOMLEFT","BOTTOM","BOTTOMRIGHT",
}
local GROW_DIRS = { "RIGHT","LEFT","UP","DOWN" }

-- ──────────────────────────────────────────────────────────────
-- State
-- ──────────────────────────────────────────────────────────────

local db
local frames    = { party = {}, raid = {} }
local anchorIDs = {}
local inCombat  = false
local settingsCat
local BuildSettings

local previewActive  = { party = false, raid = false }
local previewState   = {}
local previewThrottle = {}

-- ──────────────────────────────────────────────────────────────
-- Unit frame scanners
-- ──────────────────────────────────────────────────────────────

local UnitFrameCache = {}

local function ScanBlizzard()
    -- Party: CompactPartyFrameMember1..5
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember"..i]
        if f and f.unit then UnitFrameCache[f.unit] = f end
    end
    -- Raid: walk the container's "normal" frames
    if CompactRaidFrameContainer and CompactRaidFrameContainer.ApplyToFrames then
        CompactRaidFrameContainer:ApplyToFrames("normal", function(f)
            if f and f.unit then UnitFrameCache[f.unit] = f end
        end)
    end
    -- Player frame
    if PlayerFrame and PlayerFrame.unit then
        UnitFrameCache[PlayerFrame.unit] = PlayerFrame
    end
end

local function ScanElvUI()
    if not ElvUF then return end
    -- Prefer a visible frame over a hidden one when multiple frames
    -- exist for the same unit token (ElvUI's split-raid layouts create
    -- duplicate frames; only one set is visible at a time).
    local function take(u, f)
        if not f or not u then return end
        local existing = UnitFrameCache[u]
        if existing and existing:IsVisible() then return end
        UnitFrameCache[u] = f
    end

    -- Player frame (works in party, hidden in raid)
    local pf = _G["ElvUF_Player"]
    if pf and pf.unit then take(pf.unit, pf) end
    -- Party (one group of 5)
    for m = 1, 5 do
        local f = _G["ElvUF_PartyGroup1UnitButton"..m]
        if f and f.unit then take(f.unit, f) end
    end

    -- Detect which raid layout is active. ElvUI only renders one of
    -- {legacy, Raid1, Raid2, Raid3} at a time; scanning all 200+
    -- possible globals each refresh is wasteful. Use the first
    -- visible button as a probe to pick the right layout.
    --
    -- We still fall back to scanning all of them if the probes don't
    -- find a visible frame, in case the user is using an unusual
    -- ElvUI configuration. The fallback only runs at config-time when
    -- the user is between layouts; in practice the fast path covers
    -- every steady-state raid.
    local function scanRaidSet(prefix)
        for g = 1, 8 do
            for m = 1, 10 do
                local f = _G[prefix..g.."UnitButton"..m]
                if f and f.unit then take(f.unit, f) end
            end
        end
    end

    -- Probe each candidate prefix in order; stop at the first one
    -- whose UnitButton1 is visible.
    local prefixes = {
        "ElvUF_RaidGroup",   -- legacy single-raid
        "ElvUF_Raid1Group",  -- split-raid variant 1
        "ElvUF_Raid2Group",
        "ElvUF_Raid3Group",
    }
    local matched
    for i = 1, #prefixes do
        local probe = _G[prefixes[i].."1UnitButton1"]
        if probe and probe:IsVisible() then
            scanRaidSet(prefixes[i])
            matched = true
            break
        end
    end
    -- Fallback for unusual configurations: scan every prefix.
    if not matched then
        for i = 1, #prefixes do
            scanRaidSet(prefixes[i])
        end
    end
end

local SCANNERS = { ScanBlizzard, ScanElvUI }

local function RefreshUnitFrameCache()
    wipe(UnitFrameCache)
    for _, scan in ipairs(SCANNERS) do
        pcall(scan)
    end
end


local function GetUnitFrame(unit)
    local f = UnitFrameCache[unit]
    if f and f:IsVisible() and f.unit == unit then return f end
    -- Cache miss or stale; refresh and retry once.
    RefreshUnitFrameCache()
    f = UnitFrameCache[unit]
    if f and f.unit == unit then return f end
    return nil
end


local function GetPlayerVisibleFrame()
    local pGUID = UnitGUID("player")

    -- 1. Raid context: find player among raid frames
    if IsInRaid() and pGUID then
        -- Same layout-probe pattern as ScanElvUI: detect the active
        -- raid set and only scan that one.
        local prefixes = {
            "ElvUF_RaidGroup",
            "ElvUF_Raid1Group",
            "ElvUF_Raid2Group",
            "ElvUF_Raid3Group",
        }
        for i = 1, #prefixes do
            local probe = _G[prefixes[i].."1UnitButton1"]
            if probe and probe:IsVisible() then
                for g = 1, 8 do
                    for m = 1, 10 do
                        local f = _G[prefixes[i]..g.."UnitButton"..m]
                        if f and f:IsVisible() and f.unit and UnitGUID(f.unit) == pGUID then
                            return f
                        end
                    end
                end
                break  -- found the active prefix; don't try other layouts
            end
        end
        if CompactRaidFrameContainer and CompactRaidFrameContainer.ApplyToFrames then
            local match
            CompactRaidFrameContainer:ApplyToFrames("normal", function(f)
                if not match and f and f:IsVisible() and f.unit and UnitGUID(f.unit) == pGUID then
                    match = f
                end
            end)
            if match then return match end
        end
    end

    -- 2. Party context: find player among party frames (visible).
    if pGUID then
        for m = 1, 5 do
            local f = _G["ElvUF_PartyGroup1UnitButton"..m]
            if f and f:IsVisible() and f.unit and UnitGUID(f.unit) == pGUID then
                return f
            end
        end
        for i = 1, 5 do
            local f = _G["CompactPartyFrameMember"..i]
            if f and f:IsVisible() and f.unit and UnitGUID(f.unit) == pGUID then
                return f
            end
        end
    end

    -- 3. Solo (or party frames hidden): fall back to the party slot
    for m = 5, 1, -1 do
        local f = _G["ElvUF_PartyGroup1UnitButton"..m]
        if f then return f end
    end
    -- 4. Last-resort fallback: standalone player frame.
    return GetUnitFrame("player")
end

-- ──────────────────────────────────────────────────────────────
-- DB init
-- ──────────────────────────────────────────────────────────────
local function InitDB()
    PrivateAuraFramesDB = PrivateAuraFramesDB or {}
    db = PrivateAuraFramesDB
    for k, v in pairs(DEFAULTS) do
        if type(v) == "table" then
            db[k] = db[k] or {}
            for k2, v2 in pairs(v) do
                if db[k][k2] == nil then db[k][k2] = v2 end
            end
        else
            if db[k] == nil then db[k] = v end
        end
    end
end

local function DebugErr(msg)
    if db and db.debug then
        print("|cffff4444PAF error|r "..tostring(msg))
    end
end

-- ──────────────────────────────────────────────────────────────
-- Anchor cleanup
-- ──────────────────────────────────────────────────────────────
local function RemoveAllAnchors()
    for i = 1, #anchorIDs do
        local id = anchorIDs[i]
        if id then
            local ok, err = pcall(C_UnitAuras.RemovePrivateAuraAnchor, id)
            if not ok then DebugErr("remove "..tostring(id)..": "..tostring(err)) end
        end
    end
    wipe(anchorIDs)
end

-- ──────────────────────────────────────────────────────────────
-- Layout helpers
-- ──────────────────────────────────────────────────────────────
local function GetGrowVectors(S)
    local xD = (S.GrowDirection    == "RIGHT" and 1) or (S.GrowDirection    == "LEFT"  and -1) or 0
    local yD = (S.GrowDirection    == "DOWN"  and -1) or (S.GrowDirection   == "UP"    and  1) or 0
    local xR = (S.RowGrowDirection == "RIGHT" and 1) or (S.RowGrowDirection == "LEFT"  and -1) or 0
    local yR = (S.RowGrowDirection == "DOWN"  and -1) or (S.RowGrowDirection == "UP"   and  1) or 0
    return xD, yD, xR, yR
end

local function GetIconOffset(auraIndex, S, xD, yD, xR, yR)
    local row    = math.ceil(auraIndex / S.PerRow)
    local column = auraIndex - (row - 1) * S.PerRow
    local ox = (column - 1) * (S.Width  + S.Spacing) * xD
             + (row    - 1) * (S.Width  + S.Spacing) * xR
    local oy = (column - 1) * (S.Height + S.Spacing) * yD
             + (row    - 1) * (S.Height + S.Spacing) * yR
    return ox, oy
end

-- ──────────────────────────────────────────────────────────────
-- BuildUnit
-- ──────────────────────────────────────────────────────────────

local function BuildUnit(layout, slotIndex, unit, unitFrame)
    local S = db[layout]
    if not S.enabled then return end


    local slot = frames[layout][slotIndex]
    if not slot then
        slot = { icons = {} }
        slot.container = CreateFrame("Frame", nil, Root)
        slot.container:SetFrameStrata("HIGH")
        frames[layout][slotIndex] = slot
    end


    local container = slot.container
    container.__pafUnit   = unit
    container.__pafLayout = layout
    container:SetAlpha(1)

    -- For RangeFade: parent the container to the unit frame so its
    -- alpha is inherited via WoW's render pipeline (no Lua read needed,
    -- so no taint contamination). When RangeFade is off, parent to
    -- Root so the container always renders at full opacity regardless
    -- of the unit frame's fade state.
    local anchorTo = (unitFrame and unitFrame.__owner) or unitFrame
    local desiredParent = (S.RangeFade and anchorTo) or Root
    if container:GetParent() ~= desiredParent then
        container:SetParent(desiredParent)
        container:SetFrameStrata("HIGH")
    end

    container:SetSize(S.Width, S.Height)
    container:ClearAllPoints()
    container:SetPoint(S.Anchor, anchorTo, S.relativeTo, S.xOffset, S.yOffset)
    container:Show()

    local borderSize = S.HideBorder and -1000 or (S.BorderScale or 1)
    local xD, yD, xR, yR = GetGrowVectors(S)

    for auraIndex = 1, S.Limit do
        local ox, oy = GetIconOffset(auraIndex, S, xD, yD, xR, yR)


        local iconFrame = slot.icons[auraIndex]
        if not iconFrame then
            iconFrame = CreateFrame("Frame", nil, container)
            iconFrame:SetFrameStrata("HIGH")
            slot.icons[auraIndex] = iconFrame
        end


        if S.HideTooltip then
            iconFrame:SetSize(0.001, 0.001)
        else
            iconFrame:SetSize(S.Width, S.Height)
        end
        iconFrame:ClearAllPoints()
        iconFrame:SetPoint(S.Anchor, container, S.Anchor, ox, oy)
        iconFrame:Show()

        -- Reuse the args table across rebuilds. Saves ~600-800
        -- transient table allocations per rebuild in a full raid.
        -- We mutate fields in place rather than reallocating.
        local args = iconFrame.__pafArgs
        if not args then
            args = {
                isContainer = false,
                iconInfo = {
                    iconAnchor = {
                        point         = "CENTER",
                        relativePoint = "CENTER",
                        offsetX       = 0,
                        offsetY       = 0,
                        -- relativeTo set below
                    },
                    -- borderScale, iconWidth, iconHeight set below
                },
                __durationAnchorTbl = {
                    point         = "BOTTOM",
                    relativePoint = "BOTTOM",
                    offsetX       = 0,
                    offsetY       = 2,
                    -- relativeTo set below
                },
            }
            args.iconInfo.iconAnchor.relativeTo = iconFrame
            args.__durationAnchorTbl.relativeTo = iconFrame
            iconFrame.__pafArgs = args
        end

        args.unitToken            = unit
        args.auraIndex            = auraIndex
        args.parent               = iconFrame
        args.showCountdownFrame   = S.ShowCountdownFrame
        args.showCountdownNumbers = S.ShowCountdownNumbers
        args.iconInfo.borderScale = borderSize
        args.iconInfo.iconWidth   = S.Width
        args.iconInfo.iconHeight  = S.Height
        if S.ShowDurationText then
            args.durationAnchor = args.__durationAnchorTbl
        else
            args.durationAnchor = nil
        end

        local ok, id = pcall(C_UnitAuras.AddPrivateAuraAnchor, args)
        if ok and id then
            anchorIDs[#anchorIDs + 1] = id
        else
            DebugErr(layout.." slot="..slotIndex.." aura="..auraIndex..": "..tostring(id))
        end
    end

    -- Hide any leftover icon frames if Limit was lowered since last build.
    for i = S.Limit + 1, #slot.icons do
        if slot.icons[i] then slot.icons[i]:Hide() end
    end
end

-- ──────────────────────────────────────────────────────────────
-- Range fader
-- ──────────────────────────────────────────────────────────────
-- Implementation: containers parented to the unit frame inherit its
-- alpha via WoW's render pipeline. No Lua reads of unit-related state
-- are needed (which would propagate taint after touching private aura
-- data). All the heavy lifting happens in BuildUnit's SetParent call.
--
-- This means our range-fade is whatever the underlying unit-frame
-- addon (ElvUI / Blizzard) does for fading. If ElvUI doesn't fade
-- out-of-range frames, ours won't either — they always match.
--
-- EnsureRangeFader is kept as a stub so callers don't break. The
-- RangeFadeAlpha setting is unused under this approach; we inherit
-- whatever alpha the parent renders at.
local function EnsureRangeFader()
    -- intentionally no-op; alpha is inherited via SetParent.
end

local function HideLayout(layout)
    for _, slot in pairs(frames[layout]) do
        if slot and slot.container then slot.container:Hide() end
    end
end

-- ──────────────────────────────────────────────────────────────
-- BuildAll
-- ──────────────────────────────────────────────────────────────
local function BuildAll()
    RemoveAllAnchors()
    RefreshUnitFrameCache()

    local inRaid = IsInRaid()
    local activeLayout = inRaid and "raid"  or "party"
    local otherLayout  = inRaid and "party" or "raid"

    HideLayout(otherLayout)

    if not db[activeLayout].enabled then
        HideLayout(activeLayout)
        return
    end

    if inRaid then
        local n = GetNumGroupMembers()
        for i = 1, 40 do
            local slot = frames.raid[i]
            if i <= n then
                local u = "raid"..i
                if UnitExists(u) then
                    local uf = GetUnitFrame(u)
                    if uf then
                        BuildUnit("raid", i, u, uf)
                    elseif slot and slot.container then
                        slot.container:Hide()
                    end
                elseif slot and slot.container then
                    slot.container:Hide()
                end
            elseif slot and slot.container then
                slot.container:Hide()
            end
        end
    else
        local n = GetNumGroupMembers()
        for i = 1, 5 do
            local u
            if i < 5 then
                if n > 0 then u = "party"..i end
            else
                u = "player"
            end

            local slot = frames.party[i]
            if u and UnitExists(u) then
			
                local uf
                if u == "player" then
                    uf = GetPlayerVisibleFrame()
                else
                    uf = GetUnitFrame(u)
                end
                if uf then
                    BuildUnit("party", i, u, uf)
                elseif slot and slot.container then
                    slot.container:Hide()
                end
            elseif slot and slot.container then
                slot.container:Hide()
            end
        end
    end

    EnsureRangeFader()
end

local rebuildTimer
local function RebuildAll()
    if rebuildTimer then rebuildTimer:Cancel() end
    rebuildTimer = C_Timer.NewTimer(0.2, function()
        rebuildTimer = nil
        BuildAll()
    end)
end

-- ──────────────────────────────────────────────────────────────
-- Events
-- ──────────────────────────────────────────────────────────────
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ENCOUNTER_START")
ev:RegisterEvent("ENCOUNTER_END")
ev:RegisterUnitEvent("UNIT_PET", "player")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        ev:UnregisterEvent("ADDON_LOADED")
        InitDB()

    elseif event == "PLAYER_LOGIN" then
        ev:UnregisterEvent("PLAYER_LOGIN")
        BuildSettings()
        RefreshUnitFrameCache()
        print("|cff00ccff"..ADDON_NAME.."|r v4.5 loaded. /paf for settings.")

    elseif event == "PLAYER_ENTERING_WORLD"
        or event == "GROUP_ROSTER_UPDATE"
        or event == "UNIT_PET"
        or event == "ZONE_CHANGED_NEW_AREA" then
        if not inCombat then RebuildAll() end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        RebuildAll()

    elseif event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        C_Timer.After(0.5, RebuildAll)
    end
end)

-- ──────────────────────────────────────────────────────────────
-- Preview system
-- ──────────────────────────────────────────────────────────────
local PREVIEW_ICON = 136243   -- inv_misc_questionmark

local function HidePreview(layout)
    local pv = previewState[layout]
    if pv and pv.mover then pv.mover:Hide() end
    previewActive[layout] = false
end

local ShowPreview
ShowPreview = function(layout)
    local S = db[layout]

    local uf = GetPlayerVisibleFrame()
    if not uf then
        print("|cff00ccffPAF|r: No visible unit frame found for player.")
        return
    end
    local anchorTo = uf.__owner or uf

    local pv = previewState[layout]
    if not pv then
        pv = { icons = {} }
        previewState[layout] = pv
    end

    if not pv.mover then
        local m = CreateFrame("Frame", nil, Root)
        m:SetFrameStrata("DIALOG")
        m:SetMovable(true)
        m:EnableMouse(true)
        m:RegisterForDrag("LeftButton")
        m:SetScript("OnDragStart", function(self) self:StartMoving() end)
        pv.mover = m
    end

    local mover = pv.mover
    mover:SetSize(S.Width, S.Height)
    mover:ClearAllPoints()
    mover:SetPoint(S.Anchor, anchorTo, S.relativeTo, S.xOffset, S.yOffset)
    mover:Show()

    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local function PointCoords(frame, point)
            local l, b, w, h = frame:GetLeft(), frame:GetBottom(), frame:GetWidth(), frame:GetHeight()
            if not l then return nil, nil end
            local t = b + h
            local cx, cy = l + w/2, b + h/2
            if point == "TOPLEFT"        then return l,   t
            elseif point == "TOP"        then return cx,  t
            elseif point == "TOPRIGHT"   then return l+w, t
            elseif point == "LEFT"       then return l,   cy
            elseif point == "CENTER"     then return cx,  cy
            elseif point == "RIGHT"      then return l+w, cy
            elseif point == "BOTTOMLEFT" then return l,   b
            elseif point == "BOTTOM"     then return cx,  b
            elseif point == "BOTTOMRIGHT"then return l+w, b end
            return cx, cy
        end
        local ax, ay = PointCoords(self,     S.Anchor)
        local rx, ry = PointCoords(anchorTo, S.relativeTo)
        if ax and rx then
            db[layout].xOffset = math.floor(ax - rx + 0.5)
            db[layout].yOffset = math.floor(ay - ry + 0.5)
            print("|cff00ccffPAF|r: "..layout.." offset → x="
                ..db[layout].xOffset.." y="..db[layout].yOffset)
            RebuildAll()
        end
    end)

    local xD, yD, xR, yR = GetGrowVectors(S)
    for i = 1, 10 do
        local icon = pv.icons[i]
        if not icon then
            icon = mover:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(PREVIEW_ICON)
            icon:SetDesaturated(true)
            icon.text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            icon.text:SetTextColor(1, 1, 0, 1)
            pv.icons[i] = icon
        end
        if i <= S.Limit then
            local ox, oy = GetIconOffset(i, S, xD, yD, xR, yR)
            icon:SetSize(S.Width, S.Height)
            icon:ClearAllPoints()
            icon:SetPoint(S.Anchor, mover, S.Anchor, ox, oy)
            icon:Show()
            icon.text:ClearAllPoints()
            icon.text:SetPoint("CENTER", icon, "CENTER", 0, 0)
            icon.text:SetText(tostring(i))
            icon.text:Show()
        else
            icon:Hide()
            if icon.text then icon.text:Hide() end
        end
    end

    previewActive[layout] = true
end

local function TogglePreview(layout)
    if previewActive[layout] then
        HidePreview(layout)
        print("|cff00ccffPAF|r: "..layout.." preview OFF")
    else
        ShowPreview(layout)
        print("|cff00ccffPAF|r: |cff00ff00"..layout.." preview ON|r — drag to reposition")
    end
end

-- ──────────────────────────────────────────────────────────────
-- Settings panel
-- ──────────────────────────────────────────────────────────────
BuildSettings = function()
    local root = Settings.RegisterVerticalLayoutCategory(ADDON_NAME)

    local function AddSection(layout, label)
        local sub = Settings.RegisterVerticalLayoutSubcategory(root, label)
        local tbl = db[layout]

        local function ScheduleLivePreview()
            if not previewActive[layout] then return end
            if previewThrottle[layout] then
                previewThrottle[layout]:Cancel()
                previewThrottle[layout] = nil
            end
            previewThrottle[layout] = C_Timer.NewTimer(0.05, function()
                previewThrottle[layout] = nil
                if previewActive[layout] then ShowPreview(layout) end
            end)
        end

        local function OnAnyChange()
            ScheduleLivePreview()
            RebuildAll()
        end

        local function Slider(name, key, mn, mx, step)
            local variable = "PAF_"..layout.."_"..key
            local setting = Settings.RegisterAddOnSetting(
                sub, variable, key, tbl,
                Settings.VarType.Number, name, tbl[key])
            local opts = Settings.CreateSliderOptions(mn, mx, step)
            opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
                function(v)
                    return step < 1 and string.format("%.2f", v)
                                     or tostring(math.floor(v + 0.5))
                end)
            Settings.CreateSlider(sub, setting, opts, "")
            setting:SetValueChangedCallback(OnAnyChange)
        end

        local function Check(name, key)
            local variable = "PAF_"..layout.."_"..key
            local setting = Settings.RegisterAddOnSetting(
                sub, variable, key, tbl,
                Settings.VarType.Boolean, name, tbl[key])
            Settings.CreateCheckbox(sub, setting, "")
            setting:SetValueChangedCallback(OnAnyChange)
        end

        local function Drop(name, key, choices)
            local variable = "PAF_"..layout.."_"..key
            local setting = Settings.RegisterAddOnSetting(
                sub, variable, key, tbl,
                Settings.VarType.String, name, tbl[key])
            local function GetOptions()
                local container = Settings.CreateControlTextContainer()
                for _, ch in ipairs(choices) do container:Add(ch, ch) end
                return container:GetData()
            end
            Settings.CreateDropdown(sub, setting, GetOptions, "")
            setting:SetValueChangedCallback(OnAnyChange)
        end

        Check("Enabled",            "enabled")
        Slider("Icon Width",        "Width",          8,    64,  1)
        Slider("Icon Height",       "Height",         8,    64,  1)
        Slider("Spacing",           "Spacing",        0,    20,  1)
        Slider("X Offset",          "xOffset",      -250,  250,  1)
        Slider("Y Offset",          "yOffset",      -250,  250,  1)
        Drop("Anchor Point",        "Anchor",          ANCHOR_POINTS)
        Drop("Relative Point",      "relativeTo",      ANCHOR_POINTS)
        Drop("Grow Direction",      "GrowDirection",   GROW_DIRS)
        Slider("Max Per Row",       "PerRow",          1,    10,  1)
        Drop("Row Grow Direction",  "RowGrowDirection",GROW_DIRS)
        Slider("Max Icons",         "Limit",           1,    10,  1)
        Check("Hide Border",            "HideBorder")
        Slider("Border Scale",          "BorderScale",  0.1,    3, 0.05)
        Check("Show Spiral Animation",  "ShowCountdownFrame")
        Check("Show Spiral Numbers",    "ShowCountdownNumbers")
        Check("Show Duration Text",     "ShowDurationText")
        Check("Hide Tooltip",                "HideTooltip")
        Check("Fade icons with frame fade",  "RangeFade")

        do
            local previewVar = "PAF_preview_"..layout
            local setting = Settings.RegisterProxySetting(
                sub,
                previewVar,
                Settings.VarType.Boolean,
                "Preview — drag to reposition",
                false,
                function() return previewActive[layout] or false end,
                function() end)
            setting:SetValueChangedCallback(function() TogglePreview(layout) end)
            Settings.CreateCheckbox(sub, setting,
                "Shows numbered placeholder icons on your unit frame. Drag to reposition.")
        end
    end

    AddSection("party", "Party / Dungeon (≤5 players)")
    AddSection("raid",  "Raid (6-40 players)")

    Settings.RegisterAddOnCategory(root)
    settingsCat = root
end

-- ──────────────────────────────────────────────────────────────
-- Slash command
-- ──────────────────────────────────────────────────────────────
SLASH_PAF1 = "/paf"
SlashCmdList["PAF"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" or msg == "config" then
        if settingsCat then Settings.OpenToCategory(settingsCat:GetID()) end

    elseif msg == "reload" or msg == "refresh" then
        RebuildAll()
        print("|cff00ccff"..ADDON_NAME.."|r: rebuilding...")

    elseif msg == "preview party" or msg == "pp" then
        TogglePreview("party")
    elseif msg == "preview raid" or msg == "pr" then
        TogglePreview("raid")
    elseif msg == "preview" then
        TogglePreview(IsInRaid() and "raid" or "party")

    elseif msg == "debug" then
        print("|cff00ccffPAF|r: "..#anchorIDs.." live anchors")
        local pc, rc = 0, 0
        for _, slot in pairs(frames.party) do
            if slot and slot.container and slot.container:IsShown() then pc = pc + 1 end
        end
        for _, slot in pairs(frames.raid) do
            if slot and slot.container and slot.container:IsShown() then rc = rc + 1 end
        end
        print("  party containers visible: "..pc..", raid containers visible: "..rc)

    elseif msg == "verbose" then
        db.debug = not db.debug
        print("|cff00ccffPAF|r: verbose errors "..(db.debug and "ON" or "OFF"))

    elseif msg == "reset" then
        PrivateAuraFramesDB = nil
        ReloadUI()

    else
        print("|cff00ccff"..ADDON_NAME.."|r commands:")
        print("  /paf config        — open settings")
        print("  /paf preview       — toggle preview (auto party/raid)")
        print("  /paf preview party — toggle party preview")
        print("  /paf preview raid  — toggle raid preview")
        print("  /paf reload        — rebuild anchors")
        print("  /paf debug         — show anchor counts")
        print("  /paf verbose       — toggle error printing")
        print("  /paf reset         — wipe saved settings (reloads UI)")
    end
end
