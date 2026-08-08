-- =========================================================
-- FS25_DairyCore - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the DairyCore modules, publishes the g_currentMission.dairyCoreManager
-- handle, and hooks the FS25 mission lifecycle. Companion mod: it reads the
-- ecosystem (SoilFertilizer, MarketDynamics, RandomWorldEvents, WorkerCosts,
-- FuelCosts, NPCFavor, TaxMod, ProStaff, Ritter RLRM) and rides the Time Guard
-- clock. Every cross-mod edge is handle-gated + pcall-wrapped and degrades to
-- neutral when a companion is absent.
-- =========================================================

local modDirectory = g_currentModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/DairyConstants.lua")
source(modDirectory .. "src/RLBridge.lua")
source(modDirectory .. "src/DairyCoreManager.lua")

-- Esc RF PDA framework joiner (NO-HOST).
source(g_currentModDirectory .. "src/gui/RfEscModules.lua")
source(g_currentModDirectory .. "src/gui/RfPdaMenuPage.lua")
source(g_currentModDirectory .. "src/gui/RfEscBootstrap.lua")
source(g_currentModDirectory .. "src/gui/RfEscUiDebugger.lua")
source(g_currentModDirectory .. "src/gui/DairyRfPdaGuest.lua")

local dairyCore = DairyCoreManager.new()
getfenv(0)["g_dairyCoreManager"] = dairyCore

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.dairyCoreManager = dairyCore
    end
    DCLogger.info("DairyCore loaded")
end

local function onMissionLoadedFinished()
    dairyCore:onMissionLoaded()
end

local function onMissionUpdate(mission, dt)
    dairyCore:update(dt)
end

local function onMissionSave()
    dairyCore:save()
end

local function onMissionDelete()
    dairyCore:onMissionDelete()
    getfenv(0)["g_dairyCoreManager"] = nil
    if g_currentMission ~= nil then
        g_currentMission.dairyCoreManager = nil
    end
end

Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, onMissionUpdate)

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
else
    DCLogger.warning("FSCareerMissionInfo.saveToXMLFile not found - barn state will NOT be saved")
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

if addConsoleCommand ~= nil then
    addConsoleCommand("dairyStatus", "Show DairyCore barns, mode, contracts",
        "consoleCommandStatus", dairyCore)
end


local function _rfEscTryRegister()
    if DairyRfPdaGuest ~= nil and type(DairyRfPdaGuest.tryRegister) == "function" then
        pcall(DairyRfPdaGuest.tryRegister)
    end
end

-- Esc RF PDA: register module after mission/door ready (retry-safe).
if Mission00 ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
        _rfEscTryRegister()
    end)
end
if FSBaseMission ~= nil then
    FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function()
        _rfEscTryRegister()
    end)
end

if FSBaseMission ~= nil then
    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, function()
        if DairyRfPdaGuest ~= nil and type(DairyRfPdaGuest.reset) == "function" then
            DairyRfPdaGuest.reset()
        end
    end)
end
