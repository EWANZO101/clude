--[[
    integrations/notifications/none/client.lua
    Fallback used when no rich notification module is detected/configured.
    Degrades to this library's own framework-backed Notify, extracting a
    plain message from the richer ox_lib-style options table so callers
    don't have to special-case the "no rich notifications" server.
]]

lib = lib or {}
lib.notifications = lib.notifications or {}
lib.notifications.none = lib.notifications.none or {}

local impl = lib.notifications.none

-- ox_lib notify types are 'inform' | 'success' | 'error' | 'warning'; the
-- plain Notify only knows 'success' | 'error' | 'info' — map what matches
-- and default everything else to 'info'.
local TYPE_MAP = { success = 'success', error = 'error' }

function impl.Notify(options)
    options = options or {}
    local message = options.description or options.title or ''
    Notify(message, TYPE_MAP[options.type] or 'info')
end
