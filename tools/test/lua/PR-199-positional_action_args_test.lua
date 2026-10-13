-- PR-199-positional_action_args_test.lua
--
-- PLAYER-REPORTS row 199 (keyed args), the DairyCore half: the feed flush sent a keyed
-- table, and NetworkSync's action event writes args[1..#args], which for a keyed table
-- is nothing; the server's handler bailed on the nil and a joined client's flush did
-- nothing. A host never saw it (requestAction applies in memory). The sender now sends
-- a positional array, the handler reads args[1] as a positive number, and the three
-- latent handlers (sell milk, assign and unassign the rota) read the documented order.
--
-- THE ENTRY-POINT BAR DRIVES THE REAL TRANSPORT: a pure client's requestAction, then the
-- real RealisticFarmingActionEvent:writeStream into readStream on the server, then run,
-- then NetworkSync:_applyAction, then the handler DairyCore registered. The transport is
-- FS25_NetworkSync's own code, verbatim at 9e599be (tools/test/lua/networksync_fixture).
-- No row hands a table to a handler. The world is engine state (users, farms with a
-- balance, a money book); the feed provenance is written by the real blend and the
-- real flush.
--
--!load: tools/test/lua/networksync_fixture/engine_stubs.lua, tools/test/lua/networksync_fixture/Logger.lua, tools/test/lua/networksync_fixture/RealisticFarmingSyncEvent.lua, tools/test/lua/networksync_fixture/NetworkSync.lua, src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

local WARN = {}
DCLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
DCLogger.info = function() end
DCLogger.debug = function() end
NSLogger.warning = function() end
NSLogger.debug = function() end
NSLogger.error = function(fmt, ...) WARN[#WARN + 1] = "NS " .. string.format(fmt, ...) end
MoneyType = MoneyType or { OTHER = 1 }
g_modIsLoaded = g_modIsLoaded or {}
g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
    getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function warned(needle)
    local n = 0
    for _, l in ipairs(WARN) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ── engine state ────────────────────────────────────────────────────────────
-- Users: 1 is an admin in farm 1, 2 a member of farm 2, 3 a spectator (farm 0, as
-- FarmManager:getFarmByUserId answers for a user in no farm, FarmManager.lua:201).
local function user(id, farmId, master)
    return { id = id, farmId = farmId, master = master == true,
        getId = function(self) return self.id end,
        getIsMasterUser = function(self) return self.master end,
        getNickname = function(self) return "user" .. self.id end }
end
local USERS = { [1] = user(1, 1, true), [2] = user(2, 2, false), [3] = user(3, 0, false) }
local function conn(u) return { user = u } end
local FROM_ADMIN1, FROM_MEMBER2, FROM_SPECTATOR, UNPLAYERED = conn(USERS[1]), conn(USERS[2]), conn(USERS[3]), conn(nil)

local W = {}
--- The server world: NetworkSync's core with DairyCore's actions bound to it, users,
--- farms with money, a money book; contaminated feed on farms 1 and 2.
local function serverWorld()
    W.booked, W.sent, W.sold, W.assigned, W.unassigned = {}, {}, {}, {}, {}
    W.nsServer = NetworkSync.new()
    g_currentMission = {
        _isServer = true, getIsServer = function(self) return self._isServer end,
        getFarmId = function() return 1 end,
        missionInfo = { savegameDirectory = "savegame1" },
        environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
        userManager = { getUserByConnection = function(_, c) return c and c.user or nil end },
        addMoney = function(_, amount, farmId) W.booked[#W.booked + 1] = { amount = amount, farmId = farmId } end,
        networkSync = W.nsServer,
    }
    g_networkSync = W.nsServer
    g_server = { broadcastEvent = function() end }
    g_client = nil
    g_farmManager = {
        getFarmById = function(_, id) return { farmId = id, getBalance = function() return 100000 end } end,
        getFarmByUserId = function(_, userId) local u = USERS[userId] if u == nil then return nil end return { farmId = u.farmId } end,
    }
    local ms = DairyCoreManager.new()
    ms.disabled = false
    ms._markBarnsDirty = function() end
    ms:_bindActions()
    ms.feedProvenance:blend(1, "WHEAT", 100, 0.5, 0.0)
    ms.feedProvenance:blend(2, "WHEAT", 100, 0.5, 0.0)
    -- The three latent handlers' targets record what they were handed (the subject
    -- is the argument plumbing, not the milk sale or the rota).
    ms.sellMilk = function(_, barnId, quantity) W.sold[#W.sold + 1] = { barnId, quantity } end
    ms.assignCollectionWorker = function(_, barnId, workerId) W.assigned[#W.assigned + 1] = { barnId, workerId } end
    ms.unassignCollectionWorker = function(_, barnId) W.unassigned[#W.unassigned + 1] = barnId end
    W.ms = ms
    return ms
end
--- A pure client of farm `farmId`: its own NetworkSync core and manager; what it
--- sends is recorded.
local function asClient(farmId, fn)
    local nsClient = NetworkSync.new()
    local mission = { _isServer = false, getIsServer = function(self) return self._isServer end,
                      getFarmId = function() return farmId end, networkSync = nsClient,
                      missionInfo = { savegameDirectory = "savegame1" }, environment = { currentDay = 100, dayTime = 0 } }
    local saved = { g_currentMission, g_networkSync, g_server, g_client }
    g_currentMission, g_networkSync, g_server = mission, nsClient, nil
    g_client = { getServerConnection = function() return { sendEvent = function(_, ev) W.sent[#W.sent + 1] = ev end } end }
    local mc = DairyCoreManager.new()
    mc.disabled = false
    mc._markBarnsDirty = function() end
    local ok, err = pcall(fn, mc)
    g_currentMission, g_networkSync, g_server, g_client = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err, 0) end
end
--- The engine's delivery: the sender's writeStream, the server's readStream (which
--- runs, applies through NetworkSync and reaches the handler).
local function deliver(ev, connection)
    local s = NewTypedStream()
    ev:writeStream(s, nil)
    local rx = RealisticFarmingActionEvent.emptyNew()
    rx:readStream(s, connection)
    return rx, TypedStreamFaults(s)
end
local function contaminated(farmId) return W.ms.feedProvenance:getFraction(farmId, "WHEAT").contaminated end
local function booked()
    local out = {}
    for _, b in ipairs(W.booked) do out[#out + 1] = b.farmId .. ":" .. tostring(b.amount < 0) end
    return table.concat(out, ",")
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE WIRE CARRIES THE FARM
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    serverWorld()
    asClient(1, function(mc) mc:requestFeedFlush(1) end)
    local ev = W.sent[1]
    T.eq("A1 a client's feed flush sends one action event whose args are a positional array of one farm id",
        #W.sent .. "/" .. tostring(ev and ev.actionId) .. "/" .. tostring(ev and #ev.args) .. "/" .. tostring(ev and ev.args[1]), "1/" .. DairyConstants.FEED_FLUSH.ACTION .. "/1/1")
    local s = NewTypedStream()
    ev:writeStream(s, nil)
    streamReadString(s)
    local n = streamReadInt32(s)
    T.eq("A2 the transport writes that one value (a keyed table wrote none)", n .. "/" .. tostring(RealisticFarmingSyncEvent.readValue(s)) .. "/" .. TypedStreamFaults(s), "1/1/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE FLUSH THROUGH THE REAL TRANSPORT
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    serverWorld()
    asClient(1, function(mc) mc:requestFeedFlush(1) end)
    local _, faults = deliver(W.sent[1], FROM_ADMIN1)
    T.eq("B1 a member flushing its own farm: the contamination is purged and its farm is charged once",
        tostring(contaminated(1)) .. "/" .. booked() .. "/" .. faults, "0/1:true/0")
    asClient(2, function(mc) mc:requestFeedFlush(2) end)
    deliver(W.sent[2], FROM_ADMIN1)
    T.eq("B2 a member of farm 1 naming farm 2 is refused: nothing purged, nothing charged, the refusal logged",
        tostring(contaminated(2)) .. "/" .. #W.booked .. "/" .. warned("FEED_FLUSH rejected"), "0.5/1/1")
    -- A spectator's own door refuses farm 0 before sending (resolveFarmId names no real
    -- farm), so the server's refusal is pinned with the forged request such a client
    -- could still craft.
    local sentBefore = #W.sent
    asClient(0, function(mc) mc:requestFeedFlush(0) end)
    deliver(RealisticFarmingActionEvent.new(DairyConstants.FEED_FLUSH.ACTION, { 0 }), FROM_SPECTATOR)
    T.eq("B3 a spectator's door sends nothing for farm 0, and a forged 0 is refused on the server before the ownership equality could pass",
        (#W.sent - sentBefore) .. "/" .. #W.booked .. "/" .. tostring(W.ms.feedFlushGuard == nil or W.ms.feedFlushGuard[0] == nil), "0/1/true")
    asClient(2, function(mc) mc:requestFeedFlush(2) end)
    deliver(W.sent[3], UNPLAYERED)
    T.eq("B4 a connection with no user is refused", tostring(contaminated(2)) .. "/" .. #W.booked, "0.5/1")
    W.ms:requestFeedFlush(2)
    T.eq("B5 the host's own path is unchanged: applied in memory, no event", tostring(contaminated(2)) .. "/" .. booked() .. "/" .. #W.sent, "0/1:true,2:true/3")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE THREE LATENT HANDLERS READ THE DOCUMENTED ORDER
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    serverWorld()
    deliver(RealisticFarmingActionEvent.new(DairyConstants.ACTIONS.SELL_MILK, { "b7", 250 }), FROM_ADMIN1)
    deliver(RealisticFarmingActionEvent.new(DairyConstants.ACTIONS.ASSIGN_ROTA, { "b7", "worker-9" }), FROM_ADMIN1)
    deliver(RealisticFarmingActionEvent.new(DairyConstants.ACTIONS.UNASSIGN_ROTA, { "b7" }), FROM_ADMIN1)
    T.eq("C1 sell milk, assign and unassign the rota reach their targets with the documented positional order (barnId, quantity / barnId, workerId / barnId)",
        tostring(W.sold[1] and W.sold[1][1]) .. "," .. tostring(W.sold[1] and W.sold[1][2]) .. "/" .. tostring(W.assigned[1] and W.assigned[1][1]) .. "," .. tostring(W.assigned[1] and W.assigned[1][2]) .. "/" .. tostring(W.unassigned[1]),
        "b7,250/b7,worker-9/b7")
    deliver(RealisticFarmingActionEvent.new(DairyConstants.ACTIONS.SELL_MILK, { "b7", 250 }), FROM_MEMBER2)
    T.eq("C2 the three stay admin-gated: a non-admin's sale is denied by NetworkSync", #W.sold, 1)
    deliver(RealisticFarmingActionEvent.new(DairyConstants.ACTIONS.SELL_MILK, {}), FROM_ADMIN1)
    T.eq("C3 an empty array (what a keyed sender would produce) reaches no target", #W.sold, 1)
end)

T.summary()
