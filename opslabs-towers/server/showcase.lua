-- OPS Showcase: builds one of everything in the /towers menu, really connected and working, around where an admin
-- stands (/opsshowcase here). Nothing is faked: it is ordinary kit, cable, pipe and towers (created_by 'OPS Showcase'),
-- so the grid, mains, fibre, copper, Wi-Fi, PoE, fuel and every other system run it exactly like kit built by hand.
--   /opsshowcase here     build it centred on you, the street running the way you face (needs ~550 × 260 m of space)
--   /opsshowcase goto     go to the suggested site (Config.Showcase.Site)
--   /opsshowcase where    list where each part is (also shown as map blips)
--   /opsshowcase remove   take the whole showcase away again
-- Layout (metres, x along the street to the right, y ahead of you): generation & transmission at the back (y ≈ 150),
-- the street at y = 0 with power poles one side and telecom poles the other, the house, exchange, depot, fuel station.

local SC = Config.Showcase or {}
local TAG = 'OPS Showcase'
local Built = nil            -- { fixtures, runs, towers, zones, origin }
local busy = false

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_showcase` (`k` VARCHAR(16) NOT NULL PRIMARY KEY, `v` LONGTEXT NOT NULL)]])
    local v = MySQL.scalar.await('SELECT v FROM opslabs_towers_showcase WHERE k = ?', { 'built' })
    Built = v and json.decode(v) or nil
    GlobalState.opsShowcase = Built and { zones = Built.zones, origin = Built.origin } or nil
end)

local function say(src, text, kind)
    if src and src > 0 then TriggerClientEvent('ox_lib:notify', src, { title = TAG, description = text, type = kind or 'inform', duration = 9000 })
    else print('[' .. TAG .. '] ' .. text) end
end

---------------------------------------------------------------------------
-- the layout. G(lx, ly) = ground height there (site frame); returns the plan
---------------------------------------------------------------------------
local function layout(O, H, G)
    local P = { fixtures = {}, towers = {}, runs = {}, post = {}, zones = {} }
    local byKey = {}
    local rad = math.rad(H)
    local c, s = math.cos(rad), math.sin(rad)
    local function rot(x, y, deg)
        local r = math.rad(deg)
        return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)
    end
    local function W(lx, ly) return O.x + lx * c - ly * s, O.y + lx * s + ly * c end
    local function pt(lx, ly, z) local x, y = W(lx, ly) return { x = x, y = y, z = z } end
    local n = 0
    local function fx(key, model, lx, ly, z, h, data)
        n = n + 1
        key = key or ('k' .. n)
        local x, y = W(lx, ly)
        local f = { key = key, model = model, x = x, y = y, z = z, heading = ((h or 0) + H) % 360, data = data, lx = lx, ly = ly }
        P.fixtures[#P.fixtures + 1] = f
        byKey[key] = f
        return f
    end
    local function ground(key, model, lx, ly, dz, h, data) return fx(key, model, lx, ly, G(lx, ly) + (dz or 0), h, data) end
    -- a building: kit inside / on it in the building's own frame (bx, by, height above its slab)
    local function building(key, model, lx, ly, h)
        local z = G(lx, ly)
        local b = fx(key, model, lx, ly, z, h)
        b.frame = { lx = lx, ly = ly, h = h, z = z }
        return b
    end
    local function inB(b, key, model, bx, by, bz, bh, data)
        local F = b.frame
        local dx, dy = rot(bx, by, F.h)
        return fx(key, model, F.lx + dx, F.ly + dy, F.z + bz, (bh or 0) + F.h, data)
    end
    local function bpt(b, bx, by, bz) local F = b.frame local dx, dy = rot(bx, by, F.h) return pt(F.lx + dx, F.ly + dy, F.z + bz) end
    local function at(key, dz, ox, oy)
        local f = byKey[key]
        local dx, dy = 0, 0
        if ox or oy then dx, dy = rot(ox or 0, oy or 0, H) end
        return { x = f.x + dx, y = f.y + dy, z = f.z + (dz or 0) }
    end
    -- pole kit: on the pole at a height, nudged off its centre
    local function onPole(pole, key, model, height, off, h, data)
        local p = byKey[pole]
        return fx(key, model, p.lx + (off or 0.0), p.ly - 0.18, p.z + height, h or 0, data)
    end
    local function run(kind, color, pts, o)
        o = o or {}
        P.runs[#P.runs + 1] = { kind = kind, color = color, pts = pts, sf = o.sf, ef = o.ef, st = o.st, et = o.et, term = o.term }
    end
    local function tower(key, d) n = n + 1 key = key or ('t' .. n) d.key = key P.towers[#P.towers + 1] = d byKey[key] = d return d end
    local function zone(label, lx, ly, icon) local x, y = W(lx, ly) P.zones[#P.zones + 1] = { label = label, x = x, y = y, sprite = icon } end

    -- ============================================================ generation & transmission (y ≈ 150)
    ground('station', 'opslabs_grid_station', -230, 150)
    local pyl = { { 'py1', -170, 150 }, { 'py2', -110, 150 }, { 'py3', -50, 150 }, { 'py4', 60, 190 } }
    for _, p in ipairs(pyl) do ground(p[1], 'opslabs_grid_pylon', p[2], p[3], 0, 90) end
    local function arm(k) local f = byKey[k] local dx, dy = rot(0, 7.5, H) return { x = f.x + dx, y = f.y + dy, z = f.z + 18.8 } end
    ground('yard', 'opslabs_grid_substation', 20, 150)
    building('subb', 'opslabs_grid_subbuilding', 100, 150, 0)
    local shell = building('subs', 'opslabs_grid_subshell', 180, 150, 0)
    -- fit the empty building out piece by piece, with an RTU pole outside
    inB(shell, nil, 'opslabs_sub_gis', -7.6, 3.0, 0.1)
    inB(shell, nil, 'opslabs_sub_swgr', -2.4, 3.8, 0.1)
    inB(shell, nil, 'opslabs_sub_tx', 2.5, 2.8, 0.1)
    inB(shell, nil, 'opslabs_sub_tx', 6.6, 2.8, 0.1)
    inB(shell, nil, 'opslabs_sub_busbar', -1.0, 1.4, 0.1)
    inB(shell, nil, 'opslabs_sub_relay', -8.2, -1.8, 0.1)
    inB(shell, nil, 'opslabs_sub_meter', -7.4, -1.8, 0.1)
    inB(shell, nil, 'opslabs_sub_control', -5.4, -3.6, 0.1, 180)
    inB(shell, nil, 'opslabs_sub_battery', 6.4, -4.1, 0.1, 180)
    inB(shell, nil, 'opslabs_sub_earth', -2.0, -4.7, 0.1, 180)
    inB(shell, nil, 'opslabs_sub_cable', 1.0, -2.6, 0.1)
    ground('rtu', 'opslabs_grid_rtu', 171, 143)
    ground('wind1', 'opslabs_grid_wind', 300, 110)
    ground('wind2', 'opslabs_grid_wind', 335, 80)
    -- 400 kV: station → py1 → py2 → py3 → yard; py3 → py4 → building and empty building
    local st = byKey.station
    local gx, gy = rot(25, 7.5, H)
    run('power', 'transmission', { { x = st.x + gx, y = st.y + gy, z = st.z + 16 }, arm('py1') })
    run('power', 'transmission', { arm('py1'), arm('py2') })
    run('power', 'transmission', { arm('py2'), arm('py3') })
    run('power', 'transmission', { arm('py3'), at('yard', 13, 0, 9.5) })
    run('power', 'transmission', { arm('py3'), arm('py4') })
    run('power', 'transmission', { arm('py4'), at('subb', 5.5, 0, 4) })
    run('power', 'transmission', { arm('py4'), at('subs', 5.5, 0, 4) })
    zone('Power station & 400 kV line', -200, 150, 354)
    zone('Substations: yard · fitted building · DIY building + RTU', 100, 160, 354)
    zone('Wind turbines', 318, 95, 354)

    -- ============================================================ the street (y = 0): power poles y = +12, telecom y = -12
    local PP = { { 'pp1', 20 }, { 'pp2', 60 }, { 'pp3', 100 }, { 'pp4', 140 }, { 'pp5', 180 }, { 'pp6', 220 } }
    for _, p in ipairs(PP) do ground(p[1], 'opslabs_power_pole_10m', p[2], 12) end
    ground('pp7', 'opslabs_power_pole_12m', 260, 90)
    local function top(k, dz) local f = byKey[k] return { x = f.x, y = f.y, z = f.z + (dz or 9.6) } end
    -- feeders (11 kV): yard → pp1..pp4 · fitted building → pp5, pp6 · DIY building → pp7 ← wind turbines
    run('power', 'hv', { at('yard', 6, 0, -11), top('pp1') })
    run('power', 'hv', { top('pp1'), top('pp2') })
    run('power', 'hv', { top('pp2'), top('pp3') })
    run('power', 'hv', { top('pp3'), top('pp4') })
    run('power', 'hv', { at('subb', 4, 0, -6), top('pp5') })
    run('power', 'hv', { top('pp5'), top('pp6') })
    run('power', 'hv', { at('subs', 4, 0, -6), top('pp7', 11.6) })
    run('power', 'hv', { at('wind1', 3), top('pp7', 11.6) })
    run('power', 'hv', { at('wind2', 3), top('pp7', 11.6) })
    -- pole kit
    for _, k in ipairs({ 'pp1', 'pp2', 'pp4', 'pp6' }) do onPole(k, k .. 'tx', 'opslabs_power_transformer', 6.8, 0.3) end
    onPole('pp3', 'recloser', 'opslabs_power_recloser', 7.0, 0.4)
    onPole('pp2', nil, 'opslabs_power_cutouts', 7.6, -0.25)
    onPole('pp2', nil, 'opslabs_power_lv_connectors', 8.2, 0.0)
    onPole('pp2', nil, 'opslabs_power_earth_tape', 0.0, 0.0)
    onPole('pp2', nil, 'opslabs_power_anticlimb', 2.6, 0.18)
    onPole('pp2', nil, 'opslabs_power_danger_sign', 2.1, 0.0)
    onPole('pp4', nil, 'opslabs_power_pothead', 2.2, 0.0)
    onPole('pp3', nil, 'opslabs_streetlight_pole', 7.4, 0.0, 180)
    -- street lighting
    for i, x in ipairs({ 40, 80, 120 }) do ground(nil, 'opslabs_streetlight_6m', x, 7, 0, 180) end
    ground(nil, 'opslabs_streetlight_10m', 160, 7, 0, 180)
    ground(nil, 'opslabs_streetlight_10m_twin', 200, 0, 0, 90)
    zone('Street: power poles, telecom poles, street lights', 100, 0, 1)

    -- telecom poles and their kit
    local TP = { { 'tp1', 20, 'opslabs_pole_10m' }, { 'tp2', 60, 'opslabs_pole_10m' }, { 'tp3', 100, 'opslabs_pole_10m' }, { 'tp4', 140, 'opslabs_pole_10m' },
        { 'tp5', 180, 'opslabs_pole_metal' }, { 'tp6', 200, 'opslabs_pole_07m' }, { 'tp7', 215, 'opslabs_pole_13m' } }
    for _, p in ipairs(TP) do
        local data = p[3] == 'opslabs_pole_metal' and { brand = { name = 'OPS Openline', color = '#0a84ff', number = 'SHOW-005', phone = '0800 677 000', extra = 'OPS Showcase' } } or nil
        ground(p[1], p[3], p[2], -12, 0, 0, data)
    end
    onPole('tp1', 'splice', 'opslabs_splice_enclosure', 6.0)
    onPole('tp1', nil, 'opslabs_slack_loop', 4.2)
    onPole('tp1', nil, 'opslabs_triple_bracket', 6.8)
    onPole('tp1', nil, 'opslabs_jhook', 7.4)
    onPole('tp2', 'cbt', 'opslabs_cbt_8', 5.5)
    onPole('tp2', 'dp', 'opslabs_copper_dp', 4.6)
    onPole('tp3', nil, 'opslabs_joint_tophat', 6.4)
    onPole('tp3', 'gunshot', 'opslabs_gunshot_sensor', 7.2)
    onPole('tp4', nil, 'opslabs_alt_cbt', 4.6)
    onPole('tp4', nil, 'opslabs_alt_tag', 3.9)
    onPole('tp4', nil, 'opslabs_alt_pia_bracket', 5.3)
    onPole('tp4', nil, 'opslabs_copper_joint_aerial', 6.2)
    onPole('tp4', nil, 'opslabs_pole_splice_box', 3.2)

    -- ============================================================ customer house (60, 30) facing the street
    local house = building('house', 'opslabs_house_customer', 60, 30, 0)
    local FL = 0.12
    inB(house, 'cutout', 'opslabs_mains_cutout', 1.0, -4.5, FL + 1.3)
    inB(house, 'meter', 'opslabs_mains_meter', 1.6, -4.5, FL + 1.3)
    inB(house, 'hcu', 'opslabs_mains_cu', 1.2, -4.25, FL + 1.6, 180)
    inB(house, 'switch', 'opslabs_mains_switch', 0.45, -4.25, FL + 1.1, 180)
    inB(house, 'nte', 'opslabs_nte5c', 0.3, -4.25, FL + 0.3, 180)
    inB(house, 'ont', 'opslabs_ont', -1.35, -4.25, FL + 1.3, 180)
    inB(house, nil, 'opslabs_mains_socket2_usb', 3.6, -4.25, FL + 1.05, 180)
    inB(house, nil, 'opslabs_mains_spur', 4.6, -4.25, FL + 1.05, 180)
    inB(house, nil, 'opslabs_mains_socket2_chrome', -2.3, -4.25, FL + 0.3, 180)
    inB(house, nil, 'opslabs_vdsl_faceplate', -1.95, -4.25, FL + 0.3, 180)
    inB(house, nil, 'opslabs_mains_socket1', 1.0, 4.25, FL + 0.3, 0)
    inB(house, nil, 'opslabs_mains_socket2', -5.75, 0.5, FL + 0.3, 90)
    inB(house, 'jack', 'opslabs_copper_linejack', -2.6, 4.25, FL + 0.3, 0)
    inB(house, 'jb', 'opslabs_copper_jb', -0.5, -4.25, FL + 2.3, 180)
    inB(house, 'lamp1', 'opslabs_mains_ledpanel', -3.0, -1.0, 2.76)
    inB(house, nil, 'opslabs_mains_ledpanel', 1.6, -1.2, 2.76)
    inB(house, nil, 'opslabs_entry_cap', -1.35, -4.25, FL + 2.0, 180)
    inB(house, nil, 'opslabs_splice_tray', -1.0, -4.25, FL + 1.9, 180)
    -- worktop / table / desk kit
    inB(house, nil, 'opslabs_mains_desklamp', 2.2, -3.95, 1.02)
    inB(house, nil, 'opslabs_mains_qistand', 2.9, -3.95, 1.02)
    inB(house, nil, 'opslabs_mains_phonecable', 4.2, -3.95, 1.02)
    inB(house, nil, 'opslabs_mains_qipad', 4.9, -3.95, 1.02)
    inB(house, 'hlaptop', 'opslabs_laptop', 1.2, 3.9, 0.86, 180)
    inB(house, nil, 'opslabs_mains_laptopcharger', 1.55, 4.05, 0.86)
    inB(house, nil, 'opslabs_mains_extension', -2.6, -3.9, FL)
    -- outside: fibre / copper entry, EV, solar, outdoor kit
    inB(house, 'csp', 'opslabs_csp', -1.35, -4.5, FL + 2.3)
    inB(house, nil, 'opslabs_house_pole', -3.4, -4.5, 2.7)
    inB(house, nil, 'opslabs_wall_anchor', -2.0, -4.5, 2.5)
    inB(house, nil, 'opslabs_entry_bushing', -1.6, -4.5, FL + 1.2)
    inB(house, nil, 'opslabs_mains_ev_wall', 6.0, -2.0, 1.0, 90)
    inB(house, nil, 'opslabs_mains_isolator', 6.0, -0.8, 1.4, 90)
    inB(house, nil, 'opslabs_mains_socket_out', 6.0, 0.6, 0.6, 90)
    inB(house, nil, 'opslabs_solar_inverter', 6.0, 2.0, 0.9, 90)
    inB(house, nil, 'opslabs_solar_dciso', 6.0, 3.1, 1.4, 90)
    inB(house, nil, 'opslabs_solar_battery', 6.3, 3.9, 0.0, 90)
    ground(nil, 'opslabs_mains_ev_post', 69, 26, 0, 90)
    ground(nil, 'opslabs_mains_reel', 66.8, 31.5)
    ground(nil, 'opslabs_solar_array_ground', 60, 45)
    ground(nil, 'opslabs_mains_generator', 52, 41)
    -- supply: pp2 → cut-out → meter → consumer unit; the light switch works the living room panel
    run('power', 'service', { top('pp2', 8.0), at('cutout', 0.2) })
    run('power', 'mains', { at('cutout', 0.2), at('meter', 0.2) })
    run('power', 'mains', { at('meter', 0.2), at('hcu', 0.15) })
    run('power', 'mains', { at('switch', 0.05), at('lamp1', -0.02) })
    -- fibre + copper in from the poles
    run('fibre', 'black', { at('cbt', 0), at('csp', 0) }, { sf = 'cbt', ef = 'csp', term = true })
    run('fibre', 'black', { at('csp', 0), at('ont', 0.1) }, { sf = 'csp', ef = 'ont', term = true })
    run('copper', 'drop', { at('dp', 0), bpt(house, -1.6, -4.6, FL + 1.2), at('nte', 0.05) }, { sf = 'dp', ef = 'nte', term = true })
    run('copper', 'internal', { at('nte', 0.05), at('jb', 0) }, { sf = 'nte', ef = 'jb', term = true })
    run('copper', 'internal', { at('jb', 0), at('jack', 0.05) }, { sf = 'jb', ef = 'jack', term = true })
    -- home network: ONT → OPS Gateway Mini → PoE switch → ceiling AP · laptop · mesh / extender
    local function wifi(key, model, b, bx, by, bz, name, bh)
        local F = b.frame
        local dx, dy = rot(bx, by, F.h)
        local x, y = W(F.lx + dx, F.ly + dy)
        return tower(key, { type = 'wifi', model = model, name = name, x = x, y = y, z = F.z + bz, heading = ((bh or 0) + F.h + H) % 360, exact = true })
    end
    wifi('ucg', 'opslabs_gw_mini', house, 2.7, -1.9, 0.86, 'Showcase House')
    wifi('hsw', 'opslabs_poe_switch8', house, 3.3, -1.9, 0.86, 'Showcase House switch')
    wifi('hap', 'opslabs_ap_halo_ceiling', house, -0.5, 1.0, 2.76, 'Showcase House AP')
    wifi(nil, 'opslabs_mesh_m1', house, -3.2, -0.45, 0.62, 'Showcase Mesh')
    wifi(nil, 'opslabs_homerouter_ax4', house, 1.85, 3.9, 0.86, 'Showcase HomeRouter')
    wifi(nil, 'opslabs_range_extender', house, -5.7, 0.9, FL + 0.3, 'Showcase Extender', 90)
    run('cable', 'black', { at('ont', 0.05), byKey.ucg }, { sf = 'ont', et = 'ucg', term = true })
    run('cable', 'black', { byKey.ucg, byKey.hsw }, { st = 'ucg', et = 'hsw', term = true })
    run('cable', 'black', { byKey.hsw, bpt(house, -0.5, 0.0, 2.7), byKey.hap }, { st = 'hsw', et = 'hap', term = true })
    run('cable', 'black', { at('hlaptop', 0.02), bpt(house, 1.2, 3.0, FL + 0.05), bpt(house, 2.7, -1.6, FL + 0.05), byKey.ucg }, { sf = 'hlaptop', et = 'ucg', term = true })
    zone('Customer house: power, fibre, copper, Wi-Fi, EV, solar', 60, 30, 40)

    -- ============================================================ telephone exchange (30, -40), door onto the street
    local ex = building('ex', 'opslabs_exchange_building', 30, -40, 180)
    local EF = 0.15
    inB(ex, 'olt', 'opslabs_olt', -6.5, 3.9, EF)
    inB(ex, 'core', 'opslabs_core_router', -5.8, 3.9, EF)
    inB(ex, nil, 'opslabs_fdf', -5.1, 3.9, EF)
    inB(ex, nil, 'opslabs_hof', -4.4, 3.9, EF)
    inB(ex, nil, 'opslabs_dslam', -3.7, 3.9, EF)
    inB(ex, 'mdf', 'opslabs_mdf', -1.6, 3.9, EF)
    inB(ex, nil, 'opslabs_rectifier', 5.0, 3.9, EF)
    inB(ex, nil, 'opslabs_battery_bank', 5.85, 0.5, EF)
    inB(ex, nil, 'opslabs_dc_power', 6.5, -3.0, EF)
    inB(ex, nil, 'opslabs_crac', -7.0, -2.5, EF, 90)
    inB(ex, 'exmeter', 'opslabs_mains_meterbox', 2.5, -5.0, 0.8)
    inB(ex, 'excu', 'opslabs_mains_cu', 2.6, -4.7, EF + 1.5, 180)
    inB(ex, nil, 'opslabs_mains_socket2', 0.5, 4.7, EF + 0.3, 0)
    inB(ex, nil, 'opslabs_generator', -11.5, 0.0, 0.0, 90)
    inB(ex, nil, 'opslabs_condenser', 11.0, 2.0, 0.0)
    inB(ex, nil, 'opslabs_pole_roof', 4.0, 2.0, 5.35)
    inB(ex, nil, 'opslabs_solar_panel_roof', -4.0, 2.0, 5.35, 180)
    wifi(nil, 'opslabs_gw_pro', ex, 0.0, 4.3, EF, 'Exchange Gateway Pro')
    wifi(nil, 'opslabs_edge_e7', ex, 1.0, 4.3, EF, 'Exchange EdgeLink E7')
    run('power', 'service', { top('pp1', 8.0), at('exmeter', 0.3) })
    run('power', 'mains', { at('exmeter', 0.3), at('excu', 0.1) })
    -- OLT → splice enclosure on tp1 → CBT on tp2 (→ the house); MDF → PCP cabinet → DP on tp2
    run('fibre', 'black', { at('olt', 1.2), bpt(ex, -6.5, 2.8, EF + 0.1), bpt(ex, 0.0, -4.0, EF + 0.1), bpt(ex, 0.0, -6.0, 0.05),
        pt(20, -12.5, G(20, -12) + 0.05), at('splice', 0) }, { sf = 'olt', ef = 'splice', term = true })
    run('fibre', 'black', { at('splice', 0), at('cbt', 0) }, { sf = 'splice', ef = 'cbt', term = true })
    ground('pcp', 'opslabs_cabinet_pcp', 45, -6, 0, 180)
    run('copper', 'multipair', { at('mdf', 1.0), bpt(ex, -1.6, 2.8, EF + 0.1), bpt(ex, 0.0, -4.0, EF + 0.1), bpt(ex, 0.0, -6.0, 0.05), at('pcp', 0.3) }, { sf = 'mdf', ef = 'pcp', term = true })
    run('copper', 'multipair', { at('pcp', 0.3), pt(60, -12.5, G(60, -12) + 0.05), at('dp', 0) }, { sf = 'pcp', ef = 'dp', term = true })
    P.post[#P.post + 1] = function(id)
        local core, olt = Cabling.fixtures[id.core], id.olt
        core.data = { uplink = true, patched = { olt } }
        MySQL.update.await('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { json.encode(core.data), core.id })
    end
    zone('Telephone exchange (OLT, core router, MDF, power plant)', 30, -40, 459)

    -- street cabinets, chambers, joints + a roadworks scene
    ground(nil, 'opslabs_cabinet_fttc', 50, -6, 0, 180)
    ground(nil, 'opslabs_cabinet_green3', 55, -6, 0, 180)
    ground(nil, 'opslabs_cabinet_green3_open', 130, -6, 0, 180)
    ground(nil, 'opslabs_footway_box', 80, -5)
    ground(nil, 'opslabs_carriageway_cover', 80, 2)
    ground(nil, 'opslabs_manhole', 90, -5)
    ground(nil, 'opslabs_chamber_modular', 95, -5)
    ground(nil, 'opslabs_ucbt', 83, -5)
    ground(nil, 'opslabs_track_joint', 87, -5)
    ground(nil, 'opslabs_base_node', 98, -5)
    for i, x in ipairs({ 76, 78, 80, 82, 84 }) do ground(nil, i == 1 and 'opslabs_rw_cone_1000' or i == 5 and 'opslabs_rw_cone_450' or 'opslabs_rw_cone', x, -2.6) end
    ground(nil, 'opslabs_rw_barrier', 80, -8.2)
    ground(nil, 'opslabs_rw_barrier_stay', 77, -8.2)
    ground(nil, 'opslabs_rw_barrier_red', 83, -8.2)
    ground(nil, 'opslabs_rw_sign', 73, -6, 0, 0, { lines = { 'OPS OPENLINE', 'FIBRE WORKS', 'SHOWCASE SITE', 'Mon-Sun 07:00-19:00', 'Sorry for any delay' } })
    ground(nil, 'opslabs_rw_tlight', 68, -2, 0, 90, { phase = 0 })
    ground(nil, 'opslabs_rw_tlight', 92, 2, 0, 270, { phase = 1 })
    ground(nil, 'opslabs_rw_tape', 86, -4)
    ground(nil, 'opslabs_rw_worklight', 78, -7)
    ground(nil, 'opslabs_rw_lighttower', 93, -9)
    zone('Roadworks, street cabinets & chambers', 80, -5, 650)

    -- ============================================================ depot (110, -45) + OPS Track bay + fuel station control
    local dp = building('depot', 'opslabs_depot', 110, -45, 180)
    inB(dp, 'dmeter', 'opslabs_mains_meterbox', -2.5, -7.0, 0.8)
    inB(dp, 'dcu', 'opslabs_mains_cu', -2.5, -6.75, 1.7, 180)
    inB(dp, nil, 'opslabs_mains_socket2', -9.5, -6.75, 0.4, 180)
    inB(dp, nil, 'opslabs_mains_socket2_usb', -5.0, -6.75, 0.4, 180)
    inB(dp, nil, 'opslabs_mains_batten', 5.0, 0.0, 5.6)
    inB(dp, nil, 'opslabs_mains_extension', -9.3, -5.4, 0.1)
    inB(dp, 'dlaptop', 'opslabs_laptop', -9.7, -4.15, 0.84, 180)
    inB(dp, nil, 'opslabs_mains_laptopcharger', -9.15, -4.2, 0.84)
    inB(dp, 'atg', 'opslabs_fuel_atg', -10.75, -2.0, 1.4, 90)
    -- OPS Track fitting bay on the workbench
    inB(dp, nil, 'opslabs_trk_unit', 10.35, 1.4, 1.0, 90)
    inB(dp, nil, 'opslabs_trk_antenna', 10.35, 2.0, 1.0)
    inB(dp, nil, 'opslabs_trk_battery', 10.35, 2.6, 1.0, 90)
    inB(dp, nil, 'opslabs_trk_harness', 10.3, 3.4, 1.0, 90)
    inB(dp, nil, 'opslabs_trk_toolcase', 9.2, 2.5, 0.08, 90)
    inB(dp, nil, 'opslabs_trk_sign', 10.74, 2.5, 2.4, 270)
    -- office network: EdgeLink E5 gateway ← PoE switch → APs (PoE) + laptop
    wifi('er605', 'opslabs_edge_e5', dp, -5.8, -4.3, 0.84, 'Showcase Depot')
    wifi('dsw', 'opslabs_poe_switch8', dp, -5.0, -4.3, 0.84, 'Showcase Depot switch')
    wifi(nil, 'opslabs_ctrl_c2', dp, -5.4, -3.95, 0.84, 'Showcase Depot controller')
    wifi('dap1', 'opslabs_ap_beam_ceiling', dp, -7.0, -2.5, 3.18, 'Showcase Depot AP (office)')
    wifi('dap2', 'opslabs_ap_halo', dp, -9.9, -3.85, 0.84, 'Showcase Depot AP (desk)')
    wifi('dap3', 'opslabs_ap_beam', dp, -9.2, -4.45, 0.84, 'Showcase Depot Beam AP')
    run('cable', 'black', { byKey.er605, byKey.dsw }, { st = 'er605', et = 'dsw', term = true })
    run('cable', 'black', { byKey.dsw, bpt(dp, -6.0, -3.0, 3.1), byKey.dap1 }, { st = 'dsw', et = 'dap1', term = true })
    run('cable', 'black', { byKey.dsw, bpt(dp, -7.5, -4.6, 0.84), byKey.dap2 }, { st = 'dsw', et = 'dap2', term = true })
    run('cable', 'black', { byKey.dsw, bpt(dp, -7.5, -4.55, 0.84), byKey.dap3 }, { st = 'dsw', et = 'dap3', term = true })
    run('cable', 'black', { at('dlaptop', 0.02), bpt(dp, -7.5, -4.5, 0.84), byKey.dsw }, { sf = 'dlaptop', et = 'dsw', term = true })
    run('power', 'service', { top('pp4', 8.0), at('dmeter', 0.3) })
    run('power', 'mains', { at('dmeter', 0.3), at('dcu', 0.1) })
    zone('Engineering depot · OPS Track fitting bay · office network', 110, -45, 446)

    -- ============================================================ fuel station (165, -45) + bulk terminal
    ground('canopy', 'opslabs_fuel_canopy', 165, -45)
    ground('d1', 'opslabs_fuel_dispenser', 162, -45, 0, 90)
    ground('d2', 'opslabs_fuel_dispenser', 168, -45, 0, 90)
    ground('tul', 'opslabs_fuel_tank_ul', 156, -60)
    ground('tsup', 'opslabs_fuel_tank_sup', 160, -60)
    ground('tdsl', 'opslabs_fuel_tank_dsl', 164, -60)
    ground('vent', 'opslabs_fuel_vent', 150, -64)
    ground('fill', 'opslabs_fuel_fillpoint', 172, -62)
    ground(nil, 'opslabs_fuel_estop', 170, -39)
    ground('agt', 'opslabs_fuel_tank_agt', 135, -62)
    ground(nil, 'opslabs_fuel_gantry', 230, -62)
    local function g(lx, ly, dz) return pt(lx, ly, G(lx, ly) + (dz or 0.05)) end
    local tanks = { { 'tul', 'ul', 156 }, { 'tsup', 'sup', 160 }, { 'tdsl', 'dsl', 164 } }
    for i, t in ipairs(tanks) do
        local off = (i - 2) * 0.3
        run('pipe', t[2], { g(t[3], -59.6), g(t[3], -52), g(162 + off, -46), g(162 + off, -45.4) })        -- tank → dispenser 1
        run('pipe', t[2], { g(162 + off, -44.6), g(168 + off, -44.6) })                                 -- dispenser 1 → 2
        run('pipe', t[2], { g(171.5, -61.6 + off), g(t[3] + 0.2, -60.4) })                              -- fill point → tank
        run('pipe', 'vent', { g(t[3] - 0.2, -60.3), g(150.2, -63.6) })                                  -- tank → vent stack
    end
    -- power: depot consumer unit → dispenser 1 → dispenser 2 → canopy lights (the gauge is in the depot office)
    run('power', 'mains', { at('dcu', 0.1), bpt(dp, -2.5, -7.4, 0.05), g(140, -40), g(162, -44.8, 0.3) })
    run('power', 'mains', { g(162, -44.8, 0.3), g(168, -44.8, 0.3) })
    run('power', 'mains', { g(168, -45.2, 0.3), g(165, -45, 0.1) })
    P.post[#P.post + 1] = function(id)
        if FuelSetTank then
            FuelSetTank(id.tul, 24000) FuelSetTank(id.tsup, 18000) FuelSetTank(id.tdsl, 26000) FuelSetTank(id.agt, 7000)
        end
        if FuelAction then FuelAction(id.atg, 'name', { name = 'OPS Fuel · Showcase' }, TAG) end
    end
    zone('OPS Fuel station (canopy, pumps, tanks, fill point, vent)', 165, -50, 361)
    zone('Bulk fuel terminal gantry', 230, -62, 361)

    -- ============================================================ cell masts, gunshot sensor, underground, fencing
    local m1x, m1y = W(-20, -22)
    tower('cell1', { type = 'cell', model = 'opslabs_mast_5g', name = 'OPS Showcase 5G', x = m1x, y = m1y, z = G(-20, -22), heading = H, exact = true })
    local m2x, m2y = W(-60, 60)
    tower('cell2', { type = 'cell', model = 'opslabs_mast_lattice', name = 'OPS Showcase lattice', x = m2x, y = m2y, z = G(-60, 60), heading = H, exact = true })
    zone('Cell masts (5G monopole, lattice mast)', -40, 20, 459)
    ground(nil, 'opslabs_ug_chamber', -40, -60)
    ground(nil, 'opslabs_ug_tunnel', -40, -56.2)
    ground(nil, 'opslabs_ug_tunnel', -40, -52.2)
    ground(nil, 'opslabs_ug_tunnel_tee', -40, -48.2)
    ground(nil, 'opslabs_ug_tunnel_end', -40, -46.2)
    ground(nil, 'opslabs_ug_entrance', -33, -62)
    ground(nil, 'opslabs_ug_riser', -46, -60)
    ground(nil, 'opslabs_ug_riser_flush', -46, -57)
    zone('Underground chamber & cable tunnel', -40, -55, 557)
    -- palisade / mesh fencing behind the exchange, gates, barrier, bollards
    local brand = { brand = { name = 'OPS Network', color = '#0a84ff', message = 'Telephone exchange · authorised staff only', phone = '0800 677 000' } }
    for i = 0, 9 do ground(nil, i % 3 == 0 and 'opslabs_fence_pal_grey' or i % 3 == 1 and 'opslabs_fence_pal_green' or 'opslabs_fence_pal_galv', 18 + 1.25 + i * 2.5, -50) end
    for i = 0, 3 do ground(nil, i % 2 == 0 and 'opslabs_fence_mesh_grey' or 'opslabs_fence_mesh_green', 16.8, -48.75 + i * 2.5, 0, 90) end
    ground(nil, 'opslabs_fence_post', 18, -50)
    ground(nil, 'opslabs_fence_brand', 44.25, -50, 0, 0, brand)
    ground(nil, 'opslabs_fence_sign', 44.25, -50.15, 1.2, 0, brand)
    ground(nil, 'opslabs_gate_slide_frame', 53.5, -50, 0, 0, brand)
    ground(nil, 'opslabs_gate_swing_frame', 61, -50, 0, 0, brand)
    ground(nil, 'opslabs_gate_ped_frame', 66, -50)
    ground(nil, 'opslabs_barrier_housing', 72, -53, 0, 0)
    ground(nil, 'opslabs_bollard_rising', 77, -53)
    ground(nil, 'opslabs_bollard_fixed', 79, -53)
    ground(nil, 'opslabs_bollard_steel', 80.5, -53)
    zone('Security fencing, gates, barrier & bollards', 50, -51, 1)

    -- grid: start two units, name things
    P.post[#P.post + 1] = function(id)
        if not GridAction then return end
        GridAction({ action = 'name', key = 'N' .. id.station, name = 'Showcase Power Station' }, TAG)
        GridAction({ action = 'name', key = 'N' .. id.yard, name = 'Showcase Yard 400/11 kV' }, TAG)
        GridAction({ action = 'name', key = 'N' .. id.subb, name = 'Showcase Substation Building' }, TAG)
        GridAction({ action = 'name', key = 'N' .. id.subs, name = 'Showcase DIY Substation (RTU)' }, TAG)
        GridAction({ action = 'unit_start', id = id.station, unit = 1 }, TAG)
        GridAction({ action = 'unit_start', id = id.station, unit = 2 }, TAG)
    end
    P.post[#P.post + 1] = function(id)
        if IspProvision then IspProvision(id.ont, 'opsfibre', 'fibre900', 'Showcase House', TAG) end
    end
    return P
end

---------------------------------------------------------------------------
-- building it
---------------------------------------------------------------------------
local function insertFixture(f)
    local id = MySQL.insert.await('INSERT INTO opslabs_towers_fixtures (model, x, y, z, heading, data, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { f.model, f.x, f.y, f.z, f.heading, f.data and json.encode(f.data) or nil, TAG })
    Cabling.fixtures[id] = { id = id, model = f.model, x = f.x, y = f.y, z = f.z, heading = f.heading, data = f.data, created_by = TAG }
    return id
end

local function insertRun(r, ids, tids)
    local pts, length = {}, 0.0
    for i, p in ipairs(r.pts) do
        pts[i] = { x = p.x, y = p.y, z = p.z, nx = 0.0, ny = 0.0, nz = 1.0 }
        if i > 1 then length = length + math.sqrt((p.x - r.pts[i - 1].x) ^ 2 + (p.y - r.pts[i - 1].y) ^ 2 + (p.z - r.pts[i - 1].z) ^ 2) end
    end
    local row = { kind = r.kind, color = r.color, points = pts, length = length, box_id = nil,
        start_tower = r.st and tids[r.st] or nil, end_tower = r.et and tids[r.et] or nil,
        start_fixture = r.sf and ids[r.sf] or nil, end_fixture = r.ef and ids[r.ef] or nil,
        start_term = r.term == true, end_term = r.term == true, created_by = TAG }
    local id = MySQL.insert.await([[INSERT INTO opslabs_towers_cables (kind, color, points, length, start_tower, end_tower, start_fixture, end_fixture, start_term, end_term, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { row.kind, row.color, json.encode(pts), length, row.start_tower, row.end_tower, row.start_fixture, row.end_fixture,
        row.start_term and 1 or 0, row.end_term and 1 or 0, TAG })
    row.id = id
    Cabling.runs[id] = row
    return id
end

local function save()
    MySQL.update.await('INSERT INTO opslabs_towers_showcase (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)', { 'built', json.encode(Built) })
    GlobalState.opsShowcase = Built and { zones = Built.zones, origin = Built.origin } or nil
end

local function build(src, O, H, flatZ)
    -- flat ground (the airport): no survey needed
    if flatZ then
        local P = layout(O, H, function() return flatZ end)
        return P, flatZ
    end
    -- pass 1: where we need the ground height
    local wanted, idx = {}, {}
    local function want(lx, ly)
        local key = ('%.1f:%.1f'):format(lx, ly)
        if not idx[key] then
            local r = math.rad(H)
            wanted[#wanted + 1] = { x = O.x + lx * math.cos(r) - ly * math.sin(r), y = O.y + lx * math.sin(r) + ly * math.cos(r) }
            idx[key] = #wanted
        end
        return O.z
    end
    layout(O, H, want)
    say(src, ('Surveying the site (%d spots) — hold still, you will be moved round it and back…'):format(#wanted))
    local zs = lib.callback.await('opslabs-towers:showcase:survey', src, wanted) or {}
    local found = 0
    for i = 1, #wanted do if tonumber(zs[i]) then found = found + 1 end end
    local function G(lx, ly)
        local z = tonumber(zs[idx[('%.1f:%.1f'):format(lx, ly)]])
        return z or O.z
    end
    -- pass 2: build it
    return layout(O, H, G), nil, found, #wanted
end

local function commit(src, O, H, P, found, wanted)
    local ids, tids = {}, {}
    Built = { fixtures = {}, runs = {}, towers = {}, zones = P.zones, origin = { x = O.x, y = O.y, z = O.z, h = H }, at = os.time() }
    for _, f in ipairs(P.fixtures) do
        local id = insertFixture(f)
        ids[f.key] = id
        Built.fixtures[#Built.fixtures + 1] = id
    end
    for _, t in ipairs(P.towers) do
        local row = SaveTower(nil, { type = t.type, name = t.name, x = t.x, y = t.y, z = t.z, heading = t.heading, model = t.model, exact = true, active = true,
            ssid = t.type == 'wifi' and t.name:gsub('%s+', '-') or nil, notes = TAG }, TAG)
        if row then tids[t.key] = row.id Built.towers[#Built.towers + 1] = row.id end
    end
    for _, r in ipairs(P.runs) do Built.runs[#Built.runs + 1] = insertRun(r, ids, tids) end
    save()
    if CablingChanged then CablingChanged() end
    for _, fn in ipairs(P.post) do local ok, err = pcall(fn, ids) if not ok then print('[showcase] post step failed: ' .. tostring(err)) end end
    if CablingChanged then CablingChanged() end
    TriggerEvent('opslabs-towers:towersChanged')
    say(src, ('Built: %d pieces of kit, %d cable / pipe runs, %d towers (ground found for %d / %d spots). The power station units take ~90 s to come online.')
        :format(#Built.fixtures, #Built.runs, #Built.towers, found or #P.fixtures, wanted or #P.fixtures), 'success')
    TriggerClientEvent('opslabs-towers:showcase:where', src, Built.zones)
end

local function remove(src)
    if not Built then return say(src, 'There is no showcase built') end
    for _, id in ipairs(Built.runs or {}) do Cabling.runs[id] = nil end
    if #(Built.runs or {}) > 0 then MySQL.query.await('DELETE FROM opslabs_towers_cables WHERE id IN (' .. table.concat(Built.runs, ',') .. ')') end
    for _, id in ipairs(Built.fixtures or {}) do
        if IspFixtureRemoved then pcall(IspFixtureRemoved, id) end
        Cabling.fixtures[id] = nil
    end
    if #(Built.fixtures or {}) > 0 then MySQL.query.await('DELETE FROM opslabs_towers_fixtures WHERE id IN (' .. table.concat(Built.fixtures, ',') .. ')') end
    for _, id in ipairs(Built.towers or {}) do if DeleteTower then pcall(DeleteTower, id) end end
    Built = nil
    MySQL.query.await('DELETE FROM opslabs_towers_showcase WHERE k = ?', { 'built' })
    GlobalState.opsShowcase = nil
    if CablingChanged then CablingChanged() end
    TriggerEvent('opslabs-towers:towersChanged')
    if BroadcastTowers then BroadcastTowers() end
    say(src, 'Showcase removed', 'success')
end

--- server/citybuild.lua: take the showcase away before building the city network
function ShowcaseRemove() if Built then remove(0) return true end return false end

RegisterCommand('opsshowcase', function(src, args)
    if src > 0 and not IsTowerAdmin(src) then return say(src, 'Admins only', 'error') end
    local a = (args[1] or ''):lower()
    if a == 'here' then
        if src == 0 then return print('Run it in game, standing where you want it') end
        if Built then return say(src, 'A showcase is already built — /opsshowcase where, or /opsshowcase remove first', 'error') end
        if busy then return say(src, 'Already building…', 'error') end
        busy = true
        local ped = GetPlayerPed(src)
        local c = GetEntityCoords(ped)
        local h = math.floor((GetEntityHeading(ped) + 45) / 90) * 90 % 360       -- square to the nearest quarter
        local O = { x = c.x, y = c.y, z = c.z - 1.0 }
        local ok, err = pcall(function()
            local P, _, found, wanted = build(src, O, h)
            commit(src, O, h, P, found, wanted)
        end)
        busy = false
        if not ok then say(src, 'Build failed: ' .. tostring(err), 'error') print('[showcase] ' .. tostring(err)) end
    elseif a == 'remove' then remove(src)
    elseif a == 'airport' then
        if Built then return say(src, 'Already built — /opsshowcase remove first', 'error') end
        local S = SC.Site
        local O = { x = S.x, y = S.y, z = S.z }
        local P = build(src, O, S.h or 0, S.z)
        commit(src, O, S.h or 0, P)
    elseif a == 'resnap' then
        -- drop everything onto the real ground: survey every spot, move kit and cable by the difference
        if src == 0 or not Built then return say(src, 'Run it in game, with the showcase built', 'error') end
        local base = (Built.origin or {}).z or 0
        local pts, list = {}, {}
        for _, id in ipairs(Built.fixtures) do local f = Cabling.fixtures[id] if f then pts[#pts + 1] = { x = f.x, y = f.y } list[#list + 1] = { f = f } end end
        for _, id in ipairs(Built.runs) do
            local r = Cabling.runs[id]
            for _, p in ipairs(r and r.points or {}) do pts[#pts + 1] = { x = p.x, y = p.y } list[#list + 1] = { p = p, r = r } end
        end
        say(src, ('Re-reading the ground at %d spots…'):format(#pts))
        local zs = lib.callback.await('opslabs-towers:showcase:survey', src, pts) or {}
        local moved, touched = 0, {}
        for i, it in ipairs(list) do
            local z = tonumber(zs[i])
            if z and math.abs(z - base) > 0.03 and math.abs(z - base) < 8 then
                local d = z - base
                if it.f then
                    it.f.z = it.f.z + d
                    MySQL.update.await('UPDATE opslabs_towers_fixtures SET z = ? WHERE id = ?', { it.f.z, it.f.id })
                else it.p.z = it.p.z + d touched[it.r.id] = it.r end
                moved = moved + 1
            end
        end
        for id, r in pairs(touched) do MySQL.update.await('UPDATE opslabs_towers_cables SET points = ? WHERE id = ?', { json.encode(r.points), id }) end
        if CablingChanged then CablingChanged() end
        say(src, ('Done: %d of %d spots moved onto the ground'):format(moved, #pts), 'success')
    elseif a == 'goto' then
        local s = SC.Site or { x = 1340.0, y = 3200.0 }
        TriggerClientEvent('opslabs-towers:showcase:goto', src, Built and Built.origin or s)
    elseif a == 'where' then
        if not Built then return say(src, 'No showcase yet. Stand somewhere big and empty (or /opsshowcase goto) and use /opsshowcase here') end
        if src > 0 then TriggerClientEvent('opslabs-towers:showcase:where', src, Built.zones)
        else for _, z in ipairs(Built.zones) do print(('%s: %.1f, %.1f'):format(z.label, z.x, z.y)) end end
    else
        say(src, Built and ('Showcase is built (%d kit, %d runs). /opsshowcase where · goto · remove'):format(#Built.fixtures, #Built.runs)
            or 'Not built yet. /opsshowcase goto (suggested site) then /opsshowcase here — it builds round you, the street running the way you face.')
    end
end, false)

exports('ShowcaseInfo', function() return Built end)

-- build it at the airport by itself the first time (Config.Showcase.AutoBuild)
CreateThread(function()
    if not SC.AutoBuild or not SC.Site then return end
    Wait(20000)                       -- let every system load its own state first
    if Built then return end
    local S = SC.Site
    local O = { x = S.x, y = S.y, z = S.z }
    local ok, err = pcall(function() commit(0, O, S.h or 0, (build(0, O, S.h or 0, S.z))) end)
    if not ok then print('[showcase] auto-build failed: ' .. tostring(err)) end
end)
