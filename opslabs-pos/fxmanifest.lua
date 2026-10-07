fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-pos'
author 'OpsLab Systems'
description 'OPS POS Systems: tills for stores on OPS kit (terminal, card reader, scanner, printer, cash drawer, customer display)'
version '1.0.0'

dependencies { 'ox_lib', 'oxmysql', 'opslabs-towers' }

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
    'server/framework.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/pos.css',
    'html/pos.js',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*',
}

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
