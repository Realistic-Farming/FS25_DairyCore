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
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/RLBridge.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua

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

-- Absence of `cured` is not a cure.
T.near("2: a record with neither flag set counts as active", score("2e", { cow({ {} }) }), BASE - PER_RECORD, 1e-6)

-- The provider's own predicate is `not cured and not isCarrier`, so a truthy flag
-- that is not the literal true still makes a record inactive.
T.near("2: a truthy non-boolean cured flag is not active, as the provider reads it",
  score("2f", { cow({ { cured = 1 }, { isCarrier = "yes" } }) }), BASE, 1e-6)

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
