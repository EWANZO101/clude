local PREFIX = 'opslabs-phone:'

local function setVoiceChannel(channel)
    if Config.Calls.UsePmaVoice and GetResourceState('pma-voice') == 'started' then
        exports['pma-voice']:setCallChannel(channel)
    end
end

RegisterNetEvent(PREFIX .. 'push', function(action, data)
    if action == 'incomingCall' then
        InCall = true
        -- show the phone peeking from the bottom even when closed
        if not PhoneOpen then SendNUIMessage({ action = 'peek' }) end
    elseif action == 'callAccepted' then
        InCall = true
        setVoiceChannel(data.channel)
        PlayPhoneAnim('call')
    elseif action == 'callEnded' then
        InCall = false
        setVoiceChannel(0)
        if PhoneOpen then PlayPhoneAnim('text') else StopPhoneAnim() end
    end
end)

-- outgoing calls are started from the UI via rpc; flag the state locally
RegisterNUICallback('callState', function(body, cb)
    InCall = body.active == true
    if InCall then PlayPhoneAnim('call') end
    cb(true)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then setVoiceChannel(0) end
end)
