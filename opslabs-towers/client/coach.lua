-- Job guide coach: a step-by-step guide that watches what you do and tells you what's next. F7 (/poleguide)
-- opens it any time; offered the first time you start pole work in a session (climb, ladder, pole kit).
-- Progress is kept per player (KVP), so it carries on after a reconnect.
--
-- Guides are grouped by company (F7 → pick a company → pick a job) and, job-type guides apart from the three
-- general "skills" ones, map 1:1 onto a real job code from the OPS Work catalogue (CATALOG.jobTypes in
-- opsphone-store/ops_catalog.json) - the `code` field on each track is that job code, purely for reference.
-- Not every job type has one: OPS Web / OPS Cloud / OPS Domains and the seven OPS Network "isp_config" router
-- *settings* jobs are configured from the OPS Phone laptop (OPS OS), not built in the physical world opslabs-
-- towers tracks, so there's nothing here for a physical coach to watch for. OPS POS Systems is a separate
-- resource (opslabs-pos) with its own install flow, also out of scope for this file.
--
-- Every step's `done(event, data)` is checked against real game events (see the EVENTS table at the bottom) -
-- a step only ticks off when you've actually done the thing, not just read about it. Where no such signal
-- exists (most "onsite" diagnostic jobs: speed complaints, fault-finding, support visits - there's no fixed
-- sequence of actions to watch for), the step is informational only; "Skip this step" in the F7 menu is the
-- intended way past those.

local CC = Config.Cabling
local KVP_STATE, KVP_NOASK = 'opslabs_coach_state', 'opslabs_coach_noask'

local function fixtureModel(id)
    if not id or not CablingFixtures then return nil end
    local f = CablingFixtures()[id]
    return f and f.model
end

local function equipEntry(model)
    for _, e in ipairs(CC.Equipment or {}) do
        if e.model == model then return e end
        for _, s in ipairs(e.sizes or {}) do if s.model == model then return e end end
    end
end

-- does a run (cable / fibre / copper / power) start or end on a fixture whose model matches the pattern?
local function runTouches(run, pattern)
    if type(run) ~= 'table' then return false end
    for _, id in ipairs({ run.end_fixture, run.start_fixture }) do
        local m = fixtureModel(id)
        if m and m:find(pattern) then return true end
    end
    return false
end

local function placed(pattern) return function(e, d) return e == 'fixture' and d.model and d.model:find(pattern) ~= nil end end
local function fibreTo(pattern) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == 'fibre' and runTouches(d, pattern) end end
local function cableTo(pattern) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == 'cable' and runTouches(d, pattern) end end
local function copperTo(pattern) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == 'copper' and runTouches(d, pattern) end end
local function powerTo(pattern) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == 'power' and runTouches(d, pattern) end end
local function anyRun(kind) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == kind end end

--- several patterns, any one of them finishing the cable counts (e.g. "to the NVR or a PoE switch")
local function cableToAny(patterns)
    return function(e, d)
        if not ((e == 'run' or e == 'terminate') and d.kind == 'cable') then return false end
        for _, p in ipairs(patterns) do if runTouches(d, p) then return true end end
        return false
    end
end

--- an exact set of fixture models (for a job's own `verify.models` list, rather than one shared pattern)
local function placedAny(models)
    local set = {}
    for _, m in ipairs(models) do set[m] = true end
    return function(e, d) return e == 'fixture' and d.model and set[d.model] == true end
end

--- same, for Wi-Fi / cell towers (Config.Wifi.Props, opslabs-towers:save) - a different table from Cabling
--- fixtures, so it needs its own matcher and its own EVENTS entry (below).
local function towerAny(models)
    local set = {}
    for _, m in ipairs(models) do set[m] = true end
    return function(e, d) return e == 'tower' and d.model and set[d.model] == true end
end

--- no reliable in-game signal for this one (a diagnostic visit with no fixed sequence of actions) - the step
--- exists for the "what to check" text; "Skip this step" in the F7 menu is how you move past it.
local function manual() return function() return false end end

local NET_GATEWAYS = { 'opslabs_gw_pro', 'opslabs_gw_mini', 'opslabs_edge_e5', 'opslabs_edge_e7', 'opslabs_homerouter_ax4', 'opslabs_mesh_m1' }
local NET_APS = { 'opslabs_ap_halo', 'opslabs_ap_halo_ceiling', 'opslabs_ap_beam', 'opslabs_ap_beam_ceiling', 'opslabs_mesh_m1' }
local NET_POE_APS = { 'opslabs_ap_halo', 'opslabs_ap_halo_ceiling', 'opslabs_ap_beam', 'opslabs_ap_beam_ceiling' }
local CCTV_CAMERAS = { 'opslabs_cctv_bullet', 'opslabs_cctv_dome', 'opslabs_cctv_turret', 'opslabs_cctv_fisheye', 'opslabs_cctv_ptz', 'opslabs_cctv_anpr',
    'opslabs_cctv_thermal', 'opslabs_cctv_analog', 'opslabs_cctv_wifi', 'opslabs_cctv_doorbell' }
local CCTV_RECORDERS = { 'opslabs_cctv_nvr', 'opslabs_cctv_dvr' }

---------------------------------------------------------------------------
-- company groups (F7's first menu) - codes match ops_catalog.json's "companies" entries
---------------------------------------------------------------------------
local COMPANIES = {
    { id = 'skills', label = 'General skills', icon = 'graduation-cap', color = '#8e8e93' },
    { id = 'fibre', label = 'OPS Fibre', icon = 'house-signal', color = '#30d158' },
    { id = 'network', label = 'OPS Network', icon = 'wifi', color = '#0a84ff' },
    { id = 'comms', label = 'OPS Communications', icon = 'phone', color = '#5e5ce6' },
    { id = 'systems', label = 'OPS Systems', icon = 'desktop', color = '#8e8e93' },
    { id = 'mobile', label = 'OPS Mobile', icon = 'signal', color = '#0a84ff' },
    { id = 'sapl', label = 'San Andreas Power & Light', icon = 'bolt', color = '#ffd60a' },
    { id = 'solar', label = 'San Andreas Solar', icon = 'solar-panel', color = '#ff9f0a' },
    { id = 'secure', label = 'OPS Secure', icon = 'video', color = '#ff453a' },
    { id = 'data', label = 'OPS Data', icon = 'server', color = '#8b7bff' },
    { id = 'fuel', label = 'OPS Fuel', icon = 'gas-pump', color = '#e5383b' },
    { id = 'track', label = 'OPS Track', icon = 'location-crosshairs', color = '#22d3ee' },
    { id = 'usfiber', label = 'OPS America Fiber', icon = 'flag-usa', color = '#2f6bff' },
    { id = 'usosp', label = 'OPS America Outside Plant', icon = 'road', color = '#2f6bff' },
    { id = 'usnet', label = 'OPS America Network Ops', icon = 'network-wired', color = '#2f6bff' },
}

---------------------------------------------------------------------------
-- tracks
---------------------------------------------------------------------------
local TRACKS = {
    -- =====================================================================
    -- General skills (not tied to a specific job code)
    -- =====================================================================
    {
        id = 'fibre', company = 'fibre', code = 'fibre_install', title = 'Fibre to a house', icon = 'house-signal', color = '#30d158',
        sub = 'Overhead drop: pole → CBT → drop cable → CSP → ONT → live line',
        steps = {
            { title = 'Find or place a telegraph pole',
              how = { 'Any telegraph pole on the map works', 'Or /towers → OPS Openline → Telecom equipment → Poles & fixings' },
              done = function(e, d) return placed('^opslabs_pole_%d+m$')(e, d) or e == 'climb_pole' or e == 'ladder' end },
            { title = 'Get up the pole',
              how = { 'Walk up to it and press [E] to climb', 'Or stand a ladder against it (/ladder) and climb that' },
              done = function(e) return e == 'climb_pole' or e == 'climb_ladder' end },
            { title = 'Fit a CBT near the top',
              how = { 'On the pole (or ladder) press [G]', 'Pick “Mount: CBT” and choose 4, 8 or 12 ports' },
              done = placed('^opslabs_cbt') },
            { title = 'Feed the CBT with fibre',
              how = { 'Place a black fibre box or spine drum by a cabinet / joint', 'Pull fibre from it (/towers → OPS Openline → Pull cable)', 'Clip it up the poles and finish on the CBT' },
              done = fibreTo('^opslabs_cbt') },
            { title = 'Fit a house pole or anchor on the house',
              how = { 'No house? /towers → Buildings & sites → Customer house', 'Then OPS Openline → Telecom equipment → Poles & fixings → House pole', 'or Customer premises · outside → Anchor eyebolt' },
              done = placed('^opslabs_house_pole') , alt = placed('^opslabs_wall_anchor') },
            { title = 'Fit a CSP on the outside wall',
              how = { 'Telecom equipment → Customer premises · outside → CSP', 'Aim at the wall where the drop will come in' },
              done = placed('^opslabs_csp') },
            { title = 'Put a ULW drop drum by the pole',
              how = { '/towers → OPS Openline → Place a cable box or drum', 'Choose “ULW drop”' },
              done = function(e, d) return e == 'box' and d.kind == 'drop' end },
            { title = 'Run the drop from the CBT to the CSP',
              how = { 'Pull from the drum, climb up and clip it to the CBT', 'Span across to the house pole / anchor ([E] to fix)', 'Finish on the CSP' },
              done = fibreTo('^opslabs_csp') },
            { title = 'Fit the ONT inside',
              how = { 'Telecom equipment → Customer premises · inside → ONT', 'Place it on an inside wall near the router' },
              done = placed('^opslabs_ont$') },
            { title = 'Patch the CSP to the ONT',
              how = { 'Pull fibre (yellow or ULW) from the CSP side', 'Run it through the wall and finish on the ONT' },
              done = fibreTo('^opslabs_ont$') },
            { title = 'Provision the line',
              how = { '/towers → Tools → Nearby equipment → the ONT', 'Pick “Provision internet service”, choose provider & plan', 'CS can also do it on the website (Admin → Internet service)' },
              done = function(e) return e == 'provision' end },
            { title = 'Check the lights',
              how = { 'Walk up to the ONT — the status pop-up opens', 'POWER, PON and INTERNET green = the customer is live' },
              done = function(e, d) return e == 'ont' and d.internet == 'on' end },
        },
    },
    {
        id = 'basics', company = 'skills', title = 'Pole & ladder basics', icon = 'person-arrow-up-from-line', color = '#0a84ff',
        sub = 'Ladder, climbing, fitting kit, cutting and re-fixing cable',
        steps = {
            { title = 'Stand a ladder against a pole',
              how = { '/ladder (or /towers → Tools → Place an extension ladder)', 'Walk to the pole — it leans on its own · [Enter] to stand it' },
              done = function(e) return e == 'ladder' end },
            { title = 'Climb the ladder',
              how = { 'Stand at its foot and press [E]', '[W]/[S] rung by rung · [H] at the foot to extend it' },
              done = function(e) return e == 'climb_ladder' end },
            { title = 'Step across onto the pole',
              how = { 'At the top of the ladder press [F]', 'You clip on with your feet on the pegs' },
              done = function(e) return e == 'climb_pole' end },
            { title = 'Fit something to the pole',
              how = { 'Press [G] for the pole menu', 'Pick any “Mount:” item — it goes on the side you face' },
              done = function(e, d) local en = e == 'fixture' and equipEntry(d.model) return en and en.pole == true end },
            { title = 'Cut a cable',
              how = { 'On the pole or ladder press [C]', 'Arrows pick the cable and the cut point · [Enter] to cut' },
              done = function(e) return e == 'cut' end },
            { title = 'Deal with the loose end',
              how = { 'Walk to the loose end and press [E] to pick it up', 'Fix it to a pole / wall, or drop it on the ground' },
              done = function(e) return e == 'loose' end },
        },
    },
    {
        id = 'power', company = 'skills', title = 'Power line', icon = 'bolt', color = '#ffd60a',
        sub = 'San Andreas Power & Light: pole, transformer, cut-outs, cable, safety',
        steps = {
            { title = 'Place a wooden power pole',
              how = { '/towers → San Andreas Power & Light → Power equipment → Power poles' },
              done = placed('^opslabs_power_pole') },
            { title = 'Climb the power pole',
              how = { 'Walk up to it and press [E]', 'Or put a 13 m ladder against it' },
              done = function(e) return e == 'climb_pole' or e == 'climb_ladder' end },
            { title = 'Fit the transformer',
              how = { 'Press [G] → “Mount: Pole-mounted transformer”' },
              done = placed('^opslabs_power_transformer') },
            { title = 'Fit the cut-outs',
              how = { 'Press [G] → “Mount: Cut-out fuses & surge arresters”' },
              done = placed('^opslabs_power_cutouts') },
            { title = 'Run power cable',
              how = { '/towers → San Andreas Power & Light → Run power cable', 'HV between poles, LV bundled, or a service drop to a house' },
              done = function(e, d) return e == 'run' and d.kind == 'power' end },
            { title = 'Make it safe',
              how = { 'Fit a Danger of Death sign or an anti-climbing device', '[G] on the pole → Safety items' },
              done = function(e, d) return placed('^opslabs_power_danger_sign')(e, d) or placed('^opslabs_power_anticlimb')(e, d) end },
        },
    },

    -- =====================================================================
    -- OPS Fibre (fibre_* beyond the house build above)
    -- =====================================================================
    {
        id = 'fibre_cabinet', company = 'fibre', code = 'fibre_cabinet', title = 'Network cabinet installation', icon = 'box', color = '#30d158',
        sub = 'A street cabinet feeding the local network',
        steps = {
            { title = 'Place the street cabinet',
              how = { '/towers → OPS Openline → Telecom equipment → Street cabinets & chambers', 'PCP, FTTC DSLAM cabinet, or the green 3-door cabinet' },
              done = placedAny({ 'opslabs_cabinet_pcp', 'opslabs_cabinet_fttc', 'opslabs_cabinet_green3' }) },
            { title = 'Feed it with fibre',
              how = { 'Pull fibre from a box and run it to the cabinet' },
              done = fibreTo('^opslabs_cabinet_') },
        },
    },
    {
        id = 'fibre_dp', company = 'fibre', code = 'fibre_dp', title = 'Distribution point installation', icon = 'diagram-project', color = '#30d158',
        sub = 'A CBT or copper DP distributing the network onward',
        steps = {
            { title = 'Fit the distribution point',
              how = { 'On a pole: [G] → Mount: CBT, or Mount: Copper DP box', 'Underground: Telecom equipment → Underground joints → U-CBT' },
              done = function(e, d) return placed('^opslabs_cbt')(e, d) or placed('^opslabs_copper_dp')(e, d) or placed('^opslabs_ucbt')(e, d) end },
            { title = 'Feed it',
              how = { 'Run fibre (or copper, for a copper DP) in from the network side' },
              done = function(e, d) return fibreTo('^opslabs_cbt')(e, d) or fibreTo('^opslabs_ucbt')(e, d) or copperTo('^opslabs_copper_dp')(e, d) end },
        },
    },
    {
        id = 'fibre_test', company = 'fibre', code = 'fibre_test', title = 'Fibre testing', icon = 'wave-square', color = '#30d158',
        sub = 'OTDR, visual fault locator, optical power meter',
        steps = {
            { title = 'Check the fibre with the right tool',
              how = { 'OTDR: shoots the fibre — length, breaks, open ends', 'Visual fault locator: breaks / open ends glow red for 30 s', 'Optical power meter: dBm reading at the ONT' },
              done = manual() },
        },
    },
    {
        id = 'fibre_repair', company = 'fibre', code = 'fibre_repair', title = 'Fibre repair', icon = 'wrench', color = '#30d158',
        sub = 'Find the break, re-splice or replace',
        steps = {
            { title = 'Find the break',
              how = { 'OTDR or visual fault locator from the ONT (or the nearest working point) back towards the fault' },
              done = manual() },
            { title = 'Fix it',
              how = { 'Cut back to good fibre, fusion splice (one-click cleaner → strip → cleave → splice → heat-shrink)', 'Or replace the ONT if the fault is the unit itself' },
              done = function(e) return e == 'cut' end },
        },
    },

    -- =====================================================================
    -- OPS Network (home / business networking)
    -- =====================================================================
    {
        id = 'net_router', company = 'network', code = 'net_router', title = 'Router installation', icon = 'router', color = '#0a84ff',
        sub = 'Fit and power a new gateway for the customer',
        steps = {
            { title = 'Place and power the gateway',
              how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point', 'Pick OPS Gateway Pro / Mini, EdgeLink E5 / E7, HomeRouter AX4 or Mesh M1', 'Needs a live socket within 3 m' },
              done = towerAny(NET_GATEWAYS) },
        },
    },
    {
        id = 'net_router_swap', company = 'network', code = 'net_router_swap', title = 'Router replacement', icon = 'rotate', color = '#0a84ff',
        sub = 'Customer\'s gateway has failed',
        steps = {
            { title = 'Take out the failed unit',
              how = { 'Nearby towers → the dead gateway → delete, or move it aside' },
              done = manual() },
            { title = 'Fit the replacement and power it',
              how = { 'Same models as a fresh install: Gateway Pro / Mini, EdgeLink E5 / E7, HomeRouter AX4, Mesh M1' },
              done = towerAny(NET_GATEWAYS) },
        },
    },
    {
        id = 'net_switch', company = 'network', code = 'net_switch', title = 'Switch installation', icon = 'network-wired', color = '#0a84ff',
        sub = 'A managed PoE switch in the comms cupboard',
        steps = {
            { title = 'Place the PoE switch',
              how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point → OPS Switch 8 PoE', 'Needs a live socket within 3 m' },
              done = towerAny({ 'opslabs_poe_switch8' }) },
            { title = 'Cable it in',
              how = { 'Pull CAT6 from a box and terminate it onto the switch' },
              done = anyRun('cable') },
        },
    },
    {
        id = 'net_wifi', company = 'network', code = 'net_wifi', title = 'Wi-Fi installation', icon = 'wifi', color = '#0a84ff',
        sub = 'Two access points for full coverage',
        steps = {
            { title = 'Place the first access point',
              how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point', 'OPS Halo, OPS Beam (ceiling or desk) or a Mesh M1' },
              done = towerAny(NET_APS) },
            { title = 'Place the second access point',
              how = { 'Spread them out for full coverage' },
              done = towerAny(NET_APS) },
        },
    },
    {
        id = 'net_poe', company = 'network', code = 'net_poe', title = 'PoE installation', icon = 'plug-circle-bolt', color = '#0a84ff',
        sub = 'Power a ceiling access point over PoE',
        steps = {
            { title = 'Place the ceiling access point',
              how = { 'OPS Halo or OPS Beam, ceiling-mount version' },
              done = towerAny(NET_POE_APS) },
            { title = 'Run CAT6 from a powered PoE switch',
              how = { 'Pull CAT6 from a box, terminate on the OPS Switch 8 PoE', 'The switch itself needs a live socket' },
              done = anyRun('cable') },
        },
    },
    {
        id = 'net_cat6', company = 'network', code = 'net_cat6', title = 'CAT6 installation', icon = 'ethernet', color = '#0a84ff',
        sub = 'New outlets, at least 20 m of cable',
        steps = {
            { title = 'Pull CAT6 from a box',
              how = { '/towers → Network cabling → Place a cable box', 'Pick CAT6' },
              done = function(e, d) return e == 'box' and d.kind == 'cat6' end },
            { title = 'Run and terminate both ends',
              how = { 'Fix it along walls / ceiling as you go', 'Strip, untwist, arrange T568B, trim, crimp at each end' },
              done = anyRun('cable') },
        },
    },
    {
        id = 'net_business', company = 'network', code = 'net_business', title = 'Business network installation', icon = 'building', color = '#0a84ff',
        sub = 'Gateway, PoE switch, two APs, all cabled',
        steps = {
            { title = 'Place the gateway',
              how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point' },
              done = towerAny(NET_GATEWAYS) },
            { title = 'Place the PoE switch',
              how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point → OPS Switch 8 PoE', 'Needs a live socket' },
              done = towerAny({ 'opslabs_poe_switch8' }) },
            { title = 'Place two access points',
              how = { 'OPS Halo / OPS Beam, desk or ceiling' },
              done = towerAny(NET_APS) },
            { title = 'Cable it all together',
              how = { 'CAT6 from the switch to the gateway, and to each access point' },
              done = anyRun('cable') },
        },
    },
    {
        id = 'net_speed', company = 'network', code = 'net_speed', title = 'Speed issue', icon = 'gauge-high', color = '#0a84ff',
        sub = 'Prove the fix with a speed test',
        steps = { { title = 'Run a speed test on site (Wi-Fi or wired) and get at least 70% of the package', how = { 'OPS Phone → speed test', 'Fix whatever\'s dragging it down first: Wi-Fi placement, PoE budget, a bad cable run' }, done = manual() } },
    },
    {
        id = 'net_troubleshoot', company = 'network', code = 'net_troubleshoot', title = 'Network troubleshooting', icon = 'magnifying-glass', color = '#0a84ff',
        sub = 'Intermittent drop-outs on site',
        steps = { { title = 'Find and fix the fault', how = { 'Handheld network tester at the ONT / router (speed + PPP login)', 'Check PoE budget / ports on the switch', 'Re-terminate / replace a bad CAT6 run' }, done = manual() } },
    },
    {
        id = 'net_outage', company = 'network', code = 'net_outage', title = 'Internet outage', icon = 'triangle-exclamation', color = '#0a84ff',
        sub = 'No service at all',
        steps = { { title = 'Trace it back', how = { 'Router powered? Cable to the ONT good? ONT lights OK?', 'Follow the ONT diagnostic tester\'s step-by-step fix if the fault is upstream' }, done = manual() } },
    },
    {
        id = 'isp_newcustomer', company = 'network', code = 'isp_newcustomer', title = 'New customer installation (fibre)', icon = 'user-plus', color = '#0a84ff',
        sub = 'Provision the line the job created',
        steps = {
            { title = 'Provision the line at the ONT',
              how = { 'Nearest online ONT → Internet service → pick provider & plan' },
              done = function(e) return e == 'provision' end },
            { title = 'Check the lights',
              how = { 'POWER, PON and INTERNET green = live' },
              done = function(e, d) return e == 'ont' and d.internet == 'on' end },
        },
    },

    -- =====================================================================
    -- OPS Communications (copper phone)
    -- =====================================================================
    {
        id = 'comms_line', company = 'comms', code = 'comms_line', title = 'Telephone line installation', icon = 'phone', color = '#5e5ce6',
        sub = 'Copper DP → master socket → dial tone',
        steps = {
            { title = 'Fit (or find) a copper DP on the network side',
              how = { 'On a pole: [G] → Mount: Copper DP box' },
              done = placed('^opslabs_copper_dp') },
            { title = 'Fit the master socket inside',
              how = { 'Telecom equipment → Customer premises · inside → Master socket (NTE5C)' },
              done = placed('^opslabs_nte5c$') },
            { title = 'Run and punch down the copper',
              how = { 'Run phone cable → Copper drop wire / internal CW1308', 'Punch down at each end (2 = White/Blue, 5 = Blue/White)' },
              done = copperTo('^opslabs_nte5c$') },
            { title = 'Confirm dial tone',
              how = { 'Butt set on the socket — you should hear dial tone and get a line number' },
              done = manual() },
        },
    },
    {
        id = 'comms_fault', company = 'comms', code = 'comms_fault', title = 'Phone line fault', icon = 'phone-slash', color = '#5e5ce6',
        sub = 'No dial tone, or a noisy line',
        steps = { { title = 'Find it with the copper tools', how = { 'Tone generator & probe — the toned pair glows purple', 'Copper line tester — loop resistance, insulation, distance to an open circuit', 'NTE5 test socket check — network fault or house wiring?' }, done = manual() } },
    },

    -- =====================================================================
    -- OPS Systems
    -- =====================================================================
    {
        id = 'sys_laptop', company = 'systems', code = 'sys_laptop', title = 'Workstation installation', icon = 'laptop', color = '#8e8e93',
        sub = 'A desk laptop on the network',
        steps = {
            { title = 'Place the laptop',
              how = { 'Telecom equipment → Customer premises · inside → Laptop (OPS OS, Ethernet port)' },
              done = placed('^opslabs_laptop$') },
            { title = 'Run CAT6 into it',
              how = { 'From a router / switch with an uplink, or a live ONT' },
              done = cableTo('^opslabs_laptop$') },
        },
    },
    {
        id = 'sys_support', company = 'systems', code = 'sys_support', title = 'IT support visit', icon = 'headset', color = '#8e8e93',
        sub = 'General on-site IT help',
        steps = { { title = 'Sort out whatever\'s wrong', how = { 'Check the workstation\'s link (laptop → router → internet)', 'No fixed steps — this one\'s diagnostic' }, done = manual() } },
    },

    -- =====================================================================
    -- OPS Mobile
    -- =====================================================================
    {
        id = 'mobile_coverage', company = 'mobile', code = 'mobile_coverage', title = 'Mobile coverage survey', icon = 'signal', color = '#0a84ff',
        sub = 'Check bars across the area',
        steps = { { title = 'Walk the area and note the bars', how = { 'Phone\'s signal indicator, or /towers → coverage overlay (range circles + 3D markers)', 'A gap usually means a tower\'s down or too far - place a new cell tower / Wi-Fi AP to fill it' }, done = manual() } },
    },

    -- =====================================================================
    -- San Andreas Power & Light
    -- =====================================================================
    {
        id = 'sapl_supply', company = 'sapl', code = 'sapl_supply', title = 'New electricity supply', icon = 'plug', color = '#ffd60a',
        sub = 'Service drop → cut-out/meter → consumer unit',
        steps = {
            { title = 'Fit the service cut-out, meter, or an all-in-one meter cabinet outside',
              how = { 'Customer supply & metering → Service cut-out + Smart meter, or just the Outside meter cabinet (counts as both)' },
              done = function(e, d) return placed('^opslabs_mains_cutout$')(e, d) or placed('^opslabs_mains_meterbox$')(e, d) end,
              alt = placed('^opslabs_mains_meter$') },
            { title = 'Fit the consumer unit inside and switch it on',
              how = { 'Fuse boards & isolators → Consumer unit', '[E] the main switch once it\'s wired up' },
              done = placed('^opslabs_mains_cu$') },
            { title = 'Run the service cable',
              how = { 'Run power cable → service drop, from the nearest live pole to the cut-out / meter cabinet' },
              done = powerTo('^opslabs_mains_cutout$'), alt = powerTo('^opslabs_mains_meterbox$') },
        },
    },
    {
        id = 'sapl_ev', company = 'sapl', code = 'sapl_ev', title = 'EV charger installation', icon = 'car-side', color = '#ffd60a',
        sub = 'Wallbox or post, wired to a live consumer unit',
        steps = {
            { title = 'Fit the EV charger',
              how = { 'Plug-in & charging → EV charging → EV wallbox 7.4 kW or EV charging post' },
              done = placedAny({ 'opslabs_mains_ev_wall', 'opslabs_mains_ev_post' }) },
            { title = 'Wire it to a live consumer unit',
              how = { 'Within AutoWireRadius of a live consumer unit it just works', 'Or run mains cable / flex straight to it' },
              done = powerTo('^opslabs_mains_ev_') },
        },
    },
    {
        id = 'sapl_station', company = 'sapl', title = 'Power station: build & connect', icon = 'industry', color = '#ffd60a',
        sub = 'Gas power station → pylons → 400 kV run → substation → start a unit',
        steps = {
            { title = 'Build the power station',
              how = { '/towers → San Andreas Power & Light → Generation → Gas power station (4 × 120 MW)' },
              done = placed('^opslabs_grid_station$') },
            { title = 'Have a substation for it to feed',
              how = { 'Use one that\'s already there, or place one that needs no fitting out', 'Substations → Primary substation 400 / 11 kV (yard)', 'or Substations → Substation building · fully fitted (walk-in)' },
              done = placedAny({ 'opslabs_grid_substation', 'opslabs_grid_subbuilding' }) },
            { title = 'Walk a line of pylons from the station towards the substation',
              how = { 'Transmission → 400 kV lattice pylon, one after another' },
              done = placed('^opslabs_grid_pylon$') },
            { title = 'Run the 400 kV conductor',
              how = { 'Run power cable → 400 kV transmission conductor (pylons)', 'Start on the station\'s gantry, follow the pylons in, finish on the substation' },
              done = powerTo('^opslabs_grid_station$') },
            { title = 'Start a generating unit',
              how = { 'Walk into the station yard and press [E] — "Power station control"', 'Pick an offline unit to start it — 90 seconds to synchronise' },
              done = manual() },
            { title = 'Check it\'s actually live',
              how = { '[E] in the yard again: it should read RUNNING with output above 0 MW', 'At the substation, [E] → the 400 kV line in and the feeders should show closed, not faulted' },
              done = manual() },
        },
    },

    -- =====================================================================
    -- San Andreas Solar
    -- =====================================================================
    {
        id = 'solar_install', company = 'solar', code = 'solar_install', title = 'Solar PV installation', icon = 'solar-panel', color = '#ff9f0a',
        sub = 'Panels → isolator → inverter (→ battery)',
        steps = {
            { title = 'Place the panels',
              how = { 'Install → Solar panels → Roof panel 400 W (aim at the roof) or Ground-mount array 2.4 kW' },
              done = placedAny({ 'opslabs_solar_panel_roof', 'opslabs_solar_array_ground' }) },
            { title = 'Fit the hybrid inverter',
              how = { 'Install → Inverters & batteries → Hybrid inverter 5 kW', 'Within 30 m of the panels, near the consumer unit' },
              done = placed('^opslabs_solar_inverter$') },
            { title = 'Fit the PV DC isolator',
              how = { 'Install → Isolators & protection', 'Makes the array safe to work on' },
              done = placed('^opslabs_solar_dciso$') },
            { title = 'Add a home battery (optional)',
              how = { 'Install → Inverters & batteries → Home battery 13.5 kWh', 'Within 4 m of the inverter — stores daytime solar for night / power cuts' },
              done = placed('^opslabs_solar_battery$') },
        },
    },

    -- =====================================================================
    -- OPS Secure (CCTV + OPS Access)
    -- =====================================================================
    {
        id = 'cctv_install', company = 'secure', code = 'cctv_install', title = 'Install CCTV cameras', icon = 'video', color = '#ff453a',
        sub = 'Camera → CAT6 → NVR / DVR / PoE switch',
        steps = {
            { title = 'Place the camera',
              how = { 'IP cameras (PoE), Specialist cameras, or Wireless & doorbells' },
              done = placedAny(CCTV_CAMERAS) },
            { title = 'Wire it to a recorder',
              how = { 'IP → NVR (direct or via a PoE switch) · analogue → DVR' },
              done = function(e, d) return cableToAny({ '^opslabs_cctv_nvr$', '^opslabs_cctv_dvr$' })(e, d) or anyRun('cable')(e, d) end },
        },
    },
    {
        id = 'cctv_nvr', company = 'secure', code = 'cctv_nvr', title = 'Install NVR', icon = 'server', color = '#ff453a',
        sub = '16 channel, 8 × PoE - needs a live socket',
        steps = { { title = 'Place the NVR', how = { 'Recorders & viewing → NVR 16 channel · 8 × PoE' }, done = placed('^opslabs_cctv_nvr$') } },
    },
    {
        id = 'cctv_dvr', company = 'secure', code = 'cctv_dvr', title = 'Install DVR', icon = 'server', color = '#ff453a',
        sub = '8 channel, for analogue cameras',
        steps = { { title = 'Place the DVR', how = { 'Recorders & viewing → DVR 8 channel (analogue)' }, done = placed('^opslabs_cctv_dvr$') } },
    },
    {
        id = 'cctv_ptz', company = 'secure', code = 'cctv_ptz', title = 'Install PTZ camera', icon = 'arrows-spin', color = '#ff453a',
        sub = 'Pan / tilt / 30× zoom',
        steps = {
            { title = 'Place the PTZ speed dome', how = { 'Specialist cameras → PTZ speed dome (PoE+)' }, done = placed('^opslabs_cctv_ptz$') },
            { title = 'Wire it to the NVR', how = { 'It needs the extra PoE+ budget' }, done = function(e, d) return cableTo('^opslabs_cctv_nvr$')(e, d) or anyRun('cable')(e, d) end },
        },
    },
    {
        id = 'cctv_anpr', company = 'secure', code = 'cctv_anpr', title = 'Install ANPR camera', icon = 'car', color = '#ff453a',
        sub = 'Reads number plates in view',
        steps = {
            { title = 'Place the ANPR camera', how = { 'Specialist cameras → ANPR / LPR camera' }, done = placed('^opslabs_cctv_anpr$') },
            { title = 'Wire it to the NVR', how = {}, done = function(e, d) return cableTo('^opslabs_cctv_nvr$')(e, d) or anyRun('cable')(e, d) end },
        },
    },
    {
        id = 'cctv_thermal', company = 'secure', code = 'cctv_thermal', title = 'Install thermal camera', icon = 'fire', color = '#ff453a',
        sub = 'Sees heat - people at night, through smoke',
        steps = {
            { title = 'Place the thermal camera', how = { 'Specialist cameras → Thermal bi-spectrum camera' }, done = placed('^opslabs_cctv_thermal$') },
            { title = 'Wire it to the NVR', how = {}, done = function(e, d) return cableTo('^opslabs_cctv_nvr$')(e, d) or anyRun('cable')(e, d) end },
        },
    },
    {
        id = 'cctv_doorbell', company = 'secure', code = 'cctv_doorbell', title = 'Install video doorbell', icon = 'bell', color = '#ff453a',
        sub = 'Visitors press [E] - the owner gets a phone alert',
        steps = { { title = 'Place the doorbell', how = { 'Wireless & doorbells → Video doorbell', 'Needs an NVR within 60 m, a powered Wi-Fi / AP within 40 m, and a socket' }, done = placed('^opslabs_cctv_doorbell$') } },
    },
    {
        id = 'cctv_poe', company = 'secure', code = 'cctv_poe', title = 'Configure PoE cameras', icon = 'plug-circle-bolt', color = '#ff453a',
        sub = 'Powered straight off the NVR or a PoE switch',
        steps = { { title = 'Cable a PoE camera to a powered switch', how = { 'Within the switch\'s port and watt budget' }, done = anyRun('cable') } },
    },
    {
        id = 'cctv_remote', company = 'secure', code = 'cctv_remote', title = 'Configure remote viewing', icon = 'mobile-screen', color = '#ff453a',
        sub = 'Watch it in Secure View on the phone',
        steps = { { title = 'Turn on remote viewing at the NVR', how = { '[E] at the NVR → Set up the system → Remote viewing on', 'The NVR also needs to be cabled to an online router' }, done = function(e, d) return e == 'cctvConfig' and d.remote == true end } },
    },
    {
        id = 'cctv_recording', company = 'secure', code = 'cctv_recording', title = 'Configure recording', icon = 'circle-dot', color = '#ff453a',
        sub = 'Motion, continuous, or off',
        steps = { { title = 'Set the recording mode at the NVR / DVR', how = { '[E] → Set up the system → pick motion, continuous or off, and the retention' }, done = function(e, d) return e == 'cctvConfig' and d.mode and d.mode ~= 'off' end } },
    },
    {
        id = 'cctv_cable', company = 'secure', code = 'cctv_cable', title = 'Replace damaged camera cable', icon = 'scissors', color = '#ff453a',
        sub = 'At least 25 m of new CAT6',
        steps = {
            { title = 'Cut out the bad run', how = { 'Aim along it and press [C] (on a pole / ladder) or cut directly' }, done = function(e) return e == 'cut' end },
            { title = 'Pull and terminate a new one to the camera', how = {}, done = cableToAny(CCTV_CAMERAS) },
        },
    },
    {
        id = 'cctv_maintenance', company = 'secure', code = 'cctv_maintenance', title = 'CCTV maintenance visit', icon = 'screwdriver-wrench', color = '#ff453a',
        sub = 'General upkeep',
        steps = { { title = 'Check every camera and the recorder', how = { '[E] at each camera / the NVR shows status and any fault' }, done = manual() } },
    },
    {
        id = 'cctv_fault', company = 'secure', code = 'cctv_fault', title = 'CCTV fault finding', icon = 'bug', color = '#ff453a',
        sub = 'Dirty lens, cable fault, dead camera, or a failed hard drive',
        steps = { { title = 'Fix it at the kit', how = { 'Camera: clean lens / re-terminate / replace', 'Recorder: replace the hard drive' }, done = function(e) return e == 'cctvRepair' end } },
    },
    {
        id = 'cctv_upgrade', company = 'secure', code = 'cctv_upgrade', title = 'CCTV system upgrade', icon = 'arrow-up', color = '#ff453a',
        sub = 'Add a better camera or recorder to an existing system',
        steps = { { title = 'Add the new kit and wire it in', how = { 'Any camera or recorder model counts' }, done = function(e, d) return placedAny(CCTV_CAMERAS)(e, d) or placedAny(CCTV_RECORDERS)(e, d) end } },
    },
    {
        id = 'cctv_removal', company = 'secure', code = 'cctv_removal', title = 'CCTV system removal', icon = 'trash-can', color = '#ff453a',
        sub = 'Take it all down',
        steps = { { title = 'Remove the kit and clear its cabling', how = { 'Nearby equipment → remove, then clear up any loose cable' }, done = manual() } },
    },
    {
        id = 'cctv_access', company = 'secure', code = 'cctv_access', title = 'Access control camera', icon = 'id-card', color = '#ff453a',
        sub = 'OPS Access hub & reader, linked to a door',
        steps = {
            { title = 'Place an OPS Access hub & reader', how = { '/towers → OPS Access → Install → Hubs & readers', 'One prop is both the hub and the reader - no separate activation step' }, done = placed('^opslabs_cctv_reader$') },
            { title = 'Link it to a door', how = { '[G] at it → Link a door' }, done = function(e) return e == 'accessLink' end },
            { title = 'Issue a card', how = { '[G] at it → Issue a card (to whoever is standing next to you)', 'Or set its authorized companies instead - anyone with that job taps straight in' }, done = function(e) return e == 'accessIssueCard' end },
        },
    },

    -- =====================================================================
    -- OPS Data
    -- =====================================================================
    {
        id = 'dc_capacity', company = 'data', code = 'dc_capacity', title = 'Add cloud capacity', icon = 'server', color = '#8b7bff',
        sub = 'A rack, fitted with compute or storage',
        steps = {
            { title = 'Place a 42U rack (if there isn\'t a free one)', how = { 'Racks & power → 42U server rack', 'Plug into a socket or stand within 25 m of a UPS' }, done = placed('^opslabs_dc_rack$') },
            { title = 'Install kit in it', how = { '[E] on the rack → Install → Halcyon C1 / C2 compute or S4 SAN storage' }, done = function(e) return e == 'dcInstall' end },
        },
    },
    {
        id = 'dc_network', company = 'data', code = 'dc_network', title = 'Rack offline', icon = 'network-wired', color = '#8b7bff',
        sub = 'No ToR switch, or no CAT6 to a router with internet',
        steps = { { title = 'Fix the rack\'s network path', how = { '[E] on the rack → check / install a Meridian ToR switch', 'Run CAT6 from the rack to a router with internet' }, done = function(e) return e == 'dcRepair' end } },
    },
    {
        id = 'dc_power', company = 'data', code = 'dc_power', title = 'Data hall on battery', icon = 'car-battery', color = '#8b7bff',
        sub = 'The UPS has lost mains / generator power',
        steps = { { title = 'Fix the hall\'s power', how = { 'Socket within 3 m of the UPS, or a generator in the hall' }, done = function(e) return e == 'dcRepair' end } },
    },
    {
        id = 'dc_cooling', company = 'data', code = 'dc_cooling', title = 'Data hall overheating', icon = 'temperature-high', color = '#8b7bff',
        sub = 'Not enough CRAC cooling for the load',
        steps = { { title = 'Add or fix a CRAC cooling unit', how = { 'Cooling → CRAC cooling unit (30 kW) — needs a socket within 3 m', 'Each one removes 30 kW of heat' }, done = placed('^opslabs_crac$'), alt = function(e) return e == 'dcRepair' end } },
    },
    {
        id = 'dc_fault', company = 'data', code = 'dc_fault', title = 'Server fault', icon = 'triangle-exclamation', color = '#8b7bff',
        sub = 'Failed drive, PSU, fan or motherboard',
        steps = { { title = 'Repair it at the rack', how = { '[E] on the rack → the server → Repair' }, done = function(e) return e == 'dcRepair' end } },
    },

    -- =====================================================================
    -- OPS Fuel
    -- =====================================================================
    {
        id = 'fuel_service', company = 'fuel', code = 'fuel_service', title = 'Fuel station service visit', icon = 'gas-pump', color = '#e5383b',
        sub = 'Tank leaks / water, stock variance, dispenser faults',
        steps = { { title = 'Check and fix the station', how = { 'Tank gauge (ATG) → levels, leaks, water, vent / fill / pump checks', '[E] at the tank chamber to clear a leak or water', 'Reset the breakaway coupling or the e-stop if needed' }, done = function(e) return e == 'fuelFix' end } },
    },

    -- =====================================================================
    -- OPS Track
    -- =====================================================================
    {
        id = 'track_install', company = 'track', code = 'track_install', title = 'Vehicle tracker installation', icon = 'location-crosshairs', color = '#22d3ee',
        sub = 'OPS Track Mini or Pro, step by step',
        steps = { { title = 'Fit the tracker', how = { 'Sit in the vehicle, stopped — pick Mini (plug-and-play) or Pro (hard-wired)', 'Follow the installer tool case\'s steps in order: feeds → fuse tap → strip/crimp/heat-shrink → mount → check the LEDs' }, done = function(e) return e == 'trackInstall' end } },
    },

    -- =====================================================================
    -- OPS America Fiber
    -- =====================================================================
    {
        id = 'us_install', company = 'usfiber', code = 'us_install', title = 'Fiber install & activation', icon = 'house-signal', color = '#2f6bff',
        sub = 'Same build as a UK fibre install, US-branded kit',
        steps = {
            { title = 'Provision the line at the ONT', how = { 'Nearest online ONT → Internet service' }, done = function(e) return e == 'provision' end },
            { title = 'Check the lights', how = { 'POWER, PON and INTERNET green = live' }, done = function(e, d) return e == 'ont' and d.internet == 'on' end },
        },
    },
    {
        id = 'us_gateway', company = 'usfiber', code = 'us_gateway', title = 'Residential gateway install', icon = 'router', color = '#2f6bff',
        sub = 'Fit and power the customer\'s gateway',
        steps = { { title = 'Place and power the gateway', how = { '/towers → OPS Mobile → Place cell tower / Wi-Fi access point' }, done = towerAny(NET_GATEWAYS) } },
    },
    {
        id = 'us_ont_swap', company = 'usfiber', code = 'us_ont_swap', title = 'ONT replacement', icon = 'rotate', color = '#2f6bff',
        sub = 'Swap a failed ONT',
        steps = {
            { title = 'Place the new ONT and patch it', how = { 'Customer premises → ONT', 'Patch fibre from the CSP / NID side' }, done = fibreTo('^opslabs_ont$') },
            { title = 'Check the lights', how = {}, done = function(e, d) return e == 'ont' and d.internet == 'on' end },
        },
    },
    {
        id = 'us_aerial_drop', company = 'usfiber', code = 'us_aerial_drop', title = 'Aerial drop installation', icon = 'tower-cell', color = '#2f6bff',
        sub = 'FDT on the pole, drop to the NID',
        steps = {
            { title = 'Fit the FDT on the pole', how = { 'Outside plant · aerial → Fiber distribution terminal (FDT)' }, done = placed('^opslabs_cbt') },
            { title = 'Run the drop to the NID', how = {}, done = fibreTo('^opslabs_csp') },
        },
    },
    {
        id = 'us_buried_drop', company = 'usfiber', code = 'us_buried_drop', title = 'Buried drop installation', icon = 'road', color = '#2f6bff',
        sub = 'Underground path to the NID',
        steps = {
            { title = 'Fit a handhole or vault on the path', how = { 'Outside plant · cabinets & underground → Handhole or Vault' }, done = function(e, d) return placed('^opslabs_footway_box')(e, d) or placed('^opslabs_chamber_modular')(e, d) end },
            { title = 'Run the drop to the NID', how = {}, done = fibreTo('^opslabs_csp') },
        },
    },
    {
        id = 'us_business', company = 'usfiber', code = 'us_business', title = 'Business fiber install', icon = 'building', color = '#2f6bff',
        sub = 'FDT, drop, ONT and provisioning',
        steps = {
            { title = 'Fit the FDT on the pole', how = {}, done = placed('^opslabs_cbt') },
            { title = 'Run the drop and fit the ONT', how = {}, done = placed('^opslabs_ont$') },
            { title = 'Provision the service', how = {}, done = function(e) return e == 'provision' end },
        },
    },
    {
        id = 'us_no_service', company = 'usfiber', code = 'us_no_service', title = 'No service repair (trouble ticket)', icon = 'ticket', color = '#2f6bff',
        sub = 'Find and fix what\'s down',
        steps = { { title = 'Diagnose from the ONT', how = { 'ONT diagnostic tester reads all 5 lights and lists the exact fix', 'OTDR / VFL for anything upstream' }, done = manual() } },
    },
    {
        id = 'us_speed', company = 'usfiber', code = 'us_speed', title = 'Speed & Wi-Fi complaint', icon = 'gauge-high', color = '#2f6bff',
        sub = 'Prove the fix with a speed test',
        steps = { { title = 'Run a speed test and fix the bottleneck', how = { 'Wi-Fi placement, PoE budget, or a bad cable run' }, done = manual() } },
    },

    -- =====================================================================
    -- OPS America Outside Plant
    -- =====================================================================
    {
        id = 'us_fdh', company = 'usosp', code = 'us_fdh', title = 'Fiber distribution hub (FDH) install', icon = 'box', color = '#2f6bff',
        sub = 'The street-level fiber hub',
        steps = { { title = 'Place the FDH', how = { 'Outside plant · cabinets & underground → Fiber distribution hub (FDH), or the compact cabinet' }, done = placedAny({ 'opslabs_cabinet_green3', 'opslabs_cabinet_pcp' }) } },
    },
    {
        id = 'us_fdt', company = 'usosp', code = 'us_fdt', title = 'Fiber distribution terminal (FDT) install', icon = 'diagram-project', color = '#2f6bff',
        sub = 'On the pole, feeding drops',
        steps = { { title = 'Fit the FDT on the pole', how = {}, done = placed('^opslabs_cbt') } },
    },
    {
        id = 'us_strand', company = 'usosp', code = 'us_strand', title = 'Aerial strand & lashing', icon = 'ethernet', color = '#2f6bff',
        sub = 'At least 60 m of aerial fiber, pole to pole',
        steps = { { title = 'Run and clip the fiber along the poles', how = { 'Pull from a box, clamp to each pole as you pass it' }, done = anyRun('fibre') } },
    },
    {
        id = 'us_feeder', company = 'usosp', code = 'us_feeder', title = 'Feeder / distribution fiber placement', icon = 'ethernet', color = '#2f6bff',
        sub = 'At least 120 m, FDH to FDT',
        steps = { { title = 'Run the feeder fiber', how = { 'Same mechanic as a strand run, just longer' }, done = anyRun('fibre') } },
    },
    {
        id = 'us_handhole', company = 'usosp', code = 'us_handhole', title = 'Handhole / vault installation', icon = 'manhole', color = '#2f6bff',
        sub = 'Underground access point',
        steps = { { title = 'Place the handhole or vault', how = { 'Outside plant · cabinets & underground' }, done = function(e, d) return placed('^opslabs_footway_box')(e, d) or placed('^opslabs_chamber_modular')(e, d) or placed('^opslabs_manhole')(e, d) end } },
    },
    {
        id = 'us_splice', company = 'usosp', code = 'us_splice', title = 'Splice closure & splicing', icon = 'link', color = '#2f6bff',
        sub = 'Join fiber at an aerial or underground closure',
        steps = {
            { title = 'Fit the splice closure', how = { 'Outside plant · aerial → Aerial or Dome splice closure, or an underground splice closure' }, done = function(e, d) return placed('^opslabs_splice_enclosure')(e, d) or placed('^opslabs_joint_tophat')(e, d) or placed('^opslabs_ucbt')(e, d) end },
            { title = 'Splice the fibre through it', how = { 'Strip, clean, cleave, fusion splice, heat-shrink sleeve' }, done = fibreTo('^opslabs_splice_enclosure') },
        },
    },
    {
        id = 'us_fiber_cut', company = 'usosp', code = 'us_fiber_cut', title = 'Fiber cut restoration', icon = 'scissors', color = '#2f6bff',
        sub = 'Emergency repair',
        steps = {
            { title = 'Locate the cut', how = { 'OTDR / visual fault locator' }, done = manual() },
            { title = 'Re-splice it', how = { 'Fusion splice back together — same technique as any other splice' }, done = anyRun('fibre') },
        },
    },
    {
        id = 'us_otdr', company = 'usosp', code = 'us_otdr', title = 'OTDR & power-meter acceptance test', icon = 'wave-square', color = '#2f6bff',
        sub = 'Sign off a new build',
        steps = { { title = 'Test and record the readings', how = { 'OTDR for length / breaks / open ends', 'Optical power meter for the dBm at the ONT / handoff' }, done = manual() } },
    },

    -- =====================================================================
    -- OPS America Network Ops
    -- =====================================================================
    {
        id = 'us_olt', company = 'usnet', code = 'us_olt', title = 'OLT installation', icon = 'server', color = '#2f6bff',
        sub = 'Central office optical line terminal',
        steps = {
            { title = 'Place the OLT', how = { 'Central office · optical & routing → OLT' }, done = placed('^opslabs_olt$') },
            { title = 'Patch it to the aggregation router', how = { 'Central office · optical & routing → Aggregation / core router' }, done = placed('^opslabs_core_router$') },
        },
    },
    {
        id = 'us_odf', company = 'usnet', code = 'us_odf', title = 'ODF installation & patching', icon = 'diagram-project', color = '#2f6bff',
        sub = 'Terminates outside-plant fiber to the OLT',
        steps = { { title = 'Place the ODF', how = { 'Central office · optical & routing → ODF (optical distribution frame)' }, done = placed('^opslabs_fdf$') } },
    },
    {
        id = 'us_agg', company = 'usnet', code = 'us_agg', title = 'Aggregation router turn-up', icon = 'network-wired', color = '#2f6bff',
        sub = 'Collects OLT traffic, backhauls to the core',
        steps = { { title = 'Place the aggregation router', how = { 'Central office · optical & routing' }, done = placed('^opslabs_core_router$') } },
    },
    {
        id = 'us_edge', company = 'usnet', code = 'us_edge', title = 'Internet edge / peering router', icon = 'network-wired', color = '#2f6bff',
        sub = 'BGP to transit & peering, subscriber IPs',
        steps = { { title = 'Place the edge router', how = { 'Same model as the aggregation router — a second one, in the edge / BGP role' }, done = placed('^opslabs_core_router$') } },
    },
    {
        id = 'us_bng', company = 'usnet', code = 'us_bng', title = 'BNG installation', icon = 'network-wired', color = '#2f6bff',
        sub = 'Broadband network gateway, subscriber sessions',
        steps = { { title = 'Place the BNG', how = { 'Central office · optical & routing' }, done = placed('^opslabs_core_router$') } },
    },
    {
        id = 'us_co_power', company = 'usnet', code = 'us_co_power', title = 'Central office power plant', icon = 'car-battery', color = '#2f6bff',
        sub = 'Rectifier, DC plant, batteries',
        steps = {
            { title = 'Fit the rectifier shelf', how = { 'Central office · power & HVAC → Rectifier shelf (-48 V DC)' }, done = placed('^opslabs_rectifier$') },
            { title = 'Fit the DC power plant', how = {}, done = placed('^opslabs_dc_power$') },
            { title = 'Fit the battery string', how = {}, done = placed('^opslabs_battery_bank$') },
        },
    },
    {
        id = 'us_hvac', company = 'usnet', code = 'us_hvac', title = 'Central office HVAC', icon = 'temperature-half', color = '#2f6bff',
        sub = 'Cooling for the equipment floor',
        steps = {
            { title = 'Fit the HVAC indoor unit', how = { 'Central office · power & HVAC' }, done = placed('^opslabs_crac$') },
            { title = 'Fit the outdoor condenser', how = {}, done = placed('^opslabs_condenser$') },
        },
    },
    {
        id = 'us_pon_alarm', company = 'usnet', code = 'us_pon_alarm', title = 'PON alarm — multiple ONTs offline', icon = 'triangle-exclamation', color = '#2f6bff',
        sub = 'OLT or upstream power problem',
        steps = { { title = 'Check the OLT and its power', how = { 'OLT online? Rectifier / DC plant / batteries all good?', 'ONT diagnostic tester on a sample of the affected ONTs' }, done = manual() } },
    },
}
local byId = {}
local byCompany = {}
for _, t in ipairs(TRACKS) do
    byId[t.id] = t
    byCompany[t.company] = byCompany[t.company] or {}
    table.insert(byCompany[t.company], t)
end

-- state ---------------------------------------------------------------------------------------------
local state = nil            -- { track = id, step = n, hidden = bool }
local offered = false

local function save()
    if state then SetResourceKvp(KVP_STATE, json.encode(state)) else DeleteResourceKvp(KVP_STATE) end
end

local function push(extra)
    if not state then return SendNUIMessage({ action = 'coach', show = false }) end
    local t = byId[state.track]
    local s = t.steps[state.step]
    SendNUIMessage({
        action = 'coach', show = not state.hidden,
        track = t.title, color = t.color, step = state.step, total = #t.steps,
        title = s and s.title or 'All done!', how = s and s.how or { 'Nice work — you finished “' .. t.title .. '”.', 'F7 to pick another guide' },
        finished = s == nil, flash = extra and extra.flash, key = 'F7',
    })
end

local function start(id)
    state = { track = id, step = 1 }
    save() push()
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

local function stop()
    state = nil save() push()
end

local function advance(to)
    local t = byId[state.track]
    local doneTitle = t.steps[state.step].title
    state.step = to + 1
    state.hidden = false
    save()
    push({ flash = doneTitle })
    if state.step > #t.steps then
        PlaySoundFrontend(-1, 'CHALLENGE_UNLOCKED', 'HUD_AWARDS', true)
        SetTimeout(9000, function() if state and state.step > #byId[state.track].steps then stop() end end)
    else
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    end
end

-- menus ---------------------------------------------------------------------------------------------
local function trackList(companyId)
    local tracks = byCompany[companyId] or {}
    local options = {}
    for _, t in ipairs(tracks) do
        options[#options + 1] = { title = t.title, description = t.sub .. (' · %d step%s'):format(#t.steps, #t.steps == 1 and '' or 's'), icon = t.icon, iconColor = t.color,
            onSelect = function() start(t.id) end }
    end
    lib.registerContext({ id = 'coach_tracks', title = 'Pick a job', menu = 'coach_choose', options = options })
    lib.showContext('coach_tracks')
end

local function chooser()
    local options = {}
    for _, c in ipairs(COMPANIES) do
        local n = #(byCompany[c.id] or {})
        if n > 0 then
            options[#options + 1] = { title = c.label, description = ('%d guide%s'):format(n, n == 1 and '' or 's'), icon = c.icon, iconColor = c.color, arrow = true,
                onSelect = function() trackList(c.id) end }
        end
    end
    options[#options + 1] = { title = 'Not now', icon = 'xmark', onSelect = function() end }
    options[#options + 1] = { title = 'Don’t offer this again', description = 'F7 still opens it whenever you want', icon = 'bell-slash',
        onSelect = function() SetResourceKvpInt(KVP_NOASK, 1) lib.notify({ description = 'OK — press F7 any time for the job guide' }) end }
    lib.registerContext({ id = 'coach_choose', root = true, title = 'Job guide — which company?', options = options })
    lib.showContext('coach_choose')
end

local function guideMenu()
    if not state then return chooser() end
    local t = byId[state.track]
    local options = {}
    for i, s in ipairs(t.steps) do
        local status = i < state.step and 'done' or i == state.step and 'now' or 'todo'
        options[#options + 1] = {
            title = ('%d. %s'):format(i, s.title), icon = status == 'done' and 'circle-check' or status == 'now' and 'circle-play' or 'circle',
            iconColor = status == 'done' and '#30d158' or status == 'now' and t.color or '#6b6b75',
            description = status == 'now' and (#s.how > 0 and table.concat(s.how, ' · ') or nil) or nil,
            onSelect = function() state.step = i save() push() guideMenu() end,   -- jump to any step
        }
    end
    options[#options + 1] = { title = 'Skip this step', icon = 'forward', disabled = state.step > #t.steps, onSelect = function() advance(state.step) guideMenu() end }
    options[#options + 1] = { title = state.hidden and 'Show the guide card' or 'Hide the guide card', description = 'It keeps tracking either way', icon = state.hidden and 'eye' or 'eye-slash',
        onSelect = function() state.hidden = not state.hidden save() push() end }
    options[#options + 1] = { title = 'Switch guide', icon = 'repeat', onSelect = chooser }
    options[#options + 1] = { title = 'Stop the guide', icon = 'xmark', iconColor = '#ff453a', onSelect = stop }
    lib.registerContext({ id = 'coach_menu', root = true, title = ('%s · step %d of %d'):format(t.title, math.min(state.step, #t.steps), #t.steps), options = options })
    lib.showContext('coach_menu')
end

RegisterCommand('poleguide', function() guideMenu() end, false)
RegisterKeyMapping('poleguide', 'Job guide (step by step)', 'keyboard', 'F7')
PoleGuideMenu = guideMenu

-- events --------------------------------------------------------------------------------------------
local OFFER_ON = { climb_pole = true, climb_ladder = true, ladder = true, pole_menu = true, fixture = true, box = true }

--- tell the coach something happened: Coach('climb_pole'), Coach('fixture', { model = … }), …
function Coach(event, data)
    data = data or {}
    if not state then
        if not offered and OFFER_ON[event] and GetResourceKvpInt(KVP_NOASK) ~= 1
            and (event ~= 'fixture' or (data.model or ''):find('pole')) then
            offered = true
            SendNUIMessage({ action = 'coachOffer', key = 'F7' })
        end
        return
    end
    local t = byId[state.track]
    -- the step after this one first (e.g. used a map pole and climbed it: both done), then the current one
    for i = math.min(state.step + 1, #t.steps), state.step, -1 do
        local s = t.steps[i]
        local ok, hit = pcall(s.done, event, data)
        if not (ok and hit) and s.alt then ok, hit = pcall(s.alt, event, data) end
        if ok and hit then return advance(i) end
    end
end

-- every successful server action this resource makes reports to the coach
local EVENTS = {
    ['opslabs-towers:fixture:save']     = function(r, args) if not args[1].id then return 'fixture', { model = r.fixture and r.fixture.model or args[1].model } end end,
    ['opslabs-towers:cable:placeBox']   = function(r) return 'box', r.box or {} end,
    ['opslabs-towers:cable:saveRun']    = function(r) return 'run', r.run or {} end,
    ['opslabs-towers:cable:terminate']  = function(r) return 'terminate', r.run or {} end,
    ['opslabs-towers:cable:split']      = function() return 'cut' end,
    ['opslabs-towers:cable:loose']      = function() return 'loose' end,
    ['opslabs-towers:ladder:place']     = function() return 'ladder' end,
    ['opslabs-towers:isp:provision']    = function() return 'provision' end,
    -- Wi-Fi / cell towers (Config.Wifi.Props - a different table from cabling fixtures, see towerAny() above)
    ['opslabs-towers:save']             = function(r, args) if not args[1] or not args[1].id then return 'tower', { model = r.tower and r.tower.model } end end,
    -- OPS Secure CCTV
    ['opslabs-towers:cctv:config']      = function(r, args) return 'cctvConfig', args[2] or {} end,
    ['opslabs-towers:cctv:repair']      = function() return 'cctvRepair' end,
    -- OPS Access
    ['opslabs-towers:access:link']      = function() return 'accessLink' end,
    ['opslabs-towers:access:issueCard'] = function() return 'accessIssueCard' end,
    -- OPS Data
    ['opslabs-towers:dc:install']       = function() return 'dcInstall' end,
    ['opslabs-towers:dc:repair']        = function() return 'dcRepair' end,
    -- OPS Track
    ['opslabs-towers:track:install']    = function() return 'trackInstall' end,
    -- OPS Fuel
    ['opslabs-towers:fuel:tankWork']    = function() return 'fuelFix' end,
    ['opslabs-towers:fuel:atgAct']      = function() return 'fuelFix' end,
}
local await = lib.callback.await
lib.callback.await = function(name, delay, ...)
    local r = await(name, delay, ...)
    local map = EVENTS[name]
    if map and type(r) == 'table' and r.ok then
        local args = { ... }
        local ok, ev, data = pcall(map, r, args)
        if ok and ev then CreateThread(function() Wait(300) Coach(ev, data) end) end
    end
    return r
end

CreateThread(function()
    Wait(2000)
    local raw = GetResourceKvpString(KVP_STATE)
    local ok, s = pcall(json.decode, raw or '')
    if ok and type(s) == 'table' and byId[s.track] and tonumber(s.step) then
        state = { track = s.track, step = math.floor(s.step), hidden = s.hidden == true }
        if state.step > #byId[state.track].steps then state = nil save() end
        push()
    end
end)
