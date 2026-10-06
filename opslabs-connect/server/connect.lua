-- opslabs-connect: this server ↔ the OPS Hub (multi-server, /new-hub).
--
-- Hosted mode (a server token is set): OPS tables (ops_* / opslabs_*) live in this server's own database on the
-- OPS Hub. opslabs-phone and opslabs-towers include lib/db.lua, which sends their OPS queries here; this file runs
-- them through the Hub API (POST /api/v1/db, authenticated by the token) and hands back exactly what oxmysql would.
-- Framework tables (users, billing, owned_vehicles …) never leave your server. Player names + jobs are mirrored to
-- the hosted `users` table (never money or inventory) so staff lists and reports can show names.
--
-- No token: nothing changes — OPS uses your local oxmysql database (self-hosted / single-server set-ups).

local RES = GetCurrentResourceName()
local VERSION = GetResourceMetadata(RES, 'version', 0) or '1.0.0'
local API = (GetConvar('ops_api_url', 'https://opsphone-store.opslabsystems.cloud'):gsub('/+$', ''))

local state = {
    token = '', source = 'none',          -- convar | devapp | none
    connected = false, dbReady = false, server = nil, hub = nil,
    lastError = nil, lastSeen = 0, pairing = nil, warned = false,
}

local function log(msg, ...)
    print(('^5[opslabs-connect]^7 ' .. msg):format(...))
end

local function loadToken()
    local cv = GetConvar('ops_server_token', '')
    if cv ~= '' then
        state.token, state.source = cv, 'convar'
    else
        local kvp = GetResourceKvpString('token') or ''
        state.token, state.source = kvp, kvp ~= '' and 'devapp' or 'none'
    end
end
loadToken()

-- the REST API key opslabs-phone uses — the Hub needs it to call your server; created once if you have none
local function apiKey()
    local key = GetConvar('opslabs_phone_api_key', '')
    if #key >= 24 then return key end
    key = GetResourceKvpString('phone_api_key') or ''
    if #key < 24 then
        local chars, t = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789', {}
        math.randomseed(GetGameTimer() + os.time())
        for i = 1, 40 do local n = math.random(1, #chars) t[i] = chars:sub(n, n) end
        key = table.concat(t)
        SetResourceKvp('phone_api_key', key)
    end
    SetConvar('opslabs_phone_api_key', key)   -- opslabs-phone starts after us and reads it
    return key
end
if state.token ~= '' then apiKey() end

local function http(method, path, body, cb, retries)
    local headers = { ['Content-Type'] = 'application/json', ['User-Agent'] = 'opslabs-connect/' .. VERSION }
    if state.token ~= '' then headers['Authorization'] = 'Bearer ' .. state.token end
    PerformHttpRequest(API .. path, function(status, text)
        local data = nil
        if text and text ~= '' then data = json.decode(text) end
        cb(status or 0, data or {})
    end, method, body and json.encode(body) or '', headers)
end

local function httpAwait(method, path, body)
    local p = promise.new()
    http(method, path, body, function(status, data) p:resolve({ status, data }) end)
    local r = Citizen.Await(p)
    return r[1], r[2]
end

---------------------------------------------------------------------------------------------------- connect
local function framework()
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    return 'standalone'
end

local function publicUrl()
    local u = GetConvar('ops_public_url', '')
    if u ~= '' then return (u:gsub('/+$', '')) end
    local base = GetConvar('web_baseUrl', '')           -- e.g. abc123-xyz.users.cfx.re (set once the server is listed)
    if base ~= '' then return 'https://' .. base end
    return nil
end

local function resVersions()
    local out = {}
    for _, r in ipairs({ 'opslabs-phone', 'opslabs-towers', 'opslabs-props', 'oxmysql', 'ox_lib' }) do
        if GetResourceState(r) ~= 'missing' then out[r] = GetResourceMetadata(r, 'version', 0) or '?' end
    end
    return out
end

local function connect()
    if state.token == '' then return false end
    local status, data = httpAwait('POST', '/api/v1/connect', {
        version = resVersions()['opslabs-phone'], connect_version = VERSION, hostname = GetConvar('sv_projectName', GetConvar('sv_hostname', '')),
        players = #GetPlayers(), max_players = GetConvarInt('sv_maxclients', 0), framework = framework(), resources = resVersions(),
        game_build = GetConvar('sv_enforceGameBuild', ''), game_url = publicUrl(), api_key = apiKey(), mode = 'hosted',
    })
    if status == 200 and data.ok then
        local first = not state.connected
        state.connected, state.server, state.hub, state.lastError = true, data.server, data.hub, nil
        state.dbReady = data.db and data.db.ready or false
        state.lastSeen = os.time()
        if first then log('connected to ^2%s^7 (server #%s)%s', data.server.name, data.server.id, state.dbReady and '' or ' — database still being set up') end
        if data.warning and not state.warned then state.warned = true log('^3%s^7', data.warning) end
        return true
    end
    state.connected = false
    state.lastError = (data and data.error) or ('HTTP ' .. tostring(status))
    if status == 401 or status == 403 then
        log('^1the OPS Hub refused this server (%s)^7 — check ops_server_token, or pair again from the Dev App', state.lastError)
    else
        log('^3could not reach the OPS Hub (%s)^7 — retrying', state.lastError)
    end
    return false
end

CreateThread(function()
    if state.token == '' then
        log('no server token — OPS uses the local database. Connect on %s/new-hub or from the Dev App.', API)
        return
    end
    while true do
        if not state.connected or not state.dbReady then
            connect()
            Wait(state.connected and 10000 or 15000)
        else
            local status, data = httpAwait('POST', '/api/v1/heartbeat', { players = #GetPlayers() })
            if status == 200 and data.ok then
                state.lastSeen = os.time()
                state.dbReady = data.db and data.db.ready or false
            elseif status == 401 or status == 403 then
                state.connected, state.dbReady = false, false
                state.lastError = data.error
                log('^1token refused (%s)^7 — OPS database calls stop until this is fixed', tostring(data.error))
            end
            Wait(60000)
        end
    end
end)

local function waitReady(ms)
    local untilT = GetGameTimer() + ms
    while not (state.connected and state.dbReady) do
        if state.token == '' or GetGameTimer() > untilT then return false end
        Wait(250)
    end
    return true
end

---------------------------------------------------------------------------------------------------- database relay
local function normParams(params)
    if type(params) ~= 'table' then return {} end
    local n, named = 0, false
    for k in pairs(params) do
        if type(k) == 'number' then if k > n then n = k end else named = true end
    end
    if named then return params, true end
    local arr = {}
    for i = 1, n do
        local v = params[i]
        if v == nil then v = json.null end
        arr[i] = v
    end
    return arr, false
end

-- oxmysql-style named placeholders (@name / :name with a keyed table) → ? + array; skips quoted strings
local function convertNamed(sql, params)
    local out, args, i, len, quote = {}, {}, 1, #sql, nil
    while i <= len do
        local ch = sql:sub(i, i)
        if quote then
            out[#out + 1] = ch
            if ch == quote then quote = nil end
            i = i + 1
        elseif ch == "'" or ch == '"' or ch == '`' then
            quote = ch
            out[#out + 1] = ch
            i = i + 1
        elseif (ch == '@' or ch == ':') and sql:sub(i + 1, i + 1):match('[%a_]') and sql:sub(i - 1, i - 1) ~= ch then
            local name = sql:match('^[%w_]+', i + 1)
            local v = params[name]
            if v == nil then v = params[ch .. name] end
            if v == nil then v = json.null end
            args[#args + 1] = v
            out[#out + 1] = '?'
            i = i + 1 + #name
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out), args
end

local READONLY = { query = true, single = true, scalar = true }

local function relay(payload, attempt)
    local status, data = httpAwait('POST', '/api/v1/db', payload)
    if status == 200 and data.ok then return true, data.result end
    attempt = attempt or 1
    -- not executed (rate limit / not ready / Hub restarting) → safe to retry; connection lost → retry reads only
    local retry = status == 429 or status == 503 or status == 502 or (status == 0 and READONLY[payload.op] and attempt < 3)
    if retry and attempt < 5 then
        Wait(attempt * 400)
        if status == 503 then waitReady(15000) end
        return relay(payload, attempt + 1)
    end
    if status == 401 or status == 403 then state.connected = false end
    return false, (data and (data.message or data.error)) or ('OPS Hub unreachable (HTTP ' .. tostring(status) .. ')')
end

local function run(op, sql, params, invoker)
    if state.token == '' then return false, 'opslabs-connect: no server token' end
    if not waitReady(60000) then return false, 'opslabs-connect: not connected to the OPS Hub' .. (state.lastError and (' (' .. state.lastError .. ')') or '') end
    local payload
    if op == 'transaction' then
        local qs = {}
        for i, q in ipairs(sql) do
            local text, values
            if type(q) == 'string' then text, values = q, params
            else text, values = q.query or q[1], q.values or q.parameters or q[2] or params end
            local arr, named = normParams(values)
            if named then text, arr = convertNamed(text, arr) end
            qs[i] = { sql = text, params = arr }
        end
        payload = { op = 'transaction', queries = qs }
    else
        local arr, named = normParams(params)
        if named then sql, arr = convertNamed(sql, arr) end
        payload = { op = op, sql = sql, params = arr }
    end
    local ok, res = relay(payload)
    if not ok then
        local text = op == 'transaction' and '(transaction)' or tostring(sql):gsub('%s+', ' '):sub(1, 300)
        print(('^1[opslabs-connect] %s query failed: %s^7\n  %s'):format(invoker or '?', tostring(res), text))
        if op == 'transaction' then return true, false end
        return false, res
    end
    return true, res
end

-- exports['opslabs-connect']:db(op, sql, params, cb)  — cb(result, err); called by lib/db.lua in other resources
exports('db', function(op, sql, params, cb)
    local invoker = GetInvokingResource()
    CreateThread(function()
        local ok, res = run(op, sql, params, invoker)
        if ok then cb(res, nil) else cb(nil, res) end
    end)
end)

exports('isHosted', function() return state.token ~= '' end)
exports('awaitReady', function(ms) return waitReady(ms or 60000) end)

---------------------------------------------------------------------------------------------------- player names → hosted `users`
local function localUsers(offset, limit)
    if framework() == 'esx' or framework() == 'standalone' then
        return MySQL.query.await('SELECT identifier, firstname, lastname, job, job_grade FROM users ORDER BY identifier LIMIT ? OFFSET ?', { limit, offset }) or {}
    end
    local rows = MySQL.query.await('SELECT citizenid, charinfo, job FROM players ORDER BY citizenid LIMIT ? OFFSET ?', { limit, offset }) or {}
    local out = {}
    for i, r in ipairs(rows) do
        local ci = json.decode(r.charinfo or '{}') or {}
        local jb = json.decode(r.job or '{}') or {}
        out[i] = { identifier = r.citizenid, firstname = ci.firstname, lastname = ci.lastname, job = jb.name, job_grade = jb.grade and jb.grade.level }
    end
    return out
end

local function pushUsers(rows)
    if #rows == 0 then return end
    local vals, args = {}, {}
    local now = os.time()
    for _, r in ipairs(rows) do
        vals[#vals + 1] = '(?, ?, ?, ?, ?, ?)'
        for _, v in ipairs({ r.identifier, r.firstname or json.null, r.lastname or json.null, r.job or json.null, tonumber(r.job_grade) or json.null, now }) do args[#args + 1] = v end
    end
    relay({ op = 'update', params = args, sql = 'INSERT INTO users (identifier, firstname, lastname, job, job_grade, synced_at) VALUES ' .. table.concat(vals, ', ') ..
        ' ON DUPLICATE KEY UPDATE firstname = VALUES(firstname), lastname = VALUES(lastname), job = VALUES(job), job_grade = VALUES(job_grade), synced_at = VALUES(synced_at)' })
end

local function syncAllUsers()
    local offset, total = 0, 0
    while true do
        local ok, rows = pcall(localUsers, offset, 200)
        if not ok or not rows or #rows == 0 then break end
        pushUsers(rows)
        total = total + #rows
        offset = offset + 200
        Wait(200)
    end
    return total
end

CreateThread(function()
    if state.token == '' then return end
    MySQL.ready.await()
    while true do
        if waitReady(120000) then
            local n = syncAllUsers()
            if n > 0 then log('player names synced (%d)', n) end
        end
        Wait(15 * 60000)
    end
end)

AddEventHandler('esx:playerLoaded', function(_, xPlayer)
    if state.token == '' or not state.dbReady or not xPlayer then return end
    local id = xPlayer.identifier or (xPlayer.getIdentifier and xPlayer.getIdentifier())
    if not id then return end
    CreateThread(function()
        local r = MySQL.single.await('SELECT identifier, firstname, lastname, job, job_grade FROM users WHERE identifier = ?', { id })
        if r then pushUsers({ r }) end
    end)
end)

---------------------------------------------------------------------------------------------------- moving existing data up
-- `opsconnect upload` (server console): copies every local ops_* / opslabs_* table into the hosted database —
-- for a server that already ran OPS on its own database before connecting. Tables that already have rows in the
-- hosted database are skipped unless `opsconnect upload force` (then rows with the same key are left as they are).
local function uploadTable(name, force)
    local cols = MySQL.query.await([[SELECT COLUMN_NAME AS c, DATA_TYPE AS t FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION]], { name }) or {}
    if #cols == 0 then return 0, 'no columns' end
    local create = MySQL.single.await(('SHOW CREATE TABLE `%s`'):format(name))
    local ddl = create and (create['Create Table'] or create['Create View'])
    if not ddl or not ddl:find('^CREATE TABLE') then return 0, 'not a table' end
    local ok, err = relay({ op = 'query', sql = (ddl:gsub('^CREATE TABLE', 'CREATE TABLE IF NOT EXISTS')), params = {} })
    if not ok then return 0, err end
    local okc, have = relay({ op = 'scalar', sql = ('SELECT COUNT(*) FROM `%s`'):format(name), params = {} })
    if okc and (tonumber(have) or 0) > 0 and not force then return 0, 'already has data (use force)' end
    -- dates as text and binary as hex, so they go back in exactly as they are
    local sel, ins, names = {}, {}, {}
    for i, c in ipairs(cols) do
        local q = '`' .. c.c .. '`'
        names[i] = q
        if c.t == 'datetime' or c.t == 'timestamp' then sel[i], ins[i] = ("DATE_FORMAT(%s, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')"):format(q), '?'
        elseif c.t == 'date' or c.t == 'time' or c.t == 'year' then sel[i], ins[i] = ('CAST(%s AS CHAR)'):format(q), '?'
        elseif c.t:find('blob') or c.t:find('binary') or c.t == 'bit' then sel[i], ins[i] = ('HEX(%s)'):format(q), 'UNHEX(?)'
        else sel[i], ins[i] = q, '?' end
        sel[i] = sel[i] .. ' AS c' .. i
    end
    local row1 = '(' .. table.concat(ins, ', ') .. ')'
    local offset, total = 0, 0
    while true do
        local rows = MySQL.query.await(('SELECT %s FROM `%s` LIMIT 200 OFFSET %d'):format(table.concat(sel, ', '), name, offset)) or {}
        if #rows == 0 then break end
        local vals, args, size = {}, {}, 0
        local function flush()
            if #vals == 0 then return true end
            local okI, errI = relay({ op = 'update', sql = ('INSERT IGNORE INTO `%s` (%s) VALUES %s'):format(name, table.concat(names, ', '), table.concat(vals, ', ')), params = args })
            vals, args, size = {}, {}, 0
            return okI, errI
        end
        for _, row in ipairs(rows) do
            vals[#vals + 1] = row1
            for i = 1, #cols do
                local v = row['c' .. i]
                if type(v) == 'boolean' then v = v and 1 or 0 end
                if v == nil then v = json.null end
                if type(v) == 'string' then size = size + #v + 8 else size = size + 12 end
                args[#args + 1] = v
            end
            if size > 1500000 then                       -- the Hub API takes 4 MB per request; JSON escaping can double text
                local okI, errI = flush()
                if not okI then return total, errI end
            end
        end
        local okI, errI = flush()
        if not okI then return total, errI end
        total = total + #rows
        offset = offset + 200
    end
    return total
end

local function upload(force)
    if not waitReady(5000) then return log('^1not connected / database not ready^7') end
    local tables = MySQL.query.await([[SELECT TABLE_NAME AS n FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
        AND (TABLE_NAME LIKE 'ops\_%' OR TABLE_NAME LIKE 'opslabs\_%') ORDER BY TABLE_NAME]]) or {}
    log('uploading %d OPS tables to the hosted database…', #tables)
    local rows = 0
    for _, t in ipairs(tables) do
        local n, err = uploadTable(t.n, force)
        rows = rows + n
        if err then log('  %s: ^3%s^7', t.n, tostring(err)) elseif n > 0 then log('  %s: %d rows', t.n, n) end
    end
    log('upload finished — %d rows. Restart opslabs-towers and opslabs-phone (or the server) to load them.', rows)
end

---------------------------------------------------------------------------------------------------- Dev App pairing
local function pollPairing(p)
    while state.pairing == p and os.time() < p.expires do
        Wait(3000)
        local status, data = httpAwait('POST', '/api/v1/pair/poll', { code = p.code, poll = p.poll })
        if status == 200 and data.status == 'paired' and data.token then
            SetResourceKvp('token', data.token)
            state.pairing = nil
            loadToken()
            if state.source ~= 'devapp' then
                log('^3paired, but ops_server_token in server.cfg takes priority — remove it to use the paired token^7')
                return
            end
            log('paired with the OPS Hub — restart the server to move OPS data to the hosted database')
            state.connected = false
            apiKey()
            connect()
            return
        elseif status == 200 and (data.status == 'expired' or data.status == 'unknown' or data.status == 'used') then
            break
        end
    end
    if state.pairing == p then state.pairing = nil end
end

exports('startPairing', function()
    local status, data = httpAwait('POST', '/api/v1/pair/start', { server_name = GetConvar('sv_projectName', GetConvar('sv_hostname', '')) })
    if status ~= 200 or not data.ok then return { error = (data and data.error) or ('Could not reach the OPS Hub (HTTP ' .. tostring(status) .. ')') } end
    local p = { code = data.code, poll = data.poll, expires = os.time() + 900, url = data.url }
    state.pairing = p
    CreateThread(function() pollPairing(p) end)
    return { code = p.code, url = p.url, expires = p.expires }
end)

exports('forget', function()
    if state.source ~= 'devapp' then return { error = 'This server uses ops_server_token from server.cfg — remove it there.' } end
    DeleteResourceKvp('token')
    loadToken()
    state.connected, state.dbReady, state.server = false, false, nil
    log('paired token removed — restart the server to go back to the local database')
    return { ok = true }
end)

exports('status', function()
    return {
        hosted = state.token ~= '', source = state.source, connected = state.connected, dbReady = state.dbReady,
        server = state.server, hub = state.hub, api = API, lastError = state.lastError, lastSeen = state.lastSeen,
        tokenPrefix = state.token ~= '' and state.token:sub(1, 12) or nil, version = VERSION,
        pairing = state.pairing and { code = state.pairing.code, url = state.pairing.url, expires = state.pairing.expires } or nil,
        publicUrl = publicUrl(), restartNeeded = state.source == 'devapp' and not _G.__opsHostedAtStart,
    }
end)
_G.__opsHostedAtStart = state.token ~= ''

RegisterCommand('opsconnect', function(src, args)
    if src ~= 0 then return end
    local sub = args[1] or 'status'
    if sub == 'pair' then
        local r = exports[RES]:startPairing()
        if r.error then log('^1%s^7', r.error) else log('pairing code ^2%s^7 — enter it on %s/new-hub/pair (15 minutes)', r.code, API) end
    elseif sub == 'forget' then
        local r = exports[RES]:forget()
        log(r.error or 'done')
    elseif sub == 'upload' then
        CreateThread(function() upload(args[2] == 'force') end)
    else
        log('token: %s (%s) · connected: %s · database ready: %s · server: %s · hub: %s%s', state.token ~= '' and (state.token:sub(1, 12) .. '…') or 'none', state.source,
            tostring(state.connected), tostring(state.dbReady), state.server and state.server.name or '-', state.hub or '-', state.lastError and (' · last error: ' .. state.lastError) or '')
    end
end, true)
