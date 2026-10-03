fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-phone'
author 'OpsLab Systems'
description 'OPS OS smartphone for ESX Legacy with its own database'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'client/main.lua',
    'client/calls.lua',
    'client/camera.lua',
    'client/live.lua',
    'client/dev.lua',
    'client/opsnet.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config_server.lua',
    'server/database.lua',
    'server/main.lua',
    'server/calls.lua',
    'server/apps.lua',
    'server/live.lua',
    'server/api_config.lua',
    'server/api.lua',
    'server/dev.lua',
    'server/setup.lua',
    'server/crypto.js',
    'server/oauth.lua',
    'server/media.js',
    'server/media.lua',
    'server/carrier.lua',
    'server/opsnet.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
    'html/js/apps/*.js',
    'html/vendor/inter/*',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*.woff2',
}

dependencies {
    'es_extended',
    'oxmysql',
    'ox_lib',
}
