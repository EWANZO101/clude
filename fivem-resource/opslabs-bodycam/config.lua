Config = {}

-- Guarantees ServerConfig exists (as an empty table) even before config_server.lua loads - and forever,
-- if it's never copied from config_server.example.lua at all. Without this, a fresh install that hasn't
-- set that file up yet crashes every server script that reads ServerConfig.* at load time (xonsight.lua,
-- audio.lua) instead of just quietly running with Xon Sight/voice disabled, same as an empty config would.
-- config_server.lua (when present) does `ServerConfig = {}` itself right after this, which simply replaces
-- this placeholder - no conflict either way.
ServerConfig = ServerConfig or {}

-- Framework used for jobs, duty, names and items. 'auto' finds Qbox, QBCore, ESX, ox_core or ND by itself and runs
-- standalone when there is none. Force one with 'qbx', 'qb', 'esx', 'ox', 'nd' or 'standalone'
-- (or the convar: set opsbodycam_framework "esx").
Config.Framework = 'auto'

-- Who is issued a bodycam:
--   'job'           members of Config.Access.Jobs (on duty, when OnDutyOnly)
--   'item'          anyone carrying Config.Access.Item
--   'job_and_item'  a listed job AND the item
--   'job_or_item'   a listed job OR the item
--   'ace'           only players with the ACE below (standalone servers: add_ace group.police opslabs.bodycam allow)
--   'everyone'      every player
-- Players with the ACE can always use it, whatever the mode.
Config.Access = {
    Mode = 'job',
    Jobs = { police = 0, sheriff = 0, statepolice = 0, ambulance = 0 },   -- job = lowest grade that gets a camera
    OnDutyOnly = true,          -- frameworks with a duty flag (QBCore / Qbox onduty, ESX job.onDuty)
    Item = 'bodycam',
    Ace = 'opslabs.bodycam',
}

-- Toggle: key (players can rebind it in Settings → Key Bindings → FiveM), command, the OPS Phone Bodycam app.
Config.Keybind = 'F10'
Config.Command = 'bodycam'

-- Starts by itself, like a real camera with signal triggers. It never stops by itself (only on going off duty).
Config.Auto = {
    OnShooting = true,          -- firing any weapon (taser included)
    OnSiren = true,             -- driving with the emergency lights / siren on - AND at least SirenSpeedMph
    OnWeaponDrawn = true,       -- drawing a gun OR taser out of the holster (not just aiming - the moment it's equipped)
    SirenSpeedMph = 68,         -- siren alone isn't a trigger by itself; a parked/crawling vehicle with lights on isn't a stop
    Cooldown = 15,              -- seconds after a manual stop before an auto trigger can start it again
}

-- Pre-event buffer: a real bodycam is never really "off" - it keeps a short rolling buffer so an auto trigger
-- (shots fired, weapon drawn, pursuit) catches what led up to it, not just what comes after. Implemented as a
-- separate, much smaller/cheaper continuous capture (own low resolution, fps and bitrate below) that only
-- officers issued a bodycam ever run, and that stops the moment a real recording starts (no point buffering
-- while already recording at full quality) and picks back up the moment it stops.
Config.PreRoll = {
    Enabled = true,
    Seconds = 180,              -- how far back an auto trigger reaches (3 minutes)
    Width = 320, Height = 180,  -- intentionally tiny - this runs the whole time an officer is on duty
    Fps = 8,
    Bitrate = 200000,           -- ~200 kbps - a fraction of Config.Video.Bitrate
}

-- The video. Drawn from the game view (no screenshot resource needed): what the player sees, including the game's own
-- HUD (minimap, weapon wheel…) but not NUI (phone, menus).
Config.Video = {
    Width = 1280,
    Height = 720,
    Fps = 30,
    Bitrate = 3000000,          -- bits per second (3 Mbps ≈ 22 MB a minute)
    SegmentSeconds = 120,       -- long recordings are split into parts; each part becomes its own evidence item
    -- The video is what's on the player's screen (the game draws one view per frame, so there's no separate camera to
    -- record). true = hold the player in first person while recording; false = record whatever view they use.
    FirstPerson = false,
    MaxMinutes = 0,             -- stop after this long (0 = never)
    Overlay = true,             -- burn the evidence data into the picture: time, camera, unit, officer, location, GPS…
    OverlayColor = '#ffd60a',   -- watermark text colour
    OverlayTitle = 'OPS BODY CAM',
}

-- Optional: render from a camera clipped to the chest instead of the player's free-look view while recording, so the
-- footage is a true body-worn-camera perspective (follows body heading, not mouse-aim) - technique and bone/offsets
-- from Your-Spy/spy-bodycam's self-watch camera. Trade-off, by design: while this is active the officer can't look
-- around independent of which way they're facing - that's a real chest cam doing that, not a bug. Off by default:
-- it changes how recording *feels to play through* (aiming/looking), not just how the footage looks, so try it
-- before turning it on for everyone.
Config.ChestCam = {
    Enabled = false,
    Fov = 100.0,
    Offset = { x = 0.1, y = 0.025, z = 0.1 },           -- on foot, bone-local (spy-bodycam's values)
    VehicleOffset = { x = 0.1, y = 0.25, z = -0.1 },    -- seated in a vehicle
    Shake = false,              -- subtle handheld wobble (ShakeCam 'HAND_SHAKE')
    ShakeAmplitude = 0.3,       -- spy-bodycam uses 2.0 (quite strong); gentler here so footage stays reviewable
}

Config.Hud = {
    Enabled = true,             -- the small "● REC 00:00" badge on screen
    Position = 'top-right',     -- 'top-right', 'top-left', 'bottom-right', 'bottom-left'
}

Config.Beep = {
    OnStartStop = true,
    Interval = 120,             -- seconds between the double reminder beep while recording (0 = off)
    Volume = 0.25,
}

-- Spoken line on start/stop (NUI text-to-speech, in addition to the beep above - set either's *Enabled off if
-- you only want one). Plays through whatever TTS voice the client has available; if it has none, this is a
-- silent no-op rather than an error, so it's safe to leave on for everyone.
Config.Voice = {
    Enabled = true,
    OnStart = 'Xon recording',
    OnStop = 'Xon off',
    Rate = 1.0, Pitch = 1.0, Volume = 0.8,
}

-- The black vest (opslabs-props: opslabs_vest_black) with the camera clipped to its chest. While recording the camera
-- shows its red LEDs. Put on / taken off with the item or the command.
Config.Vest = {
    Enabled = true,
    Item = 'ops_vest',          -- use it to put the vest on / take it off ('' = command only)
    Command = 'vest',           -- '' = item only
    CommandNeedsAccess = true,  -- the command only works for players issued a bodycam (Config.Access) or carrying the item
    Animation = true,           -- a short "pulling it on" animation
    Model = 'opslabs_vest_black',
    Camera = 'opslabs_bodycam',
    CameraOn = 'opslabs_bodycam_on',
    CamOffset = vector3(0.0, 0.169, 0.0),   -- where the camera clips on the vest (vest model space, from build_bodycam.py)
    CameraWithoutVest = true,   -- recording without the vest: the camera is clipped to the shirt instead
    RequiredToRecord = false,   -- true = /vest (or the item) must be ON before the bodycam will start at all, manual
                                -- or auto - false (default) = recording works regardless, same as it always has
    -- where the vest sits, from SKEL_Spine3, in body directions (metres). Each player can fine-tune their own with
    -- /vestfit up|forward|side <metres> (saved for them, seen by everyone); put good values here for everybody.
    Fit = {
        male = { forward = 0.0, up = 0.0, side = 0.0 },
        female = { forward = -0.015, up = -0.03, side = 0.0 },
    },
    ShirtCam = {                -- the camera on the shirt (no vest): how far in front of / above SKEL_Spine3
        male = { forward = 0.145, up = 0.0 },
        female = { forward = 0.13, up = -0.03 },
    },
}

-- How often the officer's position is sent to the Xon Sight /live page while recording.
Config.Live = { ReportSeconds = 3 }

-- Live video to the Xon Sight /live page (MediaMTX WHIP publish from the NUI - html/recorder.js's Live
-- module), separate from the recorded-evidence pipeline above: no chunked upload, no Xon Sight evidence
-- item, just a real-time feed a logged-in viewer can watch while it's happening. Video only - no game
-- audio reaches the NUI, same limitation as the recorded bodycam. Started/stopped from the MDT laptop
-- (opslabs-mdt) via exports('StartLive')/('StopLive') below, or manually with Config.LiveStream.Command.
Config.LiveStream = {
    Command = 'dashcam',       -- '' = no chat command, MDT/other scripts only
    Kind = 'dashcam',          -- sent to Xon Sight as the stream's `kind` (also accepts 'bodycam')
    Width = 1280, Height = 720, Fps = 24,
    OverlayTitle = 'OPS DASH CAM',
    HeartbeatSeconds = 5,      -- how often the server tells Xon Sight this broadcast is still alive
}

-- Video upload to the server after each part (latent events, so gameplay traffic isn't held up).
Config.Upload = {
    ChunkKB = 512,
    BytesPerSecond = 1500000,
}

--- In-game messages. Uses ox_lib when it's running, otherwise the GTA feed.
Config.Notify = function(text, kind)
    if GetResourceState('ox_lib') == 'started' then
        exports.ox_lib:notify({ title = 'Bodycam', description = text, type = kind or 'inform' })
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(text)
        EndTextCommandThefeedPostTicker(false, false)
    end
end
