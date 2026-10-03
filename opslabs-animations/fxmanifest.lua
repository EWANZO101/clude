fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-animations'
description 'More lifelike climbing, carrying and walking for the OPS Network (opslabs-towers), with ladder, pole and harness sounds'
author 'OpsLabs'
version '1.0.0'

shared_script 'config.lua'
client_script 'client/main.lua'
server_script 'server/main.lua'

ui_page 'html/index.html'
files { 'html/index.html', 'html/sfx/*.wav' }
