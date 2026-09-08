-- =========================================================
-- DairyRfPdaGuest - Esc RF PDA Dairy framework (barn cards)
-- Soft-detect: mission.dairyCoreManager. isAvailable false when PF / disabled.
-- getBarnRows() for the read side. Densify 2026-08-05: Sale quality honesty.
-- DC-27 (BUILD 21:48): Herd now / Milk in tank from the server's breed surface
-- (version 1, strict local farm). No earned-tier invent, no best breed, no price.
-- BUILD 23:43 (Ash, George CLOSED DESIGN 23:27, Option B): one card per barn in the
-- 1140x428 content window, four cards a page (2 across x 2 down), the pager steps by
-- a full page, the sheet chrome is hidden for Dairy only and handed back on the way
-- out, and the feed fields live on the card. No side dump, no dialog on the way in.
-- Lua only paints elements the door XML declares; nothing is created at runtime.
-- BUILD 06:59 (Ash, George CLOSED DESIGN 06:50): the field picker comes off the card (no
-- soil N/P/K as feed, no Feed Fields footer), the freed Field slot carries the farm's
-- stored-feed readout from FeedProvenance (WAITING until the farm has harvest data), and
-- the side rail gets its Dairy teach back. Same XML, same ids; positions unchanged.
-- BUILD 11:40 (Ash, George CLOSED DESIGN 11:25): no breed chips. Herd now / Milk in tank are
-- in-card SmoothLists (the NPC Favor nest); extra rows stay in the table and scroll.
-- =========================================================

DairyRfPdaGuest = DairyRfPdaGuest or {}

local MOD_DIR = (DairyCoreModDirectory or g_currentModDirectory)
local MOD_NAME = (DairyCoreModName or g_currentModName)
local PANEL_ID = "dairy"
local PANEL_ORDER = 70
local MAX_ROWS = 8            -- the shared sheet's row count; Dairy hides every row
-- BUILD 17:13 (George CLOSED DESIGN 17:00): 2x2 barn cards, 555x200 each, in the 1140x428 bay.
local CARDS_PER_PAGE = 4      -- rfDairyCard1..4: 2 across by 2 down; empty slots hide
local CARD_SLOTS = 4          -- rfDairyCard1..4 exist in the ten doors
local TABLE_ROWS = 4          -- breed rows a herd or milk table shows per breed page (200px card)
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

--- Same walk, but a nil root goes straight to the host page. The chrome hand-back runs
--- from the registry listener and the availability poll, where no container is handed in.
local function findOnPage(root, id)
    if root ~= nil then return findDescendant(root, id) end
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

--- Human barn name (Tyson eyes-on 2026-08-08 shot 04: raw uniqueId is ugly).
--- George resolve ladder: go to the placeable via placeableSystem and take the first
--- non-empty real name, then fall back to a truncated id. Every step is pcall-guarded
--- and nil-safe: an unknown id or a missing placeableSystem must truncate, never throw.
--- Veto honoured: no invented row.barnName, no typeDesc, no LUADOC getName triple-trust.
--- BUILD 23:43: this is the one name ladder for the mod; the card title, the page hint
--- and FeedDesignationDialog's barn label all read it (DairyRfPdaGuest.barnLabel).
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
DairyRfPdaGuest.barnLabel = barnLabel

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
    -- BUILD 23:43: the hint names the barn the way the card does, never by uniqueId.
    return string.format("%s: %s", barnLabel(r), table.concat(bits, ", "))
end

-- ============================================================
-- DC-27 (BUILD 21:48): the breed surfaces, presentation only.
-- ============================================================
-- Two separate clocks per barn. "Herd now" is the milking headcount standing in the barn
-- today, by breed. "Milk in tank" is the stored milk by the breeds that produced it, with
-- unknown milk named as unknown. A new herd beside old milk is correct and stays that way.
-- Every value painted here is a server record DairyCoreManager already put on the row;
-- nothing is derived from local animals or Storage, and no breed is scored or priced.
local BREED_VERSION = 1
local UNKNOWN_TOKEN = "UNKNOWN"

--- Strict local farm id: a positive number or nil. Mirrors FT_DataProvider:getPlayerFarmIdStrict
--- in Farm Tablet so both surfaces gate the same way. Never falls back to 1; zero (spectator)
--- and anything that is not a number read as nil.
local function localFarmIdStrict()
    local id = nil
    if g_localPlayer ~= nil then
        if type(g_localPlayer.getFarmId) == "function" then
            local ok, v = pcall(function() return g_localPlayer:getFarmId() end)
            if ok then id = v end
        end
        if id == nil then id = g_localPlayer.farmId end
    end
    if id == nil and g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        local ok, v = pcall(function() return g_currentMission:getFarmId() end)
        if ok then id = v end
    end
    if type(id) == "number" and id > 0 then return id end
    return nil
end

--- A record is painted only when the server says it is available. Anything else is a state.
local function recordLive(rec)
    return type(rec) == "table" and rec.available == true and rec.trust == "server"
end

--- Reason for a record that is not paintable. A malformed record (no table, or available
--- without server trust) reads as an invalid snapshot, never as a value.
local function recordReason(rec)
    if type(rec) ~= "table" then return "SNAPSHOT_INVALID" end
    if rec.available == false and type(rec.reason) == "string" and rec.reason ~= "" then
        return rec.reason
    end
    return "SNAPSHOT_INVALID"
end

local function stateLabel(reason)
    local r = tostring(reason or "")
    if r == "WAITING_FOR_SERVER" then
        return tr("dairy_rf_pda_breed_waiting_server", "Waiting for server")
    elseif r == "WAITING_FOR_PLAYER_FARM" then
        return tr("dairy_rf_pda_breed_waiting_farm", "Waiting for player farm")
    elseif r == "UNRESOLVED_FILLTYPE" then
        return tr("dairy_rf_pda_breed_filltype_unresolved", "Fill type unresolved")
    elseif r == "NO_INTERNAL_STORAGE" then
        return tr("dairy_rf_pda_breed_storage_missing", "No internal storage")
    elseif r == "NON_SINGLE_STORAGE_ROUTE" then
        return tr("dairy_rf_pda_breed_route_unavailable", "Tank route unavailable")
    elseif r == "HERD_UNRESOLVED" then
        return tr("dairy_rf_pda_breed_herd_unresolved", "Herd unreadable")
    end
    return tr("dairy_rf_pda_breed_snapshot_invalid", "Snapshot invalid")
end

--- Breed label: the subtype's own fill type title (the game's name for the breed), else a
--- fill type by that name, else the raw token. The UNKNOWN token is localized.
local function breedLabel(key)
    local k = tostring(key or "")
    if k == "" or k == UNKNOWN_TOKEN then
        return tr("dairy_rf_pda_breed_unknown", "unknown")
    end
    local as = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if as ~= nil and type(as.getSubTypeByName) == "function" and g_fillTypeManager ~= nil
        and type(g_fillTypeManager.getFillTypeTitleByIndex) == "function" then
        local ok, st = pcall(function() return as:getSubTypeByName(k) end)
        if ok and type(st) == "table" and st.fillTypeIndex ~= nil then
            local ok2, title = pcall(function()
                return g_fillTypeManager:getFillTypeTitleByIndex(st.fillTypeIndex)
            end)
            if ok2 and type(title) == "string" and title ~= "" then return title end
        end
    end
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeByName) == "function" then
        local ok, ft = pcall(function() return g_fillTypeManager:getFillTypeByName(k) end)
        if ok and type(ft) == "table" and type(ft.title) == "string" and ft.title ~= "" then
            return ft.title
        end
    end
    return k
end

local function fillTypeLabel(name)
    local n = tostring(name or "")
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeByName) == "function" then
        local ok, ft = pcall(function() return g_fillTypeManager:getFillTypeByName(n) end)
        if ok and type(ft) == "table" and type(ft.title) == "string" and ft.title ~= "" then
            return ft.title
        end
    end
    return n
end

local function pct(f)
    return math.floor((tonumber(f) or 0) * 100 + 0.5)
end

local function headText(n)
    return string.format(tr("dairy_rf_pda_breed_head", "%d head"), math.floor((tonumber(n) or 0) + 0.5))
end

local function litresText(l)
    return string.format(tr("dairy_rf_pda_breed_litres", "%d L"), math.floor((tonumber(l) or 0) + 0.5))
end

--- Shares sorted for display: share descending, then name; unknown after an equal share.
--- Returns { key, frac, unknown } entries; zero shares are left out.
local function sortedShares(fractions, unknownShare)
    local list = {}
    if type(fractions) == "table" then
        for k, f in pairs(fractions) do
            local v = tonumber(f) or 0
            if v > 0 then
                local key = tostring(k)
                list[#list + 1] = { key = key, frac = v, unknown = (key == UNKNOWN_TOKEN) }
            end
        end
    end
    local u = tonumber(unknownShare) or 0
    if u > 0 then
        list[#list + 1] = { key = UNKNOWN_TOKEN, frac = u, unknown = true }
    end
    table.sort(list, function(a, b)
        if a.frac ~= b.frac then return a.frac > b.frac end
        if a.unknown ~= b.unknown then return not a.unknown end
        return a.key < b.key
    end)
    return list
end

--- The barn's tracked milk fill types, MILK first, then by name.
local function milkFillTypeNames(prov)
    local names = {}
    if type(prov) == "table" then
        for k, _ in pairs(prov) do names[#names + 1] = tostring(k) end
    end
    table.sort(names, function(a, b)
        if (a == "MILK") ~= (b == "MILK") then return a == "MILK" end
        return a < b
    end)
    return names
end

--- Strict farm gate. Keeps only rows carrying the DC-27 version and this farm's validated
--- breedSurfaceFarmId (never the legacy row.farmId). Also reports whether any dropped row
--- was still waiting for the server (a client without its mirror yet) and whether any row
--- carried a foreign version, so the empty state can say the true reason.
local function filterBreedRows(rows, farmId)
    local kept, waitingServer, badVersion = {}, false, false
    for _, r in ipairs(rows) do
        local versionOk = r.breedSurfaceVersion == BREED_VERSION
        if not versionOk then badVersion = true end
        if versionOk and farmId ~= nil and type(r.breedSurfaceFarmId) == "number"
            and r.breedSurfaceFarmId == farmId then
            kept[#kept + 1] = r
        elseif versionOk and r.breedSurfaceFarmId == nil then
            local h = r.herdBreedComposition
            if type(h) == "table" and h.available == false and h.reason == "WAITING_FOR_SERVER" then
                waitingServer = true
            end
        end
    end
    return kept, waitingServer, badVersion
end

-- ============================================================
-- BUILD 07:47: the breed tables.
-- ============================================================
-- A card is 555x380. Each table is a header line plus two multi-line Text columns at the
-- same pitch (names left, numbers right, TABLE_ROWS lines each), so every breed gets its
-- own row: name, head or litres, share. No "+N", no best breed, no price. A barn with more
-- rows than a table holds gets the in-card breed pager (XML-declared Buttons bound at paint
-- time), never a hidden remainder.

--- Herd table: header and { name, value } rows per breed, share descending. Zero head is
--- an empty table under a "0 head" header; a record that is not live paints its state in
--- the header and no rows.
local function herdTable(rec)
    local title = tr("dairy_rf_pda_breed_herd", "Herd now")
    if not recordLive(rec) then
        return string.format("%s: %s", title, stateLabel(recordReason(rec))), {}
    end
    local total = math.floor((tonumber(rec.totalMilkingHeadcount) or 0) + 0.5)
    local header = string.format("%s: %s", title, headText(total))
    local rows = {}
    if total <= 0 then return header, rows end
    for _, e in ipairs(sortedShares(rec.fractions, nil)) do
        local n = tonumber(type(rec.counts) == "table" and rec.counts[e.key]) or 0
        rows[#rows + 1] = { breedLabel(e.key), string.format("%s (%d%%)", headText(n), pct(e.frac)) }
    end
    return header, rows
end

--- Breed rows of one tracked fill type record. Unknown milk is a named row like any other.
local function milkRecordRows(rec, rows, indent)
    for _, e in ipairs(sortedShares(rec.fractions, rec.unknownShare)) do
        local l
        if e.unknown then
            l = tonumber(rec.unknownLitres) or 0
        else
            l = tonumber(type(rec.knownLitres) == "table" and rec.knownLitres[e.key]) or 0
        end
        rows[#rows + 1] = { indent .. breedLabel(e.key), string.format("%s (%d%%)", litresText(l), pct(e.frac)) }
    end
end

local function milkRecordValue(rec)
    if not recordLive(rec) then return stateLabel(recordReason(rec)), false end
    local litres = math.floor((tonumber(rec.litres) or 0) + 0.5)
    if litres <= 0 then return tr("dairy_rf_pda_breed_no_milk", "no milk stored"), false end
    return litresText(litres), true
end

--- Milk table. One tracked fill type is the common case: "Milk in tank: 1240 L" over its
--- breed rows. Several tracked fill types each get a section row (the fill type's name with
--- its litres or state) and their breed rows under it; nothing is folded into "+1".
local function milkTable(prov)
    local title = tr("dairy_rf_pda_breed_milk", "Milk in tank")
    local names = milkFillTypeNames(prov)
    if #names == 0 then
        return string.format("%s: %s", title, stateLabel("SNAPSHOT_INVALID")), {}
    end
    local rows = {}
    if #names == 1 then
        local rec = prov[names[1]]
        local value, live = milkRecordValue(rec)
        if live then milkRecordRows(rec, rows, "") end
        return string.format("%s: %s", title, value), rows
    end
    for _, name in ipairs(names) do
        local rec = prov[name]
        local value, live = milkRecordValue(rec)
        rows[#rows + 1] = { fillTypeLabel(name), value }
        if live then milkRecordRows(rec, rows, "  ") end
    end
    return title, rows
end

--- The line the sheet used to spend three columns on: health score, sale tier, spoilage.
--- An idle spoilage clock says so in two words; the page hint carries the longer sentence.
local function stateCardLine(r, scoreMax)
    local tierKey = tostring(r.qualityTier or "")
    local tierLabel = tr("dc_tier_" .. tierKey, tierKey ~= "" and tierKey or "--")
    local spoilLabel
    if r.spoilageClockStarted ~= true then
        spoilLabel = tr("dairy_rf_pda_card_spoil_idle", "clock idle")
    else
        local spoilKey = tostring(r.spoilage or "")
        spoilLabel = tr("dc_spoilage_" .. spoilKey, spoilKey ~= "" and spoilKey or "--")
    end
    return string.format("%s %d/%d, %s %s, %s %s",
        tr("dairy_rf_pda_col_health", "Herd Health"),
        math.floor(tonumber(r.herdHealth) or 0), scoreMax,
        tr("dairy_rf_pda_col_tier", "Sale quality"), tierLabel,
        tr("dairy_rf_pda_col_spoil", "Spoilage"), spoilLabel)
end

-- ============================================================
-- BUILD 06:59: the farm's stored feed on the card (FeedProvenance, read-only).
-- ============================================================
-- There is no per-barn trough value in the engine. FeedProvenance is per farm and per fill
-- type: quality is locked on the crop at the cut (contamination = the field's disease
-- pressure, organic = the field's certification), blended into the farm pool by amount, and
-- the trough draws from that pool: DairyCoreManager._applyTroughExposure reads
-- contaminatedFeedFraction and _barnOrganicFraction reads organicFeedFraction, both by the
-- barn's farm. So the card paints exactly those two farm-pool reads, labelled as the farm's
-- stored feed, and says WAITING while hasData(farmId) is false. No invented barn value, no
-- mixer average, no soil NPK, and feedDiseaseFlag / mycotoxin stay in the page hint as the
-- consequence they are. The pool is written on the server and persisted through the
-- savegame ledger, which a pure client does not have, so a client says that instead of
-- pretending the farm has never harvested.

local _pageIndex = 1
local _lastRowCount = 0

local function cardEl(container, slot, part)
    return findOnPage(container, "rfDairyCard" .. slot .. (part or ""))
end

local function serverSide(mgr)
    if mgr ~= nil and type(mgr._isServer) == "function" then
        local ok, v = pcall(function() return mgr:_isServer() end)
        if ok then return v == true end
    end
    return false
end

local function feedConstants()
    if DairyConstants ~= nil and type(DairyConstants.FEED_PROVENANCE) == "table" then
        return DairyConstants.FEED_PROVENANCE
    end
    return nil
end

--- Contamination fades by this share each in-game day (FeedProvenance.decayContaminated).
local function contaminationDecayPct()
    local c = feedConstants()
    if c ~= nil and type(c.CONTAMINATED_DECAY_PER_DAY) == "number" then
        return pct(c.CONTAMINATED_DECAY_PER_DAY)
    end
    return 15
end

--- The farm's stored-feed readout, two short lines (the Stored slot wraps whole words over
--- three), computed once per paint. It is a farm-pool read, so every barn card on the page
--- says the same thing, and that is the honest state.
local function troughCardText(mgr, farmId, isServer)
    local fp = mgr ~= nil and mgr.feedProvenance or nil
    local hasData = false
    if fp ~= nil and farmId ~= nil and type(fp.hasData) == "function" then
        local ok, v = pcall(function() return fp:hasData(farmId) end)
        hasData = ok and v == true
    end
    if not hasData then
        if not isServer then
            return tr("dairy_rf_pda_trough_server_only",
                "Stored feed: server only, no record on this client")
        end
        return tr("dairy_rf_pda_trough_waiting", "Stored feed: waiting for harvest data")
            .. "\n" .. tr("dairy_rf_pda_trough_waiting_why", "No cut recorded for this farm yet.")
    end
    local organic, contaminated = 0, 0
    pcall(function()
        organic = tonumber(fp:organicFeedFraction(farmId)) or 0
        contaminated = tonumber(fp:contaminatedFeedFraction(farmId)) or 0
    end)
    -- The ratified classification: organic only ABOVE the threshold share.
    local isOrganic = false
    if type(fp.isOrganicFeed) == "function" then
        local ok, v = pcall(function() return fp:isOrganicFeed(farmId) end)
        isOrganic = ok and v == true
    else
        local c = feedConstants()
        local threshold = (c ~= nil and type(c.ORGANIC_THRESHOLD) == "number") and c.ORGANIC_THRESHOLD or 0.8
        isOrganic = organic > threshold
    end
    local line1
    if isOrganic then
        line1 = string.format(tr("dairy_rf_pda_trough_organic",
            "Farm's stored feed: organic (%d%% organic share)"), pct(organic))
    else
        line1 = string.format(tr("dairy_rf_pda_trough_not_organic",
            "Farm's stored feed: not organic (%d%% organic share)"), pct(organic))
    end
    local line2
    if contaminated <= 0 then
        line2 = tr("dairy_rf_pda_trough_clean", "Contamination: none in the stored feed")
    elseif pct(contaminated) < 1 then
        line2 = string.format(tr("dairy_rf_pda_trough_trace",
            "Contamination: a trace, fading %d%% a day"), contaminationDecayPct())
    else
        line2 = string.format(tr("dairy_rf_pda_trough_contaminated",
            "Contamination: %d%% diseased, fading %d%% a day"),
            pct(contaminated), contaminationDecayPct())
    end
    return line1 .. "\n" .. line2
end

--- Buttons in the card block are ours alone: no engine glyph, no chord chip. The pager
--- buttons go through this too (the engine repaints the glyph on every setText otherwise).
local function stripButtonGlyph(btn)
    if btn == nil then return end
    btn.inputActionName = nil
    btn.keyDisplayText = nil
    btn.keyOverlay = nil
    btn.hideKeyboardGlyph = true
    btn.hasLoadedInputGlyph = false
    btn.isKeyboardMode = false
    btn.keyGlyphOffsetX = 0
    btn.keyGlyphSize = { 0, 0 }
    btn.iconSize = { 0, 0 }
    btn.icon = {}
end

-- ============================================================
-- BUILD 11:40 (George CLOSED DESIGN 11:25): the in-card herd / milk breed lists. No breed
-- chips: extra rows stay in the table and scroll. The NPC Favor nest and data source, copied:
-- eight SmoothLists (rfDairyCardNHerdList / rfDairyCardNMilkList) in the ten-door XML, one
-- data source told apart by list id, rows from the {name, value} pairs herdTable / milkTable
-- already return. setDataSource once per list, setDelegate explicitly, reloadData only on a
-- full show and only once the list is loaded (the thrash fence).
-- ============================================================
local _cardRows = {}      -- slot -> { herd = rows, milk = rows }
local _cardBarn = {}      -- slot -> barn key the headers and lists were last painted for

--- Slot and part from a list id: "rfDairyCard2MilkList" -> 2, "milk".
local function listSlotPart(list)
    local id = list ~= nil and list.id or nil
    if type(id) ~= "string" then return nil, nil end
    local slot, part = id:match("^rfDairyCard(%d)(%a+)List$")
    if slot == nil then return nil, nil end
    return tonumber(slot), string.lower(part)
end

local function listRows(list)
    local slot, part = listSlotPart(list)
    local card = slot ~= nil and _cardRows[slot] or nil
    local rows = card ~= nil and card[part] or nil
    if type(rows) ~= "table" then return {} end
    return rows
end

--- The one data source for the eight in-card SmoothLists (engine contract, SmoothListElement.lua:
--- one section by default, getNumberOfItemsInSection, populateCellForItemInSection; the single
--- ListItem template is the singular cell). Cells are the engine's clones of the XML template:
--- nothing is created here, only text set by name. A row pick paints nothing (read-only cards).
local dairyListSource = {}

function dairyListSource:getNumberOfItemsInSection(list, section)
    return #listRows(list)
end

function dairyListSource:populateCellForItemInSection(list, section, index, cell)
    if cell == nil or type(cell.getDescendantByName) ~= "function" then return end
    local row = listRows(list)[index]
    if row == nil then return end
    setText(cell:getDescendantByName("rfDairyBreedName"), row[1])
    setText(cell:getDescendantByName("rfDairyBreedVal"), row[2])
end

function dairyListSource:onListSelectionChanged(list, section, index)
end

--- setDataSource once per list element, by identity: the list is re-sourced only when its
--- dataSource is not this chunk's table (a flag on the element would outlive a re-sourced chunk);
--- setDelegate explicitly (the XML loader made the host page the delegate, the NPC Favor lesson);
--- reloadData only when asked and only once the engine has loaded the list (list.isLoaded).
local function syncList(container, id, reload)
    local list = findOnPage(container, id)
    if list == nil then return nil end
    if list.dataSource ~= dairyListSource and type(list.setDataSource) == "function" then
        list:setDataSource(dairyListSource)
        if type(list.setDelegate) == "function" then
            list:setDelegate(dairyListSource)
        end
        list._rfDairySourced = true
    end
    if reload and list.isLoaded and type(list.reloadData) == "function" then
        pcall(list.reloadData, list)
    end
    return list
end

-- The eight breed-pager Buttons of the doors before BUILD 11:40. Belt only: an old first-writer
-- door may still carry them, so every show hides, unlabels and disables whatever is found.
local DAIRY_CHIP_IDS = {
    "rfDairyCard1BreedPrev", "rfDairyCard1BreedNext", "rfDairyCard2BreedPrev", "rfDairyCard2BreedNext",
    "rfDairyCard3BreedPrev", "rfDairyCard3BreedNext", "rfDairyCard4BreedPrev", "rfDairyCard4BreedNext",
}
-- The sixteen multi-line breed Texts of the same old doors: blanked and hidden on the same belt,
-- so a Lua reload ahead of the XML restart never shows a frozen breed column.
local OLD_DOOR_TEXT_PARTS = { "HerdNames", "HerdVals", "MilkNames", "MilkVals" }

local function beltHideBreedChips(container)
    for _, id in ipairs(DAIRY_CHIP_IDS) do
        local el = findOnPage(container, id)
        if el ~= nil then
            setVis(el, false)
            el.rfChipLabel = nil
            if type(el.setDisabled) == "function" then el:setDisabled(true) end
        end
    end
    for slot = 1, CARD_SLOTS do
        for _, part in ipairs(OLD_DOOR_TEXT_PARTS) do
            local el = findOnPage(container, "rfDairyCard" .. slot .. part)
            if el ~= nil then
                setText(el, "")
                setVis(el, false)
            end
        end
    end
end

--- George's measured card: Name -6, State -32, Herd now header -52 and its list -72 (80px, four
--- 20px rows visible, the rest scroll), Milk in tank header -152 and its list -172, the stored-feed
--- readout -252. Nothing is created; every element is in the ten-door XML. Headers and lists are
--- set on a full show; the 2s light tick repaints Name / State / stored feed and leaves them, except
--- when the barn in this slot is not the one the lists were painted for (a barn arrived, moved or
--- was swapped between full shows): then this slot alone gets its headers and lists once. Change-
--- gated, never periodic: the thrash fence holds.
local function paintCard(container, slot, r, scoreMax, troughText, full)
    setText(cardEl(container, slot, "Name"), barnLabel(r))
    setText(cardEl(container, slot, "State"), stateCardLine(r, scoreMax))
    local barnKey = tostring(r.barnId or "?")
    if full or _cardBarn[slot] ~= barnKey then
        local herdHeader, herdRows = herdTable(r.herdBreedComposition)
        local milkHeader, milkRows = milkTable(r.milkBreedProvenance)
        _cardRows[slot] = { herd = herdRows, milk = milkRows }
        _cardBarn[slot] = barnKey
        setText(cardEl(container, slot, "HerdHead"), herdHeader)
        setText(cardEl(container, slot, "MilkHead"), milkHeader)
        syncList(container, "rfDairyCard" .. slot .. "HerdList", true)
        syncList(container, "rfDairyCard" .. slot .. "MilkList", true)
    end
    -- BUILD 20:36 (George CLOSED DESIGN 19:03): the 555x380 card is back, so the farm-wide
    -- stored-feed readout paints inside the card again (rfDairyCardNStored at -252, three lines).
    local stored = cardEl(container, slot, "Stored")
    setText(stored, troughText or "")
    setVis(stored, true)
end

-- ============================================================
-- BUILD 06:59: the side rail teach.
-- ============================================================
-- The host shows rfSideInfoShell for every framework module and paints an empty
-- rfSideInfoBody for anything that is not Soil or Crop Stress, on every chrome sync and
-- before the guest runs; the light tick calls only the guest. So the guest writes the body
-- on every show and that is the last word while Dairy is active; the host repaints the body
-- for whoever comes next. Short, and no breed list: the cards carry the numbers.
local SIDE_TEACH_FALLBACK = "Dairy\n\n"
    .. "One card per barn on your farm. Turn pages with , and . or the pager.\n\n"
    .. "Herd now is the milking herd in the barn today, by breed. Milk in tank is the stored "
    .. "milk by the breeds that made it. Milk with no breed record stays unknown. A new herd "
    .. "beside old milk is normal.\n\n"
    .. "Spoilage clock: starts when a collection is recorded. Clock idle means not started, "
    .. "so Fresh is not a live timer yet.\n\n"
    .. "Feed disease clock: diseased feed in the pool puts mycotoxin on the herd. It fades "
    .. "day by day. The page hint names the barn while it lasts.\n\n"
    .. "Stored feed: quality is locked on the crop at the cut and blended in the farm's silos. "
    .. "The trough draws from that pool and milk follows it. Organic means over 80% organic "
    .. "share. Waiting for harvest data until the first cut is recorded."

--- BUILD 20:36: the page hint (barn count, more-barns note, spoilage-clock note, mycotoxin
--- warnings) rides the side info under the teach text: two 380-tall card rows fill the 780 bay
--- and leave no band for rfDairyCardsHint, which stays declared and hidden.
local function paintSideTeach(container, tail)
    setVis(findDescendant(container, "rfSideInfoShell"), true)
    local body = tr("dairy_rf_pda_side_teach", SIDE_TEACH_FALLBACK)
    if type(tail) == "string" and tail ~= "" then
        body = body .. "\n\n" .. tail
    end
    setText(findDescendant(container, "rfSideInfoBody"), body)
end

-- ============================================================
-- BUILD 23:43: the shared sheet chrome, hidden for Dairy and handed back.
-- ============================================================
-- Income, Depot and NPC Favor paint the rfFwCol / rfFwRule / rfFwRow grid and set their own
-- row visibility on every show, but nobody touches the column headers or the hairlines, and
-- no host calls onHide. So Dairy hides them on the way in and gives exactly those back the
-- moment the registry says another module is active: on the change listener (selectModule,
-- register, unregister) and, as a belt for applyHomeModuleQuiet which does not notify, on the
-- availability poll every host refresh makes through getModules(). The rows are left to the
-- guest that owns the next show. Every card frame and the Dairy hint go dark at the same time.
local SHEET_HEADERS = {
    "rfFwColA", "rfFwColB", "rfFwColC", "rfFwColD",
}
-- BUILD 21:40 (George CLOSED DESIGN 21:35 item 5): the eleven hairlines of the old fixed
-- eight-row table. Nothing paints that grid any more - Income and Depot moved their rows into the
-- shared SmoothList at 17:21, this module uses cards and NPC Favor uses lists - so they are hidden
-- on the way in with the rest of the chrome and, unlike the column headers, they are NEVER handed
-- back. Handing them back is what left a second frame standing behind the Depot sheet.
local SHEET_RULES = {
    "rfFwRuleHead", "rfFwRuleRow1", "rfFwRuleRow2", "rfFwRuleRow3", "rfFwRuleRow4",
    "rfFwRuleRow5", "rfFwRuleRow6", "rfFwRuleRow7",
    "rfFwRuleCol1", "rfFwRuleCol2", "rfFwRuleCol3",
}
local _chromeHidden = false
local _listenerHost = nil

local function hideSheetChrome(container)
    for _, id in ipairs(SHEET_HEADERS) do
        setVis(findOnPage(container, id), false)
    end
    for _, id in ipairs(SHEET_RULES) do
        setVis(findOnPage(container, id), false)
    end
    -- BUILD 17:21: the shared table's rows now live in this list, so the list goes dark with the
    -- rest of the sheet. Nil-safe: an older door copy has no such id.
    setVis(findOnPage(container, "rfFwSheetBox"), false)
    for i = 1, MAX_ROWS do
        for _, c in ipairs({ "A", "B", "C", "D" }) do
            setVis(findOnPage(container, "rfFwRow" .. i .. c), false)
        end
    end
    setText(findOnPage(container, "rfFwMore"), "")
    setText(findOnPage(container, "rfFwHintTable"), "")
    _chromeHidden = true
end

local function restoreSheetChrome(container)
    for _, id in ipairs(SHEET_HEADERS) do
        setVis(findOnPage(container, id), true)
    end
    for slot = 1, CARD_SLOTS do
        setVis(cardEl(container, slot), false)
    end
    setVis(findOnPage(container, "rfDairyCardsHint"), false)
    _chromeHidden = false
end

local function handBackChromeIfLeft()
    if not _chromeHidden then return end
    local host = getHost()
    if host ~= nil and host.activeModuleId == PANEL_ID then return end
    restoreSheetChrome(nil)
end

local function isDairyAvailable()
    if _chromeHidden then pcall(handBackChromeIfLeft) end
    local mgr = getMgr()
    if mgr == nil then return false end
    if mgr.disabled == true then return false end
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then return false end
    return true
end

-- ============================================================
-- BUILD 23:43: the page pager (host rfFwPagePrev / rfFwPageNext, keys , and .).
-- ============================================================
local function pageCountFor(n)
    if n <= 0 then return 1 end
    return math.ceil(n / CARDS_PER_PAGE)
end

--- The host hides both shared pager Buttons on every refresh before the guest paints, so this
--- is the only thing that turns them on for Dairy. One page means no pager at all rather than
--- two dead buttons. The Next label carries the page position.
local function paintPager(container, pages)
    local prevEl = findOnPage(container, "rfFwPagePrev")
    local nextEl = findOnPage(container, "rfFwPageNext")
    local multi = pages > 1
    for _, el in ipairs({ prevEl, nextEl }) do
        if el ~= nil then
            stripButtonGlyph(el)
            if type(el.setVisible) == "function" then el:setVisible(multi) end
            if type(el.setDisabled) == "function" then el:setDisabled(not multi) end
        end
    end
    if not multi then return end
    setText(prevEl, tr("dairy_rf_pda_page_prev", "< Back"))
    stripButtonGlyph(prevEl)
    setText(nextEl, string.format(tr("dairy_rf_pda_page_next", "More (%d/%d) >"), _pageIndex, pages))
    stripButtonGlyph(nextEl)
end

---@param delta number -1 previous page, +1 next page
---@return boolean moved
function DairyRfPdaGuest.onPageStep(delta)
    local pages = pageCountFor(_lastRowCount)
    if pages <= 1 then
        return false
    end
    local step = tonumber(delta) or 0
    if step == 0 then
        return false
    end
    local target = _pageIndex + (step > 0 and 1 or -1)
    if target > pages then target = 1 end
    if target < 1 then target = pages end
    if target == _pageIndex then
        return false
    end
    _pageIndex = target
    return true
end

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
    -- BUILD 21:41: 0 / 0 is the PRE-16:32 baseline. The shared XML has had this title
    -- at 10 / -8 since the white-card inset, so the old reset handed it back to a place
    -- that no longer exists. Same miss Depot had.
    el:setPosition(GuiUtils.getNormalizedXValue("10px", 0), GuiUtils.getNormalizedYValue("-8px", 0))
    if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
end

-- ============================================================
-- BUILD 07:06: put the shared empty-hint box back.
-- ============================================================
-- rfFwEmptyHint is ONE element behind all nine doors. Income and Depot now shrink it to bay A
-- (10 / 280 / -68 / 22) so their empty notice sits in the first cell instead of running across
-- the grid. Without this an empty Income visited earlier in the same session leaves this
-- page's notice in a 280x22 box.
--
-- This page never uses bay A. It restores the XML numbers verbatim, every show, before the
-- text is set, so the notice is painted into a box that is already the right size.
local FW_HINT_X = "10px"
local FW_HINT_Y = "-68px"
local FW_HINT_W = "1120px"
local FW_HINT_H = "44px"

local function restoreFwEmptyHintBox(container)
    local el = findDescendant(container, "rfFwEmptyHint")
    if el == nil then
        return
    end
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedYValue) ~= "function"
        or type(GuiUtils.getNormalizedScreenValues) ~= "function" then
        return
    end
    el.textMaxNumLines = 2
    local norms = GuiUtils.getNormalizedScreenValues(FW_HINT_W .. " " .. FW_HINT_H)
    if type(norms) ~= "table" or norms[1] == nil or norms[2] == nil then
        return
    end
    if type(el.setSize) == "function" then
        el:setSize(norms[1], norms[2])
    end
    if type(el.setPosition) == "function" then
        el:setPosition(GuiUtils.getNormalizedXValue(FW_HINT_X, 0),
                       GuiUtils.getNormalizedYValue(FW_HINT_Y, 0))
        if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
    end
end

function DairyRfPdaGuest.onShow(container, lightOnly)
    beltHideBreedChips(container)
    local full = lightOnly ~= true
    restoreFwEmptyHintBox(container)
    resetFwTableTitlePos(container)
    clearHostDupes(container)
    showTableMode(container)
    setText(findDescendant(container, "rfFwTableTitle"), "")
    setVis(findDescendant(container, "rfFwTableTitle"), false)
    -- BUILD 23:43: the sheet goes dark for Dairy (handed back on the way out, see
    -- handBackChromeIfLeft). BUILD 06:59: the side rail is back with the Dairy teach; the
    -- host clears the body before this runs, so this is the last word on it for as long
    -- as Dairy is the active module.
    hideSheetChrome(container)
    paintSideTeach(container)

    -- DairyConstants.HERD.SCORE_MAX is the real bound DairyCoreManager clamps herdHealth
    -- to; read from the constant so the card line's denominator can never drift.
    local scoreMax = 100
    if DairyConstants ~= nil and DairyConstants.HERD ~= nil
        and type(DairyConstants.HERD.SCORE_MAX) == "number" then
        scoreMax = DairyConstants.HERD.SCORE_MAX
    end

    local mgr = getMgr()
    local allRows = {}
    if mgr ~= nil and type(mgr.getBarnRows) == "function" then
        allRows = mgr:getBarnRows() or {}
    end
    -- Strict farm gate BEFORE the count, the sort, the page cap and the paint. A nil farm
    -- id keeps every row out, and a row for another farm never reaches this page.
    local farmId = localFarmIdStrict()
    local rows, waitingServer, badVersion = filterBreedRows(allRows, farmId)
    sortBarnRows(rows)

    local emptyEl = findDescendant(container, "rfFwEmptyHint")
    local hintEl = findOnPage(container, "rfDairyCardsHint")

    if #rows == 0 then
        -- The empty state says why: no proven farm yet, a client still waiting for its
        -- mirror, a row carrying a foreign surface version, or simply no barns.
        local emptyText
        if farmId == nil then
            emptyText = stateLabel("WAITING_FOR_PLAYER_FARM")
        elseif waitingServer then
            emptyText = stateLabel("WAITING_FOR_SERVER")
        elseif badVersion then
            emptyText = stateLabel("SNAPSHOT_INVALID")
        else
            emptyText = tr("dairy_rf_pda_empty", "no barns")
        end
        setVis(emptyEl, true)
        setText(emptyEl, emptyText)
        for slot = 1, CARD_SLOTS do
            setVis(cardEl(container, slot), false)
        end
        if full then _cardRows = {}; _cardBarn = {} end
        _lastRowCount = 0
        _pageIndex = 1
        paintPager(container, 1)
        setText(hintEl, "")
        setVis(hintEl, false)
        return
    end

    setVis(emptyEl, false)
    setText(emptyEl, "")

    local n = #rows
    _lastRowCount = n
    local pages = pageCountFor(n)
    if _pageIndex > pages then _pageIndex = pages end
    if _pageIndex < 1 then _pageIndex = 1 end
    local first = (_pageIndex - 1) * CARDS_PER_PAGE
    local troughText = troughCardText(mgr, farmId, serverSide(mgr))

    -- One card per barn, in barn order, never a card cut in half: a page holds four whole
    -- barns (2x2 since BUILD 17:13) and an empty slot stays an honest empty (hidden frame),
    -- the hint below says how many barns sit on the pages after this one. The shared pager
    -- only appears past four barns (pageCountFor).
    if full then _cardRows = {}; _cardBarn = {} end
    local painted = 0
    for slot = CARDS_PER_PAGE + 1, CARD_SLOTS do
        setVis(cardEl(container, slot), false)
    end
    for slot = 1, CARDS_PER_PAGE do
        local r = rows[first + slot]
        local card = cardEl(container, slot)
        if r ~= nil then
            paintCard(container, slot, r, scoreMax, troughText, full)
            setVis(card, true)
            painted = painted + 1
        else
            setVis(card, false)
        end
    end
    paintPager(container, pages)

    local hintParts = {}
    hintParts[#hintParts + 1] = string.format(tr("dairy_rf_pda_barns_n", "Barns: %d"), n)
    local remaining = n - (first + painted)
    if remaining > 0 then
        hintParts[#hintParts + 1] = string.format(
            tr("dairy_rf_pda_card_more", "%d more barns after this page"), remaining)
    end
    local idleClock = false
    local warnBits = {}
    for _, r in ipairs(rows) do
        if r.spoilageClockStarted ~= true then idleClock = true end
        local warn = buildWarnFlavour(r)
        if warn ~= nil then warnBits[#warnBits + 1] = warn end
    end
    local tailParts = {}
    if idleClock then
        tailParts[#tailParts + 1] = tr(
            "dairy_rf_pda_hint_spoil_idle",
            "Spoilage clock not started - Fresh does not mean a live ageing timer yet."
        )
    end
    if #warnBits > 0 then
        tailParts[#tailParts + 1] = table.concat(warnBits, "; ")
    end
    -- BUILD 20:36: the hint (barns count and the more-barns note, then the spoilage-clock note
    -- and the mycotoxin warnings) rides the side info; the stored-feed readout is back on each
    -- card. rfDairyCardsHint stays declared, empty and hidden.
    local hintText = table.concat(hintParts, "  ")
    if #tailParts > 0 then
        hintText = hintText .. "\n" .. table.concat(tailParts, "  ")
    end
    setText(hintEl, "")
    setVis(hintEl, false)
    paintSideTeach(container, hintText)
end

function DairyRfPdaGuest.onHide()
    _pageIndex = 1
    _cardRows = {}
    _cardBarn = {}
end

--- Registry change: selectModule / registerModule / unregisterModule all notify. If Dairy was
--- the last painter and is no longer the active module, the sheet chrome goes back now.
local function onRegistryChanged()
    handBackChromeIfLeft()
end

--- BUILD 19:15: the Esc Help footer asks whichever module is showing to open its own guide, so
--- every companion ships and owns its own help instead of borrowing Soil's.
---@param container table|nil
function DairyRfPdaGuest.onOpenHelp(container)
    if DairyGuideDialog ~= nil and type(DairyGuideDialog.show) == "function" then
        DairyGuideDialog.show()
    end
end

function DairyRfPdaGuest.tryRegister()
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            print("[Dairy] DairyRfPdaGuest: WARNING MOD_DIR nil - cannot ensureDoor")
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            -- BUILD 19:15 (George CLOSED DESIGN 18:55 item 5): load this mod's Field Guide at the
            -- same moment the door itself loads. A GUI loaded from a mod directory later, once the
            -- mod's own file system context has closed, fails to open.
            if DairyGuideDialog ~= nil and type(DairyGuideDialog.register) == "function" then
                pcall(DairyGuideDialog.register, MOD_DIR)
            end
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
            -- BUILD 23:43: the host reads onPageStep off the registered descriptor
            -- (RfEscModules whitelist carries it since BUILD 14:04), so the shared pager
            -- and the , . keys step Dairy by a full page of two cards.
            onPageStep = DairyRfPdaGuest.onPageStep,
            onOpenHelp = DairyRfPdaGuest.onOpenHelp,
        })
        if ok then
            _registered = true
            print("[Dairy] DairyRfPdaGuest: registered module dairy on rfEscModules")
        else
            return false
        end
    end
    if _listenerHost ~= host and type(host.addChangeListener) == "function" then
        host:addChangeListener(onRegistryChanged)
        _listenerHost = host
    end
    return _registered and g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
end

function DairyRfPdaGuest.isRegistered() return _registered end
function DairyRfPdaGuest.reset()
    _registered = false
    _listenerHost = nil
    _chromeHidden = false
    _pageIndex = 1
    _lastRowCount = 0
    _cardRows = {}
    _cardBarn = {}
end
