-- MissionFocus_UI.lua
-- The panel: one focused quest (title + objectives) and a collapsible tray of the other tracked quests.
-- Plain (non-secure) frames only, so everything here keeps working in combat.
MissionFocus_UI = {}

local UI = MissionFocus_UI
local Q = MissionFocus_Quests
local LSM = LibStub("LibSharedMedia-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")

local PADDING = 8
local HEADER_BUTTON_SIZE = 16
local BUTTON_GAP = 2
local OBJECTIVE_INDENT = 10
local UNTRACKED_ALPHA = 0.55
local DEFAULT_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local LINE_GAP = 2
local SOFT_TITLE_COLOR = { r = 0.45, g = 0.75, b = 1.0, a = 1 } -- secondary focus titles

UI.frame = nil
UI.trayExpanded = false
UI.currentFocusQuestID = nil
UI.currentList = {}

local trayEntries = {}

-- Objective lines and progress bars, pooled per frame that shows objectives:
-- the panel itself and the soft objective block under it (see MissionFocus_Soft.lua).
local mainPool = { lines = {}, bars = {}, count = 0, barCount = 0 }
local softPool = { lines = {}, bars = {}, count = 0, barCount = 0 }
local softHeaders = {}

---------------------------------------------------------
-- Helpers

local function DB()
    return MissionFocus_Options.db
end

local function ApplyFont(fontString, prefix)
    local db = DB()
    local path = LSM:Fetch("font", db[prefix .. "_font_name"]) or STANDARD_TEXT_FONT
    fontString:SetFont(path, db[prefix .. "_font_size"], db[prefix .. "_font_outline"])
    if not fontString:GetFont() then
        fontString:SetFont(STANDARD_TEXT_FONT, db[prefix .. "_font_size"], db[prefix .. "_font_outline"])
    end
end

local function SetColor(fontString, color)
    fontString:SetTextColor(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
end

local function CategoryName(category)
    if category == MissionFocus_Location.ELSEWHERE then
        return MissionFocus_Location:GetElsewhereName()
    end
    return L["MissionFocus.category." .. category] or category
end

local function ShowTooltip(owner, lines)
    MissionFocus_Utils.Tooltip():SetOwner(owner, "ANCHOR_LEFT")
    for i, line in ipairs(lines) do
        if i == 1 then
            MissionFocus_Utils.Tooltip():SetText(line[1], line[2] or 1, line[3] or 0.82, line[4] or 0, 1, true)
        else
            MissionFocus_Utils.Tooltip():AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, true)
        end
    end
    MissionFocus_Utils.Tooltip():Show()
end

local function HideTooltip()
    MissionFocus_Utils.Tooltip():Hide()
end

---------------------------------------------------------
-- Dragging

local function StartDrag()
    if DB().locked or InCombatLockdown() then
        return
    end
    UI.frame:StartMoving()
    UI.isDragging = true
end

local function StopDrag()
    if not UI.isDragging then
        return
    end
    UI.isDragging = false
    UI.frame:StopMovingOrSizing()
    UI.frame:SetUserPlaced(false)
    UI:SavePosition(DB().anchor_point)
    UI:ApplyPosition()
    MissionFocus_ItemButton:ApplyLayout()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("MissionFocus")
end

-- Stores the panel's current screen position, expressed relative to `point`.
function UI:SavePosition(point)
    local frame = self.frame
    local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not left then
        return
    end
    local scale = frame:GetScale()
    local parentWidth, parentHeight = UIParent:GetWidth() / scale, UIParent:GetHeight() / scale

    local x, y
    if point:find("LEFT") then
        x = left
    elseif point:find("RIGHT") then
        x = right - parentWidth
    else
        x = (left + right) / 2 - parentWidth / 2
    end
    if point:find("TOP") then
        y = top - parentHeight
    elseif point:find("BOTTOM") then
        y = bottom
    else
        y = (top + bottom) / 2 - parentHeight / 2
    end

    local db = DB()
    db.anchor_point = point
    db.pos_x = math.floor(x + 0.5)
    db.pos_y = math.floor(y + 0.5)
end

function UI:ChangeAnchorPoint(point)
    if self.frame and self.frame:IsShown() then
        self:SavePosition(point)
    else
        DB().anchor_point = point
    end
end

function UI:ApplyPosition()
    local db = DB()
    local frame = self.frame
    frame:SetScale(db.frame_scale)
    frame:SetFrameStrata(db.strata)
    frame:ClearAllPoints()
    frame:SetPoint(db.anchor_point, UIParent, db.anchor_point, db.pos_x, db.pos_y)
end

---------------------------------------------------------
-- Creation

local function CreateHeaderButton(parent, normal, pushed)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(HEADER_BUTTON_SIZE, HEADER_BUTTON_SIZE)
    button:SetNormalTexture(normal)
    button:SetPushedTexture(pushed or normal)
    button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return button
end

function UI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "MissionFocusFrame", UIParent, "BackdropTemplate")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetSize(DB().frame_width, 40)
    self.frame = frame

    -- Category label
    frame.category = frame:CreateFontString(nil, "OVERLAY")
    frame.category:SetJustifyH("LEFT")

    -- Tray toggle [+], below the next button. The quest count is shown on hover only.
    local trayToggle = CreateFrame("Button", nil, frame)
    trayToggle:SetSize(HEADER_BUTTON_SIZE, HEADER_BUTTON_SIZE)
    trayToggle.icon = trayToggle:CreateTexture(nil, "ARTWORK")
    trayToggle.icon:SetSize(14, 14)
    trayToggle.icon:SetPoint("CENTER")
    trayToggle.trayCount = 0
    trayToggle:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    trayToggle:SetScript("OnClick", function() UI:ToggleTray() end)
    trayToggle:SetScript("OnEnter", function(self)
        ShowTooltip(self, {
            { string.format(L["MissionFocus.ui.tray_count"], self.trayCount) },
            { L["MissionFocus.ui.hint_tray"], 0.7, 0.7, 0.7 },
        })
    end)
    trayToggle:SetScript("OnLeave", HideTooltip)
    frame.trayToggle = trayToggle

    -- Next / previous quest
    local nextButton = CreateHeaderButton(frame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    nextButton:SetScript("OnClick", function(_, mouseButton)
        MissionFocus:CycleFocus(mouseButton == "RightButton" and -1 or 1)
    end)
    nextButton:SetScript("OnEnter", function(self)
        ShowTooltip(self, { { L["MissionFocus.ui.hint_next"] } })
    end)
    nextButton:SetScript("OnLeave", HideTooltip)
    frame.nextButton = nextButton

    -- Title (also the drag handle)
    local title = CreateFrame("Button", nil, frame)
    title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    title:RegisterForDrag("LeftButton")
    title.text = title:CreateFontString(nil, "OVERLAY")
    title.text:SetJustifyH("LEFT")
    title.text:SetJustifyV("TOP")
    title.text:SetWordWrap(true)
    title.text:SetPoint("TOPLEFT")
    title:SetScript("OnDragStart", StartDrag)
    title:SetScript("OnDragStop", StopDrag)
    title:SetScript("OnClick", function(_, mouseButton)
        -- Left: tray. Shift-left: focus mode tray. Right: MissionFocus Center.
        -- Shift-right: Blizzard's quest log.
        if mouseButton ~= "RightButton" then
            if IsShiftKeyDown() then
                UI:ToggleModeTray()
            else
                UI:ToggleTray()
            end
        elseif IsShiftKeyDown() then
            if UI.displayQuestID then
                Q:OpenInQuestLog(UI.displayQuestID)
            end
        else
            MissionFocus_Log:Toggle(UI.currentFocusQuestID)
        end
    end)
    title:SetScript("OnEnter", function(self)
        local soft = UI.softOnPanel
        if soft then
            local lines = {
                { title.text:GetText() },
                { L["MissionFocus.ui.hint_title"], 0.7, 0.7, 0.7 },
            }
            if MissionFocus_Soft:IsShownOnPanel() and UI.currentFocusQuestID then
                lines[#lines + 1] = { L["MissionFocus.ui.hint_soft_back"], 0.7, 0.7, 0.7 }
            end
            local description = soft.description
            if not description and soft.questID then
                description = Q:GetQuestText(soft.questID)
            end
            if description and description ~= "" then
                lines[#lines + 1] = { " " }
                lines[#lines + 1] = { description, 1, 1, 1 }
            end
            ShowTooltip(self, lines)
            return
        end
        if not UI.currentFocusQuestID then
            return
        end
        local lines = {
            { title.text:GetText() },
            { L["MissionFocus.ui.hint_title"], 0.7, 0.7, 0.7 },
            { L["MissionFocus.ui.hint_title_shift_left"], 0.7, 0.7, 0.7 },
            { L["MissionFocus.ui.hint_title_right"], 0.7, 0.7, 0.7 },
            { L["MissionFocus.ui.hint_title_shift"], 0.7, 0.7, 0.7 },
        }
        -- After the commands: the quest description, when the quest log has one.
        local description = Q:GetQuestText(UI.currentFocusQuestID)
        if description and description ~= "" then
            lines[#lines + 1] = { " " }
            lines[#lines + 1] = { description, 1, 1, 1 }
        end
        ShowTooltip(self, lines)
    end)
    title:SetScript("OnLeave", HideTooltip)
    frame.title = title

    -- Tray
    local tray = CreateFrame("Frame", "MissionFocusTray", frame, "BackdropTemplate")
    tray:Hide()
    tray.header = tray:CreateFontString(nil, "OVERLAY")
    tray.header:SetJustifyH("LEFT")
    frame.tray = tray

    -- Secondary focus: soft objectives (scenarios, world quests / bonus objectives in range).
    local soft = CreateFrame("Frame", "MissionFocusSoft", frame, "BackdropTemplate")
    soft:Hide()
    frame.soft = soft

    MissionFocus_Background:Create(frame)
    MissionFocus_Background:Create(tray)
    MissionFocus_Background:Create(soft)
end

---------------------------------------------------------
-- Objective lines and tray entries (pooled)

local function GetObjectiveLine(pool, parent, index)
    local line = pool.lines[index]
    if not line then
        line = parent:CreateFontString(nil, "OVERLAY")
        line:SetJustifyH("LEFT")
        line:SetWordWrap(true)
        pool.lines[index] = line
    end
    return line
end

local function GetProgressBar(pool, parent, index)
    local bar = pool.bars[index]
    if not bar then
        bar = CreateFrame("StatusBar", nil, parent)
        bar:SetMinMaxValues(0, 100)

        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()

        bar.text = bar:CreateFontString(nil, "OVERLAY")
        bar.text:SetPoint("CENTER", 0, 0)

        pool.bars[index] = bar
    end
    return bar
end

local function BeginPool(pool)
    pool.count = 0
    pool.barCount = 0
end

-- Hides the lines and bars not used since BeginPool.
local function FinishPool(pool)
    for i = pool.count + 1, #pool.lines do
        pool.lines[i]:Hide()
    end
    for i = pool.barCount + 1, #pool.bars do
        pool.bars[i]:Hide()
    end
end

-- Lays out objectives from y downwards; returns the new y.
-- Objectives: { text, finished, failed, progress (0-100, drawn as a bar), plain (no dash) }
local function LayoutObjectives(pool, parent, objectives, left, width, y)
    local db = DB()
    for _, objective in ipairs(objectives) do
        pool.count = pool.count + 1
        local line = GetObjectiveLine(pool, parent, pool.count)
        ApplyFont(line, "objective")
        local dash = objective.plain and "" or "- "
        -- With the bar hidden, the percentage is always shown in the text instead.
        local showBar = objective.progress and not db.progress_bar_hidden
        if objective.progress and not showBar then
            line:SetText(string.format("%s%s (%d%%)", dash, objective.text, math.floor(objective.progress)))
        else
            line:SetText(dash .. objective.text)
        end
        if objective.failed then
            line:SetTextColor(1, 0.25, 0.25, 1)
        elseif objective.finished then
            SetColor(line, db.objective_complete_color)
        else
            SetColor(line, db.objective_color)
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", left + OBJECTIVE_INDENT, y)
        line:SetWidth(width - OBJECTIVE_INDENT)
        line:Show()
        y = y - line:GetStringHeight() - LINE_GAP

        -- Progress bar objectives: a bar under the text, as tall as the objective font + 2px.
        if showBar then
            pool.barCount = pool.barCount + 1
            local bar = GetProgressBar(pool, parent, pool.barCount)
            local barHeight = db.objective_font_size + 2
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", left + OBJECTIVE_INDENT, y - 1)
            bar:SetSize(width - OBJECTIVE_INDENT, barHeight)
            bar:SetStatusBarTexture(LSM:Fetch("statusbar", db.progress_bar_texture) or DEFAULT_BAR_TEXTURE)
            bar:SetValue(objective.progress)
            local fill = objective.finished and db.objective_complete_color or db.title_color
            bar:SetStatusBarColor(fill.r, fill.g, fill.b, 1)
            local bg = db.progress_bar_bg_color
            bar.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a)
            if db.progress_bar_show_text then
                ApplyFont(bar.text, "objective")
                SetColor(bar.text, db.objective_color)
                bar.text:SetText(string.format("%d%%", math.floor(objective.progress)))
                bar.text:Show()
            else
                bar.text:Hide()
            end
            bar:Show()
            y = y - barHeight - 2 - LINE_GAP
        end
    end
    return y
end

-- Objectives of a soft objective with its optional step title on top (scenarios).
local function SoftObjectives(details)
    if not details.subtitle then
        return details.objectives
    end
    local objectives = { { text = details.subtitle, plain = true } }
    for _, objective in ipairs(details.objectives) do
        objectives[#objectives + 1] = objective
    end
    return objectives
end

-- Tooltip lines for a list of objectives.
local function AddObjectiveLines(lines, objectives)
    for _, objective in ipairs(objectives) do
        local text = (objective.plain and "" or "- ") .. objective.text
        if objective.progress then
            text = string.format("%s (%d%%)", text, math.floor(objective.progress))
        end
        if objective.finished then
            lines[#lines + 1] = { text, 0.5, 1, 0.5 }
        else
            lines[#lines + 1] = { text, 0.9, 0.9, 0.9 }
        end
    end
end

local function OnTrayEntryClick(entryButton, mouseButton)
    local entry = entryButton.entry
    if not entry then
        return
    end
    -- Focus mode tray: switch, then back to how the tray was before.
    if entry.modeID then
        UI.modeTrayOpen = false
        if mouseButton == "RightButton" then
            UI:Render()
            MissionFocus_Log:Open(nil, "modes")
        else
            MissionFocus:SetFocusMode(entry.modeID)
        end
        return
    end
    -- Soft objective (main mode): put it back on the panel.
    if entry.softKey then
        if mouseButton == "RightButton" then
            if entry.soft.questID then
                Q:OpenInQuestLog(entry.soft.questID)
            end
            return
        end
        UI.trayExpanded = false
        MissionFocus_Soft:Show(entry.softKey)
        UI:Render()
        return
    end
    if mouseButton == "RightButton" then
        Q:OpenInQuestLog(entry.questID)
    elseif IsShiftKeyDown() then
        Q:ToggleTracking(entry)
    else
        UI.trayExpanded = false
        MissionFocus:PickFocus(entry.questID)
    end
end

local function OnTrayEntryEnter(entryButton)
    local entry = entryButton.entry
    if not entry then
        return
    end
    if entry.modeID then
        ShowTooltip(entryButton, {
            { entry.title },
            { entry.categoryText, 0.6, 0.6, 0.6 },
            { " " },
            { L["MissionFocus.ui.hint_mode_entry"], 0.7, 0.7, 0.7 },
            { L["MissionFocus.ui.hint_mode_entry_right"], 0.7, 0.7, 0.7 },
        })
        return
    end
    if entry.softKey then
        local details = entry.soft
        local color = Q.CATEGORY_COLORS[entry.category] or { r = 1, g = 0.82, b = 0 }
        local lines = { { details.title, color.r, color.g, color.b }, { details.categoryText or CategoryName(details.category), 0.6, 0.6, 0.6 } }
        AddObjectiveLines(lines, SoftObjectives(details))
        lines[#lines + 1] = { " " }
        lines[#lines + 1] = { L["MissionFocus.ui.hint_soft_entry"], 0.7, 0.7, 0.7 }
        ShowTooltip(entryButton, lines)
        return
    end
    local details = Q:GetQuestDetails(entry.questID, entry.realCategory or entry.category)
    local color = Q.CATEGORY_COLORS[entry.category] or { r = 1, g = 0.82, b = 0 }
    local categoryText = CategoryName(entry.category)
    if entry.realCategory then
        categoryText = categoryText .. " · " .. CategoryName(entry.realCategory)
    end
    if not entry.isTracked then
        categoryText = categoryText .. " · " .. L["MissionFocus.ui.untracked"]
    end
    local lines = { { details.title, color.r, color.g, color.b }, { categoryText, 0.6, 0.6, 0.6 } }
    AddObjectiveLines(lines, details.objectives)
    lines[#lines + 1] = { " " }
    lines[#lines + 1] = { L["MissionFocus.ui.hint_entry"], 0.7, 0.7, 0.7 }
    lines[#lines + 1] = { L["MissionFocus.ui.hint_entry_right"], 0.7, 0.7, 0.7 }
    lines[#lines + 1] = { L[entry.isTracked and "MissionFocus.ui.hint_entry_shift" or "MissionFocus.ui.hint_entry_shift_track"], 0.7, 0.7, 0.7 }
    ShowTooltip(entryButton, lines)
end

local function GetTrayEntry(index)
    local entryButton = trayEntries[index]
    if not entryButton then
        local tray = UI.frame.tray
        entryButton = CreateFrame("Button", nil, tray)
        entryButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        entryButton:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
        entryButton:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)

        entryButton.stripe = entryButton:CreateTexture(nil, "ARTWORK")
        entryButton.stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        entryButton.stripe:SetWidth(3)
        entryButton.stripe:SetPoint("TOPLEFT", 0, -1)
        entryButton.stripe:SetPoint("BOTTOMLEFT", 0, 1)

        entryButton.progress = entryButton:CreateFontString(nil, "OVERLAY")
        entryButton.progress:SetJustifyH("RIGHT")
        entryButton.progress:SetPoint("RIGHT", -2, 0)

        entryButton.text = entryButton:CreateFontString(nil, "OVERLAY")
        entryButton.text:SetJustifyH("LEFT")
        entryButton.text:SetWordWrap(false)
        entryButton.itemIcon = entryButton:CreateTexture(nil, "ARTWORK")
        entryButton.itemIcon:SetPoint("LEFT", entryButton.stripe, "RIGHT", 4, 0)
        entryButton.itemIcon:Hide()

        entryButton:SetScript("OnClick", OnTrayEntryClick)
        entryButton:SetScript("OnEnter", OnTrayEntryEnter)
        entryButton:SetScript("OnLeave", HideTooltip)
        trayEntries[index] = entryButton
    end
    return entryButton
end

---------------------------------------------------------
-- Rendering

function UI:ToggleTray()
    self.modeTrayOpen = false
    self.trayExpanded = not self.trayExpanded
    self:Render()
end

-- The focus mode tray takes the quest tray's place while open; the quest tray state is kept.
function UI:ToggleModeTray()
    self.modeTrayOpen = not self.modeTrayOpen
    self:Render()
end

-- Tray rows for the focus mode tray.
function UI:GetModeTrayEntries()
    local Modes = MissionFocus_Modes
    local entries = {}
    for _, mode in ipairs(DB().focus_modes) do
        entries[#entries + 1] = {
            modeID = mode.id,
            title = mode.name,
            categoryText = mode.category == Modes.ALL and L["MissionFocus.modes.category_all"] or CategoryName(mode.category),
            isActive = Modes:IsActive(mode.id),
        }
    end
    return entries
end

-- Peeks are counted so two keys peeking at once do not cancel each other.
UI.trayPeekCount = 0
UI.panelPeekCount = 0

function UI:SetTrayPeek(active)
    self.trayPeekCount = math.max(0, self.trayPeekCount + (active and 1 or -1))
    self:Render()
end

function UI:SetPanelPeek(active)
    self.panelPeekCount = math.max(0, self.panelPeekCount + (active and 1 or -1))
    self:Render()
end

function UI:IsTrayOpen()
    return self.trayExpanded or self.trayPeekCount > 0
end

-- Hidden by the "hide quest panel" action, unless something is peeking.
function UI:IsConcealed()
    return DB().panel_hidden and self.panelPeekCount == 0 and self.trayPeekCount == 0
end

function UI:ApplyStyle()
    if not self.frame then
        return
    end
    local frame = self.frame
    ApplyFont(frame.title.text, "title")
    ApplyFont(frame.category, "objective")
    frame.category:SetTextColor(0.6, 0.6, 0.6, 1)
    for _, pool in ipairs({ mainPool, softPool }) do
        for _, line in ipairs(pool.lines) do
            ApplyFont(line, "objective")
        end
    end
    for _, entryButton in ipairs(trayEntries) do
        ApplyFont(entryButton.text, "tray")
        ApplyFont(entryButton.progress, "tray")
    end
    self:ApplyPosition()
end

-- Rebuilds the panel from the WoW API. Safe in combat.
function UI:Render()
    if not self.frame then
        return
    end
    local db = DB()
    local frame = self.frame

    if MissionFocus.hiddenByInstance then
        frame:Hide()
        MissionFocus_ItemButton:SetConcealed(false)
        MissionFocus_ItemButton:SetQuest(nil)
        return
    end

    local list = Q:GetQuests()
    local focusID = Q:GetFocusQuestID(list)
    -- Waiting for a new quest of the category that just became empty: show the wait instead
    -- of whatever Blizzard may have super-tracked meanwhile.
    local hold = MissionFocus:GetFocusHold()
    if hold then
        focusID = nil
    end
    self.currentList = list
    self.currentFocusQuestID = focusID
    if focusID then
        Q.lastFocusQuestID = focusID
    end

    -- Same quests as the tray and cycling; also where nearby quest items are looked for.
    local pool = Q:GetQuestPool(list)
    self:CollectItemCandidates(pool)

    -- Soft objectives: on the panel (main mode, or when there is nothing else to show) and/or
    -- in the block under it (secondary mode).
    local softMain, softBlocks = self:PickSoft(focusID, hold)
    self:PickSoftItems(softMain, softBlocks)

    if not focusID and not hold and not softMain and db.hide_when_empty then
        frame:Hide()
        self:UpdateItemButton(nil)
        return
    end

    -- Immersion: the panel is hidden but the quest stays tracked and focused.
    -- The item button stays active (its key still works); optionally it is made invisible.
    if self:IsConcealed() then
        frame:Hide()
        MissionFocus_ItemButton:SetConcealed(db.hide_item_with_panel)
        self:UpdateItemButton(focusID)
        return
    end
    MissionFocus_ItemButton:SetConcealed(false)
    frame:Show()

    local width = db.frame_width
    frame:SetWidth(width)
    frame:EnableMouse(false)

    -- Right-side button column: next quest on top, tray toggle below it.
    local trayQuests = self:GetTrayQuests(pool, focusID, softMain)
    -- Cycling has somewhere to go: another quest it can reach besides the focused one.
    -- With a soft objective on the panel, cycling first goes back to the focused quest.
    local cyclePool = MissionFocus:GetCyclePool(pool, focusID)
    local canCycle = #cyclePool > 1 or (#cyclePool == 1 and cyclePool[1].questID ~= focusID)
        or (softMain ~= nil and focusID ~= nil)
    local showNext = db.show_next_button and canCycle
    local showTray = db.show_tray_button and #trayQuests > 0
    local buttonCount = (showNext and 1 or 0) + (showTray and 1 or 0)
    local columnWidth = buttonCount > 0 and (HEADER_BUTTON_SIZE + 4) or 0
    local columnHeight = buttonCount * HEADER_BUTTON_SIZE + math.max(0, buttonCount - 1) * BUTTON_GAP

    local titleLeft = PADDING
    local titleWidth = width - titleLeft - PADDING - columnWidth
    local y = -PADDING

    local details = focusID and Q:GetQuestDetails(focusID, self:GetEntryCategory(focusID))
    -- The focused quest's category, even while something else is shown (see OnQuestGone).
    self.currentFocusCategory = details and details.category or nil
    if hold then
        local text
        local remaining = MissionFocus:GetHoldRemaining(hold)
        if remaining then
            remaining = math.ceil(remaining)
            local format = hold.pausedAt and L["MissionFocus.ui.waiting_paused"] or L["MissionFocus.ui.waiting_desc"]
            text = string.format(format, math.floor(remaining / 60), remaining % 60)
        else
            -- Single-category focus mode: no time limit.
            text = string.format(L["MissionFocus.ui.waiting_mode"], MissionFocus_Modes:GetActive().name)
        end
        details = {
            title = string.format(L["MissionFocus.ui.waiting_title"], CategoryName(hold.category)),
            category = hold.category,
            objectives = { { text = text } },
        }
    end
    if softMain then
        details = softMain
    end
    self.softOnPanel = softMain
    -- The quest the title's commands open (a world quest / bonus objective on the panel).
    self.displayQuestID = softMain and softMain.questID or (not softMain and focusID) or nil

    -- Category label
    if details and db.show_category_label then
        frame.category:SetText(details.categoryText or CategoryName(details.category))
        frame.category:ClearAllPoints()
        frame.category:SetPoint("TOPLEFT", titleLeft, y)
        frame.category:SetWidth(titleWidth)
        frame.category:Show()
        y = y - frame.category:GetStringHeight() - LINE_GAP
    else
        frame.category:Hide()
    end

    -- Header row
    local title = frame.title
    title.text:SetWidth(titleWidth)
    if details then
        title.text:SetText(details.title)
        local color = db.title_color
        if db.title_use_category_color then
            color = Q.CATEGORY_COLORS[details.category] or color
        end
        SetColor(title.text, color)
    else
        title.text:SetText(L["MissionFocus.ui.no_quests"])
        SetColor(title.text, db.objective_color)
    end
    local titleHeight = math.max(HEADER_BUTTON_SIZE, title.text:GetStringHeight())
    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", titleLeft, y)
    title:SetSize(titleWidth, titleHeight)

    local columnTop = -PADDING
    local nextButton = frame.nextButton
    nextButton:SetShown(showNext)
    if showNext then
        nextButton:ClearAllPoints()
        nextButton:SetPoint("TOPRIGHT", -PADDING, columnTop)
        columnTop = columnTop - HEADER_BUTTON_SIZE - BUTTON_GAP
    end
    local trayToggle = frame.trayToggle
    trayToggle:SetShown(showTray)
    if showTray then
        trayToggle:ClearAllPoints()
        trayToggle:SetPoint("TOPRIGHT", -PADDING, columnTop)
    end
    y = y - titleHeight - 4
    -- Fading style: the background's core line sits in the gap right under the title.
    local underline = -y - 2

    -- Objectives
    BeginPool(mainPool)
    if details then
        local objectives = details.soft and SoftObjectives(details) or details.objectives
        y = LayoutObjectives(mainPool, frame, objectives, titleLeft, titleWidth, y)
    end
    FinishPool(mainPool)

    local height = math.max(-y - LINE_GAP, columnHeight + PADDING) + PADDING
    frame:SetHeight(height)
    MissionFocus_Background:ApplyPanel(frame, { width = width, height = height, underline = underline })

    -- Soft objective block, then the tray (below it when the tray is below the panel).
    local softFrame = self:RenderSoftBlock(softBlocks)

    -- Tray
    self:RenderTray(trayQuests, softFrame)

    -- The item button sits beside the title, which may have moved (immediate out of combat).
    MissionFocus_ItemButton:ApplyLayout()
    self:UpdateItemButton(focusID)
end

---------------------------------------------------------
-- Soft objectives (see MissionFocus_Soft.lua)

-- Returns the soft objective shown on the panel (or nil) and the list for the block under it.
--   main: the picked objective takes the panel (the others wait in the tray)
--   secondary: all of them go in the block, unless nothing else would be on the panel
function UI:PickSoft(focusID, hold)
    local S = MissionFocus_Soft
    local list = S:GetActive(focusID)
    S.lastActive = list
    local mode = S:GetMode()
    local softMain, blocks = nil, {}
    if mode == "main" then
        softMain = S:PickShown(list)
    elseif mode == "secondary" then
        for _, details in ipairs(list) do
            if not softMain and not focusID and not hold then
                softMain = details
            else
                blocks[#blocks + 1] = details
            end
        end
    end
    S.shownOnPanel = mode == "main" and softMain and softMain.key or nil
    return softMain, blocks
end

local function GetSoftHeader(index)
    local header = softHeaders[index]
    if not header then
        local parent = UI.frame.soft
        header = {
            category = parent:CreateFontString(nil, "OVERLAY"),
            title = parent:CreateFontString(nil, "OVERLAY"),
        }
        header.category:SetJustifyH("LEFT")
        header.title:SetJustifyH("LEFT")
        header.title:SetWordWrap(true)
        softHeaders[index] = header
    end
    return header
end

-- The block under the panel: one small header + objectives per soft objective.
-- Returns the block frame when shown, else nil.
function UI:RenderSoftBlock(blocks)
    local db = DB()
    local softFrame = self.frame.soft
    if #blocks == 0 then
        softFrame:Hide()
        return nil
    end
    local width = db.frame_width
    local left = PADDING
    local textWidth = width - PADDING * 2
    local y = -PADDING
    local underline

    BeginPool(softPool)
    for i, details in ipairs(blocks) do
        local header = GetSoftHeader(i)
        if i > 1 then
            y = y - 4
        end
        if db.show_category_label then
            ApplyFont(header.category, "objective")
            header.category:SetTextColor(0.6, 0.6, 0.6, 1)
            header.category:SetText(details.categoryText or CategoryName(details.category))
            header.category:ClearAllPoints()
            header.category:SetPoint("TOPLEFT", left, y)
            header.category:SetWidth(textWidth)
            header.category:Show()
            y = y - header.category:GetStringHeight() - LINE_GAP
        else
            header.category:Hide()
        end

        -- A little smaller than the focused quest's title: this is the secondary focus.
        local path = LSM:Fetch("font", db.title_font_name) or STANDARD_TEXT_FONT
        local size = math.max(8, db.title_font_size - 2)
        header.title:SetFont(path, size, db.title_font_outline)
        if not header.title:GetFont() then
            header.title:SetFont(STANDARD_TEXT_FONT, size, db.title_font_outline)
        end
        -- Always light blue, so the secondary focus never looks like the focused quest.
        SetColor(header.title, SOFT_TITLE_COLOR)
        header.title:SetText(details.title)
        header.title:ClearAllPoints()
        header.title:SetPoint("TOPLEFT", left, y)
        header.title:SetWidth(textWidth)
        header.title:Show()
        y = y - header.title:GetStringHeight() - 4
        underline = underline or (-y - 2)

        y = LayoutObjectives(softPool, softFrame, SoftObjectives(details), left, textWidth, y)
    end
    FinishPool(softPool)
    for i = #blocks + 1, #softHeaders do
        softHeaders[i].category:Hide()
        softHeaders[i].title:Hide()
    end

    local height = -y - LINE_GAP + PADDING
    softFrame:SetSize(width, height)
    MissionFocus_Background:ApplyPanel(softFrame, { width = width, height = height, underline = underline })
    softFrame:ClearAllPoints()
    softFrame:SetPoint("TOPLEFT", self.frame, "BOTTOMLEFT", 0, -2)
    softFrame:Show()
    return softFrame
end

---------------------------------------------------------
-- Quest item button: the focused quest's item, or else the item of the nearest pool quest on
-- the player's zone within Nearby Item Distance (yards; 0 = off). Using a nearby item focuses
-- its quest (see MissionFocus_ItemButton).

local NEARBY_CHECK_SECONDS = 1

-- Pool quests that have a usable item (from the last render).
function UI:CollectItemCandidates(pool)
    local candidates = {}
    for _, entry in ipairs(pool) do
        if MissionFocus_ItemButton:GetItem(entry.questID) then
            candidates[#candidates + 1] = entry
        end
    end
    self.itemCandidates = candidates
    self:UpdateNearbyTicker()
end

function UI:FindNearbyItemQuest(focusID)
    local distance = DB().item_nearby_distance or 0
    if distance <= 0 or not self.itemCandidates or #self.itemCandidates == 0 then
        return nil
    end
    local LOC = MissionFocus_Location
    local playerZone = LOC:GetRegion(LOC:GetPlayerMap(), "zone")
    if not playerZone then
        return nil
    end
    local limitSq = distance * distance
    local bestID, bestSq
    for _, entry in ipairs(self.itemCandidates) do
        if entry.questID ~= focusID then
            local questZone = LOC:GetRegion(MissionFocus_Utils.Call("GetQuestUiMapID", entry.questID, true), "zone")
            if questZone == playerZone then
                local distanceSq = MissionFocus_Utils.Call("C_QuestLog.GetDistanceSqToQuest", entry.questID)
                if distanceSq and distanceSq <= limitSq and (not bestSq or distanceSq < bestSq) then
                    bestID, bestSq = entry.questID, distanceSq
                end
            end
        end
    end
    return bestID
end

-- Soft objective items: the one on the panel goes first; one in the block under the panel is
-- used when the focused quest has no item. Both count as "this objective's" item (no "!").
function UI:PickSoftItems(softMain, softBlocks)
    local IB = MissionFocus_ItemButton
    self.softItemFirst, self.softItemFallback = nil, nil
    if softMain and softMain.questID and IB:GetItem(softMain.questID) then
        self.softItemFirst = softMain.questID
    end
    for _, details in ipairs(softBlocks) do
        if details.questID and IB:GetItem(details.questID) then
            self.softItemFallback = details.questID
            break
        end
    end
end

function UI:UpdateItemButton(focusID)
    local IB = MissionFocus_ItemButton
    if not DB().show_item_button or MissionFocus.hiddenByInstance then
        IB:SetQuest(nil)
        return
    end
    if self.softItemFirst then
        IB:SetQuest(self.softItemFirst, false)
        return
    end
    if focusID and IB:GetItem(focusID) then
        IB:SetQuest(focusID, false)
        return
    end
    if self.softItemFallback then
        IB:SetQuest(self.softItemFallback, false)
        return
    end
    local nearbyID = self:FindNearbyItemQuest(focusID)
    IB:SetQuest(nearbyID, nearbyID ~= nil)
end

-- While there are item quests to watch, re-check distances as the player moves.
function UI:UpdateNearbyTicker()
    local needed = (DB().item_nearby_distance or 0) > 0 and self.itemCandidates and #self.itemCandidates > 0
    if needed and not self.nearbyTicker then
        self.nearbyTicker = C_Timer.NewTicker(NEARBY_CHECK_SECONDS, function()
            UI:UpdateItemButton(UI.currentFocusQuestID)
        end)
    elseif not needed and self.nearbyTicker then
        self.nearbyTicker:Cancel()
        self.nearbyTicker = nil
    end
end

function UI:GetEntryCategory(questID)
    for _, entry in ipairs(self.currentList) do
        if entry.questID == questID then
            return entry.category
        end
    end
    return nil
end

-- Tray = the quest pool minus the focused quest, capped at Maximum Entries (display only).
-- A single-category focus mode lists the quests of its category first.
-- With a soft objective on the panel (main mode): the focused quest comes first (click it to go
-- back) and the other soft objectives are listed on top. Quests shown as soft objectives are
-- not listed again.
function UI:GetTrayQuests(pool, focusID, softMain)
    local db = DB()
    local softShown = {}
    for _, details in ipairs(MissionFocus_Soft.lastActive or {}) do
        if details.questID then
            softShown[details.questID] = true
        end
    end
    local shown = {}
    if MissionFocus_Soft:GetMode() == "main" then
        for _, details in ipairs(MissionFocus_Soft.lastActive) do
            if details ~= softMain then
                shown[#shown + 1] = { softKey = details.key, soft = details, title = details.title, category = details.category }
            end
        end
    end
    if softMain then
        for _, entry in ipairs(pool) do
            if entry.questID == focusID then
                shown[#shown + 1] = entry
            end
        end
    end
    local focusCategory = MissionFocus_Modes:GetFocusCategory()
    local ordered = pool
    if focusCategory then
        ordered = {}
        for _, entry in ipairs(pool) do
            if (entry.realCategory or entry.category) == focusCategory then
                ordered[#ordered + 1] = entry
            end
        end
        for _, entry in ipairs(pool) do
            if (entry.realCategory or entry.category) ~= focusCategory then
                ordered[#ordered + 1] = entry
            end
        end
    end
    for _, entry in ipairs(ordered) do
        if entry.questID ~= focusID and not softShown[entry.questID] then
            shown[#shown + 1] = entry
            if #shown >= db.tray_max_entries then
                break
            end
        end
    end
    return shown
end

local function FillQuestEntry(entryButton, entry, db)
    -- Untracked quests are dimmed.
    local alpha = entry.isTracked and 1 or UNTRACKED_ALPHA
    entryButton.text:SetAlpha(alpha)
    entryButton.progress:SetAlpha(alpha)
    entryButton.stripe:SetAlpha(alpha)

    local color = Q.CATEGORY_COLORS[entry.category] or { r = 1, g = 0.82, b = 0 }
    entryButton.stripe:SetVertexColor(color.r, color.g, color.b, 1)
    entryButton.text:SetText(entry.title)

    -- Small icon of the quest's item, between the color stripe and the name.
    local item = MissionFocus_ItemButton:GetItem(entry.questID)
    entryButton.text:ClearAllPoints()
    if item then
        local iconSize = db.tray_font_size + 2
        entryButton.itemIcon:SetTexture(item.texture)
        entryButton.itemIcon:SetSize(iconSize, iconSize)
        entryButton.itemIcon:SetAlpha(alpha)
        entryButton.itemIcon:Show()
        entryButton.text:SetPoint("LEFT", entryButton.itemIcon, "RIGHT", 3, 0)
    else
        entryButton.itemIcon:Hide()
        entryButton.text:SetPoint("LEFT", entryButton.stripe, "RIGHT", 5, 0)
    end
    entryButton.text:SetPoint("RIGHT", entryButton.progress, "LEFT", -4, 0)

    if db.tray_show_progress then
        local finished, total, complete = Q:GetProgress(entry.questID)
        if complete then
            entryButton.progress:SetText("|cff66ff66" .. L["MissionFocus.ui.tray_done"] .. "|r")
        elseif total > 0 then
            entryButton.progress:SetText(finished .. "/" .. total)
        else
            entryButton.progress:SetText("")
        end
    else
        entryButton.progress:SetText("")
    end
end

-- Soft objective row (main mode): category color stripe, finished / total on the right.
local function FillSoftEntry(entryButton, entry)
    local details = entry.soft
    entryButton.text:SetAlpha(1)
    entryButton.progress:SetAlpha(1)
    entryButton.stripe:SetAlpha(1)
    local color = Q.CATEGORY_COLORS[entry.category] or { r = 1, g = 0.82, b = 0 }
    entryButton.stripe:SetVertexColor(color.r, color.g, color.b, 1)
    entryButton.text:SetText(entry.title)
    entryButton.itemIcon:Hide()
    entryButton.text:ClearAllPoints()
    entryButton.text:SetPoint("LEFT", entryButton.stripe, "RIGHT", 5, 0)
    entryButton.text:SetPoint("RIGHT", entryButton.progress, "LEFT", -4, 0)
    local finished, total = 0, 0
    for _, objective in ipairs(details.objectives) do
        total = total + 1
        if objective.finished then
            finished = finished + 1
        end
    end
    entryButton.progress:SetText(total > 0 and (finished .. "/" .. total) or "")
end

-- Focus mode row: green stripe for the active mode; the category on the right.
local function FillModeEntry(entryButton, entry)
    entryButton.text:SetAlpha(1)
    entryButton.progress:SetAlpha(entry.isActive and 1 or 0.6)
    entryButton.stripe:SetAlpha(1)
    if entry.isActive then
        entryButton.stripe:SetVertexColor(0.3, 0.9, 0.3, 1)
    else
        entryButton.stripe:SetVertexColor(0.4, 0.4, 0.4, 1)
    end
    entryButton.text:SetText(entry.title)
    entryButton.itemIcon:Hide()
    entryButton.text:ClearAllPoints()
    entryButton.text:SetPoint("LEFT", entryButton.stripe, "RIGHT", 5, 0)
    entryButton.text:SetPoint("RIGHT", entryButton.progress, "LEFT", -4, 0)
    entryButton.progress:SetText(entry.categoryText)
end

function UI:RenderTray(shown, softFrame)
    local db = DB()
    local frame = self.frame
    local tray = frame.tray

    local trayToggle = frame.trayToggle
    trayToggle.trayCount = #shown
    local trayOpen = self:IsTrayOpen()
    if trayOpen and #shown > 0 then
        trayToggle.icon:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
    else
        trayToggle.icon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
    end

    if self.modeTrayOpen then
        shown = self:GetModeTrayEntries()
    elseif not trayOpen or #shown == 0 then
        tray:Hide()
        return
    end

    local width = db.frame_width
    local rowHeight = db.tray_font_size + 8

    -- Small, dim title: which list this is.
    local header = tray.header
    local headerSize = math.max(8, db.tray_font_size - 2)
    header:SetFont(LSM:Fetch("font", db.tray_font_name) or STANDARD_TEXT_FONT, headerSize, db.tray_font_outline)
    if not header:GetFont() then
        header:SetFont(STANDARD_TEXT_FONT, headerSize, db.tray_font_outline)
    end
    header:SetTextColor(0.6, 0.6, 0.6, 0.9)
    header:SetText(self.modeTrayOpen and L["MissionFocus.ui.tray_title_modes"] or L["MissionFocus.ui.tray_title_quests"])
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", tray, "TOPLEFT", PADDING + 3, -5)
    local y = -5 - header:GetStringHeight() - 2

    for i, entry in ipairs(shown) do
        local entryButton = GetTrayEntry(i)
        entryButton.entry = entry
        ApplyFont(entryButton.text, "tray")
        ApplyFont(entryButton.progress, "tray")
        SetColor(entryButton.text, db.tray_color)
        SetColor(entryButton.progress, db.tray_color)
        if entry.modeID then
            FillModeEntry(entryButton, entry)
        elseif entry.softKey then
            FillSoftEntry(entryButton, entry)
        else
            FillQuestEntry(entryButton, entry, db)
        end

        entryButton:ClearAllPoints()
        entryButton:SetPoint("TOPLEFT", tray, "TOPLEFT", PADDING, y)
        entryButton:SetSize(width - PADDING * 2, rowHeight)
        entryButton:Show()
        y = y - rowHeight
    end
    for i = #shown + 1, #trayEntries do
        trayEntries[i]:Hide()
        trayEntries[i].entry = nil
    end

    local height = -y + 4
    tray:SetSize(width, height)
    MissionFocus_Background:ApplyTray(tray, { width = width, height = height })

    local gap = 2
    tray:ClearAllPoints()
    if db.tray_position == "ABOVE" then
        tray:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, gap)
    else
        tray:SetPoint("TOPLEFT", softFrame or frame, "BOTTOMLEFT", 0, -gap)
    end
    tray:Show()
end
