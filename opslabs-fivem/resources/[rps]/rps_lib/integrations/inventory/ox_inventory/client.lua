--[[
    integrations/inventory/ox_inventory/client.lua
    Client-side item checks via ox_inventory's own Search export. This is a
    convenience for UI gating (show/hide a prompt, grey out a button) —
    NOT authoritative. A client can lie about its own inventory state, so
    never trust this for anything that grants a reward; re-verify with the
    server-side HasItem/GetItemCount before actually giving anything.
]]

lib = lib or {}
lib.inventories = lib.inventories or {}
lib.inventories.ox_inventory = lib.inventories.ox_inventory or {}

local impl = lib.inventories.ox_inventory

function impl.GetItemCount(item)
    return exports.ox_inventory:Search('count', item) or 0
end

function impl.HasItem(item, count)
    return impl.GetItemCount(item) >= (count or 1)
end
