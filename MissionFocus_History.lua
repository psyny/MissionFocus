-- MissionFocus_History.lua
-- What the WoW API does not keep about a quest: when and where it was accepted, and from whom.
-- Stored per character in db.char.quest_history[questID]:
--   { time = epoch seconds, mapID, x, y, giver = "NPC name", seenOnly = true|nil }
-- seenOnly marks quests that were already in the log when we first saw them (accepted before
-- MissionFocus was installed): their time is "first seen", not "accepted".
MissionFocus_History = {}

local H = MissionFocus_History
local Call = MissionFocus_Utils.Call

-- The quest dialog (QUEST_DETAIL) tells us the giver; QUEST_ACCEPTED follows shortly after.
local pendingGiver
local PENDING_GIVER_SECONDS = 120

local function History()
    return MissionFocus.db.char.quest_history
end

function H:Get(questID)
    return questID and History()[questID]
end

---------------------------------------------------------
-- Recording

local function PlayerPlace()
    local mapID = Call("C_Map.GetBestMapForUnit", "player")
    local x, y
    if mapID then
        local position = Call("C_Map.GetPlayerMapPosition", mapID, "player")
        if position and position.GetXY then
            x, y = position:GetXY()
        end
    end
    return mapID, x, y
end

-- QUEST_DETAIL: the quest dialog is open; remember who is offering the quest.
-- The name can be a 12.0 secret value (unreadable by addons): the giver is then unknown.
function H:OnQuestDetail()
    local Readable = MissionFocus_Utils.ReadableString
    local name = Readable(UnitName("npc"))
    if not name and QuestFrameNpcNameText and QuestFrameNpcNameText.GetText then
        name = Readable(QuestFrameNpcNameText:GetText())
    end
    pendingGiver = {
        questID = MissionFocus_Utils.Readable(Call("GetQuestID")),
        name = name,
        at = GetTime(),
    }
end

function H:OnQuestAccepted(questID)
    if not questID then
        return
    end
    local giver
    if pendingGiver and GetTime() - pendingGiver.at <= PENDING_GIVER_SECONDS
        and (pendingGiver.questID == questID or not pendingGiver.questID or pendingGiver.questID == 0) then
        giver = pendingGiver.name
    end
    pendingGiver = nil

    local mapID, x, y = PlayerPlace()
    History()[questID] = {
        time = time(),
        mapID = mapID,
        x = x,
        y = y,
        giver = giver,
    }
end

function H:Forget(questID)
    if questID then
        History()[questID] = nil
    end
end

-- Quests already in the log that we never saw being accepted: record "first seen".
-- Also drops entries of quests that left the log while MissionFocus was not running.
-- Only runs once the quest log has entries (it is empty for a moment after login).
function H:Sync()
    local numEntries = Call("C_QuestLog.GetNumQuestLogEntries") or 0
    if numEntries == 0 then
        return
    end
    local inLog = {}
    for i = 1, numEntries do
        local info = Call("C_QuestLog.GetInfo", i)
        if info and info.questID and not info.isHeader then
            inLog[info.questID] = true
        end
    end
    local history = History()
    for questID in pairs(inLog) do
        if not history[questID] then
            history[questID] = { time = time(), seenOnly = true }
        end
    end
    for questID in pairs(history) do
        if not inLog[questID] then
            history[questID] = nil
        end
    end
end

---------------------------------------------------------
-- Reading

-- Map where the quest was accepted. Falls back to the older quest_origins data.
function H:GetOriginMap(questID)
    local entry = self:Get(questID)
    if entry and entry.mapID then
        return entry.mapID
    end
    local legacy = MissionFocus.db.char.quest_origins
    return legacy and legacy[questID]
end
