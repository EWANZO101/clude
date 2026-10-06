-- OPS Network van: a base van dressed with branding, a roof light bar, rear beacons and a ladder on a roof rack.
-- Every client dresses any van flagged with the 'opsvan' state bag, so everyone sees the same thing.

local V = Config.Van or {}
local dressed = {}          -- veh -> { props, bar_l, bar_r, beacons = { off, on }, lightAt = {...} }
local myVan

local function load(model)
    local h = joaat(model)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    return h
end

local function attach(veh, bone, model, x, y, z, rx, ry, rz)
    local h = load(model)
    if not h then return nil end
    local p = GetEntityCoords(veh)
    local e = CreateObjectNoOffset(h, p.x, p.y, p.z + 5.0, false, false, false)
    SetEntityCollision(e, false, false)
    AttachEntityToEntity(e, veh, bone, x, y, z, rx or 0.0, ry or 0.0, rz or 0.0, false, false, false, false, 2, true)
    return e
end

--- find the van's surface: cast a ray at it from outside and return the hit as a vehicle offset
local function surface(veh, from, to)
    local a, b = GetOffsetFromEntityInWorldCoords(veh, from.x, from.y, from.z), GetOffsetFromEntityInWorldCoords(veh, to.x, to.y, to.z)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 2, 0, 7)
    local _, hit, at, _, ent = GetShapeTestResult(ray)
    if hit == 1 and ent == veh then return GetOffsetFromEntityGivenWorldCoords(veh, at.x, at.y, at.z) end
end

local function dress(veh)
    local mn, mx = GetModelDimensions(GetEntityModel(veh))
    local L, H = mx.y - mn.y, mx.z - mn.z
    local bone = GetEntityBoneIndexByName(veh, 'chassis')
    if bone == -1 then bone = 0 end
    local d = { props = {} }
    local function add(e) if e then d.props[#d.props + 1] = e end return e end
    local function roofAt(y)
        local s = surface(veh, vector3(0.0, y, mx.z + 1.0), vector3(0.0, y, mn.z))
        return s and s.z or (mx.z - 0.05)
    end
    -- roof: light bar over the cab, rack + ladder over the load space, beacons at the back corners
    local barY = mn.y + 0.68 * L
    local barZ = roofAt(barY)
    add(attach(veh, bone, 'opslabs_van_lightbar', 0.0, barY, barZ + 0.06))
    d.bar_l = add(attach(veh, bone, 'opslabs_van_lightbar_on_l', 0.0, barY, barZ + 0.06))
    d.bar_r = add(attach(veh, bone, 'opslabs_van_lightbar_on_r', 0.0, barY, barZ + 0.06))
    local rackY = mn.y + 0.36 * L
    local rackZ = roofAt(rackY)
    add(attach(veh, bone, 'opslabs_van_rack', 0.0, rackY, rackZ + 0.06))
    add(attach(veh, bone, 'opslabs_ladder_base', 0.25, rackY - 1.95, rackZ + 0.18, -90.0, 0.0, 0.0))
    d.beacons = {}
    local backY = mn.y + 0.18
    local backZ = roofAt(backY)
    for _, x in ipairs({ mn.x + 0.3, mx.x - 0.3 }) do
        add(attach(veh, bone, 'opslabs_van_beacon', x, backY, backZ))
        local on = add(attach(veh, bone, 'opslabs_van_beacon_on', x, backY, backZ))
        d.beacons[#d.beacons + 1] = on
    end
    -- branding on both sides and the back doors (placed on the body found by ray, not the mirrors)
    local sideY, sideZ = mn.y + 0.40 * L, mn.z + 0.55 * H
    local left = surface(veh, vector3(mn.x - 1.5, sideY, sideZ), vector3(0.0, sideY, sideZ))
    local right = surface(veh, vector3(mx.x + 1.5, sideY, sideZ), vector3(0.0, sideY, sideZ))
    if left then add(attach(veh, bone, 'opslabs_van_side', left.x - 0.012, sideY, sideZ, 0.0, 0.0, -90.0)) end
    if right then add(attach(veh, bone, 'opslabs_van_side', right.x + 0.012, sideY, sideZ, 0.0, 0.0, 90.0)) end
    local rearZ = mn.z + 0.5 * H
    local rear = surface(veh, vector3(0.0, mn.y - 1.5, rearZ), vector3(0.0, 0.0, rearZ))
    if rear then add(attach(veh, bone, 'opslabs_van_rear', 0.0, rear.y - 0.012, rearZ)) end
    d.lights = { vector3(-0.6, barY, barZ + 0.15), vector3(0.6, barY, barZ + 0.15), vector3(mn.x + 0.3, backY, backZ + 0.1), vector3(mx.x - 0.3, backY, backZ + 0.1) }
    d.rear = vector3(0.0, mn.y - 0.6, 0.0)
    dressed[veh] = d
end

local function undress(veh)
    local d = dressed[veh]
    if not d then return end
    for _, e in ipairs(d.props) do if DoesEntityExist(e) then DeleteEntity(e) end end
    dressed[veh] = nil
end

local function isVan(veh) return Entity(veh).state.opsvan == true end

CreateThread(function()
    while true do
        Wait(1000)
        local pos = GetEntityCoords(PlayerPedId())
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if not dressed[veh] and isVan(veh) and #(pos - GetEntityCoords(veh)) < 150.0 then dress(veh) end
        end
        for veh in pairs(dressed) do
            if not DoesEntityExist(veh) or #(pos - GetEntityCoords(veh)) > 180.0 then undress(veh) end
        end
    end
end)

-- beacons: alternate the two halves of the light bar and the rear pods, with real amber light
CreateThread(function()
    while true do
        local any = false
        local phase = math.floor(GetGameTimer() / 220) % 2 == 0
        for veh, d in pairs(dressed) do
            if DoesEntityExist(veh) then
                local on = Entity(veh).state.beacons == true
                if on then any = true end
                if d.bar_l then SetEntityVisible(d.bar_l, on and phase, false) end
                if d.bar_r then SetEntityVisible(d.bar_r, on and not phase, false) end
                for i, b in ipairs(d.beacons or {}) do SetEntityVisible(b, on and ((i % 2 == 1) == phase), false) end
                if on then
                    for i, p in ipairs(d.lights) do
                        if (i % 2 == 1) == phase then
                            local w = GetOffsetFromEntityInWorldCoords(veh, p.x, p.y, p.z)
                            DrawLightWithRange(w.x, w.y, w.z, 255, 150, 20, 9.0, 4.0)
                        end
                    end
                end
            end
        end
        Wait(any and 0 or 250)
    end
end)

RegisterCommand('opsvan_beacons', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not isVan(veh) or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local on = not (Entity(veh).state.beacons == true)
    Entity(veh).state:set('beacons', on, true)
    PlaySoundFrontend(-1, on and 'NAV_UP_DOWN' or 'NAV_LEFT_RIGHT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end, false)
RegisterKeyMapping('opsvan_beacons', 'OPS van: beacons on / off', 'keyboard', V.BeaconKey or 'K')

--- bring an OPS Network van (or send yours back)
function SpawnOpsVan()
    if myVan and DoesEntityExist(myVan) then
        if lib.alertDialog({ header = 'Send your van back?', content = 'Your OPS van will be returned to the depot.', centered = true, cancel = true }) == 'confirm' then
            undress(myVan) SetEntityAsMissionEntity(myVan, true, true) DeleteVehicle(myVan) myVan = nil
        end
        return
    end
    if not lib.callback.await('opslabs-towers:cable:can', false) then
        return lib.notify({ type = 'error', description = 'Only network engineers can take an OPS van' })
    end
    local h = load(V.Model or 'speedo')
    if not h then return lib.notify({ type = 'error', description = 'Van model not found' }) end
    local ped = PlayerPedId()
    local p = GetOffsetFromEntityInWorldCoords(ped, 0.0, 4.5, 0.0)
    local veh = CreateVehicle(h, p.x, p.y, p.z, GetEntityHeading(ped) + 90.0, true, false)
    SetVehicleOnGroundProperly(veh)
    SetVehicleCustomPrimaryColour(veh, V.Colour[1], V.Colour[2], V.Colour[3])
    SetVehicleCustomSecondaryColour(veh, V.Trim[1], V.Trim[2], V.Trim[3])
    SetVehicleNumberPlateText(veh, V.Plate or 'OPSNET')
    SetVehicleDirtLevel(veh, 0.0)
    SetVehicleHasBeenOwnedByPlayer(veh, true)
    Entity(veh).state:set('opsvan', true, true)
    Entity(veh).state:set('beacons', false, true)
    if (V.Spotlight or {}).Fitted ~= false then Entity(veh).state:set('spot', { on = false, s = 0.0, r = 0.0, p = 0.0, t = 0.0 }, true) end
    SetModelAsNoLongerNeeded(h)
    myVan = veh
    lib.notify({ type = 'success', description = ('OPS van ready · %s for the beacons · %s for the roof spotlight · [E] at the back for the stores'):format(V.BeaconKey or 'K', (V.Spotlight or {}).Key or 'L') })
end
RegisterCommand(V.Command or 'opsvan', function() SpawnOpsVan() end, false)

--- the van's stores (at the back doors)
local function storesMenu(veh)
    local A = CableActions or {}
    local options = {
        { title = 'Ladder', description = 'Telescopic 0.9 → 3.2 m, or a 6.9 m or 13 m extension ladder off the roof', icon = 'stairs', onSelect = function() if PlaceLadder then PlaceLadder() end end },
        { title = 'Cable box or drum', description = 'CAT6, fibre, spine feed or ULW drop', icon = 'box-open', onSelect = function() if A.placeBox then A.placeBox(function() end) end end },
        { title = 'Phone cable (copper)', description = 'Drop wire, internal CW1308 or 50-pair — run it and punch it down', icon = 'phone', iconColor = '#bf5af2', onSelect = function() if A.copper then A.copper(function() end) end end },
        { title = 'Road safety kit', description = 'Cones, barriers, signs, traffic lights, tape', icon = 'triangle-exclamation', iconColor = '#ff9f0a', onSelect = function() if OpenRoadworksMenu then OpenRoadworksMenu() end end },
    }
    if VanSpotStoresOption then options[#options + 1] = VanSpotStoresOption(veh) end
    if UniformMenu then
        table.insert(options, 1, { title = 'Uniform locker', description = 'Change into (or out of) OPS Network uniform', icon = 'user-tie', iconColor = '#0a84ff', onSelect = function() UniformMenu() end })
    end
    if ToolKitMenu then
        table.insert(options, 1, { title = 'Tool kit', description = 'Fibre tools (splicer, OTDR, VFL, power meter…), copper phone line tools (butt set, toner, line tester…) and electrical tools', icon = 'toolbox', iconColor = '#0a84ff', arrow = true, onSelect = function() ToolKitMenu() end })
    end
    lib.registerContext({ id = 'opsvan_stores', root = true, title = 'OPS van · stores', options = options })
    lib.showContext('opsvan_stores')
end

CreateThread(function()
    local shown = false
    while true do
        local ped = PlayerPedId()
        local near
        if not IsPedInAnyVehicle(ped, false) then
            local pos = GetEntityCoords(ped)
            for veh, d in pairs(dressed) do
                if DoesEntityExist(veh) then
                    local r = GetOffsetFromEntityInWorldCoords(veh, d.rear.x, d.rear.y, 0.0)
                    if #(vector2(pos.x, pos.y) - vector2(r.x, r.y)) < 1.4 and math.abs(pos.z - r.z) < 2.0 then near = veh break end
                end
            end
        end
        if near then
            if not shown then lib.showTextUI('[E] Van stores', { icon = 'toolbox' }) shown = true end
            if IsControlJustPressed(0, 38) then lib.hideTextUI() shown = false storesMenu(near) end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = false end
            Wait(400)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for veh in pairs(dressed) do undress(veh) end
end)
