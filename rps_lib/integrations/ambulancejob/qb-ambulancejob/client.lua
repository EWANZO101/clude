--[[
    integrations/ambulancejob/qb-ambulancejob/client.lua
    Targets qb-ambulancejob and most forks, which track dead/downed state via
    qb-core's own player metadata ('isdead' / 'inlaststand') rather than
    anything ambulance-job-specific — that metadata is set by qb-core's death
    handling and read by qb-ambulancejob, so this works even if your hospital
    UI is a heavily customized fork.
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

--- True if the local player is dead OR in "last stand" (downed, not yet dead).
function impl.IsPlayerDead()
    local px = getObject().Functions.GetPlayerData()
    local metadata = px and px.metadata
    return metadata ~= nil and (metadata.isdead == true or metadata.inlaststand == true)
end

--- Revives the local player. Fires qb-ambulancejob's standard revive event —
--- verify against your fork if it renamed this.
function impl.RevivePlayer()
    TriggerEvent('hospital:client:Revive')
end
