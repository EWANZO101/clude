--[[
    integrations/garages/init.lua
    Selects which garage integration to use, mirroring how framework/init.lua
    picks the framework module. Waits for framework detection to finish first
    since 'auto' mode picks based on the detected framework.

    Controlled by Config.Garage in config.lua:
        Config.Garage = 'auto'        -- pick automatically based on framework (default)
        Config.Garage = 'qb-garage'   -- force the QBCore-style integration (player_vehicles table)
        Config.Garage = 'qbox-garage' -- force the QBox-style integration (qbx_vehicles/qbx_garages exports)
        Config.Garage = 'esx-garage'  -- force the ESX-style integration (owned_vehicles table)
        Config.Garage = 'none'        -- no garage integration
]]

lib = lib or {}
lib.garages = lib.garages or {} -- registry, filled by integrations/garages/<name>/*.lua
lib.garage = {
    name = 'none',
    impl = nil,
    ready = false
}

local GARAGE_LABELS = {
    ['qb-garage'] = 'QB-Garage (player_vehicles)',
    ['qbox-garage'] = 'QBox-Garage (qbx_vehicles/qbx_garages)',
    ['esx-garage'] = 'ESX-Garage (owned_vehicles)',
    none = 'None'
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = GARAGE_LABELS[lib.garage.name] or lib.garage.name

    lib.printBanner('rps_lib - garage detection', {
        { 'Resource', resourceName },
        { 'Side',     side },
        { 'Garage',   label }
    })
end

local function detect()
    local forced = (Config and Config.Garage) or 'auto'

    if forced ~= 'auto' then
        lib.garage.name = forced
    elseif lib.framework.name == 'qbox' then
        lib.garage.name = 'qbox-garage'
    elseif lib.framework.name == 'qb' then
        lib.garage.name = 'qb-garage'
    elseif lib.framework.name == 'esx' then
        lib.garage.name = 'esx-garage'
    else
        lib.garage.name = 'none'
    end

    lib.garage.impl = lib.garages[lib.garage.name] or lib.garages.none
    lib.garage.ready = true
    printBanner()
end

-- Framework detection must finish first (auto mode depends on lib.framework.name).
CreateThread(function()
    while not (lib.framework and lib.framework.ready) do
        Wait(50)
    end
    detect()
end)

--- Returns the selected garage integration name: 'qb-garage' | 'esx-garage' | 'none'
function GetGarageName()
    return lib.garage.name
end

exports('GetGarageName', GetGarageName)
