-- QBCore and Qbox (client). Both fire the QBCore load / unload events (Qbox as local events, QBCore as net events;
-- RegisterNetEvent handlers get both).
local events = {
    loaded = { ['QBCore:Client:OnPlayerLoaded'] = true },
    unloaded = { ['QBCore:Client:OnPlayerUnload'] = true },
}
Bridge.RegisterFramework('qbx', { label = 'Qbox', builtin = true, events = events })
Bridge.RegisterFramework('qb', { label = 'QBCore', builtin = true, events = events })
