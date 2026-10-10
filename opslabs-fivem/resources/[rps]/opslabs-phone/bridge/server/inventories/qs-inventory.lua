-- qs-inventory (Quasar, closed source). Experimental: from Quasar's published export list; return values aren't
-- documented, so anything but false counts as done.
local A = { label = 'qs-inventory', resource = 'qs-inventory', status = 'experimental', builtin = true }
local function inv() return exports['qs-inventory'] end

function A.detect() return Bridge.Started('qs-inventory') end
function A.ItemCount(src, item) return tonumber(inv():GetItemTotalAmount(src, item)) or 0 end
function A.AddItem(src, item, count, metadata) return inv():AddItem(src, item, count, nil, metadata) ~= false end
function A.RemoveItem(src, item, count) return inv():RemoveItem(src, item, count) ~= false end
function A.UsableItem(item, handler)
    inv():CreateUsableItem(item, function(src) handler(src) end)
    return true
end

Bridge.RegisterInventory('qs-inventory', A)
