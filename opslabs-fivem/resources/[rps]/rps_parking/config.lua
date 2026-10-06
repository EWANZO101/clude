Config = {}

-- Framework (ESX / QBCore / QBox / standalone) and notifications come from rps_lib.
-- To force a framework: setr rps_lib:forceFramework "esx" (or set it in rps_lib's config.lua)

-- General
Config.ParkKey            = 'E'     -- Park when stopped in a free bay (unparking is done at the lot's parking machine)
Config.ParkTime           = 1500    -- ms progress bar when parking / paying at the machine
Config.RequireOwnership   = true    -- Must own the vehicle in the framework DB to park it
Config.MaxParkedPerPlayer = 5
Config.MaxParkSpeed       = 1.0     -- m/s, vehicle must be (almost) stopped
Config.UnparkDistance     = 5.0     -- max distance (server check) for police to ticket / impound a parked car
Config.FreezeParked       = true    -- parked cars can't be pushed / towed by players
Config.MaxParkDays        = 7       -- older parked cars get auto-impounded on server start
Config.RespawnInterval    = 30      -- seconds; respawns parked cars that got deleted
Config.Show3DText         = true    -- "PARKED | PLATE" floating text

-- Parking bays
Config.SpotRadius      = 2.0        -- how close the car's centre must be to the bay centre
Config.SpotMaxAngle    = 40.0       -- max heading difference (reverse parking into a bay is allowed)
Config.SnapToSpot      = true       -- straighten the car into the bay when parked
Config.MarkerDistance  = 30.0       -- show bay markers when this close to a lot (while driving)
Config.MarkerFree      = { r = 60,  g = 200, b = 90,  a = 120 }
Config.MarkerTaken     = { r = 220, g = 60,  b = 60,  a = 120 }
Config.EnableSpotTool  = true       -- /parkspot prints your current car position as a vec4 (F8)

-- Parking machine (prop at each lot). Target it to see your cars parked at that lot, pay and unlock them.
-- Uses your target script via rps_lib (ox_target / qb-target / tgiann-target), or [E] if none is installed.
Config.ParkingMachine = {
    model    = 'prop_park_ticket_01',
    label    = 'Parking Machine',
    icon     = 'fas fa-square-parking',
    distance = 2.0,
}

-- Jobs allowed to ticket & impound parked vehicles
-- Players with these jobs can target a parked car: "Write parking ticket" / "Impound vehicle"
Config.PoliceJobs = { police = true, sheriff = true }
Config.MaxTicket  = 5000   -- max fine per ticket

-- Parking lots are stored in the ParkingLots database table.
-- Create / edit them in-game: /parkadmin -> Lot editor.

-- Impound lot
Config.Impound = {
    fee    = 500,
    coords = vec3(409.25, -1623.08, 29.29),        -- where the player walks to
    spawn  = vec4(401.5, -1631.5, 29.3, 230.0),    -- where the vehicle spawns
    blip   = true,
}

-- Called server-side when a player regains control of a vehicle (unpark / impound retrieve).
Config.GiveKeys = function(src, plate, vehicle)
    if GetResourceState('qb-vehiclekeys') == 'started' then
        TriggerClientEvent('vehiclekeys:client:SetOwner', src, plate)
    elseif GetResourceState('wasabi_carlock') == 'started' then
        exports.wasabi_carlock:GiveKey(src, plate)
    end
end

-- Admin panel (/parkadmin) – includes the lot editor (lots are saved in the ParkingLots table)
Config.Admin = {
    command        = 'parkadmin',
    ace            = 'rps_parking.admin',  -- add_ace group.admin rps_parking.admin allow
    frameworkAdmin = true,                 -- also allow QB 'admin'/'god' and ESX 'admin'/'superadmin'
    ghostModel     = 'sultan',             -- lot editor: ghost car used to place bays (your current car's model is used if you're in one)
    bayMinGap      = 2.2,                  -- lot editor: metres; bays closer than this to another bay can't be placed
}

-- Activity logs (stored in the parking_logs table)
Config.Logs = {
    retentionDays = 30,     -- older log rows are deleted on server start (0 = keep forever)
    webhook = '',           -- optional Discord webhook URL
    webhookActions = {      -- which actions are also sent to Discord
        park = false, unpark = true, ticket = true, impound = true,
        retrieve = true, expire = true, admin = true,
    },
}
