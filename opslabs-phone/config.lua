Config = {}

-- Branding — the MAIN company of this server and every platform name players see on phones, laptops, routers,
-- stores, websites and OPS Hub. Leave a name empty to derive it from Name (OS → "<Name> OS", Hub → "<Name> Hub" …).
-- Change any of it live on OPS Hub → Settings (no restart). Companies themselves are renamed on OPS Hub → Companies.
Config.Brand = {
    Name = 'OPS',                          -- the main brand, e.g. 'Vodafone', 'Skyline', 'Los Santos Telecom'
    Full = 'OPS Hub · Network · Power',    -- the long name (website titles, about page)
    Group = 'OPS Group',                   -- the parent company that owns every brand
    Color = '#5b3df5',                     -- main colour (hex)
    Accent = '#38bdf8',                    -- second colour (hex)
    Logo = '',                             -- https image URL for the logo; empty = built-in signal mark
    OS = '',          -- phone / laptop / router operating system name   (default "<Name> OS")
    ID = '',          -- player account name                               (default "<Name> ID")
    Hub = '',         -- the staff website                                 (default "<Name> Hub")
    Work = '',        -- the jobs app                                      (default "<Name> Work")
    Academy = '',     -- training                                          (default "<Name> Academy")
    Store = '',       -- the app store                                     (default "<Name> Store")
    Search = '',      -- the search engine                                 (default "<Name> Search")
    Depot = '',       -- engineering depots                                (default "<Name> Depot")
    Accounts = '',    -- engineer accounts app                             (default "<Name> Networks")
    Trust = '',       -- the certificate authority on websites             (default "<Name> Trust")
    -- in-game website addresses (leave as they are, or give your own .sa / .ls names)
    Sites = { search = 'ops.sa', domains = 'opsdomains.sa', whois = 'whois.sa', web = 'opsweb.sa', cloud = 'opscloud.sa', academy = 'opsacademy.sa' },
}

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

-- Battery: drains with use and only charges on a live charger (opslabs-towers: phone charging cable, wireless pad,
-- USB socket) or a power bank. At 0 % the phone switches off until it's charged (it can't be called either).
-- Rates are % per real minute.
Config.Battery = {
    Enabled = true,
    Standby = 0.2,            -- in your pocket (≈ 8 hours)
    ScreenOn = 0.7,           -- phone open (≈ 2.5 hours)
    InCall = 1.0,
    Wired = 3.5,              -- charging cable / USB socket (≈ 30 min to full)
    Wireless = 2.2,           -- wireless pad / stand
    PowerBank = 4.0,          -- while a power bank is charging it
    PowerBankAmount = 50,     -- % one charged power bank adds
    PowerBankRecharge = 60,   -- seconds to recharge a flat power bank on a charger
    PowerBankItem = 'powerbank',
    PowerBankEmptyItem = 'powerbank_empty',
    Warnings = { 20, 10, 5 },
}

-- Wireless charger dock: stand beside a wireless pad / stand (opslabs-towers) and press E to take the phone out of
-- your inventory and put it down on the charger, where everyone can see it. It charges there while the charger is
-- live, still rings and gets messages, and you can use it (F1) as long as you stay beside it. E again picks it up.
-- A docked phone stays there across disconnects and restarts until its owner picks it up.
Config.Dock = {
    Enabled = true,
    Auto = false,             -- true = put the phone down by itself when you stop next to a free charger (no key)
    AutoDelay = 2500,         -- ms you have to stand still beside the charger before Auto docks
    Key = 38,                 -- E
    PromptDistance = 1.6,     -- how close to the charger the prompt shows
    UseDistance = 2.2,        -- how far you can be from the docked phone and still use it on screen
    OwnerOnly = true,         -- false = anyone can pick up a docked phone (it goes into their inventory)
    Models = { on = 'opslabs_phone_dock_on', off = 'opslabs_phone_dock' },   -- opslabs-props; falls back to Config.Prop
    -- where the phone sits on each charger model (charger frame: x right, y back, z up). pitch tilts it back.
    Spots = {
        opslabs_mains_qipad = { pos = vector3(0.0, 0.0, 0.0085), pitch = 0.0 },
        opslabs_mains_qistand = { pos = vector3(0.0, 0.0219, 0.0911), pitch = 74.5 },
    },
}

-- OPS Buds: wireless earbuds (an item). Use the case to put them in your ears; the first time a card asks to connect
-- them to your phone. They work like the real thing: battery for each bud and the case (the case charges beside any
-- live charger and tops the buds up), Noise Control (Noise Cancellation mutes the world around you, Transparency /
-- Adaptive / Off), Conversation Awareness (lowers your music when you talk), Automatic Ear Detection (taking them out
-- pauses your music), hands-free calls (no phone at your ear), press to play / pause / answer, press and hold to
-- switch Noise Control, and a Bluetooth range from a docked phone. Other players see them in your ears.
Config.Buds = {
    Enabled = true,
    Item = 'ops_buds',
    Label = 'OPS Buds',
    Range = 12.0,             -- metres from a docked phone before the buds lose the connection
    -- % per real minute
    Drain = 0.28,             -- in your ears, playing (≈ 6 hours)
    DrainIdle = 0.12,         -- in your ears, quiet
    DrainAnc = 0.05,          -- extra while Noise Cancellation / Adaptive is on
    BudCharge = 6.0,          -- buds in the case (≈ 15 min to full), taken from the case battery
    CaseCost = 0.22,          -- case % used for every 1 % put into the buds (the case holds ≈ 4.5 full charges)
    CaseCharge = 2.0,         -- the case beside a live charger
    Warnings = { 20, 10 },
    -- Noise Cancellation: the GTA audio scene that mutes the world (voice chat is not affected). '' = off
    AncScene = 'CHARACTER_CHANGE_IN_SKY_SCENE',
    -- the press control: rebind in Settings → Key Bindings → FiveM. Tap = play / pause, answer, hang up;
    -- double tap = next track; hold = cycle Noise Control
    Keybind = 'PAGEUP',
    -- where the buds sit, relative to the head (metres): side = out from the centre, up, forward
    Ear = { male = { side = 0.074, up = 0.022, forward = -0.004 }, female = { side = 0.068, up = 0.02, forward = -0.004 } },
}
-- OPS SafeMag: a magnetic battery pack (an item) that snaps onto the back of the phone. Use it to snap it on / take it
-- off. Like the real thing: while it's on, it charges the phone wirelessly from its own battery; on a charger (cable,
-- wireless pad, USB socket or a dock) the phone charges first and the pack after it, and a pack on its own charges
-- beside any live charger (opslabs-towers). The Dynamic Island shows both levels when it snaps on, and the Batteries
-- widget on the home screen shows the phone, the SafeMag and the OPS Buds together.
Config.SafeMag = {
    Enabled = true,
    Item = 'ops_safemag',
    Label = 'OPS SafeMag',
    -- % per real minute
    Charge = 1.6,             -- phone % the pack adds (slower than a cable, like real MagSafe ≈ 1 hour to full)
    Cost = 0.7,               -- pack % used for every 1 % put into the phone (a full pack ≈ 1.4 phone charges)
    Recharge = 2.5,           -- the pack on / beside a live charger (≈ 40 min to full)
    StopAt = 100,             -- the pack stops charging the phone here (real packs stop around 90 to save the battery)
    Warnings = { 20, 10 },
    -- the pack on the back of the phone in your hand (opslabs-props opslabs_safemag). It's fitted to Config.Prop by
    -- itself; side = which face of the phone is the back (1 / -1, try /safemagside in game), flip = turn it upside
    -- down, offset = nudge it. Or set pos + rot (vector3s) to place it by hand.
    Attach = { side = -1, flip = false, offset = vector3(0.0, 0.0, 0.0) },   -- -1 = the back of prop_npc_phone_02
}

-- Batteries widget (home screen, page 1): phone + OPS SafeMag + OPS Buds levels, like the iPhone widget. It shows
-- once you own an accessory; players can hide it in Settings → Battery.
Config.BatteriesWidget = true

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
        webBrowse = 120, webSearch = 60, webForm = 20, webDomains = 20, webHost = 20, webCloud = 20,   -- the in-game internet (Browser app)
        trafficFeed = 60, trafficReport = 10, trafficVote = 2, trafficClear = 2, trafficPursuit = 4,   -- OPS Traffic
        datingDeck = 300, datingProfile = 40, datingSave = 40, datingSwipe = 5, datingMatches = 60, datingChat = 30, datingSend = 10, datingUnmatch = 5, datingReport = 5,   -- Sparks (dating)
        radio = 1500,            -- per minute of internet radio in the music apps
    },
}

-- OPS Traffic app: live incidents across the state — accidents, road closures, fires, gun violence (OPS Sentinel
-- sensors), active police pursuits (10-80) and planned work (street works sites, planned network / power work, crews
-- on site). Players report incidents; crashes and fires near a player are reported automatically; police start /
-- end 10-80s that track the lead unit live; police and the reporter clear them.
Config.Traffic = {
    Enabled = true,
    PoliceJobs = { 'police', 'sheriff', 'state' },      -- start 10-80s, close roads, clear anything
    ClosureJobs = { 'police', 'sheriff', 'state', 'mechanic', 'electrician', 'sapl' },   -- may also mark a road closed
    AlertRadius = 800.0,           -- metres: phones this close get a notification about a new incident (players can turn it off in the app)
    MergeRadius = 80.0,            -- reports this close together of the same kind are one incident (they add a confirmation)
    Expire = { accident = 25, closure = 120, fire = 30, shots = 20, pursuit = 3, hazard = 30, police = 30, works = 240 },  -- minutes until it drops off (pursuit: without a position update)
    AutoCrash = true,              -- a hard crash in a vehicle reports an accident
    AutoFire = true,               -- fires near a player report a fire
    PursuitUpdate = 3,             -- seconds between 10-80 position updates from the lead unit
}

-- Sparks (dating app): profiles, swipe to like / pass, a match when it's mutual, then chat. Over-18 characters only.
Config.Dating = {
    Enabled = true,
    MinAge = 18,
    MaxPhotos = 4,
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

-- OPS platform (OPS Work app + OPS Hub): companies, jobs, wages, invoices — server/platform.lua, sql/ops_catalog.json
Config.Platform = {
    AutoJobs = true,              -- customers keep needing things: new jobs appear by themselves
    JobEvery = 240,               -- seconds between checks (one new job per company if it has fewer open than below)
    OpenJobsPerCompany = 4,
    MaxActiveJobs = 3,            -- jobs one engineer can hold at once
    StartingBalance = 25000,      -- each company's account when it is first created
}

-- Feature switches for the OPS systems that live in this resource (opslabs-towers has its own Enabled flags).
-- Every value in this file (and opslabs-towers/config.lua) can also be changed on OPS Hub → Settings or in
-- OPS Work → Admin settings; those changes are saved in the database and override this file.
Config.Features = {
    Web = true,                   -- the in-game internet: Browser, OPS Domains, OPS Web, email on your own domain
    Cloud = true,                 -- OPS Cloud virtual servers
    Business = true,              -- quotes, contracts, stock, assets, fleet, tickets, alerts
    Training = true,              -- courses, exams, practicals and certifications
    Assistant = true,             -- the job assistant ("Guide me" / /jobhelp)
}

-- How OPS jobs are worked.
Config.Work = {
    -- 'standalone': no inventory items needed — tools are assumed to be in your van and kit is placed from /towers.
    -- 'items':      realistic — tools and parts are inventory items (ox_inventory / ESX / qb). Engineers collect them
    --               from an OPS depot, need the right tools to start a job and use up the parts the job needs.
    Mode = 'standalone',
    Inventory = 'auto',           -- 'auto' | 'ox' | 'esx' | 'qb'   (items mode only)
    ItemPrefix = 'ops_',          -- item names: ops_crimper, ops_cam_ip … (see items/ for ready-made definitions)
    ConsumeParts = true,          -- items mode: completing a job uses its parts from your inventory
    -- where tools and parts are collected (items mode) and where the job assistant sends you for them
    Depots = {
        { label = 'OPS Depot · LSIA', x = -1318.5, y = -3027.2, z = 13.94, companies = 'all' },
    },
    DepotRadius = 3.0,
    -- items mode: kit placed from /towers uses this stock item (item name = ItemPrefix .. sku, '-' → '_'); removing it gives it back
    ModelItems = {
        opslabs_gw_pro = 'rtr-gw', opslabs_gw_mini = 'rtr-gw', opslabs_edge_e5 = 'rtr-gw', opslabs_edge_e7 = 'rtr-gw', opslabs_homerouter_ax4 = 'rtr-gw',
        opslabs_poe_switch8 = 'sw-poe8', opslabs_ap_halo = 'ap-wifi6', opslabs_ap_halo_ceiling = 'ap-wifi6', opslabs_ap_beam = 'ap-wifi6', opslabs_ap_beam_ceiling = 'ap-wifi6',
        opslabs_ont = 'ont', opslabs_cbt = 'cbt', opslabs_cbt_4 = 'cbt', opslabs_cbt_8 = 'cbt', opslabs_cabinet_pcp = 'cab-pcp', opslabs_nte5c = 'nte', opslabs_laptop = 'laptop',
        opslabs_cctv_bullet = 'cam-ip', opslabs_cctv_dome = 'cam-ip', opslabs_cctv_turret = 'cam-ip', opslabs_cctv_fisheye = 'cam-ip', opslabs_cctv_ptz = 'cam-ptz',
        opslabs_cctv_anpr = 'cam-anpr', opslabs_cctv_thermal = 'cam-therm', opslabs_cctv_doorbell = 'doorbell', opslabs_cctv_nvr = 'nvr', opslabs_cctv_dvr = 'dvr', opslabs_cctv_reader = 'reader',
        opslabs_mains_cu = 'cu', opslabs_mains_ev_wall = 'ev', opslabs_mains_ev_post = 'ev', opslabs_solar_panel_roof = 'pv-panel', opslabs_solar_inverter = 'inverter', opslabs_solar_battery = 'battery',
    },
    -- health & safety
    SafetyBriefing = true,        -- a dynamic risk assessment (checklist) before starting on-site work
    SafetyIncidents = true,       -- skip the checklist on a risky job and accidents can happen (falls, shocks)
    RequireSafetyTraining = true, -- the family's safety module must be passed before taking its jobs
    -- training: what a certification needs (the exam is always required)
    RequirePractical = true,      -- an in-game practical at a training bench
    PracticalSkillChecks = true,  -- ox_lib skill checks during the practical
    PassMark = 75,                -- % for exams and safety quizzes
    RetryCooldown = 60,           -- seconds before you can re-sit after failing
    TrainingCentres = {
        { label = 'OPS Academy · LSIA', x = -1324.0, y = -3036.0, z = 13.94 },
    },
    -- step animations (job assistant, on-site work, practicals). dict/clip, or scenario
    Anims = {
        crimp = { dict = 'mini@repair', clip = 'fixing_a_ped' },
        drill = { scenario = 'WORLD_HUMAN_CONST_DRILL' },
        reach = { dict = 'amb@prop_human_movie_bulb@idle_a', clip = 'idle_b' },
        kneel = { dict = 'amb@medic@standing@kneel@idle_a', clip = 'idle_a' },
        type = { dict = 'anim@heists@prison_heiststation@cop_reactions', clip = 'cop_b_idle' },
        inspect = { dict = 'amb@code_human_police_investigate@idle_a', clip = 'idle_b' },
        splice = { dict = 'mini@repair', clip = 'fixing_a_player' },
        clipboard = { scenario = 'WORLD_HUMAN_CLIPBOARD' },
        phone = { scenario = 'WORLD_HUMAN_STAND_MOBILE' },
        carry = { dict = 'anim@heists@box_carry@', clip = 'idle' },
        ladder = { dict = 'amb@prop_human_movie_bulb@idle_a', clip = 'idle_a' },
        dig = { scenario = 'WORLD_HUMAN_GARDENER_PLANT' },
        test = { dict = 'amb@world_human_clipboard@male@idle_a', clip = 'idle_c' },
    },
}
