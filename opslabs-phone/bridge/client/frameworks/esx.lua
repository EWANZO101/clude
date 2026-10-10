-- ESX Legacy (client)
Bridge.RegisterFramework('esx', {
    label = 'ESX Legacy', builtin = true,
    events = {
        loaded = { ['esx:playerLoaded'] = true },
        unloaded = { ['esx:onPlayerLogout'] = true },
        -- the ESX inventory (only used when no other inventory runs)
        inventory = {
            ['esx:addInventoryItem'] = function(item) return item end,
            ['esx:removeInventoryItem'] = function(item) return item end,
        },
    },
})
