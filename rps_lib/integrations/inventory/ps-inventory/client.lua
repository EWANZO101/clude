--[[
    integrations/inventory/ps-inventory/client.lua
    Client-side item checks via QBCore's own PlayerData.items — a
    convenience for UI gating only, NOT authoritative. See
    integrations/inventory/qb-inventory/client.lua for the full caveat.
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories['ps-inventory'] = lib.inventories['ps-inventory'] or {}

local impl = lib.inventories['ps-inventory']

local QBCore = nil
local function getObject()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

function impl.GetItemCount(item)
    local px = getObject().Functions.GetPlayerData()
    local count = 0
    for _, slot in pairs(px.items or {}) do
        if slot and slot.name == item then
            count = count + (slot.amount or 0)
        end
    end
    return count
end

function impl.HasItem(item, count)
    return impl.GetItemCount(item) >= (count or 1)
end
