--[[
    integrations/inventory/none/client.lua
    Fallback used when no inventory integration is detected/configured. All
    calls return empty/false rather than erroring.
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories.none = lib.inventories.none or {}

local impl = lib.inventories.none

function impl.GetItemCount(item) return 0 end
function impl.HasItem(item, count) return false end
