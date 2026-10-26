# OPS Bodycam (`opslabs-bodycam`)

Body worn cameras for FiveM. The officer's view is recorded as **video** in game and every recording is sent to the
**Xon Sight evidence portal** (`/evidence`); while someone records they show on its **`/live`** page with their
position and facing. Works standalone or on ESX, QBCore, Qbox, ox_core and ND. The **OPS Phone** has a Bodycam app.

## How it works

```
game view ──WebGL──▶ NUI canvas (+ date/time, officer, serial, street burned in) ──MediaRecorder──▶ webm part
   │                                                                                   │ chunks, latent events
   │ position every 3 s                                                                 ▼
   ▼                                       server: media/<random>.webm  (uploaded to the portal, or Storage.PublicUrl)
server roster ──POST /api/xonsight/recorders/sync──▶ Xon Sight /live                    │
                                                    Xon Sight /evidence ◀──POST /api/xonsight/evidence (videoUrl)
```

- The portal never receives the video itself, only its link, so the files have to be reachable over **https**.
- Long recordings are split into parts (`Config.Video.SegmentSeconds`, default 3 min). Each part is its own
  evidence item, captioned *officer · job · street · part N · time · trigger · note*.
- The picture is exactly what the player sees (their current view, the game's own HUD / minimap included, NUI screens
  like the phone not). The game draws one view per frame, so there's no separate chest camera to record by default;
  `Config.Video.FirstPerson = true` holds the player in first person while recording instead. For an actual
  chest-mounted perspective, see **Chest cam** below.
- Shots fired / weapon drawn also raise an alert banner on the portal's Live page (`Config.Auto` + `XonSight.AlertTriggers`
  in `server/xonsight.lua`) - lights-and-siren deliberately doesn't, or every routine traffic stop would flash red.
- The live roster pushes to Xon Sight immediately when someone starts/stops recording, not just on the periodic
  `SyncSeconds` timer - the Live page reflects a new recorder within about a second, not up to `SyncSeconds` later.
- **Voice** (the officer's mic, people talking near them, radio) comes from the OPS Voice bridge — see below. Game
  sound (shots, sirens, engines) can't be recorded: FiveM gives neither the NUI nor the server the game's audio.

## Install

1. `ensure opslabs-bodycam` in `server.cfg`, after your framework, `opslabs-license` and (optional) `oxmysql`.
2. Edit `config_server.lua` (ships ready to go, no copying from an example file needed) and set just:
   - `XonSight.Url` / `XonSight.Token`: sign up your community at the portal's `/get-started` page, then
     paste both straight from `/integration` (header `X-XonSight-Token`)
3. That's it - leave `Storage.PublicUrl` blank. Recordings upload straight to your Xon Sight portal and play
   back from there, with no web server of your own to stand up and no extra process to run. The server console
   on start-up confirms this (`Videos: <resource>/media → Xon Sight portal`); if `Storage.PublicUrl` is ever
   set to something that isn't a real address (or accidentally points at the portal itself), the console says
   so and falls back to the portal automatically rather than silently showing "video unavailable" forever.

   **Prefer to host the files yourself?** Set `Storage.PublicUrl` to a web server you run that publishes
   `Storage.Dir` from disk. The videos are written to `<resource>/media` (FXServer only lets a resource write
   inside resource folders) - **publish that folder with a web server from disk, never through FXServer**
   (sending video from a resource crashed the game server once). nginx can't read under `/root`, so bind-mount
   the folder somewhere it can:
   ```bash
   mkdir -p /var/www/opslabs-bodycam/media
   mount --bind "<resources>/[rps]/opslabs-bodycam/media" /var/www/opslabs-bodycam/media
   # /etc/fstab:  <resources>/[rps]/opslabs-bodycam/media /var/www/opslabs-bodycam/media none bind,nofail 0 0
   ```
   ```nginx
   location ^~ /opslabs-bodycam/media/ {
       alias /var/www/opslabs-bodycam/media/;
       types { video/webm webm; }
       add_header Access-Control-Allow-Origin "*" always;
       limit_except GET HEAD { deny all; }
   }
   ```
   then set `PublicUrl` to that address (your own domain, **not** the Xon Sight portal's).

   There's also a standalone `tools/upload-companion.py` script for a middle ground (host the files
   yourself, but push them to a web server on another machine instead of running one on the FXServer box) -
   see its own `--help`/docstring. Most people don't need it: the zero-setup default above already covers
   the common case.
4. With `oxmysql` the table `opslabs_bodycam_recordings` is created by itself. Recordings the portal didn't take
   (down, wrong key) are sent again every 2 minutes, up to 10 times - and if using the zero-setup default, the
   upload to the portal itself is retried a few times first (with backoff) before that even comes into play.

## Bundled modules (`config_server.lua` → `ServerConfig.Modules`)

Five optional extras ship inside this same resource - no separate downloads, no repeating the portal
connection. All read `ServerConfig.XonSight` above; turn any of them off by setting its `Enabled = false`. Turn
on whichever phone module matches the phone resource your server actually runs - the others just never find
their export and stay dormant, so it's safe to leave more than one `Enabled = true` while migrating phones.

| Module | What it is | Needs |
|---|---|---|
| `Tablet` | In-hand tablet prop that opens the portal in NUI (`F6` by default) | Nothing extra |
| `LbPhone` | Installable LB Phone app - viewer, plus evidence capture from LB Phone's own camera | `lb-phone`, or `sky_phone` acting as it (see below) |
| `GksPhone` | Same app, registered with GKSPHONE V2 (`AddCustomApp`, [docs.gkshop.org](https://docs.gkshop.org/gksphone-v2/custom-app)) | `gksphone` |
| `Movement` | Same app, registered with 17Movement's phone (`AddApplication`, [docs.17movement.net](https://docs.17movement.net/phone/building-custom-apps)) | `17mov_Phone`, or `sky_phone` acting as it |
| `LiveSync` | Pushes a **different, third-party** bodycam's roster to `/live` | Off by default - this resource already syncs its own roster; only turn this on if you're running a separate `XonSight`-named bodycam instead of this one |

**Sky Phone** ([sky-systems/sky_phone](https://github.com/sky-systems/sky_phone#external-custom-apps)) isn't a
separate module - it provides compatibility aliases for `lb-phone` and `17mov_Phone`, so the `LbPhone` and
`Movement` modules above register with it unchanged. Start `sky_phone` instead of the original phone resource
for whichever alias you're using, never both at once (two resources exporting the same name race for the
registration). Captioning while Sky Phone is the active provider also needs its `SetPhoneGameInputEnabled`
export reported on focus - the `LbPhone` module does that automatically when it detects `sky_phone` running;
real `lb-phone` doesn't need it and is unaffected.

All three phone apps share the same UI (`html/app/`) - an auto-fit script (`html/app/autoscale.js`) measures
the iframe's actual rendered size and rescales the rem-based layout's root font size to match, so the app
renders correctly on any screen resolution and at any of the host phone's zoom/scale settings without needing
that phone's own (and differently-shaped, where it exists at all) scale API.

## Who gets a camera (`config.lua` → `Config.Access`)

| Mode | Who |
|---|---|
| `job` | members of `Jobs` (job = lowest grade), on duty when `OnDutyOnly` |
| `item` | anyone carrying `Item` (ox_inventory or the framework's inventory) |
| `job_and_item` / `job_or_item` | both / either |
| `ace` | only the ACE — for standalone servers: `add_ace group.police opslabs.bodycam allow` |
| `everyone` | every player |

The ACE (`opslabs.bodycam`) always works, whatever the mode. Going off duty or losing the job or item stops the
camera within 20 seconds. Callsigns come from QBCore / Qbox metadata, or from any script with
`Player(src).state:set('callsign', '1-ADAM-12', true)`.

## Using it

- **F10** (rebindable: Settings → Key Bindings → FiveM) or **/bodycam** to start / stop.
- **OPS Phone → Bodycam**: start / stop, recording time, add a note (incident no.) to the captions, *My footage*
  (sent / pending, evidence number) and *Live* (who is recording). The app only appears for players issued a camera
  (checked when the phone loads).
- **Auto start** (`Config.Auto`): firing a weapon (taser too), driving with lights / siren, optionally aiming.
  It never stops by itself; a manual stop holds auto start off for `Cooldown` seconds.
- A beep on start / stop and a double beep every 2 minutes while recording, like the real thing.

## Chest cam (optional, `Config.ChestCam`)

By default the recording is whatever the player is looking at - free mouse-look included, same as their own screen.
Turn `Config.ChestCam.Enabled` on and recording instead renders from a scripted camera clipped to the chest
(`AttachCamToPedBone`, bone/offsets from `Your-Spy/spy-bodycam`'s self-watch camera), following the ped's **heading**
every frame rather than the camera's aim - a true body-worn-camera perspective, not a first-person one.

**The trade-off is real, not a bug:** there's no way with these natives to render a second camera to an off-screen
texture while keeping the player's own free-look view - the same screen the NUI captures is what the officer sees.
So while chest cam is active, looking around means turning the character; aiming down sights and strafe-looking
independent of where you're walking stops working the way it normally does. That's why it defaults to `false` -
try it with a few officers before turning it on server-wide. `Config.ChestCam.Shake` adds a gentle handheld wobble
(off by default; spy-bodycam's own default is much stronger, tuned for passive watching rather than footage you
still need to review afterward).

## Voice (OPS Voice bridge)

`/opt/opsvoip-bridge/recorder.js`. When an officer starts recording, `server/audio.lua` tells the bridge
(`opsvoip_url` / `opsvoip_key`, the OPS Voice convars); a listening bot (`OPSBodycam-…`, allowed by the guard) joins
their pma-voice channel (`Player(src).state.assignedChannel`) and keeps every voice frame it hears. The client marks
the moment each video part starts; when the part is saved, the bridge cuts that window, mixes one Ogg Opus stream per
speaker with ffmpeg (`/opt/opsvoip-bridge/bin/ffmpeg`, static) and writes video + voice to
`/var/lib/opsvoip-bridge/bodycam/` (nginx: `/opslabs-bodycam/av/`). The evidence link points to that file and the
silent one is deleted (`ServerConfig.Audio.KeepSilentCopy`). If the bridge is down or a mux fails, the silent video
goes to Xon Sight as before. Bridge tests: `cd /opt/opsvoip-bridge && node --test test/*.test.js`.

**Voice plugin compatibility:** the bridge works by joining a numbered Mumble channel, and that numbering only
exists because **pma-voice** assigns it (`Player(src).state.assignedChannel`, set by pma-voice itself — see its
`server/main.lua`). That's the only voice resource this server runs, and the only one confirmed to work.
- **pma-voice** — works (what's deployed here). Radio/submix overlay scripts built on top of pma-voice don't change
  this — they don't touch channel assignment, so audio capture keeps working underneath them.
- **FXServer's built-in native Mumble voice (no pma-voice)** — not supported: nothing assigns numbered channels
  without pma-voice (or an equivalent script setting `state.assignedChannel` the same way), so `Audio.Start` silently
  has no channel to join and the recording stays silent (as of this fix, logged once instead of silent).
- **SaltyChat, GameVox** — cannot be bridged this way at all, regardless of configuration: both route player audio
  entirely outside FXServer's Mumble server (TeamSpeak and GameVox's own client respectively), so there's no Mumble
  channel for a listening bot to join in the first place. This isn't a missing integration to add — there's no
  audio path to tap into from here.

## The vest and the camera you can see

Models in **opslabs-props** (`opslabs_vest_black`, `opslabs_bodycam`, `opslabs_bodycam_on`), built by
`/root/fivem/opslabs-dev/props-source/make_bodycam_tex.py` + `build_bodycam.py`.

- **Put it on / take it off:** use the **`ops_vest`** item (Black Duty Vest), or **`/vest`** (only for players issued
  a bodycam or carrying the item: `Config.Vest.CommandNeedsAccess`). A vest worn from the item comes off when the
  item leaves your inventory.
- The camera is clipped to the vest's chest dock; **while recording it shows its red LEDs** (`opslabs_bodycam_on`).
  Recording without the vest clips the camera to the shirt (`Config.Vest.CameraWithoutVest`).
- The props are networked and attached to your ped, so everyone sees them. Other scripts: `Player(src).state.opsVest`,
  client exports `IsVestOn()` / `SetVest(bool)`, client event `opslabs-bodycam:vest`.
- **Fit:** the vest is a rigid plate carrier on `SKEL_Spine3`. If it sits too high / low / far on a ped,
  `/vestfit up 0.01`, `/vestfit forward -0.01`, `/vestfit side 0.005`, `/vestfit reset` move it for you (saved,
  per male / female ped, seen by everyone); `/vestfit` prints the totals — put good ones in `Config.Vest.Fit`.

Items:
- **ox_inventory** (`data/items.lua`, image `web/images/ops_vest.png`):
  ```lua
  ["ops_vest"] = { label = "Black Duty Vest", weight = 2500, stack = false, close = true },
  ```
  With ESX / QBCore / Qbox it is made usable through the framework. Without one (ox_core, ND, standalone) add
  `server = { export = 'opslabs-bodycam.useVest' }` to the entry.
- **ESX without ox_inventory:** `INSERT INTO items (name, label, weight) VALUES ('ops_vest', 'Black Duty Vest', 3);`
- **QBCore:** `ops_vest = { name = 'ops_vest', label = 'Black Duty Vest', weight = 2500, type = 'item', image = 'ops_vest.png', unique = true, useable = true, shouldClose = true },`

## For other scripts

Server:
```lua
exports['opslabs-bodycam']:CanUse(src)              -- issued a camera right now?
exports['opslabs-bodycam']:IsRecording(src)
exports['opslabs-bodycam']:StartRecording(src, 'panic button')
exports['opslabs-bodycam']:StopRecording(src)
exports['opslabs-bodycam']:GetActiveRecorders()     -- the /live roster (same name as XonSight's export)
TriggerEvent('opslabs-bodycam:trigger', src, 'pursuit')   -- auto start from your script
AddEventHandler('opslabs-bodycam:recorded', function(rec) end) -- every saved part: url, evidenceId, caption, …
AddEventHandler('opslabs-bodycam:started', function(src, sessionId, trigger) end)
AddEventHandler('opslabs-bodycam:stopped', function(src, sessionId, reason) end)
```
Client: `IsRecording()`, `GetState()`, `Start(reason)`, `Stop(reason)`, `Toggle()`, `SetNote(text)`,
`GetRecent()`, `GetLive()`; event `opslabs-bodycam:state` on every change.

## Notes

- The per-officer serial burned into the overlay (`serialFor()` in `server/main.lua`) now also reaches the portal as
  `deviceSerial` on the evidence webhook, filling in the Metadata tab's "Device serial" field automatically - it only
  ever sets a non-blank value, so a manual correction in the portal is never overwritten by a later retry resend.
- Evidence ids start at `XonSight.EvidenceIdOffset` (1 000 000) so they never collide with another source on the
  same portal. The portal's live roster is replaced on every sync, so **one game server per portal** for `/live`.
- Recording costs some client FPS (one extra draw + VP8 encode at 960×540, 20 fps). Lower `Config.Video` on
  weak PCs. A player who disconnects mid-part loses that part.
