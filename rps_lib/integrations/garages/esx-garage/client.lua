--[[
    integrations/garages/esx-garage/client.lua
    Unlike QBCore forks, ESX garage scripts (esx_garage, esx_advancedgarage,
    jb-eden-garage, etc.) don't share one standard "open garage" event, so
    there's nothing safe to hardcode here. Point OpenGarage at whatever event
    your installed garage script actually listens for.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['esx-garage'] = lib.garages['esx-garage'] or {}

local impl = lib.garages['esx-garage']

function impl.OpenGarage(garageName)
    -- No universal event across ESX garage scripts. Example for esx_advancedgarage:
    -- TriggerEvent('esx_advancedgarage:openGarage', garageName)
    lib.print(('OpenGarage("%s") called — wire this up to your installed ESX garage script in integrations/garages/esx-garage/client.lua'):format(garageName))
end
