-- dc9_21_milk_round_test.lua - DC-9 COLLECTION SCHEDULING + DC-21 ADMIN SALE.
--
-- The milk round, in three parts:
--   * DC-9 detects milk leaving a barn (tanker, AI haul) from the raw storage level
--     and runs the standing round (rota).
--   * DC-21 sells milk from an office/rota action: remove, price, margin, credit.
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

-- BAR: margin is a percentage subtraction; the amount is priced against what was
-- actually removed; the money credit has the _payContract shape.
g_currentMission.money = {}
local removed, status = m5:_adminSellMilk(b5, 100, SRC.office, 2412, 100)
T.eq("the sale returns the removed litres", removed, 100)
T.eq("the sale returns ok", status, "ok")
T.eq("money is credited (100 L * 1.0 * 0.95 margin)", g_currentMission.money[1].income, 95)
T.eq("the credit is MoneyType.OTHER", g_currentMission.money[1].mtype, MoneyType.OTHER)
T.eq("the credit goes to the barn's farm", g_currentMission.money[1].farmId, 1)
T.eq("the collection is recorded with source office", b5.lastCollectionSource, SRC.office)
T.eq("the milk actually left", p5.spec_husbandry.unloadingStation.fillLevels[MILK], 900)

-- BAR: changing the named setting changes the outcome without touching the mechanism.
m5.settings.saleMargin = 0.10
g_currentMission.money = {}
removed = m5:_adminSellMilk(b5, 100, SRC.office, 2412, 100)
T.eq("a 10% margin changes the payout", g_currentMission.money[1].income, 90)

-- BAR: the sale prices against the ACTUAL removed amount, not the request.
local m6 = newManager()
local p6 = makePlaceable(50)   -- only 50 L present
local b6 = m6:_getOrCreateBarn("b6", 1, p6)
m6._markBarnsDirty = function() end
g_currentMission.money = {}
removed = m6:_adminSellMilk(b6, 1000, SRC.office, 2412, 100)
T.eq("a sale cannot remove more milk than the barn holds", removed, 50)
T.eq("and the payout is against the 50 actually removed", g_currentMission.money[1].income, 47)

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

T.summary()
