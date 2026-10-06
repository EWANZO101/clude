-- OPS Domains · OPS Web · OPS Trust CA — the in-game internet behind the Browser app (html/js/apps/browser.js).
--
-- A domain (name.ls, name.sa, …) is registered with OPS Domains and points somewhere with DNS:
--   A → 198.18.10.80 (OPS Web shared hosting): the site built with the OPS Web builder for that domain is served,
--   A → one of your OPS Network static IPs: you host it yourself — the line must be up and the router must forward
--       port 80 (http) / 443 (https) or the browser gets ERR_CONNECTION_TIMED_OUT / REFUSED.
-- HTTPS needs a valid certificate from OPS Trust CA (free with OPS Web hosting, or bought); without one the site is
-- "Not secure", and an expired / wrong one gets the full-page warning. Email on your domain needs an MX record
-- pointing at mx.opsweb.sa and a mailbox, which delivers into a phone's Mail app.
-- Domains, hosting and certificates renew every billing period; unpaid → expired / suspended → released.
-- Data: sql/ops_web.sql (shared with OPS Hub → OPS Web & Domains). Prices and TLDs: sql/ops_catalog.json → web.

local W = (Ops and Ops.catalog and Ops.catalog.web) or {}
local DAY = 86400
local PERIOD = (W.periodDays or 30) * DAY
local GRACE = (W.graceDays or 7) * DAY
local WARN = (W.warnDays or 3) * DAY
local SHARED_IP = W.sharedIp or '198.18.10.80'
local MAIL_IP = W.mailIp or '198.18.10.25'
local MAIL_HOST = W.mailHost or 'mx.opsweb.sa'
local CA = W.trustCa or 'OPS Trust CA'

--- OPS services that run on OPS Data servers (opslabs-towers datacentre.lua): once any server has the role, the
--- service is only up while one of them is reachable. No data / no such servers = up (nothing built yet).
local function serviceDown(role)
    local pf = DcStatus and DcStatus('platform')
    local r = pf and pf[role]
    return r ~= nil and (r.total or 0) > 0 and (r.up or 0) == 0
end

local TLDS, TLD_LIST = {}, {}
for _, t in ipairs(W.tlds or {}) do TLDS[t.tld] = t TLD_LIST[#TLD_LIST + 1] = t end
table.sort(TLD_LIST, function(a, b) return #a.tld > #b.tld end)          -- gov.sa before sa
local PLANS = {}
for _, p in ipairs(W.plans or {}) do PLANS[p.code] = p end
local CERTS = {}
for _, c in ipairs(W.certs or {}) do CERTS[c.kind] = c end
local SERVICES = {}
for _, s in ipairs(W.services or {}) do SERVICES[s.code] = s end
local INTERNAL = {}
for _, h in ipairs(W.internal or {}) do INTERNAL[h] = true end

-- site aliases: Config.Brand.Sites can give the built-in sites this server's own addresses (e.g. ops.sa → skyline.sa).
-- Requests to an alias are served by the built-in site; pages, links and search show the alias.
local function siteAliases()
    local b = OpsBrand and OpsBrand() or { Sites = {} }
    local IN, OUT = {}, {}
    for k, stock in pairs(OPS_SITE_STOCK or {}) do
        local mine = (b.Sites or {})[k]
        if mine and mine ~= stock then IN[mine] = stock OUT[stock] = mine end
    end
    return IN, OUT
end
local function aliasIn(host) local IN = siteAliases() return IN[host] or host end
local function aliasOut(host) local _, OUT = siteAliases() return OUT[host] or host end
local function isInternal(host) return INTERNAL[host] or INTERNAL[aliasIn(host)] end
local HOST_COMPANY = {}
for code, h in pairs(W.companySites or {}) do HOST_COMPANY[h] = code end
local RESERVED = {}
for _, r in ipairs(W.reserved or {}) do RESERVED[r] = true end

local function now() return os.time() end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function str(v, max) return Clean(tostring(v or ''), max or 200) end
local function lower(v) return str(v, 255):lower() end
local function money(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end

CreateThread(function()
    AwaitDatabase()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'sql/ops_web.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    local has = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ops_web_domains' AND COLUMN_NAME = 'dns_changed_at']])
    if (tonumber(has) or 0) == 0 then MySQL.query.await('ALTER TABLE ops_web_domains ADD COLUMN dns_changed_at INT NULL') end
end)

---------------------------------------------------------------------------
-- names
---------------------------------------------------------------------------
local LABEL = '^[a-z0-9][a-z0-9%-]*$'
local function validLabel(l) return type(l) == 'string' and #l >= 1 and #l <= 40 and l:match(LABEL) ~= nil and l:sub(-1) ~= '-' end

--- "shop.mybiz.ls" → "mybiz.ls", "shop", "ls"   ("mybiz.ls" → "mybiz.ls", "@", "ls")
local function parseHost(host)
    host = lower(host):gsub('%.$', '')
    for _, t in ipairs(TLD_LIST) do
        local suffix = '.' .. t.tld
        if #host > #suffix and host:sub(-#suffix) == suffix then
            local rest = host:sub(1, -#suffix - 1)
            local label = rest:match('([^%.]+)$')
            local sub = rest:sub(1, -#label - 2)
            return label .. suffix, sub ~= '' and sub or '@', t.tld, label
        end
    end
    return nil
end

local function isIp(s) local a, b, c, d = tostring(s or ''):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$') return a and tonumber(a) < 256 and tonumber(b) < 256 and tonumber(c) < 256 and tonumber(d) < 256 end
local function isHostname(s) s = tostring(s or '') return #s <= 120 and s:match('^[a-z0-9][a-z0-9%-%.]*[a-z0-9]$') ~= nil and s:find('%.') ~= nil and not s:find('%.%.') end
local function isEmail(s) return type(s) == 'string' and #s <= 100 and s:match('^[%w%._%-+]+@[%w%-]+%.[%w%.%-]+$') ~= nil end

---------------------------------------------------------------------------
-- registry + DNS
---------------------------------------------------------------------------
local function domainByName(name) return name and MySQL.single.await('SELECT * FROM ops_web_domains WHERE name = ?', { name }) end
local function domainById(id) return MySQL.single.await('SELECT * FROM ops_web_domains WHERE id = ?', { tonumber(id) or 0 }) end
local function records(domainId) return MySQL.query.await('SELECT * FROM ops_web_dns WHERE domain_id = ? ORDER BY FIELD(type, "A", "AAAA", "CNAME", "MX", "TXT"), host, prio, id', { domainId }) or {} end

--- resolve a hostname to an IPv4 address like a real resolver would (A, following CNAMEs)
--- returns ip, nil, domainRow, sub — or nil, why ('nxdomain' | 'norecord' | 'expired' | 'suspended' | 'internal'), domainRow
local function resolve(host, depth)
    depth = depth or 0
    if depth > 4 then return nil, 'norecord' end
    host = lower(host)
    if isInternal(host) then return nil, 'internal' end
    if isIp(host) then return host end
    local name, sub = parseHost(host)
    if not name then return nil, 'nxdomain' end
    if isInternal(name) then return nil, 'internal' end
    local d = domainByName(name)
    if not d then return nil, 'nxdomain' end
    if d.status == 'expired' or d.status == 'suspended' then return nil, d.status, d end
    local cname
    for _, r in ipairs(records(d.id)) do
        if r.host == sub then
            if r.type == 'A' then return r.value, nil, d, sub end
            if r.type == 'CNAME' then cname = r.value end
        end
    end
    if cname then
        local target = cname == '@' and name or (cname:find('%.') and cname or (cname .. '.' .. name))
        local ip, why = resolve(target, depth + 1)
        if ip then return ip, nil, d, sub end
        return nil, why, d
    end
    return nil, 'norecord', d
end

local function mxOf(d)
    local best
    for _, r in ipairs(records(d.id)) do
        if r.type == 'MX' and r.host == '@' and (not best or r.prio < best.prio) then best = r end
    end
    return best and best.value
end

local function touchDns(d) MySQL.update.await('UPDATE ops_web_domains SET dns_changed_at = ? WHERE id = ?', { now(), d.id }) end

--- replace the address records for host with one A (or CNAME) record
local function pointHost(d, host, value, kind)
    MySQL.update.await("DELETE FROM ops_web_dns WHERE domain_id = ? AND host = ? AND type IN ('A', 'AAAA', 'CNAME')", { d.id, host })
    MySQL.insert.await('INSERT INTO ops_web_dns (domain_id, host, type, value, ttl) VALUES (?, ?, ?, ?, 3600)', { d.id, host, kind or 'A', value })
    touchDns(d)
end

local function ensureMx(d)
    if mxOf(d) == MAIL_HOST then return end
    MySQL.update.await("DELETE FROM ops_web_dns WHERE domain_id = ? AND host = '@' AND type = 'MX'", { d.id })
    MySQL.insert.await("INSERT INTO ops_web_dns (domain_id, host, type, value, prio, ttl) VALUES (?, '@', 'MX', ?, 10, 3600)", { d.id, MAIL_HOST })
    touchDns(d)
end

---------------------------------------------------------------------------
-- certificates
---------------------------------------------------------------------------
--- the best valid certificate covering host (exact name, the bare domain for www, or a wildcard)
local function certFor(host)
    local name, sub = parseHost(host)
    if not name then return nil end
    local d = domainByName(name)
    if not d then return nil end
    local best, expired
    for _, c in ipairs(MySQL.query.await('SELECT * FROM ops_web_certs WHERE domain_id = ? AND status <> "revoked" ORDER BY expires_at DESC', { d.id }) or {}) do
        local covers = c.common_name == host or (sub == 'www' and c.common_name == name)
            or (IsTrue(c.wildcard) and (sub == '@' or not sub:find('%.')))
        if covers then
            if c.status == 'valid' and c.expires_at > now() then best = best or c else expired = expired or c end
        end
    end
    return best, expired
end

local function certView(c)
    if not c then return nil end
    return { issuer = CA, subject = c.common_name, wildcard = IsTrue(c.wildcard), kind = c.kind, org = c.org, serial = c.serial,
        issued = c.issued_at, expires = c.expires_at, status = (c.status == 'valid' and c.expires_at > now()) and 'valid' or (c.status == 'revoked' and 'revoked' or 'expired') }
end

---------------------------------------------------------------------------
-- sites: the builder's data, sanitised
---------------------------------------------------------------------------
local BLOCKS = {
    hero = { title = 80, text = 300, button = 30, href = 'href', image = 'img', align = { 'center', 'left' } },
    text = { heading = 80, body = 2000 },
    image = { url = 'img', caption = 120 },
    features = { heading = 80, items = { max = 6, fields = { icon = 'icon', title = 60, text = 240 } } },
    list = { heading = 80, items = { max = 24, fields = { name = 60, price = 20, text = 160 } } },
    gallery = { heading = 80, items = { max = 9, fields = { url = 'img', caption = 80 } } },
    contact = { heading = 80, text = 300, form = 'bool' },
    hours = { heading = 80, items = { max = 7, fields = { day = 20, time = 40 } } },
    links = { heading = 80, items = { max = 10, fields = { label = 40, href = 'href' } } },
    quote = { text = 300, by = 60 },
    cta = { title = 80, text = 200, button = 30, href = 'href' },
    divider = {},
}
local FONTS = { sans = true, serif = true, mono = true, rounded = true }

local function cleanHref(v)
    v = str(v, 200)
    if v == '' then return nil end
    if v:match('^/[a-z0-9%-]*$') or v:match('^#[%w%-]*$') then return v end
    if v:match('^https?://[%w%-%.]+[%w/%-%._~%%?&=#]*$') then return v end
    if v:match('^mailto:[%w%._%-+]+@[%w%-%.]+$') or v:match('^tel:[%d%-+ ]+$') then return v end
    return nil
end
local function cleanImg(v) v = str(v, 400) if v:match('^https://[^%s"\'<>()\\]+$') then return v end return nil end

local function cleanField(spec, v)
    if spec == 'href' then return cleanHref(v) end
    if spec == 'img' then return cleanImg(v) end
    if spec == 'bool' then return v == true or v == 1 or v == '1' end
    if spec == 'icon' then v = lower(v) return v:match('^[a-z0-9%-]+$') and #v <= 30 and v or 'star' end
    if type(spec) == 'table' then for _, o in ipairs(spec) do if v == o then return v end end return spec[1] end
    if type(spec) == 'number' then
        if type(v) ~= 'string' and type(v) ~= 'number' then return nil end
        v = tostring(v):gsub('[\0-\8\11\12\14-\31]', ''):sub(1, spec)    -- keep line breaks in body text
        return v ~= '' and v or nil
    end
end

local function cleanBlock(b)
    if type(b) ~= 'table' then return nil end
    local spec = BLOCKS[b.t]
    if not spec then return nil end
    local out = { t = b.t }
    for k, s in pairs(spec) do
        if k == 'items' then
            out.items = {}
            for i, it in ipairs(type(b.items) == 'table' and b.items or {}) do
                if i > s.max then break end
                local row = {}
                for f, fs in pairs(s.fields) do row[f] = cleanField(fs, type(it) == 'table' and it[f]) end
                out.items[#out.items + 1] = row
            end
        else
            out[k] = cleanField(s, b[k])
        end
    end
    return out
end

local function cleanSite(data)
    data = type(data) == 'table' and data or {}
    local th = type(data.theme) == 'table' and data.theme or {}
    local color = tostring(th.color or ''):match('^#%x%x%x%x%x%x$') or '#0a84ff'
    local out = {
        theme = { color = color, mode = th.mode == 'dark' and 'dark' or 'light', font = FONTS[th.font] and th.font or 'sans' },
        contact = {},
        pages = {},
    }
    local c = type(data.contact) == 'table' and data.contact or {}
    out.contact.email = isEmail(lower(c.email)) and lower(c.email) or nil
    out.contact.phone = str(c.phone, 20) ~= '' and str(c.phone, 20) or nil
    out.contact.address = str(c.address, 120) ~= '' and str(c.address, 120) or nil
    local seen = {}
    for i, p in ipairs(type(data.pages) == 'table' and data.pages or {}) do
        if #out.pages >= 8 then break end
        if type(p) == 'table' then
            local slug = i == 1 and '' or lower(p.slug):gsub('[^a-z0-9%-]', ''):sub(1, 24)
            if i > 1 and slug == '' then slug = 'page' .. i end
            if not seen[slug] then
                seen[slug] = true
                local page = { slug = slug, title = str(p.title, 40) ~= '' and str(p.title, 40) or (i == 1 and 'Home' or slug), blocks = {} }
                for _, b in ipairs(type(p.blocks) == 'table' and p.blocks or {}) do
                    if #page.blocks >= 25 then break end
                    local cb = cleanBlock(b)
                    if cb then page.blocks[#page.blocks + 1] = cb end
                end
                out.pages[#out.pages + 1] = page
            end
        end
    end
    if #out.pages == 0 then out.pages[1] = { slug = '', title = 'Home', blocks = {} } end
    return out
end

local function starterSite(title, color)
    return {
        theme = { color = color or '#0a84ff', mode = 'light', font = 'sans' },
        contact = {},
        pages = {
            { slug = '', title = 'Home', blocks = {
                { t = 'hero', title = title, text = 'Welcome to our new website.', button = 'Get in touch', href = '/contact', align = 'center' },
                { t = 'features', heading = 'What we do', items = {
                    { icon = 'star', title = 'Quality', text = 'Tell visitors what makes you great.' },
                    { icon = 'clock', title = 'Fast', text = 'Add your opening times and how quickly you respond.' },
                    { icon = 'location-dot', title = 'Local', text = 'Proudly serving Los Santos.' } } },
                { t = 'text', heading = 'About us', body = 'Write a few lines about who you are and what you offer.' },
            } },
            { slug = 'contact', title = 'Contact', blocks = { { t = 'contact', heading = 'Contact us', text = 'Send us a message and we’ll get back to you.', form = true } } },
        },
    }
end

local function blockCount(data)
    local n = 0
    for _, p in ipairs(data.pages or {}) do n = n + #(p.blocks or {}) end
    return n
end

local function siteText(data)
    local parts = {}
    local function add(v) if type(v) == 'string' then parts[#parts + 1] = v end end
    for _, p in ipairs(data.pages or {}) do
        add(p.title)
        for _, b in ipairs(p.blocks or {}) do
            for _, k in ipairs({ 'title', 'text', 'heading', 'body', 'caption', 'by' }) do add(b[k]) end
            for _, it in ipairs(b.items or {}) do for _, k in ipairs({ 'title', 'text', 'name', 'label', 'caption' }) do add(it[k]) end end
        end
    end
    return table.concat(parts, ' ')
end

---------------------------------------------------------------------------
-- who may touch what: the owner, or OPS Web / OPS Domains staff while they're on a job for that customer
---------------------------------------------------------------------------
local function staffJobFor(a, customerId)
    if not a or not customerId then return nil end
    return MySQL.single.await([[SELECT j.* FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
        WHERE j.assigned_to = ? AND j.customer_id = ? AND j.status IN ('assigned', 'in_progress') AND c.code IN (?, ?) LIMIT 1]], { a.id, customerId, Ops.role('web'), Ops.role('domains') })
end

local function mayManage(phone, a, row)
    if not row then return false end
    if row.identifier and row.identifier == phone.identifier then return true end
    if a and Ops.isSuper(a) then return true end
    return staffJobFor(a, row.customer_id) ~= nil
end

local function ownerSrc(row) return row and row.identifier and GetSourceByIdentifier(row.identifier) end
local function ownerEmail(row) return row and row.identifier and MySQL.scalar.await('SELECT email FROM opslabs_phone_users WHERE identifier = ? LIMIT 1', { row.identifier }) end

local function tellOwner(row, title, body, app)
    local email = ownerEmail(row)
    if email then SendMail(email, title:match('^OPS %a+') or 'OPS Domains', title, body, 'noreply@opsdomains.sa') end
    local src = ownerSrc(row)
    if src then Notify(src, { app = app or 'browser', title = title, body = body:sub(1, 140), icon = 'fa-globe' }) end
end

--- money: take it from the player's customer account → OPS company income + a paid invoice
local function pay(src, phone, company, amount, label, ref)
    local cust = Ops.customerForPlayer(src, phone)
    amount = money(amount)
    if amount > 0 then
        local ok, why = Ops.charge(cust.id, amount, label)
        if not ok then return nil, why == 'insufficient' and ('You need $%s in the bank'):format(amount) or 'Payment failed' end
        Ops.move(company, 'income', amount, label, 'web', nil, cust.name, phone.name)
        Ops.invoice(company, cust, label, ref, amount, true)
    end
    return cust
end

--- billing for renewals (owner may be offline) → ok, why
local function payRow(row, company, amount, label, ref)
    amount = money(amount)
    if amount <= 0 then return true end
    if not row.customer_id then return false, 'no customer' end
    local ok, why = Ops.charge(row.customer_id, amount, label)
    if not ok then return false, why end
    local cust = MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { row.customer_id })
    Ops.move(company, 'income', amount, label, 'web', row.id, cust and cust.name, 'billing')
    Ops.invoice(company, cust, label, ref, amount, true)
    return true
end

---------------------------------------------------------------------------
-- self-hosting on an OPS Network line
---------------------------------------------------------------------------
local function ispByIp(ip)
    return MySQL.single.await([[SELECT i.ip, s.id AS service_id, s.status, s.line_state, s.customer_id, c.config
        FROM ops_isp_ips i JOIN ops_isp_services s ON s.id = i.service_id LEFT JOIN ops_isp_config c ON c.service_id = s.id WHERE i.ip = ?]], { ip })
end

local function myIps(phone)
    local ok, rows = pcall(MySQL.query.await, [[SELECT i.ip, i.pool, s.ref, s.status, s.line_state FROM ops_isp_ips i JOIN ops_isp_services s ON s.id = i.service_id
        JOIN ops_customers c ON c.id = s.customer_id WHERE c.identifier = ? AND i.pool <> 'dynamic' AND s.status <> 'cancelled' ORDER BY INET_ATON(i.ip)]], { phone.identifier })
    rows = ok and rows or {}
    for _, v in ipairs(CloudVmsOf and CloudVmsOf(phone.identifier) or {}) do
        rows[#rows + 1] = { ip = v.ip, pool = 'cloud', ref = 'OPS Cloud · ' .. v.name, status = v.status, line_state = v.state == 'running' and 'up' or 'down' }
    end
    return rows
end

--- which ports the router forwards (tcp 80 / 443)
local function forwarded(cfgJson)
    local cfg = decode(cfgJson, {})
    local open = {}
    for _, f in ipairs(cfg.forwards or {}) do
        local proto = tostring(f.proto or 'tcp'):lower()
        if proto == 'tcp' or proto == 'both' or proto == 'any' or proto == 'tcp/udp' then open[tonumber(f.ext) or 0] = true end
    end
    return open[80] == true, open[443] == true
end

---------------------------------------------------------------------------
-- the browser: url → what to show
---------------------------------------------------------------------------
local function errorPage(code, host, extra)
    local E = {
        DNS_PROBE_FINISHED_NXDOMAIN = { 'This site can’t be reached', ('%s’s server IP address could not be found.'):format(host), 'Check the address for typos, or search for it instead.' },
        ERR_NAME_NOT_RESOLVED = { 'This site can’t be reached', ('%s has no address record.'):format(host), 'The domain is registered but its DNS doesn’t point anywhere for this name.' },
        ERR_CONNECTION_TIMED_OUT = { 'This site can’t be reached', ('%s took too long to respond.'):format(host), 'The server may be offline, or its internet connection is down.' },
        ERR_CONNECTION_REFUSED = { 'This site can’t be reached', ('%s refused to connect.'):format(host), 'The server is online but isn’t accepting web connections (is the port forwarded?).' },
        ERR_NAME_RESOLUTION_FAILED = { 'This site can’t be reached', ('%s’s DNS lookup failed.'):format(host), 'OPS DNS isn’t answering right now — the servers that run it are down.' },
        ERR_INVALID_URL = { 'That isn’t a web address', 'Type a site like opsweb.sa, or search for it.', '' },
    }
    local e = E[code] or { 'Something went wrong', host or '', '' }
    return { kind = 'error', code = code, title = e[1], text = e[2], hint = extra or e[3], host = host }
end

local function parseUrl(url)
    url = tostring(url or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local scheme, rest = url:match('^(%a+)://(.*)$')
    if not scheme then rest = url end
    scheme = scheme and scheme:lower()
    if scheme and scheme ~= 'http' and scheme ~= 'https' then return nil end
    local host, path = rest:match('^([^/?#]+)(.*)$')
    if not host then return nil end
    host = host:lower():gsub(':%d+$', ''):gsub('%.$', '')
    if not (isIp(host) or isHostname(host)) then return nil end
    path = path:match('^([^?#]*)') or ''
    path = path:gsub('/+$', '')
    if path == '' then path = '/' end
    if #path > 80 then return nil end
    return scheme, host, path
end

local function companyData(code)
    local c = Ops.company(code)
    if not c then return nil end
    local services = {}
    for _, t in ipairs(Ops.catalog.jobTypes or {}) do
        if t.company == code then services[#services + 1] = { title = t.title, desc = t.desc, price = t.price } end
    end
    local done = MySQL.scalar.await("SELECT COUNT(*) FROM ops_jobs WHERE company_id = ? AND status = 'completed'", { c.id }) or 0
    local staff = MySQL.scalar.await("SELECT COUNT(*) FROM ops_members WHERE company_id = ? AND status = 'active'", { c.id }) or 0
    local data = { code = code, name = c.name, tagline = c.tagline, color = c.color, icon = c.icon, services = services, completed = done, staff = staff }
    if code == 'data' then data.halls = DcStatus and DcStatus('halls') or {} data.platform = DcStatus and DcStatus('platform') or {} end
    local isp = code == Ops.role('isp')
    if isp then
        local ok, rows = pcall(MySQL.query.await, "SELECT ref, title, area, status, planned, started_at FROM ops_isp_outages WHERE status <> 'resolved' ORDER BY id DESC LIMIT 6")
        data.outages = ok and rows or {}
    end
    -- broadband packages: the ISP's own, or a sub-company's while it leases fibre access (server/market.lua)
    if isp or (Market and Market.canSell(c.id, 'fibre_access')) then
        local ok2, pk = pcall(MySQL.query.await, 'SELECT name, segment, down_mbps, up_mbps, price, description FROM ops_isp_packages WHERE active = 1 AND '
            .. (isp and 'company_id IS NULL' or 'company_id = ?') .. ' ORDER BY sort', isp and {} or { c.id })
        data.packages = ok2 and pk or {}
    end
    return data
end

local function internalPage(host, path, phone)
    local data = { host = host, path = path }
    if host == 'ops.sa' or host == 'search.sa' then
        data.app = 'search'
        data.popular = MySQL.query.await([[SELECT s.title, s.description, d.name AS domain, s.host FROM ops_web_sites s JOIN ops_web_domains d ON d.id = s.domain_id
            WHERE s.published = 1 AND s.noindex = 0 AND s.status = 'ok' AND d.status = 'active' ORDER BY s.views DESC LIMIT 6]]) or {}
    elseif host == 'opsdomains.sa' or host == 'whois.sa' then
        data.app = 'domains'
        data.tlds = W.tlds
        data.certs = W.certs
        if host == 'whois.sa' then data.path = '/whois' end
    elseif host == 'opsweb.sa' then
        data.app = 'web'
        data.plans = W.plans
        data.services = W.services
        data.sharedIp, data.mailHost = SHARED_IP, MAIL_HOST
    elseif host == 'opsacademy.sa' then
        data.app = 'academy'          -- everything is fetched by the page itself (opsAcademy / opsLesson / opsSystem / opsSlides)
    elseif host == 'opscloud.sa' then
        data.app = 'cloud'
        local cl = Ops.catalog.cloud or {}
        data.plans, data.images, data.capacity = cl.plans, cl.images, DcStatus and DcStatus('capacity') or {}
    elseif HOST_COMPANY[host] then
        data.app = 'company'
        data.company = companyData(HOST_COMPANY[host])
    end
    local shown = aliasOut(host)
    return { kind = 'internal', url = 'https://' .. shown .. (path ~= '/' and path or ''), host = shown, secure = true,
        cert = { issuer = CA, subject = shown, kind = 'ev', org = (OpsBrand and OpsBrand().Group) or 'OPS Group', status = 'valid' }, data = data }
end

local function servePage(site, path, host, ip, secure, cert, hosted, phone)
    local data = cleanSite(decode(site.data, {}))
    local slug = path:gsub('^/', '')
    local page
    for _, p in ipairs(data.pages) do if p.slug == slug then page = p end end
    local nav = {}
    for _, p in ipairs(data.pages) do nav[#nav + 1] = { slug = p.slug, title = p.title } end
    if site.identifier ~= phone.identifier then MySQL.update('UPDATE ops_web_sites SET views = views + 1 WHERE id = ?', { site.id }) end
    return {
        kind = 'site', url = (secure and 'https://' or 'http://') .. host .. (path ~= '/' and path or ''), host = host, ip = ip, secure = secure,
        cert = certView(cert), hosted = hosted,
        site = { id = site.id, title = site.title, description = site.description, theme = data.theme, contact = data.contact, nav = nav,
            owner = site.owner_name, form = data.contact.email ~= nil or site.identifier ~= nil },
        page = page and { slug = page.slug, title = page.title, blocks = page.blocks } or nil,
        notFound = page == nil,
    }
end

local function browse(phone, url, proceed)
    local scheme, host, path = parseUrl(url)
    if not host then return errorPage('ERR_INVALID_URL', tostring(url or '')) end
    local bare = aliasIn((host:gsub('^www%.', '')))
    if INTERNAL[bare] then return internalPage(bare, path, phone) end
    if not isIp(host) and serviceDown('dns') then return errorPage('ERR_NAME_RESOLUTION_FAILED', host) end
    local ip, why, d = resolve(host)
    if not ip then
        if why == 'expired' or why == 'suspended' then
            return { kind = 'parked', reason = why, host = host, url = 'http://' .. host, secure = false, domain = d and d.name }
        end
        return errorPage(why == 'norecord' and 'ERR_NAME_NOT_RESOLVED' or 'DNS_PROBE_FINISHED_NXDOMAIN', host)
    end
    local name, sub = parseHost(host)
    d = d or (name and domainByName(name))

    -- where does the IP go?
    local site, hosted, httpOk, httpsOk
    local vm = ip ~= SHARED_IP and ip ~= MAIL_IP and CloudVmByIp and CloudVmByIp(ip) or nil
    if ip == SHARED_IP then
        if serviceDown('opsweb') then return errorPage('ERR_CONNECTION_TIMED_OUT', host, 'OPS Web’s hosting servers are down — OPS Data is on it.') end
        hosted, httpOk, httpsOk = 'OPS Web', true, true
        if d then
            site = MySQL.single.await([[SELECT s.*, h.status AS hosting_status FROM ops_web_sites s LEFT JOIN ops_web_hosting h ON h.id = s.hosting_id
                WHERE s.domain_id = ? AND s.hosting_id IS NOT NULL AND (s.host = ? OR (s.host = '@' AND ? = 'www')) ORDER BY s.host = ? DESC LIMIT 1]], { d.id, sub, sub, sub })
        end
        if not site then return { kind = 'parked', reason = 'parked', host = host, url = 'http://' .. host, secure = false, domain = name } end
        if site.hosting_status ~= 'active' then return { kind = 'parked', reason = 'hosting', host = host, url = 'http://' .. host, secure = false, domain = name } end
    elseif ip == MAIL_IP then
        return errorPage('ERR_CONNECTION_REFUSED', host, 'That address is a mail server, not a website.')
    elseif vm then
        if vm.state ~= 'running' then return errorPage('ERR_CONNECTION_TIMED_OUT', host) end
        local ports = CloudVmPorts(vm)
        httpOk, httpsOk = ports[80] == true, ports[443] == true
        if not httpOk and not httpsOk then return errorPage('ERR_CONNECTION_REFUSED', host, 'The server’s firewall blocks web traffic — open ports 80 / 443.') end
        hosted = 'OPS Cloud · ' .. (vm.region or '')
        site = MySQL.single.await([[SELECT * FROM ops_web_sites WHERE self_ip = ? AND hosting_id IS NULL
            ORDER BY (domain_id = ? AND (host = ? OR (host = '@' AND ? = 'www'))) DESC, id LIMIT 1]], { ip, d and d.id or 0, sub or '@', sub or '@' })
        if not site then return { kind = 'parked', reason = 'default_server', host = host, ip = ip, url = 'http://' .. host, secure = false } end
    else
        local line = ispByIp(ip)
        if not line or line.status ~= 'active' or line.line_state == 'down' then return errorPage('ERR_CONNECTION_TIMED_OUT', host) end
        httpOk, httpsOk = forwarded(line.config)
        if not httpOk and not httpsOk then return errorPage('ERR_CONNECTION_REFUSED', host) end
        hosted = 'Self-hosted · OPS Network'
        site = MySQL.single.await([[SELECT * FROM ops_web_sites WHERE self_ip = ? AND hosting_id IS NULL
            ORDER BY (domain_id = ? AND (host = ? OR (host = '@' AND ? = 'www'))) DESC, id LIMIT 1]], { ip, d and d.id or 0, sub or '@', sub or '@' })
        if not site then return { kind = 'parked', reason = 'default_server', host = host, ip = ip, url = 'http://' .. host, secure = false } end
    end
    if site.status == 'taken_down' then return { kind = 'parked', reason = 'takedown', host = host, url = 'http://' .. host, secure = false, note = site.takedown_reason } end
    if not IsTrue(site.published) and site.identifier ~= phone.identifier then return { kind = 'parked', reason = 'coming_soon', host = host, url = 'http://' .. host, secure = false, title = site.title } end

    -- TLS
    local cert, bad = nil, nil
    if httpsOk then cert, bad = certFor(host) end
    if scheme == 'https' and not cert and not proceed then
        if not httpsOk then return errorPage('ERR_CONNECTION_REFUSED', host, 'Nothing is listening on port 443 (https). Try http:// instead.') end
        return { kind = 'interstitial', host = host, url = 'https://' .. host .. (path ~= '/' and path or ''),
            code = bad and (bad.status == 'revoked' and 'NET::ERR_CERT_REVOKED' or 'NET::ERR_CERT_DATE_INVALID') or 'NET::ERR_CERT_COMMON_NAME_INVALID',
            cert = certView(bad) }
    end
    local secure = cert ~= nil and scheme ~= 'http'
    if not httpOk and not secure and not proceed then return errorPage('ERR_CONNECTION_REFUSED', host, 'Port 80 (http) isn’t forwarded on the server’s router.') end
    local r = servePage(site, path, host, ip, secure, cert, hosted, phone)
    r.warning = proceed and not secure and scheme == 'https' or nil
    return r
end

---------------------------------------------------------------------------
-- search
---------------------------------------------------------------------------
local index, indexAt = nil, 0
local INTERNAL_PAGES = {
    { url = 'https://opsdomains.sa', title = 'OPS Domains — register your .ls, .sa, .biz domain', text = 'domain names registration register buy whois dns ssl certificate transfer .ls .sa .biz .shop .club' },
    { url = 'https://opsdomains.sa/whois', title = 'WHOIS lookup — OPS Domains', text = 'whois lookup who owns domain registrant expiry' },
    { url = 'https://opsweb.sa', title = 'OPS Web — websites, hosting and business email', text = 'website builder hosting web design email mailbox ssl business site make a website' },
    { url = 'https://ops.sa', title = 'OPS Search', text = 'search engine' },
    { url = 'https://opsacademy.sa', title = 'OPS Academy — learn every OPS job, free', text = 'training course courses learn lesson lessons exam certificate certification health safety job jobs how to engineer academy classroom tutorial guide' },
    { url = 'https://opsacademy.sa/systems', title = 'How the OPS systems work — OPS Academy', text = 'how it works system explainer network power grid fibre mobile cctv data centre cloud internet' },
    { url = 'https://opsacademy.sa/slides', title = 'Slideshow courses — OPS Academy', text = 'slideshow configure configuration settings first job' },
}

local function buildIndex()
    if index and now() - indexAt < 60 then return index end
    index = {}
    for _, p in ipairs(INTERNAL_PAGES) do index[#index + 1] = { url = p.url:gsub('https://([^/]+)', function(h) return 'https://' .. aliasOut(h) end), title = p.title, desc = '', text = p.text:lower(), titleL = p.title:lower(), secure = true, boost = 1 } end
    for code, host in pairs(W.companySites or {}) do
        local c = Ops.company(code)
        if c then
            local txt = { c.name, c.tagline or '' }
            for _, t in ipairs(Ops.catalog.jobTypes or {}) do if t.company == code then txt[#txt + 1] = t.title .. ' ' .. (t.desc or '') end end
            index[#index + 1] = { url = 'https://' .. host, title = c.name .. ' — ' .. (c.tagline or ''), desc = c.tagline or '', text = table.concat(txt, ' '):lower(), titleL = c.name:lower(), secure = true, boost = 1.2 }
        end
    end
    local rows = MySQL.query.await([[SELECT s.*, d.name AS domain FROM ops_web_sites s JOIN ops_web_domains d ON d.id = s.domain_id
        WHERE s.published = 1 AND s.noindex = 0 AND s.status = 'ok' AND d.status = 'active']]) or {}
    for _, s in ipairs(rows) do
        local host = (s.host == '@' and '' or (s.host .. '.')) .. s.domain
        local ip = resolve(host)
        if ip then
            local data = cleanSite(decode(s.data, {}))
            local cert = certFor(host)
            index[#index + 1] = { url = (cert and 'https://' or 'http://') .. host, title = s.title, desc = s.description or '', titleL = s.title:lower(),
                text = (s.title .. ' ' .. (s.description or '') .. ' ' .. (s.keywords or '') .. ' ' .. host .. ' ' .. siteText(data)):lower(),
                secure = cert ~= nil, color = data.theme.color, boost = 1 + math.min(1, (s.views or 0) / 200) }
        end
    end
    indexAt = now()
    return index
end

local function search(q)
    q = lower(q):sub(1, 80)
    local terms = {}
    for w in q:gmatch('[%w%.%-]+') do if #w >= 2 and #terms < 8 then terms[#terms + 1] = w end end
    if #terms == 0 then return { results = {} } end
    local out = {}
    for _, e in ipairs(buildIndex()) do
        local score = 0
        for _, t in ipairs(terms) do
            local plain = t:gsub('%p', '%%%0')
            if e.titleL:find(plain) then score = score + 6 end
            if e.url:find(plain) then score = score + 5 end
            if e.desc:lower():find(plain) then score = score + 3 end
            local _, n = e.text:gsub(plain, '')
            score = score + math.min(n, 5)
        end
        if score > 0 then
            local snippet = e.desc ~= '' and e.desc or ''
            if snippet == '' then
                local pos = e.text:find((terms[1]:gsub('%p', '%%%0')))
                snippet = pos and e.text:sub(math.max(1, pos - 60), pos + 120) or ''
            end
            out[#out + 1] = { url = e.url, title = e.title, snippet = snippet, secure = e.secure, color = e.color, score = score * (e.boost or 1) }
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    local res = {}
    for i = 1, math.min(#out, 20) do res[i] = out[i] end
    return { results = res, total = #out }
end

---------------------------------------------------------------------------
-- RPCs: browsing
---------------------------------------------------------------------------
Register('webBrowse', function(_, phone, d) return browse(phone, d.url, d.proceed == true) end)
Register('webSearch', function(_, _, d) return search(d.q) end)

local formAt = {}
Register('webForm', function(src, phone, d)
    if formAt[src] and now() - formAt[src] < 30 then return { error = 'Please wait a moment before sending another message.' } end
    local r = browse(phone, d.url, true)
    if r.kind ~= 'site' then return { error = 'This site isn’t reachable any more.' } end
    local site = MySQL.single.await('SELECT * FROM ops_web_sites WHERE id = ?', { r.site.id })
    local data = cleanSite(decode(site.data, {}))
    local to = data.contact.email or ownerEmail(site)
    if not to then return { error = 'This site doesn’t accept messages.' } end
    local body = ('From: %s <%s>\nPhone: %s\nPage: %s\n\n%s'):format(str(d.name, 60), str(d.email, 100), phone.number, r.url, str(d.message, 1500))
    formAt[src] = now()
    if WebDeliverable(to) then SendMail(to, 'Website · ' .. site.title, 'New message from your website', body, 'forms@opsweb.sa') end
    return { ok = true }
end)
AddEventHandler('playerDropped', function() formAt[source] = nil end)

---------------------------------------------------------------------------
-- RPCs: OPS Domains (registrar)
---------------------------------------------------------------------------
local function domainView(d, full)
    local v = { id = d.id, name = d.name, tld = d.tld, status = d.status, auto = IsTrue(d.auto_renew), privacy = IsTrue(d.privacy), locked = IsTrue(d.locked),
        created = d.created_at, expires = d.expires_at, owner = d.owner_name, price = (TLDS[d.tld] or {}).price or 0 }
    if full then
        v.records = records(d.id)
        v.transferCode = d.transfer_code
        v.mx = mxOf(d)
        local c = MySQL.single.await('SELECT * FROM ops_web_certs WHERE domain_id = ? AND status = "valid" AND expires_at > ? ORDER BY expires_at DESC LIMIT 1', { d.id, now() })
        v.cert = certView(c)
    end
    return v
end

local function whois(name)
    name = lower(name)
    local d = domainByName(name)
    if isInternal(name) then return { name = name, registered = true, registrar = 'OPS Domains', registrant = 'OPS Group', status = 'reserved', nameservers = W.nameservers } end
    if not d then return { name = name, registered = false } end
    return { name = d.name, registered = true, registrar = 'OPS Domains', status = d.status, created = d.created_at, expires = d.expires_at,
        registrant = IsTrue(d.privacy) and 'REDACTED FOR PRIVACY' or d.owner_name, locked = IsTrue(d.locked), nameservers = W.nameservers }
end

local function checkName(label, kind)
    label = lower(label):gsub('^https?://', ''):gsub('^www%.', '')
    local full = parseHost(label)
    if full then label = full:match('^([^%.]+)') end
    label = label:gsub('%..*$', '')
    if not validLabel(label) then return { error = 'Use letters, numbers and dashes (up to 40), no spaces.' } end
    local out = { label = label, list = {} }
    for _, t in ipairs(W.tlds or {}) do
        local name = label .. '.' .. t.tld
        local taken = isInternal(name) or RESERVED[label] or domainByName(name) ~= nil
        local restricted = t.restricted and not (kind and table.concat(t.restricted, ','):find(kind, 1, true)) or false
        out.list[#out.list + 1] = { name = name, tld = t.tld, price = t.price, available = not taken and not restricted, taken = taken, restricted = restricted and t.restricted or nil, desc = t.desc }
    end
    return out
end

local DNS_TYPES = { A = true, AAAA = true, CNAME = true, MX = true, TXT = true }
local function cleanRecord(r, d)
    if type(r) ~= 'table' then return nil, 'Bad record' end
    local host = lower(r.host) if host == '' then host = '@' end
    if host ~= '@' and not host:match('^[a-z0-9_%*][a-z0-9_%-%.]*$') then return nil, 'Host must be @ or a name like www' end
    if #host > 63 then return nil, 'Host too long' end
    local t = tostring(r.type or ''):upper()
    if not DNS_TYPES[t] then return nil, 'Type must be A, AAAA, CNAME, MX or TXT' end
    local v = str(r.value, 255)
    if t == 'A' and not isIp(v) then return nil, 'A records need an IPv4 address' end
    if t == 'AAAA' and not v:match('^[%x:]+$') then return nil, 'AAAA records need an IPv6 address' end
    if (t == 'CNAME' or t == 'MX') then
        v = v:lower()
        if not (v == '@' or isHostname(v) or v:match('^[a-z0-9%-]+$')) then return nil, t .. ' needs a hostname' end
        if t == 'CNAME' and host == '@' then return nil, 'The bare domain (@) can’t be a CNAME — use an A record' end
    end
    if t == 'TXT' and v == '' then return nil, 'TXT needs a value' end
    return { host = host, type = t, value = v, prio = math.max(0, math.min(100, math.floor(tonumber(r.prio) or 10))), ttl = math.max(60, math.min(86400, math.floor(tonumber(r.ttl) or 3600))) }
end

local function domAction(src, phone, d, a)
    local act = d.action
    if act == 'check' then
        local cust = MySQL.single.await('SELECT kind FROM ops_customers WHERE identifier = ? LIMIT 1', { phone.identifier })
        return checkName(d.name, cust and cust.kind or 'residential')
    elseif act == 'whois' then
        local name = parseHost(lower(d.name)) or lower(d.name)
        return whois(name)
    elseif act == 'mine' then
        local rows = MySQL.query.await('SELECT * FROM ops_web_domains WHERE identifier = ? ORDER BY name', { phone.identifier }) or {}
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = domainView(r) end
        local work = {}
        if a then
            for _, j in ipairs(MySQL.query.await([[SELECT j.ref, j.title, j.customer_id, cu.name AS customer FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
                LEFT JOIN ops_customers cu ON cu.id = j.customer_id WHERE j.assigned_to = ? AND j.status IN ('assigned', 'in_progress') AND c.code IN (?, ?)]], { a.id, Ops.role('web'), Ops.role('domains') }) or {}) do
                local doms = {}
                for _, r in ipairs(MySQL.query.await('SELECT * FROM ops_web_domains WHERE customer_id = ?', { j.customer_id }) or {}) do doms[#doms + 1] = domainView(r) end
                work[#work + 1] = { ref = j.ref, title = j.title, customer = j.customer, domains = doms }
            end
        end
        return { domains = out, work = work }
    elseif act == 'register' then
        local name, sub, tld, label = parseHost(lower(d.name))
        if not name or sub ~= '@' then return { error = 'Pick a name like yourname.ls' } end
        local chk = checkName(label, (MySQL.single.await('SELECT kind FROM ops_customers WHERE identifier = ? LIMIT 1', { phone.identifier }) or {}).kind or 'residential')
        for _, x in ipairs(chk.list or {}) do
            if x.name == name and not x.available then return { error = x.restricted and 'That ending is only for government and emergency services' or (name .. ' is taken') } end
        end
        local years = math.max(1, math.min(5, math.floor(tonumber(d.years) or 1)))
        local price = (TLDS[tld].price or 0) * years
        local cust, err = pay(src, phone, Ops.role('domains'), price, 'Domain registration · ' .. name, name)
        if not cust then return { error = err } end
        local ok, id = pcall(MySQL.insert.await, [[INSERT INTO ops_web_domains (name, tld, customer_id, identifier, owner_name, status, auto_renew, privacy, locked, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?, 'active', 1, 1, 1, ?, ?)]], { name, tld, cust.id, phone.identifier, Clean(phone.name, 80), now(), now() + PERIOD * years })
        if not ok or not id then return { error = name .. ' was just taken' } end
        MySQL.insert.await("INSERT INTO ops_web_dns (domain_id, host, type, value) VALUES (?, '@', 'A', ?), (?, 'www', 'CNAME', '@')", { id, SHARED_IP, id })
        Ops.audit(phone.name, Ops.company('domains') and Ops.company('domains').id, 'domain.register', name, ('%d period(s) · $%s'):format(years, price))
        SendMail(phone.email, 'OPS Domains', 'You registered ' .. name, ('%s is yours until %s.\n\nPoint it at a website on opsweb.sa, or set your own DNS on opsdomains.sa → My domains.\n\nNameservers: %s')
            :format(name, os.date('%d %b %Y', now() + PERIOD * years), table.concat(W.nameservers or {}, ', ')), 'noreply@opsdomains.sa')
        indexAt = 0
        return { ok = true, id = id, name = name, price = price }
    elseif act == 'accept' then           -- receive a domain transfer with its code
        local dom = domainByName(lower(d.name))
        if not dom or not dom.transfer_code or IsTrue(dom.locked) or dom.transfer_code ~= str(d.code, 16):upper() then return { error = 'That code doesn’t match (or the domain is still locked)' } end
        if dom.identifier == phone.identifier then return { error = 'You already own it' } end
        local cust = Ops.customerForPlayer(src, phone)
        local from = dom.owner_name
        MySQL.update.await('UPDATE ops_web_domains SET identifier = ?, customer_id = ?, owner_name = ?, transfer_code = NULL, locked = 1 WHERE id = ?', { phone.identifier, cust.id, Clean(phone.name, 80), dom.id })
        MySQL.update.await('UPDATE ops_web_sites SET domain_id = NULL WHERE domain_id = ? AND (identifier IS NULL OR identifier <> ?)', { dom.id, phone.identifier })
        tellOwner(dom, 'OPS Domains · transfer complete', ('%s has been transferred to %s.'):format(dom.name, phone.name))
        Ops.audit(phone.name, nil, 'domain.transfer', dom.name, 'from ' .. tostring(from))
        return { ok = true }
    end

    -- the rest act on one domain you manage
    local dom = domainById(d.id)
    if not dom or not mayManage(phone, a, dom) then return { error = 'Not your domain' } end
    if act == 'get' then return { domain = domainView(dom, true) }
    elseif act == 'renew' then
        local years = math.max(1, math.min(5, math.floor(tonumber(d.years) or 1)))
        local price = ((TLDS[dom.tld] or {}).price or 0) * years
        local cust, err = pay(src, phone, Ops.role('domains'), price, 'Domain renewal · ' .. dom.name, dom.name)
        if not cust then return { error = err } end
        local base = math.max(dom.expires_at, dom.status == 'expired' and now() or dom.expires_at)
        MySQL.update.await("UPDATE ops_web_domains SET expires_at = ?, status = IF(status = 'expired', 'active', status), warned_at = NULL WHERE id = ?", { base + PERIOD * years, dom.id })
        return { ok = true }
    elseif act == 'set' then
        local f, v = d.field, d.value == true
        local col = ({ auto = 'auto_renew', privacy = 'privacy', locked = 'locked' })[f]
        if not col then return { error = 'Unknown setting' } end
        MySQL.update.await(('UPDATE ops_web_domains SET %s = ?%s WHERE id = ?'):format(col, col == 'locked' and v and ', transfer_code = NULL' or ''), { v and 1 or 0, dom.id })
        return { ok = true }
    elseif act == 'transfer_code' then
        if dom.identifier ~= phone.identifier then return { error = 'Only the owner can transfer it' } end
        local code = ('%04X%04X'):format(math.random(0, 0xffff), math.random(0, 0xffff))
        MySQL.update.await('UPDATE ops_web_domains SET locked = 0, transfer_code = ? WHERE id = ?', { code, dom.id })
        return { ok = true, code = code }
    elseif act == 'dns_add' or act == 'dns_edit' then
        if dom.status == 'suspended' then return { error = 'This domain is suspended' } end
        local r, err = cleanRecord(d.record, dom)
        if not r then return { error = err } end
        local count = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_dns WHERE domain_id = ?', { dom.id }) or 0
        if act == 'dns_add' and count >= 40 then return { error = 'Up to 40 records per domain' } end
        local others = MySQL.query.await('SELECT id, type FROM ops_web_dns WHERE domain_id = ? AND host = ? AND id <> ?', { dom.id, r.host, tonumber(d.rid) or 0 }) or {}
        for _, o in ipairs(others) do
            if r.type == 'CNAME' or o.type == 'CNAME' then
                if not (r.type == 'MX' or o.type == 'MX' or r.type == 'TXT' or o.type == 'TXT') or r.type == 'CNAME' then return { error = 'A CNAME can’t share its name with other records' } end
            end
        end
        if act == 'dns_add' then
            MySQL.insert.await('INSERT INTO ops_web_dns (domain_id, host, type, value, prio, ttl) VALUES (?, ?, ?, ?, ?, ?)', { dom.id, r.host, r.type, r.value, r.prio, r.ttl })
        else
            MySQL.update.await('UPDATE ops_web_dns SET host = ?, type = ?, value = ?, prio = ?, ttl = ? WHERE id = ? AND domain_id = ?', { r.host, r.type, r.value, r.prio, r.ttl, tonumber(d.rid), dom.id })
        end
        touchDns(dom)
        indexAt = 0
        return { ok = true }
    elseif act == 'dns_del' then
        MySQL.update.await('DELETE FROM ops_web_dns WHERE id = ? AND domain_id = ?', { tonumber(d.rid), dom.id })
        touchDns(dom)
        indexAt = 0
        return { ok = true }
    end
    return { error = 'Unknown action' }
end

Register('webDomains', function(src, phone, d) return domAction(src, phone, d, Ops.account(src)) end)

---------------------------------------------------------------------------
-- RPCs: OPS Web (hosting, sites, SSL, email)
---------------------------------------------------------------------------
local function hostingFor(identifier) return MySQL.query.await("SELECT * FROM ops_web_hosting WHERE identifier = ? AND status <> 'cancelled' ORDER BY id", { identifier }) or {} end

local function limitsOf(identifier)
    local sites, boxes, ssl = 0, 0, nil
    for _, h in ipairs(hostingFor(identifier)) do
        if h.status == 'active' then
            local p = PLANS[h.plan] or {}
            sites, boxes = sites + (p.sites or 0), boxes + (p.mailboxes or 0)
            if p.ssl == 'ov' or (p.ssl == 'dv' and ssl ~= 'ov') then ssl = p.ssl end
        end
    end
    return sites, boxes, ssl
end

local function siteView(s, full)
    local dom = s.domain_id and domainById(s.domain_id)
    local host = dom and ((s.host == '@' and '' or (s.host .. '.')) .. dom.name)
    local v = { id = s.id, title = s.title, description = s.description, keywords = s.keywords, published = IsTrue(s.published), noindex = IsTrue(s.noindex),
        status = s.status, reason = s.takedown_reason, views = s.views, updated = s.updated_at, hosting = s.hosting_id, selfIp = s.self_ip,
        domainId = s.domain_id, sub = s.host, url = host and ('https://' .. host) or nil, host = host }
    if host then
        local ip = resolve(host)
        local want = s.hosting_id and SHARED_IP or s.self_ip
        v.live = ip == want
        v.dnsHint = (not v.live) and (ip and ('%s points at %s, not %s'):format(host, ip, want) or (host .. ' has no address record')) or nil
        v.cert = certView((certFor(host)))
    end
    if full then v.data = cleanSite(decode(s.data, {})) end
    return v
end

local function webAction(src, phone, d, a)
    local act = d.action
    if act == 'mine' then
        local hosting = {}
        for _, h in ipairs(hostingFor(phone.identifier)) do
            local p = PLANS[h.plan] or {}
            hosting[#hosting + 1] = { id = h.id, plan = h.plan, name = p.name, price = h.price, status = h.status, next = h.next_bill_at, overdue = h.overdue_since,
                sites = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_sites WHERE hosting_id = ?', { h.id }) or 0, maxSites = p.sites, ssl = p.ssl }
        end
        local sites = {}
        for _, s in ipairs(MySQL.query.await('SELECT * FROM ops_web_sites WHERE identifier = ? ORDER BY id', { phone.identifier }) or {}) do sites[#sites + 1] = siteView(s) end
        local doms = {}
        for _, r in ipairs(MySQL.query.await('SELECT * FROM ops_web_domains WHERE identifier = ? ORDER BY name', { phone.identifier }) or {}) do
            local dv = domainView(r) dv.mx = mxOf(r) doms[#doms + 1] = dv
        end
        local boxes = MySQL.query.await([[SELECT m.*, d.name AS domain FROM ops_web_mailboxes m JOIN ops_web_domains d ON d.id = m.domain_id WHERE d.identifier = ? ORDER BY m.address]], { phone.identifier }) or {}
        local work = {}
        if a then
            for _, j in ipairs(MySQL.query.await([[SELECT j.ref, j.title, j.customer_id, cu.name AS customer FROM ops_jobs j JOIN ops_companies c ON c.id = j.company_id
                LEFT JOIN ops_customers cu ON cu.id = j.customer_id WHERE j.assigned_to = ? AND j.status IN ('assigned', 'in_progress') AND c.code IN (?, ?)]], { a.id, Ops.role('web'), Ops.role('domains') }) or {}) do
                local ss = {}
                for _, s in ipairs(MySQL.query.await('SELECT * FROM ops_web_sites WHERE customer_id = ?', { j.customer_id }) or {}) do ss[#ss + 1] = siteView(s) end
                local dd = {}
                for _, r in ipairs(MySQL.query.await('SELECT * FROM ops_web_domains WHERE customer_id = ?', { j.customer_id }) or {}) do dd[#dd + 1] = domainView(r) end
                work[#work + 1] = { ref = j.ref, title = j.title, customer = j.customer, sites = ss, domains = dd }
            end
        end
        local maxSites, maxBoxes, ssl = limitsOf(phone.identifier)
        return { hosting = hosting, sites = sites, domains = doms, mailboxes = boxes, ips = myIps(phone), work = work,
            limits = { sites = maxSites, mailboxes = maxBoxes, ssl = ssl }, plans = W.plans, certs = W.certs, services = W.services, number = phone.number, sharedIp = SHARED_IP, mailHost = MAIL_HOST }
    elseif act == 'buy' then
        local p = PLANS[d.plan]
        if not p then return { error = 'Pick a plan' } end
        local cust, err = pay(src, phone, Ops.role('web'), p.price, 'OPS Web hosting · ' .. p.name, p.code)
        if not cust then return { error = err } end
        local id = MySQL.insert.await([[INSERT INTO ops_web_hosting (customer_id, identifier, owner_name, plan, price, status, created_at, next_bill_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?)]],
            { cust.id, phone.identifier, Clean(phone.name, 80), p.code, p.price, now(), now() + PERIOD })
        return { ok = true, id = id }
    elseif act == 'hosting_pay' or act == 'hosting_cancel' or act == 'hosting_plan' then
        local h = MySQL.single.await('SELECT * FROM ops_web_hosting WHERE id = ? AND identifier = ?', { tonumber(d.id), phone.identifier })
        if not h then return { error = 'Not your hosting' } end
        if act == 'hosting_cancel' then
            MySQL.update.await("UPDATE ops_web_hosting SET status = 'cancelled' WHERE id = ?", { h.id })
            indexAt = 0
            return { ok = true }
        elseif act == 'hosting_plan' then
            local p = PLANS[d.plan]
            if not p then return { error = 'Pick a plan' } end
            local used = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_sites WHERE hosting_id = ?', { h.id }) or 0
            if used > p.sites then return { error = ('%s allows %d site(s); you have %d on this plan'):format(p.name, p.sites, used) } end
            MySQL.update.await('UPDATE ops_web_hosting SET plan = ?, price = ? WHERE id = ?', { p.code, p.price, h.id })
            return { ok = true }
        end
        if not h.overdue_since and h.status == 'active' then return { error = 'Nothing to pay' } end
        local cust, err = pay(src, phone, Ops.role('web'), h.price, 'OPS Web hosting · ' .. h.plan, 'H' .. h.id)
        if not cust then return { error = err } end
        MySQL.update.await("UPDATE ops_web_hosting SET status = 'active', overdue_since = NULL, next_bill_at = ? WHERE id = ?", { now() + PERIOD, h.id })
        indexAt = 0
        return { ok = true }
    elseif act == 'site_new' then
        local title = str(d.title, 80)
        if title == '' then return { error = 'Give the site a name' } end
        local hostingId, selfIp
        if d.self_ip then
            for _, ip in ipairs(myIps(phone)) do if ip.ip == d.self_ip then selfIp = ip.ip end end
            if not selfIp then return { error = 'That IP isn’t one of your static OPS Network addresses' } end
        else
            for _, h in ipairs(hostingFor(phone.identifier)) do
                if h.status == 'active' and (not d.hosting or h.id == tonumber(d.hosting)) then
                    local used = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_sites WHERE hosting_id = ?', { h.id }) or 0
                    if used < ((PLANS[h.plan] or {}).sites or 0) then hostingId = h.id break end
                end
            end
            if not hostingId then return { error = 'Your hosting plan is full (or you have none) — upgrade on opsweb.sa, or host it yourself on a static IP' } end
        end
        local cust = Ops.customerForPlayer(src, phone)
        local id = MySQL.insert.await([[INSERT INTO ops_web_sites (hosting_id, self_ip, customer_id, identifier, owner_name, title, data, created_at, updated_at, edited_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { hostingId, selfIp, cust.id, phone.identifier, Clean(phone.name, 80), title, json.encode(starterSite(title, d.color)), now(), now(), phone.name })
        return { ok = true, id = id }
    end

    -- domain-level: SSL and mailboxes
    if act == 'ssl' or act == 'mailbox_add' then
        local dom = domainById(d.domain)
        if not dom or not mayManage(phone, a, dom) then return { error = 'Not your domain' } end
        if dom.status ~= 'active' then return { error = dom.name .. ' is ' .. dom.status } end
        if act == 'ssl' then
            local kind = CERTS[d.kind] and d.kind or 'dv'
            local host = str(d.host, 63) ~= '' and lower(d.host) or '@'
            local cn = host == '@' and dom.name or (host .. '.' .. dom.name)
            -- validation: the name has to reach a server the owner controls (OPS Web hosting or their own line)
            local ip = resolve(kind == 'wild' and dom.name or cn)
            local ownIp = ip == SHARED_IP
            if not ownIp and ip then
                local line = ispByIp(ip)
                local vm = CloudVmByIp and CloudVmByIp(ip)
                ownIp = (line and line.customer_id == dom.customer_id) or (vm and vm.customer_id == dom.customer_id and vm.state == 'running')
            end
            if not ownIp then return { error = ('Validation failed: %s must point at OPS Web (%s) or your own OPS Network IP first'):format(cn, SHARED_IP) } end
            local cust = dom.customer_id and MySQL.single.await('SELECT * FROM ops_customers WHERE id = ?', { dom.customer_id })
            if (kind == 'ov' or kind == 'ev') and (not cust or cust.kind == 'residential') then return { error = 'OV / EV certificates are for registered organisations (business, government, emergency services)' } end
            local _, _, planSsl = limitsOf(dom.identifier or '')
            local free = ip == SHARED_IP and planSsl and (kind == 'dv' or kind == planSsl)
            local price = free and 0 or (CERTS[kind].price or 0)
            if price > 0 then
                local c, err = pay(src, phone, Ops.role('domains'), price, ('SSL certificate (%s) · %s'):format(kind:upper(), cn), cn)
                if not c then return { error = err } end
            end
            local serial = ('%04X%04X%04X'):format(math.random(0, 0xffff), math.random(0, 0xffff), math.random(0, 0xffff))
            MySQL.update.await("UPDATE ops_web_certs SET status = 'revoked' WHERE domain_id = ? AND common_name = ? AND status = 'valid' AND wildcard = ?", { dom.id, cn, kind == 'wild' and 1 or 0 })
            MySQL.insert.await([[INSERT INTO ops_web_certs (domain_id, common_name, wildcard, kind, org, serial, status, auto, issued_at, expires_at, issued_by)
                VALUES (?, ?, ?, ?, ?, ?, 'valid', ?, ?, ?, ?)]], { dom.id, cn, kind == 'wild' and 1 or 0, kind == 'wild' and 'dv' or kind, (kind == 'ov' or kind == 'ev') and cust and cust.name or nil,
                serial, free and 1 or 0, now(), now() + PERIOD, phone.name })
            indexAt = 0
            return { ok = true, free = free, price = price, name = (kind == 'wild' and ('*.' .. dom.name) or cn) }
        else
            local local_ = lower(d['local']):gsub('[^a-z0-9%._%-]', '')
            if local_ == '' or #local_ > 40 then return { error = 'Pick an address like info or sales' } end
            local _, maxBoxes = limitsOf(dom.identifier or '')
            local used = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_mailboxes m JOIN ops_web_domains d ON d.id = m.domain_id WHERE d.identifier = ?', { dom.identifier }) or 0
            if used >= maxBoxes then return { error = maxBoxes == 0 and 'Email needs an OPS Web hosting plan' or ('Your plans allow %d mailboxes'):format(maxBoxes) } end
            local to = NormalizeNumber(d.deliver or phone.number)
            if not MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE phone_number = ?', { to }) then return { error = 'No phone with the number ' .. to } end
            local address = local_ .. '@' .. dom.name
            local ok = pcall(MySQL.insert.await, 'INSERT INTO ops_web_mailboxes (domain_id, address, deliver_to, catch_all, created_at, created_by) VALUES (?, ?, ?, ?, ?, ?)',
                { dom.id, address, to, d.catch_all and 1 or 0, now(), phone.name })
            if not ok then return { error = address .. ' already exists' } end
            ensureMx(dom)
            local dsrc = GetSourceByNumber(to)
            if dsrc then Notify(dsrc, { app = 'mail', title = 'New mailbox', body = address .. ' now arrives in your Mail app', icon = 'fa-envelope' }) end
            return { ok = true, address = address }
        end
    elseif act == 'mailbox_del' then
        local m = MySQL.single.await('SELECT m.*, d.identifier, d.customer_id FROM ops_web_mailboxes m JOIN ops_web_domains d ON d.id = m.domain_id WHERE m.id = ?', { tonumber(d.id) })
        if not m or not mayManage(phone, a, m) then return { error = 'Not yours' } end
        MySQL.update.await('DELETE FROM ops_web_mailboxes WHERE id = ?', { m.id })
        return { ok = true }
    elseif act == 'order' then          -- have OPS Web do it for you: raises a job
        local svc = SERVICES[d.code]
        if not svc then return { error = 'Unknown service' } end
        local dom = domainById(d.domain)
        if not dom or dom.identifier ~= phone.identifier then return { error = 'Pick one of your domains' } end
        local cust = Ops.customerForPlayer(src, phone)
        local open = MySQL.scalar.await([[SELECT j.ref FROM ops_jobs j WHERE j.customer_id = ? AND j.type = ? AND j.status IN ('open', 'assigned', 'in_progress') LIMIT 1]], { cust.id, d.code })
        if open then return { error = 'You already have that job open: ' .. open } end
        local t
        for _, x in ipairs(Ops.catalog.jobTypes or {}) do if x.code == d.code then t = x end end
        local v = { kind = t.verify.kind, blocks = t.verify.blocks, domain_id = dom.id, domain = dom.name }
        local company = t.company
        local id, ref = Ops.job(company, d.code, { customer_id = cust.id, address = 'Online · ' .. dom.name }, {
            title = ('%s · %s'):format(t.title, dom.name), price = svc.price, verify = v, by = phone.name,
            description = (t.desc or '') .. (d.note and str(d.note, 300) ~= '' and ('\n\nCustomer’s brief: ' .. str(d.note, 300)) or '') })
        if not id then return { error = 'Couldn’t book it right now' } end
        return { ok = true, ref = ref, price = svc.price }
    end

    -- site-level
    local s = MySQL.single.await('SELECT * FROM ops_web_sites WHERE id = ?', { tonumber(d.id) or 0 })
    if not s or not mayManage(phone, a, s) then return { error = 'Not your site' } end
    if act == 'site_get' then
        local v = siteView(s, true)
        v.domains = {}
        for _, r in ipairs(MySQL.query.await('SELECT id, name FROM ops_web_domains WHERE identifier = ? AND status = "active" ORDER BY name', { s.identifier }) or {}) do v.domains[#v.domains + 1] = r end
        return { site = v }
    elseif act == 'site_save' then
        if s.status == 'taken_down' then return { error = 'This site was taken down by OPS Web: ' .. (s.takedown_reason or '') } end
        local data = cleanSite(d.data)
        local enc = json.encode(data)
        if #enc > 60000 then return { error = 'The site is too big — remove some blocks' } end
        MySQL.update.await('UPDATE ops_web_sites SET title = ?, description = ?, keywords = ?, noindex = ?, data = ?, updated_at = ?, edited_by = ? WHERE id = ?',
            { str(d.title, 80) ~= '' and str(d.title, 80) or s.title, str(d.description, 240), str(d.keywords, 240), d.noindex and 1 or 0, enc, now(), phone.name, s.id })
        indexAt = 0
        return { ok = true }
    elseif act == 'site_publish' then
        if s.status == 'taken_down' then return { error = 'This site was taken down by OPS Web' } end
        MySQL.update.await('UPDATE ops_web_sites SET published = ?, published_at = IF(? = 1, ?, published_at), updated_at = ? WHERE id = ?', { d.on and 1 or 0, d.on and 1 or 0, now(), now(), s.id })
        indexAt = 0
        return { ok = true }
    elseif act == 'site_domain' then
        if not d.domain then
            MySQL.update.await('UPDATE ops_web_sites SET domain_id = NULL WHERE id = ?', { s.id })
            return { ok = true }
        end
        local dom = domainById(d.domain)
        if not dom or dom.identifier ~= s.identifier then return { error = 'The domain has to belong to the site’s owner' } end
        local host = lower(d.host) if host == '' or host == 'www' then host = '@' end
        if host ~= '@' and not validLabel(host) then return { error = 'Subdomain: letters, numbers and dashes' } end
        if MySQL.scalar.await('SELECT id FROM ops_web_sites WHERE domain_id = ? AND host = ? AND id <> ?', { dom.id, host, s.id }) then return { error = 'Another of your sites already uses that address' } end
        MySQL.update.await('UPDATE ops_web_sites SET domain_id = ?, host = ? WHERE id = ?', { dom.id, host, s.id })
        if d.dns ~= false then
            pointHost(dom, host, s.hosting_id and SHARED_IP or s.self_ip)
            if host == '@' and not MySQL.scalar.await("SELECT id FROM ops_web_dns WHERE domain_id = ? AND host = 'www'", { dom.id }) then
                MySQL.insert.await("INSERT INTO ops_web_dns (domain_id, host, type, value) VALUES (?, 'www', 'CNAME', '@')", { dom.id })
            end
        end
        indexAt = 0
        return { ok = true, url = 'https://' .. (host == '@' and '' or (host .. '.')) .. dom.name }
    elseif act == 'site_move' then          -- "migrate hosting": OPS Web plan ⇄ own static IP / cloud server
        local newHosting, newIp
        if d.self_ip then
            for _, ip in ipairs(myIps({ identifier = s.identifier })) do if ip.ip == d.self_ip then newIp = ip.ip end end
            if not newIp then return { error = 'That IP isn’t one of the owner’s servers / static IPs' } end
        else
            for _, h in ipairs(hostingFor(s.identifier or '')) do
                if h.status == 'active' then
                    local used = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_sites WHERE hosting_id = ? AND id <> ?', { h.id, s.id }) or 0
                    if used < ((PLANS[h.plan] or {}).sites or 0) then newHosting = h.id break end
                end
            end
            if not newHosting then return { error = 'No OPS Web plan with room — buy or upgrade one' } end
        end
        MySQL.update.await('UPDATE ops_web_sites SET hosting_id = ?, self_ip = ?, updated_at = ?, edited_by = ? WHERE id = ?', { newHosting, newIp, now(), phone.name, s.id })
        if s.domain_id then
            local dom = domainById(s.domain_id)
            if dom then pointHost(dom, s.host or '@', newIp or SHARED_IP) end
        end
        indexAt = 0
        return { ok = true }
    elseif act == 'site_delete' then
        if s.identifier ~= phone.identifier then return { error = 'Only the owner can delete it' } end
        MySQL.update.await('DELETE FROM ops_web_sites WHERE id = ?', { s.id })
        indexAt = 0
        return { ok = true }
    end
    return { error = 'Unknown action' }
end

Register('webHost', function(src, phone, d) return webAction(src, phone, d, Ops.account(src)) end)

---------------------------------------------------------------------------
-- email on your own domain
---------------------------------------------------------------------------
--- every address that lands in this phone's Mail app
function WebMailAddresses(phone)
    local list, catch = { phone.email }, {}
    for _, m in ipairs(MySQL.query.await('SELECT m.address, m.catch_all, d.name FROM ops_web_mailboxes m JOIN ops_web_domains d ON d.id = m.domain_id WHERE m.deliver_to = ? AND d.status = "active"', { phone.number }) or {}) do
        list[#list + 1] = m.address
        if IsTrue(m.catch_all) then catch[#catch + 1] = m.name end
    end
    return list, catch
end

--- the phone number a custom-domain address delivers to (nil if none)
function WebMailOwner(address)
    address = lower(address)
    local local_, domain = address:match('^(.+)@(.+)$')
    if not domain then return nil end
    local m = MySQL.single.await([[SELECT m.deliver_to FROM ops_web_mailboxes m JOIN ops_web_domains d ON d.id = m.domain_id
        WHERE d.status = 'active' AND (m.address = ? OR (m.catch_all = 1 AND d.name = ?)) ORDER BY m.address = ? DESC LIMIT 1]], { address, domain, address })
    return m and m.deliver_to
end

--- can mail to this address be delivered? → ok, reason
function WebDeliverable(address)
    address = lower(address)
    local domain = address:match('@(.+)$')
    if not domain then return false, 'That isn’t an email address.' end
    if domain == lower(Config.MailDomain) then return true end
    local name, sub = parseHost(domain)
    if INTERNAL[domain] or (name and INTERNAL[name]) then return true end    -- OPS company addresses
    if not name or sub ~= '@' then return true end                          -- not our registry (other script addresses)
    local d = domainByName(name)
    if not d then return false, ('The domain %s doesn’t exist.'):format(domain) end
    if d.status ~= 'active' then return false, ('The domain %s has expired or is suspended.'):format(domain) end
    if serviceDown('dns') then return false, 'DNS lookup failed — OPS DNS is down. Try again later.' end
    local mx = mxOf(d)
    if mx == MAIL_HOST and serviceDown('mail') then return false, ('%s didn’t answer — OPS Web mail is down. Try again later.'):format(MAIL_HOST) end
    if not mx then return false, ('%s has no mail server (MX record).'):format(domain) end
    if mx ~= MAIL_HOST then
        local ip = resolve(mx)
        if ip ~= MAIL_IP then return false, ('%s’s mail server %s didn’t answer.'):format(domain, mx) end
    end
    if not WebMailOwner(address) then return false, ('There is no mailbox called %s.'):format(address) end
    return true
end

function WebBounce(toPhoneEmail, original, subject, why)
    SendMail(toPhoneEmail, 'Mail Delivery Subsystem', 'Undeliverable: ' .. (subject or ''),
        ('Your message to %s couldn’t be delivered.\n\n%s\n\n— %s'):format(original, why or 'Unknown error', MAIL_HOST), 'mailer-daemon@' .. MAIL_HOST)
end

---------------------------------------------------------------------------
-- OPS Web / OPS Domains job checks (called from platform.lua verify)
---------------------------------------------------------------------------
function WebVerify(v, j)
    local since = tonumber(j.accepted_at) or 0
    local dom = v.domain_id and domainById(v.domain_id)
    if not dom then return { ok = false, label = 'The customer’s domain', have = 0, need = 1, detail = 'The domain no longer exists' } end
    if v.kind == 'web_published' then
        local best, detail = 0, 'No site on ' .. dom.name .. ' yet'
        for _, s in ipairs(MySQL.query.await('SELECT * FROM ops_web_sites WHERE domain_id = ?', { dom.id }) or {}) do
            local host = (s.host == '@' and '' or (s.host .. '.')) .. dom.name
            local n = blockCount(cleanSite(decode(s.data, {})))
            local ip = resolve(host)
            local live = ip ~= nil and ip == (s.hosting_id and SHARED_IP or s.self_ip)
            if not IsTrue(s.published) then detail = host .. ' isn’t published'
            elseif (s.updated_at or 0) < since then detail = 'Edit and publish the site after accepting the job'
            elseif not live then detail = host .. ' doesn’t point at the site yet (DNS)'
            elseif n < (v.blocks or 4) then detail = ('%d of %d content blocks'):format(n, v.blocks or 4) best = math.max(best, n)
            else return { ok = true, label = 'Site live on ' .. host, have = v.blocks or 4, need = v.blocks or 4, detail = ('%d blocks · published'):format(n) } end
        end
        return { ok = false, label = 'Customer’s site live on ' .. dom.name, have = best, need = v.blocks or 4, detail = detail }
    elseif v.kind == 'web_ssl' then
        local c = MySQL.single.await("SELECT * FROM ops_web_certs WHERE domain_id = ? AND status = 'valid' AND expires_at > ? AND issued_at >= ? LIMIT 1", { dom.id, now(), since })
        return { ok = c ~= nil, label = 'Valid certificate on ' .. dom.name, have = c and 1 or 0, need = 1, detail = c and ('Issued for ' .. c.common_name) or 'Issue it on opsweb.sa → SSL (the name must point at the site first)' }
    elseif v.kind == 'web_mail' then
        local m = MySQL.scalar.await('SELECT COUNT(*) FROM ops_web_mailboxes WHERE domain_id = ? AND created_at >= ?', { dom.id, since }) or 0
        local mx = mxOf(dom) == MAIL_HOST
        return { ok = m > 0 and mx, label = 'Email on ' .. dom.name, have = (m > 0 and 1 or 0) + (mx and 1 or 0), need = 2,
            detail = ('%s mailbox · MX %s'):format(m > 0 and '✓' or '✗', mx and '✓' or '✗') }
    elseif v.kind == 'web_cloud_setup' or v.kind == 'web_cloud_migrate' then
        local detail = 'No site on ' .. dom.name .. ' running on an OPS Cloud server yet'
        for _, s in ipairs(MySQL.query.await('SELECT * FROM ops_web_sites WHERE domain_id = ? AND self_ip IS NOT NULL', { dom.id }) or {}) do
            local vm = CloudVmByIp and CloudVmByIp(s.self_ip)
            local host = (s.host == '@' and '' or (s.host .. '.')) .. dom.name
            if vm and vm.customer_id == dom.customer_id then
                local ports = CloudVmPorts(vm)
                if vm.state ~= 'running' then detail = vm.name .. ' isn’t running (' .. vm.state .. ')'
                elseif not (ports[80] or ports[443]) then detail = 'Open ports 80 / 443 on ' .. vm.name
                elseif resolve(host) ~= vm.ip then detail = host .. ' doesn’t point at ' .. vm.ip .. ' yet'
                elseif not IsTrue(s.published) then detail = 'Publish the site'
                elseif (s.updated_at or 0) < since and (vm.created_at or 0) < since then detail = 'Do the work after accepting the job'
                else return { ok = true, label = host .. ' served from ' .. vm.name, have = 1, need = 1 } end
            end
        end
        return { ok = false, label = 'Website on the customer’s cloud server', have = 0, need = 1, detail = detail }
    elseif v.kind == 'web_dns' then
        local ok = (tonumber(dom.dns_changed_at) or 0) >= since
        return { ok = ok, label = 'DNS updated on ' .. dom.name, have = ok and 1 or 0, need = 1, detail = ok and 'Changed' or 'Make the change on opsdomains.sa → My domains' }
    end
    return { ok = false, label = 'Unknown check', have = 0, need = 1 }
end

---------------------------------------------------------------------------
-- renewals, billing, certificate expiry
---------------------------------------------------------------------------
local function cycle()
    local t = now()
    -- domains
    for _, d in ipairs(MySQL.query.await("SELECT * FROM ops_web_domains WHERE status = 'active' AND expires_at < ?", { t + WARN }) or {}) do
        local price = (TLDS[d.tld] or {}).price or 0
        if d.expires_at <= t then
            local ok, why = false, 'auto-renew is off'
            if IsTrue(d.auto_renew) then ok, why = payRow(d, Ops.role('domains'), price, 'Domain renewal · ' .. d.name, d.name) end
            if ok then
                MySQL.update.await('UPDATE ops_web_domains SET expires_at = ?, warned_at = NULL WHERE id = ?', { d.expires_at + PERIOD, d.id })
                tellOwner(d, 'OPS Domains · renewed', ('%s renewed until %s ($%s).'):format(d.name, os.date('%d %b %Y', d.expires_at + PERIOD), price))
            elseif not (why == 'offline' and t < d.expires_at + 2 * DAY) then
                MySQL.update.await("UPDATE ops_web_domains SET status = 'expired' WHERE id = ?", { d.id })
                tellOwner(d, 'OPS Domains · ' .. d.name .. ' expired', ('%s has expired (%s). Its website and email have stopped. Renew it on opsdomains.sa within %d days or it is released for anyone to register.')
                    :format(d.name, why or 'payment failed', math.floor(GRACE / DAY)))
                indexAt = 0
            end
        elseif not d.warned_at then
            MySQL.update.await('UPDATE ops_web_domains SET warned_at = ? WHERE id = ?', { t, d.id })
            tellOwner(d, 'OPS Domains · renewal due', ('%s renews on %s%s.'):format(d.name, os.date('%d %b', d.expires_at),
                IsTrue(d.auto_renew) and (' — $' .. price .. ' will be taken from your bank') or ' — auto-renew is OFF, renew on opsdomains.sa'))
        end
    end
    for _, d in ipairs(MySQL.query.await("SELECT * FROM ops_web_domains WHERE status = 'expired' AND expires_at < ?", { t - GRACE }) or {}) do
        MySQL.update.await('DELETE FROM ops_web_dns WHERE domain_id = ?', { d.id })
        MySQL.update.await('DELETE FROM ops_web_certs WHERE domain_id = ?', { d.id })
        MySQL.update.await('DELETE FROM ops_web_mailboxes WHERE domain_id = ?', { d.id })
        MySQL.update.await('UPDATE ops_web_sites SET domain_id = NULL WHERE domain_id = ?', { d.id })
        MySQL.update.await('DELETE FROM ops_web_domains WHERE id = ?', { d.id })
        tellOwner(d, 'OPS Domains · ' .. d.name .. ' released', d.name .. ' wasn’t renewed and is now available for anyone to register.')
        Ops.audit('billing', nil, 'domain.release', d.name, 'not renewed')
    end
    -- hosting
    for _, h in ipairs(MySQL.query.await("SELECT * FROM ops_web_hosting WHERE status = 'active' AND next_bill_at <= ?", { t }) or {}) do
        local ok, why = payRow(h, Ops.role('web'), h.price, 'OPS Web hosting · ' .. h.plan, 'H' .. h.id)
        if ok then
            MySQL.update.await('UPDATE ops_web_hosting SET next_bill_at = ?, overdue_since = NULL WHERE id = ?', { h.next_bill_at + PERIOD, h.id })
        else
            if not h.overdue_since then
                MySQL.update.await('UPDATE ops_web_hosting SET overdue_since = ? WHERE id = ?', { t, h.id })
                tellOwner(h, 'OPS Web · payment failed', ('Your %s hosting couldn’t be renewed (%s). Pay on opsweb.sa within %d days or your sites go offline.'):format(h.plan, why or 'payment failed', math.floor(GRACE / DAY)))
            elseif t - h.overdue_since > GRACE then
                MySQL.update.await("UPDATE ops_web_hosting SET status = 'suspended' WHERE id = ?", { h.id })
                tellOwner(h, 'OPS Web · hosting suspended', 'Your sites are offline until the hosting bill is paid on opsweb.sa.')
                indexAt = 0
            end
        end
    end
    -- certificates
    for _, c in ipairs(MySQL.query.await("SELECT c.*, d.identifier, d.name AS dname FROM ops_web_certs c JOIN ops_web_domains d ON d.id = c.domain_id WHERE c.status = 'valid' AND c.expires_at <= ?", { t }) or {}) do
        local renewed = false
        if IsTrue(c.auto) and resolve(c.common_name) == SHARED_IP then
            local _, _, ssl = limitsOf(c.identifier or '')
            if ssl then
                MySQL.update.await('UPDATE ops_web_certs SET expires_at = ?, issued_at = ? WHERE id = ?', { t + PERIOD, t, c.id })
                renewed = true
            end
        end
        if not renewed then
            MySQL.update.await("UPDATE ops_web_certs SET status = 'expired' WHERE id = ?", { c.id })
            tellOwner(c, 'OPS Trust CA · certificate expired', ('The certificate for %s has expired — visitors now get a security warning. Issue a new one on opsweb.sa.'):format(c.common_name))
        end
    end
end

CreateThread(function()
    AwaitDatabase()
    Wait(20000)
    while true do
        local ok, err = pcall(cycle)
        if not ok then print('^1[opslabs-phone] web billing: ' .. tostring(err) .. '^7') end
        Wait(300000)
    end
end)

-- for OPS Hub (server/api.lua) and other resources
exports('WebResolve', function(host) return resolve(host) end)
exports('WebBrowse', function(url) return browse({ identifier = '', number = '', name = 'api' }, url, true) end)
