local PREFIX = 'opslabs-phone:'

-- call audio goes through the voice resource the bridge picked (Config.Integrations.voice: pma-voice, saltychat, …)
local currentCall

RegisterNetEvent(PREFIX .. 'push', function(action, data)
    if action == 'incomingCall' then
        InCall = true
        -- show the phone peeking from the bottom even when closed
        if not PhoneOpen then SendNUIMessage({ action = 'peek' }) end
    elseif action == 'callAccepted' then
        InCall = true
        -- channel 0: a call with OPS Hub (server/voip.lua) — no pma-voice call channel, the bridge listens in your own
        if data.channel and data.channel ~= 0 then currentCall = data FW.VoiceJoin(data) end
        PlayPhoneAnim('call')
    elseif action == 'callEnded' then
        InCall = false
        FW.VoiceLeave(currentCall)
        currentCall = nil
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
    if res == GetCurrentResourceName() and currentCall then FW.VoiceLeave(currentCall) end
end)
