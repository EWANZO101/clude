--[[
    integrations/garages/qb-garage/client.lua
    Triggers the standard qb-garages client events (qbcore-framework/qb-garages
    and most forks share these). If your installed fork renamed them, update
    the event names below to match.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages['qb-garage'] = lib.garages['qb-garage'] or {}

local impl = lib.garages['qb-garage']

--- Opens the garage menu/UI for the given garage name (as configured in your
--- garage script's own Config.Garages).
function impl.OpenGarage(garageName)
    TriggerEvent('qb-garages:openGarage', garageName)
end

--- Parks whatever vehicle the player last pulled out (used by "park here" zones).
function impl.ParkLastVehicle(garageName)
    TriggerEvent('qb-garages:client:ParkLastVehicle', garageName)
end
