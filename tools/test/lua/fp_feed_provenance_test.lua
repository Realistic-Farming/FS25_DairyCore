-- fp_feed_provenance_test.lua - FP-1 FEED PROVENANCE (authority #5).
--
-- The ONE feed-tracking model: a per-farm per-fill-type fraction vector
-- { contaminated, organic }, blended with one formula at every combine point,
-- decayed daily, persisted, and read where organic feed affects the milk premium.
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

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

-- ==========================================================
-- THE BLEND LAW: f_new = (S * f_old + amount * value) / (S + amount)
-- ==========================================================

local m = newManager()
local fp = m.feedProvenance

-- A clean organic cut into an empty store seeds exactly that value.
fp:blend(1, "WHEAT", 100, 0.0, 1.0)
local p = fp:getFraction(1, "WHEAT")
T.near("a first organic cut seeds organic 1", p.organic, 1.0)
T.near("and contaminated 0", p.contaminated, 0.0)

-- A conventional cut (organic 0, cont 0) dilutes the organic fraction.
fp:blend(1, "WHEAT", 100, 0.0, 0.0)
p = fp:getFraction(1, "WHEAT")
T.near("equal organic + conventional cuts dilute organic to 0.5", p.organic, 0.5, 1e-9)

-- A diseased cut raises contaminated by the blend law.
fp:blend(1, "WHEAT", 100, 0.8, 0.0)
p = fp:getFraction(1, "WHEAT")
-- 200 S at cont 0 + 100 at 0.8 = 80/300 = 0.2667
T.near("a diseased cut blends contaminated by S", p.contaminated, 0.8 * 100 / 300, 1e-9)

-- A different fill type on the same farm is independent. (Wheat organic is 1/3
-- after the diseased cut diluted it: 200 S at 0.5 + 100 at 0.0 over 300.)
fp:blend(1, "BARLEY", 50, 0.0, 1.0)
T.near("barley does not change wheat", fp:getFraction(1, "WHEAT").organic, 1 / 3, 1e-9)
T.near("barley seeds its own organic", fp:getFraction(1, "BARLEY").organic, 1.0)

-- A different farm is independent.
fp:blend(2, "WHEAT", 50, 0.0, 0.0)
T.near("farm 2 does not touch farm 1", fp:getFraction(1, "WHEAT").organic, 1 / 3, 1e-9)

-- An empty or zero amount changes nothing.
local before = fp:getFraction(1, "WHEAT").organic
fp:blend(1, "WHEAT", 0, 0.0, 0.0)
fp:blend(1, "", 100, 0.0, 0.0)
T.eq("a zero amount is ignored", fp:getFraction(1, "WHEAT").organic, before)

-- ==========================================================
-- THE HARVEST CAPTURE (soilHarvestBus payload, server-side)
-- ==========================================================

local m2 = newManager()
local fp2 = m2.feedProvenance

-- Mock the farm, fruit and organic sources the capture reads.
g_farmlandManager = { getFarmlandById = function(_, id) return { farmId = id % 7 } end }
g_fruitTypeManager = { getFruitTypeByIndex = function(_, idx) return { name = "WHEAT" } end }
g_SoilFertilityManager = {
  organic = {
    getFieldOrganicState = function() return { certified = true } end,
  },
}

fp2:onHarvestCut({ fieldId = 10, fruitTypeIndex = 1, liters = 200,
  diseasePressure = 0, activeDisease = nil, activeDiseaseSeverity = 1 })
local g = fp2:getFraction(3, "WHEAT")
T.eq("a certified-organic clean harvest seeds organic 1", g.organic, 1.0)
T.eq("a clean harvest seeds contaminated 0", g.contaminated, 0.0)

-- A diseased grain cut carries the pressure as contamination.
fp2:onHarvestCut({ fieldId = 10, fruitTypeIndex = 1, liters = 200, diseasePressure = 50 })
g = fp2:getFraction(3, "WHEAT")
T.near("a diseased cut blends contaminated from the pressure", g.contaminated, 0.5 * 200 / 400, 1e-9)

-- A client never writes the ledger.
g_currentMission._isServer = false
local m3 = newManager()
local fp3 = m3.feedProvenance
fp3:onHarvestCut({ fieldId = 10, fruitTypeIndex = 1, liters = 200, diseasePressure = 40 })
T.eq("a client does not seed provenance", fp3:hasData(3), false)
g_currentMission._isServer = true

-- An unreserved farm id never books (F75-style guard).
local m4 = newManager()
local fp4 = m4.feedProvenance
fp4:onHarvestCut({ fieldId = 0, fruitTypeIndex = 1, liters = 100, diseasePressure = 0 })
T.eq("an invalid farm never books", fp4:hasData(0), false)

-- ==========================================================
-- DECAY: CONTAMINATED HEALS, ORGANIC DOES NOT
-- ==========================================================

local m5 = newManager()
local fp5 = m5.feedProvenance
fp5:blend(1, "SILAGE", 100, 1.0, 1.0)
fp5:decayContaminated()
local d1 = fp5:getFraction(1, "SILAGE")
T.near("contaminated heals by the daily rate", d1.contaminated, 1.0 * (1 - DairyConstants.FEED_PROVENANCE.CONTAMINATED_DECAY_PER_DAY), 1e-9)
T.near("organic never decays", d1.organic, 1.0)
for _ = 1, 60 do fp5:decayContaminated() end
local d2 = fp5:getFraction(1, "SILAGE")
T.ok("contaminated floors at zero (never-stuck)", d2.contaminated < 1e-3)
T.near("organic is untouched by decay", d2.organic, 1.0)

-- ==========================================================
-- READS: ORGANIC FEED FRACTION + THRESHOLD CLASSIFICATION
-- ==========================================================

local m6 = newManager()
local fp6 = m6.feedProvenance
fp6:blend(1, "WHEAT", 100, 0.0, 1.0)
fp6:blend(1, "BARLEY", 100, 0.0, 1.0)
fp6:blend(1, "OAT", 100, 0.0, 0.0)   -- conventional, half the stock
T.near("the organic feed fraction is amount-weighted", fp6:organicFeedFraction(1), 2 / 3, 1e-9)
T.eq("a farm with no data reads 0", fp6:organicFeedFraction(99), 0)
T.eq("hasData is false for a farm with no data", fp6:hasData(99), false)
T.eq("hasData is true for a seeded farm", fp6:hasData(1), true)
T.ok("2/3 organic above the ratified 0.8 threshold is NOT organic",
  fp6:isOrganicFeed(1, DairyConstants.FEED_PROVENANCE.ORGANIC_THRESHOLD) == false)
fp6:blend(1, "WHEAT", 1000, 0.0, 1.0)   -- swing the weight fully organic
T.ok("an overwhelmingly organic stock classifies organic",
  fp6:isOrganicFeed(1, DairyConstants.FEED_PROVENANCE.ORGANIC_THRESHOLD) == true)

-- ==========================================================
-- PERSISTENCE ROUND TRIP (StateLedger table)
-- ==========================================================

local m7 = newManager()
local fp7 = m7.feedProvenance
fp7:blend(1, "WHEAT", 300, 0.4, 0.7)
fp7:blend(2, "BARLEY", 120, 0.1, 0.2)
local ser = fp7:serialize()
local m8 = newManager()
m8.feedProvenance:deserialize(ser)
local w = m8.feedProvenance:getFraction(1, "WHEAT")
T.near("ledger: contaminated survives", w.contaminated, 0.4, 1e-9)
T.near("ledger: organic survives", w.organic, 0.7, 1e-9)
local b2 = m8.feedProvenance:getFraction(2, "BARLEY")
T.near("ledger: farm 2 survives", b2.organic, 0.2, 1e-9)
T.eq("ledger: an unseeded farm stays absent", m8.feedProvenance:hasData(9), false)

-- ==========================================================
-- THE ORGANIC CONSUMER: _barnOrganicFraction PREFERS THE PROVENANCE
-- ==========================================================

-- When the farm's provenance has data, the contract's organic credit comes from it.
local m9 = newManager()
local b9 = m9:_getOrCreateBarn("b9", 1, {})
b9.farmId = 1
m9.feedProvenance:blend(1, "WHEAT", 100, 0.0, 1.0)
m9.feedProvenance:blend(1, "BARLEY", 100, 0.0, 0.0)
g_SoilFertilityManager = { organic = { getFieldOrganicState = function() return { certified = true } end } }
T.near("the milk premium reads the provenance organic fraction",
  m9:_barnOrganicFraction(b9), 0.5, 1e-9)

-- When the provenance is empty, it falls back to the direct field read.
local m10 = newManager()
local b10 = m10:_getOrCreateBarn("b10", 1, {})
b10.farmId = 7
b10.feedSourceFields = { [3] = true }
T.near("an empty provenance falls back to the direct field read",
  m10:_barnOrganicFraction(b10), 1.0, 1e-9)

T.summary()
