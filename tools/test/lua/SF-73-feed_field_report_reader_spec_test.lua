-- SF-73-feed_field_report_reader_spec_test.lua
--
-- SF-73 Implementation v1.1 section 6, the DairyCore reader: a designated feed field
-- is balanced when Soil's crop-relative FIELD_REPORT (getCropNutrientRelationship(
-- fieldId), no coordinates) is complete and all three nutrients sit IDEAL or ABOVE;
-- without a complete record the whole legacy all-three-Good test decides. OM, weeds,
-- rotation and every other herd rule are unchanged.
--
-- ENTRY-POINT BAR: every row runs the production herd update, DairyCoreManager:
-- _updateBarnHealth, on a real manager with the REAL _getFieldInfo and the new real
-- _getFieldRelationships reaching through g_currentMission.soilFertilityManager. Soil
-- itself is the only stand-in, answering through its two published read contracts.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

local HERD = DairyConstants.HERD
RLBridge.active = false

local function nutrient(kind) return { relationship = kind, knowledgeState = "KNOWN", value = 40 } end
local function report(n, p, k, scope)
  return { schema = 1, scope = scope or "FIELD_REPORT", quality = "ANALYSIS",
           nutrients = { N = nutrient(n), P = nutrient(p), K = nutrient(k) } }
end
local function info(status)
  return { organicMatter = 8, weedPressure = 10, rotationStatus = "maize",
           nitrogen = { status = status }, phosphorus = { status = status }, potassium = { status = status } }
end

--- The production herd update for one barn with one designated feed field; returns
--- the herd score. `rel` false means Soil has no relationship getter (an older Soil).
local function score(fieldInfo, rel)
  local soil = { getFieldInfo = function(_, fieldId) return fieldInfo end }
  if rel ~= false then
    soil.getCropNutrientRelationship = function(_, fieldId, x, z)
      if x ~= nil or z ~= nil then return nil end   -- the herd must read the FIELD report
      return rel
    end
  end
  g_currentMission = { soilFertilityManager = { soilSystem = soil } }
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  local barn = { barnId = "b1", farmId = 1, feedSourceFields = { [5] = true }, mycotoxinPenalty = 0,
                 _placeable = { getGlobalProductionFactor = function() return 0.8 end } }
  m.barns = { b1 = barn }
  m:_updateBarnHealth(barn)
  g_currentMission = nil
  return barn.herdHealthScore
end

local base = 80
T.eq("B1 all three IDEAL on a complete FIELD_REPORT is balanced",
     score(info("Poor"), report("IDEAL", "IDEAL", "IDEAL")), base + HERD.BALANCED_NPK_BONUS)
T.eq("B2 ABOVE counts as balanced", score(info("Poor"), report("ABOVE", "IDEAL", "ABOVE")), base + HERD.BALANCED_NPK_BONUS)
T.eq("B3 one APPROACHING nutrient is not balanced, even where legacy says Good",
     score(info("Good"), report("IDEAL", "APPROACHING", "IDEAL")), base)
T.eq("B4 one BELOW is not balanced", score(info("Good"), report("BELOW", "IDEAL", "IDEAL")), base)
T.eq("B5 an UNDETERMINED nutrient takes the whole legacy test (Good -> balanced)",
     score(info("Good"), report("UNDETERMINED", "IDEAL", "IDEAL")), base + HERD.BALANCED_NPK_BONUS)
T.eq("B6 an UNDETERMINED nutrient takes the whole legacy test (Poor -> not)",
     score(info("Poor"), report("IDEAL", "UNDETERMINED", "IDEAL")), base)
T.eq("B7 a vehicle FOOTPRINT never decides the herd (legacy Poor stands)",
     score(info("Poor"), report("IDEAL", "IDEAL", "IDEAL", "FOOTPRINT")), base)
T.eq("B8 an older Soil without the getter keeps the legacy result",
     score(info("Good"), false), base + HERD.BALANCED_NPK_BONUS)
T.eq("B9 a getter answering nil keeps the legacy result", score(info("Poor"), nil), base)

-- the other herd rules are untouched by the new balance source
do
  local low = info("Poor")
  low.organicMatter = 1.5
  T.eq("B10 severe OM still penalises beside a report-balanced field",
       score(low, report("IDEAL", "IDEAL", "IDEAL")), base + HERD.BALANCED_NPK_BONUS - HERD.OM_SEVERE_PEN)
end

T.summary()
