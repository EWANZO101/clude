-- CAT6 cabling: cable boxes, cable runs and trunking, saved in the database and
-- shown to every player. A cable run is a list of points stuck to surfaces
-- (position + surface normal). Runs start out of a 305 m box; when both ends are
-- terminated into towers they link those devices (used for Wi-Fi uplinks).

local CC = Config.Cabling
Cabling = { boxes = {}, runs = {}, fixtures = {} }
Uplinked = {}            -- tower id -> true when it has a cabled path to a gateway
local ready = false

local function bool(v) return v == true or v == 1 or v == '1' end

local function decodeRun(r)
    r.points = json.decode(r.points or '[]') or {}
    r.start_term, r.end_term = bool(r.start_term), bool(r.end_term)
    r.length = tonumber(r.length) or 0
    -- cut ends lying loose: { start = { len, at? }, ['end'] = { len, at? } }
    r.loose = r.loose and r.loose ~= '' and json.decode(r.loose) or nil
    return r
end

local function looseJson(l) return (l and next(l)) and json.encode(l) or nil end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_cable_boxes` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `heading` FLOAT NOT NULL DEFAULT 0,
        `remaining` FLOAT NOT NULL DEFAULT 305,
        `kind` VARCHAR(16) NOT NULL DEFAULT 'cat6',
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_cables` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `kind` VARCHAR(8) NOT NULL DEFAULT 'cable',
        `color` VARCHAR(12) NOT NULL DEFAULT 'black',
        `points` LONGTEXT NOT NULL,
        `length` FLOAT NOT NULL DEFAULT 0,
        `box_id` INT DEFAULT NULL,
        `start_tower` INT DEFAULT NULL,
        `end_tower` INT DEFAULT NULL,
        `start_term` TINYINT(1) NOT NULL DEFAULT 0,
        `end_term` TINYINT(1) NOT NULL DEFAULT 0,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_fixtures` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `model` VARCHAR(60) NOT NULL,
        `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `heading` FLOAT NOT NULL DEFAULT 0,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    -- boxes table from before fibre boxes existed (MySQL has no ADD COLUMN IF NOT EXISTS)
    local hasKind = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers_cable_boxes' AND COLUMN_NAME = 'kind']])
    if (tonumber(hasKind) or 0) == 0 then
        MySQL.query.await("ALTER TABLE opslabs_towers_cable_boxes ADD COLUMN `kind` VARCHAR(16) NOT NULL DEFAULT 'cat6' AFTER `remaining`")
    end
    -- cable ends can plug into equipment (ONT, CBT, cabinets...) as well as routers / APs
    for _, col in ipairs({ 'start_fixture', 'end_fixture', 'loose' }) do
        local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers_cables' AND COLUMN_NAME = ?]], { col })
        if (tonumber(has) or 0) == 0 then
            MySQL.query.await(('ALTER TABLE opslabs_towers_cables ADD COLUMN `%s` %s DEFAULT NULL'):format(col, col == 'loose' and 'TEXT' or 'INT'))
        end
    end
    -- per-item settings (sign text, traffic light phase)
    local hasData = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers_fixtures' AND COLUMN_NAME = 'data']])
    if (tonumber(hasData) or 0) == 0 then MySQL.query.await('ALTER TABLE opslabs_towers_fixtures ADD COLUMN `data` TEXT DEFAULT NULL') end
    for _, f in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_fixtures') or {}) do
        f.data = f.data and json.decode(f.data) or nil
        Cabling.fixtures[f.id] = f
    end
    for _, b in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_cable_boxes') or {}) do Cabling.boxes[b.id] = b end
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_cables') or {}) do Cabling.runs[r.id] = decodeRun(r) end
    ready = true
    RecomputeUplinks()
end)

---------------------------------------------------------------------------
-- uplinks: Wi-Fi towers whose prop is a gateway, and everything cabled to them
---------------------------------------------------------------------------

local function isGateway(t)
    if not t or t.type ~= 'wifi' or not t.prop then return false end
    for _, m in ipairs(CC.Gateways or {}) do if t.model == m then return true end end
    return false
end

function RecomputeUplinks()
    local adj = {}
    for _, r in pairs(Cabling.runs) do
        if r.kind ~= 'trunk' and r.start_term and r.end_term and r.start_tower and r.end_tower then
            adj[r.start_tower] = adj[r.start_tower] or {}
            adj[r.end_tower] = adj[r.end_tower] or {}
            table.insert(adj[r.start_tower], r.end_tower)
            table.insert(adj[r.end_tower], r.start_tower)
        end
    end
    local up, queue = {}, {}
    for id, t in pairs(Towers or {}) do
        if isGateway(t) and t.active and (not IspGatewayOnline or IspGatewayOnline(id)) then up[id] = true; queue[#queue + 1] = id end
    end
    while #queue > 0 do
        local id = table.remove(queue)
        for _, nb in ipairs(adj[id] or {}) do
            if not up[nb] then up[nb] = true; queue[#queue + 1] = nb end
        end
    end
    Uplinked = up
    -- on the fibre network: cabled (through any switches / APs) to a gateway whose WAN reaches a live ONT
    local fibre = {}
    queue = {}
    for id, t in pairs(Towers or {}) do
        if isGateway(t) and t.active and IspGatewayLive and IspGatewayLive(id) then fibre[id] = true; queue[#queue + 1] = id end
    end
    while #queue > 0 do
        local id = table.remove(queue)
        for _, nb in ipairs(adj[id] or {}) do
            if not fibre[nb] then fibre[nb] = true; queue[#queue + 1] = nb end
        end
    end
    OnFibre = fibre
end
OnFibre = {}

--- fibre-only Wi-Fi (the access point's "Only online when on the fibre network" option)
function WifiOnFibre(id) return OnFibre[id] == true end
lib.callback.register('opslabs-towers:wifiFibre', function(_, id) return OnFibre[tonumber(id)] == true end)

--- used by ComputeCoverage when Config.Cabling.RequireUplink is on
function WifiHasUplink(id)
    if not CC.RequireUplink then return true end
    return Uplinked[id] == true
end

---------------------------------------------------------------------------
-- sync
---------------------------------------------------------------------------

local function payload()
    local boxes, runs, fixtures = {}, {}, {}
    for _, b in pairs(Cabling.boxes) do boxes[#boxes + 1] = b end
    for _, r in pairs(Cabling.runs) do runs[#runs + 1] = r end
    for _, f in pairs(Cabling.fixtures) do fixtures[#fixtures + 1] = f end
    return { boxes = boxes, runs = runs, fixtures = fixtures }
end

function BroadcastCabling(target)
    TriggerClientEvent('opslabs-towers:cabling', target or -1, payload())
end

RegisterNetEvent('opslabs-towers:ready', function() BroadcastCabling(source) end)

local function changed()
    if RecomputeIsp then RecomputeIsp() end
    RecomputeUplinks()
    BroadcastCabling()
end
CablingChanged = changed
-- towers change (gateway added, AP moved...) can change who has an uplink
AddEventHandler('opslabs-towers:towersChanged', function() RecomputeUplinks() end)

---------------------------------------------------------------------------
-- permissions + validation
---------------------------------------------------------------------------

local function canCable(src)
    if IsTowerAdmin(src) then return true end
    local job = FW.Job(src)
    for _, j in ipairs(CC.Jobs or {}) do if j == job then return true end end
    return false
end
CanCable = canCable

-- models that carry a live brand board (Config: branded = true)
BRANDED = {}
for _, e in ipairs(CC.Equipment or {}) do
    if e.branded then
        BRANDED[e.model] = true
        for _, sz in ipairs(e.sizes or {}) do BRANDED[sz.model] = true end
    end
end

local function num(v) v = tonumber(v); return v and v == v and math.abs(v) < 100000 and v or nil end

local function cleanPoints(points)
    if type(points) ~= 'table' or #points < 2 or #points > 300 then return nil, 'a run needs 2-300 points' end
    local out, length = {}, 0.0
    for i, p in ipairs(points) do
        local x, y, z, nx, ny, nz = num(p.x), num(p.y), num(p.z), num(p.nx) or 0.0, num(p.ny) or 0.0, num(p.nz) or 1.0
        if not (x and y and z) then return nil, 'bad point' end
        local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
        if nl < 0.01 then nx, ny, nz, nl = 0.0, 0.0, 1.0, 1.0 end
        out[i] = { x = x, y = y, z = z, nx = nx / nl, ny = ny / nl, nz = nz / nl, t = tonumber(p.t) or nil, p = tonumber(p.p) or nil }
        if i > 1 then
            local a = out[i - 1]
            local d = math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2)
            if d > 60 then return nil, 'points too far apart' end
            length = length + d
        end
    end
    return out, length
end

lib.callback.register('opslabs-towers:cable:can', function(src) return canCable(src) end)

lib.callback.register('opslabs-towers:cable:placeBox', function(src, d)
    if not canCable(src) or type(d) ~= 'table' then return { error = 'not allowed' } end
    local x, y, z = num(d.x), num(d.y), num(d.z)
    if not (x and y and z) then return { error = 'bad position' } end
    local kind, length = 'cat6', CC.BoxLength
    local fc = type(d.kind) == 'string' and d.kind:match('^fibre_(%a+)$')
    if d.kind == 'drop' then
        kind, length = 'drop', CC.DropDrumLength or 500
    elseif fc then
        if not (CC.FibreBoxLength or {})[fc] then return { error = 'unknown box' } end
        kind, length = d.kind, CC.FibreBoxLength[fc]
    end
    local id = MySQL.insert.await('INSERT INTO opslabs_towers_cable_boxes (x, y, z, heading, remaining, kind, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { x, y, z, num(d.heading) or 0.0, length, kind, GetPlayerName(src) })
    Cabling.boxes[id] = { id = id, x = x, y = y, z = z, heading = num(d.heading) or 0.0, remaining = length, kind = kind, created_by = GetPlayerName(src) }
    changed()
    return { ok = true, box = Cabling.boxes[id] }
end)

-- per-player undo stash of removed boxes / runs (in memory, last 20 removals)
local Stash = {}
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function stash(src, kind, rows)
    if not src or #rows == 0 then return end
    Stash[src] = Stash[src] or {}
    table.insert(Stash[src], { kind = kind, rows = rows })
    while #Stash[src] > 20 do table.remove(Stash[src], 1) end
end
AddEventHandler('playerDropped', function() Stash[source] = nil end)

local function deleteBoxes(ids, src)
    local n, rows = 0, {}
    for _, id in ipairs(ids) do
        id = tonumber(id)
        if id and Cabling.boxes[id] then
            rows[#rows + 1] = copy(Cabling.boxes[id])
            MySQL.update.await('DELETE FROM opslabs_towers_cable_boxes WHERE id = ?', { id })
            MySQL.update.await('UPDATE opslabs_towers_cables SET box_id = NULL WHERE box_id = ?', { id })
            Cabling.boxes[id] = nil
            for _, r in pairs(Cabling.runs) do if r.box_id == id then r.box_id = nil end end
            n = n + 1
        end
    end
    stash(src, 'box', rows)
    if n > 0 then changed() end
    return n
end

lib.callback.register('opslabs-towers:cable:deleteBox', function(src, id)
    if not canCable(src) then return false end
    return deleteBoxes({ id }, src) > 0
end)

--- several at once: { ids }
lib.callback.register('opslabs-towers:cable:deleteBoxes', function(src, ids)
    if not canCable(src) or type(ids) ~= 'table' then return 0 end
    return deleteBoxes(ids, src)
end)

--- move a box; cable still on it follows (exit = the new pull-out hole, worked out by the client)
lib.callback.register('opslabs-towers:cable:moveBox', function(src, id, d, exit)
    if not canCable(src) or type(d) ~= 'table' or type(exit) ~= 'table' then return { error = 'not allowed' } end
    local b = Cabling.boxes[tonumber(id)]
    if not b then return { error = 'not found' } end
    local x, y, z = num(d.x), num(d.y), num(d.z)
    if not (x and y and z) then return { error = 'bad position' } end
    -- work out the new routes first: cable still on the box pays out (or feeds back in)
    local updates, delta = {}, 0.0
    for _, r in pairs(Cabling.runs) do
        if r.box_id == b.id and #r.points >= 2 then
            local pts = copy(r.points)
            pts[1] = { x = num(exit.x) or x, y = num(exit.y) or y, z = num(exit.z) or z, nx = 0.0, ny = 0.0, nz = 1.0 }
            local clean, length = cleanPoints(pts)
            if clean then
                updates[#updates + 1] = { r = r, points = clean, length = length }
                delta = delta + (length - r.length)
            end
        end
    end
    if delta > b.remaining then return { error = ('Not enough cable left in the box to move it that far (%.0f m left)'):format(b.remaining) } end
    b.x, b.y, b.z, b.heading = x, y, z, (num(d.heading) or b.heading) % 360
    b.remaining = math.max(0.0, b.remaining - delta)
    MySQL.update.await('UPDATE opslabs_towers_cable_boxes SET x = ?, y = ?, z = ?, heading = ?, remaining = ? WHERE id = ?', { b.x, b.y, b.z, b.heading, b.remaining, b.id })
    for _, u in ipairs(updates) do
        u.r.points, u.r.length = u.points, u.length
        MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ? WHERE id = ?', { json.encode(u.points), u.length, u.r.id })
    end
    changed()
    return { ok = true }
end)

--- save a laid cable or trunking run. d: { kind, color, points, box_id, end_tower }
lib.callback.register('opslabs-towers:cable:saveRun', function(src, d)
    if not canCable(src) or type(d) ~= 'table' then return { error = 'not allowed' } end
    local kind = (d.kind == 'trunk' or d.kind == 'fibre' or d.kind == 'power' or d.kind == 'copper') and d.kind or 'cable'
    local points, length = cleanPoints(d.points)
    if not points then return { error = length } end
    local color = 'black'
    if kind == 'trunk' then
        color = 'white'
        for _, c in ipairs(CC.TrunkColors) do if c == d.color then color = c end end
    elseif kind == 'fibre' then
        if length > (CC.MaxFibreLength or 1000) + 0.5 then return { error = 'fibre run too long' } end
    elseif kind == 'power' then
        color = 'lv'
        for _, c in ipairs(CC.PowerColors or {}) do if c == d.color then color = c end end
        if length > (CC.MaxPowerLength or 600) + 0.5 then return { error = 'power run too long' } end
    elseif kind == 'copper' then
        color = 'drop'
        for _, c in ipairs(CC.CopperColors or {}) do if c == d.color then color = c end end
        if length > (CC.MaxCopperLength or 800) + 0.5 then return { error = 'phone cable run too long' } end
    end
    local boxId, dropLoose = nil, nil
    if kind == 'cable' or kind == 'fibre' then
        if kind == 'cable' and length > CC.MaxRunLength + 0.5 then return { error = ('runs can be at most %dm'):format(CC.MaxRunLength) } end
        local box = Cabling.boxes[tonumber(d.box_id) or -1]
        if not box then return { error = 'pull the cable from a box' } end
        local boxKind = box.kind or 'cat6'
        if kind == 'cable' and boxKind ~= 'cat6' then return { error = 'that is a fibre box' } end
        if kind == 'fibre' then
            color = boxKind == 'drop' and 'ulw' or boxKind:match('^fibre_(%a+)$')
            if not color then return { error = 'that is a CAT6 box' } end
        end
        -- put down part-way: the end lies loose on the ground (slack from the last fixing to where it was left)
        if type(d.drop) == 'table' then
            local len = math.max(0.3, math.min(60.0, num(d.drop.len) or 0.3))
            local at = type(d.drop.at) == 'table' and num(d.drop.at.x) and num(d.drop.at.y) and num(d.drop.at.z)
                and { x = num(d.drop.at.x), y = num(d.drop.at.y), z = num(d.drop.at.z) } or nil
            local last = points[#points]
            if at and math.sqrt((at.x - last.x) ^ 2 + (at.y - last.y) ^ 2) > len + 1.5 then at = nil end
            dropLoose = { ['end'] = { len = len, at = at } }
            length = length + len
        end
        if box.remaining < length then return { error = ('only %.0fm left in this box'):format(box.remaining) } end
        box.remaining = math.max(0, box.remaining - length)
        MySQL.update.await('UPDATE opslabs_towers_cable_boxes SET remaining = ? WHERE id = ?', { box.remaining, box.id })
        boxId = box.id
    end
    local endTower = Towers[tonumber(d.end_tower) or -1] and tonumber(d.end_tower) or nil
    local endFixture = (kind ~= 'trunk' and not endTower and Cabling.fixtures[tonumber(d.end_fixture) or -1]) and tonumber(d.end_fixture) or nil
    if dropLoose then endTower, endFixture = nil, nil end
    local id = MySQL.insert.await('INSERT INTO opslabs_towers_cables (kind, color, points, length, box_id, end_tower, end_fixture, loose, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { kind, color, json.encode(points), length, boxId, endTower, endFixture, looseJson(dropLoose), GetPlayerName(src) })
    Cabling.runs[id] = { id = id, kind = kind, color = color, points = points, length = length, box_id = boxId, end_tower = endTower, end_fixture = endFixture,
        start_term = false, end_term = false, loose = dropLoose, created_by = GetPlayerName(src) }
    print(('[opslabs-towers] %s laid %s run #%d (%.1fm)'):format(GetPlayerName(src), kind, id, length))
    changed()
    return { ok = true, run = Cabling.runs[id] }
end)

--- cut the cable from its box: the box end becomes the first laid point (to terminate at the router)
lib.callback.register('opslabs-towers:cable:cut', function(src, id)
    if not canCable(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(id)]
    if not r or r.kind == 'trunk' then return { error = 'not found' } end
    if not r.box_id then return { ok = true, run = r } end
    if #r.points > 2 then table.remove(r.points, 1) end   -- drop the box exit point
    r.box_id = nil
    MySQL.update.await('UPDATE opslabs_towers_cables SET box_id = NULL, points = ? WHERE id = ?', { json.encode(r.points), r.id })
    changed()
    return { ok = true, run = r }
end)

--- cut a run anywhere along its length: it becomes two runs with bare ends at the cut.
--- seg = segment index (points[seg] -> points[seg + 1]), at = where the player cut
lib.callback.register('opslabs-towers:cable:split', function(src, id, seg, at)
    if not canCable(src) or type(at) ~= 'table' then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(id)]
    if not r then return { error = 'not found' } end
    seg = math.tointeger(tonumber(seg))
    if not seg or seg < 1 or seg >= #r.points then return { error = 'bad cut' } end
    local x, y, z = num(at.x), num(at.y), num(at.z)
    if not (x and y and z) then return { error = 'bad cut' } end
    local a, b = r.points[seg], r.points[seg + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local L2 = dx * dx + dy * dy + dz * dz
    local t = L2 > 0 and math.max(0.0, math.min(1.0, ((x - a.x) * dx + (y - a.y) * dy + (z - a.z) * dz) / L2)) or 0.0
    local cut = { x = a.x + dx * t, y = a.y + dy * t, z = a.z + dz * t, nx = a.nx, ny = a.ny, nz = a.nz, t = (a.t and a.t == b.t) and a.t or nil }
    -- aerial spans sag below the straight line between their ends, so allow for the droop
    if math.sqrt((cut.x - x) ^ 2 + (cut.y - y) ^ 2 + (cut.z - z) ^ 2) > 1.0 + 0.04 * math.sqrt(L2) then return { error = 'too far from the cable' } end
    local function len(pts)
        local l = 0.0
        for i = 2, #pts do l = l + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) end
        return l
    end
    if r.kind ~= 'trunk' then
        -- a cut cable goes loose: each side drops from its last fixing with the cut-free length
        local tA = math.sqrt((cut.x - a.x) ^ 2 + (cut.y - a.y) ^ 2 + (cut.z - a.z) ^ 2)
        local tB = math.sqrt((b.x - cut.x) ^ 2 + (b.y - cut.y) ^ 2 + (b.z - cut.z) ^ 2)
        if tA < 0.1 or tB < 0.1 then return { error = 'too close to a fixing — cut further along' } end
        local first, second = {}, {}
        for i = 1, seg do first[#first + 1] = r.points[i] end
        for i = seg + 1, #r.points do second[#second + 1] = r.points[i] end
        local oldLoose = r.loose or {}
        local looseA = { start = oldLoose.start, ['end'] = { len = tA } }
        local looseB = { start = { len = tB }, ['end'] = oldLoose['end'] }
        local function total(pts, l) return len(pts) + ((l.start and l.start.len) or 0) + ((l['end'] and l['end'].len) or 0) end
        local l1, l2 = total(first, looseA), total(second, looseB)
        local endTerm, endTower, endFixture = r.end_term, r.end_tower, r.end_fixture
        r.points, r.length, r.end_term, r.end_tower, r.end_fixture, r.loose = first, l1, false, nil, nil, looseA
        MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ?, end_term = 0, end_tower = NULL, end_fixture = NULL, loose = ? WHERE id = ?',
            { json.encode(first), l1, looseJson(looseA), r.id })
        local nid = MySQL.insert.await('INSERT INTO opslabs_towers_cables (kind, color, points, length, box_id, end_tower, end_fixture, end_term, loose, created_by) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)',
            { r.kind, r.color, json.encode(second), l2, endTower, endFixture, endTerm and 1 or 0, looseJson(looseB), GetPlayerName(src) })
        Cabling.runs[nid] = { id = nid, kind = r.kind, color = r.color, points = second, length = l2, box_id = nil, end_tower = endTower, end_fixture = endFixture,
            start_term = false, end_term = endTerm, loose = looseB, created_by = GetPlayerName(src) }
        print(('[opslabs-towers] %s cut %s run #%d -> #%d + #%d (ends loose)'):format(GetPlayerName(src), r.kind, r.id, r.id, nid))
        changed()
        return { ok = true, a = r, b = Cabling.runs[nid] }
    end

    local first, second = {}, { cut }
    for i = 1, seg do first[#first + 1] = r.points[i] end
    first[#first + 1] = cut
    for i = seg + 1, #r.points do second[#second + 1] = r.points[i] end
    local l1, l2 = len(first), len(second)
    if l1 < 0.1 or l2 < 0.1 then return { error = 'too close to the end — cut further along' } end

    local endTerm, endTower, endFixture = r.end_term, r.end_tower, r.end_fixture
    r.points, r.length, r.end_term, r.end_tower, r.end_fixture = first, l1, false, nil, nil
    MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ?, end_term = 0, end_tower = NULL, end_fixture = NULL WHERE id = ?', { json.encode(first), l1, r.id })
    local nid = MySQL.insert.await('INSERT INTO opslabs_towers_cables (kind, color, points, length, box_id, end_tower, end_fixture, end_term, created_by) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?)',
        { r.kind, r.color, json.encode(second), l2, endTower, endFixture, endTerm and 1 or 0, GetPlayerName(src) })
    Cabling.runs[nid] = { id = nid, kind = r.kind, color = r.color, points = second, length = l2, box_id = nil, end_tower = endTower, end_fixture = endFixture,
        start_term = false, end_term = endTerm, created_by = GetPlayerName(src) }
    print(('[opslabs-towers] %s cut %s run #%d -> #%d + #%d'):format(GetPlayerName(src), r.kind, r.id, r.id, nid))
    changed()
    return { ok = true, a = r, b = Cabling.runs[nid] }
end)

--- a loose end was picked up. add = new fixing points from the fixed end outwards;
--- action 'fix' (the end is fixed at the last point) or 'drop' (it lies loose at `at`)
lib.callback.register('opslabs-towers:cable:loose', function(src, id, which, add, action, at)
    if not canCable(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(id)]
    if not r or not r.loose or (which ~= 'start' and which ~= 'end') or not r.loose[which] then return { error = 'That end isn’t loose any more' } end
    if type(add) ~= 'table' or #add > 120 then return { error = 'bad route' } end
    local anchor = which == 'end' and r.points[#r.points] or r.points[1]
    local route = { anchor }
    for _, p in ipairs(add) do route[#route + 1] = p end
    local extra = 0.0
    if #route >= 2 then
        local clean, l = cleanPoints(route)
        if not clean then return { error = l } end
        route, extra = clean, l
    end
    local slack = r.loose[which].len or 0
    local box = which == 'end' and r.box_id and Cabling.boxes[r.box_id] or nil   -- still on its box: more pays out
    local fromBox = 0.0
    if extra > slack + 0.15 then
        if not box or extra > slack + box.remaining then
            return { error = box and ('Not enough cable — only %.0f m left on the box'):format(slack + box.remaining) or ('Not enough cable — only %.1f m is loose'):format(slack) }
        end
        fromBox = extra - slack
    end
    local newPts = {}
    if which == 'end' then
        for _, p in ipairs(r.points) do newPts[#newPts + 1] = p end
        for i = 2, #route do newPts[#newPts + 1] = route[i] end
    else
        for i = #route, 2, -1 do newPts[#newPts + 1] = route[i] end
        for _, p in ipairs(r.points) do newPts[#newPts + 1] = p end
    end
    if action == 'drop' then
        local x, y, z = type(at) == 'table' and num(at.x), type(at) == 'table' and num(at.y), type(at) == 'table' and num(at.z)
        local tip = which == 'end' and newPts[#newPts] or newPts[1]
        local remaining = math.max(0.2, slack - extra - fromBox)
        if x and y and z and box then                                -- walked further than the slack: pull it off the box
            local want = math.sqrt((x - tip.x) ^ 2 + (y - tip.y) ^ 2) + math.max(0.0, tip.z - z) + 0.5
            if want > remaining then
                local more = math.min(want - remaining, box.remaining - fromBox)
                fromBox, remaining = fromBox + more, remaining + more
            end
        end
        local place = (x and y and z and math.sqrt((x - tip.x) ^ 2 + (y - tip.y) ^ 2) <= remaining + 1.5) and { x = x, y = y, z = z } or nil
        r.loose[which] = { len = remaining, at = place }
    else
        r.loose[which] = nil                                         -- spare length coiled at the fixing
    end
    if not next(r.loose) then r.loose = nil end
    r.points = newPts
    if box and fromBox > 0 then
        box.remaining = math.max(0.0, box.remaining - fromBox)
        r.length = (r.length or 0) + fromBox
        MySQL.update.await('UPDATE opslabs_towers_cable_boxes SET remaining = ? WHERE id = ?', { box.remaining, box.id })
    end
    MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ?, loose = ? WHERE id = ?', { json.encode(newPts), r.length, looseJson(r.loose), r.id })
    changed()
    return { ok = true, run = r }
end)

--- an end was terminated (the client ran the strip / arrange / crimp steps). which = 'start' | 'end'
lib.callback.register('opslabs-towers:cable:terminate', function(src, id, which, towerId, fixtureId)
    if not canCable(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(id)]
    if not r or r.kind == 'trunk' or r.kind == 'power' then return { error = 'not found' } end
    if which == 'start' and r.box_id then return { error = 'cut the cable from the box first' } end
    if r.loose and r.loose[which] then return { error = 'That end is lying loose — pick it up and fix it first' } end
    towerId = Towers[tonumber(towerId) or -1] and tonumber(towerId) or nil
    fixtureId = (not towerId and Cabling.fixtures[tonumber(fixtureId) or -1]) and tonumber(fixtureId) or nil
    if which == 'start' then
        r.start_term, r.start_tower, r.start_fixture = true, towerId, fixtureId
        MySQL.update.await('UPDATE opslabs_towers_cables SET start_term = 1, start_tower = ?, start_fixture = ? WHERE id = ?', { towerId, fixtureId, r.id })
    else
        r.end_term, r.end_tower, r.end_fixture = true, towerId, fixtureId
        MySQL.update.await('UPDATE opslabs_towers_cables SET end_term = 1, end_tower = ?, end_fixture = ? WHERE id = ?', { towerId, fixtureId, r.id })
    end
    print(('[opslabs-towers] %s terminated the %s of cable #%d%s'):format(GetPlayerName(src), which, r.id,
        towerId and (' into tower #' .. towerId) or fixtureId and (' into ' .. Cabling.fixtures[fixtureId].model .. ' #' .. fixtureId) or ''))
    changed()
    return { ok = true, run = r }
end)

local function deleteRuns(ids, src)
    local n, gone, rows = 0, {}, {}
    for _, id in ipairs(ids) do
        id = tonumber(id)
        local r = id and Cabling.runs[id]
        if r then
            rows[#rows + 1] = copy(r)
            MySQL.update.await('DELETE FROM opslabs_towers_cables WHERE id = ?', { id })
            Cabling.runs[id] = nil
            if r.kind == 'trunk' then gone[id] = true end
            n = n + 1
        end
    end
    -- cable that was tucked inside removed trunking is out in the open again
    if next(gone) then
        for _, r in pairs(Cabling.runs) do
            local touched = false
            for _, p in ipairs(r.points or {}) do
                if p.t and gone[p.t] then p.t = nil touched = true end
            end
            if touched then MySQL.update.await('UPDATE opslabs_towers_cables SET points = ? WHERE id = ?', { json.encode(r.points), r.id }) end
        end
    end
    stash(src, 'run', rows)
    if n > 0 then changed() end
    return n
end
CablingDeleteRuns = deleteRuns
CablingLooseJson = looseJson

lib.callback.register('opslabs-towers:cable:deleteRun', function(src, id)
    if not canCable(src) then return false end
    return deleteRuns({ id }, src) > 0
end)

lib.callback.register('opslabs-towers:cable:deleteRuns', function(src, ids)
    if not canCable(src) or type(ids) ~= 'table' then return 0 end
    return deleteRuns(ids, src)
end)

--- put back the last thing this player removed
lib.callback.register('opslabs-towers:cable:undo', function(src)
    if not canCable(src) then return { error = 'not allowed' } end
    local list = Stash[src]
    local last = list and table.remove(list)
    if not last then return { error = 'Nothing to undo' } end
    local n = 0
    for _, row in ipairs(last.rows) do
        if last.kind == 'box' then
            local id = MySQL.insert.await('INSERT INTO opslabs_towers_cable_boxes (x, y, z, heading, remaining, kind, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
                { row.x, row.y, row.z, row.heading or 0.0, row.remaining or 0, row.kind or 'cat6', row.created_by })
            row.id = id
            Cabling.boxes[id] = row
        else
            if row.box_id and not Cabling.boxes[row.box_id] then row.box_id = nil end
            local id = MySQL.insert.await([[INSERT INTO opslabs_towers_cables (kind, color, points, length, box_id, start_tower, end_tower, start_fixture, end_fixture, start_term, end_term, loose, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { row.kind, row.color, json.encode(row.points), row.length, row.box_id, row.start_tower, row.end_tower,
                row.start_fixture, row.end_fixture, row.start_term and 1 or 0, row.end_term and 1 or 0, looseJson(row.loose), row.created_by })
            row.id = id
            Cabling.runs[id] = row
        end
        n = n + 1
    end
    changed()
    return { ok = true, kind = last.kind, count = n }
end)

--- reshape a run. Ends on a box or plugged in stay put; a cut cable can't grow beyond its length,
--- a cable still on its box pulls more off (or feeds back) the box
lib.callback.register('opslabs-towers:cable:reroute', function(src, id, points)
    if not canCable(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(id)]
    if not r then return { error = 'not found' } end
    if type(points) ~= 'table' or #points < 2 then return { error = 'a run needs at least 2 points' } end
    if r.box_id or r.start_term then points[1] = r.points[1] end
    if r.end_term then points[#points] = r.points[#r.points] end
    local clean, length = cleanPoints(points)
    if not clean then return { error = length } end
    if r.kind == 'cable' or r.kind == 'fibre' then
        if r.kind == 'cable' and length > CC.MaxRunLength + 0.5 then return { error = ('runs can be at most %dm'):format(CC.MaxRunLength) } end
        local box = r.box_id and Cabling.boxes[r.box_id]
        if box then
            local delta = length - r.length
            if delta > box.remaining then return { error = ('only %.0fm left in the box'):format(box.remaining) } end
            box.remaining = math.max(0.0, box.remaining - delta)
            MySQL.update.await('UPDATE opslabs_towers_cable_boxes SET remaining = ? WHERE id = ?', { box.remaining, box.id })
        elseif length > r.length + 0.05 then
            return { error = ('Not enough slack — this piece is cut to %.1f m'):format(r.length) }
        end
    end
    -- a cut cable keeps its real length even when routed shorter (the slack is coiled up)
    local keep = ((r.kind == 'cable' or r.kind == 'fibre') and not r.box_id) and math.max(length, r.length) or length
    r.points, r.length = clean, keep
    MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ? WHERE id = ?', { json.encode(clean), keep, r.id })
    changed()
    return { ok = true, run = r }
end)

exports('GetCabling', function() return Cabling end)
exports('IsUplinked', function(id) return Uplinked[tonumber(id)] == true end)

---------------------------------------------------------------------------
-- telecom equipment (poles, CBTs, cabinets, covers, CSP, ONT...)
---------------------------------------------------------------------------

local function equipmentAllowed(model)
    for _, e in ipairs(CC.Equipment or {}) do
        if e.model == model then return true end
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then return true end end
    end
    for _, e in ipairs((Config.Roadworks or {}).Items or {}) do
        if e.model == model then return true end
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then return true end end
    end
    return false
end

lib.callback.register('opslabs-towers:fixture:save', function(src, d)
    if not canCable(src) or type(d) ~= 'table' then return { error = 'not allowed' } end
    local x, y, z = num(d.x), num(d.y), num(d.z)
    if not (x and y and z) then return { error = 'bad position' } end
    -- settings: sign lines (up to 5 × 40 chars) or a traffic light phase (0 = side A, 1 = side B)
    local function cleanData(model, raw)
        if type(raw) ~= 'table' then return nil end
        if model == 'opslabs_rw_sign' then
            local lines = {}
            for i = 1, 5 do lines[i] = type(raw.lines) == 'table' and type(raw.lines[i]) == 'string' and raw.lines[i]:sub(1, 40) or '' end
            return { lines = lines }
        elseif model == 'opslabs_rw_tlight' then
            return { phase = raw.phase == 1 and 1 or 0 }
        elseif model == 'opslabs_core_router' then
            local patched = {}
            for _, v in ipairs(type(raw.patched) == 'table' and raw.patched or {}) do
                local n = math.tointeger(tonumber(v))
                if n and #patched < 64 then patched[#patched + 1] = n end
            end
            return { uplink = raw.uplink == true, patched = patched }
        elseif model:find('^opslabs_pole_') or model:find('^opslabs_power_pole_') or model == 'opslabs_house_pole' then
            local st = raw.status
            local out = {}
            if st == 'planned' or st == 'building' or st == 'maintenance' then out.status = st end
            if model == 'opslabs_pole_metal' and type(raw.brand) == 'table' then
                local b = raw.brand
                local function str(v, n) return type(v) == 'string' and v:sub(1, n) or '' end
                out.brand = { name = str(b.name, 32), color = (type(b.color) == 'string' and b.color:match('^#%x%x%x%x%x%x$')) or '#0a84ff',
                    number = str(b.number, 24), phone = str(b.phone, 32), extra = str(b.extra, 40) }
            end
            return next(out) and out or nil
        elseif BRANDED[model] then
            -- fence boards, branded signs and gates: company, colour, message, phone
            local b = type(raw.brand) == 'table' and raw.brand or {}
            local function str(v, n) return type(v) == 'string' and v:sub(1, n) or '' end
            return { brand = { name = str(b.name, 32), color = (type(b.color) == 'string' and b.color:match('^#%x%x%x%x%x%x$')) or '#0a84ff',
                message = str(b.message, 48), phone = str(b.phone, 32) } }
        end
    end
    local id = tonumber(d.id)
    if id then
        local f = Cabling.fixtures[id]
        if not f then return { error = 'not found' } end
        f.x, f.y, f.z, f.heading = x, y, z, num(d.heading) or f.heading
        if d.data ~= nil then f.data = cleanData(f.model, d.data) end
        MySQL.update.await('UPDATE opslabs_towers_fixtures SET x = ?, y = ?, z = ?, heading = ?, data = ? WHERE id = ?',
            { f.x, f.y, f.z, f.heading, f.data and json.encode(f.data) or nil, id })
    else
        if not equipmentAllowed(d.model) then return { error = 'unknown equipment' } end
        local data = cleanData(d.model, d.data)
        id = MySQL.insert.await('INSERT INTO opslabs_towers_fixtures (model, x, y, z, heading, data, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { d.model, x, y, z, num(d.heading) or 0.0, data and json.encode(data) or nil, GetPlayerName(src) })
        Cabling.fixtures[id] = { id = id, model = d.model, x = x, y = y, z = z, heading = num(d.heading) or 0.0, data = data, created_by = GetPlayerName(src) }
    end
    changed()
    return { ok = true, fixture = Cabling.fixtures[id] }
end)

--- a row of road safety kit at once (line of cones / barriers / tape): { { model, x, y, z, heading }, ... }
lib.callback.register('opslabs-towers:fixture:saveMany', function(src, list)
    if not canCable(src) or type(list) ~= 'table' then return { error = 'not allowed' } end
    if #list > 60 then return { error = 'at most 60 at a time' } end
    local n = 0
    for _, d in ipairs(list) do
        local x, y, z = num(d.x), num(d.y), num(d.z)
        if x and y and z and type(d.model) == 'string' and (d.model:find('^opslabs_rw_') or d.model:find('^opslabs_fence_') or d.model:find('^opslabs_bollard_fixed') or d.model:find('^opslabs_bollard_steel') or d.model:find('^opslabs_ug_')) and equipmentAllowed(d.model) then
            local id = MySQL.insert.await('INSERT INTO opslabs_towers_fixtures (model, x, y, z, heading, created_by) VALUES (?, ?, ?, ?, ?, ?)',
                { d.model, x, y, z, num(d.heading) or 0.0, GetPlayerName(src) })
            Cabling.fixtures[id] = { id = id, model = d.model, x = x, y = y, z = z, heading = num(d.heading) or 0.0, created_by = GetPlayerName(src) }
            n = n + 1
        end
    end
    if n > 0 then changed() end
    return { ok = true, count = n }
end)

--- pick up many road safety items at once (only road kit — never poles, cabinets or ONTs)
lib.callback.register('opslabs-towers:fixture:deleteMany', function(src, ids)
    if not canCable(src) or type(ids) ~= 'table' then return 0 end
    local gone = {}
    for i, id in ipairs(ids) do
        if i > 300 then break end
        id = tonumber(id)
        local f = id and Cabling.fixtures[id]
        if f and f.model:find('^opslabs_rw_') then gone[#gone + 1] = id end
    end
    if #gone == 0 then return 0 end
    MySQL.query.await(('DELETE FROM opslabs_towers_fixtures WHERE id IN (%s)'):format(table.concat(gone, ',')))
    for _, id in ipairs(gone) do Cabling.fixtures[id] = nil end
    changed()
    return #gone
end)

lib.callback.register('opslabs-towers:fixture:delete', function(src, id)
    if not canCable(src) then return false end
    id = tonumber(id)
    if not Cabling.fixtures[id] then return false end
    MySQL.update.await('DELETE FROM opslabs_towers_fixtures WHERE id = ?', { id })
    MySQL.update.await('UPDATE opslabs_towers_cables SET start_fixture = NULL WHERE start_fixture = ?', { id })
    MySQL.update.await('UPDATE opslabs_towers_cables SET end_fixture = NULL WHERE end_fixture = ?', { id })
    for _, r in pairs(Cabling.runs) do
        if r.start_fixture == id then r.start_fixture = nil end
        if r.end_fixture == id then r.end_fixture = nil end
    end
    Cabling.fixtures[id] = nil
    if IspFixtureRemoved then IspFixtureRemoved(id) end
    TriggerEvent('opslabs-towers:fixtureRemoved', id)
    changed()
    return true
end)
