-- =========================================================
-- FS25_DairyCore - DC-14 collection refusal: the session report and its safe view
-- =========================================================
-- Author: TisonK
-- =========================================================
-- The farmer can read why a real scheduled milk round left milk behind: the
-- handling fee met or exceeded the sale price at that attempt (RSF-F216's refusal,
-- DairyCoreManager:_adminSellMilk). This file extends DairyCoreManager with ONE
-- manager-owned, session-lived report map keyed by barn id, written only from the
-- rota's actual due attempt on the server (onCollectionHourTick captures the whole
-- return of _rotaCollection), and ONE safe getter that returns a detached,
-- farm-private view for the local real farm.
--
-- What it never does: sell milk, move money, change the rota's cadence or ageing,
-- read a current price, write a barn record, StateLedger, the own XML file or
-- CHANNEL_BARNS. Mission load begins with no report; reload is NOT_RECORDED by
-- design (SDS v0.9 section 3).
--
-- Slice A of the DC-14 host (brief v1.0 sections 2, 3, 4's getter and 8's
-- strings). Slice B adds the transports a pure client needs (NetworkSync scoped
-- module, the DIRECT events, the route coordinator, the farm-change lifecycle).
-- Slice C binds the Esc sheet. Until B, a pure client's getter answers
-- WAITING/FIRST_SNAPSHOT, which is the truth: no snapshot has reached it.
-- =========================================================

local function dc14IsFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Valid UTF-8 for a label (brief section 8), without Lua 5.3's utf8 library:
-- one byte-walk that rejects stray continuation bytes, overlongs, surrogates
-- and code points past U+10FFFF.
local function dc14ValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return false end
        if i + len - 1 > n then return false end
        for k = 1, len - 1 do
            local cc = s:byte(i + k)
            if cc < 0x80 or cc > 0xBF then return false end
        end
        if len == 3 then
            local c2 = s:byte(i + 1)
            if (c == 0xE0 and c2 < 0xA0) or (c == 0xED and c2 > 0x9F) then return false end
        elseif len == 4 then
            local c2 = s:byte(i + 1)
            if (c == 0xF0 and c2 < 0x90) or (c == 0xF4 and c2 > 0x8F) then return false end
        end
        i = i + len
    end
    return true
end

-- =========================================================
-- The session map
-- =========================================================

--- One session, one map: barnId -> { recordedFarmId, state, attemptHours?, reason? }.
--- Reset at the start of onMissionLoaded ABOVE the PF stand-down return and again in
--- onMissionDelete, because main.lua builds the manager once per process and reuses
--- it across mission loads (main.lua:47-74).
function DairyCoreManager:_resetCollectionRefusalSession()
    self.collectionRefusal = { records = {}, revision = 0 }
end

function DairyCoreManager:_collectionRefusalState()
    if self.collectionRefusal == nil then self:_resetCollectionRefusalSession() end
    return self.collectionRefusal
end

--- The shown projection changed (an outcome, an admission or the next-due truth).
--- The revision feeds slice B's dataRevision; there is no transport to mark yet.
function DairyCoreManager:_touchCollectionRefusal()
    local st = self:_collectionRefusalState()
    st.revision = st.revision + 1
end

--- Clear one barn's explanation: an actual collection from any real source, a
--- later ordinary attempt, a confirmed removal, an owner change or a report
--- invalidation. Worker assignment never calls this (SDS section 5).
function DairyCoreManager:_clearCollectionRefusal(barnId)
    local st = self:_collectionRefusalState()
    if barnId ~= nil and st.records[barnId] ~= nil then
        st.records[barnId] = nil
        self:_touchCollectionRefusal()
    end
end

-- =========================================================
-- Admission
-- =========================================================

--- The strict real farm of this feature: a finite integer from 1 through
--- FarmManager.MAX_FARM_ID (FarmManager.lua:3-4), none of the reserved ids.
--- _isRealFarmId alone lets NaN, the infinities and fractions through (see
--- _advisoryFarmId); this adds the upper bound the SDS names.
function DairyCoreManager:_collectionRealFarmId(farmId)
    if not dc14IsFinite(farmId) or math.floor(farmId) ~= farmId then return nil end
    local fm = FarmManager
    local maxId = (fm ~= nil and tonumber(fm.MAX_FARM_ID)) or 8
    if farmId < 1 or farmId > maxId then return nil end
    if not self:_isRealFarmId(farmId) then return nil end
    return farmId
end

--- The live native owner of a barn's placeable, or nil when it cannot be read.
--- Cached barn.farmId never stands in for it.
function DairyCoreManager:_collectionLiveOwner(barn)
    local p = barn ~= nil and barn._placeable or nil
    if p == nil or type(p.getOwnerFarmId) ~= "function" then return nil end
    local ok, owner = pcall(p.getOwnerFarmId, p)
    if not ok then return nil end
    return self:_collectionRealFarmId(owner)
end

--- The local machine's real farm, strictly. Nil on a dedicated server (no local
--- player, FSBaseMission:getFarmId returns nil there) and for a spectator.
function DairyCoreManager:_collectionLocalFarmId()
    local id = nil
    pcall(function()
        if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
            id = g_currentMission:getFarmId()
        end
    end)
    return self:_collectionRealFarmId(id)
end

-- =========================================================
-- Presence: milk actually left behind, read fail-closed
-- =========================================================

--- The native husbandry Storage (PlaceableHusbandry.lua:89, spec.storage; not the
--- unloading or loading station) at the numeric MILK index. Returns "PRESENT",
--- "ZERO" or "UNAVAILABLE". _milkLevel is not used here: its missing station and
--- its failed read both collapse to zero, and zero here would clear a real refusal.
function DairyCoreManager:_collectionBarnMilk(barn)
    local p = barn ~= nil and barn._placeable or nil
    local spec = p ~= nil and p.spec_husbandry or nil
    local storage = spec ~= nil and spec.storage or nil
    if type(storage) ~= "table" then return "UNAVAILABLE" end

    local index = nil
    pcall(function()
        local ftm = g_fillTypeManager
        if ftm ~= nil and ftm.getFillTypeIndexByName ~= nil then
            index = ftm:getFillTypeIndexByName(DairyConstants.CONTRACTS.MILK_FILLTYPE)
        end
    end)
    if not dc14IsFinite(index) or index <= 0 or math.floor(index) ~= index then return "UNAVAILABLE" end

    -- Storage.lua:275-277: supported means fillTypes[index] == true.
    local supported = false
    if type(storage.getIsFillTypeSupported) == "function" then
        local ok, s = pcall(storage.getIsFillTypeSupported, storage, index)
        supported = ok and s == true
    elseif type(storage.fillTypes) == "table" then
        supported = storage.fillTypes[index] == true
    end
    if not supported then return "UNAVAILABLE" end

    -- Storage.lua:278-280: getFillLevel is fillLevels[index] or 0, so a supported
    -- index with no entry is a trusted zero.
    local level = nil
    if type(storage.fillLevels) == "table" then
        level = storage.fillLevels[index]
        if level == nil then level = 0 end
    elseif type(storage.getFillLevel) == "function" then
        local ok, v = pcall(storage.getFillLevel, storage, index)
        if ok then level = v end
    end
    if not dc14IsFinite(level) or level < 0 then return "UNAVAILABLE" end
    return level > 0 and "PRESENT" or "ZERO"
end

local function dc14WorldXZ(node)
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if ok and dc14IsFinite(x) and dc14IsFinite(z) then return x, z end
    return nil, nil
end

--- The Dairy tank registry, walked within TANK_RADIUS on LIVE owner and LIVE
--- position, never through getNearestTankForBarn (which trusts the cached
--- tank.farmId). The quantity is the registry record's tank.fillLevel, the number
--- MilkTank:addMilk, removeMilk, getFillLevel, serialize and deserialize own; no
--- native Storage is invented for it. Any admitted positive tank proves presence.
--- A candidate that could be in range but cannot be read (no live position, no live
--- owner, a malformed fill) makes the answer UNAVAILABLE, because it could hold the
--- milk. A resolved foreign or empty candidate proves nothing and blocks nothing.
function DairyCoreManager:_collectionTankMilk(barn, farmId)
    local registry = self.milkTankRegistry
    local tanks = registry ~= nil and registry.tanks or nil
    if type(tanks) ~= "table" or next(tanks) == nil then return "ZERO" end
    local radius = DairyConstants.MILK_TANK.TANK_RADIUS
    local p = barn._placeable
    local bx, bz = nil, nil
    if p ~= nil and p.rootNode ~= nil then bx, bz = dc14WorldXZ(p.rootNode) end

    local uncertain = false
    for _, tank in pairs(tanks) do
        local tp = tank._placeable
        local tx, tz = nil, nil
        if tp ~= nil and tp.rootNode ~= nil then tx, tz = dc14WorldXZ(tp.rootNode) end
        local inRange = nil
        if bx ~= nil and tx ~= nil then
            local dx, dz = tx - bx, tz - bz
            -- The same strict reach the sale's own nearest-tank read uses (MilkTank.lua:134-140).
            inRange = math.sqrt(dx * dx + dz * dz) < radius
        end
        if inRange == nil then
            uncertain = true
        elseif inRange then
            local owner = nil
            if tp ~= nil and type(tp.getOwnerFarmId) == "function" then
                local ok, o = pcall(tp.getOwnerFarmId, tp)
                if ok then owner = self:_collectionRealFarmId(o) end
            end
            if owner == nil then
                uncertain = true
            elseif owner == farmId then
                local fill = tank.fillLevel
                if not dc14IsFinite(fill) or fill < 0 then
                    uncertain = true
                elseif fill > 0 then
                    return "PRESENT"
                end
            end
        end
    end
    return uncertain and "UNAVAILABLE" or "ZERO"
end

--- Barn first; the tank walk runs only after a trusted barn zero, so an unread tank
--- can never poison a barn that proved presence (brief section 3).
function DairyCoreManager:_collectionMilkPresence(barn, farmId)
    local barnRead = self:_collectionBarnMilk(barn)
    if barnRead ~= "ZERO" then return barnRead end
    return self:_collectionTankMilk(barn, farmId)
end

-- =========================================================
-- The attempt: called by onCollectionHourTick after the rota's sale returns
-- =========================================================

--- ok, resultOrError, status are pcall's three results around _rotaCollection.
--- Only ok == true with status "fee_exceeds_price" enters the presence read; any
--- ordinary result clears the explanation; a raising sale or an untrusted read
--- makes the row UNAVAILABLE without claiming a collection happened. Repeated
--- same-reason attempts replace the attempt hour (no history list).
function DairyCoreManager:_recordCollectionAttempt(barn, ok, resultOrError, status, nowHours)
    local barnId = barn ~= nil and barn.barnId or nil
    if barnId == nil then return end
    local st = self:_collectionRefusalState()
    local R = DairyConstants.COLLECTION_REFUSAL
    local owner = self:_collectionLiveOwner(barn)
    local record = nil
    if not ok then
        DCLogger.warning("DC-14: the rota's sale raised for barn %s (%s); its collection status is unavailable",
            tostring(barnId), tostring(resultOrError))
        record = { recordedFarmId = owner, state = R.ROW_STATES.UNAVAILABLE, reason = R.ROW_REASONS.EVALUATION_ERROR }
    elseif status == "fee_exceeds_price" then
        if owner == nil or owner ~= barn.farmId then
            -- Unresolved or changed owner: no milk is read and no fee reason is stored;
            -- discovery and reconciliation own the cache correction.
            record = { recordedFarmId = owner, state = R.ROW_STATES.UNAVAILABLE, reason = R.ROW_REASONS.OWNER_UNRESOLVED }
        else
            local presence = self:_collectionMilkPresence(barn, owner)
            if presence == "PRESENT" and dc14IsFinite(nowHours) and nowHours >= 0 then
                record = { recordedFarmId = owner, state = R.ROW_STATES.FEE_EXCEEDS_PRICE, attemptHours = nowHours }
            elseif presence == "ZERO" then
                -- An empty high-fee round: trusted zero clears an older explanation.
                record = nil
            else
                record = { recordedFarmId = owner, state = R.ROW_STATES.UNAVAILABLE, reason = R.ROW_REASONS.EVALUATION_ERROR }
            end
        end
    else
        record = nil
    end
    local before = st.records[barnId]
    st.records[barnId] = record
    if before ~= nil or record ~= nil then self:_touchCollectionRefusal() end
end

-- =========================================================
-- The safe view
-- =========================================================

--- The stable row identity: the barn id as a nonempty string of at most
--- MAX_KEY_BYTES. A barn whose id cannot be keyed cannot be identified safely and
--- gets no row; it is logged once per session.
function DairyCoreManager:_collectionBarnKey(barnId)
    local R = DairyConstants.COLLECTION_REFUSAL
    local key = barnId ~= nil and tostring(barnId) or nil
    if type(key) == "string" and key ~= "" and #key <= R.MAX_KEY_BYTES and dc14ValidUtf8(key) then
        return key
    end
    local st = self:_collectionRefusalState()
    st.unkeyed = st.unkeyed or {}
    local mark = tostring(barnId)
    if not st.unkeyed[mark] then
        st.unkeyed[mark] = true
        DCLogger.warning("DC-14: barn id %s cannot be a stable row key; no collection row for it", mark)
    end
    return nil
end

--- The display label: _advisoryBarnLabel's ladder when it is valid UTF-8, nonempty
--- and within MAX_LABEL_BYTES; otherwise the bounded literal "Barn <short key>"
--- from the final safe bytes of the stable key. A bad name never rejects the barn.
function DairyCoreManager:_collectionBarnLabel(key, barnId, placeable)
    local R = DairyConstants.COLLECTION_REFUSAL
    local label = nil
    pcall(function() label = self:_advisoryBarnLabel(barnId, placeable) end)
    if type(label) == "string" and label ~= "" and #label <= R.MAX_LABEL_BYTES and dc14ValidUtf8(label) then
        return label
    end
    for n = 4, 1, -1 do
        local suffix = key:sub(math.max(1, #key - n + 1))
        if dc14ValidUtf8(suffix) then return R.LABEL_FALLBACK_PREFIX .. suffix end
    end
    return R.LABEL_FALLBACK_PREFIX .. "?"
end

--- The producer: every live native Dairy barn admitted to farmId by its LIVE owner,
--- one detached row each, sorted by barnKey. A barn the cache assigns to farmId
--- whose live owner cannot be read gets an UNAVAILABLE row (OWNER_UNRESOLVED) and
--- never a fee reason. A stored report whose recorded owner differs from the live
--- owner is invalidated before anything is returned. Slice B's transports call this
--- with the trusted farm they derived; the local producer calls it with the strict
--- local farm.
function DairyCoreManager:_collectionRefusalRows(farmId)
    local R = DairyConstants.COLLECTION_REFUSAL
    local st = self:_collectionRefusalState()
    local rows = {}
    for barnId, barn in pairs(self.barns) do
        local p = barn._placeable
        if p ~= nil and not barn._probeDead then
            local owner = self:_collectionLiveOwner(barn)
            local record = st.records[barnId]
            if record ~= nil and owner ~= nil and record.recordedFarmId ~= owner then
                st.records[barnId] = nil
                record = nil
                self:_touchCollectionRefusal()
            end
            local admitted, unresolved = false, false
            if owner ~= nil then
                admitted = owner == farmId
            elseif barn.farmId == farmId then
                admitted, unresolved = true, true
            end
            if admitted then
                local key = self:_collectionBarnKey(barnId)
                if key ~= nil then
                    local row = { barnKey = key, barnLabel = self:_collectionBarnLabel(key, barnId, p) }
                    if unresolved then
                        row.state, row.code = R.ROW_STATES.UNAVAILABLE, R.ROW_CODES.UNAVAILABLE
                        row.reason = R.ROW_REASONS.OWNER_UNRESOLVED
                    elseif record == nil then
                        row.state, row.code = R.ROW_STATES.NONE_RECORDED, R.ROW_CODES.NONE_RECORDED
                    elseif record.state == R.ROW_STATES.FEE_EXCEEDS_PRICE
                        and dc14IsFinite(record.attemptHours) and record.attemptHours >= 0 then
                        row.state, row.code = R.ROW_STATES.FEE_EXCEEDS_PRICE, R.ROW_CODES.FEE_EXCEEDS_PRICE
                        row.attemptHours = record.attemptHours
                    else
                        row.state, row.code = R.ROW_STATES.UNAVAILABLE, R.ROW_CODES.UNAVAILABLE
                        row.reason = record.reason or R.ROW_REASONS.EVALUATION_ERROR
                    end
                    -- Next due is published only while a worker remains assigned.
                    if barn.assignedWorkerId ~= nil and dc14IsFinite(barn.nextCollectionDue)
                        and barn.nextCollectionDue >= 0 then
                        row.nextDueHours = barn.nextCollectionDue
                    end
                    rows[#rows + 1] = row
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.barnKey < b.barnKey end)
    return rows
end

--- The one safe getter. No caller-supplied farm or barn: it derives the strict
--- local farm itself and returns one detached { state, reason, rows } value.
---   nil                         PF stand-down: no collection surface exists
---   UNAVAILABLE / SETTINGS_OFF  Dairy simulation is off
---   WAITING / FIRST_SNAPSHOT    a pure client before its first complete snapshot
---                               (slice B brings the transports; until then always)
---   UNAVAILABLE / NO_REAL_FARM  no strict local real farm (spectator, dedicated)
---   READY                       the local producer's rows for the local farm
function DairyCoreManager:getCollectionRefusalViews()
    local R = DairyConstants.COLLECTION_REFUSAL
    if self.disabled then return nil end
    if self.settings == nil or self.settings.enabled == false then
        return { state = R.STATES.UNAVAILABLE, reason = R.REASONS.SETTINGS_OFF, rows = {} }
    end
    if not self:_isServer() then
        return { state = R.STATES.WAITING, reason = R.REASONS.FIRST_SNAPSHOT, rows = {} }
    end
    local farmId = self:_collectionLocalFarmId()
    if farmId == nil then
        return { state = R.STATES.UNAVAILABLE, reason = R.REASONS.NO_REAL_FARM, rows = {} }
    end
    return { state = R.STATES.READY, reason = nil, rows = self:_collectionRefusalRows(farmId) }
end
