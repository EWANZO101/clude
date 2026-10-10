-- ps-inventory (QBCore). Experimental: from its source, tested against fakes. It has no GetItemCount, so the
-- stacks from GetItemsByName are added up.
local A = { label = 'ps-inventory', resource = 'ps-inventory', status = 'experimental', builtin = true }
local function inv() return exports['ps-inventory'] end

function A.detect() return Bridge.Started('ps-inventory') end

function A.ItemCount(src, item)
    local n = 0
    for _, stack in pairs(inv():GetItemsByName(src, item) or {}) do n = n + (tonumber(stack.amount) or 0) end
    return n
end

function A.AddItem(src, item, count, metadata) return inv():AddItem(src, item, count, false, metadata) ~= false end
function A.RemoveItem(src, item, count) return inv():RemoveItem(src, item, count) ~= false end

Bridge.RegisterInventory('ps-inventory', A)
