-- OPS Work → Admin settings: the most-used switches, every job type and every company, from the phone.
-- Same data as OPS Hub → Settings / Jobs / Companies (ops_settings, ops_job_overrides, ops_companies).
-- Who: super admins, or anyone with admin.settings (admin.companies for companies) in one of their companies.

local QUICK = {
    { 'Branding (your main company)', {
        { 'opslabs-phone', 'Brand.Name', 'Main brand name — every platform name follows it', 'text' },
        { 'opslabs-phone', 'Brand.Full', 'Long name (website titles)', 'text' },
        { 'opslabs-phone', 'Brand.Color', 'Main colour', 'color' }, { 'opslabs-phone', 'Brand.Accent', 'Second colour', 'color' },
        { 'opslabs-phone', 'Brand.Logo', 'Logo image (https URL)', 'url' },
        { 'opslabs-phone', 'Brand.Sites.search', 'Search engine address', 'text' }, { 'opslabs-phone', 'Brand.Sites.web', 'Web hosting site address', 'text' },
        { 'opslabs-phone', 'Brand.Sites.domains', 'Domains site address', 'text' } } },
    { 'Play mode', {
        { 'opslabs-phone', 'Work.Mode', 'How jobs are worked', 'select', { 'standalone', 'items' } },
        { 'opslabs-phone', 'Work.ConsumeParts', 'Jobs use their parts from your inventory (items mode)', 'bool' } } },
    { 'OPS systems', {
        { 'opslabs-phone', 'Features.Web', 'In-game internet', 'bool' }, { 'opslabs-phone', 'Features.Cloud', 'OPS Cloud', 'bool' },
        { 'opslabs-phone', 'Features.Business', 'Business layer', 'bool' }, { 'opslabs-phone', 'Features.Training', 'Training & certifications', 'bool' },
        { 'opslabs-phone', 'Features.Assistant', 'Job assistant', 'bool' }, { 'opslabs-phone', 'Carrier.Enabled', 'OPS Mobile plans', 'bool' },
        { 'opslabs-towers', 'Enforce', 'Phones need tower signal', 'bool' }, { 'opslabs-towers', 'Mains.Enabled', 'Mains electricity', 'bool' },
        { 'opslabs-towers', 'Grid.Enabled', 'Power grid', 'bool' }, { 'opslabs-towers', 'OpsIsp.Enabled', 'OPS Network ISP', 'bool' },
        { 'opslabs-towers', 'Cctv.Enabled', 'OPS Secure CCTV', 'bool' }, { 'opslabs-towers', 'DataCentre.Enabled', 'OPS Data centres', 'bool' },
        { 'opslabs-towers', 'Track.Enabled', 'OPS Track', 'bool' }, { 'opslabs-towers', 'Fuel.Enabled', 'OPS Fuel', 'bool' },
        { 'opslabs-towers', 'Gunshot.Enabled', 'Gunshot detection', 'bool' }, { 'opslabs-towers', 'Faults.Enabled', 'Random network faults', 'bool' } } },
    { 'Jobs & safety', {
        { 'opslabs-phone', 'Platform.AutoJobs', 'New jobs appear by themselves', 'bool' }, { 'opslabs-phone', 'Platform.JobEvery', 'Seconds between new-job checks', 'number' },
        { 'opslabs-phone', 'Platform.OpenJobsPerCompany', 'Open jobs per board', 'number' }, { 'opslabs-phone', 'Platform.MaxActiveJobs', 'Jobs one engineer can hold', 'number' },
        { 'opslabs-phone', 'Work.SafetyBriefing', 'Risk assessment before work', 'bool' }, { 'opslabs-phone', 'Work.SafetyIncidents', 'Accidents when safety is skipped', 'bool' },
        { 'opslabs-phone', 'Work.RequireSafetyTraining', 'Safety module before a family’s jobs', 'bool' }, { 'opslabs-phone', 'Work.RequirePractical', 'Practical needed for certification', 'bool' },
        { 'opslabs-phone', 'Work.PassMark', 'Pass mark (%)', 'number' } } },
}

local function allowed(a, perm)
    if not a then return false end
    if Ops.isSuper(a) then return true end
    for _, m in ipairs(MySQL.query.await("SELECT company_id FROM ops_members WHERE account_id = ? AND status = 'active'", { a.id }) or {}) do
        if Ops.canId(a, m.company_id, perm) then return true end
    end
    return false
end

local function lookup(t, path)
    for seg in path:gmatch('[^%.]+') do if type(t) ~= 'table' then return nil end t = t[tonumber(seg) or seg] end
    return t
end

local function current(res, path)
    local ov = MySQL.scalar.await('SELECT value FROM ops_settings WHERE path = ?', { res .. ':' .. path })
    if ov then local ok, v = pcall(json.decode, ov) if ok then return v, true end end
    if res == GetCurrentResourceName() then return lookup(Config, path), false end
    local d = MySQL.scalar.await('SELECT config FROM ops_config_dump WHERE resource = ?', { res })
    local ok, cfg = pcall(json.decode, d or '{}')
    return ok and lookup(cfg, path) or nil, false
end

local function On(name, perm, fn)
    Register(name, function(src, phone, d)
        local a = Ops.account(src)
        if not allowed(a, perm) then return { denied = true, error = 'You need the admin settings permission' } end
        return fn(src, phone, d or {}, a)
    end)
end

On('opsAdminState', 'admin.settings', function()
    local out = {}
    for _, grp in ipairs(QUICK) do
        local items = {}
        for _, it in ipairs(grp[2]) do
            local v, over = current(it[1], it[2])
            items[#items + 1] = { res = it[1], path = it[2], label = it[3], kind = it[4], opts = it[5], value = v, over = over }
        end
        out[#out + 1] = { title = grp[1], items = items }
    end
    return { groups = out }
end)

On('opsAdminSet', 'admin.settings', function(_, _, d, a)
    local res, path = tostring(d.res or ''), tostring(d.path or '')
    if (res ~= 'opslabs-phone' and res ~= 'opslabs-towers') or not path:match('^[%w_%.]+$') then return { error = 'Bad setting' } end
    local known = false
    for _, grp in ipairs(QUICK) do for _, it in ipairs(grp[2]) do if it[1] == res and it[2] == path then known = it end end end
    if not known then return { error = 'Use OPS Hub → Settings for that one' } end
    if d.reset then
        MySQL.update.await('DELETE FROM ops_settings WHERE path = ?', { res .. ':' .. path })
        Ops.audit(Ops.nameOf(a), nil, 'settings.reset', res .. ':' .. path, 'reset')
        return { ok = true }
    end
    local v = d.value
    if known[4] == 'text' then
        v = tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 60)
        if path:find('^Brand%.Sites%.') and v ~= '' and not v:lower():match('^[a-z0-9%-]+%.[a-z]+$') then return { error = 'Use an address like mysite.sa' } end
        if path:find('^Brand%.Sites%.') then v = v:lower() end
    elseif known[4] == 'color' then
        v = tostring(v or '')
        if not v:match('^#%x%x%x%x%x%x$') then return { error = 'Use a hex colour like #5b3df5' } end
    elseif known[4] == 'url' then
        v = tostring(v or ''):gsub('%s', '')
        if v ~= '' and not v:match('^https://[%w%.%-]+/.+') then return { error = 'Use an https:// image address, or leave it empty' } end
    elseif known[4] == 'bool' then v = v == true elseif known[4] == 'number' then v = tonumber(v) if not v then return { error = 'Needs a number' } end
    elseif known[4] == 'select' then local okv = false for _, o in ipairs(known[5]) do if o == v then okv = true end end if not okv then return { error = 'Pick an option' } end end
    if d.reset then MySQL.update.await('DELETE FROM ops_settings WHERE path = ?', { res .. ':' .. path })
    else
        MySQL.query.await('INSERT INTO ops_settings (path, value, updated_by, updated_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)',
            { res .. ':' .. path, json.encode(v), Ops.nameOf(a), os.time() })
    end
    Ops.audit(Ops.nameOf(a), nil, 'settings.set', res .. ':' .. path, d.reset and 'reset' or json.encode(v))
    return { ok = true, note = 'Applied within 15 seconds (some systems only switch on/off on the next restart).' }
end)

On('opsAdminJobs', 'admin.settings', function()
    local list = {}
    for _, t in ipairs(Ops.catalog.jobTypes or {}) do
        local c = Ops.company(t.company) or {}
        list[#list + 1] = { code = t.code, title = t.title, company = c.name or t.company, color = c.color, icon = c.icon, enabled = t.enabled ~= false, auto = t.auto ~= false,
            price = t.price or 0, wage = t.wage or 0, custom = t.custom == true }
    end
    table.sort(list, function(x, y) if x.company ~= y.company then return x.company < y.company end return x.title < y.title end)
    return { jobs = list }
end)

On('opsAdminJob', 'admin.settings', function(_, _, d, a)
    local code = tostring(d.code or '')
    if not Ops.types[code] then return { error = 'No such job' } end
    local field = d.field
    if field ~= 'enabled' and field ~= 'auto' and field ~= 'price' and field ~= 'wage' then return { error = 'Bad field' } end
    local row = MySQL.scalar.await('SELECT data FROM ops_job_overrides WHERE code = ?', { code })
    local data = row and json.decode(row) or {}
    if field == 'enabled' or field == 'auto' then data[field] = d.value == true else local n = tonumber(d.value) if not n or n < 0 then return { error = 'Needs a number' } end data[field] = math.floor(n * 100 + 0.5) / 100 end
    MySQL.query.await('INSERT INTO ops_job_overrides (code, data, updated_by, updated_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)',
        { code, json.encode(data), Ops.nameOf(a), os.time() })
    Ops.audit(Ops.nameOf(a), nil, 'jobs.edit', code, field .. '=' .. tostring(data[field]))
    return { ok = true }
end)

On('opsAdminCompanies', 'admin.companies', function()
    return { companies = MySQL.query.await('SELECT id, code, name, tagline, color, icon, active FROM ops_companies ORDER BY name') or {} }
end)
On('opsAdminCompany', 'admin.companies', function(_, _, d, a)
    local id = tonumber(d.id)
    if not id then return { error = 'Pick a company' } end
    MySQL.update.await('UPDATE ops_companies SET active = ? WHERE id = ?', { d.active and 1 or 0, id })
    Ops.audit(Ops.nameOf(a), id, 'company.edit', tostring(id), d.active and 'switched on' or 'switched off')
    return { ok = true }
end)

Register('opsAdminAllowed', function(src)
    local a = Ops.account(src)
    return { settings = allowed(a, 'admin.settings'), companies = allowed(a, 'admin.companies') }
end)
