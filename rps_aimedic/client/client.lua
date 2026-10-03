-- Uses the 'rps_lib' resource (exports.rps_lib) for notifications, progress bar, and
-- ambulance-job dead/revive detection, so this resource works unmodified on
-- ESX, QBCore, QBox, or standalone (see [standalone]/rps_lib/INTEGRATION_GUIDE.md).

local Active = false
local requestPending = false
local medicPed = nil
local medicBlip = nil

-- Goes through the configured rich-notification module (ox_lib / codem /
-- whatever Config.Notifications in rps_lib resolves to), not the plain
-- framework-default Notify.
local function Notify(msg, type)
    exports.rps_lib:ShowNotification({ description = msg, type = type })
end

RegisterCommand(Config.CommandName, function(source, args, raw)
    if requestPending then
        Notify(Config.Messages.alreadyRequested, "error")
        return
    end

    if not exports.rps_lib:IsPlayerDead() then
        Notify(Config.Messages.notDowned, "error")
        return
    end

    requestPending = true

    exports.rps_lib:TriggerServerCallback('aimedic:request', function(success, reason, extra)
        if success then
            SpawnMedic()
            Notify(Config.Messages.onTheWay, "success")
            return
        end

        requestPending = false

        local message = Config.Messages[reason] or Config.Messages.genericError
        if reason == "onCooldown" or reason == "tooManyEMS" then
            message = string.format(message, extra, Config.Doctor)
        end

        Notify(message, "error")
    end)
end)

-- Server-originated notifications (e.g. the timeout refund).
RegisterNetEvent('aimedic:notify')
AddEventHandler('aimedic:notify', function(msg, type)
    Notify(msg, type)
end)

function SpawnMedic()
    local pedHash = GetHashKey('s_m_m_doctor_01')
    local loc = GetEntityCoords(PlayerPedId())

    RequestModel(pedHash)
    local modelTimeout = GetGameTimer() + 5000
    while not HasModelLoaded(pedHash) and GetGameTimer() < modelTimeout do
        Wait(1)
    end

    if not HasModelLoaded(pedHash) then
        requestPending = false
        Notify(Config.Messages.genericError, "error")
        return
    end

    local spawnPos, spawnHeading = GetEntityCoords(PlayerPedId()), GetEntityHeading(PlayerPedId())

    medicPed = CreatePed(26, pedHash, spawnPos.x, spawnPos.y, spawnPos.z, spawnHeading, true, false)
    SetModelAsNoLongerNeeded(pedHash)

    medicBlip = AddBlipForEntity(medicPed)
    SetBlipFlashes(medicBlip, true)
    SetBlipColour(medicBlip, 5)

    PlaySoundFrontend(-1, "Text_Arrive_Tone", "Phone_SoundSet_Default", 1)
    Wait(2000)
    TaskGoToCoordAnyMeans(medicPed, loc.x, loc.y, loc.z, 1.0, 0, 0, 786603, 0xbf800000)
    Active = true

    Citizen.CreateThread(function()
        local deadline = GetGameTimer() + Config.MedicTimeout
        while Active do
            Citizen.Wait(500)
            if Active and GetGameTimer() > deadline then
                Active = false

                -- The medic couldn't path to the player in time (stuck on
                -- geometry, cut off by terrain, etc.) — rather than give up
                -- and refund, pull the player to the medic so treatment can
                -- still happen.
                local medicCoords = GetEntityCoords(medicPed)
                local playerPed = PlayerPedId()

                DoScreenFadeOut(500)
                Wait(500)
                SetEntityCoordsNoOffset(playerPed, medicCoords.x, medicCoords.y, medicCoords.z, false, false, false)
                Wait(200)
                DoScreenFadeIn(500)

                Notify(Config.Messages.medicPulledToYou, "info")
                ClearPedTasksImmediately(medicPed)
                DoctorNPC()
                break
            end
        end
    end)
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(200)
        if Active then
            local loc = GetEntityCoords(GetPlayerPed(-1))
            local ld = GetEntityCoords(medicPed)
            local dist1 = Vdist(loc.x, loc.y, loc.z, ld.x, ld.y, ld.z)
            if dist1 <= 1 then
                Active = false
                ClearPedTasksImmediately(medicPed)
                DoctorNPC()
            end
        end
    end
end)

function DoctorNPC()
    RequestAnimDict("mini@cpr@char_a@cpr_str")
    while not HasAnimDictLoaded("mini@cpr@char_a@cpr_str") do
        Citizen.Wait(10)
    end

    TaskPlayAnim(medicPed, "mini@cpr@char_a@cpr_str", "cpr_pumpchest", 1.0, 1.0, -1, 9, 1.0, 0, 0, 0)

    local completed = exports.rps_lib:ProgressBar({
        duration = Config.ReviveTime,
        label = Config.ProgressbarText,
        canCancel = false,
        useWhileDead = true, -- the player is deliberately still "dead" for the whole bar; ox_lib auto-cancels otherwise
        disable = {
            move = Config.ProgressbarDisableMovement,
            car = Config.ProgressbarDisableCarMovement,
            mouse = Config.ProgressbarDisableMouse,
            combat = Config.ProgressbarDisableCombat,
        },
    })

    ClearPedTasks(medicPed)
    Citizen.Wait(500)

    if completed then
        exports.rps_lib:RevivePlayer()
        TriggerServerEvent("aimedic:treatmentComplete")
        Notify(string.format(Config.Messages.treatmentComplete, Config.Price), "success")
    else
        Notify(Config.Messages.genericError, "error")
    end

    RemovePedElegantly(medicPed)
    requestPending = false
end

function RemovePedElegantly(ped)
    if ped and DoesEntityExist(ped) then
        SetEntityAsMissionEntity(ped, true, true)
        DeleteEntity(ped)
    end

    if medicBlip and DoesBlipExist(medicBlip) then
        RemoveBlip(medicBlip)
    end
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        Active = false
        RemovePedElegantly(medicPed)
    end
end)
