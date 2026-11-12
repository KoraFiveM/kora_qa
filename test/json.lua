-- Minimal JSON for the plain-Lua smoke tests (FXServer provides `json`).
local M = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

function M.encode(value)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return tostring(value) end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return 'null' end
        if math.type(value) == 'integer' then return tostring(value) end
        return string.format('%.14g', value)
    end
    if kind == 'string' then
        return '"' .. value:gsub('[%c"\\]', function(c) return escapes[c] or string.format('\\u%04x', c:byte()) end) .. '"'
    end
    if kind == 'table' then
        local array, n = isArray(value)
        local parts = {}
        if array and n > 0 then
            for i = 1, n do parts[i] = M.encode(value[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        if array then return '[]' end
        for k, v in pairs(value) do
            if type(v) ~= 'function' then parts[#parts + 1] = M.encode(tostring(k)) .. ':' .. M.encode(v) end
        end
        table.sort(parts)
        return '{' .. table.concat(parts, ',') .. '}'
    end
    error('cannot encode ' .. kind)
end

function M.decode(text)
    local pos = 1
    local function ws() pos = text:find('[^ \t\r\n]', pos) or #text + 1 end
    local value
    local function str()
        local out, i = {}, pos + 1
        while true do
            local c = text:sub(i, i)
            if c == '' then error('unterminated string') end
            if c == '"' then pos = i + 1 return table.concat(out) end
            if c == '\\' then
                local e = text:sub(i + 1, i + 1)
                local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
                if e == 'u' then
                    local code = tonumber(text:sub(i + 2, i + 5), 16)
                    out[#out + 1] = utf8.char(code)
                    i = i + 6
                else
                    out[#out + 1] = map[e]
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
    end
    function value()
        ws()
        local c = text:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            ws()
            if text:sub(pos, pos) == '}' then pos = pos + 1 return obj end
            while true do
                ws()
                local key = str()
                ws(); pos = pos + 1 -- :
                obj[key] = value()
                ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == '}' then return obj end
            end
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            ws()
            if text:sub(pos, pos) == ']' then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == ']' then return arr end
            end
        elseif c == '"' then
            return str()
        elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
        else
            local num = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            pos = pos + #num
            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end
    return value()
end

return M
