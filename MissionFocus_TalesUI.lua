-- MissionFocus_TalesUI.lua
-- Tales tab of the MissionFocus Center (data and rules: MissionFocus_Tales.lua).
--   List: every saved tale with its progress; New Tale, Import, Core Tales, Hide spoilers.
--   View: a tale, story or chapter as a top-to-bottom flow (MissionFocus_QuestlineGraph.lua).
--         Clicking a story or chapter goes inside; clicking a step does it (focus, waypoint,
--         questline view...); Shift-click marks dungeons, visits and notes done.
--         The top row shows what comes before the item and what it requires.
--   Edit: the tale editor (MissionFocus_TalesEditor.lua).
-- Also: the import / export text window and the "Add to Tale" menu used by other tabs.
MissionFocus_TalesUI = {}

local UIT = MissionFocus_TalesUI
local T = MissionFocus_Tales
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")

local ROW_HEIGHT = 58
local ROW_GAP = 4
local ROW_PADDING = 6
local TOP_BAR_HEIGHT = 32
local HEADER_HEIGHT = 150 -- buttons, title, where it is, meta, description, progress bar
local REFRESH_DELAY = 0.15

UIT.page = nil
UIT.mode = "list"     -- list | view | edit
UIT.taleID = nil
UIT.viewID = nil      -- the tale, story or chapter shown
UIT.history = {}
UIT.scrollToNow = false

local listRows = {}

local function Tip()
    return MissionFocus_Utils.Tooltip()
end

local function SetTooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        Tip():SetOwner(self, "ANCHOR_TOP")
        Tip():SetText(text, 1, 1, 1, 1, true)
        Tip():Show()
    end)
    frame:SetScript("OnLeave", function() Tip():Hide() end)
end

local function Button(parent, text, width, onClick)
    return MissionFocus_Log.CreateButton(parent, text, width, onClick)
end

local function HideSpoilers()
    return MissionFocus_Options.db.tales_hide_spoilers
end

local function Hidden(result)
    return HideSpoilers() and (result.kind == "future" or result.kind == "blocked")
end

local function FactionText(tale)
    return L["MissionFocus.tales.faction_" .. (tale.faction or "both")]
end

local function ProgressText(result)
    if (result.total or 0) == 0 then
        return ""
    end
    return string.format(L["MissionFocus.tales.progress"], result.doneCount, result.total)
end

---------------------------------------------------------
-- List

local function GetListRow(index)
    local row = listRows[index]
    if row then
        return row
    end
    local content = UIT.page.listContent
    row = CreateFrame("Button", nil, content, "BackdropTemplate")
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    row:SetBackdropColor(1, 1, 1, 0.03)
    row:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.04)
    row:SetHeight(ROW_HEIGHT)

    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetColorTexture(1, 0.82, 0, 1)
    row.stripe:SetWidth(3)
    row.stripe:SetPoint("TOPLEFT")
    row.stripe:SetPoint("BOTTOMLEFT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetPoint("TOPLEFT", ROW_PADDING + 6, -ROW_PADDING)
    row.name:SetPoint("RIGHT", -(ROW_PADDING + 90), 0)

    row.progress = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.progress:SetJustifyH("RIGHT")
    row.progress:SetPoint("TOPRIGHT", -ROW_PADDING, -ROW_PADDING - 1)

    row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.desc:SetJustifyH("LEFT")
    row.desc:SetWordWrap(false)
    row.desc:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.desc:SetPoint("RIGHT", -ROW_PADDING, 0)

    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    row.meta:SetPoint("TOPLEFT", row.desc, "BOTTOMLEFT", 0, -3)
    row.meta:SetPoint("RIGHT", -ROW_PADDING, 0)

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    row.bar:SetPoint("BOTTOMLEFT", 3, 0)
    row.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    row.bar:SetHeight(2)
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints()
    row.bar.bg:SetColorTexture(1, 1, 1, 0.08)

    row.follow = Button(row, "", 80, function()
        local followed = T:GetFollowed()
        T:SetFollow((followed and followed.id == row.taleID) and nil or row.taleID)
    end)
    row.follow:SetPoint("TOPRIGHT", -ROW_PADDING, -ROW_PADDING + 2)
    local function CheckHover()
        local hovered = row:IsMouseOver()
        row.follow:SetShown(hovered)
        row.progress:SetShown(not hovered)
    end
    row.follow:HookScript("OnLeave", CheckHover)
    row:SetScript("OnEnter", CheckHover)
    row:SetScript("OnLeave", CheckHover)
    row.CheckHover = CheckHover
    row:SetScript("OnClick", function()
        UIT:OpenTale(row.taleID)
    end)

    listRows[index] = row
    return row
end

function UIT:LayoutList()
    local page = self.page
    local tales = T:GetTales()
    local followed = T:GetFollowed()
    local recordingTale = T:GetRecording()
    page.empty:SetShown(#tales == 0)
    -- Core Tales: shown while a core tale is missing or has a newer version.
    local missing, outdated = T:CoreStatus()
    page.coreButton:SetShown(#missing > 0 or #outdated > 0)
    page.spoilerCheck:SetChecked(HideSpoilers())

    local content = page.listContent
    local width = content:GetWidth()
    local y = 0
    for i, tale in ipairs(tales) do
        local row = GetListRow(i)
        local result = T:Evaluate(tale)
        row.taleID = tale.id
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        row:SetWidth(width)
        row.name:SetText(tale.title)
        row.desc:SetText(tale.description or "")
        local meta = {}
        if tale.author then
            meta[#meta + 1] = string.format(L["MissionFocus.tales.by_author"], tale.author)
        end
        meta[#meta + 1] = L["MissionFocus.tales.game_" .. (tale.game or "retail")]
        meta[#meta + 1] = FactionText(tale)
        if not T:GameAllowed(tale) then
            meta[#meta + 1] = "|cffff6666" .. L["MissionFocus.tales.not_your_game"] .. "|r"
        elseif not T:FactionAllowed(tale) then
            meta[#meta + 1] = "|cffff6666" .. L["MissionFocus.tales.not_your_faction"] .. "|r"
        end
        if followed and followed.id == tale.id then
            meta[#meta + 1] = "|cff66ff66" .. L["MissionFocus.tales.following_tag"] .. "|r"
        end
        if recordingTale and recordingTale.id == tale.id then
            meta[#meta + 1] = "|cffff4444" .. L["MissionFocus.tales.recording_tag"] .. "|r"
        end
        row.meta:SetText(table.concat(meta, "  ·  "))
        row.progress:SetText(result.done and ("|cff66ff66" .. L["MissionFocus.tales.kind_done"] .. "|r") or ProgressText(result))
        row.bar:SetMinMaxValues(0, math.max(1, result.total))
        row.bar:SetValue(result.doneCount)
        if result.done then
            row.bar:SetStatusBarColor(0.4, 1, 0.4, 0.8)
        else
            row.bar:SetStatusBarColor(1, 0.82, 0, 0.8)
        end
        row.follow:SetText((followed and followed.id == tale.id) and L["MissionFocus.tales.unfollow"] or L["MissionFocus.tales.follow"])
        row:Show()
        row.CheckHover()
        y = y + ROW_HEIGHT + ROW_GAP
    end
    for i = #tales + 1, #listRows do
        listRows[i]:Hide()
    end
    content:SetHeight(math.max(y, 10))
end

---------------------------------------------------------
-- View: a tale, story or chapter as a flow

local LEVEL_WORDS = { tale = "level_tale", story = "level_story", chapter = "level_chapter" }

local function KindWord(kind)
    return L["MissionFocus.tales.kind_" .. kind] or ""
end

local function StepTypeWord(step)
    return L["MissionFocus.tales.type_" .. step.type] or step.type
end

-- Status line of a box.
local function StatusText(result)
    local parts = {}
    if result.item.role == "optional" then
        parts[#parts + 1] = L["MissionFocus.tales.role_optional"]
    elseif result.item.role == "side" then
        parts[#parts + 1] = L["MissionFocus.tales.role_side"]
    end
    if result.level == "step" then
        parts[#parts + 1] = StepTypeWord(result.item)
        if result.item.type == "questline" and (result.lineTotal or 0) > 0 then
            parts[#parts + 1] = string.format(L["MissionFocus.tales.progress"], result.lineDone, result.lineTotal)
        end
    else
        parts[#parts + 1] = L["MissionFocus.tales." .. LEVEL_WORDS[result.level]]
        local progress = ProgressText(result)
        if progress ~= "" then
            parts[#parts + 1] = progress
        end
    end
    if result.kind ~= "note" and result.kind ~= "future" then
        parts[#parts + 1] = KindWord(result.kind)
    end
    return table.concat(parts, "  ·  ")
end

local ROLE_HINT = { main = 0, side = 1, optional = 2 }

-- The flow of an item's children, in the shape MissionFocus_QuestlineGraph draws.
local function BuildGraph(tale, result)
    local graph = { nodes = {}, edges = {}, prereqs = {} }
    for i, child in ipairs(result.children) do
        local title = Hidden(child) and L["MissionFocus.tales.spoiler"] or T:Title(child.item, child.level)
        graph.nodes[i] = {
            step = { title = title },
            kind = child.kind,
            hint = ROLE_HINT[child.item.role or "main"] or 0,
            statusText = StatusText(child),
            result = child,
        }
        for _, p in ipairs(child.preds or {}) do
            graph.edges[#graph.edges + 1] = { from = p, to = i }
        end
    end
    -- Top row: what comes before this item (its "previous"), then what it requires.
    local parent = result.parent
    if parent then
        for _, p in ipairs(result.preds or {}) do
            local pred = parent.children[p]
            graph.prereqs[#graph.prereqs + 1] = {
                kind = "item",
                header = L["MissionFocus.tales.after_header"],
                name = T:Title(pred.item, pred.level),
                done = pred.done,
                result = pred,
            }
        end
    end
    for _, req in ipairs(result.reqs or {}) do
        graph.prereqs[#graph.prereqs + 1] = {
            kind = "requirement",
            header = L["MissionFocus.tales.requires_header"],
            name = req.label,
            done = req.done,
        }
    end
    for i, node in ipairs(graph.nodes) do
        if node.kind == "current" or node.kind == "next" then
            graph.now = graph.now or i
        end
    end
    graph.emptyText = result.level == "chapter" and L["MissionFocus.tales.empty_chapter"] or L["MissionFocus.tales.empty_item"]
    return graph
end

local function AddRequirementLines(tip, result)
    for _, req in ipairs(result.reqs or {}) do
        if req.done then
            tip:AddLine("|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t " .. req.label, 0.6, 0.9, 0.6)
        else
            tip:AddLine("|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t " .. req.label, 1, 0.5, 0.5)
        end
    end
end

local function NodeTooltip(owner, node)
    local result = node.result
    local item = result.item
    local tip = Tip()
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    local hidden = Hidden(result)
    tip:SetText(hidden and L["MissionFocus.tales.spoiler"] or T:Title(item, result.level), 1, 0.82, 0, 1, true)
    tip:AddLine(StatusText(result), 0.7, 0.7, 0.7, true)
    if hidden then
        tip:AddLine(L["MissionFocus.tales.spoiler_tip"], 0.8, 0.8, 0.8, true)
        tip:Show()
        return
    end
    if item.description then
        tip:AddLine(" ")
        tip:AddLine(item.description, 1, 1, 1, true)
    end
    if result.kind == "behind" then
        tip:AddLine(" ")
        tip:AddLine(L["MissionFocus.tales.behind_tip"], 0.8, 0.8, 0.8, true)
    elseif result.kind == "future" then
        tip:AddLine(" ")
        tip:AddLine(L["MissionFocus.tales.future_tip"], 0.8, 0.8, 0.8, true)
    elseif result.kind == "unavailable" then
        tip:AddLine(" ")
        tip:AddLine(L["MissionFocus.tales.unavailable_tip"], 0.8, 0.8, 0.8, true)
    end
    if result.reqs and #result.reqs > 0 then
        tip:AddLine(" ")
        tip:AddLine(L["MissionFocus.tales.requires_header"], 1, 0.82, 0)
        AddRequirementLines(tip, result)
    end
    if result.level == "step" then
        if item.type == "quest" then
            local mapID, _, _, npc = T:GetStart(item)
            if npc or mapID then
                local where = mapID and T.MapName(mapID) or nil
                local text = npc and where and (npc .. " (" .. where .. ")") or npc or where
                tip:AddLine(string.format(L["MissionFocus.questlines.giver"], text), 0.8, 0.8, 0.8, true)
            elseif item.start and item.start.type then
                tip:AddLine(L["MissionFocus.tales.start_" .. item.start.type], 0.8, 0.8, 0.8, true)
            end
            tip:AddLine("#" .. item.questID, 0.5, 0.5, 0.5)
        end
        if result.account then
            tip:AddLine(L["MissionFocus.tales.account_done"], 0.53, 0.8, 1, true)
        end
        local action = T:StepAction(result)
        if action then
            tip:AddLine(L["MissionFocus.tales.click_" .. action], 0, 1, 0)
        end
        if T.MARKABLE[item.type] or (item.type == "questline" and (result.lineTotal or 0) == 0) then
            tip:AddLine(result.done and L["MissionFocus.tales.shift_unmark"] or L["MissionFocus.tales.shift_mark"], 0, 1, 0)
        end
    else
        tip:AddLine(L["MissionFocus.tales.click_open"], 0, 1, 0)
    end
    tip:Show()
end

local function NodeClick(node)
    local result = node.result
    local tale = T:Get(UIT.taleID)
    if not tale then
        return
    end
    if result.level ~= "step" then
        UIT:OpenItem(result.item.id, true)
        return
    end
    local item = result.item
    if IsShiftKeyDown() and (T.MARKABLE[item.type] or (item.type == "questline" and (result.lineTotal or 0) == 0)) then
        T:ToggleMark(tale, item.id)
        return
    end
    T:RunStep(tale, result)
end

local function PrereqTooltip(owner, prereq)
    local tip = Tip()
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    tip:SetText(prereq.name or "?", 0.75, 0.85, 1, 1, true)
    tip:AddLine(prereq.header, 0.8, 0.8, 0.8)
    tip:AddLine(prereq.done and L["MissionFocus.tales.kind_done"] or L["MissionFocus.questlines.prereq_not_done"], 1, 1, 1)
    if prereq.result then
        tip:AddLine(L["MissionFocus.tales.click_open"], 0, 1, 0)
    end
    tip:Show()
end

local GRAPH_HANDLERS = {
    stepTooltip = NodeTooltip,
    stepClick = NodeClick,
    prereqTooltip = PrereqTooltip,
    prereqClick = function(prereq)
        if prereq.result then
            UIT:OpenItem(prereq.result.item.id, true)
        end
    end,
}

function UIT:LayoutView()
    local page = self.page
    local tale = T:Get(self.taleID)
    if not tale then
        self:ShowList()
        return
    end
    local root = T:Evaluate(tale)
    local result = root.byID[self.viewID] or root
    local item = result.item

    -- "Tale: <name>" / "Story: <name>" / "Chapter: <name>": where the player is.
    page.viewName:SetText(string.format(L["MissionFocus.tales.view_title"],
        L["MissionFocus.tales." .. LEVEL_WORDS[result.level]], T:Title(item, result.level)))
    -- Where it is, in small above the title: a story shows its tale; a chapter "Tale - Story"
    -- (or just the tale).
    page.viewContext:SetText(result.parent and T:Path(result.parent, " - ") or "")
    local meta = {}
    if not result.parent then
        if tale.author then
            meta[#meta + 1] = string.format(L["MissionFocus.tales.by_author"], tale.author)
        end
        meta[#meta + 1] = L["MissionFocus.tales.game_" .. (tale.game or "retail")]
        meta[#meta + 1] = FactionText(tale)
        if not T:GameAllowed(tale) then
            meta[#meta + 1] = "|cffff6666" .. L["MissionFocus.tales.not_your_game"] .. "|r"
        end
    end
    local progress = ProgressText(result)
    if progress ~= "" then
        meta[#meta + 1] = progress
    end
    if result.kind and result.level ~= "tale" then
        meta[#meta + 1] = KindWord(result.kind)
    end
    page.viewMeta:SetText(table.concat(meta, "  ·  "))
    -- The whole description, however long: the flow below moves down to make room.
    page.viewDesc:SetText(item.description or "")
    local descHeight = item.description and math.ceil(page.viewDesc:GetStringHeight()) or 0
    page.viewDesc:SetHeight(math.max(descHeight, 1))
    -- Header: context line (top 28 + 12), title, meta, description, progress bar, gap.
    local top = 28 + 12 + 2 + math.ceil(page.viewName:GetStringHeight()) + 4
        + math.ceil(page.viewMeta:GetStringHeight()) + 8 + descHeight + 6 + 4 + 10
    MissionFocus_QuestlineGraph:SetTop(page.graph, math.max(top, HEADER_HEIGHT - 40))
    page.viewBar:SetMinMaxValues(0, math.max(1, result.total or 0))
    page.viewBar:SetValue(result.doneCount or 0)
    page.viewBar:SetStatusBarColor(result.done and 0.4 or 1, result.done and 1 or 0.82, result.done and 0.4 or 0, 0.9)

    local followed = T:GetFollowed()
    page.followButton:SetText((followed and followed.id == tale.id) and L["MissionFocus.tales.unfollow"] or L["MissionFocus.tales.follow"])
    local recordingTale = T:GetRecording()
    page.stopRecordButton:SetShown(recordingTale ~= nil and recordingTale.id == tale.id)

    MissionFocus_QuestlineGraph:Render(page.graph, BuildGraph(tale, result), GRAPH_HANDLERS, self.scrollToNow)
    self.scrollToNow = false
end

---------------------------------------------------------
-- Navigation

function UIT:SetMode(mode)
    self.mode = mode
    local page = self.page
    page.list:SetShown(mode == "list")
    page.view:SetShown(mode == "view")
    page.edit:SetShown(mode == "edit")
    if mode ~= "edit" then
        MissionFocus_TalesEditor:Close()
    end
    self:Refresh()
end

function UIT:ShowList()
    self.taleID, self.viewID, self.history = nil, nil, {}
    self:SetMode("list")
end

function UIT:OpenTale(taleID)
    self.taleID = taleID
    self.viewID = taleID
    self.history = {}
    self.scrollToNow = true
    self:SetMode("view")
end

-- Back from a questline opened from a tale: the Tales tab, on the item it was opened from.
function UIT:ReturnTo(taleID, viewID)
    if self.taleID ~= taleID then
        self.history = {}
    end
    self.taleID, self.viewID = taleID, viewID
    self.mode = "view"
    self.scrollToNow = true
    MissionFocus_Log:Open(nil, "tales")
end

-- push: Back returns to the item shown now.
function UIT:OpenItem(id, push)
    if push and self.viewID then
        table.insert(self.history, self.viewID)
    end
    self.viewID = id
    self.scrollToNow = true
    self:SetMode("view")
end

function UIT:Back()
    local previous = table.remove(self.history)
    if previous then
        self.viewID = previous
        self.scrollToNow = true
        self:SetMode("view")
    else
        self:ShowList()
    end
end

function UIT:Edit()
    if self.taleID then
        self:SetMode("edit")
        MissionFocus_TalesEditor:Open(self.taleID, self.page.editGroup, self.viewID)
    end
end

-- Opens the Center on a tale (from elsewhere).
function UIT:Show(taleID)
    MissionFocus_Log:Open(nil, "tales")
    if taleID then
        self:OpenTale(taleID)
    end
end

---------------------------------------------------------
-- Text window: export (copy) and import (paste)

StaticPopupDialogs["MISSIONFOCUS_TALE_REPLACE"] = {
    text = "%s",
    -- Cancel is button 2: Escape counts as it, and imports nothing.
    button1 = L["MissionFocus.tales.import_replace"],
    button2 = CANCEL or "Cancel",
    button3 = L["MissionFocus.tales.import_keep_both"],
    OnAccept = function(_, data)
        UIT:FinishImport(data, "replace")
    end,
    OnAlt = function(_, data)
        UIT:FinishImport(data, "copy")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["MISSIONFOCUS_CORE_UPDATE"] = {
    text = "%s",
    button1 = L["MissionFocus.tales.core_update"],
    button2 = L["MissionFocus.tales.core_keep"],
    OnAccept = function()
        UIT:FinishCoreInstall(true)
    end,
    OnCancel = function()
        UIT:FinishCoreInstall(false)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Adds the missing core tales; asks before replacing saved ones that have a newer version.
function UIT:InstallCoreTales()
    local _, outdated = T:CoreStatus()
    if #outdated > 0 then
        local names = {}
        for _, tale in ipairs(outdated) do
            names[#names + 1] = tale.title
        end
        StaticPopup_Show("MISSIONFOCUS_CORE_UPDATE", string.format(L["MissionFocus.tales.core_update_ask"],
            table.concat(names, ", ")))
    else
        self:FinishCoreInstall(false)
    end
end

function UIT:FinishCoreInstall(update)
    local added = T:InstallCoreTales(update)
    for _, tale in ipairs(added) do
        MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.core_added"], tale.title))
    end
    if #added == 1 then
        self:OpenTale(added[1].id)
    else
        self:Refresh()
    end
end

StaticPopupDialogs["MISSIONFOCUS_TALE_DELETE"] = {
    text = "%s",
    button1 = DELETE or "Delete",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, data)
        T:Delete(data)
        UIT:ShowList()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UIT:FinishImport(tale, mode)
    tale = T:Save(tale, mode)
    self.textDialog:Hide()
    MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.imported"], tale.title))
    self:OpenTale(tale.id)
end

function UIT:Import(text)
    local dialog = self.textDialog
    local tale, warnings, existing = T:Parse(text)
    if not tale then
        dialog.status:SetText("|cffff6666" .. tostring(warnings) .. "|r")
        return
    end
    for _, warning in ipairs(warnings) do
        MissionFocus_Utils.Print(warning)
    end
    if existing then
        StaticPopup_Show("MISSIONFOCUS_TALE_REPLACE", string.format(L["MissionFocus.tales.import_exists"], existing.title), nil, tale)
    else
        self:FinishImport(tale, "copy")
    end
end

-- mode: "export" (text given, read-only use) or "import".
function UIT:ShowTextDialog(mode, text)
    local dialog = self.textDialog
    dialog.mode = mode
    dialog.title:SetText(mode == "export" and L["MissionFocus.tales.export_title"] or L["MissionFocus.tales.import_title"])
    dialog.help:SetText(mode == "export" and L["MissionFocus.tales.export_help"] or L["MissionFocus.tales.import_help"])
    dialog.status:SetText("")
    -- Edit boxes treat "|" as an escape: double it so the text shows (and copies) as it is.
    dialog.edit:SetText(((text or ""):gsub("|", "||")))
    dialog.actionButton:SetText(mode == "export" and L["MissionFocus.tales.select_all"] or L["MissionFocus.tales.import"])
    dialog:Show()
    dialog.edit:SetFocus()
    if mode == "export" then
        dialog.edit:HighlightText()
    end
end

local function CreateTextDialog(page)
    local dialog = CreateFrame("Frame", nil, page, "BackdropTemplate")
    dialog:SetAllPoints()
    dialog:SetFrameLevel(page:GetFrameLevel() + 30)
    dialog:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    dialog:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    dialog:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    dialog:EnableMouse(true)
    dialog:Hide()

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.title:SetPoint("TOPLEFT", 10, -10)
    dialog.help = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dialog.help:SetPoint("TOPLEFT", dialog.title, "BOTTOMLEFT", 0, -6)
    dialog.help:SetPoint("RIGHT", -10, 0)
    dialog.help:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", nil, dialog, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -52)
    scroll:SetPoint("BOTTOMRIGHT", -30, 40)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(540)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function() dialog:Hide() end)
    scroll:SetScrollChild(edit)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    dialog.edit = edit

    dialog.status = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dialog.status:SetPoint("BOTTOMLEFT", 10, 14)
    dialog.status:SetPoint("RIGHT", -200, 0)
    dialog.status:SetJustifyH("LEFT")

    local close = Button(dialog, L["MissionFocus.tales.close"], 80, function() dialog:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -10, 10)
    dialog.actionButton = Button(dialog, "", 100, function()
        if dialog.mode == "export" then
            edit:SetFocus()
            edit:HighlightText()
        else
            UIT:Import(edit:GetText())
        end
    end)
    dialog.actionButton:SetPoint("RIGHT", close, "LEFT", -6, 0)
    return dialog
end

---------------------------------------------------------
-- "Add to Tale" menu (Quest Log rows, questline view)

-- makeStep() returns the step to add ({ type = "quest", questID = ... }).
function UIT:ShowAddMenu(owner, makeStep)
    local menu = rawget(_G, "MenuUtil")
    if type(menu) ~= "table" or type(menu.CreateContextMenu) ~= "function" then
        MissionFocus_Utils.Print(L["MissionFocus.tales.menu_missing"])
        return
    end
    local function Added(tale, chapter, step)
        MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.added"], T:Title(step, "step"),
            chapter.title or "", tale.title))
    end
    menu.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L["MissionFocus.tales.add_to_tale"])
        for _, tale in ipairs(T:GetTales()) do
            local taleMenu = root:CreateButton(tale.title)
            local chapters = {}
            if tale.stories and #tale.stories > 0 then
                for _, story in ipairs(tale.stories) do
                    for _, chapter in ipairs(story.chapters or {}) do
                        chapters[#chapters + 1] = { chapter = chapter, label = (story.title or "") .. " > " .. (chapter.title or "") }
                    end
                end
            else
                for _, chapter in ipairs(tale.chapters or {}) do
                    chapters[#chapters + 1] = { chapter = chapter, label = chapter.title or "" }
                end
            end
            for _, entry in ipairs(chapters) do
                taleMenu:CreateButton(entry.label, function()
                    local step = T:AddStep(tale, entry.chapter, makeStep())
                    Added(tale, entry.chapter, step)
                end)
            end
            taleMenu:CreateButton("|cff88ccff" .. L["MissionFocus.tales.new_chapter_here"] .. "|r", function()
                local chapter = T:AddChapter(tale)
                local step = T:AddStep(tale, chapter, makeStep())
                Added(tale, chapter, step)
            end)
        end
        root:CreateButton("|cff88ccff" .. L["MissionFocus.tales.new_tale_with"] .. "|r", function()
            local tale = T:CreateTale()
            local chapter = T:AddChapter(tale)
            local step = T:AddStep(tale, chapter, makeStep())
            Added(tale, chapter, step)
        end)
    end)
end

---------------------------------------------------------
-- Page

function UIT:CreatePage(parent, padding, top)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", padding, -top)
    page:SetPoint("BOTTOMRIGHT", -padding, padding)
    page:Hide()
    self.page = page
    local contentWidth = parent:GetWidth() - padding * 2 - 26

    -- List
    -- The list starts below the tab's intro paragraph (the detail views use the full page).
    local list = CreateFrame("Frame", nil, page)
    list:SetPoint("TOPLEFT", 0, -MissionFocus_Log.INTRO_HEIGHT)
    list:SetPoint("BOTTOMRIGHT")
    MissionFocus_Log.CreateIntro(list, L["MissionFocus.center.intro_tales"], list)
    page.list = list

    local newTale = Button(list, L["MissionFocus.tales.new_tale"], 90, function()
        local tale = T:CreateTale()
        UIT:OpenTale(tale.id)
        UIT:Edit()
    end)
    newTale:SetPoint("TOPLEFT", 0, -4)
    local import = Button(list, L["MissionFocus.tales.import"], 80, function()
        UIT:ShowTextDialog("import", "")
    end)
    import:SetPoint("LEFT", newTale, "RIGHT", 6, 0)
    page.coreButton = Button(list, L["MissionFocus.tales.core_tales"], 100, function()
        UIT:InstallCoreTales()
    end)
    page.coreButton:SetPoint("LEFT", import, "RIGHT", 6, 0)
    SetTooltip(page.coreButton, L["MissionFocus.tales.core_tales_tip"])

    local spoilers = CreateFrame("CheckButton", nil, list, "UICheckButtonTemplate")
    spoilers:SetSize(22, 22)
    spoilers:SetPoint("TOPRIGHT", -100, -3)
    spoilers.label = spoilers:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spoilers.label:SetPoint("LEFT", spoilers, "RIGHT", 0, 1)
    spoilers.label:SetText(L["MissionFocus.tales.hide_spoilers"])
    spoilers:SetScript("OnClick", function(self)
        MissionFocus_Options.db.tales_hide_spoilers = self:GetChecked() and true or false
        UIT:Refresh()
    end)
    SetTooltip(spoilers, L["MissionFocus.tales.hide_spoilers_tip"])
    page.spoilerCheck = spoilers

    page.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    page.empty:SetPoint("TOP", list, "TOP", 0, -(TOP_BAR_HEIGHT + 40))
    page.empty:SetWidth(contentWidth - 40)
    page.empty:SetText(L["MissionFocus.tales.empty"])

    local scroll = CreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -TOP_BAR_HEIGHT)
    scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(contentWidth, 10)
    scroll:SetScrollChild(content)
    page.listContent = content

    -- View
    local view = CreateFrame("Frame", nil, page)
    view:SetAllPoints()
    view:Hide()
    page.view = view

    local back = Button(view, L["MissionFocus.questlines.back"], 70, function() UIT:Back() end)
    back:SetPoint("TOPLEFT", 0, -4)
    local export = Button(view, L["MissionFocus.tales.export"], 70, function()
        local tale = T:Get(UIT.taleID)
        if tale then
            UIT:ShowTextDialog("export", T:Export(tale))
        end
    end)
    export:SetPoint("TOPRIGHT", 0, -4)
    local edit = Button(view, L["MissionFocus.tales.edit"], 60, function() UIT:Edit() end)
    edit:SetPoint("RIGHT", export, "LEFT", -4, 0)
    page.followButton = Button(view, "", 80, function()
        local followed = T:GetFollowed()
        T:SetFollow((followed and followed.id == UIT.taleID) and nil or UIT.taleID)
    end)
    page.followButton:SetPoint("RIGHT", edit, "LEFT", -4, 0)
    SetTooltip(page.followButton, L["MissionFocus.tales.follow_tip"])
    page.stopRecordButton = Button(view, L["MissionFocus.tales.stop_recording"], 100, function()
        T:StopRecording()
    end)
    page.stopRecordButton:SetPoint("RIGHT", page.followButton, "LEFT", -4, 0)
    page.stopRecordButton:Hide()

    -- Below the buttons, centered: where it is (small), then the title (large).
    page.viewContext = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.viewContext:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -28)
    page.viewContext:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, -28)
    page.viewContext:SetHeight(12) -- keeps its room when empty (tale page)
    page.viewContext:SetJustifyH("CENTER")
    page.viewContext:SetWordWrap(false)
    page.viewContext:SetTextColor(0.8, 0.8, 0.8, 1)

    page.viewName = view:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    page.viewName:SetPoint("TOPLEFT", page.viewContext, "BOTTOMLEFT", 0, -2)
    page.viewName:SetPoint("RIGHT", view, "RIGHT", 0, 0)
    page.viewName:SetJustifyH("CENTER")
    page.viewName:SetWordWrap(false)

    page.viewMeta = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    page.viewMeta:SetPoint("TOPLEFT", page.viewName, "BOTTOMLEFT", 0, -4)
    page.viewMeta:SetPoint("RIGHT", view, "RIGHT", 0, 0)
    page.viewMeta:SetJustifyH("CENTER")
    page.viewMeta:SetWordWrap(false)

    page.viewDesc = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.viewDesc:SetPoint("TOPLEFT", page.viewMeta, "BOTTOMLEFT", 0, -8)
    page.viewDesc:SetPoint("RIGHT", view, "RIGHT", -4, 0)
    page.viewDesc:SetJustifyH("LEFT")
    page.viewDesc:SetJustifyV("TOP")
    page.viewDesc:SetWordWrap(true)
    page.viewDesc:SetNonSpaceWrap(true)

    page.viewBar = CreateFrame("StatusBar", nil, view)
    page.viewBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    page.viewBar:SetPoint("TOPLEFT", page.viewDesc, "BOTTOMLEFT", 0, -6)
    page.viewBar:SetPoint("RIGHT", view, "RIGHT", -8, 0)
    page.viewBar:SetHeight(4)
    local barBg = page.viewBar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(1, 1, 1, 0.08)

    page.graph = MissionFocus_QuestlineGraph:Create(view, HEADER_HEIGHT)

    -- Edit
    local editFrame = CreateFrame("Frame", nil, page)
    editFrame:SetAllPoints()
    editFrame:Hide()
    page.edit = editFrame
    page.editGroup = MissionFocus_TalesEditor:CreateContainer(editFrame, page)

    self.textDialog = CreateTextDialog(page)

    -- Quest and achievement progress arrives with events.
    local events = CreateFrame("Frame", nil, page)
    for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_DATA_LOAD_RESULT", "ACHIEVEMENT_EARNED",
        "PLAYER_LEVEL_UP", "QUESTLINE_UPDATE" }) do
        pcall(events.RegisterEvent, events, event)
    end
    events:SetScript("OnEvent", function()
        T:Invalidate()
        UIT:RequestRefresh()
    end)
    table.insert(T.listeners, function()
        UIT:RequestRefresh()
    end)
end

function UIT:RequestRefresh()
    if not self.page or not self.page:IsVisible() or self.refreshPending then
        return
    end
    self.refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        UIT.refreshPending = false
        UIT:Refresh()
    end)
end

function UIT:OnShow()
    T:Invalidate()
    self:SetMode(self.mode)
end

function UIT:Refresh()
    local page = self.page
    if not page or not page:IsVisible() then
        return
    end
    if self.mode == "list" then
        self:LayoutList()
    elseif self.mode == "view" then
        self:LayoutView()
    end
end
