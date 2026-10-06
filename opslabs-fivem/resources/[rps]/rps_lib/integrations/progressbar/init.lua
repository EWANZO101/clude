--[[
    integrations/progressbar/init.lua
    Selects which progress bar integration to use, mirroring how
    integrations/garages/init.lua picks the garage module. Unlike garages,
    selection is based on whether ox_lib is running, not on the detected
    framework.

    Controlled by Config.ProgressBar in config.lua:
        Config.ProgressBar = 'auto'   -- auto-detect ox_lib, else none (default)
        Config.ProgressBar = 'ox_lib' -- force the ox_lib integration
        Config.ProgressBar = 'none'   -- no progress bar (calls resolve instantly)
]]

lib = lib or {}
lib.progressbars = lib.progressbars or {} -- registry, filled by integrations/progressbar/<name>/*.lua
lib.progressbar = {
    name = 'none',
    impl = nil,
    ready = false
}

local PROGRESSBAR_LABELS = {
    ox_lib = 'ox_lib (progressBar)',
    none = 'None'
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = PROGRESSBAR_LABELS[lib.progressbar.name] or lib.progressbar.name

    lib.printBanner('rps_lib - progress bar detection', {
        { 'Resource',     resourceName },
        { 'Side',         side },
        { 'Progress bar', label }
    })
end

local function detect()
    local forced = (Config and Config.ProgressBar) or 'auto'

    if forced ~= 'auto' then
        lib.progressbar.name = forced
    elseif GetResourceState('ox_lib') == 'started' then
        lib.progressbar.name = 'ox_lib'
    else
        lib.progressbar.name = 'none'
    end

    lib.progressbar.impl = lib.progressbars[lib.progressbar.name] or lib.progressbars.none
    lib.progressbar.ready = true
    printBanner()
end

-- Wait for ox_lib to finish starting (if present) before detecting.
CreateThread(function()
    while GetResourceState('ox_lib') == 'starting' do
        Wait(50)
    end
    detect()
end)

--- Returns the selected progress bar integration name: 'ox_lib' | 'none'
function GetProgressBarName()
    return lib.progressbar.name
end

exports('GetProgressBarName', GetProgressBarName)
