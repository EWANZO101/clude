--[[
    integrations/inventory/ox_inventory/server.lua
    Uses ox_inventory's own server exports directly against the player's
    source id (ox_inventory accepts a player source as the inventory
    identifier for player inventories).
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories.ox_inventory = lib.inventories.ox_inventory or {}

local impl = lib.inventories.ox_inventory

--- Returns 0 rather than erroring if the item name is unknown or the player
--- has none.
function impl.GetItemCount(source, item)
    return exports.ox_inventory:GetItemCount(source, item) or 0
end

function impl.HasItem(source, item, count)
    return impl.GetItemCount(source, item) >= (count or 1)
end

--- metadata is optional and passed straight through to ox_inventory.
function impl.AddItem(source, item, count, metadata)
    return exports.ox_inventory:AddItem(source, item, count or 1, metadata) and true or false
end

function impl.RemoveItem(source, item, count, metadata)
    return exports.ox_inventory:RemoveItem(source, item, count or 1, metadata) and true or false
end

--- Returns a normalized list of every item the player is carrying:
--- { { name, count, metadata }, ... }
function impl.GetInventory(source)
    local items = exports.ox_inventory:GetInventoryItems(source) or {}
    local result = {}
    for _, item in pairs(items) do
        result[#result + 1] = { name = item.name, count = item.count, metadata = item.metadata }
    end
    return result
end

--- keep (optional): array of item names to leave untouched.
function impl.ClearInventory(source, keep)
    exports.ox_inventory:ClearInventory(source, keep)
    return true
end

--- Real weight/slot check via ox_inventory's own export.
function impl.CanCarryItem(source, item, count)
    return exports.ox_inventory:CanCarryItem(source, item, count or 1) and true or false
end

function impl.GetItemDefinition(item)
    local ok, items = pcall(function() return exports.ox_inventory:Items() end)
    return (ok and items and items[item]) or nil
end

function impl.GetItemCatalog()
    local ok, items = pcall(function() return exports.ox_inventory:Items() end)
    return (ok and items) or {}
end
