-- ox_inventory (verified: the live ESX server runs it). Also covers codem-inventory v2, which answers as ox_inventory.
local A = { label = 'ox_inventory', resource = 'ox_inventory', status = 'verified', builtin = true }
local function ox() return exports.ox_inventory end

function A.detect() return Bridge.Started('ox_inventory') end
function A.ItemCount(src, item) return ox():GetItemCount(src, item) or 0 end
function A.AddItem(src, item, count, metadata) return (ox():AddItem(src, item, count, metadata)) == true end
-- metadata (optional): only a stack carrying it (e.g. this phone's number)
function A.RemoveItem(src, item, count, metadata) return (ox():RemoveItem(src, item, count, metadata)) == true end

-- per-item metadata (the phone item carries its number): { { slot, metadata } } and set one slot's metadata
function A.GetSlots(src, item)
    local out = {}
    for _, s in pairs(ox():Search(src, 'slots', item) or {}) do out[#out + 1] = { slot = s.slot, metadata = s.metadata or {} } end
    return out
end
function A.SetSlotMetadata(src, slot, metadata)
    ox():SetMetadata(src, slot, metadata)
    return true
end

-- only used when the framework has no usable items of its own (ox_core, standalone). ox_inventory runs the hook
-- for items that have `consume` set in their item data (e.g. consume = 0).
function A.UsableItem(item, handler)
    ox():registerHook('usingItem', function(payload)
        handler(payload.source)
        return false
    end, { itemFilter = { [item] = true } })
    return true
end

Bridge.RegisterInventory('ox_inventory', A)
