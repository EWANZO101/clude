-- OPSHUB guard (opslabs-license/guard.lua) settings for OPS Phone: what still works while the server isn't licensed —
-- just enough to start, run its own setup and show the OPSHUB license screen so an admin can enter the key.
-- Every other phone action is checked by the guard, and per app by server/license.lua.
OPSHUB_OPEN = OPSHUB_OPEN or {}
for _, name in ipairs({
    -- server callbacks (the phone's NUI calls arrive as opslabs-phone:<name>)
    'opslabs-phone:init', 'opslabs-phone:setupInfo', 'opslabs-phone:setupCheck', 'opslabs-phone:completeSetup',
    'opslabs-phone:saveSettings', 'opslabs-phone:licenseState', 'opslabs-phone:licenseActivate',
    -- client NUI plumbing (rpc relays to the callbacks above, which are checked on the server)
    'rpc', 'close', 'inputFocus', 'getWorld', 'getLocation', 'notifyGame',
}) do OPSHUB_OPEN[name] = true end
-- what a refused call returns: the phone shows "not included in this server's OPSHUB license"
OPSHUB_DENIED = { __license = 'phone' }
