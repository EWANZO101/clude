-- Mobile carrier: plans, eSIM lines and usage limits.
--
-- One line per character (identifier). A line is bought on the store website
-- (through the REST API below), then the eSIM is installed on the phone
-- (Settings > Mobile Service). While a line is active the phone can text,
-- call and use online apps up to the plan's allowance; emergency numbers
-- always work. Periods renew automatically from the bank account.
--
-- line.status: pending (bought, eSIM not installed yet) | active | suspended | expired | cancelled

Carrier = {}

local RES = GetCurrentResourceName()
local UNLIMITED = -1
local lines = {}        -- identifier -> line row (cache)
local plans = {}        -- id -> plan row
local planByCode = {}
local warned = {}       -- "lineId:kind:periodStart" -> highest % warned
local pushAt = {}       -- src -> last status push (throttle)

---------------------------------------------------------------------------
-- settings (config defaults, overridable from the store admin)
---------------------------------------------------------------------------

local function settings()
    local s = {}
    for k, v in pairs(Config.Carrier) do s[k] = v end
    local saved = KV and KV.carrier and json.decode(KV.carrier)
    if type(saved) == 'table' then
        for k, v in pairs(saved) do if k ~= 'DataCost' then s[k] = v end end
    end
    return s
end
Carrier.Settings = settings

local function enabled() return settings().Enabled ~= false end

---------------------------------------------------------------------------
-- database
---------------------------------------------------------------------------

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_plans` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `code` VARCHAR(40) NOT NULL,
        `kind` VARCHAR(10) NOT NULL DEFAULT 'plan',
        `name` VARCHAR(60) NOT NULL,
        `description` VARCHAR(255) NOT NULL DEFAULT '',
        `price` INT NOT NULL DEFAULT 0,
        `period_days` INT NOT NULL DEFAULT 7,
        `sms` INT NOT NULL DEFAULT -1,
        `minutes` INT NOT NULL DEFAULT -1,
        `data_mb` INT NOT NULL DEFAULT -1,
        `color` VARCHAR(20) NOT NULL DEFAULT '#0a84ff',
        `featured` TINYINT(1) NOT NULL DEFAULT 0,
        `public` TINYINT(1) NOT NULL DEFAULT 1,
        `active` TINYINT(1) NOT NULL DEFAULT 1,
        `sort` INT NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        UNIQUE KEY `code` (`code`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_lines` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `identifier` VARCHAR(60) NOT NULL,
        `plan_id` INT DEFAULT NULL,
        `status` VARCHAR(12) NOT NULL DEFAULT 'pending',
        `iccid` VARCHAR(24) NOT NULL,
        `activation_code` VARCHAR(40) NOT NULL,
        `installed` TINYINT(1) NOT NULL DEFAULT 0,
        `period_start` INT DEFAULT NULL,
        `period_end` INT DEFAULT NULL,
        `auto_renew` TINYINT(1) NOT NULL DEFAULT 1,
        `sms_used` INT NOT NULL DEFAULT 0,
        `seconds_used` INT NOT NULL DEFAULT 0,
        `data_kb` INT NOT NULL DEFAULT 0,
        `extra_sms` INT NOT NULL DEFAULT 0,
        `extra_minutes` INT NOT NULL DEFAULT 0,
        `extra_data_mb` INT NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        UNIQUE KEY `identifier` (`identifier`),
        UNIQUE KEY `activation_code` (`activation_code`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_usage` (
        `line_id` INT NOT NULL,
        `day` DATE NOT NULL,
        `sms` INT NOT NULL DEFAULT 0,
        `seconds` INT NOT NULL DEFAULT 0,
        `data_kb` INT NOT NULL DEFAULT 0,
        PRIMARY KEY (`line_id`, `day`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_credit` (
        `identifier` VARCHAR(60) NOT NULL,
        `balance` INT NOT NULL DEFAULT 0,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_credit_log` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `identifier` VARCHAR(60) NOT NULL,
        `amount` INT NOT NULL,
        `balance_after` INT NOT NULL,
        `reason` VARCHAR(160) NOT NULL DEFAULT '',
        `actor` VARCHAR(60) NOT NULL DEFAULT 'system',
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `identifier` (`identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_carrier_events` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `line_id` INT NOT NULL,
        `type` VARCHAR(24) NOT NULL,
        `detail` VARCHAR(255) NOT NULL DEFAULT '',
        `amount` INT NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `line_id` (`line_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

local DEFAULT_PLANS = {
    { code = 'starter', kind = 'plan', name = 'Starter', description = 'Free welcome plan for new phones.', price = 0, period_days = 7, sms = 50, minutes = 30, data_mb = 500, color = '#8e8e93', public = 0, sort = 0 },
    { code = 'essential', kind = 'plan', name = 'Essential', description = 'Everyday texting, calls and apps.', price = 500, period_days = 7, sms = 500, minutes = 300, data_mb = 5120, color = '#0a84ff', sort = 1 },
    { code = 'plus', kind = 'plan', name = 'Plus', description = 'Unlimited texts and calls with plenty of data.', price = 900, period_days = 7, sms = -1, minutes = -1, data_mb = 20480, color = '#5e5ce6', featured = 1, sort = 2 },
    { code = 'unlimited', kind = 'plan', name = 'Unlimited', description = 'Everything unlimited. No limits, ever.', price = 1500, period_days = 7, sms = -1, minutes = -1, data_mb = -1, color = '#ff375f', sort = 3 },
    { code = 'data-5gb', kind = 'addon', name = '5 GB Data Boost', description = 'Extra data until your plan renews.', price = 200, period_days = 0, sms = 0, minutes = 0, data_mb = 5120, color = '#30d158', sort = 10 },
    { code = 'texts-500', kind = 'addon', name = '500 Texts', description = 'Extra texts until your plan renews.', price = 100, period_days = 0, sms = 500, minutes = 0, data_mb = 0, color = '#30d158', sort = 11 },
    { code = 'minutes-300', kind = 'addon', name = '300 Minutes', description = 'Extra call minutes until your plan renews.', price = 150, period_days = 0, sms = 0, minutes = 300, data_mb = 0, color = '#30d158', sort = 12 },
}

local function loadPlans()
    plans, planByCode = {}, {}
    for _, p in ipairs(MySQL.query.await('SELECT * FROM opslabs_phone_carrier_plans ORDER BY sort, id')) do
        p.featured, p.public, p.active = IsTrue(p.featured), IsTrue(p.public), IsTrue(p.active)
        plans[p.id] = p
        planByCode[p.code] = p
    end
end

local ready = false
CreateThread(function()
    while not DatabaseReady do Wait(100) end
    for _, q in ipairs(SCHEMA) do MySQL.query.await(q) end
    if MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_carrier_plans') == 0 then
        for _, p in ipairs(DEFAULT_PLANS) do
            MySQL.insert.await([[INSERT INTO opslabs_phone_carrier_plans (code, kind, name, description, price, period_days, sms, minutes, data_mb, color, featured, public, sort)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
                { p.code, p.kind, p.name, p.description, p.price, p.period_days, p.sms, p.minutes, p.data_mb, p.color, p.featured or 0, p.public == 0 and 0 or 1, p.sort })
        end
    end
    loadPlans()
    ready = true
end)

---------------------------------------------------------------------------
-- lines
---------------------------------------------------------------------------

local function normalizeLine(l)
    if not l then return nil end
    l.installed, l.auto_renew = IsTrue(l.installed), IsTrue(l.auto_renew)
    return l
end

local function getLine(identifier)
    if lines[identifier] == nil then
        lines[identifier] = normalizeLine(MySQL.single.await('SELECT * FROM opslabs_phone_carrier_lines WHERE identifier = ?', { identifier })) or false
    end
    return lines[identifier] or nil
end
Carrier.GetLine = getLine

local function forget(identifier) lines[identifier] = nil end

-- account credit: spent before the bank on plans, extras and renewals
local credits = {}  -- identifier -> balance (cache)
local function getCredit(identifier)
    if credits[identifier] == nil then
        credits[identifier] = tonumber(MySQL.scalar.await('SELECT balance FROM opslabs_phone_carrier_credit WHERE identifier = ?', { identifier })) or 0
    end
    return credits[identifier]
end
Carrier.GetCredit = getCredit

local function event(line, type, detail, amount)
    MySQL.insert('INSERT INTO opslabs_phone_carrier_events (line_id, type, detail, amount) VALUES (?, ?, ?, ?)', { line.id, type, detail or '', amount or 0 })
end

local function newCodes()
    -- ICCID-like number and an eSIM activation code (shown as a QR on the store)
    local iccid = '8944' .. tostring(math.random(100000000, 999999999)) .. tostring(math.random(100000, 999999))
    local code
    repeat
        local raw = exports[RES]:RandomToken(12):upper():gsub('[^%w]', ''):sub(1, 16)
        code = raw:sub(1, 4) .. '-' .. raw:sub(5, 8) .. '-' .. raw:sub(9, 12) .. '-' .. raw:sub(13, 16)
    until #code == 19 and not MySQL.scalar.await('SELECT 1 FROM opslabs_phone_carrier_lines WHERE activation_code = ?', { code })
    return iccid, code
end

local function limitOf(plan, line, kind)
    if not plan then return 0 end
    local base, extra
    if kind == 'sms' then base, extra = plan.sms, line.extra_sms
    elseif kind == 'call' then base, extra = plan.minutes, line.extra_minutes
    else base, extra = plan.data_mb, line.extra_data_mb end
    if base == UNLIMITED then return UNLIMITED end
    return base + (extra or 0)
end

local function usedOf(line, kind)
    if kind == 'sms' then return line.sms_used end
    if kind == 'call' then return math.ceil(line.seconds_used / 60) end
    return math.floor(line.data_kb / 1024)
end

local function inService(line)
    return line and line.status == 'active' and line.installed and (line.period_end or 0) > os.time()
end

--- What the phone UI shows (also returned by the API)
function Carrier.View(identifier)
    local s = settings()
    local line = getLine(identifier)
    local view = { enabled = s.Enabled ~= false, name = s.Name, storeUrl = s.StoreUrl, number = s.Number, credit = getCredit(identifier) }
    if not line then return view end
    local plan = plans[line.plan_id]
    view.line = {
        status = line.status, installed = line.installed, service = inService(line),
        plan = plan and { code = plan.code, name = plan.name, color = plan.color, price = plan.price, period_days = plan.period_days } or nil,
        period_start = line.period_start, period_end = line.period_end, auto_renew = line.auto_renew,
        iccid = line.iccid, activation_code = (not line.installed) and line.activation_code or nil,
        usage = {
            sms = { used = line.sms_used, limit = limitOf(plan, line, 'sms') },
            minutes = { used = math.ceil(line.seconds_used / 60), limit = limitOf(plan, line, 'call') },
            data_mb = { used = math.floor(line.data_kb / 1024 * 10) / 10, limit = limitOf(plan, line, 'data') },
        },
    }
    return view
end

local function pushStatus(identifier, force)
    local src = GetSourceByIdentifier(identifier)
    if not src then return end
    local now = GetGameTimer()
    if not force and pushAt[src] and now - pushAt[src] < 3000 then return end
    pushAt[src] = now
    Push(src, 'carrier', Carrier.View(identifier))
end
Carrier.PushStatus = pushStatus

AddEventHandler('playerDropped', function() pushAt[source] = nil end)

--- text from the carrier to a player's phone
local function carrierText(identifier, message)
    local number = MySQL.scalar.await('SELECT phone_number FROM opslabs_phone_users WHERE identifier = ?', { identifier })
    if number then SendMessage(settings().Number, number, message, nil, settings().Name) end
end
Carrier.Text = carrierText

---------------------------------------------------------------------------
-- money
---------------------------------------------------------------------------

local function balance(identifier)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    if xPlayer then
        local a, c = xPlayer.getAccount(Config.Bank.Account), xPlayer.getAccount('money')
        return a and a.money or 0, c and c.money or 0
    end
    local raw = MySQL.scalar.await('SELECT accounts FROM users WHERE identifier = ?', { identifier })
    local acc = raw and json.decode(raw) or {}
    return tonumber(acc[Config.Bank.Account]) or 0, tonumber(acc.money) or 0
end
Carrier.Balance = balance

--- takes money from the character's bank (online or offline). Returns ok, err
--- adds (or removes, with a negative amount) credit. Never goes below 0. Returns the new balance
function Carrier.AdjustCredit(identifier, amount, reason, actor, opts)
    amount = math.floor(tonumber(amount) or 0)
    local before = getCredit(identifier)
    local after = math.max(0, before + amount)
    amount = after - before
    if amount == 0 then return after end
    MySQL.query.await('INSERT INTO opslabs_phone_carrier_credit (identifier, balance) VALUES (?, ?) ON DUPLICATE KEY UPDATE balance = VALUES(balance)', { identifier, after })
    MySQL.insert.await('INSERT INTO opslabs_phone_carrier_credit_log (identifier, amount, balance_after, reason, actor) VALUES (?, ?, ?, ?, ?)',
        { identifier, amount, after, Clean(reason or '', 160), Clean(actor or 'system', 60) })
    credits[identifier] = after
    if amount > 0 and not (opts and opts.quiet) then
        carrierText(identifier, ('You received $%d %s credit%s. It is used first for plans and extras. Balance: $%d')
            :format(amount, settings().Name, (reason and reason ~= '') and (' (' .. Clean(reason, 80) .. ')') or '', after))
    end
    pushStatus(identifier, true)
    return after
end

--- takes money from the bank only (online or offline). Returns ok, err
local function takeBank(identifier, amount, label)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    if xPlayer then
        local a = xPlayer.getAccount(Config.Bank.Account)
        if not a or a.money < amount then return false, 'insufficient_funds' end
        xPlayer.removeAccountMoney(Config.Bank.Account, amount, label)
    else
        local raw = MySQL.scalar.await('SELECT accounts FROM users WHERE identifier = ?', { identifier })
        if not raw then return false, 'no_account' end
        local acc = json.decode(raw) or {}
        local have = tonumber(acc[Config.Bank.Account]) or 0
        if have < amount then return false, 'insufficient_funds' end
        acc[Config.Bank.Account] = have - amount
        MySQL.update.await('UPDATE users SET accounts = ? WHERE identifier = ?', { json.encode(acc), identifier })
    end
    MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { identifier, label, -amount })
    local society = settings().Society
    if society and society ~= '' then
        TriggerEvent('esx_addonaccount:getSharedAccount', society, function(account) if account then account.addMoney(amount) end end)
    end
    return true
end

--- pays with credit first, the rest from the bank. Returns ok, err, { credit, bank }
local function charge(identifier, amount, label)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true, nil, { credit = 0, bank = 0 } end
    local fromCredit = math.min(getCredit(identifier), amount)
    local fromBank = amount - fromCredit
    if fromBank > 0 then
        local ok, err = takeBank(identifier, fromBank, label)
        if not ok then return false, err end
    end
    if fromCredit > 0 then Carrier.AdjustCredit(identifier, -fromCredit, label, 'payment', { quiet = true }) end
    return true, nil, { credit = fromCredit, bank = fromBank }
end

---------------------------------------------------------------------------
-- usage
---------------------------------------------------------------------------

local KIND_LABEL = { sms = 'texts', call = 'call minutes', data = 'data' }
local paidWith -- { credit, bank } of the last charge (shown in the line's history)

local function warnUsage(line, plan, kind)
    local limit = limitOf(plan, line, kind)
    if limit == UNLIMITED or limit <= 0 then return end
    local pct = usedOf(line, kind) / limit * 100
    local key = ('%s:%s:%s'):format(line.id, kind, line.period_start or 0)
    local level = pct >= 100 and 100 or pct >= 80 and 80 or 0
    if level == 0 or (warned[key] or 0) >= level then return end
    warned[key] = level
    if level == 100 then
        carrierText(line.identifier, ("You've used all of your %s. Add more or upgrade at %s"):format(KIND_LABEL[kind], settings().StoreUrl))
    else
        carrierText(line.identifier, ("You've used 80%% of your %s for this period."):format(KIND_LABEL[kind]))
    end
end

--- counts usage: kind = 'sms' (amount texts) | 'call' (seconds) | 'data' (KB)
function Carrier.Record(identifier, kind, amount)
    if not enabled() then return end
    local line = getLine(identifier)
    amount = math.floor(tonumber(amount) or 0)
    if not inService(line) or amount <= 0 then return end
    local col = kind == 'sms' and 'sms_used' or kind == 'call' and 'seconds_used' or 'data_kb'
    local dayCol = kind == 'sms' and 'sms' or kind == 'call' and 'seconds' or 'data_kb'
    line[col] = line[col] + amount
    MySQL.update(('UPDATE opslabs_phone_carrier_lines SET %s = %s + ? WHERE id = ?'):format(col, col), { amount, line.id })
    MySQL.insert(('INSERT INTO opslabs_phone_carrier_usage (line_id, day, %s) VALUES (?, CURDATE(), ?) ON DUPLICATE KEY UPDATE %s = %s + VALUES(%s)')
        :format(dayCol, dayCol, dayCol, dayCol), { line.id, amount })
    warnUsage(line, plans[line.plan_id], kind)
    pushStatus(identifier)
end

--- seconds of calling left (nil = unlimited)
function Carrier.CallSecondsLeft(identifier)
    if not enabled() then return nil end
    local line = getLine(identifier)
    if not inService(line) then return 0 end
    local limit = limitOf(plans[line.plan_id], line, 'call')
    if limit == UNLIMITED then return nil end
    return math.max(0, limit * 60 - line.seconds_used)
end

local function isEmergency(number)
    for _, service in ipairs(Config.Services) do
        if service.number == number then return true end
    end
    return number == settings().Number
end

--- can this phone do it right now? returns ok, reason
--- signal from opslabs-towers (nil when that resource isn't running = full coverage)
function Carrier.Network(src)
    if not src or GetResourceState('opslabs-towers') ~= 'started' then return nil end
    local ok, cov = pcall(function() return exports['opslabs-towers']:GetCoverage(src) end)
    if not ok or type(cov) ~= 'table' or cov.enforce == false then return nil end
    return cov
end

local function isService(number)
    for _, service in ipairs(Config.Services) do
        if service.number == number then return true end
    end
    return false
end

function Carrier.Check(phone, kind, data, src)
    local target = data and NormalizeNumber(data.number or '') or ''
    -- 911 & co always go through, even with no signal and no plan
    if kind == 'call' and isService(target) then return true end
    if phone.settings and phone.settings.airplane then return false, 'airplane' end
    local cov = Carrier.Network(src)
    if cov then
        if kind == 'data' then
            if cov.wifi then return true end            -- on Wi-Fi: apps work, no plan or signal needed
            if (cov.cell or 0) <= 0 then return false, 'no_internet' end
        elseif (cov.cell or 0) <= 0 then
            return false, 'no_signal'
        end
    end
    -- texts to emergency numbers and the carrier are free (but still need signal)
    if kind ~= 'data' and isEmergency(target) then return true end
    if not enabled() then return true end
    local line = Carrier.EnsureStarter(phone.identifier)
    if not line then return false, 'no_plan' end
    if line.status == 'pending' or not line.installed then return false, 'not_installed' end
    if line.status == 'suspended' then return false, 'suspended' end
    if not inService(line) then return false, line.status == 'cancelled' and 'cancelled' or 'expired' end
    local limit = limitOf(plans[line.plan_id], line, kind)
    if limit ~= UNLIMITED and usedOf(line, kind) >= limit then return false, 'limit' end
    return true
end

--- first use: hand out the free starter plan once. Returns the line (or nil)
function Carrier.EnsureStarter(identifier)
    local line = getLine(identifier)
    if line or not enabled() or not ready then return line end
    local starter = settings().StarterPlan
    local plan = starter and planByCode[starter]
    if not plan or plan.kind ~= 'plan' then return nil end
    Carrier.Subscribe(identifier, plan, { charge = false, install = true, auto_renew = false, quiet = true })
    carrierText(identifier, ('Welcome to %s! You have the free %s plan for %d days. See all plans at %s')
        :format(settings().Name, plan.name, plan.period_days, settings().StoreUrl))
    return getLine(identifier)
end

--- does the phone have signal (to receive calls)?
function Carrier.HasService(identifier)
    if not enabled() then return true end
    return inService(getLine(identifier))
end

-- which phone actions need the plan: Register() in main.lua checks these
CarrierGates = { sendMessage = 'sms', startCall = 'call' }
for name in pairs(Config.Carrier.DataCost) do
    if name ~= 'radio' and name ~= 'serviceRequest' then CarrierGates[name] = 'data' end
end
CarrierGates.carrierRadioMinute = 'data' -- the music apps report each minute of internet radio

--- called by Register() after a gated action succeeded
function Carrier.AfterAction(phone, name, kind, data, result, src)
    if not result or (type(result) == 'table' and result.error) then return end
    -- Wi-Fi doesn't use the plan's data
    if kind == 'data' then
        local cov = Carrier.Network(src)
        if cov and cov.wifi then return end
    end
    if kind == 'sms' then
        if not isEmergency(NormalizeNumber(data.number or '')) then Carrier.Record(phone.identifier, 'sms', 1) end
    elseif kind == 'data' then
        local cost = name == 'carrierRadioMinute' and Config.Carrier.DataCost.radio or Config.Carrier.DataCost[name]
        Carrier.Record(phone.identifier, 'data', cost or 0)
    end
end

---------------------------------------------------------------------------
-- subscribe / renew / manage
---------------------------------------------------------------------------

--- buy (or switch to) a plan. opts: charge, install, auto_renew, quiet
function Carrier.Subscribe(identifier, plan, opts)
    opts = opts or {}
    if not plan or plan.kind ~= 'plan' then return nil, 'invalid_plan' end
    if opts.charge ~= false then
        local ok, err; ok, err, paidWith = charge(identifier, plan.price, ('%s: %s plan'):format(settings().Name, plan.name))
        if not ok then return nil, err end
    end
    local line = getLine(identifier)
    local now = os.time()
    local installed = (line and line.installed) or opts.install == true
    local status = installed and 'active' or 'pending'
    local periodStart = installed and now or nil
    local periodEnd = installed and (now + plan.period_days * 86400) or nil
    local autoRenew = opts.auto_renew ~= false and plan.price > 0
    if line then
        MySQL.update.await([[UPDATE opslabs_phone_carrier_lines SET plan_id = ?, status = ?, installed = ?, period_start = ?, period_end = ?,
            auto_renew = ?, sms_used = 0, seconds_used = 0, data_kb = 0, extra_sms = 0, extra_minutes = 0, extra_data_mb = 0 WHERE id = ?]],
            { plan.id, status, installed, periodStart, periodEnd, autoRenew, line.id })
    else
        local iccid, code = newCodes()
        MySQL.insert.await([[INSERT INTO opslabs_phone_carrier_lines (identifier, plan_id, status, iccid, activation_code, installed, period_start, period_end, auto_renew)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]], { identifier, plan.id, status, iccid, code, installed, periodStart, periodEnd, autoRenew })
    end
    forget(identifier)
    line = getLine(identifier)
    event(line, 'subscribe', plan.name .. ((paidWith and paidWith.credit > 0) and (' (credit $' .. paidWith.credit .. ')') or ''), opts.charge ~= false and plan.price or 0)
    paidWith = nil
    if not opts.quiet then
        local src = GetSourceByIdentifier(identifier)
        if status == 'pending' then
            if src then Notify(src, { app = 'settings', title = settings().Name, icon = 'fa-sim-card', body = 'Your eSIM is ready. Tap to install it.', data = { page = 'cellular' } }) end
            carrierText(identifier, ('Thanks for joining %s! Your %s eSIM is ready: open Settings > Mobile Service on your phone to install it. Activation code: %s')
                :format(settings().Name, plan.name, line.activation_code))
        else
            carrierText(identifier, ('You are now on the %s plan%s. It renews %s.'):format(plan.name,
                plan.price > 0 and (' ($%d / %d days)'):format(plan.price, plan.period_days) or '', autoRenew and 'automatically' or 'manually'))
        end
    end
    pushStatus(identifier, true)
    return line
end

--- install the eSIM on the phone (activation code is optional for the owner)
function Carrier.Install(identifier, code)
    local line = getLine(identifier)
    if not line then return nil, 'no_line' end
    if code and code ~= '' and code:upper():gsub('%s', '') ~= line.activation_code then return nil, 'wrong_code' end
    if line.installed then return line end
    local plan = plans[line.plan_id]
    local now = os.time()
    local status = line.status == 'pending' and 'active' or line.status
    MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET installed = 1, status = ?, period_start = ?, period_end = ? WHERE id = ?',
        { status, now, now + ((plan and plan.period_days) or 7) * 86400, line.id })
    forget(identifier)
    line = getLine(identifier)
    event(line, 'install', 'eSIM installed')
    pushStatus(identifier, true)
    return line
end

function Carrier.AddOn(identifier, addon, opts)
    opts = opts or {}
    local line = getLine(identifier)
    if not addon or addon.kind ~= 'addon' then return nil, 'invalid_addon' end
    if not inService(line) then return nil, 'no_active_line' end
    if opts.charge ~= false then
        local ok, err; ok, err, paidWith = charge(identifier, addon.price, ('%s: %s'):format(settings().Name, addon.name))
        if not ok then return nil, err end
    end
    MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET extra_sms = extra_sms + ?, extra_minutes = extra_minutes + ?, extra_data_mb = extra_data_mb + ? WHERE id = ?',
        { math.max(0, addon.sms), math.max(0, addon.minutes), math.max(0, addon.data_mb), line.id })
    forget(identifier)
    line = getLine(identifier)
    event(line, 'addon', addon.name .. ((paidWith and paidWith.credit > 0) and (' (credit $' .. paidWith.credit .. ')') or ''), opts.charge ~= false and addon.price or 0)
    paidWith = nil
    carrierText(identifier, ('%s added to your plan.'):format(addon.name))
    pushStatus(identifier, true)
    return line
end

--- renew now (charged); returns line or nil, err
function Carrier.Renew(identifier, opts)
    opts = opts or {}
    local line = getLine(identifier)
    local plan = line and plans[line.plan_id]
    if not plan then return nil, 'no_line' end
    if not plan.active then return nil, 'plan_retired' end
    if opts.charge ~= false then
        local ok, err; ok, err, paidWith = charge(identifier, plan.price, ('%s: %s renewal'):format(settings().Name, plan.name))
        if not ok then return nil, err end
    end
    local now = os.time()
    MySQL.update.await([[UPDATE opslabs_phone_carrier_lines SET status = ?, period_start = ?, period_end = ?, sms_used = 0, seconds_used = 0,
        data_kb = 0, extra_sms = 0, extra_minutes = 0, extra_data_mb = 0 WHERE id = ?]], { line.installed and 'active' or 'pending', now, now + plan.period_days * 86400, line.id })
    forget(identifier)
    line = getLine(identifier)
    event(line, 'renew', plan.name .. ((paidWith and paidWith.credit > 0) and (' (credit $' .. paidWith.credit .. ')') or ''), opts.charge ~= false and plan.price or 0)
    paidWith = nil
    pushStatus(identifier, true)
    return line
end

function Carrier.SetStatus(identifier, status, detail)
    local line = getLine(identifier)
    if not line then return nil, 'no_line' end
    MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET status = ? WHERE id = ?', { status, line.id })
    forget(identifier)
    line = getLine(identifier)
    event(line, status, detail or '')
    pushStatus(identifier, true)
    return line
end

-- period ends: renew from the bank or let the line expire
CreateThread(function()
    while not ready do Wait(500) end
    while true do
        Wait(60000)
        if enabled() then
            local due = MySQL.query.await("SELECT identifier FROM opslabs_phone_carrier_lines WHERE status = 'active' AND period_end <= ?", { os.time() })
            for _, row in ipairs(due) do
                forget(row.identifier)
                local line = getLine(row.identifier)
                local plan = line and plans[line.plan_id]
                if line and line.auto_renew and plan and plan.active and plan.price > 0 then
                    local renewed, err = Carrier.Renew(row.identifier)
                    if renewed then
                        carrierText(row.identifier, ('Your %s plan renewed for $%d. Thanks for being with %s!'):format(plan.name, plan.price, settings().Name))
                    else
                        Carrier.SetStatus(row.identifier, 'expired', 'renewal failed: ' .. tostring(err))
                        carrierText(row.identifier, ("We couldn't renew your %s plan (%s), so your service has stopped. Renew at %s")
                            :format(plan.name, err == 'insufficient_funds' and 'not enough money in your bank' or tostring(err), settings().StoreUrl))
                    end
                elseif line then
                    Carrier.SetStatus(row.identifier, 'expired', 'period ended')
                    carrierText(row.identifier, ('Your %s plan has ended. Get a new plan at %s'):format(plan and plan.name or 'mobile', settings().StoreUrl))
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- phone RPCs
---------------------------------------------------------------------------

Register('carrierStatus', function(_, phone)
    return Carrier.View(phone.identifier)
end)

Register('carrierRadioMinute', function() return true end)

-- Wi-Fi passwords (opslabs-towers): join / forget a network from Settings > Wi-Fi
local function towersCall(fn, ...)
    if GetResourceState('opslabs-towers') ~= 'started' then return { error = 'unavailable' } end
    local args = { ... }
    local ok, r = pcall(function() return exports['opslabs-towers'][fn](exports['opslabs-towers'], table.unpack(args)) end)
    if not ok or type(r) ~= 'table' then return { error = 'unavailable' } end
    return r
end
Register('wifiJoin', function(src, _, data) return towersCall('JoinWifi', src, tonumber(data.id), tostring(data.password or '')) end)
Register('wifiForget', function(src, _, data) return towersCall('ForgetWifi', src, tonumber(data.id)) end)

---------------------------------------------------------------------------
-- OPS Mobile app (App Store): shop, renew, history. These don't use the
-- plan's data, like a real carrier app.
---------------------------------------------------------------------------

local ERR_TEXT = {
    insufficient_funds = "There isn't enough money in your bank account.",
    no_active_line = 'You need an active plan before adding extras.',
    plan_retired = 'This plan is no longer available. Choose a new plan.',
    invalid_plan = 'That plan is not available.', invalid_addon = 'That extra is not available.', no_line = "You don't have a line yet.",
}

Register('carrierShop', function(_, phone)
    local list = {}
    for _, p in pairs(plans) do
        if p.active and p.public then list[#list + 1] = planOut(p) end
    end
    table.sort(list, function(a, b) return a.sort == b.sort and a.id < b.id or a.sort < b.sort end)
    local bank = balance(phone.identifier)
    return { plans = list, balance = bank, credit = getCredit(phone.identifier), carrier = Carrier.View(phone.identifier) }
end)

Register('carrierBuy', function(_, phone, data)
    local item = planByCode[tostring(data.code or '')]
    if not item or not item.active or not item.public then return { error = ERR_TEXT.invalid_plan } end
    local line, err
    if item.kind == 'addon' then
        line, err = Carrier.AddOn(phone.identifier, item)
    else
        line, err = Carrier.Subscribe(phone.identifier, item, { auto_renew = data.auto_renew ~= false })
    end
    if not line then return { error = ERR_TEXT[err] or tostring(err) } end
    return { ok = true, carrier = Carrier.View(phone.identifier), balance = balance(phone.identifier), credit = getCredit(phone.identifier) }
end)

Register('carrierRenew', function(_, phone)
    local line, err = Carrier.Renew(phone.identifier)
    if not line then return { error = ERR_TEXT[err] or tostring(err) } end
    return { ok = true, carrier = Carrier.View(phone.identifier) }
end)

Register('carrierAutoRenew', function(_, phone, data)
    local line = getLine(phone.identifier)
    if not line then return { error = ERR_TEXT.no_line } end
    MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET auto_renew = ? WHERE id = ?', { data.on == true, line.id })
    forget(phone.identifier)
    event(getLine(phone.identifier), 'auto_renew', data.on == true and 'on' or 'off')
    return { ok = true, carrier = Carrier.View(phone.identifier) }
end)

Register('carrierActivity', function(_, phone)
    local line = getLine(phone.identifier)
    if not line then return { events = {}, daily = {} } end
    return {
        events = MySQL.query.await('SELECT type, detail, amount, UNIX_TIMESTAMP(created_at) AS at FROM opslabs_phone_carrier_events WHERE line_id = ? ORDER BY id DESC LIMIT 40', { line.id }),
        daily = MySQL.query.await([[SELECT DATE_FORMAT(day, '%Y-%m-%d') AS day, sms, seconds, data_kb FROM opslabs_phone_carrier_usage
            WHERE line_id = ? AND day > CURDATE() - INTERVAL 14 DAY ORDER BY day]], { line.id }),
    }
end)

Register('carrierInstall', function(_, phone, data)
    local line, err = Carrier.Install(phone.identifier, tostring(data.code or ''))
    if not line then return { error = err } end
    return Carrier.View(phone.identifier)
end)

---------------------------------------------------------------------------
-- REST API (used by the store website)
---------------------------------------------------------------------------

local route, apiError, requireUser, paging = ApiRoute, ApiError, ApiRequireUser, ApiPaging

function planOut(p)
    return {
        id = p.id, code = p.code, kind = p.kind, name = p.name, description = p.description, price = p.price,
        period_days = p.period_days, sms = p.sms, minutes = p.minutes, data_mb = p.data_mb, color = p.color,
        featured = p.featured, public = p.public, active = p.active, sort = p.sort,
    }
end

local function findPlan(v)
    return plans[tonumber(v) or -1] or planByCode[tostring(v or '')]
end

local function lineOut(identifier, extra)
    local user = MySQL.single.await([[SELECT p.phone_number, p.email, p.display_name, u.firstname, u.lastname
        FROM opslabs_phone_users p LEFT JOIN users u ON u.identifier = p.identifier WHERE p.identifier = ?]], { identifier })
    local line = getLine(identifier)
    local bank, cash = balance(identifier)
    local out = {
        number = user and user.phone_number, email = user and user.email,
        name = user and ((user.firstname and (user.firstname .. ' ' .. (user.lastname or ''))) or user.display_name) or nil,
        online = GetSourceByIdentifier(identifier) ~= nil,
        balance = { bank = bank, cash = cash, credit = getCredit(identifier) },
        carrier = Carrier.View(identifier),
    }
    if extra then
        out.credit_log = MySQL.query.await('SELECT amount, balance_after, reason, actor, created_at FROM opslabs_phone_carrier_credit_log WHERE identifier = ? ORDER BY id DESC LIMIT 30', { identifier })
    end
    if line then
        out.line_id = line.id
        out.activation_code = line.activation_code
        out.extra = { sms = line.extra_sms, minutes = line.extra_minutes, data_mb = line.extra_data_mb }
    end
    if extra and line then
        out.daily = MySQL.query.await([[SELECT DATE_FORMAT(day, '%Y-%m-%d') AS day, sms, seconds, data_kb FROM opslabs_phone_carrier_usage
            WHERE line_id = ? AND day > CURDATE() - INTERVAL 30 DAY ORDER BY day]], { line.id })
        out.events = MySQL.query.await('SELECT type, detail, amount, created_at FROM opslabs_phone_carrier_events WHERE line_id = ? ORDER BY id DESC LIMIT 50', { line.id })
    end
    return out
end

local function fail(err)
    local codes = { insufficient_funds = 402, no_account = 404, no_line = 404, invalid_plan = 400, invalid_addon = 400, no_active_line = 409, plan_retired = 409, wrong_code = 400 }
    apiError(codes[err] or 400, err)
end

route('GET', '/carrier/settings', function()
    local s = settings()
    return { enabled = s.Enabled ~= false, name = s.Name, number = s.Number, store_url = s.StoreUrl, starter_plan = s.StarterPlan or false, society = s.Society or false }
end)

route('PATCH', '/carrier/settings', function(_, _, body)
    local saved = KV.carrier and json.decode(KV.carrier) or {}
    if body.enabled ~= nil then saved.Enabled = body.enabled == true end
    if body.name then saved.Name = Clean(body.name, 30) end
    if body.number then saved.Number = NormalizeNumber(body.number) end
    if body.store_url then saved.StoreUrl = Clean(body.store_url, 120) end
    if body.starter_plan ~= nil then saved.StarterPlan = body.starter_plan ~= false and body.starter_plan ~= '' and tostring(body.starter_plan) or false end
    if body.society ~= nil then saved.Society = body.society ~= false and body.society ~= '' and Clean(body.society, 60) or false end
    SetKV('carrier', json.encode(saved))
    -- every online phone shows the new name / service state
    for src, phone in pairs(Phones) do Push(src, 'carrier', Carrier.View(phone.identifier)) end
    return { ok = true }
end)

route('GET', '/carrier/stats', function()
    local byStatus = {}
    for _, r in ipairs(MySQL.query.await('SELECT status, COUNT(*) AS n FROM opslabs_phone_carrier_lines GROUP BY status')) do byStatus[r.status] = r.n end
    return {
        lines = byStatus,
        revenue_30d = MySQL.scalar.await('SELECT CAST(COALESCE(SUM(amount), 0) AS SIGNED) FROM opslabs_phone_carrier_events WHERE created_at > NOW() - INTERVAL 30 DAY') or 0,
        revenue_total = MySQL.scalar.await('SELECT CAST(COALESCE(SUM(amount), 0) AS SIGNED) FROM opslabs_phone_carrier_events') or 0,
        usage_30d = MySQL.single.await([[SELECT CAST(COALESCE(SUM(sms), 0) AS SIGNED) AS sms, CAST(COALESCE(SUM(seconds), 0) AS SIGNED) AS seconds, CAST(COALESCE(SUM(data_kb), 0) AS SIGNED) AS data_kb
            FROM opslabs_phone_carrier_usage WHERE day > CURDATE() - INTERVAL 30 DAY]]),
        daily = MySQL.query.await([[SELECT DATE_FORMAT(day, '%Y-%m-%d') AS day, CAST(SUM(sms) AS SIGNED) AS sms, CAST(SUM(seconds) AS SIGNED) AS seconds, CAST(SUM(data_kb) AS SIGNED) AS data_kb
            FROM opslabs_phone_carrier_usage WHERE day > CURDATE() - INTERVAL 30 DAY GROUP BY day ORDER BY day]]),
        plans = MySQL.query.await([[SELECT p.name, COUNT(l.id) AS line_count FROM opslabs_phone_carrier_plans p
            LEFT JOIN opslabs_phone_carrier_lines l ON l.plan_id = p.id AND l.status = 'active' WHERE p.kind = 'plan' GROUP BY p.id ORDER BY p.sort]]),
    }
end)

route('GET', '/carrier/plans', function(_, q)
    local out = {}
    for _, p in pairs(plans) do
        if q.all == '1' or (p.active and p.public) then out[#out + 1] = planOut(p) end
    end
    table.sort(out, function(a, b) return a.sort == b.sort and a.id < b.id or a.sort < b.sort end)
    return out
end)

local PLAN_FIELDS = { code = 'string', kind = 'string', name = 'string', description = 'string', price = 'number', period_days = 'number',
    sms = 'number', minutes = 'number', data_mb = 'number', color = 'string', featured = 'boolean', public = 'boolean', active = 'boolean', sort = 'number' }

local function planValues(body, base)
    local v = {}
    for k, t in pairs(PLAN_FIELDS) do
        local x = body[k]
        if x == nil and base then x = base[k] end
        if t == 'number' then x = math.floor(tonumber(x) or 0)
        elseif t == 'boolean' then x = x == true or x == 1 or x == '1'
        else x = Clean(x or '', k == 'description' and 255 or 60) end
        v[k] = x
    end
    v.code = v.code:lower():gsub('[^%w%-]', '-')
    if v.kind ~= 'addon' then v.kind = 'plan' end
    if v.code == '' or v.name == '' then apiError(400, 'code and name are required') end
    if v.kind == 'plan' and v.period_days < 1 then apiError(400, 'period_days must be at least 1') end
    return v
end

route('POST', '/carrier/plans', function(_, _, body)
    local v = planValues(body, { active = true, public = true, color = '#0a84ff', sms = -1, minutes = -1, data_mb = -1, period_days = 7 })
    if planByCode[v.code] then apiError(409, 'A plan with this code already exists') end
    local id = MySQL.insert.await([[INSERT INTO opslabs_phone_carrier_plans (code, kind, name, description, price, period_days, sms, minutes, data_mb, color, featured, public, active, sort)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        { v.code, v.kind, v.name, v.description, v.price, v.period_days, v.sms, v.minutes, v.data_mb, v.color, v.featured, v.public, v.active, v.sort })
    loadPlans()
    return planOut(plans[id])
end)

route('PATCH', '/carrier/plans/(%d+)', function(p, _, body)
    local plan = plans[tonumber(p[1])]
    if not plan then apiError(404, 'Plan not found') end
    local v = planValues(body, plan)
    if v.code ~= plan.code and planByCode[v.code] then apiError(409, 'A plan with this code already exists') end
    MySQL.update.await([[UPDATE opslabs_phone_carrier_plans SET code = ?, kind = ?, name = ?, description = ?, price = ?, period_days = ?, sms = ?, minutes = ?,
        data_mb = ?, color = ?, featured = ?, public = ?, active = ?, sort = ? WHERE id = ?]],
        { v.code, v.kind, v.name, v.description, v.price, v.period_days, v.sms, v.minutes, v.data_mb, v.color, v.featured, v.public, v.active, v.sort, plan.id })
    loadPlans()
    for src, phone in pairs(Phones) do Push(src, 'carrier', Carrier.View(phone.identifier)) end
    return planOut(plans[plan.id])
end)

-- retiring keeps existing customers on it until their period ends
route('DELETE', '/carrier/plans/(%d+)', function(p)
    local plan = plans[tonumber(p[1])]
    if not plan then apiError(404, 'Plan not found') end
    MySQL.update.await('UPDATE opslabs_phone_carrier_plans SET active = 0 WHERE id = ?', { plan.id })
    loadPlans()
    return { ok = true }
end)

route('GET', '/carrier/lines', function(_, q)
    local limit, offset = paging(q)
    local search = '%' .. (q.search or '') .. '%'
    local status = q.status and q.status ~= '' and q.status or nil
    local rows = MySQL.query.await([[
        SELECT l.id, l.status, l.installed, l.period_end, l.auto_renew, l.sms_used, l.seconds_used, l.data_kb, l.created_at,
            p.phone_number AS number, p.email, CONCAT(COALESCE(u.firstname, ''), ' ', COALESCE(u.lastname, '')) AS name,
            pl.name AS plan, pl.code AS plan_code, pl.color AS plan_color, pl.price AS plan_price,
            IF(pl.sms < 0, -1, pl.sms + l.extra_sms) AS sms_limit, IF(pl.minutes < 0, -1, pl.minutes + l.extra_minutes) AS minutes_limit,
            IF(pl.data_mb < 0, -1, pl.data_mb + l.extra_data_mb) AS data_limit_mb, l.identifier
        FROM opslabs_phone_carrier_lines l
        JOIN opslabs_phone_users p ON p.identifier = l.identifier
        LEFT JOIN users u ON u.identifier = l.identifier
        LEFT JOIN opslabs_phone_carrier_plans pl ON pl.id = l.plan_id
        WHERE (? IS NULL OR l.status = ?) AND (p.phone_number LIKE ? OR p.email LIKE ? OR CONCAT(COALESCE(u.firstname, ''), ' ', COALESCE(u.lastname, '')) LIKE ?)
        ORDER BY l.updated_at DESC LIMIT ? OFFSET ?]], { status, status, search, search, search, limit, offset })
    for _, r in ipairs(rows) do
        r.installed, r.auto_renew = IsTrue(r.installed), IsTrue(r.auto_renew)
        r.online = GetSourceByIdentifier(r.identifier) ~= nil
        r.identifier = nil
    end
    return rows
end)

route('GET', '/carrier/lines/([^/]+)', function(p)
    return lineOut(requireUser(p[1]).identifier, true)
end)

route('POST', '/carrier/lines/([^/]+)/subscribe', function(p, _, body)
    local user = requireUser(p[1])
    local plan = findPlan(body.plan_id or body.plan)
    if not plan or not plan.active then apiError(400, 'invalid_plan') end
    local line, err = Carrier.Subscribe(user.identifier, plan, { charge = body.charge ~= false, auto_renew = body.auto_renew ~= false, install = body.install == true })
    if not line then fail(err) end
    return lineOut(user.identifier)
end)

route('POST', '/carrier/lines/([^/]+)/addon', function(p, _, body)
    local user = requireUser(p[1])
    local addon = findPlan(body.plan_id or body.plan)
    if not addon or not addon.active then apiError(400, 'invalid_addon') end
    local line, err = Carrier.AddOn(user.identifier, addon, { charge = body.charge ~= false })
    if not line then fail(err) end
    return lineOut(user.identifier)
end)

-- { action = suspend | resume | cancel | renew | reset_usage | reissue_esim | install | notify }
route('POST', '/carrier/lines/([^/]+)/action', function(p, _, body)
    local user = requireUser(p[1])
    local id = user.identifier
    local line = getLine(id)
    if not line then apiError(404, 'no_line') end
    local a = tostring(body.action or '')
    local ok, err = true, nil
    if a == 'suspend' then
        Carrier.SetStatus(id, 'suspended', body.reason)
        carrierText(id, ('Your %s service has been suspended.%s'):format(settings().Name, body.reason and (' Reason: ' .. Clean(body.reason, 120)) or ''))
    elseif a == 'resume' then
        Carrier.SetStatus(id, line.installed and 'active' or 'pending', 'resumed')
        carrierText(id, ('Your %s service is back on.'):format(settings().Name))
    elseif a == 'cancel' then
        Carrier.SetStatus(id, 'cancelled', body.reason)
        MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET auto_renew = 0, period_end = ? WHERE id = ?', { os.time(), line.id })
        forget(id); pushStatus(id, true)
        carrierText(id, ('Your %s line has been cancelled.'):format(settings().Name))
    elseif a == 'renew' then
        ok, err = Carrier.Renew(id, { charge = body.charge ~= false })
    elseif a == 'reset_usage' then
        MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET sms_used = 0, seconds_used = 0, data_kb = 0 WHERE id = ?', { line.id })
        forget(id); event(line, 'reset_usage', 'usage reset'); pushStatus(id, true)
    elseif a == 'reissue_esim' then
        local _, code = newCodes()
        MySQL.update.await('UPDATE opslabs_phone_carrier_lines SET activation_code = ?, installed = 0, status = IF(status = \'active\', \'pending\', status) WHERE id = ?', { code, line.id })
        forget(id); event(line, 'reissue_esim', 'new eSIM issued'); pushStatus(id, true)
        carrierText(id, ('A new eSIM was issued for your line. Install it in Settings > Mobile Service. Activation code: %s'):format(code))
    elseif a == 'install' then
        ok, err = Carrier.Install(id)
    elseif a == 'notify' then
        local src = GetSourceByIdentifier(id)
        if not src then apiError(409, 'offline') end
        Notify(src, { app = 'settings', title = settings().Name, icon = 'fa-sim-card', body = line.installed and 'Tap to see your plan and usage.' or 'Your eSIM is ready. Tap to install it.', data = { page = 'cellular' } })
    else
        apiError(400, 'unknown action')
    end
    if not ok then fail(err) end
    return lineOut(id)
end)

-- admin adjustments: { auto_renew, extra_sms, extra_minutes, extra_data_mb, period_end, plan_id (no charge) }
route('PATCH', '/carrier/lines/([^/]+)', function(p, _, body)
    local user = requireUser(p[1])
    local line = getLine(user.identifier)
    if not line then apiError(404, 'no_line') end
    local sets, vals = {}, {}
    local function set(col, v) sets[#sets + 1] = col .. ' = ?'; vals[#vals + 1] = v end
    if body.auto_renew ~= nil then set('auto_renew', body.auto_renew == true) end
    for _, k in ipairs({ 'extra_sms', 'extra_minutes', 'extra_data_mb', 'period_end' }) do
        if body[k] ~= nil then set(k, math.floor(tonumber(body[k]) or 0)) end
    end
    if body.plan_id ~= nil then
        local plan = findPlan(body.plan_id)
        if not plan or plan.kind ~= 'plan' then apiError(400, 'invalid_plan') end
        set('plan_id', plan.id)
    end
    if #sets == 0 then apiError(400, 'nothing to change') end
    vals[#vals + 1] = line.id
    MySQL.update.await(('UPDATE opslabs_phone_carrier_lines SET %s WHERE id = ?'):format(table.concat(sets, ', ')), vals)
    forget(user.identifier)
    event(getLine(user.identifier), 'admin_change', json.encode(body):sub(1, 250))
    pushStatus(user.identifier, true)
    return lineOut(user.identifier)
end)

route('GET', '/users/([^/]+)/balance', function(p)
    local bank, cash = balance(requireUser(p[1]).identifier)
    return { bank = bank, cash = cash }
end)

-- text from the carrier number (store sign-in codes, announcements)
route('POST', '/carrier/sms', function(_, _, body)
    local user = requireUser(NormalizeNumber(body.number or ''))
    local msg = Clean(body.message, 500)
    if msg == '' then apiError(400, 'message is required') end
    carrierText(user.identifier, msg)
    return { ok = true }
end)

---------------------------------------------------------------------------
-- carrier inbox: texts between the carrier number and customers
---------------------------------------------------------------------------

local function threadRows(carrierNo, number, sinceId)
    local rows = MySQL.query.await([[SELECT id, sender, message, attachment, is_read, UNIX_TIMESTAMP(created_at) AS at FROM opslabs_phone_messages
        WHERE ((sender = ? AND receiver = ?) OR (sender = ? AND receiver = ?)) AND id > ? ORDER BY id DESC LIMIT 200]],
        { carrierNo, number, number, carrierNo, sinceId or 0 })
    local out = {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        local att = r.attachment and json.decode(r.attachment) or nil
        out[#out + 1] = { id = r.id, from = r.sender == carrierNo and 'carrier' or 'customer', message = r.message, attachment = att,
            read = IsTrue(r.is_read), at = r.at }
    end
    return out
end

-- ?since=<message id> returns only newer messages (for live refresh)
route('GET', '/carrier/messages/([^/]+)', function(p, q)
    local user = requireUser(p[1])
    return { number = user.phone_number, messages = threadRows(settings().Number, user.phone_number, tonumber(q.since)) }
end)

-- the customer's replies have been seen by staff
route('POST', '/carrier/messages/([^/]+)/read', function(p)
    local user = requireUser(p[1])
    MySQL.update.await('UPDATE opslabs_phone_messages SET is_read = 1 WHERE sender = ? AND receiver = ? AND is_read = 0', { user.phone_number, settings().Number })
    return { ok = true }
end)

-- conversations, newest first, with unread customer replies
route('GET', '/carrier/inbox', function(_, q)
    local limit, offset = paging(q)
    local c = settings().Number
    local rows = MySQL.query.await([[
        SELECT t.number, UNIX_TIMESTAMP(m.created_at) AS at, m.message, m.sender = ? AS from_carrier,
            (SELECT COUNT(*) FROM opslabs_phone_messages x WHERE x.sender = t.number AND x.receiver = ? AND x.is_read = 0) AS unread,
            CONCAT(COALESCE(u.firstname, ''), ' ', COALESCE(u.lastname, '')) AS name
        FROM (SELECT IF(sender = ?, receiver, sender) AS number, MAX(id) AS last_id FROM opslabs_phone_messages
              WHERE sender = ? OR receiver = ? GROUP BY IF(sender = ?, receiver, sender)) t
        JOIN opslabs_phone_messages m ON m.id = t.last_id
        LEFT JOIN opslabs_phone_users p ON p.phone_number = t.number
        LEFT JOIN users u ON u.identifier = p.identifier
        ORDER BY (unread > 0) DESC, t.last_id DESC LIMIT ? OFFSET ?]], { c, c, c, c, c, c, limit, offset })
    for _, r in ipairs(rows) do r.from_carrier = IsTrue(r.from_carrier) end
    return rows
end)

---------------------------------------------------------------------------
-- credit API
---------------------------------------------------------------------------

route('GET', '/carrier/credit/([^/]+)', function(p)
    local user = requireUser(p[1])
    return {
        balance = getCredit(user.identifier),
        log = MySQL.query.await('SELECT amount, balance_after, reason, actor, created_at FROM opslabs_phone_carrier_credit_log WHERE identifier = ? ORDER BY id DESC LIMIT 100', { user.identifier }),
    }
end)

-- { amount (negative removes), reason, actor, quiet }
route('POST', '/carrier/credit/([^/]+)', function(p, _, body)
    local user = requireUser(p[1])
    local amount = math.floor(tonumber(body.amount) or 0)
    if amount == 0 or math.abs(amount) > 10000000 then apiError(400, 'amount must be a non-zero number') end
    local after = Carrier.AdjustCredit(user.identifier, amount, body.reason, body.actor or 'api', { quiet = body.quiet == true })
    return { balance = after }
end)

-- total credit outstanding (for the dashboard)
route('GET', '/carrier/credit', function()
    return {
        outstanding = MySQL.scalar.await('SELECT CAST(COALESCE(SUM(balance), 0) AS SIGNED) FROM opslabs_phone_carrier_credit') or 0,
        customers = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_carrier_credit WHERE balance > 0') or 0,
        given_30d = MySQL.scalar.await("SELECT CAST(COALESCE(SUM(amount), 0) AS SIGNED) FROM opslabs_phone_carrier_credit_log WHERE amount > 0 AND created_at > NOW() - INTERVAL 30 DAY") or 0,
    }
end)
