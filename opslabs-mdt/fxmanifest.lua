fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-mdt'
author 'OpsLab Systems'
description 'Portable in-car MDT: an opslabs_laptop that mounts in any vehicle and logs each officer into their own SnailyCAD account. Standalone or ESX, QBCore, Qbox, ox_core, ND.'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    '@opslabs-license/guard.lua',     -- OPSHUB: every player action is checked (opslabs-license)
    'config.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bridge.lua',     -- framework: job, duty, name (standalone without one)
    'server/cad.lua',        -- the SnailyCAD API client: global token for reference data, each officer's own
                              -- personal CAD token for everything they do (search, BOLOs, citations, warrants)
    'server/install.lua',    -- which vehicle (by plate) has the laptop mounted right now
    'server/mounts.lua',     -- per-model dash offsets, calibrated in-game with /mdtmount
    'server/main.lua',
    'server/actions.lua',    -- every NUI screen's callback
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
}

dependencies { 'oxmysql', 'ox_lib', 'rps_lib' }   -- framework (ESX / QBCore / QBox) through rps_lib
dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
