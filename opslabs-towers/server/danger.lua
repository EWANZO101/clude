-- Danger zone (/towers → Danger zone, tower admins only): mass-delete parts of the power network and everything
-- else that's been built — by group (network · category, cable class, boxes, masts) inside a radius or across the map.
--   · a second lock on top of being a tower admin: username + password, checked here on the server. The first login
--     is admin / admin and must change both before anything can be deleted. Stored as a bcrypt hash
--     (GetPasswordHash) in opslabs_towers_danger, never in config files players receive.
--   · 5 wrong passwords → locked for 10 minutes (per player licence). A login lasts 15 minutes.
--   · every wipe saves a JSON backup of the exact database rows first (danger_backups/ in this resource) and can be
--     restored from the same menu. Every login, wipe and restore is printed to the server console.

local DZ = Config.Danger or {}
if DZ.Enabled == false then return end

local SESSION_TTL = (DZ.SessionMinutes or 15) * 60
local MAX_FAILS, LOCK_SECS = DZ.MaxFails or 5, (DZ.LockMinutes or 10) * 60
local Sessions, Fails = {}, {}
local auth = nil            -- { user, hash } once a password has been set; nil = still the admin / admin default

local function log(src, text) print(('^1[opslabs-towers] DANGER ZONE^7 %s (%s): %s'):format(GetPlayerName(src) or '?', src, text)) end
local function lic(src) return GetPlayerIdentifierByType(src, 'license') or ('src:' .. src) end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_danger` (`k` VARCHAR(32) NOT NULL, `v` LONGTEXT NOT NULL, PRIMARY KEY (`k`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    local row = MySQL.scalar.await("SELECT v FROM opslabs_towers_danger WHERE k = 'auth'")
    local a = row and json.decode(row)
    if type(a) == 'table' and a.user and a.hash then auth = a end
end)

local function session(src)
    local s = Sessions[src]
    if s and os.time() - s.at > SESSION_TTL then Sessions[src] = nil s = nil end
    return s
end
local function lockedFor(src)
    local f = Fails[lic(src)]
    if f and f['until'] and os.time() < f['until'] then return f['until'] - os.time() end
    return 0
end
local function admin(src) return IsTowerAdmin and IsTowerAdmin(src) end
AddEventHandler('playerDropped', function() Sessions[source] = nil end)

lib.callback.register('opslabs-towers:danger:state', function(src)
    if not admin(src) then return { admin = false } end
    local s = session(src)
    return { admin = true, locked = lockedFor(src), session = s ~= nil, mustChange = s and s.mustChange or false, default = auth == nil,
        expires = s and (SESSION_TTL - (os.time() - s.at)) or nil }
end)

lib.callback.register('opslabs-towers:danger:login', function(src, user, pass)
    if not admin(src) then return { error = 'Tower admins only' } end
    local wait = lockedFor(src)
    if wait > 0 then return { error = ('Locked — too many wrong passwords. Try again in %d min.'):format(math.ceil(wait / 60)) } end
    if type(user) ~= 'string' or type(pass) ~= 'string' or #user > 64 or #pass > 128 then return { error = 'Wrong username or password' } end
    local ok
    if auth then ok = user == auth.user and VerifyPasswordHash(pass, auth.hash)
    else ok = user == 'admin' and pass == 'admin' end
    if not ok then
        local k = lic(src)
        local f = Fails[k] or { n = 0 }
        f.n = f.n + 1
        if f.n >= MAX_FAILS then f.n, f['until'] = 0, os.time() + LOCK_SECS end
        Fails[k] = f
        log(src, 'wrong danger zone password')
        return { error = f['until'] and os.time() < f['until'] and ('Wrong — locked for %d minutes'):format(LOCK_SECS // 60)
            or ('Wrong username or password (%d tries left)'):format(MAX_FAILS - f.n) }
    end
    Fails[lic(src)] = nil
    Sessions[src] = { at = os.time(), mustChange = auth == nil }
    log(src, auth and 'unlocked the danger zone' or 'logged in with the DEFAULT admin / admin — must change it now')
    return { ok = true, mustChange = auth == nil }
end)

lib.callback.register('opslabs-towers:danger:setPassword', function(src, user, pass, confirm)
    local s = admin(src) and session(src)
    if not s then return { error = 'Log in first' } end
    if type(user) ~= 'string' or not user:match('^[%w_%.%-]+$') or #user < 3 or #user > 32 then return { error = 'Username: 3–32 letters, numbers, . _ -' } end
    if type(pass) ~= 'string' or #pass < 8 or #pass > 128 then return { error = 'The password needs at least 8 characters' } end
    if pass ~= confirm then return { error = 'The passwords don’t match' } end
    if pass:lower() == 'admin' or pass:lower() == user:lower() or pass:lower():find('password') then return { error = 'Pick a password that isn’t admin, your username or "password"' } end
    auth = { user = user, hash = GetPasswordHash(pass), at = os.time(), by = GetPlayerName(src) }
    MySQL.query.await('REPLACE INTO opslabs_towers_danger (k, v) VALUES (?, ?)', { 'auth', json.encode(auth) })
    s.mustChange = false
    s.at = os.time()
    log(src, 'changed the danger zone username / password')
    return { ok = true }
end)

lib.callback.register('opslabs-towers:danger:lock', function(src) Sessions[src] = nil return true end)

---------------------------------------------------------------------------
-- what can be deleted: groups
---------------------------------------------------------------------------

local CC = Config.Cabling or {}
local NETS = { sites = (CC.Sites or {}).label or 'Buildings & sites' }
for _, n in ipairs(CC.Networks or {}) do NETS[n.id] = n.label end
local GROUP_OF = {}          -- model -> group key
local GROUP_LABEL = {}
local function addModel(model, key, label) if model and not GROUP_OF[model] then GROUP_OF[model] = key GROUP_LABEL[key] = label end end
for _, e in ipairs(CC.Equipment or {}) do
    local key = ('eq:%s|%s'):format(e.net or '?', e.cat or '?')
    local label = ('%s · %s'):format(NETS[e.net] or e.net or 'Kit', e.cat or 'other')
    addModel(e.model, key, label)
    for _, sz in ipairs(e.sizes or {}) do addModel(sz.model, key, label) end
end
for _, e in ipairs((Config.Roadworks or {}).Items or {}) do
    addModel(e.model, 'rw', 'Road safety equipment')
    for _, sz in ipairs(e.sizes or {}) do addModel(sz.model, 'rw', 'Road safety equipment') end
end
local POWER_LABEL = CC.PowerLabels or {}
local KIND_LABEL = { cable = 'CAT6 cable', fibre = 'Fibre cable', copper = 'Copper phone cable', trunk = 'Trunking', pipe = 'Fuel pipe' }

local function fixtureGroup(f) return GROUP_OF[f.model] or (f.model:find('^opslabs_rw_') and 'rw') or 'other' end
local function runGroup(r) return r.kind == 'power' and ('run:power:' .. (r.color or '?')) or ('run:' .. r.kind) end
local function labelOf(key)
    if GROUP_LABEL[key] then return GROUP_LABEL[key] end
    local c = key:match('^run:power:(.+)$')
    if c then return 'San Andreas Power & Light · conductor: ' .. (POWER_LABEL[c] or c) end
    local k = key:match('^run:(.+)$')
    if k then return 'Cable · ' .. (KIND_LABEL[k] or k) end
    return ({ other = 'Other placed kit', rw = 'Road safety equipment', box = 'Cable boxes & drums', ['tower:cell'] = 'OPS Mobile · cell towers',
        ['tower:wifi'] = 'OPS Mobile · Wi-Fi access points' })[key] or key
end

-- presets: the power grid only / the whole power network / everything
local GRID_CATS = { ['Power poles'] = true, ['On the power pole'] = true, ['Safety & earthing'] = true, Substations = true, ['Substation plant'] = true,
    Transmission = true, Generation = true }
local function inPreset(key, preset)
    if preset == 'all' then return true end
    local net, cat = key:match('^eq:([^|]+)|(.+)$')
    if preset == 'power' then return net == 'sapl' or net == 'solar' or key:find('^run:power:') ~= nil end
    if preset == 'grid' then
        if net == 'sapl' then return GRID_CATS[cat] == true end
        local c = key:match('^run:power:(.+)$')
        return c == 'transmission' or c == 'hv' or c == 'lv' or c == 'service'
    end
    return false
end

--- scope = { all = true } or { x, y, r } (2D)
local function cleanScope(src, sc)
    if type(sc) ~= 'table' then return nil end
    if sc.all == true then return { all = true } end
    local r = tonumber(sc.r)
    if not r or r < 1 or r > 20000 then return nil end
    local p = GetEntityCoords(GetPlayerPed(src))
    local x, y = p.x, p.y
    if x == 0.0 and y == 0.0 then x, y = tonumber(sc.x), tonumber(sc.y) end
    if not x or not y then return nil end
    return { x = x, y = y, r = r }
end
local function inside(sc, p) return sc.all or ((p.x - sc.x) ^ 2 + (p.y - sc.y) ^ 2 <= sc.r * sc.r) end
local function runInside(sc, r)
    if sc.all then return true end
    local pts = r.points or {}
    for i, p in ipairs(pts) do
        if inside(sc, p) then return true end
        if i > 1 and inside(sc, { x = (p.x + pts[i - 1].x) / 2, y = (p.y + pts[i - 1].y) / 2 }) then return true end
    end
    return false
end

--- everything in scope, by group: key -> { fixtures = {}, runs = {}, boxes = {}, towers = {} }
local function collect(sc)
    local G = {}
    local function g(k) G[k] = G[k] or { fixtures = {}, runs = {}, boxes = {}, towers = {} } return G[k] end
    for id, f in pairs(Cabling.fixtures) do if inside(sc, f) then table.insert(g(fixtureGroup(f)).fixtures, id) end end
    for id, r in pairs(Cabling.runs) do if runInside(sc, r) then table.insert(g(runGroup(r)).runs, id) end end
    for id, b in pairs(Cabling.boxes) do if inside(sc, b) then table.insert(g('box').boxes, id) end end
    for id, t in pairs(Towers or {}) do if t.x and inside(sc, t) then table.insert(g('tower:' .. (t.type == 'wifi' and 'wifi' or 'cell')).towers, id) end end
    return G
end
local function count(x) return #x.fixtures + #x.runs + #x.boxes + #x.towers end

lib.callback.register('opslabs-towers:danger:groups', function(src, scope)
    local s = admin(src) and session(src)
    if not s then return { error = 'Log in first' } end
    if s.mustChange then return { error = 'Change the default username and password first' } end
    local sc = cleanScope(src, scope)
    if not sc then return { error = 'Bad range' } end
    local out = {}
    for key, x in pairs(collect(sc)) do
        out[#out + 1] = { key = key, label = labelOf(key), n = count(x), grid = inPreset(key, 'grid'), power = inPreset(key, 'power') }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return { groups = out }
end)

---------------------------------------------------------------------------
-- backup → delete, and restore
---------------------------------------------------------------------------

local RES = GetCurrentResourceName()
local BQ = string.char(96)          -- a backtick, to quote column names
local function rowsOf(tbl, ids)
    local out = {}
    for i = 1, #ids, 400 do
        local chunk = {}
        for k = i, math.min(#ids, i + 399) do chunk[#chunk + 1] = tonumber(ids[k]) end
        for _, row in ipairs(MySQL.query.await(('SELECT * FROM %s WHERE id IN (%s)'):format(tbl, table.concat(chunk, ','))) or {}) do out[#out + 1] = row end
    end
    return out
end
local function deleteIds(tbl, ids)
    for i = 1, #ids, 400 do
        local chunk = {}
        for k = i, math.min(#ids, i + 399) do chunk[#chunk + 1] = tonumber(ids[k]) end
        MySQL.query.await(('DELETE FROM %s WHERE id IN (%s)'):format(tbl, table.concat(chunk, ',')))
    end
end
local function backupIndex()
    local raw = GetResourceKvpString('danger:backups')
    local ok, list = pcall(json.decode, raw or '[]')
    return ok and type(list) == 'table' and list or {}
end

lib.callback.register('opslabs-towers:danger:wipe', function(src, scope, keys, typed)
    local s = admin(src) and session(src)
    if not s then return { error = 'Log in first' } end
    if s.mustChange then return { error = 'Change the default username and password first' } end
    if typed ~= 'DELETE' then return { error = 'Type DELETE to confirm' } end
    local sc = cleanScope(src, scope)
    if not sc or type(keys) ~= 'table' or #keys == 0 then return { error = 'Nothing picked' } end
    local want = {}
    for _, k in ipairs(keys) do if type(k) == 'string' then want[k] = true end end
    local F, Rn, B, Tw = {}, {}, {}, {}
    for key, x in pairs(collect(sc)) do
        if want[key] then
            for _, id in ipairs(x.fixtures) do F[#F + 1] = id end
            for _, id in ipairs(x.runs) do Rn[#Rn + 1] = id end
            for _, id in ipairs(x.boxes) do B[#B + 1] = id end
            for _, id in ipairs(x.towers) do Tw[#Tw + 1] = id end
        end
    end
    local total = #F + #Rn + #B + #Tw
    if total == 0 then return { error = 'Nothing to delete in that range' } end

    -- 1. backup of the exact rows
    local stamp = os.date('%Y%m%d-%H%M%S')
    local name = ('danger_backups/wipe-%s-%d.json'):format(stamp, src)
    local backup = { at = os.time(), by = GetPlayerName(src), scope = sc, keys = keys,
        fixtures = rowsOf('opslabs_towers_fixtures', F), runs = rowsOf('opslabs_towers_cables', Rn), boxes = rowsOf('opslabs_towers_cable_boxes', B),
        towers = rowsOf('opslabs_towers', Tw) }
    if not SaveResourceFile(RES, name, json.encode(backup), -1) then return { error = 'Couldn’t write the backup — nothing was deleted' } end
    local idx = backupIndex()
    table.insert(idx, 1, { file = name, at = backup.at, by = backup.by, n = total, what = #keys == 1 and labelOf(keys[1]) or (#keys .. ' groups'),
        where = sc.all and 'whole map' or ('%.0f m round %.0f, %.0f'):format(sc.r, sc.x, sc.y) })
    while #idx > 30 do table.remove(idx) end
    SetResourceKvp('danger:backups', json.encode(idx))

    -- 2. delete
    if #Rn > 0 then CablingDeleteRuns(Rn, src) end
    if #F > 0 then
        deleteIds('opslabs_towers_fixtures', F)
        local gone = {}
        for _, id in ipairs(F) do gone[id] = true Cabling.fixtures[id] = nil if IspFixtureRemoved then pcall(IspFixtureRemoved, id) end TriggerEvent('opslabs-towers:fixtureRemoved', id) end
        MySQL.query.await(('UPDATE opslabs_towers_cables SET start_fixture = NULL WHERE start_fixture IN (%s)'):format(table.concat(F, ',')))
        MySQL.query.await(('UPDATE opslabs_towers_cables SET end_fixture = NULL WHERE end_fixture IN (%s)'):format(table.concat(F, ',')))
        for _, r in pairs(Cabling.runs) do
            if r.start_fixture and gone[r.start_fixture] then r.start_fixture = nil end
            if r.end_fixture and gone[r.end_fixture] then r.end_fixture = nil end
        end
    end
    if #B > 0 then deleteIds('opslabs_towers_cable_boxes', B) for _, id in ipairs(B) do Cabling.boxes[id] = nil end end
    if #Tw > 0 and DeleteTowers then DeleteTowers({ ids = Tw }) end
    if CablingChanged then CablingChanged() end
    log(src, ('WIPED %d item(s): %d kit, %d cable runs, %d boxes, %d masts (%s) — backup %s'):format(total, #F, #Rn, #B, #Tw,
        sc.all and 'whole map' or ('%.0f m radius'):format(sc.r), name))
    return { ok = true, total = total, fixtures = #F, runs = #Rn, boxes = #B, towers = #Tw, backup = name }
end)

lib.callback.register('opslabs-towers:danger:backups', function(src)
    local s = admin(src) and session(src)
    if not s or s.mustChange then return { error = 'Log in first' } end
    return { list = backupIndex() }
end)

--- put a wipe back (same ids). Masts come back after a resource restart.
lib.callback.register('opslabs-towers:danger:restore', function(src, file)
    local s = admin(src) and session(src)
    if not s or s.mustChange then return { error = 'Log in first' } end
    local known = false
    for _, b in ipairs(backupIndex()) do if b.file == file then known = true end end
    if not known then return { error = 'Unknown backup' } end
    local ok, B = pcall(json.decode, LoadResourceFile(RES, file) or '')
    if not ok or type(B) ~= 'table' then return { error = 'The backup file is missing or damaged' } end
    local n = 0
    local function insert(tbl, row)
        local cols, vals, qs = {}, {}, {}
        for k, v in pairs(row) do
            if k ~= 'created_at' and k ~= 'updated_at' and type(k) == 'string' and k:match('^[%w_]+$') then
                cols[#cols + 1] = BQ .. k .. BQ
                vals[#vals + 1] = type(v) == 'table' and json.encode(v) or v
                qs[#qs + 1] = '?'
            end
        end
        local done = MySQL.update.await(('INSERT IGNORE INTO %s (%s) VALUES (%s)'):format(tbl, table.concat(cols, ','), table.concat(qs, ',')), vals)
        if (tonumber(done) or 0) > 0 then n = n + 1 return true end
        return false
    end
    for _, f in ipairs(B.fixtures or {}) do
        if insert('opslabs_towers_fixtures', f) then
            local c = {}
            for k, v in pairs(f) do c[k] = v end
            c.data = type(c.data) == 'string' and json.decode(c.data) or nil
            Cabling.fixtures[c.id] = c
        end
    end
    for _, r in ipairs(B.runs or {}) do
        if insert('opslabs_towers_cables', r) then
            local c = {}
            for k, v in pairs(r) do c[k] = v end
            Cabling.runs[c.id] = CablingDecodeRun and CablingDecodeRun(c) or c
        end
    end
    for _, b in ipairs(B.boxes or {}) do if insert('opslabs_towers_cable_boxes', b) then Cabling.boxes[b.id] = b end end
    local masts = 0
    for _, t in ipairs(B.towers or {}) do if insert('opslabs_towers', t) then masts = masts + 1 end end
    if CablingChanged then CablingChanged() end
    log(src, ('restored %d item(s) from %s'):format(n, file))
    return { ok = true, n = n, masts = masts }
end)
