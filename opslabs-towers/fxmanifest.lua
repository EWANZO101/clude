fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-towers'
description 'Cell towers and Wi-Fi access points for opslabs-phone (OPS Mobile coverage)'
author 'OpsLabs'
version '1.0.0'

dependencies { 'oxmysql', 'ox_lib', 'es_extended' }

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/api.lua',
    'server/cabling.lua',
    'server/isp.lua',
    'server/ladders.lua',
    'server/doors.lua',
    'server/tools.lua',
    'server/uniform.lua',
    'server/faults.lua',
    'server/guys.lua',
}

client_scripts {
    'client/menu.lua',
    'client/main.lua',
    'client/worldpoles.lua',
    'client/cabling.lua',
    'client/poles.lua',
    'client/ladders.lua',
    'client/ont.lua',
    'client/roadworks.lua',
    'client/lighting.lua',
    'client/faults.lua',
    'client/harness.lua',
    'client/guys.lua',
    'client/coach.lua',
    'client/doors.lua',
    'client/van.lua',
    'client/tools.lua',
    'client/anticlimb.lua',
    'client/uniform.lua',
}

ui_page 'html/index.html'
files { 'html/index.html', 'html/sign.html', 'html/brand.html', 'html/fencesign.html' }
