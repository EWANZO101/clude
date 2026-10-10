-- ox_inventory (client): a local event per changed item
Bridge.RegisterInventory('ox_inventory', {
    label = 'ox_inventory', builtin = true,
    localEvents = { ['ox_inventory:itemCount'] = true },
    events = { inventory = { ['ox_inventory:itemCount'] = function(item) return item end } },
})
