Config = {}

-- Identifiers that are allowed to use the /doorscreator and /migratedoors commands
Config.Admins = {
    "license:1144e0f3d8f7ccaa719f85be2d991f49d9f6c74d",
    -- add your identifiers here
}

-- ACE groups (server.cfg `add_principal identifier.xxx group.<name>`) that are
-- also allowed to use the /doorscreator and /migratedoors commands, on top of
-- the raw identifiers above. Checked via IsPlayerAceAllowed(source, "group.<name>"),
-- which requires server.cfg to grant each group that same-named ace
-- (e.g. `add_ace group.admin group.admin allow`) — plain group membership via
-- add_principal alone isn't enough for the native to see it.
Config.AdminGroups = { "admin", "superadmin", "god" }

Config.Command = 'doorscreator'
Config.MigrateCommand = 'migratedoors'

-- Distance at which the lock/unlock options show
Config.InteractDistance = 4.0
-- Distance at which the door starts checking for state and rendering the locked/unlocked sprite
Config.DrawDistance = 15.0

-- How long (in seconds) the door stays unlocked if successfully lockpicked
Config.LockpickTempUnlockTime = 600 -- 10 minutes

-- Item required to lockpick the door via third eye (target via rps_lib)
Config.LockpickItem = "lockpick"

-- Max failures allowed for minigames that require it (like lockpick)
Config.MaxFailures = 1

-- The resource name for the glitch-minigames script (folder name in your resources)
Config.MinigameResource = 'glitch-minigames'

Config.InteractText = '[E] Lock/Unlock'
