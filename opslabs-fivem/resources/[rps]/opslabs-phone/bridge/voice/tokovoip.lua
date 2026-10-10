-- TokoVOIP. Experimental: from its source (tokovoip_script). It has no call exports: a call is a radio channel joined
-- with its client events. Call channels start at 100000 so they never meet a real radio frequency.
local function channel(call) return 100000 + (tonumber(call.channel) or 0) end
Bridge.RegisterIntegration('voice', 'tokovoip_script', {
    label = 'TokoVOIP', resource = 'tokovoip_script', status = 'experimental', builtin = true,
    Join = function(call) TriggerEvent('TokoVoip:addPlayerToRadio', channel(call), false) end,
    Leave = function(call) if call and call.channel then TriggerEvent('TokoVoip:removePlayerFromRadio', channel(call)) end end,
})
