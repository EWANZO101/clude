-- OPS business layer (Phase 6): quotes → work orders, contracts & SLAs, stock & purchase orders, installed assets &
-- warranties, engineer certifications (training exams in OPS Work), company vans & tools, support tickets and alerts.
-- Shared with OPS Hub (sql/ops_business.sql); prices, parts, certs and suppliers: sql/ops_catalog.json → business.
--
-- How it plugs into jobs (server/platform.lua):
--   created   → due_at from the customer's contract (response hours) or SLA tier; emergencies within 4 h
--   accepted  → the job type's certification is required (OPS Work → Training)
--   completed → warranty / contract cover makes repairs free; parts come out of the company's stock; installed kit is
--               registered as the customer's assets with serials and a warranty; a late finish is an SLA breach

local B = (Ops and Ops.catalog and Ops.catalog.business) or {}
local DAY, HOUR = 86400, 3600
local CERTS, SUPPLIERS, KINDS = {}, {}, {}
for _, c in ipairs(B.certs or {}) do CERTS[c.code] = c end
for _, s in ipairs(B.suppliers or {}) do SUPPLIERS[s.code] = s end
for _, k in ipairs(B.contractKinds or {}) do KINDS[k.code] = k end

local function now() return os.time() end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function money(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end
local function str(v, max) return Clean(tostring(v or ''), max or 200) end
local function serial(sku) return ('%s-%06X'):format(tostring(sku):upper():gsub('[^A-Z0-9]', ''):sub(1, 6), math.random(0, 0xffffff)) end

CreateThread(function()
    AwaitDatabase()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'sql/ops_business.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    for _, tc in ipairs({ { 'ops_quotes', 'notify' }, { 'ops_tickets', 'notify' } }) do
        local has = MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', tc)
        if (tonumber(has) or 0) == 0 then MySQL.query.await(('ALTER TABLE %s ADD COLUMN %s TINYINT(1) NOT NULL DEFAULT 0'):format(tc[1], tc[2])) end
    end
    for _, s in ipairs(B.suppliers or {}) do
        MySQL.query.await('INSERT INTO ops_suppliers (code, name, contact, phone, lead_hours, terms) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE code = code',
            { s.code, s.name, s.contact, s.phone, s.leadHours or 2, s.terms })
    end
    -- the gateway router's SKU used to carry a real product name (rtr-udm) — renamed once, keeping stock and history
    pcall(MySQL.update.await, "UPDATE IGNORE ops_stock SET sku = 'rtr-gw' WHERE sku = 'rtr-udm'")
    pcall(MySQL.update.await, "UPDATE ops_stock_moves SET sku = 'rtr-gw' WHERE sku = 'rtr-udm'")
    Wait(3000)
    for code, items in pairs(B.stock or {}) do
        local c = Ops.company(code)
        if c then
            for _, it in ipairs(items) do
                MySQL.query.await('INSERT INTO ops_stock (company_id, sku, name, unit, qty, min_qty, cost, supplier) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), unit = VALUES(unit)',
                    { c.id, it.sku, it.name, it.unit, it.start or 0, it.min or 0, it.cost or 0, it.supplier })
            end
        end
    end
end)

---------------------------------------------------------------------------
-- alerts (OPS Hub alert centre + phone notifications to the right people)
---------------------------------------------------------------------------
local PERM_FOR = { stock = 'stock.manage', sla = 'jobs.dispatch', contract = 'contracts.manage', cert = 'training.manage', vehicle = 'fleet.manage', quote = 'quotes.manage', ticket = 'tickets.manage', po = 'stock.manage' }
function BizAlert(dkey, coId, kind, severity, title, body, link)
    local existing = MySQL.single.await('SELECT id, resolved_at FROM ops_alerts WHERE dkey = ?', { dkey })
    if existing and not existing.resolved_at then return false end
    if existing then
        MySQL.update.await('UPDATE ops_alerts SET resolved_at = NULL, created_at = ?, title = ?, body = ?, severity = ? WHERE id = ?', { now(), title, body, severity, existing.id })
    else
        MySQL.insert.await('INSERT INTO ops_alerts (dkey, company_id, kind, severity, title, body, link, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', { dkey, coId, kind, severity, title, body, link, now() })
    end
    if coId then Ops.notifyId(coId, PERM_FOR[kind] or 'company.manage', { app = 'opswork', title = title, body = body or '', icon = severity == 'bad' and 'fa-triangle-exclamation' or 'fa-bell' }) end
    return true
end
function BizResolve(dkey) MySQL.update('UPDATE ops_alerts SET resolved_at = ? WHERE dkey = ? AND resolved_at IS NULL', { now(), dkey }) end

local function custSrc(cust) return cust and cust.identifier and GetSourceByIdentifier(cust.identifier) end
local function tellCustomer(cust, notif) local s = custSrc(cust) if s then Notify(s, notif) end end

---------------------------------------------------------------------------
-- job hooks (called from platform.lua)
---------------------------------------------------------------------------
function BizCertName(code) return CERTS[code] and CERTS[code].name end

local function hasCert(accountId, code)
    return MySQL.scalar.await('SELECT 1 FROM ops_member_certs WHERE account_id = ? AND cert = ? AND expires_at > ?', { accountId, code, now() }) ~= nil
end

local function activeContract(coId, customerId)
    if not customerId then return nil end
    return MySQL.single.await("SELECT * FROM ops_contracts WHERE company_id = ? AND customer_id = ? AND status = 'active' ORDER BY response_hours LIMIT 1", { coId, customerId })
end

function BizOnJobCreated(id, c, customerId, emergency)
    local hours
    local k = activeContract(c.id, customerId)
    if k then hours = k.response_hours
    elseif customerId then
        local tier = MySQL.scalar.await('SELECT sla FROM ops_customers WHERE id = ?', { customerId })
        hours = (B.slaHours or {})[tier or 'standard']
    end
    if emergency then hours = math.min(hours or 4, 4) end
    if hours then MySQL.update.await('UPDATE ops_jobs SET due_at = ? WHERE id = ?', { now() + hours * HOUR, id }) end
end

--- is this job free for the customer? → text for the job result, or nil
function BizCoverage(j, c, cust)
    if not cust then return nil end
    local t = Ops.types[j.type] or {}
    local k = activeContract(c.id, cust.id)
    if k then
        local covers = (KINDS[k.kind] or {}).covers
        if covers == 'all' or (covers == 'repairs' and t.warranty) or (covers == 'maintenance' and tostring(j.type):find('maint')) then
            return ('Covered by contract %s'):format(k.number or k.id)
        end
    end
    if t.warranty then
        local a = MySQL.single.await("SELECT serial, name FROM ops_assets WHERE company_id = ? AND customer_id = ? AND status = 'installed' AND warranty_until > ? ORDER BY warranty_until DESC LIMIT 1",
            { c.id, cust.id, now() })
        if a then return ('Covered by warranty (%s %s)'):format(a.name, a.serial) end
    end
    return nil
end

local function stockRow(coId, sku) return MySQL.single.await('SELECT * FROM ops_stock WHERE company_id = ? AND sku = ?', { coId, sku }) end

local function checkStock(coId, sku)
    local s = stockRow(coId, sku)
    if not s then return end
    local key = ('stock:%d:%s'):format(coId, sku)
    if tonumber(s.qty) < tonumber(s.min_qty) then
        BizAlert(key, coId, 'stock', tonumber(s.qty) <= 0 and 'bad' or 'warn', ('Low stock: %s'):format(s.name), ('%s %s left (minimum %s) — order more on OPS Hub'):format(money(s.qty), s.unit, money(s.min_qty)))
    else BizResolve(key) end
end

function BizOnCompleted(j, c, cust, a)
    local t = Ops.types[j.type] or {}
    for sku, qty in pairs(t.parts or {}) do
        local s = stockRow(c.id, sku)
        if s then
            MySQL.update.await('UPDATE ops_stock SET qty = qty - ? WHERE id = ?', { qty, s.id })
            MySQL.insert.await('INSERT INTO ops_stock_moves (company_id, sku, qty, reason, ref, actor, at) VALUES (?, ?, ?, ?, ?, ?, ?)', { c.id, sku, -qty, 'job', j.ref, Ops.nameOf(a), now() })
            checkStock(c.id, sku)
            -- kit (not cable / consumables) becomes the customer's asset, with a serial and a warranty
            if cust and s.unit == 'each' and tonumber(s.cost) >= 20 then
                for _ = 1, math.min(qty, 10) do
                    MySQL.insert.await([[INSERT INTO ops_assets (company_id, customer_id, sku, name, serial, location, job_id, installed_at, warranty_until)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]], { c.id, cust.id, sku, s.name, serial(sku), j.location, j.id, now(), now() + (B.warrantyDays or 30) * DAY })
                end
            end
        end
    end
    BizResolve('sla:' .. j.id)
    if j.due_at and now() > j.due_at then
        MySQL.insert('INSERT INTO ops_audit (at, actor, company_id, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)',
            { now(), 'sla', c.id, 'sla.breach', j.ref, ('finished %d min late'):format(math.floor((now() - j.due_at) / 60)) })
    end
end

---------------------------------------------------------------------------
-- quotes → work orders (jobs) and contracts
---------------------------------------------------------------------------
function BizAcceptQuote(qt, by)
    local c = Ops.byId(qt.company_id)
    local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { qt.customer_id })
    if not c or not cust then return nil end
    local items = decode(qt.items, {})
    local vat = 1 + (tonumber(c.vat_pct) or 20) / 100
    local jobs, extra, contractId = {}, 0, nil
    local typed = {}
    for _, it in ipairs(items) do
        local total = money((tonumber(it.qty) or 1) * (tonumber(it.unit) or 0))
        if it.contract and KINDS[it.contract] then
            local tier = it.sla or 'business'
            local hours = 24
            for _, s in ipairs(B.slaTiers or {}) do if s.code == tier then hours = s.hours end end
            contractId = MySQL.insert.await([[INSERT INTO ops_contracts (company_id, customer_id, title, kind, sla, response_hours, fee, status, start_at, next_bill_at, auto_renew, created_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, 1, ?, ?)]], { c.id, cust.id, it.description or (KINDS[it.contract].name), it.contract, tier, hours, money(total * vat), now(), now(), by, now() })
            MySQL.update.await('UPDATE ops_contracts SET number = ? WHERE id = ?', { ('%s-C%05d'):format(c.code:upper():sub(1, 3), contractId), contractId })
        elseif it.type and Ops.types[it.type] then typed[#typed + 1] = { it = it, total = total }
        else extra = extra + total end
    end
    local place = { customer_id = cust.id, address = cust.address or cust.name, x = cust.x, y = cust.y, z = cust.z }
    for i, x in ipairs(typed) do
        local price = money((x.total + (i == 1 and extra or 0)) * vat)
        local id, ref = Ops.job(c.code, x.it.type, place, { title = x.it.description, price = price, by = by, description = ('From quote %s · %s'):format(qt.number or qt.id, qt.title) })
        if ref then jobs[#jobs + 1] = ref end
    end
    if #typed == 0 and extra > 0 then
        Ops.invoice(c.code, cust, qt.title, qt.number, money(extra * vat), false)     -- supply only: invoiced
    end
    MySQL.update.await("UPDATE ops_quotes SET status = 'accepted', jobs = ?, contract_id = ?, decided_at = COALESCE(decided_at, ?), decided_by = COALESCE(decided_by, ?) WHERE id = ?",
        { table.concat(jobs, ','), contractId, now(), by, qt.id })
    Ops.notifyId(c.id, 'quotes.manage', { app = 'opswork', title = c.name .. ' · quote accepted', body = ('%s accepted %s ($%s)%s'):format(cust.name, qt.number or '', money(qt.total), #jobs > 0 and (' · jobs ' .. table.concat(jobs, ', ')) or ''), icon = 'fa-file-signature' })
    Ops.audit(by, c.id, 'quote.accept', qt.number, table.concat(jobs, ','))
    return jobs, contractId
end

---------------------------------------------------------------------------
-- the clock: contracts, deliveries, expiries, SLA watch, alerts
---------------------------------------------------------------------------
local function sweep()
    local t = now()
    -- quotes accepted on the website: turn them into work
    for _, qt in ipairs(MySQL.query.await("SELECT * FROM ops_quotes WHERE status = 'accepted' AND jobs IS NULL AND contract_id IS NULL") or {}) do BizAcceptQuote(qt, qt.decided_by or 'portal') end
    MySQL.update.await("UPDATE ops_quotes SET status = 'expired' WHERE status = 'sent' AND valid_until < ?", { t })
    -- contracts
    for _, k in ipairs(MySQL.query.await("SELECT * FROM ops_contracts WHERE status = 'active' AND next_bill_at <= ?", { t }) or {}) do
        local c = Ops.byId(k.company_id)
        if k.end_at and k.end_at <= t and not IsTrue(k.auto_renew) then
            MySQL.update.await("UPDATE ops_contracts SET status = 'ended' WHERE id = ?", { k.id })
        elseif c then
            local ok, why = Ops.charge(k.customer_id, k.fee, ('%s · contract %s'):format(c.name, k.number or k.id))
            local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { k.customer_id })
            if ok then
                Ops.move(c.code, 'income', k.fee, 'Contract ' .. (k.number or k.id), 'contract', k.id, cust and cust.name, 'billing')
                Ops.invoice(c.code, cust, ('%s · %s'):format(k.title, os.date('%b %Y')), k.number, k.fee, true)
                MySQL.update.await('UPDATE ops_contracts SET next_bill_at = ?, overdue_since = NULL WHERE id = ?', { k.next_bill_at + (B.contractPeriodDays or 30) * DAY, k.id })
                BizResolve('contract:' .. k.id)
            elseif why ~= 'offline' or t - k.next_bill_at > 2 * DAY then
                if not k.overdue_since then MySQL.update.await('UPDATE ops_contracts SET overdue_since = ? WHERE id = ?', { t, k.id }) end
                BizAlert('contract:' .. k.id, k.company_id, 'contract', 'warn', ('Contract %s unpaid'):format(k.number or k.id), ('%s couldn’t be charged $%s'):format(cust and cust.name or '?', money(k.fee)))
                if k.overdue_since and t - k.overdue_since > 7 * DAY then MySQL.update.await("UPDATE ops_contracts SET status = 'suspended' WHERE id = ?", { k.id }) end
            end
        end
    end
    -- purchase orders arriving
    for _, po in ipairs(MySQL.query.await("SELECT * FROM ops_pos WHERE status = 'ordered' AND eta <= ?", { t }) or {}) do
        for _, it in ipairs(decode(po.items, {})) do
            MySQL.update.await('UPDATE ops_stock SET qty = qty + ? WHERE company_id = ? AND sku = ?', { tonumber(it.qty) or 0, po.company_id, it.sku })
            MySQL.insert.await('INSERT INTO ops_stock_moves (company_id, sku, qty, reason, ref, actor, at) VALUES (?, ?, ?, ?, ?, ?, ?)', { po.company_id, it.sku, tonumber(it.qty) or 0, 'po', po.number, 'delivery', t })
            checkStock(po.company_id, it.sku)
        end
        MySQL.update.await("UPDATE ops_pos SET status = 'received', received_at = ? WHERE id = ?", { t, po.id })
        Ops.notifyId(po.company_id, 'stock.manage', { app = 'opswork', title = 'Delivery arrived', body = ('%s from %s is in stock'):format(po.number or ('PO ' .. po.id), (SUPPLIERS[po.supplier] or {}).name or po.supplier), icon = 'fa-truck-ramp-box' })
    end
    -- jobs made on OPS Hub / by other systems get their SLA due time too
    for _, j in ipairs(MySQL.query.await("SELECT id, company_id, customer_id, emergency FROM ops_jobs WHERE status = 'open' AND due_at IS NULL AND customer_id IS NOT NULL AND created_at > ?", { t - DAY }) or {}) do
        local c = Ops.byId(j.company_id)
        if c then BizOnJobCreated(j.id, c, j.customer_id, IsTrue(j.emergency)) end
    end
    -- SLA watch: open work past its due time
    for _, j in ipairs(MySQL.query.await("SELECT id, ref, title, company_id, due_at FROM ops_jobs WHERE status IN ('open','assigned','in_progress') AND due_at IS NOT NULL AND due_at < ?", { t }) or {}) do
        BizAlert('sla:' .. j.id, j.company_id, 'sla', 'bad', ('SLA breached: %s'):format(j.ref), j.title)
    end
    for _, j in ipairs(MySQL.query.await("SELECT id, ref, title, company_id, due_at FROM ops_jobs WHERE status IN ('open','assigned') AND due_at BETWEEN ? AND ?", { t, t + HOUR }) or {}) do
        BizAlert('sla_soon:' .. j.id, j.company_id, 'sla', 'warn', ('Due within the hour: %s'):format(j.ref), j.title)
    end
    MySQL.update.await("UPDATE ops_alerts a JOIN ops_jobs j ON a.dkey IN (CONCAT('sla:', j.id), CONCAT('sla_soon:', j.id)) SET a.resolved_at = ? WHERE a.resolved_at IS NULL AND j.status IN ('completed', 'cancelled')", { t })
    -- certifications running out (alert the person's companies' trainers)
    for _, r in ipairs(MySQL.query.await([[SELECT mc.*, u.display_name, u.username, m.company_id FROM ops_member_certs mc JOIN opslabs_phone_opsnet_users u ON u.id = mc.account_id
        JOIN ops_members m ON m.account_id = mc.account_id AND m.status = 'active' WHERE mc.expires_at BETWEEN ? AND ?]], { t, t + 3 * DAY }) or {}) do
        if (CERTS[r.cert] or {}).company and Ops.company(CERTS[r.cert].company) and Ops.company(CERTS[r.cert].company).id == r.company_id then
            BizAlert(('cert:%d:%s'):format(r.account_id, r.cert), r.company_id, 'cert', 'warn', ('Certification expiring: %s'):format(r.display_name or r.username), ('%s runs out %s'):format(BizCertName(r.cert) or r.cert, os.date('%d %b', r.expires_at)))
        end
    end
    -- vans due a service
    for _, v in ipairs(MySQL.query.await("SELECT * FROM ops_vehicles WHERE status <> 'retired' AND service_due_at IS NOT NULL AND service_due_at < ?", { t }) or {}) do
        BizAlert('vehicle:' .. v.id, v.company_id, 'vehicle', 'warn', ('Service due: %s'):format(v.plate), v.label or v.model)
    end
end

-- things done on OPS Hub that the customer should hear about in game (notify = 1)
local function tellCustomers()
    MySQL.update.await("UPDATE ops_quotes SET notify = 0 WHERE notify = 1 AND status <> 'sent'")      -- decided before they were told
    for _, qt in ipairs(MySQL.query.await([[SELECT q.*, c.name AS company FROM ops_quotes q JOIN ops_companies c ON c.id = q.company_id WHERE q.notify = 1 AND q.status = 'sent']]) or {}) do
        local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { qt.customer_id })
        local s = custSrc(cust)
        if s then
            Notify(s, { app = 'opswork', title = qt.company .. ' · new quote', body = ('%s — $%s. Accept it in OPS Work → My services'):format(qt.title, money(qt.total)), icon = 'fa-file-invoice', data = { page = 'mystuff' } })
            MySQL.update.await('UPDATE ops_quotes SET notify = 0 WHERE id = ?', { qt.id })
        end
    end
    for _, tk in ipairs(MySQL.query.await([[SELECT t.*, c.name AS company FROM ops_tickets t JOIN ops_companies c ON c.id = t.company_id WHERE t.notify = 1]]) or {}) do
        local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { tk.customer_id })
        local s = custSrc(cust)
        if s then
            Notify(s, { app = 'opswork', title = tk.company .. ' replied', body = ('%s · %s'):format(tk.ref or '', tk.subject), icon = 'fa-headset', data = { page = 'mystuff' } })
            MySQL.update.await('UPDATE ops_tickets SET notify = 0 WHERE id = ?', { tk.id })
        end
    end
end

CreateThread(function()
    AwaitDatabase()
    Wait(20000)
    while true do pcall(tellCustomers) Wait(30000) end
end)

CreateThread(function()
    AwaitDatabase()
    Wait(40000)
    while true do
        local ok, err = pcall(sweep)
        if not ok then print('^1[opslabs-phone] business: ' .. tostring(err) .. '^7') end
        Wait(120000)
    end
end)

---------------------------------------------------------------------------
-- OPS Work: training & certifications
---------------------------------------------------------------------------
local function On(name, fn)
    Register(name, function(src, phone, d)
        local a = Ops.account(src)
        return fn(src, phone, d, a)
    end)
end

-- (training, exams and certifications live in server/training.lua)

---------------------------------------------------------------------------
-- OPS Work: my van and tools
---------------------------------------------------------------------------
On('opsMyKit', function(_, _, _, a)
    if not a then return { loggedOut = true } end
    local vans = MySQL.query.await([[SELECT v.*, c.name AS company, c.color FROM ops_vehicles v JOIN ops_companies c ON c.id = v.company_id WHERE v.assigned_to = ? AND v.status <> 'retired']], { a.id }) or {}
    local tools = MySQL.query.await([[SELECT t.*, c.name AS company FROM ops_tools t JOIN ops_companies c ON c.id = t.company_id WHERE t.assigned_to = ? AND t.status <> 'retired' ORDER BY t.kind]], { a.id }) or {}
    return { vehicles = vans, tools = tools }
end)

local out = {}             -- src -> vehicle id
On('opsVehicleOut', function(src, _, d, a)
    if not a then return { loggedOut = true } end
    local v = MySQL.single.await('SELECT * FROM ops_vehicles WHERE id = ? AND assigned_to = ?', { tonumber(d.id) or 0, a.id })
    if not v then return { error = 'That isn’t your van' } end
    if v.status ~= 'available' then return { error = 'It’s ' .. v.status } end
    if out[src] then return { error = 'Return your other van first' } end
    out[src] = v.id
    MySQL.update.await('UPDATE ops_vehicles SET out_at = ? WHERE id = ?', { now(), v.id })
    return { ok = true, model = v.model, plate = v.plate }
end)
On('opsVehicleIn', function(src, _, d, a)
    local id = out[src]
    if not id then return { error = 'No van out' } end
    out[src] = nil
    local km = math.max(0, math.min(500, math.floor(tonumber(d.km) or 0)))
    MySQL.update.await('UPDATE ops_vehicles SET out_at = NULL, mileage = mileage + ? WHERE id = ?', { km, id })
    return { ok = true, km = km }
end)
AddEventHandler('playerDropped', function()
    local id = out[source]
    if id then MySQL.update('UPDATE ops_vehicles SET out_at = NULL WHERE id = ?', { id }) out[source] = nil end
end)

---------------------------------------------------------------------------
-- OPS Work (customer side): quotes, contracts, assets, tickets
---------------------------------------------------------------------------
local function myCustomer(phone) return MySQL.single.await('SELECT * FROM ops_customers WHERE identifier = ? LIMIT 1', { phone.identifier }) end

Register('opsMyQuotes', function(_, phone)
    local cust = myCustomer(phone)
    if not cust then return { quotes = {}, contracts = {}, assets = {} } end
    local quotes = MySQL.query.await([[SELECT q.*, c.name AS company, c.color, c.icon FROM ops_quotes q JOIN ops_companies c ON c.id = q.company_id
        WHERE q.customer_id = ? AND q.status IN ('sent', 'accepted', 'declined', 'expired') ORDER BY q.status = 'sent' DESC, q.id DESC LIMIT 30]], { cust.id }) or {}
    for _, q in ipairs(quotes) do q.items = decode(q.items, {}) end
    local contracts = MySQL.query.await([[SELECT k.*, c.name AS company, c.color FROM ops_contracts k JOIN ops_companies c ON c.id = k.company_id WHERE k.customer_id = ? AND k.status <> 'ended' ORDER BY k.id DESC]], { cust.id }) or {}
    local assets = MySQL.query.await([[SELECT a.*, c.name AS company FROM ops_assets a JOIN ops_companies c ON c.id = a.company_id WHERE a.customer_id = ? AND a.status = 'installed' ORDER BY a.installed_at DESC LIMIT 60]], { cust.id }) or {}
    return { quotes = quotes, contracts = contracts, assets = assets, now = now() }
end)

Register('opsQuoteDecide', function(_, phone, d)
    local cust = myCustomer(phone)
    local qt = cust and MySQL.single.await("SELECT * FROM ops_quotes WHERE id = ? AND customer_id = ? AND status = 'sent'", { tonumber(d.id) or 0, cust.id })
    if not qt then return { error = 'That quote can’t be changed now' } end
    if qt.valid_until and qt.valid_until < now() then return { error = 'This quote has expired — ask for a new one' } end
    if d.accept then
        MySQL.update.await('UPDATE ops_quotes SET decided_at = ?, decided_by = ? WHERE id = ?', { now(), phone.name, qt.id })
        local jobs = BizAcceptQuote(qt, phone.name)
        return { ok = true, jobs = jobs }
    end
    MySQL.update.await("UPDATE ops_quotes SET status = 'declined', decided_at = ?, decided_by = ? WHERE id = ?", { now(), phone.name, qt.id })
    Ops.notifyId(qt.company_id, 'quotes.manage', { app = 'opswork', title = 'Quote declined', body = ('%s declined %s'):format(cust.name, qt.number or ''), icon = 'fa-file-circle-xmark' })
    return { ok = true }
end)

Register('opsMyTickets', function(_, phone)
    local cust = myCustomer(phone)
    if not cust then return { tickets = {} } end
    local rows = MySQL.query.await([[SELECT t.*, c.name AS company, c.color, c.icon FROM ops_tickets t JOIN ops_companies c ON c.id = t.company_id WHERE t.customer_id = ? ORDER BY t.status = 'closed', t.updated_at DESC LIMIT 30]], { cust.id }) or {}
    for _, r in ipairs(rows) do r.messages = decode(r.messages, {}) end
    return { tickets = rows }
end)

local ticketAt = {}
Register('opsTicketNew', function(src, phone, d)
    if ticketAt[src] and now() - ticketAt[src] < 30 then return { error = 'Please wait a moment' } end
    local c = Ops.company(tostring(d.company or ''))
    if not c then return { error = 'Pick a company' } end
    local subject, text = str(d.subject, 120), str(d.text, 1500)
    if subject == '' then return { error = 'What’s it about?' } end
    local cust = Ops.customerForPlayer(src, phone)
    local msgs = { { from = phone.name, text = text, at = now(), staff = false } }
    local id = MySQL.insert.await('INSERT INTO ops_tickets (company_id, customer_id, subject, status, priority, messages, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { c.id, cust.id, subject, 'open', d.urgent and 'high' or 'normal', json.encode(msgs), 'phone', now(), now() })
    local ref = ('T%s-%05d'):format(c.code:upper():sub(1, 3), id)
    MySQL.update.await('UPDATE ops_tickets SET ref = ? WHERE id = ?', { ref, id })
    ticketAt[src] = now()
    BizAlert('ticket:' .. id, c.id, 'ticket', d.urgent and 'bad' or 'warn', ('New ticket %s'):format(ref), ('%s: %s'):format(cust.name, subject))
    return { ok = true, ref = ref }
end)

Register('opsTicketReply', function(_, phone, d)
    local cust = myCustomer(phone)
    local t = cust and MySQL.single.await('SELECT * FROM ops_tickets WHERE id = ? AND customer_id = ?', { tonumber(d.id) or 0, cust.id })
    if not t then return { error = 'Ticket not found' } end
    local text = str(d.text, 1500)
    if text == '' then return { error = 'Write something' } end
    local msgs = decode(t.messages, {})
    msgs[#msgs + 1] = { from = phone.name, text = text, at = now(), staff = false }
    MySQL.update.await("UPDATE ops_tickets SET messages = ?, status = IF(status = 'closed', 'open', status), updated_at = ? WHERE id = ?", { json.encode(msgs), now(), t.id })
    Ops.notifyId(t.company_id, 'tickets.manage', { app = 'opswork', title = 'Ticket ' .. (t.ref or t.id), body = cust.name .. ': ' .. text:sub(1, 100), icon = 'fa-headset' })
    return { ok = true }
end)

-- the website (OPS Hub) answers tickets and sends quotes straight into the database; tell the customer in game
exports('BizNotifyCustomer', function(customerId, notif)
    local cust = MySQL.single.await('SELECT identifier FROM ops_customers WHERE id = ?', { customerId })
    tellCustomer(cust, notif)
end)
