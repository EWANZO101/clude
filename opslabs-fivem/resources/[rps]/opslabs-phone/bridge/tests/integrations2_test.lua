local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

test('ox_core invoices: unpaid bills of the default account; paid through PayAccountInvoice (one transaction)', function()
    local paid
    local H = boot(function(H)
        local fx = F.ox(H)
        fx.add(1, { charId = 42, first = 'K', last = 'L', bank = 500 })
        H.exportsOf.ox_core.PayAccountInvoice = function(_, id, charId)
            if id == 9 then paid = { id, charId } return { success = true } end
            return { success = false, message = 'no_balance' }
        end
        H.sqlHandler = function(kind, q, params)
            if q:find('FROM accounts_invoices i JOIN accounts a') and kind == 'query' then return { { id = 9, label = 'Fine', amount = 200, target = 'LSPD' } } end
            if q:find('FROM accounts_invoices i JOIN accounts a') and kind == 'single' then
                if params[1] == 404 then return nil end
                return { id = params[1], label = 'Fine', amount = 200 }
            end
        end
    end)
    eq(FW.Integration('billing'), 'ox_core', 'picked on ox_core')
    eq(H.call(function() return FW.GetBills('42') end)[1].target, 'LSPD', 'issuer')
    local bill = H.call(function() return FW.PayBill(1, '42', 9) end)
    eq(bill.id, 9, 'paid') eq(paid[2], 42, 'as the character')
    local _, err = H.call(function() return FW.PayBill(1, '42', 10) end)
    eq(err, 'Insufficient funds', 'ox_core refusal explained')
    _, err = H.call(function() return FW.PayBill(1, '42', 404) end)
    eq(err, 'Bill not found or already paid', 'not theirs / paid')
end)

test('PayBill (take-first integrations): a failed payment puts the bill back', function()
    local bills = { { id = 3, identifier = 'c1', sender = 'x', target_type = 'society', target = 'society_police', label = 'Fine', amount = 900 } }
    local restored
    local H = boot(function(H)
        local fx = F.esx(H)
        fx.add(1, { identifier = 'c1', first = 'A', last = 'B', bank = 100 })
        H.resources.esx_billing = 'started'
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT %* FROM billing') then return bills[1] end
            if q:find('DELETE FROM billing') then return 1 end
            if q:find('INSERT INTO billing') then restored = params[1] return 1 end
        end
    end)
    local bill, err = H.call(function() return FW.PayBill(1, 'c1', 3) end)
    eq(bill, nil, 'not paid') eq(err, 'Insufficient funds', 'why') eq(restored, 3, 'bill restored')
end)

test('jg-advancedgarages: its in_garage / garage_id / impound / nickname columns, on ESX and QBCore', function()
    local H = boot(function(H)
        F.esx(H)
        H.resources['jg-advancedgarages'] = 'started'
        H.sqlHandler = function(kind, q) if q:find('FROM owned_vehicles') then
            return { { plate = 'JG1', vehicle = json.encode({ model = 55, fuelLevel = 40 }), in_garage = 1, garage_id = 'Legion', impound = 0, nickname = 'Daily' },
                     { plate = 'JG2', vehicle = '{}', in_garage = 0, impound = 1 } } end end
    end)
    eq(FW.Integration('garage'), 'jg-advancedgarages', 'picked')
    local v = H.call(function() return FW.GetVehicles('c1') end)
    eq(v[1].name, 'Daily', 'nickname') eq(v[1].parking, 'Legion', 'garage') eq(v[1].stored, true, 'in garage') eq(v[1].fuel, 40, 'fuel from props')
    eq(v[2].pound, 'Impound', 'impounded') eq(v[2].stored, false, 'not stored')

    H = boot(function(H)
        F.qb(H)
        H.resources['jg-advancedgarages'] = 'started'
        H.sqlHandler = function(kind, q) if q:find('FROM player_vehicles') then return { { plate = 'Q1', vehicle = 'sultan', hash = '123', in_garage = 1, garage_id = 'pillbox', fuel = 90 } } end end
    end)
    v = H.call(function() return FW.GetVehicles('QB1') end)
    eq(v[1].model, 123, 'hash') eq(v[1].fuel, 90, 'fuel column')
end)

test('housing: qb-houses (owned + key holder), ps-housing (door position), qbx_properties (rented)', function()
    local H = boot(function(H)
        F.qb(H)
        H.resources['qb-houses'] = 'started'
        H.sqlHandler = function(kind, q) if q:find('FROM player_houses') then
            return { { house = 'h1', citizenid = 'ME', label = 'Grove St 1', coords = '{"enter":{"x":1,"y":2,"z":3,"h":0}}' },
                     { house = 'h2', citizenid = 'OTHER', label = 'Mirror Park 4', coords = '{"enter":{"x":4,"y":5,"z":6}}' } } end end
    end)
    local homes = H.call(function() return FW.GetHomes('ME') end)
    eq(#homes, 2, 'two') eq(homes[1].kind, 'owned', 'owned') eq(homes[2].kind, 'key', 'key holder') eq(homes[2].x, 4, 'enter coords')

    H = boot(function(H)
        F.qbx(H)
        H.resources['ps-housing'] = 'started'
        H.sqlHandler = function(kind, q) if q:find('FROM properties') then
            return { { property_id = 1, owner_citizenid = 'ME', street = 'Vespucci Blvd', door_data = '{"x":9,"y":8,"z":7,"h":0,"length":1,"width":2}' },
                     { property_id = 2, owner_citizenid = 'ME', apartment = 'Alta', door_data = '{"count":2}' } } end end
    end)
    eq(FW.Integration('housing'), 'ps-housing', 'ps-housing first')
    homes = H.call(function() return FW.GetHomes('ME') end)
    eq(#homes, 1, 'MLO / apartment without a door position left out') eq(homes[1].label, 'Vespucci Blvd', 'street')

    H = boot(function(H)
        F.qbx(H)
        H.resources.qbx_properties = 'started'
        H.sqlHandler = function(kind, q) if q:find('FROM properties') then
            return { { id = 5, property_name = 'Del Perro Heights 7', coords = '{"x":1,"y":1,"z":1}', owner = 'ME', rent_interval = 168 } } end end
    end)
    eq(H.call(function() return FW.GetHomes('ME') end)[1].kind, 'rented', 'rented')
end)

test('housing integrations are only used on their framework', function()
    local H = boot(function(H) F.esx(H) H.resources['qb-houses'] = 'started' end)
    eq(FW.Integration('housing'), 'none', 'qb-houses ignored on ESX')
end)

test('voice on the server: SaltyChat adds both players to the call by name, YaCA connects the pair', function()
    local salty = {}
    local H = boot(function(H)
        F.esx(H)
        H.resources.saltychat = 'started'
        H.exportsOf.saltychat = {
            AddPlayerToCall = function(_, name, src) salty[#salty + 1] = 'add ' .. name .. ' ' .. src end,
            RemovePlayerFromCall = function(_, name, src) salty[#salty + 1] = 'remove ' .. name .. ' ' .. src end,
        }
    end)
    eq(FW.Integration('voice'), 'saltychat', 'picked')
    eq(GlobalState['opslabs-phone:bridge'].voice, 'saltychat', 'told to clients')
    H.call(function() FW.VoiceCallStarted(4, { 1, 2 }) FW.VoiceCallEnded(4, { 1, 2 }) end)
    eq(salty[1], 'add ops-call-4 1', 'add') eq(salty[2], 'add ops-call-4 2', 'add other') eq(salty[4], 'remove ops-call-4 2', 'removed')

    local yaca
    H = boot(function(H)
        F.esx(H)
        H.resources['yaca-voice'] = 'started'
        H.exportsOf['yaca-voice'] = { callPlayer = function(_, a, b, on) yaca = { a, b, on } end }
    end)
    H.call(function() FW.VoiceCallStarted(4, { 1, 2 }) end)
    eq(yaca[3], true, 'connected') eq(yaca[2], 2, 'pair')
end)

test('voice: Config.Calls.UsePmaVoice = false still means no call audio', function()
    local H = boot(function(H) F.esx(H) H.resources['pma-voice'] = 'started' Config.Calls = { UsePmaVoice = false } end)
    eq(FW.Integration('voice'), 'none', 'none')
end)

test('banking statements: Renewed-Banking handleTransaction and qb-banking CreateBankStatement, online players only', function()
    local rb
    local H = boot(function(H)
        local fx = F.qbx(H)
        fx.add(1, { citizenid = 'CID1', first = 'A', last = 'B', bank = 10 })
        H.resources['Renewed-Banking'] = 'started'
        H.exportsOf['Renewed-Banking'] = { handleTransaction = function(_, acc, title, amount, msg, issuer, receiver, kind) rb = { acc, amount, kind } end }
    end)
    H.call(function() FW.LogTransaction('CID1', -75, 'Transfer to 555-0101') end)
    eq(rb[1], 'CID1', 'citizenid account') eq(rb[2], 75, 'positive') eq(rb[3], 'withdraw', 'withdraw')
    rb = nil
    H.call(function() FW.LogTransaction('OFFLINE', 75, 'x') end)
    eq(rb, nil, 'offline skipped (Renewed-Banking would not keep it)')

    local qbst
    H = boot(function(H)
        local fx = F.qb(H)
        fx.add(2, { citizenid = 'Q2', first = 'A', last = 'B' })
        H.resources['qb-banking'] = 'started'
        H.exportsOf['qb-banking'] = { CreateBankStatement = function(_, src, acc, amount, reason, kind, accType) qbst = { src, acc, amount, kind, accType, reason } end }
    end)
    H.call(function() FW.LogTransaction('Q2', 30, string.rep('x', 80)) end)
    eq(qbst[1], 2, 'source') eq(qbst[2], 'checking', 'account') eq(qbst[4], 'deposit', 'deposit') eq(#qbst[6], 50, 'reason cut to 50')
end)

test('Renewed-Banking / qb-banking: society_ prefix is dropped (accounts are keyed by job name)', function()
    local added
    local H = boot(function(H)
        F.qbx(H)
        H.resources['Renewed-Banking'] = 'started'
        H.exportsOf['Renewed-Banking'] = { addAccountMoney = function(_, acc, n) added = acc return true end }
    end)
    H.call(function() FW.AddSocietyMoney('society_police', 10) end)
    eq(added, 'police', 'job name')
end)

test('okokBanking: a society withdrawal needs a readable balance first', function()
    local removed
    local H = boot(function(H)
        F.esx(H)
        H.resources.okokBanking = 'started'
        H.exportsOf.okokBanking = {
            GetAccount = function(_, s) return s == 'police' and { value = 100 } or nil end,
            RemoveMoney = function(_, s, n) removed = n return true end,
        }
        Config.Integrations = { banking = 'okokBanking' }
    end)
    eq(FW.Integration('banking'), 'okokBanking', 'picked')
    eq(H.call(function() return FW.RemoveSocietyMoney('police', 150) end), false, 'short')
    eq(H.call(function() return FW.RemoveSocietyMoney('unknown', 1) end), false, 'unreadable: refused')
    eq(H.call(function() return FW.RemoveSocietyMoney('police', 60) end), true, 'enough') eq(removed, 60, 'taken')
end)

-- esx_billing + esx_addonaccount fakes for the payment paths
local function billingServer(bills, accounts, bank)
    local events = {}
    local H = boot(function(H)
        local fx = F.esx(H)
        fx.add(1, { identifier = 'payer', first = 'P', last = 'Q', bank = bank })
        H.resources.esx_billing, H.resources.esx_addonaccount = 'started', 'started'
        AddEventHandler('esx_addonaccount:getSharedAccount', function(name, cb)
            local a = accounts[name]
            cb(a and { money = a.money, addMoney = function(n) a.money = a.money + n end } or nil)
        end)
        AddEventHandler('esx_billing:paidBill', function(src, id) events[#events + 1] = id end)
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT %* FROM billing') then for _, b in ipairs(bills) do if b.id == params[1] then return b end end return nil end
            if q:find('DELETE FROM billing') then for i, b in ipairs(bills) do if b.id == params[1] then table.remove(bills, i) return 1 end end return 0 end
            if q:find('INSERT INTO billing') then bills[#bills + 1] = { id = params[1], identifier = params[2], sender = params[3], target_type = params[4], target = params[5], label = params[6], amount = params[7] } return params[1] end
            if q:find('SELECT accounts FROM users') then return nil end      -- 'server' / unknown sender: no offline account
        end
    end)
    return H, events
end

test('PayBill: a society bill is removed, the payer charged, the society paid (esx_addonaccount directly), paidBill fired', function()
    local bills = { { id = 1, identifier = 'payer', sender = 'cop', target_type = 'society', target = 'society_police', label = 'Speeding', amount = 250 } }
    local accounts = { society_police = { money = 0 } }
    local H, events = billingServer(bills, accounts, 1000)
    Config.Integrations = nil
    local bill = H.call(function() return FW.PayBill(1, 'payer', 1) end)
    eq(bill.id, 1, 'paid') eq(#bills, 0, 'bill gone')
    eq(H.call(function() return FW.GetMoney(1, 'bank') end), 750, 'payer charged')
    eq(accounts.society_police.money, 250, 'society paid') eq(events[1], 1, 'esx_billing:paidBill')
end)

test('PayBill: when nobody can be paid (no society account / a "server" bill) the payer is refunded and the bill kept', function()
    local bills = { { id = 2, identifier = 'payer', sender = 'x', target_type = 'society', target = 'society_ghost', label = 'Fine', amount = 100 },
                    { id = 3, identifier = 'payer', sender = 'server', target_type = 'player', target = 'x', label = 'Tax', amount = 50 } }
    local H, events = billingServer(bills, {}, 1000)
    local bill, err = H.call(function() return FW.PayBill(1, 'payer', 2) end)
    eq(bill, nil, 'not paid') eq(err, "This bill can't be paid right now", 'explained')
    eq(H.call(function() return FW.GetMoney(1, 'bank') end), 1000, 'refunded')
    eq(#bills, 2, 'bill kept')
    bill = H.call(function() return FW.PayBill(1, 'payer', 3) end)
    eq(bill, nil, '"server" bill not paid') eq(H.call(function() return FW.GetMoney(1, 'bank') end), 1000, 'refunded again')
    eq(#events, 0, 'no paidBill for failed payments')
    ok(H.logged('refunded and kept unpaid'), 'logged for the admin')
end)

test('PayBill: two taps at once pay the bill only once (one-step integrations like ox_core)', function()
    local pays = 0
    local H = boot(function(H)
        local fx = F.ox(H)
        fx.add(1, { charId = 42, first = 'K', last = 'L', bank = 500 })
        H.exportsOf.ox_core.PayAccountInvoice = function() pays = pays + 1 Wait(200) return { success = true } end
        H.sqlHandler = function(kind, q, params) if kind == 'single' then return { id = 9, label = 'Fine', amount = 10 } end end
    end)
    local results = {}
    CreateThread(function() results[1] = { FW.PayBill(1, '42', 9) } end)
    CreateThread(function() results[2] = { FW.PayBill(1, '42', 9) } end)
    H.run()
    eq(pays, 1, 'paid once')
    eq(results[2][2] or results[1][2], 'This bill is already being paid', 'second tap told')
end)

test('integrations are picked again when a broken framework starts working (Garage no longer empty)', function()
    local fx
    local H = boot(function(H)
        fx = F.esx(H, { noExport = true })
        H.sqlHandler = function(kind, q) if q:find('FROM owned_vehicles') then return { { plate = 'AAA', vehicle = '{}' } } end end
    end)
    eq(FW.Integration('garage'), 'none', 'nothing while broken')
    H.exportsOf.es_extended = { getSharedObject = function() return fx.ESX end }
    H.run(20000)
    eq(FW.Integration('garage'), 'framework', 'owned_vehicles again')
    eq(#H.call(function() return FW.GetVehicles('c') end), 1, 'vehicles listed')
end)

test('okokBanking: no deposit into an account that does not exist', function()
    local added
    local H = boot(function(H)
        F.esx(H)
        H.resources.okokBanking = 'started'
        H.exportsOf.okokBanking = { GetAccount = function() return nil end, AddMoney = function() added = true return nil end }
    end)
    eq(H.call(function() return FW.AddSocietyMoney('ghost', 10) end), false, 'refused') eq(added, nil, 'nothing sent')
end)
