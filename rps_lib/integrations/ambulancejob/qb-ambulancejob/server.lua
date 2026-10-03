--[[
    integrations/ambulancejob/qb-ambulancejob/server.lua
    See client.lua for the metadata/event caveats — same assumptions apply
    server-side.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances['qb-ambulancejob'] = lib.ambulances['qb-ambulancejob'] or {}

local impl = lib.ambulances['qb-ambulancejob']

local QBCore = nil
local function getObject()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

--- True if the player is dead OR in "last stand" (downed, not yet dead),
--- per qb-core's own player metadata.
function impl.IsPlayerDead(source)
    local px = getObject().Functions.GetPlayer(source)
    local metadata = px and px.PlayerData.metadata
    return metadata ~= nil and (metadata.isdead == true or metadata.inlaststand == true)
end

--- Asks that client to revive itself via qb-ambulancejob's standard revive event.
function impl.RevivePlayer(source)
    TriggerClientEvent('hospital:client:Revive', source)
end
