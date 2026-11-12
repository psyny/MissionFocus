-- MissionFocus_QuestlinesUI.lua
-- Questlines tab of the MissionFocus Center (data: MissionFocus_Questlines.lua).
--   List: the recorded questlines, filtered (category, completed) and sorted (recent, nearby,
--         name); each row shows the step the player is at. Hover: Focus / Waypoint button.
--         "Find Quests" adds the questlines available around the player.
--   Detail (click a row): the questline as a top-to-bottom flow of quest boxes
--         (MissionFocus_QuestlineGraph.lua); clicking a box runs its Focus / Waypoint action.
--         With BtWQuests: parallel branches, and boxes linking to what comes before.
MissionFocus_QuestlinesUI = {}

local UIQ = MissionFocus_QuestlinesUI
local QL = MissionFocus_Questlines
local Q = MissionFocus_Quests
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
local AceGUI = LibStub("AceGUI-3.0")

local TOP_BAR_HEIGHT = 32
local ROW_HEIGHT = 58
local ROW_GAP = 4
local ROW_PADDING = 6
local ACTION_WIDTH = 72
local FIND_RESCAN_DELAY = 1.5

UIQ.CATEGORY_FILTERS = { "all", "campaign", "side" }
UIQ.SORTS = { "recent", "nearby", "category", "name" }

UIQ.page = nil
UIQ.detailLineID = nil
UIQ.history = {}      -- questlines left by following a link (Back returns to them)
UIQ.scrollToNow = false

local listRows = {}

local function Filters()
    return MissionFocus_Options.db.questline_filters
end

local function CategoryColor(category)
    return Q.CATEGORY_COLORS[category] or { r = 1, g = 0.82, b = 0 }
end

local function SetTooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        MissionFocus_Utils.Tooltip():SetOwner(self, "ANCHOR_TOP")
        MissionFocus_Utils.Tooltip():SetText(text, 1, 1, 1, 1, true)
        MissionFocus_Utils.Tooltip():Show()
    end)
    frame:SetScript("OnLeave", function() MissionFocus_Utils.Tooltip():Hide() end)
end

local function Ago(timestamp)
    if not timestamp then
        return "?"
    end
    local seconds = math.max(0, time() - timestamp)
    if seconds < 3600 then
        return string.format(L["MissionFocus.questlines.ago_minutes"], math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format(L["MissionFocus.questlines.ago_hours"], math.floor(seconds / 3600))
    end
    return string.format(L["MissionFocus.questlines.ago_days"], math.floor(seconds / 86400))
end

local function StepTitle(step)
    return step and (step.title or L["MissionFocus.questlines.loading"]) or "?"
end

-- One line saying where the player stands.
local function StateText(state)
    local step = state.index and state.steps[state.index]
    if state.state == "complete" then
        return "|cff66ff66" .. L["MissionFocus.questlines.state_complete"] .. "|r"
    elseif state.state == "current" then
        return string.format(L["MissionFocus.questlines.state_current"], StepTitle(step))
    elseif state.state == "next" then
        return "|cffffd100" .. string.format(L["MissionFocus.questlines.state_next"], StepTitle(step)) .. "|r"
    elseif state.state == "start" then
        return string.format(L["MissionFocus.questlines.state_start"], StepTitle(step))
    end
    return "|cff999999" .. L["MissionFocus.questlines.state_unknown"] .. "|r"
end

local function StepCountText(state)
    if state.state == "unknown" then
        return ""
    end
    if state.state == "complete" then
        return string.format(L["MissionFocus.questlines.steps_done"], state.total, state.total)
    end
    return string.format(L["MissionFocus.questlines.step_of"], state.index, state.total)
end

local function ActionLabel(action)
    return action == "focus" and L["MissionFocus.questlines.focus"] or L["MissionFocus.questlines.waypoint"]
end

---------------------------------------------------------
-- Building the list

-- Region group for "nearby": 0 = player's zone, 1 = player's continent, 2 = elsewhere / unknown.
local function NearbyGroup(mapID, playerZone, playerContinent)
    local LOC = MissionFocus_Location
    if mapID and playerZone and LOC:GetRegion(mapID, "zone") == playerZone then
        return 0
    end
    if mapID and playerContinent and LOC:GetRegion(mapID, "continent") == playerContinent then
        return 1
    end
    return 2
end

function UIQ:CollectLines()
    local filters = Filters()
    local LOC = MissionFocus_Location
    local playerZone = LOC:GetPlayerRegion("zone")
    local playerContinent = LOC:GetPlayerRegion("continent")
    local items = {}
    for _, entry in ipairs(QL:GetLines()) do
        local line = entry.line
        local category = QL:GetCategory(line)
        local keep = filters.category == "all"
            or (filters.category == "campaign" and category == "campaign")
            or (filters.category == "side" and category ~= "campaign")
        local state = keep and QL:GetState(entry.lineID)
        if state and state.state == "complete" and not filters.completed then
            keep = false
        end
        if keep then
            items[#items + 1] = {
                lineID = entry.lineID,
                line = line,
                category = category,
                state = state,
                group = NearbyGroup(line.mapID, playerZone, playerContinent),
            }
        end
    end
    local sort = filters.sort
    local rank = {}
    for i, key in ipairs(Q:GetCategoryOrder()) do
        rank[key] = i
    end
    table.sort(items, function(a, b)
        -- By category: cycle priority order, nearby first within a category.
        if sort == "category" then
            local ra, rb = rank[a.category] or 99, rank[b.category] or 99
            if ra ~= rb then
                return ra < rb
            end
            if a.group ~= b.group then
                return a.group < b.group
            end
        end
        if sort == "nearby" and a.group ~= b.group then
            return a.group < b.group
        end
        if sort == "name" and a.line.name ~= b.line.name then
            return (a.line.name or "") < (b.line.name or "")
        end
        if (a.line.lastSeen or 0) ~= (b.line.lastSeen or 0) then
            return (a.line.lastSeen or 0) > (b.line.lastSeen or 0)
        end
        return a.lineID < b.lineID
    end)
    return items
end

---------------------------------------------------------
-- List rows

local function CheckHover(row)
    local hovered = row:IsMouseOver()
    row.action:SetShown(hovered and row.actionKind ~= nil)
    row.steps:SetShown(not (hovered and row.actionKind ~= nil))
end

local function GetListRow(index)
    local row = listRows[index]
    if row then
        return row
    end
    local content = UIQ.page.listContent
    row = CreateFrame("Button", nil, content, "BackdropTemplate")
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(1, 1, 1, 0.03)
    row:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.04)
    row:SetHeight(ROW_HEIGHT)

    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.stripe:SetWidth(3)
    row.stripe:SetPoint("TOPLEFT")
    row.stripe:SetPoint("BOTTOMLEFT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetPoint("TOPLEFT", ROW_PADDING + 6, -ROW_PADDING)
    row.name:SetPoint("RIGHT", -(ROW_PADDING + ACTION_WIDTH + 8), 0)

    row.steps = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.steps:SetJustifyH("RIGHT")
    row.steps:SetPoint("TOPRIGHT", -ROW_PADDING, -ROW_PADDING - 1)

    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.state:SetJustifyH("LEFT")
    row.state:SetWordWrap(false)
    row.state:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.state:SetPoint("RIGHT", -ROW_PADDING, 0)

    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    row.meta:SetPoint("TOPLEFT", row.state, "BOTTOMLEFT", 0, -3)
    row.meta:SetPoint("RIGHT", -ROW_PADDING, 0)

    -- Progress: a thin bar along the bottom.
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    row.bar:SetPoint("BOTTOMLEFT", 3, 0)
    row.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    row.bar:SetHeight(2)
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints()
    row.bar.bg:SetColorTexture(1, 1, 1, 0.08)

    row.action = MissionFocus_Log.CreateButton(row, "", ACTION_WIDTH, function()
        local item = row.item
        QL:RunStepAction(item.lineID, item.state.steps[item.state.index])
    end)
    row.action:SetPoint("TOPRIGHT", -ROW_PADDING, -ROW_PADDING + 2)
    row.action:HookScript("OnLeave", function() CheckHover(row) end)

    row:SetScript("OnEnter", CheckHover)
    row:SetScript("OnLeave", CheckHover)
    row:SetScript("OnClick", function()
        UIQ:ShowDetail(row.item.lineID)
    end)

    listRows[index] = row
    return row
end

local function FillListRow(row, item, width)
    row.item = item
    local line, state = item.line, item.state
    local color = CategoryColor(item.category)
    row.stripe:SetVertexColor(color.r, color.g, color.b, 1)
    row.name:SetText(line.name or ("#" .. item.lineID))
    row.name:SetTextColor(color.r, color.g, color.b, 1)
    row.steps:SetText(StepCountText(state))
    row.state:SetText(StateText(state))

    local meta = { L["MissionFocus.category." .. item.category] or item.category }
    if line.mapID then
        meta[#meta + 1] = QL.MapName(line.mapID)
    end
    meta[#meta + 1] = Ago(line.lastSeen)
    if line.flags and line.flags.isAccountCompleted then
        meta[#meta + 1] = L["MissionFocus.questlines.account_completed"]
    end
    if line.flags and line.flags.isHidden then
        meta[#meta + 1] = L["MissionFocus.questlines.hidden"]
    end
    row.meta:SetText(table.concat(meta, "  ·  "))

    row.bar:SetMinMaxValues(0, math.max(1, state.total))
    row.bar:SetValue(state.done)
    if state.state == "complete" then
        row.bar:SetStatusBarColor(0.4, 1, 0.4, 0.8)
    else
        row.bar:SetStatusBarColor(color.r, color.g, color.b, 0.8)
    end

    row.actionKind = QL:GetStepAction(state.index and state.steps[state.index])
    if row.actionKind then
        row.action:SetText(ActionLabel(row.actionKind))
    end
    row:SetWidth(width)
    row:Show()
    CheckHover(row)
end

---------------------------------------------------------
-- Detail: the questline as a horizontal flow of boxes (MissionFocus_QuestlineGraph.lua)

local GRAPH = MissionFocus_QuestlineGraph
local BTW = MissionFocus_BtW

local ACTION_KINDS = { current = true, next = true, available = true, behind = true }

local function NodeAction(node)
    return ACTION_KINDS[node.kind] and QL:GetStepAction(node.step) or nil
end

local function KindText(kind)
    local keys = { done = "step_done", current = "step_current", next = "step_next",
        available = "step_available", behind = "step_behind", future = "step_future" }
    return keys[kind] and L["MissionFocus.questlines." .. keys[kind]] or ""
end

local function StepTooltip(owner, node)
    local tip = MissionFocus_Utils.Tooltip()
    local step = node.step
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    tip:SetText(StepTitle(step), 1, 0.82, 0, 1, true)
    tip:AddLine("#" .. step.questID, 0.6, 0.6, 0.6)
    tip:AddLine(KindText(node.kind), 1, 1, 1, true)
    if node.kind == "behind" then
        tip:AddLine(L["MissionFocus.questlines.step_behind_tip"], 0.8, 0.8, 0.8, true)
    end
    if node.optional then
        tip:AddLine(L["MissionFocus.questlines.step_optional_tip"], 0.8, 0.8, 0.8, true)
    end
    if step.parallel then
        tip:AddLine(L["MissionFocus.questlines.step_parallel_tip"], 0.53, 0.8, 1, true)
    end
    if node.extra then
        tip:AddLine(L["MissionFocus.questlines.step_extra_tip"], 0.53, 0.8, 1, true)
    end
    local giver, mapID = BTW:GetQuestGiver(step.questID)
    if giver then
        local where = mapID and (" (" .. QL.MapName(mapID) .. ")") or ""
        tip:AddLine(string.format(L["MissionFocus.questlines.giver"], giver .. where), 0.8, 0.8, 0.8, true)
    end
    local action = NodeAction(node)
    if action then
        tip:AddLine(L["MissionFocus.questlines.click_" .. action], 0, 1, 0)
    end
    tip:Show()
end

-- The questline of a BtWQuests chain: the ID BtWQuests stores, else one of our questlines that
-- matched the chain. Cached until another questline is opened (tooltips ask on every hover).
local chainLines = {}
local function LineForChain(chainID)
    if chainLines[chainID] ~= nil then
        return chainLines[chainID] or nil
    end
    local lineID = BTW:GetLineForChain(chainID)
    if not lineID then
        for _, entry in ipairs(QL:GetLines()) do
            local questIDs = MissionFocus_Utils.Call("C_QuestLine.GetQuestLineQuests", entry.lineID)
            if type(questIDs) == "table" and #questIDs > 0 and BTW:GetChainForLine(entry.lineID, questIDs) == chainID then
                lineID = entry.lineID
                break
            end
        end
    end
    chainLines[chainID] = lineID or false
    return lineID
end

local function PrereqTooltip(owner, prereq)
    local tip = MissionFocus_Utils.Tooltip()
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    if prereq.kind == "level" then
        tip:SetText(string.format(L["MissionFocus.questlines.prereq_level"], prereq.level), 0.75, 0.85, 1, 1, true)
    else
        tip:SetText(prereq.name or L["MissionFocus.questlines.prereq_unnamed"], 0.75, 0.85, 1, 1, true)
    end
    tip:AddLine(L["MissionFocus.questlines.prereq_tip"], 0.8, 0.8, 0.8, true)
    tip:AddLine(prereq.done and L["MissionFocus.questlines.step_done"] or L["MissionFocus.questlines.prereq_not_done"], 1, 1, 1)
    if prereq.kind == "chain" then
        if LineForChain(prereq.chainID) then
            tip:AddLine(L["MissionFocus.questlines.click_open_line"], 0, 1, 0)
        elseif BtWQuestsFrame then
            tip:AddLine(L["MissionFocus.questlines.click_open_btw"], 0, 1, 0)
        end
    end
    tip:Show()
end

local function PrereqClick(prereq)
    if prereq.kind ~= "chain" then
        return
    end
    local lineID = LineForChain(prereq.chainID)
    if lineID then
        QL:EnsureLine(lineID, prereq.name)
        UIQ:ShowDetail(lineID, true)
    else
        BTW:OpenChain(prereq.chainID)
    end
end

local GRAPH_HANDLERS = {
    stepTooltip = StepTooltip,
    stepClick = function(node)
        if NodeAction(node) then
            QL:RunStepAction(UIQ.detailLineID, node.step)
        end
    end,
    prereqTooltip = PrereqTooltip,
    prereqClick = PrereqClick,
}

-- push: keep the questline shown now, so Back returns to it (links between questlines).
-- context: where it was opened from, shown above the title (e.g. "Tale - Story - Chapter").
-- returnTo: { taleID, viewID } when opened from a tale: Back goes back there, not to the list.
function UIQ:ShowDetail(lineID, push, context, returnTo)
    if push and self.detailLineID and self.detailLineID ~= lineID then
        table.insert(self.history, { lineID = self.detailLineID, context = self.detailContext, returnTo = self.detailReturn })
    elseif not push then
        self.history = {}
    end
    self.detailLineID = lineID
    self.detailContext = context
    if not push then
        self.detailReturn = returnTo
    end
    self.scrollToNow = true
    chainLines = {}
    self.page.list:Hide()
    self.page.detail:Show()
    self:Refresh()
end

function UIQ:Back()
    local previous = table.remove(self.history)
    if not previous and self.detailReturn then
        -- Opened from a tale: back to that tale's chapter, in the Tales tab.
        local returnTo = self.detailReturn
        self:ShowList()
        MissionFocus_TalesUI:ReturnTo(returnTo.taleID, returnTo.viewID)
        return
    end
    if previous and QL:GetLine(previous.lineID) then
        self.detailLineID = previous.lineID
        self.detailContext = previous.context
        self.detailReturn = previous.returnTo
        self.scrollToNow = true
        self:Refresh()
    else
        self:ShowList()
    end
end

function UIQ:ShowList()
    self.detailLineID = nil
    self.detailContext = nil
    self.detailReturn = nil
    self.history = {}
    self.page.detail:Hide()
    self.page.list:Show()
    self:Refresh()
end

function UIQ:LayoutDetail()
    local page = self.page
    local line = QL:GetLine(self.detailLineID)
    if not line then
        self:ShowList()
        return
    end
    local state = QL:GetState(self.detailLineID)
    local graph = QL:GetGraph(self.detailLineID, state)
    local category = QL:GetCategory(line)
    local color = CategoryColor(category)

    page.detailName:SetText(string.format(L["MissionFocus.questlines.view_title"], line.name or ("#" .. self.detailLineID)))
    page.detailContext:SetText(self.detailContext or "")
    page.backButton:SetText((self.detailReturn and #self.history == 0) and L["MissionFocus.questlines.back_to_tale"]
        or L["MissionFocus.questlines.back"])
    page.detailName:SetTextColor(color.r, color.g, color.b, 1)
    local meta = { L["MissionFocus.category." .. category] or category }
    if line.mapID then
        meta[#meta + 1] = QL.MapName(line.mapID)
    end
    meta[#meta + 1] = StepCountText(state)
    if graph.chainID then
        meta[#meta + 1] = "|cff88ccff" .. L["MissionFocus.questlines.source_btw"] .. "|r"
    end
    page.detailMeta:SetText(table.concat(meta, "  ·  "))
    page.detailState:SetText(StateText(state))

    page.detailBar:SetMinMaxValues(0, math.max(1, state.total))
    page.detailBar:SetValue(state.done)
    page.detailBar:SetStatusBarColor(color.r, color.g, color.b, 0.9)

    page.detailChainID = graph.chainID
    page.btwButton:SetShown(graph.chainID ~= nil and BtWQuestsFrame ~= nil)

    GRAPH:Render(page.graph, graph, GRAPH_HANDLERS, self.scrollToNow)
    self.scrollToNow = false
end

---------------------------------------------------------
-- Page

local function CreateScroll(parent, top, width)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -top)
    scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width, 10)
    scroll:SetScrollChild(content)
    return scroll, content
end

local function OrderedList(keys, prefix)
    local list = {}
    for _, key in ipairs(keys) do
        list[key] = L[prefix .. key]
    end
    return list
end

local function PlaceDropdown(parent, keys, prefix, x, width, onChange)
    local dropdown = AceGUI:Create("Dropdown")
    dropdown:SetList(OrderedList(keys, prefix), keys)
    dropdown:SetCallback("OnValueChanged", function(_, _, key)
        onChange(key)
    end)
    dropdown.frame:SetParent(parent)
    dropdown.frame:ClearAllPoints()
    dropdown.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
    dropdown:SetWidth(width)
    dropdown.frame:Show()
    return dropdown
end

-- parent: the Center frame; the page fills the area below its header.
function UIQ:CreatePage(parent, padding, top)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", padding, -top)
    page:SetPoint("BOTTOMRIGHT", -padding, padding)
    page:Hide()
    self.page = page
    local contentWidth = parent:GetWidth() - padding * 2 - 26

    -- List view
    -- The list starts below the tab's intro paragraph (the detail views use the full page).
    local list = CreateFrame("Frame", nil, page)
    list:SetPoint("TOPLEFT", 0, -MissionFocus_Log.INTRO_HEIGHT)
    list:SetPoint("BOTTOMRIGHT")
    MissionFocus_Log.CreateIntro(list, L["MissionFocus.center.intro_questlines"], list)
    page.list = list

    local find = MissionFocus_Log.CreateButton(list, L["MissionFocus.questlines.find"], 100, function()
        UIQ:FindQuests()
    end)
    find:SetPoint("TOPLEFT", 0, -4)
    SetTooltip(find, L["MissionFocus.questlines.find_tip"])

    page.categoryDropdown = PlaceDropdown(list, UIQ.CATEGORY_FILTERS, "MissionFocus.questlines.category_", 110, 130, function(key)
        Filters().category = key
        UIQ:Refresh()
    end)
    page.sortDropdown = PlaceDropdown(list, UIQ.SORTS, "MissionFocus.questlines.sort_", 248, 120, function(key)
        Filters().sort = key
        UIQ:Refresh()
    end)

    local completed = CreateFrame("CheckButton", nil, list, "UICheckButtonTemplate")
    completed:SetSize(22, 22)
    completed:SetPoint("TOPLEFT", 376, -3)
    completed.label = completed:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    completed.label:SetPoint("LEFT", completed, "RIGHT", 0, 1)
    completed.label:SetText(L["MissionFocus.questlines.show_completed"])
    completed:SetScript("OnClick", function(self)
        Filters().completed = self:GetChecked() and true or false
        UIQ:Refresh()
    end)
    page.completedCheck = completed

    page.count = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.count:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -8)
    page.count:SetJustifyH("RIGHT")

    page.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    page.empty:SetPoint("TOP", list, "TOP", 0, -(TOP_BAR_HEIGHT + 40))
    page.empty:SetWidth(contentWidth - 40)
    page.empty:SetText(L["MissionFocus.questlines.empty"])

    page.listScroll, page.listContent = CreateScroll(list, TOP_BAR_HEIGHT, contentWidth)

    -- Detail view
    local detail = CreateFrame("Frame", nil, page)
    detail:SetAllPoints()
    detail:Hide()
    page.detail = detail

    page.backButton = MissionFocus_Log.CreateButton(detail, L["MissionFocus.questlines.back"], 70, function()
        UIQ:Back()
    end)
    page.backButton:SetPoint("TOPLEFT", 0, -4)

    page.btwButton = MissionFocus_Log.CreateButton(detail, L["MissionFocus.questlines.open_btw"], 110, function()
        MissionFocus_BtW:OpenChain(page.detailChainID)
    end)
    page.addTaleButton = MissionFocus_Log.CreateButton(detail, L["MissionFocus.tales.add_to_tale_button"], 90, function(self)
        local lineID = UIQ.detailLineID
        MissionFocus_TalesUI:ShowAddMenu(self, function()
            return { type = "questline", questLineID = lineID }
        end)
    end)
    page.addTaleButton:SetPoint("TOPRIGHT", 0, -4)
    SetTooltip(page.addTaleButton, L["MissionFocus.tales.add_to_tale_tip"])
    page.btwButton:SetPoint("RIGHT", page.addTaleButton, "LEFT", -4, 0)
    page.btwButton:Hide()
    SetTooltip(page.btwButton, L["MissionFocus.questlines.open_btw_tip"])

    -- Same header as the Tales views, centered below the buttons: where it was opened from (a
    -- tale, small), "Questline: <name>", then its details.
    page.detailContext = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.detailContext:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -28)
    page.detailContext:SetPoint("TOPRIGHT", detail, "TOPRIGHT", 0, -28)
    page.detailContext:SetHeight(12)
    page.detailContext:SetJustifyH("CENTER")
    page.detailContext:SetWordWrap(false)
    page.detailContext:SetTextColor(0.8, 0.8, 0.8, 1)

    page.detailName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    page.detailName:SetPoint("TOPLEFT", page.detailContext, "BOTTOMLEFT", 0, -2)
    page.detailName:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    page.detailName:SetJustifyH("CENTER")
    page.detailName:SetWordWrap(false)

    page.detailMeta = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.detailMeta:SetPoint("TOPLEFT", page.detailName, "BOTTOMLEFT", 0, -4)
    page.detailMeta:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    page.detailMeta:SetJustifyH("CENTER")

    page.detailState = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    page.detailState:SetPoint("TOPLEFT", page.detailMeta, "BOTTOMLEFT", 0, -4)
    page.detailState:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    page.detailState:SetJustifyH("CENTER")

    page.detailBar = CreateFrame("StatusBar", nil, detail)
    page.detailBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    page.detailBar:SetPoint("TOPLEFT", page.detailState, "BOTTOMLEFT", 0, -6)
    page.detailBar:SetPoint("RIGHT", detail, "RIGHT", -22, 0)
    page.detailBar:SetHeight(4)
    local barBg = page.detailBar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(1, 1, 1, 0.08)

    page.graph = MissionFocus_QuestlineGraph:Create(detail, 124)

    -- Data arrives asynchronously: questline data, quest titles, quest progress.
    local events = CreateFrame("Frame", nil, page)
    for _, event in ipairs({ "QUESTLINE_UPDATE", "QUEST_DATA_LOAD_RESULT", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN" }) do
        pcall(events.RegisterEvent, events, event)
    end
    events:SetScript("OnEvent", function(_, event)
        UIQ:RequestRefresh(event == "QUESTLINE_UPDATE")
    end)
end

function UIQ:FindQuests()
    QL:Find(true)
    self:Refresh()
    -- The questline data of the maps arrives a moment later.
    C_Timer.After(FIND_RESCAN_DELAY, function()
        local found = QL:Find(false)
        MissionFocus_Utils.Print(string.format(L["MissionFocus.questlines.found"], found))
        UIQ:Refresh()
    end)
end

-- Coalesced: quest events come in bursts. sync: questline data arrived, look up log quests again.
function UIQ:RequestRefresh(sync)
    if not self.page or not self.page:IsVisible() then
        return
    end
    self.pendingSync = self.pendingSync or sync
    if self.refreshPending then
        return
    end
    self.refreshPending = true
    C_Timer.After(0.3, function()
        UIQ.refreshPending = false
        if UIQ.pendingSync then
            UIQ.pendingSync = false
            QL:Sync()
        end
        UIQ:Refresh()
    end)
end

function UIQ:OnShow()
    QL:Sync()
    self:Refresh()
end

function UIQ:Refresh()
    local page = self.page
    if not page or not page:IsVisible() then
        return
    end
    if self.detailLineID then
        self:LayoutDetail()
        return
    end

    local filters = Filters()
    page.categoryDropdown:SetValue(filters.category)
    page.sortDropdown:SetValue(filters.sort)
    page.completedCheck:SetChecked(filters.completed)

    local items = self:CollectLines()
    page.count:SetText(string.format(L["MissionFocus.questlines.count"], #items))
    page.empty:SetShown(#items == 0)

    local content = page.listContent
    local width = content:GetWidth()
    local y = 0
    for i, item in ipairs(items) do
        local row = GetListRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        FillListRow(row, item, width)
        y = y + ROW_HEIGHT + ROW_GAP
    end
    for i = #items + 1, #listRows do
        listRows[i]:Hide()
        listRows[i].item = nil
    end
    content:SetHeight(math.max(y, 10))
end
