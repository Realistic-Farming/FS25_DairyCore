-- dc11_feed_business_layer_test.lua - DC-11 4A placement + F106.
--
-- Pins the mode-independent farm-business modifier layer (brief fold 2026-08-05,
-- addendum 2026-08-14): the feed-field bonuses and penalties plus the mycotoxin
-- subtraction apply AFTER either score path resolves, so a Ritter-mode farm is
-- not silently exempt. Before the fix they sat inside _herdScoreStandard, which
-- Ritter-mode saves skip entirely (the Ritter bypass at DairyCoreManager.lua:374-378).
-- Also pins F106: undesignateFeedField marks the barns dirty, symmetric with
-- designateFeedField, so a co-op partner sees the undesignation immediately.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local HERD = DairyConstants.HERD

-- A good feed field: balanced NPK, high OM, no weeds, legume rotation.
local GOOD = {
  organicMatter = 8,
  nitrogen = { status = "Good" }, phosphorus = { status = "Good" }, potassium = { status = "Good" },
  weedPressure = 10,
  rotationStatus = "legume",
}

-- A poor feed field: severe OM depletion, unbalanced NPK, weeds, no legume.
local POOR = {
  organicMatter = 1.5,
  nitrogen = { status = "Low" }, phosphorus = { status = "Low" }, potassium = { status = "Low" },
  weedPressure = 80,
  rotationStatus = "maize",
}

local function newManager(barns, fieldInfo)
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  m.barns = barns or {}
  if fieldInfo ~= nil then
    m._getFieldInfo = function(_, fieldId) return fieldInfo[fieldId] end
  end
  return m
end

local function barnWith(overrides)
  local b = { barnId = "b1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
  for k, v in pairs(overrides or {}) do b[k] = v end
  return b
end

-- ══════════════════════════════════════════════════════════
-- STANDARD PATH: base globalProductionFactor + the feed layer
-- ══════════════════════════════════════════════════════════

RLBridge.active = false

local stdGood = newManager({ b1 = barnWith({ _placeable = { getGlobalProductionFactor = function() return 0.8 end }, feedSourceFields = { [5] = true } }) },
  { [5] = GOOD })
stdGood:_updateBarnHealth(stdGood.barns.b1)
T.eq("standard: balanced NPK + legume bonus apply over the base",
  stdGood.barns.b1.herdHealthScore,
  80 + HERD.BALANCED_NPK_BONUS + HERD.LEGUME_QUALITY_FLOOR_BONUS)

local stdPoor = newManager({ b1 = barnWith({ _placeable = { getGlobalProductionFactor = function() return 0.8 end }, feedSourceFields = { [5] = true } }) },
  { [5] = POOR })
stdPoor:_updateBarnHealth(stdPoor.barns.b1)
T.eq("standard: severe OM + weed penalties apply over the base",
  stdPoor.barns.b1.herdHealthScore,
  80 - HERD.OM_SEVERE_PEN - HERD.WEED_QUALITY_PEN)

local stdNoFields = newManager({ b1 = barnWith({ _placeable = { getGlobalProductionFactor = function() return 0.8 end } }) })
stdNoFields:_updateBarnHealth(stdNoFields.barns.b1)
T.eq("standard: no designated fields means no feed deltas",
  stdNoFields.barns.b1.herdHealthScore, 80)

-- ══════════════════════════════════════════════════════════
-- RITTER PATH: the feed layer applies on top of the RL score
-- ══════════════════════════════════════════════════════════

local origActive = RLBridge.active
local origScore, origGenetics = RLBridge.computeHerdScore, RLBridge.computeGeneticsContribution
RLBridge.active = true
RLBridge.computeHerdScore = function() return 70 end
RLBridge.computeGeneticsContribution = function() return nil end

local ritGood = newManager({ b1 = barnWith({ feedSourceFields = { [5] = true } }) }, { [5] = GOOD })
ritGood:_updateBarnHealth(ritGood.barns.b1)
T.eq("ritter: feed bonuses apply on top of the RL score (not silently exempt)",
  ritGood.barns.b1.herdHealthScore,
  70 + HERD.BALANCED_NPK_BONUS + HERD.LEGUME_QUALITY_FLOOR_BONUS)

local ritPoor = newManager({ b1 = barnWith({ feedSourceFields = { [5] = true } }) }, { [5] = POOR })
ritPoor:_updateBarnHealth(ritPoor.barns.b1)
T.eq("ritter: feed penalties apply on top of the RL score",
  ritPoor.barns.b1.herdHealthScore,
  70 - HERD.OM_SEVERE_PEN - HERD.WEED_QUALITY_PEN)

RLBridge.active = origActive
RLBridge.computeHerdScore = origScore
RLBridge.computeGeneticsContribution = origGenetics

-- ══════════════════════════════════════════════════════════
-- MYCOTOXIN PENALTY APPLIES IN BOTH MODES
-- ══════════════════════════════════════════════════════════

RLBridge.active = false
local stdMyc = newManager({ b1 = barnWith({ _placeable = { getGlobalProductionFactor = function() return 0.8 end }, feedSourceFields = { [5] = true }, mycotoxinPenalty = 10 }) },
  { [5] = GOOD })
stdMyc:_updateBarnHealth(stdMyc.barns.b1)
T.eq("standard: mycotoxin penalty is subtracted", stdMyc.barns.b1.herdHealthScore, 80 - 10 + HERD.BALANCED_NPK_BONUS + HERD.LEGUME_QUALITY_FLOOR_BONUS)

RLBridge.active = true
RLBridge.computeHerdScore = function() return 70 end
RLBridge.computeGeneticsContribution = function() return nil end
local ritMyc = newManager({ b1 = barnWith({ feedSourceFields = { [5] = true }, mycotoxinPenalty = 10 }) }, { [5] = GOOD })
ritMyc:_updateBarnHealth(ritMyc.barns.b1)
T.eq("ritter: mycotoxin penalty is subtracted too", ritMyc.barns.b1.herdHealthScore, 70 - 10 + HERD.BALANCED_NPK_BONUS + HERD.LEGUME_QUALITY_FLOOR_BONUS)
RLBridge.active = origActive
RLBridge.computeHerdScore = origScore
RLBridge.computeGeneticsContribution = origGenetics

-- ══════════════════════════════════════════════════════════
-- F106: undesignateFeedField marks the barns dirty
-- ══════════════════════════════════════════════════════════

local dirtyCalls = 0
local f106 = newManager({ b1 = barnWith({ feedSourceFields = { [5] = true } }) })
f106._markBarnsDirty = function() dirtyCalls = dirtyCalls + 1 end
f106:designateFeedField("b1", 6)
f106:undesignateFeedField("b1", 5)
T.eq("F106: designate and undesignate both mark the barns dirty", dirtyCalls, 2)
T.eq("F106: the field is removed from the set", f106.barns.b1.feedSourceFields[5], nil)
T.eq("F106: a missing barn returns false", f106:undesignateFeedField("nope", 1), false)

T.summary()
