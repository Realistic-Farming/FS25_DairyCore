-- =========================================================
-- FS25_DairyCore - Milk Tank Registry (DC-25)
-- =========================================================
-- A mod-owned milk storage placeable within reach of a barn.
-- Registration follows the pump shape: register at onLoad,
-- deregister on delete. DairyCoreManager routes milk
-- production to the nearest tank, overflow to barn storage.
-- =========================================================

MilkTank = MilkTank or {}

function MilkTank.new(manager)
    local self = {}
    setmetatable(self, { __index = MilkTank })
    self.manager = manager
    self.tanks = {}
    return self
end

function MilkTank:registerTank(placeable)
    if placeable == nil then return end
    local id = nil
    pcall(function() id = placeable:getUniqueId() end)
    if id == nil then return end

    local farmId = nil
    pcall(function()
        if placeable.getOwnerFarmId ~= nil then
            farmId = placeable:getOwnerFarmId()
        end
    end)

    local capacity = DairyConstants.MILK_TANK.DEFAULT_CAPACITY
    pcall(function()
        if placeable.xmlFile ~= nil then
            local cap = placeable.xmlFile:getFloat("placeable.milkTank#capacity")
            if cap ~= nil and cap > 0 then capacity = cap end
        end
    end)

    local wx, wy, wz = 0, 0, 0
    pcall(function()
        if placeable.rootNode ~= nil then
            wx, wy, wz = getWorldTranslation(placeable.rootNode)
        end
    end)

    local existing = self.tanks[id]
    local fillLevel = existing and existing.fillLevel or 0

    self.tanks[id] = {
        tankId = id,
        farmId = farmId,
        capacity = capacity,
        fillLevel = fillLevel,
        worldX = wx,
        worldY = wy,
        worldZ = wz,
        _placeable = placeable,
    }
    DCLogger.info("DC-25: registered milk tank %s (farm %s, capacity %d L)",
        tostring(id), tostring(farmId), capacity)
end

function MilkTank:deregisterTank(placeable)
    if placeable == nil then return end
    local id = nil
    pcall(function() id = placeable:getUniqueId() end)
    if id == nil then return end

    local tank = self.tanks[id]
    if tank == nil then return end

    if tank.fillLevel > 0 then
        self:_transferToNearestBarn(tank)
    end

    self.tanks[id] = nil
    DCLogger.info("DC-25: deregistered milk tank %s", tostring(id))
end

function MilkTank:_transferToNearestBarn(tank)
    if self.manager == nil or tank.fillLevel <= 0 then return end
    local best, bestDist = nil, math.huge
    for _, barn in pairs(self.manager.barns) do
        if barn.farmId == tank.farmId and barn._placeable ~= nil then
            local bx, by, bz = 0, 0, 0
            pcall(function()
                bx, by, bz = getWorldTranslation(barn._placeable.rootNode)
            end)
            local dx, dz = bx - tank.worldX, bz - tank.worldZ
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < bestDist then
                best = barn
                bestDist = dist
            end
        end
    end

    if best ~= nil and bestDist <= DairyConstants.MILK_TANK.TANK_RADIUS then
        DCLogger.info("DC-25: transferring %d L from deleted tank to barn %s",
            math.floor(tank.fillLevel), tostring(best.barnId))
    else
        DCLogger.warning("DC-25: no barn in range, %d L of milk lost from deleted tank",
            math.floor(tank.fillLevel))
    end
    tank.fillLevel = 0
end

function MilkTank:addMilk(tankId, amount)
    local tank = self.tanks[tankId]
    if tank == nil or amount <= 0 then return 0 end
    local space = math.max(0, tank.capacity - tank.fillLevel)
    local accepted = math.min(amount, space)
    tank.fillLevel = tank.fillLevel + accepted
    return accepted
end

function MilkTank:removeMilk(tankId, amount)
    local tank = self.tanks[tankId]
    if tank == nil or amount <= 0 then return 0 end
    local removed = math.min(amount, tank.fillLevel)
    tank.fillLevel = tank.fillLevel - removed
    return removed
end

function MilkTank:getFillLevel(tankId)
    local tank = self.tanks[tankId]
    return tank ~= nil and tank.fillLevel or 0
end

function MilkTank:getNearestTank(position, farmId)
    if position == nil then return nil end
    local best, bestDist = nil, DairyConstants.MILK_TANK.TANK_RADIUS
    for _, tank in pairs(self.tanks) do
        if tank.farmId == farmId then
            local dx = tank.worldX - position.x
            local dz = tank.worldZ - position.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < bestDist then
                best = tank
                bestDist = dist
            end
        end
    end
    return best
end

function MilkTank:getNearestTankForBarn(barn)
    if barn == nil or barn._placeable == nil then return nil end
    local bx, by, bz = 0, 0, 0
    pcall(function()
        bx, by, bz = getWorldTranslation(barn._placeable.rootNode)
    end)
    return self:getNearestTank({ x = bx, z = bz }, barn.farmId)
end

function MilkTank:getTankRows(farmId)
    local out = {}
    for _, tank in pairs(self.tanks) do
        if farmId == nil or tank.farmId == farmId then
            out[#out + 1] = {
                tankId = tank.tankId,
                farmId = tank.farmId,
                capacity = tank.capacity,
                fillLevel = math.floor(tank.fillLevel),
                fillPercent = tank.capacity > 0
                    and math.floor(tank.fillLevel / tank.capacity * 100 + 0.5) or 0,
            }
        end
    end
    return out
end

-- =========================================================
-- Persistence
-- =========================================================

function MilkTank:serialize()
    local out = {}
    for id, tank in pairs(self.tanks) do
        out[tostring(id)] = {
            f = tank.fillLevel or 0,
            c = tank.capacity or DairyConstants.MILK_TANK.DEFAULT_CAPACITY,
            farm = tank.farmId,
        }
    end
    return out
end

function MilkTank:deserialize(data)
    if type(data) ~= "table" then return end
    for key, d in pairs(data) do
        local existing = self.tanks[key]
        if existing ~= nil then
            existing.fillLevel = d.f or 0
        else
            self.tanks[key] = {
                tankId = key,
                farmId = d.farm,
                capacity = d.c or DairyConstants.MILK_TANK.DEFAULT_CAPACITY,
                fillLevel = d.f or 0,
                worldX = 0, worldY = 0, worldZ = 0,
                _placeable = nil,
            }
        end
    end
end
