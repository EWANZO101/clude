local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

-- ox_inventory server exports (modules/inventory/server.lua): AddItem / RemoveItem return success, response
local function fakeOx(H, counts)
    H.resources.ox_inventory = 'started'
    local hooks = {}
    H.exportsOf.ox_inventory = {
        GetItemCount = function(_, src, item) return counts[item] or 0 end,
        AddItem = function(_, src, item, n) counts[item] = (counts[item] or 0) + n return true, 'ok' end,
        RemoveItem = function(_, src, item, n) if (counts[item] or 0) < n then return false, 'not_enough_items' end counts[item] = counts[item] - n return true end,
        registerHook = function(_, event, fn, opts) hooks[#hooks + 1] = { event = event, fn = fn, opts = opts } return #hooks end,
    }
    return hooks
end

test('ox_inventory is preferred over the framework inventory (the live ESX server)', function()
    local counts = { phone = 1 }
    local H = boot(function(H) F.esx(H) fakeOx(H, counts) end)
    eq(FW.Info().inventory, 'ox_inventory', 'inventory')
    eq(H.call(function() return FW.ItemCount(1, 'phone') end), 1, 'count')
    eq(H.call(function() return FW.RemoveItem(1, 'phone', 2) end), false, 'cannot remove more than held')
    eq(H.call(function() return FW.AddItem(1, 'phone', 1) end), true, 'add')
    eq(counts.phone, 2, 'added')
end)

test('ox_inventory: usable items through its usingItem hook when the framework has none (ox_core)', function()
    local hooks
    local H = boot(function(H) F.ox(H) hooks = fakeOx(H, {}) end)
    local used
    H.call(function() FW.UsableItem('ops_powerbank', function(src) used = src end) end)
    eq(hooks[1].event, 'usingItem', 'hook')
    ok(hooks[1].opts.itemFilter.ops_powerbank, 'filtered to the item')
    hooks[1].fn({ source = 8 })
    eq(used, 8, 'handler got the source')
end)

test('Config.Inventory = "none": no item checks, the phone needs no item', function()
    local H = boot(function(H) F.esx(H) Config.Inventory = 'none' end)
    eq(FW.Info().inventory, 'none', 'none')
    eq(H.call(function() return FW.HasInventory() end), false, 'no inventory')
    ok(H.logged('No inventory found: Config.RequireItem is ignored'), 'explained')
end)

test('qb-inventory on QBCore; ps-inventory adds up stacks', function()
    local H = boot(function(H)
        F.qb(H)
        H.resources['qb-inventory'] = 'started'
        H.exportsOf['qb-inventory'] = { GetItemCount = function() return 3 end }
    end)
    eq(FW.Info().inventory, 'qb-inventory', 'qb-inventory')
    eq(H.call(function() return FW.ItemCount(1, 'phone') end), 3, 'count')

    H = boot(function(H)
        F.qb(H)
        H.resources['ps-inventory'] = 'started'
        H.exportsOf['ps-inventory'] = { GetItemsByName = function() return { { amount = 2 }, { amount = 1 } } end }
    end)
    eq(FW.Info().inventory, 'ps-inventory', 'ps-inventory')
    eq(H.call(function() return FW.ItemCount(1, 'phone') end), 3, 'stacks added')
end)

test('a QBCore server without an inventory resource: no item requirement (QBCore has no items of its own)', function()
    local H = boot(function(H) F.qb(H) end)
    eq(FW.Info().inventory, 'none', 'none')
end)
