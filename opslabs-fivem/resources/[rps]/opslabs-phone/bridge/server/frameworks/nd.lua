-- ND Core v2 (ND-Framework). Experimental: written from its source (2.3) and tested against fakes, not yet on a live
-- server. Characters are charids; money is player.cash / player.bank; the job is the group marked isJob.
-- Note: ND's deductMoney doesn't check the balance, so FW.RemoveMoney checks it first.

local A = { label = 'ND Core', resource = 'ND_Core', status = 'experimental', builtin = true }
local function nd() return exports.ND_Core end
local function player(src) return nd():getPlayer(src) end

function A.detect() return Bridge.Started('ND_Core') end

function A.init()
    local ok, err = pcall(function() return nd():getPlayer(-1) end)
    if not ok then return false, 'ND_Core getPlayer export failed: ' .. tostring(err) end
    return true
end

function A.GetPlayer(src)
    local p = player(src)
    if not p or not p.id then return nil end
    local j = p.jobInfo
    return {
        identifier = tostring(p.id), firstname = p.firstname, lastname = p.lastname,
        job = p.job and { name = p.job, label = j and j.label or p.job, grade = { level = j and j.rank or 0, name = j and j.rankName } } or nil,
    }
end

function A.GetSource(identifier)
    local list = nd():getPlayers('id', tonumber(identifier), true) or {}
    return list[1] and list[1].source or nil
end

-- the "admin" group, or the group.admin ACE ND gives admins
function A.IsAdmin(src)
    local p = player(src)
    return (p and p.groups and p.groups.admin ~= nil) or IsPlayerAceAllowed(src, 'command')
end

function A.GetMoney(src, acc)
    local p = player(src)
    return p and tonumber(p[acc == 'cash' and 'cash' or 'bank']) or 0
end

function A.AddMoney(src, amount, acc, reason)
    local p = player(src)
    return p ~= nil and p.addMoney(acc == 'cash' and 'cash' or 'bank', amount, reason) == true
end

function A.RemoveMoney(src, amount, acc, reason)
    local p = player(src)
    local key = acc == 'cash' and 'cash' or 'bank'
    if not p or (tonumber(p[key]) or 0) < amount then return false end
    return p.deductMoney(key, amount, reason) == true
end

-- offline: nd_characters.cash / .bank
local function column(acc) return acc == 'cash' and 'cash' or 'bank' end
function A.GetOfflineMoney(identifier, acc)
    local v = MySQL.scalar.await(('SELECT %s FROM nd_characters WHERE charid = ?'):format(column(acc)), { tonumber(identifier) })
    return v and tonumber(v) or nil
end
function A.AddOfflineMoney(identifier, amount, acc)
    return (MySQL.update.await(('UPDATE nd_characters SET %s = %s + ? WHERE charid = ?'):format(column(acc), column(acc)), { amount, tonumber(identifier) }) or 0) > 0
end
function A.RemoveOfflineMoney(identifier, amount, acc)
    local c = column(acc)
    return (MySQL.update.await(('UPDATE nd_characters SET %s = %s - ? WHERE charid = ? AND %s >= ?'):format(c, c, c), { amount, tonumber(identifier), amount }) or 0) > 0
end

function A.Notify(src, message, kind)
    local p = player(src)
    if not p then return false end
    p.notify({ description = message, type = kind })
    return true
end

-- garage: nd_vehicles
function A.GetVehicles(identifier)
    local rows = MySQL.query.await('SELECT plate, properties, stored, impounded FROM nd_vehicles WHERE owner = ?', { tonumber(identifier) }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local ok, props = pcall(json.decode, r.properties or '{}')
        props = ok and type(props) == 'table' and props or {}
        list[#list + 1] = {
            plate = r.plate, model = props.model, type = 'car', stored = IsTrue(r.stored),
            pound = IsTrue(r.impounded) and 'Impound' or nil,
            fuel = props.fuelLevel, engine = props.engineHealth, body = props.bodyHealth,
        }
    end
    return list
end

function A.BackfillNames()
    return MySQL.update.await([[UPDATE opslabs_phone_users p JOIN nd_characters c ON c.charid = p.identifier
        SET p.char_first = c.firstname, p.char_last = c.lastname WHERE p.char_first IS NULL]])
end

A.events = {
    loaded = { ['ND:characterLoaded'] = function(p) return p and p.source end },
    unloaded = { ['ND:characterUnloaded'] = function(src) return src end },
}

Bridge.RegisterFramework('nd', A)
