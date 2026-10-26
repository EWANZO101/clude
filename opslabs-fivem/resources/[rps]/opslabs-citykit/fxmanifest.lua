fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-citykit'
description 'Outdoor dressing kit: roads, concrete, fences, gates, lighting and more for custom maps / MLOs'
author 'OpsLabs'
version '1.0.0'

dependencies { 'oxmysql', 'ox_lib', 'rps_lib' }   -- framework (ESX / QBCore / QBox) through rps_lib

shared_scripts {
    '@ox_lib/init.lua',
    '@opslabs-license/guard.lua',   -- OPSHUB: every player action is checked (opslabs-license) — grant this resource a module before use
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/opsconnect.lua',
    'server/framework.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}
