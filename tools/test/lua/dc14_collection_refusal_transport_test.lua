-- dc14_collection_refusal_transport_test.lua - DC-14 host slice B: the routes a
-- view travels (SDS v0.9 sections 4, 5 and 8; brief v1.0 sections 4, 5 and 8).
--
-- THE ENTRY-POINT BAR IS GROUP S. Two machines share the process: a server with
-- a dairy barn and a pure client of the same farm. Each manager is built by
-- DairyCoreManager.new() and enters through onMissionLoaded (the session reset,
-- the bedrock binds, the scoped provider's registration on the server, the
-- client's route selection through NetworkSync's capabilities, the farm-change
-- subscription) and the per-frame update. The refusal on the server comes from
-- the real hour tick and RSF-F216's real fee gate. NetworkSync's transport is
-- MODELED to its contract: the model hands the server's real buildView the actor
-- context NetworkSync builds (NetworkSyncScoped.lua:640-648) and hands the
-- client's real applyView the publication NetworkSync assembles (:1077-1088).
-- The DIRECT events travel a typed stream model that checks the layout order,
-- through connections that can deliver chunks out of order or twice. Nothing
-- writes a replica, a route or a row by hand.
--
-- Groups:
--   S  the entry-point bar: NS_SCOPED end to end, FULL then UNCHANGED then FULL
--   D  DIRECT: the round trip, chunking within the budget, out-of-order and
--      duplicate chunks, population mismatch, timeout, retry pacing, the
--      header-only UNAVAILABLE, the rate limit, a malformed request, no broadcast
--   E  the typed layouts on the wire and the byte estimate
--   V  the flat scoped vector is rejected whole on any defect
--   R  one-way failover: no APPLIED in ten visible seconds, TERMINAL, demand gaps
--   W  WAITING_NS: the bounded wait, then NS_SCOPED or DIRECT
--   F  the local farm change: every publisher's argument shape, both stores
--      cleared synchronously, late messages of the old generation ignored
--   G  settings off, PF stand-down, no real farm
--   H  LOCAL_PRODUCER on a listen host, a dedicated server serving a remote farm
--   X  DIRECT integrity, each check alone: a foreign sequence, another farm, a
--      header that disagrees, a repeated index that would still add up, a total the
--      chunks do not reach with headers that agree, a chunk index past the count, a
--      row count the rows disagree with, a timeout under continuous demand
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/MilkTank.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

local MILK_NAME = DairyConstants.CONTRACTS.MILK_FILLTYPE
local MILK_INDEX = 1
local R = DairyConstants.COLLECTION_REFUSAL
local MOD = R.NETWORK_MODULE

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function num(x)
  if type(x) ~= "number" then return tostring(x) end
  local r = math.floor(x * 10000 + 0.5) / 10000
  if r == math.floor(r) then return string.format("%d", math.floor(r)) end
  return tostring(r)
end

-- ── the engine world ────────────────────────────────────────
FarmManager = { MAX_NUM_FARMS = 8, MAX_FARM_ID = 8, SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1,
  GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
MoneyType = { OTHER = 1 }
XMLFile = { loadIfExists = function() return nil end }
MessageType = { PLAYER_FARM_CHANGED = 25 }
function getWorldTranslation(node) return node.x, node.y, node.z end
g_modIsLoaded = {}
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == MILK_NAME then return MILK_INDEX end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
local function setPrice(p) g_fillTypeManager.getFillTypeByIndex = function() return { pricePerLiter = p } end end

-- The message center: subscribe(type, fn, target), unsubscribe(type, target), publish(type, arg).
g_messageCenter = { subs = {} }
function g_messageCenter:subscribe(mt, fn, target) self.subs[#self.subs + 1] = { mt = mt, fn = fn, target = target } end
function g_messageCenter:unsubscribe(mt, target)
  for i = #self.subs, 1, -1 do
    if self.subs[i].mt == mt and self.subs[i].target == target then table.remove(self.subs, i) end
  end
end
function g_messageCenter:unsubscribeAll(target)
  for i = #self.subs, 1, -1 do if self.subs[i].target == target then table.remove(self.subs, i) end end
end
function g_messageCenter:publish(mt, arg)
  for _, s in ipairs(self.subs) do if s.mt == mt then s.fn(s.target, arg) end end
end

-- ── the typed stream: every write is tagged, every read checks the tag ───────
local streamErrors = 0
local function newStream() return { items = {}, pos = 1 } end
local function writer(tag, check)
  return function(s, v)
    if not check(v) then streamErrors = streamErrors + 1 end
    s.items[#s.items + 1] = { tag, v }
  end
end
local function reader(tag)
  return function(s)
    local it = s.items[s.pos]
    s.pos = s.pos + 1
    if it == nil or it[1] ~= tag then error("stream read " .. tag .. " got " .. tostring(it and it[1]), 0) end
    return it[2]
  end
end
local function isInt(lo, hi) return function(v) return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi end end
streamWriteUInt8 = writer("u8", isInt(0, 255));                 streamReadUInt8 = reader("u8")
streamWriteUInt32 = writer("u32", isInt(0, 4294967295));        streamReadUInt32 = reader("u32")
streamWriteInt32 = writer("i32", isInt(-2147483648, 2147483647)); streamReadInt32 = reader("i32")
streamWriteFloat32 = writer("f32", function(v) return type(v) == "number" and v == v end); streamReadFloat32 = reader("f32")
streamWriteBool = writer("bool", function(v) return type(v) == "boolean" end); streamReadBool = reader("bool")
streamWriteString = writer("str", function(v) return type(v) == "string" end); streamReadString = reader("str")

-- ── two machines ──────────────────────────────────────────
local function newMission(isServer, localFarm)
  local ticks = {}
  local m = {
    _isServer = isServer, _localFarm = localFarm,
    missionInfo = { savegameDirectory = "savegame1" },
    missionDynamicInfo = { isMultiplayer = true },
    environment = { currentDay = 100, dayTime = 6 * 3600 * 1000 },
    placeableSystem = { placeables = {} },
    money = {},
    timeGuard = { subscribeTick = function(_, kind, name, fn) ticks[kind] = fn end },
    _ticks = ticks,
    workerCostsManager = { getRosterSnapshot = function()
      return { workers = { { uuid = "w1", lifecycleState = "hired", levelName = "experienced" } } } end },
  }
  function m:getIsServer() return self._isServer end
  -- PlaceableSystem:getPlaceableByUniqueId (decompiled evidence, guarded by the
  -- caller): the placeable currently registered under that id, or nil.
  function m.placeableSystem:getPlaceableByUniqueId(id)
    for _, p in ipairs(self.placeables) do
      if p:getUniqueId() == id then return p end
    end
    return nil
  end
  -- FSBaseMission.lua:1067-1086: a connection names its player's farm on the
  -- server; without one, the local player's farm (nil on a dedicated server).
  function m:getFarmId(connection)
    if connection ~= nil then return connection.farmId end
    return self._localFarm
  end
  function m:addMoney(income, farmId) self.money[#self.money + 1] = { income = income, farmId = farmId } end
  return m
end

local function newNs(caps)
  local ns = { caps = caps or { ready = true, waiting = false }, scoped = {}, registerCalls = 0,
    unregisterCalls = 0, fullRequests = 0, dirty = {}, refuse = false }
  function ns:getScopedCapabilities()
    return { ready = self.caps.ready == true, waiting = self.caps.waiting == true,
      reasonCode = self.caps.ready and "READY" or (self.caps.waiting and "WAITING_MISSION_LOAD" or "NOT_INITIALIZED") }
  end
  function ns:registerScopedModule(modId, spec)
    self.registerCalls = self.registerCalls + 1
    if self.refuse then return false end
    self.scoped[modId] = spec
    return true
  end
  function ns:unregisterScopedModule(modId)
    self.unregisterCalls = self.unregisterCalls + 1
    local had = self.scoped[modId] ~= nil
    self.scoped[modId] = nil
    return had
  end
  function ns:requestScopedFull(modId) self.fullRequests = self.fullRequests + 1 return true end
  function ns:markDirty(modId) self.dirty[modId] = (self.dirty[modId] or 0) + 1 end
  function ns:registerModule() return true end
  function ns:registerAction() return true end
  return ns
end

local function makeBarn(id, owner, litres, opts)
  opts = opts or {}
  local storage = { fillTypes = { [MILK_INDEX] = true }, fillLevels = { [MILK_INDEX] = litres }, listeners = {} }
  function storage:getIsFillTypeSupported(ft) return self.fillTypes[ft] == true end
  function storage:getFillLevel(ft) return self.fillLevels[ft] or 0 end
  function storage:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function storage:removeFillLevelChangedListeners() end
  local station = { fillLevels = { [MILK_NAME] = litres }, listeners = {} }
  function station:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function station:removeFillLevelChangedListeners() end
  local p = { spec_husbandryMilk = {}, spec_husbandry = { storage = storage, unloadingStation = station },
    rootNode = { x = 0, y = 0, z = 0 }, _owner = owner, _name = opts.name or ("Barn " .. id) }
  function p:getUniqueId() return id end
  function p:getOwnerFarmId() return self._owner end
  function p:getName() return self._name end
  function p:removeHusbandryFillLevel(farmId, delta, ft)
    local cur = storage.fillLevels[MILK_INDEX] or 0
    local removed = math.min(delta, cur)
    storage.fillLevels[MILK_INDEX] = cur - removed
    station.fillLevels[MILK_NAME] = cur - removed
    return delta - removed
  end
  p._storage = storage
  return p
end

--- Run fn with this machine's globals in place.
local function on(machine, fn)
  local sm, smgr, sc, ss = g_currentMission, g_dairyCoreManager, g_client, g_server
  g_currentMission, g_dairyCoreManager, g_client, g_server = machine.mission, machine.mgr, machine.client, machine.server
  local ok, err = pcall(fn)
  g_currentMission, g_dairyCoreManager, g_client, g_server = sm, smgr, sc, ss
  if not ok then error(err, 0) end
end

--- A machine: its mission, its NetworkSync (or nil), its manager booted through
--- onMissionLoaded and one frame of update.
local function newMachine(opts)
  local mc = { inbox = {}, broadcasts = 0, deliveryErrors = 0 }
  mc.mission = newMission(opts.isServer == true, opts.localFarm)
  mc.mission.networkSync = opts.ns
  mc.ns = opts.ns
  for _, p in ipairs(opts.placeables or {}) do
    mc.mission.placeableSystem.placeables[#mc.mission.placeableSystem.placeables + 1] = p
  end
  if opts.isServer then
    mc.server = { broadcastEvent = function() mc.broadcasts = mc.broadcasts + 1 end }
  end
  mc.mgr = DairyCoreManager.new()
  mc.mgr.settings.saleFeePer1000L = opts.feePer1000 or DairyConstants.SALE.FEE_PER_1000L
  if opts.settingsOff then mc.mgr.settings.enabled = false end
  on(mc, function()
    if opts.pf then g_modIsLoaded["FS25_precisionFarming"] = true end
    mc.mgr:onMissionLoaded()
    g_modIsLoaded["FS25_precisionFarming"] = nil
    mc.mgr:update(16)
  end)
  return mc
end

--- Wire a client to a server: the server's handle of the client carries the
--- client's farm (what FSBaseMission:getFarmId(connection) answers); the
--- client's handle of the server is the server connection. sendEvent serialises
--- at once into the receiver's inbox; flush delivers in the order asked.
local function link(server, client, clientFarm)
  local clientConn = { isServer = false, farmId = clientFarm }
  local serverConn = { isServer = true }
  local function queue(target, ev, from)
    local s = newStream()
    ev:writeStream(s, nil)
    target.inbox[#target.inbox + 1] = { stream = s, class = getmetatable(ev), from = from }
  end
  function clientConn:getIsServer() return self.isServer end
  function clientConn:sendEvent(ev) queue(client, ev, serverConn) end
  function serverConn:getIsServer() return self.isServer end
  function serverConn:sendEvent(ev) queue(server, ev, clientConn) end
  client.client = { getServerConnection = function() return serverConn end }
  client.serverConn, server.clientConn = serverConn, clientConn
end

--- Deliver queued events to a machine. order: nil (as sent), "reverse", or a
--- list of inbox indices (an index repeated delivers the chunk twice).
local function flush(machine, order)
  local items = machine.inbox
  machine.inbox = {}
  local seq = {}
  if order == "reverse" then
    for i = #items, 1, -1 do seq[#seq + 1] = items[i] end
  elseif type(order) == "table" then
    for _, i in ipairs(order) do seq[#seq + 1] = items[i] end
  else
    seq = items
  end
  local delivered = 0
  for _, it in ipairs(seq) do
    on(machine, function()
      local ok = pcall(function()
        local e = it.class.emptyNew()
        e:readStream({ items = it.stream.items, pos = 1 }, it.from)
      end)
      if ok then delivered = delivered + 1 else machine.deliveryErrors = machine.deliveryErrors + 1 end
    end)
  end
  return delivered, #items
end

local function tick(machine, dt) on(machine, function() machine.mgr:update(dt) end) end
local function pulse(machine, consumer) on(machine, function() machine.mgr:pulseCollectionDemand(consumer or "ESC") end) end
local function view(machine)
  local v
  on(machine, function() v = machine.mgr:getCollectionRefusalViews() end)
  return v
end
local function state(v)
  if v == nil then return "nil" end
  return tostring(v.state) .. "/" .. tostring(v.reason) .. "/" .. tostring(#v.rows)
end
local function rowOf(v, key)
  for _, r in ipairs(v and v.rows or {}) do if r.barnKey == key then return r end end
  return nil
end
local function describe(r)
  if r == nil then return "nil" end
  return tostring(r.state) .. "/" .. tostring(r.code) .. "/" .. num(r.attemptHours) .. "/" .. num(r.nextDueHours)
end
local function route(machine) return machine.mgr.collectionRoute.route end

--- The server's round that falls due: the worker through the real path, the
--- clock through the environment, the hour tick through the captured
--- subscription.
local function serverRound(server, barnId, days)
  on(server, function()
    if barnId ~= nil then server.mgr:assignCollectionWorker(barnId, "w1") end
    server.mission.environment.currentDay = server.mission.environment.currentDay + (days or 1)
    server.mission._ticks.hour({ monotonicDay = server.mission.environment.currentDay })
  end)
end

--- NetworkSync's scoped transport, modeled: the server's real buildView with the
--- context NetworkSync builds, then the client's real applyView with the
--- publication NetworkSync assembles from a FULL result.
local function nsPublish(server, client, opts)
  opts = opts or {}
  local sSpec = server.ns.scoped[MOD]
  local cSpec = client and client.ns and client.ns.scoped[MOD] or nil
  local result, applied
  on(server, function()
    result = sSpec.buildView({ modId = MOD, connectionId = "c1", userId = 7, farmId = opts.farmId,
      actorState = opts.actorState or "RESOLVED", serverSession = "s1", subscriptionId = "1" },
      opts.previous, opts.forceFull == true)
  end)
  if opts.apply ~= false and cSpec ~= nil and result.state == "READY" and result.mode == "FULL" then
    on(client, function()
      applied = cSpec.applyView({ modId = MOD, subscriptionId = "1", serverSession = "s1", viewEpoch = "1",
        publicationId = "1", state = "READY", mode = "FULL", dataRevision = result.dataRevision, values = result.values })
    end)
  end
  return result, applied
end

-- ══════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: NS_SCOPED END TO END
-- ══════════════════════════════════════════════════════════
group("S", function()
  setPrice(0.05)
  local barn = makeBarn("b1", 2, 500)
  local server = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = { barn }, feePer1000 = 50 })
  local client = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, client, 2)
  T.ok("S1 [reached] the server registered the scoped provider at mission load, under its own id",
    server.mgr.collectionRoute.nsRegistered == true and server.ns.scoped[MOD] ~= nil and route(server) == "LOCAL_PRODUCER")
  T.eq("S2 [reached] the pure client selected NS_SCOPED through the capabilities and its own registration", route(client) .. "/" .. tostring(client.ns.registerCalls), "NS_SCOPED/1")
  T.eq("S3 before any snapshot the client is updating, never no-report", state(view(client)), "WAITING/FIRST_SNAPSHOT/0")
  pulse(client, "ESC")
  T.eq("S4 the first visible pulse with no usable replica requests one scoped full, once", client.ns.fullRequests, 1)

  serverRound(server, "b1", 1)
  T.eq("S5 [world] the server's real round refused with milk in the barn", tostring(server.mgr.collectionRefusal.records.b1.state), "FEE_EXCEEDS_PRICE")
  local result, applied = nsPublish(server, client, { farmId = 2 })
  T.eq("S6 the producer answers READY FULL with the exact scalar layout", tostring(result.state) .. "/" .. tostring(result.mode) .. "/" .. tostring(#result.values), "READY/FULL/10")
  T.eq("S7 the consumer returns NetworkSync's exact APPLIED shape", tostring(applied.outcome) .. "/" .. tostring(applied.dataRevision == result.dataRevision), "APPLIED/true")
  local v = view(client)
  T.eq("S8 the client's getter reads the replica of its own farm", state(v) .. " " .. describe(rowOf(v, "b1")), "READY/nil/1 FEE_EXCEEDS_PRICE/1/2430/2454")
  pulse(client, "ESC")
  T.eq("S9 a later pulse with a usable replica requests nothing", client.ns.fullRequests, 1)

  local again = nsPublish(server, client, { farmId = 2, previous = { viewKey = result.viewKey, viewEpoch = "1", dataRevision = result.dataRevision } })
  T.eq("S10 nothing changed: the producer answers UNCHANGED against the previous revision", tostring(again.mode) .. "/" .. tostring(again.values), "UNCHANGED/nil")

  setPrice(1.0)
  serverRound(server, nil, 1)
  T.ok("S11 the ordinary sale marked the scoped module dirty", (server.ns.dirty[MOD] or 0) >= 1)
  local third, applied3 = nsPublish(server, client, { farmId = 2, previous = { viewKey = result.viewKey, viewEpoch = "1", dataRevision = result.dataRevision } })
  T.eq("S12 the revision moved, so the next publication is FULL again", third.mode, "FULL")
  T.eq("S13 the client shows the cleared explanation", describe(rowOf(view(client), "b1")), "NONE_RECORDED/0/nil/2478")
  T.eq("S14 [world] nothing was sent to the server by a stream-zero event: the scoped path carries it", #server.inbox, 0)
  T.eq("S15 another farm's actor gets a READY view of its own with no barn of farm 2", (function()
    local r = nsPublish(server, client, { farmId = 3, apply = false })
    return tostring(r.state) .. "/" .. tostring(r.values[3])
  end)(), "READY/0")
  T.eq("S16 a spectator actor is denied", nsPublish(server, client, { farmId = 0, actorState = "SPECTATOR", apply = false }).state, "DENIED")
  -- Row 94's window, coupled as Iris's answer 7 requires: the barn is demolished between
  -- two discovery passes (the cached handle still answers, the placeable system no longer
  -- resolves it). The producer builds the rows, whose first failed live check moves the
  -- revision, BEFORE it reads dataRevision, so the row's removal and the changed revision
  -- are one produced view: FULL without the row, never UNCHANGED against the last one.
  server.mission.placeableSystem.placeables = {}
  local gone, applied4 = nsPublish(server, client, { farmId = 2, previous = { viewKey = third.viewKey, viewEpoch = "1", dataRevision = third.dataRevision } })
  T.eq("S17 the first build after the demolition answers FULL with the row gone and a new revision, not UNCHANGED", tostring(gone.mode) .. "/" .. tostring(gone.values and gone.values[3]) .. "/" .. tostring(gone.dataRevision ~= third.dataRevision), "FULL/0/true")
  T.eq("S18 the client applied it and its getter no longer shows the demolished barn", tostring(applied4 and applied4.outcome) .. "/" .. #view(client).rows, "APPLIED/0")
end)

-- ══════════════════════════════════════════════════════════
-- D. DIRECT
-- ══════════════════════════════════════════════════════════
group("D", function()
  setPrice(0.05)
  local barn = makeBarn("b1", 2, 500)
  local server = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = { barn }, feePer1000 = 50 })
  local client = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(server, client, 2)
  T.eq("D1 with no scoped service the pure client selects DIRECT", route(client), "DIRECT")
  T.eq("D2 before any request the client is updating", state(view(client)), "WAITING/FIRST_SNAPSHOT/0")
  serverRound(server, "b1", 1)
  pulse(client, "ESC")
  T.eq("D3 the first visible pulse sends one request carrying no farm, barn or result", #server.inbox, 1)
  T.eq("D3b the outstanding request is the client's own generation and sequence",
    tostring(client.mgr.collectionRoute.directOutstanding.sequence) .. "/" .. tostring(client.mgr.collectionRoute.directOutstanding.generation), "1/1")
  local d = flush(server)
  T.eq("D4 the server answered the requesting connection alone and never broadcast", tostring(#client.inbox) .. "/" .. tostring(server.broadcasts), "1/0")
  flush(client)
  local v = view(client)
  T.eq("D5 the DIRECT replica is applied atomically and read through the getter", state(v) .. " " .. describe(rowOf(v, "b1")), "READY/nil/1 FEE_EXCEEDS_PRICE/1/2430/2454")
  T.eq("D5b no stream error on the typed layout", streamErrors, 0)

  -- Retry pacing: pulses keep coming; a second request only after five seconds.
  pulse(client, "ESC")
  T.eq("D6 a pulse right after a reply sends no second request", #server.inbox, 0)
  tick(client, 5000)
  pulse(client, "ESC")
  T.eq("D7 five real seconds later a pulse refreshes with one request", #server.inbox, 1)
  flush(server); flush(client)
  T.eq("D7b the refreshed replica still reads", state(view(client)), "READY/nil/1")

  -- Timeout: an outstanding request with no reply for ten seconds.
  tick(client, 5000)
  pulse(client, "ESC")
  server.inbox = {}   -- the request is lost
  tick(client, 10000)
  T.eq("D8 a ten-second timeout clears the usable status to UNAVAILABLE/TRANSPORT_TIMEOUT", state(view(client)), "UNAVAILABLE/TRANSPORT_TIMEOUT/0")
  pulse(client, "ESC")
  flush(server); flush(client)
  T.eq("D9 a later pulse retries and recovers", state(view(client)), "READY/nil/1")

  -- Many barns: more than one chunk within the real budget, every row reachable.
  local many = {}
  for i = 1, 260 do many[#many + 1] = makeBarn(string.format("barn-%03d", i), 2, 0, { name = "Dairy barn number " .. i }) end
  local big = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = many })
  local bigClient = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(big, bigClient, 2)
  pulse(bigClient, "ESC")
  flush(big)
  local chunks = #bigClient.inbox
  T.ok("D10 260 barns need more than one chunk under the 8192-byte budget", chunks >= 2)
  local firstStream = bigClient.inbox[1].stream
  local bytes = 0
  for _, it in ipairs(firstStream.items) do
    local tag = it[1]
    bytes = bytes + (tag == "u8" and 1 or tag == "bool" and 1 or tag == "str" and (2 + #it[2]) or 4)
  end
  T.ok("D10b a chunk's typed size stays within the budget", bytes <= R.DIRECT_BUDGET_BYTES)
  flush(bigClient, "reverse")
  T.eq("D11 chunks delivered out of order still assemble every row", #view(bigClient).rows, 260)
  T.eq("D11b the assembled rows are in stable-key order", view(bigClient).rows[1].barnKey .. "/" .. view(bigClient).rows[260].barnKey, "barn-001/barn-260")

  -- A repeated chunk index discards the whole staging set.
  tick(bigClient, 5000)
  pulse(bigClient, "ESC")
  flush(big)
  local order = { 1 }
  for i = 1, chunks do order[#order + 1] = i end
  flush(bigClient, order)
  T.eq("D12 a duplicate chunk index rejects the whole snapshot", state(view(bigClient)), "UNAVAILABLE/TRANSPORT_ERROR/0")
  T.eq("D12b nothing is staged after the rejection", tostring(bigClient.mgr.collectionRoute.directStaging), "nil")

  -- A population mismatch: a chunk whose header claims more rows than arrive.
  tick(bigClient, 5000)
  pulse(bigClient, "ESC")
  flush(big)
  local tampered = bigClient.inbox[1].stream
  for _, it in ipairs(tampered.items) do if it[1] == "i32" and it[2] == 260 then it[2] = 261 break end end
  flush(bigClient)
  T.eq("D13 a total that the chunks do not add up to rejects the whole snapshot", state(view(bigClient)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- The server cannot resolve the connection's farm: header-only UNAVAILABLE.
  local c2 = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(server, c2, nil)
  pulse(c2, "ESC")
  flush(server)
  local reply = c2.inbox[1]
  local codes = {}
  for _, it in ipairs(reply.stream.items) do if it[1] == "u8" then codes[#codes + 1] = it[2] end end
  T.eq("D14 the server answers a farmless connection with one header-only UNAVAILABLE chunk (schema, state 1, farm 0)", table.concat(codes, ","), "1,1,0")
  flush(c2)
  T.eq("D14b the client reads it as UNAVAILABLE/TRANSPORT_ERROR", state(view(c2)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- The rate limit: nine requests in one real second, eight answered.
  local c3 = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(server, c3, 2)
  for i = 1, 9 do
    on(c3, function() c3.mgr:_collectionDirectRequest() end)
  end
  flush(server)
  T.eq("D15 the server answers at most eight requests per connection per second", #c3.inbox, 8)
  tick(server, 1000)
  on(c3, function() c3.mgr:_collectionDirectRequest() end)
  c3.inbox = {}
  flush(server)
  T.eq("D15b the next second admits again", #c3.inbox, 1)

  -- A malformed request is ignored without a reply.
  c3.inbox = {}
  on(c3, function()
    local ev = DairyCollectionStatusRequestEvent.new(1, "", 1)
    ev.valid = true   -- a forged flag; the server validates the wire fields itself
    c3.serverConn:sendEvent(ev)
  end)
  flush(server)
  T.eq("D16 a request with an empty view token gets no reply", #c3.inbox, 0)
  on(c3, function()
    local ev = DairyCollectionStatusRequestEvent.new(1, "v1", 0)
    ev.valid = true
    c3.serverConn:sendEvent(ev)
  end)
  flush(server)
  T.eq("D16b a sequence outside 1..2147483647 gets no reply", #c3.inbox, 0)

  -- Settings off on the server: header-only UNAVAILABLE.
  server.mgr.settings.enabled = false
  tick(server, 1000)
  on(c3, function() c3.mgr:_collectionDirectRequest() end)
  flush(server)
  codes = {}
  for _, it in ipairs(c3.inbox[1].stream.items) do if it[1] == "u8" then codes[#codes + 1] = it[2] end end
  T.eq("D17 a server with Dairy switched off answers header-only UNAVAILABLE", table.concat(codes, ","), "1,1,0")
  server.mgr.settings.enabled = true

  -- A response from a non-server connection is refused.
  local stray = { isServer = false, getIsServer = function(self) return self.isServer end }
  on(client, function()
    client.mgr._collectionDirectRequest(client.mgr)
    local st = client.mgr.collectionRoute
    local ev = DairyCollectionStatusResponseEvent.new({ routeGeneration = st.generation, viewGeneration = st.viewGeneration,
      requestSequence = st.sequence, stateCode = 0, farmIdOr0 = 2, totalRowCount = 0, chunkIndex = 0, chunkCount = 1, chunkRowCount = 0 }, {})
    ev:run(stray)
  end)
  T.eq("D18 a chunk from a connection that is not the server is refused", tostring(client.mgr.collectionRoute.directOutstanding ~= nil), "true")
end)

-- ══════════════════════════════════════════════════════════
-- E. THE TYPED LAYOUTS
-- ══════════════════════════════════════════════════════════
group("E", function()
  local req = DairyCollectionStatusRequestEvent.new(7, "v1-3", 42)
  local s = newStream()
  req:writeStream(s, nil)
  local tags = {}
  for _, it in ipairs(s.items) do tags[#tags + 1] = it[1] end
  T.eq("E1 the request layout is uint8, uint32, string, uint32", table.concat(tags, ","), "u8,u32,str,u32")
  local back = DairyCollectionStatusRequestEvent.emptyNew()
  local ranOn = nil
  back.run = function(self, connection) ranOn = connection end
  back:readStream({ items = s.items, pos = 1 }, "conn")
  T.eq("E2 the request reads back its fields and runs exactly once from readStream", tostring(back.routeGeneration) .. "/" .. back.viewGeneration .. "/" .. tostring(back.requestSequence) .. "/" .. tostring(back.valid) .. "/" .. tostring(ranOn), "7/v1-3/42/true/conn")

  local header = { routeGeneration = 7, viewGeneration = "v1-3", requestSequence = 42, stateCode = 0, farmIdOr0 = 2,
    totalRowCount = 2, chunkIndex = 0, chunkCount = 1, chunkRowCount = 2 }
  local rows = {
    { barnKey = "a", barnLabel = "A", code = 1, hasAttempt = true, attemptHours = 2430, hasNextDue = true, nextDueHours = 2454 },
    { barnKey = "b", barnLabel = "B", code = 0, hasAttempt = false, attemptHours = 0, hasNextDue = false, nextDueHours = 0 },
  }
  local res = DairyCollectionStatusResponseEvent.new(header, rows)
  s = newStream()
  res:writeStream(s, nil)
  tags = {}
  for _, it in ipairs(s.items) do tags[#tags + 1] = it[1] end
  T.eq("E3 the response layout is the fixed header then the seven typed row fields",
    table.concat(tags, ","), "u8,u32,str,u32,u8,u8,i32,i32,i32,i32,str,str,u8,bool,f32,bool,f32,str,str,u8,bool,f32,bool,f32")
  T.eq("E4 the byte estimate is the typed sum", DairyCollectionStatusResponseEvent.estimateBytes("v1-3", rows), 29 + 4 + (3 + 3 + 11) + (3 + 3 + 11))
  local back2 = DairyCollectionStatusResponseEvent.emptyNew()
  back2.run = function() end
  back2:readStream({ items = s.items, pos = 1 }, nil)
  T.eq("E5 the response reads back valid with its rows", tostring(back2.valid) .. "/" .. tostring(#back2.rows) .. "/" .. back2.rows[1].barnKey, "true/2/a")
  T.eq("E6 a fee row without an attempt is invalid", tostring(DairyCollectionStatusResponseEvent.validateRow({ barnKey = "a", barnLabel = "A", code = 1, hasAttempt = false, attemptHours = 0, hasNextDue = false, nextDueHours = 0 })), "false")
  T.eq("E7 an UNAVAILABLE chunk must be header-only, farm 0, one chunk", tostring(DairyCollectionStatusResponseEvent.new({ routeGeneration = 1, viewGeneration = "v", requestSequence = 1, stateCode = 1, farmIdOr0 = 2, totalRowCount = 0, chunkIndex = 0, chunkCount = 1, chunkRowCount = 0 }, {}).valid), "false")
  T.eq("E8 a READY farm with zero barns is exactly one zero-row chunk", tostring(DairyCollectionStatusResponseEvent.new({ routeGeneration = 1, viewGeneration = "v", requestSequence = 1, stateCode = 0, farmIdOr0 = 2, totalRowCount = 0, chunkIndex = 0, chunkCount = 2, chunkRowCount = 0 }, {}).valid), "false")
end)

-- ══════════════════════════════════════════════════════════
-- V. THE FLAT SCOPED VECTOR IS REJECTED WHOLE
-- ══════════════════════════════════════════════════════════
group("V", function()
  local client = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  local spec = client.ns.scoped[MOD]
  local function apply(values)
    local out
    on(client, function() out = spec.applyView({ modId = MOD, serverSession = "s1", viewEpoch = "1", state = "READY", mode = "FULL", dataRevision = "r1", values = values }) end)
    client.mgr.collectionRoute.nsFatal = false
    return tostring(out.outcome) .. "/" .. tostring(out.reason)
  end
  local good = { 1, 2, 1, "b1", "Barn", 1, true, 2430, true, 2454 }
  T.eq("V1 a valid vector applies", apply(good), "APPLIED/nil")
  T.eq("V2 the wrong farm is RETRYABLE, never applied", apply({ 1, 3, 1, "b1", "Barn", 1, true, 2430, true, 2454 }), "RETRYABLE/FARM")
  T.eq("V3 a truncated vector is TERMINAL", apply({ 1, 2, 1, "b1", "Barn", 1, true, 2430, true }), "TERMINAL/MALFORMED_LENGTH")
  T.eq("V4 a duplicate key is TERMINAL", apply({ 1, 2, 2, "b1", "Barn", 0, false, 0, false, 0, "b1", "Barn", 0, false, 0, false, 0 }), "TERMINAL/MALFORMED_DUPLICATE")
  T.eq("V5 a fee code without an attempt is TERMINAL", apply({ 1, 2, 1, "b1", "Barn", 1, false, 0, false, 0 }), "TERMINAL/MALFORMED_ATTEMPT")
  T.eq("V6 a no-report row carrying an attempt is TERMINAL", apply({ 1, 2, 1, "b1", "Barn", 0, true, 5, false, 0 }), "TERMINAL/MALFORMED_ATTEMPT")
  T.eq("V7 an unknown code is TERMINAL", apply({ 1, 2, 1, "b1", "Barn", 3, false, 0, false, 0 }), "TERMINAL/MALFORMED_CODE")
  T.eq("V8 a label over 128 bytes is TERMINAL", apply({ 1, 2, 1, "b1", string.rep("x", 129), 0, false, 0, false, 0 }), "TERMINAL/MALFORMED_LABEL")
  T.eq("V9 a non-boolean flag is TERMINAL", apply({ 1, 2, 1, "b1", "Barn", 0, 0, 0, false, 0 }), "TERMINAL/MALFORMED_FLAG")
  T.eq("V10 a DELTA publication is TERMINAL: this version is FULL or UNCHANGED only", (function()
    local out
    on(client, function() out = spec.applyView({ mode = "DELTA", dataRevision = "r2", baseRevision = "r1", values = {} }) end)
    client.mgr.collectionRoute.nsFatal = false
    return tostring(out.outcome)
  end)(), "TERMINAL")
  T.eq("V11 the replica after the rejections is still the valid one", describe(rowOf(view(client), "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454")
end)

-- ══════════════════════════════════════════════════════════
-- R. ONE-WAY FAILOVER
-- ══════════════════════════════════════════════════════════
group("R", function()
  local server = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = { makeBarn("b1", 2, 500) } })
  local client = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, client, 2)
  T.eq("R1 NS_SCOPED selected", route(client), "NS_SCOPED")
  -- Visible demand with no APPLIED for ten seconds: pulses every second.
  for _ = 1, 10 do pulse(client, "ESC") tick(client, 1000) end
  T.eq("R2 ten visible seconds without a replica move the endpoint to DIRECT, once", route(client) .. "/" .. tostring(client.ns.unregisterCalls) .. "/" .. tostring(client.mgr.collectionRoute.generation), "DIRECT/1/2")
  T.eq("R3 the scoped full was requested exactly once for that activation", client.ns.fullRequests, 1)
  client.ns.caps = { ready = true, waiting = false }
  tick(client, 1000)
  pulse(client, "ESC")
  T.eq("R4 the scoped service coming back never switches the route back", route(client), "DIRECT")
  T.eq("R5 DIRECT begins on the next visible demand", #server.inbox, 1)
  flush(server); flush(client)
  T.eq("R6 the DIRECT replica serves the view", state(view(client)), "READY/nil/1")
  T.eq("R7 a late scoped clear touches no DIRECT store", (function()
    on(client, function() client.ns.scoped[MOD] = nil end)
    local spec = client.mgr:_collectionScopedSpec()
    on(client, function() spec.clearView("MODULE_UNREGISTERED") end)
    return state(view(client))
  end)(), "READY/nil/1")

  -- Hidden time does not advance the clock, and a demand gap cancels it.
  local c2 = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, c2, 2)
  pulse(c2, "ESC")
  tick(c2, 12000)
  T.eq("R8 twelve seconds with no pulses keep NS_SCOPED: the clock ran only while demand was visible", route(c2), "NS_SCOPED")
  pulse(c2, "ESC")
  T.eq("R9 a fresh activation requests the scoped full again", c2.ns.fullRequests, 2)

  -- TERMINAL from a malformed publication fails over on the next frame.
  local c3 = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, c3, 2)
  on(c3, function() c3.ns.scoped[MOD].applyView({ mode = "FULL", dataRevision = "r1", values = { 1, 2, 9 } }) end)
  tick(c3, 16)
  T.eq("R10 a TERMINAL apply latches fatal recovery: DIRECT on the next frame", route(c3) .. "/" .. tostring(c3.ns.unregisterCalls), "DIRECT/1")

  -- An ordinary NEW_GENERATION clear re-arms instead of failing over.
  local c4 = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, c4, 2)
  pulse(c4, "ESC")
  nsPublish(server, c4, { farmId = 2 })
  T.eq("R11 replica applied", state(view(c4)), "READY/nil/1")
  on(c4, function() c4.ns.scoped[MOD].clearView("NEW_GENERATION") end)
  tick(c4, 16)
  T.eq("R12 a NEW_GENERATION clear drops the replica and keeps NS_SCOPED", route(c4) .. " " .. state(view(c4)), "NS_SCOPED WAITING/FIRST_SNAPSHOT/0")
  pulse(c4, "ESC")
  T.eq("R13 the next visible pulse requests a scoped full again", c4.ns.fullRequests, 2)
  on(c4, function() c4.ns.scoped[MOD].clearView("RECOVERY_BUDGET") end)
  tick(c4, 16)
  T.eq("R14 any other clear reason latches fatal recovery", route(c4), "DIRECT")
end)

-- ══════════════════════════════════════════════════════════
-- W. WAITING_NS
-- ══════════════════════════════════════════════════════════
group("W", function()
  local client = newMachine({ isServer = false, localFarm = 2, ns = newNs({ ready = false, waiting = true }) })
  T.eq("W1 a waiting scoped service keeps WAITING_NS and paints updating", route(client) .. " " .. state(view(client)), "WAITING_NS WAITING/NS_READY_WAIT/0")
  pulse(client, "ESC")
  T.eq("W2 no fallback request is sent while waiting", tostring(client.mgr.collectionRoute.directOutstanding), "nil")
  tick(client, 5000)
  client.ns.caps = { ready = true, waiting = false }
  tick(client, 16)
  T.eq("W3 the service becoming ready within the bound selects NS_SCOPED", route(client), "NS_SCOPED")

  local c2 = newMachine({ isServer = false, localFarm = 2, ns = newNs({ ready = false, waiting = true }) })
  tick(c2, 10000)
  T.eq("W4 ten real seconds of waiting select DIRECT", route(c2), "DIRECT")

  local c3 = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  c3.ns.refuse = true
  c3.mgr.collectionRoute.route = "UNRESOLVED"
  tick(c3, 16)
  T.eq("W5 a refused registration selects DIRECT", route(c3), "DIRECT")
end)

-- ══════════════════════════════════════════════════════════
-- F. THE LOCAL FARM CHANGE
-- ══════════════════════════════════════════════════════════
group("F", function()
  setPrice(0.05)
  local server = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = { makeBarn("b1", 2, 500), makeBarn("b2", 3, 500) }, feePer1000 = 50 })
  local client = newMachine({ isServer = false, localFarm = 2, ns = newNs() })
  link(server, client, 2)
  serverRound(server, "b1", 1)
  pulse(client, "ESC")
  nsPublish(server, client, { farmId = 2 })
  T.eq("F1 the replica shows farm 2's barn", state(view(client)), "READY/nil/1")
  local cleared = {}
  client.mgr:addCollectionViewListener(function(reason) cleared[#cleared + 1] = reason end)

  -- Another player's switch: PlayerSetFarmEvent.lua:40 publishes a Player table.
  on(client, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, { farmId = 5, userId = 9 }) end)
  T.eq("F2 another player's switch clears nothing", state(view(client)) .. "/" .. tostring(#cleared), "READY/nil/1/0")

  -- The local player's switch to farm 3, published with each shape the engine uses.
  client.mission._localFarm = 3
  server.clientConn.farmId = 3
  on(client, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, { farmId = 3, userId = 1 }) end)
  T.eq("F3 the local switch clears the store synchronously and the listener ran inside the callback", state(view(client)) .. "/" .. tostring(cleared[1]) .. "/" .. tostring(client.mgr.collectionRoute.generation), "WAITING/FIRST_SNAPSHOT/0/FARM_CHANGED/2")
  on(client, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, nil) end)
  T.eq("F4 the same farm published again (PlayerSwitchedFarmEvent's shape, or nil) clears nothing more", #cleared, 1)

  -- A late publication for the old farm is refused; the new farm's applies.
  local res = nsPublish(server, client, { farmId = 2, apply = false })
  local outcome
  on(client, function() outcome = client.ns.scoped[MOD].applyView({ mode = "FULL", dataRevision = res.dataRevision, values = res.values }) end)
  T.eq("F5 the old farm's late publication is RETRYABLE and not shown", tostring(outcome.outcome) .. " " .. state(view(client)), "RETRYABLE WAITING/FIRST_SNAPSHOT/0")
  nsPublish(server, client, { farmId = 3 })
  T.eq("F6 the new farm's own snapshot shows its own barn", tostring(rowOf(view(client), "b2") ~= nil) .. "/" .. tostring(rowOf(view(client), "b1")), "true/nil")

  -- The same on DIRECT: a response of the old generation is ignored.
  local d = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(server, d, 2)
  pulse(d, "ESC")
  flush(server)
  d.mission._localFarm = 3
  server.clientConn.farmId = 3
  on(d, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, { farmId = 3 }) end)
  flush(d)
  T.eq("F7 a DIRECT reply of the previous generation is ignored after the switch", state(view(d)), "WAITING/FIRST_SNAPSHOT/0")
  tick(d, 5000)
  pulse(d, "ESC")
  flush(server); flush(d)
  T.eq("F8 the next request is the new generation and shows farm 3", tostring(d.mgr.collectionRoute.generation) .. " " .. tostring(rowOf(view(d), "b2") ~= nil), "2 true")
end)

-- ══════════════════════════════════════════════════════════
-- G. SETTINGS OFF, PF STAND-DOWN, NO REAL FARM
-- ══════════════════════════════════════════════════════════
group("G", function()
  local off = newMachine({ isServer = false, localFarm = 2, ns = newNs(), settingsOff = true })
  T.eq("G1 settings off: UNAVAILABLE/SETTINGS_OFF, no route selected, nothing registered", state(view(off)) .. "/" .. route(off) .. "/" .. tostring(off.ns.registerCalls), "UNAVAILABLE/SETTINGS_OFF/0/UNRESOLVED/0")
  off.mgr.settings.enabled = true
  tick(off, 16)
  T.eq("G2 re-enabling selects", route(off), "NS_SCOPED")

  local pf = newMachine({ isServer = true, localFarm = 1, ns = newNs(), pf = true })
  T.eq("G3 PF stand-down: no surface and no scoped registration", tostring(view(pf)) .. "/" .. tostring(pf.ns.registerCalls), "nil/0")

  local spectator = newMachine({ isServer = false, localFarm = 0, ns = nil })
  pulse(spectator, "ESC")
  T.eq("G4 a spectator gets NO_REAL_FARM before route selection and sends nothing", state(view(spectator)) .. "/" .. tostring(spectator.mgr.collectionRoute.directOutstanding), "UNAVAILABLE/NO_REAL_FARM/0/nil")
end)

-- ══════════════════════════════════════════════════════════
-- H. LOCAL_PRODUCER AND THE DEDICATED SERVER
-- ══════════════════════════════════════════════════════════
group("H", function()
  setPrice(0.05)
  local host = newMachine({ isServer = true, localFarm = 2, ns = newNs(), placeables = { makeBarn("b1", 2, 500) }, feePer1000 = 50 })
  serverRound(host, "b1", 1)
  pulse(host, "ESC")
  T.eq("H1 a listen host reads its own producer and sends nothing", route(host) .. " " .. state(view(host)) .. "/" .. tostring(host.mgr.collectionRoute.directOutstanding), "LOCAL_PRODUCER READY/nil/1/nil")
  host.mission._localFarm = 0
  T.eq("H2 a listen host spectator is NO_REAL_FARM, still LOCAL_PRODUCER", state(view(host)) .. "/" .. route(host), "UNAVAILABLE/NO_REAL_FARM/0/LOCAL_PRODUCER")

  local dedi = newMachine({ isServer = true, localFarm = nil, ns = newNs(), placeables = { makeBarn("b1", 2, 500) }, feePer1000 = 50 })
  serverRound(dedi, "b1", 1)
  T.eq("H3 a dedicated server exposes no local view", state(view(dedi)), "UNAVAILABLE/NO_REAL_FARM/0")
  T.ok("H4 but registers the scoped provider", dedi.mgr.collectionRoute.nsRegistered == true)
  local remote = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(dedi, remote, 2)
  pulse(remote, "ESC")
  flush(dedi); flush(remote)
  T.eq("H5 and serves a remote client its own farm over DIRECT", describe(rowOf(view(remote), "b1")), "FEE_EXCEEDS_PRICE/1/2430/2454")
  T.eq("H6 mission delete unregisters and unsubscribes", (function()
    on(dedi, function() dedi.mgr:onMissionDelete() end)
    local subs = 0
    for _, s in ipairs(g_messageCenter.subs) do if s.target == dedi.mgr then subs = subs + 1 end end
    return tostring(dedi.ns.unregisterCalls) .. "/" .. tostring(subs)
  end)(), "1/0")
end)

-- ═══════════════════════════════════════════════════
-- X. DIRECT INTEGRITY, EACH CHECK ALONE
-- ═══════════════════════════════════════════════════
-- The D rows above prove the outcomes; here each guard is isolated so that removing
-- any one of them changes a row (the first battery run found five of them masking
-- one another).
group("X", function()
  setPrice(0.05)
  local barn = makeBarn("b1", 2, 500)
  local server = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = { barn }, feePer1000 = 50 })
  local client = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(server, client, 2)
  serverRound(server, "b1", 1)
  --- The n-th item of a tag in a queued reply's typed stream.
  local function item(stream, tag, n)
    local k = 0
    for _, it in ipairs(stream.items) do
      if it[1] == tag then k = k + 1 if k == n then return it end end
    end
    return nil
  end
  local function request(c) tick(c, 5000) pulse(c, "ESC") flush(server) end

  -- A reply whose sequence is not the outstanding one: ignored, the request stands.
  request(client)
  item(client.inbox[1].stream, "u32", 2)[2] = 99
  flush(client)
  T.eq("X1 a reply of another sequence is ignored: not staged, not applied, the request still outstanding",
    state(view(client)) .. "/" .. tostring(client.mgr.collectionRoute.directOutstanding ~= nil) .. "/" .. tostring(client.mgr.collectionRoute.directStaging), "WAITING/FIRST_SNAPSHOT/0/true/nil")

  -- A reply for another farm: discarded.
  request(client)
  item(client.inbox[1].stream, "u8", 3)[2] = 3
  flush(client)
  T.eq("X2 a reply for another farm is discarded", state(view(client)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- A chunk index past the chunk count: invalid on the wire, discarded as malformed.
  request(client)
  item(client.inbox[1].stream, "i32", 2)[2] = 1
  flush(client)
  T.eq("X3 a chunk index past the chunk count is refused on the wire", state(view(client)) .. "/" .. tostring(client.mgr.collectionRoute.directError), "UNAVAILABLE/TRANSPORT_ERROR/0/MALFORMED")

  -- A row count the stream does not carry: the reader reads exactly chunkRowCount rows,
  -- so the stream faults, the event never runs, and the request stands (the in-memory
  -- row-count check is reachable only from a server that builds the header wrong).
  request(client)
  item(client.inbox[1].stream, "i32", 4)[2] = 2
  local errs0 = client.deliveryErrors
  flush(client)
  T.eq("X4 a header claiming more rows than the stream carries faults the stream: the event never runs, nothing is discarded, the request stands",
    state(view(client)) .. "/" .. tostring(client.deliveryErrors - errs0) .. "/" .. tostring(client.mgr.collectionRoute.directOutstanding ~= nil), "WAITING/FIRST_SNAPSHOT/0/1/true")
  client.inbox = {}

  -- Many barns, so every chunk check has more than one chunk to disagree with.
  local many = {}
  for i = 1, 260 do many[#many + 1] = makeBarn(string.format("barn-%03d", i), 2, 0, { name = "Dairy barn number " .. i }) end
  local big = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = many })
  local bc = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(big, bc, 2)
  local function bigRequest() tick(bc, 5000) pulse(bc, "ESC") flush(big) return #bc.inbox end

  -- Headers that disagree: only the second chunk's total is wrong, so the staged total
  -- (the first chunk's) still matches the rows that arrive; only the header check sees it.
  local n = bigRequest()
  item(bc.inbox[2].stream, "i32", 1)[2] = 261
  flush(bc)
  T.eq("X5 a chunk whose header disagrees with the staged one discards the snapshot", state(view(bc)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- A repeated index in place of a missing one: the row total still adds up when the
  -- two chunks are the same size. The chunking is byte-budgeted, so a world whose keys
  -- and labels are all the same length makes every full chunk the same size; 700 rows
  -- give at least three full chunks under the byte budget.
  local same = {}
  for i = 1, 700 do same[#same + 1] = makeBarn(string.format("barn-%03d", i), 2, 0, { name = string.format("Same size label %03d", i) }) end
  local eq = newMachine({ isServer = true, localFarm = 1, ns = newNs(), placeables = same })
  local ec = newMachine({ isServer = false, localFarm = 2, ns = nil })
  link(eq, ec, 2)
  tick(ec, 5000) pulse(ec, "ESC") flush(eq)
  local m = #ec.inbox
  local r1, r2 = item(ec.inbox[1].stream, "i32", 4)[2], item(ec.inbox[2].stream, "i32", 4)[2]
  T.eq("X6 [world] the first two chunks are the same size, so the first repeated in place of the second still adds up", tostring(m >= 3) .. "/" .. tostring(r1 == r2), "true/true")
  local order = { 1, 1 }
  for i = 3, m do order[#order + 1] = i end
  flush(ec, order)
  T.eq("X7 and the repeated index alone discards the snapshot", state(view(ec)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- A total the chunks do not reach, with every header agreeing: only the population check sees it.
  n = bigRequest()
  for i = 1, n do item(bc.inbox[i].stream, "i32", 1)[2] = 261 end
  flush(bc)
  T.eq("X8 a total the chunks do not add up to, with headers that agree, discards the snapshot", state(view(bc)), "UNAVAILABLE/TRANSPORT_ERROR/0")

  -- A timeout under continuous demand: the retry keeps the usable replica until the
  -- request times out, and the timeout must clear it, not leave a stale READY.
  n = bigRequest()
  flush(bc)
  T.eq("X9 [world] a usable replica", state(view(bc)), "READY/nil/260")
  for _ = 1, 11 do tick(bc, 500) pulse(bc, "ESC") end
  big.inbox = {}   -- the retry request is lost
  T.eq("X10 [world] the retry under continuous demand kept the replica showing", state(view(bc)) .. "/" .. tostring(bc.mgr.collectionRoute.directOutstanding ~= nil), "READY/nil/260/true")
  for _ = 1, 21 do tick(bc, 500) pulse(bc, "ESC") big.inbox = {} end
  T.eq("X11 the timeout clears the stale replica: UNAVAILABLE/TRANSPORT_TIMEOUT, never a READY nobody refreshed", state(view(bc)), "UNAVAILABLE/TRANSPORT_TIMEOUT/0")
end)
