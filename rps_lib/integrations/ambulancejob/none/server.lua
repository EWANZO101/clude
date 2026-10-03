--[[
    integrations/ambulancejob/none/server.lua
    Fallback used when no ambulance job integration is detected/configured.
    The server has no direct way to check a client's ped state, so
    IsPlayerDead always returns false; RevivePlayer is a no-op.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.none = lib.ambulances.none or {}

local impl = lib.ambulances.none

function impl.IsPlayerDead(source) return false end
function impl.RevivePlayer(source) end
