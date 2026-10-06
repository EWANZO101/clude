-- San Andreas Power & Light · Line Tool (insulated hot stick, client/powerline.lua). Works on the power kit in front of
-- the engineer:
--   inspect    is it live, which conductors land on it (and where they go), and every step still missing — each with
--              its fix: place the missing kit through the tool, run the right conductor, or be shown where it goes first
--   snap off / on   open or close the jumper between a conductor and the kit it lands on. The line stays strung but is
--              disconnected there: server/grid.lua (11 kV / 400 kV) and server/mains.lua (LV) both respect it.
--              Kept in the kit's fixture data: data.open = { ['<run id>'] = true }
--   move end   take a conductor's end off this kit and snap it onto another pole / kit (re-route a line)
--   re-string  change a conductor to another class (11 kV ↔ LV ↔ service, flex ↔ mains …)

local PL = Config.PowerLine or {}
if PL.Enabled == false then return end
local CG, CM, CC = Config.Grid or {}, Config.Mains or {}, Config.Cabling or {}
local ST, WI, SU, PY = CG.Station or {}, CG.Wind or {}, CG.Substation or {}, CG.Pylon or {}
local SITES, SK = CG.SubSites or {}, CG.SubKit or {}

---------------------------------------------------------------------------
-- jumpers (read by grid.lua and mains.lua every time they rebuild)
---------------------------------------------------------------------------

function PowerJumperOpen(fid, rid)
    local f = Cabling.fixtures[fid]
    local o = f and type(f.data) == 'table' and f.data.open
    return type(o) == 'table' and o[tostring(rid)] == true or false
end

local function setJumper(f, rid, open)
    f.data = type(f.data) == 'table' and f.data or {}
    f.data.open = type(f.data.open) == 'table' and f.data.open or {}
    f.data.open[tostring(rid)] = open and true or nil
    if not next(f.data.open) then f.data.open = nil end
    MySQL.update.await('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { next(f.data) and json.encode(f.data) or nil, f.id })
end

---------------------------------------------------------------------------
-- what a piece of kit is, and which conductor belongs on it
---------------------------------------------------------------------------

local SUBPART_MODEL = {}
for model, role in pairs(SK.parts or {}) do SUBPART_MODEL[role] = SUBPART_MODEL[role] or model end
local POLE_KIT = { [CG.Transformer or 'opslabs_power_transformer'] = 'tx', [CG.Recloser or 'opslabs_power_recloser'] = 'recloser',
    opslabs_power_cutouts = 'polekit', opslabs_power_pothead = 'polekit', opslabs_power_lv_connectors = 'polekit' }
local INSIDE = {}
for _, c in ipairs(CC.PowerInside or { 'mains', 'flex', 'flexblack' }) do INSIDE[c] = true end
local OVERHEAD = {}
for _, c in ipairs(CC.PowerOverhead or { 'transmission', 'hv', 'lv', 'service' }) do OVERHEAD[c] = true end
local LABEL = CC.PowerLabels or {}

local function isPole(m) return m and m:find('^opslabs_power_pole') ~= nil end
local function kindOf(m)
    if not m then return nil end
    if isPole(m) then return 'pole' end
    if m == PY.model then return 'pylon' end
    if m == ST.model then return 'station' end
    if m == WI.model then return 'wind' end
    if m == SU.model or SITES[m] then return 'sub' end
    if (SK.parts or {})[m] then return 'subpart' end
    if POLE_KIT[m] then return POLE_KIT[m] end
    local r = MainsRole and MainsRole(m)
    if r == 'supply' or r == 'cu' or r == 'wired' or r == 'gen' or r == 'inv' then return r end
    if m:find('^opslabs_streetlight') then return 'light' end
    return nil
end
local CABLES = {
    pole = { 'hv', 'lv', 'service' }, tx = { 'lv', 'service' }, recloser = { 'hv' }, polekit = { 'lv', 'service' },
    pylon = { 'transmission' }, station = { 'transmission' }, wind = { 'hv' }, sub = { 'hv', 'transmission' },
    supply = { 'service', 'lv', 'mains' }, cu = { 'mains', 'flex' }, wired = { 'mains', 'flex' }, gen = { 'flexblack', 'mains' }, inv = { 'mains' },
}
local KIND_LABEL = { pole = 'Power pole', pylon = '400 kV pylon', station = 'Power station', wind = 'Wind turbine', sub = 'Substation',
    subpart = 'Substation plant', tx = 'Pole transformer', recloser = 'Pole recloser', polekit = 'Pole kit', supply = 'Supply kit',
    cu = 'Consumer unit', wired = 'Wired kit', gen = 'Generator', inv = 'Solar inverter', light = 'Street light' }

local function clsOf(color) return color == 'transmission' and 'T' or color == 'hv' and 'H' or 'L' end
local function h2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
local function subReach(m) return m == SU.model and (SU.reach or 19.0) or (SITES[m] or {}).reach or 16.0 end

--- does a conductor end at p land on this kit? (the same rules grid.lua / mains.lua use)
local function lands(f, p, cls)
    local k = kindOf(f.model)
    if k == 'pole' then return h2(p, f) <= (CM.PoleReach or 1.6) and p.z > f.z - 1 and p.z < f.z + 16 end
    if k == 'pylon' then return cls == 'T' and h2(p, f) <= (PY.reach or 9.5) and p.z > f.z - 2 and p.z < f.z + 40 end
    if k == 'station' then return cls == 'T' and h2(p, f) <= (ST.reach or 34.0) end
    if k == 'sub' then return cls ~= 'L' and h2(p, f) <= subReach(f.model) end
    if k == 'wind' then return cls == 'H' and h2(p, f) <= (WI.reach or 10.0) end
    if cls == 'L' and (k == 'supply' or k == 'cu' or k == 'wired' or k == 'gen' or k == 'inv') then
        return math.min(d3(p, f), d3(p, { x = f.x, y = f.y, z = f.z + 0.15 })) <= (CM.KitReach or 0.9)
    end
    return false
end

local function fname(f)
    if not f then return '?' end
    local k = kindOf(f.model)
    return ('%s #%d'):format(KIND_LABEL[k] or 'Kit', f.id)
end

--- the pole a piece of pole kit is fitted on (within the stricter of the LV / grid reach)
local function poleUnder(f, reach)
    local best, bd
    for _, p in pairs(Cabling.fixtures) do
        if isPole(p.model) then
            local d = h2(p, f)
            if d <= (reach or math.min(CM.TransformerReach or 0.8, CG.TransformerOnPole or 1.2)) and (not bd or d < bd) then best, bd = p, d end
        end
    end
    return best
end

local function nearest(match, from, maxDist, except)
    local best, bd
    for _, f in pairs(Cabling.fixtures) do
        if f.id ~= except and match(f) then
            local d = h2(f, from)
            if d <= (maxDist or 1e9) and (not bd or d < bd) then best, bd = f, d end
        end
    end
    return best, bd
end

--- every power conductor landing on this kit (pole kit: the pole's), with what the far end lands on
local function connections(f)
    local out = {}
    for rid, r in pairs(Cabling.runs) do
        if r.kind == 'power' and type(r.points) == 'table' and #r.points >= 2 then
            local cls = clsOf(r.color)
            local ends = { start = r.points[1], ['end'] = r.points[#r.points] }
            for which, p in pairs(ends) do
                if lands(f, p, cls) then
                    local far = ends[which == 'start' and 'end' or 'start']
                    local other
                    for _, g in pairs(Cabling.fixtures) do
                        if g.id ~= f.id and kindOf(g.model) and lands(g, far, cls) then other = g break end
                    end
                    local live = (cls ~= 'L' and GridNodeLive and GridNodeLive('r' .. rid)) or false
                    out[#out + 1] = { rid = rid, which = which, color = r.color, label = LABEL[r.color] or r.color, cls = cls,
                        open = PowerJumperOpen(f.id, rid) or nil, length = r.length, live = live,
                        flow = cls ~= 'L' and GridRunFlow and GridRunFlow(rid) or nil,
                        other = other and fname(other) or 'nothing (a loose end)', otherId = other and other.id or nil }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.rid < b.rid end)
    return out
end

---------------------------------------------------------------------------
-- checks: every step this kit still needs, with its fixes
---------------------------------------------------------------------------

local function poleRow(id) local list = GridPoles and GridPoles({ id }) return list and list[1] or nil end
local function liveHvPole(from, except)
    local best, bd
    for _, p in ipairs(GridPoles and GridPoles() or {}) do
        if p.hv and p.id ~= except then
            local d = h2(p, from)
            if not bd or d < bd then best, bd = p, d end
        end
    end
    return best
end
local function liveSub(from)
    return nearest(function(g) return kindOf(g.model) == 'sub' and GridNodeLive and GridNodeLive('B' .. g.id .. 'H') end, from)
end
local function where(f, label) return f and { kind = 'where', x = f.x, y = f.y, z = f.z, label = label } or nil end
local function run(color, label) return { kind = 'run', color = color, label = label or ('Run ' .. (LABEL[color] or color):lower() .. ' from here') } end
local function place(model, label, extra)
    local fix = { kind = 'place', model = model, label = label }
    for k, v in pairs(extra or {}) do fix[k] = v end
    return fix
end

local function inspect(f)
    local k = kindOf(f.model)
    local I = { id = f.id, model = f.model, kind = k, kindLabel = KIND_LABEL[k] or 'Kit', name = fname(f), x = f.x, y = f.y, z = f.z,
        checks = {}, cables = {} }
    local function check(ok, text, note, fixes, optional)
        I.checks[#I.checks + 1] = { ok = ok and true or false, text = text, note = note, fixes = fixes or {}, optional = optional or nil }
    end
    for _, c in ipairs(CABLES[k] or {}) do I.cables[#I.cables + 1] = { color = c, label = LABEL[c] or c } end

    -- pole kit lives on a pole: its checks are the pole's, after "is it on a pole"
    local pole = k == 'pole' and f or nil
    if k == 'tx' or k == 'recloser' or k == 'polekit' then
        pole = poleUnder(f)
        local near = not pole and nearest(function(g) return isPole(g.model) end, f, 60.0)
        check(pole ~= nil, 'Fitted on a power pole',
            pole and ('On ' .. fname(pole)) or ('It must be fitted within %.1f m of a power pole (aim at the pole when placing it).'):format(math.min(CM.TransformerReach or 0.8, CG.TransformerOnPole or 1.2)),
            not pole and {
                near and where(near, ('Nearest pole: %s (%.0f m) — move this onto it'):format(fname(near), h2(near, f))) or nil,
                place('opslabs_power_pole_10m', 'Place a power pole here first, then refit this on it'),
            } or nil)
        I.pole = pole and { id = pole.id, name = fname(pole) } or nil
    end

    I.conns = connections(pole or f)
    local closed, hvIn, lvIn, open = 0, 0, 0, 0
    for _, c in ipairs(I.conns) do
        if c.open then open = open + 1 else
            closed = closed + 1
            if c.cls == 'H' then hvIn = hvIn + 1 elseif c.cls == 'L' then lvIn = lvIn + 1 end
        end
    end

    if pole then
        local m = poleRow(pole.id) or {}
        I.monitor = m
        I.live, I.status = m.live, m.hv and ('11 kV live · %.2f MW · %d A'):format(m.mw or 0, math.floor((m.amps or 0) + 0.5)) or m.lv and 'LV live' or 'Dead'
        if k == 'pole' then
            local lp, ls = liveHvPole(pole, pole.id), liveSub(pole)
            check(closed > 0, 'A conductor is landed on the pole', closed > 0 and ('%d connected'):format(closed) or 'Nothing is connected to this pole yet.',
                closed == 0 and { run('hv', 'Run 11 kV conductor from here'), run('lv', 'Run LV cable from here'),
                    where(lp, lp and ('Nearest live 11 kV pole: %s (%.0f m)'):format(lp.name, h2(lp, pole)) or nil),
                    where(ls, ls and ('Nearest live substation: %s (%.0f m)'):format(fname(ls), h2(ls, pole)) or nil) } or nil)
        end
        if hvIn > 0 then
            local lp, ls = liveHvPole(pole, pole.id), liveSub(pole)
            check(m.hv, 'On a live 11 kV feeder', m.hv and ('%s%s'):format(m.feederName or 'Feeder', m.subName and (' from ' .. m.subName) or '')
                or 'The 11 kV conductor here is dead: it must reach a live pole or a substation feeder (see the reasons below).',
                not m.hv and { where(lp, lp and ('Nearest live 11 kV pole: %s (%.0f m)'):format(lp.name, h2(lp, pole)) or nil),
                    where(ls, ls and ('Nearest live substation: %s (%.0f m)'):format(fname(ls), h2(ls, pole)) or nil), { kind = 'restore', label = 'Run the power restoration kit here' } } or nil)
        elseif lvIn > 0 and k == 'pole' then
            local tp = nearest(function(g) return kindOf(g.model) == 'tx' and GridTransformerLive and GridTransformerLive(g.id) end, pole)
            check(m.lv, 'LV supply from a pole transformer', m.lv and 'LV network live' or 'This LV cable must reach a pole with a live transformer.',
                not m.lv and { where(tp, tp and ('Nearest live transformer: %s (%.0f m)'):format(fname(tp), h2(tp, pole)) or nil) } or nil)
        end
        if open > 0 then
            check(false, 'All jumpers connected', ('%d conductor(s) snapped off here — the line is strung but not connected.'):format(open),
                { { kind = 'jumpers', label = 'Snap every jumper back on' } })
        end
        if m.recloser then
            check(m.recloser.closed, 'Recloser closed', m.recloser.closed and m.recloser.name
                or (m.recloser.lockout and 'Locked out after a fault — close it from OPS Hub or [E] under it.' or 'Open — close it from OPS Hub or [E] under it.'))
        end
        if k == 'pole' or k == 'tx' then
            check(m.tx and m.tx > 0, 'Pole transformer fitted', (m.tx or 0) > 0 and ('%d/%d live'):format(m.txLive or 0, m.tx)
                or 'Without one, nothing on the LV side of this pole (houses, street lights) gets power.',
                (m.tx or 0) == 0 and { place(CG.Transformer or 'opslabs_power_transformer', 'Fit a pole transformer on this pole', { pole = pole.id }) } or nil, true)
        end
        if (m.tx or 0) > 0 then
            check(not m.fusesOut, 'Cut-out fuses in', m.fusesOut and 'The fuses were pulled with the operating rod.' or nil,
                m.fusesOut and { { kind = 'fuses', pole = pole.id, label = 'Refit the fuses (restoration kit)' } } or nil)
            check(not m.earthed, 'Working earths off', m.earthed and 'Portable earths are on this pole.' or nil,
                m.earthed and { { kind = 'fuses', pole = pole.id, label = 'Take the earths off and refit the fuses' } } or nil)
            check((m.lvRuns or 0) > 0, 'LV network leaving the pole', (m.lvRuns or 0) > 0 and ('%d LV / service cable(s)'):format(m.lvRuns)
                or 'Run LV cable to the next pole or a service drop to a house.', (m.lvRuns or 0) == 0 and { run('lv'), run('service') } or nil)
        end
        check(true, 'LineSense pole monitor', 'Fitted and reporting to OPS Hub')
    elseif k == 'pylon' or k == 'station' then
        local node = (k == 'pylon' and 'P' or 'S') .. f.id
        local tc = 0
        for _, c in ipairs(I.conns) do if c.cls == 'T' and not c.open then tc = tc + 1 end end
        I.live = GridNodeLive and GridNodeLive(node) or false
        I.status = I.live and '400 kV live' or 'Dead'
        local near = nearest(function(g) local kk = kindOf(g.model) return kk == 'pylon' or kk == 'sub' or kk == 'station' end, f, 2000.0, f.id)
        check(tc >= (k == 'pylon' and 2 or 1), k == 'pylon' and '400 kV conductor strung in and out' or '400 kV line leaving the station',
            ('%d conductor(s) landed'):format(tc), tc < (k == 'pylon' and 2 or 1) and { run('transmission'),
                where(near, near and ('Next: %s (%.0f m)'):format(fname(near), h2(near, f)) or nil) } or nil)
        check(I.live, k == 'pylon' and 'Line energised' or 'Generating',
            I.live and nil or (k == 'station' and 'Start a unit: [E] in the station, or OPS Hub → Generation.' or 'Needs a path to a power station with a unit running.'))
    elseif k == 'sub' then
        local spec = GridSubSpec and GridSubSpec(f.id)
        I.live = GridNodeLive and GridNodeLive('B' .. f.id .. 'H') or false
        I.status = I.live and '11 kV busbar live' or 'Dead'
        if spec then
            for _, miss in ipairs(spec.missing or {}) do
                local role
                for r, l in pairs(SK.labels or {}) do if l == miss then role = r end end
                local model = role and SUBPART_MODEL[role]
                check(false, miss .. ' fitted', ('Substation plant goes within %d m of the building.'):format(SK.radius or 16),
                    model and { place(model, 'Place the ' .. miss:lower() .. ' now') } or nil)
            end
            if #(spec.missing or {}) == 0 then check(true, 'Substation plant complete', ('%d MVA · %d transformer(s)'):format(spec.mva or 0, spec.tx or 0)) end
        end
        local hv400 = GridNodeLive and GridNodeLive('B' .. f.id .. 'T') or false
        local py = nearest(function(g) local kk = kindOf(g.model) return kk == 'pylon' or kk == 'station' end, f, 3000.0)
        check(hv400, '400 kV supply in', hv400 and nil or 'Land a live 400 kV line in the yard.',
            not hv400 and { run('transmission'), where(py, py and ('Nearest pylon / station: %s (%.0f m)'):format(fname(py), h2(py, f)) or nil) } or nil)
        check(hvIn > 0, '11 kV feeders out', hvIn > 0 and ('%d feeder(s)'):format(hvIn) or 'Run 11 kV conductor out of the yard to the first pole.', hvIn == 0 and { run('hv') } or nil)
    elseif k == 'wind' then
        I.live = GridNodeLive and GridNodeLive('W' .. f.id) or false
        I.status = I.live and 'Feeding the 11 kV network' or 'Not connected'
        local lp = liveHvPole(f)
        check(hvIn > 0, '11 kV conductor to the turbine', nil, hvIn == 0 and { run('hv'), where(lp, lp and ('Nearest live 11 kV pole: %s (%.0f m)'):format(lp.name, h2(lp, f)) or nil) } or nil)
        check(I.live, 'Connected to a live network', I.live and nil or 'A turbine only generates into a live 11 kV network.')
    else
        local st = MainsState and MainsState(f.id) or {}
        I.live = (st.on or (st.live and not st.off)) and true or false
        I.status = I.live and 'Live' or 'No supply'
        if k == 'supply' then
            local tp = nearest(function(g) return isPole(g.model) and (MainsPoleLive or {})[g.id] end, f, 200.0)
            check(lvIn > 0 or I.live, 'Supply cable landed', lvIn > 0 and ('%d cable(s)'):format(lvIn) or nil,
                (lvIn == 0 and not I.live) and { run('service', 'Run a service drop from here'), where(tp, tp and ('Nearest pole with live LV: %s (%.0f m)'):format(fname(tp), h2(tp, f)) or nil) } or nil)
        end
    end

    -- and everything the fault finder knows about this kit's supply (grid reasons included)
    local diag = PowerDiagFixture and PowerDiagFixture(f.id)
    if diag then
        I.chain = diag.chain
        for _, x in ipairs(diag.issues or {}) do
            check(false, x.text, x.fix and ('Fix: ' .. x.fix) or nil, x.fixable and { { kind = 'restore', label = 'Fix it with the power restoration kit' } } or nil)
        end
    end
    -- drop empty fix slots (where() returns nil when nothing is near)
    for _, c in ipairs(I.checks) do
        local list = {}
        for i = 1, 8 do if c.fixes[i] then list[#list + 1] = c.fixes[i] end end
        c.fixes = list
    end
    return I
end

---------------------------------------------------------------------------
-- callbacks
---------------------------------------------------------------------------

local function crew(src)
    if CanCable and CanCable(src) then return true end
    local job = FW.Job and FW.Job(src)
    for _, j in ipairs(CG.CrewJobs or {}) do if j == job then return true end end
    return false
end

local function within(src, f, extra)
    local p = GetEntityCoords(GetPlayerPed(src))
    if p.x == 0.0 and p.y == 0.0 then return true end
    local reach = (PL.Range or 7.0) + (extra or 0) + (kindOf(f.model) == 'sub' and 20 or kindOf(f.model) == 'station' and 30 or 0)
    return h2(p, f) <= reach + 4.0
end

local function rebuild()
    if CablingChanged then CablingChanged() end
    if GridResolve then GridResolve() end
    if MainsRecompute then MainsRecompute() end
end

local function who(src) return GetPlayerName(src) .. ' (Line Tool)' end
local function note(src, text) if GridNote then GridNote(who(src), text) end end

lib.callback.register('opslabs-towers:pline:can', function(src) return crew(src) end)

lib.callback.register('opslabs-towers:pline:inspect', function(src, fid)
    if not crew(src) then return { error = 'Only San Andreas Power & Light crews and engineers carry the Line Tool' } end
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f or not kindOf(f.model) then return { error = 'That isn’t power kit' } end
    if MainsRecompute then MainsRecompute() end
    if GridResolve then GridResolve() end
    return inspect(f)
end)

--- what a run end lands on, for a run picked in the air
lib.callback.register('opslabs-towers:pline:runInfo', function(src, rid)
    if not crew(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(rid) or -1]
    if not r or r.kind ~= 'power' then return { error = 'Not a power conductor' } end
    local cls = clsOf(r.color)
    local ends = {}
    for which, p in pairs({ start = r.points[1], ['end'] = r.points[#r.points] }) do
        local on
        for _, g in pairs(Cabling.fixtures) do if kindOf(g.model) and lands(g, p, cls) then on = g break end end
        ends[which] = { x = p.x, y = p.y, z = p.z, on = on and on.id or nil, name = on and fname(on) or nil, open = on and PowerJumperOpen(on.id, r.id) or nil }
    end
    return { id = r.id, color = r.color, label = LABEL[r.color] or r.color, length = r.length, cls = cls,
        live = cls ~= 'L' and GridNodeLive and GridNodeLive('r' .. r.id) or nil, flow = cls ~= 'L' and GridRunFlow and GridRunFlow(r.id) or nil, ends = ends }
end)

lib.callback.register('opslabs-towers:pline:jumper', function(src, fid, rid, open)
    if not crew(src) then return { error = 'not allowed' } end
    local f, r = Cabling.fixtures[tonumber(fid) or -1], Cabling.runs[tonumber(rid) or -1]
    if not f or not r or r.kind ~= 'power' then return { error = 'not found' } end
    if not within(src, f) then return { error = 'Too far away — stand at the pole' } end
    local cls = clsOf(r.color)
    if not (lands(f, r.points[1], cls) or lands(f, r.points[#r.points], cls)) then return { error = 'That conductor doesn’t land here' } end
    setJumper(f, r.id, open == true)
    note(src, ('%s %s %s at %s'):format(open and 'Snapped off' or 'Snapped on', LABEL[r.color] or r.color, ('#' .. r.id), fname(f)))
    rebuild()
    return { ok = true }
end)

--- OPS Hub (GridAction pole_jumper): remote switching of a jumper → ok, err
function PowerLineSetJumper(fid, rid, open, by)
    local f, r = Cabling.fixtures[tonumber(fid) or -1], Cabling.runs[tonumber(rid) or -1]
    if not f or not r or r.kind ~= 'power' then return nil, 'Not found' end
    local cls = clsOf(r.color)
    if not (lands(f, r.points[1], cls) or lands(f, r.points[#r.points], cls)) then return nil, 'That conductor doesn’t land on this pole' end
    setJumper(f, r.id, open == true)
    if GridNote then GridNote(by or 'OPS Hub', ('%s %s #%d at %s (remote)'):format(open and 'Snapped off' or 'Snapped on', LABEL[r.color] or r.color, r.id, fname(f))) end
    rebuild()
    return true
end

lib.callback.register('opslabs-towers:pline:jumpersAll', function(src, fid)
    if not crew(src) then return { error = 'not allowed' } end
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f then return { error = 'not found' } end
    if not within(src, f) then return { error = 'Too far away' } end
    local n = 0
    if type(f.data) == 'table' and type(f.data.open) == 'table' then for _ in pairs(f.data.open) do n = n + 1 end f.data.open = nil end
    MySQL.update.await('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { type(f.data) == 'table' and next(f.data) and json.encode(f.data) or nil, f.id })
    note(src, ('Snapped %d jumper(s) back on at %s'):format(n, fname(f)))
    rebuild()
    return { ok = true, n = n }
end)

--- change a conductor's class (stays in its family: overhead ↔ overhead, inside ↔ inside)
lib.callback.register('opslabs-towers:pline:restring', function(src, rid, color)
    if not crew(src) then return { error = 'not allowed' } end
    local r = Cabling.runs[tonumber(rid) or -1]
    if not r or r.kind ~= 'power' then return { error = 'not found' } end
    if type(color) ~= 'string' or color == r.color then return { error = 'Pick a different conductor' } end
    local fam = OVERHEAD[r.color] and OVERHEAD or INSIDE[r.color] and INSIDE or nil
    if not fam or not fam[color] then return { error = 'Overhead line can only be re-strung as another overhead conductor (and inside wiring as other inside cable)' } end
    local p = GetEntityCoords(GetPlayerPed(src))
    if p.x ~= 0.0 or p.y ~= 0.0 then
        local close = false
        for _, q in ipairs(r.points) do if h2(p, q) <= 40.0 then close = true break end end
        if not close then return { error = 'Too far from that conductor' } end
    end
    local was = r.color
    r.color = color
    MySQL.update.await('UPDATE opslabs_towers_cables SET color = ? WHERE id = ?', { color, r.id })
    note(src, ('Re-strung conductor #%d: %s → %s'):format(r.id, LABEL[was] or was, LABEL[color] or color))
    rebuild()
    return { ok = true }
end)

--- snap one end of a conductor onto another pole / kit (the end point moves to `at`, which the client aims on that kit)
lib.callback.register('opslabs-towers:pline:moveEnd', function(src, rid, which, fid, at)
    if not crew(src) then return { error = 'not allowed' } end
    local r, f = Cabling.runs[tonumber(rid) or -1], Cabling.fixtures[tonumber(fid) or -1]
    if not r or r.kind ~= 'power' or not f then return { error = 'not found' } end
    if which ~= 'start' and which ~= 'end' then return { error = 'bad end' } end
    local x, y, z = tonumber(type(at) == 'table' and at.x), tonumber(type(at) == 'table' and at.y), tonumber(type(at) == 'table' and at.z)
    if not (x and y and z) then return { error = 'bad point' } end
    local p = { x = x, y = y, z = z, nx = 0.0, ny = 0.0, nz = 1.0 }
    local cls = clsOf(r.color)
    if not lands(f, p, cls) then return { error = ('%s can’t land on %s there'):format(LABEL[r.color] or r.color, fname(f)) } end
    local pts = r.points
    local i = which == 'start' and 1 or #pts
    local nb = pts[which == 'start' and 2 or #pts - 1]
    if h2(nb, p) > (PL.MoveReach or 60.0) then return { error = ('Too far: the next fixing is %.0f m from there (max %d m)'):format(h2(nb, p), PL.MoveReach or 60) } end
    -- the jumper it had where it came off goes with it
    for _, g in pairs(Cabling.fixtures) do
        if type(g.data) == 'table' and type(g.data.open) == 'table' and g.data.open[tostring(r.id)] and lands(g, pts[i], cls) then setJumper(g, r.id, false) end
    end
    local old = pts[i]
    pts[i] = p
    local len = 0.0
    for k = 2, #pts do len = len + d3(pts[k - 1], pts[k]) end
    r.points, r.length = pts, len
    MySQL.update.await('UPDATE opslabs_towers_cables SET points = ?, length = ? WHERE id = ?', { json.encode(pts), len, r.id })
    local from
    for _, g in pairs(Cabling.fixtures) do if kindOf(g.model) and lands(g, old, cls) then from = g break end end
    note(src, ('Moved conductor #%d from %s onto %s'):format(r.id, from and fname(from) or 'a loose end', fname(f)))
    rebuild()
    return { ok = true }
end)

--- the pole's cut-out fuses back in / earths off (the restoration kit's fix, from the Line Tool)
lib.callback.register('opslabs-towers:pline:fuses', function(src, pid)
    if not crew(src) then return { error = 'not allowed' } end
    local f = Cabling.fixtures[tonumber(pid) or -1]
    if not f or not isPole(f.model) then return { error = 'not a pole' } end
    if not within(src, f) then return { error = 'Too far away' } end
    if PoleRestore then PoleRestore(f.id) end
    note(src, 'Fuses refitted / earths removed at ' .. fname(f))
    rebuild()
    return { ok = true }
end)
