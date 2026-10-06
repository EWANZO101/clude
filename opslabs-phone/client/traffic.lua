-- OPS Traffic (Config.Traffic): automatic accident / fire reports, the lead unit's 10-80 position, street names.

local CT = Config.Traffic or {}
if CT.Enabled == false then return end
local PREFIX = 'opslabs-phone:'

local function streetAt(x, y, z)
    local a, b = GetStreetNameAtCoord(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
    local s = GetStreetNameFromHashKey(a)
    if b and b ~= 0 then s = s .. ' / ' .. GetStreetNameFromHashKey(b) end
    local zone = GetLabelText(GetNameOfZone(x + 0.0, y + 0.0, (z or 0.0) + 0.0))
    if zone and zone ~= 'NULL' and zone ~= '' then s = s .. ', ' .. zone end
    return s
end

local function auto(kind, at)
    CreateThread(function()
        pcall(lib.callback.await, PREFIX .. 'trafficAuto', false, { kind = kind, x = at.x, y = at.y, z = at.z, street = streetAt(at.x, at.y, at.z) })
    end)
end

-- a hard crash: the vehicle loses a lot of speed in a moment while hitting something
if CT.AutoCrash ~= false then
    CreateThread(function()
        local last = 0.0
        while true do
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and IsThisModelACar(GetEntityModel(veh)) then
                local v = GetEntitySpeed(veh) * 3.6
                if last > 70.0 and last - v > 45.0 and HasEntityCollidedWithAnything(veh) then auto('accident', GetEntityCoords(veh)) end
                last = v
                Wait(150)
            else
                last = 0.0
                Wait(1000)
            end
        end
    end)
end

-- fires burning near the player
if CT.AutoFire ~= false then
    CreateThread(function()
        while true do
            Wait(5000)
            local p = GetEntityCoords(PlayerPedId())
            if GetNumberOfFiresInRange(p.x, p.y, p.z, 40.0) >= 3 then
                local ok, at = GetClosestFirePos(p.x, p.y, p.z)
                auto('fire', (ok and at) and at or p)
            end
        end
    end)
end

-- 10-80: while it runs, the lead unit's position goes to everyone's map
local pursuit = false
RegisterNUICallback('trafficPursuitTrack', function(data, cb)
    local on = data.on == true
    cb(true)
    if on == pursuit then return end
    pursuit = on
    if not on then return end
    CreateThread(function()
        while pursuit do
            Wait((CT.PursuitUpdate or 3) * 1000)
            if not pursuit then break end
            local p = GetEntityCoords(PlayerPedId())
            local ok, r = pcall(lib.callback.await, PREFIX .. 'trafficPursuit', false, { action = 'update', street = streetAt(p.x, p.y, p.z) })
            if ok and r and r.ended then pursuit = false end
        end
    end)
end)

RegisterNUICallback('trafficStreets', function(data, cb)
    local out = {}
    for i, p in ipairs(type(data.points) == 'table' and data.points or {}) do
        if i > 80 then break end
        out[i] = (tonumber(p.x) and tonumber(p.y)) and streetAt(tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0.0) or ''
    end
    cb(out)
end)

RegisterNUICallback('trafficHere', function(_, cb)
    local p = GetEntityCoords(PlayerPedId())
    cb({ street = streetAt(p.x, p.y, p.z), pursuit = pursuit })
end)
