-- MissionFocus_Actions.lua
-- Gesture keybindings: each "MissionFocus Action N" key maps tap / hold / double tap to an action.
--   tap        : fires on release (released before the hold threshold)
--   hold       : fires the moment the hold threshold is reached; "peek" actions end on release
--   double tap : a second tap within the double-tap window. Only when a slot HAS a double-tap
--                action does its single tap wait for that window; otherwise taps fire instantly.
-- Bindings use runOnUp="true", so we receive both "down" and "up" (see Bindings.xml).
MissionFocus_Actions = {}

local A = MissionFocus_Actions

A.NUM_SLOTS = 3

-- Display order of the actions in the options.
A.ACTION_ORDER = {
    "none",
    "next",
    "prev",
    "nearest",
    "next_category",
    "prev_category",
    "next_mode",
    "prev_mode",
    "toggle_tray",
    "toggle_panel",
    "open_log",
    "toggle_mf_log",
    "tale_next",
    "untrack",
    "options",
    "region_none",
    "region_world",
    "region_continent",
    "region_zone",
    "peek_tray",
    "peek_panel",
}

-- Actions that only make sense while a key is held.
A.HOLD_ONLY = {
    peek_tray = true,
    peek_panel = true,
}

local function UntrackFocused()
    local UI = MissionFocus_UI
    for _, entry in ipairs(UI.currentList) do
        if entry.questID == UI.currentFocusQuestID then
            MissionFocus_Quests:Untrack(entry)
            return
        end
    end
end

-- Instant actions are functions; held actions are { start, stop }.
A.HANDLERS = {
    next         = function() MissionFocus:CycleFocus(1) end,
    prev         = function() MissionFocus:CycleFocus(-1) end,
    nearest      = function() MissionFocus:FocusNearest() end,
    next_category = function() MissionFocus:JumpCategory(1) end,
    prev_category = function() MissionFocus:JumpCategory(-1) end,
    next_mode    = function() MissionFocus:CycleFocusMode(1) end,
    prev_mode    = function() MissionFocus:CycleFocusMode(-1) end,
    toggle_tray  = function() MissionFocus_UI:ToggleTray() end,
    toggle_panel = function() MissionFocus:TogglePanelHidden() end,
    open_log     = function()
        if MissionFocus_UI.currentFocusQuestID then
            MissionFocus_Quests:OpenInQuestLog(MissionFocus_UI.currentFocusQuestID)
        end
    end,
    toggle_mf_log = function() MissionFocus_Log:Toggle(MissionFocus_UI.currentFocusQuestID) end,
    tale_next    = function() MissionFocus_Tales:RunNext() end,
    untrack      = UntrackFocused,
    options      = function() MissionFocus:OpenOptions() end,
    region_none      = function() MissionFocus:SetRegionFilter("none") end,
    region_world     = function() MissionFocus:SetRegionFilter("world") end,
    region_continent = function() MissionFocus:SetRegionFilter("continent") end,
    region_zone      = function() MissionFocus:SetRegionFilter("zone") end,
    peek_tray    = {
        start = function() MissionFocus_UI:SetTrayPeek(true) end,
        stop  = function() MissionFocus_UI:SetTrayPeek(false) end,
    },
    peek_panel   = {
        start = function() MissionFocus_UI:SetPanelPeek(true) end,
        stop  = function() MissionFocus_UI:SetPanelPeek(false) end,
    },
}

---------------------------------------------------------
-- Per-slot state

local states = {}

local function GetState(slot)
    local state = states[slot]
    if not state then
        state = {
            isDown = false,
            pressToken = 0,     -- invalidates hold timers of earlier presses
            holdFired = false,
            activeHold = nil,   -- held action to stop on release
            pendingTap = false, -- first tap waiting for a possible double tap
            tapToken = 0,       -- invalidates double-tap timers
        }
        states[slot] = state
    end
    return state
end

-- The slot's actions in the active focus mode (gestures set to "Same as global" use the Actions tab).
local function GetConfig(slot)
    local Modes = MissionFocus_Modes
    return {
        tap = Modes:GetAction(slot, "tap"),
        hold = Modes:GetAction(slot, "hold"),
        double = Modes:GetAction(slot, "double"),
    }
end

local function IsSet(action)
    return action and action ~= "none" and A.HANDLERS[action] ~= nil
end

local function RunInstant(action)
    local handler = A.HANDLERS[action]
    if type(handler) == "function" then
        handler()
    end
end

local function StartHold(state, action)
    local handler = A.HANDLERS[action]
    if type(handler) == "table" then
        handler.start()
        state.activeHold = action
    elseif type(handler) == "function" then
        handler()
    end
end

local function StopHold(state)
    local action = state.activeHold
    state.activeHold = nil
    if action then
        A.HANDLERS[action].stop()
    end
end

-- Clears a slot whose key release was missed (e.g. alt-tab while holding).
local function Reset(state)
    StopHold(state)
    state.isDown = false
    state.holdFired = false
end

---------------------------------------------------------
-- Key handling

local function OnDown(slot)
    local state = GetState(slot)
    local config = GetConfig(slot)
    local db = MissionFocus_Options.db

    if state.isDown then
        Reset(state)
    end
    state.isDown = true
    state.holdFired = false
    state.pressToken = state.pressToken + 1

    if IsSet(config.hold) then
        local token = state.pressToken
        C_Timer.After(db.action_hold_threshold, function()
            if state.isDown and state.pressToken == token then
                state.holdFired = true
                -- A hold cancels a first tap that was waiting for a double tap.
                state.pendingTap = false
                state.tapToken = state.tapToken + 1
                StartHold(state, GetConfig(slot).hold)
            end
        end)
    end
end

local function OnUp(slot)
    local state = GetState(slot)
    if not state.isDown then
        return
    end
    state.isDown = false

    if state.holdFired then
        state.holdFired = false
        StopHold(state)
        return
    end

    local config = GetConfig(slot)
    if not IsSet(config.double) then
        if IsSet(config.tap) then
            RunInstant(config.tap)
        end
        return
    end

    if state.pendingTap then
        state.pendingTap = false
        state.tapToken = state.tapToken + 1
        RunInstant(config.double)
        return
    end

    state.pendingTap = true
    state.tapToken = state.tapToken + 1
    local token = state.tapToken
    C_Timer.After(MissionFocus_Options.db.action_double_window, function()
        if state.pendingTap and state.tapToken == token then
            state.pendingTap = false
            local tap = GetConfig(slot).tap
            if IsSet(tap) then
                RunInstant(tap)
            end
        end
    end)
end

function A:OnKey(slot, keystate)
    if keystate == "up" then
        OnUp(slot)
    else
        OnDown(slot)
    end
end

-- Ends any peek still active (e.g. options changed while a key is held).
function A:ResetAll()
    for _, state in pairs(states) do
        Reset(state)
        state.pendingTap = false
    end
end

---------------------------------------------------------
-- Keybinding entry point (see Bindings.xml)

function MissionFocus_Action(slot, keystate)
    A:OnKey(slot, keystate)
end
