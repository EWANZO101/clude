-- ============================================
--  State
-- ============================================
local activeJobId = nil

-- ============================================
--  Network Events - Boss Menu Open
-- ============================================
RegisterNetEvent('rps-bossmenu:client:openBossMenu', function(data)
    activeJobId = data.jobId
    local pos = GetEntityCoords(PlayerPedId())
    local streetHash, crossingHash = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
    local streetName = GetStreetNameFromHashKey(streetHash)
    local zone = GetNameOfZone(pos.x, pos.y, pos.z)
    local zoneLabel = GetLabelText(zone)
    if not zoneLabel or zoneLabel == "NULL" then zoneLabel = "San Andreas" end
    streetName = streetName .. ", " .. zoneLabel

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openBossMenu",
        employees = data.employees,
        logs = data.logs,
        grades = data.grades,
        nearby = data.nearby,
        businessName = data.businessName,
        jobId = data.jobId,
        rank = data.rank,
        balance = data.balance,
        isOwner = data.isOwner,
        isBoss = data.isBoss,
        myCid = data.myCid,
        myPermissions = data.myPermissions,
        allowedShops = data.allowedShops,
        onlineShopId = data.onlineShopId,
        inventoryImage = data.inventoryImage,
        streetName = streetName
    })
end)

-- ============================================
--  NUI Callbacks - Menu Actions
-- ============================================
RegisterNUICallback('closeBossMenu', function(data, cb)
    SetNuiFocus(false, false)
    if activeJobId then
        TriggerServerEvent('rps-bossmenu:server:closeBossMenu', activeJobId)
        activeJobId = nil
    end
    cb('ok')
end)

RegisterNUICallback('manageEmployee', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:manageEmployee', data)
    cb('ok')
end)

RegisterNUICallback('fireEmployee', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:fireEmployee', data)
    cb('ok')
end)

RegisterNUICallback('giveBonus', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:giveBonus', data)
    cb('ok')
end)

RegisterNUICallback('deposit', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:deposit', data)
    cb('ok')
end)

RegisterNUICallback('withdraw', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:withdraw', data)
    cb('ok')
end)

RegisterNUICallback('orderItems', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:orderItems', function(success, err)
        cb({ success = success, err = err })
    end, data)
end)

-- ============================================
--  NUI Callbacks - Nearby Players
-- ============================================
RegisterNUICallback('getNearbyPlayers', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:getNearbyPlayers', function(players)
        cb(players)
    end)
end)

-- ============================================
--  NUI Callbacks - Job Offers
-- ============================================
RegisterNUICallback('sendJobOffer', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:sendJobOffer', data)
    cb('ok')
end)

RegisterNUICallback('jobOfferResponse', function(data, cb)
    SetNuiFocus(false, false)
    TriggerServerEvent('rps-bossmenu:server:jobOfferResponse', data)
    cb('ok')
end)

-- ============================================
--  Network Events - Receive Job Offer
-- ============================================
local lastOffer = 0
RegisterNetEvent('rps-bossmenu:client:receiveJobOffer', function(data)
    if GetGameTimer() - lastOffer < 5000 then return end
    lastOffer = GetGameTimer()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openJobOffer",
        offerData = data
    })
end)
