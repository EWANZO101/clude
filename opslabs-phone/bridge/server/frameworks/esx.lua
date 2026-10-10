-- ESX Legacy (es_extended). Verified: this is what the phone was built and tested on.

local ESX
local function x(src) return ESX.GetPlayerFromId(src) end
local function account(a) return a == 'cash' and 'money' or a end   -- ESX calls cash 'money'

local A = {
    label = 'ESX Legacy', resource = 'es_extended', status = 'verified', builtin = true,
}

function A.detect() return Bridge.Started('es_extended') end

function A.init()
    local ok, obj = pcall(function() return exports.es_extended:getSharedObject() end)
    if not ok or type(obj) ~= 'table' or not obj.GetPlayerFromId then
        return false, 'es_extended has no getSharedObject export (ESX older than 1.9 is not supported)'
    end
    ESX = obj
    return true
end

function A.GetPlayer(src)
    local p = x(src)
    if not p then return nil end
    local first = p.get and (p.get('firstName') or p.get('firstname')) or nil
    local last = p.get and (p.get('lastName') or p.get('lastname')) or nil
    return {
        identifier = p.identifier,
        name = p.getName and p.getName() or nil,
        firstname = first, lastname = last,
        job = p.job and { name = p.job.name, label = p.job.label, grade = { level = p.job.grade, name = p.job.grade_label } },
    }
end

function A.GetSource(identifier)
    local p = ESX.GetPlayerFromIdentifier and ESX.GetPlayerFromIdentifier(identifier)
    return p and p.source or nil
end

-- admin / superadmin, or any of the groups the caller lists (owner, god, dev, …)
function A.IsAdmin(src, groups)
    local p = x(src)
    local g = p and p.getGroup and p.getGroup()
    if not g then return false end
    if g == 'admin' or g == 'superadmin' then return true end
    for _, want in ipairs(groups) do if g == want then return true end end
    return false
end

function A.GetMoney(src, acc)
    local p = x(src)
    local a = p and p.getAccount(account(acc))
    return a and a.money or 0
end

function A.AddMoney(src, amount, acc, reason)
    local p = x(src)
    if not p then return false end
    p.addAccountMoney(account(acc), amount, reason)
    return true
end

function A.RemoveMoney(src, amount, acc, reason)
    local p = x(src)
    if not p then return false end
    p.removeAccountMoney(account(acc), amount, reason)
    return true
end

-- offline: the users.accounts JSON column
local function offlineAccounts(identifier)
    local raw = MySQL.scalar.await('SELECT accounts FROM users WHERE identifier = ?', { identifier })
    return raw and json.decode(raw) or nil
end

function A.GetOfflineMoney(identifier, acc)
    local accounts = offlineAccounts(identifier)
    return accounts and (tonumber(accounts[account(acc)]) or 0) or nil
end

function A.AddOfflineMoney(identifier, amount, acc)
    local accounts = offlineAccounts(identifier)
    if not accounts then return false end
    accounts[account(acc)] = (tonumber(accounts[account(acc)]) or 0) + amount
    MySQL.update.await('UPDATE users SET accounts = ? WHERE identifier = ?', { json.encode(accounts), identifier })
    return true
end

function A.RemoveOfflineMoney(identifier, amount, acc)
    local accounts = offlineAccounts(identifier)
    local have = accounts and tonumber(accounts[account(acc)]) or 0
    if not accounts or have < amount then return false end
    accounts[account(acc)] = have - amount
    MySQL.update.await('UPDATE users SET accounts = ? WHERE identifier = ?', { json.encode(accounts), identifier })
    return true
end

function A.ItemCount(src, item)
    local p = x(src)
    local i = p and p.getInventoryItem and p.getInventoryItem(item)
    return i and (i.count or i.amount or 0) or 0
end

function A.AddItem(src, item, count)
    local p = x(src)
    if not p then return false end
    p.addInventoryItem(item, count)
    return true
end

function A.RemoveItem(src, item, count)
    local p = x(src)
    if not p then return false end
    p.removeInventoryItem(item, count)
    return true
end

function A.UsableItem(item, handler)
    ESX.RegisterUsableItem(item, function(src) handler(src) end)
    return true
end

function A.Notify(src, message, kind)
    local p = x(src)
    if not p or not p.showNotification then return false end
    p.showNotification(message, kind)
    return true
end

-- garage: owned_vehicles (esx_garage's parking / pound / custom_name / mileage columns when it is installed)
function A.GetVehicles(identifier)
    local rows = MySQL.query.await('SELECT * FROM owned_vehicles WHERE `owner` = ?', { identifier }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local props = r.vehicle and json.decode(r.vehicle) or {}
        list[#list + 1] = {
            plate = r.plate, model = props.model, type = r.type, name = r.custom_name,
            stored = IsTrue(r.stored), parking = r.parking, pound = r.pound, mileage = r.mileage,
            fuel = props.fuelLevel, engine = props.engineHealth, body = props.bodyHealth,
        }
    end
    return list
end

-- once: names of phone owners who haven't logged in since the phone kept its own copy. Returns rows updated.
function A.BackfillNames()
    return MySQL.update.await([[UPDATE opslabs_phone_users p JOIN users u ON u.identifier = p.identifier
        SET p.char_first = u.firstname, p.char_last = u.lastname, p.char_job = u.job, p.char_grade = u.job_grade WHERE p.char_first IS NULL]])
end

A.events = {
    loaded = { ['esx:playerLoaded'] = function(src) return src end },
    unloaded = { ['esx:playerLogout'] = function(src) return src end },
    job = { ['esx:setJob'] = function(src) return src end },          -- (source, job, lastJob)
}

Bridge.RegisterFramework('esx', A)
