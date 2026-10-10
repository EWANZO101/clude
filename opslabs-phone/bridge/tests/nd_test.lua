local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

test('ND Core: charid identifier, job info, money with the balance checked (deductMoney does not)', function()
    local fx, p
    local H = boot(function(H)
        fx = F.nd(H)
        p = fx.add(2, { charid = 9, first = 'Nia', last = 'Dee', bank = 50, cash = 5, job = 'ems', jobInfo = { label = 'EMS', rank = 3, rankName = 'Paramedic' } })
    end)
    eq(FW.Info().framework, 'nd', 'framework')
    local pl = H.call(function() return FW.Player(2) end)
    eq(pl.identifier, '9', 'charid')
    eq(pl.job.grade.name, 'Paramedic', 'rank name')
    eq(H.call(function() return FW.RemoveMoney(2, 80, 'bank') end), false, 'overdraft refused')
    eq(p.bank, 50, 'untouched')
    eq(H.call(function() return FW.RemoveMoney(2, 20, 'bank') end), true, 'pay')
    eq(p.bank, 30, 'debited')
    eq(H.call(function() return FW.SourceOf('9') end), 2, 'SourceOf')
end)

test('ND Core: ND:characterLoaded / ND:characterUnloaded', function()
    local fx, p
    local H = boot(function(H) fx = F.nd(H) p = fx.add(7, { charid = 1, first = 'A', last = 'B' }) end)
    local loaded, unloaded
    FW.OnPlayerLoaded(function(src) loaded = src end)
    FW.OnPlayerUnloaded(function(src) unloaded = src end)
    H.emit('ND:characterLoaded', nil, p)
    H.emit('ND:characterUnloaded', nil, 7, p)
    H.run()
    eq(loaded, 7, 'loaded') eq(unloaded, 7, 'unloaded')
end)

test('ND Core: offline money only taken when there is enough (one SQL statement)', function()
    local H = boot(function(H)
        F.nd(H)
        H.sqlHandler = function(kind, q, params)
            if q:find('UPDATE nd_characters SET bank = bank %- %? WHERE charid = %? AND bank >= %?') then return params[1] <= 50 and 1 or 0 end
        end
    end)
    eq(H.call(function() return FW.RemoveOfflineMoney('9', 80, 'bank') end), false, 'not enough')
    eq(H.call(function() return FW.RemoveOfflineMoney('9', 30, 'bank') end), true, 'enough')
end)
