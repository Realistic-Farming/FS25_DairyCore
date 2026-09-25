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
-- DC-14 slice C (brief v1.0 section 6, SDS v0.9; Wizard brief section 3): the shared
-- farm-office sheet (rfFwSheetBox / rfFwSheetList, rfFwSheetBand, rfSideInfoBody) is the
-- complete standalone floor for the collection-refusal explanation. Its rows come from the
-- one safe getter on every show and light tick, bound by barnKey; the band carries the full
-- past-tense sentence; the side rail keeps the selected barn's breed and feed truths. The
-- card premise and the removed pager ids are gone, as the brief retires them.
-- =========================================================

DairyRfPdaGuest = DairyRfPdaGuest or {}

local MOD_DIR = (DairyCoreModDirectory or g_currentModDirectory)
local PANEL_ID = "dairy"
local PANEL_ORDER = 70
local MAX_ROWS = 8            -- the old fixed sheet rows (rfFwRow1..8), hidden on every show
local CARD_SLOTS = 4          -- rfDairyCard1..4 exist in the ten doors; hidden on every show
local _registered = false

local function tr(key, fallback)
    -- MAINTENANCE row 99, the SoilFertilizer #973 shape. Gate on hasText, never on the
    -- returned string: getText never returns nil, and for an absent key it returns the
    -- sentence "Missing '<key>' in l10n<suffix>.xml" (I18N.lua:175-191), which the old
    -- prefix gate caught only by also refusing any real text that begins "Missing".
    -- Past hasText the return is opaque: type and non-empty, never inspected. g_i18n is
    -- read plainly: in this mod's environment it IS the mod-aware instance
    -- (mods.lua:453, modEnv.g_i18n = g_i18n:addModI18N(modName), I18N.lua:149-172); the
    -- engine sets no modEnv.i18n, so the branch that read it was dead.
    local i18n = g_i18n
    if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
        return fallback or key
    end
    local okHas, has = pcall(i18n.hasText, i18n, key)
    if not okHas or has ~= true then return fallback or key end
    local ok, text = pcall(i18n.getText, i18n, key)
    if not ok or type(text) ~= "string" or text == "" then return fallback or key end
    return text
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

-- ============================================================
-- DC-14 slice C: the collection sheet is the floor (brief v1.0 section 6).
-- ============================================================
-- The shared farm-office sheet the ten doors declare (rfFwSheetBox with rfFwSheetList and its
-- four cells, rfFwSheetBand, rfSideInfoBody, the host's onClickFwSheetRow delegation) carries
-- the strict local farm's collection rows. They are read from the one safe getter
-- (DairyCoreManager:getCollectionRefusalViews) on every show and every light tick, with a demand
-- pulse ("ESC") ahead of each read so a pure client's route fetches; nothing else starts a
-- request. Rows are sorted and bound by barnKey; barnLabel is display only, and when two visible
-- labels collide a short stable-key suffix is appended to the display alone. A row click selects
-- the key; the band carries the complete past-tense sentence plus the next-due or no-worker truth;
-- the side rail keeps the selected barn's herd, milk and stored-feed truths when the breed surface
-- has them. Selection clears when its row disappears, the strict farm changes, the view leaves
-- READY, or another module takes the door (the registry listener, which also ends demand at
-- once; the host never calls onHide). No card, no pager: the brief retires both.
local _sheetRows = {}         -- what the sheet was last painted with, sorted by barnKey
local _sheetContainer = nil
local _selectedKey = nil
local _lastSignature = nil
local _lastFarmId = nil
local _listenerHost = nil
local _viewListenerMgr = nil  -- the manager whose collection view listener this guest holds

local SHEET_RULES = {
    "rfFwRuleHead", "rfFwRuleRow1", "rfFwRuleRow2", "rfFwRuleRow3", "rfFwRuleRow4",
    "rfFwRuleRow5", "rfFwRuleRow6", "rfFwRuleRow7",
    "rfFwRuleCol1", "rfFwRuleCol2", "rfFwRuleCol3",
}

local dc14SheetSource = {}
function dc14SheetSource:getNumberOfItemsInSection(list, section)
    return #_sheetRows
end
function dc14SheetSource:populateCellForItemInSection(list, section, index, cell)
    if cell == nil or type(cell.getDescendantByName) ~= "function" then return end
    local row = _sheetRows[index]
    if row == nil then return end
    setText(cell:getDescendantByName("rfFwSheetA"), row.label)
    setText(cell:getDescendantByName("rfFwSheetB"), row.status)
    setText(cell:getDescendantByName("rfFwSheetC"), row.worker)
    setText(cell:getDescendantByName("rfFwSheetD"), row.due)
end
function dc14SheetSource:onListSelectionChanged(list, section, index)
end

--- In-game day and clock of a monotonic hour (DairyCoreManager:_nowHours is currentDay times
--- 24 plus the hour of day), for the localized "day %s at %s" strings.
local function dayClock(hours)
    local h = tonumber(hours)
    if h == nil or h ~= h or h < 0 or h == math.huge then return "?", "?" end
    local day = math.floor(h / 24)
    local rest = h - day * 24
    local hh = math.floor(rest)
    local mm = math.floor((rest - hh) * 60 + 0.5)
    if mm >= 60 then hh, mm = hh + 1, 0 end
    if hh >= 24 then hh, mm = 23, 59 end
    return tostring(day), string.format("%02d:%02d", hh, mm)
end

local ROW_REFUSED, ROW_UNAVAILABLE = 1, 2

--- The row code of a getter row: the producer's and the wire's rows carry `code`; a row
--- without one is read from its state name, and anything else is unavailable.
local function rowCode(r)
    local code = tonumber(r.code)
    if code == 0 or code == ROW_REFUSED or code == ROW_UNAVAILABLE then return code end
    local s = tostring(r.state or "")
    if s == "NONE_RECORDED" then return 0 end
    if s == "FEE_EXCEEDS_PRICE" then return ROW_REFUSED end
    return ROW_UNAVAILABLE
end

--- The four cells of one sheet row.
local function sheetCells(row)
    if row.code == ROW_REFUSED then
        row.status = tr("dc14_collection_row_refused", "Milk left behind")
    elseif row.code == ROW_UNAVAILABLE then
        row.status = tr("dc14_collection_row_unavailable", "Unavailable")
    else
        row.status = tr("dc14_collection_row_none", "No report")
    end
    if row.nextDueHours ~= nil then
        row.worker = tr("dc14_collection_worker_assigned", "Assigned")
        local d, c = dayClock(row.nextDueHours)
        row.due = string.format(tr("dc14_collection_due_cell", "day %s at %s"), d, c)
    else
        row.worker = tr("dc14_collection_worker_none", "None")
        row.due = ""
    end
end

--- The getter's rows as sheet rows: sorted by barnKey, labels made distinct with a short
--- stable-key suffix on the display only (never the key), the cells filled.
local function sheetRowsFrom(view)
    local rows = {}
    for _, r in ipairs(type(view) == "table" and view.rows or {}) do
        local key = r.barnKey
        if type(key) == "string" and key ~= "" then
            local label = r.barnLabel
            if type(label) ~= "string" or label == "" then label = "Barn " .. key:sub(math.max(1, #key - 3)) end
            local due = tonumber(r.nextDueHours)
            if due ~= nil and (due ~= due or due < 0) then due = nil end
            rows[#rows + 1] = { key = key, label = label, code = rowCode(r), attemptHours = tonumber(r.attemptHours), nextDueHours = due }
        end
    end
    table.sort(rows, function(a, b) return a.key < b.key end)
    local seen = {}
    for _, row in ipairs(rows) do seen[row.label] = (seen[row.label] or 0) + 1 end
    for _, row in ipairs(rows) do
        if seen[row.label] > 1 then
            row.label = row.label .. " (" .. row.key:sub(math.max(1, #row.key - 3)) .. ")"
        end
        sheetCells(row)
    end
    return rows
end

local function signatureOf(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        parts[#parts + 1] = row.key .. "|" .. row.label .. "|" .. tostring(row.code) .. "|" .. tostring(row.attemptHours) .. "|" .. tostring(row.nextDueHours)
    end
    return table.concat(parts, ";")
end

local function selectedRow()
    if _selectedKey == nil then return nil end
    for _, row in ipairs(_sheetRows) do
        if row.key == _selectedKey then return row end
    end
    return nil
end

local function clearSelection()
    _selectedKey = nil
end

--- The band under the sheet: the selected barn's complete sentence, past tense, with the
--- next-due or no-worker truth; hidden when nothing is selected.
local function paintBand(container)
    local band = findDescendant(container, "rfFwSheetBand")
    if band == nil then return end
    local row = selectedRow()
    if row == nil then
        setVis(band, false)
        setText(band, "")
        return
    end
    local lines = { row.label }
    if row.code == ROW_REFUSED then
        local d, c = dayClock(row.attemptHours)
        lines[#lines + 1] = string.format(tr("dc14_collection_fee_refused",
            "At the scheduled collection on day %s at %s, the milk remained because the handling fee met or exceeded the sale price at that attempt."), d, c)
    elseif row.code == ROW_UNAVAILABLE then
        lines[#lines + 1] = tr("dc14_collection_barn_unavailable", "Collection status unavailable for this barn.")
    else
        lines[#lines + 1] = tr("dc14_collection_no_report", "No collection-refusal report this session.")
    end
    if row.nextDueHours ~= nil then
        local d, c = dayClock(row.nextDueHours)
        lines[#lines + 1] = string.format(tr("dc14_collection_next_due", "Next collection due: day %s at %s."), d, c)
    else
        lines[#lines + 1] = tr("dc14_collection_no_worker", "No collection worker is currently assigned.")
    end
    setText(band, table.concat(lines, "\n"))
    setVis(band, true)
end

--- The breed-surface row of the selected barn (DC-27), when the surface has it for this farm.
local function breedRowFor(mgr, farmId, key)
    if mgr == nil or farmId == nil or type(mgr.getBarnRows) ~= "function" then return nil end
    local ok, all = pcall(mgr.getBarnRows, mgr)
    if not ok or type(all) ~= "table" then return nil end
    local rows = filterBreedRows(all, farmId)
    for _, r in ipairs(rows) do
        if tostring(r.barnId) == key then return r end
    end
    return nil
end

--- The side rail: the barn count and the warnings, then the selected barn's health, quality,
--- spoilage, herd, milk and stored-feed truths when the breed surface carries them.
local function paintSideRail(container, mgr, farmId, rows)
    setVis(findDescendant(container, "rfSideInfoShell"), true)
    local parts = {}
    parts[#parts + 1] = string.format(tr("dairy_rf_pda_barns_n", "Barns: %d"), #rows)
    local row = selectedRow()
    if row ~= nil then
        parts[#parts + 1] = ""
        parts[#parts + 1] = row.label
        local breed = breedRowFor(mgr, farmId, row.key)
        if breed ~= nil then
            local scoreMax = 100
            if DairyConstants ~= nil and DairyConstants.HERD ~= nil and type(DairyConstants.HERD.SCORE_MAX) == "number" then
                scoreMax = DairyConstants.HERD.SCORE_MAX
            end
            parts[#parts + 1] = stateCardLine(breed, scoreMax)
            local herdHeader, herdRows = herdTable(breed.herdBreedComposition)
            parts[#parts + 1] = herdHeader
            for _, hr in ipairs(herdRows) do parts[#parts + 1] = "  " .. hr[1] .. "  " .. hr[2] end
            local milkHeader, milkRows = milkTable(breed.milkBreedProvenance)
            parts[#parts + 1] = milkHeader
            for _, mr in ipairs(milkRows) do parts[#parts + 1] = "  " .. mr[1] .. "  " .. mr[2] end
            parts[#parts + 1] = troughCardText(mgr, farmId, serverSide(mgr))
            local warn = buildWarnFlavour(breed)
            if warn ~= nil then parts[#parts + 1] = warn end
            if breed.spoilageClockStarted ~= true then
                parts[#parts + 1] = tr("dairy_rf_pda_hint_spoil_idle",
                    "Spoilage clock not started - Fresh does not mean a live ageing timer yet.")
            end
        end
    end
    setText(findDescendant(container, "rfSideInfoBody"), table.concat(parts, "\n"))
end

--- The sheet's chrome on every show: the four column headings are Dairy's, the old fixed
--- rows, hairlines and cards are dark, the removed pager ids are never touched.
local function paintSheetChrome(container)
    setText(findOnPage(container, "rfFwColA"), tr("dc14_collection_heading_barn", "Barn"))
    setText(findOnPage(container, "rfFwColB"), tr("dc14_collection_heading_status", "Collection"))
    setText(findOnPage(container, "rfFwColC"), tr("dc14_collection_heading_worker", "Worker"))
    setText(findOnPage(container, "rfFwColD"), tr("dc14_collection_heading_next_due", "Next due"))
    for _, id in ipairs({ "rfFwColA", "rfFwColB", "rfFwColC", "rfFwColD" }) do
        setVis(findOnPage(container, id), true)
    end
    for _, id in ipairs(SHEET_RULES) do
        setVis(findOnPage(container, id), false)
    end
    for i = 1, MAX_ROWS do
        for _, c in ipairs({ "A", "B", "C", "D" }) do
            setVis(findOnPage(container, "rfFwRow" .. i .. c), false)
        end
    end
    for slot = 1, CARD_SLOTS do
        setVis(cardEl(container, slot), false)
    end
    setVis(findOnPage(container, "rfDairyCardsHint"), false)
    setText(findOnPage(container, "rfFwMore"), "")
    setText(findOnPage(container, "rfFwHintTable"), "")
end

--- setDataSource by identity, setDelegate explicitly (the XML loader made the host page the
--- delegate), reloadData only once the engine has loaded the list; the box shows only with rows.
local function syncSheet(container)
    local list = findDescendant(container, "rfFwSheetList")
    local box = findDescendant(container, "rfFwSheetBox")
    if list == nil then
        setVis(box, false)
        return false
    end
    if list.dataSource ~= dc14SheetSource and type(list.setDataSource) == "function" then
        list:setDataSource(dc14SheetSource)
    end
    if type(list.setDelegate) == "function" and list.delegate ~= dc14SheetSource then
        list:setDelegate(dc14SheetSource)
    end
    if list.isLoaded and type(list.reloadData) == "function" then
        pcall(list.reloadData, list)
    end
    return true
end

--- Slice B's synchronous clear (DairyCoreManager:_collectionClearLocalContext) runs its
--- listeners inside the farm-change handler, before it returns; this one clears the
--- guest's selection, rows and Esc paint at that moment (brief section 8), so the previous
--- farm's rows, band and rail never outlive the switch by a refresh. The next show or
--- light tick paints the new farm. Registered once per manager: the manager keeps its
--- listeners across its own route resets.
local function onCollectionViewCleared(reason)
    _selectedKey = nil
    _sheetRows, _lastSignature, _lastFarmId = {}, nil, nil
    local container = _sheetContainer
    if container == nil then return end
    setVis(findDescendant(container, "rfFwSheetBox"), false)
    paintBand(container)
    setText(findDescendant(container, "rfSideInfoBody"), "")
end

local function ensureViewListener(mgr)
    if mgr == nil or mgr == _viewListenerMgr or type(mgr.addCollectionViewListener) ~= "function" then return end
    local ok = pcall(mgr.addCollectionViewListener, mgr, onCollectionViewCleared)
    if ok then _viewListenerMgr = mgr end
end

--- The whole-view state as the hint text: updating, unavailable, settings off, no real farm.
local function stateText(view)
    if type(view) ~= "table" then return tr("dc14_collection_unavailable", "Collection status unavailable.") end
    if view.state == "WAITING" then return tr("dc14_collection_updating", "Updating collection status.") end
    if view.reason == "SETTINGS_OFF" then return tr("dc14_collection_settings_off", "Dairy simulation is off.") end
    if view.reason == "NO_REAL_FARM" then return tr("dc14_collection_no_real_farm", "Select or join a farm to view collection status.") end
    return tr("dc14_collection_unavailable", "Collection status unavailable.")
end

--- One refresh, full (a show) or light (the 2 s tick): pulse demand, read the getter, paint.
local function refreshSheet(container, full)
    local mgr = getMgr()
    _sheetContainer = container
    local emptyEl = findDescendant(container, "rfFwEmptyHint")
    local box = findDescendant(container, "rfFwSheetBox")
    local view = nil
    if mgr ~= nil then
        ensureViewListener(mgr)
        if type(mgr.pulseCollectionDemand) == "function" then pcall(mgr.pulseCollectionDemand, mgr, "ESC") end
        if type(mgr.getCollectionRefusalViews) == "function" then
            local ok, v = pcall(mgr.getCollectionRefusalViews, mgr)
            if ok then view = v end
        end
    end
    local farmId = localFarmIdStrict()
    if _lastFarmId ~= farmId then
        clearSelection()
        _lastFarmId = farmId
    end
    if type(view) ~= "table" or view.state ~= "READY" then
        _sheetRows, _lastSignature = {}, nil
        clearSelection()
        setVis(box, false)
        setVis(emptyEl, true)
        setText(emptyEl, stateText(view))
        paintBand(container)
        paintSideRail(container, mgr, farmId, {})
        return
    end
    local rows = sheetRowsFrom(view)
    local sig = signatureOf(rows)
    if _selectedKey ~= nil then
        local still = false
        for _, row in ipairs(rows) do if row.key == _selectedKey then still = true break end end
        if not still then clearSelection() end
    end
    if full or sig ~= _lastSignature then
        _sheetRows, _lastSignature = rows, sig
        syncSheet(container)
    end
    if #_sheetRows == 0 then
        setVis(box, false)
        setVis(emptyEl, true)
        setText(emptyEl, tr("dairy_rf_pda_empty", "no barns"))
    else
        setVis(emptyEl, false)
        setText(emptyEl, "")
        setVis(box, true)
    end
    paintBand(container)
    paintSideRail(container, mgr, farmId, _sheetRows)
end

local function isDairyAvailable()
    local mgr = getMgr()
    if mgr == nil then return false end
    if mgr.disabled == true then return false end
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then return false end
    return true
end

-- ============================================================
local BLURB_FALLBACK =
    "Collection status per barn, and the herd glance for the selected one. Read-only."

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
    paintSheetChrome(container)
    refreshSheet(container, full)
end

--- The host's 2 s light tick while Dairy is showing: pulse demand and repaint what changed.
function DairyRfPdaGuest.onLightTick(container)
    refreshSheet(container or _sheetContainer, false)
end

--- The host's onClickFwSheetRow hands the clicked row's index; the row binds by its stable
--- key, the band and the side rail follow.
---@param index number row index into the rows the sheet was last painted with
function DairyRfPdaGuest.onSheetRow(index)
    local row = _sheetRows[tonumber(index) or 0]
    if row == nil then
        clearSelection()
    else
        _selectedKey = row.key
    end
    local container = _sheetContainer
    if container == nil then return end
    paintBand(container)
    paintSideRail(container, getMgr(), localFarmIdStrict(), _sheetRows)
end

function DairyRfPdaGuest.onHide()
    clearSelection()
    _sheetRows, _lastSignature = {}, nil
end

--- Registry change: selectModule / registerModule / unregisterModule all notify. When Dairy is
--- no longer the active module its selection clears and its demand ends at once (brief section
--- 8: registry and app-switch listeners end demand; the host never calls onHide).
local function onRegistryChanged()
    local host = getHost()
    if host ~= nil and host.activeModuleId == PANEL_ID then return end
    clearSelection()
    -- The detail goes with the selection: no host calls onHide, and the band must not sit
    -- under the next module's headers (the host darkens it on its refresh; this is the belt).
    if _sheetContainer ~= nil then paintBand(_sheetContainer) end
    local mgr = getMgr()
    if mgr ~= nil and type(mgr.endCollectionDemand) == "function" then
        pcall(mgr.endCollectionDemand, mgr, "ESC")
    end
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
            -- DC-14 slice C: the shared sheet's row click and the host's light tick both
            -- reach this guest through the registry's descriptor (the whitelist carries both).
            onSheetRow = DairyRfPdaGuest.onSheetRow,
            onLightTick = DairyRfPdaGuest.onLightTick,
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
    _sheetRows = {}
    _sheetContainer = nil
    _selectedKey = nil
    _lastSignature = nil
    _lastFarmId = nil
    _viewListenerMgr = nil
end
