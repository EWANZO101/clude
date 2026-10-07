fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-license'
author 'OpsLab Systems'
description 'OPSHUB licensing: activates this server, verifies its signed license and runs only the OPS modules it is entitled to'
version '1.0.0'

shared_script 'config.lua'

server_scripts {
    'server/verify.js',
    'server/main.lua',
}
