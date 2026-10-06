-- OPS Traffic: live incidents across the state (Config.Traffic) — accidents, road closures, fires, gun violence, active
-- police pursuits (10-80), hazards and planned work.
--   reported : players report what they see (opslabs_phone_traffic); the same thing reported again nearby adds a
--              confirmation; hard crashes and fires near a player are reported automatically (client/traffic.lua)
--   10-80    : police start a pursuit; the lead unit's phone sends its position every few seconds, it ends when they
--              end it or stop sending
--   live     : gun violence from the OPS Sentinel sensors (opslabs-towers), street works sites (roadworks kit placed
--              in the world), planned network / power work and crews working on site (OPS platform jobs)
-- New incidents notify phones within AlertRadius (the app can turn alerts off).

local CT = Config.Traffic or {}
if CT.Enabled == false then return end

local KINDS = {
    accident = { label = 'Accident', icon = 'fa-car-burst', color = '#ff9f0a' },
    closure  = { label = 'Road closed', icon = 'fa-road-barrier', color = '#ff453a' },
    fire     = { label = 'Fire', icon = 'fa-fire', color = '#ff6b00' },
    shots    = { label = 'Gun violence', icon = 'fa-gun', color = '#bf5af2' },
    pursuit  = { label = '10-80 · Police pursuit', icon = 'fa-car-on', color = '#0a84ff' },
    police   = { label = 'Police activity', icon = 'fa-shield-halved', color = '#0a84ff' },
    hazard   = { label = 'Hazard', icon = 'fa-triangle-exclamation', color = '#ffd60a' },
    works    = { label = 'Planned work', icon = 'fa-person-digging', color = '#30d158' },
}
local REPORTABLE = { accident = true, closure = true, fire = true, shots = true, hazard = true, police = true }

local function now() return os.time() end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function inList(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end
local function isPolice(src) return inList(CT.PoliceJobs, FW.Job and FW.Job(src)) end
local function canClose(src) return isPolice(src) or inList(CT.ClosureJobs, FW.Job and FW.Job(src)) end
local function expiry(kind) return now() + (((CT.Expire or {})[kind] or 30) * 60) end
local function pos(src) local c = GetEntityCoords(GetPlayerPed(src)) return { x = c.x, y = c.y, z = c.z } end

CreateThread(function()
    while not DatabaseReady do Wait(100) end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_traffic` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `kind` VARCHAR(12) NOT NULL,
        `detail` VARCHAR(200) NULL,
        `street` VARCHAR(120) NULL,
        `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL DEFAULT 0,
        `source` VARCHAR(10) NOT NULL DEFAULT 'player',
        `reporter` VARCHAR(60) NULL,
        `reporter_name` VARCHAR(60) NULL,
        `confirms` INT NOT NULL DEFAULT 1,
        `status` VARCHAR(10) NOT NULL DEFAULT 'active',
        `created_at` INT NOT NULL,
        `updated_at` INT NOT NULL,
        `expires_at` INT NOT NULL,
        PRIMARY KEY (`id`), KEY `active` (`status`, `expires_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_traffic_votes` (
        `incident` INT NOT NULL, `identifier` VARCHAR(60) NOT NULL, `vote` TINYINT NOT NULL,
        PRIMARY KEY (`incident`, `identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

---------------------------------------------------------------------------
-- live sources (cached a few seconds)
---------------------------------------------------------------------------
local liveCache, liveAt = {}, 0
local TOWERS = 'opslabs-towers'

local function liveItems()
    if now() - liveAt < 8 then return liveCache end
    liveAt = now()
    local out = {}
    -- gun violence: OPS Sentinel acoustic sensors
    if GetResourceState(TOWERS) == 'started' then
        local ok, g = pcall(function() return exports[TOWERS]:GetGunshots(false) end)
        if ok and g and g.incidents then
            for _, i in ipairs(g.incidents) do
                if now() - (i.updated_at or i.created_at or 0) < ((CT.Expire or {}).shots or 20) * 60 then
                    out[#out + 1] = { id = 'gs' .. i.id, kind = 'shots', x = i.x, y = i.y, z = i.z, street = i.street, source = 'sensor',
                        detail = ('%d shot%s heard by %d sensor%s%s'):format(i.rounds or 1, (i.rounds or 1) == 1 and '' or 's', i.sensors or 1, (i.sensors or 1) == 1 and '' or 's',
                            i.status == 'responding' and ' · police responding' or ''), created_at = i.created_at, updated_at = i.updated_at, confirms = i.sensors or 1 }
                end
            end
        end
    end
    -- street works sites: roadworks kit placed in the world, grouped into sites
    local ok, rows = pcall(MySQL.query.await, "SELECT id, model, x, y, z, data, created_at FROM opslabs_towers_fixtures WHERE model LIKE 'opslabs_rw_%'")
    if ok and rows then
        local sites = {}
        for _, r in ipairs(rows) do
            local site
            for _, s in ipairs(sites) do if d2(s, r) <= 60 then site = s break end end
            if not site then site = { x = r.x, y = r.y, z = r.z, n = 0, lights = 0, text = nil, at = 0 } sites[#sites + 1] = site end
            site.n = site.n + 1
            if r.model == 'opslabs_rw_tlight' then site.lights = site.lights + 1 end
            if r.model == 'opslabs_rw_sign' and r.data then
                local okj, d = pcall(json.decode, r.data)
                if okj and type(d) == 'table' and type(d.lines) == 'table' then
                    local t = {}
                    for _, l in ipairs(d.lines) do if type(l) == 'string' and l ~= '' then t[#t + 1] = l end end
                    if #t > 0 then site.text = table.concat(t, ' · ') end
                end
            end
        end
        for i, s in ipairs(sites) do
            if s.n >= 3 then
                out[#out + 1] = { id = 'rw' .. i, kind = 'works', x = s.x, y = s.y, z = s.z, source = 'works',
                    detail = (s.text and (s.text .. ' · ') or 'Street works · ') .. (s.lights > 0 and 'temporary traffic lights' or ('%d pieces of safety kit'):format(s.n)) }
            end
        end
    end
    -- planned network outages (OPS Network) and crews working on site (OPS platform jobs)
    local ok2, outs = pcall(MySQL.query.await, "SELECT id, ref, title, area, x, y, started_at FROM ops_isp_outages WHERE status <> 'resolved' AND planned = 1 AND x IS NOT NULL")
    if ok2 then
        for _, o in ipairs(outs or {}) do
            out[#out + 1] = { id = 'po' .. o.id, kind = 'works', x = o.x, y = o.y, z = 0, street = o.area, source = 'planned', detail = ('Planned work · %s (%s)'):format(o.title, o.ref or ''), created_at = o.started_at }
        end
    end
    local ok3, jobs = pcall(MySQL.query.await, [[SELECT j.id, j.title, j.location, j.x, j.y, j.z, j.accepted_at AS started_at, c.name AS company FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
        WHERE j.status = 'in_progress' AND j.x IS NOT NULL ORDER BY j.id DESC LIMIT 40]])
    if ok3 then
        for _, j in ipairs(jobs or {}) do
            out[#out + 1] = { id = 'jb' .. j.id, kind = 'works', x = j.x, y = j.y, z = j.z or 0, street = j.location, source = 'crew', detail = ('%s crew on site · %s'):format(j.company, j.title), created_at = j.started_at }
        end
    end
    liveCache = out
    return out
end

---------------------------------------------------------------------------
-- reported incidents
---------------------------------------------------------------------------
local function active()
    return MySQL.query.await("SELECT * FROM opslabs_phone_traffic WHERE status = 'active' AND expires_at > ? ORDER BY updated_at DESC LIMIT 150", { now() }) or {}
end

local function view(r, me)
    local k = KINDS[r.kind] or KINDS.hazard
    return { id = r.id, kind = r.kind, label = k.label, icon = k.icon, color = k.color, detail = r.detail, street = r.street, x = r.x, y = r.y, z = r.z,
        source = r.source, reporter = r.reporter_name, confirms = r.confirms, created_at = r.created_at, updated_at = r.updated_at,
        dist = me and math.floor(d2(me, r)) or nil, mine = r.mine }
end

--- tell phones near a new incident (the app decides whether to show it)
local function announce(inc)
    for src, phone in pairs(Phones) do
        local p = GetPlayerPed(src)
        if p and p ~= 0 then
            local c = GetEntityCoords(p)
            local d = d2({ x = c.x, y = c.y }, inc)
            if d <= (CT.AlertRadius or 800) or inc.kind == 'pursuit' and d <= (CT.AlertRadius or 800) * 2 then
                Push(src, 'trafficAlert', view(inc, { x = c.x, y = c.y }))
            end
        end
    end
    for src in pairs(Phones) do Push(src, 'trafficChanged') end
end

--- add a report, or confirm one of the same kind close by
local function report(kind, at, detail, street, source, phone, name)
    local near = MySQL.single.await([[SELECT * FROM opslabs_phone_traffic WHERE status = 'active' AND expires_at > ? AND kind = ?
        AND ABS(x - ?) < ? AND ABS(y - ?) < ? ORDER BY id DESC LIMIT 1]], { now(), kind, at.x, CT.MergeRadius or 80, at.y, CT.MergeRadius or 80 })
    if near and d2(near, at) <= (CT.MergeRadius or 80) then
        MySQL.update.await('UPDATE opslabs_phone_traffic SET confirms = confirms + 1, updated_at = ?, expires_at = ?, detail = COALESCE(?, detail) WHERE id = ?',
            { now(), expiry(kind), detail, near.id })
        for src in pairs(Phones) do Push(src, 'trafficChanged') end
        return near.id, true
    end
    local id = MySQL.insert.await([[INSERT INTO opslabs_phone_traffic (kind, detail, street, x, y, z, source, reporter, reporter_name, created_at, updated_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { kind, detail, street, at.x, at.y, at.z or 0, source, phone and phone.identifier, name, now(), now(), expiry(kind) })
    announce({ id = id, kind = kind, detail = detail, street = street, x = at.x, y = at.y, z = at.z, source = source, reporter_name = name, confirms = 1, created_at = now(), updated_at = now() })
    return id, false
end

-- tidy up
CreateThread(function()
    while true do
        Wait(60000)
        pcall(MySQL.update.await, "UPDATE opslabs_phone_traffic SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", { now() })
        pcall(MySQL.update.await, 'DELETE FROM opslabs_phone_traffic WHERE created_at < ?', { now() - 3 * 86400 })
    end
end)

---------------------------------------------------------------------------
-- the app
---------------------------------------------------------------------------
Register('trafficFeed', function(src, phone)
    local me = pos(src)
    local list = {}
    for _, r in ipairs(active()) do
        r.mine = r.reporter == phone.identifier or nil
        list[#list + 1] = view(r, me)
    end
    for _, x in ipairs(liveItems()) do
        local k = KINDS[x.kind]
        x.label, x.icon, x.color, x.dist, x.live = k.label, k.icon, k.color, math.floor(d2(me, x)), true
        list[#list + 1] = x
    end
    return { incidents = list, police = isPolice(src), closer = canClose(src), now = now(), kinds = KINDS }
end)

Register('trafficReport', function(src, phone, data)
    local kind = tostring(data.kind or '')
    if not REPORTABLE[kind] then return { error = 'Pick what you are reporting' } end
    if kind == 'closure' and not canClose(src) then return { error = 'Only police and road crews can close a road — report a hazard instead' } end
    local at = pos(src)
    local id, merged = report(kind, at, data.detail and Clean(data.detail, 200) or nil, data.street and Clean(data.street, 120) or nil,
        kind == 'closure' and isPolice(src) and 'police' or 'player', phone, phone.name)
    if not merged and kind == 'closure' then
        MySQL.update.await('UPDATE opslabs_phone_traffic SET expires_at = ? WHERE id = ?', { now() + math.max(10, math.min(480, tonumber(data.minutes) or 60)) * 60, id })
    end
    return { ok = true, id = id, merged = merged }
end)

--- automatic reports from the game (hard crash, fire nearby) — rate-limited per player
local autoAt = {}
Register('trafficAuto', function(src, phone, data)
    local kind = data.kind == 'fire' and 'fire' or data.kind == 'accident' and 'accident' or nil
    if not kind or (kind == 'fire' and CT.AutoFire == false) or (kind == 'accident' and CT.AutoCrash == false) then return false end
    local key = src .. kind
    if autoAt[key] and now() - autoAt[key] < 120 then return false end
    autoAt[key] = now()
    local at = pos(src)
    if tonumber(data.x) and tonumber(data.y) and d2(at, { x = tonumber(data.x), y = tonumber(data.y) }) < 120 then at = { x = tonumber(data.x), y = tonumber(data.y), z = tonumber(data.z) or at.z } end
    report(kind, at, kind == 'fire' and 'Fire reported automatically' or 'Crash reported automatically', data.street and Clean(data.street, 120) or nil, 'auto', nil, nil)
    return true
end)

--- still there (+1 confirmation, keeps it alive) / gone (enough "gone" votes clear it)
Register('trafficVote', function(_, phone, data)
    local id, vote = tonumber(data.id), data.vote == 'gone' and -1 or 1
    local r = id and MySQL.single.await("SELECT * FROM opslabs_phone_traffic WHERE id = ? AND status = 'active'", { id })
    if not r then return { error = 'That incident has cleared' } end
    local prev = MySQL.scalar.await('SELECT vote FROM opslabs_phone_traffic_votes WHERE incident = ? AND identifier = ?', { id, phone.identifier })
    if prev then return { error = 'You already voted on this one' } end
    MySQL.insert.await('INSERT INTO opslabs_phone_traffic_votes (incident, identifier, vote) VALUES (?, ?, ?)', { id, phone.identifier, vote })
    if vote > 0 then
        MySQL.update.await('UPDATE opslabs_phone_traffic SET confirms = confirms + 1, updated_at = ?, expires_at = GREATEST(expires_at, ?) WHERE id = ?', { now(), expiry(r.kind), id })
    else
        local gone = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_traffic_votes WHERE incident = ? AND vote < 0', { id }) or 0
        if gone >= math.max(2, math.ceil((r.confirms or 1) / 2)) then MySQL.update.await("UPDATE opslabs_phone_traffic SET status = 'cleared' WHERE id = ?", { id }) end
    end
    for src in pairs(Phones) do Push(src, 'trafficChanged') end
    return { ok = true }
end)

Register('trafficClear', function(src, phone, data)
    local r = MySQL.single.await("SELECT * FROM opslabs_phone_traffic WHERE id = ? AND status = 'active'", { tonumber(data.id) or 0 })
    if not r then return { error = 'Already cleared' } end
    if not (isPolice(src) or r.reporter == phone.identifier or (r.kind == 'closure' and canClose(src))) then return { error = 'Only police or whoever reported it can clear it' } end
    MySQL.update.await("UPDATE opslabs_phone_traffic SET status = 'cleared', updated_at = ? WHERE id = ?", { now(), r.id })
    for s in pairs(Phones) do Push(s, 'trafficChanged') end
    return { ok = true }
end)

--- 10-80: start / position / end (police only); the lead unit's client sends its position while it runs
local pursuitOf = {}            -- src -> incident id
Register('trafficPursuit', function(src, phone, data)
    if not isPolice(src) then return { error = 'Police only' } end
    local act = data.action
    local at = pos(src)
    if act == 'start' then
        if pursuitOf[src] then return { ok = true, id = pursuitOf[src] } end
        local id = MySQL.insert.await([[INSERT INTO opslabs_phone_traffic (kind, detail, street, x, y, z, source, reporter, reporter_name, created_at, updated_at, expires_at)
            VALUES ('pursuit', ?, ?, ?, ?, ?, 'police', ?, ?, ?, ?, ?)]], { data.detail and Clean(data.detail, 200) or 'Vehicle pursuit in progress — keep clear',
            data.street and Clean(data.street, 120) or nil, at.x, at.y, at.z, phone.identifier, phone.name, now(), now(), expiry('pursuit') })
        pursuitOf[src] = id
        announce({ id = id, kind = 'pursuit', detail = data.detail or 'Vehicle pursuit in progress — keep clear', street = data.street, x = at.x, y = at.y, z = at.z, source = 'police', reporter_name = phone.name, confirms = 1, created_at = now(), updated_at = now() })
        return { ok = true, id = id, every = CT.PursuitUpdate or 3 }
    elseif act == 'update' then
        local id = pursuitOf[src]
        if not id then return { ended = true } end
        MySQL.update.await("UPDATE opslabs_phone_traffic SET x = ?, y = ?, z = ?, street = COALESCE(?, street), updated_at = ?, expires_at = ? WHERE id = ? AND status = 'active'",
            { at.x, at.y, at.z, data.street and Clean(data.street, 120) or nil, now(), expiry('pursuit'), id })
        for s in pairs(Phones) do Push(s, 'trafficMove', { id = id, x = at.x, y = at.y, street = data.street }) end
        return { ok = true }
    elseif act == 'end' then
        local id = pursuitOf[src]
        pursuitOf[src] = nil
        if id then MySQL.update.await("UPDATE opslabs_phone_traffic SET status = 'cleared', updated_at = ? WHERE id = ?", { now(), id }) end
        for s in pairs(Phones) do Push(s, 'trafficChanged') end
        return { ok = true }
    end
    return { error = 'bad request' }
end)
AddEventHandler('playerDropped', function()
    local id = pursuitOf[source]
    pursuitOf[source] = nil
    if id then MySQL.update("UPDATE opslabs_phone_traffic SET status = 'cleared' WHERE id = ?", { id }) end
end)

exports('ReportTrafficIncident', function(kind, x, y, z, detail, street)
    if not KINDS[kind] then return nil end
    return report(kind, { x = x, y = y, z = z or 0 }, detail, street, 'system', nil, nil)
end)
