--[[
    integrations/garages/none/client.lua
    Fallback used when no garage script is detected/configured.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages.none = lib.garages.none or {}

local impl = lib.garages.none

function impl.OpenGarage(garageName)
    lib.print('OpenGarage called but no garage module is configured (Config.Garage = "none")')
end
