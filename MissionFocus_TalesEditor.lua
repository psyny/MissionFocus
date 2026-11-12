-- MissionFocus_TalesEditor.lua
-- Editor of a tale (Tales tab > Edit): an AceConfig tree, Tale > Stories > Chapters > Steps,
-- shown inside the MissionFocus Center. The options table is rebuilt from the tale after every
-- change (MissionFocus_Tales listeners), and the dialog re-opened in its container, like the
-- Focus Modes tab does.
-- Players write the tale, its stories and chapters; steps are picked from the game (quest log,
-- questlines, IDs, BtWQuests chains when it is installed) and then fine-tuned.
MissionFocus_TalesEditor = {}

local E = MissionFocus_TalesEditor
local T = MissionFocus_Tales
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
local AceGUI = LibStub("AceGUI-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local Call = MissionFocus_Utils.Call

E.APP = "MissionFocusTales"
E.taleID = nil
E.group = nil
E.search = ""          -- BtWQuests chain search text
E.chainChoice = nil    -- chosen BtWQuests chain

local HEADER_HEIGHT = 30
local options = { type = "group", name = "", childGroups = "tree", args = {} }

local function Tale()
    return E.taleID and T:Get(E.taleID) or nil
end

local function Key(id)
    return "i_" .. id
end

---------------------------------------------------------
-- Field helpers

local function NumberText(value)
    return value and tostring(value) or ""
end

local function ParseNumber(text)
    text = text and text:gsub(",", ".") or ""
    return tonumber(text)
end

local function ValidNumber(_, text)
    if text == "" or ParseNumber(text) then
        return true
    end
    return L["MissionFocus.tales.ed_not_number"]
end

local function Done()
    T:Changed()
end

local function PlayerPosition()
    local mapID = Call("C_Map.GetBestMapForUnit", "player")
    local position = mapID and Call("C_Map.GetPlayerMapPosition", mapID, "player")
    if position and position.GetXY then
        local x, y = position:GetXY()
        return mapID, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
    end
    return mapID
end

local function RoleValues()
    return { main = L["MissionFocus.tales.role_main"], side = L["MissionFocus.tales.role_side"],
        optional = L["MissionFocus.tales.role_optional"] }
end

local function FactionValues(includeBoth)
    local values = { alliance = L["MissionFocus.tales.faction_alliance"], horde = L["MissionFocus.tales.faction_horde"] }
    values[includeBoth and "both" or "any"] = L["MissionFocus.tales.faction_both"]
    return values
end

---------------------------------------------------------
-- Fields shared by stories, chapters and steps

-- Collapsible sections: an item's sections start closed; E.open["<itemID>:<section>"] = true.
E.open = {}

local function SectionOpen(item, section)
    return E.open[item.id .. ":" .. section] == true
end

local function SectionToggle(item, section, label, order)
    return {
        type = "execute", order = order, width = "full",
        name = function()
            local text = type(label) == "function" and label() or label
            return (SectionOpen(item, section) and "|cffffd100-|r  " or "|cffffd100+|r  ") .. text
        end,
        func = function()
            local key = item.id .. ":" .. section
            E.open[key] = not E.open[key] or nil
            AceConfigRegistry:NotifyChange(E.APP)
        end,
    }
end

local function Closed(item, section)
    return function()
        return not SectionOpen(item, section)
    end
end

-- Quests inside an item (quest steps, and dungeons done with a quest): questID -> label.
local function QuestsIn(node, level, prefix, out)
    if level == "step" then
        if (node.type == "quest" or node.type == "dungeon") and node.questID then
            out[node.questID] = prefix .. T:Title(node, "step")
        end
        return
    end
    local children, childLevel = T:Children(node, level)
    for _, child in ipairs(children) do
        local childPrefix = childLevel == "step" and prefix or (prefix .. T:Title(child, childLevel) .. " > ")
        QuestsIn(child, childLevel, childPrefix, out)
    end
end

-- Quests that can be required: those of the other items of the same list (a step: the other
-- steps of its chapter; a chapter: the other chapters; a story: the other stories). Quests
-- already required from elsewhere (e.g. an imported file) stay listed so they can be unticked.
local function RequirableQuests(item, level, siblings)
    local values = {}
    for _, sibling in ipairs(siblings) do
        if sibling ~= item then
            local prefix = level == "step" and "" or (T:Title(sibling, level) .. " > ")
            QuestsIn(sibling, level, prefix, values)
        end
    end
    for _, questID in ipairs(item.requires and item.requires.quests or {}) do
        if not values[questID] then
            values[questID] = (T:QuestTitle(questID) or ("#" .. questID)) .. "  |cff999999("
                .. L["MissionFocus.tales.ed_req_elsewhere"] .. ")|r"
        end
    end
    return values
end

local function RequirementCount(item)
    local requires, n = item.requires, 0
    if requires then
        n = (requires.level and 1 or 0) + (requires.maxLevel and 1 or 0) + (requires.chromieTime and 1 or 0)
            + #(requires.quests or {})
    end
    return n
end

-- Fields shared by stories, chapters and steps. Always shown: title and what comes before.
-- Collapsed until opened: details (story text, role, faction, removed) and requirements.
local function CommonArgs(tale, item, level, siblings, order)
    local args = {}
    local isStep = level == "step"
    args.title = {
        type = "input", order = order + 1, width = "full",
        name = isStep and L["MissionFocus.tales.ed_title_step"] or L["MissionFocus.tales.ed_title"],
        get = function() return item.title or "" end,
        set = function(_, value)
            item.title = value ~= "" and value or nil
            Done()
        end,
    }
    args.previous = {
        type = "multiselect", order = order + 2, width = "full",
        name = L["MissionFocus.tales.ed_previous"],
        desc = L["MissionFocus.tales.ed_previous_desc"],
        values = function()
            local values = {}
            for _, sibling in ipairs(siblings) do
                if sibling ~= item then
                    values[sibling.id] = T:Title(sibling, level)
                end
            end
            return values
        end,
        get = function(_, key)
            for _, id in ipairs(item.previous or {}) do
                if id == key then
                    return true
                end
            end
            return false
        end,
        set = function(_, key, value)
            -- First link in a list that follows its listed order: keep that order for the others.
            if not T.IsExplicit(siblings) then
                T:MakeExplicit(siblings)
            end
            local list = {}
            for _, id in ipairs(item.previous or {}) do
                if id ~= key then
                    list[#list + 1] = id
                end
            end
            if value then
                list[#list + 1] = key
            end
            item.previous = #list > 0 and list or nil
            Done()
        end,
        hidden = function() return #siblings < 2 end,
    }

    -- Details (collapsed)
    args.details_space = { type = "description", order = order + 3, name = " " }
    args.details_toggle = SectionToggle(item, "details", L["MissionFocus.tales.ed_section_details"], order + 4)
    local detailsClosed = Closed(item, "details")
    args.description = {
        type = "input", multiline = 4, order = order + 5, width = "full", hidden = detailsClosed,
        name = L["MissionFocus.tales.ed_description"],
        get = function() return item.description or "" end,
        set = function(_, value)
            item.description = value ~= "" and value or nil
            Done()
        end,
    }
    args.role = {
        type = "select", order = order + 6, name = L["MissionFocus.tales.ed_role"], hidden = detailsClosed,
        desc = L["MissionFocus.tales.ed_role_desc"],
        values = RoleValues,
        get = function() return item.role or "main" end,
        set = function(_, value)
            item.role = value ~= "main" and value or nil
            Done()
        end,
    }
    args.faction = {
        type = "select", order = order + 7, name = L["MissionFocus.tales.ed_faction_item"], hidden = detailsClosed,
        values = function() return FactionValues(false) end,
        get = function() return item.faction or "any" end,
        set = function(_, value)
            item.faction = value ~= "any" and value or nil
            Done()
        end,
    }
    args.unavailable = {
        type = "toggle", order = order + 8, width = "full", hidden = detailsClosed,
        name = L["MissionFocus.tales.ed_unavailable"], desc = L["MissionFocus.tales.ed_unavailable_desc"],
        get = function() return item.unavailable == true end,
        set = function(_, value)
            item.unavailable = value or nil
            Done()
        end,
    }

    -- Requirements (collapsed)
    local function Requires()
        item.requires = item.requires or {}
        return item.requires
    end
    local function Tidy()
        if item.requires and next(item.requires) == nil then
            item.requires = nil
        end
    end
    args.req_toggle = SectionToggle(item, "requires", function()
        local n = RequirementCount(item)
        if n == 0 then
            return L["MissionFocus.tales.ed_requirements"]
        end
        return string.format(L["MissionFocus.tales.ed_requirements_n"], n)
    end, order + 10)
    local reqClosed = Closed(item, "requires")
    args.req_level = {
        type = "input", order = order + 11, name = L["MissionFocus.tales.ed_min_level"], width = "half",
        hidden = reqClosed, validate = ValidNumber,
        get = function() return NumberText(item.requires and item.requires.level) end,
        set = function(_, value)
            Requires().level = ParseNumber(value)
            Tidy()
            Done()
        end,
    }
    args.req_max_level = {
        type = "input", order = order + 12, name = L["MissionFocus.tales.ed_max_level"], width = "half",
        hidden = reqClosed, validate = ValidNumber,
        get = function() return NumberText(item.requires and item.requires.maxLevel) end,
        set = function(_, value)
            Requires().maxLevel = ParseNumber(value)
            Tidy()
            Done()
        end,
    }
    args.req_chromie = {
        type = "select", order = order + 13, name = L["MissionFocus.tales.ed_chromie"], hidden = reqClosed,
        values = function()
            local values = { [0] = L["MissionFocus.tales.ed_none"] }
            for id, name in pairs(T:ChromieOptions()) do
                values[id] = name
            end
            local current = item.requires and item.requires.chromieTime
            if current and not values[current] then
                values[current] = "#" .. current
            end
            return values
        end,
        get = function() return item.requires and item.requires.chromieTime or 0 end,
        set = function(_, value)
            Requires().chromieTime = value ~= 0 and value or nil
            Tidy()
            Done()
        end,
    }
    args.req_quests = {
        type = "multiselect", order = order + 14, width = "full",
        name = L["MissionFocus.tales.ed_req_quests"],
        desc = L["MissionFocus.tales.ed_req_quests_desc_" .. level],
        hidden = function() return reqClosed() or next(RequirableQuests(item, level, siblings)) == nil end,
        values = function() return RequirableQuests(item, level, siblings) end,
        get = function(_, questID)
            for _, id in ipairs(item.requires and item.requires.quests or {}) do
                if id == questID then
                    return true
                end
            end
            return false
        end,
        set = function(_, questID, value)
            local list = {}
            for _, id in ipairs(item.requires and item.requires.quests or {}) do
                if id ~= questID then
                    list[#list + 1] = id
                end
            end
            if value then
                list[#list + 1] = questID
            end
            Requires().quests = #list > 0 and list or nil
            Tidy()
            Done()
        end,
    }
    args.req_quests_none = {
        type = "description", order = order + 14.5,
        name = L["MissionFocus.tales.ed_req_quests_none_" .. level],
        hidden = function() return reqClosed() or next(RequirableQuests(item, level, siblings)) ~= nil end,
    }

    -- Order and removal
    args.manage_header = { type = "header", order = order + 40, name = "" }
    args.move_up = {
        type = "execute", order = order + 41, name = L["MissionFocus.tales.ed_move_up"], width = "half",
        func = function() T:Move(tale, item.id, -1) end,
    }
    args.move_down = {
        type = "execute", order = order + 42, name = L["MissionFocus.tales.ed_move_down"], width = "half",
        func = function() T:Move(tale, item.id, 1) end,
    }
    args.delete = {
        type = "execute", order = order + 43, name = L["MissionFocus.tales.ed_delete"],
        confirm = true, confirmText = string.format(L["MissionFocus.tales.ed_delete_confirm"], T:Title(item, level)),
        func = function() T:Remove(tale, item.id) end,
    }
    return args
end

-- "Use list order" for a list whose items have links.
local function ListOrderArg(list, order)
    return {
        type = "execute", order = order, name = L["MissionFocus.tales.ed_list_order"],
        desc = L["MissionFocus.tales.ed_list_order_desc"],
        hidden = function() return not T.IsExplicit(list) end,
        func = function()
            for _, child in ipairs(list) do
                child.previous = nil
            end
            Done()
        end,
    }
end

---------------------------------------------------------
-- Steps

local function StepTypeArgs(item, order)
    local args = {}
    local function NumberField(field, name, ord)
        args[field] = {
            type = "input", order = ord, name = name, validate = ValidNumber,
            get = function() return NumberText(item[field]) end,
            set = function(_, value)
                item[field] = ParseNumber(value) or item[field]
                Done()
            end,
        }
    end
    local kind = item.type
    if kind == "quest" then
        NumberField("questID", L["MissionFocus.tales.ed_quest_id"], order + 1)
    elseif kind == "questline" then
        NumberField("questLineID", L["MissionFocus.tales.ed_questline_id"], order + 1)
        args.line_info = {
            type = "description", order = order + 2,
            name = function()
                return string.format(L["MissionFocus.tales.ed_line_info"], #T.LineQuests(item.questLineID))
            end,
        }
    elseif kind == "achievement" then
        NumberField("achievementID", L["MissionFocus.tales.ed_achievement_id"], order + 1)
    elseif kind == "dungeon" then
        args.name = {
            type = "input", order = order + 1, name = L["MissionFocus.tales.ed_dungeon_name"],
            get = function() return item.name or "" end,
            set = function(_, value)
                item.name = value ~= "" and value or nil
                Done()
            end,
        }
        NumberField("questID", L["MissionFocus.tales.ed_dungeon_quest"], order + 2)
    elseif kind == "visit" then
        NumberField("mapID", L["MissionFocus.tales.ed_map_id"], order + 1)
        NumberField("x", L["MissionFocus.tales.ed_x"], order + 2)
        NumberField("y", L["MissionFocus.tales.ed_y"], order + 3)
        args.here = {
            type = "execute", order = order + 4, name = L["MissionFocus.tales.ed_use_my_position"],
            func = function()
                item.mapID, item.x, item.y = PlayerPosition()
                Done()
            end,
        }
    end
    return args
end

-- Where a quest starts: the automatic answer, and fields to override it.
local function StartArgs(item, order)
    local function Start()
        item.start = item.start or {}
        return item.start
    end
    local function Tidy()
        if item.start and next(item.start) == nil then
            item.start = nil
        end
    end
    local args = {}
    args.start_header = { type = "header", order = order, name = L["MissionFocus.tales.ed_start"] }
    args.start_auto = {
        type = "description", order = order + 1,
        name = function()
            local saved = item.start
            item.start = nil
            local mapID, x, y, npc = T:GetStart(item)
            item.start = saved
            if not mapID and not npc then
                return L["MissionFocus.tales.ed_start_unknown"]
            end
            local where = mapID and string.format("%s %.1f, %.1f", T.MapName(mapID) or ("#" .. mapID), (x or 0) * 100, (y or 0) * 100) or ""
            return string.format(L["MissionFocus.tales.ed_start_auto"], npc or "?", where)
        end,
    }
    args.start_type = {
        type = "select", order = order + 2, name = L["MissionFocus.tales.ed_start_type"],
        values = function()
            local values = { none = L["MissionFocus.tales.ed_start_auto_choice"] }
            for _, kind in ipairs(T.START_TYPES) do
                values[kind] = L["MissionFocus.tales.start_type_" .. kind]
            end
            return values
        end,
        get = function() return item.start and item.start.type or "none" end,
        set = function(_, value)
            Start().type = value ~= "none" and value or nil
            Tidy()
            Done()
        end,
    }
    args.start_npc = {
        type = "input", order = order + 3, name = L["MissionFocus.tales.ed_start_npc"],
        get = function() return item.start and item.start.npc or "" end,
        set = function(_, value)
            Start().npc = value ~= "" and value or nil
            Tidy()
            Done()
        end,
    }
    for i, field in ipairs({ "mapID", "x", "y" }) do
        args["start_" .. field] = {
            type = "input", order = order + 3 + i, width = "half", validate = ValidNumber,
            name = L["MissionFocus.tales.ed_" .. (field == "mapID" and "map_id" or field)],
            get = function() return NumberText(item.start and item.start[field]) end,
            set = function(_, value)
                Start()[field] = ParseNumber(value)
                Tidy()
                Done()
            end,
        }
    end
    args.start_here = {
        type = "execute", order = order + 8, name = L["MissionFocus.tales.ed_use_my_position"],
        func = function()
            local start = Start()
            start.mapID, start.x, start.y = PlayerPosition()
            start.type = start.type or "location"
            Done()
        end,
    }
    return args
end

local function StepGroup(tale, step, siblings, order)
    local args = {
        kind = {
            type = "description", order = 0, fontSize = "medium",
            name = function()
                return "|cffffd100" .. (L["MissionFocus.tales.type_" .. step.type] or step.type) .. "|r  " .. T:Title(step, "step")
            end,
        },
    }
    for key, arg in pairs(StepTypeArgs(step, 1)) do
        args[key] = arg
    end
    for key, arg in pairs(CommonArgs(tale, step, "step", siblings, 10)) do
        args[key] = arg
    end
    if step.type == "quest" then
        for key, arg in pairs(StartArgs(step, 30)) do
            args[key] = arg
        end
    end
    return {
        type = "group", order = order,
        name = function()
            return "|cff999999" .. (L["MissionFocus.tales.type_" .. step.type] or "") .. "|r " .. T:Title(step, "step")
        end,
        args = args,
    }
end

---------------------------------------------------------
-- Chapters: their fields, the ways to add steps, their steps

local function QuestLogValues()
    local values = {}
    for i = 1, (Call("C_QuestLog.GetNumQuestLogEntries") or 0) do
        local info = Call("C_QuestLog.GetInfo", i)
        if info and info.questID and info.questID > 0 and not info.isHeader and info.title then
            values[info.questID] = info.title
        end
    end
    return values
end

local function QuestlineValues()
    local values = {}
    for _, entry in ipairs(MissionFocus_Questlines:GetLines()) do
        values[entry.lineID] = entry.line.name or ("#" .. entry.lineID)
    end
    return values
end

local function AddStepArgs(tale, chapter, order)
    local function Add(step)
        T:AddStep(tale, chapter, step)
    end
    local args = {}
    -- Room above, so adding steps reads as its own part of the page.
    args.add_space = { type = "description", order = order - 1, name = "\n\n\n" }
    args.add_header = { type = "header", order = order, name = L["MissionFocus.tales.ed_add_steps"] }
    args.add_from_log = {
        type = "select", order = order + 1, width = "full", name = L["MissionFocus.tales.ed_from_log"],
        values = QuestLogValues,
        get = function() return nil end,
        set = function(_, questID) Add({ type = "quest", questID = questID }) end,
    }
    args.add_from_lines = {
        type = "select", order = order + 2, width = "full", name = L["MissionFocus.tales.ed_from_questlines"],
        values = QuestlineValues,
        get = function() return nil end,
        set = function(_, lineID) Add({ type = "questline", questLineID = lineID }) end,
    }
    args.add_quest_id = {
        type = "input", order = order + 3, name = L["MissionFocus.tales.ed_add_quest_id"], validate = ValidNumber,
        get = function() return "" end,
        set = function(_, value)
            local id = ParseNumber(value)
            if id then
                Add({ type = "quest", questID = id })
            end
        end,
    }
    args.add_line_id = {
        type = "input", order = order + 4, name = L["MissionFocus.tales.ed_add_line_id"], validate = ValidNumber,
        get = function() return "" end,
        set = function(_, value)
            local id = ParseNumber(value)
            if id then
                Add({ type = "questline", questLineID = id })
            end
        end,
    }
    args.add_achievement = {
        type = "input", order = order + 5, name = L["MissionFocus.tales.ed_add_achievement"], validate = ValidNumber,
        get = function() return "" end,
        set = function(_, value)
            local id = ParseNumber(value)
            if id then
                Add({ type = "achievement", achievementID = id })
            end
        end,
    }
    args.add_dungeon = {
        type = "input", order = order + 6, name = L["MissionFocus.tales.ed_add_dungeon"],
        get = function() return "" end,
        set = function(_, value)
            if value ~= "" then
                Add({ type = "dungeon", name = value })
            end
        end,
    }
    args.add_note = {
        type = "execute", order = order + 7, name = L["MissionFocus.tales.ed_add_note"],
        func = function() Add({ type = "note", title = L["MissionFocus.tales.new_note_title"] }) end,
    }
    args.add_visit = {
        type = "execute", order = order + 8, name = L["MissionFocus.tales.ed_add_visit"],
        desc = L["MissionFocus.tales.ed_add_visit_desc"],
        func = function()
            local mapID, x, y = PlayerPosition()
            Add({ type = "visit", mapID = mapID, x = x, y = y })
        end,
    }
    args.record = {
        type = "toggle", order = order + 9, width = "full",
        name = L["MissionFocus.tales.ed_record"], desc = L["MissionFocus.tales.ed_record_desc"],
        get = function()
            local recTale, recChapter = T:GetRecording()
            return recTale == tale and recChapter == chapter
        end,
        set = function(_, value)
            if value then
                T:StartRecording(tale, chapter)
            else
                T:StopRecording()
            end
        end,
    }

    -- BtWQuests chains
    local BTW = MissionFocus_BtW
    local function NoBtW()
        return not BTW:IsEnabled()
    end
    args.btw_header = { type = "header", order = order + 20, name = L["MissionFocus.tales.ed_btw"], hidden = NoBtW }
    args.btw_search = {
        type = "input", order = order + 21, name = L["MissionFocus.tales.ed_btw_search"],
        desc = L["MissionFocus.tales.ed_btw_search_desc"], hidden = NoBtW,
        get = function() return E.search end,
        set = function(_, value)
            E.search = value
            E.chainChoice = nil
            AceConfigRegistry:NotifyChange(E.APP)
        end,
    }
    args.btw_results = {
        type = "select", order = order + 22, width = "full", name = L["MissionFocus.tales.ed_btw_results"],
        hidden = NoBtW,
        values = function()
            local values = {}
            for _, chain in ipairs(BTW:SearchChains(E.search)) do
                values[chain.chainID] = chain.name .. (chain.lineID and ("  |cff999999(" .. L["MissionFocus.tales.type_questline"] .. ")|r") or "")
            end
            return values
        end,
        get = function() return E.chainChoice end,
        set = function(_, value)
            E.chainChoice = value
            AceConfigRegistry:NotifyChange(E.APP)
        end,
    }
    args.btw_add_line = {
        type = "execute", order = order + 23, name = L["MissionFocus.tales.ed_btw_add_line"],
        desc = L["MissionFocus.tales.ed_btw_add_line_desc"],
        hidden = NoBtW,
        disabled = function() return not (E.chainChoice and BTW:GetLineForChain(E.chainChoice)) end,
        func = function()
            Add({ type = "questline", questLineID = BTW:GetLineForChain(E.chainChoice) })
        end,
    }
    args.btw_add_quests = {
        type = "execute", order = order + 24, name = L["MissionFocus.tales.ed_btw_add_quests"],
        desc = L["MissionFocus.tales.ed_btw_add_quests_desc"],
        hidden = NoBtW,
        disabled = function() return E.chainChoice == nil end,
        func = function()
            local steps = BTW:GetChainSteps(E.chainChoice)
            if not steps or #steps == 0 then
                return
            end
            local list = {}
            for i, entry in ipairs(steps) do
                list[i] = { type = "quest", questID = entry.questID, role = entry.optional and "optional" or nil,
                    links = entry.links }
            end
            T:AddLinkedSteps(tale, chapter, list)
        end,
    }
    return args
end

local function ChapterGroup(tale, chapter, siblings, order)
    local args = CommonArgs(tale, chapter, "chapter", siblings, 0)
    for key, arg in pairs(AddStepArgs(tale, chapter, 60)) do
        args[key] = arg
    end
    chapter.steps = chapter.steps or {}
    args.list_order = ListOrderArg(chapter.steps, 90)
    for i, step in ipairs(chapter.steps) do
        args[Key(step.id)] = StepGroup(tale, step, chapter.steps, 100 + i)
    end
    return {
        type = "group", order = order,
        name = function() return chapter.title or L["MissionFocus.tales.untitled"] end,
        args = args,
    }
end

local function StoryGroup(tale, story, siblings, order)
    local args = CommonArgs(tale, story, "story", siblings, 0)
    args.add_space = { type = "description", order = 58, name = "\n\n\n" }
    args.add_header = { type = "header", order = 59, name = L["MissionFocus.tales.ed_add_chapters"] }
    args.add_chapter = {
        type = "execute", order = 60, name = L["MissionFocus.tales.ed_add_chapter"],
        func = function()
            E.pendingSelect = T:AddChapter(tale, story).id
        end,
    }
    story.chapters = story.chapters or {}
    args.list_order = ListOrderArg(story.chapters, 61)
    for i, chapter in ipairs(story.chapters) do
        args[Key(chapter.id)] = ChapterGroup(tale, chapter, story.chapters, 100 + i)
    end
    return {
        type = "group", order = order,
        name = function() return "|cffffd100" .. (story.title or L["MissionFocus.tales.untitled"]) .. "|r" end,
        args = args,
    }
end

---------------------------------------------------------
-- Tale

local function TaleArgs(tale)
    local args = {}
    local function Text(field, name, ord, multiline)
        args[field] = {
            type = "input", order = ord, name = name, width = "full", multiline = multiline,
            get = function() return tale[field] or "" end,
            set = function(_, value)
                tale[field] = value ~= "" and value or nil
                if field == "title" and not tale.title then
                    tale.title = L["MissionFocus.tales.untitled"]
                end
                Done()
            end,
        }
    end
    Text("title", L["MissionFocus.tales.ed_title"], 1)
    Text("author", L["MissionFocus.tales.ed_author"], 2)
    Text("version", L["MissionFocus.tales.ed_version"], 3)
    Text("description", L["MissionFocus.tales.ed_description"], 4, 5)
    args.game = {
        type = "select", order = 4.5, name = L["MissionFocus.tales.ed_game"],
        desc = L["MissionFocus.tales.ed_game_desc"],
        values = function()
            return { retail = L["MissionFocus.tales.game_retail"], forever = L["MissionFocus.tales.game_forever"] }
        end,
        get = function() return tale.game or "retail" end,
        set = function(_, value)
            tale.game = value
            Done()
        end,
    }
    args.faction = {
        type = "select", order = 5, name = L["MissionFocus.tales.ed_faction"],
        values = function() return FactionValues(true) end,
        get = function() return tale.faction or "both" end,
        set = function(_, value)
            tale.faction = value
            Done()
        end,
    }
    args.structure = {
        type = "description", order = 10,
        name = "\n" .. L["MissionFocus.tales.ed_structure"],
    }
    args.add_story = {
        type = "execute", order = 11, name = L["MissionFocus.tales.ed_add_story"],
        desc = L["MissionFocus.tales.ed_add_story_desc"],
        func = function()
            E.pendingSelect = T:AddStory(tale).id
        end,
    }
    args.add_chapter = {
        type = "execute", order = 12, name = L["MissionFocus.tales.ed_add_chapter"],
        hidden = function() return tale.stories ~= nil and #tale.stories > 0 end,
        func = function()
            E.pendingSelect = T:AddChapter(tale).id
        end,
    }
    return args
end

function E:Build()
    local tale = Tale()
    options.args = {}
    if not tale then
        return
    end
    options.name = tale.title
    options.args.tale = {
        type = "group", order = 0, name = "|cff88ccff" .. L["MissionFocus.tales.ed_tale_settings"] .. "|r",
        args = TaleArgs(tale),
    }
    if tale.stories and #tale.stories > 0 then
        options.args.story_order = ListOrderArg(tale.stories, 1)
        for i, story in ipairs(tale.stories) do
            options.args[Key(story.id)] = StoryGroup(tale, story, tale.stories, 10 + i)
        end
    else
        tale.chapters = tale.chapters or {}
        options.args.chapter_order = ListOrderArg(tale.chapters, 1)
        for i, chapter in ipairs(tale.chapters) do
            options.args[Key(chapter.id)] = ChapterGroup(tale, chapter, tale.chapters, 10 + i)
        end
    end
end

AceConfigRegistry:RegisterOptionsTable(E.APP, function() return options end)

-- Tree path (group keys) to an item.
local function PathTo(tale, id)
    local path = {}
    local item = T:Find(tale, id)
    while item and item ~= tale do
        table.insert(path, 1, Key(item.id))
        local _, _, parent = T:Find(tale, item.id)
        item = parent
    end
    return path
end

---------------------------------------------------------
-- Container (inside the Tales page)

function E:CreateContainer(frame, page)
    local done = MissionFocus_Log.CreateButton(frame, L["MissionFocus.tales.ed_done"], 70, function()
        MissionFocus_TalesUI:SetMode("view")
    end)
    done:SetPoint("TOPLEFT", 0, -4)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("LEFT", done, "RIGHT", 10, 0)
    frame.title:SetPoint("RIGHT", frame, "RIGHT", -230, 0)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetWordWrap(false)
    local delete = MissionFocus_Log.CreateButton(frame, L["MissionFocus.tales.delete_tale"], 90, function()
        local tale = Tale()
        if tale then
            StaticPopup_Show("MISSIONFOCUS_TALE_DELETE", string.format(L["MissionFocus.tales.delete_confirm"], tale.title), nil, tale.id)
        end
    end)
    delete:SetPoint("TOPRIGHT", 0, -4)
    local export = MissionFocus_Log.CreateButton(frame, L["MissionFocus.tales.export"], 70, function()
        local tale = Tale()
        if tale then
            MissionFocus_TalesUI:ShowTextDialog("export", T:Export(tale))
        end
    end)
    export:SetPoint("RIGHT", delete, "LEFT", -4, 0)
    self.frame = frame

    local group = AceGUI:Create("SimpleGroup")
    group:SetLayout("Fill")
    group.frame:SetParent(frame)
    group.frame:SetFrameStrata(page:GetParent():GetFrameStrata())
    group.frame:SetFrameLevel(page:GetFrameLevel() + 2)
    group.frame:ClearAllPoints()
    group.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -HEADER_HEIGHT)
    group.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    group.frame:Show()
    self.group = group

    -- Coalesced: an edit notifies more than once, and the widget being clicked must not be
    -- released while its own callback runs.
    table.insert(T.listeners, function()
        E:RequestRebuild()
    end)
    AceConfigRegistry.RegisterCallback(E, "ConfigTableChange", function(_, appName)
        if appName == E.APP then
            E:RequestRebuild(true)
        end
    end)
    return group
end

-- keepTable: only re-open the dialog (the table did not change shape, e.g. a search).
function E:RequestRebuild(keepTable)
    if not self.taleID or not self.frame or not self.frame:IsVisible() then
        return
    end
    if not keepTable then
        self.needsBuild = true
    end
    if self.rebuildPending then
        return
    end
    self.rebuildPending = true
    C_Timer.After(0, function()
        E.rebuildPending = false
        if E.needsBuild then
            E.needsBuild = false
            E:Build()
        end
        E:Show()
    end)
end

function E:Show()
    local tale = Tale()
    if not tale or not self.group then
        return
    end
    self.frame.title:SetText(string.format(L["MissionFocus.tales.editing"], tale.title))
    if self.pendingSelect then
        local path = PathTo(tale, self.pendingSelect)
        self.pendingSelect = nil
        if #path > 0 then
            AceConfigDialog:SelectGroup(self.APP, unpack(path))
        end
    end
    self.group:SetWidth(self.frame:GetWidth())
    self.group:SetHeight(self.frame:GetHeight() - HEADER_HEIGHT)
    AceConfigDialog:Open(self.APP, self.group)
end

-- selectID: open the editor on this item (the one being viewed).
function E:Open(taleID, group, selectID)
    self.taleID = taleID
    self.group = group or self.group
    self:Build()
    if selectID and selectID ~= taleID then
        self.pendingSelect = selectID
    else
        AceConfigDialog:SelectGroup(self.APP, "tale")
    end
    self:Show()
end

function E:Close()
    if self.group and self.taleID then
        self.group:ReleaseChildren()
    end
    self.taleID = nil
end
