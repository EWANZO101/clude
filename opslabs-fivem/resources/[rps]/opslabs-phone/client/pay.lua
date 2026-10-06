-- OPS Pay: contactless payments at OPS POS tills (opslabs-pos). The till asks with the local event
-- 'opslabs-phone:payRequest'; the phone comes up with a pay sheet (merchant, items, total) and the customer approves
-- with Face ID or cancels. The answer goes back as 'opslabs-pos:payResult' (true / false; nil = no working phone,
-- so the till falls back to tapping a bank card).

local waiting = {}

local function usable()
    if Config.RequireItem and HasPhoneCached and not HasPhoneCached() then return false end
    if PhoneIsDead and PhoneIsDead() then return false end
    if MyDock and MyDock() then return false end          -- it's lying on a charger, not in your hand
    return true
end

local function answer(id, ok)
    if not waiting[id] then return end
    waiting[id] = nil
    TriggerEvent('opslabs-pos:payResult', id, ok)
end

AddEventHandler('opslabs-phone:payRequest', function(d)
    if type(d) ~= 'table' or not d.id then return end
    if not usable() then return TriggerEvent('opslabs-pos:payResult', d.id, nil) end
    waiting[d.id] = true
    if not PhoneOpen then OpenPhone() end
    SendNUIMessage({ action = 'payRequest', data = d })
    SetTimeout((tonumber(d.timeout) or 30) * 1000, function()
        if waiting[d.id] then
            SendNUIMessage({ action = 'payClose', data = { id = d.id } })
            answer(d.id, false)
        end
    end)
end)

RegisterNUICallback('payRespond', function(body, cb)
    cb(true)
    answer(tonumber(body and body.id), body and body.ok == true)
end)
