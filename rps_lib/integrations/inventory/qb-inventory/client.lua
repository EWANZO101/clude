--[[
    integrations/inventory/qb-inventory/client.lua
    Client-side item checks via QBCore's own PlayerData.items — a
    convenience for UI gating only, NOT authoritative. A client can lie
    about its own inventory state, so never trust this for anything that
    grants a reward; re-verify with the server-side HasItem/GetItemCount
    before actually giving anything.
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
