-- Pole work coach: a step-by-step guide that watches what you do and tells you what's next.
-- Offered the first time you start pole work in a session (climb, ladder, pole kit); F7 opens it any time.
-- Progress is kept per player (KVP), so it carries on after a reconnect.

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

local TRACKS = {
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
local function chooser()
    local options = {}
    for _, t in ipairs(TRACKS) do
        options[#options + 1] = { title = t.title, description = t.sub .. (' · %d steps'):format(#t.steps), icon = t.icon, iconColor = t.color,
            onSelect = function() start(t.id) end }
    end
    options[#options + 1] = { title = 'Not now', icon = 'xmark', onSelect = function() end }
    options[#options + 1] = { title = 'Don’t offer this again', description = 'F7 still opens it whenever you want', icon = 'bell-slash',
        onSelect = function() SetResourceKvpInt(KVP_NOASK, 1) lib.notify({ description = 'OK — press F7 any time for the pole work guide' }) end }
    lib.registerContext({ id = 'coach_choose', root = true, title = 'Pole work guide — what are you doing?', options = options })
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
    lib.registerContext({ id = 'coach_menu', root = true, title = ('%s · step %d of %d'):format(t.title, math.min(state.step, #t.steps), #t.steps), options = options })
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
