-- OPS City network (Config.City): builds a real, connected, powered network across the whole map in one go, started
-- from OPS Hub (Grid / Power / Internet / Gunshots / Fuel / CCTV → "Build complete network") or /opscity.
--   statewide   a power station + 400 kV pylon lines (minimum spanning tree) to a substation in every district
--   district    a flat lot beside a road: fitted substation, telephone exchange (OLT + core router + power), customer
--               house on broadband (meter, consumer unit, ONT), fuel station (tanks, pumps, pipework, gauge), CCTV
--               (NVR + PoE cameras), a cell mast · along the road both ways: 11 kV poles (transformers, recloser,
--               cut-outs, street lights) and telecom poles (splice, CBTs, fibre, gunshot sensors)
-- Nothing is faked: it's ordinary kit and cable (created_by 'OPS City') that the grid, mains, fibre, Wi-Fi, CCTV, fuel and
-- gunshot systems run like anything built by hand, so it can be controlled, broken and repaired. The server can't see
-- the map, so an admin's game surveys it (client/citybuild.lua — they're hidden for a few minutes). With no admin in
-- game the build waits for the next one to join.

local CY = Config.City or {}
if CY.Enabled == false then return end
local TAG = 'OPS City'
local CC = Config.Cabling or {}

local Built = nil        -- { fixtures = {}, runs = {}, towers = {}, districts = {}, at }
local Job = { state = 'idle' }
local busy = false

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_city` (`k` VARCHAR(16) NOT NULL PRIMARY KEY, `v` LONGTEXT NOT NULL)]])
    local v = MySQL.scalar.await('SELECT v FROM opslabs_towers_city WHERE k = ?', { 'built' })
    Built = v and json.decode(v) or nil
end)
local function save()
    if Built then MySQL.update.await('REPLACE INTO opslabs_towers_city (k, v) VALUES (?, ?)', { 'built', json.encode(Built) })
    else MySQL.update.await('DELETE FROM opslabs_towers_city WHERE k = ?', { 'built' }) end
end

local function step(msg, done, total)
    Job.msg, Job.done, Job.total, Job.at = msg, done or Job.done, total or Job.total, os.time()
    print(('[%s] %s'):format(TAG, msg))
end

---------------------------------------------------------------------------
-- geometry
---------------------------------------------------------------------------

local function rot(x, y, deg) local r = math.rad(deg) return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r) end
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

--- the plan being assembled: fixtures / runs / towers keyed so runs can refer to them
local function newPlan()
    local P = { fixtures = {}, runs = {}, towers = {}, post = {}, byKey = {}, n = 0 }
    function P.fx(key, model, x, y, z, h, data)
        P.n = P.n + 1
        key = key or ('k' .. P.n)
        local f = { key = key, model = model, x = x, y = y, z = z, heading = (h or 0) % 360, data = data }
        P.fixtures[#P.fixtures + 1] = f
        P.byKey[key] = f
        return f
    end
    function P.run(kind, color, pts, o)
        o = o or {}
        P.runs[#P.runs + 1] = { kind = kind, color = color, pts = pts, sf = o.sf, ef = o.ef, st = o.st, et = o.et, term = o.term }
    end
    function P.tower(key, d) d.key = key P.towers[#P.towers + 1] = d P.byKey[key] = d return d end
    --- a point in a fixture's own frame
    function P.off(key, ox, oy, dz)
        local f = P.byKey[key]
        local dx, dy = rot(ox or 0, oy or 0, f.heading or 0)
        return { x = f.x + dx, y = f.y + dy, z = f.z + (dz or 0) }
    end
    --- pole kit: fitted on a pole at a height, on its LV-rack side, nudged sideways
    function P.onPole(pole, key, model, height, side, h, data)
        local p = P.byKey[pole]
        local dx, dy = rot(side or 0, -0.18, p.heading)
        return P.fx(key, model, p.x + dx, p.y + dy, p.z + height, (h or 0) + p.heading, data)
    end
    return P
end

--- a district lot frame (front edge centre at the road, +y into the lot) with the surveyed ground
local function lotFrame(P, lot)
    local H = lot.h
    local function W(lx, ly) local dx, dy = rot(lx, ly, H) return lot.x + dx, lot.y + dy end
    local function G(lx, ly)
        local best, bd = lot.z, nil
        for _, s in ipairs(lot.zs or {}) do
            local d = (s[1] - lx) ^ 2 + (s[2] - ly) ^ 2
            if not bd or d < bd then best, bd = s[3], d end
        end
        return best
    end
    local L = {}
    function L.pt(lx, ly, dz) local x, y = W(lx, ly) return { x = x, y = y, z = G(lx, ly) + (dz or 0) } end
    function L.ground(key, model, lx, ly, dz, h, data) local x, y = W(lx, ly) return P.fx(key, model, x, y, G(lx, ly) + (dz or 0), (h or 0) + H, data) end
    function L.building(key, model, lx, ly, h)
        local b = L.ground(key, model, lx, ly, 0, h)
        b.frame = { lx = lx, ly = ly, h = h or 0, z = b.z }
        return b
    end
    function L.inB(b, key, model, bx, by, bz, bh, data)
        local F = b.frame
        local dx, dy = rot(bx, by, F.h)
        local x, y = W(F.lx + dx, F.ly + dy)
        return P.fx(key, model, x, y, F.z + bz, (bh or 0) + F.h + H, data)
    end
    function L.bpt(b, bx, by, bz)
        local F = b.frame
        local dx, dy = rot(bx, by, F.h)
        local x, y = W(F.lx + dx, F.ly + dy)
        return { x = x, y = y, z = F.z + bz }
    end
    L.H, L.W, L.G = H, W, G
    return L
end

---------------------------------------------------------------------------
-- one district
---------------------------------------------------------------------------

-- the plots a district asks the surveyor for (front edge on the road, +y into the plot; metres)
local function plotsFor(systems)
    local list = { { key = 'sub', w = 16, d = 14, need = true, label = 'substation' } }
    if systems.internet or systems.cctv then list[#list + 1] = { key = 'ex', w = 28, d = 13, label = 'telephone exchange' } end
    list[#list + 1] = { key = 'house', w = 14, d = 11, label = 'customer house' }
    if systems.fuel then list[#list + 1] = { key = 'fuel', w = 24, d = 20, label = 'fuel station' } end
    list[#list + 1] = { key = 'mast', w = 7, d = 7, label = 'cell mast', slope = 3.5 }
    return list
end

local function district(P, i, d, S)
    local sites, name = S.sites, d.name
    local K = function(k) return ('d%d_%s'):format(i, k) end
    local F = {}
    for k, site in pairs(sites) do F[k] = lotFrame(P, site) end

    -- substation (fitted building: 400 kV in, 11 kV feeders out — all within its reach)
    F.sub.building(K('sub'), 'opslabs_grid_subbuilding', 0, 7, 0)

    -- 11 kV pole lines (both ways along the road from the substation)
    local function poleTop(k, dz) return P.off(k, 0, 0, dz or 9.6) end
    local txPoles = {}
    for li, line in ipairs(S.power or {}) do
        local prev = nil
        for pi, p in ipairs(line) do
            local pk = K(('pp%d_%d'):format(li, pi))
            P.fx(pk, 'opslabs_power_pole_10m', p.x, p.y, p.z, p.h)
            if pi == 1 then P.run('power', 'hv', { P.off(K('sub'), 0, -6, 4), poleTop(pk) })
            else P.run('power', 'hv', { poleTop(prev), poleTop(pk) }) end
            if pi % 3 == 1 then
                P.onPole(pk, pk .. 'tx', 'opslabs_power_transformer', 6.8, 0.3)
                P.onPole(pk, nil, 'opslabs_power_cutouts', 7.6, -0.25)
                txPoles[#txPoles + 1] = pk
            end
            if li == 1 and pi == 3 then P.onPole(pk, nil, 'opslabs_power_recloser', 7.0, 0.4) end
            if pi % 2 == 0 then P.onPole(pk, nil, 'opslabs_streetlight_pole', 7.4, 0.0, 180) end
            if pi == 1 then
                P.onPole(pk, nil, 'opslabs_power_danger_sign', 2.1, 0.0)
                P.onPole(pk, nil, 'opslabs_power_anticlimb', 2.6, 0.18)
            end
            prev = pk
        end
    end
    --- a service drop from the nearest transformer pole to a point (nil when there's no transformer near)
    local function supply(to)
        local best, bd
        for _, pk in ipairs(txPoles) do
            local dd = dist(P.byKey[pk], to)
            if not bd or dd < bd then best, bd = pk, dd end
        end
        if best and bd <= 160 then P.run('power', 'service', { poleTop(best, 8.0), to }) return true end
    end

    -- telephone exchange
    local ex = nil
    if F.ex then
        ex = F.ex.building(K('ex'), 'opslabs_exchange_building', 0, 6.5, 0)
        local EF, B = 0.15, F.ex
        B.inB(ex, K('olt'), 'opslabs_olt', -6.5, 3.9, EF)
        B.inB(ex, K('core'), 'opslabs_core_router', -5.8, 3.9, EF)
        B.inB(ex, nil, 'opslabs_fdf', -5.1, 3.9, EF)
        B.inB(ex, nil, 'opslabs_rectifier', 5.0, 3.9, EF)
        B.inB(ex, nil, 'opslabs_battery_bank', 5.85, 0.5, EF)
        B.inB(ex, nil, 'opslabs_crac', -7.0, -2.5, EF, 90)
        B.inB(ex, K('exmeter'), 'opslabs_mains_meterbox', 2.5, -5.0, 0.8)
        B.inB(ex, K('excu'), 'opslabs_mains_cu', 2.6, -4.7, EF + 1.5, 180)
        B.inB(ex, nil, 'opslabs_mains_socket2', 0.5, 4.7, EF + 0.3, 0)
        B.inB(ex, nil, 'opslabs_mains_batten', 0.0, 0.0, 4.6)
        B.inB(ex, nil, 'opslabs_generator', -11.5, 0.0, 0.0, 90)
        supply(P.off(K('exmeter'), 0, 0, 0.3))
        P.run('power', 'mains', { P.off(K('exmeter'), 0, 0, 0.3), P.off(K('excu'), 0, 0, 0.1) })
        P.post[#P.post + 1] = function(id)
            local core = Cabling.fixtures[id[K('core')]]
            if core then
                core.data = { uplink = true, patched = { id[K('olt')] } }
                MySQL.update.await('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { json.encode(core.data), core.id })
            end
        end
        -- CCTV: NVR beside the exchange socket, PoE cameras on the outside walls, CAT6 back to the NVR
        if S.systems.cctv then
            B.inB(ex, K('nvr'), 'opslabs_cctv_nvr', 1.6, 4.2, EF, 0)
            for c, cam in ipairs({ { 'opslabs_cctv_bullet', -6.0, -5.15, 0 }, { 'opslabs_cctv_bullet', 6.0, -5.15, 0 }, { 'opslabs_cctv_dome', 8.15, 0.0, 90 },
                { 'opslabs_cctv_ptz', -8.15, 0.0, 270 } }) do
                local ck = K('cam' .. c)
                B.inB(ex, ck, cam[1], cam[2], cam[3], 3.4, cam[4])
                P.run('cable', 'black', { P.off(ck, 0, 0, -0.05), B.bpt(ex, cam[2] * 0.9, cam[3] * 0.85, 3.3), B.bpt(ex, 1.6, 3.8, 3.3), P.off(K('nvr'), 0, 0, 0.1) },
                    { sf = ck, ef = K('nvr'), term = true })
            end
        end
    end

    -- customer house: power from the nearest transformer pole, broadband from the nearest CBT
    local house = nil
    if F.house then
        local B = F.house
        house = B.building(K('house'), 'opslabs_house_customer', 0, 5.5, 0)
        local FL = 0.12
        B.inB(house, K('cutout'), 'opslabs_mains_cutout', 1.0, -4.5, FL + 1.3)
        B.inB(house, K('meter'), 'opslabs_mains_meter', 1.6, -4.5, FL + 1.3)
        B.inB(house, K('hcu'), 'opslabs_mains_cu', 1.2, -4.25, FL + 1.6, 180)
        B.inB(house, K('ont'), 'opslabs_ont', -1.35, -4.25, FL + 1.3, 180)
        B.inB(house, K('csp'), 'opslabs_csp', -1.35, -4.5, FL + 2.3)
        B.inB(house, nil, 'opslabs_mains_ledpanel', -3.0, -1.0, 2.76)
        B.inB(house, nil, 'opslabs_mains_socket2', 3.6, -4.25, FL + 1.05, 180)
        B.inB(house, nil, 'opslabs_house_pole', -3.4, -4.5, 2.7)
        supply(P.off(K('cutout'), 0, 0, 0.2))
        P.run('power', 'mains', { P.off(K('cutout'), 0, 0, 0.2), P.off(K('meter'), 0, 0, 0.2) })
        P.run('power', 'mains', { P.off(K('meter'), 0, 0, 0.2), P.off(K('hcu'), 0, 0, 0.15) })
        P.run('fibre', 'black', { P.off(K('csp')), P.off(K('ont'), 0, 0, 0.1) }, { sf = K('csp'), ef = K('ont'), term = true })
    end

    -- fuel station: its own supply pillar (meter, consumer unit, tank gauge) fed from the nearest transformer pole
    if F.fuel then
        local B = F.fuel
        B.ground(K('fmeter'), 'opslabs_mains_meterbox', -10, 2.5, 0, 180)
        B.ground(K('fcu'), 'opslabs_mains_cu', -10, 2.75, 1.5, 0)
        B.ground(K('atg'), 'opslabs_fuel_atg', -11.2, 2.75, 1.4, 0)
        B.ground(K('canopy'), 'opslabs_fuel_canopy', 0, 7)
        B.ground(K('d1'), 'opslabs_fuel_dispenser', -3, 7, 0, 90)
        B.ground(K('d2'), 'opslabs_fuel_dispenser', 3, 7, 0, 90)
        B.ground(K('tul'), 'opslabs_fuel_tank_ul', -4, 15)
        B.ground(K('tsup'), 'opslabs_fuel_tank_sup', 0, 15)
        B.ground(K('tdsl'), 'opslabs_fuel_tank_dsl', 4, 15)
        B.ground(K('vent'), 'opslabs_fuel_vent', -9, 18)
        B.ground(K('fill'), 'opslabs_fuel_fillpoint', 9, 15)
        B.ground(nil, 'opslabs_fuel_estop', 10.5, 9)
        local function g(lx, ly, dz) return B.pt(lx, ly, dz or 0.05) end
        for k, t in ipairs({ { 'tul', 'ul', -4 }, { 'tsup', 'sup', 0 }, { 'tdsl', 'dsl', 4 } }) do
            local o = (k - 2) * 0.3
            P.run('pipe', t[2], { g(t[3], 14.6), g(t[3], 11), g(-3 + o, 8), g(-3 + o, 7.6) })        -- tank → dispenser 1
            P.run('pipe', t[2], { g(-3 + o, 6.4), g(3 + o, 6.4) })                                    -- dispenser 1 → 2
            P.run('pipe', t[2], { g(8.5, 14.6 + o), g(t[3] + 0.2, 15.4) })                            -- fill point → tank
            P.run('pipe', 'vent', { g(t[3] - 0.2, 15.3), g(-8.8, 17.6) })                             -- tank → vent stack
        end
        supply(P.off(K('fmeter'), 0, 0, 0.3))
        P.run('power', 'mains', { P.off(K('fmeter'), 0, 0, 0.3), P.off(K('fcu'), 0, 0, 0.1) })
        P.run('power', 'mains', { P.off(K('fcu'), 0, 0, 0.1), g(-10, 4, 0.05), g(-3, 7.2, 0.3) })
        P.run('power', 'mains', { g(-3, 7.2, 0.3), g(3, 7.2, 0.3) })
        P.run('power', 'mains', { g(3, 6.8, 0.3), g(0, 7, 0.1) })
        P.post[#P.post + 1] = function(id)
            if FuelSetTank then pcall(FuelSetTank, id[K('tul')], 24000) pcall(FuelSetTank, id[K('tsup')], 18000) pcall(FuelSetTank, id[K('tdsl')], 26000) end
            if FuelAction then pcall(FuelAction, id[K('atg')], 'name', { name = 'OPS Fuel · ' .. name }, TAG) end
        end
    end

    -- cell mast (OPS Mobile coverage: the gunshot sensors' backhaul)
    if F.mast then
        local mx, my = F.mast.W(0, 3.5)
        P.tower(K('cell'), { type = 'cell', model = 'opslabs_mast_5g', name = 'OPS Mobile · ' .. name, x = mx, y = my, z = F.mast.G(0, 3.5), heading = F.mast.H, exact = true })
    end

    -- telecom poles across the road: splice on the first, CBTs along, fibre from the OLT, gunshot sensors
    if S.systems.internet and ex then
        local lines = S.telecom or {}
        local splice, cbts = nil, {}
        for li, line in ipairs(lines) do
            for pi, p in ipairs(line) do
                local tk = K(('tp%d_%d'):format(li, pi))
                P.fx(tk, 'opslabs_pole_10m', p.x, p.y, p.z, p.h)
                if not splice then P.onPole(tk, K('splice'), 'opslabs_splice_enclosure', 6.0) P.onPole(tk, nil, 'opslabs_slack_loop', 4.2) splice = tk end
                if pi % 3 == 2 then P.onPole(tk, tk .. 'cbt', 'opslabs_cbt_8', 5.5) cbts[#cbts + 1] = tk .. 'cbt' end
                if S.systems.gunshots and pi % 4 == 3 then P.onPole(tk, nil, 'opslabs_gunshot_sensor', 7.2) end
            end
        end
        if splice then
            P.run('fibre', 'black', { P.off(K('olt'), 0, 0, 1.2), F.ex.bpt(ex, -6.5, 2.8, 0.25), F.ex.bpt(ex, 0.0, -4.0, 0.25), F.ex.bpt(ex, 0.0, -6.0, 0.05),
                F.ex.pt(0, 0.5, 0.1), P.off(K('splice')) }, { sf = K('olt'), ef = K('splice'), term = true })
            for li, line in ipairs(lines) do
                local pts = { P.off(K('splice')) }
                for pi = 1, #line do
                    local tk = K(('tp%d_%d'):format(li, pi))
                    if tk ~= splice then pts[#pts + 1] = P.off(tk, 0, 0, 6.0) end
                    if P.byKey[tk .. 'cbt'] then
                        local cb = { table.unpack(pts) }
                        cb[#cb] = P.off(tk .. 'cbt')
                        P.run('fibre', 'black', cb, { sf = K('splice'), ef = tk .. 'cbt', term = true })
                    end
                end
            end
            -- the house drops off the nearest CBT
            if house and #cbts > 0 then
                local best, bd
                for _, c in ipairs(cbts) do local dd = dist(P.byKey[c], P.byKey[K('csp')]) if not bd or dd < bd then best, bd = c, dd end end
                if bd <= 160 then
                    P.run('fibre', 'black', { P.off(best), F.house.pt(0, -1, 4.5), P.off(K('csp')) }, { sf = best, ef = K('csp'), term = true })
                    P.post[#P.post + 1] = function(id) if IspProvision then pcall(IspProvision, id[K('ont')], 'opsfibre', 'fibre500', name .. ' customer', TAG) end end
                end
            end
        end
    end
    -- for the 400 kV tree: where the line lands at this substation
    S.landing = P.off(K('sub'), 0, 4, 5.5)
    S.subKey = K('sub')
    S.lot = sites.sub
    P.post[#P.post + 1] = function(id)
        if GridAction then GridAction({ action = 'name', key = 'N' .. id[K('sub')], name = name .. ' Substation' }, TAG) end
    end
end

---------------------------------------------------------------------------
-- statewide 400 kV: minimum spanning tree from the station over every substation, pylons every PylonSpacing
---------------------------------------------------------------------------

local function transmissionPlan(nodes, existing)
    local inTree, edges = {}, {}
    for k = 1, math.max(1, existing or 1) do inTree[k] = true end
    for _ = (existing or 1) + 1, #nodes do
        local best, bi, bj
        for i in pairs(inTree) do
            for j = 1, #nodes do
                if not inTree[j] then
                    local dd = dist(nodes[i], nodes[j])
                    if not best or dd < best then best, bi, bj = dd, i, j end
                end
            end
        end
        if not bj then break end
        inTree[bj] = true
        edges[#edges + 1] = { bi, bj }
    end
    return edges
end

---------------------------------------------------------------------------
-- insert, remove
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
    local row = { kind = r.kind, color = r.color, points = pts, length = length,
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

local function chunkDelete(tbl, ids)
    for i = 1, #ids, 400 do
        local c = {}
        for k = i, math.min(#ids, i + 399) do c[#c + 1] = tonumber(ids[k]) end
        MySQL.query.await(('DELETE FROM %s WHERE id IN (%s)'):format(tbl, table.concat(c, ',')))
    end
end

local function removeAll(by)
    if not Built then return nil, 'Nothing built' end
    for _, id in ipairs(Built.runs or {}) do Cabling.runs[id] = nil end
    chunkDelete('opslabs_towers_cables', Built.runs or {})
    for _, id in ipairs(Built.fixtures or {}) do
        if IspFixtureRemoved then pcall(IspFixtureRemoved, id) end
        Cabling.fixtures[id] = nil
    end
    chunkDelete('opslabs_towers_fixtures', Built.fixtures or {})
    if DeleteTowers and #(Built.towers or {}) > 0 then DeleteTowers({ ids = Built.towers }) end
    local n = #(Built.fixtures or {}) + #(Built.runs or {}) + #(Built.towers or {})
    Built = nil
    save()
    if CablingChanged then CablingChanged() end
    TriggerEvent('opslabs-towers:towersChanged')
    Job = { state = 'idle', msg = ('Removed %d item(s)'):format(n), by = by, at = os.time() }
    print(('[%s] removed by %s: %d item(s)'):format(TAG, by or '?', n))
    return true
end

---------------------------------------------------------------------------
-- the build
---------------------------------------------------------------------------

--- ask the surveying client, but never wait forever (they might log off mid-survey) → result or nil
local function ask(name, src, timeoutS, ...)
    local p = promise.new()
    local args = { ... }
    lib.callback(name, src, function(...) p:resolve({ ... }) end, table.unpack(args))
    SetTimeout((timeoutS or 120) * 1000, function() if p.state == 0 then p:resolve(nil) end end)
    local r = Citizen.Await(p)
    return r and r[1] or nil
end

--- before a build (option "clear"): back up and remove the showcase and everything placed before — poles, cable, kit,
--- boxes, masts — in the Danger zone's backup format, so Danger zone → Restore a wipe can bring it back
local function clearOld(by)
    if ShowcaseRemove then pcall(ShowcaseRemove) end
    local F, R, B, Tw = {}, {}, {}, {}
    for id, f in pairs(Cabling.fixtures) do if f.created_by ~= TAG then F[#F + 1] = id end end
    for id, r in pairs(Cabling.runs) do if r.created_by ~= TAG then R[#R + 1] = id end end
    for id in pairs(Cabling.boxes) do B[#B + 1] = id end
    for id, t in pairs(Towers or {}) do if t.notes ~= TAG then Tw[#Tw + 1] = id end end
    local total = #F + #R + #B + #Tw
    if total == 0 then return 0 end
    local function rows(tbl, ids)
        local out = {}
        for i = 1, #ids, 400 do
            local c = {}
            for k = i, math.min(#ids, i + 399) do c[#c + 1] = tonumber(ids[k]) end
            for _, row in ipairs(MySQL.query.await(('SELECT * FROM %s WHERE id IN (%s)'):format(tbl, table.concat(c, ','))) or {}) do out[#out + 1] = row end
        end
        return out
    end
    local name = ('danger_backups/city-clear-%s.json'):format(os.date('%Y%m%d-%H%M%S'))
    local backup = { at = os.time(), by = by, scope = { all = true }, keys = { 'city-clear' }, fixtures = rows('opslabs_towers_fixtures', F),
        runs = rows('opslabs_towers_cables', R), boxes = rows('opslabs_towers_cable_boxes', B), towers = rows('opslabs_towers', Tw) }
    if not SaveResourceFile(GetCurrentResourceName(), name, json.encode(backup), -1) then return nil, 'Couldn’t write the backup — nothing was cleared' end
    local ok, idx = pcall(json.decode, GetResourceKvpString('danger:backups') or '[]')
    idx = ok and type(idx) == 'table' and idx or {}
    table.insert(idx, 1, { file = name, at = backup.at, by = by, n = total, what = 'Cleared before the OPS City build', where = 'whole map' })
    while #idx > 30 do table.remove(idx) end
    SetResourceKvp('danger:backups', json.encode(idx))
    for _, id in ipairs(R) do Cabling.runs[id] = nil end
    chunkDelete('opslabs_towers_cables', R)
    for _, id in ipairs(F) do if IspFixtureRemoved then pcall(IspFixtureRemoved, id) end Cabling.fixtures[id] = nil end
    chunkDelete('opslabs_towers_fixtures', F)
    for _, id in ipairs(B) do Cabling.boxes[id] = nil end
    chunkDelete('opslabs_towers_cable_boxes', B)
    if #Tw > 0 and DeleteTowers then DeleteTowers({ ids = Tw }) end
    print(('[%s] cleared %d old item(s) before building (backup %s)'):format(TAG, total, name))
    return total
end

local function adminOnline()
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        if IsTowerAdmin and IsTowerAdmin(src) then return src end
    end
end

local function run(src)
    busy = true
    Job.state, Job.started, Job.surveyor = 'surveying', os.time(), GetPlayerName(src)
    local systems = Job.systems or {}
    TriggerClientEvent('opslabs-towers:city:warn', src, 'OPS City network: your game is surveying the map — you are hidden and your screen goes dark for a few minutes. Don\'t log off.')
    Wait(4000)
    local P = newPlan()
    local districts, lots = {}, {}
    if Job.extend and Built then for _, x in ipairs(Built.districts or {}) do lots[#lots + 1] = { x = x.x, y = x.y } end end
    local list = CY.Districts or {}
    if Job.extend and Built then
        local have = {}
        for _, x in ipairs(Built.districts or {}) do have[x.name] = true end
        local miss = {}
        for _, d in ipairs(list) do if not have[d.name] then miss[#miss + 1] = d end end
        list = miss
    end
    for i, d in ipairs(list) do
        step(('Surveying %s (%d/%d)'):format(d.name, i, #list), i - 1, #list + 2)
        local S = ask('opslabs-towers:city:district', src, 180,
            { x = d.x, y = d.y, poles = CY.PolesPerLine or 8, spacing = CY.PoleSpacing or 40.0, plots = plotsFor(systems) })
        local ok = S ~= nil
        if ok and type(S) == 'table' and S.sites and S.sites.sub then S.lot = S.sites.sub end
        if ok and type(S) == 'table' and S.diag then
            local miss = {}
            for k, v in pairs(S.diag) do if k ~= 'nodes' and v ~= '' then miss[#miss + 1] = k .. ' (' .. v .. ')' end end
            if #miss > 0 and S.lot then Job.notes = Job.notes or {} table.insert(Job.notes, d.name .. ': no plot for ' .. table.concat(miss, '; ')) end
        end
        -- the surveyor's game isn't answering (left, crashed, old client): stop now rather than keep them in the dark
        if not ok then
            Job.silent = (Job.silent or 0) + 1
            if Job.silent >= 2 then
                ask('opslabs-towers:city:done', src, 10)
                Job.state, Job.msg = 'error', 'The surveying admin\'s game stopped answering — build stopped. Make sure they ran "restart opslabs-towers" (or reconnected) so they have the new client files.'
                busy = false
                return
            end
        else Job.silent = 0 end
        if not ok or type(S) ~= 'table' or S.error or not S.lot then
            Job.skipped = Job.skipped or {}
            table.insert(Job.skipped, d.name .. ': ' .. tostring(ok and type(S) == 'table' and S.error or 'no answer from the surveying admin\'s game'))
        else
            local clash = false
            for _, o in ipairs(lots) do if dist(o, S.lot) < 160 then clash = true end end
            if clash then
                Job.skipped = Job.skipped or {}
                table.insert(Job.skipped, d.name .. ': too close to another district')
            else
                S.systems = systems
                lots[#lots + 1] = S.lot
                districts[#districts + 1] = { d = d, S = S }
            end
        end
        if GetPlayerPing(src) == 0 then break end
    end
    if #districts == 0 then
        ask('opslabs-towers:city:done', src, 10)
        Job.state, Job.msg = 'error', 'No district had a flat, clear lot (or the surveyor left)'
        busy = false
        return
    end
    for i, x in ipairs(districts) do district(P, i, x.d, x.S) end

    -- statewide 400 kV
    step('Surveying the power station and pylon routes', #list, #list + 2)
    local st = CY.Station or { x = 2740.0, y = 1540.0 }
    local nodes, existing = {}, 0
    local function offOf(f, ox, oy, dz) local dx, dy = rot(ox, oy, f.heading or 0) return { x = f.x + dx, y = f.y + dy, z = f.z + dz } end
    if Job.extend and Built then
        -- already built: the station and every substation are in the tree already
        for _, id in ipairs(Built.fixtures or {}) do
            local f = Cabling.fixtures[id]
            if f and f.model == 'opslabs_grid_station' then table.insert(nodes, 1, { x = f.x, y = f.y, land = offOf(f, 25, 7.5, 16) })
            elseif f and f.model == 'opslabs_grid_subbuilding' then nodes[#nodes + 1] = { x = f.x, y = f.y, land = offOf(f, 0, 4, 5.5) } end
        end
        existing = #nodes
    end
    if existing == 0 then
        local sp = ask('opslabs-towers:city:spots', src, 120, { { x = st.x, y = st.y, h = 0.0 } }, 80, 30) or {}
        local stz = sp[1] and sp[1] or { x = st.x, y = st.y, z = 60.0 }
        P.fx('station', 'opslabs_grid_station', stz.x, stz.y, stz.z, 0)
        nodes = { { x = stz.x, y = stz.y, land = P.off('station', 25, 7.5, 16), key = 'station' } }
        existing = 1
    end
    for _, x in ipairs(districts) do nodes[#nodes + 1] = { x = x.S.landing.x, y = x.S.landing.y, land = x.S.landing, key = x.S.subKey } end
    local edges = transmissionPlan(nodes, existing)
    local spacing = CY.PylonSpacing or 300.0
    local pylonN = 0
    for ei, e in ipairs(edges) do
        local a, b = nodes[e[1]], nodes[e[2]]
        local L = dist(a, b)
        local n = math.max(0, math.ceil(L / spacing) - 1)
        local h = math.deg(math.atan(-(b.x - a.x), b.y - a.y)) % 360
        local want = {}
        for k = 1, n do
            local t = k / (n + 1)
            want[#want + 1] = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, h = h }
        end
        local got = #want > 0 and (ask('opslabs-towers:city:spots', src, 60 + #want * 15, want, 40, 10) or {}) or {}
        local prev = a.land
        for k, w in ipairs(want) do
            local g = got[k]
            if g then
                pylonN = pylonN + 1
                local pk = ('py%d_%d'):format(ei, k)
                P.fx(pk, 'opslabs_grid_pylon', g.x, g.y, g.z, h)
                local arm = P.off(pk, 7.5, 0, 18.8)
                P.run('power', 'transmission', { prev, arm })
                prev = arm
            end
        end
        P.run('power', 'transmission', { prev, b.land })
        step(('400 kV line %d/%d (%d pylons so far)'):format(ei, #edges, pylonN), #list + 1, #list + 2)
    end
    ask('opslabs-towers:city:done', src, 10)
    if P.byKey.station then P.post[#P.post + 1] = function(id)
        if not GridAction or not id.station then return end
        GridAction({ action = 'name', key = 'N' .. id.station, name = st.name or 'Palmer-Taylor Power Station' }, TAG)
        for u = 1, (st.units or 3) do GridAction({ action = 'unit_start', id = id.station, unit = u }, TAG) end
    end end

    -- clear what was there before (only now the survey worked)
    if Job.clear then
        step('Removing the showcase and everything placed before (backed up)')
        local n, err = clearOld(Job.by or 'OPS Hub')
        if not n then Job.state, Job.msg = 'error', err busy = false return end
        Job.cleared = n
    end

    -- write it
    Job.state = 'building'
    local total = #P.fixtures + #P.runs + #P.towers
    step(('Building %d pieces of kit, %d cable / pipe runs, %d masts'):format(#P.fixtures, #P.runs, #P.towers), 0, total)
    if not (Job.extend and Built) then Built = { fixtures = {}, runs = {}, towers = {}, districts = {}, at = os.time() } end
    local ids, tids, n = {}, {}, 0
    for _, f in ipairs(P.fixtures) do
        local id = insertFixture(f)
        ids[f.key] = id
        Built.fixtures[#Built.fixtures + 1] = id
        n = n + 1
        if n % 200 == 0 then Job.done = n save() Wait(0) end
    end
    for _, t in ipairs(P.towers) do
        local row = SaveTower and SaveTower(nil, { type = t.type, name = t.name, x = t.x, y = t.y, z = t.z, heading = t.heading, model = t.model,
            exact = true, active = true, notes = TAG }, TAG)
        if row then tids[t.key] = row.id Built.towers[#Built.towers + 1] = row.id end
        n = n + 1
    end
    for _, r in ipairs(P.runs) do
        Built.runs[#Built.runs + 1] = insertRun(r, ids, tids)
        n = n + 1
        if n % 200 == 0 then Job.done = n Wait(0) end
    end
    for _, x in ipairs(districts) do Built.districts[#Built.districts + 1] = { name = x.d.name, x = x.S.lot.x, y = x.S.lot.y } end
    save()
    if CablingChanged then CablingChanged() end
    for _, fn in ipairs(P.post) do local ok, err = pcall(fn, ids) if not ok then print(('[%s] post step failed: %s'):format(TAG, tostring(err))) end end
    if CablingChanged then CablingChanged() end
    TriggerEvent('opslabs-towers:towersChanged')
    Job.state = 'done'
    Job.done, Job.total = total, total
    Job.result = { districts = #districts, fixtures = #Built.fixtures, runs = #Built.runs, towers = #Built.towers, pylons = pylonN }
    step(Job.extend and ('Added %d district(s) to the city network: %d new kit, %d new runs, %d pylons.'):format(#districts, #P.fixtures, #P.runs, pylonN)
        or ('Built %d districts: %d kit, %d runs, %d masts, %d pylons. The station units take ~90 s to come online.'):format(#districts, #Built.fixtures, #Built.runs, #Built.towers, pylonN))
    busy = false
end

--- start (or queue) a build → ok, err
function CityBuildStart(systems, by)
    if busy or Job.state == 'surveying' or Job.state == 'building' then return nil, 'A build is already running' end
    local extend = type(systems) == 'table' and systems.extend == true
    if Built and not extend then return nil, 'A city network is already built — remove it first, or fill in the missing districts' end
    if extend and not Built then extend = false end
    local sys = { internet = true, fuel = true, cctv = true, gunshots = true }
    if type(systems) == 'table' then for k in pairs(sys) do if systems[k] == false then sys[k] = false end end end
    if not sys.internet then sys.gunshots = false end
    Job = { state = 'queued', systems = sys, extend = extend, clear = (not extend) and type(systems) == 'table' and systems.clear == true or false, by = by or 'OPS Hub', queuedAt = os.time(),
        msg = 'Waiting for a tower admin to be in game (they survey the map)' }
    local src = adminOnline()
    if src then CreateThread(function() run(src) end) end
    return true
end

function CityBuildState()
    return { job = Job, built = Built and { at = Built.at, districts = Built.districts, fixtures = #(Built.fixtures or {}), runs = #(Built.runs or {}), towers = #(Built.towers or {}) } or nil,
        districts = #(CY.Districts or {}) }
end

function CityBuildRemove(by)
    if busy then return nil, 'A build is running' end
    return removeAll(by)
end

function CityBuildCancel()
    if Job.state ~= 'queued' then return nil, 'Nothing queued' end
    Job = { state = 'idle', msg = 'Cancelled' }
    return true
end

-- queued: the next tower admin who's in game does the survey
AddEventHandler('playerJoining', function()
    local src = source
    if Job.state ~= 'queued' then return end
    SetTimeout(45000, function()
        if Job.state == 'queued' and not busy and GetPlayerPing(src) > 0 and IsTowerAdmin and IsTowerAdmin(src) then
            TriggerClientEvent('opslabs-towers:city:warn', src, 'OPS City network: a build was queued from OPS Hub — it starts in 20 s. Your screen will go dark while your game surveys the map.')
            SetTimeout(20000, function() if Job.state == 'queued' and not busy then CreateThread(function() run(src) end) end end)
        end
    end)
end)

RegisterCommand('opscity', function(src, args)
    if src > 0 and not IsTowerAdmin(src) then return end
    local a = args[1]
    local function say(t) if src > 0 then TriggerClientEvent('ox_lib:notify', src, { title = TAG, description = t, duration = 9000 }) else print('[' .. TAG .. '] ' .. t) end end
    if a == 'build' then local ok, err = CityBuildStart(nil, src > 0 and GetPlayerName(src) or 'console') say(ok and 'Build started (or queued)' or err)
    elseif a == 'remove' then local ok, err = CityBuildRemove(src > 0 and GetPlayerName(src) or 'console') say(ok and 'Removed' or err)
    else say(('State: %s · %s'):format(Job.state, Job.msg or '')) end
end, false)
