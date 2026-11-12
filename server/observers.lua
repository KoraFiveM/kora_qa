-- Event taps feeding QA.engine.onEvent: kora_lib's Kora.qa events (marks,
-- notifications, NUI opens, callbacks, commands), kora_inventory, kora_vehiclekeys'
-- lock state, and the server console (RegisterConsoleListener).

local U = QA.util
local R = QA.runs
local E = QA.engine

-- --- kora_lib Kora.qa ------------------------------------------------------------

local handlerId
local function attachKoraLib()
    if not U.started('kora_lib') then return end
    local ok, id = pcall(Kora.qa.onEvent, function(src, event)
        local okCall, err = pcall(E.onEvent, src, event)
        if not okCall then U.log('event handler failed: %s', tostring(err)) end
    end)
    if ok then
        handlerId = id
        -- A kora_lib restart forgets which players were active.
        for src in pairs(R.bySrc) do pcall(Kora.qa.setActive, src, true) end
    else
        U.log('could not attach to Kora.qa (kora_lib too old?): %s', tostring(id))
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'kora_lib' then SetTimeout(1000, attachKoraLib) end
end)

-- --- kora_inventory ----------------------------------------------------------------

AddEventHandler('qbinventory:server:usedItem', function(src, name)
    if type(src) == 'number' and R.get(src) and type(name) == 'string' then
        E.onEvent(src, { type = 'item', name = name, data = { action = 'used' }, side = 'server' })
    end
end)

AddEventHandler('qbinventory:server:sessionOpened', function(src, payload)
    if type(src) ~= 'number' or not R.get(src) or type(payload) ~= 'table' then return end
    local secondary = type(payload.secondary) == 'table' and payload.secondary or nil
    E.onEvent(src, {
        type = 'inventory',
        name = secondary and tostring(secondary.type or 'unknown') or 'player',
        data = secondary and { id = secondary.id, label = secondary.label } or nil,
        side = 'server',
    })
end)

-- --- kora_vehiclekeys lock state -------------------------------------------------------

AddStateBagChangeHandler('qbvehiclekeys:locked', nil, function(bagName, _, value)
    if next(R.bySrc) == nil then return end
    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end
    local coords = GetEntityCoords(entity)
    local at = { x = coords.x, y = coords.y, z = coords.z }
    for src, run in pairs(R.bySrc) do
        -- The run's own vehicle, or any vehicle within 25 m of the tester.
        if run.vehicle == entity or U.distance(U.playerCoords(src), at) <= 25.0 then
            E.onEvent(src, {
                type = 'vehicle', name = value and 'locked' or 'unlocked',
                data = { entity = entity, netId = NetworkGetNetworkIdFromEntity(entity) }, side = 'server',
            })
        end
    end
end)

-- --- console tap ---------------------------------------------------------------------------

QA.console = {}
local ring, ringSize = {}, 400

local function stripColours(line) return (line:gsub('%^%d', ''):gsub('\27%[[%d;]*m', '')) end

local function isError(line)
    local lower = line:lower()
    return lower:find('script error', 1, true) ~= nil or lower:find('error', 1, true) ~= nil
        or lower:find('warn', 1, true) ~= nil or lower:find('stack traceback', 1, true) ~= nil
end

function QA.console.recent(n)
    local out = {}
    for i = math.max(1, #ring - n + 1), #ring do out[#out + 1] = ring[i] end
    return out
end

local function onConsole(channel, message)
    if type(message) ~= 'string' or message == '' then return end
    local line = stripColours(message):gsub('%s+$', '')
    if line == '' or line:find('[kora_qa]', 1, true) then return end
    local entry = { at = U.now(), channel = tostring(channel or ''), line = line:sub(1, 600), error = isError(line) }
    entry.scriptError = line:lower():find('script error', 1, true) ~= nil
    ring[#ring + 1] = entry
    if #ring > ringSize then table.remove(ring, 1) end
    if next(R.bySrc) == nil then return end
    local lowerChannel = entry.channel:lower()
    for _, run in pairs(R.bySrc) do
        local relevant = entry.error
        if not relevant then
            for _, name in ipairs(run.resources) do
                if lowerChannel:find(name:lower(), 1, true) or line:find(name, 1, true) then relevant = true break end
            end
        end
        if relevant then
            run.console[#run.console + 1] = { at = entry.at, channel = entry.channel, line = entry.line, error = entry.scriptError }
            if #run.console > Config.run.maxConsoleLines then table.remove(run.console, 1) end
        end
    end
end

if type(RegisterConsoleListener) == 'function' then
    RegisterConsoleListener(function(channel, message)
        local ok, err = pcall(onConsole, channel, message)
        if not ok then ring[#ring + 1] = { at = U.now(), channel = 'kora_qa', line = 'console tap failed: ' .. tostring(err) } end
    end)
else
    U.log('RegisterConsoleListener is unavailable; console lines will not be captured')
end

QA.observers = { attachKoraLib = attachKoraLib, onConsole = onConsole }
