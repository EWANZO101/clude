fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-bodycam'
author 'OpsLab Systems'
description 'Body worn cameras: records the officer\'s view as video and sends every recording to the Xon Sight evidence portal (live roster on /live), plus the Xon Sight tablet, phone apps (LB Phone, GKSPHONE, 17Movement - also Sky Phone via compatibility aliases) and live sync modules. Standalone or ESX, QBCore, Qbox, ox_core, ND.'
version '1.2.0'

shared_scripts {
    '@opslabs-license/guard.lua',     -- OPSHUB: every player action is checked (opslabs-license)
    'config.lua',
}

client_scripts {
    'client/chestcam.lua',   -- optional: render from a chest-clipped camera while recording (Config.ChestCam)
    'client/main.lua',
    'client/vest.lua',       -- the black vest + the camera you can see on it (opslabs-props models)

    -- modules (settings: config_server.lua → ServerConfig.Modules, shared to clients by modules/server.lua)
    'modules/client.lua',
    'modules/tablet/client.lua',     -- was xonsight-tablet
    'modules/lbphone/client.lua',    -- was xonsight-lbphone; also covers Sky Phone's lb-phone alias
    'modules/gksphone/client.lua',
    'modules/movement/client.lua',   -- also covers Sky Phone's 17mov_Phone alias
}

server_scripts {
    'config_server.lua',      -- every setting, the Xon Sight connection and all modules (was also xonsight-config)
    'server/storage.js',      -- writes video files, uploads them to the portal when there's no self-hosted PublicUrl
    'server/bridge.lua',      -- framework: job, duty, name, items (standalone without one)
    'server/xonsight.lua',    -- Xon Sight evidence webhook + live recorder roster
    'server/audio.lua',       -- voice in the videos through the OPS Voice bridge
    'server/main.lua',
    'server/vest.lua',       -- vest item / command

    -- modules
    'modules/server.lua',
    'modules/evidence.lua',          -- shared phone-app evidence webhook (lbphone/gksphone/movement)
    'modules/lbphone/server.lua',    -- was xonsight-lbphone
    'modules/gksphone/server.lua',
    'modules/movement/server.lua',
    'modules/livesync/server.lua',   -- was xonsight-livesync
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/recorder.js',
    'html/hud.css',
    'html/tablet.js',
    'html/tablet.css',
    'html/app/**/*',        -- shared phone-app viewer/capture UI (lbphone, gksphone, movement all load this)
    'html/lbphone/**/*',
    'html/gksphone/**/*',
    'html/movement/**/*',
}

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
