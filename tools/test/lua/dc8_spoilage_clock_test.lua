-- dc8_spoilage_clock_test.lua - DC-8 MILK SPOILAGE, THE DECAY CLOCK.
--
-- The clock is elapsed time, evaluated once per in-game hour from the FRACTIONAL
-- days since the last collection, never a flag on a missed window. A barn on a
-- precise 24h cadence stays Fresh the whole round; a barn nobody collects ages
-- continuously to Condemned. The tier drop reaches MONEY (F102) because the
-- contract settlement reads the effective tier. The band travels as an l10n KEY.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local MILK = DairyConstants.CONTRACTS.MILK_FILLTYPE
local STAGES = DairyConstants.SPOILAGE.STAGES

-- ── Engine mock ─────────────────────────────────────────────
g_currentMission = {
  _isServer = true,
  missionInfo = { savegameDirectory = "savegame1" },
  environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
  money = {},
}
function g_currentMission:getIsServer() return self._isServer end
function g_currentMission:addMoney(income, farmId, mtype, a, b)
  self.money[#self.money + 1] = { income = income, farmId = farmId, mtype = mtype }
end
MoneyType = { OTHER = 1 }
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
g_server = {}
g_modIsLoaded = {}

local function makePlaceable(cows)
  local placeable = {
    spec_husbandry = { unloadingStation = { fillLevels = {}, listeners = {} } },
    getNumOfAnimals = function() return cows or 0 end,
  }
  return placeable
end

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

local function stageOf(m, barn, nowHours)
  m:_updateSpoilage(barn, nowHours)
  return barn.spoilageStatus, barn._spoilageTierDrop
end

-- ══════════════════════════════════════════════════════════
-- BAR 1: THE FRACTIONAL-DAY READ ADVANCES CONTINUOUSLY
-- The band resolves from FRACTIONAL days, so 0h is Fresh and the jump to Ageing
-- lands at 24h (1.0 days), not at the next midnight. This is the bar that catches
-- the whole-day truncation bug returning.
-- ══════════════════════════════════════════════════════════

local m = newManager()
local barn = m:_getOrCreateBarn("b1", 1, makePlaceable(6))
m:markCollected(barn, 100, 2400, DairyConstants.COLLECTION.SOURCES.self)

-- 0h .. 23h after collection: Fresh, zero drop.
for _, h in ipairs({ 0, 1, 23 }) do
  local s, d = stageOf(m, barn, 2400 + h)
  T.eq("hour +" .. h .. " reads fresh", s, STAGES.fresh.key)
  T.eq("hour +" .. h .. " has zero drop", d, 0)
end

-- At exactly 24h (1.0 days) the band is Ageing, and it stays Ageing through 47h.
local s, d = stageOf(m, barn, 2400 + 24)
T.eq("hour +24 (1.0 days) is ageing", s, STAGES.ageing.key)
T.eq("hour +24 drop is -1 tier", d, STAGES.ageing.tierDrop)
s, d = stageOf(m, barn, 2400 + 47)
T.eq("hour +47 (1.958 days) is ageing", s, STAGES.ageing.key)

-- At 48h (2.0 days) At Risk; at 72h (3.0 days) Condemned; beyond stays Condemned.
s, d = stageOf(m, barn, 2400 + 48)
T.eq("hour +48 (2.0 days) is at risk", s, STAGES.atrisk.key)
T.eq("hour +48 drop is -2 tiers", d, STAGES.atrisk.tierDrop)
s, d = stageOf(m, barn, 2400 + 72)
T.eq("hour +72 (3.0 days) is condemned", s, STAGES.condemned.key)
T.eq("hour +72 drop forces poor", d, STAGES.condemned.tierDrop)
s, d = stageOf(m, barn, 2400 + 73)
T.eq("hour +73 (3.042 days) stays condemned", s, STAGES.condemned.key)

-- The stage resolver matches the < operator convention at the exact thresholds.
T.eq("0.999 days is fresh", m:_spoilageStage(0.999).key, STAGES.fresh.key)
T.eq("1.000 days is ageing", m:_spoilageStage(1.0).key, STAGES.ageing.key)
T.eq("1.999 days is ageing", m:_spoilageStage(1.999).key, STAGES.ageing.key)
T.eq("2.000 days is at risk", m:_spoilageStage(2.0).key, STAGES.atrisk.key)
T.eq("2.999 days is at risk", m:_spoilageStage(2.999).key, STAGES.atrisk.key)
T.eq("3.000 days is condemned", m:_spoilageStage(3.0).key, STAGES.condemned.key)

-- The clock has never started (nil lastCollectionDay): Fresh, zero drop, never
-- "collected today".
local m0 = newManager()
local b0 = m0:_getOrCreateBarn("b0", 1, makePlaceable(4))
local s0, d0 = stageOf(m0, b0, 2400)
T.eq("an unstarted clock reads fresh", s0, STAGES.fresh.key)
T.eq("an unstarted clock has zero drop", d0, 0)

-- ══════════════════════════════════════════════════════════
-- BAR 2: A BARN COLLECTED EXACTLY EVERY 24 HOURS NEVER LEAVES FRESH
-- No hour between collections reads anything but Fresh.
-- ══════════════════════════════════════════════════════════

local m1 = newManager()
local b1 = m1:_getOrCreateBarn("b2", 1, makePlaceable(6))
local now = 2400
for round = 1, 3 do
  m1:markCollected(b1, 100 + round, now, DairyConstants.COLLECTION.SOURCES.rota)
  for hour = 1, 23 do
    local s = stageOf(m1, b1, now + hour)
    T.eq("round " .. round .. " hour +" .. hour .. " stays fresh", s, STAGES.fresh.key)
  end
  now = now + 24
end

-- ══════════════════════════════════════════════════════════
-- BAR 5: markCollected RESETS THE BAND AND DROP FOR EVERY SOURCE
-- Source-blind: all four values plus an unrecognised fifth.
-- ══════════════════════════════════════════════════════════

local sources = {
  DairyConstants.COLLECTION.SOURCES.self,
  DairyConstants.COLLECTION.SOURCES.hauled,
  DairyConstants.COLLECTION.SOURCES.rota,
  DairyConstants.COLLECTION.SOURCES.office,
  "someone_else",
}
local m2 = newManager()
for _, src in ipairs(sources) do
  local b = m2:_getOrCreateBarn("src_" .. tostring(src), 1, makePlaceable(5))
  b.lastCollectionDay = 90
  b.lastCollectionHours = 2160
  b.spoilageStatus = STAGES.condemned.key
  b._spoilageTierDrop = 99
  m2:markCollected(b, 100, 2400, src)
  T.eq("markCollected resets the band for source '" .. tostring(src) .. "'",
    b.spoilageStatus, STAGES.fresh.key)
  T.eq("markCollected resets the drop for source '" .. tostring(src) .. "'",
    b._spoilageTierDrop, 0)
  T.eq("the source is recorded for '" .. tostring(src) .. "'", b.lastCollectionSource, src)
end

-- ══════════════════════════════════════════════════════════
-- BAR 6: THE MISSED-WINDOW MECHANISM IS GONE
-- The one-stage-per-window function and the flag no longer exist anywhere.
-- ══════════════════════════════════════════════════════════

T.eq("_advanceSpoilageOneStage is deleted", m1._advanceSpoilageOneStage, nil)

-- The hour tick no longer sets _missedWindow: an unassigned barn whose window
-- arrives just ages on the elapsed-time clock, and no flag appears.
local m3 = newManager()
local b3 = m3:_getOrCreateBarn("b3", 1, makePlaceable(5))
b3.lastCollectionHours = 2100
b3.lastCollectionDay = 87
b3.nextCollectionDue = 1   -- window already arrived, no worker assigned
m3:onCollectionHourTick({ monotonicDay = 100 })
T.eq("a missed window leaves no _missedWindow flag", b3._missedWindow, nil)
T.eq("the band advanced on elapsed time, not on a flag",
  b3.spoilageStatus ~= STAGES.fresh.key, true)

-- ══════════════════════════════════════════════════════════
-- BAR 7: _spoilageTierDrop ROUND TRIPS BOTH SAVE PATHS
-- A barn's effective tier and spoilage status must not disagree after a reload.
-- ══════════════════════════════════════════════════════════

-- StateLedger path.
local m4 = newManager()
local b4 = m4:_getOrCreateBarn("b4", 1, makePlaceable(5))
b4.lastCollectionDay = 80
b4.lastCollectionHours = 1920
b4._spoilageTierDrop = 2
b4.spoilageStatus = STAGES.atrisk.key
local ser = m4:_serializeBarns()
local m5 = newManager()
m5:_deserializeBarns(ser)
T.eq("ledger: the tier drop survives", m5.barns["b4"]._spoilageTierDrop, 2)
T.eq("ledger: the band key survives", m5.barns["b4"].spoilageStatus, STAGES.atrisk.key)

-- Own-file path.
local DISK = {}
local XF = {}
XF.__index = XF
XMLFile = {}
function XMLFile.create(_, path, _) return setmetatable({ path = path, data = {} }, XF) end
function XMLFile.loadIfExists(_, path, _)
  if DISK[path] == nil then return nil end
  local copy = {}
  for k, v in pairs(DISK[path]) do copy[k] = v end
  return setmetatable({ path = path, data = copy }, XF)
end
function XF:setString(k, v) self.data[k] = tostring(v) end
function XF:setInt(k, v) self.data[k] = math.floor(v) end
function XF:setFloat(k, v) self.data[k] = v + 0.0 end
function XF:getString(k, d) local v = self.data[k]; if v == nil then return d end return tostring(v) end
function XF:getInt(k, d) local v = self.data[k]; if v == nil then return d end return math.floor(tonumber(v)) end
function XF:getFloat(k, d) local v = self.data[k]; if v == nil then return d end return tonumber(v) end
function XF:save() local snap = {} for k, v in pairs(self.data) do snap[k] = v end DISK[self.path] = snap end
function XF:delete() end
function XF:iterate(base, fn)
  local i = 0
  while true do
    local prefix = string.format("%s(%d)#", base, i)
    local found = false
    for k in pairs(self.data) do if k:sub(1, #prefix) == prefix then found = true break end end
    if not found then break end
    fn(i + 1, string.format("%s(%d)", base, i))
    i = i + 1
  end
end

g_currentMission.missionInfo.savegameDirectory = "savegame_dc8"
local m6 = newManager()
local b6 = m6:_getOrCreateBarn("b6", 1, makePlaceable(5))
b6.lastCollectionDay = 80
b6.lastCollectionHours = 1920
b6._spoilageTierDrop = 1
b6.spoilageStatus = STAGES.ageing.key
m6:_saveOwnFile()
local m7 = newManager()
m7:_loadOwnFile()
T.eq("own-file: the tier drop survives", m7.barns["b6"]._spoilageTierDrop, 1)
T.eq("own-file: the band key survives", m7.barns["b6"].spoilageStatus, STAGES.ageing.key)

-- ══════════════════════════════════════════════════════════
-- MIGRATION: OLD-SAVE ENGLISH BAND NAMES NORMALISE TO KEYS
-- ══════════════════════════════════════════════════════════

local m8 = newManager()
local b8 = m8:_getOrCreateBarn("b8", 1, makePlaceable(5))
b8.spoilageStatus = "At Risk"   -- what a pre-DC-8 save carries
local ser2 = m8:_serializeBarns()
local m9 = newManager()
m9:_deserializeBarns(ser2)
T.eq("an old English band name is migrated to its key", m9.barns["b8"].spoilageStatus, STAGES.atrisk.key)
T.eq("an unrecognised band degrades to fresh", m9:_normalizeSpoilageKey("Banana"), STAGES.fresh.key)

-- ══════════════════════════════════════════════════════════
-- BAR (F102): SPOILAGE REACHES MONEY - THE SETTLEMENT READS THE EFFECTIVE TIER
-- A barn with a healthy herd but Condemned milk must accrue at the POOR rate, not
-- the Premium rate the earned tier would give. This is DC-10's written acceptance,
-- carried by DC-8 so waking the clock actually changes income.
-- ══════════════════════════════════════════════════════════

local m10 = newManager()
local b10 = m10:_getOrCreateBarn("b10", 1, makePlaceable(10))
b10.herdHealthScore = 90      -- earned tier Premium (>= 85)
b10.milkQualityTier = "premium"
b10._spoilageTierDrop = 99    -- Condemned -> effective Poor
b10.activeContractId = 1
m10.contracts[1] = {
  contractId = 1, barnId = "b10", farmId = 1, type = "standard",
  volumeTarget = 8000, termDays = 30, daysRemaining = 5, premiumRate = 1.0,
  qualityRequired = nil, delivered = 0, settled = false, organicSum = 0, organicDays = 0,
}
local earnedMod = DairyConstants.QUALITY.TIERS[1].priceMod     -- Premium 1.20
local poorMod   = DairyConstants.QUALITY.TIERS[4].priceMod     -- Poor 0.70
m10:_settleContractDay(1, { boundariesCrossed = 1 })
T.eq("the earned tier is premium", earnedMod, 1.20)
T.eq("the contract accrues at the effective (poor) rate",
  math.floor(m10.contracts[1].delivered), math.floor(10 * 22 * poorMod))
T.ok("and NOT at the earned (premium) rate",
  m10.contracts[1].delivered < 10 * 22 * earnedMod)

-- And a fresh barn (zero drop) still accrues at its earned tier.
local m11 = newManager()
local b11 = m11:_getOrCreateBarn("b11", 1, makePlaceable(10))
b11.herdHealthScore = 90
b11.milkQualityTier = "premium"
b11._spoilageTierDrop = 0
b11.activeContractId = 2
m11.contracts[2] = {
  contractId = 2, barnId = "b11", farmId = 1, type = "standard",
  volumeTarget = 8000, termDays = 30, daysRemaining = 5, premiumRate = 1.0,
  qualityRequired = nil, delivered = 0, settled = false, organicSum = 0, organicDays = 0,
}
m11:_settleContractDay(2, { boundariesCrossed = 1 })
T.eq("a fresh barn accrues at its earned tier",
  math.floor(m11.contracts[2].delivered), math.floor(10 * 22 * earnedMod))

T.summary()
