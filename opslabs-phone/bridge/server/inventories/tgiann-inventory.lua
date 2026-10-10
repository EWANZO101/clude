-- tgiann-inventory. Experimental and unverified: its docs couldn't be read; it advertises qb-inventory compatible
-- exports, which is what this uses. Please report whether it works.
local A = { label = 'tgiann-inventory', resource = 'tgiann-inventory', status = 'experimental', builtin = true }
local function inv() return exports['tgiann-inventory'] end

function A.detect() return Bridge.Started('tgiann-inventory') end
function A.ItemCount(src, item) return tonumber(inv():GetItemCount(src, item)) or 0 end
function A.AddItem(src, item, count, metadata) return inv():AddItem(src, item, count, false, metadata) ~= false end
function A.RemoveItem(src, item, count) return inv():RemoveItem(src, item, count) ~= false end

Bridge.RegisterInventory('tgiann-inventory', A)
