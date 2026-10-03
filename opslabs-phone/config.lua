Config = {}

-- Key / command used to open the phone. Players can rebind it in
-- Settings -> Key Bindings -> FiveM.
Config.Keybind = 'F1'
Config.Command = 'phone'

-- Require a phone item in the inventory to open the phone.
Config.RequireItem = true

-- Item name -> frame colour (key into Config.FrameColors). The first item the
-- player owns decides the colour of the phone.
Config.Items = {
    phone        = 'black',
    phone_black  = 'black',
    phone_blue   = 'ultramarine',
    phone_green  = 'teal',
    phone_pink   = 'pink',
    phone_red    = 'red',
    phone_yellow = 'yellow',
    phone_orange = 'orange',
    phone_purple = 'purple',
}

-- Aluminium frame finishes (plus a few extras for the coloured items).
Config.FrameColors = {
    black       = '#3c3d3a',
    white       = '#f2f1ed',
    pink        = '#f2adda',
    teal        = '#a6d8d0',
    ultramarine = '#9aadf6',
    red         = '#b8202e',
    yellow      = '#f5e07a',
    orange      = '#f0a765',
    purple      = '#c5b3e6',
}

-- Phone numbers: every X becomes a random digit.
Config.NumberFormat = '555-XXXX'

-- Email domain for the Mail app (name@domain, e.g. example@opslabs.cloud).
-- Default; can also be changed in-game from the Developer app.
Config.MailDomain = 'opslabs.cloud'

-- Default units & formats for new phones. Every player can change each one in
-- Setup or Settings → Units & Formats, independent of their language.
Config.DefaultUnits = {
    temp     = 'F',    -- 'F' or 'C'
    distance = 'mi',   -- 'mi' or 'km'
    speed    = 'mph',  -- 'mph' or 'kmh'
    weight   = 'lb',   -- 'lb', 'kg' or 'st' (stone)
    clock    = '12',   -- '12' or '24'
    date     = 'MDY',  -- 'MDY' (10/02/2026), 'DMY' (02/10/2026) or 'YMD' (2026-10-02)
    week     = 'sun',  -- first day of the week: 'sun' or 'mon'
}

-- Prop + animations while the phone is open.
Config.Prop = `prop_npc_phone_02`
Config.DisableControlsWhileOpen = true

-- Calls
Config.Calls = {
    RingTimeout = 30,     -- seconds before an unanswered call becomes "missed"
    UsePmaVoice = true,   -- route call audio through pma-voice
}

-- Developer app (map locations, blips, wallpapers, numbers, broadcast) is on
-- every phone but needs a login. The email/password live in config_server.lua
-- (server-only, so players can't read them from their game cache).

-- Music apps (in the OPS OS Store). They play direct audio links (mp3/ogg/aac),
-- internet radio streams and YouTube links. Audio is heard by the player only.
-- Rename the apps here if you like.
Config.Music = {
    Apps = {
        soundwave = { name = 'Soundwave' },   -- green, Spotify-style look
        tide      = { name = 'Tide' },        -- black & white, TIDAL-style look
    },
    -- Radio stations everyone gets. SomaFM is free, listener-supported internet radio.
    Stations = {
        { title = 'Groove Salad',   artist = 'SomaFM · Ambient / Downtempo', url = 'https://ice1.somafm.com/groovesalad-128-mp3' },
        { title = 'Beat Blender',   artist = 'SomaFM · Deep House',          url = 'https://ice1.somafm.com/beatblender-128-mp3' },
        { title = 'Indie Pop Rocks!', artist = 'SomaFM · Indie Pop',         url = 'https://ice1.somafm.com/indiepop-128-mp3' },
        { title = 'Fluid',          artist = 'SomaFM · Instrumental Hip-Hop', url = 'https://ice1.somafm.com/fluid-128-mp3' },
        { title = 'Secret Agent',   artist = 'SomaFM · Lounge',              url = 'https://ice1.somafm.com/secretagent-128-mp3' },
        { title = 'DEF CON Radio',  artist = 'SomaFM · Electronic',          url = 'https://ice1.somafm.com/defcon-128-mp3' },
        { title = 'Lush',           artist = 'SomaFM · Vocal Chill',         url = 'https://ice1.somafm.com/lush-128-mp3' },
        { title = 'Left Coast 70s', artist = 'SomaFM · 70s Rock',            url = 'https://ice1.somafm.com/seventies-128-mp3' },
    },
}

-- Live location sharing (Messages / Maps / Contacts)
Config.LiveLocation = {
    Interval = 2000,              -- ms between position updates from the sharer
    Durations = { 15, 60, 0 },    -- minutes offered to the player (0 = until stopped)
    BlipSprite = 280,             -- person blip
    BlipColour = 2,               -- green
}

-- Bank app (uses the ESX "bank" account)
Config.Bank = {
    Account = 'bank',
    MaxTransfer = 1000000,
    TransferCooldown = 5, -- seconds
}

-- Mobile carrier (eSIM plans). Players buy a plan on the store website
-- (opsphone-store) and install the eSIM on their phone; texting, calling and
-- online apps then use the plan's allowance. Everything here can also be
-- changed live from the store's admin panel (saved in the database).
Config.Carrier = {
    Enabled = true,              -- false: every phone has unlimited service, no plans needed
    Name = 'OPS Mobile',         -- shown in the status bar, Control Center and Settings
    Number = '6677',             -- texts from the carrier (sign-in codes, receipts) come from here
    StoreUrl = 'https://opsphone-store.opslabsystems.cloud',
    StarterPlan = 'starter',     -- phones without a line get this free plan once (false = none)
    Society = false,             -- e.g. 'society_opsmobile': plan payments go to this society account
    -- data used per online action, in KB (counts against the plan's data)
    DataCost = {
        chirpFeed = 400, chirpPost = 150, chirpLike = 5, chirpProfile = 60, chirpUpdateProfile = 50, chirpDelete = 5,
        getMail = 80, readMail = 30, sendMail = 40, deleteMail = 5,
        spotifyApi = 250, tidalApi = 250, oauthStart = 20, oauthStatus = 2,
        getBank = 30, transfer = 10, payBill = 10, getVehicles = 40,
        startLiveLocation = 30, serviceRequest = 0,
        radio = 1500,            -- per minute of internet radio in the music apps
    },
}

-- Emergency / services app. The phone sends a request to every online
-- player whose job is listed; they get a notification with a GPS button.
Config.Services = {
    { id = 'police',    label = 'Police',      number = '911', jobs = { 'police' },    icon = 'fa-shield-halved', color = '#1c6dd0' },
    { id = 'ambulance', label = 'EMS',         number = '912', jobs = { 'ambulance' }, icon = 'fa-truck-medical', color = '#e5383b' },
    { id = 'mechanic',  label = 'Mechanic',    number = '913', jobs = { 'mechanic' },  icon = 'fa-wrench',        color = '#f08c00' },
    { id = 'taxi',      label = 'Taxi',        number = '914', jobs = { 'taxi' },      icon = 'fa-taxi',          color = '#f5c518' },
}

-- Camera: the live viewfinder is drawn inside the phone from the game view
-- (no screenshot resource needed). Photos (jpg) and videos (webm) are stored
-- on this server in opslabs-phone/media and served from the PublicUrl set in
-- config_server.lua (or the server's cfx.re address).
Config.Camera = {
    MaxVideoSeconds = 60,    -- longest video a player can record
}

-- Places shown in the Maps app.
Config.Places = {
    { name = 'Legion Square',          coords = vec3(195.17, -933.77, 30.69),  icon = 'fa-tree' },
    { name = 'Pillbox Hospital',       coords = vec3(298.67, -584.47, 43.26),  icon = 'fa-hospital' },
    { name = 'Mission Row PD',         coords = vec3(428.23, -984.28, 29.76),  icon = 'fa-building-shield' },
    { name = 'Fleeca Bank',            coords = vec3(149.91, -1040.74, 29.37), icon = 'fa-building-columns' },
    { name = 'Los Santos Customs',     coords = vec3(-337.38, -136.92, 39.0),  icon = 'fa-screwdriver-wrench' },
    { name = 'Premium Deluxe Motorsport', coords = vec3(-56.7, -1096.6, 26.4), icon = 'fa-car' },
    { name = 'LS International Airport', coords = vec3(-1037.0, -2737.0, 20.17), icon = 'fa-plane' },
    { name = 'Vespucci Beach',         coords = vec3(-1393.4, -1024.6, 4.4),   icon = 'fa-umbrella-beach' },
    { name = 'Sandy Shores',           coords = vec3(1853.0, 3686.0, 34.27),   icon = 'fa-sun' },
    { name = 'Paleto Bay',             coords = vec3(-150.0, 6390.0, 31.5),    icon = 'fa-water' },
}

-- Wallpapers available in Settings (CSS backgrounds). Players may also paste
-- an image URL.
Config.Wallpapers = {
    { id = 'ios18',   label = 'Bloom',    css = 'radial-gradient(120% 80% at 20% 10%, #ff8a5c 0%, transparent 55%), radial-gradient(110% 90% at 90% 30%, #8a5cff 0%, transparent 60%), radial-gradient(120% 100% at 40% 100%, #2b6bff 0%, transparent 60%), #0b0b2a' },
    { id = 'teal',    label = 'Lagoon',   css = 'radial-gradient(100% 70% at 80% 0%, #6fe7d2 0%, transparent 60%), radial-gradient(120% 90% at 0% 100%, #1f7a8c 0%, transparent 65%), #062a35' },
    { id = 'pink',    label = 'Blush',    css = 'radial-gradient(90% 70% at 10% 0%, #ffc1e3 0%, transparent 60%), radial-gradient(120% 100% at 100% 100%, #ff5fa2 0%, transparent 60%), #3a0f2a' },
    { id = 'ultra',   label = 'Ultramarine', css = 'radial-gradient(90% 70% at 90% 0%, #a7b8ff 0%, transparent 60%), radial-gradient(120% 100% at 0% 100%, #3346d3 0%, transparent 65%), #0a0f3d' },
    { id = 'sunset',  label = 'Sunset',   css = 'linear-gradient(180deg, #1d2b64 0%, #f8576b 60%, #ffb36b 100%)' },
    { id = 'mono',    label = 'Graphite', css = 'radial-gradient(100% 80% at 50% 0%, #4a4a4f 0%, transparent 70%), #111113' },
}

Config.Ringtones = {
    { id = 'reflection', label = 'Reflection' },
    { id = 'opening',    label = 'Opening' },
    { id = 'radar',      label = 'Radar' },
    { id = 'chime',      label = 'Chime' },
}
