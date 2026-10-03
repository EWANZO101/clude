-- Doors, gates and rising bollards on placed buildings / gate frames (layouts in Config.Buildings),
-- plus the live brand boards on fences, signs and gates (12 shared DUI faces).
--   Doors:  [E] open / close · locked → [E] enter the PIN · [H] keypad (lock, set / change PIN)
--   Gates:  open by themselves when you walk or drive up (unless locked); locked → [E] PIN lets you through

local B = Config.Buildings or {}
local CC = Config.Cabling
local STATE = {}            -- [fid][idx] = { open, locked, pin }
local leaves = {}           -- key "fid:idx:leaf" -> record
local RES = GetCurrentResourceName()

---------------------------------------------------------------------------
-- live brand boards (fence signs, branded panels, gate boards)
---------------------------------------------------------------------------
local SIGN_SLOTS = 12
local signSlot, signOf, signDui = {}, {}, {}
local txd
local DEFAULT_BRAND = { name = 'OPS Network', color = '#0a84ff', message = 'Private property · No unauthorised access', phone = '' }

local function enc(v)
    return (tostring(v or ''):gsub('[^%w%-%._~ ]', function(c) return ('%%%02X'):format(c:byte()) end):gsub(' ', '%%20'))
end

local function signUrl(b)
    b = b or DEFAULT_BRAND
    return ('nui://%s/html/fencesign.html?name=%s&color=%s&message=%s&phone=%s'):format(RES, enc(b.name), enc(b.color), enc(b.message), enc(b.phone))
end

local function paintSign(n, brand)
    local url = signUrl(brand)
    local d = signDui[n]
    if not d then
        txd = txd or CreateRuntimeTxd('opslabs_fence_duis')
        local dui = CreateDui(url, 1024, 512)
        CreateRuntimeTextureFromDuiHandle(txd, 'sign_' .. n, GetDuiHandle(dui))
        AddReplaceTexture('opslabs_fencesign_' .. n, 'opslabs_fencesign_' .. n, 'opslabs_fence_duis', 'sign_' .. n)
        signDui[n] = { dui = dui, url = url }
    elseif d.url ~= url then
        SetDuiUrl(d.dui, url)
        d.url = url
    end
end

--- take a live sign face for `key` (returns the slot number, or nil when all 12 are in use nearby)
local function signTake(key, brand)
    local n = signOf[key]
    if not n then
        for i = 1, SIGN_SLOTS do if not signSlot[i] then n = i break end end
        if not n then return nil end
        signSlot[n], signOf[key] = key, n
    end
    paintSign(n, brand)
    return n
end

local function signRelease(key)
    local n = signOf[key]
    if n then signSlot[n], signOf[key] = nil, nil end
end

local function spawn(model, x, y, z, heading, collide)
    local h = joaat(model)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    local e = CreateObjectNoOffset(h, x, y, z, false, false, false)
    SetEntityHeading(e, heading or 0.0)
    SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
    FreezeEntityPosition(e, true)
    if collide == false then SetEntityCollision(e, false, false) end
    SetModelAsNoLongerNeeded(h)
    return e
end

local function brandOf(f) return (f.data and f.data.brand) or DEFAULT_BRAND end

--- the cabling streamer hands branded fixtures to us; true = handled
function BrandSignSpawn(key, f, list)
    if f.model == 'opslabs_fence_sign' then
        local n = signTake(key, brandOf(f))
        list[1] = spawn(n and ('opslabs_fencesign_' .. n) or 'opslabs_fence_sign', f.x, f.y, f.z, f.heading)
        return true
    elseif f.model == 'opslabs_fence_brand' then
        local e = spawn(f.model, f.x, f.y, f.z, f.heading)
        if not e then return true end
        list[1] = e
        local n = signTake(key, brandOf(f))
        if n then
            local p = GetOffsetFromEntityInWorldCoords(e, 0.0, -0.1, 1.35)
            list[2] = spawn('opslabs_fencesign_' .. n, p.x, p.y, p.z, f.heading, false)
        end
        return true
    end
    return false
end

function BrandSignDespawn(key) signRelease(key) end

--- Branding on a fence board, sign or gate (company, colour, message, phone)
function EditBrandSign(f, after)
    local b = (f.data and f.data.brand) or {}
    local colours = {}
    for _, c in ipairs(CC.BrandColors or {}) do colours[#colours + 1] = { value = c[1], label = c[2] } end
    local v = lib.inputDialog('Branding', {
        { type = 'input', label = 'Company name', icon = 'building', default = b.name or 'OPS Network', max = 32, required = true },
        { type = 'select', label = 'Brand colour', icon = 'palette', options = colours, default = b.color or '#0a84ff' },
        { type = 'input', label = 'Message', icon = 'message', description = 'e.g. “Private property · No unauthorised access”, “Depot — deliveries round the back”',
          default = b.message or DEFAULT_BRAND.message, max = 48 },
        { type = 'input', label = 'Phone / contact', icon = 'phone', default = b.phone or '', max = 32 },
    })
    if v then
        local r = lib.callback.await('opslabs-towers:fixture:save', false, { id = f.id, x = f.x, y = f.y, z = f.z, heading = f.heading,
            data = { brand = { name = v[1], color = v[2], message = v[3], phone = v[4] } } })
        if r and r.ok then lib.notify({ type = 'success', description = 'Branding updated' }) Wait(250)
        else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    end
    if after then after() end
end

---------------------------------------------------------------------------
-- door / gate state
---------------------------------------------------------------------------
local function stateOf(fid, idx)
    return (STATE[fid] or {})[idx] or { open = false, locked = false, pin = false }
end

RegisterNetEvent('opslabs-towers:door', function(fid, idx, s)
    STATE[fid] = STATE[fid] or {}
    STATE[fid][idx] = s
end)

CreateThread(function()
    Wait(1500)
    local all = lib.callback.await('opslabs-towers:door:states', false) or {}
    for fid, doors in pairs(all) do
        fid = tonumber(fid)
        STATE[fid] = STATE[fid] or {}
        for idx, s in pairs(doors) do STATE[fid][tonumber(idx)] = s end
    end
end)

---------------------------------------------------------------------------
-- leaves: spawn, move
---------------------------------------------------------------------------
local SPEED = { swing = 1.5, slide = 0.22, lift = 0.7, sink = 0.8, shutter = 0.25 }

local function leafKind(lf)
    return lf.slide and 'slide' or lf.sink and 'sink' or lf.lift and 'lift' or lf.shutter and 'shutter' or 'swing'
end

local function leafBase(f, lf)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    local x = f.x + lf.hinge[1] * c - lf.hinge[2] * s
    local y = f.y + lf.hinge[1] * s + lf.hinge[2] * c
    return x, y, f.z + (lf.z or 0.0), (f.heading or 0.0) + (lf.h or 0.0)
end

local function apply(L)
    local e, lf, t = L.ent, L.lf, L.t
    if not DoesEntityExist(e) then return end
    local k = L.kind
    if k == 'slide' then
        local r = math.rad(L.bh)
        SetEntityCoordsNoOffset(e, L.x - math.cos(r) * lf.slide * t, L.y - math.sin(r) * lf.slide * t, L.z, false, false, false)
        SetEntityRotation(e, 0.0, 0.0, L.bh, 2, false)
    elseif k == 'sink' then
        SetEntityCoordsNoOffset(e, L.x, L.y, L.z - lf.sink * t, false, false, false)
    elseif k == 'lift' then
        SetEntityRotation(e, 0.0, -lf.lift * t, L.bh, 2, false)
    elseif k == 'shutter' then
        SetEntityRotation(e, 90.0 * t, 0.0, L.bh, 2, false)
    else
        SetEntityRotation(e, 0.0, 0.0, L.bh + (lf.swing or 1) * 90.0 * t, 2, false)
    end
end

local function removeLeaf(key)
    local L = leaves[key]
    if not L then return end
    if L.sign and DoesEntityExist(L.sign) then DeleteEntity(L.sign) end
    if DoesEntityExist(L.ent) then DeleteEntity(L.ent) end
    signRelease('leaf:' .. key)
    leaves[key] = nil
end

local function makeLeaf(key, f, idx, d, li, lf)
    local x, y, z, bh = leafBase(f, lf)
    local e = spawn(lf.kind, x, y, z, bh)
    if not e then return end
    local open = stateOf(f.id, idx).open and 1.0 or 0.0
    local L = { ent = e, fid = f.id, idx = idx, d = d, lf = lf, x = x, y = y, z = z, bh = bh, kind = leafKind(lf), t = open, target = open,
                sig = ('%.2f|%.2f|%.2f|%.1f|%s'):format(f.x, f.y, f.z, f.heading or 0, f.data and json.encode(f.data.brand or {}) or '') }
    if lf.sign then
        local n = signTake('leaf:' .. key, brandOf(f))
        if n then
            local s = spawn('opslabs_fencesign_' .. n, x, y, z, bh, false)
            if s then
                FreezeEntityPosition(s, false)
                AttachEntityToEntity(s, e, 0, lf.sign[1], lf.sign[2], lf.sign[3], 0.0, 0.0, 0.0, false, false, false, false, 2, true)
                L.sign = s
            end
        end
    end
    leaves[key] = L
    apply(L)
end

-- keep leaves in step with the buildings / gates around you
CreateThread(function()
    while true do
        Wait(400)
        local pos = GetEntityCoords(PlayerPedId())
        local seen = {}
        for fid, f in pairs(CablingFixtures and CablingFixtures() or {}) do
            local lay = B[f.model]
            if lay and lay.doors and #(pos - vector3(f.x, f.y, f.z)) < 90.0 then
                for idx, d in ipairs(lay.doors) do
                    for li, lf in ipairs(d.leaves or { d }) do
                        local key = fid .. ':' .. idx .. ':' .. li
                        seen[key] = true
                        local L = leaves[key]
                        local sig = ('%.2f|%.2f|%.2f|%.1f|%s'):format(f.x, f.y, f.z, f.heading or 0, f.data and json.encode(f.data.brand or {}) or '')
                        if L and L.sig ~= sig then removeLeaf(key) L = nil end
                        if not L then makeLeaf(key, f, idx, d, li, lf) L = leaves[key] end
                        if L then L.target = stateOf(fid, idx).open and 1.0 or 0.0 end
                    end
                end
            end
        end
        for key in pairs(leaves) do if not seen[key] then removeLeaf(key) end end
    end
end)

-- animate
CreateThread(function()
    local last = GetGameTimer()
    while true do
        local moving = false
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000.0)
        last = now
        for _, L in pairs(leaves) do
            if L.t ~= L.target then
                local step = (SPEED[L.kind] or 1.0) * dt
                if L.t < L.target then L.t = math.min(L.target, L.t + step) else L.t = math.max(L.target, L.t - step) end
                apply(L)
                moving = true
            end
        end
        Wait(moving and 0 or 150)
    end
end)

---------------------------------------------------------------------------
-- prompts, keypad, gate sensors
---------------------------------------------------------------------------
local function doorCentre(fid, idx)
    local L = leaves[fid .. ':' .. idx .. ':1']
    if not L then return nil end
    local r = math.rad(L.bh)
    local w = L.lf.w or 1.0
    if L.kind == 'shutter' then return vector3(L.x + math.cos(r) * w / 2, L.y + math.sin(r) * w / 2, L.z - 3.6) end
    return vector3(L.x + math.cos(r) * w / 2, L.y + math.sin(r) * w / 2, L.z + 1.0), L
end

local function enterPin(fid, idx, d, keep)
    local v = lib.inputDialog((d.label or 'Door') .. ' · keypad', { { type = 'input', label = 'PIN', icon = 'key', password = true, required = true, min = 4, max = 6 } })
    if not v then return end
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
    local r = lib.callback.await('opslabs-towers:door:unlock', false, fid, idx, v[1], keep)
    if r and r.ok then
        PlaySoundFrontend(-1, 'Hack_Success', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
        lib.notify({ type = 'success', description = d.auto and (keep and 'Unlocked — it opens for everyone now' or 'Access granted') or 'Unlocked' })
    else
        PlaySoundFrontend(-1, 'Hack_Failed', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
        lib.notify({ type = 'error', description = (r and r.error) or 'Failed' })
    end
end

local function setPin(fid, idx, d, hasPin, all)
    local fields = {}
    if hasPin then fields[#fields + 1] = { type = 'input', label = 'Current PIN', icon = 'key', password = true, min = 4, max = 6, description = 'Engineers can leave this empty' } end
    fields[#fields + 1] = { type = 'input', label = 'New PIN (4–6 digits)', icon = 'lock', password = true, required = true, min = 4, max = 6 }
    fields[#fields + 1] = { type = 'input', label = 'New PIN again', icon = 'lock', password = true, required = true, min = 4, max = 6 }
    local v = lib.inputDialog(all and 'Same PIN on every door here' or ((d.label or 'Door') .. ' · set PIN'), fields)
    if not v then return end
    local old, new, again = hasPin and v[1] or nil, v[hasPin and 2 or 1], v[hasPin and 3 or 2]
    if new ~= again then return lib.notify({ type = 'error', description = 'The two PINs don’t match' }) end
    local r = lib.callback.await('opslabs-towers:door:setPin', false, fid, all and 'all' or idx, old, new)
    if r and r.ok then lib.notify({ type = 'success', description = all and ('PIN set on %d doors'):format(r.count or 0) or 'PIN set' })
    else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
end

local function keypadMenu(fid, idx, d)
    local s = stateOf(fid, idx)
    local lay = B[(CablingFixtures()[fid] or {}).model or ''] or {}
    local options = {
        { title = s.locked and 'Locked' or (s.pin and 'Unlocked' or 'No PIN set'), description = d.auto and (s.locked and 'Stays shut — enter the PIN to get through' or 'Opens for anyone who comes up to it')
            or (s.locked and 'Enter the PIN to open it' or 'Anyone can open it'), icon = s.locked and 'lock' or 'lock-open', iconColor = s.locked and '#ff453a' or '#30d158', readOnly = true },
    }
    if s.locked then
        options[#options + 1] = { title = d.auto and 'Enter PIN · let me through' or 'Enter PIN · unlock', icon = 'key', onSelect = function() enterPin(fid, idx, d, false) end }
        if d.auto then options[#options + 1] = { title = 'Enter PIN · keep it unlocked', description = 'Opens for everyone until someone locks it again', icon = 'lock-open', onSelect = function() enterPin(fid, idx, d, true) end } end
    elseif s.pin then
        options[#options + 1] = { title = 'Lock', description = d.auto and 'Only people with the PIN get through' or 'Closes and locks it', icon = 'lock', onSelect = function()
            local r = lib.callback.await('opslabs-towers:door:lock', false, fid, idx, true)
            if r and r.ok then PlaySoundFrontend(-1, 'Hack_Success', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true) lib.notify({ description = 'Locked' })
            else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
        end }
    end
    options[#options + 1] = { title = s.pin and 'Change PIN' or 'Set a PIN', icon = 'hashtag', onSelect = function() setPin(fid, idx, d, s.pin, false) end }
    if lay.doors and #lay.doors > 1 then
        options[#options + 1] = { title = 'Same PIN on every door here', description = ('All %d doors in this building'):format(#lay.doors), icon = 'layer-group', onSelect = function() setPin(fid, idx, d, s.pin, true) end }
    end
    lib.registerContext({ id = 'door_keypad', root = true, title = (d.label or 'Door') .. ' · keypad', options = options })
    lib.showContext('door_keypad')
end

-- nearest door / gate prompt
CreateThread(function()
    local shown, lastText = false, nil
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local inVeh = IsPedInAnyVehicle(ped, false)
        local best, bd, bfid, bidx
        for _, L in pairs(leaves) do
            if L.lf == (L.d.leaves or { L.d })[1] then
                local c = doorCentre(L.fid, L.idx)
                if c then
                    local reach = L.d.auto and (inVeh and L.d.auto or 3.0) or 1.7
                    local dist = #(pos - c)
                    if (not inVeh or L.d.auto) and dist < reach and math.abs(pos.z - c.z) < 3.0 and dist < (bd or 1e9) then
                        best, bd, bfid, bidx = L.d, dist, L.fid, L.idx
                    end
                end
            end
        end
        if best and not lib.getOpenContextMenu() then
            local s = stateOf(bfid, bidx)
            local text
            if best.auto then
                text = s.locked and '[E] Enter PIN  ·  [H] Keypad' or '[H] Keypad  ·  opens automatically'
            else
                text = s.locked and '[E] Locked — enter PIN  ·  [H] Keypad' or (s.open and '[E] Close' or '[E] Open') .. '  ·  [H] Keypad'
            end
            if text ~= lastText then lib.showTextUI(text, { icon = s.locked and 'lock' or 'door-open' }) shown, lastText = true, text end
            if IsControlJustPressed(0, 38) then
                if s.locked and not s.open then enterPin(bfid, bidx, best, false)
                elseif not best.auto then
                    local r = lib.callback.await('opslabs-towers:door:use', false, bfid, bidx)
                    if r and r.error and r.error ~= 'locked' then lib.notify({ type = 'error', description = r.error }) end
                end
            elseif IsControlJustPressed(0, 74) then
                keypadMenu(bfid, bidx, best)
            end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown, lastText = false, nil end
            Wait(best and 100 or 300)
        end
    end
end)

-- gate sensors: tell the server when you (or your vehicle) are at a gate
CreateThread(function()
    local lastSent = {}
    while true do
        Wait(700)
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local inVeh = IsPedInAnyVehicle(ped, false)
        for key, L in pairs(leaves) do
            local d = L.d
            if d.auto and L.lf == (d.leaves or { d })[1] and ((inVeh and d.vehicles) or (not inVeh and d.peds)) then
                local c = doorCentre(L.fid, L.idx)
                local s = stateOf(L.fid, L.idx)
                if c and #(pos - c) < d.auto and (not s.locked or s.open) then
                    local k = L.fid .. ':' .. L.idx
                    if GetGameTimer() - (lastSent[k] or 0) > 2000 then
                        lastSent[k] = GetGameTimer()
                        TriggerServerEvent('opslabs-towers:gate:presence', L.fid, L.idx)
                    end
                end
            end
        end
    end
end)

--- engineers' view of a building's doors (from the fixture menu)
function DoorsMenu(f)
    local lay = B[f.model]
    if not lay or not lay.doors then return end
    local options = {}
    for idx, d in ipairs(lay.doors) do
        local s = stateOf(f.id, idx)
        options[#options + 1] = { title = d.label or ('Door ' .. idx), description = (s.locked and 'Locked' or 'Unlocked') .. ' · ' .. (s.pin and 'PIN set' or 'no PIN') .. ' · ' .. (s.open and 'open' or 'closed'),
            icon = s.locked and 'lock' or 'lock-open', iconColor = s.locked and '#ff453a' or '#30d158', readOnly = true }
    end
    options[#options + 1] = { title = 'Set the same PIN on every door', icon = 'hashtag', onSelect = function()
        local v = lib.inputDialog('PIN for every door', { { type = 'input', label = 'New PIN (4–6 digits)', icon = 'lock', password = true, required = true, min = 4, max = 6 } })
        if v then
            local r = lib.callback.await('opslabs-towers:door:setPin', false, f.id, 'all', nil, v[1])
            lib.notify({ type = r and r.ok and 'success' or 'error', description = r and r.ok and 'PIN set on every door' or (r and r.error) or 'Failed' })
        end
        DoorsMenu(f)
    end }
    options[#options + 1] = { title = 'Clear every PIN & unlock', description = 'Engineers / admins only', icon = 'eraser', iconColor = '#ff9f0a', onSelect = function()
        local r = lib.callback.await('opslabs-towers:door:clearPin', false, f.id, 'all')
        lib.notify({ type = r and r.ok and 'success' or 'error', description = r and r.ok and 'All PINs cleared' or (r and r.error) or 'Failed' })
        Wait(200) DoorsMenu(f)
    end }
    lib.registerContext({ id = 'doors_admin', title = 'Doors & PINs', options = options })
    lib.showContext('doors_admin')
end

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    for key in pairs(leaves) do removeLeaf(key) end
    for n = 1, SIGN_SLOTS do RemoveReplaceTexture('opslabs_fencesign_' .. n, 'opslabs_fencesign_' .. n) end
end)
