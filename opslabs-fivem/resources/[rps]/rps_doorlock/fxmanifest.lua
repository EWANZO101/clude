fx_version 'cerulean'
game 'gta5'

author 'RPS'
description 'Door Lock Creator'
version '1.1'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'client/access.lua',
    'client/entitypicker.lua',
    'client/nui.lua',
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/commands.lua',
    'server/callbacks.lua',
    'server/migrate.lua'
}

dependency 'rps_lib'

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js'
}

escrow_ignore {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'config.lua'
}
