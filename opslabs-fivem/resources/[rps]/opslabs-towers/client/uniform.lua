-- OPS Network uniform: put it on / take it off (your own clothes come back), branded hard hat, hi-vis back print and
-- chest badge that everyone sees (player state bag 'opsuniform'). Admins can restyle the clothes and the branding live.

local U = Config.Uniform or {}
local KVP_CIVVIES = 'opslabs_uniform_civvies'
local civvies                                  -- the skin you had on before the uniform
local attached = {}                            -- serverId -> { ped, props = {} }
local fits = {}                                -- fitted attachments: ped model .. piece -> { pos, rot, order, bone }

CreateThread(function()
    Wait(1500)
    local u = lib.callback.await('opslabs-towers:uniform:get', false)
    if u then U = u end
end)
RegisterNetEvent('opslabs-towers:uniform', function(u)
    U = u
    fits = {}
    for sid, a in pairs(attached) do for _, e in ipairs(a.props) do if DoesEntityExist(e) then DeleteEntity(e) end end attached[sid] = nil end
end)

local function hasSkinchanger() return GetResourceState('skinchanger') == 'started' end
local function isFemale(ped) return GetEntityModel(ped) == joaat('mp_f_freemode_01') end

local COMPONENTS = {   -- skinchanger key, texture key, ped component (or prop) id, label
    { 'torso_1', 'torso_2', 11, 'Jacket / top' }, { 'tshirt_1', 'tshirt_2', 8, 'Undershirt / hi-vis' }, { 'bproof_1', 'bproof_2', 9, 'Vest' },
    { 'arms', 'arms_2', 3, 'Arms / gloves' }, { 'pants_1', 'pants_2', 4, 'Trousers' }, { 'shoes_1', 'shoes_2', 6, 'Boots' },
    { 'decals_1', 'decals_2', 10, 'Decals' }, { 'chain_1', 'chain_2', 7, 'Neck / tool lanyard' }, { 'bags_1', 'bags_2', 5, 'Bag / harness' },
    { 'mask_1', 'mask_2', 1, 'Mask' }, { 'helmet_1', 'helmet_2', 0, 'Hat (game)', true }, { 'glasses_1', 'glasses_2', 1, 'Safety glasses', true },
}

--- put a set of skinchanger values on the ped (through skinchanger when it's running, natives otherwise)
local function applySet(set)
    local ped = PlayerPedId()
    if hasSkinchanger() then
        TriggerEvent('skinchanger:getSkin', function(skin) TriggerEvent('skinchanger:loadClothes', skin, set) end)
        return
    end
    for _, c in ipairs(COMPONENTS) do
        local d, t = set[c[1]], set[c[2]] or 0
        if d then
            if c[5] then
                if d < 0 then ClearPedProp(ped, c[3]) else SetPedPropIndex(ped, c[3], d, t, true) end
            else
                SetPedComponentVariation(ped, c[3], d, t, 0)
            end
        end
    end
end

local function wearing() return LocalPlayer.state.opsuniform ~= nil end

function WearUniform(hat)
    local ped = PlayerPedId()
    local model = GetEntityModel(ped)
    if model ~= joaat('mp_m_freemode_01') and model ~= joaat('mp_f_freemode_01') then
        return lib.notify({ type = 'error', description = 'The uniform only fits freemode characters' })
    end
    if not wearing() and hasSkinchanger() then
        TriggerEvent('skinchanger:getSkin', function(skin)
            civvies = skin
            SetResourceKvp(KVP_CIVVIES, json.encode(skin))
        end)
    end
    if not lib.progressBar({ duration = 3500, label = 'Getting changed', canCancel = true, disable = { move = true, combat = true, car = true },
        anim = { dict = 'clothingtie', clip = 'try_tie_neutral_a' } }) then return end
    applySet(isFemale(ped) and U.Female or U.Male)
    LocalPlayer.state:set('opsuniform', { hat = hat ~= false }, true)
    lib.notify({ type = 'success', description = 'You’re in OPS Network uniform' })
end

function RemoveUniform()
    if not wearing() then return end
    if not lib.progressBar({ duration = 3000, label = 'Getting changed', canCancel = true, disable = { move = true, combat = true, car = true },
        anim = { dict = 'clothingtie', clip = 'try_tie_neutral_a' } }) then return end
    LocalPlayer.state:set('opsuniform', nil, true)
    if not civvies then
        local ok, s = pcall(json.decode, GetResourceKvpString(KVP_CIVVIES) or '')
        if ok then civvies = s end
    end
    if civvies and hasSkinchanger() then TriggerEvent('skinchanger:loadSkin', civvies) end
    lib.notify({ description = 'Back in your own clothes' })
end

---------------------------------------------------------------------------
-- branded pieces on everyone wearing the uniform
---------------------------------------------------------------------------
local function loadModel(m)
    local h = joaat(m)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    return h
end

---------------------------------------------------------------------------
-- auto-fit: measure the bone's axes in the world, work out the rotation that makes the print face the right way,
-- and find the Euler convention the game uses (tested on a free probe, so no guessing).
---------------------------------------------------------------------------
local function v3(x, y, z) return vector3(x, y, z) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function norm(a) local l = math.sqrt(dot(a, a)) return l > 1e-6 and a / l or a end

-- R = R_i(t1) R_j(t2) R_k(t3) for each axis order, as (x, y, z) angles in degrees
local PERMS = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
local function parity(p) return (p[1] == 1 and p[2] == 2) or (p[1] == 2 and p[2] == 3) or (p[1] == 3 and p[2] == 1) end
local function decompose(R, p)
    local i, j, k = p[1], p[2], p[3]
    local sgn = parity(p) and 1 or -1
    local t2 = math.asin(math.max(-1.0, math.min(1.0, sgn * R[i][k])))
    local t1 = math.atan(-sgn * R[j][k], R[k][k])
    local t3 = math.atan(-sgn * R[i][j], R[i][i])
    local ang = {}
    ang[i], ang[j], ang[k] = math.deg(t1), math.deg(t2), math.deg(t3)
    return ang
end
local function transpose(R) return { { R[1][1], R[2][1], R[3][1] }, { R[1][2], R[2][2], R[3][2] }, { R[1][3], R[2][3], R[3][3] } } end

local probe
local function getProbe()
    if probe and DoesEntityExist(probe) then return probe end
    local h = loadModel('opslabs_uniform_badge')
    if not h then return nil end
    local p = GetEntityCoords(PlayerPedId())
    probe = CreateObjectNoOffset(h, p.x, p.y, p.z - 50.0, false, false, false)
    SetEntityVisible(probe, false, false) SetEntityCollision(probe, false, false) FreezeEntityPosition(probe, true)
    return probe
end

local convention                     -- { perm, transposed, order }
local function axesOf(e)
    local r, f, u = GetEntityMatrix(e)
    return norm(r), norm(f), norm(u)
end
local function matErr(e, R)          -- R columns = wanted world axes (x, y, z)
    local r, f, u = axesOf(e)
    local err = 0.0
    for c, ax in ipairs({ r, f, u }) do
        err = err + math.abs(ax.x - R[1][c]) + math.abs(ax.y - R[2][c]) + math.abs(ax.z - R[3][c])
    end
    return err
end
-- two unrelated test rotations: a convention that reproduces both is the game's convention
local function rotm(axis, deg)
    local a = math.rad(deg)
    local c, sn = math.cos(a), math.sin(a)
    if axis == 1 then return { { 1, 0, 0 }, { 0, c, -sn }, { 0, sn, c } } end
    if axis == 2 then return { { c, 0, sn }, { 0, 1, 0 }, { -sn, 0, c } } end
    return { { c, -sn, 0 }, { sn, c, 0 }, { 0, 0, 1 } }
end
local function mul(A, B2)
    local C = {}
    for i = 1, 3 do C[i] = {} for j = 1, 3 do C[i][j] = A[i][1] * B2[1][j] + A[i][2] * B2[2][j] + A[i][3] * B2[3][j] end end
    return C
end
local TESTS = { mul(rotm(3, 37), mul(rotm(1, 23), rotm(2, -61))), mul(rotm(2, 118), mul(rotm(3, -44), rotm(1, 71))) }

local function solve(R, c)
    local ang = decompose(c.tr and transpose(R) or R, c.perm)
    if c.neg then ang = { -ang[1], -ang[2], -ang[3] } end
    return ang
end

local function anglesFor(R)
    local pr = getProbe()
    if not pr then return { 0.0, 0.0, 0.0 }, 2 end
    if not convention then
        for _, p in ipairs(PERMS) do
            for _, tr in ipairs({ false, true }) do
                for k = 0, 11 do
                    local order, neg = k % 6, k >= 6
                    local c = { perm = p, tr = tr, neg = neg, order = order }
                    local ok = true
                    for _, T in ipairs(TESTS) do
                        local ang = solve(T, c)
                        SetEntityRotation(pr, ang[1], ang[2], ang[3], order, false)
                        if matErr(pr, T) > 0.02 then ok = false break end
                    end
                    if ok then convention = c break end
                end
                if convention then break end
            end
            if convention then break end
        end
        if not convention then return { 0.0, 0.0, 0.0 }, 2 end
    end
    return solve(R, convention), convention.order
end

local function fit(ped, key, b)
    local cacheKey = GetEntityModel(ped) .. ':' .. key .. ':' .. b.at.up .. ':' .. b.at.forward .. ':' .. b.at.right
    if fits[cacheKey] then return fits[cacheKey] end
    local pr = getProbe()
    if not pr then return nil end
    local bone = GetPedBoneIndex(ped, b.bone)
    FreezeEntityPosition(pr, false)
    AttachEntityToEntity(pr, ped, bone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    Wait(0) Wait(0)
    local bx, by, bz = axesOf(pr)
    local B = GetEntityCoords(pr)
    DetachEntity(pr, false, false)
    FreezeEntityPosition(pr, true)
    -- the body's frame: forward, right, up
    local fw = GetEntityForwardVector(ped)
    fw = norm(v3(fw.x, fw.y, 0.0))
    local up = v3(0.0, 0.0, 1.0)
    local right = v3(fw.y, -fw.x, 0.0)
    local P = B + up * b.at.up + fw * b.at.forward + right * b.at.right
    local d = P - B
    local pos = { dot(d, bx), dot(d, by), dot(d, bz) }
    -- which way the piece faces: models face -Y with +X to the right of someone looking at them
    local X, Y
    if b.face == 'back' then X, Y = right, fw
    elseif b.face == 'front' then X, Y = -right, -fw
    else X, Y = -right, -fw end                                       -- hat: peak (−Y) forward
    local Z = up
    local function local3(v) return { dot(v, bx), dot(v, by), dot(v, bz) } end
    local x, y, z = local3(X), local3(Y), local3(Z)
    local R = { { x[1], y[1], z[1] }, { x[2], y[2], z[2] }, { x[3], y[3], z[3] } }
    local rot, order = anglesFor(R)
    local res = { pos = pos, rot = rot, order = order, bone = bone }
    fits[cacheKey] = res
    return res
end

local function attachPiece(ped, key, b)
    if not b or not b.at then return nil end
    local h = loadModel(b.model)
    if not h then return nil end
    local F = fit(ped, key, b)
    if not F then return nil end
    local p = GetEntityCoords(ped)
    local e = CreateObjectNoOffset(h, p.x, p.y, p.z + 2.0, false, false, false)
    SetEntityCollision(e, false, false)
    AttachEntityToEntity(e, ped, F.bone, F.pos[1], F.pos[2], F.pos[3], F.rot[1], F.rot[2], F.rot[3], false, false, false, false, F.order, true)
    return e
end

local function dress(sid, ped, st)
    local a = { ped = ped, props = {}, hat = st.hat }
    attached[sid] = a                                   -- claim it first (fitting waits a couple of frames)
    local B = U.Branding or {}
    for _, k in ipairs({ 'back', 'badge' }) do
        local e = attachPiece(ped, k, B[k])
        if e then a.props[#a.props + 1] = e end
    end
    if st.hat then
        local e = attachPiece(ped, 'hat', B.hat)
        if e then a.props[#a.props + 1] = e end
    end
end

local function undress(sid)
    local a = attached[sid]
    if not a then return end
    for _, e in ipairs(a.props) do if DoesEntityExist(e) then DeleteEntity(e) end end
    attached[sid] = nil
end

CreateThread(function()
    while true do
        Wait(800)
        local seen = {}
        local me = GetEntityCoords(PlayerPedId())
        for _, pid in ipairs(GetActivePlayers()) do
            local sid = GetPlayerServerId(pid)
            local ped = GetPlayerPed(pid)
            local st = Player(sid).state.opsuniform
            if st and DoesEntityExist(ped) and #(me - GetEntityCoords(ped)) < 120.0 then
                seen[sid] = true
                local a = attached[sid]
                if a and a.adjusting then goto continue end
                if a and (a.ped ~= ped or a.hat ~= st.hat) then undress(sid) a = nil end
                if not a then dress(sid, ped, st) end
            end
            ::continue::
        end
        for sid, a in pairs(attached) do if not seen[sid] and not a.adjusting then undress(sid) end end
    end
end)

---------------------------------------------------------------------------
-- admin: design the clothes live, adjust where the branding sits
---------------------------------------------------------------------------
local function design()
    local ped = PlayerPedId()
    local female = isFemale(ped)
    local set = {}
    for k, v in pairs((female and U.Female or U.Male) or {}) do set[k] = v end
    applySet(set)
    local options, map = {}, {}
    local function range(n, from)
        local t = {}
        for i = from, n - 1 do t[#t + 1] = tostring(i) end
        if #t == 0 then t[1] = tostring(from) end
        return t
    end
    for _, c in ipairs(COMPONENTS) do
        local prop = c[5]
        local nd = prop and GetNumberOfPedPropDrawableVariations(ped, c[3]) or GetNumberOfPedDrawableVariations(ped, c[3])
        local from = prop and -1 or 0
        local values = range(nd, from)
        local cur = set[c[1]] or from
        options[#options + 1] = { label = c[4], values = values, defaultIndex = math.max(1, cur - from + 1), description = c[1] }
        map[#options] = { key = c[1], texKey = c[2], comp = c[3], prop = prop, from = from, kind = 'drawable' }
        local nt = prop and (cur >= 0 and GetNumberOfPedPropTextureVariations(ped, c[3], cur) or 1) or GetNumberOfPedTextureVariations(ped, c[3], cur)
        options[#options + 1] = { label = '   colour', values = range(math.max(1, nt), 0), defaultIndex = (set[c[2]] or 0) + 1, description = c[2] }
        map[#options] = { key = c[2], comp = c[3], prop = prop, from = 0, kind = 'texture', drawableKey = c[1] }
    end
    options[#options + 1] = { label = 'Save for every ' .. (female and 'female' or 'male') .. ' engineer', icon = 'floppy-disk' }
    local saveIndex = #options
    lib.registerMenu({ id = 'uniform_design', title = 'Design the uniform', position = 'top-right', options = options,
        onSideScroll = function(selected, scrollIndex)
            local m = map[selected]
            if not m then return end
            local v = m.from + scrollIndex - 1
            set[m.key] = v
            if m.kind == 'drawable' then set[m.key:gsub('_1$', '_2'):gsub('^arms$', 'arms_2')] = 0 end
            applySet(set)
        end,
    }, function(selected)
        if selected == saveIndex then
            local r = lib.callback.await('opslabs-towers:uniform:save', false, female and 'Female' or 'Male', set)
            lib.notify({ type = r and r.ok and 'success' or 'error', description = r and r.ok and 'Uniform saved for everyone' or (r and r.error) or 'Failed' })
        end
    end)
    lib.showMenu('uniform_design')
end

local function adjustBranding()
    if not wearing() then return lib.notify({ type = 'error', description = 'Put the uniform on first' }) end
    local v = lib.inputDialog('Adjust the branding', { { type = 'select', label = 'Which piece', options = {
        { value = 'back', label = 'Back print' }, { value = 'badge', label = 'Chest logo' }, { value = 'hat', label = 'Hard hat' } }, default = 'back', required = true } })
    if not v then return end
    local key = v[1]
    local B = {}
    for k, b in pairs(U.Branding or {}) do B[k] = { model = b.model, bone = b.bone, face = b.face, at = { up = b.at.up, forward = b.at.forward, right = b.at.right } } end
    local b = B[key]
    local ped = PlayerPedId()
    local sid = GetPlayerServerId(PlayerId())
    undress(sid)
    attached[sid] = { ped = ped, props = {}, hat = (LocalPlayer.state.opsuniform or {}).hat, adjusting = true }
    local e = attachPiece(ped, key, b)
    local sf = PlaceHud.buttons({ { 'Up / down', { 172, 173 } }, { 'Left / right', { 174, 175 } }, { 'In / out', { 10, 11 } }, { 'Fine', 21 }, { 'Save', 191 }, { 'Cancel', 177 } })
    local save, last = false, ''
    while true do
        Wait(0)
        for _, c in ipairs({ 10, 11, 172, 173, 174, 175, 177, 191 }) do DisableControlAction(0, c, true) end
        local s = IsControlPressed(0, 21) and 0.001 or 0.004
        local out = key == 'back' and -1 or 1                         -- "out" is away from the body
        if IsDisabledControlPressed(0, 172) then b.at.up = b.at.up + s end
        if IsDisabledControlPressed(0, 173) then b.at.up = b.at.up - s end
        if IsDisabledControlPressed(0, 174) then b.at.right = b.at.right - s end
        if IsDisabledControlPressed(0, 175) then b.at.right = b.at.right + s end
        if IsDisabledControlPressed(0, 10) then b.at.forward = b.at.forward + s * out end
        if IsDisabledControlPressed(0, 11) then b.at.forward = b.at.forward - s * out end
        local sig = ('%.3f|%.3f|%.3f'):format(b.at.up, b.at.forward, b.at.right)
        if sig ~= last then
            last = sig
            if e and DoesEntityExist(e) then DeleteEntity(e) end
            e = attachPiece(ped, key, b)
        end
        PlaceHud.draw(sf, 'Adjusting · ' .. key, ('up %.3f · forward %.3f · right %.3f'):format(b.at.up, b.at.forward, b.at.right))
        if IsDisabledControlJustPressed(0, 191) then save = true break end
        if IsDisabledControlJustPressed(0, 177) then break end
    end
    PlaceHud.release(sf)
    if e and DoesEntityExist(e) then DeleteEntity(e) end
    attached[sid] = nil
    if save then
        local res = lib.callback.await('opslabs-towers:uniform:save', false, 'Branding', B)
        lib.notify({ type = res and res.ok and 'success' or 'error', description = res and res.ok and 'Branding position saved for everyone' or (res and res.error) or 'Failed' })
    end
end

---------------------------------------------------------------------------
-- menu
---------------------------------------------------------------------------
function UniformMenu()
    local on = wearing()
    local st = LocalPlayer.state.opsuniform or {}
    local options = {
        { title = on and 'Take the uniform off' or 'Put the uniform on', description = on and 'Back into your own clothes' or (U.Name or 'OPS Network engineer') .. ' · hi-vis, boots, branded back print & badge',
            icon = on and 'shirt' or 'user-tie', iconColor = '#0a84ff', onSelect = function() if on then RemoveUniform() else WearUniform(true) end end },
    }
    if on then
        options[#options + 1] = { title = st.hat and 'Take the hard hat off' or 'Put the hard hat on', icon = 'helmet-safety', iconColor = '#ffd60a',
            onSelect = function() LocalPlayer.state:set('opsuniform', { hat = not st.hat }, true) end }
    end
    options[#options + 1] = { title = 'Design the uniform (admins)', description = 'Pick each piece with ← → and see it live · saves for everyone', icon = 'palette', onSelect = function()
        if not lib.callback.await('opslabs-towers:isAdmin', false) then return lib.notify({ type = 'error', description = 'Admins only' }) end
        design()
    end }
    options[#options + 1] = { title = 'Adjust the branding (admins)', description = 'Line up the back print, badge or hard hat on the body', icon = 'up-down-left-right', onSelect = function()
        if not lib.callback.await('opslabs-towers:isAdmin', false) then return lib.notify({ type = 'error', description = 'Admins only' }) end
        adjustBranding()
    end }
    lib.registerContext({ id = 'uniform_menu', title = 'OPS Network uniform', options = options })
    lib.showContext('uniform_menu')
end

RegisterCommand('uniform', function()
    if not lib.callback.await('opslabs-towers:cable:can', false) then return lib.notify({ type = 'error', description = 'Only OPS Network staff have a uniform' }) end
    UniformMenu()
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for sid in pairs(attached) do undress(sid) end
    if probe and DoesEntityExist(probe) then DeleteEntity(probe) end
end)
