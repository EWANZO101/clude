local radioEnabled = not Config.disableRadioByDefault

RegisterCommand(Config.toggleCommand, function()
    local currentVehicle = cache.vehicle
    if not currentVehicle or currentVehicle == 0 then
        return
    end

    radioEnabled = not radioEnabled

    if radioEnabled then
        SetUserRadioControlEnabled(true)
    else
        SetVehRadioStation(currentVehicle, 'OFF')
        SetUserRadioControlEnabled(false)
    end
end, false)


lib.onCache('vehicle', function(currentVehicle)
    if currentVehicle and currentVehicle ~= 0 then
        SetUserRadioControlEnabled(radioEnabled)
        if not radioEnabled then
            SetVehRadioStation(currentVehicle, 'OFF')
        end
    else
        SetUserRadioControlEnabled(true)
    end
end)

-- SetUserRadioControlEnabled(false) alone still lets the radio wheel/menu pop
-- up (it just blocks the station from actually changing) -- actively block
-- the wheel + next/prev station controls so the menu itself can't open.
CreateThread(function()
    while true do
        if not radioEnabled and cache.vehicle then
            DisableControlAction(0, 85, true) -- INPUT_VEH_RADIO_WHEEL
            DisableControlAction(0, 86, true) -- INPUT_VEH_NEXT_RADIO
            DisableControlAction(0, 87, true) -- INPUT_VEH_PREV_RADIO
            Wait(0)
        else
            Wait(500)
        end
    end
end)