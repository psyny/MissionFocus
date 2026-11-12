-- MissionFocus_Tales.lua
-- Adventurer's Tales: player-made story paths (see readme_adventurer_tales.md).
--   Tale -> Stories (optional) -> Chapters -> Steps (quest, questline, dungeon, achievement,
--   visit, note). Each item may list the sibling items that come before it ("previous"); a list
--   where no item does keeps its listed order.
-- Tales are stored in the tale file format itself (plain tables that map 1:1 to JSON), account
-- wide in db.global.tales. Per character: db.char.tales = { marks, follow, record }.
-- Progress always comes from the game (quests done, in the log, achievements); only dungeons,
-- visits and notes can be marked done by hand.
-- BtWQuests (MissionFocus_BtW) is optional: names and quest givers when it is there.
MissionFocus_Tales = {}

local T = MissionFocus_Tales
local Call = MissionFocus_Utils.Call
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")

T.FORMAT = "MissionFocus-Tale"
T.FORMAT_VERSION = 1
T.STEP_TYPES = { "quest", "questline", "dungeon", "achievement", "visit", "note" }
T.ROLES = { "main", "side", "optional" }
T.FACTIONS = { "both", "alliance", "horde" }
-- The game a tale is made for: quests, zones and levels differ between them.
T.GAMES = { "retail", "forever" }
T.START_TYPES = { "npc", "location", "item", "followup", "auto" }

-- Field order in exported files (readable top to bottom).
local KEY_ORDER = { "format", "formatVersion", "id", "type", "title", "author", "version", "game", "name",
    "description", "faction", "role", "previous", "requires", "unavailable", "questID", "questLineID",
    "achievementID", "mapID", "x", "y", "npc", "start", "level", "maxLevel", "quests", "chromieTime",
    "stories", "chapters", "steps" }
local LIST_KEYS = { stories = true, chapters = true, steps = true, previous = true, quests = true }

T.revision = 0 -- bumped on every edit; views and caches compare it

---------------------------------------------------------
-- Storage

local function Global()
    local global = MissionFocus.db.global
    global.tales = global.tales or {}
    return global.tales
end

local function Char()
    local char = MissionFocus.db.char
    char.tales = char.tales or {}
    local data = char.tales
    data.marks = data.marks or {}
    return data
end

function T:GetTales()
    return Global()
end

function T:Get(taleID)
    for index, tale in ipairs(Global()) do
        if tale.id == taleID then
            return tale, index
        end
    end
    return nil
end

-- Listeners (UI, editor) are told about every change.
T.listeners = {}

function T:Changed()
    self.revision = self.revision + 1
    for _, listener in ipairs(self.listeners) do
        pcall(listener)
    end
end

---------------------------------------------------------
-- Structure

-- Levels: "tale" | "story" | "chapter" | "step". Children of an item, and their level.
function T:Children(item, level)
    if level == "tale" then
        if item.stories and #item.stories > 0 then
            return item.stories, "story"
        end
        item.chapters = item.chapters or {}
        return item.chapters, "chapter"
    elseif level == "story" then
        item.chapters = item.chapters or {}
        return item.chapters, "chapter"
    elseif level == "chapter" then
        item.steps = item.steps or {}
        return item.steps, "step"
    end
    return {}, nil
end

-- id -> { item, level, parent, parentLevel, index } for the whole tale.
local indexCache = setmetatable({}, { __mode = "k" })

function T:Index(tale)
    local cached = indexCache[tale]
    if cached and cached.revision == self.revision then
        return cached.map
    end
    local map = {}
    local function Walk(item, level, parent, parentLevel, index)
        if item.id then
            map[item.id] = { item = item, level = level, parent = parent, parentLevel = parentLevel, index = index }
        end
        local children, childLevel = self:Children(item, level)
        for i, child in ipairs(children) do
            Walk(child, childLevel, item, level, i)
        end
    end
    Walk(tale, "tale", nil, nil, 0)
    indexCache[tale] = { revision = self.revision, map = map }
    return map
end

function T:Find(tale, id)
    local entry = self:Index(tale)[id]
    if entry then
        return entry.item, entry.level, entry.parent, entry.parentLevel, entry.index
    end
    return nil
end

-- A new ID unique in the tale.
function T:NewID(tale, prefix)
    local map = self:Index(tale)
    local n = 1
    while map[prefix .. n] do
        n = n + 1
    end
    return prefix .. n
end

---------------------------------------------------------
-- Checking a tale (import, and every edit): only known fields, of the right types, unique IDs,
-- "previous" pointing at siblings. Returns a clean copy and a list of warnings.

local function Str(value)
    if type(value) == "string" and value ~= "" then
        return value
    elseif type(value) == "number" then
        return tostring(value)
    end
    return nil
end

local function Num(value)
    if type(value) == "string" then
        value = tonumber(value)
    end
    if type(value) == "number" and value == value then
        return value
    end
    return nil
end

local function OneOf(value, list, default)
    value = type(value) == "string" and value:lower() or nil
    for _, option in ipairs(list) do
        if option == value then
            return value
        end
    end
    return default
end

local function CleanRequires(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local requires = {
        level = Num(raw.level),
        maxLevel = Num(raw.maxLevel),
        chromieTime = Num(raw.chromieTime),
    }
    if type(raw.quests) == "table" then
        local quests = {}
        for _, questID in ipairs(raw.quests) do
            quests[#quests + 1] = Num(questID)
        end
        requires.quests = #quests > 0 and quests or nil
    end
    if next(requires) == nil then
        return nil
    end
    return requires
end

local function CleanStart(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local start = {
        type = OneOf(raw.type, T.START_TYPES, nil),
        npc = Str(raw.npc),
        mapID = Num(raw.mapID),
        x = Num(raw.x),
        y = Num(raw.y),
    }
    return next(start) and start or nil
end

local STEP_FIELDS = {
    quest = { questID = Num },
    questline = { questLineID = Num },
    dungeon = { name = Str, questID = Num },
    achievement = { achievementID = Num },
    visit = { mapID = Num, x = Num, y = Num },
    note = {},
}
local STEP_REQUIRED = { quest = "questID", questline = "questLineID", achievement = "achievementID" }

local function Clean(raw, level, warnings, ids, where)
    local item = {
        id = Str(raw.id),
        title = Str(raw.title),
        description = Str(raw.description),
    }
    if level ~= "tale" then
        item.role = OneOf(raw.role, T.ROLES, nil)
        if item.role == "main" then
            item.role = nil -- the default; keeps files short
        end
        item.requires = CleanRequires(raw.requires)
        item.faction = OneOf(raw.faction, { "alliance", "horde" }, nil)
        item.unavailable = raw.unavailable == true or nil
        if type(raw.previous) == "table" then
            local previous = {}
            for _, id in ipairs(raw.previous) do
                previous[#previous + 1] = Str(id)
            end
            item.previous = #previous > 0 and previous or nil
        end
    end
    if level == "step" then
        local stepType = OneOf(raw.type, T.STEP_TYPES, nil)
        if not stepType then
            warnings[#warnings + 1] = string.format(L["MissionFocus.tales.warn_step_type"], where, tostring(raw.type))
            return nil
        end
        item.type = stepType
        for field, convert in pairs(STEP_FIELDS[stepType]) do
            item[field] = convert(raw[field])
        end
        local required = STEP_REQUIRED[stepType]
        if required and not item[required] then
            warnings[#warnings + 1] = string.format(L["MissionFocus.tales.warn_step_field"], where, required)
            return nil
        end
        if stepType == "quest" then
            item.start = CleanStart(raw.start)
        end
    end

    -- Unique IDs across the whole tale (missing ones are made later, when siblings are known).
    if item.id and ids[item.id] then
        warnings[#warnings + 1] = string.format(L["MissionFocus.tales.warn_duplicate_id"], item.id)
        item.id = nil
    end
    if item.id then
        ids[item.id] = true
    end
    return item
end

local function CleanList(rawList, level, warnings, ids, where)
    local list = {}
    if type(rawList) ~= "table" then
        return list
    end
    for i, raw in ipairs(rawList) do
        if type(raw) == "table" then
            local label = string.format("%s %d", where, i)
            local item = Clean(raw, level, warnings, ids, label)
            if item then
                if level == "story" then
                    item.chapters = CleanList(raw.chapters, "chapter", warnings, ids, label .. " > chapter")
                elseif level == "chapter" then
                    item.steps = CleanList(raw.steps, "step", warnings, ids, label .. " > step")
                end
                list[#list + 1] = item
            end
        end
    end
    return list
end

-- Missing IDs, and "previous" entries that are not siblings.
local function FixLinks(list, prefix, ids, warnings)
    for _, item in ipairs(list) do
        if not item.id then
            local n = 1
            while ids[prefix .. n] do
                n = n + 1
            end
            item.id = prefix .. n
            ids[item.id] = true
        end
    end
    local siblings = {}
    for _, item in ipairs(list) do
        siblings[item.id] = true
    end
    for _, item in ipairs(list) do
        if item.previous then
            local kept = {}
            for _, id in ipairs(item.previous) do
                if siblings[id] and id ~= item.id then
                    kept[#kept + 1] = id
                else
                    warnings[#warnings + 1] = string.format(L["MissionFocus.tales.warn_previous"], item.id, id)
                end
            end
            item.previous = #kept > 0 and kept or nil
        end
        if item.chapters then
            FixLinks(item.chapters, "chapter", ids, warnings)
        end
        if item.steps then
            FixLinks(item.steps, "step", ids, warnings)
        end
    end
end

function T:Normalize(raw)
    local warnings = {}
    if type(raw) ~= "table" then
        return nil, { L["MissionFocus.tales.warn_not_tale"] }
    end
    if raw.format ~= nil and raw.format ~= T.FORMAT then
        return nil, { L["MissionFocus.tales.warn_not_tale"] }
    end
    if Num(raw.formatVersion) and Num(raw.formatVersion) > T.FORMAT_VERSION then
        warnings[#warnings + 1] = L["MissionFocus.tales.warn_newer"]
    end
    local ids = {}
    local tale = Clean(raw, "tale", warnings, ids, "tale")
    tale.format = T.FORMAT
    tale.formatVersion = T.FORMAT_VERSION
    tale.id = Str(raw.id) or ("tale-" .. tostring(time()) .. "-" .. tostring(math.random(1000, 9999)))
    tale.title = tale.title or L["MissionFocus.tales.untitled"]
    tale.author = Str(raw.author)
    tale.version = Str(raw.version)
    tale.faction = OneOf(raw.faction, T.FACTIONS, "both")
    -- Tales from before this field existed were all made for Retail.
    tale.game = OneOf(raw.game, T.GAMES, "retail")
    ids[tale.id] = true

    local stories = CleanList(raw.stories, "story", warnings, ids, "story")
    local chapters = CleanList(raw.chapters, "chapter", warnings, ids, "chapter")
    if #stories > 0 and #chapters > 0 then
        -- Both: the loose chapters become a story of their own, so nothing is lost.
        warnings[#warnings + 1] = L["MissionFocus.tales.warn_mixed"]
        stories[#stories + 1] = { title = L["MissionFocus.tales.more_chapters"], chapters = chapters }
        chapters = {}
    end
    if #stories > 0 then
        tale.stories = stories
        FixLinks(stories, "story", ids, warnings)
    else
        tale.chapters = chapters
        FixLinks(chapters, "chapter", ids, warnings)
    end
    return tale, warnings
end

---------------------------------------------------------
-- Import / export

local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, field in pairs(value) do
        copy[key] = DeepCopy(field)
    end
    return copy
end
T.DeepCopy = DeepCopy

function T:Export(tale)
    local clean = self:Normalize(DeepCopy(tale))
    return MissionFocus_JSON.Encode(clean, { keyOrder = KEY_ORDER, listKeys = LIST_KEYS })
end

-- Returns tale, warnings, existing (a saved tale with the same ID), or nil and an error.
function T:Parse(text)
    -- WoW edit boxes double "|" (their escape character).
    text = (text or ""):gsub("||", "|")
    local raw, err = MissionFocus_JSON.Decode(text)
    if raw == nil then
        return nil, string.format(L["MissionFocus.tales.import_bad_json"], tostring(err))
    end
    local tale, warnings = self:Normalize(raw)
    if not tale then
        return nil, warnings[1]
    end
    return tale, warnings, (self:Get(tale.id))
end

-- mode: "replace" (same ID) or "copy" (new ID).
function T:Save(tale, mode)
    local list = Global()
    local _, index = self:Get(tale.id)
    if index and mode == "replace" then
        list[index] = tale
    else
        if index then
            tale.id = tale.id .. "-" .. tostring(time() % 100000)
        end
        list[#list + 1] = tale
    end
    self:Changed()
    return tale
end

function T:Delete(taleID)
    local _, index = self:Get(taleID)
    if index then
        table.remove(Global(), index)
        local char = Char()
        char.marks[taleID] = nil
        if char.follow == taleID then
            char.follow = nil
        end
        if char.record and char.record.tale == taleID then
            char.record = nil
        end
        self:Changed()
    end
end

function T:CreateTale(title)
    local tale = self:Normalize({ title = title or L["MissionFocus.tales.new_tale_title"], chapters = {},
        game = self:CurrentGame() })
    tale.author = UnitName and Call("UnitName", "player") or nil
    tale.version = "1.0"
    return self:Save(tale)
end

---------------------------------------------------------
-- Editing

-- Gives every item of the list an explicit "previous" (the item before it), so new items with
-- branches can be added without changing the order of the existing ones.
function T:MakeExplicit(list)
    for i, item in ipairs(list) do
        if i > 1 and not item.previous then
            item.previous = { list[i - 1].id }
        end
    end
end

local function IsExplicit(list)
    for _, item in ipairs(list) do
        if item.previous then
            return true
        end
    end
    return false
end
T.IsExplicit = IsExplicit

-- Adds a story; a tale holding chapters gets its chapters moved into this first story.
function T:AddStory(tale)
    local story = { id = self:NewID(tale, "story"), title = L["MissionFocus.tales.new_story_title"], chapters = {} }
    if not tale.stories or #tale.stories == 0 then
        tale.stories = { story }
        story.chapters = tale.chapters or {}
        tale.chapters = nil
    else
        if IsExplicit(tale.stories) then
            story.previous = { tale.stories[#tale.stories].id }
        end
        table.insert(tale.stories, story)
    end
    self:Changed()
    return story
end

-- parent: the tale (when it has no stories) or a story.
function T:AddChapter(tale, parent)
    parent = parent or tale
    local list
    if parent == tale then
        if tale.stories and #tale.stories > 0 then
            parent = tale.stories[#tale.stories]
            parent.chapters = parent.chapters or {}
            list = parent.chapters
        else
            tale.chapters = tale.chapters or {}
            list = tale.chapters
        end
    else
        parent.chapters = parent.chapters or {}
        list = parent.chapters
    end
    local chapter = { id = self:NewID(tale, "chapter"), title = L["MissionFocus.tales.new_chapter_title"], steps = {} }
    if IsExplicit(list) and #list > 0 then
        chapter.previous = { list[#list].id }
    end
    table.insert(list, chapter)
    self:Changed()
    return chapter
end

-- Adds one step (a table of step fields) at the end of a chapter.
function T:AddStep(tale, chapter, step)
    step.id = self:NewID(tale, "step")
    chapter.steps = chapter.steps or {}
    if IsExplicit(chapter.steps) and #chapter.steps > 0 then
        step.previous = { chapter.steps[#chapter.steps].id }
    end
    table.insert(chapter.steps, step)
    self:Changed()
    return step
end

-- Adds several steps with their own links: steps[i].links = { indexes into steps }. Steps that
-- link to nothing follow the chapter's last step.
function T:AddLinkedSteps(tale, chapter, steps)
    chapter.steps = chapter.steps or {}
    local hasLinks = false
    for _, step in ipairs(steps) do
        if step.links and #step.links > 0 then
            hasLinks = true
        end
    end
    if hasLinks then
        self:MakeExplicit(chapter.steps)
    end
    local last = chapter.steps[#chapter.steps]
    local ids = {}
    for i, step in ipairs(steps) do
        step.id = self:NewID(tale, "step")
        ids[i] = step.id
        self.revision = self.revision + 1 -- the next NewID must see this one (one notice at the end)
        chapter.steps[#chapter.steps + 1] = step
    end
    for _, step in ipairs(steps) do
        local links = step.links
        step.links = nil
        if hasLinks then
            if links and #links > 0 then
                step.previous = {}
                for _, k in ipairs(links) do
                    step.previous[#step.previous + 1] = ids[k]
                end
            elseif last then
                step.previous = { last.id }
            end
        end
    end
    self:Changed()
end

-- Removes an item; siblings stop pointing at it.
function T:Remove(tale, id)
    local _, _, parent, parentLevel, index = self:Find(tale, id)
    if not parent then
        return
    end
    local list = self:Children(parent, parentLevel)
    local removed = table.remove(list, index)
    for _, item in ipairs(list) do
        if item.previous then
            local kept = {}
            for _, prev in ipairs(item.previous) do
                if prev ~= id then
                    kept[#kept + 1] = prev
                end
            end
            -- Whatever came after it now comes after what came before it.
            if #kept < #item.previous and removed.previous then
                for _, prev in ipairs(removed.previous) do
                    kept[#kept + 1] = prev
                end
            end
            item.previous = #kept > 0 and kept or nil
        end
    end
    if parent == tale and tale.stories and #tale.stories == 0 then
        tale.stories = nil
        tale.chapters = tale.chapters or {}
    end
    self:Changed()
end

function T:Move(tale, id, delta)
    local _, _, parent, parentLevel, index = self:Find(tale, id)
    if not parent then
        return
    end
    local list = self:Children(parent, parentLevel)
    local target = index + delta
    if target < 1 or target > #list then
        return
    end
    list[index], list[target] = list[target], list[index]
    self:Changed()
end

---------------------------------------------------------
-- Names

local function MapName(mapID)
    local info = mapID and Call("C_Map.GetMapInfo", mapID)
    return info and info.name or nil
end
T.MapName = MapName

function T:QuestTitle(questID)
    return MissionFocus_Questlines:GetTitle(questID) or MissionFocus_BtW:GetQuestName(questID)
end

function T:QuestlineTitle(lineID)
    local line = MissionFocus_Questlines:GetLine(lineID)
    if line and line.name then
        return line.name
    end
    local questIDs = Call("C_QuestLine.GetQuestLineQuests", lineID)
    local chainID = MissionFocus_BtW:GetChainForLine(lineID, type(questIDs) == "table" and questIDs or nil)
    return chainID and MissionFocus_BtW:GetChainName(chainID) or nil
end

-- Display name of any item. nil fields fall back to what the game knows.
function T:Title(item, level)
    if level ~= "step" then
        return item.title or L["MissionFocus.tales.untitled"]
    end
    if item.title then
        return item.title
    end
    local kind = item.type
    if kind == "quest" then
        return self:QuestTitle(item.questID) or string.format(L["MissionFocus.tales.quest_n"], item.questID)
    elseif kind == "questline" then
        return self:QuestlineTitle(item.questLineID) or string.format(L["MissionFocus.tales.questline_n"], item.questLineID)
    elseif kind == "achievement" then
        local name = select(2, Call("GetAchievementInfo", item.achievementID))
        return name or string.format(L["MissionFocus.tales.achievement_n"], item.achievementID)
    elseif kind == "dungeon" then
        return item.name or L["MissionFocus.tales.type_dungeon"]
    elseif kind == "visit" then
        local map = MapName(item.mapID)
        return map and string.format(L["MissionFocus.tales.visit_map"], map) or L["MissionFocus.tales.type_visit"]
    end
    if item.description then
        return item.description:sub(1, 40) .. (#item.description > 40 and "..." or "")
    end
    return L["MissionFocus.tales.type_note"]
end

---------------------------------------------------------
-- Requirements

function T:ChromieOptions()
    local names = {}
    for _, option in ipairs(Call("C_ChromieTime.GetChromieTimeExpansionOptions") or {}) do
        if type(option) == "table" and option.id then
            names[option.id] = option.name
        end
    end
    return names
end

local function PlayerLevel()
    return Call("UnitLevel", "player") or 0
end

-- met, { { label, done }, ... }
function T:CheckRequirements(requires)
    local list, met = {}, true
    if type(requires) ~= "table" then
        return true, list
    end
    local function Add(label, done)
        list[#list + 1] = { label = label, done = done and true or false }
        met = met and done and true or false
    end
    if requires.level then
        Add(string.format(L["MissionFocus.tales.req_level"], requires.level), PlayerLevel() >= requires.level)
    end
    if requires.maxLevel then
        Add(string.format(L["MissionFocus.tales.req_max_level"], requires.maxLevel), PlayerLevel() <= requires.maxLevel)
    end
    for _, questID in ipairs(requires.quests or {}) do
        Add(string.format(L["MissionFocus.tales.req_quest"], self:QuestTitle(questID) or ("#" .. questID)),
            Call("C_QuestLog.IsQuestFlaggedCompleted", questID))
    end
    if requires.chromieTime and requires.chromieTime > 0 then
        local name = self:ChromieOptions()[requires.chromieTime] or ("#" .. requires.chromieTime)
        Add(string.format(L["MissionFocus.tales.req_chromie"], name),
            Call("UnitChromieTimeID", "player") == requires.chromieTime)
    end
    return met, list
end

local function PlayerFaction()
    local faction = Call("UnitFactionGroup", "player")
    return type(faction) == "string" and faction:lower() or nil
end

local function Visible(item)
    return not item.faction or item.faction == PlayerFaction()
end
T.Visible = Visible

function T:FactionAllowed(tale)
    return tale.faction == "both" or tale.faction == nil or tale.faction == PlayerFaction()
end

-- The game this client is: "forever" for World of Warcraft: Forever (interface 16xxx, the
-- MissionFocus_Camelot.toc build), else "retail".
function T:CurrentGame()
    local interface = select(4, Call("GetBuildInfo"))
    if type(interface) == "number" and interface >= 16000 and interface < 17000 then
        return "forever"
    end
    return "retail"
end

function T:GameAllowed(tale)
    return (tale.game or "retail") == self:CurrentGame()
end

-- The tale can be played by this character: right game and faction.
function T:Playable(tale)
    return self:GameAllowed(tale) and self:FactionAllowed(tale)
end

---------------------------------------------------------
-- Manual marks (dungeons, visits, notes)

function T:IsMarked(tale, id)
    local marks = Char().marks[tale.id]
    return marks ~= nil and marks[id] == true
end

function T:ToggleMark(tale, id)
    local marks = Char().marks
    marks[tale.id] = marks[tale.id] or {}
    marks[tale.id][id] = not marks[tale.id][id] or nil
    self:Changed()
end

T.MARKABLE = { dungeon = true, visit = true, note = true }

---------------------------------------------------------
-- Progress. Evaluate(tale) returns a tree of results:
--   { item, level, kind, done, doneCount, total, inLog, inLogQuestID, account, reqs, reqMet,
--     preds = { child indexes }, children = { results }, parent }
-- kind: "done" | "unavailable" | "current" (on it) | "next" (can start now) | "blocked"
--       (requirement missing) | "behind" (not done, a later item is) | "future" (waiting) | "note"

local function LineQuests(lineID)
    local questIDs = Call("C_QuestLine.GetQuestLineQuests", lineID)
    if type(questIDs) == "table" and #questIDs > 0 then
        return questIDs
    end
    return MissionFocus_BtW:GetChainQuestIDs(lineID) or {}
end
T.LineQuests = LineQuests

local function QuestDone(questID)
    return Call("C_QuestLog.IsQuestFlaggedCompleted", questID) and true or false
end

local function QuestInLog(questID)
    return Call("C_QuestLog.IsOnQuest", questID) and true or false
end

local function StepState(tale, step, result)
    local kind = step.type
    if step.unavailable then
        result.done, result.unavailable = true, true
        return
    end
    if kind == "quest" then
        result.done = QuestDone(step.questID)
        result.inLog = QuestInLog(step.questID)
        result.inLogQuestID = result.inLog and step.questID or nil
        result.account = not result.done and Call("C_QuestLog.IsQuestFlaggedCompletedOnAccount", step.questID) and true or nil
    elseif kind == "questline" then
        local questIDs = LineQuests(step.questLineID)
        local done = 0
        for _, questID in ipairs(questIDs) do
            if QuestDone(questID) then
                done = done + 1
            elseif not result.inLogQuestID and QuestInLog(questID) then
                result.inLog, result.inLogQuestID = true, questID
            end
        end
        result.lineDone, result.lineTotal = done, #questIDs
        -- The game's own answer first: some questlines list every class's or faction's version
        -- of a quest (e.g. the Echo Isles), so "all quests done" would never be true.
        local complete = Call("C_QuestLine.IsComplete", step.questLineID)
        if type(complete) == "boolean" then
            result.done = complete or T:IsMarked(tale, step.id)
        else
            result.done = (#questIDs > 0 and done == #questIDs) or T:IsMarked(tale, step.id)
        end
        result.active = done > 0
    elseif kind == "achievement" then
        result.done = select(4, Call("GetAchievementInfo", step.achievementID)) and true or false
    elseif kind == "dungeon" then
        result.done = T:IsMarked(tale, step.id) or (step.questID ~= nil and QuestDone(step.questID))
    else -- visit, note
        result.done = T:IsMarked(tale, step.id)
    end
end

-- Notes, optional items and stories/chapters with nothing that counts never hold anything back.
local function Blocking(result)
    if result.item.role == "optional" then
        return false
    end
    if result.level == "step" then
        return result.item.type ~= "note"
    end
    return (result.total or 0) > 0
end

local function Counts(result)
    if result.level == "step" then
        if Blocking(result) then
            result.doneCount, result.total = result.done and 1 or 0, 1
        else
            result.doneCount, result.total = 0, 0
        end
        return
    end
    local doneCount, total, allDone, any = 0, 0, true, false
    for _, child in ipairs(result.children) do
        if child.item.role ~= "optional" then
            doneCount, total = doneCount + child.doneCount, total + child.total
            if Blocking(child) then
                any = true
                allDone = allDone and child.done
            end
        end
        result.inLog = result.inLog or child.inLog
        result.inLogQuestID = result.inLogQuestID or child.inLogQuestID
        result.active = result.active or child.active or child.done
    end
    result.doneCount, result.total = doneCount, total
    result.done = any and allDone
end

-- Builds results for an item and everything inside it (done-ness only).
local function Build(tale, item, level, parent)
    local result = { item = item, level = level, parent = parent, children = {} }
    if level == "step" then
        StepState(tale, item, result)
    else
        local children, childLevel = T:Children(item, level)
        for _, child in ipairs(children) do
            if Visible(child) then
                result.children[#result.children + 1] = Build(tale, child, childLevel, result)
            end
        end
    end
    Counts(result)
    if item.unavailable then
        result.done, result.unavailable = true, true
    end
    result.reqMet, result.reqs = T:CheckRequirements(item.requires)
    return result
end

-- Order links between the children of one result.
local function Link(result)
    local children = result.children
    local position = {}
    for i, child in ipairs(children) do
        position[child.item.id] = i
    end
    local explicit = false
    for _, child in ipairs(children) do
        if child.item.previous then
            explicit = true
        end
    end
    for i, child in ipairs(children) do
        child.preds = {}
        if explicit then
            for _, id in ipairs(child.item.previous or {}) do
                if position[id] then
                    child.preds[#child.preds + 1] = position[id]
                end
            end
        elseif i > 1 then
            child.preds[1] = i - 1
        end
    end
end

-- A later sibling that is done (its whole chain of predecessors leads back to this child).
local function LaterDone(children, index)
    local succ = {}
    for i, child in ipairs(children) do
        for _, p in ipairs(child.preds) do
            succ[p] = succ[p] or {}
            table.insert(succ[p], i)
        end
    end
    local stack, seen = { index }, { [index] = true }
    while #stack > 0 do
        local node = table.remove(stack)
        for _, to in ipairs(succ[node] or {}) do
            if not seen[to] then
                if children[to].done and not children[to].unavailable then
                    return true
                end
                seen[to] = true
                stack[#stack + 1] = to
            end
        end
    end
    return false
end

-- Kinds, top down. open: the parent can be played (its own predecessors and requirements).
local function Classify(result, open)
    Link(result)
    for i, child in ipairs(result.children) do
        local predsDone = true
        for _, p in ipairs(child.preds) do
            local pred = result.children[p]
            if Blocking(pred) and not pred.done then
                predsDone = false
            end
        end
        child.predsDone = predsDone
        local isNote = child.level == "step" and child.item.type == "note"
        if child.unavailable then
            child.kind = "unavailable"
        elseif child.done then
            child.kind = "done"
        elseif not open then
            child.kind = "future"
        elseif isNote then
            child.kind = predsDone and "note" or "future"
        elseif child.inLog or (child.active and predsDone) then
            child.kind = "current"
        elseif LaterDone(result.children, i) then
            child.kind = "behind"
        elseif predsDone and child.reqMet then
            child.kind = "next"
        elseif predsDone then
            child.kind = "blocked"
        else
            child.kind = "future"
        end
        local childOpen = open and predsDone and child.reqMet
        Classify(child, childOpen or child.kind == "current" or child.kind == "behind")
    end
end

local evalCache = setmetatable({}, { __mode = "k" })
local EVAL_SECONDS = 1 -- quest state changes come with events; a second of reuse is plenty

function T:Evaluate(tale)
    local cached = evalCache[tale]
    local now = GetTime and GetTime() or 0
    if cached and cached.revision == self.revision and now - cached.time < EVAL_SECONDS then
        return cached.result
    end
    local root = Build(tale, tale, "tale", nil)
    root.kind = root.done and "done" or (root.active and "current" or "next")
    Classify(root, self:Playable(tale))
    local byID = {}
    local function Map(result)
        byID[result.item.id] = result
        for _, child in ipairs(result.children) do
            Map(child)
        end
    end
    Map(root)
    root.byID = byID
    evalCache[tale] = { revision = self.revision, time = now, result = root }
    return root
end

-- Forget cached results (quest events).
function T:Invalidate()
    evalCache = setmetatable({}, { __mode = "k" })
end

-- The steps to do now, in tale order: steps in progress first, then the ones that can start.
-- Main and side steps come before optional ones.
function T:GetNextSteps(tale)
    local root = self:Evaluate(tale)
    local current, ready, optional = {}, {}, {}
    local function Walk(result, optionalBranch)
        for _, child in ipairs(result.children) do
            local isOptional = optionalBranch or child.item.role == "optional"
            if child.level == "step" then
                if child.kind == "current" or child.kind == "next" then
                    local list = isOptional and optional or (child.kind == "current" and current or ready)
                    list[#list + 1] = child
                end
            elseif child.kind ~= "done" and child.kind ~= "future" and child.kind ~= "blocked"
                and child.kind ~= "unavailable" then
                Walk(child, isOptional)
            end
        end
    end
    Walk(root, false)
    for _, list in ipairs({ ready, optional }) do
        for _, result in ipairs(list) do
            current[#current + 1] = result
        end
    end
    return current
end

-- Path of titles from the tale down to an item: "Tale > Story > Chapter" (separator: " > ").
function T:Path(result, separator)
    local parts = {}
    local node = result
    while node do
        table.insert(parts, 1, self:Title(node.item, node.level))
        node = node.parent
    end
    return table.concat(parts, separator or " > ")
end

---------------------------------------------------------
-- Where a step starts, and doing it

-- mapID, x, y (0..1), npcName for a quest step: the tale's own "start", else what MissionFocus
-- and BtWQuests know.
function T:GetStart(step)
    local start = step.start
    if start and start.mapID and start.x and start.y then
        return start.mapID, start.x / 100, start.y / 100, start.npc
    end
    if step.type ~= "quest" then
        return nil, nil, nil, start and start.npc
    end
    local entry = MissionFocus.db.char.questlines.quests[step.questID]
    if entry and entry.lineID then
        local mapID, x, y = MissionFocus_Questlines:GetOfferPosition(entry.lineID, step.questID)
        if mapID then
            return mapID, x, y, start and start.npc
        end
    end
    local npc, mapID, x, y = MissionFocus_BtW:GetQuestGiver(step.questID, { MissionFocus_Location:GetPlayerMap() })
    return mapID, x, y, (start and start.npc) or npc
end

local function FocusQuest(questID)
    if not Call("C_QuestLog.GetQuestWatchType", questID) then
        Call("C_QuestLog.AddQuestWatch", questID)
    end
    MissionFocus:SetFocus(questID)
end

-- The main action of a step (click, "Next tale step").
function T:RunStep(tale, result)
    local step = result.item
    if result.inLogQuestID then
        FocusQuest(result.inLogQuestID)
        return
    end
    local title = self:Title(step, "step")
    if step.type == "quest" then
        local mapID, x, y = self:GetStart(step)
        if mapID then
            MissionFocus_Questlines:SetWaypoint(mapID, x, y, title)
        elseif step.start and step.start.type == "followup" then
            MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.start_followup_msg"], title))
        else
            MissionFocus_Utils.Print(L["MissionFocus.questlines.no_position"])
        end
    elseif step.type == "questline" then
        MissionFocus_Questlines:EnsureLine(step.questLineID, step.title or self:QuestlineTitle(step.questLineID))
        MissionFocus_Log:Open(nil, "questlines")
        -- The questline view shows where it comes from: "Tale - Story - Chapter".
        MissionFocus_QuestlinesUI:ShowDetail(step.questLineID, false, result.parent and self:Path(result.parent, " - "),
            { taleID = tale.id, viewID = result.parent and result.parent.item.id or tale.id })
    elseif step.type == "visit" and step.mapID and step.x and step.y then
        MissionFocus_Questlines:SetWaypoint(step.mapID, step.x / 100, step.y / 100, title)
    elseif step.type == "achievement" then
        Call("OpenAchievementFrameToAchievement", step.achievementID)
    end
end

-- Does the step have a main action at all (for "Click: ..." hints)?
function T:StepAction(result)
    local step = result.item
    if result.done or step.unavailable then
        return step.type == "questline" and "open_line" or nil
    end
    if result.inLogQuestID then
        return "focus"
    end
    if step.type == "quest" then
        return "waypoint"
    elseif step.type == "questline" then
        return "open_line"
    elseif step.type == "visit" and step.mapID then
        return "waypoint"
    elseif step.type == "achievement" then
        return "open_achievement"
    end
    return nil
end

---------------------------------------------------------
-- Following a tale (one per character)

function T:GetFollowed()
    local id = Char().follow
    return id and self:Get(id) or nil
end

function T:SetFollow(taleID)
    Char().follow = taleID
    self:Changed()
    local tale = taleID and self:Get(taleID)
    if tale then
        MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.following"], tale.title))
        self:AnnounceNext()
    end
end

-- Does a step of the followed tale, open now, use this quest?
local function StepUsesQuest(step, questID)
    if step.type == "quest" or step.type == "dungeon" then
        return step.questID == questID
    elseif step.type == "questline" then
        for _, id in ipairs(LineQuests(step.questLineID)) do
            if id == questID then
                return true
            end
        end
    end
    return false
end

function T:IsTaleQuest(tale, questID)
    for _, entry in pairs(self:Index(tale)) do
        if entry.level == "step" and StepUsesQuest(entry.item, questID) then
            return true
        end
    end
    return false
end

-- A new quest of the followed tale's open steps takes the focus.
function T:OnQuestAccepted(questID)
    local tale = self:GetFollowed()
    if not tale then
        return
    end
    self:Invalidate()
    for _, result in ipairs(self:GetNextSteps(tale)) do
        if StepUsesQuest(result.item, questID) then
            MissionFocus:SetFocus(questID)
            return
        end
    end
end

-- Says what comes next (and focuses it when it is already in the log).
function T:AnnounceNext()
    local tale = self:GetFollowed()
    if not tale then
        return
    end
    self:Invalidate()
    local root = self:Evaluate(tale)
    if root.done then
        UIErrorsFrame:AddMessage(string.format(L["MissionFocus.tales.tale_done"], tale.title), 0.4, 1, 0.4)
        return
    end
    local nextStep = self:GetNextSteps(tale)[1]
    if not nextStep then
        return
    end
    if nextStep.inLogQuestID then
        MissionFocus:SetFocus(nextStep.inLogQuestID)
    end
    UIErrorsFrame:AddMessage(string.format(L["MissionFocus.tales.next_msg"], self:Title(nextStep.item, "step")), 1, 0.82, 0)
end

-- "Next tale step" action and /mf tale.
function T:RunNext()
    local tale = self:GetFollowed()
    if not tale then
        MissionFocus_Utils.Print(L["MissionFocus.tales.not_following"])
        return
    end
    self:Invalidate()
    local nextStep = self:GetNextSteps(tale)[1]
    if not nextStep then
        MissionFocus_Utils.Print(L["MissionFocus.tales.nothing_next"])
        return
    end
    self:RunStep(tale, nextStep)
end

---------------------------------------------------------
-- Recording: completed quests are added to a chapter as you play.

function T:GetRecording()
    local record = Char().record
    local tale = record and self:Get(record.tale)
    local chapter = tale and self:Find(tale, record.chapter)
    if not chapter then
        return nil
    end
    return tale, chapter
end

function T:StartRecording(tale, chapter)
    Char().record = { tale = tale.id, chapter = chapter.id }
    MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.record_started"], chapter.title or "", tale.title))
    self:Changed()
end

function T:StopRecording()
    if Char().record then
        Char().record = nil
        MissionFocus_Utils.Print(L["MissionFocus.tales.record_stopped"])
        self:Changed()
    end
end

-- Called on QUEST_TURNED_IN, before the quest's history (accept place, giver) is forgotten.
function T:OnQuestTurnedIn(questID)
    if not questID then
        return
    end
    self:Invalidate()
    local tale, chapter = self:GetRecording()
    if tale then
        local present = false
        for _, step in ipairs(chapter.steps or {}) do
            if step.type == "quest" and step.questID == questID then
                present = true
            end
        end
        if not present then
            local step = { type = "quest", questID = questID }
            local history = MissionFocus_History:Get(questID)
            if history and history.mapID and history.x and history.y and not history.seenOnly then
                step.start = {
                    type = history.giver and "npc" or "location",
                    npc = history.giver,
                    mapID = history.mapID,
                    x = math.floor(history.x * 1000 + 0.5) / 10,
                    y = math.floor(history.y * 1000 + 0.5) / 10,
                }
            end
            self:AddStep(tale, chapter, step)
            MissionFocus_Utils.Print(string.format(L["MissionFocus.tales.recorded"],
                self:QuestTitle(questID) or ("#" .. questID), chapter.title or ""))
        end
    end
    local followed = self:GetFollowed()
    if followed and self:IsTaleQuest(followed, questID) then
        C_Timer.After(0.8, function()
            T:AnnounceNext()
        end)
    end
end

---------------------------------------------------------
-- Core tales: tales shipped with MissionFocus, one file each in default_tales/. Each file adds its
-- tale (tale file text, JSON) to MissionFocus_CoreTales.

local coreCache = nil

-- The core tales, checked like an import. { tale, ... }
function T:GetCoreTales()
    if coreCache then
        return coreCache
    end
    coreCache = {}
    for _, text in ipairs(MissionFocus_CoreTales or {}) do
        local tale, warnings = self:Parse(text)
        if tale then
            coreCache[#coreCache + 1] = tale
            for _, warning in ipairs(warnings) do
                MissionFocus_Utils.Debug("Core tale " .. tale.id .. ": " .. warning)
            end
        else
            MissionFocus_Utils.Debug("Core tale not readable: " .. tostring(warnings))
        end
    end
    return coreCache
end

-- missing: core tales not saved yet; outdated: saved with another version.
function T:CoreStatus()
    local missing, outdated = {}, {}
    for _, core in ipairs(self:GetCoreTales()) do
        -- Only the core tales made for the game being played are offered.
        if core.game == self:CurrentGame() then
            local saved = self:Get(core.id)
            if not saved then
                missing[#missing + 1] = core
            elseif saved.version ~= core.version then
                outdated[#outdated + 1] = core
            end
        end
    end
    return missing, outdated
end

-- Adds the missing core tales; updates the outdated ones when `update` is true (the saved copy is
-- replaced, edits included; progress stays, as step IDs are kept between versions).
function T:InstallCoreTales(update)
    local missing, outdated = self:CoreStatus()
    local added = {}
    for _, core in ipairs(missing) do
        added[#added + 1] = self:Save(DeepCopy(core), "copy")
    end
    if update then
        for _, core in ipairs(outdated) do
            added[#added + 1] = self:Save(DeepCopy(core), "replace")
        end
    end
    return added
end
