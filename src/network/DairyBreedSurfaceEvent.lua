-- =========================================================
-- FS25_DairyCore - DairyBreedSurfaceEvent
-- =========================================================
-- Author: TisonK
-- =========================================================
-- DC-27 fallback transport. Carries one breed surface snapshot (the same dense
-- value array DairyCoreManager hands NetworkSync) from the server to a client
-- when NetworkSync is absent or refused the module. A pure client applies it
-- through the one validating entry point; the server ignores its own copy.
-- Values are bool, number (int32 when integral and in range, else float32) or
-- string, tagged per value exactly like RealisticFarmingSyncEvent.
-- =========================================================

DairyBreedSurfaceEvent = DairyBreedSurfaceEvent or {}
local DairyBreedSurfaceEvent_mt = Class(DairyBreedSurfaceEvent, Event)

InitEventClass(DairyBreedSurfaceEvent, "DairyBreedSurfaceEvent")

DairyBreedSurfaceEvent.T_BOOL   = 0
DairyBreedSurfaceEvent.T_INT    = 1
DairyBreedSurfaceEvent.T_FLOAT  = 2
DairyBreedSurfaceEvent.T_STRING = 3

local INT32_MIN = -2147483648
local INT32_MAX = 2147483647

local function isFinite(v)
    return v == v and v ~= math.huge and v ~= -math.huge
end

-- Every value must be encodable; nil, tables and non-finite numbers are not.
-- Returns true, or false and the offending index.
function DairyBreedSurfaceEvent.validateValues(values)
    if type(values) ~= "table" then return false, 0 end
    for i = 1, #values do
        local v = values[i]
        local t = type(v)
        if t == "number" then
            if not isFinite(v) then return false, i end
        elseif t ~= "boolean" and t ~= "string" then
            return false, i
        end
    end
    return true
end

-- The engine constructs through emptyNew() and then calls readStream on the
-- result; no field defaults so a short read fails instead of passing quietly.
function DairyBreedSurfaceEvent.emptyNew()
    local self = Event.new(DairyBreedSurfaceEvent_mt)
    return self
end

function DairyBreedSurfaceEvent.new(values)
    local self = Event.new(DairyBreedSurfaceEvent_mt)
    self.values = values or {}
    self.valid = true
    return self
end

local function writeValue(streamId, v)
    local t = type(v)
    if t == "boolean" then
        streamWriteUInt8(streamId, DairyBreedSurfaceEvent.T_BOOL)
        streamWriteBool(streamId, v)
    elseif t == "number" then
        if isFinite(v) and math.floor(v) == v and v >= INT32_MIN and v <= INT32_MAX then
            streamWriteUInt8(streamId, DairyBreedSurfaceEvent.T_INT)
            streamWriteInt32(streamId, v)
        else
            streamWriteUInt8(streamId, DairyBreedSurfaceEvent.T_FLOAT)
            streamWriteFloat32(streamId, isFinite(v) and v or 0)
        end
    else
        streamWriteUInt8(streamId, DairyBreedSurfaceEvent.T_STRING)
        streamWriteString(streamId, tostring(v))
    end
end

function DairyBreedSurfaceEvent:writeStream(streamId, connection)
    local values = self.values or {}
    local ok = DairyBreedSurfaceEvent.validateValues(values)
    if not ok then values = {} end
    streamWriteInt32(streamId, #values)
    for i = 1, #values do
        writeValue(streamId, values[i])
    end
end

function DairyBreedSurfaceEvent:readStream(streamId, connection)
    self.values = {}
    self.valid = true
    local count = streamReadInt32(streamId)
    if count < 0 then
        self.valid = false
        count = 0
    end
    for i = 1, count do
        local tag = streamReadUInt8(streamId)
        if tag == DairyBreedSurfaceEvent.T_BOOL then
            self.values[i] = streamReadBool(streamId)
        elseif tag == DairyBreedSurfaceEvent.T_INT then
            self.values[i] = streamReadInt32(streamId)
        elseif tag == DairyBreedSurfaceEvent.T_FLOAT then
            self.values[i] = streamReadFloat32(streamId)
        elseif tag == DairyBreedSurfaceEvent.T_STRING then
            self.values[i] = streamReadString(streamId)
        else
            -- Unknown tag: the rest of the stream cannot be trusted. Stop reading
            -- values and let run() reject the packet.
            self.valid = false
            break
        end
    end
    self:run(connection)
end

-- Pure client only. The listen host is the server and already holds the truth.
function DairyBreedSurfaceEvent:run(connection)
    if g_currentMission == nil or g_currentMission:getIsServer() then return end
    local mgr = g_dairyCoreManager
    if mgr == nil then mgr = g_currentMission.dairyCoreManager end
    if mgr == nil or mgr._applyBreedSurfaceSnapshot == nil then return end
    if not self.valid then
        mgr:_applyBreedSurfaceSnapshot(nil, "DIRECT_EVENT")
        return
    end
    mgr:_applyBreedSurfaceSnapshot(self.values, "DIRECT_EVENT")
end
