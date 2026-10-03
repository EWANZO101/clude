-- ============================================
--  Player Data
-- ============================================
local PlayerData = {}

CreateThread(function()
    Wait(500)
    local pData = Bridge.GetPlayerData()
    if pData and pData.job then
        PlayerData = pData
    end
end)

-- ============================================
--  Event Handlers - Player Loaded & Job Update
-- ============================================
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
    TriggerServerEvent('rps-bossmenu:server:requestTargets')
end)

RegisterNetEvent('esx:playerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
    TriggerServerEvent('rps-bossmenu:server:requestTargets')
end)

RegisterNetEvent('qbx:playerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
    TriggerServerEvent('rps-bossmenu:server:requestTargets')
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    PlayerData.job = JobInfo
end)

RegisterNetEvent('esx:setJob', function()
    local pData = Bridge.GetPlayerData()
    if pData then
        PlayerData.job = pData.job
    end
end)

RegisterNetEvent('qbx:setJob', function()
    local pData = Bridge.GetPlayerData()
    if pData then
        PlayerData = pData
    end
end)

-- ============================================
--  Resource Start
-- ============================================
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end
    TriggerServerEvent('rps-bossmenu:server:requestTargets')
end)

-- ============================================
--  Target Zone Creation
-- ============================================
local function createBossTarget(job, coords)
    if not coords then return end
    
    if type(coords) == 'string' then
        local success, decoded = pcall(json.decode, coords)
        if success and decoded then
            coords = decoded
        end
    end
    
    if type(coords) == 'table' and coords.x and coords.y and coords.z then
        local vecCoords = vector3(coords.x, coords.y, coords.z)
        local zoneName = 'rps_bossmenu_'..job
        
        Bridge.AddCircleZone(zoneName, vecCoords, 1.5, {
            name = zoneName,
            debugPoly = Config.Debug or false,
            useZ = false
        }, {
            options = {
                {
                    type = "client",
                    icon = 'fas fa-briefcase',
                    label = 'Open Boss Menu',
                    action = function()
                        TriggerServerEvent('rps-bossmenu:server:requestBossMenu', job)
                    end,
                    canInteract = function()
                        if PlayerData and PlayerData.job and PlayerData.job.name == job then
                            return true
                        end
                        return false
                    end
                }
            },
            distance = 2.5
        })
    end
end

-- ============================================
--  Network Events
-- ============================================
RegisterNetEvent('rps-bossmenu:client:initTargets', function(businesses)
    for i=1, #businesses do
        createBossTarget(businesses[i].job, businesses[i].coords)
    end
end)

RegisterCommand('bosstarget', function()
    print('Manually requesting bossmenu targets...')
    TriggerServerEvent('rps-bossmenu:server:requestTargets')
end, false)
