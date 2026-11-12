-- MissionFocus_Utils.lua
-- Small helpers. Every call into the WoW API goes through MissionFocus_Utils.Call so that
-- a function renamed or removed by a patch only disables that feature instead of
-- throwing errors every frame.
MissionFocus_Utils = {}

local reported = {}

-- Resolves a dotted global path, e.g. "C_QuestLog.GetInfo". Returns nil when missing.
local function Resolve(path)
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then
            return nil
        end
        value = value[part]
    end
    return value
end
MissionFocus_Utils.Resolve = Resolve

-- Calls an API by path. Returns the API results, or nothing if the API is missing or errors.
function MissionFocus_Utils.Call(path, ...)
    local fn = Resolve(path)
    if type(fn) ~= "function" then
        return nil
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        if not reported[path] then
            reported[path] = true
            MissionFocus_Utils.Debug("API error in " .. path .. ": " .. tostring(results[2]))
        end
        return nil
    end
    return unpack(results, 2, table.maxn(results))
end

function MissionFocus_Utils.HasAPI(path)
    return type(Resolve(path)) == "function"
end

-- 12.0 "secret" values (e.g. some unit names) cannot be compared, stored or inspected by addon
-- code. Readable returns the value, or nil when it is secret.
function MissionFocus_Utils.Readable(value)
    if value ~= nil and issecretvalue and issecretvalue(value) then
        return nil
    end
    return value
end

-- The value when it is a readable non-empty string, else nil.
function MissionFocus_Utils.ReadableString(value)
    value = MissionFocus_Utils.Readable(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- Enum lookup that tolerates missing enums or values.
function MissionFocus_Utils.EnumValue(enumName, valueName)
    local enum = Enum and Enum[enumName]
    return enum and enum[valueName]
end

function MissionFocus_Utils.Debug(msg)
    if MissionFocus_Options.db and MissionFocus_Options.db.debug then
        print("|cff33ccffMissionFocus|r: " .. tostring(msg))
    end
end

function MissionFocus_Utils.Print(msg)
    print("|cff33ccffMissionFocus|r: " .. tostring(msg))
end

-- MissionFocus's own tooltip. Blizzard's shared GameTooltip may still hold Blizzard widget sets
-- from its last use; when our code takes it over, Blizzard's widget layout runs tainted by us
-- and fails on 12.0 "secret" values. A private tooltip (as Ace3 does) never carries those.
local tooltip
function MissionFocus_Utils.Tooltip()
    if not tooltip then
        tooltip = CreateFrame("GameTooltip", "MissionFocusTooltip", UIParent, "GameTooltipTemplate")
    end
    return tooltip
end

-- A small window with selectable text, so reports can be copied (Ctrl+A, Ctrl+C).
local copyWindow
function MissionFocus_Utils.ShowCopyWindow(title, text)
    if not copyWindow then
        local frame = CreateFrame("Frame", "MissionFocusCopyWindow", UIParent, "BackdropTemplate")
        frame:SetSize(620, 420)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.9)
        tinsert(UISpecialFrames, "MissionFocusCopyWindow") -- closes with Escape

        frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.title:SetPoint("TOPLEFT", 12, -10)

        local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 0, 0)

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)

        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(ChatFontNormal)
        editBox:SetWidth(570)
        editBox:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(editBox)
        frame.editBox = editBox

        copyWindow = frame
    end
    copyWindow.title:SetText(title .. "  -  Ctrl+A, Ctrl+C to copy")
    copyWindow.editBox:SetText(text)
    copyWindow:Show()
    copyWindow.editBox:SetFocus()
    copyWindow.editBox:HighlightText()
end

function MissionFocus_Utils.ColorToHex(color)
    if not color then
        return "ffffffff"
    end
    return string.format("ff%02x%02x%02x",
        math.floor((color.r or 1) * 255 + 0.5),
        math.floor((color.g or 1) * 255 + 0.5),
        math.floor((color.b or 1) * 255 + 0.5))
end

function MissionFocus_Utils.InCombat()
    return InCombatLockdown()
end

-- Runs fn now if out of combat, otherwise once combat ends.
local combatQueue = {}
function MissionFocus_Utils.RunOutOfCombat(key, fn)
    if not InCombatLockdown() then
        fn()
        return
    end
    combatQueue[key] = fn
end

function MissionFocus_Utils.FlushCombatQueue()
    local queue = combatQueue
    combatQueue = {}
    for _, fn in pairs(queue) do
        fn()
    end
end
