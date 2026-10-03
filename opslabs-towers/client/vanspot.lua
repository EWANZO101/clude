-- OPS van roof spotlight: a lamp head on a pan / tilt yoke, on a telescopic post that slides along a
-- cross-rail on the roof. Fitted / removed at the van stores; worked from any seat inside the van.
-- The van's 'spot' state bag holds { on, s = slide, r = raise, p = pan, t = tilt } (nil = not fitted);
-- the server writes it so passengers can drive the light too. Every client draws the parts and the beam.

local V = Config.Van or {}
local S = V.Spotlight or {}
local LIM = {
    s = S.Slide or 0.62,                    -- metres either side of the middle
    r = S.Raise or 0.35,                    -- metres the mast extends
    tMin = S.TiltDown or -50.0, tMax = S.TiltUp or 40.0,
}
local SPEED = { p = 70.0, t = 40.0, s = 0.35, r = 0.15 }   -- per second (pan / tilt in degrees)
local RAIL_TOP, TUBE_TOP, TILT_AXIS, LENS = 0.10, 0.25, 0.22, 0.12  -- from opslabs-props/source/build_vanspot.py

local fitted = {}           -- veh -> { parts, mount, cur = { s, r, p, t }, sig }
local control               -- the van being worked from this client, while the controls are open

local function load(model)
    local h = joaat(model)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    return h
end

local function spawn(veh, model)
    local h = load(model)
    if not h then return nil end
    local p = GetEntityCoords(veh)
    local e = CreateObjectNoOffset(h, p.x, p.y, p.z + 5.0, false, false, false)
    SetEntityCollision(e, false, false)
    return e
end

local function attach(e, veh, bone, x, y, z, rx, ry, rz)
    if e then AttachEntityToEntity(e, veh, bone, x, y, z, rx or 0.0, ry or 0.0, rz or 0.0, false, false, false, false, 2, true) end
end

--- where the rail sits: across the roof just in front of the light bar (clear of the rack and ladder)
local function mountOf(veh)
    local mn, mx = GetModelDimensions(GetEntityModel(veh))
    local y = mn.y + (S.Along or 0.74) * (mx.y - mn.y)
    local a, b = GetOffsetFromEntityInWorldCoords(veh, 0.0, y, mx.z + 1.0), GetOffsetFromEntityInWorldCoords(veh, 0.0, y, mn.z)
    local _, hit, at, _, ent = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 2, 0, 7))
    local z = (hit == 1 and ent == veh) and GetOffsetFromEntityGivenWorldCoords(veh, at.x, at.y, at.z).z or (mx.z - 0.05)
    local bone = GetEntityBoneIndexByName(veh, 'chassis')
    return { y = y, z = z + (S.Lift or 0.0), bone = bone == -1 and 0 or bone }
end

local function clean(st)
    return { s = math.max(-LIM.s, math.min(LIM.s, tonumber(st.s) or 0.0)), r = math.max(0.0, math.min(LIM.r, tonumber(st.r) or 0.0)),
        p = ((tonumber(st.p) or 0.0) + 180.0) % 360.0 - 180.0, t = math.max(LIM.tMin, math.min(LIM.tMax, tonumber(st.t) or 0.0)) }
end

local function build(veh)
    local m = mountOf(veh)
    local f = { mount = m, parts = {} }
    for _, k in ipairs({ 'rail', 'post', 'mast', 'yoke', 'head', 'head_on' }) do f.parts[k] = spawn(veh, 'opslabs_van_spot_' .. k) end
    if not f.parts.rail then
        for _, e in pairs(f.parts) do DeleteEntity(e) end
        return nil
    end
    attach(f.parts.rail, veh, m.bone, 0.0, m.y, m.z)
    fitted[veh] = f
    return f
end

local function unbuild(veh)
    local f = fitted[veh]
    if not f then return end
    for _, e in pairs(f.parts) do if DoesEntityExist(e) then DeleteEntity(e) end end
    fitted[veh] = nil
end

--- local (vehicle frame) lens position and beam direction for a pose
local function beam(f, c)
    local m = f.mount
    local pivot = vector3(c.s, m.y, m.z + RAIL_TOP + TUBE_TOP + c.r + TILT_AXIS)
    local p, t = math.rad(c.p), math.rad(c.t)
    local dir = vector3(-math.sin(p) * math.cos(t), math.cos(p) * math.cos(t), math.sin(t))
    return pivot + dir * LENS, dir, pivot
end

local function pose(veh, f, c)
    local m, P = f.mount, f.parts
    local zTop = m.z + RAIL_TOP + TUBE_TOP + c.r
    attach(P.post, veh, m.bone, c.s, m.y, m.z + RAIL_TOP)
    attach(P.mast, veh, m.bone, c.s, m.y, zTop)
    attach(P.yoke, veh, m.bone, c.s, m.y, zTop, 0.0, 0.0, c.p)
    attach(P.head, veh, m.bone, c.s, m.y, zTop + TILT_AXIS, c.t, 0.0, c.p)
    attach(P.head_on, veh, m.bone, c.s, m.y, zTop + TILT_AXIS, c.t, 0.0, c.p)
end

local function toward(cur, want, step)
    if math.abs(want - cur) <= step then return want end
    return cur + (want > cur and step or -step)
end

local function isVan(veh) return Entity(veh).state.opsvan == true end

-- keep parts in step with the state bag; draw the beam
CreateThread(function()
    local last, scanned = GetGameTimer(), 0
    while true do
        local now = GetGameTimer()
        local dt = math.min(0.2, (now - last) / 1000)
        last = now
        local pos = GetEntityCoords(PlayerPedId())
        local any = false
        if now - scanned > 1000 then                              -- look for newly fitted vans once a second
            scanned = now
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                local st = isVan(veh) and Entity(veh).state.spot
                if st and not fitted[veh] and #(pos - GetEntityCoords(veh)) < 150.0 then build(veh) end
            end
        end
        for veh, f in pairs(fitted) do
            local st = DoesEntityExist(veh) and Entity(veh).state.spot
            if not st or #(pos - GetEntityCoords(veh)) > 180.0 then
                unbuild(veh)
            else
                any = true
                local want = (control and control.veh == veh) and control.c or clean(st)
                local c = f.cur or want
                if f.cur and not (control and control.veh == veh) then   -- other people's moves glide in
                    local dp = (want.p - c.p + 180.0) % 360.0 - 180.0
                    c = { s = toward(c.s, want.s, SPEED.s * 2 * dt), r = toward(c.r, want.r, SPEED.r * 2 * dt),
                        p = c.p + math.max(-SPEED.p * 2 * dt, math.min(SPEED.p * 2 * dt, dp)), t = toward(c.t, want.t, SPEED.t * 2 * dt) }
                end
                local sig = ('%.3f|%.3f|%.1f|%.1f'):format(c.s, c.r, c.p, c.t)
                if sig ~= f.sig then pose(veh, f, c) f.sig = sig end
                f.cur = c
                local on = (control and control.veh == veh) and control.on or st.on == true
                if f.parts.head_on then SetEntityVisible(f.parts.head_on, on, false) end
                if on then
                    local lens, dir = beam(f, c)
                    local a = GetOffsetFromEntityInWorldCoords(veh, lens.x, lens.y, lens.z)
                    local b = GetOffsetFromEntityInWorldCoords(veh, lens.x + dir.x, lens.y + dir.y, lens.z + dir.z)
                    local rgb = S.Colour or { 255, 244, 225 }
                    DrawSpotLightWithShadow(a.x, a.y, a.z, b.x - a.x, b.y - a.y, b.z - a.z, rgb[1], rgb[2], rgb[3],
                        S.Range or 80.0, S.Brightness or 14.0, 0.0, S.Cone or 13.0, S.Falloff or 25.0, 7)
                    DrawLightWithRange(a.x + (b.x - a.x) * 0.3, a.y + (b.y - a.y) * 0.3, a.z + (b.z - a.z) * 0.3, rgb[1], rgb[2], rgb[3], 1.2, 2.0)
                end
            end
        end
        Wait(any and 0 or 500)
    end
end)

---------------------------------------------------------------------------
-- controls (from inside the van)
---------------------------------------------------------------------------
local function send(veh, payload)
    TriggerServerEvent('opslabs-towers:van:spot', NetworkGetNetworkIdFromEntity(veh), payload)
end

local function controls(veh)
    local st = Entity(veh).state.spot
    if not st then return lib.notify({ type = 'error', description = 'No roof spotlight on this van — fit one at the van stores' }) end
    control = { veh = veh, c = clean(st), on = true }
    local sf = PlaceHud.buttons({ { 'Pan', { 174, 175 } }, { 'Tilt', { 172, 173 } }, { 'Slide (hold)', 21 }, { 'Raise / lower', { 10, 11 } },
        { 'Aim with camera (hold)', 19 }, { 'Light on / off', 191 }, { 'Park', 73 }, { 'Done', 177 } })
    local last, lastSent, sentSig = GetGameTimer(), 0, ''
    local ped = PlayerPedId()
    while control and DoesEntityExist(veh) and GetVehiclePedIsIn(ped, false) == veh and Entity(veh).state.spot do
        Wait(0)
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000)
        last = now
        for _, ctl in ipairs({ 10, 11, 19, 73, 81, 82, 85, 99, 100, 172, 173, 174, 175, 177, 191, 199, 200, 201 }) do DisableControlAction(0, ctl, true) end
        local c, slide = control.c, IsControlPressed(0, 21)
        if IsDisabledControlPressed(0, 174) then if slide then c.s = c.s - SPEED.s * dt else c.p = c.p + SPEED.p * dt end end
        if IsDisabledControlPressed(0, 175) then if slide then c.s = c.s + SPEED.s * dt else c.p = c.p - SPEED.p * dt end end
        if IsDisabledControlPressed(0, 172) then c.t = c.t + SPEED.t * dt end
        if IsDisabledControlPressed(0, 173) then c.t = c.t - SPEED.t * dt end
        if IsDisabledControlPressed(0, 10) then c.r = c.r + SPEED.r * dt end
        if IsDisabledControlPressed(0, 11) then c.r = c.r - SPEED.r * dt end
        local f = fitted[veh]
        if IsDisabledControlPressed(0, 19) and f then            -- the head turns to where the camera looks
            local _, _, pivot = beam(f, c)
            local cam, rot = GetGameplayCamCoord(), GetGameplayCamRot(2)
            local rx, rz = math.rad(rot.x), math.rad(rot.z)
            local look = cam + vector3(-math.sin(rz) * math.cos(rx), math.cos(rz) * math.cos(rx), math.sin(rx)) * 60.0
            local l = GetOffsetFromEntityGivenWorldCoords(veh, look.x, look.y, look.z) - pivot
            local wantP = math.deg(math.atan(-l.x, l.y))
            local wantT = math.deg(math.atan(l.z, math.sqrt(l.x * l.x + l.y * l.y)))
            local dp = (wantP - c.p + 180.0) % 360.0 - 180.0
            c.p = c.p + math.max(-SPEED.p * 2 * dt, math.min(SPEED.p * 2 * dt, dp))
            c.t = toward(c.t, wantT, SPEED.t * 2 * dt)
        end
        if IsDisabledControlJustPressed(0, 73) then c.s, c.r, c.p, c.t = 0.0, 0.0, 0.0, 0.0 end
        if IsDisabledControlJustPressed(0, 191) then
            control.on = not control.on
            PlaySoundFrontend(-1, control.on and 'NAV_UP_DOWN' or 'NAV_LEFT_RIGHT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
        end
        control.c = clean(c)
        c = control.c
        PlaceHud.draw(sf, 'Roof spotlight', ('%s   ·   Pan %d°   ·   Tilt %+d°   ·   Slide %+.2f m   ·   Mast %.2f m'):format(
            control.on and 'ON' or 'OFF', math.floor(c.p + 0.5), math.floor(c.t + 0.5), c.s, c.r), { 255, 214, 10 })
        local sig = ('%d|%.2f|%.2f|%.0f|%.0f'):format(control.on and 1 or 0, c.s, c.r, c.p, c.t)
        if sig ~= sentSig and now - lastSent > 120 then
            send(veh, { on = control.on, s = c.s, r = c.r, p = c.p, t = c.t })
            sentSig, lastSent = sig, now
        end
        if IsDisabledControlJustPressed(0, 177) then break end
    end
    if control and DoesEntityExist(veh) and Entity(veh).state.spot then
        local c = control.c
        Wait(80)                                                  -- the server ignores messages closer than 50 ms
        send(veh, { on = control.on, s = c.s, r = c.r, p = c.p, t = c.t })
    end
    PlaceHud.release(sf)
    control = nil
end

RegisterCommand('opsvan_spot', function()
    if control then control = nil return end
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 or not isVan(veh) then return end
    CreateThread(function() controls(veh) end)
end, false)
RegisterKeyMapping('opsvan_spot', 'OPS van: roof spotlight controls', 'keyboard', S.Key or 'L')

--- van stores entry: fit or take off the roof spotlight
function VanSpotStoresOption(veh)
    local on = Entity(veh).state.spot ~= nil
    return { title = on and 'Take the roof spotlight off' or 'Fit the roof spotlight',
        description = on and 'Unclamp the rail and stow the lamp' or ('Clamp the rail across the roof · %s inside the van to work it'):format(S.Key or 'L'),
        icon = 'lightbulb', iconColor = '#ffd60a', onSelect = function()
            if not lib.progressBar({ duration = on and 4000 or 6000, label = on and 'Unclamping the roof spotlight' or 'Clamping the spotlight rail to the roof',
                canCancel = true, disable = { move = true, combat = true, car = true }, anim = { dict = 'mini@repair', clip = 'fixing_a_ped' } }) then return end
            send(veh, on and false or { fit = true })
            lib.notify({ type = 'success', description = on and 'Roof spotlight stowed' or ('Roof spotlight fitted · get in and press %s'):format(S.Key or 'L') })
        end }
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for veh in pairs(fitted) do unbuild(veh) end
end)
