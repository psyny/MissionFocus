-- MissionFocus_ItemButton.lua
-- The "use quest item" button for the focused quest.
-- It is a secure button, so in combat it cannot be shown, hidden, moved or retargeted.
-- It lives directly under UIParent (not inside the panel) so the panel stays free to
-- resize and hide during combat. If the focus changes in combat, the button is dimmed
-- and updated once combat ends.
MissionFocus_ItemButton = {}

local IB = MissionFocus_ItemButton
local Call = MissionFocus_Utils.Call
local RunOutOfCombat = MissionFocus_Utils.RunOutOfCombat

local STALE_ALPHA = 0.35
local BORDER_SIZE = 1
-- Blizzard item icons have a bevel baked into the image; this crop removes it.
local ICON_CROP = 0.08
local RANGE_UPDATE = 0.2

IB.button = nil
IB.wantedQuestID = nil
IB.concealed = false

-- Concealed: fully transparent and ignoring the mouse, but still bound to the item,
-- so the "Use Focused Quest Item" key keeps working while the quest panel is hidden.
-- Alpha can change in combat; mouse input only out of combat.
function IB:SetConcealed(concealed)
    if self.concealed == concealed then
        return
    end
    self.concealed = concealed
    self:ApplyAlpha()
    RunOutOfCombat("item_mouse", function()
        IB.button:EnableMouse(not IB.concealed)
    end)
end

function IB:ApplyAlpha()
    local button = self.button
    if self.concealed then
        button:SetAlpha(0)
    else
        button:SetAlpha(button.isStale and STALE_ALPHA or 1)
    end
end

local function GetItemInfo(questID)
    if not questID then
        return nil
    end
    local logIndex = Call("C_QuestLog.GetLogIndexForQuestID", questID)
    if not logIndex then
        return nil
    end
    local link, texture, charges, showItemWhenComplete = Call("GetQuestLogSpecialItemInfo", logIndex)
    if not link then
        return nil
    end
    if Call("C_QuestLog.IsComplete", questID) and not showItemWhenComplete then
        return nil
    end
    return { logIndex = logIndex, link = link, texture = texture, charges = charges }
end

-- The quest's usable special item, or nil: { logIndex, link, texture, charges }.
function IB:GetItem(questID)
    return GetItemInfo(questID)
end

local function UpdateCooldown(button)
    if not button.logIndex then
        return
    end
    local start, duration, enable = Call("GetQuestLogSpecialItemCooldown", button.logIndex)
    if start and duration then
        if CooldownFrame_Set then
            CooldownFrame_Set(button.Cooldown, start, duration, enable)
        else
            button.Cooldown:SetCooldown(start, duration)
        end
    else
        button.Cooldown:Clear()
    end
end

local function OnUpdate(button, elapsed)
    button.rangeTimer = (button.rangeTimer or 0) - elapsed
    if button.rangeTimer > 0 then
        return
    end
    button.rangeTimer = RANGE_UPDATE
    local inRange = button.logIndex and Call("IsQuestLogSpecialItemInRange", button.logIndex)
    if inRange == 0 then
        button.icon:SetVertexColor(1.0, 0.3, 0.3)
    else
        button.icon:SetVertexColor(1, 1, 1)
    end
end

local function OnEnter(button)
    if not button.logIndex then
        return
    end
    MissionFocus_Utils.Tooltip():SetOwner(button, "ANCHOR_LEFT")
    if MissionFocus_Utils.Tooltip().SetQuestLogSpecialItem then
        MissionFocus_Utils.Tooltip():SetQuestLogSpecialItem(button.logIndex)
    elseif button.link then
        MissionFocus_Utils.Tooltip():SetHyperlink(button.link)
    end
    local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")
    if button.isNearby and button.questID then
        local title = Call("C_QuestLog.GetTitleForQuestID", button.questID) or ""
        MissionFocus_Utils.Tooltip():AddLine(" ")
        MissionFocus_Utils.Tooltip():AddLine(string.format(L["MissionFocus.ui.item_nearby"], title), 1, 0.82, 0, true)
    end
    if button.isStale then
        MissionFocus_Utils.Tooltip():AddLine(" ")
        MissionFocus_Utils.Tooltip():AddLine(L["MissionFocus.ui.item_after_combat"], 1, 0.3, 0.3, true)
    end
    MissionFocus_Utils.Tooltip():Show()
end

function IB:Create()
    if self.button then
        return
    end
    local button = CreateFrame("Button", "MissionFocusItemButton", UIParent, "SecureActionButtonTemplate")
    button:SetAttribute("type", "item")
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetClampedToScreen(true)

    button.icon = button:CreateTexture(nil, "BORDER")
    button.icon:SetAllPoints()

    button.Count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.Count:SetPoint("BOTTOMRIGHT", button, -2, 2)

    button.Cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.Cooldown:SetAllPoints()

    button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    -- Thin black border for the Fading / Border Blur styles (see IB:ApplyStyle).
    button.borderLines = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local line = button:CreateTexture(nil, "OVERLAY", nil, -1)
        line:SetColorTexture(0, 0, 0, 1)
        if side == "TOP" or side == "BOTTOM" then
            line:SetPoint(side .. "LEFT")
            line:SetPoint(side .. "RIGHT")
            line:SetHeight(BORDER_SIZE)
        else
            line:SetPoint("TOP" .. side)
            line:SetPoint("BOTTOM" .. side)
            line:SetWidth(BORDER_SIZE)
        end
        line:Hide()
        button.borderLines[#button.borderLines + 1] = line
    end

    -- Nearby quest's item (not the focused quest's): the icon turns greyscale and a yellow "!"
    -- the size of the button covers it, to make clear it is not for the focused quest.
    button.nearbyMark = button:CreateTexture(nil, "OVERLAY")
    button.nearbyMark:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    button.nearbyMark:SetAllPoints()
    button.nearbyMark:Hide()

    -- After the secure click used the item: a nearby quest's item also focuses that quest.
    button:SetScript("PostClick", function(self)
        if self.isNearby and self.questID then
            MissionFocus:PickFocus(self.questID)
        end
    end)

    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", function() MissionFocus_Utils.Tooltip():Hide() end)
    button:SetScript("OnUpdate", OnUpdate)
    button:SetScript("OnEvent", function(self) UpdateCooldown(self) end)
    button:SetScript("OnShow", function(self) self:RegisterEvent("BAG_UPDATE_COOLDOWN") UpdateCooldown(self) end)
    button:SetScript("OnHide", function(self) self:UnregisterEvent("BAG_UPDATE_COOLDOWN") end)
    button:Hide()

    self.button = button
end

-- Placed beside the quest title: top edge on the title's top, with a horizontal gap of one
-- title font size (left side: button's top-right next to the title's top-left; right side:
-- button's top-left next to the panel's right edge). Uses the title's on-screen position,
-- so it is recomputed after every panel layout; in combat the button cannot move and catches
-- up when combat ends.
-- Blizzard style: the icon as Blizzard draws it, with the quickslot pressed frame.
-- Fading / Border Blur: icon bevel cropped off, 1px black border, a plain dark pressed overlay.
function IB:ApplyStyle()
    local button = self.button
    local blizzard = MissionFocus_Options.db.frame_style == "blizzard"
    if blizzard then
        button.icon:SetTexCoord(0, 1, 0, 1)
        button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        button:GetPushedTexture():SetVertexColor(1, 1, 1, 1)
    else
        button.icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
        button:SetPushedTexture("Interface\\Buttons\\WHITE8x8")
        button:GetPushedTexture():SetVertexColor(0, 0, 0, 0.35)
    end
    for _, line in ipairs(button.borderLines) do
        line:SetShown(not blizzard)
    end
end

function IB:ApplyLayout()
    RunOutOfCombat("item_layout", function()
        local db = MissionFocus_Options.db
        local button = self.button
        IB:ApplyStyle()
        local size = db.item_size
        button:SetScale(db.frame_scale)
        button:SetSize(size, size)
        button:SetFrameStrata(db.strata)

        local panel = MissionFocus_UI.frame
        local title = panel and panel.title
        local titleLeft, titleTop = title and title:GetLeft(), title and title:GetTop()
        local panelRight = panel and panel:GetRight()
        if titleLeft and titleTop and panelRight then
            local gap = db.title_font_size
            button:ClearAllPoints()
            if db.item_side == "RIGHT" then
                button:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", panelRight + gap, titleTop)
            else
                button:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", titleLeft - gap, titleTop)
            end
            return
        end

        -- The panel has not been laid out yet: approximate from the panel's anchor settings.
        local width = db.frame_width
        local gap = db.title_font_size
        local point = db.anchor_point

        local f
        if point:find("LEFT") then
            f = 0
        elseif point:find("RIGHT") then
            f = 1
        else
            f = 0.5
        end
        local panelLeft = db.pos_x - width * f
        local x
        if db.item_side == "RIGHT" then
            x = panelLeft + width + gap + size * f
        else
            x = panelLeft - gap - size + size * f
        end

        button:ClearAllPoints()
        button:SetPoint(point, UIParent, point, x, db.pos_y)
    end)
end

-- questID: the quest whose item to show, or nil to hide the button.
-- isNearby: the quest is not the focused one but close by (using the item focuses it).
function IB:SetQuest(questID, isNearby)
    isNearby = isNearby and true or false
    self.wantedQuestID = questID
    self.wantedNearby = isNearby
    local button = self.button
    local item = GetItemInfo(questID)

    if InCombatLockdown() then
        if button:IsShown() then
            button.isStale = button.questID ~= questID or not item
            self:ApplyAlpha()
        end
        RunOutOfCombat("item_quest", function()
            IB:SetQuest(IB.wantedQuestID, IB.wantedNearby)
        end)
        return
    end

    button.isStale = false
    self:ApplyAlpha()
    if not item then
        button.questID = nil
        button.logIndex = nil
        button.link = nil
        button.isNearby = false
        button.nearbyMark:Hide()
        button.icon:SetDesaturated(false)
        button:SetAttribute("item", nil)
        button:Hide()
        return
    end

    button.questID = questID
    button.isNearby = isNearby
    button.nearbyMark:SetShown(isNearby)
    button.icon:SetDesaturated(isNearby)
    button.logIndex = item.logIndex
    button.link = item.link
    button:SetAttribute("item", item.link)
    button.icon:SetTexture(item.texture)
    button.Count:SetText((item.charges and item.charges > 1) and item.charges or "")
    button:Show()
    UpdateCooldown(button)
end
