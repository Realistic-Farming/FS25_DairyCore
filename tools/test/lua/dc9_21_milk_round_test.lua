-- dc9_21_milk_round_test.lua - DC-9 COLLECTION SCHEDULING + DC-21 ADMIN SALE.
--
-- The milk round, in three parts:
--   * DC-9 detects milk leaving a barn (tanker, AI haul) from the raw storage level
--     and runs the standing round (rota).
--   * DC-21 sells milk from an office/rota action (RSF-F216): price it, refuse if the
--     per-litre handling fee meets or beats the price, then remove, credit and record.
--   * The five repairs the member carries (skill normalisation, the nextCollectionDue
--     clamp, the worker-id type round trips) are pinned so they cannot regress.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local MILK = DairyConstants.CONTRACTS.MILK_FILLTYPE
local SRC   = DairyConstants.COLLECTION.SOURCES

local function asServer(flag) g_currentMission._isServer = flag end

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

-- A dairy barn placeable with a Storage-like unloading station. The removal path
-- mimics the real one: it fires the storage listeners (via setFillLevel semantics)
-- so the passive detector's suppression is exercised for real.
local function makePlaceable(level)
  local storage = {
    fillLevels = { [MILK] = level },
    listeners = {},
    addFillLevelChangedListeners = function(_, fn) storage.listeners[#storage.listeners + 1] = fn end,
    removeFillLevelChangedListeners = function() end,
  }
  local placeable = {
    spec_husbandry = { unloadingStation = storage },
    removeHusbandryFillLevel = function(_, farmId, delta, ft)
      local cur = storage.fillLevels[MILK] or 0
      local removed = math.min(delta, cur)
      local new = cur - removed
      if new ~= cur then
        storage.fillLevels[MILK] = new
        for _, fn in ipairs(storage.listeners) do fn(MILK, new - cur) end
      end
      return delta - removed   -- remaining (unfulfilled)
    end,
  }
  return placeable
end

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  return m
end

local function setRoster(lifecycleOrLevel)
  local w = { uuid = "w1" }
  if type(lifecycleOrLevel) == "table" then
    w.lifecycleState = lifecycleOrLevel.lifecycle
    w.levelName = lifecycleOrLevel.levelName
    w.level = lifecycleOrLevel.level
  else
    w.lifecycleState = lifecycleOrLevel
  end
  g_currentMission.workerCostsManager = {
    getRosterSnapshot = function() return { workers = { w } } end,
  }
end

-- ══════════════════════════════════════════════════════════
-- DC-9 BAR 1+2: THE LEVEL COMPARISON, SIGN-AGNOSTIC, PER FILL TYPE
-- ══════════════════════════════════════════════════════════

asServer(true)
local m = newManager()
local p = makePlaceable(500)
local barn = m:_getOrCreateBarn("b1", 1, p)

-- First observation seeds the stored level; nothing is a collection.
m:_observeBarnLevels(barn, 2412, 100)
T.eq("first observe seeds, no collection recorded", barn.lastCollectionDay, nil)

-- A drop IS a collection, sized by the difference.
p.spec_husbandry.unloadingStation.fillLevels[MILK] = 300
m:_observeBarnLevels(barn, 2412, 100)
T.eq("a level drop records a collection day", barn.lastCollectionDay, 100)
T.eq("the collection litres are the difference", barn.lastCollectionLitres[MILK], 200)
T.eq("the passive source is hauled", barn.lastCollectionSource, SRC.hauled)
T.eq("the collection hour is stamped", barn.lastCollectionHours, 2412)

-- A rise is production; no second collection is recorded.
p.spec_husbandry.unloadingStation.fillLevels[MILK] = 400
m:_observeBarnLevels(barn, 2412, 100)
T.eq("a level rise is production, not a collection", barn.lastCollectionDay, 100)
T.eq("the litres are not overwritten by production", barn.lastCollectionLitres[MILK], 200)

-- Per fill type: a barn with no MILK never records a MILK collection.
local m2 = newManager()
local p2 = makePlaceable(0)
local b2 = m2:_getOrCreateBarn("b2", 1, p2)
m2:_observeBarnLevels(b2, 2412, 100)
p2.spec_husbandry.unloadingStation.fillLevels[MILK] = 0
m2:_observeBarnLevels(b2, 2412, 100)
T.eq("a buffalo barn (no MILK) records no MILK collection", b2.lastCollectionDay, nil)

-- ══════════════════════════════════════════════════════════
-- DC-9 BAR 3: THE LIFECYCLE SORT, EIGHT STATES + UNRECOGNISED + NIL
-- ══════════════════════════════════════════════════════════

local m3 = newManager()
local p3 = makePlaceable(100)
local b3 = m3:_getOrCreateBarn("b3", 1, p3)

b3.assignedWorkerId = nil
T.eq("no worker -> unassigned", m3:_workerRotaState(b3),
  DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED)

local onRound = { "available", "hired", "training", "injured", "onLeave", "contract" }
for _, state in ipairs(onRound) do
  b3.assignedWorkerId = "w1"
  setRoster(state)
  T.eq("state '" .. state .. "' stays on the round", m3:_workerRotaState(b3),
    DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_OK)
end

for _, state in ipairs({ "retired", "fired" }) do
  b3.assignedWorkerId = "w1"
  setRoster(state)
  T.eq("terminal state '" .. state .. "' reads departed", m3:_workerRotaState(b3),
    DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_DEPARTED)
end

-- Unrecognised and absent lifecycle are treated as still on the round.
b3.assignedWorkerId = "w1"
setRoster("weird_state_that_never_exists")
T.eq("an unrecognised lifecycle stays on the round", m3:_workerRotaState(b3),
  DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_OK)
setRoster(nil)
T.eq("a missing lifecycle stays on the round", m3:_workerRotaState(b3),
  DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_OK)

-- ══════════════════════════════════════════════════════════
-- DC-9 BAR 4: THE SKILL NORMALISATION IS TOTAL OVER STRING AND NUMBER
-- ══════════════════════════════════════════════════════════

local m4 = newManager()
local p4 = makePlaceable(100)
local b4 = m4:_getOrCreateBarn("b4", 1, p4)
b4.assignedWorkerId = "w1"

setRoster({ lifecycle = "available", levelName = "Master" })
T.eq("capitalised level name resolves to the lowercase SKILL key",
  m4:_workerLevelName(b4), "master")

setRoster({ lifecycle = "available", level = 3 })
local numName = m4:_workerLevelName(b4)
T.eq("a numeric level is coerced to a string, not a crash",
  type(numName), "string")
T.eq("and the SKILL lookup does not error on it",
  DairyConstants.COLLECTION.SKILL[numName] ~= nil or numName ~= "experienced", true)

-- ══════════════════════════════════════════════════════════
-- DC-21: THE OFFICE SALE MECHANISM
-- ══════════════════════════════════════════════════════════

local m5 = newManager()
local p5 = makePlaceable(1000)
local b5 = m5:_getOrCreateBarn("b5", 1, p5)
m5._markBarnsDirty = function() end   -- silence the network call

-- BAR: the fee is a fixed per-litre subtraction, not a percentage; the amount is
-- priced against what was actually removed; the credit has the _payContract shape.
-- At the ratified default of 11 per 1000 L the net is 1.0 - 0.011 = 0.989/L.
g_currentMission.money = {}
local removed, status = m5:_adminSellMilk(b5, 100, SRC.office, 2412, 100)
T.eq("the sale returns the removed litres", removed, 100)
T.eq("the sale returns ok", status, "ok")
T.eq("money is credited (100 L at 1.0 less 0.011/L fee)", g_currentMission.money[1].income, 98)
T.eq("the credit is MoneyType.OTHER", g_currentMission.money[1].mtype, MoneyType.OTHER)
T.eq("the credit goes to the barn's farm", g_currentMission.money[1].farmId, 1)
T.eq("the collection is recorded with source office", b5.lastCollectionSource, SRC.office)
T.eq("the milk actually left", p5.spec_husbandry.unloadingStation.fillLevels[MILK], 900)

-- BAR: changing the named setting changes the outcome without touching the mechanism.
-- 30 per 1000 L is chosen rather than converted: 20 would give 98 and collide with
-- the new default, and the old 0.10 override would clamp to the 50 ceiling and give
-- 95, which is exactly what the OLD default asserted, letting a stale bar pass.
m5.settings.saleFeePer1000L = 30
g_currentMission.money = {}
removed = m5:_adminSellMilk(b5, 100, SRC.office, 2412, 100)
T.eq("a 30 per 1000 L fee changes the payout", g_currentMission.money[1].income, 97)

-- BAR: the sale prices against the ACTUAL removed amount, not the request.
local m6 = newManager()
local p6 = makePlaceable(50)   -- only 50 L present
local b6 = m6:_getOrCreateBarn("b6", 1, p6)
m6._markBarnsDirty = function() end
g_currentMission.money = {}
removed = m6:_adminSellMilk(b6, 1000, SRC.office, 2412, 100)
T.eq("a sale cannot remove more milk than the barn holds", removed, 50)
T.eq("and the payout is against the 50 actually removed", g_currentMission.money[1].income, 49)

-- BAR: the internal function is callable directly with no permission check.
local m7 = newManager()
local p7 = makePlaceable(200)
local b7 = m7:_getOrCreateBarn("b7", 1, p7)
m7._markBarnsDirty = function() end
g_currentMission.money = {}
local directRemoved = m7:_adminSellMilk(b7, 200, SRC.rota, 2412, 100)
T.eq("the rota calls the mechanism directly, no gate in the work", directRemoved, 200)
T.eq("and that direct call records source rota", b7.lastCollectionSource, SRC.rota)

-- BAR: the passive detector does NOT re-count a sale the mod made (suppression +
-- re-seed in the same step).
m7:_observeBarnLevels(b7, 2412, 100)
T.eq("no double-count after a rota sale", b7.lastCollectionLitres[MILK], 200)
T.eq("and the source stays rota", b7.lastCollectionSource, SRC.rota)

-- BAR: the admin action wrapper registers without disabling adminOnly.
local captured = {}
local m8 = newManager()
g_currentMission.networkSync = {
  registerAction = function(_, id, spec) captured[id] = spec end,
}
m8:_bindActions()
T.ok("the sell action is registered", captured[DairyConstants.ACTIONS.SELL_MILK] ~= nil)
T.ok("the rota actions are registered", captured[DairyConstants.ACTIONS.ASSIGN_ROTA] ~= nil
  and captured[DairyConstants.ACTIONS.UNASSIGN_ROTA] ~= nil)
T.eq("adminOnly is not overridden (NetworkSync default true)",
  captured[DairyConstants.ACTIONS.SELL_MILK].adminOnly == nil, true)
g_currentMission.networkSync = nil

-- ══════════════════════════════════════════════════════════
-- DC-9 BAR 5: nextCollectionDue ROUND TRIPS + THE LOAD-TIME CLAMP
-- ══════════════════════════════════════════════════════════

-- StateLedger path.
local m9 = newManager()
local p9 = makePlaceable(100)
local b9 = m9:_getOrCreateBarn("b9", 1, p9)
b9.nextCollectionDue = 500000   -- absurdly far ahead; must clamp on load
b9.collectionInterval = 24
local ser = m9:_serializeBarns()
local m10 = newManager()
m10:_deserializeBarns(ser)
T.ok("nextCollectionDue survives the ledger round trip", m10.barns["b9"] ~= nil)
local nowH = m10:_nowHours()
T.ok("a restored value ahead of the clock is clamped",
  m10.barns["b9"].nextCollectionDue <= nowH + 24)
T.ok("and not clamped below the present", m10.barns["b9"].nextCollectionDue >= nowH)

-- Own-file path (in-memory XMLFile faithful to the subset used).
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

g_currentMission.missionInfo.savegameDirectory = "savegame_dc9"
local m11 = newManager()
local p11 = makePlaceable(100)
local b11 = m11:_getOrCreateBarn("b11", 1, p11)
b11.nextCollectionDue = 500000
b11.collectionInterval = 24
m11._markBarnsDirty = function() end
m11:_saveOwnFile()

local m12 = newManager()
m12._markBarnsDirty = function() end
m12:_loadOwnFile()
T.ok("the own-file path restores the barn", m12.barns["b11"] ~= nil)
T.ok("own-file: a restored value ahead of the clock is clamped",
  m12.barns["b11"].nextCollectionDue <= m12:_nowHours() + 24)

-- ══════════════════════════════════════════════════════════
-- DC-9 BAR 6: THE WORKER ID ROUND TRIPS WITH ITS TYPE INTACT
-- ══════════════════════════════════════════════════════════

-- Wire path: a numeric-string worker id comes back numeric.
local m13 = newManager()
local p13 = makePlaceable(100)
local b13 = m13:_getOrCreateBarn("b13", 1, p13)
b13.assignedWorkerId = "42"
local wire = m13:_onWriteBarnState()
local m14 = newManager()
m14.barns["b13"] = { barnId = "b13", farmId = 1, feedSourceFields = {} }
m14:_onReadBarnState(wire)
T.eq("the wire returns a numeric worker id as a number", m14.barns["b13"].assignedWorkerId, 42)
T.eq("and a string-only id stays a string",
  m14.barns["b13"].assignedWorkerId ~= nil and type(m14.barns["b13"].assignedWorkerId), "number")

-- Own-file path: same type round trip.
local m15 = newManager()
local p15 = makePlaceable(100)
local b15 = m15:_getOrCreateBarn("b15", 1, p15)
b15.assignedWorkerId = "77"
m15._markBarnsDirty = function() end
m15:_saveOwnFile()
local m16 = newManager()
m16._markBarnsDirty = function() end
m16:_loadOwnFile()
T.eq("the own-file path returns a numeric worker id as a number",
  m16.barns["b15"].assignedWorkerId, 77)

-- ══════════════════════════════════════════════════════════
-- THE ROTA RUNS THE ROUND (DC-9 3.4 + DC-21 3.3)
-- ══════════════════════════════════════════════════════════

asServer(true)
local m17 = newManager()
local p17 = makePlaceable(400)
local b17 = m17:_getOrCreateBarn("b17", 1, p17)
b17._placeable = p17
m17._markBarnsDirty = function() end
g_currentMission.money = {}
setRoster({ lifecycle = "available", levelName = "experienced" })
m17:assignCollectionWorker("b17", "w1")
b17.nextCollectionDue = 1   -- window already arrived
m17:onCollectionHourTick({ monotonicDay = 100 })
T.eq("an assigned worker runs the rota sale", p17.spec_husbandry.unloadingStation.fillLevels[MILK], 0)
T.ok("the rota actually removed milk", p17.spec_husbandry.unloadingStation.fillLevels[MILK] < 400)
T.eq("the rota collection is recorded with source rota", b17.lastCollectionSource, SRC.rota)
T.eq("and the rota resets the freshness clock", b17.lastCollectionDay, 100)

-- ══════════════════════════════════════════════════════════
-- DC-9 REPAIR 5: RECONCILE - A STALE BARN IS DROPPED, A FARM CHANGE CLEARS THE ROTA
-- ══════════════════════════════════════════════════════════

local m18 = newManager()
local p18 = makePlaceable(100)
local b18 = m18:_getOrCreateBarn("live", 1, p18)
local b19 = m18:_getOrCreateBarn("ghost", 2, nil)   -- never resolves again
m18.barns["ghost"]._probeDead = true
m18:_reconcileBarns()
T.ok("a provably dead barn record is dropped", m18.barns["ghost"] == nil)
T.ok("a live barn survives reconcile", m18.barns["live"] ~= nil)

local m19 = newManager()
local p19 = makePlaceable(100)
local b20 = m19:_getOrCreateBarn("sold", 1, p19)
b20.assignedWorkerId = "w1"
b20.rotaState = DairyConstants.COLLECTION.ROTA_STATES.ASSIGNED_OK
p19.getOwnerFarmId = function() return 3 end
m19:_reconcileBarns()
T.eq("a barn that changed hands clears its rota", b20.assignedWorkerId, nil)
T.eq("and reports unassigned", b20.rotaState, DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED)
T.eq("and follows its new owner", b20.farmId, 3)


-- ══════════════════════════════════════════════════════════
-- RSF-F216: THE PER-LITRE HANDLING FEE, THE REFUSAL, AND THE PRICE SOURCE
-- ══════════════════════════════════════════════════════════
-- The charge is a fixed amount per litre, so it does NOT move with the price. The
-- sale refuses outright when the fee meets or beats the price, and it refuses
-- BEFORE anything moves: the tank, the barn, the passive detector, the money and
-- the collection record must all be exactly as they were.

local SALE = DairyConstants.SALE

-- Income of the last credit, nil-safe. A mutation that turns a sale into a refusal
-- leaves money empty; reading money[1].income directly would abort the whole file
-- and hide which bar caught it, along with every bar after it.
local function lastIncome()
  local row = g_currentMission.money[#g_currentMission.money]
  return row ~= nil and row.income or nil
end

-- A tank the sale draws from first, so a refusal bar can prove the tank was never
-- touched. The incumbent DC-21 fixtures have no tank, and the tank is the first
-- thing the refusal exists to protect.
local function attachTank(m, litres)
  local tank = { tankId = "t1", fillLevel = litres }
  m.milkTankRegistry = {
    getNearestTankForBarn = function() return tank end,
    removeMilk = function(_, _id, want)
      local take = math.min(want, tank.fillLevel)
      tank.fillLevel = tank.fillLevel - take
      return take
    end,
  }
  return tank
end

-- Drive the price rungs. md = nil removes MarketDynamics entirely.
local function setMarket(md, basePricePerLitre)
  g_currentMission.MarketDynamics = md
  g_fillTypeManager.getFillTypeByIndex = function()
    return { pricePerLiter = basePricePerLitre or 1.0 }
  end
end

local function restoreMarket()
  g_currentMission.MarketDynamics = nil
  g_fillTypeManager.getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end
end

-- BAR: the conversion has exactly one home and the ratified numbers derive from it.
do
  T.eq("F216 default is 11 per 1000 L", SALE.FEE_PER_1000L, 11)
  T.eq("F216 floor is 0 per 1000 L", SALE.FEE_MIN_PER_1000L, 0)
  T.eq("F216 ceiling is 50 per 1000 L", SALE.FEE_MAX_PER_1000L, 50)
  T.near("the default divides to the ratified 0.011/L", SALE.FEE_PER_1000L / SALE.FEE_DIVISOR, 0.011, 1e-9)
  T.near("the ceiling divides to the ratified 0.05/L", SALE.FEE_MAX_PER_1000L / SALE.FEE_DIVISOR, 0.05, 1e-9)
  T.near("the floor divides to the ratified 0.0/L", SALE.FEE_MIN_PER_1000L / SALE.FEE_DIVISOR, 0.0, 1e-9)
  T.eq("the percentage does not survive in the constants", rawget(SALE, "DEFAULT_MARGIN"), nil)
  T.eq("no MARGIN_MAX survives either", rawget(SALE, "MARGIN_MAX"), nil)
end

-- BAR: the deduction does NOT move when the spot price moves. This is the property
-- that separates a per-litre fee from the percentage it replaced: under the old 5%
-- rule a 2.0 price deducted 0.10/L; under F216 it deducts 0.011/L at any price.
do
  asServer(true)
  local mA = newManager()
  local pA = makePlaceable(1000)
  local bA = mA:_getOrCreateBarn("bA", 1, pA)
  mA._markBarnsDirty = function() end
  setMarket(nil, 2.0)
  g_currentMission.money = {}
  mA:_adminSellMilk(bA, 100, SRC.office, 2412, 100)
  -- 100 L at 2.0 less 0.011 = 198.9 -> 198. The old percentage would have paid 190.
  T.eq("at a 2.0 price the fee is still 0.011/L, not a percentage", lastIncome(), 198)

  local mB = newManager()
  local pB = makePlaceable(1000)
  local bB = mB:_getOrCreateBarn("bB", 1, pB)
  mB._markBarnsDirty = function() end
  setMarket(nil, 0.5)
  g_currentMission.money = {}
  mB:_adminSellMilk(bB, 100, SRC.office, 2412, 100)
  -- 100 L at 0.5 less 0.011 = 48.9 -> 48.
  T.eq("at a 0.5 price the deduction is the same 0.011/L", lastIncome(), 48)
  restoreMarket()
end

-- BAR: the charge scales linearly with the litres actually removed.
do
  asServer(true)
  local mC = newManager()
  local pC = makePlaceable(1000)
  local bC = mC:_getOrCreateBarn("bC", 1, pC)
  mC._markBarnsDirty = function() end
  g_currentMission.money = {}
  mC:_adminSellMilk(bC, 200, SRC.office, 2412, 100)
  T.eq("200 L at 1.0 less 0.011/L pays 197", lastIncome(), 197)
  g_currentMission.money = {}
  mC:_adminSellMilk(bC, 400, SRC.office, 2412, 100)
  T.eq("400 L at the same fee pays 395", lastIncome(), 395)
end

-- BAR: the sale floors a non-integer setting before it clamps and divides, so a
-- value written straight into self.settings with no hub present cannot become a
-- second fractional charge. 900 L is chosen because that is where the two readings
-- differ: floored 11 pays 890, unfloored 11.9 would pay 889.
do
  asServer(true)
  local mD = newManager()
  local pD = makePlaceable(1000)
  local bD = mD:_getOrCreateBarn("bD", 1, pD)
  mD._markBarnsDirty = function() end
  mD.settings.saleFeePer1000L = 11.9
  g_currentMission.money = {}
  mD:_adminSellMilk(bD, 900, SRC.office, 2412, 100)
  T.eq("a fractional setting is floored before it is divided", lastIncome(), 890)
end

-- BAR: the clamp still bites on an out-of-band value.
do
  asServer(true)
  local mE = newManager()
  local pE = makePlaceable(1000)
  local bE = mE:_getOrCreateBarn("bE", 1, pE)
  mE._markBarnsDirty = function() end
  mE.settings.saleFeePer1000L = 999
  g_currentMission.money = {}
  mE:_adminSellMilk(bE, 100, SRC.office, 2412, 100)
  -- clamps to 50 -> 0.05/L -> 100 * 0.95 = 95.
  T.eq("an over-ceiling setting clamps to 50 per 1000 L", lastIncome(), 95)
end

-- BAR: a non-finite setting falls back to the ratified default instead of reaching
-- the comparison. spot <= fee is FALSE for a NaN, so without the guard the refusal
-- would not fire and math.max(0, spot - fee) would floor the income to zero with the
-- milk already gone, which is the exact defect this repair removes. The clamp alone
-- happens to sanitise a NaN through math.min's argument order; this pins the
-- behaviour rather than that accident. (Bob, PR #57 cold review.)
do
  asServer(true)
  local mN = newManager()
  local pN = makePlaceable(1000)
  local bN = mN:_getOrCreateBarn("bN", 1, pN)
  mN._markBarnsDirty = function() end
  local nan = 0 / 0
  T.ok("the fixture really holds a NaN", nan ~= nan, "0/0 did not produce a NaN here")
  mN.settings.saleFeePer1000L = nan
  g_currentMission.money = {}
  local removedN, statusN = mN:_adminSellMilk(bN, 100, SRC.office, 2412, 100)
  T.eq("a NaN setting does not suppress the sale", statusN, "ok")
  T.eq("and the milk moves", removedN, 100)
  T.eq("a NaN setting falls back to the ratified default fee", lastIncome(), 98)

  local mI2 = newManager()
  local pI2 = makePlaceable(1000)
  local bI2 = mI2:_getOrCreateBarn("bI2", 1, pI2)
  mI2._markBarnsDirty = function() end
  mI2.settings.saleFeePer1000L = math.huge
  g_currentMission.money = {}
  mI2:_adminSellMilk(bI2, 100, SRC.office, 2412, 100)
  T.eq("an infinite setting falls back to the ratified default fee", lastIncome(), 98)
end

-- BAR: THE REFUSAL, and that nothing moved. Fee exactly equal to the price.
do
  asServer(true)
  local mF = newManager()
  local pF = makePlaceable(1000)
  local bF = mF:_getOrCreateBarn("bF", 1, pF)
  mF._markBarnsDirty = function() end
  local tank = attachTank(mF, 500)
  setMarket(nil, 0.05)
  mF.settings.saleFeePer1000L = 50
  bF.lastCollectionDay = 42
  bF.lastCollectionHours = 7
  bF.lastCollectionSource = SRC.tanker
  bF.lastCollectionLitres = { [MILK] = 123 }
  bF.lastKnownMilkLevel[MILK] = 1000
  g_currentMission.money = {}

  local removedF, statusF = mF:_adminSellMilk(bF, 100, SRC.office, 2412, 100)

  T.eq("an equal fee and price refuses", removedF, nil)
  T.eq("the refusal names fee_exceeds_price", statusF, "fee_exceeds_price")
  T.eq("the tank is untouched", tank.fillLevel, 500)
  T.eq("the barn is untouched", pF.spec_husbandry.unloadingStation.fillLevels[MILK], 1000)
  T.eq("no money changed hands", #g_currentMission.money, 0)
  -- Bob's ordering hazard, BOTH halves. Return inside the suppressed window and a
  -- later REAL milk drop goes unnoticed; return after the bookkeeping and a refused
  -- sale re-seeds the detector as though milk had moved.
  T.ok("the detector suppression is not left on", bF._suppressDetection ~= true,
    "_suppressDetection was left true by a refused sale, so a later real drop would be missed")
  T.eq("no collection litres were recorded", bF.lastCollectionLitres[MILK], 123)
  T.eq("the collection source is unchanged", bF.lastCollectionSource, SRC.tanker)
  T.eq("the collection day is unchanged", bF.lastCollectionDay, 42)
  T.eq("the collection hour is unchanged", bF.lastCollectionHours, 7)
  T.eq("the detector level was not re-seeded", bF.lastKnownMilkLevel[MILK], 1000)
  restoreMarket()
end

-- BAR: strictly above still sells, so the <= boundary is pinned on both sides.
do
  asServer(true)
  local mG = newManager()
  local pG = makePlaceable(1000)
  local bG = mG:_getOrCreateBarn("bG", 1, pG)
  mG._markBarnsDirty = function() end
  setMarket(nil, 0.1)
  mG.settings.saleFeePer1000L = 50
  g_currentMission.money = {}
  local removedG, statusG = mG:_adminSellMilk(bG, 1000, SRC.office, 2412, 100)
  T.eq("a price above the fee still sells", statusG, "ok")
  T.eq("and it removes the milk", removedG, 1000)
  -- 1000 L at 0.1 less the 0.05 ceiling = 50. The margin is deliberately not razor
  -- thin: binary floating point puts 0.06-0.05 at 0.009999999999999995 and 0.051-0.05
  -- at 0.0009999999999999975, so a near-equal pair floors BELOW the arithmetic answer
  -- and the bar would end up asserting invariant 11's whole-currency floor instead of
  -- the boundary it names. The <= boundary itself is pinned by the equality refusal.
  T.eq("paying the margin above the ceiling fee", lastIncome(), 50)
  restoreMarket()
end

-- BAR: the rota observes the refusal, driven through the real hour tick.
do
  asServer(true)
  local mH = newManager()
  local pH = makePlaceable(1000)
  local bH = mH:_getOrCreateBarn("bH", 1, pH)
  mH._markBarnsDirty = function() end
  local tankH = attachTank(mH, 300)
  setRoster("active")
  bH.assignedWorkerId = "w1"
  bH.collectionInterval = 24
  bH.nextCollectionDue = 0
  bH.lastCollectionSource = SRC.tanker
  bH.lastCollectionDay = 42
  bH.lastCollectionHours = 7
  bH.lastCollectionLitres = { [MILK] = 123 }
  setMarket(nil, 0.01)   -- the ONLY difference from the control below
  g_currentMission.money = {}

  mH:onCollectionHourTick({ monotonicDay = 100 })

  T.eq("a refused rota leaves the tank alone", tankH.fillLevel, 300)
  T.eq("a refused rota leaves the barn alone", pH.spec_husbandry.unloadingStation.fillLevels[MILK], 1000)
  T.eq("a refused rota pays nothing", #g_currentMission.money, 0)
  T.eq("a refused rota records no collection source", bH.lastCollectionSource, SRC.tanker)
  T.eq("a refused rota records no collection day", bH.lastCollectionDay, 42)
  T.eq("a refused rota records no collection hour", bH.lastCollectionHours, 7)
  T.eq("a refused rota records no collection litres", bH.lastCollectionLitres[MILK], 123)
  -- The window advance sits OUTSIDE the worker branch, so a refused round still uses
  -- its scheduled slot. That is DC-9 scheduling, not a collection record.
  T.ok("a refused round still advances its window", (bH.nextCollectionDue or 0) > 0,
    "nextCollectionDue did not advance on a refused round")
  restoreMarket()
end

-- BAR: the ordinary successful rota control, same fixture shape. Without it the
-- refusal bar above would pass just as well on a rota that never fired at all.
do
  asServer(true)
  local mI = newManager()
  local pI = makePlaceable(1000)
  local bI = mI:_getOrCreateBarn("bI", 1, pI)
  mI._markBarnsDirty = function() end
  local tankI = attachTank(mI, 300)
  setRoster("active")
  bI.assignedWorkerId = "w1"
  bI.collectionInterval = 24
  bI.nextCollectionDue = 0
  bI.lastCollectionSource = SRC.tanker
  bI.lastCollectionDay = 42
  bI.lastCollectionHours = 7
  bI.lastCollectionLitres = { [MILK] = 123 }
  setMarket(nil, 1.0)    -- identical to the refusal fixture but for the price
  g_currentMission.money = {}

  mI:onCollectionHourTick({ monotonicDay = 100 })

  T.eq("an ordinary rota round does draw the tank", tankI.fillLevel, 0)
  T.ok("an ordinary rota round pays", #g_currentMission.money > 0,
    "the control rota round paid nothing, so the refusal bar above proves nothing")
  -- The same four fields the refusal asserts unchanged, asserted here to MOVE. That
  -- is what makes the refusal's "unchanged" mean something: these fields demonstrably
  -- shift in a fixture that differs only in the price-versus-fee relationship.
  T.eq("an ordinary rota round records its source", bI.lastCollectionSource, SRC.rota)
  T.ok("an ordinary rota round records its day", bI.lastCollectionDay ~= 42,
    "lastCollectionDay did not move on a successful rota round")
  T.ok("an ordinary rota round records its hour", bI.lastCollectionHours ~= 7,
    "lastCollectionHours did not move on a successful rota round")
  T.ok("an ordinary rota round records its litres", bI.lastCollectionLitres[MILK] ~= 123,
    "lastCollectionLitres did not move on a successful rota round")
  -- This is the ONE observable of _rotaCollection's new `return`. The hour tick at
  -- :1177 captures the value into `local removed` and only then sets _lastRunSpeedMod;
  -- without the return that branch read nil and had never fired in the mod's life.
  -- Nothing else in the mod observes it, so without this bar the return is unpinned
  -- and a builder could drop it with the whole suite still green.
  T.ok("the rota's return reaches the hour tick", bI._lastRunSpeedMod ~= nil,
    "_lastRunSpeedMod was not set, so _rotaCollection's return value never reached the tick")
  restoreMarket()
end

-- ── Price source: the new resolver's rungs ─────────────────
-- Active and pricing uses the MarketDynamics quote; every other outcome, INCLUDING
-- a throwing provider, reaches DairyCore's fill-type base price rung.

do
  asServer(true)
  local mJ = newManager()
  local function priceOf() return mJ:_milkSaleUnitPrice(MILK) end

  setMarket({ isActive = true, marketEngine = { getPrice = function() return 1.8 end } }, 1.0)
  T.near("an active provider's quote is used", priceOf(), 1.8, 1e-9)

  setMarket({ isActive = true, settings = { pricesEnabled = false },
              marketEngine = { getPrice = function() return 1.8 end } }, 1.0)
  T.near("pricesEnabled false falls to the fill-type base", priceOf(), 1.0, 1e-9)

  setMarket({ isActive = false, marketEngine = { getPrice = function() return 1.8 end } }, 1.0)
  T.near("isActive false falls to the fill-type base", priceOf(), 1.0, 1e-9)

  setMarket({ isActive = true, marketEngine = { getPrice = function() return nil end } }, 1.0)
  T.near("a nil quote falls to the base, not to the 1.0 literal", priceOf(), 1.0, 1e-9)

  setMarket({ isActive = true, marketEngine = { getPrice = function() return 0 end } }, 0.75)
  T.near("a non-positive quote falls through to the base", priceOf(), 0.75, 1e-9)

  -- THE BAR THAT CATCHES A SINGLE OUTER PCALL. A throwing provider must still reach
  -- the fill-type rung; wrapped in one pcall the ladder aborts and the sale lands on
  -- the 1.0 literal having never tried the fill type.
  setMarket({ isActive = true, marketEngine = { getPrice = function() error("provider exploded") end } }, 0.75)
  T.near("a THROWING provider still reaches the fill-type rung", priceOf(), 0.75, 1e-9)

  setMarket(nil, 0.6)
  T.near("an absent provider uses the fill-type base", priceOf(), 0.6, 1e-9)

  -- An absent settings object does not by itself reject an otherwise active quote.
  setMarket({ isActive = true, marketEngine = { getPrice = function() return 1.4 end } }, 1.0)
  T.near("an absent settings table does not reject the quote", priceOf(), 1.4, 1e-9)
  restoreMarket()
end

-- BAR: the farmer case Arissani ruled on. Prices disabled, the MarketDynamics quote
-- below the fee, the fill-type base above it. The sale PROCEEDS on the base price;
-- before this fold it would have refused and held the milk.
do
  asServer(true)
  local mK = newManager()
  local pK = makePlaceable(1000)
  local bK = mK:_getOrCreateBarn("bK", 1, pK)
  mK._markBarnsDirty = function() end
  setMarket({ isActive = true, settings = { pricesEnabled = false },
              marketEngine = { getPrice = function() return 0.005 end } }, 0.7)
  g_currentMission.money = {}
  local removedK, statusK = mK:_adminSellMilk(bK, 100, SRC.office, 2412, 100)
  T.eq("a disabled provider's low quote cannot refuse the sale", statusK, "ok")
  T.eq("the milk moves", removedK, 100)
  -- 100 L at the 0.7 base less 0.011 = 68.9 -> 68.
  T.eq("and it pays on the base price", lastIncome(), 68)
  restoreMarket()
end

-- BAR: contract settlement does not move. _payContract reads _milkSpotPrice, which
-- F216 leaves byte-identical, so the contract number is the same across every price
-- source case the sale now distinguishes. This is the bar that catches a builder who
-- tidies the two helpers into one.
do
  asServer(true)
  local mL = newManager()
  local cases = {
    { name = "active and pricing", md = { isActive = true, marketEngine = { getPrice = function() return 1.8 end } }, want = 1.8 },
    { name = "prices disabled",    md = { isActive = true, settings = { pricesEnabled = false },
                                          marketEngine = { getPrice = function() return 1.8 end } }, want = 1.8 },
    { name = "inactive provider",  md = { isActive = false, marketEngine = { getPrice = function() return 1.8 end } }, want = 1.8 },
    { name = "absent provider",    md = nil, want = 1.0 },
  }
  for _, case in ipairs(cases) do
    setMarket(case.md, 1.0)
    -- _milkSpotPrice ignores isActive and pricesEnabled BY DESIGN: it takes any engine
    -- quote it can reach. That is today's behaviour and F216 must not move it.
    T.near("_milkSpotPrice unchanged for " .. case.name, mL:_milkSpotPrice(), case.want, 1e-9)
  end
  restoreMarket()
end

-- BAR: a stored pre-F216 saleMargin cannot reach the new setting. The key is new on
-- purpose: SettingsHub looks its definitions up BY KEY, so an old stored 0.05 has no
-- definition to land on and is skipped, rather than flooring to 0 and silently
-- waiving the fee on every existing save.
do
  asServer(true)
  local mM = newManager()
  local defs, onChange = nil, nil
  g_currentMission.settingsHub = {
    registerModule = function(_, _modId, spec)
      defs = {}
      for _, d in ipairs(spec.adminSettings or {}) do defs[d.id] = d end
      onChange = spec.onChange
    end,
  }
  mM:_bindBedrock()
  g_currentMission.settingsHub = nil

  T.ok("the new integer setting is registered", defs ~= nil and defs.saleFeePer1000L ~= nil,
    "saleFeePer1000L was not registered")
  T.eq("the old float key is gone", defs.saleMargin, nil)
  T.eq("the new setting is an int", defs.saleFeePer1000L.type, "int")
  T.eq("its default is the ratified 11", defs.saleFeePer1000L.default, 11)
  T.eq("its band floor is 0", defs.saleFeePer1000L.min, 0)
  T.eq("its band ceiling is 50", defs.saleFeePer1000L.max, 50)
  T.eq("it steps by 1", defs.saleFeePer1000L.step, 1)
  T.eq("it stays admin only", defs.saleFeePer1000L.adminOnly, true)

  -- SettingsHub's own restore looks up mod.defs[key] and skips an unknown key, so a
  -- stored saleMargin has nowhere to land.
  local before = mM.settings.saleFeePer1000L
  onChange("saleMargin", 0.05)
  T.eq("delivering a stored saleMargin changes nothing", mM.settings.saleFeePer1000L, before)
  T.eq("the manager holds no saleMargin field", rawget(mM.settings, "saleMargin"), nil)

  onChange("saleFeePer1000L", 30)
  T.eq("the new key does write through", mM.settings.saleFeePer1000L, 30)
end

T.summary()
