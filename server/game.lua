-- Thin, pcall-guarded wrappers over the game resources kora_qa drives
-- (kora_core, kora_inventory, kora_vehiclekeys, kora_weathersync). Each returns
-- (value) or (false/nil, err) and never raises into the step executor.

QA.game = {}
local G = QA.game
local U = QA.util

local function call(resource, fn, ...)
    if not U.started(resource) then return nil, resource .. ' is not started' end
    local results = table.pack(pcall(function(...) return exports[resource][fn](exports[resource], ...) end, ...))
    if not results[1] then return nil, tostring(results[2]) end
    return table.unpack(results, 2, results.n)
end
G.call = call

-- Item operations go through kora_inventory (locks, hooks, item boxes) when it
-- runs; kora_core's own inventory module otherwise.
local function inv() return U.started('kora_inventory') and 'kora_inventory' or 'kora_core' end

function G.itemDefined(name)
    local item = call('kora_core', 'getShared', 'items', name)
    if type(item) == 'table' then return true end
    local weapon = call('kora_core', 'getShared', 'weapons', name)
    return type(weapon) == 'table'
end

function G.itemCount(src, name)
    return tonumber(call('kora_core', 'getItemCount', src, name)) or 0
end

function G.items(src)
    local items = call('kora_core', 'getPlayerData', src, { 'items' })
    return type(items) == 'table' and items or {}
end

function G.addItem(src, name, amount, info)
    if inv() == 'kora_inventory' then
        return call('kora_inventory', 'AddItem', src, name, amount, nil, info, 'kora_qa')
    end
    return call('kora_core', 'addItem', src, name, amount, nil, info, 'kora_qa')
end

function G.removeItem(src, name, amount)
    if amount <= 0 then return true end
    if inv() == 'kora_inventory' then
        return call('kora_inventory', 'RemoveItem', src, name, amount, nil, 'kora_qa')
    end
    return call('kora_core', 'removeItem', src, name, amount, nil, 'kora_qa')
end

function G.clearInventory(src)
    if inv() == 'kora_inventory' then return call('kora_inventory', 'ClearInventory', src) end
    return call('kora_core', 'clearInventory', src)
end

function G.setItems(src, items)
    if inv() == 'kora_inventory' then return call('kora_inventory', 'SetInventory', src, items) end
    return call('kora_core', 'setItems', src, items)
end

function G.useItem(src, name)
    if inv() == 'kora_inventory' then return call('kora_inventory', 'useItem', src, name) end
    return call('kora_core', 'useItem', src, name)
end

---Inventory as a sorted list {slot, name, amount, info} for reports.
function G.inventoryList(src)
    local list = {}
    for slot, item in pairs(G.items(src)) do
        if type(item) == 'table' and type(item.name) == 'string' then
            list[#list + 1] = {
                slot = tonumber(slot) or tonumber(item.slot) or 0,
                name = item.name,
                amount = tonumber(item.amount) or 1,
                info = type(item.info) == 'table' and item.info or nil,
            }
        end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    return list
end

function G.getMoney(src, account) return tonumber(call('kora_core', 'getMoney', src, account)) end
function G.setMoney(src, account, amount) return call('kora_core', 'setMoney', src, account, amount, 'kora_qa') end

function G.jobDefined(name) return type(call('kora_core', 'getShared', 'jobs', name)) == 'table' end
function G.gangDefined(name) return type(call('kora_core', 'getShared', 'gangs', name)) == 'table' end

local function slim(group)
    if type(group) ~= 'table' then return nil end
    local grade = type(group.grade) == 'table' and (group.grade.level or group.grade.grade) or group.grade
    return { name = group.name, grade = tonumber(grade), onduty = group.onduty }
end
function G.getJob(src) return slim(call('kora_core', 'getJob', src)) end
function G.getGang(src) return slim(call('kora_core', 'getGang', src)) end
function G.setJob(src, name, grade) return call('kora_core', 'setJob', src, name, grade) end
function G.setGang(src, name, grade) return call('kora_core', 'setGang', src, name, grade) end
function G.setDuty(src, onDuty) return call('kora_core', 'setJobDuty', src, onDuty) end

function G.getMeta(src, key) return call('kora_core', 'getMetaData', src, key) end
function G.setMeta(src, key, value) return call('kora_core', 'setMetaData', src, key, value) end

function G.giveKeys(src, plate) return call('kora_vehiclekeys', 'giveKeys', src, plate, true) end
function G.removeKeys(src, plate) return call('kora_vehiclekeys', 'removeKeys', src, plate) end
function G.hasKeys(src, plate) return call('kora_vehiclekeys', 'hasKeys', src, plate) == true end

function G.vehicleLocked(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    local state = Entity(vehicle).state['qbvehiclekeys:locked']
    if state ~= nil then return state == true end
    return GetVehicleDoorLockStatus(vehicle) >= 2
end

function G.setVehicleLocked(vehicle, locked)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'the vehicle no longer exists' end
    Entity(vehicle).state:set('qbvehiclekeys:locked', locked == true, true)
    SetVehicleDoorsLocked(vehicle, locked and 2 or 1)
    pcall(Kora.events.push, -1, 'qbvehiclekeys:client:lockStateChanged', NetworkGetNetworkIdFromEntity(vehicle), locked == true)
    return true
end

function G.weather() return call('kora_weathersync', 'getWeather') end
function G.setWeather(weather) return call('kora_weathersync', 'setWeather', weather) end
function G.time()
    if not U.started('kora_weathersync') then return nil end
    local ok, hour, minute = pcall(function() return exports.kora_weathersync:getTime() end)
    if not ok then return nil end
    return hour, minute
end
function G.setTime(hour, minute) return call('kora_weathersync', 'setTime', hour, minute) end
function G.timeFrozen() return call('kora_weathersync', 'getTimeFrozen') end
function G.setTimeFrozen(state) return call('kora_weathersync', 'setTimeFrozen', state) end

---Dead or downed (kora_ambulance metadata), from server-side state.
function G.isDead(src)
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and GetEntityHealth(ped) <= 100 then return true end
    local meta = G.getMeta(src, nil)
    if type(meta) == 'table' and (meta.isdead == true or meta.inlaststand == true) then return true end
    return false
end

-- --- entities -------------------------------------------------------------------

local function waitExists(entity, timeoutMs)
    local deadline = GetGameTimer() + timeoutMs
    while entity and entity ~= 0 and not DoesEntityExist(entity) and GetGameTimer() < deadline do Wait(0) end
    return entity and entity ~= 0 and DoesEntityExist(entity)
end

---Position `distance` metres in front of the player.
function G.inFront(src, distance)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local origin = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local radians = math.rad(heading)
    return {
        x = origin.x - math.sin(radians) * distance,
        y = origin.y + math.cos(radians) * distance,
        z = origin.z,
        h = heading,
    }
end

local function intoBucket(entity, src)
    pcall(SetEntityRoutingBucket, entity, GetPlayerRoutingBucket(src))
end

function G.spawnVehicle(src, model)
    local at = G.inFront(src, Config.run.spawnDistance)
    if not at then return nil, 'player ped unavailable' end
    local vehicle = CreateVehicle(joaat(model), at.x, at.y, at.z, at.h, true, true)
    if not waitExists(vehicle, 4000) then return nil, ('could not create vehicle "%s" (unknown model?)'):format(model) end
    intoBucket(vehicle, src)
    local plate = ('QA%04d'):format(math.random(0, 9999))
    pcall(SetVehicleNumberPlateText, vehicle, plate)
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local deadline = GetGameTimer() + 2000
    while (not netId or netId <= 0) and GetGameTimer() < deadline do
        Wait(0)
        netId = NetworkGetNetworkIdFromEntity(vehicle)
    end
    return vehicle, nil, netId, plate
end

function G.spawnPed(src, model, scenario)
    local at = G.inFront(src, Config.run.spawnDistance - 1.5)
    if not at then return nil, 'player ped unavailable' end
    local ped = CreatePed(4, joaat(model), at.x, at.y, at.z - 1.0, (at.h + 180.0) % 360.0, true, true)
    if not waitExists(ped, 4000) then return nil, ('could not create ped "%s" (unknown model?)'):format(model) end
    intoBucket(ped, src)
    pcall(FreezeEntityPosition, ped, true)
    if scenario then pcall(TaskStartScenarioInPlace, ped, scenario, 0, true) end
    return ped
end

function G.spawnProp(src, model)
    local at = G.inFront(src, Config.run.spawnDistance - 1.5)
    if not at then return nil, 'player ped unavailable' end
    local object = CreateObjectNoOffset(joaat(model), at.x, at.y, at.z - 1.0, true, true, false)
    if not waitExists(object, 4000) then return nil, ('could not create prop "%s" (unknown model?)'):format(model) end
    intoBucket(object, src)
    pcall(SetEntityHeading, object, at.h)
    pcall(FreezeEntityPosition, object, true)
    return object
end

function G.deleteEntity(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        DeleteEntity(entity)
        return true
    end
    return false
end

function G.vehicleModelMatches(vehicle, model)
    return vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle) == joaat(model)
end

function G.currentVehicle(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    return GetVehiclePedIsIn(ped, false)
end
