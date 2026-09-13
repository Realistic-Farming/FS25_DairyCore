-- f191_active_disease_test.lua - F191, ONLY ACTIVE DISEASE RECORDS PENALIZE.
--
-- RealisticLivestock keeps a cured disease record attached to the animal until its
-- immunity counts down (Disease.lua:89-93) and a carrier record is symptomless by
-- design. RLBridge:computeHerdScore used to count every entry in animal.diseases,
-- so a treated cow kept dragging herdHealthScore for as long as its immunity ran.
-- The fix counts a record only when it is neither cured nor a carrier
-- (`d.cured ~= true and d.isCarrier ~= true`, field names from Disease.lua:10/15).
--
-- Acceptance list (tracking notes.md:459): one active record, cured only, carrier
-- only, mixed records, provider absent. Plus the 0.40 cap on 6+ active records, and
-- the read-only fence: the records are never touched.
--
-- Every mock animal has health 100 and productivity 1.0, so the per-animal base is
-- (1.0 * 0.6) + (0.5 * 0.4) = 0.80, i.e. a barn score of 80 with no penalty.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/RLBridge.lua, src/DairyCoreManager.lua

local BASE = 80          -- clean animal score, see header
local PER_RECORD = 8     -- 0.08 * 100
local CAP = 40           -- 0.40 * 100

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

local function cow(diseases)
  return { health = 100, genetics = { productivity = 1.0 }, diseases = diseases }
end

local function active()  return { cured = false, isCarrier = false } end
local function cured()   return { cured = true,  isCarrier = false } end
local function carrier() return { cured = false, isCarrier = true  } end

-- ══════════════════════════════════════════════════════════
-- 1. ONE ACTIVE RECORD
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({ cow({ active() }) })
T.near("1: one active record costs exactly one 0.08 step",
  RLBridge:computeHerdScore("barn1", 1), BASE - PER_RECORD, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 2. CURED ONLY
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({ cow({ cured(), cured() }) })
T.near("2: cured records still attached during immunity cost nothing",
  RLBridge:computeHerdScore("barn1", 1), BASE, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 3. CARRIER ONLY
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({ cow({ carrier() }) })
T.near("3: a symptomless carrier record costs nothing",
  RLBridge:computeHerdScore("barn1", 1), BASE, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 4. MIXED RECORDS: 1 active + 2 cured + 1 carrier = one 0.08 step
-- ══════════════════════════════════════════════════════════

setRitterPresent()
local mixed = { active(), cured(), cured(), carrier() }
setHerd({ cow(mixed) })
T.near("4: mixed records penalize only the one active record",
  RLBridge:computeHerdScore("barn1", 1), BASE - PER_RECORD, 1e-6)

-- Read-only fence: the reader never writes into the RL records.
T.eq("4: the active record is untouched", mixed[1].cured, false)
T.eq("4: the cured record is untouched", mixed[2].cured, true)
T.eq("4: the carrier record is untouched", mixed[4].isCarrier, true)
T.eq("4: no record was added or removed", #mixed, 4)

-- A record with the fields simply absent (older provider, or a bare table) still
-- counts as active: absence of `cured` is not a cure.
setRitterPresent()
setHerd({ cow({ {} }) })
T.near("4: a record with neither flag set counts as active",
  RLBridge:computeHerdScore("barn1", 1), BASE - PER_RECORD, 1e-6)

-- Two cows: the herd average must reflect per-animal filtering, not a herd total.
setRitterPresent()
setHerd({ cow({ active(), active() }), cow({ cured(), carrier() }) })
T.near("4: per-animal filtering averages across the herd",
  RLBridge:computeHerdScore("barn1", 1), ((BASE - 2 * PER_RECORD) + BASE) / 2, 1e-6)

-- ══════════════════════════════════════════════════════════
-- 5. PROVIDER ABSENT
-- ══════════════════════════════════════════════════════════

setRitterAbsent()
setHerd({ cow({ active(), active(), active() }) })
T.eq("5: with the provider absent the bridge reads nothing",
  RLBridge:computeHerdScore("barn1", 1), nil)

local m = DairyCoreManager.new()
m.barns["barn1"] = { barnId = "barn1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
m:_updateBarnHealth(m.barns["barn1"])
T.eq("5: the barn falls back to Standard mode", m.barns["barn1"].ritterMode, false)
T.ok("5: Standard mode still yields a numeric score",
  type(m.barns["barn1"].herdHealthScore) == "number")

-- ══════════════════════════════════════════════════════════
-- 6. THE 0.40 CAP STILL APPLIES TO 6+ ACTIVE RECORDS
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({ cow({ active(), active(), active(), active(), active(), active() }) })
T.near("6: six active records hit the 0.40 cap",
  RLBridge:computeHerdScore("barn1", 1), BASE - CAP, 1e-6)

setRitterPresent()
setHerd({ cow({ active(), active(), active(), active(), active(), active(), active(), active() }) })
T.near("6: eight active records do not exceed the cap",
  RLBridge:computeHerdScore("barn1", 1), BASE - CAP, 1e-6)

-- Cured and carrier records must not count toward the cap either: 4 active + 4
-- cured is 0.32, not 0.40.
setRitterPresent()
setHerd({ cow({ active(), active(), active(), active(), cured(), cured(), cured(), cured() }) })
T.near("6: inactive records do not push the penalty toward the cap",
  RLBridge:computeHerdScore("barn1", 1), BASE - 4 * PER_RECORD, 1e-6)
