-- dc14_read_contract_test.lua - DC-14 THE DAIRY READ CONTRACT.
--
-- The published row must never present a default as a fact. Every field marks
-- which machine produced it (server / local / unknown), the transport now carries
-- the fields a client would otherwise guess at, the contract publishes keys not
-- English display text, and a row is a claim the thing it describes still exists.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/DairyCoreManager.lua

local MILK = DairyConstants.CONTRACTS.MILK_FILLTYPE
local TRUST = DairyConstants.TRUST
local CP = DairyConstants.CONTRACT_PROGRESS
local ROTA = DairyConstants.COLLECTION.ROTA_STATES

-- Engine mock
g_currentMission = {
  _isServer = true,
  missionInfo = { savegameDirectory = "savegame1" },
  environment = { currentDay = 100, dayTime = 12 * 3600 * 1000 },
  money = {},
}
function g_currentMission:getIsServer() return self._isServer end
function g_currentMission:addMoney() end
MoneyType = { OTHER = 1 }
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == "MILK" then return 1 end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
g_server = {}
g_modIsLoaded = {}

local function makePlaceable(opts)
  opts = opts or {}
  return {
    spec_husbandry = { unloadingStation = { fillLevels = {} } },
    getNumOfAnimals = function() return opts.cows or 0 end,
    getHusbandryFillLevel = function() return opts.level or 0 end,
    getHusbandryCapacity = function() return opts.cap or 1000 end,
    getOwnerFarmId = function() return opts.owner or 1 end,
  }
end

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

local function barnState(over)
  local b = {
    barnId = "b1", farmId = 1,
    herdHealthScore = 73, milkQualityTier = "standard",
    _spoilageTierDrop = 0, mycotoxinPenalty = 0,
    collectionInterval = 24, assignedWorkerId = nil,
    lastCollectionDay = nil, nextCollectionDue = nil, feedSourceFields = {},
    spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key,
    activeContractId = nil, rotaState = ROTA.UNASSIGNED,
    feedDiseaseFlag = false, feedDiseaseCropName = nil, feedDiseaseSeverity = 0,
    lastCollectionHours = nil, lastCollectionSource = nil, lastCollectionLitres = {},
  }
  for k, v in pairs(over or {}) do b[k] = v end
  return b
end

-- ==========================================================
-- THE THREE-STATE MARKING
-- ==========================================================

-- On the server everything is the server's own book.
local m = newManager()
local b = m:_getOrCreateBarn("b1", 3, makePlaceable({ owner = 3 }))
m.barns["b1"] = barnState({ barnId = "b1", farmId = 3 })
m.barns["b1"]._placeable = makePlaceable({ owner = 3 })
local rows = m:getBarnRows()
T.eq("the server publishes the row", #rows, 1)
T.eq("server: herdHealth is server-marked", rows[1].trust.herdHealth, TRUST.SERVER)
T.eq("server: spoilage is server-marked", rows[1].trust.spoilage, TRUST.SERVER)
T.eq("server: farmId is server-marked", rows[1].trust.farmId, TRUST.SERVER)
T.eq("server: the farm is on the row", rows[1].farmId, 3)

-- On a client, a record that has NOT received the wire is all unknown except the
-- identity and the locally-read farmId.
local m2 = newManager()
g_currentMission._isServer = false
local b2 = m2:_getOrCreateBarn("b2", 5, makePlaceable({ owner = 5 }))
m2.barns["b2"] = barnState({ barnId = "b2", farmId = 5 })
m2.barns["b2"]._placeable = makePlaceable({ owner = 5 })
local rows2 = m2:getBarnRows()
T.eq("client (pre-wire): herdHealth is unknown", rows2[1].trust.herdHealth, TRUST.UNKNOWN)
T.eq("client (pre-wire): spoilage is unknown", rows2[1].trust.spoilage, TRUST.UNKNOWN)
T.eq("client (pre-wire): farmId is local (placeable read)", rows2[1].trust.farmId, TRUST.LOCAL)
T.eq("client (pre-wire): barnId is always server", rows2[1].trust.barnId, TRUST.SERVER)

-- ==========================================================
-- THE TRANSPORT CARRIES THE CONTRACT (22-slot record, two barns, no shear)
-- DC-13's finish line: no field reports another barn's value.
-- ==========================================================

local server = newManager()
g_currentMission._isServer = true
local pa = makePlaceable({ owner = 1, level = 1000, cap = 1000 })   -- full store
local pb = makePlaceable({ owner = 2, level = 100, cap = 1000 })    -- not full
local ba = server:_getOrCreateBarn("barnA", 1, pa)
local bb = server:_getOrCreateBarn("barnB", 2, pb)
ba.lastCollectionDay = 90; ba.lastCollectionHours = 2160; ba.spoilageStatus = "ageing"
ba.activeContractId = 7
ba.feedDiseaseFlag = true; ba.feedDiseaseSeverity = 44; ba.feedDiseaseCropName = "FUSARIUM"
ba.rotaState = ROTA.ASSIGNED_OK
bb.spoilageStatus = "fresh"

local arr = server:_onWriteBarnState()
T.eq("two barns write two full records", #arr, DairyConstants.NETWORK.BARN_STRIDE * 2)

-- A client receives the wire and every carried field flips to server-marked.
local client = newManager()
g_currentMission._isServer = false
client.barns["barnA"] = { barnId = "barnA", farmId = 0, feedSourceFields = {} }
client.barns["barnB"] = { barnId = "barnB", farmId = 0, feedSourceFields = {} }
client:_onReadBarnState(arr)

local ca = client.barns["barnA"]
T.eq("wire: activeContractId arrives", ca.activeContractId, 7)
T.eq("wire: the spoilage key arrives", ca.spoilageStatus, "ageing")
T.eq("wire: storeFull arrives as the server saw it", ca.storeFull, true)
T.eq("wire: farmId arrives", ca.farmId, 1)
T.eq("wire: the feed flag arrives", ca.feedDiseaseFlag, true)
T.eq("wire: the feed severity arrives", ca.feedDiseaseSeverity, 44)
T.eq("wire: the gated crop name arrives", ca.feedDiseaseCropName, "FUSARIUM")
T.eq("wire: the rota state arrives", ca.rotaState, ROTA.ASSIGNED_OK)
T.eq("wire: barn B was not sheared into barn A", client.barns["barnB"].spoilageStatus, "fresh")
T.eq("wire: barn A's health is not barn B's", client.barns["barnA"].herdHealthScore, ba.herdHealthScore)

local crow = client:getBarnRows()
T.eq("client (post-wire): herdHealth is server-marked", crow[1].trust.herdHealth, TRUST.SERVER)
T.eq("client (post-wire): spoilage is server-marked", crow[1].trust.spoilage, TRUST.SERVER)
T.eq("client (post-wire): storeFull is server-marked", crow[1].trust.storeFull, TRUST.SERVER)
T.eq("client (post-wire): farmId stays local", crow[1].trust.farmId, TRUST.LOCAL)

-- ==========================================================
-- THE CONTRACT CARRIES KEYS, NOT ENGLISH DISPLAY TEXT
-- ==========================================================

local m3 = newManager()
g_currentMission._isServer = true
local b3 = m3:_getOrCreateBarn("b3", 1, makePlaceable({ owner = 1 }))
b3.herdHealthScore = 90
b3.milkQualityTier = "premium"
b3.spoilageStatus = "condemned"
b3._spoilageTierDrop = 99
local rows3 = m3:getBarnRows()
-- The row publishes the EFFECTIVE tier (premium dropped to poor by the spoilage
-- penalty), as its KEY, never the English display text.
T.eq("qualityTier publishes the effective tier KEY", rows3[1].qualityTier, "poor")
T.eq("spoilage publishes the KEY, not Condemned", rows3[1].spoilage, "condemned")

-- ==========================================================
-- STORE-FULL SIGNAL (server side, from the husbandry API)
-- ==========================================================

local m4 = newManager()
g_currentMission._isServer = true
local fullBarn = m4:_getOrCreateBarn("full", 1, makePlaceable({ level = 1000, cap = 1000 }))
local emptyBarn = m4:_getOrCreateBarn("empty", 1, makePlaceable({ level = 100, cap = 1000 }))
T.eq("a store at capacity reads full", m4:_storeFull(fullBarn), true)
T.eq("a store with room reads not full", m4:_storeFull(emptyBarn), false)
T.eq("a barn with no placeable reads not full", m4:_storeFull({}), false)

-- ==========================================================
-- THE CONTRACT PROGRESS BAND
-- ==========================================================

local m5 = newManager()
local b5 = m5:_getOrCreateBarn("b5", 1, makePlaceable({ owner = 1 }))
T.eq("no active contract reads none", m5:_contractProgress(b5), CP.NONE)

-- On track: early in the term, delivered already ahead of position.
b5.activeContractId = 1
m5.contracts[1] = { contractId = 1, barnId = "b5", delivered = 1000, volumeTarget = 8000,
  termDays = 30, daysRemaining = 28, settled = false }
T.eq("delivered ahead of position reads on track", m5:_contractProgress(b5), CP.ON_TRACK)

-- Behind: delivered well behind the term position but still plausible. Half the
-- term is gone (expected 0.5) and 3000 of 8000 L are delivered (actual 0.375),
-- which is between ON_TRACK_TOL and BEHIND_TOL under the position.
m5.contracts[1].delivered = 3000
m5.contracts[1].daysRemaining = 15
T.eq("slipping reads behind", m5:_contractProgress(b5), CP.BEHIND)

-- Will not make it: far behind with little term left.
m5.contracts[1].delivered = 100
m5.contracts[1].daysRemaining = 5
T.eq("hopelessly behind reads will not make", m5:_contractProgress(b5), CP.WILL_NOT_MAKE)

-- A settled contract reads none.
m5.contracts[1].settled = true
T.eq("a settled contract reads none", m5:_contractProgress(b5), CP.NONE)

-- ==========================================================
-- THE FEED SIGNAL: FLAG + SEVERITY + THE REVEAL GATE
-- ==========================================================

local m6 = newManager()
local b6 = m6:_getOrCreateBarn("b6", 1, makePlaceable({ owner = 1 }))
b6.feedSourceFields = { [12] = true }
m6._getFieldInfo = function()
  return { activeDisease = "FUSARIUM", diseaseDiscovered = false, diseasePressure = 60 }
end
m6:_refreshFeedDiseaseFlag(b6)
T.eq("an undiscovered disease flags the barn", b6.feedDiseaseFlag, true)
T.eq("an undiscovered disease hides the name", b6.feedDiseaseCropName, nil)
T.eq("the severity crosses ungated", b6.feedDiseaseSeverity, 60)

m6._getFieldInfo = function()
  return { activeDisease = "FUSARIUM", diseaseDiscovered = true, diseasePressure = 60 }
end
m6:_refreshFeedDiseaseFlag(b6)
T.eq("a discovered disease reveals the name", b6.feedDiseaseCropName, "FUSARIUM")

-- ==========================================================
-- A ROW IS A CLAIM THE THING STILL EXISTS
-- ==========================================================

local m7 = newManager()
g_currentMission._isServer = true
m7.barns["live"] = barnState({ barnId = "live" })
m7.barns["ghost"] = barnState({ barnId = "ghost" })
m7.barns["ghost"]._probeDead = true
local rows7 = m7:getBarnRows()
T.eq("a live barn is published", #rows7, 1)
T.eq("and it is the live one", rows7[1].barnId, "live")

-- ==========================================================
-- THE DC-13 FINISH LINE SURVIVES THE LONGER RECORD: A MISALIGNED PAYLOAD IS REFUSED
-- ==========================================================

local m8 = newManager()
g_currentMission._isServer = false
local captured = nil
DCLogger.warning = function(...) captured = table.concat({ ... }, " ") end
m8.barns["victim"] = { barnId = "victim", farmId = 1, feedSourceFields = {} }
-- 15 values against the 22-value record: not a whole number of records.
m8:_onReadBarnState({ "victim", 99, 1, 0, 0, 24, 0, 99, 0, 0, 0, 0, "fresh", 0, 1 })
T.ok("a misaligned payload is refused", captured ~= nil and captured:find("not a multiple"))
T.eq("and the victim keeps its own values", m8.barns["victim"].herdHealthScore, nil)

T.summary()
