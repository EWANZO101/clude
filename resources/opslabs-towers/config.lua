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
    },
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
    TrunkColors = { 'white', 'black', 'blue' },
    FibreColors = { 'black', 'yellow' },       -- black outdoor dropwire, yellow indoor patch
    MaxFibreLength = 1000,                     -- longest single fibre run
    FibreBoxLength = { black = 1000, yellow = 500 },   -- metres in a new fibre box
    -- telecom equipment that can be placed with /cable → Telecom equipment
    -- telegraph poles: anyone can climb (E at the base); ClimbJobs = { 'telecom' } to restrict
    ClimbJobs = false,
    ClimbSpeed = 0.9,          -- metres per second
    LadderCommand = 'ladder',  -- /ladder to stand an extension ladder against a wall or pole
    Ladders = {                -- top = top of the fly when closed (m along the ladder), maxExt = how far the fly slides out
        { id = 'l7', label = 'Extension ladder · 3.6 m → 6.9 m', base = 'opslabs_ladder_base', fly = 'opslabs_ladder_fly', top = 3.9, maxExt = 3.0 },
        { id = 'l13', label = 'Extension ladder · 6.8 m → 13 m', base = 'opslabs_ladder13_base', fly = 'opslabs_ladder13_fly', top = 7.1, maxExt = 5.9 },
    },
    LadderMaxPerPlayer = 2,
    ClimbAnimFlip = true,      -- climbers face the pole; set false if they ever end up with their back to it
    Equipment = {
        { label = 'Telegraph pole 7 m',  model = 'opslabs_pole_07m' },
        { label = 'Telegraph pole 10 m', model = 'opslabs_pole_10m' },
        { label = 'Telegraph pole 13 m', model = 'opslabs_pole_13m' },
        { label = 'CBT (fibre block terminal, pole-mount)', model = 'opslabs_cbt', pole = true },
        { label = 'Copper DP (pole-mount)', model = 'opslabs_copper_dp', pole = true },
        { label = 'Splice enclosure', model = 'opslabs_splice_enclosure', pole = true },
        { label = 'Street cabinet (PCP)', model = 'opslabs_cabinet_pcp' },
        { label = 'Street cabinet (FTTC extension)', model = 'opslabs_cabinet_fttc' },
        { label = 'Carriageway / chamber cover', model = 'opslabs_carriageway_cover' },
        { label = 'Customer splice point (outside wall)', model = 'opslabs_csp' },
        { label = 'ONT (inside wall)', model = 'opslabs_ont' },
    },
    RotationOrder = 2,          -- euler order used to lay pieces on walls/ceilings (leave at 2)
}

-- Internet service (fibre to the premises). Light travels from a street cabinet (the ISP's
-- exchange / OLT) over spliced fibre through splice enclosures, CBTs and CSPs into an ONT.
-- A CAT6 run from the ONT's LAN port to a router gives that router internet. Lights on the
-- ONT pop up when a player walks up to it.
Config.Isp = {
    Headends = { 'opslabs_cabinet_pcp', 'opslabs_cabinet_fttc' },              -- light comes from these
    PassThrough = { 'opslabs_splice_enclosure', 'opslabs_cbt', 'opslabs_csp' },  -- fibre joints / splitters
    Ont = 'opslabs_ont',
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
