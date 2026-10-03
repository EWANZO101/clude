-- opslabs-towers: cell towers + Wi-Fi access points.
-- Works out every player's signal on the server (authoritative), pushes it to
-- their phone and lets opslabs-phone ask for it before texts, calls and apps.
--   exports['opslabs-towers']:GetCoverage(src) -> { cell = 0..4, net = '5G'|'LTE'|nil, wifi = { id, ssid, bars } | nil, tower = name }

-- player / job / admin lookups go through FW (server/framework.lua → rps_lib)

Towers = {}          -- id -> tower row
local coverage = {}  -- src -> last coverage
local ready = false

---------------------------------------------------------------------------
-- database
---------------------------------------------------------------------------

local function bool(v) return v == true or v == 1 or v == '1' end

local function normalize(t)
    t.active, t.prop, t.exact, t.fibre_only = bool(t.active), bool(t.prop), bool(t.exact), bool(t.fibre_only)
    t.x, t.y, t.z, t.heading = tonumber(t.x), tonumber(t.y), tonumber(t.z), tonumber(t.heading) or 0.0
    t.range = tonumber(t.range_m)
    t.range_m = nil
    return t
end

local function load()
    Towers = {}
    for _, t in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers') or {}) do
        Towers[t.id] = normalize(t)
    end
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `type` VARCHAR(8) NOT NULL DEFAULT 'cell',
        `name` VARCHAR(60) NOT NULL,
        `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL,
        `heading` FLOAT NOT NULL DEFAULT 0,
        `range_m` INT NOT NULL DEFAULT 1500,
        `ssid` VARCHAR(40) DEFAULT NULL,
        `jobs` VARCHAR(120) DEFAULT NULL,
        `prop` TINYINT(1) NOT NULL DEFAULT 0,
        `active` TINYINT(1) NOT NULL DEFAULT 1,
        `notes` VARCHAR(255) DEFAULT NULL,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `type` (`type`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_meta` (
        `k` VARCHAR(40) NOT NULL, `v` VARCHAR(255) NOT NULL, PRIMARY KEY (`k`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    -- towers are never added automatically; the table is the only source
    -- column added after the first release
    if MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers' AND COLUMN_NAME = 'model'") == 0 then
        MySQL.query.await('ALTER TABLE `opslabs_towers` ADD COLUMN `model` VARCHAR(60) DEFAULT NULL AFTER `prop`')
    end
    if MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers' AND COLUMN_NAME = 'exact'") == 0 then
        -- 1 = placed with the aim tool: the prop sits exactly at x/y/z (desks, shelves)
        MySQL.query.await('ALTER TABLE `opslabs_towers` ADD COLUMN `exact` TINYINT(1) NOT NULL DEFAULT 0 AFTER `model`')
    end
    if MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers' AND COLUMN_NAME = 'password'") == 0 then
        MySQL.query.await('ALTER TABLE `opslabs_towers` ADD COLUMN `password` VARCHAR(64) DEFAULT NULL AFTER `jobs`')
    end
    if MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_towers' AND COLUMN_NAME = 'fibre_only'") == 0 then
        -- 1 = the access point only broadcasts while it is cabled to a gateway with a live fibre line
        MySQL.query.await('ALTER TABLE `opslabs_towers` ADD COLUMN `fibre_only` TINYINT(1) NOT NULL DEFAULT 0 AFTER `active`')
    end
    -- Wi-Fi networks each character has joined (remembered like a real phone)
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_wifi_known` (
        `identifier` VARCHAR(60) NOT NULL,
        `tower_id` INT NOT NULL,
        `password` VARCHAR(64) NOT NULL DEFAULT '',
        `joined_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`identifier`, `tower_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    load()
    ready = true
    local cells, wifis = 0, 0
    for _, t in pairs(Towers) do if t.type == 'wifi' then wifis = wifis + 1 else cells = cells + 1 end end
    print(('^2[opslabs-towers]^7 %d cell towers, %d Wi-Fi access points loaded'):format(cells, wifis))
end)

local function clean(s, max)
    s = tostring(s or ''):gsub('[%c<>]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    return s:sub(1, max or 60)
end

--- validates + saves a tower. data: type, name, x, y, z, heading, range, ssid, jobs, prop, active, notes
function SaveTower(id, data, actor)
    local base = id and Towers[id] or {}
    local t = {
        type = (data.type or base.type) == 'wifi' and 'wifi' or 'cell',
        name = clean(data.name or base.name, 60),
        x = tonumber(data.x or base.x), y = tonumber(data.y or base.y), z = tonumber(data.z or base.z) or 30.0,
        heading = tonumber(data.heading or base.heading) or 0.0,
        ssid = data.ssid ~= nil and clean(data.ssid, 40) or base.ssid,
        jobs = data.jobs ~= nil and clean(data.jobs, 120):gsub('%s', '') or base.jobs,
        notes = data.notes ~= nil and clean(data.notes, 255) or base.notes,
        password = base.password,
    }
    if data.password ~= nil then
        local pw = tostring(data.password or ''):gsub('[%c]', ''):sub(1, 64)
        if pw ~= '' and #pw < (Config.Wifi.PasswordMin or 4) then return nil, ('Wi-Fi password must be at least %d characters'):format(Config.Wifi.PasswordMin or 4) end
        t.password = pw ~= '' and pw or nil
    end
    local lim = t.type == 'wifi' and Config.Wifi or Config.Cell
    t.range = math.floor(math.max(lim.MinRange, math.min(lim.MaxRange, tonumber(data.range or base.range) or lim.DefaultRange)))
    if data.prop ~= nil then t.prop = bool(data.prop) else t.prop = base.prop or false end
    if data.exact ~= nil then t.exact = bool(data.exact) else t.exact = base.exact or false end
    -- prop model: must be one of the Props lists for this type ('' = no prop)
    t.model = base.model
    if data.model ~= nil then
        t.model, t.prop = nil, false
        for _, p in ipairs((t.type == 'wifi' and Config.Wifi.Props or Config.Cell.Props) or {}) do
            if p.model == data.model then t.model, t.prop = p.model, true end
        end
    end
    if data.active ~= nil then t.active = bool(data.active) else t.active = base.active ~= false end
    if data.fibre_only ~= nil then t.fibre_only = bool(data.fibre_only) else t.fibre_only = base.fibre_only == true end
    if t.name == '' then return nil, 'name is required' end
    if not t.x or not t.y then return nil, 'x and y are required' end
    if t.type == 'wifi' and (not t.ssid or t.ssid == '') then t.ssid = t.name:gsub('%s+', '-') end
    if t.type == 'cell' then t.ssid, t.jobs, t.password, t.fibre_only = nil, nil, nil, false end
    if t.jobs == '' then t.jobs = nil end
    if id then
        MySQL.update.await('UPDATE opslabs_towers SET type=?, name=?, x=?, y=?, z=?, heading=?, range_m=?, ssid=?, jobs=?, password=?, prop=?, model=?, exact=?, active=?, fibre_only=?, notes=? WHERE id=?',
            { t.type, t.name, t.x, t.y, t.z, t.heading, t.range, t.ssid, t.jobs, t.password, t.prop, t.model, t.exact, t.active, t.fibre_only, t.notes, id })
    else
        id = MySQL.insert.await('INSERT INTO opslabs_towers (type, name, x, y, z, heading, range_m, ssid, jobs, password, prop, model, exact, active, fibre_only, notes, created_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            { t.type, t.name, t.x, t.y, t.z, t.heading, t.range, t.ssid, t.jobs, t.password, t.prop, t.model, t.exact, t.active, t.fibre_only, t.notes, actor or 'api' })
    end
    t.id = id
    Towers[id] = t
    BroadcastTowers()
    return t
end

function DeleteTower(id)
    if not Towers[id] then return false end
    MySQL.update.await('DELETE FROM opslabs_towers WHERE id = ?', { id })
    Towers[id] = nil
    BroadcastTowers()
    return true
end

--- which towers a bulk action targets: { ids = {..} } or { all = true, type = 'cell'|'wifi'|nil, offline = true|nil }
function SelectTowers(sel)
    local out = {}
    if type(sel) ~= 'table' then return out end
    if type(sel.ids) == 'table' then
        for _, id in ipairs(sel.ids) do
            id = tonumber(id)
            if id and Towers[id] then out[#out + 1] = id end
        end
    elseif sel.all == true then
        for id, t in pairs(Towers) do
            if (not sel.type or t.type == sel.type) and (not sel.offline or not t.active) then out[#out + 1] = id end
        end
    end
    return out
end

function DeleteTowers(sel)
    local ids = SelectTowers(sel)
    if #ids == 0 then return 0 end
    MySQL.update.await(('DELETE FROM opslabs_towers WHERE id IN (%s)'):format(('?,'):rep(#ids):sub(1, -2)), ids)
    for _, id in ipairs(ids) do Towers[id] = nil end
    BroadcastTowers()
    return #ids
end

function SetTowersActive(sel, active)
    local ids = SelectTowers(sel)
    if #ids == 0 then return 0 end
    MySQL.update.await(('UPDATE opslabs_towers SET active = ? WHERE id IN (%s)'):format(('?,'):rep(#ids):sub(1, -2)), { active, table.unpack(ids) })
    for _, id in ipairs(ids) do Towers[id].active = active end
    BroadcastTowers()
    return #ids
end

--- every client gets the list (props, admin overlay); coverage is still worked out here
local function public(t)
    local c = {}
    for k, v in pairs(t) do if k ~= 'password' then c[k] = v end end
    c.secured = t.password ~= nil
    return c
end
PublicTower = public

function BroadcastTowers(target)
    if not target then TriggerEvent('opslabs-towers:towersChanged') end
    local list = {}
    for _, t in pairs(Towers) do list[#list + 1] = public(t) end
    TriggerClientEvent('opslabs-towers:list', target or -1, list)
end

---------------------------------------------------------------------------
-- coverage
---------------------------------------------------------------------------

local function jobAllowed(src, jobs)
    if not jobs or jobs == '' then return true end
    local job = FW.Job(src)
    if not job then return false end
    for j in jobs:gmatch('[^,]+') do if j:match('^%s*(.-)%s*$') == job then return true end end
    return false
end

local known = {}   -- identifier -> { [towerId] = password }
local function identifierOf(src)
    return src and FW.Identifier(src) or nil
end
local function knownFor(identifier)
    if not identifier then return {} end
    if not known[identifier] then
        known[identifier] = {}
        for _, r in ipairs(MySQL.query.await('SELECT tower_id, password FROM opslabs_towers_wifi_known WHERE identifier = ?', { identifier }) or {}) do
            known[identifier][r.tower_id] = r.password
        end
    end
    return known[identifier]
end

--- has this player got the password for a secured network? (changing the password logs everyone out)
local function hasPassword(src, t)
    if not t.password then return true end
    local k = knownFor(identifierOf(src))
    return k[t.id] ~= nil and k[t.id] == t.password
end

local function barsFor(s, steps)
    if s <= 0 then return 0 end
    return math.min(steps, math.floor(s * steps) + 1)
end

--- works out signal for a position (+ player for job-locked Wi-Fi)
function ComputeCoverage(coords, src)
    local best, bestTower = 0, nil
    local wifi, nearby = nil, {}
    for _, t in pairs(Towers) do
        -- fibre-only access points stay silent until they're cabled to a gateway with a live fibre line
        if t.active and not (FaultEffects and FaultEffects.towers[t.id]) and not (t.fibre_only and not (WifiOnFibre and WifiOnFibre(t.id))) then
            local dx, dy = coords.x - t.x, coords.y - t.y
            local d2 = math.sqrt(dx * dx + dy * dy)
            if t.type == 'cell' then
                local s = 1 - d2 / t.range
                if s > best then best, bestTower = s, t end
            elseif d2 < t.range * 1.6 and math.abs(coords.z - t.z) <= Config.Wifi.FloorTolerance * 1.5 then
                local inRange = d2 <= t.range and math.abs(coords.z - t.z) <= Config.Wifi.FloorTolerance
                local s = inRange and (1 - d2 / t.range) or 0
                local jobOk = jobAllowed(src, t.jobs) and (not WifiHasUplink or WifiHasUplink(t.id))
                local passOk = hasPassword(src, t)
                local bars = inRange and math.max(1, barsFor(s, 3)) or 1
                nearby[#nearby + 1] = { id = t.id, ssid = t.ssid, bars = bars, locked = not jobOk, secured = t.password ~= nil, known = t.password ~= nil and passOk, inRange = inRange }
                if inRange and jobOk and passOk and (not wifi or s > wifi.s) then wifi = { id = t.id, ssid = t.ssid, bars = bars, s = s, secured = t.password ~= nil } end
            end
        end
    end
    table.sort(nearby, function(a, b) return a.bars > b.bars end)
    if wifi then wifi.s = nil end
    local cell = barsFor(best, 4)
    return {
        cell = cell,
        net = cell >= 3 and '5G' or cell >= 1 and 'LTE' or nil,
        tower = bestTower and bestTower.name or nil,
        wifi = wifi,
        nearby = nearby,
        enforce = Config.Enforce,
    }
end

--- current coverage for a player (used by opslabs-phone before texts/calls/apps)
function GetCoverage(src)
    src = tonumber(src)
    if not Config.Enforce or not ready then return { cell = 4, net = '5G', enforce = false } end
    local ped = src and GetPlayerPed(src)
    if not ped or ped == 0 then return coverage[src] or { cell = 0 } end
    local c = ComputeCoverage(GetEntityCoords(ped), src)
    coverage[src] = c
    return c
end
exports('GetCoverage', GetCoverage)
exports('GetTowers', function() return Towers end)

--- join a secured network from the phone. Returns { ok } or { error = 'wrong_password' | ... }
function JoinWifi(src, id, password)
    local t = Towers[tonumber(id)]
    if not t or t.type ~= 'wifi' or not t.active then return { error = 'not_found' } end
    if not jobAllowed(src, t.jobs) then return { error = 'restricted' } end
    local identifier = identifierOf(src)
    if not identifier then return { error = 'not_found' } end
    if t.password and tostring(password or '') ~= t.password then return { error = 'wrong_password' } end
    MySQL.query.await('INSERT INTO opslabs_towers_wifi_known (identifier, tower_id, password) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE password = VALUES(password), joined_at = CURRENT_TIMESTAMP',
        { identifier, t.id, t.password or '' })
    knownFor(identifier)[t.id] = t.password or ''
    TriggerClientEvent('opslabs-towers:coverage', src, GetCoverage(src))
    return { ok = true, ssid = t.ssid }
end
exports('JoinWifi', JoinWifi)

function ForgetWifi(src, id)
    local identifier = identifierOf(src)
    if not identifier then return { error = 'not_found' } end
    MySQL.update.await('DELETE FROM opslabs_towers_wifi_known WHERE identifier = ? AND tower_id = ?', { identifier, tonumber(id) })
    knownFor(identifier)[tonumber(id)] = nil
    TriggerClientEvent('opslabs-towers:coverage', src, GetCoverage(src))
    return { ok = true }
end
exports('ForgetWifi', ForgetWifi)

local function same(a, b)
    if not a or not b then return false end
    if a.cell ~= b.cell or a.tower ~= b.tower or (a.wifi and a.wifi.ssid) ~= (b.wifi and b.wifi.ssid) or (a.wifi and a.wifi.bars) ~= (b.wifi and b.wifi.bars) then return false end
    if #(a.nearby or {}) ~= #(b.nearby or {}) then return false end
    return true
end

-- push changes to phones (and tell opslabs-phone so it can drop calls)
CreateThread(function()
    while not ready do Wait(500) end
    while true do
        Wait(Config.TickMs)
        if Config.Enforce then
            for _, id in ipairs(GetPlayers()) do
                local src = tonumber(id)
                local before = coverage[src]
                local ped = GetPlayerPed(src)
                if ped and ped ~= 0 then
                    local c = ComputeCoverage(GetEntityCoords(ped), src)
                    coverage[src] = c
                    if not same(before, c) then
                        TriggerClientEvent('opslabs-towers:coverage', src, c)
                        TriggerEvent('opslabs-towers:changed', src, c, before)
                    end
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function() coverage[source] = nil end)

RegisterNetEvent('opslabs-towers:ready', function()
    local src = source
    BroadcastTowers(src)
    TriggerClientEvent('opslabs-towers:coverage', src, GetCoverage(src))
end)

---------------------------------------------------------------------------
-- in-game admin tool
---------------------------------------------------------------------------

function IsTowerAdmin(src)
    if IsPlayerAceAllowed(src, 'opslabs.towers') then return true end
    local license = GetPlayerIdentifierByType(src, 'license')
    for _, l in ipairs(Config.AdminLicenses or {}) do
        if l == license then return true end
    end
    return FW.IsAdmin(src, Config.AdminGroups)
end

lib.callback.register('opslabs-towers:isAdmin', function(src) return IsTowerAdmin(src) end)

lib.callback.register('opslabs-towers:save', function(src, data)
    if not IsTowerAdmin(src) or type(data) ~= 'table' then return { error = 'not allowed' } end
    local id = tonumber(data.id)
    if not id then
        local c = GetEntityCoords(GetPlayerPed(src))
        data.x, data.y, data.z = data.x or c.x, data.y or c.y, data.z or c.z
        data.heading = data.heading or GetEntityHeading(GetPlayerPed(src))
    end
    local t, err = SaveTower(id, data, GetPlayerName(src))
    if not t then return { error = err } end
    print(('[opslabs-towers] %s %s %s tower #%d "%s"'):format(GetPlayerName(src), id and 'edited' or 'placed', t.type, t.id, t.name))
    return { ok = true, tower = t }
end)

-- admins see the password when editing
lib.callback.register('opslabs-towers:password', function(src, id)
    if not IsTowerAdmin(src) then return nil end
    local t = Towers[tonumber(id)]
    return t and t.password or nil
end)

lib.callback.register('opslabs-towers:delete', function(src, id)
    if not IsTowerAdmin(src) then return false end
    local t = Towers[tonumber(id)]
    local ok = DeleteTower(tonumber(id))
    if ok then print(('[opslabs-towers] %s deleted tower #%s "%s"'):format(GetPlayerName(src), id, t and t.name or '')) end
    return ok
end)

lib.callback.register('opslabs-towers:bulk', function(src, sel, action)
    if not IsTowerAdmin(src) then return { error = 'not allowed' } end
    local n
    if action == 'delete' then n = DeleteTowers(sel)
    elseif action == 'offline' then n = SetTowersActive(sel, false)
    elseif action == 'online' then n = SetTowersActive(sel, true)
    else return { error = 'unknown action' } end
    print(('[opslabs-towers] %s bulk %s: %d towers'):format(GetPlayerName(src), action, n))
    return { ok = true, count = n }
end)

lib.callback.register('opslabs-towers:here', function(src)
    local ped = GetPlayerPed(src)
    return ComputeCoverage(GetEntityCoords(ped), src)
end)
