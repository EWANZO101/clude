-- Ops-Networks: the network engineer app.
-- Own accounts (scrypt-hashed passwords, per phone-session login), granular
-- permissions checked here on every request, jobs created from opslabs-towers
-- faults or planned by managers, engineer pay, and read-only network screens.
-- Everything from opslabs-towers is called defensively: when it is stopped or
-- an export is missing the app keeps working and says the network is offline.

local RES = GetCurrentResourceName()
local TOWERS = 'opslabs-towers'

local CFG = (ServerConfig and ServerConfig.OpsNet) or {}
local ADMIN_CFG = CFG.Admin or {}
local DEFAULT_ADMIN_USER = tostring(ADMIN_CFG.Username or 'admin'):lower()
local DEFAULT_ADMIN_PASS = tostring(ADMIN_CFG.Password or 'admin')
local MAX_ATTEMPTS = tonumber(CFG.MaxAttempts) or 5
local LOCKOUT = tonumber(CFG.LockoutSeconds) or 60
local PLANNED_RADIUS = tonumber(CFG.PlannedRadius) or 30.0
local MAX_PLANNED_PAY = tonumber(CFG.MaxPlannedPay) or 25000

---------------------------------------------------------------------------
-- permissions + role presets
---------------------------------------------------------------------------

local PERMS = {
    { id = 'jobs.view', group = 'Jobs', label = 'View jobs' },
    { id = 'jobs.take', group = 'Jobs', label = 'Accept and work jobs (get paid)' },
    { id = 'jobs.manage', group = 'Jobs', label = 'Create, assign and cancel planned work' },
    { id = 'faults.view', group = 'Faults', label = 'View faults' },
    { id = 'faults.manage', group = 'Faults', label = 'Acknowledge, add notes and close faults' },
    { id = 'customers.view', group = 'Customers', label = 'View customers and ONTs' },
    { id = 'customers.ip', group = 'Customers', label = 'See IP, gateway, MAC and LAN details' },
    { id = 'network.view', group = 'Network', label = 'View equipment, cabinets, links and towers' },
    { id = 'poles.view', group = 'Network', label = 'View poles' },
    { id = 'planned.view', group = 'Network', label = 'View planned work' },
    { id = 'rangetest.use', group = 'Tools', label = 'Use the Wi-Fi range test' },
    { id = 'payments.view', group = 'Pay', label = 'View own earnings' },
    { id = 'admin.users', group = 'Admin', label = 'Manage users' },
    { id = 'admin.permissions', group = 'Admin', label = 'Grant and revoke permissions' },
    { id = 'admin.payments', group = 'Admin', label = 'Edit pay rates' },
    { id = 'admin.faults', group = 'Admin', label = 'Fault engine settings' },
    { id = 'admin.render', group = 'Admin', label = 'Kit render distance' },
}
local PERM_SET = {}
for _, p in ipairs(PERMS) do PERM_SET[p.id] = true end

local TRAINEE = { 'jobs.view', 'faults.view', 'network.view', 'poles.view', 'planned.view', 'rangetest.use' }
local function plus(base, extra)
    local out = {}
    for _, p in ipairs(base) do out[#out + 1] = p end
    for _, p in ipairs(extra) do out[#out + 1] = p end
    return out
end
local ENGINEER = plus(TRAINEE, { 'jobs.take', 'customers.view', 'payments.view' })
local SENIOR = plus(ENGINEER, { 'faults.manage', 'customers.ip', 'jobs.manage' })
local NOC = { 'jobs.view', 'jobs.manage', 'faults.view', 'faults.manage', 'customers.view', 'customers.ip', 'network.view', 'poles.view', 'planned.view', 'payments.view' }

local PRESETS = {
    { id = 'trainee', label = 'Trainee', perms = TRAINEE },
    { id = 'engineer', label = 'Engineer', perms = ENGINEER },
    { id = 'senior', label = 'Senior engineer', perms = SENIOR },
    { id = 'noc', label = 'NOC', perms = NOC },
    { id = 'admin', label = 'Administrator', all = true },
}
local PRESET_BY_ID = {}
for _, p in ipairs(PRESETS) do PRESET_BY_ID[p.id] = p end

local function allPerms()
    local list = {}
    for _, p in ipairs(PERMS) do list[#list + 1] = p.id end
    return list
end

local function decodePerms(raw)
    local ok, list = pcall(json.decode, raw or '[]')
    local out = {}
    if ok and type(list) == 'table' then
        for _, p in ipairs(list) do if PERM_SET[p] then out[#out + 1] = p end end
    end
    return out
end

--- effective permission list of a user row (admin role = everything)
local function permList(u)
    if u.role == 'admin' then return allPerms() end
    return decodePerms(u.perms)
end

local function cleanPermList(list)
    local out, seen = {}, {}
    if type(list) ~= 'table' then return out end
    for _, p in ipairs(list) do
        if PERM_SET[p] and not seen[p] then seen[p] = true out[#out + 1] = p end
    end
    return out
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function hashPassword(pw)
    local ok, h = pcall(function() return exports[RES]:HashPassword(pw) end)
    if ok and type(h) == 'string' and h:find('^scrypt%$') then return h end
    print(('^1[opslabs-phone] Ops-Networks: password hashing failed: %s^7'):format(tostring(h)))
    return nil
end

local function verifyPassword(pw, hash)
    local ok, r = pcall(function() return exports[RES]:VerifyPassword(pw, hash) end)
    return ok and r == true
end

local function cleanUsername(s)
    s = tostring(s or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if not s:match('^[a-z0-9_%.%-]+$') or #s < 3 or #s > 24 then return nil end
    return s
end

local function displayName(u)
    return (u.display_name and u.display_name ~= '') and u.display_name or u.username
end

local function round(n) return math.floor((tonumber(n) or 0) + 0.5) end

local function clampInt(v, lo, hi, fallback)
    v = tonumber(v)
    if not v or v ~= v then return fallback end
    return math.max(lo, math.min(hi, math.floor(v + 0.5)))
end

local PRIORITIES = { low = true, medium = true, high = true, critical = true }

---------------------------------------------------------------------------
-- opslabs-towers (optional)
---------------------------------------------------------------------------

local function towersUp() return GetResourceState(TOWERS) == 'started' end
local OFFLINE = 'The network system (opslabs-towers) is offline right now.'

--- calls a towers export; returns its results or nil, error text
local function T(fn, ...)
    if not towersUp() then return nil, OFFLINE end
    local args = table.pack(...)
    local ok, a, b = pcall(function()
        local e = exports[TOWERS]
        return e[fn](e, table.unpack(args, 1, args.n))
    end)
    if not ok then
        print(('^3[opslabs-phone] Ops-Networks: opslabs-towers %s failed: %s^7'):format(fn, tostring(a)))
        return nil, ('The network system could not answer (%s).'):format(fn)
    end
    return a, b
end

local FAULT_TYPES = {
    { id = 'pole_lean', label = 'Leaning pole', severity = 'medium' },
    { id = 'pole_rot', label = 'Rotten pole', severity = 'high' },
    { id = 'fibre_break', label = 'Fibre break', severity = 'critical' },
    { id = 'dropwire_down', label = 'Drop wire down', severity = 'medium' },
    { id = 'cbt_water', label = 'Water in CBT', severity = 'medium' },
    { id = 'splice_loss', label = 'High splice loss', severity = 'low' },
    { id = 'ont_failure', label = 'ONT failure', severity = 'low' },
    { id = 'cabinet_power', label = 'Cabinet power failure', severity = 'high' },
    { id = 'olt_card', label = 'OLT card failure', severity = 'critical' },
    { id = 'tower_power', label = 'Tower power failure', severity = 'high' },
}

--- fault catalogue: from towers when available, otherwise the contract's ids
local function faultTypes()
    local s = T('GetFaultSettings')
    if type(s) == 'table' and type(s.types) == 'table' and #s.types > 0 then
        local out = {}
        for _, t in ipairs(s.types) do out[#out + 1] = { id = t.id, label = t.label or t.id, severity = t.severity, category = t.category } end
        return out
    end
    return FAULT_TYPES
end

---------------------------------------------------------------------------
-- pay settings (config defaults, overridden from KV 'opsnet_pay')
---------------------------------------------------------------------------

local PAY_CFG = CFG.Pay or {}
local SEVERITIES = { 'low', 'medium', 'high', 'critical' }

local function payDefaults()
    local bySev, byType = {}, {}
    local cs = PAY_CFG.BySeverity or {}
    local fallbackSev = { low = 400, medium = 700, high = 1100, critical = 1600 }
    for _, s in ipairs(SEVERITIES) do bySev[s] = round(cs[s] or fallbackSev[s]) end
    for id, v in pairs(PAY_CFG.ByType or {}) do byType[id] = round(v) end
    local b = PAY_CFG.Bonus or {}
    return {
        Default = round(PAY_CFG.Default or 500),
        BySeverity = bySev,
        ByType = byType,
        Planned = round(PAY_CFG.Planned or 600),
        Bonus = { Enabled = b.Enabled ~= false, Hours = tonumber(b.Hours) or 2, Amount = round(b.Amount or 250) },
    }
end

local function paySettings()
    local s = payDefaults()
    local ok, saved = pcall(json.decode, KV.opsnet_pay or '{}')
    if not ok or type(saved) ~= 'table' then return s end
    if saved.Default then s.Default = round(saved.Default) end
    if saved.Planned then s.Planned = round(saved.Planned) end
    for _, sev in ipairs(SEVERITIES) do
        if type(saved.BySeverity) == 'table' and saved.BySeverity[sev] then s.BySeverity[sev] = round(saved.BySeverity[sev]) end
    end
    if type(saved.ByType) == 'table' then
        for id, v in pairs(saved.ByType) do s.ByType[id] = round(v) end
    end
    if type(saved.Bonus) == 'table' then
        if saved.Bonus.Enabled ~= nil then s.Bonus.Enabled = saved.Bonus.Enabled == true end
        if saved.Bonus.Hours then s.Bonus.Hours = tonumber(saved.Bonus.Hours) or s.Bonus.Hours end
        if saved.Bonus.Amount then s.Bonus.Amount = round(saved.Bonus.Amount) end
    end
    return s
end

local MAX_RATE = 1000000

local function savePaySettings(data, actor)
    if type(data) ~= 'table' then return { error = 'Invalid settings' } end
    local cur = paySettings()
    local out = {
        Default = clampInt(data.Default, 0, MAX_RATE, cur.Default),
        Planned = clampInt(data.Planned, 0, MAX_RATE, cur.Planned),
        BySeverity = {}, ByType = {},
        Bonus = {
            Enabled = (type(data.Bonus) == 'table' and data.Bonus.Enabled ~= nil) and data.Bonus.Enabled == true or cur.Bonus.Enabled,
            Hours = math.max(0.25, math.min(168, tonumber(type(data.Bonus) == 'table' and data.Bonus.Hours) or cur.Bonus.Hours)),
            Amount = clampInt(type(data.Bonus) == 'table' and data.Bonus.Amount, 0, MAX_RATE, cur.Bonus.Amount),
        },
    }
    for _, sev in ipairs(SEVERITIES) do
        out.BySeverity[sev] = clampInt(type(data.BySeverity) == 'table' and data.BySeverity[sev], 0, MAX_RATE, cur.BySeverity[sev])
    end
    for id, v in pairs(cur.ByType) do out.ByType[id] = v end
    if type(data.ByType) == 'table' then
        for id, v in pairs(data.ByType) do
            if type(id) == 'string' and id:match('^[%w_]+$') and #id <= 30 then out.ByType[id] = clampInt(v, 0, MAX_RATE, 0) end
        end
    end
    SetKV('opsnet_pay', json.encode(out))
    print(('^3[opslabs-phone]^7 Ops-Networks pay rates changed by %s'):format(actor or '?'))
    return { ok = true, settings = out }
end

local function payView()
    return { settings = paySettings(), defaults = payDefaults(), types = faultTypes(), account = PAY_CFG.Account or 'bank' }
end

local function rateFor(fault)
    local s = paySettings()
    local t = fault and fault.type and s.ByType[fault.type]
    if t and t > 0 then return t end
    local sev = fault and fault.severity and s.BySeverity[fault.severity]
    if sev then return sev end
    return s.Default
end

local function bonusFor(fault, fixedAt)
    local s = paySettings()
    if not s.Bonus.Enabled or (s.Bonus.Amount or 0) <= 0 then return 0 end
    local created = tonumber(fault and fault.created_at)
    if not created then return 0 end
    if (fixedAt or os.time()) - created <= s.Bonus.Hours * 3600 then return s.Bonus.Amount end
    return 0
end

---------------------------------------------------------------------------
-- fault + render settings (shared by the Developer app and the admin panel)
---------------------------------------------------------------------------

local function faultSettingsView()
    local s, err = T('GetFaultSettings')
    if type(s) ~= 'table' then return { error = err or 'Fault settings are unavailable.', offline = true } end
    local list = T('GetFaults', { status = 'active', limit = 100 })
    return { settings = s, faults = type(list) == 'table' and list.faults or {}, stats = type(list) == 'table' and list.stats or nil }
end

local function saveFaultSettings(data, actor)
    if type(data) ~= 'table' then return { error = 'Invalid settings' } end
    local s = { types = {} }
    if data.enabled ~= nil then s.enabled = data.enabled == true end
    if data.maxOpen ~= nil then s.maxOpen = clampInt(data.maxOpen, 0, 500, nil) end
    if type(data.types) == 'table' then
        for id, t in pairs(data.types) do
            if type(id) == 'string' and id:match('^[%w_]+$') and type(t) == 'table' then
                local e = {}
                if t.enabled ~= nil then e.enabled = t.enabled == true end
                if t.perWeek ~= nil then local n = tonumber(t.perWeek) if n then e.perWeek = math.max(0, math.min(1000, n)) end end
                if t.minLiveHours ~= nil then local n = tonumber(t.minLiveHours) if n then e.minLiveHours = math.max(0, math.min(100000, n)) end end
                s.types[id] = e
            end
        end
    end
    local ok, err = T('SetFaultSettings', s, actor)
    if not ok then return { error = err or 'Could not save fault settings' } end
    return { ok = true }
end

local function triggerFault(typeId, actor)
    typeId = tostring(typeId or '')
    if not typeId:match('^[%w_]+$') then return { error = 'Pick a fault type' } end
    local f, err = T('TriggerFault', typeId, actor)
    if type(f) ~= 'table' then return { error = err or 'No eligible asset for that fault right now.' } end
    return { ok = true, fault = f }
end

local function closeFault(id, actor, note)
    local ok, err = T('CloseFault', tonumber(id), actor, note and Clean(note, 300) or nil)
    if not ok then return { error = err or 'Could not close the fault' } end
    return { ok = true }
end

local RENDER_LIMITS = { Distance = { 50, 1500 }, Behind = { 10, 400 }, ViewAngle = { 60, 360 }, Margin = { 0, 100 } }

local function renderView()
    local r, err = T('GetRenderSettings')
    if type(r) ~= 'table' then return { error = err or 'Render settings are unavailable.', offline = true } end
    return { settings = r, limits = RENDER_LIMITS }
end

local function saveRender(data, actor)
    if type(data) ~= 'table' then return { error = 'Invalid settings' } end
    local r = {}
    for k, lim in pairs(RENDER_LIMITS) do
        local n = tonumber(data[k])
        if n then r[k] = math.max(lim[1], math.min(lim[2], n)) + 0.0 end
    end
    local ok, err = T('SetRenderSettings', r, actor)
    if not ok then return { error = err or 'Could not save render settings' } end
    return { ok = true }
end

---------------------------------------------------------------------------
-- accounts + sessions
---------------------------------------------------------------------------

local sessions = {}  -- [src] = user id
local attempts = {}  -- [src] = { count, lockedUntil }

local function endSession(src)
    sessions[src] = nil
    attempts[src] = nil
end

AddEventHandler('playerDropped', function() endSession(source) end)
AddEventHandler('esx:playerLogout', function(src) endSession(src) end)
AddEventHandler('esx:playerLoaded', function(src) endSession(src) end)

local function getUser(id)
    return MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_users WHERE id = ?', { tonumber(id) })
end

--- the logged-in, enabled account of a player (with .permset), or nil
local function currentUser(src)
    local uid = sessions[src]
    if not uid then return nil end
    local u = getUser(uid)
    if not u or IsTrue(u.disabled) then sessions[src] = nil return nil end
    u.permlist = permList(u)
    u.permset = {}
    for _, p in ipairs(u.permlist) do u.permset[p] = true end
    return u
end

local function hasPerm(u, perm) return u and u.permset and u.permset[perm] == true end

local function accountFor(identifier)
    if not identifier then return nil end
    local u = MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_users WHERE identifier = ? AND disabled = 0 ORDER BY id LIMIT 1', { identifier })
    if not u then return nil end
    u.permset = {}
    for _, p in ipairs(permList(u)) do u.permset[p] = true end
    return u
end

local function me(u)
    local admin = MySQL.scalar.await("SELECT COUNT(*) FROM opslabs_phone_opsnet_users WHERE role = 'admin' AND default_pw = 1 AND disabled = 0") or 0
    local canAdmin = false
    for _, p in ipairs(u.permlist) do if p:find('^admin%.') then canAdmin = true end end
    return {
        id = u.id, username = u.username, name = displayName(u), role = u.role,
        perms = u.permlist, pending = #u.permlist == 0,
        defaultPassword = IsTrue(u.default_pw),
        adminDefaultPassword = canAdmin and admin > 0,
    }
end

local function sessionPush(action, data, filterPerm)
    for src, uid in pairs(sessions) do
        if Phones[src] then Push(src, action, data) end
    end
end

-- seed the administrator account on first start
CreateThread(function()
    AwaitDatabase()
    Wait(500)
    local admins = MySQL.scalar.await("SELECT COUNT(*) FROM opslabs_phone_opsnet_users WHERE role = 'admin'") or 0
    if admins > 0 then return end
    local username = cleanUsername(DEFAULT_ADMIN_USER) or 'admin'
    local hash = hashPassword(DEFAULT_ADMIN_PASS)
    if not hash then return end
    local exists = MySQL.scalar.await('SELECT id FROM opslabs_phone_opsnet_users WHERE username = ?', { username })
    if exists then
        MySQL.update.await("UPDATE opslabs_phone_opsnet_users SET role = 'admin', disabled = 0 WHERE id = ?", { exists })
    else
        MySQL.insert.await([[INSERT INTO opslabs_phone_opsnet_users (username, pass_hash, display_name, role, perms, default_pw, created_by, created_at)
            VALUES (?, ?, 'Administrator', 'admin', '[]', 1, 'system', ?)]], { username, hash, os.time() })
    end
    print(('^3[opslabs-phone]^7 Ops-Networks: created the administrator account "%s" - change its password in the app'):format(username))
end)

Register('opsnetSession', function(src)
    local u = currentUser(src)
    return {
        loggedIn = u ~= nil,
        me = u and me(u) or nil,
        signup = CFG.AllowSignup ~= false,
        towers = towersUp(),
    }
end)

Register('opsnetLogin', function(src, phone, data)
    local now = os.time()
    local a = attempts[src] or { count = 0, lockedUntil = 0 }
    attempts[src] = a
    if a.lockedUntil > now then
        return { error = ('Too many attempts. Try again in %d seconds.'):format(a.lockedUntil - now) }
    end
    local username = cleanUsername(data.username)
    local password = tostring(data.password or '')
    local u = username and MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_users WHERE username = ?', { username })
    if u and #password > 0 and verifyPassword(password, u.pass_hash) then
        if IsTrue(u.disabled) then return { error = 'This account has been disabled. Contact an administrator.' } end
        sessions[src] = u.id
        attempts[src] = nil
        -- link an unlinked account to the first character that signs into it
        if not u.identifier then
            local taken = MySQL.scalar.await('SELECT 1 FROM opslabs_phone_opsnet_users WHERE identifier = ?', { phone.identifier })
            if not taken then MySQL.update.await('UPDATE opslabs_phone_opsnet_users SET identifier = ? WHERE id = ? AND identifier IS NULL', { phone.identifier, u.id }) end
        end
        MySQL.update.await('UPDATE opslabs_phone_opsnet_users SET last_login = ? WHERE id = ?', { now, u.id })
        print(('^3[opslabs-phone]^7 %s (%s) signed into Ops-Networks as %s'):format(phone.name, phone.identifier, u.username))
        return { ok = true, me = me(currentUser(src)) }
    end
    a.count = a.count + 1
    if a.count >= MAX_ATTEMPTS then
        a.count = 0
        a.lockedUntil = now + LOCKOUT
        print(('^1[opslabs-phone]^7 Ops-Networks login locked for %s (%s) after failed attempts'):format(phone.name, phone.identifier))
        return { error = ('Too many attempts. Try again in %d seconds.'):format(LOCKOUT) }
    end
    return { error = 'Incorrect username or password.', remaining = MAX_ATTEMPTS - a.count }
end)

Register('opsnetSignup', function(src, phone, data)
    if CFG.AllowSignup == false then return { error = 'Sign-up is closed. Ask an administrator for an account.' } end
    local username = cleanUsername(data.username)
    if not username then return { error = 'Usernames are 3-24 characters: letters, numbers, dot, dash or underscore.' } end
    local password = tostring(data.password or '')
    if #password < 6 or #password > 128 then return { error = 'Use a password of at least 6 characters.' } end
    local existing = MySQL.scalar.await('SELECT username FROM opslabs_phone_opsnet_users WHERE identifier = ?', { phone.identifier })
    if existing then return { error = ('This character already has an account (%s). Sign in instead.'):format(existing) } end
    if MySQL.scalar.await('SELECT 1 FROM opslabs_phone_opsnet_users WHERE username = ?', { username }) then
        return { error = 'That username is taken.' }
    end
    local hash = hashPassword(password)
    if not hash then return { error = 'Could not create the account right now.' } end
    local id = MySQL.insert.await([[INSERT INTO opslabs_phone_opsnet_users (username, pass_hash, identifier, display_name, role, perms, created_by, created_at)
        VALUES (?, ?, ?, ?, 'custom', '[]', 'signup', ?)]], { username, hash, phone.identifier, Clean(phone.name, 60), os.time() })
    if not id then return { error = 'Could not create the account.' } end
    sessions[src] = id
    attempts[src] = nil
    -- let online administrators know there is someone waiting
    for s, uid in pairs(sessions) do
        if s ~= src then
            local au = currentUser(s)
            if au and (hasPerm(au, 'admin.users') or hasPerm(au, 'admin.permissions')) then
                Notify(s, { app = 'opsnet', title = 'Ops-Networks', icon = 'fa-user-plus', body = ('%s (%s) is waiting for access.'):format(Clean(phone.name, 60), username) })
            end
        end
    end
    return { ok = true, me = me(currentUser(src)) }
end)

Register('opsnetLogout', function(src)
    sessions[src] = nil
    return { ok = true }
end)

--- Register for signed-in users; `perm` = permission id or list (any of)
local function OnRegister(name, perm, handler)
    Register(name, function(src, phone, data)
        local u = currentUser(src)
        if not u then return { error = 'Please sign in to Ops-Networks.', loggedOut = true } end
        if perm then
            local need = type(perm) == 'table' and perm or { perm }
            local ok = false
            for _, p in ipairs(need) do if u.permset[p] then ok = true break end end
            if not ok then return { error = "You don't have permission to do that.", denied = true } end
        end
        return handler(src, phone, data, u)
    end)
end

OnRegister('opsnetChangePassword', nil, function(_, _, data, u)
    local current, password = tostring(data.current or ''), tostring(data.password or '')
    if not verifyPassword(current, u.pass_hash) then return { error = 'Your current password is incorrect.' } end
    if #password < 6 or #password > 128 then return { error = 'Use a password of at least 6 characters.' } end
    if password == DEFAULT_ADMIN_PASS or password == current then return { error = 'Choose a new password that is not the default.' } end
    local hash = hashPassword(password)
    if not hash then return { error = 'Could not change the password right now.' } end
    MySQL.update.await('UPDATE opslabs_phone_opsnet_users SET pass_hash = ?, default_pw = 0 WHERE id = ?', { hash, u.id })
    return { ok = true }
end)

---------------------------------------------------------------------------
-- jobs
---------------------------------------------------------------------------

local PRIO_ORDER = "FIELD(priority, 'critical', 'high', 'medium', 'low')"

local function jobView(r, u)
    return {
        id = r.id, kind = r.kind, faultId = r.fault_id, faultType = r.fault_type, faultStatus = r.fault_status,
        title = r.title, description = r.description, location = r.location,
        x = r.x, y = r.y, z = r.z, poleId = r.pole_id, priority = r.priority, status = r.status,
        assignedTo = r.assigned_to, assignedName = r.assigned_name, mine = u and r.assigned_to == u.id or false,
        pay = r.pay, paid = IsTrue(r.paid), paidAmount = r.paid_amount,
        createdBy = r.created_by, createdAt = r.created_at, completedAt = r.completed_at, completedName = r.completed_name,
    }
end

local function jobsChanged()
    sessionPush('opsnetJobsChanged', true)
end

local function faultLocation(f)
    local parts = {}
    if type(f.asset) == 'table' and f.asset.label then parts[#parts + 1] = tostring(f.asset.label) end
    if f.pole_id then parts[#parts + 1] = ('Pole #%s'):format(f.pole_id) end
    return table.concat(parts, ' · ')
end

local function faultDescription(f)
    if type(f.symptoms) == 'table' and #f.symptoms > 0 then
        local out = {}
        for i = 1, math.min(#f.symptoms, 4) do out[#out + 1] = tostring(f.symptoms[i]) end
        return table.concat(out, '\n')
    end
    return f.description or ''
end

--- creates or refreshes the job for a fault; returns job id, created
local function upsertFaultJob(f)
    local fid = type(f) == 'table' and tonumber(f.id)
    if not fid then return nil end
    local prio = PRIORITIES[f.severity] and f.severity or 'medium'
    local title = Clean(f.label or f.type or ('Fault #' .. fid), 120)
    local x, y, z = tonumber(f.x) or 0.0, tonumber(f.y) or 0.0, tonumber(f.z) or 0.0
    local existing = MySQL.single.await('SELECT id, status FROM opslabs_phone_opsnet_jobs WHERE fault_id = ?', { fid })
    if existing then
        MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET title = ?, description = ?, location = ?, x = ?, y = ?, z = ?, pole_id = ?,
            priority = ?, fault_type = ?, fault_status = ?, pay = IF(paid = 0, ?, pay) WHERE id = ?]],
            { title, faultDescription(f), Clean(faultLocation(f), 160), x, y, z, tonumber(f.pole_id), prio, f.type, f.status, rateFor(f), existing.id })
        return existing.id, false
    end
    local id = MySQL.insert.await([[INSERT IGNORE INTO opslabs_phone_opsnet_jobs
        (kind, fault_id, fault_type, fault_status, title, description, location, x, y, z, pole_id, priority, status, pay, created_by, created_at)
        VALUES ('fault', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, 'Fault engine', ?)]],
        { fid, f.type, f.status, title, faultDescription(f), Clean(faultLocation(f), 160), x, y, z, tonumber(f.pole_id), prio, rateFor(f), tonumber(f.created_at) or os.time() })
    return id, id ~= nil and id ~= 0
end

local function payUser(src, user, amount, bonus, label, jobId)
    local total = (amount or 0) + (bonus or 0)
    local identifier = FW.Identifier(src)
    if not identifier or total <= 0 then return false end
    if not FW.AddMoney(src, total, PAY_CFG.Account or 'bank', 'Ops-Networks: ' .. label) then return false end
    MySQL.insert.await('INSERT INTO opslabs_phone_opsnet_payments (user_id, identifier, job_id, label, amount, bonus, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { user.id, identifier, jobId, Clean(label, 160), amount or 0, bonus or 0, os.time() })
    MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { identifier, Clean('Ops-Networks: ' .. label, 120), total })
    Notify(src, {
        app = 'opsnet', title = 'Ops-Networks', icon = 'fa-sack-dollar',
        body = ('Paid $%s for %s%s'):format(total, label, (bonus or 0) > 0 and (' (incl. $%s quick-fix bonus)'):format(bonus) or ''),
        data = { page = 'earnings' },
    })
    return true
end

--- server-internal events only: ignore anything a client could have sent
local function fromServer()
    local s = tonumber(source)
    return not s or s <= 0
end

AddEventHandler('opslabs-towers:faultOpened', function(fault)
    if not fromServer() then return end
    CreateThread(function()
        AwaitDatabase()
        local _, created = upsertFaultJob(fault)
        if not created then return end
        for s in pairs(sessions) do
            local u = currentUser(s)
            if u and hasPerm(u, 'jobs.take') then
                Notify(s, { app = 'opsnet', title = 'New job · ' .. tostring(fault.severity or ''):upper(), icon = 'fa-triangle-exclamation',
                    body = ('%s%s'):format(fault.label or 'Network fault', faultLocation(fault) ~= '' and (' — ' .. faultLocation(fault)) or ''), data = { page = 'jobs' } })
            end
        end
        jobsChanged()
    end)
end)

AddEventHandler('opslabs-towers:faultUpdated', function(fault)
    if not fromServer() then return end
    CreateThread(function()
        AwaitDatabase()
        upsertFaultJob(fault)
        jobsChanged()
    end)
end)

AddEventHandler('opslabs-towers:faultFixed', function(fault, fixer)
    if not fromServer() then return end
    CreateThread(function()
        AwaitDatabase()
        if type(fault) ~= 'table' then return end
        local jobId = upsertFaultJob(fault)
        local job = jobId and MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_jobs WHERE id = ?', { jobId })
        if not job then return end
        local now = os.time()
        local fixedAt = tonumber(fault.fixed_at) or now
        MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET status = 'completed', fault_status = ?, completed_at = COALESCE(completed_at, ?),
            completed_name = COALESCE(completed_name, ?) WHERE id = ?]], { fault.status or 'fixed', fixedAt, Clean(fault.fixed_by or 'Closed', 60), job.id })
        fixer = tonumber(fixer)
        if fixer and GetPlayerName(fixer) then
            local fixerId = FW.Identifier(fixer)
            local u = fixerId and accountFor(fixerId)
            if u and hasPerm(u, 'jobs.take') then
                local amount, bonus = rateFor(fault), bonusFor(fault, fixedAt)
                local flipped = MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET paid = 1, paid_amount = ?, completed_by = ?, completed_name = ?
                    WHERE id = ? AND paid = 0]], { amount + bonus, u.id, Clean(displayName(u), 60), job.id })
                if flipped == 1 then payUser(fixer, u, amount, bonus, job.title, job.id) end
            end
        end
        jobsChanged()
    end)
end)

-- catch up with faults opened / finished while this resource was stopped
local function syncFaultJobs()
    local list = T('GetFaults', { status = 'active', limit = 500 })
    if type(list) ~= 'table' or type(list.faults) ~= 'table' then return end
    local active = {}
    for _, f in ipairs(list.faults) do
        if tonumber(f.id) then active[tonumber(f.id)] = true upsertFaultJob(f) end
    end
    local open = MySQL.query.await("SELECT id, fault_id FROM opslabs_phone_opsnet_jobs WHERE kind = 'fault' AND status IN ('open', 'assigned')") or {}
    local changed = false
    for _, j in ipairs(open) do
        if j.fault_id and not active[j.fault_id] then
            local f = T('GetFault', j.fault_id)
            if type(f) ~= 'table' or f.status == 'fixed' or f.status == 'closed' then
                MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET status = 'completed', fault_status = ?, completed_at = COALESCE(completed_at, ?),
                    completed_name = COALESCE(completed_name, ?) WHERE id = ? AND status IN ('open', 'assigned')]],
                    { type(f) == 'table' and f.status or 'closed', type(f) == 'table' and tonumber(f.fixed_at) or os.time(), type(f) == 'table' and Clean(f.fixed_by or 'Closed', 60) or 'Closed', j.id })
                changed = true
            end
        end
    end
    if changed then jobsChanged() end
end

CreateThread(function()
    AwaitDatabase()
    Wait(5000)
    while true do
        if towersUp() then pcall(syncFaultJobs) end
        Wait(5 * 60 * 1000)
    end
end)

OnRegister('opsnetJobs', { 'jobs.view', 'planned.view' }, function(_, _, data, u)
    local filter = tostring(data.filter or 'available')
    local rows
    if filter == 'planned' or not hasPerm(u, 'jobs.view') then
        if not hasPerm(u, 'planned.view') and not hasPerm(u, 'jobs.view') then return { error = "You don't have permission to do that.", denied = true } end
        rows = MySQL.query.await(("SELECT * FROM opslabs_phone_opsnet_jobs WHERE kind = 'planned' AND status IN ('open', 'assigned') ORDER BY %s, created_at DESC LIMIT 100"):format(PRIO_ORDER))
    elseif filter == 'mine' then
        rows = MySQL.query.await(("SELECT * FROM opslabs_phone_opsnet_jobs WHERE assigned_to = ? AND status = 'assigned' ORDER BY %s, created_at DESC LIMIT 100"):format(PRIO_ORDER), { u.id })
    elseif filter == 'completed' then
        rows = MySQL.query.await("SELECT * FROM opslabs_phone_opsnet_jobs WHERE status IN ('completed', 'cancelled') ORDER BY COALESCE(completed_at, created_at) DESC LIMIT 60")
    elseif filter == 'all' then
        rows = MySQL.query.await(("SELECT * FROM opslabs_phone_opsnet_jobs WHERE status IN ('open', 'assigned') ORDER BY %s, created_at DESC LIMIT 150"):format(PRIO_ORDER))
    else
        rows = MySQL.query.await(("SELECT * FROM opslabs_phone_opsnet_jobs WHERE status = 'open' ORDER BY %s, created_at DESC LIMIT 100"):format(PRIO_ORDER))
    end
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = jobView(r, u) end
    local counts = MySQL.single.await([[SELECT SUM(status = 'open') AS available, SUM(status = 'assigned' AND assigned_to = ?) AS mine FROM opslabs_phone_opsnet_jobs]], { u.id }) or {}
    return { jobs = out, counts = { available = tonumber(counts.available) or 0, mine = tonumber(counts.mine) or 0 } }
end)

local function cleanFault(f, u)
    if type(f) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(f) do out[k] = v end
    local aff = {}
    if type(f.affected) == 'table' and hasPerm(u, 'customers.view') then
        for _, a in ipairs(f.affected) do
            aff[#aff + 1] = { ont_id = a.ont_id, customer = a.customer, username = a.username, provider = a.provider, ip = hasPerm(u, 'customers.ip') and a.ip or nil }
        end
    end
    out.affected = aff
    out.affected_count = tonumber(f.affected_count) or (type(f.affected) == 'table' and #f.affected) or 0
    return out
end

OnRegister('opsnetJob', { 'jobs.view', 'planned.view' }, function(_, _, data, u)
    local r = MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_jobs WHERE id = ?', { tonumber(data.id) })
    if not r then return { error = 'Job not found' } end
    if r.kind ~= 'planned' and not hasPerm(u, 'jobs.view') then return { error = "You don't have permission to do that.", denied = true } end
    local job = jobView(r, u)
    if r.fault_id and hasPerm(u, 'faults.view') then job.fault = cleanFault(T('GetFault', r.fault_id), u) end
    local s = paySettings()
    job.bonus = s.Bonus.Enabled and s.Bonus.Amount > 0 and { hours = s.Bonus.Hours, amount = s.Bonus.Amount } or nil
    job.radius = PLANNED_RADIUS
    return job
end)

OnRegister('opsnetAcceptJob', 'jobs.take', function(_, _, data, u)
    local n = MySQL.update.await("UPDATE opslabs_phone_opsnet_jobs SET status = 'assigned', assigned_to = ?, assigned_name = ? WHERE id = ? AND status = 'open'",
        { u.id, Clean(displayName(u), 60), tonumber(data.id) })
    if n ~= 1 then return { error = 'Someone else already took this job.' } end
    jobsChanged()
    return { ok = true }
end)

OnRegister('opsnetReleaseJob', { 'jobs.take', 'jobs.manage' }, function(_, _, data, u)
    local r = MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_jobs WHERE id = ?', { tonumber(data.id) })
    if not r or r.status ~= 'assigned' then return { error = 'This job is not assigned.' } end
    if r.assigned_to ~= u.id and not hasPerm(u, 'jobs.manage') then return { error = "You don't have permission to do that.", denied = true } end
    MySQL.update.await("UPDATE opslabs_phone_opsnet_jobs SET status = 'open', assigned_to = NULL, assigned_name = NULL WHERE id = ? AND status = 'assigned'", { r.id })
    jobsChanged()
    return { ok = true }
end)

OnRegister('opsnetEngineers', 'jobs.manage', function()
    local rows = MySQL.query.await('SELECT id, username, display_name, role, perms FROM opslabs_phone_opsnet_users WHERE disabled = 0 ORDER BY display_name') or {}
    local out = {}
    for _, r in ipairs(rows) do
        for _, p in ipairs(permList(r)) do
            if p == 'jobs.take' then out[#out + 1] = { id = r.id, name = displayName(r), username = r.username } break end
        end
    end
    return out
end)

OnRegister('opsnetAssignJob', 'jobs.manage', function(src, _, data, u)
    local target = getUser(data.userId)
    if not target or IsTrue(target.disabled) then return { error = 'Engineer not found' } end
    local ok = false
    for _, p in ipairs(permList(target)) do if p == 'jobs.take' then ok = true end end
    if not ok then return { error = 'That user cannot take jobs (needs jobs.take).' } end
    local n = MySQL.update.await("UPDATE opslabs_phone_opsnet_jobs SET status = 'assigned', assigned_to = ?, assigned_name = ? WHERE id = ? AND status IN ('open', 'assigned')",
        { target.id, Clean(displayName(target), 60), tonumber(data.id) })
    if n ~= 1 then return { error = 'This job can no longer be assigned.' } end
    for s, uid in pairs(sessions) do
        if uid == target.id and s ~= src then Notify(s, { app = 'opsnet', title = 'Ops-Networks', icon = 'fa-clipboard-check', body = ('%s assigned you a job.'):format(displayName(u)), data = { page = 'jobs' } }) end
    end
    jobsChanged()
    return { ok = true }
end)

OnRegister('opsnetCancelJob', 'jobs.manage', function(_, _, data, u)
    local n = MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET status = 'cancelled', completed_at = ?, completed_name = ?
        WHERE id = ? AND kind = 'planned' AND status IN ('open', 'assigned')]], { os.time(), Clean('Cancelled by ' .. displayName(u), 60), tonumber(data.id) })
    if n ~= 1 then return { error = 'Only open planned work can be cancelled.' } end
    jobsChanged()
    return { ok = true }
end)

local function findPole(id)
    local isp = T('GetIspList')
    if type(isp) ~= 'table' then return nil end
    for _, p in ipairs(isp.poles or {}) do if p.id == id then return p end end
    return nil
end

OnRegister('opsnetCreateJob', 'jobs.manage', function(src, _, data, u)
    local title = Clean(data.title, 120)
    if title == '' then return { error = 'A title is required.' } end
    local prio = PRIORITIES[data.priority] and data.priority or 'medium'
    local pay = clampInt(data.pay, 0, MAX_PLANNED_PAY, paySettings().Planned)
    local x, y, z, poleId
    local location = Clean(data.location, 160)
    if data.where == 'pole' then
        poleId = tonumber(data.poleId)
        local p = poleId and findPole(poleId)
        if not p then return { error = 'Pole not found (is the network system online?).' } end
        x, y, z = p.x, p.y, p.z
        if location == '' then location = ('Pole #%d · %s'):format(poleId, p.label or '') end
    else
        local c = GetEntityCoords(GetPlayerPed(src))
        x, y, z = c.x, c.y, c.z
    end
    local id = MySQL.insert.await([[INSERT INTO opslabs_phone_opsnet_jobs (kind, title, description, location, x, y, z, pole_id, priority, status, pay, created_by, created_at)
        VALUES ('planned', ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, ?)]],
        { title, Clean(data.description, 1000), location, x, y, z, poleId, prio, pay, Clean(displayName(u), 60), os.time() })
    jobsChanged()
    return { ok = true, id = id }
end)

OnRegister('opsnetCompleteJob', 'jobs.take', function(src, _, data, u)
    local r = MySQL.single.await('SELECT * FROM opslabs_phone_opsnet_jobs WHERE id = ?', { tonumber(data.id) })
    if not r then return { error = 'Job not found' } end
    if r.kind ~= 'planned' then return { error = 'Fault jobs complete automatically when the repair is done in the field.' } end
    if r.status ~= 'open' and not (r.status == 'assigned' and r.assigned_to == u.id) then return { error = 'This job is assigned to someone else or already finished.' } end
    local c = GetEntityCoords(GetPlayerPed(src))
    local d = #(vector3(c.x, c.y, c.z) - vector3(r.x + 0.0, r.y + 0.0, r.z + 0.0))
    if d > PLANNED_RADIUS then return { error = ('You need to be on site: %d m away (within %d m).'):format(math.floor(d), math.floor(PLANNED_RADIUS)), distance = d } end
    local n = MySQL.update.await([[UPDATE opslabs_phone_opsnet_jobs SET status = 'completed', paid = 1, paid_amount = pay, completed_at = ?, completed_by = ?,
        completed_name = ?, assigned_to = ?, assigned_name = COALESCE(assigned_name, ?) WHERE id = ? AND paid = 0 AND status IN ('open', 'assigned')]],
        { os.time(), u.id, Clean(displayName(u), 60), u.id, Clean(displayName(u), 60), r.id })
    if n ~= 1 then return { error = 'This job was already completed.' } end
    payUser(src, u, r.pay, 0, r.title, r.id)
    jobsChanged()
    return { ok = true, paid = r.pay }
end)

---------------------------------------------------------------------------
-- information screens
---------------------------------------------------------------------------

OnRegister('opsnetFaults', 'faults.view', function(_, _, data, u)
    local list, err = T('GetFaults', { status = data.status == 'all' and 'all' or 'active', limit = 200 })
    if type(list) ~= 'table' then return { error = err or 'Faults are unavailable.', offline = true } end
    local out = {}
    for _, f in ipairs(list.faults or {}) do out[#out + 1] = cleanFault(f, u) end
    return { faults = out, stats = list.stats }
end)

OnRegister('opsnetFault', 'faults.view', function(_, _, data, u)
    local f, err = T('GetFault', tonumber(data.id))
    if type(f) ~= 'table' then return { error = err or 'Fault not found' } end
    local out = cleanFault(f, u)
    local job = MySQL.single.await('SELECT id, status, assigned_name FROM opslabs_phone_opsnet_jobs WHERE fault_id = ?', { f.id })
    out.job = job
    return out
end)

OnRegister('opsnetFaultAction', 'faults.manage', function(_, _, data, u)
    local id = tonumber(data.id)
    local actor = displayName(u)
    local ok, err
    if data.action == 'ack' then ok, err = T('AckFault', id, actor)
    elseif data.action == 'note' then
        local text = Clean(data.text, 300)
        if text == '' then return { error = 'Write a note first.' } end
        ok, err = T('AddFaultNote', id, actor, text)
    elseif data.action == 'close' then
        ok, err = T('CloseFault', id, actor, data.text and Clean(data.text, 300) or nil)
    else return { error = 'Unknown action' } end
    if not ok then return { error = err or 'The network system refused that.' } end
    return { ok = true }
end)

local ONT_FIELDS = { 'id', 'x', 'y', 'z', 'customer', 'username', 'provider', 'providerColor', 'plan', 'down', 'up', 'service', 'serial', 'rx',
    'distance', 'joints', 'los', 'pon', 'internet', 'uptime', 'fault', 'hardware', 'lowLight', 'lanName' }
local IP_FIELDS = { 'ip', 'gateway', 'mac', 'lan_subnet' }

OnRegister('opsnetCustomers', 'customers.view', function(_, _, _, u)
    local isp, err = T('GetIspList')
    if type(isp) ~= 'table' then return { error = err or 'Customer data is unavailable.', offline = true } end
    local ip = hasPerm(u, 'customers.ip')
    local out = {}
    for _, o in ipairs(isp.onts or {}) do
        local r = {}
        for _, k in ipairs(ONT_FIELDS) do r[k] = o[k] end
        if ip then for _, k in ipairs(IP_FIELDS) do r[k] = o[k] end end
        out[#out + 1] = r
    end
    return { onts = out, stats = isp.stats, ip = ip }
end)

OnRegister('opsnetNetwork', 'network.view', function()
    local isp, err = T('GetIspList')
    if type(isp) ~= 'table' then return { error = err or 'Network data is unavailable.', offline = true } end
    local links, fibreM, cableM, litLinks = {}, 0, 0, 0
    for _, l in ipairs(isp.links or {}) do
        links[#links + 1] = { id = l.id, kind = l.kind, length = l.length, lit = l.lit, color = l.color }
        if l.kind == 'fibre' then fibreM = fibreM + (l.length or 0) else cableM = cableM + (l.length or 0) end
        if l.lit then litLinks = litLinks + 1 end
    end
    table.sort(links, function(a, b) return (a.length or 0) > (b.length or 0) end)
    local towers = {}
    local raw = T('GetTowers')
    for _, t in pairs(type(raw) == 'table' and raw or {}) do
        if type(t) == 'table' then
            towers[#towers + 1] = { id = t.id, type = t.type, name = t.name, x = t.x, y = t.y, z = t.z, range = t.range, ssid = t.ssid, active = t.active, model = t.model }
        end
    end
    table.sort(towers, function(a, b) return (a.id or 0) < (b.id or 0) end)
    local kit = {}
    for _, k in ipairs(isp.kit or {}) do kit[#kit + 1] = { id = k.id, model = k.model, label = k.label, x = k.x, y = k.y, lit = k.lit, headend = k.headend } end
    table.sort(kit, function(a, b) if a.headend ~= b.headend then return a.headend == true end return a.id < b.id end)
    local faults = T('GetFaults', { status = 'active', limit = 1 })
    return {
        kit = kit, links = links, towers = towers, stats = isp.stats,
        totals = { fibre = fibreM, cable = cableM, lit = litLinks, links = #links, poles = #(isp.poles or {}) },
        faults = type(faults) == 'table' and faults.stats or nil,
    }
end)

OnRegister('opsnetPoles', 'poles.view', function(_, _, _, u)
    local isp, err = T('GetIspList')
    if type(isp) ~= 'table' then return { error = err or 'Pole data is unavailable.', offline = true } end
    local faultsById = {}
    if hasPerm(u, 'faults.view') then
        local list = T('GetFaults', { status = 'active', limit = 500 })
        for _, f in ipairs(type(list) == 'table' and list.faults or {}) do faultsById[f.id] = { id = f.id, label = f.label, severity = f.severity, status = f.status } end
    end
    local out = {}
    for _, p in ipairs(isp.poles or {}) do
        local fl = {}
        for _, fid in ipairs(type(p.faults) == 'table' and p.faults or {}) do fl[#fl + 1] = faultsById[fid] or { id = fid } end
        out[#out + 1] = { id = p.id, label = p.label, model = p.model, x = p.x, y = p.y, z = p.z, height = p.height, status = p.status, lit = p.lit,
            house = p.house, cables = p.cables, fibres = p.fibres, equipment = p.equipment, faults = fl }
    end
    return { poles = out }
end)

OnRegister('opsnetEarnings', 'payments.view', function(_, _, _, u)
    local rows = MySQL.query.await('SELECT id, job_id, label, amount, bonus, created_at FROM opslabs_phone_opsnet_payments WHERE user_id = ? ORDER BY id DESC LIMIT 100', { u.id }) or {}
    local t = MySQL.single.await([[SELECT COALESCE(SUM(amount + bonus), 0) AS total, COUNT(*) AS jobs,
        COALESCE(SUM(IF(created_at > ?, amount + bonus, 0)), 0) AS week FROM opslabs_phone_opsnet_payments WHERE user_id = ?]], { os.time() - 7 * 86400, u.id }) or {}
    return { payments = rows, total = tonumber(t.total) or 0, week = tonumber(t.week) or 0, jobs = tonumber(t.jobs) or 0, rates = paySettings() }
end)

local FALLBACK_WIFI = {
    { model = 'home_router', label = 'Home router', range = 30 },
    { model = 'indoor_ap', label = 'Indoor access point', range = 45 },
    { model = 'mesh_node', label = 'Mesh node', range = 35 },
    { model = 'outdoor_ap', label = 'Outdoor access point', range = 120 },
    { model = 'sector', label = 'Long-range sector', range = 250 },
}

OnRegister('opsnetWifiModels', 'rangetest.use', function()
    local list = T('GetWifiModels')
    local out = {}
    for _, m in ipairs(type(list) == 'table' and list or {}) do
        local r = tonumber(m.range)
        if r and r > 0 then out[#out + 1] = { model = tostring(m.model or ''), label = tostring(m.label or m.model or 'Wi-Fi'), range = math.min(r, 1000) } end
    end
    if #out == 0 then return { models = FALLBACK_WIFI, fallback = true } end
    return { models = out }
end)

---------------------------------------------------------------------------
-- admin panel
---------------------------------------------------------------------------

local function activeAdmins(exceptId)
    return MySQL.scalar.await("SELECT COUNT(*) FROM opslabs_phone_opsnet_users WHERE role = 'admin' AND disabled = 0 AND id <> ?", { exceptId or 0 }) or 0
end

OnRegister('opsnetAdminUsers', { 'admin.users', 'admin.permissions' }, function()
    local rows = MySQL.query.await([[SELECT o.id, o.username, o.display_name, o.role, o.perms, o.disabled, o.default_pw, o.identifier, o.created_at, o.last_login,
        u.firstname, u.lastname FROM opslabs_phone_opsnet_users o LEFT JOIN users u ON u.identifier = o.identifier ORDER BY o.disabled, o.username]]) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local perms = permList(r)
        local char = ((r.firstname or '') .. ' ' .. (r.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
        out[#out + 1] = {
            id = r.id, username = r.username, name = displayName(r), role = r.role, perms = perms, pending = #perms == 0,
            disabled = IsTrue(r.disabled), defaultPassword = IsTrue(r.default_pw), linked = r.identifier ~= nil,
            character = char ~= '' and char or nil, online = r.identifier and GetSourceByIdentifier(r.identifier) ~= nil or false,
            createdAt = r.created_at, lastLogin = r.last_login,
        }
    end
    return { users = out, perms = PERMS, presets = PRESETS }
end)

OnRegister('opsnetAdminSaveUser', { 'admin.users', 'admin.permissions' }, function(_, _, data, u)
    local id = tonumber(data.id)
    local target = id and getUser(id)
    if id and not target then return { error = 'User not found' } end
    local canUsers, canPerms = hasPerm(u, 'admin.users'), hasPerm(u, 'admin.permissions')

    if not target then
        if not canUsers then return { error = "You don't have permission to create users.", denied = true } end
        local username = cleanUsername(data.username)
        if not username then return { error = 'Usernames are 3-24 characters: letters, numbers, dot, dash or underscore.' } end
        local password = tostring(data.password or '')
        if #password < 6 then return { error = 'Use a password of at least 6 characters.' } end
        if MySQL.scalar.await('SELECT 1 FROM opslabs_phone_opsnet_users WHERE username = ?', { username }) then return { error = 'That username is taken.' } end
        local role, perms = 'custom', {}
        if canPerms then
            role = PRESET_BY_ID[data.role] and data.role or 'custom'
            perms = cleanPermList(data.perms)
            if role == 'admin' and u.role ~= 'admin' then return { error = 'Only administrators can create administrators.' } end
        end
        local hash = hashPassword(password)
        if not hash then return { error = 'Could not create the account right now.' } end
        local newId = MySQL.insert.await([[INSERT INTO opslabs_phone_opsnet_users (username, pass_hash, display_name, role, perms, created_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], { username, hash, Clean(data.name or username, 60), role, json.encode(perms), Clean(u.username, 60), os.time() })
        return { ok = true, id = newId }
    end

    -- editing an administrator (or making one) is reserved for administrators
    if (target.role == 'admin' or data.role == 'admin') and u.role ~= 'admin' then
        return { error = 'Only administrators can change administrator accounts.' }
    end
    local sets, vals = {}, {}
    if data.name ~= nil and canUsers then sets[#sets + 1] = 'display_name = ?' vals[#vals + 1] = Clean(data.name, 60) end
    if data.disabled ~= nil and canUsers then
        local dis = data.disabled == true
        if dis and target.id == u.id then return { error = "You can't disable your own account." } end
        if dis and target.role == 'admin' and activeAdmins(target.id) == 0 then return { error = "You can't disable the last administrator." } end
        sets[#sets + 1] = 'disabled = ?' vals[#vals + 1] = dis and 1 or 0
    end
    if (data.role ~= nil or data.perms ~= nil) then
        if not canPerms then return { error = "You don't have permission to change permissions.", denied = true } end
        local role = PRESET_BY_ID[data.role] and data.role or 'custom'
        if target.role == 'admin' and role ~= 'admin' and activeAdmins(target.id) == 0 then return { error = 'There must be at least one administrator.' } end
        sets[#sets + 1] = 'role = ?' vals[#vals + 1] = role
        sets[#sets + 1] = 'perms = ?' vals[#vals + 1] = json.encode(cleanPermList(data.perms))
    end
    if #sets == 0 then return { ok = true } end
    vals[#vals + 1] = target.id
    MySQL.update.await(('UPDATE opslabs_phone_opsnet_users SET %s WHERE id = ?'):format(table.concat(sets, ', ')), vals)
    -- disabled accounts are signed out everywhere
    if data.disabled == true then for s, uid in pairs(sessions) do if uid == target.id then sessions[s] = nil end end end
    for s, uid in pairs(sessions) do if uid == target.id then Push(s, 'opsnetMeChanged', true) end end
    return { ok = true }
end)

OnRegister('opsnetAdminDeleteUser', 'admin.users', function(_, _, data, u)
    local target = getUser(data.id)
    if not target then return { error = 'User not found' } end
    if target.id == u.id then return { error = "You can't delete your own account." } end
    if target.role == 'admin' and u.role ~= 'admin' then return { error = 'Only administrators can delete administrators.' } end
    if target.role == 'admin' and activeAdmins(target.id) == 0 then return { error = "You can't delete the last administrator." } end
    MySQL.update.await('DELETE FROM opslabs_phone_opsnet_users WHERE id = ?', { target.id })
    MySQL.update.await("UPDATE opslabs_phone_opsnet_jobs SET status = 'open', assigned_to = NULL, assigned_name = NULL WHERE assigned_to = ? AND status = 'assigned'", { target.id })
    for s, uid in pairs(sessions) do if uid == target.id then sessions[s] = nil end end
    jobsChanged()
    return { ok = true }
end)

OnRegister('opsnetAdminResetPassword', 'admin.users', function(_, _, data, u)
    local target = getUser(data.id)
    if not target then return { error = 'User not found' } end
    if target.role == 'admin' and u.role ~= 'admin' then return { error = 'Only administrators can reset administrator passwords.' } end
    local password = tostring(data.password or '')
    if #password < 6 or #password > 128 then return { error = 'Use a password of at least 6 characters.' } end
    local hash = hashPassword(password)
    if not hash then return { error = 'Could not reset the password right now.' } end
    MySQL.update.await('UPDATE opslabs_phone_opsnet_users SET pass_hash = ?, default_pw = ? WHERE id = ?', { hash, password == DEFAULT_ADMIN_PASS and 1 or 0, target.id })
    return { ok = true }
end)

OnRegister('opsnetAdminPay', 'admin.payments', function() return payView() end)
OnRegister('opsnetAdminSavePay', 'admin.payments', function(_, _, data, u) return savePaySettings(data, 'Ops-Networks/' .. u.username) end)
OnRegister('opsnetAdminFaults', 'admin.faults', function() return faultSettingsView() end)
OnRegister('opsnetAdminSaveFaults', 'admin.faults', function(_, _, data, u) return saveFaultSettings(data, displayName(u)) end)
OnRegister('opsnetAdminTriggerFault', 'admin.faults', function(_, _, data, u) return triggerFault(data.type, displayName(u)) end)
OnRegister('opsnetAdminCloseFault', { 'admin.faults', 'faults.manage' }, function(_, _, data, u) return closeFault(data.id, displayName(u), data.note) end)
OnRegister('opsnetAdminRender', { 'admin.render', 'admin.faults' }, function() return renderView() end)
OnRegister('opsnetAdminSaveRender', { 'admin.render', 'admin.faults' }, function(_, _, data, u) return saveRender(data, displayName(u)) end)

---------------------------------------------------------------------------
-- Developer app pages: Network faults, Engineer pay, Render distance
---------------------------------------------------------------------------

local function DevOnly(name, handler)
    Register(name, function(src, phone, data)
        if not IsDev or not IsDev(src) then return { error = 'Please sign in to the Developer app', loggedOut = true } end
        return handler(src, phone, data)
    end)
end

DevOnly('devOpsFaults', function() local v = faultSettingsView() v.catalogue = faultTypes() return v end)
DevOnly('devOpsSaveFaults', function(_, phone, data) return saveFaultSettings(data, 'Developer/' .. phone.name) end)
DevOnly('devOpsTriggerFault', function(_, phone, data) return triggerFault(data.type, 'Developer/' .. phone.name) end)
DevOnly('devOpsCloseFault', function(_, phone, data) return closeFault(data.id, 'Developer/' .. phone.name, data.note) end)
DevOnly('devOpsPay', function() return payView() end)
DevOnly('devOpsSavePay', function(_, phone, data) return savePaySettings(data, 'Developer/' .. phone.name) end)
DevOnly('devOpsRender', function() return renderView() end)
DevOnly('devOpsSaveRender', function(_, phone, data) return saveRender(data, 'Developer/' .. phone.name) end)

-- the OPS platform (server/platform.lua) shares these accounts and sessions
function OpsnetUser(src) return currentUser(src) end
function OpsnetHasPerm(u, perm) return hasPerm(u, perm) end
