--[[
    integrations/notifications/ox_lib/server.lua
    ox_lib has no server-side notify export — notifications only ever render
    client-side. This bridges a server-initiated notification over to the
    target client's own ShowNotification (client/client.lua, which resolves
    whatever notification module that client has selected).
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.ox_lib = lib.notifications.ox_lib or {}

local impl = lib.notifications.ox_lib

--- Shows `source` a notification. Fire-and-forget — unlike progress bars,
--- there's no completion result to report back.
function impl.Notify(source, options)
    TriggerClientEvent('rps_lib:notification:show', source, options)
end
