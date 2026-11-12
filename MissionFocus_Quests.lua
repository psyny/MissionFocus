-- MissionFocus_Quests.lua
-- Everything MissionFocus knows about quests comes from the WoW API here.
-- No quest list is stored: "tracked" is the watch list and "focused" is the super-tracked quest.
MissionFocus_Quests = {}

local Q = MissionFocus_Quests
local Call = MissionFocus_Utils.Call
local EnumValue = MissionFocus_Utils.EnumValue

-- The last quest we showed, used when nothing is super-tracked (e.g. a map pin is).
Q.lastFocusQuestID = nil

Q.CATEGORY_COLORS = {
    campaign  = { r = 1.00, g = 0.55, b = 0.10 },
    legendary = { r = 1.00, g = 0.50, b = 0.00 },
    important = { r = 0.80, g = 0.45, b = 1.00 },
    meta      = { r = 0.40, g = 0.80, b = 1.00 },
    questline = { r = 1.00, g = 0.82, b = 0.00 },
    side      = { r = 1.00, g = 0.82, b = 0.00 },
    group     = { r = 0.30, g = 0.60, b = 1.00 },
    calling   = { r = 0.40, g = 1.00, b = 0.80 },
    recurring = { r = 0.30, g = 0.75, b = 1.00 },
    event     = { r = 1.00, g = 0.30, b = 0.30 },
    world     = { r = 0.55, g = 0.85, b = 0.35 },
    bonus     = { r = 0.85, g = 0.70, b = 0.35 },
    elsewhere = { r = 0.35, g = 0.35, b = 0.35 }, -- tray group for quests off the player's continent
    -- Soft objectives (not quest categories, see MissionFocus_Soft.lua)
    scenario  = { r = 0.95, g = 0.75, b = 0.35 },
    delve     = { r = 0.90, g = 0.60, b = 0.25 },
}

---------------------------------------------------------
-- Classification

local function TagSet(enumName, names)
    local set = {}
    for _, name in ipairs(names) do
        local value = EnumValue(enumName, name)
        if value ~= nil then
            set[value] = true
        end
    end
    return set
end

local groupTags, eventWorldQuestTypes

local function EnsureTagSets()
    if groupTags then
        return
    end
    groupTags = TagSet("QuestTag", { "Group", "Dungeon", "Raid", "Heroic", "Raid10", "Raid25", "Scenario", "Delve" })
    eventWorldQuestTypes = TagSet("QuestTagType", { "Invasion", "InvasionWrapper", "FactionAssault", "Threat", "WorldBoss", "Contribution" })
end

-- Returns one of MissionFocus_Options.CATEGORIES.
function Q:GetCategory(questID, info)
    EnsureTagSets()

    local classification = Call("C_QuestInfoSystem.GetQuestClassification", questID)
    local function Is(name)
        local value = EnumValue("QuestClassification", name)
        return value ~= nil and classification == value
    end

    local tagInfo = Call("C_QuestLog.GetQuestTagInfo", questID)

    if Call("C_QuestLog.IsWorldQuest", questID) or Is("WorldQuest") then
        if tagInfo and tagInfo.worldQuestType and eventWorldQuestTypes[tagInfo.worldQuestType] then
            return "event"
        end
        return "world"
    end
    if Is("Threat") then
        return "event"
    end
    if Is("BonusObjective") or Call("C_QuestLog.IsQuestTask", questID) or (info and info.isTask) then
        return "bonus"
    end
    if Is("Campaign") or (info and info.campaignID and info.campaignID > 0) then
        return "campaign"
    end
    if Is("Legendary") then
        return "legendary"
    end
    if Is("Important") then
        return "important"
    end
    if Is("Meta") then
        return "meta"
    end
    if Is("Calling") or Call("C_QuestLog.IsQuestCalling", questID) then
        return "calling"
    end
    local defaultFrequency = EnumValue("QuestFrequency", "Default") or 0
    if Is("Recurring") or (info and info.frequency and info.frequency ~= defaultFrequency) then
        return "recurring"
    end
    if tagInfo and tagInfo.tagID and groupTags[tagInfo.tagID] then
        return "group"
    end
    if Is("Questline") then
        return "questline"
    end
    return "side"
end

---------------------------------------------------------
-- Category order (sanitized: unknown keys dropped, new categories appended)

function Q:GetCategoryOrder()
    local saved = MissionFocus_Options.db.category_order or {}
    local valid, seen, order = {}, {}, {}
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        valid[key] = true
    end
    for i = 1, #MissionFocus_Options.CATEGORIES do
        local key = saved[i]
        if key and valid[key] and not seen[key] then
            seen[key] = true
            order[#order + 1] = key
        end
    end
    for _, key in ipairs(MissionFocus_Options.CATEGORIES) do
        if not seen[key] then
            order[#order + 1] = key
        end
    end
    return order
end

---------------------------------------------------------
-- Tracked quests

local function GetLogInfo(questID)
    local logIndex = Call("C_QuestLog.GetLogIndexForQuestID", questID)
    local info = logIndex and Call("C_QuestLog.GetInfo", logIndex)
    return logIndex, info
end

local function GetTitle(questID, info)
    return Call("C_QuestLog.GetTitleForQuestID", questID) or (info and info.title) or ("Quest " .. questID)
end

-- Sorted list of tracked quests: { questID, title, category, watchIndex, isWorldQuest }
-- Sorted list of quests: { questID, title, category, watchIndex, isWorldQuest, isTracked }
-- Tracked = on the watch list. Untracked quests of the quest log are included too (flagged);
-- whether they are listed is decided by the quest pool (per-category tracked/untracked options).
function Q:GetQuests()
    local list, seen = {}, {}

    local function Add(questID, watchIndex, isWorldQuest, isTracked)
        if not questID or questID == 0 or seen[questID] then
            return
        end
        seen[questID] = true
        local logIndex, info = GetLogInfo(questID)
        list[#list + 1] = {
            questID = questID,
            logIndex = logIndex,
            title = GetTitle(questID, info),
            category = self:GetCategory(questID, info),
            watchIndex = watchIndex,
            isWorldQuest = isWorldQuest,
            isTracked = isTracked,
        }
    end

    for i = 1, (Call("C_QuestLog.GetNumQuestWatches") or 0) do
        Add(Call("C_QuestLog.GetQuestIDForQuestWatchIndex", i), i, false, true)
    end
    for i = 1, (Call("C_QuestLog.GetNumWorldQuestWatches") or 0) do
        Add(Call("C_QuestLog.GetQuestIDForWorldQuestWatchIndex", i), 1000 + i, true, true)
    end

    -- Untracked quests of the quest log (headers and hidden entries skipped).
    for i = 1, (Call("C_QuestLog.GetNumQuestLogEntries") or 0) do
        local info = Call("C_QuestLog.GetInfo", i)
        if info and info.questID and not info.isHeader and not info.isHidden then
            Add(info.questID, 2000 + i, false, false)
        end
    end

    -- A world quest can be super-tracked (e.g. from the map) without being watched or in the log.
    local superID = Call("C_SuperTrack.GetSuperTrackedQuestID")
    if superID and superID > 0 and not seen[superID] and Call("C_QuestLog.IsWorldQuest", superID) then
        Add(superID, 5000, true, false)
    end

    -- Category priority, then tracked before untracked, then watch / log order.
    local rank = {}
    for i, key in ipairs(self:GetCategoryOrder()) do
        rank[key] = i
    end
    table.sort(list, function(a, b)
        local ra, rb = rank[a.category] or 99, rank[b.category] or 99
        if ra ~= rb then
            return ra < rb
        end
        if a.isTracked ~= b.isTracked then
            return a.isTracked
        end
        return a.watchIndex < b.watchIndex
    end)

    return list
end

-- The quest pool: the single source of truth for both the tray and cycling.
-- Tracked quests (priority order) with the user's filters applied:
--   1. region grouping: quests outside the player's region move to the "Not in <region>" group, last
--   2. quest categories: "Not in <region>" quests must pass both their group and their own category
-- Display-only rules (excluding the focused quest, Maximum Entries) belong to the tray, and the
-- "Not in <region>" cycling rule belongs to cycling.
function Q:GetQuestPool(list)
    local db = MissionFocus_Options.db
    list = MissionFocus_Location:GroupByRegion(list)
    local pool = {}
    for _, entry in ipairs(list) do
        local shown = entry.isTracked and db.tray_categories or db.tray_categories_untracked
        if shown[entry.category] and (not entry.realCategory or shown[entry.realCategory]) then
            pool[#pool + 1] = entry
        end
    end
    return pool
end

local function IndexOf(list, questID)
    for i, entry in ipairs(list) do
        if entry.questID == questID then
            return i
        end
    end
    return nil
end

-- Which quest the panel shows.
function Q:GetFocusQuestID(list)
    local superID = Call("C_SuperTrack.GetSuperTrackedQuestID")
    if superID and superID > 0 and IndexOf(list, superID) then
        return superID
    end
    if self.lastFocusQuestID and IndexOf(list, self.lastFocusQuestID) then
        return self.lastFocusQuestID
    end
    -- Nothing focused yet: the first tracked quest (untracked ones are only focused on purpose).
    for _, entry in ipairs(list) do
        if entry.isTracked then
            return entry.questID
        end
    end
    return nil
end

---------------------------------------------------------
-- Cycling

local function Wrap(i, n)
    return ((i - 1) % n) + 1
end

-- Returns the questID to focus when cycling in direction (1 or -1), or nil to stay.
-- sameCategory / nextWhenEmpty: the focus mode's Category Priority settings.
function Q:GetCycleTarget(list, currentID, direction, sameCategory, nextWhenEmpty)
    local n = #list
    if n == 0 then
        return nil
    end
    local pos = IndexOf(list, currentID)
    if not pos then
        return direction > 0 and list[1].questID or list[n].questID
    end
    if n == 1 then
        return nil
    end

    if not sameCategory then
        return list[Wrap(pos + direction, n)].questID
    end

    local category = list[pos].category
    local same = {}
    local samePos
    for _, entry in ipairs(list) do
        if entry.category == category then
            same[#same + 1] = entry
            if entry.questID == currentID then
                samePos = #same
            end
        end
    end
    if #same > 1 then
        return same[Wrap(samePos + direction, #same)].questID
    end

    if not nextWhenEmpty then
        return nil
    end
    -- The list is sorted by category priority: walk until the category changes,
    -- then jump to the first quest of that category.
    for step = 1, n - 1 do
        local entry = list[Wrap(pos + direction * step, n)]
        if entry.category ~= category then
            for _, candidate in ipairs(list) do
                if candidate.category == entry.category then
                    return candidate.questID
                end
            end
        end
    end
    return nil
end

-- First quest of the next (direction 1) or previous (-1) category of a sorted pool.
-- Categories follow the pool order: cycle priority, with the "Not in <region>" group last.
-- Returns nil when there is no other category to jump to.
function Q:GetCategoryJumpTarget(pool, currentID, direction)
    local categories, firstQuest = {}, {}
    for _, entry in ipairs(pool) do
        if not firstQuest[entry.category] then
            firstQuest[entry.category] = entry.questID
            categories[#categories + 1] = entry.category
        end
    end
    local n = #categories
    if n == 0 then
        return nil
    end

    local currentIndex
    for _, entry in ipairs(pool) do
        if entry.questID == currentID then
            for i, category in ipairs(categories) do
                if category == entry.category then
                    currentIndex = i
                end
            end
        end
    end

    if not currentIndex then
        -- Focused quest is outside the pool: start from the first / last category.
        return firstQuest[categories[direction > 0 and 1 or n]]
    end
    if n == 1 then
        return nil
    end
    return firstQuest[categories[Wrap(currentIndex + direction, n)]]
end

-- Nearest quest of a list, by straight-line distance. Quests with no map point, or on another
-- continent (distance across continents is meaningless), are skipped. Returns nil if none.
function Q:FindNearest(list)
    local nearestID, nearestDistance
    for _, entry in ipairs(list) do
        local distanceSq, onContinent = Call("C_QuestLog.GetDistanceSqToQuest", entry.questID)
        if distanceSq and onContinent ~= false and (not nearestDistance or distanceSq < nearestDistance) then
            nearestID, nearestDistance = entry.questID, distanceSq
        end
    end
    return nearestID
end

---------------------------------------------------------
-- Details of a single quest

-- { questID, title, category, isComplete, isFailed, objectives = { { text, finished } }, finished, total }
function Q:GetQuestDetails(questID, category)
    local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
    local logIndex, info = GetLogInfo(questID)
    local details = {
        questID = questID,
        logIndex = logIndex,
        title = GetTitle(questID, info),
        category = category or self:GetCategory(questID, info),
        isComplete = Call("C_QuestLog.IsComplete", questID) and true or false,
        isFailed = Call("C_QuestLog.IsFailed", questID) and true or false,
        objectives = {},
        finished = 0,
        total = 0,
    }

    local objectives = Call("C_QuestLog.GetQuestObjectives", questID) or {}
    for _, objective in ipairs(objectives) do
        local text = objective.text or ""
        local progress
        if objective.type == "progressbar" then
            -- Blizzard's text usually already contains the percentage ("Slay invaders (45%)").
            -- Keep the percentage as a number (drawn as a bar) and strip it from the text.
            progress = Call("GetQuestProgressBarPercent", questID)
            if progress then
                progress = math.max(0, math.min(100, progress))
            end
            text = text:gsub("%s*%(%s*%d+%s*%%%s*%)", ""):gsub("^%s*%d+%s*%%%s*$", "")
            text = strtrim(text)
            if text == "" then
                text = L["MissionFocus.ui.progress"]
            end
        end
        if text ~= "" then
            details.objectives[#details.objectives + 1] = {
                text = text,
                finished = objective.finished and true or false,
                progress = progress, -- 0-100 for progress bar objectives, nil otherwise
            }
            details.total = details.total + 1
            if objective.finished then
                details.finished = details.finished + 1
            end
        end
    end

    if details.isFailed then
        details.objectives[#details.objectives + 1] = { text = L["MissionFocus.ui.failed"], finished = false, failed = true }
    elseif details.isComplete then
        local completionText = logIndex and Call("GetQuestLogCompletionText", logIndex)
        if not completionText or completionText == "" then
            completionText = L["MissionFocus.ui.ready_turn_in"]
        end
        details.objectives = { { text = completionText, finished = true } }
    end

    return details
end

-- Quest description and objectives text from the quest log, or nil. GetQuestLogQuestText reads
-- the log's selected quest: select it briefly, then restore the player's selection.
function Q:GetQuestText(questID)
    local logIndex = questID and Call("C_QuestLog.GetLogIndexForQuestID", questID)
    if not logIndex then
        return nil
    end
    local previous = Call("C_QuestLog.GetSelectedQuest")
    Call("C_QuestLog.SetSelectedQuest", questID)
    local description, objectivesText = Call("GetQuestLogQuestText", logIndex)
    if previous and previous ~= 0 and previous ~= questID then
        Call("C_QuestLog.SetSelectedQuest", previous)
    end
    return description, objectivesText
end

-- Light summary for tray entries: finished / total objectives.
function Q:GetProgress(questID)
    local objectives = Call("C_QuestLog.GetQuestObjectives", questID) or {}
    local finished, total = 0, 0
    for _, objective in ipairs(objectives) do
        total = total + 1
        if objective.finished then
            finished = finished + 1
        end
    end
    return finished, total, Call("C_QuestLog.IsComplete", questID) and true or false
end

---------------------------------------------------------
-- Actions

function Q:Focus(questID)
    if not questID then
        return
    end
    self.lastFocusQuestID = questID
    Call("C_SuperTrack.SetSuperTrackedQuestID", questID)
end

function Q:Untrack(entry)
    if entry.isWorldQuest then
        Call("C_QuestLog.RemoveWorldQuestWatch", entry.questID)
    else
        Call("C_QuestLog.RemoveQuestWatch", entry.questID)
    end
end

function Q:Track(entry)
    if entry.isWorldQuest then
        Call("C_QuestLog.AddWorldQuestWatch", entry.questID)
    else
        Call("C_QuestLog.AddQuestWatch", entry.questID)
    end
end

function Q:ToggleTracking(entry)
    if entry.isTracked then
        self:Untrack(entry)
    else
        self:Track(entry)
    end
end

function Q:OpenInQuestLog(questID)
    if MissionFocus_Utils.HasAPI("QuestMapFrame_OpenToQuestDetails") then
        Call("QuestMapFrame_OpenToQuestDetails", questID)
    else
        Call("ToggleQuestLog")
    end
end
