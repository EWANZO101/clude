-- SaltyChat (TeamSpeak). Experimental: from its README / VoiceManager.cs, tested against fakes. Calls are connected on
-- the server with AddPlayerToCall / RemovePlayerFromCall (the call id is the call's name).
Bridge.RegisterIntegration('voice', 'saltychat', {
    label = 'SaltyChat', resource = 'saltychat', status = 'experimental', builtin = true,
    ServerJoin = function(call, sources)
        for _, src in ipairs(sources) do exports.saltychat:AddPlayerToCall('ops-call-' .. call.id, src) end
    end,
    ServerLeave = function(call, sources)
        for _, src in ipairs(sources) do exports.saltychat:RemovePlayerFromCall('ops-call-' .. call.id, src) end
    end,
})
