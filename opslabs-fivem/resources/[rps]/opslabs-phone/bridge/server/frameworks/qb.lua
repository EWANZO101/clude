-- QBCore (qb-core) and Qbox (qbx_core). Experimental: written from their source (qb-core 1.3, qbx_core 1.24) and
-- tested against fakes, not yet on a live server. Both keep characters in `players` (citizenid, charinfo / money /
-- job JSON) and vehicles in `player_vehicles`; the difference is how the player object is reached.
-- Note: both let the bank go negative, so FW.RemoveMoney checks the balance before calling RemoveMoney.

local function decode(v)
    if type(v) == 'table' then return v end
    local ok, t = pcall(json.decode, v or '')
    return ok and type(t) == 'table' and t or {}
end

local function playerData(p)
    if not p then return nil end
    local d = p.PlayerData or p
    local c = d.charinfo or {}
    local j = d.job
    return {
        identifier = d.citizenid,
        firstname = c.firstname, lastname = c.lastname,
        job = j and { name = j.name, label = j.label, grade = { level = j.grade and j.grade.level or 0, name = j.grade and j.grade.name } } or nil,
    }
end

-- offline money: players.money JSON (cash / bank)
local function offlineMoney(identifier)
    local raw = MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { identifier })
    return raw and decode(raw) or nil
end

local function writeOffline(identifier, money)
    MySQL.update.await('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(money), identifier })
end

local function vehicles(identifier)
    local rows = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { identifier }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local mods = decode(r.mods)
        local state = tonumber(r.state) or 0      -- 0 out, 1 in a garage, 2 impounded
        list[#list + 1] = {
            plate = r.plate, name = nil, type = 'car',
            model = tonumber(r.hash) or mods.model or (r.vehicle and joaat(r.vehicle)) or nil,
            stored = state == 1, parking = r.garage, pound = state == 2 and 'Impound' or nil,
            fuel = tonumber(r.fuel), engine = tonumber(r.engine), body = tonumber(r.body),
        }
    end
    return list
end

local function backfill()
    return MySQL.update.await([[UPDATE opslabs_phone_users p JOIN players q ON q.citizenid = p.identifier
        SET p.char_first = JSON_UNQUOTE(JSON_EXTRACT(q.charinfo, '$.firstname')),
            p.char_last = JSON_UNQUOTE(JSON_EXTRACT(q.charinfo, '$.lastname')),
            p.char_job = JSON_UNQUOTE(JSON_EXTRACT(q.job, '$.name'))
        WHERE p.char_first IS NULL]])
end

local events = {
    loaded = { ['QBCore:Server:PlayerLoaded'] = function(p) return p and p.PlayerData and p.PlayerData.source end },
    unloaded = { ['QBCore:Server:OnPlayerUnload'] = function(src) return src end },
    job = { ['QBCore:Server:OnJobUpdate'] = function(src) return src end },   -- (source, job)
}

---------------------------------------------------------------------------
-- Qbox (qbx_core): exports
---------------------------------------------------------------------------

local qbx = {
    label = 'Qbox', resource = 'qbx_core', status = 'experimental', builtin = true, events = events,
    GetVehicles = vehicles, BackfillNames = backfill,
}

function qbx.detect() return Bridge.Started('qbx_core') end

function qbx.init()
    -- a real call: reading an export doesn't prove it exists
    local ok, err = pcall(function() return exports.qbx_core:GetPlayer(-1) end)
    if not ok then return false, 'qbx_core GetPlayer export failed: ' .. tostring(err) end
    return true
end

function qbx.GetPlayer(src) return playerData(exports.qbx_core:GetPlayer(src)) end

function qbx.GetSource(identifier)
    local p = exports.qbx_core:GetPlayerByCitizenId(identifier)
    return p and p.PlayerData and p.PlayerData.source or nil
end

function qbx.IsAdmin(src) return IsPlayerAceAllowed(src, 'admin') or IsPlayerAceAllowed(src, 'god') end

function qbx.GetMoney(src, account) return exports.qbx_core:GetMoney(src, account) end
function qbx.AddMoney(src, amount, account, reason) return exports.qbx_core:AddMoney(src, account, amount, reason or 'OPS Phone') == true end
function qbx.RemoveMoney(src, amount, account, reason) return exports.qbx_core:RemoveMoney(src, account, amount, reason or 'OPS Phone') == true end

-- offline: qbx_core's money exports take a citizenid and save offline characters themselves
function qbx.GetOfflineMoney(identifier, account)
    local m = offlineMoney(identifier)
    return m and (tonumber(m[account]) or 0) or nil
end
function qbx.AddOfflineMoney(identifier, amount, account)
    if not offlineMoney(identifier) then return false end
    return exports.qbx_core:AddMoney(identifier, account, amount, 'OPS Phone') == true
end
function qbx.RemoveOfflineMoney(identifier, amount, account)
    local have = qbx.GetOfflineMoney(identifier, account)
    if not have or have < amount then return false end
    return exports.qbx_core:RemoveMoney(identifier, account, amount, 'OPS Phone') == true
end

function qbx.UsableItem(item, handler)
    exports.qbx_core:CreateUseableItem(item, function(src) handler(src) end)
    return true
end

function qbx.Notify(src, message, kind)
    exports.qbx_core:Notify(src, message, kind == 'inform' and 'inform' or kind)
    return true
end

Bridge.RegisterFramework('qbx', qbx)

---------------------------------------------------------------------------
-- QBCore (qb-core): the core object
---------------------------------------------------------------------------

local QBCore
local qb = {
    label = 'QBCore', resource = 'qb-core', status = 'experimental', builtin = true, events = events,
    GetVehicles = vehicles, BackfillNames = backfill,
}

-- Qbox also answers to 'qb-core' (provide 'qb-core'): never treat Qbox as QBCore
function qb.detect() return Bridge.Started('qb-core') and not Bridge.Started('qbx_core') end

function qb.init()
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not ok or type(obj) ~= 'table' or not obj.Functions then return false, 'qb-core has no GetCoreObject export' end
    QBCore = obj
    return true
end

local function qp(src) return QBCore.Functions.GetPlayer(src) end

function qb.GetPlayer(src) return playerData(qp(src)) end

function qb.GetSource(identifier)
    local p = QBCore.Functions.GetPlayerByCitizenId(identifier)
    return p and p.PlayerData and p.PlayerData.source or nil
end

function qb.IsAdmin(src) return QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god') end

function qb.GetMoney(src, account)
    local p = qp(src)
    return p and p.Functions.GetMoney(account) or 0
end
function qb.AddMoney(src, amount, account, reason)
    local p = qp(src)
    return p ~= nil and p.Functions.AddMoney(account, amount, reason or 'OPS Phone') ~= false
end
function qb.RemoveMoney(src, amount, account, reason)
    local p = qp(src)
    return p ~= nil and p.Functions.RemoveMoney(account, amount, reason or 'OPS Phone') == true
end

-- offline: the players.money JSON (qb-core's offline player objects don't save money changes by themselves)
function qb.GetOfflineMoney(identifier, account)
    local m = offlineMoney(identifier)
    return m and (tonumber(m[account]) or 0) or nil
end
function qb.AddOfflineMoney(identifier, amount, account)
    local m = offlineMoney(identifier)
    if not m then return false end
    m[account] = (tonumber(m[account]) or 0) + amount
    writeOffline(identifier, m)
    return true
end
function qb.RemoveOfflineMoney(identifier, amount, account)
    local m = offlineMoney(identifier)
    local have = m and tonumber(m[account]) or 0
    if not m or have < amount then return false end
    m[account] = have - amount
    writeOffline(identifier, m)
    return true
end

function qb.UsableItem(item, handler)
    QBCore.Functions.CreateUseableItem(item, function(src) handler(src) end)
    return true
end

function qb.Notify(src, message, kind)
    TriggerClientEvent('QBCore:Notify', src, message, kind == 'inform' and 'primary' or kind)
    return true
end

Bridge.RegisterFramework('qb', qb)
