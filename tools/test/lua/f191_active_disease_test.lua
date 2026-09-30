-- f191_active_disease_test.lua - F191, ONLY ACTIVE DISEASE RECORDS PENALIZE.
--
-- RealisticLivestock keeps a cured disease record attached to the animal until its
-- immunity counts down (Disease.lua:89-93) and a carrier record is symptomless by
-- design. RLBridge:computeHerdScore used to count every entry in animal.diseases,
-- so a treated cow kept dragging herdHealthScore for as long as its immunity ran.
-- #54 filtered cured and carrier records.
--
-- RSF-F191 FINISHES THE READER. The provider decides first: each animal's own
-- getHasAnyDisease is asked, a strict false is zero active records (disabled
-- diseases included), and only a strict true opens the list, counted in order with
-- ipairs, each record active only when it is neither cured nor a carrier. A true is
-- never itself a record. A missing, non-boolean or throwing getter, an unreadable
-- list or a malformed record degrades the bridge to Standard mode through safeRead.
--
-- THE PROVIDER MODEL. The installed RealisticLivestockRM is 1.2.6.0, whose getter is
-- `g_diseaseManager ~= nil and g_diseaseManager.diseasesEnabled and #self.diseases > 0`
-- (RealisticLivestock_Animal.lua:1591-1593), with no cured or carrier filter of its
-- own. The cows below carry that getter, with `provider.enabled` standing in for
-- diseasesEnabled. The brief's 1.3.2.x provider filters inside the getter too; a
-- reader that filters in its own count is right against both.
--
-- THE FIXTURE TRAP (Bob's intake). Every case that expects a SCORE also asserts it
-- REACHED the count: the bridge is still in Ritter mode and every animal's getter
-- was asked. A degrade to Standard returns nil, so without those rows a case
-- expecting "no penalty" could pass by exiting early.
--
-- Every scored cow has health 100 and productivity 1.0, so the per-animal base is
-- (1.0 * 0.6) + (0.5 * 0.4) = 0.80, i.e. a barn score of 80 with no penalty.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/RLBridge.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua

local BASE = 80          -- clean animal score, see header
local PER_RECORD = 8     -- 0.08 * 100
local CAP = 40           -- 0.40 * 100

local provider = { enabled = true, calls = 0 }

local function setRitterPresent()
  g_diseaseManager = {}
  g_modIsLoaded = { ["FS25_RealisticLivestockRM"] = true }
  RLBridge._degradedLogged = nil
  RLBridge:init()
end

local function setRitterAbsent()
  g_diseaseManager = nil
  g_modIsLoaded = {}
  RLBridge._degradedLogged = nil
  RLBridge:init()
end

-- The barn placeable lives under farm 1 in the mocked husbandry system.
local function setHerd(animals)
  g_currentMission.husbandrySystem = {
    getPlaceablesByFarm = function(_, farmId)
      if farmId == 1 then
        return {
          {
            getUniqueId = function() return "barn1" end,
            getOwnerFarmId = function() return 1 end,
            spec_husbandryAnimals = {
              clusterSystem = { getAnimals = function() return animals end },
            },
          },
        }
      end
      return {}
    end,
  }
end

--- The 1.2.6.0 getter, counting how often it is asked.
local function providerGetter(self)
  provider.calls = provider.calls + 1
  return provider.enabled and #self.diseases > 0
end

--- A getter that answers `value` whatever the list holds, still counted.
local function answers(value)
  return function()
    provider.calls = provider.calls + 1
    return value
  end
end

local function cow(diseases, getter)
  return { health = 100, genetics = { productivity = 1.0 }, diseases = diseases,
           getHasAnyDisease = getter or providerGetter }
end

local function active()  return { cured = false, isCarrier = false } end
local function cured()   return { cured = true,  isCarrier = false } end
local function carrier() return { cured = false, isCarrier = true  } end

--- Score a herd in Ritter mode and prove the read reached the count.
local function score(tag, herd)
  provider.calls = 0
  setRitterPresent()
  setHerd(herd)
  local s = RLBridge:computeHerdScore("barn1", 1)
  T.eq(tag .. " [reached: still in Ritter mode]", RLBridge.active, true)
  T.eq(tag .. " [reached: every animal's getter was asked]", provider.calls, #herd)
  return s
end

--- Score a herd that must DEGRADE: nil back, and the bridge tripped to Standard.
local function degrades(tag, herd)
  provider.calls = 0
  setRitterPresent()
  setHerd(herd)
  T.eq(tag .. ": no score is invented", RLBridge:computeHerdScore("barn1", 1), nil)
  T.eq(tag .. ": the bridge degraded to Standard mode", RLBridge.active, false)
end

provider.enabled = true

-- ══════════════════════════════════════════════════════════
-- 1. 0 / 1 / 2 / 5 ACTIVE RECORDS, AND THE 0.40 CAP
-- ══════════════════════════════════════════════════════════

T.near("1: no records, no penalty", score("1a", { cow({}) }), BASE, 1e-6)
T.near("1: one active record costs exactly one 0.08 step", score("1b", { cow({ active() }) }), BASE - PER_RECORD, 1e-6)
T.near("1: two active records cost two steps", score("1c", { cow({ active(), active() }) }), BASE - 2 * PER_RECORD, 1e-6)
T.near("1: five active records reach the 0.40 cap exactly",
  score("1d", { cow({ active(), active(), active(), active(), active() }) }), BASE - CAP, 1e-6)
T.near("1: six active records stay at the cap",
  score("1e", { cow({ active(), active(), active(), active(), active(), active() }) }), BASE - CAP, 1e-6)
T.near("1: eight active records do not exceed the cap",
  score("1f", { cow({ active(), active(), active(), active(), active(), active(), active(), active() }) }), BASE - CAP, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 2. CURED AND CARRIER RECORDS, AND "TRUE IS NOT A RECORD"
-- ══════════════════════════════════════════════════════════

-- The 1.2.6.0 getter says true here (no filter of its own). The true opens the list;
-- it is not itself a record, and every record in the list is inactive.
T.near("2: cured records still attached during immunity cost nothing",
  score("2a", { cow({ cured(), cured() }) }), BASE, 1e-6)
T.near("2: a symptomless carrier record costs nothing", score("2b", { cow({ carrier() }) }), BASE, 1e-6)

local mixed = { active(), cured(), cured(), carrier() }
T.near("2: mixed records penalize only the one active record", score("2c", { cow(mixed) }), BASE - PER_RECORD, 1e-6)
T.eq("2: the active record is untouched", mixed[1].cured, false)
T.eq("2: the cured record is untouched", mixed[2].cured, true)
T.eq("2: the carrier record is untouched", mixed[4].isCarrier, true)
T.eq("2: no record was added or removed", #mixed, 4)

T.near("2: inactive records do not push the penalty toward the cap",
  score("2d", { cow({ active(), active(), active(), active(), cured(), cured(), cured(), cured() }) }),
  BASE - 4 * PER_RECORD, 1e-6)

-- Rewritten for the v1.4 delta (brief v1.0 section 3.2): a legacy record, one with
-- no state, must carry both flags as booleans, and malformed legacy flags raise.
-- Real 1.2.6.0 and 1.3.2.1 records always carry both booleans (their constructor,
-- XML load and stream write them), so this changes nothing on real provider data.
-- Before the delta, 2e counted a record with neither flag as active.
degrades("2e a legacy record with neither flag set", { cow({ {} }) })

-- Before the delta, 2f read a truthy non-boolean flag as the provider's own
-- `not cured and not isCarrier` does. Now a non-boolean flag raises.
-- One row per flag, so a check that dropped either one alone is seen.
degrades("2f a truthy non-boolean cured flag", { cow({ { cured = 1, isCarrier = false } }) })
degrades("2f a truthy non-boolean isCarrier flag", { cow({ { cured = false, isCarrier = "yes" } }) })

T.near("2: per-animal filtering averages across the herd",
  score("2g", { cow({ active(), active() }), cow({ cured(), carrier() }) }),
  ((BASE - 2 * PER_RECORD) + BASE) / 2, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 3. PROVIDER FALSE, DISABLED AND ABSENT
-- ══════════════════════════════════════════════════════════

-- Diseases switched off in RealisticLivestock: the getter says false while active
-- records are still attached. False means zero active records.
provider.enabled = false
T.near("3: DISEASES DISABLED: active records still attached cost nothing",
  score("3a", { cow({ active(), active(), active() }) }), BASE, 1e-6)
provider.enabled = true

-- A strict false never opens the list, so an unreadable list behind it is not read.
T.near("3: a strict false never reads the list behind it",
  score("3b", { cow("not a list", answers(false)) }), BASE, 1e-6)

setRitterAbsent()
setHerd({ cow({ active(), active(), active() }) })
T.eq("3: with the provider absent the bridge reads nothing", RLBridge:computeHerdScore("barn1", 1), nil)

local m = DairyCoreManager.new()
m.barns["barn1"] = { barnId = "barn1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
m:_updateBarnHealth(m.barns["barn1"])
T.eq("3: the barn falls back to Standard mode", m.barns["barn1"].ritterMode, false)
T.ok("3: Standard mode still yields a numeric score", type(m.barns["barn1"].herdHealthScore) == "number")

-- ══════════════════════════════════════════════════════════
-- 4. SPARSE ORDERED LISTS: ipairs, the way the provider iterates
-- ══════════════════════════════════════════════════════════

T.near("4: a hole in the list ends the ordered count, as the provider's ipairs does",
  score("4a", { cow({ [1] = active(), [3] = active(), [4] = active() }, answers(true)) }), BASE - PER_RECORD, 1e-6)
T.near("4: a list whose first slot is empty counts nothing",
  score("4b", { cow({ [2] = active(), [3] = active() }, answers(true)) }), BASE, 1e-6)
T.near("4: string keys are not ordered records",
  score("4c", { cow({ active(), extra = active() }, answers(true)) }), BASE - PER_RECORD, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 5. A GETTER THAT CANNOT BE TRUSTED DEGRADES, NEVER SCORES
-- ══════════════════════════════════════════════════════════

local noGetter = cow({ active() })
noGetter.getHasAnyDisease = nil
degrades("5a missing getter", { noGetter })

local notCallable = cow({ active() })
notCallable.getHasAnyDisease = true
degrades("5b a getter that is not a function", { notCallable })

degrades("5c a getter answering the number 1", { cow({ active() }, answers(1)) })
degrades("5d a getter answering nil", { cow({ active() }, answers(nil)) })
degrades("5e a getter answering the string true", { cow({ active() }, answers("true")) })
degrades("5f a throwing getter", { cow({ active() }, function() error("provider threw") end) })

-- One bad animal among good ones: the existing safeRead degradation takes the whole read.
degrades("5g one untrustworthy getter in a good herd", { cow({ active() }), cow({ active() }, answers(1)) })

-- ══════════════════════════════════════════════════════════
-- 6. RECORDS THAT CANNOT BE READ DEGRADE, NEVER SCORE
-- ══════════════════════════════════════════════════════════

degrades("6a a true getter over a missing list", { cow(nil, answers(true)) })
degrades("6b a true getter over a list that is not a table", { cow("not a list", answers(true)) })
degrades("6c a malformed record (a string)", { cow({ active(), "junk" }, answers(true)) })
degrades("6d a malformed record (a number)", { cow({ 42 }, answers(true)) })
degrades("6e a record whose fields throw when read",
  { cow({ setmetatable({}, { __index = function() error("record read failed") end }) }, answers(true)) })

-- And the manager's Standard fallback follows the degrade end to end.
setRitterPresent()
setHerd({ cow({ active() }, answers(1)) })
local m2 = DairyCoreManager.new()
m2.barns["barn1"] = { barnId = "barn1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
m2:_updateBarnHealth(m2.barns["barn1"])
T.eq("6: after a degrade the barn is scored in Standard mode", m2.barns["barn1"].ritterMode, false)
T.ok("6: with a numeric Standard score", type(m2.barns["barn1"].herdHealthScore) == "number")

-- ══════════════════════════════════════════════════════════
-- 7. REALISTIC LIVESTOCK 1.4.0.0: THE RECORD STATE
-- ══════════════════════════════════════════════════════════
-- Brief v1.0 on Design amendment v0.4. A 1.4 record carries a string state and
-- isCarrier, and no cured (Disease.lua constructor, XML load and save, and streams
-- at tag v1.4.0.0). The getter is the provider's own Animal:getHasAnyDisease,
-- RealisticLivestock_Animal.lua:1942-1954 at tag v1.4.0.0 (e914c2f8), line for line,
-- wrapped only to count that it was asked: false with no manager, diseases off or no
-- diseases table; otherwise true when any record passes RLDiseaseStatus.isDiseased
-- (RLDiseaseStatus.lua:72-74, state == STATE.INFECTIOUS; STATE values equal their
-- keys, RLDiseaseRecord.lua:39-45). Not a stub that returns true.

local STATE14 = { SUSCEPTIBLE = "SUSCEPTIBLE", EXPOSED = "EXPOSED", INFECTIOUS = "INFECTIOUS", RECOVERED = "RECOVERED", DEAD = "DEAD" }
local function isDiseased14(record)
  return record.state == STATE14.INFECTIOUS
end
local function gate14(self)
  if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled or self.diseases == nil then
    return false
  end
  for _, disease in ipairs(self.diseases) do
    if isDiseased14(disease) then
      return true
    end
  end
  return false
end
local function getter14(self)
  provider.calls = provider.calls + 1
  return gate14(self)
end

local function rec14(state, carrier) return { state = state, isCarrier = carrier == true } end
local function cow14(records) return cow(records, getter14) end
local function INF()  return rec14("INFECTIOUS") end
local function EXP()  return rec14("EXPOSED") end
local function REC()  return rec14("RECOVERED") end
local function DEAD() return rec14("DEAD") end

-- RLBridge:init needs g_diseaseManager present; the 1.4 gate also reads its
-- diseasesEnabled flag, which setRitterPresent's fresh table does not carry.
local function score14(tag, herd, enabled)
  provider.calls = 0
  setRitterPresent()
  g_diseaseManager.diseasesEnabled = enabled ~= false
  setHerd(herd)
  local s = RLBridge:computeHerdScore("barn1", 1)
  T.eq(tag .. " [reached: still in Ritter mode]", RLBridge.active, true)
  T.eq(tag .. " [reached: every animal's getter was asked]", provider.calls, #herd)
  return s
end
local function degrades14(tag, herd)
  provider.calls = 0
  setRitterPresent()
  g_diseaseManager.diseasesEnabled = true
  setHerd(herd)
  T.eq(tag .. ": no score is invented", RLBridge:computeHerdScore("barn1", 1), nil)
  T.eq(tag .. ": the bridge degraded to Standard mode", RLBridge.active, false)
end

-- Counts: 0, 1, 2, 5 and 6 INFECTIOUS records, and the 0.40 cap.
T.near("7: v1.4, no records, no penalty", score14("7a", { cow14({}) }), BASE, 1e-6)
T.near("7: v1.4, one INFECTIOUS record costs one step", score14("7b", { cow14({ INF() }) }), BASE - PER_RECORD, 1e-6)
T.near("7: v1.4, two INFECTIOUS records cost two steps", score14("7c", { cow14({ INF(), INF() }) }), BASE - 2 * PER_RECORD, 1e-6)
T.near("7: v1.4, five INFECTIOUS records reach the cap",
  score14("7d", { cow14({ INF(), INF(), INF(), INF(), INF() }) }), BASE - CAP, 1e-6)
T.near("7: v1.4, six INFECTIOUS records stay at the cap",
  score14("7e", { cow14({ INF(), INF(), INF(), INF(), INF(), INF() }) }), BASE - CAP, 1e-6)

-- The defect case: the v0.2 classifier counted `not d.cured and not d.isCarrier`,
-- and cured is nil on every 1.4 record, so here it cost four steps, not one.
T.near("7: v1.4 mixed, one INFECTIOUS among EXPOSED, RECOVERED and DEAD costs exactly one step",
  score14("7f", { cow14({ EXP(), INF(), REC(), DEAD() }) }), BASE - PER_RECORD, 1e-6)
T.near("7: v1.4 mixed, averaged across two animals",
  score14("7g", { cow14({ EXP(), INF(), INF(), REC() }), cow14({ EXP(), REC(), DEAD() }) }),
  ((BASE - 2 * PER_RECORD) + BASE) / 2, 1e-6)
T.near("7: v1.4, an INFECTIOUS carrier counts one, as the provider's own rule does",
  score14("7h", { cow14({ rec14("INFECTIOUS", true) }) }), BASE - PER_RECORD, 1e-6)

-- State wins: a state-bearing record never falls through to the legacy flags.
T.near("7: state wins, EXPOSED and RECOVERED with both legacy flags false cost nothing",
  score14("7i", { cow14({ INF(), { state = "EXPOSED", cured = false, isCarrier = false },
                            { state = "RECOVERED", cured = false, isCarrier = false } }) }),
  BASE - PER_RECORD, 1e-6)
T.near("7: state wins, INFECTIOUS with cured = true still costs one step",
  score14("7j", { cow14({ { state = "INFECTIOUS", cured = true, isCarrier = false } }) }), BASE - PER_RECORD, 1e-6)

-- The provider says false: no penalty, and the bridge does not read the list. The
-- animal below counts every read of its diseases field. The provider's own gate
-- reads it twice (the nil check and the ipairs); a bridge read would be a third.
local function readCounted(records)
  local a = cow14(nil)
  local seen = { reads = 0 }
  setmetatable(a, { __index = function(_, k)
    if k == "diseases" then seen.reads = seen.reads + 1; return records end
  end })
  return a, seen
end
do
  local a, seen = readCounted({ EXP() })
  T.near("7: gate false, EXPOSED only: no penalty", score14("7k", { a }), BASE, 1e-6)
  T.eq("7: gate false, EXPOSED only: the bridge did not read the list", seen.reads, 2)
  a, seen = readCounted({ rec14("EXPOSED", true) })
  T.near("7: gate false, a carrier held EXPOSED: no penalty", score14("7l", { a }), BASE, 1e-6)
  T.eq("7: gate false, a carrier held EXPOSED: the bridge did not read the list", seen.reads, 2)
  a, seen = readCounted({ REC() })
  T.near("7: gate false, RECOVERED only: no penalty", score14("7m", { a }), BASE, 1e-6)
  T.eq("7: gate false, RECOVERED only: the bridge did not read the list", seen.reads, 2)
  a, seen = readCounted({ INF() })
  T.near("7: control, gate true: one step", score14("7n", { a }), BASE - PER_RECORD, 1e-6)
  T.eq("7: control, gate true: the bridge's own read is seen", seen.reads, 3)
end
T.near("7: diseases disabled in the provider: INFECTIOUS records cost nothing",
  score14("7o", { cow14({ INF(), INF() }) }, false), BASE, 1e-6)

-- Behind a true gate (an INFECTIOUS sibling opens it), a state that is not a
-- string or not one of the four the brief names raises, and the bridge degrades.
-- SUSCEPTIBLE is in the provider's enum but is never held; the brief names only
-- EXPOSED, RECOVERED and DEAD as zero states, so it degrades too.
degrades14("7p state SUSCEPTIBLE", { cow14({ INF(), { state = "SUSCEPTIBLE", isCarrier = false } }) })
degrades14("7q unknown state SICK", { cow14({ INF(), { state = "SICK", isCarrier = false } }) })
degrades14("7r numeric state", { cow14({ INF(), { state = 1, isCarrier = false } }) })
degrades14("7s boolean state", { cow14({ INF(), { state = true, isCarrier = false } }) })
-- A 1.4 record read with a nil state and no cured (a client's out-of-range stream
-- ordinal) takes the legacy branch, finds no boolean cured, and degrades. It cannot
-- arise on the server, where this runs; the row pins the order.
degrades14("7t nil state and no cured flag", { cow14({ INF(), { isCarrier = false } }) })

-- The manager's Standard fallback follows an unknown-state degrade end to end.
setRitterPresent()
g_diseaseManager.diseasesEnabled = true
setHerd({ cow14({ INF(), { state = "SICK", isCarrier = false } }) })
local m3 = DairyCoreManager.new()
m3.barns["barn1"] = { barnId = "barn1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
m3:_updateBarnHealth(m3.barns["barn1"])
T.eq("7: after an unknown-state degrade the barn is scored in Standard mode", m3.barns["barn1"].ritterMode, false)
T.ok("7: with a numeric Standard score", type(m3.barns["barn1"].herdHealthScore) == "number")

-- ══════════════════════════════════════════════════════════
-- 8. ENTRY-POINT BAR (R-18): THE PRODUCTION DAY TICK
-- ══════════════════════════════════════════════════════════
-- DairyCoreManager:onDayTick(ctx), the call Time Guard's day tick makes, run as the
-- server. It reaches updateAllBarns, then discoverBarns through the placeable
-- system's own list (the verified route, DairyCoreManager.lua discoverBarns), then
-- _updateBarnHealth, then RLBridge:computeHerdScore, which finds the barn's animals
-- through husbandrySystem:getPlaceablesByFarm, modelled on HusbandrySystem.lua:39-48
-- at game 1.24.0.0 (the owner filter and the optional animal type). Nothing below
-- calls _updateBarnHealth or computeHerdScore directly. The limit: the barn and its
-- animals are a fixture, because the placeable registry is the engine's and the
-- animal list is the provider's.
do
  local savedMission = g_currentMission
  local function barnPlaceable(id, owner, herd)
    local p = { spec_husbandryMilk = {},
                spec_husbandryAnimals = { clusterSystem = { getAnimals = function() return herd end } } }
    function p:getUniqueId() return id end
    function p:getOwnerFarmId() return owner end
    function p:getAnimalTypeIndex() return 1 end
    return p
  end
  local function husbandrySystemOver(list)
    local hs = { placeables = list }
    function hs:getPlaceablesByFarm(farmId, animalTypeIndex)
      local want = farmId or (g_localPlayer ~= nil and g_localPlayer.farmId or nil)
      local out = {}
      for _, placeable in ipairs(self.placeables) do
        if want == placeable:getOwnerFarmId() and (animalTypeIndex == nil or placeable:getAnimalTypeIndex() == animalTypeIndex) then
          table.insert(out, placeable)
        end
      end
      return out
    end
    return hs
  end

  local sickHerd  = { cow14({ EXP(), INF(), REC(), DEAD() }) }
  local quietHerd = { cow14({ EXP(), EXP(), REC(), DEAD() }) }
  local list = { barnPlaceable("barnE", 1, sickHerd), barnPlaceable("barnQ", 1, quietHerd),
                 barnPlaceable("barnX", 2, { cow14({ INF(), INF(), INF() }) }) }

  local realCompute = RLBridge.computeHerdScore
  local computeCalls = 0
  RLBridge.computeHerdScore = function(self, ...) computeCalls = computeCalls + 1; return realCompute(self, ...) end

  local function mission(isServer)
    g_currentMission = setmetatable({ _isServer = isServer, placeableSystem = { placeables = list },
                                      husbandrySystem = husbandrySystemOver(list) }, { __index = savedMission })
    function g_currentMission:getIsServer() return self._isServer end
  end

  mission(true)
  setRitterPresent()
  g_diseaseManager.diseasesEnabled = true
  local mgr = DairyCoreManager.new()
  mgr:onDayTick({ monotonicDay = 5 })
  local sick, quiet = mgr.barns["barnE"], mgr.barns["barnQ"]
  T.ok("8: the day tick discovered the sick barn", sick ~= nil)
  T.ok("8: the day tick discovered the quiet barn", quiet ~= nil)
  T.ok("8: the bridge scored the barns, it was not bypassed", computeCalls >= 2)
  local GW = DairyConstants.HERD.RITTER_GENETICS_WEIGHT * 0.5   -- productivity 1.0 normalizes to 0.5
  if sick ~= nil and quiet ~= nil then
    T.eq("8: the sick barn is in Ritter mode", sick.ritterMode, true)
    T.near("8: one INFECTIOUS among EXPOSED, RECOVERED and DEAD: herdHealthScore is one step down",
      sick.herdHealthScore, (BASE - PER_RECORD) + GW, 1e-6)
    T.near("8: the same herd with EXPOSED for INFECTIOUS scores exactly one step higher",
      quiet.herdHealthScore - sick.herdHealthScore, PER_RECORD, 1e-6)
  end

  -- As a client the day tick only rediscovers barns; the score is the server's.
  computeCalls = 0
  mission(false)
  local client = DairyCoreManager.new()
  client:onDayTick({ monotonicDay = 5 })
  T.eq("8: as a client, the day tick never scores a herd", computeCalls, 0)

  RLBridge.computeHerdScore = realCompute
  g_currentMission = savedMission
end
