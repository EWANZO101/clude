-- qb-inventory (current qbcore-framework/qb-inventory). Experimental: from its source, tested against fakes.
local A = { label = 'qb-inventory', resource = 'qb-inventory', status = 'experimental', builtin = true }
local function inv() return exports['qb-inventory'] end

function A.detect() return Bridge.Started('qb-inventory') end
function A.ItemCount(src, item) return tonumber(inv():GetItemCount(src, item)) or 0 end
function A.AddItem(src, item, count, metadata) return inv():AddItem(src, item, count, false, metadata, 'OPS Phone') == true end
function A.RemoveItem(src, item, count) return inv():RemoveItem(src, item, count, false, 'OPS Phone') == true end

Bridge.RegisterInventory('qb-inventory', A)
