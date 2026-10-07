-- OPS Buds: wireless earbuds. The item is the case with both buds; using it takes them out / puts them back
-- (client/buds.lua does the rest). Their settings (paired, name, Noise Control, …) live in the phone settings under
-- `buds`, the three battery levels under `budsBattery` (reported by the client, like the phone battery).

local CB = Config.Buds or {}
local MODES = { anc = true, adaptive = true, transparency = true, off = true }

--- whitelist what the UI may save for the buds
function CleanBuds(v)
    return {
        paired = v.paired == true,
        name = type(v.name) == 'string' and Clean(v.name, 32) or nil,
        mode = MODES[v.mode] and v.mode or 'anc',
        earDetect = v.earDetect ~= false,
        convAware = v.convAware ~= false,
    }
end

if CB.Enabled == false then return end

local function ensureItem()
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'items']])
    if (tonumber(has) or 0) == 0 then return end
    MySQL.query.await('INSERT IGNORE INTO items (name, label, weight) VALUES (?, ?, ?)', { CB.Item or 'ops_buds', CB.Label or 'OPS Buds', 1 })
end
MySQL.ready(function() pcall(ensureItem) end)

FW.UsableItem(CB.Item or 'ops_buds', function(src)
    if LicenseHas and not LicenseHas('phone.accessories') then return end      -- OPSHUB license (server/license.lua)
    if FW.ItemCount(src, CB.Item or 'ops_buds') < 1 then return end
    TriggerClientEvent('opslabs-phone:budsUse', src)
end)

lib.callback.register('opslabs-phone:hasBuds', function(src)
    return FW.ItemCount(src, CB.Item or 'ops_buds') > 0
end)

local saveAt, pending = {}, {}      -- pending: src -> phone with unsaved levels (main.lua drops Phones[src] first on leave)
RegisterNetEvent('opslabs-phone:budsBattery', function(l, r, c)
    local src = source
    local phone = GetPhone(src)
    if not phone then return end
    local function pct(v) v = tonumber(v) or 100 return math.floor(math.max(0, math.min(100, v)) * 10 + 0.5) / 10 end
    phone.settings.budsBattery = { l = pct(l), r = pct(r), c = pct(c) }
    pending[src] = phone
    local now = os.time()
    if now - (saveAt[src] or 0) >= 120 then
        saveAt[src], pending[src] = now, nil
        MySQL.update('UPDATE opslabs_phone_users SET settings = ? WHERE identifier = ?', { json.encode(phone.settings), phone.identifier })
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local phone = pending[src]
    if phone then
        MySQL.update('UPDATE opslabs_phone_users SET settings = ? WHERE identifier = ?', { json.encode(phone.settings), phone.identifier })
    end
    saveAt[src], pending[src] = nil, nil
end)
