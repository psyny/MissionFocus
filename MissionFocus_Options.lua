-- MissionFocus_Options.lua
MissionFocus_Options = {}

---------------------------------------------------------
-- Our db upvalue and db defaults

MissionFocus_Options.db = nil
MissionFocus_Options.options = nil
MissionFocus_Options.defaults = nil

---------------------------------------------------------
-- Quest categories. The list order is the default cycle priority.

MissionFocus_Options.CATEGORIES = {
    "campaign",
    "legendary",
    "important",
    "meta",
    "questline",
    "side",
    "group",
    "calling",
    "recurring",
    "event",
    "world",
    "bonus",
}

local function DefaultCategoryOrder()
    local order = {}
    for i, key in ipairs(MissionFocus_Options.CATEGORIES) do
        order[i] = key
    end
    return order
end

local function DefaultTrayCategories()
    local shown = { elsewhere = true }
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        shown[key] = true
    end
    return shown
end

-- Untracked quests of the quest log: only campaign quests by default.
local function DefaultTrayCategoriesUntracked()
    local shown = { elsewhere = false }
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        shown[key] = key == "campaign"
    end
    return shown
end

---------------------------------------------------------
-- Our options default values

MissionFocus_Options.defaults = {
    profile = {
        -- General
        hide_blizzard_tracker               = true,
        blizzard_in_instances               = true,
        hide_when_empty                     = true,
        soft_objectives                     = "secondary", -- off | main | secondary (MissionFocus_Soft.lua)
        show_category_label                 = true,
        show_item_button                    = true,
        show_next_button                    = true,
        show_tray_button                    = true,
        panel_hidden                        = false,
        hide_item_with_panel                = true,
        btwquests_enabled                   = true,  -- use BtWQuests data when it is installed
        tales_hide_spoilers                 = false, -- Adventurer's Tales: hide names not reached yet
        debug                               = false,

        -- Actions (gesture keybindings)
        action_hold_threshold               = 0.25,
        action_double_window                = 0.30,
        actions = {
            [1] = { tap = "next",        hold = "toggle_panel", double = "none" },
            [2] = { tap = "prev",        hold = "peek_tray",    double = "none" },
            [3] = { tap = "toggle_tray", hold = "peek_panel",   double = "none" },
        },

        -- Quest Toggle
        category_order                      = DefaultCategoryOrder(),
        -- focus_modes / focus_mode_active: created by MissionFocus_Modes:Ensure (kept out of
        -- AceDB defaults on purpose, AceDB would merge default modes back into the user's list)

        -- Quest Tray
        tray_categories                     = DefaultTrayCategories(),          -- tracked quests
        tray_categories_untracked           = DefaultTrayCategoriesUntracked(), -- untracked quest log quests
        tray_max_entries                    = 15,
        tray_position                       = "BELOW",
        tray_show_progress                  = true,

        -- Appearance: title
        title_font_name                     = "Friz Quadrata TT",
        title_font_size                     = 14,
        title_font_outline                  = "OUTLINE",
        title_color                         = { r = 1.0, g = 0.82, b = 0.0, a = 1 },
        title_use_category_color            = false,

        -- Appearance: objectives
        objective_font_name                 = "Friz Quadrata TT",
        objective_font_size                 = 12,
        objective_font_outline              = "OUTLINE",
        objective_color                     = { r = 0.9, g = 0.9, b = 0.9, a = 1 },
        objective_complete_color            = { r = 0.4, g = 1.0, b = 0.4, a = 1 },

        -- Appearance: progress bar (height = objective font size + 2; fill = title / completed color)
        progress_bar_texture                = "Blizzard",
        progress_bar_bg_color               = { r = 0, g = 0, b = 0, a = 0.5 },
        progress_bar_show_text              = true,
        progress_bar_hidden                 = false, -- when hidden, the percentage goes in the text

        -- Appearance: tray
        tray_font_name                      = "Friz Quadrata TT",
        tray_font_size                      = 12,
        tray_font_outline                   = "OUTLINE",
        tray_color                          = { r = 0.85, g = 0.85, b = 0.85, a = 1 },

        -- Appearance: frame
        bg_color                            = { r = 0, g = 0, b = 0, a = 0.45 },
        frame_style                         = "blizzard",
        border_size                         = 12,
        border_color                        = { r = 0.6, g = 0.6, b = 0.6, a = 0.8 },
        frame_width                         = 260,
        frame_scale                         = 1.0,

        -- Position
        locked                              = false,
        anchor_point                        = "TOPRIGHT",
        pos_x                               = -90,
        pos_y                               = -260,
        strata                              = "MEDIUM",
        item_side                           = "LEFT",
        item_size                           = 34,
        item_nearby_distance                = 200, -- yards; 0 = only the focused quest's item

        -- Quest log window: saved filters and position
        log_filters = {
            search     = "",
            sort       = "category",  -- category | newest | oldest | proximity | name
            near       = "any",       -- any | zone | continent | world (relative to the player)
            zone       = 0,           -- 0 = all zones, else a zone mapID
            tracking   = "all",       -- all | tracked | untracked
            categories = DefaultTrayCategories(),
        },
        log_point = nil,

        -- Questlines tab: saved filters
        questline_filters = {
            category  = "all",    -- all | campaign | side
            sort      = "recent", -- recent | nearby | category | name
            completed = false,    -- also list questlines with every step done
        },
    },
    char = {
        -- Recent quests and their questlines (see MissionFocus_Questlines.lua)
        questlines = {
            quests = {},
            lines = {},
        },
        -- Older accept-location data (questID -> mapID), kept as a fallback.
        quest_origins = {},
        -- questID -> { time, mapID, x, y, giver, seenOnly } (see MissionFocus_History.lua)
        quest_history = {},
        -- Adventurer's Tales progress: marks[taleID][itemID], follow = taleID, record = {...}
        tales = { marks = {} },
    },
    global = {
        -- Adventurer's Tales, in the tale file format (see MissionFocus_Tales.lua)
        tales = {},
    },
}

---------------------------------------------------------
-- Lists

local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus", false)
local LSM = LibStub("LibSharedMedia-3.0")
local optionWidth = 2.0

local function GetCategoryOptions()
    local values = {}
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        values[key] = L["MissionFocus.category." .. key]
    end
    return values
end

local function GetOutlineOptions()
    return {
        [""] = L["MissionFocus.list.outline_none"],
        ["OUTLINE"] = L["MissionFocus.list.outline_outline"],
        ["THICKOUTLINE"] = L["MissionFocus.list.outline_thick"],
    }
end

local function GetAnchorOptions()
    return {
        ["TOPLEFT"] = "Top Left",
        ["TOP"] = "Top",
        ["TOPRIGHT"] = "Top Right",
        ["LEFT"] = "Left",
        ["CENTER"] = "Center",
        ["RIGHT"] = "Right",
        ["BOTTOMLEFT"] = "Bottom Left",
        ["BOTTOM"] = "Bottom",
        ["BOTTOMRIGHT"] = "Bottom Right",
    }
end

local function GetFrameStyleOptions()
    return {
        ["blizzard"] = L["MissionFocus.list.style_blizzard"],
        ["border"] = L["MissionFocus.list.style_border"],
        ["fading"] = L["MissionFocus.list.style_fading"],
    }
end

-- Action lists for the Actions tab. Hold-only actions (peeks) are offered only for hold.
local function GetActionValues(includeHoldOnly)
    local values, sorting = {}, {}
    for _, key in ipairs(MissionFocus_Actions.ACTION_ORDER) do
        if includeHoldOnly or not MissionFocus_Actions.HOLD_ONLY[key] then
            values[key] = L["MissionFocus.action." .. key]
            sorting[#sorting + 1] = key
        end
    end
    return values, sorting
end
MissionFocus_Options.GetActionValues = GetActionValues -- also used by the focus mode actions

local function GetStrataOptions()
    return {
        ["BACKGROUND"] = "Background",
        ["LOW"] = "Low",
        ["MEDIUM"] = "Medium",
        ["HIGH"] = "High",
        ["DIALOG"] = "Dialog",
    }
end

---------------------------------------------------------
-- Generic get/set: options point at db keys through info.arg

local function OnChanged()
    MissionFocus:GeneralParameterChanges()
end

local function GenericGet(info, key)
    local value = MissionFocus_Options.db[info.arg]
    if info.type == "color" then
        value = value or {}
        return value.r or 1, value.g or 1, value.b or 1, value.a or 1
    elseif info.type == "multiselect" then
        return value and value[key]
    end
    return value
end

local function GenericSet(info, ...)
    local arg = info.arg
    if info.type == "color" then
        local r, g, b, a = ...
        MissionFocus_Options.db[arg] = { r = r, g = g, b = b, a = a or 1 }
    elseif info.type == "multiselect" then
        local key, value = ...
        MissionFocus_Options.db[arg][key] = value
    else
        MissionFocus_Options.db[arg] = ...
    end
    OnChanged()
end

---------------------------------------------------------
-- Builders

local function FontOptions(prefix, order)
    return {
        [prefix .. "_font_name"] = {
            type = "select",
            name = L["MissionFocus.options.font_name.title"],
            desc = L["MissionFocus.options.font_name.desc"],
            values = function()
                return LSM:HashTable("font")
            end,
            dialogControl = "LSM30_Font",
            arg = prefix .. "_font_name",
            order = order + 1,
            width = optionWidth,
        },
        [prefix .. "_font_size"] = {
            type = "range",
            name = L["MissionFocus.options.font_size.title"],
            desc = L["MissionFocus.options.font_size.desc"],
            min = 6, max = 32, step = 1,
            arg = prefix .. "_font_size",
            order = order + 2,
            width = optionWidth,
        },
        [prefix .. "_font_outline"] = {
            type = "select",
            name = L["MissionFocus.options.font_outline.title"],
            desc = L["MissionFocus.options.font_outline.desc"],
            values = GetOutlineOptions,
            arg = prefix .. "_font_outline",
            order = order + 3,
            width = optionWidth,
        },
        [prefix .. "_color"] = {
            type = "color",
            name = L["MissionFocus.options.font_color.title"],
            desc = L["MissionFocus.options.font_color.desc"],
            hasAlpha = true,
            arg = prefix .. "_color",
            order = order + 4,
            width = optionWidth,
        },
    }
end

local function Merge(target, source)
    for k, v in pairs(source) do
        target[k] = v
    end
    return target
end

-- One select per priority slot. Choosing a category already used in another slot swaps them.
local function CycleOrderOptions()
    local args = {}
    for i = 1, #MissionFocus_Options.CATEGORIES do
        args["cycle_slot_" .. i] = {
            type = "select",
            name = string.format(L["MissionFocus.options.cycle_slot.title"], i),
            values = GetCategoryOptions,
            order = 10 + i,
            width = optionWidth,
            get = function()
                return MissionFocus_Options.db.category_order[i]
            end,
            set = function(_, value)
                local order = MissionFocus_Options.db.category_order
                for j = 1, #MissionFocus_Options.CATEGORIES do
                    if order[j] == value then
                        order[j] = order[i]
                    end
                end
                order[i] = value
                OnChanged()
            end,
        }
    end
    return args
end

-- One row per category: name | Tracked | Untracked. The list also has the "Not in <region>"
-- group (it is not part of the cycle priority).
local function TrayCategoryGrid()
    local args = {
        tray_categories_desc = {
            type = "description",
            name = L["MissionFocus.options.tray_categories.desc"] .. "\n",
            order = 0,
        },
    }
    local keys = {}
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        keys[#keys + 1] = key
    end
    keys[#keys + 1] = "elsewhere"

    local function Toggle(key, dbKey, label, order)
        return {
            type = "toggle",
            name = label,
            order = order,
            width = 0.7,
            get = function()
                return MissionFocus_Options.db[dbKey][key]
            end,
            set = function(_, value)
                MissionFocus_Options.db[dbKey][key] = value
                OnChanged()
            end,
        }
    end

    for i, key in ipairs(keys) do
        local order = i * 10
        args["name_" .. key] = {
            type = "description",
            name = function()
                if key == "elsewhere" then
                    return MissionFocus_Location:GetElsewhereName()
                end
                return L["MissionFocus.category." .. key]
            end,
            fontSize = "medium",
            order = order,
            width = 1.2,
        }
        args["tracked_" .. key] = Toggle(key, "tray_categories", L["MissionFocus.options.tray_tracked.title"], order + 1)
        args["untracked_" .. key] = Toggle(key, "tray_categories_untracked", L["MissionFocus.options.tray_untracked.title"], order + 2)
    end
    return args
end

-- One inline group per gesture slot, with a dropdown per gesture.
local GESTURES = { "tap", "hold", "double" }

local function ActionSlotOptions()
    local args = {
        action_hold_threshold = {
            type = "range",
            name = L["MissionFocus.options.action_hold_threshold.title"],
            desc = L["MissionFocus.options.action_hold_threshold.desc"],
            min = 0.1, max = 1.0, step = 0.05,
            arg = "action_hold_threshold",
            order = 1,
            width = optionWidth,
        },
        action_double_window = {
            type = "range",
            name = L["MissionFocus.options.action_double_window.title"],
            desc = L["MissionFocus.options.action_double_window.desc"],
            min = 0.1, max = 1.0, step = 0.05,
            arg = "action_double_window",
            order = 2,
            width = optionWidth,
        },
        actions_hint = {
            type = "description",
            name = "\n" .. L["MissionFocus.options.actions_hint"] .. "\n",
            order = 3,
        },
    }
    for slot = 1, MissionFocus_Actions.NUM_SLOTS do
        local slotArgs = {}
        for i, gesture in ipairs(GESTURES) do
            local includeHoldOnly = gesture == "hold"
            slotArgs[gesture] = {
                type = "select",
                name = L["MissionFocus.options.gesture_" .. gesture .. ".title"],
                desc = L["MissionFocus.options.gesture_" .. gesture .. ".desc"],
                values = function()
                    return (GetActionValues(includeHoldOnly))
                end,
                sorting = function()
                    return select(2, GetActionValues(includeHoldOnly))
                end,
                order = i,
                get = function()
                    return MissionFocus_Options.db.actions[slot][gesture]
                end,
                set = function(_, value)
                    MissionFocus_Actions:ResetAll()
                    MissionFocus_Options.db.actions[slot][gesture] = value
                    OnChanged()
                end,
            }
        end
        args["slot_" .. slot] = {
            type = "group",
            inline = true,
            name = string.format(L["MissionFocus.options.action_slot.title"], slot),
            order = 10 + slot,
            args = slotArgs,
        }
    end
    return args
end

---------------------------------------------------------
-- Our options table

MissionFocus_Options.options = {
    type = "group",
    name = L["MissionFocus.title"],
    desc = L["MissionFocus.desc"],
    childGroups = "tab",
    args = {
        tab_general = {
            type = "group",
            name = L["MissionFocus.options.tab_general.title"],
            order = 1,
            get = GenericGet,
            set = GenericSet,
            args = {
                hide_blizzard_tracker = {
                    type = "toggle",
                    name = L["MissionFocus.options.hide_blizzard_tracker.title"],
                    desc = L["MissionFocus.options.hide_blizzard_tracker.desc"],
                    arg = "hide_blizzard_tracker",
                    order = 1,
                    width = optionWidth,
                },
                blizzard_in_instances = {
                    type = "toggle",
                    name = L["MissionFocus.options.blizzard_in_instances.title"],
                    desc = L["MissionFocus.options.blizzard_in_instances.desc"],
                    arg = "blizzard_in_instances",
                    order = 2,
                    width = optionWidth,
                },
                hide_when_empty = {
                    type = "toggle",
                    name = L["MissionFocus.options.hide_when_empty.title"],
                    desc = L["MissionFocus.options.hide_when_empty.desc"],
                    arg = "hide_when_empty",
                    order = 3,
                    width = optionWidth,
                },
                soft_objectives = {
                    type = "select",
                    name = L["MissionFocus.options.soft_objectives.title"],
                    desc = L["MissionFocus.options.soft_objectives.desc"],
                    values = {
                        ["off"] = L["MissionFocus.list.soft_off"],
                        ["main"] = L["MissionFocus.list.soft_main"],
                        ["secondary"] = L["MissionFocus.list.soft_secondary"],
                    },
                    sorting = { "off", "main", "secondary" },
                    arg = "soft_objectives",
                    order = 3.5,
                    width = optionWidth,
                },
                panel_hidden = {
                    type = "toggle",
                    name = L["MissionFocus.options.panel_hidden.title"],
                    desc = L["MissionFocus.options.panel_hidden.desc"],
                    arg = "panel_hidden",
                    order = 4,
                    width = optionWidth,
                },
                btwquests_enabled = {
                    type = "toggle",
                    name = L["MissionFocus.options.btwquests_enabled.title"],
                    desc = function()
                        if MissionFocus_BtW:IsInstalled() then
                            return L["MissionFocus.options.btwquests_enabled.desc"]
                        end
                        return L["MissionFocus.options.btwquests_enabled.desc"] .. "\n\n|cffff6666"
                            .. L["MissionFocus.options.btwquests_enabled.missing"] .. "|r"
                    end,
                    disabled = function()
                        return not MissionFocus_BtW:IsInstalled()
                    end,
                    arg = "btwquests_enabled",
                    order = 5,
                    width = optionWidth,
                    set = function(info, value)
                        GenericSet(info, value)
                        MissionFocus_BtW:Invalidate()
                        MissionFocus_QuestlinesUI:Refresh()
                    end,
                },
                debug = {
                    type = "toggle",
                    name = L["MissionFocus.options.debug.title"],
                    desc = L["MissionFocus.options.debug.desc"],
                    arg = "debug",
                    order = 10,
                    width = optionWidth,
                },
                keybind_hint = {
                    type = "description",
                    name = "\n" .. L["MissionFocus.options.keybind_hint"],
                    order = 20,
                },
            },
        },
        tab_cycle = {
            type = "group",
            name = L["MissionFocus.options.tab_cycle.title"],
            order = 2,
            get = GenericGet,
            set = GenericSet,
            args = Merge({
                focus_modes_hint = {
                    type = "description",
                    name = L["MissionFocus.options.focus_modes_hint"],
                    order = 1,
                },
                focus_modes_open = {
                    type = "execute",
                    name = L["MissionFocus.options.focus_modes_open.title"],
                    order = 2,
                    func = function()
                        MissionFocus_Log:Open(nil, "modes")
                    end,
                },
                cycle_header = {
                    type = "header",
                    name = L["MissionFocus.options.cycle_header.title"],
                    order = 9,
                },
                cycle_header_desc = {
                    type = "description",
                    name = L["MissionFocus.options.cycle_header.desc"],
                    order = 10,
                },
                cycle_reset = {
                    type = "execute",
                    name = L["MissionFocus.options.cycle_reset.title"],
                    order = 100,
                    func = function()
                        MissionFocus_Options.db.category_order = DefaultCategoryOrder()
                        OnChanged()
                    end,
                },
            }, CycleOrderOptions()),
        },
        tab_actions = {
            type = "group",
            name = L["MissionFocus.options.tab_actions.title"],
            order = 2.5,
            get = GenericGet,
            set = GenericSet,
            args = ActionSlotOptions(),
        },
        tab_tray = {
            type = "group",
            name = L["MissionFocus.options.tab_tray.title"],
            order = 3,
            get = GenericGet,
            set = GenericSet,
            args = {
                -- Last, so the other tray options stay at the top.
                tray_categories = {
                    type = "group",
                    inline = true,
                    name = L["MissionFocus.options.tray_categories.title"],
                    order = 100,
                    args = TrayCategoryGrid(),
                },
                tray_max_entries = {
                    type = "range",
                    name = L["MissionFocus.options.tray_max_entries.title"],
                    desc = L["MissionFocus.options.tray_max_entries.desc"],
                    min = 1, max = 40, step = 1,
                    arg = "tray_max_entries",
                    order = 2,
                    width = optionWidth,
                },
                tray_position = {
                    type = "select",
                    name = L["MissionFocus.options.tray_position.title"],
                    desc = L["MissionFocus.options.tray_position.desc"],
                    values = {
                        ["BELOW"] = L["MissionFocus.list.below"],
                        ["ABOVE"] = L["MissionFocus.list.above"],
                    },
                    arg = "tray_position",
                    order = 3,
                    width = optionWidth,
                },
                tray_show_progress = {
                    type = "toggle",
                    name = L["MissionFocus.options.tray_show_progress.title"],
                    desc = L["MissionFocus.options.tray_show_progress.desc"],
                    arg = "tray_show_progress",
                    order = 4,
                    width = optionWidth,
                },
            },
        },
        tab_appearance = {
            type = "group",
            name = L["MissionFocus.options.tab_appearance.title"],
            order = 4,
            get = GenericGet,
            set = GenericSet,
            args = Merge(Merge(Merge({
                header_panel = {
                    type = "header",
                    name = L["MissionFocus.options.header_panel.title"],
                    order = 1,
                },
                show_category_label = {
                    type = "toggle",
                    name = L["MissionFocus.options.show_category_label.title"],
                    desc = L["MissionFocus.options.show_category_label.desc"],
                    arg = "show_category_label",
                    order = 2,
                    width = optionWidth,
                },
                show_next_button = {
                    type = "toggle",
                    name = L["MissionFocus.options.show_next_button.title"],
                    desc = L["MissionFocus.options.show_next_button.desc"],
                    arg = "show_next_button",
                    order = 3,
                    width = optionWidth,
                },
                show_tray_button = {
                    type = "toggle",
                    name = L["MissionFocus.options.show_tray_button.title"],
                    desc = L["MissionFocus.options.show_tray_button.desc"],
                    arg = "show_tray_button",
                    order = 4,
                    width = optionWidth,
                },
                header_title_font = {
                    type = "header",
                    name = L["MissionFocus.options.header_title_font.title"],
                    order = 10,
                },
                title_use_category_color = {
                    type = "toggle",
                    name = L["MissionFocus.options.title_use_category_color.title"],
                    desc = L["MissionFocus.options.title_use_category_color.desc"],
                    arg = "title_use_category_color",
                    order = 15,
                    width = optionWidth,
                },
                header_objective_font = {
                    type = "header",
                    name = L["MissionFocus.options.header_objective_font.title"],
                    order = 20,
                },
                objective_complete_color = {
                    type = "color",
                    name = L["MissionFocus.options.objective_complete_color.title"],
                    desc = L["MissionFocus.options.objective_complete_color.desc"],
                    hasAlpha = true,
                    arg = "objective_complete_color",
                    order = 25,
                    width = optionWidth,
                },
                header_progress_bar = {
                    type = "header",
                    name = L["MissionFocus.options.header_progress_bar.title"],
                    order = 26,
                },
                progress_bar_desc = {
                    type = "description",
                    name = L["MissionFocus.options.header_progress_bar.desc"],
                    order = 26.1,
                },
                progress_bar_hidden = {
                    type = "toggle",
                    name = L["MissionFocus.options.progress_bar_hidden.title"],
                    desc = L["MissionFocus.options.progress_bar_hidden.desc"],
                    arg = "progress_bar_hidden",
                    order = 26.5,
                    width = optionWidth,
                },
                progress_bar_texture = {
                    type = "select",
                    name = L["MissionFocus.options.progress_bar_texture.title"],
                    desc = L["MissionFocus.options.progress_bar_texture.desc"],
                    values = function()
                        return LSM:HashTable("statusbar")
                    end,
                    dialogControl = "LSM30_Statusbar",
                    arg = "progress_bar_texture",
                    order = 27,
                    width = optionWidth,
                    disabled = function()
                        return MissionFocus_Options.db.progress_bar_hidden
                    end,
                },
                progress_bar_bg_color = {
                    type = "color",
                    name = L["MissionFocus.options.progress_bar_bg_color.title"],
                    desc = L["MissionFocus.options.progress_bar_bg_color.desc"],
                    hasAlpha = true,
                    arg = "progress_bar_bg_color",
                    order = 28,
                    width = optionWidth,
                    disabled = function()
                        return MissionFocus_Options.db.progress_bar_hidden
                    end,
                },
                progress_bar_show_text = {
                    type = "toggle",
                    name = L["MissionFocus.options.progress_bar_show_text.title"],
                    desc = L["MissionFocus.options.progress_bar_show_text.desc"],
                    arg = "progress_bar_show_text",
                    order = 29,
                    width = optionWidth,
                    disabled = function()
                        return MissionFocus_Options.db.progress_bar_hidden
                    end,
                },
                header_tray_font = {
                    type = "header",
                    name = L["MissionFocus.options.header_tray_font.title"],
                    order = 30,
                },
                header_frame = {
                    type = "header",
                    name = L["MissionFocus.options.header_frame.title"],
                    order = 40,
                },
                frame_style = {
                    type = "select",
                    name = L["MissionFocus.options.frame_style.title"],
                    desc = L["MissionFocus.options.frame_style.desc"],
                    values = GetFrameStyleOptions,
                    arg = "frame_style",
                    order = 40.5,
                    width = optionWidth,
                },
                bg_color = {
                    type = "color",
                    name = L["MissionFocus.options.bg_color.title"],
                    desc = L["MissionFocus.options.bg_color.desc"],
                    hasAlpha = true,
                    arg = "bg_color",
                    order = 41,
                    width = optionWidth,
                },
                border_size = {
                    type = "range",
                    name = L["MissionFocus.options.border_size.title"],
                    desc = L["MissionFocus.options.border_size.desc"],
                    min = 0, max = 64, step = 1,
                    arg = "border_size",
                    order = 42,
                    width = optionWidth,
                },
                border_color = {
                    type = "color",
                    name = L["MissionFocus.options.border_color.title"],
                    desc = L["MissionFocus.options.border_color.desc"],
                    hasAlpha = true,
                    arg = "border_color",
                    order = 42.5,
                    width = optionWidth,
                    disabled = function()
                        return MissionFocus_Options.db.frame_style ~= "blizzard"
                    end,
                },
                frame_width = {
                    type = "range",
                    name = L["MissionFocus.options.frame_width.title"],
                    desc = L["MissionFocus.options.frame_width.desc"],
                    min = 150, max = 600, step = 1,
                    arg = "frame_width",
                    order = 43,
                    width = optionWidth,
                },
                frame_scale = {
                    type = "range",
                    name = L["MissionFocus.options.frame_scale.title"],
                    desc = L["MissionFocus.options.frame_scale.desc"],
                    min = 0.5, max = 2.0, step = 0.05,
                    arg = "frame_scale",
                    order = 44,
                    width = optionWidth,
                },
            }, FontOptions("title", 10)), FontOptions("objective", 20)), FontOptions("tray", 30)),
        },
        tab_position = {
            type = "group",
            name = L["MissionFocus.options.tab_position.title"],
            order = 5,
            get = GenericGet,
            set = GenericSet,
            args = {
                header_position_panel = {
                    type = "header",
                    name = L["MissionFocus.options.header_panel.title"],
                    order = 0,
                },
                locked = {
                    type = "toggle",
                    name = L["MissionFocus.options.locked.title"],
                    desc = L["MissionFocus.options.locked.desc"],
                    arg = "locked",
                    order = 1,
                    width = optionWidth,
                },
                anchor_point = {
                    type = "select",
                    name = L["MissionFocus.options.anchor_point.title"],
                    desc = L["MissionFocus.options.anchor_point.desc"],
                    values = GetAnchorOptions,
                    arg = "anchor_point",
                    order = 2,
                    width = optionWidth,
                    -- Keep the panel where it is on screen; only the reference point changes.
                    set = function(info, value)
                        MissionFocus_UI:ChangeAnchorPoint(value)
                        OnChanged()
                    end,
                },
                pos_x = {
                    type = "range",
                    name = L["MissionFocus.options.pos_x.title"],
                    desc = L["MissionFocus.options.pos_x.desc"],
                    min = -4000, max = 4000, softMin = -2000, softMax = 2000, step = 1,
                    arg = "pos_x",
                    order = 3,
                    width = optionWidth,
                },
                pos_y = {
                    type = "range",
                    name = L["MissionFocus.options.pos_y.title"],
                    desc = L["MissionFocus.options.pos_y.desc"],
                    min = -3000, max = 3000, softMin = -1500, softMax = 1500, step = 1,
                    arg = "pos_y",
                    order = 4,
                    width = optionWidth,
                },
                strata = {
                    type = "select",
                    name = L["MissionFocus.options.strata.title"],
                    desc = L["MissionFocus.options.strata.desc"],
                    values = GetStrataOptions,
                    arg = "strata",
                    order = 5,
                    width = optionWidth,
                },
                reset_position = {
                    type = "execute",
                    name = L["MissionFocus.options.reset_position.title"],
                    order = 6,
                    func = function()
                        MissionFocus:ResetPosition()
                    end,
                },
                header_item_button = {
                    type = "header",
                    name = L["MissionFocus.options.header_item_button.title"],
                    order = 10,
                },
                show_item_button = {
                    type = "toggle",
                    name = L["MissionFocus.options.show_item_button.title"],
                    desc = L["MissionFocus.options.show_item_button.desc"],
                    arg = "show_item_button",
                    order = 11,
                    width = optionWidth,
                },
                hide_item_with_panel = {
                    type = "toggle",
                    name = L["MissionFocus.options.hide_item_with_panel.title"],
                    desc = L["MissionFocus.options.hide_item_with_panel.desc"],
                    arg = "hide_item_with_panel",
                    order = 12,
                    width = optionWidth,
                },
                item_side = {
                    type = "select",
                    name = L["MissionFocus.options.item_side.title"],
                    desc = L["MissionFocus.options.item_side.desc"],
                    values = {
                        ["LEFT"] = L["MissionFocus.list.left"],
                        ["RIGHT"] = L["MissionFocus.list.right"],
                    },
                    arg = "item_side",
                    order = 13,
                    width = optionWidth,
                },
                item_size = {
                    type = "range",
                    name = L["MissionFocus.options.item_size.title"],
                    desc = L["MissionFocus.options.item_size.desc"],
                    min = 20, max = 64, step = 1,
                    arg = "item_size",
                    order = 14,
                    width = optionWidth,
                },
                item_nearby_distance = {
                    type = "range",
                    name = L["MissionFocus.options.item_nearby_distance.title"],
                    desc = L["MissionFocus.options.item_nearby_distance.desc"],
                    min = 0, max = 1000, step = 10,
                    arg = "item_nearby_distance",
                    order = 15,
                    width = optionWidth,
                },
            },
        },
    },
}
