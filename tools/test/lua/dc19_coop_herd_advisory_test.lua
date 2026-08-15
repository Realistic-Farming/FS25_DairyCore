-- dc19_coop_herd_advisory_test.lua - DC-19 THE CO-OP HERD ADVISORY (DAIRYCORE HALF).
--
-- The advisory is a formatted read of state that already exists, gated by ProStaff's
-- hasHerdAdvisory flag (L12, delivered on the ProStaffCoOp side). DairyCore only
-- reads the flag through its accessor and formats barn state for display: herd health
-- at or below the needs-attention cutoff (reused from the QUALITY tiering constant,
-- never a new number) or a spoilage stage that is Ageing or worse (DC-8 lifecycle).
-- Advisory-only: no write, no money, no economics.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

-- ── Engine mock ─────────────────────────────────────────────
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

local function newManager()
  local m = DairyCoreManager.new()
  m.disabled = false
  m._markBarnsDirty = function() end
  return m
end

-- The real accessor reads g_currentMission.proStaffManager and calls ps[getterName].
-- Flipping this table's hasHerdAdvisory is mocking the ONE ProStaff surface DC-19 reads.
local function setGate(gate)
  g_currentMission.proStaffManager = { hasHerdAdvisory = function() return gate end }
end

local function barnState(over)
  local b = {
    barnId = "b1", farmId = 1,
    herdHealthScore = 73, milkQualityTier = "standard",
    spoilageStatus = DairyConstants.SPOILAGE.STAGES.fresh.key,
    _spoilageTierDrop = 0, mycotoxinPenalty = 0, feedSourceFields = {},
  }
  for k, v in pairs(over or {}) do b[k] = v end
  return b
end

local function advisoryBarnIds(m)
  local out = {}
  for _, s in ipairs(m:getHerdAdvisories()) do
    out[#out + 1] = (s:match("^Barn ([^:]+):")) or s
  end
  table.sort(out)
  return out
end

-- ══════════════════════════════════════════════════════════
-- BAR 1: THE GATE IS BINARY ON THE FLAG
-- ══════════════════════════════════════════════════════════

-- Gate true -> populated. Gate false -> empty regardless of barn state.
local m1 = newManager()
setGate(true)
m1.barns["b1"] = barnState({ barnId = "b1", herdHealthScore = 20, spoilageStatus = "condemned" })
T.ok("gate true publishes the flag getter", m1:hasHerdAdvisory(1) == true)
local list1 = m1:getHerdAdvisories()
T.eq("gate true returns a populated list", #list1, 1)
T.ok("the sentence names the barn", list1[1]:match("^Barn b1:"))

setGate(false)
T.eq("the flag getter reads false below the gate", m1:hasHerdAdvisory(1), false)
T.eq("gate false returns an empty list", #m1:getHerdAdvisories(), 0)

-- ══════════════════════════════════════════════════════════
-- BAR 2: BARN HEALTH AT OR BELOW THE CUTOFF APPEARS
-- The cutoff REUSES the QUALITY tiering constant (Standard's minScore), so the
-- advisory language cannot drift from what _qualityTierForScore already shows.
-- ══════════════════════════════════════════════════════════

local m2 = newManager()
setGate(true)
m2.barns["premium"]  = barnState({ barnId = "premium",  herdHealthScore = 85 })
m2.barns["healthy"]  = barnState({ barnId = "healthy",  herdHealthScore = 70 })
m2.barns["atCutoff"] = barnState({ barnId = "atCutoff", herdHealthScore = 60 })
m2.barns["reduced"]  = barnState({ barnId = "reduced",  herdHealthScore = 35 })
m2.barns["poor"]     = barnState({ barnId = "poor",     herdHealthScore = 0 })

-- The cutoff is EXACTLY the Standard tier's minScore (reuse, not a magic number).
T.eq("the health cutoff reuses the Standard tier boundary",
  m2:_herdAdvisoryCutoff(), DairyConstants.QUALITY.TIERS[2].minScore)
T.eq("the cutoff equals the tiering constant",
  m2:_herdAdvisoryCutoff(), 60)

local ids2 = advisoryBarnIds(m2)
T.eq("only barns at or below the cutoff appear", #ids2, 3)
T.eq("the barn at the cutoff appears", ids2[1], "atCutoff")
T.eq("the poor barn appears", ids2[2], "poor")
T.eq("the reduced barn appears", ids2[3], "reduced")
T.eq("a healthy barn is not flagged", (function()
  for _, id in ipairs(ids2) do if id == "healthy" then return false end end
  return true
end)(), true)
T.eq("a premium barn is not flagged", (function()
  for _, id in ipairs(ids2) do if id == "premium" then return false end end
  return true
end)(), true)

-- ══════════════════════════════════════════════════════════
-- BAR 3: TERMINAL SPOILAGE STAGES APPEAR, EARLIER STAGES DO NOT
-- Health kept high so only the spoilage condition can qualify a barn.
-- ══════════════════════════════════════════════════════════

local m3 = newManager()
setGate(true)
m3.barns["fresh"]     = barnState({ barnId = "fresh",     herdHealthScore = 90, spoilageStatus = "fresh" })
m3.barns["ageing"]    = barnState({ barnId = "ageing",    herdHealthScore = 90, spoilageStatus = "ageing" })
m3.barns["atrisk"]    = barnState({ barnId = "atrisk",    herdHealthScore = 90, spoilageStatus = "atrisk" })
m3.barns["condemned"] = barnState({ barnId = "condemned", herdHealthScore = 90, spoilageStatus = "condemned" })

local ids3 = advisoryBarnIds(m3)
T.eq("ageing, at risk and condemned appear", #ids3, 3)
T.eq("the ageing barn appears", ids3[1], "ageing")
T.eq("the at risk barn appears", ids3[2], "atrisk")
T.eq("the condemned barn appears", ids3[3], "condemned")
T.ok("fresh is excluded", (function()
  for _, id in ipairs(ids3) do if id == "fresh" then return false end end
  return true
end)(), true)

-- ══════════════════════════════════════════════════════════
-- BAR 4: NO WRITE OCCURS
-- self.barns, self.contracts and money state are bit-identical before and after.
-- ══════════════════════════════════════════════════════════

local m4 = newManager()
setGate(true)
m4.barns["sick"]    = barnState({ barnId = "sick",    herdHealthScore = 30, spoilageStatus = "ageing" })
m4.barns["healthy"] = barnState({ barnId = "healthy", herdHealthScore = 90, spoilageStatus = "fresh" })
m4.contracts[1] = { contractId = 1, barnId = "sick", farmId = 1, delivered = 0 }
g_currentMission.money[1] = { income = 100, farmId = 1 }

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepCopy(v) end
  return c
end

local barnsBefore = deepCopy(m4.barns)
local contractsBefore = deepCopy(m4.contracts)
local moneyBefore = deepCopy(g_currentMission.money)
local countBefore = #m4:getHerdAdvisories()

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

T.eq("the advisory read ran", countBefore, 1)
T.ok("barns are untouched", equalTables(m4.barns, barnsBefore))
T.ok("contracts are untouched", equalTables(m4.contracts, contractsBefore))
T.ok("money is untouched", equalTables(g_currentMission.money, moneyBefore))

-- ══════════════════════════════════════════════════════════
-- BAR 5: EMPTY LIST WHEN THE GATE IS FALSE, REGARDLESS OF BARN STATE
-- ══════════════════════════════════════════════════════════

local m5 = newManager()
setGate(false)
m5.barns["sick"] = barnState({ barnId = "sick", herdHealthScore = 0, spoilageStatus = "condemned" })
T.eq("a terminal barn still yields an empty list below the gate", #m5:getHerdAdvisories(), 0)

-- And the missing-ProStaff case: no proStaffManager at all -> the accessor falls
-- back to neutral-false, exactly the designed fail-closed shape.
g_currentMission.proStaffManager = nil
T.eq("no ProStaff handle reads neutral-false", m5:hasHerdAdvisory(1), false)
T.eq("no ProStaff handle yields an empty list", #m5:getHerdAdvisories(), 0)

-- ══════════════════════════════════════════════════════════
-- FARM FILTERING: the getter honours farmId
-- ══════════════════════════════════════════════════════════

local m6 = newManager()
setGate(true)
m6.barns["mine"]   = barnState({ barnId = "mine",   farmId = 1, herdHealthScore = 10 })
m6.barns["theirs"] = barnState({ barnId = "theirs", farmId = 2, herdHealthScore = 10 })
local mine = m6:getHerdAdvisories(1)
T.eq("farm 1 sees only its own barn", #mine, 1)
T.ok("farm 1's advisory names its barn", mine[1]:match("Barn mine:"))
T.eq("farm 2 sees only its own barn", #m6:getHerdAdvisories(2), 1)

T.summary()
