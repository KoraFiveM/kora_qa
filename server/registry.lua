-- Step registry, per-resource aliases (tests/qa.lua), scenario cache and
-- tester access.

QA.registry = {}
local Reg = QA.registry
local U = QA.util
local P = QA.panel

-- --- step catalog ------------------------------------------------------------

local function loadBuiltins()
    local defs = U.jsonDecode(LoadResourceFile(U.RESOURCE, 'shared/steps.json'))
    assert(type(defs) == 'table', 'shared/steps.json is missing or invalid JSON')
    local catalog, errors = QACatalog.new(defs)
    for _, err in ipairs(errors) do U.log('steps.json: %s', err) end
    return catalog
end

QA.catalog = loadBuiltins()

-- Steps registered by other resources: id -> { def, owner }.
local external = {}

-- --- aliases (tests/qa.lua) ------------------------------------------------------

QA.aliases = {}

local INSTRUCTION_LIMIT = 2000000

---Runs a tests/qa.lua chunk with no globals at all and an instruction budget.
---@return table|nil result, string|nil err
function Reg.sandboxLoad(source, chunkName)
    local env = {}
    local chunk, err = load(source, chunkName, 't', env)
    if not chunk then return nil, err end
    local hooked = type(debug) == 'table' and type(debug.sethook) == 'function'
    if hooked then
        debug.sethook(function() error('tests/qa.lua took too long', 2) end, '', INSTRUCTION_LIMIT)
    end
    local ok, result = pcall(chunk)
    if hooked then debug.sethook() end
    if not ok then return nil, tostring(result) end
    if type(result) ~= 'table' then return nil, 'tests/qa.lua must return a table' end
    return result
end

local function cleanModelGroup(group, warn)
    local out = {}
    if type(group) ~= 'table' then return out end
    for name, value in pairs(group) do
        local model = type(value) == 'table' and value.model or value
        if type(name) == 'string' and type(model) == 'string' and model:match('^[%w_%-]+$') then
            out[name] = model
        else
            warn(('bad model alias %s'):format(tostring(name)))
        end
    end
    return out
end

---Validates the table a tests/qa.lua returned. Returns the cleaned alias set.
function Reg.cleanAliases(raw, warn)
    warn = warn or function() end
    local out = { locations = {}, vehicles = {}, peds = {}, props = {}, fixtures = {} }
    if type(raw.locations) == 'table' then
        for name, value in pairs(raw.locations) do
            local location = type(name) == 'string' and QACatalog.normalizeLocation(value)
            if location then out.locations[name] = location else warn(('bad location %s'):format(tostring(name))) end
        end
    end
    out.vehicles = cleanModelGroup(raw.vehicles, warn)
    out.peds = cleanModelGroup(raw.peds, warn)
    out.props = cleanModelGroup(raw.props, warn)
    if type(raw.fixtures) == 'table' then
        for name, fixture in pairs(raw.fixtures) do
            local steps = type(fixture) == 'table' and (fixture.steps or fixture) or nil
            local valid = type(name) == 'string' and type(steps) == 'table' and #steps > 0
            if valid then
                for _, entry in ipairs(steps) do
                    if type(entry) ~= 'table' or type(entry.step) ~= 'string' or (entry.args ~= nil and type(entry.args) ~= 'table') then
                        valid = false
                    end
                end
            end
            if valid then
                out.fixtures[name] = { steps = steps, description = type(fixture.description) == 'string' and fixture.description or nil }
            else
                warn(('bad fixture %s (expected { steps = { { step = "items.have", args = { 1, "water" } } } })'):format(tostring(name)))
            end
        end
    end
    return out
end

function Reg.loadAliasesFor(resource)
    local source = LoadResourceFile(resource, 'tests/qa.lua')
    if not source then
        QA.aliases[resource] = nil
        return false
    end
    local raw, err = Reg.sandboxLoad(source, ('@@%s/tests/qa.lua'):format(resource))
    if not raw then
        U.log('%s/tests/qa.lua: %s', resource, tostring(err))
        QA.aliases[resource] = nil
        return false
    end
    QA.aliases[resource] = Reg.cleanAliases(raw, function(message)
        U.log('%s/tests/qa.lua: %s', resource, message)
    end)
    return true
end

function Reg.loadAllAliases()
    QA.aliases = {}
    local count = 0
    for index = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(index)
        if name and GetResourceState(name) == 'started' and Reg.loadAliasesFor(name) then count = count + 1 end
    end
    return count
end

---Alias payload for POST /registry: fixtures as names only.
function Reg.aliasesForPanel()
    local out = {}
    for resource, set in pairs(QA.aliases) do
        local fixtures = {}
        for name in pairs(set.fixtures) do fixtures[#fixtures + 1] = name end
        table.sort(fixtures)
        local locations = {}
        for name, l in pairs(set.locations) do locations[name] = { x = l.x, y = l.y, z = l.z, h = l.h, r = l.r } end
        out[resource] = { locations = locations, vehicles = set.vehicles, peds = set.peds, props = set.props, fixtures = fixtures }
    end
    return out
end

-- --- registry post (debounced) ---------------------------------------------------

local postScheduled = false
function Reg.post()
    if postScheduled then return end
    postScheduled = true
    SetTimeout(2000, function()
        postScheduled = false
        if not U.enabled() or not P.configured() then return end
        P.request('POST', '/registry', {
            steps = QACatalog.publicDefs(QA.catalog),
            aliases = Reg.aliasesForPanel(),
            caps = Config.caps,
        }, function(status)
            if P.ok(status) then
                U.log('registry posted (%d steps)', #QA.catalog.list)
            else
                U.log('registry post failed (HTTP %s); will retry when the panel is back', tostring(status))
            end
        end)
    end)
end

-- --- external steps ----------------------------------------------------------------

---exports.kora_qa:registerStep({ id = 'fishing.rod_equipped', pattern = 'I have a fishing rod equipped',
---    kind = 'setup', side = 'server', description = '…', args = {}, undo = true,
---    setup = function(src, params) return true, 'detail' end, undo = function(src, data) end,
---    check = function(src, params) return ok, actual, expected end })
---Ids must start with the resource name or a group it owns; built-in ids can't be replaced.
function Reg.registerStep(def)
    local owner = GetInvokingResource() or U.RESOURCE
    if type(def) ~= 'table' then return false, 'definition must be a table' end
    if QA.catalog.byId[def.id] and not external[def.id] then return false, 'built-in step ids cannot be replaced' end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    copy.resource = owner
    copy.args = copy.args or {}
    copy.external = { setup = def.setup, undo = def.undoFn or def.revert, check = def.check }
    copy.setup, copy.check, copy.revert, copy.undoFn = nil, nil, nil, nil
    copy.undo = def.undo == true or def.undoFn ~= nil or def.revert ~= nil
    local ok, err = QACatalog.add(QA.catalog, copy)
    if not ok then return false, err end
    external[copy.id] = { owner = owner }
    Reg.post()
    return true
end
exports('registerStep', Reg.registerStep)

function Reg.dropOwner(resource)
    local changed = false
    for id, entry in pairs(external) do
        if entry.owner == resource then
            external[id] = nil
            QA.catalog.byId[id] = nil
            for i = #QA.catalog.list, 1, -1 do
                if QA.catalog.list[i].id == id then table.remove(QA.catalog.list, i) end
            end
            changed = true
        end
    end
    if changed then Reg.post() end
end

-- --- scenarios -----------------------------------------------------------------------

QA.scenarios = { hash = nil, list = {}, byId = {}, fetchedAt = 0 }
local CACHE = 'data/scenarios.json'

local function setScenarios(data)
    local byId = {}
    local list = {}
    for _, scenario in ipairs(type(data.scenarios) == 'table' and data.scenarios or {}) do
        if type(scenario) == 'table' and type(scenario.id) == 'string' and type(scenario.steps) == 'table' then
            byId[scenario.id] = scenario
            list[#list + 1] = scenario
        end
    end
    table.sort(list, function(a, b)
        if (a.resource or '') ~= (b.resource or '') then return (a.resource or '') < (b.resource or '') end
        return (a.name or '') < (b.name or '')
    end)
    QA.scenarios = { hash = data.hash, list = list, byId = byId, fetchedAt = os.time() }
end

function Reg.loadScenarioCache()
    local cached = U.readJsonFile(CACHE)
    if type(cached) == 'table' then setScenarios(cached) end
end

---Fetches GET /scenarios. `done(ok)` optional.
function Reg.refreshScenarios(done)
    done = done or function() end
    if not U.enabled() then return done(false) end
    P.request('GET', '/scenarios', nil, function(status, data)
        if P.ok(status) and type(data) == 'table' and type(data.scenarios) == 'table' then
            if data.hash ~= QA.scenarios.hash or #QA.scenarios.list == 0 then
                setScenarios(data)
                U.writeJsonFile(CACHE, data)
                U.log('%d scenario(s) loaded from the panel', #QA.scenarios.list)
            else
                QA.scenarios.fetchedAt = os.time()
            end
            done(true)
        else
            done(false)
        end
    end)
end

function Reg.maybeRefreshScenarios()
    if os.time() - (QA.scenarios.fetchedAt or 0) > 60 then Reg.refreshScenarios() end
end

-- --- tester access ---------------------------------------------------------------------

local accessCache = {}

local function localAccess(src)
    if Config.access.ace and IsPlayerAceAllowed(src, Config.access.ace) then return true, 'ace' end
    local ok, allowed = pcall(Kora.permissions.hasLevel, src, Config.access.level, Config.access.levels, Config.access.prefix)
    if ok and allowed then return true, Config.access.level end
    return false
end

function Reg.isAdmin(src)
    local ok, allowed = pcall(Kora.permissions.hasLevel, src, Config.access.adminLevel, Config.access.levels, Config.access.prefix)
    return ok and allowed == true
end

---Blocking (thread only). Returns allowed, role.
function Reg.checkAccess(src)
    local discordId = U.discordOf(src)
    local cached = discordId and accessCache[discordId]
    if cached and os.time() - cached.at < Config.access.accessCacheSeconds then
        if cached.allowed then return true, cached.role end
        return localAccess(src)
    end
    if discordId and P.configured() then
        local status, data = P.call('GET', '/tester?discordId=' .. P.urlEncode(discordId))
        if P.ok(status) and type(data) == 'table' then
            accessCache[discordId] = { at = os.time(), allowed = data.allowed == true, role = data.role }
            if data.allowed == true then return true, data.role end
        end
    end
    return localAccess(src)
end
