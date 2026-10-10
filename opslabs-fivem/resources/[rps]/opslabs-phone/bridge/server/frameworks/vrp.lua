-- vRP 1.x (ImagicTheCat's vRP 1). Experimental: written from its source (tag 1.0) and tested against fakes, not yet
-- on a live server. vRP 2 and the Brazilian "Creative" bases use different APIs: the start-up check tells them apart
-- and asks for a custom adapter (bridge/README.md) instead of guessing.
-- Talks to vRP through its Proxy interface (the 'vRP:proxy' event), with a small client of our own instead of loading
-- vRP's lib/utils.lua (which would add vRP's globals to the phone).

local vRP
local A = { label = 'vRP', resource = 'vrp', status = 'experimental', builtin = true }

--- vRP 1 Proxy: TriggerEvent('vRP:proxy', member, args, identifier, rid), answered on 'vRP:<identifier>:proxy_res'
local function proxy()
    local id = GetCurrentResourceName() .. ':bridge'
    local pending, seq = {}, 0
    AddEventHandler('vRP:' .. id .. ':proxy_res', function(rid, rets)
        local p = pending[rid]
        if p then pending[rid] = nil p:resolve(rets or {}) end
    end)
    return setmetatable({}, {
        __index = function(_, member)
            return function(...)
                seq = seq + 1
                local rid, p = seq, promise.new()
                pending[rid] = p
                TriggerEvent('vRP:proxy', member, { ... }, id, rid)
                SetTimeout(5000, function() if pending[rid] then pending[rid] = nil p:resolve({}) end end)
                local rets = Citizen.Await(p)
                return table.unpack(rets, 1, #rets)
            end
        end,
    })
end

function A.detect() return Bridge.Started('vrp') end

function A.init()
    local base = LoadResourceFile('vrp', 'base.lua') or ''
    if not base:find('function vRP.getUserId%(') then
        local creative = (LoadResourceFile('vrp', 'modules/base.lua') or ''):find('function vRP.Passport%(')
        return false, creative and 'this is a Creative-style vRP (vRP.Passport): add a custom adapter (bridge/README.md)'
            or 'this is not vRP 1 (vRP 2 or a fork): add a custom adapter (bridge/README.md)'
    end
    vRP = proxy()
    return true
end

local function uid(src) return vRP.getUserId(src) end

function A.GetPlayer(src)
    local id = uid(src)
    if not id then return nil end
    local identity = vRP.getUserIdentity(id) or {}
    local job = vRP.getUserGroupByType(id, 'job')
    return {
        identifier = tostring(id),
        firstname = identity.firstname, lastname = identity.name,       -- vRP's "name" is the last name
        job = job and job ~= '' and { name = job, label = vRP.getGroupTitle(job) or job, grade = { level = 0 } } or nil,
    }
end

function A.GetSource(identifier) return vRP.getUserSource(tonumber(identifier)) end

function A.IsAdmin(src)
    local id = uid(src)
    return id ~= nil and (vRP.hasGroup(id, 'superadmin') or vRP.hasGroup(id, 'admin') or vRP.hasPermission(id, 'admin.tickets')) == true
end

-- vRP's cash is the "wallet"
function A.GetMoney(src, acc)
    local id = uid(src)
    if not id then return 0 end
    return acc == 'cash' and vRP.getMoney(id) or vRP.getBankMoney(id)
end

function A.AddMoney(src, amount, acc)
    local id = uid(src)
    if not id then return false end
    if acc == 'cash' then vRP.giveMoney(id, amount) else vRP.giveBankMoney(id, amount) end
    return true
end

function A.RemoveMoney(src, amount, acc)
    local id = uid(src)
    if not id then return false end
    if acc == 'cash' then return vRP.tryPayment(id, amount) == true end
    local have = tonumber(vRP.getBankMoney(id)) or 0
    if have < amount then return false end
    vRP.setBankMoney(id, have - amount)
    return true
end

-- offline: vrp_user_moneys (only while they're offline — vRP saves its own copy of online players over it)
local function column(acc) return acc == 'cash' and 'wallet' or 'bank' end
function A.GetOfflineMoney(identifier, acc)
    local v = MySQL.scalar.await(('SELECT %s FROM vrp_user_moneys WHERE user_id = ?'):format(column(acc)), { tonumber(identifier) })
    return v and tonumber(v) or nil
end
function A.AddOfflineMoney(identifier, amount, acc)
    local c = column(acc)
    return (MySQL.update.await(('UPDATE vrp_user_moneys SET %s = %s + ? WHERE user_id = ?'):format(c, c), { amount, tonumber(identifier) }) or 0) > 0
end
function A.RemoveOfflineMoney(identifier, amount, acc)
    local c = column(acc)
    return (MySQL.update.await(('UPDATE vrp_user_moneys SET %s = %s - ? WHERE user_id = ? AND %s >= ?'):format(c, c, c), { amount, tonumber(identifier), amount }) or 0) > 0
end

function A.BackfillNames()
    return MySQL.update.await([[UPDATE opslabs_phone_users p JOIN vrp_user_identities i ON i.user_id = p.identifier
        SET p.char_first = i.firstname, p.char_last = i.name WHERE p.char_first IS NULL]])
end

A.events = {
    loaded = { ['vRP:playerSpawn'] = function(_, src, firstSpawn) return firstSpawn and src or false end },   -- (user_id, source, first_spawn)
    unloaded = { ['vRP:playerLeave'] = function(_, src) return src end },
}

Bridge.RegisterFramework('vrp', A)
