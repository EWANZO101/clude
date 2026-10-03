-- opslabs-animations: lifelike climbing (ladders and poles), carrying and walking for the OPS Network, plus the sounds
-- that go with it: boots on aluminium rungs and steel pole steps, hands on the stiles / wood, harness gear jingling,
-- karabiners clipping on and off, webbing round the pole. Nearby players hear yours through the server.
--
-- opslabs-towers calls the exports while you climb (Begin / Drive / Pose / End) and raises local events for the
-- harness ('opslabs:harness') and for carrying ('opslabs:carry'). An export returning false = towers does its own pose.

local S, C, M = Config.Sounds or {}, Config.Climb or {}, Config.Move or {}
local LADDER = 'laddersbase'
local WORK_DICT, WORK_CLIP = 'amb@prop_human_movie_bulb@base', 'base'
local MOUNT_CLIP = 'get_on_bottom_front_stand_high'

---------------------------------------------------------------------------
-- streaming (exports can't wait, so everything is loaded up front)
---------------------------------------------------------------------------
local loaded = {}
local function want(dict)
    if loaded[dict] ~= nil then return loaded[dict] end
    loaded[dict] = false
    if not DoesAnimDictExist(dict) then return false end
    CreateThread(function()
        RequestAnimDict(dict)
        local t = GetGameTimer()
        while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 5000 do Wait(0) end
        loaded[dict] = HasAnimDictLoaded(dict)
    end)
    return false
end
local function has(dict, clip) return loaded[dict] == true and GetAnimDuration(dict, clip) > 0.0 end

CreateThread(function()
    want(LADDER) want(WORK_DICT)
    if M.CarryLadder then want(M.CarryLadder.dict) end
    if M.PullCable then want(M.PullCable.dict) end
end)

---------------------------------------------------------------------------
-- sounds
---------------------------------------------------------------------------
local function play(name, volume, pan)
    if volume <= 0.01 then return end
    SendNUIMessage({ type = 'play', file = ('%s_%d.wav'):format(name, math.random((S.Variants or {})[name] or 1)), volume = volume, pan = pan or 0,
        rate = 0.95 + math.random() * 0.1 })
end

--- play my own sounds and send them to players nearby. names: { { name, gain }, ... }
local lastSent = 0
local function sfx(names)
    if not S.Enabled then return end
    for _, n in ipairs(names) do play(n[1], (S.Volume or 0.7) * (n[2] or 1.0), 0) end
    local now = GetGameTimer()
    if now - lastSent > 100 then
        lastSent = now
        local list = {}
        for i = 1, math.min(3, #names) do list[i] = { names[i][1], names[i][2] or 1.0 } end
        TriggerServerEvent('opslabs-animations:sfx', list)
    end
end

-- someone else's climbing / harness: quieter with distance, panned to where they are
RegisterNetEvent('opslabs-animations:sfx', function(src, list)
    if not S.Enabled or type(list) ~= 'table' then return end
    local pl = GetPlayerFromServerId(src)
    if pl == -1 then return end
    local ped = GetPlayerPed(pl)
    if ped == 0 then return end
    local cam, rot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local to = GetEntityCoords(ped) - cam
    local d = #to
    local range = S.Range or 30.0
    if d > range then return end
    local fall = (1.0 - d / range) ^ 2
    local rz = math.rad(rot.z)
    local flat = math.sqrt(to.x * to.x + to.y * to.y)
    local pan = flat > 0.5 and ((math.cos(rz) * to.x + math.sin(rz) * to.y) / flat) * 0.8 or 0.0
    for _, n in ipairs(list) do
        if type(n) == 'table' and type(n[1]) == 'string' then play(n[1], (S.Volume or 0.7) * fall * math.min(1.0, tonumber(n[2]) or 1.0), pan) end
    end
end)

local function harnessWorn()
    local st = LocalPlayer.state.opsHarness
    return type(st) == 'table' and st.worn == true
end

---------------------------------------------------------------------------
-- climbing (driven by opslabs-towers)
---------------------------------------------------------------------------
local climb                 -- { kind, k, pos, hand, steps, lastMove, mountUntil, clip }

local function base(ped, clip, blend)
    if not has(LADDER, clip) then clip = 'base_left_hand_up' end
    if climb.clip ~= clip or not IsEntityPlayingAnim(ped, LADDER, clip, 3) then
        TaskPlayAnim(ped, LADDER, clip, blend or 4.0, 4.0, -1, 1, 0, false, false, false)
        climb.clip = clip
    end
end

local function workLayer(ped, on)
    if on and loaded[WORK_DICT] then
        if not IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) then TaskPlayAnim(ped, WORK_DICT, WORK_CLIP, 3.0, 3.0, -1, 49, 0, false, false, false) end
    elseif IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) then
        StopAnimTask(ped, WORK_DICT, WORK_CLIP, 2.0)
    end
end

--- stepping on from the ground: one step-on clip before the climb cycle takes over
local function mounting(ped)
    if not climb.mountUntil or GetGameTimer() > climb.mountUntil then return false end
    if climb.clip ~= MOUNT_CLIP then
        TaskPlayAnim(ped, LADDER, MOUNT_CLIP, 8.0, 4.0, -1, 2, 0, false, false, false)
        climb.clip = MOUNT_CLIP
    end
    return true
end

local function onStep(dir)
    climb.steps = climb.steps + 1
    local pole = climb.kind == 'pole'
    local list = { { pole and 'pole_step' or 'ladder_rung', dir < 0 and 0.85 or 1.0 } }
    if climb.steps % 2 == 0 then list[#list + 1] = { pole and 'pole_grip' or 'ladder_hand', 0.5 } end   -- the other hand moves up
    if harnessWorn() and math.random() < (S.JingleChance or 0.45) then list[#list + 1] = { 'harness_jingle', 0.45 } end
    sfx(list)
end

exports('Begin', function(kind, h)
    if not loaded[LADDER] then return false end
    climb = { kind = kind == 'pole' and 'pole' or 'ladder', pos = tonumber(h) or 0.0, hand = 'left', steps = 0, lastMove = GetGameTimer() }
    if C.MountClip ~= false and climb.pos < 0.3 and has(LADDER, MOUNT_CLIP) then climb.mountUntil = GetGameTimer() + 850 end
    sfx({ { climb.kind == 'pole' and 'pole_grip' or 'ladder_hand', 0.8 } })
    return true
end)

--- moving: limbs follow the distance climbed (cycle = metres per full hand-over-hand cycle = two steps)
exports('Drive', function(kind, pos, cycle)
    if not climb or not loaded[LADDER] then return false end
    local ped = PlayerPedId()
    pos, cycle = tonumber(pos) or 0.0, math.max(0.1, tonumber(cycle) or 0.8)
    local k = math.floor(pos / (cycle / 2))
    if climb.k and k ~= climb.k then onStep(pos >= climb.pos and 1 or -1) end
    climb.k, climb.pos, climb.lastMove = k, pos, GetGameTimer()
    if mounting(ped) then return true end
    workLayer(ped, false)
    if not has(LADDER, 'climb_up') then base(ped, 'base_left_hand_up') return true end
    if climb.clip ~= 'climb_up' or not IsEntityPlayingAnim(ped, LADDER, 'climb_up', 3) then
        TaskPlayAnim(ped, LADDER, 'climb_up', 6.0, 6.0, -1, 1, 0, false, false, false)
        climb.clip = 'climb_up'
    end
    local frac = (pos % cycle) / cycle
    SetEntityAnimSpeed(ped, LADDER, 'climb_up', 0.0)
    SetEntityAnimCurrentTime(ped, LADDER, 'climb_up', frac)
    climb.hand = frac < 0.5 and 'left' or 'right'          -- the hand that reached up last
    return true
end)

--- still: hold on (the last hand up stays up), shift grip now and then; 'work' adds hands-forward on top
exports('Pose', function(kind, state)
    if not climb or not loaded[LADDER] then return false end
    local ped = PlayerPedId()
    if mounting(ped) then return true end
    if state == 'up' or state == 'down' then base(ped, 'climb_up') return true end
    local now = GetGameTimer()
    if state == 'hold' and C.IdleShift and now - climb.lastMove > C.IdleShift * 1000 then
        climb.hand, climb.lastMove = climb.hand == 'left' and 'right' or 'left', now
        local list = { { climb.kind == 'pole' and 'pole_grip' or 'ladder_hand', 0.5 } }
        if harnessWorn() then list[2] = { 'harness_jingle', 0.35 } end
        sfx(list)
    end
    base(ped, C.HandSwap ~= false and ('base_%s_hand_up'):format(climb.hand) or 'base_left_hand_up', 3.0)
    workLayer(ped, state == 'work')
    return true
end)

exports('End', function()
    if not climb then return false end
    local ped = PlayerPedId()
    workLayer(ped, false)
    sfx({ { climb.kind == 'pole' and 'pole_step' or 'ladder_rung', 0.7 } })
    climb = nil
    return true
end)

---------------------------------------------------------------------------
-- harness sounds
---------------------------------------------------------------------------
AddEventHandler('opslabs:harness', function(action)
    if action == 'on' or action == 'off' then sfx({ { 'buckle', 1.0 } })
    elseif action == 'strap' then sfx({ { 'webbing', 0.9 } })
    elseif action == 'clip' then sfx({ { 'harness_clip', 1.0 } })
    elseif action == 'unclip' then sfx({ { 'harness_unclip', 1.0 } })
    elseif action == 'check' then sfx({ { 'harness_jingle', 0.8 }, { 'webbing', 0.5 } }) end
end)

---------------------------------------------------------------------------
-- moving around: harness walk + gear jingle, carrying a ladder, pulling cable
---------------------------------------------------------------------------
local carrying                 -- 'ladder' | 'cable' | nil
AddEventHandler('opslabs:carry', function(what, on)
    if on then carrying = what
    elseif carrying == what then carrying = nil end
end)

local walkSet, carryAnim = nil, nil
local function setWalk(ped, cs)
    if cs == walkSet then return end
    if cs then
        RequestClipSet(cs)
        local t = GetGameTimer()
        while not HasClipSetLoaded(cs) and GetGameTimer() - t < 1500 do Wait(0) end
        if not HasClipSetLoaded(cs) then return end
        SetPedMovementClipset(ped, cs, 0.35)
    elseif walkSet then
        ResetPedMovementClipset(ped, 0.35)                 -- only undo what we set
    end
    walkSet = cs
end

local function setCarry(ped, a)
    if carryAnim and (not a or carryAnim.dict ~= a.dict) then StopAnimTask(ped, carryAnim.dict, carryAnim.clip, 2.0) carryAnim = nil end
    if a and has(a.dict, a.clip) then
        if not IsEntityPlayingAnim(ped, a.dict, a.clip, 3) then TaskPlayAnim(ped, a.dict, a.clip, 4.0, 4.0, -1, 49, 0, false, false, false) end
        carryAnim = a
    end
end

CreateThread(function()
    local nextJingle = 0
    while true do
        local ped = PlayerPedId()
        local onFoot = not climb and not IsPedInAnyVehicle(ped, false) and not IsPedSwimming(ped) and not IsPedRagdoll(ped)
        local worn = harnessWorn()
        setWalk(ped, (onFoot and worn and M.HarnessWalk and IsPedMale(ped)) and M.HarnessWalk or nil)
        setCarry(ped, onFoot and (carrying == 'ladder' and M.CarryLadder or carrying == 'cable' and M.PullCable) or nil)
        local speed = GetEntitySpeed(ped)
        if onFoot and worn and S.WalkJingle ~= false and speed > 1.0 then
            local now = GetGameTimer()
            if now > nextJingle then
                sfx({ { 'harness_jingle', speed > 4.0 and 0.5 or 0.28 } })
                nextJingle = now + (speed > 4.0 and 380 or 700) + math.random(0, 250)
            end
            Wait(100)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local ped = PlayerPedId()
    if walkSet then ResetPedMovementClipset(ped, 0.0) end
    if carryAnim then StopAnimTask(ped, carryAnim.dict, carryAnim.clip, 1.0) end
end)
