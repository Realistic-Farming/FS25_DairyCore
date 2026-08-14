-- =========================================================
-- DairyRfPdaGuest - Esc RF PDA Dairy framework (Table shell)
-- Soft-detect: mission.dairyCoreManager. isAvailable false when PF / disabled.
-- getBarnRows() only. Read-only. Densify 2026-08-05: Sale quality honesty.
-- Barn human-name polish HELD (Col A = barnId). No earned-tier invent.
-- =========================================================

DairyRfPdaGuest = {}

local MOD_DIR = g_currentModDirectory
local MOD_NAME = g_currentModName
local PANEL_ID = "dairy"
local PANEL_ORDER = 70
local MAX_ROWS = 8
local _registered = false

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function getHost()
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    local env = getfenv(0)
    if env ~= nil and env.g_rfEscModules ~= nil then
        return env.g_rfEscModules
    end
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    return nil
end

local function getHostPage()
    if g_inGameMenu == nil then return nil end
    return g_inGameMenu.menuRealisticFarming
end

local function findDescendant(root, id)
    if root == nil or id == nil then return nil end
    if root.getDescendantById then
        local el = root:getDescendantById(id)
        if el ~= nil then return el end
    end
    local page = getHostPage()
    if page and page.getDescendantById then
        return page:getDescendantById(id)
    end
    return nil
end

local function setText(el, text)
    if el ~= nil and type(el.setText) == "function" then el:setText(text or "") end
end

local function setVis(el, visible)
    if el ~= nil and type(el.setVisible) == "function" then el:setVisible(visible) end
end

local function paintSide(container, key, fallback)
    setVis(findDescendant(container, "wcSideInfoShell"), false)
    setVis(findDescendant(container, "mdSideInfoShell"), false)
    local shell = findDescendant(container, "rfSideInfoShell")
    local body = findDescendant(container, "rfSideInfoBody")
    setVis(shell, true)
    setText(body, tr(key, fallback))
end


local function refreshFwAbs(container)
    local page = getHostPage()
    local host = findDescendant(container, "rfHostPlaceholder") or (page and page.rfHostPlaceholder)
    local shell = findDescendant(container, "rfFrameworkGlanceShell")
    local status = findDescendant(container, "rfFwStatusBlock")
    local tableBlock = findDescendant(container, "rfFwTableBlock")
    for _, el in ipairs({ host, shell, status, tableBlock }) do
        if el ~= nil and type(el.updateAbsolutePosition) == "function" then
            el:updateAbsolutePosition()
        end
    end
end

local function clearHostDupes(container)
    setText(findDescendant(container, "rfHostBody"), "")
    setText(findDescendant(container, "rfHostTitle"), "")
    setText(findDescendant(container, "rfHostBlurb"), "")
    setVis(findDescendant(container, "rfHostTitle"), false)
    setVis(findDescendant(container, "rfHostBlurb"), false)
end

local function showTableMode(container)
    setVis(findDescendant(container, "rfFrameworkGlanceShell"), true)
    setVis(findDescendant(container, "rfFwStatusBlock"), false)
    setVis(findDescendant(container, "rfFwTableBlock"), true)
    refreshFwAbs(container)
end

local function getMgr()
    if g_currentMission ~= nil and g_currentMission.dairyCoreManager ~= nil then
        return g_currentMission.dairyCoreManager
    end
    return nil
end

local function isDairyAvailable()
    local mgr = getMgr()
    if mgr == nil then return false end
    if mgr.disabled == true then return false end
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then return false end
    return true
end

--- Stable scan: barnId ascending (human name HOLD this pass).

--- Human barn name for Col A (Tyson eyes-on 2026-08-08 shot 04: raw uniqueId is ugly).
--- George resolve ladder: go to the placeable via placeableSystem and take the first
--- non-empty real name, then fall back to a truncated id. Every step is pcall-guarded
--- and nil-safe: an unknown id or a missing placeableSystem must truncate, never throw.
--- Veto honoured: no invented row.barnName, no typeDesc, no LUADOC getName triple-trust.
local function barnLabel(r)
    if r == nil then
        return "?"
    end
    -- Anything the row already carries as a real human name still wins.
    local human = r.nameCustom or r.displayName or r.barnName or r.name
    if type(human) == "string" and human ~= "" then
        return human
    end

    local barnId = r.barnId
    if barnId ~= nil and g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local ps = g_currentMission.placeableSystem
        local placeable
        if type(ps.getPlaceableByUniqueId) == "function" then
            local ok, p = pcall(function() return ps:getPlaceableByUniqueId(barnId) end)
            if ok then placeable = p end
        end
        if placeable ~= nil then
            -- 1) getName() / nameCustom
            if type(placeable.getName) == "function" then
                local ok, n = pcall(function() return placeable:getName() end)
                if ok and type(n) == "string" and n ~= "" then return n end
            end
            if type(placeable.nameCustom) == "string" and placeable.nameCustom ~= "" then
                return placeable.nameCustom
            end
            -- 2) nameL10n
            if type(placeable.nameL10n) == "string" and placeable.nameL10n ~= "" then
                return placeable.nameL10n
            end
            -- 3) storeItem name
            local si = placeable.storeItem
            if si ~= nil and type(si.name) == "string" and si.name ~= "" then
                return si.name
            end
        end
    end

    -- 4) last resort: truncated id
    local id = tostring(barnId or "?")
    if #id > 24 then
        return id:sub(1, 22) .. "..."
    end
    return id
end

local function sortBarnRows(rows)
    table.sort(rows, function(a, b)
        local idA = tostring((a and a.barnId) or "")
        local idB = tostring((b and b.barnId) or "")
        return idA < idB
    end)
end

local function buildWarnFlavour(r)
    local bits = {}
    if r.feedDiseaseFlag then
        local crop = r.feedDiseaseCropName
        if type(crop) == "string" and crop ~= "" then
            bits[#bits + 1] = string.format(tr("dairy_rf_pda_warn_feed_crop", "feed disease (%s)"), crop)
        else
            bits[#bits + 1] = tr("dairy_rf_pda_warn_feed", "feed disease")
        end
    end
    if (tonumber(r.mycotoxin) or 0) > 0 then
        bits[#bits + 1] = tr("dairy_rf_pda_warn_myc", "mycotoxin")
    end
    if #bits == 0 then
        return nil
    end
    local barn = tostring(r.barnId or "?")
    return string.format("%s: %s", barn, table.concat(bits, ", "))
end

local function anyRitterWithCounts(rows)
    for _, r in ipairs(rows) do
        if r.ritterMode == true and r.counts ~= nil then
            return true
        end
    end
    return false
end

local SIDE_FALLBACK =
    "Dairy glance: barns, herd health, sale quality, spoilage. Rows sit in the gray shell. Barn id truncates when unnamed. Esc is read-only - open Dairy tools for full barn work."

local BLURB_FALLBACK =
    "Barn herd glance: sale quality. Spoilage clock idle until collection is recorded (path inert). Read-only."

local _rfFwTitleBaselineWarned = false

--- rfFwTableTitle is shared by every Table-mode module (Income, Dairy, Depot, NPCFavor).
--- Income deliberately drops it to the bottom band (-360) for its own glance, and no host
--- calls onHide, so whoever shows next must reassert its own baseline or it inherits
--- Income's position. Cheap, idempotent, and keeps each guest owning its own layout.
local function resetFwTableTitlePos(container)
    local el = findDescendant(container, "rfFwTableTitle")
    if el == nil or type(el.setPosition) ~= "function" then return end
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedYValue) ~= "function" then
        if not _rfFwTitleBaselineWarned then
            _rfFwTitleBaselineWarned = true
            print("[DairyCore] DairyRfPdaGuest: GuiUtils normalizer absent - cannot reassert rfFwTableTitle baseline")
        end
        return
    end
    el:setPosition(GuiUtils.getNormalizedXValue("0px", 0), GuiUtils.getNormalizedYValue("0px", 0))
    if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
end

function DairyRfPdaGuest.onShow(container, lightOnly)
    resetFwTableTitlePos(container)
    clearHostDupes(container)
    showTableMode(container)
    paintSide(container, "rf_pda_side_info_dairy", SIDE_FALLBACK)
    setText(findDescendant(container, "rfFwTableTitle"), "")
    setVis(findDescendant(container, "rfFwTableTitle"), false)
    setText(findDescendant(container, "rfFwColA"), tr("dairy_rf_pda_col_barn", "Barn"))
    setText(findDescendant(container, "rfFwColB"), tr("dairy_rf_pda_col_health", "Herd"))
    setText(findDescendant(container, "rfFwColC"), tr("dairy_rf_pda_col_tier", "Sale quality"))
    setText(findDescendant(container, "rfFwColD"), tr("dairy_rf_pda_col_spoil", "Spoilage"))

    local mgr = getMgr()
    local rows = {}
    if mgr ~= nil and type(mgr.getBarnRows) == "function" then
        rows = mgr:getBarnRows() or {}
    end
    sortBarnRows(rows)

    local emptyEl = findDescendant(container, "rfFwEmptyHint")
    local hintEl = findDescendant(container, "rfFwHintTable")
    local moreEl = findDescendant(container, "rfFwMore")
    local warnBits = {}

    if #rows == 0 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("dairy_rf_pda_empty", "no barns"))
        for i = 1, MAX_ROWS do
            for _, c in ipairs({"A", "B", "C", "D"}) do
                setVis(findDescendant(container, "rfFwRow" .. i .. c), false)
            end
        end
        setText(moreEl, "")
        setText(hintEl, "")
        return
    end

    setVis(emptyEl, false)
    setText(emptyEl, "")
    local show = math.min(#rows, MAX_ROWS)
    for i = 1, MAX_ROWS do
        local a = findDescendant(container, "rfFwRow" .. i .. "A")
        local b = findDescendant(container, "rfFwRow" .. i .. "B")
        local c = findDescendant(container, "rfFwRow" .. i .. "C")
        local d = findDescendant(container, "rfFwRow" .. i .. "D")
        if i <= show then
            local r = rows[i]
            setVis(a, true); setVis(b, true); setVis(c, true); setVis(d, true)
            -- George HOLD getName=rename-only: soft-try human fields, else truncate barnId.
            setText(a, barnLabel(r))
            setText(b, tostring(r.herdHealth or 0))
            -- Live qualityTier is already effective / post-spoilage sale tier. The
            -- row carries the KEY (dc_tier_*); translate it here (DC-14 invariant 3).
            local tierKey = tostring(r.qualityTier or "")
            setText(c, tr("dc_tier_" .. tierKey, tierKey ~= "" and tierKey or "--"))
            -- Honesty: Fresh with clock not started means spoilage path is inert, not a live timer.
            -- The row carries the spoilage KEY (DC-8/DC-14 invariant 3); translate it here.
            local spoilKey = tostring(r.spoilage or "")
            local spoilLabel = tr("dc_spoilage_" .. spoilKey, spoilKey)
            if r.spoilageClockStarted ~= true then
                spoilLabel = tr("dairy_rf_pda_spoil_clock_idle", "Fresh (clock not started)")
            end
            setText(d, spoilLabel)
            local warn = buildWarnFlavour(r)
            if warn ~= nil then
                warnBits[#warnBits + 1] = warn
            end
        else
            setVis(a, false); setVis(b, false); setVis(c, false); setVis(d, false)
        end
    end

    -- Also collect warn flavour from rows beyond the painted 8 so hints stay honest.
    for i = show + 1, #rows do
        local warn = buildWarnFlavour(rows[i])
        if warn ~= nil then
            warnBits[#warnBits + 1] = warn
        end
    end

    local moreParts = {}
    moreParts[#moreParts + 1] = string.format(tr("dairy_rf_pda_barns_n", "Barns: %d"), #rows)
    if anyRitterWithCounts(rows) then
        moreParts[#moreParts + 1] = tr("dairy_rf_pda_ritter", "Ritter")
    end
    if #rows > MAX_ROWS then
        moreParts[#moreParts + 1] = string.format(
            tr("dairy_rf_pda_more", "Showing %d of %d"),
            MAX_ROWS, #rows
        )
    end
    setText(moreEl, table.concat(moreParts, "  ·  "))

    local idleClock = false
    for _, r in ipairs(rows) do
        if r.spoilageClockStarted ~= true then
            idleClock = true
            break
        end
    end
    local hintParts = {}
    if idleClock then
        hintParts[#hintParts + 1] = tr(
            "dairy_rf_pda_hint_spoil_idle",
            "Spoilage clock not started - Fresh does not mean a live ageing timer yet."
        )
    end
    if #warnBits > 0 then
        hintParts[#hintParts + 1] = table.concat(warnBits, "; ")
    end
    setText(hintEl, table.concat(hintParts, " "))
end

function DairyRfPdaGuest.onHide() end

function DairyRfPdaGuest.tryRegister()
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            print("[Dairy] DairyRfPdaGuest: WARNING MOD_DIR nil - cannot ensureDoor")
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            if not doorOk then print("[Dairy] DairyRfPdaGuest: WARNING ensureDoor failed (will retry)") end
        end
    end
    local host = getHost()
    local registerFn = host and (host.registerModule or host.registerPanel)
    if host == nil or registerFn == nil then return false end
    if not _registered then
        local ok = registerFn(host, {
            id = PANEL_ID,
            title = tr("dairy_rf_pda_module_title", "Dairy"),
            blurb = tr("dairy_rf_pda_blurb", BLURB_FALLBACK),
            order = PANEL_ORDER,
            isAvailable = isDairyAvailable,
            onShow = DairyRfPdaGuest.onShow,
            onHide = DairyRfPdaGuest.onHide,
        })
        if ok then
            _registered = true
            print("[Dairy] DairyRfPdaGuest: registered module dairy on rfEscModules")
        else
            return false
        end
    end
    return _registered and g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
end

function DairyRfPdaGuest.isRegistered() return _registered end
function DairyRfPdaGuest.reset() _registered = false end
