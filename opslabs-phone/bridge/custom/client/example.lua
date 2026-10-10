-- Your own framework adapter (client). Files in bridge/custom/client/ load automatically.
-- Register it under the SAME name as the server adapter. Does nothing until ENABLED = true. See bridge/README.md.

local ENABLED = false
if not ENABLED then return end

Bridge.RegisterFramework('myframework', {
    label = 'My Framework',
    events = {
        -- net events your framework sends the client; true = always, or a function(...) returning false to ignore one
        loaded = { ['my_core:client:characterLoaded'] = true },
        unloaded = { ['my_core:client:characterUnloaded'] = true },
        -- only used when the framework owns the inventory (Config.Inventory = 'framework'): return the item name, or
        -- nil when you can't tell which item changed
        inventory = { ['my_core:client:itemsChanged'] = function() return nil end },
    },
})
