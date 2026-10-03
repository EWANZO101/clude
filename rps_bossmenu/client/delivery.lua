-- ============================================
--  State
-- ============================================
local activeDelivery = nil
local isCarryingBox = false
local boxProp = nil
local PlayerData = {}

-- ============================================
--  Player Data Sync
-- ============================================
CreateThread(function()
    Wait(500)
    local pData = Bridge.GetPlayerData()
    if pData and pData.job then
        PlayerData = pData
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
end)

RegisterNetEvent('esx:playerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
end)

RegisterNetEvent('qbx:playerLoaded', function()
    PlayerData = Bridge.GetPlayerData()
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

RegisterNetEvent('rps-bossmenu:client:ordersFetched', function(data)
    SendNUIMessage({
        action = "ordersFetched",
        data = data
    })
end)

RegisterNetEvent('rps-bossmenu:client:messagesFetched', function(data)
    SendNUIMessage({
        action = "messagesFetched",
        data = data
    })
end)

-- ============================================
--  NUI Callbacks - Orders & Messages
-- ============================================
RegisterNUICallback('getOrders', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:getOrdersCallback', function(orders)
        cb(orders)
    end, data.shopId)
end)

RegisterNUICallback('getMessages', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:getMessagesCallback', function(messages)
        cb(messages)
    end, data.jobId)
end)

RegisterNUICallback('dispatchDelivery', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:triggerDeliverySpawn', data.orderId, data.msgId)
    cb('ok')
end)

RegisterNUICallback('acceptOrder', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:acceptOrder', data)
    cb('ok')
end)

RegisterNUICallback('declineOrder', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:declineOrder', data)
    cb('ok')
end)

RegisterNUICallback('refundOrder', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:refundOrder', data)
    cb('ok')
end)

-- ============================================
--  Network Events - Delivery Truck (Seller Side)
-- ============================================
RegisterNetEvent('rps-bossmenu:client:spawnDeliveryTruck', function(orderId, sellerCoords, buyerCoords, buyerJob)
    if not sellerCoords then return end
    
    local model = `pounder`
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(10) end
    
    local pedModel = `s_m_m_trucker_01`
    RequestModel(pedModel)
    while not HasModelLoaded(pedModel) do Wait(10) end
    
    print("[rps_bossmenu] Attempting to spawn truck for order", orderId)
    local x, y, z = tonumber(sellerCoords.x), tonumber(sellerCoords.y), tonumber(sellerCoords.z)
    local w = tonumber(sellerCoords.w) or 0.0
    
    local spawnPos = vector3(x, y, z)
    local spawnHeading = w
    local b, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(x, y, z, 1, 3.0, 0)
    
    print("[rps_bossmenu] Closest vehicle node found?", b, "NodePos:", nodePos)
    if b and nodePos then
        spawnPos = nodePos
        spawnHeading = nodeHeading
    end
    
    print("[rps_bossmenu] Spawning truck at:", spawnPos.x, spawnPos.y, spawnPos.z, spawnHeading)
    local vehicle = CreateVehicle(model, spawnPos.x, spawnPos.y, spawnPos.z, spawnHeading, true, false)
    
    if not vehicle or vehicle == 0 then
        print("[rps_bossmenu] ERROR: CreateVehicle failed! Vehicle handle is 0")
        return
    end
    
    SetEntityCoordsNoOffset(vehicle, spawnPos.x, spawnPos.y, spawnPos.z, false, false, false)
    SetVehicleOnGroundProperly(vehicle)
    
    local driver = CreatePedInsideVehicle(vehicle, 4, pedModel, -1, true, false)
    
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    TriggerEvent("vehiclekeys:client:SetOwner", Bridge.GetPlate(vehicle))
    print("[rps_bossmenu] Truck spawned successfully with plate:", Bridge.GetPlate(vehicle))
    SetEntityAsMissionEntity(driver, true, true)
    SetBlockingOfNonTemporaryEvents(driver, true)
    
    activeDelivery = {
        orderId = orderId,
        vehicle = vehicle,
        driver = driver,
        buyerCoords = buyerCoords,
        buyerJob = buyerJob,
        boxesLoaded = 0,
        maxBoxes = 6
    }
    
    Bridge.AddTargetEntity(vehicle, {
        options = {
            {
                type = "client",
                event = "rps-bossmenu:client:usePackaging",
                icon = "fas fa-box-open",
                label = "Pack Order Box",
                canInteract = function(entity)
                    return not isCarryingBox and activeDelivery and activeDelivery.vehicle == entity and activeDelivery.boxesLoaded < activeDelivery.maxBoxes
                end
            },
            {
                type = "client",
                event = "rps-bossmenu:client:loadBox",
                icon = "fas fa-box",
                label = "Load Box",
                canInteract = function(entity)
                    return isCarryingBox and activeDelivery and activeDelivery.vehicle == entity
                end
            }
        },
        distance = 3.0
    })
    
    SetVehicleDoorOpen(vehicle, 2, false, false)
    SetVehicleDoorOpen(vehicle, 3, false, false)
end)

-- ============================================
--  Packing Logic
-- ============================================
local function startPackingBox()
    Bridge.Progressbar("pack_box", "Packing items into box...", 3000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = "mini@repair",
        anim = "fixing_a_ped",
        flags = 16,
    }, {}, {}, function()
        ClearPedTasks(PlayerPedId())
        
        isCarryingBox = true
        
        local ped = PlayerPedId()
        local dict = "anim@heists@box_carry@"
        RequestAnimDict(dict)
        while not HasAnimDictLoaded(dict) do Wait(10) end
        
        TaskPlayAnim(ped, dict, "idle", 8.0, -8.0, -1, 50, 0, false, false, false)
        
        local propModel = `prop_cs_cardbox_01`
        RequestModel(propModel)
        while not HasModelLoaded(propModel) do Wait(10) end
        
        boxProp = CreateObject(propModel, 0.0, 0.0, 0.0, true, true, false)
        local bone = GetPedBoneIndex(ped, 28422)
        AttachEntityToEntity(boxProp, ped, bone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
        
    end, function()
        ClearPedTasks(PlayerPedId())
    end)
end

-- ============================================
--  Network Events - Use Packaging
-- ============================================
RegisterNetEvent('rps-bossmenu:client:usePackaging', function()
    if isCarryingBox then
        Bridge.Notify("You are already carrying a box!", "error")
        return
    end
    
    if not activeDelivery then
        Bridge.Notify("There is no active delivery!", "error")
        return
    end

    if activeDelivery.boxesLoaded == 0 then
        Bridge.TriggerCallback('rps-bossmenu:server:checkAndRemoveOrderItems', function(hasItems, errorMsg)
            if hasItems then
                startPackingBox()
            else
                Bridge.Notify(errorMsg or "You do not have the required items in your inventory!", "error")
            end
        end, activeDelivery.orderId)
    else
        startPackingBox()
    end
end)

-- ============================================
--  Network Events - Load Box
-- ============================================
RegisterNetEvent('rps-bossmenu:client:loadBox', function()
    if not isCarryingBox or not activeDelivery then return end
    
    local ped = PlayerPedId()
    ClearPedTasks(ped)
    if boxProp then
        DeleteEntity(boxProp)
        boxProp = nil
    end
    isCarryingBox = false
    
    activeDelivery.boxesLoaded = activeDelivery.boxesLoaded + 1
    Bridge.Notify("Box loaded! (" .. activeDelivery.boxesLoaded .. "/" .. activeDelivery.maxBoxes .. ")", "success")
    
    if activeDelivery.boxesLoaded >= activeDelivery.maxBoxes then
        Bridge.Notify("Truck fully loaded. Driver is departing!", "primary")
        
        SetVehicleDoorShut(activeDelivery.vehicle, 2, false)
        SetVehicleDoorShut(activeDelivery.vehicle, 3, false)
        TaskVehicleDriveWander(activeDelivery.driver, activeDelivery.vehicle, 20.0, 786603)
        
        SetTimeout(10000, function()
            local veh = activeDelivery.vehicle
            if DoesEntityExist(veh) then 
                Bridge.RemoveTargetEntity(veh, {'Pack Order Box', 'Load Box'})
                DeleteEntity(veh) 
            end
            if DoesEntityExist(activeDelivery.driver) then DeleteEntity(activeDelivery.driver) end
            
            TriggerServerEvent('rps-bossmenu:server:dispatchShippedOrder', activeDelivery.orderId, activeDelivery.buyerJob, activeDelivery.buyerCoords)
            activeDelivery = nil
        end)
    end
end)

-- ============================================
--  Network Events - Auto Delivery Truck (Buyer Side)
-- ============================================
RegisterNetEvent('rps-bossmenu:client:spawnAutoDeliveryTruck', function(orderId, buyerCoords, buyerJob)
    if not buyerCoords then return end
    
    local ped = PlayerPedId()
    
    local spawnX, spawnY, spawnZ = buyerCoords.x, buyerCoords.y, buyerCoords.z
    local spawnW = 0.0
    
    local nodeFound, outPos, outHeading = GetNthClosestVehicleNodeWithHeading(buyerCoords.x, buyerCoords.y, buyerCoords.z, 100, 0, 0, 0)
    if not nodeFound then
        nodeFound, outPos, outHeading = GetNthClosestVehicleNodeWithHeading(buyerCoords.x, buyerCoords.y, buyerCoords.z, 40, 0, 0, 0)
    end
    
    if nodeFound and outPos then
        spawnX, spawnY, spawnZ = outPos.x, outPos.y, outPos.z
        spawnW = outHeading
    end
    
    local pedModel = `s_m_m_trucker_01`
    RequestModel(pedModel)
    while not HasModelLoaded(pedModel) do Wait(10) end
    
    Bridge.Notify("A delivery truck is en route to your business...", "primary")
    
    Bridge.SpawnVehicle('pounder', function(vehicle)
        SetVehicleOnGroundProperly(vehicle)
        
        local driver = CreatePedInsideVehicle(vehicle, 4, pedModel, -1, true, false)
        
        SetEntityAsMissionEntity(vehicle, true, true)
        SetVehicleHasBeenOwnedByPlayer(vehicle, true)
        TriggerEvent("vehiclekeys:client:SetOwner", Bridge.GetPlate(vehicle))
        SetEntityAsMissionEntity(driver, true, true)
        SetBlockingOfNonTemporaryEvents(driver, true)
        
        local blip = AddBlipForEntity(vehicle)
        SetBlipSprite(blip, 477)
        SetBlipColour(blip, 5)
        SetBlipScale(blip, 0.8)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString("Delivery Truck")
        EndTextCommandSetBlipName(blip)
        
        Entity(vehicle).state:set('rps_deliveryJob', buyerJob, true)
        Entity(vehicle).state:set('rps_orderId', orderId, true)
        Entity(vehicle).state:set('rps_driverNet', VehToNet(vehicle), true)
        
        activeDelivery = {
            vehicle = vehicle,
            driver = driver,
            orderId = orderId,
            buyerJob = buyerJob,
            blip = blip,
            isAuto = true
        }
        
        TaskVehicleDriveToCoord(driver, vehicle, buyerCoords.x, buyerCoords.y, buyerCoords.z, 20.0, 0, GetEntityModel(vehicle), 786603, 1.0, true)
        
        local startTime = GetGameTimer()
        CreateThread(function()
            while true do
                Wait(1000)
                if not activeDelivery or not DoesEntityExist(vehicle) then return end
                
                local dist = #(GetEntityCoords(vehicle) - vector3(buyerCoords.x, buyerCoords.y, buyerCoords.z))
                
                if dist < 15.0 then
                    SetVehicleDoorOpen(vehicle, 2, false, false)
                    SetVehicleDoorOpen(vehicle, 3, false, false)
                    
                    Bridge.AddTargetEntity(vehicle, {
                        options = {
                            {
                                type = "client",
                                event = "rps-bossmenu:client:extractDelivery",
                                icon = "fas fa-box-open",
                                label = "Receive Delivery",
                                canInteract = function(entity)
                                    return activeDelivery and activeDelivery.vehicle == entity and activeDelivery.isAuto
                                end
                            }
                        },
                        distance = 3.0
                    })
                    
                    Bridge.Notify("Delivery truck has arrived! Grab your items from the back.", "success")
                    break
                end
            end
        end)
    end, vector4(spawnX, spawnY, spawnZ, spawnW), true)
end)

-- ============================================
--  Target Model Setup
-- ============================================
CreateThread(function()
    Bridge.AddTargetModel(`pounder`, {
        options = {
            {
                type = "client",
                event = "rps-bossmenu:client:extractDelivery",
                icon = "fas fa-box-open",
                label = "Receive Delivery",
                canInteract = function(entity)
                    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
                    
                    local state = Entity(entity).state
                    if not state or not state.rps_deliveryJob then return false end
                    
                    if PlayerData and PlayerData.job and PlayerData.job.name == state.rps_deliveryJob then
                        return true
                    end
                    
                    return false
                end
            }
        },
        distance = 3.0
    })
end)

-- ============================================
--  Network Events - Extract Delivery
-- ============================================
RegisterNetEvent('rps-bossmenu:client:extractDelivery', function(data)
    local vehicle = data.entity
    if not vehicle or vehicle == 0 then return end
    
    local state = Entity(vehicle).state
    if not state or not state.rps_orderId then return end
    
    local orderId = state.rps_orderId
    local buyerJob = state.rps_deliveryJob
    
    Bridge.TriggerCallback('rps-bossmenu:server:hasWebshopPerm', function(hasPerm)
        if not hasPerm then
            Bridge.Notify("You need webshop permissions to receive this!", "error")
            return
        end
        
        local ped = PlayerPedId()
        Bridge.Progressbar("extract_del", "Unloading items...", 3000, false, true, {
            disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
        }, {
            animDict = "mini@repair", anim = "fixing_a_ped", flags = 16,
        }, {}, {}, function()
            ClearPedTasks(ped)
            
            if not Entity(vehicle).state.rps_orderId then return end
            Entity(vehicle).state:set('rps_orderId', nil, true)
            
            TriggerServerEvent('rps-bossmenu:server:deliveryComplete', orderId, buyerJob)
            
            SetVehicleDoorShut(vehicle, 2, false)
            SetVehicleDoorShut(vehicle, 3, false)
            
            local driver = GetPedInVehicleSeat(vehicle, -1)
            if driver and driver ~= 0 then
                TaskVehicleDriveWander(driver, vehicle, 20.0, 786603)
            end
            
            SetTimeout(15000, function()
                if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
                if driver and DoesEntityExist(driver) then DeleteEntity(driver) end
            end)
        end)
    end, buyerJob)
end)
