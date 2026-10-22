fx_version 'cerulean'
game 'gta5'

author 'customer2 ops'
description 'Small admin command gap-fill: /giveweapon, disabled server-wide by Config.CustomInventory since this server runs ox_inventory.'
version '1.0.0'

shared_script '@opslabs-license/guard.lua'   -- OPSHUB: every player action is checked (opslabs-license)

server_script 'server.lua'

dependencies {
    'rps_lib',
}

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
