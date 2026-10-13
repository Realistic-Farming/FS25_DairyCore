-- =========================================================
-- FS25_DairyCore - DC-14 collection refusal: the routes a view travels
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Slice B of the DC-14 host (SDS v0.9 sections 4, 5 and 8; brief v1.0 sections
-- 4, 5 and 8). Slice A produced the farm-private view on the server; this file
-- carries it to a pure client and keeps every route's store apart.
--
-- ROUTES, per local endpoint, mission-lived:
--   LOCAL_PRODUCER  any server process with a local player: the getter reads the
--                   producer directly; nothing is ever sent to stream zero.
--   WAITING_NS      a pure client while NetworkSync's scoped service is waiting,
--                   for at most 10 real seconds from the first enabled wait.
--   NS_SCOPED       the scoped module dairy.collectionRefusal.v1: FULL or UNCHANGED
--                   publications, one detached flat scalar array, atomic apply.
--   DIRECT          Dairy's own request/response events, bounded ordered chunks,
--                   the farm derived from the actual connection, unicast only.
-- One recovery is permitted after NS_SCOPED and it is one-way: a fatal scoped
-- failure, or 10 visible seconds with demand and no APPLIED replica, moves this
-- endpoint to DIRECT, unregisters guardedly and never switches back.
-- A dedicated server has no local view; it registers the scoped provider and
-- answers DIRECT requests. NetworkSync is optional: absent, DIRECT is the floor.
--
-- STORES never cross: the NS replica, the DIRECT replica, the DIRECT staging and
-- the outstanding request are separate; the getter reads only the selected
-- route's store; a message from an unselected route is ignored; a local farm
-- change clears everything and increments the generation before any refresh.
-- =========================================================

local function rtIsFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function rtCfg()
    return DairyConstants.COLLECTION_REFUSAL
end

local function rtLog(fmt, ...)
    DCLogger.info("[DC14 ROUTE] " .. fmt, ...)
end

-- =========================================================
-- State
-- =========================================================

function DairyCoreManager:_resetCollectionRoute()
    local previous = self.collectionRoute
    self.collectionRoute = {
        route = "UNRESOLVED",
        generation = 1,            -- uint32 routeGeneration on the wire
        contextGeneration = 1,     -- bumps on every local farm or context change
        localFarmId = nil,
        nowMs = 0,
        -- NetworkSync scoped
        nsRegistered = false,
        nsWaitMs = nil,            -- accumulated wait since the first enabled wait
        nsFatal = false,
        nsFailedOver = false,
        nsReplica = nil,           -- { farmId, rows, dataRevision, generation }
        nsClockMs = nil,           -- post-selection availability clock
        nsRequestedFull = false,
        nsRegistrationGeneration = nil,
        -- DIRECT
        directReplica = nil,       -- { farmId, rows, generation }
        directStaging = nil,
        directOutstanding = nil,   -- { sequence, viewGeneration, generation, ageMs }
        directLastRequestMs = nil,
        directTimedOut = false,
        directError = nil,
        viewGeneration = nil,
        viewSerial = 0,
        sequence = 0,
        demand = {},               -- consumer -> last pulse ms
        demandActive = false,
        listeners = {},            -- fn(reason) called synchronously on a clear
        serverRate = {},           -- connection -> { windowStartMs, count }
        serverRegisterRetryMs = 0,
    }
    if previous ~= nil and type(previous.listeners) == "table" then
        self.collectionRoute.listeners = previous.listeners
    end
end

function DairyCoreManager:_collectionRoute()
    if self.collectionRoute == nil then self:_resetCollectionRoute() end
    return self.collectionRoute
end

--- Slice C (and any other local surface) registers a synchronous clear here: it
--- runs inside the farm-change handler before the callback returns.
function DairyCoreManager:addCollectionViewListener(fn)
    if type(fn) ~= "function" then return false end
    local st = self:_collectionRoute()
    st.listeners[#st.listeners + 1] = fn
    return true
end

local function rtNotify(st, reason)
    for _, fn in ipairs(st.listeners) do
        pcall(fn, reason)
    end
end

--- Slice A's revision hook: the shown projection changed. On the server the
--- scoped module is marked dirty so the 1 Hz cadence publishes FULL to the
--- farms whose view changed and UNCHANGED to the rest.
function DairyCoreManager:_collectionRouteOnRevision()
    if not self:_isServer() then return end
    local st = self:_collectionRoute()
    if not st.nsRegistered then return end
    local ns = self:_getNetworkSync()
    if ns ~= nil and ns.markDirty ~= nil then
        pcall(function() ns:markDirty(rtCfg().NETWORK_MODULE) end)
    end
end

-- =========================================================
-- The flat scalar vector (scoped) and its validation, shared by both ends
-- =========================================================

--- values = { schema, farmId, rowCount, then 7 scalars per sorted row }.
function DairyCoreManager:_collectionPackValues(farmId, rows)
    local values = { rtCfg().SCHEMA, farmId, #rows }
    for _, row in ipairs(rows) do
        local hasAttempt = row.code == rtCfg().ROW_CODES.FEE_EXCEEDS_PRICE
        local hasNext = row.nextDueHours ~= nil
        values[#values + 1] = row.barnKey
        values[#values + 1] = row.barnLabel
        values[#values + 1] = row.code
        values[#values + 1] = hasAttempt
        values[#values + 1] = hasAttempt and row.attemptHours or 0
        values[#values + 1] = hasNext
        values[#values + 1] = hasNext and row.nextDueHours or 0
    end
    return values
end

--- Returns the decoded rows, or nil and the reason. Every defect rejects the
--- whole vector: length, farm, count, key, label, code, flags, times, duplicates.
function DairyCoreManager:_collectionUnpackValues(values, expectedFarm)
    local C = rtCfg()
    if type(values) ~= "table" or values[1] ~= C.SCHEMA then return nil, "SCHEMA" end
    if values[2] ~= expectedFarm then return nil, "FARM" end
    local rowCount = values[3]
    if not rtIsFinite(rowCount) or rowCount < 0 or math.floor(rowCount) ~= rowCount then return nil, "COUNT" end
    if #values ~= 3 + rowCount * 7 then return nil, "LENGTH" end
    local rows, seen, offset = {}, {}, 4
    for _ = 1, rowCount do
        local row = {
            barnKey = values[offset], barnLabel = values[offset + 1], code = values[offset + 2],
            hasAttempt = values[offset + 3], attemptHours = values[offset + 4],
            hasNextDue = values[offset + 5], nextDueHours = values[offset + 6],
        }
        local ok, why = DairyCollectionStatusResponseEvent.validateRow(row)
        if not ok then return nil, why end
        if seen[row.barnKey] then return nil, "DUPLICATE" end
        seen[row.barnKey] = true
        rows[#rows + 1] = self:_collectionRowFromWire(row)
        offset = offset + 7
    end
    return rows
end

--- A wire row becomes a view row of slice A's shape.
function DairyCoreManager:_collectionRowFromWire(w)
    local C = rtCfg()
    local row = { barnKey = w.barnKey, barnLabel = w.barnLabel, code = w.code }
    if w.code == C.ROW_CODES.FEE_EXCEEDS_PRICE then
        row.state = C.ROW_STATES.FEE_EXCEEDS_PRICE
        row.attemptHours = w.attemptHours
    elseif w.code == C.ROW_CODES.UNAVAILABLE then
        row.state = C.ROW_STATES.UNAVAILABLE
        row.reason = C.ROW_REASONS.EVALUATION_ERROR
    else
        row.state = C.ROW_STATES.NONE_RECORDED
    end
    if w.hasNextDue then row.nextDueHours = w.nextDueHours end
    return row
end

local function rtCopyRows(rows)
    local out = {}
    for i, r in ipairs(rows or {}) do
        local c = {}
        for k, v in pairs(r) do c[k] = v end
        out[i] = c
    end
    return out
end

-- =========================================================
-- NetworkSync scoped module: the spec both ends register
-- =========================================================

function DairyCoreManager:_collectionScopedSpec()
    local mgr = self
    return {
        buildView = function(context, previous, forceFull) return mgr:_collectionBuildView(context, previous, forceFull) end,
        applyView = function(publication) return mgr:_collectionApplyView(publication) end,
        clearView = function(reason) return mgr:_collectionClearView(reason) end,
    }
end

--- Server producer. Only a RESOLVED actor with a strict real farm gets READY;
--- the values are the farm's rows packed flat, FULL when the view key or the
--- Dairy revision moved, UNCHANGED otherwise.
function DairyCoreManager:_collectionBuildView(context, previous, forceFull)
    local C = rtCfg()
    if self.disabled then return { state = "UNAVAILABLE", reason = "PF_STAND_DOWN" } end
    if self.settings == nil or self.settings.enabled == false then
        return { state = "UNAVAILABLE", reason = C.REASONS.SETTINGS_OFF }
    end
    if type(context) ~= "table" then return { state = "ERROR", reason = "NO_CONTEXT" } end
    if context.actorState == "WAITING" then return { state = "WAITING", reason = "ACTOR_WAITING" } end
    if context.actorState ~= "RESOLVED" then return { state = "DENIED", reason = C.REASONS.NO_REAL_FARM } end
    local farmId = self:_collectionRealFarmId(context.farmId)
    if farmId == nil then return { state = "DENIED", reason = C.REASONS.NO_REAL_FARM } end
    local rows = self:_collectionRefusalRows(farmId)
    local values = self:_collectionPackValues(farmId, rows)
    -- The producer checks its own packing against the consumer's rule, so a bad
    -- row is refused here rather than rejected on every client.
    local decoded, why = self:_collectionUnpackValues(values, farmId)
    if decoded == nil then return { state = "ERROR", reason = "MALFORMED_" .. tostring(why) } end
    local viewKey = "dc14:" .. tostring(farmId) .. ":" .. tostring(context.serverSession)
    local dataRevision = "r" .. tostring(self:_collectionRefusalState().revision)
    local mode = "FULL"
    if not forceFull and type(previous) == "table" and previous.viewKey == viewKey and previous.dataRevision == dataRevision then
        mode = "UNCHANGED"
    end
    return { state = "READY", viewKey = viewKey, dataRevision = dataRevision, mode = mode,
        values = mode == "FULL" and values or nil }
end

--- Client consumer. Applies only on the selected NS route for the current
--- farm; a malformed vector is TERMINAL (fatal recovery follows), a vector for
--- another farm is RETRYABLE (NetworkSync resyncs).
function DairyCoreManager:_collectionApplyView(publication)
    local st = self:_collectionRoute()
    if self:_isServer() or st.route ~= "NS_SCOPED" then
        return { outcome = "RETRYABLE", reason = "ROUTE" }
    end
    if type(publication) ~= "table" or publication.mode == "DELTA" then
        return { outcome = "TERMINAL", reason = "UNSUPPORTED_MODE" }
    end
    local farmId = self:_collectionLocalFarmId()
    if farmId == nil then return { outcome = "RETRYABLE", reason = rtCfg().REASONS.NO_REAL_FARM } end
    local rows, why = self:_collectionUnpackValues(publication.values, farmId)
    if rows == nil then
        if why == "FARM" then return { outcome = "RETRYABLE", reason = "FARM" } end
        st.nsFatal = true
        return { outcome = "TERMINAL", reason = "MALFORMED_" .. tostring(why) }
    end
    st.nsReplica = { farmId = farmId, rows = rows, dataRevision = publication.dataRevision, generation = st.generation }
    st.nsClockMs = nil
    st.nsRequestedFull = false
    return { outcome = "APPLIED", dataRevision = publication.dataRevision }
end

--- Client clear. An ordinary NEW_GENERATION clear re-arms the availability
--- clock; a clear during our own failover is ignored (the route is DIRECT by
--- then); any other reason latches fatal recovery. The DIRECT store is never
--- touched from here.
function DairyCoreManager:_collectionClearView(reason)
    local st = self:_collectionRoute()
    if self:_isServer() or st.route ~= "NS_SCOPED" then return end
    st.nsReplica = nil
    if reason == "NEW_GENERATION" or reason == "LOCAL_CONTEXT_CHANGED" then
        st.nsClockMs = nil
        st.nsRequestedFull = false
    elseif reason == "MODULE_UNREGISTERED" then
        return
    else
        st.nsFatal = true
    end
end

-- =========================================================
-- Route selection
-- =========================================================

--- Server: register the scoped provider once the capability is ready (retried
--- from update while it waits). PF stand-down registers nothing.
function DairyCoreManager:_collectionServerRegister()
    if self.disabled or not self:_isServer() then return false end
    local st = self:_collectionRoute()
    st.route = "LOCAL_PRODUCER"
    if st.nsRegistered then return true end
    local ns = self:_getNetworkSync()
    if ns == nil or ns.getScopedCapabilities == nil or ns.registerScopedModule == nil then return false end
    local ok, caps = pcall(ns.getScopedCapabilities, ns)
    if not ok or type(caps) ~= "table" or caps.ready ~= true then return false end
    local okReg, registered = pcall(ns.registerScopedModule, ns, rtCfg().NETWORK_MODULE, self:_collectionScopedSpec())
    st.nsRegistered = okReg and registered == true
    rtLog("server scoped provider %s", st.nsRegistered and "REGISTERED" or "REFUSED")
    return st.nsRegistered
end

--- Pure client: the one selection this endpoint makes, bounded by the wait.
function DairyCoreManager:_collectionRouteSelect(dtMs)
    local st = self:_collectionRoute()
    if self.disabled then return st.route end
    if self:_isServer() then
        self:_collectionServerRegister()
        return st.route
    end
    if st.route == "NS_SCOPED" or st.route == "DIRECT" then return st.route end
    if self.settings == nil or self.settings.enabled == false then return st.route end
    local ns = self:_getNetworkSync()
    if ns == nil or ns.getScopedCapabilities == nil or ns.registerScopedModule == nil then
        st.route = "DIRECT"
        rtLog("client route DIRECT (no scoped service)")
        return st.route
    end
    local ok, caps = pcall(ns.getScopedCapabilities, ns)
    if ok and type(caps) == "table" and caps.ready == true then
        local okReg, registered = pcall(ns.registerScopedModule, ns, rtCfg().NETWORK_MODULE, self:_collectionScopedSpec())
        if okReg and registered == true then
            st.route = "NS_SCOPED"
            st.nsRegistered = true
            st.nsRegistrationGeneration = st.contextGeneration
            rtLog("client route NS_SCOPED")
        else
            st.route = "DIRECT"
            rtLog("client route DIRECT (scoped registration refused)")
        end
        return st.route
    end
    -- Waiting (or not initialised yet): bounded from the first enabled wait.
    st.route = "WAITING_NS"
    st.nsWaitMs = (st.nsWaitMs or 0) + (dtMs or 0)
    if st.nsWaitMs >= rtCfg().NS_WAIT_MS then
        st.route = "DIRECT"
        rtLog("client route DIRECT (scoped service waited %d ms)", st.nsWaitMs)
    end
    return st.route
end

--- The one-way recovery: NS_SCOPED to DIRECT for this endpoint, for the mission.
function DairyCoreManager:_collectionFailOver(why)
    local st = self:_collectionRoute()
    if st.route ~= "NS_SCOPED" then return end
    -- uint32 on the wire, 1 at birth: the wrap goes back to 1, never to 0 (and never
    -- through a float, which a 32-bit integer runtime would make of 2^32).
    st.generation = st.generation >= 4294967295 and 1 or st.generation + 1
    st.route = "DIRECT"
    st.nsFailedOver = true
    st.nsReplica = nil
    st.nsClockMs = nil
    st.nsRequestedFull = false
    st.directReplica = nil
    st.directStaging = nil
    st.directOutstanding = nil
    st.directTimedOut = false
    st.directError = nil
    local ns = self:_getNetworkSync()
    if ns ~= nil and ns.unregisterScopedModule ~= nil then
        pcall(ns.unregisterScopedModule, ns, rtCfg().NETWORK_MODULE)
    end
    st.nsRegistered = false
    rtLog("client failed over to DIRECT (%s), generation %d", tostring(why), st.generation)
    rtNotify(st, "FAILOVER")
end

-- =========================================================
-- Demand and the clocks
-- =========================================================

--- A visible render path pulses its consumer ("ESC" from the Dairy Esc guest's
--- onShow, "TABLET" from the open Dairy Tablet drawer). Nothing else starts a
--- request; a consumer that stops pulsing is inactive after the light-refresh
--- window and its clock does not advance.
function DairyCoreManager:pulseCollectionDemand(consumer)
    local st = self:_collectionRoute()
    if self.disabled or self:_isServer() then return end
    local wasActive = self:_collectionDemandActive()
    st.demand[tostring(consumer or "ESC")] = st.nowMs
    if self.settings == nil or self.settings.enabled == false then return end
    local farmId = self:_collectionLocalFarmId()
    if farmId == nil then return end
    self:_collectionRouteSelect(0)
    if st.route == "NS_SCOPED" then
        if not self:_collectionNsReplicaUsable(farmId) and st.nsClockMs == nil then
            st.nsClockMs = 0
            if not st.nsRequestedFull then
                st.nsRequestedFull = true
                local ns = self:_getNetworkSync()
                if ns ~= nil and ns.requestScopedFull ~= nil then
                    pcall(ns.requestScopedFull, ns, rtCfg().NETWORK_MODULE)
                end
            end
        end
    elseif st.route == "DIRECT" then
        if not wasActive then
            -- A new demand interval: prior staging and usable cache go, the view
            -- token advances, one request goes out.
            st.directStaging = nil
            st.directOutstanding = nil
            st.directReplica = nil
            st.directTimedOut = false
            st.directError = nil
            self:_collectionNewViewGeneration()
            self:_collectionDirectRequest()
        elseif st.directOutstanding == nil
            and (st.directLastRequestMs == nil or st.nowMs - st.directLastRequestMs >= rtCfg().DIRECT_RETRY_MS) then
            self:_collectionDirectRequest()
        end
    end
end

--- A render path that stops showing ends its demand at once rather than letting the
--- window run out: the Esc guest's registry listener calls this when another module takes
--- the door (brief section 8). Clearing the mark only; an outstanding request completes or
--- times out on its own and its reply is applied like any other.
function DairyCoreManager:endCollectionDemand(consumer)
    local st = self:_collectionRoute()
    st.demand[tostring(consumer or "ESC")] = nil
end

function DairyCoreManager:_collectionDemandActive()
    local st = self:_collectionRoute()
    local window = rtCfg().DEMAND_WINDOW_MS
    for _, last in pairs(st.demand) do
        if st.nowMs - last <= window then return true end
    end
    return false
end

function DairyCoreManager:_collectionNsReplicaUsable(farmId)
    local st = self:_collectionRoute()
    local r = st.nsReplica
    return r ~= nil and r.generation == st.generation and r.farmId == farmId
end

--- Per frame from DairyCoreManager:update: the real-time clocks.
function DairyCoreManager:_collectionRouteUpdate(dt)
    local st = self:_collectionRoute()
    dt = rtIsFinite(dt) and dt or 0
    st.nowMs = st.nowMs + dt
    if self.disabled then return end
    if self:_isServer() then
        if not st.nsRegistered then
            st.serverRegisterRetryMs = st.serverRegisterRetryMs + dt
            if st.serverRegisterRetryMs >= 500 then
                st.serverRegisterRetryMs = 0
                self:_collectionServerRegister()
            end
        end
        return
    end
    if st.route == "UNRESOLVED" or st.route == "WAITING_NS" then
        if self.settings ~= nil and self.settings.enabled ~= false then self:_collectionRouteSelect(dt) end
    end
    local active = self:_collectionDemandActive()
    if st.route == "NS_SCOPED" then
        if st.nsFatal then
            self:_collectionFailOver("TERMINAL")
            return
        end
        if st.nsClockMs ~= nil then
            if not active then
                st.nsClockMs = nil
                st.nsRequestedFull = false
            else
                st.nsClockMs = st.nsClockMs + dt
                if st.nsClockMs >= rtCfg().NS_AVAILABILITY_MS then
                    self:_collectionFailOver("NO_APPLIED_IN_TIME")
                end
            end
        end
    elseif st.route == "DIRECT" then
        local out = st.directOutstanding
        if out ~= nil then
            out.ageMs = out.ageMs + dt
            if out.ageMs >= rtCfg().DIRECT_TIMEOUT_MS then
                st.directStaging = nil
                st.directOutstanding = nil
                st.directReplica = nil
                st.directTimedOut = true
                rtLog("DIRECT request %d timed out", out.sequence)
            end
        end
    end
end

-- =========================================================
-- DIRECT: the client side
-- =========================================================

function DairyCoreManager:_collectionNewViewGeneration()
    local st = self:_collectionRoute()
    st.viewSerial = st.viewSerial + 1
    st.viewGeneration = "v" .. tostring(st.generation) .. "-" .. tostring(st.viewSerial)
    st.sequence = 0
end

local function rtServerConnection()
    if g_client == nil or g_client.getServerConnection == nil then return nil end
    local ok, conn = pcall(g_client.getServerConnection, g_client)
    if not ok or conn == nil then return nil end
    return conn
end

function DairyCoreManager:_collectionDirectRequest()
    local st = self:_collectionRoute()
    if DairyCollectionStatusRequestEvent == nil then return false end
    if st.viewGeneration == nil or st.sequence >= 2147483647 then self:_collectionNewViewGeneration() end
    st.sequence = st.sequence + 1
    local ev = DairyCollectionStatusRequestEvent.new(st.generation, st.viewGeneration, st.sequence)
    if not ev.valid then return false end
    local conn = rtServerConnection()
    if conn == nil then return false end
    local ok = pcall(function() conn:sendEvent(ev) end)
    if not ok then return false end
    st.directOutstanding = { sequence = st.sequence, viewGeneration = st.viewGeneration, generation = st.generation, ageMs = 0 }
    st.directStaging = nil
    st.directLastRequestMs = st.nowMs
    return true
end

local function rtDiscard(st, why)
    st.directStaging = nil
    st.directOutstanding = nil
    st.directError = why
    rtLog("DIRECT response discarded (%s)", tostring(why))
end

--- One response chunk. Accepted only from the server connection, on the DIRECT
--- route, for the outstanding generation, view token and sequence, and for the
--- strict local farm. Chunks may arrive out of order; a repeated index, an
--- inconsistent header, a bad row or a population mismatch discards the whole
--- staging set. Apply is atomic when every chunk is present.
function DairyCoreManager:_collectionDirectOnChunk(ev, connection)
    local st = self:_collectionRoute()
    if self:_isServer() or st.route ~= "DIRECT" then return end
    if connection == nil or type(connection.getIsServer) ~= "function" or not connection:getIsServer() then return end
    if type(ev) ~= "table" or ev.valid ~= true then
        if st.directOutstanding ~= nil then rtDiscard(st, "MALFORMED") end
        return
    end
    local out = st.directOutstanding
    if out == nil or ev.routeGeneration ~= out.generation or ev.viewGeneration ~= out.viewGeneration
        or ev.requestSequence ~= out.sequence then
        return   -- a different generation, token or sequence: not ours any more
    end
    local E = DairyCollectionStatusResponseEvent
    if ev.stateCode == E.STATE_UNAVAILABLE then
        st.directStaging = nil
        st.directOutstanding = nil
        st.directReplica = nil
        st.directError = rtCfg().REASONS.TRANSPORT_ERROR
        return
    end
    local farmId = self:_collectionLocalFarmId()
    if farmId == nil or ev.farmIdOr0 ~= farmId then
        rtDiscard(st, "FARM")
        return
    end
    local staging = st.directStaging
    if staging == nil then
        staging = { totalRowCount = ev.totalRowCount, chunkCount = ev.chunkCount, farmId = ev.farmIdOr0,
            chunks = {}, received = 0, rowsReceived = 0 }
        st.directStaging = staging
    elseif staging.totalRowCount ~= ev.totalRowCount or staging.chunkCount ~= ev.chunkCount or staging.farmId ~= ev.farmIdOr0 then
        rtDiscard(st, "HEADER")
        return
    end
    if staging.chunks[ev.chunkIndex] ~= nil then
        rtDiscard(st, "DUPLICATE_CHUNK")
        return
    end
    staging.chunks[ev.chunkIndex] = ev.rows
    staging.received = staging.received + 1
    staging.rowsReceived = staging.rowsReceived + #ev.rows
    if staging.received < staging.chunkCount then return end
    if staging.rowsReceived ~= staging.totalRowCount then
        rtDiscard(st, "POPULATION")
        return
    end
    local rows, seen = {}, {}
    for index = 0, staging.chunkCount - 1 do
        for _, w in ipairs(staging.chunks[index] or {}) do
            if seen[w.barnKey] then
                rtDiscard(st, "DUPLICATE_KEY")
                return
            end
            seen[w.barnKey] = true
            rows[#rows + 1] = self:_collectionRowFromWire(w)
        end
    end
    st.directReplica = { farmId = farmId, rows = rows, generation = st.generation }
    st.directStaging = nil
    st.directOutstanding = nil
    st.directTimedOut = false
    st.directError = nil
end

-- =========================================================
-- DIRECT: the server side
-- =========================================================

--- Chunk a farm's rows within the application budget. Returns the chunk list,
--- or nil when a row or the chunk count exceeds the bounds (never truncated).
function DairyCoreManager:_collectionDirectChunks(viewGeneration, rows)
    local C = rtCfg()
    local E = DairyCollectionStatusResponseEvent
    local headerBytes = E.estimateBytes(viewGeneration, {})
    local chunks, current, currentBytes = {}, {}, headerBytes
    for _, row in ipairs(rows) do
        local w = {
            barnKey = row.barnKey, barnLabel = row.barnLabel, code = row.code,
            hasAttempt = row.code == C.ROW_CODES.FEE_EXCEEDS_PRICE,
            attemptHours = row.code == C.ROW_CODES.FEE_EXCEEDS_PRICE and row.attemptHours or 0,
            hasNextDue = row.nextDueHours ~= nil,
            nextDueHours = row.nextDueHours or 0,
        }
        local rowBytes = E.estimateRowBytes(w)
        if headerBytes + rowBytes > C.DIRECT_BUDGET_BYTES then return nil, "ROW_OVER_BUDGET" end
        if currentBytes + rowBytes > C.DIRECT_BUDGET_BYTES or #current >= C.DIRECT_MAX_ROWS_PER_CHUNK then
            chunks[#chunks + 1] = current
            current, currentBytes = {}, headerBytes
        end
        current[#current + 1] = w
        currentBytes = currentBytes + rowBytes
    end
    if #current > 0 or #chunks == 0 then chunks[#chunks + 1] = current end
    if #chunks > C.DIRECT_MAX_CHUNKS then return nil, "TOO_MANY_CHUNKS" end
    return chunks
end

local function rtRateAllows(st, connection, nowMs)
    local limit = rtCfg().DIRECT_MAX_REQUESTS_PER_SECOND
    local rec = st.serverRate[connection]
    if rec == nil or nowMs - rec.windowStartMs >= 1000 then
        rec = { windowStartMs = nowMs, count = 0 }
        st.serverRate[connection] = rec
    end
    rec.count = rec.count + 1
    return rec.count <= limit
end

--- A client's request. Silence for a malformed or rate-limited request; a
--- header-only UNAVAILABLE for a connection whose farm cannot be resolved; else
--- the complete snapshot for the farm the connection actually owns, unicast.
function DairyCoreManager:_collectionDirectOnRequest(req, connection)
    if self.disabled or not self:_isServer() then return end
    if connection == nil or type(connection.sendEvent) ~= "function" then return end
    if type(req) ~= "table" or req.valid ~= true then return end
    local st = self:_collectionRoute()
    if not rtRateAllows(st, connection, st.nowMs) then return end
    local E = DairyCollectionStatusResponseEvent
    local header = { routeGeneration = req.routeGeneration, viewGeneration = req.viewGeneration,
        requestSequence = req.requestSequence, stateCode = E.STATE_UNAVAILABLE, farmIdOr0 = 0,
        totalRowCount = 0, chunkIndex = 0, chunkCount = 1, chunkRowCount = 0 }
    local function unavailable(why)
        rtLog("DIRECT request from a connection answered UNAVAILABLE (%s)", tostring(why))
        pcall(function() connection:sendEvent(E.new(header, {})) end)
    end
    if self.settings == nil or self.settings.enabled == false then unavailable("SETTINGS_OFF") return end
    local farmId = nil
    pcall(function()
        if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
            farmId = g_currentMission:getFarmId(connection)
        end
    end)
    farmId = self:_collectionRealFarmId(farmId)
    if farmId == nil then unavailable("NO_REAL_FARM") return end
    local rows = self:_collectionRefusalRows(farmId)
    local chunks, why = self:_collectionDirectChunks(req.viewGeneration, rows)
    if chunks == nil then unavailable(why) return end
    for index, chunk in ipairs(chunks) do
        local h = { routeGeneration = req.routeGeneration, viewGeneration = req.viewGeneration,
            requestSequence = req.requestSequence, stateCode = E.STATE_READY, farmIdOr0 = farmId,
            totalRowCount = #rows, chunkIndex = index - 1, chunkCount = #chunks, chunkRowCount = #chunk }
        local ev = E.new(h, chunk)
        if not ev.valid then unavailable("MALFORMED_CHUNK") return end
        pcall(function() connection:sendEvent(ev) end)
    end
end

-- =========================================================
-- The local farm change (section 8) and the mission boundaries
-- =========================================================

--- MessageType.PLAYER_FARM_CHANGED handler. The engine publishes it for ANY
--- player's switch, with a Player at PlayerSetFarmEvent.lua:40 and :54 and the
--- player looked up by user id at PlayerSwitchedFarmEvent.lua:42, so the argument
--- is ignored: the strict local farm is re-read and only a change of it clears.
function DairyCoreManager:_onCollectionFarmChanged(_)
    if self.disabled then return end
    local st = self:_collectionRoute()
    local farmId = self:_collectionLocalFarmId()
    if farmId == st.localFarmId then return end
    st.localFarmId = farmId
    self:_collectionClearLocalContext("FARM_CHANGED")
end

--- Synchronous clear of both stores, staging, the outstanding request and every
--- painted surface (listeners), then a new generation; the next visible demand
--- refreshes. The NS registration is re-armed rather than re-made.
function DairyCoreManager:_collectionClearLocalContext(reason)
    local st = self:_collectionRoute()
    st.nsReplica = nil
    st.nsClockMs = nil
    st.nsRequestedFull = false
    st.directReplica = nil
    st.directStaging = nil
    st.directOutstanding = nil
    st.directTimedOut = false
    st.directError = nil
    -- uint32 on the wire, 1 at birth: the wrap goes back to 1, never to 0 (and never
    -- through a float, which a 32-bit integer runtime would make of 2^32).
    st.generation = st.generation >= 4294967295 and 1 or st.generation + 1
    st.contextGeneration = st.contextGeneration + 1
    st.nsRegistrationGeneration = st.contextGeneration
    st.demandActive = false
    self:_collectionNewViewGeneration()
    rtNotify(st, reason)
end

--- MAINTENANCE row 97: a departed connection's DIRECT rate record leaves the table.
--- The engine publishes USER_REMOVED when a connection closes
--- (FSBaseMission:onConnectionClosed -> UserManager:removeUserByConnection,
--- users/UserManager.lua:23-31, MessageType.lua:94) with the User, whose connection
--- (User:getConnection, users/User.lua:71-72) is the key rtRateAllows used. Without this
--- the table held one record per connection that ever asked, for the mission.
function DairyCoreManager:_onCollectionUserRemoved(user)
    if type(user) ~= "table" or type(user.getConnection) ~= "function" then return end
    local ok, connection = pcall(user.getConnection, user)
    if not ok or connection == nil then return end
    local st = self.collectionRoute
    if st ~= nil and type(st.serverRate) == "table" then
        st.serverRate[connection] = nil
    end
end

function DairyCoreManager:_collectionRouteBind()
    if self.disabled then return end
    self:_resetCollectionRoute()
    local st = self:_collectionRoute()
    st.localFarmId = self:_collectionLocalFarmId()
    if self:_isServer() then
        self:_collectionServerRegister()
        -- Row 97: only the server keeps rate records, so only the server listens.
        pcall(function()
            if g_messageCenter ~= nil and MessageType ~= nil and MessageType.USER_REMOVED ~= nil then
                g_messageCenter:subscribe(MessageType.USER_REMOVED, self._onCollectionUserRemoved, self)
                st.userRemovedBound = true
            end
        end)
    end
    pcall(function()
        if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PLAYER_FARM_CHANGED ~= nil then
            g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self._onCollectionFarmChanged, self)
            st.farmChangeBound = true
        end
    end)
end

function DairyCoreManager:_collectionRouteTeardown()
    local st = self:_collectionRoute()
    if st.farmChangeBound and g_messageCenter ~= nil then
        pcall(function() g_messageCenter:unsubscribe(MessageType.PLAYER_FARM_CHANGED, self) end)
    end
    -- Row 97: this type only, and this callback only (MessageCenter:unsubscribe matches
    -- the target and, when given, the callback, MessageCenter.lua:53-66). Never
    -- unsubscribeAll: the manager subscribes other types with the same self
    -- (DairyCoreManager.lua:129, :3691-3697).
    if st.userRemovedBound and g_messageCenter ~= nil then
        pcall(function() g_messageCenter:unsubscribe(MessageType.USER_REMOVED, self, self._onCollectionUserRemoved) end)
    end
    if st.nsRegistered then
        local ns = self:_getNetworkSync()
        if ns ~= nil and ns.unregisterScopedModule ~= nil then
            pcall(ns.unregisterScopedModule, ns, rtCfg().NETWORK_MODULE)
        end
    end
    rtNotify(st, "MISSION_END")
    self:_resetCollectionRoute()
end

-- =========================================================
-- The pure client's answer to the getter
-- =========================================================

--- Slice A's getter calls this on a machine that is not the server. The strict
--- farm has already been admitted. The answer reads only the selected route's
--- store; the route is selected without pulsing (a pulse is a render path's).
function DairyCoreManager:_collectionClientView(farmId)
    local C = rtCfg()
    local st = self:_collectionRoute()
    self:_collectionRouteSelect(0)
    local function waiting(reason) return { state = C.STATES.WAITING, reason = reason, rows = {} } end
    if st.route == "WAITING_NS" or st.route == "UNRESOLVED" then
        return waiting(C.REASONS.NS_READY_WAIT)
    elseif st.route == "NS_SCOPED" then
        if self:_collectionNsReplicaUsable(farmId) then
            return { state = C.STATES.READY, reason = nil, rows = rtCopyRows(st.nsReplica.rows) }
        end
        return waiting(C.REASONS.FIRST_SNAPSHOT)
    elseif st.route == "DIRECT" then
        local r = st.directReplica
        if r ~= nil and r.generation == st.generation and r.farmId == farmId then
            return { state = C.STATES.READY, reason = nil, rows = rtCopyRows(r.rows) }
        end
        if st.directTimedOut then
            return { state = C.STATES.UNAVAILABLE, reason = C.REASONS.TRANSPORT_TIMEOUT, rows = {} }
        end
        if st.directError ~= nil then
            return { state = C.STATES.UNAVAILABLE, reason = C.REASONS.TRANSPORT_ERROR, rows = {} }
        end
        return waiting(C.REASONS.FIRST_SNAPSHOT)
    end
    return waiting(C.REASONS.FIRST_SNAPSHOT)
end
