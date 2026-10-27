fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-license'
author 'OpsLab Systems'
description 'OPSHUB licensing: activates this server, verifies its signed license and runs only the OPS modules it is entitled to'
version '1.3.0'

shared_script 'config.lua'

server_scripts {
    'server/verify.js',
    'server/main.lua',
}

-- the guard every OPS / rps resource loads ('@opslabs-license/guard.lua' in its fxmanifest). The rest
-- are read via LoadResourceFile + load(), not auto-run as scripts - server/installer.lua returns a
-- function main.lua calls itself, and the two vendored libs return a module table the same way
-- (see server/installer.lua's own comment on why - plain script loading discards a file's `return`).
files { 'guard.lua', 'server/installer.lua', 'libs/LibDeflate.lua', 'libs/sha2.lua' }
