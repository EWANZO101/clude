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

### Battery

The battery is real (`Config.Battery`). It drains slowly in your pocket, faster with the phone open and fastest in a call, and it **only
charges on a live charger**: stand beside a phone **charging cable**, a **wireless pad / stand** or a **USB socket** (opslabs-towers mains kit,
plugged into a live socket) — the status bar shows a bolt — or use a **power bank** item.

- At **0 %** the phone switches off: it won't open, notifications don't pop up and it can't be called. It turns back on as soon as it charges.
- Low battery warnings at 20 %, 10 % and 5 %. **Settings → Battery** shows the level and whether it's charging.
- **Power banks:** using a `powerbank` adds 50 % over about 12 minutes and leaves a `powerbank_empty`; use the empty one beside a live charger
  to recharge it (60 s). Both items are added to the ESX `items` table automatically; give them out however you like (shops, admin).
- The level is kept per character and survives reconnects.

### Wireless charger dock

Walk up to a **wireless charging pad or stand** (opslabs-towers, `/towers` → SAPL → Plug-in devices & chargers) and press **E**
(`Config.Dock`). The phone leaves your inventory and **lies on the charger** as a prop everyone can see: screen-up on the flat pad, leaning
back on the stand. The lock screen lights up with "Charging" while the charger has power and goes dark when it doesn't.

- It **charges wirelessly** there wherever you go, and it's still your phone: it rings, gets messages and shows notifications.
- **Use it on the charger:** press F1 while you're within `UseDistance` (2.2 m). No phone in your hand. Walk away and the screen closes.
- **E** beside it picks it back up into your inventory. With `OwnerOnly = false` anyone can take it.
- Calls on a docked phone are on speaker. With OPS Buds in, you can answer it from across the room (see below).
- `Auto = true` puts the phone down by itself when you stand still beside a free charger.
- Docked phones are kept in a resource KVP: they stay on the charger across disconnects and restarts until the owner picks them up.
- Needs the `opslabs_phone_dock` / `_on` models from opslabs-props (otherwise `Config.Prop` is used) and opslabs-towers' `WirelessChargerNear`
  / `GetFixture` exports.

### OPS Buds

`ops_buds` is a pair of wireless earbuds in a charging case (`Config.Buds`, image `html/img/opsbuds_case.png`). They work like AirPods:

- **Use the item** to open the case. The first time, a **Connect** card slides up on the phone. After that, opening the case shows the
  battery card and the buds go in your ears. The Dynamic Island shows "OPS Buds" with a battery ring when they connect. **Use it again** to
  take them out. Other players see a bud in each ear.
- **Batteries:** left, right and case. Buds last about 6 hours of listening, recharge in the case (≈ 15 min), and the case charges beside any
  live charger (cable, pad or USB socket). Low-battery notifications at 20 % and 10 %.
- **Noise Control** (Settings → Bluetooth → OPS Buds, a Control Center tile, or hold the buds key): **Noise Cancellation** mutes the world
  around you (a GTA audio scene, voice chat isn't affected), **Adaptive** does the same but lets gunfire and explosions through, and
  **Transparency** / **Off** leave everything as it is.
- **Conversation Awareness:** your music drops while you talk on voice chat.
- **Automatic Ear Detection:** taking them out pauses your music, and putting them back in within a minute carries on. Losing the connection
  (out of range of a docked phone, flat battery, Bluetooth off) also pauses it.
- **Hands-free calls:** with the buds connected you don't hold the phone to your ear.
- **Press control** (`Page Up`, rebind under Settings → Key Bindings → FiveM → "OPS Buds"): press to play / pause or answer / hang up, press twice
  for the next track, three times for the previous one, hold for Noise Control.
- **Range:** if your phone is on a charger, the buds stay connected within `Range` (12 m).
- Settings → Bluetooth lists them under My Devices, with rename and Forget This Device. Batteries and settings are saved per character.
- The item is added to the ESX `items` table automatically; for ox_inventory / qb add the entries from `items/`.

### OPS SafeMag

`ops_safemag` is a magnetic battery pack for the back of the phone (`Config.SafeMag`, `client/safemag.lua`, `server/safemag.lua`, image `html/img/ops_safemag.png`). It works like a MagSafe battery pack:

- **Use it** from the inventory to snap it onto the phone; use it again to take it off. Dropping or giving the item away takes it off too.
- **Snapping it on** peeks the phone up, and the Dynamic Island shows the pack's level next to the phone's level with a charging bolt.
- **While it's on** it charges the phone wirelessly from its own battery (`Charge` % per minute, costing `Cost` pack % for each phone %), up to `StopAt`.
- **Recharging:** on a charger (cable, wireless pad, USB socket or a dock) the phone charges first and the pack once the phone is nearly full. A pack that's off the phone charges beside any live charger.
- Its level and whether it's on are saved per character in the phone settings (`safemag`).
- **Model:** while the phone is in your hand, the pack (`opslabs_safemag` from opslabs-props) sits on its back, networked so everyone sees it. It's fitted to `Config.Prop` automatically from the model's size. If it lands on the screen side, run `/safemagside` and copy the printed `side` into `Config.SafeMag.Attach`; `flip`, `offset`, or `pos` + `rot` fine-tune it.

**Batteries widget:** once a player owns OPS Buds or a SafeMag, page 1 of the home screen gets an iPhone-style Batteries widget. It shows the phone, the SafeMag, the buds and the case, each with a level ring and a bolt while charging, and takes the place of four app icons. Players can hide it in Settings → Battery; `Config.BatteriesWidget = false` turns it off for everyone.

### Laptop (OPS OS desktop)

Engineers place an **OPS laptop** (`/cable` → OPS Openline → Telecom equipment → Customer premises · inside → *Laptop*) on a desk, and anyone can walk up and press **E** to use it. OPS OS opens as a desktop with a menu bar, a dock and windows. The same apps run in the windows, with the same accounts as your phone: Ops-Networks, OPS Mobile, Mail, Messages, Contacts, Notes, Calendar, Wallet, Chirp, Maps, Photos, Garage, Services, Weather and Calculator. There's also a **Network** panel.

- **Battery:** the laptop runs on its battery (shown in the menu bar) unless a live **laptop charger** sits beside it. A flat laptop won't start.
- **Ethernet only:** the laptop has no Wi-Fi or mobile signal. It's online when a CAT6 cable, terminated at both ends, runs from its port to a router / switch / AP that has an uplink (cabled through to a gateway), or straight into an ONT with an active service. Unplug or cut the cable and every window is covered with *Cable unplugged* / *No internet* until it comes back. The server refuses online requests from an offline laptop as well.
- **No mobile plan used:** texts and apps on the laptop don't use plan allowance or data. Laptops can't make voice calls, and your phone still rings while you're at one.
- **Network panel:** link speed, what it's plugged into, gateway, IP / router / MAC, the broadband provider and plan behind it, a speed test, and a plain-language reason when it's offline.
- **Windows:** drag by the title bar, resize from the corner, double-click the title bar or press the green button to maximise, yellow minimises, red closes. Links between apps (e.g. *Message* on a contact) open another window, and notifications show as banners at the top right.
- **Esc** or the power button leaves the laptop (you also leave it by walking away). Your windows are still there next time on the same laptop.
- Browser preview: `Mock.laptop()` in the console opens it; `Mock.unplug()` / `Mock.plugIn()` change the cable.

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

### Browser — the in-game internet (`server/web.lua`, `html/js/apps/browser.js`)

A real web for the city, on the phone (mobile data) and on laptops (Ethernet). Tables: `sql/ops_web.sql` (created on start); prices, endings and plans: `sql/ops_catalog.json` → `web`. Staff manage everything on OPS Hub → **Web & Domains**.

- **OPS Search** (`ops.sa`) indexes every published site (title, description, keywords and page text) plus the OPS sites.
- **OPS Domains** (`opsdomains.sa`): search and register `.ls .sa .biz .shop .club` (`.gov.sa` is for government / emergency services, registered by staff), renew, auto-renew, WHOIS privacy, transfer lock + transfer codes, a full DNS editor (A, AAAA, CNAME, MX, TXT) and WHOIS lookup.
- **OPS Web** (`opsweb.sa`): hosting plans (Starter / Business / Pro), a block-based site builder (header, text, image, features, menu/price list, gallery, contact form, opening hours, links, quote, call to action, divider; up to 8 pages, colours, light/dark, fonts), one-click “connect domain” (sets the DNS), free SSL with hosting, mailboxes on your domain, and paid services (*build my site*, *set up SSL*, *set up email*) that become OPS Web jobs, checked automatically when the employee completes them.
- **How a page loads** — DNS first: unknown names get `DNS_PROBE_FINISHED_NXDOMAIN`; expired / suspended domains show a parked page. `A 198.18.10.80` is OPS Web hosting. Pointing at your own **OPS Network static IP** self-hosts the site: the line must be up (else `ERR_CONNECTION_TIMED_OUT`) and the router must forward port 80 and/or 443 (else `ERR_CONNECTION_REFUSED`); with no site on that IP you get the server’s “It works!” page.
- **HTTPS** needs a valid OPS Trust CA certificate for the name (DV / OV / EV / wildcard). Without one the site is “Not secure”; typing `https://` to a site with a missing, expired or revoked certificate shows the full-page warning (with *Proceed anyway*).
- **Email** — a mailbox (`info@yourname.ls`) delivers into a phone’s Mail app and can be picked as the sender; mail to an address that doesn’t exist, a domain without an MX record or an expired domain bounces back from the Mail Delivery Subsystem.
- **Billing** every `periodDays`: domains renew from the owner’s bank (warning mail first); unpaid → expired (site and mail stop) → released after `graceDays`. Hosting unpaid → overdue → suspended. Free certificates renew with the hosting; others expire.
- Sites are data only — the builder’s blocks are sanitised on the server and rendered with escaping, so no player HTML or script ever runs in anyone’s phone. Images must be `https://` links.
- Uses data (`Config.Carrier.DataCost`: `webBrowse`, `webSearch`, …).

### OPS Cloud (`server/cloud.lua`, console at `opscloud.sa`)

Virtual servers (Nano → X-Large, images: OPS Web server, Ubuntu, Debian, Rocky, Windows Server) with a public IP from `198.18.20.0/24`, a firewall (open ports), snapshots / restore, resize, start / stop / reboot and a console log, billed every period. They run on OPS Data hardware (opslabs-towers `server/datacentre.lua`): a VM is only up while a healthy host in its region has room for it. Host a website on a VM: create the site on opsweb.sa → *host it on* the VM's IP (or *Move to another server…* for an existing one), open 80 / 443 — the browser then serves it from the VM. *Set up my server* and *Migrate my website* are paid OPS Cloud jobs, checked automatically. `sql/ops_cloud.sql`; plans in `sql/ops_catalog.json` → `cloud`.

### OPS business layer (`server/business.lua` · OPS Hub → each company's tabs)

Quotes, contracts, stock, assets, certifications, fleet and support for every OPS company. Tables: `sql/ops_business.sql`; stock lines, parts per job, suppliers, certification exams, SLA tiers and contract types: `sql/ops_catalog.json` → `business`.
- **Quotes → work orders:** staff build a quote on OPS Hub from job types, stock items, contracts and free lines, then send it. The customer accepts it in OPS Work → *Quotes, contracts & warranties* or in the website's customer portal. Accepted quotes become jobs (with the price agreed), and contract lines become contracts.
- **Contracts & SLAs:** billed every period. A job for a customer gets a due time: the contract's response hours, otherwise the customer's SLA tier, and 4 h for emergencies. Overdue work raises SLA alerts, and SLA performance shows on the dashboards. *Support* contracts cover repairs; *Managed* covers everything.
- **Stock & purchasing:** completed jobs take their parts from the company's stock. Low stock raises alerts. Purchase orders to suppliers are paid from the company account and arrive after the supplier's lead time.
- **Assets & warranty:** kit fitted on a job is registered to the customer with a serial and a warranty. Repairs to kit still under warranty are free.
- **Certifications:** installation job types need a certification. Staff take the exam in OPS Work → *Training*, and managers can grant or revoke on OPS Hub.
- **Fleet & tools:** company vans (spawned at the nearest road from OPS Work → *My van & tools*, mileage logged) and tools (issue, condition, calibration).
- **Support tickets:** from OPS Work → *Support* or the customer portal. Staff reply, close or book a job from the ticket on OPS Hub, and the customer is notified in game.
- **Alerts:** low stock, SLA, unpaid contracts, new tickets, certifications expiring and vans due a service. Managers get them on the phone, and they're listed on OPS Hub → *Alerts* and the *Operations centre*.

### Training, job assistant, health & safety, live settings (`server/training.lua`, `server/settings.lua`, `server/admin.lua`)

See `../OPS-SETUP.md` for the overview. In short:
- **Content:** `sql/ops_guides.json` holds 21 job families covering every job type: equipment, tools & PPE, steps (each with an animation key), hazards & controls, mistakes & consequences, a safety quiz and an exam. It also holds 12 system explainers for the OPS Hub classroom.
- **OPS Academy (learn anywhere):** the `academy` app (`html/js/apps/academy.js`, phone + laptop dock), the Browser site `opsacademy.sa` (`web.lua` internal page, `browser.js` `BrInternal.academy`) and OPS Hub → Classroom all read `sql/ops_guides.json`. `opsAcademy` / `opsLesson` / `opsSystem` / `opsSlides` need no login; quizzes, exams and the practical do. Progress is shared everywhere.
- **Certification:** exam ≥ `Work.PassMark`, plus the practical at a `Work.TrainingCentres` spot when `Work.RequirePractical` is on. Each family's safety module is needed before its jobs (`Work.RequireSafetyTraining`). Records: `ops_training`, `ops_member_certs`.
- **Job assistant:** OPS Work → the job → *Guide me*, or `/jobhelp`. Risk assessment (`Work.SafetyBriefing`) is needed before work and before completing; skipped controls can cause incidents (`Work.SafetyIncidents`, logged in `ops_incidents`). On-site work runs the family's steps with their animations (`Work.Anims`).
- **Items mode:** `Work.Mode = 'items'`, with depots, `ModelItems` and the definitions in `items/`.
- **Live settings:** `ops_settings` overrides any `Config` value (OPS Hub → Settings, OPS Work → Admin settings) within 15 s. Clients get them via `GlobalState['opscfg:<resource>']`. Defaults and comments are published to `ops_config_dump`. Job types are edited in `ops_job_overrides` (live within 30 s). Catalogue sections (`catalog:<section>`) are written into `sql/ops_catalog.json` on start, so they apply after a restart; the original is kept as `sql/ops_catalog.default.json`.

### Emergency Alerts (`server/emergency.lua`, `client/emergency.lua`, `html/js/apps/alerts.js` · OPS Hub → Emergency alerts)
Wireless-Emergency-Alert style alerts that take over the screen with the alert tone (extreme and severe alerts sound
even in Silent mode / Do Not Disturb). Four levels: Extreme, Severe, Warning, Information; sent to the whole city, to
everyone within a radius of a place (the area shows on the map, and people who walk in while it is live get it too), or
to a company's staff. Live alerts reach players who come online later as well.

It is a **premium per company**: a Hub admin ticks *Emergency Alerts (premium)* on the company in OPS Hub → Settings →
Companies. Members whose role has `alerts.send` (owner, director and manager by default) can then send and cancel alerts
from the phone's **Alerts** app or from OPS Hub → Emergency alerts. Players choose which levels sound in the app (extreme
is always on). Tuning: `Config.Emergency` (cooldown, live alerts per company, radii, durations, map blip). The table is
`ops_emergency_alerts` (`sql/ops_emergency.sql`); OPS Hub needs `migrations/2026-10-08-emergency.sql` once for its grant.

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

## OPS Traffic and Sparks

**OPS Traffic** (`Config.Traffic`): live incidents across the state — accidents, road closures, fires, shots fired (OPS Sentinel sensors), active police pursuits (10-80), hazards and planned work (street works sites, planned network outages, crews on site). Players report what they see; the same thing reported nearby adds a confirmation; "still there" / "it's gone" votes keep or clear reports. Hard crashes and nearby fires are reported automatically. Police (`PoliceJobs`) start and end 10-80s — the lead unit's position updates live — and close roads (also `ClosureJobs`). Phones within `AlertRadius` get a notification (players choose which kinds in the app). Other resources can add incidents with `exports['opslabs-phone']:ReportTrafficIncident(kind, x, y, z, detail, street)`.

**Sparks** (`Config.Dating`): dating — a profile per character (18+, photos from the library, bio, job, area, interests, who you want to see), a swipe deck, a match when the like is mutual, private chat, unmatch and report (reports are printed to the server console and stored in `opslabs_phone_dating_reports`).

