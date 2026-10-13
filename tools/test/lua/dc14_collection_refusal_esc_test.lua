-- dc14_collection_refusal_esc_test.lua - DC-14 host slice C: the complete standalone Esc
-- floor's DATA binding (brief v1.0 section 6, SDS v0.9; Wizard brief section 3, the
-- craft is Wizard's).
--
-- THE ENTRY-POINT BAR IS GROUP S. The manager is built by DairyCoreManager.new() and
-- enters through onMissionLoaded and the real hour tick (the refusal comes from RSF-F216's
-- real fee gate); the Dairy Esc guest registers itself on the REAL RfEscModules registry
-- through DairyRfPdaGuest.tryRegister, the registry selects it, and the bar drives the
-- registered descriptor exactly as the host page does: onShow(container) on a show,
-- onLightTick(container) on the 2 s tick, onSheetRow(index) from onClickFwSheetRow. The
-- door is MODELED: elements by id with setText and setVisible, and the shared SmoothList
-- whose reloadData asks the data source for its rows and cells, the engine contract
-- (SmoothListElement: getNumberOfItemsInSection, populateCellForItemInSection). Nothing
-- writes a row, a selection, a band or a demand mark by hand.
--
-- Groups:
--   S  the entry-point bar: the sheet from the getter, headings, cells, the band on a
--      click, the side rail, no card and no pager id touched
--   L  the light tick: no reload without a change (the thrash fence), a reload and a
--      changed cell when the round leaves a new refusal, the selection surviving
--   X  the selection clears: the row disappears, another module takes the door
--   C  a pure client: updating, the demand mark and one DIRECT request on show, the
--      mark ended by the registry listener
--   G  the states: settings off, no real farm, PF stand-down; the empty farm
--   F  the strict farm changes under the sheet: the other farm's rows, no selection
--   T  MAINTENANCE row 99: the three translation helpers (the guest's tr, the manager's
--      _tr, the Field Guide's tr) under an i18n modelled on I18N.lua and mods.lua:453: a
--      real text beginning "Missing" renders, an absent key renders the fallback (never
--      the engine's "Missing '<key>'" sentence), a translation renders
--
--!load: src/Logger.lua, src/DairyConstants.lua, src/FeedProvenance.lua, src/MilkTank.lua, src/DairyCoreManager.lua, src/DairyCollectionRefusal.lua, src/network/DairyCollectionStatusEvents.lua, src/DairyCollectionRoute.lua, src/gui/RfEscModules.lua, src/gui/DairyRfPdaGuest.lua, src/gui/DairyGuideDialog.lua

getfenv = getfenv or function() return _G end
local MILK_NAME = DairyConstants.CONTRACTS.MILK_FILLTYPE
local MILK_INDEX = 1

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine world (as the transport bar models it) ────────────────────────
FarmManager = { MAX_NUM_FARMS = 8, MAX_FARM_ID = 8, SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1,
  GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
MoneyType = { OTHER = 1 }
XMLFile = { loadIfExists = function() return nil end }
MessageType = { PLAYER_FARM_CHANGED = 25 }
function getWorldTranslation(node) return node.x, node.y, node.z end
g_modIsLoaded = {}
g_fillTypeManager = {
  getFillTypeIndexByName = function(_, name) if name == MILK_NAME then return MILK_INDEX end return 0 end,
  getFillTypeByIndex = function() return { pricePerLiter = 1.0 } end,
}
local function setPrice(p) g_fillTypeManager.getFillTypeByIndex = function() return { pricePerLiter = p } end end
g_messageCenter = { subs = {} }
function g_messageCenter:subscribe(mt, fn, target) self.subs[#self.subs + 1] = { mt = mt, fn = fn, target = target } end
function g_messageCenter:unsubscribe(mt, target)
  for i = #self.subs, 1, -1 do
    if self.subs[i].mt == mt and self.subs[i].target == target then table.remove(self.subs, i) end
  end
end
function g_messageCenter:unsubscribeAll(target)
  for i = #self.subs, 1, -1 do if self.subs[i].target == target then table.remove(self.subs, i) end end
end
function g_messageCenter:publish(mt, arg)
  for _, s in ipairs(self.subs) do if s.mt == mt then s.fn(s.target, arg) end end
end

local function newMission(isServer, localFarm)
  local ticks = {}
  local m = {
    _isServer = isServer, _localFarm = localFarm,
    missionInfo = { savegameDirectory = "savegame1" },
    missionDynamicInfo = { isMultiplayer = true },
    environment = { currentDay = 100, dayTime = 6 * 3600 * 1000 },
    placeableSystem = { placeables = {} },
    money = {},
    timeGuard = { subscribeTick = function(_, kind, name, fn) ticks[kind] = fn end },
    _ticks = ticks,
    workerCostsManager = { getRosterSnapshot = function()
      return { workers = { { uuid = "w1", lifecycleState = "hired", levelName = "experienced" } } } end },
  }
  function m:getIsServer() return self._isServer end
  function m.placeableSystem:getPlaceableByUniqueId(id)
    for _, p in ipairs(self.placeables) do
      if p:getUniqueId() == id then return p end
    end
    return nil
  end
  function m:getFarmId(connection)
    if connection ~= nil then return connection.farmId end
    return self._localFarm
  end
  function m:addMoney(income, farmId) self.money[#self.money + 1] = { income = income, farmId = farmId } end
  return m
end

local function makeBarn(id, owner, litres, opts)
  opts = opts or {}
  local storage = { fillTypes = { [MILK_INDEX] = true }, fillLevels = { [MILK_INDEX] = litres }, listeners = {} }
  function storage:getIsFillTypeSupported(ft) return self.fillTypes[ft] == true end
  function storage:getFillLevel(ft) return self.fillLevels[ft] or 0 end
  function storage:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function storage:removeFillLevelChangedListeners() end
  local station = { fillLevels = { [MILK_NAME] = litres }, listeners = {} }
  function station:addFillLevelChangedListeners(fn) self.listeners[#self.listeners + 1] = fn end
  function station:removeFillLevelChangedListeners() end
  local p = { spec_husbandryMilk = {}, spec_husbandry = { storage = storage, unloadingStation = station },
    rootNode = { x = 0, y = 0, z = 0 }, _owner = owner, _name = opts.name or ("Barn " .. id) }
  function p:getUniqueId() return id end
  function p:getOwnerFarmId() return self._owner end
  function p:getName() return self._name end
  function p:removeHusbandryFillLevel(farmId, delta, ft)
    local cur = storage.fillLevels[MILK_INDEX] or 0
    local removed = math.min(delta, cur)
    storage.fillLevels[MILK_INDEX] = cur - removed
    station.fillLevels[MILK_NAME] = cur - removed
    return delta - removed
  end
  p._storage = storage
  return p
end

--- Run fn with this machine's globals in place.
local function on(machine, fn)
  local sm, smgr, sc, ss, menu = g_currentMission, g_dairyCoreManager, g_client, g_server, g_inGameMenu
  g_currentMission, g_dairyCoreManager, g_client, g_server = machine.mission, machine.mgr, machine.client, machine.server
  g_inGameMenu = { menuRealisticFarming = machine.door }
  local ok, err = pcall(fn)
  g_currentMission, g_dairyCoreManager, g_client, g_server, g_inGameMenu = sm, smgr, sc, ss, menu
  if not ok then error(err, 0) end
end

-- ── the door, modeled ─────────────────────────────────────────────────────────
local RULE_IDS = { "rfFwRuleHead", "rfFwRuleRow1", "rfFwRuleRow2", "rfFwRuleRow3", "rfFwRuleRow4",
  "rfFwRuleRow5", "rfFwRuleRow6", "rfFwRuleRow7", "rfFwRuleCol1", "rfFwRuleCol2", "rfFwRuleCol3" }
local function newDoor()
  local els = {}
  local function el(id)
    local e = { id = id, text = "", visible = nil }
    function e:setText(t) self.text = t end
    function e:setVisible(v) self.visible = v end
    els[id] = e
    return e
  end
  for _, id in ipairs({ "rfHostPlaceholder", "rfFrameworkGlanceShell", "rfFwStatusBlock", "rfFwTableBlock",
      "rfHostBody", "rfHostTitle", "rfHostBlurb", "rfFwTableTitle", "rfFwEmptyHint", "rfFwSheetBox", "rfFwSheetBand",
      "rfSideInfoShell", "rfSideInfoBody", "rfFwColA", "rfFwColB", "rfFwColC", "rfFwColD", "rfFwMore", "rfFwHintTable",
      "rfDairyCardsHint" }) do el(id) end
  for i = 1, 8 do for _, c in ipairs({ "A", "B", "C", "D" }) do el("rfFwRow" .. i .. c) end end
  for _, id in ipairs(RULE_IDS) do el(id) end
  for slot = 1, 4 do el("rfDairyCard" .. slot) end
  -- The shared SmoothList: reloadData asks the data source, as SmoothListElement does.
  local list = el("rfFwSheetList")
  list.isLoaded, list.cells, list.reloads = true, {}, 0
  function list:setDataSource(ds) self.dataSource = ds end
  function list:setDelegate(d) self.delegate = d end
  function list:reloadData()
    self.reloads = self.reloads + 1
    self.cells = {}
    local n = self.dataSource:getNumberOfItemsInSection(self, 1)
    for i = 1, n do
      local cell = { parts = {} }
      for _, name in ipairs({ "rfFwSheetA", "rfFwSheetB", "rfFwSheetC", "rfFwSheetD" }) do
        local part = { text = "" }
        function part:setText(t) self.text = t end
        cell.parts[name] = part
      end
      function cell:getDescendantByName(name) return self.parts[name] end
      self.dataSource:populateCellForItemInSection(self, 1, i, cell)
      self.cells[i] = cell
    end
  end
  local container = { els = els, list = list }
  function container:getDescendantById(id) return self.els[id] end
  return container
end

--- A machine: its mission, its door, its manager booted through onMissionLoaded and one
--- frame of update, the manager published on the mission as main.lua publishes it.
local function newMachine(opts)
  local mc = { sent = 0 }
  mc.mission = newMission(opts.isServer == true, opts.localFarm)
  for _, p in ipairs(opts.placeables or {}) do
    mc.mission.placeableSystem.placeables[#mc.mission.placeableSystem.placeables + 1] = p
  end
  if opts.isServer then
    mc.server = { broadcastEvent = function() end }
  else
    local conn = { getIsServer = function() return true end, sendEvent = function() mc.sent = mc.sent + 1 end }
    mc.client = { getServerConnection = function() return conn end }
  end
  mc.door = newDoor()
  mc.mgr = DairyCoreManager.new()
  mc.mgr.settings.saleFeePer1000L = opts.feePer1000 or DairyConstants.SALE.FEE_PER_1000L
  if opts.settingsOff then mc.mgr.settings.enabled = false end
  mc.mission.dairyCoreManager = mc.mgr
  on(mc, function()
    if opts.pf then g_modIsLoaded["FS25_precisionFarming"] = true end
    mc.mgr:onMissionLoaded()
    g_modIsLoaded["FS25_precisionFarming"] = nil
    mc.mgr:update(16)
  end)
  return mc
end

local function serverRound(server, barnId, days)
  on(server, function()
    if barnId ~= nil then server.mgr:assignCollectionWorker(barnId, "w1") end
    server.mission.environment.currentDay = server.mission.environment.currentDay + (days or 1)
    server.mission._ticks.hour({ monotonicDay = server.mission.environment.currentDay })
  end)
end

--- The guest through the registry, as the host page reaches it: register, select, and the
--- registered descriptor's handlers.
local function registerGuest(machine)
  local ok
  on(machine, function()
    DairyRfPdaGuest.reset()
    ok = DairyRfPdaGuest.tryRegister()
  end)
  return ok
end
local function host(machine)
  local h
  on(machine, function() h = RfEscModules.getOrCreate() end)
  return h
end
local function selectDairy(machine)
  local ok
  on(machine, function() ok = RfEscModules.getOrCreate():selectModule("dairy") end)
  return ok
end
local function active(machine)
  local a
  on(machine, function() a = RfEscModules.getOrCreate():getActivePanel() end)
  return a
end
local function show(machine)
  on(machine, function() local a = RfEscModules.getOrCreate():getActivePanel(); a.onShow(machine.door, false) end)
end
local function lightTick(machine)
  on(machine, function() local a = RfEscModules.getOrCreate():getActivePanel(); a.onLightTick(machine.door) end)
end
local function clickRow(machine, index)
  on(machine, function() local a = RfEscModules.getOrCreate():getActivePanel(); a.onSheetRow(index) end)
end
local function el(machine, id) return machine.door.els[id] end
local function cellText(machine, i, part) local c = machine.door.list.cells[i]; return c and c.parts[part].text or "nil" end
local function rowLine(machine, i)
  return cellText(machine, i, "rfFwSheetA") .. " | " .. cellText(machine, i, "rfFwSheetB") .. " | " .. cellText(machine, i, "rfFwSheetC") .. " | " .. cellText(machine, i, "rfFwSheetD")
end
local function demandMark(machine) return machine.mgr.collectionRoute ~= nil and machine.mgr.collectionRoute.demand.ESC or nil end

-- ══════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════
group("S", function()
  setPrice(0.05)
  -- Two barns of farm 1 with the same display name, one of farm 2. b1 gets a worker and a
  -- refused round; b2 has no worker and no report.
  local b1 = makeBarn("b1", 1, 500, { name = "North" })
  local b2 = makeBarn("b2", 1, 300, { name = "North" })
  local b3 = makeBarn("b3", 2, 400, { name = "Far" })
  local m = newMachine({ isServer = true, localFarm = 1, placeables = { b1, b2, b3 }, feePer1000 = 50 })
  serverRound(m, "b1", 1)
  T.eq("S0 [world] the server's real round refused b1 with milk in the barn", tostring(m.mgr.collectionRefusal.records.b1.state), "FEE_EXCEEDS_PRICE")
  T.eq("S1 [reached] the guest registered itself on the real registry", tostring(registerGuest(m)) .. "/" .. tostring(host(m).modules.dairy ~= nil), "true/true")
  T.eq("S2 [reached] the registry selected Dairy (it is available on this mission)", tostring(selectDairy(m)), "true")
  local a = active(m)
  T.eq("S3 the registered descriptor carries the sheet row and the light tick, and no pager step", type(a.onSheetRow) .. "/" .. type(a.onLightTick) .. "/" .. tostring(a.onPageStep), "function/function/nil")
  show(m)
  T.eq("S4 the sheet box shows and the list was reloaded from the data source with the farm's two rows, in key order", tostring(el(m, "rfFwSheetBox").visible) .. "/" .. m.door.list.reloads .. "/" .. #m.door.list.cells, "true/1/2")
  T.eq("S5 the first row: the colliding label carries its key suffix, the refused status, the worker and the next due (a day after the refused attempt)", rowLine(m, 1), "North (b1) | Milk left behind | Assigned | day 102 at 06:00")
  T.eq("S6 the second row: no report, no worker, no due", rowLine(m, 2), "North (b2) | No report | None | ")
  T.eq("S7 the other farm's barn is not on the sheet", (function()
    for _, c in ipairs(m.door.list.cells) do if c.parts.rfFwSheetA.text:find("Far", 1, true) then return "shown" end end
    return "absent"
  end)(), "absent")
  T.eq("S8 the four column headings are Dairy's", el(m, "rfFwColA").text .. "/" .. el(m, "rfFwColB").text .. "/" .. el(m, "rfFwColC").text .. "/" .. el(m, "rfFwColD").text, "Barn/Collection/Worker/Next due")
  T.eq("S9 the old fixed rows, the hairlines and the cards are dark; the empty hint is off", tostring(el(m, "rfFwRow1A").visible) .. "/" .. tostring(el(m, "rfFwRuleHead").visible) .. "/" .. tostring(el(m, "rfDairyCard1").visible) .. "/" .. tostring(el(m, "rfFwEmptyHint").visible), "false/false/false/false")
  T.eq("S10 before a click the band is hidden and empty", tostring(el(m, "rfFwSheetBand").visible) .. "/" .. el(m, "rfFwSheetBand").text, "false/")
  clickRow(m, 1)
  local band = el(m, "rfFwSheetBand")
  T.eq("S11 a click on the first row shows the band with the complete past-tense sentence, day and clock", tostring(band.visible) .. "/" .. tostring(band.text:find("At the scheduled collection on day 101 at 06:00, the milk remained because the handling fee met or exceeded the sale price at that attempt.", 1, true) ~= nil), "true/true")
  T.eq("S12 and the next-due truth for the barn with a worker", tostring(band.text:find("Next collection due: day ", 1, true) ~= nil) .. "/" .. tostring(band.text:find("No collection worker", 1, true) ~= nil), "true/false")
  T.eq("S13 the band names the barn by its display label", band.text:sub(1, 10), "North (b1)")
  clickRow(m, 2)
  T.eq("S14 the second row's band: no report this session, and no worker assigned", tostring(band.text:find("No collection-refusal report this session.", 1, true) ~= nil) .. "/" .. tostring(band.text:find("No collection worker is currently assigned.", 1, true) ~= nil), "true/true")
  local rail = el(m, "rfSideInfoBody").text
  T.eq("S15 the side rail carries the barn count and the selected barn's label", tostring(rail:find("Barns: 2", 1, true) ~= nil) .. "/" .. tostring(rail:find("North (b2)", 1, true) ~= nil), "true/true")
  T.eq("S16 [world] nothing was sold, no money moved, no timer changed: the surface is read-only", #m.mission.money .. "/" .. tostring(m.mgr.collectionRefusal.records.b1.state), "0/FEE_EXCEEDS_PRICE")
end)

-- ══════════════════════════════════════════════════════════
-- L. THE LIGHT TICK
-- ══════════════════════════════════════════════════════════
group("L", function()
  setPrice(0.05)
  local b1 = makeBarn("b1", 1, 500)
  local b2 = makeBarn("b2", 1, 300)
  local m = newMachine({ isServer = true, localFarm = 1, placeables = { b1, b2 }, feePer1000 = 50 })
  serverRound(m, "b1", 1)
  registerGuest(m); selectDairy(m); show(m)
  clickRow(m, 2)
  local reloads = m.door.list.reloads
  lightTick(m)
  T.eq("L1 a light tick with nothing changed reloads nothing (the thrash fence) and keeps the selection", (m.door.list.reloads - reloads) .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "0/true")
  -- The next round refuses b2 too.
  serverRound(m, "b2", 1)
  lightTick(m)
  T.eq("L2 a light tick after a new refusal reloads once and the row's cells change", (m.door.list.reloads - reloads) .. "/" .. cellText(m, 2, "rfFwSheetB") .. "/" .. cellText(m, 2, "rfFwSheetC"), "1/Milk left behind/Assigned")
  T.eq("L3 the selection survived, and its band now carries the refusal", tostring(el(m, "rfFwSheetBand").visible) .. "/" .. tostring(el(m, "rfFwSheetBand").text:find("day 102 at 06:00", 1, true) ~= nil), "true/true")
end)

-- ══════════════════════════════════════════════════════════
-- X. THE SELECTION CLEARS
-- ══════════════════════════════════════════════════════════
group("X", function()
  setPrice(0.05)
  local b1 = makeBarn("b1", 1, 500)
  local b2 = makeBarn("b2", 1, 300)
  local m = newMachine({ isServer = true, localFarm = 1, placeables = { b1, b2 }, feePer1000 = 50 })
  serverRound(m, "b1", 1)
  registerGuest(m); selectDairy(m); show(m)
  clickRow(m, 1)
  T.eq("X0 [reached] b1 is selected", tostring(el(m, "rfFwSheetBand").visible), "true")
  -- b1 demolished between two discovery passes: its row goes on the next read.
  m.mission.placeableSystem.placeables = { b2 }
  lightTick(m)
  T.eq("X1 when the selected row disappears the selection clears: the band is hidden and the sheet holds one row", tostring(el(m, "rfFwSheetBand").visible) .. "/" .. #m.door.list.cells, "false/1")
  -- The barn comes back (re-registered): a selection that was only hidden would return with it.
  m.mission.placeableSystem.placeables = { b1, b2 }
  lightTick(m)
  T.eq("X1b when the barn returns the old selection does not: two rows, nothing selected", #m.door.list.cells .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "2/false")
  clickRow(m, 2)
  T.eq("X2 [reached] twin: a row that is still there can be selected", tostring(el(m, "rfFwSheetBand").visible) .. "/" .. cellText(m, 2, "rfFwSheetA"), "true/Barn b2")
  -- Another module takes the door: the registry notifies, Dairy clears.
  on(m, function()
    local h = RfEscModules.getOrCreate()
    h:registerModule({ id = "income", title = "Income", order = 10, isAvailable = function() return true end, onShow = function() end })
    h:selectModule("income")
  end)
  T.eq("X3 when another module takes the door the selection is gone", tostring(el(m, "rfFwSheetBand").visible), "false")
  selectDairy(m); show(m)
  T.eq("X4 [reached] twin: back on Dairy the sheet repaints with no selection", tostring(el(m, "rfFwSheetBox").visible) .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "true/false")
  clickRow(m, 1)
  T.eq("X5 a click past the rows clears a selection", tostring(el(m, "rfFwSheetBand").visible) .. (function() clickRow(m, 9) return "/" .. tostring(el(m, "rfFwSheetBand").visible) end)(), "true/false")
end)

-- ══════════════════════════════════════════════════════════
-- C. A PURE CLIENT
-- ══════════════════════════════════════════════════════════
group("C", function()
  local c = newMachine({ isServer = false, localFarm = 2 })
  registerGuest(c); selectDairy(c)
  T.eq("C0 [world] with no NetworkSync the client's route is DIRECT", tostring(c.mgr.collectionRoute.route), "DIRECT")
  show(c)
  T.eq("C1 before a snapshot the hint reads updating, the sheet is hidden, the band too", el(c, "rfFwEmptyHint").text .. "/" .. tostring(el(c, "rfFwSheetBox").visible) .. "/" .. tostring(el(c, "rfFwSheetBand").visible), "Updating collection status./false/false")
  T.eq("C2 the show pulsed demand: the ESC mark is set and exactly one DIRECT request went out", tostring(demandMark(c) ~= nil) .. "/" .. c.sent, "true/1")
  lightTick(c)
  T.eq("C3 a light tick pulses again without a second request inside the retry pacing", tostring(demandMark(c) ~= nil) .. "/" .. c.sent, "true/1")
  on(c, function()
    local h = RfEscModules.getOrCreate()
    h:registerModule({ id = "income", title = "Income", order = 10, isAvailable = function() return true end, onShow = function() end })
    h:selectModule("income")
  end)
  T.eq("C4 another module taking the door ends the ESC demand at once", tostring(demandMark(c)), "nil")
end)

-- ══════════════════════════════════════════════════════════
-- G. THE STATES
-- ══════════════════════════════════════════════════════════
group("G", function()
  local off = newMachine({ isServer = true, localFarm = 1, placeables = { makeBarn("b1", 1, 500) }, settingsOff = true })
  registerGuest(off); selectDairy(off); show(off)
  T.eq("G1 settings off: the hint says so and the sheet is hidden", el(off, "rfFwEmptyHint").text .. "/" .. tostring(el(off, "rfFwSheetBox").visible), "Dairy simulation is off./false")
  local spec = newMachine({ isServer = true, localFarm = nil, placeables = { makeBarn("b1", 1, 500) } })
  registerGuest(spec); selectDairy(spec); show(spec)
  T.eq("G2 no real farm: the hint asks for a farm", el(spec, "rfFwEmptyHint").text, "Select or join a farm to view collection status.")
  local pf = newMachine({ isServer = true, localFarm = 1, placeables = { makeBarn("b1", 1, 500) }, pf = true })
  registerGuest(pf)
  T.eq("G3 PF stand-down: the module is not available, so the registry refuses to select it", tostring(selectDairy(pf)), "false")
  local none = newMachine({ isServer = true, localFarm = 3 })
  registerGuest(none); selectDairy(none); show(none)
  T.eq("G4 a farm with no barn: no barns, the sheet hidden, no error", el(none, "rfFwEmptyHint").text .. "/" .. tostring(el(none, "rfFwSheetBox").visible), "no barns/false")
end)

-- ══════════════════════════════════════════════════════════
-- F. THE STRICT FARM CHANGES UNDER THE SHEET
-- ══════════════════════════════════════════════════════════
group("F", function()
  setPrice(0.05)
  local b1 = makeBarn("b1", 1, 500)
  local b3 = makeBarn("b3", 2, 400, { name = "Far" })
  local m = newMachine({ isServer = true, localFarm = 1, placeables = { b1, b3 }, feePer1000 = 50 })
  serverRound(m, "b1", 1)
  registerGuest(m); selectDairy(m); show(m)
  clickRow(m, 1)
  T.eq("F0 [reached] farm 1's barn is on the sheet and selected", cellText(m, 1, "rfFwSheetA") .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "Barn b1/true")
  -- The local player switches to farm 2: the manager's synchronous clear runs the guest's
  -- listener inside the handler, so the old farm's paint is gone BEFORE the handler returns
  -- and before any refresh (brief section 8, Bob's verdict on #62).
  m.mission._localFarm = 2
  on(m, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, nil) end)
  T.eq("F0b the farm change clears the sheet, the band and the rail synchronously, before any refresh", tostring(el(m, "rfFwSheetBox").visible) .. "/" .. tostring(el(m, "rfFwSheetBand").visible) .. "/" .. el(m, "rfSideInfoBody").text, "false/false/")
  lightTick(m)
  T.eq("F1 after the switch the sheet holds farm 2's barn only and the selection is gone", #m.door.list.cells .. "/" .. cellText(m, 1, "rfFwSheetA") .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "1/Far/false")
  m.mission._localFarm = 1
  on(m, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, nil) end)
  lightTick(m)
  T.eq("F2 switching back does not bring the old selection back: farm 1's barn, nothing selected", cellText(m, 1, "rfFwSheetA") .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "Barn b1/false")
  -- The barn follows the player to the other farm (sold, then the switch): its row is still
  -- there under farm 2, so only the farm change itself can clear the selection.
  clickRow(m, 1)
  T.eq("F3a [reached] farm 1's barn is selected again", tostring(el(m, "rfFwSheetBand").visible), "true")
  b1._owner = 2
  m.mission._localFarm = 2
  on(m, function() g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, nil) end)
  lightTick(m)
  T.eq("F3 a farm switch clears the selection even when the selected barn came along: its row stands under farm 2, nothing selected", cellText(m, 1, "rfFwSheetA") .. "/" .. tostring(el(m, "rfFwSheetBand").visible), "Barn b1/false")
end)

-- ═══════════════════════════════════════════════════════════
-- T. MAINTENANCE row 99: THE TRANSLATION HELPERS GATE ON hasText
-- ═══════════════════════════════════════════════════════════
--- The engine's i18n as a mod sees it: I18N.lua:149-172 (addModI18N: a table whose texts
--- fall back to the global texts, whose methods are I18N's), :175-191 (getText: the text,
--- else the "Missing '<key>' in l10n<suffix>.xml" sentence) and :194-209 (hasText), and
--- mods.lua:453 (the mod's environment holds it as g_i18n; there is no .i18n). Returned
--- as the value the mod reads for g_i18n.
local function engineModI18n(globalTexts, modTexts)
  local base = { texts = globalTexts or {}, modEnvironments = {} }
  function base:getText(name)
    local ret = self.texts[name]
    if ret == nil then ret = string.format("Missing '%s' in l10n%s.xml", name, "_en") end
    return ret
  end
  function base:hasText(name)
    if name == nil then return false end
    return self.texts[name] ~= nil
  end
  local modi18n = { texts = modTexts or {} }
  setmetatable(modi18n, { __index = base })
  setmetatable(modi18n.texts, { __index = base.texts })
  return modi18n
end

group("T", function()
  local TEXTS = {
    dc14_collection_heading_barn = "Missing herd count",   -- a REAL text that begins "Missing"
    dc14_collection_heading_worker = "Trabajador",          -- a translation
    dc_setting_saleFee = "Missing-litre fee",               -- a real label beginning "Missing"
    dc_guide_saleFee_01 = "Missing milk is charged per litre.",
    dc_guide_saleFee_03 = "Por litro: 0,011 por defecto.",
    -- dc14_collection_heading_status, dc_guide_saleFee_02: absent
  }
  local i18n = engineModI18n({}, TEXTS)
  local savedI18n, savedEnvs = g_i18n, g_modEnvironments
  g_modEnvironments = { FS25_DairyCore = { g_i18n = i18n } }   -- mods.lua:453's field, the only one
  g_i18n = i18n
  local ok, err = pcall(function()
    -- The guest through the real registry: the column headings are painted on every show.
    setPrice(0.05)
    local b1 = makeBarn("b1", 1, 500)
    local m = newMachine({ isServer = true, localFarm = 1, placeables = { b1 }, feePer1000 = 50 })
    registerGuest(m); selectDairy(m); show(m)
    T.eq("T1 the guest renders a real text that begins 'Missing' (the old prefix gate refused it for the English fallback)",
      el(m, "rfFwColA").text, "Missing herd count")
    T.eq("T2 an absent key renders the fallback, never the engine's Missing sentence", el(m, "rfFwColB").text, "Collection")
    T.eq("T3 a translation renders", el(m, "rfFwColC").text, "Trabajador")

    -- The manager's _tr: the sale-fee label SettingsHub receives at the bedrock bind.
    local label
    local mgr2 = DairyCoreManager.new()
    on(m, function()
      g_currentMission.settingsHub = { registerModule = function(_, _id, spec)
        for _, d in ipairs(spec.adminSettings or {}) do if d.id == "saleFeePer1000L" then label = d.label end end
      end }
      mgr2:_bindBedrock()
      g_currentMission.settingsHub = nil
    end)
    T.eq("T4 the manager's _tr hands SettingsHub the real label that begins 'Missing'", tostring(label), "Missing-litre fee")

    -- The Field Guide's tr: page 5's keyed fee rows, built on a bare dialog instance with
    -- the GUI modelled (g_gui:getProfile, TextElement, the two column boxes).
    local savedGui, savedText = g_gui, TextElement
    g_gui = { getProfile = function() return {} end }
    TextElement = { new = function()
      local e = { text = nil }
      function e:loadProfile() end
      function e:setText(s) self.text = s end
      function e:onGuiSetupFinished() end
      return e
    end }
    local texts = {}
    local function box() return { addElement = function(_, e) texts[#texts + 1] = e end, invalidateLayout = function() end } end
    local dlg = setmetatable({ _elCol1 = box(), _elCol2 = box(), _contentLineEls = {} }, { __index = DairyGuideDialog })
    local okG, errG = pcall(DairyGuideDialog._buildContent, dlg, 5)
    g_gui, TextElement = savedGui, savedText
    local function shown(s)
      for _, e in ipairs(texts) do if e.text == s then return true end end
      return false
    end
    T.eq("T5 the guide renders its keyed fee rows: a real 'Missing...' text, the fallback for an absent key, a translation",
      tostring(okG) .. "/" .. tostring(shown("Missing milk is charged per litre.")) .. "/"
        .. tostring(shown("Set per 1000 L: 11 by default, from 0 to 50.")) .. "/" .. tostring(shown("Por litro: 0,011 por defecto.")),
      "true/true/true/true")

    -- The helpers' own refusals: an i18n whose hasText raises renders the fallback.
    g_i18n = setmetatable({ hasText = function() error("hasText refused") end }, { __index = i18n })
    show(m)
    T.eq("T6 an i18n whose hasText raises renders the fallback", el(m, "rfFwColC").text, "Worker")
  end)
  g_i18n, g_modEnvironments = savedI18n, savedEnvs
  if not ok then error(err, 0) end
end)
