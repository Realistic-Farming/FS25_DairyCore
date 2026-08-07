-- =========================================================
-- FS25_DairyCore - RLBridge (Ritter RealisticLivestock integration layer)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Detects Ritter's RealisticLivestockRM once at mission load and provides the
-- per-animal reads for Ritter mode. Every read is pcall-wrapped via safeRead; a
-- single failure trips the bridge back to Standard mode (F13: DairyCore NEVER
-- writes into Ritter - no addDisease / injection; all reads only).
-- =========================================================

RLBridge = {}

function RLBridge:init()
    -- Presence: prefer the reliable loaded-in-this-save check (g_modIsLoaded) over a
    -- bare cross-mod global, which FS25 mod-env isolation does not guarantee. Require
    -- g_diseaseManager (RLRM sets it in loadMap) as the "fully live" gate; if it is not
    -- cross-mod visible, we simply stay in Standard mode (safe degrade).
    local present = false
    local ok = pcall(function()
        if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_RealisticLivestockRM"] then
            present = true
        elseif FS25_RealisticLivestockRM ~= nil then
            present = true
        end
    end)

    local diseaseMgr = nil
    pcall(function() diseaseMgr = g_diseaseManager end)

    self.active = (ok and present and diseaseMgr ~= nil) or false

    if self.active then
        DCLogger.info("RLBridge: RealisticLivestock detected - Ritter Mode active")
    else
        DCLogger.info("RLBridge: RealisticLivestock not present - Standard Mode")
    end
    return self.active
end

-- pcall wrapper. On failure, trip back to Standard mode and log once.
function RLBridge:safeRead(fn, fallback)
    if not self.active then return fallback end
    local ok, result = pcall(fn)
    if not ok then
        if not self._degradedLogged then
            DCLogger.debug("RLBridge: a Ritter read failed, degrading to Standard mode (%s)", tostring(result))
            self._degradedLogged = true
        end
        self.active = false
        return fallback
    end
    return result
end

-- Resolve the animal cluster list for a barn placeable (by uniqueId) on a farm.
-- Uses base-game husbandrySystem:getPlaceablesByFarm(farmId) + spec_husbandryAnimals.
function RLBridge:getBarnAnimals(barnId, farmId)
    return self:safeRead(function()
        local hs = g_currentMission and g_currentMission.husbandrySystem
        if hs == nil or hs.getPlaceablesByFarm == nil then return nil end
        for _, placeable in pairs(hs:getPlaceablesByFarm(farmId) or {}) do
            if placeable.getUniqueId ~= nil and placeable:getUniqueId() == barnId then
                local spec = placeable.spec_husbandryAnimals
                if spec ~= nil and spec.clusterSystem ~= nil and spec.clusterSystem.getAnimals ~= nil then
                    return spec.clusterSystem:getAnimals()
                end
                return nil
            end
        end
        return nil
    end, nil)
end

-- Per-animal composite herd score (0-100). Returns nil if animals unavailable
-- (caller falls back to Standard). Mirrors the brief's F4-corrected formula:
-- health (0.6) + normalized genetics.productivity (0.4) - disease penalty.
function RLBridge:computeHerdScore(barnId, farmId)
    local animals = self:getBarnAnimals(barnId, farmId)
    if animals == nil then return nil end

    return self:safeRead(function()
        local total, count = 0, 0
        for _, animal in ipairs(animals) do
            local health = (animal.health ~= nil) and (animal.health / 100) or 1.0
            local prodRaw = (animal.genetics ~= nil and animal.genetics.productivity ~= nil)
                            and animal.genetics.productivity or 1.0
            -- normalize 0.25..1.75 -> 0..1 so an average herd does not max out (F4)
            local prodGene = math.max(0, math.min(1, (prodRaw - 0.25) / 1.5))
            local diseaseCount = 0
            if animal.diseases ~= nil then
                for _ in pairs(animal.diseases) do diseaseCount = diseaseCount + 1 end
            end
            local diseasePenalty = math.min(diseaseCount * 0.08, 0.40)
            local animalScore = ((health * 0.6) + (prodGene * 0.4)) - diseasePenalty
            total = total + math.max(animalScore, 0)
            count = count + 1
        end
        if count == 0 then return nil end
        return (total / count) * 100
    end, nil)
end

-- Per-barn count summary for the FarmTablet Ritter view.
function RLBridge:getHerdCounts(barnId, farmId)
    local animals = self:getBarnAnimals(barnId, farmId)
    if animals == nil then return nil end
    return self:safeRead(function()
        local healthy, sick, pregnant, geneSum, n = 0, 0, 0, 0, 0
        for _, animal in ipairs(animals) do
            n = n + 1
            local health = animal.health or 100
            if health >= 60 then healthy = healthy + 1 else sick = sick + 1 end
            -- F146: the fallback leg read RL's numeric `reproduction` field as a
            -- table (`reproduction.pregnant`), which is nil on a number and was
            -- silently caught by safeRead, degrading Ritter mode to Standard.
            -- `isPregnant` is the real field; drop the bad leg.
            if animal.isPregnant == true then
                pregnant = pregnant + 1
            end
            local prodRaw = (animal.genetics ~= nil and animal.genetics.productivity) or 1.0
            geneSum = geneSum + math.max(0, math.min(1, (prodRaw - 0.25) / 1.5))
        end
        return { healthy = healthy, sick = sick, pregnant = pregnant,
                 avgGenetics = n > 0 and (geneSum / n) or 0, total = n }
    end, nil)
end
