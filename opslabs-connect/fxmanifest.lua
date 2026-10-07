fx_version 'cerulean'
game 'gta5'
lua54 'yes'
shared_script '@opslabs-license/guard.lua'   -- OPSHUB: every player action is checked (opslabs-license)

name 'opslabs-connect'
author 'OpsLabs'
description 'Connects this server to the OPS Hub (/new-hub): server token or Dev App pairing, hosted OPS database, heartbeat'
version '1.0.0'

-- Start BEFORE opslabs-towers and opslabs-phone (they include lib/db.lua):
--   set ops_api_url "https://opsphone-store.opslabsystems.cloud"
--   set ops_server_token "opsk_…"          (or pair from the Dev App — the token is then kept in this resource's KVP)
--   ensure opslabs-connect
-- Without a token nothing changes: OPS keeps using your local oxmysql database (self-hosted / single server).

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/connect.lua',
}

dependencies { 'oxmysql' }

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
