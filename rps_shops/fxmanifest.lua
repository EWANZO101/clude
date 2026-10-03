fx_version 'cerulean'
game 'gta5'

author 'Traps'
description 'rps_shops - 24/7 Supermarket, LTD Gasoline, YouTool and Digital Den in one resource (ESX / QBCore / QBox, inventory, target and notifications via rps_lib)'
version '2.0.0'

lua54 'yes'

ui_page 'web/index.html'

shared_scripts {
    '@ox_lib/init.lua',
    'config/shared.lua',
    'config/brands/*.lua',
    'shared/init.lua'
}

client_scripts {
    'bridge/client.lua',
    'client/main.lua'
}

server_scripts {
    'bridge/server.lua',
    'server/main.lua'
}

files {
    'web/index.html',
    'web/loader.js',
    'web/themes/**/*'
}

dependencies {
    'ox_lib',
    'rps_lib'
}
