-- Hands Up / Kneel script
-- Tap X  -> toggle hands up (on/off)
-- Hold X -> go on knees with hands up (release to stand back up)

local bindKey = 'x'          -- change this if you want a different default key
local holdThreshold = 400    -- ms held before it counts as "hold" instead of "tap"

local isPressed = false
local pressedAt = 0
local handsUp = false
local kneeling = false

local handsUpDict = 'missminuteman_1ig_2'
local handsUpAnim = 'handsup_base'
local kneelDict = 'random@arrests'
local kneelAnim = 'kneeling_arrest_idle'

local function loadDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end
end

local function startHandsUp()
    local ped = PlayerPedId()
    loadDict(handsUpDict)
    TaskPlayAnim(ped, handsUpDict, handsUpAnim, 8.0, -8.0, -1, 49, 0, false, false, false)
end

local function startKneel()
    local ped = PlayerPedId()
    loadDict(kneelDict)
    TaskPlayAnim(ped, kneelDict, kneelAnim, 8.0, -8.0, -1, 1, 0, false, false, false)
end

local function stopAnim()
    ClearPedTasks(PlayerPedId())
end

-- Register a bindable key mapping (players can rebind it in FiveM's Key Bindings menu
-- under "FiveM" category, look for "Hands Up / Kneel")
RegisterKeyMapping('+handsup', 'Hands Up / Kneel', 'keyboard', bindKey)

RegisterCommand('+handsup', function()
    isPressed = true
    pressedAt = GetGameTimer()
end, false)

RegisterCommand('-handsup', function()
    isPressed = false

    -- if we were holding (kneeling), stand back up but keep hands up toggled on
    if kneeling then
        kneeling = false
        handsUp = true
        startHandsUp()
        return
    end

    local heldFor = GetGameTimer() - pressedAt
    if heldFor < holdThreshold then
        -- short tap = toggle hands up
        handsUp = not handsUp
        if handsUp then
            startHandsUp()
        else
            stopAnim()
        end
    end
end, false)

-- watches for the key being held long enough to switch into kneeling
CreateThread(function()
    while true do
        Wait(0)
        if isPressed and not kneeling then
            local heldFor = GetGameTimer() - pressedAt
            if heldFor >= holdThreshold then
                handsUp = false
                kneeling = true
                startKneel()
            end
        end
    end
end)

-- keeps the anim playing continuously -- movement, other tasks, etc. can knock
-- the ped out of it, so re-apply it whenever it's no longer actually playing
-- (only when it's actually stopped, so this doesn't restart/reset it every tick)
CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        if handsUp and not kneeling then
            if not IsEntityPlayingAnim(ped, handsUpDict, handsUpAnim, 3) then
                startHandsUp()
            end
        elseif kneeling then
            if not IsEntityPlayingAnim(ped, kneelDict, kneelAnim, 3) then
                startKneel()
            end
        end
    end
end)

-- optional safety: cancel hands up/kneel if player enters a vehicle, dies, gets tased, etc.
CreateThread(function()
    while true do
        Wait(250)
        local ped = PlayerPedId()
        if (handsUp or kneeling) and (IsPedInAnyVehicle(ped, false) or IsEntityDead(ped)) then
            handsUp = false
            kneeling = false
            isPressed = false
            stopAnim()
        end
    end
end)