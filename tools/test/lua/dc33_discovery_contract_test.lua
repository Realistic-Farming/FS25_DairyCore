-- dc33_discovery_contract_test.lua - DC-33, BARN DISCOVERY CONTRACT.
--
-- The symptom this member locks: dairy barns did not show on the Farm Tablet or
-- the RF PDA because the per-frame retry driver never ran, so discovery ran once
-- at mission load (before the placeable list was populated) and stayed at 0 barns.
-- The fix moved the per-frame carrier to the verified g_currentMission:addUpdateable
-- pattern. This test locks the discovery CONTRACT itself so the retry, once it
-- runs, registers exactly the placeables that are dairy barns and nothing else:
--
--   * a husbandry with the milk spec (a base cowHusbandryBarnMilk barn: cowBarnMedium
--     and cowBarnMedium02B both carry it) registers to its owning farm,
--   * a husbandry without the milk spec never registers,
--   * a milk husbandry whose owner is a reserved engine farm id (the preplaced
--     farmId=0 case) is skipped and named on the first pass,
--   * a placeable with no unique id is skipped and named on the first pass.
--
-- This is the backend half of the fix; the runtime half (does the updateable fire)
-- is a log.txt check after a full game restart with the deployed build.
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/DairyCoreManager.lua

local function newManager()
  local mgr = DairyCoreManager.new()
  mgr.disabled = false
  -- discovery first pass: _discoveryRetries is nil -> the skip diagnostics fire
  return mgr
end

-- a real base-game milk cow barn: cowHusbandryBarnMilk carries spec_husbandryMilk
local function milkBarn(uniqueId, farmId)
  return {
    spec_husbandryMilk = {},
    getUniqueId     = function() return uniqueId end,
    getOwnerFarmId  = function() return farmId end,
  }
end

-- a cow barn that is NOT a milk barn (e.g. cowHusbandryobjectStorage: no milk spec)
local function plainHusbandry(uniqueId, farmId)
  return {
    spec_husbandry = {},
    getUniqueId    = function() return uniqueId end,
    getOwnerFarmId = function() return farmId end,
  }
end

-- preplaced barn: owner is the engine's reserved farm 0
local function preplacedMilkBarn(uniqueId)
  local p = milkBarn(uniqueId, 0)
  return p
end

-- farm 1 is the real single-player farm id (SINGLEPLAYER_FARM_ID), so it must pass
local mgr = newManager()

T.ok("dc33_isDairyBarn accepts cowHusbandryBarnMilk (spec_husbandryMilk)",
  mgr:_isDairyBarn(milkBarn(1, 1)) == true)
T.ok("dc33_isDairyBarn rejects a husbandry without the milk spec",
  mgr:_isDairyBarn(plainHusbandry(2, 1)) == false)
T.ok("dc33_isDairyBarn rejects nil",
  mgr:_isDairyBarn(nil) == false)

-- one milk barn owned by farm 1, one plain husbandry, one preplaced(reserved) milk barn
mgr:_registerBarnsFrom(
  { milkBarn(100, 1), plainHusbandry(200, 1), preplacedMilkBarn(300) },
  nil)

T.eq("dc33 farm-1 milk barn registers", mgr.barns[100] ~= nil, true)
T.eq("dc33 registered barn carries owner farm 1", mgr.barns[100] and mgr.barns[100].farmId, 1)
T.ok("dc33 non-milk husbandry does not register", mgr.barns[200] == nil)
T.ok("dc33 reserved-farm (preplaced) milk barn does not register", mgr.barns[300] == nil)

-- the registered count matches: 100 only
local n = 0
for _ in pairs(mgr.barns) do n = n + 1 end
T.eq("dc33 registered barn count", n, 1)

-- a second pass with a placeable that has no unique id must skip it and not crash
local broken = milkBarn(nil, 1)
broken.getUniqueId = function() return nil end
local mgr2 = newManager()
mgr2:_registerBarnsFrom({ broken }, nil)
local n2 = 0
for _ in pairs(mgr2.barns) do n2 = n2 + 1 end
T.eq("dc33 no-unique-id placeable is skipped", n2, 0)

-- a later retry pass (retries set) re-registers a live barn and keeps counts sane
local mgr3 = newManager()
mgr3._discoveryRetries = 1
mgr3:_registerBarnsFrom({ milkBarn(500, 1) }, nil)
T.eq("dc33 retry pass registers live barn", mgr3.barns[500] ~= nil, true)

-- DC-33 frame gate: _retryDiscovery must not attempt discovery before 30 update
-- frames (so it is dt-independent, per the fix), and must attempt on the 30th.
local mgr4 = newManager()
for _ = 1, 29 do mgr4:_retryDiscovery() end
T.eq("dc33 retry does not attempt before 30 frames", mgr4._discoveryRetries, nil)
mgr4:_retryDiscovery()
T.eq("dc33 retry attempts on the 30th frame", mgr4._discoveryRetries, 1)

T.summary()