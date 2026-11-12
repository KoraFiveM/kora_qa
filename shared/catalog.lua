-- Step catalog + argument validation. Pure Lua (no natives) so it is shared by
-- the server executor, the client UI and the smoke tests.
--
-- The panel validates scenarios against the same rules at scan time; this file
-- re-validates every value right before a step executes, so a stale or forged
-- scenario can never push a value past the caps.

QACatalog = QACatalog or {}
local C = QACatalog

C.KINDS = { setup = true, observed = true, check = true, manual = true }
C.SIDES = { server = true, client = true, both = true }
C.TYPES = { int = true, float = true, string = true, word = true, any = true }

local DEFAULT_MAX_LENGTH = { string = 200, word = 64, any = 500 }

local function lower(value) return type(value) == 'string' and value:lower() or value end

local function listHas(list, value)
    if type(list) ~= 'table' then return false end
    local needle = lower(value)
    for _, entry in ipairs(list) do
        if lower(entry) == needle then return true end
    end
    return false
end
C.listHas = listHas

local function isInteger(value)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value > -math.huge and value < math.huge
end

---Validates one step definition (shape of a steps.json entry or a registered step).
---@param def table
---@return boolean ok
---@return string|nil err
function C.validateDef(def)
    if type(def) ~= 'table' then return false, 'definition must be a table' end
    if type(def.id) ~= 'string' or not def.id:match('^[%w_%-]+%.[%w_%.%-]+$') or #def.id > 64 then
        return false, 'id must look like "group.name"'
    end
    if type(def.pattern) ~= 'string' or def.pattern == '' or #def.pattern > 200 then return false, def.id .. ': pattern missing' end
    if not C.KINDS[def.kind] then return false, def.id .. ': unknown kind ' .. tostring(def.kind) end
    if not C.SIDES[def.side] then return false, def.id .. ': unknown side ' .. tostring(def.side) end
    if def.priority ~= nil and not isInteger(def.priority) then return false, def.id .. ': priority must be an integer' end
    if type(def.args) ~= 'table' then return false, def.id .. ': args must be a list' end
    local placeholders = 0
    for _ in def.pattern:gmatch('{[%a]*}') do placeholders = placeholders + 1 end
    if placeholders ~= #def.args then
        return false, ('%s: pattern has %d parameters but %d args'):format(def.id, placeholders, #def.args)
    end
    for index, arg in ipairs(def.args) do
        if type(arg) ~= 'table' or type(arg.name) ~= 'string' or not C.TYPES[arg.type] then
            return false, ('%s: arg %d malformed'):format(def.id, index)
        end
    end
    return true
end

---Builds a catalog from a list of definitions.
---@param defs table[]
---@return table catalog { list = def[], byId = { [id] = def } }
---@return string[] errors definitions that were skipped
function C.new(defs)
    local catalog = { list = {}, byId = {} }
    local errors = {}
    for _, def in ipairs(defs or {}) do
        local ok, err = C.add(catalog, def)
        if not ok then errors[#errors + 1] = err end
    end
    return catalog, errors
end

---Adds (or replaces, same id) one definition.
function C.add(catalog, def)
    local ok, err = C.validateDef(def)
    if not ok then return false, err end
    def.priority = def.priority or 0
    def.resource = def.resource or 'kora_qa'
    if catalog.byId[def.id] then
        for index, existing in ipairs(catalog.list) do
            if existing.id == def.id then catalog.list[index] = def end
        end
    else
        catalog.list[#catalog.list + 1] = def
    end
    catalog.byId[def.id] = def
    return true
end

---JSON-safe registry entries (no functions), in StepDef shape.
function C.publicDefs(catalog)
    local out = {}
    for _, def in ipairs(catalog.list) do
        local entry = {}
        for key, value in pairs(def) do
            if type(value) ~= 'function' then entry[key] = value end
        end
        out[#out + 1] = entry
    end
    return out
end

-- --- aliases --------------------------------------------------------------

local ALIAS_GROUPS = { locations = true, vehicles = true, peds = true, props = true, fixtures = true }
C.ALIAS_GROUPS = ALIAS_GROUPS

---Looks an alias up: "resource:name" explicitly, else the scenario's resource,
---then kora_qa's shared aliases.
---@return any value, string|nil owner
function C.resolveAlias(aliases, group, name, resource)
    if type(aliases) ~= 'table' or type(name) ~= 'string' then return nil end
    local owner, local_ = name:match('^([%w_%-]+):(.+)$')
    if owner and aliases[owner] and aliases[owner][group] and aliases[owner][group][local_] ~= nil then
        return aliases[owner][group][local_], owner
    end
    for _, candidate in ipairs({ resource, 'kora_qa' }) do
        local set = candidate and aliases[candidate]
        if set and set[group] and set[group][name] ~= nil then return set[group][name], candidate end
    end
    return nil
end

---Normalises a location alias value: {x,y,z[,h][,r]} or {x=,y=,z=,h=,r=}.
function C.normalizeLocation(value)
    if type(value) ~= 'table' then return nil end
    local x = tonumber(value.x or value[1])
    local y = tonumber(value.y or value[2])
    local z = tonumber(value.z or value[3])
    if not x or not y or not z then return nil end
    local h = tonumber(value.h or value.heading or value.w or value[4])
    local r = tonumber(value.r or value.radius)
    return { x = x, y = y, z = z, h = h, r = r, label = type(value.label) == 'string' and value.label or nil }
end

-- --- argument validation ---------------------------------------------------

local MODEL_PATTERN = '^[%w_%-]+$'

local function modelAllowed(caps, ...)
    for _, name in ipairs({ ... }) do
        if listHas(caps.modelDeny, name) then return false end
    end
    return true
end

local allowRules = {}

allowRules.items = function(value, env)
    if not value:match('^[%w_%-%.]+$') then return nil, 'is not an item name' end
    local caps = env.caps
    if listHas(caps.itemDeny, value) then return nil, 'is on the item denylist' end
    if type(caps.itemAllow) == 'table' and not listHas(caps.itemAllow, value) then return nil, 'is not on the item allowlist' end
    return value:lower()
end

allowRules.accounts = function(value, env)
    if not listHas(env.caps.accounts or { 'cash', 'bank' }, value) then return nil, 'is not an allowed money account' end
    return value:lower()
end

local function identifier(value)
    if not value:match('^[%w_%-]+$') then return nil, 'is not a valid name' end
    return value:lower()
end
allowRules.jobs = identifier
allowRules.gangs = identifier

allowRules.metadataKeys = function(value, env)
    if not value:match('^[%w_%-%.]+$') then return nil, 'is not a metadata key' end
    if listHas(env.caps.metadataDeny, value) then return nil, 'is on the metadata denylist' end
    return value
end

allowRules.locations = function(value, env)
    local raw = C.resolveAlias(env.aliases, 'locations', value, env.resource)
    local location = C.normalizeLocation(raw)
    if not location then return nil, 'is not a known location alias' end
    location.name = value
    return location
end

local function modelRule(group)
    return function(value, env)
        local alias = C.resolveAlias(env.aliases, group, value, env.resource)
        local model = alias
        if type(alias) == 'table' then model = alias.model end
        if alias == nil then model = value end
        if type(model) ~= 'string' or not model:match(MODEL_PATTERN) then return nil, 'is not a model name or alias' end
        if not modelAllowed(env.caps, value, model) then return nil, 'is on the model denylist' end
        return model:lower()
    end
end
allowRules.vehicles = modelRule('vehicles')
allowRules.peds = modelRule('peds')
allowRules.props = modelRule('props')

allowRules.pedScenarios = function(value)
    if not value:match('^[%u%d_]+$') then return nil, 'is not a GTA scenario name' end
    return value
end

allowRules.weather = function(value, env)
    if not listHas(env.caps.weather, value) then return nil, 'is not a weather type' end
    return value:upper()
end

allowRules.inventoryTypes = function(value, env)
    if not listHas(env.caps.inventoryTypes, value) then return nil, 'is not an inventory type' end
    return value:lower()
end

allowRules.fixtures = function(value, env)
    local fixture, owner = C.resolveAlias(env.aliases, 'fixtures', value, env.resource)
    if type(fixture) ~= 'table' then return nil, 'is not a known fixture' end
    return { name = value, owner = owner, steps = fixture.steps or fixture }
end

allowRules.commands = function(value)
    local text = value:gsub('^%s*/', ''):gsub('%s+$', '')
    local name = text:match('^([^%s]+)')
    if not name or not name:match('^[%w_:%.%-]+$') then return nil, 'is not a command' end
    return { text = text, name = name:lower() }
end

allowRules.marks = function(value)
    if #value > 64 or not value:match('^[%w_:%.%-/ ]+$') then return nil, 'is not a mark name' end
    return value
end

allowRules.text = function(value) return value end

local KEY_ALIASES = {
    ['LEFT ALT'] = 'ALT', ['RIGHT ALT'] = 'ALT', RALT = 'ALT', ['LEFT SHIFT'] = 'SHIFT', ['LEFT CTRL'] = 'CTRL',
    CONTROL = 'CTRL', RETURN = 'ENTER', ['PAGE UP'] = 'PAGEUP', ['PAGE DOWN'] = 'PAGEDOWN', DEL = 'DELETE',
    ['ARROW UP'] = 'UP', ['ARROW DOWN'] = 'DOWN', ['ARROW LEFT'] = 'LEFT', ['ARROW RIGHT'] = 'RIGHT',
    ['CAPS LOCK'] = 'CAPSLOCK', CAPS = 'CAPSLOCK', ['LEFT MOUSE'] = 'MOUSE1', ['RIGHT MOUSE'] = 'MOUSE2',
}

---Key name for `I press the {string} key`: trimmed, upper-cased, aliases resolved; nil for junk.
function C.normalizeKey(name)
    if type(name) ~= 'string' then return nil end
    local key = name:gsub('^%s+', ''):gsub('%s+$', ''):upper()
    if key == '' or #key > 24 or not key:match('^[%w%-_ `]+$') then return nil end
    return KEY_ALIASES[key] or key
end

-- Any key name is accepted (unknown keys fall back to Done); see shared/keys.lua.
allowRules.keys = function(value)
    local key = C.normalizeKey(value)
    if not key then return nil, 'is not a key name' end
    return key
end

local NOTIFY_TYPES = { info = 'info', inform = 'info', success = 'success', warning = 'warning', warn = 'warning', error = 'error' }
allowRules.notifyTypes = function(value)
    local kind = NOTIFY_TYPES[value:lower()]
    if not kind then return nil, 'is not a notification type (info, success, warning, error)' end
    return kind
end

C.allowRules = allowRules

---Validates and resolves positional `args` against `def.args`.
---@param def table step definition
---@param args any[] values from the compiled scenario (never from the client)
---@param env table { caps, aliases, resource }
---@return table|nil params name -> value (aliases resolved), or nil on error
---@return string|nil err
function C.validateArgs(def, args, env)
    if type(args) ~= 'table' then args = {} end
    local specs = def.args or {}
    if #args ~= #specs then
        return nil, ('expected %d argument(s), got %d'):format(#specs, #args)
    end
    env = env or {}
    env.caps = env.caps or {}
    local params = {}
    for index, spec in ipairs(specs) do
        local value = args[index]
        local label = ('"%s" (%s)'):format(tostring(value), spec.name)
        if spec.type == 'int' then
            if not isInteger(value) then return nil, label .. ' must be a whole number' end
        elseif spec.type == 'float' then
            if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
                return nil, label .. ' must be a number'
            end
        else
            if type(value) ~= 'string' then return nil, label .. ' must be text' end
            local maxLength = spec.maxLength or DEFAULT_MAX_LENGTH[spec.type] or 200
            if #value > maxLength then return nil, ('%s is longer than %d characters'):format(spec.name, maxLength) end
            if spec.type == 'word' and value:find('%s') then return nil, label .. ' must be one word' end
        end

        if type(value) == 'number' then
            if spec.min ~= nil and value < spec.min then return nil, ('%s must be at least %s'):format(label, spec.min) end
            if spec.max ~= nil and value > spec.max then return nil, ('%s must be at most %s'):format(label, spec.max) end
            if spec.cap then
                local limit = tonumber(env.caps[spec.cap])
                if not limit then return nil, ('cap %s is not configured'):format(spec.cap) end
                if value > limit then return nil, ('%s is over the %s cap (%s)'):format(label, spec.cap, limit) end
                if value < -limit then return nil, ('%s is under the %s cap (-%s)'):format(label, spec.cap, limit) end
            end
        end

        if spec.allow then
            local rule = allowRules[spec.allow]
            if not rule then return nil, ('unknown allow rule %s'):format(spec.allow) end
            local resolved, err = rule(value, env)
            if resolved == nil then return nil, ('%s %s'):format(label, err or 'is not allowed') end
            value = resolved
        end
        params[spec.name] = value
    end
    return params
end

return C
