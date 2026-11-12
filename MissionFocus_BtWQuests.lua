-- MissionFocus_BtWQuests.lua
-- Optional link to the BtWQuests addon (option "btwquests_enabled"). BtWQuests keeps a hand-made
-- database of quest chains: the order of their quests as a graph (parallel branches included),
-- the chains that come before them, quest givers and their locations.
-- The WoW API stays the source of truth (which quests a questline has, what is done, what is in
-- the log); this data only adds structure and places.
--
-- Safety: every read of BtWQuests goes through Safe(). An error there is logged (debug option),
-- and after MAX_ERRORS errors the link turns itself off until the next reload, so a broken or
-- changed BtWQuests never breaks MissionFocus.
--
-- BtWQuests globals used: BtWQuestsDatabase (chains, quests, NPCs, maps), BtWQuestsCharacters
-- (the player, for faction/class variations), BtWQuestsFrame (to open a chain in its window).
MissionFocus_BtW = {}

local BTW = MissionFocus_BtW
local Call = MissionFocus_Utils.Call

local MAX_ERRORS = 5
local MIN_MATCHES = 2 -- quests a chain must share with a questline to be matched by its quests

local errors = 0
local brokenForSession = false
local index = nil      -- built from the raw chain tables, see BuildIndex
local lineCache = {}   -- lineID -> chainID, or false (no chain)

---------------------------------------------------------
-- Safety

local function L()
    return LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
end

local function Safe(fn, ...)
    if brokenForSession then
        return nil
    end
    local results = { pcall(fn, ...) }
    if results[1] then
        return unpack(results, 2, table.maxn(results))
    end
    errors = errors + 1
    MissionFocus_Utils.Debug("BtWQuests error: " .. tostring(results[2]))
    if errors >= MAX_ERRORS then
        brokenForSession = true
        MissionFocus_Utils.Print(L()["MissionFocus.btw.disabled_errors"])
    end
    return nil
end

local function Database()
    local db = rawget(_G, "BtWQuestsDatabase")
    if type(db) == "table" and type(db.GetChainByID) == "function" then
        return db
    end
    return nil
end

local function Player()
    local characters = rawget(_G, "BtWQuestsCharacters")
    if type(characters) == "table" and type(characters.GetPlayer) == "function" then
        return characters:GetPlayer()
    end
    return nil
end

-- BtWQuests is loaded (whatever our option says).
function BTW:IsInstalled()
    return Database() ~= nil
end

-- The link is on and usable.
function BTW:IsEnabled()
    local options = MissionFocus_Options.db
    return options ~= nil and options.btwquests_enabled ~= false and not brokenForSession
        and Database() ~= nil and Player() ~= nil
end

-- BtWQuests loads its expansion data on demand: drop what we built from it.
function BTW:Invalidate()
    index = nil
    lineCache = {}
end

do
    local events = CreateFrame("Frame")
    events:RegisterEvent("ADDON_LOADED")
    events:SetScript("OnEvent", function(_, _, name)
        if type(name) == "string" and name:sub(1, 9) == "BtWQuests" then
            BTW:Invalidate()
        end
    end)
end

---------------------------------------------------------
-- Index: questline -> chain, quest -> chains. Built from the raw chain tables (no BtWQuests
-- objects are created for chains we never show).

-- Calls out(questID) for every quest of a raw chain item (variations and groups included).
local function CollectQuestIDs(item, parentType, out)
    if type(item) ~= "table" then
        return
    end
    local itemType = item.type or parentType
    if type(item.variations) == "table" then
        for _, variation in ipairs(item.variations) do
            CollectQuestIDs(variation, itemType, out)
        end
        return
    end
    if item[1] ~= nil then
        for _, sub in ipairs(item) do
            CollectQuestIDs(sub, itemType, out)
        end
        return
    end
    if itemType == "quest" then
        if type(item.id) == "number" then
            out(item.id)
        end
        if type(item.ids) == "table" then
            for _, id in ipairs(item.ids) do
                out(id)
            end
        end
    end
end

-- chainID -> raw chain table, from the chains added one by one and the chain tables.
local function ForEachRawChain(db, fn)
    local seen = {}
    if type(db.chain) == "table" then
        for id, chain in next, db.chain do -- next: skips the lazy-loading metatable
            if type(chain) == "table" then
                seen[id] = true
                fn(id, chain)
            end
        end
    end
    if type(db.chainList) == "table" then
        for _, source in ipairs(db.chainList) do
            for id, chain in next, source do
                if not seen[id] and type(chain) == "table" then
                    seen[id] = true
                    fn(id, chain)
                end
            end
        end
    end
end

local function AddLines(lineToChain, questline, chainID)
    if type(questline) == "number" then
        lineToChain[questline] = lineToChain[questline] or chainID
    elseif type(questline) == "table" then
        for _, id in ipairs(questline) do
            AddLines(lineToChain, id, chainID)
        end
    end
end

local function BuildIndex()
    local db = Database()
    local built = { lineToChain = {}, questToChains = {}, chainToLine = {} }
    ForEachRawChain(db, function(chainID, chain)
        AddLines(built.lineToChain, chain.questline, chainID)
        if type(chain.questline) == "number" then
            built.chainToLine[chainID] = chain.questline
        end
        local seen = {}
        for _, item in ipairs(type(chain.items) == "table" and chain.items or {}) do
            CollectQuestIDs(item, nil, function(questID)
                if not seen[questID] then
                    seen[questID] = true
                    local list = built.questToChains[questID] or {}
                    list[#list + 1] = chainID
                    built.questToChains[questID] = list
                end
            end)
        end
    end)
    return built
end

local function Index()
    if not index then
        index = BuildIndex()
    end
    return index
end

-- The chain that describes a questline: by the questline ID BtWQuests stores, else the chain
-- sharing the most quests with it.
local function FindChain(lineID, questIDs)
    local built = Index()
    if built.lineToChain[lineID] then
        return built.lineToChain[lineID]
    end
    local votes, best, bestVotes = {}, nil, 0
    for _, questID in ipairs(questIDs or {}) do
        for _, chainID in ipairs(built.questToChains[questID] or {}) do
            votes[chainID] = (votes[chainID] or 0) + 1
            if votes[chainID] > bestVotes then
                best, bestVotes = chainID, votes[chainID]
            end
        end
    end
    local needed = math.min(MIN_MATCHES, #(questIDs or {}))
    if best and bestVotes >= math.max(1, needed) then
        return best
    end
    return nil
end

function BTW:GetChainForLine(lineID, questIDs)
    if not self:IsEnabled() or not lineID then
        return nil
    end
    local cached = lineCache[lineID]
    if cached ~= nil then
        return cached or nil
    end
    local chainID = Safe(FindChain, lineID, questIDs)
    -- Without the questline's quests the vote cannot run: do not remember a miss yet.
    if chainID or (questIDs and #questIDs > 0) then
        lineCache[lineID] = chainID or false
    end
    return chainID
end

-- The Blizzard questline of a chain, when BtWQuests stores it.
function BTW:GetLineForChain(chainID)
    if not self:IsEnabled() then
        return nil
    end
    return Safe(function()
        return Index().chainToLine[chainID]
    end)
end

function BTW:GetChainName(chainID)
    if not self:IsEnabled() then
        return nil
    end
    return Safe(function()
        -- "Unnamed": BtWQuests has not resolved the name yet (some come from achievements).
        local name = Database():GetChainName(chainID)
        return name ~= "Unnamed" and name or nil
    end)
end

---------------------------------------------------------
-- Graph of a chain

local function ConnectionOffset(connection)
    -- "2.1"-style connections point inside an embedded chain; we do not follow those.
    if type(connection) == "number" and connection == math.floor(connection) then
        return connection
    end
    if type(connection) == "string" and not connection:find("%.") then
        return tonumber(connection)
    end
    return nil
end

-- The quest an item stands for. Items with several ids accept any of them: prefer the one the
-- player did or has, then the one the questline lists.
local function PickQuestID(item, wanted)
    local ids = {}
    local id = item:GetID()
    if item.item and type(item.item.ids) == "table" then
        ids = item.item.ids
    elseif id then
        ids = { id }
    end
    for _, questID in ipairs(ids) do
        if Call("C_QuestLog.IsQuestFlaggedCompleted", questID) or Call("C_QuestLog.IsOnQuest", questID) then
            return questID
        end
    end
    for _, questID in ipairs(ids) do
        if wanted[questID] then
            return questID
        end
    end
    return ids[1]
end

local function PrerequisiteList(db, chain, character)
    local list = {}
    local raw = chain.prerequisites
    if type(raw) ~= "table" then
        return list
    end
    if raw[1] == nil then
        raw = { raw }
    end
    for _, item in ipairs(raw) do
        if type(item) == "table" and not item.lowPriority and db:IsItemValidForCharacter(item, character) then
            local ids = item.ids or { item.id }
            if item.type == "chain" then
                for _, id in ipairs(ids) do
                    -- nil: that chain's expansion data is not loaded. "Unnamed": its name is not
                    -- resolved yet (BtWQuests reads some names from achievements later).
                    local name = db:GetChainName(id)
                    if name then
                        list[#list + 1] = {
                            kind = "chain",
                            chainID = id,
                            name = name ~= "Unnamed" and name or nil,
                            done = db:IsChainCompleted(id, character) and true or false,
                        }
                    end
                end
            elseif item.type == "quest" then
                for _, id in ipairs(ids) do
                    list[#list + 1] = {
                        kind = "quest",
                        questID = id,
                        name = db:GetQuestName(id) or Call("C_QuestLog.GetTitleForQuestID", id),
                        done = Call("C_QuestLog.IsQuestFlaggedCompleted", id) and true or false,
                    }
                end
            elseif item.type == "level" and type(item.level) == "number" then
                list[#list + 1] = {
                    kind = "level",
                    level = item.level,
                    done = (Call("UnitLevel", "player") or 0) >= item.level,
                }
            end
        end
    end
    return list
end

-- { chainID, nodes = { { questID, optional, hint } }, edges = { { from, to } }, prereqs }
-- Nodes are the chain's quests valid for the player, in chain order. Other items (the NPC that
-- starts a chain, the other faction's variant, level steps...) are bridged: their edges are
-- passed through to the quests they lead to.
local function BuildGraph(chainID, questIDs)
    local db = Database()
    local character = Player()
    local chain = db:GetChainByID(chainID)
    if not chain or type(chain.items) ~= "table" then
        return nil
    end
    local wanted = {}
    for _, questID in ipairs(questIDs or {}) do
        wanted[questID] = true
    end

    local entries = {}
    local count = chain:GetNumItems()
    local hint = 0
    for i = 1, count do
        local item = chain:GetItem(i, character)
        local entry = { next = {} }
        entries[i] = entry
        if item then
            local valid = item:IsValidForCharacter(character)
            if valid and item:GetType() == "quest" then
                entry.questID = PickQuestID(item, wanted)
                entry.optional = (item:IsBreadcrumb(character) or item:IsAside(character)) and true or false
                local x = item:GetX()
                hint = type(x) == "number" and x or hint + 2
                entry.hint = hint
            end
            for _, connection in ipairs(item:GetConnections() or {}) do
                local offset = ConnectionOffset(connection)
                if offset and i + offset <= count and i + offset > 0 then
                    entry.next[#entry.next + 1] = i + offset
                end
            end
        end
    end

    -- Quest items become nodes (one node per quest).
    local nodeOf, nodes = {}, {}
    local byQuest = {}
    for i, entry in ipairs(entries) do
        if entry.questID then
            local existing = byQuest[entry.questID]
            if existing then
                nodeOf[i] = existing
            else
                nodes[#nodes + 1] = { questID = entry.questID, optional = entry.optional, hint = entry.hint }
                nodeOf[i] = #nodes
                byQuest[entry.questID] = #nodes
            end
        end
    end

    -- Edges between nodes, walking through non-quest items.
    local edges, seenEdge = {}, {}
    for i in ipairs(entries) do
        local from = nodeOf[i]
        if from then
            local visited = {}
            local function Walk(j)
                if visited[j] then
                    return
                end
                visited[j] = true
                for _, k in ipairs(entries[j].next) do
                    local to = nodeOf[k]
                    if to then
                        local key = from * 100000 + to
                        if to ~= from and not seenEdge[key] then
                            seenEdge[key] = true
                            edges[#edges + 1] = { from = from, to = to }
                        end
                    elseif entries[k] then
                        Walk(k)
                    end
                end
            end
            Walk(i)
        end
    end

    return {
        chainID = chainID,
        nodes = nodes,
        edges = edges,
        prereqs = PrerequisiteList(db, chain, character),
    }
end

function BTW:GetGraph(lineID, questIDs)
    local chainID = self:GetChainForLine(lineID, questIDs)
    if not chainID then
        return nil
    end
    return Safe(BuildGraph, chainID, questIDs)
end

-- The quests of a chain in chain order (for questlines the API sends no quests for).
function BTW:GetChainQuestIDs(lineID)
    local graph = self:GetGraph(lineID, nil)
    if not graph then
        return nil
    end
    local list = {}
    for i, node in ipairs(graph.nodes) do
        list[i] = node.questID
    end
    return #list > 0 and list or nil
end

---------------------------------------------------------
-- Quest givers

-- First location of a location list valid for the player.
local function FirstValid(db, character, list)
    if type(list) ~= "table" then
        return nil
    end
    for _, spot in ipairs(db:FilterItems(list, character)) do
        if type(spot.x) == "number" and type(spot.y) == "number" then
            return spot
        end
    end
    return nil
end

local function QuestGiver(questID, preferredMaps)
    local db = Database()
    local character = Player()
    local quest = db:GetQuestByID(questID)
    local source = quest and quest.source
    if type(source) ~= "table" then
        return nil
    end
    if source[1] ~= nil then
        source = source[1]
    end
    local id = source.id or (type(source.ids) == "table" and source.ids[1])
    local target
    if source.type == "npc" then
        target = db:GetNPCByID(id)
    elseif source.type == "object" then
        target = db:GetObjectByID(id)
    end
    if not target then
        return nil
    end
    local name = target:GetName()
    local locations = type(target.locations) == "table" and target.locations or {}
    for _, mapID in ipairs(preferredMaps or {}) do
        local spot = mapID and FirstValid(db, character, locations[mapID])
        if spot then
            return name, mapID, spot.x, spot.y
        end
    end
    for mapID, list in pairs(locations) do
        local spot = FirstValid(db, character, list)
        if spot then
            return name, mapID, spot.x, spot.y
        end
    end
    return name
end

-- name, mapID, x, y of who starts a quest (any of them can be nil).
function BTW:GetQuestGiver(questID, preferredMaps)
    if not self:IsEnabled() or not questID then
        return nil
    end
    return Safe(QuestGiver, questID, preferredMaps)
end

---------------------------------------------------------
-- Find Quests: chains of the given maps whose next quest can be picked up there.

-- Chain IDs of a BtWQuests map item (a category, or a chain), one category level deep.
local function ChainsOfMapItem(db, item, out, depth)
    if type(item) ~= "table" or (depth or 0) > 2 then
        return
    end
    if item.type == "chain" and item.id then
        out[#out + 1] = item.id
    elseif item.type == "category" and item.id then
        local category = db:GetCategoryByID(item.id)
        for _, sub in ipairs(category and type(category.items) == "table" and category.items or {}) do
            ChainsOfMapItem(db, sub, out, (depth or 0) + 1)
        end
    end
end

local function ContinentOf(mapID)
    local continentType = MissionFocus_Utils.EnumValue("UIMapType", "Continent") or 2
    local id = mapID
    for _ = 1, 10 do
        local info = id and Call("C_Map.GetMapInfo", id)
        if not info then
            return nil
        end
        if info.mapType and info.mapType <= continentType then
            return id
        end
        id = info.parentMapID
    end
    return nil
end

-- The next quest of a chain, when the player can pick it up on mapID. nil otherwise.
local function OfferOfChain(db, character, chainID, mapID)
    local chain = db:GetChainByID(chainID)
    if not (chain and chain:IsValidForCharacter(character) and not chain:IsCompleted(character)
        and (chain:IsAvailable(character) or chain:IsActive(character))) then
        return nil
    end
    local nextItem = chain:GetNextItem(character)
    if not nextItem or nextItem:GetType() ~= "quest" or nextItem:IsActive(character) then
        return nil
    end
    local source = nextItem:GetSource(character)
    if not (source and source.GetLocation) then
        return nil
    end
    local _, coords = source:GetLocation(mapID)
    local x, y
    if type(coords) == "table" and coords.GetXY then
        x, y = coords:GetXY()
    end
    if not (x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1) then
        return nil
    end
    local name = chain:GetName()
    return {
        chainID = chainID,
        lineID = Index().chainToLine[chainID],
        name = name ~= "Unnamed" and name or nil,
        questID = nextItem:GetID(),
        mapID = mapID,
        x = x,
        y = y,
    }
end

local function FindOnMaps(maps)
    local db = Database()
    local character = Player()
    local results, seenChain = {}, {}
    for _, mapID in ipairs(maps) do
        local chainIDs = {}
        ChainsOfMapItem(db, db:GetMapItemByID(mapID, character), chainIDs, 0)
        local continent = ContinentOf(mapID)
        for _, item in ipairs(continent and type(db.Continents) == "table" and db.Continents[continent] or {}) do
            ChainsOfMapItem(db, item, chainIDs, 0)
        end
        for _, chainID in ipairs(chainIDs) do
            if not seenChain[chainID] then
                -- One chain at a time: BtWQuests' location lookup can fail for a single NPC
                -- (no usable location); that chain is skipped, the others still count.
                local ok, result = pcall(OfferOfChain, db, character, chainID, mapID)
                if ok and result then
                    seenChain[chainID] = true
                    results[#results + 1] = result
                elseif not ok then
                    MissionFocus_Utils.Debug("BtWQuests chain " .. tostring(chainID) .. ": " .. tostring(result))
                end
            end
        end
    end
    return results
end

-- { { chainID, lineID (may be nil), name, questID, mapID, x, y }, ... }
function BTW:Find(maps)
    if not self:IsEnabled() then
        return {}
    end
    return Safe(FindOnMaps, maps) or {}
end

---------------------------------------------------------
-- Helpers for making tales (Adventurer's Tales editor)

function BTW:GetQuestName(questID)
    if not self:IsEnabled() or not questID then
        return nil
    end
    return Safe(function()
        local name = Database():GetQuestName(questID)
        return name ~= "Unnamed" and name or nil
    end)
end

-- Chains whose name contains `text` (case-insensitive): { { chainID, name, lineID }, ... }
function BTW:SearchChains(text, limit)
    if not self:IsEnabled() or type(text) ~= "string" or #text < 2 then
        return {}
    end
    limit = limit or 25
    return Safe(function()
        local db = Database()
        local needle = text:lower()
        local found = {}
        ForEachRawChain(db, function(chainID)
            if #found < limit then
                -- One chain at a time: a single bad name must not end the search.
                local ok, name = pcall(db.GetChainName, db, chainID)
                if ok and type(name) == "string" and name ~= "Unnamed" and name:lower():find(needle, 1, true) then
                    found[#found + 1] = { chainID = chainID, name = name, lineID = Index().chainToLine[chainID] }
                end
            end
        end)
        table.sort(found, function(a, b)
            return a.name < b.name
        end)
        return found
    end) or {}
end

-- The quests of a chain with its branches, for adding them to a tale:
-- { { questID, optional, links = { indexes of the quests before it } }, ... }
function BTW:GetChainSteps(chainID)
    if not self:IsEnabled() then
        return nil
    end
    local graph = Safe(BuildGraph, chainID, nil)
    if not graph then
        return nil
    end
    local steps = {}
    for i, node in ipairs(graph.nodes) do
        steps[i] = { questID = node.questID, optional = node.optional, links = {} }
    end
    for _, edge in ipairs(graph.edges) do
        table.insert(steps[edge.to].links, edge.from)
    end
    return steps
end

---------------------------------------------------------
-- BtWQuests window

function BTW:OpenChain(chainID)
    local frame = rawget(_G, "BtWQuestsFrame")
    if not chainID or type(frame) ~= "table" or brokenForSession then
        return false
    end
    return Safe(function()
        frame:Show()
        if frame.SelectCharacter then
            frame:SelectCharacter(UnitName("player"), GetRealmName())
        end
        frame:SelectChain(chainID)
        return true
    end) or false
end
