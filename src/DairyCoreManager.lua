-- =========================================================
-- FS25_DairyCore - central manager
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Owns the per-barn dairy simulation and every cross-mod edge. All companion
-- reads are handle-gated + pcall-wrapped and degrade to neutral when a mod is
-- absent. Cadence rides the Time Guard clock (rule 10). Money is moved only by
-- the base game addMoney (server); TaxMod recordExpense is audit-only.
-- =========================================================

DairyCoreManager = {}
local DairyCoreManager_mt = Class(DairyCoreManager)

DairyCoreManager.LEDGER_BARNS     = "DairyCore_BarnState"
DairyCoreManager.LEDGER_CONTRACTS = "DairyCore_Contracts"
DairyCoreManager.SAVE_FILE        = "FS25_DairyCore.xml"      -- own-file fallback

-- Gated (F12): a rough per-cow daily yield used only to accrue contract delivery
-- until the SDK base litersPerDay age-curve is confirmed by Tyson.
local PER_COW_LITRES_DAY = 22

function DairyCoreManager.new()
    local self = setmetatable({}, DairyCoreManager_mt)
    self.barns        = {}      -- barnId -> barn record
    self.contracts    = {}      -- contractId -> contract record
    self.nextContractId = 1
    self.disabled     = false   -- true when Precision Farming is present
    self.bedrockBound = false
    self.clockBound   = false
    self.actionsBound = false
    self.settings = {
        enabled                 = true,
        defaultCollectionInterval = DairyConstants.COLLECTION.DEFAULT_INTERVAL_HOURS,
        spoilageEnabled         = true,
        contractsEnabled        = true,
        saleMargin              = DairyConstants.SALE.DEFAULT_MARGIN,
    }
    -- FP-1: the feed provenance ledger (authority #5). DairyCore is the sole writer.
    self.feedProvenance = FeedProvenance.new(self)
    return self
end

-- =========================================================
-- Lifecycle
-- =========================================================

function DairyCoreManager:onMissionLoaded()
    -- Zero Precision Farming compatibility: stand down fully if PF is present.
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then
        self.disabled = true
        DCLogger.info("Precision Farming detected - DairyCore standing down")
        return
    end

    RLBridge:init()
    self:_bindBedrock()

    local ledger = self:_getLedger()
    if ledger == nil then
        self:_loadOwnFile()
    end

    self:_subscribeClock()
    self:_bindActions()
    self:discoverBarns()
    -- FP-1: subscribe to SF's soilHarvestBus on the server so grain harvests seed
    -- the farm's feed provenance. Delegate-when-present and read-only.
    self:_bindHarvestBus()

    -- Trailer-transfer completion (Ritter mode, Integration 29C): base-game event.
    pcall(function()
        if g_messageCenter ~= nil and AnimalMoveEvent ~= nil then
            g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMoved, self)
            self.animalMoveBound = true
        end
    end)

    DCLogger.info("DairyCore active (%s mode, %d barn(s))",
        RLBridge.active and "Ritter" or "Standard", self:_countBarns())
end

function DairyCoreManager:onMissionDelete()
    if self.animalMoveBound and g_messageCenter ~= nil then
        pcall(function() g_messageCenter:unsubscribeAll(self) end)
    end
    self:_unbindHarvestBus()
    self.bedrockBound = false
    self.clockBound   = false
end

function DairyCoreManager:update(dt)
    if not self.bedrockBound then self:_bindBedrock() end
    if not self.clockBound then self:_subscribeClock() end
end

function DairyCoreManager:save()
    if self:_getLedger() ~= nil then return end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    self:_saveOwnFile()
end

function DairyCoreManager:_isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function DairyCoreManager:_countBarns()
    local n = 0
    for _ in pairs(self.barns) do n = n + 1 end
    return n
end

-- =========================================================
-- Barn discovery
-- =========================================================

-- A dairy barn is a husbandry placeable that produces milk (spec_husbandryMilk).
function DairyCoreManager:_isDairyBarn(placeable)
    return placeable ~= nil and placeable.spec_husbandryMilk ~= nil
end

-- A farm id that owns things, as opposed to the engine's reserved ids. Read from
-- FarmManager when it is loaded so we inherit any change, with the shipped values as
-- the fallback. SINGLEPLAYER_FARM_ID (1) is a REAL farm and is deliberately kept.
function DairyCoreManager:_isRealFarmId(farmId)
    if type(farmId) ~= "number" or farmId <= 0 then return false end
    local fm = FarmManager
    local spectator = (fm ~= nil and fm.SPECTATOR_FARM_ID) or 0
    local tour      = (fm ~= nil and fm.GUIDED_TOUR_FARM_ID) or 14
    local invalid   = (fm ~= nil and fm.INVALID_FARM_ID) or 15
    return farmId ~= spectator and farmId ~= tour and farmId ~= invalid
end

-- Every farm whose barns this machine should look for.
--
-- F75, certified against dataS. `FSBaseMission:getFarmId` returns NIL on a dedicated
-- server: `getIsServer()` is true, there is no `g_localPlayer` (BaseMission.lua:272
-- nils it, PlayerSystem.lua:206 is the only setter), and with no connection argument
-- the first branch returns nil (FSBaseMission.lua:1067-1086). The old
-- `mission:getFarmId() or 1` therefore resolved to a HARDCODED 1 on every dedicated
-- server, so only farm 1's barns were ever discovered. Every other farm had no dairy
-- at all: no barns, no contracts, no simulation, and nothing on screen saying so.
--
-- The fix is not a better way to answer "which farm am I". A barn belongs to the farm
-- that OWNS THE PLACEABLE, not to whoever happens to be looking at it, so discovery
-- runs per owning farm.
function DairyCoreManager:_farmIdsToScan()
    local ids, seen = {}, {}
    pcall(function()
        local fm = g_farmManager
        if fm == nil or fm.getFarms == nil then return end
        for _, farm in pairs(fm:getFarms() or {}) do
            local id = farm ~= nil and farm.farmId or nil
            if id ~= nil and not seen[id] and self:_isRealFarmId(id) then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end)
    if #ids > 0 then return ids end

    -- No farm manager, or it holds nothing yet. Fall back to this machine's own farm,
    -- and keep the guarantee the whole function exists to make: NEVER hand nil to
    -- getPlaceablesByFarm. It resolves `farmId or g_localPlayer.farmId`, and on a
    -- dedicated server g_localPlayer is nil, so a nil id raises there. The old `or 1`
    -- caused the bug AND happened to prevent that crash; this keeps the crash covered
    -- without pretending everyone is farm 1.
    local localId = nil
    pcall(function()
        if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
            localId = g_currentMission:getFarmId()
        end
    end)
    if self:_isRealFarmId(localId) then return { localId } end
    return {}
end

function DairyCoreManager:discoverBarns()
    if self.disabled then return end
    local mission = g_currentMission
    if mission == nil or mission.husbandrySystem == nil then return end
    local hs = mission.husbandrySystem

    -- Clear every transient placeable ref so reconcile can tell a barn that was not
    -- re-registered this pass (sold, demolished) from one that was.
    for _, barn in pairs(self.barns) do
        barn._placeable = nil
    end

    if hs.getPlaceablesByFarm ~= nil then
        for _, farmId in ipairs(self:_farmIdsToScan()) do
            local placeables = nil
            pcall(function() placeables = hs:getPlaceablesByFarm(farmId) end)
            self:_registerBarnsFrom(placeables, farmId)
        end
    else
        -- No per-farm enumerator. Take the whole set once and let each placeable name its
        -- own owner, which is the same question asked a different way.
        self:_registerBarnsFrom(hs.placeables or hs.husbandries, nil)
    end

    -- DC-9 repair 5 + the milk-round listeners: drop records that are provably dead,
    -- clear the rota on a farm change, and start watching every live barn's storage.
    self:_reconcileBarns()
    for _, barn in pairs(self.barns) do
        self:_attachStorageListeners(barn)
    end
end

--- @param placeables table|nil
--- @param queriedFarmId number|nil  the farm this set was asked for, when it was
function DairyCoreManager:_registerBarnsFrom(placeables, queriedFarmId)
    for _, placeable in pairs(placeables or {}) do
        if self:_isDairyBarn(placeable) then
            local ok, barnId = pcall(function() return placeable:getUniqueId() end)
            if ok and barnId ~= nil then
                -- The placeable's own owner is the authority. The queried id only
                -- stands in when the getter is missing, and the two cannot disagree
                -- when both exist, because getPlaceablesByFarm filters on that getter.
                local farmId = nil
                pcall(function()
                    if placeable.getOwnerFarmId ~= nil then farmId = placeable:getOwnerFarmId() end
                end)
                if not self:_isRealFarmId(farmId) then farmId = queriedFarmId end
                if self:_isRealFarmId(farmId) then
                    self:_getOrCreateBarn(barnId, farmId, placeable)
                end
            end
        end
    end
end

function DairyCoreManager:_getOrCreateBarn(barnId, farmId, placeable)
    local barn = self.barns[barnId]
    if barn == nil then
        barn = {
            barnId = barnId,
            farmId = farmId,
            herdHealthScore = 60,
            milkQualityTier = "standard",
            milkLitresAvailable = 0,
            lastCollectionDay = nil,
            spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key,
            feedSourceFields = {},
            feedDiseaseFlag = false,
            feedDiseaseCropName = nil,
            mycotoxinPenalty = 0,
            mycotoxinDaysLeft = 0,
            collectionInterval = self.settings.defaultCollectionInterval,
            nextCollectionDue = nil,
            assignedWorkerId = nil,
            -- DC-9 milk-round detection state. `lastKnownMilkLevel` is the previous
            -- observed level; a drop is a collection, a rise is production. The rota
            -- and the office record their own collections and re-seed it in the same
            -- step so the passive detector never re-counts a sale it made.
            lastKnownMilkLevel = {},     -- fillType -> last observed litres
            lastCollectionHours = nil,   -- monotonic hour of the last collection (DC-8)
            lastCollectionSource = nil,  -- self / hauled / rota / office
            lastCollectionLitres = {},   -- fillType -> litres of the last collection
            rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED,
            _suppressDetection = false,  -- transient: an active rota/office sale is mid-flight
            activeContractId = nil,
            ritterMode = RLBridge.active,
        }
        self.barns[barnId] = barn
    end
    barn.farmId = farmId or barn.farmId
    barn._placeable = placeable  -- transient runtime reference, not saved
    return barn
end

-- =========================================================
-- Companion read helpers (all handle-gated + pcall; neutral when absent)
-- =========================================================

function DairyCoreManager:_getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
end
function DairyCoreManager:_getNetworkSync()
    return (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
end
function DairyCoreManager:_getSettingsHub()
    return (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
end
function DairyCoreManager:_getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
end

-- SoilFertilizer field info via the .soilSystem hop (getFieldInfo lives on the system).
function DairyCoreManager:_getFieldInfo(fieldId)
    local sf = g_currentMission ~= nil and g_currentMission.soilFertilityManager
    if sf == nil or sf.soilSystem == nil then return nil end
    local ok, info = pcall(function() return sf.soilSystem:getFieldInfo(fieldId) end)
    return ok and info or nil
end

-- MarketDynamics live spot price for milk; base-game price when absent.
function DairyCoreManager:_milkSpotPrice()
    local price = nil
    pcall(function()
        local md = g_currentMission ~= nil and g_currentMission.MarketDynamics
        local ftm = g_fillTypeManager
        local ftIndex = ftm ~= nil and ftm:getFillTypeIndexByName(DairyConstants.CONTRACTS.MILK_FILLTYPE) or nil
        if md ~= nil and md.marketEngine ~= nil and ftIndex ~= nil and md.marketEngine.getPrice ~= nil then
            price = md.marketEngine:getPrice(ftIndex)
        elseif ftm ~= nil and ftIndex ~= nil then
            local desc = ftm:getFillTypeByIndex(ftIndex)
            price = desc ~= nil and desc.pricePerLiter or nil
        end
    end)
    return price or 1.0
end

-- MarketDynamics crash-proof BASE price snapshot for milk; base-game price when
-- absent. entry.base is the vanilla base price MarketDynamics snapshots at init and
-- refreshes daily from the seasonal curve, so a market crash (which only moves the
-- volatility factor on top of base, clamped to [0.50, 2.00]) cannot drag it down.
-- DC-16 anchors the settlement floor here, read as a pull at pay time, never a
-- subscription and never a live spot read.
function DairyCoreManager:_milkBasePrice()
    local base = nil
    pcall(function()
        local md = g_currentMission ~= nil and g_currentMission.MarketDynamics
        local ftm = g_fillTypeManager
        local ftIndex = ftm ~= nil and ftm:getFillTypeIndexByName(DairyConstants.CONTRACTS.MILK_FILLTYPE) or nil
        if ftIndex ~= nil then
            if md ~= nil and md.marketEngine ~= nil and md.marketEngine.prices ~= nil then
                local entry = md.marketEngine.prices[ftIndex]
                if entry ~= nil and entry.base ~= nil then base = entry.base end
            end
            if base == nil then
                local desc = ftm:getFillTypeByIndex(ftIndex)
                base = desc ~= nil and desc.pricePerLiter or nil
            end
        end
    end)
    return base or 1.0
end

-- RandomWorldEvents: the new top-level getActiveEvent() -> {name,intensity,category,remainingMs}.
function DairyCoreManager:_rweActiveEvent()
    local ev = nil
    pcall(function()
        local rwe = g_currentMission ~= nil and g_currentMission.randomWorldEvents
        if rwe ~= nil and rwe.getActiveEvent ~= nil then
            ev = rwe:getActiveEvent()
        end
    end)
    return ev  -- nil when nothing active
end

-- MarketDynamics active world event ids (for livestock_boom milk premium).
function DairyCoreManager:_mdEventActive(eventId)
    local active = false
    pcall(function()
        local md = g_currentMission ~= nil and g_currentMission.MarketDynamics
        if md ~= nil and md.worldEvents ~= nil and md.worldEvents.getActiveEvents ~= nil then
            for _, e in ipairs(md.worldEvents:getActiveEvents() or {}) do
                if e.id == eventId then active = true break end
            end
        end
    end)
    return active
end

-- ProStaff ladder getter, pcall-wrapped, neutral fallback.
function DairyCoreManager:_proStaff(getterName, fallback, ...)
    local args = { ... }
    local result = fallback
    pcall(function()
        local ps = g_currentMission ~= nil and g_currentMission.proStaffManager
        if ps ~= nil and ps[getterName] ~= nil then
            result = ps[getterName](ps, unpack(args))
        end
    end)
    return result
end

function DairyCoreManager:_proStaffLevel()
    return self:_proStaff("getLevel", 0)
end

-- WorkerCosts: resolve the assigned collection worker's skill level name for a barn.
-- DC-9 repair 1: WorkerCosts publishes CAPITALISED level names and the SKILL table is
-- keyed lowercase, so every worker used to fall through to the default. Normalise at
-- the read, coercing to string FIRST (the roster can put a number in `level`), never
-- re-keying the table.
function DairyCoreManager:_workerLevelName(barn)
    local levelName = "experienced"  -- neutral default
    pcall(function()
        local wc = g_currentMission ~= nil and g_currentMission.workerCostsManager
        if wc == nil then return end
        local snap = wc.getRosterSnapshot ~= nil and wc:getRosterSnapshot() or nil
        if snap == nil or snap.workers == nil then return end
        for _, w in ipairs(snap.workers) do
            if barn.assignedWorkerId ~= nil and w.uuid == barn.assignedWorkerId then
                local raw = w.levelName or w.level or levelName
                levelName = tostring(raw):lower()
                return
            end
        end
    end)
    return levelName
end

-- DC-9 rota state: the three-way lifecycle sort over the assigned worker. HireHall
-- publishes eight lifecycle states; six mean still-on-the-round (including injured
-- and onLeave, because HireHallEvolution auto-moves a worker to onLeave at fatigue
-- 95), two (retired, fired) mean the man is gone, and anything unknown or absent is
-- treated as still on the round. UNKNOWN-OR-ABSENT reads as still-on-round by
-- design: a roster that does not carry a lifecycle field, or carries one this mod
-- has never seen, must not silently lapse a round.
function DairyCoreManager:_workerRotaState(barn)
    if barn.assignedWorkerId == nil then
        return DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
    end
    local lifecycle = nil
    pcall(function()
        local wc = g_currentMission ~= nil and g_currentMission.workerCostsManager
        if wc == nil then return end
        local snap = wc.getRosterSnapshot ~= nil and wc:getRosterSnapshot() or nil
        if snap == nil or snap.workers == nil then return end
        for _, w in ipairs(snap.workers) do
            if w.uuid == barn.assignedWorkerId then
                lifecycle = w.lifecycleState
                return
            end
        end
    end)
    if lifecycle ~= nil then
        local lower = tostring(lifecycle):lower()
        if DairyConstants.COLLECTION.TERMINAL_STATES[lower] then
            return DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_DEPARTED
        end
    end
    return DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_OK
end

-- TaxMod audit line (bookkeeping only; never moves money). Sign: +credit / -debit.
function DairyCoreManager:_taxAudit(farmId, amount, label)
    pcall(function()
        local tm = g_currentMission ~= nil and g_currentMission.taxManager
        if tm ~= nil and tm.recordExpense ~= nil then
            tm:recordExpense(farmId, amount, label)
        end
    end)
end

-- =========================================================
-- Herd health
-- =========================================================

function DairyCoreManager:updateAllBarns(currentDay)
    if self.disabled or not self.settings.enabled then return end
    self:discoverBarns()  -- refresh: barns can be built/sold between days
    for _, barn in pairs(self.barns) do
        self:_updateBarnHealth(barn)
        self:_decayMycotoxin(barn)
        -- DC-8: spoilage no longer lives on the day tick. It evaluates once per
        -- in-game hour on the hour tick, where the fractional elapsed-time read
        -- has the hours it needs. The day tick keeps herd health and the mycotoxin
        -- countdown, and nothing here competes with the hour tick.
    end
end

function DairyCoreManager:_updateBarnHealth(barn)
    local score
    if RLBridge.active then
        score = RLBridge:computeHerdScore(barn.barnId, barn.farmId)
        barn.ritterMode = true
    end
    if score == nil then
        score = self:_herdScoreStandard(barn)
        barn.ritterMode = false
    end

    -- ProStaff global effectiveness (L20 supersedes L19; do not stack).
    local level = self:_proStaffLevel()
    if level >= 20 then
        score = score * DairyConstants.PROSTAFF.L20_GLOBAL
    elseif level >= 19 then
        score = score * DairyConstants.PROSTAFF.L19_GLOBAL
    end

    barn.herdHealthScore = math.max(DairyConstants.HERD.SCORE_MIN,
                                    math.min(DairyConstants.HERD.SCORE_MAX, score))
    barn.milkQualityTier = self:_qualityTierForScore(barn.herdHealthScore).key
end

-- Standard mode: base-game globalProductionFactor + SoilFertilizer feed-field
-- modifiers + mycotoxin penalty + ProStaff L12 quality bump.
function DairyCoreManager:_herdScoreStandard(barn)
    local base = 60
    pcall(function()
        if barn._placeable ~= nil and barn._placeable.getGlobalProductionFactor ~= nil then
            local gpf = barn._placeable:getGlobalProductionFactor()  -- 0..1
            if type(gpf) == "number" then base = gpf * 100 end
        end
    end)

    local score = base
    local qualityBonus = 0

    -- SoilFertilizer reads on designated feed fields only.
    local balancedAll, anyLowOM, anySevereOM, anyWeed, anyLegume = true, false, false, false, false
    local hasFields = false
    for fieldId in pairs(barn.feedSourceFields) do
        hasFields = true
        local info = self:_getFieldInfo(fieldId)
        if info ~= nil then
            local om = info.organicMatter or 5
            if om < DairyConstants.HERD.OM_SEVERE then anySevereOM = true
            elseif om < DairyConstants.HERD.OM_DEPLETED then anyLowOM = true end
            local nStatus = info.nitrogen and info.nitrogen.status
            local pStatus = info.phosphorus and info.phosphorus.status
            local kStatus = info.potassium and info.potassium.status
            if not (nStatus == "Good" and pStatus == "Good" and kStatus == "Good") then
                balancedAll = false
            end
            if (info.weedPressure or 0) > DairyConstants.HERD.WEED_PRESSURE_LIMIT then anyWeed = true end
            if type(info.rotationStatus) == "string" and info.rotationStatus:lower():find("legume") then
                anyLegume = true
            end
        else
            balancedAll = false
        end
    end

    if hasFields then
        if balancedAll then score = score + DairyConstants.HERD.BALANCED_NPK_BONUS end
        if anySevereOM then score = score - DairyConstants.HERD.OM_SEVERE_PEN
        elseif anyLowOM then score = score - DairyConstants.HERD.OM_DEPLETED_PEN end
        if anyWeed then qualityBonus = qualityBonus - DairyConstants.HERD.WEED_QUALITY_PEN end
        if anyLegume then qualityBonus = qualityBonus + DairyConstants.HERD.LEGUME_QUALITY_FLOOR_BONUS end
    end

    -- Mycotoxin penalty (both modes).
    score = score - (barn.mycotoxinPenalty or 0)

    -- ProStaff L12 precision agronomy: +5% feed crop quality.
    if self:_proStaffLevel() >= 12 then
        qualityBonus = qualityBonus + (base * (DairyConstants.PROSTAFF.L12_QUALITY - 1.0))
    end

    return score + qualityBonus
end

-- =========================================================
-- Milk quality + spoilage
-- =========================================================

function DairyCoreManager:_qualityTierForScore(score)
    for _, tier in ipairs(DairyConstants.QUALITY.TIERS) do
        if score >= tier.minScore then return tier end
    end
    return DairyConstants.QUALITY.TIERS[#DairyConstants.QUALITY.TIERS]
end

function DairyCoreManager:_tierIndexByKey(key)
    for i, tier in ipairs(DairyConstants.QUALITY.TIERS) do
        if tier.key == key then return i end
    end
    return 2  -- standard
end

-- Days since last collection, honoring the ProStaff L18 fresh-window extension.
function DairyCoreManager:_spoilageStage(daysSince)
    local sp = DairyConstants.SPOILAGE
    local freshDays = sp.FRESH_DAYS
    if self:_proStaffLevel() >= 18 then
        freshDays = freshDays + (sp.L18_FRESH_BONUS_HOURS / 24)
    end
    if daysSince < freshDays then return sp.STAGES.fresh
    elseif daysSince < sp.AGEING_DAYS then return sp.STAGES.ageing
    elseif daysSince < sp.ATRISK_DAYS then return sp.STAGES.atrisk
    else return sp.STAGES.condemned end
end

-- DC-8: the spoilage clock runs on ELAPSED TIME, not on flags. Evaluated once per
-- in-game hour on the hour tick, daysSince is the FRACTIONAL days between the last
-- collection's monotonic hour and now, so a barn collected on a precise 24h cadence
-- reads Fresh for the whole round instead of jumping at midnight. A barn that is
-- never collected advances continuously through Ageing and At Risk to Condemned.
-- Old saves carry lastCollectionDay but not the hour; the day is read as the
-- start-of-day hour so a legacy barn still ages instead of freezing.
function DairyCoreManager:_updateSpoilage(barn, nowHours)
    if barn.lastCollectionDay == nil then
        -- Clock has never started (no collection, no missed window). Do NOT treat
        -- that as "collected today" (forever-Fresh). Stay Fresh with zero drop
        -- until a collection is recorded.
        barn.spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key
        barn._spoilageTierDrop = 0
        return
    end
    local lastHours = barn.lastCollectionHours
    if lastHours == nil then lastHours = barn.lastCollectionDay * 24 end
    local hoursSince = math.max(0, (nowHours or 0) - lastHours)
    local daysSince = hoursSince / 24.0
    local stage = self:_spoilageStage(daysSince)
    barn.spoilageStatus = stage.key
    barn._spoilageTierDrop = stage.tierDrop
end

-- Map a stored spoilage value to the canonical key, migrating the English display
-- names old saves carry. Anything unrecognised degrades to fresh.
function DairyCoreManager:_normalizeSpoilageKey(value)
    if type(value) ~= "string" then return DairyConstants.SPOILAGE.STAGES.fresh.key end
    local byEnglish = {
        Fresh = "fresh", Ageing = "ageing", ["At Risk"] = "atrisk", Condemned = "condemned",
    }
    if byEnglish[value] then return byEnglish[value] end
    for _, st in pairs(DairyConstants.SPOILAGE.STAGES) do
        if st.key == value then return value end
    end
    return DairyConstants.SPOILAGE.STAGES.fresh.key
end

-- Effective sale tier = herd quality tier dropped by the spoilage stage.
function DairyCoreManager:getEffectiveQualityTier(barn)
    local idx = self:_tierIndexByKey(barn.milkQualityTier)
    local drop = barn._spoilageTierDrop or 0
    idx = math.min(#DairyConstants.QUALITY.TIERS, idx + drop)
    return DairyConstants.QUALITY.TIERS[idx]
end

-- Called when a collection actually happens (administrative; resets the timer).
-- DC-9: also stamps the monotonic collection hour and the collection's source.
function DairyCoreManager:markCollected(barn, currentDay, nowHours, source)
    barn.lastCollectionDay = currentDay
    if nowHours ~= nil then barn.lastCollectionHours = nowHours end
    if source ~= nil then barn.lastCollectionSource = source end
    barn.spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key
    barn._spoilageTierDrop = 0
    self:_markBarnsDirty()
end

-- =========================================================
-- DC-9 / DC-21: the milk round. Detection, the rota and the office sale.
-- =========================================================

-- The milk storage object on a dairy barn, ungated (F108). The husbandry's
-- unloading station is a Storage whose fillLevels hold the milk; reading the raw
-- Storage method bypasses UnloadingStation's farm-gated override, so a farm
-- resolution failure can never read zero and manufacture a phantom collection.
function DairyCoreManager:_milkStorageOf(barn)
    local p = barn ~= nil and barn._placeable
    if p == nil or p.spec_husbandry == nil then return nil end
    return p.spec_husbandry.unloadingStation or p.spec_husbandry.loadingStation
end

-- Raw ungated level for a fill type (Storage:getFillLevel semantics).
function DairyCoreManager:_milkLevel(barn, fillType)
    local storage = self:_milkStorageOf(barn)
    if storage == nil then return 0 end
    if storage.fillLevels ~= nil then
        return storage.fillLevels[fillType] or 0
    end
    local ok, level = pcall(function() return storage:getFillLevel(fillType) end)
    return ok and level or 0
end

-- DC-9 3.2: compare a barn's current level against lastKnownMilkLevel. A drop is a
-- collection (size = the difference); a rise is production. The comparison is sign-
-- agnostic on purpose: it self-corrects after a missed callback and cannot drift.
-- Per fill type, so a buffalo barn never credits a MILK collection. Nil-safe against
-- legacy barn records that predate the milk-round fields.
function DairyCoreManager:_observeBarnLevels(barn, nowHours, monotonicDay)
    if barn.lastKnownMilkLevel == nil then barn.lastKnownMilkLevel = {} end
    if barn.lastCollectionLitres == nil then barn.lastCollectionLitres = {} end
    local milkFillType = DairyConstants.CONTRACTS.MILK_FILLTYPE
    local prev = barn.lastKnownMilkLevel[milkFillType]
    if prev == nil then
        barn.lastKnownMilkLevel[milkFillType] = self:_milkLevel(barn, milkFillType)
        return
    end
    local current = self:_milkLevel(barn, milkFillType)
    if current < prev then
        -- A collection (tanker or AI haul). Size is the difference.
        barn.lastCollectionLitres[milkFillType] = prev - current
        barn.lastCollectionSource = DairyConstants.COLLECTION.SOURCES.hauled
        self:markCollected(barn, monotonicDay or 0, nowHours,
            barn.lastCollectionSource)
    end
    barn.lastKnownMilkLevel[milkFillType] = current
end

-- Storage callback (fires on any real level change, farm-agnostic). The active rota
-- and office paths suppress this so a sale they made is not re-counted.
function DairyCoreManager:_onStorageFillChanged(barn, fillType)
    if barn == nil or barn._suppressDetection then return end
    local nowHours = self:_nowHours()
    self:_observeBarnLevels(barn, nowHours, self:_monotonicDay())
end

function DairyCoreManager:_nowHours()
    local monotonicDay = self:_monotonicDay()
    local hourOfDay = 0
    pcall(function()
        local env = g_currentMission and g_currentMission.environment
        hourOfDay = env and (env.dayTime / (60 * 60 * 1000)) or 0
    end)
    return monotonicDay * 24 + hourOfDay
end

function DairyCoreManager:_monotonicDay()
    local day = 0
    pcall(function()
        local env = g_currentMission and g_currentMission.environment
        day = env and env.currentDay or 0
    end)
    return day
end

-- Attach one storage listener per barn (idempotent), so a tanker or AI haul is
-- noticed the moment it happens rather than on the next hour tick.
function DairyCoreManager:_attachStorageListeners(barn)
    if barn._storageListenerBound then return end
    local storage = self:_milkStorageOf(barn)
    if storage == nil or storage.addFillLevelChangedListeners == nil then return end
    local listener = function(fillType, delta)
        self:_onStorageFillChanged(barn, fillType)
    end
    barn._storageListenerFn = listener
    pcall(function()
        storage:addFillLevelChangedListeners(listener)
        barn._storageListenerBound = true
    end)
end

function DairyCoreManager:_detachStorageListeners(barn)
    if not barn._storageListenerBound then return end
    local storage = self:_milkStorageOf(barn)
    if storage ~= nil and storage.removeFillLevelChangedListeners ~= nil
        and barn._storageListenerFn ~= nil then
        pcall(function() storage:removeFillLevelChangedListeners(barn._storageListenerFn) end)
    end
    barn._storageListenerBound = nil
    barn._storageListenerFn = nil
end

-- DC-9 rota: server-authoritative worker assignment. Clients never write it.
-- NetworkSync's default adminOnly=true gates the player-facing path.
function DairyCoreManager:assignCollectionWorker(barnId, workerId)
    local barn = self.barns[barnId]
    if barn == nil or not self:_isServer() then return false end
    barn.assignedWorkerId = workerId
    barn.rotaState = self:_workerRotaState(barn)
    if barn.nextCollectionDue == nil then
        barn.nextCollectionDue = self:_nowHours() + (barn.collectionInterval or 24)
    end
    self:_markBarnsDirty()
    return true
end

function DairyCoreManager:unassignCollectionWorker(barnId)
    local barn = self.barns[barnId]
    if barn == nil or not self:_isServer() then return false end
    barn.assignedWorkerId = nil
    barn.rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
    self:_markBarnsDirty()
    return true
end

-- DC-21 3.1: the internal office/rota sale. ONE ordinary mechanism, no permission
-- check inside it. Reads the level, prices it through the spot market, applies the
-- margin, removes the milk by the standard removal path (pricing against what ACTUALLY
-- came out), credits the money and records the collection. Permission lives at the
-- boundary: the NetworkSync action wrapper for office, the server tick for rota.
-- DC-9 3.4: this is what the rota calls directly on the server.
function DairyCoreManager:_adminSellMilk(barn, quantity, source, nowHours, monotonicDay)
    if barn == nil or not self:_isServer() then
        return nil, "server_only"
    end
    local fillType = DairyConstants.CONTRACTS.MILK_FILLTYPE
    local available = self:_milkLevel(barn, fillType)
    if available <= 0 then return nil, "no_milk" end

    local requested = quantity or available
    requested = math.min(requested, available)

    -- Suppress the passive detector while we move the milk, so this sale is counted
    -- once, by us, with its real source.
    barn._suppressDetection = true
    local removed = 0
    pcall(function()
        local p = barn._placeable
        if p ~= nil and p.removeHusbandryFillLevel ~= nil then
            local ftIndex = 0
            pcall(function()
                local ftm = g_fillTypeManager
                if ftm ~= nil then ftIndex = ftm:getFillTypeIndexByName(fillType) or 0 end
            end)
            local remaining = p:removeHusbandryFillLevel(barn.farmId, requested, ftIndex)
            if type(remaining) == "number" then
                removed = math.max(0, requested - remaining)
            else
                removed = requested
            end
        end
    end)
    barn._suppressDetection = false

    if removed <= 0 then return nil, "no_milk" end

    local spot = self:_milkSpotPrice()
    local margin = self.settings.saleMargin or DairyConstants.SALE.DEFAULT_MARGIN
    margin = math.max(DairyConstants.SALE.MARGIN_MIN,
                      math.min(DairyConstants.SALE.MARGIN_MAX, margin))
    local income = math.floor(removed * spot * (1 - margin))
    if income > 0 then
        pcall(function()
            g_currentMission:addMoney(income, barn.farmId, MoneyType.OTHER, true, true)
        end)
        self:_taxAudit(barn.farmId, income, DairyConstants.SALE.INCOME_LABEL)
    end

    -- Record the collection with its real source and re-seed the detector in the
    -- same step, so the passive path cannot re-count this drop.
    if barn.lastCollectionLitres == nil then barn.lastCollectionLitres = {} end
    barn.lastCollectionLitres[fillType] = removed
    barn.lastCollectionSource = source
    barn.lastKnownMilkLevel[fillType] = self:_milkLevel(barn, fillType)
    self:markCollected(barn, monotonicDay or self:_monotonicDay(), nowHours or self:_nowHours(), source)
    DCLogger.info("Milk sale (%s): %d L -> %d (barn %s)", tostring(source),
        math.floor(removed), income, tostring(barn.barnId))
    return removed, "ok"
end

-- DC-21 3.3: the rota's entry point, called directly by the hour tick on the server.
function DairyCoreManager:_rotaCollection(barn, nowHours, monotonicDay)
    self:_adminSellMilk(barn, nil, DairyConstants.COLLECTION.SOURCES.rota, nowHours, monotonicDay)
end

-- DC-21 3.2: the thin admin wrapper the office menu invokes.
function DairyCoreManager:sellMilk(barnId, quantity)
    local barn = self.barns[barnId]
    if barn == nil then return nil, "no_barn" end
    return self:_adminSellMilk(barn, quantity, DairyConstants.COLLECTION.SOURCES.office)
end

-- DC-9 repair 5: no barn record is ever removed. Reconcile at discovery: drop any
-- record whose placeable no longer resolves, and clear the rota when the resolved
-- farm differs from the stored one (a barn that changes hands resolves fine, it is
-- simply somebody else's now).
function DairyCoreManager:_reconcileBarns()
    for barnId, barn in pairs(self.barns) do
        local p = barn._placeable
        if p == nil then
            -- Placeable unresolved this pass (fresh discovery may not have reached
            -- it yet); only drop records we can prove dead.
            if barn._probeDead then
                self:_detachStorageListeners(barn)
                self.barns[barnId] = nil
            else
                barn._probeDead = true
            end
        else
            barn._probeDead = nil
            if barn.farmId ~= nil and p.getOwnerFarmId ~= nil then
                local owner = nil
                pcall(function() owner = p:getOwnerFarmId() end)
                if self:_isRealFarmId(owner) and owner ~= barn.farmId then
                    barn.assignedWorkerId = nil
                    barn.rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
                    barn.farmId = owner
                end
            end
        end
    end
end

-- =========================================================
-- Collection scheduling (administrative; hour tick)
-- =========================================================

function DairyCoreManager:onCollectionHourTick(ctx)
    if self.disabled or not self.settings.enabled then return end
    -- Server only, same reason as onDayTick: this tick moves the collection schedule
    -- and the spoilage clock, and both of those travel down over CHANNEL_BARNS.
    if not self:_isServer() then return end
    local monotonicDay = ctx.monotonicDay or 0
    local nowHours = self:_nowHours()

    for _, barn in pairs(self.barns) do
        -- DC-9: notice milk that left since the last tick (tanker, AI haul).
        self:_observeBarnLevels(barn, nowHours, monotonicDay)

        -- DC-8: spoilage evaluates every hour from elapsed time since the last
        -- collection. A missed window needs no flag any more: the clock is time,
        -- so a barn nobody collected simply ages continuously.
        if self.settings.spoilageEnabled then
            self:_updateSpoilage(barn, nowHours)
        end

        -- Refresh the rota state from the live roster (three-way lifecycle sort).
        if barn.assignedWorkerId ~= nil then
            barn.rotaState = self:_workerRotaState(barn)
        end

        if barn.nextCollectionDue == nil then
            barn.nextCollectionDue = nowHours + (barn.collectionInterval or 24)
        elseif nowHours >= barn.nextCollectionDue then
            -- A scheduled window has arrived. If no worker is assigned the window is
            -- MISSED: the milk ages on, which the elapsed-time clock already shows.
            if barn.assignedWorkerId ~= nil then
                -- DC-9 3.4: the rota is ACTIVE, not passive. It calls DC-21's
                -- internal sale mechanism directly on the server (source rota),
                -- which actually removes, prices and credits the milk.
                local skill = DairyConstants.COLLECTION.SKILL[self:_workerLevelName(barn)]
                              or DairyConstants.COLLECTION.SKILL.experienced
                local removed = self:_rotaCollection(barn, nowHours, monotonicDay)
                if removed and removed > 0 then
                    barn._lastRunSpeedMod = skill.speedMod
                end
            else
                DCLogger.debug("Barn %s: collection window missed (no worker assigned)", tostring(barn.barnId))
            end
            barn.nextCollectionDue = nowHours + (barn.collectionInterval or 24)
        end
    end
end

-- =========================================================
-- Feed source fields + mycotoxin
-- =========================================================

function DairyCoreManager:designateFeedField(barnId, fieldId)
    local barn = self.barns[barnId]
    if barn == nil then return false end
    barn.feedSourceFields[fieldId] = true
    self:_markBarnsDirty()
    return true
end

function DairyCoreManager:undesignateFeedField(barnId, fieldId)
    local barn = self.barns[barnId]
    if barn == nil then return false end
    barn.feedSourceFields[fieldId] = nil
    return true
end

-- Inbound broadcast from CropDisease / SF disease layer.
function DairyCoreManager:applyFeedContaminationPenalty(barnId, severity)
    local barn = self.barns[barnId]
    if barn == nil then return end
    severity = math.max(0, math.min(100, severity or 0))
    local myc = DairyConstants.MYCOTOXIN
    barn.mycotoxinPenalty = myc.MIN_PENALTY + math.floor((severity / 100) * (myc.MAX_PENALTY - myc.MIN_PENALTY))
    barn.mycotoxinDaysLeft = math.floor(myc.MIN_DAYS + (severity / 100) * (myc.MAX_DAYS - myc.MIN_DAYS))
    self:_markBarnsDirty()
end

-- Refresh the which-field feed-disease flag (reveal gate: name only when the field's
-- diseaseDiscovered is true; otherwise which-field-only). DC-14 also derives a
-- severity band from the raw ungated diseasePressure of the designated feed fields
-- (the max across them), so the published feed signal can say how bad, not only
-- that something is there.
function DairyCoreManager:_refreshFeedDiseaseFlag(barn)
    barn.feedDiseaseFlag = false
    barn.feedDiseaseCropName = nil
    barn.feedDiseaseSeverity = 0
    for fieldId in pairs(barn.feedSourceFields) do
        local info = self:_getFieldInfo(fieldId)
        if info ~= nil and info.activeDisease ~= nil then
            barn.feedDiseaseFlag = true
            if info.diseaseDiscovered == true then
                barn.feedDiseaseCropName = info.activeDisease
            end
            local severity = info.diseasePressure or 0
            if severity > barn.feedDiseaseSeverity then
                barn.feedDiseaseSeverity = math.floor(severity)
            end
        end
    end
end

function DairyCoreManager:_decayMycotoxin(barn)
    if (barn.mycotoxinDaysLeft or 0) > 0 then
        barn.mycotoxinDaysLeft = barn.mycotoxinDaysLeft - 1
        if barn.mycotoxinDaysLeft <= 0 then
            barn.mycotoxinPenalty = 0
        end
    end
    self:_refreshFeedDiseaseFlag(barn)
end

-- =========================================================
-- Dairy contracts
-- =========================================================

function DairyCoreManager:getAvailableContractTypes()
    local out = {}
    local level = self:_proStaffLevel()
    for _, ct in pairs(DairyConstants.CONTRACTS.TYPES) do
        if ct.key ~= "sovereign_floor" and (ct.prostaffLevel or 0) <= level then
            out[#out + 1] = ct.key
        end
    end
    table.sort(out)
    return out
end

function DairyCoreManager:acceptContract(barnId, typeKey)
    if not self.settings.contractsEnabled then return nil end
    local barn = self.barns[barnId]
    local ct = DairyConstants.CONTRACTS.TYPES[typeKey]
    if barn == nil or ct == nil or ct.key == "sovereign_floor" then return nil end
    if (ct.prostaffLevel or 0) > self:_proStaffLevel() then return nil end

    local contractId = self.nextContractId
    self.nextContractId = self.nextContractId + 1
    self.contracts[contractId] = {
        contractId = contractId, barnId = barnId, farmId = barn.farmId,
        type = ct.key, volumeTarget = ct.volumeTarget, termDays = ct.termDays,
        daysRemaining = ct.termDays, premiumRate = ct.premiumRate,
        qualityRequired = ct.qualityRequired, delivered = 0, settled = false,
    }
    barn.activeContractId = contractId
    self:_registerContractAccrual(contractId)
    self:_markBarnsDirty()
    return contractId
end

-- Register the contract with the Time Guard accrue-and-settle (server-only, idempotent).
function DairyCoreManager:_registerContractAccrual(contractId)
    local tg = self:_getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then return end
    tg:registerAccrual("DairyCore_contract_" .. tostring(contractId), {
        cadence = "day",
        flowClass = "calendar",
        firstPeriodPolicy = "full",
        priority = DairyConstants.SETTLE_PRIORITY.CONTRACT,
        onSettle = function(sctx) self:_settleContractDay(contractId, sctx) end,
    })
end

-- One day of the contract: accrue delivery, decrement the term, pay + close at end.
function DairyCoreManager:_settleContractDay(contractId, sctx)
    local c = self.contracts[contractId]
    if c == nil or c.settled then return end
    local barn = self.barns[c.barnId]
    if barn == nil then return end

    local n = sctx and sctx.boundariesCrossed or 1
    for _ = 1, n do
        if c.settled then break end
        -- Estimate the day's delivery from the barn herd (gated placeholder rate).
        local herd = self:_barnHerdCount(barn)
        -- DC-8 (F102, DC-10's written acceptance): the contract is paid on the
        -- EFFECTIVE tier, which carries the spoilage penalty. Reading the earned
        -- tier here let a barn with Condemned milk sell at Premium if the herd was
        -- healthy, so spoilage never reached money.
        local qualityFactor = self:getEffectiveQualityTier(barn).priceMod
        c.delivered = c.delivered + herd * PER_COW_LITRES_DAY * qualityFactor
        -- OM-211: accumulate the barn's mean organic-feed credit per accrual day.
        -- The pay line averages these over organicDays, so a contract that spends
        -- part of its term on organic feed and part not pays a blended factor.
        c.organicSum  = (c.organicSum or 0) + self:_barnOrganicFraction(barn)
        c.organicDays = (c.organicDays or 0) + 1
        c.daysRemaining = c.daysRemaining - 1
        if c.daysRemaining <= 0 then
            self:_payContract(c)
            c.settled = true
        end
    end
    self:_markBarnsDirty()
end

function DairyCoreManager:_barnHerdCount(barn)
    local count = 5
    pcall(function()
        if barn._placeable ~= nil and barn._placeable.getNumOfAnimals ~= nil then
            count = barn._placeable:getNumOfAnimals() or count
        end
    end)
    return math.max(1, count)
end

--- OM-211 / FP-1: mean organic credit of the barn's feed, 0..1.
--- FP-1 (authority #5): when the farm's harvest provenance holds data, the credit
--- comes from it (the amount-weighted organic fraction of the farm's harvested
--- feed) instead of a live field read, because organic rides the feed, not the
--- field. Otherwise it reads SoilFertilizer's shipped OrganicCertification
--- (g_SoilFertilityManager.organic, delegate-when-present) over the barn's
--- designated feed fields. SF absent, no provenance, no designations, or no
--- readable fields => 0, so the pay factor stays 1.0.
---@param barn table
---@return number  mean organic credit 0..1 (0 when no source is readable)
function DairyCoreManager:_barnOrganicFraction(barn)
    local fp = self.feedProvenance
    if fp ~= nil and fp:hasData(barn.farmId) then
        return fp:organicFeedFraction(barn.farmId)
    end
    local mgr = g_SoilFertilityManager
    if mgr == nil or mgr.organic == nil or mgr.organic.getFieldOrganicState == nil then return 0 end
    local sum, n = 0, 0
    for fieldId in pairs(barn.feedSourceFields or {}) do
        local ok, st = pcall(function() return mgr.organic:getFieldOrganicState(fieldId) end)
        if ok and st ~= nil then
            n = n + 1
            if st.certified == true then
                sum = sum + 1.0
            elseif st.transitionDaysNeeded and st.transitionDaysNeeded > 0 and st.daysAccrued then
                sum = sum + math.max(0, math.min(1, st.daysAccrued / st.transitionDaysNeeded))
            end
        end
    end
    if n == 0 then return 0 end
    return sum / n
end

-- Pay contract income. Base-game addMoney moves the money (server only); TaxMod audits.
function DairyCoreManager:_payContract(c)
    if not self:_isServer() then return end
    local spot = self:_milkSpotPrice()
    local premium = c.premiumRate or 1.0

    -- Sovereign floor (DC-16 fold): floor the effective per-litre at floorFraction
    -- of the crash-proof BASE price (entry.base), read as a pull at pay time, never
    -- the live spot. max() composes two independently arrived-at numbers, the
    -- contract's own rate arithmetic and a base anchor, so a market crash cannot
    -- drag the floor down with it (the deleted block floored the spot it divided
    -- by, which crashed exactly when the floor was needed). No ProStaff read: the
    -- L20 gate waits on the family barn.farmId plumbing (DC-6/DC-7).
    local effectivePrice = math.max(spot * premium,
        self:_milkBasePrice() * DairyConstants.CONTRACTS.TYPES.sovereign_floor.floorFraction)

    -- DairyCore's own livestock-boom milk premium (keyed on the MD event id).
    if self:_mdEventActive("livestock_boom") then
        effectivePrice = effectivePrice * DairyConstants.CONTRACTS.LIVESTOCK_BOOM_MILK_BONUS
    end

    -- OM-211: organic-feed milk premium, AFTER the sovereign floor, beside the
    -- boom bonus. Mean organic credit over the contract's accrual days scales the
    -- factor between 1.0 (no organic feed) and ORGANIC_MILK_PREMIUM_MAX; the
    -- formula floors at 1.0 so organic can only add. An old save loads organicSum
    -- / organicDays nil and the guard treats that as zero organic days (1.0).
    if (c.organicDays and c.organicDays > 0) and
       (c.organicSum and c.organicSum > 0) then
        local organicFactor = c.organicSum / c.organicDays
        effectivePrice = effectivePrice * (1 + organicFactor * (DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX - 1))
    end

    local litres = math.min(c.delivered, c.volumeTarget)
    local income = math.floor(litres * effectivePrice)
    if income <= 0 then return end

    pcall(function()
        g_currentMission:addMoney(income, c.farmId, MoneyType.OTHER, true, true)
    end)
    self:_taxAudit(c.farmId, income, DairyConstants.CONTRACTS.INCOME_LABEL)
    DCLogger.info("Contract %d paid: %d L -> %d (farm %d)", c.contractId, math.floor(litres), income, c.farmId)

    local barn = self.barns[c.barnId]
    if barn ~= nil then barn.activeContractId = nil end
end

-- =========================================================
-- Integration 29C: trailer transfer completion (Ritter)
-- =========================================================

function DairyCoreManager:onAnimalMoved(errorCode)
    if not RLBridge.active then return end
    if AnimalMoveEvent == nil or errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then return end
    -- Refresh affected barn counts on the next day update. The event does not carry
    -- barnId; a full re-discover on the day tick reconciles counts. Fuel-cost logging
    -- is stored internally only (FuelCosts is a price oracle, no registration API).
end

-- DC-21 3.2 + DC-9 rota: the admin-gated network actions. The office sale wrapper and
-- the rota assignment both validate the caller through NetworkSync's default
-- adminOnly=true, then call the mechanism. The rota's hourly run bypasses these
-- actions entirely and calls _adminSellMilk directly (a scheduled tick has no
-- connection, so routing it through the admin gate would be a gate that looks like
-- it is working).
function DairyCoreManager:_bindActions()
    if self.actionsBound then return end
    local ns = self:_getNetworkSync()
    if ns == nil or ns.registerAction == nil then return end

    ns:registerAction(DairyConstants.ACTIONS.SELL_MILK, {
        onAction = function(userId, args)
            if type(args) ~= "table" or args.barnId == nil then return end
            self:sellMilk(args.barnId, args.quantity)
        end,
    })
    ns:registerAction(DairyConstants.ACTIONS.ASSIGN_ROTA, {
        onAction = function(userId, args)
            if type(args) ~= "table" or args.barnId == nil then return end
            self:assignCollectionWorker(args.barnId, args.workerId)
        end,
    })
    ns:registerAction(DairyConstants.ACTIONS.UNASSIGN_ROTA, {
        onAction = function(userId, args)
            if type(args) ~= "table" or args.barnId == nil then return end
            self:unassignCollectionWorker(args.barnId)
        end,
    })
    self.actionsBound = true
end

-- =========================================================
-- Time Guard clock subscription
-- =========================================================

function DairyCoreManager:_subscribeClock()
    if self.clockBound then return end
    local tg = self:_getTimeGuard()
    if tg == nil or tg.subscribeTick == nil then return end
    tg:subscribeTick("day", "DairyCore_daily", function(ctx) self:onDayTick(ctx) end)
    tg:subscribeTick("hour", "DairyCore_collection", function(ctx) self:onCollectionHourTick(ctx) end)
    self.clockBound = true
end

-- Time Guard fires its ticks on ALL peers by deliberate design and says so in its
-- own contract, so the server gate is DairyCore's to apply and is not a Time Guard
-- change. A client still re-discovers its own barns, because placeables are local
-- and a barn built after join has to become visible to the reader, but it simulates
-- nothing: every simulated field arrives over CHANNEL_BARNS, and a local recompute
-- would overwrite what the server sent within one tick.
function DairyCoreManager:onDayTick(ctx)
    if self.disabled then return end
    if not self:_isServer() then
        self:discoverBarns()
        return
    end
    local currentDay = ctx.monotonicDay or 0
    self:updateAllBarns(currentDay)
    -- FP-1: the provenance's contaminated fraction heals on the calendar, server-side.
    if self.feedProvenance ~= nil then
        self.feedProvenance:decayContaminated()
    end
    self:_markBarnsDirty()
end

-- =========================================================
-- Bedrock (delegate-when-present)
-- =========================================================

function DairyCoreManager:_markBarnsDirty()
    local ns = self:_getNetworkSync()
    if ns ~= nil and self:_isServer() and ns.markDirty ~= nil then
        ns:markDirty(DairyConstants.NETWORK.CHANNEL_BARNS)
    end
end

-- FP-1: subscribe to SoilFertilizer's harvest bus (server only). The payload shape
-- is certified: { fieldId, fruitTypeIndex, liters (incremental), area,
-- diseasePressure, activeDisease, activeDiseaseSeverity }. Subscribe is keyed by
-- name, so re-registering replaces our own listener rather than stacking.
function DairyCoreManager:_bindHarvestBus()
    if self.harvestBound then return end
    if not self:_isServer() then return end
    local bus = g_currentMission ~= nil and g_currentMission.soilHarvestBus
    if bus == nil or bus.subscribe == nil then return end
    local ok = pcall(function()
        return bus:subscribe("DairyCore_FeedProvenance", function(payload)
            if self.feedProvenance ~= nil then
                self.feedProvenance:onHarvestCut(payload)
            end
        end)
    end)
    if ok then self.harvestBound = true end
end

function DairyCoreManager:_unbindHarvestBus()
    if not self.harvestBound then return end
    local bus = g_currentMission ~= nil and g_currentMission.soilHarvestBus
    if bus ~= nil and bus.unsubscribe ~= nil then
        pcall(function() bus:unsubscribe("DairyCore_FeedProvenance") end)
    end
    self.harvestBound = false
end

function DairyCoreManager:_bindBedrock()
    if self.bedrockBound then return end
    local bound = false

    local ledger = self:_getLedger()
    if ledger ~= nil then
        ledger:registerModule(DairyCoreManager.LEDGER_BARNS, {
            serialize   = function() return self:_serializeBarns() end,
            deserialize = function(data) self:_deserializeBarns(data) end,
        })
        ledger:registerModule(DairyCoreManager.LEDGER_CONTRACTS, {
            serialize   = function() return self:_serializeContracts() end,
            deserialize = function(data) self:_deserializeContracts(data) end,
        })
        -- FP-1: the feed provenance ledger (authority #5).
        ledger:registerModule(DairyConstants.FEED_PROVENANCE.LEDGER, {
            serialize   = function() return self.feedProvenance:serialize() end,
            deserialize = function(data) self.feedProvenance:deserialize(data) end,
        })
        bound = true
    end

    local ns = self:_getNetworkSync()
    if ns ~= nil then
        ns:registerModule(DairyConstants.NETWORK.CHANNEL_BARNS, {
            channel      = DairyConstants.NETWORK.CHANNEL_BARNS,
            onWriteState = function() return self:_onWriteBarnState() end,
            onReadState  = function(arr) self:_onReadBarnState(arr) end,
        })
        bound = true
    end

    local hub = self:_getSettingsHub()
    if hub ~= nil then
        hub:registerModule("DairyCore", {
            selfPersisted = true,
            adminSettings = {
                { id = "enabled", type = "bool", default = true, adminOnly = true, label = "Dairy Core Enabled" },
                { id = "defaultCollectionInterval", type = "int", default = 24, min = 4, max = 72,
                  adminOnly = true, label = "Default Collection Interval (h)" },
                { id = "spoilageEnabled", type = "bool", default = true, adminOnly = true, label = "Milk Spoilage" },
                { id = "contractsEnabled", type = "bool", default = true, adminOnly = true, label = "Dairy Contracts" },
                { id = "saleMargin", type = "float", default = DairyConstants.SALE.DEFAULT_MARGIN,
                  min = DairyConstants.SALE.MARGIN_MIN, max = DairyConstants.SALE.MARGIN_MAX,
                  adminOnly = true, label = "Milk Sale Margin (fraction)" },
            },
            onChange = function(key, value)
                if key == "enabled" then self.settings.enabled = value ~= false
                elseif key == "defaultCollectionInterval" then self.settings.defaultCollectionInterval = value
                elseif key == "spoilageEnabled" then self.settings.spoilageEnabled = value ~= false
                elseif key == "contractsEnabled" then self.settings.contractsEnabled = value ~= false
                elseif key == "saleMargin" then self.settings.saleMargin = value end
            end,
        })
        bound = true
    end

    if bound then self.bedrockBound = true end
end

-- =========================================================
-- Serialization (StateLedger tables) + NetworkSync arrays
-- =========================================================

function DairyCoreManager:_serializeBarns()
    local out = {}
    for barnId, b in pairs(self.barns) do
        local fields = {}
        for fid in pairs(b.feedSourceFields) do fields[#fields + 1] = fid end
        local milkFill = DairyConstants.CONTRACTS.MILK_FILLTYPE
        out[tostring(barnId)] = {
            herdHealthScore = b.herdHealthScore, milkQualityTier = b.milkQualityTier,
            spoilageStatus = self:_normalizeSpoilageKey(b.spoilageStatus),
            _spoilageTierDrop = b._spoilageTierDrop or 0,
            lastCollectionDay = b.lastCollectionDay,
            feedSourceFields = fields, mycotoxinPenalty = b.mycotoxinPenalty,
            mycotoxinDaysLeft = b.mycotoxinDaysLeft, collectionInterval = b.collectionInterval,
            assignedWorkerId = b.assignedWorkerId, activeContractId = b.activeContractId,
            nextCollectionDue = b.nextCollectionDue,
            -- DC-9: milk-round state. lastCollectionLitres is per-fill type; MILK is
            -- the only fill type the mod tracks today.
            lastCollectionHours = b.lastCollectionHours,
            lastCollectionSource = b.lastCollectionSource,
            rotaState = b.rotaState,
            lastCollectionLitres = b.lastCollectionLitres and b.lastCollectionLitres[milkFill],
        }
    end
    return out
end

function DairyCoreManager:_deserializeBarns(data)
    if type(data) ~= "table" then return end
    for key, s in pairs(data) do
        local barnId = tonumber(key) or key
        local b = self.barns[barnId] or { barnId = barnId, farmId = 0, feedSourceFields = {} }
        b.herdHealthScore = s.herdHealthScore or 60
        b.milkQualityTier = s.milkQualityTier or "standard"
        b.spoilageStatus = self:_normalizeSpoilageKey(s.spoilageStatus)
        b._spoilageTierDrop = s._spoilageTierDrop or 0
        b.lastCollectionDay = s.lastCollectionDay
        b.mycotoxinPenalty = s.mycotoxinPenalty or 0
        b.mycotoxinDaysLeft = s.mycotoxinDaysLeft or 0
        b.collectionInterval = s.collectionInterval or self.settings.defaultCollectionInterval
        b.assignedWorkerId = s.assignedWorkerId
        b.activeContractId = s.activeContractId
        b.nextCollectionDue = s.nextCollectionDue
        b.feedSourceFields = {}
        for _, fid in ipairs(s.feedSourceFields or {}) do b.feedSourceFields[fid] = true end
        -- DC-9 state + repair 2: a restored nextCollectionDue that has landed ahead
        -- of the clock would wedge forever, so clamp it to one interval ahead.
        b.lastCollectionHours = s.lastCollectionHours
        b.lastCollectionSource = s.lastCollectionSource
        b.rotaState = s.rotaState or DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
        b.lastCollectionLitres = {}
        if s.lastCollectionLitres ~= nil then
            b.lastCollectionLitres[DairyConstants.CONTRACTS.MILK_FILLTYPE] = s.lastCollectionLitres
        end
        if b.nextCollectionDue ~= nil then
            b.nextCollectionDue = math.min(b.nextCollectionDue,
                self:_nowHours() + (b.collectionInterval or 24))
        end
        self.barns[barnId] = b
    end
end

function DairyCoreManager:_serializeContracts()
    local out = {}
    for id, c in pairs(self.contracts) do
        if not c.settled then
            out[tostring(id)] = { barnId = c.barnId, farmId = c.farmId, type = c.type,
                volumeTarget = c.volumeTarget, termDays = c.termDays, daysRemaining = c.daysRemaining,
                premiumRate = c.premiumRate, qualityRequired = c.qualityRequired, delivered = c.delivered,
                organicSum = c.organicSum, organicDays = c.organicDays }
        end
    end
    out._nextId = self.nextContractId
    return out
end

function DairyCoreManager:_deserializeContracts(data)
    if type(data) ~= "table" then return end
    self.nextContractId = data._nextId or self.nextContractId
    for key, s in pairs(data) do
        if key ~= "_nextId" then
            local id = tonumber(key) or key
            self.contracts[id] = { contractId = id, barnId = s.barnId, farmId = s.farmId,
                type = s.type, volumeTarget = s.volumeTarget, termDays = s.termDays,
                daysRemaining = s.daysRemaining, premiumRate = s.premiumRate,
                qualityRequired = s.qualityRequired, delivered = s.delivered or 0, settled = false,
                organicSum = s.organicSum, organicDays = s.organicDays }
            self:_registerContractAccrual(id)
        end
    end
end

-- DC-14: the barn's own milk store-full state, read from the husbandry methods the
-- base game ships (getHusbandryFillLevel against getHusbandryCapacity). A STATE and
-- not a litre count: the base game already prints litres in the placeable info box.
function DairyCoreManager:_storeFull(b)
    local p = b ~= nil and b._placeable
    if p == nil or p.getHusbandryFillLevel == nil or p.getHusbandryCapacity == nil then
        return false
    end
    local full = false
    pcall(function()
        local ftm = g_fillTypeManager
        local ft = ftm ~= nil and ftm:getFillTypeIndexByName(DairyConstants.CONTRACTS.MILK_FILLTYPE) or 0
        local level = p:getHusbandryFillLevel(ft)
        local cap = p:getHusbandryCapacity(ft)
        if type(level) == "number" and type(cap) == "number" and cap > 0 then
            full = level >= cap
        end
    end)
    return full
end

-- DC-14: the contract progress band, server-side. On track when the delivered
-- fraction is within ON_TRACK_TOL of the term position, behind within BEHIND_TOL,
-- otherwise the contract will not make its volume. No active contract reads NONE.
function DairyCoreManager:_contractProgress(b)
    local c = self.contracts[b.activeContractId]
    if c == nil or c.settled then return DairyConstants.CONTRACT_PROGRESS.NONE end
    local expected = 1 - (c.daysRemaining or 0) / math.max(1, c.termDays or 1)
    local actual = (c.delivered or 0) / math.max(1, c.volumeTarget or 1)
    local cp = DairyConstants.CONTRACT_PROGRESS
    if actual >= expected - cp.ON_TRACK_TOL then return cp.ON_TRACK end
    if actual >= expected - cp.BEHIND_TOL then return cp.BEHIND end
    return cp.WILL_NOT_MAKE
end

-- Compact barn state for MP. Exactly BARN_STRIDE flat scalars per barn, in order:
--    1 barnId (string)                 2 herd health score (int)
--    3 quality tier index (int)        4 spoilage tier drop (int)
--    5 mycotoxin penalty (int)         6 collection interval hours (int)
--    7 assignedWorkerId (string, NONE_STRING when unassigned)
--    8 lastCollectionDay (int, NONE_NUMBER when never collected)
--    9 nextCollectionDue (number, NONE_NUMBER when unscheduled)
--   10 feedSourceFields (comma-joined ids, NONE_STRING when none)
--   11 activeContractId (int, NONE_NUMBER when no contract)
--   12 contractProgress (int: 0 none, 1 on track, 2 behind, 3 will not make)
--   13 spoilageKey (string: dc_spoilage_* key)
--   14 storeFull (int 0/1)
--   15 farmId (int)
--   16 feedDiseaseFlag (int 0/1)
--   17 feedDiseaseSeverity (int 0-100)
--   18 feedDiseaseCropName (string, NONE_STRING when gated or absent)
--   19 rotaState (string)
--   20 lastCollectionHours (number, NONE_NUMBER when never collected)
--   21 lastCollectionSource (string, NONE_STRING when none)
--   22 lastCollectionLitres (number, NONE_NUMBER when none)
--
-- Two rules the shape exists to enforce, both of which this record used to break.
-- A nil is never appended: `arr[#arr+1] = nil` neither writes a slot nor advances
-- the length, so one absent field shortens the record and the reader takes the next
-- barn's identifier as this barn's data. And no slot is a table: the encoding
-- carries scalars only and turns anything else into a float32 zero, so the feed
-- field set crosses as a string and is rebuilt on the far side.
function DairyCoreManager:_onWriteBarnState()
    local net = DairyConstants.NETWORK
    local arr = {}
    for barnId, b in pairs(self.barns) do
        local feedFields = {}
        for fid in pairs(b.feedSourceFields or {}) do feedFields[#feedFields + 1] = tostring(fid) end
        table.sort(feedFields)  -- pairs order is arbitrary; keep the payload stable

        local milkFill = DairyConstants.CONTRACTS.MILK_FILLTYPE
        local lastLitres = b.lastCollectionLitres and b.lastCollectionLitres[milkFill]
        arr[#arr + 1] = tostring(barnId)
        arr[#arr + 1] = math.floor(b.herdHealthScore or 60)
        arr[#arr + 1] = self:_tierIndexByKey(b.milkQualityTier)
        arr[#arr + 1] = math.floor(b._spoilageTierDrop or 0)
        arr[#arr + 1] = math.floor(b.mycotoxinPenalty or 0)
        arr[#arr + 1] = math.floor(b.collectionInterval or self.settings.defaultCollectionInterval)
        arr[#arr + 1] = b.assignedWorkerId ~= nil and tostring(b.assignedWorkerId) or net.NONE_STRING
        arr[#arr + 1] = b.lastCollectionDay ~= nil and math.floor(b.lastCollectionDay) or net.NONE_NUMBER
        arr[#arr + 1] = b.nextCollectionDue or net.NONE_NUMBER
        arr[#arr + 1] = table.concat(feedFields, ",")
        -- DC-14 slots.
        arr[#arr + 1] = b.activeContractId ~= nil and math.floor(b.activeContractId) or net.NONE_NUMBER
        arr[#arr + 1] = self:_contractProgress(b)
        arr[#arr + 1] = self:_normalizeSpoilageKey(b.spoilageStatus)
        arr[#arr + 1] = self:_storeFull(b) and 1 or 0
        arr[#arr + 1] = math.floor(b.farmId or 0)
        arr[#arr + 1] = b.feedDiseaseFlag == true and 1 or 0
        arr[#arr + 1] = math.floor(b.feedDiseaseSeverity or 0)
        arr[#arr + 1] = b.feedDiseaseCropName ~= nil and tostring(b.feedDiseaseCropName) or net.NONE_STRING
        arr[#arr + 1] = b.rotaState or DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
        arr[#arr + 1] = b.lastCollectionHours or net.NONE_NUMBER
        arr[#arr + 1] = b.lastCollectionSource ~= nil and tostring(b.lastCollectionSource) or net.NONE_STRING
        arr[#arr + 1] = lastLitres ~= nil and lastLitres or net.NONE_NUMBER
    end
    return arr
end

function DairyCoreManager:_onReadBarnState(arr)
    if type(arr) ~= "table" then return end
    local net = DairyConstants.NETWORK
    local stride = net.BARN_STRIDE
    local count = #arr

    -- A payload that is not a whole number of records means writer and reader
    -- disagree about the record. Applying it would read one barn's values into
    -- another barn's fields, so refuse the batch and say so instead.
    if count % stride ~= 0 then
        DCLogger.warning("barn sync: payload of %d values is not a multiple of the %d-value record, ignoring batch",
            count, stride)
        return
    end

    for i = 1, count, stride do
        local barnId = tonumber(arr[i]) or arr[i]
        local b = self.barns[barnId]
        if b ~= nil then
            -- DC-14: every field that arrives over the wire is the SERVER's book,
            -- never a local default. The record marks the receipt so getBarnRows
            -- can mark the row's fields `server` instead of `unknown`.
            b._wireReceived      = true
            b.herdHealthScore    = arr[i+1]
            b.milkQualityTier    = (DairyConstants.QUALITY.TIERS[arr[i+2]] or DairyConstants.QUALITY.TIERS[2]).key
            b._spoilageTierDrop  = arr[i+3]
            b.mycotoxinPenalty   = arr[i+4]
            b.collectionInterval = arr[i+5]
            b.assignedWorkerId   = arr[i+6] ~= net.NONE_STRING and (tonumber(arr[i+6]) or arr[i+6]) or nil
            b.lastCollectionDay  = arr[i+7] ~= net.NONE_NUMBER and arr[i+7] or nil
            b.nextCollectionDue  = arr[i+8] ~= net.NONE_NUMBER and arr[i+8] or nil
            b.feedSourceFields   = {}
            for fid in string.gmatch(tostring(arr[i+9] or ""), "([^,]+)") do
                b.feedSourceFields[tonumber(fid) or fid] = true
            end
            -- DC-14 slots.
            b.activeContractId   = arr[i+10] ~= net.NONE_NUMBER and arr[i+10] or nil
            b.contractProgress   = arr[i+11]
            b.spoilageStatus     = self:_normalizeSpoilageKey(arr[i+12])
            b.storeFull          = arr[i+13] == 1
            if b.farmId == nil or b.farmId == 0 then
                b.farmId = arr[i+14]
            end
            b.feedDiseaseFlag    = arr[i+15] == 1
            b.feedDiseaseSeverity = arr[i+16]
            b.feedDiseaseCropName = arr[i+17] ~= net.NONE_STRING and arr[i+17] or nil
            b.rotaState          = arr[i+18] or DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED
            b.lastCollectionHours = arr[i+19] ~= net.NONE_NUMBER and arr[i+19] or nil
            b.lastCollectionSource = arr[i+20] ~= net.NONE_STRING and arr[i+20] or nil
            b.lastCollectionLitres = {}
            if arr[i+21] ~= net.NONE_NUMBER then
                b.lastCollectionLitres[DairyConstants.CONTRACTS.MILK_FILLTYPE] = arr[i+21]
            end
        end
    end
end

-- =========================================================
-- Own-file persistence fallback (only when StateLedger absent)
-- =========================================================

function DairyCoreManager:_savePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then return nil end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. DairyCoreManager.SAVE_FILE
end

-- When StateLedger is absent this file is the ONLY persistence the mod has, so its
-- record has to carry what the ledger modules carry. It previously stored a subset
-- of the barn and no contracts at all, which silently lost the two longest-horizon
-- things the mod holds: the mycotoxin countdown (the penalty reloaded without its
-- clock, so `_decayMycotoxin` never fired and a single bad feeding became permanent)
-- and every active contract (accrued litres, remaining term and premium, gone on
-- every save). Absence is stored as an explicit sentinel rather than an omitted
-- attribute, so no read depends on a nil default.
local OWN_FILE_NONE_NUMBER = -1
local OWN_FILE_NONE_STRING = ""

function DairyCoreManager:_saveOwnFile()
    local path = self:_savePath()
    if path == nil then return end
    local xml = XMLFile.create("dc_SaveXML", path, "dairyCore")
    if xml == nil then return end

    xml:setInt("dairyCore#nextContractId", math.floor(self.nextContractId or 1))

    local i = 0
    for barnId, b in pairs(self.barns) do
        local key = string.format("dairyCore.barn(%d)", i)
        xml:setString(key .. "#id", tostring(barnId))
        xml:setFloat(key .. "#score", b.herdHealthScore or 60)
        xml:setString(key .. "#tier", b.milkQualityTier or "standard")
        xml:setInt(key .. "#myc", math.floor(b.mycotoxinPenalty or 0))
        xml:setInt(key .. "#mycDays", math.floor(b.mycotoxinDaysLeft or 0))
        xml:setString(key .. "#spoilage", self:_normalizeSpoilageKey(b.spoilageStatus))
        xml:setInt(key .. "#spoilageDrop", math.floor(b._spoilageTierDrop or 0))
        xml:setInt(key .. "#interval",
            math.floor(b.collectionInterval or self.settings.defaultCollectionInterval))
        xml:setInt(key .. "#lastCol",
            b.lastCollectionDay ~= nil and math.floor(b.lastCollectionDay) or OWN_FILE_NONE_NUMBER)
        xml:setFloat(key .. "#nextCol", b.nextCollectionDue or OWN_FILE_NONE_NUMBER)
        xml:setString(key .. "#worker",
            b.assignedWorkerId ~= nil and tostring(b.assignedWorkerId) or OWN_FILE_NONE_STRING)
        -- DC-9 milk-round state.
        xml:setFloat(key .. "#lastColH", b.lastCollectionHours or OWN_FILE_NONE_NUMBER)
        xml:setString(key .. "#lastSrc",
            b.lastCollectionSource ~= nil and tostring(b.lastCollectionSource) or OWN_FILE_NONE_STRING)
        xml:setString(key .. "#rota", b.rotaState or DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED)
        xml:setFloat(key .. "#lastLitres",
            (b.lastCollectionLitres and b.lastCollectionLitres[DairyConstants.CONTRACTS.MILK_FILLTYPE])
            or OWN_FILE_NONE_NUMBER)
        xml:setInt(key .. "#contract",
            b.activeContractId ~= nil and math.floor(b.activeContractId) or OWN_FILE_NONE_NUMBER)
        local fs = {}
        for fid in pairs(b.feedSourceFields or {}) do fs[#fs+1] = tostring(fid) end
        table.sort(fs)
        xml:setString(key .. "#feedFields", table.concat(fs, ","))
        i = i + 1
    end

    -- Contracts, mirroring the LEDGER_CONTRACTS record: unsettled only.
    local j = 0
    for id, c in pairs(self.contracts) do
        if not c.settled then
            local key = string.format("dairyCore.contract(%d)", j)
            xml:setString(key .. "#id", tostring(id))
            xml:setString(key .. "#barnId", tostring(c.barnId))
            xml:setInt(key .. "#farmId", math.floor(c.farmId or 1))
            xml:setString(key .. "#type", c.type or "standard")
            xml:setFloat(key .. "#volumeTarget", c.volumeTarget or 0)
            xml:setInt(key .. "#termDays", math.floor(c.termDays or 0))
            xml:setInt(key .. "#daysRemaining", math.floor(c.daysRemaining or 0))
            xml:setFloat(key .. "#premiumRate", c.premiumRate or 1.0)
            xml:setString(key .. "#qualityRequired", c.qualityRequired or OWN_FILE_NONE_STRING)
            xml:setFloat(key .. "#delivered", c.delivered or 0)
            xml:setFloat(key .. "#organicSum", c.organicSum or 0)
            xml:setInt(key .. "#organicDays", math.floor(c.organicDays or 0))
            j = j + 1
        end
    end

    -- FP-1: the feed provenance ledger, flattened per (farm, fill type).
    if self.feedProvenance ~= nil then
        local k = 0
        for farmId, byFt in pairs(self.feedProvenance.provenance) do
            for ft, p in pairs(byFt) do
                local key = string.format("dairyCore.provenance(%d)", k)
                xml:setInt(key .. "#farmId", math.floor(farmId))
                xml:setString(key .. "#ft", tostring(ft))
                xml:setFloat(key .. "#c", p.contaminated or 0)
                xml:setFloat(key .. "#o", p.organic or 0)
                xml:setFloat(key .. "#s",
                    (self.feedProvenance.accum[farmId] and self.feedProvenance.accum[farmId][ft]) or 0)
                k = k + 1
            end
        end
    end

    xml:save()
    xml:delete()
end

function DairyCoreManager:_loadOwnFile()
    local path = self:_savePath()
    if path == nil then return end
    local xml = XMLFile.loadIfExists("dc_SaveXML", path, "dairyCore")
    if xml == nil then return end

    self.nextContractId = xml:getInt("dairyCore#nextContractId", self.nextContractId or 1)

    xml:iterate("dairyCore.barn", function(_, key)
        local rawId = xml:getString(key .. "#id", OWN_FILE_NONE_STRING)
        if rawId == OWN_FILE_NONE_STRING then return end
        local id = tonumber(rawId) or rawId

        local lastCol  = xml:getInt(key .. "#lastCol", OWN_FILE_NONE_NUMBER)
        local nextCol  = xml:getFloat(key .. "#nextCol", OWN_FILE_NONE_NUMBER)
        local worker   = xml:getString(key .. "#worker", OWN_FILE_NONE_STRING)
        local lastColH = xml:getFloat(key .. "#lastColH", OWN_FILE_NONE_NUMBER)
        local lastSrc  = xml:getString(key .. "#lastSrc", OWN_FILE_NONE_STRING)
        local rota     = xml:getString(key .. "#rota", DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED)
        local lastLit  = xml:getFloat(key .. "#lastLitres", OWN_FILE_NONE_NUMBER)
        local contract = xml:getInt(key .. "#contract", OWN_FILE_NONE_NUMBER)

        -- DC-9 repair 2: a restored nextCollectionDue ahead of the clock wedges the
        -- round forever; clamp it to one interval ahead of now.
        if nextCol >= 0 then
            nextCol = math.min(nextCol, self:_nowHours() + (xml:getInt(key .. "#interval",
                self.settings.defaultCollectionInterval)))
        end
        local milkFill = DairyConstants.CONTRACTS.MILK_FILLTYPE
        local lastLitres = {}
        if lastLit >= 0 then lastLitres[milkFill] = lastLit end

        local b = {
            barnId              = id,
            farmId              = 0,   -- resolved by discoverBarns on this machine
            herdHealthScore     = xml:getFloat(key .. "#score", 60),
            milkQualityTier     = xml:getString(key .. "#tier", "standard"),
            milkLitresAvailable = 0,
            mycotoxinPenalty    = xml:getInt(key .. "#myc", 0),
            mycotoxinDaysLeft   = xml:getInt(key .. "#mycDays", 0),
            spoilageStatus      = self:_normalizeSpoilageKey(xml:getString(key .. "#spoilage", "Fresh")),
            _spoilageTierDrop   = xml:getInt(key .. "#spoilageDrop", 0),
            collectionInterval  = xml:getInt(key .. "#interval", self.settings.defaultCollectionInterval),
            lastCollectionDay   = lastCol  >= 0 and lastCol or nil,
            nextCollectionDue   = nextCol  >= 0 and nextCol or nil,
            -- DC-9 repair 4: the worker id is stringified on the own-file path; convert
            -- it back so server and client agree on type (tonumber(x) or x precedent).
            assignedWorkerId    = worker   ~= OWN_FILE_NONE_STRING and (tonumber(worker) or worker) or nil,
            activeContractId    = contract >= 0 and contract or nil,
            feedSourceFields    = {},
            feedDiseaseFlag     = false,
            feedDiseaseCropName = nil,
            ritterMode          = RLBridge.active,
            lastCollectionHours  = lastColH >= 0 and lastColH or nil,
            lastCollectionSource = lastSrc ~= OWN_FILE_NONE_STRING and lastSrc or nil,
            rotaState            = rota,
            lastCollectionLitres = lastLitres,
            lastKnownMilkLevel   = {},
        }
        for fid in string.gmatch(xml:getString(key .. "#feedFields", OWN_FILE_NONE_STRING), "([^,]+)") do
            b.feedSourceFields[tonumber(fid) or fid] = true
        end
        self.barns[id] = b
    end)

    xml:iterate("dairyCore.contract", function(_, key)
        local rawId = xml:getString(key .. "#id", OWN_FILE_NONE_STRING)
        if rawId == OWN_FILE_NONE_STRING then return end
        local id = tonumber(rawId) or rawId
        local rawBarnId = xml:getString(key .. "#barnId", OWN_FILE_NONE_STRING)
        local quality = xml:getString(key .. "#qualityRequired", OWN_FILE_NONE_STRING)

        self.contracts[id] = {
            contractId      = id,
            barnId          = tonumber(rawBarnId) or rawBarnId,
            farmId          = xml:getInt(key .. "#farmId", 1),
            type            = xml:getString(key .. "#type", "standard"),
            volumeTarget    = xml:getFloat(key .. "#volumeTarget", 0),
            termDays        = xml:getInt(key .. "#termDays", 0),
            daysRemaining   = xml:getInt(key .. "#daysRemaining", 0),
            premiumRate     = xml:getFloat(key .. "#premiumRate", 1.0),
            qualityRequired = quality ~= OWN_FILE_NONE_STRING and quality or nil,
            delivered       = xml:getFloat(key .. "#delivered", 0),
            settled         = false,
            organicSum      = xml:getFloat(key .. "#organicSum", 0),
            organicDays     = xml:getInt(key .. "#organicDays", 0),
        }

        -- Same obligation the ledger path carries: a reloaded contract has to go back
        -- on the Time Guard accrual or it stops accruing and never settles or pays.
        self:_registerContractAccrual(id)

        -- Never reissue a live contract's id, even if the counter did not survive.
        local numericId = tonumber(id)
        if numericId ~= nil and self.nextContractId <= numericId then
            self.nextContractId = numericId + 1
        end
    end)

    -- FP-1: restore the feed provenance ledger from the own-file section.
    if self.feedProvenance ~= nil then
        xml:iterate("dairyCore.provenance", function(_, key)
            local farmId = xml:getInt(key .. "#farmId", 0)
            local ft = xml:getString(key .. "#ft", OWN_FILE_NONE_STRING)
            if farmId > 0 and ft ~= OWN_FILE_NONE_STRING then
                self.feedProvenance:blend(farmId, ft, xml:getFloat(key .. "#s", 0),
                    xml:getFloat(key .. "#c", 0), xml:getFloat(key .. "#o", 0))
            end
        end)
    end

    xml:delete()
end

-- =========================================================
-- FarmTablet read model + console
-- =========================================================

-- Read-only per-barn rows for Esc RF PDA / FarmTablet surfaces (autoDetect model).
-- spoilageClockStarted: true after the first collection starts the clock. Idle
-- (nil lastCollectionDay) stays Fresh without faking "collected today". spoilage
-- carries the l10n KEY (dc_spoilage_*), never English display text (DC-14
-- invariant 3); a surface translates it. assignedWorkerId still has no writer here.
-- DC-14: the three-state marking for a published row. On the server every field is
-- the server's own book (`server`). On a client a field is `server` only when it
-- arrived over the wire; farmId is read from the local placeable and so is `local`;
-- anything never received is `unknown` (a default a surface must not present as a
-- fact). Shape is the contract's; the exact fields marked are the row's public ones.
function DairyCoreManager:_rowTrust(b)
    local t = {}
    local wireFields = {
        "herdHealth", "qualityTier", "spoilage", "spoilageClockStarted",
        "feedDiseaseFlag", "feedDiseaseCropName", "feedDiseaseSeverity",
        "mycotoxin", "contractId", "contractProgress", "rotaState", "rotaWorkerName",
        "lastCollectionSource", "lastCollectionHours", "nextCollectionDue",
        "lastCollectionLitres", "storeFull",
    }
    local server = self:_isServer()
    local wire = b._wireReceived == true
    for _, k in ipairs(wireFields) do
        t[k] = server and DairyConstants.TRUST.SERVER
            or (wire and DairyConstants.TRUST.SERVER or DairyConstants.TRUST.UNKNOWN)
    end
    t.barnId = DairyConstants.TRUST.SERVER
    t.ritterMode = DairyConstants.TRUST.SERVER
    t.farmId = server and DairyConstants.TRUST.SERVER or DairyConstants.TRUST.LOCAL
    return t
end

function DairyCoreManager:getBarnRows()
    local rows = {}
    for barnId, b in pairs(self.barns) do
        -- DC-14 3c: a row is a claim that the thing it describes still exists. A
        -- barn proven dead (placeable unresolved across two discovery passes) is a
        -- ghost; the contract does not publish it. The removal repair itself is
        -- DC-1's frame; this is the contract refusing to lie while it runs.
        if not b._probeDead then
            local eff = self:getEffectiveQualityTier(b)
            -- DC-14 invariant 3: the contract carries a KEY, never English display
            -- text. qualityTier and spoilage are keys; a surface translates them.
            local row = { barnId = barnId, ritterMode = b.ritterMode == true,
                herdHealth = math.floor(b.herdHealthScore or 0), qualityTier = eff.key,
                spoilage = self:_normalizeSpoilageKey(b.spoilageStatus),
                spoilageClockStarted = b.lastCollectionDay ~= nil,
                feedDiseaseFlag = b.feedDiseaseFlag == true,
                feedDiseaseCropName = b.feedDiseaseCropName,
                feedDiseaseSeverity = b.feedDiseaseSeverity or 0,
                mycotoxin = b.mycotoxinPenalty or 0,
                contractId = b.activeContractId,
                contractProgress = b.contractProgress or DairyConstants.CONTRACT_PROGRESS.NONE,
                storeFull = b.storeFull == true,
                -- DC-14 3b.6: the farm the row belongs to, on the row.
                farmId = b.farmId,
                -- DC-9 contract: the rota state, the last collection's source and hour,
                -- and the litres that left in it (DC-10 asks for the litres).
                rotaState = b.rotaState or DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED,
                rotaWorkerName = b.assignedWorkerId,
                lastCollectionSource = b.lastCollectionSource,
                lastCollectionHours = b.lastCollectionHours,
                nextCollectionDue = b.nextCollectionDue,
                lastCollectionLitres = b.lastCollectionLitres
                    and b.lastCollectionLitres[DairyConstants.CONTRACTS.MILK_FILLTYPE] or nil }
            -- DC-14 3a: every field declares where it came from.
            row.trust = self:_rowTrust(b)
            if b.ritterMode then
                local counts = RLBridge:getHerdCounts(barnId, b.farmId)
                if counts ~= nil then row.counts = counts end
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- =========================================================
-- DC-19: the co-op herd advisory (read-only, gated by the ProStaff flag)
-- =========================================================

-- The gate flag: has the farm's co-op reached the level that publishes the herd
-- advisory? Read through the shared ProStaff accessor with NO farmId, deliberately
-- inheriting the farmId-blind read the DC-6/DC-7 read architecture fixes once (the
-- same class as F75; a local patch here would leave two patches for one bug). The
-- flag's level gate lives in the ProStaffCoOp callback itself (false below L12);
-- DairyCore never checks a level. Neutral-false when ProStaffCoOp is absent, so the
-- advisory stays off until the flag exists. farmId is accepted for the published
-- getter contract and matches the ProStaff flag's own signature; the read itself is
-- farmId-blind by design.
function DairyCoreManager:hasHerdAdvisory(farmId)
    return self:_proStaff("hasHerdAdvisory", false)
end

-- The public advisory getter: a list of advisory strings, one per barn of the farm
-- that needs attention, or an empty list when the gate does not apply. Advisory-only:
-- formats state that already exists (herdHealthScore and the spoilage stage), NEVER
-- writes state, moves money or applies economics. farmId filters to that farm's barns;
-- nil returns every barn (the optional-farm convention the ProStaff getters use).
function DairyCoreManager:getHerdAdvisories(farmId)
    if not self:hasHerdAdvisory(farmId) then return {} end
    local out = {}
    for barnId, barn in pairs(self.barns) do
        if farmId == nil or barn.farmId == nil or barn.farmId == farmId then
            local sentence = self:_herdAdvisoryForBarn(barn)
            if sentence ~= nil then out[#out + 1] = sentence end
        end
    end
    return out
end

-- The advisory sentence for one barn, or nil when the barn needs no attention.
-- EITHER condition qualifies: herd health at or below the needs-attention cutoff
-- (the Standard tier's minScore, reused from QUALITY.TIERS so the language cannot
-- drift from what _qualityTierForScore / the Financial Cockpit show), or a spoilage
-- stage that is Ageing or worse (DC-8 lifecycle). Both reasons join into one sentence.
function DairyCoreManager:_herdAdvisoryForBarn(barn)
    local reasons = {}
    if (barn.herdHealthScore or 0) <= self:_herdAdvisoryCutoff() then
        reasons[#reasons + 1] = DairyConstants.HERD_ADVISORY.HEALTH
    end
    local stage = self:_normalizeSpoilageKey(barn.spoilageStatus)
    if DairyConstants.HERD_ADVISORY.SPOILAGE_STAGES[stage] then
        reasons[#reasons + 1] = DairyConstants.HERD_ADVISORY.SPOILAGE
    end
    if #reasons == 0 then return nil end
    return string.format(DairyConstants.HERD_ADVISORY.SENTENCE, tostring(barn.barnId),
        table.concat(reasons, DairyConstants.HERD_ADVISORY.JOIN))
end

-- The needs-attention health cutoff: the minScore of the tier named by
-- HEALTH_CUTOFF_TIER, read from the SAME table _qualityTierForScore reads, so the
-- advisory uses the tiering constant and never a copied magic number.
function DairyCoreManager:_herdAdvisoryCutoff()
    for _, tier in ipairs(DairyConstants.QUALITY.TIERS) do
        if tier.key == DairyConstants.HERD_ADVISORY.HEALTH_CUTOFF_TIER then
            return tier.minScore
        end
    end
    return 60
end

function DairyCoreManager:consoleCommandStatus()
    local lines = {}
    table.insert(lines, string.format("DairyCore: %s, mode=%s, barns=%d, contracts=%d, bedrock=%s",
        self.settings.enabled and "enabled" or "disabled",
        RLBridge.active and "Ritter" or "Standard", self:_countBarns(),
        (function() local n=0 for _ in pairs(self.contracts) do n=n+1 end return n end)(),
        tostring(self.bedrockBound)))
    for barnId, b in pairs(self.barns) do
        local eff = self:getEffectiveQualityTier(b)
        local milkFill = DairyConstants.CONTRACTS.MILK_FILLTYPE
        table.insert(lines, string.format("  barn %s: health=%d tier=%s spoilage=%s myc=%d contract=%s",
            tostring(barnId), math.floor(b.herdHealthScore or 0), eff.name, b.spoilageStatus,
            b.mycotoxinPenalty or 0, tostring(b.activeContractId)))
        -- DC-9: the milk-round view, so a tanker drain or a rota run is actually
        -- observable in game rather than only in the save.
        table.insert(lines, string.format("    rota=%s worker=%s",
            tostring(b.rotaState or "unassigned"),
            tostring(b.assignedWorkerId or "none")))
        table.insert(lines, string.format("    lastColDay=%s hours=%s source=%s litres=%s nextDue=%s",
            tostring(b.lastCollectionDay or "-"),
            tostring(b.lastCollectionHours or "-"),
            tostring(b.lastCollectionSource or "-"),
            tostring((b.lastCollectionLitres and b.lastCollectionLitres[milkFill]) or "-"),
            tostring(b.nextCollectionDue or "-")))
    end
    return table.concat(lines, "\n")
end

-- ── Console test commands (server-only; the rota and sale have no UI surface yet,
-- so these exist so the in-game pass can exercise them). ──

function DairyCoreManager:consoleAssignRota(barnId, workerId)
    if not self:_isServer() then return "server only" end
    local ok = self:assignCollectionWorker(barnId, workerId)
    if ok then
        local barn = self.barns[barnId]
        if barn ~= nil and barn.nextCollectionDue ~= nil then
            return string.format("assigned %s to barn %s; next window at hour %s",
                tostring(workerId), tostring(barnId), tostring(barn.nextCollectionDue))
        end
        return "assigned " .. tostring(workerId) .. " to barn " .. tostring(barnId)
    end
    return "assign failed (server-only; check barn id)"
end

function DairyCoreManager:consoleUnassignRota(barnId)
    if not self:_isServer() then return "server only" end
    return self:unassignCollectionWorker(barnId) and "unassigned" or "failed"
end

function DairyCoreManager:consoleSellMilk(barnId, litres)
    if not self:_isServer() then return "server only" end
    local removed, status = self:sellMilk(barnId, litres)
    if removed ~= nil then
        return string.format("sold %d L (source office, %s)", math.floor(removed), status)
    end
    return "no sale: " .. tostring(status or "unknown")
end

function DairyCoreManager:consoleCollectionTick()
    if not self:_isServer() then return "server only" end
    self:onCollectionHourTick({ monotonicDay = self:_monotonicDay() })
    return "collection hour tick run"
end

function DairyCoreManager:consoleFeedProvenance()
    if self.feedProvenance == nil then return "feed provenance not initialised" end
    return self.feedProvenance:consoleDump()
end
