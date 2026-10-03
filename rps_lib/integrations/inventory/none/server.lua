--[[
    integrations/inventory/none/server.lua
    Fallback used when no inventory integration is detected/configured. All
    calls return empty/false rather than erroring.
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories.none = lib.inventories.none or {}

local impl = lib.inventories.none

function impl.GetItemCount(source, item) return 0 end
function impl.HasItem(source, item, count) return false end
function impl.AddItem(source, item, count, metadata) return false end
function impl.RemoveItem(source, item, count, metadata) return false end
function impl.GetInventory(source) return {} end
function impl.ClearInventory(source, keep) return false end
function impl.CanCarryItem(source, item, count) return false end
function impl.GetItemDefinition(item) return nil end
function impl.GetItemCatalog() return {} end
