
--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]


fx_version 'cerulean'

game 'gta5'

lua54 'yes'

name 'rps_parking'

author 'Realplay Scripts'

description 'Advanced persistent real-world parking: fees, fines, impound, auto-respawn'

version '1.0.0'

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/lots.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/lots.lua',
    'client/main.lua',
    'client/admin.lua',
    'client/editor.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server.lua',
    'server/main.lua',
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

escrow_ignore {
    'config.lua',
}

dependencies {
    '/onesync',
    'ox_lib',
    'oxmysql',
    'rps_lib',
}