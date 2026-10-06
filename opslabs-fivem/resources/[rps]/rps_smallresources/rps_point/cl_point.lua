-- Point script (full-arm finger-point gesture, same one GTA Online uses)
-- Tap B -> toggle pointing on/off; while active, the point runs continuously
-- and its direction follows your camera -- just look where you want to point.
--
-- This gesture is driven by a move-network task ("task_mp_pointing") that
-- blends pitch/heading signals from the camera every frame, rather than a
-- single animation clip -- that's what makes it hold a continuous full-arm
-- point the whole time it's toggled on, instead of a short gesture that ends.

local bindKey = 'b'          -- change this if you want a different default key
local animDict = 'anim@mp_point'

local pointing = false

-- Native hashes (no FiveM native-table wrapper exists for these move-network
-- signal/task natives, so they're invoked directly)
local TASK_MOVE_NETWORK_BY_NAME = 0x2D537BA194896636
local SET_TASK_MOVE_NETWORK_SIGNAL_FLOAT = 0xD5BB4025AE449A4E
local SET_TASK_MOVE_NETWORK_SIGNAL_BOOL = 0xB0A6CFD2C69C1088

local function loadDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
end

local function startPoint()
    local ped = PlayerPedId()
    loadDict(animDict)
    SetPedCurrentWeaponVisible(ped, false, true, true, true)
    SetPedConfigFlag(ped, 36, true)
    Citizen.InvokeNative(TASK_MOVE_NETWORK_BY_NAME, ped, 'task_mp_pointing', 0.5, false, animDict, 24)
end

local function stopPoint()
    local ped = PlayerPedId()
    -- ClearPedTasks actually cancels the move-network task; the hash every
    -- community reference for this copy-pastes for "stop" (0xD01015C7316AE176)
    -- actually resolves to SET_PED_CLOTH_PACKAGE_INDEX in FiveM's native docs,
    -- so it never stopped anything -- that's why pointing survived a 2nd press.
    ClearPedTasks(ped)
    if not IsPedInAnyVehicle(ped, false) then
        SetPedCurrentWeaponVisible(ped, true, true, true, true)
    end
    SetPedConfigFlag(ped, 36, false)
end

-- Register a bindable key mapping (players can rebind it in FiveM's Key Bindings menu
-- under "FiveM" category, look for "Point")
RegisterKeyMapping('point', 'Point', 'keyboard', bindKey)

RegisterCommand('point', function()
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        return
    end

    pointing = not pointing
    if pointing then
        startPoint()
    else
        stopPoint()
    end
end, false)

-- while pointing, feed the move-network task the camera's pitch/heading every
-- frame so the point direction tracks wherever you're looking, continuously,
-- for as long as it's toggled on
CreateThread(function()
    while true do
        if pointing then
            local ped = PlayerPedId()

            local pitch = math.max(-70.0, math.min(42.0, GetGameplayCamRelativePitch()))
            pitch = (pitch + 70.0) / 112.0

            local heading = math.max(-180.0, math.min(180.0, GetGameplayCamRelativeHeading()))
            heading = (heading + 180.0) / 360.0

            Citizen.InvokeNative(SET_TASK_MOVE_NETWORK_SIGNAL_FLOAT, ped, 'Pitch', pitch)
            Citizen.InvokeNative(SET_TASK_MOVE_NETWORK_SIGNAL_FLOAT, ped, 'Heading', (heading * -1.0) + 1.0)
            Citizen.InvokeNative(SET_TASK_MOVE_NETWORK_SIGNAL_BOOL, ped, 'isFirstPerson', GetFollowPedCamViewMode() == 4)

            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- optional safety: cancel pointing if player enters a vehicle, dies, gets tased, etc.
CreateThread(function()
    while true do
        Wait(250)
        local ped = PlayerPedId()
        if pointing and (IsPedInAnyVehicle(ped, false) or IsEntityDead(ped)) then
            pointing = false
            stopPoint()
        end
    end
end)
