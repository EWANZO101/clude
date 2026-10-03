--[[
    integrations/inventory/tgiann-inventory/server.lua
    Uses tgiann-inventory's own server exports directly — it's
    framework-agnostic (works on ESX/QB/Qbox) and, unlike the QBCore-family
    integrations here, has real exports for everything this module needs,
    including an actual CanCarryItem weight/slot check and a ClearInventory
    with the same (source, keep) shape this module already uses.
    https://tgiann.gitbook.io/tgiann/scripts/tgiann-inventory/exports/server
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories['tgiann-inventory'] = lib.inventories['tgiann-inventory'] or {}

local impl = lib.inventories['tgiann-inventory']

function impl.GetItemCount(source, item)
    return exports['tgiann-inventory']:GetItemCount(source, item) or 0
end

function impl.HasItem(source, item, count)
    return exports['tgiann-inventory']:HasItem(source, item, count or 1) and true or false
end

--- metadata is optional and passed straight through as tgiann-inventory's
--- "info" table (slot is left nil / auto-assigned).
function impl.AddItem(source, item, count, metadata)
    return exports['tgiann-inventory']:AddItem(source, item, count or 1, nil, metadata) and true or false
end

function impl.RemoveItem(source, item, count, metadata)
    return exports['tgiann-inventory']:RemoveItem(source, item, count or 1, nil, metadata) and true or false
end

--- Returns a normalized list of every item the player is carrying:
--- { { name, count, metadata }, ... }
function impl.GetInventory(source)
    local items = exports['tgiann-inventory']:GetPlayerItems(source) or {}
    local result = {}
    for _, item in pairs(items) do
        result[#result + 1] = { name = item.name, count = item.amount, metadata = item.metadata or item.info }
    end
    return result
end

--- keep (optional): array of item names to leave untouched — tgiann-inventory's
--- own ClearInventory takes this exact (source, filterItems) shape natively.
function impl.ClearInventory(source, keep)
    exports['tgiann-inventory']:ClearInventory(source, keep)
    return true
end

--- Real weight/slot check via tgiann-inventory's own export (unlike the
--- QBCore-family integrations here, which have no such API and always
--- return true).
function impl.CanCarryItem(source, item, count)
    return exports['tgiann-inventory']:CanCarryItem(source, item, count or 1) and true or false
end

--- Returns the item catalog definition for one item name, or nil if unknown.
function impl.GetItemDefinition(item)
    return exports['tgiann-inventory']:Items(item)
end

--- Returns the full item catalog (item name -> definition).
function impl.GetItemCatalog()
    return exports['tgiann-inventory']:Items() or {}
end
