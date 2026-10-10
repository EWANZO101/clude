-- YaCA (yaca-voice). Experimental: from its source (yaca-server/src/yaca/phone.ts), tested against fakes. A call is
-- one-to-one: callPlayer(src, target, true) connects both, false disconnects.
Bridge.RegisterIntegration('voice', 'yaca-voice', {
    label = 'YaCA', resource = 'yaca-voice', status = 'experimental', builtin = true,
    ServerJoin = function(_, sources)
        if sources[1] and sources[2] then exports['yaca-voice']:callPlayer(sources[1], sources[2], true) end
    end,
    ServerLeave = function(_, sources)
        if sources[1] and sources[2] then exports['yaca-voice']:callPlayer(sources[1], sources[2], false) end
    end,
})
