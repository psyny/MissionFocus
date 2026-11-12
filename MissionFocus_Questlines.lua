-- MissionFocus_Questlines.lua
-- Questlines the player recently worked on, and where they stand in each of them.
-- The API gives the steps of a questline (C_QuestLine.GetQuestLineQuests) and which quests are
-- done (IsQuestFlaggedCompleted), but not which questlines the player cares about, nor a list of
-- recently finished quests. Finding a quest's questline (GetQuestLineInfo) also needs a map.
-- So we record, per character (db.char.questlines), capped by age:
--   quests[questID] = { lineID (false = none), lastSeen, completedAt }  -- quests seen in the log
--   lines[lineID]   = { name, lastSeen, mapID, flags = {...}, offers = { [questID] = { mapID, x, y } } }
-- "Find Quests" adds the questlines available on the player's maps (GetAvailableQuestLines),
-- with where their quests are offered.
-- The API gives a questline as a flat list, with no branches or prerequisites. Parallel steps
-- only show at runtime: several steps of a line in the log at once, or offered at once.
MissionFocus_Questlines = {}

local QL = MissionFocus_Questlines
local Call = MissionFocus_Utils.Call

local MAX_LINES = 80
local MAX_QUESTS = 300
local LINE_LOOKUP_TRIES = 3 -- questline data can arrive late; give up on a quest after this

QL.FLAGS = { "isCampaign", "isImportant", "isLegendary", "isMeta", "isLocalStory", "isDaily",
    "isCombatAllyQuest", "isHidden", "isAccountCompleted" }

local requestedMaps = {}  -- mapID -> true once RequestQuestLinesForMap was sent this session
local loadRequested = {}  -- questID -> true once RequestLoadQuestByID was sent

local function Store()
    return MissionFocus.db.char.questlines
end

-- Drops the oldest entries (by lastSeen) above max.
local function Prune(tbl, max)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    if #keys <= max then
        return
    end
    table.sort(keys, function(a, b)
        return (tbl[a].lastSeen or 0) < (tbl[b].lastSeen or 0)
    end)
    for i = 1, #keys - max do
        tbl[keys[i]] = nil
    end
end

-- Questline data of a map arrives later (QUESTLINE_UPDATE); ask once per session unless forced.
local function RequestMap(mapID, force)
    if mapID and (force or not requestedMaps[mapID]) then
        requestedMaps[mapID] = true
        Call("C_QuestLine.RequestQuestLinesForMap", mapID)
    end
end

---------------------------------------------------------
-- Recording

-- Stores a questline from a QuestLineInfo (GetQuestLineInfo / GetAvailableQuestLines).
local function RememberLine(info, mapID)
    if type(info) ~= "table" or not info.questLineID then
        return nil
    end
    local lines = Store().lines
    local line = lines[info.questLineID] or {}
    lines[info.questLineID] = line
    line.name = info.questLineName or line.name
    line.lastSeen = time()
    line.mapID = mapID or info.startMapID or line.mapID
    line.flags = line.flags or {}
    for _, flag in ipairs(QL.FLAGS) do
        line.flags[flag] = info[flag] and true or nil
    end
    return line
end

-- Maps worth asking GetQuestLineInfo about: where the quest is, where it was taken, where
-- the player is, and the zones of those.
local function CandidateMaps(questID)
    local maps, seen = {}, {}
    local function Add(mapID)
        if mapID and mapID ~= 0 and not seen[mapID] then
            seen[mapID] = true
            maps[#maps + 1] = mapID
        end
    end
    Add(Call("GetQuestUiMapID", questID, true))
    Add(Call("GetQuestUiMapID", questID))
    Add(Call("C_TaskQuest.GetQuestZoneID", questID))
    Add(MissionFocus_History:GetOriginMap(questID))
    Add(MissionFocus_Location:GetPlayerMap())
    for i = 1, #maps do
        Add(MissionFocus_Location:GetRegion(maps[i], "zone"))
    end
    return maps
end

-- Records a quest of the log and finds its questline. Returns the lineID, or nil.
function QL:RememberQuest(questID)
    local store = Store()
    local entry = store.quests[questID] or {}
    store.quests[questID] = entry
    entry.lastSeen = time()

    if entry.lineID == nil then
        for _, mapID in ipairs(CandidateMaps(questID)) do
            RequestMap(mapID)
            local info = Call("C_QuestLine.GetQuestLineInfo", questID, mapID)
            if RememberLine(info, mapID) then
                entry.lineID = info.questLineID
                break
            end
        end
        if not entry.lineID then
            entry.tries = (entry.tries or 0) + 1
            if entry.tries >= LINE_LOOKUP_TRIES then
                entry.lineID = false -- not part of a questline (as far as the API tells)
            end
        end
    end

    local line = entry.lineID and store.lines[entry.lineID]
    if line then
        line.lastSeen = time()
    end
    return entry.lineID or nil
end

-- Every quest of the log. Called on login, on quest events and when the tab opens.
function QL:Sync()
    for i = 1, (Call("C_QuestLog.GetNumQuestLogEntries") or 0) do
        local info = Call("C_QuestLog.GetInfo", i)
        if info and info.questID and info.questID > 0 and not info.isHeader then
            self:RememberQuest(info.questID)
        end
    end
    Prune(Store().quests, MAX_QUESTS)
    Prune(Store().lines, MAX_LINES)
end

function QL:OnQuestAccepted(questID)
    -- The quest log needs a moment to list the new quest.
    C_Timer.After(0.5, function()
        QL:RememberQuest(questID)
    end)
end

-- The quest is still known to us (recorded while it was in the log).
function QL:OnQuestTurnedIn(questID)
    local entry = Store().quests[questID]
    if not entry then
        self:RememberQuest(questID)
        entry = Store().quests[questID]
    end
    entry.completedAt = time()
    entry.lastSeen = time()
    local line = entry.lineID and Store().lines[entry.lineID]
    if line then
        line.lastSeen = time()
    end
end

---------------------------------------------------------
-- Find Quests: questlines available on the player's map, its zone and the zone's child maps.

local function MapsToScan()
    local maps, seen = {}, {}
    local function Add(mapID)
        if mapID and mapID ~= 0 and not seen[mapID] then
            seen[mapID] = true
            maps[#maps + 1] = mapID
        end
    end
    local zoneType = MissionFocus_Utils.EnumValue("UIMapType", "Zone") or 3
    local continentType = MissionFocus_Utils.EnumValue("UIMapType", "Continent") or 2
    local zoneID
    local id = MissionFocus_Location:GetPlayerMap()
    for _ = 1, 10 do
        local info = id and Call("C_Map.GetMapInfo", id)
        if not info or (info.mapType and info.mapType <= continentType) then
            break
        end
        Add(id)
        if info.mapType == zoneType then
            zoneID = id
            break
        end
        id = info.parentMapID
    end
    if zoneID then
        for _, child in ipairs(Call("C_Map.GetMapChildrenInfo", zoneID) or {}) do
            Add(child.mapID)
        end
    end
    return maps
end

local function AddOffer(line, questID, mapID, x, y)
    line.offer = nil -- old format: one offer per line
    line.offers = line.offers or {}
    if questID then
        line.offers[questID] = { mapID = mapID, x = x, y = y }
    end
end

-- A questline known only by ID and name (BtWQuests data, links between questlines). Keeps what
-- the API told us before.
function QL:EnsureLine(lineID, name, mapID)
    local lines = Store().lines
    local line = lines[lineID] or { flags = {} }
    lines[lineID] = line
    line.name = line.name or name
    line.mapID = line.mapID or mapID
    line.lastSeen = time()
    return line
end

-- request: ask the server again (the answer comes with QUESTLINE_UPDATE). Returns the number of
-- questlines found. BtWQuests (when on) adds the chains it knows can be picked up on these maps.
function QL:Find(request)
    local found, seen = 0, {}
    local maps = MapsToScan()
    for _, mapID in ipairs(maps) do
        RequestMap(mapID, request)
        for _, info in ipairs(Call("C_QuestLine.GetAvailableQuestLines", mapID) or {}) do
            local line = RememberLine(info, mapID)
            if line then
                AddOffer(line, info.questID, mapID, info.x, info.y)
                if not seen[info.questLineID] then
                    seen[info.questLineID] = true
                    found = found + 1
                end
            end
        end
    end
    for _, offer in ipairs(MissionFocus_BtW:Find(maps)) do
        -- Chains without a questline ID: ask the API which questline their next quest is in.
        local info = Call("C_QuestLine.GetQuestLineInfo", offer.questID, offer.mapID)
        local line
        if type(info) == "table" and info.questLineID then
            line = RememberLine(info, offer.mapID)
            offer.lineID = info.questLineID
        elseif offer.lineID then
            line = self:EnsureLine(offer.lineID, offer.name, offer.mapID)
        end
        if line then
            AddOffer(line, offer.questID, offer.mapID, offer.x, offer.y)
            if not seen[offer.lineID] then
                seen[offer.lineID] = true
                found = found + 1
            end
        end
    end
    Prune(Store().lines, MAX_LINES)
    return found
end

---------------------------------------------------------
-- Reading

function QL:GetLine(lineID)
    return Store().lines[lineID]
end

-- { { lineID, line }, ... }
function QL:GetLines()
    local list = {}
    for lineID, line in pairs(Store().lines) do
        list[#list + 1] = { lineID = lineID, line = line }
    end
    return list
end

-- One of MissionFocus_Options.CATEGORIES, from the questline flags.
function QL:GetCategory(line)
    local flags = line.flags or {}
    if flags.isCampaign then return "campaign" end
    if flags.isLegendary then return "legendary" end
    if flags.isImportant then return "important" end
    if flags.isMeta then return "meta" end
    if flags.isDaily then return "recurring" end
    if flags.isLocalStory then return "side" end
    return "questline"
end

-- Quest title; unknown quests are loaded (QUEST_DATA_LOAD_RESULT follows) and return nil.
function QL:GetTitle(questID)
    local title = Call("C_QuestLog.GetTitleForQuestID", questID)
    if not title and not loadRequested[questID] then
        loadRequested[questID] = true
        Call("C_QuestLog.RequestLoadQuestByID", questID)
    end
    return title
end

-- Where the player stands in a questline:
--   steps   = { { questID, title, done, inLog, offered, parallel }, ... } in questline order
--             offered:  seen offered by "Find Quests" (not done, not in the log)
--             parallel: open (in the log or offered) while another step is open too
--   done, total
--   lastDone = the highest step done; open = number of open steps
--   index   = the step that matters now: the first step in the log after the highest step
--             done, else the step right after it. Steps left behind earlier do not count:
--             players often skip one and move on.
--   state   = "current"  (index is in the quest log)
--             "next"     (a step is done, index not started yet)
--             "start"    (nothing done yet, index is the first quest)
--             "complete" (the last step is done)
--             "unknown"  (no steps: neither the API nor BtWQuests listed this questline's quests)
--   fromBtW = true when the API sent no quests and the steps come from BtWQuests
function QL:MakeStep(questID, offers)
    local step = {
        questID = questID,
        title = self:GetTitle(questID),
        done = Call("C_QuestLog.IsQuestFlaggedCompleted", questID) and true or false,
        inLog = Call("C_QuestLog.IsOnQuest", questID) and true or false,
    }
    step.offered = not step.done and not step.inLog and offers ~= nil and offers[questID] ~= nil
    return step
end

local function Offers(line)
    return line and line.offers or {}
end

function QL:GetState(lineID)
    local result = { steps = {}, done = 0, total = 0 }
    local questIDs = Call("C_QuestLine.GetQuestLineQuests", lineID)
    if type(questIDs) ~= "table" or #questIDs == 0 then
        questIDs = MissionFocus_BtW:GetChainQuestIDs(lineID)
        result.fromBtW = questIDs ~= nil
    end
    if type(questIDs) ~= "table" or #questIDs == 0 then
        result.state = "unknown"
        return result
    end
    local offers = Offers(self:GetLine(lineID))
    result.open = 0
    for i, questID in ipairs(questIDs) do
        local step = self:MakeStep(questID, offers)
        result.steps[i] = step
        if step.done then
            result.done = result.done + 1
            result.lastDone = i
        end
        if step.inLog or step.offered then
            result.open = result.open + 1
        end
    end
    result.total = #questIDs
    if result.open > 1 then
        for _, step in ipairs(result.steps) do
            step.parallel = step.inLog or step.offered
        end
    end

    local lastDone = result.lastDone or 0
    for i = lastDone + 1, result.total do
        if result.steps[i].inLog then
            result.index = i
            result.state = "current"
            return result
        end
    end
    if lastDone >= result.total then
        result.state = "complete"
    else
        result.index = lastDone + 1
        result.state = lastDone > 0 and "next" or "start"
    end
    return result
end

---------------------------------------------------------
-- Graph: the steps of a questline as boxes and edges (the detail view).
--   nodes   = { { step, kind, extra, optional, hint }, ... }
--             kind:  "done" | "current" (in the log) | "next" (every step before it is done)
--                    | "available" (offered, steps before it not all done)
--                    | "behind" (not done, a later step is) | "future"
--             extra: a quest BtWQuests lists but the API does not
--   edges   = { { from, to }, ... } (node indexes)
--   prereqs = what comes before the questline (BtWQuests: chains, quests, levels)
--   chainID = the BtWQuests chain, when one matched
--   now     = the node that matters now (scroll target)
-- With BtWQuests the edges are its chain graph (parallel branches included); without, the
-- steps follow each other in API order.

local function Successors(graph)
    local succ, pred = {}, {}
    for i = 1, #graph.nodes do
        succ[i], pred[i] = {}, {}
    end
    for _, edge in ipairs(graph.edges) do
        table.insert(succ[edge.from], edge.to)
        table.insert(pred[edge.to], edge.from)
    end
    return succ, pred
end

-- Drops edge u->v when v can be reached from u another way (keeps the drawing readable).
local function ReduceEdges(graph)
    local succ = Successors(graph)
    local function Reaches(from, target, skipTo)
        local stack, seen = { from }, { [from] = true }
        while #stack > 0 do
            local node = table.remove(stack)
            for _, to in ipairs(succ[node]) do
                if not (node == from and to == skipTo) and not seen[to] then
                    if to == target then
                        return true
                    end
                    seen[to] = true
                    stack[#stack + 1] = to
                end
            end
        end
        return false
    end
    local kept, seen = {}, {}
    for _, edge in ipairs(graph.edges) do
        local key = edge.from .. ">" .. edge.to
        if not seen[key] and edge.from ~= edge.to and not Reaches(edge.from, edge.to, edge.to) then
            kept[#kept + 1] = edge
        end
        seen[key] = true
    end
    graph.edges = kept
end

local function Classify(graph)
    local succ, pred = Successors(graph)
    local doneBelow = {}
    local function DoneBelow(i, visiting)
        if doneBelow[i] ~= nil then
            return doneBelow[i]
        end
        visiting = visiting or {}
        if visiting[i] then
            return false
        end
        visiting[i] = true
        local result = false
        for _, to in ipairs(succ[i]) do
            if graph.nodes[to].step.done or DoneBelow(to, visiting) then
                result = true
                break
            end
        end
        doneBelow[i] = result
        return result
    end
    for i, node in ipairs(graph.nodes) do
        local step = node.step
        local ready = true
        for _, from in ipairs(pred[i]) do
            if not graph.nodes[from].step.done then
                ready = false
                break
            end
        end
        if step.done then
            node.kind = "done"
        elseif step.inLog then
            node.kind = "current"
        elseif DoneBelow(i) then
            node.kind = "behind"
        elseif ready then
            node.kind = "next"
        elseif step.offered then
            node.kind = "available"
        else
            node.kind = "future"
        end
    end
    -- What matters now: a step in the log, else one ready to pick up, else the last done.
    for _, kind in ipairs({ "current", "next", "available" }) do
        for i, node in ipairs(graph.nodes) do
            if node.kind == kind then
                graph.now = i
                return
            end
        end
    end
    for i = #graph.nodes, 1, -1 do
        if graph.nodes[i].kind == "done" then
            graph.now = i
            return
        end
    end
end

function QL:GetGraph(lineID, state)
    local graph = { nodes = {}, edges = {}, prereqs = {} }
    local steps = state.steps
    local questIDs, nodeOfQuest = {}, {}
    for i, step in ipairs(steps) do
        questIDs[i] = step.questID
    end

    local chain = MissionFocus_BtW:GetGraph(lineID, questIDs)
    if chain and #chain.nodes > 0 then
        graph.chainID = chain.chainID
        graph.prereqs = chain.prereqs or {}
        for _, prereq in ipairs(graph.prereqs) do
            if prereq.kind == "chain" and not prereq.name then
                local known = self:GetLine(MissionFocus_BtW:GetLineForChain(prereq.chainID))
                prereq.name = known and known.name
            end
        end
        local stepOf = {}
        for _, step in ipairs(steps) do
            stepOf[step.questID] = step
        end
        local offers = Offers(self:GetLine(lineID))
        for i, node in ipairs(chain.nodes) do
            local step = stepOf[node.questID]
            graph.nodes[i] = {
                step = step or self:MakeStep(node.questID, offers),
                extra = step == nil and #steps > 0,
                optional = node.optional,
                hint = node.hint,
            }
            nodeOfQuest[node.questID] = i
        end
        for _, edge in ipairs(chain.edges) do
            graph.edges[#graph.edges + 1] = { from = edge.from, to = edge.to }
        end
        -- Steps the API lists but BtWQuests does not: placed between their API neighbours.
        local apiOnly = {}
        for _, step in ipairs(steps) do
            if not nodeOfQuest[step.questID] then
                graph.nodes[#graph.nodes + 1] = { step = step }
                nodeOfQuest[step.questID] = #graph.nodes
                apiOnly[#graph.nodes] = true
            end
        end
        for k, step in ipairs(steps) do
            local node = nodeOfQuest[step.questID]
            if apiOnly[node] then
                if steps[k - 1] then
                    graph.edges[#graph.edges + 1] = { from = nodeOfQuest[steps[k - 1].questID], to = node }
                end
                if steps[k + 1] then
                    graph.edges[#graph.edges + 1] = { from = node, to = nodeOfQuest[steps[k + 1].questID] }
                end
            end
        end
    else
        for i, step in ipairs(steps) do
            graph.nodes[i] = { step = step }
            if i > 1 then
                graph.edges[#graph.edges + 1] = { from = i - 1, to = i }
            end
        end
    end

    ReduceEdges(graph)
    Classify(graph)
    return graph
end

---------------------------------------------------------
-- Going there

-- Map position of a quest offer: from Find Quests, else asked on the questline's known maps.
function QL:GetOfferPosition(lineID, questID)
    local line = self:GetLine(lineID)
    if not line then
        return nil
    end
    local offer = (line.offers and line.offers[questID])
        or (line.offer and line.offer.questID == questID and line.offer)
    if offer and offer.x and offer.x > 0 then
        return offer.mapID, offer.x, offer.y
    end
    -- Added one by one: a nil in a table constructor would end ipairs early.
    local maps = {}
    local function Add(mapID)
        if mapID then
            maps[#maps + 1] = mapID
        end
    end
    Add(line.mapID)
    Add(line.mapID and MissionFocus_Location:GetRegion(line.mapID, "zone"))
    Add(MissionFocus_Location:GetPlayerMap())
    for _, mapID in ipairs(maps) do
        local info = mapID and Call("C_QuestLine.GetQuestLineInfo", questID, mapID)
        if type(info) == "table" and info.x and info.x > 0 then
            return mapID, info.x, info.y
        end
    end
    -- BtWQuests: where the quest giver stands.
    local _, mapID, x, y = MissionFocus_BtW:GetQuestGiver(questID, maps)
    if mapID and x and y then
        return mapID, x, y
    end
    return nil
end

-- What the player can do about a step: "focus" (it is in the log) or "waypoint" (not started).
function QL:GetStepAction(step)
    if not step or step.done then
        return nil
    end
    return step.inLog and "focus" or "waypoint"
end

local function MapName(mapID)
    local info = mapID and Call("C_Map.GetMapInfo", mapID)
    return info and info.name or "?"
end
QL.MapName = MapName

function QL:RunStepAction(lineID, step)
    local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
    local action = self:GetStepAction(step)
    if action == "focus" then
        if not Call("C_QuestLog.GetQuestWatchType", step.questID) then
            Call("C_QuestLog.AddQuestWatch", step.questID)
        end
        MissionFocus:PickFocus(step.questID)
    elseif action == "waypoint" then
        local mapID, x, y = self:GetOfferPosition(lineID, step.questID)
        if not mapID then
            MissionFocus_Utils.Print(L["MissionFocus.questlines.no_position"])
            return
        end
        self:SetWaypoint(mapID, x, y, step.title or ("#" .. step.questID))
    end
end

-- Map pin + super-track on it. x, y in 0..1. Also used by Adventurer's Tales.
function QL:SetWaypoint(mapID, x, y, title)
    local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
    if Call("C_Map.CanSetUserWaypointOnMap", mapID) == false then
        MissionFocus_Utils.Print(string.format(L["MissionFocus.questlines.no_waypoint_map"], MapName(mapID)))
        return false
    end
    local point = Call("UiMapPoint.CreateFromCoordinates", mapID, x, y)
    if not point then
        return false
    end
    Call("C_Map.SetUserWaypoint", point)
    Call("C_SuperTrack.SetSuperTrackedUserWaypoint", true)
    MissionFocus_Utils.Print(string.format(L["MissionFocus.questlines.waypoint_set"], title or "?",
        MapName(mapID), x * 100, y * 100))
    return true
end
