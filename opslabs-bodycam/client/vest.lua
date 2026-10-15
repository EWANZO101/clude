-- The black vest and the camera you can see on it (opslabs-props: opslabs_vest_black, opslabs_bodycam / _on).
-- Put on / taken off with the item (Config.Vest.Item) or the command (Config.Vest.Command). The camera clips to the
-- vest's chest dock; while recording it shows its red LEDs. Recording without the vest clips the camera to the shirt
-- (Config.Vest.CameraWithoutVest). The props are networked and attached to you, so everyone sees them.
--
-- The models are built with X = your right, Y = forward, Z = up. SKEL_Spine3's own axes don't line up with that, so
-- the attachment is worked out from the bone's real axes (like the OPS Buds), then moved by the fit
-- (Config.Vest.Fit, or your own from /vestfit).

local V = Config.Vest or {}
if V.Enabled == false then return end

local SPINE3 = 24818
local worn, wornBy = false, nil        -- wornBy: 'item' or 'command'
local recording = false
local vestEnt, camEnt, camOn = nil, nil, nil
local poseCache = {}                   -- ped model → { pos, rot } worked out while standing upright

-- fit -----------------------------------------------------------------------------------------------------------

local function female(ped) return GetEntityModel(ped) == `mp_f_freemode_01` or not IsPedMale(ped) end

local function fit(ped)
    local key = female(ped) and 'female' or 'male'
    local base = (V.Fit or {})[key] or {}
    local mine = json.decode(GetResourceKvpString('vestfit_' .. key) or 'null') or {}
    return {
        forward = (base.forward or 0.0) + (mine.forward or 0.0),
        up = (base.up or 0.0) + (mine.up or 0.0),
        side = (base.side or 0.0) + (mine.side or 0.0),
    }, key, mine
end

local function v3norm(v) local l = #v return l > 1e-6 and v / l or v end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

--- bone-space position + rotation that put a model (X right, Y forward, Z up) on SKEL_Spine3, moved by d (metres,
--- body directions); R = Rz(c)·Rx(a)·Ry(b), GTA rotation order 2
local function spineAttach(ped, d)
    local o = GetPedBoneCoords(ped, SPINE3, 0.0, 0.0, 0.0)
    local bx = v3norm(GetPedBoneCoords(ped, SPINE3, 1.0, 0.0, 0.0) - o)
    local by = v3norm(GetPedBoneCoords(ped, SPINE3, 0.0, 1.0, 0.0) - o)
    local bz = v3norm(GetPedBoneCoords(ped, SPINE3, 0.0, 0.0, 1.0) - o)
    local f = GetEntityForwardVector(ped)
    local fwd = v3norm(vector3(f.x, f.y, 0.0))
    local right = vector3(fwd.y, -fwd.x, 0.0)
    local up = vector3(0.0, 0.0, 1.0)
    local w = right * (d.side or 0.0) + up * (d.up or 0.0) + fwd * (d.forward or 0.0)
    local pos = vector3(dot(w, bx), dot(w, by), dot(w, bz))
    local R = {
        { dot(right, bx), dot(fwd, bx), dot(up, bx) },
        { dot(right, by), dot(fwd, by), dot(up, by) },
        { dot(right, bz), dot(fwd, bz), dot(up, bz) },
    }
    local s = math.max(-1.0, math.min(1.0, R[3][2]))
    local a, b, c = math.asin(s), 0.0, 0.0
    if math.abs(s) < 0.9999 then
        b = math.atan(-R[3][1], R[3][3])
        c = math.atan(-R[1][2], R[2][2])
    else
        c = math.atan(R[2][1], R[1][1])
    end
    return pos, vector3(math.deg(a), math.deg(b), math.deg(c))
end

--- the bone's axes only mean "upright" while the ped stands normally: work it out then and keep it for this model
local function upright(ped)
    return IsPedOnFoot(ped) and not IsPedRagdoll(ped) and not IsPedFalling(ped) and not IsPedInCover(ped, false)
        and not GetPedStealthMovement(ped) and not IsPedDucking(ped) and not IsPlayerFreeAiming(PlayerId()) and GetEntitySpeed(ped) < 2.0
end

local function vestPose(ped, d)
    local key = GetEntityModel(ped)
    local c = poseCache[key]
    if upright(ped) or not c then
        local pos, rot = spineAttach(ped, d)
        c = { pos = pos, rot = rot, d = d }
        if upright(ped) then poseCache[key] = c end
    end
    return c.pos, c.rot
end

-- props -------------------------------------------------------------------------------------------------------------

local function spawn(model)
    local h = joaat(model)
    if not IsModelInCdimage(h) then
        print(('^3[opslabs-bodycam] model %s is not streamed — is opslabs-props started?^7'):format(model))
        return nil
    end
    RequestModel(h)
    local t = GetGameTimer() + 5000
    while not HasModelLoaded(h) and GetGameTimer() < t do Wait(0) end
    if not HasModelLoaded(h) then return nil end
    local p = GetEntityCoords(PlayerPedId())
    local e = CreateObject(h, p.x, p.y, p.z - 5.0, true, true, false)
    SetEntityCollision(e, false, false)
    SetEntityCanBeDamaged(e, false)
    SetModelAsNoLongerNeeded(h)
    return e
end

local function gone(e) return not e or not DoesEntityExist(e) end
local function drop(e) if e and DoesEntityExist(e) then DetachEntity(e, false, false) DeleteEntity(e) end end

local function clear()
    drop(camEnt) drop(vestEnt)
    camEnt, vestEnt, camOn = nil, nil, nil
end

--- make the props match: vest when worn; camera on the vest, or on the shirt while recording without one
local function sync()
    local ped = PlayerPedId()
    local wantCam = worn or (recording and V.CameraWithoutVest ~= false)

    if worn then
        if gone(vestEnt) or not IsEntityAttachedToEntity(vestEnt, ped) then
            drop(vestEnt)
            vestEnt = spawn(V.Model or 'opslabs_vest_black')
            if vestEnt then
                local pos, rot = vestPose(ped, (fit(ped)))
                AttachEntityToEntity(vestEnt, ped, GetPedBoneIndex(ped, SPINE3), pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, false, false, false, true, 2, true)
                drop(camEnt) camEnt = nil      -- the camera goes back on the new vest
            end
        end
    elseif vestEnt then
        drop(vestEnt) vestEnt = nil
        drop(camEnt) camEnt = nil
    end

    if not wantCam then
        if camEnt then drop(camEnt) camEnt, camOn = nil, nil end
        return
    end
    local onVest = worn and not gone(vestEnt)
    local parent = onVest and vestEnt or ped
    if gone(camEnt) or camOn ~= recording or not IsEntityAttachedToEntity(camEnt, parent) then
        drop(camEnt)
        camEnt = spawn(recording and (V.CameraOn or 'opslabs_bodycam_on') or (V.Camera or 'opslabs_bodycam'))
        camOn = recording
        if not camEnt then return end
        if onVest then
            local o = V.CamOffset or vector3(0.0, 0.169, 0.0)
            AttachEntityToEntity(camEnt, vestEnt, 0, o.x, o.y, o.z, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
        else
            local f = fit(ped)
            local s = ((V.ShirtCam or {})[female(ped) and 'female' or 'male']) or { forward = 0.145, up = 0.0 }
            local pos, rot = spineAttach(ped, { forward = f.forward + (s.forward or 0.145), up = f.up + (s.up or 0.0), side = f.side })
            AttachEntityToEntity(camEnt, ped, GetPedBoneIndex(ped, SPINE3), pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, false, false, false, true, 2, true)
        end
    end
end

-- putting it on / taking it off -------------------------------------------------------------------------------------

local function dressAnim()
    if V.Animation == false then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return end
    local dict = 'clothingshirt'
    RequestAnimDict(dict)
    local t = GetGameTimer() + 2000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < t do Wait(0) end
    if not HasAnimDictLoaded(dict) then return end
    TaskPlayAnim(ped, dict, 'try_shirt_positive_d', 8.0, -8.0, 1400, 49, 0, false, false, false)
    Wait(1100)
    RemoveAnimDict(dict)
end

local function setWorn(on, by)
    if on == worn then return end
    CreateThread(function()
        dressAnim()
        worn, wornBy = on, on and by or nil
        poseCache = {}
        sync()
        TriggerServerEvent('opslabs-bodycam:vestState', worn)
        Config.Notify(worn and 'Vest on' or 'Vest off', 'inform')
        TriggerEvent('opslabs-bodycam:vest', worn)
    end)
end

RegisterNetEvent('opslabs-bodycam:useVest', function(by) setWorn(not worn, by or 'item') end)
RegisterNetEvent('opslabs-bodycam:notify', function(text, kind) Config.Notify(text, kind) end)
RegisterNetEvent('opslabs-bodycam:takeOffVest', function() if worn then setWorn(false) end end)

if V.Command and V.Command ~= '' then
    RegisterCommand(V.Command, function()
        TriggerServerEvent('opslabs-bodycam:vestCommand', not worn)
    end, false)
end

AddEventHandler('opslabs-bodycam:state', function(s)
    recording = s and s.recording == true
    sync()
end)

-- /vestfit: move the vest on yourself; saved for you (per male / female ped) and seen by everyone
RegisterCommand('vestfit', function(_, args)
    local ped = PlayerPedId()
    local _, key, mine = fit(ped)
    local what, amount = args[1], tonumber(args[2] or '')
    if what == 'reset' then
        mine = {}
    elseif (what == 'up' or what == 'forward' or what == 'side') and amount then
        mine[what] = math.floor(((mine[what] or 0.0) + amount) * 1000 + 0.5) / 1000
    else
        local f = fit(ped)
        print(('[opslabs-bodycam] vest fit (%s): forward = %.3f, up = %.3f, side = %.3f — your own adjustment: %s'):format(key, f.forward, f.up, f.side, json.encode(mine)))
        Config.Notify('Use /vestfit up|forward|side <metres> (e.g. /vestfit up 0.01) or /vestfit reset', 'inform')
        return
    end
    SetResourceKvp('vestfit_' .. key, json.encode(mine))
    poseCache = {}
    drop(vestEnt) vestEnt = nil
    drop(camEnt) camEnt = nil
    sync()
    local f = fit(ped)
    print(('[opslabs-bodycam] vest fit (%s): forward = %.3f, up = %.3f, side = %.3f'):format(key, f.forward, f.up, f.side))
    Config.Notify(('Vest fit: forward %.3f · up %.3f · side %.3f'):format(f.forward, f.up, f.side), 'inform')
end, false)

-- keep it on: respawn, model / clothing changes, lost the item ------------------------------------------------------
CreateThread(function()
    local n = 0
    while true do
        Wait(1000)
        n = n + 1
        if worn or camEnt then sync() end
        if worn and wornBy == 'item' and n % 15 == 0 then TriggerServerEvent('opslabs-bodycam:vestCheck') end
    end
end)

exports('IsVestOn', function() return worn end)
exports('SetVest', function(on) setWorn(on == true, 'export') end)

AddEventHandler('onResourceStop', function(r) if r == GetCurrentResourceName() then clear() end end)
