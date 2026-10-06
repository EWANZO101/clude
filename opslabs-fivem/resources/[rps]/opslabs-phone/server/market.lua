-- OPS market: sub-companies under the main company, wholesale products and leases between companies, retail
-- (who may sell broadband / mobile plans) and network reports routed to every company a problem affects.
-- Shared with OPS Hub (ops_market.py; same tables, sql/ops_market.sql). Rules: sql/ops_catalog.json → market.
--
-- How it works (like Openreach / EE / Vodafone, all fictional):
--   * provider companies (companyRoles: fibre, mobile, data …) publish wholesale products (ops_wholesale)
--   * any company leases them (ops_leases: requested → active → ended); billed here every market.billingDays,
--     per period ('month') or per active customer line ('line'); unpaid → overdue → suspended after graceDays
--   * an active fibre_access lease lets a company sell its own broadband packages (ops_isp_packages.company_id);
--     installs and repairs stay with the network company — an active mobile_access lease lets it sell mobile plans
--     (opslabs_phone_carrier_plans.company_id) and its name shows on the customer's phone
--   * problems (outages, faults on leased / used kit, customer complaints, lease billing) become ops_net_reports
--     for each company affected; the main company sees all of it on OPS Hub → Market → Network overview

local RES = GetCurrentResourceName()
local CAT = (Ops and Ops.catalog) or {}
local function M() return CAT.market or {} end
local function now() return os.time() end
local function money(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local READY = false

Market = {}

---------------------------------------------------------------------------
-- set-up: tables, new columns, the starting wholesale price list
---------------------------------------------------------------------------
local COLUMNS = {
    { 'ops_companies', 'parent_id', 'INT NULL' },
    { 'ops_companies', 'owner_account', 'INT NULL' },
    { 'ops_companies', 'logo', 'VARCHAR(255) NULL' },
    { 'ops_companies', 'provides', 'VARCHAR(255) NULL' },
    { 'ops_companies', 'may_lease', 'VARCHAR(255) NULL' },
    { 'ops_companies', 'approved', 'TINYINT(1) NOT NULL DEFAULT 1' },
    { 'ops_isp_packages', 'company_id', 'INT NULL' },
    { 'ops_isp_services', 'company_id', 'INT NULL' },
    { 'opslabs_phone_carrier_plans', 'company_id', 'INT NULL' },
}

local function seedWholesale()
    for i, w in ipairs(M().wholesale or {}) do
        local p = Ops.company(Ops.role(w.provider or ''))
        if p and w.code and w.kind then
            MySQL.query.await([[INSERT INTO ops_wholesale (provider_id, code, kind, name, description, unit, price, setup_fee, approval, sort)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE code = code]],      -- created once; providers own the prices after that
                { p.id, w.code, w.kind, w.name or w.code, w.description, w.unit == 'line' and 'line' or 'month', money(w.price), money(w.setup), w.approval == false and 0 or 1, i })
        end
    end
end

CreateThread(function()
    AwaitDatabase()
    local sql = LoadResourceFile(RES, 'sql/ops_market.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    for _, c in ipairs(COLUMNS) do
        local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?]], { c[1], c[2] })
        if (tonumber(has) or 0) == 0 then pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(c[1], c[2], c[3])) end
    end
    Wait(3000)                       -- platform.lua seeds the companies first
    pcall(seedWholesale)
    READY = true
end)

---------------------------------------------------------------------------
-- reports: one row per (problem, company); dkey makes them idempotent
---------------------------------------------------------------------------
--- raise or refresh a report for a company. opts: { kind, severity, title, body, source, asset, affected, x, y }
function Market.report(companyId, dkey, opts)
    if not READY or not companyId then return end
    local t = now()
    local row = dkey and MySQL.single.await('SELECT id, status, affected FROM ops_net_reports WHERE dkey = ?', { dkey })
    if row then
        if row.status == 'resolved' then
            MySQL.update.await("UPDATE ops_net_reports SET status = 'open', resolved_at = NULL, ack_at = NULL, ack_by = NULL, created_at = ?, title = ?, body = ?, affected = ? WHERE id = ?",
                { t, Clean(opts.title, 160), opts.body and Clean(opts.body, 600) or nil, opts.affected or 0, row.id })
        elseif (opts.affected or 0) ~= row.affected then
            MySQL.update.await('UPDATE ops_net_reports SET affected = ?, body = COALESCE(?, body) WHERE id = ?', { opts.affected or 0, opts.body and Clean(opts.body, 600) or nil, row.id })
        end
        return row.id
    end
    local id = MySQL.insert.await([[INSERT INTO ops_net_reports (dkey, company_id, kind, severity, title, body, source, asset, affected, x, y, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)]], { dkey, companyId, opts.kind or 'service', opts.severity or 'warn', Clean(opts.title, 160),
        opts.body and Clean(opts.body, 600) or nil, opts.source or 'auto', opts.asset, opts.affected or 0, opts.x, opts.y, t })
    if id then
        MySQL.update.await('UPDATE ops_net_reports SET ref = ? WHERE id = ?', { ('REP-%05d'):format(id), id })
        if opts.severity == 'crit' then
            Ops.notifyId(companyId, 'market.view', { app = 'opswork', title = 'Network report', icon = 'fa-triangle-exclamation', body = Clean(opts.title, 120), data = { page = 'home' } })
        end
    end
    return id
end

function Market.resolve(dkeyLike, keep)
    if not READY then return end
    local rows = MySQL.query.await("SELECT id, dkey FROM ops_net_reports WHERE status <> 'resolved' AND dkey LIKE ?", { dkeyLike }) or {}
    for _, r in ipairs(rows) do
        if not (keep and keep[r.dkey]) then MySQL.update.await("UPDATE ops_net_reports SET status = 'resolved', resolved_at = ? WHERE id = ?", { now(), r.id }) end
    end
end
exports('MarketReport', function(companyCode, dkey, opts)
    local c = Ops.company(companyCode)
    return c and Market.report(c.id, dkey, opts or {}) or nil
end)

---------------------------------------------------------------------------
-- leases and retail rights
---------------------------------------------------------------------------
--- the wholesale kinds a role company sells by itself, without leasing (fibre_access for the ISP, mobile_access for the mobile network)
local OWN = { fibre_access = { 'isp', 'fibre' }, mobile_access = { 'mobile' } }

--- does this company have an active lease of this kind (or is it the role company that owns the network)?
function Market.canSell(companyId, kind)
    if not companyId then return true end             -- NULL = the role company (the original behaviour)
    local c = Ops.byId(companyId)
    if not c or not OpsCompanyOn(c) or tonumber(c.approved or 1) == 0 then return false end
    for _, r in ipairs(OWN[kind] or {}) do if Ops.role(r) == c.code then return true end end
    if not READY then return false end
    return (tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM ops_leases WHERE company_id = ? AND kind = ? AND status = 'active'", { companyId, kind })) or 0) > 0
end
exports('MarketCanSell', function(companyId, kind) return Market.canSell(companyId, kind) end)

--- the company a customer deals with for a retail row (ISP service, carrier plan): its own company_id, or the role company
function Market.retailer(companyId, roleName)
    local c = companyId and Ops.byId(companyId)
    if c then return c end
    return Ops.company(Ops.role(roleName))
end
exports('MarketRetailer', function(companyId, roleName)
    local c = Market.retailer(companyId, roleName)
    return c and { id = c.id, code = c.code, name = c.name, color = c.color, logo = c.logo } or nil
end)

local function activeLines(lease)
    if lease.kind == 'fibre_access' then
        return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM ops_isp_services WHERE company_id = ? AND status IN ('active','suspended')", { lease.company_id })) or 0
    elseif lease.kind == 'mobile_access' then
        return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM opslabs_phone_carrier_lines l JOIN opslabs_phone_carrier_plans p ON p.id = l.plan_id
            WHERE p.company_id = ? AND l.status = 'active']], { lease.company_id })) or 0
    end
    return 1
end

local function billLease(lease, t)
    local lessee, provider = Ops.byId(lease.company_id), Ops.byId(lease.provider_id)
    if not lessee or not provider then return end
    local qty = lease.unit == 'line' and activeLines(lease) or 1
    lessee.balance = MySQL.scalar.await('SELECT balance FROM ops_companies WHERE id = ?', { lessee.id }) or 0
    local amount = money(tonumber(lease.price) * qty)
    local days = tonumber(M().billingDays) or 7
    local label = ('%s · %s%s'):format(lease.ref or 'lease', lease.asset_label or lease.kind, lease.unit == 'line' and (' · %d lines'):format(qty) or '')
    if amount > 0 and tonumber(lessee.balance or 0) < amount then
        if not lease.overdue_since then
            MySQL.update.await('UPDATE ops_leases SET overdue_since = ? WHERE id = ?', { t, lease.id })
            Market.report(lessee.id, 'lease:overdue:' .. lease.id, { kind = 'lease', severity = 'crit', title = ('Lease %s is overdue — $%s due to %s'):format(lease.ref, amount, provider.name),
                body = ('Add money to the company account. After %d days the lease is suspended.'):format(tonumber(M().graceDays) or 3) })
            Market.report(provider.id, 'lease:overdue-p:' .. lease.id, { kind = 'lease', severity = 'warn', title = ('%s has not paid lease %s ($%s)'):format(lessee.name, lease.ref, amount) })
        elseif t - lease.overdue_since > (tonumber(M().graceDays) or 3) * 86400 and lease.status == 'active' then
            MySQL.update.await("UPDATE ops_leases SET status = 'suspended' WHERE id = ?", { lease.id })
            Market.report(lessee.id, 'lease:suspended:' .. lease.id, { kind = 'lease', severity = 'crit', title = ('Lease %s is suspended for non-payment'):format(lease.ref),
                body = 'You cannot take new customers on it until it is paid. Existing customers keep their service.' })
            Ops.audit('market', lessee.id, 'lease.suspend', lease.ref, 'unpaid')
        end
        return
    end
    if amount > 0 then
        OpsCompanyMove(lessee.id, 'expense', -amount, 'Wholesale · ' .. label, 'lease', lease.id, provider.name, 'billing')
        OpsCompanyMove(provider.id, 'income', amount, 'Wholesale · ' .. lessee.name .. ' · ' .. label, 'lease', lease.id, lessee.name, 'billing')
    end
    MySQL.update.await("UPDATE ops_leases SET next_bill_at = ?, overdue_since = NULL, status = IF(status = 'suspended', 'active', status) WHERE id = ?",
        { math.max(t, tonumber(lease.next_bill_at) or t) + days * 86400, lease.id })
    if lease.overdue_since then Market.resolve('lease:%:' .. lease.id) end
end

local function leaseBilling()
    local t = now()
    for _, l in ipairs(MySQL.query.await("SELECT * FROM ops_leases WHERE status IN ('active','suspended') AND next_bill_at IS NOT NULL AND (next_bill_at <= ? OR overdue_since IS NOT NULL)", { t }) or {}) do
        local ok, err = pcall(billLease, l, t)
        if not ok then print('[opslabs-phone] market billing: ' .. tostring(err)) end
    end
    -- leases approved on OPS Hub start here: setup fee + first period
    for _, l in ipairs(MySQL.query.await("SELECT * FROM ops_leases WHERE status = 'active' AND next_bill_at IS NULL") or {}) do
        local lessee, provider = Ops.byId(l.company_id), Ops.byId(l.provider_id)
        local bal = tonumber(MySQL.scalar.await('SELECT balance FROM ops_companies WHERE id = ?', { l.company_id })) or 0
        if lessee and provider and tonumber(l.setup_fee) > 0 and bal < tonumber(l.setup_fee) then
            -- not started until the set-up fee can be paid (checked every minute)
            Market.report(lessee.id, 'lease:setup:' .. l.id, { kind = 'lease', severity = 'warn', title = ('Lease %s is waiting for its $%s set-up fee'):format(l.ref or '', tonumber(l.setup_fee)),
                body = 'Add money to the company account — the lease starts as soon as it can be paid.' })
            goto continue
        end
        Market.resolve('lease:setup:' .. l.id)
        if lessee and provider and tonumber(l.setup_fee) > 0 then
            OpsCompanyMove(lessee.id, 'expense', -tonumber(l.setup_fee), 'Wholesale set-up · ' .. (l.ref or ''), 'lease', l.id, provider.name, 'billing')
            OpsCompanyMove(provider.id, 'income', tonumber(l.setup_fee), 'Wholesale set-up · ' .. lessee.name .. ' · ' .. (l.ref or ''), 'lease', l.id, lessee.name, 'billing')
        end
        MySQL.update.await('UPDATE ops_leases SET started_at = COALESCE(started_at, ?), next_bill_at = ? WHERE id = ?', { t, t, l.id })
        l.next_bill_at = t
        pcall(billLease, l, t)
        ::continue::
    end
end

---------------------------------------------------------------------------
-- network reports: route each problem to every company it touches
---------------------------------------------------------------------------
local function svcCompanies(ids)
    local by = {}
    if #ids == 0 then return by end
    local marks = {}
    for i = 1, #ids do marks[i] = '?' end
    for _, s in ipairs(MySQL.query.await(('SELECT id, company_id FROM ops_isp_services WHERE id IN (%s)'):format(table.concat(marks, ',')), ids) or {}) do
        local c = Market.retailer(s.company_id, 'isp')
        if c then by[c.id] = (by[c.id] or 0) + 1 end
    end
    return by
end

local function routeOutages(keep)
    local fibre = Ops.company(Ops.role('fibre'))
    for _, o in ipairs(MySQL.query.await("SELECT * FROM ops_isp_outages WHERE status <> 'resolved'") or {}) do
        local ids = {}
        for _, v in ipairs(decode(o.services, {})) do ids[#ids + 1] = tonumber(v) end
        local base = { kind = 'outage', severity = 'crit', asset = o.ref, x = o.x, y = o.y, source = 'auto' }
        for coId, n in pairs(svcCompanies(ids)) do
            local key = ('outage:%d:%d'):format(o.id, coId)
            keep[key] = true
            Market.report(coId, key, { kind = base.kind, severity = base.severity, asset = base.asset, x = base.x, y = base.y, affected = n,
                title = ('%s · %d of your customers have no internet'):format(o.title, n), body = (o.cause or 'Under investigation') .. ' — the network company is sending engineers.' })
        end
        if fibre then
            local key = ('outage:%d:%d'):format(o.id, fibre.id)
            keep[key] = true
            Market.report(fibre.id, key, { kind = 'outage', severity = 'crit', asset = o.ref, x = o.x, y = o.y, affected = tonumber(o.affected) or #ids,
                title = ('%s · %d lines down'):format(o.title, tonumber(o.affected) or #ids), body = o.cause })
        end
    end
end

local function routeFaults(keep)
    local mobile = Ops.company(Ops.role('mobile'))
    local mvnos = MySQL.query.await("SELECT DISTINCT company_id FROM ops_leases WHERE kind = 'mobile_access' AND status IN ('active','suspended')") or {}
    for _, f in ipairs(MySQL.query.await("SELECT id, type, asset, data FROM opslabs_towers_faults WHERE status <> 'fixed'") or {}) do
        local d = decode(f.data, {})
        local label = (d.label or f.type) .. ' · ' .. (d.location or f.asset)
        local sev = (d.severity == 'critical' or d.severity == 'high') and 'crit' or 'warn'
        local base = { kind = 'damage', severity = sev, asset = f.asset, x = d.x, y = d.y }
        local towerId = tostring(f.asset or ''):match('^t:(%d+)$')
        local function send(coId, title, n)
            local key = ('fault:%d:%d'):format(f.id, coId)
            keep[key] = true
            Market.report(coId, key, { kind = base.kind, severity = base.severity, asset = base.asset, x = base.x, y = base.y, affected = n or 0, title = title, body = d.diagnosis })
        end
        if towerId then
            -- a mast: the mobile network, everyone selling mobile on it, and whoever leases that site
            if mobile then send(mobile.id, 'Mast fault · ' .. label) end
            for _, m in ipairs(mvnos) do send(m.company_id, 'Mobile network fault · ' .. label .. ' — your customers near it may lose signal') end
            for _, l in ipairs(MySQL.query.await("SELECT company_id FROM ops_leases WHERE kind = 'tower' AND asset = ? AND status IN ('active','suspended')", { towerId }) or {}) do
                send(l.company_id, 'Fault on your leased mast · ' .. label)
            end
        else
            -- fibre plant: the companies whose customers lost service
            local onts = {}
            for _, a in ipairs(d.affected or {}) do if a.ont_id then onts[#onts + 1] = tonumber(a.ont_id) end end
            if #onts > 0 then
                local marks = {}
                for i = 1, #onts do marks[i] = '?' end
                local by = {}
                for _, s in ipairs(MySQL.query.await(('SELECT company_id FROM ops_isp_services WHERE status <> \'cancelled\' AND ont_id IN (%s)'):format(table.concat(marks, ',')), onts) or {}) do
                    local c = Market.retailer(s.company_id, 'isp')
                    if c then by[c.id] = (by[c.id] or 0) + 1 end
                end
                for coId, n in pairs(by) do send(coId, ('Network damage · %s · %d of your customers affected'):format(label, n), n) end
            end
        end
    end
end

local function routeComplaints(keep)
    -- broadband fault tickets from customers of a sub-company's lines: the retailer handles the customer
    for _, t in ipairs(MySQL.query.await([[SELECT t.id, t.ref, t.subject, t.kind, t.priority, s.company_id, s.ref AS line FROM ops_isp_tickets t
        JOIN ops_isp_services s ON s.id = t.service_id WHERE t.status <> 'closed' AND s.company_id IS NOT NULL]]) or {}) do
        local key = ('ispticket:%d'):format(t.id)
        keep[key] = true
        Market.report(t.company_id, key, { kind = t.kind == 'fault' and 'service' or 'complaint', severity = t.priority == 'urgent' and 'crit' or 'warn', asset = t.line, source = 'customer',
            title = ('%s · %s (%s)'):format(t.ref or 'Ticket', t.subject, t.line or '') })
    end
end

local function routeReports()
    local keep = {}
    routeOutages(keep)
    pcall(routeFaults, keep)
    routeComplaints(keep)
    Market.resolve('outage:%', keep)
    Market.resolve('fault:%', keep)
    Market.resolve('ispticket:%', keep)
end

CreateThread(function()
    while not READY do Wait(1000) end
    Wait(30000)
    local lastBill = 0
    while true do
        local ok, err = pcall(routeReports)
        if not ok then print('[opslabs-phone] market reports: ' .. tostring(err)) end
        if now() - lastBill >= 60 then
            lastBill = now()
            ok, err = pcall(leaseBilling)
            if not ok then print('[opslabs-phone] market billing: ' .. tostring(err)) end
        end
        Wait(30000)
    end
end)
