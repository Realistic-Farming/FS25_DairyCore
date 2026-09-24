-- dc14_collection_refusal_producer_test.lua - DC-14 host slice A: the session
-- report and its safe view (SDS v0.9, brief v1.0 sections 2, 3, 4 and 8).
--
-- THE ENTRY-POINT BAR IS GROUP S. The manager is built by DairyCoreManager.new()
-- and enters through onMissionLoaded (main.lua's appended call): the session reset,
-- the bedrock binds, the Time Guard subscription and barn DISCOVERY through the
-- mission's placeable list. The worker is assigned through the real
-- assignCollectionWorker (what the NetworkSync action calls), the clock advances
-- through the mission environment, and the hour tick fires through the captured
-- Time Guard subscription into the real onCollectionHourTick, whose real
-- _rotaCollection reaches RSF-F216's fee gate in _adminSellMilk. The fee refusal
-- comes from the sale's own comparison of the price rung against the fee setting,
-- never from a hand-set status. Nothing here writes a record, a row or a view.
-- group() runs each group under pcall and reports a raise as a named FAIL row of its
-- own, so a raising group is a failure with a name, never a silent skip.
--
-- Groups:
--   S  the entry-point bar: a fee refusal with milk in the barn is FEE_EXCEEDS_PRICE
--      with the attempt hour and the next due, read through the getter
--   N  an ordinary sale clears the explanation; the milk and money moved
--   Z  an empty high-fee round proves zero and clears an older explanation
--   T  the Dairy tank registry: live owner, live position, registry fill
--   U  fail-closed barn reads and a raising sale: UNAVAILABLE, never zero
--   O  owner changes and unreadable owners
--   W  worker assignment changes next due, never the past attempt
--   F  strict farm admission of the getter
--   G  settings-off, PF stand-down, a pure client
--   L  labels: the ladder, then the bounded fallback
--   M  mission boundaries, the office sale, a haul
--   R  a confirmed removal
--   K  sorting and detachment
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/MilkTank.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

local MILK_NAME = DairyConstants.CONTRACTS.MILK_FILLTYPE
local MILK_INDEX = 1
local R = DairyConstants.COLLECTION_REFUSAL
local SRC = DairyConstants.COLLECTION.SOURCES

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine world ────────────────────────────────────────
-- FarmManager.lua:3-8.
FarmManager = { MAX_NUM_FARMS = 8, MAX_FARM_ID = 8, SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1,
  GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
MoneyType = { OTHER = 1 }
-- No own save file on disk: the engine's loadIfExists answers nil.
XMLFile = { loadIfExists = function() return nil end }
function getWorldTranslation(node) return node.x, node.y, node.z end
g_server = {}
g_modIsLoaded = {}
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == MILK_NAME then return MILK_INDEX end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}

local function setPrice(pricePerLitre)
  g_fillTypeManager.getFillTypeByIndex = function() return { pricePerLiter = pricePerLitre } end
end

local function newMission()
  local ticks = {}
  local m = {
    _isServer = true, _localFarm = 1,
    missionInfo = { savegameDirectory = "savegame1" },
    environment = { currentDay = 100, dayTime = 6 * 3600 * 1000 },
    placeableSystem = { placeables = {} },
    money = {},
    timeGuard = { subscribeTick = function(_, kind, name, fn) ticks[kind] = fn end },
    _ticks = ticks,
    workerCostsManager = { getRosterSnapshot = function()
      return { workers = { { uuid = "w1", lifecycleState = "hired", levelName = "experienced" } } } end },
  }
  function m:getIsServer() return self._isServer end
  function m:getFarmId() return self._localFarm end
  -- PlaceableSystem:getPlaceableByUniqueId (decompiled evidence, guarded by the
  -- caller): the placeable currently registered under that id, or nil.
  function m.placeableSystem:getPlaceableByUniqueId(id)
    for _, p in ipairs(self.placeables) do
      if p:getUniqueId() == id then return p end
    end
    return nil
  end
  function m:addMoney(income, farmId) self.money[#self.money + 1] = { income = income, farmId = farmId } end
  return m
end

--- A dairy barn placeable. Its native husbandry Storage (PlaceableHusbandry.lua:89)
--- is keyed by the numeric fill-type index (Storage.lua:275-283); the unloading
--- station the existing DC-9/DC-21 paths read is keyed by the fill-type name, as
--- those paths expect. The removal path keeps the two in step.
local function makeBarn(id, owner, litres, opts)
  opts = opts or {}
  local storage = { fillTypes = { [MILK_INDEX] = true }, fillLevels = { [MILK_INDEX] = litres }, listeners = {} }
  function storage:getIsFillTypeSupported(ft) return self.fillTypes[ft] == true end
  function storage:getFillLevel(ft) return self.fillLevels[ft] or 0 end
  function storage:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function storage:removeFillLevelChangedListeners() end
  local station = { fillLevels = { [MILK_NAME] = opts.stationLitres or litres }, listeners = {} }
  function station:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function station:removeFillLevelChangedListeners() end
  local p = {
    spec_husbandryMilk = {},
    spec_husbandry = { storage = storage, unloadingStation = station },
    rootNode = { x = opts.x or 0, y = 0, z = opts.z or 0 },
    _owner = owner, _name = opts.name or ("Barn " .. id),
  }
  function p:getUniqueId() return id end
  function p:getOwnerFarmId() return self._owner end
  function p:getName() return self._name end
  function p:removeHusbandryFillLevel(farmId, delta, ft)
    local cur = storage.fillLevels[MILK_INDEX] or 0
    -- opts.removeCap: a husbandry that honours only part of a removal per call.
    local removed = math.min(delta, cur, opts.removeCap or math.huge)
    storage.fillLevels[MILK_INDEX] = cur - removed
    station.fillLevels[MILK_NAME] = cur - removed
    return delta - removed
  end
  p._storage, p._station = storage, station
  return p
end

--- A milk tank placeable for the real registry (MilkTank:registerTank reads
--- getUniqueId, getOwnerFarmId and the root node).
local function makeTank(id, owner, x, z)
  local p = { rootNode = { x = x, y = 0, z = z }, _owner = owner }
  function p:getUniqueId() return id end
  function p:getOwnerFarmId() return self._owner end
  return p
end

--- Boot as production does: a fresh manager, the mission's placeable list, then
--- onMissionLoaded. Returns the mission and the manager.
local function boot(placeables, pricePerLitre, feePer1000)
  local m = newMission()
  g_currentMission = m
  g_modIsLoaded = {}
  setPrice(pricePerLitre or 1.0)
  for _, p in ipairs(placeables or {}) do
    m.placeableSystem.placeables[#m.placeableSystem.placeables + 1] = p
  end
  local mgr = DairyCoreManager.new()
  mgr.settings.saleFeePer1000L = feePer1000 or DairyConstants.SALE.FEE_PER_1000L
  mgr:onMissionLoaded()
  -- The mission's per-frame update is what settles discovery in production
  -- (_retryDiscovery clears the pending flag once every stored barn is live).
  mgr:update(600)
  return m, mgr
end

--- Advance the mission clock by whole days and fire the hour tick the manager
--- subscribed to Time Guard.
local function hourTick(m, days)
  m.environment.currentDay = m.environment.currentDay + (days or 0)
  m._ticks.hour({ monotonicDay = m.environment.currentDay })
end

--- Assign the worker through the real path, then run the round that falls due.
local function dueRound(m, mgr, barnId)
  T.eq("[world] the worker is assigned through the real path", mgr:assignCollectionWorker(barnId, "w1"), true)
  hourTick(m, 1)
end

local function view(mgr) return mgr:getCollectionRefusalViews() end
local function rowOf(v, key)
  for _, r in ipairs(v and v.rows or {}) do if r.barnKey == key then return r end end
  return nil
end
--- fengari spells an integral float "2430.0" where the game's Lua prints "2430";
--- the bar compares rounded numbers, never the spelling.
local function num(x)
  if type(x) ~= "number" then return tostring(x) end
  local r = math.floor(x * 10000 + 0.5) / 10000
  if r == math.floor(r) then return string.format("%d", math.floor(r)) end
  return tostring(r)
end
local function describe(r)
  if r == nil then return "nil" end
  return tostring(r.state) .. "/" .. tostring(r.code) .. "/" .. num(r.attemptHours) .. "/" .. num(r.nextDueHours) .. "/" .. tostring(r.reason)
end

-- ══════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════
group("S", function()
  local barn = makeBarn("b1", 1, 500)
  -- 50 per 1000 L is a fee of 0.05/L; a base price of 0.05/L meets it, so the
  -- sale's own gate refuses (DairyCoreManager._adminSellMilk, spot <= fee).
  local m, mgr = boot({ barn }, 0.05, 50)
  T.ok("S1 [reached] the manager carries the getter the reference bar said was not built", type(DairyCoreManager.getCollectionRefusalViews) == "function")
  T.ok("S2 [reached] onMissionLoaded subscribed the hour tick to Time Guard and discovered the barn",
    m._ticks.hour ~= nil and mgr.barns.b1 ~= nil and mgr.barns.b1._placeable == barn)
  local before = view(mgr)
  T.eq("S3 before any round the barn's row is NONE_RECORDED", describe(rowOf(before, "b1")), "NONE_RECORDED/0/nil/nil/nil")
  dueRound(m, mgr, "b1")
  T.eq("S4 [world] the refused round left the milk in the barn and moved no money",
    tostring(barn._storage.fillLevels[MILK_INDEX]) .. "/" .. tostring(#m.money), "500/0")
  local v = view(mgr)
  T.eq("S5 the view is READY for the local farm", tostring(v.state) .. "/" .. tostring(v.reason) .. "/" .. tostring(#v.rows), "READY/nil/1")
  -- Day 101 at 06:00 is monotonic hour 2430; the next due is one interval on.
  T.eq("S6 the row is FEE_EXCEEDS_PRICE with the attempt hour and the next due", describe(rowOf(v, "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454/nil")
  T.eq("S7 the row carries the stable key and the placeable's own name", rowOf(v, "b1").barnKey .. "|" .. rowOf(v, "b1").barnLabel, "b1|Barn b1")
  T.eq("S8 [world] the rota's own schedule advanced as before", num(mgr.barns.b1.nextCollectionDue), "2454")
  -- A second refused round replaces the attempt hour; no history accumulates.
  hourTick(m, 1)
  T.eq("S9 a repeated refusal replaces the attempt hour", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2454/2478/nil")
end)

-- ══════════════════════════════════════════════════════════
-- N. AN ORDINARY SALE CLEARS
-- ══════════════════════════════════════════════════════════
group("N", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  T.eq("N1 the refusal is recorded", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  setPrice(1.0)
  hourTick(m, 1)
  T.eq("N2 [world] the next round sold the milk and paid the farm",
    tostring(barn._storage.fillLevels[MILK_INDEX]) .. "/" .. tostring(#m.money), "0/1")
  T.eq("N3 an ordinary result clears the explanation", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2478/nil")
  local rev = mgr.collectionRefusal.revision
  hourTick(m, 1)
  T.eq("N3b a due round with nothing to report still moves the next due, so the revision moves", describe(rowOf(view(mgr), "b1")) .. "/" .. tostring(mgr.collectionRefusal.revision > rev), "NONE_RECORDED/0/nil/2502/nil/true")

  -- A sale the husbandry honours only in part: an ordinary result with milk still
  -- in the barn is no refusal.
  local barn2 = makeBarn("b2", 1, 500, { removeCap = 100 })
  local m2, mgr2 = boot({ barn2 }, 1.0)
  dueRound(m2, mgr2, "b2")
  T.eq("N4 [world] the sale took what the husbandry gave and paid for it",
    tostring(barn2._storage.fillLevels[MILK_INDEX]) .. "/" .. tostring(#m2.money), "400/1")
  T.eq("N4b an ordinary sale that left milk behind is no report", describe(rowOf(view(mgr2), "b2")), "NONE_RECORDED/0/nil/2454/nil")

  -- A round whose sale finds no milk to sell (the station reads empty while the
  -- native Storage holds milk) records no collection, and still clears: any
  -- ordinary result does, not only one that went through markCollected.
  local barn3 = makeBarn("b3", 1, 500, { stationLitres = 0 })
  local m3, mgr3 = boot({ barn3 }, 0.05, 50)
  dueRound(m3, mgr3, "b3")
  T.eq("N5 the refusal is recorded from the native Storage", rowOf(view(mgr3), "b3").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  setPrice(1.0)
  hourTick(m3, 1)
  T.eq("N5b [world] the round found no milk to sell, so nothing was collected",
    tostring(#m3.money) .. "/" .. tostring(mgr3.barns.b3.lastCollectionSource), "0/nil")
  T.eq("N5c a no-milk result clears the explanation all the same", describe(rowOf(view(mgr3), "b3")), "NONE_RECORDED/0/nil/2478/nil")
end)

-- ══════════════════════════════════════════════════════════
-- Z. AN EMPTY HIGH-FEE ROUND
-- ══════════════════════════════════════════════════════════
group("Z", function()
  local barn = makeBarn("b1", 1, 0)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  T.eq("Z1 a fee refusal with trusted zero milk is no report", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2454/nil")
  -- An older explanation, then a round that finds the native Storage empty while
  -- the station the passive detector reads is unchanged (so the clear is the
  -- presence read's, not markCollected's).
  barn._storage.fillLevels[MILK_INDEX] = 500
  hourTick(m, 1)
  T.eq("Z2 milk in the barn: the explanation is recorded", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  barn._storage.fillLevels[MILK_INDEX] = 0
  hourTick(m, 1)
  T.eq("Z3 trusted zero clears the older explanation", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2502/nil")
end)

-- ══════════════════════════════════════════════════════════
-- T. THE DAIRY TANK REGISTRY
-- ══════════════════════════════════════════════════════════
group("T", function()
  -- Zero in the barn, 300 L in a same-farm tank 10 m away.
  local barn = makeBarn("b1", 1, 0)
  local m, mgr = boot({ barn }, 0.05, 50)
  local tank = makeTank("t1", 1, 10, 0)
  mgr:registerMilkTank(tank)
  T.eq("T0 [world] the real registry holds the tank's milk", mgr.milkTankRegistry:addMilk("t1", 300), 300)
  dueRound(m, mgr, "b1")
  T.eq("T1 a positive same-farm tank in range proves presence", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454/nil")
  T.eq("T1b [world] the refusal drew nothing from the tank", mgr.milkTankRegistry:getFillLevel("t1"), 300)

  -- The same tank owned by another farm: no source, no report.
  tank._owner = 2
  hourTick(m, 1)
  T.eq("T2 a live foreign owner is ignored, even though the registry cached farm 1", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2478/nil")
  tank._owner = 1

  -- Out of range: not a candidate.
  tank.rootNode.x = 200
  hourTick(m, 1)
  T.eq("T3 a tank outside the radius is no source", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2502/nil")
  tank.rootNode.x = 10

  -- An owner that cannot be read on a tank that could be in range: unavailable.
  tank.getOwnerFarmId = function() error("no owner") end
  hourTick(m, 1)
  T.eq("T4 an unreadable owner in range fails closed", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2526/EVALUATION_ERROR")
  tank.getOwnerFarmId = function(self) return self._owner end

  -- A registry record with no live placeable (restored from a save, never
  -- re-registered): its position cannot be read, so it could hold the answer.
  -- The live tank is emptied first, since any admitted positive tank would win.
  mgr.milkTankRegistry.tanks.t1.fillLevel = 0
  mgr.milkTankRegistry:deserialize({ t9 = { f = 100, c = 1000, farm = 1 } })
  hourTick(m, 1)
  T.eq("T5 a record with no live position fails closed", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2550/EVALUATION_ERROR")
  mgr.milkTankRegistry.tanks.t9 = nil

  -- A malformed registry fill on a same-farm tank in range: unavailable.
  mgr.milkTankRegistry.tanks.t1.fillLevel = 0 / 0
  hourTick(m, 1)
  T.eq("T6 a malformed registry fill fails closed", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2574/EVALUATION_ERROR")
  mgr.milkTankRegistry.tanks.t1.fillLevel = 0

  -- Empty same-farm tank plus a positive foreign one: resolved zero.
  local foreign = makeTank("t2", 2, 5, 5)
  mgr:registerMilkTank(foreign)
  mgr.milkTankRegistry:addMilk("t2", 900)
  hourTick(m, 1)
  T.eq("T7 resolved empty own tank and a full foreign one prove zero", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2598/nil")

  -- Positive barn milk wins before any tank is read, unreadable or not.
  barn._storage.fillLevels[MILK_INDEX] = 40
  mgr.milkTankRegistry:deserialize({ t9 = { f = 100, c = 1000, farm = 1 } })
  hourTick(m, 1)
  T.eq("T8 positive barn milk proves presence and no tank can poison it", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2598/2622/nil")
end)

-- ══════════════════════════════════════════════════════════
-- U. FAIL-CLOSED BARN READS AND A RAISING SALE
-- ══════════════════════════════════════════════════════════
group("U", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  barn.spec_husbandry.storage = nil
  dueRound(m, mgr, "b1")
  T.eq("U1 no native Storage on the husbandry: unavailable, never zero", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2454/EVALUATION_ERROR")
  barn.spec_husbandry.storage = barn._storage

  barn._storage.fillTypes[MILK_INDEX] = false
  hourTick(m, 1)
  T.eq("U2 MILK unsupported by the Storage: unavailable", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2478/EVALUATION_ERROR")
  barn._storage.fillTypes[MILK_INDEX] = true

  barn._storage.fillLevels[MILK_INDEX] = "500"
  hourTick(m, 1)
  T.eq("U3 a malformed level: unavailable", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2502/EVALUATION_ERROR")
  barn._storage.fillLevels[MILK_INDEX] = 500

  local saved = g_fillTypeManager.getFillTypeIndexByName
  g_fillTypeManager.getFillTypeIndexByName = function() return 0 end
  hourTick(m, 1)
  T.eq("U4 an unresolved MILK index: unavailable", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2526/EVALUATION_ERROR")
  g_fillTypeManager.getFillTypeIndexByName = saved

  -- A supported Storage whose fillLevels table has no MILK entry is a trusted zero
  -- (Storage.lua:278-280), and one that only offers getFillLevel is read through it.
  barn._storage.fillLevels = {}
  hourTick(m, 1)
  T.eq("U5 a supported index with no entry is trusted zero", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2550/nil")
  barn._storage.fillLevels = nil
  barn._storage.getFillLevel = function() return 12 end
  hourTick(m, 1)
  T.eq("U6 getFillLevel is the read when no fillLevels table is exposed", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2550/2574/nil")
  barn._storage.fillLevels = { [MILK_INDEX] = 500 }

  -- A sale that raises (a companion's markDirty throwing inside markCollected):
  -- the row is unavailable, nothing claims a collection, and the tick loop goes on
  -- to the next barn instead of aborting.
  local barn2 = makeBarn("b2", 1, 300)
  m.placeableSystem.placeables[#m.placeableSystem.placeables + 1] = barn2
  mgr:discoverBarns()
  mgr:assignCollectionWorker("b2", "w1")
  setPrice(1.0)
  m.networkSync = { markDirty = function() error("companion down") end }
  local okTick = pcall(hourTick, m, 1)
  local v = view(mgr)
  T.eq("U7 the hour tick survives a raising sale", okTick, true)
  T.eq("U7a and leaves that barn unavailable", describe(rowOf(v, "b1")), "UNAVAILABLE/2/nil/2598/EVALUATION_ERROR")
  -- b2 was registered after the last tick, so only this tick can have touched it: its
  -- next due set, its detector seeded (this tick also sells it, since it has a worker,
  -- a price and no due yet, and the sale re-seeds at the post-sale level, :1146) and
  -- its milk gone. Those are the proof the loop went on past the raise.
  T.eq("U7b the tick still reached the second barn: due set, detector seeded, its own sale made",
    tostring(mgr.barns.b2.nextCollectionDue ~= nil) .. "/" .. tostring(mgr.barns.b2.lastKnownMilkLevel[MILK_NAME]) .. "/" .. tostring(barn2._station.fillLevels[MILK_NAME]), "true/0/0")
  m.networkSync = nil
end)

-- ══════════════════════════════════════════════════════════
-- O. OWNERS
-- ══════════════════════════════════════════════════════════
group("O", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  -- The placeable changes hands before the round; the cache still says farm 1.
  barn._owner = 2
  dueRound(m, mgr, "b1")
  T.eq("O1 farm 1 no longer sees the barn at all", #view(mgr).rows, 0)
  m._localFarm = 2
  T.eq("O2 the new owner sees an unavailable row, never a fee reason read past a stale cache", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2454/OWNER_UNRESOLVED")
  -- Reconciliation corrects the cache; the next round is the new owner's own.
  local revO = mgr.collectionRefusal.revision
  mgr:discoverBarns()
  T.ok("O3c reconciliation moved the barn between two farms' views, so the revision moved", mgr.collectionRefusal.revision > revO)
  T.eq("O3 [world] reconciliation moved the barn to farm 2 and cleared its rota", tostring(mgr.barns.b1.farmId) .. "/" .. tostring(mgr.barns.b1.assignedWorkerId), "2/nil")
  T.eq("O3b re-registration under the new owner cleared the old row, before any new round", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/nil/nil")
  dueRound(m, mgr, "b1")
  T.eq("O4 the new owner's own refused round is recorded for farm 2", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2454/2478/nil")

  -- A recorded explanation, then a sale to another farm: invalidated before any
  -- view is returned, for either farm.
  barn._owner = 3
  m._localFarm = 3
  T.eq("O5 the buyer sees no report, not the seller's", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2478/nil")
  m._localFarm = 2
  T.eq("O6 the seller no longer sees the barn", #view(mgr).rows, 0)

  -- An owner that cannot be read: the cached farm gets an unavailable row.
  barn._owner = 2
  mgr:discoverBarns()
  barn.getOwnerFarmId = function() error("owner unreadable") end
  T.eq("O7 an unreadable owner is an unavailable row for the cached farm", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2478/OWNER_UNRESOLVED")
  m._localFarm = 1
  T.eq("O8 and no row for anyone else", #view(mgr).rows, 0)
  barn.getOwnerFarmId = function(self) return self._owner end
  m._localFarm = 2
  mgr:assignCollectionWorker("b1", "w1")
  barn.getOwnerFarmId = function() error("owner unreadable") end
  hourTick(m, 1)
  T.eq("O9 a refused round with an unreadable owner stores no fee reason", describe(rowOf(view(mgr), "b1")), "UNAVAILABLE/2/nil/2502/OWNER_UNRESOLVED")
  T.eq("O9b [world] the milk was never read for it", tostring(mgr.collectionRefusal.records.b1.state) .. "/" .. tostring(mgr.collectionRefusal.records.b1.reason), "UNAVAILABLE/OWNER_UNRESOLVED")
end)

-- ══════════════════════════════════════════════════════════
-- W. WORKERS
-- ══════════════════════════════════════════════════════════
group("W", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  local rev = mgr.collectionRefusal.revision
  T.eq("W0 the refusal is recorded with the next due", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454/nil")
  mgr:unassignCollectionWorker("b1")
  T.eq("W1 unassigning keeps the past attempt and drops the next due", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2430/nil/nil")
  T.ok("W2 the shown projection changed, so the revision moved", mgr.collectionRefusal.revision > rev)
  mgr:assignCollectionWorker("b1", "w1")
  T.eq("W3 reassigning restores the next due and leaves the attempt untouched", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454/nil")
  -- A window that passes with no worker is missed, not an attempt: the report stands.
  mgr:unassignCollectionWorker("b1")
  hourTick(m, 1)
  T.eq("W4 a missed window is no attempt and clears nothing", describe(rowOf(view(mgr), "b1")), "FEE_EXCEEDS_PRICE/1/2430/nil/nil")
end)

-- ══════════════════════════════════════════════════════════
-- F. STRICT FARM ADMISSION
-- ══════════════════════════════════════════════════════════
group("F", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  local function stateFor(farm)
    m._localFarm = farm
    local v = view(mgr)
    return tostring(v.state) .. "/" .. tostring(v.reason) .. "/" .. tostring(#v.rows)
  end
  T.eq("F1 spectator farm 0 is no real farm", stateFor(0), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F2 the guided-tour id is no real farm", stateFor(14), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F3 the invalid id is no real farm", stateFor(15), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F4 an id past MAX_FARM_ID is no real farm", stateFor(9), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F5 a fractional id is no real farm", stateFor(2.5), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F6 NaN is no real farm", stateFor(0 / 0), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F7 nil (a dedicated server has no local player) is no real farm", stateFor(nil), "UNAVAILABLE/NO_REAL_FARM/0")
  T.eq("F8 another real farm sees a READY view with none of farm 1's barns", stateFor(2), "READY/nil/0")
  T.eq("F9 farm 8 is a real farm", stateFor(8), "READY/nil/0")
  T.eq("F10 the owning farm sees its row", stateFor(1), "READY/nil/1")
end)

-- ══════════════════════════════════════════════════════════
-- G. SETTINGS OFF, PF STAND-DOWN, A PURE CLIENT
-- ══════════════════════════════════════════════════════════
group("G", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  mgr.settings.enabled = false
  local v = view(mgr)
  T.eq("G1 settings off is UNAVAILABLE with SETTINGS_OFF and no rows", tostring(v.state) .. "/" .. tostring(v.reason) .. "/" .. tostring(#v.rows), "UNAVAILABLE/SETTINGS_OFF/0")
  mgr.settings.enabled = true
  T.eq("G2 re-enabling shows the retained report", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)

  m._isServer = false
  v = view(mgr)
  T.eq("G3 a pure client before any snapshot is WAITING with FIRST_SNAPSHOT, never no-report", tostring(v.state) .. "/" .. tostring(v.reason) .. "/" .. tostring(#v.rows), "WAITING/FIRST_SNAPSHOT/0")
  m._localFarm = 0
  v = view(mgr)
  T.eq("G3b a pure client with no real farm is NO_REAL_FARM before any route", tostring(v.state) .. "/" .. tostring(v.reason), "UNAVAILABLE/NO_REAL_FARM")
  m._localFarm = 1
  m._isServer = true

  -- PF present at the next load of the SAME manager object: the session map is
  -- emptied above the stand-down return, and no surface exists.
  g_modIsLoaded["FS25_precisionFarming"] = true
  mgr:onMissionLoaded()
  T.eq("G4 PF stand-down exposes no collection surface", view(mgr), nil)
  T.eq("G5 the session map was reset above the stand-down return", next(mgr.collectionRefusal.records), nil)
  g_modIsLoaded["FS25_precisionFarming"] = nil
end)

-- ══════════════════════════════════════════════════════════
-- L. LABELS
-- ══════════════════════════════════════════════════════════
group("L", function()
  local long = string.rep("N", 129)
  local b1 = makeBarn("north-01", 1, 0, { name = long })
  local b2 = makeBarn("south-02", 1, 0, { name = "Bad\255Name" })
  local b3 = makeBarn("west-03", 1, 0, { name = "Weide \195\164 Hof" })
  local b4 = makeBarn("east-04", 1, 0)
  b4.getName = nil
  local m, mgr = boot({ b1, b2, b3, b4 }, 1.0)
  local v = view(mgr)
  T.eq("L1 a label over 128 bytes falls back to the bounded literal from the key's last bytes", rowOf(v, "north-01").barnLabel, "Barn h-01")
  T.eq("L2 invalid UTF-8 falls back likewise", rowOf(v, "south-02").barnLabel, "Barn h-02")
  T.eq("L3 valid multi-byte UTF-8 passes through", rowOf(v, "west-03").barnLabel, "Weide \195\164 Hof")
  T.eq("L4 a nameless placeable reads its id, the ladder's last rung", rowOf(v, "east-04").barnLabel, "east-04")
  T.eq("L5 a bad name never rejects the barn or the farm", #v.rows, 4)
end)

-- ══════════════════════════════════════════════════════════
-- M. MISSION BOUNDARIES, THE OFFICE SALE, A HAUL
-- ══════════════════════════════════════════════════════════
group("M", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  T.eq("M0 recorded", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  mgr:onMissionDelete()
  T.eq("M1 mission delete empties the session map", next(mgr.collectionRefusal.records), nil)
  mgr:onMissionLoaded()
  T.eq("M2 the same process reloads with NOT_RECORDED, the worker still on the rota", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2454/nil")

  -- An office sale from the menu clears through markCollected.
  mgr:assignCollectionWorker("b1", "w1")
  hourTick(m, 1)
  T.eq("M3 refused again", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  setPrice(1.0)
  local removed, status = mgr:sellMilk("b1")
  T.eq("M4 [world] the office sold the milk", tostring(removed) .. "/" .. tostring(status), "500/ok")
  T.eq("M5 an office sale clears the explanation", rowOf(view(mgr), "b1").state, R.ROW_STATES.NONE_RECORDED)

  -- A tanker haul noticed by the passive detector clears too.
  barn._storage.fillLevels[MILK_INDEX] = 400
  barn._station.fillLevels[MILK_NAME] = 400
  setPrice(0.05)
  hourTick(m, 1)
  T.eq("M6 refused with the fresh milk", rowOf(view(mgr), "b1").state, R.ROW_STATES.FEE_EXCEEDS_PRICE)
  barn._storage.fillLevels[MILK_INDEX] = 0
  barn._station.fillLevels[MILK_NAME] = 0
  hourTick(m, 0)
  T.eq("M7 a haul detected from the level clears the explanation", describe(rowOf(view(mgr), "b1")), "NONE_RECORDED/0/nil/2502/nil")
  T.eq("M7b [world] the haul was recorded as a collection", mgr.barns.b1.lastCollectionSource, SRC.hauled)
end)

-- ══════════════════════════════════════════════════════════
-- R. A CONFIRMED REMOVAL
-- ══════════════════════════════════════════════════════════
group("R", function()
  local barn = makeBarn("b1", 1, 500)
  local m, mgr = boot({ barn }, 0.05, 50)
  dueRound(m, mgr, "b1")
  -- Demolished between two discovery passes: the cached handle still answers an
  -- owner, but the placeable system no longer resolves the id, so no row.
  m.placeableSystem.placeables = {}
  local rev0 = mgr.collectionRefusal.revision
  T.eq("R0 a demolished barn gets no row before the next discovery pass, whatever its cached handle says", #view(mgr).rows, 0)
  -- Row 94's window: that first miss moved the revision once, so a client's UNCHANGED
  -- answer cannot hold the row; a second build before the next discovery pass moves nothing.
  local revMiss = mgr.collectionRefusal.revision
  view(mgr)
  T.eq("R0b the first failed live check moved the revision once, the second build not again", (revMiss - rev0) .. "/" .. (mgr.collectionRefusal.revision - revMiss), "1/0")
  local rev = mgr.collectionRefusal.revision
  mgr:discoverBarns()
  T.eq("R1 one miss retains the record and hides the row", tostring(mgr.barns.b1 ~= nil) .. "/" .. tostring(#view(mgr).rows), "true/0")
  T.ok("R1b hiding the barn moved the revision", mgr.collectionRefusal.revision > rev)
  mgr:discoverBarns()
  T.eq("R2 the second miss removes the barn and its explanation", tostring(mgr.barns.b1) .. "/" .. tostring(mgr.collectionRefusal.records.b1), "nil/nil")
end)

-- ══════════════════════════════════════════════════════════
-- K. SORTING AND DETACHMENT
-- ══════════════════════════════════════════════════════════
group("K", function()
  local b2 = makeBarn("b2", 1, 500)
  local b1 = makeBarn("b1", 1, 500)
  local m, mgr = boot({ b2, b1 }, 0.05, 50)
  mgr:assignCollectionWorker("b1", "w1")
  hourTick(m, 1)
  local v = view(mgr)
  T.eq("K1 rows are sorted by stable key whatever the registration order", v.rows[1].barnKey .. "," .. v.rows[2].barnKey, "b1,b2")
  T.eq("K2 the barn with no worker has no next due and no report", describe(rowOf(v, "b2")), "NONE_RECORDED/0/nil/nil/nil")
  v.rows[1].state = "TAMPERED"
  v.rows[1].attemptHours = 1
  local again = view(mgr)
  T.eq("K3 the view is detached: a caller's edit reaches nothing", describe(rowOf(again, "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454/nil")
  T.ok("K4 two calls return distinct tables", again ~= v and again.rows ~= v.rows)
  T.eq("K5 no persistent barn table carries the report", tostring(mgr.barns.b1.collectionRefusal) .. "/" .. tostring(mgr.barns.b1.recordedFarmId), "nil/nil")
  local pub = mgr:getBarnRows()
  local leaked = false
  for _, row in ipairs(pub) do
    for k in pairs(row) do
      if tostring(k):lower():find("refus", 1, true) or k == "attemptHours" then leaked = true end
    end
  end
  T.eq("K6 the public barn rows carry no refusal field", leaked, false)
end)
