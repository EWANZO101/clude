-- Pole work coach: a step-by-step guide that watches what you do and tells you what's next.
-- Offered the first time you start pole work in a session (climb, ladder, pole kit); F7 opens it any time.
-- Progress is kept per player (KVP), so it carries on after a reconnect.

local CC = Config.Cabling
local CF = Config.Faults or {}
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

-- does a run (cable / fibre) start or end on a fixture whose model matches the pattern?
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
local function copperTo(pattern) return function(e, d) return (e == 'run' or e == 'terminate') and d.kind == 'copper' and runTouches(d, pattern) end end

local TRACKS = {
    {
        id = 'openline_scratch', title = 'Build OPS Openline — from scratch', icon = 'network-wired', color = '#0a84ff',
        sub = 'Exchange → OLT & MDF → spine fibre/copper → street cabinet → hand off to a customer',
        steps = {
            { title = 'Build the telephone exchange',
              how = { '/towers → Buildings & sites → Buildings → Telephone exchange building (walk-in)', '16 × 10 m — racks, power plant & switching go inside' },
              done = placed('^opslabs_exchange_building$') },
            { title = 'Fit the OLT — lights the fibre network',
              how = { 'Inside the exchange: OPS Openline → Exchange network kit → Optical line terminal (OLT)' },
              done = placed('^opslabs_olt$') },
            { title = 'Fit the MDF — where every copper line starts',
              how = { 'Exchange network kit → Main distribution frame (MDF)' },
              done = placed('^opslabs_mdf$') },
            { title = 'Power and cool the exchange',
              how = { 'Exchange power & cooling: DC rectifier rack + battery bank at minimum', 'A generator and HVAC (CRAC + condenser) keep it running and cool long-term' },
              done = placed('^opslabs_rectifier$'),
              alt = function(e, d) return placed('^opslabs_battery_bank$')(e, d) or placed('^opslabs_dc_power$')(e, d) or placed('^opslabs_generator$')(e, d) end },
            { title = 'Place a street cabinet out in the area you’re serving',
              how = { 'Street cabinets & chambers → Street cabinet (PCP)', 'This is where the exchange’s fibre and copper fan out to the neighbourhood' },
              done = placed('^opslabs_cabinet_pcp$') },
            { title = 'Feed the cabinet from the exchange',
              how = { 'Pull fibre (spine feed) from the OLT / ODF to the cabinet for FTTP/FTTC', 'Or run phone cable (copper) from the MDF to the cabinet for copper lines — do either or both' },
              done = fibreTo('^opslabs_cabinet_'), alt = copperTo('^opslabs_cabinet_') },
            { title = 'Carry it on to a pole',
              how = { 'Climb a pole near the cabinet and fit a CBT ([G] → Mount: CBT) for fibre', 'Or fit a copper DP / pole-mounted splice box for a copper line' },
              done = placed('^opslabs_cbt'),
              alt = function(e, d) return placed('^opslabs_copper_dp$')(e, d) or placed('^opslabs_pole_splice_box$')(e, d) end },
            { title = 'Finish at the customer',
              how = { 'Press F7 → Switch guide → “Fibre to a house” for an FTTP customer', 'Or → “Copper phone line” to finish a copper drop and get a dial tone' },
              done = function(e) return e == 'provision' end },
        },
    },
    {
        id = 'copper', title = 'Copper phone line', icon = 'phone', color = '#bf5af2',
        sub = 'Exchange MDF → PCP cabinet → DP or aerial joint on the pole → drop wire → master socket',
        steps = {
            { title = 'Find or place a telegraph pole',
              how = { 'Any telegraph pole on the map works', 'Or /towers → OPS Openline → Telecom equipment → Poles & fixings' },
              done = function(e, d) return placed('^opslabs_pole_%d+m$')(e, d) or e == 'climb_pole' or e == 'ladder' end },
            { title = 'Get up the pole',
              how = { 'Walk up to it and press [E] to climb', 'Or stand a ladder against it (/ladder) and climb that' },
              done = function(e) return e == 'climb_pole' or e == 'climb_ladder' end },
            { title = 'Fit a copper DP or pole-mounted splice box',
              how = { 'On the pole (or ladder) press [G]', 'Copper phone line → DP box (distribution point), or pole-mounted splice box' },
              done = placed('^opslabs_copper_dp$'), alt = placed('^opslabs_pole_splice_box$') },
            { title = 'Feed it with copper from the cabinet or MDF',
              how = { '/towers → OPS Openline → Run phone cable (copper)', 'From the PCP street cabinet (or further back, straight off the MDF)', 'Clip it up the poles and finish on the DP / splice box' },
              done = copperTo('^opslabs_copper_dp$'), alt = copperTo('^opslabs_pole_splice_box$') },
            { title = 'Fit a house pole or anchor on the house',
              how = { 'No house? /towers → Buildings & sites → Customer house', 'Then OPS Openline → Telecom equipment → Poles & fixings → House pole', 'or Customer premises · outside → Anchor eyebolt' },
              done = placed('^opslabs_house_pole$'), alt = placed('^opslabs_wall_anchor$') },
            { title = 'Drill the entry hole and fit the bushing',
              how = { 'Tool kit → Cordless drill, aimed at the outside wall', 'Fits the brickwork entry bushing the drop wire comes in through' },
              done = placed('^opslabs_entry_bushing$') },
            { title = 'Fit the master socket (NTE5C) inside',
              how = { 'Telecom equipment → Copper phone line → Master socket (NTE5C)', 'Place it on an inside wall near where the phone / router sits' },
              done = placed('^opslabs_nte5c$') },
            { title = 'Run the copper drop from the DP to the master socket',
              how = { 'Pull phone cable from the DP / splice box', 'Through the bushing and finish on the NTE5C' },
              done = copperTo('^opslabs_nte5c$') },
            { title = 'Provision the line',
              how = { '/towers → Tools → Nearby equipment → the master socket', 'Pick “Provision internet service”, choose a copper / VDSL plan', 'CS can also do it on the website (Admin → Internet service)' },
              done = function(e) return e == 'provision' end },
        },
    },
    {
        id = 'fibre', title = 'Fibre to a house', icon = 'house-signal', color = '#30d158',
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
        id = 'underground', title = 'Underground fibre run', icon = 'road', color = '#5e5ce6',
        sub = 'Dig a chamber, lay duct, pull fibre through, bring it up to a pole or cabinet',
        steps = {
            { title = 'Dig an underground chamber',
              how = { '/towers → Buildings & sites → Underground chambers & tunnels', 'Underground chamber — its access hatch opens with [E]' },
              done = placed('^opslabs_ug_chamber') },
            { title = 'Climb down and lay the duct run',
              how = { 'At the open hatch press [F] to climb down', 'Face an open end (or a wall, to branch off) and lay tunnel sections to the next chamber' },
              done = placed('^opslabs_ug_tunnel') },
            { title = 'Bring it up with a riser',
              how = { 'In a chamber or at a tunnel end, fit a riser pipe', 'Goose-neck riser to come up a pole, flush riser to come up inside a cabinet' },
              done = placed('^opslabs_ug_riser') },
            { title = 'Fit an underground joint',
              how = { 'In the chamber, fit a U-CBT (underground joint)', 'This is where the duct fibre splices onward' },
              done = placed('^opslabs_ucbt') },
            { title = 'Pull fibre through the duct',
              how = { 'Pull cable from a drum at one chamber (/towers → OPS Openline → Pull cable)', 'Run it through the tunnel and finish on the U-CBT or the riser' },
              done = function(e, d) return fibreTo('^opslabs_ucbt')(e, d) or fibreTo('^opslabs_ug_riser')(e, d) end },
            { title = 'Carry on above ground',
              how = { 'At the top of the riser, fit a CBT the same as an overhead run', 'Press F7 → Switch guide → “Fibre to a house” to finish at the CSP and ONT' },
              done = placed('^opslabs_cbt') },
        },
    },
    {
        id = 'basics', title = 'Pole & ladder basics', icon = 'person-arrow-up-from-line', color = '#0a84ff',
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
        id = 'grid', title = 'Build the power grid — from scratch', icon = 'industry', color = '#ff9f0a',
        sub = 'Generation → transmission → substation → feeders → pole transformers',
        steps = {
            { title = 'Build a power station (or a wind turbine)',
              how = { '/towers → San Andreas Power & Light → Generation', 'Gas power station (4 × 120 MW) or wind turbine (3 MW)' },
              done = placed('^opslabs_grid_station'), alt = placed('^opslabs_grid_wind') },
            { title = 'Put up a transmission pylon',
              how = { 'Generation → Transmission → 400 kV lattice pylon', 'Walk a line of them out towards where the substation will go' },
              done = placed('^opslabs_grid_pylon') },
            { title = 'Run 400 kV transmission conductor',
              how = { 'Run power cable → pick 400 kV / transmission', 'From the station’s gantry, over the pylons, into the substation' },
              done = function(e, d) return e == 'run' and d.kind == 'power' and d.color == 'transmission' end },
            { title = 'Build a substation',
              how = { 'Substations → Primary substation 400/11 kV', 'Or an empty/fully-fitted substation building, or an RTU telemetry pole on any building' },
              done = placed('^opslabs_grid_substation'),
              alt = function(e, d) return placed('^opslabs_grid_subbuilding')(e, d) or placed('^opslabs_grid_subshell')(e, d) or placed('^opslabs_grid_rtu')(e, d) end },
            { title = 'Fit out the substation plant',
              how = { 'Substation plant category, placed inside', 'Required to energise it: transformer, 400 kV GIS incomer, 11 kV switchgear, busbars, protection relay, earth bar, 110 V DC battery & charger',
                      'Metering panel, control desk (SCADA) and HV cable sealing ends are optional extras' },
              done = placed('^opslabs_sub_') },
            { title = 'Run 11 kV (HV) conductor out of the substation',
              how = { 'Run power cable → pick 11 kV / HV', 'Out of the substation yard, pole to pole', 'You don’t need to climb for this — aim at each pole (up to 40 m away) and the cable clamps on by itself' },
              done = function(e, d) return e == 'run' and d.kind == 'power' and d.color == 'hv' end },
            { title = 'Climb the pole (or use a ladder) to fit kit',
              how = { 'Fitting a transformer or recloser needs you up the pole: walk up to it and press [E] to climb',
                      'Or stand a ladder against it (/ladder) and climb that — a 13 m ladder reaches a power pole’s pegs', 'Then press [G] for the pole menu' },
              done = function(e) return e == 'climb_pole' or e == 'climb_ladder' end },
            { title = 'Fit a pole transformer where homes need supply',
              how = { '[G] on the pole → “Mount: Pole-mounted transformer”' },
              done = placed('^opslabs_power_transformer') },
            { title = 'Split the feeder with a recloser',
              how = { '[G] on a pole along the feeder → “Mount: Pole-mounted auto-recloser (PMAR)”', 'A fault past it only cuts customers past it, not the whole feeder' },
              done = placed('^opslabs_power_recloser') },
            { title = 'Finish the pole: cut-outs and safety',
              how = { 'Press F7 → Switch guide → “Power line” to finish the fuses and safety signage', 'LV / service drops to houses carry on from Mains' },
              done = placed('^opslabs_power_cutouts') },
        },
    },
    {
        id = 'power', title = 'Power line', icon = 'bolt', color = '#ffd60a',
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
    {
        id = 'fault_fix', title = 'Fix a network fault', icon = 'bolt-lightning', color = '#ff9500',
        sub = 'Find a reported fault, diagnose it and carry out the repair',
        steps = {
            { title = 'Go to an open fault and diagnose it',
              how = { 'A red marker flashes over every open fault nearby', ('Press [%s] at it — or /cable → Network faults → Repair it'):format(CF.RepairKey or 'U'), 'The diagnosis explains what’s wrong and why' },
              done = function(e) return e == 'fault_diagnose' end },
            { title = 'Follow the fix checklist and repair it',
              how = { 'Tick off each listed step as you do it, and have the tools listed', 'At height: clip your harness on first', 'Then pick “Start repair”' },
              done = function(e) return e == 'fault_repair' end },
        },
    },
    {
        id = 'power_fix', title = 'Fix a power problem', icon = 'bolt', color = '#ffd60a',
        sub = 'Trace a power fault back to the station, fix what you can, confirm it’s back',
        steps = {
            { title = 'Test the supply with the power fault finder',
              how = { '/powercheck at the dead kit — or Tool kit → Electrical tools → Power fault finder', 'It traces the supply back to the power station and lists every cause' },
              done = function(e) return e == 'power_test' end },
            { title = 'Fix what you can',
              how = { 'Power repair tool fixes everything wrong at that kit and its supply in one go', 'Or work through the fault finder’s results with the restoration kit — upstream causes first', 'Some causes need building work before they can be fixed' },
              done = function(e) return e == 'power_fixed' end, alt = function(e) return e == 'grid_repair' end },
            { title = 'Confirm the supply is back',
              how = { 'Test again with the power fault finder', 'POWERED with no causes left means you’re done' },
              done = function(e, d) return e == 'power_test' and d and d.powered == true end },
        },
    },
}
local byId = {}
for _, t in ipairs(TRACKS) do byId[t.id] = t end

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
--- up a pole or ladder: force the small menu (the big console panel steals focus mid-climb) and pause climbing
--- movement while the guide is open, the same way faults.lua and harness.lua already do around their own menus
local function onClimb() return PoleClimb ~= nil or LadderClimb ~= nil end
local function climbMenuOpen() if onClimb() then ForceClassicMenus = true ClimbPaused = true end end
local function climbMenuClosed() ClimbPaused = false end

local function chooser()
    local options = {}
    for _, t in ipairs(TRACKS) do
        options[#options + 1] = { title = t.title, description = t.sub .. (' · %d steps'):format(#t.steps), icon = t.icon, iconColor = t.color,
            onSelect = function() start(t.id) end }
    end
    options[#options + 1] = { title = 'Not now', icon = 'xmark', onSelect = function() end }
    options[#options + 1] = { title = 'Don’t offer this again', description = 'F7 still opens it whenever you want', icon = 'bell-slash',
        onSelect = function() SetResourceKvpInt(KVP_NOASK, 1) lib.notify({ description = 'OK — press F7 any time for the pole work guide' }) end }
    climbMenuOpen()
    lib.registerContext({ id = 'coach_choose', root = true, title = 'Pole work guide — what are you doing?', options = options, onExit = climbMenuClosed })
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
            description = status == 'now' and table.concat(s.how, ' · ') or nil,
            onSelect = function() state.step = i save() push() guideMenu() end,   -- jump to any step
        }
    end
    options[#options + 1] = { title = 'Skip this step', icon = 'forward', disabled = state.step > #t.steps, onSelect = function() advance(state.step) guideMenu() end }
    options[#options + 1] = { title = state.hidden and 'Show the guide card' or 'Hide the guide card', description = 'It keeps tracking either way', icon = state.hidden and 'eye' or 'eye-slash',
        onSelect = function() state.hidden = not state.hidden save() push() end }
    options[#options + 1] = { title = 'Switch guide', icon = 'repeat', onSelect = chooser }
    options[#options + 1] = { title = 'Stop the guide', icon = 'xmark', iconColor = '#ff453a', onSelect = stop }
    climbMenuOpen()
    lib.registerContext({ id = 'coach_menu', root = true, title = ('%s · step %d of %d'):format(t.title, math.min(state.step, #t.steps), #t.steps), options = options, onExit = climbMenuClosed })
    lib.showContext('coach_menu')
end

RegisterCommand('poleguide', function() guideMenu() end, false)
RegisterKeyMapping('poleguide', 'Pole work guide (step by step)', 'keyboard', 'F7')
PoleGuideMenu = guideMenu

-- events --------------------------------------------------------------------------------------------
local OFFER_ON = { climb_pole = true, climb_ladder = true, ladder = true, pole_menu = true, fixture = true, box = true }

--- tell the coach something happened: Coach('climb_pole'), Coach('fixture', { model = … }), …
function Coach(event, data)
    data = data or {}
    if not state then
        if not offered and OFFER_ON[event] and GetResourceKvpInt(KVP_NOASK) ~= 1
            and (event ~= 'fixture' or (data.model or ''):find('pole') or (data.model or ''):find('^opslabs_ug_')) then
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
    ['opslabs-towers:faults:diagnose']  = function(r) if r.ok then return 'fault_diagnose', r.fault or {} end end,
    ['opslabs-towers:faults:repair']    = function(r) if r.ok then return 'fault_repair', {} end end,
    ['opslabs-towers:powerdiag:test']   = function(r) if not r.error then return 'power_test', r end end,
    ['opslabs-towers:powerdiag:fix']    = function(r) if not r.error then return 'power_fixed', r end end,
    ['opslabs-towers:grid:repair']      = function(r) if r.ok then return 'grid_repair', r end end,
}
local await = lib.callback.await
lib.callback.await = function(name, delay, ...)
    local r = await(name, delay, ...)
    local map = EVENTS[name]
    -- success here is ".ok = true" for most of these callbacks, but opslabs-towers:powerdiag:test/fix
    -- signal it by the absence of ".error" instead and never set .ok at all — r.ok ~= false still
    -- excludes every real failure (they all set .ok = false or .error, never neither)
    if map and type(r) == 'table' and r.ok ~= false and not r.error then
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
