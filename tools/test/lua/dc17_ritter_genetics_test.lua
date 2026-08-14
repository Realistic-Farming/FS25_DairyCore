-- dc17_ritter_genetics_test.lua - DC-17, DEEPER USE OF RITTER GENETICS.
--
-- Pins the re-scoped design from the DC-17 build brief (fold 2026-08-05): for each
-- Ritter-mode barn, one atomic per-animal read of `health` and
-- `genetics.productivity` together; either field missing means that animal
-- contributes NOTHING to the genetics-weighted average this pass (all-or-nothing,
-- never partial credit). The barn is graded on the AVERAGE, not the peak, and the
-- genetics term is the named (Engineering-tuned, not measured)
-- DairyConstants.HERD.RITTER_GENETICS_WEIGHT times the herd-average normalized
-- productivity gene. The reads are pcall-wrapped so a throwing RL field is caught
-- and the rest of the herd still contributes.
--
-- Bench bars, by brief section 7: 1 all-or-nothing atomic read, 2 average-not-peak,
-- 4a all-fail fallback, 4b weighting-constant effect, 5 the RLBridge.active gate,
-- 6 the uninstall fallback (announce once, re-announce on a second uninstall),
-- 7 pcall wrapping. Plus the two things the flag has to survive to make the
-- uninstall fallback possible: the StateLedger serialize path and the wire record.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/RLBridge.lua, src/DairyCoreManager.lua

local W = DairyConstants.HERD.RITTER_GENETICS_WEIGHT

local function normProd(raw)
  return math.max(0, math.min(1, (raw - 0.25) / 1.5))
end

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

local function bareBarn()
  return { barnId = "barn1", farmId = 1, feedSourceFields = {}, mycotoxinPenalty = 0 }
end

-- ══════════════════════════════════════════════════════════
-- 7.1. THE ALL-OR-NOTHING ATOMIC READ
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({
  { health = 80, genetics = { productivity = 0.9 } },  -- both fields: contributes fully
  { genetics = { productivity = 0.8 } },                 -- missing health: contributes NOTHING
})
local contrib = RLBridge:computeGeneticsContribution("barn1", 1)
T.ok("7.1: the atomic read returns a contribution", contrib ~= nil)
T.eq("7.1: only the complete animal contributes", contrib.contributing, 1)
T.eq("7.1: the missing-field animal still counts toward the herd", contrib.total, 2)
T.near("7.1: the term is the weight times the surviving average",
  contrib.term, W * normProd(0.9), 1e-6)

-- ══════════════════════════════════════════════════════════
-- 7.2. AVERAGE, NOT PEAK
-- ══════════════════════════════════════════════════════════
-- One elite animal among an ordinary herd must not lift the grade to elite.

setRitterPresent()
setHerd({
  { health = 60, genetics = { productivity = 0.9 } },  -- the one prize cow
  { health = 60, genetics = { productivity = 0.4 } },
  { health = 60, genetics = { productivity = 0.4 } },
  { health = 60, genetics = { productivity = 0.4 } },
  { health = 60, genetics = { productivity = 0.4 } },
})
local contrib2 = RLBridge:computeGeneticsContribution("barn1", 1)
local meanGene = (normProd(0.9) + 4 * normProd(0.4)) / 5
T.near("7.2: the contribution is the herd AVERAGE, not the peak",
  contrib2.term, W * meanGene, 1e-6)

-- End to end: crank the weight so a peak-based grade WOULD cross into Premium, and
-- assert the mean-based grade does not.
local origW = W
DairyConstants.HERD.RITTER_GENETICS_WEIGHT = 100
local peakTerm = 100 * normProd(0.9)          -- what a peak grade would add
local m2 = DairyCoreManager.new()
m2.barns["barn1"] = bareBarn()
m2:_updateBarnHealth(m2.barns["barn1"])
local base2 = m2.barns["barn1"].herdHealthScore - 100 * meanGene
T.eq("7.2: one elite animal does not reach an elite grade",
  m2.barns["barn1"].milkQualityTier, "reduced")
T.ok("7.2: the peak alone would have cleared the premium threshold",
  base2 + peakTerm >= 85)
T.ok("7.2: the source flag is true (usable genetics were read)",
  m2.barns["barn1"].herdHealthScore_RitterSource == true)
DairyConstants.HERD.RITTER_GENETICS_WEIGHT = origW

-- ══════════════════════════════════════════════════════════
-- 7.4a. FALLBACK WHEN EVERY ANIMAL FAILS THE ATOMIC READ
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({ { name = "A" }, { name = "B" } })  -- no health, no genetics at all
T.eq("7.4a: no animal contributes, so the term is nil", RLBridge:computeGeneticsContribution("barn1", 1), nil)

local m3 = DairyCoreManager.new()
m3.barns["barn1"] = bareBarn()
m3:_updateBarnHealth(m3.barns["barn1"])
local dc12base = RLBridge:computeHerdScore("barn1", 1)
T.ok("7.4a: the barn survives with no divide-by-zero", type(m3.barns["barn1"].herdHealthScore) == "number")
T.near("7.4a: the score is DC-12's base score, no genetics term",
  m3.barns["barn1"].herdHealthScore, dc12base, 1e-6)
T.eq("7.4a: the source flag is false (Ritter present, no usable genetics)",
  m3.barns["barn1"].herdHealthScore_RitterSource, false)
T.eq("7.4a: ritterMode still reads true (DC-12 supplied the score)",
  m3.barns["barn1"].ritterMode, true)

-- ══════════════════════════════════════════════════════════
-- 7.4b. THE WEIGHTING CONSTANT'S EFFECT
-- ══════════════════════════════════════════════════════════

setRitterPresent()
setHerd({
  { health = 70, genetics = { productivity = 0.6 } },
  { health = 80, genetics = { productivity = 0.8 } },
})
local contrib3 = RLBridge:computeGeneticsContribution("barn1", 1)
local knownAvg = (normProd(0.6) + normProd(0.8)) / 2
T.near("7.4b: the weighted contribution is the constant times the average",
  contrib3.term, W * knownAvg, 1e-6)
local origW2 = W
DairyConstants.HERD.RITTER_GENETICS_WEIGHT = origW2 * 2
local contrib4 = RLBridge:computeGeneticsContribution("barn1", 1)
T.near("7.4b: doubling the constant doubles the term", contrib4.term, contrib3.term * 2, 1e-6)
DairyConstants.HERD.RITTER_GENETICS_WEIGHT = origW2
T.ok("7.4b: the constant is a named, positive Engineering value", type(W) == "number" and W > 0)

-- ══════════════════════════════════════════════════════════
-- 7.5. THE RLBRIDGE.ACTIVE GATE
-- ══════════════════════════════════════════════════════════

setRitterAbsent()
local geneticsCalls = 0
local origG = RLBridge.computeGeneticsContribution
RLBridge.computeGeneticsContribution = function() geneticsCalls = geneticsCalls + 1; return nil end
local m5 = DairyCoreManager.new()
m5.barns["barn1"] = bareBarn()
m5:_updateBarnHealth(m5.barns["barn1"])
T.eq("7.5: no genetics read is attempted when RL is absent", geneticsCalls, 0)
T.eq("7.5: the source flag is false in Standard mode", m5.barns["barn1"].herdHealthScore_RitterSource, false)
T.eq("7.5: Standard mode resolves the score", m5.barns["barn1"].herdHealthScore, 60)
RLBridge.computeGeneticsContribution = origG

-- ══════════════════════════════════════════════════════════
-- 7.6. THE UNINSTALL FALLBACK
-- ══════════════════════════════════════════════════════════

local warnings = 0
local origWarning = Logging.warning
Logging.warning = function(...) warnings = warnings + 1 end

-- A barn whose STORED flag says the deeper genetics ran last load, now without RL.
setRitterAbsent()
local m6 = DairyCoreManager.new()
m6.barns["barn1"] = bareBarn()
m6.barns["barn1"].herdHealthScore_RitterSource = true
m6:_updateBarnHealth(m6.barns["barn1"])
T.eq("7.6(a): the score reverts to DC-12's Standard formula", m6.barns["barn1"].herdHealthScore, 60)
T.eq("7.6(b): one fallback message is published", warnings, 1)
T.eq("7.6: the stored flag is cleared", m6.barns["barn1"].herdHealthScore_RitterSource, false)

-- A third update, still without RL: no additional message.
m6:_updateBarnHealth(m6.barns["barn1"])
T.eq("7.6(c): no message on a later update while RL stays absent", warnings, 1)

-- Reinstall, then uninstall again: a NEW message on the second uninstall.
setRitterPresent()
setHerd({
  { health = 80, genetics = { productivity = 0.8 } },
  { health = 70, genetics = { productivity = 0.6 } },
})
m6:_updateBarnHealth(m6.barns["barn1"])
T.eq("7.6: reinstall restores the deeper-genetics flag", m6.barns["barn1"].herdHealthScore_RitterSource, true)
setRitterAbsent()
m6:_updateBarnHealth(m6.barns["barn1"])
T.eq("7.6: the second uninstall announces anew", warnings, 2)

Logging.warning = origWarning

-- ══════════════════════════════════════════════════════════
-- 7.7. PCALL WRAPPING: A THROWING FIELD IS CAUGHT
-- ══════════════════════════════════════════════════════════

setRitterPresent()
local boomGenetics = setmetatable({}, { __index = function() error("boom") end })
setHerd({
  { health = 80, genetics = { productivity = 0.9 } },  -- healthy animal
  { health = 80, genetics = boomGenetics },             -- throws on read
})
local contrib7 = RLBridge:computeGeneticsContribution("barn1", 1)
T.ok("7.7: the pcall catches the throw and the read survives", contrib7 ~= nil)
T.eq("7.7: the throwing animal contributes nothing", contrib7.contributing, 1)
local m7 = DairyCoreManager.new()
m7.barns["barn1"] = bareBarn()
m7:_updateBarnHealth(m7.barns["barn1"])
T.ok("7.7: the barn update completes with the surviving data", type(m7.barns["barn1"].herdHealthScore) == "number")

-- ══════════════════════════════════════════════════════════
-- THE FLAG SURVIVES: LEDGER SERIALIZE + THE WIRE RECORD
-- ══════════════════════════════════════════════════════════
-- The uninstall fallback only works if the flag outlives a save, and a client
-- surface can only read it if it crosses the wire.

local s1 = DairyCoreManager.new()
s1.barns["barn1"] = bareBarn()
s1.barns["barn1"].herdHealthScore_RitterSource = true
local payload = s1:_serializeBarns()
local s2 = DairyCoreManager.new()
s2:_deserializeBarns(payload)
T.eq("serialize: the deeper-genetics flag survives a save/load",
  s2.barns["barn1"].herdHealthScore_RitterSource, true)
T.eq("serialize: an old-save barn without the flag loads false",
  s1:_serializeBarns()["barn1"].herdHealthScore_RitterSource, true)

local w1 = DairyCoreManager.new()
w1.barns["barn1"] = bareBarn()
w1.barns["barn1"].herdHealthScore_RitterSource = true
w1.barns["barn1"].herdHealthScore = 70
w1.barns["barn1"].milkQualityTier = "standard"
local arr = w1:_onWriteBarnState()
T.eq("wire: the record is exactly the stride", #arr, DairyConstants.NETWORK.BARN_STRIDE)
local w2 = DairyCoreManager.new()
w2.barns["barn1"] = bareBarn()
w2:_onReadBarnState(arr)
T.eq("wire: the deeper-genetics flag crosses the wire", w2.barns["barn1"].herdHealthScore_RitterSource, true)

-- restore the bridge for whatever runs after this file
setRitterAbsent()
