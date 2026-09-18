-- =========================================================
-- Dairy Field Guide - Field Guide
-- =========================================================
-- BUILD 19:15 (George CLOSED DESIGN 18:55 item 5): every Realistic Farming Esc page gets its own
-- guide, in its own mod, opened from the shared Help footer through this guest's onOpenHelp. The
-- chrome is SoilGuideDialog's so all of them read as one family; only the words differ.
-- Rows are { t = "H" | "B" | "S" | "COL", v = "text" }: header, body, spacer, column break.
-- =========================================================

---@class DairyGuideDialog
DairyGuideDialog = DairyGuideDialog or {}
local DairyGuideDialog_mt = Class(DairyGuideDialog, ScreenElement)

local GUIDE_MOD_DIR = (DairyCoreModDirectory or g_currentModDirectory)

DairyGuideDialog.INSTANCE = nil
DairyGuideDialog.GUI_NAME = "DairyGuideDialog"

DairyGuideDialog.SUBTITLES = {
    "Overview - what Dairy Core does and where its page is",
    "Barn Cards - reading one barn card top to bottom",
    "Herd Quality - health, grades and the spoilage clock",
    "Feed and Milk - stored feed, contamination and breeds",
    "Settings - the options, and common questions",
}

DairyGuideDialog.PAGE1 = {
    { t="H", v="WHAT DAIRY CORE DOES" },
    { t="B", v="Dairy Core adds a dairy layer to your farm." },
    { t="B", v="It finds every barn you own that produces" },
    { t="B", v="milk and keeps a small set of books on it." },
    { t="B", v="Once a day it scores the herd, sets a milk" },
    { t="B", v="quality grade, and runs a spoilage clock on" },
    { t="B", v="the milk waiting in the barn." },
    { t="B", v="It also remembers the quality of the feed" },
    { t="B", v="your farm harvests." },
    { t="S", v=" " },
    { t="H", v="WHERE TO FIND IT" },
    { t="B", v="Press Escape and open the Realistic Farming" },
    { t="B", v="page." },
    { t="B", v="Pick Dairy from the module list down the" },
    { t="B", v="left side." },
    { t="B", v="The wide area on the right fills with barn" },
    { t="B", v="cards." },
    { t="S", v=" " },
    { t="H", v="THE LEFT SIDE" },
    { t="B", v="The list of modules sits at the top left." },
    { t="B", v="Under it is a short Dairy help text and," },
    { t="B", v="below that, how many barns you have." },
    { t="COL", v="" },
    { t="H", v="THE BARN CARDS" },
    { t="B", v="One card per barn, four to a page, two" },
    { t="B", v="across and two down." },
    { t="B", v="Each card carries the barn name, a state" },
    { t="B", v="line, the herd by breed, the milk in the" },
    { t="B", v="tank by breed, and the farm's stored feed." },
    { t="S", v=" " },
    { t="H", v="TURNING PAGES" },
    { t="B", v="With more than four barns the rest sit on" },
    { t="B", v="later pages." },
    { t="B", v="Press the comma key to step back a page and" },
    { t="B", v="the period key to step forward." },
    { t="B", v="The help text says how many barns are left" },
    { t="B", v="after the page you are on." },
    { t="S", v=" " },
    { t="H", v="IT ONLY SHOWS, IT DOES NOT DO" },
    { t="B", v="This page is a read-only glance." },
    { t="B", v="Nothing on it schedules a collection, sells" },
    { t="B", v="milk or changes a barn." },
    { t="B", v="If a value cannot be proved, the card says" },
    { t="B", v="so in words instead of guessing." },
}

DairyGuideDialog.PAGE2 = {
    { t="H", v="THE BARN NAME" },
    { t="B", v="The top line of a card is the barn's own" },
    { t="B", v="name." },
    { t="B", v="A barn with no name yet shows a short code" },
    { t="B", v="instead." },
    { t="S", v=" " },
    { t="H", v="THE STATE LINE" },
    { t="B", v="Under the name is one line with three" },
    { t="B", v="readings." },
    { t="B", v="Herd Health is a score out of 100." },
    { t="B", v="Sale quality is the grade the barn's milk" },
    { t="B", v="carries today." },
    { t="B", v="Spoilage is the stage of the milk clock, or" },
    { t="B", v="clock idle when it has not started." },
    { t="S", v=" " },
    { t="H", v="HERD NOW" },
    { t="B", v="The first block counts the milking animals" },
    { t="B", v="standing in the barn today." },
    { t="B", v="The header gives the total head." },
    { t="B", v="Under it comes one row per breed with its" },
    { t="B", v="head count and its share of the herd." },
    { t="B", v="A long list scrolls inside the card." },
    { t="COL", v="" },
    { t="H", v="MILK IN TANK" },
    { t="B", v="The second block follows the milk already" },
    { t="B", v="stored in the barn, split by the breeds" },
    { t="B", v="that produced it." },
    { t="B", v="The header gives the litres held." },
    { t="B", v="Milk with no breed record is listed as" },
    { t="B", v="unknown." },
    { t="B", v="A fresh herd standing beside older milk is" },
    { t="B", v="normal, not a fault." },
    { t="S", v=" " },
    { t="H", v="STORED FEED" },
    { t="B", v="The last lines describe the feed your farm" },
    { t="B", v="has in store." },
    { t="B", v="That is a whole farm reading, so every card" },
    { t="B", v="on the page repeats it." },
    { t="S", v=" " },
    { t="H", v="WHEN A VALUE IS NOT KNOWN" },
    { t="B", v="In place of a number a card may show a" },
    { t="B", v="short state such as waiting for the server," },
    { t="B", v="waiting for player farm, or no milk stored." },
    { t="B", v="Those are honest answers, not errors." },
}

DairyGuideDialog.PAGE3 = {
    { t="H", v="HERD HEALTH" },
    { t="B", v="Every barn carries a herd health score from" },
    { t="B", v="0 to 100, worked out once a game day." },
    { t="B", v="The base of it is how well the barn itself" },
    { t="B", v="is running: food, water, straw and the rest" },
    { t="B", v="of the barn's own production state." },
    { t="B", v="Feed trouble pulls the score down." },
    { t="S", v=" " },
    { t="H", v="SALE QUALITY" },
    { t="B", v="The score sets a grade for the milk:" },
    { t="B", v="Premium at 85 and above." },
    { t="B", v="Standard from 60 up." },
    { t="B", v="Reduced from 35 up." },
    { t="B", v="Poor below 35." },
    { t="B", v="The grade is a rating of the milk your barn" },
    { t="B", v="is turning out. It is shown to you, not" },
    { t="B", v="charged at the sell point." },
    { t="S", v=" " },
    { t="H", v="THE SPOILAGE CLOCK" },
    { t="B", v="Milk left standing in the barn ages." },
    { t="B", v="The clock starts the moment milk actually" },
    { t="COL", v="" },
    { t="B", v="leaves the barn. Any drop in the barn's" },
    { t="B", v="milk level counts as a collection." },
    { t="S", v=" " },
    { t="B", v="From that moment the stages run:" },
    { t="B", v="Fresh for the first day." },
    { t="B", v="Ageing through the second day." },
    { t="B", v="At Risk through the third day." },
    { t="B", v="Condemned after three days." },
    { t="S", v=" " },
    { t="H", v="WHAT AGEING COSTS" },
    { t="B", v="Ageing drops the shown grade one step." },
    { t="B", v="At Risk drops it two steps." },
    { t="B", v="Condemned counts as Poor whatever the herd" },
    { t="B", v="score is." },
    { t="B", v="Empty the tank regularly and the grade" },
    { t="B", v="stays where the herd earned it." },
    { t="S", v=" " },
    { t="H", v="CLOCK IDLE" },
    { t="B", v="A barn that has never had milk leave it" },
    { t="B", v="reads clock idle." },
    { t="B", v="That means the clock has not started yet." },
    { t="B", v="It does not mean the milk is fresh forever." },
}

DairyGuideDialog.PAGE4 = {
    { t="H", v="WHERE FEED QUALITY COMES FROM" },
    { t="B", v="When a crop is cut on your land the mod" },
    { t="B", v="notes two things about that field: whether" },
    { t="B", v="it was certified organic, and how much" },
    { t="B", v="disease pressure it carried at the cut." },
    { t="B", v="Those readings are blended into one farm" },
    { t="B", v="wide feed pool as more harvest comes in." },
    { t="B", v="The pool is the farm's, not the barn's." },
    { t="S", v=" " },
    { t="H", v="THE STORED FEED LINES" },
    { t="B", v="The first line says whether the stored feed" },
    { t="B", v="counts as organic, with the organic share." },
    { t="B", v="It counts as organic above an 80 percent" },
    { t="B", v="share." },
    { t="B", v="The second line reports contamination:" },
    { t="B", v="none, a trace, or a percentage." },
    { t="B", v="Contamination fades a little every day by" },
    { t="B", v="itself, and the line says how fast." },
    { t="COL", v="" },
    { t="H", v="SICK FEED, SICK HERD" },
    { t="B", v="Cattle eat from that pool, so contaminated" },
    { t="B", v="feed puts a penalty on the herd and the" },
    { t="B", v="herd health score falls." },
    { t="B", v="The penalty lifts as the days pass and the" },
    { t="B", v="pool cleans itself up." },
    { t="B", v="While a barn is affected, the help text on" },
    { t="B", v="the left names it." },
    { t="S", v=" " },
    { t="H", v="WHEN IT SAYS WAITING" },
    { t="B", v="Until a harvest has been recorded for your" },
    { t="B", v="farm the lines say they are waiting for" },
    { t="B", v="harvest data." },
    { t="B", v="In multiplayer a client is told the record" },
    { t="B", v="lives on the server." },
    { t="S", v=" " },
    { t="H", v="TWO RECORDS, NOT ONE" },
    { t="B", v="Herd now counts animals. Milk in tank" },
    { t="B", v="counts litres." },
    { t="B", v="Sell the herd and the tank still remembers" },
    { t="B", v="which breeds filled it." },
    { t="B", v="Cow milk and buffalo milk are kept apart," },
    { t="B", v="each with its own line." },
}

DairyGuideDialog.PAGE5 = {
    { t="H", v="WHERE THE SETTINGS LIVE" },
    { t="B", v="Dairy Core has no keys of its own. Nothing" },
    { t="B", v="to bind under Options and Controls." },
    { t="B", v="Its settings sit in the shared Realistic" },
    { t="B", v="Farming settings screen, under DairyCore." },
    { t="B", v="They are admin settings, so on a server" },
    { t="B", v="only the farm admin can change them." },
    { t="S", v=" " },
    { t="H", v="THE SETTINGS" },
    { t="B", v="Dairy Core Enabled turns the whole dairy" },
    { t="B", v="layer on or off." },
    { t="B", v="Default Collection Interval sets the hours" },
    { t="B", v="between scheduled collections for a new" },
    { t="B", v="barn. It runs from 4 to 72 hours and starts" },
    { t="B", v="at 24." },
    { t="B", v="Milk Spoilage turns the spoilage clock on" },
    { t="B", v="or off." },
    { t="B", v="Dairy Contracts turns the dairy contract" },
    { t="B", v="machinery on or off." },
    { t="COL", v="" },
    { t="B", v="Milk Sale Margin is the cut taken off the" },
    { t="B", v="spot price on an administrative milk sale." },
    { t="B", v="It runs from none up to a quarter and" },
    { t="B", v="starts at one twentieth." },
    { t="S", v=" " },
    { t="H", v="COMMON QUESTIONS" },
    { t="B", v="I see no Dairy entry in the list." },
    { t="B", v="Dairy Core stands down completely when" },
    { t="B", v="Precision Farming is installed. It also" },
    { t="B", v="needs at least one barn that makes milk." },
    { t="S", v=" " },
    { t="B", v="Why do all four cards say the same about" },
    { t="B", v="stored feed?" },
    { t="B", v="Because stored feed is a farm reading." },
    { t="S", v=" " },
    { t="B", v="Does breeding matter?" },
    { t="B", v="With Realistic Livestock installed the herd" },
    { t="B", v="score is worked out animal by animal, so a" },
    { t="B", v="better bred herd scores better. Without it" },
    { t="B", v="the barn's own output is used." },
    { t="S", v=" " },
    { t="B", v="Who does the work in multiplayer?" },
    { t="B", v="The server keeps the books. Your screen is" },
    { t="B", v="a mirror and says so while it waits." },
}

DairyGuideDialog.PAGE_CONTENT = { DairyGuideDialog.PAGE1, DairyGuideDialog.PAGE2, DairyGuideDialog.PAGE3, DairyGuideDialog.PAGE4, DairyGuideDialog.PAGE5 }

-- -- Constructor ------------------------------------------

function DairyGuideDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or DairyGuideDialog_mt)
    self._contentLineEls = {}
    self._currentPage = 1
    return self
end

--- Loads the dialog into g_gui once. Safe to call twice, and safe to call when some other path has
--- already registered the same name.
function DairyGuideDialog.register(modDirectory)
    if g_gui == nil then return end
    if g_gui.guis ~= nil and g_gui.guis[DairyGuideDialog.GUI_NAME] ~= nil then return end
    if modDirectory ~= nil then GUIDE_MOD_DIR = modDirectory end
    if GUIDE_MOD_DIR == nil then return end
    DairyGuideDialog.INSTANCE = DairyGuideDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(GUIDE_MOD_DIR .. "xml/gui/DairyGuideDialog.xml", DairyGuideDialog.GUI_NAME, DairyGuideDialog.INSTANCE)
    end)
    if not ok then
        print("[Dairy] DairyGuideDialog: loadGui failed: " .. tostring(err))
        DairyGuideDialog.INSTANCE = nil
    end
end

function DairyGuideDialog.show()
    if g_gui == nil then return end
    local loaded = g_gui.guis ~= nil and g_gui.guis[DairyGuideDialog.GUI_NAME] ~= nil
    if not loaded then
        DairyGuideDialog.register(GUIDE_MOD_DIR)
        loaded = g_gui.guis ~= nil and g_gui.guis[DairyGuideDialog.GUI_NAME] ~= nil
    end
    if not loaded then return end
    g_gui:showDialog(DairyGuideDialog.GUI_NAME)
end

-- -- Lifecycle --------------------------------------------

function DairyGuideDialog:onGuiSetupFinished()
    DairyGuideDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("dcGuide_col1")
    self._elCol2 = self:getDescendantById("dcGuide_col2")
    self._elSubtitle = self:getDescendantById("dcGuide_subtitle")
end

function DairyGuideDialog:onOpen()
    DairyGuideDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function DairyGuideDialog:onClose()
    DairyGuideDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- -- Tabs -------------------------------------------------

function DairyGuideDialog:onClickTab1() self:_selectPage(1) end
function DairyGuideDialog:onClickTab2() self:_selectPage(2) end
function DairyGuideDialog:onClickTab3() self:_selectPage(3) end
function DairyGuideDialog:onClickTab4() self:_selectPage(4) end
function DairyGuideDialog:onClickTab5() self:_selectPage(5) end

function DairyGuideDialog:_selectPage(pageNum)
    if self._currentPage == pageNum and #self._contentLineEls > 0 then return end
    self:_clearContent()
    self._currentPage = pageNum
    if self._elSubtitle ~= nil then
        self._elSubtitle:setText(DairyGuideDialog.SUBTITLES[pageNum] or "")
    end
    self:_buildContent(pageNum)
end

-- -- Content ----------------------------------------------

function DairyGuideDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("dcGuide_colHeader")
    local profileB = g_gui:getProfile("dcGuide_colBody")
    local profileS = g_gui:getProfile("dcGuide_colSpacer")
    if not profileH or not profileB then
        print("[Dairy] DairyGuideDialog: column profiles not found")
        return
    end
    local content = DairyGuideDialog.PAGE_CONTENT[pageNum]
    if content == nil then return end
    local currentBox = self._elCol1
    for _, row in ipairs(content) do
        if row.t == "COL" then
            if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox ~= nil then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB
            if profile ~= nil then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v or "")
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

function DairyGuideDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls or {}) do
        if entry.box ~= nil then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

-- -- Button -----------------------------------------------

function DairyGuideDialog:onClickClose()
    g_gui:closeDialogByName(DairyGuideDialog.GUI_NAME)
end
