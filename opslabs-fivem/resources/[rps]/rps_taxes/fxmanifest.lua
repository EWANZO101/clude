fx_version 'cerulean'
game 'gta5'

name 'rps_taxes'
author 'real play scripts'
version '1.1.0'
description 'Tax system - Bank and Vehicle Taxes (ESX / QBCore / QBox, phone, banking and notifications via rps_lib)'

lua54 'yes'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/utils.lua',
    'server/bridge.lua',
    'server/webhooks.lua',
    'server/main.lua'
}

escrow_ignore {
    'config.lua',
    'server/*.lua'
}

dependencies {
    'rps_lib',
    'ox_lib',
    'oxmysql'
}
