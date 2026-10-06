-- OPS Work: the on-site part of a job, step by step with each step's animation (server/training.lua BizWorkPlan)
local function animOf(key) return ((Config.Work or {}).Anims or {})[key] end
local function stepBar(label, secs, key)
    local a = animOf(key) or { scenario = 'WORLD_HUMAN_CLIPBOARD' }
    local anim = a.scenario and { scenario = a.scenario } or { dict = a.dict, clip = a.clip, flag = 49 }
    return lib.progressBar({ duration = math.max(2, secs) * 1000, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true }, anim = anim })
end
OpsStepBar = stepBar
RegisterNetEvent('opslabs-phone:opsWorkAnim', function(d)
    d = d or {}
    if type(d.plan) == 'table' and #d.plan > 0 then
        for i, s in ipairs(d.plan) do
            if not stepBar(('%d/%d · %s'):format(i, #d.plan, s.title or 'Working'), s.secs or 5, s.anim) then
                lib.notify({ type = 'warning', description = 'Stopped — press Start work again to carry on' }) return
            end
        end
    else
        if not stepBar((d.label) or 'Working', math.max(3, tonumber(d.secs) or 30), 'clipboard') then return end
    end
    lib.notify({ type = 'success', description = 'Work done — complete the job in OPS Work' })
end)

-- accidents when safety controls were skipped (server/training.lua opsRiskAssess)
RegisterNetEvent('opslabs-phone:opsIncident', function(d)
    local ped = PlayerPedId()
    local kind = d and d.kind or 'injury'
    if kind == 'fall' then
        SetPedToRagdoll(ped, 3500, 3500, 0, false, false, false)
        ApplyDamageToPed(ped, 25, false)
        lib.notify({ type = 'error', title = 'You fell', description = 'No harness / ladder control — logged as a safety incident' })
    elseif kind == 'shock' then
        ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.4)
        SetPedToRagdoll(ped, 2000, 2000, 0, false, false, false)
        ApplyDamageToPed(ped, 30, false)
        lib.notify({ type = 'error', title = 'Electric shock', description = 'Not isolated / no insulated gloves — logged as a safety incident' })
    else
        ApplyDamageToPed(ped, 10, false)
        lib.notify({ type = 'error', title = 'Injury', description = 'Skipped safety controls — logged as a safety incident' })
    end
end)

-- the job assistant from OPS Work: play one step's animation, GPS to the depot / training centre / job
RegisterNUICallback('opsDoStep', function(b, cb)
    cb(true)
    if b and b.title then stepBar(b.title, tonumber(b.secs) or 6, b.anim) end
end)
RegisterNUICallback('opsGps', function(b, cb)
    if b and b.x and b.y then SetNewWaypoint(b.x + 0.0, b.y + 0.0) end
    cb(true)
end)

-- OPS Work: real addresses for job locations (street, crossing, district) + how far / which way from you
local COMPASS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
local function addressOf(x, y, z)
    x, y, z = x + 0.0, y + 0.0, (z or 30.0) + 0.0
    local s1, s2 = GetStreetNameAtCoord(x, y, z)
    local street = s1 ~= 0 and GetStreetNameFromHashKey(s1) or nil
    local cross = s2 ~= 0 and GetStreetNameFromHashKey(s2) or nil
    local zone = GetLabelText(GetNameOfZone(x, y, z))
    if zone == 'NULL' then zone = nil end
    local p = GetEntityCoords(PlayerPedId())
    local dx, dy = x - p.x, y - p.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local ang = (math.deg(math.atan(dx, dy)) + 360) % 360           -- 0 = north
    return { street = street, cross = (cross and cross ~= street) and cross or nil, zone = zone, dist = math.floor(dist + 0.5),
        dir = COMPASS[math.floor((ang + 22.5) / 45) % 8 + 1] }
end
RegisterNUICallback('opsAddresses', function(body, cb)
    local out = {}
    for i, p in ipairs(type(body) == 'table' and body.points or {}) do
        if p and p.x and p.y then out[i] = addressOf(p.x, p.y, p.z) else out[i] = false end
    end
    cb(out)
end)

-- OPS Secure View (phone): CCTV systems you can watch remotely — the viewer itself lives in opslabs-towers
local function towersUp() return GetResourceState('opslabs-towers') == 'started' end
RegisterNUICallback('cctvList', function(_, cb)
    if not towersUp() then return cb({ offline = true }) end
    cb({ systems = lib.callback.await('opslabs-towers:cctv:mine', false) or {} })
end)
RegisterNUICallback('cctvSystem', function(body, cb)
    if not towersUp() then return cb({ offline = true }) end
    cb(lib.callback.await('opslabs-towers:cctv:watch', false, body and body.id, true, true) or {})   -- peek: details only
end)
RegisterNUICallback('cctvEvents', function(body, cb)
    if not towersUp() then return cb({}) end
    cb(lib.callback.await('opslabs-towers:cctv:events', false, body and body.id, body and body.kind) or {})
end)
RegisterNUICallback('cctvWatch', function(body, cb)
    cb(true)
    if not towersUp() or not body then return end
    ClosePhone()
    Wait(250)
    TriggerEvent('opslabs-towers:cctv:remote', body.id, body.cam)
end)

-- OPS Network broadband (customers + engineers) — the ISP engine lives in opslabs-towers (server/opsisp.lua)
local function T(name, ...) if not towersUp() then return { offline = true } end return lib.callback.await('opslabs-towers:isp:' .. name, false, ...) end
RegisterNUICallback('ispPackages', function(_, cb) cb(T('packages') or {}) end)
RegisterNUICallback('ispMine', function(_, cb) cb(T('mine') or {}) end)
RegisterNUICallback('ispOrder', function(b, cb) cb(T('order', b and b.package, b and b.address) or {}) end)
RegisterNUICallback('ispSpeedtest', function(_, cb) cb(T('speedtest') or {}) end)
RegisterNUICallback('ispPay', function(_, cb) cb(T('pay') or {}) end)
RegisterNUICallback('ispTicket', function(b, cb) cb(T('ticket', b and b.service, b and b.subject, b and b.text) or {}) end)
RegisterNUICallback('ispLookup', function(_, cb) cb(T('lookup') or {}) end)

---------------------------------------------------------------------------
-- company vans (OPS Work → My van & tools; allocated on OPS Hub → company → Fleet)
---------------------------------------------------------------------------
local van = nil                 -- { ent, id, dist, last }

RegisterNUICallback('opsVanOut', function(b, cb)
    if van and DoesEntityExist(van.ent) then return cb({ error = 'Your van is already out' }) end
    local r = lib.callback.await('opslabs-phone:opsVehicleOut', false, { id = b and b.id })
    if not r or not r.ok then return cb(r or { error = 'Failed' }) end
    local hash = joaat(r.model)
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
        lib.callback.await('opslabs-phone:opsVehicleIn', false, { km = 0 })
        return cb({ error = 'That vehicle model isn’t on this server' })
    end
    RequestModel(hash)
    local t = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t < 5000 do Wait(0) end
    local p = GetEntityCoords(PlayerPedId())
    local found, node, heading = GetClosestVehicleNodeWithHeading(p.x, p.y, p.z, 1, 3.0, 0)
    if not found or #(node - p) > 60.0 then node, heading = p + GetEntityForwardVector(PlayerPedId()) * 4.0, GetEntityHeading(PlayerPedId()) end
    local ent = CreateVehicle(hash, node.x, node.y, node.z, heading, true, false)
    SetModelAsNoLongerNeeded(hash)
    SetVehicleNumberPlateText(ent, r.plate)
    SetVehicleOnGroundProperly(ent)
    SetVehicleDirtLevel(ent, 0.0)
    SetEntityAsMissionEntity(ent, true, true)
    SetVehicleHasBeenOwnedByPlayer(ent, true)
    local blip = AddBlipForEntity(ent)
    SetBlipSprite(blip, 67) SetBlipColour(blip, 3)
    BeginTextCommandSetBlipName('STRING') AddTextComponentSubstringPlayerName('Company van ' .. r.plate) EndTextCommandSetBlipName(blip)
    van = { ent = ent, dist = 0.0, last = GetEntityCoords(ent) }
    CreateThread(function()
        while van and van.ent == ent and DoesEntityExist(ent) do
            local c = GetEntityCoords(ent)
            local d = #(c - van.last)
            if d < 200.0 then van.dist = van.dist + d end
            van.last = c
            Wait(2000)
        end
    end)
    cb({ ok = true, plate = r.plate })
end)

RegisterNUICallback('opsVanIn', function(_, cb)
    if not van then
        local r = lib.callback.await('opslabs-phone:opsVehicleIn', false, { km = 0 })
        return cb(r or { error = 'No van out' })
    end
    if DoesEntityExist(van.ent) then
        if #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(van.ent)) > 20.0 then return cb({ error = 'Stand next to the van to hand it back' }) end
        if GetPedInVehicleSeat(van.ent, -1) == PlayerPedId() then TaskLeaveVehicle(PlayerPedId(), van.ent, 0) Wait(1500) end
        DeleteEntity(van.ent)
    end
    local km = math.floor(van.dist / 1000 + 0.5)
    van = nil
    cb(lib.callback.await('opslabs-phone:opsVehicleIn', false, { km = km }) or { ok = true, km = km })
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and van and DoesEntityExist(van.ent) then DeleteEntity(van.ent) end
end)
