-- =========================================================
-- FeedDesignationDialog - DC-11 field picker (deep engine dialog)
-- =========================================================
-- The missing surface of DC-11 section 3.1: lets a dairy farmer tell the mod
-- which of his fields feed which barn. Each add/remove calls the already-built
-- designateFeedField / undesignateFeedField on the manager, and the live state
-- shown is the same _getFieldInfo read the herd score uses, so what the farmer
-- sees is exactly what the score eats.
--
-- Deep tool, not Esc chrome: opened from the Dairy Esc glance footer button,
-- engine-native ScreenElement dialog, works with no FarmTablet installed. Writes
-- are server-gated in the manager; on a client the picker reads and says so.
-- =========================================================

---@class FeedDesignationDialog
FeedDesignationDialog = FeedDesignationDialog or {}
local FeedDesignationDialog_mt = Class(FeedDesignationDialog, ScreenElement)

local DC_FD_MOD_DIR = (DairyCoreModDirectory or g_currentModDirectory)
FeedDesignationDialog.INSTANCE = nil
FeedDesignationDialog.xmlPath = nil

local function tr(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" then return t end
    end
    return fallback or key
end

local function getMgr()
    if g_currentMission ~= nil and g_currentMission.dairyCoreManager ~= nil then
        return g_currentMission.dairyCoreManager
    end
    local env = getfenv and getfenv(0)
    return (env and env.g_dairyCoreManager) or g_dairyCoreManager
end

function FeedDesignationDialog.new(target, customMt)
    -- MUST chain the ScreenElement constructor so GuiElement state is initialized;
    -- a bare setmetatable leaves self.elements nil and loadGui crashes.
    local self = ScreenElement.new(target, customMt or FeedDesignationDialog_mt)
    self._barns = {}
    self._barnIndex = 1
    self._fields = {}
    self._fieldIndex = 1
    return self
end

function FeedDesignationDialog.register(modDirectory)
    if FeedDesignationDialog.INSTANCE ~= nil then return end
    DC_FD_MOD_DIR = modDirectory
    FeedDesignationDialog.xmlPath = modDirectory .. "xml/gui/FeedDesignationDialog.xml"
    FeedDesignationDialog.INSTANCE = FeedDesignationDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(
            FeedDesignationDialog.xmlPath,
            "FeedDesignationDialog",
            FeedDesignationDialog.INSTANCE
        )
    end)
    if not ok then
        DCLogger.error("FeedDesignationDialog: loadGui failed: %s", tostring(err))
        FeedDesignationDialog.INSTANCE = nil
    else
        DCLogger.info("FeedDesignationDialog: registered")
    end
end

function FeedDesignationDialog.show(startBarnId)
    if FeedDesignationDialog.INSTANCE == nil then
        FeedDesignationDialog.register(DC_FD_MOD_DIR)
    end
    local inst = FeedDesignationDialog.INSTANCE
    if inst == nil then return end
    inst._startBarnId = startBarnId
    if g_gui:getIsGuiVisible() then
        g_gui:showDialog("FeedDesignationDialog")
    else
        g_gui:showGui("FeedDesignationDialog")
    end
end

function FeedDesignationDialog:onGuiSetupFinished()
    FeedDesignationDialog:superClass().onGuiSetupFinished(self)
    self.fdTitle = self:getDescendantById("fdTitle")
    self.fdBarnHeader = self:getDescendantById("fdBarnHeader")
    self.fdBarnLabel = self:getDescendantById("fdBarnLabel")
    self.fdFieldHeader = self:getDescendantById("fdFieldHeader")
    self.fdFieldState = self:getDescendantById("fdFieldState")
    self.fdDesignation = self:getDescendantById("fdDesignation")
    self.fdHint = self:getDescendantById("fdHint")
end

function FeedDesignationDialog:onOpen()
    FeedDesignationDialog:superClass().onOpen(self)
    self:_rebuildBarns()
    if self._startBarnId ~= nil then
        for i, id in ipairs(self._barns) do
            if id == self._startBarnId then self._barnIndex = i break end
        end
    end
    self:_rebuildFields()
    self:_refresh()
end

function FeedDesignationDialog:onClose()
    FeedDesignationDialog:superClass().onClose(self)
end

function FeedDesignationDialog:onClickBack()
    g_gui:closeDialogByName("FeedDesignationDialog")
end

function FeedDesignationDialog:onClickPrevBarn()
    if #self._barns == 0 then return end
    self._barnIndex = self._barnIndex - 1
    if self._barnIndex < 1 then self._barnIndex = #self._barns end
    self:_rebuildFields()
    self:_refresh()
end

function FeedDesignationDialog:onClickNextBarn()
    if #self._barns == 0 then return end
    self._barnIndex = self._barnIndex + 1
    if self._barnIndex > #self._barns then self._barnIndex = 1 end
    self:_rebuildFields()
    self:_refresh()
end

function FeedDesignationDialog:onClickPrevField()
    if #self._fields == 0 then return end
    self._fieldIndex = self._fieldIndex - 1
    if self._fieldIndex < 1 then self._fieldIndex = #self._fields end
    self:_refresh()
end

function FeedDesignationDialog:onClickNextField()
    if #self._fields == 0 then return end
    self._fieldIndex = self._fieldIndex + 1
    if self._fieldIndex > #self._fields then self._fieldIndex = 1 end
    self:_refresh()
end

function FeedDesignationDialog:onClickToggle()
    local mgr = getMgr()
    local barnId = self._barns[self._barnIndex]
    local field = self._fields[self._fieldIndex]
    if mgr == nil or barnId == nil or field == nil then return end
    local fieldId = field.fieldId
    local ids = mgr:getBarnDesignations(barnId)
    local designated = false
    for _, id in ipairs(ids) do if id == fieldId then designated = true break end end
    if designated then
        mgr:undesignateFeedField(barnId, fieldId)
    else
        mgr:designateFeedField(barnId, fieldId)
    end
    self:_refresh()
end

function FeedDesignationDialog:_rebuildBarns()
    self._barns = {}
    local mgr = getMgr()
    if mgr == nil then return end
    local rows = mgr:getBarnRows() or {}
    table.sort(rows, function(a, b) return tostring(a.barnId) < tostring(b.barnId) end)
    for _, r in ipairs(rows) do
        self._barns[#self._barns + 1] = r.barnId
    end
    if self._barnIndex < 1 or self._barnIndex > #self._barns then self._barnIndex = 1 end
end

function FeedDesignationDialog:_rebuildFields()
    self._fields = {}
    local mgr = getMgr()
    local barnId = self._barns[self._barnIndex]
    if mgr == nil or barnId == nil then return end
    -- The farm the selected barn belongs to; its fields are the ones a farmer
    -- can designate. Falls back to the local player farm when the row lacks one.
    local farmId = nil
    local rows = mgr:getBarnRows() or {}
    for _, r in ipairs(rows) do
        if r.barnId == barnId then farmId = r.farmId break end
    end
    if farmId == nil or farmId == 0 then
        pcall(function()
            if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
                farmId = g_currentMission:getFarmId()
            end
        end)
    end
    local owned = mgr:getOwnedFeedFields(farmId) or {}
    -- Carry the designation flag so the readout can mark it immediately.
    local ids = mgr:getBarnDesignations(barnId)
    for _, f in ipairs(owned) do
        for _, id in ipairs(ids) do
            if id == f.fieldId then f.designated = true break end
        end
        self._fields[#self._fields + 1] = f
    end
    if self._fieldIndex < 1 or self._fieldIndex > #self._fields then self._fieldIndex = 1 end
end

--- BUILD 23:43: the barn row shows the human barn name, never the raw uniqueId.
--- DairyRfPdaGuest.barnLabel is the one name ladder for the mod (it loads before this
--- file in main.lua); the placeable walk below is the fallback for a standalone load.
local function humanBarnLabel(barnId)
    if DairyRfPdaGuest ~= nil and type(DairyRfPdaGuest.barnLabel) == "function" then
        local ok, name = pcall(DairyRfPdaGuest.barnLabel, { barnId = barnId })
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local ps = g_currentMission.placeableSystem
        if type(ps.getPlaceableByUniqueId) == "function" then
            local ok, placeable = pcall(function() return ps:getPlaceableByUniqueId(barnId) end)
            if ok and placeable ~= nil then
                if type(placeable.getName) == "function" then
                    local ok2, n = pcall(function() return placeable:getName() end)
                    if ok2 and type(n) == "string" and n ~= "" then return n end
                end
                if type(placeable.nameCustom) == "string" and placeable.nameCustom ~= "" then
                    return placeable.nameCustom
                end
            end
        end
    end
    local id = tostring(barnId or "?")
    if #id > 24 then return id:sub(1, 22) .. "..." end
    return id
end

local function npkLine(info)
    local function st(v)
        if v == nil then return "--" end
        return tostring(v.status or "--")
    end
    return "N " .. st(info.nitrogen) .. "  P " .. st(info.phosphorus) .. "  K " .. st(info.potassium)
end

function FeedDesignationDialog:_refresh()
    if self.fdTitle then
        self.fdTitle:setText(tr("dc_fd_title", "Feed Fields"))
    end
    local mgr = getMgr()
    local isServer = mgr == nil or mgr:_isServer()

    if self.fdBarnHeader then
        self.fdBarnHeader:setText(string.format(
            tr("dc_fd_barn_header", "Barn  (%d / %d)"),
            self._barnIndex, math.max(#self._barns, 1)
        ))
    end
    local barnId = self._barns[self._barnIndex]
    if self.fdBarnLabel then
        self.fdBarnLabel:setText(barnId ~= nil and humanBarnLabel(barnId) or tr("dc_fd_no_barns", "no barns"))
    end

    local field = self._fields[self._fieldIndex]
    if self.fdFieldHeader then
        if field == nil then
            self.fdFieldHeader:setText(tr("dc_fd_no_fields", "No owned fields"))
        else
            self.fdFieldHeader:setText(string.format(
                tr("dc_fd_field_header", "Field #%d  (%d / %d)"),
                field.fieldId, self._fieldIndex, math.max(#self._fields, 1)
            ))
        end
    end
    if self.fdFieldState then
        if field == nil then
            self.fdFieldState:setText(tr("dc_fd_state_empty",
                "Own a field to feed this barn. SoilFertilizer absent: no live state to show."))
        else
            local om = type(field.organicMatter) == "number" and string.format("%.1f", field.organicMatter) or "--"
            local weeds = type(field.weedPressure) == "number" and string.format("%d%%", field.weedPressure) or "--"
            local rot = type(field.rotationStatus) == "string" and field.rotationStatus or "--"
            local dis = "no"
            if (field.diseasePressure or 0) > 0 then dis = "yes" end
            self.fdFieldState:setText(string.format(
                tr("dc_fd_state", "OM %s    %s    Weeds %s    Rot %s    Disease %s"),
                om, npkLine(field), weeds, rot, dis
            ))
        end
    end
    if self.fdDesignation then
        if field == nil then
            self.fdDesignation:setText("")
        else
            local words = field.designated
                and tr("dc_fd_designated", "DESIGNATED to this barn")
                or tr("dc_fd_not_designated", "not designated")
            local server = isServer
                and ""
                or ("  (" .. tr("dc_fd_client_readonly", "server only") .. ")")
            self.fdDesignation:setText(words .. server)
        end
    end
    if self.fdHint then
        self.fdHint:setText(tr("dc_fd_hint",
            "Pick a barn, then step fields with the arrows. Toggle adds or removes the field's feed. Its soil state feeds the herd score daily."))
    end
end
