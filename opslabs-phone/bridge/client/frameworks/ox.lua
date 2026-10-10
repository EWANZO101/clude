-- ox_core (client)
Bridge.RegisterFramework('ox', {
    label = 'ox_core', builtin = true,
    events = { loaded = { ['ox:playerLoaded'] = true }, unloaded = { ['ox:playerLogout'] = true } },
})
