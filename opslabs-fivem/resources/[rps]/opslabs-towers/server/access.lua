-- OPS Access (Config.Access): door hubs & readers. Placing one of Config.Access.ReaderModel on the Buildings &
-- sites → OPS Access menu IS placing a hub — there's no separate activation step, its row here is created the
-- first time anything asks about it. [E] it to tap (grant/deny, opens every door linked to it for a few seconds);
-- further away or held, [E] opens its menu (link nearby doors, set which companies' staff tap straight in, issue
-- or revoke individual cards, arm/disarm). OPS Hub's "OPS Access gates & security" page drives the same hubs over
-- HTTP (server/api.lua: GET /api/access, POST /api/access/action) — see admin/_access_gates.html on that end.
-- Alarms (motion / impact / glass-break / manual) are server/sensors.lua's table, not this one.

local CA = Config.Access or {}
if CA.Enabled == false then return end

local Hubs = {}         -- fixture_id -> { companies = {<job name>, ...}, armed = bool }
local lastAlarmAt = {}  -- fixture_id -> os.time() of the last alarm this hub raised (Config.Access.AlarmCooldownSeconds)

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_access_hubs (
        fixture_id INT NOT NULL,
        companies TEXT NULL,
        armed TINYINT NOT NULL DEFAULT 0,
        PRIMARY KEY (fixture_id)
    )]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_access_doors (
        id INT NOT NULL AUTO_INCREMENT,
        hub_fixture_id INT NOT NULL,
        door_fixture_id INT NOT NULL,
        door_index INT NOT NULL,
        PRIMARY KEY (id),
        UNIQUE KEY hub_door (hub_fixture_id, door_fixture_id, door_index)
    )]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_access_cards (
        id INT NOT NULL AUTO_INCREMENT,
        hub_fixture_id INT NOT NULL,
        identifier VARCHAR(100) NOT NULL,
        holder_name VARCHAR(100) NULL,
        issued_by VARCHAR(100) NULL,
        issued_at INT NOT NULL,
        PRIMARY KEY (id),
        UNIQUE KEY hub_identifier (hub_fixture_id, identifier)
    )]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_access_log (
        id INT NOT NULL AUTO_INCREMENT,
        hub_fixture_id INT NOT NULL,
        identifier VARCHAR(100) NULL,
        holder_name VARCHAR(100) NULL,
        granted TINYINT NOT NULL,
        at INT NOT NULL,
        PRIMARY KEY (id)
    )]])
    for _, r in ipairs(MySQL.query.await('SELECT fixture_id, companies, armed FROM opslabs_towers_access_hubs') or {}) do
        local ok, companies = pcall(json.decode, r.companies or '[]')
        Hubs[r.fixture_id] = { companies = (ok and type(companies) == 'table') and companies or {}, armed = r.armed == 1 }
    end
end)

local function now() return os.time() end

local function hub(fid)
    if not Hubs[fid] then Hubs[fid] = { companies = {}, armed = false } end
    return Hubs[fid]
end

local function persistHub(fid)
    local h = hub(fid)
    MySQL.query('INSERT INTO opslabs_towers_access_hubs (fixture_id, companies, armed) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE companies = VALUES(companies), armed = VALUES(armed)',
        { fid, json.encode(h.companies), h.armed and 1 or 0 })
end

local function readerModel() return CA.ReaderModel or 'opslabs_cctv_reader' end

local function readers()
    local out = {}
    for fid, f in pairs(Cabling.fixtures) do
        if f.model == readerModel() then out[#out + 1] = f end
    end
    return out
end

local function doorsOfHub(fid)
    local rows = MySQL.query.await('SELECT id, door_fixture_id, door_index FROM opslabs_towers_access_doors WHERE hub_fixture_id = ?', { fid }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local label = 'Door'
        if Cabling.fixtures[r.door_fixture_id] and DoorsOf then
            for _, d in ipairs(DoorsOf(r.door_fixture_id)) do if d.idx == r.door_index then label = d.label end end
        end
        out[#out + 1] = { link = r.id, fid = r.door_fixture_id, idx = r.door_index, label = label }
    end
    return out
end

local function cardsOfHub(fid)
    return MySQL.query.await('SELECT id, identifier, holder_name, issued_by, issued_at FROM opslabs_towers_access_cards WHERE hub_fixture_id = ?', { fid }) or {}
end

local function hasCard(fid, identifier)
    if not identifier then return false end
    local rows = MySQL.query.await('SELECT id FROM opslabs_towers_access_cards WHERE hub_fixture_id = ? AND identifier = ?', { fid, identifier })
    return rows and rows[1] ~= nil
end

local function hasAccess(src, fid)
    local h = hub(fid)
    local job = FW.Job and FW.Job(src)
    if job then for _, c in ipairs(h.companies) do if c == job then return true end end end
    return hasCard(fid, FW.Identifier and FW.Identifier(src))
end

--- can manage this hub (arm/disarm, link doors, set companies, issue/revoke cards): an admin/engineer, or
--- already has access to it themselves — same shape as server/cctv.lua's isStaff() / org_job check
local function canManage(src, fid)
    return IsTowerAdmin(src) or CanCable(src) or hasAccess(src, fid)
end

local function logTap(fid, src, granted)
    MySQL.query('INSERT INTO opslabs_towers_access_log (hub_fixture_id, identifier, holder_name, granted, at) VALUES (?, ?, ?, ?, ?)',
        { fid, FW.Identifier and FW.Identifier(src), FW.Name and FW.Name(src) or GetPlayerName(src), granted and 1 or 0, now() })
end

local function lastTap(fid)
    local rows = MySQL.query.await('SELECT holder_name, granted, at FROM opslabs_towers_access_log WHERE hub_fixture_id = ? ORDER BY at DESC LIMIT 1', { fid })
    local r = rows and rows[1]
    return r and { granted = r.granted == 1, holder_name = r.holder_name, at = r.at } or nil
end

local function maybeAlarm(fid, kind, detail, pos)
    local h = hub(fid)
    if not h.armed or not RaiseAlarm then return end
    local t = now()
    if lastAlarmAt[fid] and t - lastAlarmAt[fid] < (CA.AlarmCooldownSeconds or 60) then return end
    lastAlarmAt[fid] = t
    RaiseAlarm(fid, kind, detail, pos)
end

--- open every door linked to a hub; true if it actually opened at least one
local function openHubDoors(fid)
    local any = false
    for _, d in ipairs(doorsOfHub(fid)) do
        if RemoteOpenDoor and Cabling.fixtures[d.fid] and RemoteOpenDoor(d.fid, d.idx) then any = true end
    end
    return any
end

---------------------------------------------------------------------------
-- in-game: tap the reader, its management menu
---------------------------------------------------------------------------

--- [E] on the reader: grant or deny, open its doors on a grant
lib.callback.register('opslabs-towers:access:tap', function(src, fid)
    fid = tonumber(fid)
    if not Cabling.fixtures[fid] then return { error = 'Not found' } end
    local granted = hasAccess(src, fid)
    logTap(fid, src, granted)
    if granted then
        if not openHubDoors(fid) then return { ok = true, granted = true, note = 'Access granted, but nothing is linked to this reader yet' } end
    else
        maybeAlarm(fid, 'impact', ('Denied access attempt by %s'):format(FW.Name and FW.Name(src) or GetPlayerName(src)), GetEntityCoords(GetPlayerPed(src)))
    end
    return { ok = true, granted = granted }
end)

--- held / the menu key on the reader: everything needed to draw the OPS Access menu for it
lib.callback.register('opslabs-towers:access:menu', function(src, fid)
    fid = tonumber(fid)
    if not Cabling.fixtures[fid] then return { error = 'Not found' } end
    local h = hub(fid)
    return { ok = true, hub = { id = fid, companies = h.companies, armed = h.armed },
        doors = doorsOfHub(fid), cards = cardsOfHub(fid), canManage = canManage(src, fid) }
end)

--- doors within Config.Access.LinkRadius of this hub, for the "link a door" picker
lib.callback.register('opslabs-towers:access:linkable', function(src, fid)
    fid = tonumber(fid)
    local f = Cabling.fixtures[fid]
    if not f then return { error = 'Not found' } end
    local out = {}
    if DoorsOf then
        for otherFid, other in pairs(Cabling.fixtures) do
            local dist = #(vector3(f.x, f.y, f.z) - vector3(other.x, other.y, other.z))
            if dist <= (CA.LinkRadius or 20.0) then
                for _, d in ipairs(DoorsOf(otherFid)) do
                    out[#out + 1] = { fid = otherFid, idx = d.idx, label = d.label, dist = dist }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return { ok = true, doors = out }
end)

lib.callback.register('opslabs-towers:access:link', function(src, fid, doorFid, doorIdx)
    fid, doorFid, doorIdx = tonumber(fid), tonumber(doorFid), tonumber(doorIdx)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    if not Cabling.fixtures[doorFid] then return { error = 'That door is gone' } end
    local ok = pcall(function()
        MySQL.insert.await('INSERT INTO opslabs_towers_access_doors (hub_fixture_id, door_fixture_id, door_index) VALUES (?, ?, ?)', { fid, doorFid, doorIdx })
    end)
    return ok and { ok = true } or { error = 'Already linked' }
end)

lib.callback.register('opslabs-towers:access:unlink', function(src, fid, linkId)
    fid, linkId = tonumber(fid), tonumber(linkId)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    MySQL.query('DELETE FROM opslabs_towers_access_doors WHERE id = ? AND hub_fixture_id = ?', { linkId, fid })
    return { ok = true }
end)

lib.callback.register('opslabs-towers:access:setCompanies', function(src, fid, companies)
    fid = tonumber(fid)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    local h = hub(fid)
    h.companies = type(companies) == 'table' and companies or {}
    persistHub(fid)
    return { ok = true }
end)

lib.callback.register('opslabs-towers:access:arm', function(src, fid, armed)
    fid = tonumber(fid)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    local h = hub(fid)
    h.armed = armed and true or false
    persistHub(fid)
    return { ok = true, armed = h.armed }
end)

--- issue a card to whoever's standing right next to you
lib.callback.register('opslabs-towers:access:issueCard', function(src, fid)
    fid = tonumber(fid)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    local c = GetEntityCoords(GetPlayerPed(src))
    local best, bd
    for _, id in ipairs(GetPlayers()) do
        local s = tonumber(id)
        if s ~= src then
            local p = GetPlayerPed(s)
            if p ~= 0 then
                local d = #(GetEntityCoords(p) - c)
                if d < 3.0 and (not bd or d < bd) then best, bd = s, d end
            end
        end
    end
    if not best then return { error = 'Stand next to the person you want to issue a card to' } end
    local identifier = FW.Identifier and FW.Identifier(best)
    local name = FW.Name and FW.Name(best) or GetPlayerName(best)
    if not identifier then return { error = 'Could not identify that player' } end
    MySQL.query('INSERT INTO opslabs_towers_access_cards (hub_fixture_id, identifier, holder_name, issued_by, issued_at) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE holder_name = VALUES(holder_name)',
        { fid, identifier, name, FW.Name and FW.Name(src) or GetPlayerName(src), now() })
    return { ok = true, name = name }
end)

lib.callback.register('opslabs-towers:access:revokeCard', function(src, fid, cardId)
    fid, cardId = tonumber(fid), tonumber(cardId)
    if not canManage(src, fid) then return { error = 'not allowed' } end
    MySQL.query('DELETE FROM opslabs_towers_access_cards WHERE id = ? AND hub_fixture_id = ?', { cardId, fid })
    return { ok = true }
end)

---------------------------------------------------------------------------
-- HTTP (server/api.lua): GET /api/access, POST /api/access/action — OPS Hub's "OPS Access gates & security" page
---------------------------------------------------------------------------

function AccessState()
    local out = {}
    for _, f in ipairs(readers()) do
        local h = hub(f.id)
        local doors = doorsOfHub(f.id)
        local doorLabels = {}
        for _, d in ipairs(doors) do doorLabels[#doorLabels + 1] = { label = d.label } end
        local alarm = OpenAlarmFor and OpenAlarmFor(f.id) or nil
        out[#out + 1] = {
            id = f.id,
            label = 'OPS Access hub #' .. f.id,
            x = f.x, y = f.y,   -- so OPS Hub's Grid control map (gridcontrol.js) can plot gates on the pole map
            doors = doorLabels,
            companies = h.companies,
            credentials = #cardsOfHub(f.id),
            lastTap = lastTap(f.id),
            linked = #doors > 0,
            armed = h.armed,
            alarm = alarm and { id = alarm.id, kind = alarm.kind, detail = alarm.detail, created_at = alarm.created_at } or nil,
        }
    end
    return { hubs = out }
end

function AccessAction(data, actor)
    local action = data.action
    if action == 'open' then
        local fid = tonumber(data.hub)
        if not fid or not Cabling.fixtures[fid] then return false, 'Hub not found' end
        if not openHubDoors(fid) then return false, 'Not linked to a door yet' end
        return true
    elseif action == 'set_companies' then
        local fid = tonumber(data.hub)
        if not fid or not Cabling.fixtures[fid] then return false, 'Hub not found' end
        local h = hub(fid)
        h.companies = type(data.companies) == 'table' and data.companies or {}
        persistHub(fid)
        return true
    elseif action == 'arm' then
        local fid = tonumber(data.hub)
        if not fid or not Cabling.fixtures[fid] then return false, 'Hub not found' end
        local h = hub(fid)
        h.armed = data.armed and true or false
        persistHub(fid)
        return true
    elseif action == 'alert911' then
        local jobs = {}
        for _, j in ipairs(CA.AlertJobs or {}) do jobs[j] = true end
        local text = tostring(data.message or ('Manual alert from OPS Access' .. (actor and (' · ' .. actor) or '')))
        for _, id in ipairs(GetPlayers()) do
            local src = tonumber(id)
            local job = FW.Job and FW.Job(src)
            if job and jobs[job] then
                TriggerClientEvent('opslabs-towers:access:alert', src, text)
                if GetResourceState('opslabs-phone') == 'started' then
                    pcall(function() exports['opslabs-phone']:Notify(src, 'OPS Access alert', text, 'system', 'fa-solid fa-triangle-exclamation') end)
                end
            end
        end
        if RaiseAlarm then RaiseAlarm(nil, 'manual', text) end
        return true
    end
    return false, 'Unknown action'
end

---------------------------------------------------------------------------
-- a reader removed from the map takes its hub, door links and cards with it
---------------------------------------------------------------------------

AddEventHandler('opslabs-towers:fixtureRemoved', function(fid)
    if not Hubs[fid] then return end
    Hubs[fid], lastAlarmAt[fid] = nil, nil
    MySQL.query('DELETE FROM opslabs_towers_access_hubs WHERE fixture_id = ?', { fid })
    MySQL.query('DELETE FROM opslabs_towers_access_doors WHERE hub_fixture_id = ?', { fid })
    MySQL.query('DELETE FROM opslabs_towers_access_cards WHERE hub_fixture_id = ?', { fid })
end)

---------------------------------------------------------------------------
-- armed hubs: anyone without access lingering by one of their doors trips a 'motion' alarm (throttled)
---------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait((CA.MotionCheckSeconds or 5) * 1000)
        for fid, h in pairs(Hubs) do
            if h.armed and Cabling.fixtures[fid] then
                for _, d in ipairs(doorsOfHub(fid)) do
                    local pos = DoorPos and select(1, DoorPos(d.fid, d.idx))
                    if pos then
                        for _, id in ipairs(GetPlayers()) do
                            local src = tonumber(id)
                            local ped = GetPlayerPed(src)
                            if ped ~= 0 and #(GetEntityCoords(ped) - pos) <= (CA.MotionRadius or 8.0) and not hasAccess(src, fid) then
                                maybeAlarm(fid, 'motion', ('Movement near %s with no access'):format(d.label), pos)
                            end
                        end
                    end
                end
            end
        end
    end
end)
