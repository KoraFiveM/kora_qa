-- Renders every runner state through kora_lib's real AppShell validator
-- (modules/nui/client.lua), so a malformed block/action fails here instead of
-- in game.
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'
local root = scriptDir .. '../../'
local koraLib = os.getenv('KORA_LIB_DIR') or (root .. '../../[pre]/kora_lib/')
package.path = koraLib .. 'test/?.lua;' .. package.path

local h = require('harness')
local mocks = require('mocks')
local net = mocks.install()

dofile(koraLib .. 'config.lua')
dofile(koraLib .. 'build/initiate.lua')
dofile(koraLib .. 'local/resources/client.lua')
dofile(koraLib .. 'modules/util/shared.lua')
_G.RegisterNUICallback = function() end
_G.SendNUIMessage = function() end
_G.SetNuiFocus = function() end
_G.SetNuiFocusKeepInput = function() end
_G.IsNuiFocusKeepingInput = function() return false end
_G.QBTheme = { apply = function() end }
dofile(koraLib .. 'modules/nui/client.lua')

-- Pretend the app is open so every push re-renders through updateApp (which validates).
Kora.nui.isAppOpen = function() return true end
local updates = 0
local realUpdate = Kora.nui.updateApp
Kora.nui.updateApp = function(id, update)
    updates = updates + 1
    return realUpdate(id, update)
end

local pushHandlers, sent, notes = {}, {}, {}
Kora.events = {
    onPush = function(name, fn) pushHandlers[name] = fn end,
    trigger = function(name, action, data) sent[#sent + 1] = { name = name, action = action, data = data }; return true end,
}
Kora.keybind = { add = function() end }
Kora.notify = { send = function(payload) notes[#notes + 1] = payload end }
Kora.qa = { setActive = function() end }
_G.IsPauseMenuActive = function() return false end
_G.GetCloudTimeAsInt = function() return 1800000000 end

dofile(root .. 'config.lua')
dofile(root .. 'client/exec.lua')
dofile(root .. 'client/ui.lua')
-- ui.lua registers its app in a thread after Wait(1000): resume it once.
net.step()

local function push(name, ...) pushHandlers[name](...) end

h.test('the runner registers and renders the first state', function()
    h.assertTrue(pushHandlers['kora_qa:run'] ~= nil and pushHandlers['kora_qa:exec'] ~= nil, 'push handlers registered')
    local before = updates
    pushHandlers['kora_qa:data']({ kind = 'hello', allowed = true, enabled = true })
    h.assertEqual(updates, before + 1, 'app registered (update accepted)')
end)

local scenarios = {}
for i = 1, 30 do
    scenarios[i] = { id = 'kora_fishing:tests/a.feature:' .. i, name = 'Scenario ' .. i, resource = i % 2 == 0 and 'kora_fishing' or 'kora_hud',
        tags = { '@smoke', '@issue-123456789012345678', '@cat:ui' }, target = 3, passes = i % 4, steps = 5, admin = i == 3, players = 1 }
end

local function runView(statuses, extra)
    local kinds = { 'setup', 'setup', 'observed', 'check', 'manual', 'manual', 'observed' }
    local defs = { 'items.have', 'vehicle.spawn', 'command.run', 'notify.contains', 'manual.do', 'manual.confirm', 'item.use' }
    local steps = {}
    local current = 1
    for i, status in ipairs(statuses) do
        if status == 'pending' or status == 'running' or status == 'failed' or status == 'blocked' then current = current == 1 and i or current end
    end
    for i = 1, #kinds do
        steps[i] = { idx = i - 1, keyword = 'Given', text = 'step ' .. i, kind = kinds[i], defId = defs[i], status = statuses[i] or 'pending',
            current = false, auto = (kinds[i] == 'check' or kinds[i] == 'observed') and (statuses[i] == 'passed' or statuses[i] == 'failed'),
            canRunFor = defs[i] == 'command.run', detail = statuses[i] == 'failed' and 'expected 5, got 2' or nil }
    end
    for i, step in ipairs(steps) do
        if step.status == 'pending' or step.status == 'running' or step.status == 'failed' or step.status == 'blocked' then
            step.current = true
            current = i
            break
        end
    end
    local view = { localId = 'run1', status = 'running', current = current, steps = steps,
        scenario = { id = 's1', name = 'Selling fish', resource = 'kora_fishing', tags = { '@kora_fishing' } } }
    for k, v in pairs(extra or {}) do view[k] = v end
    return view
end

h.test('every runner state passes the AppShell validator', function()
    local okRegister, regErr = pcall(Kora.nui.registerApp, {
        id = 'probe:app', title = 'probe', navigation = { { id = 'a', label = 'a' } },
    })
    h.assertTrue(okRegister, 'validator is live: ' .. tostring(regErr))

    local before = updates
    push('kora_qa:data', { kind = 'scenarios', scenarios = scenarios })
    push('kora_qa:data', { kind = 'scenario', scenario = { id = 's1', name = 'Selling fish', resource = 'kora_fishing', description = 'about',
        tags = { '@kora_fishing' }, steps = { { idx = 0, keyword = 'Given', text = 'I have 1 "fish"', kind = 'setup' }, { idx = 1, keyword = 'Then', text = 'x', kind = 'check' } } } })
    local states = {
        { 'pending' },
        { 'blocked' },
        { 'passed', 'passed', 'running' },
        { 'passed', 'passed', 'unverified', 'running' },
        { 'passed', 'passed', 'passed', 'failed' },
        { 'passed', 'passed', 'passed', 'passed', 'running' },
        { 'passed', 'passed', 'passed', 'passed', 'passed', 'running' },
        { 'passed', 'passed', 'skipped', 'passed', 'passed', 'passed', 'running' },
    }
    for _, statuses in ipairs(states) do push('kora_qa:run', runView(statuses)) end
    push('kora_qa:run', runView({ 'running' }, { busy = true, retest = '123456789012345678' }))
    push('kora_qa:run', runView({ 'passed', 'passed', 'passed', 'failed' }, { failedIdx = 4, status = 'finishing' }))
    push('kora_qa:finished', { status = 'failed', issueId = '123456789012345678', scenario = 'Selling fish' })
    push('kora_qa:finished', { status = 'passed', scenario = 'Selling fish' })
    push('kora_qa:finished', { status = 'aborted' })
    push('kora_qa:data', { kind = 'retests', retests = { { issueId = '123456789012345678', title = 'Fish price', scenarioId = 's1', notFixedCount = 1 }, { issueId = '223456789012345678', title = 'No scenario' } } })
    push('kora_qa:data', { kind = 'runs', runs = { { name = 'Selling fish', status = 'passed', at = 1799999000000 }, { scenarioId = 'x', status = 'aborted' } } })
    push('kora_qa:data', { kind = 'hello', allowed = false, enabled = false })
    push('kora_qa:notice', { message = 'hi', tone = 'destructive' })
    h.assertTrue(updates - before >= 15, 'each push re-rendered through updateApp: ' .. (updates - before))
    h.assertThrows(function() realUpdate(Config.appId, { navigation = { { id = 'x' } } }) end,
        'sanity: updateApp really validates (a label-less view is rejected)')
end)

h.test('exec ops refuse bad input', function()
    local results = {}
    Kora.events.trigger = function(name, token, okResult, result) results[#results + 1] = { name = name, token = token, ok = okResult, result = result }; return true end
    pushHandlers['kora_qa:exec']('t1', 'nope', {})
    pushHandlers['kora_qa:exec']('t2', 'equip', { weapon = 'not a weapon' })
    pushHandlers['kora_qa:exec']('t3', 'command', { command = '' })
    h.assertEqual(#results, 3, 'every op answers')
    for _, r in ipairs(results) do
        h.assertEqual(r.name, 'kora_qa:execResult', 'answers on execResult')
        h.assertFalse(r.ok, r.token .. ' refused')
    end
end)

h.report('kora_qa client ui')
