-- Extension ladders (6.9 m and 13 m). /ladder (or Network cabling → Place an extension ladder):
-- aim at the wall / pole where the top should rest (the feet are worked out on the ground at
-- the 1-in-4 angle and it extends to reach), or aim at the ground to put the feet there.
-- At the foot of a ladder: E climb · H extend / retract · G pick it up.

local CC = Config.Cabling
local LEAN = 15.0                        -- degrees from vertical (the 1-in-4 rule)
local RUNG = 0.28                        -- rung spacing along the ladder

local function typeOf(id)
    for _, t in ipairs(CC.Ladders or {}) do if t.id == id then return t end end
    return (CC.Ladders or {})[1]
end

local ladders, spawned = {}, {}
local climbingLadder = nil
NearLadder = false


-- unit vector up the ladder for a heading (top leans away from the climbing side)
local function axisFor(heading)
    local h, l = math.rad(heading), math.rad(LEAN)
    return vector3(-math.sin(h) * math.sin(l), math.cos(h) * math.sin(l), math.cos(l))
end

local function loadModel(name)
    local h = joaat(name)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    return h
end

local function pose(base, fly, x, y, z, heading, ext)
    local a = axisFor(heading)
    SetEntityCoordsNoOffset(base, x, y, z, false, false, false)
    SetEntityRotation(base, -LEAN, 0.0, heading, 2, false)
    SetEntityCoordsNoOffset(fly, x + a.x * ext, y + a.y * ext, z + a.z * ext, false, false, false)
    SetEntityRotation(fly, -LEAN, 0.0, heading, 2, false)
end

local function spawnPair(t, x, y, z, heading, ext, alpha)
    local hb, hf = loadModel(t.base), loadModel(t.fly)
    if not (hb and hf) then return nil end
    local base = CreateObjectNoOffset(hb, x, y, z, false, false, false)
    local fly = CreateObjectNoOffset(hf, x, y, z, false, false, false)
    for _, e in ipairs({ base, fly }) do
        FreezeEntityPosition(e, true)
        SetEntityCollision(e, false, false)
        if alpha then SetEntityAlpha(e, alpha, false) end
    end
    pose(base, fly, x, y, z, heading, ext)
    return { base = base, fly = fly }
end

local function despawn(id)
    local s = spawned[id]
    if not s then return end
    for _, e in ipairs({ s.base, s.fly }) do if DoesEntityExist(e) then DeleteEntity(e) end end
    spawned[id] = nil
end

local function refresh()
    for id in pairs(spawned) do if not ladders[id] then despawn(id) end end
    for id, l in pairs(ladders) do
        local sig = ('%.2f|%.2f|%.2f|%.1f|%.2f'):format(l.x, l.y, l.z, l.heading, l.ext)
        local s = spawned[id]
        if s and s.sig ~= sig then
            pose(s.base, s.fly, l.x, l.y, l.z, l.heading, l.ext)
            s.sig = sig
        elseif not s then
            s = spawnPair(typeOf(l.type), l.x, l.y, l.z, l.heading, l.ext)
            if s then s.sig = sig spawned[id] = s end
        end
    end
end

RegisterNetEvent('opslabs-towers:ladders', function(list)
    ladders = {}
    for _, l in ipairs(list or {}) do ladders[l.id] = l end
    refresh()
end)

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end
    TriggerServerEvent('opslabs-towers:ladders:get')
end)

---------------------------------------------------------------------------
-- placing
---------------------------------------------------------------------------

local function rotToDir(r)
    local x, z = math.rad(r.x), math.rad(r.z)
    return vector3(-math.sin(z) * math.abs(math.cos(x)), math.cos(z) * math.abs(math.cos(x)), math.sin(x))
end

local function groundBelow(x, y, z, ignore)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x, y, z + 1.5, x, y, z - 15.0, 1 + 16, ignore or PlayerPedId(), 4)
    local _, hit, at, normal = GetShapeTestResult(ray)
    if hit == 1 and normal.z > 0.6 then return at.z end
end

local function outline(ents, ok)
    SetEntityDrawOutlineColor(ok and 48 or 255, ok and 209 or 69, ok and 88 or 58, 255)
    SetEntityDrawOutlineShader(1)
    for _, e in ipairs(ents) do SetEntityDrawOutline(e, true) end
end

function PlaceLadder(typeId)
    local t = typeOf(typeId)
    if not typeId and #(CC.Ladders or {}) > 1 then
        local opts = {}
        for _, lt in ipairs(CC.Ladders) do opts[#opts + 1] = { value = lt.id, label = lt.label } end
        local v = lib.inputDialog('Which ladder?', { { type = 'select', label = 'Ladder', options = opts, default = opts[1].value, required = true } })
        if not v then return end
        t = typeOf(v[1])
    end
    if not t or not loadModel(t.base) then lib.notify({ type = 'error', description = 'Start opslabs-props for the ladder model' }) return end
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local ghost = spawnPair(t, c.x, c.y, c.z, 0.0, 0.0, 200)
    local turn, ext, manualExt = 0.0, 0.0, false
    local result
    local sf = PlaceHud.buttons({ { 'Place', { 24, 191 } }, { 'Cancel', { 25, 177 } }, { 'Rotate', { 44, 38 } }, { 'Extend', { 172, 173 } } })
    local cosL, sinL = math.cos(math.rad(LEAN)), math.sin(math.rad(LEAN))
    while true do
        Wait(0)
        for _, ctl in ipairs({ 14, 15, 16, 17, 24, 25, 37, 44, 38, 140, 141, 142, 172, 173, 177, 191, 199, 200, 261, 262 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local to = camPos + rotToDir(camRot) * 20.0
        local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1 + 16, ped, 4)
        local _, hit, at, normal = GetShapeTestResult(ray)
        if IsDisabledControlPressed(0, 44) then turn = turn + 1.2 end
        if IsDisabledControlPressed(0, 38) then turn = turn - 1.2 end
        if IsDisabledControlJustPressed(0, 14) then turn = turn - 5 end
        if IsDisabledControlJustPressed(0, 15) then turn = turn + 5 end
        if IsDisabledControlPressed(0, 172) then ext = math.min(t.maxExt, ext + 0.03) manualExt = true end
        if IsDisabledControlPressed(0, 173) then ext = math.max(0.0, ext - 0.03) manualExt = true end

        local foot, heading, ok, note, restAt
        if hit == 1 and normal.z < 0.5 then
            -- aimed at a wall / pole: that's where the top rests. Face it, find the ground below
            -- the feet and extend until it reaches.
            local wall = vector3(-normal.x, -normal.y, 0.0)
            wall = #wall > 0.01 and wall / #wall or vector3(0.0, 1.0, 0.0)
            heading = (math.deg(math.atan(-wall.x, wall.y)) + turn) % 360
            local g = groundBelow(at.x - wall.x * 1.0, at.y - wall.y * 1.0, c.z, ghost and ghost.base)
            g = g or (c.z - 1.0)
            local L = (at.z - g) / cosL                                   -- ladder length needed
            if not manualExt then ext = math.max(0.0, math.min(t.maxExt, L - t.top + 0.25)) end
            L = math.min(L, t.top + ext)
            local fx, fy = at.x - wall.x * (L * sinL + 0.05), at.y - wall.y * (L * sinL + 0.05)
            g = groundBelow(fx, fy, at.z, ghost and ghost.base) or g
            foot = vector3(fx, fy, g)
            restAt = at
            local reach = cosL * (t.top + ext)
            ok = at.z - g <= reach + 0.3 and at.z - g > 0.8
            note = not ok and (at.z - g > reach and ('Too short to reach %.1f m — %s'):format(at.z - g, t.maxExt < 5 and 'use the 13 m ladder' or 'aim lower') or 'Aim higher up the wall')
                or ('Top rests at %.1f m   ·   extended %.1f m'):format(at.z - g, ext)
        elseif hit == 1 then
            foot = at
            heading = (camRot.z + turn) % 360
            ok = true
        else
            foot = camPos + rotToDir(camRot) * 4.0
            heading = (camRot.z + turn) % 360
            ok = false
            note = 'Aim at a wall or pole (where the top rests) or at the ground (where the feet go)'
        end
        if ghost then
            pose(ghost.base, ghost.fly, foot.x, foot.y, foot.z, heading, ext)
            outline({ ghost.base, ghost.fly }, ok)
        end
        local a = axisFor(heading)
        local top = foot + a * (t.top + ext)
        if not note then
            local fwd = vector3(-math.sin(math.rad(heading)), math.cos(math.rad(heading)), 0.0)
            local probe = StartExpensiveSynchronousShapeTestLosProbe(top.x, top.y, top.z, top.x + fwd.x * 0.6, top.y + fwd.y * 0.6, top.z, 1 + 16, ghost and ghost.base or ped, 4)
            local _, rest = GetShapeTestResult(probe)
            restAt = rest == 1 and top or nil
            note = ('Reaches %.1f m   ·   extended %.1f m   ·   %s'):format(top.z - foot.z, ext, rest == 1 and 'top resting on something' or 'nothing behind the top')
        end
        -- where the feet go, where the top lands, and the line between
        DrawMarker(25, foot.x, foot.y, foot.z + 0.02, 0, 0, 0, 0, 0, 0, 0.9, 0.9, 0.9, ok and 48 or 255, ok and 209 or 69, ok and 88 or 58, 160, false, false, 2, false, nil, nil, false)
        DrawMarker(28, top.x, top.y, top.z, 0, 0, 0, 0, 0, 0, 0.07, 0.07, 0.07, restAt and 48 or 255, restAt and 209 or 159, restAt and 88 or 10, 230, false, false, 2, false, nil, nil, false)
        DrawLine(foot.x, foot.y, foot.z + 0.05, top.x, top.y, top.z, 255, 255, 255, 120)
        PlaceHud.draw(sf, 'Placing ' .. t.label:lower(), note, { 255, 159, 10 }, not ok)
        if ok and (IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191)) then
            result = { x = foot.x, y = foot.y, z = foot.z, heading = heading, ext = ext, type = t.id }
            break
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) then break end
    end
    PlaceHud.release(sf)
    if ghost then for _, e in ipairs({ ghost.base, ghost.fly }) do if DoesEntityExist(e) then DeleteEntity(e) end end end
    if not result then return end
    if #(GetEntityCoords(ped) - vector3(result.x, result.y, result.z)) > 7.0 then
        lib.notify({ type = 'error', description = 'Walk closer to where the feet go' })
        return
    end
    if not lib.progressBar({ duration = 2500, label = 'Footing the ladder', canCancel = true, disable = { move = true, combat = true },
        anim = { dict = 'anim@heists@box_carry@', clip = 'idle' } }) then return end
    local r = lib.callback.await('opslabs-towers:ladder:place', false, result)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

---------------------------------------------------------------------------
-- extending
---------------------------------------------------------------------------

local function extendMode(l)
    local s = spawned[l.id]
    if not s then return end
    local lt = typeOf(l.type)
    local ext = l.ext
    local sf = PlaceHud.buttons({ { 'Done', 191 }, { 'Cancel', { 177, 25 } }, { 'Pull / let out the rope', { 172, 173 } } })
    local done = false
    local lastSound = 0
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 172, 173, 177, 191, 199, 200 }) do DisableControlAction(0, ctl, true) end
        local moved = false
        if IsDisabledControlPressed(0, 172) and ext < lt.maxExt then ext = math.min(lt.maxExt, ext + 0.012) moved = true end
        if IsDisabledControlPressed(0, 173) and ext > 0 then ext = math.max(0.0, ext - 0.012) moved = true end
        if moved and GetGameTimer() - lastSound > 280 then   -- the fly clicking past each rung
            lastSound = GetGameTimer()
            PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
        end
        if not ladders[l.id] or not DoesEntityExist(s.fly) then break end
        pose(s.base, s.fly, l.x, l.y, l.z, l.heading, ext)
        PlaceHud.draw(sf, 'Extending ladder', ('Extended %.1f / %.1f m   ·   reaches %.1f m'):format(ext, lt.maxExt, axisFor(l.heading).z * (lt.top + ext)), { 255, 159, 10 })
        if IsDisabledControlJustPressed(0, 191) then done = true break end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    if done and ladders[l.id] then
        local r = lib.callback.await('opslabs-towers:ladder:extend', false, l.id, ext)
        if r and r.error then lib.notify({ type = 'error', description = r.error }) end
    end
    if ladders[l.id] and spawned[l.id] then pose(s.base, s.fly, l.x, l.y, l.z, l.heading, ladders[l.id].ext) end
end

---------------------------------------------------------------------------
-- climbing
---------------------------------------------------------------------------

local function climb(l)
    local ped = PlayerPedId()
    local haveAnim = ClimbAnims.load()
    climbingLadder = l.id
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    local s, leaving, still = 0.0, false, 0.0
    local sf = PlaceHud.buttons({ { 'Climb', { 32, 33 } }, { 'Climb down', 73 } })
    local last = GetGameTimer()
    local h = math.rad(l.heading)
    local back = vector3(math.sin(h), -math.cos(h), 0.0)    -- the climbing side
    while true do
        Wait(0)
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000)
        last = now
        for _, ctl in ipairs({ 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 44, 73, 140, 141, 142 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local cur = ladders[l.id]
        if not cur or IsPedDeadOrDying(ped, true) then break end
        local top = typeOf(cur.type).top + cur.ext - 1.9
        local state = 'hold'
        if leaving then
            s = s - 1.6 * dt
            state = 'down'
            if s <= 0 then break end
        else
            local up, down = IsDisabledControlPressed(0, 32) and s < top, IsDisabledControlPressed(0, 33) and s > 0
            if up then s = math.min(top, s + (CC.ClimbSpeed or 0.9) * dt) state = 'up' end
            if down then s = math.max(0.0, s - (CC.ClimbSpeed or 0.9) * dt) state = 'down' end
            if up or down then
                still = 0.0
            else
                still = still + dt
                local rungAt = math.floor(s / RUNG + 0.5) * RUNG       -- feet onto the nearest rung
                s = s + math.max(-0.6 * dt, math.min(0.6 * dt, rungAt - s))
            end
            if s > top then s = top end                             -- someone retracted it under you
            if IsDisabledControlJustPressed(0, 73) then
                if s <= 0.3 then break end
                leaving = true
            end
        end
        if state == 'hold' and still > 0.7 and s > 1.5 then state = 'work' end
        local a = axisFor(cur.heading)
        local feet = vector3(cur.x, cur.y, cur.z) + a * s + back * 0.30
        SetEntityCoordsNoOffset(ped, feet.x, feet.y, feet.z + 1.0, false, false, false)
        -- face the ladder (the ladder clip is authored facing backwards, as on the poles)
        SetEntityHeading(ped, (cur.heading + ((haveAnim and CC.ClimbAnimFlip ~= false) and 180.0 or 0.0)) % 360)
        ClimbAnims.set(ped, state)
        PlaceHud.draw(sf, 'On the ladder', leaving and 'Climbing down…' or ('Height %.1f m'):format(a.z * s + 1.0), { 255, 159, 10 })
    end
    PlaceHud.release(sf)
    ClimbAnims.unload(ped)
    ClearPedTasks(ped)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityCoords(ped, l.x + back.x * 0.9, l.y + back.y * 0.9, l.z + 0.1, false, false, false, false)
    climbingLadder = nil
end

---------------------------------------------------------------------------
-- prompt at the foot of a ladder
---------------------------------------------------------------------------

local function nearestLadder(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for _, l in pairs(ladders) do
        local d = #(pos - vector3(l.x, l.y, l.z + 1.0))
        if d < (bd or maxDist) then best, bd = l, d end
    end
    return best
end

CreateThread(function()
    local shown = false
    while true do
        local l = not climbingLadder and not IsPedInAnyVehicle(PlayerPedId(), false) and nearestLadder(1.6)
        NearLadder = l and true or false
        if l then
            if not shown then lib.showTextUI('[E] Climb  ·  [H] Extend  ·  [G] Pick up', { icon = 'stairs' }) shown = true end
            Wait(0)
            local key = IsControlJustPressed(0, 38) and 'climb' or IsControlJustPressed(0, 74) and 'extend' or IsControlJustPressed(0, 47) and 'pickup'
            if key then
                lib.hideTextUI() shown = false
                if key == 'climb' then climb(l)
                elseif key == 'extend' then extendMode(l)
                elseif lib.progressBar({ duration = 2000, label = 'Taking the ladder down', canCancel = true, disable = { move = true, combat = true } }) then
                    local r = lib.callback.await('opslabs-towers:ladder:remove', false, l.id)
                    if r and r.error then lib.notify({ type = 'error', description = r.error }) end
                end
            end
        else
            if shown then lib.hideTextUI() shown = false end
            Wait(400)
        end
    end
end)

RegisterCommand(CC.LadderCommand or 'ladder', function() PlaceLadder() end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(spawned) do despawn(id) end
    if climbingLadder then
        local ped = PlayerPedId()
        ClearPedTasks(ped)
        SetEntityCollision(ped, true, true)
        FreezeEntityPosition(ped, false)
    end
end)
