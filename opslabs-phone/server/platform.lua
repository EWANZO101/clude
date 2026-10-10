-- OPS platform: the companies (OPS Network, OPS Fibre, OPS Secure, OPS Communications, OPS Systems, OPS Domains,
-- OPS Web, OPS Data, OPS Cloud, OPS Mobile, OPS Track, OPS Fuel, SAPL, SA Solar), their people, roles, money,
-- customers and jobs. Shared with OPS Hub (same MySQL tables, same accounts as Ops-Networks).
--
-- A job's life: open → assigned (accepted; a snapshot of the world is taken) → the engineer does the real work →
-- complete: the work is checked against the game world (opslabs-towers OpsVerify: kit fitted, cable laid, ONT
-- online, dial tone, live supply… or time spent on site) → the customer pays (bank / society / account) → the
-- company is credited → the engineer is paid wages from the company → an invoice is issued → everyone is notified.

local RES = GetCurrentResourceName()
local TOWERS = 'opslabs-towers'
local CAT = json.decode(LoadResourceFile(RES, 'sql/ops_catalog.json') or '{}') or {}
local PC = Config.Platform or {}

local PERM_IDS, PERM_SET = {}, {}
for _, p in ipairs(CAT.perms or {}) do PERM_IDS[#PERM_IDS + 1] = p.id PERM_SET[p.id] = true end
local TYPES = {}
for _, t in ipairs(CAT.jobTypes or {}) do TYPES[t.code] = t end
-- job types edited on OPS Hub (Jobs editor) / OPS Work admin: ops_job_overrides(code, data JSON). New codes = custom job types.
local ORIG = {}
local OVERRIDABLE = { 'enabled', 'title', 'desc', 'price', 'wage', 'auto', 'emergency', 'cert', 'certRequired', 'parts', 'for', 'verify', 'warranty' }
local function loadJobOverrides()
    local ok, rows = pcall(MySQL.query.await, 'SELECT code, data FROM ops_job_overrides')
    if not ok then return end
    local seen = {}
    for _, r in ipairs(rows or {}) do
        local okj, d = pcall(json.decode, r.data)
        if okj and type(d) == 'table' then
            seen[r.code] = true
            local t = TYPES[r.code]
            if not t and d.company and d.title then
                t = { code = r.code, company = d.company, title = d.title, custom = true, verify = { kind = 'onsite', secs = 45, radius = 30 } }
                TYPES[r.code] = t
                CAT.jobTypes[#CAT.jobTypes + 1] = t
            end
            if t then
                if not ORIG[r.code] then ORIG[r.code] = {} for _, f in ipairs(OVERRIDABLE) do ORIG[r.code][f] = t[f] end end
                for _, f in ipairs(OVERRIDABLE) do if d[f] ~= nil then t[f] = d[f] end end
            end
        end
    end
    for code, orig in pairs(ORIG) do
        if not seen[code] then for _, f in ipairs(OVERRIDABLE) do TYPES[code][f] = orig[f] end ORIG[code] = nil end
    end
end
--- catalog sections edited on OPS Hub (ops_settings "catalog:<section>"): merged into sql/ops_catalog.json on start.
--- The catalog is read when scripts load, so these apply from the next restart (OPS Hub says so).
local function syncCatalogFile()
    local ok, rows = pcall(MySQL.query.await, "SELECT path, value, updated_at FROM ops_settings WHERE path LIKE 'catalog:%' ORDER BY path")
    if not ok then return end
    local stamp = {}
    for _, r in ipairs(rows or {}) do stamp[#stamp + 1] = r.path .. '@' .. tostring(r.updated_at) end
    stamp = table.concat(stamp, ';')
    if (LoadResourceFile(RES, 'sql/ops_catalog.applied') or '') == stamp then return end
    local base = LoadResourceFile(RES, 'sql/ops_catalog.default.json')
    if not base then
        if #rows == 0 then return end
        base = LoadResourceFile(RES, 'sql/ops_catalog.json')
        SaveResourceFile(RES, 'sql/ops_catalog.default.json', base, -1)
    end
    local merged = json.decode(base)
    for _, r in ipairs(rows or {}) do
        local key = r.path:sub(9)
        local okj, v = pcall(json.decode, r.value)
        if okj and key ~= 'jobTypes' and key ~= 'perms' and merged[key] ~= nil then merged[key] = v end
    end
    SaveResourceFile(RES, 'sql/ops_catalog.json', json.encode(merged, { indent = true }), -1)
    SaveResourceFile(RES, 'sql/ops_catalog.applied', stamp, -1)
    print('^3[opslabs-phone] catalog changes from OPS Hub written to sql/ops_catalog.json — restart opslabs-phone and opslabs-towers to use them^7')
end

local function typeOn(t) return t ~= nil and t.enabled ~= false end
local function coOn(c) return c ~= nil and (c.active == nil or IsTrue(c.active)) end
OpsTypeOn, OpsCompanyOn = typeOn, coOn
local CO = {}                 -- code -> company row (cached)
local CO_BY_ID = {}

local function now() return os.time() end
local function money(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end
local function towersUp() return GetResourceState(TOWERS) == 'started' end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end

local function audit(actor, coId, action, target, detail)
    MySQL.insert('INSERT INTO ops_audit (at, actor, company_id, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)',
        { now(), actor and tostring(actor):sub(1, 60), coId, action, target and tostring(target):sub(1, 80), detail and tostring(detail):sub(1, 400) })
end

---------------------------------------------------------------------------
-- set-up: tables, companies, roles, customers from the catalogue
---------------------------------------------------------------------------
local function loadCompanies()
    CO, CO_BY_ID = {}, {}
    for _, c in ipairs(MySQL.query.await('SELECT * FROM ops_companies') or {}) do CO[c.code] = c CO_BY_ID[c.id] = c end
end

CreateThread(function()
    AwaitDatabase()
    local sql = LoadResourceFile(RES, 'sql/ops_platform.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    -- jobs created on OPS Hub get announced in game once
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ops_jobs' AND COLUMN_NAME = 'announced']])
    if (tonumber(has) or 0) == 0 then MySQL.query.await('ALTER TABLE ops_jobs ADD COLUMN announced TINYINT(1) NOT NULL DEFAULT 0') end
    for _, c in ipairs(CAT.companies or {}) do
        MySQL.query.await([[INSERT INTO ops_companies (code, name, tagline, color, icon, kind, balance, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE code = code]],                 -- created once; after that OPS Hub owns the details
            { c.code, c.name, c.tagline, c.color, c.icon, c.kind, PC.StartingBalance or 25000, now() })
    end
    for _, r in ipairs(CAT.roles or {}) do
        local perms = r.all and {} or r.perms
        if r.all then for _, p in ipairs(PERM_IDS) do if not p:find('^admin%.') then perms[#perms + 1] = p end end end
        MySQL.query.await([[INSERT INTO ops_roles (code, name, rank_no, perms, builtin, description) VALUES (?, ?, ?, ?, 1, ?)
            ON DUPLICATE KEY UPDATE name = VALUES(name), rank_no = VALUES(rank_no), perms = IF(builtin = 1, VALUES(perms), perms), description = VALUES(description)]],
            { r.code, r.name, r.rank or 10, json.encode(perms), r.description })
    end
    -- OPS Hub seeds the same rows: wait (up to ~10s) while it holds its seed lock. No GET_LOCK here — oxmysql's pool would
    -- release it on a different connection, leaving the lock held for good and stalling the Hub's first page.
    for _ = 1, 20 do if not MySQL.scalar.await("SELECT IS_USED_LOCK('ops_seed')") then break end Wait(500) end
    for _, p in ipairs(CAT.places or {}) do
        if not MySQL.scalar.await('SELECT id FROM ops_customers WHERE name = ? AND identifier IS NULL AND ABS(x - ?) < 3 AND ABS(y - ?) < 3', { p.name, p.x, p.y }) then
            local id = MySQL.insert.await([[INSERT INTO ops_customers (account_no, kind, name, society, address, x, y, z, sla, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
                { ('T%06d'):format(math.random(0, 999999)), p.kind, p.name, p.society, p.address or p.name, p.x, p.y, p.z, (p.kind == 'police' or p.kind == 'government') and 'critical' or p.kind == 'business' and 'business' or 'standard', now() })
            MySQL.update.await('UPDATE ops_customers SET account_no = ? WHERE id = ?', { ('C%06d'):format(id), id })
        end
    end
    loadCompanies()
    pcall(MySQL.query.await, 'CREATE TABLE IF NOT EXISTS ops_job_overrides (code VARCHAR(40) NOT NULL PRIMARY KEY, data LONGTEXT NOT NULL, updated_by VARCHAR(60) NULL, updated_at INT NOT NULL DEFAULT 0)')
    loadJobOverrides()
    pcall(syncCatalogFile)
    print(('^2[opslabs-phone]^7 OPS platform: %d companies, %d job types'):format(#(CAT.companies or {}), #(CAT.jobTypes or {})))
    while true do Wait(30000) pcall(loadJobOverrides) pcall(loadCompanies) end
end)

---------------------------------------------------------------------------
-- who you are, what you can do
---------------------------------------------------------------------------
local function account(src) return OpsnetUser and OpsnetUser(src) or nil end
local function isSuper(a) return a and a.role == 'admin' end
local function nameOf(a) return a and ((a.display_name and a.display_name ~= '') and a.display_name or a.username) or '?' end

local function memberships(aid)
    local rows = MySQL.query.await([[SELECT m.*, r.code AS role_code, r.name AS role_name, r.perms AS role_perms, r.rank_no
        FROM ops_members m LEFT JOIN ops_roles r ON r.id = m.role_id WHERE m.account_id = ?]], { aid }) or {}
    local out = {}
    for _, m in ipairs(rows) do out[m.company_id] = m end
    return out
end

--- permission set of an account in one company
local function permsIn(a, coId, mem)
    local set = {}
    if not a then return set end
    if isSuper(a) then for _, p in ipairs(PERM_IDS) do set[p] = true end return set end
    mem = mem or memberships(a.id)
    local m = mem[coId]
    if m and m.status == 'active' then for _, p in ipairs(decode(m.role_perms, {})) do set[p] = true end end
    return set
end
local function can(a, coId, perm, mem) return permsIn(a, coId, mem)[perm] == true end

local function companyView(c, perms)
    local v = { id = c.id, code = c.code, name = c.name, tagline = c.tagline, color = c.color, icon = c.icon, kind = c.kind }
    if perms and perms['finance.view'] then v.balance = money(c.balance) end
    return v
end

local function meView(a)
    loadCompanies()
    local mem = memberships(a.id)
    local mine, others = {}, {}
    for _, c in pairs(CO_BY_ID) do
      if coOn(c) or isSuper(a) then
        local m = mem[c.id]
        local perms = permsIn(a, c.id, mem)
        if (m and m.status == 'active') or isSuper(a) then
            local list = {}
            for p in pairs(perms) do list[#list + 1] = p end
            local v = companyView(c, perms)
            v.role = isSuper(a) and (m and m.role_name or 'Super Admin') or m.role_name or 'Member'
            v.perms = list
            mine[#mine + 1] = v
        else
            local v = companyView(c)
            v.applied = m and m.status == 'applied' or false
            others[#others + 1] = v
        end
      end
    end
    table.sort(mine, function(x, y) return x.name < y.name end)
    table.sort(others, function(x, y) return x.name < y.name end)
    return { id = a.id, username = a.username, name = nameOf(a), super = isSuper(a), companies = mine, others = others,
        defaultPassword = IsTrue(a.default_pw) }
end

---------------------------------------------------------------------------
-- money
---------------------------------------------------------------------------
local function companyMove(coId, kind, amount, memo, refType, refId, counterparty, actor)
    amount = money(amount)
    if amount == 0 then return end
    MySQL.update.await('UPDATE ops_companies SET balance = balance + ? WHERE id = ?', { amount, coId })
    local bal = MySQL.scalar.await('SELECT balance FROM ops_companies WHERE id = ?', { coId }) or 0
    MySQL.insert.await([[INSERT INTO ops_transactions (company_id, kind, amount, balance_after, ref_type, ref_id, counterparty, memo, actor, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { coId, kind, amount, bal, refType, refId, counterparty and tostring(counterparty):sub(1, 80), memo and tostring(memo):sub(1, 200), actor, now() })
    if CO_BY_ID[coId] then CO_BY_ID[coId].balance = bal end
    return bal
end
OpsCompanyMove = companyMove

local function society(name, amount) return FW.RemoveSocietyMoney(name, amount) end

local function invoiceNumber(c, id) return ('%s-%06d'):format(c.code:upper():sub(1, 3), id) end

local function issueInvoice(c, cust, job, total, status)
    local vat = tonumber(c.vat_pct) or 20
    local sub = money(total / (1 + vat / 100))
    local items = { { description = job.title .. (job.ref and (' · ' .. job.ref) or ''), qty = 1, unit = sub, total = sub } }
    local id = MySQL.insert.await([[INSERT INTO ops_invoices (number, company_id, customer_id, customer_name, job_id, kind, items, subtotal, tax, total, status, issued_at, paid_at)
        VALUES (?, ?, ?, ?, ?, 'invoice', ?, ?, ?, ?, ?, ?, ?)]], { 'TMP' .. math.random(1, 1e9), c.id, cust and cust.id, cust and cust.name, job.id,
        json.encode(items), sub, money(total - sub), money(total), status, now(), status == 'paid' and now() or nil })
    local number = invoiceNumber(c, id)
    MySQL.update.await('UPDATE ops_invoices SET number = ? WHERE id = ?', { number, id })
    return id, number
end

---------------------------------------------------------------------------
-- customers
---------------------------------------------------------------------------
local function customerForPlayer(src, phone)
    local c = MySQL.single.await('SELECT * FROM ops_customers WHERE identifier = ? LIMIT 1', { phone.identifier })
    if c then return c end
    local id = MySQL.insert.await('INSERT INTO ops_customers (account_no, kind, name, identifier, phone, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        { 'TMP' .. math.random(1, 1e9), 'residential', Clean(phone.name, 80), phone.identifier, phone.number, now() })
    MySQL.update.await('UPDATE ops_customers SET account_no = ? WHERE id = ?', { ('C%06d'):format(id), id })
    return MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { id })
end

---------------------------------------------------------------------------
-- jobs
---------------------------------------------------------------------------
local function jobView(j, a, mem)
    local c = CO_BY_ID[j.company_id] or {}
    local t = TYPES[j.type] or {}
    local v = decode(j.verify, {})
    return { id = j.id, ref = j.ref, company = c.code, companyName = c.name, color = c.color, type = j.type, title = j.title, description = j.description,
        priority = j.priority, emergency = IsTrue(j.emergency), status = j.status, location = j.location, x = j.x, y = j.y, z = j.z,
        price = money(j.price), wage = money(j.wage), assigned = j.assigned_name, mine = a and j.assigned_to == a.id or false,
        created_at = j.created_at, accepted_at = j.accepted_at, completed_at = j.completed_at, appointment_at = j.appointment_at,
        check = v.kind, action = v.action, secs = v.secs, result = j.result,
        customer = j.customer_name, customerKind = j.customer_kind, customerAddress = j.customer_address, customerPhone = j.customer_phone, sla = j.customer_sla,
        icon = c.icon, label = t.title, due = j.due_at, cert = t.cert, certName = t.cert and BizCertName and BizCertName(t.cert) or nil }
end

local JOB_SELECT = [[SELECT j.*, cu.name AS customer_name, cu.kind AS customer_kind, cu.address AS customer_address, cu.phone AS customer_phone, cu.sla AS customer_sla
    FROM ops_jobs j LEFT JOIN ops_customers cu ON cu.id = j.customer_id ]]

local function notifyCompany(coId, perm, notif, except)
    for src in pairs(Phones or {}) do
        if src ~= except then
            local a = account(src)
            if a and can(a, coId, perm) then Notify(src, notif) end
        end
    end
end

local function createJob(c, t, place, opts)
    opts = opts or {}
    if not typeOn(t) or not coOn(c) then return nil end
    local v = opts.verify or t.verify or { kind = 'onsite', secs = 40, radius = 30 }
    local emergency = opts.emergency or (t.emergency and math.random() < 0.6) or false
    local price = opts.price or t.price or 0
    if emergency and price > 0 then price = math.floor(price * 1.5) end
    local id = MySQL.insert.await([[INSERT INTO ops_jobs (ref, company_id, type, title, description, priority, emergency, status, customer_id, location, x, y, z,
        price, wage, verify, created_by, created_at, appointment_at, announced) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)]],
        { 'TMP', c.id, t.code, opts.title or t.title, opts.description or t.desc, emergency and 'urgent' or (opts.priority or 'normal'), emergency and 1 or 0,
          place and place.customer_id, place and (place.address or place.name), place and place.x, place and place.y, place and place.z,
          price, math.floor((t.wage or 200) * (emergency and 1.5 or 1)), json.encode(v), opts.by or 'system', now(), opts.appointment })
    local ref = ('%s-%05d'):format(c.code:upper():sub(1, 3), id)
    MySQL.update.await('UPDATE ops_jobs SET ref = ? WHERE id = ?', { ref, id })
    if BizOnJobCreated then pcall(BizOnJobCreated, id, c, place and place.customer_id, emergency) end     -- SLA due time (server/business.lua)
    notifyCompany(c.id, 'jobs.view', { app = 'opswork', title = (emergency and '🚨 Emergency · ' or '') .. c.name,
        body = ('%s · %s'):format(opts.title or t.title, place and (place.address or place.name) or 'see job'), icon = emergency and 'fa-triangle-exclamation' or 'fa-briefcase',
        data = { page = 'job', id = id } })
    return id, ref
end
OpsCreateJob = createJob

local function getJob(id) return MySQL.single.await(JOB_SELECT .. 'WHERE j.id = ?', { tonumber(id) }) end

local function playerPos(src) local p = GetEntityCoords(GetPlayerPed(src)) return p end
local function within(src, j, r)
    if not j.x then return true end
    local p = playerPos(src)
    return math.sqrt((p.x - j.x) ^ 2 + (p.y - j.y) ^ 2) <= (r or 40), math.floor(math.sqrt((p.x - j.x) ^ 2 + (p.y - j.y) ^ 2))
end

--- run the job's check; returns { ok, label, have, need, detail }
local function verify(j, src, a)
    local v = decode(j.verify, {})
    local prog = decode(j.progress, {})
    if v.kind == 'onsite' then
        local here, d = within(src, j, v.radius or 30)
        if not prog.workStart then return { ok = false, label = 'Do the work on site', have = 0, need = v.secs or 40, detail = here and 'You are on site — start the work' or ('You are %d m away'):format(d or 0) } end
        local done = now() - prog.workStart
        if not here then return { ok = false, label = 'Stay on site while you work', have = done, need = v.secs or 40 } end
        return { ok = done >= (v.secs or 40), label = 'Time on the job', have = math.min(done, v.secs or 40), need = v.secs or 40 }
    end
    if v.kind and v.kind:find('^web_') then          -- OPS Web / OPS Domains work is checked against the domain registry (server/web.lua)
        if not WebVerify then return { ok = false, label = 'Web systems are offline', have = 0, need = 1 } end
        return WebVerify(v, j)
    end
    if not towersUp() then return { ok = false, label = 'The network systems are offline', have = 0, need = 1 } end
    local ok, res = pcall(function() return exports[TOWERS]:OpsVerify(v, j.x, j.y, j.z, prog.snap or {}, GetPlayerName(src)) end)
    if not ok then return { ok = false, label = 'Check failed', have = 0, need = 1, detail = tostring(res) } end
    return res
end

local function settle(j, src, a, phone)
    local c = CO_BY_ID[j.company_id]
    local cust = j.customer_id and MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { j.customer_id }) or nil
    local price, wage = money(j.price), money(j.wage)
    local paid, how = false, nil
    local covered
    if BizCoverage and price > 0 then covered = BizCoverage(j, c, cust) if covered then price = 0 end end      -- warranty / contract
    if price > 0 then
        if cust and cust.identifier then
            local cs = GetSourceByIdentifier(cust.identifier)
            if cs and (FW.RemoveMoney(cs, price, 'bank', c.name) or FW.RemoveMoney(cs, price, 'cash', c.name)) then paid, how = true, 'card' end
        elseif cust and cust.society then
            paid = society(cust.society, price)
            how = paid and 'account' or nil
        elseif cust then paid, how = true, 'account' end               -- businesses settle on account
    else paid = true end
    local invId, invNo
    if price > 0 then
        invId, invNo = issueInvoice(c, cust, j, price, paid and 'paid' or 'unpaid')
        if paid then companyMove(c.id, 'income', price, j.title .. ' · ' .. j.ref, 'invoice', invId, cust and cust.name, nameOf(a)) end
    end
    -- the engineer's wages, from the company account
    if wage > 0 then
        companyMove(c.id, 'wage', -wage, ('Wages · %s · %s'):format(nameOf(a), j.ref), 'job', j.id, nameOf(a), 'payroll')
        FW.AddMoney(src, wage, 'bank', c.name .. ' wages')
        MySQL.insert.await('INSERT INTO ops_wages (account_id, identifier, company_id, job_id, amount, label, status, at, paid_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { a.id, phone.identifier, c.id, j.id, wage, j.title .. ' · ' .. j.ref, 'paid', now(), now() })
        MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { phone.identifier, Clean(c.name .. ': ' .. j.title, 120), wage })
    end
    MySQL.update.await("UPDATE ops_jobs SET status = 'completed', completed_at = ?, invoice_id = ?, result = ? WHERE id = ?",
        { now(), invId, covered or (paid and 'Paid' or (price > 0 and 'Invoice outstanding' or 'No charge')), j.id })
    if BizOnCompleted then pcall(BizOnCompleted, j, c, cust, a, src) end            -- parts from stock, installed assets, SLA
    audit(nameOf(a), c.id, 'job.complete', j.ref, ('price %.2f %s · wage %.2f'):format(price, paid and 'paid' or 'unpaid', wage))
    TriggerEvent('ops:jobCompleted', j.id, j.type, j.x, j.y, j.z, nameOf(a))
    Notify(src, { app = 'opswork', title = c.name, icon = 'fa-sack-dollar', body = ('Job %s done · $%s wages paid'):format(j.ref, wage), data = { page = 'earnings' } })
    if cust and cust.identifier then
        local cs = GetSourceByIdentifier(cust.identifier)
        if cs then
            Notify(cs, { app = 'opswork', title = c.name, icon = 'fa-file-invoice-dollar',
                body = price > 0 and ('%s complete · invoice %s $%s %s'):format(j.title, invNo, price, paid and 'paid' or 'due') or (j.title .. ' complete') , data = { page = 'invoices' } })
        end
    end
    return { ok = true, paid = paid, invoice = invNo, wage = wage, price = price }
end

---------------------------------------------------------------------------
-- automatic work: customers keep needing things
---------------------------------------------------------------------------
local function placesFor(kinds)
    local set = {}
    for _, k in ipairs(kinds or { 'business' }) do set[k] = true end
    local list = {}
    for _, c in ipairs(MySQL.query.await('SELECT id, name, kind, address, x, y, z FROM ops_customers WHERE identifier IS NULL AND x IS NOT NULL') or {}) do
        if set[c.kind] then list[#list + 1] = { customer_id = c.id, name = c.name, address = c.address or c.name, x = c.x, y = c.y, z = c.z } end
    end
    return list
end

CreateThread(function()
    Wait(30000)
    while true do
        if PC.AutoJobs ~= false then
            loadCompanies()
            for code, c in pairs(CO) do
                local types = {}
                for _, t in ipairs(CAT.jobTypes or {}) do if t.company == code and t.auto ~= false and typeOn(t) and coOn(c) then types[#types + 1] = t end end
                if #types > 0 then
                    local open = MySQL.scalar.await("SELECT COUNT(*) FROM ops_jobs WHERE company_id = ? AND status = 'open'", { c.id }) or 0
                    if open < (PC.OpenJobsPerCompany or 4) then
                        local t = types[math.random(#types)]
                        local places = placesFor(t['for'])
                        if #places > 0 then createJob(c, t, places[math.random(#places)]) end
                    end
                end
            end
        end
        -- announce jobs that were made on OPS Hub
        for _, j in ipairs(MySQL.query.await('SELECT * FROM ops_jobs WHERE announced = 0 LIMIT 20') or {}) do
            MySQL.update.await('UPDATE ops_jobs SET announced = 1 WHERE id = ?', { j.id })
            notifyCompany(j.company_id, 'jobs.view', { app = 'opswork', title = (CO_BY_ID[j.company_id] or {}).name or 'OPS',
                body = ('New job: %s · %s'):format(j.title, j.location or ''), icon = 'fa-briefcase', data = { page = 'job', id = j.id } })
            if j.assigned_to then
                for src in pairs(Phones or {}) do
                    local a = account(src)
                    if a and a.id == j.assigned_to then Notify(src, { app = 'opswork', title = 'Job assigned to you', body = j.title .. ' · ' .. (j.location or ''), icon = 'fa-user-check', data = { page = 'job', id = j.id } }) end
                end
            end
        end
        Wait((PC.JobEvery or 240) * 1000)
    end
end)

---------------------------------------------------------------------------
-- phone RPCs
---------------------------------------------------------------------------
local function On(name, handler)
    Register(name, function(src, phone, data)
        local a = account(src)
        if not a then return { loggedOut = true } end
        return handler(src, phone, data, a)
    end)
end

On('opsMe', function(_, _, _, a) return { me = meView(a) } end)

On('opsJobs', function(_, _, d, a)
    loadCompanies()
    local mem = memberships(a.id)
    local c = d.company and CO[d.company]
    local rows
    if d.filter == 'mine' then
        rows = MySQL.query.await(JOB_SELECT .. "WHERE j.assigned_to = ? AND j.status IN ('open','assigned','in_progress') ORDER BY j.emergency DESC, j.id", { a.id })
    elseif d.filter == 'done' then
        rows = MySQL.query.await(JOB_SELECT .. "WHERE j.assigned_to = ? AND j.status = 'completed' ORDER BY j.completed_at DESC LIMIT 40", { a.id })
    else
        if not c then return { error = 'Pick a company' } end
        if not can(a, c.id, 'jobs.view', mem) then return { denied = true, error = 'You can’t see this company’s jobs' } end
        local st = d.filter == 'all' and "j.status IN ('open','assigned','in_progress')" or "j.status = 'open'"
        rows = MySQL.query.await(JOB_SELECT .. 'WHERE j.company_id = ? AND ' .. st .. ' ORDER BY j.emergency DESC, j.id DESC LIMIT 60', { c.id })
    end
    local out = {}
    for _, j in ipairs(rows or {}) do out[#out + 1] = jobView(j, a, mem) end
    return { jobs = out }
end)

On('opsJob', function(src, _, d, a)
    local j = getJob(d.id)
    if not j then return { error = 'Job not found' } end
    if not can(a, j.company_id, 'jobs.view') and j.assigned_to ~= a.id then return { denied = true } end
    local v = jobView(j, a)
    if j.assigned_to == a.id and (j.status == 'assigned' or j.status == 'in_progress') then v.check = verify(j, src, a) v.checkKind = decode(j.verify, {}).kind end
    v.canTake = j.status == 'open' and can(a, j.company_id, 'jobs.take')
    v.canDispatch = can(a, j.company_id, 'jobs.dispatch')
    return { job = v }
end)

On('opsAccept', function(src, _, d, a)
    local j = getJob(d.id)
    if not j or j.status ~= 'open' then return { error = 'Someone else has taken that job' } end
    if j.assigned_to and j.assigned_to ~= a.id then return { error = ('This job is reserved for %s'):format(j.assigned_name or 'someone else') } end
    if not can(a, j.company_id, 'jobs.take') then return { denied = true, error = 'You can’t take jobs for this company' } end
    if not coOn(CO_BY_ID[j.company_id]) or not typeOn(TYPES[j.type]) then return { error = 'This kind of work is switched off right now' } end
    local active = MySQL.scalar.await("SELECT COUNT(*) FROM ops_jobs WHERE assigned_to = ? AND status IN ('assigned','in_progress')", { a.id }) or 0
    if active >= (PC.MaxActiveJobs or 3) then return { error = ('You already have %d jobs on — finish one first'):format(active) } end
    if BizCertBlock then
        local why = BizCertBlock(a, j)
        if why then return { error = why, training = true } end
    end
    local snap = towersUp() and exports[TOWERS]:OpsVerifySnapshot() or { at = now() }
    local n = MySQL.update.await("UPDATE ops_jobs SET status = 'assigned', assigned_to = ?, assigned_name = ?, accepted_at = ?, progress = ? WHERE id = ? AND status = 'open' AND (assigned_to IS NULL OR assigned_to = ?)",
        { a.id, nameOf(a), now(), json.encode({ snap = snap }), j.id, a.id })
    if n ~= 1 then return { error = 'Someone else has taken that job' } end
    audit(nameOf(a), j.company_id, 'job.accept', j.ref)
    if j.customer_id then
        local cust = MySQL.single.await('SELECT identifier FROM ops_customers WHERE id = ?', { j.customer_id })
        local cs = cust and cust.identifier and GetSourceByIdentifier(cust.identifier)
        if cs then Notify(cs, { app = 'opswork', title = (CO_BY_ID[j.company_id] or {}).name, icon = 'fa-user-gear', body = ('%s is on the way for %s'):format(nameOf(a), j.title) }) end
    end
    return { ok = true, x = j.x, y = j.y }
end)

On('opsRelease', function(_, _, d, a)
    local j = getJob(d.id)
    if not j then return { error = 'Job not found' } end
    if j.assigned_to ~= a.id and not can(a, j.company_id, 'jobs.dispatch') then return { denied = true } end
    MySQL.update.await("UPDATE ops_jobs SET status = 'open', assigned_to = NULL, assigned_name = NULL, accepted_at = NULL, progress = NULL WHERE id = ?", { j.id })
    audit(nameOf(a), j.company_id, 'job.release', j.ref)
    return { ok = true }
end)

--- start the on-site work (onsite jobs): you must be there; the client plays the work animation
On('opsWork', function(src, _, d, a)
    local j = getJob(d.id)
    if not j or j.assigned_to ~= a.id then return { error = 'Not your job' } end
    local v = decode(j.verify, {})
    local here, dist = within(src, j, v.radius or 30)
    if not here then return { error = ('Get to the job first — you are %d m away'):format(dist or 0) } end
    if BizBeforeWork then local g = BizBeforeWork(j, src, a, 'work') if g then return g end end       -- risk assessment, tools (server/training.lua)
    local prog = decode(j.progress, {})
    prog.workStart = prog.workStart or now()
    MySQL.update.await("UPDATE ops_jobs SET status = 'in_progress', progress = ? WHERE id = ?", { json.encode(prog), j.id })
    local left = math.max(0, (v.secs or 40) - (now() - prog.workStart))
    TriggerClientEvent('opslabs-phone:opsWorkAnim', src, { secs = left, label = v.action or j.title, plan = BizWorkPlan and BizWorkPlan(j, left) or nil })
    return { ok = true, secs = v.secs or 40, elapsed = now() - prog.workStart }
end)

On('opsComplete', function(src, phone, d, a)
    local j = getJob(d.id)
    if not j or j.assigned_to ~= a.id or (j.status ~= 'assigned' and j.status ~= 'in_progress') then return { error = 'Not your job' } end
    if BizBeforeWork then local g = BizBeforeWork(j, src, a, 'complete') if g then return g end end
    local res = verify(j, src, a)
    if not res.ok then return { error = ('Not finished yet: %s (%s / %s)%s'):format(res.label or '', res.have or 0, res.need or 1, res.detail and (' · ' .. res.detail) or ''), check = res } end
    local r = settle(j, src, a, phone)
    return r
end)

On('opsEarnings', function(_, _, _, a)
    local rows = MySQL.query.await([[SELECT w.*, c.name AS company FROM ops_wages w LEFT JOIN ops_companies c ON c.id = w.company_id
        WHERE w.account_id = ? ORDER BY w.at DESC LIMIT 50]], { a.id }) or {}
    local total, week = 0, 0
    for _, w in ipairs(rows) do total = total + w.amount if w.at > now() - 7 * 86400 then week = week + w.amount end end
    return { wages = rows, total = money(total), week = money(week) }
end)

On('opsApply', function(_, _, d, a)
    local c = CO[d.company]
    if not c then return { error = 'No such company' } end
    local apprentice = MySQL.scalar.await("SELECT id FROM ops_roles WHERE code = 'apprentice'")
    MySQL.query.await([[INSERT INTO ops_members (account_id, company_id, role_id, status, note, joined_at) VALUES (?, ?, ?, 'applied', ?, ?)
        ON DUPLICATE KEY UPDATE status = IF(status = 'active', 'active', 'applied'), note = VALUES(note)]], { a.id, c.id, apprentice, Clean(d.note or '', 255), now() })
    notifyCompany(c.id, 'employees.manage', { app = 'opswork', title = c.name, icon = 'fa-user-plus', body = nameOf(a) .. ' applied to join' })
    audit(nameOf(a), c.id, 'member.apply', a.username)
    return { ok = true }
end)

On('opsCompany', function(_, _, d, a)
    local c = CO[d.company]
    if not c then return { error = 'No such company' } end
    local perms = permsIn(a, c.id)
    if not next(perms) then return { denied = true } end
    local out = { company = companyView(c, perms), perms = {} }
    for p in pairs(perms) do out.perms[#out.perms + 1] = p end
    out.messages = MySQL.query.await('SELECT id, author, title, body, at FROM ops_messages WHERE company_id = ? ORDER BY at DESC LIMIT 20', { c.id }) or {}
    out.counts = MySQL.single.await([[SELECT SUM(status = 'open') AS open, SUM(status IN ('assigned','in_progress')) AS active,
        SUM(status = 'completed' AND completed_at > ?) AS week FROM ops_jobs WHERE company_id = ?]], { now() - 7 * 86400, c.id })
    if perms['finance.view'] then
        out.transactions = MySQL.query.await('SELECT kind, amount, balance_after, memo, counterparty, at FROM ops_transactions WHERE company_id = ? ORDER BY id DESC LIMIT 25', { c.id }) or {}
    end
    if perms['employees.view'] then
        out.employees = MySQL.query.await([[SELECT m.id, m.status, m.title, m.note, u.username, u.display_name, r.name AS role, r.code AS role_code
            FROM ops_members m JOIN opslabs_phone_opsnet_users u ON u.id = m.account_id LEFT JOIN ops_roles r ON r.id = m.role_id
            WHERE m.company_id = ? ORDER BY m.status, r.rank_no DESC]], { c.id }) or {}
        out.roles = MySQL.query.await('SELECT id, code, name FROM ops_roles ORDER BY rank_no DESC') or {}
    end
    if perms['jobs.dispatch'] then
        out.jobTypes = {}
        for _, t in ipairs(CAT.jobTypes or {}) do if t.company == c.code then out.jobTypes[#out.jobTypes + 1] = { code = t.code, title = t.title } end end
    end
    return out
end)

On('opsMember', function(_, _, d, a)
    local m = MySQL.single.await('SELECT * FROM ops_members WHERE id = ?', { tonumber(d.id) })
    if not m or not can(a, m.company_id, 'employees.manage') then return { denied = true } end
    if d.action == 'approve' or d.action == 'role' then
        local role = d.role and MySQL.scalar.await('SELECT id FROM ops_roles WHERE code = ?', { d.role }) or m.role_id
        MySQL.update.await("UPDATE ops_members SET status = 'active', role_id = ?, joined_at = IF(status = 'active', joined_at, ?) WHERE id = ?", { role, now(), m.id })
    elseif d.action == 'remove' then MySQL.update.await("UPDATE ops_members SET status = 'left' WHERE id = ?", { m.id })
    else return { error = 'bad action' } end
    audit(nameOf(a), m.company_id, 'member.' .. d.action, tostring(m.account_id), d.role)
    return { ok = true }
end)

On('opsPost', function(_, _, d, a)
    local c = CO[d.company]
    if not c or not can(a, c.id, 'company.manage') then return { denied = true } end
    local title = Clean(d.title or '', 120)
    if title == '' then return { error = 'Write a title' } end
    MySQL.insert.await('INSERT INTO ops_messages (company_id, author, title, body, at) VALUES (?, ?, ?, ?, ?)', { c.id, nameOf(a), title, Clean(d.body or '', 2000), now() })
    notifyCompany(c.id, 'jobs.view', { app = 'opswork', title = c.name, icon = 'fa-bullhorn', body = title })
    return { ok = true }
end)

--- dispatchers: new job at a customer / here
On('opsDispatch', function(src, _, d, a)
    local c = CO[d.company]
    if not c or not can(a, c.id, 'jobs.dispatch') then return { denied = true } end
    local t = TYPES[d.type]
    if not t or t.company ~= c.code then return { error = 'Pick a job type' } end
    local p = playerPos(src)
    local place = { name = Clean(d.location or 'Dispatcher location', 160), x = p.x, y = p.y, z = p.z }
    local id, ref = createJob(c, t, place, { by = nameOf(a), emergency = d.emergency == true, price = tonumber(d.price) })
    audit(nameOf(a), c.id, 'job.create', ref)
    return { ok = true, id = id, ref = ref }
end)

---------------------------------------------------------------------------
-- customers: ask any OPS company for a service (anyone with a phone, no account needed)
---------------------------------------------------------------------------
Register('opsServices', function(src, phone)
    loadCompanies()
    local out = {}
    for _, t in ipairs(CAT.jobTypes or {}) do
        local c = CO[t.company]
        if c and coOn(c) and typeOn(t) and t.price and t.price > 0 then out[#out + 1] = { code = t.code, company = c.code, companyName = c.name, color = c.color, icon = c.icon, title = t.title, desc = t.desc, price = t.price } end
    end
    local cust = MySQL.single.await('SELECT id FROM ops_customers WHERE identifier = ?', { phone.identifier })
    local mine = cust and MySQL.query.await(JOB_SELECT .. "WHERE j.customer_id = ? ORDER BY j.id DESC LIMIT 15", { cust.id }) or {}
    local inv = cust and MySQL.query.await([[SELECT i.number, i.total, i.status, i.issued_at, c.name AS company FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id
        WHERE i.customer_id = ? ORDER BY i.id DESC LIMIT 20]], { cust.id }) or {}
    local jobs = {}
    for _, j in ipairs(mine) do jobs[#jobs + 1] = jobView(j) end
    return { services = out, requests = jobs, invoices = inv }
end)

Register('opsRequest', function(src, phone, d)
    local t = TYPES[d.type]
    local c = t and CO[t.company]
    if not c then return { error = 'Pick a service' } end
    local open = MySQL.scalar.await([[SELECT COUNT(*) FROM ops_jobs j JOIN ops_customers cu ON cu.id = j.customer_id
        WHERE cu.identifier = ? AND j.status IN ('open','assigned','in_progress')]], { phone.identifier }) or 0
    if open >= 3 then return { error = 'You already have 3 open requests' } end
    local cust = customerForPlayer(src, phone)
    local p = playerPos(src)
    local place = { customer_id = cust.id, name = Clean(d.address or '', 160) ~= '' and Clean(d.address, 160) or ('Customer: ' .. cust.name), x = p.x, y = p.y, z = p.z }
    local id, ref = createJob(c, t, place, { by = cust.name, emergency = d.emergency == true })
    audit(cust.name, c.id, 'job.request', ref)
    return { ok = true, ref = ref }
end)

---------------------------------------------------------------------------
-- wages owed (jobs signed off on OPS Hub, bonuses): paid into the bank when the engineer is in game
---------------------------------------------------------------------------
CreateThread(function()
    Wait(45000)
    while true do
        local pending = MySQL.query.await([[SELECT w.*, u.identifier AS uident, c.name AS company FROM ops_wages w
            JOIN opslabs_phone_opsnet_users u ON u.id = w.account_id JOIN ops_companies c ON c.id = w.company_id
            WHERE w.status = 'pending' AND u.identifier IS NOT NULL LIMIT 50]]) or {}
        for _, w in ipairs(pending) do
            local src = GetSourceByIdentifier(w.uident)
            if src and FW.AddMoney(src, tonumber(w.amount), 'bank', w.company .. ' wages') then
                MySQL.update.await("UPDATE ops_wages SET status = 'paid', paid_at = ?, identifier = ? WHERE id = ? AND status = 'pending'", { now(), w.uident, w.id })
                MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { w.uident, Clean(w.company .. ': ' .. (w.label or 'wages'), 120), w.amount })
                Notify(src, { app = 'opswork', title = w.company, icon = 'fa-sack-dollar', body = ('$%s paid · %s'):format(w.amount, w.label or 'wages'), data = { page = 'earnings' } })
            end
        end
        Wait(60000)
    end
end)

--- other resources raise jobs (e.g. opslabs-towers CCTV faults): company code, job type code, { name, x, y, z }, opts
exports('CompanyForRole', function(r) return Ops.role(r) end)
exports('CreatePlatformJob', function(code, typeCode, place, opts)
    loadCompanies()
    local c, t = CO[code], TYPES[typeCode]
    if not c or not t then return nil end
    return createJob(c, t, place, opts)
end)

---------------------------------------------------------------------------
-- money for other resources (OPS Network ISP billing…)
---------------------------------------------------------------------------
--- take money from a customer account: player (bank, then cash, if online), organisation (society), business (on account)
local function chargeCustomer(customerId, amount, label)
    local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { customerId })
    if not cust then return false, 'no customer' end
    amount = money(amount)
    if amount <= 0 then return true, 'free' end
    if cust.identifier then
        local cs = GetSourceByIdentifier(cust.identifier)
        if not cs then return false, 'offline' end
        if FW.RemoveMoney(cs, amount, 'bank', label) or FW.RemoveMoney(cs, amount, 'cash', label) then
            MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { cust.identifier, Clean(label, 120), -amount })
            return true, 'card'
        end
        return false, 'insufficient'
    elseif cust.society then
        if society(cust.society, amount) then return true, 'account' end
        return false, 'insufficient'
    end
    return true, 'account'
end
exports('ChargeCustomer', chargeCustomer)
exports('CompanyMove', function(code, kind, amount, memo, refType, refId, counterparty, actor)
    loadCompanies()
    local c = CO[code]
    if not c then return nil end
    return companyMove(c.id, kind, amount, memo, refType, refId, counterparty, actor)
end)
--- invoice from a company to a customer for a line item; returns id, number
exports('IssueInvoice', function(code, customerId, title, ref, total, paid)
    loadCompanies()
    local c = CO[code]
    if not c then return nil end
    local cust = customerId and MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { customerId }) or nil
    return issueInvoice(c, cust, { id = nil, title = title, ref = ref }, total, paid and 'paid' or 'unpaid')
end)
exports('NotifyIdentifier', function(identifier, notif)
    local src = identifier and GetSourceByIdentifier(identifier)
    if src then Notify(src, notif) return true end
    return false
end)

---------------------------------------------------------------------------
-- for the rest of this resource (server/web.lua: OPS Domains · OPS Web)
---------------------------------------------------------------------------
Ops = {
    account = account, nameOf = nameOf, isSuper = isSuper, audit = audit, money = money,
    customerForPlayer = customerForPlayer, charge = chargeCustomer,
    company = function(code) if not CO[code] then loadCompanies() end return CO[code] end,
    --- the company that fills a role in the city (catalog "companyRoles": isp, fibre, mobile, web, domains, cloud, data, secure, power …)
    role = function(r) local m = Ops.catalog.companyRoles or {} local v = m[r] return type(v) == 'string' and v ~= '' and v or r end,
    can = function(a, code, perm) if not CO[code] then loadCompanies() end local c = CO[code] return a ~= nil and c ~= nil and can(a, c.id, perm) end,
    move = function(code, kind, amount, memo, refType, refId, counterparty, actor)
        local c = Ops.company(code) if c then return companyMove(c.id, kind, amount, memo, refType, refId, counterparty, actor) end
    end,
    invoice = function(code, cust, title, ref, total, paid)
        local c = Ops.company(code) if c then return issueInvoice(c, cust, { id = nil, title = title, ref = ref }, total, paid and 'paid' or 'unpaid') end
    end,
    job = function(code, typeCode, place, opts)
        local c, t = Ops.company(code), TYPES[typeCode]
        if c and t then return createJob(c, t, place, opts) end
    end,
    catalog = CAT,
    types = TYPES,
    verify = function(j, src, a) return verify(j, src, a) end,
    getJob = function(id) return getJob(id) end,
    jobView = function(j, a) return jobView(j, a) end,
    notify = function(code, perm, notif) local c = Ops.company(code) if c then notifyCompany(c.id, perm, notif) end end,
    notifyId = function(coId, perm, notif) notifyCompany(coId, perm, notif) end,
    byId = function(id) if not CO_BY_ID[id] then loadCompanies() end return CO_BY_ID[id] end,
    canId = function(a, coId, perm) return a ~= nil and can(a, coId, perm) end,
}
