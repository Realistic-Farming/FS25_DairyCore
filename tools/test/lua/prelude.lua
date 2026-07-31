-- prelude.lua - minimal FS25 engine mock + tiny test framework for FS25_DairyCore.
-- Loaded first by run-tests.mjs, before src modules and the test file. Only stubs what
-- module load + the functions under test touch; extend as new tests need more surface.

unpack = unpack or table.unpack

-- ── FS25 OO helper ─────────────────────────────────────────
-- Class(classTable[, parent]): instances get __index = classTable.
function Class(classTable, parent)
  classTable = classTable or {}
  if parent ~= nil then
    setmetatable(classTable, { __index = parent })
  end
  classTable.__index = classTable
  return classTable
end

-- ── Logging (DCLogger wraps this) ──────────────────────────
-- Silent by default. A test that wants to assert on a warning installs its own
-- capturing Logging.warning; see the barn sync refusal assertions.
Logging = {
  info    = function(...) end,
  warning = function(...) end,
  error   = function(...) end,
}

-- ── Ritter bridge ──────────────────────────────────────────
-- DairyCore only ever reads RLBridge.active plus three pcall-wrapped getters, and
-- standard mode is the shape every DC-13 assertion runs in.
RLBridge = {
  active           = false,
  init             = function() end,
  computeHerdScore = function() return nil end,
  getHerdCounts    = function() return nil end,
}

-- ── Mission stub ───────────────────────────────────────────
-- Tests flip _isServer to exercise the F79 gate from both sides.
g_currentMission = {
  _isServer   = true,
  missionInfo = { savegameDirectory = "savegame1" },
}
function g_currentMission:getIsServer() return self._isServer end

g_server = nil
g_modIsLoaded = {}

-- ── tiny test framework (emits ##TEST_ markers parsed by run-tests.mjs) ──
T = { _pass = 0, _fail = 0 }
local function _pass(name) T._pass = T._pass + 1; print("##TEST_PASS " .. name) end
local function _fail(name, msg) T._fail = T._fail + 1; print("##TEST_FAIL " .. name .. " :: " .. tostring(msg)) end

function T.ok(name, cond, msg)
  if cond then _pass(name) else _fail(name, msg or "expected truthy, got " .. tostring(cond)) end
end
function T.eq(name, got, want)
  if got == want then _pass(name) else _fail(name, "got " .. tostring(got) .. " want " .. tostring(want)) end
end
function T.near(name, got, want, tol)
  tol = tol or 1e-6
  if type(got) == "number" and math.abs(got - want) <= tol then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want ~" .. tostring(want)) end
end
function T.summary() print("##TEST_SUMMARY " .. T._pass .. " " .. T._fail) end
