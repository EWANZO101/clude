local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')
local JOB = { name = 'mechanic', label = 'Mechanic', grade = { level = 1, name = 'Apprentice' } }

test('Qbox: detected before QBCore although it also answers to qb-core', function()
    boot(function(H) F.qbx(H) end)
    eq(FW.Info().framework, 'qbx', 'framework')
    eq(FW.Info().status, 'experimental', 'status')
end)

test('Qbox: player, job, money (bank overdraft refused), offline money through the citizenid', function()
    local fx
    local H = boot(function(H)
        fx = F.qbx(H)
        fx.add(1, { citizenid = 'ABC123', first = 'Ada', last = 'Lane', bank = 300, cash = 10, job = JOB })
        fx.addOffline('OFF999', { first = 'Off', last = 'Line', bank = 40 })
        H.sqlHandler = function(kind, q, params) if q:find('SELECT money FROM players') then return params[1] == 'OFF999' and json.encode({ bank = 40, cash = 0 }) or nil end end
    end)
    local p = H.call(function() return FW.Player(1) end)
    eq(p.identifier, 'ABC123', 'citizenid')
    eq(p.name, 'Ada Lane', 'name from charinfo')
    eq(p.job.grade.name, 'Apprentice', 'grade')
    eq(H.call(function() return FW.SourceOf('ABC123') end), 1, 'SourceOf')
    eq(H.call(function() return FW.RemoveMoney(1, 500, 'bank') end), false, 'Qbox lets bank go negative: the bridge refuses first')
    eq(H.call(function() return FW.RemoveMoney(1, 100, 'bank') end), true, 'pays')
    eq(H.call(function() return FW.GetMoney(1, 'bank') end), 200, 'balance')
    eq(H.call(function() return FW.AddOfflineMoney('OFF999', 15, 'bank') end), true, 'offline credit via export')
    eq(H.call(function() return FW.RemoveOfflineMoney('OFF999', 1000, 'bank') end), false, 'offline overdraft refused')
end)

test('Qbox: usable items and admin ACE', function()
    local fx
    local H = boot(function(H) fx = F.qbx(H) H.aces[2] = { admin = true } end)
    local used
    H.call(function() FW.UsableItem('ops_buds', function(src) used = src end) end)
    fx.usable.ops_buds(5)
    eq(used, 5, 'usable')
    eq(H.call(function() return FW.IsAdmin(2) end), true, 'admin ace')
    eq(H.call(function() return FW.IsAdmin(3) end), false, 'not admin')
end)

test('QBCore: player, money, offline money in players.money', function()
    local stored = { bank = 70, cash = 3 }
    local fx
    local H = boot(function(H)
        fx = F.qb(H)
        fx.add(4, { citizenid = 'QB1', first = 'Max', last = 'Payne', bank = 100, job = JOB })
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT money FROM players') then return json.encode(stored) end
            if q:find('UPDATE players SET money') then stored = json.decode(params[1]) return 1 end
        end
    end)
    eq(FW.Info().framework, 'qb', 'framework')
    eq(H.call(function() return FW.Player(4) end).identifier, 'QB1', 'citizenid')
    eq(H.call(function() return FW.RemoveMoney(4, 150, 'bank') end), false, 'overdraft refused')
    eq(H.call(function() return FW.AddMoney(4, 25, 'bank') end), true, 'add')
    eq(H.call(function() return FW.GetMoney(4, 'bank') end), 125, 'balance')
    eq(H.call(function() return FW.AddOfflineMoney('QB2', 30, 'bank') end), true, 'offline add')
    eq(stored.bank, 100, 'offline stored')
end)

test('QBCore / Qbox: QBCore:Server:PlayerLoaded and OnPlayerUnload reach the phone', function()
    local fx
    local H = boot(function(H) fx = F.qb(H) end)
    local p = fx.add(6, { citizenid = 'QB6', first = 'A', last = 'B' })
    local loaded, unloaded
    FW.OnPlayerLoaded(function(src) loaded = src end)
    FW.OnPlayerUnloaded(function(src) unloaded = src end)
    H.emit('QBCore:Server:PlayerLoaded', nil, p)
    H.emit('QBCore:Server:OnPlayerUnload', nil, 6)
    H.run()
    eq(loaded, 6, 'loaded')
    eq(unloaded, 6, 'unloaded')
end)

test('QBCore / Qbox: garage from player_vehicles (state 1 = garaged, 2 = impounded)', function()
    local H = boot(function(H)
        F.qb(H)
        H.sqlHandler = function(kind, q) if q:find('FROM player_vehicles') then
            return { { plate = 'AAA111', vehicle = 'sultan', hash = '970598228', garage = 'pillbox', state = 1, fuel = 80, engine = 990, body = 1000, mods = '{}' },
                     { plate = 'BBB222', vehicle = 'blista', garage = 'pillbox', state = 2, mods = '{"model":123}' } } end end
    end)
    local v = H.call(function() return FW.GetVehicles('QB1') end)
    eq(v[1].model, 970598228, 'hash column')
    eq(v[1].stored, true, 'garaged')
    eq(v[1].fuel, 80, 'fuel')
    eq(v[2].model, 123, 'model from mods')
    eq(v[2].pound, 'Impound', 'impounded')
end)
