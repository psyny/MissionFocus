-- MissionFocus_Location.lua
-- Region filtering for the tray and cycling. The level is a setting of the active focus mode:
--   none | world | continent | zone
-- Every map is resolved to its top-most ancestor of the chosen map type (the common point;
-- e.g. at zone level Valdrakken resolves to Thaldraszus). When a map has no ancestor of that
-- type, the next more detailed type is used (world -> continent -> zone).
-- A quest is kept when ANY location involved in it is in the player's region:
--   * the quest's map (GetQuestUiMapID, ignoring waypoints: objective or turn-in location)
--   * the world quest zone
--   * Blizzard's own "onContinent" answer from GetDistanceSqToQuest (continent/world levels)
--   * where the quest was accepted (recorded by us, the API does not keep it)
-- Quests with no known location at all are always kept.
MissionFocus_Location = {}

local LOC = MissionFocus_Location
local Call = MissionFocus_Utils.Call
local EnumValue = MissionFocus_Utils.EnumValue

local MAX_DEPTH = 20

LOC.LEVELS = { "none", "world", "continent", "zone" }

-- Map types tried for each level, the requested one first, then more detailed fallbacks.
local LEVEL_TYPES = {
    world     = { "World", "Continent", "Zone" },
    continent = { "Continent", "Zone" },
    zone      = { "Zone" },
}

function LOC:GetLevel()
    local level = MissionFocus_Modes:GetRegionFilter()
    if LEVEL_TYPES[level] then
        return level
    end
    return nil -- "none" or unknown: no filtering
end

-- Map data never changes: cache "mapID:level" -> regionID (false when there is none).
local regionCache = {}

-- Top-most ancestor (or the map itself) per map type, e.g. { [2] = 1978, [3] = 2025 }.
local function TopMostByType(mapID)
    local topMost = {}
    local id = mapID
    for _ = 1, MAX_DEPTH do
        local info = Call("C_Map.GetMapInfo", id)
        if not info then
            break
        end
        if info.mapType then
            topMost[info.mapType] = id -- later (higher) ancestors overwrite: top-most wins
        end
        id = info.parentMapID
        if not id or id == 0 then
            break
        end
    end
    return topMost
end

function LOC:GetRegion(mapID, level)
    if not mapID or mapID == 0 or not LEVEL_TYPES[level] then
        return nil
    end
    local key = mapID .. ":" .. level
    local cached = regionCache[key]
    if cached ~= nil then
        return cached or nil
    end

    local topMost = TopMostByType(mapID)
    local found
    for _, typeName in ipairs(LEVEL_TYPES[level]) do
        local mapType = EnumValue("UIMapType", typeName)
        if mapType and topMost[mapType] then
            found = topMost[mapType]
            break
        end
    end

    regionCache[key] = found or false
    return found
end

function LOC:GetPlayerMap()
    return Call("C_Map.GetBestMapForUnit", "player")
end

function LOC:GetPlayerRegion(level)
    return self:GetRegion(self:GetPlayerMap(), level)
end

---------------------------------------------------------
-- Accept location: recorded by MissionFocus_History (exact map), resolved to the chosen level.

-- Drops the older per-quest origin data (kept only as a fallback for quests accepted before
-- MissionFocus_History existed).
function LOC:ForgetOrigin(questID)
    local legacy = MissionFocus.db.char.quest_origins
    if questID and legacy then
        legacy[questID] = nil
    end
end

---------------------------------------------------------
-- Filtering

-- Returns true when the quest should be listed for a player in playerRegion.
function LOC:IsQuestNearby(questID, playerRegion, level)
    if not playerRegion then
        -- We do not know where the player is: do not filter anything.
        return true
    end

    local hasLocation = false
    local function Check(mapID)
        local region = self:GetRegion(mapID, level)
        if region then
            hasLocation = true
            return region == playerRegion
        end
        return false
    end

    -- ignoreWaypoints: without it, quests on other continents report the next route step
    -- (e.g. the portal room in Valdrakken) instead of where the quest actually is.
    -- For the same reason the next waypoint itself is not used: it is a route step, not a quest location.
    if Check(Call("GetQuestUiMapID", questID, true)) then
        return true
    end
    if Check(Call("C_TaskQuest.GetQuestZoneID", questID)) then
        return true
    end

    -- "On my continent" also means "in my world"; it says nothing about the zone.
    local distanceSq, onContinent = Call("C_QuestLog.GetDistanceSqToQuest", questID)
    if distanceSq then
        hasLocation = true
        if onContinent and level ~= "zone" then
            return true
        end
    end

    if Check(MissionFocus_History:GetOriginMap(questID)) then
        return true
    end

    return not hasLocation
end

-- Pseudo-category for quests outside the player's region. Always sorted last.
LOC.ELSEWHERE = "elsewhere"

-- "Not in Continent", "Not in Zone", ... following the chosen level.
function LOC:GetElsewhereName()
    local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
    return L["MissionFocus.category.elsewhere_" .. (self:GetLevel() or "continent")]
end

-- Returns a new list: quests in the player's region first (original order), then the
-- others as copies with category "elsewhere" (original order, so the most important come
-- first). realCategory keeps the quest's own category. Without a level, returns the list.
function LOC:GroupByRegion(list)
    local level = self:GetLevel()
    if not level then
        return list
    end
    local playerRegion = self:GetPlayerRegion(level)
    local nearby, elsewhere = {}, {}
    for _, entry in ipairs(list) do
        if self:IsQuestNearby(entry.questID, playerRegion, level) then
            nearby[#nearby + 1] = entry
        else
            local copy = {}
            for k, v in pairs(entry) do
                copy[k] = v
            end
            copy.realCategory = entry.category
            copy.category = self.ELSEWHERE
            elsewhere[#elsewhere + 1] = copy
        end
    end
    for _, entry in ipairs(elsewhere) do
        nearby[#nearby + 1] = entry
    end
    return nearby
end

---------------------------------------------------------
-- Diagnostics: /mf where

local function DescribeChain(mapID)
    if not mapID or mapID == 0 then
        return "none"
    end
    local parts = {}
    local id = mapID
    for _ = 1, MAX_DEPTH do
        local info = Call("C_Map.GetMapInfo", id)
        if not info then
            parts[#parts + 1] = id .. "(no info)"
            break
        end
        parts[#parts + 1] = string.format("%s[%d,t%s]", info.name or "?", id, tostring(info.mapType))
        id = info.parentMapID
        if not id or id == 0 then
            break
        end
    end
    return table.concat(parts, " > ")
end

function LOC:PrintReport()
    local lines = {}
    local function Print(text)
        text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        lines[#lines + 1] = text
    end
    local level = self:GetLevel()
    Print("Region filter: " .. tostring(MissionFocus_Modes:GetRegionFilter())
        .. "  (UIMapType World=" .. tostring(EnumValue("UIMapType", "World"))
        .. " Continent=" .. tostring(EnumValue("UIMapType", "Continent"))
        .. " Zone=" .. tostring(EnumValue("UIMapType", "Zone")) .. ")")
    local playerMap = self:GetPlayerMap()
    local playerRegion = level and self:GetPlayerRegion(level)
    Print("Player: " .. DescribeChain(playerMap))
    Print("Player region: " .. tostring(playerRegion))

    for _, entry in ipairs(MissionFocus_Quests:GetQuests()) do
        local questID = entry.questID
        local routeMap = Call("GetQuestUiMapID", questID)
        local uiMap = Call("GetQuestUiMapID", questID, true)
        local waypointMap = Call("C_QuestLog.GetNextWaypoint", questID)
        local taskZone = Call("C_TaskQuest.GetQuestZoneID", questID)
        local distanceSq, onContinent = Call("C_QuestLog.GetDistanceSqToQuest", questID)
        local origin = MissionFocus_History:GetOriginMap(questID)
        local verdict = "no filter"
        if level then
            verdict = self:IsQuestNearby(questID, playerRegion, level) and "|cff66ff66KEEP|r" or "|cffff6666ELSEWHERE|r"
        end
        Print(string.format("|cffffd100%s|r [%d]%s -> %s", entry.title, questID,
            entry.isTracked and "" or " (untracked)", verdict))
        Print(string.format("   uiMap=%s (region %s)  [unused: route map=%s, waypoint=%s]  taskZone=%s",
            tostring(uiMap), tostring(level and self:GetRegion(uiMap, level)),
            tostring(routeMap), tostring(waypointMap), tostring(taskZone)))
        Print(string.format("   distSq=%s onContinent=%s origin=%s (region %s)",
            tostring(distanceSq), tostring(onContinent), tostring(origin),
            tostring(level and self:GetRegion(origin, level))))
        if uiMap and uiMap ~= 0 then
            Print("   chain: " .. DescribeChain(uiMap))
        end
    end

    MissionFocus_Utils.ShowCopyWindow("MissionFocus /mf where", table.concat(lines, "\n"))
end
