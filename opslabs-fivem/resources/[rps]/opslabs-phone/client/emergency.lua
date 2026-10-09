-- OPS Emergency Alerts (server/emergency.lua): show an alert on the phone, mark its area on the map while it is live,
-- and tell the server the phone has shown it. No phone in your pockets (or a flat battery): nothing shows, and the
-- server tries again while the alert is live.

local CFG = Config.Emergency or {}
local blips = {}   -- [id] = { radius blip, centre blip }

local function hasWorkingPhone()
    if Config.RequireItem then
        local has = HasPhoneCached and HasPhoneCached()
        if has == nil and RefreshHasPhone then has = RefreshHasPhone() end
        if not has then return false end
    end
    if PhoneIsDead and PhoneIsDead() then return false end
    return true
end

local SEVERITY_COLOUR = { extreme = 1, severe = 47, warning = 5, info = 3 }   -- blip colours: red, orange, yellow, blue
local SEVERITY_NAME = { extreme = 'Extreme Alert', severe = 'Severe Alert', warning = 'Warning', info = 'Information' }

local function dropBlip(id)
    local b = blips[id]
    if not b then return end
    for _, h in ipairs(b) do if DoesBlipExist(h) then RemoveBlip(h) end end
    blips[id] = nil
end

local function areaBlip(a)
    if CFG.AreaBlip == false or a.audience ~= 'area' or not a.x or not a.radius or blips[a.id] then return end
    local r = AddBlipForRadius(a.x + 0.0, a.y + 0.0, 0.0, a.radius + 0.0)
    SetBlipColour(r, SEVERITY_COLOUR[a.severity] or 1)
    SetBlipAlpha(r, 90)
    local c = AddBlipForCoord(a.x + 0.0, a.y + 0.0, 0.0)
    SetBlipSprite(c, 161)
    SetBlipColour(c, SEVERITY_COLOUR[a.severity] or 1)
    SetBlipScale(c, 0.8)
    SetBlipAsShortRange(c, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('%s: %s'):format(SEVERITY_NAME[a.severity] or 'Alert', a.title or ''))
    EndTextCommandSetBlipName(c)
    blips[a.id] = { r, c }
end

RegisterNetEvent('opslabs-phone:emergency', function(a)
    if type(a) ~= 'table' or not hasWorkingPhone() then return end
    TriggerServerEvent('opslabs-phone:emergencyAck', a.id)
    areaBlip(a)
    SendNUIMessage({ action = 'emergencyAlert', data = a })
    -- phone in your pocket: the alert is also read out on screen (the phone peeks up and keeps it until you open it)
    if not PhoneOpen then
        lib.notify({ title = ('%s · %s'):format(SEVERITY_NAME[a.severity] or 'Emergency Alert', a.company or 'OPS'),
            description = ('%s\n%s'):format(a.title or '', a.body or ''), type = (a.severity == 'info') and 'inform' or 'error',
            duration = a.severity == 'info' and 8000 or 15000, position = 'top' })
    end
end)

RegisterNetEvent('opslabs-phone:emergencyEnd', function(id, status)
    dropBlip(id)
    SendNUIMessage({ action = 'emergencyEnd', data = { id = id, status = status } })
end)

RegisterNUICallback('emergencyWaypoint', function(body, cb)
    if body and body.x and body.y then SetNewWaypoint(body.x + 0.0, body.y + 0.0) end
    cb(true)
end)

-- an alert while the phone is pocketed: a cursor to tap Acknowledge, while you keep walking/driving (no shooting meanwhile)
local alertFocus = false
RegisterNUICallback('emergencyFocus', function(body, cb)
    local on = body and body.on == true
    cb(true)
    if PhoneOpen then alertFocus = false return end   -- the open phone owns the focus
    if on == alertFocus then return end
    alertFocus = on
    SetNuiFocus(on, on)
    SetNuiFocusKeepInput(on)
    if not on then return end
    CreateThread(function()
        while alertFocus and not PhoneOpen do
            DisableControlAction(0, 1, true)     -- look (the mouse is on the cursor)
            DisableControlAction(0, 2, true)
            DisableControlAction(0, 24, true)    -- attack
            DisableControlAction(0, 25, true)    -- aim
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
            DisableControlAction(0, 263, true)
            DisableControlAction(0, 37, true)    -- weapon wheel
            DisablePlayerFiring(PlayerId(), true)
            Wait(0)
        end
        if PhoneOpen then alertFocus = false end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(blips) do dropBlip(id) end
    if alertFocus and not PhoneOpen then SetNuiFocus(false, false); SetNuiFocusKeepInput(false) end
end)
