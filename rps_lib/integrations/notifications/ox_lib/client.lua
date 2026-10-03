--[[
    integrations/notifications/ox_lib/client.lua
    Shows the notification via ox_lib's own client export. Requires ox_lib
    running as its own resource.
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.ox_lib = lib.notifications.ox_lib or {}

local impl = lib.notifications.ox_lib

--- Shows an ox_lib notification locally. `options` is passed straight
--- through to ox_lib — see
--- https://overextended.dev/ox_lib/Modules/Interface/Client/notify
function impl.Notify(options)
    exports.ox_lib:notify(options)
end
