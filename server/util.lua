-- Shared server helpers. Everything in kora_qa's server realm hangs off QA.

QA = QA or {}
QA.util = {}
local U = QA.util

local RESOURCE = GetCurrentResourceName()
U.RESOURCE = RESOURCE

-- Millisecond wall clock that stays monotonic within a session: os.time() has
-- one-second resolution, GetGameTimer() is monotonic, so anchor one to the other.
local epochBase = os.time() * 1000 - GetGameTimer()
function U.now() return epochBase + GetGameTimer() end

function U.log(fmt, ...)
    print(('[kora_qa] ' .. fmt):format(...))
end

function U.enabled()
    return GetConvarInt(Config.convars.enabled, 0) == 1
end

function U.deepcopy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[U.deepcopy(k, seen)] = U.deepcopy(v, seen) end
    return out
end

function U.trim(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

---Strips control characters (newlines kept when asked) and trims to `max`.
function U.cleanText(value, max, keepNewlines)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('[%z\1-\31\127]', function(c)
        if keepNewlines and c == '\n' then return '\n' end
        return ' '
    end)
    value = U.trim(value)
    if value == '' then return nil end
    if max and #value > max then value = value:sub(1, max) end
    return value
end

---Length-independent string comparison for the shared secret.
function U.secureEquals(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or a == '' then return false end
    local diff = #a ~ #b
    for i = 1, math.max(#a, #b) do
        diff = diff | ((a:byte(i) or 0) ~ (b:byte(i) or 0))
    end
    return diff == 0
end

function U.discordOf(src)
    for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
        local id = identifier:match('^discord:(%d+)$')
        if id then return id end
    end
    return nil
end

function U.playersByDiscord(discordId)
    local out = {}
    for _, player in ipairs(GetPlayers()) do
        local src = tonumber(player)
        if src and U.discordOf(src) == discordId then out[#out + 1] = src end
    end
    return out
end

function U.playerName(src)
    return GetPlayerName(src) or ('Player #%s'):format(src)
end

function U.jsonEncode(value)
    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == 'string' then return encoded end
    return nil
end

function U.jsonDecode(text)
    if type(text) ~= 'string' or text == '' then return nil end
    local ok, decoded = pcall(json.decode, text)
    if ok then return decoded end
    return nil
end

function U.resourcePath(rel)
    local base = GetResourcePath(RESOURCE):gsub('\\', '/'):gsub('/+', '/'):gsub('/$', '')
    return rel and (base .. '/' .. rel) or base
end

function U.readJsonFile(rel)
    return U.jsonDecode(LoadResourceFile(RESOURCE, rel))
end

function U.writeJsonFile(rel, value)
    local encoded = U.jsonEncode(value)
    if not encoded then return false end
    return SaveResourceFile(RESOURCE, rel, encoded, -1)
end

function U.randomId(prefix)
    return ('%s%d%04d'):format(prefix or '', os.time(), math.random(0, 9999))
end

---Await a promise-like callback API inside a thread, with a timeout.
---`start(resolve)` must call resolve(...) once.
function U.await(timeoutMs, start)
    local p = promise.new()
    local settled = false
    local function resolve(...)
        if settled then return end
        settled = true
        p:resolve(table.pack(...))
    end
    SetTimeout(timeoutMs, function() resolve(nil, 'timeout') end)
    local ok, err = pcall(start, resolve)
    if not ok then resolve(nil, tostring(err)) end
    local packed = Citizen.Await(p)
    return table.unpack(packed, 1, packed.n)
end

function U.vec(entityCoords, heading)
    if not entityCoords then return nil end
    return {
        x = math.floor(entityCoords.x * 100 + 0.5) / 100,
        y = math.floor(entityCoords.y * 100 + 0.5) / 100,
        z = math.floor(entityCoords.z * 100 + 0.5) / 100,
        h = heading and math.floor(heading * 10 + 0.5) / 10 or nil,
    }
end

function U.distance(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function U.playerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return U.vec(GetEntityCoords(ped), GetEntityHeading(ped))
end

function U.started(resource)
    return GetResourceState(resource) == 'started'
end
