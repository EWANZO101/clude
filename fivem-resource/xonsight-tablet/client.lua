local tabletOpen = false
local tabletProp = nil
local playerPed = nil

-- Swap this for your framework's job lookup (ESX: ESX.GetPlayerData().job.name,
-- QBCore: QBCore.Functions.GetPlayerData().job.name, etc). Returns "" when
-- there's no framework wired up, which only matters if Config.AllowedJobs
-- is non-empty.
local function GetPlayerJob()
    return ""
end

local function IsAllowedToOpen()
    if #Config.AllowedJobs == 0 then
        return true
    end

    local job = GetPlayerJob()
    for _, allowed in ipairs(Config.AllowedJobs) do
        if allowed == job then
            return true
        end
    end

    return false
end

local function requestModel(modelName)
    local hash = GetHashKey(modelName)

    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        print(("[xonsight-tablet] '%s' is not a valid streamed model on this server"):format(modelName))
        return nil
    end

    RequestModel(hash)
    local attempts = 0
    while not HasModelLoaded(hash) and attempts < 100 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(hash) then
        print(("[xonsight-tablet] timed out loading model '%s'"):format(modelName))
        return nil
    end

    return hash
end

local function spawnTabletProp()
    local hash = requestModel(Config.PropModel)
    if not hash then
        return nil
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local prop = CreateObject(hash, coords.x, coords.y, coords.z, true, true, false)

    local boneIndex = GetEntityBoneIndexByName(ped, Config.AttachBone)
    AttachEntityToEntity(
        prop, ped, boneIndex,
        Config.AttachOffset.x, Config.AttachOffset.y, Config.AttachOffset.z,
        Config.AttachRotation.x, Config.AttachRotation.y, Config.AttachRotation.z,
        true, true, false, true, 1, true
    )

    SetModelAsNoLongerNeeded(hash)
    return prop
end

local function closeTablet()
    if not tabletOpen then
        return
    end

    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "close" })

    if tabletProp and DoesEntityExist(tabletProp) then
        DeleteEntity(tabletProp)
    end
    tabletProp = nil
end

local function openTablet()
    if tabletOpen then
        closeTablet()
        return
    end

    if not IsAllowedToOpen() then
        return
    end

    if Config.SiteUrl == "" or Config.SiteUrl == "http://YOUR_SITE_HOST:5010" then
        print("[xonsight-tablet] Config.SiteUrl isn't configured yet - edit config.lua")
        return
    end

    playerPed = PlayerPedId()
    tabletProp = spawnTabletProp()
    tabletOpen = true

    SendNUIMessage({
        action = "open",
        url = Config.SiteUrl .. Config.StartPath,
    })
    SetNuiFocus(true, true)
end

RegisterCommand("xonsight:toggletablet", function()
    openTablet()
end, false)

RegisterKeyMapping("xonsight:toggletablet", "Open/close Xon Sight tablet", "keyboard", Config.ToggleKey)

-- The NUI page's close button posts here (see html/app.js) rather than
-- relying only on the in-game key, so players without easy keyboard
-- access to the toggle key can still back out.
RegisterNUICallback("close", function(_, cb)
    closeTablet()
    cb({})
end)

-- Esc doesn't close NUI focus on its own - poll for it only while the
-- tablet is actually open so this thread is a no-op the rest of the time.
CreateThread(function()
    while true do
        if tabletOpen then
            Wait(0)
            if IsControlJustPressed(0, 322) then -- INPUT_FRONTEND_PAUSE (Esc)
                closeTablet()
            end
            if Config.DisableAttackWhileOpen then
                DisableControlAction(0, 24, true) -- INPUT_ATTACK
                DisableControlAction(0, 25, true) -- INPUT_AIM
            end
        else
            Wait(250)
        end
    end
end)

AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() == resourceName then
        closeTablet()
    end
end)
