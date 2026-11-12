-- MissionFocus.lua
MissionFocus = LibStub("AceAddon-3.0"):NewAddon("MissionFocus", "AceConsole-3.0", "AceEvent-3.0")

local Utils = MissionFocus_Utils
local Q = MissionFocus_Quests
local UI = MissionFocus_UI
local Modes = MissionFocus_Modes
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")

local addonOptions = nil
local REFRESH_DELAY = 0.05

MissionFocus.hiddenByInstance = false
MissionFocus.focusVersion = 0 -- incremented on every focus change

-- Events that can change what the panel shows. Unknown events (renamed by a patch) are skipped.
local REFRESH_EVENTS = {
    "QUEST_LOG_UPDATE",
    "QUEST_WATCH_LIST_CHANGED",
    "QUEST_POI_UPDATE",
    "SUPER_TRACKING_CHANGED",
    -- Soft objectives (scenarios, delves, world quests / bonus objectives in range)
    "SCENARIO_UPDATE",
    "SCENARIO_CRITERIA_UPDATE",
    "SCENARIO_COMPLETED",
    "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS",
}

---------------------------------------------------------
-- Addon events

function MissionFocus:OnInitialize()
    local options = MissionFocus_Options.options
    local defaults = MissionFocus_Options.defaults

    self.db = LibStub("AceDB-3.0"):New("MissionFocusDB", defaults, true)
    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")
    addonOptions = self.db.profile
    MissionFocus_Options.db = addonOptions
    Modes:Ensure(addonOptions)

    -- Get the option table for profiles
    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    options.args.profiles.order = 100

    -- Register options table
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("MissionFocus", options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("MissionFocus", "MissionFocus")
    -- Focus modes are edited in the MissionFocus Center (see MissionFocus_Log.lua).
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable(Modes.APP_NAME, Modes.options)
    Modes:BuildOptions()

    self:RegisterChatCommand("mf", "SlashCommand")
    self:RegisterChatCommand("missionfocus", "SlashCommand")
end

function MissionFocus:OnEnable()
    MissionFocus_ItemButton:Create()
    UI:Create()

    for _, event in ipairs(REFRESH_EVENTS) do
        self:SafeRegisterEvent(event, "RequestRefresh")
    end
    self:SafeRegisterEvent("UNIT_QUEST_LOG_CHANGED", "OnUnitQuestLogChanged")
    self:SafeRegisterEvent("QUEST_ACCEPTED", "OnQuestAccepted")
    self:SafeRegisterEvent("QUEST_REMOVED", "OnQuestGone")
    self:SafeRegisterEvent("QUEST_TURNED_IN", "OnQuestGone")
    self:SafeRegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
    self:SafeRegisterEvent("QUEST_DETAIL", "OnQuestDetail")
    -- NPC dialogs (pause the focus wait)
    self:SafeRegisterEvent("QUEST_GREETING", "OnQuestDialogOpen")
    self:SafeRegisterEvent("QUEST_PROGRESS", "OnQuestDialogOpen")
    self:SafeRegisterEvent("QUEST_COMPLETE", "OnQuestDialogOpen")
    self:SafeRegisterEvent("QUEST_FINISHED", "OnQuestDialogClosed")
    self:SafeRegisterEvent("GOSSIP_SHOW", "OnGossipShow")
    self:SafeRegisterEvent("GOSSIP_CLOSED", "OnGossipClosed")
    self:SafeRegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "OnInteractionShow")
    self:SafeRegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "OnInteractionHide")
    self:SafeRegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
    self:SafeRegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnded")

    self:GeneralParameterChanges()
end

function MissionFocus:SafeRegisterEvent(event, handler)
    local ok, err = pcall(self.RegisterEvent, self, event, handler)
    if not ok then
        Utils.Debug("Could not register event " .. event .. ": " .. tostring(err))
    end
end

function MissionFocus:OnProfileChanged()
    MissionFocus_Actions:ResetAll()
    self:GeneralParameterChanges()
    Modes:BuildOptions() -- the new profile has its own mode list
    self:ApplyFocusMode()
end

-- Applies every option. Called when any option changes.
function MissionFocus:GeneralParameterChanges()
    addonOptions = self.db.profile
    MissionFocus_Options.db = addonOptions
    Modes:Ensure(addonOptions)

    if not self:IsFocusWaitEnabled() then
        self:ClearFocusHold()
    end
    self:UpdateInstanceState()
    UI:ApplyStyle()
    MissionFocus_ItemButton:ApplyLayout()
    self:Refresh()
    MissionFocus_Log:RequestRefresh() -- frame style may have changed
end

---------------------------------------------------------
-- Refresh (coalesced: many quest events fire in bursts)

function MissionFocus:RequestRefresh()
    if self.refreshPending then
        return
    end
    self.refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        MissionFocus.refreshPending = false
        MissionFocus:Refresh()
        MissionFocus_Log:RequestRefresh()
    end)
end

function MissionFocus:Refresh()
    -- A pending wait may resolve on any refresh (e.g. the awaited quest was just accepted).
    if self.focusHold and self:ResolveFocusHold() then
        return -- focus changed; SetFocus already re-rendered
    end
    UI:Render()
end

function MissionFocus:OnUnitQuestLogChanged(_, unit)
    if unit == "player" then
        self:RequestRefresh()
    end
end

-- Remember where the quest was taken: the API does not keep the accept location.
function MissionFocus:OnQuestAccepted(_, questID)
    MissionFocus_History:OnQuestAccepted(questID)
    if questID then
        MissionFocus_Questlines:OnQuestAccepted(questID)
        -- Let the quest log settle so the new quest has its category and watch state.
        C_Timer.After(0.3, function()
            MissionFocus:OnNewQuest(questID)
            MissionFocus_Tales:OnQuestAccepted(questID) -- the followed tale wins
        end)
    end
    self:RequestRefresh()
end

local function CategoryRanks()
    local rank = {}
    for i, key in ipairs(Q:GetCategoryOrder()) do
        rank[key] = i
    end
    return rank
end

-- A newly accepted quest takes the focus when the focus mode wants it:
--   single-category mode: any new quest of that category
--   "all" mode: a quest whose category comes before the focused quest's category in the cycle
--               priority order (the "Not in <region>" group ranks last)
-- Uses the quest pool, so quests hidden by the tray filters never take the focus.
function MissionFocus:OnNewQuest(questID)
    local list = Q:GetQuests()
    local pool = Q:GetQuestPool(list)
    local newEntry
    for _, entry in ipairs(pool) do
        if entry.questID == questID then
            newEntry = entry
        end
    end
    local currentID = Q:GetFocusQuestID(list)
    if not newEntry or (questID == currentID and not self.focusHold) then
        return
    end
    -- Entering a world quest / bonus objective area "accepts" it: with soft objectives on, it is
    -- shown as one and the focused quest stays (so it is still there when the player leaves).
    if MissionFocus_Soft:IsEnabled() and MissionFocus_Soft:IsActiveTask(questID) then
        return
    end

    local focusCategory = Modes:GetFocusCategory()
    if focusCategory then
        if (newEntry.realCategory or newEntry.category) == focusCategory then
            self:SetFocus(questID)
        end
        return
    end

    local rank = CategoryRanks()
    local currentRank = 99
    if self.focusHold then
        -- Waiting for a quest of an emptied category: that category is the one to beat.
        currentRank = rank[self.focusHold.category] or 99
    else
        for _, entry in ipairs(pool) do
            if entry.questID == currentID then
                currentRank = rank[entry.category] or 99
            end
        end
    end
    if (rank[newEntry.category] or 99) < currentRank then
        self:SetFocus(questID)
    end
end

function MissionFocus:OnQuestGone(event, questID)
    if event == "QUEST_TURNED_IN" and questID then
        MissionFocus_Questlines:OnQuestTurnedIn(questID) -- before the history entry goes
        MissionFocus_Tales:OnQuestTurnedIn(questID)      -- recording uses the history too
    end
    MissionFocus_Location:ForgetOrigin(questID)
    MissionFocus_History:Forget(questID)
    -- QUEST_TURNED_IN and QUEST_REMOVED both fire for a turn-in: handle the focused quest once.
    if questID and questID == UI.currentFocusQuestID and questID ~= self.goneHandledQuestID then
        self.goneHandledQuestID = questID
        local category = UI.currentFocusCategory
        local focusVersion = self.focusVersion
        -- Let the quest log settle before looking at what is left.
        C_Timer.After(0.3, function()
            MissionFocus:OnFocusedQuestGone(questID, category, focusVersion)
        end)
    end
    self:RequestRefresh()
end

---------------------------------------------------------
-- Focus wait: when the focused quest is turned in or abandoned and its category becomes empty,
-- wait for a new quest of that category (quest chains usually hand out the next one within a
-- minute).
--   "all" mode with Category Priority: wait a while, then move to the next category.
--   single-category mode: wait for the mode's category with no time limit.
-- Any explicit focus action (tray, cycling, actions) ends the wait. Quests of other categories
-- do not reset or end it.

function MissionFocus:IsFocusWaitEnabled()
    return Modes:GetFocusCategory() ~= nil or Modes:SameCategory()
end

function MissionFocus:GetFocusHold()
    return self.focusHold
end

local function FirstOfCategory(pool, category, excludeID)
    for _, entry in ipairs(pool) do
        if (entry.realCategory or entry.category) == category and entry.questID ~= excludeID then
            return entry.questID
        end
    end
    return nil
end

function MissionFocus:ClearFocusHold()
    self.focusHold = nil
    if self.focusHoldTicker then
        self.focusHoldTicker:Cancel()
        self.focusHoldTicker = nil
    end
end

function MissionFocus:OnFocusedQuestGone(questID, category, focusVersion)
    if not self:IsFocusWaitEnabled() or not category then
        return
    end
    -- The user picked a quest in the meantime: their choice wins.
    if focusVersion ~= self.focusVersion then
        return
    end

    -- Single-category mode: back to the mode's category, whatever the gone quest was.
    if Modes:GetFocusCategory() then
        self:ApplyFocusMode()
        return
    end

    local pool = Q:GetQuestPool(Q:GetQuests())
    local same = FirstOfCategory(pool, category, questID)
    if same then
        self:SetFocus(same)
        return
    end

    local seconds = Modes:WaitSeconds()
    if seconds <= 0 then
        self:MoveToNextCategory(category)
        return
    end
    self:StartFocusHold(category, seconds)
end

-- Waits for a quest of `category`; seconds = nil waits with no time limit.
function MissionFocus:StartFocusHold(category, seconds)
    self:ClearFocusHold()
    self.focusHold = { category = category, expires = seconds and (GetTime() + seconds) or nil }
    self:UpdateHoldPause() -- e.g. the next quest's dialog is already open
    if seconds then
        self.focusHoldTicker = C_Timer.NewTicker(1, function()
            MissionFocus:Refresh()
        end)
    end
    self:Refresh()
end

-- Returns true when the wait ended with a focus change.
function MissionFocus:ResolveFocusHold()
    local hold = self.focusHold
    if not self:IsFocusWaitEnabled() then
        self:ClearFocusHold()
        return false
    end
    local pool = Q:GetQuestPool(Q:GetQuests())
    local same = FirstOfCategory(pool, hold.category)
    if same then
        self:SetFocus(same)
        return true
    end
    if not hold.expires then
        return false
    end
    self:UpdateHoldPause()
    if not hold.pausedAt and GetTime() >= hold.expires then
        return self:MoveToNextCategory(hold.category)
    end
    return false
end

---------------------------------------------------------
-- NPC dialogs pause the focus wait: the player is reading or choosing a quest.
-- Tracked by events (not frame visibility) so it also works with addons that replace
-- Blizzard's quest frame.

-- Safety: a missed "closed" event cannot pause the wait forever. The longest pause is this
-- many times the wait option (Wait for Next Quest of Category).
local MAX_PAUSE_FACTOR = 10

MissionFocus.npcDialogs = {}

function MissionFocus:SetNpcDialog(key, open)
    self.npcDialogs[key] = open and true or nil
    self:UpdateHoldPause()
end

function MissionFocus:IsNpcDialogOpen()
    return next(self.npcDialogs) ~= nil
end

function MissionFocus:UpdateHoldPause()
    local hold = self.focusHold
    if not hold or not hold.expires then
        return
    end
    local maxPause = Modes:WaitSeconds() * MAX_PAUSE_FACTOR
    if hold.pausedAt and GetTime() - hold.pausedAt > maxPause then
        wipe(self.npcDialogs)
    end
    local paused = self:IsNpcDialogOpen()
    if paused and not hold.pausedAt then
        hold.pausedAt = GetTime()
    elseif not paused and hold.pausedAt then
        hold.expires = hold.expires + (GetTime() - hold.pausedAt)
        hold.pausedAt = nil
    end
end

-- Seconds left on the wait (frozen while paused), nil when it has no time limit.
function MissionFocus:GetHoldRemaining(hold)
    if not hold.expires then
        return nil
    end
    return math.max(0, hold.expires - (hold.pausedAt or GetTime()))
end

function MissionFocus:OnQuestDialogOpen()
    self:SetNpcDialog("quest", true)
end

function MissionFocus:OnQuestDialogClosed()
    self:SetNpcDialog("quest", false)
end

function MissionFocus:OnGossipShow()
    self:SetNpcDialog("gossip", true)
end

function MissionFocus:OnGossipClosed()
    self:SetNpcDialog("gossip", false)
end

function MissionFocus:OnInteractionShow(_, interactionType)
    self:SetNpcDialog("interaction:" .. tostring(interactionType), true)
end

function MissionFocus:OnInteractionHide(_, interactionType)
    self:SetNpcDialog("interaction:" .. tostring(interactionType), false)
end

-- Super-track the first quest of the category after `category` (cycle priority order),
-- skipping the "Not in <region>" group; wraps to the top when nothing comes after it.
function MissionFocus:MoveToNextCategory(category)
    self:ClearFocusHold()
    local pool = self:ApplyElsewhereCycleRule(Q:GetQuestPool(Q:GetQuests()), nil)
    local rank = CategoryRanks()
    local fromRank = rank[category] or 0
    local target
    for _, entry in ipairs(pool) do
        if (rank[entry.category] or 99) > fromRank then
            target = entry.questID
            break
        end
    end
    target = target or (pool[1] and pool[1].questID)
    if target then
        self:SetFocus(target)
        return true
    end
    UI:Render()
    return false
end

function MissionFocus:OnCombatEnded()
    Utils.FlushCombatQueue()
    self:RequestRefresh()
end

---------------------------------------------------------
-- Instances: optionally hand over to the Blizzard tracker

function MissionFocus:UpdateInstanceState()
    local inInstance, instanceType = IsInInstance()
    local useBlizzard = addonOptions.blizzard_in_instances and inInstance and instanceType ~= "none"
    self.hiddenByInstance = useBlizzard and true or false
    MissionFocus_BlizzardTracker:SetHidden(addonOptions.hide_blizzard_tracker and not self.hiddenByInstance)
end

-- The quest log can be empty for a moment after login: sync the history once it has entries.
function MissionFocus:OnEnteringWorld()
    -- Dialogs never survive a loading screen; their "closed" events may have been missed.
    wipe(self.npcDialogs)
    self:UpdateHoldPause()
    self:OnZoneChanged()
    local attempts = 0
    local function TrySync()
        attempts = attempts + 1
        if (Utils.Call("C_QuestLog.GetNumQuestLogEntries") or 0) > 0 or attempts >= 10 then
            MissionFocus_History:Sync()
            MissionFocus_Questlines:Sync()
            MissionFocus_Log:RequestRefresh()
        else
            C_Timer.After(2, TrySync)
        end
    end
    C_Timer.After(2, TrySync)
end

function MissionFocus:OnQuestDetail()
    MissionFocus_History:OnQuestDetail()
    self:OnQuestDialogOpen()
end

function MissionFocus:OnZoneChanged()
    self:UpdateInstanceState()
    self:RequestRefresh()
end

---------------------------------------------------------
-- Focus actions

-- Every focus change goes through here (tray, cycling, actions, and the focus wait itself),
-- so any explicit choice also ends a pending focus wait.
function MissionFocus:SetFocus(questID)
    self.focusVersion = self.focusVersion + 1
    self:ClearFocusHold()
    Q:Focus(questID)
    self:Refresh()
    MissionFocus_Log:RequestRefresh()
end

-- A focus picked by the player (tray, quest log, questlines, item button): also takes the
-- panel back from a soft objective shown in main mode.
function MissionFocus:PickFocus(questID)
    MissionFocus_Soft:DismissAll()
    self:SetFocus(questID)
end

-- Main mode: a soft objective is on the panel. Cycling first goes back to the focused quest.
-- Returns true when that was all there was to do.
function MissionFocus:LeaveSoftObjective(currentID)
    if not MissionFocus_Soft:IsShownOnPanel() then
        return false
    end
    MissionFocus_Soft:DismissAll()
    if currentID and not self.focusHold then
        self:Refresh()
        return true
    end
    return false
end

function MissionFocus:CycleFocus(direction)
    local list = Q:GetQuests()
    local currentID = Q:GetFocusQuestID(list)
    if self:LeaveSoftObjective(currentID) then
        return
    end
    -- Same pool as the tray. A focused quest outside it (e.g. super-tracked from the map
    -- in a hidden category) is simply not found, so cycling jumps into the pool.
    local pool = self:GetCyclePool(Q:GetQuestPool(list), currentID)
    local target = Q:GetCycleTarget(pool, currentID, direction, Modes:SameCategory(), Modes:NextCategoryWhenEmpty())
    if target and target ~= currentID then
        self:SetFocus(target)
    end
end

-- Jump to the first quest of the next / previous category, e.g. to leave a category while
-- Same Category Priority keeps cycling inside it. Uses the quest pool (all filters apply);
-- the "Not in <region>" group counts as the last category, so this is also the way into it.
function MissionFocus:JumpCategory(direction)
    local list = Q:GetQuests()
    local currentID = Q:GetFocusQuestID(list)
    if self:LeaveSoftObjective(currentID) then
        return
    end
    local target = Q:GetCategoryJumpTarget(Q:GetQuestPool(list), currentID, direction)
    if target and target ~= currentID then
        self:SetFocus(target)
    end
end

-- Focus the nearest quest of the cycling pool. With Category Priority (unless the
-- "Nearest Quest Ignores Category" option is on), only the focused quest's category is
-- searched; if none of it has a known distance, Next Category When Empty widens the search
-- to the whole pool. A single-category mode's cycling pool is already that category.
function MissionFocus:FocusNearest()
    local list = Q:GetQuests()
    local currentID = Q:GetFocusQuestID(list)
    -- Nearest is a pick of its own: leave the soft objective, then look for the nearest quest.
    MissionFocus_Soft:DismissAll()
    local pool = self:GetCyclePool(Q:GetQuestPool(list), currentID)

    local currentCategory
    for _, entry in ipairs(pool) do
        if entry.questID == currentID then
            currentCategory = entry.category
        end
    end

    local target
    local sameCategoryOnly = Modes:SameCategory() and not Modes:NearestIgnoresCategory()
    if sameCategoryOnly and currentCategory then
        local same = {}
        for _, entry in ipairs(pool) do
            if entry.category == currentCategory then
                same[#same + 1] = entry
            end
        end
        target = Q:FindNearest(same)
        if not target and Modes:NextCategoryWhenEmpty() then
            target = Q:FindNearest(pool)
        end
    else
        target = Q:FindNearest(pool)
    end

    if target and target ~= currentID then
        self:SetFocus(target)
    else
        self:Refresh()
    end
end

-- Quests that cycling, "nearest" and the next button move between.
--   "all" mode: the pool minus the "Not in <region>" group (see ApplyElsewhereCycleRule).
--   single-category mode: the quests of that category in the player's region; those outside it
--   too when there are no others, or when the focused quest is one of them.
function MissionFocus:GetCyclePool(pool, currentID)
    local focusCategory = Modes:GetFocusCategory()
    if not focusCategory then
        return self:ApplyElsewhereCycleRule(pool, currentID)
    end
    local ELSEWHERE = MissionFocus_Location.ELSEWHERE
    local all, nearby, focusedElsewhere = {}, {}, false
    for _, entry in ipairs(pool) do
        if (entry.realCategory or entry.category) == focusCategory then
            all[#all + 1] = entry
            if entry.category ~= ELSEWHERE then
                nearby[#nearby + 1] = entry
            elseif entry.questID == currentID then
                focusedElsewhere = true
            end
        end
    end
    if #nearby == 0 or focusedElsewhere then
        return all
    end
    return nearby
end

-- Cycling skips the "Not in Continent" group. The exception: when the focused quest is in that
-- group and cycling is limited to the same category, we cycle through the group like any other.
function MissionFocus:ApplyElsewhereCycleRule(pool, currentID)
    local ELSEWHERE = MissionFocus_Location.ELSEWHERE
    for _, entry in ipairs(pool) do
        if entry.questID == currentID and entry.category == ELSEWHERE and Modes:SameCategory() then
            return pool
        end
    end
    local nearby = {}
    for _, entry in ipairs(pool) do
        if entry.category ~= ELSEWHERE then
            nearby[#nearby + 1] = entry
        end
    end
    return nearby
end

function MissionFocus:ResetPosition()
    local defaults = MissionFocus_Options.defaults.profile
    addonOptions.anchor_point = defaults.anchor_point
    addonOptions.pos_x = defaults.pos_x
    addonOptions.pos_y = defaults.pos_y
    self:GeneralParameterChanges()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("MissionFocus")
    Utils.Print(L["MissionFocus.ui.position_reset"])
end

-- The standalone AceConfig window does not depend on Blizzard's Settings API, which keeps changing.
-- The options are also listed under Options > AddOns.
function MissionFocus:OpenOptions()
    LibStub("AceConfigDialog-3.0"):Open("MissionFocus")
end

-- Region filtering level of the active focus mode: none | world | continent | zone.
function MissionFocus:SetRegionFilter(level)
    Modes:SetRegionFilter(level)
    self:Refresh()
    Modes:NotifyChange()
    Utils.Print(string.format(L["MissionFocus.ui.region_filter_set"], L["MissionFocus.list.region_" .. level]))
end

---------------------------------------------------------
-- Focus modes (see MissionFocus_Modes.lua)

-- Single-category mode: focus the focused quest if it is of the mode's category, else the first
-- quest of it, or wait for one. "all" modes leave the focus alone.
function MissionFocus:ApplyFocusMode()
    local focusCategory = Modes:GetFocusCategory()
    if not focusCategory then
        self:ClearFocusHold()
        self:Refresh()
        return
    end
    local list = Q:GetQuests()
    local currentID = Q:GetFocusQuestID(list)
    local pool = self:GetCyclePool(Q:GetQuestPool(list), currentID)
    local target = pool[1] and pool[1].questID
    for _, entry in ipairs(pool) do
        if entry.questID == currentID then
            target = currentID
        end
    end
    if target then
        self:SetFocus(target)
    else
        self:StartFocusHold(focusCategory, nil)
    end
end

function MissionFocus:SetFocusMode(id)
    Modes:SetActive(id)
    MissionFocus_Actions:ResetAll() -- the keys may do something else now
    self:ApplyFocusMode()
    Modes:NotifyChange()
    UIErrorsFrame:AddMessage(string.format(L["MissionFocus.ui.focus_mode_set"], Modes:GetActive().name), 1, 0.82, 0)
end

function MissionFocus:CycleFocusMode(direction)
    self:SetFocusMode(Modes:GetNeighbourID(direction))
end

-- Immersion mode: hide the panel; the quest stays tracked and focused.
function MissionFocus:TogglePanelHidden()
    addonOptions.panel_hidden = not addonOptions.panel_hidden
    self:Refresh()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("MissionFocus")
end

---------------------------------------------------------
-- Slash commands: /mf next | prev | nextmode | prevmode | modes | tray | panel | tale | tales | config | reset
-- Keybindings are handled in MissionFocus_Actions.lua.

function MissionFocus:SlashCommand(input)
    local command = strtrim(string.lower(input or ""))
    if command == "next" then
        self:CycleFocus(1)
    elseif command == "prev" then
        self:CycleFocus(-1)
    elseif command == "nearest" then
        self:FocusNearest()
    elseif command == "nextcat" then
        self:JumpCategory(1)
    elseif command == "prevcat" then
        self:JumpCategory(-1)
    elseif command == "nextmode" then
        self:CycleFocusMode(1)
    elseif command == "prevmode" then
        self:CycleFocusMode(-1)
    elseif command == "modes" then
        MissionFocus_Log:Open(nil, "modes")
    elseif command == "tray" then
        UI:ToggleTray()
    elseif command == "panel" then
        self:TogglePanelHidden()
    elseif command == "reset" then
        self:ResetPosition()
    elseif command == "log" then
        MissionFocus_Log:Toggle(UI.currentFocusQuestID)
    elseif command == "where" then
        MissionFocus_Location:PrintReport()
    elseif command == "tale" then
        MissionFocus_Tales:RunNext()
    elseif command == "tales" then
        MissionFocus_Log:Open(nil, "tales")
    else
        self:OpenOptions()
    end
end
