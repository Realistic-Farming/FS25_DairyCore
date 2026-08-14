-- =========================================================
-- FS25_DairyCore - Feed Provenance (authority #5, FP-1)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- The ONE feed-tracking model. A per-farm, per-fill-type fraction vector:
--   provenance[farmId][fillType] = { contaminated = 0..1, organic = 0..1 }
-- `contaminated` decays toward zero each in-game day (disease heals, the
-- never-stuck floor); `organic` does not decay (only dilution lowers it). Two
-- fractions because they differ in time.
--
-- ONE blend formula at every combine point:
--   f_new = (S * f_old + amount * value) / (S + amount)     -- per fraction
-- where S is the stored amount the incoming `amount` joins. In this build S is the
-- amount accumulated for that farm and fill type (persisted), which is the
-- harvest-pass denominator; the base-game storage aggregate (the farm's actual
-- silo/bunker levels) is the brief's outstanding confirm, and the conversion
-- chain (drying, silage, mixer) uses this same carry-forward when it lands.
--
-- DairyCore is the SOLE writer. Every read is pull-only and neutral when a source
-- is absent. Fraction writes and the effects are server-side.
-- =========================================================

FeedProvenance = {}
local FeedProvenance_mt = Class(FeedProvenance)

function FeedProvenance.new(manager)
    local self = setmetatable({}, FeedProvenance_mt)
    self.manager = manager
    self.provenance = {}   -- [farmId][fillType] = { contaminated, organic }
    self.accum = {}        -- [farmId][fillType] = litres accumulated (the blend denominator S)
    return self
end

-- Server-authoritative: every fraction write happens where the simulation runs.
function FeedProvenance:serverOnly()
    return self.manager ~= nil and self.manager:_isServer()
end

--- Does this farm's provenance hold any data at all? Consumers use this to decide
--- whether to trust the provenance or fall back to a live field read.
function FeedProvenance:hasData(farmId)
    local byFt = self.provenance[farmId]
    return byFt ~= nil and next(byFt) ~= nil
end

--- Read the fraction vector for a farm and fill type. Nil when never seeded.
function FeedProvenance:getFraction(farmId, fillType)
    local byFt = self.provenance[farmId]
    if byFt == nil then return nil end
    return byFt[fillType]
end

--- THE blend law. `amount` of a fill type with `contValue`/`orgValue` (0..1) joins
--- the farm's accumulated stock of that fill type. Called at every capture point.
function FeedProvenance:blend(farmId, fillType, amount, contValue, orgValue)
    if type(fillType) ~= "string" or fillType == "" then return end
    if amount == nil or amount <= 0 then return end
    local prov = self.provenance[farmId]
    if prov == nil then prov = {}; self.provenance[farmId] = prov end
    local p = prov[fillType]
    if p == nil then p = { contaminated = 0, organic = 0 }; prov[fillType] = p end
    local acc = self.accum[farmId]
    if acc == nil then acc = {}; self.accum[farmId] = acc end
    local S = acc[fillType] or 0
    local newS = S + amount
    p.contaminated = math.max(0, math.min(1, (S * (p.contaminated or 0) + amount * (contValue or 0)) / newS))
    p.organic = math.max(0, math.min(1, (S * (p.organic or 0) + amount * (orgValue or 0)) / newS))
    acc[fillType] = newS
end

--- HARVEST capture: a cut of the soilHarvestBus. GRAIN (a combine cut) carries the
--- field's disease pressure at harvest as contamination, and the field's organic
--- certification as the organic fraction. SF holds grass/forage out of its disease
--- model, so a combine cut is grain by construction; forage contamination is a
--- downstream conversion concern (the brief's conversion chain, still confirmed).
function FeedProvenance:onHarvestCut(payload)
    if payload == nil then return end
    if not self:serverOnly() then return end
    local fieldId = payload.fieldId
    local liters = payload.liters or 0
    if fieldId == nil or liters <= 0 then return end

    -- The harvested field's owning farm: the provenance belongs to whoever the
    -- feed will belong to, and a field's produce belongs to its owner.
    local farmId = 0
    pcall(function()
        local flm = g_farmlandManager
        if flm ~= nil and flm.getFarmlandById ~= nil then
            local fl = flm:getFarmlandById(fieldId)
            if fl ~= nil and fl.farmId ~= nil then farmId = fl.farmId end
        end
    end)
    if not self.manager:_isRealFarmId(farmId) then return end

    -- The feed fill type: the harvested fruit's name.
    local fillType = nil
    pcall(function()
        local ftm = g_fruitTypeManager
        if ftm ~= nil and ftm.getFruitTypeByIndex ~= nil then
            local fd = ftm:getFruitTypeByIndex(payload.fruitTypeIndex)
            if fd ~= nil and fd.name ~= nil then fillType = fd.name end
        end
    end)
    if fillType == nil or fillType == "" then return end

    -- Organic: the field's certification at harvest (delegate-when-present).
    local isOrganic = 0
    pcall(function()
        local sf = g_SoilFertilityManager
        if sf ~= nil and sf.organic ~= nil and sf.organic.getFieldOrganicState ~= nil then
            local st = sf.organic:getFieldOrganicState(fieldId)
            if st ~= nil and st.certified == true then isOrganic = 1 end
        end
    end)

    -- Contaminated: the field's raw disease pressure at harvest, as a fraction.
    -- The moisture factor and the Biological dial ride the Option-Scaling Spine
    -- and are neutral (1.0) until the spine exists.
    local cont = math.max(0, math.min(1, (payload.diseasePressure or 0) / 100))

    self:blend(farmId, fillType, liters, cont, isOrganic)
end

--- DECAY: each in-game day, contaminated heals toward zero. Organic never decays;
--- only dilution (a conventional purchase or harvest) lowers it.
function FeedProvenance:decayContaminated()
    if not self:serverOnly() then return end
    local rate = DairyConstants.FEED_PROVENANCE.CONTAMINATED_DECAY_PER_DAY
    for _, byFt in pairs(self.provenance) do
        for _, p in pairs(byFt) do
            p.contaminated = math.max(0, math.min(1, (p.contaminated or 0) * (1 - rate)))
        end
    end
end

--- Amount-weighted mean organic fraction across a farm's harvested feed fills.
--- The read a herd/contract consumer uses for the organic-feed credit.
function FeedProvenance:organicFeedFraction(farmId)
    local byFt = self.provenance[farmId]
    if byFt == nil then return 0 end
    local acc = self.accum[farmId]
    local wsum, wtotal = 0, 0
    for ft, p in pairs(byFt) do
        local w = (acc and acc[ft]) or 0
        wsum = wsum + (p.organic or 0) * w
        wtotal = wtotal + w
    end
    if wtotal <= 0 then return 0 end
    return wsum / wtotal
end

--- THRESHOLD classification (the ratified organic default): a farm's feed classifies
--- organic only ABOVE the threshold share of its organic fraction. Strictness rides
--- the Livestock dial once the spine exists; the neutral value is the ratified default.
function FeedProvenance:isOrganicFeed(farmId, threshold)
    local frac = self:organicFeedFraction(farmId)
    local t = threshold or DairyConstants.FEED_PROVENANCE.ORGANIC_THRESHOLD
    return frac > t
end

-- =========================================================
-- Persistence (StateLedger table + own-file section in the manager)
-- =========================================================

function FeedProvenance:serialize()
    local out = {}
    for farmId, byFt in pairs(self.provenance) do
        local fam = {}
        for ft, p in pairs(byFt) do
            fam[ft] = {
                c = p.contaminated or 0,
                o = p.organic or 0,
                s = (self.accum[farmId] and self.accum[farmId][ft]) or 0,
            }
        end
        out[tostring(farmId)] = fam
    end
    return out
end

function FeedProvenance:deserialize(data)
    if type(data) ~= "table" then return end
    self.provenance = {}
    self.accum = {}
    for key, fam in pairs(data) do
        local farmId = tonumber(key) or key
        for ft, p in pairs(fam) do
            if self.provenance[farmId] == nil then self.provenance[farmId] = {} end
            if self.accum[farmId] == nil then self.accum[farmId] = {} end
            self.provenance[farmId][ft] = { contaminated = p.c or 0, organic = p.o or 0 }
            self.accum[farmId][ft] = p.s or 0
        end
    end
end

-- Console dump (server-side read for the test pass).
function FeedProvenance:consoleDump()
    local lines = {}
    for farmId, byFt in pairs(self.provenance) do
        for ft, p in pairs(byFt) do
            lines[#lines + 1] = string.format("  farm %s %s: cont=%.3f org=%.3f (S=%d)",
                tostring(farmId), tostring(ft), p.contaminated or 0, p.organic or 0,
                math.floor((self.accum[farmId] and self.accum[farmId][ft]) or 0))
        end
    end
    if #lines == 0 then return "feed provenance: no data" end
    return "feed provenance:\n" .. table.concat(lines, "\n")
end
