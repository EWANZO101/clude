-- Engineer tool kits: OPS Openline fibre tools and San Andreas Power & Light electrical tools.
-- Each tool works on what is around you (joints, fibre runs, ONTs, chambers, poles, power poles, power cable).
-- Open from the van stores, /towers → Tools → Tool kit, or /toolkit.

local CC = Config.Cabling
local PPE = { harness = false, gloves = false, insulated = false, arc = false }
local Power = {}            -- [poleId] = { fusesOut, earthed }
local prepped, cleaned = false, {}

RegisterNetEvent('opslabs-towers:power', function(id, s) Power[id] = s end)
CreateThread(function()
    Wait(2000)
    for id, s in pairs(lib.callback.await('opslabs-towers:power:states', false) or {}) do Power[tonumber(id)] = s end
end)

--- is the climber wearing a harness (poles.lua warns when not)
function HarnessOn() return PPE.harness end
function HarnessSet(on) PPE.harness = on == true end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function pos() return GetEntityCoords(PlayerPedId()) end

local function nearestFixture(match, maxDist)
    local p, best, bd = pos(), nil, nil
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if match(f.model) then
            local d = #(p - vector3(f.x, f.y, f.z))
            if d < (bd or maxDist) then best, bd = f, d end
        end
    end
    return best, bd
end

local function find(patterns) return function(m) for _, pat in ipairs(patterns) do if m:find(pat) then return true end end return false end end

local function segDist(p, a, b)
    local ab, ap = b - a, p - a
    local L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
    local t = L2 > 0 and math.max(0.0, math.min(1.0, (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / L2)) or 0.0
    return #(p - (a + ab * t)), t
end

local function nearestRun(kind, maxDist)
    local p, best, bd = pos(), nil, nil
    for _, r in pairs(CablingRuns and CablingRuns() or {}) do
        if r.kind == kind then
            local pts = r.points or {}
            for i = 1, #pts - 1 do
                local d = segDist(p, vector3(pts[i].x, pts[i].y, pts[i].z), vector3(pts[i + 1].x, pts[i + 1].y, pts[i + 1].z))
                if d < (bd or maxDist) then best, bd = r, d end
            end
        end
    end
    return best, bd
end

local function nearestPole(maxDist)
    local p, best, bd = pos(), nil, nil
    for _, pl in ipairs(AllPoles and AllPoles() or {}) do
        if not pl.house then
            local d = #(vector2(p.x, p.y) - vector2(pl.x, pl.y))
            if d < (bd or maxDist) and p.z > pl.z - 2.0 and p.z < pl.z + pl.H + 2.0 then best, bd = pl, d end
        end
    end
    return best, bd
end

local function powerPole(maxDist) return nearestFixture(function(m) return m:find('^opslabs_power_pole') ~= nil end, maxDist) end

--- deterministic "random" per thing, so the same pole always tests the same
local function roll(seed, n)
    local h = 7
    for c in tostring(seed):gmatch('.') do h = (h * 131 + c:byte()) % 1000003 end
    return h % n
end

local ANIM = {
    kneel = { dict = 'amb@medic@standing@kneel@base', clip = 'base' },
    hands = { dict = 'mini@repair', clip = 'fixing_a_ped' },
    tablet = { dict = 'amb@world_human_seat_wall_tablet@female@base', clip = 'base' },
    hammer = { dict = 'amb@world_human_hammering@male@base', clip = 'base' },
    weld = { dict = 'amb@world_human_welding@male@base', clip = 'base' },
    up = { dict = 'amb@prop_human_movie_bulb@base', clip = 'base' },
}
local PROP = {
    tablet = { model = 'prop_cs_tablet', bone = 60309, pos = vec3(0.03, 0.002, -0.0), rot = vec3(10.0, 160.0, 0.0) },
    hammer = { model = 'prop_tool_hammer', bone = 57005, pos = vec3(0.1, 0.0, -0.02), rot = vec3(-80.0, 0.0, 0.0) },
    torch = { model = 'prop_cs_police_torch', bone = 57005, pos = vec3(0.12, 0.03, -0.02), rot = vec3(-90.0, 0.0, 0.0) },
    meter = { model = 'prop_cs_hand_radio', bone = 57005, pos = vec3(0.14, 0.03, -0.02), rot = vec3(-110.0, 0.0, 0.0) },
    pliers = { model = 'prop_tool_pliers', bone = 57005, pos = vec3(0.12, 0.02, -0.02), rot = vec3(-90.0, 0.0, 0.0) },
    stick = { model = 'prop_tool_broom', bone = 57005, pos = vec3(0.1, 0.0, -0.05), rot = vec3(-70.0, 0.0, 0.0) },
    buttset = { model = 'opslabs_tool_buttset', bone = 57005, pos = vec3(0.12, 0.02, -0.02), rot = vec3(-90.0, 0.0, 0.0) },
    drill = { model = 'hei_prop_heist_drill', bone = 57005, pos = vec3(0.14, 0.0, -0.03), rot = vec3(-90.0, 0.0, 0.0) },
    toner = { model = 'opslabs_tool_toner', bone = 57005, pos = vec3(0.1, 0.02, -0.02), rot = vec3(-90.0, 0.0, 0.0) },
}
-- hand props from opslabs-props fall back to a base-game one when it isn't streamed
for _, k in ipairs({ 'buttset', 'toner', 'drill' }) do
    if not IsModelInCdimage(joaat(PROP[k].model)) then PROP[k].model = k == 'buttset' and 'prop_cs_hand_radio' or k == 'drill' and 'prop_tool_pliers' or 'prop_cs_police_torch' end
end

local function work(label, ms, anim, prop)
    return lib.progressBar({ duration = ms, label = label, canCancel = true, disable = { move = true, combat = true, car = true },
        anim = anim and ANIM[anim] or nil, prop = prop and PROP[prop] or nil })
end

local function result(header, lines)
    lib.alertDialog({ header = header, content = table.concat(lines, '  \n'), centered = true })
end

local function need(thing, where)
    lib.notify({ type = 'error', description = ('No %s within reach — %s'):format(thing, where) })
end

---------------------------------------------------------------------------
-- OPS Openline fibre tools
---------------------------------------------------------------------------
local JOINTS = find({ '^opslabs_cbt', '^opslabs_alt_cbt', '^opslabs_joint_tophat', '^opslabs_splice_enclosure', '^opslabs_track_joint', '^opslabs_ucbt',
    '^opslabs_base_node', '^opslabs_csp', '^opslabs_splice_tray', '^opslabs_footway_box', '^opslabs_cabinet_pcp', '^opslabs_pole_splice_box', '^opslabs_fdf', '^opslabs_hof' })
local CHAMBERS = find({ '^opslabs_manhole', '^opslabs_chamber_modular', '^opslabs_footway_box', '^opslabs_carriageway_cover' })

local function splicer()
    local j = nearestFixture(JOINTS, 3.0)
    if not j then return need('joint, CBT or CSP', 'stand at the enclosure you are splicing in') end
    if not work('Stripping, cleaving and loading the fibres', 5000, 'kneel') then return end
    local ok = lib.skillCheck({ 'easy', 'medium' }, { 'e' })
    if not work('Arc fusing', 3000, 'weld') then return end
    local loss = ok and (prepped and 0.01 + roll(GetGameTimer(), 3) / 100 or 0.02 + roll(GetGameTimer(), 5) / 100) or 0.28 + roll(GetGameTimer(), 10) / 100
    prepped = false
    result('Fusion splicer · ' .. equipLabelFor(j.model), {
        ('**Estimated splice loss: %.2f dB**'):format(loss),
        loss < 0.1 and 'Good splice — protect it with a sleeve and store it in the tray.' or 'Too lossy — cut it out and splice again (prep the fibre with the strippers first).',
    })
end

local function otdr()
    local r, d = nearestRun('fibre', 6.0)
    if not r then return need('fibre', 'stand by the fibre you want to test') end
    if not work('Connecting the launch lead and shooting the fibre', 6000, 'tablet', 'tablet') then return end
    local pts = r.points or {}
    local here = pos()
    local fromStart = #(here - vector3(pts[1].x, pts[1].y, pts[1].z)) <= #(here - vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z))
    local len = r.length or 0
    local lines = { ('**Fibre #%d · %s · %.0f m**'):format(r.id, (CC.FibreLabels or {})[r.color] or r.color or '', len), '0 m — launch connector' }
    local far = fromStart and 'end' or 'start'
    local near = fromStart and 'start' or 'end'
    if r.loose and r.loose[near] then lines[#lines + 1] = '0 m — **BREAK** right at this end (cut / loose)' end
    if r.loose and r.loose[far] then
        lines[#lines + 1] = ('%.0f m — **BREAK** · reflective spike, then nothing (cut / loose end)'):format(len)
    elseif not (fromStart and r.end_fixture or (not fromStart) and r.start_fixture) then
        lines[#lines + 1] = ('%.0f m — open end (not terminated)'):format(len)
    else
        lines[#lines + 1] = ('%.0f m — connector at %s'):format(len, equipLabelFor((CablingFixtures()[fromStart and r.end_fixture or r.start_fixture] or {}).model or '?'))
    end
    lines[#lines + 1] = ('Fibre loss %.2f dB (0.35 dB/km at 1310 nm)'):format(len / 1000 * 0.35)
    result('OTDR trace', lines)
end

local vflUntil = 0
local function vfl()
    if not work('Clipping the red laser on the fibre', 1500, 'hands', 'torch') then return end
    vflUntil = GetGameTimer() + 30000
    lib.notify({ description = 'Red light on for 30 s — breaks and open ends glow red' })
    CreateThread(function()
        while GetGameTimer() < vflUntil do
            local here = pos()
            for _, r in pairs(CablingRuns and CablingRuns() or {}) do
                if r.kind == 'fibre' then
                    local spots = {}
                    for _, which in ipairs({ 'start', 'end' }) do
                        if r.loose and r.loose[which] and LoosePath then
                            local _, tip = LoosePath(r, which)
                            if tip then spots[#spots + 1] = tip end
                        end
                    end
                    local pts = r.points or {}
                    if #pts > 1 and not r.end_fixture and not (r.loose and r.loose['end']) then spots[#spots + 1] = vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z) end
                    for _, p in ipairs(spots) do
                        if #(here - p) < 60.0 then
                            DrawLightWithRange(p.x, p.y, p.z + 0.05, 255, 20, 20, 1.2, 6.0)
                            DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.05, 0.05, 0.05, 255, 30, 30, 220, false, false, 2, false, nil, nil, false)
                        end
                    end
                end
            end
            Wait(0)
        end
    end)
end

local function nearestOntId(maxDist)
    local f = nearestFixture(function(m) return m == ((Config.Isp or {}).Ont or 'opslabs_ont') end, maxDist)
    return f and f.id, f
end

local function powerMeter()
    local id = nearestOntId(2.5)
    if not id then return need('ONT', 'plug into the ONT you are testing') end
    if not work('Reading the light level', 3000, 'hands', 'meter') then return end
    local o = OntReading and OntReading(id) or {}
    if not o.rx then return result('Optical power meter', { '**LOS — no light**', 'Nothing arriving from the exchange. Check the path with the OTDR / red light.' }) end
    local rx = o.rx + (cleaned[id] and 0.3 or 0.0)
    result('Optical power meter', {
        ('**%.1f dBm** at 1490 nm'):format(rx),
        (rx > -27 and rx < -8) and 'Within range (−8 to −27 dBm).' or 'Out of range — clean the connectors and check the splices.',
        ('Path %d m · %d joint(s)'):format(o.distance or 0, o.joints or 0),
    })
end

--- ONT diagnostics: read the five lights (POWER · PON · LOS · LAN · INTERNET), say what's wrong and how to fix it
local LED = { on = { 'On', '#30d158' }, off = { 'Off', '#8e8e93' }, blink = { 'Flashing', '#ff9f0a' }, red = { 'Red', '#ff453a' }, traffic = { 'Flickering (traffic)', '#30d158' } }

local function ontDiagnose(f)
    local o = OntReading and OntReading(f.id) or {}
    local failed = o.hardware == 'failed'
    local fibre, spliced = nil, false
    for _, r in pairs(CablingRuns and CablingRuns() or {}) do
        if r.kind == 'fibre' and (r.start_fixture == f.id or r.end_fixture == f.id) then
            fibre = r
            if (r.start_fixture == f.id and r.start_term) or (r.end_fixture == f.id and r.end_term) then spliced = true end
        end
    end
    local leds = {
        { 'POWER', failed and 'off' or 'on' },
        { 'PON', o.pon or 'off' },
        { 'LOS', o.los and 'red' or 'off' },
        { 'LAN', o.lan or 'off' },
        { 'INTERNET', o.internet or 'off' },
    }
    local title, steps, ok
    if failed then
        title = 'POWER off — the ONT has failed'
        steps = { 'Check the ONT power supply is plugged in and switched on', 'If it still won't power up the ONT itself is dead', 'Swap the ONT (repair the fault with the repair key at the ONT) and re-provision it' }
    elseif o.los then
        if not fibre then
            title = 'LOS — no fibre connected to this ONT'
            steps = { 'Run fibre (yellow patch / drop) from the CSP or splice tray to the ONT', 'Splice it into the ONT', 'Test again — PON should flash, then go solid' }
        elseif not spliced then
            title = 'LOS — the fibre at the ONT isn't spliced'
            steps = { ('Fibre #%d reaches the ONT but the end isn't finished'):format(fibre.id), 'Strip, clean, cleave and splice it into the ONT (Nearby cables → that fibre → Splice the end)', 'Test again' }
        elseif o.lowLight then
            title = 'LOS — light is too weak (below −28 dBm)'
            steps = { 'Too much loss on the path: too many splitters / joints or a bad splice', 'Clean the connectors at the ONT and CSP (one-click cleaner)', 'Find the bad joint with the OTDR and re-splice it' }
        else
            title = 'LOS — no light reaching the ONT'
            steps = { 'The fibre is broken or not spliced somewhere between the cabinet / OLT and here', 'Shine the red light (VFL) and walk the route — breaks and open ends glow', 'Check the joints with the OTDR, re-splice the break', 'At the exchange: is the OLT patched to a powered core router with its uplink up?' }
        end
    elseif o.pon == 'blink' then
        title = 'PON flashing — registering with the OLT'
        steps = { 'Light is arriving and the ONT is ranging with the OLT', 'Wait about 20 seconds — PON goes solid when it's registered' }
    elseif o.service == 'none' or o.internet == 'off' and o.service ~= 'active' then
        title = 'No service on this line'
        steps = { 'The fibre is good (PON solid) but no broadband is provisioned', 'Open the ONT (Tools → Nearby equipment) → Internet service → pick a provider & plan' }
    elseif o.service == 'suspended' or o.internet == 'red' then
        title = 'INTERNET red — service suspended by the provider'
        steps = { 'The line is fine; the provider has suspended the account', 'Resume it from the ONT's Internet service menu (or the provider's admin)' }
    elseif o.internet == 'blink' then
        title = 'INTERNET flashing — PPP login in progress'
        steps = { 'Wait a few seconds for the login to finish' }
    elseif o.lan == 'off' then
        title = 'LAN off — no router plugged into the ONT'
        steps = { 'Internet is up at the ONT but nothing is connected to its LAN port', 'Pull CAT6 from the ONT to the customer's router and terminate both ends (RJ45)', 'The LAN light comes on — it flickers once traffic flows' }
        ok = 'Internet is live at the ONT'
    else
        title = 'All good — the line is healthy'
        steps = { ('%s · %s · %d / %d Mbps'):format(o.provider or '?', o.plan or '?', o.down or 0, o.up or 0), o.lanName and ('Router on the LAN port: ' .. o.lanName) or 'Router connected' }
        ok = true
    end
    local options = {}
    for _, l in ipairs(leds) do
        local st = LED[l[2]] or LED.off
        options[#options + 1] = { title = ('%s · %s'):format(l[1], st[1]), icon = 'circle', iconColor = st[2], readOnly = true }
    end
    options[#options + 1] = { title = ('Light level %s'):format(o.rx and ('%.1f dBm'):format(o.rx) or '— (no light)'),
        description = o.distance and ('%d m of fibre · %d joint(s) back to the OLT'):format(o.distance, o.joints or 0) or nil, icon = 'gauge', readOnly = true }
    options[#options + 1] = { title = title, description = table.concat(steps, '  ·  '), icon = ok == true and 'circle-check' or 'stethoscope',
        iconColor = ok == true and '#30d158' or ok and '#ff9f0a' or '#ff453a', onSelect = function()
            local lines = {}
            for i, st in ipairs(steps) do lines[#lines + 1] = ('%d. %s'):format(i, st) end
            lib.alertDialog({ header = title, content = table.concat(lines, '  \n'), centered = true })
            ontDiagnose(f)
        end }
    options[#options + 1] = { title = 'Test again', icon = 'rotate', onSelect = function() if work('Re-testing the line', 2500, 'tablet', 'tablet') then ontDiagnose(f) end end }
    lib.registerContext({ id = 'ont_diag', title = 'ONT diagnostics · ' .. (o.serial or ('#' .. f.id)), options = options })
    lib.showContext('ont_diag')
end

local function ontTester()
    local id, f = nearestOntId(3.0)
    if not id then return need('ONT', 'plug the tester into the ONT you are diagnosing') end
    if not work('Plugging the diagnostic tester into the ONT', 3000, 'tablet', 'tablet') then return end
    ontDiagnose(f)
end
OntDiagnostics = ontTester

local function strippers()
    if not work('Stripping the jacket and cutting back the Kevlar', 4000, 'hands', 'pliers') then return end
    prepped = true
    lib.notify({ type = 'success', description = 'Fibre prepped — your next splice will be cleaner' })
end

local function cleaner()
    local f = nearestFixture(find({ '^opslabs_cbt', '^opslabs_alt_cbt', '^opslabs_ont', '^opslabs_csp' }), 2.5)
    if not f then return need('CBT port, CSP or ONT', 'stand at the port you want to clean') end
    if not work('One-click cleaning the connector', 2000, 'hands') then return end
    cleaned[f.id] = true
    lib.notify({ type = 'success', description = 'Connector cleaned — ' .. equipLabelFor(f.model) })
end

local function gasCheck()
    local f = nearestFixture(CHAMBERS, 3.0)
    if not f then return need('chamber or manhole', 'stand at the cover') end
    if not work('Lifting the cover with the keys', 4000, 'kneel') then return end
    if not work('Gas detector: sampling the chamber', 3000, 'hands', 'meter') then return end
    local bad = roll(f.id .. ':' .. math.floor(GetCloudTimeAsInt() / 3600), 10) == 0
    result('Gas detector · ' .. equipLabelFor(f.model), {
        bad and '**ALARM — CO 38 ppm**' or '**Clear**',
        ('O₂ %.1f %% · LEL 0 %% · H₂S 0 ppm · CO %d ppm'):format(bad and 19.8 or 20.9, bad and 38 or 0),
        bad and 'Do not enter — ventilate the chamber and test again.' or 'Safe to work in the chamber.',
    })
end

local function ductRods()
    local f = nearestFixture(CHAMBERS, 3.0)
    if not f then return need('chamber', 'rod from an open chamber') end
    if not work('Pushing the duct rods through', 9000, 'kneel') then return end
    local best, bd
    for _, g in pairs(CablingFixtures()) do
        if g.id ~= f.id and CHAMBERS(g.model) then
            local d = #(vector3(f.x, f.y, f.z) - vector3(g.x, g.y, g.z))
            if d < 150.0 and d < (bd or 1e9) then best, bd = g, d end
        end
    end
    if best then result('Duct rods', { ('Rodded **%.0f m** through to %s #%d.'):format(bd, equipLabelFor(best.model), best.id), 'Draw grip on — ready to pull the cable through.' })
    else result('Duct rods', { 'No chamber at the other end within 150 m.' }) end
end

local function harness()
    if HarnessMenu then return HarnessMenu() end              -- client/harness.lua: wear, check, clip on / off
    PPE.harness = not PPE.harness
    lib.notify({ type = PPE.harness and 'success' or 'inform', description = PPE.harness and 'Harness on · pole straps ready — you will clip on when you climb' or 'Harness off' })
end

local function tester()
    local id = nearestOntId(3.0)
    if not id then return need('ONT', 'connect to the ONT / router') end
    if not work('Running a speed test and checking the login', 7000, 'tablet', 'tablet') then return end
    local o = OntReading and OntReading(id) or {}
    if o.internet ~= 'on' then
        return result('Network tester', { '**FAIL**', o.rx == nil and 'No light on the ONT (LOS).' or o.service == 'none' and 'No service provisioned on this line.'
            or o.service == 'suspended' and 'Service suspended by the provider.' or 'PPP login not up yet — try again in a moment.' })
    end
    local seed = GetGameTimer()
    local down = (o.down or 0) * (0.94 + roll(seed, 6) / 100)
    local up = (o.up or 0) * (0.93 + roll(seed + 1, 7) / 100)
    result('Network tester', { '**PASS**', ('%s · %s'):format(o.provider or '?', o.plan or '?'), ('↓ %.0f Mbps · ↑ %.0f Mbps · %d ms'):format(down, up, 4 + roll(seed, 6)),
        ('PPP authenticated as %s'):format(o.username or '—') })
end

local function poleTest()
    local pl = nearestPole(2.0)
    if not pl then return need('pole', 'stand at the foot of the pole') end
    if not work('Tapping the pole with the test hammer', 4000, 'hammer', 'hammer') then return end
    if not work('Probing the wood at ground line', 2500, 'kneel') then return end
    local r = roll(('%.0f:%.0f'):format(pl.x, pl.y), 100)
    local verdict = r < 85 and 'sound' or r < 97 and 'suspect' or 'decayed'
    local lines = {
        verdict == 'sound' and '**Sound** — clear ring, probe 5 mm' or verdict == 'suspect' and '**Suspect** — dull note, probe 25 mm' or '**DECAYED** — dead thud, probe 60 mm',
        verdict == 'decayed' and 'Do not climb. Mark it for replacement.' or verdict == 'suspect' and 'Climb with care and report it for a re-test.' or 'Safe to climb.',
    }
    result('Pole test', lines)
    if verdict ~= 'sound' and pl.id and not pl.world and lib.alertDialog({ header = 'Mark for maintenance?', content = 'Sets this pole to maintenance on the pole map.', centered = true, cancel = true }) == 'confirm' then
        lib.callback.await('opslabs-towers:pole:status', false, pl.id, 'maintenance')
    end
end

---------------------------------------------------------------------------
-- San Andreas Power & Light electrical tools
---------------------------------------------------------------------------
local function ppeToggle(key, on, off)
    return function()
        PPE[key] = not PPE[key]
        lib.notify({ type = PPE[key] and 'success' or 'inform', description = PPE[key] and on or off })
    end
end

local function stateOf(id) return Power[id] or { fusesOut = false, earthed = false } end

local function voltage()
    local f, d = powerPole(6.0)
    local run = not f and nearestRun('power', 5.0)
    if not f and not run then return need('power pole or line', 'stand by the pole or under the line') end
    if not work('Testing with the voltage detector', 2500, 'up', 'stick') then return end
    local live
    if f then local s = stateOf(f.id) live = not s.fusesOut else live = true end
    if live then PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true) end
    result('Voltage detector', { live and '**LIVE** — 11 kV / 400 V present' or '**DEAD** — no voltage detected', live and 'Treat as live. Isolate (pull the fuses) and prove dead before touching.' or 'Prove the tester on a known live source, then earth it.' })
end

local function earthing()
    local f = powerPole(6.0)
    if not f then return need('power pole', 'earths go on at a pole') end
    local s = stateOf(f.id)
    local on = not s.earthed
    if on and not PPE.gloves then lib.notify({ type = 'error', description = 'Put your dielectric gloves on first' }) return end
    if not work(on and 'Clamping the portable earths on' or 'Taking the earths off', 5000, 'up', 'stick') then return end
    local r = lib.callback.await('opslabs-towers:power:set', false, f.id, 'earthed', on)
    if r and r.error == 'live' then
        AddExplosion(GetEntityCoords(PlayerPedId()) + vector3(0.0, 0.0, 1.5), 70, 0.0, true, false, 0.4)
        ApplyDamageToPed(PlayerPedId(), PPE.arc and 8 or 45, false)
        return lib.notify({ type = 'error', description = 'FLASH — that line was live! Never earth without pulling the fuses and proving dead.' })
    end
    if r and r.ok then lib.notify({ type = 'success', description = on and 'Earths on — the line can’t re-energise' or 'Earths off' })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

local function rod()
    local f = powerPole(6.0)
    if not f then return need('power pole', 'stand under the pole with the cut-outs') end
    local hasCutouts = false
    for _, g in pairs(CablingFixtures()) do
        if g.model == 'opslabs_power_cutouts' and #(vector2(g.x, g.y) - vector2(f.x, f.y)) < 1.0 then hasCutouts = true end
    end
    if not hasCutouts then return lib.notify({ type = 'error', description = 'This pole has no cut-out fuses fitted' }) end
    local s = stateOf(f.id)
    local out = not s.fusesOut
    if not PPE.gloves or not PPE.arc then lib.notify({ type = 'warning', description = 'Gloves and arc flash PPE should be on for switching' }) end
    if not work(out and 'Pulling the fuses with the operating rod' or 'Putting the fuses back in', 4000, 'up', 'stick') then return end
    local r = lib.callback.await('opslabs-towers:power:set', false, f.id, 'fusesOut', out)
    if r and r.ok then
        PlaySoundFrontend(-1, 'Bomb_Disarmed', 'GTAO_Speed_Convoy_Soundset', true)
        lib.notify({ type = 'success', description = out and 'Fuses out — the line is isolated (prove it dead)' or 'Fuses in — the line is live again' })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

local thermalOn = false
local function thermal()
    thermalOn = not thermalOn
    SetSeethrough(thermalOn)
    if not thermalOn then return end
    lib.notify({ description = 'Thermal camera on (use it again to switch off)' })
    local t = nearestFixture(function(m) return m == 'opslabs_power_transformer' end, 30.0)
    if t then
        local temp = 45 + roll(t.id .. ':' .. math.floor(GetCloudTimeAsInt() / 1800), 50)
        lib.notify({ type = temp > 80 and 'error' or 'inform', description = ('Transformer #%d: %d °C%s'):format(t.id, temp, temp > 80 and ' — hot spot, check the connections' or ' — normal') })
    end
    CreateThread(function()
        local untilT = GetGameTimer() + 60000
        while thermalOn and GetGameTimer() < untilT do Wait(500) end
        thermalOn = false
        SetSeethrough(false)
    end)
end

local function spike()
    local run = nearestRun('power', 4.0)
    if not run then return need('power cable', 'stand by the cable you need to cut') end
    if not work('Setting up the cable spiking gun', 3000, 'kneel') then return end
    PlaySoundFromEntity(-1, 'Bomb_Disarmed', PlayerPedId(), 'GTAO_Speed_Convoy_Soundset', false, 0)
    local dead = false
    local pts = run.points or {}
    for _, p in ipairs({ pts[1], pts[#pts] }) do
        if p then
            for _, g in pairs(CablingFixtures()) do
                if g.model:find('^opslabs_power_pole') and #(vector2(g.x, g.y) - vector2(p.x, p.y)) < 1.5 and stateOf(g.id).fusesOut then dead = true end
            end
        end
    end
    result('Cable spiking gun', { dead and '**Proven dead** — safe to cut' or '**LIVE** — the spike shorted the cable and the protection tripped',
        dead and 'Cut the cable and joint it.' or 'Isolate it at the pole (pull the fuses) and spike again.' })
end

local function sockets()
    local f = nearestFixture(find({ '^opslabs_power_transformer', '^opslabs_power_pole' }), 3.0)
    if not f then return need('transformer or cross-arm', 'climb up to it') end
    if not work('Torquing the bolts', 5000, 'hands') then return end
    lib.notify({ type = 'success', description = 'Bolts torqued to 85 Nm — ' .. equipLabelFor(f.model) })
end

---------------------------------------------------------------------------
-- OPS Openline copper phone line tools
---------------------------------------------------------------------------
local PL = Config.PhoneLine or {}
local COPPER = {}
for _, list in ipairs({ PL.Exchange, PL.PassThrough, PL.Sockets }) do for _, m in ipairs(list or {}) do COPPER[m] = true end end
local SOCKETS = {}
for _, m in ipairs(PL.Sockets or {}) do SOCKETS[m] = true end

local function copperKit(maxDist) return nearestFixture(function(m) return COPPER[m] == true end, maxDist or 2.5) end

local function trace(f)
    local t = lib.callback.await('opslabs-towers:phoneline:trace', false, f.id)
    if not t or t.error then lib.notify({ type = 'error', description = (t and t.error) or 'Line test failed' }) return nil end
    return t
end

local function noLine(t)
    if t.exchange then return ('**No dial tone** — the line reaches %s but the exchange has no power.'):format(t.exchangeLabel) end
    if (t.open or 0) > 0 then
        return ('**No dial tone** — open circuit about **%d m** away%s.'):format(t.open, t.openAt and (' (copper ends at the ' .. t.openAt .. ')') or '')
    end
    return '**No dial tone** — nothing is punched down on this terminal.'
end

local function buttSet()
    local f = copperKit(2.5)
    if not f then return need('socket, DP, joint, cabinet or MDF', 'clip on at the terminals you are testing') end
    if not work('Clipping the butt set on the pair', 2500, 'hands', 'buttset') then return end
    local t = trace(f)
    if not t then return end
    if not t.dialtone then return result('Lineman’s test set · ' .. t.label, { noLine(t), 'Trace it back with the tone tracer or the line tester.' }) end
    if not work('Listening for dial tone… dialling the ring-back test', 3000, 'hands', 'buttset') then return end
    PlaySoundFrontend(-1, 'Beep_Green', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
    result('Lineman’s test set · ' .. t.label, {
        '**Dial tone** — line working',
        ('Line number **%s** (ring-back test answered)'):format(t.number),
        ('Fed from %s · %d m of copper%s'):format(t.exchangeLabel, math.floor(t.metres + 0.5), #t.hops > 0 and (' via ' .. table.concat(t.hops, ' → ')) or ''),
    })
end

local toneUntil = 0
local function toneTracer()
    local f = copperKit(2.5)
    if not f then return need('socket, DP, joint or cabinet', 'clip the tone generator on at one end of the pair') end
    if not work('Clipping the tone generator on the pair', 2000, 'hands', 'toner') then return end
    local t = trace(f)
    if not t then return end
    local toned = {}
    for _, id in ipairs(t.direct or {}) do toned[id] = true end
    for _, id in ipairs(t.runs or {}) do toned[id] = true end
    if not next(toned) then return lib.notify({ type = 'error', description = 'No copper punched down here — nothing to tone' }) end
    toneUntil = GetGameTimer() + 90000
    lib.notify({ description = 'Tone on for 90 s — walk the probe along the cables: the toned pair warbles and glows purple' })
    CreateThread(function()
        local nextBeep = 0
        while GetGameTimer() < toneUntil do
            local here = pos()
            local best
            for id in pairs(toned) do
                local r = (CablingRuns and CablingRuns() or {})[id]
                local pts = r and r.points or {}
                for i = 1, #pts - 1 do
                    local a, b = vector3(pts[i].x, pts[i].y, pts[i].z), vector3(pts[i + 1].x, pts[i + 1].y, pts[i + 1].z)
                    local d = segDist(here, a, b)
                    if d < 40.0 then DrawLine(a.x, a.y, a.z + 0.02, b.x, b.y, b.z + 0.02, 191, 90, 242, 200) end
                    if d < (best or 2.0) then best = d end
                end
            end
            if best and GetGameTimer() > nextBeep then
                PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
                nextBeep = GetGameTimer() + math.floor(150 + best * 400)
            end
            Wait(0)
        end
    end)
end

local function lineTester()
    local f = copperKit(2.5)
    if not f then return need('socket, DP, joint, cabinet or MDF', 'connect the tester to the pair') end
    if not work('Running insulation, loop and capacitance tests', 6000, 'tablet', 'tablet') then return end
    local t = trace(f)
    if not t then return end
    local seed = f.id .. ':' .. math.floor(GetCloudTimeAsInt() / 3600)
    if t.exchange then
        result('Copper line tester · ' .. t.label, {
            t.dialtone and '**PASS**' or '**FAIL** — exchange battery missing',
            ('Loop resistance **%.1f Ω** (%d m of 0.5 mm copper)'):format(t.loop or 0, math.floor(t.metres + 0.5)),
            ('Insulation A–B / A–E / B–E: >%d MΩ'):format(500 + roll(seed, 400)),
            ('Line voltage %s · capacitance %d nF'):format(t.dialtone and ('%.1f V DC'):format(49.5 + roll(seed, 15) / 10) or '0 V', math.floor(t.metres * 0.05 + 0.5) + 50),
            ('Path: %s'):format(#t.hops > 0 and table.concat(t.hops, ' → ') .. ' → ' .. t.exchangeLabel or t.exchangeLabel),
        })
    else
        result('Copper line tester · ' .. t.label, {
            '**FAIL — open circuit**',
            (t.open or 0) > 0 and ('Capacitance puts the break about **%d m** away%s.'):format(t.open, t.openAt and (' — after the ' .. t.openAt) or '') or 'No pair connected at this terminal.',
            'Insulation >999 MΩ · Line voltage 0 V · No exchange battery.',
        })
    end
end

local function punchTool()
    if not work('Laying out the Krone tool, sheath knife and strippers', 2000, 'hands', 'pliers') then return end
    CopperPunchReady = true
    lib.notify({ type = 'success', description = 'IDC punch-down tool in hand — your next copper termination seats first time' })
end

local function uyCrimper()
    local f = nearestFixture(function(m) return COPPER[m] == true and not SOCKETS[m] end, 3.0)
    if not f then return need('copper joint, DP, junction box or cabinet', 'stand at the joint') end
    if not work('Cutting the pairs and dressing them into UY connectors', 4000, 'hands', 'pliers') then return end
    if not lib.skillCheck({ 'easy', 'medium' }, { 'e' }) then return lib.notify({ type = 'error', description = 'A UY connector didn’t crimp fully — cut it out and use a new one' }) end
    if not work('Crimping and sealing the joint (gel-filled)', 2500, 'hands', 'pliers') then return end
    lib.notify({ type = 'success', description = 'Pairs jointed in gel-filled UY connectors — ' .. equipLabelFor(f.model) })
end

local function multimeter()
    local f = copperKit(2.5)
    if not f then return need('phone socket or terminals', 'put the probes on the pair') end
    if not work('Measuring the line voltage', 2000, 'hands', 'meter') then return end
    local t = trace(f)
    if not t then return end
    result('Multimeter · ' .. t.label, { t.dialtone and ('**%.1f V DC** across A–B (on hook)'):format(49.5 + roll(f.id, 15) / 10) or '**0.0 V** — no exchange battery on the pair',
        t.dialtone and 'Exchange battery present (−50 V on the A-leg).' or 'Dead pair — check it back towards the exchange.' })
end

local function testSocket()
    local f = nearestFixture(function(m) return m == 'opslabs_nte5c' end, 2.5)
    if not f then return need('master socket (NTE5C)', 'stand at the master socket') end
    if not work('Removing the faceplate and plugging into the test socket', 2500, 'hands') then return end
    local t = trace(f)
    if not t then return end
    if not t.dialtone then return result('NTE5 test socket', { noLine(t), 'The fault is on the network side — not the customer’s wiring.' }) end
    local bad = {}
    for _, g in pairs(CablingFixtures()) do
        if (g.model == 'opslabs_copper_linejack' or g.model == 'opslabs_vdsl_faceplate') and #(vector3(g.x, g.y, g.z) - vector3(f.x, f.y, f.z)) < 30.0 then
            local e = trace(g)
            if e and not e.dialtone then bad[#bad + 1] = equipLabelFor(g.model) .. ' #' .. g.id end
        end
    end
    result('NTE5 test socket', { '**Dial tone at the test socket** — the line is good to the house',
        #bad > 0 and ('House wiring fault — no dial tone at: %s. Re-punch the extension wiring.'):format(table.concat(bad, ', ')) or 'Extension sockets nearby all have dial tone.' })
end

---------------------------------------------------------------------------
-- cordless drill: drill the cable entry hole through an outside wall and fit the entry bushing
---------------------------------------------------------------------------
--- opts (on a ladder): { dir = horizontal direction to the wall } — keeps the climbing pose (no work animation)
local function drill(opts)
    local ped = PlayerPedId()
    local from = GetEntityCoords(ped) + vector3(0.0, 0.0, opts and 0.45 or 0.2)
    local h = math.rad(GetEntityHeading(ped))
    local dir = opts and opts.dir or vector3(-math.sin(h), math.cos(h), 0.0)
    local to = from + dir * (opts and 4.0 or 1.6)          -- from a ladder the wall can be a few metres off
    local _, hit, at, n = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 + 16, ped, 4))
    if hit ~= 1 or math.abs(n.z) > 0.4 then return need('wall', 'face the wall where the cable goes in') end
    local anim = not opts and 'hands' or nil
    if not work('Marking the spot and drilling a pilot hole', 2500, anim, 'drill') then return end
    if not work('Drilling through the brickwork with the long masonry bit', 5000, anim, 'drill') then return end
    if not lib.skillCheck({ 'easy', 'medium' }, { 'e' }) then return lib.notify({ type = 'error', description = 'The bit wandered and blew the brick out the other side — fill it and drill again' }) end
    local head = vector3(at.x + n.x * 0.005, at.y + n.y * 0.005, at.z)
    local heading = math.deg(math.atan(n.x, -n.y)) % 360             -- the bushing's front faces out of the wall
    if lib.alertDialog({ header = 'Fit the entry bushing?', content = 'Push a brickwork entry bushing into the hole for the drop cable.', centered = true, cancel = true,
        labels = { confirm = 'Fit it', cancel = 'Leave the hole' } }) ~= 'confirm' then
        return lib.notify({ type = 'success', description = 'Hole drilled through the wall' })
    end
    if not work('Sealing the bushing into the hole', 2000, 'hands') then return end
    local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = 'opslabs_entry_bushing', x = head.x, y = head.y, z = head.z, heading = heading })
    if r and r.ok then lib.notify({ type = 'success', description = 'Entry hole drilled and bushing fitted — run the drop cable through it' })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Could not fit the bushing' }) end
end

ToolDrill = drill                                          -- also straight from /towers → Tools, and from a ladder (G)

--- up a pole: drill a through-bolt hole for a bracket at your height (keeps the climbing pose)
function ToolDrillPole(heightAbove)
    if not work('Drilling a through-bolt hole in the pole', 4000, nil, 'drill') then return end
    if not lib.skillCheck({ 'easy' }, { 'e' }) then return lib.notify({ type = 'error', description = 'The bit snagged in the grain — back it out and go again' }) end
    if not work('Clearing the swarf and fitting the bolt', 1500, nil, 'drill') then return end
    lib.notify({ type = 'success', description = ('Bolt hole drilled at %.1f m — ready to fit the bracket'):format(heightAbove or 0) })
end

---------------------------------------------------------------------------
-- MEWP (cherry picker): set up in front of you, ride the basket up to 14 m
---------------------------------------------------------------------------
local mewpActive = false
local function mewp()
    if mewpActive then return end
    local ped = PlayerPedId()
    local function load(m) local h = joaat(m) if not IsModelInCdimage(h) then return nil end lib.requestModel(h, 5000) return h end
    if not load('opslabs_mewp_base') then return lib.notify({ type = 'error', description = 'Restart opslabs-props for the MEWP' }) end
    load('opslabs_mewp_mast') load('opslabs_mewp_basket')
    local heading = GetEntityHeading(ped)
    local hr = math.rad(heading)
    local p = GetEntityCoords(ped) + vector3(-math.sin(hr) * 2.2, math.cos(hr) * 2.2, 0.0)
    local ok, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
    local bz = ok and gz or (p.z - 1.0)
    local function obj(m, x, y, z, h) local e = CreateObjectNoOffset(joaat(m), x, y, z, false, false, false) SetEntityHeading(e, h or heading) FreezeEntityPosition(e, true) return e end
    local base = obj('opslabs_mewp_base', p.x, p.y, bz)
    local basket = obj('opslabs_mewp_basket', p.x, p.y, bz + 1.1)
    SetEntityCollision(basket, false, false)
    local masts, booms = {}, {}
    mewpActive = true
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    local h, ang, reach = 0.0, heading, 1.2
    local menuOpen = false
    local sf = PlaceHud.buttons({ { 'Up / down', { 172, 173 } }, { 'Slew', { 174, 175 } }, { 'Reach', { 32, 33 } }, { 'Equipment', 47 }, { 'Cut cable', 26 }, { 'Lower & get out', 177 } })
    local last = GetGameTimer()
    local leaving = false
    while true do
        Wait(0)
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000)
        last = now
        for _, c in ipairs({ 22, 23, 24, 25, 26, 30, 31, 32, 33, 34, 35, 44, 47, 140, 141, 142, 172, 173, 174, 175, 177 }) do DisableControlAction(0, c, true) end
        if not menuOpen then
            if leaving then h = math.max(0.0, h - 1.4 * dt) if h <= 0.0 then break end
            else
                if IsDisabledControlPressed(0, 172) then h = math.min(14.0, h + 1.2 * dt) end
                if IsDisabledControlPressed(0, 173) then h = math.max(0.0, h - 1.2 * dt) end
                if IsDisabledControlPressed(0, 174) then ang = ang + 35.0 * dt end
                if IsDisabledControlPressed(0, 175) then ang = ang - 35.0 * dt end
                if IsDisabledControlPressed(0, 32) then reach = math.min(4.0, reach + 0.8 * dt) end
                if IsDisabledControlPressed(0, 33) then reach = math.max(0.6, reach - 0.8 * dt) end
                if IsDisabledControlJustPressed(0, 177) then leaving = true end
                if IsDisabledControlJustPressed(0, 26) and CableCutAtHand then menuOpen = true CreateThread(function() CableCutAtHand() menuOpen = false end) end
                if IsDisabledControlJustPressed(0, 47) then
                    menuOpen = true
                    local feet = GetEntityCoords(ped) - vector3(0.0, 0.0, 1.0)
                    local pl = nearestPole(2.2)
                    if pl and PoleEquipMenu then PoleEquipMenu(pl, math.atan(feet.y - pl.y, feet.x - pl.x), feet.z - pl.z, function() menuOpen = false end)
                    elseif LadderWallEquipment then LadderWallEquipment(function() menuOpen = false end)
                    else menuOpen = false end
                end
            end
        end
        -- mast up to the boom, boom out to the basket
        local top = bz + 1.05 + h
        local nm = math.max(0, math.ceil(h))
        while #masts < nm do masts[#masts + 1] = obj('opslabs_mewp_mast', p.x, p.y, bz + 1.05 + #masts) SetEntityCollision(masts[#masts], false, false) end
        while #masts > nm do DeleteEntity(table.remove(masts)) end
        for i, m in ipairs(masts) do SetEntityCoordsNoOffset(m, p.x, p.y, math.min(bz + 1.05 + (i - 1), top - 1.0), false, false, false) end
        local ar = math.rad(ang)
        local dir = vector3(-math.sin(ar), math.cos(ar), 0.0)
        local nb = math.max(1, math.ceil(reach))
        while #booms < nb do booms[#booms + 1] = obj('opslabs_mewp_mast', p.x, p.y, top) SetEntityCollision(booms[#booms], false, false) end
        while #booms > nb do DeleteEntity(table.remove(booms)) end
        for i, b in ipairs(booms) do
            local o = math.min(i - 1, reach - 1.0)
            SetEntityCoordsNoOffset(b, p.x + dir.x * o, p.y + dir.y * o, top, false, false, false)
            SetEntityRotation(b, -90.0, 0.0, ang, 2, false)
        end
        local bx, by = p.x + dir.x * reach, p.y + dir.y * reach
        SetEntityCoordsNoOffset(basket, bx, by, top - 0.06, false, false, false)
        SetEntityHeading(basket, ang)
        SetEntityCoordsNoOffset(ped, bx, by, top + 1.0, false, false, false)
        SetEntityHeading(ped, ang)
        PlaceHud.draw(sf, 'MEWP · cherry picker', leaving and 'Lowering…' or ('Basket %.1f m · reach %.1f m'):format(h + 1.05, reach), { 255, 190, 0 })
    end
    PlaceHud.release(sf)
    for _, e in ipairs(masts) do DeleteEntity(e) end
    for _, e in ipairs(booms) do DeleteEntity(e) end
    DeleteEntity(basket) DeleteEntity(base)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityCoords(ped, p.x + math.sin(hr) * 1.6, p.y - math.cos(hr) * 1.6, bz + 0.1, false, false, false, false)
    mewpActive = false
end

---------------------------------------------------------------------------
-- menus
---------------------------------------------------------------------------
local FIBRE = {
    { 'Cordless drill', 'Drill the cable entry hole through an outside wall and fit the entry bushing', 'screwdriver-wrench', drill },
    { 'Fusion splicer', 'Fuse two fibres at a joint, CBT or CSP — shows the splice loss', 'bolt', splicer },
    { 'OTDR', 'Shoot the fibre beside you — finds breaks, open ends and the length', 'chart-line', otdr },
    { 'Visual fault locator (red light)', 'Breaks and open ends glow red for 30 s', 'lightbulb', vfl },
    { 'ONT diagnostic tester', 'Reads POWER · PON · LOS · LAN · INTERNET, says what\'s wrong and how to fix it', 'stethoscope', ontTester },
    { 'Optical power meter', 'Light level arriving at the ONT (dBm)', 'gauge', powerMeter },
    { 'Fibre strippers & Kevlar shears', 'Prep the fibre — your next splice is cleaner', 'scissors', strippers },
    { 'One-click fibre cleaner', 'Clean a CBT port, CSP or ONT connector', 'pen', cleaner },
    { 'Manhole keys & gas detector', 'Lift a chamber cover and test the air before going in', 'triangle-exclamation', gasCheck },
    { 'Duct rods & draw grips', 'Rod through to the next chamber ready to pull cable', 'grip-lines', ductRods },
    { 'Combat harness & pole straps', 'Put on / take off fall-arrest gear for climbing', 'user-shield', harness },
    { 'Handheld network tester', 'Speed test and login check at the ONT', 'tablet-screen-button', tester },
    { 'Pole tester hammer & probe', 'Tap and probe a pole for rot before climbing', 'hammer', poleTest },
}
local COPPER_TOOLS = {
    { 'Cordless drill', 'Drill the cable entry hole through an outside wall and fit the entry bushing', 'screwdriver-wrench', drill },
    { 'Lineman’s test set (butt set)', 'Clip on at a socket, DP, joint or cabinet — dial tone, line number, path to the exchange', 'phone', buttSet },
    { 'Tone generator & inductive probe', 'Put tone on a pair, then follow it — the toned cable warbles and glows', 'wave-square', toneTracer },
    { 'Copper line tester', 'Loop resistance, insulation, capacitance — finds how far away an open circuit is', 'chart-line', lineTester },
    { 'IDC punch-down tool & strippers', 'Krone tool, sheath knife, strippers — your next copper termination seats first time', 'screwdriver', punchTool },
    { 'UY crimpers & gel connectors', 'Joint pairs at a DP, joint, junction box or cabinet', 'compress', uyCrimper },
    { 'Multimeter', 'Line voltage across the pair (exchange battery)', 'gauge', multimeter },
    { 'NTE5 test socket check', 'At the master socket: is the fault the network or the house wiring?', 'house-signal', testSocket },
    { 'Combat harness & pole straps', 'Put on / take off fall-arrest gear for climbing', 'user-shield', harness },
    { 'Pole tester hammer & probe', 'Tap and probe a pole for rot before climbing', 'hammer', poleTest },
}
local POWER = {
    { 'Insulated hand tools (1000 V)', 'VDE screwdrivers, pliers & cutters', 'screwdriver', ppeToggle('insulated', 'Insulated tools in hand', 'Insulated tools away') },
    { 'Voltage detector & phasing stick', 'Is the pole / line live or dead?', 'wave-square', voltage },
    { 'Dielectric rubber gloves', 'HV gloves with leather over-gloves', 'mitten', ppeToggle('gloves', 'Dielectric gloves on', 'Gloves off') },
    { 'Arc flash PPE', 'FR suit and switching visor', 'shield-halved', ppeToggle('arc', 'Arc flash PPE on', 'Arc flash PPE off') },
    { 'Portable earthing kit', 'Earth an isolated line so it can’t re-energise', 'plug-circle-xmark', earthing },
    { 'Insulated operating rod (shotgun stick)', 'Pull / replace the pole fuses from the ground', 'wand-magic', rod },
    { 'Thermal imaging camera', 'Spot hot transformers and loose connections', 'temperature-high', thermal },
    { 'Cable spiking gun', 'Prove an underground cable dead before cutting', 'crosshairs', spike },
    { 'Heavy socket set & spanners', 'Torque transformer and cross-arm bolts', 'wrench', sockets },
    { 'MEWP / cherry picker controls', 'Set up a cherry picker and ride the basket up to 14 m', 'truck-pickup', function() CreateThread(mewp) end },
}

local function kitMenu(id, title, list, color)
    local options = {}
    for _, t in ipairs(list) do
        options[#options + 1] = { title = t[1], description = t[2], icon = t[3], iconColor = color, onSelect = t[4] }
    end
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

function ToolKitMenu()
    local worn = {}
    if PPE.harness then worn[#worn + 1] = 'harness' end
    if PPE.gloves then worn[#worn + 1] = 'HV gloves' end
    if PPE.arc then worn[#worn + 1] = 'arc PPE' end
    if PPE.insulated then worn[#worn + 1] = 'insulated tools' end
    lib.registerContext({ id = 'toolkit', title = 'Tool kit', options = {
        { title = 'Wearing: ' .. (#worn > 0 and table.concat(worn, ', ') or 'nothing'), icon = 'user-shield', readOnly = true },
        { title = 'OPS Openline · fibre & telecom tools', description = 'ONT diagnostics, drill, splicer, OTDR, red light, power meter, cleaners, gas detector, rods, harness, tester, pole hammer', icon = 'network-wired', iconColor = '#0a84ff', arrow = true,
            onSelect = function() kitMenu('toolkit_fibre', 'Fibre & telecom tools', FIBRE, '#0a84ff') end },
        { title = 'OPS Openline · copper phone line tools', description = 'Drill, butt set, tone & probe, line tester, punch-down tool, UY crimpers, multimeter, NTE5 test socket', icon = 'phone', iconColor = '#bf5af2', arrow = true,
            onSelect = function() kitMenu('toolkit_copper', 'Copper phone line tools', COPPER_TOOLS, '#bf5af2') end },
        { title = 'San Andreas Power & Light · electrical tools', description = 'Insulated tools, voltage detector, gloves, arc PPE, earths, operating rod, thermal camera, spiking gun, sockets, MEWP', icon = 'bolt', iconColor = '#ffd60a', arrow = true,
            onSelect = function() kitMenu('toolkit_power', 'Electrical tools', POWER, '#ffd60a') end },
    } })
    lib.showContext('toolkit')
end

RegisterCommand('toolkit', function()
    if not lib.callback.await('opslabs-towers:cable:can', false) then return lib.notify({ type = 'error', description = 'Only network engineers carry the tool kit' }) end
    ToolKitMenu()
end, false)

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() and thermalOn then SetSeethrough(false) end end)
