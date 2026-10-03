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
}

client_scripts {
    'client/main.lua',
    'client/cabling.lua',
    'client/poles.lua',
    'client/ladders.lua',
    'client/ont.lua',
}

ui_page 'html/index.html'
files { 'html/index.html' }
