# opslabs-towers

Cell towers and Wi-Fi access points for **opslabs-phone** (OPS Mobile coverage).

- Saved in the `opslabs_towers` table. **None are created automatically** — you place every one (in game or on the website) and deletions stick across restarts.
- Every 1.5 s the server works out each player's signal (0–4 bars, 5G/LTE) and best Wi-Fi and pushes it to their phone.
- **No signal:** texts and calls fail — only calls to emergency numbers (911 etc.) go through. Apps need signal or Wi-Fi. Calls drop when either side loses signal; phones with no signal can't be called.
- **Wi-Fi:** apps work with no signal and no plan, and don't use plan data. Reaches `Config.Wifi.FloorTolerance` m above/below the access point.
  - **Passwords:** set one and phones see a lock; players enter it once in Settings › Wi-Fi and rejoin automatically (remembered per character in `opslabs_towers_wifi_known`). Changing the password logs everyone out. "Forget This Network" on the phone.
  - **Job-locked networks** (`jobs = police,ambulance`) show as restricted to everyone else.
  - **Only online when connected to the fibre network** (tick it in the access point's details): the network stays silent —
    phones don't even see it — until the AP is cabled (CAT6, through any switches / other APs) to a gateway whose WAN goes to an
    ONT with live fibre and an active service. Unplug or cut that chain and it drops off air. Leave it unticked and it works as before.

## In game — `/towers`
Admins: ESX groups in `Config.AdminGroups`, licenses in `Config.AdminLicenses`, or ace `opslabs.towers`. The menu stays open until Esc / Backspace / ✕.

- **Place cell tower / Wi-Fi access point** — fill in the details, then **aim** where it goes (see below).
- **Nearby towers** → a tower: teleport, take offline (outage), edit (name, range, SSID, password, jobs, prop), **Move (aim & place)**, move to my feet, delete.
- **Bulk actions** — pick several from a list to delete / take offline / bring online, or delete all offline, all Wi-Fi, all cell, or everything.
- **Coverage overlay** — range circles on the map + 3D markers.

**Aim & place:** a see-through preview follows where you look (snaps to floors, desks, shelves, ceilings). Scroll or Q/E rotate · ↑/↓ raise/lower · Shift fine · LMB/Enter place · RMB/Backspace cancel. Props placed this way stay exactly where you put them.

**Props:** cell towers can show a satellite dish, rooftop antenna or radio mast (`Config.Cell.Props`); Wi-Fi can show the **UniFi access point** (ceiling or desk, from the `opslabs-props` resource), a USB dongle, hand radio, router, mini PC, laptop… (`Config.Wifi.Props`). Models missing from the game are hidden automatically.

## Menus
`/towers` (admins) and `/cable` (engineers) open the same tidy menu — `/cable` just leaves out OPS Mobile:
**Guides** · **OPS Mobile** · **OPS Openline** (networking) · **StreamFibre** (networking) · **San Andreas Power & Light** (electricity) ·
**Buildings & sites** · **Road safety** · **Tools**. Back always returns to the menu you came from (client/menu.lua).
Telecom kit, power kit, buildings and the exchange's own power & cooling plant are kept apart; the pole menu (G) only offers
power kit on power poles and telecom kit on telegraph / metal poles; the ladder's wall menu only offers wall-mounted kit.

## Buildings & sites — `/towers` → Buildings & sites
Walk-in buildings you can put down anywhere (aim up to 90 m away, scroll to rotate, arrows for height) and walk into —
real collision, furniture, lights that come on inside, and doors.
- **Customer house** — 12 × 9 m: hallway, living room, kitchen, bathroom, two bedrooms; front & back doors.
- **Engineering depot** — 22 × 14 m: office, corridor, meeting room, kit room, lockers & WC, warehouse (racking, cable drums,
  workbench), roller-shutter bay, front & side doors.
- **Telephone exchange** — 16 × 10 m: entrance lobby, equipment hall, power room.
- **Saved for good** — every building you put down is stored in the database (`opslabs_towers_fixtures`) and comes back after a
  restart. **Buildings & sites** lists every placed building (any distance): open one to **Move** it (aim & place), **Fine-tune** it
  (arrows slide, PgUp / PgDn height, Q / E turn, Shift fine), **Set exact position** (heading / height), **Teleport to the front door**
  or **Remove** it (deleted for good, with its doors and PINs).
- **Underground chambers & tunnels** (Buildings & sites → Underground chambers & tunnels) — walk-in concrete structures that sit
  under the road or pavement; from above you only see the access hatch.
  - **Lay a tunnel line:** click the start (or an open end of an existing chamber / tunnel), aim at the end — a chamber at each end and a
    4 m tunnel section every 4 m, level with the start, previewed on the road. It warns you if the ground drops so far the tunnel would show.
  - **One by one:** chambers, tunnel sections or end walls. Aim near an open end and the piece joins on (hold Shift to place freely);
    it keeps placing until Backspace. Q / E turn, PgUp / PgDn depth.
  - **Getting in:** **E** at the hatch opens / closes it (**H** for its PIN keypad — lock it like any door), **F** at the open hatch
    climbs down the step irons; **F** at the foot of the step irons climbs back out. Lit inside, real collision.
  - Everything is saved and listed in the same menu (move, fine-tune, teleport, remove).
- **Doors** — every door has a keypad: **[E]** open / close, **[H]** keypad (lock, set or change the PIN, same PIN on every door).
  A locked door needs the PIN to open. 5 wrong PINs lock the keypad for 30 s. PINs are stored hashed on the server only.
  Engineers: open the building (Tools → Nearby equipment) → **Doors & PINs** to set one PIN everywhere or clear them all.
- **Security & fencing** — palisade or mesh fence panels (anthracite, green, galvanised), **branded fence panels** and
  **branded signs** (company, colour, message, phone — live text), fixed bollards. **Lay a fence line** puts panels or bollards
  down in a row with a preview.
- **Anti-climb zones** — along every fence panel, fence post and gate (Config.AntiClimb): within 1.4 m you can't jump, and any climb or vault over is cancelled and you're put back on the side you came from (“use the gate”).
- **Gates** — sliding gate 5 m, double swing gates 4 m (both with a brand board), pedestrian gate, car-park barrier and rising
  bollard. They **open by themselves** when you walk or drive up and close when you've gone. **Lock** one at its keypad and it
  stays shut — enter the PIN to get through once, or “keep it unlocked”.
- **Ladders** work on buildings: the ladder rests on the gutter / eave, can go over a roof edge, **F** at the top steps onto the
  roof, and **E** next to the ladder top on the roof climbs back down. A ladder too long for a pole won't lean on it.

## OPS Network van — `/opsvan` or `/towers` → Tools
A base van (Config.Van.Model, default `speedo`) dressed in OPS Network livery: branded sides, red / yellow chevrons on the back,
roof light bar and rear beacon pods, roof rack with a ladder. Every player sees it (state bag `opsvan`).
**K** (rebindable) — beacons on / off (alternating amber with real light). **[E] at the back doors** — van stores: tool kit,
ladder, cable box / drum, phone cable, road safety kit, fit / take off the roof spotlight. Use `/opsvan` again to send your van back.

**Roof spotlight** — a lamp head on a pan / tilt yoke, on a telescopic post that slides along a rail across the roof (fitted on new
vans; fit or remove it at the van stores). Press **L** (rebindable) from **any seat** to work it while you drive:
**← →** pan (all the way round) · **↑ ↓** tilt · **Shift + ← →** slide it side to side along the rail · **PgUp / PgDn** raise / lower the
mast · hold **Alt** and the head follows your camera · **Enter** light on / off · **X** park it · **Backspace** done. It's a real
spotlight with shadows, and everyone sees it move (`Config.Van.Spotlight`: key, position, travel, colour, range).

## Uniform — `/uniform`, `/towers` → Tools → Uniform, or the van's uniform locker
Navy work polo, navy work trousers and black work boots (base-game items, checked against the game's clothing names),
with printed **OPS Network** branding: a back print (signal mark, OPS / NETWORK, yellow rule, “FIBRE · POWER · MOBILE”) and a
small chest logo — transparent decals in a real font, so they look printed on the shirt — plus a white **hard hat** with the
logo sticker and a centre ridge (on / off from the menu). The branding **fits itself to the body**: it measures the bone
orientation in game and works out the exact rotation, so it sits square on any character; everyone sees it.
Taking the uniform off puts your own clothes back.
**Admins:** *Design the uniform* (pick every piece with ← → live, save for male / female) and *Adjust the branding*
(nudge a piece up / down, left / right, in / out with the arrows — Shift for fine — and save). Stored in `uniform.json`.

## Tool kit — `/toolkit`, the van stores, or `/towers` → Tools
**OPS Openline fibre & telecom:** fusion splicer (splice loss at a joint / CBT / CSP), OTDR (shoots the fibre beside you — length,
breaks, open ends), visual fault locator (breaks and open ends glow red for 30 s), optical power meter (dBm at the ONT),
fibre strippers & Kevlar shears (prep → cleaner splice), one-click cleaner, manhole keys & gas detector, duct rods & draw grips
(rod to the next chamber), combat harness & pole straps (climbing warns without it), handheld network tester (speed test +
PPP login at the ONT), pole tester hammer & probe (sound / suspect / decayed — mark it for maintenance).
**San Andreas Power & Light:** insulated hand tools, voltage detector & phasing stick (live / dead), dielectric gloves, arc flash
PPE, portable earthing kit (only on a dead pole — earthing a live one flashes over), insulated operating rod (pull / replace
the cut-out fuses → the pole goes dead), thermal imaging camera (thermal view + transformer temperature), cable spiking gun,
heavy socket set, **MEWP / cherry picker** (set up in front of you, ride the basket to 14 m: ↑↓ height, ←→ slew, W/S reach,
G equipment on the pole / wall, C cut cable, Backspace lower and get out).

## Pole work guide — F7 (`/poleguide`)
A step-by-step coach for pole work. The first time you climb a pole, open the pole menu, stand a ladder or place
pole kit in a session it offers itself (“Press F7”). Pick a guide and a card on the left shows the current step and
how to do it; every time you finish a step it ticks it off and shows the next one.
- **Fibre to a house** — pole → climb → CBT → feed the CBT → house pole / anchor → CSP → ULW drop drum → drop to the CSP → ONT → patch → provision → check the lights (12 steps)
- **Pole & ladder basics** — ladder → climb → step onto the pole → fit kit → cut a cable → deal with the loose end
- **Power line** — power pole → climb → transformer → cut-outs → power cable → safety sign / anti-climb
- F7 menu: see all steps, jump to any step, skip, hide the card (keeps tracking), switch or stop. “Don’t offer this again” turns the pop-up off.
- Progress is saved per player, so it carries on after a reconnect. The key can be rebound in Settings → Key Bindings → FiveM.

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
- **Telecom equipment** is grouped by network (OPS Openline…) and category:
  - *Poles & fixings*: wooden poles 7 / 10 / 13 m (galvanised ring head), house pole.
  - *Exchange*: OLT (a light source for internet service), MDF, DSLAM, handover frame, fibre distribution frame, DC power plant & batteries.
  - *Street & chambers*: PCP and FTTC cabinets, footway box, modular chamber, manhole, carriageway cover.
  - *Underground*: U-CBT, track joint, base node.
  - *Overhead pole* (also fit from the pole menu): CBT with 4 / 8 / 12 ports, top hat joint, splice enclosure, pole splice box, slack / coil bracket, legacy copper DP.
  - *Customer outside*: CSP, anchor eyebolt + swivel link (cable clamps to it), entry bushing. *Customer inside*: ONT, master socket, VDSL faceplate, splicing tray, fibre entry box.
- **Networks** (each with its own menu under Telecom equipment):
  - **OPS Openline** — the main fibre & copper network (above), plus triple-sided brackets, J-hooks / pigtail bolts and the **metal pole 9 m** with a live **branding & info plate** (company, colour, pole number, phone, extra line — set from the pole's menu).
  - **StreamFibre** — alt-net kit for shared poles: alt-net CBT, yellow provider ID tags, shared (PIA) bracket & slack loop.
  - **San Andreas Power & Light** — wooden power poles 10 / 12 m with cross-arm & insulators, pole-mounted transformer, cut-out fuses & surge arresters, auto-recloser (PMAR), pothead, LV connectors & shrouds, copper earth tape, anti-climbing device, Danger of Death sign.
- **Copper phone line** (OPS Openline → Run phone cable / Copper phone line equipment): copper **drop wire** (pole → house),
  **internal CW1308** (round the house) and **50-pair** (exchange ↔ cabinet ↔ DP). It clamps to poles and sags like the fibre, can go in
  trunking, and is cut / picked up like any other cable. Finish each end on kit by **punching it down** — the pair on the IDC terminals
  (2 = White / Blue, 5 = Blue / White). Kit: copper DP, pole splice box, aerial copper joint, master socket (NTE5C), extension socket,
  internal junction box, VDSL faceplate, plus the PCP cabinet and the exchange MDF. A socket has **dial tone** (and a line number) when
  punched-down copper joins it, through DPs / joints / cabinets, to an **MDF in an exchange with power** (`Config.PhoneLine`).
  Tools (Tool kit → Copper phone line tools): **butt set** (dial tone, number, path), **tone generator & probe** (the toned pair warbles and
  glows purple), **copper line tester** (loop resistance, insulation, distance to an open circuit), **IDC punch-down tool**, **UY
  crimpers**, **multimeter** (line voltage), **NTE5 test socket check** (network fault or house wiring?).
- **Rooftop mast 6 m** (Telecom equipment → Poles & fixings): a galvanised mast on a ballast frame that stands on a flat roof — put
  poles on top of the telephone exchange. Climb it, clamp cable to it and fit pole kit like any pole.
- **Power cable** (Network cabling → Run power cable): HV overhead conductor, LV bundled cable or a service drop to a house. It clamps to poles and sags between them like the fibre does.
- **Cable types:** CAT6; fibre as black dropwire, yellow indoor patch, thick spine feed (drum) and ULW drop (drum). Trunking in white / black / blue, steel capping No. 1, plastic capping No. 25, orange sub-duct and green blown-fibre tubing — cable laid into any of them is hidden.
- **Fixings are automatic:** dropwire clamps wherever cable is clamped to a pole or wall anchor, masonry clips every 35 cm along cable on walls.
- **Climbing poles:** stand at the base of a placed pole and press **E**. W / S climb (feet and hands working up the steps), A / D move round the pole, **X** climbs down. Stop and your feet settle onto the nearest pair of pole steps; above 1.5 m your hands start working in front of you. **G** opens the pole menu: mount a CBT, copper DP or splice enclosure at your height on your side of the pole (refused if something is already fitted there), or remove one next to you. Mounted kit is strapped on with stainless bands sized to the pole and has no collision. Anyone can climb unless `Config.Cabling.ClimbJobs` lists jobs; fitting / removing equipment needs cabling access. Items marked `pole = true` in `Config.Cabling.Equipment` can be mounted.
- **Extension ladders:** `/ladder` (or Network cabling → Place an extension ladder) and pick the **telescopic 0.9 m → 3.2 m** (nests down small; its sections slide out one by one), **3.6 m → 6.9 m** or **6.8 m → 13 m**. You carry it in front of you — walk to move it, the camera stays free. Walk up to a pole or wall and it leans on it at the 1-in-4 angle (against a pole it never goes past the top). Scroll or ↑ / ↓ extends, Shift for fine, Q / E turns it when free-standing, Enter / LMB places. At the foot: **E** climb, **H** extend / retract, **G** move it or take it down. Everyone sees them; they aren't saved, max `LadderMaxPerPlayer` each.
- **Put the cable down:** while pulling CAT6 or fibre from a box press **G** — the cable stays on its box with its end lying where you
  stand, and you walk away hands-free. Walk back to the end and press **E** to carry on: it keeps paying out from the box. **Cable you
  put down** (OPS Openline / StreamFibre menu) lists the loose ends nearby and sets a waypoint. Esc while pulling still puts it all back on the box.
- **Cut ends go loose:** cutting CAT6, fibre or power cable leaves each cut end hanging from its last fixing and lying on the ground with the length that was cut free. Walk up to a loose end and press **E** to pick it up: fix it along walls / poles again (it can only reach as far as its loose length), **Enter** fixes the end where you are (then terminate / splice), **G** or **Backspace** drops it where you stand. Loose ends can't be terminated until they're fixed.
- **Remove all cable within a range:** Tools (or Nearby cables & trunking) → pick cable & fibre, CAT6, fibre, power, trunking or everything, and a distance of 5–200 m. Z in Remove mode puts it back.
- **/towers** is laid out by company: OPS Mobile (cell & Wi-Fi), OPS Openline, StreamFibre, San Andreas Power & Light, Road safety and Tools.
- **Cutting from a pole or ladder:** press **C** while climbing. Every cable within reach is highlighted — **← →** choose the cable, **↑ ↓** slide the cut point along it (Shift for fine), **Enter** cuts, **Backspace** stops.
- **Map poles:** the GTA map's own telegraph poles (`Config.Cabling.WorldPoles`) work like placed ones: climb them, lean ladders on them, clamp cable to them, fit kit on them.
- **Ladder ↔ pole:** at the top of a ladder leaning on a pole press **F** to step onto the pole; on the pole, at a leaning ladder's top step, **F** steps back onto it. **G** on a ladder fits equipment — on the pole it leans on, or (aim & place) on the wall in front.
- **Drop cable drum:** Place a cable box → *Drop cable drum* (500 m black dropwire). The reel turns as you pull, and the slack lies on the ground from the last fixed point to your hand. Climbing (ladder and pole) moves rung by rung with the limbs driven by how far you climb.
- **Gateways** (internet uplink for `RequireUplink`): UDM Pro, Cloud Gateway Ultra, Omada ER605 / ER7206, TP-Link Archer and Deco.
- Placing and laying show a status card at the top of the screen and GTA-style key hints bottom right.

## Road safety equipment
Network cabling → **Road safety equipment** (engineers / admins). Everyone sees it; it's saved.

- **Traffic cones**, **barriers** ("FIBRE WORKS IN PROGRESS" and "STAY BACK"), **cordon tape** (3 m between posts).
- **Works signs** with editable text — heading, second line, dates, times and a footer (e.g. *Mon 06/10 – Fri 10/10 · 08:00 – 18:00*). The text is drawn live on each sign (up to 8 signs in view at once).
- **Portable traffic lights** that cycle green → amber → red. Set one of a pair to side **A** and the other to **B**: one is green while the other is red, with an all-red gap, in sync for every player. Timings in `Config.Roadworks.Lights`.
- **Ruler:** while placing or moving road kit, a coloured line runs from the nearest piece already down — ticks every metre and the distance. It turns **green** when the two are square (straight across or straight along).
- **Line of cones / barriers / tape:** click the start, aim at the end — the row is previewed as see-through pieces with the count; click to place it. Cones use the spacing you choose; barriers and tape go end to end.
- **Pick up:** by aiming (outlines red, hold), everything of a type within a distance you choose, or tick items from a list.
- Place with aim & place; the nearby list lets you move, edit the sign, swap a light's side, or pick it up.
- **House pole** (Telecom equipment): a short pole on a wall bracket — aim at it while laying fibre and the drop clamps to its top.

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
