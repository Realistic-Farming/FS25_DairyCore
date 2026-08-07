-- dc13_persistence_sync_test.lua - DC-13, PERSISTENCE AND SYNC.
--
-- The four defects this member shipped with, pinned so they cannot come back. Every
-- one of them was SILENT in game: none raised, none logged, and three of them looked
-- exactly like correct behaviour from the outside.
--
--   * F80 THE SYNC ARRAY SHEARED. `arr[#arr+1] = nil` neither writes a slot nor
--     advances the length, so two structurally-nil fields made every barn record
--     7 or 8 values against a reader stride of 10. One barn applied nothing at all;
--     two put barn A's identifier and numbers into barn B's typed fields. A tenth
--     slot held a table, which the NetworkSync encoding cannot represent and turns
--     into a float32 zero.
--   * F79 THE TICKS WERE UNGATED, so every client re-ran the whole dairy simulation
--     from its own reads and overwrote what the server had just sent it.
--   * F84 CONTRACTS WERE NOT PERSISTED AT ALL without StateLedger, so every save
--     erased the accrued litres, the remaining term and the premium.
--   * F83 THE MYCOTOXIN COUNTDOWN WAS NOT SAVED, so the penalty reloaded without its
--     clock and a single bad feeding became permanent.
--
-- The finish-line condition DC-14 states as a test is the pair at the top: no field
-- on a client is locally computed, AND no field reports another barn's value. The
-- second half exists because the first does not catch a mis-aligned read.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/DairyCoreManager.lua

local NET = DairyConstants.NETWORK
local STRIDE = NET.BARN_STRIDE

-- ── Wire encoding, mirrored from the real one ──────────────
-- RealisticFarmingSyncEvent.writeValue carries bool/int32/float32/string and turns
-- ANYTHING else into a float32 zero after a warning. That last branch is what made
-- slot 10 unrepresentable, so the round trip has to model it rather than assume it.
local INT32_MIN, INT32_MAX = -2147483648, 2147483647
local function wireRoundTrip(v)
  local t = type(v)
  if t == "boolean" or t == "string" then return v end
  if t == "number" then
    if v == v and v ~= math.huge and v ~= -math.huge
       and math.floor(v) == v and v >= INT32_MIN and v <= INT32_MAX then
      return v          -- T_INT, exact
    end
    return v            -- T_FLOAT; every value this member sends is small
  end
  return 0              -- unsupported: warns and writes float32 zero
end

local function asServer(flag) g_currentMission._isServer = flag end

local function newManager()
  return DairyCoreManager.new()
end

local function barn(id, opts)
  opts = opts or {}
  return {
    barnId = id, farmId = 1,
    herdHealthScore = opts.health or 60,
    milkQualityTier = opts.tier or "standard",
    _spoilageTierDrop = opts.drop or 0,
    mycotoxinPenalty = opts.myc or 0,
    mycotoxinDaysLeft = opts.mycDays or 0,
    collectionInterval = opts.interval or 24,
    assignedWorkerId = opts.worker,
    lastCollectionDay = opts.lastCol,
    nextCollectionDue = opts.nextCol,
    spoilageStatus = "Fresh",
    feedSourceFields = opts.fields or {},
  }
end

-- ══════════════════════════════════════════════════════════
-- F80. THE RECORD IS A WHOLE NUMBER OF SLOTS, ALWAYS
-- ══════════════════════════════════════════════════════════

asServer(true)
local server = newManager()
-- Barn A is the DEFAULT shipped state, and it is the shear trigger: assignedWorkerId
-- has no writer anywhere in the mod and lastCollectionDay is never set, so both are
-- nil on every barn in every save until a collection happens.
server.barns["barn_A"] = barn("barn_A", { health = 73.6, fields = { [12] = true, [7] = true } })
server.barns["barn_B"] = barn("barn_B", {
  health = 41.2, tier = "reduced", drop = 2, myc = 18, interval = 36,
  worker = "worker-uuid-9", lastCol = 114, nextCol = 2748.5, fields = { [3] = true },
})

local arr = server:_onWriteBarnState()
T.eq("two barns write exactly two records", #arr, STRIDE * 2)

local sawNil, sawTable = false, false
for i = 1, STRIDE * 2 do
  if arr[i] == nil then sawNil = true end
  if type(arr[i]) == "table" then sawTable = true end
end
T.ok("no nil slot: a nil neither writes nor advances the length", not sawNil)
T.ok("no table slot: the encoder turns a table into float32 zero", not sawTable)

local wire = {}
for i = 1, #arr do wire[i] = wireRoundTrip(arr[i]) end

asServer(false)
local client = newManager()
client.barns["barn_A"] = barn("barn_A")
client.barns["barn_B"] = barn("barn_B")
client:_onReadBarnState(wire)

local a, b = client.barns["barn_A"], client.barns["barn_B"]

-- THE FINISH LINE: no field reports another barn's value.
T.eq("A health is A's, not B's", a.herdHealthScore, 73)
T.eq("B health is B's, not A's", b.herdHealthScore, 41)
T.eq("A tier round-trips", a.milkQualityTier, "standard")
T.eq("B tier round-trips", b.milkQualityTier, "reduced")
T.eq("A spoilage drop", a._spoilageTierDrop, 0)
T.eq("B spoilage drop", b._spoilageTierDrop, 2)
T.eq("A mycotoxin", a.mycotoxinPenalty, 0)
T.eq("B mycotoxin", b.mycotoxinPenalty, 18)
T.eq("A interval", a.collectionInterval, 24)
T.eq("B interval", b.collectionInterval, 36)

-- ABSENCE SURVIVES AS ABSENCE. The sentinel exists so a nil can cross without
-- shortening the record, and it must arrive back as nil rather than as -1.
T.eq("A absent worker decodes back to nil", a.assignedWorkerId, nil)
T.eq("B worker id survives", b.assignedWorkerId, "worker-uuid-9")
T.eq("A absent lastCollectionDay decodes back to nil", a.lastCollectionDay, nil)
T.eq("B lastCollectionDay survives", b.lastCollectionDay, 114)
T.eq("A absent nextCollectionDue decodes back to nil", a.nextCollectionDue, nil)
T.near("B nextCollectionDue survives", b.nextCollectionDue, 2748.5, 0.01)

T.ok("A feed fields rebuild as a set", a.feedSourceFields[7] == true
  and a.feedSourceFields[12] == true and a.feedSourceFields[3] == nil)
T.ok("B feed fields rebuild as a set", b.feedSourceFields[3] == true
  and b.feedSourceFields[7] == nil and b.feedSourceFields[12] == nil)

-- ── One barn applies. Under the old stride the loop never ran at all. ──
asServer(true)
local solo = newManager()
solo.barns["solo"] = barn("solo", { health = 88, tier = "premium" })
local soloArr = solo:_onWriteBarnState()
T.eq("one barn writes exactly one record", #soloArr, STRIDE)

asServer(false)
local soloClient = newManager()
soloClient.barns["solo"] = barn("solo")
soloClient:_onReadBarnState(soloArr)
T.eq("one barn actually applies on the client", soloClient.barns["solo"].herdHealthScore, 88)
T.eq("one barn tier applies", soloClient.barns["solo"].milkQualityTier, "premium")

-- ── A ragged payload is REFUSED, not walked ──
-- 15 values is what two barns produced under the old writer (7 + 8). Applying it can
-- only ever cross-contaminate, so the reader must decline the whole batch and say so.
local warned = false
local origWarning = Logging.warning
Logging.warning = function(...) warned = true end

local victim = newManager()
victim.barns["barn_A"] = barn("barn_A")
victim:_onReadBarnState({ "barn_A", 99, 1, 0, 0, 24, 0, "barn_B", 12, 3, 0, 0, 36, 0, 0 })
T.eq("a ragged payload leaves state untouched", victim.barns["barn_A"].herdHealthScore, 60)
T.ok("and it is said out loud rather than swallowed", warned)

Logging.warning = origWarning

-- ══════════════════════════════════════════════════════════
-- F79. THE TICKS ARE SERVER-GATED
-- ══════════════════════════════════════════════════════════
-- Time Guard fires on ALL peers by deliberate design, so the gate is DairyCore's to
-- apply. A client must still DISCOVER, because placeables are local and a barn built
-- after that client joined has to become visible to the reader, but it must simulate
-- nothing: every simulated field arrives over the barn channel.

local SENTINEL = 999   -- impossible score; only a local recompute would overwrite it

asServer(false)
local peer = newManager()
peer.barns["barn_A"] = barn("barn_A", { health = SENTINEL, tier = "premium", myc = 10, mycDays = 3 })
peer:onDayTick({ monotonicDay = 200 })
T.eq("a client does NOT recompute herd health", peer.barns["barn_A"].herdHealthScore, SENTINEL)
T.eq("a client does NOT decay mycotoxin locally", peer.barns["barn_A"].mycotoxinDaysLeft, 3)

peer.barns["barn_A"].nextCollectionDue = nil
peer:onCollectionHourTick({ monotonicDay = 200 })
T.eq("a client does NOT run the collection schedule", peer.barns["barn_A"].nextCollectionDue, nil)

asServer(true)
local host = newManager()
host.barns["barn_A"] = barn("barn_A", { health = SENTINEL, tier = "premium", myc = 10, mycDays = 3 })
host:onDayTick({ monotonicDay = 200 })
T.ok("the server DOES still simulate", host.barns["barn_A"].herdHealthScore ~= SENTINEL)
T.eq("the server DOES still decay mycotoxin", host.barns["barn_A"].mycotoxinDaysLeft, 2)

host.barns["barn_A"].nextCollectionDue = nil
host:onCollectionHourTick({ monotonicDay = 200 })
T.ok("the server DOES still run the collection schedule",
  host.barns["barn_A"].nextCollectionDue ~= nil)

-- ══════════════════════════════════════════════════════════
-- F84 / F83. THE OWN-FILE PATH, WHICH IS THE ONLY PERSISTENCE
-- WITHOUT STATELEDGER
-- ══════════════════════════════════════════════════════════

-- In-memory XMLFile, faithful to the subset the own-file path uses.
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

local registeredAccruals = {}
g_currentMission.timeGuard = {
  registerAccrual = function(_, id, _) registeredAccruals[id] = true end,
  subscribeTick   = function() end,
}

asServer(true)
local before = newManager()
before.barns["barn_A"] = barn("barn_A", {
  health = 77, myc = 21, mycDays = 4, fields = { [5] = true },
})
before.barns["barn_A"].activeContractId = 1
before.nextContractId = 2
before.contracts[1] = {
  contractId = 1, barnId = "barn_A", farmId = 1, type = "syndicate",
  volumeTarget = 52000, termDays = 60, daysRemaining = 43,
  premiumRate = 1.22, qualityRequired = "standard", delivered = 9137.5, settled = false,
}
before.contracts[2] = {   -- settled: must NOT be resurrected
  contractId = 2, barnId = "barn_A", farmId = 1, type = "standard",
  volumeTarget = 8000, termDays = 30, daysRemaining = 0,
  premiumRate = 1.12, delivered = 8000, settled = true,
}
before:_saveOwnFile()

local after = newManager()
after:_loadOwnFile()
local ab = after.barns["barn_A"]

T.ok("the barn survives the save", ab ~= nil)
T.eq("F83: the mycotoxin penalty survives", ab.mycotoxinPenalty, 21)
T.eq("F83: the mycotoxin COUNTDOWN survives", ab.mycotoxinDaysLeft, 4)
T.eq("the collection interval survives", ab.collectionInterval, 24)
T.eq("an absent lastCollectionDay stays absent", ab.lastCollectionDay, nil)
T.eq("activeContractId survives", ab.activeContractId, 1)
T.ok("feed fields survive", ab.feedSourceFields[5] == true)

-- F83's real consequence, and the only assertion that proves the fix: the penalty
-- has to be able to DECAY again. Before, daysLeft reloaded at zero and the test in
-- _decayMycotoxin was false forever, so one bad feeding was permanent.
after:_decayMycotoxin(ab)
T.eq("F83: the penalty decays after a reload (it was permanent)", ab.mycotoxinDaysLeft, 3)

local c = after.contracts[1]
T.ok("F84: the active contract survives at all", c ~= nil)
T.near("F84: accrued litres survive", c.delivered, 9137.5, 0.01)
T.eq("F84: the remaining term survives", c.daysRemaining, 43)
T.near("F84: the premium survives", c.premiumRate, 1.22, 0.001)
T.eq("F84: the type survives", c.type, "syndicate")
T.eq("F84: the quality requirement survives", c.qualityRequired, "standard")
T.eq("F84: the barn link survives", c.barnId, "barn_A")
T.eq("F84: a settled contract is not resurrected", after.contracts[2], nil)
-- A reloaded contract that is not put back on the accrual survives the save and then
-- never settles or pays, which is a quieter version of the same bug.
T.ok("F84: the reloaded contract goes back on the accrual",
  registeredAccruals["DairyCore_contract_1"] == true)
T.eq("F84: the id counter survives, so no live id is reissued", after.nextContractId, 2)

-- ══════════════════════════════════════════════════════════
-- F75. DISCOVERY IS PER OWNING FARM
-- ══════════════════════════════════════════════════════════
-- On a dedicated server FSBaseMission:getFarmId returns NIL, and the old
-- `mission:getFarmId() or 1` resolved that to a hardcoded 1. Only farm 1's barns were
-- ever discovered; every other farm had no dairy at all and no message saying so.
-- A barn belongs to the farm that OWNS THE PLACEABLE, not to whoever is looking.

FarmManager = {
  SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1,
  GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15,
}

local function placeable(uid, ownerFarmId)
  return {
    spec_husbandryMilk = {},
    getUniqueId    = function() return uid end,
    getOwnerFarmId = function() return ownerFarmId end,
  }
end

-- Records every farm id discovery asks for, so "never hand nil to the engine" is an
-- assertion rather than a hope.
local function makeHusbandrySystem(byFarm)
  local asked = {}
  return {
    asked = asked,
    getPlaceablesByFarm = function(_, farmId)
      asked[#asked + 1] = farmId
      return byFarm[farmId] or {}
    end,
  }, asked
end

local function withFarms(ids)
  local farms = {}
  for _, id in ipairs(ids) do farms[#farms + 1] = { farmId = id } end
  g_farmManager = { getFarms = function() return farms end }
end

-- ── A dedicated server: no local player, so getFarmId returns nil ──
asServer(true)
g_currentMission.getFarmId = function() return nil end
withFarms({ 1, 2, 3 })
local hs, asked = makeHusbandrySystem({
  [1] = { placeable("barn_f1", 1) },
  [2] = { placeable("barn_f2", 2) },
  [3] = { placeable("barn_f3", 3) },
})
g_currentMission.husbandrySystem = hs

local dedi = newManager()
dedi:discoverBarns()

T.ok("F75: farm 1's barn is found", dedi.barns["barn_f1"] ~= nil)
T.ok("F75: farm 2's barn is found, and was invisible before", dedi.barns["barn_f2"] ~= nil)
T.ok("F75: farm 3's barn is found, and was invisible before", dedi.barns["barn_f3"] ~= nil)
T.eq("F75: every real farm was scanned", #asked, 3)

-- Each barn carries ITS OWN owner, not the id of whoever asked.
T.eq("a barn belongs to the farm that owns it (1)", dedi.barns["barn_f1"].farmId, 1)
T.eq("a barn belongs to the farm that owns it (2)", dedi.barns["barn_f2"].farmId, 2)
T.eq("a barn belongs to the farm that owns it (3)", dedi.barns["barn_f3"].farmId, 3)

-- THE CRASH GUARD. getPlaceablesByFarm resolves `farmId or g_localPlayer.farmId`, and
-- g_localPlayer is nil on a dedicated server, so a nil id raises there. The `or 1`
-- that caused the bug also happened to prevent that, and the replacement must too.
local sawNilAsk = false
for _, id in ipairs(asked) do if id == nil then sawNilAsk = true end end
T.ok("F75: never asks the engine for a nil farm", not sawNilAsk)

-- ── Reserved farm ids are not farms ──
withFarms({ 0, 1, 14, 15, 2 })
local hs2, asked2 = makeHusbandrySystem({ [1] = {}, [2] = {} })
g_currentMission.husbandrySystem = hs2
newManager():discoverBarns()
T.eq("spectator, guided-tour and invalid ids are skipped", #asked2, 2)

-- ── No farm manager: fall back to this machine's own farm ──
g_farmManager = nil
g_currentMission.getFarmId = function() return 4 end
local hs3, asked3 = makeHusbandrySystem({ [4] = { placeable("barn_f4", 4) } })
g_currentMission.husbandrySystem = hs3
local fallback = newManager()
fallback:discoverBarns()
T.eq("without a farm manager it scans the local farm", #asked3, 1)
T.eq("and that farm is the local one, not a hardcoded 1", asked3[1], 4)
T.ok("and the barn is still found", fallback.barns["barn_f4"] ~= nil)

-- ── No farm manager AND no local farm: scan nothing, and above all ask nothing ──
g_currentMission.getFarmId = function() return nil end
local hs4, asked4 = makeHusbandrySystem({ [1] = { placeable("barn_ghost", 1) } })
g_currentMission.husbandrySystem = hs4
local blind = newManager()
blind:discoverBarns()
T.eq("with no farm to name, it asks for none rather than guessing 1", #asked4, 0)
T.eq("and discovers nothing rather than another farm's barns", blind.barns["barn_ghost"], nil)

-- ── No per-farm enumerator: take the whole set, read each placeable's own owner ──
g_farmManager = nil
g_currentMission.husbandrySystem = {
  placeables = { placeable("barn_a", 2), placeable("barn_b", 3) },
}
local whole = newManager()
whole:discoverBarns()
T.eq("the whole-set path reads owner 2 off the placeable", whole.barns["barn_a"].farmId, 2)
T.eq("the whole-set path reads owner 3 off the placeable", whole.barns["barn_b"].farmId, 3)

g_currentMission.husbandrySystem = nil
g_currentMission.getFarmId = nil
