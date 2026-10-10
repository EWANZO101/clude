-- Live location: reports our position while we share, and draws a moving blip
-- (plus optional auto-updating GPS route) for every live location shared with us.

local blips = {}       -- [shareId] = blip
local last = {}        -- [shareId] = latest payload
local following = nil  -- shareId whose position drives the GPS waypoint
local lastWaypoint = nil
local reporting = false

local function removeBlip(id)
    if blips[id] and DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
    blips[id] = nil
end

local function updateBlip(s)
    local blip = blips[s.id]
    if not blip or not DoesBlipExist(blip) then
        blip = AddBlipForCoord(s.x, s.y, s.z)
        SetBlipSprite(blip, Config.LiveLocation.BlipSprite)
        SetBlipColour(blip, Config.LiveLocation.BlipColour)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        SetBlipCategory(blip, 7)
        ShowHeadingIndicatorOnBlip(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(('Live: %s'):format(s.name or s.number))
        EndTextCommandSetBlipName(blip)
        blips[s.id] = blip
    else
        SetBlipCoords(blip, s.x, s.y, s.z)
    end
    SetBlipRotation(blip, math.floor(s.h or 0.0))
end

local function followTo(s)
    if not s or not s.x then return end
    if lastWaypoint and #(vec2(s.x, s.y) - lastWaypoint) < 20.0 then return end
    SetNewWaypoint(s.x + 0.0, s.y + 0.0)
    lastWaypoint = vec2(s.x, s.y)
end

local function withDistance(s)
    if s.x then
        local me = GetEntityCoords(PlayerPedId())
        s.dist = #(me - vec3(s.x, s.y, s.z))
    end
    return s
end

RegisterNetEvent('opslabs-phone:liveLocation', function(s)
    if type(s) ~= 'table' or not s.id or not s.x then return end
    last[s.id] = s
    updateBlip(s)
    if following == s.id then followTo(s) end
    SendNUIMessage({ action = 'liveLocation', data = withDistance(s) })
end)

RegisterNetEvent('opslabs-phone:liveLocationEnded', function(d)
    if type(d) ~= 'table' or not d.id then return end
    removeBlip(d.id)
    last[d.id] = nil
    if following == d.id then
        following = nil
        lastWaypoint = nil
        lib.notify({ description = 'Live location sharing ended', type = 'inform' })
    end
    SendNUIMessage({ action = 'liveLocationEnded', data = { id = d.id } })
end)

-- server tells us whether we currently have outgoing shares
RegisterNetEvent('opslabs-phone:liveReporting', function(on)
    if on and not reporting then
        reporting = true
        CreateThread(function()
            while reporting do
                local ped = PlayerPedId()
                local c = GetEntityCoords(ped)
                TriggerServerEvent('opslabs-phone:livePos', c.x, c.y, c.z, GetEntityHeading(ped))
                Wait(Config.LiveLocation.Interval)
            end
        end)
    elseif not on then
        reporting = false
    end
    SendNUIMessage({ action = 'liveReporting', data = { on = on == true } })
end)

-- UI: follow a live location with the GPS (id = nil to stop)
RegisterNUICallback('liveFollow', function(body, cb)
    local id = tonumber(body.id)
    following = id
    lastWaypoint = nil
    if id and last[id] then
        followTo(last[id])
        lib.notify({ description = ('GPS following %s'):format(last[id].name or last[id].number), type = 'success' })
    elseif not id then
        lib.notify({ description = 'Stopped following', type = 'inform' })
    end
    cb({ following = following })
end)

-- UI: briefly flash the blip on the map
RegisterNUICallback('liveFlash', function(body, cb)
    local blip = blips[tonumber(body.id)]
    if blip and DoesBlipExist(blip) then
        SetBlipFlashes(blip, true)
        SetTimeout(5000, function() if DoesBlipExist(blip) then SetBlipFlashes(blip, false) end end)
    end
    cb(true)
end)

-- UI: distances for the current shares (refreshes "x mi away")
RegisterNUICallback('liveDistances', function(_, cb)
    local out = {}
    for id, s in pairs(last) do
        withDistance(s)
        out[tostring(id)] = s.dist
    end
    cb(out)
end)

local function clearAll()
    for id in pairs(blips) do removeBlip(id) end
    last = {}
    following = nil
    reporting = false
end

FW.OnPlayerUnloaded(clearAll)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)
