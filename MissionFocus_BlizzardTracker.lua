-- MissionFocus_BlizzardTracker.lua
-- Hides / restores the default objective tracker.
-- Deliberately minimal: we never replace Blizzard functions (that is what tends to break on new
-- patches and causes taint). Instead:
--   * out of combat the tracker is parented to a hidden frame, so it cannot become visible
--     no matter how often Blizzard calls Show() on it
--   * when Blizzard shows it during combat (e.g. quest progress while fighting), we cannot
--     reparent or hide it safely, so it is made fully transparent at once (alpha is allowed in
--     combat) and properly hidden when combat ends.
MissionFocus_BlizzardTracker = {}

local BT = MissionFocus_BlizzardTracker
local RunOutOfCombat = MissionFocus_Utils.RunOutOfCombat

BT.wantHidden = false
local hooked = false
local hiddenParent
local originalParent

local function GetTracker()
    return _G.ObjectiveTrackerFrame
end

local function HideNow()
    local tracker = GetTracker()
    if not BT.wantHidden or not tracker then
        return
    end
    tracker:SetAlpha(0) -- immediate, even in combat
    RunOutOfCombat("blizzard_tracker", function()
        if not BT.wantHidden then
            return
        end
        if not hiddenParent then
            hiddenParent = CreateFrame("Frame")
            hiddenParent:Hide()
        end
        if tracker:GetParent() ~= hiddenParent then
            originalParent = tracker:GetParent()
            tracker:SetParent(hiddenParent)
        end
        tracker:Hide()
    end)
end

local function Hook(tracker)
    if hooked then
        return
    end
    hooked = true
    hooksecurefunc(tracker, "Show", function()
        if BT.wantHidden then
            HideNow()
        end
    end)
    hooksecurefunc(tracker, "SetShown", function(_, shown)
        if shown and BT.wantHidden then
            HideNow()
        end
    end)
end

function BT:SetHidden(hidden)
    local tracker = GetTracker()
    if not tracker then
        MissionFocus_Utils.Debug("ObjectiveTrackerFrame not found; default tracker left untouched.")
        return
    end
    if hidden == self.wantHidden then
        return
    end
    self.wantHidden = hidden
    if hidden then
        Hook(tracker)
        HideNow()
    else
        RunOutOfCombat("blizzard_tracker", function()
            if BT.wantHidden then
                return
            end
            if hiddenParent and tracker:GetParent() == hiddenParent then
                tracker:SetParent(originalParent or UIParent)
            end
            tracker:SetAlpha(1)
            tracker:Show()
        end)
    end
end
