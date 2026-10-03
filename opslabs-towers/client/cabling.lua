-- CAT6 cabling client: draws every cable / trunking run near the player out of
-- short segment props, and runs the /cable tool (box → pull → route → terminate).

local CC = Config.Cabling
local data = { boxes = {}, runs = {}, fixtures = {} }
local spawned = {}            -- key -> { entities }
local CABLE_R = 0.0045        -- lift so the 8 mm cable lies on the surface
local TRUNK_LIFT = 0.0006
local TRUNK_INSIDE = 0.008    -- cable height inside 25x16 trunking

-- Only what changed is redrawn: every box / run / fixture gets a signature, and a key is
-- despawned (and re-streamed) only when its signature is new. Runs also get a bounding
-- sphere so streaming and aiming can skip far-away cable cheaply.
local sigs = {}
local POLE_MODELS = Config.Cabling.PoleHeights
local function mm(v) return math.floor((v or 0) * 1000 + 0.5) end

local function runSig(r)
    local t = { r.kind, r.color or '', r.start_term and 1 or 0, r.end_term and 1 or 0, r.loose and json.encode(r.loose) or '' }
    for _, p in ipairs(r.points or {}) do t[#t + 1] = ('%d,%d,%d,%s,%s'):format(mm(p.x), mm(p.y), mm(p.z), p.t or '', p.p or '') end
    return table.concat(t, '|')
end

local function runBounds(r)
    local pts, n = r.points or {}, #(r.points or {})
    if n == 0 then r._c, r._r = vector3(0.0, 0.0, -1000.0), 0.0 return end
    local sx, sy, sz = 0.0, 0.0, 0.0
    for _, p in ipairs(pts) do sx, sy, sz = sx + p.x, sy + p.y, sz + p.z end
    local c = vector3(sx / n, sy / n, sz / n)
    local rad = 0.0
    for _, p in ipairs(pts) do rad = math.max(rad, #(c - vector3(p.x, p.y, p.z))) end
    local loose = 0.0
    for _, l in pairs(r.loose or {}) do loose = loose + (l.len or 0) end
    r._c, r._r = c, rad + 1.0 + loose  -- + room for sagging spans and loose ends
end

-- kit fitted to poles (its steel bands depend on the pole it sits on); buildings, cabinets etc. don't care
POLE_KIT, BRANDED_MODEL = {}, {}
for _, e in ipairs(CC.Equipment or {}) do
    local models = { e.model }
    for _, sz in ipairs(e.sizes or {}) do models[#models + 1] = sz.model end
    for _, m in ipairs(models) do
        if e.pole then POLE_KIT[m] = true end
        if e.branded then BRANDED_MODEL[m] = true end
    end
end
StreamWake = false

RegisterNetEvent('opslabs-towers:cabling', function(d)
    local boxes, runs, fixtures, newSigs = {}, {}, {}, {}
    local poleSig = {}
    for _, f in ipairs(d.fixtures or {}) do
        fixtures[f.id] = f
        if POLE_MODELS[f.model] then poleSig[#poleSig + 1] = ('%d:%d,%d'):format(f.id, mm(f.x), mm(f.y)) end
    end
    poleSig = table.concat(poleSig, ';')   -- pole kit's bands depend on which pole it sits on
    for id, f in pairs(fixtures) do
        newSigs['f' .. id] = ('%s|%d|%d|%d|%d|%s|%s'):format(f.model, mm(f.x), mm(f.y), mm(f.z), mm(f.heading), POLE_KIT[f.model] and poleSig or '', f.data and json.encode(f.data) or '')
    end
    for _, b in ipairs(d.boxes or {}) do
        boxes[b.id] = b
        newSigs['b' .. b.id] = ('%s|%d|%d|%d|%d'):format(b.kind or 'cat6', mm(b.x), mm(b.y), mm(b.z), mm(b.heading))
    end
    for _, r in ipairs(d.runs or {}) do
        runs[r.id] = r
        runBounds(r)
        newSigs['r' .. r.id] = runSig(r)
    end
    data.boxes, data.runs, data.fixtures = boxes, runs, fixtures
    local redraw = false
    for key in pairs(spawned) do
        if newSigs[key] ~= sigs[key] then DespawnKey(key) redraw = true end   -- gone or changed: redraw just this one
    end
    sigs = newSigs
    if redraw then StreamWake = true end                                 -- respawn straight away, not on the next tick
end)

---------------------------------------------------------------------------
-- maths: orient a +Y-forward / +Z-up model along f with up u
---------------------------------------------------------------------------

local function norm(v) local l = #v; return l > 1e-6 and v / l or vector3(0.0, 0.0, 1.0) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

local function rotationFor(f, u)
    f = norm(f)
    u = u - f * dot(u, f)
    if #u < 1e-4 then u = math.abs(f.z) < 0.9 and vector3(0.0, 0.0, 1.0) or vector3(0.0, 1.0, 0.0); u = u - f * dot(u, f) end
    u = norm(u)
    local pitch = math.deg(math.asin(math.max(-1.0, math.min(1.0, f.z))))
    local yaw = math.abs(f.z) > 0.999 and 0.0 or math.deg(math.atan(-f.x, f.y))
    local yr, pr = math.rad(yaw), math.rad(pitch)
    local x1 = u.x * math.cos(-yr) - u.y * math.sin(-yr)
    local y1 = u.x * math.sin(-yr) + u.y * math.cos(-yr)
    local c, s = math.cos(-pr), math.sin(-pr)
    local z2 = y1 * s + u.z * c
    local roll = math.deg(math.atan(x1, z2))
    return pitch, roll, yaw
end

local models = {}
local function model(name)
    local h = joaat(name)
    if not models[h] then
        if not IsModelInCdimage(h) then return nil end
        lib.requestModel(h, 5000)
        models[h] = true
    end
    return h
end

local function place(list, name, pos, f, u)
    local h = model(name)
    if not h then return end
    local e = CreateObjectNoOffset(h, pos.x, pos.y, pos.z, false, false, false)
    local p, r, y = rotationFor(f, u)
    SetEntityRotation(e, p, r, y, CC.RotationOrder or 2, true)
    SetEntityCoordsNoOffset(e, pos.x, pos.y, pos.z, false, false, false)
    SetEntityCollision(e, false, false)
    FreezeEntityPosition(e, true)
    list[#list + 1] = e
    return e
end

local CABLE_PIECES = { { 2.0, '200' }, { 1.0, '100' }, { 0.5, '050' }, { 0.25, '025' }, { 0.1, '010' }, { 0.05, '005' } }
local TRUNK_PIECES = { { 2.0, '200' }, { 1.0, '100' }, { 0.5, '050' }, { 0.25, '025' } }

--- fill a straight line with the longest pieces that fit (the last one overlaps the end)
local function fillLine(list, a, b, up, pieces, prefix)
    local d = b - a
    local L = #d
    if L < 0.005 then return end
    local f = d / L
    local t = 0.0
    while L - t > 0.004 do
        local left, piece = L - t, nil
        for _, p in ipairs(pieces) do if p[1] <= left + 0.001 then piece = p; break end end
        if not piece then
            piece = pieces[#pieces]
            t = math.max(0.0, L - piece[1])
        end
        place(list, prefix .. piece[2], a + f * t, f, up)
        t = t + piece[1]
    end
end

CablePlace, CableFillLine = place, fillLine      -- shared with guy wires (client/guys.lua)

local function pt(p, lift) return vector3(p.x + p.nx * lift, p.y + p.ny * lift, p.z + p.nz * lift) end
local function nrm(p) return vector3(p.nx, p.ny, p.nz) end

-- per box type: prop, pull-out hole offset from the centre, height of the cable end
local BOXES = {
    cat6 = { model = 'opslabs_cat6_box', label = 'CAT6', ly = -0.10, top = 0.29 },
    fibre_black = { model = 'opslabs_fibre_box_black', label = 'Fibre (black)', ly = -0.11, top = 0.32 },
    fibre_yellow = { model = 'opslabs_fibre_box_yellow', label = 'Fibre (yellow)', ly = -0.088, top = 0.27 },
    drop = { model = 'opslabs_drop_drum_stand', reel = 'opslabs_drop_drum_reel', label = 'ULW drop cable drum', ly = -0.08, top = 0.62 },
    fibre_ulw = { model = 'opslabs_drop_drum_stand', reel = 'opslabs_drop_drum_reel', label = 'ULW drop cable drum', ly = -0.08, top = 0.62 },
    fibre_spine = { model = 'opslabs_drop_drum_stand', reel = 'opslabs_drop_drum_reel', label = 'Spine feed cable drum', ly = -0.08, top = 0.62 },
}
local REEL_AXLE, REEL_R = 0.40, 0.22

--- the drum's reel turns with every metre pulled off it
local function reelAngle(b, pulled)
    local full = b.kind == 'drop' and (CC.DropDrumLength or 500) or ((CC.FibreBoxLength or {})[(b.kind or ''):match('^fibre_(%a+)$') or ''] or 500)
    return (full - (b.remaining or 0) + (pulled or 0)) / (2 * math.pi * REEL_R) * 360.0
end
local function boxType(b) return BOXES[b.kind or 'cat6'] or BOXES.cat6 end

local function boxExit(b)
    local h = math.rad(b.heading or 0.0)
    local t = boxType(b)
    local lx, ly = 0.0, t.ly   -- the cable comes out of the hole near the front of the lid
    return { x = b.x + lx * math.cos(h) - ly * math.sin(h), y = b.y + lx * math.sin(h) + ly * math.cos(h), z = b.z + t.top, nx = 0.0, ny = 0.0, nz = 1.0 }
end
CableBoxExit = boxExit
CablingFixtures = function() return data.fixtures end
CablingRuns = function() return data.runs end
CablingEntities = function(key) return spawned[key] end

local function towerName(id)
    local t = id and (TowerList() or {})[id]
    return t and t.name or nil
end

-- equipment a cable end can plug into: fibre → cabinets, joints, CBT, CSP, ONT · CAT6 → the ONT's LAN port
local function setOf(list) local o = {} for _, v in ipairs(list or {}) do o[v] = true end return o end
local FIBRE_KIT = setOf(Config.Isp and Config.Isp.Headends)
for k in pairs(setOf(Config.Isp and Config.Isp.PassThrough)) do FIBRE_KIT[k] = true end
local ONT_MODEL = Config.Isp and Config.Isp.Ont or 'opslabs_ont'
FIBRE_KIT[ONT_MODEL] = true
local PL = Config.PhoneLine or {}
local COPPER_KIT = setOf(PL.Exchange)
for _, list in ipairs({ PL.PassThrough, PL.Sockets }) do for k in pairs(setOf(list)) do COPPER_KIT[k] = true end end
local function connectable(kind, model)
    if kind == 'fibre' then return FIBRE_KIT[model] == true end
    if kind == 'copper' then return COPPER_KIT[model] == true end
    return kind == 'cable' and model == ONT_MODEL
end
local function fixtureLabel(id)
    local f = id and data.fixtures[id]
    if not f then return nil end
    for _, e in ipairs(CC.Equipment) do if e.model == f.model then return (e.label:gsub(' %(.*%)', '')) end end
    return f.model
end
local function nearestFixtureFor(kind, pos, maxDist)
    local best, bd = nil, maxDist
    for id, f in pairs(data.fixtures) do
        if connectable(kind, f.model) then
            local d = #(pos - vector3(f.x, f.y, f.z + 0.1))
            if d < bd then best, bd = id, d end
        end
    end
    return best
end
local function endName(r, which)
    local t, f = r[which .. '_tower'], r[which .. '_fixture']
    return towerName(t) or fixtureLabel(f)
end


--- draw one run; returns the entity list
-- aerial spans (to or from a pole, more than 2.5 m across) hang with a sag instead of a
-- ruler-straight line: about 2.5 % of the span at the middle, like real dropwire
local SAG, SAG_STEPS = 0.025, 8
local function isAerial(a, b)
    return (a.p or b.p) and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 2.5
end
function SpanPoints(a, b)
    local pa, pb = vector3(a.x, a.y, a.z), vector3(b.x, b.y, b.z)
    if not isAerial(a, b) then return { pa, pb } end
    local span = #(pb - pa)
    local out = {}
    for k = 0, SAG_STEPS do
        local t = k / SAG_STEPS
        out[#out + 1] = pa + (pb - pa) * t - vector3(0.0, 0.0, 4.0 * SAG * span * t * (1.0 - t))
    end
    return out
end
local UP = vector3(0.0, 0.0, 1.0)

--- draw a hanging span: sub-pieces along the sag curve with small joints hiding the bends
local function hangSpan(list, a, b, pieces, prefix, joint)
    local sp = SpanPoints(a, b)
    for k = 1, #sp - 1 do fillLine(list, sp[k], sp[k + 1], UP, pieces, prefix) end
    for k = 2, #sp - 1 do place(list, joint, sp[k], vector3(0.0, 1.0, 0.0), UP) end
end

-- fibre types: lift so each sits on the surface (radius + a hair)
FIBRE_R = { black = 0.0028, yellow = 0.0018, spine = 0.0065, ulw = 0.0021 }

--- dropwire clamps where a cable is fixed to a pole / wall anchor, and masonry clips along walls
local function fixings(list, pts)
    for i, p in ipairs(pts) do
        if p.p then
            for _, j in ipairs({ i - 1, i + 1 }) do
                local nb = pts[j]
                if nb then
                    local d = vector3(nb.x - p.x, nb.y - p.y, nb.z - p.z)
                    if #d > 0.3 then place(list, 'opslabs_dropwire_clamp', vector3(p.x, p.y, p.z), d, UP) end
                end
            end
        end
    end
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local wallish = math.abs(a.nz or 1) < 0.5 and not a.t and not b.t and not isAerial(a, b) and not a.p and not b.p
        if wallish then
            local pa, pb = vector3(a.x, a.y, a.z), vector3(b.x, b.y, b.z)
            local L = #(pb - pa)
            local n = math.floor(L / 0.35)
            for k = 1, n do
                local q = pa + (pb - pa) * (k * 0.35 / L)
                place(list, 'opslabs_cable_clip', q + nrm(a) * 0.004, pb - pa, nrm(a))
            end
        end
    end
end

POWER_R = { hv = 0.007, lv = 0.012, service = 0.006 }
COPPER_R = { drop = 0.003, internal = 0.0026, multipair = 0.0085 }

local function runLabel(r)
    if r.kind == 'copper' then return (CC.CopperLabels or {})[r.color] or 'Phone cable' end
    return r.kind == 'trunk' and ((CC.TrunkLabels or {})[r.color] or ('Trunking (' .. r.color .. ')'))
        or r.kind == 'fibre' and ((CC.FibreLabels or {})[r.color] or ('Fibre (' .. r.color .. ')'))
        or r.kind == 'power' and ((CC.PowerLabels or {})[r.color] or 'Power cable') or 'CAT6'
end

local function groundUnder(x, y, z)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x, y, z + 0.2, x, y, z - 30.0, 1, 0, 4)
    local _, hit, at = GetShapeTestResult(ray)
    return hit == 1 and at.z or (z - 1.0)
end

--- where a loose end lies: from its last fixing it drops to the ground and the rest lies along it
--- (or to where it was dropped). Returns the path and the free tip.
function LoosePath(r, which)
    local l = r.loose and r.loose[which]
    local pts = r.points or {}
    if not l or #pts == 0 then return nil end
    local anchor = which == 'end' and pts[#pts] or pts[1]
    local prev = which == 'end' and pts[#pts - 1] or pts[2]
    local A = vector3(anchor.x, anchor.y, anchor.z)
    local g = groundUnder(A.x, A.y, A.z)
    local len, path = l.len or 0, { A }
    if l.at then
        local T = vector3(l.at.x, l.at.y, l.at.z + 0.01)
        local drop = vector3(A.x, A.y, g + 0.01)
        if A.z - g > 0.3 then path[#path + 1] = drop end
        path[#path + 1] = T
        return path, T
    end
    local fall = math.min(len, math.max(0.0, A.z - g - 0.01))
    local down = vector3(A.x, A.y, A.z - fall)
    path[#path + 1] = down
    local rest = len - fall
    if rest > 0.05 then
        local dir = prev and vector3(A.x - prev.x, A.y - prev.y, 0.0) or vector3(0.0, 1.0, 0.0)
        dir = #dir > 0.01 and dir / #dir or vector3(0.0, 1.0, 0.0)
        local tip = vector3(down.x + dir.x * rest, down.y + dir.y * rest, 0.0)
        tip = vector3(tip.x, tip.y, groundUnder(tip.x, tip.y, down.z + 1.0) + 0.01)
        path[#path + 1] = tip
    end
    return path, path[#path]
end

local function drawLoose(r, list, prefix, joint, lift)
    r._looseTip = {}
    for _, which in ipairs({ 'start', 'end' }) do
        local path, tip = LoosePath(r, which)
        if path then
            for k = 1, #path - 1 do
                if #(path[k + 1] - path[k]) > 0.02 then fillLine(list, path[k] + UP * (k > 1 and lift or 0.0), path[k + 1] + UP * lift, UP, CABLE_PIECES, prefix) end
            end
            for k = 2, #path - 1 do place(list, joint, path[k] + UP * lift, vector3(0.0, 1.0, 0.0), UP) end
            r._looseTip[which] = tip
        end
    end
end

function BuildRun(r, list)
    list = list or {}
    local pts = r.points or {}
    if r.loose and r.kind ~= 'trunk' then
        local col
        if r.kind == 'power' then col = POWER_R[r.color] and r.color or 'lv'
            drawLoose(r, list, ('opslabs_power_%s_'):format(col), ('opslabs_power_%s_joint'):format(col), POWER_R[col])
        elseif r.kind == 'copper' then col = COPPER_R[r.color] and r.color or 'drop'
            drawLoose(r, list, ('opslabs_copper_%s_'):format(col), ('opslabs_copper_%s_joint'):format(col), COPPER_R[col])
        elseif r.kind == 'fibre' then col = FIBRE_R[r.color] and r.color or 'black'
            drawLoose(r, list, ('opslabs_fibre_%s_'):format(col), ('opslabs_fibre_%s_joint'):format(col), FIBRE_R[col])
        else drawLoose(r, list, 'opslabs_cat6_seg_', 'opslabs_cat6_joint', CABLE_R) end
    end
    if r.kind == 'power' or r.kind == 'copper' then
        local R, fam = r.kind == 'copper' and COPPER_R or POWER_R, r.kind
        local col = R[r.color] and r.color or (fam == 'copper' and 'drop' or 'lv')
        local lift, prefix, joint = R[col], ('opslabs_%s_%s_'):format(fam, col), ('opslabs_%s_%s_joint'):format(fam, col)
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            if isAerial(a, b) then hangSpan(list, a, b, CABLE_PIECES, prefix, joint)
            else fillLine(list, pt(a, lift), pt(b, lift), nrm(a), CABLE_PIECES, prefix) end
        end
        for i = 2, #pts - 1 do place(list, joint, pt(pts[i], lift), vector3(0.0, 1.0, 0.0), nrm(pts[i])) end
        return list
    end
    if r.kind == 'trunk' then
        local prefix = ('opslabs_trunk_%s_'):format(r.color or 'white')
        for i = 1, #pts - 1 do fillLine(list, pt(pts[i], TRUNK_LIFT), pt(pts[i + 1], TRUNK_LIFT), nrm(pts[i]), TRUNK_PIECES, prefix) end
        for i = 1, #pts do
            local f = i < #pts and (pt(pts[i + 1], 0) - pt(pts[i], 0)) or (pt(pts[i], 0) - pt(pts[i - 1], 0))
            place(list, prefix .. 'corner', pt(pts[i], TRUNK_LIFT), f, nrm(pts[i]))
        end
        return list
    end
    if r.kind == 'fibre' then
        local col = FIBRE_R[r.color] and r.color or 'black'
        local lift = FIBRE_R[col]
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            if isAerial(a, b) then
                hangSpan(list, a, b, CABLE_PIECES, ('opslabs_fibre_%s_'):format(col), ('opslabs_fibre_%s_joint'):format(col))
            elseif not (a.t and b.t and a.t == b.t) then
                fillLine(list, pt(a, a.t and TRUNK_INSIDE or lift), pt(b, b.t and TRUNK_INSIDE or lift), nrm(a), CABLE_PIECES, ('opslabs_fibre_%s_'):format(col))
            end
        end
        for i = 2, #pts - 1 do
            if not pts[i].t then place(list, ('opslabs_fibre_%s_joint'):format(col), pt(pts[i], lift), vector3(0.0, 1.0, 0.0), nrm(pts[i])) end
        end
        fixings(list, pts)
        return list
    end
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        -- both ends tucked inside the same trunking: hidden
        if isAerial(a, b) then
            hangSpan(list, a, b, CABLE_PIECES, 'opslabs_cat6_seg_', 'opslabs_cat6_joint')
        elseif not (a.t and b.t and a.t == b.t) then
            local la = a.t and TRUNK_INSIDE or CABLE_R
            local lb = b.t and TRUNK_INSIDE or CABLE_R
            fillLine(list, pt(a, la), pt(b, lb), nrm(a), CABLE_PIECES, 'opslabs_cat6_seg_')
        end
    end
    for i = 2, #pts - 1 do
        if not pts[i].t then place(list, 'opslabs_cat6_joint', pt(pts[i], CABLE_R), vector3(0.0, 1.0, 0.0), nrm(pts[i])) end
    end
    fixings(list, pts)
    -- RJ45 plugs on terminated ends: tip into the device, cable leaving behind it
    if r.end_term and #pts >= 2 then
        local e, p = pts[#pts], pts[#pts - 1]
        place(list, 'opslabs_rj45_plug', pt(e, 0.004), pt(p, 0.004) - pt(e, 0.004), nrm(e))
    end
    if r.start_term and #pts >= 2 then
        local s, n = pts[1], pts[2]
        place(list, 'opslabs_rj45_plug', pt(s, 0.004), pt(n, 0.004) - pt(s, 0.004), nrm(s))
    end
    return list
end

-- pole-mounted kit gets stainless banding straps round the pole at its bracket arms
local BAND_HEIGHTS = { opslabs_cbt = { 0.11, 0.25 }, opslabs_cbt_4 = { 0.11, 0.25 }, opslabs_cbt_8 = { 0.11, 0.25 }, opslabs_copper_dp = { 0.06, 0.20 },
    opslabs_splice_enclosure = { 0.112, 0.392 }, opslabs_joint_tophat = { 0.092, 0.352 }, opslabs_slack_loop = { 0.05, 0.5 }, opslabs_pole_splice_box = { 0.05, 0.25 } }
PoleRadiusAt = function(H, z)
    local rb, rt = 0.115 + H * 0.002, 0.075
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, z / H))
end
local function poleUnder(f)
    for _, p in ipairs(AllPoles()) do
        if #(vector2(p.x, p.y) - vector2(f.x, f.y)) < 0.35 and f.z > p.z and f.z < p.z + p.H then return p end
    end
end
function poleBands(f, list)
    local heights = BAND_HEIGHTS[f.model]
    local pole = heights and poleUnder(f)
    if not pole then return end
    for _, hz in ipairs(heights) do
        local z = f.z + hz
        local r = PoleRadius(pole, z - pole.z)
        local mm = 75
        while mm < 145 and mm / 1000 < r + 0.001 do mm = mm + 5 end
        local hb = model(('opslabs_pole_band_%03d'):format(mm))
        if hb then
            local e = CreateObjectNoOffset(hb, pole.x, pole.y, z, false, false, false)
            SetEntityHeading(e, f.heading or 0.0)
            SetEntityCoordsNoOffset(e, pole.x, pole.y, z, false, false, false)
            FreezeEntityPosition(e, true)
            SetEntityCollision(e, false, false)
            list[#list + 1] = e
        end
    end
end

function DespawnKey(key)
    if RoadworksDespawn then RoadworksDespawn(key) end
    if BrandSignDespawn then BrandSignDespawn(key) end
    for _, e in ipairs(spawned[key] or {}) do if DoesEntityExist(e) then DeleteEntity(e) end end
    spawned[key] = nil
end

local function nearRun(r, pos, dist)
    if r._c then return #(pos - r._c) - r._r < dist end
    for _, p in ipairs(r.points or {}) do
        if #(pos - vector3(p.x, p.y, p.z)) < dist then return true end
    end
    return false
end

-- Render range (Config.Render, live-editable from the Ops-Phone dev app): network and power kit
-- streams in up to Distance metres in FRONT of the camera, and only Behind metres all round.
-- Already-spawned things get a Margin before they go, so nothing flickers at the edge.
RenderSettings = Config.Render or { Distance = 400.0, Behind = 80.0, ViewAngle = 130.0, Margin = 25.0 }
RegisterNetEvent('opslabs-towers:render', function(r) if type(r) == 'table' then RenderSettings = r StreamWake = true end end)

local function camForward()
    local rot = GetGameplayCamRot(2)
    local z = math.rad(rot.z)
    return -math.sin(z), math.cos(z)
end

--- is a point (with radius) inside the render range from pos? keep = it's already spawned (margin)
function RenderInView(pos, target, radius, keep, fx, fy)
    local R = RenderSettings
    local m = keep and (R.Margin or 25.0) or 0.0
    local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz) - (radius or 0.0)
    if d <= (R.Behind or 80.0) + m then return true end
    if d > (R.Distance or 400.0) + m then return false end
    if not fx then fx, fy = camForward() end
    local h = math.sqrt(dx * dx + dy * dy)
    if h < 0.001 then return true end
    -- wide cone in front; things with a big radius (long runs) count if any part could be in it
    local cosHalf = math.cos(math.rad((R.ViewAngle or 130.0) / 2 + (keep and 10.0 or 0.0)))
    local slack = math.min(1.0, (radius or 0.0) / h)
    return (dx * fx + dy * fy) / h >= cosHalf - slack
end

-- stream runs and boxes in / out around the player
CreateThread(function()
    local lastYaw = 0.0
    while true do
        for _ = 1, 30 do                       -- every 1.5 s, as soon as something changed, or when the camera swings round
            if StreamWake then break end
            local yaw = GetGameplayCamRot(2).z
            if math.abs((yaw - lastYaw + 180.0) % 360.0 - 180.0) > 35.0 then break end
            Wait(50)
        end
        lastYaw = GetGameplayCamRot(2).z
        StreamWake = false
        local pos = GetEntityCoords(PlayerPedId())
        local fx, fy = camForward()
        local want, order = {}, {}
        local function consider(key, v, at, radius)
            if RenderInView(pos, at, radius, spawned[key] ~= nil, fx, fy) then
                want[key] = v
                order[#order + 1] = { key = key, d = #(pos - at) - (radius or 0.0) }
            end
        end
        for id, b in pairs(data.boxes) do consider('b' .. id, b, vector3(b.x, b.y, b.z), 0.0) end
        for id, f in pairs(data.fixtures) do consider('f' .. id, f, vector3(f.x, f.y, f.z), 0.0) end
        for id, r in pairs(data.runs) do
            if not r._c then runBounds(r) end
            consider('r' .. id, r, r._c, r._r)
        end
        for key in pairs(spawned) do if not want[key] then DespawnKey(key) end end
        table.sort(order, function(a, b) return a.d < b.d end)   -- nearest first: what you're looking at fills in first
        for _, o in ipairs(order) do
            local key, v = o.key, want[o.key]
            if not spawned[key] then
                local list = {}
                if key:sub(1, 1) == 'f' and ((RoadworksSpawn and RoadworksSpawn(key, v, list)) or (BrandSignSpawn and BrandSignSpawn(key, v, list))) then
                    -- road safety kit spawns itself (live sign faces, traffic light lamps)
                elseif key:sub(1, 1) == 'f' then
                    local h = model(v.model)
                    if h then
                        local e = CreateObjectNoOffset(h, v.x, v.y, v.z, false, false, false)
                        SetEntityHeading(e, v.heading or 0.0)
                        SetEntityCoordsNoOffset(e, v.x, v.y, v.z, false, false, false)
                        FreezeEntityPosition(e, true)
                        list[1] = e
                        poleBands(v, list)
                    end
                elseif key:sub(1, 1) == 'b' then
                    local bt = boxType(v)
                    local h = model(bt.model)
                    if h then
                        local e = CreateObjectNoOffset(h, v.x, v.y, v.z, false, false, false)
                        SetEntityHeading(e, v.heading or 0.0)
                        FreezeEntityPosition(e, true)
                        list[1] = e
                        local hr = bt.reel and model(bt.reel)
                        if hr then
                            local r = CreateObjectNoOffset(hr, v.x, v.y, v.z + REEL_AXLE, false, false, false)
                            SetEntityRotation(r, reelAngle(v, 0) % 360, 0.0, v.heading or 0.0, 2, false)
                            SetEntityCoordsNoOffset(r, v.x, v.y, v.z + REEL_AXLE, false, false, false)
                            FreezeEntityPosition(r, true)
                            SetEntityCollision(r, false, false)
                            list[2] = r
                        end
                    end
                else
                    -- a run still on its box starts at the box's pull-out hole (saved as its first point)
                    BuildRun(v, list)
                end
                spawned[key] = list
                Wait(0)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then for key in pairs(spawned) do DespawnKey(key) end end
end)

---------------------------------------------------------------------------
-- aiming at surfaces
---------------------------------------------------------------------------

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

local function aim(ignore, dist)
    local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local to = camPos + rotToDir(camRot) * (dist or 12.0)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1 + 16, ignore or PlayerPedId(), 4)
    local _, hit, at, normal, ent = GetShapeTestResult(ray)
    if hit ~= 1 then return nil end
    return at, normal, ent
end

--- closest approach between segment p0-p1 and the ray q0 + s·u (0 ≤ s ≤ maxS)
--- returns distance, point on the segment, s along the ray
local function segRay(p0, p1, q0, u, maxS)
    local d = p1 - p0
    local r = p0 - q0
    local a, b, c, f = dot(d, d), dot(d, u), dot(d, r), dot(u, r)
    local denom = a - b * b
    local t = (a > 1e-9 and denom > 1e-9) and math.max(0.0, math.min(1.0, (b * f - c) / denom)) or 0.0
    local sr = math.max(0.0, math.min(maxS, b * t + f))
    t = a > 1e-9 and math.max(0.0, math.min(1.0, (b * sr - c) / a)) or 0.0
    local cp = p0 + d * t
    return #(cp - (q0 + u * sr)), cp, sr
end

--- the run under the crosshair: works for cable on walls and for spans hanging in the air.
--- Cables behind the surface you're looking at don't count.
local function pickRun(onlyId, tol)
    local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local u = rotToDir(camRot)
    local maxS = 25.0
    local at = aim(nil, maxS)
    local wall = at and #(at - camPos) + 0.3 or maxS
    local bestRun, bestSeg, bestPt, bestD, bestS
    for id, r in pairs(data.runs) do
        if (not onlyId or id == onlyId) and (not r._c or #(camPos - r._c) - r._r < maxS) then
            local pts = r.points or {}
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                if not (r.kind ~= 'trunk' and a.t and a.t == b.t) then      -- hidden inside trunking
                    local sp = SpanPoints(a, b)
                    for k = 1, #sp - 1 do
                        local d, cp, sr = segRay(sp[k], sp[k + 1], camPos, u, maxS)
                        local allow = (tol or 0.12) + sr * 0.008                -- a little more slack far away
                        if d < allow and sr <= wall and (not bestD or d / allow < bestD) then
                            bestRun, bestSeg, bestPt, bestD, bestS = r, i, cp, d / allow, sr
                        end
                    end
                end
            end
        end
    end
    return bestRun, bestSeg, bestPt, bestS
end

--- telegraph poles near the crosshair (for clamping cable to them)
local function pickPole()
    local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local u = rotToDir(camRot)
    local best, bd, bz
    for _, p in ipairs(AllPoles()) do
        local d, cp = segRay(vector3(p.x, p.y, p.z), vector3(p.x, p.y, p.z + p.H), camPos, u, 40.0)
        if d < 0.45 and (not bd or d < bd) then best, bd, bz = p, d, cp.z end
    end
    return best, bz
end

--- which tower prop (router / AP) an entity is
local function towerOfEntity(ent)
    if not ent or ent == 0 then return nil end
    for id, e in pairs(TowerPropEntities or {}) do if e == ent then return id end end
    return nil
end

local function nearestTowerProp(pos, maxDist)
    local best, bd = nil, maxDist
    for id, e in pairs(TowerPropEntities or {}) do
        if DoesEntityExist(e) then
            local d = #(pos - GetEntityCoords(e))
            if d < bd then best, bd = id, d end
        end
    end
    return best
end

--- snap a point onto nearby trunking so the cable runs (hidden) inside it
local function snapToTrunking(p)
    local best, bd = nil, 0.07
    for id, r in pairs(data.runs) do
        if r.kind == 'trunk' then
            local pts = r.points
            for i = 1, #pts - 1 do
                local a, b = vector3(pts[i].x, pts[i].y, pts[i].z), vector3(pts[i + 1].x, pts[i + 1].y, pts[i + 1].z)
                local ab = b - a
                local t = math.max(0.0, math.min(1.0, dot(p - a, ab) / math.max(1e-6, dot(ab, ab))))
                local c = a + ab * t
                local d = #(p - c)
                if d < bd then best, bd = { pos = c, n = nrm(pts[i]), run = id }, d end
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- laying mode (cable or trunking)
---------------------------------------------------------------------------


--- returns points, endTowerId  (nil when cancelled)
local function layRun(kind, color, box, opts)
    local pts, preview = {}, {}
    local boxed = kind == 'cable' or kind == 'fibre'          -- pulled from a box / drum, ends plug into kit
    local plugs = boxed or kind == 'copper'                   -- ends finish on kit
    local maxLen = (opts and opts.start) and (opts.maxLen or 0) or kind == 'cable' and math.min(CC.MaxRunLength, box.remaining) or kind == 'fibre' and math.min(CC.MaxFibreLength or 1000, box.remaining)
        or kind == 'power' and (CC.MaxPowerLength or 600) or kind == 'copper' and (CC.MaxCopperLength or 800) or 200.0
    local carry = opts and opts.start
    if carry then
        pts[1] = opts.start                                     -- carrying a loose end from its last fixing
        maxLen = opts.maxLen
    elseif boxed then pts[1] = boxExit(box) end
    local length = 0.0
    local function seglen(a, b) return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z)) end
    local function rebuildLast()
        local n = #pts
        if n < 2 then return end
        local list = {}
        BuildRun({ kind = kind, color = color, points = { pts[n - 1], pts[n] } }, list)
        preview[n] = list
    end
    local result, endTower, endFixture
    local ghost, ghostAt, ghostT = {}, nil, 0
    local slack, slackAt, slackT = {}, nil, 0
    local fcol = FIBRE_R[color] and color or 'black'
    local slackPrefix = kind == 'fibre' and ('opslabs_fibre_%s_'):format(fcol) or 'opslabs_cat6_seg_'
    local slackJoint = kind == 'fibre' and ('opslabs_fibre_%s_joint'):format(fcol) or 'opslabs_cat6_joint'
    local function clearSlack()
        for _, e in ipairs(slack) do if DoesEntityExist(e) then DeleteEntity(e) end end
        slack = {}
    end
    local function groundAt(p)
        local ray = StartExpensiveSynchronousShapeTestLosProbe(p.x, p.y, p.z + 0.3, p.x, p.y, p.z - 6.0, 1 + 16, PlayerPedId(), 4)
        local _, hit, at = GetShapeTestResult(ray)
        return hit == 1 and at.z or nil
    end
    local function clearGhost()
        for _, e in ipairs(ghost) do if DoesEntityExist(e) then DeleteEntity(e) end end
        ghost = {}
    end
    local dropped = false
    local startedAt = GetGameTimer()
    if boxed then TriggerEvent('opslabs:carry', 'cable', true) end      -- opslabs-animations: cable in hand
    local sf = carry and PlaceHud.buttons({ { 'Fix point', 24 }, { 'Fix the end here', 191 }, { 'Drop it', { 47, 177 } }, { 'Straight line', 21 } })
        or PlaceHud.buttons(not boxed
        and { { 'Fix point', 24 }, { 'Finish', 191 }, { 'Undo', { 25, 177 } }, { 'Straight line', 21 }, { 'Cancel', 200 } }
        or { { 'Fix point', 24 }, { 'Finish & connect', 191 }, { 'Put it down & walk away', 47 }, { 'Undo', { 25, 177 } }, { 'Straight line', 21 }, { 'Cancel', 200 } })
    local title = kind == 'cable' and 'Pulling CAT6' or kind == 'fibre' and ('Pulling ' .. ((CC.FibreLabels or {})[color] or ('fibre · ' .. color)):lower())
        or kind == 'power' and ('Running ' .. ((CC.PowerLabels or {})[color] or 'power cable'):lower())
        or kind == 'copper' and ('Running ' .. ((CC.CopperLabels or {})[color] or 'phone cable'):lower()) or ('Fitting ' .. ((CC.TrunkLabels or {})[color] or ('trunking · ' .. color)):lower())
    local accent = kind == 'power' and { 255, 214, 10 } or kind == 'copper' and { 191, 90, 242 } or kind == 'fibre' and (color == 'yellow' and { 255, 214, 10 } or { 120, 120, 125 }) or kind == 'trunk' and { 48, 209, 88 } or { 10, 132, 255 }
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 44, 47, 140, 141, 142, 177, 191, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        -- someone removed all cable in a box round this: it goes from your hands too
        local cleared = AreaCleared
        if cleared and cleared.at > startedAt and AREA_KIND_OK(cleared.what, kind) then
            local function inside(p) return p.x >= cleared.r.minx and p.x <= cleared.r.maxx and p.y >= cleared.r.miny and p.y <= cleared.r.maxy end
            local hit = inside(GetEntityCoords(PlayerPedId()))
            for _, p in ipairs(pts) do if inside(p) then hit = true break end end
            if hit then
                result, dropped = nil, false
                lib.notify({ type = 'inform', description = 'The cable you were holding was removed (area cleared)' })
                break
            end
        end
        local at, normal, ent = aim(nil, 40.0)
        local target, tgtTower, tgtFixture
        local straight, poleHint
        -- a pole near the crosshair: clamp to it on the side the cable comes from (the ring head near the top)
        local pole, pz = pickPole()
        if pole and (not at or #(vector3(pole.x, pole.y, at.z) - at) < 0.6 or (at and #(at - GetGameplayCamCoord()) > #(vector3(pole.x, pole.y, pz) - GetGameplayCamCoord()))) then
            local H = pole.H
            local ringHead = pz > pole.z + H - 1.3
            local z = ringHead and (pole.z + H - 0.2) or math.max(pole.z + 0.3, math.min(pole.z + H - 0.2, pz))
            if pole.anchor then z, ringHead = pole.z, false end
            local from = #pts > 0 and vector3(pts[#pts].x, pts[#pts].y, 0.0) or vector3(GetGameplayCamCoord().x, GetGameplayCamCoord().y, 0.0)
            local dir = from - vector3(pole.x, pole.y, 0.0)
            dir = #dir > 0.01 and dir / #dir or vector3(0.0, -1.0, 0.0)
            local rr = PoleRadius(pole, z - pole.z) + 0.012
            at, normal, ent = vector3(pole.x + dir.x * rr, pole.y + dir.y * rr, z), dir, nil
            poleHint = pole.anchor and 'clamped to the wall anchor' or ringHead and 'clamped to the pole’s ring head' or ('on the pole at %.1f m'):format(z - pole.z)
        end
        if at and not poleHint and #(at - GetGameplayCamCoord()) > 14.0 then at = nil end   -- far points only for poles
        if at then
            target = { x = at.x, y = at.y, z = at.z, nx = normal.x, ny = normal.y, nz = normal.z, p = poleHint and pole.id or nil }
            tgtTower = kind ~= 'copper' and towerOfEntity(ent) or nil
            if not tgtTower and plugs then
                if ent and ent ~= 0 then
                    for id, f in pairs(data.fixtures) do
                        local sp = spawned['f' .. id]
                        if sp and sp[1] == ent and connectable(kind, f.model) then tgtFixture = id break end
                    end
                end
                -- pole kit has no collision: aiming within ~40 cm of it counts too
                tgtFixture = tgtFixture or nearestFixtureFor(kind, at, 0.45)
            end
            if plugs and not poleHint then
                local snap = snapToTrunking(at)
                if snap then target = { x = snap.pos.x, y = snap.pos.y, z = snap.pos.z, nx = snap.n.x, ny = snap.n.y, nz = snap.n.z, t = snap.run } end
            end
            -- neat runs: hold Shift for a dead-straight line (level or plumb), small height
            -- differences snap level on their own
            if #pts > 0 and not target.t and not target.p and not tgtTower and not tgtFixture then
                local l = pts[#pts]
                local dz = target.z - l.z
                local flat = math.sqrt((target.x - l.x) ^ 2 + (target.y - l.y) ^ 2)
                if IsControlPressed(0, 21) then
                    if math.abs(dz) > flat then
                        target.x, target.y = l.x, l.y
                        target.nx, target.ny, target.nz = l.nx, l.ny, l.nz
                        straight = 'plumb'
                    else
                        target.z = l.z
                        straight = 'level'
                    end
                elseif math.abs(dz) < 0.04 and flat > 0.1 then
                    target.z = l.z
                    straight = 'level'
                end
            end
            local tp = vector3(target.x, target.y, target.z)
            local dev = tgtTower or tgtFixture
            DrawMarker(28, tp.x, tp.y, tp.z, 0, 0, 0, 0, 0, 0, 0.02, 0.02, 0.02, dev and 50 or 255, 255, dev and 120 or 255, 220, false, false, 2, false, nil, nil, false)
            -- live see-through preview of the piece you're about to fix
            if #pts > 0 then
                local l = pts[#pts]
                local now = GetGameTimer()
                if (not ghostAt or #(ghostAt - tp) > 0.02) and now - ghostT > 90 then
                    clearGhost()
                    BuildRun({ kind = kind, color = color, points = { l, target } }, ghost)
                    for _, e in ipairs(ghost) do SetEntityAlpha(e, 150, false) SetEntityCollision(e, false, false) end
                    ghostAt, ghostT = tp, now
                end
                if #ghost == 0 then DrawLine(l.x, l.y, l.z, tp.x, tp.y, tp.z, 255, 255, 255, 200) end
            end
        elseif #ghost > 0 then
            clearGhost() ghostAt = nil
        end
        -- the loose cable you're pulling: it drops from the last fixed point to the ground,
        -- trails along the floor to your feet and up to your hand
        if boxed and #pts > 0 then
            local ped = PlayerPedId()
            local hand = GetPedBoneCoords(ped, 57005, 0.0, 0.0, 0.0)
            local now = GetGameTimer()
            if (not slackAt or #(slackAt - hand) > 0.15) and now - slackT > 150 then
                clearSlack()
                local l = pts[#pts]
                local P = vector3(l.x, l.y, l.z)
                local feet = GetEntityCoords(ped)
                local gP = groundAt(P) or (feet.z - 0.98)
                local gF = groundAt(feet) or (feet.z - 0.98)
                local path = { P }
                if P.z - gP > 0.3 then path[#path + 1] = vector3(P.x, P.y, gP + CABLE_R) end
                path[#path + 1] = vector3(feet.x, feet.y, gF + CABLE_R)
                path[#path + 1] = hand
                for k = 1, #path - 1 do
                    if #(path[k + 1] - path[k]) > 0.05 then fillLine(slack, path[k], path[k + 1], UP, CABLE_PIECES, slackPrefix) end
                end
                for k = 2, #path - 1 do place(slack, slackJoint, path[k], vector3(0.0, 1.0, 0.0), UP) end
                for _, e in ipairs(slack) do SetEntityCollision(e, false, false) end
                slackAt, slackT = hand, now
            end
            if #slack == 0 then DrawLine(hand.x, hand.y, hand.z, pts[#pts].x, pts[#pts].y, pts[#pts].z, 20, 20, 22, 255) end
            -- the drum turns as cable comes off it
            local reel = box and boxType(box).reel and spawned['b' .. box.id] and spawned['b' .. box.id][2]
            if reel and DoesEntityExist(reel) then
                local extraNow = target and seglen(pts[#pts], target) or 0.0
                SetEntityRotation(reel, reelAngle(box, length + extraNow + #(vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z) - hand)) % 360, 0.0, box.heading or 0.0, 2, false)
            end
        end
        local extra = (target and #pts > 0) and seglen(pts[#pts], target) or 0.0
        local over = boxed and length + extra > maxLen
        local hint = (tgtTower or tgtFixture) and plugs and ('Enter to connect to ' .. (towerName(tgtTower) or fixtureLabel(tgtFixture) or 'this device'))
            or (plugs and target and target.t and 'Inside trunking')
            or poleHint
            or (straight == 'plumb' and 'straight up / down') or (straight == 'level' and 'level')
            or (#pts == 0 and 'Aim at the floor, a wall or the ceiling')
        PlaceHud.draw(sf, title, not boxed and ('%.1f m%s'):format(length + extra, hint and ('   ·   ' .. hint) or '')
            or ('%.1f / %.0f m%s'):format(length + extra, maxLen, over and '   ·   not enough cable' or hint and ('   ·   ' .. hint) or ''), accent, over)
        if target and IsDisabledControlJustPressed(0, 24) then
            if #pts > 0 and length + extra > maxLen then
                lib.notify({ type = 'error', description = boxed and ('Not enough cable — %.0f m max for this run'):format(maxLen) or 'Too long' })
            elseif #pts == 0 or extra > 0.03 then
                pts[#pts + 1] = target
                if #pts > 1 then length = length + extra end
                clearGhost() ghostAt = nil
                rebuildLast()
                PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
            end
        end
        if carry and (IsDisabledControlJustPressed(0, 47) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200)) then
            result, dropped = pts, true
            break
        end
        -- pulling from a box: put the cable down where you stand (it stays on the box) and walk away hands-free
        if boxed and not carry and IsDisabledControlJustPressed(0, 47) then
            if #pts >= 2 then result, dropped = pts, true break end
            lib.notify({ type = 'inform', description = 'Fix the cable to at least one point first — or Esc to leave it all on the box' })
        end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 25) then
            local minPts = boxed and 1 or 0
            if #pts > minPts then
                if #pts > 1 then length = length - seglen(pts[#pts - 1], pts[#pts]) end
                for _, e in ipairs(preview[#pts] or {}) do if DoesEntityExist(e) then DeleteEntity(e) end end
                preview[#pts] = nil
                pts[#pts] = nil
            end
        end
        if IsDisabledControlJustPressed(0, 191) then
            if target and (tgtTower or tgtFixture) and plugs and (#pts == 0 or seglen(pts[#pts], target) > 0.03) and length + extra <= maxLen then
                pts[#pts + 1] = target
                length = length + extra
            end
            local needed = carry and 2 or boxed and 3 or 2
            if #pts >= needed then
                result = pts
                endTower = boxed and (tgtTower or nearestTowerProp(vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z), 0.6)) or nil
                endFixture = plugs and not endTower and (tgtFixture or nearestFixtureFor(kind, vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z), 0.6)) or nil
                break
            end
            lib.notify({ type = 'inform', description = boxed and 'Fix the cable to at least two points first' or 'Place at least two points' })
        end
        if IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    if boxed then TriggerEvent('opslabs:carry', 'cable', false) end
    clearGhost()
    clearSlack()
    for _, list in pairs(preview) do for _, e in ipairs(list) do if DoesEntityExist(e) then DeleteEntity(e) end end end
    return result, endTower, endFixture, dropped
end

--- pick up a loose end: carry it from its last fixing, fix it along walls / poles, or drop it
function CarryLooseEnd(r, which)
    r = data.runs[r.id] or r
    local l = r.loose and r.loose[which]
    if not l then return end
    local anchor = which == 'end' and r.points[#r.points] or r.points[1]
    PlaySoundFrontend(-1, 'PICK_UP', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    local box = which == 'end' and r.box_id and data.boxes[r.box_id]
    local pts, endTower, endFixture, dropped = layRun(r.kind, r.color, nil, { start = anchor, maxLen = (l.len or 0) + (box and box.remaining or 0) })
    if not pts then return end
    local add = {}
    for i = 2, #pts do add[#add + 1] = pts[i] end
    local at
    if dropped then
        local feet = GetEntityCoords(PlayerPedId())
        at = { x = feet.x, y = feet.y, z = groundUnder(feet.x, feet.y, feet.z) }
    end
    local res = lib.callback.await('opslabs-towers:cable:loose', false, r.id, which, add, dropped and 'drop' or 'fix', at)
    if not res or res.error then return lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) end
    if dropped then lib.notify({ type = 'inform', description = 'Dropped — the end lies here until you pick it up again' })
    else
        lib.notify({ type = 'success', description = 'End fixed in place' })
        if (endTower or endFixture) and (r.kind == 'cable' or r.kind == 'fibre' or r.kind == 'copper') then
            Wait(250)
            local cur = data.runs[r.id]
            local into = towerName(endTower) or fixtureLabel(endFixture) or 'the device'
            local q = r.kind == 'fibre' and ('Splice it into ' .. into .. '?') or r.kind == 'copper' and ('Punch it down on the ' .. into .. '?') or ('Terminate it into ' .. into .. '?')
            if cur and lib.alertDialog({ header = q, centered = true, cancel = true }) == 'confirm' then
                TerminateEnd(cur, which, endTower, endFixture)
            end
        end
    end
end

--- cable ends lying loose nearby (put down or cut): set a waypoint and walk back to pick one up
function LooseEndsMenu()
    local pos, list = GetEntityCoords(PlayerPedId()), {}
    for _, r in pairs(data.runs) do
        for which, tip in pairs(r._looseTip or {}) do
            local d = #(pos - tip)
            if d < 300.0 then list[#list + 1] = { r = r, which = which, tip = tip, d = d } end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local options = {}
    for i = 1, math.min(#list, 25) do
        local e = list[i]
        options[#options + 1] = { title = ('%s #%d · %s end'):format(runLabel(e.r), e.r.id, e.which), description = ('%d m away%s · waypoint, then walk up and press E'):format(math.floor(e.d),
            e.r.box_id and e.which == 'end' and ' · still on its box' or ''), icon = 'location-dot', onSelect = function()
            SetNewWaypoint(e.tip.x, e.tip.y)
            lib.notify({ description = 'Waypoint set — walk to the cable end and press E to pick it up' })
        end }
    end
    if #options == 0 then options[1] = { title = 'No loose cable ends nearby', readOnly = true } end
    lib.registerContext({ id = 'cable_loose', title = 'Cable you put down', options = options })
    lib.showContext('cable_loose')
end

-- walk up to a loose end: [E] picks it up
NearLooseEnd = false
CreateThread(function()
    local shown = false
    while true do
        local found
        if not CableCutActive then
            local pos = GetEntityCoords(PlayerPedId())
            for id, r in pairs(data.runs) do
                if r._looseTip and spawned['r' .. id] then
                    for which, tip in pairs(r._looseTip) do
                        if #(pos - tip) < 1.8 then found = { r = r, which = which } break end
                    end
                end
                if found then break end
            end
        end
        NearLooseEnd = found and true or false
        if found then
            if not shown then lib.showTextUI('[E] Pick up the loose end', { icon = 'hand' }) shown = true end
            Wait(0)
            if IsControlJustPressed(0, 38) then
                lib.hideTextUI() shown = false
                CarryLooseEnd(found.r, found.which)
                Wait(500)
            end
        else
            if shown then lib.hideTextUI() shown = false end
            Wait(400)
        end
    end
end)

---------------------------------------------------------------------------
-- termination: strip, untwist, arrange (T568B/A), trim, insert, crimp
---------------------------------------------------------------------------

local ORDERS = {
    T568B = { 'White / Orange', 'Orange', 'White / Green', 'Blue', 'White / Blue', 'Green', 'White / Brown', 'Brown' },
    T568A = { 'White / Green', 'Green', 'White / Orange', 'Blue', 'White / Blue', 'Orange', 'White / Brown', 'Brown' },
}
local WIRE_COLOR = { ['White / Orange'] = '#f7c08a', Orange = '#ff8a00', ['White / Green'] = '#a8e6a1', Green = '#20b04b',
    ['White / Blue'] = '#9ec5ff', Blue = '#1f6fff', ['White / Brown'] = '#d8b89a', Brown = '#7b4a24' }

local function work(label, ms)
    return lib.progressBar({
        duration = ms, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@', clip = 'machinic_loop_mechandplayer', flag = 1 },
    })
end

--- pick the wires in pin order 1..8; returns true when correct, false when cancelled
local function arrangeWires()
    local order = ORDERS[CC.Standard] or ORDERS.T568B
    local chart = {}
    for k, w in ipairs(order) do chart[k] = ('%d. %s'):format(k, w) end
    while true do
        local picked, remaining = {}, {}
        for _, w in ipairs(order) do remaining[#remaining + 1] = w end
        for i = #remaining, 2, -1 do local j = math.random(i); remaining[i], remaining[j] = remaining[j], remaining[i] end
        local wrong = false
        while #picked < 8 do
            local p = promise.new()
            local options = {
                { title = ('Pin %d of 8 — %s'):format(#picked + 1, CC.Standard),
                  description = #picked > 0 and ('So far: ' .. table.concat(picked, ', ')) or 'Plug clip-down, contacts facing you, pin 1 on the left',
                  readOnly = true, icon = 'plug' },
            }
            for i, w in ipairs(remaining) do
                options[#options + 1] = { title = w, icon = 'circle', iconColor = WIRE_COLOR[w], onSelect = function() p:resolve(i) end }
            end
            options[#options + 1] = { title = ('Look at the %s chart'):format(CC.Standard), icon = 'circle-info', onSelect = function() p:resolve(0) end }
            lib.registerContext({ id = 'cable_wires', root = true, title = 'Arrange the wires', options = options, onExit = function() p:resolve(-1) end })
            lib.showContext('cable_wires')
            local choice = Citizen.Await(p)
            if choice == -1 then return false end
            if choice == 0 then
                lib.alertDialog({ header = CC.Standard .. ' pin order', content = table.concat(chart, '  \n'), centered = true })
            else
                local w = table.remove(remaining, choice)
                picked[#picked + 1] = w
                if w ~= order[#picked] then wrong = true break end
            end
        end
        if not wrong then return true end
        lib.notify({ type = 'error', description = ('Wrong order at pin %d — that would be a crossed pair. Pull the wires back out and try again.'):format(#picked) })
    end
end

--- full termination; returns true when crimped
local function spliceFibre(run, which, towerId, fixtureId)
    if not work('Stripping the outer sheath', 2500) then return false end
    if not work('Stripping the buffer coating', 2000) then return false end
    if not work('Cleaning the fibre with alcohol', 1500) then return false end
    if not lib.skillCheck({ 'medium' }, { 'e' }) then
        lib.notify({ type = 'error', description = 'Bad cleave — the end face is chipped. Strip and cleave again.' })
        return false
    end
    if not work('Fusion splicing', 3500) then return false end
    if not lib.skillCheck({ 'easy', 'medium' }, { 'e' }) then
        lib.notify({ type = 'error', description = 'Splice loss too high (0.6 dB) — break it and splice again' })
        return false
    end
    if not work('Shrinking the protection sleeve', 2000) then return false end
    local r = lib.callback.await('opslabs-towers:cable:terminate', false, run.id, which, towerId, fixtureId)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) return false end
    PlaySoundFrontend(-1, 'PICK_UP', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    lib.notify({ type = 'success', description = 'Spliced — 0.02 dB loss. Light on the line.' })
    return true
end

-- copper phone line: strip the sheath, put the pair on the IDC terminals (2 = B-leg, 5 = A-leg), punch down
local COPPER_WIRES = { 'White / Blue', 'Blue / White', 'Orange / White', 'White / Orange' }
local COPPER_WIRE_COLOR = { ['White / Blue'] = '#cfe0ff', ['Blue / White'] = '#1f6fff', ['Orange / White'] = '#ff8a00', ['White / Orange'] = '#ffd9b0' }
local COPPER_ORDER = { { 2, 'White / Blue', 'B-leg' }, { 5, 'Blue / White', 'A-leg' } }
CopperPunchReady = false                                   -- tools.lua: the IDC punch-down tool is in hand

local function punchCopper(run, which, towerId, fixtureId)
    if not work('Stripping the sheath back 50 mm', 2000) then return false end
    for _, step in ipairs(COPPER_ORDER) do
        local choice = 0
        while choice == 0 do
            local p = promise.new()
            local options = { { title = ('Terminal %d (%s)'):format(step[1], step[3]), description = 'Which wire goes on this IDC terminal?', readOnly = true, icon = 'plug' } }
            for i, w in ipairs(COPPER_WIRES) do options[#options + 1] = { title = w, icon = 'circle', iconColor = COPPER_WIRE_COLOR[w], onSelect = function() p:resolve(i) end } end
            options[#options + 1] = { title = 'Look at the wiring chart', icon = 'circle-info', onSelect = function() p:resolve(0) end }
            lib.registerContext({ id = 'copper_wires', root = true, title = 'Pair on the IDC block', options = options, onExit = function() p:resolve(-1) end })
            lib.showContext('copper_wires')
            choice = Citizen.Await(p)
            if choice == -1 then return false end
            if choice == 0 then
                lib.alertDialog({ header = 'Phone line wiring (pair 1)', content = 'Terminal 2 — White / Blue (B-leg)  \nTerminal 3 — Orange / White (bell wire, old sockets only)  \nTerminal 5 — Blue / White (A-leg)  \nPair 2 (orange) is the spare.', centered = true })
            end
        end
        if COPPER_WIRES[choice] ~= step[2] then
            lib.notify({ type = 'error', description = ('%s on terminal %d — that reverses the pair. Pull it out and start again.'):format(COPPER_WIRES[choice], step[1]) })
            return false
        end
        if not work(('Punching down terminal %d'):format(step[1]), 900) then return false end
    end
    if not lib.skillCheck(CopperPunchReady and { 'easy' } or { 'easy', 'medium' }, { 'e' }) then
        lib.notify({ type = 'error', description = 'The wire didn’t seat in the IDC slot — trim it and punch again' })
        return false
    end
    CopperPunchReady = false
    local r = lib.callback.await('opslabs-towers:cable:terminate', false, run.id, which, towerId, fixtureId)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) return false end
    PlaySoundFrontend(-1, 'PICK_UP', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    lib.notify({ type = 'success', description = fixtureId and 'Punched down — test the line with the butt set' or 'Ends made off' })
    return true
end

function TerminateEnd(run, which, towerId, fixtureId)
    if run.kind == 'fibre' then return spliceFibre(run, which, towerId, fixtureId) end
    if run.kind == 'copper' then return punchCopper(run, which, nil, fixtureId) end
    if not work('Stripping the outer jacket', 2500) then return false end
    if not work('Untwisting the four pairs', 2500) then return false end
    if not arrangeWires() then return false end
    if not work('Trimming the wires flush', 1500) then return false end
    if not lib.skillCheck({ 'easy' }, { 'e' }) then
        lib.notify({ type = 'error', description = 'The wires slipped out of the plug — trim and try again' })
        return false
    end
    if not work('Pushing the wires into the RJ45', 1200) then return false end
    if not lib.skillCheck({ 'easy', 'medium' }, { 'e' }) then
        lib.notify({ type = 'error', description = 'Bad crimp — cut the plug off and start again' })
        return false
    end
    local r = lib.callback.await('opslabs-towers:cable:terminate', false, run.id, which, towerId, fixtureId)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) return false end
    PlaySoundFrontend(-1, 'PICK_UP', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    lib.notify({ type = 'success', description = (towerId or fixtureId) and 'Terminated and plugged in — link light on' or 'Terminated' })
    return true
end

---------------------------------------------------------------------------
-- /cable menu (stays open until Esc / back / close)
---------------------------------------------------------------------------

local CableMenu, RunMenu, RunsMenu, BoxesMenu, nearbyBoxCount, EditRoute, moveBox
-- actions started from /towers return to the section they came from instead of /cable
local ReturnMenu
local function menuBack()
    local f = ReturnMenu
    ReturnMenu = nil
    if f then f() else MainMenu() end
end

local function nearestBox(maxDist, fibre)
    local pos, best, bd = GetEntityCoords(PlayerPedId()), nil, maxDist
    for _, b in pairs(data.boxes) do
        if fibre == nil or ((b.kind or 'cat6') ~= 'cat6') == fibre then
            local d = #(pos - vector3(b.x, b.y, b.z))
            if d < bd then best, bd = b, d end
        end
    end
    return best, bd
end

local function runEnds(r)
    local a, z = r.points[r.box_id and 2 or 1], r.points[#r.points]
    return a, z
end

RunMenu = function(r)
    r = data.runs[r.id] or r
    local pos = GetEntityCoords(PlayerPedId())
    local a, z = runEnds(r)
    local nearStart = a and #(pos - vector3(a.x, a.y, a.z)) < 2.5
    local nearEnd = z and #(pos - vector3(z.x, z.y, z.z)) < 2.5
    local done = r.kind == 'fibre' and 'spliced' or r.kind == 'copper' and 'punched down' or 'terminated'
    local options = {
        { title = ('%s · %.1f m'):format(r.kind == 'trunk' and ('Trunking (' .. r.color .. ')') or r.kind == 'fibre' and ('Fibre (' .. r.color .. ')')
            or r.kind == 'copper' and ((CC.CopperLabels or {})[r.color] or 'Phone cable') or r.kind == 'power' and ((CC.PowerLabels or {})[r.color] or 'Power cable') or 'CAT6 cable', r.length or 0),
          description = r.kind ~= 'trunk' and ('Start: %s · End: %s%s'):format(
            r.box_id and 'still on the box' or (r.start_term and (done .. (endName(r, 'start') and (' → ' .. endName(r, 'start')) or '')) or 'bare end'),
            r.end_term and (done .. (endName(r, 'end') and (' → ' .. endName(r, 'end')) or '')) or 'bare end',
            '') or nil, icon = r.kind == 'trunk' and 'grip-lines' or 'ethernet', readOnly = true },
    }
    local verb = r.kind == 'fibre' and 'Splice' or r.kind == 'copper' and 'Punch down' or 'Terminate'
    if r.kind == 'cable' or r.kind == 'fibre' or r.kind == 'copper' then
        if r.box_id then
            options[#options + 1] = { title = 'Cut from the box', description = 'Frees the start of the cable so you can terminate it', icon = 'scissors', onSelect = function()
                local res = lib.callback.await('opslabs-towers:cable:cut', false, r.id)
                if res and res.ok then lib.notify({ type = 'success', description = 'Cable cut from the box' }) Wait(250) end
                RunMenu(r)
            end }
        elseif not r.start_term then
            local tw = a and r.kind ~= 'copper' and nearestTowerProp(vector3(a.x, a.y, a.z), 1.2)
            local fx = a and not tw and nearestFixtureFor(r.kind, vector3(a.x, a.y, a.z), 1.5)
            local into = towerName(tw) or fixtureLabel(fx)
            options[#options + 1] = { title = verb .. ' the start', description = not nearStart and 'Walk to the start of the cable first' or into and ('Connects to ' .. into) or 'Nothing to plug into here — it will just be finished off',
                icon = 'plug', disabled = not nearStart, onSelect = function()
                TerminateEnd(r, 'start', tw, fx)
                Wait(250) RunMenu(r)
            end }
        end
        if not r.end_term then
            local tw = r.end_tower or (z and r.kind ~= 'copper' and nearestTowerProp(vector3(z.x, z.y, z.z), 1.2))
            local fx = not tw and (r.end_fixture or (z and nearestFixtureFor(r.kind, vector3(z.x, z.y, z.z), 1.5)))
            local into = towerName(tw) or fixtureLabel(fx)
            options[#options + 1] = { title = verb .. ' the end', description = not nearEnd and 'Walk to the end of the cable first' or into and ('Connects to ' .. into) or 'Nothing to plug into here — it will just be finished off',
                icon = 'plug', disabled = not nearEnd, onSelect = function()
                TerminateEnd(r, 'end', tw, fx)
                Wait(250) RunMenu(r)
            end }
        end
    end
    options[#options + 1] = { title = 'Move / reshape the route', description = 'Drag points, add bends, take bends out', icon = 'bezier-curve', iconColor = '#0a84ff', onSelect = function()
        EditRoute(r)
        Wait(250)
        RunMenu(r)
    end }
    options[#options + 1] = { title = 'Cut it somewhere along its length', description = 'Aim at the spot · makes two pieces with bare ends', icon = 'scissors', onSelect = function()
        CutMode(r.id)
        RunsMenu()
    end }
    options[#options + 1] = { title = 'Delete', icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
        if lib.alertDialog({ header = 'Remove this ' .. (r.kind == 'trunk' and 'trunking' or 'cable') .. '?', content = r.kind == 'cable' and 'The cable is not returned to the box.' or nil, centered = true, cancel = true }) == 'confirm' then
            lib.callback.await('opslabs-towers:cable:deleteRun', false, r.id)
            Wait(250)
            return RunsMenu()
        end
        RunMenu(r)
    end }
    lib.registerContext({ id = 'cable_run', title = r.kind == 'trunk' and 'Trunking' or r.kind == 'fibre' and 'Fibre' or r.kind == 'copper' and 'Phone cable' or 'Cable', menu = 'cable_runs', onBack = function() RunsMenu() end, options = options })
    lib.showContext('cable_run')
end

--- closest point on any run (or just run onlyId) to pos: run, segment index, point, distance
local function nearestOnRuns(pos, maxDist, onlyId)
    local bestRun, bestSeg, bestPt, bd = nil, nil, nil, maxDist
    for id, r in pairs(data.runs) do
        if not onlyId or id == onlyId then
            local pts = r.points or {}
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                local hidden = r.kind ~= 'trunk' and a.t and a.t == b.t   -- tucked inside trunking
                if not hidden then
                    local pa, pb = vector3(a.x, a.y, a.z), vector3(b.x, b.y, b.z)
                    local d = pb - pa
                    local L2 = dot(d, d)
                    local t = L2 > 0 and math.max(0.0, math.min(1.0, dot(pos - pa, d) / L2)) or 0.0
                    local q = pa + d * t
                    local dist = #(pos - q)
                    if dist < bd then bestRun, bestSeg, bestPt, bd = r, i, q, dist end
                end
            end
        end
    end
    return bestRun, bestSeg, bestPt, bd
end

--- aim along a cable / fibre / trunking and cut it anywhere: it becomes two runs with bare ends
local function CutMode(onlyId)
    local sf = PlaceHud.buttons({ { 'Cut here', 24 }, { 'Done', { 25, 177, 200 } } })
    local cuts = 0
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 44, 140, 141, 142, 177, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local r, seg, q = pickRun(onlyId)
        local what = r and runLabel(r)
        if r then
            local sp = SpanPoints(r.points[seg], r.points[seg + 1])
            for k = 1, #sp - 1 do DrawLine(sp[k].x, sp[k].y, sp[k].z, sp[k + 1].x, sp[k + 1].y, sp[k + 1].z, 255, 69, 58, 255) end
            DrawMarker(28, q.x, q.y, q.z, 0, 0, 0, 0, 0, 0, 0.03, 0.03, 0.03, 255, 69, 58, 230, false, false, 2, false, nil, nil, false)
        end
        PlaceHud.draw(sf, 'Cut a cable', r and ('%s #%d · %.1f m · aim and click to cut'):format(what, r.id, r.length or 0) or 'Aim at a cable, fibre or trunking', { 255, 69, 58 })
        if r and IsDisabledControlJustPressed(0, 24) then
            local head = GetPedBoneCoords(PlayerPedId(), 31086, 0.0, 0.0, 0.0)
            if #(head - q) > 2.2 then
                lib.notify({ type = 'error', description = q.z - head.z > 1.2 and 'Out of reach — use a ladder or climb the pole' or 'Get closer to cut it' })
            elseif work(r.kind == 'trunk' and 'Sawing through the trunking' or r.kind == 'fibre' and 'Cutting the fibre' or 'Cutting with the snips', r.kind == 'trunk' and 2500 or 1200) then
                local res = lib.callback.await('opslabs-towers:cable:split', false, r.id, seg, { x = q.x, y = q.y, z = q.z })
                if not res or res.error then
                    lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
                else
                    cuts = cuts + 1
                    PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
                    lib.notify({ type = 'success', description = r.kind == 'trunk' and 'Trunking cut in two' or ('Cut — #%d and #%d now have bare ends to %s'):format(res.a.id, res.b.id, r.kind == 'fibre' and 'splice' or r.kind == 'copper' and 'punch down' or 'terminate') })
                    onlyId = nil
                    Wait(300)
                end
            end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    return cuts
end

-- outline everything drawn for a run / box key (red = remove, blue = move)
local outlined = nil
local function outline(key, r, g, b)
    if outlined == key then return end
    for _, e in ipairs(outlined and spawned[outlined] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
    outlined = key
    if key then
        SetEntityDrawOutlineColor(r, g, b, 255)
        SetEntityDrawOutlineShader(1)
        for _, e in ipairs(spawned[key] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, true) end end
    end
end


--- what the player is aiming at: a box (by its prop or within 35 cm) or the nearest run
local function aimTarget()
    local at, _, ent = aim()
    local bestBox
    if at then
        local bd = 0.35
        for id, b in pairs(data.boxes) do
            local sp = spawned['b' .. id]
            if sp and sp[1] == ent then bestBox = b break end
            local d = #(at - vector3(b.x, b.y, b.z + 0.15))
            if d < bd then bestBox, bd = b, d end
        end
    end
    -- a box you're looking straight at wins; otherwise the cable under the crosshair
    if bestBox then return { box = bestBox, key = 'b' .. bestBox.id } end
    local r, seg, q = pickRun()
    if r then return { run = r, seg = seg, at = q, key = 'r' .. r.id } end
    return nil
end

local function bar(t)
    local n = math.floor(t * 10 + 0.5)
    return string.rep('■', n) .. string.rep('□', 10 - n)
end

--- cutting from a pole or ladder: every cable within reach of your hands is highlighted.
--- ← → choose the cable, ↑ ↓ slide the cut point along it (Shift = fine), Enter cuts, Backspace stops.
local REACH = 2.2
function CableCutAtHand()
    local ped = PlayerPedId()
    local function hands() return GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0) end
    -- sample every visible run every 5 cm, keeping the original segment index for the server
    local function samples(r)
        local out = {}
        local pts = r.points or {}
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            if not (r.kind ~= 'trunk' and a.t and a.t == b.t) then
                local sp = SpanPoints(a, b)
                for k = 1, #sp - 1 do
                    local p0, p1 = sp[k], sp[k + 1]
                    local n = math.max(1, math.ceil(#(p1 - p0) / 0.05))
                    for j = 0, n - 1 do out[#out + 1] = { pos = p0 + (p1 - p0) * (j / n), seg = i } end
                end
            end
        end
        return out
    end
    local function candidates()
        local h = hands()
        local list = {}
        for _, r in pairs(data.runs) do
            if not r._c or #(h - r._c) - r._r < REACH then
                local ss = samples(r)
                local best, bd
                for idx, smp in ipairs(ss) do
                    local d = #(h - smp.pos)
                    if d < REACH and (not bd or d < bd) then best, bd = idx, d end
                end
                if best then list[#list + 1] = { run = r, samples = ss, cursor = best, dist = bd } end
            end
        end
        table.sort(list, function(x, y) return x.dist < y.dist end)
        return list
    end

    local list = candidates()
    if #list == 0 then lib.notify({ type = 'inform', description = 'No cable within reach' }) return end
    CableCutActive = true
    local sel = 1
    local outlinedKey
    local function outlineSel()
        local key = 'r' .. list[sel].run.id
        if outlinedKey == key then return end
        for _, e in ipairs(outlinedKey and spawned[outlinedKey] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
        SetEntityDrawOutlineColor(255, 69, 58, 255) SetEntityDrawOutlineShader(1)
        for _, e in ipairs(spawned[key] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, true) end end
        outlinedKey = key
    end
    local sf = PlaceHud.buttons({ { 'Cut here', 191 }, { 'Choose cable', { 174, 175 } }, { 'Slide along it', { 172, 173 } }, { 'Fine', 21 }, { 'Stop', { 177, 200 } } })
    local holdT = 0
    while true do
        Wait(0)
        for _, ctl in ipairs({ 172, 173, 174, 175, 177, 191, 199, 200 }) do DisableControlAction(0, ctl, true) end
        local c = list[sel]
        if not c or not data.runs[c.run.id] then break end
        local h = hands()
        -- every reachable cable: dim orange; the chosen one: bright red with the cut marker
        for i, other in ipairs(list) do
            if i ~= sel then
                local smp = other.samples
                for k = 1, #smp - 1, 2 do
                    if #(h - smp[k].pos) < REACH then
                        local p0, p1 = smp[k].pos, smp[math.min(#smp, k + 2)].pos
                        DrawLine(p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, 255, 159, 10, 160)
                    end
                end
            end
        end
        local smp = c.samples
        for k = 1, #smp - 1 do
            local p0, p1 = smp[k].pos, smp[k + 1].pos
            local inReach = #(h - p0) < REACH
            DrawLine(p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, 255, 69, 58, inReach and 255 or 70)
        end
        outlineSel()
        -- move the cut point (held keys repeat)
        local fine = IsControlPressed(0, 21)
        local step = fine and 1 or 4                                 -- samples are 5 cm apart
        local now = GetGameTimer()
        local dir = (IsDisabledControlPressed(0, 172) and 1) or (IsDisabledControlPressed(0, 173) and -1) or 0
        if dir ~= 0 and (IsDisabledControlJustPressed(0, 172) or IsDisabledControlJustPressed(0, 173) or now - holdT > 90) then
            holdT = now
            local nxt = math.max(1, math.min(#smp, c.cursor + dir * step))
            if #(h - smp[nxt].pos) < REACH then c.cursor = nxt end
        end
        if IsDisabledControlJustPressed(0, 175) then sel = sel % #list + 1 end
        if IsDisabledControlJustPressed(0, 174) then sel = (sel - 2) % #list + 1 end
        local cur = smp[c.cursor]
        DrawMarker(28, cur.pos.x, cur.pos.y, cur.pos.z, 0, 0, 0, 0, 0, 0, 0.035, 0.035, 0.035, 255, 255, 255, 255, false, false, 2, false, nil, nil, false)
        DrawMarker(28, cur.pos.x, cur.pos.y, cur.pos.z, 0, 0, 0, 0, 0, 0, 0.07, 0.07, 0.07, 255, 69, 58, 90, false, false, 2, false, nil, nil, false)
        local r = c.run
        local what = runLabel(r)
        PlaceHud.draw(sf, ('Cut a cable · %d of %d within reach'):format(sel, #list), ('%s #%d · %.1f m long · cut point %.2f m from your hands'):format(what, r.id, r.length or 0, #(h - cur.pos)), { 255, 69, 58 })
        if IsDisabledControlJustPressed(0, 191) then
            if lib.progressBar({ duration = r.kind == 'trunk' and 2500 or 1200, label = r.kind == 'trunk' and 'Sawing through the trunking' or r.kind == 'fibre' and 'Cutting the fibre' or 'Cutting with the snips', canCancel = true, disable = { combat = true } }) then
                local res = lib.callback.await('opslabs-towers:cable:split', false, r.id, cur.seg, { x = cur.pos.x, y = cur.pos.y, z = cur.pos.z })
                if res and res.ok then
                    PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
                    lib.notify({ type = 'success', description = r.kind == 'trunk' and 'Trunking cut in two' or 'Cut — both pieces now have bare ends' })
                    Wait(300)
                    for _, e in ipairs(outlinedKey and spawned[outlinedKey] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
                    outlinedKey = nil
                    list = candidates()
                    if #list == 0 then break end
                    sel = math.min(sel, #list)
                else
                    lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
                end
            end
        end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    for _, e in ipairs(outlinedKey and spawned[outlinedKey] or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
    PlaceHud.release(sf)
    CableCutActive = false
end

--- aim at a cable, fibre, trunking or box: hold to remove it. Z puts back the last removal
local function RemoveMode()
    local sf = PlaceHud.buttons({ { 'Hold to remove', 24 }, { 'Undo', 20 }, { 'Done', { 25, 177, 200 } } })
    local hold, holdKey = 0.0, nil
    local last = GetGameTimer()
    while true do
        Wait(0)
        local now = GetGameTimer()
        local dt = (now - last) / 1000
        last = now
        for _, ctl in ipairs({ 20, 24, 25, 37, 44, 140, 141, 142, 177, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local t = aimTarget()
        outline(t and t.key, 255, 69, 58)
        if t and t.run and not spawned[t.key] then
            for i = 1, #t.run.points - 1 do
                local sp = SpanPoints(t.run.points[i], t.run.points[i + 1])
                for k = 1, #sp - 1 do DrawLine(sp[k].x, sp[k].y, sp[k].z, sp[k + 1].x, sp[k + 1].y, sp[k + 1].z, 255, 69, 58, 255) end
            end
        end
        if t and IsDisabledControlPressed(0, 24) then
            if holdKey ~= t.key then hold, holdKey = 0.0, t.key end
            hold = hold + dt
        else
            hold, holdKey = 0.0, nil
        end
        local what = t and (t.box and (boxType(t.box).label .. ' box · ' .. math.floor(t.box.remaining or 0) .. ' m left') or ('%s #%d · %.1f m'):format(runLabel(t.run), t.run.id, t.run.length or 0))
        PlaceHud.draw(sf, 'Remove cable, trunking or a box', not t and 'Aim at a cable, fibre, trunking or a box'
            or (hold > 0 and (what .. '   ' .. bar(math.min(1, hold / 0.6))) or what), { 255, 69, 58 })
        if t and hold >= 0.6 then
            hold, holdKey = 0.0, nil
            local ok
            if t.box then ok = lib.callback.await('opslabs-towers:cable:deleteBox', false, t.box.id)
            else ok = lib.callback.await('opslabs-towers:cable:deleteRun', false, t.run.id) end
            if ok then
                PlaySoundFrontend(-1, 'DELETE', 'HUD_DEATHMATCH_SOUNDSET', true)
                lib.notify({ type = 'success', description = (t.box and 'Box removed' or t.run.kind == 'trunk' and 'Trunking removed — cable inside stays on the wall' or 'Cable removed') .. ' · Z to undo' })
            end
            outline(nil)
            Wait(250)
        end
        if IsDisabledControlJustPressed(0, 20) then
            local r = lib.callback.await('opslabs-towers:cable:undo', false)
            if r and r.ok then lib.notify({ type = 'success', description = ('Put back %d %s'):format(r.count, r.kind == 'box' and 'box(es)' or 'piece(s)') })
            else lib.notify({ type = 'inform', description = (r and r.error) or 'Nothing to undo' }) end
            Wait(250)
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    outline(nil)
    PlaceHud.release(sf)
end

--- reshape a run: drag points, add points on the line (E), remove points (right click)
EditRoute = function(r)
    r = data.runs[r.id] or r
    local pts = {}
    for i, p in ipairs(r.points) do pts[i] = { x = p.x, y = p.y, z = p.z, nx = p.nx, ny = p.ny, nz = p.nz, t = p.t, p = p.p } end
    local function locked(i) return (i == 1 and (r.box_id or r.start_term)) or (i == #pts and r.end_term) end
    local key = 'r' .. r.id
    for _, e in ipairs(spawned[key] or {}) do if DoesEntityExist(e) then SetEntityVisible(e, false, false) end end
    local preview, dirty, lastBuild = {}, true, 0
    local function rebuild()
        for _, e in ipairs(preview) do if DoesEntityExist(e) then DeleteEntity(e) end end
        preview = {}
        BuildRun({ kind = r.kind, color = r.color, points = pts, box_id = r.box_id, start_term = r.start_term, end_term = r.end_term }, preview)
    end
    local function length()
        local l = 0.0
        for i = 2, #pts do l = l + #(vector3(pts[i].x, pts[i].y, pts[i].z) - vector3(pts[i - 1].x, pts[i - 1].y, pts[i - 1].z)) end
        return l
    end
    local box = r.box_id and data.boxes[r.box_id]
    local limit = r.kind == 'trunk' and nil or box and (r.length + box.remaining) or r.length
    local carrying, saved = nil, false
    local sf = PlaceHud.buttons({ { 'Pick up / drop point', 24 }, { 'Add point', 38 }, { 'Remove point', 25 }, { 'Save', 191 }, { 'Cancel', { 177, 200 } } })
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 38, 44, 140, 141, 142, 177, 191, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local at, normal = aim()
        if carrying and at then
            local np = { x = at.x, y = at.y, z = at.z, nx = normal.x, ny = normal.y, nz = normal.z }
            if r.kind ~= 'trunk' then
                local snap = snapToTrunking(at)
                if snap then np = { x = snap.pos.x, y = snap.pos.y, z = snap.pos.z, nx = snap.n.x, ny = snap.n.y, nz = snap.n.z, t = snap.run } end
            end
            local o = pts[carrying]
            if #(vector3(o.x, o.y, o.z) - vector3(np.x, np.y, np.z)) > 0.01 then pts[carrying] = np dirty = true end
        end
        if dirty and GetGameTimer() - lastBuild > 90 then rebuild() dirty = false lastBuild = GetGameTimer() end
        -- points: grey = fixed (on the box / plugged in), blue = hovered, white = movable
        local hover
        if at and not carrying then
            local bd = 0.25
            for i, p in ipairs(pts) do
                local d = #(at - vector3(p.x, p.y, p.z))
                if d < bd then hover, bd = i, d end
            end
        end
        for i, p in ipairs(pts) do
            local c = (i == carrying or i == hover) and { 10, 132, 255 } or locked(i) and { 140, 140, 145 } or { 255, 255, 255 }
            DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.035, 0.035, 0.035, c[1], c[2], c[3], 230, false, false, 2, false, nil, nil, false)
        end
        local L = length()
        local over = limit and L > limit + 0.05
        PlaceHud.draw(sf, 'Reshaping ' .. runLabel(r) .. ' #' .. r.id,
            ('%.1f m%s%s'):format(L, limit and (' of %.1f m %s'):format(limit, box and 'available' or 'slack') or '', over and '   ·   too long' or (hover and locked(hover) and '   ·   that end is fixed' or '')),
            { 10, 132, 255 }, over)
        if IsDisabledControlJustPressed(0, 24) then
            if carrying then carrying = nil PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
            elseif hover and not locked(hover) then carrying = hover end
        end
        if IsDisabledControlJustPressed(0, 38) and at and not carrying then
            -- the segment of the edited points under the crosshair
            local seg, q, bd = nil, nil, 0.3
            for i = 1, #pts - 1 do
                local a, b = vector3(pts[i].x, pts[i].y, pts[i].z), vector3(pts[i + 1].x, pts[i + 1].y, pts[i + 1].z)
                local d = b - a
                local tt = math.max(0.0, math.min(1.0, dot(at - a, d) / math.max(1e-6, dot(d, d))))
                local c = a + d * tt
                if #(at - c) < bd then seg, q, bd = i, c, #(at - c) end
            end
            if seg then
                local a = pts[seg]
                table.insert(pts, seg + 1, { x = q.x, y = q.y, z = q.z, nx = a.nx, ny = a.ny, nz = a.nz, t = (a.t and a.t == pts[seg + 1].t) and a.t or nil })
                carrying = seg + 1
                dirty = true
            end
        end
        if IsDisabledControlJustPressed(0, 25) and hover and not carrying and not locked(hover) and #pts > 2 then
            table.remove(pts, hover)
            dirty = true
        end
        if IsDisabledControlJustPressed(0, 191) and not carrying then
            if over then lib.notify({ type = 'error', description = box and 'Not enough cable left in the box' or 'Not enough slack — this piece is cut to length' })
            else
                local res = lib.callback.await('opslabs-towers:cable:reroute', false, r.id, pts)
                if res and res.ok then saved = true lib.notify({ type = 'success', description = 'Route updated' }) break end
                lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
            end
        end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then
            if carrying then carrying = nil else break end
        end
    end
    PlaceHud.release(sf)
    for _, e in ipairs(preview) do if DoesEntityExist(e) then DeleteEntity(e) end end
    if not saved then for _, e in ipairs(spawned[key] or {}) do if DoesEntityExist(e) then SetEntityVisible(e, true, false) end end end
end

moveBox = function(b)
    local t = boxType(b)
    local spot = PlacementMode('box', t.model, 1.0, b.heading, 'Moving ' .. t.label .. ' box')
    if not spot then return end
    local exit = boxExit({ x = spot.x, y = spot.y, z = spot.z, heading = spot.heading, kind = b.kind })
    local r = lib.callback.await('opslabs-towers:cable:moveBox', false, b.id, spot, exit)
    if r and r.ok then lib.notify({ type = 'success', description = 'Box moved — cable still on it followed' })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

--- aim at a box or a run and click to move it
local function MoveMode()
    local sf = PlaceHud.buttons({ { 'Move this', 24 }, { 'Done', { 25, 177, 200 } } })
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 44, 140, 141, 142, 177, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local t = aimTarget()
        outline(t and t.key, 10, 132, 255)
        PlaceHud.draw(sf, 'Move cable, trunking or a box', not t and 'Aim at what you want to move'
            or t.box and ('%s box · click to pick it up'):format(boxType(t.box).label)
            or ('%s #%d · click to reshape its route'):format(runLabel(t.run), t.run.id), { 10, 132, 255 })
        if t and IsDisabledControlJustPressed(0, 24) then
            outline(nil)
            PlaceHud.release(sf)
            if t.box then moveBox(t.box) else EditRoute(t.run) end
            Wait(250)
            sf = PlaceHud.buttons({ { 'Move this', 24 }, { 'Done', { 25, 177, 200 } } })
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    outline(nil)
    PlaceHud.release(sf)
end

RunsMenu = function()
    local pos = GetEntityCoords(PlayerPedId())
    local list = {}
    for _, r in pairs(data.runs) do
        local best = math.huge
        for _, p in ipairs(r.points or {}) do best = math.min(best, #(pos - vector3(p.x, p.y, p.z))) end
        if best < 60 then list[#list + 1] = { r = r, d = best } end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local options = {}
    local trunks, cablesIds = {}, {}
    for _, e in ipairs(list) do
        if e.r.kind == 'trunk' then trunks[#trunks + 1] = e.r.id else cablesIds[#cablesIds + 1] = e.r.id end
    end
    local function bulk(ids, header, body)
        if lib.alertDialog({ header = header, content = body, centered = true, cancel = true }) == 'confirm' then
            local n = lib.callback.await('opslabs-towers:cable:deleteRuns', false, ids)
            lib.notify({ type = 'success', description = ('Removed %d'):format(n or 0) })
            Wait(250)
        end
        RunsMenu()
    end
    options[#options + 1] = { title = 'Remove by aiming', description = 'Aim at any cable or trunking and click', icon = 'crosshairs', iconColor = '#ff453a', onSelect = function() RemoveMode() RunsMenu() end }
    options[#options + 1] = { title = 'Remove cable in an area (draw a box)', description = 'Click two corners on the ground · any size · cable in players’ hands inside it goes too', icon = 'vector-square', iconColor = '#ff453a', onSelect = function() AreaRemove() RunsMenu() end }
    options[#options + 1] = { title = 'Remove all within a range…', description = 'Pick what and how far (5–200 m)', icon = 'circle-radiation', iconColor = '#ff453a', onSelect = function() ReturnMenu = function() RunsMenu() end RemoveInRange() end }
    options[#options + 1] = { title = ('Remove all trunking nearby (%d)'):format(#trunks), icon = 'grip-lines', iconColor = '#ff5a5f', disabled = #trunks == 0,
        onSelect = function() bulk(trunks, 'Remove all trunking within 60 m?', 'Cable inside it stays on the wall.') end }
    options[#options + 1] = { title = ('Remove all cable & fibre nearby (%d)'):format(#cablesIds), icon = 'ethernet', iconColor = '#ff5a5f', disabled = #cablesIds == 0,
        onSelect = function() bulk(cablesIds, 'Remove all cable and fibre within 60 m?', 'Devices fed by it lose their uplink.') end }
    for _, e in ipairs(list) do
        local r = e.r
        local state = r.kind == 'trunk' and r.color or (r.start_term and r.end_term and 'connected both ends' or r.box_id and 'on the box' or 'needs terminating')
        options[#options + 1] = { title = ('%s #%d · %.1f m'):format(r.kind == 'trunk' and 'Trunking' or r.kind == 'fibre' and ('Fibre ' .. r.color) or r.kind == 'cable' and 'CAT6' or runLabel(r), r.id, r.length or 0),
            description = ('%s · %dm away'):format(state, math.floor(e.d)), icon = r.kind == 'trunk' and 'grip-lines' or r.kind == 'copper' and 'phone' or 'ethernet',
            iconColor = r.kind ~= 'trunk' and (r.start_term and r.end_term and '#30d158' or '#ff9f0a') or nil, arrow = true, onSelect = function() RunMenu(r) end }
    end
    if #list == 0 then options[#options + 1] = { title = 'No cables nearby', readOnly = true } end
    lib.registerContext({ id = 'cable_runs', title = 'Nearby cables & trunking', menu = 'cable_main', onBack = function() CableMenu() end, options = options })
    lib.showContext('cable_runs')
end

local function pullCable()
    local box = nearestBox(CC.PullDistance)
    if not box then lib.notify({ type = 'error', description = 'Stand next to a cable box to pull cable from it' }) return menuBack() end
    if box.remaining < 1 then lib.notify({ type = 'error', description = 'This box is empty' }) return menuBack() end
    local fibre = (box.kind or 'cat6') ~= 'cat6'
    local kind, color = fibre and 'fibre' or 'cable', (box.kind == 'drop' and 'ulw') or (fibre and box.kind:match('^fibre_(%a+)$')) or 'black'
    local pts, endTower, endFixture, dropped = layRun(kind, color, box)
    if not pts then return menuBack() end
    local drop
    if dropped then                                            -- slack from the last fixing down to the floor and over to your feet
        local l, feet = pts[#pts], GetEntityCoords(PlayerPedId())
        local g = groundUnder(feet.x, feet.y, feet.z)
        drop = { at = { x = feet.x, y = feet.y, z = g },
            len = math.max(0.5, (l.z - groundUnder(l.x, l.y, l.z)) + #(vector2(l.x, l.y) - vector2(feet.x, feet.y)) + 0.5) }
        endTower, endFixture = nil, nil
    end
    local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = kind, color = color, points = pts, box_id = box.id, end_tower = endTower, end_fixture = endFixture, drop = drop })
    if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) return menuBack() end
    Wait(250)
    if dropped then
        lib.notify({ type = 'success', description = 'Cable put down — it stays on the box. Walk back to the end and press E to carry on pulling.' })
        return menuBack()
    end
    if endTower or endFixture then
        local devName = towerName(endTower) or fixtureLabel(endFixture) or 'the device'
        local c = fibre
            and lib.alertDialog({ header = 'Splice into ' .. devName .. '?', content = 'Strip, clean, cleave and fusion-splice the fibre.', centered = true, cancel = true, labels = { confirm = 'Splice', cancel = 'Later' } })
            or lib.alertDialog({ header = 'Terminate into ' .. devName .. '?', content = 'Strip, arrange the pairs (' .. CC.Standard .. '), crimp an RJ45 and plug it in.', centered = true, cancel = true, labels = { confirm = 'Terminate', cancel = 'Later' } })
        if c == 'confirm' then TerminateEnd(res.run, 'end', endTower, endFixture) Wait(250) end
    end
    RunMenu(res.run)
end

local function placeBox()
    local opts = { { value = 'cat6', label = ('CAT6 · %d m'):format(CC.BoxLength) } }
    for _, c in ipairs(CC.FibreColors) do
        local drum = c == 'spine' or c == 'ulw'
        opts[#opts + 1] = { value = 'fibre_' .. c, label = ('%s %s · %d m'):format((CC.FibreLabels or {})[c] or ('Fibre ' .. c), drum and 'drum' or 'box', (CC.FibreBoxLength or {})[c] or 0) }
    end
    local v = lib.inputDialog('Place a cable box', { { type = 'select', label = 'Box', options = opts, default = 'cat6', required = true } })
    if not v then return menuBack() end
    local t = BOXES[v[1]]
    local spot = PlacementMode('box', t.model, 1.0, nil, 'Placing ' .. t.label .. ' box')
    if spot then
        spot.kind = v[1]
        local r = lib.callback.await('opslabs-towers:cable:placeBox', false, spot)
        if r and r.ok then lib.notify({ type = 'success', description = t.label .. ' box placed' }) Wait(250)
        else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    menuBack()
end

local function layTrunking()
    local opts = {}
    for _, c in ipairs(CC.TrunkColors) do opts[#opts + 1] = { value = c, label = (CC.TrunkLabels or {})[c] or (c:sub(1, 1):upper() .. c:sub(2)) } end
    local v = lib.inputDialog('Trunking, capping & ducts', { { type = 'select', label = 'Type', options = opts, default = CC.TrunkColors[1], required = true } })
    if not v then return menuBack() end
    local pts = layRun('trunk', v[1])
    if pts then
        local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = 'trunk', color = v[1], points = pts })
        if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
        else lib.notify({ type = 'success', description = ('%.1f m of %s trunking fitted'):format(res.run.length, v[1]) }) end
        Wait(250)
    end
    menuBack()
end

local EquipmentMenu, equipLabelFor

local function isBuilding(model)
    for _, e in ipairs(CC.Equipment) do if e.building and e.model == model then return true end end
    return false
end

--- fine-tune where something sits: arrows slide it (along its own front / side), PgUp / PgDn height, Q / E turn,
--- Shift for fine steps. A see-through copy shows the result; Enter saves, Backspace puts it back.
function NudgeFixture(f)
    local h = joaat(f.model)
    if not IsModelInCdimage(h) then return end
    lib.requestModel(h, 5000)
    local ghost = CreateObjectNoOffset(h, f.x, f.y, f.z, false, false, false)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    local hidden = spawned['f' .. f.id] or {}
    for _, e in ipairs(hidden) do if DoesEntityExist(e) then SetEntityVisible(e, false, false) end end
    local x, y, z, hd = f.x, f.y, f.z, f.heading or 0.0
    local sf = PlaceHud.buttons({ { 'Save', 191 }, { 'Cancel', 177 }, { 'Slide', { 172, 173, 174, 175 } }, { 'Height', { 10, 11 } }, { 'Turn', { 44, 38 } }, { 'Fine', 21 } })
    local saved = false
    while true do
        Wait(0)
        for _, c in ipairs({ 10, 11, 38, 44, 140, 141, 142, 172, 173, 174, 175, 177, 191, 199, 200 }) do DisableControlAction(0, c, true) end
        local fine = IsControlPressed(0, 21)
        local step, turn = fine and 0.005 or 0.04, fine and 0.1 or 1.0
        local r = math.rad(hd)
        local fx, fy = -math.sin(r), math.cos(r)             -- its +Y (back) direction; front faces -Y
        local rx, ry = math.cos(r), math.sin(r)
        if IsDisabledControlPressed(0, 172) then x, y = x - fx * step, y - fy * step end
        if IsDisabledControlPressed(0, 173) then x, y = x + fx * step, y + fy * step end
        if IsDisabledControlPressed(0, 174) then x, y = x - rx * step, y - ry * step end
        if IsDisabledControlPressed(0, 175) then x, y = x + rx * step, y + ry * step end
        if IsDisabledControlPressed(0, 10) then z = z + step * 0.5 end
        if IsDisabledControlPressed(0, 11) then z = z - step * 0.5 end
        if IsDisabledControlPressed(0, 44) then hd = (hd + turn) % 360 end
        if IsDisabledControlPressed(0, 38) then hd = (hd - turn) % 360 end
        SetEntityCoordsNoOffset(ghost, x, y, z, false, false, false)
        SetEntityHeading(ghost, hd)
        PlaceHud.draw(sf, 'Adjusting ' .. equipLabelFor(f.model), ('Moved %.2f m   ·   height %+.2f m   ·   heading %.1f°%s'):format(
            math.sqrt((x - f.x) ^ 2 + (y - f.y) ^ 2), z - f.z, hd, fine and '   ·   fine' or ''))
        if IsDisabledControlJustPressed(0, 191) then saved = true break end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    DeleteEntity(ghost)
    for _, e in ipairs(hidden) do if DoesEntityExist(e) then SetEntityVisible(e, true, false) end end
    if saved then
        local res = lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = x, y = y, z = z, heading = hd })
        if res and res.ok then lib.notify({ type = 'success', description = 'Saved — it stays there after restarts' }) Wait(250)
        else lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) end
    end
end

--- outside the front of a building (fronts face -Y), or just beside smaller kit
local function besideFixture(f)
    local mn = GetModelDimensions(joaat(f.model))
    local back = isBuilding(f.model) and (mn.y - 2.0) or -1.0
    local r = math.rad(f.heading or 0.0)
    return f.x - math.sin(r) * back, f.y + math.cos(r) * back, f.z + 0.5, (f.heading or 0.0)
end

local function fixtureMenu(f)
    f = data.fixtures[f.id] or f
    local label = equipLabelFor(f.model)
    local options = {
        { title = ('#%d · placed by %s'):format(f.id, f.created_by or '?'), icon = 'tower-broadcast', readOnly = true },
    }
    if f.model:find('^opslabs_pole_') or f.model == 'opslabs_house_pole' then
        local st = f.data and f.data.status
        options[#options + 1] = { title = 'Status: ' .. (st and (st:sub(1, 1):upper() .. st:sub(2)) or 'Automatic'), description = 'Automatic = live when light reaches its kit, building while it’s being fitted out',
            icon = 'helmet-safety', iconColor = st == 'maintenance' and '#ff453a' or st and '#ff9f0a' or '#30d158', onSelect = function()
            local v = lib.inputDialog('Pole status', { { type = 'select', label = 'Status', default = st or 'auto', required = true, options = {
                { value = 'auto', label = 'Automatic (live / building / planned)' }, { value = 'planned', label = 'Planned' },
                { value = 'building', label = 'Building' }, { value = 'maintenance', label = 'In maintenance' } } } })
            if v then
                local r = lib.callback.await('opslabs-towers:pole:status', false, f.id, v[1])
                if r and r.error then lib.notify({ type = 'error', description = r.error }) end
                Wait(250)
            end
            fixtureMenu(f)
        end }
    end
    if f.model == 'opslabs_core_router' then
        local d = f.data or {}
        options[#options + 1] = { title = 'Switching', description = ('Uplink %s · %d OLT(s) patched'):format(d.uplink and 'up' or 'down', #(d.patched or {})),
            icon = 'shuffle', iconColor = d.uplink and '#30d158' or '#ff9f0a', arrow = true, onSelect = function() SwitchingMenu(f) end }
    end
    if f.model == 'opslabs_pole_metal' then
        local b = f.data and f.data.brand
        options[#options + 1] = { title = 'Branding & info', description = b and ('%s · %s'):format(b.name ~= '' and b.name or '—', b.number or '') or 'Company name, colour, pole number, phone — shown on the pole plate',
            icon = 'id-card', iconColor = b and b.color or '#0a84ff', onSelect = function() EditPoleBranding(f, function() fixtureMenu(data.fixtures[f.id] or f) end) end }
    end
    if Config.Buildings and Config.Buildings[f.model] and Config.Buildings[f.model].doors and DoorsMenu then
        options[#options + 1] = { title = 'Doors & PINs', description = ('%d door(s) · lock state, set the same PIN everywhere'):format(#Config.Buildings[f.model].doors),
            icon = 'key', iconColor = '#ff9f0a', arrow = true, onSelect = function() DoorsMenu(data.fixtures[f.id] or f) end }
    end
    if BRANDED_MODEL[f.model] and EditBrandSign then
        local b = f.data and f.data.brand
        options[#options + 1] = { title = 'Branding', description = b and ('%s · %s'):format(b.name ~= '' and b.name or '—', b.message or '') or 'Company name, colour, message, phone',
            icon = 'id-card', iconColor = b and b.color or '#0a84ff', onSelect = function() EditBrandSign(f, function() fixtureMenu(data.fixtures[f.id] or f) end) end }
    end
    if f.model == ONT_MODEL then
        options[#options + 1] = { title = 'Internet service', description = 'Provider, plan, suspend / resume', icon = 'wifi', iconColor = '#30d158', arrow = true,
            onSelect = function() IspMenu(f, function() fixtureMenu(f) end) end }
    end
    local building = isBuilding(f.model)
    if building then
        options[#options + 1] = { title = 'Saved', description = ('Kept in the database — it comes back after restarts · %.1f, %.1f, %.1f · heading %.0f°'):format(f.x, f.y, f.z, f.heading or 0),
            icon = 'database', iconColor = '#30d158', readOnly = true }
    end
    options[#options + 1] = { title = 'Move (aim & place)', description = building and 'Pick it up and put it down somewhere else (aim up to 90 m away)' or nil, icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function()
        local spot = PlacementMode('fixture', f.model, 1.0, f.heading, 'Moving ' .. label)
        if spot then lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading }) Wait(250) end
        fixtureMenu(f)
    end }
    options[#options + 1] = { title = 'Fine-tune position', description = 'Slide, raise / lower and turn it a little at a time · Shift for fine', icon = 'arrows-up-down-left-right', iconColor = '#0a84ff', onSelect = function()
        NudgeFixture(f)
        fixtureMenu(data.fixtures[f.id] or f)
    end }
    if building then
        options[#options + 1] = { title = 'Set exact position', description = 'Type in the heading and height', icon = 'compass-drafting', onSelect = function()
            local v = lib.inputDialog(label, {
                { type = 'number', label = 'Heading (°)', default = math.floor((f.heading or 0) * 10 + 0.5) / 10, min = 0, max = 360, step = 0.1, precision = 1 },
                { type = 'number', label = 'Height (z)', default = math.floor(f.z * 100 + 0.5) / 100, step = 0.01, precision = 2 },
            })
            if v then lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = f.x, y = f.y, z = tonumber(v[2]) or f.z, heading = (tonumber(v[1]) or f.heading or 0) % 360 }) Wait(250) end
            fixtureMenu(data.fixtures[f.id] or f)
        end }
    end
    options[#options + 1] = { title = building and 'Teleport to the front door' or 'Teleport here', icon = 'location-arrow', onSelect = function()
        local tx, ty, tz, th = besideFixture(f)
        SetEntityCoords(PlayerPedId(), tx, ty, tz, false, false, false, false)
        if building then SetEntityHeading(PlayerPedId(), th) end
        fixtureMenu(f)
    end }
    options[#options + 1] = { title = 'Remove', description = building and 'Deletes it from the database — doors and PINs go with it' or nil, icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
        if lib.alertDialog({ header = 'Remove ' .. label .. '?', content = building and 'It is deleted for good (it won’t come back after a restart).' or nil, centered = true, cancel = true }) == 'confirm' then
            lib.callback.await('opslabs-towers:fixture:delete', false, f.id) Wait(250)
            if not MenuBack('cable_fixture') then EquipmentMenu() end
            return
        end
        fixtureMenu(f)
    end }
    lib.registerContext({ id = 'cable_fixture', title = label, options = options })
    lib.showContext('cable_fixture')
end

equipLabelFor = function(model)
    for _, e in ipairs(CC.Equipment) do
        if e.model == model then return e.label end
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then return e.label .. ' · ' .. sz.label end end
    end
    return model
end

--- pick a size when an item comes in sizes (CBT 4 / 8 / 12 ports…); returns the model or nil
function EquipmentSize(e)
    if not e.sizes then return e.model end
    local opts = {}
    for _, sz in ipairs(e.sizes) do opts[#opts + 1] = { value = sz.model, label = sz.label } end
    local v = lib.inputDialog(e.label, { { type = 'select', label = e.sizeLabel or 'Size', icon = e.sizeLabel and 'palette' or 'ruler', options = opts, default = e.model, required = true } })
    return v and v[1] or nil
end

local function placeEquipment(e, back)
    local modelName = EquipmentSize(e)
    if not modelName then return back() end
    local spot = PlacementMode('fixture', modelName, 1.0, nil, 'Placing ' .. equipLabelFor(modelName))
    if spot then
        local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = modelName, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
        if r and r.ok then lib.notify({ type = 'success', description = equipLabelFor(modelName) .. ' placed' }) Wait(250)
        else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    back()
end

local function categoryMenu(net, cat)
    local options = {}
    for _, e in ipairs(CC.Equipment) do
        if (e.net or 'openline') == net.id and e.cat == cat and IsModelInCdimage(joaat((e.sizes and e.sizes[1].model) or e.model)) then
            options[#options + 1] = { title = e.label, description = (e.sizes and (#e.sizes .. ' sizes') or '') .. (e.pole and ((e.sizes and ' · ' or '') .. 'can be fitted from the pole menu') or ''),
                icon = 'plus', onSelect = function() placeEquipment(e, function() categoryMenu(net, cat) end) end }
        end
    end
    if cat == 'Security & fencing' and FenceLine then
        table.insert(options, 1, { title = 'Lay a fence line', description = 'Click the start, aim at the end — panels (or bollards) are previewed along the line',
            icon = 'grip-lines', iconColor = '#5e5ce6', onSelect = function()
                local list = {}
                for _, e in ipairs(CC.Equipment) do if e.fence then list[#list + 1] = { value = e.model, label = e.label } end end
                local v = lib.inputDialog('Fence line', { { type = 'select', label = 'What', icon = 'grip-lines', options = list, required = true, default = list[1] and list[1].value } })
                if v then
                    local e
                    for _, x in ipairs(CC.Equipment) do if x.model == v[1] then e = x end end
                    local modelName = e and EquipmentSize(e)
                    if modelName then FenceLine(modelName, e.gap) end
                end
                categoryMenu(net, cat)
            end })
    end
    if #options == 0 then options[1] = { title = 'Start opslabs-props to place this equipment', readOnly = true } end
    lib.registerContext({ id = 'cable_equip_cat', title = cat .. ' · ' .. net.label, options = options })
    lib.showContext('cable_equip_cat')
end

local CAT_ICON = {
    ['Poles & fixings'] = 'tower-observation', ['Exchange network kit'] = 'server', ['Street cabinets & chambers'] = 'box-archive',
    ['Underground joints'] = 'circle-down', ['On the pole'] = 'arrow-up-from-bracket', ['Customer premises · outside'] = 'house-chimney',
    ['Customer premises · inside'] = 'house-laptop', ['Power poles'] = 'tower-observation', ['On the power pole'] = 'bolt',
    ['Safety & earthing'] = 'triangle-exclamation', ['Buildings'] = 'city', ['Exchange power & cooling'] = 'plug', ['Copper phone line'] = 'phone',
}

function EquipmentNetMenu(net)
    local cats, seen = {}, {}
    for _, e in ipairs(CC.Equipment) do
        if (e.net or 'openline') == net.id and e.cat and not seen[e.cat] then seen[e.cat] = true cats[#cats + 1] = e.cat end
    end
    local options = {}
    for _, cat in ipairs(cats) do
        local n = 0
        for _, e in ipairs(CC.Equipment) do if (e.net or 'openline') == net.id and e.cat == cat then n = n + 1 end end
        options[#options + 1] = { title = cat, description = n .. ' item' .. (n == 1 and '' or 's'), icon = CAT_ICON[cat] or 'folder', iconColor = net.color, arrow = true, onSelect = function() categoryMenu(net, cat) end }
    end
    lib.registerContext({ id = 'cable_equip_net', title = net.label .. ' · equipment', options = options })
    lib.showContext('cable_equip_net')
end

local function netLabelOf(model)
    for _, e in ipairs(CC.Equipment) do
        local hit = e.model == model
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then hit = true end end
        if hit then
            if e.net == 'sites' then return (CC.Sites or {}).label or 'Buildings & sites', e.cat end
            for _, n in ipairs(CC.Networks or {}) do if n.id == (e.net or 'openline') then return n.label, e.cat end end
        end
    end
    return 'Other', nil
end

--- everything placed within 60 m (road safety kit has its own menu)
EquipmentMenu = function()
    local options = {}
    local pos = GetEntityCoords(PlayerPedId())
    local near = {}
    for _, f in pairs(data.fixtures) do
        local d = #(pos - vector3(f.x, f.y, f.z))
        if d < 60 and not f.model:find('^opslabs_rw_') then near[#near + 1] = { f = f, d = d } end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#near, 30) do
        local f = near[i].f
        local netLabel, cat = netLabelOf(f.model)
        options[#options + 1] = { title = equipLabelFor(f.model), description = ('%d m away · %s%s'):format(math.floor(near[i].d), netLabel, cat and (' · ' .. cat) or ''),
            icon = 'location-dot', arrow = true, onSelect = function() fixtureMenu(f) end }
    end
    if #options == 0 then options[1] = { title = 'Nothing placed within 60 m', readOnly = true } end
    lib.registerContext({ id = 'cable_equipment', title = 'Nearby equipment', options = options })
    lib.showContext('cable_equipment')
end

nearbyBoxCount = function()
    local pos, n = GetEntityCoords(PlayerPedId()), 0
    for _, b in pairs(data.boxes) do if #(pos - vector3(b.x, b.y, b.z)) < 80 then n = n + 1 end end
    return n
end

local function boxMenu(b)
    b = data.boxes[b.id] or b
    local t = boxType(b)
    lib.registerContext({ id = 'cable_box', title = t.label .. ' box #' .. b.id, menu = 'cable_boxes', onBack = function() BoxesMenu() end, options = {
        { title = ('%.0f m of cable left'):format(b.remaining or 0), description = 'Placed by ' .. (b.created_by or '?'), icon = 'box', readOnly = true },
        { title = 'Teleport here', icon = 'location-arrow', onSelect = function()
            SetEntityCoords(PlayerPedId(), b.x, b.y - 0.8, b.z + 0.3, false, false, false, false)
            boxMenu(b)
        end },
        { title = 'Move this box', description = 'Aim & place · cable still on it follows', icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function()
            moveBox(b)
            Wait(250)
            boxMenu(b)
        end },
        { title = 'Remove this box', description = 'Cable already laid from it stays where it is', icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
            if lib.alertDialog({ header = 'Remove this box?', content = ('%.0f m of cable left in it.'):format(b.remaining or 0), centered = true, cancel = true }) == 'confirm' then
                lib.callback.await('opslabs-towers:cable:deleteBox', false, b.id)
                Wait(250)
                return BoxesMenu()
            end
            boxMenu(b)
        end },
    } })
    lib.showContext('cable_box')
end

BoxesMenu = function()
    local pos = GetEntityCoords(PlayerPedId())
    local list = {}
    for _, b in pairs(data.boxes) do
        local d = #(pos - vector3(b.x, b.y, b.z))
        if d < 80 then list[#list + 1] = { b = b, d = d } end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local empty, all = {}, {}
    for _, e in ipairs(list) do
        all[#all + 1] = e.b.id
        if (e.b.remaining or 0) < 1 then empty[#empty + 1] = e.b.id end
    end
    local function bulk(ids, header)
        if #ids == 0 then return BoxesMenu() end
        if lib.alertDialog({ header = header, content = ('%d box(es). Laid cable stays where it is.'):format(#ids), centered = true, cancel = true }) == 'confirm' then
            local n = lib.callback.await('opslabs-towers:cable:deleteBoxes', false, ids)
            lib.notify({ type = 'success', description = ('Removed %d box(es)'):format(n or 0) })
            Wait(250)
        end
        BoxesMenu()
    end
    local options = {
        { title = ('Remove empty boxes (%d)'):format(#empty), icon = 'box-open', disabled = #empty == 0, onSelect = function() bulk(empty, 'Remove all empty boxes nearby?') end },
        { title = ('Remove all boxes nearby (%d)'):format(#all), icon = 'trash', iconColor = '#ff5a5f', disabled = #all == 0, onSelect = function() bulk(all, 'Remove every box within 80 m?') end },
    }
    for _, e in ipairs(list) do
        local b = e.b
        options[#options + 1] = { title = ('%s box #%d'):format(boxType(b).label, b.id), description = ('%.0f m left · %dm away'):format(b.remaining or 0, math.floor(e.d)),
            icon = 'box', iconColor = (b.remaining or 0) < 1 and '#8e8e93' or nil, arrow = true, onSelect = function() boxMenu(b) end }
    end
    if #list == 0 then options[#options + 1] = { title = 'No boxes within 80 m', readOnly = true } end
    lib.registerContext({ id = 'cable_boxes', title = 'Cable boxes', menu = 'cable_main', onBack = function() CableMenu() end, options = options })
    lib.showContext('cable_boxes')
end

function RunPowerCable()
    local opts = {}
    for _, c in ipairs(CC.PowerColors or {}) do opts[#opts + 1] = { value = c, label = (CC.PowerLabels or {})[c] or c } end
    local v = lib.inputDialog('Power cable', { { type = 'select', label = 'Cable', options = opts, default = opts[1] and opts[1].value, required = true } })
    if v then
        local pts = layRun('power', v[1])
        if pts then
            local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = 'power', color = v[1], points = pts })
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
            else lib.notify({ type = 'success', description = ('%.1f m of %s run'):format(res.run.length, ((CC.PowerLabels or {})[v[1]] or 'power cable'):lower()) }) end
            Wait(250)
        end
    end
    menuBack()
    end

---------------------------------------------------------------------------
-- remove cable in a box drawn on the ground (any size, every height) — cable in people's hands inside it goes too
---------------------------------------------------------------------------
local AREA_KINDS = { cabling = { cable = true, fibre = true }, cable = { cable = true }, fibre = { fibre = true }, copper = { copper = true },
    power = { power = true }, trunk = { trunk = true }, wires = { cable = true, fibre = true, copper = true, power = true } }
local AREA_ORDER = { { 'wires', 'All cable (CAT6, fibre, phone, power)' }, { 'all', 'Everything (cable + trunking & ducts)' }, { 'cabling', 'CAT6 & fibre' },
    { 'cable', 'CAT6 only' }, { 'fibre', 'Fibre only' }, { 'copper', 'Phone cable only' }, { 'power', 'Power cable only' }, { 'trunk', 'Trunking & ducts only' } }
function AREA_KIND_OK(what, kind) return what == 'all' or (AREA_KINDS[what] or {})[kind] == true end

AreaCleared = nil
RegisterNetEvent('opslabs-towers:cable:areaCleared', function(r, what) AreaCleared = { r = r, what = what, at = GetGameTimer() } end)

local function segHitsRect(a, b, r)
    local t0, t1, dx, dy = 0.0, 1.0, b.x - a.x, b.y - a.y
    for _, e in ipairs({ { -dx, a.x - r.minx }, { dx, r.maxx - a.x }, { -dy, a.y - r.miny }, { dy, r.maxy - a.y } }) do
        local p, q = e[1], e[2]
        if p == 0 then if q < 0 then return false end
        else
            local t = q / p
            if p < 0 then if t > t1 then return false elseif t > t0 then t0 = t end
            else if t < t0 then return false elseif t < t1 then t1 = t end end
        end
    end
    return true
end

local function runsInArea(r, what)
    local out, metres = {}, 0.0
    for id, run in pairs(data.runs) do
        if AREA_KIND_OK(what, run.kind) then
            local pts, hit = run.points or {}, false
            for i = 1, #pts do
                local p = pts[i]
                if (p.x >= r.minx and p.x <= r.maxx and p.y >= r.miny and p.y <= r.maxy) or (i > 1 and segHitsRect(pts[i - 1], p, r)) then hit = true break end
            end
            for _, tip in pairs(run._looseTip or {}) do
                if tip.x >= r.minx and tip.x <= r.maxx and tip.y >= r.miny and tip.y <= r.maxy then hit = true end
            end
            if hit then out[#out + 1] = id metres = metres + (run.length or 0) end
        end
    end
    return out, metres
end

function AreaRemove()
    local A, mode = nil, 1
    local lit = {}
    local function unlight()
        for _, e in ipairs(lit) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
        lit = {}
    end
    local sf = PlaceHud.buttons({ { 'Corner / remove', { 24, 191 } }, { 'What', 37 }, { 'Back', { 25, 177 } }, { 'Cancel', 200 } })
    local found, metres, lastScan = {}, 0.0, 0
    while true do
        Wait(0)
        for _, c in ipairs({ 24, 25, 37, 140, 141, 142, 177, 191, 199, 200, 257, 263 }) do DisableControlAction(0, c, true) end
        DisablePlayerFiring(PlayerId(), true)
        if IsDisabledControlJustPressed(0, 37) then mode = mode % #AREA_ORDER + 1 lastScan = 0 end
        local cam, rot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local rx, rz = math.rad(rot.x), math.rad(rot.z)
        local to = cam + vector3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx)) * 150.0
        local _, hit, at = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, to.x, to.y, to.z, 1, PlayerPedId(), 4))
        local what = AREA_ORDER[mode]
        local r
        if hit == 1 then
            DrawMarker(28, at.x, at.y, at.z, 0, 0, 0, 0, 0, 0, 0.12, 0.12, 0.12, 255, 69, 58, 220, false, false, 2, false, nil, nil, false)
            if A then
                r = { minx = math.min(A.x, at.x), maxx = math.max(A.x, at.x), miny = math.min(A.y, at.y), maxy = math.max(A.y, at.y) }
                local z0, z1 = math.min(A.z, at.z) - 0.5, math.max(A.z, at.z) + 0.05
                local c = { vector3(r.minx, r.miny, z1), vector3(r.maxx, r.miny, z1), vector3(r.maxx, r.maxy, z1), vector3(r.minx, r.maxy, z1) }
                for i = 1, 4 do
                    local a, b = c[i], c[i % 4 + 1]
                    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 255, 69, 58, 255)
                    DrawLine(a.x, a.y, a.z + 15.0, b.x, b.y, b.z + 15.0, 255, 69, 58, 120)
                    DrawLine(a.x, a.y, z0, a.x, a.y, a.z + 15.0, 255, 69, 58, 200)
                end
                DrawPoly(c[1].x, c[1].y, c[1].z, c[2].x, c[2].y, c[2].z, c[3].x, c[3].y, c[3].z, 255, 69, 58, 60)
                DrawPoly(c[1].x, c[1].y, c[1].z, c[3].x, c[3].y, c[3].z, c[4].x, c[4].y, c[4].z, 255, 69, 58, 60)
                DrawPoly(c[3].x, c[3].y, c[3].z, c[2].x, c[2].y, c[2].z, c[1].x, c[1].y, c[1].z, 255, 69, 58, 60)
                DrawPoly(c[4].x, c[4].y, c[4].z, c[3].x, c[3].y, c[3].z, c[1].x, c[1].y, c[1].z, 255, 69, 58, 60)
                if GetGameTimer() - lastScan > 250 then                    -- outline everything that will go
                    lastScan = GetGameTimer()
                    found, metres = runsInArea(r, what[1])
                    unlight()
                    SetEntityDrawOutlineColor(255, 69, 58, 255)
                    SetEntityDrawOutlineShader(1)
                    for _, id in ipairs(found) do
                        for _, e in ipairs(spawned['r' .. id] or {}) do
                            if #lit >= 600 then break end
                            if DoesEntityExist(e) then SetEntityDrawOutline(e, true) lit[#lit + 1] = e end
                        end
                    end
                end
            end
        end
        local note = not A and ('Click the first corner   ·   %s'):format(what[2])
            or r and ('%.0f × %.0f m   ·   %d piece(s), %.0f m   ·   %s'):format(r.maxx - r.minx, r.maxy - r.miny, #found, metres, what[2]) or 'Aim at the ground'
        PlaceHud.draw(sf, 'Remove cable in an area', note, { 255, 69, 58 })
        if hit == 1 and (IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191)) then
            if not A then A = at
            elseif r then
                if lib.alertDialog({ header = ('Remove %d piece(s)?'):format(#found), content = ('%s inside the %.0f × %.0f m box, at every height — %.0f m. Anyone holding cable in the box drops it. Z in Remove mode puts it back.')
                    :format(what[2], r.maxx - r.minx, r.maxy - r.miny, metres), centered = true, cancel = true }) == 'confirm' then
                    local res = lib.callback.await('opslabs-towers:cable:deleteArea', false, { x1 = r.minx, y1 = r.miny, x2 = r.maxx, y2 = r.maxy }, what[1])
                    if res and res.ok then lib.notify({ type = 'success', description = ('Removed %d piece(s)'):format(res.count or 0) })
                    else lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) end
                    break
                end
            end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) then
            if A then A = nil unlight() found, metres = {}, 0.0 else break end
        end
        if IsDisabledControlJustPressed(0, 200) then break end
    end
    unlight()
    PlaceHud.release(sf)
end

--- copper phone cable: drop wire from the pole, internal cable round the house, multi-pair between cabinets
function RunCopperCable()
    local opts = {}
    for _, c in ipairs(CC.CopperColors or {}) do opts[#opts + 1] = { value = c, label = (CC.CopperLabels or {})[c] or c } end
    local v = lib.inputDialog('Phone cable (copper)', { { type = 'select', label = 'Cable', options = opts, default = opts[1] and opts[1].value, required = true } })
    if v then
        local pts, _, endFixture = layRun('copper', v[1])
        if pts then
            local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = 'copper', color = v[1], points = pts, end_fixture = endFixture })
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
            else
                lib.notify({ type = 'success', description = ('%.1f m of %s run'):format(res.run.length, ((CC.CopperLabels or {})[v[1]] or 'phone cable'):lower()) })
                Wait(250)
                local cur = data.runs[res.run.id]
                if cur and endFixture and lib.alertDialog({ header = 'Punch it down on the ' .. (fixtureLabel(endFixture) or 'socket') .. '?', content = 'Do the other end from Tools → Nearby cables & trunking.', centered = true, cancel = true }) == 'confirm' then
                    TerminateEnd(cur, 'end', nil, endFixture)
                end
            end
            Wait(250)
        end
    end
    menuBack()
end

    --- remove every cable of a kind within a distance of the player (undo with Z in Remove mode)
local RANGE_KINDS = { { 'cabling', 'Cable & fibre' }, { 'cable', 'CAT6 only' }, { 'fibre', 'Fibre only' }, { 'power', 'Power cable' }, { 'copper', 'Phone cable (copper)' }, { 'trunk', 'Trunking, capping & ducts' }, { 'all', 'Everything' } }
function RemoveInRange()
    local opts = {}
    for _, k in ipairs(RANGE_KINDS) do opts[#opts + 1] = { value = k[1], label = k[2] } end
    local v = lib.inputDialog('Remove cable within a range', {
        { type = 'select', label = 'What', options = opts, default = 'cabling', required = true },
        { type = 'slider', label = 'Within (metres)', min = 5, max = 200, step = 5, default = 25 },
    })
    if not v then return menuBack() end
    local what, range = v[1], v[2]
    local pos = GetEntityCoords(PlayerPedId())
    local ids, metres = {}, 0.0
    for id, r in pairs(data.runs) do
        local match = what == 'all' or r.kind == what or (what == 'cabling' and (r.kind == 'cable' or r.kind == 'fibre'))
        if match then
            local near = false
            for _, p in ipairs(r.points or {}) do
                if #(pos - vector3(p.x, p.y, p.z)) <= range then near = true break end
            end
            for _, tip in pairs(r._looseTip or {}) do if #(pos - tip) <= range then near = true end end
            if near then ids[#ids + 1] = id metres = metres + (r.length or 0) end
        end
    end
    if #ids == 0 then lib.notify({ type = 'inform', description = 'Nothing like that within ' .. range .. ' m' }) return menuBack() end
    local label = ({ cabling = 'cable and fibre', cable = 'CAT6 cable', fibre = 'fibre', power = 'power cable', copper = 'copper phone cable', trunk = 'trunking, capping and ducts', all = 'cable, trunking and ducts' })[what] or what
    if lib.alertDialog({ header = ('Remove %d piece(s)?'):format(#ids), content = ('Every bit of %s within %d m — %.0f m in total. Z in Remove mode puts it back.'):format(label, range, metres), centered = true, cancel = true }) == 'confirm' then
        local n = lib.callback.await('opslabs-towers:cable:deleteRuns', false, ids)
        lib.notify({ type = 'success', description = ('Removed %d piece(s)'):format(n or 0) })
        Wait(250)
    end
    menuBack()
end

--- core router switching: patch OLTs through to the national spine, uplink up / down
function SwitchingMenu(f)
    f = data.fixtures[f.id] or f
    local d = f.data or {}
    local st = lib.callback.await('opslabs-towers:exchange:status', false, f.id) or { power = {}, olts = {} }
    local patched = {}
    for _, id in ipairs(d.patched or {}) do patched[id] = true end
    local function save(newData)
        local r = lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = f.x, y = f.y, z = f.z, heading = f.heading, data = newData })
        if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
        Wait(300)
        SwitchingMenu(f)
    end
    local function list() local out = {} for id in pairs(patched) do out[#out + 1] = id end return out end
    local options = {
        { title = #st.power > 0 and ('Power OK · ' .. table.concat(st.power, ', ')) or 'No power in this exchange',
          description = #st.power > 0 and 'Rectifier / batteries / generator within ' .. math.floor((Config.Isp and Config.Isp.ExchangeRadius) or 60) .. ' m' or 'Place a DC rectifier rack, battery bank or generator nearby',
          icon = 'car-battery', iconColor = #st.power > 0 and '#30d158' or '#ff453a', readOnly = true },
        { title = 'National spine uplink: ' .. (d.uplink and 'UP' or 'DOWN'), description = d.uplink and 'Traffic leaves the exchange — click to take it down' or 'Click to bring the uplink up',
          icon = 'arrow-up-right-dots', iconColor = d.uplink and '#30d158' or '#ff453a', onSelect = function() save({ uplink = not d.uplink, patched = list() }) end },
    }
    if #st.olts == 0 then
        options[#options + 1] = { title = 'No OLTs in this exchange', description = 'Place an optical line terminal nearby to patch it', icon = 'circle-info', readOnly = true }
    end
    for _, o in ipairs(st.olts) do
        local on = patched[o.id]
        options[#options + 1] = { title = ('OLT #%d · %s'):format(o.id, on and 'patched' or 'not patched'),
            description = o.lit and 'Light on the fibre' or on and (d.uplink and #st.power > 0 and 'Waiting for the network…' or 'No light — uplink down or no power') or 'Click to patch it to this router',
            icon = on and 'link' or 'link-slash', iconColor = o.lit and '#30d158' or on and '#ff9f0a' or '#8e8e93', onSelect = function()
                patched[o.id] = not on or nil
                save({ uplink = d.uplink == true, patched = list() })
            end }
    end
    lib.registerContext({ id = 'cable_switching', title = 'Switching · core router #' .. f.id, menu = 'cable_fixture', onBack = function() fixtureMenu(f) end, options = options })
    lib.showContext('cable_switching')
end

CableMenu = function() MainMenu(true) end

RegisterCommand(CC.Command, function()
    if not lib.callback.await('opslabs-towers:cable:can', false) then
        return lib.notify({ type = 'error', description = 'You are not trained to run network cable' })
    end
    CableMenu()
end, false)

-- reachable from the /towers menu too
OpenCableMenu = function() CableMenu() end

--- cabling actions for the /towers sections; back = the menu to return to afterwards
CableActions = {}
local function wrap(fn) return function(back) ReturnMenu = back fn() end end
local function wrapMode(fn) return function(back) fn() if back then back() end end end
CableActions.placeBox = wrap(placeBox)
CableActions.pull = wrap(pullCable)
CableActions.trunking = wrap(layTrunking)
CableActions.power = wrap(RunPowerCable)
CableActions.copper = wrap(RunCopperCable)
CableActions.move = wrapMode(MoveMode)
CableActions.remove = wrapMode(RemoveMode)
CableActions.cut = wrapMode(function() CutMode() end)
CableActions.runs = function() RunsMenu() end
CableActions.removeRange = function(back) ReturnMenu = back RemoveInRange() end
CableActions.removeArea = function(back) AreaRemove() if back then back() end end
CableActions.boxes = function() BoxesMenu() end
CableActions.equipment = function(net) EquipmentNetMenu(net) end
CableActions.placeBuilding = function(e, back) placeEquipment(e, back) end
CableActions.fixture = function(f) fixtureMenu(f) end
CableActions.nearby = function() EquipmentMenu() end
CableActions.equipmentCat = function(net, cat) categoryMenu(net, cat) end
