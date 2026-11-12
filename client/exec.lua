-- Ops the server asks the tester's client to perform on its own ped/vehicle.
-- Only fixed ops exist; every value comes from the server, which validated it
-- against the scenario and the caps. The client never chooses what to set up.

local OPS = {}

local function waitFor(predicate, timeoutMs, step)
    local deadline = GetGameTimer() + timeoutMs
    while not predicate() and GetGameTimer() < deadline do Wait(step or 50) end
    return predicate()
end

local function vehicleFromNet(netId)
    if type(netId) ~= 'number' then return nil end
    if not waitFor(function() return NetworkDoesEntityExistWithNetworkId(netId) end, 5000, 100) then return nil end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    return vehicle
end

local function control(entity)
    waitFor(function()
        if NetworkHasControlOfEntity(entity) then return true end
        NetworkRequestControlOfEntity(entity)
        return false
    end, 1500, 50)
end

-- Same careful teleport as the legacy /test runner: the driver takes the vehicle,
-- collision is streamed in, and the ground probe is only trusted near the target.
OPS.teleport = function(data)
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not x or not y or not z then return false, 'bad coordinates' end
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local entity = (vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped) and vehicle or ped
    DoScreenFadeOut(250)
    waitFor(IsScreenFadedOut, 1000)
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(entity, x, y, z, false, false, false)
    if data.h then SetEntityHeading(entity, data.h + 0.0) end
    waitFor(function() return HasCollisionLoadedAroundEntity(entity) end, 3000)
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    if found and math.abs(groundZ - z) <= 3.0 then
        SetEntityCoordsNoOffset(entity, x, y, groundZ + 0.5, false, false, false)
    end
    if entity == vehicle then SetVehicleOnGroundProperly(vehicle) end
    DoScreenFadeIn(250)
    return true
end

OPS.warp = function(data)
    local vehicle = vehicleFromNet(data.netId)
    if not vehicle then return false, 'vehicle did not arrive' end
    control(vehicle)
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, tonumber(data.seat) or -1)
    return waitFor(function() return GetVehiclePedIsIn(PlayerPedId(), false) == vehicle end, 3000) or false, 'could not enter'
end

OPS.fuel = function(data)
    local vehicle = vehicleFromNet(data.netId)
    if not vehicle then return false, 'vehicle not found' end
    local level = math.max(0, math.min(100, tonumber(data.level) or 100)) + 0.0
    control(vehicle)
    if GetResourceState('kora_fuel') == 'started' then
        local ok = pcall(function() exports.kora_fuel:SetFuel(vehicle, level) end)
        if not ok then SetVehicleFuelLevel(vehicle, level) end
    else
        SetVehicleFuelLevel(vehicle, level)
    end
    return true, { fuel = GetVehicleFuelLevel(vehicle) }
end

OPS.engine = function(data)
    local vehicle = vehicleFromNet(data.netId)
    if not vehicle then return false, 'vehicle not found' end
    control(vehicle)
    SetVehicleEngineHealth(vehicle, (tonumber(data.value) or 1000) + 0.0)
    return true
end

local function revive(ped)
    if not IsPedInAnyVehicle(ped, false) then
        local c = GetEntityCoords(ped)
        NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), true, false)
        ped = PlayerPedId()
        ClearPedTasksImmediately(ped)
    end
    -- Both ambulance implementations track their own downed state (see kora_admin/client/relay.lua).
    TriggerEvent('hospital:client:Revive')
    TriggerEvent('qbambulance:client:revived', 100)
    return ped
end

OPS.heal = function(data)
    local ped = PlayerPedId()
    if data.revive and (IsPedDeadOrDying(ped, true) or IsEntityDead(ped) or LocalPlayer.state.isDead or LocalPlayer.state.inLastStand) then
        ped = revive(ped)
    elseif data.revive then
        TriggerEvent('qbambulance:client:revived', 100)
    end
    local health = tonumber(data.health)
    SetEntityHealth(ped, health and math.max(101, math.floor(health)) or GetEntityMaxHealth(ped))
    return true
end

OPS.kill = function()
    SetEntityHealth(PlayerPedId(), 0)
    return true
end

OPS.health = function(data)
    local ped = PlayerPedId()
    local percent = math.max(1, math.min(100, tonumber(data.percent) or 100))
    if IsPedDeadOrDying(ped, true) then ped = revive(ped) end
    local floor = 100
    local max = math.max(floor + 1, GetEntityMaxHealth(ped))
    SetEntityHealth(ped, math.floor(floor + (max - floor) * percent / 100))
    return true
end

OPS.equip = function(data)
    if type(data.weapon) ~= 'string' or not data.weapon:match('^weapon_[%w_]+$') then return false, 'bad weapon' end
    local hash = joaat(data.weapon)
    local ped = PlayerPedId()
    if not HasPedGotWeapon(ped, hash, false) then
        GiveWeaponToPed(ped, hash, tonumber(data.ammo) or 0, false, true)
    end
    SetCurrentPedWeapon(ped, hash, true)
    return GetSelectedPedWeapon(ped) == hash or false, 'weapon not selected'
end

OPS.unequip = function(data)
    local ped = PlayerPedId()
    if type(data.weapon) == 'string' and GetSelectedPedWeapon(ped) == joaat(data.weapon) then
        SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
    end
    return true
end

OPS.command = function(data)
    if type(data.command) ~= 'string' or data.command == '' or #data.command > 200 then return false, 'bad command' end
    ExecuteCommand(data.command)
    return true
end

OPS.context = function()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local streetHash, crossingHash = GetStreetNameAtCoord(c.x, c.y, c.z)
    local street = GetStreetNameFromHashKey(streetHash)
    local crossing = crossingHash ~= 0 and GetStreetNameFromHashKey(crossingHash) or nil
    local zone = GetLabelText(GetNameOfZone(c.x, c.y, c.z))
    local vehicle = GetVehiclePedIsIn(ped, false)
    return true, {
        street = ('%s%s%s'):format(street or '?', crossing and crossing ~= '' and (' / ' .. crossing) or '', zone and zone ~= 'NULL' and (', ' .. zone) or ''),
        vehicleModel = vehicle ~= 0 and GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)):lower() or nil,
        interior = GetInteriorFromEntity(ped),
    }
end

OPS.engineState = function(data)
    local vehicle = vehicleFromNet(data.netId)
    if not vehicle then return false, 'vehicle not found' end
    control(vehicle)
    SetVehicleEngineOn(vehicle, data.on == true, true, true)
    return true
end

-- Read-only snapshot of local state the server can't see (HUD, minimap,
-- seatbelt, open AppShell app, vehicle fuel/engine).
OPS.probe = function(data)
    local ped = PlayerPedId()
    local out = {
        minimap = not IsRadarHidden(),
        seatbelt = LocalPlayer.state.seatbelt == true,
    }
    if GetResourceState('kora_hud') == 'started' then
        local ok, visible = pcall(function() return exports.kora_hud:isVisible() end)
        if ok then out.hud = visible == true end
    end
    if type(data.app) == 'string' then
        local ok, open = pcall(Kora.nui.isAppOpen, data.app)
        out.app = ok and open == true
    end
    local vehicle = data.netId and vehicleFromNet(data.netId) or GetVehiclePedIsIn(ped, false)
    if vehicle and vehicle ~= 0 then
        out.fuel = GetVehicleFuelLevel(vehicle)
        if GetResourceState('kora_fuel') == 'started' then
            local ok, fuel = pcall(function() return exports.kora_fuel:GetFuel(vehicle) end)
            if ok and type(fuel) == 'number' then out.fuel = fuel end
        end
        out.engine = GetIsVehicleEngineRunning(vehicle)
    end
    return true, out
end

Kora.events.onPush('kora_qa:exec', function(token, op, data)
    local handler = OPS[op]
    CreateThread(function()
        local ok, result, extra = false, 'unknown op', nil
        if handler then
            local called
            called, ok, result = pcall(handler, type(data) == 'table' and data or {})
            if not called then ok, result = false, tostring(ok) end
        end
        extra = result
        Kora.events.trigger('kora_qa:execResult', token, ok == true, extra)
    end)
end)
