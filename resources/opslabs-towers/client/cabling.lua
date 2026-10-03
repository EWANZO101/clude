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
local POLE_MODELS = { opslabs_pole_07m = true, opslabs_pole_10m = true, opslabs_pole_13m = true }
local function mm(v) return math.floor((v or 0) * 1000 + 0.5) end

local function runSig(r)
    local t = { r.kind, r.color or '', r.start_term and 1 or 0, r.end_term and 1 or 0 }
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
    r._c, r._r = c, rad + 1.0          -- + room for sagging spans
end

RegisterNetEvent('opslabs-towers:cabling', function(d)
    local boxes, runs, fixtures, newSigs = {}, {}, {}, {}
    local poleSig = {}
    for _, f in ipairs(d.fixtures or {}) do
        fixtures[f.id] = f
        if POLE_MODELS[f.model] then poleSig[#poleSig + 1] = ('%d:%d,%d'):format(f.id, mm(f.x), mm(f.y)) end
    end
    poleSig = table.concat(poleSig, ';')   -- pole kit's bands depend on which pole it sits on
    for id, f in pairs(fixtures) do
        newSigs['f' .. id] = ('%s|%d|%d|%d|%d|%s'):format(f.model, mm(f.x), mm(f.y), mm(f.z), mm(f.heading), POLE_MODELS[f.model] and '' or poleSig)
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
    for key in pairs(spawned) do
        if newSigs[key] ~= sigs[key] then DespawnKey(key) end   -- gone or changed: redraw just this one
    end
    sigs = newSigs
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

local function pt(p, lift) return vector3(p.x + p.nx * lift, p.y + p.ny * lift, p.z + p.nz * lift) end
local function nrm(p) return vector3(p.nx, p.ny, p.nz) end

-- per box type: prop, pull-out hole offset from the centre, height of the cable end
local BOXES = {
    cat6 = { model = 'opslabs_cat6_box', label = 'CAT6', ly = -0.10, top = 0.29 },
    fibre_black = { model = 'opslabs_fibre_box_black', label = 'Fibre (black)', ly = -0.11, top = 0.32 },
    fibre_yellow = { model = 'opslabs_fibre_box_yellow', label = 'Fibre (yellow)', ly = -0.088, top = 0.27 },
}
local function boxType(b) return BOXES[b.kind or 'cat6'] or BOXES.cat6 end

local function boxExit(b)
    local h = math.rad(b.heading or 0.0)
    local t = boxType(b)
    local lx, ly = 0.0, t.ly   -- the cable comes out of the hole near the front of the lid
    return { x = b.x + lx * math.cos(h) - ly * math.sin(h), y = b.y + lx * math.sin(h) + ly * math.cos(h), z = b.z + t.top, nx = 0.0, ny = 0.0, nz = 1.0 }
end
CableBoxExit = boxExit
CablingFixtures = function() return data.fixtures end

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
local function connectable(kind, model)
    if kind == 'fibre' then return FIBRE_KIT[model] == true end
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

function BuildRun(r, list)
    list = list or {}
    local pts = r.points or {}
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
        local col = r.color == 'yellow' and 'yellow' or 'black'
        local lift = col == 'yellow' and 0.0018 or 0.0028
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
local BAND_HEIGHTS = { opslabs_cbt = { 0.11, 0.25 }, opslabs_copper_dp = { 0.06, 0.20 }, opslabs_splice_enclosure = { 0.112, 0.392 } }
local POLE_HEIGHT = { opslabs_pole_07m = 7.0, opslabs_pole_10m = 10.0, opslabs_pole_13m = 13.0 }
PoleRadiusAt = function(H, z)
    local rb, rt = 0.115 + H * 0.002, 0.075
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, z / H))
end
local function poleUnder(f)
    for _, p in pairs(data.fixtures) do
        if POLE_HEIGHT[p.model] and #(vector2(p.x, p.y) - vector2(f.x, f.y)) < 0.35 and f.z > p.z and f.z < p.z + POLE_HEIGHT[p.model] then return p end
    end
end
function poleBands(f, list)
    local heights = BAND_HEIGHTS[f.model]
    local pole = heights and poleUnder(f)
    if not pole then return end
    for _, hz in ipairs(heights) do
        local z = f.z + hz
        local r = PoleRadiusAt(POLE_HEIGHT[pole.model], z - pole.z)
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

-- stream runs and boxes in / out around the player
CreateThread(function()
    while true do
        Wait(1500)
        local pos = GetEntityCoords(PlayerPedId())
        local want = {}
        for id, b in pairs(data.boxes) do
            if #(pos - vector3(b.x, b.y, b.z)) < CC.DrawDistance then want['b' .. id] = b end
        end
        for id, f in pairs(data.fixtures) do
            if #(pos - vector3(f.x, f.y, f.z)) < CC.DrawDistance * 3 then want['f' .. id] = f end
        end
        for id, r in pairs(data.runs) do
            if nearRun(r, pos, CC.DrawDistance) then want['r' .. id] = r end
        end
        for key in pairs(spawned) do if not want[key] then DespawnKey(key) end end
        for key, v in pairs(want) do
            if not spawned[key] then
                local list = {}
                if key:sub(1, 1) == 'f' then
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
                    local h = model(boxType(v).model)
                    if h then
                        local e = CreateObjectNoOffset(h, v.x, v.y, v.z, false, false, false)
                        SetEntityHeading(e, v.heading or 0.0)
                        FreezeEntityPosition(e, true)
                        list[1] = e
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
    for _, f in pairs(data.fixtures) do
        local H = POLE_HEIGHT[f.model]
        if H then
            local d, cp = segRay(vector3(f.x, f.y, f.z), vector3(f.x, f.y, f.z + H), camPos, u, 40.0)
            if d < 0.45 and (not bd or d < bd) then best, bd, bz = f, d, cp.z end
        end
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
local function layRun(kind, color, box)
    local pts, preview = {}, {}
    local maxLen = kind == 'cable' and math.min(CC.MaxRunLength, box.remaining) or kind == 'fibre' and math.min(CC.MaxFibreLength or 1000, box.remaining) or 200.0
    if kind ~= 'trunk' then pts[1] = boxExit(box) end
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
    local function clearGhost()
        for _, e in ipairs(ghost) do if DoesEntityExist(e) then DeleteEntity(e) end end
        ghost = {}
    end
    local sf = PlaceHud.buttons(kind == 'trunk'
        and { { 'Fix point', 24 }, { 'Finish', 191 }, { 'Undo', { 25, 177 } }, { 'Straight line', 21 }, { 'Cancel', 200 } }
        or { { 'Fix point', 24 }, { 'Finish & connect', 191 }, { 'Undo', { 25, 177 } }, { 'Straight line', 21 }, { 'Cancel', 200 } })
    local title = kind == 'cable' and 'Pulling CAT6' or kind == 'fibre' and ('Pulling fibre · ' .. color) or ('Fitting trunking · ' .. color)
    local accent = kind == 'fibre' and (color == 'yellow' and { 255, 214, 10 } or { 120, 120, 125 }) or kind == 'trunk' and { 48, 209, 88 } or { 10, 132, 255 }
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 44, 140, 141, 142, 177, 191, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local at, normal, ent = aim(nil, 40.0)
        local target, tgtTower, tgtFixture
        local straight, poleHint
        -- a pole near the crosshair: clamp to it on the side the cable comes from (the ring head near the top)
        local pole, pz = pickPole()
        if pole and (not at or #(vector3(pole.x, pole.y, at.z) - at) < 0.6 or (at and #(at - GetGameplayCamCoord()) > #(vector3(pole.x, pole.y, pz) - GetGameplayCamCoord()))) then
            local H = POLE_HEIGHT[pole.model]
            local ringHead = pz > pole.z + H - 1.3
            local z = ringHead and (pole.z + H - 0.2) or math.max(pole.z + 0.3, math.min(pole.z + H - 0.2, pz))
            local from = #pts > 0 and vector3(pts[#pts].x, pts[#pts].y, 0.0) or vector3(GetGameplayCamCoord().x, GetGameplayCamCoord().y, 0.0)
            local dir = from - vector3(pole.x, pole.y, 0.0)
            dir = #dir > 0.01 and dir / #dir or vector3(0.0, -1.0, 0.0)
            local rr = PoleRadiusAt(H, z - pole.z) + 0.012
            at, normal, ent = vector3(pole.x + dir.x * rr, pole.y + dir.y * rr, z), dir, nil
            poleHint = ringHead and 'clamped to the pole’s ring head' or ('on the pole at %.1f m'):format(z - pole.z)
        end
        if at and not poleHint and #(at - GetGameplayCamCoord()) > 14.0 then at = nil end   -- far points only for poles
        if at then
            target = { x = at.x, y = at.y, z = at.z, nx = normal.x, ny = normal.y, nz = normal.z, p = poleHint and pole.id or nil }
            tgtTower = towerOfEntity(ent)
            if not tgtTower and kind ~= 'trunk' then
                if ent and ent ~= 0 then
                    for id, f in pairs(data.fixtures) do
                        local sp = spawned['f' .. id]
                        if sp and sp[1] == ent and connectable(kind, f.model) then tgtFixture = id break end
                    end
                end
                -- pole kit has no collision: aiming within ~40 cm of it counts too
                tgtFixture = tgtFixture or nearestFixtureFor(kind, at, 0.45)
            end
            if kind ~= 'trunk' and not poleHint then
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
        -- the cable trailing from your hand to the last point (you're pulling it)
        if kind ~= 'trunk' and #pts > 0 then
            local hand = GetPedBoneCoords(PlayerPedId(), 57005, 0.0, 0.0, 0.0)
            local l = pts[#pts]
            if color == 'yellow' then DrawLine(hand.x, hand.y, hand.z, l.x, l.y, l.z, 230, 190, 30, 255)
            else DrawLine(hand.x, hand.y, hand.z, l.x, l.y, l.z, 20, 20, 22, 255) end
        end
        local extra = (target and #pts > 0) and seglen(pts[#pts], target) or 0.0
        local over = kind ~= 'trunk' and length + extra > maxLen
        local hint = (tgtTower or tgtFixture) and kind ~= 'trunk' and ('Enter to connect to ' .. (towerName(tgtTower) or fixtureLabel(tgtFixture) or 'this device'))
            or (kind ~= 'trunk' and target and target.t and 'Inside trunking')
            or poleHint
            or (straight == 'plumb' and 'straight up / down') or (straight == 'level' and 'level')
            or (#pts == 0 and 'Aim at the floor, a wall or the ceiling')
        PlaceHud.draw(sf, title, kind == 'trunk' and ('%.1f m%s'):format(length + extra, hint and ('   ·   ' .. hint) or '')
            or ('%.1f / %.0f m%s'):format(length + extra, maxLen, over and '   ·   not enough cable' or hint and ('   ·   ' .. hint) or ''), accent, over)
        if target and IsDisabledControlJustPressed(0, 24) then
            if #pts > 0 and length + extra > maxLen then
                lib.notify({ type = 'error', description = kind ~= 'trunk' and ('Not enough cable — %.0f m max for this run'):format(maxLen) or 'Too long' })
            elseif #pts == 0 or extra > 0.03 then
                pts[#pts + 1] = target
                if #pts > 1 then length = length + extra end
                clearGhost() ghostAt = nil
                rebuildLast()
                PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
            end
        end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 25) then
            local minPts = kind ~= 'trunk' and 1 or 0
            if #pts > minPts then
                if #pts > 1 then length = length - seglen(pts[#pts - 1], pts[#pts]) end
                for _, e in ipairs(preview[#pts] or {}) do if DoesEntityExist(e) then DeleteEntity(e) end end
                preview[#pts] = nil
                pts[#pts] = nil
            end
        end
        if IsDisabledControlJustPressed(0, 191) then
            if target and (tgtTower or tgtFixture) and kind ~= 'trunk' and (#pts == 0 or seglen(pts[#pts], target) > 0.03) and length + extra <= maxLen then
                pts[#pts + 1] = target
                length = length + extra
            end
            local needed = kind ~= 'trunk' and 3 or 2
            if #pts >= needed then
                result = pts
                endTower = kind ~= 'trunk' and (tgtTower or nearestTowerProp(vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z), 0.6)) or nil
                endFixture = kind ~= 'trunk' and not endTower and (tgtFixture or nearestFixtureFor(kind, vector3(pts[#pts].x, pts[#pts].y, pts[#pts].z), 0.6)) or nil
                break
            end
            lib.notify({ type = 'inform', description = kind ~= 'trunk' and 'Fix the cable to at least two points first' or 'Place at least two points' })
        end
        if IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    clearGhost()
    for _, list in pairs(preview) do for _, e in ipairs(list) do if DoesEntityExist(e) then DeleteEntity(e) end end end
    return result, endTower, endFixture
end

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
            lib.registerContext({ id = 'cable_wires', title = 'Arrange the wires', options = options, onExit = function() p:resolve(-1) end })
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

function TerminateEnd(run, which, towerId, fixtureId)
    if run.kind == 'fibre' then return spliceFibre(run, which, towerId, fixtureId) end
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
    local done = r.kind == 'fibre' and 'spliced' or 'terminated'
    local options = {
        { title = ('%s · %.1f m'):format(r.kind == 'trunk' and ('Trunking (' .. r.color .. ')') or r.kind == 'fibre' and ('Fibre (' .. r.color .. ')') or 'CAT6 cable', r.length or 0),
          description = r.kind ~= 'trunk' and ('Start: %s · End: %s%s'):format(
            r.box_id and 'still on the box' or (r.start_term and (done .. (endName(r, 'start') and (' → ' .. endName(r, 'start')) or '')) or 'bare end'),
            r.end_term and (done .. (endName(r, 'end') and (' → ' .. endName(r, 'end')) or '')) or 'bare end',
            '') or nil, icon = r.kind == 'trunk' and 'grip-lines' or 'ethernet', readOnly = true },
    }
    local verb = r.kind == 'fibre' and 'Splice' or 'Terminate'
    if r.kind ~= 'trunk' then
        if r.box_id then
            options[#options + 1] = { title = 'Cut from the box', description = 'Frees the start of the cable so you can terminate it', icon = 'scissors', onSelect = function()
                local res = lib.callback.await('opslabs-towers:cable:cut', false, r.id)
                if res and res.ok then lib.notify({ type = 'success', description = 'Cable cut from the box' }) Wait(250) end
                RunMenu(r)
            end }
        elseif not r.start_term then
            local tw = a and nearestTowerProp(vector3(a.x, a.y, a.z), 1.2)
            local fx = a and not tw and nearestFixtureFor(r.kind, vector3(a.x, a.y, a.z), 1.5)
            local into = towerName(tw) or fixtureLabel(fx)
            options[#options + 1] = { title = verb .. ' the start', description = not nearStart and 'Walk to the start of the cable first' or into and ('Connects to ' .. into) or 'Nothing to plug into here — it will just be finished off',
                icon = 'plug', disabled = not nearStart, onSelect = function()
                TerminateEnd(r, 'start', tw, fx)
                Wait(250) RunMenu(r)
            end }
        end
        if not r.end_term then
            local tw = r.end_tower or (z and nearestTowerProp(vector3(z.x, z.y, z.z), 1.2))
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
    lib.registerContext({ id = 'cable_run', title = r.kind == 'trunk' and 'Trunking' or r.kind == 'fibre' and 'Fibre' or 'Cable', menu = 'cable_runs', onBack = function() RunsMenu() end, options = options })
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
        local what = r and (r.kind == 'trunk' and ('Trunking (' .. r.color .. ')') or r.kind == 'fibre' and ('Fibre (' .. r.color .. ')') or 'CAT6')
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
                    lib.notify({ type = 'success', description = r.kind == 'trunk' and 'Trunking cut in two' or ('Cut — #%d and #%d now have bare ends to %s'):format(res.a.id, res.b.id, r.kind == 'fibre' and 'splice' or 'terminate') })
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

local function runLabel(r)
    return r.kind == 'trunk' and ('Trunking (' .. r.color .. ')') or r.kind == 'fibre' and ('Fibre (' .. r.color .. ')') or 'CAT6'
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
    options[#options + 1] = { title = ('Remove all trunking nearby (%d)'):format(#trunks), icon = 'grip-lines', iconColor = '#ff5a5f', disabled = #trunks == 0,
        onSelect = function() bulk(trunks, 'Remove all trunking within 60 m?', 'Cable inside it stays on the wall.') end }
    options[#options + 1] = { title = ('Remove all cable & fibre nearby (%d)'):format(#cablesIds), icon = 'ethernet', iconColor = '#ff5a5f', disabled = #cablesIds == 0,
        onSelect = function() bulk(cablesIds, 'Remove all cable and fibre within 60 m?', 'Devices fed by it lose their uplink.') end }
    for _, e in ipairs(list) do
        local r = e.r
        local state = r.kind == 'trunk' and r.color or (r.start_term and r.end_term and 'connected both ends' or r.box_id and 'on the box' or 'needs terminating')
        options[#options + 1] = { title = ('%s #%d · %.1f m'):format(r.kind == 'trunk' and 'Trunking' or r.kind == 'fibre' and ('Fibre ' .. r.color) or 'CAT6', r.id, r.length or 0),
            description = ('%s · %dm away'):format(state, math.floor(e.d)), icon = r.kind == 'trunk' and 'grip-lines' or 'ethernet',
            iconColor = r.kind ~= 'trunk' and (r.start_term and r.end_term and '#30d158' or '#ff9f0a') or nil, arrow = true, onSelect = function() RunMenu(r) end }
    end
    if #list == 0 then options[#options + 1] = { title = 'No cables nearby', readOnly = true } end
    lib.registerContext({ id = 'cable_runs', title = 'Nearby cables & trunking', menu = 'cable_main', onBack = function() CableMenu() end, options = options })
    lib.showContext('cable_runs')
end

local function pullCable()
    local box = nearestBox(CC.PullDistance)
    if not box then lib.notify({ type = 'error', description = 'Stand next to a cable box to pull cable from it' }) return CableMenu() end
    if box.remaining < 1 then lib.notify({ type = 'error', description = 'This box is empty' }) return CableMenu() end
    local fibre = (box.kind or 'cat6') ~= 'cat6'
    local kind, color = fibre and 'fibre' or 'cable', fibre and box.kind:match('^fibre_(%a+)$') or 'black'
    local pts, endTower, endFixture = layRun(kind, color, box)
    if not pts then return CableMenu() end
    local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = kind, color = color, points = pts, box_id = box.id, end_tower = endTower, end_fixture = endFixture })
    if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) return CableMenu() end
    Wait(250)
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
        opts[#opts + 1] = { value = 'fibre_' .. c, label = ('Fibre %s · %d m'):format(c == 'yellow' and 'yellow (indoor patch)' or 'black (outdoor dropwire)', (CC.FibreBoxLength or {})[c] or 0) }
    end
    local v = lib.inputDialog('Place a cable box', { { type = 'select', label = 'Box', options = opts, default = 'cat6', required = true } })
    if not v then return CableMenu() end
    local t = BOXES[v[1]]
    local spot = PlacementMode('box', t.model, 1.0, nil, 'Placing ' .. t.label .. ' box')
    if spot then
        spot.kind = v[1]
        local r = lib.callback.await('opslabs-towers:cable:placeBox', false, spot)
        if r and r.ok then lib.notify({ type = 'success', description = t.label .. ' box placed' }) Wait(250)
        else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    CableMenu()
end

local function layTrunking()
    local opts = {}
    for _, c in ipairs(CC.TrunkColors) do opts[#opts + 1] = { value = c, label = c:sub(1, 1):upper() .. c:sub(2) } end
    local v = lib.inputDialog('Trunking', { { type = 'select', label = 'Colour', options = opts, default = CC.TrunkColors[1], required = true } })
    if not v then return CableMenu() end
    local pts = layRun('trunk', v[1])
    if pts then
        local res = lib.callback.await('opslabs-towers:cable:saveRun', false, { kind = 'trunk', color = v[1], points = pts })
        if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
        else lib.notify({ type = 'success', description = ('%.1f m of %s trunking fitted'):format(res.run.length, v[1]) }) end
        Wait(250)
    end
    CableMenu()
end

local EquipmentMenu
local function fixtureMenu(f)
    f = data.fixtures[f.id] or f
    local label = f.model
    for _, e in ipairs(CC.Equipment) do if e.model == f.model then label = e.label end end
    local options = {
        { title = ('#%d · placed by %s'):format(f.id, f.created_by or '?'), icon = 'tower-broadcast', readOnly = true },
    }
    if f.model == ONT_MODEL then
        options[#options + 1] = { title = 'Internet service', description = 'Provider, plan, suspend / resume', icon = 'wifi', iconColor = '#30d158', arrow = true,
            onSelect = function() IspMenu(f, function() fixtureMenu(f) end) end }
    end
    options[#options + 1] = { title = 'Move (aim & place)', icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function()
        local spot = PlacementMode('fixture', f.model, 1.0, f.heading, 'Moving ' .. label)
        if spot then lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading }) Wait(250) end
        fixtureMenu(f)
    end }
    options[#options + 1] = { title = 'Teleport here', icon = 'location-arrow', onSelect = function() SetEntityCoords(PlayerPedId(), f.x, f.y - 1.0, f.z + 0.5, false, false, false, false) fixtureMenu(f) end }
    options[#options + 1] = { title = 'Remove', icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
        if lib.alertDialog({ header = 'Remove ' .. label .. '?', centered = true, cancel = true }) == 'confirm' then
            lib.callback.await('opslabs-towers:fixture:delete', false, f.id) Wait(250)
            return EquipmentMenu()
        end
        fixtureMenu(f)
    end }
    lib.registerContext({ id = 'cable_fixture', title = label, menu = 'cable_equipment', onBack = function() EquipmentMenu() end, options = options })
    lib.showContext('cable_fixture')
end

EquipmentMenu = function()
    local options = {}
    for _, e in ipairs(CC.Equipment) do
        if IsModelInCdimage(joaat(e.model)) then
            options[#options + 1] = { title = 'Place: ' .. e.label, icon = 'plus', onSelect = function()
                local spot = PlacementMode('fixture', e.model, 1.0, nil, 'Placing ' .. e.label)
                if spot then
                    local r = lib.callback.await('opslabs-towers:fixture:save', false, { model = e.model, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
                    if r and r.ok then lib.notify({ type = 'success', description = e.label .. ' placed' }) Wait(250) end
                end
                EquipmentMenu()
            end }
        end
    end
    local pos = GetEntityCoords(PlayerPedId())
    local near = {}
    for _, f in pairs(data.fixtures) do
        local d = #(pos - vector3(f.x, f.y, f.z))
        if d < 60 then near[#near + 1] = { f = f, d = d } end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#near, 20) do
        local f = near[i].f
        local label = f.model
        for _, e in ipairs(CC.Equipment) do if e.model == f.model then label = e.label end end
        options[#options + 1] = { title = label, description = ('%dm away'):format(math.floor(near[i].d)), icon = 'location-dot', arrow = true, onSelect = function() fixtureMenu(f) end }
    end
    if #options == 0 then options[1] = { title = 'Start opslabs-props to place equipment', readOnly = true } end
    lib.registerContext({ id = 'cable_equipment', title = 'Telecom equipment', menu = 'cable_main', onBack = function() CableMenu() end, options = options })
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

CableMenu = function()
    local box, bd = nearestBox(25.0)
    local cables, trunks = 0, 0
    for _, r in pairs(data.runs) do if r.kind == 'trunk' then trunks = trunks + 1 else cables = cables + 1 end end
    lib.registerContext({
        id = 'cable_main', title = 'Network cabling',
        options = {
            { title = box and ('Nearest box: %s · %.0f m left'):format(boxType(box).label, box.remaining) or 'No cable box nearby', description = box and ('%.0f m away'):format(bd) or 'Place a CAT6 or fibre box first', icon = 'box', readOnly = true },
            { title = 'Place a cable box', description = ('CAT6 %d m · fibre black %d m · fibre yellow %d m'):format(CC.BoxLength, (CC.FibreBoxLength or {}).black or 0, (CC.FibreBoxLength or {}).yellow or 0), icon = 'box-open', onSelect = placeBox },
            { title = 'Pull cable from the nearest box', description = ('Stand within %.0f m of a CAT6 or fibre box, then fix the cable along floors, walls or ceilings'):format(CC.PullDistance), icon = 'ethernet', iconColor = '#0a84ff', onSelect = pullCable },
            { title = 'Fit trunking', description = 'White, black or blue — cables run through it out of sight', icon = 'grip-lines', onSelect = layTrunking },
            { title = 'Place an extension ladder', description = 'Stand it against a wall or pole, extend it, climb it (also /' .. (CC.LadderCommand or 'ladder') .. ')', icon = 'stairs', onSelect = function() if PlaceLadder then PlaceLadder() end end },
            { title = 'Telecom equipment', description = 'Poles 7/10/13 m, CBT, DP, splice enclosure, cabinets, covers, CSP, ONT', icon = 'tower-broadcast', arrow = true, onSelect = function() EquipmentMenu() end },
            { title = 'Move cable, trunking or a box', description = 'Aim and click · reshape a route or carry a box somewhere else', icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function() MoveMode() CableMenu() end },
            { title = 'Remove cable, trunking or a box', description = 'Aim and hold · Z puts back what you removed (bulk options under Nearby)', icon = 'trash-can', iconColor = '#ff453a', onSelect = function() RemoveMode() CableMenu() end },
            { title = 'Cut a cable', description = 'Aim at any CAT6, fibre or trunking and cut it anywhere along the line', icon = 'scissors', iconColor = '#ff453a', onSelect = function() CutMode() CableMenu() end },
            { title = ('Nearby cables & trunking (%d / %d)'):format(cables, trunks), icon = 'list', arrow = true, onSelect = function() RunsMenu() end },
            { title = ('Cable boxes (%d nearby)'):format(nearbyBoxCount()), description = 'See, teleport to or remove boxes', icon = 'boxes-stacked', arrow = true, onSelect = function() BoxesMenu() end },
        },
    })
    lib.showContext('cable_main')
end

RegisterCommand(CC.Command, function()
    if not lib.callback.await('opslabs-towers:cable:can', false) then
        return lib.notify({ type = 'error', description = 'You are not trained to run network cable' })
    end
    CableMenu()
end, false)

-- reachable from the /towers menu too
OpenCableMenu = function() CableMenu() end
