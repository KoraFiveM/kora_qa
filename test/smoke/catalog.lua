-- steps.json loading, definition shape, pattern overlap guards and argument caps.
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'
local support = dofile(scriptDir .. '../support.lua')
local h = support.harness
support.boot({ server = false })

local defs = json.decode(support.readFile(support.root .. 'shared/steps.json'))
local catalog, errors = QACatalog.new(defs)

h.test('steps.json is a non-empty array of valid StepDefs', function()
    h.assertTrue(type(defs) == 'table' and #defs >= 60, 'expected the full built-in library')
    h.assertEqual(#errors, 0, 'invalid definitions: ' .. table.concat(errors, '; '))
    h.assertEqual(#catalog.list, #defs, 'every definition registered')
end)

h.test('ids and patterns are unique; every step names its resource', function()
    local ids, patterns = {}, {}
    for _, def in ipairs(defs) do
        h.assertFalse(ids[def.id], 'duplicate id ' .. def.id)
        h.assertFalse(patterns[def.pattern], 'duplicate pattern ' .. def.pattern)
        ids[def.id], patterns[def.pattern] = true, true
        h.assertEqual(def.resource, 'kora_qa', def.id .. ' resource')
        h.assertTrue(type(def.description) == 'string' and #def.description > 10, def.id .. ' needs a description')
        h.assertTrue(type(def.example) == 'string', def.id .. ' needs an example')
    end
end)

h.test('fallbacks are the only priority -100 steps; named manual steps are Pass/Fail', function()
    h.assertEqual(catalog.byId['manual.do'].pattern, 'I manually: {}', 'manual.do pattern')
    h.assertEqual(catalog.byId['manual.confirm'].pattern, 'I confirm: {}', 'manual.confirm pattern')
    local namedManual = { ['hud.shows'] = true, ['console.f8_shows'] = true, ['console.f8_clean'] = true }
    for _, def in ipairs(defs) do
        local fallback = def.id == 'manual.do' or def.id == 'manual.confirm'
        h.assertEqual(def.priority, fallback and -100 or 0, def.id .. ' priority')
        h.assertEqual(def.kind == 'manual', fallback or namedManual[def.id] == true, def.id .. ' kind')
        if namedManual[def.id] then h.assertTrue(def.pattern:find('should', 1, true), def.id .. ' reads as an assertion') end
    end
end)

h.test('checks are phrased with "should"/"opens"/"is called" so they never collide with setup phrasing', function()
    for _, def in ipairs(defs) do
        if def.kind == 'check' then
            local ok = def.pattern:find('should', 1, true) or def.pattern:find(' opens$') or def.pattern:find('is called$')
            h.assertTrue(ok, def.id .. ' check pattern must read as an assertion: ' .. def.pattern)
        end
        if def.kind == 'setup' then
            h.assertFalse(def.pattern:find('should', 1, true), def.id .. ' setup must not use "should"')
        end
    end
end)

h.test('validateDef rejects malformed definitions', function()
    h.assertFalse(QACatalog.validateDef({ id = 'bad', pattern = 'x', kind = 'setup', side = 'server', args = {} }), 'id needs a group')
    h.assertFalse(QACatalog.validateDef({ id = 'a.b', pattern = 'I have {int}', kind = 'setup', side = 'server', args = {} }), 'arg count mismatch')
    h.assertFalse(QACatalog.validateDef({ id = 'a.b', pattern = 'x', kind = 'nope', side = 'server', args = {} }), 'unknown kind')
    h.assertTrue(QACatalog.validateDef({ id = 'a.b', pattern = 'I have {int}', kind = 'setup', side = 'server', args = { { name = 'n', type = 'int' } } }), 'valid def')
end)

local aliases = {
    kora_qa = { locations = { square = { x = 1, y = 2, z = 3, h = 90 } }, vehicles = { car = 'sultan', tank = 'rhino' }, peds = {}, props = {}, fixtures = { f = { steps = {} } } },
    kora_fishing = { locations = { pier = { -1850, -1231, 13 } }, vehicles = {}, peds = {}, props = {}, fixtures = {} },
}
local function env(caps, resource)
    local c = {}
    for k, v in pairs(Config.caps) do c[k] = v end
    for k, v in pairs(caps or {}) do c[k] = v end
    return { caps = c, aliases = aliases, resource = resource or 'kora_fishing' }
end
local function validate(id, args, caps, resource) return QACatalog.validateArgs(catalog.byId[id], args, env(caps, resource)) end

h.test('item counts are capped and typed', function()
    local p = validate('items.have', { 3, 'Water' })
    h.assertEqual(p.count, 3, 'count')
    h.assertEqual(p.item, 'water', 'item names are lower-cased')
    h.assertFalse(validate('items.have', { Config.caps.maxItemCount + 1, 'water' }), 'over maxItemCount is refused')
    h.assertFalse(validate('items.have', { 0, 'water' }), 'min 1')
    h.assertFalse(validate('items.have', { 1.5, 'water' }), 'int only')
    h.assertFalse(validate('items.have', { '3', 'water' }), 'numbers must be numbers')
    h.assertFalse(validate('items.have', { 3 }), 'missing argument')
    h.assertFalse(validate('items.have', { 3, 'water; drop table' }), 'item name pattern')
end)

h.test('item deny/allow lists apply', function()
    h.assertFalse(validate('items.have', { 1, 'weapon_rpg' }, { itemDeny = { 'WEAPON_RPG' } }), 'denylist is case-insensitive')
    h.assertFalse(validate('items.have', { 1, 'lockpick' }, { itemAllow = { 'water' } }), 'allowlist excludes others')
    h.assertTrue(validate('items.have', { 1, 'water' }, { itemAllow = { 'water' } }), 'allowlist admits listed items')
end)

h.test('money accounts and ceilings', function()
    h.assertTrue(validate('money.set', { 'cash', Config.caps.maxMoney }), 'at the cap is fine')
    h.assertFalse(validate('money.set', { 'cash', Config.caps.maxMoney + 1 }), 'over maxMoney refused')
    h.assertFalse(validate('money.set', { 'gold', 10 }), 'unknown account refused')
    h.assertFalse(validate('money.set', { 'cash', -5 }), 'negative refused')
end)

h.test('aliases resolve from the scenario resource, then kora_qa, or explicitly', function()
    local p = validate('teleport.location', { 'pier' })
    h.assertEqual(p.location.x, -1850, 'array-form location normalised')
    h.assertEqual(p.location.name, 'pier', 'keeps its name')
    h.assertEqual(validate('teleport.location', { 'square' }).location.h, 90, 'falls back to kora_qa aliases')
    h.assertEqual(validate('teleport.location', { 'kora_fishing:pier' }, nil, 'kora_hud').location.y, -1231, 'explicit resource:name')
    h.assertFalse(validate('teleport.location', { 'nowhere' }), 'unknown alias refused')
end)

h.test('models: aliases, raw names and the denylist', function()
    h.assertEqual(validate('vehicle.spawn', { 'car' }).model, 'sultan', 'alias resolves to model')
    h.assertEqual(validate('vehicle.spawn', { 'Adder' }).model, 'adder', 'raw model names allowed')
    h.assertFalse(validate('vehicle.spawn', { 'tank' }), 'alias to a denied model refused')
    h.assertFalse(validate('vehicle.spawn', { 'rhino' }), 'denied model refused')
    h.assertFalse(validate('vehicle.spawn', { 'bad model' }), 'model pattern')
end)

h.test('commands, weather, wait and free text', function()
    local p = validate('command.run', { '/id toggle' })
    h.assertEqual(p.command.name, 'id', 'command name')
    h.assertEqual(p.command.text, 'id toggle', 'command text without slash')
    h.assertEqual(validate('world.weather', { 'rain' }).weather, 'RAIN', 'weather upper-cased')
    h.assertFalse(validate('world.weather', { 'lava' }), 'unknown weather refused')
    h.assertFalse(validate('wait.seconds', { Config.caps.maxWaitSeconds + 1 }), 'wait capped')
    h.assertFalse(validate('metadata.set', { 'citizenid', 'x' }), 'metadata denylist')
    h.assertTrue(validate('manual.do', { string.rep('a', 500) }), 'manual text up to 500')
    h.assertFalse(validate('manual.do', { string.rep('a', 501) }), 'manual text capped')
    h.assertTrue(validate('teleport.coords', { 1, 2.5, 3 }), 'floats accept integers')
    h.assertFalse(validate('teleport.coords', { 1, 2, 99999 }), 'coordinate bounds')
end)

h.test('v2 allow rules: keys and notification types', function()
    dofile(support.root .. 'shared/keys.lua')
    h.assertEqual(validate('key.press', { 'left alt' }).key, 'ALT', 'key aliases normalised')
    h.assertEqual(validate('key.press', { 'f7' }).key, 'F7', 'upper-cased')
    h.assertEqual(validate('key.press', { 'NUMPAD9' }).key, 'NUMPAD9', 'unknown keys still accepted (manual Done)')
    h.assertFalse(validate('key.press', { 'a;b' }), 'junk refused')
    h.assertEqual(QAKeys.controlsFor('tab')[1], 37, 'TAB watches control 37')
    h.assertEqual(QAKeys.controlsFor('NUMPAD9'), nil, 'no controls for unknown keys')
    h.assertEqual(validate('notify.type', { 'warn' }).type, 'warning', 'notification type alias')
    h.assertFalse(validate('notify.type', { 'purple' }), 'unknown notification type refused')
    h.assertFalse(validate('mark.fires_within', { 'm', Config.caps.maxWaitSeconds + 1 }), 'mark deadline capped')
end)

h.test('ui-ids.json lists real AppShell ids and menu titles', function()
    local ids = json.decode(support.readFile(support.root .. 'shared/ui-ids.json'))
    h.assertTrue(#ids.apps >= 30, 'apps listed: ' .. #ids.apps)
    local byId = {}
    for _, app in ipairs(ids.apps) do
        h.assertTrue(app.id:match('^[%w_%-]+:[%w_:%-]+$') ~= nil, 'app id shape ' .. app.id)
        byId[app.id] = app
    end
    h.assertTrue(byId['qbmdt:terminal'] and byId['qbmultijob:roster'] and byId['kora_qa:runner'], 'MDT, job roster and runner present')
    h.assertTrue(#ids.menus > 0, 'menu titles listed')
end)

h.report('kora_qa catalog')
