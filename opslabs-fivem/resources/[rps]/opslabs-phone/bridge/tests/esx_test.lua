local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

local function esxBoot(extra)
    local fx
    local H = boot(function(H)
        fx = F.esx(H)
        fx.add(1, { identifier = 'char1:abc', first = 'John', last = 'Doe', bank = 500, cash = 20, group = 'user',
            job = { name = 'police', label = 'LSPD', grade = 2, grade_label = 'Sergeant' }, items = { phone = 1 } })
        if extra then extra(H, fx) end
    end)
    return H, fx
end

test('ESX: detected, verified, version in the console', function()
    local H = esxBoot()
    eq(FW.Info().framework, 'esx', 'framework')
    eq(FW.Info().status, 'verified', 'status')
    ok(H.logged('Framework: ESX Legacy 1.0.0%-test %(detected%) · verified'), 'banner')
end)

test('ESX: player, name, job', function()
    local H = esxBoot()
    local p = H.call(function() return FW.Player(1) end)
    eq(p.identifier, 'char1:abc', 'identifier')
    eq(p.name, 'John Doe', 'name')
    eq(p.firstname, 'John', 'firstname')
    eq(p.job.name, 'police', 'job')
    eq(p.job.grade.level, 2, 'grade')
    eq(p.job.grade.name, 'Sergeant', 'grade name')
    eq(H.call(function() return FW.SourceOf('char1:abc') end), 1, 'SourceOf')
end)

test('ESX: money — cash maps to "money", no overdraft, no negative amounts', function()
    local H, fx = esxBoot()
    eq(H.call(function() return FW.GetMoney(1, 'cash') end), 20, 'cash')
    eq(H.call(function() return FW.RemoveMoney(1, 600, 'bank') end), false, 'refuses overdraft')
    eq(H.call(function() return FW.RemoveMoney(1, 100, 'bank') end), true, 'takes')
    eq(H.call(function() return FW.AddMoney(1, -50, 'bank') end), false, 'refuses negative')
    eq(H.call(function() return FW.GetMoney(1, 'bank') end), 400, 'balance')
end)

test('ESX: admin groups — admin/superadmin always, others when listed', function()
    local H, fx = esxBoot(function(H, fx) fx.add(2, { identifier = 'char1:o', first = 'O', last = 'W', group = 'owner' }) end)
    eq(H.call(function() return FW.IsAdmin(1) end), false, 'user')
    eq(H.call(function() return FW.IsAdmin(2) end), false, 'owner not listed')
    eq(H.call(function() return FW.IsAdmin(2, { 'owner' }) end), true, 'owner listed')
end)

test('ESX: offline money uses users.accounts', function()
    local stored = { bank = 50, money = 5 }
    local H = esxBoot(function(H)
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT accounts FROM users') then return json.encode(stored) end
            if q:find('UPDATE users SET accounts') then stored = json.decode(params[1]) return 1 end
        end
    end)
    eq(H.call(function() return FW.GetOfflineMoney('char2:x', 'bank') end), 50, 'read')
    eq(H.call(function() return FW.AddOfflineMoney('char2:x', 25, 'bank') end), true, 'add')
    eq(stored.bank, 75, 'stored')
    eq(H.call(function() return FW.RemoveOfflineMoney('char2:x', 100, 'bank') end), false, 'no overdraft offline')
    eq(H.call(function() return FW.GetOfflineMoney('char2:x', 'cash') end), 5, 'cash = money')
end)

test('ESX: bills from esx_billing; a taken bill can be restored', function()
    local bills = { { id = 7, identifier = 'char1:abc', sender = 'char1:cop', target_type = 'society', target = 'society_police', label = 'Speeding', amount = 250 } }
    local H = esxBoot(function(H)
        H.sqlHandler = function(kind, q, params)
            if q:find('SELECT id, label, amount, target FROM billing') then return bills end
            if q:find('SELECT %* FROM billing') then for _, b in ipairs(bills) do if b.id == params[1] then return b end end end
            if q:find('DELETE FROM billing') then for i, b in ipairs(bills) do if b.id == params[1] then table.remove(bills, i) return 1 end end return 0 end
            if q:find('INSERT INTO billing') then bills[#bills + 1] = { id = params[1], identifier = params[2] } return params[1] end
        end
    end)
    eq(#H.call(function() return FW.GetBills('char1:abc') end), 1, 'listed')
    local bill = H.call(function() return FW.TakeBill('char1:abc', 7) end)
    eq(bill.amount, 250, 'taken')
    eq(H.call(function() return FW.TakeBill('char1:abc', 7) end), nil, 'cannot take twice')
    H.call(function() return FW.RestoreBill(bill) end)
    eq(#bills, 1, 'restored')
end)

test('ESX: garage from owned_vehicles', function()
    local H = esxBoot(function(H)
        H.sqlHandler = function(kind, q)
            if q:find('FROM owned_vehicles') then
                return { { plate = 'OPS 2024', vehicle = json.encode({ model = 123, fuelLevel = 76, engineHealth = 980, bodyHealth = 940 }), type = 'car', stored = 1, parking = 'Legion', custom_name = 'Sultan' } }
            end
        end
    end)
    local v = H.call(function() return FW.GetVehicles('char1:abc') end)[1]
    eq(v.plate, 'OPS 2024', 'plate')
    eq(v.model, 123, 'model')
    eq(v.stored, true, 'stored')
    eq(v.fuel, 76, 'fuel')
end)

test('ESX: esx:playerLoaded / esx:playerLogout reach FW.OnPlayerLoaded / Unloaded once', function()
    local H = esxBoot()
    local loads, unloads = {}, {}
    FW.OnPlayerLoaded(function(src) loads[#loads + 1] = src end)
    FW.OnPlayerUnloaded(function(src) unloads[#unloads + 1] = src end)
    H.emit('esx:playerLoaded', nil, 1, {}, false)
    H.emit('esx:playerLoaded', nil, 1, {}, false)   -- duplicate within 3 s: ignored
    H.emit('esx:playerLogout', nil, 1)
    H.run()
    eq(#loads, 1, 'loaded once')
    eq(loads[1], 1, 'loaded source')
    eq(unloads[1], 1, 'unloaded source')
end)

test('ESX: usable items and the ESX inventory (no other inventory running)', function()
    local H, fx = esxBoot()
    eq(FW.Info().inventory, 'framework', 'inventory = ESX')
    eq(H.call(function() return FW.ItemCount(1, 'phone') end), 1, 'count')
    H.call(function() return FW.RemoveItem(1, 'phone', 1) end)
    eq(H.call(function() return FW.ItemCount(1, 'phone') end), 0, 'removed')
    local used
    H.call(function() FW.UsableItem('ops_buds', function(src) used = src end) end)
    fx.usable.ops_buds(1)
    eq(used, 1, 'usable handler gets the source')
end)

test('ESX: names of phone owners are backfilled once from users', function()
    local H = esxBoot(function(H)
        H.sqlHandler = function(kind, q) if q:find('UPDATE opslabs_phone_users p JOIN users u') then return 12 end end
    end)
    ok(H.logged('Saved the character names of 12 phone owners from ESX Legacy'), 'backfill logged')
end)
