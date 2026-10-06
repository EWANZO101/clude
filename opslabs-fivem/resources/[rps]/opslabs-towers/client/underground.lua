-- Underground chambers & cable tunnels (opslabs_ug_*): walk-in concrete structures placed under roads and pavements.
-- Every model's origin is on the road surface and it hangs below. A chamber has an access hatch (a door leaf in
-- Config.Buildings: E opens / closes it, H for its PIN keypad) and step irons; tunnels join onto chamber openings and
-- onto each other. Placing snaps pieces together; "Lay a tunnel line" builds a whole run in one go.
-- F at an open hatch climbs down, F at the step irons inside climbs back up.

local U = Config.Underground or {}
local CH, SEG = 1.8, 4.0                           -- chamber half size, tunnel section length (build_underground.py)
local HATCH = U.Hatch or { -1.0, -1.15 }           -- hatch centre in the chamber's frame
local FLOOR = U.Floor or -3.0
local IRONS = { HATCH[1], -1.0 }                   -- where you stand at the foot of the step irons
local CHAMBER, TUNNEL, ENDWALL = 'opslabs_ug_chamber', 'opslabs_ug_tunnel', 'opslabs_ug_tunnel_end'
local ENTRANCE, RISER, RISER_FLUSH = 'opslabs_ug_entrance', 'opslabs_ug_riser', 'opslabs_ug_riser_flush'
local TEE = 'opslabs_ug_tunnel_tee'                    -- tunnel section with a side opening on its +X wall
local LABEL = { [CHAMBER] = 'underground chamber', [TUNNEL] = 'tunnel section', [ENDWALL] = 'tunnel end wall',
    [ENTRANCE] = 'street entrance', [RISER] = 'riser pipe', [RISER_FLUSH] = 'flush riser pipe', [TEE] = 'tunnel T-junction' }
local ENT_DOOR = U.EntranceDoor or { 0.0, -1.0 }       -- outside the kiosk door (entrance frame)
local ENT_LAND = U.EntranceLanding or { -0.9, 1.0 }    -- foot of the stairs, below

local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function headingOf(dx, dy) return math.deg(math.atan(-dx, dy)) % 360 end
local function toWorld(f, lx, ly)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return f.x + lx * c - ly * s, f.y + lx * s + ly * c
end
local function dirOf(heading, lx, ly)
    local h = math.rad(heading)
    return lx * math.cos(h) - ly * math.sin(h), lx * math.sin(h) + ly * math.cos(h)
end

--- open ends you can build onto: { x, y, z, dx, dy } (d points outward)
local function connections()
    local pts = {}
    for _, f in pairs(fixtures()) do
        local list = f.model == CHAMBER and { { CH, 0 }, { -CH, 0 }, { 0, CH }, { 0, -CH } } or f.model == TUNNEL and { { 0, SEG / 2 }, { 0, -SEG / 2 } }
            or f.model == ENTRANCE and { { 0, CH } } or f.model == TEE and { { 0, SEG / 2 }, { 0, -SEG / 2 }, { 1.2, 0 } } or nil
        for _, p in ipairs(list or {}) do
            local x, y = toWorld(f, p[1], p[2])
            local len = math.sqrt(p[1] * p[1] + p[2] * p[2])
            local dx, dy = dirOf(f.heading or 0.0, p[1] / len, p[2] / len)
            pts[#pts + 1] = { x = x, y = y, z = f.z, dx = dx, dy = dy, id = f.id }
        end
    end
    -- an end that meets another piece (or an end wall) is taken
    local free = {}
    for i, a in ipairs(pts) do
        local used = false
        for j, b in ipairs(pts) do
            if i ~= j and math.abs(a.x - b.x) < 0.3 and math.abs(a.y - b.y) < 0.3 and math.abs(a.z - b.z) < 0.5 then used = true break end
        end
        for _, f in pairs(fixtures()) do
            if f.model == ENDWALL and math.abs(a.x - f.x) < 0.3 and math.abs(a.y - f.y) < 0.3 then used = true end
        end
        if not used then free[#free + 1] = a end
    end
    return free
end

local function aimGround(reach)
    local cam, rot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local to = cam + vector3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx)) * (reach or 40.0)
    local _, hit, at = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, to.x, to.y, to.z, 1, PlayerPedId(), 4))
    return hit == 1 and at or nil
end

local function groundAt(x, y, z)
    local ok, g = GetGroundZFor_3dCoord(x, y, z + 3.0, false)
    return ok and g or nil
end

--- outline a piece's footprint on the road (the structure itself is out of sight below)
local FOOT = { [CHAMBER] = { CH, CH }, [TUNNEL] = { 1.2, SEG / 2 }, [ENDWALL] = { 1.2, 0.1 }, [ENTRANCE] = { CH, CH }, [RISER] = { 0.15, 0.15 }, [RISER_FLUSH] = { 0.15, 0.15 }, [TEE] = { 1.2, SEG / 2 } }
local function footprint(model, x, y, z, heading, r, g, b)
    local e = FOOT[model]
    local c = {}
    for i, k in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
        local dx, dy = dirOf(heading, k[1] * e[1], k[2] * e[2] + (model == ENDWALL and 0.1 or 0))
        c[i] = vector3(x + dx, y + dy, (groundAt(x + dx, y + dy, z) or z) + 0.06)
    end
    for i = 1, 4 do local a, bb = c[i], c[i % 4 + 1] DrawLine(a.x, a.y, a.z, bb.x, bb.y, bb.z, r, g, b, 255) end
    if model == CHAMBER then
        local hx, hy = dirOf(heading, HATCH[1], HATCH[2])
        DrawMarker(43, x + hx, y + hy, z + 0.02, 0, 0, 0, 0, 0, heading, 0.8, 0.8, 0.05, r, g, b, 120, false, false, 2, false, nil, nil, false)
    end
end

--- where a piece goes when built onto an open end
local function snapped(model, p)
    local off = (model == CHAMBER or model == ENTRANCE) and CH or (model == TUNNEL or model == TEE) and SEG / 2 or 0.0
    -- an entrance has its one opening on its +Y side: that side faces back on to the open end
    local heading = model == ENTRANCE and headingOf(-p.dx, -p.dy) or headingOf(p.dx, p.dy)
    return { x = p.x + p.dx * off, y = p.y + p.dy * off, z = p.z, heading = heading }
end

local function nearestEnd(at, maxD)
    local best, bd
    for _, p in ipairs(connections()) do
        local d = math.sqrt((p.x - at.x) ^ 2 + (p.y - at.y) ^ 2)
        if d < (bd or maxD) then best, bd = p, d end
    end
    return best
end

local sf
local function hud(buttons) sf = PlaceHud.buttons(buttons) end

--- place pieces one at a time (keeps going until Backspace): snaps onto open ends of chambers / tunnels
local function placeOne(model)
    local h = joaat(model)
    if not IsModelInCdimage(h) then return lib.notify({ type = 'error', description = 'Restart opslabs-props for the underground models' }) end
    lib.requestModel(h, 5000)
    local ghost = CreateObjectNoOffset(h, 0.0, 0.0, -100.0, false, false, false)
    SetEntityAlpha(ghost, 160, false) SetEntityCollision(ghost, false, false) FreezeEntityPosition(ghost, true)
    hud({ { 'Place', { 24, 191 } }, { 'Done', { 25, 177 } }, { 'Turn', { 44, 38 } }, { 'Deeper / shallower', { 11, 10 } }, { 'Free (no snap)', 21 } })
    local turn, depth, placed = GetEntityHeading(PlayerPedId()), 0.0, 0
    while true do
        Wait(0)
        for _, c in ipairs({ 10, 11, 24, 25, 37, 38, 44, 140, 141, 142, 177, 191, 199, 200 }) do DisableControlAction(0, c, true) end
        DisablePlayerFiring(PlayerId(), true)
        if IsDisabledControlPressed(0, 44) then turn = turn + 1.5 end
        if IsDisabledControlPressed(0, 38) then turn = turn - 1.5 end
        if IsDisabledControlPressed(0, 11) then depth = depth - 0.01 end
        if IsDisabledControlPressed(0, 10) then depth = depth + 0.01 end
        local at = aimGround(40.0)
        local spot, snapEnd
        if at then
            local p = model ~= RISER and model ~= RISER_FLUSH and not IsControlPressed(0, 21) and nearestEnd(at, 3.0)
            if p then spot, snapEnd = snapped(model, p), true
            else spot = { x = at.x, y = at.y, z = at.z + depth, heading = turn % 360 } end
            SetEntityCoordsNoOffset(ghost, spot.x, spot.y, spot.z, false, false, false)
            SetEntityHeading(ghost, spot.heading)
            footprint(model, spot.x, spot.y, spot.z, spot.heading, snapEnd and 48 or 255, snapEnd and 209 or 159, snapEnd and 88 or 10)
        end
        PlaceHud.draw(sf, 'Placing ' .. LABEL[model] .. 's', (snapEnd and 'Joins on to the open end' or 'Aim at the road / ground · aim near an open end to join on')
            .. ('   ·   %d placed'):format(placed), { 120, 120, 128 })
        if spot and (IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191)) then
            local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = model, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
            if r and r.ok then placed = placed + 1 PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true) Wait(300)
            else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    DeleteEntity(ghost)
    if placed > 0 then lib.notify({ type = 'success', description = ('%d %s%s placed'):format(placed, LABEL[model], placed == 1 and '' or 's') }) end
end

--- a whole run: click the start (or an open end), aim at the end — tunnel sections every 4 m, level with the start
local function tunnelLine()
    local v = lib.inputDialog('Lay a tunnel line', {
        { type = 'checkbox', label = 'Chamber at the start (unless you start on an open end)', checked = true },
        { type = 'checkbox', label = 'Chamber at the end', checked = true },
        { type = 'checkbox', label = 'Otherwise close the far end with an end wall', checked = true },
        { type = 'select', label = 'Chambers along the line', default = '0', options = {
            { value = '0', label = 'None — tunnel all the way' }, { value = 'b2b', label = 'Chambers only, back to back (no tunnel)' },
            { value = '1', label = 'A chamber after every tunnel section' }, { value = '2', label = 'A chamber every 2 sections (8 m)' },
            { value = '3', label = 'A chamber every 3 sections (12 m)' }, { value = '5', label = 'A chamber every 5 sections (20 m)' } } },
    })
    if not v then return end
    local wantStart, wantEnd, wantWall = v[1], v[2], v[3]
    local every = v[4] == 'b2b' and 'b2b' or tonumber(v[4]) or 0
    local start
    hud({ { 'Set start / build', { 24, 191 } }, { 'Back', { 25, 177 } }, { 'Cancel', 200 } })
    while true do
        Wait(0)
        for _, c in ipairs({ 24, 25, 37, 140, 141, 142, 177, 191, 199, 200 }) do DisableControlAction(0, c, true) end
        DisablePlayerFiring(PlayerId(), true)
        local at = aimGround(60.0)
        local list, note, warn = {}, nil, false
        if at and not start then
            local p = nearestEnd(at, 3.0)
            if p then DrawMarker(28, p.x, p.y, p.z + 0.1, 0, 0, 0, 0, 0, 0, 0.25, 0.25, 0.25, 48, 209, 88, 200, false, false, 2, false, nil, nil, false) end
            note = p and 'Click to start from this open end' or 'Click the start of the tunnel (or aim at an open end of a chamber / tunnel)'
        elseif at and start then
            local dx, dy = at.x - start.x, at.y - start.y
            local L = math.sqrt(dx * dx + dy * dy)
            if L > 2.0 then
                dx, dy = dx / L, dy / L
                if start.dx then dx, dy = start.dx, start.dy end      -- carries straight on from the open end
                local heading = headingOf(dx, dy)
                local z = start.z
                -- walk along the line laying pieces end to end (a start chamber is centred on the click)
                local pos = (not start.dx and wantStart) and -CH or 0.0
                local n, chambers, last = 0, 0, nil
                local function put(model)
                    local len = model == CHAMBER and 2 * CH or SEG
                    local t = pos + len / 2
                    list[#list + 1] = { model = model, x = start.x + dx * t, y = start.y + dy * t, z = z, heading = heading }
                    pos, last = pos + len, model
                    if model == TUNNEL then n = n + 1 else chambers = chambers + 1 end
                end
                if not start.dx and wantStart then put(CHAMBER) end
                local stop = L - (wantEnd and 2 * CH or 0)
                local sinceChamber = 0
                while #list < 55 do
                    local nextLen = every == 'b2b' and 2 * CH or SEG
                    if pos + nextLen > stop and #list > 0 then break end
                    if every == 'b2b' then put(CHAMBER)
                    else
                        put(TUNNEL)
                        sinceChamber = sinceChamber + 1
                        if every > 0 and sinceChamber >= every and pos + 2 * CH + SEG <= stop then put(CHAMBER) sinceChamber = 0 end
                    end
                end
                if wantEnd and last ~= CHAMBER then put(CHAMBER)
                elseif not wantEnd and wantWall then list[#list + 1] = { model = ENDWALL, x = start.x + dx * pos, y = start.y + dy * pos, z = z, heading = heading } end
                -- the ground must stay above the tunnel roof all the way along
                local low = 0.0
                for _, sp in ipairs(list) do
                    local g = groundAt(sp.x, sp.y, z)
                    if g then low = math.min(low, g - z) end
                end
                warn = low < -0.45
                note = ('%d tunnel section%s · %d chamber%s · %.0f m long%s'):format(n, n == 1 and '' or 's', chambers, chambers == 1 and '' or 's', pos - ((not start.dx and wantStart) and -CH or 0.0),
                    warn and ('   ·   the ground drops %.1f m — the tunnel would show above ground'):format(-low) or '')
            else
                note = 'Aim further along the route'
            end
            DrawMarker(28, start.x, start.y, start.z + 0.1, 0, 0, 0, 0, 0, 0, 0.25, 0.25, 0.25, 48, 209, 88, 200, false, false, 2, false, nil, nil, false)
        else
            note = 'Aim at the road or the ground'
        end
        for _, sp in ipairs(list) do footprint(sp.model, sp.x, sp.y, sp.z, sp.heading, warn and 255 or 48, warn and 69 or 209, warn and 58 or 88) end
        PlaceHud.draw(sf, 'Lay a tunnel line', note, { 120, 120, 128 }, warn)
        if at and (IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191)) then
            if not start then
                local p = nearestEnd(at, 3.0)
                start = p and { x = p.x, y = p.y, z = p.z, dx = p.dx, dy = p.dy } or { x = at.x, y = at.y, z = at.z }
            elseif #list > 0 then
                if warn and lib.alertDialog({ header = 'Part of it would show above ground', content = 'Build it anyway?', centered = true, cancel = true }) ~= 'confirm' then goto continue end
                local r = lib.callback.await('opslabs-towers:fixture:saveMany', false, list)
                if r and r.ok then lib.notify({ type = 'success', description = ('Tunnel built — %d piece(s)'):format(r.count or #list) })
                else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
                break
            end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) then
            if start then start = nil else break end
        end
        if IsDisabledControlJustPressed(0, 200) then break end
        ::continue::
    end
    PlaceHud.release(sf)
end

function UndergroundMenu()
    local pos, near = GetEntityCoords(PlayerPedId()), {}
    for _, f in pairs(fixtures()) do
        if LABEL[f.model] then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d < 150.0 then near[#near + 1] = { f = f, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local options = {
        { title = 'Lay a tunnel line', description = 'Click the start, aim at the end · chambers at the ends, a section every 4 m, level all the way', icon = 'route', iconColor = '#30d158',
          onSelect = function() tunnelLine() UndergroundMenu() end },
        { title = 'Dig forward from here (inside)', description = 'Underground: face an open end, or face a tunnel wall to branch off · walk into the highlighted section and it\'s built · G tunnel / chamber',
          icon = 'person-digging', iconColor = '#30d158', onSelect = function() if DigForward then DigForward() end end },
        { title = 'Place chambers one by one', description = '3.2 × 3.2 m walk-in chamber with an access hatch (PIN lock) and step irons', icon = 'square', iconColor = '#8e8e93',
          onSelect = function() placeOne(CHAMBER) UndergroundMenu() end },
        { title = 'Place tunnel sections one by one', description = '4 m sections · aim near an open end and they join on · keeps going until Backspace', icon = 'grip-lines-vertical', iconColor = '#8e8e93',
          onSelect = function() placeOne(TUNNEL) UndergroundMenu() end },
        { title = 'Close an open end', description = 'End wall with sealed ducts', icon = 'square-xmark', iconColor = '#8e8e93',
          onSelect = function() placeOne(ENDWALL) UndergroundMenu() end },
        { title = 'Place a street entrance', description = 'Access kiosk with stairs down · joins on to an open end like a chamber · F at the door to go down', icon = 'door-open', iconColor = '#30d158',
          onSelect = function() placeOne(ENTRANCE) UndergroundMenu() end },
        { title = 'Place riser pipes (goose-neck)', description = 'Duct pipe up out of the ground anywhere · from the tunnel / chamber ceiling below · fibre & copper join through it', icon = 'faucet', iconColor = '#8e8e93',
          onSelect = function() placeOne(RISER) UndergroundMenu() end },
        { title = 'Place riser pipes (flush)', description = 'Ends at ground level with a duct cap — under a cabinet or beside a pole', icon = 'circle-dot', iconColor = '#8e8e93',
          onSelect = function() placeOne(RISER_FLUSH) UndergroundMenu() end },
    }
    for i = 1, math.min(#near, 25) do
        local f = near[i].f
        options[#options + 1] = { title = ('%s #%d'):format(LABEL[f.model]:gsub('^%l', string.upper), f.id), description = ('%d m away · move, fine-tune, teleport or remove'):format(math.floor(near[i].d)),
            icon = 'location-dot', arrow = true, onSelect = function() if CableActions and CableActions.fixture then CableActions.fixture(f) end end }
    end
    lib.registerContext({ id = 'towers_underground', title = 'Underground chambers & tunnels', options = options })
    lib.showContext('towers_underground')
end

---------------------------------------------------------------------------
-- open ends seal themselves: every chamber / tunnel opening with nothing joined to it gets a concrete wall
-- (a local prop, not saved) — join another piece on and that wall goes, so lines can always be extended
---------------------------------------------------------------------------
local seals = {}
local DigKey = nil              -- the open end being dug right now gets no wall
local function endKey(p) return ('%.1f|%.1f|%.1f'):format(p.x, p.y, p.z) end
CreateThread(function()
    while true do
        Wait(1000)
        local pos = GetEntityCoords(PlayerPedId())
        local want = {}
        for _, p in ipairs(connections()) do
            if math.abs(p.x - pos.x) < 150.0 and math.abs(p.y - pos.y) < 150.0 then
                local key = endKey(p)
                want[key] = key ~= DigKey or nil
                if key ~= DigKey and (not seals[key] or not DoesEntityExist(seals[key])) then
                    local h = joaat(ENDWALL)
                    if IsModelInCdimage(h) then
                        lib.requestModel(h, 5000)
                        local e = CreateObjectNoOffset(h, p.x, p.y, p.z, false, false, false)
                        SetEntityHeading(e, headingOf(p.dx, p.dy))
                        FreezeEntityPosition(e, true)
                        seals[key] = e
                    end
                end
            end
        end
        for key, e in pairs(seals) do
            if not want[key] then
                if DoesEntityExist(e) then DeleteEntity(e) end
                seals[key] = nil
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, e in pairs(seals) do if DoesEntityExist(e) then DeleteEntity(e) end end
end)

---------------------------------------------------------------------------
-- dig forward: inside, at an open end — a highlighted section (solid, so you can walk on it) waits in front of you;
-- walk into it and it's built for real, the wall goes, and the next one appears ahead. G swaps tunnel / chamber.
---------------------------------------------------------------------------
local function pieceAt(model, spot)
    for _, f in pairs(fixtures()) do
        if f.model == model and math.abs(f.x - spot.x) < 0.2 and math.abs(f.y - spot.y) < 0.2 and math.abs(f.z - spot.z) < 0.2 then return f end
    end
end

--- the real piece is in the world with its collision (not just saved) — only then can anything under your feet go
local function pieceReady(model, spot)
    local f = pieceAt(model, spot)
    local ents = f and CablingEntities and CablingEntities('f' .. f.id)
    local e = ents and ents[1]
    return e and DoesEntityExist(e) and HasCollisionLoadedAroundEntity(PlayerPedId())
end

--- wait (up to ms) for a piece to be really there
local function awaitPiece(model, spot, ms)
    local t = GetGameTimer() + (ms or 6000)
    while GetGameTimer() < t do
        if pieceReady(model, spot) then Wait(250) return true end
        Wait(50)
    end
    return false
end

--- where to dig from: an open end in front of you (up to 80 m along the tunnel), or — facing a tunnel wall — a new
--- side opening: the section you're in becomes a T-junction opening on your side
local function digStart(ped)
    local pos = GetEntityCoords(ped)
    local rz = math.rad(GetGameplayCamRot(2).z)
    local fx, fy = -math.sin(rz), math.cos(rz)
    local best, bd
    for _, p in ipairs(connections()) do
        local vx, vy = p.x - pos.x, p.y - pos.y
        local d = math.sqrt(vx * vx + vy * vy)
        local level = pos.z < p.z - 0.8 and pos.z > p.z + FLOOR - 0.5
        local ahead = d < 2.5 or (vx * fx + vy * fy) / math.max(d, 0.01) > 0.75
        if level and ahead and d < (bd or 80.0) then best, bd = p, d end
    end
    if best then return best end
    -- inside a tunnel section, facing one of its walls?
    for _, f in pairs(fixtures()) do
        if f.model == TUNNEL or f.model == TEE then
            local h = math.rad(f.heading or 0.0)
            local ax, ay = -math.sin(h), math.cos(h)            -- along the tunnel
            local sx, sy = math.cos(h), math.sin(h)             -- its +X side
            local vx, vy = pos.x - f.x, pos.y - f.y
            local lx, ly = vx * sx + vy * sy, vx * ax + vy * ay
            if math.abs(lx) < 1.1 and math.abs(ly) < SEG / 2 and pos.z < f.z - 0.8 and pos.z > f.z + FLOOR - 0.5 then
                local side = fx * sx + fy * sy
                if math.abs(fx * ax + fy * ay) > 0.7 then return nil, 'That way is already built — face a wall to branch off' end
                if f.model == TEE and side > 0 then return nil, 'There\'s already an opening on this side — walk to it' end
                -- swap the section for a T-junction opening on the side you face (put the new one in before taking the old one out)
                local heading = side > 0 and (f.heading or 0.0) or ((f.heading or 0.0) + 180.0) % 360
                if not lib.progressBar({ duration = 3000, label = 'Breaking out the tunnel wall', canCancel = true, disable = { move = true, combat = true } }) then return nil, 'Stopped' end
                local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = TEE, x = f.x, y = f.y, z = f.z, heading = heading })
                if not (r and r.ok) then return nil, (r and r.error) or 'Could not break out the wall' end
                local t = { model = TEE, x = f.x, y = f.y, z = f.z, heading = heading }
                if not awaitPiece(TEE, t, 6000) then return nil, 'The new section didn\'t appear — try again' end
                lib.callback.await('opslabs-towers:fixture:delete', false, f.id)
                local ox, oy = toWorld(t, 1.2, 0)
                local dx, dy = dirOf(heading, 1, 0)
                return { x = ox, y = oy, z = f.z, dx = dx, dy = dy }
            end
        end
    end
    return nil, 'Go underground: face an open end, or stand in a tunnel and face its wall'
end

function DigForward()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local target, why = digStart(ped)
    if not target then return lib.notify({ type = 'error', description = why }) end
    local model = TUNNEL
    local ghost, ghostModel, spot
    local function dropGhost() if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end ghost = nil end
    local function makeGhost()
        dropGhost()
        spot = snapped(model, target)
        local h = joaat(model)
        if not IsModelInCdimage(h) then return end
        lib.requestModel(h, 5000)
        ghost = CreateObjectNoOffset(h, spot.x, spot.y, spot.z, false, false, false)
        SetEntityHeading(ghost, spot.heading)
        FreezeEntityPosition(ghost, true)
        SetEntityAlpha(ghost, 140, false)
        SetEntityDrawOutlineColor(48, 209, 88, 255)
        SetEntityDrawOutlineShader(1)
        SetEntityDrawOutline(ghost, true)
        ghostModel = model
    end
    local function openUp()
        DigKey = endKey(target)
        local e = seals[DigKey]
        if e and DoesEntityExist(e) then DeleteEntity(e) end
        seals[DigKey] = nil
    end
    -- anything already at an end (other than the piece just dug)? then we've broken through
    local function occupied(p, except)
        for _, f in pairs(fixtures()) do
            if not (except and math.abs(f.x - except.x) < 0.2 and math.abs(f.y - except.y) < 0.2) then
                local list = f.model == CHAMBER and { { CH, 0 }, { -CH, 0 }, { 0, CH }, { 0, -CH } } or (f.model == TUNNEL or f.model == TEE) and { { 0, SEG / 2 }, { 0, -SEG / 2 } }
                    or f.model == ENTRANCE and { { 0, CH } } or f.model == ENDWALL and { { 0, 0 } } or {}
                for _, q in ipairs(list) do
                    local x, y = toWorld(f, q[1], q[2])
                    if math.abs(x - p.x) < 0.3 and math.abs(y - p.y) < 0.3 and math.abs(f.z - p.z) < 0.5 then return true end
                end
            end
        end
        return false
    end
    openUp()
    makeGhost()
    local sf2 = PlaceHud.buttons({ { 'Walk forward to dig', 32 }, { 'Tunnel / chamber', 47 }, { 'Stop', { 177, 200 } } })
    local built, holds = 0, {}         -- holds: dug pieces whose highlighted copy stays under you until the real one is in
    local done = false
    while not done do
        Wait(0)
        for _, c in ipairs({ 47, 177, 199, 200 }) do DisableControlAction(0, c, true) end
        for i = #holds, 1, -1 do
            local h = holds[i]
            if pieceReady(h.model, h.spot) then
                if DoesEntityExist(h.ent) then DeleteEntity(h.ent) end
                table.remove(holds, i)
            end
        end
        if IsDisabledControlJustPressed(0, 47) then
            model = model == TUNNEL and CHAMBER or TUNNEL
            makeGhost()
        end
        pos = GetEntityCoords(ped)
        local along = (pos.x - target.x) * target.dx + (pos.y - target.y) * target.dy
        if ghost and along > 0.6 then
            local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = ghostModel, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
            if not (r and r.ok) then
                lib.notify({ type = 'error', description = (r and r.error) or 'Could not dig here' })
                done = true
            else
                built = built + 1
                SetEntityDrawOutline(ghost, false)
                holds[#holds + 1] = { ent = ghost, model = ghostModel, spot = spot }
                ghost = nil
                local len = ghostModel == CHAMBER and 2 * CH or SEG
                local nextEnd = { x = target.x + target.dx * len, y = target.y + target.dy * len, z = target.z, dx = target.dx, dy = target.dy }
                if occupied(nextEnd, spot) then
                    lib.notify({ type = 'inform', description = 'You\'ve dug through to another tunnel' })
                    done = true
                else
                    target = nextEnd
                    openUp()
                    makeGhost()                -- the next highlighted section is there straight away
                end
            end
        end
        PlaceHud.draw(sf2, 'Digging a tunnel', ('Next: %s   ·   %d built   ·   walk into the highlighted section'):format(model == TUNNEL and 'tunnel section (4 m)' or 'chamber', built), { 48, 209, 88 })
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then done = true end
    end
    PlaceHud.release(sf2)
    -- don't leave anyone standing on nothing: every dug piece must be really there before its highlighted copy goes
    for _, h in ipairs(holds) do
        awaitPiece(h.model, h.spot, 8000)
        if DoesEntityExist(h.ent) then DeleteEntity(h.ent) end
    end
    dropGhost()
    DigKey = nil
    if built > 0 then lib.notify({ type = 'success', description = ('Dug %d piece(s) — the open end is sealed until you carry on'):format(built) }) end
end

---------------------------------------------------------------------------
-- getting in and out
---------------------------------------------------------------------------
local function text3d(x, y, z, txt)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.35, 0.35) SetTextFont(4) SetTextCentre(true) SetTextOutline()
    SetTextColour(255, 255, 255, 230)
    BeginTextCommandDisplayText('STRING') AddTextComponentSubstringPlayerName(txt) EndTextCommandDisplayText(sx, sy)
end

local function climb(label, x, y, z, heading)
    local ped = PlayerPedId()
    if not lib.progressBar({ duration = 1600, label = label, canCancel = true, disable = { move = true, combat = true, car = true } }) then return end
    DoScreenFadeOut(250)
    Wait(260)
    -- hold still until the ground round the landing spot is there, so you can't drop through on arrival
    FreezeEntityPosition(ped, true)
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, heading)
    RequestCollisionAtCoord(x, y, z)
    local t = GetGameTimer() + 2000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < t do Wait(0) end
    Wait(200)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(300)
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local found = false
        if not IsPedInAnyVehicle(ped, false) then
            for _, f in pairs(fixtures()) do
                if f.model == ENTRANCE and math.abs(pos.x - f.x) < 6.0 and math.abs(pos.y - f.y) < 6.0 then
                    local dx, dy = toWorld(f, ENT_DOOR[1], ENT_DOOR[2])
                    local lx, ly = toWorld(f, ENT_LAND[1], ENT_LAND[2])
                    if pos.z > f.z - 0.5 and pos.z < f.z + 3.0 and math.sqrt((pos.x - dx) ^ 2 + (pos.y - dy) ^ 2) < 1.2 then
                        found = true
                        text3d(dx, dy, f.z + 1.2, '[F] Go down to the tunnels')
                        if IsControlJustPressed(0, 23) then climb('Unlocking the door and going down the stairs', lx, ly, f.z + FLOOR + 1.0, f.heading or 0.0) end
                    elseif pos.z < f.z - 1.0 and pos.z > f.z + FLOOR - 0.5 and math.sqrt((pos.x - lx) ^ 2 + (pos.y - ly) ^ 2) < 1.3 then
                        found = true
                        text3d(lx, ly, f.z + FLOOR + 1.3, '[F] Up the stairs to the street')
                        if IsControlJustPressed(0, 23) then
                            local ox, oy = toWorld(f, ENT_DOOR[1], ENT_DOOR[2] - 0.8)
                            climb('Going up the stairs', ox, oy, (groundAt(ox, oy, f.z) or f.z) + 1.0, ((f.heading or 0.0) + 180.0) % 360)
                        end
                    end
                end
                if f.model == CHAMBER and math.abs(pos.x - f.x) < 6.0 and math.abs(pos.y - f.y) < 6.0 then
                    local hx, hy = toWorld(f, HATCH[1], HATCH[2])
                    if pos.z > f.z - 0.5 and pos.z < f.z + 2.5 and math.sqrt((pos.x - hx) ^ 2 + (pos.y - hy) ^ 2) < 1.1 then
                        found = true
                        local open = DoorIsOpen and DoorIsOpen(f.id, 1)
                        text3d(hx, hy, f.z + 0.6, open and '[F] Climb down' or 'Hatch shut · [E] open it')
                        if open and IsControlJustPressed(0, 23) then
                            local ix, iy = toWorld(f, IRONS[1], IRONS[2])
                            climb('Climbing down the step irons', ix, iy, f.z + FLOOR + 1.0, ((f.heading or 0.0) + 180.0) % 360)
                        end
                    elseif pos.z < f.z - 1.0 and pos.z > f.z + FLOOR - 0.5 then
                        local ix, iy = toWorld(f, IRONS[1], IRONS[2])
                        if math.sqrt((pos.x - ix) ^ 2 + (pos.y - iy) ^ 2) < 1.0 then
                            found = true
                            text3d(ix, iy, f.z + FLOOR + 1.3, '[F] Climb up and out')
                            if IsControlJustPressed(0, 23) then
                                local ox, oy = toWorld(f, HATCH[1], HATCH[2] - 1.0)
                                climb('Climbing up the step irons', ox, oy, (groundAt(ox, oy, f.z) or f.z) + 1.0, ((f.heading or 0.0) + 180.0) % 360)
                            end
                        end
                    end
                end
            end
        end
        Wait(found and 0 or 300)
    end
end)

-- /dig: straight into dig mode when you're standing at an open end underground
RegisterCommand('dig', function()
    if not lib.callback.await('opslabs-towers:cable:can', false) then return lib.notify({ type = 'error', description = 'Only network engineers can dig tunnels' }) end
    DigForward()
end, false)
