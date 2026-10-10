-- the client half: the server's choice arrives in GlobalState, the matching client adapters turn framework events
-- into FW.OnPlayerLoaded / OnPlayerUnloaded / OnInventoryChanged

local function client(choice, extra)
    H.reset()
    H.load(H_ROOT, { 'bridge/shared.lua', 'bridge/voice/pma-voice.lua', 'bridge/voice/tokovoip.lua', 'bridge/voice/mumble-voip.lua' })
    for _, f in ipairs({ 'esx', 'qb', 'ox', 'nd', 'vrp', 'standalone' }) do H.load(H_ROOT, { 'bridge/client/frameworks/' .. f .. '.lua' }) end
    for _, f in ipairs({ 'ox_inventory', 'qb' }) do H.load(H_ROOT, { 'bridge/client/inventories/' .. f .. '.lua' }) end
    if extra then H.load(H_ROOT, extra) end
    H.load(H_ROOT, { 'bridge/client/core.lua' })
    local seen = { loaded = 0, unloaded = 0, inv = {} }
    FW.OnPlayerLoaded(function() seen.loaded = seen.loaded + 1 end)
    FW.OnPlayerUnloaded(function() seen.unloaded = seen.unloaded + 1 end)
    FW.OnInventoryChanged(function(item) seen.inv[#seen.inv + 1] = item == nil and '?' or item end)
    SetTimeout(500, function() GlobalState['opslabs-phone:bridge'] = choice end)   -- the server decides a moment later
    H.run()
    return seen
end

test('client ESX + ox_inventory: load / logout events; items through ox_inventory:itemCount', function()
    local seen = client({ framework = 'esx', inventory = 'ox_inventory' })
    H.emit('esx:playerLoaded', nil, {}, false)
    H.emit('esx:onPlayerLogout', nil)
    H.emit('ox_inventory:itemCount', nil, 'phone', 0)
    H.emit('esx:addInventoryItem', nil, 'phone', 1)      -- ox_inventory also sends these on ESX: counted once, through itemCount
    H.run()
    eq(seen.loaded, 1, 'loaded') eq(seen.unloaded, 1, 'unloaded')
    eq(#seen.inv, 1, 'one inventory change') eq(seen.inv[1], 'phone', 'item name')
    eq(FW.HasInventoryEvents(), true, 'has inventory events')
end)

test('client ESX with its own inventory: esx:addInventoryItem / removeInventoryItem', function()
    local seen = client({ framework = 'esx', inventory = 'framework' })
    H.emit('esx:removeInventoryItem', nil, 'phone', 1)
    H.run()
    eq(seen.inv[1], 'phone', 'item')
end)

test('client QBCore + qb-inventory: only item updates count, bursts are merged', function()
    local seen = client({ framework = 'qb', inventory = 'qb-inventory' })
    H.emit('QBCore:Client:OnPlayerLoaded', nil)
    H.emit('QBCore:Client:OnPlayerUpdated', nil, 'metadata', {})   -- hunger: ignored
    H.emit('QBCore:Client:OnPlayerUpdated', nil, 'items', {})
    H.emit('QBCore:Player:SetPlayerData', nil, {})
    H.emit('QBCore:Player:SetPlayerData', nil, {})
    H.run()
    eq(seen.loaded, 1, 'loaded')
    eq(#seen.inv, 1, 'merged into one re-check')
    eq(seen.inv[1], '?', 'item unknown')
end)

test('client: an inventory with no client events makes the phone re-check on every open', function()
    client({ framework = 'qb', inventory = 'qs-inventory' })
    eq(FW.HasInventoryEvents(), false, 'no events')
    ok(H.logged('no client adapter for inventory "qs%-inventory"'), 'explained')
end)

test('client: unknown framework name falls back to standalone and says so', function()
    client({ framework = 'mycity', inventory = 'none' })
    ok(H.logged('no client adapter for framework "mycity"'), 'warned')
end)

test('client: a custom client adapter in bridge/custom/client is used', function()
    local seen = client({ framework = 'mycity', inventory = 'none' }, { 'bridge/tests/custom_client.lua' })
    H.emit('mycity:loaded', nil)
    H.run()
    eq(seen.loaded, 1, 'custom loaded event')
end)

test('client ox_core / ND events', function()
    local seen = client({ framework = 'ox', inventory = 'ox_inventory' })
    H.emit('ox:playerLoaded', nil, {}, false) H.emit('ox:playerLogout', nil) H.run()
    eq(seen.loaded, 1, 'ox loaded') eq(seen.unloaded, 1, 'ox logout')
    seen = client({ framework = 'nd', inventory = 'ox_inventory' })
    H.emit('ND:characterLoaded', nil, {}) H.emit('ND:characterUnloaded', nil) H.run()
    eq(seen.loaded, 1, 'nd loaded') eq(seen.unloaded, 1, 'nd unloaded')
end)

test('client voice: pma-voice joins the call channel and leaves with 0; TokoVOIP uses a radio channel above 100000', function()
    client({ framework = 'esx', inventory = 'ox_inventory', voice = 'pma-voice' })
    local set = {}
    H.exportsOf['pma-voice'] = { setCallChannel = function(_, n) set[#set + 1] = n end }
    FW.VoiceJoin({ id = 12, channel = 12, peer = 3 })
    FW.VoiceLeave({ id = 12, channel = 12 })
    eq(set[1], 12, 'joined') eq(set[2], 0, 'left')

    client({ framework = 'qb', inventory = 'none', voice = 'tokovoip_script' })
    local radio = {}
    AddEventHandler('TokoVoip:addPlayerToRadio', function(ch) radio.join = ch end)
    AddEventHandler('TokoVoip:removePlayerFromRadio', function(ch) radio.leave = ch end)
    FW.VoiceJoin({ id = 7, channel = 7 }) FW.VoiceLeave({ id = 7, channel = 7 }) H.run()
    eq(radio.join, 100007, 'radio channel') eq(radio.leave, 100007, 'left')
end)

test('client voice: an error in the voice resource is caught and reported', function()
    client({ framework = 'esx', inventory = 'none', voice = 'pma-voice' })
    H.exportsOf['pma-voice'] = { setCallChannel = function() error('voice_enableCalls is off') end }
    FW.VoiceJoin({ id = 1, channel = 1 })
    ok(H.logged('joining the call failed'), 'reported')
end)
