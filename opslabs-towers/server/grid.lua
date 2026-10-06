-- Grid control: the bulk power network engineers BUILD in game (Config.Grid), solved every few seconds.
--   power station (units) / wind turbine → 400 kV runs on pylons → primary substation (transformers, incomer)
--   → 11 kV feeders (each HV run leaving a substation has its own breaker) → power poles (reclosers) → pole transformers
-- Every breaker / unit / recloser here is a real piece of placed kit. Control works it from OPS Hub or in game ([E] at
-- the station / substation / recloser). What's live feeds server/mains.lua: a pole transformer only supplies its LV
-- network (sockets, lights, EV chargers, street lights) when the grid reaches it.
-- Protection is automatic: a fault or overload trips the nearest breaker / recloser upstream, which tries to reclose
-- (Config.Grid.Reclose) and locks out on a permanent fault; under-frequency sheds feeders; substation overload sheds a feeder.

local CG = Config.Grid or {}
if CG.Enabled == false then return end

local PROCEDURES = {
    { id = 'storm', title = 'Storm / high winds', steps = {
        'Raise the system level to ALERT', 'Start spare station units to hold extra reserve', 'Put crews on standby near the overhead network',
        'Send a notice to customers on exposed feeders', 'Watch feeder loading — re-route round any tripped circuit',
        'After the storm: patrol locked-out lines before closing them again' } },
    { id = 'major_outage', title = 'Major outage', steps = {
        'Read the protection alarms: which breaker or recloser tripped, and why', 'Isolate the faulted section (open the breaker / recloser upstream of it)',
        'Restore healthy feeders and sections', 'Dispatch a crew to the fault (yellow marker in game)', 'Tell affected customers when power will be back',
        'When the crew reports the repair: close the breaker and confirm the transformers are live' } },
    { id = 'equipment_failure', title = 'Equipment failure (transformer / generator / line)', steps = {
        'Confirm the alarm and take the equipment out of service', 'Check N-1: is anything now overloaded?', 'Shed or move load if needed',
        'Dispatch a crew', 'Return it to service and note it in the log' } },
    { id = 'black_start', title = 'Black start (whole grid down)', steps = {
        'Declare RESTORATION', 'Open every feeder breaker', 'Start one power station unit', 'Close the 400 kV line breakers to one substation',
        'Close that substation’s feeders one at a time, watching frequency', 'Start more units as load grows', 'Bring the other substations back the same way',
        'Return to NORMAL' } },
    { id = 'load_shedding', title = 'Generation shortfall / load shedding', steps = {
        'Start every available unit', 'Shed low-priority feeders to hold 50 Hz', 'Rotate the shed feeders every 20 minutes',
        'Tell customers on shed feeders', 'Restore feeders as generation comes back' } },
}

---------------------------------------------------------------------------
-- state (persisted)
---------------------------------------------------------------------------

local S = { units = {}, brk = {}, subs = {}, txFail = {}, runFault = {}, names = {}, prio = {},
    events = {}, log = {}, procs = {}, level = 'normal', manualLevel = nil, streets = {} }
local env = { hour = 12.0, weather = 'CLEAR', storm = false, wind = 0.55 }
local live = { freq = CG.Hz or 50.0, gen = 0, demand = 0, capacity = 0, reserve = 0, load = 0 }
local T = nil              -- topology (rebuilt when the cabling changes)
local R = { energized = {}, parent = {}, flow = {}, gateFlow = {}, poleLive = {}, txLive = {}, out = {}, wind = {} }
local dirtyTopo, saveDirty, seq = true, false, 0
local lastTxJson, lastJobs = nil, nil

function GridDirty() dirtyTopo = true end

local function now() return os.time() end
local function addLog(by, text)
    table.insert(S.log, 1, { at = now(), by = by or 'system', text = text })
    for i = #S.log, 251, -1 do S.log[i] = nil end
    saveDirty = true
end
--- server/powerline.lua: line work in the field goes in the control-room log
function GridNote(by, text) addLog(by, text) end
local function event(kind, sev, title, text, target, pos, crew)
    seq = seq + 1
    local e = { id = ('E%d%03d'):format(now() % 1000000, seq % 1000), kind = kind, sev = sev, title = title, text = text, target = target,
        x = pos and pos.x or nil, y = pos and pos.y or nil, z = pos and pos.z or nil, crew = crew or nil, status = 'active', at = now() }
    table.insert(S.events, 1, e)
    for i = #S.events, 151, -1 do S.events[i] = nil end
    addLog('protection', title .. (text and (' — ' .. text) or ''))
    return e
end
local function clearEvents(target, kind)
    for _, e in ipairs(S.events) do
        if e.status ~= 'cleared' and e.target == target and (not kind or e.kind == kind) then e.status = 'cleared' e.cleared = now() end
    end
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_grid` (`k` VARCHAR(32) NOT NULL, `v` LONGTEXT NOT NULL, PRIMARY KEY (`k`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    local row = MySQL.scalar.await("SELECT v FROM opslabs_towers_grid WHERE k = 'built'")
    local saved = row and json.decode(row)
    if type(saved) == 'table' then
        for _, k in ipairs({ 'units', 'brk', 'subs', 'txFail', 'runFault', 'names', 'prio', 'events', 'log', 'procs', 'level', 'manualLevel', 'streets' }) do
            if saved[k] ~= nil then S[k] = saved[k] end
        end
    end
    -- json keys come back as strings: normalise the tables keyed by fixture / run id
    for _, k in ipairs({ 'units', 'subs', 'txFail', 'runFault' }) do
        local t = {}
        for id, v in pairs(S[k] or {}) do t[tonumber(id) or id] = v end
        S[k] = t
    end
    S.ready = true
end)
local function save()
    saveDirty = false
    MySQL.update('REPLACE INTO opslabs_towers_grid (k, v) VALUES (?, ?)', { 'built', json.encode({ units = S.units, brk = S.brk, subs = S.subs, txFail = S.txFail,
        runFault = S.runFault, names = S.names, prio = S.prio, events = S.events, log = S.log, procs = S.procs, level = S.level, manualLevel = S.manualLevel,
        streets = S.streets }) })
end

---------------------------------------------------------------------------
-- topology from what's placed
---------------------------------------------------------------------------

local ST, WI, SU, PY = CG.Station or {}, CG.Wind or {}, CG.Substation or {}, CG.Pylon or {}
local SITES, SK = CG.SubSites or {}, CG.SubKit or {}
local function isSubAnchor(m) return m == SU.model or SITES[m] ~= nil end
local function isSubPart(m) return (SK.parts or {})[m] ~= nil end
local YARD_SPEC = { kind = 'yard', mva = SU.mva or 60, tx = SU.tx or 2, feeders = 99, reach = SU.reach or 19, scada = true, control = true, meter = true, ok = true, missing = {}, kit = {} }

--- what a substation can do, from the plant fitted round it
local function subSpec(f, fx, parts)
    if f.model == SU.model then return YARD_SPEC end
    local site = SITES[f.model]
    if site.kind == 'fitted' then
        return { kind = 'fitted', mva = site.mva or 60, tx = site.tx or 2, feeders = site.feeders or 8, reach = site.reach or 16, scada = true,
            control = true, meter = true, ok = true, missing = {}, kit = {} }
    end
    local n = {}
    for _, p in ipairs(parts) do n[p.role] = (n[p.role] or 0) + 1 end
    local missing = {}
    for _, r in ipairs(SK.required or {}) do if not n[r] then missing[#missing + 1] = (SK.labels or {})[r] or r end end
    local scada = site.scada or false
    for _, p in ipairs(parts) do if p.f.model == 'opslabs_grid_rtu' then scada = true end end
    return { kind = site.kind, mva = (n.tx or 0) * (SK.txMVA or 30), tx = n.tx or 0, feeders = (n.mv or 0) * (SK.feedersPerLineup or 4),
        reach = site.reach or 16, scada = scada, control = (n.control or 0) > 0, meter = (n.meter or 0) > 0, ok = #missing == 0, missing = missing, kit = n }
end
local function isPowerPole(m) return m and m:find('^opslabs_power_pole') ~= nil end
local KIT_LABEL = {}
for _, e in ipairs((Config.Cabling or {}).Equipment or {}) do
    KIT_LABEL[e.model] = e.label
    for _, sz in ipairs(e.sizes or {}) do KIT_LABEL[sz.model] = e.label .. ' · ' .. sz.label end
end
-- what the fault finder says about each pole, refreshed in the background (it's too heavy for every 2 s solve)
local PoleIssues = {}
local function h2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
local function classOf(r)
    if r.kind ~= 'power' then return nil end
    if r.color == 'transmission' then return 'T' end
    if r.color == 'hv' then return 'H' end
    return nil
end

local function nameOf(kind, f)
    if not f then return '?' end
    local n = S.names['N' .. f.id]
    if n then return n end
    return (kind == 'station' and 'Power station #' or kind == 'sub' and 'Substation #' or kind == 'wind' and 'Wind turbine #' or 'Recloser #') .. f.id
end

local function units(f)
    S.units[f.id] = S.units[f.id] or {}
    local u = S.units[f.id]
    for i = 1, (ST.units or 4) do u[i] = u[i] or { state = 'offline' } end
    return u
end

--- kit was removed (by hand, the Danger zone, the city builder…): forget its alarms, faults, breakers and names, so the grid
--- doesn't stay in ALERT / EMERGENCY over things that aren't there any more
local function pruneGone()
    if not CablingLoaded then return end
    local fx, runs = Cabling.fixtures, Cabling.runs
    local function exists(kind, id)
        id = tonumber(id)
        if not id then return true end
        if kind == 'run' or kind == 'F' or kind == 'L' then return runs[id] ~= nil end
        return fx[id] ~= nil
    end
    local function targetGone(tg)
        if type(tg) ~= 'string' then return false end
        local k, id = tg:match('^(%a+):(%d+)$')
        if k then return not exists(k, id) end
        local b, bid = tg:match('^([FLRIN])(%d+)$')
        if b then return not exists(b, bid) end
        return false
    end
    local changed = false
    for _, e in ipairs(S.events) do
        if e.status == 'active' and targetGone(e.target) then e.status, e.cleared, e.text = 'cleared', now(), (e.text or '') .. ' · kit removed' changed = true end
    end
    for _, tbl in ipairs({ S.runFault }) do for id in pairs(tbl) do if not runs[tonumber(id) or -1] then tbl[id] = nil changed = true end end end
    for _, tbl in ipairs({ S.txFail, S.subs, S.units }) do for id in pairs(tbl) do if not fx[tonumber(id) or -1] then tbl[id] = nil changed = true end end end
    for _, tbl in ipairs({ S.brk, S.prio, S.names }) do
        for key in pairs(tbl) do if targetGone(key) then tbl[key] = nil changed = true end end
    end
    for key in pairs(S.streets or {}) do
        local id = tonumber(tostring(key):match('^P(%d+)$'))
        if id and not fx[id] then S.streets[key] = nil changed = true end
    end
    if changed then saveDirty = true end
end

local function buildTopo()
    local fx, runs = Cabling.fixtures, Cabling.runs
    local t = { stations = {}, winds = {}, subs = {}, pylons = {}, poles = {}, reclosers = {}, transformers = {}, adj = {}, gateOfNode = {},
        runs = {}, feeders = {}, lines = {}, noWay = {}, poleRuns = {} }
    for id, f in pairs(fx) do
        if f.model == ST.model then t.stations[#t.stations + 1] = f units(f)
        elseif f.model == WI.model then t.winds[#t.winds + 1] = f
        elseif isSubAnchor(f.model) then t.subs[#t.subs + 1] = f
        elseif f.model == PY.model then t.pylons[#t.pylons + 1] = f
        elseif isPowerPole(f.model) then t.poles[#t.poles + 1] = f end
    end
    -- substations: an RTU pole beside a building just telemeters it (it isn't a second substation); plant goes to its nearest one
    local keep = {}
    for _, s in ipairs(t.subs) do
        local dup = false
        if s.model == 'opslabs_grid_rtu' then
            for _, o in ipairs(t.subs) do if o ~= s and o.model ~= 'opslabs_grid_rtu' and h2(o, s) <= (SK.radius or 16) + 4 then dup = true end end
        end
        if not dup then keep[#keep + 1] = s end
    end
    t.subs = keep
    local partsOf, partSub = {}, {}
    for id, f in pairs(fx) do
        if isSubPart(f.model) or f.model == 'opslabs_grid_rtu' then
            local best, bd
            for _, s in ipairs(t.subs) do
                local d = h2(f, s)
                if s ~= f and d <= (SK.radius or 16) + (s.model == 'opslabs_grid_rtu' and 4 or 0) and (not bd or d < bd) then best, bd = s, d end
            end
            if best then
                partsOf[best.id] = partsOf[best.id] or {}
                table.insert(partsOf[best.id], { f = f, role = (SK.parts or {})[f.model] or 'rtu' })
                partSub[id] = best.id
            end
        end
    end
    t.partSub = partSub
    for _, s in ipairs(t.subs) do
        s.ways = 0
        s.spec = subSpec(s, fx, partsOf[s.id] or {})
        local st = S.subs[s.id]
        if not st then st = { txOk = s.spec.tx } S.subs[s.id] = st end
        if st.txMax ~= s.spec.tx then                              -- transformers fitted / removed since last time
            st.txOk = math.max(0, math.min(s.spec.tx, (st.txOk or 0) + (s.spec.tx - (st.txMax or st.txOk or 0))))
            st.txMax = s.spec.tx
        end
    end
    -- pole kit: which pole each recloser / transformer is on
    for id, f in pairs(fx) do
        if f.model == CG.Recloser or f.model == CG.Transformer then
            local best, bd
            for _, p in ipairs(t.poles) do
                local d = h2(f, p)
                if d <= (CG.TransformerOnPole or 1.2) and (not bd or d < bd) then best, bd = p, d end
            end
            if f.model == CG.Recloser then
                t.reclosers[#t.reclosers + 1] = { f = f, pole = best and best.id }
            else
                t.transformers[#t.transformers + 1] = { f = f, pole = best and best.id }
            end
        end
    end
    local function link(a, b, gate)
        t.adj[a] = t.adj[a] or {}
        t.adj[b] = t.adj[b] or {}
        table.insert(t.adj[a], { to = b, gate = gate })
        table.insert(t.adj[b], { to = a, gate = gate })
    end
    -- substation: 400 kV bus ↔ 11 kV bus through its transformers (incomer breaker 'I')
    for _, s in ipairs(t.subs) do link('B' .. s.id .. 'T', 'B' .. s.id .. 'H', 'I' .. s.id) end
    -- runs: each end connects to what it touches, by voltage
    local ends = {}
    for rid, r in pairs(runs) do
        local cls = classOf(r)
        if cls and type(r.points) == 'table' and #r.points >= 2 then
            local node = 'r' .. rid
            t.runs[rid] = { id = rid, cls = cls, r = r, touches = {} }
            local touches = t.runs[rid].touches
            -- a jumper snapped off at that kit (server/powerline.lua): the conductor is there but not connected
            local function open(fid) return PowerJumperOpen ~= nil and PowerJumperOpen(fid, rid) end
            for _, p in ipairs({ r.points[1], r.points[#r.points] }) do
                local before = #touches
                local en = { node = node, cls = cls, p = p }
                ends[#ends + 1] = en
                if cls == 'T' then
                    for _, s in ipairs(t.stations) do
                        if h2(p, s) <= (ST.reach or 34) then
                            if open(s.id) then touches[#touches + 1] = { kind = 'station', id = s.id, open = true }
                            else link(node, 'S' .. s.id, 'L' .. rid) t.lines[rid] = true touches[#touches + 1] = { kind = 'station', id = s.id } end
                        end
                    end
                    for _, s in ipairs(t.subs) do
                        if h2(p, s) <= s.spec.reach then
                            if open(s.id) then touches[#touches + 1] = { kind = 'sub', id = s.id, open = true }
                            else link(node, 'B' .. s.id .. 'T', 'L' .. rid) t.lines[rid] = true touches[#touches + 1] = { kind = 'sub', id = s.id } end
                        end
                    end
                    for _, py in ipairs(t.pylons) do
                        if h2(p, py) <= (PY.reach or 9.5) and p.z > py.z - 2 and p.z < py.z + 40 then
                            if open(py.id) then touches[#touches + 1] = { kind = 'pylon', id = py.id, open = true }
                            else link(node, 'P' .. py.id) touches[#touches + 1] = { kind = 'pylon', id = py.id } end
                        end
                    end
                else
                    for _, s in ipairs(t.subs) do
                        if h2(p, s) <= s.spec.reach and open(s.id) then
                            touches[#touches + 1] = { kind = 'sub', id = s.id, open = true }
                        elseif h2(p, s) <= s.spec.reach then
                            -- every 11 kV feeder needs a free circuit breaker in the switchgear
                            s.ways = (s.ways or 0) + 1
                            if s.ways <= s.spec.feeders then
                                link(node, 'B' .. s.id .. 'H', 'F' .. rid) t.feeders[rid] = s.id
                            else t.noWay[rid] = s.id end
                            touches[#touches + 1] = { kind = 'sub', id = s.id }
                        end
                    end
                    for _, w in ipairs(t.winds) do
                        if h2(p, w) <= (WI.reach or 10) then
                            if open(w.id) then touches[#touches + 1] = { kind = 'wind', id = w.id, open = true }
                            else link(node, 'W' .. w.id) touches[#touches + 1] = { kind = 'wind', id = w.id } end
                        end
                    end
                    for _, pl in ipairs(t.poles) do
                        if h2(p, pl) <= 1.6 and p.z > pl.z - 1 and p.z < pl.z + 16 then
                            local o = open(pl.id)
                            if not o then link(node, 'P' .. pl.id) end
                            touches[#touches + 1] = { kind = 'pole', id = pl.id, open = o or nil }
                            t.poleRuns[pl.id] = t.poleRuns[pl.id] or {}
                            table.insert(t.poleRuns[pl.id], { id = rid, cls = 'H', color = r.color, open = o or nil })
                        end
                    end
                end
                en.free = #touches == before          -- landed on nothing: a mid-span joint with another run
            end
        end
    end
    for i = 1, #ends do
        for j = i + 1, #ends do
            local a, b = ends[i], ends[j]
            -- ends on a pole / pylon / substation meet THROUGH it (so a recloser or breaker there can cut them); free ends joint directly
            if a.node ~= b.node and a.cls == b.cls and a.free and b.free and d3(a.p, b.p) <= 0.6 then link(a.node, b.node) end
        end
    end
    -- LV / service conductor on each pole (only for the pole monitor: server/mains.lua solves the LV side)
    for rid, r in pairs(runs) do
        if r.kind == 'power' and not classOf(r) and type(r.points) == 'table' and #r.points >= 2 then
            for _, p in ipairs({ r.points[1], r.points[#r.points] }) do
                for _, pl in ipairs(t.poles) do
                    if h2(p, pl) <= 1.6 and p.z > pl.z - 1 and p.z < pl.z + 16 then
                        t.poleRuns[pl.id] = t.poleRuns[pl.id] or {}
                        table.insert(t.poleRuns[pl.id], { id = rid, cls = 'L', color = r.color, open = (PowerJumperOpen and PowerJumperOpen(pl.id, rid)) or nil })
                    end
                end
            end
        end
    end
    -- everything fitted on each pole (for the pole monitor and OPS Hub)
    t.poleKit = {}
    for id, f in pairs(fx) do
        if not isPowerPole(f.model) then
            for _, pl in ipairs(t.poles) do
                if math.abs(f.x - pl.x) < 1.3 and math.abs(f.y - pl.y) < 1.3 and h2(f, pl) <= 1.2 and f.z > pl.z - 1 and f.z < pl.z + 16 then
                    t.poleKit[pl.id] = t.poleKit[pl.id] or {}
                    table.insert(t.poleKit[pl.id], { id = id, model = f.model, label = KIT_LABEL[f.model] or f.model, h = math.floor((f.z - pl.z) * 10 + 0.5) / 10 })
                    break
                end
            end
        end
    end
    -- a recloser gates its pole (open = nothing passes through that pole)
    for _, rc in ipairs(t.reclosers) do if rc.pole then t.gateOfNode['P' .. rc.pole] = 'R' .. rc.f.id end end
    T = t
    dirtyTopo = false
    pruneGone()
end

---------------------------------------------------------------------------
-- breakers
---------------------------------------------------------------------------

local function brk(key)
    local b = S.brk[key]
    if not b then b = { closed = true } S.brk[key] = b end
    return b
end
local function gateClosed(key)
    if not key then return true end
    local b = S.brk[key]
    if not b then return true end
    return b.closed and not b.shed
end
local function subOf(id)
    if not T then return nil end
    for _, s in ipairs(T.subs) do if s.id == id then return s end end
end
local function subHealthy(id)
    local s = S.subs[id]
    local f = subOf(id)
    if f and f.spec and not f.spec.ok then return false end
    return s ~= nil and not s.fire and not s.maint and (s.txOk or 1) > 0
end

---------------------------------------------------------------------------
-- the solve
---------------------------------------------------------------------------

local function stationAvail(f)
    local mw = 0
    for _, u in ipairs(units(f)) do if u.state == 'online' then mw = mw + (ST.unitMW or 120) end end
    return mw
end

local function profile()
    local p = CG.Profile or {}
    local h = math.floor(env.hour) % 24
    local a, b = p[h + 1] or .7, p[(h + 1) % 24 + 1] or .7
    return a + (b - a) * (env.hour - math.floor(env.hour))
end

local function nodePasses(node)
    local g = T.gateOfNode[node]
    if g and not gateClosed(g) then return false end
    local rid = tonumber(node:match('^r(%d+)$'))
    if rid and S.runFault[rid] then return false end
    return true
end

local function walkUp(n, fn)
    local guard = 0
    while n and R.parent[n] and guard < 5000 do
        guard = guard + 1
        local p = R.parent[n]
        if fn(n, p) then return end
        n = p.from
    end
end

local lastSubsLive = nil
local function solve()
    if dirtyTopo or not T then buildTopo() end
    local energized, parent, island = {}, {}, {}
    local q = {}
    -- sources: power stations with units running (they hold the frequency); wind only runs into a live network
    for _, s in ipairs(T.stations) do
        if stationAvail(s) > 0 then local n = 'S' .. s.id energized[n] = true island[n] = n q[#q + 1] = n end
    end
    local head = 1
    while head <= #q do
        local n = q[head]
        head = head + 1
        for _, e in ipairs(T.adj[n] or {}) do
            if not energized[e.to] and gateClosed(e.gate) then
                local sid = tonumber((e.gate or ''):match('^I(%d+)$'))
                if (not sid or subHealthy(sid)) and nodePasses(e.to) then
                    energized[e.to] = true
                    parent[e.to] = { from = n, gate = e.gate }
                    island[e.to] = island[n]
                    q[#q + 1] = e.to
                end
            end
        end
    end
    R.parent = parent
    -- pole transformers: supplied when their pole is live, the transformer works and the pole's cut-out fuses are in
    local txLive, loads = {}, {}
    local perTx = (CG.TransformerKW or 150) / 1000 * profile()
    for _, tx in ipairs(T.transformers) do
        local id = tx.f.id
        local pn = tx.pole and ('P' .. tx.pole)
        local on = pn and energized[pn] and not S.txFail[id] and true or false
        if on and PolePowerState then local ps = PolePowerState(tx.pole) if ps and ps.fusesOut then on = false end end
        txLive[id] = on
        if on then loads[#loads + 1] = { node = pn, mw = perTx } end
    end
    -- wind turbines feed a live 11 kV network
    local windOut = {}
    for _, w in ipairs(T.winds) do
        local on = false
        for _, e in ipairs(T.adj['W' .. w.id] or {}) do if energized[e.to] then on = e.to break end end
        windOut[w.id] = on and (WI.mw or 3) * env.wind or 0
        if on then windOut['@' .. w.id] = island[on] end
    end
    -- flows: every load walks back to its source; everything on the way carries it
    local flow, gateFlow, islandDemand = {}, {}, {}
    for _, l in ipairs(loads) do
        islandDemand[island[l.node]] = (islandDemand[island[l.node]] or 0) + l.mw
        walkUp(l.node, function(n, p)
            flow[n] = (flow[n] or 0) + l.mw
            if p.gate then gateFlow[p.gate] = (gateFlow[p.gate] or 0) + l.mw end
        end)
    end
    -- each island: generation vs demand → frequency, dispatch, under-frequency load shedding
    local gen, demand, cap, out = 0, 0, 0, {}
    local mainFreq, mainSize = CG.Hz or 50.0, -1
    for _, s in ipairs(T.stations) do
        local src = 'S' .. s.id
        if energized[src] then
            local c = stationAvail(s)
            local D = islandDemand[src] or 0
            local w = 0
            for _, wt in ipairs(T.winds) do if windOut['@' .. wt.id] == src then w = w + windOut[wt.id] end end
            local need = math.max(0, D - w)
            local f = CG.Hz or 50.0
            if need > c then
                f = f - math.min(2.5, (need - c) / math.max(D, 1) * 6)
                local cand = {}
                for rid, sid in pairs(T.feeders) do
                    local key = 'F' .. rid
                    if island['B' .. sid .. 'H'] == src and gateClosed(key) and (gateFlow[key] or 0) > 0 then cand[#cand + 1] = key end
                end
                table.sort(cand, function(a, b)
                    local pa, pb = S.prio[a] or 2, S.prio[b] or 2
                    if pa ~= pb then return pa < pb end
                    return (gateFlow[a] or 0) > (gateFlow[b] or 0)
                end)
                local shedMW = 0
                for _, key in ipairs(cand) do
                    if need - shedMW <= c * 0.98 then break end
                    brk(key).shed = 'ufls'
                    shedMW = shedMW + (gateFlow[key] or 0)
                    event('shed', 'high', ('%s shed — under-frequency'):format(S.names[key] or ('Feeder ' .. key:sub(2))),
                        'Under-frequency relay opened it automatically. Restore it once there is enough generation.', key)
                end
            else
                local reserve = c > 0 and (c - need) / c or 0
                f = f + math.max(-0.08, math.min(0.06, (reserve - 0.12) * 0.15)) + math.sin(now() / 7) * 0.008
            end
            out[src] = math.min(need, c)
            gen = gen + math.min(need, c) + w
            demand = demand + D
            cap = cap + c + w
            if c > mainSize then mainSize, mainFreq = c, f end
        end
    end
    -- substation transformer overload: shed that substation's lowest-priority feeder
    for _, s in ipairs(T.subs) do
        local st = S.subs[s.id]
        local firm = (s.spec.tx > 0) and (s.spec.mva * (st.txOk or 0) / s.spec.tx) or 0
        if firm > 0 and (gateFlow['I' .. s.id] or 0) > firm then
            local pick
            for rid, sid in pairs(T.feeders) do
                local key = 'F' .. rid
                if sid == s.id and gateClosed(key) and (gateFlow[key] or 0) > 0 and (not pick or (S.prio[key] or 2) < (S.prio[pick] or 2)) then pick = key end
            end
            if pick then
                brk(pick).shed = 'overload'
                event('shed', 'high', ('%s shed — transformer overload'):format(S.names[pick] or ('Feeder ' .. pick:sub(2))), ('%s is over its firm capacity'):format(nameOf('sub', s)), pick)
            end
        end
    end
    R.energized, R.flow, R.gateFlow, R.txLive, R.out, R.wind = energized, flow, gateFlow, txLive, out, windOut
    -- substation buildings: lit when their 11 kV bus is live (station supply transformer)
    local subsLive = {}
    for _, s in ipairs(T.subs) do if energized['B' .. s.id .. 'H'] then subsLive[tostring(s.id)] = true end end
    local sj = json.encode(subsLive)
    if sj ~= lastSubsLive then lastSubsLive = sj GlobalState.gridSubsLive = subsLive end
    live.freq = mainSize > 0 and mainFreq or 0.0
    live.gen, live.demand, live.capacity = gen, demand, cap
    live.reserve = cap > 0 and math.max(0, cap - demand) / cap or 0
    live.load = cap > 0 and demand / cap or 0

    -- to the game: which pole transformers are supplied (server/mains.lua re-solves the LV side)
    local txJson = json.encode(txLive)
    if txJson ~= lastTxJson then
        lastTxJson = txJson
        if MainsDirty then MainsDirty() end
    end
    local jobs = {}
    for _, e in ipairs(S.events) do
        if e.status == 'active' and e.crew and e.x then jobs[#jobs + 1] = { id = e.id, title = e.title, x = e.x, y = e.y } end
    end
    local jj = json.encode(jobs)
    if jj ~= lastJobs then lastJobs = jj GlobalState.gridJobs = jobs end
end

--- server/mains.lua: does this pole transformer get 11 kV from the grid?
function GridTransformerLive(id) return R.txLive[tonumber(id)] == true end
--- server/powerline.lua: is a grid node live ('S12' station, 'P5' pole / pylon, 'B3H' / 'B3T' substation bus, 'W2', 'r40' run)
function GridNodeLive(node) if not T then solve() end return R.energized[node] == true end
function GridRunFlow(rid) return R.flow['r' .. tostring(rid)] or 0 end
--- what a substation can do (plant fitted, missing plant, feeder ways)
function GridSubSpec(id)
    if not T then solve() end
    for _, s in ipairs(T.subs) do if s.id == id then return s.spec, s.ways end end
end

---------------------------------------------------------------------------
-- protection: trips, auto-reclose, overloads, faults
---------------------------------------------------------------------------

--- the nearest breaker / recloser upstream of a node
local function upstreamGate(node)
    if T.gateOfNode[node] then return T.gateOfNode[node] end
    local found
    walkUp(node, function(n, p)
        if p.gate then found = p.gate return true end
        if T.gateOfNode[p.from] then found = T.gateOfNode[p.from] return true end
    end)
    return found
end

local function gateLabel(key)
    if S.names[key] then return S.names[key] end
    local k, id = key:sub(1, 1), key:sub(2)
    return k == 'F' and ('Feeder ' .. id) or k == 'L' and ('Line ' .. id) or k == 'R' and ('Recloser #' .. id) or k == 'I' and ('Substation #' .. id .. ' incomer') or key
end

local function trip(key, reason, faultRid)
    local b = brk(key)
    if not b.closed then return end
    b.closed, b.tries, b.fault = false, 0, faultRid
    local RC = CG.Reclose or {}
    local kind = key:sub(1, 1)
    local max = kind == 'R' and (RC.recloser or 2) or kind == 'F' and (RC.feeder or 1) or kind == 'L' and (RC.line or 1) or 0
    b.maxTries = max
    b.recloseAt = (max > 0 and faultRid) and (now() + 3) or nil
    event('trip', 'high', ('%s tripped'):format(gateLabel(key)), reason .. (b.recloseAt and ' · auto-reclose in 3 s' or ''), key)
    saveDirty = true
end

local function autoReclose()
    for key, b in pairs(S.brk) do
        if b.recloseAt and now() >= b.recloseAt then
            b.tries = (b.tries or 0) + 1
            local f = b.fault and S.runFault[b.fault]
            if not f or f.kind == 'transient' then
                if f then S.runFault[b.fault] = nil clearEvents('run:' .. b.fault) end
                b.closed, b.recloseAt, b.fault, b.lockout = true, nil, nil, nil
                clearEvents(key, 'trip')
                event('reclose', 'low', ('%s auto-reclosed'):format(gateLabel(key)), 'Transient fault cleared — supply restored', key)
            elseif b.tries < (b.maxTries or 1) then
                b.recloseAt = now() + 5
                event('reclose', 'medium', ('%s reclose failed (%d/%d)'):format(gateLabel(key), b.tries, b.maxTries), 'Fault still there — trying again', key)
            else
                b.recloseAt, b.lockout = nil, true
                event('lockout', 'high', ('%s LOCKED OUT'):format(gateLabel(key)), 'Permanent fault. A crew has to repair it before it can be closed again.', key)
            end
            saveDirty = true
        end
    end
end

local function overloads()
    for rid, run in pairs(T.runs) do
        local n = 'r' .. rid
        local rating = (CG.Ratings or {})[run.cls == 'T' and 'transmission' or 'hv'] or 8
        local loading = (R.flow[n] or 0) / rating
        run.loading = loading
        if loading > 1.0 then
            run.overSince = run.overSince or now()
            if now() - run.overSince >= (loading > 1.2 and 2 or 20) then
                run.overSince = nil
                local g = upstreamGate(n)
                if g then trip(g, ('Overcurrent: run #%d at %d%% of its rating'):format(rid, math.floor(loading * 100))) end
            end
        else run.overSince = nil end
    end
end

local function randomFault()
    local r = math.random()
    local liveRuns = {}
    for rid, run in pairs(T.runs) do if R.energized['r' .. rid] and not S.runFault[rid] then liveRuns[#liveRuns + 1] = run end end
    if r < 0.6 and #liveRuns > 0 then
        local run = liveRuns[math.random(#liveRuns)]
        local p = run.r.points[math.random(#run.r.points)]
        local permanent = math.random() < (env.storm and 0.45 or 0.3)
        local cause = env.storm and ({ 'lightning strike', 'tree blown into the conductors', 'conductor clash in high wind' })[math.random(3)]
            or ({ 'tree contact', 'bird / animal contact', 'insulator flashover', 'broken binder' })[math.random(4)]
        S.runFault[run.id] = { kind = permanent and 'permanent' or 'transient', x = p.x, y = p.y, z = p.z, cause = cause }
        local g = upstreamGate('r' .. run.id)
        local what = run.cls == 'T' and '400 kV' or '11 kV'
        if permanent then event('fault', 'high', ('%s fault on run #%d'):format(what, run.id), cause .. ' · crew needed at the yellow marker', 'run:' .. run.id, p, true) end
        if g then trip(g, ('%s fault on run #%d (%s)'):format(what, run.id, cause), run.id) end
    elseif r < 0.75 and #T.transformers > 0 then
        local tx = T.transformers[math.random(#T.transformers)]
        if R.txLive[tx.f.id] then
            S.txFail[tx.f.id] = true
            event('txfail', 'high', ('Pole transformer #%d failed'):format(tx.f.id), 'The homes it feeds are off. Crew to replace it.', 'tx:' .. tx.f.id, { x = tx.f.x, y = tx.f.y, z = tx.f.z }, true)
        end
    elseif r < 0.87 and #T.subs > 0 then
        local s = T.subs[math.random(#T.subs)]
        local st = S.subs[s.id]
        if subHealthy(s.id) then
            if math.random() < 0.2 then
                st.fire = true
                event('fire', 'critical', ('FIRE at %s'):format(nameOf('sub', s)), 'Substation tripped out. Fire service, then a crew to make safe and repair.', 'sub:' .. s.id, { x = s.x, y = s.y, z = s.z }, true)
            else
                st.txOk = math.max(0, (st.txOk or 2) - 1)
                event('subtx', 'high', ('%s — transformer unavailable'):format(nameOf('sub', s)), ('Buchholz / differential protection tripped it · %d left in service'):format(st.txOk),
                    'sub:' .. s.id, { x = s.x, y = s.y, z = s.z }, true)
            end
        end
    elseif #T.stations > 0 then
        local s = T.stations[math.random(#T.stations)]
        for i, u in ipairs(units(s)) do
            if u.state == 'online' then
                u.state = 'tripped'
                event('unit', 'high', ('%s unit %d tripped'):format(nameOf('station', s), i), 'Generator protection · restart it when ready', 'station:' .. s.id, { x = s.x, y = s.y, z = s.z })
                break
            end
        end
    end
    saveDirty = true
end

---------------------------------------------------------------------------
-- loops
---------------------------------------------------------------------------

local RANK = { normal = 0, alert = 1, emergency = 2, restoration = 3 }

CreateThread(function()
    while not S.ready or not Cabling or not Cabling.fixtures do Wait(500) end
    Wait(2000)
    local lastRand, lastSave = os.time(), os.time()
    while true do
        env.wind = math.max(0.1, math.min(0.95, env.wind + (math.random() - 0.5) * 0.03 + (env.storm and 0.01 or -0.002)))
        for _, us in pairs(S.units) do
            for _, u in ipairs(us) do if u.state == 'starting' and u.readyAt and now() >= u.readyAt then u.state, u.readyAt = 'online', nil end end
        end
        autoReclose()
        solve()
        overloads()
        if os.time() - lastRand >= 10 then
            lastRand = os.time()
            local p = (CG.FaultRate or 0.6) / 360 * (env.storm and (CG.StormFactor or 8) or 1)
            if math.random() < p then randomFault() solve() end
        end
        local auto = 'normal'
        for _, b in pairs(S.brk) do
            if b.shed == 'ufls' then auto = 'emergency' end
            if (b.lockout or b.shed) and auto == 'normal' then auto = 'alert' end
        end
        if #T.stations > 0 then
            for _, s in ipairs(T.subs) do if not R.energized['B' .. s.id .. 'H'] then auto = 'emergency' end end
        end
        if auto == 'normal' and (env.storm or (live.capacity > 0 and live.reserve < 0.1) or next(S.runFault) or next(S.txFail)) then auto = 'alert' end
        S.level = (S.manualLevel and RANK[S.manualLevel] > RANK[auto]) and S.manualLevel or auto
        if saveDirty and os.time() - lastSave >= 10 then lastSave = os.time() save() end
        Wait((CG.Tick or 2) * 1000)
    end
end)

CreateThread(function()
    while true do
        local players = GetPlayers()
        if #players > 0 then
            local ok, h, w = pcall(lib.callback.await, 'opslabs-towers:sky', tonumber(players[math.random(#players)]))
            if ok and tonumber(h) then
                env.hour = tonumber(h)
                local was = env.storm
                env.weather = type(w) == 'string' and w or env.weather
                env.storm = env.weather == 'THUNDER' or env.weather == 'BLIZZARD'
                if env.storm and not was then event('storm', 'medium', 'Storm warning', 'Thunderstorms over San Andreas — overhead line faults are much more likely.', 'storm') end
                if was and not env.storm then clearEvents('storm') addLog('system', 'The storm has passed') end
            end
        end
        Wait(60000)
    end
end)
AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() and S.ready then save() end end)

---------------------------------------------------------------------------
-- crews: repairs at the real spot
---------------------------------------------------------------------------

local function isCrew(src)
    if CanCable and CanCable(src) then return true end
    local job = FW.Job and FW.Job(src)
    for _, j in ipairs(CG.CrewJobs or {}) do if j == job then return true end end
    return false
end
lib.callback.register('opslabs-towers:grid:isCrew', function(src) return isCrew(src) end)

lib.callback.register('opslabs-towers:grid:repair', function(src, eid)
    if not isCrew(src) then return { error = 'Only grid crews can repair this' } end
    local e
    for _, x in ipairs(S.events) do if x.id == eid and x.status == 'active' and x.crew then e = x end end
    if not e then return { error = 'That job is already done' } end
    local p = GetEntityCoords(GetPlayerPed(src))
    if math.sqrt((p.x - e.x) ^ 2 + (p.y - e.y) ^ 2) > 30.0 then return { error = 'Get to the fault first' } end
    local kind, id = (e.target or ''):match('^(%a+):(.+)$')
    id = tonumber(id) or id
    local who = GetPlayerName(src)
    if kind == 'run' then S.runFault[id] = nil
    elseif kind == 'tx' then S.txFail[id] = nil
    elseif kind == 'sub' and S.subs[id] then
        local st = S.subs[id]
        local sf = subOf(id)
        if st.fire then st.fire = false else st.txOk = math.min(sf and sf.spec.tx or SU.tx or 2, (st.txOk or 0) + 1) end
    end
    clearEvents(e.target)
    e.status = 'cleared'
    event('repaired', 'low', ('Repaired: %s'):format(e.title), ('Crew %s reports it repaired — close the tripped breaker / recloser to restore.'):format(who), e.target)
    saveDirty = true
    solve()
    return { ok = true, text = kind == 'tx' and 'New transformer fitted — the homes behind it are back' or 'Repair done — close the tripped breaker / recloser to restore' }
end)

---------------------------------------------------------------------------
-- power fault finder (server/powerdiag.lua): why a pole transformer has no 11 kV, and fixing one cause
---------------------------------------------------------------------------

--- every reason this pole transformer is dead, upstream first: { code, text, fix, fixable, key / id } (empty = it's live)
function GridWhy(txId)
    txId = tonumber(txId)
    if not T then solve() end
    local out = {}
    if R.txLive[txId] then return out end
    local tx
    for _, x in ipairs(T.transformers) do if x.f.id == txId then tx = x end end
    if not tx then return out end
    if not tx.pole then
        out[#out + 1] = { code = 'tx_off_pole', text = 'The transformer isn’t fitted on a power pole', fix = 'Move it onto a pole (within ' .. (CG.TransformerOnPole or 1.2) .. ' m)' }
        return out
    end
    if S.txFail[txId] then out[#out + 1] = { code = 'tx_failed', text = ('Pole transformer #%d has failed'):format(txId), fix = 'Fit a new transformer', fixable = true, id = txId } end
    local ps = PolePowerState and PolePowerState(tx.pole)
    if ps and ps.fusesOut then out[#out + 1] = { code = 'fuses_out', text = ('The cut-out fuses on pole #%d are out%s'):format(tx.pole, ps.earthed and ' and it is earthed' or ''),
        fix = (ps.earthed and 'Take the earths off, then put' or 'Put') .. ' the fuses back in (operating rod)', fixable = true, id = tx.pole } end
    -- the way back to a power station, ignoring breakers, faults and substation health (BFS over everything built)
    local start = 'P' .. tx.pole
    local prev, q, head, found = { [start] = false }, { start }, 1, nil
    while head <= #q and not found do
        local n = q[head]
        head = head + 1
        for _, e in ipairs(T.adj[n] or {}) do
            if prev[e.to] == nil then
                prev[e.to] = { from = n, gate = e.gate }
                if e.to:match('^S%d+$') then found = e.to break end
                q[#q + 1] = e.to
            end
        end
    end
    if not found then
        local feeder = false
        for k in pairs(prev) do if k:match('^B%d+H$') then feeder = true end end
        out[#out + 1] = { code = 'no_route', text = feeder and ('Pole #%d reaches a substation, but the substation has no 400 kV line back to a power station'):format(tx.pole)
            or ('Pole #%d isn’t on an 11 kV feeder — no HV conductor connects it back to a substation'):format(tx.pole),
            fix = feeder and 'Run 400 kV transmission (pylons) from a power station to the substation' or 'String 11 kV (HV) conductor pole to pole back to a substation' }
        return out
    end
    -- walk the route from the transformer's pole to the station: everything that stops power on the way
    local n = start
    local function check(node)
        local g = T.gateOfNode[node]
        if g and not gateClosed(g) then
            local b = S.brk[g] or {}
            out[#out + 1] = { code = 'breaker_open', key = g, text = ('%s is %s'):format(gateLabel(g), b.lockout and 'locked out' or b.shed and ('shed (' .. b.shed .. ')') or 'open'), fix = 'Close it', fixable = true }
        end
        local rid = tonumber(node:match('^r(%d+)$'))
        if rid and S.runFault[rid] then
            out[#out + 1] = { code = 'line_fault', id = rid, text = ('Line fault on %s run #%d (%s)'):format(T.runs[rid] and T.runs[rid].cls == 'T' and '400 kV' or '11 kV', rid, S.runFault[rid].kind or 'fault'), fix = 'Repair the line', fixable = true }
        end
        if T.noWay[rid or -1] then
            local sf = subOf(T.noWay[rid])
            out[#out + 1] = { code = 'no_way', text = ('%s has no free 11 kV feeder breaker for run #%d'):format(nameOf('sub', sf), rid), fix = 'Fit another 11 kV switchgear lineup in the substation' }
        end
    end
    local guard = 0
    while n and n ~= found and guard < 5000 do
        guard = guard + 1
        check(n)
        local p = prev[n]
        if not p then break end
        if p.gate and not gateClosed(p.gate) then
            local b = S.brk[p.gate] or {}
            out[#out + 1] = { code = 'breaker_open', key = p.gate, text = ('%s is %s'):format(gateLabel(p.gate), b.lockout and 'locked out' or b.shed and ('shed (' .. b.shed .. ')') or 'open'), fix = 'Close it', fixable = true }
        end
        local sid = tonumber((p.gate or ''):match('^I(%d+)$'))
        if sid and not subHealthy(sid) then
            local st, sf = S.subs[sid] or {}, subOf(sid)
            if sf and sf.spec and not sf.spec.ok then
                out[#out + 1] = { code = 'sub_kit', text = ('%s is missing plant: %s'):format(nameOf('sub', sf), table.concat(sf.spec.missing or {}, ', ')), fix = 'Fit the missing plant in the substation' }
            end
            if st.fire then out[#out + 1] = { code = 'sub_fire', id = sid, text = nameOf('sub', sf) .. ' is on fire / fire-damaged', fix = 'Put it out and repair it', fixable = true } end
            if st.maint then out[#out + 1] = { code = 'sub_maint', id = sid, text = nameOf('sub', sf) .. ' is out for maintenance', fix = 'Return it to service', fixable = true } end
            if (st.txOk or 1) <= 0 then out[#out + 1] = { code = 'sub_tx', id = sid, text = nameOf('sub', sf) .. ' has no power transformer in service', fix = 'Repair its transformers', fixable = true } end
        end
        n = p.from
    end
    local stf = Cabling.fixtures[tonumber(found:sub(2))]
    if stf and stationAvail(stf) <= 0 then
        local starting = false
        for _, u in ipairs(units(stf)) do if u.state == 'starting' then starting = true end end
        out[#out + 1] = { code = 'no_generation', id = stf.id, text = nameOf('station', stf) .. (starting and ' is still synchronising a unit' or ' has no generating units running'),
            fix = 'Start a generating unit', fixable = not starting }
    end
    -- reverse: upstream causes first
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    return rev
end

function GridResolve() solve() end

--- fix one cause GridWhy found; returns the text of what was done
function GridFix(issue, by)
    by = tostring(by or 'crew'):sub(1, 60)
    local c = issue.code
    if c == 'tx_failed' then S.txFail[issue.id] = nil clearEvents('tx:' .. issue.id)
    elseif c == 'line_fault' then S.runFault[issue.id] = nil clearEvents('run:' .. issue.id)
    elseif c == 'breaker_open' then
        local b = brk(issue.key)
        b.closed, b.shed, b.lockout, b.recloseAt, b.tries = true, nil, nil, nil, 0
        clearEvents(issue.key)
    elseif c == 'sub_fire' and S.subs[issue.id] then S.subs[issue.id].fire = false clearEvents('sub:' .. issue.id)
    elseif c == 'sub_maint' and S.subs[issue.id] then S.subs[issue.id].maint = nil
    elseif c == 'sub_tx' and S.subs[issue.id] then local sf = subOf(issue.id) S.subs[issue.id].txOk = sf and sf.spec.tx or SU.tx or 2 clearEvents('sub:' .. issue.id)
    elseif c == 'no_generation' then
        local f = Cabling.fixtures[issue.id]
        if not f then return nil end
        for _, u in ipairs(units(f)) do if not u.maint then u.state, u.readyAt = 'online', nil break end end
        clearEvents('station:' .. f.id, 'unit')
    else return nil end
    addLog(by, 'Power restoration kit: ' .. issue.text .. ' → fixed')
    saveDirty = true
    solve()
    return issue.fix
end

---------------------------------------------------------------------------
-- state for OPS Hub + in-game panels, and operator actions
---------------------------------------------------------------------------

local function bstate(key)
    local b = S.brk[key] or { closed = true }
    return { key = key, closed = (b.closed and not b.shed) and true or false, shed = b.shed, lockout = b.lockout, tries = b.tries, recloseAt = b.recloseAt, name = S.names[key] }
end

local function ptsOf(r)
    local out, p = {}, r.points or {}
    local n = #p
    local k = math.max(1, math.floor(n / 40))
    for i = 1, n, k do out[#out + 1] = { math.floor(p[i].x * 10) / 10, math.floor(p[i].y * 10) / 10 } end
    if n > 0 and (n - 1) % k ~= 0 then out[#out + 1] = { math.floor(p[n].x * 10) / 10, math.floor(p[n].y * 10) / 10 } end
    return out
end

local function crews()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if isCrew(src) then
            local c = GetEntityCoords(GetPlayerPed(src))
            out[#out + 1] = { id = src, name = GetPlayerName(src), x = c.x, y = c.y }
        end
    end
    return out
end

--- the feeder breaker (F...) a pole is supplied through
local function feederOf(poleId)
    local found
    walkUp('P' .. poleId, function(_, p) if p.gate and p.gate:sub(1, 1) == 'F' then found = p.gate return true end end)
    return found
end

---------------------------------------------------------------------------
-- power poles: live data for the LineSense monitor on every pole (client/powerline.lua) and OPS Hub
---------------------------------------------------------------------------

local AMPS_PER_MW = 1e6 / (math.sqrt(3) * 11000)          -- 11 kV three-phase: ≈ 52.5 A per MW

--- every pole, or only the ids asked for
function GridPoles(only)
    if not T then solve() end
    local want
    if type(only) == 'table' then want = {} for _, id in ipairs(only) do want[tonumber(id) or -1] = true end end
    local txBy, rcBy, subName = {}, {}, {}
    for _, tx in ipairs(T.transformers) do if tx.pole then txBy[tx.pole] = txBy[tx.pole] or {} table.insert(txBy[tx.pole], tx) end end
    for _, rc in ipairs(T.reclosers) do if rc.pole then rcBy[rc.pole] = rc end end
    for _, s in ipairs(T.subs) do subName[s.id] = nameOf('sub', s) end
    local perTxKW = (CG.TransformerKW or 150) * profile()
    local out = {}
    for _, p in ipairs(T.poles) do
        local id = p.id
        if not want or want[id] then
            local hv = R.energized['P' .. id] == true
            local lv = MainsPoleLive ~= nil and MainsPoleLive[id] == true
            local flow = hv and (R.flow['P' .. id] or 0) or 0
            local fd = hv and feederOf(id) or nil
            local rid = fd and tonumber(fd:sub(2))
            local sid = rid and T.feeders[rid]
            local runs, nh, nl, op, fault = T.poleRuns[id] or {}, 0, 0, 0, false
            for _, r in ipairs(runs) do
                if r.cls == 'H' then nh = nh + 1 else nl = nl + 1 end
                if r.open then op = op + 1 end
                if S.runFault[r.id] then fault = true end
            end
            local txs, txl = txBy[id] or {}, 0
            for _, tx in ipairs(txs) do if R.txLive[tx.f.id] then txl = txl + 1 end end
            local rc = rcBy[id]
            local rb = rc and bstate('R' .. rc.f.id)
            local ps = PolePowerState and PolePowerState(id) or {}
            out[#out + 1] = {
                id = id, name = S.names['N' .. id] or ('Pole #' .. id), model = p.model, x = p.x, y = p.y, z = p.z, street = S.streets['P' .. id],
                hv = hv, lv = lv, live = hv or lv, mw = flow, amps = hv and flow * AMPS_PER_MW or 0, kw = txl * perTxKW,
                kv = nh > 0 and 11 or (nl > 0 and 0.4 or nil),
                feeder = fd, feederName = fd and (S.names[fd] or ('Feeder ' .. rid)) or nil, sub = sid, subName = sid and subName[sid] or nil,
                recloser = rb and { key = rb.key, id = rc.f.id, name = S.names['R' .. rc.f.id] or ('Recloser #' .. rc.f.id), closed = rb.closed, lockout = rb.lockout, shed = rb.shed } or nil,
                tx = #txs, txLive = txl, hvRuns = nh, lvRuns = nl, open = op, fault = fault or nil,
                fusesOut = ps.fusesOut or nil, earthed = ps.earthed or nil, runs = runs,
                kit = T.poleKit and T.poleKit[id] or {}, faults = {}, issues = PoleIssues[id],
            }
            -- active network faults on the pole or anything fitted to it
            local row = out[#out]
            local onKit = {}
            for _, k in ipairs(row.kit) do onKit[k.id] = true end
            for _, x in pairs(Faults or {}) do
                if (x.status == 'open' or x.status == 'acknowledged' or x.status == 'in_progress')
                    and (x.pole_id == id or (x.asset and x.asset.kind == 'fixture' and onKit[x.asset.id])) then
                    row.faults[#row.faults + 1] = { id = x.id, label = x.label, severity = x.severity, status = x.status, asset = x.asset and x.asset.label, at = x.created_at or x.at }
                end
            end
            -- grid alarms on this pole (crew requests, its transformer / recloser)
            for _, e in ipairs(S.events) do
                if e.status == 'active' and (e.target == 'pole:' .. id or (rc and (e.target == 'R' .. rc.f.id))) then
                    row.faults[#row.faults + 1] = { event = e.id, label = e.title, severity = e.sev, status = e.dispatched and 'crew dispatched' or 'active', grid = true }
                end
            end
            for _, tx in ipairs(txs) do
                if S.txFail[tx.f.id] then row.faults[#row.faults + 1] = { label = 'Pole transformer #' .. tx.f.id .. ' failed', severity = 'high', status = 'needs a crew', grid = true } end
            end
        end
    end
    return out
end

-- every 30 s: the fault finder's reasons for each pole (no power, open breaker upstream, missing cable …) for OPS Hub
CreateThread(function()
    Wait(20000)
    while true do
        if T and PowerDiagFixture then
            if MainsRecompute then pcall(MainsRecompute) end
            local n = 0
            for _, p in ipairs(T.poles) do
                local ok, d = pcall(PowerDiagFixture, p.id, true)
                if ok and d then
                    local list = {}
                    for _, x in ipairs(d.issues or {}) do if #list < 8 then list[#list + 1] = { text = x.text, fix = x.fix, grid = x.grid or nil } end end
                    PoleIssues[p.id] = list
                end
                n = n + 1
                if n % 20 == 0 then Wait(0) end
            end
            for id in pairs(PoleIssues) do if not Cabling.fixtures[id] then PoleIssues[id] = nil end end
        end
        Wait(30000)
    end
end)

lib.callback.register('opslabs-towers:grid:poles', function(_, ids)
    if type(ids) ~= 'table' or #ids > 40 then return {} end
    return GridPoles(ids)
end)

-- the street a pole stands on comes from the first player who sees its monitor (the server has no map)
RegisterNetEvent('opslabs-towers:grid:poleStreet', function(id, street)
    id = tonumber(id)
    local f = id and Cabling.fixtures[id]
    if not f or not isPowerPole(f.model) or type(street) ~= 'string' or #street == 0 or #street > 60 then return end
    if S.streets['P' .. id] == street then return end
    local p = GetEntityCoords(GetPlayerPed(source))
    if (p.x ~= 0.0 or p.y ~= 0.0) and h2(p, f) > 150 then return end
    S.streets['P' .. id] = street
    saveDirty = true
end)

function GridState()
    if not T then solve() end
    local stations, winds, subs, lines, feeders, spans, reclosers, transformers = {}, {}, {}, {}, {}, {}, {}, {}
    local subName = {}
    for _, s in ipairs(T.subs) do subName[s.id] = nameOf('sub', s) end
    for _, s in ipairs(T.stations) do
        local us = {}
        for i, u in ipairs(units(s)) do us[i] = { state = u.state, readyAt = u.readyAt, maint = u.maint } end
        stations[#stations + 1] = { id = s.id, name = nameOf('station', s), x = s.x, y = s.y, units = us, unitMW = ST.unitMW or 120,
            avail = stationAvail(s), out = R.out['S' .. s.id] or 0, energized = R.energized['S' .. s.id] or false }
    end
    for _, w in ipairs(T.winds) do winds[#winds + 1] = { id = w.id, name = nameOf('wind', w), x = w.x, y = w.y, mw = WI.mw or 3, out = R.wind[w.id] or 0 } end
    for _, s in ipairs(T.subs) do
        local st = S.subs[s.id]
        local fl = {}
        for rid, sid in pairs(T.feeders) do if sid == s.id then fl[#fl + 1] = 'F' .. rid end end
        table.sort(fl)
        local sp = s.spec
        local noWay = 0
        for _, sid in pairs(T.noWay) do if sid == s.id then noWay = noWay + 1 end end
        subs[#subs + 1] = { id = s.id, name = subName[s.id], x = s.x, y = s.y, mva = sp.mva, tx = sp.tx, txOk = st.txOk, fire = st.fire or nil, maint = st.maint or nil,
            kind = sp.kind, ready = sp.ok, missing = sp.missing, scada = sp.scada, control = sp.control, metered = sp.meter, ways = sp.feeders < 99 and sp.feeders or nil,
            noWay = noWay > 0 and noWay or nil, kit = sp.kit,
            incomer = bstate('I' .. s.id), energized = R.energized['B' .. s.id .. 'H'] or false, hv400 = R.energized['B' .. s.id .. 'T'] or false,
            load = R.gateFlow['I' .. s.id] or 0, feeders = fl }
    end
    local txOn = {}
    for _, tx in ipairs(T.transformers) do
        local g = tx.pole and R.energized['P' .. tx.pole] and feederOf(tx.pole)
        if g then txOn[g] = txOn[g] or { n = 0, live = 0 } txOn[g].n = txOn[g].n + 1 if R.txLive[tx.f.id] then txOn[g].live = txOn[g].live + 1 end end
        local ps = tx.pole and PolePowerState and PolePowerState(tx.pole)
        transformers[#transformers + 1] = { id = tx.f.id, x = tx.f.x, y = tx.f.y, live = R.txLive[tx.f.id] or false, failed = S.txFail[tx.f.id] or nil,
            onPole = tx.pole ~= nil, fusesOut = ps and ps.fusesOut or nil, feeder = g or nil }
    end
    for rid, run in pairs(T.runs) do
        local rf = S.runFault[rid]
        local item = { id = rid, cls = run.cls, pts = ptsOf(run.r), energized = R.energized['r' .. rid] or false, flow = R.flow['r' .. rid] or 0,
            loading = run.loading or 0, rating = (CG.Ratings or {})[run.cls == 'T' and 'transmission' or 'hv'], fault = rf and rf.kind or nil,
            fx = rf and rf.x or nil, fy = rf and rf.y or nil, length = run.r.length }
        if T.lines[rid] then
            -- the whole circuit: follow the 400 kV spans over the pylons to the station / substation at each end
            local names, seen, q = {}, { ['r' .. rid] = true }, { 'r' .. rid }
            local got = {}
            while #q > 0 do
                local n = table.remove(q)
                for _, e in ipairs(T.adj[n] or {}) do
                    local to = e.to
                    if not seen[to] then
                        seen[to] = true
                        local sid = tonumber(to:match('^S(%d+)$'))
                        local bid = tonumber(to:match('^B(%d+)T$'))
                        if sid and not got[to] then got[to] = true names[#names + 1] = nameOf('station', Cabling.fixtures[sid])
                        elseif bid and not got[to] then got[to] = true names[#names + 1] = subName[bid]
                        elseif to:match('^r%d+$') or to:match('^P%d+$') then q[#q + 1] = to end
                    end
                end
            end
            item.breaker = bstate('L' .. rid)
            item.ends = names
            item.name = S.names['L' .. rid] or ('Line ' .. rid .. (#names > 0 and (' · ' .. table.concat(names, ' – ')) or ''))
            lines[#lines + 1] = item
        elseif T.feeders[rid] then
            local key = 'F' .. rid
            item.breaker = bstate(key)
            item.sub, item.subName = T.feeders[rid], subName[T.feeders[rid]]
            item.name = S.names[key] or ('Feeder ' .. rid)
            item.priority = S.prio[key] or 2
            item.load = R.gateFlow[key] or 0
            item.transformers = txOn[key] and txOn[key].n or 0
            item.liveTx = txOn[key] and txOn[key].live or 0
            feeders[#feeders + 1] = item
        else
            spans[#spans + 1] = item
        end
    end
    table.sort(lines, function(a, b) return a.id < b.id end)
    table.sort(feeders, function(a, b) return a.id < b.id end)
    for _, rc in ipairs(T.reclosers) do
        local key = 'R' .. rc.f.id
        local b = bstate(key)
        b.id, b.x, b.y, b.pole = rc.f.id, rc.f.x, rc.f.y, rc.pole
        b.name = S.names[key] or ('Recloser #' .. rc.f.id)
        b.energized = rc.pole and R.energized['P' .. rc.pole] or false
        b.feeder = rc.pole and feederOf(rc.pole) or nil
        reclosers[#reclosers + 1] = b
    end
    local procs = {}
    for _, p in ipairs(PROCEDURES) do procs[#procs + 1] = { id = p.id, title = p.title, steps = p.steps, done = S.procs[p.id] or {} } end
    return {
        hz = CG.Hz or 50.0, freq = live.freq, gen = live.gen, demand = live.demand, capacity = live.capacity, reserve = live.reserve, load = live.load,
        level = S.level, manualLevel = S.manualLevel, storm = env.storm, weather = env.weather, hour = env.hour, wind = env.wind,
        stations = stations, winds = winds, subs = subs, lines = lines, feeders = feeders, spans = spans, reclosers = reclosers, transformers = transformers,
        pylons = (function() local o = {} for _, p in ipairs(T.pylons) do o[#o + 1] = { id = p.id, x = p.x, y = p.y } end return o end)(),
        ratings = CG.Ratings, events = S.events, log = S.log, procedures = procs, crews = crews(), now = now(), poles = GridPoles(),
        built = { stations = #T.stations, winds = #T.winds, subs = #T.subs, pylons = #T.pylons, poles = #T.poles, transformers = #T.transformers, reclosers = #T.reclosers },
    }
end

local function notice(audience, text, key, by)
    text = tostring(text or ''):sub(1, 240)
    if text == '' then return nil, 'Write a message' end
    local near = {}
    if audience == 'feeder' and key then
        for _, tx in ipairs(T.transformers) do if tx.pole and feederOf(tx.pole) == key then near[#near + 1] = tx.f end end
    end
    local count = 0
    for _, pid in ipairs(GetPlayers()) do
        local src = tonumber(pid)
        local send = audience == 'all' or (audience == 'crews' and isCrew(src))
        if audience == 'feeder' then
            local c = GetEntityCoords(GetPlayerPed(src))
            for _, f in ipairs(near) do if math.sqrt((c.x - f.x) ^ 2 + (c.y - f.y) ^ 2) < 180 then send = true break end end
        end
        if send then
            count = count + 1
            TriggerClientEvent('opslabs-towers:gridNotice', src, { text = text, from = audience == 'crews' and 'Grid control' or 'San Andreas Power & Light' })
            if audience ~= 'crews' and GetResourceState('opslabs-phone') == 'started' then
                pcall(function() exports['opslabs-phone']:Notify(src, 'San Andreas Power & Light', text, 'system', 'fa-solid fa-bolt') end)
            end
        end
    end
    addLog(by, ('Notice to %s%s (%d player%s): %s'):format(audience, key and (' · ' .. gateLabel(key)) or '', count, count == 1 and '' or 's', text))
    return count
end

function GridAction(d, by)
    if not T then solve() end
    by = tostring(by or 'operator'):sub(1, 80)
    local a, key = d.action, d.key and tostring(d.key) or nil
    local function done(text) addLog(by, text) saveDirty = true solve() return true end
    -- a substation without SCADA (no RTU) can't be switched from control — only on site
    if (a == 'open' or a == 'close' or a == 'shed') and key and not by:find('%(on site%)$') then
        local sid = key:match('^I%d+$') and tonumber(key:sub(2)) or (key:match('^F%d+$') and T.feeders[tonumber(key:sub(2))])
        local sf = sid and subOf(sid)
        if sf and not sf.spec.scada then return nil, ('%s has no SCADA (fit an RTU pole) — it can only be switched on site'):format(nameOf('sub', sf)) end
    end
    if (a == 'open' or a == 'close') and key and key:match('^[FLRI]%d+$') then
        local b = brk(key)
        if a == 'open' then
            b.closed, b.recloseAt = false, nil
            return done(('Opened %s'):format(gateLabel(key)))
        end
        local kind, id = key:sub(1, 1), tonumber(key:sub(2))
        if (kind == 'F' or kind == 'L') and S.runFault[id] and S.runFault[id].kind == 'permanent' then return nil, 'That run still has a fault on it — the crew has to repair it first' end
        if kind == 'I' and not subHealthy(id) then return nil, 'The substation is not fit to energise (fire, no transformers in service or maintenance)' end
        b.closed, b.shed, b.lockout, b.recloseAt, b.tries = true, nil, nil, nil, 0
        clearEvents(key)
        done(('Closed %s'):format(gateLabel(key)))
        -- closing onto a fault that's still there trips straight back out
        for rid, f in pairs(S.runFault) do
            if f.kind == 'permanent' and upstreamGate('r' .. rid) == key then
                b.closed, b.lockout = false, true
                event('trip', 'high', ('%s tripped again'):format(gateLabel(key)), ('Closed onto the fault on run #%d — it is still there'):format(rid), key)
                solve()
                return true
            end
        end
        return true
    elseif a == 'name' and key and key:match('^[FLRIN]%d+$') then
        local n = tostring(d.name or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 48)
        S.names[key] = n ~= '' and n or nil
        return done(('Renamed %s to %s'):format(key, n ~= '' and n or '(default)'))
    elseif a == 'priority' and key and key:match('^F%d+$') then
        local p = math.max(1, math.min(3, math.floor(tonumber(d.priority) or 2)))
        S.prio[key] = p
        return done(('%s priority set to %d'):format(gateLabel(key), p))
    elseif a == 'shed' and key and key:match('^F%d+$') then
        brk(key).shed = 'manual'
        event('shed', 'medium', ('%s shed by control'):format(gateLabel(key)), 'Opened for load shedding', key)
        return done(('Shed %s'):format(gateLabel(key)))
    elseif a == 'restore_all' then
        for k, b in pairs(S.brk) do if b.shed then b.shed = nil clearEvents(k, 'shed') end end
        return done('Restored every shed feeder')
    elseif (a == 'unit_start' or a == 'unit_stop' or a == 'unit_maint') and tonumber(d.id) then
        local f = Cabling.fixtures[tonumber(d.id)]
        if not f or f.model ~= ST.model then return nil, 'No such power station' end
        local i = tonumber(d.unit)
        local u = i and units(f)[i]
        if not u then return nil, 'No such unit' end
        if a == 'unit_start' then
            if u.state == 'online' or u.state == 'starting' then return nil, 'Already running' end
            if u.maint then return nil, 'That unit is out for maintenance' end
            u.state, u.readyAt = 'starting', now() + (ST.start or 90)
            clearEvents('station:' .. f.id, 'unit')
            return done(('Starting %s unit %d (%d s to synchronise)'):format(nameOf('station', f), i, ST.start or 90))
        elseif a == 'unit_stop' then u.state, u.readyAt = 'offline', nil return done(('Stopped %s unit %d'):format(nameOf('station', f), i))
        else u.maint = not u.maint if u.maint then u.state = 'offline' end return done(('%s unit %d %s maintenance'):format(nameOf('station', f), i, u.maint and 'out for' or 'back from')) end
    elseif a == 'sub_maint' and tonumber(d.id) and S.subs[tonumber(d.id)] then
        local st = S.subs[tonumber(d.id)]
        st.maint = not st.maint or nil
        return done(('Substation #%d %s maintenance'):format(tonumber(d.id), st.maint and 'out for' or 'back from'))
    elseif a == 'level' then
        local lv = d.level
        if not RANK[lv] then return nil, 'bad level' end
        S.manualLevel = lv ~= 'normal' and lv or nil
        return done(('System level set to %s'):format(lv:upper()))
    elseif a == 'notice' then
        local n, err = notice(d.audience == 'crews' and 'crews' or d.audience == 'feeder' and 'feeder' or 'all', d.text, key, by)
        if not n then return nil, err end
        return true
    elseif a == 'dispatch' then
        for _, e in ipairs(S.events) do
            if e.id == d.id and e.status == 'active' then
                e.dispatched = now()
                for _, pid in ipairs(GetPlayers()) do
                    local src = tonumber(pid)
                    if isCrew(src) then TriggerClientEvent('opslabs-towers:gridDispatch', src, { id = e.id, title = e.title, x = e.x, y = e.y }) end
                end
                return done(('Crew dispatched: %s'):format(e.title))
            end
        end
        return nil, 'No such event'
    elseif a == 'ack' then
        for _, e in ipairs(S.events) do if e.id == d.id then e.acked = by e.ackAt = now() end end
        saveDirty = true return true
    elseif a == 'clear' then
        for _, e in ipairs(S.events) do if e.id == d.id and not e.crew then e.status = 'cleared' e.cleared = now() end end
        saveDirty = true return true
    elseif a == 'pole_jumper' or a == 'pole_jumpers_all' or a == 'pole_fuses' or a == 'pole_earths_off' or a == 'pole_dispatch' then
        local pid = tonumber(d.id)
        local f = pid and Cabling.fixtures[pid]
        if not f or not isPowerPole(f.model) then return nil, 'Not a power pole' end
        local pname = S.names['N' .. pid] or ('Pole #' .. pid)
        if a == 'pole_jumper' then
            if not PowerLineSetJumper then return nil, 'The Line Tool is off' end
            local ok, err = PowerLineSetJumper(pid, tonumber(d.rid), d.open == true, by)
            if not ok then return nil, err end
            return done(('%s conductor #%s at %s'):format(d.open and 'Snapped off' or 'Snapped on', tostring(d.rid), pname))
        elseif a == 'pole_jumpers_all' then
            if not PowerLineSetJumper then return nil, 'The Line Tool is off' end
            local n = 0
            for rid in pairs(type(f.data) == 'table' and type(f.data.open) == 'table' and f.data.open or {}) do
                if PowerLineSetJumper(pid, tonumber(rid), false, by) then n = n + 1 end
            end
            return done(('Snapped %d jumper(s) back on at %s'):format(n, pname))
        elseif a == 'pole_fuses' then
            if not PoleSetPower then return nil, 'Pole safety tools are off' end
            local ok, err = PoleSetPower(pid, 'fusesOut', d.out == true)
            if not ok then return nil, err end
            return done(('%s the cut-out fuses at %s'):format(d.out and 'Pulled' or 'Refitted', pname))
        elseif a == 'pole_earths_off' then
            local ok, err = PoleSetPower and PoleSetPower(pid, 'earthed', false)
            if not ok then return nil, err or 'Pole safety tools are off' end
            return done(('Working earths off at %s'):format(pname))
        else
            event('crew', d.sev == 'high' and 'high' or 'medium', ('Crew to %s'):format(pname), type(d.text) == 'string' and d.text:sub(1, 200) or 'Inspect the pole and its kit', 'pole:' .. pid, f, true)
            local e = S.events[1]
            e.dispatched = now()
            for _, pl in ipairs(GetPlayers()) do
                local src = tonumber(pl)
                if isCrew(src) then TriggerClientEvent('opslabs-towers:gridDispatch', src, { id = e.id, title = e.title, x = e.x, y = e.y }) end
            end
            return done(('Crew dispatched to %s'):format(pname))
        end
    elseif (a == 'fault_ack' or a == 'fault_close') and tonumber(d.fault) then
        local fn = a == 'fault_ack' and AckFault or CloseFault
        if not fn then return nil, 'Faults are off' end
        local ok, err = fn(tonumber(d.fault), by, a == 'fault_close' and (type(d.note) == 'string' and d.note:sub(1, 300) or 'Closed from Grid control') or nil)
        if not ok then return nil, err end
        return done(('%s fault #%d'):format(a == 'fault_ack' and 'Acknowledged' or 'Closed', tonumber(d.fault)))
    elseif a == 'proc_step' then
        local p = tostring(d.proc or '')
        local i = tonumber(d.step)
        S.procs[p] = S.procs[p] or {}
        if not i then S.procs[p] = {} return done(('Reset procedure %s'):format(p)) end
        local k = tostring(i)
        if S.procs[p][k] then S.procs[p][k] = nil else S.procs[p][k] = { by = by, at = now() } end
        saveDirty = true return true
    end
    return nil, 'Unknown action'
end

---------------------------------------------------------------------------
-- in game: panels at the kit ([E] at a station / substation / recloser)
---------------------------------------------------------------------------

lib.callback.register('opslabs-towers:grid:panel', function(src, fid)
    if not isCrew(src) then return { error = 'Only grid crews can operate this' } end
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f then return { error = 'Not found' } end
    local st = GridState()
    local out = { model = f.model, id = f.id, freq = st.freq, level = st.level }
    local function touching(kind, id)
        local o = {}
        for _, l in ipairs(st.lines) do
            for _, t in ipairs(T.runs[l.id].touches) do if t.kind == kind and t.id == (id or f.id) then o[#o + 1] = l break end end
        end
        return o
    end
    local sid = isSubAnchor(f.model) and f.id or T.partSub[f.id]
    if f.model == ST.model then
        for _, s in ipairs(st.stations) do if s.id == f.id then out.station = s end end
        out.lines = touching('station')
    elseif sid then
        local sf = subOf(sid)
        if f.id == sid and sf and not sf.spec.control and (sf.spec.kind == 'shell' or sf.spec.kind == 'rtu') then
            return { error = 'No control desk here — operate it at the 11 kV switchgear, or fit a control desk (SCADA)' }
        end
        for _, s in ipairs(st.subs) do if s.id == sid then out.sub = s end end
        out.feeders = {}
        for _, fd in ipairs(st.feeders) do if fd.sub == sid then out.feeders[#out.feeders + 1] = fd end end
        out.lines = touching('sub', sid)
        out.subId = sid
    elseif f.model == CG.Recloser then
        for _, r in ipairs(st.reclosers) do if r.id == f.id then out.recloser = r end end
    end
    return out
end)

lib.callback.register('opslabs-towers:grid:act', function(src, d)
    if not isCrew(src) then return { error = 'Only grid crews can operate this' } end
    if type(d) ~= 'table' then return { error = 'bad request' } end
    local f = Cabling.fixtures[tonumber(d.at) or -1]
    if not f then return { error = 'Not found' } end
    local p = GetEntityCoords(GetPlayerPed(src))
    local reach = f.model == ST.model and (ST.reach or 34) + 10 or f.model == SU.model and (SU.reach or 19) + 8 or (isSubAnchor(f.model) or isSubPart(f.model)) and 26 or 10
    if math.sqrt((p.x - f.x) ^ 2 + (p.y - f.y) ^ 2) > reach then return { error = 'You have to be at the equipment' } end
    local ok, err = GridAction(d, GetPlayerName(src) .. ' (on site)')
    if not ok then return { error = err } end
    return { ok = true }
end)

exports('GetGrid', GridState)
exports('GridTransformerLive', GridTransformerLive)
