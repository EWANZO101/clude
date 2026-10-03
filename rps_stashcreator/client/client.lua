local stashes = {}
local capturing = false
local activeZoneIds = {}

local function CanAccessStash(stash)
    local PlayerData = exports.rps_lib:GetPlayerData()
    local identifier = PlayerData.identifier
    local jobName = PlayerData.job and PlayerData.job.name
    local jobGrade = PlayerData.job and PlayerData.job.grade.level

    -- are you real? prob not so lemme checl
    if stash.chars and #stash.chars > 0 then
        for _, char in ipairs(stash.chars) do
            if char.id == identifier then
                return true
            end
        end
    end

    -- idk bro i just work here
    if stash.jobs and #stash.jobs > 0 then
        for _, job in ipairs(stash.jobs) do
            if jobName and job.job == jobName and jobGrade >= tonumber(job.grade) then
                return true
            end
        end
    end

    if (#stash.chars == 0 and #stash.jobs == 0) then
        return true
    end

    return false
end

local function TryOpenStash(stash)
    if CanAccessStash(stash) then
        local stashId = "stash_"..stash.id
        -- rps_lib has no stash abstraction, so this talks to the
        -- server's actual inventory (tgiann-inventory) directly.
        exports['tgiann-inventory']:OpenInventory('stash', stashId, {
            maxweight = tonumber(stash.weight) * 1000,
            slots = tonumber(stash.slots)
        })
    else
        exports.rps_lib:Notify("You don't have the keys for this stash.", "error")
    end
end

local function ClearStashZones()
    for _, id in ipairs(activeZoneIds) do
        exports.rps_lib:RemoveZone(id)
    end
    activeZoneIds = {}
end

-- Only used when Config.InteractionMode == 'target' — registers one target
-- zone per access point via rps_lib (ox_target/qb-target/tgiann-target,
-- whichever it detects). Called whenever the stash list changes so zones
-- always match the current data.
local function RefreshStashZones()
    if Config.InteractionMode ~= 'target' then return end

    ClearStashZones()

    for _, stash in ipairs(stashes) do
        if stash.accessPoints then
            for i, ap in ipairs(stash.accessPoints) do
                local coords = vector3(ap.x, ap.y, ap.z)
                local radius = ap.radius or 1.5

                local zoneId = exports.rps_lib:AddBoxZone('rps_stash_'..stash.id..'_'..i, coords, 1.0, 1.0, 0.0, {
                    {
                        name = 'rps_stash_open_'..stash.id..'_'..i,
                        icon = Config.Target.icon,
                        label = Config.Target.label,
                        onSelect = function()
                            TryOpenStash(stash)
                        end
                    }
                }, radius)

                table.insert(activeZoneIds, zoneId)
            end
        end
    end
end

RegisterNetEvent('rps_stashecreator:client:SyncStashes', function(serverStashes)
    stashes = serverStashes
    RefreshStashZones()
end)

RegisterNetEvent('rps_stashecreator:client:OpenUI', function(serverStashes, jobsData)
    stashes = serverStashes
    RefreshStashZones()
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = 'openUI',
        stashes = stashes,
        jobs = jobsData
    })
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        ClearStashZones()
    end
end)

RegisterNUICallback('closeUI', function(data, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('createStash', function(data, cb)
    TriggerServerEvent('rps_stashecreator:server:CreateStash', data)
    cb('ok')
end)

RegisterNUICallback('saveStash', function(data, cb)
    TriggerServerEvent('rps_stashecreator:server:UpdateStash', data)
    cb('ok')
end)

RegisterNUICallback('deleteStash', function(data, cb)
    TriggerServerEvent('rps_stashecreator:server:DeleteStash', data.id)
    cb('ok')
end)

RegisterNUICallback('searchCharacters', function(data, cb)
    exports.rps_lib:TriggerServerCallback('rps_stashecreator:server:SearchCharacters', function(results)
        cb(results)
    end, data.query)
end)

local CAPTURE_MAX_DISTANCE = 50.0

-- Camera pitch/yaw (degrees) -> a normalized world-space forward vector.
local function RotationToDirection(rotation)
    local rad = { x = math.rad(rotation.x), y = math.rad(rotation.y), z = math.rad(rotation.z) }
    local cosX = math.abs(math.cos(rad.x))
    return vector3(
        -math.sin(rad.z) * cosX,
        math.cos(rad.z) * cosX,
        math.sin(rad.x)
    )
end

-- Laser raycast from the camera out to whatever it's pointed at (ground, wall,
-- prop, ...), so the player can aim the access point anywhere in view instead
-- of needing to physically stand on the spot.
local function GetAimHitCoords()
    local camCoord = GetGameplayCamCoord()
    local direction = RotationToDirection(GetGameplayCamRot(2))
    local destination = camCoord + direction * CAPTURE_MAX_DISTANCE

    local rayHandle = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, destination.x, destination.y, destination.z, -1, PlayerPedId(), 0)
    local _, hit, hitCoords = GetShapeTestResult(rayHandle)

    return camCoord, (hit == 1) and hitCoords or destination
end

RegisterNUICallback('startCapture', function(data, cb)
    capturing = true
    SetNuiFocus(false, false)

    CreateThread(function()
        while capturing do
            Wait(0)

            local camCoord, hitCoords = GetAimHitCoords()

            DrawLine(camCoord.x, camCoord.y, camCoord.z, hitCoords.x, hitCoords.y, hitCoords.z, 255, 60, 60, 180)
            DrawMarker(28, hitCoords.x, hitCoords.y, hitCoords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.15, 0.15, 0.15, 255, 60, 60, 200, false, false, 2, false, nil, nil, false)

            SetTextFont(4)
            SetTextProportional(1)
            SetTextScale(0.45, 0.45)
            SetTextColour(255, 255, 255, 255)
            SetTextDropShadow(0, 0, 0, 0, 255)
            SetTextEdge(1, 0, 0, 0, 255)
            SetTextDropShadow()
            SetTextOutline()
            SetTextEntry("STRING")
            AddTextComponentString("Aim the laser at the stash location.\nPress ~g~ENTER~w~ to place or ~r~ESC~w~ to cancel.")
            DrawText(0.5, 0.8)

            if IsControlJustPressed(0, 18) then -- ENTER
                capturing = false
                SetNuiFocus(true, true)
                SendNUIMessage({
                    type = 'coordsCaptured',
                    coords = { x = hitCoords.x, y = hitCoords.y, z = hitCoords.z }
                })
            elseif IsControlJustPressed(0, 322) then -- ESC
                capturing = false
                SetNuiFocus(true, true)
                SendNUIMessage({ type = 'cancelCapture' })
            end
        end
    end)
    cb('ok')
end)

-- Only used when Config.InteractionMode == '3dtext' — draws the floating
-- label + listens for E. In 'target' mode, RefreshStashZones above handles
-- interaction instead and this thread does nothing.
CreateThread(function()
    if Config.InteractionMode ~= '3dtext' then return end

    while true do
        local wait = 1000
        if not capturing and #stashes > 0 then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)

            for _, stash in ipairs(stashes) do
                if stash.accessPoints then
                    for _, ap in ipairs(stash.accessPoints) do
                        local apCoords = vector3(ap.x, ap.y, ap.z)
                        local dist = #(pos - apCoords)
                        local radius = ap.radius or 1.5

                        if dist < Config.Marker.drawDistance then
                            wait = 0
                            local inRange = dist < radius
                            local label = inRange and (stash.name .. '\n' .. Config.Marker.text) or stash.name

                            exports.rps_lib:DrawText3D(apCoords, label, {
                                fancy = true,
                                accentColor = { 198, 120, 255 },
                                maxDistance = Config.Marker.drawDistance,
                                fadeDistance = 3.0,
                                marker = inRange
                            })

                            if inRange and IsControlJustPressed(0, 38) then -- E
                                TryOpenStash(stash)
                            end
                        end
                    end
                end
            end
        end
        Wait(wait)
    end
end)
