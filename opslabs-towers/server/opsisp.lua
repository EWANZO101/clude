-- OPS Network ISP (Config.OpsIsp): customer lines on the fibre network — orders, installs, IP addresses, router
-- settings, monitoring, outages, billing and speed tests. Data lives in MySQL (ops_isp_*), shared with OPS Hub; this
-- file keeps the game in step with it every MonitorEvery seconds (so changes made on the website take effect here).
-- Money and jobs go through the OPS platform in opslabs-phone (exports ChargeCustomer / CompanyMove / IssueInvoice /
-- CreatePlatformJob / NotifyIdentifier).

local CO = Config.OpsIsp or {}
if not CO.Enabled then return end
local PHONE = 'opslabs-phone'
local function now() return os.time() end
local function phoneUp() return GetResourceState(PHONE) == 'started' end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function P(name, ...) if not phoneUp() then return nil end local args = { ... } local ok, a, b = pcall(function() return exports[PHONE][name](exports[PHONE], table.unpack(args)) end) if ok then return a, b end print('[opsisp] ' .. name .. ': ' .. tostring(a)) end
local function ISP() return P('CompanyForRole', 'isp') or 'network' end   -- the company that is the ISP (catalog roles)
-- the company the customer deals with for a line: a sub-company retailing on the network (ops_isp_services.company_id,
-- opslabs-phone server/market.lua) or the ISP. Installs and repairs stay with the ISP's engineers (wholesale model).
local RetailCache = {}
local function retailer(row)
    local id = row and tonumber(row.company_id) or 0
    local c = RetailCache[id]
    if c and os.time() - c.at < 30 then return c end
    local r = P('MarketRetailer', id > 0 and id or nil, 'isp') or { code = ISP(), name = 'OPS Network' }
    r.at = os.time()
    RetailCache[id] = r
    return r
end
local function canSell(companyId)
    if not companyId then return true end
    local ok = P('MarketCanSell', companyId, 'fibre_access')
    return ok == true
end

local Packages = {}          -- id -> row
local ServiceOfOnt = {}      -- ont fixture id -> service row (active / suspended)
local NetCache = {}         -- service id -> { ips, lan, cfgAt }

---------------------------------------------------------------------------
-- set-up
---------------------------------------------------------------------------
local function loadPackages()
    Packages = {}
    for _, p in ipairs(MySQL.query.await('SELECT * FROM ops_isp_packages') or {}) do Packages[p.id] = p end
end

MySQL.ready(function()
    local sql = LoadResourceFile(PHONE, 'sql/ops_isp.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    for i, p in ipairs(CO.Packages or {}) do
        MySQL.query.await([[INSERT INTO ops_isp_packages (code, name, segment, tech, down_mbps, up_mbps, price, setup_fee, ip_mode, static_ips, contract_months, sla, fix_hours, description, sort)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE code = code]],
            { p.code, p.name, p.segment, p.tech or 'fibre', p.down, p.up, p.price, p.setup or 0, p.ip or 'dynamic', p.statics or 0, p.contract or 12, p.sla or 'standard', p.fix or 48, p.desc, i })
    end
    loadPackages()
end)

---------------------------------------------------------------------------
-- IP addresses (IPAM)
---------------------------------------------------------------------------
local function cidrHosts(cidr)
    local a, b, c, d, bits = cidr:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$')
    a, b, c, d, bits = tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(bits)
    local base = ((a << 24) | (b << 16) | (c << 8) | d) & (~((1 << (32 - bits)) - 1) & 0xFFFFFFFF)
    return base, 1 << (32 - bits)
end
local function ipStr(n) return ('%d.%d.%d.%d'):format((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255) end

--- give a service `count` addresses from the pool for its kind (dedicated: an aligned block)
local function allocate(svc, kind, count)
    local pools = (CO.Pools or {})[kind] or {}
    local taken = {}
    for _, r in ipairs(MySQL.query.await('SELECT ip FROM ops_isp_ips WHERE pool = ?', { kind }) or {}) do taken[r.ip] = true end
    for _, cidr in ipairs(pools) do
        local base, size = cidrHosts(cidr)
        local step = kind == 'dedicated' and 8 or 1
        for off = (kind == 'dedicated' and 8 or 10), size - 2, step do
            local block = {}
            for k = 0, (count or 1) - 1 do
                local ip = ipStr(base + off + k)
                if taken[ip] or (off + k) >= size - 1 then block = nil break end
                block[#block + 1] = ip
            end
            if block and #block > 0 then
                for i, ip in ipairs(block) do
                    MySQL.insert.await('INSERT IGNORE INTO ops_isp_ips (ip, pool, service_id, kind, ptr, assigned_at) VALUES (?, ?, ?, ?, ?, ?)',
                        { ip, kind, svc.id, kind == 'dynamic' and 'dynamic' or 'static', i == 1 and ('host-%s.cust.opsnet.sa'):format(ip:gsub('%.', '-')) or nil, now() })
                end
                return block
            end
        end
    end
    return nil
end
local function ipsOf(id)
    local out = {}
    for _, r in ipairs(MySQL.query.await('SELECT ip, kind FROM ops_isp_ips WHERE service_id = ? ORDER BY INET_ATON(ip)', { id }) or {}) do out[#out + 1] = r.ip end
    return out
end

---------------------------------------------------------------------------
-- router settings
---------------------------------------------------------------------------
local function defaultConfig(svc, pkg, cust)
    local business = pkg.segment ~= 'residential'
    local lan = business and ('10.%d.%d.0/24'):format(20 + (svc.id // 250) % 200, svc.id % 250) or '192.168.1.0/24'
    local gw = lan:gsub('0/24$', '1')
    local first = lan:gsub('0/24$', '100')
    local last = lan:gsub('0/24$', '199')
    local ssid = ((cust and cust.name or 'OPSNET'):gsub('[^%w]', '')):sub(1, 14)
    return {
        lan = { subnet = lan, gateway = gw },
        dhcp = { enabled = true, from = first, to = last, lease_hours = 24, reservations = {} },
        dns = { mode = 'isp', servers = CO.Dns or {} },
        wifi = { ssid = (ssid ~= '' and ssid or 'OPSNET') .. '-' .. svc.id, password = nil, guest = false },
        vlans = business and { { id = 10, name = 'Staff', subnet = lan }, { id = 20, name = 'Guest', subnet = ('10.%d.%d.0/24'):format(120 + (svc.id // 250) % 100, svc.id % 250), isolated = true } } or {},
        firewall = { default_in = 'deny', default_out = 'allow', rules = {} },
        forwards = {},
        vpn = {},
    }
end
local function configOf(id)
    local r = MySQL.single.await('SELECT * FROM ops_isp_config WHERE service_id = ?', { id })
    return r and decode(r.config, nil), r
end

---------------------------------------------------------------------------
-- lines: activation, monitoring, outages, billing
---------------------------------------------------------------------------
local function svcCustomer(svc) return MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { svc.customer_id }) end
local function notifyCustomer(cust, title, body, page)
    if cust and cust.identifier then P('NotifyIdentifier', cust.identifier, { app = 'opswork', title = title, body = body, icon = 'fa-wifi', data = { page = page or 'broadband' } }) end
end
local function planFor(pkg)
    local best, bd
    for speed, plan in pairs(CO.Plans or {}) do
        local d = math.abs(speed - pkg.down_mbps)
        if not bd or d < bd then best, bd = plan, d end
    end
    return best or 'fibre150'
end

--- bill one period (setup fee too on the first one); returns paid
local function bill(svc, pkg, first)
    local amount = tonumber(svc.price) + (first and tonumber(pkg.setup_fee) or 0)
    if amount <= 0 then return true end
    local r = retailer(svc)
    local paid = P('ChargeCustomer', svc.customer_id, amount, ('%s · %s'):format(r.name, pkg.name))
    P('IssueInvoice', r.code, svc.customer_id, (first and 'Installation + first month · ' or 'Monthly service · ') .. pkg.name, svc.ref, amount, paid == true)
    if paid == true then P('CompanyMove', r.code, 'income', amount, ('%s · %s'):format(pkg.name, svc.ref), 'service', svc.id, nil, 'billing') end
    return paid == true
end

local function nearestOnlineOnt(svc)
    local status = IspPayload and IspPayload() or {}
    local best, bd
    for id, f in pairs(Cabling.fixtures) do
        if f.model == (Config.Isp or {}).Ont and svc.x and not (ServiceOfOnt[id] and ServiceOfOnt[id].id ~= svc.id) then
            local d = d2(f, svc)
            if d <= (CO.LinkRadius or 60) and (not bd or d < bd) and status[id] and not status[id].los then best, bd = id, d end
        end
    end
    return best
end

--- the router on the ONT's LAN port (a gateway tower cabled to it)
local function routerOf(ont)
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and r.start_term and r.end_term then
            if r.start_fixture == ont and r.end_tower then return r.end_tower end
            if r.end_fixture == ont and r.start_tower then return r.start_tower end
        end
    end
end

function OpsIspActivate(svcId, why)
    local svc = MySQL.single.await('SELECT * FROM ops_isp_services WHERE id = ?', { svcId })
    if not svc then return nil, 'no such line' end
    local pkg = Packages[svc.package_id]
    if not pkg then loadPackages() pkg = Packages[svc.package_id] end
    local cust = svcCustomer(svc)
    local ont = svc.ont_id or nearestOnlineOnt(svc)
    local t = now()
    MySQL.update.await([[UPDATE ops_isp_services SET status = 'active', ont_id = ?, router_tower = ?, contract_start = COALESCE(contract_start, ?),
        contract_end = COALESCE(contract_end, ?), next_bill_at = ? WHERE id = ?]],
        { ont, ont and routerOf(ont) or nil, t, t + (pkg.contract_months or 12) * 30 * 86400, t + (CO.BillingDays or 7) * 86400, svc.id })
    if #ipsOf(svc.id) == 0 then
        local kind = pkg.ip_mode == 'dedicated' and 'dedicated' or pkg.ip_mode == 'static' and 'static' or 'dynamic'
        allocate(svc, kind, math.max(1, pkg.static_ips or 1))
    end
    if not configOf(svc.id) then
        MySQL.insert.await('INSERT IGNORE INTO ops_isp_config (service_id, config, updated_by, updated_at) VALUES (?, ?, ?, ?)', { svc.id, json.encode(defaultConfig(svc, pkg, cust)), 'install', t })
    end
    if ont and IspProvision then IspProvision(ont, 'opsfibre', planFor(pkg), cust and cust.name or nil, retailer(svc).name) end
    local paid = bill(svc, pkg, true)
    if not paid then MySQL.update.await('UPDATE ops_isp_services SET overdue_since = ? WHERE id = ?', { t, svc.id }) end
    notifyCustomer(cust, retailer(svc).name, ('%s is live%s'):format(pkg.name, paid and '' or ' — your first bill is waiting'), 'broadband')
    return true
end

--- order a line: the service is created pending and an install job goes to OPS Network
function OpsIspOrder(customerId, packageId, place, by)
    local pkg = Packages[tonumber(packageId)]
    if not pkg then loadPackages() pkg = Packages[tonumber(packageId)] end
    if not pkg or pkg.active ~= 1 then return nil, 'Pick a package' end
    if not canSell(pkg.company_id) then return nil, 'This provider is not taking new customers right now' end
    local id = MySQL.insert.await([[INSERT INTO ops_isp_services (customer_id, package_id, company_id, status, address, x, y, z, ip_mode, price, ordered_by, created_at)
        VALUES (?, ?, ?, 'pending_install', ?, ?, ?, ?, ?, ?, ?, ?)]], { customerId, pkg.id, pkg.company_id, place.name, place.x, place.y, place.z, pkg.ip_mode, pkg.price, by, now() })
    local ref = ('LINE-%05d'):format(id)
    local r = retailer(pkg)
    local jobId = P('CreatePlatformJob', ISP(), 'isp_newcustomer', { customer_id = customerId, name = place.name, x = place.x, y = place.y, z = place.z },
        { title = 'New line · ' .. pkg.name .. (pkg.company_id and (' · for ' .. r.name) or ''), description = ('Install %s for %s%s: fibre to the property, ONT online with live service, router on the LAN.'):format(pkg.name, place.name or 'the customer', pkg.company_id and (' (a ' .. r.name .. ' customer)') or ''), price = 0 })
    MySQL.update.await('UPDATE ops_isp_services SET ref = ?, install_job = ? WHERE id = ?', { ref, jobId, id })
    return id, ref
end

-- the install job is done → the line goes live
AddEventHandler('ops:jobCompleted', function(jobId)
    local svc = MySQL.single.await("SELECT id FROM ops_isp_services WHERE install_job = ? AND status = 'pending_install'", { jobId })
    if svc then OpsIspActivate(svc.id, 'install') end
end)

local applied = {}       -- service id -> config updated_at applied to the router
local function reconcile()
    loadPackages()
    local status = IspPayload and IspPayload() or {}
    local t = now()
    local rows = MySQL.query.await("SELECT * FROM ops_isp_services WHERE status IN ('active','suspended','cancelled','pending_activation')") or {}
    ServiceOfOnt = {}
    local down = {}
    for _, svc in ipairs(rows) do
        local pkg = Packages[svc.package_id]
        if svc.status == 'pending_activation' then OpsIspActivate(svc.id, 'hub')
        elseif pkg then
            if svc.status ~= 'cancelled' and not svc.ont_id then
                local ont = nearestOnlineOnt(svc)
                if ont then svc.ont_id = ont MySQL.update('UPDATE ops_isp_services SET ont_id = ?, router_tower = ? WHERE id = ?', { ont, routerOf(ont), svc.id }) end
            end
            local ont = svc.ont_id
            if ont and Cabling.fixtures[ont] then
                if svc.status ~= 'cancelled' then
                    ServiceOfOnt[ont] = svc
                    local cfg, row = configOf(svc.id)
                    NetCache[svc.id] = { ips = ipsOf(svc.id), lan = cfg and cfg.lan and cfg.lan.subnet or nil, cfg = cfg, cfgAt = row and row.updated_at or 0 }
                end
                -- keep the ONT's provisioning in step with the line
                local want = svc.status == 'active' and 'active' or svc.status == 'suspended' and 'suspended' or 'cease'
                local have = IspServiceStatus and IspServiceStatus(ont) or 'none'
                if want == 'active' and have ~= 'active' and IspProvision then IspProvision(ont, 'opsfibre', planFor(pkg), nil, retailer(svc).name)
                elseif want == 'suspended' and have == 'active' and IspSetStatus then IspSetStatus(ont, 'suspended')
                elseif want == 'cease' and have ~= 'none' and IspSetStatus then IspSetStatus(ont, 'cease') end
                -- line state
                if svc.status == 'active' then
                    local s = status[ont] or {}
                    local state = s.internet == 'on' and ((s.rx and s.rx < -25.5) and 'degraded' or 'up') or 'down'
                    if state ~= svc.line_state or state ~= 'down' then
                        MySQL.update('UPDATE ops_isp_services SET line_state = ?, last_seen_up = ? WHERE id = ?', { state, state ~= 'down' and t or svc.last_seen_up, svc.id })
                    end
                    if state == 'down' then down[#down + 1] = { svc = svc, f = Cabling.fixtures[ont] } end
                end
                -- Wi-Fi name / password from the router settings → the real router in game
                if svc.router_tower and Towers[svc.router_tower] and SaveTower then
                    local cfg, row = configOf(svc.id)
                    if cfg and row and applied[svc.id] ~= row.updated_at then
                        applied[svc.id] = row.updated_at
                        local w = cfg.wifi or {}
                        local tw = Towers[svc.router_tower]
                        if w.ssid and (w.ssid ~= tw.ssid or (w.password or nil) ~= tw.password) then
                            SaveTower(svc.router_tower, { ssid = w.ssid, password = w.password or '' }, 'OPS Network')
                        end
                    end
                end
            end
        end
    end
    -- outages: lines down near each other
    local open = MySQL.query.await("SELECT * FROM ops_isp_outages WHERE status <> 'resolved'") or {}
    local claimed = {}
    for _, o in ipairs(open) do
        local still = 0
        for _, d in ipairs(down) do if o.x and d2(d.f, o) <= (o.radius or CO.OutageRadius or 450) then still = still + 1 claimed[d.svc.id] = true end end
        if still == 0 and o.planned ~= 1 then
            local ups = decode(o.updates, {})
            ups[#ups + 1] = { at = t, text = 'Service restored — all lines back up.' }
            MySQL.update('UPDATE ops_isp_outages SET status = ?, resolved_at = ?, updates = ? WHERE id = ?', { 'resolved', t, json.encode(ups), o.id })
            for _, sid in ipairs(decode(o.services, {})) do
                local s = MySQL.single.await('SELECT * FROM ops_isp_services WHERE id = ?', { sid })
                if s then notifyCustomer(svcCustomer(s), retailer(s).name, 'Your internet is back — sorry for the outage.', 'broadband') end
            end
        elseif still ~= o.affected then MySQL.update('UPDATE ops_isp_outages SET affected = ? WHERE id = ?', { still, o.id }) end
    end
    local free = {}
    for _, d in ipairs(down) do if not claimed[d.svc.id] then free[#free + 1] = d end end
    for _, d in ipairs(free) do
        if not d.used then
            local group = {}
            for _, e in ipairs(free) do if not e.used and d2(d.f, e.f) <= (CO.OutageRadius or 450) then group[#group + 1] = e end end
            if #group >= (CO.OutageMinLines or 3) then
                local cx, cy, ids = 0, 0, {}
                for _, e in ipairs(group) do e.used = true cx, cy = cx + e.f.x, cy + e.f.y ids[#ids + 1] = e.svc.id end
                cx, cy = cx / #group, cy / #group
                local area = group[1].svc.address or 'the area'
                local oid = MySQL.insert.await([[INSERT INTO ops_isp_outages (title, area, x, y, radius, cause, status, affected, services, started_at, updates)
                    VALUES (?, ?, ?, ?, ?, ?, 'investigating', ?, ?, ?, ?)]], { ('Internet outage near %s'):format(area), area, cx, cy, CO.OutageRadius or 450, 'Under investigation',
                    #group, json.encode(ids), t, json.encode({ { at = t, text = ('%d lines lost service together. Engineers are being sent.'):format(#group) } }) })
                MySQL.update('UPDATE ops_isp_outages SET ref = ? WHERE id = ?', { ('INC-%05d'):format(oid), oid })
                local jid = P('CreatePlatformJob', ISP(), 'net_outage', { name = 'Outage · ' .. area, x = cx, y = cy, z = group[1].f.z },
                    { title = ('OUTAGE · %d lines down near %s'):format(#group, area), emergency = true, description = 'Several lines dropped together — find the break (cable, joint, cabinet, OLT) and restore service.' })
                if jid then MySQL.update('UPDATE ops_isp_outages SET job_id = ? WHERE id = ?', { jid, oid }) end
                for _, e in ipairs(group) do notifyCustomer(svcCustomer(e.svc), retailer(e.svc).name, 'There’s an outage in your area — engineers are on it. We’ll tell you when it’s fixed.', 'broadband') end
            end
        end
    end
end

local function billing()
    local t = now()
    for _, svc in ipairs(MySQL.query.await("SELECT * FROM ops_isp_services WHERE status IN ('active','suspended') AND next_bill_at IS NOT NULL") or {}) do
        local pkg = Packages[svc.package_id]
        if pkg then
            if svc.next_bill_at <= t then
                local paid = bill(svc, pkg, false)
                MySQL.update('UPDATE ops_isp_services SET next_bill_at = ?, overdue_since = ? WHERE id = ?',
                    { svc.next_bill_at + (CO.BillingDays or 7) * 86400, (not paid) and (svc.overdue_since or t) or nil, svc.id })
                svc.overdue_since = (not paid) and (svc.overdue_since or t) or nil
            elseif svc.overdue_since then
                -- try again: pay the oldest unpaid invoice when they can
                local r = retailer(svc)
                local inv = MySQL.single.await([[SELECT i.* FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id
                    WHERE c.code = ? AND i.customer_id = ? AND i.status = 'unpaid' ORDER BY i.id LIMIT 1]], { r.code, svc.customer_id })
                if inv and P('ChargeCustomer', svc.customer_id, tonumber(inv.total), r.name .. ' · ' .. inv.number) == true then
                    MySQL.update.await("UPDATE ops_invoices SET status = 'paid', paid_at = ? WHERE id = ?", { t, inv.id })
                    P('CompanyMove', r.code, 'income', tonumber(inv.total), 'Invoice ' .. inv.number .. ' paid', 'invoice', inv.id, nil, 'billing')
                    local left = MySQL.scalar.await([[SELECT COUNT(*) FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id
                        WHERE c.code = ? AND i.customer_id = ? AND i.status = 'unpaid']], { r.code, svc.customer_id }) or 0
                    if left == 0 then
                        MySQL.update.await("UPDATE ops_isp_services SET overdue_since = NULL, status = IF(status = 'suspended', 'active', status) WHERE id = ?", { svc.id })
                        if svc.status == 'suspended' then notifyCustomer(svcCustomer(svc), r.name, 'Thanks — your bill is paid and your internet is back on.') end
                    end
                elseif svc.status == 'active' and t - svc.overdue_since > (CO.GraceDays or 3) * 86400 then
                    MySQL.update.await("UPDATE ops_isp_services SET status = 'suspended' WHERE id = ?", { svc.id })
                    notifyCustomer(svcCustomer(svc), retailer(svc).name, 'Your internet is suspended — your bill is overdue. Pay in OPS Work → My broadband.')
                end
            end
        end
    end
end

CreateThread(function()
    Wait(20000)
    local lastBill = 0
    while true do
        local ok, err = pcall(reconcile)
        if not ok then print('[opsisp] monitor: ' .. tostring(err)) end
        if now() - lastBill >= 60 then
            lastBill = now()
            ok, err = pcall(billing)
            if not ok then print('[opsisp] billing: ' .. tostring(err)) end
        end
        Wait((CO.MonitorEvery or 30) * 1000)
    end
end)

-- the IP the rest of the system shows for an ONT (customer lookups, faults): its real assigned address once it's a line
local baseOntAddress = OntAddress
CreateThread(function()
    Wait(1000)
    baseOntAddress = baseOntAddress or OntAddress
    OntAddress = function(id, providerId)
        local base = baseOntAddress and baseOntAddress(id, providerId) or {}
        local svc = ServiceOfOnt[id]
        local nc = svc and NetCache[svc.id]
        if svc and nc then
            local ips = nc.ips or {}
            if ips[1] then base.ip = ips[1] base.gateway = ips[1]:gsub('%d+$', '1') end
            if nc.lan then base.lan_subnet = nc.lan end
            base.line = svc.ref
        end
        return base
    end
end)

---------------------------------------------------------------------------
-- speed tests
---------------------------------------------------------------------------
local function serviceNear(pos, radius)
    local best, bd
    for ont, svc in pairs(ServiceOfOnt) do
        local f = Cabling.fixtures[ont]
        if f then
            local d = math.sqrt((f.x - pos.x) ^ 2 + (f.y - pos.y) ^ 2 + (f.z - pos.z) ^ 2)
            if d <= (radius or 40) and (not bd or d < bd) then best, bd = svc, d end
        end
    end
    return best, bd
end

function OpsIspSpeedtest(src)
    local pos = GetEntityCoords(GetPlayerPed(src))
    local svc, dist = serviceNear(pos, 45)
    if not svc then return { error = 'No OPS Network line here — stand inside the customer’s property' } end
    local pkg = Packages[svc.package_id]
    local st = (IspPayload and IspPayload() or {})[svc.ont_id] or {}
    if svc.status ~= 'active' then return { error = 'The line is ' .. svc.status } end
    if st.internet ~= 'on' then return { error = 'No internet on the line (' .. (st.los and 'no light at the ONT' or 'not authenticated') .. ')', down = true } end
    local cov = ComputeCoverage and ComputeCoverage(pos, src) or {}
    local bars = 0
    for _, n in ipairs(cov.nearby or {}) do if n.inRange and n.bars > bars then bars = n.bars end end
    local wired = dist <= 3.0
    if not wired and bars == 0 then return { error = 'Not connected — no Wi-Fi from this line in range. Stand by the router or plug in.' } end
    local rx = tonumber(st.rx) or -20
    local q = 0.78 + 0.22 * math.max(0, math.min(1, (rx + 28) / 10))
    local wifi = wired and 0.97 or (0.25 + 0.22 * bars)
    local cong = 0.88 + math.random() * 0.12
    local downv = pkg.down_mbps * q * wifi * cong
    if not wired then downv = math.min(downv, 940 * (bars / 3)) end
    local upv = pkg.up_mbps * q * (wired and 0.98 or (0.3 + 0.2 * bars)) * (0.9 + math.random() * 0.1)
    local ping = math.floor(4 + math.random() * 4 + (wired and 0 or 3 + (3 - bars) * 4) + (rx < -24 and 6 or 0))
    local row = { service_id = svc.id, down_mbps = math.floor(downv * 10) / 10, up_mbps = math.floor(upv * 10) / 10, ping_ms = ping, jitter_ms = math.floor(1 + math.random() * (wired and 2 or 6)),
        via = wired and 'ethernet' or 'wifi', by_name = GetPlayerName(src), x = pos.x, y = pos.y, at = now() }
    MySQL.insert('INSERT INTO ops_isp_speedtests (service_id, down_mbps, up_mbps, ping_ms, jitter_ms, via, by_name, x, y, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { row.service_id, row.down_mbps, row.up_mbps, row.ping_ms, row.jitter_ms, row.via, row.by_name, row.x, row.y, row.at })
    row.plan_down, row.plan_up, row.package, row.line = pkg.down_mbps, pkg.up_mbps, pkg.name, svc.ref
    row.pct = math.floor(row.down_mbps / pkg.down_mbps * 100)
    return row
end
function OpsIspSpeedtestsSince(x, y, radius, since)
    return MySQL.query.await('SELECT t.*, p.down_mbps AS plan_down FROM ops_isp_speedtests t JOIN ops_isp_services s ON s.id = t.service_id JOIN ops_isp_packages p ON p.id = s.package_id WHERE t.at >= ? AND ABS(t.x - ?) < ? AND ABS(t.y - ?) < ?',
        { since or 0, x, radius, y, radius }) or {}
end

---------------------------------------------------------------------------
-- callbacks (phone: customers + engineers)
---------------------------------------------------------------------------
local function myCustomer(src)
    local ident = FW.Identifier(src)
    return ident and MySQL.single.await('SELECT * FROM ops_customers WHERE identifier = ? LIMIT 1', { ident }), ident
end
local function serviceView(svc, full)
    local pkg = Packages[svc.package_id] or {}
    local v = { id = svc.id, ref = svc.ref, status = svc.status, line = svc.line_state, address = svc.address, package = pkg.name, down = pkg.down_mbps, up = pkg.up_mbps,
        price = tonumber(svc.price), provider = retailer(svc).name, ip_mode = pkg.ip_mode, sla = pkg.sla, contract_end = svc.contract_end, next_bill_at = svc.next_bill_at, overdue = svc.overdue_since ~= nil, ips = ipsOf(svc.id) }
    if full then
        local cfg = configOf(svc.id) or {}
        v.config = { lan = cfg.lan, wifi = cfg.wifi and { ssid = cfg.wifi.ssid, secured = cfg.wifi.password ~= nil and cfg.wifi.password ~= '' } or nil, dns = cfg.dns, vlans = cfg.vlans, forwards = cfg.forwards }
        v.tests = MySQL.query.await('SELECT down_mbps, up_mbps, ping_ms, via, at FROM ops_isp_speedtests WHERE service_id = ? ORDER BY id DESC LIMIT 5', { svc.id }) or {}
        v.outage = MySQL.single.await([[SELECT ref, title, status, started_at FROM ops_isp_outages WHERE status <> 'resolved' AND JSON_CONTAINS(services, CAST(? AS JSON))]], { tostring(svc.id) })
    end
    return v
end

--- the companies a customer has lines with (their bills): the ISP and any retailers
local function retailCodes(customerId)
    local codes, seen = { ISP() }, { [ISP()] = true }
    for _, s in ipairs(MySQL.query.await('SELECT DISTINCT company_id FROM ops_isp_services WHERE customer_id = ? AND company_id IS NOT NULL', { customerId }) or {}) do
        local r = retailer(s)
        if not seen[r.code] then seen[r.code] = true codes[#codes + 1] = r.code end
    end
    return codes
end
local function inList(codes) local m = {} for i = 1, #codes do m[i] = '?' end return table.concat(m, ',') end

lib.callback.register('opslabs-towers:isp:packages', function()
    loadPackages()
    local out = {}
    for _, p in pairs(Packages) do
        if p.active == 1 and canSell(p.company_id) then
            local r = retailer(p)
            out[#out + 1] = { id = p.id, name = p.name, segment = p.segment, down = p.down_mbps, up = p.up_mbps, price = tonumber(p.price), setup = tonumber(p.setup_fee), contract = p.contract_months, ip = p.ip_mode, sla = p.sla, desc = p.description, sort = p.sort,
                provider = r.name, provider_color = r.color, own = p.company_id == nil }
        end
    end
    table.sort(out, function(a, b) if a.own ~= b.own then return a.own end if a.provider ~= b.provider then return tostring(a.provider) < tostring(b.provider) end return a.sort < b.sort end)
    return out
end)

lib.callback.register('opslabs-towers:isp:mine', function(src)
    local cust = myCustomer(src)
    if not cust then return { services = {} } end
    local out = {}
    for _, svc in ipairs(MySQL.query.await('SELECT * FROM ops_isp_services WHERE customer_id = ? AND status <> ? ORDER BY id DESC', { cust.id, 'cancelled' }) or {}) do out[#out + 1] = serviceView(svc, true) end
    local codes = retailCodes(cust.id)
    local args = { table.unpack(codes) } args[#args + 1] = cust.id
    local owed = MySQL.scalar.await(([[SELECT COALESCE(SUM(i.total), 0) FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id WHERE c.code IN (%s) AND i.customer_id = ? AND i.status = 'unpaid']]):format(inList(codes)), args) or 0
    return { services = out, owed = tonumber(owed) }
end)

lib.callback.register('opslabs-towers:isp:order', function(src, packageId, address)
    local cust, ident = myCustomer(src)
    if not cust then
        if not ident then return { error = 'No character' } end
        local id = MySQL.insert.await('INSERT INTO ops_customers (account_no, kind, name, identifier, created_at) VALUES (?, ?, ?, ?, ?)', { 'TMP' .. math.random(1, 1e9), 'residential', GetPlayerName(src), ident, now() })
        MySQL.update.await('UPDATE ops_customers SET account_no = ? WHERE id = ?', { ('C%06d'):format(id), id })
        cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { id })
    end
    local pending = MySQL.scalar.await("SELECT COUNT(*) FROM ops_isp_services WHERE customer_id = ? AND status = 'pending_install'", { cust.id }) or 0
    if pending > 0 then return { error = 'You already have an installation booked' } end
    local p = GetEntityCoords(GetPlayerPed(src))
    local id, ref = OpsIspOrder(cust.id, packageId, { name = (address and address ~= '') and tostring(address):sub(1, 160) or cust.name, x = p.x, y = p.y, z = p.z }, GetPlayerName(src))
    if not id then return { error = ref } end
    return { ok = true, ref = ref }
end)

lib.callback.register('opslabs-towers:isp:speedtest', function(src) return OpsIspSpeedtest(src) end)

lib.callback.register('opslabs-towers:isp:pay', function(src)
    local cust = myCustomer(src)
    if not cust then return { error = 'No account' } end
    local paidAny, t = 0, now()
    local codes = retailCodes(cust.id)
    local args = { table.unpack(codes) } args[#args + 1] = cust.id
    for _, inv in ipairs(MySQL.query.await(([[SELECT i.*, c.code AS co_code, c.name AS co_name FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id
        WHERE c.code IN (%s) AND i.customer_id = ? AND i.status = 'unpaid' ORDER BY i.id]]):format(inList(codes)), args) or {}) do
        if P('ChargeCustomer', cust.id, tonumber(inv.total), inv.co_name .. ' · ' .. inv.number) ~= true then break end
        MySQL.update.await("UPDATE ops_invoices SET status = 'paid', paid_at = ? WHERE id = ?", { t, inv.id })
        P('CompanyMove', inv.co_code, 'income', tonumber(inv.total), 'Invoice ' .. inv.number .. ' paid', 'invoice', inv.id, cust.name, cust.name)
        paidAny = paidAny + tonumber(inv.total)
    end
    local left = MySQL.scalar.await(([[SELECT COUNT(*) FROM ops_invoices i JOIN ops_companies c ON c.id = i.company_id WHERE c.code IN (%s) AND i.customer_id = ? AND i.status = 'unpaid']]):format(inList(codes)), args) or 0
    if left == 0 then MySQL.update.await("UPDATE ops_isp_services SET overdue_since = NULL, status = IF(status = 'suspended', 'active', status) WHERE customer_id = ?", { cust.id }) end
    if paidAny == 0 then return { error = left > 0 and 'Not enough money in your bank' or 'Nothing to pay' } end
    return { ok = true, paid = paidAny, left = left }
end)

lib.callback.register('opslabs-towers:isp:ticket', function(src, serviceId, subject, text)
    local cust = myCustomer(src)
    local svc = cust and MySQL.single.await('SELECT * FROM ops_isp_services WHERE id = ? AND customer_id = ?', { tonumber(serviceId), cust.id })
    if not svc then return { error = 'Not your line' } end
    subject = tostring(subject or 'Fault'):sub(1, 120)
    local kind = subject:lower():find('slow') and 'net_speed' or 'net_troubleshoot'
    local jid = P('CreatePlatformJob', ISP(), kind, { customer_id = cust.id, name = svc.address or cust.name, x = svc.x, y = svc.y, z = svc.z },
        { title = ('%s · %s'):format(subject, svc.ref or ''), description = tostring(text or ''):sub(1, 500), price = 0 })
    local id = MySQL.insert.await([[INSERT INTO ops_isp_tickets (service_id, customer_id, kind, subject, status, priority, job_id, messages, opened_by, created_at)
        VALUES (?, ?, 'fault', ?, 'open', ?, ?, ?, ?, ?)]], { svc.id, cust.id, subject, (Packages[svc.package_id] or {}).sla == 'standard' and 'normal' or 'high', jid,
        json.encode({ { from = cust.name, text = tostring(text or ''):sub(1, 500), at = now() } }), GetPlayerName(src), now() })
    MySQL.update('UPDATE ops_isp_tickets SET ref = ? WHERE id = ?', { ('TKT-%05d'):format(id), id })
    return { ok = true, ref = ('TKT-%05d'):format(id) }
end)

--- engineers: the line at this property (customer, package, IPs, router settings, recent tests)
lib.callback.register('opslabs-towers:isp:lookup', function(src)
    if not (IsTowerAdmin(src) or (CanCable and CanCable(src))) then return { error = 'Engineers only' } end
    local svc = serviceNear(GetEntityCoords(GetPlayerPed(src)), 45)
    if not svc then return { error = 'No OPS Network line here' } end
    local v = serviceView(svc, true)
    local cust = svcCustomer(svc)
    v.customer = cust and cust.name
    local cfg = configOf(svc.id) or {}
    v.config = cfg
    return v
end)

---------------------------------------------------------------------------
-- OPS Hub
---------------------------------------------------------------------------
--- job checks: the router settings of the line at a place (config + when it last changed)
function OpsIspConfigNear(x, y, radius)
    local best, bd
    for ont, svc in pairs(ServiceOfOnt) do
        local f = Cabling.fixtures[ont]
        if f then local d = math.sqrt((f.x - x) ^ 2 + (f.y - y) ^ 2) if d <= radius and (not bd or d < bd) then best, bd = svc, d end end
    end
    if not best then return nil end
    local nc = NetCache[best.id] or {}
    return nc.cfg, nc.cfgAt, best, nc.ips
end

function OpsIspState()
    local out = { lines = {}, outages = MySQL.query.await("SELECT * FROM ops_isp_outages ORDER BY status = 'resolved', id DESC LIMIT 30") or {} }
    for ont, svc in pairs(ServiceOfOnt) do
        local f = Cabling.fixtures[ont]
        if f then out.lines[#out.lines + 1] = { id = svc.id, ref = svc.ref, status = svc.status, line = svc.line_state, x = f.x, y = f.y } end
    end
    return out
end
function OpsIspAction(d)
    if d.action == 'activate' and tonumber(d.service) then return OpsIspActivate(tonumber(d.service), 'hub') end
    return nil, 'unknown action'
end
