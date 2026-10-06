Config = {}

-- Who can place and edit towers in game (/towers). ESX groups, or the ace
-- permission "opslabs.towers" (add_ace group.admin opslabs.towers allow).
Config.AdminGroups = { 'admin', 'superadmin' }
-- players who can always use /towers (FiveM license identifiers)
Config.AdminLicenses = {
    'license:fe50077d59b4b447a558c58e7bf1da74e65dca40',
}
Config.Command = 'towers'

-- false: towers are tracked and shown on the map, but every phone keeps
-- full service (handy while you build out your network)
Config.Enforce = true

-- how often each player's signal is worked out (ms)
Config.TickMs = 1500

Config.Cell = {
    DefaultRange = 1500,   -- metres
    MinRange = 100, MaxRange = 6000,
    -- props you can pick when placing a tower (smallest first). Models that
    -- don't exist in the game are hidden from the menu automatically.
    Props = {
        { label = 'Small satellite dish',  model = 'prop_satdish_s_01a' },
        { label = 'Small satellite dish (B)', model = 'prop_satdish_s_02a' },
        { label = 'Rooftop antenna',       model = 'prop_roofaerial_01' },
        { label = 'Large satellite dish',  model = 'prop_satdish_l_01' },
        { label = 'Medium radio mast',     model = 'prop_radiomast01' },
        { label = 'Large radio mast',      model = 'prop_radiomast02' },
        { label = 'OPS 5G street monopole · 17.5 m, cabinets at the base', model = 'opslabs_mast_5g' },        -- opslabs-props
        { label = 'OPS lattice mast · 25 m, cabin & fenced compound', model = 'opslabs_mast_lattice' },       -- opslabs-props
    },
    -- ground kit spawned with a mast prop (same position and heading)
    Extras = { opslabs_mast_lattice = { 'opslabs_mast_lattice_compound' } },
    Prop = 'prop_radiomast02',  -- used for towers placed before you picked a model
}

Config.Wifi = {
    DefaultRange = 40,     -- metres (a building)
    MinRange = 8, MaxRange = 250,
    FloorTolerance = 14,   -- metres above/below the access point it still reaches
    -- router / mini computer props for access points (hidden if the model doesn't exist)
    Props = {
        { label = 'OPS Halo access point (ceiling)', model = 'opslabs_ap_halo_ceiling' },  -- opslabs-props
        { label = 'OPS Halo access point (desk / shelf)', model = 'opslabs_ap_halo' },     -- opslabs-props
        { label = 'OPS Gateway Mini (desk)', model = 'opslabs_gw_mini' },          -- opslabs-props
        { label = 'Dream Machine Pro (rack / shelf)', model = 'opslabs_gw_pro' },      -- opslabs-props
        { label = 'OPS Beam access point (ceiling)', model = 'opslabs_ap_beam_ceiling' },  -- opslabs-props
        { label = 'OPS Beam access point (desk / shelf)', model = 'opslabs_ap_beam' },
        { label = 'OPS EdgeLink E5 router (desk)', model = 'opslabs_edge_e5' },
        { label = 'OPS EdgeLink E7 router (rack / shelf)', model = 'opslabs_edge_e7' },
        { label = 'OPS Switch 8 PoE', model = 'opslabs_poe_switch8' },
        { label = 'OPS Controller C2', model = 'opslabs_ctrl_c2' },
        { label = 'OPS Mesh M1 unit', model = 'opslabs_mesh_m1' },
        { label = 'OPS HomeRouter AX4', model = 'opslabs_homerouter_ax4' },
        { label = 'OPS range extender (wall socket)', model = 'opslabs_range_extender' },
        { label = 'USB Wi-Fi dongle (tiny)', model = 'hei_prop_hst_usb_drive' },
        { label = 'USB stick (tiny)',      model = 'prop_cs_usb_drive' },
        { label = 'Hand radio (small)',    model = 'prop_cs_hand_radio' },
        { label = 'Walkie-talkie (small)', model = 'prop_cs_walkie_talkie' },
        { label = 'Smart speaker / hub',   model = 'prop_portable_hifi_01' },
        { label = 'Tablet',                model = 'prop_cs_tablet' },
        { label = 'Wi-Fi router',          model = 'h4_prop_h4_router_01a' },
        { label = 'Router (office)',       model = 'xm_prop_x17_wifi_router' },
        { label = 'Mini PC',               model = 'prop_pc_02a' },
        { label = 'Desktop computer',      model = 'prop_pc_01a' },
        { label = 'Laptop',                model = 'prop_laptop_01a' },
        { label = 'Server laptop',         model = 'hei_prop_hst_laptop' },
    },
    Prop = false,          -- used for access points placed before you picked a model
    PasswordMin = 4,       -- shortest Wi-Fi password allowed
}

-- No towers are created automatically: place every tower yourself with
-- /towers in game or on the website's tower map. They're saved in the
-- opslabs_towers table and stay exactly as you leave them.

-- CAT6 cabling (/cable): pull cable from a 305 m box along floors, walls and
-- ceilings, run it through trunking, then terminate it into routers / APs.
-- OPS Hub: the staff website every service links back to (/towers → each company → Open in OPS Hub)
Config.Hub = {
    Url = 'https://opsphone-store.opslabsystems.cloud/admin/',
    Pages = { mobile = 'towers', openline = 'internet', streamfibre = 'internet', sapl = 'power', solar = 'power', fuel = 'fuel', grid = 'grid', track = 'track', secure = 'cctv', data = 'datacentre', gunshots = 'gunshots', faults = 'internet' },
}

Config.Cabling = {
    Command = 'cable',
    Jobs = {},                  -- jobs that may lay cable besides tower admins, e.g. { 'electrician' }
    BoxLength = 305,            -- metres in a new box
    PullDistance = 3.0,         -- start a run within this distance of a box
    MaxRunLength = 90,          -- longest single run in metres (real CAT6 limit is 100 m)
    Standard = 'T568B',         -- wire order for termination: 'T568B' or 'T568A'
    RequireUplink = false,      -- true: Wi-Fi access points only work when cabled (both ends terminated) to a gateway
    Gateways = { 'opslabs_gw_pro', 'opslabs_gw_mini', 'opslabs_edge_e5', 'opslabs_edge_e7', 'opslabs_homerouter_ax4', 'opslabs_mesh_m1' },   -- Wi-Fi props that count as the internet uplink
    DrawDistance = 80.0,        -- cables/trunking are shown within this range
    TrunkColors = { 'white', 'black', 'blue', 'capping', 'capping25', 'subduct', 'bft' },
    TrunkLabels = { white = 'White trunking', black = 'Black trunking', blue = 'Blue trunking', capping = 'Steel capping (No. 1)',
        capping25 = 'Plastic capping (No. 25)', subduct = 'Sub-duct (orange)', bft = 'Blown fibre tubing (BFT)' },
    FibreColors = { 'black', 'yellow', 'spine', 'ulw' },   -- dropwire, indoor patch, spine feed, ultra-lightweight drop
    FibreLabels = { black = 'Black dropwire', yellow = 'Yellow indoor patch', spine = 'Spine feed cable (thick)', ulw = 'ULW drop cable' },
    MaxFibreLength = 1000,                     -- longest single fibre run
    FibreBoxLength = { black = 1000, yellow = 500, spine = 2000, ulw = 1000 },   -- metres in a new fibre box / drum
    DropDrumLength = 500,                               -- metres of black dropwire on a drop cable drum
    -- GTA map props that count as telegraph poles (climb them, lean ladders, clamp cable, fit kit)
    WorldPoles = {
        'prop_telegraph_01a', 'prop_telegraph_01b', 'prop_telegraph_01c', 'prop_telegraph_01d', 'prop_telegraph_01e',
        'prop_telegraph_01f', 'prop_telegraph_01g', 'prop_telegraph_02a', 'prop_telegraph_02b', 'prop_telegraph_03',
        'prop_telegraph_04a', 'prop_telegraph_04b', 'prop_telegraph_05a', 'prop_telegraph_05b', 'prop_telegraph_05c',
        'prop_telegraph_06a', 'prop_telegraph_06b', 'prop_telegraph_06c',
    },
    -- telecom equipment that can be placed with /cable → Telecom equipment
    -- telegraph poles: anyone can climb (E at the base); ClimbJobs = { 'telecom' } to restrict
    ClimbJobs = false,
    -- every placed pole model and its height (m): climbing, ladders, cable clamps, guy wires, faults all use this
    PoleHeights = { opslabs_pole_07m = 7.0, opslabs_pole_10m = 10.0, opslabs_pole_13m = 13.0, opslabs_pole_metal = 9.0,
        opslabs_power_pole_10m = 10.0, opslabs_power_pole_12m = 12.0, opslabs_pole_roof = 6.0, opslabs_grid_pylon = 36.0 },
    NoClimb = { opslabs_grid_pylon = true },          -- poles you clamp cable to but don't climb
    -- conductors clamp to the tip of the pylon's lower cross-arm (under the insulator string): x out along the arm, z up
    PylonArm = { opslabs_grid_pylon = { x = 7.5, z = 18.8 } },
    ClimbSpeed = 0.9,          -- metres per second
    LadderCommand = 'ladder',  -- /ladder to stand an extension ladder against a wall or pole
    Ladders = {                -- top = top of the fly when closed (m along the ladder), maxExt = how far the fly slides out
        { id = 'l7', label = 'Extension ladder · 3.6 m → 6.9 m', base = 'opslabs_ladder_base', fly = 'opslabs_ladder_fly', top = 3.9, maxExt = 3.0 },
        { id = 'l13', label = 'Extension ladder · 6.8 m → 13 m', base = 'opslabs_ladder13_base', fly = 'opslabs_ladder13_fly', top = 7.1, maxExt = 5.9 },
        -- telescopic: 10 sections of 0.32 m, nested to 0.9 m closed, end to end at 3.2 m (opslabs-props/source/build_ladder_tele.py)
        { id = 'l3', label = 'Telescopic ladder · 0.9 m → 3.2 m', base = 'opslabs_ladder_tele_base', fly = 'opslabs_ladder_tele_sec', top = 0.905, maxExt = 2.295,
          tele = { n = 10, len = 0.32 } },
    },
    LadderMaxPerPlayer = 2,
    ClimbAnimFlip = true,      -- climbers face the pole; set false if they ever end up with their back to it
    -- equipment, grouped by network (each has its own menu) and category.
    -- pole = true → can be fitted from the pole menu (G while climbing); sizes → a size dropdown
    Networks = {
        { id = 'openline', label = 'OPS Openline', sub = 'Main fibre & copper network', icon = 'network-wired', color = '#0a84ff' },
        { id = 'streamfibre', label = 'StreamFibre', sub = 'Alt-net fibre (shares poles)', icon = 'circle-nodes', color = '#14a0aa' },
        { id = 'sapl', label = 'San Andreas Power & Light', sub = 'Power poles, transformers, cut-outs, power cable', icon = 'plug-circle-bolt', color = '#ffd60a' },
        { id = 'solar', label = 'San Andreas Solar', sub = 'Solar PV installs · panels, inverters, home batteries', icon = 'solar-panel', color = '#ff9f0a' },
        { id = 'secure', label = 'OPS Secure', sub = 'CCTV & security · cameras, recorders, monitors, doorbells, ANPR', icon = 'video', color = '#ff375f' },
        { id = 'data', label = 'OPS Data', sub = 'Data centres · racks, servers, storage, UPS, cooling — runs OPS Cloud', icon = 'server', color = '#5e5ce6' },
        { id = 'track', label = 'OPS Track', sub = 'Vehicle GPS trackers · install, test, live tracking, theft alerts', icon = 'location-crosshairs', color = '#30d158' },
        { id = 'fuel', label = 'OPS Fuel', sub = 'Fuel stations · tanks, pipework, dispensers, tanker deliveries', icon = 'gas-pump', color = '#e2202a' },
        { id = 'pos', label = 'OPS POS Systems', sub = 'Store tills · terminal, card reader, cash drawer, printer, scanner, customer display', icon = 'cash-register', color = '#ff9f0a' },
        -- OPS America (US fiber-to-the-home): OPS America Fiber · Outside Plant · Network Ops — US names for the same kit
        { id = 'usfiber', label = 'OPS America Fiber', sub = 'US FTTH · central office, outside plant, drops & customer premises', icon = 'flag-usa', color = '#2f6bff' },
    },
    -- buildings, civils, fencing and office kit live under /towers → Buildings & sites (exchange plant is OPS Openline kit)
    Sites = { id = 'sites', label = 'Buildings & sites', sub = 'Walk-in buildings · underground · fencing · office & IT', icon = 'city', color = '#5e5ce6' },
    -- power cable (Run power cable): bare HV conductor, LV bundled cable, insulated service drop to a house
    PowerColors = { 'transmission', 'hv', 'lv', 'service', 'mains', 'flex', 'flexblack' },
    -- G up a ladder against a wall: only what really gets fitted at height there
    LadderKit = {
        outside = { 'opslabs_csp', 'opslabs_wall_anchor', 'opslabs_entry_bushing', 'opslabs_house_pole', 'opslabs_jhook', 'opslabs_copper_dp', 'opslabs_gunshot_sensor' },
        inside = { 'opslabs_mains_ledpanel', 'opslabs_mains_batten', 'opslabs_entry_cap', 'opslabs_copper_jb' },
    },
    PowerOverhead = { 'transmission', 'hv', 'lv', 'service' },          -- Run power cable · network (poles, service drops)
    PowerInside = { 'mains', 'flex', 'flexblack' },       -- Run mains cable / flex · electrical installation
    PowerLabels = { transmission = '400 kV transmission conductor (pylons)', hv = 'HV overhead conductor (11 kV)', lv = 'LV bundled cable (230 / 400 V)', service = 'Service drop to a house',
        mains = 'Mains cable (grey twin & earth, inside)', flex = 'Flex (white 3-core)', flexblack = 'Flex (black, heavy duty)' },
    MaxPowerLength = 1200,
    -- copper phone cable (Run phone cable): drop wire pole → house, internal cable round the house, multi-pair between cabinets
    CopperColors = { 'drop', 'internal', 'multipair' },
    -- fuel pipework (OPS Fuel → Lay fuel pipe): product lines carry one fuel (also the fill lines from the fill point); vent lines go to the vent stack
    PipeColors = { 'ul', 'sup', 'dsl', 'vent' },
    PipeLabels = { ul = 'Unleaded 95 pipe (green)', sup = 'Super 98 pipe (blue)', dsl = 'Diesel pipe (black)', vent = 'Vent pipe (galvanised)' },
    MaxPipeLength = 300,
    CopperLabels = { drop = 'Copper drop wire (black, 2 pair)', internal = 'Internal phone cable (CW1308, white)', multipair = 'Multi-pair cable (50 pair, black)' },
    MaxCopperLength = 800,
    Equipment = {
        -- poles & house fixings
        { net = 'openline', cat = 'Poles & fixings', label = 'Telegraph pole 7 m',  model = 'opslabs_pole_07m' },
        { net = 'openline', cat = 'Poles & fixings', label = 'Telegraph pole 10 m', model = 'opslabs_pole_10m' },
        { net = 'openline', cat = 'Poles & fixings', label = 'Telegraph pole 13 m', model = 'opslabs_pole_13m' },
        { net = 'openline', cat = 'Poles & fixings', label = 'House pole (wall bracket, for the drop from the pole)', model = 'opslabs_house_pole' },
        { net = 'openline', cat = 'Poles & fixings', label = 'Metal pole 9 m (branding & info plate)', model = 'opslabs_pole_metal' },
        { net = 'openline', cat = 'Poles & fixings', label = 'Rooftop mast 6 m (ballast frame, for flat roofs)', model = 'opslabs_pole_roof',
          about = 'Stands on a flat roof without fixing into it — e.g. on top of the telephone exchange. Climb it, clamp cable, fit kit.' },
        -- exchange
        { net = 'sites', cat = 'Buildings', label = 'Telephone exchange building (walk-in)', model = 'opslabs_exchange_building', building = true,
          about = '16 × 10 m · racks, power plant & switching go inside' },
        -- buildings (also listed under /towers → Buildings)
        { net = 'sites', cat = 'Buildings', label = 'Customer house (walk-in)', model = 'opslabs_house_customer', building = true,
          about = '11 × 8 m bungalow · living room, kitchen, bedroom · anchor / CSP outside, ONT inside' },
        { net = 'sites', cat = 'Buildings', label = 'Engineering depot (walk-in)', model = 'opslabs_depot', building = true,
          about = '22 × 14 m · office, kit room, warehouse with racking & cable drums, roller-shutter bay' },
        -- security & fencing (fence panels go down in a row: Buildings & sites → Security & fencing → Lay a fence line)
        -- underground (Buildings & sites → Underground chambers & tunnels): walk-in, placed under roads, origin on the road surface
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Underground chamber (walk-in, access hatch)', model = 'opslabs_ug_chamber', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Cable tunnel section 4 m', model = 'opslabs_ug_tunnel', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Tunnel end wall', model = 'opslabs_ug_tunnel_end', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Tunnel T-junction 4 m (side opening)', model = 'opslabs_ug_tunnel_tee', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Street entrance (kiosk, stairs down)', model = 'opslabs_ug_entrance', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Riser pipe · goose-neck', model = 'opslabs_ug_riser', underground = true },
        { net = 'sites', cat = 'Underground chambers & tunnels', label = 'Riser pipe · flush cap', model = 'opslabs_ug_riser_flush', underground = true },
        { net = 'sites', cat = 'Security & fencing', label = 'Palisade fence panel 2.5 m', model = 'opslabs_fence_pal_grey', fence = true, sizeLabel = 'Finish', sizes = {
            { label = 'Anthracite', model = 'opslabs_fence_pal_grey' }, { label = 'Green', model = 'opslabs_fence_pal_green' }, { label = 'Galvanised', model = 'opslabs_fence_pal_galv' } } },
        { net = 'sites', cat = 'Security & fencing', label = 'Mesh fence panel 2.5 m', model = 'opslabs_fence_mesh_grey', fence = true, sizeLabel = 'Finish', sizes = {
            { label = 'Anthracite', model = 'opslabs_fence_mesh_grey' }, { label = 'Green', model = 'opslabs_fence_mesh_green' } } },
        { net = 'sites', cat = 'Security & fencing', label = 'Branded fence panel (company sign board)', model = 'opslabs_fence_brand', fence = true, branded = true },
        { net = 'sites', cat = 'Security & fencing', label = 'Fence end post', model = 'opslabs_fence_post' },
        { net = 'sites', cat = 'Security & fencing', label = 'Branded sign (fit to a fence, wall or gate)', model = 'opslabs_fence_sign', branded = true },
        { net = 'sites', cat = 'Security & fencing', label = 'Sliding gate 5 m (auto, PIN lock, branded)', model = 'opslabs_gate_slide_frame', branded = true },
        { net = 'sites', cat = 'Security & fencing', label = 'Double swing gates 4 m (auto, PIN lock, branded)', model = 'opslabs_gate_swing_frame', branded = true },
        { net = 'sites', cat = 'Security & fencing', label = 'Pedestrian gate (auto, PIN lock)', model = 'opslabs_gate_ped_frame' },
        { net = 'sites', cat = 'Security & fencing', label = 'Car park barrier (auto, PIN lock)', model = 'opslabs_barrier_housing' },
        { net = 'sites', cat = 'Security & fencing', label = 'Rising security bollard (auto, PIN lock)', model = 'opslabs_bollard_rising' },
        { net = 'sites', cat = 'Security & fencing', label = 'Security bollard (fixed)', model = 'opslabs_bollard_fixed', fence = true, gap = 1.5, sizeLabel = 'Finish', sizes = {
            { label = 'Yellow & black', model = 'opslabs_bollard_fixed' }, { label = 'Stainless steel', model = 'opslabs_bollard_steel' } } },
        { net = 'openline', cat = 'Exchange network kit', label = 'Optical line terminal (OLT)', model = 'opslabs_olt' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Core router / backhaul switch (switching)', model = 'opslabs_core_router' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'DC rectifier rack (48 V)', model = 'opslabs_rectifier' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'Industrial battery bank', model = 'opslabs_battery_bank' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'Standby diesel generator', model = 'opslabs_generator' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'HVAC cooling unit (indoor)', model = 'opslabs_crac' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'HVAC condenser (outdoor)', model = 'opslabs_condenser' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Main distribution frame (MDF)', model = 'opslabs_mdf' },
        { net = 'openline', cat = 'Exchange network kit', label = 'DSLAM', model = 'opslabs_dslam' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Handover frame (HOF)', model = 'opslabs_hof' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Optical distribution / handover frame (ODF / OHF)', model = 'opslabs_fdf' },
        { net = 'openline', cat = 'Exchange power & cooling', label = 'DC power plant & batteries', model = 'opslabs_dc_power' },
        -- street cabinets & chambers
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Street cabinet (PCP)', model = 'opslabs_cabinet_pcp' },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Street cabinet (FTTC DSLAM)', model = 'opslabs_cabinet_fttc' },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Green 3-door street cabinet', model = 'opslabs_cabinet_green3', sizeLabel = 'Doors', sizes = {
            { label = 'Doors closed', model = 'opslabs_cabinet_green3' }, { label = 'Middle door open (being worked on)', model = 'opslabs_cabinet_green3_open' } } },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Footway box (joint box)', model = 'opslabs_footway_box' },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Modular underground chamber', model = 'opslabs_chamber_modular' },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Manhole chamber', model = 'opslabs_manhole' },
        { net = 'openline', cat = 'Street cabinets & chambers', label = 'Carriageway cover', model = 'opslabs_carriageway_cover' },
        -- underground
        { net = 'openline', cat = 'Underground joints', label = 'Underground CBT (U-CBT)', model = 'opslabs_ucbt' },
        { net = 'openline', cat = 'Underground joints', label = 'Track joint', model = 'opslabs_track_joint' },
        { net = 'openline', cat = 'Underground joints', label = 'Underground base node', model = 'opslabs_base_node' },
        -- on the pole
        { net = 'openline', cat = 'On the pole', label = 'CBT (fibre block terminal)', model = 'opslabs_cbt', pole = true, sizes = {
            { label = '4 ports', model = 'opslabs_cbt_4' }, { label = '8 ports', model = 'opslabs_cbt_8' }, { label = '12 ports', model = 'opslabs_cbt' } } },
        { net = 'openline', cat = 'On the pole', label = 'Top hat joint (fibre node)', model = 'opslabs_joint_tophat', pole = true },
        { net = 'openline', cat = 'On the pole', label = 'Splice enclosure', model = 'opslabs_splice_enclosure', pole = true },
        { net = 'openline', cat = 'On the pole', label = 'Cable slack / coil bracket', model = 'opslabs_slack_loop', pole = true },
        { net = 'openline', cat = 'On the pole', label = 'Triple-sided bracket', model = 'opslabs_triple_bracket', pole = true, axis = true },
        { net = 'openline', cat = 'On the pole', label = 'J-hook / pigtail bolt', model = 'opslabs_jhook', pole = true },
        -- customer premises, outside
        -- public safety: acoustic gunshot detection (alerts police, shown on OPS Hub → Gunshot detection)
        { net = 'openline', cat = 'Public safety', label = 'Gunshot sensor (OPS Sentinel)', model = 'opslabs_gunshot_sensor', pole = true,
          about = 'Hears gunfire up to ~450 m and reports it over LTE (needs OPS Mobile signal where it’s fitted). 3+ sensors pin it to a few metres.' },
        { net = 'openline', cat = 'Customer premises · outside', label = 'Customer splice point (CSP)', model = 'opslabs_csp' },
        { net = 'openline', cat = 'Customer premises · outside', label = 'Anchor eyebolt + swivel link', model = 'opslabs_wall_anchor' },
        { net = 'openline', cat = 'Customer premises · outside', label = 'Brickwork entry bushing', model = 'opslabs_entry_bushing' },
        -- customer premises, inside
        { net = 'openline', cat = 'Customer premises · inside', label = 'ONT (optical network termination)', model = 'opslabs_ont' },
        { net = 'openline', cat = 'Customer premises · inside', label = 'Internal splicing tray', model = 'opslabs_splice_tray' },
        { net = 'openline', cat = 'Customer premises · inside', label = 'Internal fibre entry box', model = 'opslabs_entry_cap' },
        { net = 'sites', cat = 'Office & IT', label = 'Laptop (OPS OS, Ethernet port)', model = 'opslabs_laptop',
          about = 'Put it on a desk, run CAT6 from a router (or the ONT) into its port and anyone can use it: [E] at the laptop' },
        -- copper phone line: exchange MDF → PCP cabinet → aerial joint / DP on the pole → drop wire → master socket → extensions
        { net = 'openline', cat = 'Copper phone line', label = 'Copper DP box (distribution point)', model = 'opslabs_copper_dp', pole = true },
        { net = 'openline', cat = 'Copper phone line', label = 'Pole mounted splice box (copper)', model = 'opslabs_pole_splice_box', pole = true },
        { net = 'openline', cat = 'Copper phone line', label = 'Aerial copper joint (sleeve)', model = 'opslabs_copper_joint_aerial', pole = true },
        { net = 'openline', cat = 'Copper phone line', label = 'Master socket (NTE5C)', model = 'opslabs_nte5c' },
        { net = 'openline', cat = 'Copper phone line', label = 'Secondary phone socket (extension)', model = 'opslabs_copper_linejack' },
        { net = 'openline', cat = 'Copper phone line', label = 'Internal junction box', model = 'opslabs_copper_jb' },
        { net = 'openline', cat = 'Copper phone line', label = 'VDSL faceplate', model = 'opslabs_vdsl_faceplate' },
        -- StreamFibre (alt-net) kit, mounted alongside / below the main network on shared poles
        { net = 'streamfibre', cat = 'On the pole', label = 'Alt-net CBT', model = 'opslabs_alt_cbt', pole = true },
        { net = 'streamfibre', cat = 'On the pole', label = 'Provider ID tag (yellow)', model = 'opslabs_alt_tag', pole = true },
        { net = 'streamfibre', cat = 'On the pole', label = 'Shared (PIA) bracket & slack loop', model = 'opslabs_alt_pia_bracket', pole = true },
        -- OPS America Fiber (US FTTH) — the same models as OPS Openline under their US names, so splicing, light, power and job checks all work the same
        { net = 'usfiber', cat = 'Central office · optical & routing', label = 'OLT (optical line terminal · XGS-PON shelf)', model = 'opslabs_olt',
          about = 'Lights the PON and authenticates ONTs. Needs a powered router patched to it for backhaul.' },
        { net = 'usfiber', cat = 'Central office · optical & routing', label = 'ODF (optical distribution frame)', model = 'opslabs_fdf', about = 'Terminates and patches outside-plant fiber to the OLT.' },
        { net = 'usfiber', cat = 'Central office · optical & routing', label = 'Aggregation / core router', model = 'opslabs_core_router', about = 'Collects OLT traffic · backhaul to the metro and core.' },
        { net = 'usfiber', cat = 'Central office · optical & routing', label = 'Internet edge router / BNG', model = 'opslabs_core_router', about = 'BGP to transit & peering · subscriber sessions and IP addresses.' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'Rectifier shelf (-48 V DC)', model = 'opslabs_rectifier' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'DC power plant & distribution', model = 'opslabs_dc_power' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'Battery string', model = 'opslabs_battery_bank' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'Standby generator', model = 'opslabs_generator' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'HVAC indoor unit', model = 'opslabs_crac' },
        { net = 'usfiber', cat = 'Central office · power & HVAC', label = 'HVAC condenser (outdoor)', model = 'opslabs_condenser' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'Fiber distribution hub (FDH)', model = 'opslabs_cabinet_green3', sizeLabel = 'Doors', sizes = {
            { label = 'Doors closed', model = 'opslabs_cabinet_green3' }, { label = 'Door open (being worked on)', model = 'opslabs_cabinet_green3_open' } },
          about = 'Feeder in, passive splitters (1:8 – 1:128), distribution out.' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'FDH cabinet (compact)', model = 'opslabs_cabinet_pcp' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'Handhole', model = 'opslabs_footway_box' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'Vault', model = 'opslabs_chamber_modular' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'Manhole', model = 'opslabs_manhole' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'Underground splice closure', model = 'opslabs_ucbt' },
        { net = 'usfiber', cat = 'Outside plant · cabinets & underground', label = 'In-line splice closure (underground)', model = 'opslabs_track_joint' },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Fiber distribution terminal (FDT)', model = 'opslabs_cbt', pole = true, sizes = {
            { label = '4 ports', model = 'opslabs_cbt_4' }, { label = '8 ports', model = 'opslabs_cbt_8' }, { label = '12 ports', model = 'opslabs_cbt' } } },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Aerial splice closure', model = 'opslabs_splice_enclosure', pole = true },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Dome splice closure', model = 'opslabs_joint_tophat', pole = true },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Slack storage (snowshoe)', model = 'opslabs_slack_loop', pole = true },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Pole attachment bracket', model = 'opslabs_triple_bracket', pole = true, axis = true },
        { net = 'usfiber', cat = 'Outside plant · aerial', label = 'Drop hook / J-hook', model = 'opslabs_jhook', pole = true },
        { net = 'usfiber', cat = 'Utility poles', label = 'Utility pole 25 ft (7 m)', model = 'opslabs_pole_07m' },
        { net = 'usfiber', cat = 'Utility poles', label = 'Utility pole 35 ft (10 m)', model = 'opslabs_pole_10m' },
        { net = 'usfiber', cat = 'Utility poles', label = 'Utility pole 45 ft (13 m)', model = 'opslabs_pole_13m' },
        { net = 'usfiber', cat = 'Customer premises', label = 'NID / fiber drop box', model = 'opslabs_csp', about = 'Where the drop lands on the outside wall.' },
        { net = 'usfiber', cat = 'Customer premises', label = 'Drop clamp anchor', model = 'opslabs_wall_anchor' },
        { net = 'usfiber', cat = 'Customer premises', label = 'Wall feed-through', model = 'opslabs_entry_bushing' },
        { net = 'usfiber', cat = 'Customer premises', label = 'Service mast (house attachment)', model = 'opslabs_house_pole' },
        { net = 'usfiber', cat = 'Customer premises', label = 'ONT (optical network terminal)', model = 'opslabs_ont' },
        { net = 'usfiber', cat = 'Customer premises', label = 'Inside splice tray', model = 'opslabs_splice_tray' },
        { net = 'usfiber', cat = 'Customer premises', label = 'Inside fiber entry box', model = 'opslabs_entry_cap' },
        -- San Andreas Power & Light
        { net = 'sapl', cat = 'Power poles', label = 'Wooden power pole 10 m (cross-arm & insulators)', model = 'opslabs_power_pole_10m' },
        { net = 'sapl', cat = 'Power poles', label = 'Wooden power pole 12 m (cross-arm & insulators)', model = 'opslabs_power_pole_12m' },
        { net = 'sapl', cat = 'On the power pole', label = 'Pole-mounted transformer', model = 'opslabs_power_transformer', pole = true },
        { net = 'sapl', cat = 'On the power pole', label = 'Cut-out fuses & surge arresters', model = 'opslabs_power_cutouts', pole = true },
        { net = 'sapl', cat = 'On the power pole', label = 'Pole-mounted auto-recloser (PMAR)', model = 'opslabs_power_recloser', pole = true },
        { net = 'sapl', cat = 'On the power pole', label = 'Cable termination box (pothead)', model = 'opslabs_power_pothead', pole = true, ground = true },
        { net = 'sapl', cat = 'On the power pole', label = 'LV line connectors & shrouds', model = 'opslabs_power_lv_connectors', pole = true },
        { net = 'sapl', cat = 'Safety & earthing', label = 'Copper earth tape', model = 'opslabs_power_earth_tape', pole = true, ground = true },
        { net = 'sapl', cat = 'Safety & earthing', label = 'Anti-climbing device', model = 'opslabs_power_anticlimb', pole = true, axis = true },
        { net = 'sapl', cat = 'Safety & earthing', label = 'Danger of Death sign', model = 'opslabs_power_danger_sign', pole = true },
        { net = 'sapl', cat = 'Street lighting', label = 'Street light column 6 m (residential)', model = 'opslabs_streetlight_6m' },
        { net = 'sapl', cat = 'Street lighting', label = 'Street light column 10 m (main road)', model = 'opslabs_streetlight_10m' },
        { net = 'sapl', cat = 'Street lighting', label = 'Street light column 10 m · twin arm (central reserve)', model = 'opslabs_streetlight_10m_twin' },
        { net = 'sapl', cat = 'Street lighting', label = 'Street light bracket (on the power pole)', model = 'opslabs_streetlight_pole', pole = true },
        -- San Andreas Solar (PV installs): panels → DC isolator → hybrid inverter (+ home battery) → the consumer unit
        { net = 'solar', cat = 'Solar panels', label = 'Roof panel 400 W (on rails)', model = 'opslabs_solar_panel_roof', about = 'Aim at the roof. Feeds the inverter within 30 m.' },
        { net = 'solar', cat = 'Solar panels', label = 'Ground-mount array 2.4 kW (6 panels)', model = 'opslabs_solar_array_ground' },
        { net = 'solar', cat = 'Inverters & batteries', label = 'Hybrid inverter 5 kW', model = 'opslabs_solar_inverter', about = 'Feeds the consumer unit nearby (or by mains cable). [E] shows output and battery.' },
        { net = 'solar', cat = 'Inverters & batteries', label = 'Home battery 13.5 kWh', model = 'opslabs_solar_battery', about = 'Within 4 m of the inverter: stores daytime solar and keeps the house on at night / in a power cut.' },
        { net = 'solar', cat = 'Isolators & protection', label = 'PV DC isolator', model = 'opslabs_solar_dciso', about = '[E] isolates the panels from the inverter (safe working)' },
        -- OPS Secure: CCTV (Config.Cctv) — cameras on walls / poles, recorders + viewing kit on desks
        -- OPS POS Systems (opslabs-pos): everything within a few metres of a terminal joins that till
        { net = 'pos', cat = 'Point of sale', label = 'POS terminal 15.6" (the till)', model = 'opslabs_pos_terminal', about = 'On the counter, screen towards the cashier. A boss of the business sets it up at the terminal.' },
        { net = 'pos', cat = 'Point of sale', label = 'Card reader (contactless)', model = 'opslabs_pos_cardreader', about = 'Keypad towards the customer, beside the terminal. Card and phone (OPS Pay) payments.' },
        { net = 'pos', cat = 'Point of sale', label = 'Cash drawer', model = 'opslabs_pos_drawer', about = 'Under or beside the terminal, front towards the cashier. Opens on cash sales.' },
        { net = 'pos', cat = 'Point of sale', label = 'Receipt printer', model = 'opslabs_pos_printer', about = 'Beside the terminal: customers get a printed receipt.' },
        { net = 'pos', cat = 'Point of sale', label = 'Barcode scanner + cradle', model = 'opslabs_pos_scanner', about = 'Beside the terminal: scan to add products.' },
        { net = 'pos', cat = 'Point of sale', label = 'Customer display', model = 'opslabs_pos_display', about = 'Screen towards the customer: shows the basket and total.' },
        { net = 'secure', cat = 'IP cameras (PoE)', label = 'Bullet camera 4K (IP, PoE, IR 40 m)', model = 'opslabs_cctv_bullet', about = 'CAT6 to the NVR or a PoE switch. Looks out from the wall.' },
        { net = 'secure', cat = 'IP cameras (PoE)', label = 'Dome camera (IP, PoE)', model = 'opslabs_cctv_dome' },
        { net = 'secure', cat = 'IP cameras (PoE)', label = 'Turret camera (IP, PoE)', model = 'opslabs_cctv_turret' },
        { net = 'secure', cat = 'IP cameras (PoE)', label = 'Fisheye 360° camera', model = 'opslabs_cctv_fisheye' },
        { net = 'secure', cat = 'Specialist cameras', label = 'PTZ speed dome (PoE+)', model = 'opslabs_cctv_ptz', about = 'Pan, tilt and 30× zoom from the viewer.' },
        { net = 'secure', cat = 'Specialist cameras', label = 'ANPR / LPR camera', model = 'opslabs_cctv_anpr', about = 'Reads number plates of vehicles passing in view.' },
        { net = 'secure', cat = 'Specialist cameras', label = 'Thermal bi-spectrum camera', model = 'opslabs_cctv_thermal', about = 'Sees heat — people at night, through smoke.' },
        { net = 'secure', cat = 'Specialist cameras', label = 'Analogue HD-TVI bullet (DVR)', model = 'opslabs_cctv_analog', about = 'Cable straight to a DVR.' },
        { net = 'secure', cat = 'Wireless & doorbells', label = 'Wireless indoor camera', model = 'opslabs_cctv_wifi', about = 'Needs a socket, Wi-Fi in range and an NVR on site.' },
        { net = 'secure', cat = 'Wireless & doorbells', label = 'Video doorbell', model = 'opslabs_cctv_doorbell', about = 'Visitors press [E] — the owner gets a phone alert.' },
        { net = 'secure', cat = 'Recorders & viewing', label = 'NVR 16 channel · 8 × PoE', model = 'opslabs_cctv_nvr', about = 'Needs a socket within 3 m. [E] to set up, watch and review.' },
        { net = 'secure', cat = 'Recorders & viewing', label = 'DVR 8 channel (analogue)', model = 'opslabs_cctv_dvr' },
        { net = 'secure', cat = 'Recorders & viewing', label = 'CCTV monitor 24"', model = 'opslabs_cctv_monitor', about = '[E] watch the nearest system.' },
        { net = 'secure', cat = 'Recorders & viewing', label = 'Control-room video wall 2 × 2', model = 'opslabs_cctv_videowall' },
        { net = 'secure', cat = 'Recorders & viewing', label = 'PTZ joystick keyboard', model = 'opslabs_cctv_keyboard' },
        { net = 'secure', cat = 'Access & signage', label = 'Access-control reader with camera', model = 'opslabs_cctv_reader' },
        { net = 'secure', cat = 'Access & signage', label = '"CCTV in operation" sign', model = 'opslabs_cctv_sign' },
        -- OPS Data: the data hall. Servers go INTO a rack ([E] on the rack → Install), not placed on their own.
        { net = 'data', cat = 'Racks & power', label = '42U server rack (OPS Data)', model = 'opslabs_dc_rack', about = 'Plug into a socket or stand within 25 m of a UPS. CAT6 from its switch to a router with internet. [E] to install servers.' },
        { net = 'data', cat = 'Racks & power', label = 'UPS cabinet 40 kVA', model = 'opslabs_dc_ups', about = 'Powers every rack in the hall · needs a socket (or a generator) within 3 m to stay charged · ~15 min on battery.' },
        { net = 'data', cat = 'Racks & power', label = 'Standby diesel generator', model = 'opslabs_generator', about = 'Within 25 m of the UPS: keeps it on mains through a power cut.' },
        { net = 'data', cat = 'Cooling', label = 'CRAC cooling unit (30 kW)', model = 'opslabs_crac', about = 'Needs a socket within 3 m. Each removes 30 kW of heat from the hall.' },

        { net = 'track', cat = 'Fitting bay', label = 'OPS Track fitting bay sign', model = 'opslabs_trk_sign' },
        { net = 'track', cat = 'Fitting bay', label = 'Installer tool case (open)', model = 'opslabs_trk_toolcase' },
        { net = 'track', cat = 'Fitting bay', label = 'Tracking unit (on the bench)', model = 'opslabs_trk_unit' },
        { net = 'track', cat = 'Fitting bay', label = 'GPS / LTE antenna', model = 'opslabs_trk_antenna' },
        { net = 'track', cat = 'Fitting bay', label = 'Backup battery', model = 'opslabs_trk_battery' },
        { net = 'track', cat = 'Fitting bay', label = 'Wiring loom (fuse tap & relay)', model = 'opslabs_trk_harness' },
        -- OPS Fuel: tanker → fill point → underground tank → (submersible pump) → pipe → dispenser → hose → nozzle → vehicle
        { net = 'fuel', cat = 'Storage tanks', label = 'Underground tank · Unleaded 95 (30 000 L)', model = 'opslabs_fuel_tank_ul', about = 'The access chamber sits flush in the forecourt. Pipe it to the dispensers, the fill point and the vent stack.' },
        { net = 'fuel', cat = 'Storage tanks', label = 'Underground tank · Super 98 (30 000 L)', model = 'opslabs_fuel_tank_sup' },
        { net = 'fuel', cat = 'Storage tanks', label = 'Underground tank · Diesel (30 000 L)', model = 'opslabs_fuel_tank_dsl' },
        { net = 'fuel', cat = 'Storage tanks', label = 'Bunded above-ground tank · Diesel (10 000 L)', model = 'opslabs_fuel_tank_agt', reach = 40.0, about = 'Depots and farms. Steel bund catches leaks.' },
        { net = 'fuel', cat = 'Dispensers & forecourt', label = 'Fuel dispenser (3 grades, both sides)', model = 'opslabs_fuel_dispenser', reach = 30.0,
          about = 'Needs power (consumer unit within 14 m or mains cable) and a pipe from each tank it sells. [E] beside it to fill up.' },
        { net = 'fuel', cat = 'Dispensers & forecourt', label = 'Forecourt canopy 12 × 8 m (lit)', model = 'opslabs_fuel_canopy', reach = 60.0 },
        { net = 'fuel', cat = 'Dispensers & forecourt', label = 'Emergency stop (all pumps)', model = 'opslabs_fuel_estop', about = '[E] stops every pump on the station. Reset it at the tank gauge.' },
        { net = 'fuel', cat = 'Deliveries & venting', label = 'Tanker fill point cabinet', model = 'opslabs_fuel_fillpoint', reach = 30.0,
          about = 'Pipe each coloured fill to its tank. Tankers offload here — earth first.' },
        { net = 'fuel', cat = 'Deliveries & venting', label = 'Vent stack (3 vents, P/V valves)', model = 'opslabs_fuel_vent', reach = 30.0, about = 'Run a vent pipe from every tank. No vent, no delivery.' },
        { net = 'fuel', cat = 'Station control', label = 'Tank gauge & pump controller (ATG)', model = 'opslabs_fuel_atg',
          about = 'Wall-mounted in the shop. Needs power. Authorises the pumps; [E] for levels, alarms, prices, sales, reconciliation.' },
        { net = 'fuel', cat = 'Bulk terminal', label = 'Bulk terminal loading gantry', model = 'opslabs_fuel_gantry', reach = 120.0,
          about = 'Where road tankers load. Park a fuel tanker trailer under it and [E].' },
        -- the bulk grid: build it, then run it from OPS Hub → Grid control or [E] at the kit
        { net = 'sapl', cat = 'Generation', label = 'Gas power station (4 × 120 MW)', model = 'opslabs_grid_station', reach = 260.0,
          about = 'Connect 400 kV transmission conductor to its gantry. [E] in the yard: start / stop units.' },
        { net = 'sapl', cat = 'Generation', label = 'Wind turbine (3 MW)', model = 'opslabs_grid_wind', reach = 260.0,
          about = 'Run 11 kV (HV) conductor from its base into the network. Output follows the wind.' },
        { net = 'sapl', cat = 'Transmission', label = '400 kV lattice pylon', model = 'opslabs_grid_pylon', reach = 180.0,
          about = 'Carries 400 kV conductor (Run power cable → 400 kV) between stations and substations.' },
        { net = 'sapl', cat = 'Substations', label = 'Primary substation 400 / 11 kV', model = 'opslabs_grid_substation', reach = 200.0,
          about = '400 kV in at the gantry; every 11 kV (HV) run out of it is a feeder with its own breaker. [E] at the switch room.' },
        { net = 'sapl', cat = 'Substations', label = 'Substation building · fully fitted (walk-in)', model = 'opslabs_grid_subbuilding', building = true, reach = 200.0,
          about = '18 × 10 m · 2 × 30 MVA transformers, 400 kV GIS, 8 feeder breakers, protection, metering, SCADA, DC battery, earthing, RTU. Ready to connect.' },
        { net = 'sapl', cat = 'Substations', label = 'Substation building · empty (fit it out yourself)', model = 'opslabs_grid_subshell', building = true, reach = 200.0,
          about = 'Walk-in shell. Fit the plant inside (Substation plant). Works once it has everything it needs.' },
        { net = 'sapl', cat = 'Substations', label = 'RTU telemetry pole (makes any building a substation)', model = 'opslabs_grid_rtu', reach = 60.0,
          about = 'Put it beside any building — GTA or built — and fit the plant inside. Identifies the site to grid control and gives remote (SCADA) control.' },
        -- substation plant (fits in the empty building, or any building with an RTU pole): plant within 16 m belongs to that substation
        { net = 'sapl', cat = 'Substation plant', label = 'Power transformer 30 MVA (400 / 11 kV)', model = 'opslabs_sub_tx', reach = 40.0, about = 'Each one adds 30 MVA. Two give N-1 firm capacity.' },
        { net = 'sapl', cat = 'Substation plant', label = '400 kV GIS incomer bay (breaker · disconnector · earth switch)', model = 'opslabs_sub_gis', reach = 40.0, about = 'The incomer circuit breaker. 400 kV lines land here.' },
        { net = 'sapl', cat = 'Substation plant', label = '11 kV switchgear lineup (4 feeder breakers)', model = 'opslabs_sub_swgr', reach = 40.0, about = 'Every 11 kV feeder needs a breaker — 4 per lineup. [E] to switch locally.' },
        { net = 'sapl', cat = 'Substation plant', label = 'Busbar section 4 m', model = 'opslabs_sub_busbar', reach = 40.0, about = 'Links the GIS, transformers and switchgear.' },
        { net = 'sapl', cat = 'Substation plant', label = 'Protection relay panel', model = 'opslabs_sub_relay', reach = 40.0, about = 'Differential, distance, overcurrent, earth fault, under-frequency. No protection, no energising.' },
        { net = 'sapl', cat = 'Substation plant', label = 'Metering & monitoring panel', model = 'opslabs_sub_meter', reach = 40.0, about = 'kV, A, MW, MVAr, Hz — load readings on Grid control.' },
        { net = 'sapl', cat = 'Substation plant', label = '110 V DC battery & charger', model = 'opslabs_sub_battery', reach = 40.0, about = 'Keeps protection and breaker trip coils working. Required.' },
        { net = 'sapl', cat = 'Substation plant', label = 'Main earth bar (wall)', model = 'opslabs_sub_earth', reach = 40.0, about = 'The earthing system. Required.' },
        { net = 'sapl', cat = 'Substation plant', label = 'Control desk (SCADA screens)', model = 'opslabs_sub_control', reach = 40.0, about = '[E] substation control on site.' },
        { net = 'sapl', cat = 'Substation plant', label = 'HV cable sealing end', model = 'opslabs_sub_cable', reach = 40.0, about = 'Where the cables come in from the trench.' },
        -- customer supply: pole transformer → LV / service drop → cut-out → meter → consumer unit → (in the walls) sockets, lights, EV chargers
        { net = 'sapl', cat = 'Customer supply & metering', label = 'Service cut-out (house main fuse)', model = 'opslabs_mains_cutout', about = 'Where the service drop lands. Run the service cable to it.' },
        { net = 'sapl', cat = 'Customer supply & metering', label = 'Smart electricity meter', model = 'opslabs_mains_meter', about = '[E] read it: kWh used and the load right now' },
        { net = 'sapl', cat = 'Customer supply & metering', label = 'Outside meter cabinet', model = 'opslabs_mains_meterbox', about = 'Outside wall. Counts as the cut-out + meter in one.' },
        { net = 'sapl', cat = 'Fuse boards & isolators', label = 'Consumer unit (fuse board)', model = 'opslabs_mains_cu', about = 'Feeds every socket, light and EV charger nearby through the walls. [E] main switch.' },
        { net = 'sapl', cat = 'Fuse boards & isolators', label = 'Rotary isolator', model = 'opslabs_mains_isolator', about = '[E] isolate / switch on. Breaks the supply through it.' },
        { net = 'sapl', cat = 'Sockets & switches', label = 'Twin switched socket', model = 'opslabs_mains_socket2', sizeLabel = 'Style', sizes = {
            { label = 'White', model = 'opslabs_mains_socket2' }, { label = 'White with USB-A / USB-C (charges a phone)', model = 'opslabs_mains_socket2_usb' },
            { label = 'Brushed steel', model = 'opslabs_mains_socket2_chrome' } } },
        { net = 'sapl', cat = 'Sockets & switches', label = 'Single switched socket', model = 'opslabs_mains_socket1' },
        { net = 'sapl', cat = 'Sockets & switches', label = 'Outdoor socket (IP66)', model = 'opslabs_mains_socket_out' },
        { net = 'sapl', cat = 'Sockets & switches', label = 'Fused spur', model = 'opslabs_mains_spur' },
        { net = 'sapl', cat = 'Sockets & switches', label = 'Light switch', model = 'opslabs_mains_switch', about = '[E] switches the ceiling lights around it' },
        { net = 'sapl', cat = 'Lighting', label = 'LED ceiling panel 600 × 600', model = 'opslabs_mains_ledpanel' },
        { net = 'sapl', cat = 'Lighting', label = 'LED batten 1.2 m', model = 'opslabs_mains_batten' },
        { net = 'sapl', cat = 'Plug-in devices & chargers', label = 'Desk lamp (plugs in)', model = 'opslabs_mains_desklamp' },
        { net = 'sapl', cat = 'Temporary power', label = '4-way extension lead', model = 'opslabs_mains_extension' },
        { net = 'sapl', cat = 'Temporary power', label = 'Cable reel 25 m', model = 'opslabs_mains_reel' },
        { net = 'sapl', cat = 'Plug-in devices & chargers', label = 'Phone charger (USB-C cable)', model = 'opslabs_mains_phonecable', about = 'Stand next to it with your phone to charge' },
        { net = 'sapl', cat = 'Plug-in devices & chargers', label = 'Wireless charging pad', model = 'opslabs_mains_qipad', sizeLabel = 'Style', sizes = {
            { label = 'Flat pad', model = 'opslabs_mains_qipad' }, { label = 'Stand', model = 'opslabs_mains_qistand' } } },
        { net = 'sapl', cat = 'Plug-in devices & chargers', label = 'Laptop charger (65 W USB-C)', model = 'opslabs_mains_laptopcharger', about = 'Put it next to a laptop: runs and charges it' },
        { net = 'sapl', cat = 'EV charging', label = 'EV wallbox 7.4 kW', model = 'opslabs_mains_ev_wall' },
        { net = 'sapl', cat = 'EV charging', label = 'EV charging post', model = 'opslabs_mains_ev_post' },
        { net = 'sapl', cat = 'Temporary power', label = 'Portable generator 3 kVA (2 sockets)', model = 'opslabs_mains_generator', about = 'A supply of its own: [E] start / stop. Plug leads or a cable reel into it.' },
    },
    -- metal pole information plate (Branding & info)
    BrandColors = { { '#0a84ff', 'Blue' }, { '#14a0aa', 'Teal' }, { '#30d158', 'Green' }, { '#ff9f0a', 'Orange' }, { '#ff375f', 'Pink' }, { '#bf5af2', 'Purple' }, { '#1c1c1e', 'Black' }, { '#e5383b', 'Red' } },
    RotationOrder = 2,          -- euler order used to lay pieces on walls/ceilings (leave at 2)
}

-- Mains electricity (San Andreas Power & Light). Power flows from a pole transformer (on a power pole whose cut-out
-- fuses are in) or a running generator, along power cable (LV, service drop, mains, flex) whose ends touch kit, into
-- consumer units. Sockets, lights and EV chargers near a live consumer unit are fed "through the walls"; plug-in kit
-- plugs into the nearest socket / extension / reel / generator outlet in reach (a flex lead is drawn to it).
-- Positions are in the model's own frame (x right, y back, z up; fronts face -Y): o = outlets { x, y, z, nx, ny, nz }.
Config.Mains = {
    Enabled = true,
    Tick = 3,                     -- seconds between recomputes (load, meters, batteries)
    AutoWireRadius = 14.0,        -- metres from a consumer unit that sockets / lights / EV chargers are fed through the walls
    AutoWireHeight = 6.0,         -- ... and this far above / below it
    PoleReach = 1.6,              -- a power cable end this close (sideways) to a power pole is clamped to it
    KitReach = 0.9,               -- ... this close to supply kit (cut-out, meter, consumer unit...) connects to it
    JointReach = 0.35,            -- two cable ends this close are jointed
    TransformerReach = 0.8,       -- a transformer this close (sideways) to a power pole is fitted on it
    LightSwitchRadius = 8.0,      -- a light switch works the ceiling lights this close to it
    UseDistance = 1.3,            -- [E] at sockets, switches, generators...
    LeadDrawDistance = 40.0,      -- plug tops + flex leads are drawn within this range
    Supply = { opslabs_mains_cutout = true, opslabs_mains_meter = true, opslabs_mains_meterbox = true, opslabs_mains_isolator = true,
        opslabs_power_cutouts = true, opslabs_power_pothead = true, opslabs_power_lv_connectors = true, opslabs_house_pole = true },
    Switchable = { opslabs_mains_isolator = true, opslabs_mains_cu = true, opslabs_solar_dciso = true },
    ConsumerUnit = 'opslabs_mains_cu',
    Meters = { opslabs_mains_meter = true, opslabs_mains_meterbox = true },
    Transformer = 'opslabs_power_transformer',
    Generator = 'opslabs_mains_generator',
    -- hard-wired kit fed from a consumer unit (through the walls, or by mains cable to it)
    Wired = {
        opslabs_mains_socket2 = { o = { { -0.033, -0.009, 0.036, 0, -1, 0 }, { 0.033, -0.009, 0.036, 0, -1, 0 } }, usb = false },
        opslabs_mains_socket2_usb = { o = { { -0.033, -0.009, 0.036, 0, -1, 0 }, { 0.033, -0.009, 0.036, 0, -1, 0 } }, usb = true },
        opslabs_mains_socket2_chrome = { o = { { -0.033, -0.009, 0.036, 0, -1, 0 }, { 0.033, -0.009, 0.036, 0, -1, 0 } } },
        opslabs_mains_socket1 = { o = { { -0.007, -0.009, 0.036, 0, -1, 0 } } },
        opslabs_mains_socket_out = { o = { { 0.0, -0.06, 0.08, 0, -1, 0 } } },
        opslabs_mains_spur = { watts = 0 },
        opslabs_mains_switch = { lightSwitch = true },
        opslabs_mains_ledpanel = { lamp = true, watts = 36, light = { 0.0, 0.0, -0.05, 9.0, 4.0 } },        -- x, y, z, range, brightness
        opslabs_mains_batten = { lamp = true, watts = 40, light = { 0.0, 0.0, -0.06, 9.0, 4.0 } },
        opslabs_mains_ev_wall = { ev = true, watts = 7400 },
        opslabs_mains_ev_post = { ev = true, watts = 7400 },
        -- OPS Fuel kit runs off the station's consumer unit
        opslabs_fuel_dispenser = { watts = 750 },
        opslabs_fuel_atg = { watts = 60 },
        opslabs_fuel_canopy = { lamp = true, watts = 1600, light = { 0.0, 0.0, 4.8, 18.0, 6.0 } },
    },
    -- plug-in kit: plugs into the nearest free outlet within reach (metres of lead); plug = plug top model; lead = flex colour
    PlugIn = {
        opslabs_mains_extension = { reach = 2.5, plug = 'opslabs_mains_plug', lead = 'flex', switch = true, lead_at = { 0.18, 0.0, 0.02 },
            o = { { -0.130, 0.0, 0.04, 0, 0, 1 }, { -0.054, 0.0, 0.04, 0, 0, 1 }, { 0.022, 0.0, 0.04, 0, 0, 1 }, { 0.098, 0.0, 0.04, 0, 0, 1 } } },
        opslabs_mains_reel = { reach = 25.0, plug = 'opslabs_mains_plug_black', lead = 'flexblack', switch = true, lead_at = { 0.0, -0.06, 0.06 },
            o = { { 0.0, -0.061, 0.20, 0, -1, 0 }, { 0.0, -0.061, 0.14, 0, -1, 0 } } },
        opslabs_mains_desklamp = { reach = 2.0, plug = 'opslabs_mains_plug', lead = 'flex', switch = true, lamp = true, watts = 8, lead_at = { 0.0, 0.07, 0.01 },
            light = { 0.0, -0.17, 0.33, 4.0, 3.0 } },
        opslabs_mains_phonecable = { reach = 1.8, plug = 'opslabs_mains_plug_usb', lead = 'flex', charger = 'wired', watts = 20, lead_at = { 0.0, 0.075, 0.003 } },
        opslabs_mains_qipad = { reach = 1.8, plug = 'opslabs_mains_plug_usb', lead = 'flex', charger = 'wireless', watts = 15, lead_at = { 0.0, 0.047, 0.004 } },
        opslabs_mains_qistand = { reach = 1.8, plug = 'opslabs_mains_plug_usb', lead = 'flex', charger = 'wireless', watts = 15, lead_at = { 0.0, 0.04, 0.006 } },
        opslabs_mains_laptopcharger = { reach = 2.0, plug = 'opslabs_mains_plug', lead = 'flexblack', laptop = true, watts = 65, lead_at = { 0.055, 0.0, 0.014 } },
    },
    GeneratorOutlets = { { 0.08, -0.2, 0.257, 0, -1, 0 }, { 0.17, -0.2, 0.257, 0, -1, 0 } },
    GeneratorWatts = 3000,
    -- phone charging (opslabs-phone asks ChargerNear): stand this close with your phone
    PhoneChargeDistance = 1.2,
    -- EV charging: % of a tank per second while plugged in, how close the car must be
    EV = { Rate = 0.8, CarDistance = 6.0 },
    -- laptops (opslabs_laptop): battery % per minute while in use on battery / charging on a laptop charger beside it
    Laptop = { Drain = 0.7, Charge = 2.5, ChargerDistance = 1.6 },
}

-- Power for network kit (needs the mains / grid built in game). With NetworkNeedsPower on:
--   routers / gateways / switches / ONTs need a live socket (or extension / generator outlet) within SocketReach;
--   access points also run on PoE: CAT6 (terminated both ends) to a powered PoE switch, within its watt budget;
--   cell towers need a live pole transformer within CellReach and ride through a power cut on their batteries.
-- Engineer console: every menu of this resource (/towers, tool kits, nearby kit, fuel, CCTV, grid, ladders, van …)
-- in one full-screen panel with sections, search and keyboard control. false = the classic ox_lib list menus.
-- Live (OPS Hub → Settings or here), no restart.
Config.Console = {
    Enabled = true,
    Title = 'Engineer console',
}

-- Menu style: 'console' (the full-screen engineer console) or 'classic' (the small ox_lib list menus). This is only the
-- default — every player can switch in /towers → Menu style (kept on their PC). Up a pole, Z opens the small quick menu.
Config.MenuStyle = { Default = 'console', PoleQuickKey = 20 }   -- 20 = Z

-- Third eye (ox_target / tgiann-target): look at the bottom of any pole — placed or GTA's own — for climb, pole kit,
-- Line Tool, live data, fault finder and repair. The [E] prompts stay as a fallback when no target resource is running.
Config.Target = { Enabled = true, Distance = 2.5 }

-- Danger zone (/towers → Danger zone): mass delete for tower admins, behind its own username + password. The first
-- login is admin / admin and has to be changed before anything can be deleted (stored hashed in the database, not
-- here). Every wipe is backed up to danger_backups/ and can be restored from the same menu.
-- OPS City network (server/citybuild.lua · OPS Hub → Grid / Power / Internet / Gunshots / Fuel / CCTV → "Build complete
-- network"): builds a real, connected, powered network across the whole map in one go — a power station and 400 kV pylon
-- lines to a substation in every district, 11 kV pole lines along the roads with transformers, reclosers and street
-- lights, and per district a telephone exchange with fibre on telecom poles, a customer house on broadband, a fuel
-- station, CCTV, a cell mast and gunshot sensors. An admin's game surveys the ground (they're hidden for a few minutes).
-- Everything is ordinary kit (created_by 'OPS City') that you control and repair like anything else; Remove takes it away.
Config.City = {
    Enabled = true,
    Station = { name = 'Palmer-Taylor Power Station', x = 2740.0, y = 1540.0, units = 3 },
    PylonSpacing = 300.0,         -- metres between 400 kV pylons
    PolesPerLine = 8,             -- poles each way along the road from each district's lot (power and telecom)
    PoleSpacing = 40.0,
    -- district centres: a lot is searched for on a road near each (skipped if none is flat and clear)
    Districts = {
        { name = 'Downtown Los Santos', x = 200.0, y = -850.0 }, { name = 'Vinewood', x = 330.0, y = 180.0 },
        { name = 'Rockford Hills', x = -750.0, y = -200.0 }, { name = 'Del Perro', x = -1450.0, y = -500.0 },
        { name = 'Vespucci', x = -1150.0, y = -1350.0 }, { name = 'Little Seoul', x = -650.0, y = -950.0 },
        { name = 'Strawberry', x = 100.0, y = -1650.0 }, { name = 'Mirror Park', x = 1100.0, y = -550.0 },
        { name = 'La Mesa', x = 850.0, y = -1200.0 }, { name = 'El Burro Heights', x = 1350.0, y = -1750.0 },
        { name = 'Elysian Island', x = 200.0, y = -2700.0 }, { name = 'Pacific Bluffs', x = -2000.0, y = -300.0 },
        { name = 'Vinewood Hills', x = -450.0, y = 700.0 }, { name = 'Chumash', x = -3150.0, y = 1050.0 },
        { name = 'Tongva Hills', x = -1800.0, y = 2000.0 }, { name = 'Great Chaparral', x = -250.0, y = 2500.0 },
        { name = 'Harmony', x = 550.0, y = 2700.0 }, { name = 'Grand Senora', x = 1200.0, y = 2700.0 },
        { name = 'Sandy Shores', x = 1850.0, y = 3700.0 }, { name = 'Grapeseed', x = 1700.0, y = 4800.0 },
        { name = 'Paleto Bay', x = -250.0, y = 6250.0 }, { name = 'Murrieta Heights', x = 1150.0, y = -2050.0 },
    },
}

Config.Danger = { Enabled = true, SessionMinutes = 15, MaxFails = 5, LockMinutes = 10 }

-- World cleanup: hide GTA's own street furniture so only what you build stands in the world. Only the GTA models
-- listed here are hidden — OPS kit (opslabs_*) never is. Change it here, on OPS Hub → Settings (World cleanup) or in the
-- phone's Developer app → World Cleanup; it applies live (no restart). Hidden around every player as they move.
-- Note: GTA's overhead wires are part of the map, not separate poles, so wires can stay where poles are removed;
-- AI traffic still stops at junctions without the lights.
Config.WorldCleanup = {
    Enabled = true,
    GasStations = true,       -- GTA fuel pumps (OPS Fuel stations you build keep working)
    Poles = true,             -- GTA wooden power / phone (telegraph) poles, wall brackets and big pylons
    TrafficLights = true,     -- GTA traffic lights and level-crossing lights
    Radius = 400.0,           -- metres hidden around each player (re-applied as they move)
    Models = {
        GasStations = { 'prop_gas_pump_1a', 'prop_gas_pump_1b', 'prop_gas_pump_1c', 'prop_gas_pump_1d', 'prop_gas_pump_old2', 'prop_gas_pump_old3', 'prop_vintage_pump' },
        Poles = { 'prop_telegraph_01a', 'prop_telegraph_01b', 'prop_telegraph_01c', 'prop_telegraph_01d', 'prop_telegraph_01e', 'prop_telegraph_01f', 'prop_telegraph_01g',
            'prop_telegraph_02a', 'prop_telegraph_02b', 'prop_telegraph_03', 'prop_telegraph_04a', 'prop_telegraph_04b', 'prop_telegraph_05a', 'prop_telegraph_05b',
            'prop_telegraph_05c', 'prop_telegraph_06a', 'prop_telegraph_06b', 'prop_telegraph_06c', 'prop_telegwall_01a', 'prop_telegwall_02a', 'prop_telegwall_03a',
            'prop_telegwall_03b', 'prop_telegwall_04a', 'prop_pylon_01', 'prop_pylon_02', 'prop_pylon_03', 'prop_pylon_04' },
        TrafficLights = { 'prop_traffic_01a', 'prop_traffic_01b', 'prop_traffic_01d', 'prop_traffic_02a', 'prop_traffic_02b', 'prop_traffic_03a', 'prop_traffic_03b',
            'prop_traffic_lightset_01', 'prop_traffic_rail_1a', 'prop_traffic_rail_1c', 'prop_traffic_rail_2', 'prop_traffic_rail_3' },
    },
    Extra = {},               -- any other GTA model names to hide, e.g. { 'prop_elecbox_01a', 'prop_streetlight_01' }
}

-- San Andreas Power & Light · power fault finder and power restoration kit (tool kit → electrical tools, /towers → Tools,
-- /powercheck). Stand at anything electrical (socket, light, plug-in kit, consumer unit, meter, generator, solar, pole,
-- transformer, mast, router, ONT): the fault finder traces its supply back to the power station and says why it has no
-- power; the restoration kit fixes every cause it can (switches, plugs, generators, pole fuses / earths, failed
-- transformers, line faults, tripped / shed / locked-out breakers, substations, generation, equipment faults) and says
-- what still has to be built. Grid crews (Config.Grid.CrewJobs) and cabling engineers only.
Config.PowerTools = {
    Enabled = true,
    Range = 4.0,              -- metres: the kit you're standing at
    SecondsPerFix = 4,        -- restoration time per cause fixed (progress bar)
    Command = 'powercheck',   -- false = no command
    RepairCommand = 'powerrepair',   -- the handheld power repair tool (false = no command)
    RepairSeconds = 6,        -- how long a repair with the handheld tool takes
}

-- SAPL Line Tool (insulated hot stick: tool kit → electrical tools, or /linetool). Aim at any power kit — pole, pylon,
-- substation, power station, wind turbine, pole transformer / recloser, house supply or consumer unit — to see if it's
-- live, every conductor landed on it and every step still missing (with the fix: place the missing kit through the
-- tool, or be shown where it has to go first). Connect a new conductor from it, snap a jumper off / on (the line stays
-- strung but is disconnected — grid and LV both respect it), move a conductor's end onto another pole, or re-string a
-- conductor as a different class. Every power pole also gets a LineSense monitor showing its live data.
Config.PowerLine = {
    Enabled = true,
    Command = 'linetool',         -- false = only from the tool kit
    Range = 7.0,                  -- metres: kit you aim at / stand beside
    MoveReach = 60.0,             -- metres: the longest span a conductor end can be moved to (from its next fixing)
    WhereSeconds = 120,           -- how long a "show me where" marker stays up
    Monitor = {
        Enabled = true,
        Model = 'opslabs_pole_monitor', Off = 'opslabs_pole_monitor_off',   -- opslabs-props (lit LCD / dark with a red LED)
        Height = 3.0,             -- metres up the pole
        Radius = 0.128,           -- the pole's radius there (the monitor's bands are made for it)
        Stream = 90.0,            -- spawn monitors on poles this close
        PanelDistance = 9.0,      -- the live data panel shows this close
        Refresh = 3000,           -- ms between live data updates
    },
}

Config.Power = {
    -- every GTA building (and GTA's own street lamps) has no power: the city is dark at night. Vehicle lights are NOT affected.
    -- Only what you build and hook up to the grid gives light (built buildings, street lights fed from a live transformer, lamps).
    CityBlackout = true,
    NetworkNeedsPower = true,
    SocketReach = 3.0,
    PoESources = { opslabs_poe_switch8 = 60 },          -- model = PoE budget in watts
    PoEDevices = { opslabs_ap_halo = 13, opslabs_ap_halo_ceiling = 13, opslabs_ap_beam = 12, opslabs_ap_beam_ceiling = 12 },   -- model = watts drawn
    CellReach = 350.0,
    CellBatteryMinutes = 120,
    BuildingReach = { opslabs_grid_subshell = 10.0, opslabs_house_customer = 8.0, opslabs_depot = 14.0, opslabs_exchange_building = 10.0 },   -- a live fuse board this close lights the building
}

-- OPS Fuel: real fuel. Vehicles burn it and only fill up at stations built in game (GTA's own pumps do nothing).
Config.Fuel = {
    Enabled = true,
    Products = {
        ul = { label = 'Unleaded 95', short = 'UL', color = '#24a040', price = 1.45, wholesale = 0.95 },
        sup = { label = 'Super 98', short = 'SUP', color = '#185cce', price = 1.62, wholesale = 1.08 },
        dsl = { label = 'Diesel', short = 'DSL', color = '#1c1c1e', price = 1.52, wholesale = 1.00 },
    },
    Tanks = { opslabs_fuel_tank_ul = { product = 'ul', litres = 30000 }, opslabs_fuel_tank_sup = { product = 'sup', litres = 30000 },
        opslabs_fuel_tank_dsl = { product = 'dsl', litres = 30000 }, opslabs_fuel_tank_agt = { product = 'dsl', litres = 10000, above = true } },
    Dispenser = 'opslabs_fuel_dispenser', FillPoint = 'opslabs_fuel_fillpoint', Vent = 'opslabs_fuel_vent',
    Controller = 'opslabs_fuel_atg', EStop = 'opslabs_fuel_estop', Gantry = 'opslabs_fuel_gantry',
    PipeReach = 1.5,            -- a pipe end this close to fuel kit connects to it (ends this close to each other: a joint)
    StationRadius = 70.0,       -- tank gauge / e-stop cover kit this close
    UseDistance = 2.2,          -- [E] at a dispenser / fill point / gauge
    CarDistance = 5.0,          -- the vehicle must be this close to the dispenser (hose length)
    FlowLpm = 40.0,             -- litres a minute through a nozzle (the pump runs ~4× game speed: 160 L/min real time)
    Overfill = 0.95,            -- deliveries stop at 95 % of the tank
    Society = 'society_fuel',   -- sales paid into this esx_addonaccount (if it exists); deliveries charged at wholesale
    Jobs = {},                  -- who can set prices / reset alarms / deliver (empty = anyone who can build kit)
    -- consumption: % of the tank per minute at full throttle-ish (scaled by RPM); idling burns a little
    Burn = 1.1, Idle = 0.06,
    StartLevel = { 35, 85 },   -- vehicles nobody has fuelled yet get a random level in this range
    Electric = { 'voltic', 'voltic2', 'raiden', 'neon', 'cyclone', 'tezeract', 'surge', 'dilettante', 'dilettante2', 'khamelion', 'imorgon', 'iwagen',
        'omnisegt', 'virtue', 'airtug', 'caddy', 'caddy2', 'caddy3', 'rcbandito', 'buffalo5', 'powersurge', 'cyclone2', 'coureur' },
    -- classes that need diesel (the rest take unleaded / super); classes that don't use road fuel at all
    DieselClasses = { [10] = true, [11] = true, [17] = true, [19] = true, [20] = true },
    DieselModels = { 'sandking', 'sandking2', 'rebel', 'rebel2', 'bison', 'bison2', 'bison3', 'mule', 'mule2', 'mule3', 'mule4', 'pounder', 'pounder2', 'benson', 'phantom', 'phantom3', 'hauler', 'packer', 'bus', 'coach', 'airbus', 'rentalbus', 'tourbus', 'ambulance', 'firetruk', 'riot', 'pbus' },
    NoFuelClasses = { [13] = true, [14] = true, [15] = true, [16] = true, [21] = true },
    -- road tankers: these trailers (or rigid tankers) carry 3 compartments
    Tankers = { tanker = 33000, tanker2 = 33000, armytanker = 20000 },
    Compartments = 3,
    -- tank monitoring events (per tank per hour of game time): water in after rain, slow leaks
    WaterChance = 0.004, LeakChance = 0.0015, LeakLph = 30.0,
}

-- OPS Showcase (/opsshowcase): one of everything, built for real and connected, round where an admin stands.
-- Built at Los Santos International Airport (flat, z ≈ 13.9) — AutoBuild puts it there on start if it isn't built yet.
-- Site: centre of the street; h: which way "ahead" points (the street runs across it). Needs ~620 × 290 m.
-- ClearPlanes: planes (vehicle class 16) inside the showcase area are deleted — AI and parked ones, and (if
-- ClearPlayerPlanes) ones players fly in low. Parked-plane generators in the area are switched off.
Config.Showcase = {
    Site = { x = -1560.0, y = -2850.0, z = 13.94, h = 60.0 },
    AutoBuild = true,
    ClearPlanes = true, ClearPlayerPlanes = true, ClearHeight = 120.0,   -- metres above the site
    ClearClasses = { [16] = true },                                       -- 16 planes (add [15] = true for helicopters)
    Area = { -280, -90, 360, 220 },                                       -- showcase footprint (site frame: x0, y0, x1, y1)
}

-- OPS Track: GPS trackers fitted inside vehicles. They report over OPS Mobile (no signal = no live position, the
-- unit stores it and sends it when it gets signal back). Owners (owned_vehicles) use /track; staff use /towers → OPS Track.
Config.Track = {
    Enabled = true,
    Jobs = {},                    -- who can install / remove trackers (empty = anyone who can build kit)
    Report = 10,                  -- seconds between position reports
    ArmDistance = 40.0,           -- armed: moving further than this (or the ignition coming on) raises a theft alert
    BackupHours = 48,             -- Pro: how long the backup battery runs it after the vehicle power is cut
    Units = {
        mini = { label = 'OPS Track Mini', sub = 'Plug-and-play on a fuse tap · internal antennas · no backup battery', backup = false, io = false },
        pro = { label = 'OPS Track Pro', sub = 'Hard-wired · external GPS / LTE antennas · 48 h backup battery · ignition & door inputs · immobiliser relay', backup = true, io = true },
    },
}

-- OPS Network ISP (server/opsisp.lua): customer lines on top of the fibre network. A line = a customer, a package and
-- (once installed) an ONT. Ordering raises an install job; when the engineer finishes it the line goes live: the ONT is
-- provisioned, IP addresses are assigned, the contract starts and the first bill is taken. Monthly bills every
-- BillingDays; unpaid past GraceDays → suspended until paid. Lines are monitored; several dropping together near
-- each other open an outage (emergency job + customers told). All public IP ranges are documentation ranges (fictional).
Config.OpsIsp = {
    Enabled = true,
    BillingDays = 7, GraceDays = 3,               -- real days
    MonitorEvery = 30,                           -- seconds
    OutageMinLines = 3, OutageRadius = 450.0,    -- lines down together within this many metres = an outage
    LinkRadius = 60.0,                           -- an online ONT this close to an installed line's address becomes its ONT
    Pools = {                                    -- IPAM (fictional: RFC 5737 documentation ranges)
        dynamic = { '203.0.113.0/24' },          -- residential (dynamic, shared CG-NAT style)
        static = { '198.51.100.0/24' },          -- business static IPs
        dedicated = { '192.0.2.0/24' },          -- leased lines (blocks of addresses)
    },
    Dns = { '203.0.113.53', '203.0.113.54' },    -- OPS DNS resolvers
    Plans = { [80] = 'fibre150', [150] = 'fibre150', [500] = 'fibre500', [900] = 'fibre900', [1000] = 'fibre900', [10000] = 'fibre900' },   -- package speed → ONT plan
    Packages = {
        { code = 'home150', name = 'OPS Fibre Home 150', segment = 'residential', down = 150, up = 30, price = 35, setup = 0, ip = 'dynamic', contract = 12, sla = 'standard', fix = 48, desc = 'Everyday streaming and browsing for a busy home.' },
        { code = 'home500', name = 'OPS Fibre Home 500', segment = 'residential', down = 500, up = 75, price = 45, setup = 0, ip = 'dynamic', contract = 12, sla = 'standard', fix = 48, desc = 'Fast fibre for gamers and big households.' },
        { code = 'home900', name = 'OPS Fibre Home 900', segment = 'residential', down = 900, up = 110, price = 60, setup = 0, ip = 'dynamic', contract = 18, sla = 'standard', fix = 48, desc = 'Our fastest home fibre.' },
        { code = 'copper80', name = 'OPS Broadband 80 (copper)', segment = 'residential', down = 80, up = 20, price = 28, setup = 0, tech = 'copper', ip = 'dynamic', contract = 12, sla = 'standard', fix = 72, desc = 'VDSL over the phone line where fibre isn’t ready yet.' },
        { code = 'biz500', name = 'OPS Business Fibre 500', segment = 'business', down = 500, up = 500, price = 120, setup = 150, ip = 'static', statics = 1, contract = 24, sla = 'business', fix = 8, desc = 'Symmetric fibre, 1 static IP, 8-hour fix.' },
        { code = 'biz1000', name = 'OPS Business Fibre 1000', segment = 'business', down = 1000, up = 1000, price = 180, setup = 150, ip = 'static', statics = 5, contract = 24, sla = 'business', fix = 4, desc = 'Gigabit symmetric, 5 static IPs, 4-hour fix.' },
        { code = 'ded1g', name = 'OPS Dedicated 1 Gb leased line', segment = 'business', down = 1000, up = 1000, price = 450, setup = 1000, ip = 'dedicated', statics = 8, contract = 36, sla = 'premium', fix = 4, desc = 'Uncontended, a /29 block, 99.99 % uptime.' },
        { code = 'ded10g', name = 'OPS Dedicated 10 Gb leased line', segment = 'business', down = 10000, up = 10000, price = 1500, setup = 2500, ip = 'dedicated', statics = 8, contract = 36, sla = 'premium', fix = 2, desc = 'Data-centre grade 10 Gb, /29, 2-hour fix.' },
        { code = 'gov1g', name = 'OPS Public Sector Secure 1 Gb', segment = 'government', down = 1000, up = 1000, price = 400, setup = 500, ip = 'dedicated', statics = 8, contract = 36, sla = 'critical', fix = 2, desc = 'For police, government and health: VPN-ready, 2-hour fix.' },
    },
}

-- OPS Secure CCTV. Cameras look out along their front (-Y); lens = where the picture is taken from (model frame).
--   ip      : CAT6 (crimped both ends) to an NVR (its own PoE ports) or to a powered PoE switch cabled on to an NVR
--   analog  : CAT6 / coax (via balun) straight to a DVR
--   wifi    : a recorder within SiteRadius and a powered Wi-Fi router / AP within WifiRange (the cube also needs a socket)
-- Recorders need a live socket within 3 m. Monitors, video walls and PTZ keyboards show the nearest recorder's cameras.
-- Remote viewing (phone app): the system's remote viewing is on and its NVR is cabled to an online gateway router.
Config.Cctv = {
    RelayCulling = 600.0,         -- /cctvrelay: how far (m) round its ped a relay is sent players and cars (OneSync culling)
    RelayMoveBeyond = 450.0,      -- cameras further than this from where the relay stands: its hidden ped goes there too
    -- always-on relays: these accounts (any identifier: license:…, fivem:…, discord:…) start relaying on their own when
    -- they join — leave one logged in on a spare PC and OPS Hub stays live with nobody else in the city
    RelayAccounts = {},
    NightVision = true,           -- IR cameras switch to night vision after dark (master switch; OPS Hub can flip it and set cameras one by one)
    BackgroundEvery = 60,         -- a relay with nothing else to do refreshes every online camera at least this often (s)
    RelayFilter = 0.25,           -- strength of the CCTV look on relay pictures (0 = clean picture, 1 = heavy scanlines)
    Enabled = true,
    SiteRadius = 60.0, WifiRange = 40.0, PlugReach = 3.0, EventEvery = 5, MotionCooldown = 30, AnprCooldown = 90,
    FaultsPerCameraHour = 0.01,       -- chance per camera per real hour of a fault (dirty lens, cable, dead camera)
    RetentionDays = 7,
    Cameras = {
        opslabs_cctv_bullet = { label = 'Bullet camera 4K (IP, PoE)', kind = 'ip', poe = 7, fov = 85, range = 40, lens = { 0.0, -0.28, 0.06 }, ir = true },
        opslabs_cctv_dome = { label = 'Dome camera (IP, PoE)', kind = 'ip', poe = 6, fov = 100, range = 25, lens = { 0.0, -0.2, 0.055 }, ir = true },
        opslabs_cctv_turret = { label = 'Turret camera (IP, PoE)', kind = 'ip', poe = 5, fov = 100, range = 25, lens = { 0.0, -0.125, 0.043 }, ir = true },
        opslabs_cctv_ptz = { label = 'PTZ speed dome (IP, PoE+)', kind = 'ip', poe = 25, fov = 60, range = 90, lens = { 0.0, -0.35, 0.05 }, ptz = true, ir = true },
        opslabs_cctv_anpr = { label = 'ANPR / LPR camera', kind = 'ip', poe = 12, fov = 30, range = 30, lens = { 0.0, -0.38, 0.089 }, anpr = true, ir = true },
        opslabs_cctv_thermal = { label = 'Thermal bi-spectrum camera', kind = 'ip', poe = 15, fov = 50, range = 60, lens = { 0.0, -0.34, 0.11 }, thermal = true },
        opslabs_cctv_fisheye = { label = 'Fisheye 360° camera', kind = 'ip', poe = 6, fov = 170, range = 15, lens = { 0.0, -0.065, 0.08 } },
        opslabs_cctv_analog = { label = 'Analogue HD-TVI bullet (DVR)', kind = 'analog', fov = 85, range = 30, lens = { 0.0, -0.28, 0.06 }, ir = true },
        opslabs_cctv_wifi = { label = 'Wireless indoor camera', kind = 'wifi', fov = 110, range = 12, lens = { 0.0, -0.035, 0.05 }, plug = true },
        opslabs_cctv_doorbell = { label = 'Video doorbell', kind = 'wifi', fov = 150, range = 6, lens = { 0.0, -0.017, 0.1 }, doorbell = true },
    },
    Recorders = {
        opslabs_cctv_nvr = { kind = 'nvr', label = 'NVR 16 channel · 8 × PoE', channels = 16, poePorts = 8, poeBudget = 120, hddTB = 8 },
        opslabs_cctv_dvr = { kind = 'dvr', label = 'DVR 8 channel', channels = 8, hddTB = 2 },
    },
    Viewers = { opslabs_cctv_monitor = true, opslabs_cctv_videowall = true, opslabs_cctv_keyboard = true },
    PoESwitches = { opslabs_poe_switch8 = 60 },
}

-- OPS Data centres (server/datacentre.lua) and OPS Cloud. A data hall = the racks, UPS, generators and cooling within
-- SiteRadius of each other. A rack is powered from a socket within PlugReach (no UPS: a power cut drops it) or from
-- a UPS in the hall (mains / generator, else battery). Servers live in rack units ([E] on the rack); they need the
-- rack's ToR switch and a CAT6 path from the rack to a router with internet. Heat: every powered server adds its
-- watts; CRAC units remove CoolingKw each — an overloaded hall warms up, servers throttle at TempWarn and shut down at
-- TempShutdown. Compute servers have a role: 'cloud' hosts OPS Cloud VMs (placed and live-migrated automatically),
-- 'opsweb' / 'dns' / 'mail' run those OPS services — once any server has that role, the service is only up while
-- one of them is. Faults (disk, PSU, fan, dead) and hall problems raise OPS Data jobs.
Config.DataCentre = {
    Enabled = true,
    Rack = 'opslabs_dc_rack', Ups = 'opslabs_dc_ups', Generators = { opslabs_generator = true, opslabs_mains_generator = true },
    Cooling = { opslabs_crac = 30 },             -- kW each unit removes
    SiteRadius = 25.0, PlugReach = 3.0,
    U0 = 0.10, UH = 0.04445, Units = 42, FrontY = -0.452, LedX = -0.215,
    UpsKw = 40, UpsMinutes = 15,                 -- battery runtime (real minutes) at full UPS load
    Ambient = 21, TempWarn = 32, TempShutdown = 40, Tick = 15,
    FaultsPerServerHour = 0.01,
    DefaultRegion = 'LS-1',
    Kinds = {
        srv1u = { label = 'Halcyon C1 compute (1U)', model = 'opslabs_dc_srv1u', u = 1, watts = 450, vcpu = 64, ram = 256, compute = true },
        srv2u = { label = 'Halcyon C2 compute (2U)', model = 'opslabs_dc_srv2u', u = 2, watts = 900, vcpu = 128, ram = 1024, compute = true },
        storage = { label = 'Halcyon S4 SAN storage (4U · 96 TB)', model = 'opslabs_dc_storage', u = 4, watts = 650, tb = 96 },
        switch = { label = 'Meridian TOR-48X switch (1U)', model = 'opslabs_dc_switch', u = 1, watts = 180, switch = true },
        fw = { label = 'Bastion FW-2400 firewall (1U)', model = 'opslabs_dc_fw', u = 1, watts = 140, firewall = true },
        blank = { label = 'Blanking panel (1U)', model = 'opslabs_dc_blank', u = 1, watts = 0 },
    },
    Roles = { cloud = 'OPS Cloud host (customer VMs)', opsweb = 'OPS Web shared hosting', dns = 'OPS DNS resolver', mail = 'OPS Web mail' },
    Faults = {
        disk = { label = 'Failed drive', degraded = true, fix = 'Hot-swapping the drive', secs = 25 },
        psu = { label = 'Power supply failed', down = true, fix = 'Replacing the PSU', secs = 30 },
        fan = { label = 'Fan failure (running hot)', heat = 9, fix = 'Replacing the fan module', secs = 20 },
        dead = { label = 'Motherboard failure', down = true, fix = 'Swapping the motherboard', secs = 45 },
    },
}

-- Gunshot detection (OPS Sentinel sensors, Telecom equipment → Public safety, or G up a pole / ladder).
-- Every client reports its own gunfire; each sensor that's online (OPS Mobile signal where it's fitted, no fault)
-- and in earshot hears it. 1 sensor = rough area, 2 = closer, 3+ = triangulated to a few metres. Shots close
-- together in time and place are one incident. Police get a map alert + phone notification; OPS Hub shows them all.
Config.Gunshot = {
    Enabled = true,
    Model = 'opslabs_gunshot_sensor',
    Range = 450.0,                 -- metres a sensor hears a normal gunshot
    SilencedRange = 60.0,          -- ... a suppressed one
    MinBars = 1,                   -- OPS Mobile signal the sensor needs to report (LTE backhaul)
    Accuracy = { 70.0, 25.0, 6.0 },  -- metres: heard by 1 / 2 / 3+ sensors
    MergeSeconds = 12,             -- shots within this long ...
    MergeDistance = 150.0,         -- ... and this close are the same incident
    AlertJobs = { 'police', 'sheriff', 'state' },
    AlertBlipSeconds = 180,
    Keep = 500,                    -- incidents kept in the database
    -- no alerts from the gun ranges
    Exempt = { { 13.0, -1097.0, 29.8, 30.0 }, { 821.6, -2163.6, 29.6, 30.0 } },
}

-- Power grid (San Andreas Power & Light · OPS Hub → Grid control). The grid is what engineers BUILD in game:
--   power station / wind turbine → 400 kV transmission conductor on pylons → primary substation (400 / 11 kV) →
--   11 kV feeders (HV conductor on power poles, through reclosers) → pole transformers (cut-out fuses) → LV / service
--   drops → houses (Config.Mains). Every run's colour sets its voltage: 'transmission' = 400 kV, 'hv' = 11 kV, the rest LV.
-- Each 11 kV run leaving a substation is a FEEDER with its own breaker; each transmission run touching a substation or
-- station has a LINE breaker. Control (OPS Hub, or [E] at the substation / station / recloser in game) switches them.
-- Load comes from the homes behind every pole transformer (TransformerKW × time of day) plus real in-game load.
-- Protection is automatic: faults trip the nearest breaker / recloser upstream (reclosers try again), overloads trip,
-- under-frequency sheds feeders. Faults need a crew at the real spot ([E] at the yellow marker).
Config.Grid = {
    Enabled = true,
    Tick = 2,                       -- seconds between solves
    Hz = 50.0,
    CrewJobs = { 'electrician', 'sapl' },   -- besides cabling engineers / admins: who get crew jobs, repair and operate kit in game
    RepairSeconds = 25,
    FaultRate = 0.6,                -- random faults per real hour across the network (× StormFactor in a thunderstorm)
    StormFactor = 8,
    Station = { model = 'opslabs_grid_station', units = 4, unitMW = 120, start = 90, reach = 34.0 },
    Wind = { model = 'opslabs_grid_wind', mw = 3.0, reach = 10.0 },
    Substation = { model = 'opslabs_grid_substation', mva = 60, tx = 2, reach = 19.0 },
    -- substations you build: the fitted building is complete; the empty building — or ANY building with an RTU pole
    -- beside it — becomes a substation from the plant fitted within SubKit.radius (it then works as the kit allows)
    SubSites = {
        opslabs_grid_subbuilding = { kind = 'fitted', mva = 60, tx = 2, feeders = 8, reach = 16.0, scada = true },
        opslabs_grid_subshell = { kind = 'shell', reach = 16.0 },
        opslabs_grid_rtu = { kind = 'rtu', reach = 20.0, scada = true },
    },
    SubKit = {
        radius = 16.0,                 -- plant this close to the building / RTU pole belongs to it
        txMVA = 30,                    -- per power transformer
        feedersPerLineup = 4,          -- 11 kV feeder circuit breakers per switchgear lineup
        parts = { opslabs_sub_tx = 'tx', opslabs_sub_gis = 'hv', opslabs_sub_swgr = 'mv', opslabs_sub_busbar = 'bus', opslabs_sub_relay = 'prot',
            opslabs_sub_meter = 'meter', opslabs_sub_earth = 'earth', opslabs_sub_battery = 'dc', opslabs_sub_control = 'control', opslabs_sub_cable = 'cable' },
        required = { 'tx', 'hv', 'mv', 'bus', 'prot', 'earth', 'dc' },
        labels = { tx = 'Power transformer', hv = '400 kV GIS incomer bay', mv = '11 kV switchgear', bus = 'Busbars', prot = 'Protection relay panel',
            meter = 'Metering & monitoring panel', earth = 'Main earth bar', dc = '110 V DC battery & charger', control = 'Control desk (SCADA)', cable = 'HV cable sealing ends' },
    },
    Pylon = { model = 'opslabs_grid_pylon', reach = 9.5 },
    Recloser = 'opslabs_power_recloser',
    Transformer = 'opslabs_power_transformer',
    Ratings = { transmission = 450, hv = 8 },     -- MW one run can carry before it overloads
    TransformerKW = 150,            -- peak demand of the homes behind one pole transformer
    TransformerOnPole = 1.2,        -- metres: pole kit this close (sideways) to a pole is on it
    Profile = { .45, .40, .38, .37, .38, .45, .60, .75, .72, .66, .62, .60, .62, .62, .64, .68, .78, .92, 1.0, .98, .92, .80, .65, .52 },
    UFLS = { 49.2, 48.9, 48.6 },
    Reclose = { feeder = 1, recloser = 2, line = 1 },   -- auto-reclose attempts before lockout
}

-- Solar PV (San Andreas Solar). An inverter is a power source for the consumer unit it's linked to (nearest one
-- within Config.Mains.AutoWireRadius, or by mains cable): daytime it runs off the panels within PanelReach (unless a
-- DC isolator near it is off), and a home battery within BatteryReach stores the surplus and keeps the house on at
-- night or in a power cut. Daylight follows the game clock.
Config.Solar = {
    Inverter = 'opslabs_solar_inverter',
    Battery = 'opslabs_solar_battery',
    DcIsolator = 'opslabs_solar_dciso',
    Panels = { opslabs_solar_panel_roof = 400, opslabs_solar_array_ground = 2400 },   -- peak watts
    PanelReach = 30.0,
    BatteryReach = 4.0,
    BatteryKwh = 13.5,
    MaxChargeWatts = 5000,
    HouseLoadWatts = 600,          -- what a house draws from the battery when the panels aren't making anything
    Sunrise = 6, Sunset = 20,      -- game hours
}

-- Laptops: OPS OS (opslabs-phone) on a desk, online over Ethernet only. Run CAT6 from a router / switch / AP
-- that has an uplink (or straight from an ONT with an active service) into the laptop's port.
Config.Laptop = {
    Models = { 'opslabs_laptop' },
    UseDistance = 1.3,          -- metres from the laptop for [E] Use laptop
}

-- Internet service (fibre to the premises). Light travels from a street cabinet (the ISP's
-- exchange / OLT) over spliced fibre through splice enclosures, CBTs and CSPs into an ONT.
-- A CAT6 run from the ONT's LAN port to a router gives that router internet. Lights on the
-- ONT pop up when a player walks up to it.
Config.Isp = {
    Headends = { 'opslabs_olt', 'opslabs_cabinet_pcp', 'opslabs_cabinet_fttc', 'opslabs_cabinet_green3', 'opslabs_cabinet_green3_open' },   -- light comes from these
    PassThrough = { 'opslabs_splice_enclosure', 'opslabs_cbt', 'opslabs_cbt_4', 'opslabs_cbt_8', 'opslabs_csp', 'opslabs_joint_tophat',
        'opslabs_fdf', 'opslabs_ucbt', 'opslabs_track_joint', 'opslabs_base_node', 'opslabs_entry_cap', 'opslabs_splice_tray', 'opslabs_ug_riser', 'opslabs_ug_riser_flush' },  -- fibre joints / splitters
    Ont = 'opslabs_ont',
    OltNeedsBackhaul = true,        -- an OLT only lights fibre when a powered core router patches it to an uplink
    ExchangeRadius = 60.0,          -- metres: routers, OLTs and power plant within this count as the same exchange
    RequireIspForGateways = false,  -- true: gateways (OPS Gateway, EdgeLink, HomeRouter...) only give internet when cabled to a live ONT
    PopupDistance = 1.8,            -- metres from an ONT before its status panel pops up
    Providers = {
        { id = 'opsfibre', name = 'OPS Fibre', color = '#0a84ff', plans = {
            { id = 'fibre150', name = 'Fibre 150', down = 150, up = 30 },
            { id = 'fibre500', name = 'Fibre 500', down = 500, up = 75 },
            { id = 'fibre900', name = 'Fibre 900', down = 900, up = 110 },
        } },
        { id = 'velocity', name = 'Velocity Broadband', color = '#ff375f', plans = {
            { id = 'v80', name = 'Superfast 80', down = 80, up = 20 },
            { id = 'v330', name = 'Ultrafast 330', down = 330, up = 50 },
        } },
        { id = 'lumen', name = 'Lumen Fibre', color = '#30d158', plans = {
            { id = 'l1000', name = 'Gigabit 1000', down = 1000, up = 1000 },
            { id = 'l2000', name = 'Hyper 2000', down = 2000, up = 2000 },
        } },
        -- OPS America Fiber (US): symmetric XGS-PON plans
        { id = 'opsamerica', name = 'OPS America Fiber', color = '#2f6bff', plans = {
            { id = 'us300', name = 'Fiber 300', down = 300, up = 300 },
            { id = 'us500', name = 'Fiber 500', down = 500, up = 500 },
            { id = 'us1g', name = 'Fiber 1 Gig', down = 1000, up = 1000 },
            { id = 'us2g', name = 'Fiber 2 Gig', down = 2000, up = 2000 },
            { id = 'us5g', name = 'Fiber 5 Gig', down = 5000, up = 5000 },
        } },
    },
}

-- Render range for network & power kit (poles, cabinets, cable / fibre / power runs, boxes, lights).
-- Things stream in up to Distance metres in front of the camera (a ViewAngle-wide cone) and only
-- Behind metres all round, nearest first. Margin keeps spawned things a little longer so nothing
-- flickers at the edge. Editable live from the Ops-Phone dev app (Render distance).
Config.Render = {
    Distance = 400.0,
    Behind = 80.0,
    ViewAngle = 130.0,
    Margin = 25.0,
}

-- Safety harness (fall arrest): put it on, then clip on to the pole once you're up it. Its own key
-- (default J, rebindable) opens the harness menu — G stays the pole equipment menu.
Config.Harness = {
    Key = 'J',
    ClipSeconds = 2.5,            -- strapping the pole strap round the pole
    WearSeconds = 3.0,
    ShowOthers = 60.0,            -- metres: you see other climbers' straps and lanyards within this
}

-- Network faults: once the network is live, kit develops faults at random over days and weeks.
-- perWeek = how many of that fault to expect across the WHOLE network per real-time week.
-- minLiveHours = a pole / piece of kit must have been live this long before it can get that fault.
-- These are defaults: the Ops-Phone dev app (Network faults) and the Ops-Networks admin panel
-- override them in game (saved in opslabs_towers_meta). at_height = repaired up the pole.
-- Engineers find faults on /admin/internet (website) and in the Ops-Networks phone app, go to the
-- spot and repair them: press the repair key (default U) next to the fault, or G on the pole.
Config.Faults = {
    Enabled = true,
    TickMinutes = 5,              -- how often the fault engine rolls the dice
    MaxOpen = 6,                  -- never more than this many faults open at once
    CooldownHours = 72,           -- a repaired asset is left alone this long
    RepairRange = 3.0,            -- metres from the fault you need to be (at height: on the pole within reach)
    RepairKey = 'U',              -- default key (players can rebind it in Settings → Key Bindings → FiveM)
    RequireHarness = true,        -- at-height repairs need your harness clipped on
    Types = {
        pole_lean = { label = 'Pole leaning', category = 'pole', severity = 'medium', perWeek = 0.5, minLiveHours = 120, at_height = false,
            targets = 'poles',
            causes = { 'Ground washed out round the foot of the pole after heavy rain', 'Vehicle clipped the pole', 'Uneven cable tension pulling the pole over' },
            symptoms = { 'Pole visibly leaning off vertical', 'Spans sagging lower than normal over the road' },
            diagnosis = 'Plumb check shows the pole about 8° off vertical towards the road. The spans are pulling it over.',
            fix = { 'Coordinate road safety: cones and a works sign', 'Install a guild wire from this pole to the next pole to take the load (Ops-Network → Guild wires)',
                'Straighten the pole and re-tamp the ground round the foot', 'Re-check the plumb and the span heights' },
            tools = { 'Guild wire', 'Tamping bar', 'Spirit level', 'Cones & signs' }, repairSeconds = 25, needsGuy = true },
        pole_rot = { label = 'Pole rot at ground line', category = 'pole', severity = 'high', perWeek = 0.3, minLiveHours = 240, at_height = false,
            targets = 'poles',
            causes = { 'Fungal decay at ground line', 'Woodpecker damage below the steps', 'Creosote treatment failed at the base' },
            symptoms = { 'Pole flagged unsafe at the last test', 'Soft, hollow-sounding wood at the base' },
            diagnosis = 'Pole tester hammer gives a dull thud at the ground line. Decay goes about 40 mm into the wood: the pole is unsafe to climb.',
            fix = { 'Do NOT climb the pole', 'Test it with the pole tester hammer to confirm', 'Fit a steel reinforcement stub at the base (repair)',
                'Re-test, then label the pole as tested' },
            tools = { 'Pole tester hammer', 'Steel stub & bands', 'Cones & signs' }, repairSeconds = 30 },
        fibre_break = { label = 'Fibre break on an aerial span', category = 'fibre', severity = 'critical', perWeek = 0.8, minLiveHours = 48, at_height = true,
            targets = 'aerial_fibre',
            causes = { 'Tree branch fell across the span', 'High vehicle snagged the span', 'Squirrels chewed through the sheath' },
            symptoms = { 'LOS (red light) on every ONT fed through this span', 'Customers report no internet' },
            diagnosis = 'OTDR from the cabinet shows a clean break on the span next to this pole: total loss of light past it.',
            fix = { 'Set up road safety under the span', 'Climb the pole and clip your harness on', 'Cut back the damaged fibre and splice in a repair joint',
                'Test with the red light / OTDR, then confirm the customers are back online' },
            tools = { 'OTDR', 'Fusion splicer', 'Harness', 'Ladder or climbing kit' }, repairSeconds = 35 },
        dropwire_down = { label = 'Dropwire down', category = 'customer', severity = 'high', perWeek = 1.0, minLiveHours = 48, at_height = false,
            targets = 'drop_fibre',
            causes = { 'Dropwire clamp failed in high wind', 'Pulled down by a passing lorry', 'Ladder caught it during building work' },
            symptoms = { 'One customer has LOS (red light) on their ONT', 'Dropwire hanging low or lying on the ground' },
            diagnosis = 'The drop to the customer is broken next to their house: no light at the CSP.',
            fix = { 'Make the hanging cable safe', 'Re-run or splice the dropwire and fit a new clamp', 'Check the ONT light comes back green' },
            tools = { 'Dropwire & clamps', 'Splicer', 'Ladder' }, repairSeconds = 25 },
        cbt_water = { label = 'Water in a CBT', category = 'equipment', severity = 'high', perWeek = 0.6, minLiveHours = 72, at_height = true,
            targets = { 'opslabs_cbt', 'opslabs_cbt_4', 'opslabs_cbt_8', 'opslabs_ucbt' },
            causes = { 'Port cap left off, so rain got in', 'Seal perished in the sun', 'Cracked housing after a cold snap' },
            symptoms = { 'Every customer fed from this CBT has LOS', 'Fibre light reaches the CBT but nothing comes out' },
            diagnosis = 'Light reaches the CBT input but the splitter output is dead. There is water in the housing and the splitter is corroded.',
            fix = { 'Climb the pole and clip your harness on', 'Open the CBT, dry it out and replace the splitter', 'Replace the seals and refit the port caps',
                'Check the customers come back online' },
            tools = { 'Replacement splitter', 'Seal kit', 'Harness', 'Climbing kit' }, repairSeconds = 30 },
        splice_loss = { label = 'High loss in a splice joint', category = 'fibre', severity = 'medium', perWeek = 0.7, minLiveHours = 72, at_height = true,
            targets = { 'opslabs_splice_enclosure', 'opslabs_joint_tophat', 'opslabs_track_joint', 'opslabs_base_node', 'opslabs_fdf' },
            causes = { 'Fibre bent too tightly in the splice tray', 'Splice protector slipped', 'Moisture fogging a connector' },
            symptoms = { 'Customers past this joint have slow or dropping internet', 'ONT receive light about 8 dB lower than normal' },
            diagnosis = 'OTDR shows an 8 dB step at this joint. A splice in the tray is bent too tightly.',
            fix = { 'Open the joint (if it\'s on a pole: climb and clip your harness on)', 'Re-splice the bad fibre and re-route it in the tray',
                'Test the loss is back under 0.1 dB' },
            tools = { 'OTDR', 'Fusion splicer', 'Splice protectors' }, repairSeconds = 30, lossDb = 8.0 },
        ont_failure = { label = 'Customer ONT failed', category = 'customer', severity = 'medium', perWeek = 1.2, minLiveHours = 24, at_height = false,
            targets = { 'opslabs_ont' },
            causes = { 'Power surge killed the ONT', 'ONT overheated behind furniture', 'Laser in the ONT reached end of life' },
            symptoms = { 'ONT lights off or stuck on POWER only', 'Light reaches the house but the ONT does not register' },
            diagnosis = 'The light meter at the ONT reads fine but the ONT never registers: the hardware has failed.',
            fix = { 'Visit the customer and check the ONT power supply', 'Swap the ONT for a new one and re-provision it', 'Confirm the PON and internet lights go green' },
            tools = { 'Replacement ONT', 'Optical power meter' }, repairSeconds = 20 },
        cabinet_power = { label = 'Street cabinet power failure', category = 'equipment', severity = 'critical', perWeek = 0.3, minLiveHours = 96, at_height = false,
            targets = { 'opslabs_cabinet_pcp', 'opslabs_cabinet_fttc', 'opslabs_cabinet_green3', 'opslabs_cabinet_green3_open' },
            causes = { 'Mains supply fuse blown', 'Battery backup ran flat after a power cut', 'Rodents chewed through the power feed' },
            symptoms = { 'Every customer fed from this cabinet is offline', 'Cabinet alarms: mains fail and battery low' },
            diagnosis = 'The cabinet has no mains power and the backup battery is exhausted.',
            fix = { 'Make the area safe and open the cabinet', 'Replace the mains fuse / repair the feed', 'Swap the backup batteries', 'Check the customers come back online' },
            tools = { 'Cabinet key', 'Replacement fuses', 'Battery pack', 'Multimeter' }, repairSeconds = 30 },
        olt_card = { label = 'OLT line card failed', category = 'exchange', severity = 'critical', perWeek = 0.2, minLiveHours = 168, at_height = false,
            targets = { 'opslabs_olt' },
            causes = { 'PON line card failed', 'Optic module (SFP) burnt out', 'Line card firmware crashed' },
            symptoms = { 'All customers fed by this OLT are offline', 'Exchange alarm: PON port down' },
            diagnosis = 'The OLT reports the PON card offline. The optic has no output.',
            fix = { 'Go to the exchange', 'Hot-swap the failed line card / optic in the OLT', 'Check the PON ports come back up and the customers re-register' },
            tools = { 'Spare OLT line card', 'Optical power meter', 'Antistatic strap' }, repairSeconds = 25 },
        tower_power = { label = 'Mobile mast power fault', category = 'mobile', severity = 'high', perWeek = 0.3, minLiveHours = 96, at_height = false,
            targets = 'cell_towers',
            causes = { 'Mains supply to the mast cabinet tripped', 'Rectifier failed in the mast cabinet', 'Cable theft from the mast compound' },
            symptoms = { 'Mast off air: no mobile signal from this site', 'Phones nearby drop to another mast or show no signal' },
            diagnosis = 'The mast cabinet has no DC power: the rectifier has failed.',
            fix = { 'Go to the mast compound', 'Replace the rectifier module / reset the supply', 'Check the mast is back on air' },
            tools = { 'Rectifier module', 'Multimeter', 'Site keys' }, repairSeconds = 25 },
    },
}

-- Copper phone lines: a socket has dial tone when copper runs punched down at both ends connect it, through
-- the kit below, to an MDF in an exchange with power (rectifier / batteries / generator within Isp.ExchangeRadius).
-- Engineers test with the tool kit (OPS Openline → Copper phone line tools): butt set, tone & probe, line tester…
Config.PhoneLine = {
    Exchange = { 'opslabs_mdf' },                                      -- dial tone comes from here
    NeedsPower = true,                                                 -- the exchange needs its power plant
    PassThrough = { 'opslabs_cabinet_pcp', 'opslabs_cabinet_green3', 'opslabs_cabinet_green3_open', 'opslabs_copper_dp', 'opslabs_pole_splice_box', 'opslabs_copper_joint_aerial',
        'opslabs_copper_jb', 'opslabs_footway_box', 'opslabs_hof', 'opslabs_ug_riser', 'opslabs_ug_riser_flush' },    -- joints, DPs, cabinets
    Sockets = { 'opslabs_nte5c', 'opslabs_copper_linejack', 'opslabs_vdsl_faceplate' },   -- where a phone plugs in (they feed extensions too)
    OhmsPerKm = 168,                                                   -- loop resistance of 0.5 mm copper
    NumberPrefix = '01632 96',                                         -- line numbers: prefix + 4 digits from the socket
}

-- Street works safety kit (Network cabling → Road safety equipment). Signs have editable text
-- (drawn live on the sign face); traffic lights work in pairs (A / B) on a shared cycle.
Config.Roadworks = {
    Items = {
        { label = 'Traffic cone', model = 'opslabs_rw_cone', sizes = {
            { label = '450 mm · small', model = 'opslabs_rw_cone_450' },
            { label = '750 mm · standard', model = 'opslabs_rw_cone' },
            { label = '1 m · large, two reflective bands', model = 'opslabs_rw_cone_1000' },
        } },
        { label = 'Barrier · Fibre works in progress', model = 'opslabs_rw_barrier' },
        { label = 'Barrier · Stay back', model = 'opslabs_rw_barrier_stay' },
        { label = 'Red pedestrian barrier · 1 m (interlocking)', model = 'opslabs_rw_barrier_red' },
        { label = 'Works sign · editable dates & times', model = 'opslabs_rw_sign', sign = true },
        { label = 'Portable traffic light', model = 'opslabs_rw_tlight', light = true },
        { label = 'Cordon tape · 3 m', model = 'opslabs_rw_tape' },
        { label = 'Work light · tripod, twin LED', model = 'opslabs_rw_worklight' },
        { label = 'Lighting tower · towable, 7.5 m mast', model = 'opslabs_rw_lighttower' },
    },
    SignDefault = { 'FIBRE WORKS', 'IN PROGRESS', 'Mon 06/10 – Fri 10/10', '08:00 – 18:00', 'OPS Fibre · Sorry for any delay' },
    Lights = { green = 20, amber = 3, allRed = 3 },   -- seconds; side B runs half a cycle behind side A
}

-- Lights (street lights and road works lighting): at night each one gets its `<model>_on` glow model
-- and a real spotlight per lamp. pts = lamp centres in the light's own frame (front -Y) + pitch
-- (90 = straight down). Positions come from opslabs-props/source/build_lighting.py — keep in step.
Config.Lighting = {
    On = 19, Off = 7,             -- game hours: lights on from On:00 until Off:00
    Distance = 150.0,             -- metres: lights further away than this are not drawn
    MaxLights = 24,               -- nearest lamps drawn per frame (the game caps dynamic lights)
    Kinds = {
        street = { rgb = { 255, 228, 190 }, range = 22.0, brightness = 9.0, cone = 62.0, falloff = 18.0 },   -- ≈ 4000 K LED
        work   = { rgb = { 235, 242, 255 }, range = 18.0, brightness = 10.0, cone = 50.0, falloff = 12.0 },  -- ≈ 5700 K LED flood
        tower  = { rgb = { 235, 242, 255 }, range = 35.0, brightness = 14.0, cone = 55.0, falloff = 20.0 },
    },
    Models = {
        opslabs_streetlight_6m       = { kind = 'street', pts = { { 0.0, -1.31, 6.27, 90 } } },
        opslabs_streetlight_10m      = { kind = 'street', pts = { { 0.0, -1.81, 10.27, 90 } } },
        opslabs_streetlight_10m_twin = { kind = 'street', pts = { { 0.0, -1.81, 10.27, 90 }, { 0.0, 1.81, 10.27, 90 } } },
        opslabs_streetlight_pole     = { kind = 'street', pts = { { 0.0, -1.41, 0.44, 90 } } },
        opslabs_rw_worklight         = { kind = 'work', pts = { { -0.24, -0.095, 2.224, 25 }, { 0.24, -0.095, 2.224, 25 } } },
        opslabs_rw_lighttower        = { kind = 'tower', pts = { { -0.06, -0.131, 7.405, 20 }, { 0.38, -0.131, 7.405, 20 }, { 0.82, -0.131, 7.405, 20 }, { 1.26, -0.131, 7.405, 20 } } },
    },
}

-- Walk-in buildings: lights and doors in each building's own frame (origin = centre of the floor, front faces -Y).
-- Doors: hinge = { x, y } at the hinge edge, z = floor height, h = closed heading (0 → leaf runs +X, 90 → +Y),
-- w = width, swing = +1 / -1 (which way it opens), kind = door model. Every door locks with a PIN (keypad).
-- PINs are kept on the server only (opslabs_towers_doors), never sent to players.
Config.Buildings = {
    opslabs_house_customer = {
        lights = { z = 2.5, rgb = { 255, 236, 205 }, range = 5.0, power = 1.4,
            pts = { { -3.8, -2.2 }, { 3.3, -2.2 }, { -3.8, 2.2 }, { 3.3, 0.9 }, { 3.3, 3.2 }, { -0.5, -2.0 }, { -0.5, 2.0 } } },
        doors = {
            { label = 'Front door', hinge = { -0.95, -4.375 }, z = 0.12, h = 0, w = 0.95, swing = 1, kind = 'opslabs_door_ext' },
            { label = 'Back door', hinge = { -0.95, 4.375 }, z = 0.12, h = 0, w = 0.95, swing = -1, kind = 'opslabs_door_ext' },
            { label = 'Living room', hinge = { -1.6, -2.6 }, z = 0.12, h = 90, w = 0.9, swing = 1, kind = 'opslabs_door_int' },
            { label = 'Bedroom 1', hinge = { -1.6, 1.5 }, z = 0.12, h = 90, w = 0.9, swing = 1, kind = 'opslabs_door_int' },
            { label = 'Kitchen', hinge = { 0.6, -2.6 }, z = 0.12, h = 90, w = 0.9, swing = -1, kind = 'opslabs_door_int' },
            { label = 'Bathroom', hinge = { 0.6, 0.5 }, z = 0.12, h = 90, w = 0.9, swing = -1, kind = 'opslabs_door_int' },
            { label = 'Bedroom 2', hinge = { 0.6, 2.6 }, z = 0.12, h = 90, w = 0.9, swing = -1, kind = 'opslabs_door_int' },
        },
    },
    opslabs_depot = {
        lights = { z = 5.4, rgb = { 245, 250, 255 }, range = 9.0, power = 1.8,
            pts = { { 2.0, -3.5 }, { 6.5, -3.5 }, { 9.0, -3.5 }, { 2.0, 3.0 }, { 6.5, 3.0 }, { 9.0, 3.0 } },
            low = { z = 2.9, pts = { { -8.0, -4.0 }, { -5.0, -4.0 }, { -7.0, -0.25 }, { -9.4, 3.6 }, { -6.75, 3.6 }, { -4.3, 3.6 } } } },
        doors = {
            { label = 'Front door', hinge = { -7.6, -6.875 }, z = 0.1, h = 0, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Side door', hinge = { 10.875, -1.0 }, z = 0.08, h = 90, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Roller shutter', hinge = { 1.0, -6.69 }, z = 4.6, h = 0, w = 5.5, kind = 'opslabs_door_shutter', shutter = true },
            { label = 'Warehouse door', hinge = { -3.0, -0.7 }, z = 0.1, h = 90, w = 1.0, swing = -1, kind = 'opslabs_door_steel' },
            { label = 'Office', hinge = { -6.0, -1.0 }, z = 0.1, h = 0, w = 0.9, swing = -1, kind = 'opslabs_door_int' },
            { label = 'Meeting room', hinge = { -9.8, 0.5 }, z = 0.1, h = 0, w = 0.9, swing = 1, kind = 'opslabs_door_int' },
            { label = 'Kit room', hinge = { -7.2, 0.5 }, z = 0.1, h = 0, w = 0.9, swing = 1, kind = 'opslabs_door_int' },
            { label = 'Lockers & WC', hinge = { -4.7, 0.5 }, z = 0.1, h = 0, w = 0.9, swing = 1, kind = 'opslabs_door_int' },
        },
    },
    -- gates & rising bollards: the placed fixture is the frame; leaves move. auto = metres at which it opens by itself
    -- (unless locked — then the keypad PIN lets you through once). sign = live brand board on that leaf.
    opslabs_gate_slide_frame = { gate = true,
        doors = { { label = 'Sliding gate', auto = 7.0, vehicles = true, peds = true,
            leaves = { { hinge = { -2.6, 0.0 }, z = 0.02, h = 0, w = 5.2, kind = 'opslabs_gate_slide', slide = 5.3, sign = { 2.6, -0.09, 1.0 } } } } } },
    opslabs_gate_swing_frame = { gate = true,
        doors = { { label = 'Double gates', auto = 7.0, vehicles = true, peds = true,
            leaves = { { hinge = { -2.05, 0.0 }, z = 0.0, h = 0, w = 2.0, swing = 1, kind = 'opslabs_gate_leaf', sign = { 1.0, -0.09, 0.95 } },
                       { hinge = { 2.05, 0.0 }, z = 0.0, h = 180, w = 2.0, swing = -1, kind = 'opslabs_gate_leaf' } } } } },
    opslabs_gate_ped_frame = { gate = true,
        doors = { { label = 'Pedestrian gate', auto = 2.2, peds = true,
            leaves = { { hinge = { -0.55, 0.0 }, z = 0.0, h = 0, w = 1.1, swing = 1, kind = 'opslabs_gate_ped' } } } } },
    opslabs_barrier_housing = { gate = true,
        doors = { { label = 'Barrier', auto = 6.0, vehicles = true,
            leaves = { { hinge = { -2.1, 0.0 }, z = 0.95, h = 0, w = 4.4, kind = 'opslabs_barrier_arm', lift = 85 } } } } },
    opslabs_bollard_rising = { gate = true,
        doors = { { label = 'Rising bollard', auto = 6.0, vehicles = true,
            leaves = { { hinge = { 0.0, 0.0 }, z = 0.0, h = 0, w = 0.2, kind = 'opslabs_bollard_post', sink = 0.92 } } } } },
    -- underground: the hatch is a lifting leaf (E open / close, H keypad) · lights in the chamber and every tunnel section
    opslabs_ug_chamber = {
        lights = { z = -0.55, rgb = { 255, 240, 215 }, range = 5.5, power = 1.6, pts = { { 0.6, 0.6 } } },
        doors = { { label = 'Access hatch', leaves = { { hinge = { -1.4, -1.15 }, z = 0.0, h = 0, w = 0.8, kind = 'opslabs_ug_hatch_lid', lift = 100 } } } },
    },
    opslabs_ug_entrance = { lights = { z = -0.55, rgb = { 255, 240, 215 }, range = 5.5, power = 1.6, pts = { { 0.6, 0.6 } } } },
    opslabs_ug_tunnel_tee = { lights = { z = -0.95, rgb = { 235, 242, 255 }, range = 5.0, power = 1.5, pts = { { 0.0, -1.0 }, { 0.0, 1.0 } } } },
    opslabs_ug_tunnel = { lights = { z = -0.95, rgb = { 235, 242, 255 }, range = 5.0, power = 1.5, pts = { { 0.0, -1.0 }, { 0.0, 1.0 } } } },
    opslabs_grid_subbuilding = {
        lights = { z = 5.8, rgb = { 245, 250, 255 }, range = 9.0, power = 1.8,
            pts = { { -6.0, -2.5 }, { -2.0, -2.5 }, { 2.0, -2.5 }, { 6.0, -2.5 }, { -6.0, 2.5 }, { -2.0, 2.5 }, { 2.0, 2.5 }, { 6.0, 2.5 } } },
        doors = {
            { label = 'Personnel door', hinge = { -6.5, -4.85 }, z = 0.1, h = 0, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Equipment doors (left)', hinge = { 1.0, -4.85 }, z = 0.1, h = 0, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Equipment doors (right)', hinge = { 3.0, -4.85 }, z = 0.1, h = 180, w = 1.0, swing = -1, kind = 'opslabs_door_steel' },
        },
    },
    opslabs_exchange_building = {
        lights = { z = 4.6, rgb = { 255, 250, 235 }, range = 7.0, power = 1.6,
            pts = { { -5.5, -2.0 }, { -2.0, -1.0 }, { 2.0, -1.0 }, { 6.0, -2.0 }, { -5.5, 2.0 }, { -2.0, 2.0 }, { 2.0, 2.0 }, { 6.0, 2.0 } },
            low = { z = 2.7, pts = { { 0.0, -3.6 } } } },
        doors = {
            { label = 'Front door', hinge = { -0.5, -4.85 }, z = 0.15, h = 0, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Equipment hall', hinge = { -0.5, -2.5 }, z = 0.15, h = 0, w = 1.0, swing = 1, kind = 'opslabs_door_steel' },
            { label = 'Power room', hinge = { 4.0, -1.0 }, z = 0.15, h = 90, w = 1.0, swing = -1, kind = 'opslabs_door_steel' },
        },
    },
}

-- OPS Network van: a base-game van dressed with OPS branding, roof light bar, rear beacons and a ladder rack.
-- /opsvan (network engineers & admins) brings one; K toggles the beacons; [E] at the back opens the van stores.
Config.Van = {
    Command = 'opsvan',
    Model = 'speedo',                 -- any base van works; the branding finds the body by itself
    Colour = { 246, 247, 249 },       -- body (RGB)
    Trim = { 10, 90, 200 },           -- secondary (RGB)
    Plate = 'OPSNET',
    BeaconKey = 'K',
    -- roof spotlight (opslabs_van_spot_*): a rail across the roof, a telescopic post that slides along it, a pan / tilt head.
    -- L inside the van (any seat) opens the controls: ←→ pan · ↑↓ tilt · Shift + ←→ slide · PgUp / PgDn raise · hold Alt to aim
    -- with the camera · Enter on / off · X park. Fit or take it off at the van stores ([E] at the back).
    Spotlight = {
        Fitted = true,                -- new vans come with it fitted
        Key = 'L',
        Along = 0.74,                 -- rail position along the van (0 = back, 1 = front): just in front of the light bar
        Lift = 0.0,                   -- raise the rail if it sinks into the roof of another van model
        Slide = 0.62, Raise = 0.35,   -- metres either side / mast travel
        TiltDown = -50.0, TiltUp = 40.0,
        Colour = { 255, 244, 225 }, Range = 80.0, Brightness = 14.0, Cone = 13.0, Falloff = 25.0,
    },
}

-- Underground chambers & tunnels (client/underground.lua) — numbers from opslabs-props/source/build_underground.py
Config.Underground = {
    Hatch = { -1.0, -1.15 },   -- hatch centre in the chamber's frame
    Floor = -3.0,              -- walkable floor below the road surface
    EntranceDoor = { 0.0, -1.0 },      -- street entrance: just outside the kiosk door
    EntranceLanding = { -0.9, 1.0 },   -- street entrance: foot of the stairs
}

-- Anti-climb zones along every fence panel, fence post and gate: you can't jump, climb or vault over them.
-- Segments are in each model's own frame (x from → to along y = 0); distance = how close counts as "at the fence".
Config.AntiClimb = {
    Enabled = true,
    Distance = 1.4,
    Segments = {
        opslabs_fence_pal_grey = { -1.3, 1.25 }, opslabs_fence_pal_green = { -1.3, 1.25 }, opslabs_fence_pal_galv = { -1.3, 1.25 },
        opslabs_fence_mesh_grey = { -1.3, 1.25 }, opslabs_fence_mesh_green = { -1.3, 1.25 }, opslabs_fence_brand = { -1.3, 1.25 },
        opslabs_fence_post = { -0.1, 0.1 },
        opslabs_gate_slide_frame = { -8.1, 2.8 }, opslabs_gate_swing_frame = { -2.25, 2.25 }, opslabs_gate_ped_frame = { -0.7, 0.7 },
    },
}

-- OPS Network uniform: navy work polo, navy work trousers, black work boots (base-game items, checked against the
-- game's clothing names) + printed OPS Network branding (back print, chest logo) and a branded white hard hat.
-- The branding fits itself to the body (it measures the bones), so it sits right on any character.
-- Admins can restyle it live (Tools → Uniform → Design the uniform / Adjust the branding) — saved to uniform.json.
Config.Uniform = {
    Name = 'OPS Network engineer',
    Male = { tshirt_1 = 15, tshirt_2 = 0, torso_1 = 39, torso_2 = 1, decals_1 = 0, decals_2 = 0, arms = 0, arms_2 = 0,      -- Navy Two-Tone Polo Shirt
             pants_1 = 7, pants_2 = 14, shoes_1 = 12, shoes_2 = 6, helmet_1 = -1, helmet_2 = 0, bproof_1 = 0, bproof_2 = 0, -- Navy Work Pants · Black Work Boots
             chain_1 = 0, chain_2 = 0, bags_1 = 0, bags_2 = 0, mask_1 = 0, mask_2 = 0, glasses_1 = 0, glasses_2 = 0 },
    Female = { tshirt_1 = 14, tshirt_2 = 0, torso_1 = 14, torso_2 = 7, decals_1 = 0, decals_2 = 0, arms = 0, arms_2 = 0,      -- Navy Polo Shirt
               pants_1 = 11, pants_2 = 4, shoes_1 = 52, shoes_2 = 0, helmet_1 = -1, helmet_2 = 0, bproof_1 = 0, bproof_2 = 0, -- Navy Cargos · Black Laceup Boots
               chain_1 = 0, chain_2 = 0, bags_1 = 0, bags_2 = 0, mask_1 = 0, mask_2 = 0, glasses_1 = 0, glasses_2 = 0 },
    -- where each printed piece sits, relative to its bone and the way the body faces (metres: up, forward, right)
    Branding = {
        back  = { model = 'opslabs_uniform_back',  bone = 24818, face = 'back',  at = { up = -0.05, forward = -0.135, right = 0.0 } },
        badge = { model = 'opslabs_uniform_badge', bone = 24818, face = 'front', at = { up = 0.06, forward = 0.122, right = -0.085 } },
        hat   = { model = 'opslabs_hardhat',       bone = 31086, face = 'hat',   at = { up = 0.075, forward = 0.012, right = 0.0 } },
    },
}

-- the empty substation building has the same doors and lights as the fitted one
Config.Buildings.opslabs_grid_subshell = Config.Buildings.opslabs_grid_subbuilding
