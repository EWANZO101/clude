--[[
    integrations/ambulancejob/qbx_ambulancejob/server.lua
    See client.lua for the metadata/event caveats — same assumptions apply
    server-side.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.qbx_ambulancejob = lib.ambulances.qbx_ambulancejob or {}

local impl = lib.ambulances.qbx_ambulancejob

--- True if the player is dead OR in "last stand" (downed, not yet dead),
--- per qbx_core's own player metadata.
function impl.IsPlayerDead(source)
    local px = exports['qbx_core']:GetPlayer(source)
    local metadata = px and px.PlayerData.metadata
    return metadata ~= nil and (metadata.isdead == true or metadata.inlaststand == true)
end

--- Asks that client to revive itself via qbx_ambulancejob's revive event.
function impl.RevivePlayer(source)
    TriggerClientEvent('hospital:client:Revive', source)
end
