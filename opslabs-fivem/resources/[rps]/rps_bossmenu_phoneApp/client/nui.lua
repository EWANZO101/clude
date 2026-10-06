-- ============================================
--  NUI Bridge -> rps_bossmenu
--  Every callback here just forwards to the exact same server
--  events/callbacks rps_bossmenu's tablet UI already uses
--  (server/billing.lua, server/bossmenu.lua), so this app and the
--  physical tablet always share identical data and permission checks.
-- ============================================
RegisterNUICallback('getEmployees', function(data, cb)
    exports.rps_lib:TriggerServerCallback('rps-bossmenu:server:getEmployeesCallback', function(result)
        cb(result or { canManage = false, employees = {}, grades = {} })
    end)
end)

RegisterNUICallback('getNearbyPlayers', function(data, cb)
    exports.rps_lib:TriggerServerCallback('rps-bossmenu:server:getNearbyPlayers', function(players)
        cb(players or {})
    end)
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

RegisterNUICallback('sendJobOffer', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:sendJobOffer', data)
    cb('ok')
end)
