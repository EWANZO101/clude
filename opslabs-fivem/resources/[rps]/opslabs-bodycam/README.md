# OPS Bodycam (`opslabs-bodycam`)

Body worn cameras for FiveM. The officer's view is recorded as **video** in game and every recording is sent to the
**Xon Sight evidence portal** (`/evidence`); while someone records they show on its **`/live`** page with their
position and facing. Works standalone or on ESX, QBCore, Qbox, ox_core and ND. The **OPS Phone** has a Bodycam app.

## How it works

```
game view ──WebGL──▶ NUI canvas (+ date/time, officer, serial, street burned in) ──MediaRecorder──▶ webm part
   │                                                                                   │ chunks, latent events
   │ position every 3 s                                                                 ▼
   ▼                                                   server: media/<random>.webm  (https: Storage.PublicUrl)
server roster ──POST /api/xonsight/recorders/sync──▶ Xon Sight /live                    │
                                                    Xon Sight /evidence ◀──POST /api/xonsight/evidence (videoUrl)
```

- The portal never receives the video itself, only its link, so the files have to be reachable over **https**.
- Long recordings are split into parts (`Config.Video.SegmentSeconds`, default 3 min). Each part is its own
  evidence item, captioned *officer · job · street · part N · time · trigger · note*.
- The picture is exactly what the player sees (their current view, the game's own HUD / minimap included, NUI screens
  like the phone not). The game draws one view per frame, so there's no separate chest camera to record;
  `Config.Video.FirstPerson = true` holds the player in first person while recording instead.
- **Voice** (the officer's mic, people talking near them, radio) comes from the OPS Voice bridge — see below. Game
  sound (shots, sirens, engines) can't be recorded: FiveM gives neither the NUI nor the server the game's audio.

## Install

1. `[rps]` is already `ensure`d, so the resource starts with the server. Elsewhere: `ensure opslabs-bodycam`
   after your framework and (optional) `oxmysql`.
2. Copy `config_server.example.lua` to `config_server.lua` (kept out of git) and set:
   - `XonSight.Url` / `XonSight.Key`: the portal and its `XONSIGHT_WEBHOOK_KEY` (header `X-XonSight-Key`)
   - `Storage.Dir` / `Storage.PublicUrl`: where the videos are written and their public https address
3. The videos are written to `<resource>/media` (FXServer only lets a resource write inside resource folders).
   **Publish that folder with a web server from disk — never through FXServer** (sending video from a resource
   crashed the game server). nginx can't read under `/root`, so bind-mount the folder somewhere it can:
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
   and set `Storage.PublicUrl` to that address.
4. With `oxmysql` the table `opslabs_bodycam_recordings` is created by itself. Recordings the portal didn't take
   (down, wrong key) are sent again every 2 minutes, up to 10 times.

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

## Voice (OPS Voice bridge)

`/opt/opsvoip-bridge/recorder.js`. When an officer starts recording, `server/audio.lua` tells the bridge
(`opsvoip_url` / `opsvoip_key`, the OPS Voice convars); a listening bot (`OPSBodycam-…`, allowed by the guard) joins
their pma-voice channel (`Player(src).state.assignedChannel`) and keeps every voice frame it hears. The client marks
the moment each video part starts; when the part is saved, the bridge cuts that window, mixes one Ogg Opus stream per
speaker with ffmpeg (`/opt/opsvoip-bridge/bin/ffmpeg`, static) and writes video + voice to
`/var/lib/opsvoip-bridge/bodycam/` (nginx: `/opslabs-bodycam/av/`). The evidence link points to that file and the
silent one is deleted (`ServerConfig.Audio.KeepSilentCopy`). If the bridge is down or a mux fails, the silent video
goes to Xon Sight as before. Bridge tests: `cd /opt/opsvoip-bridge && node --test test/*.test.js`.

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

- Evidence ids start at `XonSight.EvidenceIdOffset` (1 000 000) so they never collide with another source on the
  same portal. The portal's live roster is replaced on every sync, so **one game server per portal** for `/live`.
- Recording costs some client FPS (one extra draw + VP8 encode at 960×540, 20 fps). Lower `Config.Video` on
  weak PCs. A player who disconnects mid-part loses that part.
