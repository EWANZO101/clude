# opslabs-towers

Cell towers and Wi-Fi access points for **opslabs-phone** (OPS Mobile coverage).

- Saved in the `opslabs_towers` table. **None are created automatically** — you place every one (in game or on the website) and deletions stick across restarts.
- Every 1.5 s the server works out each player's signal (0–4 bars, 5G/LTE) and best Wi-Fi and pushes it to their phone.
- **No signal:** texts and calls fail — only calls to emergency numbers (911 etc.) go through. Apps need signal or Wi-Fi. Calls drop when either side loses signal; phones with no signal can't be called.
- **Wi-Fi:** apps work with no signal and no plan, and don't use plan data. Reaches `Config.Wifi.FloorTolerance` m above/below the access point.
  - **Passwords:** set one and phones see a lock; players enter it once in Settings › Wi-Fi and rejoin automatically (remembered per character in `opslabs_towers_wifi_known`). Changing the password logs everyone out. "Forget This Network" on the phone.
  - **Job-locked networks** (`jobs = police,ambulance`) show as restricted to everyone else.

## In game — `/towers`
Admins: ESX groups in `Config.AdminGroups`, licenses in `Config.AdminLicenses`, or ace `opslabs.towers`. The menu stays open until Esc / Backspace / ✕.

- **Place cell tower / Wi-Fi access point** — fill in the details, then **aim** where it goes (see below).
- **Nearby towers** → a tower: teleport, take offline (outage), edit (name, range, SSID, password, jobs, prop), **Move (aim & place)**, move to my feet, delete.
- **Bulk actions** — pick several from a list to delete / take offline / bring online, or delete all offline, all Wi-Fi, all cell, or everything.
- **Coverage overlay** — range circles on the map + 3D markers.

**Aim & place:** a see-through preview follows where you look (snaps to floors, desks, shelves, ceilings). Scroll or Q/E rotate · ↑/↓ raise/lower · Shift fine · LMB/Enter place · RMB/Backspace cancel. Props placed this way stay exactly where you put them.

**Props:** cell towers can show a satellite dish, rooftop antenna or radio mast (`Config.Cell.Props`); Wi-Fi can show the **UniFi access point** (ceiling or desk, from the `opslabs-props` resource), a USB dongle, hand radio, router, mini PC, laptop… (`Config.Wifi.Props`). Models missing from the game are hidden automatically.

## Network cabling — `/cable`
Visible to everyone, saved in the DB (`opslabs_towers_cable_boxes`, `_cables`, `_fixtures`). Also under `/towers` → Network cabling.

- **Cable boxes:** CAT6 (305 m), fibre black outdoor dropwire (1000 m) or fibre yellow indoor patch (500 m). Every run is pulled from a box. **Cable boxes** lists nearby boxes: teleport, remove one, remove all empty, or remove all nearby.
- **CAT6 (black, 8 mm):** pull from the box and fix it point by point along walls, floors or ceilings (LMB), then aim at a router / AP and press Enter to plug in. Cut it off the box, then terminate each end (strip, untwist, arrange T568B, trim, crimp).
- **Fibre:** same pulling, then splice each end (strip, clean, cleave, fusion splice, heat-shrink sleeve).
- **Trunking:** white, black or blue. Cable laid into it disappears inside. Removing trunking leaves the cable on the wall.
- **Cut a cable:** aim anywhere along a cable, fibre or trunking (including spans hanging in the air) and cut it. You have to be within reach — use a ladder or climb the pole for overhead cable. It becomes two pieces with bare ends to terminate / splice.
- **Poles:** while laying, aim anywhere near a pole (up to 40 m away) and the cable clamps to it on the side it's coming from — near the top it goes on the ring head. Spans to and between poles hang with a natural sag.
- **Laying:** a see-through preview of the next piece follows your aim; points within 4 cm of the last one's height snap level; hold **Shift** for a dead-straight level or vertical line.
- **Move cable, trunking or a box:** aim and click. A box is carried with aim & place (cable still on it pays out from the box). A run opens the route editor: drag points, **E** adds a bend on the line, right-click removes one, Enter saves. Ends on a box or plugged in stay fixed; a run on its box pulls cable off it, a cut piece can't stretch beyond its length.
- **Remove cable, trunking or a box:** aim (it outlines red) and hold for half a second. **Z** puts back your last removals (last 20, until restart). Bulk-remove all trunking / all cable within 60 m from **Nearby cables & trunking**.
- **Telecom equipment:** wooden poles at 7, 10 and 13 m, CBT, copper DP, splice enclosure, PCP cabinet, FTTC cabinet, carriageway cover, CSP, ONT.
- **Climbing poles:** stand at the base of a placed pole and press **E**. W / S climb (feet and hands working up the steps), A / D move round the pole, **X** climbs down. Stop and your feet settle onto the nearest pair of pole steps; above 1.5 m your hands start working in front of you. **G** opens the pole menu: mount a CBT, copper DP or splice enclosure at your height on your side of the pole (refused if something is already fitted there), or remove one next to you. Mounted kit is strapped on with stainless bands sized to the pole and has no collision. Anyone can climb unless `Config.Cabling.ClimbJobs` lists jobs; fitting / removing equipment needs cabling access. Items marked `pole = true` in `Config.Cabling.Equipment` can be mounted.
- **Extension ladders:** `/ladder` (or Network cabling → Place an extension ladder) and pick the size: **3.6 m → 6.9 m** or **6.8 m → 13 m**. Aim at the wall or pole where the top should rest — the feet are worked out on the ground at the 1-in-4 angle and it extends to reach (it tells you if it's too short) — or aim at the ground to put the feet there. The preview outlines green / red with a ring where the feet go and a marker at the top. Q / E rotate, ↑ / ↓ extend. At the foot: **E** climb, **H** extend / retract, **G** pick it up. Everyone sees them; they aren't saved, max `LadderMaxPerPlayer` each.
- **Gateways** (internet uplink for `RequireUplink`): UDM Pro, Cloud Gateway Ultra, Omada ER605 / ER7206, TP-Link Archer and Deco.
- Placing and laying show a status card at the top of the screen and GTA-style key hints bottom right.

## Internet service (fibre broadband)
Street cabinets (PCP / FTTC) are the ISP's exchange. Light travels over **spliced fibre** through splice enclosures, CBTs and CSPs into an **ONT**; a **CAT6** run from the ONT to a router is its LAN. All of it comes from what's really cabled:

- When laying or splicing, aim at / stand next to the equipment and the end connects to it ("Connects to CBT", "Enter to connect to ONT").
- **Lights:** POWER · PON (blinks while ranging, then solid) · LOS (red: no light — a splice is missing back to a cabinet) · LAN (on when a router is plugged in, flickers with traffic) · INTERNET (blinks while authenticating, solid when the service is up, red when suspended).
- **Walk up to an ONT** and a panel pops up with the lights, provider, plan, sync speed, optical Rx (dBm, from fibre length, joints and splitters), fibre path, LAN device, PPP user and uptime. Walk away and it closes.
- **Provisioning:** Network cabling → Telecom equipment → the ONT → **Internet service**: pick provider & plan (`Config.Isp.Providers`), customer / address label, suspend / resume / cease. Engineers (cabling jobs) and admins only.
- `Config.Isp.RequireIspForGateways = true` makes gateways (UDM, ER605, Archer…) give internet only when cabled to a live ONT, so Wi-Fi depends on a real broadband line.
- Saved in `opslabs_towers_isp`. Export: `exports['opslabs-towers']:GetOntStatus(fixtureId)`.

## Website
`https://opsphone-store.opslabsystems.cloud/admin/towers` — live map with merged coverage, dead zones and players; KPIs incl. land coverage. Add by clicking the map, drag a tower to move it, edit everything incl. prop model and Wi-Fi password, select several for bulk actions. Same API key as the phone (`opslabs_phone_api_key`).

API (Bearer key): `GET /opslabs-towers/api/live`, `GET|POST /towers`, `PATCH|DELETE /towers/:id`, `POST /towers/bulk` `{ action: delete|offline|online, ids: [..] }` or `{ action, all: true, type?, offline? }`.

## Config
`Config.Enforce = false` keeps everyone at full signal while you build the network. Ranges, Wi-Fi floor tolerance, password length and prop lists are in `config.lua`.
