Config = {}

-- ACE permission / group allowed to use the /stashcreator command, checked via
-- exports.rps_lib:HasPermission(source, Config.AdminPermission).
-- On QBCore/Qbox this is a real ACE permission string (e.g. add with
-- "add_ace group.admin rps_stashcreator.admin allow" then
-- "add_principal identifier.<id> group.admin" in server.cfg, or grant the
-- permission directly to a group).
-- On ESX this argument is ignored — it just checks admin/superadmin group
-- membership (xPlayer.getGroup()).
Config.AdminPermission = "admin"

-- Identifiers that are also allowed to use the /stashcreator command,
-- regardless of ACE group/permission (fallback allowlist).
Config.Admins = {
    "license:e26d5afe911d9b2e99a146653e109b25e8e20c51",
    "steam:110000100000000",
    -- add your identifiers here
}

-- How players interact with a stash's access points.
--   '3dtext' - walk up, see a floating 3D label, press E to open (default)
--   'target' - uses whatever target/third-eye system rps_lib detects
--              (ox_target / qb-target / tgiann-target) via
--              exports.rps_lib:AddBoxZone instead of 3D text + E
Config.InteractionMode = '3dtext'

-- DrawText3D marker settings (only used when Config.InteractionMode == '3dtext')
Config.Marker = {
    drawDistance = 5.0,  -- distance at which text appears
    interactDistance = 1.5, -- distance to press E
    text = "[~g~E~w~] Open Stash"
}

-- Target zone settings (only used when Config.InteractionMode == 'target')
Config.Target = {
    label = "Open Stash",
    icon = "fas fa-box"
}
