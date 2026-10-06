--[[
    integrations/ambulancejob/none/client.lua
    Fallback used when no ambulance job integration is detected/configured.
    IsPlayerDead falls back to the native ped-death check — that much is
    always accurate regardless of any job script — but there's no generic,
    safe way to "revive" a player without knowing your respawn/hospital
    design, so RevivePlayer just logs a reminder.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.none = lib.ambulances.none or {}

local impl = lib.ambulances.none

function impl.IsPlayerDead()
    return IsPedDeadOrDying(PlayerPedId(), true) == true
end

function impl.RevivePlayer()
    lib.print('RevivePlayer called but no ambulance job module is configured (Config.Ambulance = "none")')
end
