fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-phone'
author 'OpsLab Systems'
description 'Smartphone, laptop and jobs platform (ESX / QBCore / QBox through rps_lib) with its own database'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    '@opslabs-license/guard.lua',     -- OPSHUB: every player action is checked (opslabs-license)
    'shared/opshub.lua',              -- what works while unlicensed (the license screen)
    'config.lua',
    'shared/brand.lua',
}

client_scripts {
    'client/settings.lua',
    'client/brand.lua',
    'client/brandtext.lua',
    'client/main.lua',
    'client/calls.lua',
    'client/camera.lua',
    'client/live.lua',
    'client/dev.lua',
    'client/opsnet.lua',
    'client/laptop.lua',
    'client/battery.lua',
    'client/dock.lua',
    'client/buds.lua',
    'client/safemag.lua',
    'client/pay.lua',
    'client/platform.lua',
    'client/training.lua',
    'client/traffic.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/opsconnect.lua',            -- multi-server: OPS tables → hosted OPS Hub database when connected (opslabs-connect)
    'server/settings.lua',
    'config_server.lua',
    'server/framework.lua',
    'server/database.lua',
    'server/main.lua',
    'server/license.lua',               -- OPSHUB licensing: module gate for every phone call (asks opslabs-license)
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
    'server/platform.lua',
    'server/brand.lua',
    'server/web.lua',
    'server/cloud.lua',
    'server/business.lua',
    'server/market.lua',
    'server/traffic.lua',
    'server/dating.lua',
    'server/training.lua',
    'server/admin.lua',
    'server/laptop.lua',
    'server/battery.lua',
    'server/dock.lua',
    'server/buds.lua',
    'server/safemag.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
    'html/js/apps/*.js',
    'html/img/*.png',
    'html/vendor/inter/*',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*.woff2',
}

dependencies {
    'rps_lib',      -- framework (ESX / QBCore / QBox) through rps_lib
    'oxmysql',
    'ox_lib',
}

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
