-- Tablet module (was xonsight-tablet): stock tablet prop + NUI iframe of the portal. Settings: config_server.lua →
-- ServerConfig.Modules.Tablet. The NUI lives in html/index.html (#tablet) with html/tablet.js / tablet.css.

local cfg
local tabletOpen = false
local tabletProp = nil

-- Swap this for your framework's job lookup (ESX: ESX.GetPlayerData().job.name,
-- QBCore: QBCore.Functions.GetPlayerData().job.name, etc). Returns "" when
-- there's no framework wired up, which only matters if AllowedJobs is non-empty.
local function GetPlayerJob()
    return ""
end

local function IsAllowedToOpen()
    if #cfg.allowedJobs == 0 then
        return true
    end

    local job = GetPlayerJob()
    for _, allowed in ipairs(cfg.allowedJobs) do
        if allowed == job then
            return true
        end
    end

    return false
end

local function requestModel(modelName)
    local hash = GetHashKey(modelName)

    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        print(("[opslabs-bodycam:tablet] '%s' is not a valid streamed model on this server"):format(modelName))
        return nil
    end

    RequestModel(hash)
    local attempts = 0
    while not HasModelLoaded(hash) and attempts < 100 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(hash) then
        print(("[opslabs-bodycam:tablet] timed out loading model '%s'"):format(modelName))
        return nil
    end

    return hash
end

local function spawnTabletProp()
    local hash = requestModel(cfg.propModel)
    if not hash then
        return nil
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local prop = CreateObject(hash, coords.x, coords.y, coords.z, true, true, false)

    local boneIndex = GetEntityBoneIndexByName(ped, cfg.attachBone)
    local o, r = cfg.attachOffset, cfg.attachRotation
    AttachEntityToEntity(
        prop, ped, boneIndex,
        o.x, o.y, o.z,
        r.x, r.y, r.z,
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
    SendNUIMessage({ action = "tabletClose" })

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

    if cfg.url == "" then
        print("[opslabs-bodycam:tablet] ServerConfig.XonSight.Url isn't configured - edit opslabs-bodycam/config_server.lua")
        return
    end

    tabletProp = spawnTabletProp()
    tabletOpen = true

    SendNUIMessage({ action = "tabletOpen", url = cfg.url })
    SetNuiFocus(true, true)
end

CreateThread(function()
    cfg = ModuleConfig('tablet')
    if not cfg then return end

    -- same command name as the old xonsight-tablet resource, so players' rebinds carry over
    RegisterCommand("xonsight:toggletablet", function()
        openTablet()
    end, false)

    RegisterKeyMapping("xonsight:toggletablet", "Open/close Xon Sight tablet", "keyboard", cfg.toggleKey)

    -- Esc doesn't close NUI focus on its own - poll for it only while the
    -- tablet is actually open so this loop is a no-op the rest of the time.
    while true do
        if tabletOpen then
            Wait(0)
            if IsControlJustPressed(0, 322) then -- INPUT_FRONTEND_PAUSE (Esc)
                closeTablet()
            end
            if cfg.disableAttackWhileOpen then
                DisableControlAction(0, 24, true) -- INPUT_ATTACK
                DisableControlAction(0, 25, true) -- INPUT_AIM
            end
        else
            Wait(250)
        end
    end
end)

-- The NUI close button / Esc key post here (html/tablet.js), so players without
-- easy access to the toggle key can still back out.
RegisterNUICallback("tabletClose", function(_, cb)
    closeTablet()
    cb({})
end)

AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() == resourceName then
        closeTablet()
    end
end)
