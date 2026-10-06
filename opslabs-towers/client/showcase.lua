-- OPS Showcase (client): surveys the ground for the builder (server/showcase.lua), map blips for every part of it,
-- /opsshowcase goto and where.

--- ground height at each spot: hop round the site (frozen, invisible) so the collision there is loaded, then back
lib.callback.register('opslabs-towers:showcase:survey', function(points)
    local ped = PlayerPedId()
    local start, startH = GetEntityCoords(ped), GetEntityHeading(ped)
    local out = {}
    -- cells of ~100 m so every spot is near where we stand when we probe it
    local cells, order = {}, {}
    for i, p in ipairs(points) do
        local k = math.floor(p.x / 100) .. ':' .. math.floor(p.y / 100)
        if not cells[k] then cells[k] = { x = 0, y = 0, n = 0, list = {} } order[#order + 1] = k end
        local c = cells[k]
        c.x, c.y, c.n = c.x + p.x, c.y + p.y, c.n + 1
        c.list[#c.list + 1] = i
    end
    DoScreenFadeOut(400) Wait(450)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    for _, k in ipairs(order) do
        local c = cells[k]
        local cx, cy = c.x / c.n, c.y / c.n
        SetEntityCoordsNoOffset(ped, cx, cy, start.z + 40.0, false, false, false)
        local t0 = GetGameTimer()
        repeat RequestCollisionAtCoord(cx, cy, start.z) Wait(50) until HasCollisionLoadedAroundEntity(ped) or GetGameTimer() - t0 > 4000
        Wait(300)
        for _, i in ipairs(c.list) do
            local p = points[i]
            local z
            for _ = 1, 25 do
                RequestCollisionAtCoord(p.x, p.y, start.z)
                local ok, gz = GetGroundZFor_3dCoord(p.x + 0.0, p.y + 0.0, 1000.0, false)
                if ok then z = gz break end
                Wait(20)
            end
            out[i] = z
        end
    end
    SetEntityCoordsNoOffset(ped, start.x, start.y, start.z, false, false, false)
    SetEntityHeading(ped, startH)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(500)
    return out
end)

RegisterNetEvent('opslabs-towers:showcase:goto', function(s)
    local ped = PlayerPedId()
    DoScreenFadeOut(400) Wait(450)
    SetEntityCoordsNoOffset(ped, s.x + 0.0, s.y + 0.0, 200.0, false, false, false)
    FreezeEntityPosition(ped, true)
    local z, t0 = nil, GetGameTimer()
    repeat
        RequestCollisionAtCoord(s.x + 0.0, s.y + 0.0, 100.0)
        local ok, gz = GetGroundZFor_3dCoord(s.x + 0.0, s.y + 0.0, 1000.0, false)
        if ok then z = gz end
        Wait(50)
    until z or GetGameTimer() - t0 > 8000
    SetEntityCoordsNoOffset(ped, s.x + 0.0, s.y + 0.0, (z or 100.0) + 1.0, false, false, false)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(500)
end)

RegisterNetEvent('opslabs-towers:showcase:where', function(zones)
    local o = {}
    for _, z in ipairs(zones or {}) do
        o[#o + 1] = { title = z.label, description = ('%.0f, %.0f · set a waypoint'):format(z.x, z.y), icon = 'location-dot', iconColor = '#0a84ff',
            onSelect = function() SetNewWaypoint(z.x + 0.0, z.y + 0.0) end }
    end
    lib.registerContext({ id = 'ops_showcase', title = 'OPS Showcase · where everything is', options = o })
    lib.showContext('ops_showcase')
end)

-- map blips for each part of the showcase
local blips = {}
local function refresh(v)
    for _, b in ipairs(blips) do RemoveBlip(b) end
    blips = {}
    for _, z in ipairs(v and v.zones or {}) do
        local b = AddBlipForCoord(z.x + 0.0, z.y + 0.0, 0.0)
        SetBlipSprite(b, z.sprite or 1) SetBlipColour(b, 3) SetBlipScale(b, 0.8) SetBlipAsShortRange(b, false)
        SetBlipCategory(b, 10)
        BeginTextCommandSetBlipName('STRING') AddTextComponentSubstringPlayerName('OPS Showcase · ' .. z.label) EndTextCommandSetBlipName(b)
        blips[#blips + 1] = b
    end
end
AddStateBagChangeHandler('opsShowcase', 'global', function(_, _, v) refresh(v) end)
CreateThread(function() Wait(3000) refresh(GlobalState.opsShowcase) end)

---------------------------------------------------------------------------
-- keep planes out of the showcase (Config.Showcase.ClearPlanes): any plane inside the area is deleted
---------------------------------------------------------------------------
local SC = Config.Showcase or {}
local function inArea(o, x, y, z)
    local A = SC.Area or { -280, -90, 360, 220 }
    local h = math.rad(o.h or 0)
    local dx, dy = x - o.x, y - o.y
    local lx, ly = dx * math.cos(h) + dy * math.sin(h), -dx * math.sin(h) + dy * math.cos(h)
    return lx >= A[1] and lx <= A[3] and ly >= A[2] and ly <= A[4] and z - (o.z or 0) < (SC.ClearHeight or 120.0)
end
local function areaBox(o)
    local A = SC.Area or { -280, -90, 360, 220 }
    local h = math.rad(o.h or 0)
    local xs, ys = {}, {}
    for _, p in ipairs({ { A[1], A[2] }, { A[3], A[2] }, { A[3], A[4] }, { A[1], A[4] } }) do
        xs[#xs + 1] = o.x + p[1] * math.cos(h) - p[2] * math.sin(h)
        ys[#ys + 1] = o.y + p[1] * math.sin(h) + p[2] * math.cos(h)
    end
    return math.min(table.unpack(xs)), math.min(table.unpack(ys)), math.max(table.unpack(xs)), math.max(table.unpack(ys))
end
CreateThread(function()
    if SC.ClearPlanes == false then return end
    local genOff = nil
    while true do
        local v = GlobalState.opsShowcase
        local o = v and v.origin
        if o then
            local me = GetEntityCoords(PlayerPedId())
            if #(vector2(me.x, me.y) - vector2(o.x, o.y)) < 1200.0 then
                -- parked / spawned planes from the airport's vehicle generators
                if genOff ~= o.x then
                    local x0, y0, x1, y1 = areaBox(o)
                    SetAllVehicleGeneratorsActiveInArea(x0, y0, (o.z or 0) - 20.0, x1, y1, (o.z or 0) + 200.0, false, false)
                    RemoveVehiclesFromGeneratorsInArea(x0, y0, (o.z or 0) - 20.0, x1, y1, (o.z or 0) + 200.0)
                    genOff = o.x
                end
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if (SC.ClearClasses or { [16] = true })[GetVehicleClass(veh)] then
                        local p = GetEntityCoords(veh)
                        if inArea(o, p.x, p.y, p.z) then
                            local driver = GetPedInVehicleSeat(veh, -1)
                            local player = driver ~= 0 and IsPedAPlayer(driver)
                            if not player or SC.ClearPlayerPlanes then
                                if player and driver == PlayerPedId() then
                                    TaskLeaveVehicle(driver, veh, 16)
                                    lib.notify({ type = 'error', description = 'No planes in the OPS Showcase area' })
                                    Wait(200)
                                end
                                if not player or driver == PlayerPedId() then
                                    NetworkRequestControlOfEntity(veh)
                                    local t = GetGameTimer()
                                    while NetworkGetEntityIsNetworked(veh) and not NetworkHasControlOfEntity(veh) and GetGameTimer() - t < 1000 do Wait(0) end
                                    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
                                        local ped = GetPedInVehicleSeat(veh, seat)
                                        if ped ~= 0 and not IsPedAPlayer(ped) then SetEntityAsMissionEntity(ped, true, true) DeletePed(ped) end
                                    end
                                    SetEntityAsMissionEntity(veh, true, true)
                                    DeleteVehicle(veh)
                                end
                            end
                        end
                    end
                end
            end
        end
        Wait(1000)
    end
end)
