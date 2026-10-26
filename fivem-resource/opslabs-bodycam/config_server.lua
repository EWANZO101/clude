-- This file ships ready to edit directly - no copy step needed. (If you ever want a clean
-- reference copy, config_server.example.lua next to this has the same content.)
ServerConfig = {}

-- ============================================================================
--  REQUIRED - the barebones setup: record on the officer's view, upload the
--  finished clip to your Xon Sight portal. Everything below this section is
--  optional and OFF by default - skip it until you actually want it.
-- ============================================================================

ServerConfig.XonSight = {
    -- The one place the portal connection is set: the bodycam and every module below (tablet, LB Phone app,
    -- live sync) use it. Paste your setup block from the portal's /integration?just_created=1 page right here.
    Url = 'https://xonsight.opslabsystems.cloud',   -- your evidence portal's address, no trailing slash
    Token = '',                  -- your community's API token, sent as X-XonSight-Token
    LiveSync = true,             -- keep /live up to date with who is recording
    SyncSeconds = 5,
    -- Evidence ids must be unique on the portal. They start here, so they never meet the ids another source
    -- (e.g. the XonSight resource) sends to the same portal.
    EvidenceIdOffset = 1000000,
    ServerTag = '',              -- put in front of every caption when several servers share one portal, e.g. 'S1'
    -- trigger (session.trigger, e.g. the auto-start reasons below) -> alert sent to the portal's Live page
    -- (POST /api/xonsight/alerts - an extension endpoint, not every Xon Sight deployment has it). Anything not
    -- listed here never fires an alert - keep it short, or routine triggers like sirens become noise on /live.
    -- AlertTriggers = {
    --     ['shots fired']  = { type = 'weapon_fired', message = 'Shots fired' },
    --     ['weapon drawn'] = { type = 'weapon_drawn', message = 'Weapon drawn' },
    -- },
}

-- Where the videos are kept. Leave PublicUrl blank (the default) and recordings upload straight to your
-- Xon Sight portal instead - no web server to set up, no companion script to run. Only set PublicUrl if you'd
-- rather host the files yourself (your own nginx/web server publishing Storage.Dir from disk - see README.md's
-- Install section, step 3); FXServer itself never serves them either way (sending video from a resource
-- crashed the game server once).
ServerConfig.Storage = {
    -- folder for the .webm files. '' = <this resource>/media. FXServer only lets a resource write inside resource
    -- folders, so anything else must be a resource's folder (e.g. a dedicated storage resource)
    Dir = '',
    -- Optional: public https address of a web server YOU run that publishes Storage.Dir from disk, no trailing
    -- slash. Leave blank for the zero-setup default (upload straight to the portal, see above).
    PublicUrl = '',
    MaxSegmentMB = 64,           -- larger uploads are refused
}

-- Log recordings in MySQL (oxmysql, table created by itself) and retry evidence the portal didn't take.
-- Without oxmysql it still works; failed sends are then only retried until the next restart.
ServerConfig.Database = true

-- ============================================================================
--  OPTIONAL - all off by default. The bodycam records and uploads fine with
--  none of this touched; only come back here if you specifically want one
--  of these extras and have its dependency running.
-- ============================================================================

-- Real-time live video (MediaMTX WHIP publish, Config.LiveStream client-side) - a dashcam/bodycam toggle an
-- officer can start separately from normal recording, watchable on the portal's /live page while it's
-- happening. Needs a MediaMTX server you run yourself; WhipUrlFormat is where the NUI POSTs its SDP offer,
-- %s standing in for the per-session path Xon Sight hands back from /api/xonsight/live/start - e.g.
-- 'https://media.example.com:8889/%s/whip'. Leave Enabled = false (default) if you don't have MediaMTX set
-- up - nothing else breaks, the dashcam toggle just tells the officer live video isn't available here.
ServerConfig.LiveStream = {
    Enabled = false,
    WhipUrlFormat = '',
}

-- Voice in the videos (the officer's mic, people talking near them, radio) through the separate OPS Voice
-- bridge (/opt/opsvoip-bridge, a Node.js service you run yourself - not included here). Needs the OPS Voice
-- convars opsvoip_url / opsvoip_key set. Leave Enabled = false (default) if you don't run that bridge -
-- recordings still work, they just come out silent.
ServerConfig.Audio = {
    Enabled = false,
    PublicUrl = '',      -- where the bridge's videos with sound are served (nginx → /var/lib/opsvoip-bridge/bodycam)
    KeepSilentCopy = false,    -- keep the video-only file as well
}

-- Voice commands ("xonsight on"/"xonsight off") through the officer's own push-to-talk mic - same OPS Voice
-- bridge connection as Audio above (requires Audio.Enabled too), using a local/offline speech-to-text model
-- (no cloud API, no per-use cost, runs on the bridge server's own CPU). Only ever hears the recording officer's
-- own mic, never bystanders or radio traffic also heard in their channel. Phrases are matched case-insensitively
-- as a substring of what was heard, so minor misrecognition ("exon sight on") still works; keep them distinct
-- from each other and from ordinary radio chatter. Leave Enabled = false (default) along with Audio above.
ServerConfig.VoiceCommand = {
    Enabled = false,
    OnPhrases = { 'xonsight on', 'xon sight on', 'xon on' },
    OffPhrases = { 'xonsight off', 'xon sight off', 'xon off' },
}

-- ============================================================================
--  MODULES - the former xonsight-tablet / xonsight-lbphone / xonsight-livesync
--  resources, now part of this one (modules/). They use the portal connection
--  from ServerConfig.XonSight above. Only the non-secret settings below reach
--  players' games (modules/server.lua shares them) - Key/Token never do.
-- ============================================================================

ServerConfig.Modules = {
    -- In-game tablet (stock prop + NUI) that opens the portal.
    Tablet = {
        Enabled = true,
        -- Path opened inside the tablet: '/dashboard', or '/live' to land straight on the live recorder map.
        -- The officer logs in inside the tablet like a normal browser tab; the NUI keeps its cookies between uses.
        StartPath = '/dashboard',
        -- Key that opens/closes it (FiveM control name: https://docs.fivem.net/docs/game-references/controls/).
        -- Players can rebind it in Settings → Key Bindings → FiveM.
        ToggleKey = 'F6',
        -- Stock GTA V tablet prop - no custom model needed.
        PropModel = 'prop_cs_tablet',
        -- Bone the prop attaches to and its offset/rotation, tuned for prop_cs_tablet in the left hand.
        AttachBone = 'PH_L_Hand',
        AttachOffset = { x = 0.03, y = 0.02, z = 0.0 },
        AttachRotation = { x = 0.0, y = 0.0, z = 0.0 },
        -- Restrict by job (wire GetPlayerJob() in modules/tablet/client.lua to your framework). Empty = anyone.
        AllowedJobs = {},
        -- No attacking/aiming while it's open (both hands on the tablet). Walking stays enabled.
        DisableAttackWhileOpen = true,
    },

    -- Xon Sight as an installable LB Phone app (registered through lb-phone's AddCustomApp export). Also
    -- covers Sky Phone, which runs this unchanged through its lb-phone compatibility alias
    -- (https://github.com/sky-systems/sky_phone#external-custom-apps) - just don't run lb-phone and Sky
    -- Phone at the same time.
    LbPhone = {
        Enabled = true,
        Identifier = 'xonsight',
        Name = 'Xon Sight',
        Description = 'Bodycam evidence, live ops map, and cases - straight from your phone.',
        Developer = 'Xon Sight Evidence Portal',
        StartPath = '/dashboard',    -- page that opens first inside the app
        DefaultApp = false,          -- true = on every phone already, no app store download
        Price = nil,                 -- in-game price in the app store, nil = free
        Size = 4096,                 -- store listing size (kb), cosmetic only
        -- false = hide the in-app "Record evidence" button and only use the app as a viewer.
        AllowCapture = true,
    },

    -- Same app, registered with GKSPHONE V2 instead (https://docs.gkshop.org/gksphone-v2/custom-app). Off by
    -- default - turn on whichever of LbPhone/GksPhone/Movement actually matches the phone resource you run;
    -- the others just never find their export and stay dormant.
    GksPhone = {
        Enabled = false,
        Identifier = 'xonsight',
        Name = 'Xon Sight',
        Description = 'Bodycam evidence, live ops map, and cases - straight from your phone.',
        Developer = 'Xon Sight Evidence Portal',
        StartPath = '/dashboard',
        DefaultApp = false,
        Price = nil,
        Size = 4096,
        AllowCapture = true,
    },

    -- Same app, registered with 17Movement's phone instead (https://docs.17movement.net/phone/
    -- building-custom-apps). Also covers Sky Phone through its 17mov_Phone compatibility alias. Off by
    -- default, same reasoning as GksPhone above. The in-phone "Record evidence" camera capture isn't wired
    -- up for this one yet (see html/movement/index.html) - the dashboard viewer works regardless.
    Movement = {
        Enabled = false,
        Identifier = 'xonsight',
        Name = 'Xon Sight',
        Description = 'Bodycam evidence, live ops map, and cases - straight from your phone.',
        Developer = 'Xon Sight Evidence Portal',
        StartPath = '/dashboard',
        DefaultApp = false,
        Price = nil,
        Size = 4096,
        AllowCapture = true,
    },

    -- Pushes the separate XonSight resource's active recorders (exports.XonSight:GetActiveRecorders()) to the
    -- portal's /live page. Off by default: this resource already keeps /live up to date with its own recorders
    -- (ServerConfig.XonSight.LiveSync), and the portal replaces the whole roster on every sync, so running both
    -- makes them overwrite each other. Only turn it on if you run the XonSight resource instead of the bodycam's
    -- own live sync.
    LiveSync = {
        Enabled = false,
        PollIntervalMs = 5000,       -- how often to push the roster
        Debug = false,               -- print sync failures to the server console
    },
}
