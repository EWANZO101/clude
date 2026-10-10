-- ND Core (client)
Bridge.RegisterFramework('nd', {
    label = 'ND Core', builtin = true,
    events = { loaded = { ['ND:characterLoaded'] = true }, unloaded = { ['ND:characterUnloaded'] = true } },
})
