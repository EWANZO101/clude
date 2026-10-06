-- Gunshot detection (OPS Sentinel acoustic sensors). Sensors are placed fixtures (opslabs_gunshot_sensor);
-- one is online when it has OPS Mobile signal where it's fitted (its LTE backhaul) and no fault on it.
-- Clients report their own gunfire; every online sensor in earshot hears it. Incidents are located better the
-- more sensors hear them, merged when shots come close together, saved, pushed to police in game and served
-- to OPS Hub (GET /api/gunshots).

local CG = Config.Gunshot or {}
if CG.Enabled == false then return end

local Incidents = {}        -- id -> incident (recent, in memory; all in opslabs_towers_gunshots)
local lastEvent = {}        -- src -> { t, n } rate limit
local heardAt = {}          -- sensor fixture id -> os.time() it last heard a shot

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_gunshots` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL,
        `accuracy` FLOAT NOT NULL DEFAULT 50,
        `sensors` INT NOT NULL DEFAULT 1,
        `rounds` INT NOT NULL DEFAULT 1,
        `weapon` VARCHAR(24) DEFAULT NULL,
        `street` VARCHAR(80) DEFAULT NULL,
        `status` VARCHAR(12) NOT NULL DEFAULT 'new',
        `handled_by` VARCHAR(60) DEFAULT NULL,
        `note` VARCHAR(255) DEFAULT NULL,
        `created_at` INT NOT NULL,
        `updated_at` INT NOT NULL,
        PRIMARY KEY (`id`), KEY `created` (`created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_gunshots WHERE created_at > ? ORDER BY id DESC LIMIT 200', { os.time() - 86400 * 2 }) or {}) do
        Incidents[r.id] = r
    end
end)

---------------------------------------------------------------------------
-- sensors
---------------------------------------------------------------------------

--- OPS Mobile bars at a spot (same maths as the phones' coverage)
local function cellBars(c)
    local best = 0
    for _, t in pairs(Towers or {}) do
        if t.type == 'cell' and t.active and not (FaultEffects and FaultEffects.towers[t.id]) then
            local s = 1 - math.sqrt((c.x - t.x) ^ 2 + (c.y - t.y) ^ 2) / (t.range or 1)
            if s > best then best = s end
        end
    end
    if best <= 0 then return 0 end
    return math.min(4, math.floor(best * 4) + 1)
end

local function sensors()
    local out = {}
    for id, f in pairs(Cabling.fixtures) do
        if f.model == CG.Model then
            local bars = Config.Enforce == false and 4 or cellBars(f)
            local fault = FaultEffects and FaultEffects.fixtures[id]
            out[#out + 1] = { id = id, x = f.x, y = f.y, z = f.z, bars = bars, fault = fault or nil,
                online = bars >= (CG.MinBars or 1) and not fault, heard = heardAt[id] }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function exempt(c)
    for _, z in ipairs(CG.Exempt or {}) do
        if math.sqrt((c.x - z[1]) ^ 2 + (c.y - z[2]) ^ 2) <= z[4] and math.abs(c.z - z[3]) < 15 then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- incidents
---------------------------------------------------------------------------

local function public(i)
    return { id = i.id, x = i.x, y = i.y, z = i.z, accuracy = i.accuracy, sensors = i.sensors, rounds = i.rounds, weapon = i.weapon,
        street = i.street, status = i.status, handled_by = i.handled_by, note = i.note, created_at = i.created_at, updated_at = i.updated_at }
end

local function alertPolice(i, update)
    local jobs = {}
    for _, j in ipairs(CG.AlertJobs or {}) do jobs[j] = true end
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local job = FW.Job and FW.Job(src)
        if job and jobs[job] then
            TriggerClientEvent('opslabs-towers:gunshotAlert', src, public(i), update == true)
            if not update and GetResourceState('opslabs-phone') == 'started' then
                pcall(function()
                    exports['opslabs-phone']:Notify(src, 'Shots fired', ('%d round%s · %s · ±%d m'):format(i.rounds, i.rounds == 1 and '' or 's',
                        i.street or 'unknown street', math.floor(i.accuracy)), 'maps', 'fa-solid fa-crosshairs')
                end)
            end
        end
    end
end

local function record(c, weapon, silenced, rounds, street)
    local range = silenced and (CG.SilencedRange or 60.0) or (CG.Range or 450.0)
    local heard = {}
    for _, s in ipairs(sensors()) do
        if s.online and math.sqrt((c.x - s.x) ^ 2 + (c.y - s.y) ^ 2 + (c.z - s.z) ^ 2) <= range then heard[#heard + 1] = s end
    end
    if #heard == 0 then return end
    local now = os.time()
    for _, s in ipairs(heard) do heardAt[s.id] = now end
    local acc = (CG.Accuracy or {})[math.min(3, #heard)] or 50.0
    -- the same burst / gunfight: add to it
    for _, i in pairs(Incidents) do
        if now - i.updated_at <= (CG.MergeSeconds or 12) and math.sqrt((c.x - i.x) ^ 2 + (c.y - i.y) ^ 2) <= (CG.MergeDistance or 150.0) then
            i.rounds = i.rounds + rounds
            i.updated_at = now
            if #heard > i.sensors then
                i.sensors, i.accuracy = #heard, acc
                local a, r = math.random() * math.pi * 2, math.random() * acc * 0.6
                i.x, i.y, i.z = c.x + math.cos(a) * r, c.y + math.sin(a) * r, c.z
            end
            if weapon and i.weapon ~= weapon then i.weapon = (i.weapon and i.weapon ~= weapon) and 'mixed' or weapon end
            MySQL.update('UPDATE opslabs_towers_gunshots SET x = ?, y = ?, z = ?, accuracy = ?, sensors = ?, rounds = ?, weapon = ?, updated_at = ? WHERE id = ?',
                { i.x, i.y, i.z, i.accuracy, i.sensors, i.rounds, i.weapon, now, i.id })
            alertPolice(i, true)
            return
        end
    end
    -- a new incident: reported position is off by up to the accuracy (fewer sensors = rougher fix)
    local a, r = math.random() * math.pi * 2, math.random() * acc * 0.6
    local i = { x = c.x + math.cos(a) * r, y = c.y + math.sin(a) * r, z = c.z, accuracy = acc, sensors = #heard, rounds = rounds,
        weapon = weapon, street = street, status = 'new', created_at = now, updated_at = now }
    i.id = MySQL.insert.await([[INSERT INTO opslabs_towers_gunshots (x, y, z, accuracy, sensors, rounds, weapon, street, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'new', ?, ?)]], { i.x, i.y, i.z, i.accuracy, i.sensors, i.rounds, i.weapon, i.street, now, now })
    if not i.id then return end
    Incidents[i.id] = i
    print(('[opslabs-towers] gunshot incident #%d · %d round(s) · %d sensor(s) · %s'):format(i.id, rounds, #heard, street or '?'))
    alertPolice(i, false)
    -- keep the table small
    if i.id % 50 == 0 then
        MySQL.update('DELETE FROM opslabs_towers_gunshots WHERE id <= ?', { i.id - (CG.Keep or 500) })
        for id, x in pairs(Incidents) do if now - x.created_at > 86400 * 2 then Incidents[id] = nil end end
    end
end

local WEAPON_GROUPS = { pistol = true, smg = true, rifle = true, mg = true, shotgun = true, sniper = true, heavy = true, other = true }

RegisterNetEvent('opslabs-towers:gunshot', function(rounds, weapon, silenced, street)
    local src = source
    local now = GetGameTimer()
    local le = lastEvent[src] or { t = 0, n = 0 }
    if now - le.t < 300 then return end                    -- client batches every ~0.5 s
    le.t = now
    lastEvent[src] = le
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)                          -- the server's idea of where they are, not the client's
    if exempt(c) then return end
    rounds = math.max(1, math.min(30, math.floor(tonumber(rounds) or 1)))
    weapon = WEAPON_GROUPS[weapon] and weapon or 'other'
    street = type(street) == 'string' and street:sub(1, 80) or nil
    record({ x = c.x, y = c.y, z = c.z }, weapon, silenced == true, rounds, street)
end)
AddEventHandler('playerDropped', function() lastEvent[source] = nil end)

---------------------------------------------------------------------------
-- OPS Hub (server/api.lua) + exports
---------------------------------------------------------------------------

function GunshotList(all)
    local list = {}
    if all then
        list = MySQL.query.await('SELECT * FROM opslabs_towers_gunshots ORDER BY id DESC LIMIT 200') or {}
    else
        for _, i in pairs(Incidents) do if i.status ~= 'closed' then list[#list + 1] = public(i) end end
        table.sort(list, function(a, b) return a.id > b.id end)
    end
    local ss = sensors()
    local online = 0
    for _, s in ipairs(ss) do if s.online then online = online + 1 end end
    local today, open = 0, 0
    local since = os.time() - 86400
    for _, i in pairs(Incidents) do
        if i.created_at >= since then today = today + 1 end
        if i.status ~= 'closed' then open = open + 1 end
    end
    return { incidents = list, sensors = ss, stats = { sensors = #ss, online = online, today = today, open = open }, now = os.time() }
end

function GunshotSetStatus(id, status, actor, note)
    id = tonumber(id)
    if status ~= 'ack' and status ~= 'closed' and status ~= 'new' then return nil, 'status must be ack, closed or new' end
    local i = Incidents[id]
    if not i then
        local row = MySQL.single.await('SELECT * FROM opslabs_towers_gunshots WHERE id = ?', { id })
        if not row then return nil, 'Incident not found' end
        i = row
    end
    i.status = status
    i.handled_by = actor and tostring(actor):sub(1, 60) or i.handled_by
    if type(note) == 'string' and note ~= '' then i.note = note:sub(1, 255) end
    MySQL.update.await('UPDATE opslabs_towers_gunshots SET status = ?, handled_by = ?, note = ? WHERE id = ?', { i.status, i.handled_by, i.note, id })
    return true
end

exports('GetGunshots', function(all) return GunshotList(all) end)
