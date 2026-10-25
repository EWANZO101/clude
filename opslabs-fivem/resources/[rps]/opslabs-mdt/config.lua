Config = {}

-- print every install/remove/prop/mount/CAD-call step to the server and client consoles ([opslabs-mdt] dbg).
-- Turn this off once things are working - it's chatty by design for tracking down exactly where something
-- isn't doing what's expected. Shared (config.lua loads on both sides), so Dbg(...) works everywhere.
Config.Debug = true
function Dbg(fmt, ...)
    if not Config.Debug then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print('^5[opslabs-mdt] dbg: ' .. (ok and msg or fmt) .. '^7')
end

-- who can install / carry an MDT at all (a coarse, game-side check). "On duty" is deliberately not checked
-- here: that's the CAD's own job, not the game's - opening the laptop checks the officer has an active unit
-- in the CAD right now (server/actions.lua), which is the real, authoritative duty signal for a CAD client.
--   Mode: 'job' | 'item' | 'job_and_item' | 'job_or_item' | 'ace' | 'everyone'
Config.Access = {
    Ace = 'opslabs.mdt',             -- always allowed, any mode
    Mode = 'job',
    Jobs = { police = 0 },           -- job -> minimum grade
    Item = '',                       -- only used by 'item' / '*_and_item' / '*_or_item' modes
}

Config.Item = 'mdt_laptop'           -- ox_inventory item: see README for the entry to add
Config.Prop = 'opslabs_laptop'       -- opslabs-props model, same as the field-engineer laptop
Config.UseDistance = 1.5             -- how close to an installed laptop before [E] shows
Config.InstallDistance = 2.0         -- how close to the vehicle to install / remove it

--- the view while the MDT is open: a camera attached to the laptop prop itself (so it's correct even if the
--- vehicle is moving), offset from the prop by this much and pointed at this point on it, both in the prop's
--- own local space. Best-effort defaults - tune alongside Config.Mounts once that's dialed in.
Config.ViewCam = { x = 0.0, y = -0.4, z = 0.3 }
Config.ViewCamTarget = { x = 0.0, y = 0.05, z = 0.05 }

--- where the laptop sits in the car: bone 0 (the chassis) plus this offset/rotation, in metres/degrees.
--- "any car" has no common dashboard bone, so this is one best-effort default, overridable per model.
--- (the old z=0.65 put it up at windshield-header/mirror height instead of on the dash - confirmed from an
--- actual in-game screenshot - this is lower and further back on the dash as a saner starting point)
Config.DefaultMount = { x = 0.0, y = 0.15, z = 0.35, rx = -15.0, ry = 0.0, rz = 0.0 }
Config.Mounts = {
    -- police3 = { x = 0.05, y = 0.25, z = 0.68, rx = -5.0, ry = 0.0, rz = 90.0 },
}

--- SnailyCAD connection: reuses whatever snailycad-framework / snailycad-radio already has configured
--- (set snailycad_framework_api_url / snailycad_radio_api_url in server.cfg) - nothing to set up twice.
--- The officer's own personal "User API Token" (CAD: Account Settings > API Tokens) is what every search,
--- BOLO, citation and warrant acts as; a server-wide token (same one those resources use) is only ever used
--- for read-only reference data (penal codes) that an ordinary officer's token usually can't read itself.
Config.Cad = {
    RequestTimeoutMs = 10000,
}

-- violation list offered when writing a citation, read from the CAD's own penal codes at runtime; this is
-- just the page size for that picker
Config.PenalCodesPageSize = 200
