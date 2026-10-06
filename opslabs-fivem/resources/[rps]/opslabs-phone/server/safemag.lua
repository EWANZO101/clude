-- OPS SafeMag: a magnetic battery pack that snaps onto the back of the phone. The item is the pack; using it snaps
-- it on / takes it off (client/safemag.lua does the charging). Its level and whether it's on live in the phone
-- settings under `safemag` = { level, on } (reported by the client, like the phone battery).

local CS = Config.SafeMag or {}
if CS.Enabled == false then return end
local ITEM = CS.Item or 'ops_safemag'

local function ensureItem()
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'items']])
    if (tonumber(has) or 0) == 0 then return end
    MySQL.query.await('INSERT IGNORE INTO items (name, label, weight) VALUES (?, ?, ?)', { ITEM, CS.Label or 'OPS SafeMag', 1 })
end
MySQL.ready(function() pcall(ensureItem) end)

FW.UsableItem(ITEM, function(src)
    if FW.ItemCount(src, ITEM) < 1 then return end
    TriggerClientEvent('opslabs-phone:safemagUse', src)
end)

lib.callback.register('opslabs-phone:hasSafeMag', function(src)
    return FW.ItemCount(src, ITEM) > 0
end)

local function save(phone)
    MySQL.update('UPDATE opslabs_phone_users SET settings = ? WHERE identifier = ?', { json.encode(phone.settings), phone.identifier })
end

local saveAt, pending = {}, {}      -- pending: src -> phone with an unsaved level (main.lua drops Phones[src] first on leave)
RegisterNetEvent('opslabs-phone:safemag', function(level, on)
    local src = source
    local phone = GetPhone(src)
    level = tonumber(level)
    if not phone or not level then return end
    local was = type(phone.settings.safemag) == 'table' and phone.settings.safemag.on == true
    phone.settings.safemag = { level = math.floor(math.max(0, math.min(100, level)) * 10 + 0.5) / 10, on = on == true }
    pending[src] = phone
    -- write through when it's snapped on / off, otherwise every couple of minutes
    local now = os.time()
    if was ~= (on == true) or now - (saveAt[src] or 0) >= 120 then
        saveAt[src], pending[src] = now, nil
        save(phone)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if pending[src] then save(pending[src]) end
    saveAt[src], pending[src] = nil, nil
end)
