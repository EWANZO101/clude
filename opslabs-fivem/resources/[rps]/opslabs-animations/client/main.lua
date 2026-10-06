-- opslabs-animations: lifelike climbing (ladders and poles), carrying and walking for the OPS Network.
--
-- opslabs-towers calls the exports while you climb (Begin / Drive / Pose / End) and raises a local event while you
-- carry a ladder or pull cable ('opslabs:carry'). An export returning false = towers does its own pose.
-- /opsanim shows which of the animations your game build has (and plays the climb on the spot for a few seconds).

local C, M = Config.Climb or {}, Config.Move or {}
local LADDER = 'laddersbase'
local WORK_DICT, WORK_CLIP = 'amb@prop_human_movie_bulb@base', 'base'
local MOUNT_CLIP = 'get_on_bottom_front_stand_high'
local FB = C.Fallback or { dict = WORK_DICT, clip = WORK_CLIP }

---------------------------------------------------------------------------
-- streaming (exports can't wait, so everything is loaded up front)
---------------------------------------------------------------------------
local loaded = {}
local function want(dict)
    if not dict or loaded[dict] ~= nil then return end
    loaded[dict] = false
    if not DoesAnimDictExist(dict) then return end
    CreateThread(function()
        RequestAnimDict(dict)
        local t = GetGameTimer()
        while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 5000 do Wait(0) end
        loaded[dict] = HasAnimDictLoaded(dict)
    end)
end
local function has(dict, clip) return loaded[dict] == true and GetAnimDuration(dict, clip) > 0.0 end

CreateThread(function()
    want(LADDER) want(WORK_DICT) want(FB.dict)
    if M.CarryLadder then want(M.CarryLadder.dict) end
    if M.PullCable then want(M.PullCable.dict) end
end)

-- the climb cycle needs laddersbase; without it everything uses the fallback reach-up pose
local function ladderOk() return has(LADDER, 'climb_up') end
local function ready() return ladderOk() or has(FB.dict, FB.clip) end

---------------------------------------------------------------------------
-- climbing (driven by opslabs-towers)
---------------------------------------------------------------------------
local climb                 -- { kind, k, pos, hand, lastMove, mountUntil, clip }

local function play(ped, dict, clip, flag, blend)
    if climb.clip ~= dict .. '/' .. clip or not IsEntityPlayingAnim(ped, dict, clip, 3) then
        TaskPlayAnim(ped, dict, clip, blend or 4.0, 4.0, -1, flag or 1, 0, false, false, false)
        climb.clip = dict .. '/' .. clip
    end
end

local function hold(ped, clip)
    if ladderOk() then play(ped, LADDER, has(LADDER, clip) and clip or 'base_left_hand_up', 1, 3.0)
    else play(ped, FB.dict, FB.clip, 1, 3.0) end
end

local function workLayer(ped, on)
    if on and loaded[WORK_DICT] and ladderOk() then
        if not IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) then TaskPlayAnim(ped, WORK_DICT, WORK_CLIP, 3.0, 3.0, -1, 49, 0, false, false, false) end
    elseif IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) and FB.dict ~= WORK_DICT then
        StopAnimTask(ped, WORK_DICT, WORK_CLIP, 2.0)
    end
end

--- stepping on from the ground: one step-on clip before the climb cycle takes over
local function mounting(ped)
    if not climb.mountUntil or GetGameTimer() > climb.mountUntil then return false end
    play(ped, LADDER, MOUNT_CLIP, 2, 8.0)
    return true
end

exports('Begin', function(kind, h)
    if not ready() then return false end
    climb = { kind = kind == 'pole' and 'pole' or 'ladder', pos = tonumber(h) or 0.0, hand = 'left', lastMove = GetGameTimer() }
    if C.MountClip ~= false and climb.pos < 0.3 and has(LADDER, MOUNT_CLIP) then climb.mountUntil = GetGameTimer() + 850 end
    return true
end)

--- moving: limbs follow the distance climbed (cycle = metres per full hand-over-hand cycle = two steps)
exports('Drive', function(kind, pos, cycle)
    if not climb or not ready() then return false end
    local ped = PlayerPedId()
    pos, cycle = tonumber(pos) or 0.0, math.max(0.1, tonumber(cycle) or 0.8)
    climb.pos, climb.lastMove = pos, GetGameTimer()
    if mounting(ped) then return true end
    workLayer(ped, false)
    if not ladderOk() then
        -- no climb cycle in this build: reach-up pose, rocked in time with the steps
        play(ped, FB.dict, FB.clip, 1)
        SetEntityAnimSpeed(ped, FB.dict, FB.clip, 0.0)
        SetEntityAnimCurrentTime(ped, FB.dict, FB.clip, 0.5 + 0.35 * math.sin(pos / cycle * math.pi * 2))
        return true
    end
    play(ped, LADDER, 'climb_up', 1, 6.0)
    local frac = (pos % cycle) / cycle
    SetEntityAnimSpeed(ped, LADDER, 'climb_up', 0.0)
    SetEntityAnimCurrentTime(ped, LADDER, 'climb_up', frac)
    climb.hand = frac < 0.5 and 'left' or 'right'          -- the hand that reached up last
    return true
end)

--- still: hold on (the last hand up stays up), shift grip now and then; 'work' adds hands-forward on top
exports('Pose', function(kind, state)
    if not climb or not ready() then return false end
    local ped = PlayerPedId()
    if mounting(ped) then return true end
    if FB.dict and not ladderOk() then SetEntityAnimSpeed(ped, FB.dict, FB.clip, 1.0) end
    if state == 'up' or state == 'down' then
        if ladderOk() then play(ped, LADDER, 'climb_up', 1) else play(ped, FB.dict, FB.clip, 1) end
        return true
    end
    local now = GetGameTimer()
    if state == 'hold' and C.IdleShift and now - climb.lastMove > C.IdleShift * 1000 then
        climb.hand, climb.lastMove = climb.hand == 'left' and 'right' or 'left', now
    end
    hold(ped, C.HandSwap ~= false and ('base_%s_hand_up'):format(climb.hand) or 'base_left_hand_up')
    workLayer(ped, state == 'work')
    return true
end)

exports('End', function()
    if not climb then return false end
    workLayer(PlayerPedId(), false)
    climb = nil
    return true
end)

---------------------------------------------------------------------------
-- moving around: harness walk, carrying a ladder, pulling cable
---------------------------------------------------------------------------
local carrying                 -- 'ladder' | 'cable' | nil
AddEventHandler('opslabs:carry', function(what, on)
    if on then carrying = what
    elseif carrying == what then carrying = nil end
end)

local function harnessWorn()
    local st = LocalPlayer.state.opsHarness
    return type(st) == 'table' and st.worn == true
end

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
    while true do
        local ped = PlayerPedId()
        local onFoot = not climb and not IsPedInAnyVehicle(ped, false) and not IsPedSwimming(ped) and not IsPedRagdoll(ped)
        setWalk(ped, (onFoot and harnessWorn() and M.HarnessWalk and IsPedMale(ped)) and M.HarnessWalk or nil)
        setCarry(ped, onFoot and (carrying == 'ladder' and M.CarryLadder or carrying == 'cable' and M.PullCable) or nil)
        Wait(250)
    end
end)

---------------------------------------------------------------------------
-- /opsanim: what this game build has, and a quick look at the climb
---------------------------------------------------------------------------
RegisterCommand('opsanim', function()
    local rows = {}
    local function check(label, dict, clip)
        local ok = has(dict, clip)
        rows[#rows + 1] = ('%s %s — %s/%s'):format(ok and '✔' or '✘', label, dict, clip)
        print(('[opslabs-animations] %s %s: %s / %s (dict exists %s, loaded %s, length %.2fs)'):format(ok and 'OK  ' or 'MISS', label, dict, clip,
            tostring(DoesAnimDictExist(dict)), tostring(HasAnimDictLoaded(dict)), GetAnimDuration(dict, clip)))
    end
    check('Climb cycle', LADDER, 'climb_up')
    check('Hold (left hand)', LADDER, 'base_left_hand_up')
    check('Hold (right hand)', LADDER, 'base_right_hand_up')
    check('Step on', LADDER, MOUNT_CLIP)
    check('Working on the pole', WORK_DICT, WORK_CLIP)
    check('Fallback reach-up', FB.dict, FB.clip)
    if M.CarryLadder then check('Carrying a ladder', M.CarryLadder.dict, M.CarryLadder.clip) end
    if M.PullCable then check('Pulling cable', M.PullCable.dict, M.PullCable.clip) end
    lib.alertDialog({ header = 'OPS animations · ' .. (ladderOk() and 'ladder climb clips found' or 'no ladder climb clips — using the fallback pose'),
        content = table.concat(rows, '  \n') .. '  \n\nPlaying the climb on the spot for 4 s after you close this.', centered = true })
    local ped = PlayerPedId()
    local dict, clip = ladderOk() and LADDER or FB.dict, ladderOk() and 'climb_up' or FB.clip
    if has(dict, clip) then
        TaskPlayAnim(ped, dict, clip, 4.0, 4.0, 4000, 1, 0, false, false, false)
        Wait(300)
        lib.notify({ description = IsEntityPlayingAnim(ped, dict, clip, 3) and ('Playing %s/%s'):format(dict, clip) or ('%s/%s did not start on your ped'):format(dict, clip) })
    end
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local ped = PlayerPedId()
    if walkSet then ResetPedMovementClipset(ped, 0.0) end
    if carryAnim then StopAnimTask(ped, carryAnim.dict, carryAnim.clip, 1.0) end
end)
