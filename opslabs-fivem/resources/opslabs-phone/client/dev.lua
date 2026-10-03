-- Developer app helpers: blips for places added in-game, and teleport.

local placeBlips = {}

local function setPlaceBlips(list)
    for _, b in pairs(placeBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    placeBlips = {}
    for _, p in ipairs(type(list) == 'table' and list or {}) do
        local b = AddBlipForCoord(p.x + 0.0, p.y + 0.0, p.z + 0.0)
        SetBlipSprite(b, p.sprite or 1)
        SetBlipColour(b, p.color or 0)
        SetBlipScale(b, 0.8)
        SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(p.name)
        EndTextCommandSetBlipName(b)
        placeBlips[#placeBlips + 1] = b
    end
end

RegisterNetEvent('opslabs-phone:placeBlips', setPlaceBlips)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(2000)
    setPlaceBlips(lib.callback.await('opslabs-phone:getPlaceBlips', false))
end)

RegisterNetEvent('opslabs-phone:devTeleport', function(data)
    local ped = PlayerPedId()
    local entity = IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false) or ped
    local x, y, z
    if data.waypoint then
        local blip = GetFirstBlipInfoId(8)
        if not DoesBlipExist(blip) then
            lib.notify({ description = 'Set a waypoint first', type = 'error' })
            return
        end
        local c = GetBlipInfoIdCoord(blip)
        x, y, z = c.x, c.y, 150.0
        -- find the ground under the waypoint
        for height = 1000.0, 0.0, -25.0 do
            SetEntityCoordsNoOffset(entity, x, y, height, false, false, false)
            RequestCollisionAtCoord(x, y, height)
            Wait(20)
            local found, groundZ = GetGroundZFor_3dCoord(x, y, height + 0.0, false)
            if found then z = groundZ + 1.0 break end
        end
    else
        x, y, z = data.x + 0.0, data.y + 0.0, data.z + 0.0
    end
    DoScreenFadeOut(200)
    Wait(220)
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(entity, x, y, z, false, false, false)
    Wait(300)
    DoScreenFadeIn(300)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then setPlaceBlips({}) end
end)
