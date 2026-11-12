-- Run state per player: snapshot, sequential step machine, undo stack,
-- timeline, report builder and teardown.
--
-- Trust model: a run only ever executes the steps of the scenario the panel
-- served (looked up by id in QA.scenarios). The client sends nothing but
-- "scenario id" and "step index"; every argument comes from the scenario and
-- is re-validated against Config.caps right before it executes.

QA.runs = { bySrc = {} }
local R = QA.runs
local U = QA.util
local P = QA.panel

local STATUS_DONE = { passed = true, failed = true, skipped = true, unverified = true, blocked = true }
R.STATUS_DONE = STATUS_DONE

function R.get(src) return R.bySrc[src] end

-- --- client exec RPC -------------------------------------------------------------

local pendingExec = {}
local execSeq = 0

---Asks the player's client to run a built-in op on its own ped. Thread only.
---@return boolean ok, any result
function R.exec(src, op, data)
    if not GetPlayerName(src) then return false, 'player left' end
    execSeq = execSeq + 1
    local token = ('%d:%d'):format(execSeq, math.random(100000, 999999))
    local ok, result = U.await(Config.run.clientExecTimeoutMs, function(resolve)
        pendingExec[token] = { src = src, resolve = resolve }
        Kora.events.push(src, 'kora_qa:exec', token, op, data or {})
    end)
    pendingExec[token] = nil
    if ok == nil then return false, result or 'client did not answer' end
    return ok == true, result
end

function R.execResult(src, token, ok, result)
    local pending = type(token) == 'string' and pendingExec[token] or nil
    if not pending or pending.src ~= src then return end
    pendingExec[token] = nil
    pending.resolve(ok == true, type(result) == 'table' and result or (type(result) == 'string' and result:sub(1, 300) or nil))
end

-- --- timeline ---------------------------------------------------------------------

function R.addTimeline(run, eventType, name, data, side)
    local entry = { at = U.now(), type = eventType, name = name, data = data, side = side }
    local timeline = run.timeline
    timeline[#timeline + 1] = entry
    if #timeline > Config.run.maxTimeline then table.remove(timeline, 1) end
    return entry
end

---Timeline events of a type since the current action window opened.
function R.eventsSince(run, eventType, since)
    local out = {}
    since = since or run.windowStart or run.startedAt
    for _, entry in ipairs(run.timeline) do
        if entry.at >= since and entry.type == eventType then out[#out + 1] = entry end
    end
    if eventType == 'console' then
        for _, line in ipairs(run.console) do
            if line.at >= since then out[#out + 1] = { at = line.at, type = 'console', data = line } end
        end
    end
    return out
end

-- --- undo bookkeeping -----------------------------------------------------------------

function R.pushUndo(run, stepIdx, defId, data)
    run.undo[#run.undo + 1] = { idx = stepIdx, id = defId, data = data or {} }
end

---Pops every undo record in reverse order. `apply(record)` does the work;
---a failing record is logged and the rest still run.
function R.unwind(run, apply)
    local log = {}
    while #run.undo > 0 do
        local record = table.remove(run.undo)
        local ok, err = pcall(apply, record)
        log[#log + 1] = { id = record.id, idx = record.idx, ok = ok, error = not ok and tostring(err) or nil }
    end
    return log
end

-- --- context / snapshot ------------------------------------------------------------------

function R.playerContext(src, clientInfo)
    local G = QA.game
    local ped = GetPlayerPed(src)
    local vehicle = ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    clientInfo = type(clientInfo) == 'table' and clientInfo or {}
    return {
        coords = U.playerCoords(src),
        street = clientInfo.street,
        vehicle = vehicle ~= 0 and {
            model = clientInfo.vehicleModel or tostring(GetEntityModel(vehicle)),
            plate = U.trim(GetVehicleNumberPlateText(vehicle) or ''),
        } or nil,
        job = G.getJob(src),
        gang = G.getGang(src),
        money = { cash = G.getMoney(src, 'cash'), bank = G.getMoney(src, 'bank') },
        health = ped and ped ~= 0 and GetEntityHealth(ped) or nil,
        armour = ped and ped ~= 0 and GetPedArmour(ped) or nil,
        routingBucket = GetPlayerRoutingBucket(src),
    }
end

function R.snapshot(src)
    local G = QA.game
    local money = {}
    for _, account in ipairs(Config.caps.accounts) do money[account] = G.getMoney(src, account) end
    -- Scalar metadata only (hunger, thirst, stress, ...) for "should have changed by".
    local metadata = {}
    local meta = G.getMeta(src, nil)
    if type(meta) == 'table' then
        for key, value in pairs(meta) do
            local kind = type(value)
            if type(key) == 'string' and (kind == 'number' or kind == 'boolean' or (kind == 'string' and #value <= 64)) then
                metadata[key] = value
            end
        end
    end
    return {
        metadata = metadata,
        coords = U.playerCoords(src),
        items = G.inventoryList(src),
        money = money,
        job = G.getJob(src),
        gang = G.getGang(src),
    }
end

---Resources whose console output and versions belong in the report.
function R.scenarioResources(scenario)
    local set, list = {}, {}
    local function add(name)
        if type(name) == 'string' and not set[name] and GetResourceState(name) ~= 'missing' then
            set[name] = true
            list[#list + 1] = name
        end
    end
    add(scenario and scenario.resource)
    for _, tag in ipairs(scenario and scenario.tags or {}) do
        local name = type(tag) == 'string' and tag:match('^@([%w_%-]+)$')
        if name then add(name) end
    end
    return list, set
end

function R.resourceInfo(names)
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = { name = name, version = GetResourceMetadata(name, 'version', 0), state = GetResourceState(name) }
    end
    return out
end

-- --- creation ----------------------------------------------------------------------------

---Creates the run record (no natives besides snapshot callers). `scenario` is the panel's.
function R.new(src, scenario, opts)
    opts = opts or {}
    local steps = {}
    for i, step in ipairs(scenario.steps) do
        steps[i] = {
            idx = step.idx or (i - 1),
            keyword = step.keyword,
            text = step.text,
            defId = step.defId,
            kind = step.kind,
            args = step.args or {},
            docString = step.docString,
            status = 'pending',
        }
    end
    local resources, resourceSet = R.scenarioResources(scenario)
    local now = U.now()
    return {
        localId = U.randomId('run'),
        id = nil,
        src = src,
        discordId = opts.discordId,
        name = opts.name,
        retestIssueId = opts.retestIssueId,
        scenario = scenario,
        resources = resources,
        resourceSet = resourceSet,
        steps = steps,
        current = 1,
        status = 'running',
        startedAt = now,
        windowStart = now,
        undo = {},
        timeline = {},
        console = {},
        entityCount = 0,
        snapshot = opts.snapshot or {},
        pendingPosts = {},
        failedIdx = nil,
    }
end

-- --- step posting -------------------------------------------------------------------------

local function stepPayload(step)
    return { idx = step.idx, status = step.status, detail = step.detail }
end

local function postStep(run, step)
    local payload = stepPayload(step)
    if not run.id then
        run.pendingPosts[#run.pendingPosts + 1] = payload
        return
    end
    P.request('POST', ('/runs/%s/steps'):format(P.urlEncode(run.id)), payload, function(status)
        if not P.reachable(status) then run.pendingPosts[#run.pendingPosts + 1] = payload end
    end)
end

function R.setStep(run, i, status, detail)
    local step = run.steps[i]
    if not step then return end
    step.status = status
    step.detail = detail
    step.at = U.now()
    if status == 'failed' or status == 'blocked' then run.failedIdx = run.failedIdx or i end
    R.addTimeline(run, 'step', step.text, { idx = step.idx, status = status, detail = detail })
    if STATUS_DONE[status] then postStep(run, step) end
end

-- --- view for the client ---------------------------------------------------------------------

local function detailText(detail)
    if type(detail) ~= 'table' then return detail end
    if detail.expected or detail.actual then
        return ('expected %s, got %s'):format(tostring(detail.expected), tostring(detail.actual))
    end
    return detail.message or detail.note or detail.error
end

function R.view(run)
    if not run then return nil end
    local steps = {}
    for i, step in ipairs(run.steps) do
        steps[i] = {
            idx = step.idx,
            keyword = step.keyword,
            text = step.text,
            kind = step.kind,
            defId = step.defId,
            status = step.status,
            current = i == run.current and run.status == 'running',
            detail = detailText(step.detail),
            auto = type(step.detail) == 'table' and step.detail.auto == true or false,
            disputed = type(step.detail) == 'table' and step.detail.disputed == true or false,
            key = step.defId == 'key.press' and QAKeys.normalize(step.args[1]) or nil,
            canRunFor = step.defId == 'command.run' and step.args[1] ~= nil
                and QACatalog.listHas(Config.caps.allowCommands, (tostring(step.args[1]):gsub('^%s*/', ''):match('^(%S+)') or '')) or false,
        }
    end
    local scenario = run.scenario
    return {
        localId = run.localId,
        runId = run.id,
        status = run.status,
        busy = run.busy == true,
        current = run.current,
        failedIdx = run.failedIdx,
        retest = run.retestIssueId,
        scenario = {
            id = scenario.id, name = scenario.name, resource = scenario.resource,
            description = scenario.description, tags = scenario.tags,
        },
        steps = steps,
    }
end

-- --- report -------------------------------------------------------------------------------------

---Builds the Report object (QA-CONTRACTS §6). Pure: everything gathered from the
---game is passed in `context` so it can be unit-tested.
---@param run table|nil nil for a freeform report
---@param opts table { failedIdx?, note, frequency, expected?, actual? }
---@param context table { player, inventoryAfter, resources, build, console?, timeline? }
function R.buildReport(run, opts, context)
    opts = opts or {}
    context = context or {}
    local report = {
        v = 1,
        scenario = nil,
        failedIdx = nil,
        steps = {},
        expected = opts.expected,
        actual = opts.actual,
        note = opts.note,
        frequency = opts.frequency,
        timeline = {},
        console = {},
        player = context.player,
        inventoryBefore = {},
        inventoryAfter = context.inventoryAfter or {},
        resources = context.resources or {},
        build = context.build,
    }
    if run then
        report.scenario = { id = run.scenario.id, hash = run.scenario.hash, name = run.scenario.name }
        local failed = opts.failedIdx and run.steps[opts.failedIdx + 1] and opts.failedIdx
        if not failed and run.failedIdx then failed = run.steps[run.failedIdx].idx end
        report.failedIdx = failed
        for _, step in ipairs(run.steps) do
            report.steps[#report.steps + 1] = { idx = step.idx, text = (step.keyword and (step.keyword .. ' ') or '') .. tostring(step.text), status = step.status, detail = step.detail }
            if failed ~= nil and step.idx == failed and type(step.detail) == 'table' then
                report.expected = report.expected or step.detail.expected
                report.actual = report.actual or step.detail.actual or step.detail.error or step.detail.note
            end
        end
        for _, entry in ipairs(run.timeline) do
            if entry.type ~= 'step' then
                report.timeline[#report.timeline + 1] = { at = entry.at, type = entry.type, data = { name = entry.name, side = entry.side, data = entry.data } }
            end
        end
        for _, line in ipairs(run.console) do report.console[#report.console + 1] = { at = line.at, channel = line.channel, line = line.line } end
        report.inventoryBefore = run.snapshot.items or {}
        report.moneyBefore = run.snapshot.money
    else
        report.timeline = context.timeline or {}
        report.console = context.console or {}
    end
    if type(report.expected) ~= 'string' and report.expected ~= nil then report.expected = tostring(report.expected) end
    if type(report.actual) ~= 'string' and report.actual ~= nil then report.actual = tostring(report.actual) end
    return report
end

-- --- teardown ------------------------------------------------------------------------------------

---Undoes every setup of the run. Thread only (undo may call the client).
function R.teardown(run)
    local impl = QA.steps.impl
    local log = R.unwind(run, function(record)
        local def = QA.catalog.byId[record.id]
        local ctx = R.context(run, run.steps[record.idx + 1] or {}, def, nil)
        local handler = impl[record.id] and impl[record.id].undo
        if handler then
            handler(ctx, record.data)
        elseif def and def.external and def.external.undo then
            def.external.undo(run.src, record.data)
        end
    end)
    for _, entry in ipairs(log) do
        if not entry.ok then U.log('teardown of %s (step %s) for run %s failed: %s', entry.id, tostring(entry.idx), run.localId, tostring(entry.error)) end
    end
    return log
end

-- --- step context ----------------------------------------------------------------------------------

function R.context(run, step, def, params)
    local ctx = { src = run.src, run = run, def = def, params = params or {}, step = step }
    ctx.undo = function(data) R.pushUndo(run, step.idx or 0, def and def.id or '?', data) end
    ctx.exec = function(op, data) return R.exec(run.src, op, data) end
    ctx.events = function(eventType) return R.eventsSince(run, eventType) end
    ctx.vehicle = function()
        if run.vehicle and DoesEntityExist(run.vehicle) then return run.vehicle end
        return QA.game.currentVehicle(run.src)
    end
    return ctx
end

---Validates a scenario step's args against its definition and the caps.
---@return table|nil def, table|nil params, string|nil err
function R.resolve(run, step)
    local def = QA.catalog.byId[step.defId or '']
    if not def then return nil, nil, ('unknown step definition "%s"'):format(tostring(step.defId)) end
    if def.kind ~= step.kind then return nil, nil, ('step kind changed (%s vs %s): reload scenarios'):format(tostring(step.kind), def.kind) end
    local params, err = QACatalog.validateArgs(def, step.args, {
        caps = Config.caps, aliases = QA.aliases, resource = run.scenario.resource,
    })
    if not params then return def, nil, err end
    return def, params
end
