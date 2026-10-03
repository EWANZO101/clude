local doors = {}
local nearbyDoors = {}

local targetModels = {}
local targetAdded = false
local doorTargetOptions = nil 

RegisterNetEvent('rps_doorlock:client:OpenUI', function(jobs, gangs)
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = 'openUI',
        jobs = jobs,
        gangs = gangs,
        doors = doors
    })
end)

RegisterNetEvent('rps_doorlock:client:SyncDoors', function(data)
    doors = data
    for _, door in pairs(doors) do
        CreateSystemDoor(door)
    end
end)

RegisterNetEvent('rps_doorlock:client:UpdateDoor', function(id, data)
    doors[id] = data
    CreateSystemDoor(data)
end)

RegisterNetEvent('rps_doorlock:client:DeleteDoor', function(id)
    local door = doors[id]
    if door then
        if door.isDouble then
            RemoveDoorFromSystem(door.doors[1].hash)
            RemoveDoorFromSystem(door.doors[2].hash)
        else
            RemoveDoorFromSystem(door.hash)
        end
    end
    doors[id] = nil
end)

RegisterNetEvent('rps_doorlock:client:SetState', function(id, state)
    local door = doors[id]
    if door then
        door.state = state
        UpdateSystemDoorState(door)
    end
end)

local function RegisterTargetModel(model)
    if not targetModels[model] and doorTargetOptions then
        targetModels[model] = true
        exports.rps_lib:AddModelTarget(model, doorTargetOptions.options, doorTargetOptions.distance)
    end
end

-- Holds the door open (instead of letting it swing shut) while it's both
-- unlocked and flagged keepOpen. Locking it always releases the hold, so it
-- can still swing closed and latch like a normal door once relocked.
local function ApplyHoldOpen(hash, door)
    DoorSystemSetHoldOpen(hash, door.keepOpen == true and door.state == 0)
end

-- doorType replaced the old boolean `auto` flag; garage/lab/sliding are
-- currently metadata only (shown in the UI/door list) and behave like a
-- normal door here, since GTA's door system only exposes hinge-door physics
-- through these natives. `auto` is read as a fallback for doors saved before
-- doorType existed.
local function IsAutomaticDoor(door)
    if door.doorType then
        return door.doorType == 'automatic'
    end
    return door.auto == true
end

function CreateSystemDoor(door)
    if door.isDouble then
        for i = 1, 2 do
            AddDoorToSystem(door.doors[i].hash, door.doors[i].model, door.doors[i].coords.x, door.doors[i].coords.y, door.doors[i].coords.z, false, false, false)
            DoorSystemSetDoorState(door.doors[i].hash, 4, false, false)
            DoorSystemSetDoorState(door.doors[i].hash, door.state, false, false)
            if not IsAutomaticDoor(door) then
                DoorSystemSetAutomaticRate(door.doors[i].hash, 10.0, false, false)
            end
            ApplyHoldOpen(door.doors[i].hash, door)
            RegisterTargetModel(door.doors[i].model)
        end
    else
        AddDoorToSystem(door.hash, door.doors[1].model, door.doors[1].coords.x, door.doors[1].coords.y, door.doors[1].coords.z, false, false, false)
        DoorSystemSetDoorState(door.hash, 4, false, false)
        DoorSystemSetDoorState(door.hash, door.state, false, false)
        if not IsAutomaticDoor(door) then
            DoorSystemSetAutomaticRate(door.hash, 10.0, false, false)
        end
        ApplyHoldOpen(door.hash, door)
        RegisterTargetModel(door.doors[1].model)
    end
end

function UpdateSystemDoorState(door)
    if door.isDouble then
        for i = 1, 2 do
            DoorSystemSetDoorState(door.doors[i].hash, door.state, false, false)
            ApplyHoldOpen(door.doors[i].hash, door)
        end
    else
        DoorSystemSetDoorState(door.hash, door.state, false, false)
        ApplyHoldOpen(door.hash, door)
    end
end

CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local newNearby = {}
        for id, door in pairs(doors) do
            local dist
            
            if not door.trueCenter then
                local searchModel = door.doors[1].model
                local searchCoords = door.doors[1].coords
                local entity = GetClosestObjectOfType(searchCoords.x, searchCoords.y, searchCoords.z, 2.0, searchModel, false, false, false)
                
                if entity ~= 0 then
                    local min, max = GetModelDimensions(searchModel)
                    local p1 = GetOffsetFromEntityInWorldCoords(entity, min.x, min.y, min.z).xy
                    local p2 = GetOffsetFromEntityInWorldCoords(entity, min.x, min.y, max.z).xy
                    local p3 = GetOffsetFromEntityInWorldCoords(entity, min.x, max.y, max.z).xy
                    local p4 = GetOffsetFromEntityInWorldCoords(entity, min.x, max.y, min.z).xy
                    local p5 = GetOffsetFromEntityInWorldCoords(entity, max.x, min.y, min.z).xy
                    local p6 = GetOffsetFromEntityInWorldCoords(entity, max.x, min.y, max.z).xy
                    local p7 = GetOffsetFromEntityInWorldCoords(entity, max.x, max.y, max.z).xy
                    local p8 = GetOffsetFromEntityInWorldCoords(entity, max.x, max.y, min.z).xy

                    local centroidX = (p1.x + p2.x + p3.x + p4.x + p5.x + p6.x + p7.x + p8.x) / 8
                    local centroidY = (p1.y + p2.y + p3.y + p4.y + p5.y + p6.y + p7.y + p8.y) / 8
                    
                    door.trueCenter = vector3(centroidX, centroidY, searchCoords.z)
                end
            end

            if door.isDouble then
                local c1 = door.doors[1].coords
                local c2 = door.doors[2].coords
                local center = vector3(c1.x - (c1.x - c2.x)/2, c1.y - (c1.y - c2.y)/2, c1.z - (c1.z - c2.z)/2)
                door.center = center
                dist = #(pos - center)
            else
                local center = door.trueCenter or vector3(door.doors[1].coords.x, door.doors[1].coords.y, door.doors[1].coords.z)
                door.center = center
                dist = #(pos - center)
            end
            
            door.dist = dist
            if dist < Config.DrawDistance then
                table.insert(newNearby, door)
            end
        end
        nearbyDoors = newNearby
        Wait(500)
    end
end)

-- Lock icon: the real padlock artwork (mpsafecracking's lock_closed/
-- lock_open textures) drawn as a world-space billboard — no spawned entity,
-- no plain text, just the actual padlock graphic — gently breathing in
-- scale. Warm amber-gold while locked, green while unlocked, so both
-- states stay clearly distinguishable at a glance. The shape itself is
-- baked into the game's own texture, so only color/size are tunable here.
local LOCKED_COLOR = { 222, 150, 55 }
local UNLOCKED_COLOR = { 34, 197, 94 }

local function DrawDoorLockIcon(door)
    local center = door.center
    local locked = door.state == 1
    local color = locked and LOCKED_COLOR or UNLOCKED_COLOR
    local sprite = locked and "lock_closed" or "lock_open"
    local pulse = 0.038 + math.sin(GetGameTimer() / 350.0) * 0.003

    SetDrawOrigin(center.x, center.y, center.z + 1.0, 0)
    DrawSprite("mpsafecracking", sprite, 0, 0, pulse, pulse, 0, color[1], color[2], color[3], 230)
    ClearDrawOrigin()
end

CreateThread(function()
    RequestStreamedTextureDict("mpsafecracking", true)
    while not HasStreamedTextureDictLoaded("mpsafecracking") do Wait(0) end

    while true do
        local sleep = 500
        if #nearbyDoors > 0 then
            sleep = 0
            for _, door in ipairs(nearbyDoors) do
                if door.dist < Config.DrawDistance then
                    if door.dist < (door.range or Config.InteractDistance) and not door.hideIcon then
                        DrawDoorLockIcon(door)
                    end

                    if door.dist < (door.range or Config.InteractDistance) then
                        if IsControlJustPressed(0, 38) then -- E
                            AttemptToggleDoor(door)
                        end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

function AttemptToggleDoor(door)
    local function Toggle()
        TriggerServerEvent('rps_doorlock:server:ToggleState', door.id)
    end
    
    if GetResourceState('op-crime') == 'started' then
        exports.rps_lib:TriggerServerCallback('rps_doorlock:server:GetOpCrimeId', function(opCrimeId)
            if CanAccessDoor(door, opCrimeId) then
                Toggle()
            else
                exports.rps_lib:Notify("You don't have the keys for this door.", 'error')
            end
        end)
    else
        if CanAccessDoor(door, nil) then
            Toggle()
        else
            exports.rps_lib:Notify("You don't have the keys for this door.", 'error')
        end
    end
end

function GetDoorFromEntity(entity)
    local coords = GetEntityCoords(entity)
    local model = GetEntityModel(entity)
    for id, door in pairs(doors) do
        if door.isDouble then
            if (door.doors[1].model == model and #(vector3(door.doors[1].coords.x, door.doors[1].coords.y, door.doors[1].coords.z) - coords) < 1.0) or
               (door.doors[2].model == model and #(vector3(door.doors[2].coords.x, door.doors[2].coords.y, door.doors[2].coords.z) - coords) < 1.0) then
                return door
            end
        else
            if door.doors[1].model == model and #(vector3(door.doors[1].coords.x, door.doors[1].coords.y, door.doors[1].coords.z) - coords) < 1.0 then
                return door
            end
        end
    end
    return nil
end

doorTargetOptions = {
    options = {
        {
            name = "rps_doorlock_pick",
            onSelect = function(data)
                local entity = data.entity
                local door = GetDoorFromEntity(entity)
                if door and door.lockpick then
                    local ret = nil
                    local gameType = math.random(1, 5)
                    if gameType == 1 then
                        ret = exports[Config.MinigameResource]:StartLockpickGame(math.random(3, 5), 20, Config.MaxFailures, 30, 500)
                    elseif gameType == 2 then
                        ret = exports[Config.MinigameResource]:StartUntangleGame(math.random(9, 12), 60000)
                    elseif gameType == 3 then
                        ret = exports[Config.MinigameResource]:StartCodeCrackGame(90000, 4, 10)
                    elseif gameType == 4 then
                        ret = exports[Config.MinigameResource]:StartCircuitRhythm(5, nil, 350, 1000, math.random(5, 10), nil, 5, 5)
                    elseif gameType == 5 then
                        ret = exports[Config.MinigameResource]:StartPairsGame(math.random(4, 5), 90000, 0)
                    end
                    
                    local isSuccess = false
                    if type(ret) == 'table' then
                        isSuccess = ret.success
                    else
                        isSuccess = ret
                    end
                    
                    if isSuccess then
                        TriggerServerEvent('rps_doorlock:server:LockpickSuccess', door.id)
                    else
                        if math.random(1, 100) <= 60 then
                            TriggerServerEvent('rps_doorlock:server:RemoveLockpick')
                            exports.rps_lib:Notify("You failed to pick the lock and your lockpick broke!", 'error')
                        else
                            exports.rps_lib:Notify("You failed to pick the lock!", 'error')
                        end
                    end
                end
            end,
            icon = "fas fa-user-lock",
            label = "Pick Lock",
            -- rps_lib's target module has no native "item" gate field (that was
            -- ox_target/qb-target's own built-in behavior), so the lockpick
            -- requirement is folded into canInteract instead. Client-side
            -- HasItem is UI gating only — the server re-verifies + consumes it.
            canInteract = function(entity)
                local door = GetDoorFromEntity(entity)
                return door ~= nil and door.lockpick and door.state == 1 and exports.rps_lib:HasItem(Config.LockpickItem)
            end
        }
    },
    distance = Config.InteractDistance
}

function SetupDoorTargets()
    if targetAdded then return end
    
    local modelsToTarget = {}
    for _, door in pairs(doors) do
        if door.isDouble then
            modelsToTarget[door.doors[1].model] = true
            modelsToTarget[door.doors[2].model] = true
        else
            modelsToTarget[door.doors[1].model] = true
        end
    end
    
    local arr = {}
    for k, v in pairs(modelsToTarget) do
        table.insert(arr, k)
        targetModels[k] = true
    end
    
    if #arr > 0 then
        exports.rps_lib:AddModelTarget(arr, doorTargetOptions.options, doorTargetOptions.distance)
        targetAdded = true
    end
end

CreateThread(function()
    Wait(1000)
    TriggerServerEvent('rps_doorlock:server:RequestDoors')
    Wait(1000)
    SetupDoorTargets()
end)
