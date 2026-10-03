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
        { label = 'UniFi access point (ceiling)', model = 'opslabs_unifi_ap_ceiling' },  -- opslabs-props
        { label = 'UniFi access point (desk / shelf)', model = 'opslabs_unifi_ap' },     -- opslabs-props
        { label = 'Cloud Gateway Ultra (desk)', model = 'opslabs_ucg_ultra' },          -- opslabs-props
        { label = 'Dream Machine Pro (rack / shelf)', model = 'opslabs_udm_pro' },      -- opslabs-props
        { label = 'Omada access point (ceiling)', model = 'opslabs_omada_eap_ceiling' },  -- opslabs-props
        { label = 'Omada access point (desk / shelf)', model = 'opslabs_omada_eap' },
        { label = 'Omada ER605 router (desk)', model = 'opslabs_omada_er605' },
        { label = 'Omada ER7206 router (rack / shelf)', model = 'opslabs_omada_er7206' },
        { label = 'Omada 8-port PoE switch', model = 'opslabs_omada_switch' },
        { label = 'Omada OC200 controller', model = 'opslabs_omada_oc200' },
        { label = 'TP-Link Deco mesh unit', model = 'opslabs_tplink_deco' },
        { label = 'TP-Link Archer router', model = 'opslabs_tplink_archer' },
        { label = 'TP-Link range extender (wall socket)', model = 'opslabs_tplink_extender' },
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
Config.Cabling = {
    Command = 'cable',
    Jobs = {},                  -- jobs that may lay cable besides tower admins, e.g. { 'electrician' }
    BoxLength = 305,            -- metres in a new box
    PullDistance = 3.0,         -- start a run within this distance of a box
    MaxRunLength = 90,          -- longest single run in metres (real CAT6 limit is 100 m)
    Standard = 'T568B',         -- wire order for termination: 'T568B' or 'T568A'
    RequireUplink = false,      -- true: Wi-Fi access points only work when cabled (both ends terminated) to a gateway
    Gateways = { 'opslabs_udm_pro', 'opslabs_ucg_ultra', 'opslabs_omada_er605', 'opslabs_omada_er7206', 'opslabs_tplink_archer', 'opslabs_tplink_deco' },   -- Wi-Fi props that count as the internet uplink
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
        opslabs_power_pole_10m = 10.0, opslabs_power_pole_12m = 12.0, opslabs_pole_roof = 6.0 },
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
    },
    -- buildings and the exchange's own power & cooling plant (not network kit) live under /towers → Buildings & sites
    Sites = { id = 'sites', label = 'Buildings & sites', sub = 'Walk-in buildings · exchange power & cooling', icon = 'city', color = '#5e5ce6' },
    -- power cable (Run power cable): bare HV conductor, LV bundled cable, insulated service drop to a house
    PowerColors = { 'hv', 'lv', 'service' },
    PowerLabels = { hv = 'HV overhead conductor (11 kV)', lv = 'LV bundled cable (230 / 400 V)', service = 'Service drop to a house' },
    MaxPowerLength = 600,
    -- copper phone cable (Run phone cable): drop wire pole → house, internal cable round the house, multi-pair between cabinets
    CopperColors = { 'drop', 'internal', 'multipair' },
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
        { net = 'sites', cat = 'Exchange power & cooling', label = 'DC rectifier rack (48 V)', model = 'opslabs_rectifier' },
        { net = 'sites', cat = 'Exchange power & cooling', label = 'Industrial battery bank', model = 'opslabs_battery_bank' },
        { net = 'sites', cat = 'Exchange power & cooling', label = 'Standby diesel generator', model = 'opslabs_generator' },
        { net = 'sites', cat = 'Exchange power & cooling', label = 'HVAC cooling unit (indoor)', model = 'opslabs_crac' },
        { net = 'sites', cat = 'Exchange power & cooling', label = 'HVAC condenser (outdoor)', model = 'opslabs_condenser' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Main distribution frame (MDF)', model = 'opslabs_mdf' },
        { net = 'openline', cat = 'Exchange network kit', label = 'DSLAM', model = 'opslabs_dslam' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Handover frame (HOF)', model = 'opslabs_hof' },
        { net = 'openline', cat = 'Exchange network kit', label = 'Optical distribution / handover frame (ODF / OHF)', model = 'opslabs_fdf' },
        { net = 'sites', cat = 'Exchange power & cooling', label = 'DC power plant & batteries', model = 'opslabs_dc_power' },
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
        { net = 'openline', cat = 'Customer premises · outside', label = 'Customer splice point (CSP)', model = 'opslabs_csp' },
        { net = 'openline', cat = 'Customer premises · outside', label = 'Anchor eyebolt + swivel link', model = 'opslabs_wall_anchor' },
        { net = 'openline', cat = 'Customer premises · outside', label = 'Brickwork entry bushing', model = 'opslabs_entry_bushing' },
        -- customer premises, inside
        { net = 'openline', cat = 'Customer premises · inside', label = 'ONT (optical network termination)', model = 'opslabs_ont' },
        { net = 'openline', cat = 'Customer premises · inside', label = 'Internal splicing tray', model = 'opslabs_splice_tray' },
        { net = 'openline', cat = 'Customer premises · inside', label = 'Internal fibre entry box', model = 'opslabs_entry_cap' },
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
    },
    -- metal pole information plate (Branding & info)
    BrandColors = { { '#0a84ff', 'Blue' }, { '#14a0aa', 'Teal' }, { '#30d158', 'Green' }, { '#ff9f0a', 'Orange' }, { '#ff375f', 'Pink' }, { '#bf5af2', 'Purple' }, { '#1c1c1e', 'Black' }, { '#e5383b', 'Red' } },
    RotationOrder = 2,          -- euler order used to lay pieces on walls/ceilings (leave at 2)
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
    RequireIspForGateways = false,  -- true: gateways (UDM, ER605, Archer...) only give internet when cabled to a live ONT
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
