-- OPS City network builder (client side of server/citybuild.lua): the server can't see the map, so an admin's game
-- does the surveying. The admin is hidden and frozen (screen faded) while their ped hops round the map so collision and
-- road nodes load, and for each district we find:
--   · a small plot beside a road for each building (substation, exchange, house, fuel station, mast) — level with the
--     road (so never a roof), flat enough, no walls across it, not in water, not overlapping the others
--   · a pole line each way along the road from the substation: power on its side, telecom across the road
-- and for the 400 kV lines, clear ground for each pylon near where the server wants it.
-- Every answer carries a short diagnosis so OPS Hub can say why a district or plot was skipped.

local hidden = false
local hiddenAt = 0
local start, startH

local function hide()
    hiddenAt = GetGameTimer()
    if hidden then return end
    local ped = PlayerPedId()
    start, startH = GetEntityCoords(ped), GetEntityHeading(ped)
    DoScreenFadeOut(500) Wait(550)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityInvincible(ped, true)
    hidden = true
end

local function unhide()
    if not hidden then return end
    hidden = false
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, start.x, start.y, start.z, false, false, false)
    SetEntityHeading(ped, startH)
    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(600)
end

-- never leave an admin stuck invisible if the server stops asking
CreateThread(function()
    while true do
        Wait(5000)
        if hidden and GetGameTimer() - hiddenAt > 120000 then unhide() end
    end
end)
AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then unhide() end end)

--- hop there and wait for collision and road nodes round it
local function goTo(x, y)
    local ped = PlayerPedId()
    local top = GetHeightmapTopZForPosition(x + 0.0, y + 0.0)
    if not top or top < -50 then top = 100.0 end
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, top + 30.0, false, false, false)
    local t0 = GetGameTimer()
    repeat
        RequestCollisionAtCoord(x + 0.0, y + 0.0, top)
        RequestPathsPreferAccurateBoundingstruct(x - 400.0, y - 400.0, x + 400.0, y + 400.0)
        Wait(0)
    until (HasCollisionLoadedAroundEntity(ped) and AreNodesLoadedForArea(x - 400.0, y - 400.0, x + 400.0, y + 400.0)) or GetGameTimer() - t0 > 6000
    Wait(400)
    hiddenAt = GetGameTimer()
end

local function dirOf(h) local r = math.rad(h) return -math.sin(r), math.cos(r) end     -- GTA heading → unit vector
local function headingOf(vx, vy) return math.deg(math.atan(-vx, vy)) % 360 end

--- the map surface under a point (terrain and buildings, not props or trees): z, 'ground' | 'water' | nil
local function surface(x, y)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(x + 0.0, y + 0.0, 1200.0, x + 0.0, y + 0.0, -100.0, 1, PlayerPedId(), 7)
    local _, hit, at = GetShapeTestResult(probe)
    if hit ~= 1 then return nil end
    local water, wz = GetWaterHeight(x + 0.0, y + 0.0, at.z + 2.0)
    if water and wz > at.z - 0.2 then return at.z, 'water' end
    return at.z, 'ground'
end

local function wallBetween(a, b)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 1, PlayerPedId(), 7)
    local _, hit = GetShapeTestResult(probe)
    return hit == 1
end

--- can a W × D plot go here? front edge centred at fx, fy, deep along heading h. roadZ: it must sit level with the road.
--- → mean z, samples ({ lx, ly, z }) | nil, reason
local function fits(fx, fy, h, W, D, roadZ, slope, levelTol)
    local dx, dy = dirOf(h)
    local rx, ry = dy, -dx
    local zs, sum, n, lo, hi = {}, 0, 0, 1e9, -1e9
    -- the front edge must be near road level (so never a roof or a bridge deck); the rest is judged against it
    local frontZ = surface(fx, fy)
    if not frontZ then return nil, 'nohit' end
    if roadZ and math.abs(frontZ - roadZ) > 3.5 then return nil, 'level' end
    for iy = 0, D, 4 do
        for ix = -W / 2, W / 2, 4 do
            local x, y = fx + rx * ix + dx * iy, fy + ry * ix + dy * iy
            local z, kind = surface(x, y)
            if not z then return nil, 'nohit' end
            if kind == 'water' then return nil, 'water' end
            if math.abs(z - frontZ) > (levelTol or 5.0) then return nil, 'level' end
            if iy >= D / 2 and math.abs(ix) <= W / 4 and IsPointOnRoad(x + 0.0, y + 0.0, z + 0.5, 0) then return nil, 'road' end
            zs[#zs + 1] = { ix, iy, z }
            sum, n = sum + z, n + 1
            lo, hi = math.min(lo, z), math.max(hi, z)
        end
    end
    if hi - lo > (slope or 2.5) then return nil, 'slope' end
    local mean = sum / n
    -- walls across the plot (houses, fences, rock faces)
    local function P(ix, iy, dz) return vector3(fx + rx * ix + dx * iy, fy + ry * ix + dy * iy, mean + dz) end
    for _, dz in ipairs({ 1.3, 2.6 }) do
        local c = { P(-W / 2, 0, dz), P(W / 2, 0, dz), P(W / 2, D, dz), P(-W / 2, D, dz) }
        if wallBetween(c[1], c[3]) or wallBetween(c[2], c[4]) or wallBetween(c[1], c[2]) or wallBetween(c[2], c[3])
            or wallBetween(c[3], c[4]) or wallBetween(c[4], c[1]) then return nil, 'wall' end
    end
    return mean, zs
end

--- road nodes round a point: { x, y, z, h }
local function roadNodes(x, y, z, count)
    local out = {}
    for i = 1, count do
        local ok, pos, heading = GetNthClosestVehicleNodeWithHeading(x + 0.0, y + 0.0, z + 0.0, i, 0, 3.0, 0.0)
        if ok and pos then out[#out + 1] = { x = pos.x, y = pos.y, z = pos.z, h = heading } end
    end
    return out
end

local function roadside(x, y, z, h)
    local ok, p = GetRoadSidePointWithHeading(x + 0.0, y + 0.0, z + 0.0, h + 0.0)
    if ok and p then return p end
    return nil
end

--- a pole line along the road from a node, ~spacing apart. lotSide = true: on the same side of the road as the plot
--- (faceX, faceY points from the road into the plot), false: across the road.
local function poleLine(node, dirSign, lotSide, faceX, faceY, spacing, count)
    local pts = {}
    local px, py, pz, h = node.x, node.y, node.z, (node.h + (dirSign < 0 and 180.0 or 0.0)) % 360
    local rel = nil
    for _ = 1, count * 3 do
        if #pts >= count then break end
        local dx, dy = dirOf(h)
        local ok, pos, nh = GetClosestVehicleNodeWithHeading(px + dx * spacing, py + dy * spacing, pz, 1, 3.0, 0)
        if not ok or not pos then break end
        local jump = math.sqrt((pos.x - px) ^ 2 + (pos.y - py) ^ 2)
        if jump < spacing * 0.4 or jump > spacing * 2.2 then break end
        if math.abs(((nh - h + 540) % 360) - 180) > 90 then nh = (nh + 180) % 360 end
        px, py, pz, h = pos.x, pos.y, pos.z, nh
        if rel == nil then
            local a = roadside(px, py, pz, h)
            if a then rel = ((((a.x - px) * faceX + (a.y - py) * faceY) > 0) == lotSide) and 0 or 180 end
        end
        local rs = roadside(px, py, pz, (h + (rel or 0)) % 360)
        local sx, sy = rs and rs.x or px, rs and rs.y or py
        local ox, oy = sx - px, sy - py
        local ol = math.sqrt(ox * ox + oy * oy)
        if ol > 0.5 then sx, sy = sx + ox / ol * 1.2, sy + oy / ol * 1.2 end
        local z, kind = surface(sx, sy)
        if z and kind == 'ground' and math.abs(z - pz) < 5.0 then pts[#pts + 1] = { x = sx, y = sy, z = z, h = h } end
    end
    return pts
end

--- one district: a plot for each building + pole lines from the substation
--- d = { x, y, plots = { { key, w, d, need }… }, poles, spacing }
local function surveyDistrict(d)
    hide()
    goTo(d.x, d.y)
    local gz = surface(d.x, d.y) or GetHeightmapTopZForPosition(d.x + 0.0, d.y + 0.0) or 40.0
    local nodes = roadNodes(d.x, d.y, gz, d.tries or 140)
    local why = { nodes = #nodes }
    if #nodes == 0 then return { error = 'no roads found near the district centre (road data didn\'t load)', diag = why } end
    local sites, taken = {}, {}
    for _, spec in ipairs(d.plots or {}) do
        local fails = {}
        local W, D = spec.w, spec.d
        local rad = math.sqrt(W * W + D * D) / 2 + 2.0
        local hopX, hopY = d.x, d.y
        for pass = 1, spec.need and 1 or 2 do
        local slopeTol, levelTol = (spec.slope or 2.5) * (pass == 1 and 1 or 1.8), pass == 1 and 5.0 or 8.0
        for _, nd in ipairs(nodes) do
            if sites[spec.key] then break end
            if math.abs(nd.x - hopX) + math.abs(nd.y - hopY) > 160 then
                local ped = PlayerPedId()
                SetEntityCoordsNoOffset(ped, nd.x, nd.y, nd.z + 25.0, false, false, false)
                local t0 = GetGameTimer()
                repeat RequestCollisionAtCoord(nd.x, nd.y, nd.z) Wait(0) until HasCollisionLoadedAroundEntity(ped) or GetGameTimer() - t0 > 2500
                Wait(150)
                hopX, hopY = nd.x, nd.y
            end
            for _, try in ipairs({ 0, 180, 1000, 1180 }) do       -- each side of the road, 3 m then 10 m back from it
                local off, back = try % 1000, try >= 1000 and 10.0 or 3.0
                local rs = roadside(nd.x, nd.y, nd.z, (nd.h + off) % 360)
                if rs then
                    local vx, vy = rs.x - nd.x, rs.y - nd.y
                    local vl = math.sqrt(vx * vx + vy * vy)
                    if vl > 1.0 then
                        vx, vy = vx / vl, vy / vl
                        local face = headingOf(vx, vy)
                        local fx, fy = rs.x + vx * back, rs.y + vy * back
                        local cx, cy = fx + vx * D / 2, fy + vy * D / 2
                        local clash = false
                        for _, t in ipairs(taken) do if math.sqrt((t.x - cx) ^ 2 + (t.y - cy) ^ 2) < t.r + rad then clash = true break end end
                        if clash then fails.overlap = (fails.overlap or 0) + 1
                        else
                            local mean, zs = fits(fx, fy, face, W, D, nd.z, slopeTol, levelTol)
                            if mean then
                                sites[spec.key] = { x = fx, y = fy, z = mean, h = face, zs = zs, node = nd, fx = vx, fy = vy }
                                taken[#taken + 1] = { x = cx, y = cy, r = rad }
                                break
                            else fails[zs] = (fails[zs] or 0) + 1 end
                        end
                    end
                end
            end
            hiddenAt = GetGameTimer()
        end
        if sites[spec.key] then break end
        end
        if not sites[spec.key] then
            local t = {}
            for k, v in pairs(fails) do t[#t + 1] = k .. ' ' .. v end
            why[spec.key] = table.concat(t, ', ')
            if spec.need then return { error = ('no plot for the %s (%d roads tried: %s)'):format(spec.label or spec.key, #nodes, why[spec.key]), diag = why } end
        end
    end
    -- pole lines both ways along the road from the substation's plot
    local s = sites.sub
    local out = { sites = sites, power = {}, telecom = {}, diag = why }
    for _, dir in ipairs({ 1, -1 }) do
        out.power[#out.power + 1] = poleLine(s.node, dir, true, s.fx, s.fy, d.spacing or 40.0, d.poles or 8)
        out.telecom[#out.telecom + 1] = poleLine(s.node, dir, false, s.fx, s.fy, d.spacing or 40.0, d.poles or 8)
    end
    return out
end
-- any error answers straight away with the reason (instead of the server waiting minutes while you sit in the dark)
lib.callback.register('opslabs-towers:city:district', function(d)
    local ok, r = pcall(surveyDistrict, d)
    if ok then return r end
    print('^1[OPS City] survey error: ' .. tostring(r) .. '^7')
    return { error = 'survey error on the admin\'s game: ' .. tostring(r) }
end)

-- /opscitypreview: run the district survey right where you stand and show what it would use (nothing is built)
local previewPlots = { { key = 'sub', w = 16, d = 14, need = true, label = 'substation' }, { key = 'ex', w = 28, d = 13, label = 'telephone exchange' },
    { key = 'house', w = 14, d = 11, label = 'customer house' }, { key = 'fuel', w = 24, d = 20, label = 'fuel station' },
    { key = 'mast', w = 7, d = 7, label = 'cell mast', slope = 3.5 } }
RegisterCommand('opscitypreview', function()
    if not lib.callback.await('opslabs-towers:isAdmin', false) then return lib.notify({ type = 'error', description = 'Admins only' }) end
    local me = GetEntityCoords(PlayerPedId())
    lib.notify({ type = 'inform', title = 'OPS City preview', description = 'Surveying here — your screen goes dark for a moment' })
    local r = surveyDistrict({ x = me.x, y = me.y, plots = previewPlots, poles = (Config.City or {}).PolesPerLine or 8, spacing = (Config.City or {}).PoleSpacing or 40.0 })
    unhide()
    local lines = {}
    for k, v in pairs((r and r.diag) or {}) do lines[#lines + 1] = ('%s: %s'):format(k, tostring(v)) end
    if not r or r.error then
        return lib.alertDialog({ header = 'OPS City preview — this spot fails', content = ((r and r.error) or 'no answer') .. '  \n  \n' .. table.concat(lines, '  \n'), centered = true })
    end
    local np, nt = 0, 0
    for _, l in ipairs(r.power) do np = np + #l end
    for _, l in ipairs(r.telecom) do nt = nt + #l end
    local got = {}
    for _, p in ipairs(previewPlots) do got[#got + 1] = p.label .. (r.sites[p.key] and ' ✓' or ' ✗') end
    lib.alertDialog({ header = 'OPS City preview', centered = true, content = ('%s  \n%d power poles · %d telecom poles  \n  \n%s  \n  \nShown for 90 s: yellow boxes = plots, green = power poles, blue = telecom poles.')
        :format(table.concat(got, ' · '), np, nt, table.concat(lines, '  \n')) })
    local untilT = GetGameTimer() + 90000
    CreateThread(function()
        while GetGameTimer() < untilT do
            for key, s in pairs(r.sites) do
                local spec
                for _, p in ipairs(previewPlots) do if p.key == key then spec = p end end
                local dx, dy = dirOf(s.h)
                local cx, cy = s.x + dx * spec.d / 2, s.y + dy * spec.d / 2
                DrawMarker(43, cx, cy, s.z - 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, s.h, spec.w, spec.d, 4.0, 255, 204, 0, 70, false, false, 2, false, nil, nil, false)
            end
            for _, l in ipairs(r.power) do for _, p in ipairs(l) do DrawMarker(1, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.4, 0.4, 10.0, 52, 211, 108, 180, false, false, 2, false, nil, nil, false) end end
            for _, l in ipairs(r.telecom) do for _, p in ipairs(l) do DrawMarker(1, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.35, 0.35, 10.0, 61, 155, 255, 180, false, false, 2, false, nil, nil, false) end end
            Wait(0)
        end
    end)
end, false)

--- ground for a list of spots (pylons, the power station): each moved up to `search` m to a clear, level spot
local surveySpots
lib.callback.register('opslabs-towers:city:spots', function(...)
    local ok, r = pcall(surveySpots, ...)
    if ok then return r end
    print('^1[OPS City] survey error: ' .. tostring(r) .. '^7')
    return {}
end)
surveySpots = function(list, search, clear)
    hide()
    local out = {}
    for i, p in ipairs(list) do
        if i == 1 or math.abs(p.x - list[i - 1].x) + math.abs(p.y - list[i - 1].y) > 150 then goTo(p.x, p.y) end
        local found
        for r = 0, search or 30, 6 do
            for a = 0, (r == 0 and 0 or 330), 30 do
                local x, y = p.x + math.cos(math.rad(a)) * r, p.y + math.sin(math.rad(a)) * r
                local z0 = surface(x, y)
                if z0 and not IsPointOnRoad(x + 0.0, y + 0.0, z0 + 0.5, 0) then
                    local mean = fits(x - (clear or 10) / 2 * 0, y, p.h or 0.0, clear or 10, clear or 10, nil, 3.5)
                    if mean then found = { x = x, y = y, z = mean } break end
                end
            end
            if found then break end
        end
        if not found then
            local z, kind = surface(p.x, p.y)
            found = (z and kind == 'ground') and { x = p.x, y = p.y, z = z, rough = true } or false
        end
        out[i] = found
        hiddenAt = GetGameTimer()
    end
    return out
end

lib.callback.register('opslabs-towers:city:done', function() unhide() return true end)

RegisterNetEvent('opslabs-towers:city:warn', function(text)
    lib.notify({ type = 'warning', title = 'OPS City network', description = text, duration = 12000 })
end)
