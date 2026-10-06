--[[
    integrations/progressbar/ox_lib/server.lua
    ox_lib has no server-side progress bar API of its own — the bar only ever
    renders client-side. This bridges a server-initiated request over to the
    target client's own ProgressBar (client/client.lua, which resolves
    whatever progress bar module that client has selected) and reports the
    result back.
]]

lib = lib or {}
lib.progressbars = lib.progressbars or {}
lib.progressbars.ox_lib = lib.progressbars.ox_lib or {}

local impl = lib.progressbars.ox_lib

local pending = {}
local nextId = 0

--- Asks `source`'s client to run a progress bar. cb(completed) is optional —
--- completed is true if the bar finished, false if it was cancelled.
function impl.ProgressBar(source, options, cb)
    nextId = nextId + 1
    local id = nextId
    pending[id] = cb
    TriggerClientEvent('rps_lib:progressbar:start', source, id, options)
end

RegisterNetEvent('rps_lib:progressbar:result', function(id, completed)
    local cb = pending[id]
    if cb then
        pending[id] = nil
        cb(completed)
    end
end)
