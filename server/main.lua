-- Wiring: client actions, client exec results, /kora_qa/ctl, lifecycle.

local U = QA.util
local P = QA.panel
local R = QA.runs
local E = QA.engine
local Reg = QA.registry

local FREQUENCIES = { always = true, sometimes = true, once = true }

local function push(src, name, payload) Kora.events.push(src, name, payload) end

-- --- lists for the client ------------------------------------------------------------

local function scenarioSummaries()
    local out = {}
    for _, s in ipairs(QA.scenarios.list) do
        local admin, players = E.needsOf(s)
        out[#out + 1] = {
            id = s.id, name = s.name, resource = s.resource, tags = s.tags, target = s.target or 1,
            passes = tonumber(s.passes or (type(s.progress) == 'table' and s.progress.passes)) or nil,
            steps = #s.steps, admin = admin, players = players,
        }
    end
    return out
end

local function scenarioDetail(id)
    local s = QA.scenarios.byId[id]
    if not s then return nil end
    local steps = {}
    for i, step in ipairs(s.steps) do
        steps[i] = { idx = step.idx, keyword = step.keyword, text = step.text, kind = step.kind }
    end
    return { id = s.id, name = s.name, resource = s.resource, description = s.description, tags = s.tags, target = s.target, steps = steps }
end

local function sendRetests(src)
    local discordId = U.discordOf(src)
    if not discordId then
        push(src, 'kora_qa:data', { kind = 'retests', retests = {}, error = 'No Discord account linked.' })
        return
    end
    local status, data = P.call('GET', '/retests?discordId=' .. P.urlEncode(discordId))
    local list = P.ok(status) and type(data) == 'table' and type(data.retests) == 'table' and data.retests or {}
    push(src, 'kora_qa:data', { kind = 'retests', retests = list, error = not P.ok(status) and 'The QA panel is unreachable.' or nil })
end

local function sendRuns(src)
    local discordId = U.discordOf(src)
    local runs
    if discordId then
        local status, data = P.call('GET', '/runs?discordId=' .. P.urlEncode(discordId))
        if P.ok(status) and type(data) == 'table' and type(data.runs) == 'table' then runs = data.runs end
        runs = runs or E.history(discordId)
    end
    push(src, 'kora_qa:data', { kind = 'runs', runs = runs or {} })
end

-- --- client actions ---------------------------------------------------------------------------

local busy = {}

local ACTIONS = {}

-- Re-fetch the scenario list (pass counts change after every run) and push it to the player.
-- Used after a run is delivered so progress like 0/1 -> 1/1 shows straight away.
function QA.pushScenarios(src)
    Reg.refreshScenarios(function()
        if GetPlayerName(src) then
            push(src, 'kora_qa:data', { kind = 'scenarios', scenarios = scenarioSummaries(), hash = QA.scenarios.hash })
        end
    end)
end

ACTIONS.hello = function(src)
    local allowed, role = Reg.checkAccess(src)
    push(src, 'kora_qa:data', { kind = 'hello', allowed = allowed, role = role, enabled = U.enabled(), panel = P.online ~= false })
    if allowed then
        -- Show the cached list at once, then the fresh one if the cache is older than a minute.
        push(src, 'kora_qa:data', { kind = 'scenarios', scenarios = scenarioSummaries(), hash = QA.scenarios.hash })
        if os.time() - (QA.scenarios.fetchedAt or 0) > 60 then QA.pushScenarios(src) end
        local run = R.get(src)
        if run then E.push(run) end
    end
end

ACTIONS.scenarios = function(src)
    if not Reg.checkAccess(src) then return end
    U.await(Config.panel.timeoutMs + 1000, function(resolve) Reg.refreshScenarios(resolve) end)
    push(src, 'kora_qa:data', { kind = 'scenarios', scenarios = scenarioSummaries(), hash = QA.scenarios.hash })
end

ACTIONS.scenario = function(src, data)
    if not Reg.checkAccess(src) then return end
    push(src, 'kora_qa:data', { kind = 'scenario', scenario = scenarioDetail(type(data.id) == 'string' and data.id or '') })
end

ACTIONS.start = function(src, data)
    local ok, err = E.start(src, data.id, data.retestIssueId)
    if not ok then E.notice(src, err, 'destructive') end
end

ACTIONS.retests = function(src) if Reg.checkAccess(src) then sendRetests(src) end end
ACTIONS.runs = function(src) if Reg.checkAccess(src) then sendRuns(src) end end

local function withRun(fn)
    return function(src, data)
        local run = R.get(src)
        if not run then return E.notice(src, 'You have no test running.', 'warning') end
        local ok, err = fn(src, run, data)
        if ok == false and err then E.notice(src, err, 'destructive') end
    end
end

local function stepIndex(run, data)
    local idx = tonumber(data.idx)
    if not idx or idx % 1 ~= 0 then return nil end
    for i, step in ipairs(run.steps) do
        if step.idx == idx then return i end
    end
    return nil
end

ACTIONS.setup = withRun(function(_, run, data)
    local i = stepIndex(run, data)
    if not i then return false, 'No such step.' end
    return E.setup(run, i)
end)

ACTIONS.setupAll = withRun(function(_, run) return E.setupAll(run) end)

for _, name in ipairs({ 'done', 'pass', 'fail', 'skip', 'dispute' }) do
    ACTIONS[name] = withRun(function(_, run, data)
        local i = stepIndex(run, data)
        if not i then return false, 'No such step.' end
        return E.testerAction(run, name, i, data.note)
    end)
end

ACTIONS.runFor = withRun(function(src, run, data)
    local i = stepIndex(run, data)
    local step = i and run.steps[i]
    if not step or i ~= run.current or step.defId ~= 'command.run' or step.status ~= 'running' then return false, 'Nothing to run.' end
    local params = step.params
    if not params or not QACatalog.listHas(Config.caps.allowCommands, params.command.name) then
        return false, 'kora_qa may not run this command for you; type it yourself.'
    end
    local ok, err = R.exec(src, 'command', { command = params.command.text })
    if not ok then return false, tostring(err) end
    R.addTimeline(run, 'command', params.command.name, { raw = params.command.text, by = 'kora_qa' }, 'client')
    -- ExecuteCommand on the client gives no result; if no Kora.commands handler
    -- confirms within a moment, the step stays open for Done.
    return true
end)

ACTIONS.report = withRun(function(_, run, data)
    local note = U.cleanText(data.note, Config.report.noteMax, true)
    if not note or #note < 3 then return false, 'Describe what went wrong (required).' end
    local idx = tonumber(data.idx)
    if idx and not stepIndex(run, data) then return false, 'No such step.' end
    return E.finish(run, 'failed', { idx = idx, note = note, frequency = FREQUENCIES[data.frequency] and data.frequency or 'always' })
end)

ACTIONS.abort = withRun(function(_, run) return E.finish(run, 'aborted', {}) end)

ACTIONS.block = withRun(function(_, run, data)
    return E.finish(run, 'blocked', { note = U.cleanText(data.note, Config.report.noteMax, true) or 'could not run this scenario' })
end)

ACTIONS.freeform = function(src, data)
    if not Reg.checkAccess(src) then return E.notice(src, 'Only testers can send reports (log in to the QA panel).', 'destructive') end
    local ok, result = E.freeform(src, data)
    if not ok then return E.notice(src, result, 'destructive') end
    push(src, 'kora_qa:data', { kind = 'freeform', result = result })
end

Kora.events.register('kora_qa:action', function(src, action, data)
    if type(action) ~= 'string' or not ACTIONS[action] then return end
    if not U.enabled() then
        push(src, 'kora_qa:data', { kind = 'hello', allowed = false, enabled = false })
        return
    end
    data = type(data) == 'table' and data or {}
    local exclusive = action ~= 'hello'
    if exclusive then
        if busy[src] then return E.notice(src, 'Still working on your last request...', 'warning') end
        busy[src] = true
    end
    CreateThread(function()
        local ok, err = pcall(ACTIONS[action], src, data)
        if exclusive then busy[src] = nil end
        if not ok then
            U.log('action %s from %d failed: %s', action, src, tostring(err))
            E.notice(src, 'Something went wrong (see the server console).', 'destructive')
        end
    end)
end, { rateLimit = { max = 40, window = 30000 } })

-- Client observations kora_lib doesn't carry (chat lines, key presses). Accepted
-- only from players with an active run; values are short strings, never trusted
-- for anything but completing that player's own observed/check steps.
local CLIENT_EVENTS = { chat = true, key = true }
Kora.events.register('kora_qa:clientEvent', function(src, event)
    if type(event) ~= 'table' or not CLIENT_EVENTS[event.type] or not R.get(src) then return end
    local name = type(event.name) == 'string' and event.name:sub(1, 32) or nil
    local text = type(event.data) == 'table' and type(event.data.text) == 'string' and event.data.text:sub(1, 300) or nil
    if event.type == 'key' then
        name = name and QAKeys.normalize(name) or nil
        if not name then return end
    end
    E.onEvent(src, { type = event.type, name = name, data = text and { text = text } or nil, side = 'client' })
end, { rateLimit = { max = 40, window = 10000 } })

Kora.events.register('kora_qa:execResult', function(src, token, ok, result)
    R.execResult(src, token, ok, result)
end, { rateLimit = { max = 60, window = 30000 } })

-- --- /kora_qa/ctl (panel -> FXServer) ----------------------------------------------------------

local function json(res, code, body)
    res.writeHead(code, { ['Content-Type'] = 'application/json' })
    res.send(U.jsonEncode(body) or '{}')
end

local function isLoopback(address)
    if type(address) ~= 'string' then return false end
    local host = address:match('^%[([^%]]+)%]') or address:match('^([^:]+):%d+$') or address
    return host == '127.0.0.1' or host == '::1' or host == '::ffff:127.0.0.1' or host == 'localhost'
end

local function header(req, name)
    local headers = req.headers or {}
    return headers[name] or headers[name:lower()] or headers[name:upper()]
end

local function protected(name)
    return name == U.RESOURCE or QACatalog.listHas(Config.protectedResources, name)
end

local CTL = {}

CTL.restart = function(body)
    local name = type(body.name) == 'string' and body.name or ''
    if not name:match('^[%w_%-%.]+$') or GetResourceState(name) == 'missing' or GetResourceState(name) == 'unknown' then
        return 404, { error = 'unknown resource' }
    end
    if protected(name) then return 403, { error = 'protected resource' } end
    U.log('ctl: restarting %s (requested by the QA panel)', name)
    ExecuteCommand('ensure ' .. name)
    return 200, { ok = true }
end

CTL.notify = function(body)
    local discordId = type(body.discordId) == 'string' and body.discordId:match('^%d+$') and body.discordId or nil
    if not discordId then return 400, { error = 'discordId required' } end
    local title = U.cleanText(body.title, 80, false) or 'QA'
    local message = U.cleanText(body.message, 300, false) or 'A fix is ready for you to retest.'
    local players = U.playersByDiscord(discordId)
    for _, src in ipairs(players) do
        Kora.notify.send(src, { title = title, message = message .. ' (' .. Config.keybind .. ' / /' .. Config.command .. ' -> Retests)', type = 'info', duration = 12000 })
        push(src, 'kora_qa:data', { kind = 'retestsChanged' })
    end
    return 200, { delivered = #players > 0 }
end

CTL.reload = function()
    Reg.loadAllAliases()
    Reg.post()
    Reg.refreshScenarios()
    return 200, { ok = true }
end

SetHttpHandler(function(req, res)
    if req.path ~= '/ctl' then return json(res, 404, { error = 'not found' }) end
    if req.method ~= 'POST' then return json(res, 405, { error = 'method not allowed' }) end
    if not isLoopback(req.address) then return json(res, 403, { error = 'loopback only' }) end
    if not U.enabled() then return json(res, 503, { error = 'kora_qa is disabled (kora_qa_enabled)' }) end
    local auth = header(req, 'Authorization')
    local token = type(auth) == 'string' and auth:match('^Bearer%s+(.+)$') or nil
    if not token or not U.secureEquals(token, GetConvar(Config.convars.secret, '')) then
        return json(res, 401, { error = 'unauthorized' })
    end
    req.setDataHandler(function(raw)
        local body = U.jsonDecode(raw)
        if type(body) ~= 'table' or type(body.cmd) ~= 'string' or not CTL[body.cmd] then
            return json(res, 400, { error = 'unknown cmd' })
        end
        local ok, code, result = pcall(CTL[body.cmd], body)
        if not ok then
            U.log('ctl %s failed: %s', body.cmd, tostring(code))
            return json(res, 500, { error = 'internal error' })
        end
        json(res, code, result)
    end)
end)

-- --- lifecycle ------------------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    busy[src] = nil
    local run = R.get(src)
    if run then
        CreateThread(function() E.finish(run, 'aborted', { note = 'player disconnected' }) end)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= U.RESOURCE then
        Reg.dropOwner(resource)
        return
    end
    -- Synchronous best effort: entities are deleted; data undo needs threads
    -- (client RPCs) and can't run during stop.
    for src, run in pairs(R.bySrc) do
        for _, record in ipairs(run.undo) do
            if record.data and record.data.entity then QA.game.deleteEntity(record.data.entity) end
        end
        U.log('kora_qa stopping: run %s for %d abandoned (entities removed)', run.localId, src)
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == U.RESOURCE or not U.enabled() then return end
    -- A resource (re)started: its tests/qa.lua may have changed.
    SetTimeout(1500, function()
        if Reg.loadAliasesFor(resource) then Reg.post() end
    end)
end)

-- Retest reminder shortly after joining.
AddEventHandler('playerJoining', function()
    local src = source
    if not U.enabled() then return end
    SetTimeout(Config.panel.retestReminderDelaySeconds * 1000, function()
        if not GetPlayerName(src) then return end
        local discordId = U.discordOf(src)
        if not discordId then return end
        P.request('GET', '/retests?discordId=' .. P.urlEncode(discordId), nil, function(status, data)
            local count = P.ok(status) and type(data) == 'table' and type(data.retests) == 'table' and #data.retests or 0
            if count > 0 then
                Kora.notify.send(src, {
                    title = 'QA retests',
                    message = ('%d fix(es) waiting for your retest. %s or /%s -> Retests.'):format(count, Config.keybind, Config.command),
                    type = 'info', duration = 10000,
                })
            end
        end)
    end)
end)

CreateThread(function()
    if not U.enabled() then
        U.log('disabled (set %s 1 to enable)', Config.convars.enabled)
        return
    end
    if not P.configured() then U.log('WARNING: %s is not set; the panel cannot be reached', Config.convars.secret) end
    Reg.loadScenarioCache()
    local count = Reg.loadAllAliases()
    U.log('loaded aliases from %d resource(s); %d built-in step(s)', count, #QA.catalog.list)
    QA.observers.attachKoraLib()
    Reg.post()
    Reg.refreshScenarios()
    P.request('POST', '/server-started', {}, function(status, data)
        if P.ok(status) then U.log('server-started reported (%s issue(s) moved to awaiting_test)', tostring(type(data) == 'table' and data.moved or 0)) end
    end)
    P.flush()
    while true do
        Wait(Config.panel.scenarioRefreshSeconds * 1000)
        Reg.refreshScenarios()
    end
end)
