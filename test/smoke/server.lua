-- Server realm: step implementations bound to the catalog, tests/qa.lua sandbox,
-- run lifecycle with undo, caps re-validated at execute, report builder, ctl
-- handler and the offline queue.
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'
local support = dofile(scriptDir .. '../support.lua')
local h = support.harness
support.boot()
local game = support.game
local R, E, P, Reg = QA.runs, QA.engine, QA.panel, QA.registry

support.httpResponder = function() return 0 end -- panel offline unless a test says otherwise

h.test('every built-in step has an implementation and undo where it promises one', function()
    for _, def in ipairs(QA.catalog.list) do
        local impl = QA.steps.impl[def.id]
        if def.kind == 'manual' then
            h.assertTrue(impl == nil, def.id .. ' manual steps need no implementation')
        else
            h.assertTrue(impl ~= nil, def.id .. ' has no implementation')
            if def.kind == 'setup' then h.assertTrue(impl.setup or impl.fixture, def.id .. ' needs setup') end
            if def.kind == 'check' then h.assertTrue(impl.check, def.id .. ' needs check') end
            if def.kind == 'observed' then h.assertTrue(impl.observe, def.id .. ' needs observe') end
            if def.undo then h.assertTrue(impl.undo or impl.fixture, def.id .. ' says undo=true but has no undo') end
        end
    end
    for id in pairs(QA.steps.impl) do
        h.assertTrue(QA.catalog.byId[id] ~= nil, id .. ' is implemented but not in steps.json')
    end
end)

h.test('tests/qa.lua runs with no globals and an instruction budget', function()
    local result = Reg.sandboxLoad('return { print = print, os = os, exports = exports, n = 1 }', '=t')
    h.assertEqual(result.n, 1, 'plain tables come back')
    h.assertEqual(result.print, nil, 'no print')
    h.assertEqual(result.os, nil, 'no os')
    h.assertEqual(result.exports, nil, 'no exports')
    local looped, err = Reg.sandboxLoad('while true do end', '=loop')
    h.assertEqual(looped, nil, 'infinite loops are stopped')
    h.assertTrue(tostring(err):find('too long', 1, true), 'with a clear error: ' .. tostring(err))
    h.assertEqual(Reg.sandboxLoad('return 5', '=n'), nil, 'must return a table')
    h.assertEqual(Reg.sandboxLoad('os.exit(1)', '=exit'), nil, 'calling a missing global fails safely')
end)

h.test('alias cleaning keeps valid entries and drops bad ones', function()
    local warnings = {}
    local clean = Reg.cleanAliases({
        locations = { ok = { x = 1, y = 2, z = 3 }, bad = { x = 'a' } },
        vehicles = { car = 'sultan', bad = 'two words' },
        fixtures = { good = { steps = { { step = 'items.have', args = { 1, 'water' } } } }, bad = { steps = { 'nope' } } },
    }, function(m) warnings[#warnings + 1] = m end)
    h.assertTrue(clean.locations.ok and not clean.locations.bad, 'locations filtered')
    h.assertTrue(clean.vehicles.car == 'sultan' and not clean.vehicles.bad, 'vehicles filtered')
    h.assertTrue(clean.fixtures.good and not clean.fixtures.bad, 'fixtures filtered')
    h.assertEqual(#warnings, 3, 'each bad entry warned')
    h.assertTrue(Reg.loadAliasesFor('kora_qa'), "kora_qa's own tests/qa.lua loads")
    h.assertTrue(QA.aliases.kora_qa.fixtures.picnic ~= nil, 'picnic fixture present')
    local panel = Reg.aliasesForPanel().kora_qa
    h.assertEqual(panel.fixtures[1], 'picnic', 'fixtures posted as names only')
end)

local function scenario(id, steps)
    local out = { id = id, resource = 'kora_qa', name = id, hash = 'h-' .. id, tags = { '@kora_qa' }, target = 1, steps = {} }
    for i, s in ipairs(steps) do
        out.steps[i] = { idx = i - 1, keyword = s[1], text = s[2], defId = s[3], kind = QA.catalog.byId[s[3]].kind, args = s[4] or {} }
    end
    QA.scenarios.byId[id] = out
    QA.scenarios.list[#QA.scenarios.list + 1] = out
    return out
end

Reg.checkAccess = function() return true, 'tester' end

h.test('a full run: setup, auto-check, manual pass, teardown restores everything', function()
    scenario('qa:happy', {
        { 'Given', 'I have 3 "water"', 'items.have', { 3, 'water' } },
        { 'And', 'my cash balance is 500', 'money.set', { 'cash', 500 } },
        { 'And', 'my job is "police"', 'job.set', { 'police' } },
        { 'And', 'a "test_car" is spawned in front of me with keys', 'vehicle.spawn_keys', { 'test_car' } },
        { 'Then', 'I should have 3 "water"', 'items.count', { 3, 'water' } },
        { 'Then', 'I confirm: it looks right', 'manual.confirm', { 'it looks right' } },
    })
    local ok, err = E.start(1, 'qa:happy')
    h.assertTrue(ok, 'run starts: ' .. tostring(err))
    local run = R.get(1)
    h.assertTrue(support.active[1], 'kora_lib told the player is active')
    h.assertEqual(run.steps[1].status, 'pending', 'setup waits for the button')

    -- A client can only act on the current step.
    local okWrong = E.setup(run, 3)
    h.assertFalse(okWrong, 'non-current setup refused')

    local all, n = E.setupAll(run)
    h.assertTrue(all, 'all setup ran: ' .. tostring(n))
    h.assertEqual(n, 4, 'four setup steps')
    h.assertEqual(game.items[1] and (function() local c = 0; for _, i in pairs(game.items[1]) do if i.name == 'water' then c = c + i.amount end end; return c end)(), 3, '3 water now')
    h.assertEqual(game.money[1].cash, 500, 'cash set')
    h.assertEqual(game.jobs[1].name, 'police', 'job set')
    local vehicle = run.vehicle
    h.assertTrue(vehicle and game.entities[vehicle], 'vehicle spawned')
    h.assertEqual(#run.undo, 4, 'one undo record per state change')

    E.evaluate(run, 5, false)
    h.assertEqual(run.steps[5].status, 'passed', 'auto-check passed')
    h.assertEqual(run.current, 6, 'moved on to the manual step')
    h.assertEqual(run.steps[6].status, 'running', 'manual step waits')
    h.assertFalse(E.testerAction(run, 'done', 6), 'confirm steps need Pass/Fail, not Done')
    h.assertTrue(E.testerAction(run, 'pass', 6), 'tester passes')

    h.assertEqual(R.get(1), nil, 'run finished')
    h.assertEqual(run.status, 'passed', 'passed')
    h.assertEqual(game.money[1].cash, 100, 'cash restored')
    h.assertEqual(game.jobs[1].name, 'unemployed', 'job restored')
    h.assertEqual(game.entities[vehicle], nil, 'vehicle deleted')
    local water = 0
    for _, i in pairs(game.items[1]) do if i.name == 'water' then water = water + i.amount end end
    h.assertEqual(water, 1, 'water back to 1')
    h.assertFalse(support.active[1], 'player no longer active')
    local index = json.decode(support.files['queue/index.json'])
    h.assertEqual(#index, 1, 'offline result queued')
    local job = json.decode(support.files['queue/' .. index[1] .. '.json'])
    h.assertEqual(job.kind, 'run', 'queued as a full run')
    h.assertEqual(job.finish.status, 'passed', 'with its status')
    h.assertEqual(#job.steps, 6, 'and every step result')
end)

h.test('caps are re-validated at execute time; preflight refuses out-of-cap scenarios', function()
    scenario('qa:greedy', { { 'Given', 'I have 999 "water"', 'items.have', { 999, 'water' } } })
    local ok, err = E.start(1, 'qa:greedy')
    h.assertFalse(ok, 'out-of-cap scenario refused')
    h.assertTrue(tostring(err):find('maxItemCount', 1, true), 'names the cap: ' .. tostring(err))

    scenario('qa:tamper', { { 'Given', 'I have 2 "water"', 'items.have', { 2, 'water' } } })
    h.assertTrue(E.start(1, 'qa:tamper'), 'valid scenario starts')
    local run = R.get(1)
    run.steps[1].args = { 999, 'water' } -- changed after start
    local okSetup = E.setup(run, 1)
    h.assertFalse(okSetup, 'setup refuses the out-of-cap value')
    h.assertEqual(run.steps[1].status, 'blocked', 'step blocked')
    h.assertEqual(#run.undo, 0, 'nothing executed')
    E.finish(run, 'aborted', {})
    h.assertEqual(R.get(1), nil, 'aborted run cleared')
end)

h.test('failed checks produce a report with expected/actual; disputes flip results', function()
    scenario('qa:fail', {
        { 'Given', 'I have 2 "water"', 'items.have', { 2, 'water' } },
        { 'Then', 'I should have 5 "water"', 'items.count', { 5, 'water' } },
        { 'Then', 'my cash balance should be 100', 'money.equals', { 'cash', 100 } },
    })
    h.assertTrue(E.start(1, 'qa:fail'), 'starts')
    local run = R.get(1)
    E.setupAll(run)
    E.evaluate(run, 2, true)
    h.assertEqual(run.steps[2].status, 'failed', 'check failed after the timeout')
    h.assertEqual(run.failedIdx, 2, 'failed index recorded')
    h.assertEqual(run.current, 2, 'run stops at the failure')

    h.assertTrue(E.testerAction(run, 'dispute', 2, 'it showed 5 in my inventory'), 'dispute accepted')
    h.assertEqual(run.steps[2].status, 'passed', 'disputed failure becomes a pass')
    h.assertTrue(run.steps[2].detail.disputed, 'marked disputed')
    h.assertEqual(run.current, 3, 'run continues')

    h.assertTrue(E.testerAction(run, 'fail', 3, 'balance looked wrong'), 'tester fails the check')
    local before = #json.decode(support.files['queue/index.json'])
    support.clientHandler = function(op) if op == 'context' then return true, { street = 'Test St' } end return true end
    E.finish(run, 'failed', { idx = 2, note = 'balance looked wrong', frequency = 'sometimes' })
    local index = json.decode(support.files['queue/index.json'])
    h.assertEqual(#index, before + 1, 'report queued')
    local job = json.decode(support.files['queue/' .. index[#index] .. '.json'])
    local report = job.finish.context
    h.assertEqual(job.finish.status, 'failed', 'failed run')
    h.assertEqual(report.v, 1, 'report version')
    h.assertEqual(report.scenario.id, 'qa:fail', 'scenario id')
    h.assertEqual(report.failedIdx, 2, 'failed step index')
    h.assertEqual(report.note, 'balance looked wrong', 'tester note')
    h.assertEqual(report.frequency, 'sometimes', 'frequency')
    h.assertEqual(report.actual, 'balance looked wrong', 'actual from the failed step')
    h.assertEqual(#report.steps, 3, 'all steps')
    h.assertEqual(report.steps[2].status, 'passed', 'disputed step kept')
    h.assertEqual(report.player.street, 'Test St', 'client context included')
    h.assertTrue(type(report.inventoryBefore) == 'table' and #report.inventoryBefore >= 1, 'inventory before')
    h.assertTrue(report.screenshot and report.screenshot.available == false, 'screenshot failure recorded, report still sent')
    support.clientHandler = nil
end)

h.test('observers complete from events; Done records unverified', function()
    scenario('qa:observe', {
        { 'When', 'the "shop:purchase" mark fires', 'mark.fires', { 'shop:purchase' } },
        { 'When', 'I use a "water"', 'item.use', { 'water' } },
        { 'Then', 'I should see a notification containing "Thirst"', 'notify.contains', { 'Thirst' } },
        { 'When', 'I manually: wave', 'manual.do', { 'wave' } },
    })
    h.assertTrue(E.start(1, 'qa:observe'), 'starts')
    local run = R.get(1)
    E.onEvent(1, { type = 'mark', name = 'other' })
    h.assertEqual(run.steps[1].status, 'running', 'other marks do not match')
    E.onEvent(nil, { type = 'mark', name = 'shop:purchase' })
    h.assertEqual(run.steps[1].status, 'passed', 'broadcast mark matched')
    h.assertTrue(E.testerAction(run, 'done', 2), 'Done on an observed step')
    h.assertEqual(run.steps[2].status, 'unverified', 'recorded as unverified')
    E.onEvent(1, { type = 'notify', data = { message = 'Thirst quenched' }, side = 'client' })
    E.evaluate(run, 3, false)
    h.assertEqual(run.steps[3].status, 'passed', 'notification check sees the timeline')
    h.assertTrue(E.testerAction(run, 'done', 4), 'manual.do Done')
    h.assertEqual(R.get(1), nil, 'run complete')
    h.assertEqual(run.status, 'passed', 'unverified steps do not fail a run')
end)

h.test('undo bookkeeping unwinds in reverse and survives a failing record', function()
    local run = { undo = {} }
    R.pushUndo(run, 0, 'a', { n = 1 })
    R.pushUndo(run, 1, 'b', { n = 2 })
    R.pushUndo(run, 2, 'c', { n = 3 })
    local order = {}
    local log = R.unwind(run, function(record)
        order[#order + 1] = record.id
        if record.id == 'b' then error('boom') end
    end)
    h.assertEqual(table.concat(order, ''), 'cba', 'reverse order')
    h.assertEqual(#run.undo, 0, 'stack emptied')
    h.assertFalse(log[2].ok, 'failure logged')
    h.assertTrue(log[3].ok, 'later records still ran')
end)

h.test('freeform report builder has the same context minus scenario data', function()
    local report = R.buildReport(nil, { note = 'door stuck', frequency = 'once' }, { player = { coords = { x = 1 } }, inventoryAfter = {}, resources = {}, timeline = {}, console = {} })
    h.assertEqual(report.scenario, nil, 'no scenario')
    h.assertEqual(report.failedIdx, nil, 'no failed step')
    h.assertEqual(report.note, 'door stuck', 'note')
    h.assertEqual(#report.steps, 0, 'no steps')
end)

local function ctl(address, auth, body)
    local response = {}
    local req = {
        path = '/ctl', method = 'POST', address = address, headers = { Authorization = auth },
        setDataHandler = function(fn) fn(json.encode(body)) end,
    }
    local res = { writeHead = function(code) response.code = code end, send = function(data) response.body = json.decode(data) end }
    support.http(req, res)
    return response.code, response.body
end

h.test('ctl: loopback + bearer only; restart guards; notify by discord id', function()
    h.assertEqual(ctl('10.0.0.5:5000', 'Bearer test-secret', { cmd = 'reload' }), 403, 'non-loopback refused')
    h.assertEqual(ctl('127.0.0.1:5000', 'Bearer nope', { cmd = 'reload' }), 401, 'bad secret refused')
    h.assertEqual(ctl('127.0.0.1:5000', nil, { cmd = 'reload' }), 401, 'missing secret refused')
    h.assertEqual(ctl('127.0.0.1:5000', 'Bearer test-secret', { cmd = 'restart', name = 'kora_qa' }), 403, 'kora_qa never restarted')
    h.assertEqual(ctl('127.0.0.1:5000', 'Bearer test-secret', { cmd = 'restart', name = 'does_not_exist' }), 404, 'unknown resource')
    local executed = #support.net.executedCommands
    h.assertEqual(ctl('127.0.0.1', 'Bearer test-secret', { cmd = 'restart', name = 'kora_vehiclekeys' }), 200, 'restart accepted')
    h.assertEqual(support.net.executedCommands[executed + 1], 'ensure kora_vehiclekeys', 'ensure issued')
    local code, body = ctl('127.0.0.1:1', 'Bearer test-secret', { cmd = 'notify', discordId = '123456789012345678', title = 'Retest', message = 'Fix ready' })
    h.assertEqual(code, 200, 'notify ok')
    h.assertTrue(body.delivered, 'delivered to the online player')
    local _, nobody = ctl('127.0.0.1:1', 'Bearer test-secret', { cmd = 'notify', discordId = '999999999999999999' })
    h.assertFalse(nobody.delivered, 'nobody online with that id')
    h.assertEqual(ctl('127.0.0.1:1', 'Bearer test-secret', { cmd = 'format_disk' }), 400, 'unknown cmd')
end)

h.test('offline queue replays runs in order once the panel answers', function()
    local calls = {}
    support.httpResponder = function(url, method, body)
        calls[#calls + 1] = method .. ' ' .. url:gsub('^http://panel.test/qa/game', '')
        if url:find('/runs$') then return 200, { runId = 42 } end
        if url:find('/finish$') then return 200, { ok = true, issueId = body and body.status == 'failed' and '123456789012345678' or nil } end
        return 200, { ok = true }
    end
    P.flush()
    h.assertEqual(P.queueSize(), 0, 'queue drained')
    h.assertEqual(calls[1], 'POST /runs', 'run created first')
    local finishes = 0
    for _, call in ipairs(calls) do if call:find('/finish$') then finishes = finishes + 1 end end
    h.assertTrue(finishes >= 3, 'every queued run finished: ' .. finishes)
    for _, request in ipairs(support.requests) do
        if request.url:find('panel.test', 1, true) then
            h.assertEqual(request.headers.Authorization, 'Bearer test-secret', 'bearer on every request')
        end
    end
end)

h.test('v2: marks with data / deadlines, key presses, chat, target options', function()
    scenario('qa:v2events', {
        { 'When', 'the "fish:caught" mark fires with "fish.kind" = "cod"', 'mark.fires_with', { 'fish:caught', 'fish.kind', 'cod' } },
        { 'When', 'I press the "E" key', 'key.press', { 'e' } },
        { 'Then', 'the chat should show "Welcome"', 'chat.shows', { 'Welcome' } },
        { 'When', 'I select the "Open trunk" target option', 'target.option', { 'Open trunk' } },
        { 'When', 'the "dispatch:created" mark fires within 2 seconds', 'mark.fires_within', { 'dispatch:created', 2 } },
    })
    h.assertTrue(E.start(1, 'qa:v2events'), 'starts')
    local run = R.get(1)
    E.onEvent(1, { type = 'mark', name = 'fish:caught', data = { fish = { kind = 'salmon' } } })
    h.assertEqual(run.steps[1].status, 'running', 'wrong data value does not match')
    E.onEvent(1, { type = 'mark', name = 'fish:caught', data = { fish = { kind = 'cod' } } })
    h.assertEqual(run.steps[1].status, 'passed', 'dotted data path matched')
    h.assertEqual(R.view(run).steps[2].key, 'E', 'the client is told which key to watch')

    local clientEvent = support.registered['kora_qa:clientEvent']
    clientEvent(1, { type = 'key', name = 'F' })
    h.assertEqual(run.steps[2].status, 'running', 'other keys ignored')
    clientEvent(2, { type = 'key', name = 'E' })
    h.assertEqual(run.steps[2].status, 'running', 'players without a run are ignored')
    clientEvent(1, { type = 'evil', name = 'E' })
    clientEvent(1, { type = 'key', name = 'e' })
    h.assertEqual(run.steps[2].status, 'passed', 'key press observed')

    clientEvent(1, { type = 'chat', data = { text = 'SYSTEM: Welcome to Kora' } })
    E.evaluate(run, 3, false)
    h.assertEqual(run.steps[3].status, 'passed', 'chat check sees forwarded chat lines')

    E.onEvent(1, { type = 'mark', name = 'target:option', data = { label = 'Open Trunk', name = 'trunk', resource = 'kora_vehiclekeys' }, side = 'client' })
    h.assertEqual(run.steps[4].status, 'passed', 'kora_target mark completes the option step (label, case-insensitive)')

    local step = run.steps[5]
    step.startedAt = QA.util.now() - 3000
    support.net.step() -- ticker
    h.assertEqual(step.status, 'failed', 'deadline missed -> auto failure')
    h.assertTrue(tostring(step.detail.actual):find('within 2 s', 1, true), 'says why')
    E.finish(run, 'aborted', {})
end)

h.test('v2: probe-backed checks, engine, metadata deltas, notifications, progress, text UI, console', function()
    game.meta[1].hunger = 50
    scenario('qa:v2checks', {
        { 'Given', 'a "test_car" is spawned in front of me', 'vehicle.spawn', { 'test_car' } },
        { 'And', 'the vehicle engine is running', 'vehicle.engine_on', {} },
        { 'Then', 'the vehicle engine should be running', 'vehicle.engine_on_check', {} },
        { 'Then', 'the HUD should be visible', 'hud.visible', {} },
        { 'Then', 'the seatbelt indicator should be off', 'hud.seatbelt_off', {} },
        { 'Then', 'the "qbmdt:terminal" app should be open', 'nui.app_open', { 'qbmdt:terminal' } },
        { 'Then', 'my metadata "hunger" should have changed by 20', 'metadata.changed', { 'hunger', 20 } },
        { 'Then', 'I should see an error notification', 'notify.type', { 'error' } },
        { 'Then', 'a progress bar labelled "Fish" should run', 'progress.labelled', { 'Fish' } },
        { 'Then', 'the text UI should show "[E]"', 'textui.shows', { '[E]' } },
        { 'Then', 'the server console should show "doors loaded"', 'console.server_shows', { 'doors loaded' } },
        { 'Then', 'the F8 console should show no errors', 'console.f8_clean', {} },
    })
    support.clientHandler = function(op, data)
        if op == 'engineState' then game.entities[data.netId].engine = data.on; return true end
        if op == 'probe' then return true, { hud = true, seatbelt = false, minimap = true, app = data.app == 'qbmdt:terminal' } end
        return true
    end
    h.assertTrue(E.start(1, 'qa:v2checks'), 'starts')
    local run = R.get(1)
    h.assertEqual(run.snapshot.metadata.hunger, 50, 'scalar metadata snapshotted')
    h.assertTrue(E.setupAll(run), 'spawn + engine on')
    local vehicle = run.vehicle
    h.assertTrue(game.entities[vehicle].engine, 'engine started through the client op')
    for i = 3, 6 do E.evaluate(run, i, true); h.assertEqual(run.steps[i].status, 'passed', run.steps[i].text) end
    game.meta[1].hunger = 70
    E.evaluate(run, 7, true)
    h.assertEqual(run.steps[7].status, 'passed', 'metadata delta')
    E.onEvent(1, { type = 'notify', data = { message = 'nope', type = 'error' } })
    E.onEvent(1, { type = 'progress', name = 'start', data = { label = 'Fishing...' } })
    E.onEvent(1, { type = 'textui', data = { text = '[E] Open door' } })
    support.console('kora_doorlock', '[kora_doorlock] 12 doors loaded')
    for i = 8, 11 do E.evaluate(run, i, true); h.assertEqual(run.steps[i].status, 'passed', run.steps[i].text) end
    h.assertEqual(run.steps[12].status, 'running', 'F8 step waits for the tester')
    h.assertFalse(E.testerAction(run, 'done', 12), 'F8 manual step needs Pass/Fail')
    h.assertTrue(E.testerAction(run, 'pass', 12), 'tester passes it')
    h.assertEqual(run.status, 'passed', 'run passed')
    h.assertEqual(game.entities[vehicle], nil, 'vehicle removed in teardown')
    support.clientHandler = nil
end)

h.test('v2: failing probe checks report actual state', function()
    scenario('qa:v2fail', { { 'Then', 'the minimap should be hidden', 'hud.minimap_hidden', {} } })
    support.clientHandler = function(op) if op == 'probe' then return true, { minimap = true } end return true end
    h.assertTrue(E.start(1, 'qa:v2fail'), 'starts')
    local run = R.get(1)
    E.evaluate(run, 1, true)
    h.assertEqual(run.steps[1].status, 'failed', 'fails')
    h.assertEqual(run.steps[1].detail.actual, 'minimap visible', 'actual state: ' .. json.encode(run.steps[1].detail))
    E.finish(run, 'aborted', {})
    support.clientHandler = nil
end)

h.report('kora_qa server')
