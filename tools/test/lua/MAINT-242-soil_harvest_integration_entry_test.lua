-- MAINT-242-soil_harvest_integration_entry_test.lua - MAINTENANCE rows 242 and 260:
-- DairyCore's Soil harvest integration works in a game.
--
-- Row 242: Dairy read Soil through the bare global g_SoilFertilityManager, which Soil
-- writes into its own mod environment (getfenv(0), SoilFertilizer main.lua:758), so the
-- read was nil in a game. Dairy now reads g_currentMission.soilFertilityManager first
-- (main.lua:761), at both sites: the contract's organic credit and the harvest capture.
-- Row 260: Soil publishes its harvest bus as plain functions, subscribe(name, fn) and
-- unsubscribe(name) (main.lua:800-803); Dairy called them with a colon, which passes the
-- bus table as the name, and subscribeHarvest refused it without an error.
--
-- THE ENTRY-POINT BAR IS E1 to E6. Soil is modelled in its own mod environment, built as
-- dataS mods.lua:482-520 builds one (__index = _G, _G = the env itself, getfenv(0) maps
-- to it), and its load runs inside that environment: the manager goes into Soil's env and
-- onto the mission, and the bus goes onto the mission with Soil's own shape. Soil's
-- subscribeHarvest, unsubscribeHarvest and _emitHarvest are copied verbatim from
-- SoilFertilitySystem.lua:761-806 at 437ca320 (payload and the pcall per listener). Dairy
-- enters as main.lua does: DairyCoreManager.new() (:53), the mission handle (:58) and
-- onMissionLoaded (:63-64, appended to loadMission00Finished at :84). Barns come from the placeable system through discoverBarns,
-- designations through designateFeedField, the contract through acceptContract and the
-- Time Guard's registered accrual, the day through the Time Guard's subscribed day tick. Nothing writes a listener, a provenance entry, a
-- designation or a contract by hand.
--
--   E0  the world: Dairy's environment has no g_SoilFertilityManager; Soil's has it
--   E1  onMissionLoaded registers both listeners on Soil's bus (row 260)
--   E2  a published harvest from a certified field reaches provenance with organic 1
--       (rows 242 and 260)
--   E3  a diseased harvest on a designated field sets that barn's mycotoxin penalty
--       (DC-11, row 260)
--   E4  a contract day reads the designated fields from Soil (0.75 for one certified
--       field and one at 15 of 30 transition days) (row 242)
--   E6  diseased grain harvested on Soil's bus raises the farm's feed pool, and the next
--       day tick gives a barn with NO designated field the scaled pool penalty (D1's
--       trough exposure, _applyTroughExposure; Bob's R-15 MAJOR): the effect a game
--       reaches without any designation (rows 242 and 260)
--   E5  onMissionDelete removes both listeners (row 260)
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

getfenv = getfenv or function() return _G end

-- ── the engine world ─────────────────────────────────────────────────────────
FarmManager = { MAX_NUM_FARMS = 8, MAX_FARM_ID = 8, SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1,
  GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
MoneyType = { OTHER = 1 }
XMLFile = { loadIfExists = function() return nil end }
g_modIsLoaded = {}
g_server = { broadcastEvent = function() end }
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
local FRUIT = { [1] = "WHEAT", [2] = "MAIZE" }
g_fruitTypeManager = { getFruitTypeByIndex = function(_, idx) return FRUIT[idx] and { name = FRUIT[idx] } or nil end }
-- Field -> owning farm. Field 10 is farm 3's, field 12 farm 4's, fields 20 and 21 farm 5's,
-- field 30 farm 6's.
local OWNER = { [10] = 3, [12] = 4, [20] = 5, [21] = 5, [30] = 6 }
g_farmlandManager = { getFarmlandById = function(_, id) return OWNER[id] and { farmId = OWNER[id] } or nil end }

local accruals, ticks = {}, {}
local mission = {
  _isServer = true,
  missionInfo = { savegameDirectory = "savegame1" },
  missionDynamicInfo = { isMultiplayer = false },
  environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
  placeableSystem = { placeables = {} },
  money = {},
  timeGuard = {
    registerAccrual = function(_, name, spec) accruals[name] = spec end,
    subscribeTick = function(_, kind, name, fn) ticks[kind] = fn end,
  },
}
function mission:getIsServer() return self._isServer end
function mission:addMoney(income, farmId) self.money[#self.money + 1] = { income = income, farmId = farmId } end

local function barnPlaceable(id, owner)
  local p = { spec_husbandryMilk = {}, _owner = owner }
  function p:getUniqueId() return id end
  function p:getOwnerFarmId() return self._owner end
  return p
end
mission.placeableSystem.placeables = { barnPlaceable("barn_B1", 4), barnPlaceable("barn_B2", 5),
  barnPlaceable("barn_B3", 6) }

-- ── Soil, in its own mod environment (mods.lua:482-520) ─────────────────────
local soilEnv = setmetatable({}, { __index = _G })
soilEnv._G = soilEnv
soilEnv.getfenv = function() return soilEnv end

local SOIL_LOAD = [==[
local mission = ...
SoilLogger = { warnings = {} }
function SoilLogger.info() end
function SoilLogger.warning(fmt, ...) SoilLogger.warnings[#SoilLogger.warnings + 1] = string.format(fmt, ...) end

local SoilFertilitySystem = {}
SoilFertilitySystem.__index = SoilFertilitySystem

-- SoilFertilitySystem.lua:761-806 at 437ca320, verbatim.
function SoilFertilitySystem:subscribeHarvest(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return false end
    self.harvestListeners[name] = fn
    SoilLogger.info("Harvest bus: listener '%s' registered", name)
    return true
end

function SoilFertilitySystem:unsubscribeHarvest(name)
    if self.harvestListeners[name] == nil then return false end
    self.harvestListeners[name] = nil
    SoilLogger.info("Harvest bus: listener '%s' removed", name)
    return true
end

function SoilFertilitySystem:_emitHarvest(fieldId, fruitTypeIndex, liters, area)
    if next(self.harvestListeners) == nil then return end
    local field = self.fieldData[fieldId]
    local payload = {
        fieldId              = fieldId,
        fruitTypeIndex       = fruitTypeIndex,
        liters               = liters or 0,
        area                 = area or 0,
        diseasePressure      = field and field.diseasePressure or 0,
        activeDisease        = field and field.activeDisease or nil,
        activeDiseaseSeverity = field and field.activeDiseaseSeverity or 1.0,
    }
    for name, fn in pairs(self.harvestListeners) do
        local ok, err = pcall(fn, payload)
        if not ok then
            SoilLogger.warning("Harvest bus: listener '%s' errored: %s", tostring(name), tostring(err))
        end
    end
end

-- OrganicCertification:getFieldOrganicState's return shape (OrganicCertification.lua:167-184),
-- read from the field's own organic state.
local sfm = { soilSystem = setmetatable({ harvestListeners = {}, fieldData = {} }, SoilFertilitySystem) }
sfm.organic = {}
function sfm.organic:getFieldOrganicState(fieldId)
    local field = sfm.soilSystem.fieldData[fieldId]
    if not field or not field.organic then return nil end
    local o = field.organic
    return { state = o.state, daysAccrued = o.daysAccrued or 0, transitionDaysNeeded = o.needed or 120,
             certified = (o.state == "certified"), breaches = 0 }
end

-- main.lua:758, :761 and :800-803 at 437ca320.
getfenv(0)["g_SoilFertilityManager"] = sfm
mission.soilFertilityManager = sfm
if sfm.soilSystem then
    mission.soilHarvestBus = {
        subscribe   = function(name, fn) return sfm.soilSystem:subscribeHarvest(name, fn) end,
        unsubscribe = function(name)     return sfm.soilSystem:unsubscribeHarvest(name) end,
    }
end
return sfm
]==]

g_currentMission = mission
local chunk = assert(load(SOIL_LOAD, "=SoilFertilizer main.lua (model)", "t", soilEnv))
local sfm = chunk(mission)
local listeners = sfm.soilSystem.harvestListeners

-- ── DairyCore, entering as main.lua does ────────────────────────────────────
local dc = DairyCoreManager.new()
mission.dairyCoreManager = dc
dc:onMissionLoaded()

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

group("E0", function()
  T.eq("E0: Dairy's environment has no g_SoilFertilityManager", g_SoilFertilityManager, nil)
  T.ok("E0: Soil's own environment has it", soilEnv.g_SoilFertilityManager == sfm)
  T.ok("E0: the mission carries Soil's manager and bus", mission.soilFertilityManager == sfm and mission.soilHarvestBus ~= nil)
  T.ok("E0: the three barns were discovered from the placeable system",
    dc.barns.barn_B1 ~= nil and dc.barns.barn_B2 ~= nil and dc.barns.barn_B3 ~= nil)
end)

group("E1", function()
  T.eq("E1: the provenance listener is registered on Soil's bus", type(listeners.DairyCore_FeedProvenance), "function")
  T.eq("E1: the contamination listener is registered on Soil's bus", type(listeners.DairyCore_FeedContamination), "function")
  T.eq("E1: the manager records the bus as bound", dc.harvestBound, true)
end)

T.eq("designation: barn_B1 designates field 12", dc:designateFeedField("barn_B1", 12), true)
T.eq("designation: barn_B2 designates field 20", dc:designateFeedField("barn_B2", 20), true)
T.eq("designation: barn_B2 designates field 21", dc:designateFeedField("barn_B2", 21), true)

group("E2", function()
  sfm.soilSystem.fieldData[10] = { diseasePressure = 0, organic = { state = "certified" } }
  T.eq("E2: farm 3 has no provenance before the harvest", dc.feedProvenance:hasData(3), false)
  sfm.soilSystem:_emitHarvest(10, 1, 200, 0.5)
  T.eq("E2: the harvest reached farm 3's provenance", dc.feedProvenance:hasData(3), true)
  local g = dc.feedProvenance:getFraction(3, "WHEAT")
  T.eq("E2: a certified field's harvest is recorded organic 1", g and g.organic, 1.0)
  T.eq("E2: a clean harvest is recorded contaminated 0", g and g.contaminated, 0.0)
end)

group("E3", function()
  local myc = DairyConstants.MYCOTOXIN
  sfm.soilSystem.fieldData[12] = { diseasePressure = 60, activeDisease = "FUSARIUM", organic = { state = "conventional" } }
  T.eq("E3: barn_B1 starts clean", dc.barns.barn_B1.mycotoxinPenalty, 0)
  sfm.soilSystem:_emitHarvest(12, 2, 300, 0.5)
  T.eq("E3: the diseased harvest sets barn_B1's mycotoxin penalty", dc.barns.barn_B1.mycotoxinPenalty,
    myc.MIN_PENALTY + math.floor((60 / 100) * (myc.MAX_PENALTY - myc.MIN_PENALTY)))
  T.eq("E3: and its countdown", dc.barns.barn_B1.mycotoxinDaysLeft,
    math.floor(myc.MIN_DAYS + (60 / 100) * (myc.MAX_DAYS - myc.MIN_DAYS)))
  T.eq("E3: barn_B2, which did not designate field 12, stays clean", dc.barns.barn_B2.mycotoxinPenalty, 0)
end)

group("E4", function()
  sfm.soilSystem.fieldData[20] = { organic = { state = "certified" } }
  sfm.soilSystem.fieldData[21] = { organic = { state = "in_transition", daysAccrued = 15, needed = 30 } }
  T.eq("E4: farm 5 has no provenance, so the contract reads the fields", dc.feedProvenance:hasData(5), false)
  local id = dc:acceptContract("barn_B2", "standard")
  T.ok("E4: the contract was accepted", id ~= nil)
  local spec = accruals["DairyCore_contract_" .. tostring(id)]
  T.ok("E4: the contract registered its day with the Time Guard", spec ~= nil and type(spec.onSettle) == "function")
  spec.onSettle({ boundariesCrossed = 1 })
  local c = dc.contracts[id]
  T.eq("E4: one contract day was accrued", c.organicDays, 1)
  T.near("E4: the day's organic credit is read from Soil's designated fields", c.organicSum, 0.75, 1e-9)
end)

group("E6", function()
  local myc = DairyConstants.MYCOTOXIN
  sfm.soilSystem.fieldData[30] = { diseasePressure = 40, activeDisease = "FUSARIUM", organic = { state = "conventional" } }
  T.eq("E6: barn_B3 has no designated feed field", next(dc.barns.barn_B3.feedSourceFields), nil)
  T.eq("E6: barn_B3 starts clean", dc.barns.barn_B3.mycotoxinPenalty, 0)
  sfm.soilSystem:_emitHarvest(30, 1, 300, 0.5)
  T.near("E6: the diseased grain raised farm 6's contaminated feed fraction",
    dc.feedProvenance:contaminatedFeedFraction(6), 0.4, 1e-9)
  T.eq("E6: the harvest itself sets no acute penalty on an undesignated barn", dc.barns.barn_B3.mycotoxinPenalty, 0)
  T.eq("E6: the manager subscribed its day tick on the Time Guard", type(ticks.day), "function")
  ticks.day({ monotonicDay = 101 })
  T.eq("E6: the next day's trough exposure gives barn_B3 the scaled pool penalty", dc.barns.barn_B3.mycotoxinPenalty,
    myc.MIN_PENALTY + math.floor((40 / 100) * (myc.MAX_PENALTY - myc.MIN_PENALTY)))
  T.eq("E6: with at least a day to run", dc.barns.barn_B3.mycotoxinDaysLeft, 1)
  T.eq("E6: barn_B2, whose farm harvested nothing, stays clean", dc.barns.barn_B2.mycotoxinPenalty, 0)
end)

group("E5", function()
  dc:onMissionDelete()
  T.eq("E5: the provenance listener is removed from Soil's bus", listeners.DairyCore_FeedProvenance, nil)
  T.eq("E5: the contamination listener is removed from Soil's bus", listeners.DairyCore_FeedContamination, nil)
  T.eq("E5: the manager records the bus as unbound", dc.harvestBound, false)
end)

T.eq("Soil logged no listener error", #soilEnv.SoilLogger.warnings, 0)
