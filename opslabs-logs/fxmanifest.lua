fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-logs'
description 'Organizes, dedupes and summarizes FXServer console/resource logs: live web dashboard, Discord alerts on new errors, in-game /serverlog. Works with any resource (Lua or JS) — no per-script integration needed.'
author 'OpsLabs'
version '1.0.0'

shared_script 'config.lua'

server_scripts {
    '@opslabs-license/guard.lua',   -- OPSHUB: /serverlog and the dashboard only work while this module is licensed
    'server/main.lua',
    'server/logtail.js',
}

files {
    'web/dashboard.html',
}
