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

**Props:** cell towers can show a satellite dish, rooftop antenna or radio mast (`Config.Cell.Props`); Wi-Fi can show the **OPS Halo access point** (ceiling or desk, from the `opslabs-props` resource), a USB dongle, hand radio, router, mini PC, laptop… (`Config.Wifi.Props`). Models missing from the game are hidden automatically.

## Menus
`/towers` (admins) and `/cable` (engineers) open the same menu — `/cable` just leaves out OPS Mobile. It's laid out the way the work is done,
each thing in one place only, with section headings inside each menu (client/main.lua):

- **Networks** — *OPS Mobile* (cell & Wi-Fi) · *OPS Openline*: Telecom equipment (poles, exchange kit **and exchange power & cooling**,
  cabinets & chambers, underground joints, pole kit, customer premises, copper) / Fibre & CAT6 (boxes, pull, cable you put down) / Copper
  (run phone cable) / Overhead & containment (**guild wires**, trunking) / Customers (**Internet service** — nearby ONTs → provision, plan,
  suspend, cease) · *StreamFibre* · *San Andreas Power & Light*: Overhead network (poles, pole kit, safety, street lighting, run HV / LV /
  service cable) / Customer supply (cut-out, meter, meter cabinet) / Electrical installation (fuse boards & isolators, sockets & switches,
  lighting, EV charging, run mains cable / flex) / Plug-in & portable (devices & chargers, temporary power) · *Network faults*.
- **On site** — *Buildings & sites* (put down a building, underground, fencing, office & IT — the laptop, placed buildings) · *Road safety* ·
  *Tools* (tool kit, ladder, van, uniform · what's around you · move / cut · Remove… in its own submenu) · *Guides*.

**G in the field only offers installs for where you are:**
- **Up a pole** (or a ladder leaning on one, or the cherry picker): the kit for that kind of pole, grouped by trade — OPS Openline fibre /
  copper and StreamFibre on telegraph & metal poles and roof masts, San Andreas Power & Light pole kit on power poles — the drill, and
  removing what's fitted next to you. Nothing is offered on a house pole or wall anchor (the drop clamps to it while you lay it).
- **Up a ladder against an outside wall**: the drill and the wall kit at the eaves — CSP, anchor, entry bushing, house pole, J-hook, copper DP
  (`Config.Cabling.LadderKit.outside`).
- **Up a ladder inside a building**: ceiling lights (LED panel, batten) and high-level kit — fibre entry box, copper junction box
  (`LadderKit.inside`). Indoors = inside a placed house / depot / exchange or a game interior.

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
  - **Chambers along the line:** none, back to back (chambers only), or one after every 1 / 2 / 3 / 5 tunnel sections.
  - **Sealed walls:** any opening with nothing joined to it shows a concrete wall automatically; join another piece on and that wall
    goes — so a line can always be extended later. Opening the hatch shows the shaft going down (the road itself can't have a hole cut in it).
  - **Dig forward** (`/dig`, or the menu) from anywhere underground: face along the tunnel and it digs on from the open end ahead
    (up to 80 m away); face a tunnel wall and that section becomes a **T-junction** opening on your side so you branch off there. The wall goes and a highlighted, walkable section waits
    in front of you; walk into it and it's built, then the next one appears ahead, so you dig as you walk. **G** swaps the next piece
    between a tunnel section and a chamber; Backspace stops (the end seals itself again). It stops by itself if you break through into
    another tunnel.
  - **Street entrance:** a small access kiosk with a steel door; below it a stairwell with one opening that joins on to an open end like a
    chamber. **F** at the door goes down the stairs; **F** at the foot of the stairs comes back up to the street.
  - **Riser pipes:** duct pipes up out of the ground anywhere — a goose-neck above ground, or flush with a duct cap (under a cabinet /
    beside a pole). Below, the pipe comes down through the tunnel / chamber ceiling. Fibre and copper can be joined through them.
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
**Cordless drill** (fibre and copper kits, and Tools → Cordless drill): face an outside wall — it drills the cable entry hole and fits the brickwork entry bushing for the drop cable. Up a ladder, **G** → *Cordless drill · drill an entry hole here* drills the wall in front of you; up a pole, **G** → *Cordless drill · drill a bolt hole* drills a through-bolt hole at your height (you stay in your climbing pose).
**Power fault finder** (electrical kit, Tools → Power fault finder, or `/powercheck`): stand at anything electrical — socket, light, plug-in kit, consumer unit, meter, cut-out, generator, solar inverter, power pole / transformer, mast, router, ONT — or in a built building (house, depot, exchange) or under a street light. It traces the supply back to the power station (plug → socket → consumer unit → meter / cut-out → LV cable → pole transformer → pole fuses → 11 kV feeder and reclosers → substation → 400 kV line → power station), shows the path with the point where power stops, and lists every cause: unplugged, no socket in reach, switched off, consumer unit tripped, generator stopped, solar isolated / no sun, fuses out or earthed, failed transformer, line fault, tripped / shed / locked-out breaker or recloser, substation missing plant / on fire / in maintenance / no transformers, no generation, equipment faults, or simply not connected.
**Power repair tool** (electrical kit, Tools → Power repair tool, or `/powerrepair`): no test, no questions — use it at broken power kit, in a built building or under a street light and it repairs it and everything wrong on its supply straight away (same fixes as the restoration kit), then says whether power is back or what still has to be built.
**Power restoration kit** (electrical kit, or *Restore power* in the fault finder): grid crews and engineers fix every cause it can, upstream first — switches back on, plugs in, generators started, earths off and fuses in, transformers replaced, line faults repaired, breakers and reclosers closed, substations returned to service, a generating unit started, equipment faults repaired — then re-tests. What has to be built (missing cable, no consumer unit, no transformer near a mast, missing substation plant) is listed instead. Settings: `Config.PowerTools`.
**ONT diagnostic tester** (fibre kit, and Tools → ONT diagnostic tester): plug into an ONT and it reads all five lights — POWER, PON, LOS, LAN, INTERNET — plus the light level, works out what's wrong (failed ONT, no fibre / fibre not spliced, signal too weak, break upstream, still registering, no service, suspended, nothing on the LAN port) and lists the fix step by step.
**ONT repair kit** (fibre kit): at an ONT it tests the unit and lists everything wrong with a fix for each, done step by step:
*replace a failed ONT + power supply* (new serial, the ONT fault is cleared), *fusion splice* a fibre that reaches the ONT but isn't spliced
(or is lying beside it), *clean optics + re-splice the pigtail* when the light is too weak, *crimp and plug in* the router's CAT6 on the
LAN port, *reboot* (ranges + logs in again), *resume* a suspended service, *provision* a line with no service. Faults further up the line
(broken span, wet CBT, dead cabinet…) can't be fixed from the house: the kit says what and where, and sets a waypoint to it. Reboot, new
PSU and a full ONT swap are always on the menu. Engineers only.
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
- **Extension ladders:** `/ladder` (or Network cabling → Place an extension ladder) and pick the **telescopic 0.9 m → 3.2 m** (nests down small; its sections slide out one by one), **3.6 m → 6.9 m** or **6.8 m → 13 m**. You carry it in front of you — walk to move it, the camera stays free. Walk up to a pole or wall and it leans on it at the 1-in-4 angle (against a pole it never goes past the top). Scroll or ↑ / ↓ extends, **PgDn / PgUp pulls the foot back / pushes it in** (shallower / steeper — the top stays on the wall or pole), **← / → pans** it, **Shift + ← / → tilts** it sideways, Q / E turns it when free-standing, Enter / LMB places. The HUD shows the angle and warns when it's too steep or too shallow; each ladder keeps its angle. At the foot: **E** climb, **H** extend / retract, **G** move it or take it down. Everyone sees them; they aren't saved, max `LadderMaxPerPlayer` each.
- **Put the cable down:** while pulling CAT6 or fibre from a box press **G** — the cable stays on its box with its end lying where you
  stand, and you walk away hands-free. Walk back to the end and press **E** to carry on: it keeps paying out from the box. **Cable you
  put down** (OPS Openline / StreamFibre menu) lists the loose ends nearby and sets a waypoint. Esc while pulling still puts it all back on the box.
- **Cut ends go loose:** cutting CAT6, fibre or power cable leaves each cut end hanging from its last fixing and lying on the ground with the length that was cut free. Walk up to a loose end and press **E** to pick it up: fix it along walls / poles again (it can only reach as far as its loose length), **Enter** fixes the end where you are (then terminate / splice), **G** or **Backspace** drops it where you stand. Loose ends can't be terminated until they're fixed.
- **Remove cable in an area:** Tools (or Nearby cables & trunking) → *Remove cable in an area* — click one corner on the ground, aim at
  the other (any size, up to 150 m away); everything that will go is outlined red, **Tab** picks what (all cable, everything incl.
  trunking, CAT6, fibre, phone, power, trunking only). It removes runs at every height inside the box, and anyone pulling or carrying
  cable inside the box drops it. Z in Remove mode puts it back.
- **Remove all cable within a range:** Tools (or Nearby cables & trunking) → pick cable & fibre, CAT6, fibre, power, trunking or everything, and a distance of 5–200 m. Z in Remove mode puts it back.
- **/towers** is laid out by company: OPS Mobile (cell & Wi-Fi), OPS Openline, StreamFibre, San Andreas Power & Light, Road safety and Tools.
- **Cutting from a pole or ladder:** press **C** while climbing. Every cable within reach is highlighted — **← →** choose the cable, **↑ ↓** slide the cut point along it (Shift for fine), **Enter** cuts, **Backspace** stops.
- **Map poles:** the GTA map's own telegraph poles (`Config.Cabling.WorldPoles`) work like placed ones: climb them, lean ladders on them, clamp cable to them, fit kit on them.
- **Ladder ↔ pole:** at the top of a ladder leaning on a pole press **F** to step onto the pole; on the pole, at a leaning ladder's top step, **F** steps back onto it. **G** on a ladder fits equipment — on the pole it leans on, or (aim & place) on the wall in front.
- **Drop cable drum:** Place a cable box → *Drop cable drum* (500 m black dropwire). The reel turns as you pull, and the slack lies on the ground from the last fixed point to your hand. Climbing (ladder and pole) moves rung by rung with the limbs driven by how far you climb.
- **Gateways** (internet uplink for `RequireUplink`): OPS Gateway Pro, OPS Gateway Mini, OPS EdgeLink E5 / E7, OPS HomeRouter AX4 and OPS Mesh M1.
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
- `Config.Isp.RequireIspForGateways = true` makes gateways (OPS Gateway, EdgeLink, HomeRouter…) give internet only when cabled to a live ONT, so Wi-Fi depends on a real broadband line.

## Laptops
Network cabling → Telecom equipment → Customer premises · inside → **Laptop (OPS OS, Ethernet port)** (`opslabs_laptop`). Put it on a desk, then
run CAT6 into it like any device ("Enter to connect to Laptop"). Terminate both ends. It's online when the other end is a router / switch / AP
with an uplink (`IsUplinked`, so it respects `RequireIspForGateways`) or an ONT with an active service. Anyone can press **[E] Use laptop**
within `Config.Laptop.UseDistance`. OPS OS itself runs in opslabs-phone. `exports['opslabs-towers']:GetLaptopNet(fixtureId)` returns the port
state (link, internet, what it's plugged into, gateway, ISP / plan, IP, MAC, or the reason it's offline).
- Saved in `opslabs_towers_isp`. Export: `exports['opslabs-towers']:GetOntStatus(fixtureId)`.

## Website
`https://opsphone-store.opslabsystems.cloud/admin/towers` — live map with merged coverage, dead zones and players; KPIs incl. land coverage. Add by clicking the map, drag a tower to move it, edit everything incl. prop model and Wi-Fi password, select several for bulk actions. Same API key as the phone (`opslabs_phone_api_key`).

API (Bearer key): `GET /opslabs-towers/api/live`, `GET|POST /towers`, `PATCH|DELETE /towers/:id`, `POST /towers/bulk` `{ action: delete|offline|online, ids: [..] }` or `{ action, all: true, type?, offline? }`.

## Config
`Config.Enforce = false` keeps everyone at full signal while you build the network. Ranges, Wi-Fi floor tolerance, password length and prop lists are in `config.lua`.

## Mains electricity — sockets, lights, chargers, EV, generators
San Andreas Power & Light → **Customer supply**, **Sockets & switches**, **Lighting**, **Plug-in & charging**, **EV charging**, **Generators**
(`/cable` or `/towers`). Power cable has three more kinds under *Run power cable*: grey **mains cable**, white **flex** and black **heavy-duty flex**.
What's live is worked out on the server from what's really placed (`server/mains.lua`, settings in `Config.Mains`):

- **Supply:** a pole-mounted **transformer** on a power pole whose cut-out fuses are in (pull them with the operating rod and everything
  downstream goes dead), or a **portable generator** that's running ([E] start / stop). Power cable (LV, service drop, mains, flex) joins
  whatever its two ends touch: power poles, the house pole, the service cut-out, the meter / meter cabinet, the isolator, the consumer unit,
  and other cable ends (joints). A typical house: transformer pole → service drop → meter cabinet → consumer unit inside.
- **Through the walls:** sockets, light switches, ceiling lights and EV chargers within `AutoWireRadius` of a live consumer unit just work,
  as if wired in the walls. You can still run mains cable straight to one instead.
- **Switches:** [E] at a socket / spur / extension lead / reel / desk lamp switches it, at the consumer unit the main switch, at an isolator
  isolates, at a **light switch** all ceiling lights around it. Lights that are on glow and light the room (any time of day).
- **Plugging in:** plug-in kit (extension leads, reels, desk lamps, chargers) plugs itself into the nearest free outlet in reach — a socket,
  an extension lead, a cable reel or a generator — and a plug top and flex lead are drawn to it. [E] unplugs / plugs in chargers.
- **Phones:** stand within `PhoneChargeDistance` of a live **charging cable**, **wireless pad / stand** or a **USB socket** to charge your phone
  (see opslabs-phone *Battery*). `exports['opslabs-towers']:ChargerNear()` → `'wired'` / `'wireless'` / nil.
- **Phone dock:** opslabs-phone puts a phone down on a wireless pad / stand (E). Client export `WirelessChargerNear(maxDist)` → `{ id, model, x, y, z, heading, live }`; server export `GetFixture(id)` → `{ id, model, x, y, z, heading, live }`
- **Laptops:** a live **laptop charger** beside a laptop runs and charges it; without one its battery drains while in use and a flat laptop
  won't start. `GetLaptopPower(id)`, `SetLaptopInUse(id, on)`.
- **EV charging:** park beside a live wallbox / post and [E] *Charge a vehicle*: the car's fuel (charge) goes up `EV.Rate` % a second (also sets the
  `fuel` state bag and LegacyFuel if it's running) until it's full or you drive off. Any car can charge.
- **Meters:** [E] reads the meter — kWh used (counts up with the lights, chargers and EV charging nearest it) and the load right now.
- Switch positions, meter readings and laptop batteries are saved with the fixture and kept when it's moved.

## Gunshot detection — OPS Sentinel sensors
Telecom equipment → **Public safety** → *Gunshot sensor*, or **G** up a pole / up a ladder against an outside wall (`Config.Gunshot`).
- A sensor reports over LTE, so it's **online only with OPS Mobile signal where it's fitted** (`MinBars`) and no fault on it.
- Every player's gunfire is reported; each online sensor within `Range` (450 m, `SilencedRange` 60 m for a suppressor) hears it.
  1 sensor = rough area (±70 m), 2 = ±25 m, 3+ = triangulated (±6 m). Shots close together are one incident (rounds add up).
  The gun ranges (`Exempt`) never alert.
- **Police** (`AlertJobs`) get a red map circle the size of the accuracy, a notification and a phone notification; `/shotsgps` sets the GPS
  to the latest one.
- **OPS Hub → Gunshot detection**: live map of incidents and sensors (online / offline, range circles), acknowledge / close / reopen.
  API: `GET /api/gunshots?status=active|all`, `POST /api/gunshots/:id/ack|close|reopen`.

## San Andreas Solar
Its own company in `/towers` (Install: panels, inverters & batteries, DC isolators · run mains cable). `Config.Solar`:
- **Panels** (roof 400 W, ground array 2.4 kW) within `PanelReach` of a **hybrid inverter** feed it; a **PV DC isolator** near it ([E]) cuts them off.
- The inverter is a power source for the nearest consumer unit (through the walls, or by mains cable): daytime off the panels (output follows
  the game clock — the server asks a player for the time), and a **home battery** beside it stores the surplus and keeps the house on at
  night or in a power cut. [E] on the inverter / battery shows output and charge.
- **OPS Hub → Power & solar**: solar output, installed kWp, battery charge and metered load. API: `GET /api/power`.

## OPS Hub
Every service links back to the staff website (`Config.Hub.Url`, https://opsphone-store.opslabsystems.cloud/admin/): `/towers` → each
company → *Open in OPS Hub* opens its page in the player's browser (OPS Mobile → tower map, Openline / StreamFibre → internet, power &
solar → power, public safety → gunshot detection), and *OPS Hub* on the main menu opens the dashboard.

## Grid control — build the grid, then run it (OPS Hub → Grid control)
The power grid is what engineers **build in game** (`Config.Grid`, `server/grid.lua`), solved every 2 s:
- **Build it** — `/towers` → San Andreas Power & Light: **Generation** (gas power station 4 × 120 MW, wind turbine 3 MW), **Transmission**
  (400 kV lattice pylon), **Substations** (primary substation 400 / 11 kV, 2 × 30 MVA). Then *Run power cable*: **400 kV transmission
  conductor** from the station's gantry over pylons (it hangs from the cross-arm insulators) into the substation, and **11 kV (HV)
  conductor** out of the substation yard along power poles. Fit **pole transformers** (and cut-outs) where homes need supply and
  **reclosers (PMAR)** to split a feeder into sections. LV / service drops / houses carry on as before (Mains).
- **What it does** — every 400 kV run touching a station or substation has a **line breaker**; every 11 kV run leaving a substation is a
  **feeder** with its own breaker; the substation has an **incomer**; a recloser cuts its pole. Load = the homes behind every live pole
  transformer (`TransformerKW` × time of day). Live figures: generation, demand, frequency, every run's flow vs its rating, substation load.
- **Protection (automatic)** — a fault or overload trips the nearest breaker / recloser upstream; reclosers try twice, feeder and line
  breakers once; a permanent fault locks out and puts a crew job (yellow marker) at the real spot. Generation short → under-frequency
  relays shed feeders (priority 1 first). Substation over firm capacity → sheds its lowest-priority feeder. Random faults
  (×8 in a thunderstorm): line faults, pole transformer failures, substation transformer failures / fires, generator trips.
- **In game** — a dead pole transformer means its LV network is dead: sockets, lights, EV chargers, street lights. Crews (`CrewJobs`,
  plus engineers / admins): **[E] in a power station yard** (start / stop units, line breakers), **[E] in a substation yard** (incomer,
  every feeder: open / close, rename, shedding priority, line breakers), **[E] under a recloser** (open / close / reset lockout),
  **[E] at a yellow marker** to repair a fault. Everything is the same state as OPS Hub.
- **OPS Hub → Grid control** — status strip, live map of the real network (actual cable routes, stations, pylons, substations, feeders,
  reclosers, transformers, crews), one-line diagram generated from what's connected (click any breaker), alarms with dispatch, emergency
  levels, procedures, notices to crews / a feeder's customers / everyone, generation, substations, lines & reclosers, feeders (open /
  close / shed / priority / rename), planned maintenance, switching log. API: `GET /api/grid`, `POST /api/grid/action`.

## SAPL Line Tool & LineSense pole monitors (`Config.PowerLine` · `/linetool` · tool kit → electrical tools)

The **Line Tool** is an insulated hot stick for grid crews and engineers. Aim at any power kit (pole, pylon, substation, power
station, wind turbine, pole transformer / recloser, house supply kit, consumer unit) or at a **conductor in the air**, press **E**:

- **Live status** and every step that kit still needs, ticked or crossed. A missed step can be fixed from the tool:
  **place the missing kit now** (e.g. a pole transformer on this pole, a power pole before refitting a transformer, missing
  substation plant), **run the right conductor from here**, or **show me where** (GPS + a marker on the nearest live pole,
  substation, pylon or transformer). The fault finder's reasons (open breakers, faults, missing cable…) are listed too.
- **Connect a conductor here:** the conductor classes that belong on that kit are offered. After laying it the tool says what each
  end landed on and offers to snap a loose end onto the nearest pole / kit.
- **Snap off / snap on:** opens or closes the jumper between a conductor and the kit it lands on. The line stays strung but is
  disconnected there — 11 kV / 400 kV (`server/grid.lua`) and LV (`server/mains.lua`) both respect it, so everything beyond goes
  dead. Kept in the kit's fixture data (`data.open`).
- **Move this end onto another pole / kit:** re-route a line (span up to `MoveReach`, 60 m). **Re-string** a conductor as another
  class (11 kV ↔ LV ↔ service; mains ↔ flex). **Take a conductor down.**
- Live work warns when your dielectric gloves aren't on. Every change is written to the OPS Hub grid log.

Every **power pole** automatically gets a **LineSense monitor** (`opslabs_pole_monitor`, opslabs-props) strapped on 3 m up: lit with a
green LED while the pole is live, dark with a red LED when it's dead. Walk within 9 m for its live panel: name, street and
coordinates, 11 kV / LV, **power flowing through the pole and the current in amps**, feeder and substation, recloser, transformers
(and the power they pass to LV), conductors, open jumpers, fuses out, earths, line faults. The street is reported by the first
player who sees the pole. **OPS Hub → Grid control** shows the same data per pole: a **Poles** layer on the live map and a **Poles**
tab (search, problems first, locate, rename, switch its recloser).

Server exports for other scripts: `GridPoles(ids?)`, `PowerJumperOpen(fixtureId, runId)`, `PowerDiagFixture(fixtureId)`.

## OPS City network — build everything, everywhere (`Config.City` · OPS Hub → Grid / Power / Internet / Gunshots / Fuel / CCTV · `/opscity`)

**Build complete network** on any of those OPS Hub pages builds a real, connected, powered network across the whole map:
a power station (Palmer-Taylor) and 400 kV pylon lines (a minimum spanning tree) to a fitted substation in every district
(`Config.City.Districts`), and in each district a flat lot beside a road with a telephone exchange (OLT, core router, power),
a customer house on supply and broadband, a fuel station (tanks, pumps, pipework, gauge, filled), CCTV (NVR + PoE cameras)
and a cell mast — plus 11 kV pole lines both ways along the road (transformers, a recloser, cut-outs, street lights) and
telecom poles across the road (splice, CBTs, fibre, gunshot sensors). Internet, gunshots, fuel and CCTV can be left out.

- It's ordinary kit (`created_by = 'OPS City'`), so every system runs it like hand-built kit: control it from OPS Hub, break it,
  repair it in game. **Remove city network** takes all of it away again.
- The server can't see the map, so **an admin's game surveys it** (`client/citybuild.lua`): they're hidden with the screen dark
  for a few minutes while their ped hops round the map. With no tower admin in game the build is queued and starts with the
  next one who joins (they get a warning). Districts with no flat, clear lot near a road are skipped and listed.
- **Clear what's there first** (tick box): once the survey has worked, the OPS Showcase and everything placed before (poles, cable,
  kit, boxes, masts) is backed up and removed — Danger zone → Restore a wipe brings it back.
- **Fill in missing districts** (OPS Hub, once a network is built): surveys only the districts that were skipped and connects
  them to the existing 400 kV network — no second power station, nothing already built is touched.
- **`/opscitypreview`** (admins): runs the district survey where you stand and shows, for 90 s, the plots and pole lines it would
  use and why anything was left out. Nothing is built — use it to check a spot before a real build.
- Cable sync now sends only what changed (`opslabs-towers:cablingDelta`), so a city of thousands of items doesn't re-send
  everything to every player on each edit.

## Danger zone — mass delete (`/towers` → Danger zone · `Config.Danger`)

For tower admins, behind a **second login**. The first login is **admin / admin** and must be changed straight away (new
username + a password of 8+ characters that isn't "admin") before anything can be deleted. The login is stored hashed in the
database (`opslabs_towers_danger`), never in a config file. 5 wrong passwords lock you out for 10 minutes; a login lasts 15.

- **Mass delete:** around you (any radius) or the whole map. Pick groups with live counts — every network · category
  (e.g. *San Andreas Power & Light · Power poles*), each power conductor class, every cable kind, boxes & drums, cell towers,
  Wi-Fi, road safety — or a quick pick: **power grid only**, **the whole power network**, or **everything**.
- You see exactly what will go, then type **DELETE**. A JSON backup of the exact rows is written to `danger_backups/` first.
- **Restore a wipe** puts everything back with its original ids (masts / Wi-Fi after a resource restart). Every login, wipe
  and restore is printed to the server console.

## Menu style, pole quick menu & third eye

- **Menu style** (`/towers` → Settings): each player picks the full-screen **console** or the small **classic** menus; kept on their
  PC. `Config.MenuStyle.Default` is the default.
- **Up a pole, Z** opens a small classic quick menu whatever the style: fit / remove kit here, cut a cable, harness, Line Tool,
  climb down.
- **Third eye** (`Config.Target`, tgiann-target / ox_target): look at the bottom of any pole — placed or GTA's own — for **Climb**,
  **Pole kit at the base**, **Pole live data**, **Line Tool**, **Recloser control**, **Power fault finder**, **Repair the fault here**
  and **Place a ladder**. The old [E] prompts (climb, recloser) are only used when no target resource is running.

## Substations — buildings and plant (`/towers` → San Andreas Power & Light → Bulk grid)
- **Substation building · fully fitted**: 18 × 10 m walk-in building. It has 2 × 30 MVA transformers, two 400 kV GIS incomer bays, two 11 kV switchgear lineups (8 feeder breakers), busbars, protection relays, metering, a SCADA control desk, a 110 V DC battery and charger, a main earth bar, HV cable sealing ends and an RTU pole. Ready to connect.
- **Substation building · empty**: the same building with nothing inside. Fit the plant yourself from **Substation plant**.
- **RTU telemetry pole**: put it beside **any** building (GTA or built) and fit the plant inside, and that building becomes a substation. The RTU identifies the site to grid control and gives remote (SCADA) switching.
- Plant within 16 m belongs to that substation. It energises only when it has: a power transformer, a 400 kV GIS bay, 11 kV switchgear, busbars, a protection relay panel, a main earth bar, and a DC battery and charger. Missing items are listed on [E] and in OPS Hub.
- Each transformer adds 30 MVA. Each switchgear lineup gives 4 feeder breakers; an 11 kV run beyond that has no breaker and isn't fed.
- No RTU means no remote control: OPS Hub can't switch it, and crews operate it on site. [E] works at the control desk, the switchgear, the GIS or the relay panel.
- The building lights come on when the substation's 11 kV bus is live.

## OPS Fuel — fuel stations (`/towers` → OPS Fuel · OPS Hub → Fuel stations)
- **Real fuel.** Vehicles burn fuel and only fill up at stations built here; GTA's own pumps do nothing. Electric vehicles charge at EV chargers, not pumps. Putting diesel in a petrol car (or the reverse) damages the engine until the tank is run dry.
- **Layout:** tanker → fill point → fill pipe → underground tank (vent pipe → vent stack) → product pipe → dispenser → nozzle → vehicle.
- **Lay fuel pipe:** green unleaded, blue super, black diesel, galvanised vent. Start and finish each run within 1.5 m of the kit; ends of the same pipe within 0.5 m are joined.
- **Dispensers and the tank gauge (ATG / pump controller) need power** from a live consumer unit (wired through the walls within 14 m) — so the station must be on the grid. Kit within 70 m of a tank gauge forms one station.
- **[E] at the dispenser:** pick a grade, then fill up, a fixed number of litres or a dollar amount. Switch the engine off. Driving off mid-fill parts the breakaway coupling; reset it at the dispenser.
- **Emergency stop:** stops every pump on the station. Reset it at the tank gauge (or OPS Hub).
- **Tank gauge:** shows levels, temperature, water, leaks, the vent / fill / pump checks, sales and deliveries, and stock variance (book vs dip). Staff can set prices, rename the station and reconcile stock. Leaks and water in a tank stop sales from it; fix them at the tank chamber ([E]).
- **Deliveries:** park a `tanker` / `tanker2` trailer under a **bulk terminal gantry** and [E] to load 3 compartments (charged at wholesale). At the fill point, earth the tanker first, then offload each compartment into the tank its coloured fill pipe goes to. Tanks need a vent, and deliveries stop at 95 % full.
- `Config.Fuel`: products and prices, burn rates, electric / diesel models, tanker sizes, leak and water rates, staff jobs.

## Network power and PoE (`Config.Power`)
- Routers, gateways, switches and ONTs need a **live socket within 3 m**. Access points can also run on **PoE**: terminated CAT6 to a powered PoE switch (OPS Switch 8 PoE: 60 W; each AP draws 12–13 W).
- Cell masts run off a live pole transformer within 350 m. In a power cut their batteries last 2 hours, then they go off air.
- Unpowered kit stops giving coverage, stops passing traffic, and an unpowered ONT shows POWER off.
- Built buildings are lit only when a live consumer unit is inside them. `CityBlackout`: every GTA building and GTA street lamp is dark (no power); vehicle lights still work.

## OPS Secure — CCTV (`/towers` → OPS Secure · phone: Secure View · OPS Hub → CCTV systems)
- **Kit** (camera maker Vigilo): bullet 4K, dome, turret and fisheye (IP, PoE); PTZ speed dome; ANPR / LPR; thermal bi-spectrum; analogue HD-TVI bullet; wireless indoor camera; video doorbell; NVR (16 channels, 8 × PoE, 120 W); DVR (8 channels); desk monitor; 2 × 2 video wall; PTZ joystick; access-control reader; "CCTV in operation" sign.
- **Wiring** (pull CAT6 from a box and crimp it onto the kit):
  - IP camera → NVR: powered by the NVR's PoE ports, within the port and watt limits;
  - IP camera → PoE switch (OPS Switch 8 PoE, powered) → … → NVR;
  - analogue camera → DVR;
  - wireless camera / doorbell: an NVR within 60 m plus a powered Wi-Fi router or access point within 40 m (the indoor camera also needs a socket);
  - recorders need a live socket within 3 m.
  The NVR's channel limit applies.
- **[E] at the NVR / DVR:** status (power, recording, internet, channels, PoE), watch the cameras, recorded events, ANPR plate reads, and **Set up**: name, recording mode (motion / continuous / off) and retention, remote viewing, owner, organisation job (e.g. `police`, whose members can watch), sharing with players, camera names. **[E] at a monitor, video wall or keyboard** watches the nearest system.
- **Viewer:** ← → switches camera, scroll zooms, a mouse controls PTZ pan / tilt, Backspace exits. Thermal cameras see heat; IR cameras switch to night mode after dark. A dead camera shows NO SIGNAL.
- **Recording:** motion (people and vehicles in view), heat (thermal), ANPR plate reads (plate and speed), doorbell rings, and who watched. Kept for the system's retention.
- **Remote viewing:** the **Secure View** phone app (install it from the Store). It works when remote viewing is on and the NVR is cabled to an online router.
- **Faults:** dirty / fogged lens (degraded picture), cable fault or a dead camera. The owner is alerted and an OPS Secure "CCTV fault finding" job is raised. Engineers fix it at the camera ([E]: clean lens / re-terminate / replace); a failed recorder hard drive is replaced at the NVR.
- **Jobs (OPS Work):** install cameras, NVR, DVR, PTZ, ANPR, thermal, doorbell, configure PoE, remote viewing, recording, replace cable, maintenance, fault finding, upgrade, removal, access control. Each is checked against what is really live in game.
- `Config.Cctv`: camera / recorder definitions (field of view, range, PoE watts, lens position), ranges, fault rate, retention.

### CCTV live on OPS Hub (`server/cctvlive.lua`, `client/cctvlive.lua`, `html/cctvcap.js`)

**OPS Hub → CCTV → Live camera wall** shows every camera with its latest picture, status and how old the picture is; click
one to watch it big. A camera's picture only exists while a game renders it, so pictures come from:
- **anyone watching in game** (monitor, video wall, phone Secure View) — about one picture a second of what they see;
- a **CCTV relay**: staff type **`/cctvrelay`** and their screen becomes a control-room monitor cycling through the cameras
  OPS Hub viewers have open (the one opened big most often), so every watched camera stays live. Leave a spare PC logged in
  running it for an always-on wall. `/cctvrelay` or Backspace stops it.
Pictures are grabbed from the game view with WebGL (no screenshot resource needed), sent as small JPEGs and kept in memory.

## OPS Network — ISP (`server/opsisp.lua` · phone: OPS Work → My broadband · OPS Hub → OPS Network ISP)
Real broadband lines on top of the fibre network. Tables: `opslabs-phone/sql/ops_isp.sql`; settings: `Config.OpsIsp`.
- **Packages** — home, copper, business, dedicated and government tiers (seeded from `Config.OpsIsp.Packages`, then edited on the Hub).
- **Ordering** — a player orders from the phone where they stand (or staff order on the Hub for any customer). That raises an `isp_newcustomer` job for OPS Network; when it's completed the line goes live: nearest online ONT linked and provisioned, public IPs allocated, default router config saved, first bill (plus setup fee) charged and invoiced.
- **IP addresses** (fictional documentation ranges) — dynamic `203.0.113.0/24`, static `198.51.100.0/24`, dedicated `/29` blocks from `192.0.2.0/24`; reverse DNS per address. OPS DNS `203.0.113.53` / `.54`.
- **Router settings** — LAN, DHCP + reservations, DNS, Wi-Fi (pushed to the real router tower), guest Wi-Fi, VLANs, firewall, port forwards, VPN. Edited on the Hub; secrets never leave the server. `net_cfg_*` jobs verify that the setting actually changed after the job was accepted.
- **Monitoring** (every 30 s) — line up / degraded / down from the ONT; ONT provisioning follows the line status (suspend/cancel cut it off). Three or more lines dropping within 450 m opens an **outage**: emergency job, customers told, auto-resolved when they come back. Planned maintenance is posted on the Hub and shown on the public status page.
- **Speed tests** — phone (Wi-Fi or wired), result as % of the plan; the `net_speed` job needs 70 %.
- **Billing** — every 7 days; unpaid → overdue → suspended after 3 days' grace → back on when paid from the phone.
- **Faults** — customers report from the phone; a ticket + job is raised; staff reply and close on the Hub.

## OPS Data — data centres (`server/datacentre.lua` · `/towers` → OPS Data · OPS Hub → Data & Cloud)
Build a data hall: **42U racks**, a **UPS cabinet**, **CRAC cooling** (and a standby generator). Servers aren't placed on their own — **[E] on the rack → Install kit**: Halcyon C1 (1U) / C2 (2U) compute, S4 SAN storage (4U), Meridian ToR switch, Bastion firewall, blanking panels. They appear in the rack with a status LED (green / amber / red).
- **Power:** racks run from the hall's UPS (on mains with a socket within 3 m of it, or a generator in the hall; otherwise on battery — ~15 min at full load, longer when lightly loaded) or, with no UPS, straight from a socket (a power cut drops them).
- **Cooling:** every running server adds heat; each powered CRAC removes 30 kW. An overloaded hall warms up: servers degrade at 32 °C and shut down at 40 °C, then come back once it has cooled.
- **Network:** a rack is online with a working ToR switch in it **and** CAT6 from the rack to a router with internet.
- **Faults** (failed drive, PSU, fan, motherboard) and hall problems (overheating, on battery, rack offline) raise **OPS Data jobs** that check themselves — fix them at the rack (**[E] → the server → Repair**).
- **Roles:** compute servers host **OPS Cloud** VMs by default. Set one to *OPS Web hosting*, *OPS DNS* or *OPS Web mail* and that OPS service then runs on it — it's down whenever none of its servers is reachable (with no servers in that role it is always up).
- **OPS Cloud scheduler:** places customer VMs on healthy cloud hosts in their region (rack → *Name & region*), restarts them on another host when theirs dies, otherwise *host down* / *waiting for capacity* — and raises an *Add cloud capacity* job when a region is full.
- State goes to `ops_dc_status` (read by the phone and OPS Hub) and to clients (`GlobalState.opsDcRacks`).

## OPS Showcase — see everything built and working (`/opsshowcase`, admins)
- `/opsshowcase goto` takes you to the suggested site, a flat open area by Sandy Shores airfield (`Config.Showcase.Site`). `/opsshowcase here` then builds the lot round you, with the street running the way you face. It needs about 600 × 270 m of open ground. You're moved round the site for a few seconds while it reads the ground height, then put back.
- It builds about 300 pieces of real kit with their cable, pipe and towers, all wired so they work:
  - **Generation and transmission:** a gas power station (two units started), four 400 kV pylons and three substations: the outdoor yard, the fitted building, and the empty building fitted plant by plant with an RTU pole. Two wind turbines, 11 kV feeders, pole transformers, a recloser and street lights.
  - **The house:** service drop → cut-out → meter → consumer unit, sockets, a light switch with ceiling panels, EV wallbox and post, solar (inverter, battery, ground array), chargers and a laptop. Fibre from the exchange through a splice enclosure and CBT → CSP → ONT (OPS Fibre 900, live) → OPS Gateway Mini → PoE switch → ceiling AP. Copper MDF → PCP → DP → master socket (dial tone).
  - **Telephone exchange:** OLT, core router (patched, uplink), MDF, DSLAM, FDF, HOF, rectifier, batteries, DC plant, CRAC, condenser, standby generator, rooftop mast.
  - **Depot:** office network (OPS EdgeLink E5 → PoE switch → three APs, laptop), the OPS Track fitting bay, and the fuel station's tank gauge.
  - **Fuel station:** canopy, two dispensers, three filled underground tanks, product / fill / vent pipes, fill point, vent stack, e-stop. Also an above-ground tank and the bulk terminal gantry.
  - **Also:** 5G and lattice cell masts, a gunshot sensor, a StreamFibre pole, street cabinets and chambers, a roadworks scene, an underground chamber and tunnel, security fencing, gates, barrier and bollards.
- Map blips mark each part. `/opsshowcase where` lists them, with waypoints. `/opsshowcase remove` takes it all away again.

## OPS Track — vehicle GPS trackers (`/towers` → OPS Track · `/track` · OPS Hub → Vehicle tracking)
- **Install** (sit in the vehicle, stopped): pick **OPS Track Mini** (plug-and-play on a fuse tap, internal antennas, no backup battery) or **OPS Track Pro** (hard-wired, external GPS/LTE antenna, 48 h backup battery, ignition and door inputs, immobiliser relay). The installer tool case goes down beside the car. Work through the steps in order: remove trim → find feeds with the multimeter (12 V or 24 V depending on the vehicle) → fuse tap / inline fuse → strip, crimp and heat-shrink → inputs / output (Pro) → mount the unit → backup battery (Pro) → antenna for sky view (Pro) → tape and tie → power up and check the LEDs → refit the trim.
- **Reporting:** every 10 s over **OPS Mobile**. With no signal, the hub shows the last known position and any alert is sent late. Vehicles stored in a garage show as parked.
- **Owners** (ESX `owned_vehicles`) use `/track`: waypoint to the vehicle, arm theft alerts (it moves, or the ignition comes on), immobilise (Pro: it won't start once stopped), rename. Alerts arrive as notifications, on the OPS phone and as a flashing map blip.
- **Tamper:** anyone can hunt for the tracker and cut its feed (20 s). A Pro runs on its battery and alerts the owner; a Mini just dies. Installers can reconnect or decommission it.
- **Check the tracker (LEDs):** PWR, GNSS (searching indoors), GSM (OPS Mobile bars).
- `Config.Track`: installer jobs, report interval, arm distance, backup hours, unit types.

## House wiring tips
- **Light switch wired by cable:** run mains cable or flex from a light switch to the ceiling lights — that switch then works exactly those
  lights. Lights not cabled to anything are worked by the nearest light switch (within `LightSwitchRadius`).
- **Moving / removing sockets, switches and other kit:** Tools → *Move cable, trunking or a box* / *Remove…* now pick equipment too — aim at
  it (small kit with no collision is picked within 40 cm of where you aim). Buildings, poles, underground pieces, fencing and the big grid kit
  are moved / removed from their own menus.

## World cleanup — hide GTA's own pumps, poles and traffic lights
`Config.WorldCleanup` hides GTA's fuel pumps, wooden power / phone poles (and wall brackets and big pylons) and traffic lights around every player, so only the kit you build stands in the world. Only the GTA model names in its lists are hidden — OPS kit (`opslabs_*`) never is. Switch each group on or off, set the radius or add any other GTA models (`Extra`) in the config file, on OPS Hub → Settings → *World cleanup*, or in the phone's Developer app → World → *World Cleanup*. Changes apply live within ~15 s; switching a group off brings the props back. GTA's overhead wires belong to the map itself, so some wires can stay where poles are removed, and AI traffic still stops at junctions.

