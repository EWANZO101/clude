fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'RPS Ads Script'
author 'RPS'
version '1.0.0'

shared_script '@ox_lib/init.lua'
shared_script 'config.lua'
client_script 'client.lua'
server_script 'server.lua'

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/index.css',
    'web/dist/index.js'
}

escrow_ignore {
    'config.lua',
    'web/dist/index.html',
    'web/dist/index.css',
    'web/dist/index.js'
}

dependencies {
    '/assetpacks',
    'ox_lib',
    'rps_lib'
}
