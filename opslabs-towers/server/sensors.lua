-- OPS Access security sensors (Config.Access): the alarm history for motion / impact / glass-break / manual
-- events raised against an OPS Access hub (server/access.lua) or a manual 911 alert. Separate file and table from
-- access.lua itself because this is a flat log + acknowledge/close workflow, not hub state — matches the web
-- page's own split (admin/_access_gates.html: access.lua for the live hub list, this for the fuller alarm history).

local CA = Config.Access or {}
if CA.Enabled == false then return end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_access_alarms (
        id INT NOT NULL AUTO_INCREMENT,
        hub_fixture_id INT NULL,
        kind VARCHAR(20) NOT NULL,
        detail VARCHAR(200) NULL,
        x FLOAT NULL, y FLOAT NULL, z FLOAT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'open',
        created_at INT NOT NULL,
        closed_at INT NULL,
        PRIMARY KEY (id)
    )]])
end)

local function now() return os.time() end

local function public(a)
    return { id = a.id, hub = a.hub_fixture_id, kind = a.kind, detail = a.detail, status = a.status, created_at = a.created_at }
end

--- raise a new alarm — called by server/access.lua (armed hub tripped) or its own alert911 action (hub = nil)
function RaiseAlarm(hubFid, kind, detail, pos)
    return MySQL.insert.await('INSERT INTO opslabs_towers_access_alarms (hub_fixture_id, kind, detail, x, y, z, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { hubFid, kind, detail, pos and pos.x or nil, pos and pos.y or nil, pos and pos.z or nil, now() })
end

--- the most recent still-open alarm for one hub — ridden along on that hub's own row in server/access.lua
function OpenAlarmFor(hubFid)
    local rows = MySQL.query.await("SELECT id, hub_fixture_id, kind, detail, status, created_at FROM opslabs_towers_access_alarms WHERE hub_fixture_id = ? AND status != 'closed' ORDER BY created_at DESC LIMIT 1", { hubFid })
    return rows and rows[1] and public(rows[1]) or nil
end

--- GET /api/sensors — the fuller history (OPS Hub's "Recent alarms" list)
function SensorsState()
    local rows = MySQL.query.await('SELECT id, hub_fixture_id, kind, detail, status, created_at FROM opslabs_towers_access_alarms ORDER BY created_at DESC LIMIT 50') or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = public(r) end
    return { alarms = out }
end

--- POST /api/sensors/action — acknowledge or close one alarm
function SensorsAction(data, actor)
    local id = tonumber(data.alarm)
    if not id then return false, 'Bad alarm id' end
    if data.action == 'ack' then
        MySQL.update.await("UPDATE opslabs_towers_access_alarms SET status = 'acknowledged' WHERE id = ? AND status = 'open'", { id })
        return true
    elseif data.action == 'close' then
        MySQL.update.await("UPDATE opslabs_towers_access_alarms SET status = 'closed', closed_at = ? WHERE id = ?", { now(), id })
        return true
    end
    return false, 'Unknown action'
end

--- in-game: staff/admin can also ack or close from the hub itself, not just the web
lib.callback.register('opslabs-towers:access:ackAlarm', function(src, id, close)
    if not (IsTowerAdmin(src) or CanCable(src)) then return { error = 'not allowed' } end
    local ok, err = SensorsAction({ action = close and 'close' or 'ack', alarm = id }, FW.Name and FW.Name(src) or GetPlayerName(src))
    return ok and { ok = true } or { error = err }
end)

-- alarms older than a week are just history clutter by then
CreateThread(function()
    while true do
        Wait(3600000)
        pcall(MySQL.query.await, 'DELETE FROM opslabs_towers_access_alarms WHERE status = \'closed\' AND closed_at < ?', { now() - 7 * 86400 })
    end
end)
