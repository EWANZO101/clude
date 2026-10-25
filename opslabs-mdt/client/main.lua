-- The physical laptop: install it in any vehicle (dash-mounted, cosmetic-only prop - same idiom as
-- opslabs-towers' fixtures, nothing networked, every nearby client just renders its own copy from the
-- server's install table), take it back out, and open OPS MDT once it's in.

local installed = {}   -- [plate] = { model }
local props = {}       -- [plate] = entity (this client's own local copy)
local nuiOpen = false
local mountOverrides = {}   -- [tostring(modelHash)] = {x,y,z,rx,ry,rz} - /mdtmount calibrated, server/mounts.lua

local function trimPlate(p) return (p or ''):gsub('%s+$', ''):gsub('^%s+', '') end
local function platedVehicle(v) return v and v ~= 0 and trimPlate(GetVehicleNumberPlateText(v)) or nil end

--- a calibrated override (any player, any vehicle of this model) beats Config.Mounts (keyed by model name)
--- beats Config.DefaultMount
local function mountFor(vehicleModelHash)
    local o = mountOverrides[tostring(vehicleModelHash)]
    if o then return o end
    for name, cfg in pairs(Config.Mounts or {}) do
        if GetHashKey(name) == vehicleModelHash then return cfg end
    end
    return Config.DefaultMount
end

RegisterNetEvent('opslabs-mdt:mounts', function(all)
    mountOverrides = all or {}
    local n = 0 for _ in pairs(mountOverrides) do n = n + 1 end
    Dbg('mounts updated: %d calibrated model(s)', n)
end)
CreateThread(function()
    mountOverrides = lib.callback.await('opslabs-mdt:mounts', false) or {}
    local n = 0 for _ in pairs(mountOverrides) do n = n + 1 end
    Dbg('mounts loaded on start: %d calibrated model(s)', n)
end)

local function spawnProp(vehicle, plate)
    local existing = props[plate]
    if existing and DoesEntityExist(existing) then
        -- the entity existing isn't enough: if the actual vehicle was ever deleted and recreated with the
        -- same plate while still in range (garage respawn, a cleanup script, anything outside this resource),
        -- the old prop is left behind detached and floating, and nothing would ever notice or fix it otherwise
        if GetEntityAttachedTo(existing) == vehicle then return end
        Dbg('spawnProp: plate=%s had a stale prop (attachedTo=%s, current vehicle=%s) - recreating', plate, GetEntityAttachedTo(existing), vehicle)
        DeleteEntity(existing)
        props[plate] = nil
    end
    local model = GetHashKey(Config.Prop)
    Dbg('spawnProp: plate=%s vehicleModel=%s requesting prop model=%s', plate, GetEntityModel(vehicle), model)
    lib.requestModel(model, 3000)
    if not HasModelLoaded(model) then Dbg('spawnProp: %s FAILED TO LOAD (bad model name? opslabs-props not started?)', Config.Prop) end
    local vp = GetEntityCoords(vehicle)
    -- matches opslabs-towers/client/van.lua's attach() exactly, which DOES work in this same codebase:
    -- spawn well above the vehicle (not overlapping its own collision mesh - confirmed the real cause, not the
    -- dynamic flag, which towers also leaves false) and disable collision BEFORE attaching, not after.
    local e = CreateObjectNoOffset(model, vp.x, vp.y, vp.z + 5.0, false, false, false)
    if not DoesEntityExist(e) then Dbg('spawnProp: CreateObjectNoOffset returned no entity for plate=%s', plate) return end
    SetEntityCollision(e, false, false)
    local mnt = mountFor(GetEntityModel(vehicle))
    Dbg('spawnProp: plate=%s attaching with mount x=%.3f y=%.3f z=%.3f rz=%.1f (vehicle entity=%s)', plate, mnt.x, mnt.y, mnt.z, mnt.rz, vehicle)
    AttachEntityToEntity(e, vehicle, 0, mnt.x, mnt.y, mnt.z, mnt.rx, mnt.ry, mnt.rz, false, false, false, false, 2, true)
    FreezeEntityPosition(e, true)
    props[plate] = e
    Wait(0)   -- give the attachment a frame to actually register before checking/logging it
    Dbg('spawnProp: plate=%s done, attachedTo=%s isAttached=%s', plate, GetEntityAttachedTo(e), IsEntityAttachedToEntity(e, vehicle))
end

local function despawnProp(plate)
    Dbg('despawnProp: plate=%s', plate)
    local e = props[plate]
    if e and DoesEntityExist(e) then DeleteEntity(e) end
    props[plate] = nil
end

RegisterNetEvent('opslabs-mdt:installs', function(all)
    installed = all or {}
    local n = 0 for _ in pairs(installed) do n = n + 1 end
    Dbg('installs updated: %d vehicle(s) have an MDT installed', n)
    for plate in pairs(props) do
        if not installed[plate] then despawnProp(plate) end
    end
end)

CreateThread(function()
    installed = lib.callback.await('opslabs-mdt:installs', false) or {}
    local n = 0 for _ in pairs(installed) do n = n + 1 end
    Dbg('installs loaded on start: %d vehicle(s) have an MDT installed', n)
end)

-- spawn/despawn the prop as the player gets near an installed car, same proximity idiom as towers' fixtures
CreateThread(function()
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local near = {}
        for _, v in ipairs(GetGamePool('CVehicle')) do
            if #(pos - GetEntityCoords(v)) < 20.0 then
                local plate = platedVehicle(v)
                if plate and installed[plate] then near[plate] = v end
            end
        end
        for plate, v in pairs(near) do spawnProp(v, plate) end
        for plate in pairs(props) do if not near[plate] then despawnProp(plate) end end
    end
end)

-- install / remove ---------------------------------------------------------------------------------------

local function nearestVehicle(dist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(pos - GetEntityCoords(v))
        if d < (bd or dist) then best, bd = v, d end
    end
    return best
end

RegisterNetEvent('opslabs-mdt:tryInstall', function()
    Dbg('tryInstall: item used, looking for a vehicle within %.1fm', Config.InstallDistance or 2.0)
    local v = nearestVehicle(Config.InstallDistance or 2.0)
    if not v then Dbg('tryInstall: no vehicle in range') return lib.notify({ description = 'No vehicle close enough.', type = 'error' }) end
    local plate = platedVehicle(v)
    Dbg('tryInstall: nearest vehicle entity=%s plate=%s', v, plate)
    if not plate then return end
    if installed[plate] then Dbg('tryInstall: plate=%s already installed client-side', plate) return lib.notify({ description = 'This vehicle already has an MDT installed.', type = 'error' }) end
    local ok = lib.callback.await('opslabs-mdt:install', false, NetworkGetNetworkIdFromEntity(v))
    Dbg('tryInstall: server replied %s', json.encode(ok or {}))
    if ok and ok.ok then lib.notify({ description = 'MDT installed.', type = 'success' })
    else lib.notify({ description = (ok and ok.error) or 'Could not install the MDT.', type = 'error' }) end
end)

local function tryRemove()
    local v = nearestVehicle(Config.InstallDistance or 2.0)
    local plate = v and platedVehicle(v)
    Dbg('tryRemove: nearest vehicle entity=%s plate=%s installedClientSide=%s', v, plate, plate and installed[plate] ~= nil)
    if not plate or not installed[plate] then return lib.notify({ description = 'No MDT installed here.', type = 'error' }) end
    local ok = lib.callback.await('opslabs-mdt:remove', false, NetworkGetNetworkIdFromEntity(v))
    Dbg('tryRemove: server replied %s', json.encode(ok or {}))
    if ok and ok.ok then lib.notify({ description = 'MDT removed.', type = 'success' })
    else lib.notify({ description = (ok and ok.error) or 'Could not remove the MDT.', type = 'error' }) end
end
RegisterCommand('mdtremove', tryRemove, false)

-- mount calibration -----------------------------------------------------------------------------------------
-- A real orbit camera, same idea as the reference repo's /mdtmount: it always looks straight at the laptop,
-- and the mouse flies you freely around it (zoom with the scroll wheel) while separate keys nudge the prop's
-- actual offset - so you're looking right at what you're adjusting from any angle, not guessing from the seat.

local editing = false

--- nearest installed laptop's plate + its own live prop entity (not a separate preview object - this nudges
--- the exact thing sitting on the dash, attached to its vehicle, so you see it move for real as you adjust it)
local function nearestMounted()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for plate, e in pairs(props) do
        if DoesEntityExist(e) then
            local d = #(pos - GetEntityCoords(e))
            if d < (bd or 3.0) then best, bd = plate, d end
        end
    end
    return best
end

local function drawHud(mnt, fine)
    SetTextFont(4) SetTextScale(0.34, 0.34) SetTextColour(255, 255, 255, 220) SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(('MDT mount  x %.3f  y %.3f  z %.3f  rz %.1f%s'):format(mnt.x, mnt.y, mnt.z, mnt.rz, fine and '  [fine]' or ''))
    EndTextCommandDisplayText(0.5, 0.055)
end

RegisterCommand('mdtmount', function()
    if editing then Dbg('mdtmount: already editing, ignored') return end
    local plate = nearestMounted()
    Dbg('mdtmount: nearest mounted prop plate=%s (nil = nothing within 3m)', plate)
    local prop = plate and props[plate]
    if not prop then return lib.notify({ description = 'No installed MDT close enough to edit.', type = 'error' }) end
    local vehicle = GetEntityAttachedTo(prop)
    Dbg('mdtmount: prop entity=%s attachedTo vehicle=%s', prop, vehicle)
    if not vehicle or vehicle == 0 then Dbg('mdtmount: prop is not attached to anything - aborting') return end
    local model = GetEntityModel(vehicle)
    local mnt = { }
    for k, v in pairs(mountFor(model)) do mnt[k] = v end   -- start from whatever's already applied, don't reset it
    Dbg('mdtmount: starting edit for model=%s at x=%.3f y=%.3f z=%.3f rz=%.1f', model, mnt.x, mnt.y, mnt.z, mnt.rz)

    editing = true
    local orbit = { yaw = 0.0, pitch = -15.0, dist = 1.2 }
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 50.0, false, 0)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 400, true, true)
    lib.notify({ description = 'Mouse: look around it. Scroll: zoom. WASD moves it, ↑/↓ height, ←/→ rotate, hold Ctrl to fine-step. Enter saves, Backspace cancels.', type = 'inform', duration = 8000 })

    CreateThread(function()
        while editing do
            Wait(0)
            for _, c in ipairs({ 1, 2, 14, 15, 21, 32, 33, 34, 35, 172, 173, 174, 175, 18, 177 }) do DisableControlAction(0, c, true) end

            -- orbit camera: mouse rotates it around the prop, wheel zooms, always pointed at the prop
            local tpos = GetEntityCoords(prop)
            orbit.yaw = orbit.yaw - GetDisabledControlNormal(0, 1) * 180.0
            orbit.pitch = math.max(-80.0, math.min(80.0, orbit.pitch - GetDisabledControlNormal(0, 2) * 180.0))
            if IsDisabledControlJustPressed(0, 14) then orbit.dist = math.max(0.3, orbit.dist - 0.15) end   -- wheel up
            if IsDisabledControlJustPressed(0, 15) then orbit.dist = math.min(4.0, orbit.dist + 0.15) end   -- wheel down
            local ry, rp = math.rad(orbit.yaw), math.rad(orbit.pitch)
            local camPos = tpos + vector3(math.sin(ry) * math.cos(rp), -math.cos(ry) * math.cos(rp), math.sin(rp)) * orbit.dist
            SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
            PointCamAtCoord(cam, tpos.x, tpos.y, tpos.z)

            -- nudge the prop; Ctrl held = fine step
            local fine = IsDisabledControlPressed(0, 21)
            local step = fine and 0.002 or 0.01
            local moved = false
            if IsDisabledControlPressed(0, 32) then mnt.y = mnt.y + step moved = true end      -- W
            if IsDisabledControlPressed(0, 33) then mnt.y = mnt.y - step moved = true end      -- S
            if IsDisabledControlPressed(0, 34) then mnt.x = mnt.x - step moved = true end      -- A
            if IsDisabledControlPressed(0, 35) then mnt.x = mnt.x + step moved = true end      -- D
            if IsDisabledControlPressed(0, 172) then mnt.z = mnt.z + step moved = true end     -- arrow up
            if IsDisabledControlPressed(0, 173) then mnt.z = mnt.z - step moved = true end     -- arrow down
            if IsDisabledControlPressed(0, 174) then mnt.rz = mnt.rz - (fine and 0.2 or 1.0) moved = true end  -- arrow left
            if IsDisabledControlPressed(0, 175) then mnt.rz = mnt.rz + (fine and 0.2 or 1.0) moved = true end  -- arrow right
            if moved and DoesEntityExist(prop) then
                AttachEntityToEntity(prop, vehicle, 0, mnt.x, mnt.y, mnt.z, mnt.rx, mnt.ry, mnt.rz, false, false, false, false, 2, true)
            end
            drawHud(mnt, fine)

            if IsDisabledControlJustPressed(0, 18) then   -- Enter: save
                editing = false
                Dbg('mdtmount: saving model=%s x=%.3f y=%.3f z=%.3f rz=%.1f', model, mnt.x, mnt.y, mnt.z, mnt.rz)
                local r = lib.callback.await('opslabs-mdt:saveMount', false, { model = tostring(model), x = mnt.x, y = mnt.y, z = mnt.z, rx = mnt.rx, ry = mnt.ry, rz = mnt.rz })
                Dbg('mdtmount: save result %s', json.encode(r or {}))
                if r and r.ok then lib.notify({ description = 'Mount saved for this vehicle model.', type = 'success' })
                else lib.notify({ description = (r and r.error) or 'Could not save the mount.', type = 'error' }) end
            elseif IsDisabledControlJustPressed(0, 177) then   -- Backspace: cancel, put it back where it was
                editing = false
                Dbg('mdtmount: cancelled, reverting to previous mount')
                local orig = mountFor(model)
                if DoesEntityExist(prop) then AttachEntityToEntity(prop, vehicle, 0, orig.x, orig.y, orig.z, orig.rx, orig.ry, orig.rz, false, false, false, false, 2, true) end
                lib.notify({ description = 'Cancelled.', type = 'inform' })
            end
        end
        RenderScriptCams(false, true, 400, true, true)
        SetTimeout(450, function() if DoesCamExist(cam) then DestroyCam(cam, false) end end)
    end)
end, false)

-- open ----------------------------------------------------------------------------------------------------

local function nearestInstalled()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for plate, e in pairs(props) do
        if DoesEntityExist(e) then
            local d = #(pos - GetEntityCoords(e))
            if d < (bd or (Config.UseDistance or 1.5)) then best, bd = plate, d end
        end
    end
    return best
end

-- Camera moves to look at the dash while the MDT is open, instead of just popping a UI over whatever the
-- player happened to be looking at. Attached directly to the laptop prop (not computed from the player's
-- position each frame) so it rides along correctly if the vehicle moves while the MDT is open - a world-space
-- camera would drift out of alignment the moment the car so much as rolls forward. The ped itself isn't
-- frozen: a passenger can use it while the driver keeps driving.
local mdtCam = nil

local function startCam(prop)
    local off = Config.ViewCam or { x = 0.0, y = -0.4, z = 0.3 }
    local target = Config.ViewCamTarget or { x = 0.0, y = 0.05, z = 0.05 }
    mdtCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    SetCamFov(mdtCam, 45.0)
    SetCamNearClip(mdtCam, 0.05)   -- avoid clipping into the dash/seats at this close a range
    AttachCamToEntity(mdtCam, prop, off.x, off.y, off.z, true)
    PointCamAtEntity(mdtCam, prop, target.x, target.y, target.z, true)
    SetCamActive(mdtCam, true)
    RenderScriptCams(true, true, 600, true, true)
end

local function stopCam()
    if not mdtCam then return end
    local cam = mdtCam
    mdtCam = nil
    RenderScriptCams(false, true, 600, true, true)
    SetTimeout(650, function() if DoesCamExist(cam) then DestroyCam(cam, false) end end)
end

function CloseMdt()
    if not nuiOpen then return end
    nuiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    stopCam()
end
RegisterNUICallback('close', function(_, cb) cb(1) CloseMdt() end)
RegisterNUICallback('call', function(body, cb)
    local r = lib.callback.await('opslabs-mdt:' .. tostring(body.name), false, body.data)
    cb(r)
end)

-- Live dashcam toggle: opslabs-bodycam's full-screen capture, published live to Xon Sight /live rather
-- than recorded as evidence. A direct export call, not routed through the generic 'call' dispatcher
-- above (lib.callback.await to opslabs-mdt's own server) - both resources run client-side on the same
-- player, so there's nothing for a server round trip to add here; opslabs-bodycam's own client/main.lua
-- already does its own server request internally (mirrors how its Start/Stop exports work for recording).
-- Soft dependency: this laptop still works for everything else if opslabs-bodycam isn't running.
local function bodycamReady() return GetResourceState('opslabs-bodycam') == 'started' end

RegisterNUICallback('dashcamToggle', function(_, cb)
    if not bodycamReady() then return cb({ ok = false, active = false, error = 'Bodycam resource is not running' }) end
    local active
    if exports['opslabs-bodycam']:IsLive() then
        exports['opslabs-bodycam']:StopLive('mdt')
        active = false
    else
        active = exports['opslabs-bodycam']:StartLive({ kind = 'dashcam' }) == true
    end
    cb({ ok = true, active = active })
end)

RegisterNUICallback('dashcamStatus', function(_, cb)
    cb({ ok = bodycamReady(), active = bodycamReady() and exports['opslabs-bodycam']:IsLive() or false })
end)

local function openMdt(plate)
    if nuiOpen then return end
    plate = plate or nearestInstalled()
    local prop = plate and props[plate]
    Dbg('openMdt: plate=%s prop=%s', plate, prop)
    if not prop then return end
    local status = lib.callback.await('opslabs-mdt:status', false)
    Dbg('openMdt: status=%s', json.encode(status or {}))
    if not status or status.denied then
        return lib.notify({ description = 'You are not issued an MDT.', type = 'error' })
    end
    nuiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', status = status })
    startCam(prop)
end

-- plain proximity prompt: [E] while close to an installed laptop. Wait(0) is required here, not a longer
-- sleep - IsControlJustPressed is only true for a single frame, so polling it every 300ms (the previous bug)
-- missed almost every real press.
CreateThread(function()
    local shown = nil
    while true do
        local plate = (not IsPauseMenuActive()) and nearestInstalled()
        if plate and not nuiOpen then
            if not shown then lib.showTextUI('[E] Open MDT', { icon = 'laptop' }) shown = true end
            if IsControlJustPressed(0, 38) then openMdt(plate) end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(300)
        end
    end
end)

--- /mdt: opens the nearest installed laptop outright, no prompt/third-eye needed - the guaranteed fallback
RegisterCommand('mdt', function()
    local plate = nearestInstalled()
    if not plate then return lib.notify({ description = 'No installed MDT close enough.', type = 'error' }) end
    openMdt(plate)
end, false)

-- third-eye: hold ALT, look roughly at an installed laptop from a bit further away than the plain prompt,
-- press E. A soft angle/distance check, not a real raycast - the prop's own collision is off (so it doesn't
-- block the seats/doors), which would make a physical raycast miss it entirely.
local thirdEyeHeld = false
RegisterCommand('+mdtEye', function() thirdEyeHeld = true end, false)
RegisterCommand('-mdtEye', function() thirdEyeHeld = false end, false)
RegisterKeyMapping('+mdtEye', 'OPS MDT: hold to third-eye', 'keyboard', 'LMENU')

local function lookingAtMounted(maxDist, maxAngleDeg)
    local coord = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local dir = vector3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx))
    local best, bestAngle
    for plate, e in pairs(props) do
        if DoesEntityExist(e) then
            local to = GetEntityCoords(e) - coord
            local dist = #to
            if dist > 0.05 and dist < maxDist then
                local cosAngle = (dir.x * to.x + dir.y * to.y + dir.z * to.z) / dist
                local angle = math.deg(math.acos(math.max(-1.0, math.min(1.0, cosAngle))))
                if angle < maxAngleDeg and (not bestAngle or angle < bestAngle) then best, bestAngle = plate, angle end
            end
        end
    end
    return best
end

CreateThread(function()
    local shown = nil
    while true do
        if thirdEyeHeld and not nuiOpen and not IsPauseMenuActive() then
            local plate = lookingAtMounted(6.0, 12.0)
            if plate then
                if not shown then lib.showTextUI('[E] Open MDT', { icon = 'laptop', position = 'top-center' }) shown = true end
                if IsControlJustPressed(0, 38) then openMdt(plate) end
            elseif shown then lib.hideTextUI() shown = nil end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(200)
        end
    end
end)

RegisterKeyMapping('mdtremove', 'Remove the MDT laptop from the nearest vehicle', 'keyboard', '')

AddEventHandler('onResourceStop', function(r)
    if r ~= GetCurrentResourceName() then return end
    for plate in pairs(props) do despawnProp(plate) end
    if mdtCam and DoesCamExist(mdtCam) then RenderScriptCams(false, false, 0, true, true) DestroyCam(mdtCam, false) end
end)
