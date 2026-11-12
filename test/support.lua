-- Loads kora_qa's server realm under plain Lua with kora_lib's harness and
-- mocks plus a small fake game (players, inventory, money, jobs, entities).
-- KORA_LIB_TEST overrides where kora_lib's test/ folder lives.

local M = {}

local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'
local root = scriptDir .. '../'
M.root = root
local koraLibTest = os.getenv('KORA_LIB_TEST') or (root .. '../../[pre]/kora_lib/test/')
package.path = koraLibTest .. '?.lua;' .. scriptDir .. '?.lua;' .. package.path

M.harness = require('harness')
local mocks = require('mocks')
M.mocks = mocks
_G.json = require('json')

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end
M.readFile = readFile

---Installs mocks + the fake game and loads config/catalog (+ server files when `server`).
function M.boot(opts)
    opts = opts or {}
    local net = mocks.install()
    M.net = net

    local convars = { kora_qa_enabled = 1, kora_qa_secret = 'test-secret', kora_qa_panel_url = 'http://panel.test/qa/game' }
    M.convars = convars
    _G.GetConvarInt = function(name, default) return tonumber(convars[name]) or default end
    _G.GetConvar = function(name, default) local v = convars[name]; return v ~= nil and tostring(v) or default end
    _G.GetCurrentResourceName = function() return 'kora_qa' end
    _G.GetResourcePath = function() return '/tmp/kora_qa_test' end
    os.execute('mkdir -p /tmp/kora_qa_test/queue/shots /tmp/kora_qa_test/data')

    local files = {}
    M.files = files
    _G.LoadResourceFile = function(resource, rel)
        if resource == 'kora_qa' and files[rel] ~= nil then return files[rel] end
        if resource == 'kora_qa' then return readFile(root .. rel) end
        return M.resourceFiles and M.resourceFiles[resource] and M.resourceFiles[resource][rel] or nil
    end
    _G.SaveResourceFile = function(_, rel, data) files[rel] = data; return true end

    -- --- fake game -------------------------------------------------------------------
    local game = {
        players = { [1] = { name = 'Tester', discord = '123456789012345678', coords = { x = 0.0, y = 0.0, z = 30.0 }, heading = 0.0, vehicle = 0, health = 200, armour = 0 } },
        items = { [1] = { [1] = { name = 'water', amount = 1, slot = 1 } } },
        money = { [1] = { cash = 100, bank = 1000, crypto = 0 } },
        jobs = { [1] = { name = 'unemployed', grade = { level = 1 }, onduty = false } },
        gangs = { [1] = { name = 'none', grade = { level = 1 } } },
        meta = { [1] = {} },
        knownItems = { water = true, sandwich = true, lockpick = true, weapon_pistol = true },
        knownJobs = { unemployed = true, police = true },
        entities = {},
        nextEntity = 1000,
        resources = { kora_core = 'started', kora_inventory = 'started', kora_lib = 'started', kora_qa = 'started', kora_vehiclekeys = 'started' },
        log = {},
    }
    M.game = game

    _G.GetPlayers = function() local out = {}; for src in pairs(game.players) do out[#out + 1] = tostring(src) end; return out end
    _G.GetPlayerName = function(src) return game.players[src] and game.players[src].name or nil end
    _G.GetPlayerIdentifiers = function(src) return game.players[src] and { 'license:abc', 'discord:' .. game.players[src].discord } or {} end
    _G.GetPlayerPed = function(src) return game.players[src] and (100 + src) or 0 end
    local function playerOfPed(ped) return game.players[ped - 100] end
    _G.GetEntityCoords = function(entity)
        local p = playerOfPed(entity)
        if p then return p.coords end
        return game.entities[entity] and game.entities[entity].coords or { x = 0, y = 0, z = 0 }
    end
    _G.GetEntityHeading = function(entity) local p = playerOfPed(entity); return p and p.heading or 0.0 end
    _G.GetEntityHealth = function(entity) local p = playerOfPed(entity); return p and p.health or 0 end
    _G.GetPedArmour = function(ped) local p = playerOfPed(ped); return p and p.armour or 0 end
    _G.SetPedArmour = function(ped, value) local p = playerOfPed(ped); if p then p.armour = value end end
    _G.GetVehiclePedIsIn = function(ped) local p = playerOfPed(ped); return p and p.vehicle or 0 end
    _G.GetPlayerRoutingBucket = function() return 0 end
    _G.SetEntityRoutingBucket = function() end
    _G.GetResourceState = function(name) return game.resources[name] or 'missing' end
    _G.GetResourceMetadata = function() return '1.0.0' end
    _G.GetNumResources = function() return 0 end
    _G.GetResourceByFindIndex = function() return nil end
    _G.IsPlayerAceAllowed = function() return false end
    _G.DoesEntityExist = function(entity) return game.entities[entity] ~= nil end
    _G.DeleteEntity = function(entity) game.entities[entity] = nil end
    _G.GetEntityModel = function(entity) return game.entities[entity] and game.entities[entity].model or 0 end
    local function create(kind, model, x, y, z)
        game.nextEntity = game.nextEntity + 1
        game.entities[game.nextEntity] = { kind = kind, model = model, coords = { x = x, y = y, z = z }, state = {} }
        return game.nextEntity
    end
    _G.CreateVehicle = function(model, x, y, z) return create('vehicle', model, x, y, z) end
    _G.CreatePed = function(_, model, x, y, z) return create('ped', model, x, y, z) end
    _G.CreateObjectNoOffset = function(model, x, y, z) return create('object', model, x, y, z) end
    _G.NetworkGetNetworkIdFromEntity = function(entity) return entity end
    _G.SetVehicleNumberPlateText = function(entity, plate) if game.entities[entity] then game.entities[entity].plate = plate end end
    _G.GetVehicleNumberPlateText = function(entity) return game.entities[entity] and game.entities[entity].plate or '' end
    _G.SetVehicleDoorsLocked = function() end
    _G.GetVehicleDoorLockStatus = function() return 1 end
    _G.FreezeEntityPosition = function() end
    _G.SetEntityHeading = function() end
    _G.TaskStartScenarioInPlace = function() end
    _G.GetSelectedPedWeapon = function() return 0 end
    _G.GetPedInVehicleSeat = function(vehicle, seat) return game.drivers and game.drivers[vehicle] or 0 end
    _G.GetIsVehicleEngineRunning = function(vehicle) return game.entities[vehicle] and game.entities[vehicle].engine == true or false end
    _G.Entity = function(entity)
        local e = game.entities[entity] or { state = {} }
        return { state = setmetatable({ set = function(self, key, value) e.state[key] = value end }, { __index = function(_, k) return e.state[k] end }) }
    end
    _G.GetEntityFromStateBagName = function() return 0 end
    _G.AddStateBagChangeHandler = function() end
    _G.RegisterConsoleListener = function(fn) M.console = fn end
    _G.SetHttpHandler = function(fn) M.http = fn end
    _G.os.remove = function() return true end

    M.requests = {}
    _G.PerformHttpRequest = function(url, cb, method, body, headers)
        M.requests[#M.requests + 1] = { url = url, method = method, body = body, headers = headers }
        if M.httpResponder then
            local status, response = M.httpResponder(url, method, body and body ~= '' and json.decode(body) or nil)
            cb(status, response and json.encode(response) or '', {}, nil)
        end
    end

    local function count(src, name)
        local n = 0
        for _, item in pairs(game.items[src] or {}) do if item.name == name then n = n + item.amount end end
        return n
    end
    local function nextSlot(src)
        local slot = 1
        while game.items[src][slot] do slot = slot + 1 end
        return slot
    end
    local core = {
        getShared = function(_, kind, name)
            if kind == 'items' or kind == 'weapons' then return game.knownItems[name] and { name = name } or nil end
            if kind == 'jobs' then return game.knownJobs[name] and { name = name } or nil end
            if kind == 'gangs' then return { name = name } end
        end,
        getItemCount = function(_, src, name) return count(src, name) end,
        getPlayerData = function(_, src) return game.items[src] end,
        addItem = function(_, src, name, amount, _, info)
            if not game.knownItems[name] then return false, 'unknown item' end
            game.items[src][nextSlot(src)] = { name = name, amount = amount, info = info }
            return true
        end,
        removeItem = function(_, src, name, amount)
            if count(src, name) < amount then return false, 'not enough' end
            for slot, item in pairs(game.items[src]) do
                if item.name == name and amount > 0 then
                    local take = math.min(amount, item.amount)
                    item.amount = item.amount - take
                    amount = amount - take
                    if item.amount == 0 then game.items[src][slot] = nil end
                end
            end
            return true
        end,
        clearInventory = function(_, src) game.items[src] = {}; return true end,
        setItems = function(_, src, items) game.items[src] = items; return true end,
        useItem = function() return true end,
        getMoney = function(_, src, account) return game.money[src] and game.money[src][account] end,
        setMoney = function(_, src, account, amount) game.money[src][account] = amount; return true end,
        getJob = function(_, src) return game.jobs[src] end,
        getGang = function(_, src) return game.gangs[src] end,
        setJob = function(_, src, name, grade) game.jobs[src] = { name = name, grade = { level = grade }, onduty = true }; return true end,
        setGang = function(_, src, name, grade) game.gangs[src] = { name = name, grade = { level = grade } }; return true end,
        setJobDuty = function(_, src, on) game.jobs[src].onduty = on; return true end,
        getMetaData = function(_, src, key) if key == nil then return game.meta[src] end return game.meta[src][key] end,
        setMetaData = function(_, src, key, value) game.meta[src][key] = value; return true end,
    }
    local inventory = {
        AddItem = function(self, src, name, amount, slot, info) return core.addItem(self, src, name, amount, slot, info) end,
        RemoveItem = function(self, src, name, amount) return core.removeItem(self, src, name, amount) end,
        ClearInventory = core.clearInventory,
        SetInventory = core.setItems,
        useItem = core.useItem,
    }
    local keys = { giveKeys = function() return true end, removeKeys = function() return true end, hasKeys = function() return false end }
    _G.exports = setmetatable({ kora_core = core, kora_inventory = inventory, kora_vehiclekeys = keys }, {
        __call = function(_, name, fn) M.exported = M.exported or {}; M.exported[name] = fn end,
    })

    M.pushes = {}
    M.clientOps = {}
    _G.Kora = {
        events = {
            push = function(target, name, ...)
                M.pushes[#M.pushes + 1] = { target = target, name = name, args = { ... } }
                if name == 'kora_qa:exec' then
                    local token, op, data = ...
                    M.clientOps[#M.clientOps + 1] = { op = op, data = data }
                    local handler = M.clientHandler or function() return true end
                    QA.runs.execResult(target, token, handler(op, data))
                end
            end,
            register = function(name, fn) M.registered = M.registered or {}; M.registered[name] = fn end,
        },
        qa = { setActive = function(src, state) M.active = M.active or {}; M.active[src] = state end, onEvent = function() return 1 end },
        notify = { send = function() end },
        permissions = { hasLevel = function() return false end },
        screenshot = { requestClient = function(_, _, cb) cb('no screenshot in tests') end },
    }

    dofile(root .. 'config.lua')
    dofile(root .. 'shared/keys.lua')
    dofile(root .. 'shared/catalog.lua')
    if opts.server ~= false then
        for _, file in ipairs({ 'util', 'panel', 'registry', 'game', 'steps', 'runs', 'engine', 'observers', 'main' }) do
            dofile(root .. 'server/' .. file .. '.lua')
        end
    end
    return M
end

---Last push of a given name.
function M.lastPush(name)
    for i = #M.pushes, 1, -1 do
        if M.pushes[i].name == name then return M.pushes[i] end
    end
end

return M
