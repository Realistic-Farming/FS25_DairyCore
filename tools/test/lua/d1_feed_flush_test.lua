-- d1_feed_flush_test.lua - D1 CONTAMINATED-FEED RECOVERY FLUSH (the C5 hatch).
--
-- The paid fast-out on the contaminated feed pool: pay to purge a farm's
-- contaminated feed at the locked C5 per-litre rate (0.08/L, the mid of the
-- governed 0.05-0.10 band) times the Economy recovery-hatch curve (neutral 1.0
-- when the spine is absent). The passive daily decay stays the free never-stuck
-- floor. Mirrors the C2 disease-flush shape (ProStaffDiseaseFlush.lua).
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

g_currentMission = {
  _isServer = true,
  missionInfo = { savegameDirectory = "savegame1" },
  environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
  money = {},
}
function g_currentMission:getIsServer() return self._isServer end
local booked = {}
function g_currentMission:addMoney(amount, farmId, _type)
  booked[#booked + 1] = { amount = amount, farmId = farmId }
end
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

-- ── contaminatedFills: only contaminated fills, priced volume = litres x fraction ──
do
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.5, 0.0)   -- 100 L at 0.5 contaminated
  fp:blend(1, "BARLEY", 50, 0.0, 1.0)   -- clean organic fill
  local fills = fp:contaminatedFills(1)
  T.eq('fills.onlyContaminated', #fills, 1)
  T.eq('fills.fillType', fills[1].fillType, "WHEAT")
  T.near('fills.fraction', fills[1].contaminated, 0.5, 1e-9)
  T.near('fills.contaminatedLitres', fills[1].contaminatedLitres, 50.0, 1e-9)
  T.eq('fills.cleanFarmEmpty', #fp:contaminatedFills(2), 0)
end

-- ── purgeContamination: resets the fraction to 0, returns the count ──
do
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.8, 0.0)
  fp:blend(1, "BARLEY", 50, 0.0, 1.0)
  T.eq('purge.count', fp:purgeContamination(1), 1)
  T.near('purge.wheatCleared', fp:getFraction(1, "WHEAT").contaminated, 0.0, 1e-9)
  T.near('purge.barleyUntouched', fp:getFraction(1, "BARLEY").organic, 1.0, 1e-9)
end

-- ── quote: total = sum(floor(contaminatedLitres x 0.08 x mult)), mult neutral 1.0 ──
do
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.5, 0.0)   -- 50 contaminated litres -> floor(4.0) = 4
  fp:blend(1, "CORN", 200, 1.0, 0.0)    -- 200 contaminated litres -> floor(16.0) = 16
  local q = m:feedFlushQuote(1)
  T.eq('quote.mult', q.economyMultiplier, 1.0)
  T.eq('quote.fillCount', #q.fills, 2)
  T.eq('quote.total', q.totalCost, 20)
  T.eq('quote.perFill', q.fills[1].cost + q.fills[2].cost, 20)
end

-- ── doFeedFlush (server): prices, fund-checks, books the fee, purges ──
do
  booked = {}
  g_farmManager = {
    getFarmById = function(_self, farmId) return { farmId = farmId, getBalance = function() return 100000 end } end,
    getFarmByUserId = function() return { farmId = 1 } end,
  }
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.5, 0.0)   -- 50 contaminated litres -> fee 4
  local ok, reason = m:_doFeedFlush(1)
  T.eq('flush.ok', ok, true)
  T.eq('flush.reason', reason, "done")
  T.near('flush.purged', fp:getFraction(1, "WHEAT").contaminated, 0.0, 1e-9)
  T.eq('flush.bookedOnce', #booked, 1)
  T.eq('flush.bookedAmount', booked[1].amount, -4)
  T.eq('flush.bookedFarm', booked[1].farmId, 1)
end

-- ── funds denial: whole flush denied, nothing purged ──
do
  g_farmManager = {
    getFarmById = function(_self, farmId) return { farmId = farmId, getBalance = function() return 0 end } end,
    getFarmByUserId = function() return { farmId = 1 } end,
  }
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.9, 0.0)
  local ok, reason = m:_doFeedFlush(1)
  T.eq('funds.denied', ok, false)
  T.eq('funds.reason', reason, "funds")
  T.ok('funds.notPurged', fp:getFraction(1, "WHEAT").contaminated > 0.8)
end

-- ── none: a clean pool flushes nothing ──
do
  g_farmManager = {
    getFarmById = function(_self, farmId) return { farmId = farmId, getBalance = function() return 100000 end } end,
    getFarmByUserId = function() return { farmId = 1 } end,
  }
  local m = newManager()
  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.0, 1.0)
  local ok, reason = m:_doFeedFlush(1)
  T.eq('none.reason', reason, "none")
  T.eq('none.ok', ok, false)
end

-- ── client: the server-only gate holds ──
do
  g_currentMission._isServer = false
  local m = newManager()
  local ok, reason = m:_doFeedFlush(1)
  T.eq('client.gated', reason, "server_only")
  T.eq('client.ok', ok, false)
  g_currentMission._isServer = true
end

-- ── action binding: FEED_FLUSH is a farm action (adminOnly=false) with the
--    ownership check - a client cannot flush another farm ──
do
  -- Two-step ns so the bench (fengari, Lua 5.3) can run it: `local ns = {
  -- ... function() ns.actions[name] = def end }` is a Lua 5.1 upvalue-ism that
  -- 5.3 resolves as a global.
  local ns = { actions = {} }
  ns.registerAction = function(_self, name, def) ns.actions[name] = def end
  g_farmManager = {
    getFarmById = function(_self, farmId) return { farmId = farmId, getBalance = function() return 100000 end } end,
    getFarmByUserId = function() return { farmId = 1 } end,
  }
  local m = newManager()
  m._getNetworkSync = function() return ns end
  m:_bindActions()
  local def = ns.actions[DairyConstants.FEED_FLUSH.ACTION]
  T.ok('action.registered', def ~= nil)
  T.eq('action.farmAction', def.adminOnly, false)

  local fp = m.feedProvenance
  fp:blend(1, "WHEAT", 100, 0.5, 0.0)
  def.onAction("userA", { farmId = 2 })          -- userA belongs to farm 1
  T.ok('action.foreignRejected', fp:getFraction(1, "WHEAT").contaminated > 0.4)
  def.onAction("userA", { farmId = 1 })          -- own farm flushes
  T.near('action.ownFlushed', fp:getFraction(1, "WHEAT").contaminated, 0.0, 1e-9)
end

T.summary()
