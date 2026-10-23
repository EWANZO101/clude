-- Pole route planner (OPS Hub → Grid control → Routes, and in game from an engineer's tablet): an admin plans a
-- sequence of pole locations on the map, spaced no further apart than that network's cable can actually span, saves
-- it, then sends it out either as an open OPS Work job (opslabs-phone) any qualified engineer can accept, or
-- straight to one named engineer if they're online right now. Either way the engineer gets the same in-game guide:
-- GPS to each point in turn, ticked off as poles go up (client/routeguide.lua).
--
-- A route's points never leave this table except as a snapshot baked into a job's own `verify.points` at dispatch
-- time (server/platformhooks.lua's `pole_route` check reads that, not this table) — so once dispatched, a route
-- here is just a record of what was sent and when; editing/deleting only works while it's still 'planned'.

local CC = Config.Cabling or {}
local MAXLEN = {
    power = function() return CC.MaxPowerLength or 1200 end,
    fibre = function() return CC.MaxFibreLength or 1000 end,
}
local JOB_FOR_NETWORK = {
    power = { company = 'sapl', type = 'pole_route_power' },
    fibre = { company = 'fibre', type = 'pole_route_fibre' },
}
local NETWORK_LABEL = { power = 'Power (San Andreas Power & Light)', fibre = 'Fibre (OPS Openline)' }

CreateThread(function()
    if AwaitDatabase then AwaitDatabase() else Wait(3000) end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_routes (
        id INT AUTO_INCREMENT PRIMARY KEY,
        network VARCHAR(16) NOT NULL,
        name VARCHAR(80) NULL,
        points LONGTEXT NOT NULL,
        spacing_max FLOAT NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'planned',
        dispatch_method VARCHAR(10) NULL,
        dispatch_job_id INT NULL,
        dispatch_job_ref VARCHAR(16) NULL,
        dispatch_to VARCHAR(80) NULL,
        created_by VARCHAR(80) NULL,
        created_at INT NOT NULL DEFAULT 0,
        dispatched_at INT NULL,
        KEY status (status)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function poleModelPattern(network) return network == 'power' and '^opslabs_power_pole_%d+m$' or '^opslabs_pole_%d+m$' end

--- live progress while an engineer is actively working a route (client/routeguide.lua polls this): "is there a
--- pole near this point right now", any pole, not just ones built since some snapshot — that stricter rule is
--- only for the job's actual completion check (server/platformhooks.lua's `pole_route`), not this live display.
lib.callback.register('opslabs-towers:routes:progress', function(src, network, points, radius)
    local pat = poleModelPattern(network)
    radius = tonumber(radius) or 15
    local done = {}
    for i, pt in ipairs(type(points) == 'table' and points or {}) do
        done[i] = false
        if type(pt) == 'table' and type(pt.x) == 'number' and type(pt.y) == 'number' then
            for _, f in pairs(Cabling.fixtures) do
                if f.model and f.model:find(pat) and d2(f, pt) <= radius then done[i] = true break end
            end
        end
    end
    return done
end)

--- checks every point is a real {x,y} and no gap between consecutive points exceeds what this network's cable
--- can span; returns nil (ok) or an error string
local function validate(network, points)
    if not MAXLEN[network] then return 'network must be power or fibre' end
    if type(points) ~= 'table' or #points < 2 then return 'A route needs at least 2 points' end
    if #points > 60 then return 'At most 60 points in one route' end
    local max = MAXLEN[network]()
    for i, p in ipairs(points) do
        if type(p) ~= 'table' or type(p.x) ~= 'number' or type(p.y) ~= 'number' then return ('Point %d is missing x/y'):format(i) end
        if i > 1 then
            local d = d2(points[i - 1], p)
            if d > max then return ('Point %d is %dm from point %d — too far for %s (max %dm)'):format(i, math.floor(d), i - 1, network, max) end
        end
    end
    return nil
end

local function row(id)
    local r = MySQL.single.await('SELECT * FROM opslabs_towers_routes WHERE id = ?', { tonumber(id) })
    if r then r.points = json.decode(r.points or '[]') or {} end
    return r
end
RouteGet = row

function RoutesList(status)
    local rows = MySQL.query.await(
        'SELECT id, network, name, status, dispatch_method, dispatch_job_id, dispatch_job_ref, dispatch_to, created_by, created_at, dispatched_at, '
        .. 'JSON_LENGTH(points) AS point_count FROM opslabs_towers_routes '
        .. (status and 'WHERE status = ? ' or '') .. 'ORDER BY id DESC LIMIT 300',
        status and { status } or {}) or {}
    -- per-row, not a wrapper object, so the response stays a plain array (simplest shape for the Hub JS)
    local autoBuild = (Config.Routes or {}).AutoBuild ~= false
    for _, row2 in ipairs(rows) do row2.auto_build = autoBuild end
    return rows
end

--- id = nil to create, else update (only while still 'planned'); data = { network, name, points }
function RouteSave(id, data, actor)
    local network = data and data.network
    local err = validate(network, data and data.points)
    if err then return nil, err end
    local max = MAXLEN[network]()
    local name = type(data.name) == 'string' and data.name:sub(1, 80) or nil
    local points = json.encode(data.points)
    if id then
        local n = MySQL.update.await("UPDATE opslabs_towers_routes SET network = ?, name = ?, points = ?, spacing_max = ? WHERE id = ? AND status = 'planned'",
            { network, name, points, max, tonumber(id) })
        if n ~= 1 then return nil, 'Not found, or already dispatched (dispatched routes can’t be edited)' end
        return row(id)
    end
    local newId = MySQL.insert.await('INSERT INTO opslabs_towers_routes (network, name, points, spacing_max, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        { network, name, points, max, type(actor) == 'string' and actor:sub(1, 80) or 'unknown', os.time() })
    return row(newId)
end

function RouteDelete(id)
    local n = MySQL.update.await("DELETE FROM opslabs_towers_routes WHERE id = ? AND status = 'planned'", { tonumber(id) })
    return n == 1
end

--- data = { method = 'job' | 'text', number = <engineer's phone number, for 'text'> }
function RouteDispatch(id, data, actor)
    local r = row(id)
    if not r then return nil, 'No such route' end
    if r.status ~= 'planned' then return nil, 'Already dispatched' end
    local method = data and data.method
    if method ~= 'job' and method ~= 'text' then return nil, 'method must be job or text' end
    if GetResourceState('opslabs-phone') ~= 'started' then return nil, 'opslabs-phone is not running' end

    if method == 'job' then
        local jt = JOB_FOR_NETWORK[r.network]
        if not jt then return nil, 'Unknown network' end
        local p1 = r.points[1]
        local okc, jobId, ref = pcall(function()
            return exports['opslabs-phone']:CreatePlatformJob(jt.company, jt.type,
                { name = r.name or ('Pole route #' .. r.id), x = p1.x, y = p1.y, z = p1.z },
                { verify = { kind = 'pole_route', points = r.points, network = r.network, radius = 15 }, by = actor })
        end)
        if not okc or not jobId then return nil, 'Could not create the job — check the company and job type are switched on' end
        MySQL.update.await("UPDATE opslabs_towers_routes SET status = 'dispatched', dispatch_method = 'job', dispatch_job_id = ?, dispatch_job_ref = ?, dispatched_at = ? WHERE id = ?",
            { jobId, ref, os.time(), r.id })
        return { ok = true, job_id = jobId, job_ref = ref }
    end

    -- text: only reaches an engineer who's online right now (no offline queueing in this first version)
    local number = type(data.number) == 'string' and data.number or ''
    if number == '' then return nil, 'Pick an engineer (phone number)' end
    local okc, target = pcall(function() return exports['opslabs-phone']:GetSourceByNumber(number) end)
    target = okc and tonumber(target) or nil
    if not target or target == 0 then return nil, 'That engineer isn’t online right now — try dispatching as a job instead' end
    pcall(function()
        exports['opslabs-phone']:Notify(target, NETWORK_LABEL[r.network] or 'OPS', ('You’ve been sent a %d-point pole route%s — check your GPS'):format(#r.points, r.name and (' · ' .. r.name) or ''),
            'system', 'fa-solid fa-route')
    end)
    TriggerClientEvent('opslabs-towers:route:assign', target, { id = r.id, network = r.network, name = r.name, points = r.points })
    MySQL.update.await("UPDATE opslabs_towers_routes SET status = 'dispatched', dispatch_method = 'text', dispatch_to = ?, dispatched_at = ? WHERE id = ?",
        { number, os.time(), r.id })
    return { ok = true }
end

---------------------------------------------------------------------------
-- auto-build (Config.Routes.AutoBuild): build the planned route right now instead of sending it out for an
-- engineer to build by hand. The server has no collision/terrain data at all outside a running game, so this
-- needs a tower admin online right now — their character is briefly hidden while it surveys each point's ground
-- height, reusing the exact same survey callback server/showcase.lua already uses for its own builder.
---------------------------------------------------------------------------
local POLE_MODEL = { power = 'opslabs_power_pole_10m', fibre = 'opslabs_pole_10m' }
local TAG = 'OPS Route planner'

local function adminOnline()
    for _, p in ipairs(GetPlayers()) do
        local s = tonumber(p)
        if IsTowerAdmin and IsTowerAdmin(s) then return s end
    end
end

local function heading(a, b)
    return math.deg(math.atan(b.x - a.x, b.y - a.y)) % 360
end

local function insertPole(model, p, z, h)
    local pid = MySQL.insert.await('INSERT INTO opslabs_towers_fixtures (model, x, y, z, heading, created_by) VALUES (?, ?, ?, ?, ?, ?)',
        { model, p.x, p.y, z, h, TAG })
    Cabling.fixtures[pid] = { id = pid, model = model, x = p.x, y = p.y, z = z, heading = h, created_by = TAG }
    return pid
end

--- a bare HV conductor span between two already-known points (fixture ids optional — an endpoint with no fixture
--- id just needs to land within a substation's reach, e.g. the substation's own coordinates)
local function insertPowerRun(a, za, b, zb, idA, idB)
    local pts = { { x = a.x, y = a.y, z = za, nx = 0.0, ny = 0.0, nz = 1.0 }, { x = b.x, y = b.y, z = zb, nx = 0.0, ny = 0.0, nz = 1.0 } }
    local length = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (za - zb) ^ 2)
    local rid = MySQL.insert.await([[INSERT INTO opslabs_towers_cables (kind, color, points, length, start_fixture, end_fixture, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?)]], { 'power', 'hv', json.encode(pts), length, idA, idB, TAG })
    Cabling.runs[rid] = { id = rid, kind = 'power', color = 'hv', points = pts, length = length, start_fixture = idA, end_fixture = idB, created_by = TAG }
    return rid
end

function RouteAutoBuild(id, actor)
    if (Config.Routes or {}).AutoBuild == false then return nil, 'Auto-build is switched off (Config.Routes.AutoBuild)' end
    local r = row(id)
    if not r then return nil, 'No such route' end
    if r.status ~= 'planned' then return nil, 'Already dispatched' end
    local model = POLE_MODEL[r.network]
    if not model then return nil, 'Unknown network' end
    local src = adminOnline()
    if not src then return nil, 'Auto-build needs a tower admin online in game right now (to survey the ground) — try dispatching it as a job or text instead' end

    local okc, zs = pcall(lib.callback.await, 'opslabs-towers:showcase:survey', src, r.points)
    if not okc or type(zs) ~= 'table' then return nil, 'The survey failed — the admin may have disconnected mid-way' end

    local poleIds, created = {}, 0
    for i, p in ipairs(r.points) do
        local z = zs[i]
        if z then
            local h = heading(p, r.points[i + 1] or r.points[i - 1] or p)
            poleIds[i] = insertPole(model, p, z, h)
            created = created + 1
        end
    end
    -- only power gets auto-laid conductor: a bare HV run pole to pole is exactly right (same as a player laying it).
    -- Fibre poles need proper junction kit (CBTs, splice enclosures…) between them, not a raw cable — that's real
    -- design work an engineer still has to do by hand, so fibre routes only auto-build the poles themselves.
    if r.network == 'power' then
        for i = 2, #r.points do
            if poleIds[i - 1] and poleIds[i] then
                insertPowerRun(r.points[i - 1], zs[i - 1], r.points[i], zs[i], poleIds[i - 1], poleIds[i])
            end
        end
        if MainsRecompute then MainsRecompute() end
        if GridResolve then GridResolve() end
    end

    MySQL.update.await("UPDATE opslabs_towers_routes SET status = 'built', dispatch_method = 'autobuild', dispatch_to = ?, dispatched_at = ? WHERE id = ?",
        { GetPlayerName(src), os.time(), r.id })
    return { ok = true, poles = created, total = #r.points,
        note = r.network == 'fibre' and 'Poles are up — fibre still needs proper junction kit between them, built by hand' or nil }
end

---------------------------------------------------------------------------
-- auto-link: one click from a pole's own panel — "link this pole back to the nearest substation" — for the single
-- most common no_route fault (server/grid.lua's power fault finder: "no HV conductor connects it back to a
-- substation"). Straight line from the isolated pole to the nearest substation, spaced at Config.City.PoleSpacing;
-- any existing power pole already close to a generated spot is reused (its real position and id), not duplicated.
-- Power only — fibre poles need real junction kit between them, not a bare run (same reasoning as RouteAutoBuild).
---------------------------------------------------------------------------
local CG = Config.Grid or {}
local function isSubAnchor(m) return m == (CG.Substation or {}).model or (CG.SubSites or {})[m] ~= nil end
local SNAP_TOLERANCE = 20.0   -- metres: an existing pole this close to a generated spot is reused instead of duplicated
local MAX_AUTOLINK_POLES = 40

function RouteAutoLink(poleId, actor)
    if (Config.Routes or {}).AutoBuild == false then return nil, 'Auto-build is switched off (Config.Routes.AutoBuild)' end
    local pole = Cabling.fixtures[tonumber(poleId)]
    if not pole or not pole.model or not pole.model:find('^opslabs_power_pole') then return nil, 'Not a power pole' end

    local sub
    for _, f in pairs(Cabling.fixtures) do
        if isSubAnchor(f.model) then
            local d = math.sqrt((f.x - pole.x) ^ 2 + (f.y - pole.y) ^ 2)
            if not sub or d < sub.d then sub = { f = f, d = d } end
        end
    end
    if not sub then return nil, 'No substation built yet' end

    local spacing = (Config.City or {}).PoleSpacing or 40.0
    local maxLen = (Config.Cabling or {}).MaxPowerLength or 1200
    local n = math.max(0, math.floor(sub.d / spacing) - 1)   -- intermediate poles between the pole and the substation
    if n > MAX_AUTOLINK_POLES then
        return nil, ('The nearest substation is %dm away — too far to auto-link (over %d intermediate poles; build part of the way by hand first)'):format(math.floor(sub.d), MAX_AUTOLINK_POLES)
    end

    -- points[1] = the existing pole, points[2..n+1] = intermediate spots (reused pole if one's already close by),
    -- points[#points] = the substation's own position (no fixture needed there — being this close is what counts)
    local points, reuse = { { x = pole.x, y = pole.y, z = pole.z } }, { [1] = pole.id }
    for i = 1, n do
        local t = i / (n + 1)
        local gx, gy = pole.x + (sub.f.x - pole.x) * t, pole.y + (sub.f.y - pole.y) * t
        local near
        for _, f in pairs(Cabling.fixtures) do
            if f.model and f.model:find('^opslabs_power_pole') and f.id ~= pole.id then
                local d = math.sqrt((f.x - gx) ^ 2 + (f.y - gy) ^ 2)
                if d <= SNAP_TOLERANCE and (not near or d < near.d) then near = { f = f, d = d } end
            end
        end
        if near then
            points[#points + 1] = { x = near.f.x, y = near.f.y, z = near.f.z }
            reuse[#points] = near.f.id
        else
            points[#points + 1] = { x = gx, y = gy }
        end
    end
    points[#points + 1] = { x = sub.f.x, y = sub.f.y, z = sub.f.z }

    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        if d > maxLen then return nil, ('A gap of %dm is too far for a single HV span — build part of the way by hand first'):format(math.floor(d)) end
    end

    local src = adminOnline()
    if not src then return nil, 'Auto-link needs a tower admin online in game right now (to survey the ground) — try the route planner’s job/text dispatch instead' end

    -- only the spots that need a brand new pole get surveyed (reused poles and the substation already have a real z)
    local toSurvey, surveyIdx = {}, {}
    for i, p in ipairs(points) do
        if not reuse[i] and i < #points then
            toSurvey[#toSurvey + 1] = p
            surveyIdx[#toSurvey] = i
        end
    end
    local zs = {}
    if #toSurvey > 0 then
        local okc, got = pcall(lib.callback.await, 'opslabs-towers:showcase:survey', src, toSurvey)
        if not okc or type(got) ~= 'table' then return nil, 'The survey failed — the admin may have disconnected mid-way' end
        for i, idx in ipairs(surveyIdx) do zs[idx] = got[i] end
    end
    for i, p in ipairs(points) do if reuse[i] then zs[i] = p.z end end
    zs[#points] = sub.f.z

    local poleIds, created = { [1] = pole.id }, 0
    for i = 2, #points - 1 do
        if reuse[i] then poleIds[i] = reuse[i]
        elseif zs[i] then
            poleIds[i] = insertPole('opslabs_power_pole_10m', points[i], zs[i], heading(points[i], points[i + 1]))
            created = created + 1
        end
    end

    local linked = 0
    for i = 2, #points do
        local idA = poleIds[i - 1]
        local idB = i == #points and nil or poleIds[i]
        if idA and (i == #points or idB) then
            insertPowerRun(points[i - 1], zs[i - 1], points[i], zs[i], idA, idB)
            linked = linked + 1
        end
    end
    if MainsRecompute then MainsRecompute() end
    if GridResolve then GridResolve() end

    MySQL.insert.await([[INSERT INTO opslabs_towers_routes (network, name, points, spacing_max, status, dispatch_method, dispatch_to, created_by, created_at, dispatched_at)
        VALUES ('power', ?, ?, ?, 'built', 'autolink', ?, ?, ?, ?)]],
        { ('Auto-link: pole #%d'):format(pole.id), json.encode(points), maxLen, GetPlayerName(src), actor, os.time(), os.time() })

    return { ok = true, poles_added = created, spans = linked }
end
