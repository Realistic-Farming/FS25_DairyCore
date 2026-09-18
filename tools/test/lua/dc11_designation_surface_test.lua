-- dc11_designation_surface_test.lua - DC-11, THE FEED-FIELD DESIGNATION SURFACE.
--
-- The mechanism was built and merged (designate/undesignate, persistence, the
-- mode-independent modifier layer, F106). This test pins the read API the surface
-- is built on and the write gate the surface calls into, so the picker can never
-- drift from the functions it is supposed to drive:
--
--   * designateFeedField / undesignateFeedField mutate feedSourceFields
--   * both are server-gated (a client write must refuse)
--   * getBarnDesignations returns the sorted set + count
--   * getOwnedFeedFields enumerates only the farm's own fields and attaches the
--     live SF state the readout shows (the same read the score eats)
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

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
    feedSourceFields = opts.fields or {},
  }
end

-- ── Field stubs: g_fieldManager.fields + g_farmlandManager + SF soilSystem ──
g_fieldManager = {
  fields = {
    { farmland = { id = 7 } },
    { farmland = { id = 12 } },
    { farmland = { id = 99 } },
  },
}
g_farmlandManager = {
  getFarmlandOwner = function(self, fid)
    if fid == 7 then return 1 end
    if fid == 12 then return 1 end
    if fid == 99 then return 2 end
    return 0
  end,
}
-- SoilFertilizer-shaped read the manager hops to via .soilSystem.
g_currentMission.soilFertilityManager = {
  soilSystem = {
    getFieldInfo = function(_, fieldId)
      if fieldId == 7 then
        return {
          organicMatter = 4.2,
          nitrogen = { value = 60, status = "Good" },
          phosphorus = { value = 40, status = "Good" },
          potassium = { value = 55, status = "Good" },
          weedPressure = 20,
          rotationStatus = "legume",
          diseasePressure = 0,
        }
      elseif fieldId == 12 then
        return {
          organicMatter = 1.8,
          nitrogen = { value = 20, status = "Poor" },
          phosphorus = { value = 30, status = "Fair" },
          potassium = { value = 25, status = "Poor" },
          weedPressure = 70,
          rotationStatus = "grass",
          diseasePressure = 40,
        }
      end
      return nil
    end,
  },
}

-- ══════════════════════════════════════════════════════════
-- SERVER GATE
-- ══════════════════════════════════════════════════════════
asServer(true)
local server = newManager()
server.barns["barn_A"] = barn("barn_A", { fields = { [7] = true } })

T.ok("server designate returns true", server:designateFeedField("barn_A", 12) == true)
T.ok("designate wrote the field", server.barns["barn_A"].feedSourceFields[12] == true)

asServer(false)
T.ok("client designate refuses", server:designateFeedField("barn_A", 99) == false)
T.ok("client designate did not write", server.barns["barn_A"].feedSourceFields[99] == nil)
T.ok("client undesignate refuses", server:undesignateFeedField("barn_A", 7) == false)
T.ok("client undesignate did not remove", server.barns["barn_A"].feedSourceFields[7] == true)

asServer(true)
T.ok("server undesignate returns true", server:undesignateFeedField("barn_A", 7) == true)
T.ok("undesignate removed the field", server.barns["barn_A"].feedSourceFields[7] == nil)

-- ══════════════════════════════════════════════════════════
-- getBarnDesignations: sorted set + count
-- ══════════════════════════════════════════════════════════
server.barns["barn_A"].feedSourceFields = { [12] = true, [7] = true, [3] = true }
local ids, n = server:getBarnDesignations("barn_A")
T.eq("count is three", n, 3)
T.eq("ids sorted ascending", ids[1] == 3 and ids[2] == 7 and ids[3] == 12, true)
T.ok("unknown barn reads empty", select(2, server:getBarnDesignations("nope")) == 0)

-- ══════════════════════════════════════════════════════════
-- getOwnedFeedFields: only this farm's fields, with live state
-- ══════════════════════════════════════════════════════════
local owned = server:getOwnedFeedFields(1)
T.eq("farm 1 owns two of the three fields", #owned, 2)
T.eq("first owned field is 7", owned[1].fieldId, 7)
T.eq("second owned field is 12", owned[2].fieldId, 12)
T.eq("field 7 organic matter attaches", owned[1].organicMatter, 4.2)
T.eq("field 7 nitrogen status attaches", owned[1].nitrogen.status, "Good")
T.eq("field 12 weed pressure attaches", owned[2].weedPressure, 70)
T.eq("field 12 disease pressure attaches", owned[2].diseasePressure, 40)
T.eq("field 7 rotation status attaches", owned[1].rotationStatus, "legume")

local none = server:getOwnedFeedFields(42)
T.eq("unowned farm reads empty", #none, 0)

-- farmId 0 / nil must read empty rather than throw
T.eq("nil farm reads empty", #server:getOwnedFeedFields(nil), 0)
T.eq("zero farm reads empty", #server:getOwnedFeedFields(0), 0)

-- ── Absent SF: no live state, but the field still enumerates (owner-known) ──
local savedSf = g_currentMission.soilFertilityManager
g_currentMission.soilFertilityManager = nil
local degraded = server:getOwnedFeedFields(1)
T.eq("fields still enumerate without SF", #degraded, 2)
T.eq("absent SF yields nil organic matter", degraded[1].organicMatter, nil)
g_currentMission.soilFertilityManager = savedSf
