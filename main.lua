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

-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
DairyCoreModDirectory = DairyCoreModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_DairyCore/") or nil)
DairyCoreModName = DairyCoreModName or g_currentModName or "FS25_DairyCore"
local modDirectory = DairyCoreModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/DairyConstants.lua")
source(modDirectory .. "src/RLBridge.lua")
source(modDirectory .. "src/FeedProvenance.lua")
source(modDirectory .. "src/MilkTank.lua")
source(modDirectory .. "src/DairyCoreManager.lua")
-- DC-27: the direct-event fallback for the breed surface mirror (used only when
-- NetworkSync is absent or refuses the module).
source(modDirectory .. "src/network/DairyBreedSurfaceEvent.lua")

-- Esc RF PDA framework joiner (NO-HOST).
source(DairyCoreModDirectory .. "src/gui/RfEscModules.lua")
source(DairyCoreModDirectory .. "src/gui/RfPdaMenuPage.lua")
source(DairyCoreModDirectory .. "src/gui/RfEscBootstrap.lua")
source(DairyCoreModDirectory .. "src/gui/RfEscUiDebugger.lua")
source(DairyCoreModDirectory .. "src/gui/DairyRfPdaGuest.lua")
source(DairyCoreModDirectory .. "src/gui/FeedDesignationDialog.lua")

-- DC-27: put the milk production wrapper on the PlaceableHusbandryMilk class slot
-- before TypeManager:finalizeTypes() captures it into the husbandry types. Guarded
-- on slot identity inside, so a re-source never stacks a second wrapper.
DairyCoreManager._installMilkBreedProductionWrapper()

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
    -- DC-33: the per-frame driver rides the verified updateable pattern (same
    -- lifecycle as TaxMod's updateable): g_currentMission:addUpdateable in the
    -- mission-load-finished hook, removed in the delete hook. The previous carrier,
    -- an append onto FSBaseMission.update, never fired: the 2026-09-05 session ran
    -- for close to an hour and the DC-32 retry loop's success and cap lines never
    -- appeared in log.txt, so discovery stayed at its initial 0-barn pass and the
    -- Farm Tablet and the RF PDA showed no dairy barns. FSBaseMission.lua is not
    -- present in any of the reference packs, so the old hook cannot be verified and
    -- is not kept as a second carrier.
    local dcUpdateable = {
        update = function(_, dt)
            local delta = dt
            if type(delta) == "table" then
                delta = delta.dt or delta.deltaTime or 0
            end
            dairyCore:update(delta or 0)
        end,
        delete = function()
            DCLogger.info("DairyCore updateable removed")
        end,
    }
    if g_currentMission ~= nil and g_currentMission.addUpdateable ~= nil then
        g_currentMission:addUpdateable(dcUpdateable)
        dairyCore.updateable = dcUpdateable
        DCLogger.info("DairyCore updateable registered (DC-33)")
    else
        DCLogger.warning("g_currentMission:addUpdateable unavailable - barn discovery will not retry")
    end
end

local function onMissionSave()
    dairyCore:save()
end

local function onMissionDelete()
    dairyCore:onMissionDelete()
    if dairyCore.updateable ~= nil and g_currentMission ~= nil and g_currentMission.removeUpdateable ~= nil then
        g_currentMission:removeUpdateable(dairyCore.updateable)
        dairyCore.updateable = nil
    end
    getfenv(0)["g_dairyCoreManager"] = nil
    if g_currentMission ~= nil then
        g_currentMission.dairyCoreManager = nil
    end
end

Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
else
    DCLogger.warning("FSCareerMissionInfo.saveToXMLFile not found - barn state will NOT be saved")
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

-- DC-27: a joining client gets the breed surface snapshot as one direct event
-- when NetworkSync is not carrying the module (with NetworkSync the client pulls
-- the full snapshot itself on join).
if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        function(mission, connection, user, farm)
            dairyCore:sendBreedSurfaceInitialState(connection)
        end)
end

if addConsoleCommand ~= nil then
    addConsoleCommand("dairyStatus", "Show DairyCore barns, mode, contracts",
        "consoleCommandStatus", dairyCore)
    addConsoleCommand("dcAssignRota", "DC-9: assign a collection worker to a barn: dcAssignRota <barnId> <workerId>",
        "consoleAssignRota", dairyCore)
    addConsoleCommand("dcUnassignRota", "DC-9: clear a barn's rota: dcUnassignRota <barnId>",
        "consoleUnassignRota", dairyCore)
    addConsoleCommand("dcSellMilk", "DC-21: office-sell a barn's milk: dcSellMilk <barnId> [litres]",
        "consoleSellMilk", dairyCore)
    addConsoleCommand("dcCollectionTick", "DC-9: force one collection hour tick (testing)",
        "consoleCollectionTick", dairyCore)
    addConsoleCommand("dcFeedProvenance", "FP-1: show the farm feed provenance ledger (server only)",
        "consoleFeedProvenance", dairyCore)
    addConsoleCommand("dcFeedFlushQuote", "D1: quote the contaminated-feed flush for the local farm",
        "consoleFeedFlushQuote", dairyCore)
    addConsoleCommand("dcFeedFlush", "D1: pay to purge the farm's contaminated feed (server only)",
        "consoleFeedFlush", dairyCore)
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
