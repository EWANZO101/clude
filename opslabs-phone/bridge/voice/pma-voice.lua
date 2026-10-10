-- pma-voice (verified: the phone has always used it). Both people in a call join the call's channel (its id).
Bridge.RegisterIntegration('voice', 'pma-voice', {
    label = 'pma-voice', resource = 'pma-voice', status = 'verified', builtin = true,
    -- client: call = { id, channel, peer }
    Join = function(call) exports['pma-voice']:setCallChannel(call.channel) end,
    Leave = function() exports['pma-voice']:setCallChannel(0) end,
})
