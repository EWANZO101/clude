-- OPS City Kit: outdoor dressing props for custom maps / MLOs — concrete, fences, gates, lighting and more.
-- Every model below is a REAL vanilla GTA V object (checked against the live game's object list, not guessed from
-- memory) — see README.md for the sources and the categories with no vanilla equivalent (road markings, drain
-- covers, fake grass mats, pavement tiles, garden walls). Add custom `opslabs_*` art to any category's `items`
-- list later exactly the same way — nothing else needs to change.

Config = {}

Config.AdminAce = 'opslabs.citykit'   -- grant with: add_ace group.admin opslabs.citykit allow (or add a license to AdminLicenses below)
Config.AdminLicenses = {}             -- rockstar/license identifiers to let in even without the ACE permission
Config.AdminGroups = { 'admin', 'superadmin' }  -- framework admin groups (checked through rps_lib / ESX)

Config.UseDistance = 3.0        -- metres for [E] edit / delete on an already-placed prop
Config.StreamDistance = 150.0   -- metres: props stream in/out around the player (dressing kit, not a huge network)
Config.PlaceReach = 20.0        -- metres the placement ray reaches from the camera

-- --------------------------------------------------------------------------
-- catalog — grouped the same way the in-game menu shows them
-- --------------------------------------------------------------------------
Config.Categories = {

    { id = 'concrete', label = 'Concrete & barriers', items = {
        { model = 'prop_barier_conc_01a', label = 'Concrete barrier (weathered, rebar)' },
        { model = 'prop_barier_conc_01b', label = 'Concrete barrier (weathered, rebar) B' },
        { model = 'prop_barier_conc_02a', label = 'Concrete barrier, type 2' },
        { model = 'prop_barier_conc_02b', label = 'Concrete barrier, type 2B' },
        { model = 'prop_barier_conc_03a', label = 'Concrete barrier, type 3' },
        { model = 'prop_barier_conc_04a', label = 'Concrete barrier, type 4' },
        { model = 'prop_barier_conc_05a', label = 'Concrete barrier, type 5' },
        { model = 'prop_barier_conc_05b', label = 'Concrete barrier, type 5 (red/white stripe)' },
        { model = 'prop_mp_conc_barrier_01', label = 'Concrete jersey barrier' },
        { model = 'prop_mp_barrier_01', label = 'Jersey barrier (red/white reflective)' },
        { model = 'prop_mp_barrier_02', label = 'Jersey barrier (red/white reflective) B' },
        { model = 'prop_conc_blocks01a', label = 'Palleted concrete blocks' },
        { model = 'prop_conc_blocks01b', label = 'Palleted concrete blocks B' },
        { model = 'prop_conc_sacks_02a', label = 'Stacked sandbags' },
    } },

    { id = 'kerb', label = 'Kerbs & road edging', note = 'These are authored as integrated road/map geometry, not freestanding props — test placement and collision in game before relying on them.', items = {
        { model = 'm23_2_prop_m32_curb_str_m_01a', label = 'Asphalt kerb, straight (medium)' },
        { model = 'm23_2_prop_m32_curb_str_xl_01a', label = 'Asphalt kerb, straight (long)' },
        { model = 'm23_2_prop_m32_curb_90_01a', label = 'Asphalt kerb, 90° corner' },
        { model = 'm24_1_prop_m41_curb_15_01a', label = 'Kerb, curved/tapering' },
    } },

    { id = 'wall', label = 'Brick & wall', note = 'Vanilla GTA has no standalone wall-panel prop — these are single blocks/fragments, useful for stacking or damage dressing, not a drop-in wall section.', items = {
        { model = 'prop_wallbrick_01', label = 'Masonry block (moss-stained)' },
        { model = 'prop_wallbrick_02', label = 'Masonry block (moss-stained) B' },
        { model = 'prop_wallbrick_03', label = 'Masonry block (moss-stained) C' },
        { model = 'prop_wallchunk_01', label = 'Broken cinder-block wall fragment' },
    } },

    { id = 'fence', label = 'Fences & railings', items = {
        { model = 'prop_fnclink_01a', label = 'Chain-link fence panel' },
        { model = 'prop_fnclink_02a', label = 'Chain-link fence panel, type 2' },
        { model = 'prop_fnclink_03a', label = 'Chain-link fence panel, type 3' },
        { model = 'prop_fnclink_04a', label = 'Chain-link fence panel, type 4' },
        { model = 'prop_fnclink_05a', label = 'Chain-link fence panel, type 5' },
        { model = 'prop_fnclink_06a', label = 'Chain-link fence panel, type 6' },
        { model = 'prop_fnclink_07a', label = 'Chain-link fence panel, type 7' },
        { model = 'prop_fnclink_08b', label = 'Chain-link fence panel, type 8' },
        { model = 'prop_fnclink_09a', label = 'Chain-link fence panel, type 9' },
        { model = 'prop_fnclink_10a', label = 'Chain-link fence panel, type 10' },
        { model = 'prop_fncwood_01a', label = 'Wood fence panel' },
        { model = 'prop_fncwood_01b', label = 'Wood fence panel B' },
        { model = 'prop_fncwood_01c', label = 'Wood fence panel C' },
        { model = 'prop_fncwood_19a', label = 'Wood fence panel, type 19' },
        { model = 'prop_fncres_01a', label = 'Residential bar fence (dark green)' },
        { model = 'prop_fncsec_01a', label = 'Security palisade fence' },
        { model = 'prop_fnccorgm_01a', label = 'Corrugated metal fence (rusty)' },
        { model = 'prop_fnclog_01a', label = 'Log fence' },
        { model = 'prop_fnclog_02a', label = 'Log fence, type 2' },
        { model = 'prop_fnc_omesh_01a', label = 'Orange plastic construction mesh' },
        { model = 'prop_fncglass_01a', label = 'Glass panel / railing' },
        { model = 'prop_fnc_farm_01a', label = 'Farm fence' },
        { model = 'prop_fncbeach_01a', label = 'Beach fence' },
        { model = 'prop_fncply_01a', label = 'Plywood fence' },
        { model = 'prop_ld_balcfnc_01a', label = 'Balcony railing' },
        { model = 'prop_ld_balcfnc_02a', label = 'Balcony railing, type 2' },
        { model = 'prop_ld_balcfnc_03a', label = 'Balcony railing, type 3' },
    } },

    { id = 'gate', label = 'Gates (static — not animated)', note = 'These are decorative static gates for dressing a scene. For a gate that actually opens/locks/takes a PIN, use opslabs-towers\' Config.Buildings gate-frame system instead.', items = {
        -- pedestrian
        { model = 'prop_fncwood_01gate', label = 'Pedestrian — wood garden gate' },
        { model = 'prop_fncres_02_gate1', label = 'Pedestrian — wrought-iron garden gate' },
        { model = 'prop_fncsec_01gate', label = 'Pedestrian — palisade security gate' },
        -- driveway / ornate
        { model = 'prop_lrggate_01a', label = 'Driveway — ornate double iron gate' },
        { model = 'prop_lrggate_03a', label = 'Driveway — scrollwork iron gate' },
        { model = 'prop_gate_frame_01', label = 'Driveway gate frame, type 1' },
        { model = 'prop_gate_frame_02', label = 'Driveway gate frame, type 2' },
        -- compound / industrial
        { model = 'prop_facgate_01', label = 'Compound — sliding chain-link gate (barbed wire)' },
        { model = 'prop_facgate_02_l', label = 'Compound — industrial gate, left leaf' },
        { model = 'prop_facgate_03_l', label = 'Compound — industrial gate, type 3 left' },
        { model = 'prop_facgate_03_r', label = 'Compound — industrial gate, type 3 right' },
        -- farm
        { model = 'prop_gate_farm_01a', label = 'Farm — five-rail tubular gate' },
        { model = 'prop_gate_farm_03', label = 'Farm gate, type 3' },
        { model = 'prop_gate_farm_post', label = 'Farm gate — post' },
        -- security / prison
        { model = 'prop_gate_prison_01', label = 'Security — perforated steel gate' },
        { model = 'prop_gate_military_01', label = 'Security — chain-link gate (no entry)' },
        { model = 'prop_sec_gate_01b', label = 'Security — diamond-mesh gate' },
        -- overhead / compound entrance kit
        { model = 'prop_gate_frame_01', label = 'Overhead gantry with barrier arms' },
        { model = 'prop_gatecom_01', label = 'Gate intercom / access-control post (pairs with a gate)' },
    } },

    { id = 'lighting', label = 'Street & outdoor lighting', items = {
        { model = 'prop_streetlight_01', label = 'Streetlight — tall fluted cobra-head' },
        { model = 'prop_streetlight_02', label = 'Streetlight, type 2' },
        { model = 'prop_streetlight_03', label = 'Streetlight — tall tapered cobra-head' },
        { model = 'prop_streetlight_04', label = 'Streetlight, type 4' },
        { model = 'prop_streetlight_05', label = 'Streetlight, type 5' },
        { model = 'prop_streetlight_06', label = 'Streetlight, type 6' },
        { model = 'prop_streetlight_07a', label = 'Streetlight, type 7' },
        { model = 'prop_streetlight_08', label = 'Streetlight, type 8' },
        { model = 'prop_streetlight_09', label = 'Streetlight, type 9' },
        { model = 'prop_streetlight_10', label = 'Streetlight, type 10' },
        { model = 'prop_streetlight_11a', label = 'Streetlight — slim square post' },
        { model = 'prop_streetlight_12a', label = 'Streetlight, type 12' },
        { model = 'prop_streetlight_14a', label = 'Streetlight, type 14' },
        { model = 'prop_streetlight_15a', label = 'Streetlight, type 15' },
        { model = 'prop_streetlight_16a', label = 'Streetlight, type 16' },
        { model = 'prop_bollard_01a', label = 'Bollard (white/black banded)', note = 'Decorative post — not confirmed as a light source.' },
        { model = 'prop_bollard_04', label = 'Bollard (ornate cast-iron, ball top)', note = 'Decorative post — not confirmed as a light source.' },
        { model = 'prop_worklight_01a', label = 'Portable tripod floodlight' },
        { model = 'prop_worklight_02a', label = 'Portable tripod floodlight, type 2' },
        { model = 'prop_worklight_04a', label = 'Portable tripod floodlight, type 4' },
    } },

    { id = 'barrier', label = 'Traffic & crowd barriers', items = {
        { model = 'prop_barriercrash_01', label = 'Crash barrier / impact attenuator' },
        { model = 'prop_railway_barrier_01', label = 'Boom barrier arm (red/white, counterweighted)' },
        { model = 'prop_plas_barier_01a', label = 'Plastic road barrier block' },
        { model = 'prop_barrier_work01a', label = 'Roadwork barrier' },
        { model = 'prop_barrier_work05a', label = 'Roadwork barricade (police do-not-cross A-frame)' },
        { model = 'prop_ld_barrier_01', label = 'Freestanding crowd barrier (banner panel)' },
    } },

    { id = 'landscaping', label = 'Bushes, hedges & planters', note = 'Vanilla GTA has no dedicated "hedge" or fake-grass-mat prop — the trimmed/neat bushes below are the closest substitute for a hedge line.', items = {
        { model = 'prop_bush_lrg_01', label = 'Large bush' },
        { model = 'prop_bush_lrg_02', label = 'Large bush, type 2' },
        { model = 'prop_bush_lrg_03', label = 'Large bush, type 3' },
        { model = 'prop_bush_med_01', label = 'Medium bush' },
        { model = 'prop_bush_med_04', label = 'Medium bush, type 4' },
        { model = 'prop_bush_neat_01', label = 'Trimmed/neat bush (hedge substitute)' },
        { model = 'prop_bush_neat_04', label = 'Trimmed/neat bush, type 4' },
        { model = 'prop_bush_neat_08', label = 'Trimmed/neat bush, type 8' },
        { model = 'prop_bush_ivy_01', label = 'Wall-climbing ivy' },
        { model = 'prop_bush_ivy_02', label = 'Wall-climbing ivy, type 2' },
        { model = 'prop_bush_ornament_01', label = 'Ornamental bush' },
        { model = 'prop_ld_planter1a', label = 'Concrete garden planter' },
        { model = 'prop_ld_planter2a', label = 'Concrete garden planter, type 2' },
        { model = 'prop_ld_planter3a', label = 'Concrete garden planter, type 3' },
    } },

    -- these categories were asked for but have no vanilla GTA V equivalent (checked against the live object
    -- list, not just "couldn't find one") — they stay here, empty, so the menu is honest about the gap instead
    -- of silently dropping the category. Drop a custom `opslabs_*` model into `items` here to fill one in.
    { id = 'road_markings', label = 'Road markings', items = {}, note = 'No vanilla prop exists — road markings are baked into the road texture in GTA V. This needs a custom decal/material, not a placeable prop.' },
    { id = 'drainage', label = 'Drainage (manholes, grates, gutters)', items = {}, note = 'No vanilla manhole cover, drain grate or gutter prop exists in the base game.' },
    { id = 'fake_grass', label = 'Fake grass mats', items = {}, note = 'No vanilla "astroturf mat" prop exists — only sparse natural grass tufts, which don\'t read as artificial grass.' },
    { id = 'pavement', label = 'Pavement / footpath tiles', items = {}, note = 'No vanilla prop exists — footpaths are baked into the road/sidewalk mesh in GTA V.' },
}
