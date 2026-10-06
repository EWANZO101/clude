-- OPS Track (Config.Track): GPS trackers fitted inside vehicles.
-- Each tracker is keyed by number plate. While the vehicle exists in the world it reports position, speed and ignition
-- every Config.Track.Report seconds over OPS Mobile (ComputeCoverage): no signal → it keeps the fix and reports late.
-- Pro units: backup battery when the vehicle power is cut (tamper alert), ignition / door inputs, immobiliser relay.
-- Owners (ESX owned_vehicles) see theirs with /track; staff see all; OPS Hub → Vehicle tracking.

local CT = Config.Track or {}
if not CT.Enabled then return end
local UNITS = CT.Units or {}

local Trackers = {}          -- plate -> row + live state
local Events = {}            -- newest first (OPS Hub)
local function now() return os.time() end
local function norm(p) return (tostring(p or ''):gsub('^%s+', ''):gsub('%s+$', ''):upper()) end
local function round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_trackers` (
        `id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY, `plate` VARCHAR(16) NOT NULL UNIQUE, `unit` VARCHAR(16) NOT NULL,
        `imei` VARCHAR(20) NOT NULL, `owner` VARCHAR(80) NULL, `owner_name` VARCHAR(80) NULL, `label` VARCHAR(60) NULL,
        `model` VARCHAR(40) NULL, `installed_by` VARCHAR(80) NULL, `installed_at` INT NOT NULL DEFAULT 0, `data` LONGTEXT NULL)]])
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_trackers') or {}) do
        local d = r.data and json.decode(r.data) or {}
        r.s = type(d) == 'table' and d or {}
        Trackers[r.plate] = r
    end
end)

local function persist(t)
    MySQL.update('UPDATE opslabs_towers_trackers SET owner = ?, owner_name = ?, label = ?, data = ? WHERE plate = ?',
        { t.owner, t.owner_name, t.label, json.encode(t.s), t.plate })
end

local function canInstall(src)
    if #(CT.Jobs or {}) == 0 then return true end
    local job = FW.Job(src)
    for _, j in ipairs(CT.Jobs) do if j == job then return true end end
    return FW.IsAdmin(src)
end
local function isOwner(src, t) local id = FW.Identifier(src) return id ~= nil and id == t.owner end

local function event(t, kind, text)
    table.insert(Events, 1, { at = now(), plate = t.plate, kind = kind, text = text, x = t.s.x, y = t.s.y })
    while #Events > 60 do table.remove(Events) end
    -- tell the owner wherever they are
    local src = FW.SourceOf(t.owner)
    if src then
        TriggerClientEvent('opslabs-towers:track:alert', src, { plate = t.plate, label = t.label, kind = kind, text = text, x = t.s.x, y = t.s.y })
        if GetResourceState('opslabs-phone') == 'started' then
            pcall(function() exports['opslabs-phone']:Notify(src, 'OPS Track', ('%s · %s'):format(t.label or t.plate, text), 'system', 'fa-solid fa-location-crosshairs') end)
        end
    end
end

local function ownerOf(plate)
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT owner FROM owned_vehicles WHERE UPPER(TRIM(plate)) = ? LIMIT 1', { plate })
    end)
    if not ok or not row then return nil, nil end
    local name
    pcall(function()
        local u = MySQL.single.await('SELECT firstname, lastname FROM users WHERE identifier = ? LIMIT 1', { row.owner })
        if u then name = ((u.firstname or '') .. ' ' .. (u.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '') end
    end)
    return row.owner, name
end

---------------------------------------------------------------------------
-- reporting
---------------------------------------------------------------------------
local function vehicles()
    local out = {}
    for _, v in ipairs(GetAllVehicles()) do
        local p = norm(GetVehicleNumberPlateText(v))
        if Trackers[p] then out[p] = v end
    end
    return out
end

local function tick(dt)
    local live = vehicles()
    for plate, t in pairs(Trackers) do
        local s, unit = t.s, UNITS[t.unit] or {}
        local veh = live[plate]
        -- power: vehicle supply, or the backup battery once it's been cut
        s.battery = s.battery or 100
        if s.cut then
            if unit.backup and s.battery > 0 then s.battery = math.max(0, s.battery - dt / 3600 / (CT.BackupHours or 48) * 100) end
        elseif s.battery < 100 then s.battery = math.min(100, s.battery + dt / 36) end
        local on = not s.cut or (unit.backup and s.battery > 0)
        if on and s.cut and s.battery <= 0 then on = false end
        s.online = on
        if veh and DoesEntityExist(veh) then
            local c = GetEntityCoords(veh)
            local cov = ComputeCoverage and ComputeCoverage(c) or { cell = 4 }
            s.bars = cov.cell or 0
            s.inWorld = true
            if on then
                s.fx, s.fy, s.fz = c.x, c.y, c.z                         -- the unit always knows where it is
                local spd = round(GetEntitySpeed(veh) * 3.6, 0)
                local ign = unit.io and GetIsVehicleEngineRunning(veh) or nil
                if s.bars > 0 then
                    local moved = s.x and math.sqrt((c.x - s.x) ^ 2 + (c.y - s.y) ^ 2) or 999
                    s.x, s.y, s.z, s.at, s.speed, s.ign = round(c.x, 1), round(c.y, 1), round(c.z, 1), now(), spd, ign
                    s.trail = s.trail or {}
                    if moved > 15 then
                        table.insert(s.trail, { round(c.x, 0), round(c.y, 0) })
                        while #s.trail > 40 do table.remove(s.trail, 1) end
                    end
                    s.pending = nil
                else s.pending = true end
                -- theft watch
                if s.armed and not s.alerted then
                    local d = s.armX and math.sqrt((c.x - s.armX) ^ 2 + (c.y - s.armY) ^ 2) or 0
                    if d > (CT.ArmDistance or 40) or (unit.io and ign and not s.armIgn) then
                        s.alerted = true
                        if s.bars > 0 then event(t, 'theft', unit.io and ign and d <= (CT.ArmDistance or 40) and 'Ignition switched on while armed' or ('Moving while armed · %d km/h'):format(spd))
                        else s.alertPending = true end
                    end
                end
                if s.alertPending and s.bars > 0 then s.alertPending = nil event(t, 'theft', 'Moving while armed (reported late — it had no signal)') end
            end
            -- immobiliser relay (Pro, wired output): the vehicle won't start
            local want = (unit.io and s.immob and on) and true or nil
            if Entity(veh).state.opsImmob ~= want then Entity(veh).state:set('opsImmob', want, true) end
        else
            s.inWorld = false
        end
        if s.cut and not on and not s.deadSent then s.deadSent = true event(t, 'offline', 'Tracker went offline (power cut, backup battery flat)') end
    end
end

CreateThread(function()
    Wait(6000)
    local last, saved = os.clock(), os.time()
    while true do
        local n = os.clock()
        tick(math.min(60, n - last))
        last = n
        if os.time() - saved > 60 then
            saved = os.time()
            for _, t in pairs(Trackers) do persist(t) end
        end
        Wait((CT.Report or 10) * 1000)
    end
end)

---------------------------------------------------------------------------
-- what players / staff / the hub see
---------------------------------------------------------------------------
local function view(t, full)
    local s, unit = t.s, UNITS[t.unit] or {}
    local o = { plate = t.plate, unit = t.unit, unitLabel = unit.label, label = t.label, model = t.model, owner_name = t.owner_name,
        online = s.online ~= false, bars = s.bars or 0, x = s.x, y = s.y, at = s.at, speed = s.speed, ign = s.ign, inWorld = s.inWorld,
        pending = s.pending, armed = s.armed or false, immob = s.immob or false, cut = s.cut or false, battery = round(s.battery or 100, 0),
        backup = unit.backup or false, io = unit.io or false, imei = t.imei, installed_at = t.installed_at, installed_by = t.installed_by }
    if full then o.trail = s.trail end
    return o
end

function TrackState()
    local list = {}
    for _, t in pairs(Trackers) do list[#list + 1] = view(t, true) end
    table.sort(list, function(a, b) return a.plate < b.plate end)
    return { trackers = list, events = Events, now = now() }
end

function TrackAction(plate, action, by)
    local t = Trackers[norm(plate)]
    if not t then return nil, 'No tracker on that plate' end
    local s, unit = t.s, UNITS[t.unit] or {}
    if action == 'arm' then
        s.armed, s.alerted, s.armX, s.armY, s.armIgn = true, nil, s.fx or s.x, s.fy or s.y, s.ign
    elseif action == 'disarm' then s.armed, s.alerted, s.alertPending = false, nil, nil
    elseif action == 'immobilise' then
        if not unit.io then return nil, 'Only OPS Track Pro has an immobiliser relay' end
        s.immob = true
    elseif action == 'release' then s.immob = nil
    elseif action == 'rename' then return nil, 'use label'
    else return nil, 'Unknown action' end
    table.insert(Events, 1, { at = now(), plate = t.plate, kind = 'info', text = ('%s by %s'):format(action, by or '?') })
    persist(t)
    return true
end
exports('TrackState', TrackState)

lib.callback.register('opslabs-towers:track:get', function(src, plate)
    local t = Trackers[norm(plate)]
    if not t then return nil end
    return view(t)
end)

lib.callback.register('opslabs-towers:track:install', function(src, plate, unit, model, label)
    if not canInstall(src) then return { error = 'Only OPS Track installers can fit trackers' } end
    plate = norm(plate)
    if plate == '' then return { error = 'No number plate' } end
    if not UNITS[unit] then return { error = 'Unknown unit' } end
    if Trackers[plate] then return { error = 'This vehicle already has a tracker (' .. (Trackers[plate].imei or '?') .. ')' } end
    local owner, oname = ownerOf(plate)
    local imei = ('35%013d'):format(math.random(0, 9999999999999))
    local t = { plate = plate, unit = unit, imei = imei, owner = owner, owner_name = oname, label = label and tostring(label):sub(1, 60) or nil,
        model = model and tostring(model):sub(1, 40) or nil, installed_by = GetPlayerName(src), installed_at = now(), s = { battery = 100 } }
    MySQL.insert.await('INSERT INTO opslabs_towers_trackers (plate, unit, imei, owner, owner_name, label, model, installed_by, installed_at, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { plate, unit, imei, owner, oname, t.label, t.model, t.installed_by, t.installed_at, json.encode(t.s) })
    Trackers[plate] = t
    table.insert(Events, 1, { at = now(), plate = plate, kind = 'install', text = ('%s fitted by %s'):format(UNITS[unit].label, t.installed_by) })
    return { ok = true, imei = imei, owner = oname or (owner and 'registered owner') or nil }
end)

lib.callback.register('opslabs-towers:track:remove', function(src, plate)
    if not canInstall(src) then return { error = 'Only OPS Track installers can decommission trackers' } end
    plate = norm(plate)
    if not Trackers[plate] then return { error = 'No tracker in this vehicle' } end
    Trackers[plate] = nil
    MySQL.update.await('DELETE FROM opslabs_towers_trackers WHERE plate = ?', { plate })
    table.insert(Events, 1, { at = now(), plate = plate, kind = 'remove', text = 'Decommissioned by ' .. GetPlayerName(src) })
    return { ok = true }
end)

--- someone yanks the tracker's power feed (a thief, or an installer servicing it)
lib.callback.register('opslabs-towers:track:cut', function(src, plate, reconnect)
    local t = Trackers[norm(plate)]
    if not t then return { found = false } end
    if reconnect then
        t.s.cut, t.s.deadSent = nil, nil
        persist(t)
        return { ok = true }
    end
    t.s.cut = true
    local unit = UNITS[t.unit] or {}
    if unit.backup then event(t, 'tamper', 'TAMPER: vehicle power to the tracker was cut — running on its backup battery')
    else table.insert(Events, 1, { at = now(), plate = t.plate, kind = 'tamper', text = 'Power cut — tracker offline (Mini: no backup battery)' }) end
    persist(t)
    return { ok = true, found = true, backup = unit.backup }
end)

lib.callback.register('opslabs-towers:track:mine', function(src)
    local id, staff = FW.Identifier(src), canInstall(src) and #(CT.Jobs or {}) > 0 or FW.IsAdmin(src)
    local out = {}
    for _, t in pairs(Trackers) do if (id and t.owner == id) or staff then out[#out + 1] = view(t) end end
    table.sort(out, function(a, b) return a.plate < b.plate end)
    return { list = out, staff = staff }
end)

lib.callback.register('opslabs-towers:track:act', function(src, plate, action, label)
    local t = Trackers[norm(plate)]
    if not t then return { error = 'No such tracker' } end
    if not (isOwner(src, t) or canInstall(src) and #(CT.Jobs or {}) > 0 or FW.IsAdmin(src)) then return { error = 'That isn’t your vehicle' } end
    if action == 'label' then
        t.label = tostring(label or ''):sub(1, 60)
        if t.label == '' then t.label = nil end
        persist(t)
        return { ok = true }
    end
    local ok, err = TrackAction(plate, action, GetPlayerName(src))
    if not ok then return { error = err } end
    return { ok = true }
end)
