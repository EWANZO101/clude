-- Server-only settings. This file is NOT sent to players (unlike config.lua),
-- so secrets such as the Developer app login are safe here.

ServerConfig = {}

-- Spotify / TIDAL sign-in (players connect their own accounts in the music apps).
-- 1. PublicUrl: an https address that reaches this server's port 30120, e.g. the
--    cfx.re address txAdmin shows (https://yourname-abc123.users.cfx.re) or your
--    own domain behind an https reverse proxy. No trailing slash.
-- 2. Register a developer app and add this Redirect URI to it:
--      <PublicUrl>/opslabs-phone/oauth/spotify/callback   (developer.spotify.com)
--      <PublicUrl>/opslabs-phone/oauth/tidal/callback     (developer.tidal.com)
-- 3. Paste the app's Client ID / Secret below and restart the resource.
ServerConfig.OAuth = {
    PublicUrl = 'https://ops-phone.opslabsystems.cloud',
    Spotify = {
        ClientId = '',
        ClientSecret = '',
        Scopes = 'user-read-private user-read-email user-library-read playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-recently-played',
    },
    Tidal = {
        ClientId = '',
        ClientSecret = '',
        Scopes = 'user.read collection.read playlists.read search.read',
        CountryCode = 'US',
    },
}

-- Login for the Developer app (on every phone, but locked behind this login).
ServerConfig.DevLogin = {
    Email = 'opsphone@ops.com',
    Password = 'change-me',

    -- brute-force protection: after this many wrong attempts the player has to wait
    MaxAttempts = 5,
    LockoutSeconds = 60,
}

-- Ops-Networks engineer app (accounts, jobs, faults, pay). Accounts live in the
-- opslabs_phone_opsnet_users table with scrypt-hashed passwords.
ServerConfig.OpsNet = {
    -- seeded once, on first start, when no administrator account exists yet.
    -- Change the password in the app afterwards (the app warns while it is still this one).
    Admin = { Username = 'admin', Password = 'admin' },

    -- login brute-force protection (per player)
    MaxAttempts = 5,
    LockoutSeconds = 60,

    AllowSignup = true,          -- players can request an account (no permissions until an admin grants them)
    PlannedRadius = 30.0,        -- metres: an engineer must be this close to complete planned work
    MaxPlannedPay = 25000,       -- cap for the pay of a single planned-work job

    -- Engineer pay. Overridable live from the Developer app and the Ops-Networks
    -- admin panel (saved in opslabs_phone_kv, key opsnet_pay).
    Pay = {
        Account = 'bank',        -- ESX account the pay goes into
        Default = 500,           -- fault types / severities not listed below
        BySeverity = { low = 400, medium = 700, high = 1100, critical = 1600 },
        -- per fault type (catalogue id); 0 / missing = use the severity rate
        ByType = {
            pole_lean = 0, pole_rot = 0, fibre_break = 0, dropwire_down = 0, cbt_water = 0,
            splice_loss = 0, ont_failure = 0, cabinet_power = 0, olt_card = 0, tower_power = 0,
        },
        Planned = 600,           -- default pay for planned work (the creator can change it per job)
        Bonus = { Enabled = true, Hours = 2, Amount = 250 }, -- extra pay for fixing a fault within N hours of it opening
    },
}
