-- The in-game runner: AppShell app `kora_qa:runner` (/qa or the keybind) and a
-- compact steps overlay while a scenario runs. Replaces kora_lib-playground's
-- /test panel and /fb feedback. All decisions are server-side; this file only
-- renders what the server pushes and sends "scenario id / step index" actions.

local APP_ID = Config.appId
local KEY = Config.keybind
local MAX_LIST = 400

local FREQUENCIES = {
    { value = 'always', label = 'Every time' },
    { value = 'sometimes', label = 'Sometimes' },
    { value = 'once', label = 'Only once so far' },
}

local STATUS_ICON = {
    pending = 'Circle', running = 'CircleDot', passed = 'CheckCircle', failed = 'CircleX',
    skipped = 'ArrowRight', unverified = 'AlertCircle', blocked = 'Ban',
}
local STATUS_TONE = { passed = 'success', failed = 'destructive', blocked = 'destructive', unverified = 'warning', running = 'primary' }
local STATUS_TEXT = {
    pending = 'to do', running = 'now', passed = 'passed', failed = 'failed', skipped = 'skipped',
    unverified = 'done (not verified)', blocked = 'could not set up',
}
local KIND_HINT = {
    setup = 'Setup: press Set up (or Run all setup).',
    observed = 'Do this now. It completes on its own when kora_qa sees it, or press Done.',
    check = 'Checked automatically. Dispute it if the result is wrong.',
    manual = 'Do it / check it yourself, then answer.',
}

local State = {
    allowed = nil,
    enabled = true,
    scenarios = {},
    listIndex = {},
    filter = { resource = 'all', tag = 'any' },
    preview = nil,
    run = nil,
    finished = nil,
    retests = nil,
    retestsError = nil,
    runs = nil,
    hud = true,
}

local function notify(message, kind, title)
    Kora.notify.send({ title = title or 'QA', message = tostring(message), type = kind or 'info', duration = 6000 })
end

local function send(action, data)
    local ok, err = Kora.events.trigger('kora_qa:action', action, data or {})
    if not ok then notify(('Could not reach the server: %s'):format(tostring(err)), 'error') end
    return ok
end

local function setActive(state)
    pcall(Kora.qa.setActive, state)
end

-- --- content builders ------------------------------------------------------------------

local function stepLabel(step)
    return ('%s %s'):format(step.keyword or '*', step.text or '')
end

local function filterOptions()
    local resources, tags = {}, {}
    for _, s in ipairs(State.scenarios) do
        if s.resource then resources[s.resource] = true end
        for _, tag in ipairs(s.tags or {}) do
            if tag == '@smoke' or tag == '@regression' or tag == '@manual' or tag:match('^@issue%-') or tag:match('^@cat:') or tag == '@checklist' then
                tags[tag:match('^@issue%-') and '@issue-*' or tag] = true
            end
        end
    end
    local resourceOptions = { { value = 'all', label = 'All resources' } }
    local names = {}
    for name in pairs(resources) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do resourceOptions[#resourceOptions + 1] = { value = name, label = name } end
    local tagOptions = { { value = 'any', label = 'Any tag' } }
    local tagNames = {}
    for tag in pairs(tags) do tagNames[#tagNames + 1] = tag end
    table.sort(tagNames)
    for _, tag in ipairs(tagNames) do tagOptions[#tagOptions + 1] = { value = tag, label = tag } end
    return resourceOptions, tagOptions
end

local function matchesFilter(s)
    if State.filter.resource ~= 'all' and s.resource ~= State.filter.resource then return false end
    if State.filter.tag == 'any' then return true end
    for _, tag in ipairs(s.tags or {}) do
        if tag == State.filter.tag or (State.filter.tag == '@issue-*' and tag:match('^@issue%-')) then return true end
    end
    return false
end

local function scenariosContent()
    if State.allowed == false then
        return { title = 'Scenarios', blocks = { { type = 'empty', title = State.enabled and 'Not a tester yet' or 'QA is disabled on this server',
            description = State.enabled and 'Log in to the QA panel with Discord and ask an admin for the tester role.' or 'Ask an admin to set kora_qa_enabled 1.', icon = 'Ban' } } }
    end
    local items = {}
    State.listIndex = {}
    local shown, total = 0, 0
    for _, s in ipairs(State.scenarios) do
        if matchesFilter(s) then
            total = total + 1
            if shown < MAX_LIST then
                shown = shown + 1
                State.listIndex[shown] = s.id
                local target = math.max(1, s.target or 1)
                local progress = s.passes and ('%d/%d'):format(math.min(s.passes, target), target) or ('target %d'):format(target)
                local tags = {}
                for _, tag in ipairs(s.tags or {}) do
                    if tag ~= '@' .. tostring(s.resource) and #tags < 4 then tags[#tags + 1] = tag end
                end
                items[#items + 1] = {
                    id = 's' .. shown,
                    label = s.name,
                    description = ('%s · %d steps · %s%s%s'):format(s.resource or '?', s.steps or 0, progress,
                        s.admin and ' · needs admin' or '', #tags > 0 and (' · ' .. table.concat(tags, ' ')) or ''),
                    icon = (s.passes and s.passes >= target) and 'CheckCircle' or 'ClipboardList',
                    badge = s.passes and progress or nil,
                    action = { id = 'open:' .. shown, label = 'Open' },
                }
            end
        end
    end
    local resourceOptions, tagOptions = filterOptions()
    return {
        title = 'Scenarios',
        description = total > shown and ('Showing %d of %d — filter to narrow down'):format(shown, total) or ('%d scenario(s)'):format(total),
        actions = { { id = 'refresh-scenarios', label = 'Reload', icon = 'RefreshCw', variant = 'outline' } },
        blocks = {
            { type = 'form', id = 'filter', fields = {
                { id = 'resource', label = 'Resource', type = 'select', default = State.filter.resource, options = resourceOptions },
                { id = 'tag', label = 'Tag', type = 'select', default = State.filter.tag, options = tagOptions },
            }, action = { id = 'filter', label = 'Filter' }, submitLabel = 'Filter' },
            { type = 'list', id = 'scenarios', searchable = true, searchPlaceholder = 'Search scenarios', pageSize = 12, items = items,
                empty = State.allowed == nil and 'Loading...' or 'No scenarios match.' },
        },
    }
end

local function previewContent()
    local s = State.preview
    if not s then
        local blocks = { { type = 'empty', title = 'No scenario open', description = 'Pick one in the Scenarios tab.', icon = 'Flag' } }
        if State.finished then
            table.insert(blocks, 1, { type = 'text', title = 'Last run', text = State.finished })
        end
        return { title = 'Run', blocks = blocks }
    end
    local items = {}
    for i, step in ipairs(s.steps or {}) do
        items[i] = { id = 'p' .. i, label = stepLabel(step), description = KIND_HINT[step.kind] or step.kind, icon = 'Circle' }
    end
    local blocks = {}
    if State.finished then blocks[#blocks + 1] = { type = 'text', title = 'Last run', text = State.finished } end
    if s.description and s.description ~= '' then blocks[#blocks + 1] = { type = 'text', title = 'About', text = s.description } end
    blocks[#blocks + 1] = { type = 'list', id = 'preview', title = 'Steps', items = items }
    blocks[#blocks + 1] = { type = 'actions', actions = {
        { id = 'start', label = State.preview.retestIssueId and 'Start retest' or 'Start', icon = 'Flag', variant = 'primary' },
    } }
    return { title = s.name, description = ('%s%s'):format(s.resource or '', s.tags and #s.tags > 0 and (' · ' .. table.concat(s.tags, ' ')) or ''), blocks = blocks }
end

local function stepActions(run, step)
    local actions = {}
    local idx = step.idx
    if step.current then
        if step.kind == 'setup' and (step.status == 'pending' or step.status == 'blocked') and not run.busy then
            actions[#actions + 1] = { id = 'setup:' .. idx, label = step.status == 'blocked' and 'Retry setup' or 'Set up', icon = 'Wrench', variant = 'primary' }
        elseif step.status == 'running' then
            if step.kind == 'observed' then
                actions[#actions + 1] = { id = 'done:' .. idx, label = 'Done', icon = 'Check', variant = 'primary' }
                if step.canRunFor then actions[#actions + 1] = { id = 'runfor:' .. idx, label = 'Run it for me', icon = 'Terminal', variant = 'outline' } end
            elseif step.kind == 'manual' and step.defId == 'manual.do' then
                actions[#actions + 1] = { id = 'done:' .. idx, label = 'Done', icon = 'Check', variant = 'primary' }
            elseif step.kind == 'manual' or step.kind == 'check' then
                if step.kind == 'manual' then
                    actions[#actions + 1] = { id = 'pass:' .. idx, label = 'Pass', icon = 'Check', variant = 'primary' }
                end
            end
            if step.kind ~= 'setup' then
                actions[#actions + 1] = { id = 'fail:' .. idx, label = 'Fail...', icon = 'X', variant = 'destructive', submitLabel = 'Fail this step',
                    fields = { { id = 'note', label = 'What happened instead?', type = 'textarea', required = true, minLength = 3, maxLength = 2000 } } }
                if step.kind ~= 'check' then
                    actions[#actions + 1] = { id = 'skip:' .. idx, label = 'Skip', icon = 'ArrowRight', variant = 'ghost', confirm = 'Skip this step? It is recorded as skipped.' }
                end
            end
        end
    end
    if step.auto and (step.status == 'passed' or step.status == 'failed') then
        actions[#actions + 1] = {
            id = 'dispute:' .. idx, label = step.status == 'passed' and 'It actually failed...' or 'It actually worked...',
            icon = 'AlertTriangle', variant = 'ghost', submitLabel = 'Dispute',
            fields = { { id = 'note', label = 'Why is the automatic result wrong?', type = 'textarea', required = step.status == 'passed', maxLength = 2000 } },
        }
    end
    return actions
end

local function reportAction(run)
    local options, default = {}, nil
    for _, step in ipairs(run.steps) do
        options[#options + 1] = { value = tostring(step.idx), label = ('%d. %s'):format(step.idx + 1, stepLabel(step)):sub(1, 120) }
        if step.status == 'failed' or step.status == 'blocked' then default = default or tostring(step.idx) end
    end
    default = default or (run.steps[run.current] and tostring(run.steps[run.current].idx)) or options[1] and options[1].value
    return {
        id = 'report', label = 'Report the failure...', icon = 'AlertTriangle', variant = run.failedIdx and 'destructive' or 'outline',
        submitLabel = 'Send report',
        fields = {
            { id = 'step', label = 'Which step failed?', type = 'select', default = default, options = options, required = true },
            { id = 'note', label = 'What went wrong?', type = 'textarea', required = true, minLength = 3, maxLength = 2000,
                placeholder = 'What you did, what happened, what you expected', description = 'A screenshot, your position, inventory and the server console are added for you.' },
            { id = 'frequency', label = 'How often?', type = 'select', default = 'always', options = FREQUENCIES, required = true },
        },
    }
end

local function runContent()
    local run = State.run
    if not run then return previewContent() end
    local items, done = {}, 0
    for i, step in ipairs(run.steps) do
        if step.status ~= 'pending' and step.status ~= 'running' then done = done + 1 end
        local description = step.detail and tostring(step.detail) or nil
        if step.current and not description then description = KIND_HINT[step.kind] end
        if step.status == 'running' and step.kind == 'check' then description = 'Checking...' end
        if step.disputed then description = ('disputed · %s'):format(description or '') end
        items[i] = {
            id = 'r' .. i,
            label = stepLabel(step),
            description = ('%s%s'):format(STATUS_TEXT[step.status] or step.status, description and (' · ' .. description) or ''),
            icon = STATUS_ICON[step.status] or 'Circle',
            tone = STATUS_TONE[step.status],
            badge = step.current and 'NOW' or nil,
            actions = stepActions(run, step),
        }
    end
    local current = run.steps[run.current]
    local actions = {}
    if current and current.kind == 'setup' and (current.status == 'pending') and not run.busy then
        actions[#actions + 1] = { id = 'setup-all', label = 'Run all setup', icon = 'Wrench', variant = 'primary' }
    end
    actions[#actions + 1] = { id = 'close-run', label = 'Hide and test', icon = 'ArrowRight', variant = 'secondary', closeBeforeAction = true }
    actions[#actions + 1] = reportAction(run)
    actions[#actions + 1] = { id = 'block', label = "Can't run this...", icon = 'Ban', variant = 'ghost', submitLabel = 'Stop as blocked',
        fields = { { id = 'note', label = 'What is missing?', type = 'textarea', required = true, minLength = 3, maxLength = 500 } } }
    actions[#actions + 1] = { id = 'abort', label = 'Abort', icon = 'X', variant = 'ghost', confirm = 'Abort this run? Everything set up is undone.' }

    local blocks = {
        { type = 'progress', items = { { label = 'Steps', value = done, max = math.max(1, #run.steps), detail = ('%d/%d'):format(done, #run.steps),
            tone = run.failedIdx and 'destructive' or 'success' } } },
        { type = 'list', id = 'steps', title = 'Steps', items = items },
        { type = 'actions', title = run.failedIdx and 'A step failed: report it, dispute it, or abort' or nil, actions = actions },
    }
    if run.status ~= 'running' then
        table.insert(blocks, 1, { type = 'text', title = 'Finishing', text = 'Undoing setup and sending the result...' })
    end
    return {
        title = run.scenario.name,
        description = ('%s%s · %s'):format(run.scenario.resource or '', run.retest and (' · retest of #' .. run.retest) or '', run.busy and 'setting up...' or run.status),
        blocks = blocks,
    }
end

local function reportContent()
    return {
        title = 'Report an issue',
        description = 'Anything broken or worth changing, outside a scenario.',
        blocks = {
            { type = 'form', id = 'freeform', fields = {
                { id = 'title', label = 'Title', type = 'text', required = true, minLength = 3, maxLength = 120, placeholder = 'Short summary' },
                { id = 'kind', label = 'Type', type = 'select', default = 'bug', options = { { value = 'bug', label = 'Bug' }, { value = 'suggestion', label = 'Suggestion' } } },
                { id = 'frequency', label = 'How often?', type = 'select', default = 'always', options = FREQUENCIES },
                { id = 'note', label = 'What happened?', type = 'textarea', required = true, minLength = 3, maxLength = 2000, rows = 6,
                    placeholder = 'What you did, what happened, what you expected',
                    description = 'A screenshot, your position, inventory, job and recent server errors are attached for you.' },
            }, action = { id = 'freeform', label = 'Send' }, submitLabel = 'Send report' },
        },
    }
end

local function retestsContent()
    local items = {}
    for i, r in ipairs(State.retests or {}) do
        items[i] = {
            id = 't' .. i, label = r.title or ('Issue #' .. tostring(r.issueId)),
            description = ('#%s%s%s'):format(tostring(r.issueId), r.scenarioId and (' · ' .. r.scenarioId) or ' · no scenario: test by hand',
                (r.notFixedCount or 0) > 0 and (' · not fixed %dx'):format(r.notFixedCount) or ''),
            icon = 'RefreshCw',
            action = r.scenarioId and { id = 'retest:' .. i, label = 'Retest' } or nil,
        }
    end
    return {
        title = 'Retests', description = 'Fixes waiting for you to check them',
        actions = { { id = 'load-retests', label = 'Reload', icon = 'RefreshCw', variant = 'outline' } },
        blocks = { { type = 'list', id = 'retests', items = items,
            empty = State.retestsError or (State.retests == nil and 'Loading...' or 'Nothing to retest right now.') } },
    }
end

local function runsContent()
    local items = {}
    for i, r in ipairs(State.runs or {}) do
        local when = r.at or r.finishedAt or r.startedAt
        items[i] = {
            id = 'h' .. i, label = r.name or r.scenarioId or 'run',
            description = ('%s%s%s'):format(r.status or '?', r.issueId and (' · issue #' .. tostring(r.issueId)) or '',
                when and (' · ' .. tostring(math.floor((GetCloudTimeAsInt() * 1000 - when) / 60000)) .. ' min ago') or ''),
            icon = STATUS_ICON[r.status] or (r.status == 'aborted' and 'X' or 'Clock'),
            tone = STATUS_TONE[r.status],
        }
    end
    return {
        title = 'My runs',
        actions = { { id = 'load-runs', label = 'Reload', icon = 'RefreshCw', variant = 'outline' } },
        blocks = { { type = 'list', id = 'runs', items = items, empty = State.runs == nil and 'Loading...' or 'No runs yet.' } },
    }
end

local function navigation()
    return {
        { id = 'scenarios', label = 'Scenarios', icon = 'List', content = scenariosContent() },
        { id = 'run', label = State.run and 'Running' or 'Run', icon = 'Flag', badge = State.run and 'live' or nil, content = runContent() },
        { id = 'report', label = 'Report issue', icon = 'AlertTriangle', content = reportContent() },
        { id = 'retests', label = 'Retests', icon = 'RefreshCw', badge = State.retests and #State.retests > 0 and tostring(#State.retests) or nil,
            onOpen = 'load-retests', content = retestsContent() },
        { id = 'runs', label = 'My runs', icon = 'Clock', onOpen = 'load-runs', content = runsContent() },
    }
end

local registered = false
local function refresh()
    if registered and Kora.nui.isAppOpen(APP_ID) then
        Kora.nui.updateApp(APP_ID, { navigation = navigation() })
    end
end

-- --- server pushes --------------------------------------------------------------------------

Kora.events.onPush('kora_qa:run', function(view)
    if type(view) ~= 'table' then return end
    local wasRunning = State.run ~= nil
    State.run = view
    State.finished = nil
    if not wasRunning then setActive(true) end
    refresh()
end)

Kora.events.onPush('kora_qa:finished', function(result)
    State.run = nil
    setActive(false)
    if type(result) ~= 'table' then return refresh() end
    local text
    if result.status == 'passed' then
        text = ('Passed: %s. Thanks!'):format(result.scenario or 'scenario')
        notify(text, 'success')
    elseif result.status == 'failed' then
        text = result.issueId and ('Reported as issue #%s.'):format(result.issueId)
            or (result.queued and 'The panel is offline: your report is saved and will be sent automatically.' or 'Report sent.')
        notify(text, 'success')
    else
        text = ('Run %s. Setup was undone.'):format(result.status)
        notify(text, 'info')
    end
    State.finished = text
    refresh()
end)

Kora.events.onPush('kora_qa:notice', function(n)
    if type(n) ~= 'table' then return end
    local kind = n.tone == 'destructive' and 'error' or (n.tone == 'warning' and 'warning' or 'info')
    notify(n.message, kind)
end)

Kora.events.onPush('kora_qa:data', function(d)
    if type(d) ~= 'table' then return end
    if d.kind == 'hello' then
        State.allowed = d.allowed == true
        State.enabled = d.enabled ~= false
    elseif d.kind == 'scenarios' then
        State.scenarios = type(d.scenarios) == 'table' and d.scenarios or {}
    elseif d.kind == 'scenario' then
        if d.scenario then
            local retest = State.preview and State.preview.id == d.scenario.id and State.preview.retestIssueId or State.pendingRetest
            State.preview = d.scenario
            State.preview.retestIssueId = retest
            State.pendingRetest = nil
        else
            notify('That scenario is no longer available. Reload the list.', 'error')
        end
    elseif d.kind == 'retests' then
        State.retests = type(d.retests) == 'table' and d.retests or {}
        State.retestsError = d.error
    elseif d.kind == 'retestsChanged' then
        State.retests = nil
        if Kora.nui.isAppOpen(APP_ID) then send('retests') end
    elseif d.kind == 'runs' then
        State.runs = type(d.runs) == 'table' and d.runs or {}
    elseif d.kind == 'freeform' then
        local r = d.result or {}
        notify(r.issueId and ('Thanks! Issue #%s created.'):format(r.issueId) or 'Thanks! Saved; it will be sent when the panel is back.', 'success')
    end
    refresh()
end)

-- --- actions ------------------------------------------------------------------------------------

local function value(context) return type(context) == 'table' and type(context.value) == 'table' and context.value or {} end
local WORKING = { notice = { tone = 'primary', message = 'Working...' } }

local function onAction(actionId, context)
    local v = value(context)
    if actionId == 'filter' then
        State.filter.resource = type(v.resource) == 'string' and v.resource or 'all'
        State.filter.tag = type(v.tag) == 'string' and v.tag or 'any'
        return { update = { navigation = navigation() } }
    end
    if actionId == 'refresh-scenarios' then send('scenarios'); return WORKING end
    if actionId == 'load-retests' then send('retests'); return nil end
    if actionId == 'load-runs' then send('runs'); return nil end
    if actionId == 'start' then
        if not State.preview then return { notice = { tone = 'warning', message = 'Open a scenario first.' } } end
        send('start', { id = State.preview.id, retestIssueId = State.preview.retestIssueId })
        return { notice = { tone = 'primary', message = 'Starting...' } }
    end
    if actionId == 'setup-all' then send('setupAll'); return { notice = { tone = 'primary', message = 'Setting up...' } } end
    if actionId == 'close-run' then return { close = true } end
    if actionId == 'abort' then send('abort'); return WORKING end
    if actionId == 'block' then send('block', { note = v.note }); return WORKING end
    if actionId == 'report' then
        send('report', { idx = tonumber(v.step), note = v.note, frequency = v.frequency })
        return { notice = { tone = 'primary', message = 'Taking a screenshot and sending the report...' } }
    end
    if actionId == 'freeform' then
        send('freeform', { title = v.title, kind = v.kind, frequency = v.frequency, note = v.note })
        return { notice = { tone = 'primary', message = 'Taking a screenshot and sending...' } }
    end
    local open = tonumber(actionId:match('^open:(%d+)$'))
    if open then
        local id = State.listIndex[open]
        if not id then return nil end
        State.preview = { id = id, name = 'Loading...', steps = {} }
        send('scenario', { id = id })
        return { update = { navigation = navigation() }, navigate = { viewId = 'run' } }
    end
    local retest = tonumber(actionId:match('^retest:(%d+)$'))
    if retest and State.retests and State.retests[retest] then
        local r = State.retests[retest]
        State.pendingRetest = tostring(r.issueId)
        State.preview = { id = r.scenarioId, name = 'Loading...', steps = {}, retestIssueId = tostring(r.issueId) }
        send('scenario', { id = r.scenarioId })
        return { update = { navigation = navigation() }, navigate = { viewId = 'run' } }
    end
    local verb, idx = actionId:match('^(%a+):(%d+)$')
    idx = tonumber(idx)
    if verb and idx then
        if verb == 'setup' then send('setup', { idx = idx }); return { notice = { tone = 'primary', message = 'Setting up...' } } end
        if verb == 'runfor' then send('runFor', { idx = idx }); return WORKING end
        if verb == 'done' or verb == 'pass' or verb == 'fail' or verb == 'skip' or verb == 'dispute' then
            send(verb, { idx = idx, note = v.note })
            return WORKING
        end
    end
    error('Unknown action.')
end

local function register()
    local ok, err = pcall(Kora.nui.registerApp, {
        id = APP_ID,
        title = 'QA runner',
        description = 'Run test scenarios and report issues',
        icon = 'ClipboardList',
        layout = 'compact',
        width = 620,
        height = 760,
        draggable = true,
        rememberPosition = true,
        defaultView = 'scenarios',
        footer = ('%s or /%s toggles this window. The steps stay on screen while you test.'):format(KEY, Config.command),
        navigation = navigation(),
        onAction = onAction,
    })
    registered = ok
    if not ok then print(('[kora_qa] runner app not registered: %s'):format(tostring(err))) end
end

local function open(viewId)
    if registered and Kora.nui.isAppOpen(APP_ID) then
        Kora.nui.closeApp(APP_ID)
        return
    end
    if not registered then register() end
    if not registered then return notify('The QA runner is not available (see F8).', 'error') end
    send('hello')
    CreateThread(function()
        Kora.nui.openApp(APP_ID, { viewId = viewId or (State.run and 'run' or 'scenarios') })
    end)
end

-- --- overlay ---------------------------------------------------------------------------------------

local OVERLAY_MARK = { pending = '[ ]', running = '[>]', passed = '[x]', failed = '[!]', skipped = '[-]', unverified = '[?]', blocked = '[!]' }
local OVERLAY_COLOUR = {
    passed = { 120, 220, 120 }, failed = { 240, 90, 90 }, blocked = { 240, 90, 90 },
    unverified = { 240, 200, 80 }, running = { 250, 204, 21 }, skipped = { 160, 160, 160 }, pending = { 230, 230, 230 },
}

local function drawText(text, x, y, scale, colour)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(colour[1], colour[2], colour[3], 235)
    SetTextOutline()
    SetTextWrap(x, 0.99)
    BeginTextCommandDisplayText('STRING')
    for index = 1, math.min(#text, 450), 90 do AddTextComponentSubstringPlayerName(text:sub(index, index + 89)) end
    EndTextCommandDisplayText(x, y)
end

CreateThread(function()
    while true do
        local run = State.run
        if run and State.hud and not IsPauseMenuActive() and not (registered and Kora.nui.isAppOpen(APP_ID)) then
            local x, y = 0.70, 0.26
            drawText(('QA: %s'):format(run.scenario.name or ''), x, y, 0.40, { 250, 204, 21 })
            y = y + 0.028
            local first = math.max(1, math.min(run.current - 3, #run.steps - 9))
            for i = first, math.min(#run.steps, first + 9) do
                local step = run.steps[i]
                local line = ('%s %s'):format(OVERLAY_MARK[step.status] or '[ ]', stepLabel(step))
                if #line > 80 then line = line:sub(1, 78) .. '..' end
                drawText(line, x, y, 0.31, OVERLAY_COLOUR[step.status] or OVERLAY_COLOUR.pending)
                y = y + 0.022
            end
            local current = run.steps[run.current]
            local hint = ('%s: open the runner'):format(KEY)
            if run.failedIdx then hint = ('A step failed. %s: report or dispute'):format(KEY)
            elseif current and current.kind == 'setup' then hint = ('%s: set up  ·  /%s setup'):format(KEY, Config.command)
            elseif current and current.kind == 'observed' then hint = ('Do it now  ·  /%s done when finished'):format(Config.command)
            elseif current and current.kind == 'manual' then hint = ('/%s done | pass | fail  ·  %s: open'):format(Config.command, KEY) end
            drawText(hint, x, y + 0.006, 0.29, { 170, 170, 170 })
            Wait(0)
        else
            Wait(400)
        end
    end
end)

-- --- client observations (key presses, chat) -----------------------------------------------------

local function report(eventType, name, text)
    if not State.run then return end
    Kora.events.trigger('kora_qa:clientEvent', { type = eventType, name = name, data = text and { text = text } or nil })
end

-- Watches the current `I press the "<key>" key` step's controls (enabled or
-- disabled, so resource key mappings that disable the control still count).
CreateThread(function()
    while true do
        local run = State.run
        local step = run and run.steps[run.current]
        local controls = step and step.status == 'running' and step.key and QAKeys.controlsFor(step.key)
        if controls then
            for _, control in ipairs(controls) do
                if IsControlJustPressed(0, control) or IsDisabledControlJustPressed(0, control) then
                    report('key', step.key)
                    Wait(500)
                    break
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

local function stripColours(text) return (tostring(text):gsub('%^%d', ''):gsub('<[^>]->', '')) end

local function chatText(message)
    if type(message) == 'string' then return message end
    if type(message) ~= 'table' then return nil end
    if type(message.args) == 'table' then
        local parts = {}
        for _, part in ipairs(message.args) do parts[#parts + 1] = tostring(part) end
        return table.concat(parts, ' ')
    end
    return message.message or message.text or message.msg
end

local function onChat(text)
    if not State.run or text == nil then return end
    report('chat', nil, stripColours(text):sub(1, 300))
end

-- kora_chat's own entry points (net or local); every resource's handler runs.
for _, name in ipairs({ 'chat:addMessage', 'qbchat:message' }) do
    RegisterNetEvent(name)
    AddEventHandler(name, function(message) onChat(chatText(message)) end)
end
RegisterNetEvent('chatMessage')
AddEventHandler('chatMessage', function(author, _, text)
    onChat(author and author ~= '' and (tostring(author) .. ' ' .. tostring(text)) or text)
end)

-- --- command / key ------------------------------------------------------------------------------------

local function currentIdx()
    local run = State.run
    local step = run and run.steps[run.current]
    return step and step.idx or nil
end

local SUB = {
    setup = function() send('setupAll') end,
    done = function() local i = currentIdx(); if i then send('done', { idx = i }) end end,
    pass = function() local i = currentIdx(); if i then send('pass', { idx = i }) end end,
    fail = function(args)
        local i = currentIdx()
        local note = table.concat(args, ' ', 2)
        if not i then return end
        if #note < 3 then return notify(('Usage: /%s fail <what happened>'):format(Config.command), 'error') end
        send('fail', { idx = i, note = note })
    end,
    skip = function() local i = currentIdx(); if i then send('skip', { idx = i }) end end,
    abort = function() send('abort') end,
    hud = function() State.hud = not State.hud; notify(State.hud and 'Steps overlay on.' or 'Steps overlay off.') end,
    report = function() open('report') end,
}

RegisterCommand(Config.command, function(_, args)
    local sub = tostring(args[1] or ''):lower()
    if sub == '' then return open() end
    local handler = SUB[sub]
    if handler then return handler(args) end
    notify(('/%s [setup|done|pass|fail <text>|skip|abort|hud|report]'):format(Config.command))
end, false)

Kora.keybind.add({
    name = 'kora_qa_runner',
    description = 'QA: open the test runner',
    defaultMapper = 'keyboard',
    defaultKey = KEY,
    onPressed = function() ExecuteCommand(Config.command) end,
})

CreateThread(function()
    Wait(1000)
    register()
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_lib' then
        registered = false
        SetTimeout(1500, function()
            register()
            if State.run then setActive(true) end
        end)
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then setActive(false) end
end)
