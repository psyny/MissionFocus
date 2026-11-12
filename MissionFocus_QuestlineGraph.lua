-- MissionFocus_QuestlineGraph.lua
-- Vertical flow view of a questline (detail of the Questlines tab): each quest is a box, edges
-- run top to bottom from a quest to the ones it opens. The main line keeps the left lane; parallel
-- quests open more lanes to the right, as many as needed, and a lane ends when its branch joins.
-- The row of boxes on top (different style) is what comes before the questline.
-- Data: MissionFocus_Questlines:GetGraph. Wheel scrolls (Shift: sideways), drag pans.
MissionFocus_QuestlineGraph = {}

local G = MissionFocus_QuestlineGraph
local L = LibStub("AceLocale-3.0"):GetLocale("MissionFocus")

local BOX_W, BOX_H = 176, 44
local GAP_X, GAP_Y = 14, 16
local MARGIN = 8
local LINE = 2
local WHEEL_STEP = 60
local BAR_SIZE = 4

local MARKERS = {
    done      = "Interface\\RaidFrame\\ReadyCheck-Ready",
    current   = "Interface\\GossipFrame\\ActiveQuestIcon",
    next      = "Interface\\GossipFrame\\AvailableQuestIcon",
    available = "Interface\\GossipFrame\\AvailableQuestIcon",
    blocked   = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

-- border, background, title color per box kind
local STYLES = {
    done      = { { 0.35, 0.7, 0.35, 0.9 }, { 0.2, 0.5, 0.2, 0.18 }, { 0.65, 0.85, 0.65 } },
    current   = { { 1, 0.82, 0, 1 },        { 1, 0.82, 0, 0.16 },    { 1, 0.9, 0.5 } },
    next      = { { 1, 0.82, 0, 0.6 },      { 1, 0.82, 0, 0.07 },    { 1, 0.82, 0 } },
    available = { { 1, 0.82, 0, 0.6 },      { 1, 0.82, 0, 0.07 },    { 1, 0.82, 0 } },
    behind    = { { 0.6, 0.6, 0.6, 0.7 },   { 1, 1, 1, 0.03 },       { 0.75, 0.75, 0.75 } },
    future    = { { 0.4, 0.4, 0.4, 0.5 },   { 0, 0, 0, 0.25 },       { 0.6, 0.6, 0.6 } },
    prereq    = { { 0.45, 0.65, 1, 0.7 },   { 0.3, 0.45, 0.8, 0.12 }, { 0.75, 0.85, 1 } },
    -- Adventurer's Tales kinds
    blocked     = { { 0.9, 0.3, 0.3, 0.8 }, { 0.6, 0.1, 0.1, 0.12 }, { 0.95, 0.7, 0.7 } },
    unavailable = { { 0.3, 0.3, 0.3, 0.6 }, { 0, 0, 0, 0.35 },       { 0.5, 0.5, 0.5 } },
    note        = { { 0.8, 0.7, 0.5, 0.6 }, { 0.6, 0.5, 0.3, 0.12 }, { 0.95, 0.88, 0.7 } },
}

local EDGE_DONE = { 0.4, 0.8, 0.4, 0.7 }
local EDGE_OPEN = { 1, 0.82, 0, 0.6 }
local EDGE_LOCKED = { 0.5, 0.5, 0.5, 0.5 }
local EDGE_PREREQ = { 0.45, 0.65, 1, 0.5 }

local STATUS_KEYS = {
    done = "step_done",
    current = "step_current",
    next = "step_next",
    available = "step_available",
    behind = "step_behind_short",
}

---------------------------------------------------------
-- Layout: depth (row from the top) = longest path from a start; lane (column from the left) =
-- the leftmost lane of the quests before it, or the next free lane to its right.

local function Links(count, edges)
    local succ, pred = {}, {}
    for i = 1, count do
        succ[i], pred[i] = {}, {}
    end
    for _, edge in ipairs(edges) do
        if succ[edge.from] and pred[edge.to] then
            table.insert(succ[edge.from], edge.to)
            table.insert(pred[edge.to], edge.from)
        end
    end
    return succ, pred
end

-- Topological order, lowest node first among the ready ones. A cycle (bad data) is broken by
-- taking the lowest node left.
local function Order(count, succ, pred)
    local indegree, ready, placed, order = {}, {}, {}, {}
    for i = 1, count do
        indegree[i] = #pred[i]
        if indegree[i] == 0 then
            ready[#ready + 1] = i
        end
    end
    while #order < count do
        if #ready == 0 then
            for i = 1, count do
                if not placed[i] then
                    ready[1] = i
                    break
                end
            end
        end
        table.sort(ready)
        local node = table.remove(ready, 1)
        if not placed[node] then
            placed[node] = true
            order[#order + 1] = node
            for _, to in ipairs(succ[node]) do
                indegree[to] = indegree[to] - 1
                if indegree[to] <= 0 and not placed[to] then
                    ready[#ready + 1] = to
                end
            end
        end
    end
    return order
end

-- Lanes for the nodes of one depth. Each node wants the leftmost lane of the quests before it
-- (so a branch that joins goes back left); when that lane is taken it moves right.
local function AssignLanes(list, desired, hint, lane)
    table.sort(list, function(a, b)
        if desired[a] ~= desired[b] then
            return desired[a] < desired[b]
        end
        if hint(a) ~= hint(b) then
            return hint(a) < hint(b)
        end
        return a < b
    end)
    local used = {}
    for _, node in ipairs(list) do
        local wanted = desired[node]
        while used[wanted] do
            wanted = wanted + 1
        end
        used[wanted] = true
        lane[node] = wanted
    end
end

-- Returns depth[i], lane[i] for the nodes, prereqLane[k] for the prerequisites (all on the top
-- row, depth 0, when there are any), maxDepth, laneCount.
local function Layout(graph)
    local count = #graph.nodes
    local succ, pred = Links(count, graph.edges)
    local order = Order(count, succ, pred)
    local position = {}
    for k, node in ipairs(order) do
        position[node] = k
    end

    local depth, maxDepth = {}, 0
    for _, node in ipairs(order) do
        depth[node] = depth[node] or 0
        for _, to in ipairs(succ[node]) do
            if position[to] > position[node] then
                depth[to] = math.max(depth[to] or 0, depth[node] + 1)
            end
        end
    end

    local byDepth = {}
    for _, node in ipairs(order) do
        maxDepth = math.max(maxDepth, depth[node])
        byDepth[depth[node]] = byDepth[depth[node]] or {}
        table.insert(byDepth[depth[node]], node)
    end
    local function Hint(node)
        return graph.nodes[node].hint or 0
    end
    local lane, laneCount = {}, 1
    for d = 0, maxDepth do
        local list = byDepth[d] or {}
        local desired = {}
        for _, node in ipairs(list) do
            local best
            for _, from in ipairs(pred[node]) do
                if lane[from] and (not best or lane[from] < best) then
                    best = lane[from]
                end
            end
            desired[node] = best or 0
        end
        AssignLanes(list, desired, Hint, lane)
    end
    for _, l in pairs(lane) do
        laneCount = math.max(laneCount, l + 1)
    end

    -- Prerequisites: a row of their own on top; the quests move one row down.
    local prereqLane = {}
    local prereqs = graph.prereqs or {}
    if #prereqs > 0 then
        for k = 1, #prereqs do
            prereqLane[k] = k - 1
        end
        laneCount = math.max(laneCount, #prereqs)
        for node, d in pairs(depth) do
            depth[node] = d + 1
        end
        maxDepth = maxDepth + 1
    end
    return depth, lane, prereqLane, maxDepth, laneCount
end
G.Layout = Layout

---------------------------------------------------------
-- Drawing

local function SetBoxStyle(box, style)
    local border, bg, title = style[1], style[2], style[3]
    box:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    box:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    box.title:SetTextColor(title[1], title[2], title[3], 1)
end

local function CreateBox(view)
    local box = CreateFrame("Button", nil, view.canvas, "BackdropTemplate")
    box:SetSize(BOX_W, BOX_H)
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    box:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    box:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
    box:RegisterForClicks("LeftButtonUp")

    box.marker = box:CreateTexture(nil, "ARTWORK")
    box.marker:SetSize(12, 12)
    box.marker:SetPoint("TOPLEFT", 4, -4)

    box.header = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    box.header:SetPoint("TOPLEFT", 6, -4)
    box.header:SetPoint("RIGHT", -18, 0)
    box.header:SetJustifyH("LEFT")
    box.header:SetWordWrap(false)

    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.title:SetJustifyH("LEFT")
    box.title:SetJustifyV("TOP")
    box.title:SetWordWrap(true)
    box.title:SetMaxLines(2)

    box.status = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    box.status:SetPoint("BOTTOMLEFT", 6, 4)
    box.status:SetPoint("RIGHT", -4, 0)
    box.status:SetJustifyH("LEFT")
    box.status:SetWordWrap(false)

    box:SetScript("OnEnter", function(self)
        if self.onEnter then
            self.onEnter(self)
        end
    end)
    box:SetScript("OnLeave", function()
        MissionFocus_Utils.Tooltip():Hide()
    end)
    box:SetScript("OnClick", function(self)
        if self.onClick then
            self.onClick(self)
        end
    end)
    return box
end

local function GetBox(view, index)
    local box = view.boxes[index]
    if not box then
        box = CreateBox(view)
        view.boxes[index] = box
    end
    box:Show()
    return box
end

local function GetLine(view)
    view.lineCount = view.lineCount + 1
    local line = view.lines[view.lineCount]
    if not line then
        line = view.canvas:CreateTexture(nil, "BACKGROUND", nil, 1)
        view.lines[view.lineCount] = line
    end
    line:Show()
    return line
end

local function Segment(view, left, top, width, height, color)
    local line = GetLine(view)
    line:SetColorTexture(color[1], color[2], color[3], color[4])
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", view.canvas, "TOPLEFT", left, -top)
    line:SetSize(math.max(width, LINE), math.max(height, LINE))
end

-- Elbow from the bottom of one box to the top of another: down the source lane, sideways just
-- above the target, then down into it.
local function Edge(view, x1, y1, x2, y2, color)
    if y2 <= y1 then
        return
    end
    local half = LINE / 2
    if x1 == x2 then
        Segment(view, x1 - half, y1, LINE, y2 - y1, color)
        return
    end
    local midY = y2 - GAP_Y / 2
    Segment(view, x1 - half, y1, LINE, midY - y1 + half, color)
    Segment(view, math.min(x1, x2) - half, midY - half, math.abs(x2 - x1) + LINE, LINE, color)
    Segment(view, x2 - half, midY - half, LINE, y2 - midY + half, color)
end

local function EdgeColor(fromNode, toNode)
    if fromNode.step.done and toNode.step.done then
        return EDGE_DONE
    elseif fromNode.step.done then
        return EDGE_OPEN
    end
    return EDGE_LOCKED
end

local function StepTitle(step)
    return step.title or L["MissionFocus.questlines.loading"]
end

local function FillStepBox(box, node)
    local style = STYLES[node.kind] or STYLES.future
    SetBoxStyle(box, style)
    box.header:SetText("")
    box.title:ClearAllPoints()
    box.title:SetPoint("TOPLEFT", 19, -4)
    box.title:SetPoint("RIGHT", -4, 0)
    box.title:SetText(StepTitle(node.step))
    local marker = MARKERS[node.kind]
    box.marker:SetShown(marker ~= nil)
    if marker then
        box.marker:SetTexture(marker)
    end
    if node.statusText then
        box.status:SetText(node.statusText)
        return
    end
    local parts = {}
    local key = STATUS_KEYS[node.kind]
    if key then
        parts[#parts + 1] = L["MissionFocus.questlines." .. key]
    end
    if node.optional then
        parts[#parts + 1] = L["MissionFocus.questlines.step_optional"]
    end
    if node.step.parallel then
        parts[#parts + 1] = "|cff88ccff" .. L["MissionFocus.questlines.step_parallel"] .. "|r"
    end
    box.status:SetText(table.concat(parts, "  ·  "))
end

local function PrereqName(prereq)
    if prereq.kind == "level" then
        return string.format(L["MissionFocus.questlines.prereq_level"], prereq.level)
    end
    return prereq.name or L["MissionFocus.questlines.prereq_unnamed"]
end

local function FillPrereqBox(box, prereq)
    SetBoxStyle(box, STYLES.prereq)
    box.header:SetText(prereq.header or L["MissionFocus.questlines.prereq_header"])
    box.title:ClearAllPoints()
    box.title:SetPoint("TOPLEFT", box.header, "BOTTOMLEFT", 0, -2)
    box.title:SetPoint("RIGHT", -4, 0)
    box.title:SetText(PrereqName(prereq))
    box.marker:ClearAllPoints()
    box.marker:SetPoint("TOPRIGHT", -4, -4)
    box.marker:SetShown(prereq.done)
    box.marker:SetTexture(MARKERS.done)
    box.status:SetText(prereq.statusText or (prereq.done and "" or L["MissionFocus.questlines.prereq_not_done"]))
end

---------------------------------------------------------
-- Scrolling

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Position indicator: a thumb on a thin track, shown only when the content does not fit.
local function UpdateBar(bar, visible, total, scroll, range, vertical)
    if total <= visible + 1 or visible <= 0 then
        bar:Hide()
        return
    end
    bar:Show()
    local size = math.max(20, visible * visible / total)
    local offset = range > 0 and scroll / range or 0
    bar.thumb:ClearAllPoints()
    if vertical then
        bar.thumb:SetSize(BAR_SIZE, size)
        bar.thumb:SetPoint("TOP", bar, "TOP", 0, -offset * (visible - size))
    else
        bar.thumb:SetSize(size, BAR_SIZE)
        bar.thumb:SetPoint("LEFT", bar, "LEFT", offset * (visible - size), 0)
    end
end

local function UpdateBars(view)
    UpdateBar(view.vbar, view:GetHeight(), view.canvas:GetHeight(), view:GetVerticalScroll(),
        view:GetVerticalScrollRange(), true)
    UpdateBar(view.hbar, view:GetWidth(), view.canvas:GetWidth(), view:GetHorizontalScroll(),
        view:GetHorizontalScrollRange(), false)
end

local function ScrollTo(view, x, y)
    view:UpdateScrollChildRect()
    view:SetHorizontalScroll(Clamp(x, 0, view:GetHorizontalScrollRange()))
    view:SetVerticalScroll(Clamp(y, 0, view:GetVerticalScrollRange()))
    UpdateBars(view)
end

local function OnWheel(view, delta)
    local horizontal = view:GetHorizontalScrollRange() > 0
        and (IsShiftKeyDown() or view:GetVerticalScrollRange() <= 0)
    if horizontal then
        ScrollTo(view, view:GetHorizontalScroll() - delta * WHEEL_STEP, view:GetVerticalScroll())
    else
        ScrollTo(view, view:GetHorizontalScroll(), view:GetVerticalScroll() - delta * WHEEL_STEP)
    end
end

local function CursorPosition(view)
    local x, y = GetCursorPosition()
    local scale = view:GetEffectiveScale()
    return x / scale, y / scale
end

---------------------------------------------------------
-- Public

-- A scroll view filling `parent` below `top` pixels.
-- Moves the view's top edge (a header above it changed height).
function G:SetTop(view, top)
    if view.top == top then
        return
    end
    view.top = top
    view:ClearAllPoints()
    view:SetPoint("TOPLEFT", view:GetParent(), "TOPLEFT", 0, -top)
    view:SetPoint("BOTTOMRIGHT", view:GetParent(), "BOTTOMRIGHT", -(BAR_SIZE + 4), BAR_SIZE + 4)
end

function G:Create(parent, top)
    local view = CreateFrame("ScrollFrame", nil, parent)
    view.top = top
    view:SetPoint("TOPLEFT", 0, -top)
    view:SetPoint("BOTTOMRIGHT", -(BAR_SIZE + 4), BAR_SIZE + 4)
    view:SetClipsChildren(true)
    view.boxes, view.lines, view.lineCount = {}, {}, 0

    local canvas = CreateFrame("Frame", nil, view)
    canvas:SetSize(10, 10)
    view:SetScrollChild(canvas)
    view.canvas = canvas

    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", OnWheel)

    -- Drag to pan.
    canvas:EnableMouse(true)
    canvas:SetScript("OnMouseDown", function()
        local x, y = CursorPosition(view)
        view.drag = { x = x, y = y, h = view:GetHorizontalScroll(), v = view:GetVerticalScroll() }
    end)
    canvas:SetScript("OnMouseUp", function()
        view.drag = nil
    end)
    canvas:SetScript("OnUpdate", function()
        local drag = view.drag
        if not drag then
            return
        end
        if not IsMouseButtonDown("LeftButton") then
            view.drag = nil
            return
        end
        local x, y = CursorPosition(view)
        ScrollTo(view, drag.h - (x - drag.x), drag.v + (y - drag.y))
    end)

    local function Bar()
        local bar = CreateFrame("Frame", nil, parent)
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()
        bar.bg:SetColorTexture(1, 1, 1, 0.06)
        bar.thumb = bar:CreateTexture(nil, "ARTWORK")
        bar.thumb:SetColorTexture(1, 0.82, 0, 0.5)
        bar:Hide()
        return bar
    end
    view.vbar = Bar()
    view.vbar:SetPoint("TOPLEFT", view, "TOPRIGHT", 4, 0)
    view.vbar:SetPoint("BOTTOMLEFT", view, "BOTTOMRIGHT", 4, 0)
    view.vbar:SetWidth(BAR_SIZE)
    view.hbar = Bar()
    view.hbar:SetPoint("TOPLEFT", view, "BOTTOMLEFT", 0, -4)
    view.hbar:SetPoint("TOPRIGHT", view, "BOTTOMRIGHT", 0, -4)
    view.hbar:SetHeight(BAR_SIZE)

    view.empty = view:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    view.empty:SetPoint("TOP", 0, -30)
    view.empty:SetWidth(420)
    view.empty:SetText(L["MissionFocus.questlines.state_unknown"])
    return view
end

-- handlers:
--   stepTooltip(node), stepClick(node)        -- quest boxes
--   prereqTooltip(prereq), prereqClick(prereq) -- boxes of what comes before
-- scrollToNow: center the view on graph.now (first show of a questline).
function G:Render(view, graph, handlers, scrollToNow)
    view.lineCount = 0
    local nodes = graph.nodes
    view.empty:SetShown(#nodes == 0)
    view.empty:SetText(graph.emptyText or L["MissionFocus.questlines.state_unknown"])

    local depth, lane, prereqLane, maxDepth, laneCount = Layout(graph)
    local prereqs = graph.prereqs or {}
    local function X(l)
        return MARGIN + l * (BOX_W + GAP_X)
    end
    local function Y(d)
        return MARGIN + d * (BOX_H + GAP_Y)
    end

    local boxIndex = 0
    for i, node in ipairs(nodes) do
        boxIndex = boxIndex + 1
        local box = GetBox(view, boxIndex)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", view.canvas, "TOPLEFT", X(lane[i]), -Y(depth[i]))
        box.marker:ClearAllPoints()
        box.marker:SetPoint("TOPLEFT", 4, -4)
        FillStepBox(box, node)
        box.onEnter = function(self)
            handlers.stepTooltip(self, node)
        end
        box.onClick = function()
            handlers.stepClick(node)
        end
    end
    for k, prereq in ipairs(prereqs) do
        boxIndex = boxIndex + 1
        local box = GetBox(view, boxIndex)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", view.canvas, "TOPLEFT", X(prereqLane[k]), -Y(0))
        FillPrereqBox(box, prereq)
        box.onEnter = function(self)
            handlers.prereqTooltip(self, prereq)
        end
        box.onClick = function()
            handlers.prereqClick(prereq)
        end
    end
    for i = boxIndex + 1, #view.boxes do
        view.boxes[i]:Hide()
    end

    local center = BOX_W / 2
    for _, edge in ipairs(graph.edges) do
        local from, to = edge.from, edge.to
        if depth[from] and depth[to] then
            Edge(view, X(lane[from]) + center, Y(depth[from]) + BOX_H, X(lane[to]) + center, Y(depth[to]),
                EdgeColor(nodes[from], nodes[to]))
        end
    end
    -- What comes before leads to every start of the questline.
    if #prereqs > 0 then
        local hasPred = {}
        for _, edge in ipairs(graph.edges) do
            hasPred[edge.to] = true
        end
        for i in ipairs(nodes) do
            if not hasPred[i] then
                for k in ipairs(prereqs) do
                    Edge(view, X(prereqLane[k]) + center, Y(0) + BOX_H, X(lane[i]) + center, Y(depth[i]),
                        EDGE_PREREQ)
                end
            end
        end
    end
    for i = view.lineCount + 1, #view.lines do
        view.lines[i]:Hide()
    end

    local width = X(laneCount) - GAP_X + MARGIN
    local height = #nodes > 0 and (Y(maxDepth) + BOX_H + MARGIN) or 10
    view.canvas:SetSize(width, height)

    if scrollToNow then
        local now = graph.now
        if now then
            -- The quest that matters now a third down the view, with the ones before it above.
            ScrollTo(view, X(lane[now]) + BOX_W / 2 - view:GetWidth() / 2,
                Y(depth[now]) - view:GetHeight() / 3)
        else
            ScrollTo(view, 0, 0)
        end
    else
        ScrollTo(view, view:GetHorizontalScroll(), view:GetVerticalScroll())
    end
end
