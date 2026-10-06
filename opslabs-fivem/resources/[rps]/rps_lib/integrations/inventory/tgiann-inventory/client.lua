--[[
    integrations/inventory/tgiann-inventory/client.lua
    Client-side item checks via tgiann-inventory's own exports — a
    convenience for UI gating only, NOT authoritative. See
    integrations/inventory/ox_inventory/client.lua for the full caveat.
    https://tgiann.gitbook.io/tgiann/scripts/tgiann-inventory/exports/client
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories['tgiann-inventory'] = lib.inventories['tgiann-inventory'] or {}

local impl = lib.inventories['tgiann-inventory']

function impl.GetItemCount(item)
    return exports['tgiann-inventory']:GetItemCount(item) or 0
end

function impl.HasItem(item, count)
    return exports['tgiann-inventory']:HasItem(item, count or 1) and true or false
end
