--[[
    integrations/notifications/none/server.lua
    Fallback used when no rich notification module is detected/configured.
    Degrades to this library's own framework-backed Notify, extracting a
    plain message from the richer ox_lib-style options table. Resolves
    entirely server-side — no round-trip to the client needed.
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.none = lib.notifications.none or {}

local impl = lib.notifications.none

local TYPE_MAP = { success = 'success', error = 'error' }

function impl.Notify(source, options)
    options = options or {}
    local message = options.description or options.title or ''
    Notify(source, message, TYPE_MAP[options.type] or 'info')
end
