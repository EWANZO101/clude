--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]


fx_version 'cerulean'

game 'gta5'

lua54 'yes'

name 'rps_bossmenu'

author 'Realplay Scrips'

description 'Boss Menu Because Yes'

version '2.0.5'

provide 'qb-management'
provide 'esx_society'

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]


shared_scripts {
    'config.lua'
}

client_scripts {
    'client/bridge.lua',
    'client/main.lua',
    'client/bossmenu.lua',
    'client/admin.lua',
    'client/billing.lua',
    'client/delivery.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bridge.lua',
    'server/main.lua',
    'server/bossmenu.lua',
    'server/admin.lua',
    'server/billing.lua',
    'server/delivery.lua'
}

ui_page 'ui/dist/index.html'

files {
    'ui/dist/index.html',
    'ui/dist/assets/*.css',
    'ui/dist/assets/*.js',
    'ui/dist/assets/*.png',
    'ui/dist/logos/*.png',
    'ui/dist/assets/*.jpg',
    'ui/dist/assets/*.svg',
    'ui/dist/assets/*.woff2',
    'ui/dist/assets/*.ttf'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]


dependency {
    'rps_lib'
}

escrow_ignore {
    'config.lua',
    'ui/**/*'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]
