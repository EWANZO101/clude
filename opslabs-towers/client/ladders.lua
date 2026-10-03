-- Extension ladders (6.9 m and 13 m). /ladder (or Network cabling → Place an extension ladder):
-- you carry it in front of you (walk to move it, the camera stays free); walk up to a pole or
-- wall and it leans on it at the 1-in-4 angle. Scroll / ↑ ↓ extends (Shift = fine).
-- At the foot of a ladder: E climb · H extend / retract · G move or take it down.

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


--- what's in front of the player to lean on: a pole (within 4 m, roughly ahead) or a wall
local function leanTarget(ped)
    local pos = GetEntityCoords(ped)
    local h = math.rad(GetEntityHeading(ped))
    local fwd = vector3(-math.sin(h), math.cos(h), 0.0)
    local best, bd
    for _, p in ipairs(AllPoles()) do
        if not p.house and pos.z > p.z - 2.0 and pos.z < p.z + 3.0 then
            local to = vector3(p.x - pos.x, p.y - pos.y, 0.0)
            local d = #to
            if d < 4.5 and d > 0.2 and (to.x * fwd.x + to.y * fwd.y) / d > 0.6 and (not bd or d < bd) then
                best, bd = { kind = 'pole', f = p, H = p.H, dir = to / d }, d
            end
        end
    end
    if best then return best end
    local from = pos + vector3(0.0, 0.0, 0.4)
    local to = from + fwd * 4.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 + 16, ped, 4)
    local _, hit, at, normal = GetShapeTestResult(ray)
    if hit == 1 and math.abs(normal.z) < 0.5 then
        local dir = vector3(-normal.x, -normal.y, 0.0)
        dir = #dir > 0.01 and dir / #dir or fwd
        return { kind = 'wall', at = at, dir = dir }
    end
    return nil
end

--- carry a ladder: it stands in front of you and moves as you walk, so the camera is free.
--- Walk up to a pole or wall and it leans on it by itself. existing = a placed ladder to move.
local function carryLadder(t, existing)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local ghost = spawnPair(t, c.x, c.y, c.z, 0.0, 0.0, 210)
    if not ghost then lib.notify({ type = 'error', description = 'Start opslabs-props for the ladder model' }) return nil end
    local real = existing and spawned[existing.id]
    if real then SetEntityVisible(real.base, false, false) SetEntityVisible(real.fly, false, false) end
    local ext, turn = existing and existing.ext or 0.0, 0.0
    local result
    local cosL, sinL = math.cos(math.rad(LEAN)), math.sin(math.rad(LEAN))
    local sf = PlaceHud.buttons({ { existing and 'Put it down' or 'Place', { 24, 191 } }, { 'Cancel', { 25, 177 } }, { 'Extend / retract', { 15, 14 } }, { 'Fine', 21 }, { 'Turn', { 44, 38 } } })
    while true do
        Wait(0)
        for _, ctl in ipairs({ 14, 15, 16, 17, 24, 25, 37, 44, 38, 140, 141, 142, 172, 173, 177, 191, 199, 200, 257, 261, 262, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local fine = IsControlPressed(0, 21)
        local step = fine and 0.02 or 0.14
        if IsDisabledControlJustPressed(0, 15) or IsDisabledControlJustPressed(0, 261) then ext = ext + step end
        if IsDisabledControlJustPressed(0, 14) or IsDisabledControlJustPressed(0, 262) then ext = ext - step end
        if IsDisabledControlPressed(0, 172) then ext = ext + (fine and 0.005 or 0.03) end
        if IsDisabledControlPressed(0, 173) then ext = ext - (fine and 0.005 or 0.03) end
        if IsDisabledControlPressed(0, 44) then turn = turn + 1.5 end
        if IsDisabledControlPressed(0, 38) then turn = turn - 1.5 end
        ext = math.max(0.0, math.min(t.maxExt, ext))

        local pos = GetEntityCoords(ped)
        local lean = leanTarget(ped)
        local L = t.top + ext
        local foot, heading, note, rest
        if lean and lean.kind == 'pole' then
            -- against a pole: top stays below the ring head, never past the top
            local f = lean.f
            local dir = lean.dir
            heading = math.deg(math.atan(-dir.x, dir.y)) % 360
            local g = groundBelow(f.x - dir.x * 1.5, f.y - dir.y * 1.5, pos.z, ghost.base) or (pos.z - 1.0)
            local maxL = (f.z + lean.H - 0.35 - g) / cosL
            if L > maxL then ext = math.max(0.0, maxL - t.top) L = t.top + ext end
            local tooLong = t.top > maxL + 0.05
            local r = PoleRadius(f, L * cosL + (g - f.z))
            local fx, fy = f.x - dir.x * (L * sinL + r + 0.04), f.y - dir.y * (L * sinL + r + 0.04)
            foot = vector3(fx, fy, groundBelow(fx, fy, pos.z, ghost.base) or g)
            rest = not tooLong
            note = tooLong and ('This ladder is too long for a %d m pole — use the shorter one'):format(math.floor(lean.H))
                or ('Leaning on the pole · top at %.1f m of %d m%s'):format(L * cosL + (foot.z - f.z), math.floor(lean.H), ext >= maxL - t.top - 0.01 and ' · as high as it goes' or '')
        elseif lean and lean.kind == 'wall' then
            local dir = lean.dir
            heading = math.deg(math.atan(-dir.x, dir.y)) % 360
            local fx, fy = lean.at.x - dir.x * (L * sinL + 0.06), lean.at.y - dir.y * (L * sinL + 0.06)
            foot = vector3(fx, fy, groundBelow(fx, fy, pos.z, ghost.base) or (pos.z - 1.0))
            local a = axisFor(heading)
            local top = foot + a * L
            -- what does the ladder actually touch near its top? scan down from the top for the first wall face
            -- (a gutter or eave sticks out further than the wall, so the ladder rests on that)
            local contact, over
            for k = 0, 6 do
                local z = top.z - k * 0.25
                local along = (z - foot.z) / a.z
                local p = foot + a * along
                local from, to = p - dir * 1.2, p + dir * 0.8
                local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, z, to.x, to.y, z, 1 + 16, ghost.base, 4)
                local _, hit, at, normal = GetShapeTestResult(ray)
                if hit == 1 and math.abs(normal.z) < 0.5 then contact, over = { at = at, along = along, p = p }, k * 0.25 break end
            end
            if contact then
                -- slide the ladder out (or in) so it rests on that face
                local gap = (contact.at.x - contact.p.x) * dir.x + (contact.at.y - contact.p.y) * dir.y - 0.06
                foot = vector3(foot.x + dir.x * gap, foot.y + dir.y * gap, foot.z)
                foot = vector3(foot.x, foot.y, groundBelow(foot.x, foot.y, pos.z, ghost.base) or foot.z)
                rest = true
                if over > 0.01 then
                    local top2 = foot + a * L
                    local q = top2 + dir * 0.7
                    local ray = StartExpensiveSynchronousShapeTestLosProbe(q.x, q.y, top2.z + 0.5, q.x, q.y, top2.z - 2.0, 1 + 16, ghost.base, 4)
                    local _, hit, at, normal = GetShapeTestResult(ray)
                    note = (hit == 1 and normal.z > 0.6) and ('Over the roof edge by %.1f m · step off onto the roof at the top'):format(over)
                        or ('Top is %.1f m above the edge'):format(over)
                else
                    note = ('Leaning on the wall · top at %.1f m'):format(L * cosL)
                end
            else
                rest = false
                note = 'The top is above the wall — retract it a bit'
            end
        else
            heading = (GetEntityHeading(ped) + turn) % 360
            local h = math.rad(heading)
            local fx, fy = pos.x - math.sin(h) * 0.9, pos.y + math.cos(h) * 0.9
            foot = vector3(fx, fy, groundBelow(fx, fy, pos.z, ghost.base) or (pos.z - 1.0))
            note = 'Walk up to a wall or pole to lean it'
        end
        pose(ghost.base, ghost.fly, foot.x, foot.y, foot.z, heading, ext)
        outline({ ghost.base, ghost.fly }, rest)
        local top = foot + axisFor(heading) * L
        DrawMarker(25, foot.x, foot.y, foot.z + 0.02, 0, 0, 0, 0, 0, 0, 0.8, 0.8, 0.8, rest and 48 or 255, rest and 209 or 159, rest and 88 or 10, 150, false, false, 2, false, nil, nil, false)
        DrawMarker(28, top.x, top.y, top.z, 0, 0, 0, 0, 0, 0, 0.07, 0.07, 0.07, rest and 48 or 255, rest and 209 or 159, rest and 88 or 10, 230, false, false, 2, false, nil, nil, false)
        PlaceHud.draw(sf, (existing and 'Moving ' or 'Carrying ') .. t.label:lower(), ('%s   ·   extended %.2f / %.1f m'):format(note, ext, t.maxExt), { 255, 159, 10 }, not rest)
        if IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191) then
            if not rest and lib.alertDialog({ header = 'Nothing to lean on', content = 'Stand it up anyway? It won’t be safe to climb.', centered = true, cancel = true }) ~= 'confirm' then
                -- keep carrying
            else
                result = { x = foot.x, y = foot.y, z = foot.z, heading = heading, ext = ext, type = t.id }
                break
            end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) then break end
    end
    PlaceHud.release(sf)
    for _, e in ipairs({ ghost.base, ghost.fly }) do if DoesEntityExist(e) then DeleteEntity(e) end end
    if real and DoesEntityExist(real.base) then SetEntityVisible(real.base, true, false) SetEntityVisible(real.fly, true, false) end
    return result
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
    local result = carryLadder(t)
    if not result then return end
    if not lib.progressBar({ duration = 2000, label = 'Footing the ladder', canCancel = true, disable = { move = true, combat = true } }) then return end
    local r = lib.callback.await('opslabs-towers:ladder:place', false, result)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

local function moveLadder(l)
    local result = carryLadder(typeOf(l.type), l)
    if not result then return end
    local r = lib.callback.await('opslabs-towers:ladder:move', false, l.id, result)
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
    local sf = PlaceHud.buttons({ { 'Done', 191 }, { 'Cancel', { 177, 25 } }, { 'Pull / let out the rope', { 15, 14 } }, { 'Fine', 21 } })
    local done = false
    local lastSound = 0
    while true do
        Wait(0)
        for _, ctl in ipairs({ 14, 15, 16, 17, 24, 25, 172, 173, 177, 191, 199, 200 }) do DisableControlAction(0, ctl, true) end
        local moved = false
        local fine = IsControlPressed(0, 21)
        local before = ext
        if IsDisabledControlPressed(0, 172) then ext = ext + (fine and 0.004 or 0.012) end
        if IsDisabledControlPressed(0, 173) then ext = ext - (fine and 0.004 or 0.012) end
        if IsDisabledControlJustPressed(0, 15) then ext = ext + (fine and 0.02 or 0.14) end
        if IsDisabledControlJustPressed(0, 14) then ext = ext - (fine and 0.02 or 0.14) end
        ext = math.max(0.0, math.min(lt.maxExt, ext))
        if ext ~= before then moved = true end
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

--- fitting equipment to the wall in front while standing on a ladder (aim & place)
-- only things that go on a wall (no poles, cabinets, buildings or exchange plant)
local WALL_CATS = { ['Customer premises · outside'] = true, ['Customer premises · inside'] = true, ['On the pole'] = true }

function LadderWallEquipment(onClose)
    local options = {}
    for _, e in ipairs(CC.Equipment) do
        if (WALL_CATS[e.cat] or e.model == 'opslabs_house_pole') and IsModelInCdimage(joaat(e.model)) then
            options[#options + 1] = { title = 'Fit: ' .. e.label, description = 'Aim at the wall · scroll to rotate', icon = 'plus', onSelect = function()
                local spot = PlacementMode('fixture', e.model, 1.0, nil, 'Fitting ' .. e.label)
                if spot then
                    local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = e.model, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
                    if r and r.ok then lib.notify({ type = 'success', description = e.label .. ' fitted' })
                    else lib.notify({ type = 'error', description = (r and r.error == 'not allowed') and 'Only network engineers can fit equipment' or (r and r.error) or 'Failed' }) end
                end
                onClose()
            end }
        end
    end
    lib.registerContext({ id = 'ladder_equipment', root = true, title = 'Fit equipment', options = options, onExit = onClose })
    lib.showContext('ladder_equipment')
end

--- the pole a ladder is leaning on (its top within 60 cm of the pole), if any
local function poleAtTop(l)
    local t = typeOf(l.type)
    local top = vector3(l.x, l.y, l.z) + axisFor(l.heading) * (t.top + l.ext)
    for _, p in ipairs(AllPoles()) do
        if #(vector2(top.x, top.y) - vector2(p.x, p.y)) < 0.6 and top.z > p.z and top.z < p.z + p.H + 0.5 then return p end
    end
end

--- ladders leaning on a pole: { l, h = feet height above the pole base at the top step, angle }
function LaddersOnPole(pole)
    local out = {}
    for _, l in pairs(ladders) do
        local p = poleAtTop(l)
        if p and math.abs(p.x - pole.x) < 0.01 and math.abs(p.y - pole.y) < 0.01 then
            local t = typeOf(l.type)
            local s = t.top + l.ext - 1.9
            local feet = vector3(l.x, l.y, l.z) + axisFor(l.heading) * s
            out[#out + 1] = { l = l, s = s, h = feet.z - pole.z, angle = math.atan(feet.y - pole.y, feet.x - pole.x) }
        end
    end
    return out
end

--- somewhere to stand just past the top of a ladder (a roof, flat or pitched), or nil
function RoofAtTop(l)
    local t = typeOf(l.type)
    local a = axisFor(l.heading)
    local top = vector3(l.x, l.y, l.z) + a * (t.top + l.ext)
    local d = vector3(a.x, a.y, 0.0)
    d = #d > 0.01 and d / #d or vector3(0.0, 1.0, 0.0)
    for _, reach in ipairs({ 0.7, 1.0, 1.4 }) do
        local q = top + d * reach
        local ray = StartExpensiveSynchronousShapeTestLosProbe(q.x, q.y, top.z + 1.2, q.x, q.y, top.z - 1.8, 1 + 16, PlayerPedId(), 4)
        local _, hit, at, normal = GetShapeTestResult(ray)
        if hit == 1 and normal.z > 0.55 then return at end
    end
end

--- standing on a roof next to the top of a ladder: [E] to climb back down it
local function ladderTopNear(pos)
    for _, l in pairs(ladders) do
        local t = typeOf(l.type)
        local top = vector3(l.x, l.y, l.z) + axisFor(l.heading) * (t.top + l.ext)
        if #(pos - top) < 1.8 and pos.z > top.z - 1.6 then return l, t.top + l.ext - 1.9 end
    end
end

local function climb(l, startS)
    local ped = PlayerPedId()
    local haveAnim = ClimbAnims.load()
    climbingLadder = l.id
    if Coach then Coach('climb_ladder') end
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    local s, leaving, still = startS or 0.0, false, 0.0
    local onPole = poleAtTop(l)
    local transfer, roofSpot
    local menuOpen = false
    local sf = PlaceHud.buttons(onPole and { { 'Climb', { 32, 33 } }, { 'Equipment', 47 }, { 'Cut cable', 26 }, { 'Onto the pole', 23 }, { 'Climb down', 73 } }
        or { { 'Climb', { 32, 33 } }, { 'Equipment', 47 }, { 'Cut cable', 26 }, { 'Climb down', 73 } })
    local last = GetGameTimer()
    local h = math.rad(l.heading)
    local back = vector3(math.sin(h), -math.cos(h), 0.0)    -- the climbing side
    while true do
        Wait(0)
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000)
        last = now
        for _, ctl in ipairs({ 21, 22, 23, 24, 25, 26, 30, 31, 32, 33, 34, 35, 36, 37, 44, 47, 73, 140, 141, 142 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local cur = ladders[l.id]
        if not cur or IsPedDeadOrDying(ped, true) then break end
        local top = typeOf(cur.type).top + cur.ext - 1.9
        local state = 'hold'
        if leaving then
            s = s - 1.6 * dt
            state = 'down'
            if s <= 0 then break end
        elseif menuOpen then
            state = 'work'
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
            if IsDisabledControlJustPressed(0, 26) and CableCutAtHand then         -- C: cut a cable within reach
                menuOpen = true
                CreateThread(function() CableCutAtHand() menuOpen = false end)
            end
            -- fit equipment from the ladder: on the pole it leans on, or on the wall in front
            if IsDisabledControlJustPressed(0, 47) then
                menuOpen = true
                local feetNow = vector3(cur.x, cur.y, cur.z) + axisFor(cur.heading) * s
                if onPole and PoleEquipMenu then
                    PoleEquipMenu(onPole, math.atan(feetNow.y - onPole.y, feetNow.x - onPole.x), feetNow.z - onPole.z, function() menuOpen = false end)
                else
                    LadderWallEquipment(function() menuOpen = false end)
                end
            end
            -- near the top of a ladder leaning on a pole: step across onto the pole
            if onPole and s >= top - 0.8 and IsDisabledControlJustPressed(0, 23) then
                transfer = onPole
                break
            end
            -- at the top of a ladder against a building: step off onto the roof
            if not onPole and s >= top - 0.4 and IsDisabledControlJustPressed(0, 23) then
                local spot = RoofAtTop(cur)
                if spot then roofSpot = spot break end
            end
        end
        if state == 'hold' and still > 0.7 and s > 1.5 then state = 'work' end
        local a = axisFor(cur.heading)
        local sv = (state == 'up' or state == 'down') and ClimbAnims.step(s, RUNG) or s    -- rung by rung
        local feet = vector3(cur.x, cur.y, cur.z) + a * sv + back * 0.30
        SetEntityCoordsNoOffset(ped, feet.x, feet.y, feet.z + 1.0, false, false, false)
        -- face the ladder (the ladder clip is authored facing backwards, as on the poles)
        SetEntityHeading(ped, (cur.heading + ((haveAnim and CC.ClimbAnimFlip ~= false) and 180.0 or 0.0)) % 360)
        if state == 'up' or state == 'down' then ClimbAnims.drive(ped, s, RUNG * 2) else ClimbAnims.set(ped, state) end
        if not CableCutActive then PlaceHud.draw(sf, 'On the ladder', leaving and 'Climbing down…'
            or ('Height %.1f m%s'):format(a.z * s + 1.0, (onPole and s >= top - 0.8) and '   ·   F to step onto the pole'
                or (not onPole and s >= top - 0.4 and RoofAtTop(cur)) and '   ·   F to step onto the roof' or ''), { 255, 159, 10 }) end
    end
    PlaceHud.release(sf)
    if transfer then
        -- straight onto the pole at the same height, on the ladder's side
        local cur = ladders[l.id] or l
        local feet = vector3(cur.x, cur.y, cur.z) + axisFor(cur.heading) * s
        climbingLadder = nil
        ClimbAnims.unload(ped)
        return ClimbPole(transfer, feet.z - transfer.z, math.atan(feet.y - transfer.y, feet.x - transfer.x))
    end
    ClimbAnims.unload(ped)
    ClearPedTasks(ped)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    if roofSpot then
        SetEntityCoords(ped, roofSpot.x, roofSpot.y, roofSpot.z + 0.05, false, false, false, false)
        SetEntityHeading(ped, l.heading)
    else
        SetEntityCoords(ped, l.x + back.x * 0.9, l.y + back.y * 0.9, l.z + 0.1, false, false, false, false)
    end
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
        local topL, topS = nil, nil
        if not l and not climbingLadder and not IsPedInAnyVehicle(PlayerPedId(), false) then topL, topS = ladderTopNear(GetEntityCoords(PlayerPedId())) end
        if topL then
            lib.showTextUI('[E] Climb down the ladder', { icon = 'stairs' })
            while topL and not climbingLadder do
                Wait(0)
                if IsControlJustPressed(0, 38) then lib.hideTextUI() climb(topL, topS) break end
                topL = ladderTopNear(GetEntityCoords(PlayerPedId())) and topL or nil
            end
            lib.hideTextUI()
        end
        NearLadder = l and true or false
        if l then
            if not shown then lib.showTextUI('[E] Climb  ·  [H] Extend  ·  [G] Move / take down', { icon = 'stairs' }) shown = true end
            Wait(0)
            local key = IsControlJustPressed(0, 38) and 'climb' or IsControlJustPressed(0, 74) and 'extend' or IsControlJustPressed(0, 47) and 'options'
            if key then
                lib.hideTextUI() shown = false
                if key == 'climb' then climb(l)
                elseif key == 'extend' then extendMode(l)
                else
                    local t = typeOf(l.type)
                    lib.registerContext({ id = 'ladder_opts', root = true, title = t.label, options = {
                        { title = ('Extended %.1f of %.1f m'):format(l.ext or 0, t.maxExt), description = 'Placed by ' .. (l.owner or '?'), icon = 'stairs', readOnly = true },
                        { title = 'Move it', description = 'Pick it up and carry it · walk up to a pole or wall to lean it', icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function() moveLadder(l) end },
                        { title = 'Extend / retract', description = 'Scroll or ↑ / ↓ · Shift for fine', icon = 'arrows-up-down', onSelect = function() extendMode(l) end },
                        { title = 'Take it down', icon = 'trash', iconColor = '#ff453a', onSelect = function()
                            if lib.progressBar({ duration = 2000, label = 'Taking the ladder down', canCancel = true, disable = { move = true, combat = true } }) then
                                local r = lib.callback.await('opslabs-towers:ladder:remove', false, l.id)
                                if r and r.error then lib.notify({ type = 'error', description = r.error }) end
                            end
                        end },
                    } })
                    lib.showContext('ladder_opts')
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

--- from a pole back onto a ladder's top step (called by poles.lua)
function ClimbLadderFrom(l, s) climb(ladders[l.id] or l, s) end
