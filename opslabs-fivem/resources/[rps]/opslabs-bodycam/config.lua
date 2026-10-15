Config = {}

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
    OnSiren = true,             -- driving with the emergency lights / siren on
    OnWeaponDrawn = false,      -- aiming a gun
    Cooldown = 15,              -- seconds after a manual stop before an auto trigger can start it again
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

Config.Hud = {
    Enabled = true,             -- the small "● REC 00:00" badge on screen
    Position = 'top-right',     -- 'top-right', 'top-left', 'bottom-right', 'bottom-left'
}

Config.Beep = {
    OnStartStop = true,
    Interval = 120,             -- seconds between the double reminder beep while recording (0 = off)
    Volume = 0.25,
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
