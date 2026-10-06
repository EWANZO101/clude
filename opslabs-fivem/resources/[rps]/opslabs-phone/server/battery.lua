-- Phone battery: the client works out drain / charge (it knows if the phone is open and whether a live
-- charger is beside the player) and reports here; the level is kept per character in the phone settings.
-- A flat phone (0 %) is switched off: it can't be called. Power banks are items.

local CB = Config.Battery or {}
local saveAt = {}

--- is this player's phone switched off with a flat battery?
function PhoneDead(src)
    if CB.Enabled == false then return false end
    local phone = Phones[src]
    return phone ~= nil and (tonumber(phone.settings.battery) or 100) <= 0
end

local function save(phone)
    MySQL.update('UPDATE opslabs_phone_users SET settings = ? WHERE identifier = ?', { json.encode(phone.settings), phone.identifier })
end

RegisterNetEvent('opslabs-phone:battery', function(level, charging)
    local src = source
    if CB.Enabled == false then return end
    local phone = GetPhone(src)
    level = tonumber(level)
    if not phone or not level then return end
    level = math.max(0.0, math.min(100.0, level))
    local was = tonumber(phone.settings.battery) or 100
    phone.settings.battery = math.floor(level * 10 + 0.5) / 10
    phone.charging = charging == true
    if level <= 0 and was > 0 and EndCallFor then EndCallFor(src) end
    -- write through on big moments, otherwise every couple of minutes
    local now = os.time()
    if (level <= 0) ~= (was <= 0) or now - (saveAt[src] or 0) >= 120 then
        saveAt[src] = now
        save(phone)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local phone = Phones[src]
    if phone and phone.settings.battery then save(phone) end
    saveAt[src] = nil
end)

---------------------------------------------------------------------------
-- power banks: use a charged one → +PowerBankAmount % over a minute or so and it goes flat;
-- use a flat one beside a live charger → it recharges
---------------------------------------------------------------------------

local function ensureItems()
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'items']])
    if (tonumber(has) or 0) == 0 then return end
    MySQL.query.await('INSERT IGNORE INTO items (name, label, weight) VALUES (?, ?, ?), (?, ?, ?)', {
        CB.PowerBankItem or 'powerbank', 'Power bank', 1, CB.PowerBankEmptyItem or 'powerbank_empty', 'Power bank (flat)', 1 })
end

if CB.Enabled ~= false and CB.PowerBankItem then
    MySQL.ready(function() pcall(ensureItems) end)

    local busy = {}
    local function isBusy(src) return busy[src] and os.time() - busy[src] < (CB.PowerBankRecharge or 60) * 3 end
    FW.UsableItem(CB.PowerBankItem, function(src)
        if isBusy(src) then return end
        if FW.ItemCount(src, CB.PowerBankItem) < 1 then return end
        if not FW.RemoveItem(src, CB.PowerBankItem, 1) then return end
        FW.AddItem(src, CB.PowerBankEmptyItem, 1)
        TriggerClientEvent('opslabs-phone:powerbank', src, CB.PowerBankAmount or 50)
    end)

    FW.UsableItem(CB.PowerBankEmptyItem, function(src)
        if isBusy(src) or FW.ItemCount(src, CB.PowerBankEmptyItem) < 1 then return end
        busy[src] = os.time()
        TriggerClientEvent('opslabs-phone:powerbankRecharge', src, CB.PowerBankRecharge or 60)
    end)

    -- the client ran the recharge beside a live charger
    RegisterNetEvent('opslabs-phone:powerbankCharged', function(ok)
        local src = source
        if not busy[src] then return end
        busy[src] = nil
        if ok and FW.RemoveItem(src, CB.PowerBankEmptyItem, 1) then FW.AddItem(src, CB.PowerBankItem, 1) end
    end)
    AddEventHandler('playerDropped', function() busy[source] = nil end)
end
