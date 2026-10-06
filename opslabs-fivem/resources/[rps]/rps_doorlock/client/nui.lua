
RegisterNUICallback('closeUI', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('createDoor', function(data, cb)
    TriggerServerEvent('rps_doorlock:server:CreateDoor', data)
    cb('ok')
end)

RegisterNUICallback('saveDoor', function(data, cb)
    TriggerServerEvent('rps_doorlock:server:UpdateDoor', data.id, data)
    cb('ok')
end)

RegisterNUICallback('deleteDoor', function(data, cb)
    TriggerServerEvent('rps_doorlock:server:DeleteDoor', data.id)
    cb('ok')
end)

RegisterNUICallback('startEntityPicker', function(data, cb)
    SetNuiFocus(false, false)
    StartEntityPicker(data.isDouble)
    cb('ok')
end)

RegisterNUICallback('searchCharacters', function(data, cb)
    exports.rps_lib:TriggerServerCallback('rps_doorlock:server:SearchCharacters', function(result)
        cb(result)
    end, data.query)
end)
