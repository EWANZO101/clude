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
