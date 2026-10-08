-- OPS Emergency Alerts: like Wireless Emergency Alerts on a real phone. A company sends an alert to the whole city, to
-- everyone within a radius of a place, or to its own staff; every phone that gets it shows a full-screen alert with the
-- alert tone. Shared with OPS Hub (ops_emergency.py, same table: sql/ops_emergency.sql).
--
-- Premium: a company can only send once a Hub admin switches on its "Emergency Alerts" (ops_companies.emergency_alerts,
-- OPS Hub → Settings → Companies), and only members whose role has alerts.send (super admins: any premium company).
--
-- Live alerts keep being delivered until they end: players who come online, pick up a phone or walk into the area
-- get them too. A phone answers once it has shown an alert, so each player gets each alert once.

local RES = GetCurrentResourceName()
local CFG = Config.Emergency or {}
local SEVERITIES = { info = true, warning = true, severe = true, extreme = true }
local AUDIENCES = { all = true, area = true, staff = true }
local READY = false

local live = {}        -- [id] = alert row (status 'live')
local got = {}         -- [id] = { [src] = true } phones that have shown it (kept after it ends, for the app's history)
local staff = {}       -- [companyId] = { at, set = { [accountId] = true } }
local lastSent = {}    -- [companyId] = os.time() of its last alert

local function now() return os.time() end
local function account(src) return OpsnetUser and OpsnetUser(src) or nil end

local function premium(c) return c ~= nil and IsTrue(c.emergency_alerts) and (c.active == nil or IsTrue(c.active)) end

--- what a phone gets: the alert and who sent it
local function view(a)
    local c = Ops.byId(a.company_id) or {}
    return { id = a.id, severity = a.severity, title = a.title, body = a.body, audience = a.audience,
        x = a.x, y = a.y, radius = a.radius, area = a.area_label, at = a.created_at, expires = a.expires_at,
        company = c.name or 'OPS', color = c.color, icon = c.icon, status = a.status }
end

local function staffSet(coId)
    local s = staff[coId]
    if s and now() - s.at < 30 then return s.set end
    local set = {}
    for _, r in ipairs(MySQL.query.await("SELECT account_id FROM ops_members WHERE company_id = ? AND status = 'active'", { coId }) or {}) do set[r.account_id] = true end
    staff[coId] = { at = now(), set = set }
    return set
end

local function wants(src, a)
    if a.audience == 'all' then return true end
    if a.audience == 'staff' then
        local u = OpsnetUser and OpsnetUser(src)
        return u ~= nil and (staffSet(a.company_id)[u.id] == true)
    end
    if a.audience == 'area' and a.x and a.y and a.radius then
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return false end
        local p = GetEntityCoords(ped)
        local dx, dy = p.x - a.x, p.y - a.y
        return dx * dx + dy * dy <= a.radius * a.radius
    end
    return false
end

local function deliver(a)
    local seen = got[a.id] or {}
    got[a.id] = seen
    local v
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        if not seen[src] and wants(src, a) then
            v = v or view(a)
            TriggerClientEvent('opslabs-phone:emergency', src, v)
        end
    end
end

local function finish(id, status)
    local a = live[id]
    if not a then return end
    live[id] = nil
    for src in pairs(got[id] or {}) do TriggerClientEvent('opslabs-phone:emergencyEnd', src, id, status) end
end

-- the phone showed it
RegisterNetEvent('opslabs-phone:emergencyAck', function(id)
    local src = source
    id = tonumber(id)
    local a = id and live[id]
    if not a or not got[id] or got[id][src] then return end
    got[id][src] = true
    a.reach = (a.reach or 0) + 1
    MySQL.update('UPDATE ops_emergency_alerts SET reach = reach + 1 WHERE id = ?', { id })
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, seen in pairs(got) do seen[src] = nil end   -- back online later: shown again while it is still live
end)

---------------------------------------------------------------------------
-- set-up and the delivery loop
---------------------------------------------------------------------------
CreateThread(function()
    if CFG.Enabled == false then return end
    AwaitDatabase()
    local sql = LoadResourceFile(RES, 'sql/ops_emergency.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ops_companies' AND COLUMN_NAME = 'emergency_alerts']])
    if (tonumber(has) or 0) == 0 then pcall(MySQL.query.await, 'ALTER TABLE ops_companies ADD COLUMN emergency_alerts TINYINT(1) NOT NULL DEFAULT 0') end
    for _, a in ipairs(MySQL.query.await("SELECT * FROM ops_emergency_alerts WHERE status = 'live' AND expires_at > ?", { now() }) or {}) do live[a.id] = a end
    READY = true
    while true do
        local t = now()
        -- sent from OPS Hub: claim it (only one game server picks it up)
        for _, a in ipairs(MySQL.query.await("SELECT * FROM ops_emergency_alerts WHERE status = 'pending'") or {}) do
            local c = Ops.byId(a.company_id)
            if not premium(c) or a.expires_at <= t then
                MySQL.update.await("UPDATE ops_emergency_alerts SET status = 'cancelled', ended_at = ? WHERE id = ? AND status = 'pending'", { t, a.id })
            elseif (MySQL.update.await("UPDATE ops_emergency_alerts SET status = 'live' WHERE id = ? AND status = 'pending'", { a.id }) or 0) > 0 then
                a.status = 'live'
                live[a.id] = a
                lastSent[a.company_id] = t
            end
        end
        -- cancelled on OPS Hub, expired, or the company lost the premium
        local ids = {}
        for id in pairs(live) do ids[#ids + 1] = id end
        if #ids > 0 then
            local rows = MySQL.query.await(('SELECT id, status FROM ops_emergency_alerts WHERE id IN (%s)'):format(table.concat(ids, ',')), {}) or {}
            local st = {}
            for _, r in ipairs(rows) do st[r.id] = r.status end
            for id, a in pairs(live) do
                if st[id] ~= 'live' then
                    finish(id, st[id] or 'cancelled')
                elseif a.expires_at <= t or not premium(Ops.byId(a.company_id)) then
                    MySQL.update.await("UPDATE ops_emergency_alerts SET status = 'ended', ended_at = ? WHERE id = ? AND status = 'live'", { t, id })
                    finish(id, 'ended')
                end
            end
        end
        for _, a in pairs(live) do pcall(deliver, a) end
        Wait(5000)
    end
end)

---------------------------------------------------------------------------
-- phone RPCs (Emergency Alerts app)
---------------------------------------------------------------------------
--- premium companies this account may send for
local function senders(a)
    local out = {}
    if not a then return out end
    for _, c in ipairs(MySQL.query.await('SELECT * FROM ops_companies WHERE emergency_alerts = 1 AND active = 1 ORDER BY name') or {}) do
        if Ops.canId(a, c.id, 'alerts.send') then out[#out + 1] = { id = c.id, code = c.code, name = c.name, color = c.color, icon = c.icon } end
    end
    return out
end

-- alerts this phone got while live, plus city-wide ones of the last day
Register('emergencyInbox', function(src)
    if not READY then return { alerts = {} } end
    local u = account(src)
    local rows = MySQL.query.await([[SELECT * FROM ops_emergency_alerts WHERE status <> 'pending' AND created_at > ? ORDER BY id DESC LIMIT 60]], { now() - 86400 }) or {}
    local out = {}
    for _, a in ipairs(rows) do
        if a.audience == 'all' or (got[a.id] and got[a.id][src]) or (a.audience == 'staff' and u and staffSet(a.company_id)[u.id]) then out[#out + 1] = view(a) end
    end
    return { alerts = out }
end)

Register('emergencyMine', function(src)
    if not READY then return { signedIn = false, senders = {}, sent = {} } end
    local a = account(src)
    if not a then return { signedIn = false, senders = {}, sent = {} } end
    local list = senders(a)
    local sent = {}
    if #list > 0 then
        local ids = {}
        for _, c in ipairs(list) do ids[#ids + 1] = c.id end
        for _, r in ipairs(MySQL.query.await(('SELECT * FROM ops_emergency_alerts WHERE company_id IN (%s) ORDER BY id DESC LIMIT 30'):format(table.concat(ids, ',')), {}) or {}) do
            local v = view(r)
            v.reach, v.sentBy, v.source, v.ended = r.reach, r.sent_by, r.source, r.ended_at
            sent[#sent + 1] = v
        end
    end
    return { signedIn = true, senders = list, sent = sent, radii = CFG.Radii or { 500, 1000, 2000 }, hours = CFG.Hours or { 1, 3, 6 } }
end)

Register('emergencySend', function(src, _, d)
    if not READY then return { error = 'Emergency Alerts are starting up — try again in a moment' } end
    local a = account(src)
    if not a then return { error = 'Sign in to OPS Work first' } end
    local c = Ops.byId(tonumber(d.company))
    if not premium(c) then return { error = 'This company doesn’t have Emergency Alerts — ask an OPS Hub admin to switch it on' } end
    if not Ops.canId(a, c.id, 'alerts.send') then return { error = 'Your role can’t send emergency alerts for ' .. c.name } end
    local severity = SEVERITIES[d.severity] and d.severity or 'warning'
    local audience = AUDIENCES[d.audience] and d.audience or 'all'
    local title, body = Clean(d.title, 80), Clean(d.body, 600)
    if title == '' or body == '' then return { error = 'Give the alert a headline and a message' } end
    local t = now()
    if lastSent[c.id] and t - lastSent[c.id] < (CFG.Cooldown or 60) then
        return { error = ('Wait %d s before sending another alert for %s'):format((CFG.Cooldown or 60) - (t - lastSent[c.id]), c.name) }
    end
    local n = 0
    for _, x in pairs(live) do if x.company_id == c.id then n = n + 1 end end
    if n >= (CFG.MaxLive or 3) then return { error = ('%s already has %d live alerts — cancel one first'):format(c.name, n) } end
    local hours = 1
    for _, h in ipairs(CFG.Hours or { 1 }) do if tonumber(d.hours) == h then hours = h end end
    local x, y, radius, label
    if audience == 'area' then
        local p = GetEntityCoords(GetPlayerPed(src))
        radius = 500
        for _, r in ipairs(CFG.Radii or { 500 }) do if tonumber(d.radius) == r then radius = r end end
        x, y = p.x + 0.0, p.y + 0.0
        label = d.area and Clean(d.area, 80) or nil
        if label == '' then label = nil end
    end
    local id = MySQL.insert.await([[INSERT INTO ops_emergency_alerts (company_id, severity, title, body, audience, x, y, radius, area_label, status, source, sent_by, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'live', 'phone', ?, ?, ?)]],
        { c.id, severity, title, body, audience, x, y, radius, label, Ops.nameOf(a), t, t + hours * 3600 })
    if not id then return { error = 'Couldn’t save the alert' } end
    lastSent[c.id] = t
    local row = MySQL.single.await('SELECT * FROM ops_emergency_alerts WHERE id = ?', { id })
    live[id] = row
    Ops.audit(Ops.nameOf(a), c.id, 'emergency.send', id, ('%s · %s · %s'):format(severity, audience, title))
    deliver(row)
    return { ok = true, id = id }
end)

Register('emergencyCancel', function(src, _, d)
    local a = account(src)
    local row = a and MySQL.single.await('SELECT * FROM ops_emergency_alerts WHERE id = ?', { tonumber(d.id) })
    if not row then return { error = 'Alert not found' } end
    if not Ops.canId(a, row.company_id, 'alerts.send') then return { error = 'You can’t cancel this alert' } end
    if row.status ~= 'live' and row.status ~= 'pending' then return { ok = true } end
    MySQL.update.await("UPDATE ops_emergency_alerts SET status = 'cancelled', ended_at = ? WHERE id = ?", { now(), row.id })
    Ops.audit(Ops.nameOf(a), row.company_id, 'emergency.cancel', row.id, row.title)
    finish(row.id, 'cancelled')
    return { ok = true }
end)
