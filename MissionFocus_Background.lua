-- MissionFocus_Background.lua
-- Panel / tray backgrounds for the three frame styles:
--   blizzard : flat color + optional tooltip border (Backdrop)
--   border   : faded frame, solid core covering the frame, edges fading outward by border size
--   fading   : faded frame with a thin core line; the fade parts cover the content
--
-- The faded frame works like Skits_UI_Utils:CreateFadedFrame: a 3x3 sliced texture where the
-- center slice is solid and the side/corner slices fade to transparent. The center ("core") is
-- placed somewhere on the frame and the 8 other slices are attached around it with their own sizes.
-- Unlike Skits, the slices are textures on the frame itself (BACKGROUND layer) instead of child
-- frames, so they always draw behind the frame's text.
MissionFocus_Background = {}

local BG = MissionFocus_Background

local TEXTURE = "Interface\\AddOns\\MissionFocus\\Textures\\MissionFocusFadedFrame.tga"
local BORDER_TEXTURE = "Interface\\Tooltips\\UI-Tooltip-Border"

local SLICES = {
    center      = { 1/3, 2/3, 1/3, 2/3 },
    topLeft     = { 0, 1/3, 0, 1/3 },
    topMid      = { 1/3, 2/3, 0, 1/3 },
    topRight    = { 2/3, 1, 0, 1/3 },
    rightMid    = { 2/3, 1, 1/3, 2/3 },
    bottomRight = { 2/3, 1, 2/3, 1 },
    bottomMid   = { 1/3, 2/3, 2/3, 1 },
    bottomLeft  = { 0, 1/3, 2/3, 1 },
    leftMid     = { 0, 1/3, 1/3, 2/3 },
}

function BG:Create(frame)
    local slices = {}
    for key, coords in pairs(SLICES) do
        local texture = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        texture:SetTexture(TEXTURE)
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        texture:Hide()
        slices[key] = texture
    end
    frame.mfSlices = slices
end

local function ClearBackdrop(frame)
    if frame.ClearBackdrop then
        frame:ClearBackdrop()
    else
        frame:SetBackdrop(nil)
    end
end

local function HideSlices(frame)
    for _, texture in pairs(frame.mfSlices) do
        texture:Hide()
    end
end

local function PlaceSlice(texture, width, height, point, relativeTo, relativePoint)
    if width <= 0 or height <= 0 then
        texture:Hide()
        return
    end
    texture:ClearAllPoints()
    texture:SetSize(width, height)
    texture:SetPoint(point, relativeTo, relativePoint, 0, 0)
    texture:Show()
end

-- core: { x, y, width, height } relative to the frame's TOPLEFT (y grows downward, positive).
-- sizes: { left, right, top, bottom } lengths of the fading parts around the core.
local function LayoutFaded(frame, core, sizes, color)
    local s = frame.mfSlices
    local c = s.center

    c:ClearAllPoints()
    c:SetSize(math.max(core.width, 0.01), math.max(core.height, 0.01))
    c:SetPoint("TOPLEFT", frame, "TOPLEFT", core.x, -core.y)
    c:SetShown(core.width > 0 and core.height > 0)

    PlaceSlice(s.topLeft,     sizes.left,  sizes.top,    "BOTTOMRIGHT", c, "TOPLEFT")
    PlaceSlice(s.topMid,      core.width,  sizes.top,    "BOTTOMLEFT",  c, "TOPLEFT")
    PlaceSlice(s.topRight,    sizes.right, sizes.top,    "BOTTOMLEFT",  c, "TOPRIGHT")
    PlaceSlice(s.rightMid,    sizes.right, core.height,  "TOPLEFT",     c, "TOPRIGHT")
    PlaceSlice(s.bottomRight, sizes.right, sizes.bottom, "TOPLEFT",     c, "BOTTOMRIGHT")
    PlaceSlice(s.bottomMid,   core.width,  sizes.bottom, "TOPLEFT",     c, "BOTTOMLEFT")
    PlaceSlice(s.bottomLeft,  sizes.left,  sizes.bottom, "TOPRIGHT",    c, "BOTTOMLEFT")
    PlaceSlice(s.leftMid,     sizes.left,  core.height,  "TOPRIGHT",    c, "TOPLEFT")

    for _, texture in pairs(s) do
        texture:SetVertexColor(color.r, color.g, color.b, color.a)
    end
end

local function ApplyBlizzard(frame, db, border, bg)
    HideSlices(frame)
    border = border or db.border_size
    bg = bg or db.bg_color
    local inset = math.floor(border / 4)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = border > 0 and BORDER_TEXTURE or nil,
        edgeSize = border > 0 and border or nil,
        insets = { left = inset, right = inset, top = inset, bottom = inset },
    })
    frame:SetBackdropColor(bg.r, bg.g, bg.b, bg.a)
    if border > 0 then
        local bc = db.border_color
        frame:SetBackdropBorderColor(bc.r, bc.g, bc.b, bc.a)
    end
end

-- Border size grows inward, eating into the core. Never more than half the length,
-- so the core keeps at least 1px.
local function InwardBorder(border, length)
    return math.max(0, math.min(border, math.floor((length - 1) / 2)))
end

-- Main panel. layout = { width, height, underline } where underline is the distance from the
-- top of the panel to the line right under the title.
function BG:ApplyPanel(frame, layout)
    local db = MissionFocus_Options.db
    local style = db.frame_style
    local w, h = layout.width, layout.height

    if style == "border" then
        ClearBackdrop(frame)
        local bx, by = InwardBorder(db.border_size, w), InwardBorder(db.border_size, h)
        LayoutFaded(frame,
            { x = bx, y = by, width = w - 2 * bx, height = h - 2 * by },
            { left = bx, right = bx, top = by, bottom = by },
            db.bg_color)
    elseif style == "fading" then
        ClearBackdrop(frame)
        local bx = InwardBorder(db.border_size, w)
        local underline = math.min(math.max(layout.underline, 1), h - 1)
        LayoutFaded(frame,
            { x = bx, y = underline, width = w - 2 * bx, height = 1 },
            { left = bx, right = bx, top = underline, bottom = h - underline - 1 },
            db.bg_color)
    else
        ApplyBlizzard(frame, db)
    end
end

-- Quest tray. In the fading style the core is a 1px vertical line on the tray's right side:
-- the left part covers the tray and the right part sticks out a little.
BG.TRAY_FADING_RIGHT = 10

function BG:ApplyTray(frame, layout)
    local db = MissionFocus_Options.db
    local style = db.frame_style
    local w, h = layout.width, layout.height

    if style == "border" then
        ClearBackdrop(frame)
        local bx, by = InwardBorder(db.border_size, w), InwardBorder(db.border_size, h)
        LayoutFaded(frame,
            { x = bx, y = by, width = w - 2 * bx, height = h - 2 * by },
            { left = bx, right = bx, top = by, bottom = by },
            db.bg_color)
    elseif style == "fading" then
        ClearBackdrop(frame)
        local by = InwardBorder(db.border_size, h)
        LayoutFaded(frame,
            { x = w - 1, y = by, width = 1, height = h - 2 * by },
            { left = w - 1, right = self.TRAY_FADING_RIGHT, top = by, bottom = by },
            db.bg_color)
    else
        ApplyBlizzard(frame, db)
    end
end

-- Windows (the quest log): same style as the panel, but with fixed border sizes, and the
-- background kept opaque enough to read a long list. layout = { width, height }.
-- Border Blur and Fading look the same here: a solid core with a thin fading edge.
BG.WINDOW_BORDER = { blizzard = 14, faded = 3.0 }
BG.WINDOW_MIN_ALPHA = 0.85

function BG:ApplyWindow(frame, layout)
    local db = MissionFocus_Options.db
    local style = db.frame_style
    local w, h = layout.width, layout.height
    local bg = db.bg_color
    local color = { r = bg.r, g = bg.g, b = bg.b, a = math.max(bg.a or 1, self.WINDOW_MIN_ALPHA) }

    if style == "border" or style == "fading" then
        ClearBackdrop(frame)
        local border = self.WINDOW_BORDER.faded
        local bx, by = InwardBorder(border, w), InwardBorder(border, h)
        LayoutFaded(frame,
            { x = bx, y = by, width = w - 2 * bx, height = h - 2 * by },
            { left = bx, right = bx, top = by, bottom = by },
            color)
    else
        ApplyBlizzard(frame, db, self.WINDOW_BORDER.blizzard, color)
    end
end
