-- ============================================
--  State & Tablet Animation
-- ============================================
local tabletProp = nil
local isTabletOpen = false

local function startTabletAnimation()
    if isTabletOpen then return end
    isTabletOpen = true

    local ped = PlayerPedId()
    local dict = "amb@code_human_in_bus_passenger_idles@female@tablet@base"
    local anim = "base"

    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do Wait(10) end

    local model = `prop_cs_tablet`
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(10) end

    tabletProp = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    local bone = GetPedBoneIndex(ped, 28422)
    AttachEntityToEntity(tabletProp, ped, bone, 0.0, -0.03, 0.0, 20.0, -90.0, 0.0, true, true, false, true, 1, true)

    TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 50, 0, false, false, false)
end

local function stopTabletAnimation()
    if not isTabletOpen then return end
    isTabletOpen = false

    local ped = PlayerPedId()
    ClearPedTasks(ped)
    if tabletProp and DoesEntityExist(tabletProp) then
        DeleteEntity(tabletProp)
        tabletProp = nil
    end
end

-- ============================================
--  Commands & Item Events
-- ============================================
if type(Config.TabletItem) ~= 'string' then
    RegisterCommand(Config.Commands.Billing or 'bill', function()
        TriggerServerEvent('rps-bossmenu:server:requestBillingTablet')
    end, false)
end

RegisterNetEvent('rps-bossmenu:client:useTablet', function()
    TriggerServerEvent('rps-bossmenu:server:requestBillingTablet')
end)

-- ============================================
--  Network Events - Open Tablet
-- ============================================
RegisterNetEvent('rps-bossmenu:client:openBillingTablet', function(data)
    startTabletAnimation()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openBillingTablet",
        nearby = data.nearby,
        invoices = data.invoices,
        businessName = data.businessName,
        isBoss = data.isBoss
    })
end)

-- ============================================
--  NUI Callbacks
-- ============================================
RegisterNUICallback('closeBillingTablet', function(data, cb)
    SetNuiFocus(false, false)
    stopTabletAnimation()
    cb('ok')
end)

RegisterNUICallback('createInvoice', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:sendInvoice', data)
    cb('ok')
end)

RegisterNUICallback('cancelInvoice', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:cancelInvoice', data)
    cb('ok')
end)

RegisterNUICallback('refundInvoice', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:refundInvoice', data.invoiceId)
    cb('ok')
end)

RegisterNUICallback('getInvoices', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:getInvoicesCallback', function(invoices)
        cb(invoices or {})
    end)
end)

RegisterNUICallback('getEmployees', function(data, cb)
    Bridge.TriggerCallback('rps-bossmenu:server:getEmployeesCallback', function(result)
        cb(result or { canManage = false, employees = {}, grades = {} })
    end)
end)

-- ============================================
--  Network Events - Invoice Handling
-- ============================================
local lastInvoice = 0
RegisterNetEvent('rps-bossmenu:client:receiveInvoice', function(data)
    if GetGameTimer() - lastInvoice < 3000 then return end
    lastInvoice = GetGameTimer()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openInvoice",
        invoiceData = {
            amount = data.amount,
            reason = data.reason,
            billerName = data.from,
            businessName = data.org,
            invoiceId = data.invoiceId,
            time = data.time,
            targetName = "You"
        }
    })
end)

RegisterNetEvent('rps-bossmenu:client:invoiceResult', function(success, resultData)
    SendNUIMessage({
        action = "invoiceResult",
        success = success,
        data = resultData
    })
end)

RegisterNUICallback('payInvoice', function(data, cb)
    TriggerServerEvent('rps-bossmenu:server:payInvoice', data)
    cb('ok')
end)

RegisterNUICallback('declineInvoice', function(data, cb)
    SetNuiFocus(false, false)
    TriggerServerEvent('rps-bossmenu:server:declineInvoice', data)
    cb('ok')
end)

RegisterNUICallback('closeInvoiceSlip', function(data, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('invoiceResponse', function(data, cb)
    SetNuiFocus(false, false)
    if data.accepted then
        TriggerServerEvent('rps-bossmenu:server:payInvoice', data)
    else
        TriggerServerEvent('rps-bossmenu:server:declineInvoice', data)
    end
    cb('ok')
end)

RegisterNetEvent('rps-bossmenu:client:updateInvoiceStatus', function(invoiceId, newStatus)
    SendNUIMessage({
        action = "updateInvoiceStatus",
        id = invoiceId,
        status = newStatus
    })
end)

-- ============================================
--  Cleanup
-- ============================================
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        stopTabletAnimation()
    end
end)
