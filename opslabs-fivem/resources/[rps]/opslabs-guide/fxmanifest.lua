fx_version 'cerulean'
game 'gta5'
lua54 'yes'
shared_script '@opslabs-license/guard.lua'   -- OPSHUB: every player action is checked (opslabs-license)

name 'opslabs-guide'
description 'In-game /guide: animated step-by-step guide to OPS Mobile, towers, cabling, poles, ladders, internet service and road safety'
author 'OpsLabs'
version '1.0.0'

client_script 'client.lua'

ui_page 'html/index.html'
files { 'html/index.html', 'html/guide.js', 'html/guide.css' }

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
