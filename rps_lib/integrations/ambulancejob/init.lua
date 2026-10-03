--[[
    integrations/ambulancejob/init.lua
    Selects which ambulance/EMS job integration to use, mirroring how
    integrations/garages/init.lua picks the garage module — selection is
    based on the detected framework, same as garages.

    Controlled by Config.Ambulance in config.lua:
        Config.Ambulance = 'auto'             -- pick automatically based on framework (default)
        Config.Ambulance = 'esx_ambulancejob'  -- force integrations/ambulancejob/esx_ambulancejob
        Config.Ambulance = 'qb-ambulancejob'   -- force integrations/ambulancejob/qb-ambulancejob
        Config.Ambulance = 'qbx_ambulancejob'  -- force integrations/ambulancejob/qbx_ambulancejob
        Config.Ambulance = 'none'              -- no ambulance job integration
]]

lib = lib or {}
lib.ambulances = lib.ambulances or {} -- registry, filled by integrations/ambulancejob/<name>/*.lua
lib.ambulance = {
    name = 'none',
    impl = nil,
    ready = false
}

local AMBULANCE_LABELS = {
    esx_ambulancejob = 'esx_ambulancejob',
    ['qb-ambulancejob'] = 'qb-ambulancejob',
    qbx_ambulancejob = 'qbx_ambulancejob (Qbox)',
    none = 'None'
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = AMBULANCE_LABELS[lib.ambulance.name] or lib.ambulance.name

    lib.printBanner('rps_lib - ambulance job detection', {
        { 'Resource', resourceName },
        { 'Side',     side },
        { 'Ambulance', label }
    })
end

local function detect()
    local forced = (Config and Config.Ambulance) or 'auto'

    if forced ~= 'auto' then
        lib.ambulance.name = forced
    elseif lib.framework.name == 'qbox' then
        lib.ambulance.name = 'qbx_ambulancejob'
    elseif lib.framework.name == 'qb' then
        lib.ambulance.name = 'qb-ambulancejob'
    elseif lib.framework.name == 'esx' then
        lib.ambulance.name = 'esx_ambulancejob'
    else
        lib.ambulance.name = 'none'
    end

    lib.ambulance.impl = lib.ambulances[lib.ambulance.name] or lib.ambulances.none
    lib.ambulance.ready = true
    printBanner()
end

-- Framework detection must finish first (auto mode depends on lib.framework.name).
CreateThread(function()
    while not (lib.framework and lib.framework.ready) do
        Wait(50)
    end
    detect()
end)

--- Returns the selected ambulance job integration name:
--- 'esx_ambulancejob' | 'qb-ambulancejob' | 'qbx_ambulancejob' | 'none'
function GetAmbulanceJobName()
    return lib.ambulance.name
end

exports('GetAmbulanceJobName', GetAmbulanceJobName)
