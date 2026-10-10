-- mumble-voip (archived, still used). Experimental: from its README. Same idea as pma-voice: a call channel.
Bridge.RegisterIntegration('voice', 'mumble-voip', {
    label = 'mumble-voip', resource = 'mumble-voip', status = 'experimental', builtin = true,
    Join = function(call) exports['mumble-voip']:SetCallChannel(call.channel) end,
    Leave = function() exports['mumble-voip']:SetCallChannel(0) end,
})
