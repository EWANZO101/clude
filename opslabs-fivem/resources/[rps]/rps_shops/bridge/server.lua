-- ============================================
--  rps_lib Bridge (server)
--  Framework (ESX / QBCore / QBox / standalone), inventory
--  (ox / tgiann / qb / ps / lj) and notifications are handled by rps_lib.
--  Requires rps_lib started before this resource.
--  Force a framework with: setr rps_lib:forceFramework "esx"
-- ============================================
Bridge = {}

local rps = exports.rps_lib

CreateThread(function()
    Wait(500) -- rps_lib detects the framework/inventory asynchronously on start
    print(('[rps_shops] Framework: %s | Inventory: %s (via rps_lib)'):format(
        rps:GetFrameworkName(),
        rps:GetInventoryName()
    ))
end)

-- --------------------------------------------
--  Inventory
-- --------------------------------------------

function Bridge.CanCarryItem(src, item, count)
    return rps:CanCarryItem(src, item, count) == true
end

function Bridge.AddItem(src, item, count, metadata)
    return rps:AddItem(src, item, count, metadata) == true
end

function Bridge.RemoveItem(src, item, count, metadata)
    return rps:RemoveItem(src, item, count, metadata) == true
end

-- --------------------------------------------
--  Currency
--  Config.Currency.Type = 'item'    -> inventory item (Config.Currency.Item)
--  Config.Currency.Type = 'account' -> framework account (Config.Currency.Account)
-- --------------------------------------------

local function usesAccount()
    return Config.Currency.Type == 'account'
end

function Bridge.GetCurrency(src)
    if usesAccount() then
        return rps:GetMoney(src, Config.Currency.Account) or 0
    end
    return rps:GetItemCount(src, Config.Currency.Item) or 0
end

function Bridge.RemoveCurrency(src, amount)
    if amount <= 0 then return true end
    if usesAccount() then
        return rps:RemoveMoney(src, amount, Config.Currency.Account) == true
    end
    return Bridge.RemoveItem(src, Config.Currency.Item, amount)
end

function Bridge.AddCurrency(src, amount)
    if amount <= 0 then return true end
    if usesAccount() then
        return rps:AddMoney(src, amount, Config.Currency.Account) == true
    end
    return Bridge.AddItem(src, Config.Currency.Item, amount)
end

-- --------------------------------------------
--  Notifications
-- --------------------------------------------

--- type: 'success' | 'error' | 'inform'/'info'
function Bridge.Notify(src, msg, type, title)
    if type == 'inform' or not type then type = 'info' end
    rps:ShowNotification(src, { title = title or Config.DefaultLocale.ShopTitle, description = msg, type = type })
end
