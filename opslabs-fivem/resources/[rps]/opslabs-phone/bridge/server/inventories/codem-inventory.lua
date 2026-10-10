-- codem-inventory v1 (mInventory Remake). Experimental: from Codem's published export list. Version 2 answers as
-- ox_inventory and is handled by that adapter.
local A = { label = 'codem-inventory', resource = 'codem-inventory', status = 'experimental', builtin = true }
local function inv() return exports['codem-inventory'] end

function A.detect() return Bridge.Started('codem-inventory') and not Bridge.Started('ox_inventory') end
function A.ItemCount(src, item) return tonumber(inv():GetItemsTotalAmount(src, item)) or 0 end
function A.AddItem(src, item, count, metadata) return inv():AddItem(src, item, count, nil, metadata) ~= false end
function A.RemoveItem(src, item, count) return inv():RemoveItem(src, item, count) ~= false end

Bridge.RegisterInventory('codem-inventory', A)
