-- OPS Data centres + the OPS Cloud scheduler (Config.DataCentre).
--
-- A data hall = racks, UPS cabinets, generators and CRAC units within SiteRadius of each other. Every Tick seconds:
--   power   a rack runs from the hall's UPS (on mains when it has a socket or a generator, else on battery) or, with no
--           UPS, straight from a socket within PlugReach — no supply, the whole rack is dark
--   heat    every running server adds its watts; each powered CRAC removes its kW. An overloaded hall warms up:
--           servers throttle at TempWarn and shut down at TempShutdown (they come back once it has cooled)
--   network a rack is online with a working ToR switch in it and a CAT6 path from the rack to a router with internet
--   faults  drives, PSUs, fans and boards fail now and then — OPS Data jobs are raised and checked ([E] on the rack)
--   cloud   OPS Cloud VMs (ops_cloud_vms, sold by opslabs-phone server/cloud.lua) are placed on healthy 'cloud' hosts
--           in their region, restarted elsewhere when their host dies, or left host_down / no_capacity
--   roles   compute servers can run OPS Web hosting / DNS / mail instead: once any server has a role, that OPS
--           service is only up while one of them is reachable (ops_dc_status 'platform', read by server/web.lua)

local DC = Config.DataCentre or {}
if not DC.Enabled then return end
local PHONE = 'opslabs-phone'
local KINDS, FAULTS = DC.Kinds or {}, DC.Faults or {}
local CL = {}

Dc = { racks = {}, ups = {}, halls = {}, state = { racks = {}, halls = {} }, vmJobs = {}, hallJobs = {} }
local S = Dc

local function now() return os.time() end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function P(fn, ...)
    if GetResourceState(PHONE) ~= 'started' then return nil end
    local args = { ... }
    local ok, a, b = pcall(function() return exports[PHONE][fn](exports[PHONE], table.unpack(args)) end)
    if ok then return a, b end
    print('[datacentre] ' .. fn .. ': ' .. tostring(a))
end

---------------------------------------------------------------------------
-- persistence
---------------------------------------------------------------------------
local ready = false
MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_dc_racks (
        rack_id INT NOT NULL PRIMARY KEY, name VARCHAR(40) NULL, region VARCHAR(16) NULL, units LONGTEXT NULL, created_at INT NOT NULL DEFAULT 0)]])
    local sql = LoadResourceFile(PHONE, 'sql/ops_cloud.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    local cat = decode(LoadResourceFile(PHONE, 'sql/ops_catalog.json'), {})
    CL = cat.cloud or {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_dc_racks') or {}) do r.units = decode(r.units, {}) S.racks[r.rack_id] = r end
    ready = true
end)

local function rack(id)
    id = tonumber(id)
    local r = S.racks[id]
    if not r then
        r = { rack_id = id, name = nil, region = DC.DefaultRegion or 'LS-1', units = {}, created_at = now() }
        S.racks[id] = r
        MySQL.insert('INSERT IGNORE INTO opslabs_towers_dc_racks (rack_id, region, units, created_at) VALUES (?, ?, ?, ?)', { id, r.region, '[]', now() })
    end
    return r
end
local function saveRack(r)
    MySQL.update('UPDATE opslabs_towers_dc_racks SET name = ?, region = ?, units = ? WHERE rack_id = ?', { r.name, r.region, json.encode(r.units), r.rack_id })
end
local function rackName(r) return r.name or ('Rack %d'):format(r.rack_id) end
local function unitAt(r, u) for _, x in ipairs(r.units) do if x.u == u then return x end end end
local function occupied(r)
    local occ = {}
    for _, x in ipairs(r.units) do
        local k = KINDS[x.kind] or { u = 1 }
        for i = x.u, x.u + k.u - 1 do occ[i] = x end
    end
    return occ
end
local function fits(r, kind, u)
    local k = KINDS[kind]
    if not k or u < 1 or u + k.u - 1 > (DC.Units or 42) then return false end
    local occ = occupied(r)
    for i = u, u + k.u - 1 do if occ[i] then return false end end
    return true
end
local function firstFree(r, kind)
    local k = KINDS[kind]
    if not k then return nil end
    for u = (DC.Units or 42) - k.u + 1, 1, -1 do if fits(r, kind, u) then return u end end
    return nil
end

---------------------------------------------------------------------------
-- the world: halls, power, heat, network
---------------------------------------------------------------------------
local function socketNear(f, reach)
    for _, o in ipairs(LiveOutlets or {}) do if d3(o, f) <= (reach or DC.PlugReach or 3.0) then return true end end
    return false
end

local function graph()
    local fx = Cabling.fixtures
    local adj = {}
    local function link(a, b) if a and b and a ~= b then adj[a] = adj[a] or {} adj[b] = adj[b] or {} adj[a][b] = true adj[b][a] = true end end
    local function endNode(r, which)
        local f, t = r[which .. '_fixture'], r[which .. '_tower']
        if f and fx[f] then return 'f' .. f end
        if t and Towers[t] then return 't' .. t end
        local p = which == 'start' and r.points[1] or r.points[#r.points]
        if not p then return nil end
        for id, x in pairs(fx) do if x.model == DC.Rack and d3(x, p) <= 1.2 then return 'f' .. id end end
        for id, t in pairs(Towers) do if t.z and d3(t, p) <= 0.9 then return 't' .. id end end
        return nil
    end
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and type(r.points) == 'table' and #r.points >= 2 and not (r.loose and next(r.loose)) then link(endNode(r, 'start'), endNode(r, 'end')) end
    end
    return adj
end

local function uplinked(adj, id)
    local seen, q = { ['f' .. id] = true }, { 'f' .. id }
    while #q > 0 do
        local n = table.remove(q)
        local tid = tonumber(n:match('^t(%d+)$'))
        if tid and Uplinked and Uplinked[tid] then return true end
        for m in pairs(adj[n] or {}) do if not seen[m] and m:sub(1, 1) == 't' then seen[m] = true q[#q + 1] = m end end
    end
    return false
end

local function faultFor(kind)
    local k = KINDS[kind] or {}
    if k.switch or k.firewall then return math.random() < 0.6 and 'psu' or 'dead' end
    local roll = math.random()
    return roll < 0.45 and 'disk' or roll < 0.70 and 'fan' or roll < 0.90 and 'psu' or 'dead'
end

local function rackPlace(f, r, extra)
    return { x = f.x, y = f.y, z = f.z, address = ('Data hall %s · %s%s'):format(r.region or '?', rackName(r), extra or '') }
end

local function job(code, f, r, title, verify, extra)
    local id, ref = P('CreatePlatformJob', P('CompanyForRole', 'data') or 'data', code, rackPlace(f, r, extra), { title = title, verify = verify })
    return ref
end

local lastTick = now()
local function compute()
    local t = now()
    local dt = math.max(1, t - lastTick)
    lastTick = t
    local fx = Cabling.fixtures
    local racks, upses, coolers, gens = {}, {}, {}, {}
    for id, f in pairs(fx) do
        if f.model == DC.Rack then racks[id] = f
        elseif f.model == DC.Ups then upses[id] = f
        elseif (DC.Cooling or {})[f.model] then coolers[id] = f
        elseif (DC.Generators or {})[f.model] then gens[id] = f end
    end
    -- halls: racks within SiteRadius chain together
    local parent = {}
    local function find(a) while parent[a] ~= a do parent[a] = parent[parent[a]] a = parent[a] end return a end
    local ids = {}
    for id in pairs(racks) do parent[id] = id ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do for j = i + 1, #ids do
        if d2(racks[ids[i]], racks[ids[j]]) <= (DC.SiteRadius or 25) then parent[find(ids[j])] = find(ids[i]) end
    end end
    local halls = {}
    for _, id in ipairs(ids) do
        local h = find(id)
        halls[h] = halls[h] or { id = h, racks = {}, ups = {}, coolers = {}, gens = {} }
        table.insert(halls[h].racks, id)
    end
    local function inHall(h, f) for _, rid in ipairs(h.racks) do if d2(racks[rid], f) <= (DC.SiteRadius or 25) then return true end end return false end
    for _, h in pairs(halls) do
        for id, f in pairs(upses) do if inHall(h, f) then h.ups[#h.ups + 1] = id end end
        for id, f in pairs(coolers) do if inHall(h, f) then h.coolers[#h.coolers + 1] = id end end
        for id, f in pairs(gens) do if inHall(h, f) then h.gens[#h.gens + 1] = id end end
    end
    local adj = graph()
    local rs, hs = {}, {}
    for hid, h in pairs(halls) do
        local prev = S.halls[hid] or { temp = DC.Ambient or 21 }
        local gen = #h.gens > 0
        -- UPS: on mains if it has a socket (or a generator in the hall)
        local upsMains, upsCharge, nUps = false, 0, #h.ups
        for _, uid in ipairs(h.ups) do
            S.ups[uid] = S.ups[uid] or { charge = 100 }
            if socketNear(upses[uid]) or gen then upsMains = true end
            upsCharge = upsCharge + S.ups[uid].charge
        end
        upsCharge = nUps > 0 and upsCharge / nUps or 0
        local load, cooling, demand = 0, 0, 0     -- demand = what the hall draws with every installed server running
        for _, cid in ipairs(h.coolers) do if socketNear(coolers[cid]) or gen then cooling = cooling + DC.Cooling[coolers[cid].model] end end
        local onBattery = false
        for _, rid in ipairs(h.racks) do
            local f, r = racks[rid], rack(rid)
            local src
            if nUps > 0 then src = upsMains and 'ups' or (upsCharge > 0 and 'battery' or nil) end
            if not src and socketNear(f) then src = 'mains' end
            if src == 'battery' then onBattery = true end
            local st = { id = rid, hall = hid, power = src or 'none', units = {}, temp = prev.temp, region = r.region or DC.DefaultRegion, name = rackName(r), x = f.x, y = f.y, z = f.z }
            local switchOk, switchHot, changed = false, false, false
            for _, x in ipairs(r.units) do
                local k = KINDS[x.kind] or {}
                local us = { u = x.u, kind = x.kind, serial = x.serial, role = x.role, fault = x.fault, off = x.off == true }
                local temp = prev.temp + ((FAULTS[x.fault or ''] or {}).heat or 0) + (k.watts and k.watts > 0 and 3 or 0)
                if src and not x.off and not (x.fault and (FAULTS[x.fault] or {}).down) then demand = demand + (k.watts or 0) / 1000 end
                us.temp = math.floor(temp + 0.5)
                if not src or x.off then us.status = 'off'
                elseif x.fault and (FAULTS[x.fault] or {}).down then us.status = 'down'
                else
                    if x.thermal and temp < (DC.TempWarn or 32) then x.thermal = nil changed = true end
                    if temp >= (DC.TempShutdown or 40) and (k.watts or 0) > 0 then x.thermal = true changed = true end
                    if x.thermal then us.status = 'thermal' if k.switch then switchHot = true end
                    else
                        us.status = (x.fault or temp >= (DC.TempWarn or 32)) and 'degraded' or 'ok'
                        load = load + (k.watts or 0) / 1000
                        if k.switch then switchOk = true end
                    end
                end
                -- wear and tear
                if (us.status == 'ok' or us.status == 'degraded') and not x.fault and (k.watts or 0) > 0
                    and math.random() < (DC.FaultsPerServerHour or 0.01) * dt / 3600 then
                    x.fault, x.fault_at = faultFor(x.kind), t
                    changed = true
                    x.job = job('dc_fault', f, r, ('%s · %s · %s U%d'):format((FAULTS[x.fault] or {}).label or 'Fault', k.label or x.kind, rackName(r), x.u),
                        { kind = 'dc_server', rack = rid, u = x.u, serial = x.serial }, (' · U%d'):format(x.u))
                end
                st.units[#st.units + 1] = us
            end
            if changed then saveRack(r) end
            st.online = src ~= nil and switchOk and uplinked(adj, rid)
            st.netFault = src ~= nil and not st.online and not switchHot             -- a real network problem (not heat / power)
            for _, us in ipairs(st.units) do us.reachable = st.online and (us.status == 'ok' or us.status == 'degraded') end
            rs[rid] = st
        end
        -- heat
        local temp = prev.temp
        local net = load - cooling
        local step
        if load <= 0 then step = -1.5 * dt / 15
        elseif net > 0 then step = math.min(3.0, 0.3 + net * 0.15) * dt / 15
        else step = -1.2 * dt / 15 end
        step = math.max(-6, math.min(6, step))                -- smooth, however long the gap between ticks
        temp = math.max(DC.Ambient or 21, math.min(60, temp + step))
        -- UPS charge
        for _, uid in ipairs(h.ups) do
            local u = S.ups[uid]
            if upsMains then u.charge = math.min(100, u.charge + 2 * dt / 15)
            elseif onBattery then u.charge = math.max(0, u.charge - (load / ((DC.UpsKw or 40) * nUps)) * 100 * dt / ((DC.UpsMinutes or 15) * 60)) end
        end
        hs[hid] = { id = hid, temp = temp, load = load, demand = demand, cooling = cooling, ups = nUps, upsMains = upsMains, charge = upsCharge, battery = onBattery, generator = gen,
            racks = h.racks, region = rs[h.racks[1]] and rs[h.racks[1]].region }
        S.halls[hid] = { temp = temp }
        -- hall-level jobs (once per incident)
        local hj = S.hallJobs[hid] or {}
        S.hallJobs[hid] = hj
        local f1, r1 = racks[h.racks[1]], rack(h.racks[1])
        if temp >= (DC.TempWarn or 32) and load > 0 then
            if not hj.cooling then hj.cooling = job('dc_cooling', f1, r1, ('Data hall %s overheating (%d °C)'):format(r1.region or '', math.floor(temp)), { kind = 'dc_cooling', rack = h.racks[1] }) or true end
        elseif temp < (DC.TempWarn or 32) - 2 then hj.cooling = nil end
        if onBattery then
            if not hj.power then hj.power = job('dc_power', f1, r1, ('Data hall %s on UPS battery'):format(r1.region or ''), { kind = 'dc_power', rack = h.racks[1] }) or true end
        elseif upsMains then hj.power = nil end
        for _, rid in ipairs(h.racks) do
            local st = rs[rid]
            local key = 'net' .. rid
            if st.netFault and #st.units > 0 then
                if not hj[key] then hj[key] = job('dc_network', racks[rid], rack(rid), ('%s offline'):format(st.name), { kind = 'dc_network', rack = rid }) or true end
            elseif st.online then hj[key] = nil end
        end
    end
    S.state = { racks = rs, halls = hs, at = t }
end

---------------------------------------------------------------------------
-- OPS Cloud: place VMs on hosts
---------------------------------------------------------------------------
local function hosts()
    local list = {}
    for rid, st in pairs(S.state.racks or {}) do
        for _, us in ipairs(st.units) do
            local k = KINDS[us.kind] or {}
            if k.compute and us.reachable and (us.role or 'cloud') == 'cloud' then
                list[#list + 1] = { rack = rid, u = us.u, region = st.region, vcpu = k.vcpu * (CL.overcommit or 2), ram = k.ram, usedC = 0, usedR = 0, name = st.name, degraded = us.status == 'degraded' }
            end
        end
    end
    table.sort(list, function(a, b) return a.rack == b.rack and a.u > b.u or a.rack < b.rack end)
    return list
end

local BOOT = {
    opsweb = { 'nginx 1.27 started', 'OPS Web agent connected — ready to host your site' },
    ubuntu = { 'Ubuntu 24.04 LTS', 'cloud-init finished' }, debian = { 'Debian GNU/Linux 12', 'cloud-init finished' },
    rocky = { 'Rocky Linux 9', 'cloud-init finished' }, windows = { 'Windows Server 2025', 'Remote Desktop ready' },
}

local function vmLog(vm, lines)
    local log = decode(vm.log, {})
    local stamp = os.date('!%Y-%m-%d %H:%M:%S')
    for _, l in ipairs(lines) do log[#log + 1] = stamp .. '  ' .. l end
    while #log > 40 do table.remove(log, 1) end
    vm.log = json.encode(log)
end

local capJobAt = {}
local function schedule()
    local ok, vms = pcall(MySQL.query.await, "SELECT * FROM ops_cloud_vms WHERE status <> 'cancelled' ORDER BY id")
    if not ok or not vms then return end
    local hs = hosts()
    local byKey = {}
    for _, h in ipairs(hs) do byKey[h.rack .. ':' .. h.u] = h end
    local function fit(h, vm) return h.region == vm.region and h.vcpu - h.usedC >= vm.vcpu and h.ram - h.usedR >= vm.ram_gb end
    local function take(h, vm) h.usedC = h.usedC + vm.vcpu h.usedR = h.usedR + vm.ram_gb end
    -- keep VMs where they are first, then place the rest
    local pending = {}
    for _, vm in ipairs(vms) do
        local h = vm.host_rack and byKey[vm.host_rack .. ':' .. (vm.host_u or 0)]
        if vm.status == 'active' and vm.desired == 'running' and h and h.region == vm.region and vm.state == 'running' then take(h, vm) vm._host = h
        else pending[#pending + 1] = vm end
    end
    local starved = {}
    for _, vm in ipairs(pending) do
        local wasHost, wasState = vm.host_rack, vm.state
        local newState, h = vm.state, nil
        if vm.status ~= 'active' then newState = 'suspended'
        elseif vm.desired ~= 'running' then newState = 'stopped'
        else
            local best
            for _, c in ipairs(hs) do if fit(c, vm) and (not best or (c.ram - c.usedR) > (best.ram - best.usedR)) then best = c end end
            if best then take(best, vm) h = best newState = 'running'
            else newState = wasHost and wasState == 'running' and 'host_down' or (wasState == 'host_down' and 'host_down' or 'no_capacity') starved[vm.region] = true end
        end
        local lines = {}
        local moved = h and wasHost and (vm.host_rack ~= h.rack or vm.host_u ~= h.u)
        if newState == 'running' and (wasState ~= 'running' or moved) then
            if wasState == 'host_down' or (moved and wasState == 'running') then lines[#lines + 1] = ('Host failure — restarted on %s U%d'):format(h.name, h.u) end
            lines[#lines + 1] = 'Booting on ' .. h.name .. ' U' .. h.u
            for _, l in ipairs(BOOT[vm.image] or {}) do lines[#lines + 1] = l end
        elseif newState ~= wasState then
            lines[#lines + 1] = ({ host_down = 'Host failure — waiting for a healthy host', no_capacity = 'No capacity in ' .. vm.region .. ' — queued', stopped = 'Shut down', suspended = 'Suspended (billing)' })[newState] or newState
        end
        if newState ~= wasState or (h and (vm.host_rack ~= h.rack or vm.host_u ~= h.u)) or (not h and wasHost) then
            if #lines > 0 then vmLog(vm, lines) end
            MySQL.update('UPDATE ops_cloud_vms SET state = ?, host_rack = ?, host_u = ?, state_at = ?, booted_at = IF(? = 1, ?, booted_at), log = ? WHERE id = ?',
                { newState, h and h.rack, h and h.u, now(), newState == 'running' and wasState ~= 'running' and 1 or 0, now(), vm.log, vm.id })
            if vm.identifier and (newState == 'host_down' or (newState == 'running' and wasState == 'host_down')) then
                P('NotifyIdentifier', vm.identifier, { app = 'browser', title = 'OPS Cloud · ' .. vm.name, icon = 'fa-cloud',
                    body = newState == 'running' and 'Back online — restarted on a healthy host.' or 'Your server is down: its host failed and there was no room to restart it. OPS Data has been alerted.' })
            end
        end
    end
    -- capacity per region
    local cap = {}
    for _, h in ipairs(hs) do
        local c = cap[h.region] or { vcpu = 0, ram = 0, usedVcpu = 0, usedRam = 0, hosts = 0 }
        c.vcpu, c.ram, c.usedVcpu, c.usedRam, c.hosts = c.vcpu + h.vcpu, c.ram + h.ram, c.usedVcpu + h.usedC, c.usedRam + h.usedR, c.hosts + 1
        cap[h.region] = c
    end
    for region in pairs(starved) do cap[region] = cap[region] or { vcpu = 0, ram = 0, usedVcpu = 0, usedRam = 0, hosts = 0 } end
    for region, c in pairs(cap) do
        c.waiting = starved[region] and true or false
        local tight = starved[region] or (c.ram > 0 and c.usedRam / c.ram > 0.9)
        if tight and (now() - (capJobAt[region] or 0)) > 7200 then
            for rid, st in pairs(S.state.racks or {}) do
                if st.region == region then
                    capJobAt[region] = now()
                    job('dc_capacity', Cabling.fixtures[rid], rack(rid), ('Add cloud capacity in %s'):format(region), { kind = 'dc_install', region = region, count = 2 })
                    break
                end
            end
        end
    end
    S.capacity = cap
end

---------------------------------------------------------------------------
-- for everyone else: ops_dc_status (OPS Cloud sales, OPS Web, opsdata.sa, OPS Hub)
---------------------------------------------------------------------------
local lastPub, lastPubAt = {}, {}
local function publish(k, v)
    local s = json.encode(v)
    if lastPub[k] == s and now() - (lastPubAt[k] or 0) < 60 then return end     -- still refresh: readers treat old rows as stale
    lastPub[k], lastPubAt[k] = s, now()
    MySQL.query('INSERT INTO ops_dc_status (k, v, updated_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v), updated_at = VALUES(updated_at)', { k, s, now() })
end

local function platform()
    local roles = {}
    for role in pairs(DC.Roles or {}) do if role ~= 'cloud' then roles[role] = { up = 0, total = 0 } end end
    for _, st in pairs(S.state.racks or {}) do
        for _, us in ipairs(st.units) do
            if us.role and roles[us.role] then
                roles[us.role].total = roles[us.role].total + 1
                if us.reachable then roles[us.role].up = roles[us.role].up + 1 end
            end
        end
    end
    return roles
end

local function summary()
    local halls = {}
    for hid, h in pairs(S.state.halls or {}) do
        local units, bad = 0, 0
        for _, rid in ipairs(h.racks) do
            for _, us in ipairs(((S.state.racks or {})[rid] or {}).units or {}) do
                if (KINDS[us.kind] or {}).watts and KINDS[us.kind].watts > 0 then units = units + 1 if not us.reachable then bad = bad + 1 end end
            end
        end
        halls[#halls + 1] = { id = hid, region = h.region, temp = math.floor(h.temp * 10) / 10, load = math.floor(h.load * 10) / 10, cooling = h.cooling, racks = #h.racks,
            power = h.battery and 'battery' or (h.ups > 0 and 'ups' or 'mains'), charge = math.floor(h.charge), servers = units, down = bad }
    end
    table.sort(halls, function(a, b) return a.id < b.id end)
    return halls
end

-- client props: what is in each rack and its LED
local lastRacks
local function syncClients()
    local out = {}
    for rid, st in pairs(S.state.racks or {}) do
        local list = {}
        for _, us in ipairs(st.units) do
            local led = (us.status == 'off') and 0 or ((us.status == 'down' or us.status == 'thermal') and 3 or ((us.status == 'degraded' or not us.reachable) and 2 or 1))
            list[#list + 1] = { us.u, us.kind, led }
        end
        out[tostring(rid)] = list
    end
    local s = json.encode(out)
    if s ~= lastRacks then lastRacks = s GlobalState.opsDcRacks = out end
end

CreateThread(function()
    while not ready or not Cabling or not Towers do Wait(1000) end
    Wait(12000)
    while true do
        local ok, err = pcall(function()
            compute()
            schedule()
            syncClients()
            publish('platform', platform())
            publish('capacity', S.capacity or {})
            publish('halls', summary())
        end)
        if not ok then print('^1[opslabs-towers] data centre: ' .. tostring(err) .. '^7') end
        Wait((DC.Tick or 15) * 1000)
    end
end)

---------------------------------------------------------------------------
-- players at the rack
---------------------------------------------------------------------------
local function isStaff(src) return src == 0 or (IsTowerAdmin and IsTowerAdmin(src)) or (CanCable and CanCable(src)) end
local function near(src, f, r) local p = GetEntityCoords(GetPlayerPed(src)) return d3(p, f) <= (r or 4.0) end
local function rackView(rid)
    local f = Cabling.fixtures[rid]
    if not f or f.model ~= DC.Rack then return nil end
    local r = rack(rid)
    local st = (S.state.racks or {})[rid] or { units = {}, power = 'none' }
    local h = (S.state.halls or {})[st.hall] or {}
    local vms = {}
    local ok, rows = pcall(MySQL.query.await, "SELECT host_u, COUNT(*) n FROM ops_cloud_vms WHERE host_rack = ? AND state = 'running' GROUP BY host_u", { rid })
    for _, x in ipairs(ok and rows or {}) do vms[x.host_u] = x.n end
    local units = {}
    for _, us in ipairs(st.units) do
        local k = KINDS[us.kind] or {}
        local x = unitAt(r, us.u) or {}
        units[#units + 1] = { u = us.u, size = k.u or 1, kind = us.kind, label = k.label or us.kind, serial = us.serial, role = us.role, status = us.status, reachable = us.reachable,
            temp = us.temp, fault = us.fault, faultLabel = us.fault and (FAULTS[us.fault] or {}).label, fix = us.fault and (FAULTS[us.fault] or {}).fix, secs = us.fault and (FAULTS[us.fault] or {}).secs,
            vms = vms[us.u] or 0, off = us.off, compute = k.compute == true, installed = x.installed_at, by = x.installed_by }
    end
    table.sort(units, function(a, b) return a.u > b.u end)
    return { id = rid, name = rackName(r), region = r.region, power = st.power, online = st.online, temp = h.temp and math.floor(h.temp * 10) / 10, load = h.load, cooling = h.cooling,
        ups = h.ups, charge = h.charge and math.floor(h.charge), units = units, free = (DC.Units or 42) - (function() local n = 0 for _ in pairs(occupied(r)) do n = n + 1 end return n end)() }
end

lib.callback.register('opslabs-towers:dc:rack', function(src, rid)
    local v = rackView(tonumber(rid))
    if v then v.staff = isStaff(src) v.kinds = KINDS v.roles = DC.Roles end
    return v
end)

local function act(src, rid, fn)
    rid = tonumber(rid)
    local f = Cabling.fixtures[rid]
    if not f or f.model ~= DC.Rack then return { error = 'No rack' } end
    if not isStaff(src) then return { error = 'Only OPS Data engineers can work on the racks' } end
    if src ~= 0 and not near(src, f, 4.0) then return { error = 'Stand at the rack' } end
    local r = rack(rid)
    local res = fn(r, f)
    saveRack(r)
    return res or { ok = true }
end

local function who(src) return src == 0 and 'console' or GetPlayerName(src) end

lib.callback.register('opslabs-towers:dc:install', function(src, rid, kind, u)
    return act(src, rid, function(r)
        if not KINDS[kind] then return { error = 'Unknown kit' } end
        u = tonumber(u) or firstFree(r, kind)
        if not u or not fits(r, kind, u) then return { error = 'No room in the rack for that' } end
        local unit = { u = u, kind = kind, serial = ('HLC-%06X'):format(math.random(0, 0xffffff)), installed_at = now(), installed_by = who(src) }
        if KINDS[kind].compute then unit.role = 'cloud' end
        r.units[#r.units + 1] = unit
        return { ok = true, u = u, serial = unit.serial }
    end)
end)

lib.callback.register('opslabs-towers:dc:remove', function(src, rid, u)
    return act(src, rid, function(r)
        for i, x in ipairs(r.units) do if x.u == tonumber(u) then table.remove(r.units, i) return { ok = true } end end
        return { error = 'Nothing there' }
    end)
end)

lib.callback.register('opslabs-towers:dc:repair', function(src, rid, u)
    return act(src, rid, function(r)
        local x = unitAt(r, tonumber(u))
        if not x or not x.fault then return { error = 'Nothing to fix' } end
        x.fault, x.fault_at, x.job, x.repaired_at, x.repaired_by = nil, nil, nil, now(), who(src)
        return { ok = true }
    end)
end)

lib.callback.register('opslabs-towers:dc:power', function(src, rid, u, on)
    return act(src, rid, function(r)
        local x = unitAt(r, tonumber(u))
        if not x then return { error = 'Nothing there' } end
        x.off = not on or nil
        return { ok = true }
    end)
end)

lib.callback.register('opslabs-towers:dc:role', function(src, rid, u, role)
    return act(src, rid, function(r)
        local x = unitAt(r, tonumber(u))
        if not x or not (KINDS[x.kind] or {}).compute then return { error = 'Only compute servers have a role' } end
        if not (DC.Roles or {})[role] then return { error = 'Unknown role' } end
        x.role = role
        return { ok = true }
    end)
end)

lib.callback.register('opslabs-towers:dc:config', function(src, rid, name, region)
    return act(src, rid, function(r)
        r.name = name and tostring(name):sub(1, 40) ~= '' and tostring(name):sub(1, 40) or nil
        local reg = tostring(region or ''):upper():gsub('[^A-Z0-9%-]', ''):sub(1, 16)
        if reg ~= '' then r.region = reg end
        return { ok = true }
    end)
end)

---------------------------------------------------------------------------
-- job checks (platformhooks.lua)
---------------------------------------------------------------------------
function DcVerify(v, x, y, z, snap, who)
    local kind = v.kind
    local st = S.state.racks or {}
    if kind == 'dc_server' then
        local rs = st[tonumber(v.rack)]
        local r = S.racks[tonumber(v.rack)]
        local unit = r and unitAt(r, tonumber(v.u))
        if not unit or unit.serial ~= v.serial then return { ok = true, have = 1, need = 1, label = 'Server replaced / removed' } end
        local us
        for _, q in ipairs(rs and rs.units or {}) do if q.u == unit.u then us = q end end
        local ok = not unit.fault and us and us.reachable
        return { ok = ok == true, have = ok and 1 or 0, need = 1, label = 'Server fixed and back online',
            detail = unit.fault and ((FAULTS[unit.fault] or {}).label .. ' — [E] on the rack → the server → Repair') or (us and us.status or 'not running') }
    elseif kind == 'dc_cooling' or kind == 'dc_power' then
        local rs = st[tonumber(v.rack)]
        local h = rs and (S.state.halls or {})[rs.hall]
        if not h then return { ok = false, have = 0, need = 1, label = 'Data hall not found' } end
        if kind == 'dc_cooling' then
            local need = math.max(h.load, h.demand or 0)
            local ok = h.temp < (DC.TempWarn or 32) and h.cooling >= need
            return { ok = ok, have = math.floor(h.cooling), need = math.ceil(need), label = ('Cooling %d kW for %.1f kW of servers · %d °C'):format(h.cooling, need, math.floor(h.temp)) }
        end
        local ok = h.upsMains or (h.ups == 0 and rs.power == 'mains')
        return { ok = ok, have = ok and 1 or 0, need = 1, label = ok and 'On mains' or ('On battery · %d%%'):format(math.floor(h.charge or 0)), detail = 'Give the UPS a live socket within 3 m, or a generator in the hall' }
    elseif kind == 'dc_network' then
        local rs = st[tonumber(v.rack)]
        local ok = rs and rs.online
        return { ok = ok == true, have = ok and 1 or 0, need = 1, label = 'Rack online', detail = 'Working ToR switch in the rack + CAT6 from the rack to a router with internet' }
    elseif kind == 'dc_install' then
        local n = 0
        for rid, rs in pairs(st) do
            local r = S.racks[rid]
            if (not v.region or rs.region == v.region) and r then
                for _, us in ipairs(rs.units) do
                    local unit = unitAt(r, us.u)
                    if (KINDS[us.kind] or {}).compute and us.reachable and (us.role or 'cloud') == 'cloud' and unit and (unit.installed_at or 0) >= (snap.at or 0) then n = n + 1 end
                end
            end
        end
        return { ok = n >= (v.count or 2), have = n, need = v.count or 2, label = ('New cloud servers online in %s'):format(v.region or 'the region') }
    end
    return { ok = false, have = 0, need = 1, label = 'Unknown check ' .. tostring(kind) }
end

---------------------------------------------------------------------------
-- OPS Hub (server/api.lua)
---------------------------------------------------------------------------
function DcState()
    local racks = {}
    for rid in pairs(S.state.racks or {}) do racks[#racks + 1] = rackView(rid) end
    table.sort(racks, function(a, b) return a.id < b.id end)
    return { racks = racks, halls = summary(), capacity = S.capacity or {}, platform = platform(), roles = DC.Roles, kinds = KINDS, faults = FAULTS,
        tempWarn = DC.TempWarn, tempShutdown = DC.TempShutdown, at = S.state.at }
end

function DcAction(rid, d, actor)
    rid = tonumber(rid)
    local f = rid and Cabling.fixtures[rid]
    if not f or f.model ~= DC.Rack then return false, 'No rack' end
    local r = rack(rid)
    local x = d.u and unitAt(r, tonumber(d.u))
    if d.action == 'config' then
        r.name = d.name and tostring(d.name):sub(1, 40) ~= '' and tostring(d.name):sub(1, 40) or nil
        local reg = tostring(d.region or ''):upper():gsub('[^A-Z0-9%-]', ''):sub(1, 16)
        if reg ~= '' then r.region = reg end
    elseif d.action == 'role' then
        if not x or not (KINDS[x.kind] or {}).compute or not (DC.Roles or {})[d.role] then return false, 'Bad role' end
        x.role = d.role
    elseif d.action == 'power' then
        if not x then return false, 'Nothing there' end
        x.off = d.on ~= true or nil
    elseif d.action == 'clear' then
        if not x then return false, 'Nothing there' end
        x.fault, x.fault_at, x.job = nil, nil, nil
    elseif d.action == 'fault' then          -- staff testing: break a server on purpose
        if not x or not FAULTS[d.fault] then return false, 'Bad fault' end
        x.fault, x.fault_at = d.fault, now()
        x.job = job('dc_fault', f, r, ('%s · %s · %s U%d'):format(FAULTS[d.fault].label, (KINDS[x.kind] or {}).label or x.kind, rackName(r), x.u),
            { kind = 'dc_server', rack = rid, u = x.u, serial = x.serial }, (' · U%d'):format(x.u))
    else
        return false, 'Unknown action'
    end
    saveRack(r)
    print(('[opslabs-towers] data centre: %s %s on %s'):format(actor or '?', d.action, rackName(r)))
    return true
end
exports('DcState', DcState)
exports('DcAction', DcAction)
