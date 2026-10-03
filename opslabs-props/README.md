# opslabs-props

Streamed props used by opslabs-towers.

| Model | What it is |
|---|---|
| `opslabs_unifi_ap_ceiling` | UniFi-style access point (U6-Pro size, Ø 197 mm) mounted **dome-down** — origin on the ceiling surface |
| `opslabs_unifi_ap` | Same access point sitting **dome-up** — for desks, shelves and cabinets |
| `opslabs_udm_pro` | UDM Pro-style 1U rack gateway (442 × 285 × 44 mm + rack ears) — brushed front, glowing touchscreen, drive bay, 8 × LAN + WAN + 2 × SFP+ with link LEDs |
| `opslabs_cat6_seg_005…200`, `opslabs_cat6_joint` | Black CAT6 cable (Ø 8 mm) in 5 cm – 2 m pieces + a joint ball, used by `/cable` runs |
| `opslabs_cat6_box` | 305 m CAT6 pull-box (cardboard, cable end out of the top) |
| `opslabs_rj45_plug` | RJ45 plug + boot, shown plugged into devices after termination |
| `opslabs_trunk_{blue,black,white}_{025,050,100,200}` + `_corner` | 25 × 16 mm cable trunking |
| `opslabs_fibre_{black,yellow}_{005…200}` + `_joint` | Fibre: black outdoor dropwire (Ø 5 mm) and yellow indoor patch (Ø 3 mm) |
| `opslabs_fibre_box_{black,yellow}` | Fibre boxes: 1000 m black dropwire, 500 m yellow patch, cable end out of the lid |
| `opslabs_pole_07m`, `_10m`, `_13m` | Wooden telegraph poles (tapered, creosoted) with ring head 200 mm from the top, climbing steps from 2.4 m and a "DP 19" ID plate |
| `opslabs_cbt` | Connectorised block terminal — black weatherproof cylinder with 12 green-capped fibre ports, on a bracket (pole-mount) |
| `opslabs_copper_dp` | Copper distribution point (grey box, pole-mount) |
| `opslabs_splice_enclosure` | Inline splice enclosure / "man on the side" (black capsule) |
| `opslabs_cabinet_pcp`, `opslabs_cabinet_fttc` | Green street cabinets (PCP + FTTC extension) |
| `opslabs_carriageway_cover` | Cast-iron underground chamber cover (flush) |
| `opslabs_csp` | Customer splice point (grey box, outside wall) |
| `opslabs_ont` | Optical network terminal (white box with status LEDs, inside wall) |
| `opslabs_ucg_ultra` | Cloud Gateway Ultra-style desktop gateway (142 × 128 × 30 mm) — white rounded body, glowing status display, 4 × LAN + WAN + USB-C on the back |
| `opslabs_omada_er605` | Omada-style ER605 router — black metal desktop, 5 gigabit ports (counts as an internet gateway) |
| `opslabs_omada_er7206` | Omada-style ER7206 router — 13" metal chassis with rack ears, SFP + 5 ports (gateway) |
| `opslabs_omada_switch` | Omada-style 8-port PoE switch + 2 SFP |
| `opslabs_omada_oc200` | Omada-style OC200 hardware controller |
| `opslabs_omada_eap_ceiling`, `opslabs_omada_eap` | Omada-style ceiling access point (ceiling mount / desk) |
| `opslabs_tplink_deco` | Deco-style mesh Wi-Fi unit (gateway) |
| `opslabs_tplink_archer` | Archer-style home router with 4 antennas (gateway) |
| `opslabs_tplink_extender` | Plug-in Wi-Fi range extender (wall socket) |
| `opslabs_ladder_base`, `opslabs_ladder_fly` | Aluminium extension ladder: 3.6 m base + 3.6 m fly section that slides up behind it (up to 6.9 m) |
| `opslabs_pole_band_075…145` | Stainless banding straps (5 mm radius steps) spawned round a pole under pole-mounted kit |
| `opslabs_drop_drum_stand`, `opslabs_drop_drum_reel` | Drop cable drum: plywood reel of black dropwire (spins as cable is pulled) on a galvanised A-frame stand |
| `opslabs_rw_cone_450`, `opslabs_rw_cone`, `opslabs_rw_cone_1000`, `opslabs_rw_barrier`, `opslabs_rw_barrier_stay`, `opslabs_rw_sign_1…8`, `opslabs_rw_tlight` + `opslabs_rw_lamp_{red,amber,green}`, `opslabs_rw_tape` | Street works safety kit: cone, "FIBRE WORKS IN PROGRESS" / "STAY BACK" barriers, temporary sign (8 live-text faces), portable traffic light, cordon tape |
| `opslabs_house_pole` | House pole: 1.6 m galvanised tube on a wall bracket with a dropwire clamp at the top (pole → house drops) |
| `opslabs_streetlight_6m`, `_10m`, `_10m_twin`, `opslabs_streetlight_pole` (+ `_on`) | San Andreas Power & Light street lights: galvanised columns (base door with ID plate, curved outreach, flat LED lantern), a twin-arm 10 m column, and a lantern bracket that straps to a wooden power pole |
| `opslabs_rw_worklight`, `opslabs_rw_lighttower` (+ `_on`) | OPS Openline road works lighting: tripod with twin 50 W LED floods and a 110 V site transformer; towable lighting tower with 4 floods on a 7.5 m mast |
| `opslabs_guy_seg_005…200`, `opslabs_guy_joint`, `opslabs_guy_hook` | Guild wire: galvanised 7 mm steel strand pieces + joint, and the forged J-hook on a back plate it rests in (pole-mounted) |
| `opslabs_harness_strap`, `opslabs_lanyard` | Climber's fall-arrest kit: orange webbing pole strap with D-ring, and a 1 m lanyard strip stretched between harness and strap |

Access point: white matte body + glowing blue LED ring. Gateways: detailed front/back panel textures and glowing screens (emissive). All have embedded textures and collision (plastic / metal); fronts face the player when placed. No logos or text.

`source/` holds the Blender files, the CodeWalker XML, previews and `build_ap.py` / `build_gateways.py` (the model is generated from code, so it can be rebuilt or tweaked — e.g. change the LED colour in `led_px`). It is not streamed.

Lights: every `<name>_on` model holds only the glowing lenses, with the same origin as its light, so it can be spawned on top at night (`build_lighting.py`).

Pipeline: Blender 4.2 + Sollumz 2.9 → CodeWalker XML → CodeWalker.Core (XmlMeta) → binary `.ydr` / `.ytyp`.
