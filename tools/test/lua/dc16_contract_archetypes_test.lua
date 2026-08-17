-- dc16_contract_archetypes_test.lua - DC-16 CONTRACT ARCHETYPES AND THE SOVEREIGN FLOOR.
--
-- The settlement floor anchors to MarketDynamics' crash-proof BASE price snapshot
-- (entry.base), read as a pull at pay time, never the live spot. A market crash
-- can drag the live spot down but not entry.base, so the floor holds exactly when
-- it is needed (the deleted block floored the spot it divided by). Settlement
-- makes no ProStaff read (neutral until the family barn.farmId plumbing lands).
-- Two new contract archetypes, spot_run and standing_order, are pure data rows
-- gated by prostaffLevel like the shipped standard row.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local FF = DairyConstants.CONTRACTS.TYPES.sovereign_floor.floorFraction

-- Engine mock. The market carries a price entry with a crash-proof base and a
-- live current price, so _milkSpotPrice (getPrice) and _milkBasePrice
-- (prices[1].base) read two different numbers, the way MarketEngine.lua stores
-- them. The bench bars the floor against a MOCKED entry.base, not a mocked
-- getPrice spot read.
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

local MD_ENTRY = { base = 5.0, current = 2.0 }
g_currentMission.MarketDynamics = {
  marketEngine = {
    prices = { [1] = MD_ENTRY },
    getPrice = function() return MD_ENTRY.current end,
  },
}
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
g_server = {}
g_modIsLoaded = {}

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

local function contract(over)
  local c = {
    contractId = 1, barnId = "b1", farmId = 1, type = "standard",
    volumeTarget = 8000, termDays = 30, daysRemaining = 1, premiumRate = 1.0,
    qualityRequired = nil, delivered = 1000, settled = false,
    organicSum = 0, organicDays = 0,
  }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function pay(m, c)
  g_currentMission.money = {}
  m:_payContract(c)
  return g_currentMission.money[1]
end

-- ══════════════════════════════════════════════════════════
-- BAR 2: THE FLOOR IS max(contractPrice, entry.base * floorFraction)
-- And the floor actually BINDS below the contract's own price.
-- ══════════════════════════════════════════════════════════

local m = newManager()
MD_ENTRY.base = 5.0
MD_ENTRY.current = 2.0   -- live spot below the floor; the contract should bind it up
local floor = MD_ENTRY.base * FF
local paid = pay(m, contract({ delivered = 1000, premiumRate = 1.0 }))
local expected = math.floor(1000 * math.max(2.0 * 1.0, floor))
T.eq("the floor is max(contractPrice, entry.base * floorFraction)", paid.income, expected)
T.eq("the floor actually binds", expected, math.floor(1000 * floor))

-- ══════════════════════════════════════════════════════════
-- BAR 2 (CRASH): THE FLOOR RIDES entry.base, NOT THE LIVE SPOT
-- Crash the live spot to a tenth of what it was; the paid income must not move,
-- because the floor anchor is the base snapshot, not the crashed spot.
-- ══════════════════════════════════════════════════════════

MD_ENTRY.current = 0.5   -- the crash: live milk price collapses
local paidCrashed = pay(m, contract({ delivered = 1000, premiumRate = 1.0 }))
T.eq("a crashed live spot does not move the floor", paidCrashed.income, paid.income)
T.eq("the crashed floor is still entry.base * floorFraction",
  paidCrashed.income, math.floor(1000 * floor))

-- The anchor is base, not spot: prove the old behavior would have paid less.
T.ok("the crash paid the base-anchored floor, not a spot-anchored one",
  paidCrashed.income > math.floor(1000 * 0.5 * 1.0))

-- ══════════════════════════════════════════════════════════
-- BAR 2 (ABOVE THE FLOOR): THE CONTRACT'S OWN RATE WINS
-- The floor is a floor, not a cap: when the live price clears it, max() keeps
-- the contract's own premium arithmetic.
-- ══════════════════════════════════════════════════════════

MD_ENTRY.current = 6.0
local paidHigh = pay(m, contract({ delivered = 1000, premiumRate = 1.0 }))
T.eq("above the floor, the contract rate wins", paidHigh.income, math.floor(1000 * 6.0 * 1.0))

-- ══════════════════════════════════════════════════════════
-- BAR 3: NO PROSTAFF READ IN THE SETTLEMENT FLOOR
-- The floor's inputs are contractPrice and entry.base only. Spy on
-- _proStaffLevel: settlement must not call it at any arity.
-- ══════════════════════════════════════════════════════════

local prostaffCalls = 0
local m2 = newManager()
m2._proStaffLevel = function() prostaffCalls = prostaffCalls + 1 return 20 end
MD_ENTRY.current = 2.0
pay(m2, contract({ delivered = 100 }))
T.eq("settlement makes no ProStaff read", prostaffCalls, 0)

-- ══════════════════════════════════════════════════════════
-- BAR 5: THE SPOT-DIVIDED-BY-SPOT BLOCK IS GONE
-- The old floor divided floor / spot and scaled premium; the new block composes
-- max(contractPrice, entry.base * floorFraction). A spot at a tenth of base must
-- still floor at the full base-anchored value (covered above). Confirm the old
-- local it used to read (spot-scaled premium) no longer shapes income: with a
-- crashed spot the income is INDEPENDENT of spot entirely.
-- ══════════════════════════════════════════════════════════

MD_ENTRY.current = 0.1
local paidNearZero = pay(m, contract({ delivered = 1000, premiumRate = 1.0 }))
T.eq("income is independent of the spot while it sits under the floor",
  paidNearZero.income, paid.income)

-- ══════════════════════════════════════════════════════════
-- BAR 4: THE DATA ROWS ARE GATED LIKE THE SHIPPED STANDARD ROW
-- spot_run and standing_order carry prostaffLevel gates (SDS-unpinned; defaulted
-- here to the ladder base 0, same as standard), and getAvailableContractTypes
-- applies the gate the same way it does for the shipped rows.
-- ══════════════════════════════════════════════════════════

T.eq("spot_run is a 14-day contract", DairyConstants.CONTRACTS.TYPES.spot_run.termDays, 14)
T.eq("spot_run pays 1.15x the spot rate", DairyConstants.CONTRACTS.TYPES.spot_run.premiumRate, 1.15)
T.eq("standing_order is a 60-day contract", DairyConstants.CONTRACTS.TYPES.standing_order.termDays, 60)
T.eq("standing_order pays 0.92x the term rate", DairyConstants.CONTRACTS.TYPES.standing_order.premiumRate, 0.92)
T.eq("spot_run is gated like the shipped standard row",
  DairyConstants.CONTRACTS.TYPES.spot_run.prostaffLevel,
  DairyConstants.CONTRACTS.TYPES.standard.prostaffLevel)
T.eq("standing_order is gated like the shipped standard row",
  DairyConstants.CONTRACTS.TYPES.standing_order.prostaffLevel,
  DairyConstants.CONTRACTS.TYPES.standard.prostaffLevel)

local function availableAt(level)
  local m3 = newManager()
  m3._proStaffLevel = function() return level end
  local set = {}
  for _, k in ipairs(m3:getAvailableContractTypes()) do set[k] = true end
  return set
end

local at0 = availableAt(0)
T.eq("at level 0: the shipped standard row is available", at0.standard, true)
T.eq("at level 0: spot_run is available at its gate", at0.spot_run, true)
T.eq("at level 0: standing_order is available at its gate", at0.standing_order, true)
T.eq("at level 0: syndicate is below its gate (15)", at0.syndicate, nil)
T.eq("at level 0: sovereign_floor is never a menu row", at0.sovereign_floor, nil)

local at14 = availableAt(14)
T.eq("at level 14: spot_run still available", at14.spot_run, true)
T.eq("at level 14: standing_order still available", at14.standing_order, true)
T.eq("at level 14: syndicate still below its gate", at14.syndicate, nil)

local at15 = availableAt(15)
T.eq("at level 15: syndicate reaches its gate", at15.syndicate, true)
T.eq("at level 15: spot_run still available", at15.spot_run, true)
T.eq("at level 15: standing_order still available", at15.standing_order, true)
T.eq("at level 20: sovereign_floor is still never a menu row", availableAt(20).sovereign_floor, nil)

-- Accepting the new archetypes carries their data into the live contract.
local m4 = newManager()
m4._proStaffLevel = function() return 0 end
local b4 = m4:_getOrCreateBarn("b4", 1, {})
local id = m4:acceptContract("b4", "spot_run")
T.ok("a spot_run contract can be accepted", id ~= nil)
T.eq("the live contract carries the archetype type", m4.contracts[id].type, "spot_run")
T.eq("the live contract carries the archetype premium", m4.contracts[id].premiumRate, 1.15)
T.eq("the live contract carries the 14-day term", m4.contracts[id].termDays, 14)
T.eq("sovereign_floor cannot be accepted as a contract", m4:acceptContract("b4", "sovereign_floor"), nil)

-- ══════════════════════════════════════════════════════════
-- BASE-PRICE READ DEGRADES WHEN MARKETDYNAMICS IS ABSENT
-- _milkBasePrice is a pull with a base-game fallback, same as _milkSpotPrice.
-- ══════════════════════════════════════════════════════════

local savedMD = g_currentMission.MarketDynamics
g_currentMission.MarketDynamics = nil
local m5 = newManager()
T.eq("without MarketDynamics the base price falls back to the base game price",
  m5:_milkBasePrice(), 1.0)
g_currentMission.MarketDynamics = savedMD

T.summary()
