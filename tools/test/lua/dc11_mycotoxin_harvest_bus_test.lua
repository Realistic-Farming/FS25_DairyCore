-- dc11_mycotoxin_harvest_bus_test.lua - DC-11 / F105: harvest contamination routing.
--
-- SoilFertilizer publishes g_currentMission.soilHarvestBus (the suite's
-- neutral-when-absent disease-at-harvest broadcast). DairyCore subscribes twice:
-- FP-1 feeds provenance, and this member routes a harvest cut of a designated
-- feed field into the barn's mycotoxin penalty via applyFeedContaminationPenalty.
-- A clean cut (diseasePressure 0) is not contamination and must not route,
-- because a zero-severity call still imposes MIN_PENALTY for MIN_DAYS.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

-- Engine mock
g_currentMission = {
  _isServer = true,
  missionInfo = { savegameDirectory = "savegame1" },
  environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
  money = {},
}
function g_currentMission:getIsServer() return self._isServer end
function g_currentMission:addMoney() end
MoneyType = { OTHER = 1 }
g_server = {}
g_modIsLoaded = {}
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}

local function newManager(barns)
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  m.barns = barns or {}
  return m
end

local myc = DairyConstants.MYCOTOXIN

-- A diseased cut on a designated field sets the penalty and the countdown.
local m = newManager({
  b1 = { barnId = "b1", farmId = 1, feedSourceFields = { [5] = true } },
  b2 = { barnId = "b2", farmId = 2, feedSourceFields = {} },
})
m:_applyHarvestContamination({ fieldId = 5, diseasePressure = 60 })
T.eq("a designated field harvest sets the penalty",
  m.barns.b1.mycotoxinPenalty,
  myc.MIN_PENALTY + math.floor((60 / 100) * (myc.MAX_PENALTY - myc.MIN_PENALTY)))
T.eq("and sets the countdown",
  m.barns.b1.mycotoxinDaysLeft,
  math.floor(myc.MIN_DAYS + (60 / 100) * (myc.MAX_DAYS - myc.MIN_DAYS)))
T.eq("a barn that did not designate the field is untouched", m.barns.b2.mycotoxinPenalty, nil)

-- Every barn that designated the same field gets the penalty.
local m2 = newManager({
  a = { barnId = "a", feedSourceFields = { [7] = true } },
  b = { barnId = "b", feedSourceFields = { [7] = true } },
  c = { barnId = "c", feedSourceFields = {} },
})
m2:_applyHarvestContamination({ fieldId = 7, diseasePressure = 100 })
T.eq("both designating barns get the penalty", m2.barns.a.mycotoxinPenalty, myc.MAX_PENALTY)
T.eq("both designating barns get the penalty (second)", m2.barns.b.mycotoxinPenalty, myc.MAX_PENALTY)
T.eq("the non-designating barn stays clean", m2.barns.c.mycotoxinPenalty, nil)

-- A clean cut is not contamination: MIN_PENALTY must NOT be applied.
local m3 = newManager({ a = { barnId = "a", feedSourceFields = { [9] = true } } })
m3:_applyHarvestContamination({ fieldId = 9, diseasePressure = 0 })
T.eq("a clean cut imposes no penalty", m3.barns.a.mycotoxinPenalty, nil)
T.eq("a clean cut imposes no countdown", m3.barns.a.mycotoxinDaysLeft, nil)

-- Bad payloads are ignored, never error.
local m4 = newManager({ a = { barnId = "a", feedSourceFields = { [1] = true } } })
m4:_applyHarvestContamination(nil)
m4:_applyHarvestContamination({})
m4:_applyHarvestContamination({ fieldId = 1 })
T.eq("nil payload is ignored", m4.barns.a.mycotoxinPenalty, nil)
T.eq("missing severity is ignored", m4.barns.a.mycotoxinPenalty, nil)
T.ok("bad payloads did not error", true)

T.summary()
