-- Mains electricity (San Andreas Power & Light). Works out which kit is live from what is really placed:
--   sources:  a pole transformer fitted on a power pole whose cut-out fuses are in, or a running generator
--   cable:    power runs (LV, service drop, mains, flex) connect whatever their ends touch: poles, supply kit,
--             consumer units, sockets... and each other (joints)
--   walls:    sockets, lights and EV chargers near a live consumer unit are fed through the walls
--   plugs:    plug-in kit plugs into the nearest free outlet in reach (sockets, extension leads, reels, generators)
-- Also keeps electricity meters counting, laptop batteries charging / draining, and EV charging sessions.

local CM = Config.Mains or {}
if CM.Enabled == false then return end
local CS = Config.Solar or {}

local LAPTOPS = {}
for _, m in ipairs((Config.Laptop or {}).Models or { 'opslabs_laptop' }) do LAPTOPS[m] = true end

local function roleOf(model)
    if not model then return nil end
    if CM.Wired[model] then return 'wired' end
    if CM.PlugIn[model] then return 'plug' end
    if model == CM.ConsumerUnit then return 'cu' end
    if model == CM.Generator then return 'gen' end
    if CS.Inverter and model == CS.Inverter then return 'inv' end
    if CS.Battery and model == CS.Battery then return 'battery' end
    if CS.Panels and CS.Panels[model] then return 'panel' end
    if model == CM.Transformer then return 'tx' end
    if CM.Supply[model] then return 'supply' end
    if LAPTOPS[model] then return 'laptop' end
    if model:find('^opslabs_power_pole') then return 'pole' end
    return nil
end

--- kit whose fixture data the mains code owns (switch positions, meter readings, battery) — kept when moved
function MainsOwnsData(model)
    local r = roleOf(model)
    return r ~= nil and r ~= 'pole' and r ~= 'tx' and r ~= 'supply' and r ~= 'panel' or CM.Meters[model] == true or CM.Switchable[model] == true
end

local State = {}            -- fixture id -> { live, off, plug = { outletFixture, slot }, cu, on }
local Cabled = {}           -- fixture id -> true when a power cable end lands on it (a switch wired to its lights…)
LiveOutlets, LiveTx = {}, {}
local Laptops = {}          -- laptop fixture id -> { level, plugged, charging, dead }
local InUse = {}            -- laptop fixture id -> true while someone is at it
local EvActive = {}         -- EV charger fixture id -> os.time() the session lapses
local Load = {}             -- meter fixture id -> watts right now
local Solar = {}            -- inverter fixture id -> { gen, soc, cap, on, battery, panels }
local GameHour = 12.0       -- game clock, asked from a player every minute (the server has no clock of its own)
local payloadJson = nil
local dirty, lastTick, lastSave = true, os.clock(), os.time()
local savePending = {}

function MainsDirty() dirty = true end

local function hdist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function dist3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end

--- a point given in a fixture's own frame, in the world
local function worldOf(f, o)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return { x = f.x + o[1] * c - o[2] * s, y = f.y + o[1] * s + o[2] * c, z = f.z + o[3] }
end

local function data(f)
    f.data = type(f.data) == 'table' and f.data or {}
    return f.data
end

local function saveData(f)
    savePending[f.id] = true
end

local function flushSaves()
    for id in pairs(savePending) do
        local f = Cabling.fixtures[id]
        if f then MySQL.update('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { f.data and next(f.data) and json.encode(f.data) or nil, id }) end
    end
    savePending = {}
end

---------------------------------------------------------------------------
-- the network
---------------------------------------------------------------------------

local function recompute()
    local fx = Cabling.fixtures
    local adj, cabled = {}, {}
    local function link(a, b)
        adj[a] = adj[a] or {}
        adj[b] = adj[b] or {}
        adj[a][#adj[a] + 1] = b
        adj[b][#adj[b] + 1] = a
    end
    local poles, kit, cus, plugs = {}, {}, {}, {}
    for id, f in pairs(fx) do
        local r = roleOf(f.model)
        if r == 'pole' then poles[#poles + 1] = f
        elseif r == 'supply' or r == 'cu' or r == 'wired' or r == 'gen' or r == 'inv' then kit[#kit + 1] = f end
        if r == 'cu' then cus[#cus + 1] = f end
        if r == 'plug' then plugs[#plugs + 1] = id end
    end
    table.sort(plugs)

    -- transformers are fitted on a pole
    local txPole = {}
    for id, f in pairs(fx) do
        if f.model == CM.Transformer then
            for _, p in ipairs(poles) do
                if hdist(f, p) <= (CM.TransformerReach or 0.8) then txPole[id] = p.id; link('f' .. id, 'f' .. p.id) break end
            end
        end
    end

    -- a solar inverter is wired into the nearest consumer unit (through the walls)
    for id, f in pairs(fx) do
        if roleOf(f.model) == 'inv' then
            local best, bd
            for _, c in ipairs(cus) do
                local d = hdist(f, c)
                if d <= (CM.AutoWireRadius or 14.0) and math.abs(f.z - c.z) <= (CM.AutoWireHeight or 6.0) and (not bd or d < bd) then best, bd = c, d end
            end
            if best then link('f' .. id, 'f' .. best.id) end
        end
    end

    -- power cable: each run joins whatever its two ends touch
    local ends = {}
    for rid, r in pairs(Cabling.runs) do
        -- LV only: 400 kV and 11 kV conductor belong to the grid (server/grid.lua)
        if r.kind == 'power' and r.color ~= 'transmission' and r.color ~= 'hv' and type(r.points) == 'table' and #r.points >= 2 then
            local node = 'r' .. rid
            for _, p in ipairs({ r.points[1], r.points[#r.points] }) do
                ends[#ends + 1] = { node = node, p = p }
                -- a jumper snapped off with the Line Tool (server/powerline.lua) leaves the conductor there, unconnected
                for _, pl in ipairs(poles) do
                    if hdist(p, pl) <= (CM.PoleReach or 1.6) and p.z > pl.z - 1.0 and p.z < pl.z + 16.0
                        and not (PowerJumperOpen and PowerJumperOpen(pl.id, rid)) then link(node, 'f' .. pl.id) end
                end
                for _, k in ipairs(kit) do
                    local mid = { x = k.x, y = k.y, z = k.z + 0.15 }
                    if math.min(dist3(p, k), dist3(p, mid)) <= (CM.KitReach or 0.9) and not (PowerJumperOpen and PowerJumperOpen(k.id, rid)) then
                        link(node, 'f' .. k.id) cabled[k.id] = true
                    end
                end
            end
            for _, which in ipairs({ 'start_fixture', 'end_fixture' }) do
                if r[which] and fx[r[which]] then link(node, 'f' .. r[which]) end
            end
        end
    end
    for i = 1, #ends do
        for j = i + 1, #ends do
            if ends[i].node ~= ends[j].node and dist3(ends[i].p, ends[j].p) <= (CM.JointReach or 0.35) then link(ends[i].node, ends[j].node) end
        end
    end

    -- sources, then flood through everything that conducts (a switched-off isolator / consumer unit stops it)
    local live, queue = {}, {}
    for id, f in pairs(fx) do
        local src = false
        if f.model == CM.Transformer and txPole[id] then
            local ps = PolePowerState and PolePowerState(txPole[id])
            src = not (ps and ps.fusesOut) and (not GridTransformerLive or GridTransformerLive(id))
        elseif f.model == CM.Generator then
            src = data(f).on == true
        elseif roleOf(f.model) == 'inv' then
            src = Solar[id] ~= nil and Solar[id].on == true
        end
        if src then live['f' .. id] = true; queue[#queue + 1] = 'f' .. id end
    end
    local function conducts(node)
        local id = tonumber(node:match('^f(%d+)$'))
        if not id then return true end
        local f = fx[id]
        if not f then return false end
        if CM.Switchable[f.model] and f.data and f.data.off then return false end
        local wdef = CM.Wired[f.model]
        if wdef and wdef.lightSwitch and f.data and f.data.off then return false end
        if f.model == CM.Generator and not (f.data and f.data.on) then return false end
        return true
    end
    while #queue > 0 do
        local n = table.remove(queue)
        if conducts(n) then
            for _, m in ipairs(adj[n] or {}) do
                if not live[m] then live[m] = true; queue[#queue + 1] = m end
            end
        end
    end

    -- which poles carry live LV (the pole monitor shows it; server/grid.lua GridPoles)
    local pl = {}
    for _, p in ipairs(poles) do pl[p.id] = live['f' .. p.id] == true end
    MainsPoleLive = pl
    local st = {}
    for id, f in pairs(fx) do
        local r = roleOf(f.model)
        if r and r ~= 'pole' and r ~= 'laptop' and r ~= 'panel' and r ~= 'battery' then
            st[id] = { live = live['f' .. id] == true, off = (f.data and f.data.off) and true or nil }
            if r == 'gen' then st[id].live = f.data and f.data.on == true or false end
            if r == 'inv' then st[id].live = Solar[id] ~= nil and Solar[id].on == true end
            if r == 'tx' then st[id].pole = txPole[id] end
        end
    end
    -- through the walls: hard-wired kit not fed by cable takes the nearest consumer unit
    for id, f in pairs(fx) do
        local wdef = CM.Wired[f.model]
        if roleOf(f.model) == 'wired' and not st[id].live and not (wdef.lamp and cabled[id]) then
            local best, bd
            for _, c in ipairs(cus) do
                local d = hdist(f, c)
                if d <= (CM.AutoWireRadius or 14.0) and math.abs(f.z - c.z) <= (CM.AutoWireHeight or 6.0) and (not bd or d < bd) then best, bd = c, d end
            end
            if best then
                st[id].cu = best.id
                st[id].live = st[best.id].live and not (best.data and best.data.off) or false
            end
        end
    end

    -- kit fed through the walls passes it on along its own cables (a light switch → the lights cabled to it)
    local q2 = {}
    for id, x in pairs(st) do
        if x.cu and x.live and conducts('f' .. id) then q2[#q2 + 1] = 'f' .. id live['f' .. id] = true end
    end
    while #q2 > 0 do
        local n = table.remove(q2)
        if conducts(n) then
            for _, m in ipairs(adj[n] or {}) do
                if not live[m] then
                    live[m] = true
                    q2[#q2 + 1] = m
                    local mid = tonumber(m:match('^f(%d+)$'))
                    if mid and st[mid] then st[mid].live = true end
                end
            end
        end
    end
    Cabled = cabled

    -- outlets, then plug-in kit plugs into the nearest free one in reach
    local outlets = {}
    for id, f in pairs(fx) do
        local def = CM.Wired[f.model] or CM.PlugIn[f.model]
        local list = (def and def.o) or (f.model == CM.Generator and CM.GeneratorOutlets) or nil
        if list then
            for k, o in ipairs(list) do outlets[#outlets + 1] = { fid = id, slot = k, p = worldOf(f, o) } end
        end
    end
    local used = {}
    for _, id in ipairs(plugs) do
        local f = fx[id]
        local def = CM.PlugIn[f.model]
        if not (f.data and f.data.unplugged) then
            local lead = worldOf(f, def.lead_at or { 0, 0, 0 })
            local best, bd
            for _, o in ipairs(outlets) do
                local key = o.fid .. ':' .. o.slot
                if o.fid ~= id and not used[key] then
                    local d = dist3(lead, o.p)
                    if d <= (def.reach or 2.0) and (not bd or d < bd) then best, bd = o, d end
                end
            end
            if best then
                used[best.fid .. ':' .. best.slot] = true
                st[id].plug = { best.fid, best.slot }
            end
        end
        st[id].unplugged = (f.data and f.data.unplugged) and true or nil
    end
    local function outletLive(fid)
        local s, f = st[fid], fx[fid]
        if not s or not f then return false end
        if f.model == CM.Generator then return s.live end
        return s.live and not s.off
    end
    for _ = 1, 8 do                       -- extension leads into extension leads...
        local moved = false
        for _, id in ipairs(plugs) do
            local s = st[id]
            local nl = s.plug ~= nil and outletLive(s.plug[1]) or false
            if nl ~= s.live then s.live = nl; moved = true end
        end
        if not moved then break end
    end
    for _, s in pairs(st) do s.on = s.live and not s.off or false end
    State = st
    -- live supply points for network kit: outlets you can plug into, and live pole transformers
    local lo, lt = {}, {}
    for _, o in ipairs(outlets) do
        local of = fx[o.fid]
        local ost = st[o.fid]
        if ost and (of.model == CM.Generator and ost.live or ost.live and not ost.off) then lo[#lo + 1] = o.p end
    end
    for id, x in pairs(st) do if roleOf(fx[id].model) == 'tx' and x.live then lt[#lt + 1] = fx[id] end end
    LiveOutlets, LiveTx = lo, lt
    MainsGraph = { adj = adj, txPole = txPole, outlets = outlets, cabled = cabled }   -- server/powerdiag.lua traces it
end

---------------------------------------------------------------------------
-- meters, laptops, EV sessions (every tick)
---------------------------------------------------------------------------

local function wattsOf(id, f, s)
    if not s or not s.on then return 0 end
    local def = CM.Wired[f.model] or CM.PlugIn[f.model]
    if not def then return 0 end
    if def.ev then return (EvActive[id] and EvActive[id] > os.time()) and (def.watts or 7400) or 0 end
    if def.laptop then return s.charging and (def.watts or 65) or 5 end
    return def.watts or 0
end

local function tick(dt)
    local fx = Cabling.fixtures
    -- laptops: charging on a live laptop charger beside them, draining while in use
    local LC = CM.Laptop or {}
    local chargers = {}
    for id, f in pairs(fx) do
        local def = CM.PlugIn[f.model]
        if def and def.laptop and State[id] and State[id].on then chargers[#chargers + 1] = f end
    end
    for id, f in pairs(fx) do
        if LAPTOPS[f.model] then
            local d = data(f)
            local level = tonumber(d.battery) or 100.0
            local plugged = false
            for _, c in ipairs(chargers) do
                if dist3(c, f) <= (LC.ChargerDistance or 1.6) then plugged = true; if State[c.id] then State[c.id].charging = level < 100 end break end
            end
            local before = level
            if plugged then level = math.min(100.0, level + (LC.Charge or 2.5) * dt / 60)
            elseif InUse[id] then level = math.max(0.0, level - (LC.Drain or 0.7) * dt / 60) end
            if math.floor(level) ~= math.floor(before) then d.battery = math.floor(level * 10 + 0.5) / 10; saveData(f) else d.battery = level end
            Laptops[id] = { level = math.floor(level + 0.5), plugged = plugged, charging = plugged and level < 100, dead = level <= 0 and not plugged }
        end
    end
    -- solar: panels → (DC isolator) → inverter, surplus into the home battery, battery keeps the house on after dark
    local h = GameHour
    local rise, set = CS.Sunrise or 6, CS.Sunset or 20
    local sun = (h > rise and h < set) and math.sin(math.pi * (h - rise) / (set - rise)) or 0.0
    for id, f in pairs(fx) do
        if roleOf(f.model) == 'inv' then
            local isolated, peak, panels = false, 0, 0
            for _, g in pairs(fx) do
                local d = dist3(g, f)
                if CS.Panels[g.model] and d <= (CS.PanelReach or 30.0) then peak = peak + CS.Panels[g.model] panels = panels + 1 end
                if g.model == CS.DcIsolator and d <= (CS.PanelReach or 30.0) and g.data and g.data.off then isolated = true end
            end
            local gen = (isolated or (f.data and f.data.off)) and 0 or peak * sun
            local bat, bd
            for _, g in pairs(fx) do
                if g.model == CS.Battery then
                    local d = dist3(g, f)
                    if d <= (CS.BatteryReach or 4.0) and (not bd or d < bd) then bat, bd = g, d end
                end
            end
            local soc, cap = nil, CS.BatteryKwh or 13.5
            if bat then
                local bdat = data(bat)
                soc = tonumber(bdat.soc) or cap * 0.5
                if gen > 0 then soc = soc + math.min(gen * 0.6, CS.MaxChargeWatts or 5000) * dt / 3600000
                else soc = soc - (CS.HouseLoadWatts or 600) * dt / 3600000 end
                soc = math.max(0.0, math.min(cap, soc))
                if math.floor(soc * 10) ~= math.floor((tonumber(bdat.soc) or -1) * 10) then saveData(bat) end
                bdat.soc = soc
            end
            local on = gen > 0 or (soc ~= nil and soc > 0.01)
            local was = Solar[id]
            Solar[id] = { gen = math.floor(gen + 0.5), peak = peak, panels = panels, isolated = isolated, soc = soc, cap = cap, on = on, battery = bat and bat.id or nil }
            if not was or was.on ~= on then dirty = true end
        end
    end
    for id in pairs(Solar) do if not fx[id] then Solar[id] = nil end end

    -- meters count what's working nearest them
    local meters = {}
    for id, f in pairs(fx) do if CM.Meters[f.model] and State[id] and State[id].live then meters[#meters + 1] = f end end
    local load = {}
    for id, f in pairs(fx) do
        local w = wattsOf(id, f, State[id])
        if w > 0 and #meters > 0 then
            local best, bd
            for _, m in ipairs(meters) do
                local d = dist3(m, f)
                if d <= 40.0 and (not bd or d < bd) then best, bd = m, d end
            end
            if best then load[best.id] = (load[best.id] or 0) + w end
        end
    end
    for _, m in ipairs(meters) do
        local d = data(m)
        d.kwh = (tonumber(d.kwh) or (1000 + (m.id * 7919) % 9000)) + (load[m.id] or 0) * dt / 3600000
        if load[m.id] then saveData(m) end
    end
    Load = load
end

local function payload()
    local out = {}
    for id, s in pairs(State) do
        out[tostring(id)] = { s.live and 1 or 0, s.off and 1 or 0, s.plug and s.plug[1] or 0, s.plug and s.plug[2] or 0, s.unplugged and 1 or 0 }
    end
    for id, l in pairs(Laptops) do out['L' .. id] = { l.level, l.charging and 1 or 0, l.plugged and 1 or 0 } end
    for id, v in pairs(Solar) do out['S' .. id] = { v.gen, v.soc and math.floor(v.soc / v.cap * 100 + 0.5) or -1, v.panels, v.isolated and 1 or 0 } end
    return out
end

CreateThread(function()
    while not Cabling or not next(Cabling) do Wait(500) end
    Wait(3000)
    while true do
        local now = os.clock()
        if dirty or now - lastTick >= (CM.Tick or 3) then
            local dt = math.min(30.0, now - lastTick)
            dirty = false
            recompute()
            if dt > 0 then tick(dt) end
            lastTick = now
            local p = payload()
            local js = json.encode(p)
            if js ~= payloadJson then
                payloadJson = js
                TriggerClientEvent('opslabs-towers:mains', -1, p)
            end
            if os.time() - lastSave >= 120 then lastSave = os.time(); flushSaves() end
        end
        Wait(250)
    end
end)
AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then flushSaves() end end)

---------------------------------------------------------------------------
-- players: state, switches, meters, EV charging
---------------------------------------------------------------------------

lib.callback.register('opslabs-towers:mains:state', function() return payload() end)

local function near(src, f, extra)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(p - vector3(f.x, f.y, f.z)) <= (CM.UseDistance or 1.3) + (extra or 1.5)
end

--- [E] on kit: socket / spur / extension / reel / desk lamp switch, consumer unit main switch, isolator,
--- generator start / stop, light switch (all ceiling lights around it), plug in / unplug a charger
lib.callback.register('opslabs-towers:mains:toggle', function(src, id)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f then return { error = 'Not found' } end
    if not near(src, f) then return { error = 'Too far away' } end
    local d = data(f)
    local wired, plug = CM.Wired[f.model], CM.PlugIn[f.model]
    if f.model == CM.Generator then
        d.on = not d.on
        saveData(f) MainsDirty()
        return { ok = true, text = d.on and 'Generator running — 230 V on its sockets' or 'Generator stopped' }
    elseif wired and wired.lightSwitch and Cabled[f.id] then
        d.off = not d.off or nil
        saveData(f) MainsDirty()
        return { ok = true, text = d.off and 'Lights off' or 'Lights on' }
    elseif wired and wired.lightSwitch then
        local lamps, anyOn = {}, false
        for lid, l in pairs(Cabling.fixtures) do
            local def = CM.Wired[l.model]
            if def and def.lamp and dist3(l, f) <= (CM.LightSwitchRadius or 8.0) then
                lamps[#lamps + 1] = l
                if not (l.data and l.data.off) then anyOn = true end
            end
        end
        if #lamps == 0 then return { error = 'No ceiling lights near this switch' } end
        for _, l in ipairs(lamps) do data(l).off = anyOn or nil saveData(l) end
        MainsDirty()
        return { ok = true, text = anyOn and 'Lights off' or 'Lights on' }
    elseif plug and not plug.switch then
        d.unplugged = not d.unplugged or nil
        saveData(f) MainsDirty()
        return { ok = true, text = d.unplugged and 'Unplugged' or 'Plugged in' }
    elseif CM.Switchable[f.model] or (wired and (wired.o or f.model == 'opslabs_mains_spur')) or (plug and plug.switch) or (wired and wired.lamp) then
        d.off = not d.off or nil
        saveData(f) MainsDirty()
        local what = f.model == CM.ConsumerUnit and 'Main switch' or CM.Switchable[f.model] and 'Isolator' or 'Switched'
        return { ok = true, text = what .. (d.off and ' off' or ' on') }
    end
    return { error = 'Nothing to switch' }
end)

lib.callback.register('opslabs-towers:mains:solar', function(src, id)
    local v = Solar[tonumber(id) or -1]
    if not v then
        -- a battery: report the inverter it belongs to
        for _, x in pairs(Solar) do if x.battery == tonumber(id) then v = x break end end
    end
    if not v then return nil end
    return { gen = v.gen, peak = v.peak, panels = v.panels, isolated = v.isolated, soc = v.soc, cap = v.cap, on = v.on, hour = GameHour }
end)

-- the server has no game clock: ask a player now and then (daylight for solar)
CreateThread(function()
    while true do
        local players = GetPlayers()
        if #players > 0 then
            local ok, h = pcall(lib.callback.await, 'opslabs-towers:clock', tonumber(players[math.random(#players)]))
            if ok and tonumber(h) then GameHour = tonumber(h) end
        end
        Wait(60000)
    end
end)

lib.callback.register('opslabs-towers:mains:read', function(src, id)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f or not CM.Meters[f.model] then return nil end
    local d = data(f)
    return { kwh = tonumber(d.kwh) or (1000 + (f.id * 7919) % 9000), watts = Load[f.id] or 0, live = State[f.id] and State[f.id].live or false }
end)

--- the client keeps an EV session alive while the car is beside a live charger (it refuels the car itself)
lib.callback.register('opslabs-towers:mains:ev', function(src, id, on)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f or not (CM.Wired[f.model] and CM.Wired[f.model].ev) then return { error = 'Not an EV charger' } end
    if on and not (State[f.id] and State[f.id].on) then return { error = 'This charger has no power' } end
    if on and not near(src, f, 6.0) then return { error = 'Too far away' } end
    EvActive[f.id] = on and (os.time() + 15) or nil
    return { ok = true }
end)

---------------------------------------------------------------------------
-- other resources / files
---------------------------------------------------------------------------

function MainsState(id) return State[tonumber(id)] end
MainsRole = roleOf
function MainsSolarState(id) return Solar[tonumber(id)] end
--- set a switch / plug flag on a piece of kit (the power restoration kit) and re-solve at once
function MainsSet(id, key, value)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f then return false end
    data(f)[key] = value
    saveData(f)
    recompute()
    MainsDirty()
    return true
end
function MainsRecompute() recompute() MainsDirty() end
function MainsLaptop(id) return Laptops[tonumber(id)] end
exports('GetMainsState', MainsState)
--- a placed fixture's model + position (opslabs-phone checks a phone is being put on a real wireless charger)
exports('GetFixture', function(id)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if not f then return nil end
    local s = State[f.id]
    return { id = f.id, model = f.model, x = f.x, y = f.y, z = f.z, heading = f.heading or 0.0, live = s and s.live and not s.off or false }
end)
exports('GetLaptopPower', MainsLaptop)
exports('GetSolar', function(id) return Solar[tonumber(id)] end)
function MainsSummary()
    local out = { solar = {}, meters = {} }
    for id, v in pairs(Solar) do out.solar[#out.solar + 1] = { id = id, gen = v.gen, peak = v.peak, panels = v.panels, soc = v.soc, cap = v.cap, on = v.on } end
    for id, w in pairs(Load) do out.meters[#out.meters + 1] = { id = id, watts = w } end
    return out
end
exports('SetLaptopInUse', function(id, on)
    id = tonumber(id)
    if id then InUse[id] = on and true or nil end
end)
