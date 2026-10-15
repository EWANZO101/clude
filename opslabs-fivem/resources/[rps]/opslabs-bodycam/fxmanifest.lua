fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-bodycam'
author 'OpsLab Systems'
description 'Body worn cameras: records the officer\'s view as video and sends every recording to the Xon Sight evidence portal (live roster on /live). Standalone or ESX, QBCore, Qbox, ox_core, ND.'
version '1.0.0'

shared_script 'config.lua'

client_scripts {
    'client/main.lua',
    'client/vest.lua',       -- the black vest + the camera you can see on it (opslabs-props models)
}

server_scripts {
    'config_server.lua',
    'server/storage.js',      -- writes the video files, serves them over HTTP when nginx doesn't
    'server/bridge.lua',      -- framework: job, duty, name, items (standalone without one)
    'server/xonsight.lua',    -- Xon Sight evidence webhook + live recorder roster
    'server/audio.lua',       -- voice in the videos through the OPS Voice bridge
    'server/main.lua',
    'server/vest.lua',       -- vest item / command
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/recorder.js',
    'html/hud.css',
}
