-- OPS POS Systems: stores, tills, sales, payments, stock, staff hours, loyalty, licences and the NPC shop link.
--
-- A store is a business (ESX job + its society account) with a till: a placed OPS POS terminal (opslabs-towers
-- fixture). The rest of the kit counts when it's within Config.KitRadius of the terminal:
--   card reader → card / contactless payments (approved on the customer's phone)   cash drawer → cash payments
--   barcode scanner → scan to add            receipt printer → printed receipts      customer display → basket on show
-- Money: card sales go to the society account less the processor fee (to the OPS POS company); cash goes into the
-- till's drawer until a boss cashes up into the society. The POS software licence is billed to the society.

local CM, CP, CL = Config.Models, Config.Payments, Config.Licence
local Stores = {}            -- id -> store row (+ kit)
local ByTerminal = {}        -- terminal fixture id -> store id
local Terminals = {}         -- fixture id -> { id, x, y, z, heading, kit = { reader = fx, ... } }
local Pending = {}           -- payment request id -> { resolve, src }
local KIT_KIND = {}
for kind, model in pairs(CM) do KIT_KIND[model] = kind end

local function now() return os.time() end
local function round2(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end
local function money(v) return ('%s%s'):format(Config.Currency, string.format('%.2f', v)) end
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function towers() return GetResourceState('opslabs-towers') == 'started' and exports['opslabs-towers'] or nil end
local function phone() return GetResourceState('opslabs-phone') == 'started' and exports['opslabs-phone'] or nil end

---------------------------------------------------------------------------
-- database
---------------------------------------------------------------------------
MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_pos_stores (
        id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(64) NOT NULL, job VARCHAR(64) NOT NULL,
        terminal INT NOT NULL UNIQUE, npc_shop VARCHAR(64) NULL, tax_pct DECIMAL(5,2) NOT NULL DEFAULT 0,
        drawer DECIMAL(12,2) NOT NULL DEFAULT 0, licence_until INT NOT NULL DEFAULT 0, suspended TINYINT NOT NULL DEFAULT 0,
        created_by VARCHAR(80) NULL, created_at INT NOT NULL DEFAULT 0)]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_pos_products (
        id INT AUTO_INCREMENT PRIMARY KEY, store_id INT NOT NULL, item VARCHAR(64) NOT NULL, label VARCHAR(64) NOT NULL,
        price DECIMAL(10,2) NOT NULL DEFAULT 0, stock INT NOT NULL DEFAULT 0, barcode VARCHAR(32) NULL,
        category VARCHAR(32) NOT NULL DEFAULT 'General', INDEX (store_id), UNIQUE KEY store_item (store_id, item))]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_pos_sales (
        id INT AUTO_INCREMENT PRIMARY KEY, store_id INT NOT NULL, source VARCHAR(8) NOT NULL DEFAULT 'till',
        staff VARCHAR(80) NULL, staff_name VARCHAR(64) NULL, customer VARCHAR(80) NULL, customer_name VARCHAR(64) NULL,
        items LONGTEXT NOT NULL, subtotal DECIMAL(12,2) NOT NULL, discount DECIMAL(12,2) NOT NULL DEFAULT 0,
        tax DECIMAL(12,2) NOT NULL DEFAULT 0, total DECIMAL(12,2) NOT NULL, method VARCHAR(12) NOT NULL,
        fee DECIMAL(12,2) NOT NULL DEFAULT 0, refunded TINYINT NOT NULL DEFAULT 0, created_at INT NOT NULL,
        INDEX (store_id, created_at))]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_pos_shifts (
        id INT AUTO_INCREMENT PRIMARY KEY, store_id INT NOT NULL, identifier VARCHAR(80) NOT NULL, name VARCHAR(64) NOT NULL,
        clock_in INT NOT NULL, clock_out INT NULL, INDEX (store_id, identifier))]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_pos_loyalty (
        store_id INT NOT NULL, identifier VARCHAR(80) NOT NULL, name VARCHAR(64) NOT NULL, points INT NOT NULL DEFAULT 0,
        visits INT NOT NULL DEFAULT 0, spent DECIMAL(12,2) NOT NULL DEFAULT 0, last_at INT NOT NULL DEFAULT 0,
        PRIMARY KEY (store_id, identifier))]])
    MySQL.query.await([[INSERT IGNORE INTO items (name, label, weight) SELECT ?, ?, 0 FROM DUAL
        WHERE EXISTS (SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'items')]],
        { Config.ReceiptItem, 'Receipt' })
    for _, s in ipairs(MySQL.query.await('SELECT * FROM opslabs_pos_stores') or {}) do
        Stores[s.id] = s
        ByTerminal[s.terminal] = s.id
    end
end)

---------------------------------------------------------------------------
-- the kit in the world (opslabs-towers fixtures)
---------------------------------------------------------------------------
local function publicTerminals()
    local out = {}
    for id, t in pairs(Terminals) do
        local s = Stores[ByTerminal[id] or -1]
        out[#out + 1] = { id = id, x = t.x, y = t.y, z = t.z, heading = t.heading, kit = t.kit,
            store = s and { id = s.id, name = s.name, job = s.job, active = s.suspended == 0 } or nil }
    end
    return out
end

local lastKey = ''
local function scanKit()
    local T = towers()
    if not T then return end
    local ok, cab = pcall(function() return T:GetCabling() end)
    if not ok or not cab or not cab.fixtures then return end
    local terms, kit = {}, {}
    for id, f in pairs(cab.fixtures) do
        local kind = KIT_KIND[f.model]
        if kind == 'terminal' then terms[#terms + 1] = { id = tonumber(id), f = f }
        elseif kind then kit[#kit + 1] = { id = tonumber(id), kind = kind, f = f } end
    end
    local fresh = {}
    for _, t in ipairs(terms) do
        local e = { id = t.id, x = t.f.x, y = t.f.y, z = t.f.z, heading = t.f.heading or 0.0, kit = {} }
        for _, k in ipairs(kit) do
            if dist(t.f, k.f) <= Config.KitRadius then
                local cur = e.kit[k.kind]
                if not cur or dist(t.f, k.f) < dist(t.f, cur) then
                    e.kit[k.kind] = { id = k.id, x = k.f.x, y = k.f.y, z = k.f.z, heading = k.f.heading or 0.0 }
                end
            end
        end
        fresh[t.id] = e
    end
    Terminals = fresh
    local key = json.encode(publicTerminals())
    if key ~= lastKey then
        lastKey = key
        TriggerClientEvent('opslabs-pos:terminals', -1, publicTerminals())
    end
end

CreateThread(function()
    Wait(3000)
    while true do
        scanKit()
        Wait(15000)
    end
end)
AddEventHandler('opslabs-towers:fixtureRemoved', function() SetTimeout(500, scanKit) end)
lib.callback.register('opslabs-pos:terminals', function() return publicTerminals() end)

local function powered(id)
    if not Config.RequirePower then return true end
    local T = towers()
    local ok, s = pcall(function() return T and T:GetMainsState(id) end)
    return ok and s and s.on == true or false
end

---------------------------------------------------------------------------
-- people: staff, bosses, customers
---------------------------------------------------------------------------
local function isStaff(src, store) return store and FW.Job(src) == store.job end

local function isBoss(src, job)
    local p = FW.Player(src)
    if not p or not p.job or p.job.name ~= job then return false end
    if GetResourceState('rps_bossmenu') == 'started' then
        local ok, yes = pcall(function() return exports.rps_bossmenu:HasBossAccess(p.identifier, job) end)
        if ok and yes then return true end
    end
    local g = p.job.grade or {}
    return Config.BossGrades[tostring(g.name or ''):lower()] == true
end

local function openShift(store, identifier)
    return MySQL.single.await('SELECT * FROM opslabs_pos_shifts WHERE store_id = ? AND identifier = ? AND clock_out IS NULL ORDER BY id DESC LIMIT 1',
        { store.id, identifier })
end

local function nearTerminal(src, id, range)
    local t = Terminals[tonumber(id) or -1]
    if not t then return nil end
    local c = GetEntityCoords(GetPlayerPed(src))
    if #(c - vector3(t.x, t.y, t.z)) > (range or Config.UseDistance) + 1.0 then return nil end
    return t
end

---------------------------------------------------------------------------
-- money: society accounts and the OPS POS company
---------------------------------------------------------------------------
local function society(job)
    if GetResourceState('esx_addonaccount') ~= 'started' then return nil end
    local p = promise.new()
    TriggerEvent('esx_addonaccount:getSharedAccount', 'society_' .. job, function(acc) p:resolve(acc or false) end)
    return Citizen.Await(p) or nil
end

local function societyBalance(job) local a = society(job) return a and a.money or 0 end
local function societyAdd(job, amount, why, by)
    amount = round2(amount)
    if amount <= 0 then return true end
    local a = society(job)
    if not a then return false end
    a.addMoney(amount)
    if GetResourceState('rps_bossmenu') == 'started' then pcall(function() exports.rps_bossmenu:LogSocietyTransaction(job, 'deposit', amount, why, by or 'OPS POS') end) end
    return true
end
local function societyTake(job, amount, why, by)
    amount = round2(amount)
    if amount <= 0 then return true end
    local a = society(job)
    if not a or a.money < amount then return false end
    a.removeMoney(amount)
    if GetResourceState('rps_bossmenu') == 'started' then pcall(function() exports.rps_bossmenu:LogSocietyTransaction(job, 'withdraw', amount, why, by or 'OPS POS') end) end
    return true
end

local function companyIncome(amount, memo, store)
    local P = phone()
    if not P or amount <= 0 then return end
    pcall(function() P:CompanyMove(Config.Company, 'income', round2(amount), memo, 'pos', store and store.id or nil, store and store.name or nil, 'OPS POS') end)
end

---------------------------------------------------------------------------
-- licence
---------------------------------------------------------------------------
local function licenceState(s)
    if s.suspended == 1 then return 'suspended' end
    if s.licence_until < now() then return 'overdue' end
    return 'active'
end

local function billLicence(s)
    if not societyTake(s.job, CL.Monthly, 'OPS POS licence · ' .. s.name) then return false end
    companyIncome(CL.Monthly, 'POS software licence · ' .. s.name, s)
    s.licence_until = math.max(s.licence_until, now()) + CL.PeriodDays * 86400
    s.suspended = 0
    MySQL.update.await('UPDATE opslabs_pos_stores SET licence_until = ?, suspended = 0 WHERE id = ?', { s.licence_until, s.id })
    return true
end

CreateThread(function()
    while true do
        Wait(600000)
        for _, s in pairs(Stores) do
            if s.licence_until < now() and s.suspended == 0 then
                if not billLicence(s) and now() > s.licence_until + CL.GraceDays * 86400 then
                    s.suspended = 1
                    MySQL.update.await('UPDATE opslabs_pos_stores SET suspended = 1 WHERE id = ?', { s.id })
                    scanKit()
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- products
---------------------------------------------------------------------------
local function itemLabel(item)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, it = pcall(function() return exports.ox_inventory:Items(item) end)
        if ok and it and it.label then return it.label end
    end
    return item
end

local function products(storeId)
    return MySQL.query.await('SELECT id, item, label, price, stock, barcode, category FROM opslabs_pos_products WHERE store_id = ? ORDER BY category, label', { storeId }) or {}
end

--- what the staff member is carrying (to add as products / receive as stock)
local function carried(src)
    if GetResourceState('ox_inventory') ~= 'started' then return {} end
    local ok, items = pcall(function() return exports.ox_inventory:GetInventoryItems(src) end)
    local out, seen = {}, {}
    for _, it in pairs(ok and items or {}) do
        if it.name and it.name ~= 'money' and not seen[it.name] then
            seen[it.name] = true
            out[#out + 1] = { item = it.name, label = it.label or itemLabel(it.name), count = FW.ItemCount(src, it.name) }
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

---------------------------------------------------------------------------
-- open the till
---------------------------------------------------------------------------
local function storeView(s, src)
    local identifier = FW.Identifier(src)
    local shift = identifier and openShift(s, identifier)
    return {
        id = s.id, name = s.name, job = s.job, tax = tonumber(s.tax_pct) or 0, drawer = tonumber(s.drawer) or 0,
        licence = licenceState(s), licenceUntil = s.licence_until, npcShop = s.npc_shop,
        me = { staff = isStaff(src, s), boss = isBoss(src, s.job), clockedIn = shift ~= nil, since = shift and shift.clock_in or nil },
        products = products(s.id),
    }
end

lib.callback.register('opslabs-pos:open', function(src, terminalId)
    local t = nearTerminal(src, terminalId)
    if not t then return { error = 'Stand at the till' } end
    if not powered(t.id) then return { error = 'The terminal has no power — plug it into a live socket' } end
    local kit = { reader = t.kit.reader ~= nil, drawer = t.kit.drawer ~= nil, scanner = t.kit.scanner ~= nil,
        printer = t.kit.printer ~= nil, display = t.kit.display ~= nil }
    local s = Stores[ByTerminal[t.id] or -1]
    local base = { terminal = t.id, kit = kit, currency = Config.Currency, locale = Config.Locale,
        licence = { setup = CL.SetupFee, monthly = CL.Monthly, days = CL.PeriodDays }, cardFee = CP.CardFeePct,
        loyalty = Config.Loyalty }
    if not s then
        local job = FW.Job(src)
        base.setup = { canSetup = job ~= nil and isBoss(src, job), job = job, jobLabel = FW.JobLabel(src) }
        return base
    end
    if not isStaff(src, s) then return { error = ('This till belongs to %s'):format(s.name) } end
    base.store = storeView(s, src)
    return base
end)

lib.callback.register('opslabs-pos:setup', function(src, terminalId, name)
    local t = nearTerminal(src, terminalId)
    if not t then return { error = 'Stand at the till' } end
    if ByTerminal[t.id] then return { error = 'This till is already set up' } end
    local job = FW.Job(src)
    if not job or not isBoss(src, job) then return { error = 'Only a boss of the business can set up a till' } end
    name = tostring(name or ''):gsub('[^%w%s%-%&\'%.]', ''):sub(1, 48)
    if #name < 2 then name = FW.JobLabel(src) or job end
    local cost = CL.SetupFee + CL.Monthly
    if societyBalance(job) < cost then return { error = ('The business account needs %s (set-up %s + first licence %s)'):format(money(cost), money(CL.SetupFee), money(CL.Monthly)) } end
    societyTake(job, cost, 'OPS POS set-up · ' .. name, FW.Name(src))
    local until_ = now() + CL.PeriodDays * 86400
    local id = MySQL.insert.await('INSERT INTO opslabs_pos_stores (name, job, terminal, tax_pct, licence_until, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { name, job, t.id, CP.TaxPct or 0, until_, FW.Identifier(src), now() })
    local s = MySQL.single.await('SELECT * FROM opslabs_pos_stores WHERE id = ?', { id })
    Stores[id], ByTerminal[t.id] = s, id
    companyIncome(cost, 'POS set-up + licence · ' .. name, s)
    lastKey = ''
    scanKit()
    return { ok = true }
end)

local function storeFor(src, storeId, boss)
    local s = Stores[tonumber(storeId) or -1]
    if not s or not isStaff(src, s) then return nil, 'Not your store' end
    if boss and not isBoss(src, s.job) then return nil, 'Only a boss can do that' end
    return s
end

---------------------------------------------------------------------------
-- staff: clock in / out
---------------------------------------------------------------------------
lib.callback.register('opslabs-pos:clock', function(src, storeId)
    local s, err = storeFor(src, storeId)
    if not s then return { error = err } end
    local identifier = FW.Identifier(src)
    local shift = openShift(s, identifier)
    if shift then
        local out = math.min(now(), shift.clock_in + Config.Staff.MaxShiftHours * 3600)
        MySQL.update.await('UPDATE opslabs_pos_shifts SET clock_out = ? WHERE id = ?', { out, shift.id })
        return { ok = true, clockedIn = false, hours = round2((out - shift.clock_in) / 3600) }
    end
    -- anything left open at another store closes now
    MySQL.update.await('UPDATE opslabs_pos_shifts SET clock_out = ? WHERE identifier = ? AND clock_out IS NULL', { now(), identifier })
    MySQL.insert.await('INSERT INTO opslabs_pos_shifts (store_id, identifier, name, clock_in) VALUES (?, ?, ?, ?)', { s.id, identifier, FW.Name(src), now() })
    return { ok = true, clockedIn = true, since = now() }
end)

---------------------------------------------------------------------------
-- stock
---------------------------------------------------------------------------
lib.callback.register('opslabs-pos:carried', function(src) return carried(src) end)

lib.callback.register('opslabs-pos:product', function(src, storeId, action, d)
    d = type(d) == 'table' and d or {}
    local boss = action ~= 'receive'
    local s, err = storeFor(src, storeId, boss)
    if not s then return { error = err } end
    if action == 'add' or action == 'receive' then
        local item = tostring(d.item or '')
        local qty = math.floor(tonumber(d.qty) or 0)
        if item == '' or qty < 0 or qty > 1000 then return { error = 'Pick an item and a quantity' } end
        if qty > 0 and (FW.ItemCount(src, item) < qty or not FW.RemoveItem(src, item, qty)) then return { error = 'You are not carrying that many' } end
        local row = MySQL.single.await('SELECT id FROM opslabs_pos_products WHERE store_id = ? AND item = ?', { s.id, item })
        if row then
            MySQL.update.await('UPDATE opslabs_pos_products SET stock = stock + ? WHERE id = ?', { qty, row.id })
        elseif action == 'add' then
            local price = round2(math.max(0, math.min(CP.MaxSale, tonumber(d.price) or 0)))
            local barcode = tostring(d.barcode or ''):gsub('%D', ''):sub(1, 14)
            if barcode == '' then barcode = ('%03d%06d'):format(s.id % 1000, math.random(0, 999999)) end
            local cat = tostring(d.category or 'General'):gsub('[^%w%s&%-]', ''):sub(1, 24)
            MySQL.insert.await('INSERT INTO opslabs_pos_products (store_id, item, label, price, stock, barcode, category) VALUES (?, ?, ?, ?, ?, ?, ?)',
                { s.id, item, itemLabel(item), price, qty, barcode, cat ~= '' and cat or 'General' })
        else
            if qty > 0 then FW.AddItem(src, item, qty) end
            return { error = 'That item is not on the till yet — a boss adds it first' }
        end
        return { ok = true, products = products(s.id) }
    end
    local p = MySQL.single.await('SELECT * FROM opslabs_pos_products WHERE id = ? AND store_id = ?', { tonumber(d.id) or -1, s.id })
    if not p then return { error = 'No such product' } end
    if action == 'price' then
        MySQL.update.await('UPDATE opslabs_pos_products SET price = ?, category = ? WHERE id = ?',
            { round2(math.max(0, math.min(CP.MaxSale, tonumber(d.price) or p.price))), tostring(d.category or p.category):sub(1, 24), p.id })
    elseif action == 'remove' then
        if p.stock > 0 then FW.AddItem(src, p.item, p.stock) end
        MySQL.update.await('DELETE FROM opslabs_pos_products WHERE id = ?', { p.id })
    elseif action == 'take' then
        local qty = math.min(p.stock, math.max(0, math.floor(tonumber(d.qty) or 0)))
        if qty > 0 and FW.AddItem(src, p.item, qty) then MySQL.update.await('UPDATE opslabs_pos_products SET stock = stock - ? WHERE id = ?', { qty, p.id }) end
    end
    return { ok = true, products = products(s.id) }
end)

---------------------------------------------------------------------------
-- customers at the counter
---------------------------------------------------------------------------
local function loyalty(storeId, identifier)
    return identifier and MySQL.single.await('SELECT points, visits, spent FROM opslabs_pos_loyalty WHERE store_id = ? AND identifier = ?', { storeId, identifier }) or nil
end

lib.callback.register('opslabs-pos:customers', function(src, terminalId)
    local t = nearTerminal(src, terminalId)
    local s = t and Stores[ByTerminal[t.id] or -1]
    if not s then return {} end
    local out = {}
    local here = vector3(t.x, t.y, t.z)
    for _, pid in ipairs(GetPlayers()) do
        local p = tonumber(pid)
        if p ~= src then
            local d = #(GetEntityCoords(GetPlayerPed(p)) - here)
            if d <= Config.CustomerDistance then
                local l = loyalty(s.id, FW.Identifier(p))
                out[#out + 1] = { src = p, name = FW.Name(p), dist = math.floor(d * 10) / 10, points = l and l.points or 0, visits = l and l.visits or 0 }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end)

---------------------------------------------------------------------------
-- the customer pays: card (phone, contactless) or cash (they confirm handing it over)
---------------------------------------------------------------------------
local seq = 0

--- ask the customer; true when they approved in time
local function askCustomer(target, data)
    seq = seq + 1
    local id = seq
    local p = promise.new()
    Pending[id] = { p = p, src = target }
    data.id = id
    data.timeout = CP.CardTimeout
    TriggerClientEvent('opslabs-pos:payPrompt', target, data)
    SetTimeout((CP.CardTimeout + 2) * 1000, function()
        if Pending[id] then Pending[id] = nil p:resolve(false) end
    end)
    local ok = Citizen.Await(p)
    return ok == true
end

RegisterNetEvent('opslabs-pos:payRespond', function(id, ok)
    local src = source
    local r = Pending[tonumber(id) or -1]
    if not r or r.src ~= src then return end
    Pending[id] = nil
    r.p:resolve(ok == true)
end)

--- take the money; returns true or an error
local function collect(target, method, total, merchant, lines)
    local account = method == 'card' and CP.CardBank or CP.CashBank
    if FW.GetMoney(target, account) < total then
        return method == 'card' and 'Card declined — insufficient funds' or 'The customer does not have enough cash'
    end
    if not askCustomer(target, { method = method, merchant = merchant, total = total, lines = lines, currency = Config.Currency }) then
        return method == 'card' and 'Payment cancelled or timed out' or 'The customer did not hand over the cash'
    end
    if not FW.RemoveMoney(target, total, account, merchant) then return 'Payment failed' end
    return true
end

local function broadcastNear(coords, range, event, payload)
    for _, pid in ipairs(GetPlayers()) do
        local p = tonumber(pid)
        if #(GetEntityCoords(GetPlayerPed(p)) - coords) <= range then TriggerClientEvent(event, p, payload) end
    end
end

--- the basket on the customer display (staff's till pushes it as it changes)
RegisterNetEvent('opslabs-pos:basket', function(terminalId, lines, total, customer)
    local src = source
    local t = nearTerminal(src, terminalId)
    local s = t and Stores[ByTerminal[t.id] or -1]
    if not s or not isStaff(src, s) or not t.kit.display then return end
    local d = t.kit.display
    local clean = {}
    for i, l in ipairs(type(lines) == 'table' and lines or {}) do
        if i > 8 then break end
        clean[#clean + 1] = { label = tostring(l.label or ''):sub(1, 28), qty = math.floor(tonumber(l.qty) or 1), total = round2(l.total) }
    end
    broadcastNear(vector3(d.x, d.y, d.z), Config.DisplayDistance, 'opslabs-pos:display', {
        terminal = t.id, store = s.name, lines = clean, total = round2(total), customer = customer and tostring(customer):sub(1, 32) or nil })
end)

lib.callback.register('opslabs-pos:charge', function(src, terminalId, basket, target, method, redeem)
    local t = nearTerminal(src, terminalId)
    local s = t and Stores[ByTerminal[t.id] or -1]
    if not s or not isStaff(src, s) then return { error = 'Not your till' } end
    if licenceState(s) == 'suspended' then return { error = 'The OPS POS licence is unpaid — a boss pays it under Manage' } end
    local identifier = FW.Identifier(src)
    if Config.Staff.RequireClockIn and not openShift(s, identifier) then return { error = 'Clock in first' } end
    if method == 'card' and not t.kit.reader then return { error = 'No card reader on this till' } end
    if method ~= 'card' and method ~= 'cash' then return { error = 'Pick card or cash' } end
    target = tonumber(target)
    if not target or target == src or not GetPlayerName(target) then return { error = 'Pick the customer' } end
    if #(GetEntityCoords(GetPlayerPed(target)) - vector3(t.x, t.y, t.z)) > Config.CustomerDistance + 1.0 then return { error = 'The customer walked away from the till' } end

    -- price it up from the database (never trust the till's numbers)
    local lines, subtotal = {}, 0
    for pid, qty in pairs(type(basket) == 'table' and basket or {}) do
        qty = math.floor(tonumber(qty) or 0)
        if qty > 0 then
            local p = MySQL.single.await('SELECT * FROM opslabs_pos_products WHERE id = ? AND store_id = ?', { tonumber(pid) or -1, s.id })
            if not p then return { error = 'A product is no longer on the till' } end
            if p.stock < qty then return { error = ('Only %d × %s in stock'):format(p.stock, p.label) } end
            local lt = round2(p.price * qty)
            lines[#lines + 1] = { id = p.id, item = p.item, label = p.label, qty = qty, price = tonumber(p.price), total = lt }
            subtotal = subtotal + lt
        end
    end
    if #lines == 0 then return { error = 'The basket is empty' } end
    subtotal = round2(subtotal)
    local custId = FW.Identifier(target)
    local l = loyalty(s.id, custId)
    local discount, used = 0, 0
    if redeem and l and l.points >= Config.Loyalty.MinRedeem then
        used = l.points
        discount = math.min(subtotal, round2(used * Config.Loyalty.PointValue))
        used = math.ceil(discount / Config.Loyalty.PointValue)
    end
    local tax = round2((subtotal - discount) * (tonumber(s.tax_pct) or 0) / 100)
    local total = round2(subtotal - discount + tax)
    if total > CP.MaxSale then return { error = 'That sale is over the till limit' } end

    -- the customer must be able to carry it
    if GetResourceState('ox_inventory') == 'started' then
        for _, ln in ipairs(lines) do
            local ok, can = pcall(function() return exports.ox_inventory:CanCarryItem(target, ln.item, ln.qty) end)
            if ok and can == false then return { error = ('The customer cannot carry %s'):format(ln.label) } end
        end
    end

    local result = total > 0 and collect(target, method, total, s.name, lines) or true
    if result ~= true then return { error = result } end

    -- hand over the goods (refund if that fails)
    local given = {}
    for _, ln in ipairs(lines) do
        if not FW.AddItem(target, ln.item, ln.qty) then
            for _, g in ipairs(given) do FW.RemoveItem(target, g.item, g.qty) end
            FW.AddMoney(target, total, method == 'card' and CP.CardBank or CP.CashBank, 'Refund · ' .. s.name)
            return { error = 'Could not hand over ' .. ln.label .. ' — the customer was refunded' }
        end
        given[#given + 1] = ln
        MySQL.update.await('UPDATE opslabs_pos_products SET stock = stock - ? WHERE id = ?', { ln.qty, ln.id })
    end

    -- the money: card → society less the processor fee; cash → the drawer
    local fee = 0
    if method == 'card' then
        fee = round2(total * CP.CardFeePct / 100)
        societyAdd(s.job, total - fee, 'Card sales · ' .. s.name, FW.Name(src))
        companyIncome(fee, 'Card processing · ' .. s.name, s)
    else
        s.drawer = round2((tonumber(s.drawer) or 0) + total)
        MySQL.update.await('UPDATE opslabs_pos_stores SET drawer = ? WHERE id = ?', { s.drawer, s.id })
        if t.kit.drawer then broadcastNear(vector3(t.x, t.y, t.z), 40.0, 'opslabs-pos:drawer', t.kit.drawer.id) end
    end

    -- loyalty
    local earned = math.floor((total) * Config.Loyalty.PointsPer)
    MySQL.query.await([[INSERT INTO opslabs_pos_loyalty (store_id, identifier, name, points, visits, spent, last_at) VALUES (?, ?, ?, ?, 1, ?, ?)
        ON DUPLICATE KEY UPDATE name = VALUES(name), points = GREATEST(0, points + ?), visits = visits + 1, spent = spent + VALUES(spent), last_at = VALUES(last_at)]],
        { s.id, custId, FW.Name(target), earned, total, now(), earned - used })

    local saleId = MySQL.insert.await([[INSERT INTO opslabs_pos_sales (store_id, source, staff, staff_name, customer, customer_name, items, subtotal, discount, tax, total, method, fee, created_at)
        VALUES (?, 'till', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        { s.id, identifier, FW.Name(src), custId, FW.Name(target), json.encode(lines), subtotal, discount, tax, total, method, fee, now() })

    -- receipt: printed when there's a printer, otherwise a notification
    local receipt = { store = s.name, number = ('%d-%06d'):format(s.id, saleId), at = os.date('%Y-%m-%d %H:%M'), method = method,
        lines = lines, subtotal = subtotal, discount = discount, tax = tax, total = total, points = earned }
    if t.kit.printer then
        local desc = {}
        for _, ln in ipairs(lines) do desc[#desc + 1] = ('%d × %s  %s'):format(ln.qty, ln.label, money(ln.total)) end
        desc[#desc + 1] = ('Total %s · %s'):format(money(total), method == 'card' and 'Card' or 'Cash')
        local meta = { label = 'Receipt · ' .. s.name, description = table.concat(desc, '\n'), receipt = receipt }
        if GetResourceState('ox_inventory') == 'started' then
            pcall(function() exports.ox_inventory:AddItem(target, Config.ReceiptItem, 1, meta) end)
        else
            FW.AddItem(target, Config.ReceiptItem, 1)
        end
    end
    TriggerClientEvent('opslabs-pos:receipt', target, receipt)
    if t.kit.display then
        local d = t.kit.display
        broadcastNear(vector3(d.x, d.y, d.z), Config.DisplayDistance, 'opslabs-pos:display', { terminal = t.id, store = s.name, paid = total, lines = {} })
    end
    return { ok = true, sale = saleId, total = total, fee = fee, earned = earned, receipt = receipt, products = products(s.id) }
end)

---------------------------------------------------------------------------
-- manage: reports, refunds, cash up, settings, licence
---------------------------------------------------------------------------
lib.callback.register('opslabs-pos:report', function(src, storeId)
    local s, err = storeFor(src, storeId, true)
    if not s then return { error = err } end
    local day, week = now() - 86400, now() - 7 * 86400
    local function sum(since)
        return MySQL.single.await([[SELECT COUNT(*) n, COALESCE(SUM(total),0) total, COALESCE(SUM(fee),0) fees,
            COALESCE(SUM(CASE WHEN method = 'card' THEN total ELSE 0 END),0) card, COALESCE(SUM(CASE WHEN method = 'cash' THEN total ELSE 0 END),0) cash,
            COALESCE(SUM(CASE WHEN source = 'npc' THEN total ELSE 0 END),0) npc
            FROM opslabs_pos_sales WHERE store_id = ? AND refunded = 0 AND created_at >= ?]], { s.id, since })
    end
    local top = {}
    for _, r in ipairs(MySQL.query.await('SELECT items FROM opslabs_pos_sales WHERE store_id = ? AND refunded = 0 AND created_at >= ?', { s.id, week }) or {}) do
        for _, ln in ipairs(json.decode(r.items) or {}) do
            local k = ln.label or ln.item or '?'
            top[k] = top[k] or { label = k, qty = 0, total = 0 }
            top[k].qty = top[k].qty + (ln.qty or 0)
            top[k].total = round2(top[k].total + (ln.total or 0))
        end
    end
    local topList = {}
    for _, v in pairs(top) do topList[#topList + 1] = v end
    table.sort(topList, function(a, b) return a.total > b.total end)
    while #topList > 8 do table.remove(topList) end
    local hours = MySQL.query.await([[SELECT name, identifier, SUM(COALESCE(clock_out, UNIX_TIMESTAMP()) - clock_in) secs,
        MAX(clock_out IS NULL) onShift FROM opslabs_pos_shifts WHERE store_id = ? AND clock_in >= ? GROUP BY identifier, name ORDER BY secs DESC]], { s.id, week }) or {}
    for _, h in ipairs(hours) do h.hours = round2((tonumber(h.secs) or 0) / 3600) h.secs = nil h.onShift = tonumber(h.onShift) == 1 end
    return {
        today = sum(day), week = sum(week), top = topList, hours = hours,
        sales = MySQL.query.await('SELECT id, source, staff_name, customer_name, total, method, refunded, created_at FROM opslabs_pos_sales WHERE store_id = ? ORDER BY id DESC LIMIT 25', { s.id }) or {},
        loyalty = MySQL.query.await('SELECT name, points, visits, spent FROM opslabs_pos_loyalty WHERE store_id = ? ORDER BY spent DESC LIMIT 10', { s.id }) or {},
        low = MySQL.query.await('SELECT label, stock FROM opslabs_pos_products WHERE store_id = ? AND stock <= 3 ORDER BY stock', { s.id }) or {},
        drawer = tonumber(s.drawer) or 0, society = societyBalance(s.job), licence = licenceState(s), licenceUntil = s.licence_until,
        tax = tonumber(s.tax_pct) or 0, name = s.name, npcShop = s.npc_shop,
    }
end)

lib.callback.register('opslabs-pos:refund', function(src, storeId, saleId)
    local s, err = storeFor(src, storeId, true)
    if not s then return { error = err } end
    local sale = MySQL.single.await('SELECT * FROM opslabs_pos_sales WHERE id = ? AND store_id = ?', { tonumber(saleId) or -1, s.id })
    if not sale or sale.refunded == 1 then return { error = 'No such sale, or already refunded' } end
    local cust = FW.SourceOf(sale.customer)
    if not cust then return { error = 'The customer needs to be in town for a refund' } end
    local total = tonumber(sale.total)
    if sale.method == 'card' then
        if not societyTake(s.job, total - tonumber(sale.fee), 'Refund · sale #' .. sale.id, FW.Name(src)) then return { error = 'Not enough in the business account' } end
        FW.AddMoney(cust, total, CP.CardBank, 'Refund · ' .. s.name)
    else
        if (tonumber(s.drawer) or 0) < total then return { error = 'Not enough cash in the drawer' } end
        s.drawer = round2(s.drawer - total)
        MySQL.update.await('UPDATE opslabs_pos_stores SET drawer = ? WHERE id = ?', { s.drawer, s.id })
        FW.AddMoney(cust, total, CP.CashBank, 'Refund · ' .. s.name)
    end
    MySQL.update.await('UPDATE opslabs_pos_sales SET refunded = 1 WHERE id = ?', { sale.id })
    TriggerClientEvent('ox_lib:notify', cust, { type = 'inform', title = s.name, description = ('Refunded %s'):format(money(total)) })
    return { ok = true }
end)

lib.callback.register('opslabs-pos:cashup', function(src, storeId)
    local s, err = storeFor(src, storeId, true)
    if not s then return { error = err } end
    local amount = tonumber(s.drawer) or 0
    if amount <= 0 then return { error = 'The drawer is empty' } end
    if not societyAdd(s.job, amount, 'Cash up · ' .. s.name, FW.Name(src)) then return { error = 'Could not reach the business account' } end
    s.drawer = 0
    MySQL.update.await('UPDATE opslabs_pos_stores SET drawer = 0 WHERE id = ?', { s.id })
    return { ok = true, amount = amount }
end)

lib.callback.register('opslabs-pos:settings', function(src, storeId, d)
    local s, err = storeFor(src, storeId, true)
    if not s then return { error = err } end
    d = type(d) == 'table' and d or {}
    local name = tostring(d.name or s.name):gsub('[^%w%s%-%&\'%.]', ''):sub(1, 48)
    s.name = #name >= 2 and name or s.name
    s.tax_pct = math.max(0, math.min(30, round2(tonumber(d.tax) or s.tax_pct)))
    MySQL.update.await('UPDATE opslabs_pos_stores SET name = ?, tax_pct = ? WHERE id = ?', { s.name, s.tax_pct, s.id })
    lastKey = ''
    scanKit()
    return { ok = true }
end)

lib.callback.register('opslabs-pos:payLicence', function(src, storeId)
    local s, err = storeFor(src, storeId, true)
    if not s then return { error = err } end
    if not billLicence(s) then return { error = ('The business account needs %s'):format(money(CL.Monthly)) } end
    lastKey = ''
    scanKit()
    return { ok = true, licenceUntil = s.licence_until }
end)

---------------------------------------------------------------------------
-- NPC shops (rps_shops): the store at that shop gets its takings, and card payments go through OPS POS
---------------------------------------------------------------------------
local function storeForShop(shopId, coords)
    if not Config.NpcShops.Enabled then return nil end
    for _, s in pairs(Stores) do
        if s.npc_shop == shopId then return s end
    end
    if not coords then return nil end
    -- not linked yet: the nearest till within LinkDistance takes the shop
    local best, bd
    for _, s in pairs(Stores) do
        local t = Terminals[s.terminal]
        if t and not s.npc_shop then
            local d = dist(t, coords)
            if d <= Config.NpcShops.LinkDistance and (not bd or d < bd) then best, bd = s, d end
        end
    end
    if best then
        best.npc_shop = shopId
        MySQL.update.await('UPDATE opslabs_pos_stores SET npc_shop = ? WHERE id = ?', { shopId, best.id })
    end
    return best
end

--- rps_shops: the customer has no cash; offer to pay by card through the store's OPS POS. true when paid.
exports('NpcCardPay', function(src, shopId, label, coords, total, items)
    local s = storeForShop(shopId, coords)
    if not s or licenceState(s) == 'suspended' then return false end
    local t = Terminals[s.terminal]
    if not t or not t.kit.reader then return false end
    total = round2(total)
    local lines = {}
    for _, it in ipairs(items or {}) do lines[#lines + 1] = { label = it.label, qty = it.quantity, total = round2((it.unitPrice or 0) * (it.quantity or 1)) } end
    return collect(src, 'card', total, s.name, lines) == true
end)

--- rps_shops: a card payment from NpcCardPay has to be given back (the purchase failed after paying)
exports('NpcCardRefund', function(src, total)
    FW.AddMoney(src, round2(total), CP.CardBank, 'Refund')
end)

--- rps_shops: a purchase went through at this shop
exports('NpcSale', function(src, shopId, label, coords, cart, method)
    local s = storeForShop(shopId, coords)
    if not s or licenceState(s) == 'suspended' or not cart then return end
    local total = round2(cart.total)
    local lines = {}
    for _, it in ipairs(cart.items or {}) do
        lines[#lines + 1] = { item = it.item, label = it.label, qty = it.quantity, price = it.unitPrice, total = round2((it.unitPrice or 0) * (it.quantity or 1)) }
    end
    local fee = 0
    if method == 'card' then
        fee = round2(total * CP.CardFeePct / 100)
        societyAdd(s.job, total - fee, 'Card sales · ' .. s.name, Config.NpcShops.StaffName)
        companyIncome(fee, 'Card processing · ' .. s.name, s)
    else
        s.drawer = round2((tonumber(s.drawer) or 0) + total)
        MySQL.update.await('UPDATE opslabs_pos_stores SET drawer = ? WHERE id = ?', { s.drawer, s.id })
    end
    local custId = FW.Identifier(src)
    local earned = math.floor(total * Config.Loyalty.PointsPer)
    MySQL.query.await([[INSERT INTO opslabs_pos_loyalty (store_id, identifier, name, points, visits, spent, last_at) VALUES (?, ?, ?, ?, 1, ?, ?)
        ON DUPLICATE KEY UPDATE name = VALUES(name), points = points + VALUES(points), visits = visits + 1, spent = spent + VALUES(spent), last_at = VALUES(last_at)]],
        { s.id, custId, FW.Name(src), earned, total, now() })
    MySQL.insert.await([[INSERT INTO opslabs_pos_sales (store_id, source, staff_name, customer, customer_name, items, subtotal, tax, total, method, fee, created_at)
        VALUES (?, 'npc', ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)]],
        { s.id, Config.NpcShops.StaffName, custId, FW.Name(src), json.encode(lines), total, total, method == 'card' and 'card' or 'cash', fee, now() })
end)

--- admin: link / unlink an rps_shops shop to a store by hand (/posshop <storeId> <shopId|none>)
lib.addCommand('posshop', { help = 'OPS POS: link an rps_shops shop to a store', restricted = 'group.admin',
    params = { { name = 'store', type = 'number' }, { name = 'shop', type = 'string' } } }, function(src, args)
    local s = Stores[args.store]
    if not s then return TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = 'No such store' }) end
    s.npc_shop = args.shop ~= 'none' and args.shop or nil
    MySQL.update.await('UPDATE opslabs_pos_stores SET npc_shop = ? WHERE id = ?', { s.npc_shop, s.id })
    TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = ('%s ← %s'):format(s.name, s.npc_shop or 'no shop') })
end)

AddEventHandler('playerDropped', function()
    local src = source
    for id, r in pairs(Pending) do
        if r.src == src then Pending[id] = nil r.p:resolve(false) end
    end
end)
