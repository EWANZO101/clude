-- Multi-server OPS (/new-hub): if opslabs-connect is installed and this server has a token, OPS tables go to the
-- server's hosted database on the OPS Hub (see opslabs-connect/lib/db.lua). Without it nothing changes.
local code = GetResourceState('opslabs-connect') ~= 'missing' and LoadResourceFile('opslabs-connect', 'lib/db.lua')
if code then
    local chunk, err = load(code, '@opslabs-connect/lib/db.lua')
    if chunk then chunk() else print('^1[' .. GetCurrentResourceName() .. '] opslabs-connect/lib/db.lua: ' .. tostring(err) .. '^7') end
end
