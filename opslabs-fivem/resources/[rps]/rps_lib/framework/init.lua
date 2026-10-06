--[[
    framework/init.lua
    Detects which framework is running and selects the matching implementation
    from lib.frameworks (populated per-side by framework/<name>/client.lua or
    framework/<name>/server.lua — only one side loads in a given context, so
    there's no conflict).

    Must load BEFORE the other framework/*.lua files in init.lua so that
    lib.frameworks exists for them to register into.

    Which framework is used is controlled by Config.Framework in config.lua:
        Config.Framework = 'auto'        -- auto-detect (default)
        Config.Framework = 'esx'         -- force ESX
        Config.Framework = 'qb'          -- force QBCore
        Config.Framework = 'qbox'        -- force QBox
        Config.Framework = 'standalone'  -- force standalone

    A convar override is also available for quick testing without editing
    config.lua: setr rps_lib:forceFramework "qb" (takes priority over
    config.lua when set to anything other than "auto").
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {} -- registry, filled by the other framework/*.lua files
lib.framework = {
    name = 'standalone',
    impl = nil,
    ready = false
}

local FRAMEWORK_LABELS = {
    esx = 'ESX',
    qb = 'QBCore',
    qbox = 'QBox',
    standalone = 'Standalone'
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = FRAMEWORK_LABELS[lib.framework.name] or lib.framework.name

    lib.printBanner('rps_lib - framework detection', {
        { 'Resource',  resourceName },
        { 'Side',      side },
        { 'Framework', label }
    })
end

local function detect()
    local forced = GetConvar('rps_lib:forceFramework', 'auto')

    if forced == 'auto' then
        forced = (Config and Config.Framework) or 'auto'
    end

    if forced ~= 'auto' then
        lib.framework.name = forced
    elseif GetResourceState('qbx_core') == 'started' then
        lib.framework.name = 'qbox'
    elseif GetResourceState('qb-core') == 'started' then
        lib.framework.name = 'qb'
    elseif GetResourceState('es_extended') == 'started' then
        lib.framework.name = 'esx'
    else
        lib.framework.name = 'standalone'
    end

    lib.framework.impl = lib.frameworks[lib.framework.name] or lib.frameworks.standalone
    lib.framework.ready = true
    printBanner()
end

-- Wait for framework resources to finish starting before detecting.
CreateThread(function()
    while GetResourceState('es_extended') == 'starting'
        or GetResourceState('qb-core') == 'starting'
        or GetResourceState('qbx_core') == 'starting' do
        Wait(50)
    end
    detect()
end)

--- Returns the detected framework name: 'esx' | 'qb' | 'qbox' | 'standalone'
function GetFrameworkName()
    return lib.framework.name
end

exports('GetFrameworkName', GetFrameworkName)
