--[[
    integrations/notifications/codem/server.lua
    codem-supreme-notification has its own per-player server export, so
    (unlike ox_lib) this doesn't need to bridge to the client at all.
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.codem = lib.notifications.codem or {}

local impl = lib.notifications.codem

local TYPE_MAP = { success = 'success', error = 'error' } -- everything else -> 'info'

--- Shows `source` a codem-supreme-notification via its own server export.
function impl.Notify(source, options)
    options = options or {}
    local notifyType = TYPE_MAP[options.type] or 'info'
    local message = options.description or options.title or ''
    exports['codem-supreme-notification']:SendNotification(source, notifyType, message, options.duration)
end
