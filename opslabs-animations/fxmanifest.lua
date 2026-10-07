fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-animations'
description 'More lifelike climbing, carrying and walking for the OPS Network (opslabs-towers)'
author 'OpsLabs'
version '1.1.0'

dependency 'ox_lib'
shared_scripts { '@ox_lib/init.lua', '@opslabs-license/guard.lua', 'config.lua' }   -- guard: OPSHUB checks every player action
client_script 'client/main.lua'

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
