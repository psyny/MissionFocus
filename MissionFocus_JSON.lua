-- MissionFocus_JSON.lua
-- Small JSON reader and writer for tale files (Adventurer's Tales import / export).
-- Plain Lua, no WoW API: tale files must stay readable by any tool, on any game version.
--   Encode(value, hints) -> text   pretty printed, keys in a stable order
--   Decode(text) -> value | nil, error
-- Lua has one table type for objects and arrays: a table with keys 1..n is written as an array;
-- hints.listKeys names the fields that are arrays even when empty.
MissionFocus_JSON = {}

local JSON = MissionFocus_JSON

local MAX_DEPTH = 64

---------------------------------------------------------
-- Writing

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function EscapeString(text)
    return '"' .. text:gsub('[%c"\\]', function(char)
        return ESCAPES[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function IsArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
    end
    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end
    return true, count
end

local function EncodeNumber(value)
    if value ~= value or value == math.huge or value == -math.huge then
        return "null"
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.14g", value)
end

local function SortedKeys(value, order)
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys, function(a, b)
        local ra, rb = order[a] or 1000, order[b] or 1000
        if ra ~= rb then
            return ra < rb
        end
        return a < b
    end)
    return keys
end

local function Encode(value, hints, indent, depth, key)
    if depth > MAX_DEPTH then
        error("too deep")
    end
    local kind = type(value)
    if kind == "nil" then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        return EncodeNumber(value)
    elseif kind == "string" then
        return EscapeString(value)
    elseif kind ~= "table" then
        error("cannot write a " .. kind)
    end

    local inner = indent .. "  "
    local isArray, count = IsArray(value)
    if isArray and (count > 0 or hints.listKeys[key]) then
        if count == 0 then
            return "[]"
        end
        -- Short arrays of numbers stay on one line ("previous", "quests").
        local simple = true
        for i = 1, count do
            if type(value[i]) == "table" then
                simple = false
            end
        end
        local parts = {}
        for i = 1, count do
            parts[i] = Encode(value[i], hints, inner, depth + 1, nil)
        end
        if simple then
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        return "[\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "]"
    end
    local keys = SortedKeys(value, hints.keyOrder)
    if #keys == 0 then
        return "{}"
    end
    local parts = {}
    for i, name in ipairs(keys) do
        local field = value[name]
        if field == nil then
            field = value[tonumber(name)]
        end
        parts[i] = EscapeString(name) .. ": " .. Encode(field, hints, inner, depth + 1, name)
    end
    return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "}"
end

-- hints = { keyOrder = { "id", "title", ... }, listKeys = { steps = true, ... } }
function JSON.Encode(value, hints)
    local order = {}
    for i, name in ipairs(hints and hints.keyOrder or {}) do
        order[name] = i
    end
    return Encode(value, { keyOrder = order, listKeys = hints and hints.listKeys or {} }, "", 0, nil)
end

---------------------------------------------------------
-- Reading

local function Utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local Reader = {}
Reader.__index = Reader

function Reader:Fail(message)
    -- Line number: easier to find than a character position in a text editor.
    local line = 1
    for _ in self.text:sub(1, self.pos):gmatch("\n") do
        line = line + 1
    end
    error({ message = string.format("line %d: %s", line, message) })
end

function Reader:Skip()
    self.pos = self.text:find("[^ \t\r\n]", self.pos) or (#self.text + 1)
end

function Reader:Peek()
    self:Skip()
    return self.text:sub(self.pos, self.pos)
end

function Reader:Expect(char)
    if self:Peek() ~= char then
        self:Fail("expected '" .. char .. "'")
    end
    self.pos = self.pos + 1
end

function Reader:String()
    self:Expect('"')
    local parts = {}
    while true do
        local stop = self.text:find('["\\]', self.pos)
        if not stop then
            self:Fail("unfinished text")
        end
        parts[#parts + 1] = self.text:sub(self.pos, stop - 1)
        local char = self.text:sub(stop, stop)
        if char == '"' then
            self.pos = stop + 1
            return table.concat(parts)
        end
        local escape = self.text:sub(stop + 1, stop + 1)
        local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if simple[escape] then
            parts[#parts + 1] = simple[escape]
            self.pos = stop + 2
        elseif escape == "u" then
            local code = tonumber(self.text:sub(stop + 2, stop + 5), 16)
            if not code then
                self:Fail("bad \\u escape")
            end
            self.pos = stop + 6
            -- Surrogate pair: characters outside the basic plane.
            if code >= 0xD800 and code <= 0xDBFF and self.text:sub(self.pos, self.pos + 1) == "\\u" then
                local low = tonumber(self.text:sub(self.pos + 2, self.pos + 5), 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    self.pos = self.pos + 6
                end
            end
            parts[#parts + 1] = Utf8(code)
        else
            self:Fail("bad escape")
        end
    end
end

function Reader:Value(depth)
    if depth > MAX_DEPTH then
        self:Fail("too deep")
    end
    local char = self:Peek()
    if char == "{" then
        self.pos = self.pos + 1
        local object = {}
        if self:Peek() == "}" then
            self.pos = self.pos + 1
            return object
        end
        while true do
            local key = self:String()
            self:Expect(":")
            object[key] = self:Value(depth + 1)
            local nextChar = self:Peek()
            self.pos = self.pos + 1
            if nextChar == "}" then
                return object
            elseif nextChar ~= "," then
                self.pos = self.pos - 1
                self:Fail("expected ',' or '}'")
            end
        end
    elseif char == "[" then
        self.pos = self.pos + 1
        local array = {}
        if self:Peek() == "]" then
            self.pos = self.pos + 1
            return array
        end
        while true do
            array[#array + 1] = self:Value(depth + 1)
            local nextChar = self:Peek()
            self.pos = self.pos + 1
            if nextChar == "]" then
                return array
            elseif nextChar ~= "," then
                self.pos = self.pos - 1
                self:Fail("expected ',' or ']'")
            end
        end
    elseif char == '"' then
        return self:String()
    end
    local word = self.text:match("^[%w%.%+%-]+", self.pos)
    if not word then
        self:Fail("unexpected '" .. char .. "'")
    end
    self.pos = self.pos + #word
    if word == "true" then
        return true
    elseif word == "false" then
        return false
    elseif word == "null" then
        return nil
    end
    local number = tonumber(word)
    if not number then
        self:Fail("unexpected '" .. word .. "'")
    end
    return number
end

-- Returns the value, or nil and an error message.
function JSON.Decode(text)
    if type(text) ~= "string" then
        return nil, "no text"
    end
    local reader = setmetatable({ text = text, pos = 1 }, Reader)
    local ok, result = pcall(function()
        local value = reader:Value(0)
        reader:Skip()
        if reader.pos <= #text then
            reader:Fail("text after the end")
        end
        return value
    end)
    if ok then
        return result
    end
    return nil, type(result) == "table" and result.message or tostring(result)
end
