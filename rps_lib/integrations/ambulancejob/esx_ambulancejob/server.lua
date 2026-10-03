--[[
    integrations/ambulancejob/esx_ambulancejob/server.lua
    See client.lua for the statebag caveats — same assumptions apply
    server-side.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.esx_ambulancejob = lib.ambulances.esx_ambulancejob or {}

local impl = lib.ambulances.esx_ambulancejob

--- Dead/downed check via the 'isDead' statebag esx_ambulancejob maintains on
--- the player entity. Returns false if unset or the player doesn't exist,
--- rather than erroring.
function impl.IsPlayerDead(source)
    local ok, isDead = pcall(function()
        return Player(source).state.isDead == true
    end)
    return ok and isDead or false
end

--- Asks that client to revive itself via the long-standing esx_ambulancejob
--- revive event.
function impl.RevivePlayer(source)
    TriggerClientEvent('esx_ambulancejob:revive', source)
end
