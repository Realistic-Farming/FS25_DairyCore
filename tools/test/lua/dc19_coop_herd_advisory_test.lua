-- dc19_coop_herd_advisory_test.lua - DC-19 / RSF-F166 THE CO-OP HERD ADVISORY
-- (DAIRYCORE HALF).
--
-- The advisory is a read of state that already exists, gated by ProStaff's
-- hasHerdAdvisory flag (L12, delivered on the ProStaffCoOp side). DairyCore
-- admits a farm, admits each barn, and publishes detached fact rows. It never
-- writes, moves money or applies economics.
--
-- RSF-F166 CHANGED THE CONTRACT this file tests. Before it, the getter returned
-- English sentences, accepted a nil farm and walked every barn on the map, and
-- admitted any barn whose own farmId was nil for any requested farm. It now
-- returns row tables of semantic codes for exactly one admitted farm.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua

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

-- THE PLACEABLE SYSTEM IS PART OF ADMISSION NOW, so it is modelled rather than
-- absent. Every barn that should be admitted needs a placeable registered here
-- whose getOwnerFarmId agrees with the barn record; that agreement is the check.
local placeables = {}
g_currentMission.placeableSystem = {
  getPlaceableByUniqueId = function(_, id) return placeables[id] end,
}
-- UNSET is how a fixture says "this field is absent", and it exists because the
-- obvious way does not work: `{ farmId = nil }` in a table literal stores nothing,
-- pairs() never visits the key, and the override silently does not happen. The
-- first draft of this file did exactly that and six rows went red reporting that
-- production admitted a nil-owner barn. Production was right; the fixture had
-- never removed the field. A fixture that cannot express the state it claims to
-- test is worse than no row, because it reads as coverage.
local UNSET = setmetatable({}, { __tostring = function() return "<unset>" end })
local function merge(base, over)
  for k, v in pairs(over or {}) do
    if v == UNSET then base[k] = nil else base[k] = v end
  end
  return base
end

local function placeable(over)
  local p = { _owner = 1 }
  p.getOwnerFarmId = function(self) return self._owner end
  return merge(p, over)
end

-- The stand-down line is part of the contract, so it is captured rather than
-- swallowed. An empty result and an announced stand-down look identical from the
-- return value, which is the entire reason the line exists.
local warnings = {}
local realWarning = DCLogger.warning
DCLogger.warning = function(msg, ...)
  local ok, formatted = pcall(string.format, msg, ...)
  warnings[#warnings + 1] = ok and formatted or tostring(msg)
end

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

-- The real accessor reads g_currentMission.proStaffManager and calls
-- ps[getterName](ps, unpack(args)). This mock RECORDS the farm id it was handed,
-- because "was the exact farm forwarded" is one of the things under test.
local lastAskedFarm, askedCount
local function setGate(gate)
  lastAskedFarm, askedCount = nil, 0
  g_currentMission.proStaffManager = {
    hasHerdAdvisory = function(_, farmId)
      lastAskedFarm = farmId
      askedCount = (askedCount or 0) + 1
      return gate
    end,
  }
end

local function barnState(over)
  local b = {
    barnId = "b1", farmId = 1,
    herdHealthScore = 73, milkQualityTier = "standard",
    spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key,
    _spoilageTierDrop = 0, mycotoxinPenalty = 0, feedSourceFields = {},
    _wireReceived = true,
  }
  return merge(b, over)
end

-- Register a barn AND its matching placeable in one step, so a test that means
-- "an ordinary admissible barn" cannot accidentally omit half of it.
local function addBarn(m, id, over, placeOver)
  local b = barnState(over or {})
  b.barnId = id
  m.barns[id] = b
  if placeOver ~= "none" then
    placeables[id] = placeable(placeOver or { _owner = b.farmId })
  end
  return b
end

-- EVERY read goes through this. A malformed fact reaching an unguarded
-- comparison raises inside production (a string score against a number cutoff
-- is a Lua error, not a false), and a raised error aborts the whole file: the
-- runner prints one line and no row can be attributed. The battery caught this
-- directly, M5 came back KILLED* rather than KILLED. So the read is protected
-- here and the throw becomes a named row instead of a dead file.
local lastError
local function advisories(m, farm)
  lastError = nil
  local ok, rows = pcall(function() return m:getHerdAdvisories(farm) end)
  if not ok then lastError = tostring(rows); return {} end
  return rows
end

local function readCleanly(m, farm, what)
  local rows = advisories(m, farm)
  T.ok("the read did not throw: " .. what, lastError == nil, lastError)
  return rows
end
-- Nil-safe readers for row contents. A mutation that empties the result must
-- produce NAMED failing rows, not a nil index that aborts the file; the battery
-- proved this the hard way, with M5 coming back as a crash-only kill because the
-- assertions after an emptied read indexed nil.
local function reasonCount(row)
  if type(row) ~= "table" or type(row.reasons) ~= "table" then return -1 end
  return #row.reasons
end
local function reasonAt(row, i)
  if type(row) ~= "table" or type(row.reasons) ~= "table" then return "<no row>" end
  return row.reasons[i] or "<no reason>"
end
local function field(row, key)
  if type(row) ~= "table" then return "<no row>" end
  if row[key] == nil then return "<no " .. key .. ">" end
  return row[key]
end
local function ids(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = tostring(r.barnId) end
  return out
end

local function joined(rows) return table.concat(ids(rows), ",") end

local HEALTH = DairyConstants.HERD_ADVISORY.REASONS.HEALTH
local MILK   = DairyConstants.HERD_ADVISORY.REASONS.MILK

-- The whole file depends on these existing. Assert it once, by name, so a build
-- without the repair reports a named row rather than dying on a nil index.
T.ok("REASONS.HEALTH is published", type(HEALTH) == "string" and HEALTH ~= "")
T.ok("REASONS.MILK is published",   type(MILK) == "string" and MILK ~= "")
T.eq("the health code is HEALTH_ATTENTION", HEALTH, "HEALTH_ATTENTION")
T.eq("the milk code is MILK_AGEING",        MILK,   "MILK_AGEING")

-- ==========================================================
-- BAR 1: THE FARM ADMISSION, WHICH IS THE POINT OF THE REPAIR
--
-- A nil farm id is the dangerous one. _proStaff builds `local args = {...}` and
-- unpacks it, so a nil truncates the provider call to zero arguments, and
-- ProStaff's _resolveFarm reads "no argument" as "ask the mission", which answers
-- farm 1. So a nil must be refused HERE, and refused BEFORE the provider is asked
-- at all: it is not enough that the answer comes back empty.
-- ==========================================================

local m1 = newManager()
setGate(true)
addBarn(m1, "b1", { farmId = 1, herdHealthScore = 10 })

T.eq("a real farm is admitted",            m1:hasHerdAdvisory(1), true)
T.eq("the exact farm reached the provider", lastAskedFarm, 1)

setGate(true)
T.eq("nil farm refused",                   m1:hasHerdAdvisory(nil), false)
T.eq("nil never reached the provider",     askedCount, 0)
T.eq("nil farm yields no rows",            #advisories(m1, nil), 0)
T.eq("still never reached the provider",   askedCount, 0)

setGate(true)
T.eq("zero farm refused",                  m1:hasHerdAdvisory(0), false)
T.eq("negative farm refused",              m1:hasHerdAdvisory(-3), false)
T.eq("string farm refused",                m1:hasHerdAdvisory("1"), false)
T.eq("table farm refused",                 m1:hasHerdAdvisory({}), false)
T.eq("boolean farm refused",               m1:hasHerdAdvisory(true), false)
T.eq("none of those reached the provider", askedCount, 0)

-- NaN, the infinities and non-integers. _isRealFarmId lets all of these through
-- (NaN <= 0 is false), so the advisory admission rejects them itself.
local nan = 0 / 0
T.ok("the NaN fixture really is NaN", nan ~= nan)   -- the value, not the name
setGate(true)
T.eq("NaN farm refused",                   m1:hasHerdAdvisory(nan), false)
T.eq("+inf farm refused",                  m1:hasHerdAdvisory(math.huge), false)
T.eq("-inf farm refused",                  m1:hasHerdAdvisory(-math.huge), false)
T.eq("fractional farm refused",            m1:hasHerdAdvisory(1.5), false)
T.eq("none of those reached the provider", askedCount, 0)

-- The reserved engine ids, through _isRealFarmId.
setGate(true)
T.eq("guided tour farm refused",           m1:hasHerdAdvisory(14), false)
T.eq("invalid farm refused",               m1:hasHerdAdvisory(15), false)
T.eq("reserved ids never reached the provider", askedCount, 0)

-- ==========================================================
-- BAR 2: THE GATE IS BINARY ON THE FLAG, AND "NOT FALSE" IS NOT ENTITLEMENT
-- ==========================================================

local m2 = newManager()
setGate(true)
addBarn(m2, "b1", { farmId = 1, herdHealthScore = 20, spoilageStatus = "condemned" })
T.eq("gate true publishes the flag",       m2:hasHerdAdvisory(1), true)
T.eq("gate true returns rows",             #advisories(m2, 1), 1)

setGate(false)
T.eq("gate false reads false",             m2:hasHerdAdvisory(1), false)
T.eq("gate false returns no rows",         #advisories(m2, 1), 0)

-- A truthy non-boolean is NOT entitlement. This is the row that catches a
-- provider returning a level number, a string or a table by mistake.
for _, v in ipairs({ 1, "true", "yes" }) do
  g_currentMission.proStaffManager = { hasHerdAdvisory = function() return v end }
  T.eq("truthy " .. type(v) .. " is not entitlement", m2:hasHerdAdvisory(1), false)
end
g_currentMission.proStaffManager = { hasHerdAdvisory = function() return {} end }
T.eq("a truthy table is not entitlement",  m2:hasHerdAdvisory(1), false)

-- A throwing provider, a provider with no such method, and no provider at all.
g_currentMission.proStaffManager = { hasHerdAdvisory = function() error("boom") end }
T.eq("a throwing provider grants nothing", m2:hasHerdAdvisory(1), false)
T.eq("a throwing provider yields no rows", #advisories(m2, 1), 0)
g_currentMission.proStaffManager = { someOtherGetter = function() return true end }
T.eq("a provider without the method",      m2:hasHerdAdvisory(1), false)
g_currentMission.proStaffManager = nil
T.eq("no provider at all",                 m2:hasHerdAdvisory(1), false)
T.eq("no provider yields no rows",         #advisories(m2, 1), 0)

-- Dairy's own stand-down refuses before the provider is consulted.
setGate(true)
m2.disabled = true
T.eq("a disabled manager refuses",         m2:hasHerdAdvisory(1), false)
T.eq("and never asked the provider",       askedCount, 0)
m2.disabled = false
m2.settings.enabled = false
T.eq("disabled settings refuse",           m2:hasHerdAdvisory(1), false)
T.eq("and never asked the provider",       askedCount, 0)
m2.settings.enabled = true

-- ==========================================================
-- BAR 3: BARN ADMISSION. EACH RULE REFUSES ON ITS OWN.
--
-- Every barn below has a qualifying health score, so anything missing from the
-- result was excluded by admission rather than by having nothing to report.
-- ==========================================================

local m3 = newManager()
setGate(true)
placeables = {}
addBarn(m3, "ok",        { farmId = 1, herdHealthScore = 10 })
addBarn(m3, "otherFarm", { farmId = 2, herdHealthScore = 10 }, { _owner = 2 })
addBarn(m3, "nilOwner",  { farmId = UNSET, herdHealthScore = 10 })
addBarn(m3, "dead",      { farmId = 1, herdHealthScore = 10, _probeDead = true })
addBarn(m3, "noPlace",   { farmId = 1, herdHealthScore = 10 }, "none")
addBarn(m3, "ownerMism", { farmId = 1, herdHealthScore = 10 }, { _owner = 2 })
addBarn(m3, "ownerNil",  { farmId = 1, herdHealthScore = 10 }, { _owner = UNSET })
addBarn(m3, "noOwnerFn", { farmId = 1, herdHealthScore = 10 }, { getOwnerFarmId = UNSET })
addBarn(m3, "ownerThrow",{ farmId = 1, herdHealthScore = 10 },
        { getOwnerFarmId = function() error("no owner") end })

T.eq("only the admissible barn survives",
     joined(readCleanly(m3, 1, "malformed placeables")), "ok")

-- Named individually, so a future regression says WHICH rule stopped holding.
local function admitted(m, farm, id)
  for _, r in ipairs(advisories(m, farm)) do
    if tostring(r.barnId) == id then return true end
  end
  return false
end
T.eq("another farm's barn excluded",       admitted(m3, 1, "otherFarm"), false)
T.eq("a nil-owner barn excluded",          admitted(m3, 1, "nilOwner"), false)
T.eq("a dead probe excluded",              admitted(m3, 1, "dead"), false)
T.eq("an unresolvable placeable excluded", admitted(m3, 1, "noPlace"), false)
T.eq("a native owner mismatch excluded",   admitted(m3, 1, "ownerMism"), false)
T.eq("an unknown native owner excluded",   admitted(m3, 1, "ownerNil"), false)
T.eq("a missing owner method excluded",    admitted(m3, 1, "noOwnerFn"), false)
T.eq("a throwing owner read excluded",     admitted(m3, 1, "ownerThrow"), false)

-- The nil-owner barn is the old permissive route. It must not come back for ANY
-- farm, which is stronger than "not for farm 1".
T.eq("the nil-owner barn is invisible to farm 2 too", admitted(m3, 2, "nilOwner"), false)

-- And farm 2 sees its own and only its own.
T.eq("farm 2 sees only its barn",          joined(advisories(m3, 2)), "otherFarm")

-- ==========================================================
-- BAR 4: THE CLIENT KNOWLEDGE-STATE GATE
--
-- A client barn record begins at herdHealthScore 60 and the attention cutoff is
-- an inclusive 60, so an unreceived default would be published as an observation
-- of a herd in trouble. _wireReceived is what stops it.
-- ==========================================================

local m4 = newManager()
setGate(true)
placeables = {}
addBarn(m4, "received",   { farmId = 1, herdHealthScore = 60, _wireReceived = true })
addBarn(m4, "unreceived", { farmId = 1, herdHealthScore = 60, _wireReceived = UNSET })

g_currentMission._isServer = true
T.eq("the server trusts its own book",     joined(advisories(m4, 1)),
     "received,unreceived")

g_currentMission._isServer = false
T.eq("a client publishes only what arrived", joined(advisories(m4, 1)), "received")
T.eq("the default-60 unreceived barn is not an observation",
     admitted(m4, 1, "unreceived"), false)
g_currentMission._isServer = true

-- ==========================================================
-- BAR 5: THE REASONS. CODES, ORDER, AND NOTHING FROM A MISSING FACT.
-- ==========================================================

local m5 = newManager()
setGate(true)
placeables = {}
addBarn(m5, "healthOnly", { farmId = 1, herdHealthScore = 10,  spoilageStatus = "fresh" })
addBarn(m5, "milkOnly",   { farmId = 1, herdHealthScore = 90,  spoilageStatus = "ageing" })
addBarn(m5, "both",       { farmId = 1, herdHealthScore = 10,  spoilageStatus = "condemned" })
addBarn(m5, "neither",    { farmId = 1, herdHealthScore = 90,  spoilageStatus = "fresh" })
addBarn(m5, "atCutoff",   { farmId = 1, herdHealthScore = 60,  spoilageStatus = "fresh" })
addBarn(m5, "justAbove",  { farmId = 1, herdHealthScore = 61,  spoilageStatus = "fresh" })
addBarn(m5, "noScore",    { farmId = 1, herdHealthScore = UNSET, spoilageStatus = "fresh" })
addBarn(m5, "nanScore",   { farmId = 1, herdHealthScore = nan, spoilageStatus = "fresh" })
addBarn(m5, "strScore",   { farmId = 1, herdHealthScore = "0", spoilageStatus = "fresh" })
addBarn(m5, "infScore",   { farmId = 1, herdHealthScore = -math.huge, spoilageStatus = "fresh" })
addBarn(m5, "atrisk",     { farmId = 1, herdHealthScore = 90,  spoilageStatus = "atrisk" })

local byId = {}
for _, r in ipairs(readCleanly(m5, 1, "malformed health facts")) do
  byId[tostring(r.barnId)] = r
end

T.eq("the cutoff reuses the Standard tier boundary",
     m5:_herdAdvisoryCutoff(), DairyConstants.QUALITY.TIERS[2].minScore)
T.eq("the cutoff is 60",                   m5:_herdAdvisoryCutoff(), 60)

T.eq("health alone gives one reason",      reasonCount(byId["healthOnly"]), 1)
T.eq("health alone is the health code",    reasonAt(byId["healthOnly"], 1), HEALTH)
T.eq("milk alone gives one reason",        reasonCount(byId["milkOnly"]), 1)
T.eq("milk alone is the milk code",        reasonAt(byId["milkOnly"], 1), MILK)
T.eq("both gives two reasons",             reasonCount(byId["both"]), 2)
T.eq("health comes first",                 reasonAt(byId["both"], 1), HEALTH)
T.eq("milk comes second",                  reasonAt(byId["both"], 2), MILK)
T.eq("at risk qualifies",                  reasonAt(byId["atrisk"], 1), MILK)

T.eq("a healthy fresh barn produces no row",  byId["neither"], nil)
T.eq("the cutoff is inclusive",               byId["atCutoff"] ~= nil, true)
T.eq("one point above the cutoff is silent",  byId["justAbove"], nil)

-- Missing and malformed facts create no reason. The old code read a missing
-- score as 0, which is below every cutoff, so an absent fact was published as
-- the worst possible observation.
T.eq("a missing score produces no row",    byId["noScore"], nil)
T.eq("a NaN score produces no row",        byId["nanScore"], nil)
T.eq("a string score produces no row",     byId["strScore"], nil)
T.eq("an infinite score produces no row",  byId["infScore"], nil)

-- ==========================================================
-- BAR 6: THE ROW SHAPE, ITS ORDER, AND ITS DETACHMENT
-- ==========================================================

local m6 = newManager()
setGate(true)
placeables = {}
addBarn(m6, "zulu",  { farmId = 1, herdHealthScore = 10 })
addBarn(m6, "alpha", { farmId = 1, herdHealthScore = 10 })
addBarn(m6, "mike",  { farmId = 1, herdHealthScore = 10 })

local rows6 = advisories(m6, 1)
T.eq("rows come back in stable barn id order", joined(rows6), "alpha,mike,zulu")
T.eq("every row carries the requested farm",
     (field(rows6[1], "farmId") == 1 and field(rows6[2], "farmId") == 1 and field(rows6[3], "farmId") == 1), true)
T.ok("every row carries a string label",
     type(field(rows6[1], "label")) == "string" and field(rows6[1], "label") ~= "")
T.ok("every row carries a reasons array", reasonCount(rows6[1]) >= 1)

-- Detached: mutating what came back must not reach the simulation, and two calls
-- must not hand back the same tables.
rows6[1].reasons[1] = "TAMPERED"
rows6[1].barnId = "TAMPERED"
rows6[1].label = "TAMPERED"
local rows6b = advisories(m6, 1)
T.eq("a tampered reason did not persist",  reasonAt(rows6b[1], 1), HEALTH)
T.eq("a tampered barn id did not persist", tostring(field(rows6b[1], "barnId")), "alpha")
T.ok("a second call returns different tables", rows6[1] ~= rows6b[1])
T.ok("the reasons arrays are different too",   rows6[1].reasons ~= rows6b[1].reasons)
T.eq("the barn record itself is untouched",
     m6.barns["alpha"].herdHealthScore, 10)

-- ==========================================================
-- BAR 7: THE LABEL LADDER
--
-- The label is an IDENTITY string: whatever the player calls the building, passed
-- through opaquely. It is never advisory prose and never a format string.
-- ==========================================================

local m7 = newManager()
setGate(true)
placeables = {}
addBarn(m7, "named",   { farmId = 1, herdHealthScore = 10 },
        { getOwnerFarmId = function() return 1 end, getName = function() return "North Barn" end })
addBarn(m7, "custom",  { farmId = 1, herdHealthScore = 10 },
        { _owner = 1, nameCustom = "Custom Shed" })
addBarn(m7, "l10n",    { farmId = 1, herdHealthScore = 10 },
        { _owner = 1, nameL10n = "Localized Barn" })
addBarn(m7, "store",   { farmId = 1, herdHealthScore = 10 },
        { _owner = 1, storeItem = { name = "Store Barn" } })
addBarn(m7, "bare",    { farmId = 1, herdHealthScore = 10 }, { _owner = 1 })
addBarn(m7, "throws",  { farmId = 1, herdHealthScore = 10 },
        { _owner = 1, getName = function() error("nope") end, nameCustom = "After The Throw" })
addBarn(m7, "blank",   { farmId = 1, herdHealthScore = 10 },
        { _owner = 1, getName = function() return "" end, nameCustom = "After The Blank" })
addBarn(m7, "colon: 100% north", { farmId = 1, herdHealthScore = 10 }, { _owner = 1 })
local longId = string.rep("x", 40)
addBarn(m7, longId, { farmId = 1, herdHealthScore = 10 }, { _owner = 1 })

local lbl = {}
for _, r in ipairs(advisories(m7, 1)) do lbl[tostring(r.barnId)] = r.label end

T.eq("rung 1 is the placeable's own name",  lbl["named"],  "North Barn")
T.eq("rung 2 is nameCustom",                lbl["custom"], "Custom Shed")
T.eq("rung 3 is nameL10n",                  lbl["l10n"],   "Localized Barn")
T.eq("rung 4 is the store item name",       lbl["store"],  "Store Barn")
T.eq("the last resort is the barn id",      lbl["bare"],   "bare")
T.eq("a throwing getName falls to the next rung", lbl["throws"], "After The Throw")
T.eq("an empty getName falls to the next rung",   lbl["blank"],  "After The Blank")
T.eq("a player name with a colon and a percent survives verbatim",
     lbl["colon: 100% north"], "colon: 100% north")
T.eq("an overlong id is truncated to 25 displayed characters",
     lbl[longId], string.rep("x", 22) .. "...")
T.eq("the truncation is 22 plus the ellipsis", #lbl[longId], 25)

-- ==========================================================
-- BAR 8: NO WRITE OCCURS
-- ==========================================================

local m8 = newManager()
setGate(true)
placeables = {}
addBarn(m8, "sick",    { farmId = 1, herdHealthScore = 30, spoilageStatus = "ageing" })
addBarn(m8, "healthy", { farmId = 1, herdHealthScore = 90, spoilageStatus = "fresh" })
m8.contracts[1] = { contractId = 1, barnId = "sick", farmId = 1, delivered = 0 }
g_currentMission.money[1] = { income = 100, farmId = 1 }

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepCopy(v) end
  return c
end
local function equalTables(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  local ka, kb = 0, 0
  for k, v in pairs(a) do
    ka = ka + 1
    if not equalTables(b[k], v) then return false end
  end
  for _ in pairs(b) do kb = kb + 1 end
  return ka == kb
end

local barnsBefore = deepCopy(m8.barns)
local contractsBefore = deepCopy(m8.contracts)
local moneyBefore = deepCopy(g_currentMission.money)
local count8 = #advisories(m8, 1)
advisories(m8, 1)
advisories(m8, 1)

T.eq("the advisory read ran",              count8, 1)
T.ok("barns are untouched",                equalTables(m8.barns, barnsBefore))
T.ok("contracts are untouched",            equalTables(m8.contracts, contractsBefore))
T.ok("money is untouched",                 equalTables(g_currentMission.money, moneyBefore))
T.eq("repeated reads discovered no barn",  (function()
  local n = 0 for _ in pairs(m8.barns) do n = n + 1 end return n
end)(), 2)

-- ==========================================================
-- BAR 9: THE ONE PRECONDITION THAT FAILS GLOBALLY IS ANNOUNCED
--
-- Bob's MINOR on this PR. The other four admission rules exclude ONE barn each,
-- which is ordinary operation. If the placeable system is missing, or
-- getPlaceableByUniqueId is not a function, EVERY barn fails and the advisory is
-- permanently empty, which is indistinguishable from "no barn needs attention"
-- to anyone reading the result. getPlaceableByUniqueId is decompiled evidence
-- rather than an official signature, so this is a live risk, not a hypothetical.
-- ==========================================================

local realPs = g_currentMission.placeableSystem
local m9 = newManager()
setGate(true)
placeables = {}
addBarn(m9, "sick", { farmId = 1, herdHealthScore = 10 })

-- The witness first: with the system present this barn DOES appear, so an empty
-- result below is the stand-down and not the fixture.
T.eq("the witness barn appears while the system is present",
     joined(advisories(m9, 1)), "sick")

warnings = {}
g_currentMission.placeableSystem = nil
T.eq("no placeable system yields no rows",  #advisories(m9, 1), 0)
T.eq("and says so exactly once",            #warnings, 1)
T.ok("the line names the stand-down",       warnings[1] ~= nil and
     warnings[1]:match("stood down") ~= nil, warnings[1])
T.ok("the line says EMPTY is not all-clear", warnings[1] ~= nil and
     warnings[1]:match("not the same as no barn") ~= nil, warnings[1])

-- Once per session, not once per read: a line on every read is noise nobody reads.
advisories(m9, 1); advisories(m9, 1)
T.eq("repeated reads do not repeat the line", #warnings, 1)

-- The other failing shape: the system exists but the method does not.
warnings = {}
local m9b = newManager()
g_currentMission.placeableSystem = { getPlaceableByUniqueId = "not a function" }
addBarn(m9b, "sick", { farmId = 1, herdHealthScore = 10 })
T.eq("a non-function lookup yields no rows", #advisories(m9b, 1), 0)
T.eq("and says so once",                     #warnings, 1)
T.ok("the line names the method",            warnings[1] ~= nil and
     warnings[1]:match("getPlaceableByUniqueId") ~= nil, warnings[1])

g_currentMission.placeableSystem = realPs
DCLogger.warning = realWarning

T.summary()
