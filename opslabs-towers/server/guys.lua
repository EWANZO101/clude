-- Guild wires: galvanised steel strand run pole to pole (two or more placed poles) on forged J
-- hooks. Fibre can be lashed to it: that makes a real fibre run hanging just under the strand
-- with a few metres of loose tail at each end to splice into a CBT / joint with the usual tools.
-- Hook heights are moved with ↑ / ↓ while up the pole; a lashed fibre moves with its hook.

local CC = Config.Cabling
Guys = {}                      -- [id] = { id, points = { { pole = fixtureId, h = metres above the pole base } }, fibre_run, created_by }
local POLE_H = { opslabs_pole_07m = 7.0, opslabs_pole_10m = 10.0, opslabs_pole_13m = 13.0, opslabs_pole_metal = 9.0, opslabs_power_pole_10m = 10.0, opslabs_power_pole_12m = 12.0 }
local MAX_SPAN, MAX_POLES, TAIL = 60.0, 12, 3.0

local function poleRadius(H, z)
    local rb, rt = 0.115 + H * 0.002, 0.075
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, z / H))
end

--- where hook i sits: on the side of the pole (left of the line of the wire), and its seat
function GuyHook(g, i)
    local n = #g.points
    local function P(k) local f = Cabling.fixtures[g.points[k].pole] return f end
    local f = P(i)
    if not f then return nil end
    local a, b = P(math.max(1, i - 1)), P(math.min(n, i + 1))
    if not a or not b then return nil end
    local dx, dy = b.x - a.x, b.y - a.y
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1.0, 0.0, 1.0 end
    dx, dy = dx / l, dy / l
    local sx, sy = -dy, dx
    local H, h = POLE_H[f.model] or 10.0, g.points[i].h
    local r = poleRadius(H, h)
    return { x = f.x + sx * r, y = f.y + sy * r, z = f.z + h, sx = sx, sy = sy, seat = vector3(f.x + sx * (r + 0.055), f.y + sy * (r + 0.055), f.z + h),
        heading = math.deg(math.atan(sx, -sy)) % 360, pole = f, H = H }
end

function GuyOnPole(poleId)
    for _, g in pairs(Guys) do for _, p in ipairs(g.points) do if p.pole == poleId then return true end end end
    return false
end

local function broadcast(target)
    local list = {}
    for _, g in pairs(Guys) do list[#list + 1] = g end
    TriggerClientEvent('opslabs-towers:guys', target or -1, list)
end

local function save(g)
    MySQL.update.await('UPDATE opslabs_towers_guys SET points = ?, fibre_run = ? WHERE id = ?', { json.encode(g.points), g.fibre_run, g.id })
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_guys` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `points` TEXT NOT NULL,
        `fibre_run` INT DEFAULT NULL,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_guys') or {}) do
        local ok, pts = pcall(json.decode, r.points)
        if ok and type(pts) == 'table' then Guys[r.id] = { id = r.id, points = pts, fibre_run = r.fibre_run, created_by = r.created_by } end
    end
    Wait(3000)
    broadcast()
end)
RegisterNetEvent('opslabs-towers:ready', function() broadcast(source) end)

-- a deleted pole takes its guild wires with it (the fibre stays, as a cable run)
AddEventHandler('opslabs-towers:fixtureRemoved', function(id)
    for gid, g in pairs(Guys) do
        for _, p in ipairs(g.points) do
            if p.pole == id then
                Guys[gid] = nil
                MySQL.update.await('DELETE FROM opslabs_towers_guys WHERE id = ?', { gid })
                break
            end
        end
    end
    broadcast()
end)

local function nearPole(src, poleId, z, reach)
    local f = Cabling.fixtures[poleId]
    local ped = GetPlayerPed(src)
    if not f or not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    return math.sqrt((c.x - f.x) ^ 2 + (c.y - f.y) ^ 2) <= (reach or 3.0) and (not z or math.abs(c.z - z) <= 3.0)
end

lib.callback.register('opslabs-towers:guys:create', function(src, pts)
    if not CanCable(src) then return { error = 'Only network engineers can put up guild wires' } end
    if type(pts) ~= 'table' or #pts < 2 or #pts > MAX_POLES then return { error = ('A guild wire runs between 2 and %d poles'):format(MAX_POLES) } end
    local clean = {}
    for i, p in ipairs(pts) do
        local id = math.tointeger(tonumber(p.pole))
        local f = id and Cabling.fixtures[id]
        if not f or not POLE_H[f.model] then return { error = 'Guild wires go between placed poles' } end
        if i > 1 and clean[i - 1].pole == id then return { error = 'Pick a different pole for the next hook' } end
        local H = POLE_H[f.model]
        local h = tonumber(p.h) or (H - 1.0)
        h = math.max(2.0, math.min(H - 0.3, h))
        if i > 1 then
            local a = Cabling.fixtures[clean[i - 1].pole]
            if math.sqrt((a.x - f.x) ^ 2 + (a.y - f.y) ^ 2) > MAX_SPAN then return { error = ('Spans can be at most %d m'):format(MAX_SPAN) } end
        end
        clean[i] = { pole = id, h = math.floor(h * 100 + 0.5) / 100 }
    end
    local id = MySQL.insert.await('INSERT INTO opslabs_towers_guys (points, created_by) VALUES (?, ?)', { json.encode(clean), GetPlayerName(src) })
    Guys[id] = { id = id, points = clean, created_by = GetPlayerName(src) }
    print(('[opslabs-towers] %s put up guild wire #%d across %d poles'):format(GetPlayerName(src), id, #clean))
    broadcast()
    return { ok = true, id = id }
end)

--- move hook idx up / down (the player must be up that pole, within reach)
lib.callback.register('opslabs-towers:guys:setHeight', function(src, id, idx, h)
    if not CanCable(src) then return { error = 'not allowed' } end
    local g = Guys[tonumber(id)]
    idx = math.tointeger(tonumber(idx))
    local p = g and idx and g.points[idx]
    if not p then return { error = 'That guild wire is gone' } end
    local f = Cabling.fixtures[p.pole]
    if not f then return { error = 'The pole is gone' } end
    local H = POLE_H[f.model] or 10.0
    h = tonumber(h)
    if not h then return { error = 'bad height' } end
    h = math.max(2.0, math.min(H - 0.3, h))
    if not nearPole(src, p.pole, f.z + h) then return { error = 'Get up the pole next to the hook first' } end
    local old = p.h
    p.h = math.floor(h * 100 + 0.5) / 100
    save(g)
    -- the lashed fibre hangs off this hook: move its fixing on this pole too
    local r = g.fibre_run and Cabling.runs[g.fibre_run]
    if r then
        local hk = GuyHook(g, idx)
        local moved = false
        for _, q in ipairs(r.points or {}) do
            if q.p == p.pole and math.abs(q.z - (f.z + old - 0.05)) < 0.6 then
                q.x, q.y, q.z = hk.seat.x, hk.seat.y, hk.seat.z - 0.05
                moved = true
            end
        end
        if moved then
            MySQL.update.await('UPDATE opslabs_towers_cables SET points = ? WHERE id = ?', { json.encode(r.points), r.id })
            CablingChanged()
        end
    end
    broadcast()
    return { ok = true, h = p.h }
end)

--- lash fibre to the strand, pulled off a fibre box / drum within 25 m
lib.callback.register('opslabs-towers:guys:lash', function(src, id)
    if not CanCable(src) then return { error = 'Only network engineers can lash fibre' } end
    local g = Guys[tonumber(id)]
    if not g then return { error = 'That guild wire is gone' } end
    if g.fibre_run and Cabling.runs[g.fibre_run] then return { error = 'There is already fibre lashed to this guild wire' } end
    local ped = GetPlayerPed(src)
    local c = GetEntityCoords(ped)
    local pts, length = {}, 0.0
    for i = 1, #g.points do
        local hk = GuyHook(g, i)
        if not hk then return { error = 'A pole on this guild wire is missing' } end
        pts[i] = { x = hk.seat.x, y = hk.seat.y, z = hk.seat.z - 0.05, nx = hk.sx, ny = hk.sy, nz = 0.0, p = g.points[i].pole }
        if i > 1 then length = length + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) * 1.02 end
    end
    local need = length + TAIL * 2
    local box, bd
    for _, b in pairs(Cabling.boxes) do
        local kind = b.kind or 'cat6'
        if kind ~= 'cat6' and b.remaining >= need then
            local d = math.sqrt((b.x - c.x) ^ 2 + (b.y - c.y) ^ 2 + (b.z - c.z) ^ 2)
            if d < (bd or 25.0) then box, bd = b, d end
        end
    end
    if not box then return { error = ('Put a fibre box or drum with at least %.0f m on it within 25 m'):format(need) } end
    box.remaining = math.max(0, box.remaining - need)
    MySQL.update.await('UPDATE opslabs_towers_cable_boxes SET remaining = ? WHERE id = ?', { box.remaining, box.id })
    local color = (box.kind == 'drop') and 'ulw' or (box.kind or ''):match('^fibre_(%a+)$') or 'black'
    local loose = { start = { len = TAIL }, ['end'] = { len = TAIL } }
    local rid = MySQL.insert.await('INSERT INTO opslabs_towers_cables (kind, color, points, length, box_id, loose, created_by) VALUES (?, ?, ?, ?, NULL, ?, ?)',
        { 'fibre', color, json.encode(pts), need, CablingLooseJson(loose), GetPlayerName(src) })
    Cabling.runs[rid] = { id = rid, kind = 'fibre', color = color, points = pts, length = need, box_id = nil, start_term = false, end_term = false,
        loose = loose, created_by = GetPlayerName(src) }
    g.fibre_run = rid
    save(g)
    print(('[opslabs-towers] %s lashed fibre run #%d to guild wire #%d'):format(GetPlayerName(src), rid, g.id))
    CablingChanged()
    broadcast()
    return { ok = true, run = rid, length = need }
end)

lib.callback.register('opslabs-towers:guys:unlash', function(src, id)
    if not CanCable(src) then return { error = 'not allowed' } end
    local g = Guys[tonumber(id)]
    if not g or not g.fibre_run then return { error = 'No fibre on this guild wire' } end
    if Cabling.runs[g.fibre_run] then CablingDeleteRuns({ g.fibre_run }, src) end
    g.fibre_run = nil
    save(g)
    broadcast()
    return { ok = true }
end)

lib.callback.register('opslabs-towers:guys:delete', function(src, id)
    if not CanCable(src) then return { error = 'not allowed' } end
    local g = Guys[tonumber(id)]
    if not g then return { error = 'That guild wire is gone' } end
    if g.fibre_run and Cabling.runs[g.fibre_run] then return { error = 'Take the lashed fibre off first' } end
    Guys[g.id] = nil
    MySQL.update.await('DELETE FROM opslabs_towers_guys WHERE id = ?', { g.id })
    broadcast()
    return { ok = true }
end)
