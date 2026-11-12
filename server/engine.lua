-- The run engine: start, sequential advance, setup execution, observers,
-- auto-checks, tester actions, finish (report + screenshot + teardown + panel).

QA.engine = {}
local E = QA.engine
local R = QA.runs
local U = QA.util
local P = QA.panel
local S = QA.steps.impl

local STATUS_DONE = R.STATUS_DONE

function E.push(run)
    if run and GetPlayerName(run.src) then Kora.events.push(run.src, 'kora_qa:run', R.view(run)) end
end

local function notice(src, message, tone)
    Kora.events.push(src, 'kora_qa:notice', { message = message, tone = tone or 'neutral' })
end
E.notice = notice

-- --- history (My runs fallback) ----------------------------------------------------

local HISTORY = 'data/history.json'
local function remember(run, status, issueId)
    if not run.discordId then return end
    local history = U.readJsonFile(HISTORY)
    if type(history) ~= 'table' then history = {} end
    local list = history[run.discordId] or {}
    table.insert(list, 1, {
        at = U.now(), scenarioId = run.scenario.id, name = run.scenario.name, resource = run.scenario.resource,
        status = status, issueId = issueId, runId = run.id,
    })
    while #list > 25 do table.remove(list) end
    history[run.discordId] = list
    U.writeJsonFile(HISTORY, history)
end

function E.history(discordId)
    local history = U.readJsonFile(HISTORY)
    return type(history) == 'table' and history[discordId] or {}
end

-- --- start ---------------------------------------------------------------------------

local function needsOf(scenario)
    local needs = type(scenario.needs) == 'table' and scenario.needs or {}
    local admin, players = needs.admin == true, tonumber(needs.players) or 1
    for _, tag in ipairs(scenario.tags or {}) do
        if tag == '@needs:admin' then admin = true end
        local n = type(tag) == 'string' and tonumber(tag:match('^@needs:players:(%d+)$'))
        if n then players = math.max(players, n) end
    end
    return admin, players
end
E.needsOf = needsOf

---Checks every step of a scenario against this server's registry and caps.
function E.preflight(run)
    local problems, entities = {}, 0
    for i, step in ipairs(run.steps) do
        local def, params, err = R.resolve(run, step)
        if not def or not params then
            problems[#problems + 1] = ('step %d (%s): %s'):format(i, tostring(step.text), err)
        elseif def.kind == 'setup' then
            entities = entities + (tonumber(def.entities) or 0)
            if def.id == 'fixture.run' then
                for _, entry in ipairs(params.fixture.steps) do
                    local sub = QA.catalog.byId[entry.step]
                    entities = entities + (sub and tonumber(sub.entities) or 0)
                end
            end
        end
    end
    if entities > Config.caps.maxEntities then
        problems[#problems + 1] = ('spawns %d entities (cap %d)'):format(entities, Config.caps.maxEntities)
    end
    return problems
end

---Starts a run. Thread only. Returns ok, message.
function E.start(src, scenarioId, retestIssueId)
    if R.get(src) then return false, 'You already have a test running. Finish or abort it first.' end
    if type(scenarioId) ~= 'string' or #scenarioId > 191 then return false, 'Unknown scenario.' end
    local allowed = QA.registry.checkAccess(src)
    if not allowed then return false, 'You are not a tester on the QA panel.' end

    local scenario = QA.scenarios.byId[scenarioId]
    if not scenario then
        U.await(Config.panel.timeoutMs + 1000, function(resolve) QA.registry.refreshScenarios(resolve) end)
        scenario = QA.scenarios.byId[scenarioId]
    end
    if not scenario then return false, 'That scenario is not available (it may have changed). Reload the list.' end

    local needsAdmin, players = needsOf(scenario)
    if needsAdmin and not QA.registry.isAdmin(src) then return false, 'This scenario needs the admin role.' end
    if #GetPlayers() < players then return false, ('This scenario needs %d players online.'):format(players) end
    if R.get(src) then return false, 'You already have a test running.' end

    local discordId = U.discordOf(src)
    local run = R.new(src, scenario, {
        discordId = discordId, name = U.playerName(src),
        retestIssueId = type(retestIssueId) == 'string' and retestIssueId:match('^%d+$') and retestIssueId or nil,
        snapshot = R.snapshot(src),
    })
    local problems = E.preflight(run)
    if #problems > 0 then
        return false, 'This scenario cannot run on this server: ' .. table.concat(problems, '; '):sub(1, 400)
    end

    R.bySrc[src] = run
    pcall(Kora.qa.setActive, src, true)
    U.log('run %s started by %s (%d): %s', run.localId, run.name, src, scenario.id)

    run.startBody = {
        scenarioId = scenario.id, scenarioHash = scenario.hash, discordId = discordId or '',
        name = run.name, retestIssueId = run.retestIssueId,
    }
    P.request('POST', '/runs', run.startBody, function(status, data)
        if P.ok(status) and type(data) == 'table' and data.runId ~= nil then
            run.id = data.runId
            -- Steps finished before the id arrived.
            local pending = run.pendingPosts
            run.pendingPosts = {}
            for _, payload in ipairs(pending) do
                P.request('POST', ('/runs/%s/steps'):format(P.urlEncode(run.id)), payload, function(s)
                    if not P.reachable(s) then run.pendingPosts[#run.pendingPosts + 1] = payload end
                end)
            end
            E.push(run)
        else
            U.log('run %s: panel did not register the run (HTTP %s); results will be queued', run.localId, tostring(status))
        end
    end)

    E.advance(run)
    return true
end

-- --- step machine --------------------------------------------------------------------------

local function finishStep(run, i, status, detail)
    R.setStep(run, i, status, detail)
    if status == 'failed' or status == 'blocked' then
        E.push(run)
        return
    end
    if i == run.current then E.advance(run) else E.push(run) end
end
E.finishStep = finishStep

local function begin(run, i, step)
    if step.kind == 'setup' then return end
    local def, params, err = R.resolve(run, step)
    if not def or not params then
        R.setStep(run, i, 'blocked', { error = err })
        return
    end
    step.def, step.params = def, params
    step.startedAt = U.now()
    step.status = 'running'
    if step.kind == 'observed' or (step.kind == 'manual' and def.id == 'manual.do') then
        run.windowStart = step.startedAt
    end
    local impl = S[def.id]
    if impl and impl.observe and impl.observe.timer then
        local token = step.startedAt
        SetTimeout(params.seconds * 1000, function()
            if R.get(run.src) == run and run.steps[i].status == 'running' and step.startedAt == token then
                finishStep(run, i, 'passed', { auto = true, message = ('waited %d s'):format(params.seconds) })
            end
        end)
    end
    if step.kind == 'check' then
        SetTimeout(0, function()
            if R.get(run.src) == run and run.current == i then E.evaluate(run, i, false) end
        end)
    end
end

function E.advance(run)
    if run.status ~= 'running' then return end
    while true do
        local step = run.steps[run.current]
        if not step then
            CreateThread(function() E.finish(run, 'passed') end)
            return
        end
        if STATUS_DONE[step.status] then
            if step.status == 'failed' or step.status == 'blocked' then
                E.push(run)
                return
            end
            run.current = run.current + 1
        else
            -- begin() never completes a step synchronously (checks are evaluated
            -- on the next tick), so this loop can't race finishStep's own advance.
            if step.status == 'pending' then begin(run, run.current, step) end
            E.push(run)
            return
        end
    end
end

---Evaluates an auto-check. `final` forces a verdict (timeout reached).
function E.evaluate(run, i, final)
    local step = run.steps[i]
    if not step or step.status ~= 'running' or step.kind ~= 'check' then return end
    local impl = S[step.def.id]
    local external = step.def.external and step.def.external.check
    if not (impl and impl.check) and not external then return end -- manual verdict needed
    local ctx = R.context(run, step, step.def, step.params)
    local okCall, ok, actual, expected
    if impl and impl.check then
        okCall, ok, actual, expected = pcall(impl.check, ctx)
    else
        okCall, ok, actual, expected = pcall(external, run.src, step.params)
    end
    if not okCall then
        R.setStep(run, i, 'failed', { auto = true, error = tostring(ok), expected = step.text, actual = 'check errored: ' .. tostring(ok) })
        E.push(run)
        return
    end
    if ok then
        finishStep(run, i, 'passed', { auto = true, actual = actual, expected = expected })
        return
    end
    local eventual = not (impl and impl.eventual == false)
    local elapsed = U.now() - (step.startedAt or 0)
    if final or not eventual or elapsed >= Config.run.checkTimeoutMs then
        finishStep(run, i, 'failed', { auto = true, actual = actual, expected = expected })
    end
end

function E.hasManualVerdict(step)
    if step.kind == 'manual' then return true end
    if step.kind ~= 'check' or not step.def then return false end
    local impl = S[step.def.id]
    return not (impl and impl.check) and not (step.def.external and step.def.external.check)
end

-- Observer / check ticker.
CreateThread(function()
    while true do
        Wait(Config.run.checkIntervalMs)
        for _, run in pairs(R.bySrc) do
            local i = run.current
            local step = run.steps[i]
            if run.status == 'running' and step and step.status == 'running' and step.def then
                local ok, err = pcall(function()
                    if step.kind == 'check' then
                        E.evaluate(run, i, false)
                    elseif step.kind == 'observed' then
                        local impl = S[step.def.id]
                        local observe = impl and impl.observe
                        if observe and observe.poll then
                            local hit, detail = observe.poll(R.context(run, step, step.def, step.params))
                            if hit then finishStep(run, i, 'passed', { auto = true, message = detail }) end
                        end
                        if observe and observe.deadline and run.steps[i] == step and step.status == 'running' then
                            local seconds = observe.deadline(R.context(run, step, step.def, step.params))
                            if seconds and U.now() - (step.startedAt or 0) > seconds * 1000 then
                                finishStep(run, i, 'failed', { auto = true, expected = step.text,
                                    actual = ('nothing within %d s'):format(seconds) })
                            end
                        end
                    end
                end)
                if not ok then U.log('observer for %s failed: %s', tostring(step.defId), tostring(err)) end
            end
        end
    end
end)

---Records an event for one player's run (or every run when src is nil) and
---completes an armed observer that matches it.
function E.onEvent(src, event)
    if type(event) ~= 'table' then return end
    if event.type == 'nui' and event.name == Config.appId then return end
    local targets = {}
    if src then
        targets[1] = R.get(src)
    else
        for _, run in pairs(R.bySrc) do targets[#targets + 1] = run end
    end
    for _, run in ipairs(targets) do
        R.addTimeline(run, event.type, event.name, event.data, event.side)
        local i = run.current
        local step = run.steps[i]
        if run.status == 'running' and step and step.status == 'running' and step.kind == 'observed' and step.def then
            local impl = S[step.def.id]
            local observe = impl and impl.observe
            if observe and observe.events and observe.events[event.type] and observe.match then
                local okCall, hit, detail = pcall(observe.match, R.context(run, step, step.def, step.params), event)
                if okCall and hit then finishStep(run, i, 'passed', { auto = true, message = detail }) end
            end
        end
    end
end

-- --- setup ------------------------------------------------------------------------------------

local function runSetupDef(run, step, def, params)
    if def.id == 'fixture.run' then
        local details = {}
        for n, entry in ipairs(params.fixture.steps) do
            local sub = QA.catalog.byId[entry.step]
            if not sub or sub.kind ~= 'setup' or sub.id == 'fixture.run' then
                return false, ('fixture step %d: "%s" is not a setup step'):format(n, tostring(entry.step))
            end
            local subParams, err = QACatalog.validateArgs(sub, entry.args or {}, {
                caps = Config.caps, aliases = QA.aliases, resource = params.fixture.owner,
            })
            if not subParams then return false, ('fixture step %d (%s): %s'):format(n, sub.id, err) end
            local ok, detail = runSetupDef(run, step, sub, subParams)
            if not ok then return false, ('fixture step %d (%s): %s'):format(n, sub.id, tostring(detail)) end
            details[#details + 1] = tostring(detail)
        end
        return true, table.concat(details, '; ')
    end
    local ctx = R.context(run, step, def, params)
    local impl = S[def.id]
    if impl and impl.setup then
        local okCall, ok, detail = pcall(impl.setup, ctx)
        if not okCall then return false, 'setup errored: ' .. tostring(ok) end
        return ok == true, detail
    end
    if def.external and def.external.setup then
        local okCall, ok, detail, undoData = pcall(def.external.setup, run.src, params)
        if not okCall then return false, 'setup errored: ' .. tostring(ok) end
        if ok and def.undo then ctx.undo(undoData or params) end
        return ok == true, detail
    end
    return false, ('no setup implementation for %s'):format(def.id)
end

---Executes the current setup step. Thread only. Returns ok, message.
---`chained` (Run all setup) skips the per-click cooldown.
function E.setup(run, i, chained)
    local step = run.steps[i]
    if run.status ~= 'running' or not step or i ~= run.current then return false, 'That is not the current step.' end
    if step.kind ~= 'setup' or (step.status ~= 'pending' and step.status ~= 'blocked') then return false, 'Nothing to set up.' end
    if run.busy then return false, 'Setup is already running.' end
    if not U.enabled() then return false, 'Setup is disabled on this server (kora_qa_enabled).' end
    local now = GetGameTimer()
    if not chained and run.lastSetupAt and now - run.lastSetupAt < Config.run.setupCooldownMs then return false, 'One moment...' end
    run.lastSetupAt = now

    local def, params, err = R.resolve(run, step)
    if not def or not params then
        finishStep(run, i, 'blocked', { error = err })
        return false, err
    end
    if def.entities and run.entityCount + def.entities > Config.caps.maxEntities then
        finishStep(run, i, 'blocked', { error = 'entity cap reached' })
        return false, 'entity cap reached'
    end

    run.busy = true
    step.status = 'running'
    if run.failedIdx == i then run.failedIdx = nil end
    E.push(run)
    local ok, detail = runSetupDef(run, step, def, params)
    run.busy = false
    run.windowStart = U.now()
    U.log('setup run=%s player=%s step=%d %s %s: %s', run.id or run.localId, tostring(run.src), step.idx, def.id,
        ok and 'ok' or 'FAILED', tostring(detail))
    R.addTimeline(run, 'setup', def.id, { idx = step.idx, ok = ok, detail = detail })
    if R.get(run.src) ~= run then return false, 'run ended' end
    if ok then
        finishStep(run, i, 'passed', { message = detail })
    else
        finishStep(run, i, 'blocked', { error = detail })
    end
    return ok, detail
end

function E.setupAll(run)
    local count = 0
    while run.status == 'running' do
        local step = run.steps[run.current]
        if not step or step.kind ~= 'setup' or (step.status ~= 'pending' and step.status ~= 'blocked') then break end
        local ok, err = E.setup(run, run.current, true)
        if not ok then return false, err end
        count = count + 1
    end
    return true, count
end

-- --- tester actions -----------------------------------------------------------------------------

---Handles Done/Pass/Fail/Skip/Dispute for step `i`. Returns ok, message.
function E.testerAction(run, action, i, note)
    local step = run.steps[i]
    if not step or run.status ~= 'running' then return false, 'No such step.' end
    note = U.cleanText(note, Config.report.noteMax, true)

    if action == 'dispute' then
        if not (type(step.detail) == 'table' and step.detail.auto) or (step.status ~= 'passed' and step.status ~= 'failed') then
            return false, 'Only automatic results can be disputed.'
        end
        local flipped = step.status == 'passed' and 'failed' or 'passed'
        local detail = U.deepcopy(step.detail)
        detail.disputed = true
        detail.auto = false
        detail.autoStatus = step.status
        detail.note = note or ('tester says this step ' .. flipped)
        if flipped == 'passed' and run.failedIdx == i then run.failedIdx = nil end
        R.setStep(run, i, flipped, detail)
        if flipped == 'passed' then E.advance(run) else E.push(run) end
        return true
    end

    if i ~= run.current then return false, 'That is not the current step.' end
    if step.status ~= 'running' then return false, 'That step is not waiting for you.' end

    if action == 'done' then
        if step.kind == 'observed' then
            finishStep(run, i, 'unverified', { by = 'tester', message = 'tester pressed Done; no observer fired' })
            return true
        end
        if step.kind == 'manual' and step.defId == 'manual.do' then
            finishStep(run, i, 'passed', { by = 'tester' })
            return true
        end
        return false, 'This step needs Pass or Fail.'
    elseif action == 'pass' then
        if not E.hasManualVerdict(step) then return false, 'This step is checked automatically (use Dispute if it is wrong).' end
        finishStep(run, i, 'passed', { by = 'tester', note = note })
        return true
    elseif action == 'fail' then
        if step.kind == 'setup' then return false, 'Use the setup button.' end
        finishStep(run, i, 'failed', { by = 'tester', note = note, expected = step.text, actual = note })
        return true
    elseif action == 'skip' then
        if step.kind == 'setup' then return false, 'Setup steps cannot be skipped.' end
        finishStep(run, i, 'skipped', { by = 'tester', note = note })
        return true
    end
    return false, 'Unknown action.'
end

-- --- screenshot -----------------------------------------------------------------------------------

---Captures the player's game view to queue/shots/<name>.<ext>. Thread only.
---@return string|nil relPath, string|nil reason
function E.screenshot(src, name)
    if not Config.report.screenshot then return nil, 'disabled' end
    if not U.started('kora_lib') then return nil, 'kora_lib is not started' end
    local ext = Config.report.screenshotEncoding == 'png' and 'png' or (Config.report.screenshotEncoding == 'webp' and 'webp' or 'jpg')
    local rel = ('queue/shots/%s.%s'):format(name, ext)
    local err = U.await(Config.report.screenshotTimeoutMs + 3000, function(resolve)
        Kora.screenshot.requestClient(src, {
            fileName = U.resourcePath(rel),
            encoding = ext,
            quality = Config.report.screenshotQuality,
            maxWidth = Config.report.screenshotMaxWidth,
            maxHeight = Config.report.screenshotMaxHeight,
            timeout = Config.report.screenshotTimeoutMs,
        }, function(captureErr) resolve(captureErr or false) end)
    end)
    if err ~= false then return nil, tostring(err or 'capture failed') end
    local data = LoadResourceFile(U.RESOURCE, rel)
    if not data or #data == 0 then return nil, 'empty capture' end
    return rel
end

-- --- finish ----------------------------------------------------------------------------------------

local function gatherContext(src, resources)
    local okInfo, info = R.exec(src, 'context', {})
    return {
        player = R.playerContext(src, okInfo and info or nil),
        inventoryAfter = QA.game.inventoryList(src),
        resources = R.resourceInfo(resources),
        build = GetConvar('version', ''),
    }
end

---Ends a run. status: passed | failed | aborted | blocked. Thread only.
---opts = { idx?, note?, frequency? } for failed/blocked.
function E.finish(run, status, opts)
    if run.status ~= 'running' then return false, 'Run already finished.' end
    opts = opts or {}
    run.status = 'finishing'
    E.push(run)
    local src = run.src
    local online = GetPlayerName(src) ~= nil

    local report, shot
    if status == 'failed' and online then
        if opts.idx then
            local i = opts.idx + 1
            local step = run.steps[i]
            if step and step.status ~= 'failed' then
                R.setStep(run, i, 'failed', { by = 'tester', note = opts.note, expected = step.text, actual = opts.note })
            end
        end
        local context = gatherContext(src, run.resources)
        report = R.buildReport(run, { failedIdx = opts.idx, note = opts.note, frequency = opts.frequency }, context)
        local reason
        shot, reason = E.screenshot(src, run.localId)
        report.screenshot = shot and { available = true } or { available = false, reason = reason }
    end

    local teardownLog = online and R.teardown(run) or nil
    if not online then
        -- Player left: only server-side cleanup is possible (entities); data undo
        -- needs the player online and is skipped.
        for _, record in ipairs(run.undo) do
            if record.data and record.data.entity then QA.game.deleteEntity(record.data.entity) end
        end
        run.undo = {}
    end
    if report and teardownLog then report.teardown = teardownLog end

    pcall(Kora.qa.setActive, src, false)
    if R.bySrc[src] == run then R.bySrc[src] = nil end
    run.status = status

    local finishBody = { status = status, context = report, note = opts.note }
    local issueId, url, queued

    local function deliver()
        if not run.id then
            local s, data = P.call('POST', '/runs', run.startBody)
            if not P.reachable(s) then return false end
            if not P.ok(s) or type(data) ~= 'table' or data.runId == nil then return true end
            run.id = data.runId
            for _, step in ipairs(run.steps) do
                if STATUS_DONE[step.status] then run.pendingPosts[#run.pendingPosts + 1] = { idx = step.idx, status = step.status, detail = step.detail } end
            end
        end
        while #run.pendingPosts > 0 do
            local s = P.call('POST', ('/runs/%s/steps'):format(P.urlEncode(run.id)), run.pendingPosts[1])
            if not P.reachable(s) then return false end
            table.remove(run.pendingPosts, 1)
        end
        local s, data = P.call('POST', ('/runs/%s/finish'):format(P.urlEncode(run.id)), finishBody)
        if not P.reachable(s) then return false end
        if type(data) == 'table' then issueId, url = data.issueId, data.url end
        return true
    end

    local delivered = P.configured() and deliver() or false
    if delivered and shot then
        local s = P.upload(shot, issueId, run.id)
        if P.reachable(s) then pcall(os.remove, U.resourcePath(shot)) else
            P.enqueue({ kind = 'finish', runId = run.id, finished = true, issueId = issueId, finish = finishBody, screenshot = shot })
        end
    elseif not delivered then
        queued = true
        if run.id then
            P.enqueue({ kind = 'finish', runId = run.id, steps = run.pendingPosts, finish = finishBody, screenshot = shot })
        else
            local steps = {}
            for _, step in ipairs(run.steps) do
                if STATUS_DONE[step.status] then steps[#steps + 1] = { idx = step.idx, status = step.status, detail = step.detail } end
            end
            P.enqueue({ kind = 'run', start = run.startBody, steps = steps, finish = finishBody, screenshot = shot })
        end
    end

    remember(run, status, issueId)
    U.log('run %s (%s) finished: %s%s', run.id or run.localId, run.scenario.id, status, issueId and (' -> issue ' .. issueId) or '')
    if online then
        Kora.events.push(src, 'kora_qa:finished', {
            status = status, issueId = issueId, url = url, queued = queued == true,
            scenario = run.scenario.name, retest = run.retestIssueId,
        })
        -- Pass counts changed on the panel: refresh the list so progress (e.g. 0/1 -> 1/1) updates now.
        if delivered and QA.pushScenarios then QA.pushScenarios(src) end
    end
    return true
end

-- --- freeform report (replaces /fb) ---------------------------------------------------------------

local lastFreeform = {}
local FREQUENCIES = { always = true, sometimes = true, once = true }

function E.freeform(src, data)
    if type(data) ~= 'table' then return false, 'Bad report.' end
    local now = os.time()
    if lastFreeform[src] and now - lastFreeform[src] < 60 then return false, 'Please wait a minute between reports.' end
    local title = U.cleanText(data.title, Config.report.titleMax, false)
    local note = U.cleanText(data.note, Config.report.noteMax, true)
    if not title or #title < 3 then return false, 'Give the report a short title.' end
    if not note or #note < 3 then return false, 'Describe what happened.' end
    local frequency = FREQUENCIES[data.frequency] and data.frequency or 'once'
    local kind = data.kind == 'suggestion' and 'suggestion' or 'bug'
    lastFreeform[src] = now

    local context = gatherContext(src, {})
    local recent = {}
    for _, line in ipairs(QA.console.recent(120)) do
        if line.error then recent[#recent + 1] = { at = line.at, channel = line.channel, line = line.line } end
    end
    context.console = recent
    local report = R.buildReport(nil, { note = note, frequency = frequency }, context)
    local shot, reason = E.screenshot(src, U.randomId('fb'))
    report.screenshot = shot and { available = true } or { available = false, reason = reason }

    local body = { discordId = U.discordOf(src) or '', name = U.playerName(src), title = title, note = note, frequency = frequency, kind = kind, report = report }
    local status, result = P.call('POST', '/issues', body)
    if P.reachable(status) and P.ok(status) and type(result) == 'table' then
        if shot then
            local s = P.upload(shot, result.issueId, nil)
            if P.reachable(s) then pcall(os.remove, U.resourcePath(shot)) else
                P.enqueue({ kind = 'issue', issueId = result.issueId, screenshot = shot })
            end
        end
        U.log('freeform report from %s (%d) -> issue %s', U.playerName(src), src, tostring(result.issueId))
        return true, { issueId = result.issueId, url = result.url }
    end
    if P.reachable(status) then
        lastFreeform[src] = nil
        return false, ('The panel rejected the report (HTTP %s).'):format(status)
    end
    P.enqueue({ kind = 'issue', body = body, screenshot = shot })
    return true, { queued = true }
end
