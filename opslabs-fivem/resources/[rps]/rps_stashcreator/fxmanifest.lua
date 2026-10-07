
--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

fx_version 'cerulean'

game 'gta5'

lua54 'yes'
shared_script '@opslabs-license/guard.lua'   -- OPSHUB: every player action is checked (opslabs-license)

name 'rps_stashcreator'

author 'Realplay Scrips'

description 'Stash Creator UI'

version     '1.0.1'

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/client.lua'
}

server_scripts {
    'server/server.lua'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

dependency {
    'rps_lib'
}

escrow_ignore {
    'web/index.html',
    'web/style.css',
    'web/app.js', 
    'config.lua'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
