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
    self.settings = {
        enabled                 = true,
        defaultCollectionInterval = DairyConstants.COLLECTION.DEFAULT_INTERVAL_HOURS,
        spoilageEnabled         = true,
        contractsEnabled        = true,
    }
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
    self:discoverBarns()

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

    if hs.getPlaceablesByFarm ~= nil then
        for _, farmId in ipairs(self:_farmIdsToScan()) do
            local placeables = nil
            pcall(function() placeables = hs:getPlaceablesByFarm(farmId) end)
            self:_registerBarnsFrom(placeables, farmId)
        end
        return
    end

    -- No per-farm enumerator. Take the whole set once and let each placeable name its
    -- own owner, which is the same question asked a different way.
    self:_registerBarnsFrom(hs.placeables or hs.husbandries, nil)
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
            spoilageStatus = "Fresh",
            feedSourceFields = {},
            feedDiseaseFlag = false,
            feedDiseaseCropName = nil,
            mycotoxinPenalty = 0,
            mycotoxinDaysLeft = 0,
            collectionInterval = self.settings.defaultCollectionInterval,
            nextCollectionDue = nil,
            assignedWorkerId = nil,
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
function DairyCoreManager:_workerLevelName(barn)
    local levelName = "experienced"  -- neutral default
    pcall(function()
        local wc = g_currentMission ~= nil and g_currentMission.workerCostsManager
        if wc == nil then return end
        local snap = wc.getRosterSnapshot ~= nil and wc:getRosterSnapshot() or nil
        if snap == nil or snap.workers == nil then return end
        for _, w in ipairs(snap.workers) do
            if barn.assignedWorkerId ~= nil and w.uuid == barn.assignedWorkerId then
                levelName = w.levelName or w.level or levelName
                return
            end
        end
    end)
    return levelName
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
        if self.settings.spoilageEnabled then
            self:_updateSpoilage(barn, currentDay)
        end
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

-- Advance one spoilage stage by moving lastCollectionDay across the next
-- stage threshold (comment contract: one stage per crossed missed window).
-- Starts the clock on first miss when lastCollectionDay was nil.
function DairyCoreManager:_advanceSpoilageOneStage(barn, currentDay)
    local sp = DairyConstants.SPOILAGE
    local freshDays = sp.FRESH_DAYS
    if self:_proStaffLevel() >= 18 then
        freshDays = freshDays + (sp.L18_FRESH_BONUS_HOURS / 24)
    end
    local daysSince = 0
    if barn.lastCollectionDay ~= nil then
        daysSince = math.max(0, currentDay - barn.lastCollectionDay)
    end
    local targetDays
    if daysSince < freshDays then
        targetDays = freshDays
    elseif daysSince < sp.AGEING_DAYS then
        targetDays = sp.AGEING_DAYS
    elseif daysSince < sp.ATRISK_DAYS then
        targetDays = sp.ATRISK_DAYS
    else
        -- Already condemned; keep ageing from current lastCollectionDay.
        self:_updateSpoilage(barn, currentDay)
        return
    end
    barn.lastCollectionDay = currentDay - targetDays
    self:_updateSpoilage(barn, currentDay)
    self:_markBarnsDirty()
end

function DairyCoreManager:_updateSpoilage(barn, currentDay)
    -- Nil lastCollectionDay means the clock has never started. Do NOT treat
    -- that as "collected today" (forever-Fresh). Stay Fresh with zero drop
    -- until markCollected or a missed window starts the clock.
    if barn.lastCollectionDay == nil then
        barn.spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.name
        barn._spoilageTierDrop = 0
        return
    end
    local daysSince = math.max(0, currentDay - barn.lastCollectionDay)
    local stage = self:_spoilageStage(daysSince)
    barn.spoilageStatus = stage.name
    barn._spoilageTierDrop = stage.tierDrop
end

-- Effective sale tier = herd quality tier dropped by the spoilage stage.
function DairyCoreManager:getEffectiveQualityTier(barn)
    local idx = self:_tierIndexByKey(barn.milkQualityTier)
    local drop = barn._spoilageTierDrop or 0
    idx = math.min(#DairyConstants.QUALITY.TIERS, idx + drop)
    return DairyConstants.QUALITY.TIERS[idx]
end

-- Called when a collection actually happens (administrative; resets the timer).
function DairyCoreManager:markCollected(barn, currentDay)
    barn.lastCollectionDay = currentDay
    barn.spoilageStatus = "Fresh"
    barn._spoilageTierDrop = 0
    barn._missedWindow = nil
    self:_markBarnsDirty()
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
    local hourOfDay = 0
    pcall(function()
        local env = g_currentMission and g_currentMission.environment
        hourOfDay = env and (env.dayTime / (60*60*1000)) or 0
    end)
    local nowHours = monotonicDay * 24 + hourOfDay

    for _, barn in pairs(self.barns) do
        if barn.nextCollectionDue == nil then
            barn.nextCollectionDue = nowHours + (barn.collectionInterval or 24)
        elseif nowHours >= barn.nextCollectionDue then
            -- A scheduled window has arrived. If no worker is assigned the window is
            -- MISSED -> spoilage advances one stage (once per crossed window).
            if barn.assignedWorkerId == nil then
                barn._missedWindow = true
                DCLogger.debug("Barn %s: collection window missed (no worker assigned)", tostring(barn.barnId))
                -- Finish the dead path: consume _missedWindow by ageing via stage
                -- thresholds. Does not invent assignedWorkerId writers.
                self:_advanceSpoilageOneStage(barn, monotonicDay)
                barn._missedWindow = nil
            else
                local skill = DairyConstants.COLLECTION.SKILL[self:_workerLevelName(barn)]
                              or DairyConstants.COLLECTION.SKILL.experienced
                self:markCollected(barn, ctx.monotonicDay or 0)
                barn._lastRunSpeedMod = skill.speedMod
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
-- diseaseDiscovered is true; otherwise which-field-only).
function DairyCoreManager:_refreshFeedDiseaseFlag(barn)
    barn.feedDiseaseFlag = false
    barn.feedDiseaseCropName = nil
    for fieldId in pairs(barn.feedSourceFields) do
        local info = self:_getFieldInfo(fieldId)
        if info ~= nil and info.activeDisease ~= nil then
            barn.feedDiseaseFlag = true
            if info.diseaseDiscovered == true then
                barn.feedDiseaseCropName = info.activeDisease
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
        local qualityFactor = self:_qualityTierForScore(barn.herdHealthScore).priceMod
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

--- OM-211: mean organic credit of the barn's designated feed fields, 0..1.
--- Reads SoilFertilizer's shipped OrganicCertification authority
--- (g_SoilFertilityManager.organic, delegate-when-present). SF absent, no
--- designations, or no readable fields => 0, so the pay factor stays 1.0.
--- Certified return shape: { state, daysAccrued, transitionDaysNeeded, certified, breaches }.
---@param barn table
---@return number  mean organic credit 0..1 (0 when SF is absent or unreadable)
function DairyCoreManager:_barnOrganicFraction(barn)
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

    -- Sovereign floor (ProStaff L20): floor the effective per-litre at 85% of base price.
    if self:_proStaffLevel() >= 20 then
        local floor = spot * DairyConstants.CONTRACTS.TYPES.sovereign_floor.floorFraction
        if spot * premium < floor then premium = floor / spot end
    end

    -- DairyCore's own livestock-boom milk premium (keyed on the MD event id).
    if self:_mdEventActive("livestock_boom") then
        premium = premium * DairyConstants.CONTRACTS.LIVESTOCK_BOOM_MILK_BONUS
    end

    -- OM-211: organic-feed milk premium, AFTER the sovereign floor, beside the
    -- boom bonus. Mean organic credit over the contract's accrual days scales the
    -- factor between 1.0 (no organic feed) and ORGANIC_MILK_PREMIUM_MAX; the
    -- formula floors at 1.0 so organic can only add. An old save loads organicSum
    -- / organicDays nil and the guard treats that as zero organic days (1.0).
    if (c.organicDays and c.organicDays > 0) and
       (c.organicSum and c.organicSum > 0) then
        local organicFactor = c.organicSum / c.organicDays
        premium = premium * (1 + organicFactor * (DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX - 1))
    end

    local litres = math.min(c.delivered, c.volumeTarget)
    local income = math.floor(litres * spot * premium)
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
            },
            onChange = function(key, value)
                if key == "enabled" then self.settings.enabled = value ~= false
                elseif key == "defaultCollectionInterval" then self.settings.defaultCollectionInterval = value
                elseif key == "spoilageEnabled" then self.settings.spoilageEnabled = value ~= false
                elseif key == "contractsEnabled" then self.settings.contractsEnabled = value ~= false end
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
        out[tostring(barnId)] = {
            herdHealthScore = b.herdHealthScore, milkQualityTier = b.milkQualityTier,
            spoilageStatus = b.spoilageStatus, lastCollectionDay = b.lastCollectionDay,
            feedSourceFields = fields, mycotoxinPenalty = b.mycotoxinPenalty,
            mycotoxinDaysLeft = b.mycotoxinDaysLeft, collectionInterval = b.collectionInterval,
            assignedWorkerId = b.assignedWorkerId, activeContractId = b.activeContractId,
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
        b.spoilageStatus = s.spoilageStatus or "Fresh"
        b.lastCollectionDay = s.lastCollectionDay
        b.mycotoxinPenalty = s.mycotoxinPenalty or 0
        b.mycotoxinDaysLeft = s.mycotoxinDaysLeft or 0
        b.collectionInterval = s.collectionInterval or self.settings.defaultCollectionInterval
        b.assignedWorkerId = s.assignedWorkerId
        b.activeContractId = s.activeContractId
        b.feedSourceFields = {}
        for _, fid in ipairs(s.feedSourceFields or {}) do b.feedSourceFields[fid] = true end
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

-- Compact barn state for MP. Exactly BARN_STRIDE flat scalars per barn, in order:
--    1 barnId (string)             2 herd health score (int)
--    3 quality tier index (int)    4 spoilage tier drop (int)
--    5 mycotoxin penalty (int)     6 collection interval hours (int)
--    7 assignedWorkerId (string, NONE_STRING when unassigned)
--    8 lastCollectionDay (int, NONE_NUMBER when never collected)
--    9 nextCollectionDue (number, NONE_NUMBER when unscheduled)
--   10 feedSourceFields (comma-joined ids, NONE_STRING when none)
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
            b.herdHealthScore    = arr[i+1]
            b.milkQualityTier    = (DairyConstants.QUALITY.TIERS[arr[i+2]] or DairyConstants.QUALITY.TIERS[2]).key
            b._spoilageTierDrop  = arr[i+3]
            b.mycotoxinPenalty   = arr[i+4]
            b.collectionInterval = arr[i+5]
            b.assignedWorkerId   = arr[i+6] ~= net.NONE_STRING and arr[i+6] or nil
            b.lastCollectionDay  = arr[i+7] ~= net.NONE_NUMBER and arr[i+7] or nil
            b.nextCollectionDue  = arr[i+8] ~= net.NONE_NUMBER and arr[i+8] or nil
            b.feedSourceFields   = {}
            for fid in string.gmatch(tostring(arr[i+9] or ""), "([^,]+)") do
                b.feedSourceFields[tonumber(fid) or fid] = true
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
        xml:setString(key .. "#spoilage", b.spoilageStatus or "Fresh")
        xml:setInt(key .. "#spoilageDrop", math.floor(b._spoilageTierDrop or 0))
        xml:setInt(key .. "#interval",
            math.floor(b.collectionInterval or self.settings.defaultCollectionInterval))
        xml:setInt(key .. "#lastCol",
            b.lastCollectionDay ~= nil and math.floor(b.lastCollectionDay) or OWN_FILE_NONE_NUMBER)
        xml:setFloat(key .. "#nextCol", b.nextCollectionDue or OWN_FILE_NONE_NUMBER)
        xml:setString(key .. "#worker",
            b.assignedWorkerId ~= nil and tostring(b.assignedWorkerId) or OWN_FILE_NONE_STRING)
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
        local contract = xml:getInt(key .. "#contract", OWN_FILE_NONE_NUMBER)

        local b = {
            barnId              = id,
            farmId              = 0,   -- resolved by discoverBarns on this machine
            herdHealthScore     = xml:getFloat(key .. "#score", 60),
            milkQualityTier     = xml:getString(key .. "#tier", "standard"),
            milkLitresAvailable = 0,
            mycotoxinPenalty    = xml:getInt(key .. "#myc", 0),
            mycotoxinDaysLeft   = xml:getInt(key .. "#mycDays", 0),
            spoilageStatus      = xml:getString(key .. "#spoilage", "Fresh"),
            _spoilageTierDrop   = xml:getInt(key .. "#spoilageDrop", 0),
            collectionInterval  = xml:getInt(key .. "#interval", self.settings.defaultCollectionInterval),
            lastCollectionDay   = lastCol  >= 0 and lastCol or nil,
            nextCollectionDue   = nextCol  >= 0 and nextCol or nil,
            assignedWorkerId    = worker   ~= OWN_FILE_NONE_STRING and worker or nil,
            activeContractId    = contract >= 0 and contract or nil,
            feedSourceFields    = {},
            feedDiseaseFlag     = false,
            feedDiseaseCropName = nil,
            ritterMode          = RLBridge.active,
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

    xml:delete()
end

-- =========================================================
-- FarmTablet read model + console
-- =========================================================

-- Read-only per-barn rows for Esc RF PDA / FarmTablet surfaces (autoDetect model).
-- spoilageClockStarted: true after markCollected OR after a missed window starts
-- the clock via _advanceSpoilageOneStage. Idle (nil lastCollectionDay) stays Fresh
-- without faking "collected today". assignedWorkerId still has no writer here.
function DairyCoreManager:getBarnRows()
    local rows = {}
    for barnId, b in pairs(self.barns) do
        local eff = self:getEffectiveQualityTier(b)
        local row = { barnId = barnId, ritterMode = b.ritterMode == true,
            herdHealth = math.floor(b.herdHealthScore or 0), qualityTier = eff.name,
            spoilage = b.spoilageStatus, spoilageClockStarted = b.lastCollectionDay ~= nil,
            feedDiseaseFlag = b.feedDiseaseFlag == true,
            feedDiseaseCropName = b.feedDiseaseCropName, mycotoxin = b.mycotoxinPenalty or 0,
            contractId = b.activeContractId }
        if b.ritterMode then
            local counts = RLBridge:getHerdCounts(barnId, b.farmId)
            if counts ~= nil then row.counts = counts end
        end
        rows[#rows + 1] = row
    end
    return rows
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
        table.insert(lines, string.format("  barn %s: health=%d tier=%s spoilage=%s myc=%d contract=%s",
            tostring(barnId), math.floor(b.herdHealthScore or 0), eff.name, b.spoilageStatus,
            b.mycotoxinPenalty or 0, tostring(b.activeContractId)))
    end
    return table.concat(lines, "\n")
end
