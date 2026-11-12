-- Built-in step implementations, bound to shared/steps.json by id.
--
-- ctx = { src, run, def, params, step,
--         undo(data)            -- push an undo record for this step (run teardown pops them in reverse)
--         exec(op, data)        -- ask the tester's client to do something to its own ped; returns ok, result
--         events(type)          -- timeline events of `type` since the run's current action window
--         vehicle()             -- "the vehicle": last one spawned by the run, else the one the player is in
--       }
-- setup(ctx)   -> ok, detail | false, error     (state-changing; server re-validates args before this)
-- undo(ctx, d) -> nil                           (best effort; never raises into teardown)
-- check(ctx)   -> ok, actual, expected          (re-evaluated until Config.run.checkTimeoutMs)
-- observe      = { events = { [type] = true }, match(ctx, event) -> ok, detail }
--              | { poll(ctx) -> ok, detail }  | { timer = true }

QA.steps = { impl = {} }
local S = QA.steps.impl
local G = QA.game
local U = QA.util

local function fmtItem(count, name) return ('%dx %s'):format(count, name) end

local function needPed(ctx)
    local ped = GetPlayerPed(ctx.src)
    if not ped or ped == 0 then return nil end
    return ped
end

-- --- items -------------------------------------------------------------------------

local function setItemCount(ctx, name, target, info)
    if not G.itemDefined(name) then return false, ('unknown item "%s"'):format(name) end
    local current = G.itemCount(ctx.src, name)
    local delta = target - current
    if delta > 0 then
        local ok, err = G.addItem(ctx.src, name, delta, info)
        if not ok then return false, ('could not add %s: %s'):format(fmtItem(delta, name), tostring(err or 'refused')) end
    elseif delta < 0 then
        local ok, err = G.removeItem(ctx.src, name, -delta)
        if not ok then return false, ('could not remove %s: %s'):format(fmtItem(-delta, name), tostring(err or 'refused')) end
    end
    if delta ~= 0 then ctx.undo({ item = name, delta = delta }) end
    local now = G.itemCount(ctx.src, name)
    if now ~= target then return false, ('expected %d %s, have %d (inventory full?)'):format(target, name, now) end
    return true, ('%s (was %d)'):format(fmtItem(target, name), current)
end

local function undoItemDelta(ctx, data)
    if data.delta > 0 then
        G.removeItem(ctx.src, data.item, math.min(data.delta, G.itemCount(ctx.src, data.item)))
    elseif data.delta < 0 then
        G.addItem(ctx.src, data.item, -data.delta, nil)
    end
end

S['items.have'] = {
    setup = function(ctx) return setItemCount(ctx, ctx.params.item, ctx.params.count) end,
    undo = undoItemDelta,
}

S['items.have_meta'] = {
    setup = function(ctx)
        local p = ctx.params
        if not G.itemDefined(p.item) then return false, ('unknown item "%s"'):format(p.item) end
        local value = tonumber(p.value) or (p.value == 'true' and true) or (p.value ~= 'false' and p.value) or false
        local before = G.itemCount(ctx.src, p.item)
        local ok, err = G.addItem(ctx.src, p.item, p.count, { [p.key] = value })
        if not ok then return false, ('could not add %s: %s'):format(fmtItem(p.count, p.item), tostring(err or 'refused')) end
        ctx.undo({ item = p.item, delta = p.count })
        local after = G.itemCount(ctx.src, p.item)
        if after < before + p.count then return false, 'item was not added (inventory full?)' end
        return true, ('%s with %s=%s'):format(fmtItem(p.count, p.item), p.key, tostring(value))
    end,
    undo = undoItemDelta,
}

S['items.none'] = {
    setup = function(ctx) return setItemCount(ctx, ctx.params.item, 0) end,
    undo = undoItemDelta,
}

S['inventory.empty'] = {
    setup = function(ctx)
        local items = G.items(ctx.src)
        ctx.undo({ items = U.deepcopy(items) })
        local ok, err = G.clearInventory(ctx.src)
        if ok == false or ok == nil and err then return false, tostring(err or 'clear failed') end
        if #G.inventoryList(ctx.src) > 0 then return false, 'inventory still has items' end
        return true, 'inventory cleared'
    end,
    undo = function(ctx, data) G.setItems(ctx.src, data.items) end,
}

-- --- money -------------------------------------------------------------------------

local function setMoney(ctx, account, amount)
    local before = G.getMoney(ctx.src, account)
    if before == nil then return false, ('unknown money account "%s"'):format(account) end
    if before ~= amount then
        local ok, err = G.setMoney(ctx.src, account, amount)
        if not ok then return false, ('could not set %s: %s'):format(account, tostring(err or 'refused')) end
        ctx.undo({ account = account, amount = before })
    end
    local now = G.getMoney(ctx.src, account)
    if now ~= amount then return false, ('%s is %s, expected %d'):format(account, tostring(now), amount) end
    return true, ('%s = %d (was %d)'):format(account, amount, before)
end

local function undoMoney(ctx, data) G.setMoney(ctx.src, data.account, data.amount) end

S['money.set'] = {
    setup = function(ctx) return setMoney(ctx, ctx.params.account, ctx.params.amount) end,
    undo = undoMoney,
}

S['money.at_least'] = {
    setup = function(ctx)
        local current = G.getMoney(ctx.src, ctx.params.account)
        if current == nil then return false, ('unknown money account "%s"'):format(ctx.params.account) end
        if current >= ctx.params.amount then return true, ('%s already %d'):format(ctx.params.account, current) end
        return setMoney(ctx, ctx.params.account, ctx.params.amount)
    end,
    undo = undoMoney,
}

-- --- job / gang / duty / metadata ----------------------------------------------------------

local function setGroup(ctx, kind, name, grade)
    local defined = kind == 'job' and G.jobDefined(name) or (kind == 'gang' and G.gangDefined(name))
    if not defined then return false, ('unknown %s "%s"'):format(kind, name) end
    local before = kind == 'job' and G.getJob(ctx.src) or G.getGang(ctx.src)
    local ok, err
    if kind == 'job' then ok, err = G.setJob(ctx.src, name, grade) else ok, err = G.setGang(ctx.src, name, grade) end
    if not ok then return false, ('could not set %s: %s'):format(kind, tostring(err or 'refused')) end
    if before then ctx.undo({ kind = kind, name = before.name, grade = before.grade, onduty = before.onduty }) end
    local now = kind == 'job' and G.getJob(ctx.src) or G.getGang(ctx.src)
    if not now or now.name ~= name or now.grade ~= grade then
        return false, ('%s is %s grade %s'):format(kind, now and now.name or '?', now and tostring(now.grade) or '?')
    end
    return true, ('%s %s grade %d'):format(kind, name, grade)
end

local function undoGroup(ctx, data)
    if data.kind == 'job' then
        G.setJob(ctx.src, data.name, data.grade or 1)
        if data.onduty ~= nil then G.setDuty(ctx.src, data.onduty) end
    else
        G.setGang(ctx.src, data.name, data.grade or 1)
    end
end

S['job.set'] = { setup = function(ctx) return setGroup(ctx, 'job', ctx.params.job, 1) end, undo = undoGroup }
S['job.set_grade'] = { setup = function(ctx) return setGroup(ctx, 'job', ctx.params.job, ctx.params.grade) end, undo = undoGroup }
S['gang.set'] = { setup = function(ctx) return setGroup(ctx, 'gang', ctx.params.gang, 1) end, undo = undoGroup }
S['gang.set_grade'] = { setup = function(ctx) return setGroup(ctx, 'gang', ctx.params.gang, ctx.params.grade) end, undo = undoGroup }

local function setDuty(ctx, onDuty)
    local job = G.getJob(ctx.src)
    if not job then return false, 'no job data' end
    if job.onduty ~= onDuty then
        local ok, err = G.setDuty(ctx.src, onDuty)
        if not ok then return false, ('could not change duty: %s'):format(tostring(err or 'refused')) end
        ctx.undo({ onduty = job.onduty })
    end
    local now = G.getJob(ctx.src)
    if not now or now.onduty ~= onDuty then return false, 'duty did not change' end
    return true, onDuty and 'on duty' or 'off duty'
end
local function undoDuty(ctx, data) G.setDuty(ctx.src, data.onduty == true) end
S['job.on_duty'] = { setup = function(ctx) return setDuty(ctx, true) end, undo = undoDuty }
S['job.off_duty'] = { setup = function(ctx) return setDuty(ctx, false) end, undo = undoDuty }

local function parseValue(text)
    if text == 'true' then return true end
    if text == 'false' then return false end
    return tonumber(text) or text
end

S['metadata.set'] = {
    setup = function(ctx)
        local key, value = ctx.params.key, parseValue(ctx.params.value)
        local before = G.getMeta(ctx.src, key)
        local ok, err = G.setMeta(ctx.src, key, value)
        if not ok then return false, ('could not set metadata %s: %s'):format(key, tostring(err or 'refused')) end
        ctx.undo({ key = key, value = U.deepcopy(before), hadValue = before ~= nil })
        local now = G.getMeta(ctx.src, key)
        if tostring(now) ~= tostring(value) then return false, ('metadata %s is %s'):format(key, tostring(now)) end
        return true, ('%s = %s'):format(key, tostring(value))
    end,
    undo = function(ctx, data) G.setMeta(ctx.src, data.key, data.value) end,
}

-- --- teleport --------------------------------------------------------------------------

local function teleport(ctx, target, label)
    local before = U.playerCoords(ctx.src)
    if not before then return false, 'player ped unavailable' end
    local ok, result = ctx.exec('teleport', { x = target.x, y = target.y, z = target.z, h = target.h })
    if not ok then return false, ('client could not teleport: %s'):format(tostring(result)) end
    ctx.undo({ x = before.x, y = before.y, z = before.z, h = before.h })
    local deadline = GetGameTimer() + 3000
    local distance = math.huge
    repeat
        distance = U.distance(U.playerCoords(ctx.src), target)
        if distance <= Config.run.teleportToleranceM then break end
        Wait(200)
    until GetGameTimer() > deadline
    if distance > Config.run.teleportToleranceM then
        return false, ('still %.0f m from %s after teleporting'):format(distance, label)
    end
    return true, ('at %s'):format(label)
end

local function undoTeleport(ctx, data)
    ctx.exec('teleport', data)
end

S['teleport.location'] = {
    setup = function(ctx)
        local l = ctx.params.location
        return teleport(ctx, l, ('"%s"'):format(l.name))
    end,
    undo = undoTeleport,
}
S['teleport.coords'] = {
    setup = function(ctx)
        local p = ctx.params
        return teleport(ctx, { x = p.x, y = p.y, z = p.z }, ('%.1f, %.1f, %.1f'):format(p.x, p.y, p.z))
    end,
    undo = undoTeleport,
}
S['teleport.coords_heading'] = {
    setup = function(ctx)
        local p = ctx.params
        return teleport(ctx, { x = p.x, y = p.y, z = p.z, h = p.heading }, ('%.1f, %.1f, %.1f'):format(p.x, p.y, p.z))
    end,
    undo = undoTeleport,
}

-- --- vehicles --------------------------------------------------------------------------

local function spawnVehicle(ctx, keys, driver)
    local model = ctx.params.model
    local vehicle, err, netId, plate = G.spawnVehicle(ctx.src, model)
    if not vehicle then return false, err end
    ctx.undo({ entity = vehicle, plate = plate, keys = keys or driver })
    ctx.run.vehicle = vehicle
    ctx.run.entityCount = (ctx.run.entityCount or 0) + 1
    local detail = ('%s (plate %s)'):format(model, plate)
    if keys or driver then
        if not G.giveKeys(ctx.src, plate) then return false, 'kora_vehiclekeys refused the keys' end
        detail = detail .. ', keys'
    end
    if driver then
        local ok, result = ctx.exec('warp', { netId = netId, seat = -1 })
        if not ok then return false, ('could not get in: %s'):format(tostring(result)) end
        local ped = needPed(ctx)
        local deadline = GetGameTimer() + 3000
        while ped and GetPedInVehicleSeat(vehicle, -1) ~= ped and GetGameTimer() < deadline do Wait(100) end
        if not ped or GetPedInVehicleSeat(vehicle, -1) ~= ped then return false, 'not in the driver seat' end
        detail = detail .. ', driver seat'
    end
    return true, detail
end

local function undoVehicle(ctx, data)
    if data.keys and data.plate then G.removeKeys(ctx.src, data.plate) end
    G.deleteEntity(data.entity)
    if ctx.run.vehicle == data.entity then ctx.run.vehicle = nil end
end

S['vehicle.spawn'] = { setup = function(ctx) return spawnVehicle(ctx, false, false) end, undo = undoVehicle }
S['vehicle.spawn_keys'] = { setup = function(ctx) return spawnVehicle(ctx, true, false) end, undo = undoVehicle }
S['vehicle.driver'] = { setup = function(ctx) return spawnVehicle(ctx, true, true) end, undo = undoVehicle }

local function theVehicle(ctx)
    local vehicle = ctx.vehicle()
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil, 'there is no vehicle (spawn one or sit in one first)' end
    return vehicle
end

S['vehicle.keys'] = {
    setup = function(ctx)
        local vehicle, err = theVehicle(ctx)
        if not vehicle then return false, err end
        local plate = GetVehicleNumberPlateText(vehicle)
        if G.hasKeys(ctx.src, plate) then return true, 'already had the keys' end
        if not G.giveKeys(ctx.src, plate) then return false, 'kora_vehiclekeys refused the keys' end
        ctx.undo({ plate = plate })
        return true, ('keys for %s'):format(U.trim(plate))
    end,
    undo = function(ctx, data) G.removeKeys(ctx.src, data.plate) end,
}

S['vehicle.fuel'] = {
    setup = function(ctx)
        local vehicle, err = theVehicle(ctx)
        if not vehicle then return false, err end
        local ok, result = ctx.exec('fuel', { netId = NetworkGetNetworkIdFromEntity(vehicle), level = ctx.params.percent })
        if not ok then return false, tostring(result) end
        return true, ('fuel %d%%'):format(ctx.params.percent)
    end,
}

S['vehicle.engine'] = {
    setup = function(ctx)
        local vehicle, err = theVehicle(ctx)
        if not vehicle then return false, err end
        local ok, result = ctx.exec('engine', { netId = NetworkGetNetworkIdFromEntity(vehicle), value = ctx.params.health })
        if not ok then return false, tostring(result) end
        return true, ('engine health %d'):format(ctx.params.health)
    end,
}

local function setLock(ctx, locked)
    local vehicle, err = theVehicle(ctx)
    if not vehicle then return false, err end
    local before = G.vehicleLocked(vehicle)
    local ok, lockErr = G.setVehicleLocked(vehicle, locked)
    if not ok then return false, lockErr end
    ctx.undo({ entity = vehicle, locked = before == true })
    if G.vehicleLocked(vehicle) ~= locked then return false, 'lock state did not change' end
    return true, locked and 'locked' or 'unlocked'
end
local function undoLock(ctx, data)
    if DoesEntityExist(data.entity) then G.setVehicleLocked(data.entity, data.locked) end
end
S['vehicle.locked'] = { setup = function(ctx) return setLock(ctx, true) end, undo = undoLock }
S['vehicle.unlocked'] = { setup = function(ctx) return setLock(ctx, false) end, undo = undoLock }

-- --- peds / props ------------------------------------------------------------------------

local function undoEntity(ctx, data) G.deleteEntity(data.entity) end

local function spawned(ctx, entity, err, label)
    if not entity then return false, err end
    ctx.undo({ entity = entity })
    ctx.run.entityCount = (ctx.run.entityCount or 0) + 1
    return true, label
end

S['ped.spawn'] = {
    setup = function(ctx)
        local ped, err = G.spawnPed(ctx.src, ctx.params.model)
        return spawned(ctx, ped, err, ('ped %s'):format(ctx.params.model))
    end,
    undo = undoEntity,
}
S['ped.spawn_scenario'] = {
    setup = function(ctx)
        local ped, err = G.spawnPed(ctx.src, ctx.params.model, ctx.params.scenario)
        return spawned(ctx, ped, err, ('ped %s doing %s'):format(ctx.params.model, ctx.params.scenario))
    end,
    undo = undoEntity,
}
S['prop.spawn'] = {
    setup = function(ctx)
        local object, err = G.spawnProp(ctx.src, ctx.params.model)
        return spawned(ctx, object, err, ('prop %s'):format(ctx.params.model))
    end,
    undo = undoEntity,
}

-- --- weapons ------------------------------------------------------------------------------

local function equipWeapon(ctx, weapon, ammo)
    if not weapon:match('^weapon_') then return false, ('"%s" is not a weapon item'):format(weapon) end
    if not G.itemDefined(weapon) then return false, ('unknown weapon "%s"'):format(weapon) end
    local ok, err = G.addItem(ctx.src, weapon, 1, ammo and { ammo = ammo } or nil)
    if not ok then return false, ('could not give %s: %s'):format(weapon, tostring(err or 'refused')) end
    ctx.undo({ item = weapon, delta = 1, weapon = true })
    G.useItem(ctx.src, weapon)
    local ped = needPed(ctx)
    local hash = joaat(weapon)
    local deadline = GetGameTimer() + 2500
    while ped and GetSelectedPedWeapon(ped) ~= hash and GetGameTimer() < deadline do Wait(100) end
    if not ped or GetSelectedPedWeapon(ped) ~= hash then
        -- Inventory "use" did not equip (e.g. hotbar-only equip): ask the client.
        local done, result = ctx.exec('equip', { weapon = weapon, ammo = ammo })
        if not done then return false, ('could not equip: %s'):format(tostring(result)) end
        Wait(300)
        if not ped or GetSelectedPedWeapon(ped) ~= hash then return false, 'weapon is not in my hands' end
    end
    return true, ammo and ('%s with %d ammo'):format(weapon, ammo) or weapon
end

S['weapon.equip'] = {
    setup = function(ctx) return equipWeapon(ctx, ctx.params.weapon, nil) end,
    undo = function(ctx, data)
        ctx.exec('unequip', { weapon = data.item })
        undoItemDelta(ctx, data)
    end,
}
S['weapon.equip_ammo'] = {
    setup = function(ctx) return equipWeapon(ctx, ctx.params.weapon, ctx.params.ammo) end,
    undo = S['weapon.equip'].undo,
}

-- --- health ---------------------------------------------------------------------------------

local function revive(ctx)
    local ok, result = ctx.exec('heal', { revive = true })
    if not ok then return false, tostring(result) end
    local deadline = GetGameTimer() + 3000
    while G.isDead(ctx.src) and GetGameTimer() < deadline do Wait(200) end
    if G.isDead(ctx.src) then return false, 'still dead or downed' end
    return true
end

S['health.full'] = {
    setup = function(ctx)
        local ok, err = revive(ctx)
        if not ok then return false, err end
        return true, 'full health'
    end,
}
S['health.revived'] = S['health.full']

S['health.dead'] = {
    setup = function(ctx)
        local ok, result = ctx.exec('kill', {})
        if not ok then return false, tostring(result) end
        ctx.undo({})
        local deadline = GetGameTimer() + 3000
        while not G.isDead(ctx.src) and GetGameTimer() < deadline do Wait(200) end
        if not G.isDead(ctx.src) then return false, 'still alive' end
        return true, 'dead'
    end,
    undo = function(ctx) ctx.exec('heal', { revive = true }) end,
}

S['health.percent'] = {
    setup = function(ctx)
        local ped = needPed(ctx)
        local before = ped and GetEntityHealth(ped) or nil
        local ok, result = ctx.exec('health', { percent = ctx.params.percent })
        if not ok then return false, tostring(result) end
        ctx.undo({ health = before })
        return true, ('health %d%%'):format(ctx.params.percent)
    end,
    undo = function(ctx, data) ctx.exec('heal', { revive = true, health = data.health }) end,
}

S['health.armour'] = {
    setup = function(ctx)
        local ped = needPed(ctx)
        if not ped then return false, 'player ped unavailable' end
        local before = GetPedArmour(ped)
        SetPedArmour(ped, ctx.params.armour)
        ctx.undo({ armour = before })
        local deadline = GetGameTimer() + 2000
        while GetPedArmour(ped) ~= ctx.params.armour and GetGameTimer() < deadline do Wait(100) end
        if GetPedArmour(ped) ~= ctx.params.armour then return false, ('armour is %d'):format(GetPedArmour(ped)) end
        return true, ('armour %d'):format(ctx.params.armour)
    end,
    undo = function(ctx, data)
        local ped = GetPlayerPed(ctx.src)
        if ped and ped ~= 0 then SetPedArmour(ped, data.armour or 0) end
    end,
}

-- --- world ----------------------------------------------------------------------------------

S['world.time'] = {
    setup = function(ctx)
        local hour, minute = G.time()
        if hour == nil then return false, 'kora_weathersync is not started' end
        local frozen = G.timeFrozen()
        local ok, err = G.setTime(ctx.params.hour, ctx.params.minute)
        if not ok then return false, tostring(err) end
        G.setTimeFrozen(true)
        ctx.undo({ hour = hour, minute = minute, frozen = frozen == true })
        return true, ('%02d:%02d (frozen)'):format(ctx.params.hour, ctx.params.minute)
    end,
    undo = function(ctx, data)
        G.setTime(data.hour, data.minute)
        G.setTimeFrozen(data.frozen)
    end,
}

S['world.weather'] = {
    setup = function(ctx)
        local before = G.weather()
        if before == nil then return false, 'kora_weathersync is not started' end
        local ok, err = G.setWeather(ctx.params.weather)
        if not ok then return false, tostring(err) end
        ctx.undo({ weather = before })
        return true, ctx.params.weather
    end,
    undo = function(ctx, data) G.setWeather(data.weather) end,
}

-- fixture.run is executed by QA.runs (it validates and runs each sub-step itself).
S['fixture.run'] = { fixture = true }

-- --- observed --------------------------------------------------------------------------------

S['wait.seconds'] = { observe = { timer = true } }

S['command.run'] = {
    observe = {
        events = { command = true },
        match = function(ctx, event)
            return event.name and event.name:lower() == ctx.params.command.name, 'command handler ran'
        end,
    },
}

S['item.use'] = {
    observe = {
        events = { item = true },
        match = function(ctx, event)
            return event.name == ctx.params.item and event.data and event.data.action == 'used', 'kora_inventory: item used'
        end,
    },
}

S['inventory.open_mine'] = {
    observe = {
        events = { inventory = true },
        match = function(_, event) return event.name == 'player', 'kora_inventory: own inventory opened' end,
    },
}

local function lockObserver(locked)
    return {
        events = { vehicle = true },
        match = function(ctx, event)
            local wanted = locked and 'locked' or 'unlocked'
            if event.name ~= wanted then return false end
            local vehicle = ctx.run.vehicle
            if vehicle and event.data and event.data.entity and event.data.entity ~= vehicle then return false end
            return true, 'kora_vehiclekeys: ' .. wanted
        end,
    }
end
S['vehicle.lock_action'] = { observe = lockObserver(true) }
S['vehicle.unlock_action'] = { observe = lockObserver(false) }

S['vehicle.enter'] = {
    observe = {
        poll = function(ctx)
            local current = G.currentVehicle(ctx.src)
            if current == 0 then return false end
            if ctx.run.vehicle and DoesEntityExist(ctx.run.vehicle) and current ~= ctx.run.vehicle then return false end
            return true, 'in the vehicle'
        end,
    },
}

S['vehicle.exit'] = {
    observe = {
        poll = function(ctx) return G.currentVehicle(ctx.src) == 0, 'on foot' end,
    },
}

local function locationRadius(location) return location.r or Config.run.defaultLocationRadius end

S['location.go'] = {
    observe = {
        poll = function(ctx)
            local location = ctx.params.location
            local distance = U.distance(U.playerCoords(ctx.src), location)
            return distance <= locationRadius(location), ('%.1f m from "%s"'):format(distance, location.name)
        end,
    },
}

S['mark.fires'] = {
    observe = {
        events = { mark = true },
        match = function(ctx, event) return event.name == ctx.params.mark, ('mark %s'):format(event.name) end,
    },
}

S['target.option'] = {
    observe = {
        events = { mark = true },
        match = function(ctx, event)
            if event.name ~= 'target:option' or type(event.data) ~= 'table' then return false end
            local label = tostring(event.data.label or ''):lower()
            return label == ctx.params.label:lower(), ('target option "%s"'):format(event.data.label)
        end,
    },
}

-- --- checks ------------------------------------------------------------------------------------

S['items.count'] = {
    check = function(ctx)
        local n = G.itemCount(ctx.src, ctx.params.item)
        return n == ctx.params.count, fmtItem(n, ctx.params.item), fmtItem(ctx.params.count, ctx.params.item)
    end,
}
S['items.none_check'] = {
    check = function(ctx)
        local n = G.itemCount(ctx.src, ctx.params.item)
        return n == 0, fmtItem(n, ctx.params.item), fmtItem(0, ctx.params.item)
    end,
}
S['items.changed'] = {
    check = function(ctx)
        local before = 0
        for _, item in ipairs(ctx.run.snapshot.items or {}) do
            if item.name == ctx.params.item then before = before + item.amount end
        end
        local delta = G.itemCount(ctx.src, ctx.params.item) - before
        return delta == ctx.params.delta, ('changed by %+d'):format(delta), ('changed by %+d'):format(ctx.params.delta)
    end,
}

local function money(ctx) return G.getMoney(ctx.src, ctx.params.account) end
S['money.changed'] = {
    check = function(ctx)
        local before = ctx.run.snapshot.money and ctx.run.snapshot.money[ctx.params.account]
        local now = money(ctx)
        if before == nil or now == nil then return false, 'balance unavailable', ('changed by %+d'):format(ctx.params.delta) end
        local delta = now - before
        return delta == ctx.params.delta, ('changed by %+d (%d -> %d)'):format(delta, before, now), ('changed by %+d'):format(ctx.params.delta)
    end,
}
S['money.equals'] = {
    check = function(ctx)
        local now = money(ctx)
        return now == ctx.params.amount, tostring(now), tostring(ctx.params.amount)
    end,
}
S['money.at_least_check'] = {
    check = function(ctx)
        local now = money(ctx)
        return now ~= nil and now >= ctx.params.amount, tostring(now), ('>= %d'):format(ctx.params.amount)
    end,
}

S['location.at'] = {
    check = function(ctx)
        local l = ctx.params.location
        local distance = U.distance(U.playerCoords(ctx.src), l)
        return distance <= locationRadius(l), ('%.1f m away'):format(distance), ('within %.1f m of "%s"'):format(locationRadius(l), l.name)
    end,
}
S['location.near'] = {
    check = function(ctx)
        local l = ctx.params.location
        local distance = U.distance(U.playerCoords(ctx.src), l)
        return distance <= ctx.params.metres, ('%.1f m away'):format(distance), ('within %d m of "%s"'):format(ctx.params.metres, l.name)
    end,
}

S['vehicle.in_any'] = {
    check = function(ctx)
        local v = G.currentVehicle(ctx.src)
        return v ~= 0, v ~= 0 and 'in a vehicle' or 'on foot', 'in a vehicle'
    end,
}
S['vehicle.in_model'] = {
    check = function(ctx)
        local v = G.currentVehicle(ctx.src)
        if v == 0 then return false, 'on foot', ctx.params.model end
        return G.vehicleModelMatches(v, ctx.params.model), ('model hash %s'):format(GetEntityModel(v)), ctx.params.model
    end,
}

local function lockCheck(locked)
    return function(ctx)
        local vehicle = ctx.vehicle()
        local state = G.vehicleLocked(vehicle)
        if state == nil then return false, 'no vehicle', locked and 'locked' or 'unlocked' end
        return state == locked, state and 'locked' or 'unlocked', locked and 'locked' or 'unlocked'
    end
end
S['vehicle.locked_check'] = { check = lockCheck(true) }
S['vehicle.unlocked_check'] = { check = lockCheck(false) }

local function groupText(g) return g and ('%s grade %s'):format(g.name, tostring(g.grade)) or 'none' end
S['job.is'] = { check = function(ctx) local j = G.getJob(ctx.src); return j and j.name == ctx.params.job, groupText(j), ctx.params.job end }
S['job.grade_is'] = {
    check = function(ctx)
        local j = G.getJob(ctx.src)
        return j and j.name == ctx.params.job and j.grade == ctx.params.grade, groupText(j), ('%s grade %d'):format(ctx.params.job, ctx.params.grade)
    end,
}
S['job.on_duty_check'] = { check = function(ctx) local j = G.getJob(ctx.src); return j and j.onduty == true, j and (j.onduty and 'on duty' or 'off duty') or '?', 'on duty' end }
S['job.off_duty_check'] = { check = function(ctx) local j = G.getJob(ctx.src); return j and j.onduty == false, j and (j.onduty and 'on duty' or 'off duty') or '?', 'off duty' end }
S['gang.is'] = { check = function(ctx) local g = G.getGang(ctx.src); return g and g.name == ctx.params.gang, groupText(g), ctx.params.gang end }
S['metadata.is'] = {
    check = function(ctx)
        local value = G.getMeta(ctx.src, ctx.params.key)
        return tostring(value) == ctx.params.value, tostring(value), ctx.params.value
    end,
}

S['health.alive'] = { check = function(ctx) local dead = G.isDead(ctx.src); return not dead, dead and 'dead/downed' or 'alive', 'alive' end }
S['health.dead_check'] = { check = function(ctx) local dead = G.isDead(ctx.src); return dead, dead and 'dead/downed' or 'alive', 'dead or downed' end }

S['weapon.equipped_check'] = {
    check = function(ctx)
        local ped = needPed(ctx)
        local selected = ped and GetSelectedPedWeapon(ped) or 0
        return selected == joaat(ctx.params.weapon), ('weapon hash %s'):format(selected), ctx.params.weapon
    end,
}

local function textMatch(haystack, needle)
    return type(haystack) == 'string' and haystack:lower():find(needle:lower(), 1, true) ~= nil
end

S['notify.contains'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('notify')) do
            local data = event.data or {}
            if textMatch(data.message, ctx.params.text) or textMatch(data.title, ctx.params.text) then return true, data.message or data.title, ctx.params.text end
            seen[#seen + 1] = tostring(data.message or data.title)
        end
        return false, #seen > 0 and ('saw: ' .. table.concat(seen, ' | '):sub(1, 300)) or 'no notification', ('a notification containing "%s"'):format(ctx.params.text)
    end,
}

local function nuiCheck(kinds)
    return function(ctx)
        local wanted = ctx.params.app or ctx.params.title
        local seen = {}
        for _, event in ipairs(ctx.events('nui')) do
            local kind = event.data and event.data.kind
            if kinds[kind] then
                if event.name == wanted or (event.name and event.name:lower() == wanted:lower()) then return true, event.name, wanted end
                seen[#seen + 1] = tostring(event.name)
            end
        end
        return false, #seen > 0 and ('opened: ' .. table.concat(seen, ', ')) or 'nothing opened', wanted
    end
end
S['nui.app'] = { check = nuiCheck({ app = true }) }
S['nui.menu'] = { check = nuiCheck({ menu = true, input = true }) }

S['inventory.opens'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('inventory')) do
            if event.name == ctx.params.type then return true, event.name, ctx.params.type end
            seen[#seen + 1] = tostring(event.name)
        end
        return false, #seen > 0 and ('opened: ' .. table.concat(seen, ', ')) or 'no inventory opened', ('the %s inventory'):format(ctx.params.type)
    end,
}

S['callback.called'] = {
    check = function(ctx)
        for _, event in ipairs(ctx.events('callback')) do
            if event.name == ctx.params.callback then
                local d = event.data or {}
                return true, ('called (ok=%s%s)'):format(tostring(d.okField ~= nil and d.okField or d.ok), d.error and (', ' .. tostring(d.error)) or ''), ctx.params.callback
            end
        end
        return false, 'not called', ctx.params.callback
    end,
}

S['errors.none'] = {
    eventual = false,
    check = function(ctx)
        local errors = {}
        for _, event in ipairs(ctx.events('console')) do
            if event.data and event.data.error then errors[#errors + 1] = event.data.line end
        end
        for _, event in ipairs(ctx.events('error')) do errors[#errors + 1] = tostring(event.name or (event.data and event.data.message)) end
        return #errors == 0, #errors == 0 and 'no errors' or table.concat(errors, '\n'):sub(1, 600), 'no script errors'
    end,
}

-- ===========================================================================================
-- v2 additions (from the legacy conversion's unmapped phrases)
-- ===========================================================================================

---Asks the client for its UI/vehicle state. Returns the probe table or nil, err.
local function probe(ctx, data)
    local ok, result = ctx.exec('probe', data or {})
    if not ok or type(result) ~= 'table' then return nil, tostring(result or 'client did not answer') end
    return result
end
QA.steps.probe = probe

-- --- vehicle engine ---------------------------------------------------------------------------

local function engineRunning(ctx, vehicle)
    local okNative, running = pcall(GetIsVehicleEngineRunning, vehicle)
    if okNative and type(running) == 'boolean' then return running end
    local state = probe(ctx, { netId = NetworkGetNetworkIdFromEntity(vehicle) })
    if state then return state.engine == true end
    return nil
end

local function setEngine(ctx, on)
    local vehicle, err = theVehicle(ctx)
    if not vehicle then return false, err end
    local before = engineRunning(ctx, vehicle)
    local ok, result = ctx.exec('engineState', { netId = NetworkGetNetworkIdFromEntity(vehicle), on = on })
    if not ok then return false, tostring(result) end
    ctx.undo({ entity = vehicle, on = before == true })
    local deadline = GetGameTimer() + 2500
    while engineRunning(ctx, vehicle) ~= on and GetGameTimer() < deadline do Wait(200) end
    if engineRunning(ctx, vehicle) ~= on then return false, on and 'engine did not start' or 'engine did not stop' end
    return true, on and 'engine running' or 'engine off'
end

local function undoEngine(ctx, data)
    if DoesEntityExist(data.entity) then
        ctx.exec('engineState', { netId = NetworkGetNetworkIdFromEntity(data.entity), on = data.on })
    end
end

S['vehicle.engine_on'] = { setup = function(ctx) return setEngine(ctx, true) end, undo = undoEngine }
S['vehicle.engine_off'] = { setup = function(ctx) return setEngine(ctx, false) end, undo = undoEngine }

local function engineObserver(on)
    return {
        poll = function(ctx)
            local vehicle = ctx.vehicle()
            if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
            return engineRunning(ctx, vehicle) == on, on and 'engine running' or 'engine off'
        end,
    }
end
S['vehicle.engine_on_action'] = { observe = engineObserver(true) }
S['vehicle.engine_off_action'] = { observe = engineObserver(false) }

local function engineCheck(on)
    return function(ctx)
        local vehicle = ctx.vehicle()
        local expected = on and 'engine running' or 'engine off'
        if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no vehicle', expected end
        local running = engineRunning(ctx, vehicle)
        return running == on, running and 'engine running' or 'engine off', expected
    end
end
S['vehicle.engine_on_check'] = { check = engineCheck(true) }
S['vehicle.engine_off_check'] = { check = engineCheck(false) }

S['vehicle.driver_check'] = {
    check = function(ctx)
        local ped = needPed(ctx)
        local vehicle = G.currentVehicle(ctx.src)
        if not ped or vehicle == 0 then return false, 'not in a vehicle', 'driver seat' end
        local driver = GetPedInVehicleSeat(vehicle, -1) == ped
        return driver, driver and 'driver seat' or 'passenger seat', 'driver seat'
    end,
}

S['vehicle.deleted_check'] = {
    check = function(ctx)
        local vehicle = ctx.run.vehicle
        if not vehicle then return false, 'this run spawned no vehicle', 'the spawned vehicle deleted' end
        local exists = DoesEntityExist(vehicle)
        return not exists, exists and 'vehicle still exists' or 'deleted', 'the spawned vehicle deleted'
    end,
}

S['vehicle.fuel_check'] = {
    check = function(ctx)
        local vehicle = ctx.vehicle()
        local expected = ('%d%% fuel'):format(ctx.params.percent)
        if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no vehicle', expected end
        local state, err = probe(ctx, { netId = NetworkGetNetworkIdFromEntity(vehicle) })
        if not state or type(state.fuel) ~= 'number' then return false, err or 'fuel unknown', expected end
        return math.abs(state.fuel - ctx.params.percent) <= 2, ('%.0f%% fuel'):format(state.fuel), expected
    end,
}

-- --- key press ---------------------------------------------------------------------------------

S['key.press'] = {
    observe = {
        events = { key = true },
        match = function(ctx, event) return event.name == ctx.params.key, ('pressed %s'):format(event.name) end,
    },
}

-- --- marks ---------------------------------------------------------------------------------------

local function field(data, path)
    local value = data
    for part in tostring(path):gmatch('[^%.]+') do
        if type(value) ~= 'table' then return nil end
        value = value[part] ~= nil and value[part] or value[tonumber(part) or part]
    end
    return value
end
QA.steps.field = field

S['mark.fires_with'] = {
    observe = {
        events = { mark = true },
        match = function(ctx, event)
            if event.name ~= ctx.params.mark then return false end
            local value = field(event.data, ctx.params.field)
            return value ~= nil and tostring(value) == ctx.params.value, ('mark %s with %s = %s'):format(event.name, ctx.params.field, tostring(value))
        end,
    },
}

S['mark.fires_within'] = {
    observe = {
        events = { mark = true },
        match = function(ctx, event) return event.name == ctx.params.mark, ('mark %s'):format(event.name) end,
        deadline = function(ctx) return ctx.params.seconds end,
    },
}

-- --- progress bar / text UI / notifications ------------------------------------------------------

S['progress.cancel_action'] = {
    observe = {
        events = { progress = true },
        match = function(_, event) return event.name == 'cancel', 'progress bar cancelled' end,
    },
}

local function progressCheck(ctx, label)
    local seen = {}
    for _, event in ipairs(ctx.events('progress')) do
        if event.name == 'start' then
            local text = event.data and event.data.label
            if not label or textMatch(text, label) then return true, tostring(text or 'progress bar'), label or 'a progress bar' end
            seen[#seen + 1] = tostring(text)
        end
    end
    return false, #seen > 0 and ('ran: ' .. table.concat(seen, ', ')) or 'no progress bar', label and ('a progress bar labelled "%s"'):format(label) or 'a progress bar'
end
S['progress.shown'] = { check = function(ctx) return progressCheck(ctx, nil) end }
S['progress.labelled'] = { check = function(ctx) return progressCheck(ctx, ctx.params.label) end }

S['textui.shows'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('textui')) do
            local text = event.data and event.data.text
            if textMatch(text, ctx.params.text) then return true, text, ctx.params.text end
            if text then seen[#seen + 1] = tostring(text) end
        end
        return false, #seen > 0 and ('showed: ' .. table.concat(seen, ' | '):sub(1, 300)) or 'no text UI', ctx.params.text
    end,
}

S['notify.titled'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('notify')) do
            local title = event.data and event.data.title
            if textMatch(title, ctx.params.text) then return true, title, ctx.params.text end
            seen[#seen + 1] = tostring(title)
        end
        return false, #seen > 0 and ('titles: ' .. table.concat(seen, ' | '):sub(1, 300)) or 'no notification', ('a notification titled "%s"'):format(ctx.params.text)
    end,
}

local NOTIFY_ALIASES = { inform = 'info', warn = 'warning' }
S['notify.type'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('notify')) do
            local kind = event.data and event.data.type or 'info'
            kind = NOTIFY_ALIASES[kind] or kind
            if kind == ctx.params.type then return true, ('%s: %s'):format(kind, tostring(event.data.message or event.data.title)), ctx.params.type end
            seen[#seen + 1] = tostring(kind)
        end
        return false, #seen > 0 and ('types: ' .. table.concat(seen, ', ')) or 'no notification', ('an %s notification'):format(ctx.params.type)
    end,
}

-- --- chat ------------------------------------------------------------------------------------------

S['chat.shows'] = {
    check = function(ctx)
        local seen = {}
        for _, event in ipairs(ctx.events('chat')) do
            local text = event.data and event.data.text
            if textMatch(text, ctx.params.text) then return true, text, ctx.params.text end
            if text then seen[#seen + 1] = tostring(text) end
        end
        return false, #seen > 0 and ('chat: ' .. table.concat(seen, ' | '):sub(1, 300)) or 'no chat message', ('a chat message containing "%s"'):format(ctx.params.text)
    end,
}

-- --- HUD / minimap / apps (client probe) --------------------------------------------------------------

-- labels = { on = text when the field is true, off = text when false }.
-- (String keys on purpose: indexing a table with a comparison result, t[a == b],
-- misbehaves on some Lua 5.4 builds.)
local function probeCheck(fieldName, wanted, labels)
    local expected = wanted and labels.on or labels.off
    return function(ctx)
        local state, err = probe(ctx, {})
        if not state then return false, err, expected end
        local value = state[fieldName]
        if value == nil then return false, ('%s unknown (resource not running?)'):format(fieldName), expected end
        local isOn = value == true
        return isOn == wanted, isOn and labels.on or labels.off, expected
    end
end
local HUD = { on = 'HUD visible', off = 'HUD hidden' }
local BELT = { on = 'seatbelt on', off = 'seatbelt off' }
local MAP = { on = 'minimap visible', off = 'minimap hidden' }
S['hud.visible'] = { check = probeCheck('hud', true, HUD) }
S['hud.hidden'] = { check = probeCheck('hud', false, HUD) }
S['hud.seatbelt_on'] = { check = probeCheck('seatbelt', true, BELT) }
S['hud.seatbelt_off'] = { check = probeCheck('seatbelt', false, BELT) }
S['hud.minimap_visible'] = { check = probeCheck('minimap', true, MAP) }
S['hud.minimap_hidden'] = { check = probeCheck('minimap', false, MAP) }

S['nui.app_open'] = {
    check = function(ctx)
        local state, err = probe(ctx, { app = ctx.params.app })
        if not state then return false, err, ctx.params.app end
        return state.app == true, state.app and 'open' or 'not open', ('app %s open'):format(ctx.params.app)
    end,
}

-- --- server console --------------------------------------------------------------------------------

S['console.server_shows'] = {
    check = function(ctx)
        local since = ctx.run.windowStart or ctx.run.startedAt
        for _, line in ipairs(QA.console.recent(400)) do
            if line.at >= since and textMatch(line.line, ctx.params.text) then return true, line.line, ctx.params.text end
        end
        return false, 'not printed', ('a console line containing "%s"'):format(ctx.params.text)
    end,
}

-- --- player state ------------------------------------------------------------------------------------

S['health.armour_check'] = {
    check = function(ctx)
        local ped = needPed(ctx)
        local armour = ped and GetPedArmour(ped) or -1
        return armour == ctx.params.armour, tostring(armour), tostring(ctx.params.armour)
    end,
}

S['items.at_least'] = {
    check = function(ctx)
        local n = G.itemCount(ctx.src, ctx.params.item)
        return n >= ctx.params.count, fmtItem(n, ctx.params.item), ('at least %s'):format(fmtItem(ctx.params.count, ctx.params.item))
    end,
}

local function metaDelta(ctx)
    local before = ctx.run.snapshot.metadata and tonumber(ctx.run.snapshot.metadata[ctx.params.key])
    local now = tonumber(G.getMeta(ctx.src, ctx.params.key))
    if before == nil or now == nil then return nil, ('metadata %s is not numeric (before %s, now %s)'):format(ctx.params.key, tostring(before), tostring(now)) end
    return now - before, ('%s -> %s'):format(before, now)
end

S['metadata.changed'] = {
    check = function(ctx)
        local delta, detail = metaDelta(ctx)
        local expected = ('changed by %+d'):format(ctx.params.delta)
        if not delta then return false, detail, expected end
        return math.abs(delta - ctx.params.delta) < 0.001, ('changed by %+g (%s)'):format(delta, detail), expected
    end,
}
S['metadata.increased'] = {
    check = function(ctx)
        local delta, detail = metaDelta(ctx)
        if not delta then return false, detail, 'increased' end
        return delta > 0, detail, 'increased'
    end,
}
S['metadata.decreased'] = {
    check = function(ctx)
        local delta, detail = metaDelta(ctx)
        if not delta then return false, detail, 'decreased' end
        return delta < 0, detail, 'decreased'
    end,
}
