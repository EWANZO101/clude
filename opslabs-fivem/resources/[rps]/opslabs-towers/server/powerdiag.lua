-- San Andreas Power & Light · power fault finder and power restoration kit (Config.PowerTools).
-- Stand at anything electrical — a socket, light, plug-in kit, consumer unit, meter, cut-out, generator, solar inverter,
-- pole / pole transformer, mast, router or ONT — and the fault finder traces its supply back to the source:
--   plug-in kit → the outlet it's plugged into → the consumer unit (through the walls or by cable) → meter / cut-out →
--   service / LV cable → the pole transformer → its pole fuses → 11 kV feeder (reclosers, line faults) → substation
--   (feeder / incomer breakers, plant, fire, maintenance) → 400 kV line → power station (units running)
-- and lists every reason it has no power. The restoration kit (grid crews / engineers) fixes every cause it can —
-- switches, plugs, generators, solar isolators, pole fuses & earths, failed transformers, line faults, tripped / shed /
-- locked-out breakers, substations, generation and equipment faults — and says what still has to be BUILT (missing
-- cable, no consumer unit, no transformer in reach, missing substation plant).

local PT = Config.PowerTools or {}
if PT.Enabled == false then return end
local CM, CP, CG = Config.Mains or {}, Config.Power or {}, Config.Grid or {}
local ONT = (Config.Isp or {}).Ont or 'opslabs_ont'

local NAMES = {
    opslabs_mains_socket2 = 'Double socket', opslabs_mains_socket2_usb = 'Double USB socket', opslabs_mains_socket2_chrome = 'Double socket', opslabs_mains_socket1 = 'Single socket',
    opslabs_mains_socket_out = 'Outdoor socket', opslabs_mains_spur = 'Fused spur', opslabs_mains_switch = 'Light switch', opslabs_mains_ledpanel = 'LED ceiling panel',
    opslabs_mains_batten = 'Batten light', opslabs_mains_ev_wall = 'EV wallbox', opslabs_mains_ev_post = 'EV charge post', opslabs_mains_cu = 'Consumer unit',
    opslabs_mains_cutout = 'Service cut-out', opslabs_mains_meter = 'Electricity meter', opslabs_mains_meterbox = 'Meter box', opslabs_mains_isolator = 'Isolator switch',
    opslabs_mains_generator = 'Generator', opslabs_mains_extension = 'Extension lead', opslabs_mains_reel = 'Cable reel', opslabs_mains_desklamp = 'Desk lamp',
    opslabs_mains_laptopcharger = 'Laptop charger', opslabs_power_transformer = 'Pole transformer', opslabs_power_cutouts = 'Pole cut-outs', opslabs_power_pothead = 'Pothead',
    opslabs_house_pole = 'House pole', opslabs_solar_dciso = 'Solar DC isolator', opslabs_fuel_dispenser = 'Fuel dispenser', opslabs_fuel_canopy = 'Canopy lights', [ONT] = 'ONT',
    opslabs_house_customer = 'House', opslabs_depot = 'Depot', opslabs_exchange_building = 'Exchange building', opslabs_grid_subshell = 'Substation building',
}
local function nameOf(model, id)
    local n = NAMES[model]
    if not n then
        n = tostring(model or 'kit'):gsub('^opslabs_', ''):gsub('^mains_', ''):gsub('^power_', ''):gsub('_', ' ')
        n = n:sub(1, 1):upper() .. n:sub(2)
    end
    return ('%s #%s'):format(n, id)
end

local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function isPole(m) return m and m:find('^opslabs_power_pole') ~= nil end

local function crew(src)
    if CanCable and CanCable(src) then return true end
    local job = FW.Job and FW.Job(src)
    for _, j in ipairs(CG.CrewJobs or {}) do if j == job then return true end end
    return false
end

---------------------------------------------------------------------------
-- the trace
---------------------------------------------------------------------------
-- D = { chain = { { label, ok, note } }, issues = { { code, text, fix, fixable, act } }, seen = {}, keys = {} }
local function issue(D, x)
    local key = x.code .. ':' .. tostring(x.id or x.key or x.text)
    if D.keys[key] then return end
    D.keys[key] = true
    D.issues[#D.issues + 1] = x
end
local function step(D, label, ok, note) D.chain[#D.chain + 1] = { label = label, ok = ok and true or false, note = note } end

local traceFixture, traceTx

--- equipment faults (cabinet power, ONT failure, mast power …) on this fixture / tower
local function faultsOn(D, kind, id)
    for _, f in ipairs(PowerFaults and PowerFaults() or {}) do
        if f.asset and f.asset.kind == kind and tonumber(f.asset.id) == tonumber(id) then
            issue(D, { code = 'fault', id = f.id, text = ('Equipment fault: %s at %s'):format(f.label or f.type, f.location or '?'), fix = 'Repair the equipment', fixable = true })
        end
    end
end

traceTx = function(D, id)
    if D.seen['tx' .. id] then return end
    D.seen['tx' .. id] = true
    local f = Cabling.fixtures[id]
    if not f then return end
    local g = MainsGraph or {}
    local pole = g.txPole and g.txPole[id]
    local live = (not GridTransformerLive or GridTransformerLive(id))
    local ps = pole and PolePowerState and PolePowerState(pole)
    local fusesOut = ps and ps.fusesOut
    step(D, nameOf(f.model, id) .. (pole and (' on pole #' .. pole) or ''), pole and live and not fusesOut, (not pole) and 'not on a pole' or (fusesOut and 'fuses out') or (not live and 'no 11 kV') or '11 kV in, 400 V out')
    if not pole then
        issue(D, { code = 'tx_off_pole', id = id, text = nameOf(f.model, id) .. ' isn’t fitted on a power pole', fix = ('Move it onto a power pole (within %.1f m)'):format(CM.TransformerReach or 0.8) })
        return
    end
    if fusesOut and not GridWhy then
        issue(D, { code = 'fuses_out', id = pole, text = ('The cut-out fuses on pole #%d are out'):format(pole), fix = 'Put the fuses back in', fixable = true })
    end
    if GridWhy and (not live or fusesOut) then
        for _, x in ipairs(GridWhy(id) or {}) do x.grid = true issue(D, x) end
    end
end

--- BFS back through the LV network (cable, joints, poles, kit — and through the walls to the consumer unit) to a source
local function traceGraph(D, id)
    local g = MainsGraph
    if not g then return end
    local fx = Cabling.fixtures
    local start = 'f' .. id
    local prev, q, head, sources = { [start] = false }, { start }, 1, {}
    local function edges(n)
        local list = {}
        for _, m in ipairs(g.adj[n] or {}) do list[#list + 1] = m end
        local fid = tonumber(n:match('^f(%d+)$'))
        local st = fid and MainsState(fid)
        if st and st.cu then list[#list + 1] = 'f' .. st.cu end
        return list
    end
    while head <= #q and #sources < 4 do
        local n = q[head]
        head = head + 1
        for _, m in ipairs(edges(n)) do
            if prev[m] == nil then
                prev[m] = n
                local fid = tonumber(m:match('^f(%d+)$'))
                local f = fid and fx[fid]
                local r = f and MainsRole(f.model)
                if r == 'tx' or r == 'gen' or r == 'inv' then sources[#sources + 1] = { node = m, id = fid, role = r } end
                q[#q + 1] = m
            end
        end
    end
    -- the start itself is a source (a generator / inverter): handled by traceFixture
    if #sources == 0 then
        issue(D, { code = 'no_source', id = id, text = nameOf(fx[id].model, id) .. ' isn’t connected to any supply',
            fix = 'Run LV / service cable from a pole with a transformer to the cut-out → meter → consumer unit (or wire in a generator / solar inverter)' })
        return
    end
    -- what stops each source reaching us: switches off on the way, a dead source
    local function blockers(src)
        local out, n = {}, prev[src.node]
        while n and n ~= start do
            local fid = tonumber(n:match('^f(%d+)$'))
            local f = fid and fx[fid]
            if f and f.data and f.data.off and (CM.Switchable[f.model] or (CM.Wired[f.model] and CM.Wired[f.model].lightSwitch)) then out[#out + 1] = f end
            n = prev[n]
        end
        return out
    end
    local function sourceLive(s)
        local f = fx[s.id]
        if s.role == 'gen' then return f.data and f.data.on == true end
        if s.role == 'inv' then local v = MainsSolarState(s.id) return v ~= nil and v.on == true end
        local st = MainsState(s.id)
        return st and st.live
    end
    local best
    for _, s in ipairs(sources) do if sourceLive(s) then best = s break end end
    local use = best and { best } or { sources[1] }
    for _, s in ipairs(use) do
        local path, n = {}, prev[s.node]
        while n and n ~= start do
            local fid = tonumber(n:match('^f(%d+)$'))
            if fid and fx[fid] then table.insert(path, 1, fid) end
            n = prev[n]
        end
        for _, fid in ipairs(path) do
            local f = fx[fid]
            if not isPole(f.model) then
                local st = MainsState(fid) or {}
                local off = f.data and f.data.off
                step(D, nameOf(f.model, fid), st.live and not off, off and 'switched OFF' or nil)
            else
                step(D, 'Power pole #' .. fid, true, 'LV cable')
            end
        end
        if s.role == 'tx' then traceTx(D, s.id) else traceFixture(D, s.id) end
        for _, f in ipairs(blockers(s)) do
            local what = f.model == CM.ConsumerUnit and 'main switch is OFF (tripped or switched off)' or (CM.Wired[f.model] and CM.Wired[f.model].lightSwitch) and 'is switched off' or 'is switched OFF'
            issue(D, { code = 'switch_off', id = f.id, text = ('%s %s'):format(nameOf(f.model, f.id), what), fix = 'Switch it back on', fixable = true, act = { 'set', f.id, 'off', nil } })
        end
    end
    if #sources > 1 and not best then D.note = ('%d possible supplies reach here — none of them is live'):format(#sources) end
end

traceFixture = function(D, id)
    if D.seen[id] then return end
    D.seen[id] = true
    local f = Cabling.fixtures[id]
    if not f then return end
    local role = MainsRole(f.model)
    local st = MainsState(id) or {}
    local d = f.data or {}
    faultsOn(D, 'fixture', id)
    if role == 'plug' then
        local def = CM.PlugIn[f.model] or {}
        if d.unplugged then
            issue(D, { code = 'unplugged', id = id, text = nameOf(f.model, id) .. ' is unplugged', fix = 'Plug it in', fixable = true, act = { 'set', id, 'unplugged', nil } })
        elseif not st.plug then
            issue(D, { code = 'no_outlet', id = id, text = ('%s has no free socket within reach of its lead (%.1f m)'):format(nameOf(f.model, id), def.reach or 2.0),
                fix = 'Put it next to a socket, extension lead, cable reel or generator' })
        else
            local of = Cabling.fixtures[st.plug[1]]
            step(D, nameOf(f.model, id) .. ' → plugged into ' .. (of and nameOf(of.model, of.id) or '?'), st.live)
            traceFixture(D, st.plug[1])
        end
        if def.switch and d.off then issue(D, { code = 'switch_off', id = id, text = nameOf(f.model, id) .. ' is switched off', fix = 'Switch it on', fixable = true, act = { 'set', id, 'off', nil } }) end
        return
    end
    if role == 'gen' then
        step(D, nameOf(f.model, id), d.on == true, d.on and 'running' or 'stopped')
        if not d.on then issue(D, { code = 'gen_off', id = id, text = nameOf(f.model, id) .. ' isn’t running', fix = 'Start the generator', fixable = true, act = { 'set', id, 'on', true } }) end
        return
    end
    if role == 'inv' then
        local v = MainsSolarState(id)
        step(D, 'Solar inverter #' .. id, v and v.on, v and ((v.gen or 0) > 0 and ('%d W from %d panels'):format(math.floor(v.gen), v.panels or 0) or 'no output') or 'not wired to a consumer unit')
        if not v then
            issue(D, { code = 'inv_no_cu', id = id, text = ('Solar inverter #%d has no consumer unit within %d m'):format(id, CM.AutoWireRadius or 14), fix = 'Fit it near the consumer unit (or cable it)' })
        elseif not v.on then
            if v.isolated then
                for iid, iso in pairs(Cabling.fixtures) do
                    if iso.model == 'opslabs_solar_dciso' and iso.data and iso.data.off and d3(iso, f) <= ((Config.Solar or {}).PanelReach or 30) then
                        issue(D, { code = 'switch_off', id = iid, text = 'The solar DC isolator #' .. iid .. ' is off', fix = 'Switch it on', fixable = true, act = { 'set', iid, 'off', nil } })
                    end
                end
            elseif (v.panels or 0) == 0 then
                issue(D, { code = 'no_panels', id = id, text = 'No solar panels are connected to inverter #' .. id, fix = 'Fit panels within reach of the inverter' })
            elseif not v.soc or v.soc <= 0 then
                issue(D, { code = 'no_sun', id = id, text = 'No sun right now and no battery charge — solar can’t supply until daylight', fix = 'Wait for daylight, add a home battery, or get a grid connection' })
            end
        end
        return
    end
    if role == 'tx' then return traceTx(D, id) end
    if isPole(f.model) then
        local g = MainsGraph or {}
        local any = false
        for tid, pid in pairs(g.txPole or {}) do if pid == id then any = true traceTx(D, tid) end end
        if not any then
            local ps = PolePowerState and PolePowerState(id)
            step(D, 'Power pole #' .. id, not (ps and ps.fusesOut), 'no transformer on it')
            if ps and ps.fusesOut then issue(D, { code = 'fuses_out', id = id, text = ('The fuses on pole #%d are out'):format(id), fix = 'Put the fuses back in', fixable = true }) end
            -- a pole without a transformer is fed by LV cable from another one
            traceGraph(D, id)
        end
        return
    end
    -- wired kit, consumer units, meters, cut-outs, isolators
    local wdef = CM.Wired[f.model]
    local off = d.off
    if off and (CM.Switchable[f.model] or wdef) then
        local what = f.model == CM.ConsumerUnit and 'main switch is OFF (tripped or switched off)' or wdef and wdef.lamp and 'is switched off' or 'is switched OFF'
        issue(D, { code = 'switch_off', id = id, text = ('%s %s'):format(nameOf(f.model, id), what), fix = 'Switch it back on', fixable = true, act = { 'set', id, 'off', nil } })
    end
    step(D, nameOf(f.model, id), st.live and not off, off and 'switched OFF' or (st.live and 'live' or 'dead'))
    if st.live then return end
    if role == 'wired' and st.cu then
        local cu = Cabling.fixtures[st.cu]
        step(D, 'Wired through the walls to ' .. (cu and nameOf(cu.model, cu.id) or '?'), MainsState(st.cu) and MainsState(st.cu).live)
        return traceFixture(D, st.cu)
    end
    if role == 'wired' and not (MainsGraph and MainsGraph.cabled and MainsGraph.cabled[id]) then
        issue(D, { code = 'no_cu', id = id, text = ('%s has no consumer unit within %d m and no cable to one'):format(nameOf(f.model, id), CM.AutoWireRadius or 14),
            fix = 'Fit a consumer unit nearby (same building) and feed it, or run mains cable to it' })
        return
    end
    traceGraph(D, id)
end

--- network kit (masts, routers, access points) — Towers[id]
local function traceTower(D, id)
    local t = Towers and Towers[id]
    if not t then return end
    local info = TowerPowerInfo and TowerPowerInfo(id) or {}
    faultsOn(D, 'tower', id)
    if t.type == 'cell' or not t.model then
        local reach = CP.CellReach or 350
        local best, bd, liveNear = nil, nil, false
        for fid, f in pairs(Cabling.fixtures) do
            if f.model == CM.Transformer then
                local d = d2(f, t)
                if d <= reach then
                    local st = MainsState(fid)
                    if st and st.live then liveNear = true end
                    if not bd or d < bd then best, bd = fid, d end
                end
            end
        end
        step(D, (t.name or ('Mast #' .. id)), liveNear, liveNear and 'on mains' or (info.battery and info.battery > 0 and ('on batteries · %d min left'):format(math.floor(info.battery)) or 'batteries flat'))
        if liveNear then return end
        if not best then
            issue(D, { code = 'no_tx_near', id = id, text = ('No pole transformer within %d m of the mast'):format(reach), fix = 'Build a pole with a transformer near the mast and feed it from the grid' })
        else
            traceTx(D, best)
        end
        return
    end
    -- routers / gateways / switches / access points: a socket in reach (or PoE)
    local poe = (CP.PoEDevices or {})[t.model]
    step(D, t.name or ('Network kit #' .. id), info.powered and true or false, info.powered == 'poe' and 'on PoE' or nil)
    if info.powered then return end
    local reach, best, bd = CP.SocketReach or 3.0, nil, nil
    for _, o in ipairs((MainsGraph or {}).outlets or {}) do
        local d = d3(o.p, t)
        if d <= reach and (not bd or d < bd) then best, bd = o, d end
    end
    if not best then
        issue(D, { code = 'no_socket', id = id, text = ('No socket within %.0f m of %s'):format(reach, t.name or 'it'),
            fix = poe and 'Put a live socket / extension lead beside it, or run CAT6 to a powered PoE switch' or 'Put a live socket, extension lead or generator beside it' })
        return
    end
    traceFixture(D, best.fid)
end

local function traceOnt(D, id)
    local f = Cabling.fixtures[id]
    faultsOn(D, 'fixture', id)
    local powered = not OntPowered or OntPowered(id)
    step(D, 'ONT #' .. id, powered)
    if powered then return end
    local reach, best, bd = CP.SocketReach or 3.0, nil, nil
    for _, o in ipairs((MainsGraph or {}).outlets or {}) do
        local d = d3(o.p, f)
        if d <= reach and (not bd or d < bd) then best, bd = o, d end
    end
    if not best then
        issue(D, { code = 'no_socket', id = id, text = ('No socket within %.0f m of the ONT'):format(reach), fix = 'Put a live socket or extension lead beside the ONT' })
        return
    end
    traceFixture(D, best.fid)
end

--- built buildings (houses, depots, exchanges …): powered by a live consumer unit inside (Config.Power.BuildingReach)
local SUB_BUILDING = { opslabs_grid_subbuilding = true, opslabs_grid_subshell = true }
local function buildingReach(model) return ((CP.BuildingReach or {})[model]) or ((Config.Buildings or {})[model] and 10.0) or nil end
local function traceBuilding(D, f)
    if SUB_BUILDING[f.model] then
        step(D, 'Substation building #' .. f.id, (GlobalState.gridSubsLive or {})[tostring(f.id)] == true, 'station supply from its 11 kV bus')
        if not (GlobalState.gridSubsLive or {})[tostring(f.id)] then
            issue(D, { code = 'sub_dead', id = f.id, text = 'The substation’s 11 kV bus is dead', fix = 'Open Grid control: close its incomer / start generation (the fault finder at a pole transformer it feeds shows the cause)' })
        end
        return
    end
    local reach = buildingReach(f.model) or 10.0
    local best, bd, live = nil, nil, false
    for id, c in pairs(Cabling.fixtures) do
        if c.model == CM.ConsumerUnit and math.abs(c.x - f.x) < reach and math.abs(c.y - f.y) < reach and d3(c, f) < reach + 4.0 then
            local st = MainsState(id)
            if st and st.live and not st.off then live = true end
            local d = d3(c, f)
            if not bd or d < bd then best, bd = id, d end
        end
    end
    step(D, nameOf(f.model, f.id), live, live and 'consumer unit live' or nil)
    if live then return end
    if not best then
        issue(D, { code = 'no_cu_building', id = f.id, text = 'No consumer unit inside this building', fix = ('Fit a consumer unit inside (within %d m of the middle) and feed it from the street (cut-out → meter → consumer unit)'):format(reach) })
        return
    end
    traceFixture(D, best)
end

--- street lights: lit at night by a live pole transformer within 150 m
local function traceStreetLight(D, f)
    local best, bd, live = nil, nil, false
    for id, t in pairs(Cabling.fixtures) do
        if t.model == CM.Transformer then
            local d = d2(t, f)
            if d < 150.0 then
                local st = MainsState(id)
                if st and st.live then live = true end
                if not bd or d < bd then best, bd = id, d end
            end
        end
    end
    step(D, 'Street light #' .. f.id, live, live and ('fed · lights %02d:00–%02d:00'):format((Config.Lighting or {}).On or 19, (Config.Lighting or {}).Off or 7) or nil)
    if live then return end
    if not best then
        issue(D, { code = 'no_tx_light', id = f.id, text = 'No pole transformer within 150 m of this street light', fix = 'Put a transformer on a power pole near it and feed it from the grid' })
        return
    end
    traceTx(D, best)
end

---------------------------------------------------------------------------
-- what is the player looking at
---------------------------------------------------------------------------
local function target(src, wide)
    local p = GetEntityCoords(GetPlayerPed(src))
    local me = { x = p.x, y = p.y, z = p.z }
    local best, bd
    local range = (PT.Range or 4.0) + (wide and 2.0 or 0.0)       -- the handheld repair tool reaches a little further
    for id, f in pairs(Cabling.fixtures) do
        local r = MainsRole and MainsRole(f.model)
        local ok = (r and r ~= 'laptop' and r ~= 'battery' and r ~= 'panel') or f.model == ONT or (FaultEffects and FaultEffects.fixtures[id])
        if ok then
            local d = d3(f, me)
            if r == 'pole' or r == 'tx' then d = d2(f, me) end
            if d <= range and (not bd or d < bd) then best, bd = { kind = 'fixture', id = id, f = f }, d end
        end
    end
    for id, t in pairs(Towers or {}) do
        local d = t.type == 'cell' and d2(t, me) - 10.0 or d3(t, me)
        if d <= range and (not bd or d < bd) then best, bd = { kind = 'tower', id = id, t = t }, d end
    end
    if best then return best end
    -- nothing small in reach: a street light beside you, or the built building you're in / at
    for id, f in pairs(Cabling.fixtures) do
        if f.model:find('^opslabs_streetlight') then
            local d = d2(f, me)
            if d <= range + 3.0 and (not bd or d < bd) then best, bd = { kind = 'light', id = id, f = f }, d end
        else
            local reach = buildingReach(f.model) or (SUB_BUILDING[f.model] and 16.0)
            if reach then
                local d = d2(f, me)
                if d <= reach + 2.0 and math.abs(f.z - me.z) < 8.0 and (not bd or d < bd) then best, bd = { kind = 'building', id = id, f = f }, d end
            end
        end
    end
    return best
end

local function diagnose(tg)
    local D = { chain = {}, issues = {}, seen = {}, keys = {} }
    local label, powered
    if tg.kind == 'building' or tg.kind == 'light' then
        label = tg.kind == 'light' and ('Street light #' .. tg.id) or nameOf(tg.f.model, tg.id)
        if tg.kind == 'light' then traceStreetLight(D, tg.f) else traceBuilding(D, tg.f) end
        powered = D.chain[1] and D.chain[1].ok
    elseif tg.kind == 'tower' then
        label = tg.t.name or ('Mast #' .. tg.id)
        traceTower(D, tg.id)
        local info = TowerPowerInfo and TowerPowerInfo(tg.id) or {}
        powered = info.powered and true or false
        if tg.t.type == 'cell' and powered and FaultEffects and FaultEffects.towers[tg.id] then powered = false end
    elseif tg.f.model == ONT then
        label = 'ONT #' .. tg.id
        traceOnt(D, tg.id)
        powered = (not OntPowered or OntPowered(tg.id)) and not (FaultEffects and FaultEffects.fixtures[tg.id] == 'dead')
    else
        label = isPole(tg.f.model) and ('Power pole #' .. tg.id) or nameOf(tg.f.model, tg.id)
        traceFixture(D, tg.id)
        local r = MainsRole(tg.f.model)
        if r == 'gen' then powered = tg.f.data and tg.f.data.on == true
        elseif r == 'inv' then local v = MainsSolarState(tg.id) powered = v ~= nil and v.on == true
        elseif r == 'pole' then powered = #D.issues == 0
        else local st = MainsState(tg.id) or {} powered = (st.on or (st.live and not st.off)) and true or false end
        if FaultEffects and FaultEffects.fixtures[tg.id] == 'dead' then powered = false end
    end
    -- the chain was built leaf → source in pieces: show it source → leaf
    local chain = {}
    for i = #D.chain, 1, -1 do chain[#chain + 1] = D.chain[i] end
    -- causes: upstream (grid) first, then the building, then the kit itself
    table.sort(D.issues, function(a, b)
        local ra, rb = a.grid and 0 or 1, b.grid and 0 or 1
        if ra ~= rb then return ra < rb end
        return (a.fixable and 0 or 1) > (b.fixable and 0 or 1)
    end)
    return { label = label, powered = powered and #D.issues == 0, chain = chain, issues = D.issues, note = D.note }
end

local function public(R, isCrew)
    local issues = {}
    for _, x in ipairs(R.issues) do issues[#issues + 1] = { text = x.text, fix = x.fix, fixable = x.fixable and true or false, grid = x.grid and true or false } end
    return { label = R.label, powered = R.powered, chain = R.chain, issues = issues, note = R.note, crew = isCrew }
end

---------------------------------------------------------------------------
-- fixing
---------------------------------------------------------------------------
local function apply(x, src)
    local who = GetPlayerName(src) .. ' (on site)'
    if x.act and x.act[1] == 'set' then return MainsSet(x.act[2], x.act[3], x.act[4]) end
    if x.code == 'fuses_out' then if PoleRestore then PoleRestore(x.id) if GridResolve then GridResolve() end return true end return false end
    if x.code == 'fault' then return RepairFault and RepairFault(x.id, src, GetPlayerName(src), 'Power restoration kit') or false end
    if x.grid and GridFix then return GridFix(x, who) ~= nil end
    return false
end

--- server/powerline.lua (Line Tool): the same trace for one piece of kit, without standing at it
function PowerDiagFixture(id, noRecompute)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f then return nil end
    if MainsRecompute and not noRecompute then MainsRecompute() end
    local ok, R = pcall(diagnose, { kind = 'fixture', id = f.id, f = f })
    return ok and public(R, true) or nil
end

lib.callback.register('opslabs-towers:powerdiag:test', function(src)
    if not crew(src) then return { error = 'Only San Andreas Power & Light crews and engineers carry the fault finder' } end
    local tg = target(src)
    if not tg then return { error = 'Nothing electrical within reach — stand at the socket, light, consumer unit, building, street light, pole, mast or router you are testing (GTA’s own buildings aren’t on the grid — only built ones)' } end
    if MainsRecompute then MainsRecompute() end
    return public(diagnose(tg), true)
end)

lib.callback.register('opslabs-towers:powerdiag:fix', function(src, opts)
    if not crew(src) then return { error = 'Only San Andreas Power & Light crews and engineers can restore power' } end
    local tg = target(src, type(opts) == 'table' and opts.tool == true)
    if not tg then return { error = 'Nothing electrical within reach' } end
    local done = {}
    for _ = 1, 6 do                                   -- fixing one cause can reveal the next one upstream
        if MainsRecompute then MainsRecompute() end
        local R = diagnose(tg)
        local any = false
        for _, x in ipairs(R.issues) do
            if x.fixable then
                local ok, err = pcall(apply, x, src)
                if ok and err then done[#done + 1] = x.text .. ' → ' .. (x.fix or 'fixed') any = true
                elseif not ok then print('[opslabs-towers] power restoration: ' .. tostring(err)) end
            end
        end
        if not any then break end
        if GridResolve then GridResolve() end
    end
    if MainsRecompute then MainsRecompute() end
    -- masts, routers and ONTs re-check their supply every 3 s (server/netpower.lua): give it a moment
    if #done > 0 and (tg.kind == 'tower' or (tg.f and tg.f.model == ONT)) then Wait(3500) end
    local R = public(diagnose(tg), true)
    R.done = done
    if #done > 0 then print(('[opslabs-towers] %s restored power at %s: %d fix(es)'):format(GetPlayerName(src), R.label, #done)) end
    return R
end)
