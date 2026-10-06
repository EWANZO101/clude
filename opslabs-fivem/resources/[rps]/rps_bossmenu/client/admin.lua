RegisterCommand(Config.Commands.AdminMenu or 'bossadmin', function()
    TriggerServerEvent('rps-bossmenu:server:requestAdminUI')
end, false)

RegisterNetEvent('rps-bossmenu:client:openAdminUI', function(data)
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openAdminUI",
        businesses = data.businesses,
        shops = data.shops,
        characters = data.characters,
        itemsList = data.itemsList,
        inventoryImage = data.inventoryImage
    })
end)

RegisterNUICallback('closeAdminUI', function(data, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('captureLocation', function(data, cb)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    cb({
        x = math.floor(coords.x * 10 + 0.5) / 10,
        y = math.floor(coords.y * 10 + 0.5) / 10,
        z = math.floor(coords.z * 10 + 0.5) / 10
    })
end)

RegisterNUICallback('captureDeliveryLocation', function(data, cb)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    cb({
        x = math.floor(coords.x * 10 + 0.5) / 10,
        y = math.floor(coords.y * 10 + 0.5) / 10,
        z = math.floor(coords.z * 10 + 0.5) / 10
    })
end)

RegisterNUICallback('createBusiness', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:createBusiness', data)
    cb('ok')
end)

RegisterNUICallback('editBusiness', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:editBusiness', data)
    cb('ok')
end)

RegisterNUICallback('deleteBusiness', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:deleteBusiness', data)
    cb('ok')
end)

RegisterNUICallback('createJungleShop', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:createJungleShop', data)
    cb('ok')
end)

RegisterNUICallback('editJungleShop', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:editJungleShop', data)
    cb('ok')
end)

RegisterNUICallback('deleteJungleShop', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:deleteJungleShop', data)
    cb('ok')
end)

RegisterNUICallback('linkOnlineShop', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:linkOnlineShop', data)
    cb('ok')
end)

RegisterNUICallback('setDeliveryCoords', function(data, cb)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    TriggerServerEvent('rps-bossmenu:server:setDeliveryCoords', { job = data.job, coords = { x = coords.x, y = coords.y, z = coords.z } })
    cb('ok')
end)
