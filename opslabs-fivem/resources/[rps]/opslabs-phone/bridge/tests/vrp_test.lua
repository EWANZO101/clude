local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

test('vRP 1: through the Proxy — user id, identity, job group, wallet / bank', function()
    local fx
    local H = boot(function(H)
        fx = F.vrp(H)
        fx.add(3, 17, { first = 'Rui', last = 'Costa', cash = 40, bank = 100, groups = { _job = 'taxi', admin = true } })
    end)
    eq(FW.Info().framework, 'vrp', 'framework')
    local p = H.call(function() return FW.Player(3) end)
    eq(p.identifier, '17', 'user id')
    eq(p.name, 'Rui Costa', 'identity')
    eq(p.job.label, 'TAXI', 'group title')
    eq(H.call(function() return FW.GetMoney(3, 'cash') end), 40, 'wallet')
    eq(H.call(function() return FW.RemoveMoney(3, 150, 'bank') end), false, 'overdraft refused')
    eq(H.call(function() return FW.RemoveMoney(3, 60, 'bank') end), true, 'pay from bank')
    eq(fx.bank(17), 40, 'bank debited')
    eq(H.call(function() return FW.IsAdmin(3) end), true, 'admin group')
    eq(H.call(function() return FW.SourceOf('17') end), 3, 'SourceOf')
end)

test('vRP: a Creative-style vRP is recognised and sent to a custom adapter, not guessed at', function()
    local H = boot(function(H)
        H.resources.vrp = 'started'
        H.files.vrp = { ['modules/base.lua'] = 'function vRP.Passport(source) end' }
    end)
    ok(H.logged('Creative%-style vRP'), 'explained')
    eq(FW.Info().status, 'failed', 'no phones rather than guessing')
end)

test('vRP: vRP:playerSpawn on first spawn only, vRP:playerLeave', function()
    local H = boot(function(H) F.vrp(H) end)
    local loads, unloaded = 0, nil
    FW.OnPlayerLoaded(function() loads = loads + 1 end)
    FW.OnPlayerUnloaded(function(src) unloaded = src end)
    H.emit('vRP:playerSpawn', nil, 17, 3, true)
    H.emit('vRP:playerSpawn', nil, 17, 3, false)   -- respawn after death: not a new character
    H.emit('vRP:playerLeave', nil, 17, 3)
    H.run()
    eq(loads, 1, 'first spawn only') eq(unloaded, 3, 'leave')
end)
