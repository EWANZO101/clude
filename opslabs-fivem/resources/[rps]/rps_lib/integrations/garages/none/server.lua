--[[
    integrations/garages/none/server.lua
    Fallback used when no garage script is detected/configured. All calls
    return empty/false rather than erroring.
]]

lib = lib or {}
lib.garages = lib.garages or {}
lib.garages.none = lib.garages.none or {}

local impl = lib.garages.none

function impl.GetPlayerVehicles(identifier, cb) cb({}) end
function impl.IsVehicleStored(plate, cb) cb(false) end
function impl.SetVehicleStored(plate, stored, cb) if cb then cb(false) end end
