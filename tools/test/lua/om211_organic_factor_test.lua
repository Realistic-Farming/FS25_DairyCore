-- om211_organic_factor_test.lua - OM-211, the organic milk premium at settlement.
-- Verifies _barnOrganicFraction (the mapping table + nil rules), the per-accrual-day
-- accumulation in _settleContractDay, the pay-line factor (never below 1.0, scaled by
-- the mean organic credit, neutral 1.0 ship value), and the save round-trip.
--!load: src/Logger.lua, src/DairyConstants.lua, src/DairyCoreManager.lua

local PREMIUM_MAX = DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX

-- ── SF organic authority stub ───────────────────────────────
-- getFieldOrganicState returns { state, daysAccrued, transitionDaysNeeded, certified, breaches }.
local function sfWith(states)
  g_SoilFertilityManager = {
    organic = {
      getFieldOrganicState = function(_self, fieldId)
        return states[fieldId]
      end,
    },
  }
end

local function sfAbsent() g_SoilFertilityManager = nil end

-- ── manager + barn helpers ─────────────────────────────────
local function newManager()
  return DairyCoreManager.new()
end

local function barnWithFields(fields)
  return { barnId = "barn_A", farmId = 1, herdHealthScore = 60, milkQualityTier = "standard",
           feedSourceFields = fields }
end

-- ══════════════════════════════════════════════════════════
-- _barnOrganicFraction: the mapping table + nil rules
-- ══════════════════════════════════════════════════════════
do
  sfWith({
    [5] = { state = "certified", daysAccrued = 0, transitionDaysNeeded = 120, certified = true },
    [6] = { state = "in_transition", daysAccrued = 60, transitionDaysNeeded = 120, certified = false },
    [7] = { state = "conventional", daysAccrued = 0, transitionDaysNeeded = 120, certified = false },
  })
  local m = newManager()
  local b = barnWithFields({ [5] = true, [6] = true, [7] = true })
  local f = m:_barnOrganicFraction(b)
  -- certified -> 1.0, half-way transition -> 0.5, conventional -> 0  => mean 0.5
  T.near("om211: certified is 1.0, half transition is 0.5, conventional is 0", f, 0.5, 1e-6)
end

do
  sfWith({ [5] = { certified = true } })
  local m = newManager()
  T.near("om211: all certified fields mean 1.0", m:_barnOrganicFraction(barnWithFields({ [5] = true })), 1.0, 1e-6)
end

-- Transition credit is clamped to 0..1 even when accrued exceeds the window.
do
  sfWith({ [8] = { state = "in_transition", daysAccrued = 500, transitionDaysNeeded = 120, certified = false } })
  local m = newManager()
  T.near("om211: over-accrued transition credit clamps at 1.0", m:_barnOrganicFraction(barnWithFields({ [8] = true })), 1.0, 1e-6)
end

-- SF absent: 0, factor stays 1.0, no crash.
do
  sfAbsent()
  local m = newManager()
  T.eq("om211: absent SF means fraction 0", m:_barnOrganicFraction(barnWithFields({ [5] = true })), 0)
end

-- No designations: 0.
do
  sfWith({})
  local m = newManager()
  T.eq("om211: no designated fields means fraction 0", m:_barnOrganicFraction(barnWithFields({})), 0)
end

-- Unreadable field (getFieldOrganicState throws): skipped, not fatal.
do
  g_SoilFertilityManager = {
    organic = {
      getFieldOrganicState = function() error("boom") end,
    },
  }
  local m = newManager()
  T.eq("om211: an unreadable field is skipped (fraction 0, no crash)",
       m:_barnOrganicFraction(barnWithFields({ [5] = true })), 0)
end

-- ══════════════════════════════════════════════════════════
-- Settlement accumulation: organicSum / organicDays per accrual day
-- ══════════════════════════════════════════════════════════
-- A barn fully organic every day accumulates a clean 1.0 mean.
do
  sfWith({ [5] = { certified = true } })
  local m = newManager()
  m.barns["barn_A"] = barnWithFields({ [5] = true })
  local c = { contractId = 1, barnId = "barn_A", settled = false, delivered = 0, daysRemaining = 3,
              volumeTarget = 100000, farmId = 1, premiumRate = 1.0 }
  m.contracts[1] = c
  local sctx = { boundariesCrossed = 3 }
  m:_settleContractDay(1, sctx)
  T.eq("om211: one organic day per accrual day accumulates", c.organicDays, 3)
  T.near("om211: a fully-organic barn accumulates sum == days", c.organicSum, 3.0, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- Pay line: never below 1.0, scaled by the mean credit
-- ══════════════════════════════════════════════════════════
-- To isolate the factor, stub the price + income plumbing and capture addMoney.
MoneyType = { OTHER = 0 }
local capturedIncome = nil
g_currentMission.addMoney = function(_m, income, _farm, _type, _s, _s2) capturedIncome = income end

local function payManager(c, spot)
  local m = newManager()
  m.contracts[1] = c
  g_fillTypeManager = { getFillTypeIndexByName = function() return 1 end,
                        getFillTypeByIndex = function() return { pricePerLiter = spot } end }
  g_currentMission.MarketDynamics = { marketEngine = { getPrice = function() return spot end } }
  g_currentMission.randomWorldEvents = nil
  return m
end

-- Old save: organicDays nil -> guard treats as zero organic days -> factor stays 1.0.
do
  g_currentMission._isServer = true
  local c = { contractId = 1, farmId = 1, premiumRate = 1.0, delivered = 1000, volumeTarget = 1000 }
  local m = payManager(c, 2.0)
  m:_payContract(c)
  T.near("om211: an old save with nil organic fields pays the base premium", capturedIncome, 2000, 0.001)
end

-- Fully-organic mean with the neutral 1.0 ship value: factor is still 1.0 (merge is inert).
do
  g_currentMission._isServer = true
  local c = { contractId = 1, farmId = 1, premiumRate = 1.0, delivered = 1000, volumeTarget = 1000,
              organicSum = 3.0, organicDays = 3 }
  local m = payManager(c, 2.0)
  m:_payContract(c)
  T.near("om211: neutral 1.0 ship value adds no premium (merge is inert)", capturedIncome, 2000, 0.001)
end

-- With a non-neutral max, the factor scales by the mean organic credit and never
-- goes below 1.0. Bypass the constant read so this test does not depend on the
-- unlock pass: simulate by patching the constant in place for the assertion.
do
  g_currentMission._isServer = true
  local saved = DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX
  DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX = 1.30
  local c = { contractId = 1, farmId = 1, premiumRate = 1.0, delivered = 1000, volumeTarget = 1000,
              organicSum = 1.5, organicDays = 3 }   -- mean 0.5 -> factor 1 + 0.5*0.30 = 1.15
  local m = payManager(c, 2.0)
  m:_payContract(c)
  T.near("om211: a 0.5 mean scales the premium to the midpoint", capturedIncome, 2300, 0.001)
  DairyConstants.CONTRACTS.ORGANIC_MILK_PREMIUM_MAX = saved
end

-- ══════════════════════════════════════════════════════════
-- Save round-trip: organicSum / organicDays survive the own-file path
-- ══════════════════════════════════════════════════════════
-- In-memory XMLFile, faithful to the subset the own-file path uses (mirrored
-- from dc13_persistence_sync_test.lua so the two tests stay independent).
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
function XF:setInt(k, v)    self.data[k] = math.floor(v) end
function XF:setFloat(k, v)  self.data[k] = v + 0.0 end
function XF:getString(k, d) local v = self.data[k]; if v == nil then return d end return tostring(v) end
function XF:getInt(k, d)    local v = self.data[k]; if v == nil then return d end return math.floor(tonumber(v)) end
function XF:getFloat(k, d)  local v = self.data[k]; if v == nil then return d end return tonumber(v) end
function XF:save()
  local snap = {}
  for k, v in pairs(self.data) do snap[k] = v end
  DISK[self.path] = snap
end
function XF:delete() end
function XF:iterate(base, fn)
  local i = 0
  while true do
    local prefix = string.format("%s(%d)#", base, i)
    local found = false
    for k in pairs(self.data) do
      if k:sub(1, #prefix) == prefix then found = true break end
    end
    if not found then break end
    fn(i + 1, string.format("%s(%d)", base, i))
    i = i + 1
  end
end

do
  g_currentMission._isServer = true
  g_currentMission.timeGuard = { registerAccrual = function() end, subscribeTick = function() end }
  local before = newManager()
  before.contracts[1] = { contractId = 1, barnId = "barn_A", farmId = 1, type = "standard",
    volumeTarget = 8000, termDays = 30, daysRemaining = 20, premiumRate = 1.12,
    qualityRequired = nil, delivered = 5000, settled = false,
    organicSum = 12.5, organicDays = 20 }
  before:_saveOwnFile()

  local after = newManager()
  after:_loadOwnFile()
  local c = after.contracts[1]
  T.ok("om211: the organic accumulators survive the save", c ~= nil)
  T.near("om211: organicSum survives", c.organicSum or 0, 12.5, 0.01)
  T.eq("om211: organicDays survives", c.organicDays or 0, 20)
end
