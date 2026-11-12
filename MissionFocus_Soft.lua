-- MissionFocus_Soft.lua
-- Soft objectives: objectives that come and go with where the player is, not with the quest log.
--   * scenarios (delves, world scenarios, ...): the current step and its criteria
--   * world quests and bonus objectives whose area the player is standing in
-- The Blizzard tracker shows these in their own sections; with it hidden they need a place here.
--
-- Display option (soft_objectives):
--   "off"       nothing
--   "main"      the panel shows the soft objective instead of the focused quest. The quest's
--               super-track is left alone, so when the objective ends the panel is back on the
--               previous quest by itself. Cycling / picking a quest sends it to the tray.
--   "secondary" a second block under the panel lists the soft objectives
MissionFocus_Soft = {}

local S = MissionFocus_Soft
local Call = MissionFocus_Utils.Call
local ReadableString = MissionFocus_Utils.ReadableString

-- Keys the player sent away (main mode). Forgotten once the objective is gone, so it takes the
-- panel again the next time it appears.
S.dismissed = {}
-- Key the player picked from the tray (main mode); wins over the default order.
S.pinned = nil

local function L()
    return LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
end

function S:GetMode()
    local db = MissionFocus_Options.db
    return db and db.soft_objectives or "off"
end

function S:IsEnabled()
    return self:GetMode() ~= "off"
end

---------------------------------------------------------
-- Scenarios (delves, scenarios)

-- Criteria of the current step, modern API first, then the older C_Scenario one.
local function GetCriteria(index)
    local info = Call("C_ScenarioInfo.GetCriteriaInfo", index)
    if type(info) == "table" then
        return info
    end
    local description, _, completed, quantity, totalQuantity, _, _, quantityString, _, _, _, failed, isWeighted =
        Call("C_Scenario.GetCriteriaInfo", index)
    if description == nil then
        return nil
    end
    return {
        description = description,
        completed = completed,
        quantity = quantity,
        totalQuantity = totalQuantity,
        quantityString = quantityString,
        failed = failed,
        isWeightedProgress = isWeighted,
    }
end

local function GetStep()
    local step = Call("C_ScenarioInfo.GetScenarioStepInfo")
    if type(step) == "table" then
        return step
    end
    local title, description, numCriteria = Call("C_Scenario.GetStepInfo")
    if title == nil and numCriteria == nil then
        return nil
    end
    return { title = title, description = description, numCriteria = numCriteria }
end

local function GetScenario()
    local info = Call("C_ScenarioInfo.GetScenarioInfo")
    if type(info) == "table" then
        return info
    end
    local name, currentStage, numStages = Call("C_Scenario.GetInfo")
    if name == nil then
        return nil
    end
    return { name = name, currentStage = currentStage, numStages = numStages }
end

local function CriteriaObjective(criteria)
    local text = ReadableString(criteria.description) or ""
    local objective = {
        finished = criteria.completed and true or false,
        failed = criteria.failed and true or nil,
    }
    if criteria.isWeightedProgress then
        -- Weighted criteria: quantity is a percentage, drawn as a bar like quest progress bars.
        objective.progress = math.max(0, math.min(100, tonumber(criteria.quantity) or 0))
        objective.text = text ~= "" and text or L()["MissionFocus.ui.progress"]
        return objective
    end
    local total = tonumber(criteria.totalQuantity) or 0
    if total > 1 and not text:find("%d+%s*/%s*%d+") then
        local have = ReadableString(criteria.quantityString) or tostring(criteria.quantity or 0)
        -- quantityString may already be "3/10".
        if not have:find("/") then
            have = have .. "/" .. total
        end
        text = have .. " " .. text
    end
    objective.text = text
    return objective
end

local function ScenarioDetails()
    if not Call("C_Scenario.IsInScenario") then
        return nil
    end
    local info = GetScenario()
    if not info then
        return nil
    end
    local step = GetStep() or {}
    local name = ReadableString(info.name)
    local stepTitle = ReadableString(step.title)

    local isDelve = Call("C_PartyInfo.IsDelveInProgress") and true or false
    local category = isDelve and "delve" or "scenario"
    local categoryText = L()["MissionFocus.category." .. category]
    local numStages = tonumber(info.numStages) or 0
    local stage = tonumber(info.currentStage)
    if numStages > 1 and stage then
        categoryText = categoryText .. " · " .. string.format(L()["MissionFocus.ui.soft_stage"], math.min(stage, numStages), numStages)
    end

    local details = {
        soft = true,
        key = "scenario:" .. (name or "?"),
        category = category,
        categoryText = categoryText,
        title = name or stepTitle or L()["MissionFocus.category." .. category],
        description = ReadableString(step.description),
        objectives = {},
    }
    -- The step title is the current goal: show it first when it adds something to the name.
    if stepTitle and stepTitle ~= details.title then
        details.subtitle = stepTitle
    end

    for i = 1, (tonumber(step.numCriteria) or 0) do
        local criteria = GetCriteria(i)
        if criteria then
            local objective = CriteriaObjective(criteria)
            if objective.text ~= "" then
                details.objectives[#details.objectives + 1] = objective
            end
        end
    end
    -- Steps without criteria (some delve stages) only have a description.
    if #details.objectives == 0 and details.description then
        details.objectives[1] = { text = details.description }
    end
    if info.isComplete and #details.objectives == 0 then
        details.objectives[1] = { text = L()["MissionFocus.ui.soft_complete"], finished = true }
    end
    return details
end

---------------------------------------------------------
-- Task quests in range (world quests, bonus objectives)

local function IsInArea(questID)
    if MissionFocus_Utils.HasAPI("GetTaskInfo") then
        return Call("GetTaskInfo", questID) and true or false
    end
    return Call("C_TaskQuest.IsActive", questID) and true or false
end

local function TaskQuestIDs()
    local ids, seen = {}, {}
    local function Add(questID)
        if questID and questID > 0 and not seen[questID] then
            seen[questID] = true
            ids[#ids + 1] = questID
        end
    end
    local tasks = Call("GetTasksTable")
    if type(tasks) == "table" then
        for _, questID in ipairs(tasks) do
            Add(questID)
        end
    end
    -- Fallback / extra source: task entries of the quest log (often hidden entries).
    for i = 1, (Call("C_QuestLog.GetNumQuestLogEntries") or 0) do
        local info = Call("C_QuestLog.GetInfo", i)
        if info and info.questID and info.isTask and not info.isHeader then
            Add(info.questID)
        end
    end
    return ids
end

function S:IsActiveTask(questID)
    return questID and Call("C_QuestLog.IsQuestTask", questID) and IsInArea(questID) or false
end

local function TaskDetails()
    local Q = MissionFocus_Quests
    local list = {}
    for _, questID in ipairs(TaskQuestIDs()) do
        if IsInArea(questID) and not Call("C_QuestLog.IsQuestFlaggedCompleted", questID) then
            local details = Q:GetQuestDetails(questID)
            details.soft = true
            details.key = "task:" .. questID
            details.categoryText = L()["MissionFocus.category." .. details.category] or details.category
            details.distanceSq = Call("C_QuestLog.GetDistanceSqToQuest", questID)
            list[#list + 1] = details
        end
    end
    table.sort(list, function(a, b)
        if a.distanceSq and b.distanceSq then
            return a.distanceSq < b.distanceSq
        end
        if a.distanceSq or b.distanceSq then
            return a.distanceSq ~= nil
        end
        return a.questID < b.questID
    end)
    return list
end

---------------------------------------------------------
-- Active soft objectives

-- Ordered list of details (scenario first, then nearest task first). excludeQuestID: the focused
-- quest, already shown as a quest. Also forgets dismissals of objectives that ended.
function S:GetActive(excludeQuestID)
    local list = {}
    if not self:IsEnabled() then
        return list
    end
    local scenario = ScenarioDetails()
    if scenario then
        list[1] = scenario
    end
    for _, details in ipairs(TaskDetails()) do
        if details.questID ~= excludeQuestID then
            list[#list + 1] = details
        end
    end

    local present = {}
    for _, details in ipairs(list) do
        present[details.key] = true
    end
    for key in pairs(self.dismissed) do
        if not present[key] then
            self.dismissed[key] = nil
        end
    end
    if self.pinned and not present[self.pinned] then
        self.pinned = nil
    end
    return list
end

-- Main mode: which soft objective takes the panel, or nil.
function S:PickShown(list)
    if self.pinned then
        for _, details in ipairs(list) do
            if details.key == self.pinned then
                return details
            end
        end
    end
    for _, details in ipairs(list) do
        if not self.dismissed[details.key] then
            return details
        end
    end
    return nil
end

-- Main mode: give the panel back to the quests (the objectives stay listed in the tray).
function S:DismissAll()
    if self:GetMode() ~= "main" then
        return
    end
    for _, details in ipairs(self.lastActive or {}) do
        self.dismissed[details.key] = true
    end
    self.pinned = nil
end

-- Main mode: show this objective on the panel again.
function S:Show(key)
    self.dismissed[key] = nil
    self.pinned = key
end

-- True when the panel currently shows a soft objective in place of the focused quest.
function S:IsShownOnPanel()
    return self.shownOnPanel ~= nil
end
