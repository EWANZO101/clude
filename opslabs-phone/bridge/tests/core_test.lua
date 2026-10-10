local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

test('no framework running: standalone fallback, console says so', function()
    local H = boot()
    eq(FW.Info().framework, 'standalone', 'framework')
    eq(FW.Info().how, 'fallback', 'how')
    ok(H.logged('Framework: Standalone'), 'console banner')
    eq(GlobalState['opslabs-phone:bridge'].framework, 'standalone', 'GlobalState for clients')
end)

test('standalone: license identifier, FiveM name, no money, ace admin', function()
    local H = boot(function(H) H.players[3] = { name = 'Bob', ids = { license = 'license:abc' } } H.aces[3] = { command = true } end)
    local p = H.call(function() return FW.Player(3) end)
    eq(p.identifier, 'license:abc', 'identifier')
    eq(p.name, 'Bob', 'name')
    eq(H.call(function() return FW.GetMoney(3, 'bank') end), 0, 'money')
    eq(H.call(function() return FW.RemoveMoney(3, 10, 'bank') end), false, 'cannot pay')
    eq(H.call(function() return FW.IsAdmin(3) end), true, 'admin via ace')
end)

test('a recognised but unsupported framework is named in a warning', function()
    local H = boot(function(H) H.resources.vorp_core = 'started' end)
    ok(H.logged('VORP %(RedM%) is running, but OPS Phone has no adapter'), 'warning')
    eq(FW.Info().framework, 'standalone', 'falls back')
end)

test('Config.Framework overrides detection', function()
    local H = boot(function(H) F.esx(H) Config.Framework = 'standalone' end)
    eq(FW.Info().framework, 'standalone', 'forced')
    eq(FW.Info().how, 'config', 'how')
end)

test('a convar wins over config.lua', function()
    local H = boot(function(H) F.esx(H) Config.Framework = 'standalone' H.convars['opslabs_phone:framework'] = 'esx' end)
    eq(FW.Info().framework, 'esx', 'convar')
    eq(FW.Info().how, 'convar', 'how')
end)

test('an unknown override is reported and detection runs instead', function()
    local H = boot(function(H) F.esx(H) Config.Framework = 'nonsense' end)
    ok(H.logged('Framework "nonsense" %(from config%) has no adapter'), 'error logged')
    eq(FW.Info().framework, 'esx', 'detected anyway')
end)

test('a framework that is running but broken loads no phones (never standalone), and recovers when it works', function()
    local fx
    local H = boot(function(H)
        fx = F.esx(H, { noExport = true })
        fx.add(1, { identifier = 'char1:abc', first = 'A', last = 'B' })
        H.players[1].ids = { license = 'license:abc' }
    end)
    ok(H.logged('failed its check'), 'error logged')
    ok(H.logged('No phones will load'), 'explained')
    eq(FW.Info().framework, 'esx', 'still ESX')
    eq(FW.Info().status, 'failed', 'status')
    eq(H.call(function() return FW.Player(1) end), nil, 'no player: no phone keyed by license')
    -- es_extended comes back (e.g. it was restarting)
    H.exportsOf.es_extended = { getSharedObject = function() return fx.ESX end }
    H.run(20000)
    ok(H.logged('works now'), 'recovered')
    eq(H.call(function() return FW.Player(1) end).identifier, 'char1:abc', 'ESX identifier')
end)

test('money is rounded like ESX does, not floored', function()
    local fx
    local H = boot(function(H) fx = F.esx(H) fx.add(1, { identifier = 'c', first = 'A', last = 'B', bank = 1000 }) end)
    eq(H.call(function() return FW.RemoveMoney(1, 150.5, 'bank') end), true, 'pays')
    eq(H.call(function() return FW.GetMoney(1, 'bank') end), 849, '151 taken')
    eq(H.call(function() return FW.RemoveMoney(1, 0.4, 'bank') end), true, 'rounds to nothing: done')
    eq(H.call(function() return FW.RemoveMoney(1, -5, 'bank') end), false, 'negative refused')
end)

test('a job change during the session reaches FW.OnJobChanged', function()
    local H = boot(function(H) F.esx(H) end)
    local changed
    FW.OnJobChanged(function(src) changed = src end)
    H.emit('esx:setJob', nil, 4, { name = 'police' }, { name = 'unemployed' })
    H.run()
    eq(changed, 4, 'job change')
end)

test('an adapter error is caught, logged once, and the call returns a safe value', function()
    local H = boot(function(H)
        local fx = F.esx(H)
        fx.ESX.GetPlayerFromId = function() error('boom') end
    end)
    eq(H.call(function() return FW.Player(1) end), nil, 'Player')
    eq(H.call(function() return FW.Player(1) end), nil, 'Player again')
    eq(H.call(function() return FW.GetMoney(1) end), 0, 'GetMoney')
    local n = 0
    for _, l in ipairs(H.logs) do if l:find('GetPlayer failed') then n = n + 1 end end
    eq(n, 1, 'logged once')
end)

test('framework still starting: detection waits for it', function()
    local H = boot(function(H)
        F.esx(H)
        H.resources.es_extended = 'starting'
        SetTimeout(1200, function() H.resources.es_extended = 'started' end)
    end)
    eq(FW.Info().framework, 'esx', 'waited for es_extended')
end)

test('usable items registered before the bridge is ready are queued, then registered', function()
    local fx
    local H = boot(function(H) fx = F.esx(H) end, nil, { 'bridge/tests/usable_at_load.lua' })
    ok(fx.usable.ops_buds, 'registered with ESX after start-up')
end)

test('a custom adapter in bridge/custom wins over the built-in detection', function()
    local H = boot(function(H) F.esx(H) end, { 'bridge/tests/custom_adapter.lua' })
    eq(FW.Info().framework, 'mycity', 'custom adapter')
    eq(FW.Info().status, 'custom', 'status')
    eq(H.call(function() return FW.Player(9) end).identifier, 'mycity:9', 'custom GetPlayer')
end)

test('an adapter registered by another resource (export) is waited for when named in config', function()
    local H = boot(function(H)
        F.esx(H)
        Config.Framework = 'latefw'
        SetTimeout(2000, function()
            H.ownExports.RegisterFrameworkAdapter('latefw', { detect = function() return true end, GetPlayer = function(src) return { identifier = 'late' .. src } end })
        end)
    end)
    eq(FW.Info().framework, 'latefw', 'late adapter used')
end)

test('opslabs.admin ACE makes anyone an admin on any framework', function()
    local H = boot(function(H) local fx = F.esx(H) fx.add(4, { identifier = 'char1:x', first = 'A', last = 'B', group = 'user' }) H.aces[4] = { ['opslabs.admin'] = true } end)
    eq(H.call(function() return FW.IsAdmin(4) end), true, 'ace admin')
end)
