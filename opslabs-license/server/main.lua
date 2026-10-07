-- OPSHUB licensing for this server.
--
--   OPSHUB licensing API → license → customer → this instance → the modules it may run
--
-- First run: no key → the OPS Phone shows the OPSHUB license screen; an admin enters the key (or it's in config.lua /
-- `set opshub_license`). The key is activated: OPSHUB registers this instance (a random id kept by this resource), and
-- returns a secret for check-ins plus a signed certificate listing the modules. After that the key is never asked for
-- again unless the license is reset, revoked or the instance is released.
--
-- The certificate is only believed when its Ed25519 signature checks out (server/verify.js, Config.PublicKey) and it's
-- for this instance. It's cached, so a restart or an OPSHUB outage doesn't stop the server until it runs out
-- (valid_until, OPSHUB's grace period). Check-ins every Config.CheckEvery seconds pick up changes made on OPSHUB.
--
-- Everything else asks here:  exports['opslabs-license']:HasModule('pos')  /  :IsLicensed()  /  :State()
-- and resource modules (OPS resources) are started / stopped to match the license (Config.Enforce).

local RES = GetCurrentResourceName()
math.randomseed(os.time() + GetGameTimer())
local VERSION = GetResourceMetadata(RES, 'version', 0) or '1.0.0'

local State = { status = 'starting', message = 'Checking the OPSHUB license…', modules = {}, allowAll = false }
local Cert = nil                 -- the verified certificate (table)
local stoppedByUs = {}           -- resource name -> true (we stopped it; we may start it again)

local function log(msg, colour) print(('^%d[OPSHUB]^7 %s'):format(colour or 5, msg)) end

---------------------------------------------------------------------------
-- local storage (resource KVP: survives restarts, stays with this server)
---------------------------------------------------------------------------
local function kv(k) local v = GetResourceKvpString(k) return v ~= '' and v or nil end
local function setKv(k, v) if v == nil then DeleteResourceKvp(k) else SetResourceKvp(k, tostring(v)) end end

--- this installation's id: random, made once, never leaves this server except to OPSHUB
local function instanceUid()
    local uid = kv('instance_uid')
    if not uid then
        local hex, t = '0123456789abcdef', {}
        for i = 1, 32 do local n = math.random(1, 16) t[i] = hex:sub(n, n) end
        uid = ('%s-%x'):format(table.concat(t), os.time())
        setKv('instance_uid', uid)
    end
    return uid
end

local function licenseKey()
    local k = GetConvar('opshub_license', '')
    if k == '' then k = Config.LicenseKey or '' end
    if k == '' then k = kv('license_key') or '' end
    k = k:upper():gsub('%s', '')
    return k ~= '' and k or nil
end

---------------------------------------------------------------------------
-- talking to OPSHUB
---------------------------------------------------------------------------
local function call(path, body)
    local p = promise.new()
    PerformHttpRequest(Config.Api .. path, function(status, text)
        local ok, data = pcall(json.decode, text or '')
        p:resolve({ status = status or 0, data = ok and type(data) == 'table' and data or {} })
    end, 'POST', json.encode(body or {}), { ['Content-Type'] = 'application/json', ['User-Agent'] = 'opslabs-license/' .. VERSION })
    return Citizen.Await(p)
end

--- the OPS resources on this server and their state (OPSHUB shows it on the instance)
local function ourResources()
    local out = {}
    for i = 0, GetNumResources() - 1 do
        local r = GetResourceByFindIndex(i)
        if r and (r:find('^opslabs%-') or r:find('^rps_')) then out[r] = GetResourceState(r) end
    end
    return out
end

---------------------------------------------------------------------------
-- the certificate: verify, then act on it
---------------------------------------------------------------------------
local function verify(certB64, sigB64)
    local ok, text = pcall(function() return exports[RES]:verifyCertificate(certB64, sigB64, Config.PublicKey) end)
    if not ok or not text then return nil, 'signature' end
    local okJ, c = pcall(json.decode, text)
    if not okJ or type(c) ~= 'table' or c.iss ~= 'OPSHUB' then return nil, 'format' end
    if c.uid ~= instanceUid() then return nil, 'instance' end                 -- someone else's certificate
    return c
end

local function publicState()
    local mods = {}
    for k in pairs(State.modules) do mods[#mods + 1] = k end
    table.sort(mods)
    return { status = State.status, message = State.message, allowAll = State.allowAll, modules = mods, customer = State.customer,
        keyTail = State.keyTail, expiresAt = State.expiresAt, validUntil = State.validUntil, instance = State.instance, checkedAt = State.checkedAt }
end

--- start / stop the OPS resources to match the license
local function enforce()
    if not Config.Enforce or not Cert or type(Cert.resources) ~= 'table' then return end
    local licensed = State.status == 'active'
    for code, res in pairs(Cert.resources) do
        if type(res) == 'string' and not Config.Protected[res] and GetResourceState(res) ~= 'missing' then
            local allowed = licensed and State.modules[code] == true
            local st = GetResourceState(res)
            if allowed and (st == 'stopped') and stoppedByUs[res] then
                log(('starting %s (module %s)'):format(res, code), 2)
                stoppedByUs[res] = nil
                StartResource(res)
            elseif not allowed and (st == 'started' or st == 'starting') then
                log(('stopping %s — module "%s" is not in this license'):format(res, code), 3)
                stoppedByUs[res] = true
                StopResource(res)
            end
        end
    end
    setKv('stopped_by_us', json.encode(stoppedByUs))
end

local function broadcast()
    local s = publicState()
    TriggerEvent('opslabs-license:state', s)
    TriggerClientEvent('opslabs-license:state', -1, s)
end

local function apply(c, sourceNote)
    Cert = c
    local mods = {}
    for _, m in ipairs(c.modules or {}) do mods[m] = true end
    local now = os.time()
    local status = c.status or 'invalid'
    if status == 'active' and (c.valid_until or 0) < now then status = 'expired' end
    local before = State.status
    State = {
        status = status, modules = status == 'active' and mods or {}, allowAll = c.allow_all == true and status == 'active',
        customer = c.customer, keyTail = c.key_tail, expiresAt = c.expires_at, validUntil = c.valid_until, instance = c.inst, checkedAt = now,
        message = status == 'active' and ('Licensed to %s'):format(c.customer or 'this server')
            or ({ suspended = 'This OPSHUB license is suspended', revoked = 'This OPSHUB license has been revoked',
                  expired = 'This OPSHUB license has expired — the server couldn\'t reach OPSHUB to renew it' })[status] or 'License not valid',
    }
    if before ~= State.status then
        log(('license %s%s · %d module(s)%s'):format(State.status, sourceNote and (' (' .. sourceNote .. ')') or '',
            #(c.modules or {}), State.allowAll and ' · Allow All' or ''), State.status == 'active' and 2 or 1)
    end
    enforce()
    broadcast()
end

local function unlicensed(message, status)
    State = { status = status or 'unlicensed', message = message, modules = {}, allowAll = false, checkedAt = os.time() }
    log(message, 3)
    if Cert then Cert.modules = {} end
    enforce()
    broadcast()
end

---------------------------------------------------------------------------
-- activate / check in / release
---------------------------------------------------------------------------
local busy = false

--- activate `key` for this instance. Returns true or an error message.
local function activate(key, who)
    key = tostring(key or ''):upper():gsub('%s', '')
    if not key:match('^OPSHUB%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w$') then return 'That isn\'t an OPSHUB key (OPSHUB-XXXX-XXXX-XXXX-XXXX)' end
    local r = call('/activate', { key = key, instance_uid = instanceUid(), name = GetConvar('sv_hostname', 'FiveM server'):sub(1, 120),
        version = VERSION, resources = ourResources() })
    if r.status ~= 200 or not r.data.ok then
        local msg = r.data.error or (r.status == 0 and 'OPSHUB can\'t be reached right now' or ('OPSHUB said no (%d)'):format(r.status))
        log(('activation failed%s: %s'):format(who and (' (' .. who .. ')') or '', msg), 1)
        return msg
    end
    local c, why = verify(r.data.cert, r.data.sig)
    if not c then
        log('OPSHUB\'s answer failed verification (' .. why .. ') — not trusted', 1)
        return 'The license answer couldn\'t be verified'
    end
    setKv('license_key', key)
    setKv('instance_id', r.data.instance_id)
    setKv('instance_secret', r.data.secret)
    setKv('cert', r.data.cert)
    setKv('sig', r.data.sig)
    log(('activated%s — instance #%s'):format(who and (' by ' .. who) or '', tostring(r.data.instance_id)), 2)
    apply(c, 'activated')
    return true
end

local function checkIn()
    local iid, secret = kv('instance_id'), kv('instance_secret')
    if not iid or not secret then
        local key = licenseKey()
        if key then return activate(key, 'config') end
        return unlicensed('No OPSHUB license yet — an admin enters the key on the OPS Phone (or in opslabs-license/config.lua)')
    end
    local r = call('/check', { instance_id = tonumber(iid), secret = secret, version = VERSION, resources = ourResources() })
    if r.status == 0 or r.status >= 500 then
        -- OPSHUB unreachable: keep going on the cached certificate until it runs out
        if Cert and (Cert.valid_until or 0) > os.time() then
            State.message = 'OPSHUB unreachable — running on the cached license'
            return true
        end
        return unlicensed('OPSHUB can\'t be reached and the cached license has run out', 'expired')
    end
    if r.status == 401 then
        -- the instance was released (portal / admin) or the secret is gone: try the key again
        setKv('instance_id', nil) setKv('instance_secret', nil)
        local key = licenseKey()
        if key then return activate(key, 'reactivate') end
        return unlicensed('This server was released from its OPSHUB license — enter the key again')
    end
    if r.data.cert then
        local c, why = verify(r.data.cert, r.data.sig)
        if not c then
            log('check-in answer failed verification (' .. why .. ') — ignored', 1)
            return false
        end
        setKv('cert', r.data.cert) setKv('sig', r.data.sig)
        apply(c, 'check-in')
        return true
    end
    return unlicensed(r.data.error or ('OPSHUB refused the check-in (%d)'):format(r.status), r.data.status or 'invalid')
end

local function release()
    local iid, secret = kv('instance_id'), kv('instance_secret')
    if iid and secret then call('/deactivate', { instance_id = tonumber(iid), secret = secret }) end
    for _, k in ipairs({ 'instance_id', 'instance_secret', 'cert', 'sig', 'license_key' }) do setKv(k, nil) end
    Cert = nil
    unlicensed('License released from this server — enter a key to activate it again')
end

---------------------------------------------------------------------------
-- start-up and the check-in loop
---------------------------------------------------------------------------
CreateThread(function()
    math.randomseed(GetGameTimer() + os.time())
    local okS, s = pcall(json.decode, kv('stopped_by_us') or '{}')
    stoppedByUs = okS and type(s) == 'table' and s or {}
    -- the cached certificate first: the server runs straight away, even if OPSHUB is slow or down
    local cert, sig = kv('cert'), kv('sig')
    if cert and sig then
        local c = verify(cert, sig)
        if c and (c.valid_until or 0) > os.time() then apply(c, 'cached') end
    end
    Wait(2000)
    while true do
        if not busy then busy = true pcall(checkIn) busy = false end
        Wait((Config.CheckEvery or 600) * 1000)
    end
end)

---------------------------------------------------------------------------
-- API for every other OPS resource (the only license check any of them does)
---------------------------------------------------------------------------
exports('State', function() return publicState() end)
exports('IsLicensed', function() return State.status == 'active' end)
exports('HasModule', function(code) return State.status == 'active' and State.modules[tostring(code)] == true end)

local function isAdmin(src)
    if src == 0 then return true end
    return IsPlayerAceAllowed(src, Config.AdminAce or 'opshub.license') or IsPlayerAceAllowed(src, 'command')
end
exports('CanManage', function(src) return isAdmin(tonumber(src) or -1) end)

--- the OPS Phone's license screen (an admin enters the key) → true or an error message
exports('Activate', function(src, key)
    if not isAdmin(src) then return 'Only a server admin can activate the license' end
    if busy then return 'Already talking to OPSHUB — try again in a moment' end
    busy = true
    local ok, res = pcall(activate, key, src ~= 0 and GetPlayerName(src) or 'console')
    busy = false
    return ok and res or 'Activation failed'
end)

exports('Refresh', function() if not busy then busy = true pcall(checkIn) busy = false end return publicState() end)

-- console: opshub status | opshub activate OPSHUB-XXXX-… | opshub refresh | opshub release
RegisterCommand('opshub', function(src, args)
    if src ~= 0 and not isAdmin(src) then return end
    local cmd = (args[1] or 'status'):lower()
    if cmd == 'activate' and args[2] then
        local r = activate(args[2], 'console')
        log(r == true and 'activated' or ('failed: ' .. tostring(r)), r == true and 2 or 1)
    elseif cmd == 'refresh' then
        busy = true pcall(checkIn) busy = false
    elseif cmd == 'release' then
        release()
    end
    local s = publicState()
    log(('%s · %s · modules: %s · instance %s · valid until %s'):format(s.status, s.message or '', s.allowAll and 'ALL' or table.concat(s.modules, ', '),
        tostring(s.instance or '-'), s.validUntil and os.date('%Y-%m-%d %H:%M', s.validUntil) or '-'))
end, true)

-- players joining get the current state (the phone UI uses it)
RegisterNetEvent('opslabs-license:hello', function() TriggerClientEvent('opslabs-license:state', source, publicState()) end)
