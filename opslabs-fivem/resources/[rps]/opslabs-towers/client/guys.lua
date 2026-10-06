-- Guild wires (galvanised steel support strand) between placed poles, on forged J hooks.
--   /cable → Guild wires → Put up a guild wire: aim at each pole in turn (Enter hooks it at the
--   height you aim at), Space finishes. Lash fibre to it from the same menu.
--   Up a pole next to a hook: ↑ / ↓ slide the hook (and any lashed fibre) up and down the pole,
--   Shift for fine steps. Nothing here uses G — that stays the pole equipment menu.

local guys = {}            -- [id] = guy (from the server)
local spawned = {}         -- [id] = { sig, ents }
local UP = vector3(0.0, 0.0, 1.0)
local PIECES = { { 2.0, '200' }, { 1.0, '100' }, { 0.5, '050' }, { 0.25, '025' }, { 0.1, '010' }, { 0.05, '005' } }
local POLE_H = Config.Cabling.PoleHeights
local MAX_SPAN = 60.0
local pending = {}         -- [id .. ':' .. idx] = height being dragged (preview before it's saved)

local function poleRadius(H, z)
    local rb, rt = 0.115 + H * 0.002, 0.075
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, z / H))
end

local function fixture(id) return (CablingFixtures and CablingFixtures() or {})[id] end

--- same maths as the server (server/guys.lua GuyHook)
local function hook(g, i, hOverride)
    local n = #g.points
    local f = fixture(g.points[i].pole)
    local a, b = fixture(g.points[math.max(1, i - 1)].pole), fixture(g.points[math.min(n, i + 1)].pole)
    if not f or not a or not b then return nil end
    local dx, dy = b.x - a.x, b.y - a.y
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1.0, 0.0, 1.0 end
    dx, dy = dx / l, dy / l
    local sx, sy = -dy, dx
    local H = POLE_H[f.model] or 10.0
    local h = hOverride or g.points[i].h
    local r = poleRadius(H, h)
    return { x = f.x + sx * r, y = f.y + sy * r, z = f.z + h, sx = sx, sy = sy, H = H, h = h, pole = f,
        seat = vector3(f.x + sx * (r + 0.055), f.y + sy * (r + 0.055), f.z + h), heading = math.deg(math.atan(sx, -sy)) % 360 }
end

local function spawnProp(list, name, x, y, z, heading)
    local h = joaat(name)
    if not IsModelInCdimage(h) then return end
    lib.requestModel(h, 3000)
    local e = CreateObjectNoOffset(h, x, y, z, false, false, false)
    SetEntityHeading(e, heading or 0.0)
    SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
    SetEntityCollision(e, false, false)
    FreezeEntityPosition(e, true)
    list[#list + 1] = e
end

local function build(g)
    local ents = {}
    local seats = {}
    for i = 1, #g.points do
        local hk = hook(g, i, pending[g.id .. ':' .. i])
        if not hk then return ents end
        spawnProp(ents, 'opslabs_guy_hook', hk.x, hk.y, hk.z, hk.heading)
        seats[i] = hk.seat
    end
    for i = 1, #seats - 1 do
        -- hangs with the same sag as aerial fibre, so lashed fibre follows just under it
        local sp = SpanPoints({ x = seats[i].x, y = seats[i].y, z = seats[i].z, p = 1 }, { x = seats[i + 1].x, y = seats[i + 1].y, z = seats[i + 1].z, p = 1 })
        for k = 1, #sp - 1 do CableFillLine(ents, sp[k], sp[k + 1], UP, PIECES, 'opslabs_guy_seg_') end
        for k = 2, #sp - 1 do CablePlace(ents, 'opslabs_guy_joint', sp[k], vector3(0.0, 1.0, 0.0), UP) end
    end
    return ents
end

local function sigOf(g)
    local t = {}
    for i, p in ipairs(g.points) do
        local f = fixture(p.pole)
        t[#t + 1] = ('%d:%.2f:%s'):format(p.pole, pending[g.id .. ':' .. i] or p.h, f and ('%.2f,%.2f,%.2f'):format(f.x, f.y, f.z) or '-')
    end
    return table.concat(t, '|')
end

local function despawn(id)
    local s = spawned[id]
    if s then for _, e in ipairs(s.ents) do if DoesEntityExist(e) then DeleteEntity(e) end end end
    spawned[id] = nil
end

RegisterNetEvent('opslabs-towers:guys', function(list)
    local new = {}
    for _, g in ipairs(type(list) == 'table' and list or {}) do new[g.id] = g end
    guys = new
    for k in pairs(pending) do pending[k] = nil end
end)

local function bounds(g)
    local sx, sy, sz, n = 0.0, 0.0, 0.0, 0
    for _, p in ipairs(g.points) do
        local f = fixture(p.pole)
        if f then sx, sy, sz, n = sx + f.x, sy + f.y, sz + f.z + p.h, n + 1 end
    end
    if n == 0 then return nil end
    local c = vector3(sx / n, sy / n, sz / n)
    local r = 0.0
    for _, p in ipairs(g.points) do
        local f = fixture(p.pole)
        if f then r = math.max(r, #(c - vector3(f.x, f.y, f.z + p.h))) end
    end
    return c, r
end

-- stream guild wires in / out with the same render range as the rest of the network
CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local want = {}
        for id, g in pairs(guys) do
            local c, r = bounds(g)
            if c and (not RenderInView or RenderInView(pos, c, r, spawned[id] ~= nil)) then want[id] = g end
        end
        for id in pairs(spawned) do if not want[id] then despawn(id) end end
        for id, g in pairs(want) do
            local sig = sigOf(g)
            if not spawned[id] or spawned[id].sig ~= sig then
                despawn(id)
                spawned[id] = { sig = sig, ents = build(g) }
                Wait(0)
            end
        end
        Wait(next(pending) and 100 or 1000)
    end
end)

---------------------------------------------------------------------------
-- ↑ / ↓ on the pole: slide the hook you're next to
---------------------------------------------------------------------------

local function text2d(s, y)
    SetTextFont(4) SetTextScale(0.0, 0.42) SetTextColour(255, 255, 255, 230) SetTextOutline() SetTextCentre(true)
    BeginTextCommandDisplayText('STRING') AddTextComponentSubstringPlayerName(s) EndTextCommandDisplayText(0.5, y)
end

CreateThread(function()
    local active, releasedAt = nil, nil
    while true do
        local c = PoleClimb
        local target = nil
        if c and c.pole and c.pole.id and c.pole.id > 0 and not ClimbPaused and not CableCutActive then
            local chest = c.pole.z + c.h + 1.2
            local bd
            for id, g in pairs(guys) do
                for i, p in ipairs(g.points) do
                    if p.pole == c.pole.id then
                        local hz = c.pole.z + (pending[id .. ':' .. i] or p.h)
                        local d = math.abs(hz - chest)
                        if d < 1.4 and d < (bd or math.huge) then target, bd = { id = id, idx = i, g = g }, d end
                    end
                end
            end
        end
        if not target then
            if active then active = nil end
            Wait(250)
        else
            Wait(0)
            local key = target.id .. ':' .. target.idx
            local hk = hook(target.g, target.idx, pending[key])
            if hk then
                local fine = IsDisabledControlPressed(0, 21)
                local dir = (IsControlPressed(0, 172) and 1 or 0) - (IsControlPressed(0, 173) and 1 or 0)
                local lashed = target.g.fibre_run and ' + fibre' or ''
                text2d(('~y~↑ / ↓~w~  move the guild wire%s hook  ·  %.2f m%s'):format(lashed, hk.h, fine and '  ·  fine' or '   (Shift: fine)'), 0.86)
                DrawMarker(28, hk.seat.x, hk.seat.y, hk.seat.z, 0, 0, 0, 0, 0, 0, 0.05, 0.05, 0.05, 255, 214, 10, 200, false, false, 2, false, nil, nil, false)
                if dir ~= 0 then
                    local chest = c.pole.z + c.h + 1.2
                    local nh = hk.h + dir * (fine and 0.08 or 0.35) * GetFrameTime()
                    nh = math.max(2.0, math.min(hk.H - 0.3, nh))
                    nh = math.max(chest - c.pole.z - 1.3, math.min(chest - c.pole.z + 1.3, nh))   -- within arm's reach
                    pending[key] = nh
                    active, releasedAt = key, nil
                elseif active == key and pending[key] then
                    releasedAt = releasedAt or GetGameTimer()
                    if GetGameTimer() - releasedAt > 350 then                -- let go: fix it there
                        local h = pending[key]
                        active, releasedAt = nil, nil
                        local r = lib.callback.await('opslabs-towers:guys:setHeight', false, target.id, target.idx, h)
                        if r and r.ok then
                            target.g.points[target.idx].h = r.h
                            PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
                        else
                            lib.notify({ type = 'error', description = (r and r.error) or 'Could not move the hook' })
                        end
                        pending[key] = nil
                    end
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- putting one up
---------------------------------------------------------------------------

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

--- the placed pole the camera is pointing at, and the height on it
local function aimedPole()
    local cam, dir = GetGameplayCamCoord(), rotToDir(GetGameplayCamRot(2))
    local best, bd, bh
    for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        local H = POLE_H[f.model]
        if H then
            local to = vector3(f.x, f.y, f.z + H / 2) - cam
            local s = to.x * dir.x + to.y * dir.y + to.z * dir.z
            if s > 0 and s < 120.0 then
                local p = cam + dir * s
                local d = math.sqrt((p.x - f.x) ^ 2 + (p.y - f.y) ^ 2)
                -- distance from the ray to the pole's axis, measured at the pole
                local hz = p.z - f.z
                if d < 0.6 + s * 0.01 and hz > -1.0 and hz < H + 1.0 and d < (bd or math.huge) then
                    best, bd, bh = { id = id, f = f, H = H }, d, math.max(2.0, math.min(H - 0.3, hz))
                end
            end
        end
    end
    return best, bh
end

local function installMode()
    local pts = {}
    local sf = PlaceHud.buttons({ { 'Hook on this pole', 191 }, { 'Finish', 22 }, { 'Undo', 177 }, { 'Cancel', 25 } })
    if Coach then Coach('guy_wire') end
    while true do
        Wait(0)
        for _, ctl in ipairs({ 22, 24, 25, 140, 141, 142, 177, 191, 200 }) do DisableControlAction(0, ctl, true) end
        local pole, h = aimedPole()
        local last = pts[#pts]
        local lastF = last and fixture(last.pole)
        local span = (pole and lastF) and math.sqrt((pole.f.x - lastF.x) ^ 2 + (pole.f.y - lastF.y) ^ 2) or 0
        local okNext = pole and (not last or (last.pole ~= pole.id and span <= MAX_SPAN))
        -- preview: the chosen hooks, and a line on to the aimed pole
        for i = 1, #pts - 1 do
            local a, b = fixture(pts[i].pole), fixture(pts[i + 1].pole)
            if a and b then DrawLine(a.x, a.y, a.z + pts[i].h, b.x, b.y, b.z + pts[i + 1].h, 200, 200, 205, 255) end
        end
        if pole then
            local z = pole.f.z + h
            DrawMarker(28, pole.f.x, pole.f.y, z, 0, 0, 0, 0, 0, 0, 0.18, 0.18, 0.18, okNext and 48 or 255, okNext and 209 or 69, okNext and 88 or 58, 160, false, false, 2, false, nil, nil, false)
            if lastF then DrawLine(lastF.x, lastF.y, lastF.z + last.h, pole.f.x, pole.f.y, z, okNext and 48 or 255, okNext and 209 or 69, okNext and 88 or 58, 255) end
        end
        local sub = pole and (okNext and ('Pole #%d · hook at %.1f m%s'):format(pole.id, h, lastF and ('   ·   span %.0f m'):format(span) or '')
            or (last and last.pole == pole.id and 'Pick the next pole' or ('Span too long — %d m max'):format(MAX_SPAN)))
            or 'Aim at a placed pole (at the height you want the hook)'
        PlaceHud.draw(sf, ('Guild wire · %d pole%s'):format(#pts, #pts == 1 and '' or 's'), sub, { 152, 152, 157 })
        if IsDisabledControlJustPressed(0, 191) and okNext then
            pts[#pts + 1] = { pole = pole.id, h = math.floor(h * 100 + 0.5) / 100 }
            PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
        elseif IsDisabledControlJustPressed(0, 177) then
            if #pts == 0 then break end
            pts[#pts] = nil
        elseif IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 200) then
            pts = {} break
        elseif IsDisabledControlJustPressed(0, 22) then
            if #pts >= 2 then break end
            lib.notify({ type = 'error', description = 'Hook it on to at least two poles' })
        end
    end
    PlaceHud.release(sf)
    if #pts < 2 then return end
    if not lib.progressBar({ duration = 3000 + 1500 * #pts, label = 'Tensioning the guild wire', canCancel = true, disable = { move = true, combat = true } }) then return end
    local r = lib.callback.await('opslabs-towers:guys:create', false, pts)
    if r and r.ok then lib.notify({ type = 'success', description = ('Guild wire up across %d poles · climb a pole and use ↑ / ↓ to adjust a hook'):format(#pts) })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

---------------------------------------------------------------------------
-- menu
---------------------------------------------------------------------------

local function nearbyGuys(radius)
    local pos = GetEntityCoords(PlayerPedId())
    local out = {}
    for id, g in pairs(guys) do
        local bd
        for _, p in ipairs(g.points) do
            local f = fixture(p.pole)
            if f then bd = math.min(bd or math.huge, #(vector2(pos.x, pos.y) - vector2(f.x, f.y))) end
        end
        if bd and bd < radius then out[#out + 1] = { g = g, d = bd } end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function guyMenu(g)
    local poles = {}
    for _, p in ipairs(g.points) do poles[#poles + 1] = ('#%d @ %.1f m'):format(p.pole, p.h) end
    local function act(cb, label, ok)
        local r = lib.callback.await(cb, false, g.id)
        if r and r.ok then lib.notify({ type = 'success', description = ok(r) }) else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    local options = {
        { title = ('Poles: %s'):format(table.concat(poles, ' → ')), icon = 'grip-lines', readOnly = true },
        g.fibre_run and { title = 'Take the lashed fibre off', description = ('Fibre run #%d'):format(g.fibre_run), icon = 'scissors', onSelect = function()
            if lib.alertDialog({ header = 'Remove lashed fibre?', content = 'The fibre run on this guild wire is removed (anything spliced to it goes dark).', cancel = true, centered = true }) == 'confirm' then
                act('opslabs-towers:guys:unlash', 'unlash', function() return 'Fibre taken off the guild wire' end)
            end
        end } or { title = 'Lash fibre to it', description = 'Pulled off a fibre box / drum within 25 m · 3 m tails at each end to splice in', icon = 'link', iconColor = '#30d158', onSelect = function()
            if lib.progressBar({ duration = 6000, label = 'Lashing fibre to the guild wire', canCancel = true, disable = { move = true, combat = true } }) then
                act('opslabs-towers:guys:lash', 'lash', function(r) return ('Fibre lashed (%.0f m) · pick up the loose tails to splice them in'):format(r.length) end)
            end
        end },
        { title = 'Take the guild wire down', icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
            if lib.alertDialog({ header = 'Take the guild wire down?', content = ('Guild wire #%d across %d poles.'):format(g.id, #g.points), cancel = true, centered = true }) == 'confirm' then
                act('opslabs-towers:guys:delete', 'delete', function() return 'Guild wire taken down' end)
            end
        end },
    }
    lib.registerContext({ id = 'opslabs_guy_one', title = ('Guild wire #%d'):format(g.id), menu = 'opslabs_guys', options = options })
    lib.showContext('opslabs_guy_one')
end

function GuyMenu()
    local options = {
        { title = 'Put up a guild wire', description = 'Aim at each pole in turn: Enter hooks it on, Space finishes', icon = 'plus', iconColor = '#30d158', onSelect = function() CreateThread(installMode) end },
    }
    for _, n in ipairs(nearbyGuys(80.0)) do
        options[#options + 1] = { title = ('Guild wire #%d'):format(n.g.id), arrow = true, icon = 'grip-lines',
            description = ('%d poles · %.0f m away%s'):format(#n.g.points, n.d, n.g.fibre_run and ' · fibre lashed' or ''),
            onSelect = function() guyMenu(n.g) end }
    end
    if #options == 1 then options[2] = { title = 'No guild wires within 80 m', readOnly = true } end
    options[#options + 1] = { title = 'Adjusting hooks', description = 'Climb the pole, get next to the hook and use ↑ / ↓ (Shift for fine). Lashed fibre moves with it.', icon = 'circle-info', readOnly = true }
    lib.registerContext({ id = 'opslabs_guys', title = 'Guild wires', options = options })
    lib.showContext('opslabs_guys')
end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then for id in pairs(spawned) do despawn(id) end end
end)
