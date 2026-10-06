--[[
    integrations/notifications/codem/client.lua
    Targets codem-supreme-notification (resource name
    'codem-supreme-notification'). Unlike ox_lib, it takes positional
    (notifyType, text, duration) rather than an options table, and its
    notifyType enum ('success' | 'info' | 'error') matches this library's
    own plain Notify types exactly — so the mapping here is direct, not a
    lossy approximation like the 'none' fallback's.
    https://codem.gitbook.io/codem-documentation/supreme-series/essentials/notification/usage
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.codem = lib.notifications.codem or {}

local impl = lib.notifications.codem

local TYPE_MAP = { success = 'success', error = 'error' } -- everything else -> 'info'

--- Shows a codem-supreme-notification locally, extracting (type, message,
--- duration) from the richer options table this module's unified
--- ShowNotification accepts.
function impl.Notify(options)
    options = options or {}
    local notifyType = TYPE_MAP[options.type] or 'info'
    local message = options.description or options.title or ''
    exports['codem-supreme-notification']:SendNotification(notifyType, message, options.duration)
end
