-- San Andreas Power & Light · Line Tool + LineSense pole monitors (server/powerline.lua, server/grid.lua GridPoles)
--   · every power pole gets a LineSense monitor strapped to it (lit / dark with the line) and a live data panel when
--     you're close: location, 11 kV / LV, power and current through the pole, feeder, substation, recloser,
--     transformers, jumpers — the same data OPS Hub → Grid control shows for the pole
--   · the Line Tool (insulated hot stick): aim at power kit or a conductor and work on it — see server/powerline.lua

local PL = Config.PowerLine or {}
if PL.Enabled == false then return end
local MON = PL.Monitor or {}
local CG, CC = Config.Grid or {}, Config.Cabling or {}
local LABEL = CC.PowerLabels or {}
local HEIGHTS = CC.PoleHeights or {}

local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function isPole(m) return m and m:find('^opslabs_power_pole') ~= nil end
local function pos() return GetEntityCoords(PlayerPedId()) end
local function h2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

--- a point in a fixture's own frame, in the world
local function worldOf(f, x, y, z)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return vector3(f.x + x * c - y * s, f.y + x * s + y * c, f.z + z)
end

---------------------------------------------------------------------------
-- live pole data (asked for the poles round you)
---------------------------------------------------------------------------

local Poles = {}          -- pole id -> row from GridPoles
local sentStreet = {}

local function streetAt(x, y, z)
    local a, b = GetStreetNameAtCoord(x, y, z)
    local s = GetStreetNameFromHashKey(a)
    local c = b ~= 0 and GetStreetNameFromHashKey(b) or ''
    if c ~= '' and c ~= s then s = s .. ' / ' .. c end
    return s
end

CreateThread(function()
    while true do
        Wait(MON.Refresh or 3000)
        if MON.Enabled ~= false then
            local me, ids = pos(), {}
            for id, f in pairs(fixtures()) do
                if isPole(f.model) and h2(me, f) <= 70.0 and #ids < 40 then ids[#ids + 1] = id end
            end
            if #ids > 0 then
                local rows = lib.callback.await('opslabs-towers:grid:poles', false, ids) or {}
                local seen = {}
                for _, r in ipairs(rows) do
                    Poles[r.id] = r
                    seen[r.id] = true
                    if not r.street and not sentStreet[r.id] then
                        sentStreet[r.id] = true
                        local s = streetAt(r.x, r.y, r.z)
                        if s ~= '' then TriggerServerEvent('opslabs-towers:grid:poleStreet', r.id, s) r.street = s end
                    end
                end
                for id in pairs(Poles) do if not seen[id] and not fixtures()[id] then Poles[id] = nil end end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- the LineSense monitor on every pole
---------------------------------------------------------------------------

local monitors = {}       -- pole id -> { ent, model }
local function monitorAt(f)
    return worldOf(f, 0.0, MON.Radius or 0.128, MON.Height or 3.0), (f.heading or 0.0) + 180.0
end

local function dropMonitor(id)
    local m = monitors[id]
    if m and DoesEntityExist(m.ent) then DeleteEntity(m.ent) end
    monitors[id] = nil
end

CreateThread(function()
    if MON.Enabled == false then return end
    local onModel, offModel = joaat(MON.Model or 'opslabs_pole_monitor'), joaat(MON.Off or 'opslabs_pole_monitor_off')
    if not IsModelInCdimage(onModel) then return print('^3[opslabs-towers] LineSense monitor model missing (opslabs-props) — poles show their data without it^7') end
    while true do
        local me = pos()
        local fx = fixtures()
        for id, f in pairs(fx) do
            if isPole(f.model) then
                local d = h2(me, f)
                if d <= (MON.Stream or 90.0) then
                    local row = Poles[id]
                    local want = (row and row.live) and onModel or offModel
                    local m = monitors[id]
                    if not m or m.model ~= want or not DoesEntityExist(m.ent) or m.x ~= f.x or m.y ~= f.y then
                        dropMonitor(id)
                        if lib.requestModel(want, 3000) then
                            local p, hd = monitorAt(f)
                            local e = CreateObjectNoOffset(want, p.x, p.y, p.z, false, false, false)
                            SetEntityHeading(e, hd % 360.0)
                            SetEntityCoordsNoOffset(e, p.x, p.y, p.z, false, false, false)
                            FreezeEntityPosition(e, true)
                            SetEntityCollision(e, false, false)
                            monitors[id] = { ent = e, model = want, x = f.x, y = f.y }
                        end
                    end
                elseif d > (MON.Stream or 90.0) + 15.0 then
                    dropMonitor(id)
                end
            end
        end
        for id in pairs(monitors) do if not fx[id] then dropMonitor(id) end end
        Wait(1500)
    end
end)

---------------------------------------------------------------------------
-- the live data panel beside the monitor
---------------------------------------------------------------------------

local WHITE, GREEN, RED, AMBER, GREY = { 235, 240, 245 }, { 52, 211, 108 }, { 255, 77, 94 }, { 245, 165, 36 }, { 150, 160, 172 }

local function panel(at, lines)
    SetDrawOrigin(at.x, at.y, at.z, 0)
    local lh = 0.021
    local hgt = lh * #lines + 0.014
    DrawRect(0.0, hgt / 2 - 0.007, 0.205, hgt, 10, 14, 20, 200)
    DrawRect(0.0, -0.007, 0.205, 0.003, 255, 204, 0, 230)
    for i, l in ipairs(lines) do
        local c = l[2] or WHITE
        SetTextFont(4)
        SetTextScale(0.0, l[3] or 0.29)
        SetTextColour(c[1], c[2], c[3], 255)
        SetTextCentre(true)
        SetTextOutline()
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(l[1])
        EndTextCommandDisplayText(0.0, (i - 1) * lh - 0.002)
    end
    ClearDrawOrigin()
end

local function mwText(mw) return mw >= 1 and ('%.2f MW'):format(mw) or ('%.0f kW'):format(mw * 1000) end

function PoleLines(r, f)
    local lines = { { ('SAPL LineSense · %s'):format(r.name or ('Pole #' .. r.id)), { 255, 204, 0 }, 0.31 } }
    lines[#lines + 1] = { ('%s · %.0f, %.0f'):format(r.street or streetAt(f.x, f.y, f.z), f.x, f.y), GREY }
    if r.hv then
        lines[#lines + 1] = { ('11 kV  LIVE  ·  %s  ·  %d A'):format(mwText(r.mw or 0), math.floor((r.amps or 0) + 0.5)), GREEN, 0.32 }
    elseif r.lv then
        lines[#lines + 1] = { 'LV 230 / 400 V  LIVE', GREEN, 0.32 }
    else
        lines[#lines + 1] = { (r.hvRuns or 0) + (r.lvRuns or 0) > 0 and 'DEAD — no supply' or 'NOT CONNECTED', RED, 0.32 }
    end
    if r.feederName then lines[#lines + 1] = { ('%s  ←  %s'):format(r.feederName, r.subName or 'substation'), WHITE } end
    local kit = {}
    if r.recloser then kit[#kit + 1] = 'Recloser ' .. (r.recloser.lockout and 'LOCKED OUT' or r.recloser.closed and 'closed' or 'OPEN') end
    if (r.tx or 0) > 0 then kit[#kit + 1] = ('Transformer %d/%d live%s'):format(r.txLive or 0, r.tx, (r.kw or 0) > 0 and (' · ' .. mwText((r.kw or 0) / 1000) .. ' to LV') or '') end
    kit[#kit + 1] = ('Conductors %d HV · %d LV'):format(r.hvRuns or 0, r.lvRuns or 0)
    lines[#lines + 1] = { table.concat(kit, '  ·  '), WHITE }
    local warn = {}
    if (r.open or 0) > 0 then warn[#warn + 1] = ('%d JUMPER(S) OPEN'):format(r.open) end
    if r.fusesOut then warn[#warn + 1] = 'FUSES OUT' end
    if r.earthed then warn[#warn + 1] = 'EARTHED' end
    if r.fault then warn[#warn + 1] = 'LINE FAULT' end
    if #warn > 0 then lines[#lines + 1] = { table.concat(warn, '  ·  '), AMBER } end
    return lines
end

CreateThread(function()
    while true do
        local wait = 500
        if MON.Enabled ~= false then
            local me = pos()
            local best, bd
            for id, r in pairs(Poles) do
                local f = fixtures()[id]
                if f then
                    local d = h2(me, f)
                    if d <= (MON.PanelDistance or 9.0) and (not bd or d < bd) then best, bd = f, d end
                end
            end
            if best and Poles[best.id] then
                wait = 0
                local p = monitorAt(best)
                panel(vector3(p.x, p.y, p.z + 0.55), PoleLines(Poles[best.id], best))
            end
        end
        Wait(wait)
    end
end)

---------------------------------------------------------------------------
-- Line Tool
---------------------------------------------------------------------------

local STICK = { model = 'opslabs_tool_hotstick', bone = 57005, pos = vec3(0.1, 0.02, -0.03), rot = vec3(-80.0, 0.0, 0.0) }
local REACH_ANIM = { dict = 'amb@prop_human_movie_bulb@base', clip = 'base' }
CreateThread(function() if not IsModelInCdimage(joaat(STICK.model)) then STICK.model = 'prop_tool_broom' end end)

local function stickWork(label, ms)
    return lib.progressBar({ duration = ms, label = label, canCancel = true, disable = { move = true, combat = true, car = true },
        anim = REACH_ANIM, prop = STICK })
end

local KINDS = {}           -- model -> true for power kit the tool works on
for _, m in ipairs({ CG.Transformer or 'opslabs_power_transformer', CG.Recloser or 'opslabs_power_recloser', (CG.Pylon or {}).model, (CG.Station or {}).model,
    (CG.Wind or {}).model, (CG.Substation or {}).model, 'opslabs_power_cutouts', 'opslabs_power_pothead', 'opslabs_power_lv_connectors' }) do
    if m then KINDS[m] = true end
end
for m in pairs(CG.SubSites or {}) do KINDS[m] = true end
for m in pairs(((CG.SubKit or {}).parts) or {}) do KINDS[m] = true end
for m in pairs((Config.Mains or {}).Supply or {}) do KINDS[m] = true end
for m in pairs((Config.Mains or {}).Wired or {}) do KINDS[m] = true end
KINDS[(Config.Mains or {}).ConsumerUnit or 'opslabs_mains_cu'] = true
KINDS[(Config.Mains or {}).Generator or 'opslabs_mains_generator'] = true
local BIG = { [(CG.Station or {}).model or '-'] = 18.0, [(CG.Substation or {}).model or '-'] = 10.0, [(CG.Wind or {}).model or '-'] = 4.0 }
for m in pairs(CG.SubSites or {}) do BIG[m] = 6.0 end
local function isKit(m) return m and (isPole(m) or KINDS[m] == true) end

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
--- distance from a ray to segment a-b, and how far along the ray
local function raySeg(q0, u, a, b)
    local d, r = b - a, a - q0
    local A, B, Cc, F = dot(d, d), dot(d, u), dot(d, r), dot(u, r)
    local den = A - B * B
    local t = (A > 1e-9 and den > 1e-9) and math.max(0.0, math.min(1.0, (B * F - Cc) / den)) or 0.0
    local s = math.max(0.0, B * t + F)
    t = A > 1e-9 and math.max(0.0, math.min(1.0, (B * s - Cc) / A)) or 0.0
    return #((a + d * t) - (q0 + u * s)), s
end

--- the power kit under the crosshair (poles by their whole height), else the nearest within reach
local function pickKit(maxS, filter)
    local cam, u = GetGameplayCamCoord(), rotToDir(GetGameplayCamRot(2))
    local best, bd, bs
    for _, f in pairs(fixtures()) do
        if isKit(f.model) and (not filter or filter(f)) and #(cam - vector3(f.x, f.y, f.z)) < (maxS or 40.0) + 30.0 then
            local a = vector3(f.x, f.y, f.z)
            local H = HEIGHTS[f.model] or 1.0
            local d, s = raySeg(cam, u, a, a + vector3(0.0, 0.0, H))
            local tol = (BIG[f.model] or (isPole(f.model) and 0.5 or 0.45)) + s * 0.01
            if s <= (maxS or 40.0) and d < tol and (not bd or d / tol < bd) then best, bd, bs = f, d / tol, s end
        end
    end
    if best then return best, bs end
    local me, nd = pos(), nil
    for _, f in pairs(fixtures()) do
        if isKit(f.model) and (not filter or filter(f)) then
            local d = #(me - vector3(f.x, f.y, f.z))
            if isPole(f.model) then d = h2(me, f) end
            if d <= (PL.Range or 7.0) and (not nd or d < nd) then best, nd = f, d end
        end
    end
    return best, nd
end

local function kitName(f) return FixtureLabel and FixtureLabel(f.model) or f.model end

--- where a conductor end goes on a kit (insulator on a pole, pylon arm tip, kit terminals)
local function attachPoint(f, color, toward)
    local H = HEIGHTS[f.model]
    if isPole(f.model) and H then
        if color == 'hv' then return worldOf(f, 0.0, 0.0, H - 0.27) end
        return worldOf(f, 0.0, -0.22, H - 1.75)
    end
    local arm = (CC.PylonArm or {})[f.model]
    if arm then
        local a, b = worldOf(f, arm.x, 0.0, arm.z), worldOf(f, -arm.x, 0.0, arm.z)
        if toward and #(b - toward) < #(a - toward) then return b end
        return a
    end
    if BIG[f.model] then return vector3(f.x, f.y, f.z + 2.0) end
    return vector3(f.x, f.y, f.z + 0.15)
end

--- "show me where": waypoint + a tall marker for a while
local whereMarks = {}
local function showWhere(fix)
    SetNewWaypoint(fix.x + 0.0, fix.y + 0.0)
    whereMarks[#whereMarks + 1] = { x = fix.x, y = fix.y, z = fix.z, label = fix.label, untilT = GetGameTimer() + (PL.WhereSeconds or 120) * 1000 }
    lib.notify({ type = 'inform', title = 'Line Tool', description = (fix.label or 'Marked') .. ' — GPS set', duration = 7000 })
end
CreateThread(function()
    while true do
        local wait = 1000
        if #whereMarks > 0 then
            wait = 0
            local now = GetGameTimer()
            for i = #whereMarks, 1, -1 do
                local m = whereMarks[i]
                if now > m.untilT then table.remove(whereMarks, i) else
                    DrawMarker(1, m.x, m.y, m.z - 0.5, 0, 0, 0, 0, 0, 0, 1.2, 1.2, 30.0, 255, 204, 0, 70, false, false, 2, false, nil, nil, false)
                    DrawMarker(2, m.x, m.y, m.z + 3.0, 0, 0, 0, 180.0, 0, 0, 0.8, 0.8, 0.8, 255, 204, 0, 220, true, true, 2, false, nil, nil, false)
                    if #(pos() - vector3(m.x, m.y, m.z)) < 60.0 then panel(vector3(m.x, m.y, m.z + 4.2), { { m.label or 'Here', { 255, 204, 0 }, 0.3 } }) end
                end
            end
        end
        Wait(wait)
    end
end)

local function gloveWarning(live)
    if live and PpeWorn and not PpeWorn('gloves') then
        lib.notify({ type = 'warning', title = 'Line Tool', description = 'Live line — put your dielectric gloves on (tool kit → electrical tools)' })
    end
end

local inspectKit, runMenu, aimLoop

--- aim at a kit to put a conductor end on → kit or nil
local function pickTarget(title, filter)
    local picked = nil
    lib.showTextUI(('**%s**  \n[E] Pick  ·  [Backspace] Cancel'):format(title), { position = 'top-center', icon = 'crosshairs' })
    while true do
        Wait(0)
        DisableControlAction(0, 38, true) DisableControlAction(0, 177, true) DisableControlAction(0, 24, true)
        local f = pickKit(45.0, filter)
        if f then
            DrawMarker(2, f.x, f.y, f.z + (HEIGHTS[f.model] or 1.2) + 0.6, 0, 0, 0, 180.0, 0, 0, 0.5, 0.5, 0.5, 52, 211, 108, 220, true, true, 2, false, nil, nil, false)
            panel(vector3(f.x, f.y, f.z + (HEIGHTS[f.model] or 1.2) + 1.2), { { kitName(f) .. ' #' .. f.id, { 52, 211, 108 }, 0.3 } })
        end
        if IsDisabledControlJustPressed(0, 38) and f then picked = f break end
        if IsDisabledControlJustPressed(0, 177) then break end
    end
    lib.hideTextUI()
    return picked
end

local function act(name, ...)
    local r = lib.callback.await(name, false, ...)
    if not r or r.error then lib.notify({ type = 'error', title = 'Line Tool', description = (r and r.error) or 'Failed' }) return false end
    return r
end

--- move one end of a conductor onto another kit
local function moveEnd(rid, which, color, from)
    local f = pickTarget('Snap the end onto…', function(g) return g.id ~= from end)
    if not f then return false end
    local info = lib.callback.await('opslabs-towers:pline:runInfo', false, rid)
    local other = info and info.ends and info.ends[which == 'start' and 'end' or 'start']
    local at = attachPoint(f, color, other and vector3(other.x, other.y, other.z))
    if not stickWork('Snapping the conductor onto ' .. kitName(f), 3500) then return false end
    local r = act('opslabs-towers:pline:moveEnd', rid, which, f.id, { x = at.x, y = at.y, z = at.z })
    if r then lib.notify({ type = 'success', title = 'Line Tool', description = 'Conductor snapped onto ' .. kitName(f) .. ' #' .. f.id }) end
    return r
end

--- after laying a conductor: say what each end landed on, offer to snap a free end on
local function afterRun(run)
    Wait(600)
    local info = lib.callback.await('opslabs-towers:pline:runInfo', false, run.id)
    if not info or info.error then return end
    local opts = {}
    for _, which in ipairs({ 'start', 'end' }) do
        local e = info.ends[which]
        opts[#opts + 1] = { title = ('%s: %s'):format(which == 'start' and 'Start' or 'End', e.name or 'lands on nothing'), icon = e.name and 'circle-check' or 'circle-xmark',
            iconColor = e.name and '#34d36c' or '#ff4d5e',
            description = not e.name and 'A loose end — snap it onto a pole or kit so the line connects' or nil,
            arrow = not e.name, onSelect = not e.name and function() moveEnd(info.id, which, info.color) runMenu(info.id) end or nil }
    end
    opts[#opts + 1] = { title = 'Done', icon = 'check' }
    lib.registerContext({ id = 'pline_after', title = ('%s · %.0f m'):format(info.label, info.length or 0), options = opts })
    lib.showContext('pline_after')
end

local function connect(f, color)
    local run, err = LayPowerRun and LayPowerRun(color)
    if not run then if err then lib.notify({ type = 'error', description = err }) end return inspectKit(f) end
    afterRun(run)
end

local function doFix(f, fix)
    if fix.kind == 'place' then
        if fix.pole then lib.notify({ type = 'inform', title = 'Line Tool', description = 'Aim at the pole and place it on it (within 0.8 m)' }) end
        if PlaceEquipmentModel then PlaceEquipmentModel(fix.model) end
        return inspectKit(f)
    elseif fix.kind == 'where' then
        return showWhere(fix)
    elseif fix.kind == 'run' then
        return connect(f, fix.color)
    elseif fix.kind == 'jumpers' then
        if stickWork('Snapping the jumpers back on', 4000) and act('opslabs-towers:pline:jumpersAll', f.id) then lib.notify({ type = 'success', description = 'Jumpers back on' }) end
        return inspectKit(f)
    elseif fix.kind == 'fuses' then
        if stickWork('Refitting the cut-out fuses', 4000) then act('opslabs-towers:pline:fuses', fix.pole) end
        return inspectKit(f)
    elseif fix.kind == 'restore' then
        if PowerRestore then PowerRestore() end
    end
end

local function fixMenu(f, c)
    local opts = {}
    for _, fix in ipairs(c.fixes or {}) do
        opts[#opts + 1] = { title = fix.label, icon = fix.kind == 'place' and 'plus' or fix.kind == 'where' and 'location-dot' or fix.kind == 'run' and 'bolt'
            or fix.kind == 'restore' and 'kit-medical' or 'wrench', iconColor = '#ffcc00', onSelect = function() doFix(f, fix) end }
    end
    lib.registerContext({ id = 'pline_fix', title = c.text, menu = 'pline_kit', description = c.note, options = opts })
    lib.showContext('pline_fix')
end

local function connMenu(f, I, c)
    local opts = {
        { title = ('%s #%d'):format(c.label, c.rid), description = ('This end → %s  ·  far end → %s%s'):format(I.pole and I.pole.name or I.name, c.other,
            c.flow and c.flow > 0 and ('  ·  ' .. mwText(c.flow)) or ''), icon = 'bolt', iconColor = c.open and '#f5a524' or c.live and '#34d36c' or '#8193a8', readOnly = true },
        { title = c.open and 'Snap on (close the jumper)' or 'Snap off (open the jumper)', icon = c.open and 'link' or 'link-slash',
            description = c.open and 'Reconnect this conductor here' or 'The line stays strung but is disconnected here — everything it fed goes dead',
            onSelect = function()
                gloveWarning(c.live)
                if stickWork(c.open and 'Snapping the jumper on' or 'Snapping the jumper off', 3000) then
                    local r = act('opslabs-towers:pline:jumper', (I.pole and I.pole.id) or f.id, c.rid, not c.open)
                    if r then lib.notify({ type = 'success', title = 'Line Tool', description = c.open and 'Snapped on' or 'Snapped off' }) end
                end
                inspectKit(f)
            end },
        { title = 'Move this end onto another pole / kit', icon = 'right-left', description = ('Aim at where it should land (within %d m of the next fixing)'):format(PL.MoveReach or 60),
            onSelect = function() gloveWarning(c.live) moveEnd(c.rid, c.which, c.color, (I.pole and I.pole.id) or f.id) inspectKit(f) end },
        { title = 'Re-string as a different conductor', icon = 'arrows-rotate', onSelect = function()
            local fam = CC.PowerOverhead or {}
            for _, x in ipairs(CC.PowerInside or {}) do if x == c.color then fam = CC.PowerInside end end
            local list = {}
            for _, k in ipairs(fam) do if k ~= c.color then list[#list + 1] = { value = k, label = LABEL[k] or k } end end
            local v = lib.inputDialog('Re-string conductor #' .. c.rid, { { type = 'select', label = 'New conductor', options = list, required = true } })
            if v and stickWork('Re-stringing the conductor', 5000) then
                if act('opslabs-towers:pline:restring', c.rid, v[1]) then lib.notify({ type = 'success', description = 'Re-strung as ' .. (LABEL[v[1]] or v[1]) }) end
            end
            inspectKit(f)
        end },
        { title = 'Open this conductor', icon = 'magnifying-glass', description = 'Both ends, what they land on, re-string or remove', onSelect = function() runMenu(c.rid) end },
    }
    if c.otherId then
        local g = fixtures()[c.otherId]
        if g then opts[#opts + 1] = { title = 'Show me the far end', icon = 'location-dot', onSelect = function() showWhere({ x = g.x, y = g.y, z = g.z, label = c.other }) end } end
    end
    lib.registerContext({ id = 'pline_conn', title = 'Conductor #' .. c.rid, menu = 'pline_kit', options = opts })
    lib.showContext('pline_conn')
end

inspectKit = function(f)
    f = fixtures()[f.id] or f
    local I = lib.callback.await('opslabs-towers:pline:inspect', false, f.id)
    if not I or I.error then return lib.notify({ type = 'error', title = 'Line Tool', description = (I and I.error) or 'Failed' }) end
    local opts = {}
    local bad = 0
    for _, c in ipairs(I.checks) do if not c.ok and not c.optional then bad = bad + 1 end end
    opts[#opts + 1] = { title = (I.live and 'LIVE · ' or 'DEAD · ') .. (I.status or ''), icon = 'bolt', iconColor = I.live and '#34d36c' or '#ff4d5e', readOnly = true,
        description = bad > 0 and ('%d step(s) missing — pick one to fix it'):format(bad) or 'Every required step is done' }
    for _, c in ipairs(I.checks) do
        local hasFix = #(c.fixes or {}) > 0
        opts[#opts + 1] = { title = c.text, description = c.note, icon = c.ok and 'circle-check' or c.optional and 'circle-exclamation' or 'circle-xmark',
            iconColor = c.ok and '#34d36c' or c.optional and '#f5a524' or '#ff4d5e', arrow = hasFix, readOnly = not hasFix,
            onSelect = hasFix and function() fixMenu(f, c) end or nil }
    end
    if #I.cables > 0 then
        opts[#opts + 1] = { title = 'Connect a conductor here', icon = 'plug-circle-plus', iconColor = '#ffcc00', arrow = true,
            description = 'Run the right cable for this kit — your first fix point goes on it', onSelect = function()
                local list = {}
                for _, c in ipairs(I.cables) do list[#list + 1] = { title = c.label, icon = 'bolt', onSelect = function() connect(f, c.color) end } end
                lib.registerContext({ id = 'pline_cables', title = 'Connect a conductor', menu = 'pline_kit', options = list })
                lib.showContext('pline_cables')
            end }
    end
    local open = 0
    for _, c in ipairs(I.conns or {}) do
        if c.open then open = open + 1 end
        opts[#opts + 1] = { title = ('%s%s #%d → %s'):format(c.open and '[OPEN] ' or '', c.label, c.rid, c.other),
            description = c.open and 'Snapped off here' or c.live and ('Live' .. (c.flow and c.flow > 0 and (' · ' .. mwText(c.flow)) or '')) or (c.cls == 'L' and 'LV' or 'Dead'),
            icon = c.open and 'link-slash' or 'link', iconColor = c.open and '#f5a524' or c.live and '#34d36c' or '#8193a8', arrow = true,
            onSelect = function() connMenu(f, I, c) end }
    end
    if open > 1 then
        opts[#opts + 1] = { title = 'Snap every jumper back on', icon = 'link', iconColor = '#34d36c', onSelect = function() doFix(f, { kind = 'jumpers' }) end }
    end
    if I.chain and #I.chain > 0 then
        opts[#opts + 1] = { title = 'Supply chain (fault finder)', icon = 'route', arrow = true, onSelect = function()
            local list = {}
            for _, s in ipairs(I.chain) do list[#list + 1] = { title = s.label, description = s.note, icon = s.ok and 'circle-check' or 'circle-xmark', iconColor = s.ok and '#34d36c' or '#ff4d5e', readOnly = true } end
            lib.registerContext({ id = 'pline_chain', title = 'Supply chain', menu = 'pline_kit', options = list })
            lib.showContext('pline_chain')
        end }
    end
    opts[#opts + 1] = { title = 'Refresh', icon = 'rotate', onSelect = function() inspectKit(f) end }
    opts[#opts + 1] = { title = 'Aim at something else', icon = 'crosshairs', onSelect = function() CreateThread(aimLoop) end }
    lib.registerContext({ id = 'pline_kit', title = ('%s · %s'):format(I.name, I.kindLabel), options = opts })
    lib.showContext('pline_kit')
end

runMenu = function(rid)
    local info = lib.callback.await('opslabs-towers:pline:runInfo', false, rid)
    if not info or info.error then return lib.notify({ type = 'error', description = (info and info.error) or 'Failed' }) end
    local opts = {
        { title = ('%s · %.0f m'):format(info.label, info.length or 0), icon = 'bolt', readOnly = true,
          iconColor = info.live and '#34d36c' or '#8193a8', description = info.cls == 'L' and 'LV conductor' or info.live and ('Live · ' .. mwText(info.flow or 0)) or 'Dead' },
    }
    for _, which in ipairs({ 'start', 'end' }) do
        local e = info.ends[which]
        local title = ('%s end: %s%s'):format(which == 'start' and 'Start' or 'Far', e.name or 'nothing (loose)', e.open and ' · OPEN' or '')
        opts[#opts + 1] = { title = title, icon = e.name and (e.open and 'link-slash' or 'link') or 'circle-xmark', arrow = true,
            iconColor = not e.name and '#ff4d5e' or e.open and '#f5a524' or '#34d36c', onSelect = function()
                local list = {}
                if e.on then
                    list[#list + 1] = { title = e.open and 'Snap on here' or 'Snap off here', icon = e.open and 'link' or 'link-slash', onSelect = function()
                        gloveWarning(info.live)
                        if stickWork(e.open and 'Snapping the jumper on' or 'Snapping the jumper off', 3000) then act('opslabs-towers:pline:jumper', e.on, info.id, not e.open) end
                        runMenu(rid)
                    end }
                end
                list[#list + 1] = { title = e.on and 'Move this end onto another pole / kit' or 'Snap this loose end onto a pole / kit', icon = 'right-left',
                    onSelect = function() gloveWarning(info.live) moveEnd(info.id, which, info.color, e.on) runMenu(rid) end }
                list[#list + 1] = { title = 'Show me this end', icon = 'location-dot', onSelect = function() showWhere({ x = e.x, y = e.y, z = e.z, label = title }) end }
                lib.registerContext({ id = 'pline_end', title = title, menu = 'pline_run', options = list })
                lib.showContext('pline_end')
            end }
    end
    opts[#opts + 1] = { title = 'Re-string as a different conductor', icon = 'arrows-rotate', onSelect = function()
        local fam = CC.PowerOverhead or {}
        for _, x in ipairs(CC.PowerInside or {}) do if x == info.color then fam = CC.PowerInside end end
        local list = {}
        for _, k in ipairs(fam) do if k ~= info.color then list[#list + 1] = { value = k, label = LABEL[k] or k } end end
        local v = lib.inputDialog('Re-string conductor #' .. info.id, { { type = 'select', label = 'New conductor', options = list, required = true } })
        if v and stickWork('Re-stringing the conductor', 5000) then act('opslabs-towers:pline:restring', info.id, v[1]) end
        runMenu(rid)
    end }
    opts[#opts + 1] = { title = 'Take the conductor down', icon = 'trash', iconColor = '#ff4d5e', onSelect = function()
        if lib.alertDialog({ header = 'Take conductor #' .. info.id .. ' down?', content = 'It is removed completely.', centered = true, cancel = true }) == 'confirm' then
            gloveWarning(info.live)
            if stickWork('Taking the conductor down', 5000) then lib.callback.await('opslabs-towers:cable:deleteRun', false, info.id) end
        end
    end }
    lib.registerContext({ id = 'pline_run', title = 'Conductor #' .. info.id, options = opts })
    lib.showContext('pline_run')
end

--- aim at kit or a conductor, [E] to work on it
local stickEnt = nil
local function holdStick(on)
    if stickEnt and DoesEntityExist(stickEnt) then DeleteEntity(stickEnt) end
    stickEnt = nil
    if not on or not lib.requestModel(joaat(STICK.model), 3000) then return end
    local ped = PlayerPedId()
    stickEnt = CreateObject(joaat(STICK.model), 0.0, 0.0, 0.0, true, true, false)
    AttachEntityToEntity(stickEnt, ped, GetPedBoneIndex(ped, STICK.bone), STICK.pos.x, STICK.pos.y, STICK.pos.z, STICK.rot.x, STICK.rot.y, STICK.rot.z, true, true, false, true, 1, true)
end

local aiming = false
aimLoop = function()
    if aiming then return end
    aiming = true
    holdStick(true)
    lib.showTextUI('**Line Tool**  \nAim at power kit or a conductor  \n[E] Work on it  ·  [Backspace] Put the tool away', { position = 'top-center', icon = 'person-digging' })
    local chosen
    while true do
        Wait(0)
        DisableControlAction(0, 38, true) DisableControlAction(0, 177, true) DisableControlAction(0, 24, true) DisableControlAction(0, 25, true)
        local f, fs = pickKit(45.0)
        local r, rp, rs
        if PickPowerRunAtAim then
            local seg
            r, seg, rp, rs = PickPowerRunAtAim(0.3)
        end
        local useRun = r and (not f or (rs or 99) + 1.0 < (fs or 99))
        if useRun then
            DrawMarker(28, rp.x, rp.y, rp.z, 0, 0, 0, 0, 0, 0, 0.18, 0.18, 0.18, 255, 204, 0, 200, false, false, 2, false, nil, nil, false)
            panel(rp + vector3(0.0, 0.0, 0.6), { { ('%s #%d'):format(LABEL[r.color] or r.color, r.id), { 255, 204, 0 }, 0.3 } })
        elseif f then
            local top = f.z + (HEIGHTS[f.model] or 1.2)
            DrawMarker(2, f.x, f.y, top + 0.6, 0, 0, 0, 180.0, 0, 0, 0.5, 0.5, 0.5, 255, 204, 0, 220, true, true, 2, false, nil, nil, false)
            if not isPole(f.model) or not Poles[f.id] then panel(vector3(f.x, f.y, top + 1.2), { { kitName(f) .. ' #' .. f.id, { 255, 204, 0 }, 0.3 } })
            else panel(vector3(f.x, f.y, top + 1.2), PoleLines(Poles[f.id], f)) end
        end
        if IsDisabledControlJustPressed(0, 38) then
            if useRun then chosen = { run = r.id } break end
            if f then chosen = { kit = f } break end
            lib.notify({ type = 'error', description = 'Aim at a pole, pylon, substation, transformer, house supply or a power conductor' })
        end
        if IsDisabledControlJustPressed(0, 177) or IsPedInAnyVehicle(PlayerPedId(), false) then break end
    end
    lib.hideTextUI()
    holdStick(false)
    aiming = false
    if chosen and chosen.run then runMenu(chosen.run) elseif chosen and chosen.kit then inspectKit(chosen.kit) end
end

--- the Line Tool menu for one fixture (pole quick menu, third eye)
function LineToolInspect(fid, onDone)
    local f = fixtures()[fid]
    if f then CreateThread(function() inspectKit(f) if onDone then onDone() end end) elseif onDone then onDone() end
end

--- the pole monitor's live data as a dialog (third eye at the bottom of a power pole)
function ShowPoleData(fid)
    local f = fixtures()[fid]
    if not f then return end
    local rows = lib.callback.await('opslabs-towers:grid:poles', false, { fid }) or {}
    local r = rows[1]
    if not r then return lib.notify({ type = 'error', description = 'No data from this pole' }) end
    Poles[fid] = r
    local lines = {}
    for _, l in ipairs(PoleLines(r, f)) do lines[#lines + 1] = l[1] end
    lib.alertDialog({ header = lines[1], content = table.concat(lines, '  \n', 2), centered = true })
end

function PowerLineTool()
    if not lib.callback.await('opslabs-towers:pline:can', false) then
        return lib.notify({ type = 'error', description = 'Only San Andreas Power & Light crews and engineers carry the Line Tool' })
    end
    CreateThread(aimLoop)
end
if PL.Command then RegisterCommand(PL.Command, function() PowerLineTool() end, false) end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(monitors) do dropMonitor(id) end
    holdStick(false)
    if aiming then lib.hideTextUI() end
end)
