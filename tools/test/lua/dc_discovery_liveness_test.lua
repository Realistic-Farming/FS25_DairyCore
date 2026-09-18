-- dc_discovery_liveness_test.lua - saved-barn discovery before placeables exist.
--
-- The own file can restore a barn before the engine has populated placeableSystem.
-- Startup discovery must keep that state quietly pending, while ordinary later
-- discovery retains the established two-miss deletion rule.
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local function newManager()
    local m = DairyCoreManager.new()
    -- These hooks are ancillary to this test's discovery contract. The real
    -- discovery, reconciliation, counter, retry, and row methods still run.
    m._attachStorageListeners = function() end
    m._detachStorageListeners = function() end
    m._refreshMilkBreedBarn = function() end
    m._forgetMilkBreedBarn = function() end
    m.bedrockBound = true
    m.clockBound = true
    m._breedSurfaceNsRegistered = true
    return m
end

local function placeable(id, farmId)
    return {
        spec_husbandryMilk = {},
        getUniqueId = function() return id end,
        getOwnerFarmId = function() return farmId end,
    }
end

local function savedBarn(id, score, fields)
    return {
        barnId = id, farmId = 0, herdHealthScore = score,
        milkQualityTier = "premium", spoilageStatus = "Fresh",
        feedSourceFields = fields or {}, feedDiseaseFlag = false,
        assignedWorkerId = 17,
        lastKnownMilkLevel = {}, lastCollectionLitres = {},
        rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED,
        ritterMode = false,
    }
end

local function missionWith(placeables, networkSync)
    g_currentMission.placeableSystem = { placeables = placeables }
    g_currentMission.networkSync = networkSync
    g_currentMission.stateLedger = nil
    g_currentMission._isServer = true
end

local dirty = { barns = 0, breed = 0, channels = {} }
local networkSync = {
    markDirty = function(_, channel)
        dirty.channels[channel] = (dirty.channels[channel] or 0) + 1
        if channel == DairyConstants.NETWORK.CHANNEL_BARNS then dirty.barns = dirty.barns + 1 end
        if channel == DairyConstants.BREED_SURFACE.NETWORK_MODULE then dirty.breed = dirty.breed + 1 end
    end,
}

-- Saved rows exist while the placeable list is still empty. They remain stateful,
-- unresolved, and hidden from the public surface across repeated startup misses.
missionWith({}, networkSync)
local startup = newManager()
startup.barns.savedMilk = savedBarn("savedMilk", 83, { [17] = true })
startup.barns.otherSaved = savedBarn("otherSaved", 71)
startup:discoverBarns(true)
startup:discoverBarns(true)
T.eq("startup misses retain both saved records", startup:_countBarns(), 2)
T.eq("startup misses report no live barns", startup:_countLiveBarns(), 0)
T.eq("saved score survives startup misses", startup.barns.savedMilk.herdHealthScore, 83)
T.eq("saved feed fields survive startup misses", startup.barns.savedMilk.feedSourceFields[17], true)
T.eq("unresolved saved row is hidden", #startup:getBarnRows(), 0)
startup._discoveryRetries, startup._discoveryTimer = 0, 0
for _ = 1, 21 do startup:update(500) end
T.eq("startup retry cap retains saved records", startup:_countBarns(), 2)
T.eq("startup retry cap retains saved score", startup.barns.savedMilk.herdHealthScore, 83)
startup:discoverBarns()
T.eq("first post-startup miss still retains saved record", startup:_countBarns(), 2)
startup:discoverBarns()
T.eq("second post-startup miss deletes saved record", startup:_countBarns(), 0)

-- Retry uses live barns, not stale saved records, and eventually binds the real
-- owned barn without deleting another unresolved saved record.
missionWith({}, networkSync)
local retries = newManager()
retries.barns.savedMilk = savedBarn("savedMilk", 83, { [17] = true })
retries.barns.otherSaved = savedBarn("otherSaved", 71)
retries:discoverBarns(true)
for _ = 1, 3 do retries:update(500) end
T.eq("retry counter advances in 500 ms steps", retries._discoveryRetries, 3)

g_currentMission.placeableSystem.placeables = { placeable("savedMilk", 2) }
retries:update(500)
T.eq("retry binds the owned milk barn", retries:_countLiveBarns(), 1)
T.eq("bound barn keeps saved state", retries.barns.savedMilk.herdHealthScore, 83)
T.eq("bound barn keeps saved feed fields", retries.barns.savedMilk.feedSourceFields[17], true)
T.eq("rebind preserves saved worker from farm zero", retries.barns.savedMilk.assignedWorkerId, 17)
T.eq("first bind does not delete another unresolved saved barn", retries.barns.otherSaved ~= nil, true)
T.eq("bound farm id is published", retries.barns.savedMilk.farmId, 2)
T.eq("bound barn is visible", #retries:getBarnRows(), 1)
T.eq("visible row keeps farm id in the row", retries:getBarnRows()[1].farmId, 2)
T.eq("visible row carries breed surface farm trust", retries:getBarnRows()[1].breedSurfaceFarmId,
    2)
T.eq("rebound barn clears probe-dead", retries.barns.savedMilk._probeDead, nil)
retries:update(500)
T.eq("unresolved saved barn keeps retry pending after first bind", retries._discoveryRetries, 5)

-- A mission load starts a fresh retry budget. The cap is twenty attempts.
local loaded = newManager()
loaded._discoveryRetries, loaded._discoveryTimer = 19, 499
loaded._bindBedrock = function() end
loaded._loadOwnFile = function() end
loaded._subscribeClock = function() end
loaded._bindActions = function() end
loaded._bindHarvestBus = function() end
loaded._bindMilkBreedMessages = function() end
loaded._logMilkBreedVerify = function() end
missionWith({}, networkSync)
loaded:onMissionLoaded()
T.eq("mission load resets retry counter", loaded._discoveryRetries, 0)
T.eq("mission load resets retry timer", loaded._discoveryTimer, 0)
for _ = 1, 21 do loaded:update(500) end
T.eq("retry cap is twenty", loaded._discoveryRetries, 20)

-- Ordinary discovery retains the two-miss deletion behavior after startup.
local ordinary = newManager()
ordinary.barns.dead = savedBarn("dead", 60)
missionWith({}, networkSync)
ordinary:discoverBarns()
T.eq("ordinary first miss marks unresolved", ordinary.barns.dead._probeDead, true)
ordinary:discoverBarns()
T.eq("ordinary second miss deletes proven dead barn", ordinary.barns.dead, nil)

-- A real rebind, visibility transition, and owner change all dirty the two
-- published channels so connected surfaces do not wait for a daily tick.
local beforeBarnDirty, beforeBreedDirty = dirty.barns, dirty.breed
missionWith({ placeable("dead", 1) }, networkSync)
ordinary:discoverBarns(true)
T.ok("real discovery dirties barn channel", dirty.barns > beforeBarnDirty)
T.ok("real discovery dirties breed channel", dirty.breed > beforeBreedDirty)
local afterRebindBarnDirty, afterRebindBreedDirty = dirty.barns, dirty.breed
ordinary:discoverBarns(true)
T.eq("unchanged discovery does not dirty barn channel", dirty.barns, afterRebindBarnDirty)
T.eq("unchanged discovery does not dirty breed channel", dirty.breed, afterRebindBreedDirty)
g_currentMission.placeableSystem.placeables = {}
ordinary:discoverBarns(true)
T.ok("visibility change dirties barn channel", dirty.barns > afterRebindBarnDirty)
T.ok("visibility change dirties breed channel", dirty.breed > afterRebindBreedDirty)

local beforeOwnerBarnDirty, beforeOwnerBreedDirty = dirty.barns, dirty.breed
ordinary.barns.dead.assignedWorkerId = 42
g_currentMission.placeableSystem.placeables = { placeable("dead", 2) }
ordinary:discoverBarns(true)
T.eq("owner change updates barn owner", ordinary.barns.dead.farmId, 2)
T.eq("owner change resets prior worker", ordinary.barns.dead.assignedWorkerId, nil)
T.ok("owner change dirties barn channel", dirty.barns > beforeOwnerBarnDirty)
T.ok("owner change dirties breed channel", dirty.breed > beforeOwnerBreedDirty)

-- Clients attribute the public breed surface row from their validated mirror.
local client = newManager()
g_currentMission._isServer = false
client.barns.clientBarn = savedBarn("clientBarn", 64)
client.barns.clientBarn.farmId = 0
client.barns.clientBarn._placeable = placeable("clientBarn", 3)
client.breedSurfaceMirrorReady = true
client.breedSurfaceMirror = { byBarn = { clientBarn = { farmId = 3 } } }
local clientRows = client:getBarnRows()
T.eq("client row uses mirrored breed farm attribution", clientRows[1].breedSurfaceFarmId, 3)
