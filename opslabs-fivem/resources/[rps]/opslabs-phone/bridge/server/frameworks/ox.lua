-- ox_core (overextended). Experimental: written from its source (TypeScript, current main) and tested against fakes,
-- not yet on a live server. Uses ox_core's exports directly (the same calls its Lua lib makes):
--   characters are charIds, names come from player.get, the "job" is the active group, the bank is the character's
--   default account (works offline too), cash is ox_inventory's `money` item, society money is the group account.

local A = { label = 'ox_core', resource = 'ox_core', status = 'experimental', builtin = true }
local ox = function() return exports.ox_core end

function A.detect() return Bridge.Started('ox_core') end

function A.init()
    local ok, err = pcall(function() return ox():GetPlayer(-1) end)
    if not ok then return false, 'ox_core GetPlayer export failed: ' .. tostring(err) end
    return true
end

local function call(src, method, ...) return ox():CallPlayer(src, method, ...) end

function A.GetPlayer(src)
    local p = ox():GetPlayer(src)
    if not p or not p.charId then return nil end      -- no character selected yet
    local job
    local groupName = call(src, 'get', 'activeGroup')
    if groupName then
        local group = GlobalState['group.' .. groupName] or {}
        local grade = tonumber(call(src, 'getGroup', groupName)) or 0
        job = { name = groupName, label = group.label or groupName, grade = { level = grade, name = (group.grades or {})[grade] } }
    end
    return { identifier = tostring(p.charId), firstname = call(src, 'get', 'firstName'), lastname = call(src, 'get', 'lastName'), job = job }
end

function A.GetSource(identifier)
    local p = ox():GetPlayerFromCharId(tonumber(identifier))
    return p and p.source or nil
end

-- ox_core has no admin API of its own: its commands are restricted to group.admin through ACEs
function A.IsAdmin(src) return IsPlayerAceAllowed(src, 'command') end

local function account(charId)
    local a = ox():GetCharacterAccount(tonumber(charId))
    return a and a.accountId or nil
end

local function balance(accountId) return tonumber(ox():CallAccount(accountId, 'get', 'balance')) or 0 end

local function addTo(accountId, amount, reason)
    local r = accountId and ox():CallAccount(accountId, 'addBalance', { amount = amount, message = reason or 'OPS Phone' })
    return r and r.success == true or false
end

local function removeFrom(accountId, amount, reason)
    local r = accountId and ox():CallAccount(accountId, 'removeBalance', { amount = amount, overdraw = false, message = reason or 'OPS Phone' })
    return r and r.success == true or false
end

local function charId(src) local p = ox():GetPlayer(src) return p and p.charId end

function A.GetMoney(src, acc)
    if acc == 'cash' then return Bridge.Started('ox_inventory') and exports.ox_inventory:GetItemCount(src, 'money') or 0 end
    local id = account(charId(src))
    return id and balance(id) or 0
end

function A.AddMoney(src, amount, acc, reason)
    if acc == 'cash' then return Bridge.Started('ox_inventory') and exports.ox_inventory:AddItem(src, 'money', amount) == true end
    return addTo(account(charId(src)), amount, reason)
end

function A.RemoveMoney(src, amount, acc, reason)
    if acc == 'cash' then return Bridge.Started('ox_inventory') and exports.ox_inventory:RemoveItem(src, 'money', amount) == true end
    return removeFrom(account(charId(src)), amount, reason)
end

-- the bank account lives in the database, so offline characters work the same (cash is in their inventory: no)
function A.GetOfflineMoney(identifier, acc)
    if acc == 'cash' then return nil end
    local id = account(identifier)
    return id and balance(id) or nil
end
function A.AddOfflineMoney(identifier, amount, acc) return acc ~= 'cash' and addTo(account(identifier), amount) end
function A.RemoveOfflineMoney(identifier, amount, acc) return acc ~= 'cash' and removeFrom(account(identifier), amount) end

local function groupAccount(name)
    local a = ox():GetGroupAccount(name)
    return a and a.accountId or nil
end
function A.AddSocietyMoney(society, amount) return addTo(groupAccount(society), amount) end
function A.RemoveSocietyMoney(society, amount) return removeFrom(groupAccount(society), amount) end

-- garage: ox_core's vehicles table (stored = a garage name, 'impound', or NULL when out)
function A.GetVehicles(identifier)
    local rows = MySQL.query.await('SELECT plate, model, stored, data FROM vehicles WHERE owner = ?', { tonumber(identifier) }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local ok, data = pcall(json.decode, r.data or '{}')
        local props = ok and type(data) == 'table' and (data.properties or data) or {}
        list[#list + 1] = {
            plate = r.plate, model = r.model and joaat(r.model) or nil, type = 'car',
            stored = r.stored ~= nil and r.stored ~= 'impound', parking = r.stored ~= 'impound' and r.stored or nil,
            pound = r.stored == 'impound' and 'Impound' or nil,
            fuel = props.fuelLevel, engine = props.engineHealth, body = props.bodyHealth,
        }
    end
    return list
end

function A.BackfillNames()
    return MySQL.update.await([[UPDATE opslabs_phone_users p JOIN characters c ON c.charId = p.identifier
        SET p.char_first = c.firstName, p.char_last = c.lastName WHERE p.char_first IS NULL]])
end

A.events = {
    loaded = { ['ox:playerLoaded'] = function(src) return src end },        -- (source, userId, charId)
    unloaded = { ['ox:playerLogout'] = function(src) return src end },
}

Bridge.RegisterFramework('ox', A)
