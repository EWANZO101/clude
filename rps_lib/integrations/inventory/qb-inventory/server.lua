--[[
    integrations/inventory/qb-inventory/server.lua
    qb-inventory doesn't expose item-manipulation exports of its own — item
    state lives on the QBCore player object, and qb-inventory (like every
    QBCore-compatible inventory fork) reads/writes it through
    Player.Functions, so that's what this targets directly.
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories['qb-inventory'] = lib.inventories['qb-inventory'] or {}

local impl = lib.inventories['qb-inventory']

local QBCore = nil
local function getObject()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

function impl.GetItemCount(source, item)
    local px = getObject().Functions.GetPlayer(source)
    if not px then return 0 end
    local itemData = px.Functions.GetItemByName(item)
    return itemData and itemData.amount or 0
end

function impl.HasItem(source, item, count)
    return impl.GetItemCount(source, item) >= (count or 1)
end

--- metadata is passed through to Player.Functions.AddItem as the item's
--- "info" table.
function impl.AddItem(source, item, count, metadata)
    local px = getObject().Functions.GetPlayer(source)
    if not px then return false end
    px.Functions.AddItem(item, count or 1, nil, metadata)
    return true
end

function impl.RemoveItem(source, item, count, metadata)
    local px = getObject().Functions.GetPlayer(source)
    if not px then return false end
    px.Functions.RemoveItem(item, count or 1)
    return true
end

--- Returns a normalized list of every item the player is carrying:
--- { { name, count, metadata }, ... }
function impl.GetInventory(source)
    local px = getObject().Functions.GetPlayer(source)
    if not px then return {} end
    local result = {}
    for _, item in pairs(px.PlayerData.items or {}) do
        if item then
            result[#result + 1] = { name = item.name, count = item.amount, metadata = item.info }
        end
    end
    return result
end

--- keep is not supported here — QBCore's own ClearInventory always clears
--- everything, unlike ox_inventory's.
function impl.ClearInventory(source, keep)
    local px = getObject().Functions.GetPlayer(source)
    if not px then return false end
    px.Functions.ClearInventory()
    return true
end

--- QBCore has no carry-weight/slot check shared across every
--- QBCore-compatible inventory fork, so this always returns true — it does
--- NOT actually validate capacity on this integration. Don't rely on it to
--- prevent overloading a player; AddItem will still succeed or silently do
--- whatever the installed inventory does internally when over capacity.
function impl.CanCarryItem(source, item, count)
    return true
end

function impl.GetItemDefinition(item)
    return getObject().Shared.Items[item]
end

function impl.GetItemCatalog()
    return getObject().Shared.Items or {}
end
