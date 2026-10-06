fx_version 'cerulean'
game 'gta5'

name 'rps_bossmenu_phone'
author 'Realplay Scrips'
description 'LB Phone app: manage rps_bossmenu employees on the go'
version '1.0.1'

-- This resource has no business logic of its own — every action just
-- forwards to rps_bossmenu's existing server events/callbacks, so both
-- the physical tablet and this phone app always stay in sync.
dependencies {
    'rps_lib',
    'rps_bossmenu'
}

shared_script 'config.lua'

client_scripts {
    'client/client.lua',
    'client/nui.lua'
}

-- Production: serve the built UI.
ui_page 'ui/dist/index.html'
-- Development: comment the line above and uncomment this one instead,
-- then run `npm run dev` inside ui/ (see ui/README.md).
-- ui_page 'http://localhost:3000/'

files {
    'ui/dist/index.html',
    'ui/dist/**/*'
}
