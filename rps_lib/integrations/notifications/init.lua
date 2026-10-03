--[[
    integrations/notifications/init.lua
    Selects which rich-notification integration to use, mirroring how
    integrations/progressbar/init.lua picks the progress bar module —
    selection is based on whether ox_lib is running, not on the detected
    framework. This is separate from the plain framework-backed Notify/
    Notify(source, ...) in client/client.lua and server/server.lua — those
    always exist; this module is for the richer ox_lib-style notification
    shape (title/description/type/duration/icon/position, ...) when
    available, falling back to the plain Notify otherwise.

    Controlled by Config.Notifications in config.lua:
        Config.Notifications = 'auto'   -- auto-detect codem-supreme-notification, then ox_lib, else none (default)
        Config.Notifications = 'ox_lib' -- force the ox_lib integration
        Config.Notifications = 'codem'  -- force the codem-supreme-notification integration
        Config.Notifications = 'none'   -- fall back to the plain framework Notify

    codem-supreme-notification is checked before ox_lib in 'auto' mode
    deliberately: ox_lib is a hard dependency of rps_lib itself (always
    installed/started, for reasons unrelated to notifications), so if ox_lib
    were checked first it would always win — even on a server that installed
    codem-supreme-notification specifically to be the notification system.
    A dedicated notification resource being present is a deliberate choice
    and should take priority over the general-purpose utility lib.
]]

lib = lib or {}
lib.notifications = lib.notifications or {} -- registry, filled by integrations/notifications/<name>/*.lua
lib.notification = {
    name = 'none',
    impl = nil,
    ready = false
}

local NOTIFICATION_LABELS = {
    ox_lib = 'ox_lib (notify)',
    codem = 'codem-supreme-notification',
    none = 'None (falls back to framework Notify)'
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = NOTIFICATION_LABELS[lib.notification.name] or lib.notification.name

    lib.printBanner('rps_lib - notification detection', {
        { 'Resource',      resourceName },
        { 'Side',          side },
        { 'Notifications', label }
    })
end

local function detect()
    local forced = (Config and Config.Notifications) or 'auto'

    if forced ~= 'auto' then
        lib.notification.name = forced
    elseif GetResourceState('codem-supreme-notification') == 'started' then
        lib.notification.name = 'codem'
    elseif GetResourceState('ox_lib') == 'started' then
        lib.notification.name = 'ox_lib'
    else
        lib.notification.name = 'none'
    end

    lib.notification.impl = lib.notifications[lib.notification.name] or lib.notifications.none
    lib.notification.ready = true
    printBanner()
end

-- Wait for ox_lib / codem-supreme-notification to finish starting (if present) before detecting.
CreateThread(function()
    while GetResourceState('ox_lib') == 'starting' or GetResourceState('codem-supreme-notification') == 'starting' do
        Wait(50)
    end
    detect()
end)

--- Returns the selected notification integration name: 'ox_lib' | 'codem' | 'none'
function GetNotificationModuleName()
    return lib.notification.name
end

exports('GetNotificationModuleName', GetNotificationModuleName)
