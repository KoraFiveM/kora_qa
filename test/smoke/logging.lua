-- Behavioural check: kora_qa diagnostics go through Kora.logging (spy), not print.
-- Plain Lua, run from the resource root: lua5.4 test/smoke/logging.lua
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'
local root = scriptDir .. '../../'

local logged = {}
Kora = { logging = setmetatable({}, { __index = function(_, level)
    return function(event, message, fields)
        logged[#logged + 1] = { level = level, event = event, message = message, fields = fields }
        return true
    end
end }) }
function GetCurrentResourceName() return 'kora_qa' end
function GetGameTimer() return 0 end
function GetConvar(_, default) return default end
function GetConvarInt(_, default) return default end
function AddEventHandler() end
function CreateThread() end
function SetTimeout() end
function LoadResourceFile() return nil end
json = { encode = function() return "{}" end, decode = function() return nil end }
Config = { convars = {}, defaultPanelUrl = 'http://panel.invalid' }
local savedPrint, printed = print, 0
print = function() printed = printed + 1 end

dofile(root .. 'server/util.lua')
local U = QA.util
dofile(root .. 'server/panel.lua')

local failures = 0
local function check(ok, message)
    if not ok then failures = failures + 1; io.stderr:write('FAIL: ' .. message .. '\n') end
end

-- The wrapper forwards level, event, message and fields untouched.
U.log('warn', 'test.event', 'A message', { key = 'value' })
check(#logged == 1 and logged[1].level == 'warn' and logged[1].event == 'test.event', 'U.log forwards level and event')
check(logged[1].message == 'A message' and logged[1].fields.key == 'value', 'U.log forwards message and fields')

-- A real migrated error path: the offline queue cannot be written.
logged = {}
function SaveResourceFile() return false end
local id = QA.panel.enqueue({ kind = 'run', id = 'job1' })
check(id == nil, 'enqueue still returns nil when the write fails')
check(#logged == 1, 'one log call for the failed queue write')
check(logged[1] and logged[1].level == 'error' and logged[1].event == 'queue.write_failed', 'error level with a stable event name')
check(logged[1] and logged[1].fields.jobId == 'job1' and logged[1].fields.kind == 'run', 'job identity travels in fields')
check(printed == 0, 'nothing goes through print')

print = savedPrint
if failures > 0 then os.exit(1) end
print('kora_qa logging: all checks passed')
