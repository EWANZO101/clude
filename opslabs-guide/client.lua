-- /guide: opens the animated guide. Esc or the ✕ closes it; it remembers where you were.

local open = false

local function setOpen(state)
    open = state
    SetNuiFocus(state, state)
    SendNUIMessage({ action = state and 'open' or 'close', pos = state and json.decode(GetResourceKvpString('opslabs_guide') or 'null') or nil })
end

RegisterCommand('guide', function() setOpen(not open) end, false)
TriggerEvent('chat:addSuggestion', '/guide', 'How to use OPS Mobile, towers, cabling, poles, ladders, internet service and road safety kit')

RegisterNUICallback('close', function(_, cb) setOpen(false) cb(true) end)

-- progress: { chapter, slide, done = { chapterId = true } }
RegisterNUICallback('save', function(body, cb)
    SetResourceKvp('opslabs_guide', json.encode(body or {}))
    cb(true)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and open then SetNuiFocus(false, false) end
end)
