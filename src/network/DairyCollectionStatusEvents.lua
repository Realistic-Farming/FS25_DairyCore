-- =========================================================
-- FS25_DairyCore - DairyCollectionStatusRequestEvent / DairyCollectionStatusResponseEvent
-- =========================================================
-- Author: TisonK
-- =========================================================
-- DC-14 standalone DIRECT transport (SDS v0.9 section 5, brief v1.0 section 5):
-- the fallback a pure client uses when NetworkSync's scoped service is absent,
-- refused or failed over. One request asks the server for the complete admitted
-- farm snapshot and carries no farm, barn or result claim; the server derives the
-- farm from the actual connection and answers that connection only, in bounded
-- ordered chunks. Nothing here sells milk, moves money or writes a barn record.
--
-- Typed layouts, exactly as fixed in the brief (engine primitives, all in use
-- across dataS: streamWriteUInt8, streamWriteUInt32, streamWriteInt32,
-- streamWriteFloat32, streamWriteBool, streamWriteString and their reads):
--   request:  uint8 schema=1, uint32 routeGeneration, string viewGeneration,
--             uint32 requestSequence
--   response: uint8 schema=1, uint32 routeGeneration, string viewGeneration,
--             uint32 requestSequence, uint8 stateCode, uint8 farmIdOr0,
--             int32 totalRowCount, int32 chunkIndex, int32 chunkCount,
--             int32 chunkRowCount, then per row: string barnKey, string barnLabel,
--             uint8 rowStateCode, bool hasAttempt, float32 attemptHoursOr0,
--             bool hasNextDue, float32 nextDueHoursOr0
-- The engine constructs through emptyNew() and calls readStream, which validates,
-- then runs the event once (Event.lua:11-13; the breed event has the same shape).
-- =========================================================

local UINT32_MAX = 4294967295
local SEQUENCE_MAX = 2147483647

local function isFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isInteger(v, lo, hi)
    return isFinite(v) and math.floor(v) == v and v >= lo and v <= hi
end

local function boundedString(s, maxBytes)
    return type(s) == "string" and s ~= "" and #s <= maxBytes
end

local function cfg()
    return DairyConstants.COLLECTION_REFUSAL
end

-- =========================================================
-- Request
-- =========================================================

DairyCollectionStatusRequestEvent = DairyCollectionStatusRequestEvent or {}
local DairyCollectionStatusRequestEvent_mt = Class(DairyCollectionStatusRequestEvent, Event)
InitEventClass(DairyCollectionStatusRequestEvent, "DairyCollectionStatusRequestEvent")

--- Validates the four fields; returns true or false and the reason.
function DairyCollectionStatusRequestEvent.validate(ev)
    if ev.schema ~= cfg().SCHEMA then return false, "SCHEMA" end
    if not isInteger(ev.routeGeneration, 0, UINT32_MAX) then return false, "GENERATION" end
    if not boundedString(ev.viewGeneration, cfg().MAX_KEY_BYTES) then return false, "VIEW_GENERATION" end
    if not isInteger(ev.requestSequence, 1, SEQUENCE_MAX) then return false, "SEQUENCE" end
    return true
end

function DairyCollectionStatusRequestEvent.emptyNew()
    return Event.new(DairyCollectionStatusRequestEvent_mt)
end

function DairyCollectionStatusRequestEvent.new(routeGeneration, viewGeneration, requestSequence)
    local self = Event.new(DairyCollectionStatusRequestEvent_mt)
    self.schema = cfg().SCHEMA
    self.routeGeneration = routeGeneration
    self.viewGeneration = viewGeneration
    self.requestSequence = requestSequence
    self.valid = DairyCollectionStatusRequestEvent.validate(self)
    return self
end

function DairyCollectionStatusRequestEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.schema)
    streamWriteUInt32(streamId, self.routeGeneration)
    streamWriteString(streamId, self.viewGeneration)
    streamWriteUInt32(streamId, self.requestSequence)
end

function DairyCollectionStatusRequestEvent:readStream(streamId, connection)
    self.schema = streamReadUInt8(streamId)
    self.routeGeneration = streamReadUInt32(streamId)
    self.viewGeneration = streamReadString(streamId)
    self.requestSequence = streamReadUInt32(streamId)
    self.valid = DairyCollectionStatusRequestEvent.validate(self)
    self:run(connection)
end

--- Server only: a client asked for its own farm's snapshot. The manager derives
--- the farm from the connection, rate-limits it and answers it alone.
function DairyCollectionStatusRequestEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local mgr = g_dairyCoreManager
    if mgr == nil then mgr = g_currentMission.dairyCoreManager end
    if mgr == nil or mgr._collectionDirectOnRequest == nil then return end
    mgr:_collectionDirectOnRequest(self, connection)
end

-- =========================================================
-- Response chunk
-- =========================================================

DairyCollectionStatusResponseEvent = DairyCollectionStatusResponseEvent or {}
local DairyCollectionStatusResponseEvent_mt = Class(DairyCollectionStatusResponseEvent, Event)
InitEventClass(DairyCollectionStatusResponseEvent, "DairyCollectionStatusResponseEvent")

DairyCollectionStatusResponseEvent.STATE_READY = 0
DairyCollectionStatusResponseEvent.STATE_UNAVAILABLE = 1

--- The typed size of one chunk with these rows, against the application budget.
--- A string costs its length plus a two-byte length prefix.
function DairyCollectionStatusResponseEvent.estimateBytes(viewGeneration, rows)
    local bytes = 1 + 4 + (2 + #tostring(viewGeneration)) + 4 + 1 + 1 + 4 + 4 + 4 + 4
    for _, row in ipairs(rows or {}) do
        bytes = bytes + (2 + #row.barnKey) + (2 + #row.barnLabel) + 1 + 1 + 4 + 1 + 4
    end
    return bytes
end

function DairyCollectionStatusResponseEvent.estimateRowBytes(row)
    return (2 + #row.barnKey) + (2 + #row.barnLabel) + 1 + 1 + 4 + 1 + 4
end

--- One row of a READY chunk, validated on both sides.
function DairyCollectionStatusResponseEvent.validateRow(row)
    local C = cfg()
    if type(row) ~= "table" then return false, "ROW" end
    if not boundedString(row.barnKey, C.MAX_KEY_BYTES) then return false, "KEY" end
    if not boundedString(row.barnLabel, C.MAX_LABEL_BYTES) then return false, "LABEL" end
    if row.code ~= C.ROW_CODES.NONE_RECORDED and row.code ~= C.ROW_CODES.FEE_EXCEEDS_PRICE
        and row.code ~= C.ROW_CODES.UNAVAILABLE then
        return false, "CODE"
    end
    if type(row.hasAttempt) ~= "boolean" or type(row.hasNextDue) ~= "boolean" then return false, "FLAG" end
    if row.code == C.ROW_CODES.FEE_EXCEEDS_PRICE then
        if not row.hasAttempt or not isFinite(row.attemptHours) or row.attemptHours < 0 then return false, "ATTEMPT" end
    else
        if row.hasAttempt or row.attemptHours ~= 0 then return false, "ATTEMPT" end
    end
    if row.hasNextDue then
        if not isFinite(row.nextDueHours) or row.nextDueHours < 0 then return false, "NEXT" end
    else
        if row.nextDueHours ~= 0 then return false, "NEXT" end
    end
    return true
end

--- Header consistency; the row list is validated row by row.
function DairyCollectionStatusResponseEvent.validate(ev)
    local C = cfg()
    if ev.schema ~= C.SCHEMA then return false, "SCHEMA" end
    if not isInteger(ev.routeGeneration, 0, UINT32_MAX) then return false, "GENERATION" end
    if not boundedString(ev.viewGeneration, C.MAX_KEY_BYTES) then return false, "VIEW_GENERATION" end
    if not isInteger(ev.requestSequence, 1, SEQUENCE_MAX) then return false, "SEQUENCE" end
    local E = DairyCollectionStatusResponseEvent
    if ev.stateCode ~= E.STATE_READY and ev.stateCode ~= E.STATE_UNAVAILABLE then return false, "STATE" end
    if not isInteger(ev.farmIdOr0, 0, 255) then return false, "FARM" end
    if not isInteger(ev.totalRowCount, 0, SEQUENCE_MAX) or not isInteger(ev.chunkIndex, 0, C.DIRECT_MAX_CHUNKS - 1)
        or not isInteger(ev.chunkCount, 1, C.DIRECT_MAX_CHUNKS) or not isInteger(ev.chunkRowCount, 0, C.DIRECT_MAX_ROWS_PER_CHUNK) then
        return false, "COUNT"
    end
    if ev.chunkIndex >= ev.chunkCount then return false, "COUNT" end
    if ev.stateCode == E.STATE_UNAVAILABLE then
        if ev.farmIdOr0 ~= 0 or ev.totalRowCount ~= 0 or ev.chunkCount ~= 1 or ev.chunkIndex ~= 0 or ev.chunkRowCount ~= 0 then
            return false, "UNAVAILABLE_SHAPE"
        end
    else
        if ev.farmIdOr0 == 0 then return false, "FARM" end
        if ev.totalRowCount == 0 and (ev.chunkCount ~= 1 or ev.chunkRowCount ~= 0) then return false, "EMPTY_SHAPE" end
        if ev.chunkRowCount > ev.totalRowCount then return false, "COUNT" end
    end
    if type(ev.rows) ~= "table" or #ev.rows ~= ev.chunkRowCount then return false, "ROWS" end
    for _, row in ipairs(ev.rows) do
        local ok, why = E.validateRow(row)
        if not ok then return false, why end
    end
    return true
end

function DairyCollectionStatusResponseEvent.emptyNew()
    return Event.new(DairyCollectionStatusResponseEvent_mt)
end

--- header: { routeGeneration, viewGeneration, requestSequence, stateCode, farmIdOr0,
--- totalRowCount, chunkIndex, chunkCount, chunkRowCount }; rows: the chunk's rows.
function DairyCollectionStatusResponseEvent.new(header, rows)
    local self = Event.new(DairyCollectionStatusResponseEvent_mt)
    self.schema = cfg().SCHEMA
    self.routeGeneration = header.routeGeneration
    self.viewGeneration = header.viewGeneration
    self.requestSequence = header.requestSequence
    self.stateCode = header.stateCode
    self.farmIdOr0 = header.farmIdOr0
    self.totalRowCount = header.totalRowCount
    self.chunkIndex = header.chunkIndex
    self.chunkCount = header.chunkCount
    self.chunkRowCount = header.chunkRowCount
    self.rows = rows or {}
    self.valid = DairyCollectionStatusResponseEvent.validate(self)
    return self
end

function DairyCollectionStatusResponseEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.schema)
    streamWriteUInt32(streamId, self.routeGeneration)
    streamWriteString(streamId, self.viewGeneration)
    streamWriteUInt32(streamId, self.requestSequence)
    streamWriteUInt8(streamId, self.stateCode)
    streamWriteUInt8(streamId, self.farmIdOr0)
    streamWriteInt32(streamId, self.totalRowCount)
    streamWriteInt32(streamId, self.chunkIndex)
    streamWriteInt32(streamId, self.chunkCount)
    streamWriteInt32(streamId, self.chunkRowCount)
    for _, row in ipairs(self.rows) do
        streamWriteString(streamId, row.barnKey)
        streamWriteString(streamId, row.barnLabel)
        streamWriteUInt8(streamId, row.code)
        streamWriteBool(streamId, row.hasAttempt)
        streamWriteFloat32(streamId, row.hasAttempt and row.attemptHours or 0)
        streamWriteBool(streamId, row.hasNextDue)
        streamWriteFloat32(streamId, row.hasNextDue and row.nextDueHours or 0)
    end
end

function DairyCollectionStatusResponseEvent:readStream(streamId, connection)
    self.schema = streamReadUInt8(streamId)
    self.routeGeneration = streamReadUInt32(streamId)
    self.viewGeneration = streamReadString(streamId)
    self.requestSequence = streamReadUInt32(streamId)
    self.stateCode = streamReadUInt8(streamId)
    self.farmIdOr0 = streamReadUInt8(streamId)
    self.totalRowCount = streamReadInt32(streamId)
    self.chunkIndex = streamReadInt32(streamId)
    self.chunkCount = streamReadInt32(streamId)
    self.chunkRowCount = streamReadInt32(streamId)
    self.rows = {}
    -- A row count the layout cannot carry is not read at all; the rest of the
    -- stream cannot be trusted and run() rejects the chunk whole.
    local n = self.chunkRowCount
    if type(n) == "number" and n >= 0 and n <= cfg().DIRECT_MAX_ROWS_PER_CHUNK then
        for i = 1, n do
            local row = {}
            row.barnKey = streamReadString(streamId)
            row.barnLabel = streamReadString(streamId)
            row.code = streamReadUInt8(streamId)
            row.hasAttempt = streamReadBool(streamId)
            row.attemptHours = streamReadFloat32(streamId)
            row.hasNextDue = streamReadBool(streamId)
            row.nextDueHours = streamReadFloat32(streamId)
            self.rows[i] = row
        end
    end
    self.valid = DairyCollectionStatusResponseEvent.validate(self)
    self:run(connection)
end

--- Pure client only: the listen host is the server and holds the truth itself.
--- A response from anything but the server connection is refused.
function DairyCollectionStatusResponseEvent:run(connection)
    if g_currentMission == nil or g_currentMission:getIsServer() then return end
    local mgr = g_dairyCoreManager
    if mgr == nil then mgr = g_currentMission.dairyCoreManager end
    if mgr == nil or mgr._collectionDirectOnChunk == nil then return end
    mgr:_collectionDirectOnChunk(self, connection)
end
