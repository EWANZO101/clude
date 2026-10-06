-- OPS Cloud: customer virtual servers (sold and billed here, console at opscloud.sa in the Browser).
-- Where a VM actually runs is decided by the OPS Data centre engine (opslabs-towers server/datacentre.lua): it puts
-- each VM on a healthy 'cloud' host in its region and writes back its state (running · host_down · no_capacity …).
-- A VM gets a public IP from the OPS Cloud pool; point a domain at it and host an OPS Web site on it (self-hosted) —
-- it is reachable while the VM is running and its firewall allows port 80 / 443.

local C = (Ops and Ops.catalog and Ops.catalog.cloud) or {}
local DAY = 86400
local PERIOD = (C.periodDays or 30) * DAY
local GRACE = (C.graceDays or 5) * DAY
local PLANS, IMAGES = {}, {}
for _, p in ipairs(C.plans or {}) do PLANS[p.code] = p end
for _, i in ipairs(C.images or {}) do IMAGES[i.code] = i end

local function now() return os.time() end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function str(v, max) return Clean(tostring(v or ''), max or 80) end

CreateThread(function()
    AwaitDatabase()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'sql/ops_cloud.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
end)

--- the data centre engine's view (ops_dc_status), cached a few seconds
local statusCache, statusAt = {}, 0
function DcStatus(k)
    if now() - statusAt > 5 then
        statusCache = {}
        local ok, rows = pcall(MySQL.query.await, 'SELECT k, v, updated_at FROM ops_dc_status')
        for _, r in ipairs(ok and rows or {}) do statusCache[r.k] = { v = decode(r.v, {}), at = r.updated_at } end
        statusAt = now()
    end
    local e = statusCache[k]
    -- stale (towers stopped) = unknown: treat as no data rather than everything down
    if not e or now() - (e.at or 0) > 600 then return nil end
    return e.v
end

local function allocIp()
    local taken = {}
    for _, r in ipairs(MySQL.query.await('SELECT ip FROM ops_cloud_vms WHERE ip IS NOT NULL') or {}) do taken[r.ip] = true end
    for n = C.poolFrom or 10, C.poolTo or 250 do
        local ip = ('%s.%d'):format(C.pool or '198.18.20', n)
        if not taken[ip] then return ip end
    end
end

local function vmView(v, full)
    local fw = decode(v.firewall, { 22 })
    local out = { id = v.id, name = v.name, plan = v.plan, vcpu = v.vcpu, ram = v.ram_gb, disk = v.disk_gb, image = v.image, imageName = (IMAGES[v.image] or {}).name or v.image,
        region = v.region, ip = v.ip, desired = v.desired, state = v.state, status = v.status, price = v.price, next = v.next_bill_at, overdue = v.overdue_since,
        created = v.created_at, booted = v.booted_at, firewall = fw, host = v.host_rack and ('rack %d · U%d'):format(v.host_rack, v.host_u or 0) or nil }
    if full then
        out.log = decode(v.log, {})
        out.snapshots = MySQL.query.await('SELECT id, name, size_gb, created_at FROM ops_cloud_snapshots WHERE vm_id = ? ORDER BY id DESC', { v.id }) or {}
        out.sites = MySQL.query.await('SELECT s.id, s.title, s.host, d.name AS domain, s.published FROM ops_web_sites s LEFT JOIN ops_web_domains d ON d.id = s.domain_id WHERE s.self_ip = ?', { v.ip }) or {}
    end
    return out
end

local function staffFor(a, customerId)
    if not a or not customerId then return false end
    if Ops.isSuper(a) then return true end
    return MySQL.scalar.await([[SELECT 1 FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
        WHERE j.assigned_to = ? AND j.customer_id = ? AND j.status IN ('assigned', 'in_progress') AND c.code IN (?, ?) LIMIT 1]], { a.id, customerId, Ops.role('cloud'), Ops.role('web') }) ~= nil
end

local function cloudAction(src, phone, d, a)
    local act = d.action
    if act == 'mine' then
        local rows = MySQL.query.await("SELECT * FROM ops_cloud_vms WHERE identifier = ? AND status <> 'cancelled' ORDER BY id", { phone.identifier }) or {}
        local out = {}
        for _, v in ipairs(rows) do out[#out + 1] = vmView(v) end
        local work = {}
        if a then
            for _, j in ipairs(MySQL.query.await([[SELECT j.ref, j.title, j.customer_id, cu.name AS customer FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
                LEFT JOIN ops_customers cu ON cu.id = j.customer_id WHERE j.assigned_to = ? AND j.status IN ('assigned', 'in_progress') AND c.code IN (?, ?)]], { a.id, Ops.role('cloud'), Ops.role('web') }) or {}) do
                local vms = {}
                for _, v in ipairs(MySQL.query.await("SELECT * FROM ops_cloud_vms WHERE customer_id = ? AND status <> 'cancelled'", { j.customer_id }) or {}) do vms[#vms + 1] = vmView(v) end
                work[#work + 1] = { ref = j.ref, title = j.title, customer = j.customer, vms = vms }
            end
        end
        return { vms = out, work = work, plans = C.plans, images = C.images, capacity = DcStatus('capacity') }
    elseif act == 'create' then
        local p, img = PLANS[d.plan], IMAGES[d.image] or IMAGES.ubuntu
        if not p then return { error = 'Pick a size' } end
        local name = str(d.name, 40):lower():gsub('[^a-z0-9%-]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', ''):sub(1, 40)
        if name == '' then name = 'server' end
        local cap = DcStatus('capacity') or {}
        local region = tostring(d.region or '') ~= '' and tostring(d.region):upper():sub(1, 16) or nil
        if not region then for r in pairs(cap) do region = region or r end end
        region = region or 'LS-1'
        local ip = allocIp()
        if not ip then return { error = 'OPS Cloud is out of IP addresses' } end
        local price = (p.price or 0) + (img.extra or 0)
        local cust = Ops.customerForPlayer(src, phone)
        local ok, why = Ops.charge(cust.id, price, 'OPS Cloud · ' .. name)
        if not ok then return { error = why == 'insufficient' and ('You need $%s in the bank'):format(price) or 'Payment failed' } end
        Ops.move(Ops.role('cloud'), 'income', price, 'OPS Cloud · ' .. name, 'cloud', nil, cust.name, phone.name)
        Ops.invoice(Ops.role('cloud'), cust, ('OPS Cloud %s server · %s'):format(p.name, name), name, price, true)
        local fw = img.code == 'opsweb' and { 22, 80, 443 } or (img.code == 'windows' and { 3389 } or { 22 })
        local id = MySQL.insert.await([[INSERT INTO ops_cloud_vms (name, customer_id, identifier, owner_name, plan, vcpu, ram_gb, disk_gb, image, region, ip, desired, state, firewall, price, status, created_at, next_bill_at, log)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running', 'provisioning', ?, ?, 'active', ?, ?, ?)]],
            { name, cust.id, phone.identifier, Clean(phone.name, 80), p.code, p.vcpu, p.ram, p.disk, img.code, region, ip, json.encode(fw), price, now(), now() + PERIOD,
              json.encode({ os.date('!%Y-%m-%d %H:%M:%S') .. '  Ordered: ' .. p.name .. ' · ' .. img.name .. ' · ' .. region }) })
        return { ok = true, id = id, ip = ip, waiting = not (cap[region] and cap[region].hosts and cap[region].hosts > 0) }
    end
    if act == 'order' then              -- have OPS Cloud set it up / migrate a site: raises a job
        local t
        for _, x in ipairs(Ops.catalog.jobTypes or {}) do if x.code == d.code and x.company == Ops.role('cloud') then t = x end end
        if not t then return { error = 'Unknown service' } end
        local dom = MySQL.single.await('SELECT * FROM ops_web_domains WHERE id = ? AND identifier = ?', { tonumber(d.domain) or 0, phone.identifier })
        if not dom then return { error = 'Pick one of your domains' } end
        local cust = Ops.customerForPlayer(src, phone)
        if MySQL.scalar.await("SELECT 1 FROM ops_jobs WHERE customer_id = ? AND type = ? AND status IN ('open','assigned','in_progress') LIMIT 1", { cust.id, t.code }) then return { error = 'You already have that job open' } end
        local id, ref = Ops.job(Ops.role('cloud'), t.code, { customer_id = cust.id, address = 'Online · ' .. dom.name }, { title = t.title .. ' · ' .. dom.name, price = t.price,
            verify = { kind = t.verify.kind, domain_id = dom.id, domain = dom.name }, by = phone.name,
            description = t.desc .. (str(d.note, 300) ~= '' and ('\n\nCustomer’s brief: ' .. str(d.note, 300)) or '') })
        if not id then return { error = 'Couldn’t book it right now' } end
        return { ok = true, ref = ref, price = t.price }
    end
    local v = MySQL.single.await('SELECT * FROM ops_cloud_vms WHERE id = ?', { tonumber(d.id) or 0 })
    if not v or v.status == 'cancelled' or not (v.identifier == phone.identifier or staffFor(a, v.customer_id)) then return { error = 'Not your server' } end
    local function log(line)
        local l = decode(v.log, {})
        l[#l + 1] = os.date('!%Y-%m-%d %H:%M:%S') .. '  ' .. line
        while #l > 40 do table.remove(l, 1) end
        v.log = json.encode(l)
        MySQL.update.await('UPDATE ops_cloud_vms SET log = ? WHERE id = ?', { v.log, v.id })
    end
    if act == 'get' then return { vm = vmView(v, true) }
    elseif act == 'start' or act == 'stop' then
        if v.status ~= 'active' then return { error = 'Suspended — pay the bill first' } end
        MySQL.update.await('UPDATE ops_cloud_vms SET desired = ? WHERE id = ?', { act == 'start' and 'running' or 'stopped', v.id })
        log(act == 'start' and 'Start requested' or 'Shutdown requested')
        return { ok = true }
    elseif act == 'reboot' then
        if v.state ~= 'running' then return { error = 'It isn’t running' } end
        MySQL.update.await("UPDATE ops_cloud_vms SET booted_at = ? WHERE id = ?", { now(), v.id })
        log('Rebooted') log((IMAGES[v.image] or {}).name or v.image)
        return { ok = true }
    elseif act == 'firewall' then
        local ports, seen = {}, {}
        for _, p in ipairs(type(d.ports) == 'table' and d.ports or {}) do
            local n = math.floor(tonumber(p) or 0)
            if n >= 1 and n <= 65535 and not seen[n] and #ports < 20 then seen[n] = true ports[#ports + 1] = n end
        end
        table.sort(ports)
        MySQL.update.await('UPDATE ops_cloud_vms SET firewall = ? WHERE id = ?', { json.encode(ports), v.id })
        log('Firewall: open ' .. (#ports > 0 and table.concat(ports, ', ') or 'nothing'))
        return { ok = true }
    elseif act == 'resize' then
        local p = PLANS[d.plan]
        if not p then return { error = 'Pick a size' } end
        if p.disk < v.disk_gb then return { error = 'Disks can only grow — pick a size with at least ' .. v.disk_gb .. ' GB' } end
        local price = (p.price or 0) + ((IMAGES[v.image] or {}).extra or 0)
        MySQL.update.await("UPDATE ops_cloud_vms SET plan = ?, vcpu = ?, ram_gb = ?, disk_gb = ?, price = ?, state = IF(state = 'running', 'provisioning', state), host_rack = NULL, host_u = NULL WHERE id = ?",
            { p.code, p.vcpu, p.ram, p.disk, price, v.id })
        log(('Resized to %s (%d vCPU · %d GB) — restarting'):format(p.name, p.vcpu, p.ram))
        return { ok = true }
    elseif act == 'snapshot' then
        local n = MySQL.scalar.await('SELECT COUNT(*) FROM ops_cloud_snapshots WHERE vm_id = ?', { v.id }) or 0
        if n >= (C.maxSnapshots or 3) then return { error = ('Up to %d snapshots — delete one first'):format(C.maxSnapshots or 3) } end
        local name = str(d.name, 40) ~= '' and str(d.name, 40) or os.date('!snapshot-%Y%m%d-%H%M')
        MySQL.insert.await('INSERT INTO ops_cloud_snapshots (vm_id, name, size_gb, created_at) VALUES (?, ?, ?, ?)', { v.id, name, math.floor(v.disk_gb * (0.2 + math.random() * 0.3)), now() })
        log('Snapshot taken: ' .. name)
        return { ok = true }
    elseif act == 'restore' or act == 'snap_del' then
        local s = MySQL.single.await('SELECT * FROM ops_cloud_snapshots WHERE id = ? AND vm_id = ?', { tonumber(d.snap) or 0, v.id })
        if not s then return { error = 'No such snapshot' } end
        if act == 'snap_del' then MySQL.update.await('DELETE FROM ops_cloud_snapshots WHERE id = ?', { s.id }) log('Snapshot deleted: ' .. s.name) return { ok = true } end
        MySQL.update.await("UPDATE ops_cloud_vms SET state = IF(state = 'running', 'provisioning', state), host_rack = NULL, host_u = NULL WHERE id = ?", { v.id })
        log('Restoring snapshot ' .. s.name .. ' — restarting')
        return { ok = true }
    elseif act == 'rename' then
        local name = str(d.name, 40):lower():gsub('[^a-z0-9%-]', '-'):sub(1, 40)
        if name == '' then return { error = 'Give it a name' } end
        MySQL.update.await('UPDATE ops_cloud_vms SET name = ? WHERE id = ?', { name, v.id })
        return { ok = true }
    elseif act == 'pay' then
        if not v.overdue_since and v.status == 'active' then return { error = 'Nothing to pay' } end
        local ok, why = Ops.charge(v.customer_id, v.price, 'OPS Cloud · ' .. v.name)
        if not ok then return { error = why == 'insufficient' and 'Not enough in the bank' or 'Payment failed' } end
        Ops.move(Ops.role('cloud'), 'income', v.price, 'OPS Cloud · ' .. v.name, 'cloud', v.id, v.owner_name, phone.name)
        MySQL.update.await("UPDATE ops_cloud_vms SET status = 'active', overdue_since = NULL, next_bill_at = ? WHERE id = ?", { now() + PERIOD, v.id })
        log('Bill paid — back on')
        return { ok = true }
    elseif act == 'delete' then
        if v.identifier ~= phone.identifier then return { error = 'Only the owner can delete it' } end
        MySQL.update.await("UPDATE ops_cloud_vms SET status = 'cancelled', state = 'stopped', desired = 'stopped', ip = NULL, host_rack = NULL, host_u = NULL WHERE id = ?", { v.id })
        MySQL.update.await('DELETE FROM ops_cloud_snapshots WHERE vm_id = ?', { v.id })
        MySQL.update.await('UPDATE ops_web_sites SET self_ip = NULL WHERE self_ip = ?', { v.ip })
        return { ok = true }
    end
    return { error = 'Unknown action' }
end

Register('webCloud', function(src, phone, d) return cloudAction(src, phone, d, Ops.account(src)) end)

--- a public IP that belongs to a cloud VM: { vm row } (nil if it isn't one)
function CloudVmByIp(ip) return ip and MySQL.single.await("SELECT * FROM ops_cloud_vms WHERE ip = ? AND status <> 'cancelled'", { ip }) end
function CloudVmPorts(vm) local fw = decode(vm.firewall, {}) local s = {} for _, p in ipairs(fw) do s[tonumber(p)] = true end return s end
function CloudVmsOf(identifier) return MySQL.query.await("SELECT * FROM ops_cloud_vms WHERE identifier = ? AND status <> 'cancelled' AND ip IS NOT NULL ORDER BY id", { identifier }) or {} end

---------------------------------------------------------------------------
-- billing
---------------------------------------------------------------------------
CreateThread(function()
    AwaitDatabase()
    Wait(30000)
    while true do
        pcall(function()
            local t = now()
            for _, v in ipairs(MySQL.query.await("SELECT * FROM ops_cloud_vms WHERE status = 'active' AND next_bill_at <= ?", { t }) or {}) do
                local ok, why = Ops.charge(v.customer_id, v.price, 'OPS Cloud · ' .. v.name)
                if ok then
                    Ops.move(Ops.role('cloud'), 'income', v.price, 'OPS Cloud · ' .. v.name, 'cloud', v.id, v.owner_name, 'billing')
                    MySQL.update.await('UPDATE ops_cloud_vms SET next_bill_at = ?, overdue_since = NULL WHERE id = ?', { v.next_bill_at + PERIOD, v.id })
                elseif not v.overdue_since then
                    MySQL.update.await('UPDATE ops_cloud_vms SET overdue_since = ? WHERE id = ?', { t, v.id })
                    local src = v.identifier and GetSourceByIdentifier(v.identifier)
                    if src then Notify(src, { app = 'browser', title = 'OPS Cloud · payment failed', body = v.name .. ' will be suspended unless you pay on opscloud.sa', icon = 'fa-cloud' }) end
                elseif t - v.overdue_since > GRACE then
                    MySQL.update.await("UPDATE ops_cloud_vms SET status = 'suspended' WHERE id = ?", { v.id })
                end
            end
        end)
        Wait(300000)
    end
end)
