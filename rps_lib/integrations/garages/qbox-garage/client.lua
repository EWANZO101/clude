--[[
    integrations/garages/qbox-garage/client.lua
    qbx_garages builds its vehicle-list menu internally in response to its own
    target-zone interactions and doesn't expose a plain "open menu" event or
    export for other resources to call directly. If you need to trigger it
    externally, hook into whatever target/zone system you configured
    qbx_garages' access points with instead.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['qbox-garage'] = lib.garages['qbox-garage'] or {}

local impl = lib.garages['qbox-garage']

function impl.OpenGarage(garageName)
    lib.print(('OpenGarage("%s") called — qbx_garages has no external "open menu" event; it opens via its own configured access points'):format(garageName))
end
