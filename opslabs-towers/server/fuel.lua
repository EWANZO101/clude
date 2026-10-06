-- OPS Fuel (Config.Fuel): fuel stations built in game.
--   tanker → (earth) → fill point → fill pipe → underground tank (vent pipe → vent stack)
--   tank → product pipe → dispenser (powered, authorised by a powered tank gauge / pump controller) → nozzle → vehicle
-- Pipes are cable runs of kind 'pipe' (colour = product, or 'vent'); a pipe end within PipeReach of fuel kit connects
-- to it, two ends of the same pipe that close are jointed. Stations = the kit around each tank gauge (StationRadius).
-- State (tank contents, prices, e-stops, sales, deliveries, tanker loads) lives in opslabs_towers_fuel.

local CF = Config.Fuel or {}
if not CF.Enabled then return end
local PROD = CF.Products or {}

local S = { tanks = {}, stations = {}, loads = {}, breakaway = {}, earthed = {}, seq = 0 }
local Net = { sells = {}, fills = {}, vented = {}, station = {}, kit = {} }
local dirty, saveDue = true, false

local function now() return os.time() end
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function dist2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
local function fx(id) return Cabling.fixtures[tonumber(id) or -1] end
local function kindOf(model)
    if CF.Tanks[model] then return 'tank' end
    if model == CF.Dispenser then return 'disp' end
    if model == CF.FillPoint then return 'fill' end
    if model == CF.Vent then return 'vent' end
    if model == CF.Controller then return 'atg' end
    if model == CF.EStop then return 'estop' end
    if model == CF.Gantry then return 'gantry' end
    return nil
end
local function powered(id) local s = MainsState and MainsState(id) return s and s.on or false end
local function save() saveDue = true end

---------------------------------------------------------------------------
-- persistence
---------------------------------------------------------------------------
MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_fuel` (`k` VARCHAR(32) NOT NULL PRIMARY KEY, `v` LONGTEXT NOT NULL)]])
    local row = MySQL.scalar.await('SELECT v FROM opslabs_towers_fuel WHERE k = ?', { 'state' })
    local d = row and json.decode(row)
    if type(d) == 'table' then
        for _, k in ipairs({ 'tanks', 'stations', 'loads', 'breakaway' }) do
            local t = {}
            for key, v in pairs(d[k] or {}) do t[tonumber(key) or key] = v end
            S[k] = t
        end
        S.seq = tonumber(d.seq) or 0
    end
    dirty = true
end)
CreateThread(function()
    while true do
        Wait(15000)
        if saveDue then
            saveDue = false
            MySQL.update('INSERT INTO opslabs_towers_fuel (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)',
                { 'state', json.encode({ tanks = S.tanks, stations = S.stations, loads = S.loads, breakaway = S.breakaway, seq = S.seq }) })
        end
    end
end)

---------------------------------------------------------------------------
-- the pipe network
---------------------------------------------------------------------------
function FuelDirty() dirty = true end

local function tankState(id)
    local f = fx(id)
    local def = f and CF.Tanks[f.model]
    if not def then return nil end
    local t = S.tanks[id]
    if not t then
        t = { litres = 0.0, water = 0, temp = 18.0, leak = false, book = 0.0 }
        S.tanks[id] = t
    end
    return t, def
end

local function rebuild()
    dirty = false
    local kit = {}
    for id, f in pairs(Cabling.fixtures) do
        local k = kindOf(f.model)
        if k then kit[id] = k; if k == 'tank' then tankState(id) end end
    end
    for id in pairs(S.tanks) do if not kit[id] then S.tanks[id] = nil end end
    -- union-find over pipe runs, per colour; fixtures join the run's group
    local parent = {}
    local function find(x) while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end return x end
    local function union(a, b) a, b = find(a), find(b) if a ~= b then parent[a] = b end end
    local ends, reach = {}, CF.PipeReach or 1.5
    for rid, r in pairs(Cabling.runs) do
        if r.kind == 'pipe' and type(r.points) == 'table' and #r.points >= 2 then
            local node = 'r' .. rid
            parent[node] = node
            for _, p in ipairs({ r.points[1], r.points[#r.points] }) do
                ends[#ends + 1] = { node = node, color = r.color, p = p }
                for id, k in pairs(kit) do
                    local f = Cabling.fixtures[id]
                    if k ~= 'atg' and k ~= 'estop' and k ~= 'gantry' and math.abs(f.x - p.x) < reach + 3 and math.abs(f.y - p.y) < reach + 3 then
                        -- dispensers sit on an island and big tanks are big: measure to the footprint, roughly
                        local extra = (k == 'disp' and 0.6) or (f.model == 'opslabs_fuel_tank_agt' and 2.4) or (k == 'fill' and 0.5) or 0
                        if dist2(f, p) <= reach + extra and math.abs((p.z or f.z) - f.z) < 4.0 then
                            local fnode = r.color .. ':' .. id
                            parent[fnode] = parent[fnode] or fnode
                            union(node, fnode)
                        end
                    end
                end
            end
        end
    end
    for i = 1, #ends do
        for j = i + 1, #ends do
            local a, b = ends[i], ends[j]
            if a.color == b.color and a.node ~= b.node and dist(a.p, b.p) <= (CC_JOINT or 0.5) then union(a.node, b.node) end
        end
    end
    local groups = {}            -- root -> { color, members = { id = kind } }
    for node in pairs(parent) do
        local col, id = node:match('^(%a+):(%d+)$')
        if col then
            local root = find(node)
            groups[root] = groups[root] or { color = col, m = {} }
            groups[root].m[tonumber(id)] = kit[tonumber(id)]
        end
    end
    local sells, fills, vented = {}, {}, {}
    for _, g in pairs(groups) do
        if g.color == 'vent' then
            local hasStack = false
            for _, k in pairs(g.m) do if k == 'vent' then hasStack = true end end
            if hasStack then for id, k in pairs(g.m) do if k == 'tank' then vented[id] = true end end end
        else
            local tanks = {}
            for id, k in pairs(g.m) do
                local f = Cabling.fixtures[id]
                if k == 'tank' and CF.Tanks[f.model].product == g.color then tanks[#tanks + 1] = id end
            end
            table.sort(tanks)
            if #tanks > 0 then
                for id, k in pairs(g.m) do
                    if k == 'disp' then
                        sells[id] = sells[id] or {}
                        sells[id][g.color] = sells[id][g.color] or {}
                        for _, t in ipairs(tanks) do table.insert(sells[id][g.color], t) end
                    elseif k == 'fill' then
                        fills[id] = fills[id] or {}
                        fills[id][g.color] = fills[id][g.color] or {}
                        for _, t in ipairs(tanks) do table.insert(fills[id][g.color], t) end
                    end
                end
            end
        end
    end
    -- stations: every kit item belongs to the nearest tank gauge within StationRadius
    local station = {}
    for id, k in pairs(kit) do
        if k ~= 'gantry' then
            local f, best, bd = Cabling.fixtures[id], nil, nil
            for cid, ck in pairs(kit) do
                if ck == 'atg' then
                    local d = dist2(f, Cabling.fixtures[cid])
                    if d <= (CF.StationRadius or 70) and (not bd or d < bd) then best, bd = cid, d end
                end
            end
            station[id] = best
        end
    end
    for cid, k in pairs(kit) do
        if k == 'atg' and not S.stations[cid] then S.stations[cid] = { prices = {}, estop = false, sales = {}, deliveries = {}, alarms = {}, name = nil } end
    end
    for cid in pairs(S.stations) do if kit[cid] ~= 'atg' then S.stations[cid] = nil end end
    Net = { sells = sells, fills = fills, vented = vented, station = station, kit = kit }
end

local function stationOf(id) if dirty then rebuild() end return Net.station[id] end
local function price(cid, p)
    local st = S.stations[cid]
    return (st and st.prices and tonumber(st.prices[p])) or (PROD[p] and PROD[p].price) or 1.5
end
local function stationName(cid)
    local st, f = S.stations[cid], fx(cid)
    return (st and st.name) or ('OPS Fuel #' .. cid)
end
local function log(list, entry, max)
    table.insert(list, 1, entry)
    while #list > (max or 40) do table.remove(list) end
end
local function alarm(cid, text)
    local st = S.stations[cid]
    if not st then return end
    st.alarms = st.alarms or {}
    for _, a in ipairs(st.alarms) do if a.text == text then return end end
    log(st.alarms, { at = now(), text = text }, 20)
    save()
end

--- why a dispenser can't sell right now (nil = it can)
local function dispenserFault(id)
    if dirty then rebuild() end
    local cid = Net.station[id]
    if not powered(id) then return 'No power at the dispenser' end
    if not cid then return 'No pump controller — fit a tank gauge / pump controller (ATG) in the shop' end
    if not powered(cid) then return 'Pump controller has no power' end
    if S.stations[cid] and S.stations[cid].estop then return 'EMERGENCY STOP is active — reset it at the tank gauge' end
    if S.breakaway[id] then return 'Breakaway coupling parted — reset it at this dispenser' end
    return nil
end

local function available(id, p)
    local total, list = 0.0, {}
    for _, t in ipairs(((Net.sells[id] or {})[p]) or {}) do
        local ts = S.tanks[t]
        if ts and not ts.leak and (ts.water or 0) < 2 then total = total + ts.litres; list[#list + 1] = t end
    end
    return total, list
end

---------------------------------------------------------------------------
-- dispensing
---------------------------------------------------------------------------
local Pumping = {}        -- src -> { disp, product, reserved = { {tank, litres} }, litres, price, at }

lib.callback.register('opslabs-towers:fuel:dispenser', function(src, id)
    id = tonumber(id)
    local f = fx(id)
    if not f or f.model ~= CF.Dispenser then return { error = 'not a dispenser' } end
    if dirty then rebuild() end
    local cid = Net.station[id]
    local grades = {}
    for _, p in ipairs({ 'ul', 'sup', 'dsl' }) do
        if (Net.sells[id] or {})[p] then
            local litres = available(id, p)
            grades[#grades + 1] = { product = p, label = PROD[p].label, price = price(cid, p), litres = math.floor(litres) }
        end
    end
    return { id = id, fault = dispenserFault(id), breakaway = S.breakaway[id] and true or false, grades = grades,
        station = cid and stationName(cid) or nil, cash = FW.GetMoney(src, 'cash'), bank = FW.GetMoney(src, 'bank') }
end)

lib.callback.register('opslabs-towers:fuel:start', function(src, id, p, want)
    id, want = tonumber(id), tonumber(want) or 0
    if Pumping[src] then return { error = 'Already pumping' } end
    local f = fx(id)
    if not f or f.model ~= CF.Dispenser or not PROD[p] then return { error = 'not found' } end
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and dist(GetEntityCoords(ped), f) > (CF.UseDistance or 2.2) + 3.0 then return { error = 'Too far from the dispenser' } end
    local fault = dispenserFault(id)
    if fault then return { error = fault } end
    want = math.max(1, math.min(200, want))
    local have, tanks = available(id, p)
    if have < 1 then return { error = PROD[p].label .. ' is sold out at this station' } end
    local cid = Net.station[id]
    local ppl = price(cid, p)
    local money = math.max(FW.GetMoney(src, 'cash'), FW.GetMoney(src, 'bank'))
    want = math.min(want, have, money / ppl)
    if want < 0.5 then return { error = 'Not enough money' } end
    -- reserve from the tanks (fullest first)
    table.sort(tanks, function(a, b) return S.tanks[a].litres > S.tanks[b].litres end)
    local res, left = {}, want
    for _, t in ipairs(tanks) do
        local take = math.min(left, S.tanks[t].litres)
        if take > 0 then S.tanks[t].litres = S.tanks[t].litres - take; res[#res + 1] = { t, take }; left = left - take end
        if left <= 0 then break end
    end
    Pumping[src] = { disp = id, product = p, reserved = res, litres = want, price = ppl, station = cid, at = now() }
    return { ok = true, litres = want, price = ppl, label = PROD[p].label }
end)

local function finish(src, dispensed, brokeAway)
    local s = Pumping[src]
    if not s then return { error = 'not pumping' } end
    Pumping[src] = nil
    dispensed = math.max(0, math.min(s.litres, tonumber(dispensed) or 0))
    -- give back what wasn't used, last tank first
    local back = s.litres - dispensed
    for i = #s.reserved, 1, -1 do
        local t, l = s.reserved[i][1], s.reserved[i][2]
        local r = math.min(back, l)
        if S.tanks[t] then S.tanks[t].litres = S.tanks[t].litres + r end
        back = back - r
        local used = l - r
        if S.tanks[t] then S.tanks[t].book = (S.tanks[t].book or 0) - used end
    end
    local cost = round(dispensed * s.price, 2)
    local paid = 0
    if cost > 0 then
        if FW.RemoveMoney(src, cost, 'cash', 'Fuel') or FW.RemoveMoney(src, cost, 'bank', 'Fuel') then paid = cost
        else
            -- couldn't pay after all: take what they have in the bank (drive-off)
            paid = 0
        end
        if paid > 0 and CF.Society and GetResourceState('esx_addonaccount') == 'started' then
            TriggerEvent('esx_addonaccount:getSharedAccount', CF.Society, function(acc) if acc then acc.addMoney(paid) end end)
        end
    end
    local st = S.stations[s.station]
    if st then
        S.seq = S.seq + 1
        log(st.sales, { n = S.seq, at = now(), disp = s.disp, product = s.product, litres = round(dispensed, 2), price = s.price, total = cost,
            paid = paid > 0, who = GetPlayerName(src) or '?' }, 60)
        st.salesTotal = round((st.salesTotal or 0) + paid, 2)
        st.litresSold = round((st.litresSold or 0) + dispensed, 1)
    end
    if brokeAway then
        S.breakaway[s.disp] = now()
        if s.station then alarm(s.station, ('Breakaway coupling parted at dispenser #%d (driven off with the nozzle in)'):format(s.disp)) end
    end
    save()
    return { ok = true, litres = dispensed, cost = cost, paid = paid > 0 }
end
lib.callback.register('opslabs-towers:fuel:finish', function(src, dispensed, brokeAway) return finish(src, dispensed, brokeAway) end)
AddEventHandler('playerDropped', function() local src = source if Pumping[src] then finish(src, Pumping[src].litres, false) end end)

lib.callback.register('opslabs-towers:fuel:breakawayReset', function(src, id)
    id = tonumber(id)
    if not S.breakaway[id] then return { error = 'The coupling is fine' } end
    S.breakaway[id] = nil
    save()
    return { ok = true }
end)

lib.callback.register('opslabs-towers:fuel:estop', function(src, id)
    local cid = stationOf(tonumber(id))
    if not cid then return { error = 'This e-stop isn’t wired to a pump controller (none within range)' } end
    S.stations[cid].estop = now()
    alarm(cid, 'EMERGENCY STOP pressed by ' .. (GetPlayerName(src) or '?'))
    for p, s in pairs(Pumping) do if s.station == cid then TriggerClientEvent('opslabs-towers:fuel:stop', p, 'Emergency stop — all pumps stopped') end end
    save()
    return { ok = true, station = stationName(cid) }
end)

---------------------------------------------------------------------------
-- tank gauge / pump controller
---------------------------------------------------------------------------
local function stationReport(cid)
    if dirty then rebuild() end
    local st = S.stations[cid]
    local f = fx(cid)
    if not st or not f then return nil end
    local tanks, disps, fills, vents, estops = {}, {}, {}, 0, 0
    for id, k in pairs(Net.kit) do
        if Net.station[id] == cid then
            local kf = Cabling.fixtures[id]
            if k == 'tank' then
                local t, def = tankState(id)
                local feeds = {}
                for did, m in pairs(Net.sells) do for _, tid in ipairs(m[def.product] or {}) do if tid == id then feeds[#feeds + 1] = did end end end
                local filled = false
                for _, m in pairs(Net.fills) do for _, tid in ipairs(m[def.product] or {}) do if tid == id then filled = true end end end
                tanks[#tanks + 1] = { id = id, product = def.product, label = PROD[def.product].label, cap = def.litres, litres = round(t.litres, 0),
                    pct = round(t.litres / def.litres * 100, 1), temp = round(t.temp or 18, 1), water = round(t.water or 0, 0), leak = t.leak or false,
                    book = round(t.book or 0, 0), variance = round(t.litres - (t.book or 0), 0), vented = Net.vented[id] or false,
                    filled = filled, dispensers = #feeds, x = kf.x, y = kf.y }
            elseif k == 'disp' then
                local g = {}
                for p in pairs(Net.sells[id] or {}) do g[#g + 1] = p end
                table.sort(g)
                disps[#disps + 1] = { id = id, grades = g, powered = powered(id), fault = dispenserFault(id), breakaway = S.breakaway[id] and true or false, x = kf.x, y = kf.y }
            elseif k == 'fill' then fills[#fills + 1] = { id = id }
            elseif k == 'vent' then vents = vents + 1
            elseif k == 'estop' then estops = estops + 1 end
        end
    end
    table.sort(tanks, function(a, b) return a.id < b.id end)
    table.sort(disps, function(a, b) return a.id < b.id end)
    local prices = {}
    for p, d in pairs(PROD) do prices[p] = price(cid, p) end
    return { id = cid, name = stationName(cid), x = f.x, y = f.y, powered = powered(cid), estop = st.estop and true or false,
        tanks = tanks, dispensers = disps, fillpoints = #fills, vents = vents, estops = estops, prices = prices,
        sales = st.sales or {}, deliveries = st.deliveries or {}, alarms = st.alarms or {},
        salesTotal = st.salesTotal or 0, litresSold = st.litresSold or 0 }
end

local function canManage(src)
    if src == 0 then return true end
    if #(CF.Jobs or {}) == 0 then return true end
    local job = FW.Job(src)
    for _, j in ipairs(CF.Jobs) do if j == job then return true end end
    return FW.IsAdmin(src)
end

function FuelAction(cid, action, a, actor)
    cid = tonumber(cid)
    local st = S.stations[cid]
    if not st then return nil, 'no such station' end
    a = a or {}
    if action == 'reset_estop' then st.estop = false
    elseif action == 'price' then
        local v = tonumber(a.price)
        if not PROD[a.product] or not v or v < 0.1 or v > 20 then return nil, 'bad price' end
        st.prices = st.prices or {}
        st.prices[a.product] = round(v, 3)
    elseif action == 'name' then
        st.name = tostring(a.name or ''):sub(1, 40)
        if st.name == '' then st.name = nil end
    elseif action == 'clear_alarms' then st.alarms = {}
    elseif action == 'water_out' then
        local t = S.tanks[tonumber(a.tank) or -1]
        if not t then return nil, 'no such tank' end
        t.water = 0
    elseif action == 'leak_fixed' then
        local t = S.tanks[tonumber(a.tank) or -1]
        if not t then return nil, 'no such tank' end
        t.leak = false
    elseif action == 'reconcile' then
        for id, t in pairs(S.tanks) do if Net.station[id] == cid then t.book = t.litres end end
    else return nil, 'unknown action' end
    if actor then log(st.alarms, { at = now(), text = ('%s: %s'):format(actor, action:gsub('_', ' ')), info = true }, 20) end
    save()
    return true
end

lib.callback.register('opslabs-towers:fuel:atg', function(src, id)
    local r = stationReport(tonumber(id))
    if not r then return { error = 'not found' } end
    if not r.powered then return { error = 'The tank gauge has no power' } end
    r.manage = canManage(src)
    return r
end)
lib.callback.register('opslabs-towers:fuel:atgAct', function(src, id, action, a)
    if not canManage(src) then return { error = 'Only station staff can do that' } end
    local ok, err = FuelAction(id, action, a, GetPlayerName(src))
    if not ok then return { error = err } end
    return { ok = true }
end)
-- at the tank: pump out water / fix a leak (engineer work)
lib.callback.register('opslabs-towers:fuel:tankWork', function(src, id, what)
    id = tonumber(id)
    local t = S.tanks[id]
    if not t then return { error = 'not a tank' } end
    if what == 'water' then t.water = 0 elseif what == 'leak' then t.leak = false end
    save()
    return { ok = true }
end)

---------------------------------------------------------------------------
-- road tankers: load at a terminal gantry, offload at a fill point
---------------------------------------------------------------------------
local function cleanPlate(p) return tostring(p or ''):gsub('^%s+', ''):gsub('%s+$', '') end

lib.callback.register('opslabs-towers:fuel:tanker', function(src, plate) return S.loads[cleanPlate(plate)] or { comps = {} } end)

lib.callback.register('opslabs-towers:fuel:load', function(src, gantry, plate, model, comps)
    local g = fx(gantry)
    if not g or g.model ~= CF.Gantry then return { error = 'not a loading gantry' } end
    local cap = (CF.Tankers or {})[model]
    if not cap then return { error = 'That isn’t a fuel tanker' } end
    plate = cleanPlate(plate)
    local n = CF.Compartments or 3
    local per = math.floor(cap / n)
    local load = S.loads[plate] or { comps = {} }
    local cost = 0.0
    for i = 1, n do
        local c = comps and comps[i]
        if c and PROD[c.product] and (tonumber(c.litres) or 0) > 0 then
            local cur = load.comps[i]
            if cur and cur.litres > 0 and cur.product ~= c.product then return { error = ('Compartment %d still has %s in it'):format(i, PROD[cur.product].label) } end
            local add = math.min(per - (cur and cur.litres or 0), math.floor(tonumber(c.litres)))
            if add > 0 then
                load.comps[i] = { product = c.product, litres = (cur and cur.litres or 0) + add }
                cost = cost + add * (PROD[c.product].wholesale or 1.0)
            end
        end
    end
    cost = round(cost, 2)
    if cost <= 0 then return { error = 'Nothing to load' } end
    if not (FW.RemoveMoney(src, cost, 'bank', 'Bulk fuel') or FW.RemoveMoney(src, cost, 'cash', 'Bulk fuel')) then return { error = ('Bulk fuel costs $%.2f — not enough money'):format(cost) } end
    load.cap, load.per = cap, per
    S.loads[plate] = load
    save()
    return { ok = true, load = load, cost = cost }
end)

lib.callback.register('opslabs-towers:fuel:earth', function(src, fill, plate)
    S.earthed[cleanPlate(plate) .. ':' .. tostring(fill)] = now() + 900
    return { ok = true }
end)

--- offload compartment i into the tank its colour-coded fill pipe goes to
lib.callback.register('opslabs-towers:fuel:deliver', function(src, fill, plate, i)
    fill, i = tonumber(fill), tonumber(i)
    if dirty then rebuild() end
    local f = fx(fill)
    if not f or f.model ~= CF.FillPoint then return { error = 'not a fill point' } end
    plate = cleanPlate(plate)
    local load = S.loads[plate]
    local c = load and load.comps[i]
    if not c or c.litres <= 0 then return { error = 'That compartment is empty' } end
    local e = S.earthed[plate .. ':' .. fill]
    if not e or e < now() then return { error = 'Earth the tanker to the fill point first (static bonding)' } end
    local targets = ((Net.fills[fill] or {})[c.product]) or {}
    if #targets == 0 then return { error = ('No %s fill pipe from this fill point to a %s tank'):format(c.product:upper(), PROD[c.product].label) } end
    local moved, notes = 0, {}
    for _, t in ipairs(targets) do
        local ts, def = tankState(t)
        if not Net.vented[t] then notes[#notes + 1] = ('Tank #%d has no vent pipe to a vent stack — refused'):format(t)
        elseif ts.leak then notes[#notes + 1] = ('Tank #%d has a leak alarm — refused'):format(t)
        else
            local room = def.litres * (CF.Overfill or 0.95) - ts.litres
            local take = math.max(0, math.min(room, c.litres))
            if take > 0 then
                ts.litres = ts.litres + take
                ts.book = (ts.book or 0) + take
                c.litres = c.litres - take
                moved = moved + take
            else notes[#notes + 1] = ('Tank #%d is at its overfill limit (%d %%)'):format(t, math.floor((CF.Overfill or 0.95) * 100)) end
        end
        if c.litres <= 0 then break end
    end
    if moved <= 0 then return { error = table.concat(notes, ' · ') } end
    if c.litres < 1 then load.comps[i] = nil end
    local cid = Net.station[fill]
    if cid and S.stations[cid] then
        log(S.stations[cid].deliveries, { at = now(), product = c.product, litres = math.floor(moved), plate = plate, who = GetPlayerName(src) or '?' }, 40)
    end
    save()
    return { ok = true, litres = math.floor(moved), left = math.floor(c.litres), notes = notes }
end)

---------------------------------------------------------------------------
-- monitoring: temperature, water, leaks
---------------------------------------------------------------------------
CreateThread(function()
    Wait(5000)
    while true do
        Wait(10000)
        if dirty then rebuild() end
        local h = GlobalState.opsGameHour or 12
        local raining = GlobalState.opsRain
        for id, t in pairs(S.tanks) do
            local f, def = fx(id), nil
            def = f and CF.Tanks[f.model]
            if def then
                local amb = 16 + 8 * math.sin(math.pi * (h - 9) / 12)
                local target = def.above and amb or (12 + (amb - 12) * 0.2)          -- underground stays cool
                t.temp = (t.temp or target) + (target - (t.temp or target)) * 0.05
                local cid = Net.station[id]
                if t.litres > 50 and raining and not def.above and math.random() < (CF.WaterChance or 0.004) * 6 then
                    t.water = math.min(300, (t.water or 0) + math.random(5, 40))
                    if cid then alarm(cid, ('Water in tank #%d (%s) — %d mm'):format(id, PROD[def.product].label, t.water)) end
                end
                if not t.leak and t.litres > 100 and math.random() < (CF.LeakChance or 0.0015) / 6 then
                    t.leak = true
                    if cid then alarm(cid, ('LEAK suspected on tank #%d (%s) — dispensing from it stopped'):format(id, PROD[def.product].label)) end
                    save()
                end
                if t.leak and t.litres > 0 then t.litres = math.max(0, t.litres - (CF.LeakLph or 30) * 10 / 3600) end
                if cid and t.litres < def.litres * 0.1 and t.litres > 0 then alarm(cid, ('Low stock: tank #%d (%s) under 10 %%'):format(id, PROD[def.product].label)) end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- hub / API
---------------------------------------------------------------------------
function FuelState()
    if dirty then rebuild() end
    local out = { products = PROD, stations = {}, tankers = {} }
    for cid in pairs(S.stations) do
        local r = stationReport(cid)
        if r then out.stations[#out.stations + 1] = r end
    end
    table.sort(out.stations, function(a, b) return a.id < b.id end)
    for plate, l in pairs(S.loads) do out.tankers[#out.tankers + 1] = { plate = plate, comps = l.comps, cap = l.cap } end
    -- kit that isn't part of a station yet (no tank gauge near it)
    local loose = 0
    for id, k in pairs(Net.kit) do if k ~= 'gantry' and k ~= 'atg' and not Net.station[id] then loose = loose + 1 end end
    out.unassigned = loose
    return out
end
exports('FuelState', FuelState)
--- fill a tank (showcase / admin): litres, counted as a delivery in the book stock
function FuelSetTank(id, litres)
    if dirty then rebuild() end
    local t, def = tankState(tonumber(id))
    if not t then return false end
    t.litres = math.max(0, math.min(def.litres, tonumber(litres) or 0))
    t.book = t.litres
    save()
    return true
end
exports('FuelAction', FuelAction)

-- keep the game hour / rain flag where the monitor can see them
CreateThread(function()
    while true do
        Wait(60000)
        local players = GetPlayers()
        if #players > 0 then
            local ok, h, w = pcall(lib.callback.await, 'opslabs-towers:sky', tonumber(players[1]))
            if ok and tonumber(h) then
                GlobalState.opsGameHour = tonumber(h)
                w = tostring(w or ''):upper()
                GlobalState.opsRain = (w == 'RAIN' or w == 'THUNDER' or w == 'CLEARING') and true or false
            end
        end
    end
end)
