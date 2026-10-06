-- Street works safety kit: cones, barriers, cordon tape, works signs with live editable text
-- (each nearby sign gets one of 8 sign variants whose face texture is drawn from html/sign.html)
-- and portable traffic lights that run a shared red / amber / green cycle in A / B pairs.
-- Placed from Network cabling → Road safety equipment.

local RW = Config.Roadworks or { Items = {} }
local SLOTS = 8
local slots = {}          -- slot -> fixture key
local slotOf = {}         -- fixture key -> slot
local duis = {}           -- slot -> { dui, url }
local lights = {}         -- fixture key -> { ent, lamps = { red, amber, green }, phase }
local txd

local function labelOf(model)
    for _, e in ipairs(RW.Items) do
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then return e.label .. ' · ' .. sz.label:match('^[^·]+'):gsub('%s+$', '') end end
        if e.model == model then return e.label end
    end
    return equipLabelFor and equipLabelFor(model) or model
end

local function signUrl(lines)
    local q = {}
    for i = 1, 5 do
        local v = (lines and lines[i]) or ''
        q[#q + 1] = ('l%d=%s'):format(i, (v:gsub('[^%w%-%._~ ]', function(c) return ('%%%02X'):format(c:byte()) end):gsub(' ', '%%20')))
    end
    return ('nui://%s/html/sign.html?%s'):format(GetCurrentResourceName(), table.concat(q, '&'))
end

--- point a slot's sign face at this text
local function paintSlot(n, lines)
    local url = signUrl(lines)
    local d = duis[n]
    if not d then
        txd = txd or CreateRuntimeTxd('opslabs_rw_signs')
        local dui = CreateDui(url, 512, 384)
        CreateRuntimeTextureFromDuiHandle(txd, 'face_' .. n, GetDuiHandle(dui))
        AddReplaceTexture('opslabs_rw_sign_' .. n, 'opslabs_rw_signface_' .. n, 'opslabs_rw_signs', 'face_' .. n)
        duis[n] = { dui = dui, url = url }
    elseif d.url ~= url then
        SetDuiUrl(d.dui, url)
        d.url = url
    end
end

local function spawnAt(modelName, f)
    local h = joaat(modelName)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    local e = CreateObjectNoOffset(h, f.x, f.y, f.z, false, false, false)
    SetEntityHeading(e, f.heading or 0.0)
    SetEntityCoordsNoOffset(e, f.x, f.y, f.z, false, false, false)
    FreezeEntityPosition(e, true)
    return e
end

-- metal pole information plates: same idea as the signs, 8 live faces
local PLATES = 8
local plateSlots, plateOf, plateDuis = {}, {}, {}
local function plateUrl(b)
    b = b or {}
    local q = {}
    for _, k in ipairs({ 'name', 'color', 'number', 'phone', 'extra' }) do
        local v = tostring(b[k] or '')
        q[#q + 1] = k .. '=' .. (v:gsub('[^%w%-%._~ ]', function(c) return ('%%%02X'):format(c:byte()) end):gsub(' ', '%%20'))
    end
    return ('nui://%s/html/brand.html?%s'):format(GetCurrentResourceName(), table.concat(q, '&'))
end
local function paintPlate(n, brand)
    local url = plateUrl(brand)
    local d = plateDuis[n]
    if not d then
        txd = txd or CreateRuntimeTxd('opslabs_rw_signs')
        local dui = CreateDui(url, 512, 704)
        CreateRuntimeTextureFromDuiHandle(txd, 'plate_' .. n, GetDuiHandle(dui))
        AddReplaceTexture('opslabs_brandplate_' .. n, 'opslabs_brandplate_' .. n, 'opslabs_rw_signs', 'plate_' .. n)
        plateDuis[n] = { dui = dui, url = url }
    elseif d.url ~= url then
        SetDuiUrl(d.dui, url)
        d.url = url
    end
end

--- called by the cabling streamer for every fixture; returns true when it handled the spawn
function RoadworksSpawn(key, f, list)
    if f.model == 'opslabs_pole_metal' then
        local e = spawnAt('opslabs_pole_metal', f)
        if not e then return true end
        list[1] = e
        local n = plateOf[key]
        if not n then
            for i = 1, PLATES do if not plateSlots[i] then n = i break end end
            if n then plateSlots[n], plateOf[key] = key, n end
        end
        if n then
            paintPlate(n, f.data and f.data.brand)
            local h = math.rad(f.heading or 0.0)
            local px, py = f.x + 0.112 * math.sin(h), f.y - 0.112 * math.cos(h)       -- on the pole surface, facing out
            local plate = spawnAt('opslabs_brandplate_' .. n, { x = px, y = py, z = f.z + 1.9, heading = f.heading })
            if plate then SetEntityCollision(plate, false, false) list[2] = plate end
        end
        return true
    end
    if f.model == 'opslabs_rw_sign' then
        local n = slotOf[key]
        if not n then
            for i = 1, SLOTS do if not slots[i] then n = i break end end
            if not n then return true end              -- more than 8 signs in view: skip the far ones
            slots[n], slotOf[key] = key, n
        end
        paintSlot(n, (f.data and f.data.lines) or RW.SignDefault)
        list[1] = spawnAt('opslabs_rw_sign_' .. n, f)
        return true
    elseif f.model == 'opslabs_rw_tlight' then
        local e = spawnAt('opslabs_rw_tlight', f)
        if not e then return true end
        list[1] = e
        local lamps = {}
        for i, col in ipairs({ 'red', 'amber', 'green' }) do
            local z = 2.883 - (i - 1) * 0.233                -- the three lenses on the head
            local p = GetOffsetFromEntityInWorldCoords(e, 0.0, -0.122, z)
            local l = spawnAt('opslabs_rw_lamp_' .. col, { x = p.x, y = p.y, z = p.z, heading = f.heading })
            if l then SetEntityCollision(l, false, false) SetEntityVisible(l, false, false) list[#list + 1] = l end
            lamps[col] = l
        end
        lights[key] = { ent = e, lamps = lamps, phase = (f.data and f.data.phase) or 0 }
        return true
    end
    return false
end

function RoadworksDespawn(key)
    local n = slotOf[key]
    if n then slots[n], slotOf[key] = nil, nil end
    local pn = plateOf[key]
    if pn then plateSlots[pn], plateOf[key] = nil, nil end
    lights[key] = nil
end

--- which lamp a light shows right now (synced: every client uses the same clock)
local function aspect(phase)
    local L = RW.Lights or { green = 20, amber = 3, allRed = 3 }
    local half = L.green + L.amber + L.allRed
    local t = (GetCloudTimeAsInt() + (phase == 1 and half or 0)) % (half * 2)
    if t < L.green then return 'green' end
    if t < L.green + L.amber then return 'amber' end
    return 'red'
end

local GLOW = { red = { 255, 40, 30 }, amber = { 255, 160, 20 }, green = { 40, 255, 110 } }
CreateThread(function()
    while true do
        if next(lights) then
            local pos = GetEntityCoords(PlayerPedId())
            local close = false
            for _, l in pairs(lights) do
                local on = aspect(l.phase)
                for col, lamp in pairs(l.lamps) do
                    if lamp and DoesEntityExist(lamp) then
                        SetEntityVisible(lamp, col == on, false)
                        if col == on and #(pos - GetEntityCoords(lamp)) < 60.0 then
                            close = true
                            local p = GetEntityCoords(lamp)
                            local g = GLOW[col]
                            DrawLightWithRange(p.x, p.y, p.z, g[1], g[2], g[3], 2.5, 3.0)
                        end
                    end
                end
            end
            Wait(close and 0 or 300)
        else
            Wait(1000)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, d in pairs(duis) do if d.dui then DestroyDui(d.dui) end end
    for _, d in pairs(plateDuis) do if d.dui then DestroyDui(d.dui) end end
    for n = 1, PLATES do RemoveReplaceTexture('opslabs_brandplate_' .. n, 'opslabs_brandplate_' .. n) end
    for n = 1, SLOTS do RemoveReplaceTexture('opslabs_rw_sign_' .. n, 'opslabs_rw_signface_' .. n) end
end)

---------------------------------------------------------------------------
-- menu
---------------------------------------------------------------------------

local RoadworksMenu

local function rwFixtures()
    local out = {}
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f.model:find('^opslabs_rw_') then out[#out + 1] = f end
    end
    return out
end

local function text3d(x, y, z, txt, r, g, b)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.34, 0.34)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextColour(r or 255, g or 255, b or 255, 255)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(txt)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function groundZ(x, y, z)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x, y, z + 1.5, x, y, z - 4.0, 1, PlayerPedId(), 4)
    local _, hit, at = GetShapeTestResult(ray)
    return hit == 1 and at.z or z
end

--- ruler from the nearest road kit to where you're placing: ticks every metre, the distance,
--- and green when the two are square to each other (straight across or straight along)
local function ruler(skipId)
    return function(pos, heading)
        local best, bd
        for _, f in ipairs(rwFixtures()) do
            if f.id ~= skipId then
                local d = #(vector2(f.x, f.y) - vector2(pos.x, pos.y))
                if d > 0.15 and d < 25.0 and (not bd or d < bd) then best, bd = f, d end
            end
        end
        if not best then return nil end
        local a, b = vector3(best.x, best.y, best.z + 0.12), vector3(pos.x, pos.y, pos.z + 0.12)
        local dir = vector2(b.x - a.x, b.y - a.y) / bd
        local square = false
        for _, h in ipairs({ best.heading or 0.0, heading }) do
            local hr = math.rad(h)
            local fwd, right = vector2(-math.sin(hr), math.cos(hr)), vector2(math.cos(hr), math.sin(hr))
            local c1, c2 = math.abs(dir.x * fwd.x + dir.y * fwd.y), math.abs(dir.x * right.x + dir.y * right.y)
            if c1 > 0.9976 or c2 > 0.9976 then square = true end         -- within ~4°
        end
        local r, g, bl = square and 48 or 255, square and 209 or 159, square and 88 or 10
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, 255)
        for m = 1, math.floor(bd) do                                     -- a tick every metre
            local t = m / bd
            local p = a + (b - a) * t
            DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, m % 5 == 0 and 0.07 or 0.04, m % 5 == 0 and 0.07 or 0.04, m % 5 == 0 and 0.07 or 0.04, r, g, bl, 230, false, false, 2, false, nil, nil, false)
        end
        local mid = (a + b) / 2
        text3d(mid.x, mid.y, mid.z + 0.25, ('%.2f m%s'):format(bd, square and ' · square' or ''), r, g, bl)
        return ('%.2f m from the %s%s'):format(bd, labelOf(best.model):lower(), square and ' · square' or '')
    end
end

--- lay a row: aim at the start, click, aim at the end — the row is previewed as you aim
local LINE_GAP = { opslabs_rw_barrier = 2.0, opslabs_rw_barrier_stay = 2.0, opslabs_rw_tape = 3.0, opslabs_rw_barrier_red = 1.0,
    opslabs_fence_pal_grey = 2.5, opslabs_fence_pal_green = 2.5, opslabs_fence_pal_galv = 2.5, opslabs_fence_mesh_grey = 2.5,
    opslabs_fence_mesh_green = 2.5, opslabs_fence_brand = 2.5 }
local function lineMode(modelName, spacing)
    local h = joaat(modelName)
    if not IsModelInCdimage(h) then return end
    lib.requestModel(h, 5000)
    local wide = LINE_GAP[modelName] ~= nil                 -- barriers / tape run along the line
    local start, ghosts = nil, {}
    local function setGhosts(n)
        while #ghosts < n do
            local e = CreateObjectNoOffset(h, 0.0, 0.0, -100.0, false, false, false)
            SetEntityAlpha(e, 160, false) SetEntityCollision(e, false, false) FreezeEntityPosition(e, true)
            ghosts[#ghosts + 1] = e
        end
        for i = n + 1, #ghosts do SetEntityCoordsNoOffset(ghosts[i], 0.0, 0.0, -100.0, false, false, false) end
    end
    local result
    local sf = PlaceHud.buttons({ { 'Set start / place row', { 24, 191 } }, { 'Back', { 25, 177 } }, { 'Cancel', 200 } })
    while true do
        Wait(0)
        for _, ctl in ipairs({ 24, 25, 37, 44, 140, 141, 142, 177, 191, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local x, z = math.rad(camRot.x), math.rad(camRot.z)
        local to = camPos + vector3(-math.sin(z) * math.abs(math.cos(x)), math.cos(z) * math.abs(math.cos(x)), math.sin(x)) * 30.0
        local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1, PlayerPedId(), 4)
        local _, hit, at = GetShapeTestResult(ray)
        local spots = {}
        local note
        if hit == 1 then
            DrawMarker(28, at.x, at.y, at.z, 0, 0, 0, 0, 0, 0, 0.08, 0.08, 0.08, 255, 255, 255, 220, false, false, 2, false, nil, nil, false)
            if start then
                local d = vector2(at.x - start.x, at.y - start.y)
                local L = #d
                if L > 0.2 then
                    local dir = d / L
                    local heading = wide and math.deg(math.atan(dir.y, dir.x)) or math.deg(math.atan(-dir.x, dir.y))
                    local gap = wide and LINE_GAP[modelName] or spacing
                    local n = math.min(60, math.floor(L / gap + (wide and 0 or 1)))
                    for i = 0, n - 1 do
                        local t = wide and (i + 0.5) * gap or i * gap
                        local px, py = start.x + dir.x * t, start.y + dir.y * t
                        spots[#spots + 1] = { x = px, y = py, z = groundZ(px, py, start.z + (at.z - start.z) * (t / L)), heading = heading % 360 }
                    end
                    DrawLine(start.x, start.y, start.z + 0.05, at.x, at.y, at.z + 0.05, 255, 159, 10, 255)
                    note = ('%d × %s · %.1f m long · %.1f m apart'):format(#spots, labelOf(modelName):lower(), L, gap)
                end
            else
                note = 'Aim at the start of the row and click'
            end
        else
            note = 'Aim at the ground'
        end
        setGhosts(#spots)
        for i, sp in ipairs(spots) do
            SetEntityCoordsNoOffset(ghosts[i], sp.x, sp.y, sp.z, false, false, false)
            SetEntityHeading(ghosts[i], sp.heading)
            DrawMarker(25, sp.x, sp.y, sp.z + 0.02, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 255, 159, 10, 140, false, false, 2, false, nil, nil, false)
        end
        if start then DrawMarker(25, start.x, start.y, start.z + 0.02, 0, 0, 0, 0, 0, 0, 0.6, 0.6, 0.6, 48, 209, 88, 180, false, false, 2, false, nil, nil, false) end
        PlaceHud.draw(sf, 'Line of ' .. labelOf(modelName):lower(), note, { 255, 159, 10 })
        if hit == 1 and (IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191)) then
            if not start then start = at
            elseif #spots > 0 then
                result = {}
                for _, sp in ipairs(spots) do result[#result + 1] = { model = modelName, x = sp.x, y = sp.y, z = sp.z, heading = sp.heading } end
                break
            end
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) then
            if start then start = nil else break end
        end
        if IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    for _, e in ipairs(ghosts) do if DoesEntityExist(e) then DeleteEntity(e) end end
    if not result then return end
    local r = lib.callback.await('opslabs-towers:fixture:saveMany', false, result)
    if r and r.ok then lib.notify({ type = 'success', description = ('Placed %d'):format(r.count) })
    else lib.notify({ type = 'error', description = (r and r.error == 'not allowed') and 'Only network engineers can set out street works' or (r and r.error) or 'Failed' }) end
    Wait(250)
end

local function sizeChoice(e)
    if not e.sizes then return e.model end
    local opts = {}
    for _, sz in ipairs(e.sizes) do opts[#opts + 1] = { value = sz.model, label = sz.label } end
    local v = lib.inputDialog(e.label, { { type = 'select', label = 'Size', icon = 'ruler-vertical', options = opts, default = e.model, required = true } })
    return v and v[1] or nil
end

--- aim at road kit and hold to pick it up
local function removeAim()
    local sf = PlaceHud.buttons({ { 'Hold to pick up', 24 }, { 'Done', { 25, 177, 200 } } })
    local hold, holdId, lastOutline = 0.0, nil, nil
    local last = GetGameTimer()
    local function unOutline()
        for _, e in ipairs(lastOutline and CablingEntities('f' .. lastOutline) or {}) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
        lastOutline = nil
    end
    while true do
        Wait(0)
        local now = GetGameTimer()
        local dt = (now - last) / 1000
        last = now
        for _, ctl in ipairs({ 24, 25, 37, 44, 140, 141, 142, 177, 199, 200, 257, 263 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local x, z = math.rad(camRot.x), math.rad(camRot.z)
        local to = camPos + vector3(-math.sin(z) * math.abs(math.cos(x)), math.cos(z) * math.abs(math.cos(x)), math.sin(x)) * 25.0
        local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1 + 16, PlayerPedId(), 4)
        local _, hit, at = GetShapeTestResult(ray)
        local target
        if hit == 1 then
            local bd = 1.0
            for _, f in ipairs(rwFixtures()) do
                local d = #(vector3(f.x, f.y, f.z + 0.4) - at)
                if d < bd then target, bd = f, d end
            end
        end
        if (target and target.id) ~= lastOutline then
            unOutline()
            if target then
                SetEntityDrawOutlineColor(255, 69, 58, 255) SetEntityDrawOutlineShader(1)
                for _, e in ipairs(CablingEntities('f' .. target.id) or {}) do SetEntityDrawOutline(e, true) end
                lastOutline = target.id
            end
        end
        if target and IsDisabledControlPressed(0, 24) then
            if holdId ~= target.id then hold, holdId = 0.0, target.id end
            hold = hold + dt
        else hold, holdId = 0.0, nil end
        PlaceHud.draw(sf, 'Pick up road safety kit', target and (labelOf(target.model) .. (hold > 0 and ('   ' .. string.rep('■', math.floor(hold / 0.4 * 10)) .. string.rep('□', 10 - math.min(10, math.floor(hold / 0.4 * 10)))) or '')) or 'Aim at a cone, barrier, sign, light or tape', { 255, 69, 58 })
        if target and hold >= 0.4 then
            unOutline()
            lib.callback.await('opslabs-towers:fixture:deleteMany', false, { target.id })
            hold, holdId = 0.0, nil
            Wait(250)
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    unOutline()
    PlaceHud.release(sf)
end

local KINDS = { { 'all', 'Everything' }, { 'cone', 'Cones' }, { 'barrier', 'Barriers' }, { 'sign', 'Signs' }, { 'tlight', 'Traffic lights' }, { 'tape', 'Cordon tape' }, { 'worklight', 'Work lights' }, { 'lighttower', 'Lighting towers' } }
local function kindOf(model) return model:match('^opslabs_rw_(%a+)') end

local function removeNearby()
    local opts = {}
    for _, k in ipairs(KINDS) do opts[#opts + 1] = { value = k[1], label = k[2] } end
    local v = lib.inputDialog('Pick up road safety kit', {
        { type = 'select', label = 'What', options = opts, default = 'all', required = true },
        { type = 'slider', label = 'Within (metres)', min = 5, max = 100, step = 5, default = 25 },
    })
    if not v then return end
    local pos = GetEntityCoords(PlayerPedId())
    local ids = {}
    for _, f in ipairs(rwFixtures()) do
        if (v[1] == 'all' or kindOf(f.model) == v[1]) and #(pos - vector3(f.x, f.y, f.z)) <= v[2] then ids[#ids + 1] = f.id end
    end
    if #ids == 0 then return lib.notify({ type = 'inform', description = 'Nothing like that within ' .. v[2] .. ' m' }) end
    local what = 'road safety kit'
    for _, k in ipairs(KINDS) do if k[1] == v[1] and v[1] ~= 'all' then what = k[2]:lower() end end
    if lib.alertDialog({ header = ('Pick up %d item(s)?'):format(#ids), content = ('All %s within %d m.'):format(what, v[2]), centered = true, cancel = true }) == 'confirm' then
        local n = lib.callback.await('opslabs-towers:fixture:deleteMany', false, ids)
        lib.notify({ type = 'success', description = ('Picked up %d'):format(n or 0) })
        Wait(250)
    end
end

local function removePick()
    local pos = GetEntityCoords(PlayerPedId())
    local list = {}
    for _, f in ipairs(rwFixtures()) do
        local d = #(pos - vector3(f.x, f.y, f.z))
        if d < 100 then list[#list + 1] = { f = f, d = d } end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    if #list == 0 then return lib.notify({ type = 'inform', description = 'No road safety kit within 100 m' }) end
    local opts = {}
    for _, e in ipairs(list) do opts[#opts + 1] = { value = tostring(e.f.id), label = ('%s — %dm away'):format(labelOf(e.f.model), math.floor(e.d)) } end
    local v = lib.inputDialog('Choose what to pick up', { { type = 'multi-select', label = 'Items (nearest first)', options = opts, searchable = true, required = true } })
    if not v or not v[1] or #v[1] == 0 then return end
    local n = lib.callback.await('opslabs-towers:fixture:deleteMany', false, v[1])
    lib.notify({ type = 'success', description = ('Picked up %d'):format(n or 0) })
    Wait(250)
end

local function editSign(f)
    local cur = (f.data and f.data.lines) or RW.SignDefault
    local v = lib.inputDialog('Works sign', {
        { type = 'input', label = 'Heading', icon = 'heading', default = cur[1], max = 40 },
        { type = 'input', label = 'Second line', icon = 'font', default = cur[2], max = 40 },
        { type = 'input', label = 'Dates', icon = 'calendar', description = 'e.g. Mon 06/10 – Fri 10/10', default = cur[3], max = 40 },
        { type = 'input', label = 'Times', icon = 'clock', description = 'e.g. 08:00 – 18:00', default = cur[4], max = 40 },
        { type = 'input', label = 'Footer', icon = 'phone', description = 'Company, phone number or apology', default = cur[5], max = 40 },
    })
    if not v then return nil end
    return { lines = { v[1] or '', v[2] or '', v[3] or '', v[4] or '', v[5] or '' } }
end

local function save(f, extra)
    local d = { id = f.id, model = f.model, x = f.x, y = f.y, z = f.z, heading = f.heading }
    for k, val in pairs(extra or {}) do d[k] = val end
    local r = lib.callback.await('opslabs-towers:fixture:save', false, d)
    if not r or r.error then
        lib.notify({ type = 'error', description = (r and r.error == 'not allowed') and 'Only network engineers can set out street works' or (r and r.error) or 'Failed' })
        return nil
    end
    Wait(250)
    return r.fixture
end

local function itemMenu(f)
    local options = {
        { title = labelOf(f.model), description = ('#%d · placed by %s'):format(f.id, f.created_by or '?'), icon = 'triangle-exclamation', iconColor = '#ff9f0a', readOnly = true },
    }
    if f.model == 'opslabs_rw_sign' then
        local lines = (f.data and f.data.lines) or RW.SignDefault
        options[#options + 1] = { title = 'Edit the sign', description = ('%s · %s · %s'):format(lines[1] or '', lines[3] or '', lines[4] or ''), icon = 'pen-to-square', iconColor = '#0a84ff', onSelect = function()
            local data = editSign(f)
            if data then f = save(f, { data = data }) or f end
            itemMenu(f)
        end }
    elseif f.model == 'opslabs_rw_tlight' then
        local phase = (f.data and f.data.phase) or 0
        options[#options + 1] = { title = ('Side %s — tap to swap'):format(phase == 1 and 'B' or 'A'), description = 'Put one light on A and the other on B: one is green while the other is red', icon = 'traffic-light', iconColor = '#30d158', onSelect = function()
            f = save(f, { data = { phase = phase == 1 and 0 or 1 } }) or f
            itemMenu(f)
        end }
    end
    options[#options + 1] = { title = 'Move · aim & place', icon = 'up-down-left-right', iconColor = '#0a84ff', onSelect = function()
        local spot = PlacementMode('fixture', f.model == 'opslabs_rw_sign' and 'opslabs_rw_sign_1' or f.model, 1.0, f.heading, 'Moving ' .. labelOf(f.model):lower(), { onFrame = ruler(f.id) })
        if spot then f = save(f, { x = spot.x, y = spot.y, z = spot.z, heading = spot.heading }) or f end
        itemMenu(f)
    end }
    options[#options + 1] = { title = 'Pick it up', icon = 'trash', iconColor = '#ff453a', onSelect = function()
        lib.callback.await('opslabs-towers:fixture:delete', false, f.id)
        Wait(250)
        RoadworksMenu()
    end }
    lib.registerContext({ id = 'rw_item', title = labelOf(f.model), menu = 'rw_main', onBack = function() RoadworksMenu() end, options = options })
    lib.showContext('rw_item')
end

RoadworksMenu = function()
    local options = {}
    for _, e in ipairs(RW.Items) do
        options[#options + 1] = { title = 'Place: ' .. e.label, description = e.sizes and (#e.sizes .. ' sizes') or nil, icon = e.sign and 'sign-hanging' or e.light and 'traffic-light' or 'triangle-exclamation', iconColor = '#ff9f0a', onSelect = function()
            local data
            local modelName = sizeChoice(e)
            if not modelName then return RoadworksMenu() end
            if e.sign then data = editSign({}) if not data then return RoadworksMenu() end end
            if e.light then data = { phase = 0 } end
            local spot = PlacementMode('fixture', e.sign and 'opslabs_rw_sign_1' or modelName, 1.0, nil, 'Placing ' .. labelOf(modelName):lower(), { onFrame = ruler() })
            if spot then
                save({ model = modelName, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading }, { data = data })
            end
            RoadworksMenu()
        end }
    end
    options[#options + 1] = { title = 'Lay a line of cones, barriers or tape', description = 'Click the start, aim at the end — the row is previewed before you place it', icon = 'grip-lines', iconColor = '#30d158', onSelect = function()
        local lineItems = {}
        for _, e in ipairs(RW.Items) do if not e.sign and not e.light then lineItems[#lineItems + 1] = e end end
        local opts = {}
        for _, e in ipairs(lineItems) do
            for _, sz in ipairs(e.sizes or { { model = e.model, label = '' } }) do opts[#opts + 1] = { value = sz.model, label = e.label .. (sz.label ~= '' and (' · ' .. sz.label) or '') } end
        end
        local v = lib.inputDialog('Line of road safety kit', {
            { type = 'select', label = 'What', options = opts, default = 'opslabs_rw_cone', required = true },
            { type = 'slider', label = 'Cone spacing (metres)', description = 'Barriers and tape are laid end to end', min = 0.5, max = 10, step = 0.5, default = 2 },
        })
        if v then lineMode(v[1], v[2]) end
        RoadworksMenu()
    end }
    local nCount = 0
    for _, f in ipairs(rwFixtures()) do if #(GetEntityCoords(PlayerPedId()) - vector3(f.x, f.y, f.z)) < 100 then nCount = nCount + 1 end end
    options[#options + 1] = { title = 'Pick up by aiming', description = 'Aim — it outlines red — and hold', icon = 'crosshairs', iconColor = '#ff453a', disabled = nCount == 0, onSelect = function() removeAim() RoadworksMenu() end }
    options[#options + 1] = { title = 'Pick up everything nearby…', description = 'All of a type within a distance you choose', icon = 'trash', iconColor = '#ff453a', disabled = nCount == 0, onSelect = function() removeNearby() RoadworksMenu() end }
    options[#options + 1] = { title = ('Choose items to pick up… (%d nearby)'):format(nCount), icon = 'list-check', iconColor = '#ff453a', disabled = nCount == 0, onSelect = function() removePick() RoadworksMenu() end }
    local pos = GetEntityCoords(PlayerPedId())
    local near = {}
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f.model:find('^opslabs_rw_') then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d < 80 then near[#near + 1] = { f = f, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#near, 25) do
        local f = near[i].f
        options[#options + 1] = { title = labelOf(f.model), description = ('%dm away%s'):format(math.floor(near[i].d),
            f.model == 'opslabs_rw_tlight' and (' · side ' .. (((f.data and f.data.phase) == 1) and 'B' or 'A')) or f.model == 'opslabs_rw_sign' and (' · ' .. (((f.data and f.data.lines) or RW.SignDefault)[3] or '')) or ''),
            icon = 'location-dot', arrow = true, onSelect = function() itemMenu(f) end }
    end
    lib.registerContext({ id = 'rw_main', title = 'Road safety equipment', menu = 'cable_main', onBack = function() if OpenCableMenu then OpenCableMenu() end end, options = options })
    lib.showContext('rw_main')
end
OpenRoadworksMenu = RoadworksMenu

--- Branding & info on a metal pole (company, colour, pole number, phone, extra line)
function EditPoleBranding(f, after)
    local b = (f.data and f.data.brand) or {}
    local colours = {}
    for _, c in ipairs(Config.Cabling.BrandColors or {}) do colours[#colours + 1] = { value = c[1], label = c[2] } end
    local v = lib.inputDialog('Pole branding & info', {
        { type = 'input', label = 'Company name', icon = 'building', default = b.name or '', max = 32, required = true },
        { type = 'select', label = 'Brand colour', icon = 'palette', options = colours, default = b.color or '#0a84ff' },
        { type = 'input', label = 'Pole number', icon = 'hashtag', default = b.number or ('POLE ' .. f.id), max = 24 },
        { type = 'input', label = 'Phone / emergency contact', icon = 'phone', default = b.phone or '', max = 32 },
        { type = 'input', label = 'Extra line', icon = 'circle-info', description = 'e.g. website, “Do not climb”, network name', default = b.extra or '', max = 40 },
    })
    if v then
        local data = { brand = { name = v[1], color = v[2], number = v[3], phone = v[4], extra = v[5] } }
        if f.data and f.data.status then data.status = f.data.status end
        local r = lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = f.x, y = f.y, z = f.z, heading = f.heading, data = data })
        if r and r.ok then lib.notify({ type = 'success', description = 'Pole plate updated' }) Wait(250)
        else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    if after then after() end
end

-- walk-in buildings: light the inside (the ceiling panels glow; this adds real light) — layouts in Config.Buildings
local BUILDING_LIGHTS = {}
for model, lay in pairs(Config.Buildings or {}) do if lay.lights then BUILDING_LIGHTS[model] = lay.lights end end
CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local near = {}
        for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
            if BUILDING_LIGHTS[f.model] and #(pos - vector3(f.x, f.y, f.z)) < 50.0 and (not BuildingPowered or BuildingPowered(f)) then near[#near + 1] = f end
        end
        if #near == 0 then Wait(1000) else
            for _ = 1, 30 do                                     -- re-scan every ~30 frames
                for _, f in ipairs(near) do
                    local L = BUILDING_LIGHTS[f.model]
                    local h = math.rad(f.heading or 0.0)
                    local c, s = math.cos(h), math.sin(h)
                    for _, set in ipairs({ L, L.low }) do
                        for _, p in ipairs(set.pts) do
                            local x, y = f.x + p[1] * c - p[2] * s, f.y + p[1] * s + p[2] * c
                            DrawLightWithRange(x, y, f.z + set.z, L.rgb[1], L.rgb[2], L.rgb[3], L.range, L.power)
                        end
                    end
                end
                Wait(0)
            end
        end
    end
end)

--- fence panels / bollards in a row (Buildings & sites → Security & fencing → Lay a fence line)
FenceLine = function(modelName, spacing) lineMode(modelName, spacing or 2.5) end
