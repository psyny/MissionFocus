-- MissionFocus_Modes.lua
-- Focus modes: named sets of focus rules the player switches between (e.g. "Campaign only").
-- A mode picks the category to focus ("all" or one quest category), region filtering, and
-- what each action key does (every gesture defaults to the global action).
--   "all" mode: Category Priority, Next Category When Empty, Nearest Ignores Category and the
--               timed wait apply; a new quest of a higher priority category takes the focus.
--   single-category mode: cycling stays inside the category, a new quest of it takes the focus,
--               and when none is left it waits for the next one with no time limit.
-- Edited in the Focus Modes tab of the MissionFocus Center (right-click the panel).
MissionFocus_Modes = {}

local M = MissionFocus_Modes
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
local AceGUI = LibStub("AceGUI-3.0")

M.APP_NAME = "MissionFocusModes"
M.ALL = "all"
M.BUILTIN_ID = "all"
M.GLOBAL_ACTION = "global"

local GESTURES = { "tap", "hold", "double" }

-- AceGUI's dropdown with its text aligned left (it is right-aligned). A widget type of its own:
-- AceGUI pools widgets per type, shared with every addon, so a changed stock Dropdown would leak.
local LEFT_DROPDOWN = "MissionFocus_LeftDropdown"
AceGUI:RegisterWidgetType(LEFT_DROPDOWN, function()
    local widget = AceGUI.WidgetRegistry["Dropdown"]()
    widget.type = LEFT_DROPDOWN
    widget.text:SetJustifyH("LEFT")
    return widget
end, 1)

-- Field defaults of a mode. Missing fields are filled on load.
local MODE_DEFAULTS = {
    category = M.ALL,
    same_category = false,
    next_category_when_empty = true,
    nearest_ignore_category = false,
    wait_seconds = 120,
    region_filter = "continent", -- none | world | continent | zone
}

-- Global options that became mode settings (moved into the built-in mode on first load).
local LEGACY_KEYS = {
    same_category = "cycle_same_category",
    next_category_when_empty = "cycle_next_category_when_empty",
    nearest_ignore_category = "nearest_ignore_category",
    wait_seconds = "focus_wait_seconds",
    region_filter = "region_filter",
}

local function DB()
    return MissionFocus_Options.db
end

local function FillMode(mode)
    for key, value in pairs(MODE_DEFAULTS) do
        if mode[key] == nil then
            mode[key] = value
        end
    end
    mode.actions = mode.actions or {}
    for slot = 1, MissionFocus_Actions.NUM_SLOTS do
        mode.actions[slot] = mode.actions[slot] or {}
        for _, gesture in ipairs(GESTURES) do
            mode.actions[slot][gesture] = mode.actions[slot][gesture] or M.GLOBAL_ACTION
        end
    end
    return mode
end

---------------------------------------------------------
-- Data (db.profile.focus_modes, kept out of AceDB defaults: it is a user-edited list)

-- Makes sure the profile has its mode list, with the built-in "All" mode in it.
function M:Ensure(db)
    if type(db.focus_modes) ~= "table" then
        local builtin = { id = M.BUILTIN_ID, builtin = true, name = L["MissionFocus.modes.builtin_name"] }
        for field, legacyKey in pairs(LEGACY_KEYS) do
            builtin[field] = db[legacyKey]
        end
        db.focus_modes = { builtin }
        db.focus_mode_active = M.BUILTIN_ID
    end
    for _, legacyKey in pairs(LEGACY_KEYS) do
        db[legacyKey] = nil
    end
    db.switch_to_higher_priority = nil

    local hasBuiltin = false
    for _, mode in ipairs(db.focus_modes) do
        FillMode(mode)
        if mode.id == M.BUILTIN_ID then
            hasBuiltin = true
            mode.builtin = true
            mode.category = M.ALL
        end
    end
    if not hasBuiltin then
        table.insert(db.focus_modes, 1, FillMode({ id = M.BUILTIN_ID, builtin = true, name = L["MissionFocus.modes.builtin_name"] }))
    end
    if not self:GetByID(db.focus_mode_active, db) then
        db.focus_mode_active = M.BUILTIN_ID
    end
end

function M:GetByID(id, db)
    for index, mode in ipairs((db or DB()).focus_modes) do
        if mode.id == id then
            return mode, index
        end
    end
    return nil
end

function M:GetActive()
    local db = DB()
    return self:GetByID(db.focus_mode_active) or db.focus_modes[1]
end

function M:IsActive(id)
    return self:GetActive().id == id
end

function M:SetActive(id)
    if self:GetByID(id) then
        DB().focus_mode_active = id
    end
end

-- The mode before / after the active one, wrapping around.
function M:GetNeighbourID(direction)
    local modes = DB().focus_modes
    local _, index = self:GetByID(self:GetActive().id)
    index = ((index - 1 + direction) % #modes) + 1
    return modes[index].id
end

function M:Add()
    local db = DB()
    db.focus_mode_next_id = (db.focus_mode_next_id or 0) + 1
    local mode = FillMode({
        id = "mode" .. db.focus_mode_next_id,
        name = L["MissionFocus.modes.new_name"] .. " " .. (#db.focus_modes + 1),
        category = MissionFocus_Quests:GetCategoryOrder()[1],
    })
    db.focus_modes[#db.focus_modes + 1] = mode
    return mode
end

function M:Delete(id)
    local mode, index = self:GetByID(id)
    if not mode or mode.builtin then
        return
    end
    table.remove(DB().focus_modes, index)
end

function M:Move(id, delta)
    local modes = DB().focus_modes
    local _, index = self:GetByID(id)
    local target = index and index + delta
    if target and target >= 1 and target <= #modes then
        modes[index], modes[target] = modes[target], modes[index]
    end
end

---------------------------------------------------------
-- Settings of the active mode

-- The category a single-category mode focuses, or nil for "all".
function M:GetFocusCategory()
    local category = self:GetActive().category
    if category == M.ALL then
        return nil
    end
    return category
end

-- The quest toggle settings only apply to "all" modes.
function M:SameCategory()
    local mode = self:GetActive()
    return mode.category == M.ALL and mode.same_category
end

function M:NextCategoryWhenEmpty()
    return self:GetActive().next_category_when_empty
end

function M:NearestIgnoresCategory()
    return self:GetActive().nearest_ignore_category
end

function M:WaitSeconds()
    return self:GetActive().wait_seconds or 0
end

function M:GetRegionFilter()
    return self:GetActive().region_filter
end

function M:SetRegionFilter(level)
    self:GetActive().region_filter = level
end

-- The action a key gesture runs in the active mode ("global" resolves to the Actions tab).
function M:GetAction(slot, gesture)
    local actions = self:GetActive().actions[slot]
    local action = actions and actions[gesture]
    if not action or action == M.GLOBAL_ACTION then
        local global = DB().actions[slot]
        return global and global[gesture]
    end
    return action
end

---------------------------------------------------------
-- Options (shown in the MissionFocus Center, Focus Modes tab)

M.options = {
    type = "group",
    name = L["MissionFocus.modes.title"],
    childGroups = "tree",
    args = {},
}

function M:NotifyChange()
    LibStub("AceConfigRegistry-3.0"):NotifyChange(M.APP_NAME)
end

-- After any edit: re-apply everything; a category change of the active mode moves the focus.
local function OnEdited(id, refocus)
    MissionFocus:GeneralParameterChanges()
    if refocus and M:IsActive(id) then
        MissionFocus:ApplyFocusMode()
    end
    M:NotifyChange()
end

local function GetCategoryValues()
    local values, sorting = { [M.ALL] = L["MissionFocus.modes.category_all"] }, { M.ALL }
    for _, key in ipairs(MissionFocus_Quests:GetCategoryOrder()) do
        values[key] = L["MissionFocus.category." .. key]
        sorting[#sorting + 1] = key
    end
    return values, sorting
end

local function GetRegionValues()
    local values = {}
    for _, level in ipairs(MissionFocus_Location.LEVELS) do
        values[level] = L["MissionFocus.list.region_" .. level]
    end
    return values
end

-- One inline group per action key, a dropdown per gesture with "Same as global" first.
local function ActionArgs(id)
    local args = {
        actions_desc = {
            type = "description",
            name = L["MissionFocus.modes.actions_desc"] .. "\n",
            order = 0,
        },
    }
    for slot = 1, MissionFocus_Actions.NUM_SLOTS do
        local slotArgs = {}
        for i, gesture in ipairs(GESTURES) do
            local includeHoldOnly = gesture == "hold"
            local function Values()
                local values, sorting = MissionFocus_Options.GetActionValues(includeHoldOnly)
                local global = DB().actions[slot][gesture] or "none"
                values[M.GLOBAL_ACTION] = string.format(L["MissionFocus.modes.same_as_global"], L["MissionFocus.action." .. global])
                table.insert(sorting, 1, M.GLOBAL_ACTION)
                return values, sorting
            end
            slotArgs[gesture] = {
                type = "select",
                name = L["MissionFocus.options.gesture_" .. gesture .. ".title"],
                desc = L["MissionFocus.options.gesture_" .. gesture .. ".desc"],
                values = function() return (Values()) end,
                sorting = function() return select(2, Values()) end,
                dialogControl = LEFT_DROPDOWN,
                width = "full",
                order = i,
                get = function()
                    return M:GetByID(id).actions[slot][gesture]
                end,
                set = function(_, value)
                    MissionFocus_Actions:ResetAll()
                    M:GetByID(id).actions[slot][gesture] = value
                    OnEdited(id)
                end,
            }
        end
        args["slot_" .. slot] = {
            type = "group",
            inline = true,
            name = string.format(L["MissionFocus.options.action_slot.title"], slot),
            order = slot,
            args = slotArgs,
        }
    end
    return args
end

local function ModeGroup(id, index)
    local function Mode()
        return M:GetByID(id)
    end
    local function IsAll()
        return Mode().category == M.ALL
    end
    local function Toggle(field, order, disabledWithoutPriority)
        return {
            type = "toggle",
            name = L["MissionFocus.modes." .. field .. ".title"],
            desc = L["MissionFocus.modes." .. field .. ".desc"],
            arg = field,
            order = order,
            width = "full",
            hidden = function() return not IsAll() end,
            disabled = disabledWithoutPriority and function() return not Mode().same_category end or nil,
        }
    end

    return {
        type = "group",
        name = function()
            local mode = Mode()
            if not mode then
                return ""
            end
            if M:IsActive(id) then
                return "|cff66ff66" .. mode.name .. "|r"
            end
            return mode.name
        end,
        order = index,
        get = function(info)
            return Mode()[info.arg]
        end,
        set = function(info, value)
            Mode()[info.arg] = value
            OnEdited(id, info.arg == "category")
        end,
        args = {
            move_up = {
                type = "execute",
                name = L["MissionFocus.modes.move_up"],
                order = 2,
                width = "half",
                disabled = function() return index == 1 end,
                func = function()
                    M:Move(id, -1)
                    M:BuildOptions()
                end,
            },
            move_down = {
                type = "execute",
                name = L["MissionFocus.modes.move_down"],
                order = 3,
                width = "half",
                disabled = function() return index == #DB().focus_modes end,
                func = function()
                    M:Move(id, 1)
                    M:BuildOptions()
                end,
            },
            delete = {
                type = "execute",
                name = L["MissionFocus.modes.delete"],
                order = 4,
                width = "half",
                hidden = function() return Mode().builtin end,
                confirm = true,
                confirmText = L["MissionFocus.modes.delete_confirm"],
                func = function()
                    local wasActive = M:IsActive(id)
                    M:Delete(id)
                    if wasActive then
                        MissionFocus:SetFocusMode(M.BUILTIN_ID)
                    end
                    M:BuildOptions()
                end,
            },
            name = {
                type = "input",
                name = L["MissionFocus.modes.name"],
                arg = "name",
                order = 10,
                width = "full",
            },
            category = {
                type = "select",
                name = L["MissionFocus.modes.category"],
                desc = function()
                    return Mode().builtin and L["MissionFocus.modes.category_builtin"] or L["MissionFocus.modes.category.desc"]
                end,
                values = function() return (GetCategoryValues()) end,
                sorting = function() return select(2, GetCategoryValues()) end,
                arg = "category",
                order = 11,
                width = "full",
                disabled = function() return Mode().builtin end,
            },
            region_filter = {
                type = "select",
                name = L["MissionFocus.modes.region_filter.title"],
                desc = L["MissionFocus.modes.region_filter.desc"],
                values = GetRegionValues,
                sorting = function() return MissionFocus_Location.LEVELS end,
                arg = "region_filter",
                order = 12,
                width = "full",
            },
            header_toggle = {
                type = "header",
                name = L["MissionFocus.options.tab_cycle.title"],
                order = 20,
            },
            single_desc = {
                type = "description",
                name = L["MissionFocus.modes.single_category_desc"],
                order = 21,
                hidden = IsAll,
            },
            all_desc = {
                type = "description",
                name = L["MissionFocus.modes.all_desc"] .. "\n",
                order = 21,
                hidden = function() return not IsAll() end,
            },
            same_category = Toggle("same_category", 22),
            next_category_when_empty = Toggle("next_category_when_empty", 23, true),
            nearest_ignore_category = Toggle("nearest_ignore_category", 24, true),
            wait_seconds = {
                type = "range",
                name = L["MissionFocus.modes.wait_seconds.title"],
                desc = L["MissionFocus.modes.wait_seconds.desc"],
                min = 0, max = 600, step = 5,
                arg = "wait_seconds",
                order = 25,
                width = "full",
                hidden = function() return not IsAll() end,
                disabled = function() return not Mode().same_category end,
            },
            actions = {
                type = "group",
                inline = true,
                name = L["MissionFocus.options.tab_actions.title"],
                order = 30,
                args = ActionArgs(id),
            },
        },
    }
end

-- Rebuilds the mode groups (after adding, deleting, moving, or a profile change). The Center
-- shows its own mode list and opens one group at a time ("mode_<id>").
function M:BuildOptions()
    local args = {}
    for index, mode in ipairs(DB().focus_modes) do
        args["mode_" .. mode.id] = ModeGroup(mode.id, index)
    end
    M.options.args = args
    self:NotifyChange()
end
