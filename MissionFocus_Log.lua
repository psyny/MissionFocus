-- MissionFocus_Log.lua
-- The MissionFocus Center window, with three tabs:
--   Quest Log: every quest of the log (tracked or not) with when / where / from whom it was
--              accepted, sorting, filters (saved per profile), and quest actions.
--   Questlines: recent questlines and the player's step in each (MissionFocus_QuestlinesUI.lua).
--   Focus Modes: the focus mode editor (AceConfig table of MissionFocus_Modes.lua).
-- Filter controls are AceGUI widgets (the same library as the options window) instead of
-- Blizzard's dropdown menus, which were rewritten in 11.0 and tend to change.
MissionFocus_Log = {}

local LOG = MissionFocus_Log
local Q = MissionFocus_Quests
local Call = MissionFocus_Utils.Call
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
local AceGUI = LibStub("AceGUI-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

local WIDTH, HEIGHT = 620, 620
local PADDING = 10
local FILTER_HEIGHT = 160   -- view row + filters section + actions row
local FILTERS_HEADER_Y = 52 -- "Filters" label, below the search / sort row
local ROW_GAP = 4
local ROW_PADDING = 6
local BUTTON_HEIGHT = 18

LOG.frame = nil
LOG.expanded = {}      -- questID -> true when the details are open
LOG.highlightID = nil  -- quest to scroll to on the next layout
LOG.TABS = { "log", "questlines", "tales", "modes" }
LOG.activeTab = "log"

local rows = {}
local widgets = {}

---------------------------------------------------------
-- Filters (db.profile.log_filters)

LOG.SORTS = { "category", "newest", "oldest", "proximity", "name" }
LOG.NEAR = { "any", "zone", "continent", "world" }
LOG.TRACKING = { "all", "tracked", "untracked" }

local function Filters()
    return MissionFocus_Options.db.log_filters
end

function LOG:ClearFilters()
    local filters = Filters()
    filters.search = ""
    filters.sort = "category"
    filters.near = "any"
    filters.zone = 0
    filters.tracking = "all"
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        filters.categories[key] = true
    end
    self:SyncWidgets()
    self:Refresh()
end

---------------------------------------------------------
-- Map helpers

local function MapName(mapID)
    local info = mapID and Call("C_Map.GetMapInfo", mapID)
    return info and info.name
end

-- All known locations of a quest (where it is now, world quest zone, where it was accepted).
local function QuestMaps(questID)
    local maps = {}
    local function Add(mapID)
        if mapID and mapID ~= 0 then
            maps[#maps + 1] = mapID
        end
    end
    Add(Call("GetQuestUiMapID", questID, true))
    Add(Call("C_TaskQuest.GetQuestZoneID", questID))
    Add(MissionFocus_History:GetOriginMap(questID))
    return maps
end

-- Ancestors of a map, the map itself first.
local function Chain(mapID)
    local chain = {}
    local id = mapID
    for _ = 1, 20 do
        if not id or id == 0 then
            break
        end
        chain[#chain + 1] = id
        local info = Call("C_Map.GetMapInfo", id)
        id = info and info.parentMapID
    end
    return chain
end

-- Proximity: how far up the player's map chain the quest's map joins it (0 = same map),
-- then straight-line distance. Quests with no location come last.
local function ProximityKey(questID, playerChainIndex)
    local mapID = Call("GetQuestUiMapID", questID, true) or MissionFocus_History:GetOriginMap(questID)
    local level = 99
    if mapID and mapID ~= 0 then
        for _, ancestor in ipairs(Chain(mapID)) do
            local index = playerChainIndex[ancestor]
            if index then
                level = index
                break
            end
        end
    end
    local distanceSq = Call("C_QuestLog.GetDistanceSqToQuest", questID)
    return level, distanceSq or math.huge
end

---------------------------------------------------------
-- Building the list

-- Every quest of the log (plus tracked world quests), with what the log shows.
function LOG:CollectEntries()
    local LOC = MissionFocus_Location
    local filters = Filters()
    local search = strtrim(string.lower(filters.search or ""))
    local nearLevel = filters.near ~= "any" and filters.near or nil
    local playerRegion = nearLevel and LOC:GetPlayerRegion(nearLevel)

    local playerChainIndex = {}
    for i, id in ipairs(Chain(LOC:GetPlayerMap())) do
        playerChainIndex[id] = i - 1
    end

    local all, visible, zones = {}, {}, {}
    for _, entry in ipairs(Q:GetQuests()) do
        local maps = QuestMaps(entry.questID)
        local zoneIDs = {}
        for _, mapID in ipairs(maps) do
            local zoneID = LOC:GetRegion(mapID, "zone")
            if zoneID then
                zoneIDs[zoneID] = true
                zones[zoneID] = MapName(zoneID)
            end
        end

        local item = {
            entry = entry,
            history = MissionFocus_History:Get(entry.questID),
            zoneIDs = zoneIDs,
        }
        item.proximityLevel, item.distanceSq = ProximityKey(entry.questID, playerChainIndex)
        all[#all + 1] = item

        local keep = true
        if search ~= "" and not string.find(string.lower(entry.title or ""), search, 1, true) then
            keep = false
        end
        if keep and not filters.categories[entry.category] then
            keep = false
        end
        if keep and filters.tracking == "tracked" and not entry.isTracked then
            keep = false
        elseif keep and filters.tracking == "untracked" and entry.isTracked then
            keep = false
        end
        if keep and filters.zone and filters.zone ~= 0 and not zoneIDs[filters.zone] then
            keep = false
        end
        if keep and nearLevel and playerRegion and #maps > 0 then
            local near = false
            for _, mapID in ipairs(maps) do
                if LOC:GetRegion(mapID, nearLevel) == playerRegion then
                    near = true
                end
            end
            keep = near -- quests with no known location are kept
        end
        if keep then
            visible[#visible + 1] = item
        end
    end

    self:Sort(visible)
    return visible, all, zones
end

function LOG:Sort(items)
    local sort = Filters().sort
    local rank = {}
    for i, key in ipairs(Q:GetCategoryOrder()) do
        rank[key] = i
    end
    local function Time(item)
        return item.history and item.history.time or 0
    end
    table.sort(items, function(a, b)
        local ea, eb = a.entry, b.entry
        if sort == "newest" and Time(a) ~= Time(b) then
            return Time(a) > Time(b)
        elseif sort == "oldest" and Time(a) ~= Time(b) then
            return Time(a) < Time(b)
        elseif sort == "proximity" then
            if a.proximityLevel ~= b.proximityLevel then
                return a.proximityLevel < b.proximityLevel
            end
            if a.distanceSq ~= b.distanceSq then
                return a.distanceSq < b.distanceSq
            end
        elseif sort == "name" and ea.title ~= eb.title then
            return (ea.title or "") < (eb.title or "")
        end
        -- Default and tie-breaker: category priority, tracked first, quest log order.
        local ra, rb = rank[ea.category] or 99, rank[eb.category] or 99
        if ra ~= rb then
            return ra < rb
        end
        if ea.isTracked ~= eb.isTracked then
            return ea.isTracked
        end
        return ea.watchIndex < eb.watchIndex
    end)
end

---------------------------------------------------------
-- Quest text and rewards (for expanded rows)

-- Some quest log functions read the "selected" quest: select it briefly, then restore.
local function WithSelectedQuest(questID, fn)
    local previous = Call("C_QuestLog.GetSelectedQuest")
    Call("C_QuestLog.SetSelectedQuest", questID)
    local ok, result = pcall(fn)
    if previous and previous ~= 0 then
        Call("C_QuestLog.SetSelectedQuest", previous)
    end
    return ok and result or nil
end

local function Icon(texture)
    return texture and string.format("|T%s:14:14:0:0|t ", tostring(texture)) or ""
end

local function MoneyText(money)
    if MissionFocus_Utils.HasAPI("GetMoneyString") then
        return Call("GetMoneyString", money, true)
    end
    return string.format("%dg %ds %dc", math.floor(money / 10000), math.floor(money / 100) % 100, money % 100)
end

function LOG:GetDetailsText(entry)
    return WithSelectedQuest(entry.questID, function()
        local lines = {}
        local description, objectivesText = Call("GetQuestLogQuestText", entry.logIndex)
        if objectivesText and objectivesText ~= "" then
            lines[#lines + 1] = "|cffffd100" .. L["MissionFocus.log.objectives"] .. "|r"
            lines[#lines + 1] = objectivesText
            lines[#lines + 1] = " "
        end
        if description and description ~= "" then
            lines[#lines + 1] = "|cffffd100" .. L["MissionFocus.log.description"] .. "|r"
            lines[#lines + 1] = description
            lines[#lines + 1] = " "
        end

        local rewards = {}
        local xp = Call("GetQuestLogRewardXP", entry.questID)
        if xp and xp > 0 then
            rewards[#rewards + 1] = string.format(L["MissionFocus.log.reward_xp"], BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or xp)
        end
        local money = Call("GetQuestLogRewardMoney", entry.questID)
        if money and money > 0 then
            rewards[#rewards + 1] = MoneyText(money)
        end
        for i = 1, (Call("GetNumQuestLogRewards", entry.questID) or 0) do
            local name, texture, count = Call("GetQuestLogRewardInfo", i, entry.questID)
            if name then
                rewards[#rewards + 1] = Icon(texture) .. name .. ((count and count > 1) and (" x" .. count) or "")
            end
        end
        local currencies = Call("C_QuestLog.GetQuestRewardCurrencies", entry.questID)
        if type(currencies) == "table" then
            for _, currency in ipairs(currencies) do
                local amount = currency.totalRewardAmount or currency.baseRewardAmount
                rewards[#rewards + 1] = Icon(currency.texture) .. (currency.name or "?") .. (amount and (" x" .. amount) or "")
            end
        end
        local choices = {}
        for i = 1, (Call("GetNumQuestLogChoices", entry.questID, true) or 0) do
            local name, texture, count = Call("GetQuestLogChoiceInfo", i)
            if name then
                choices[#choices + 1] = Icon(texture) .. name .. ((count and count > 1) and (" x" .. count) or "")
            end
        end

        if #rewards > 0 then
            lines[#lines + 1] = "|cffffd100" .. L["MissionFocus.log.rewards"] .. "|r"
            for _, reward in ipairs(rewards) do
                lines[#lines + 1] = reward
            end
        end
        if #choices > 0 then
            lines[#lines + 1] = "|cffffd100" .. L["MissionFocus.log.choices"] .. "|r"
            for _, choice in ipairs(choices) do
                lines[#lines + 1] = choice
            end
        end
        if #lines == 0 then
            lines[1] = L["MissionFocus.log.no_details"]
        end
        return table.concat(lines, "\n")
    end) or L["MissionFocus.log.no_details"]
end

---------------------------------------------------------
-- Row texts

local function ObjectivesText(entry)
    local details = Q:GetQuestDetails(entry.questID, entry.category)
    local db = MissionFocus_Options.db
    local lines = {}
    for _, objective in ipairs(details.objectives) do
        local text = "- " .. objective.text
        if objective.progress then
            text = string.format("%s (%d%%)", text, math.floor(objective.progress))
        end
        local color = objective.finished and db.objective_complete_color or db.objective_color
        if objective.failed then
            color = { r = 1, g = 0.25, b = 0.25 }
        end
        lines[#lines + 1] = "|c" .. MissionFocus_Utils.ColorToHex(color) .. text .. "|r"
    end
    return table.concat(lines, "\n")
end

local function AcceptedText(history)
    if not history or not history.time then
        return L["MissionFocus.log.accepted_unknown"]
    end
    local parts = {}
    local stamp = date("%Y-%m-%d %H:%M", history.time)
    parts[1] = string.format(history.seenOnly and L["MissionFocus.log.first_seen"] or L["MissionFocus.log.accepted"], stamp)

    if history.mapID then
        local LOC = MissionFocus_Location
        local names, seen = {}, {}
        for _, mapID in ipairs({ history.mapID, LOC:GetRegion(history.mapID, "zone"), LOC:GetRegion(history.mapID, "continent") }) do
            local name = MapName(mapID)
            if name and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        local place = table.concat(names, " - ")
        if history.x and history.y then
            place = string.format("%s (%.1f, %.1f)", place, history.x * 100, history.y * 100)
        end
        parts[#parts + 1] = place
    end
    if history.giver and history.giver ~= "" then
        parts[#parts + 1] = string.format(L["MissionFocus.log.from"], history.giver)
    end
    return table.concat(parts, " · ")
end

---------------------------------------------------------
-- Actions

StaticPopupDialogs["MISSIONFOCUS_ABANDON_QUEST"] = {
    text = L["MissionFocus.log.abandon_confirm"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, questID)
        Call("C_QuestLog.SetSelectedQuest", questID)
        Call("C_QuestLog.SetAbandonQuest")
        Call("C_QuestLog.AbandonQuest")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
}

local function Abandon(entry)
    StaticPopup_Show("MISSIONFOCUS_ABANDON_QUEST", entry.title, nil, entry.questID)
end

-- Track exactly what is shown: tracks the shown quests and untracks every other one.
function LOG:TrackOnlyVisible()
    local shown = {}
    for _, item in ipairs(self.visibleItems or {}) do
        shown[item.entry.questID] = true
        if not item.entry.isTracked then
            Q:Track(item.entry)
        end
    end
    for _, item in ipairs(self.allItems or {}) do
        if item.entry.isTracked and not shown[item.entry.questID] then
            Q:Untrack(item.entry)
        end
    end
    MissionFocus:RequestRefresh()
end

-- Untracks the shown quests (onlyVisible) or every tracked quest.
function LOG:UntrackQuests(onlyVisible)
    for _, item in ipairs((onlyVisible and self.visibleItems or self.allItems) or {}) do
        if item.entry.isTracked then
            Q:Untrack(item.entry)
        end
    end
    MissionFocus:RequestRefresh()
end

---------------------------------------------------------
-- Frame

local function CreateButton(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, BUTTON_HEIGHT)
    button:SetText(text)
    button:SetNormalFontObject("GameFontNormalSmall")
    button:SetHighlightFontObject("GameFontHighlightSmall")
    button:SetScript("OnClick", onClick)
    return button
end

LOG.CreateButton = CreateButton -- also used by the Questlines tab

-- Each tab's first page starts with one paragraph saying what the tab is for.
LOG.INTRO_HEIGHT = 46

-- The intro paragraph, at the top of `parent` (or above `below`'s top edge when given).
function LOG.CreateIntro(parent, text, below)
    local intro = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if below then
        intro:SetPoint("BOTTOMLEFT", below, "TOPLEFT", 0, 8)
        intro:SetPoint("BOTTOMRIGHT", below, "TOPRIGHT", 0, 8)
    else
        intro:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        intro:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    end
    intro:SetHeight(LOG.INTRO_HEIGHT - 8)
    intro:SetJustifyH("LEFT")
    intro:SetJustifyV("TOP")
    intro:SetWordWrap(true)
    intro:SetTextColor(0.85, 0.85, 0.85, 1)
    intro:SetText(text)
    return intro
end

local function OrderedList(keys, prefix)
    local list = {}
    for _, key in ipairs(keys) do
        list[key] = L[prefix .. key]
    end
    return list
end

local function PlaceWidget(widget, parent, x, y, width)
    widget.frame:SetParent(parent)
    widget.frame:ClearAllPoints()
    widget.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    widget:SetWidth(width)
    widget.frame:Show()
end

local function SetTooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        MissionFocus_Utils.Tooltip():SetOwner(self, "ANCHOR_TOP")
        MissionFocus_Utils.Tooltip():SetText(text, 1, 1, 1, 1, true)
        MissionFocus_Utils.Tooltip():Show()
    end)
    frame:SetScript("OnLeave", function() MissionFocus_Utils.Tooltip():Hide() end)
end

-- Top: view parameters (search, sort). Then a "Filters" section, then actions.
function LOG:CreateFilters(parent)
    local full = WIDTH - PADDING * 2
    local gap = 8
    local half = (full - gap) / 2
    local quarter = (full - gap * 3) / 4

    local search = AceGUI:Create("EditBox")
    search:SetLabel(L["MissionFocus.log.search"])
    search:DisableButton(true)
    search:SetCallback("OnTextChanged", function(_, _, text)
        Filters().search = text or ""
        LOG:Refresh()
    end)
    PlaceWidget(search, parent, 0, 0, half)
    widgets.search = search

    local sort = AceGUI:Create("Dropdown")
    sort:SetLabel(L["MissionFocus.log.sort"])
    sort:SetList(OrderedList(LOG.SORTS, "MissionFocus.log.sort_"), LOG.SORTS)
    sort:SetCallback("OnValueChanged", function(_, _, key)
        Filters().sort = key
        LOG:Refresh()
    end)
    PlaceWidget(sort, parent, half + gap, 0, half)
    widgets.sort = sort

    -- "Filters" section label with a divider line
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -FILTERS_HEADER_Y)
    header:SetText(L["MissionFocus.log.filters"])
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.35)
    line:SetHeight(1)
    line:SetPoint("LEFT", header, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local y = -(FILTERS_HEADER_Y + 14)

    local near = AceGUI:Create("Dropdown")
    near:SetLabel(L["MissionFocus.log.near"])
    near:SetCallback("OnValueChanged", function(_, _, key)
        Filters().near = key
        LOG:Refresh()
    end)
    PlaceWidget(near, parent, 0, y, quarter)
    widgets.near = near

    local zone = AceGUI:Create("Dropdown")
    zone:SetLabel(L["MissionFocus.log.zone"])
    zone:SetCallback("OnValueChanged", function(_, _, key)
        Filters().zone = key
        LOG:Refresh()
    end)
    PlaceWidget(zone, parent, quarter + gap, y, quarter)
    widgets.zone = zone

    local categories = AceGUI:Create("Dropdown")
    categories:SetLabel(L["MissionFocus.log.categories"])
    categories:SetMultiselect(true)
    categories:SetList(OrderedList(MissionFocus_Options.CATEGORIES, "MissionFocus.category."), MissionFocus_Options.CATEGORIES)
    categories:SetCallback("OnValueChanged", function(_, _, key, checked)
        Filters().categories[key] = checked and true or false
        LOG:Refresh()
    end)
    PlaceWidget(categories, parent, (quarter + gap) * 2, y, quarter)
    widgets.categories = categories

    local tracking = AceGUI:Create("Dropdown")
    tracking:SetLabel(L["MissionFocus.log.tracking"])
    tracking:SetList(OrderedList(LOG.TRACKING, "MissionFocus.log.tracking_"), LOG.TRACKING)
    tracking:SetCallback("OnValueChanged", function(_, _, key)
        Filters().tracking = key
        LOG:Refresh()
    end)
    PlaceWidget(tracking, parent, (quarter + gap) * 3, y, quarter)
    widgets.tracking = tracking

    -- Actions
    y = y - 52
    local trackOnly = CreateButton(parent, L["MissionFocus.log.track_visible"], 110, function() LOG:TrackOnlyVisible() end)
    trackOnly:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    SetTooltip(trackOnly, L["MissionFocus.log.track_visible_tip"])
    local untrackShown = CreateButton(parent, L["MissionFocus.log.untrack_visible"], 110, function() LOG:UntrackQuests(true) end)
    untrackShown:SetPoint("LEFT", trackOnly, "RIGHT", 6, 0)
    SetTooltip(untrackShown, L["MissionFocus.log.untrack_visible_tip"])
    local untrackAll = CreateButton(parent, L["MissionFocus.log.untrack_all"], 80, function() LOG:UntrackQuests(false) end)
    untrackAll:SetPoint("LEFT", untrackShown, "RIGHT", 6, 0)
    SetTooltip(untrackAll, L["MissionFocus.log.untrack_all_tip"])
    local clear = CreateButton(parent, L["MissionFocus.log.clear_filters"], 90, function() LOG:ClearFilters() end)
    clear:SetPoint("LEFT", untrackAll, "RIGHT", 6, 0)
    SetTooltip(clear, L["MissionFocus.log.clear_filters_tip"])

    local count = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    count:SetPoint("TOP", trackOnly, "TOP", 0, -3)
    count:SetJustifyH("RIGHT")
    self.countText = count
end

-- Replacing a dropdown's list closes it if it is open: only do it when the list changed.
local function SetListIfChanged(dropdown, list, order)
    local parts = {}
    for _, key in ipairs(order) do
        parts[#parts + 1] = tostring(key) .. "=" .. tostring(list[key])
    end
    local signature = table.concat(parts, "|")
    if dropdown.mfSignature ~= signature then
        dropdown.mfSignature = signature
        dropdown:SetList(list, order)
    end
end

-- Puts the saved filter values into the widgets (also refreshes the dynamic lists).
function LOG:SyncWidgets(zones)
    if not widgets.search then
        return
    end
    local filters = Filters()
    -- Only write the search text when it differs: rewriting it while typing moves the cursor.
    if (widgets.search:GetText() or "") ~= (filters.search or "") then
        widgets.search:SetText(filters.search or "")
    end
    widgets.sort:SetValue(filters.sort)

    local LOC = MissionFocus_Location
    local nearList = {}
    for _, level in ipairs(LOG.NEAR) do
        local label = L["MissionFocus.log.near_" .. level]
        if level ~= "any" then
            local name = MapName(LOC:GetPlayerRegion(level))
            if name then
                label = label .. ": " .. name
            end
        end
        nearList[level] = label
    end
    SetListIfChanged(widgets.near, nearList, LOG.NEAR)
    widgets.near:SetValue(filters.near)

    local zoneList, zoneOrder = { [0] = L["MissionFocus.log.zone_all"] }, { 0 }
    local sortedZones = {}
    for zoneID, name in pairs(zones or self.lastZones or {}) do
        sortedZones[#sortedZones + 1] = { id = zoneID, name = name or tostring(zoneID) }
    end
    if filters.zone and filters.zone ~= 0 and not zoneList[filters.zone] then
        local present = false
        for _, z in ipairs(sortedZones) do
            if z.id == filters.zone then
                present = true
            end
        end
        if not present then
            sortedZones[#sortedZones + 1] = { id = filters.zone, name = MapName(filters.zone) or tostring(filters.zone) }
        end
    end
    table.sort(sortedZones, function(a, b) return a.name < b.name end)
    for _, z in ipairs(sortedZones) do
        zoneList[z.id] = z.name
        zoneOrder[#zoneOrder + 1] = z.id
    end
    SetListIfChanged(widgets.zone, zoneList, zoneOrder)
    widgets.zone:SetValue(filters.zone or 0)

    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        widgets.categories:SetItemValue(key, filters.categories[key] and true or false)
    end
    widgets.tracking:SetValue(filters.tracking)
end

function LOG:Create()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "MissionFocusLogFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false)
        local point, _, relativePoint, x, y = self:GetPoint()
        MissionFocus_Options.db.log_point = { point = point, relativePoint = relativePoint, x = x, y = y }
    end)
    MissionFocus_Background:Create(frame) -- same styles as the panel, fixed border sizes
    frame:Hide()
    tinsert(UISpecialFrames, "MissionFocusLogFrame") -- closes with Escape

    local saved = MissionFocus_Options.db.log_point
    if saved then
        frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        frame:SetPoint("CENTER")
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", PADDING + 2, -PADDING)
    frame.title:SetText(L["MissionFocus.center.title"])

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    -- Same vertical center as the title, inside the frame edge.
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

    -- Tabs, right of the title.
    frame.tabs = {}
    local previous
    local tabWidth = 90
    for _, key in ipairs(LOG.TABS) do
        local tab = CreateButton(frame, L["MissionFocus.center.tab_" .. key], tabWidth, function()
            LOG:SelectTab(key)
        end)
        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            tab:SetPoint("RIGHT", close, "LEFT", -(4 + (tabWidth + 4) * (#LOG.TABS - 1)), 0)
        end
        frame.tabs[key] = tab
        previous = tab
    end

    -- Quest Log tab
    local logPage = CreateFrame("Frame", nil, frame)
    logPage:SetAllPoints(frame)
    frame.logPage = logPage

    local filterArea = CreateFrame("Frame", nil, logPage)
    filterArea:SetPoint("TOPLEFT", PADDING, -(36 + LOG.INTRO_HEIGHT))
    filterArea:SetPoint("TOPRIGHT", -PADDING, -(36 + LOG.INTRO_HEIGHT))
    filterArea:SetHeight(FILTER_HEIGHT - 20)
    self:CreateFilters(filterArea)
    LOG.CreateIntro(logPage, L["MissionFocus.center.intro_log"], filterArea)

    local scroll = CreateFrame("ScrollFrame", nil, logPage, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PADDING, -(36 + LOG.INTRO_HEIGHT + FILTER_HEIGHT - 10))
    scroll:SetPoint("BOTTOMRIGHT", -PADDING - 22, PADDING)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - PADDING * 2 - 26, 10)
    scroll:SetScrollChild(content)
    frame.scroll = scroll
    frame.content = content

    frame:SetScript("OnShow", function()
        MissionFocus_History:Sync()
        LOG:SelectTab(LOG.activeTab)
    end)

    self.frame = frame
    self:CreateModesPage(frame)
    MissionFocus_QuestlinesUI:CreatePage(frame, PADDING, 36)
    frame.questlinesPage = MissionFocus_QuestlinesUI.page
    MissionFocus_TalesUI:CreatePage(frame, PADDING, 36)
    frame.talesPage = MissionFocus_TalesUI.page
end

---------------------------------------------------------
-- Focus Modes tab. Left: our own mode list (square = activate, row = edit). Right: the selected
-- mode's group of the MissionFocus_Modes AceConfig table, fed into an AceGUI container inside a
-- scroll frame. AceConfigDialog does not refresh custom containers on NotifyChange, so we
-- re-open it.

local MODE_LIST_WIDTH = 170
local MODE_ROW_HEIGHT = 22
local MODE_SQUARE_SIZE = 14

local function GetModeRow(page, index)
    local row = page.rows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, page.list, "BackdropTemplate")
    row:SetSize(MODE_LIST_WIDTH, MODE_ROW_HEIGHT)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
    row:SetScript("OnClick", function()
        LOG.selectedModeID = row.modeID
        LOG:RefreshModes(true)
    end)

    local square = CreateFrame("Button", nil, row, "BackdropTemplate")
    square:SetSize(MODE_SQUARE_SIZE, MODE_SQUARE_SIZE)
    square:SetPoint("LEFT", 5, 0)
    square:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    square:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    square:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    square:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.25)
    square:SetScript("OnClick", function()
        MissionFocus:SetFocusMode(row.modeID)
    end)
    SetTooltip(square, L["MissionFocus.modes.activate_tip"])
    row.square = square

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.text:SetPoint("LEFT", square, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", -4, 0)

    page.rows[index] = row
    return row
end

function LOG:CreateModesPage(frame)
    local page = CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", PADDING, -36)
    page:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
    page:Hide()
    page.rows = {}
    frame.modesPage = page

    LOG.CreateIntro(page, L["MissionFocus.center.intro_modes"])

    local list = CreateFrame("Frame", nil, page)
    list:SetPoint("TOPLEFT", 0, -LOG.INTRO_HEIGHT)
    list:SetPoint("BOTTOMLEFT")
    list:SetWidth(MODE_LIST_WIDTH)
    page.list = list

    page.addButton = CreateButton(list, L["MissionFocus.modes.add"], MODE_LIST_WIDTH, function()
        LOG.selectedModeID = MissionFocus_Modes:Add().id
        MissionFocus_Modes:BuildOptions() -- notifies: the page refreshes
    end)

    page.help = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.help:SetJustifyH("LEFT")
    page.help:SetWidth(MODE_LIST_WIDTH)
    page.help:SetText(L["MissionFocus.modes.help"])

    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
    scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    page.scroll = scroll

    -- Auto height (SimpleGroup's default): it grows with the settings, the scroll frame follows.
    local group = AceGUI:Create("SimpleGroup")
    group.frame:SetParent(scroll)
    group.frame:SetFrameStrata(frame:GetFrameStrata())
    group.frame:SetFrameLevel(page:GetFrameLevel() + 1)
    group:SetWidth(WIDTH - PADDING * 2 - MODE_LIST_WIDTH - 10 - 22)
    scroll:SetScrollChild(group.frame)
    group.frame:Show()
    self.modesGroup = group

    -- Coalesced: an edit can notify several times, and the widget being clicked must not be
    -- released while its own callback runs.
    LibStub("AceConfigRegistry-3.0").RegisterCallback(LOG, "ConfigTableChange", function(_, appName)
        if appName ~= MissionFocus_Modes.APP_NAME or LOG.modesRefreshPending then
            return
        end
        LOG.modesRefreshPending = true
        C_Timer.After(0, function()
            LOG.modesRefreshPending = false
            LOG:RefreshModes()
        end)
    end)
end

-- resetScroll: a different mode was selected.
function LOG:RefreshModes(resetScroll)
    if not self.frame or not self.frame:IsShown() or self.activeTab ~= "modes" then
        return
    end
    local Modes = MissionFocus_Modes
    if not self.selectedModeID or not Modes:GetByID(self.selectedModeID) then
        self.selectedModeID = Modes:GetActive().id
    end

    local page = self.frame.modesPage
    local modes = MissionFocus_Options.db.focus_modes
    local y = 0
    for i, mode in ipairs(modes) do
        local row = GetModeRow(page, i)
        row.modeID = mode.id
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", page.list, "TOPLEFT", 0, -y)
        row.text:SetText(mode.name)
        if mode.id == self.selectedModeID then
            row:SetBackdropColor(1, 0.82, 0, 0.18)
        else
            row:SetBackdropColor(1, 1, 1, 0.03)
        end
        if Modes:IsActive(mode.id) then
            row.square:SetBackdropColor(0.3, 0.9, 0.3, 1)
        else
            row.square:SetBackdropColor(0, 0, 0, 0.6)
        end
        row:Show()
        y = y + MODE_ROW_HEIGHT + 2
    end
    for i = #modes + 1, #page.rows do
        page.rows[i]:Hide()
    end
    page.addButton:ClearAllPoints()
    page.addButton:SetPoint("TOPLEFT", page.list, "TOPLEFT", 0, -(y + 6))
    page.help:ClearAllPoints()
    page.help:SetPoint("TOPLEFT", page.addButton, "BOTTOMLEFT", 0, -10)

    AceConfigDialog:Open(Modes.APP_NAME, self.modesGroup, "mode_" .. self.selectedModeID)
    if resetScroll then
        page.scroll:SetVerticalScroll(0)
    end
end

function LOG:SelectTab(key)
    self.activeTab = key
    local frame = self.frame
    frame.logPage:SetShown(key == "log")
    frame.modesPage:SetShown(key == "modes")
    frame.questlinesPage:SetShown(key == "questlines")
    frame.talesPage:SetShown(key == "tales")
    for tabKey, tab in pairs(frame.tabs) do
        if tabKey == key then
            tab:LockHighlight()
        else
            tab:UnlockHighlight()
        end
    end
    MissionFocus_Background:ApplyWindow(frame, { width = WIDTH, height = HEIGHT })
    if key == "log" then
        self:Refresh()
    elseif key == "modes" then
        self:RefreshModes()
    elseif key == "tales" then
        MissionFocus_TalesUI:OnShow()
    else
        MissionFocus_QuestlinesUI:OnShow()
    end
end

---------------------------------------------------------
-- Rows

local HOVER_BUTTON_WIDTH = 64
local HOVER_BUTTON_HEIGHT = 16
local HOVER_BUTTON_GAP = 2
local BUTTON_COLUMN = HOVER_BUTTON_WIDTH + 8
-- Tall enough for the right-side stack: 3 hover buttons + Details.
local ROW_MIN_HEIGHT = ROW_PADDING * 2 + HOVER_BUTTON_HEIGHT * 4 + HOVER_BUTTON_GAP * 3

local function CreateSmallButton(parent, text, onClick)
    local button = CreateButton(parent, text, HOVER_BUTTON_WIDTH, onClick)
    button:SetHeight(HOVER_BUTTON_HEIGHT)
    return button
end

-- Track / Abandon / Quest Log / Details only show while the mouse is over the card; the category label
-- is hidden meanwhile (the buttons stack over its spot).
local function SetHover(row, hovered)
    row.trackButton:SetShown(hovered)
    row.abandonButton:SetShown(hovered and row.canAbandon)
    row.blizzardButton:SetShown(hovered)
    row.expandButton:SetShown(hovered)
    row.category:SetShown(not hovered)
end

local function CheckHover(row)
    SetHover(row, row:IsMouseOver())
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    local content = LOG.frame.content
    row = CreateFrame("Button", nil, content, "BackdropTemplate")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(1, 1, 1, 0.03)
    row:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.04)

    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.stripe:SetWidth(3)
    row.stripe:SetPoint("TOPLEFT")
    row.stripe:SetPoint("BOTTOMLEFT")

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(true)

    row.category = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.category:SetJustifyH("RIGHT")
    row.category:SetPoint("TOPRIGHT", -ROW_PADDING, -ROW_PADDING)

    row.objectives = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.objectives:SetJustifyH("LEFT")
    row.objectives:SetWordWrap(true)

    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(true)

    row.details = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.details:SetJustifyH("LEFT")
    row.details:SetWordWrap(true)

    -- Right-side stack, bottom-up: Details, Quest Log, Abandon, Track (all on hover only).
    row.expandButton = CreateSmallButton(row, "", function()
        local questID = row.item.entry.questID
        LOG.expanded[questID] = not LOG.expanded[questID] or nil
        LOG:Layout()
    end)
    row.expandButton:SetPoint("BOTTOMRIGHT", -ROW_PADDING, ROW_PADDING)
    row.blizzardButton = CreateSmallButton(row, L["MissionFocus.log.open_blizzard"], function()
        Q:OpenInQuestLog(row.item.entry.questID)
    end)
    row.blizzardButton:SetPoint("BOTTOM", row.expandButton, "TOP", 0, HOVER_BUTTON_GAP)
    row.abandonButton = CreateSmallButton(row, L["MissionFocus.log.abandon"], function()
        Abandon(row.item.entry)
    end)
    row.abandonButton:SetPoint("BOTTOM", row.blizzardButton, "TOP", 0, HOVER_BUTTON_GAP)
    row.trackButton = CreateSmallButton(row, "", function()
        Q:ToggleTracking(row.item.entry)
        MissionFocus:RequestRefresh()
    end)
    row.trackButton:SetPoint("BOTTOM", row.abandonButton, "TOP", 0, HOVER_BUTTON_GAP)

    -- Moving from the card onto one of its buttons fires the card's OnLeave: check the mouse
    -- position instead of trusting enter/leave pairs.
    row:SetScript("OnEnter", CheckHover)
    row:SetScript("OnLeave", CheckHover)
    for _, button in ipairs({ row.trackButton, row.abandonButton, row.blizzardButton, row.expandButton }) do
        button:HookScript("OnLeave", function() CheckHover(row) end)
    end
    SetHover(row, false)

    -- Right-click: add the quest to a tale (Adventurer's Tales).
    row:SetScript("OnClick", function(_, button)
        local questID = row.item.entry.questID
        if button == "RightButton" then
            MissionFocus_TalesUI:ShowAddMenu(row, function()
                return { type = "quest", questID = questID }
            end)
            return
        end
        MissionFocus:PickFocus(questID)
    end)

    rows[index] = row
    return row
end

-- Lays out one row; returns its height.
local function FillRow(row, item, width, focusID)
    local entry = item.entry
    local color = Q.CATEGORY_COLORS[entry.category] or { r = 1, g = 0.82, b = 0 }
    -- Text keeps clear of the right-side button column, so nothing moves when it appears.
    local textWidth = width - ROW_PADDING * 2 - 6 - BUTTON_COLUMN

    row.item = item
    row.canAbandon = entry.logIndex ~= nil
    row.stripe:SetVertexColor(color.r, color.g, color.b, entry.isTracked and 1 or 0.5)
    if entry.questID == focusID then
        row:SetBackdropColor(color.r, color.g, color.b, 0.15)
    else
        row:SetBackdropColor(1, 1, 1, 0.03)
    end

    local categoryName = L["MissionFocus.category." .. entry.category] or entry.category
    if not entry.isTracked then
        categoryName = categoryName .. " · " .. L["MissionFocus.ui.untracked"]
    end
    row.category:SetText(categoryName)

    local y = -ROW_PADDING
    row.title:ClearAllPoints()
    row.title:SetPoint("TOPLEFT", ROW_PADDING + 6, y)
    row.title:SetWidth(textWidth)
    row.title:SetText(entry.title)
    y = y - row.title:GetStringHeight() - 3

    row.objectives:ClearAllPoints()
    row.objectives:SetPoint("TOPLEFT", ROW_PADDING + 14, y)
    row.objectives:SetWidth(textWidth - 8)
    row.objectives:SetText(ObjectivesText(entry))
    if row.objectives:GetText() and row.objectives:GetText() ~= "" then
        y = y - row.objectives:GetStringHeight() - 3
    end

    row.meta:ClearAllPoints()
    row.meta:SetPoint("TOPLEFT", ROW_PADDING + 6, y)
    row.meta:SetWidth(textWidth)
    row.meta:SetText(AcceptedText(item.history))
    y = y - row.meta:GetStringHeight() - 4

    local expanded = LOG.expanded[entry.questID]
    if expanded then
        row.details:ClearAllPoints()
        row.details:SetPoint("TOPLEFT", ROW_PADDING + 6, y)
        row.details:SetWidth(textWidth)
        row.details:SetText(LOG:GetDetailsText(entry))
        row.details:Show()
        y = y - row.details:GetStringHeight() - 4
    else
        row.details:Hide()
    end

    row.trackButton:SetText(entry.isTracked and L["MissionFocus.log.untrack"] or L["MissionFocus.log.track"])
    row.expandButton:SetText(expanded and L["MissionFocus.log.less"] or L["MissionFocus.log.more"])

    local height = math.max(-y + ROW_PADDING - 4, ROW_MIN_HEIGHT)
    row:SetSize(width, height)
    row:Show()
    CheckHover(row)
    return height
end

---------------------------------------------------------
-- Refresh / layout

function LOG:Refresh()
    if not self.frame or not self.frame:IsShown() then
        return
    end
    MissionFocus_Background:ApplyWindow(self.frame, { width = WIDTH, height = HEIGHT })
    if self.activeTab ~= "log" then
        return
    end
    local visible, all, zones = self:CollectEntries()
    self.visibleItems = visible
    self.allItems = all
    self.lastZones = zones
    self:SyncWidgets(zones)
    self.countText:SetText(string.format(L["MissionFocus.log.count"], #visible, #all))
    self:Layout()
end

function LOG:Layout()
    if not self.frame or not self.visibleItems then
        return
    end
    local content = self.frame.content
    local width = content:GetWidth()
    local focusID = MissionFocus_UI.currentFocusQuestID
    local y = 0
    local highlightOffset
    for i, item in ipairs(self.visibleItems) do
        local row = GetRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        if self.highlightID and item.entry.questID == self.highlightID then
            highlightOffset = y
        end
        y = y + FillRow(row, item, width, focusID) + ROW_GAP
    end
    for i = #self.visibleItems + 1, #rows do
        rows[i]:Hide()
        rows[i].item = nil
    end
    content:SetHeight(math.max(y, 10))

    if highlightOffset then
        self.highlightID = nil
        local scroll = self.frame.scroll
        local maxScroll = math.max(0, y - scroll:GetHeight())
        scroll:SetVerticalScroll(math.min(highlightOffset, maxScroll))
    end
end

-- Coalesced refresh for quest events.
function LOG:RequestRefresh()
    if not self.frame or not self.frame:IsShown() or self.refreshPending then
        return
    end
    self.refreshPending = true
    C_Timer.After(0.15, function()
        LOG.refreshPending = false
        LOG:Refresh()
    end)
end

---------------------------------------------------------
-- Open / close

-- questID (optional): scroll to that quest. tab (optional): "log" | "modes", else the last one.
function LOG:Open(questID, tab)
    self:Create()
    self.highlightID = questID
    if tab then
        self.activeTab = tab
    end
    if self.frame:IsShown() then
        self:SelectTab(self.activeTab)
    else
        self.frame:Show() -- OnShow selects the tab
    end
end

function LOG:Toggle(questID)
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Open(questID)
    end
end
