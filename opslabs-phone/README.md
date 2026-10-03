# opslabs-phone

**OPS OS** smartphone for ESX Legacy. It has its own database tables, a REST API, and outgoing webhooks for a companion website.

## Install

1. The resource lives in `resources/[rps]/opslabs-phone` and starts with `ensure [rps]`.
2. **Disable the old phone** so the two don't fight over F1 and the `phone` item:
   move `[standalone]/sd-phone` out of the `[standalone]` folder (or add `stop sd-phone` after `ensure [standalone]`).
3. Requirements: `es_extended`, `oxmysql`, `ox_lib` (all installed). Optional: `pma-voice` (call audio).
4. Start the server. The tables are created automatically, so there's no SQL to import.

Open the phone with **F1** (rebindable) or `/phone`, or use any phone item. You need one of the items listed in `Config.Items`, and the item decides the frame colour.

## Database

All data lives in `opslabs_phone_*` tables in the server database:

| table | contents |
|---|---|
| `opslabs_phone_users` | phone number, email, settings per character |
| `opslabs_phone_contacts` | contacts, favourites, blocked numbers |
| `opslabs_phone_messages` | text messages and attachments (location, image) |
| `opslabs_phone_calls` | call history |
| `opslabs_phone_notes` | Notes app |
| `opslabs_phone_photos` | Photos library |
| `opslabs_phone_mail` | Mail app |
| `opslabs_phone_chirp_*` | Chirp social feed (profiles, posts, likes) |
| `opslabs_phone_bank_transactions` | Wallet transaction log |
| `opslabs_phone_service_requests` | 911 / service dispatch |

## Apps

Phone (favourites, recents, contacts, keypad, voicemail, live calls via pma-voice), Messages (chat bubbles, live location, photos), Contacts (OpsDrop to nearby players), Mail, Camera, Photos, Notes, Calculator, Clock (world clock, alarms, stopwatch, timer), Weather (live game weather), Maps (GPS waypoints, share location), Wallet (bank, cash, transfers by phone number, pay `esx_billing` bills), Settings (dark mode, wallpapers, ringtones, brightness, display zoom, Face Unlock & passcode), Chirp, Garage (`owned_vehicles`), Services (911/912/913/914 dispatch with GPS for police/EMS/mechanic/taxi), Calendar.

Device features: lock screen with Face Unlock (on raise) or passcode, Dynamic Island (live call timer, incoming calls, silent mode), Control Center, Notification Centre, notification banners that make the phone peek up when it's put away, swipe-up home gesture, swipe-back navigation, and the hardware buttons (Action button = silent mode, volume, power = lock, Camera Control = camera).

### Live location

Share your live location from Messages (**+ → Share Live Location**), from a contact card, or from Maps, for 15 minutes, one hour, or until you stop. The person you share with sees:
- a live map card in Messages that moves with you, showing how long ago it updated and how far away you are,
- you as a moving green marker in their Maps app, under **People**,
- a **"Live: Name" blip on the in-game map** that follows you. **Follow** keeps their GPS route updated to your position; **Directions** sets the waypoint once.

Your client reports your position every `Config.LiveLocation.Interval` ms, so OneSync isn't required. A location arrow appears in your status bar while you're sharing. Sharing ends when it expires, when you stop it, or when you disconnect or switch character.

### Auto-Lock

Settings → Display & Brightness → Auto-Lock sets how long the phone stays unlocked after you put it away: Immediately (default), 30 seconds, 1 minute, 5 minutes, or Never. The side button always locks immediately. While you're in a call the phone stays unlocked, and it locks once the call ends.

### Gestures

- **Home bar:** swipe up = home; swipe up and pause = **app switcher** (live cards: tap to open, swipe a card up to quit); swipe sideways = previous / next app.
- **Apps keep their state** when you leave them and resume where you were. Camera, Maps, Clock and Developer restart fresh because they run live loops.
- **Top edge:** swipe down on the left = Notification Centre, on the right = Control Centre; tap the status bar = scroll to the top.
- **Home screen:** swipe down = Search (apps and contacts); long-press an icon = quick actions (Edit Home Screen, Remove App); keep holding or drag = jiggle mode, where you drag icons to rearrange them (saved per phone), with **+** (Store) and **Done** buttons.
- **Lock screen:** swipe up = open; swipe left = Camera, without unlocking.
- **Lists:** swipe a row left for **Delete** (Messages, Mail, Notes, music library), or swipe all the way to delete straight away.
- **Also:** swipe from the left edge = back; drag a sheet down from its header = close; swipe between photos; swipe a photo down = close.

### Dynamic Island

Live activities for calls, music (local or Spotify), timers, the stopwatch, live-location sharing and following a friend on GPS.

- The most important activity shows compact around the camera, and a second one appears as a bubble beside it.
- **Tap** opens the app. **Long-press** expands the activity with controls: answer or end a call, play / pause / skip music with progress, pause or cancel a timer.

### Music apps (Soundwave & Tide)

Players install them from the OPS OS Store (they aren't installed by default). Both play direct audio links (mp3/ogg/aac/m4a), internet radio and YouTube links, with playlists, liked songs, a now-playing screen, and controls on the lock screen, in Control Centre and in the Dynamic Island. Music keeps playing when the phone is put away and pauses for calls.

- The built-in radio stations (SomaFM) are set in `Config.Music.Stations`. Rename the apps in `Config.Music.Apps`.
- Audio is heard by the player only.

### Spotify & TIDAL accounts

Players can link their real accounts. **Connect** opens their own browser on the official Spotify / TIDAL sign-in page, and tokens are stored on the server only.

- **Spotify (in Soundwave):** shows your playlists, liked songs, recently played and search results. Playback uses **Spotify Connect**: music plays through the Spotify app on the player's PC or phone and is controlled from the in-game phone, Dynamic Island, lock screen and Control Centre.
  - Spotify only lets **Premium** accounts control playback.
  - Spotify doesn't allow its audio inside other apps, so it can't play through the game itself.
- **TIDAL (in Tide):** sign-in and catalogue search. TIDAL's public API has no playback control, so tracks open in TIDAL.

**Setup (once):**
1. **Public URL:** you need an https address that reaches this server's port 30120. Either use the cfx.re address txAdmin shows (`https://yourname-xxxxx.users.cfx.re`) or your own domain behind an https reverse proxy. Put it in `ServerConfig.OAuth.PublicUrl` in **config_server.lua**.
2. **Spotify:** at developer.spotify.com/dashboard, create an app with the **Web API** and add the Redirect URI `<PublicUrl>/opslabs-phone/oauth/spotify/callback`. Copy the Client ID and Secret into `ServerConfig.OAuth.Spotify`.
   - While the app is in Spotify's *Development mode*, only accounts you add under **User Management** (up to 25) can sign in. Apply for *extended quota* to open it to everyone.
3. **TIDAL:** at developer.tidal.com, create an app with the Redirect URI `<PublicUrl>/opslabs-phone/oauth/tidal/callback`. Copy the Client ID (and Secret, if given) into `ServerConfig.OAuth.Tidal`.
4. Run `refresh` then `restart opslabs-phone`. The Connect buttons only appear once a provider is configured.

### OPS OS Store

The **OPS OS Store** (home label "OPS Store") lets players remove and reinstall apps. It has **Today** (featured apps), **Apps** (by category) and **Search** tabs, and each app has its own page with **GET → download → OPEN**.

- System apps are built in and can't be removed: Phone, Messages, Contacts, Mail, Camera, Photos, Settings, Services, Developer and the Store.
- Wallet, Chirp, Maps, Weather, Clock, Notes, Calendar, Calculator and Garage can be removed, either from the Store or by long-pressing the home screen (jiggle mode) and tapping **−**.
- Removed apps disappear from the home screen and send no notifications. Opening one from an old link goes to its Store page.
- Choices are saved per phone. Every app starts out installed.

### Developer app

The **Developer** app is on every phone (second home-screen page), but it only works after signing in. The login is set in **`config_server.lua`**:

```lua
ServerConfig.DevLogin = {
    Email = 'opsphone@ops.com',
    Password = '2026',
    MaxAttempts = 5,      -- wrong tries before a lockout
    LockoutSeconds = 60,
}
```

That file is server-only, so players can't read the password from their game files (`config.lua` is sent to every client). A sign-in lasts until the player taps **Log Out**, switches character or disconnects. Every Developer action is checked on the server, and logins and lockouts are printed to the server console.

- **Map Locations:** add a location at your position (or type in coordinates), and pick a name, category and icon. You can optionally show it as a blip on the GTA map for everyone, with your choice of sprite and colour. It appears in every player's Maps app instantly. Tap a location to edit, set GPS, teleport, copy its coordinates, or delete it. Stored in `opslabs_phone_places`.
- **Coordinates:** live x/y/z/heading plus street and zone. Copy as `vec3`, `vec4` or JSON, or save straight to a map location.
- **Teleport to Waypoint.**
- **Wallpapers:** add image-URL wallpapers that everyone can pick in Settings (`opslabs_phone_wallpapers`).
- **Phone Numbers:** search players and change a number. Messages, calls and contacts move with it.
- **Broadcast:** send a notification to every phone.
- **FPS meter:** a debug overlay for checking UI performance.

### Performance

Expensive live blur is limited to small, static elements, and animations only move layers (no repaint per frame). The phone stops painting entirely while it's put away, and it opens without waiting for the server. Players on low-end PCs can also turn on **Settings → Accessibility → Reduce Transparency / Reduce Motion**.

### Camera

The Camera app works like the real one: the live view is shown inside the phone (read straight from the game view, no `screenshot-basic` needed), with Video / Photo / Portrait, .5× 1× 2× 5× lenses (scroll to zoom), selfie camera, flash Auto/On/Off, timer, 4:3 / 1:1 / 16:9, exposure, grid and photographic styles. Drag the viewfinder to aim, tap to focus (Portrait uses real depth of field), hold for AE/AF lock. Take a picture with the shutter, Space/Enter, the volume buttons or Camera Control. It also opens from the lock screen (swipe left) without unlocking.

Photos (jpg) and videos (webm, up to `Config.Camera.MaxVideoSeconds`) are uploaded to this server, stored in `opslabs-phone/media/` and served from `ServerConfig.OAuth.PublicUrl` (or the cfx.re address), so that address must be reachable over https. Deleting one in Photos also deletes the file once nothing else (a message, a Chirp post, a wallpaper) still uses it. The resource serves the files itself; behind nginx, allow large uploads with `client_max_body_size 64m;` on the phone's location.

### Preview the UI in a browser

Open `html/index.html` directly in Chrome. It runs on built-in mock data, so you can work on the design without the game. In the browser console, `Mock.incomingCall()` and `Mock.message()` simulate events.

## First-time setup

The first time a character opens the phone, the **Setup Assistant** runs: Hello → Language → Region → Name → Phone number (keep the assigned one or pick an available number) → **OPS ID** email (`name@opslabs.cloud`) → Face Unlock & passcode → Appearance → a quick **performance test** of the player's PC that picks Ultra, Balanced or Performance → Done.

Players who already had a phone also see it once, pre-filled with their current number and email.

- **Languages:** English, Español, Français, Deutsch, Português. System screens, app names, Settings and common buttons are translated; messages, notes and other player-written text are never touched.
- **Units & Formats:** each one is the player's own choice, independent of language: temperature (°F / °C), distance (miles / km), speed (mph / km/h), weight (pounds / kg / stone), time (12 / 24-hour), date (MM/DD/YYYY, DD/MM/YYYY, YYYY-MM-DD) and first day of the week. Defaults for new phones are in `Config.DefaultUnits`; players change them in **Settings → Units & Formats**.
- **Region:** number formatting only (Settings → Language & Region).
- **Performance:** **Settings → Performance** reruns the test and switches profiles. The phone draws at the game's frame rate; lighter profiles make each frame cheaper so it holds 60 fps or more on slower PCs.

### Email domain

Addresses use `Config.MailDomain` (default `opslabs.cloud`). Signed-in developers can change it in-game in **Developer → Email Domain**, optionally moving every existing address and its mail history to the new domain.

### Load speed

Fonts and icons ship with the resource (no CDN). Phone data is preloaded when the character loads, so the first open is instant. Apps render from an in-memory cache in the same frame and refresh in the background.

## Exports

```lua
-- server
exports['opslabs-phone']:GetPhoneNumber(source)
exports['opslabs-phone']:GetSourceByNumber('555-1234')
exports['opslabs-phone']:SendMessage('555-0000', '555-1234', 'Hello')
exports['opslabs-phone']:SendMail(sourceOrEmail, 'Maze Bank', 'Subject', 'Body')
exports['opslabs-phone']:Notify(source, 'Title', 'Body', 'appId', 'fa-bell')

-- client
exports['opslabs-phone']:OpenPhone()
exports['opslabs-phone']:ClosePhone()
exports['opslabs-phone']:IsPhoneOpen()
```

## REST API

Base URL: `http://<server-ip>:30120/opslabs-phone/api/v1`

Enable it by adding a secret of at least 24 characters to `server.cfg`:

```
set opslabs_phone_api_key "your-long-random-secret"
```

Send the key with every request as `Authorization: Bearer <key>` (or `X-Api-Key: <key>`). Responses are JSON: `{ "data": ... }` on success, `{ "error": "..." }` otherwise. Browser origins allowed by CORS are set in `server/api_config.lua`.

| method | path | body / query | description |
|---|---|---|---|
| GET | `/health` | | status + version |
| GET | `/stats` | | totals (users, messages, calls, posts, mail, online) |
| GET | `/online` | | players with the phone loaded |
| GET | `/users` | `?search=&limit=&offset=` | list phones |
| GET | `/users/:number` | | profile, settings, character, online flag |
| PATCH | `/users/:number` | `{ number?, email?, settings? }` | change number/email (history is migrated), merge settings; reloads an online player's phone |
| GET | `/users/:number/contacts` | | contacts |
| POST | `/users/:number/contacts` | `{ name, number, email? }` | add contact |
| DELETE | `/users/:number/contacts/:id` | | delete contact |
| GET | `/users/:number/messages` | `?with=<number>&limit=&offset=` | messages / a single thread |
| POST | `/messages` | `{ from, to, message, from_name? }` | send a text (e.g. from a business line) |
| DELETE | `/messages/:id` | | delete a message |
| GET | `/users/:number/calls` | | call history |
| GET | `/users/:number/notes` | | notes |
| GET | `/users/:number/photos` | | photos |
| POST | `/users/:number/photos` | `{ url }` | add a photo to their library |
| GET | `/users/:number/mail` | | mail |
| POST | `/mail` | `{ to (email or number), from_name, from_email?, subject, body }` | send mail |
| POST | `/notify` | `{ number or "all", title, body, app?, icon? }` | push a notification |
| GET | `/chirp/posts` | `?limit=&offset=` | feed |
| POST | `/chirp/posts` | `{ handle, content, image? }` | post as a handle |
| DELETE | `/chirp/posts/:id` | | moderate / delete |
| GET | `/services/requests` | `?service=police` | dispatch log |
| PATCH | `/services/requests/:id` | `{ status: open, accepted or closed }` | update a request |

Example:

```bash
curl -H "Authorization: Bearer $KEY" http://127.0.0.1:30120/opslabs-phone/api/v1/stats
curl -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"number":"all","title":"Server","body":"Restart in 10 minutes"}' \
  http://127.0.0.1:30120/opslabs-phone/api/v1/notify
```

## Webhooks (website sync)

Add URLs to `ApiConfig.Webhooks` in `server/api_config.lua`. Every event is POSTed as:

```json
{ "event": "message.sent", "timestamp": 1790000000, "data": { ... } }
```

Each request has an `X-OpsLabs-Event` header, plus `X-OpsLabs-Secret` when you set `set opslabs_phone_webhook_secret "..."` in `server.cfg`.

Events: `user.created`, `message.sent`, `call.ended`, `mail.sent`, `chirp.posted`, `bank.transfer`, `service.request`.
