-- HTTP client for the QA panel's game API (QA-CONTRACTS §5) plus the offline
-- queue. Every request is server-side with `Authorization: Bearer <kora_qa_secret>`;
-- the client never sees the panel URL or the secret.
--
-- Submissions that fail because the panel is unreachable (status 0 / 5xx) are
-- written to queue/<id>.json (index in queue/index.json) and replayed in order
-- when a later request succeeds or on the periodic flush.

QA.panel = {}
local P = QA.panel
local U = QA.util

P.online = nil -- nil = unknown, true/false after the last request

local function baseUrl()
    local url = GetConvar(Config.convars.panelUrl, Config.defaultPanelUrl)
    if url == '' then url = Config.defaultPanelUrl end
    return (url:gsub('/+$', ''))
end

local function secret()
    return GetConvar(Config.convars.secret, '')
end

function P.configured()
    return secret() ~= ''
end

local function reachable(status)
    return type(status) == 'number' and status > 0 and status < 500
end

---Raw request. `done(status, data, rawBody)` is called exactly once.
function P.request(method, path, body, done)
    done = done or function() end
    if not P.configured() then
        done(0, nil, 'kora_qa_secret is not set')
        return
    end
    local finished = false
    local function finish(status, data, raw)
        if finished then return end
        finished = true
        local wasOnline = P.online
        P.online = reachable(status)
        if P.online and wasOnline == false then
            SetTimeout(500, function() P.flush() end)
        end
        done(status, data, raw)
    end
    SetTimeout(Config.panel.timeoutMs, function() finish(0, nil, 'timeout') end)

    local payload = ''
    if body ~= nil then payload = U.jsonEncode(body) or '{}' end
    PerformHttpRequest(baseUrl() .. path, function(status, text, _, errorData)
        finish(tonumber(status) or 0, U.jsonDecode(text), text or errorData)
    end, method, payload, {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. secret(),
    })
end

---Blocking variant for use inside a thread. Returns status, data, raw.
function P.call(method, path, body)
    local status, data, raw = U.await(Config.panel.timeoutMs + 1000, function(resolve)
        P.request(method, path, body, resolve)
    end)
    return status or 0, data, raw
end

function P.ok(status) return type(status) == 'number' and status >= 200 and status < 300 end
P.reachable = reachable

local function urlEncode(value)
    return (tostring(value):gsub('[^%w%-_%.~]', function(c) return ('%%%02X'):format(c:byte()) end))
end
P.urlEncode = urlEncode

-- --- screenshot upload (binary, via server/upload.js) --------------------------

local uploads = {}
local uploadSeq = 0

AddEventHandler('kora_qa:uploaded', function(id, status, body)
    local pending = uploads[id]
    if not pending then return end
    uploads[id] = nil
    pending(tonumber(status) or 0, U.jsonDecode(body))
end)

---Uploads a file (relative to the resource) to POST /uploads. Blocking (thread only).
---@return integer status, table|nil data
function P.upload(relPath, issueId, runId)
    if not P.configured() then return 0, nil end
    uploadSeq = uploadSeq + 1
    local id = uploadSeq
    local query = {}
    if issueId then query[#query + 1] = 'issueId=' .. urlEncode(issueId) end
    if runId then query[#query + 1] = 'runId=' .. urlEncode(runId) end
    local status, data = U.await(Config.panel.timeoutMs + 5000, function(resolve)
        uploads[id] = resolve
        TriggerEvent('kora_qa:upload', id, U.resourcePath(relPath), table.concat(query, '&'))
    end)
    uploads[id] = nil
    return status or 0, data
end

-- --- offline queue -------------------------------------------------------------

local INDEX = 'queue/index.json'
local queueBusy = false

local function loadIndex()
    local index = U.readJsonFile(INDEX)
    return type(index) == 'table' and index or {}
end

local function saveIndex(index)
    U.writeJsonFile(INDEX, index)
end

---Persists a job for later. Jobs: { kind = 'run'|'finish'|'issue', ... } (see runJob).
function P.enqueue(job)
    job.id = job.id or U.randomId('q')
    job.queuedAt = U.now()
    if not U.writeJsonFile(('queue/%s.json'):format(job.id), job) then
        U.log('could not write queue/%s.json -- report lost: %s', job.id, U.jsonEncode(job) or '?')
        return nil
    end
    local index = loadIndex()
    index[#index + 1] = job.id
    saveIndex(index)
    U.log('panel unreachable; queued %s (%s). %d job(s) waiting.', job.id, job.kind, #index)
    return job.id
end

function P.queueSize() return #loadIndex() end

local function removeJob(id)
    local index = loadIndex()
    for i = #index, 1, -1 do
        if index[i] == id then table.remove(index, i) end
    end
    saveIndex(index)
    pcall(os.remove, U.resourcePath(('queue/%s.json'):format(id)))
end

local function postSteps(runId, steps)
    for _, step in ipairs(steps or {}) do
        local status = P.call('POST', ('/runs/%s/steps'):format(urlEncode(runId)), step)
        if not reachable(status) then return false end
    end
    return true
end

local function uploadShot(job, issueId, runId)
    if not job.screenshot then return true end
    local status = P.upload(job.screenshot, issueId, runId)
    if not reachable(status) then return false end
    pcall(os.remove, U.resourcePath(job.screenshot))
    job.screenshot = nil
    return true
end

---Replays one job. Returns true when done (or permanently rejected), false to retry later.
---Mutates `job` as it progresses so a half-finished replay resumes where it stopped.
function P.runJob(job)
    if job.kind == 'run' then
        if not job.runId then
            local status, data = P.call('POST', '/runs', job.start)
            if not reachable(status) then return false end
            if not P.ok(status) or type(data) ~= 'table' or data.runId == nil then
                U.log('queued run %s rejected by the panel (HTTP %s)', job.id, status)
                return true
            end
            job.runId = data.runId
        end
        job.kind = 'finish'
    end
    if job.kind == 'finish' then
        if job.steps and #job.steps > 0 then
            if not postSteps(job.runId, job.steps) then return false end
            job.steps = nil
        end
        if not job.finished then
            local status, data = P.call('POST', ('/runs/%s/finish'):format(urlEncode(job.runId)), job.finish)
            if not reachable(status) then return false end
            job.finished = true
            job.issueId = type(data) == 'table' and data.issueId or nil
        end
        return uploadShot(job, job.issueId, job.runId)
    end
    if job.kind == 'issue' then
        if not job.issueId then
            local status, data = P.call('POST', '/issues', job.body)
            if not reachable(status) then return false end
            if not P.ok(status) or type(data) ~= 'table' then
                U.log('queued issue %s rejected by the panel (HTTP %s)', job.id, status)
                return true
            end
            job.issueId = data.issueId
        end
        return uploadShot(job, job.issueId, nil)
    end
    U.log('dropping queued job %s with unknown kind %s', tostring(job.id), tostring(job.kind))
    return true
end

---Replays the queue in order; stops at the first job that still can't be delivered.
function P.flush()
    if queueBusy or not P.configured() then return end
    queueBusy = true
    CreateThread(function()
        local ok, err = pcall(function()
            for _, id in ipairs(loadIndex()) do
                local rel = ('queue/%s.json'):format(id)
                local job = U.readJsonFile(rel)
                if type(job) ~= 'table' then
                    removeJob(id)
                else
                    local done = P.runJob(job)
                    if done then
                        removeJob(id)
                        U.log('delivered queued %s', id)
                    else
                        job.attempts = (job.attempts or 0) + 1
                        U.writeJsonFile(rel, job)
                        break
                    end
                end
            end
        end)
        if not ok then U.log('queue flush failed: %s', tostring(err)) end
        queueBusy = false
    end)
end

CreateThread(function()
    while true do
        Wait(Config.panel.queueFlushSeconds * 1000)
        if U.enabled() and P.queueSize() > 0 then P.flush() end
    end
end)
