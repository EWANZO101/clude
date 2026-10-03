--[[
    integrations/ambulancejob/esx_ambulancejob/client.lua
    Targets esx_ambulancejob, which syncs death state via an 'isDead'
    statebag on the player entity (confirmed against an installed copy of
    this job: its own config.lua documents "Use Player(src).state.isDead
    for death checks", and server/main.lua sets it via
    Player(src).state:set('isDead', bool, true)). If your fork renamed the
    key or dropped statebags for a broadcast event instead, adjust
    IsPlayerDead below.
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {}
lib.ambulances.esx_ambulancejob = lib.ambulances.esx_ambulancejob or {}

local impl = lib.ambulances.esx_ambulancejob

--- Local dead/downed check via the 'isDead' statebag esx_ambulancejob
--- maintains. Returns false (rather than erroring) if the statebag isn't set.
function impl.IsPlayerDead()
    return LocalPlayer.state.isDead == true
end

--- Revives the local player. Fires the long-standing esx_ambulancejob revive
--- event — stable across most forks, but verify against yours if it's heavily
--- customized.
function impl.RevivePlayer()
    TriggerEvent('esx_ambulancejob:revive')
end
