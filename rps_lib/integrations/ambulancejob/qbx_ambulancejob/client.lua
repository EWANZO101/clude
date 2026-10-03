--[[
    integrations/ambulancejob/qbx_ambulancejob/client.lua
    qbx_ambulancejob is Qbox's adaptation of qb-ambulancejob for qbx_core —
    it keeps the same qb-core-style player metadata ('isdead' / 'inlaststand')
    and, as of writing, the same 'hospital:client:Revive' event rather than
    the export-based rewrite Qbox gave qbx_vehicles/qbx_garages. Verify
    against your installed version if this has since changed.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.qbx_ambulancejob = lib.ambulances.qbx_ambulancejob or {}

local impl = lib.ambulances.qbx_ambulancejob

--- True if the local player is dead OR in "last stand" (downed, not yet dead).
function impl.IsPlayerDead()
    local px = exports['qbx_core']:GetPlayerData()
    local metadata = px and px.metadata
    return metadata ~= nil and (metadata.isdead == true or metadata.inlaststand == true)
end

--- Revives the local player. Fires qbx_ambulancejob's revive event — verify
--- against your installed version if it's since moved to an export.
function impl.RevivePlayer()
    TriggerEvent('hospital:client:Revive')
end
