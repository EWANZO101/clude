local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

-- esx_addonaccount (server/main.lua): getSharedAccount event with a callback; removeMoney doesn't check
local function addonaccount(H, accounts)
    H.resources.esx_addonaccount = 'started'
    AddEventHandler('esx_addonaccount:getSharedAccount', function(name, cb)
        local a = accounts[name]
        cb(a and { money = a.money, addMoney = function(n) a.money = a.money + n end, removeMoney = function(n) a.money = a.money - n end } or nil)
    end)
end

test('integrations: the console lists what was chosen; ESX picks esx_billing / esx_addonaccount / esx_property', function()
    local H = boot(function(H)
        F.esx(H)
        H.resources.esx_billing, H.resources.esx_property = 'started', 'started'
        addonaccount(H, {})
    end)
    eq(FW.Integration('billing'), 'esx_billing', 'billing')
    eq(FW.Integration('banking'), 'esx_addonaccount', 'banking')
    eq(FW.Integration('housing'), 'esx_property', 'housing')
    eq(FW.Integration('garage'), 'framework', 'garage = owned_vehicles')
    ok(H.logged('Integrations: banking esx_addonaccount · billing esx_billing · garage ESX Legacy %(built in%) · housing esx_property'), 'console line')
end)

test('integrations: billing with nothing running is "none" — the Wallet shows no bills', function()
    local H = boot(function(H) F.esx(H) end)
    eq(FW.Integration('billing'), 'none', 'none')
    eq(#H.call(function() return FW.GetBills('x') end), 0, 'no bills')
end)

test('integrations: a configured resource that is not running is reported, and detection takes over', function()
    local H = boot(function(H) F.esx(H) H.resources.esx_addonaccount = 'started' Config.Integrations = { banking = 'qb-banking' } end)
    ok(H.logged("banking: \"qb%-banking\" is set in config, but qb%-banking isn't running"), 'reported')
    eq(FW.Integration('banking'), 'esx_addonaccount', 'detected instead')
end)

test('integrations: a name with no adapter at all is reported as such', function()
    local H = boot(function(H) F.esx(H) H.resources.esx_billing = 'started' Config.Integrations = { billing = 'okokBilling' } end)
    ok(H.logged('billing: "okokBilling" %(from config%) has no adapter'), 'reported with the name as typed')
    eq(FW.Integration('billing'), 'esx_billing', 'detected instead')
end)

test('integrations: an ESX-only integration is never picked on another framework', function()
    local H = boot(function(H) F.qb(H) H.resources.esx_billing = 'started' H.resources.esx_addonaccount = 'started' end)
    eq(FW.Integration('billing'), 'none', 'esx_billing skipped on QBCore')
    eq(FW.Integration('banking'), 'none', 'esx_addonaccount skipped on QBCore')
end)

test('integrations: a convar picks one', function()
    local H = boot(function(H) F.esx(H) H.resources.esx_billing = 'started' H.convars['opslabs_phone:billing'] = 'none' end)
    eq(FW.Integration('billing'), 'none', 'turned off by convar')
end)

test('esx_addonaccount: society deposits and withdrawals (no overdraft), exact name then society_ prefix', function()
    local accounts = { society_police = { money = 100 }, mechanic_custom = { money = 5 } }
    local H = boot(function(H) F.esx(H) addonaccount(H, accounts) end)
    eq(H.call(function() return FW.AddSocietyMoney('police', 50) end), true, 'police → society_police')
    eq(accounts.society_police.money, 150, 'credited')
    eq(H.call(function() return FW.RemoveSocietyMoney('society_police', 500) end), false, 'no overdraft')
    eq(H.call(function() return FW.RemoveSocietyMoney('mechanic_custom', 5) end), true, 'exact custom name')
    eq(accounts.mechanic_custom.money, 0, 'debited')
end)

test('esx_billing: a society bill pays the society, a player bill pays the sender (even offline), paidBill fires', function()
    local accounts = { society_police = { money = 0 } }
    local credited, paidEvent
    local H = boot(function(H)
        local fx = F.esx(H)
        fx.add(1, { identifier = 'char1:payer', first = 'P', last = 'Q', bank = 1000 })
        H.resources.esx_billing = 'started'
        addonaccount(H, accounts)
        AddEventHandler('esx_billing:paidBill', function(src, id) paidEvent = { src, id } end)
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT accounts FROM users') then return json.encode({ bank = 10 }) end
            if q:find('UPDATE users SET accounts') then credited = json.decode(params[1]).bank return 1 end
        end
    end)
    H.call(function() FW.SettleBill({ id = 4, target_type = 'society', target = 'society_police', amount = 300 }, 1) end)
    eq(accounts.society_police.money, 300, 'society paid')
    eq(paidEvent[2], 4, 'esx_billing:paidBill')
    H.call(function() FW.SettleBill({ id = 5, target_type = 'player', sender = 'char1:offline', amount = 40 }, 1) end)
    eq(credited, 50, 'offline sender credited')
end)

test('esx_banking: phone transfers go into the bank statement (online players)', function()
    local logged
    local H = boot(function(H)
        local fx = F.esx(H)
        fx.add(1, { identifier = 'char1:a', first = 'A', last = 'B' })
        addonaccount(H, {})
        H.resources.esx_banking = 'started'
        H.exportsOf.esx_banking = { logTransaction = function(_, src, label, key, amount) logged = { src, label, key, amount } end }
    end)
    H.call(function() FW.LogTransaction('char1:a', -250, 'Transfer to 555-0101') end)
    -- esx_banking's statement shows TRANSFER as money out, TRANSFER_RECEIVE as money in
    eq(logged[1], 1, 'source') eq(logged[3], 'TRANSFER', 'type') eq(logged[4], 250, 'positive amount')
end)

test('esx_banking: an offline player gets the same statement row esx_banking writes', function()
    local row
    local H = boot(function(H)
        F.esx(H)
        addonaccount(H, {})
        H.resources.esx_banking = 'started'
        H.exportsOf.esx_banking = {}
        H.sqlHandler = function(kind, q, params)
            if q:find('INSERT INTO banking') then row = params return 1 end
            if q:find('SELECT accounts FROM users') then return json.encode({ bank = 77 }) end
        end
    end)
    H.call(function() FW.LogTransaction('char1:off', 40, 'Transfer from 555-0102') end)
    eq(row[3], 'TRANSFER_RECEIVE', 'type') eq(row[4], 40, 'amount') eq(row[6], 77, 'balance after')
end)

test('esx_property: owned and keyed homes with their entrance', function()
    local H = boot(function(H)
        F.esx(H)
        H.resources.esx_property = 'started'
        H.files.esx_property = { ['properties.json'] = json.encode({
            { Name = '1076 Procopio Dr', Owned = true, Owner = 'char1:me', Keys = {}, Entrance = { x = 1, y = 2, z = 3 } },
            { Name = 'Vinewood Hills', Owned = true, Owner = 'char1:friend', Keys = { ['char1:me'] = true }, Entrance = { x = 4, y = 5, z = 6 } },
            { Name = 'Someone else', Owned = true, Owner = 'char1:x', Keys = {}, Entrance = { x = 7, y = 8, z = 9 } },
        }) }
    end)
    local homes = H.call(function() return FW.GetHomes('char1:me') end)
    eq(#homes, 2, 'two homes')
    eq(homes[1].kind, 'owned', 'owned') eq(homes[2].kind, 'key', 'key holder') eq(homes[2].x, 4, 'entrance')
end)

test('Renewed-Banking / qb-banking: society money on Qbox / QBCore, no overdraft', function()
    local bal = { mechanic = 100 }
    local H = boot(function(H)
        F.qbx(H)
        H.resources['Renewed-Banking'] = 'started'
        H.exportsOf['Renewed-Banking'] = {
            addAccountMoney = function(_, a, n) bal[a] = (bal[a] or 0) + n return true end,
            removeAccountMoney = function(_, a, n) if (bal[a] or 0) < n then return false end bal[a] = bal[a] - n return true end,
        }
    end)
    eq(FW.Integration('banking'), 'Renewed-Banking', 'detected')
    eq(H.call(function() return FW.RemoveSocietyMoney('mechanic', 150) end), false, 'short')
    eq(H.call(function() return FW.AddSocietyMoney('mechanic', 25) end), true, 'add') eq(bal.mechanic, 125, 'credited')

    local qbBal = { police = 10 }
    H = boot(function(H)
        F.qb(H)
        H.resources['qb-banking'] = 'started'
        H.exportsOf['qb-banking'] = {
            GetAccountBalance = function(_, a) return qbBal[a] end,
            RemoveMoney = function(_, a, n) qbBal[a] = qbBal[a] - n return true end,   -- no check of its own
            AddMoney = function(_, a, n) qbBal[a] = qbBal[a] + n return true end,
        }
    end)
    eq(H.call(function() return FW.RemoveSocietyMoney('police', 50) end), false, 'qb-banking: we check first')
    eq(qbBal.police, 10, 'untouched')
end)
