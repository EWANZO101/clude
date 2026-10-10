-- REST API + outgoing webhooks for opslabs-phone.
-- See README.md for the full endpoint reference.

local API_BASE = '/api/v1'

---------------------------------------------------------------------------
-- outgoing webhooks
---------------------------------------------------------------------------

--- Emits a phone event to every configured webhook.
function Emit(event, payload)
    if #ApiConfig.Webhooks == 0 or not ApiConfig.Events[event] then return end
    local body = json.encode({ event = event, timestamp = os.time(), data = payload })
    local headers = { ['Content-Type'] = 'application/json', ['X-OpsLabs-Event'] = event }
    if ApiConfig.WebhookSecret ~= '' then headers['X-OpsLabs-Secret'] = ApiConfig.WebhookSecret end
    for _, url in ipairs(ApiConfig.Webhooks) do
        PerformHttpRequest(url, function(status)
            if status < 200 or status >= 300 then
                print(('^3[opslabs-phone] webhook %s -> %s returned %s^7'):format(event, url, status))
            end
        end, 'POST', body, headers)
    end
end

---------------------------------------------------------------------------
-- http plumbing
---------------------------------------------------------------------------

local rate = {}

local function allowedOrigin(origin)
    if not origin then return nil end
    for _, o in ipairs(ApiConfig.CorsOrigins) do
        if o == '*' then return '*' end
        if o == origin then return origin end
    end
end

local function send(res, status, body, origin)
    local headers = { ['Content-Type'] = 'application/json' }
    local allow = allowedOrigin(origin)
    if allow then
        headers['Access-Control-Allow-Origin'] = allow
        headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, X-Api-Key'
        headers['Access-Control-Allow-Methods'] = 'GET, POST, PATCH, DELETE, OPTIONS'
        headers['Vary'] = 'Origin'
    end
    -- the caller may have given up (OPS Hub times out): never let a write to a closed request take the server down
    local ok, err = pcall(res.writeHead, status, headers)
    if ok then ok, err = pcall(res.send, body ~= nil and json.encode(body) or '') end
    if not ok then print(('^3[opslabs-phone] API reply dropped (%s)^7'):format(tostring(err))) end
end

local function authorized(req)
    local key = ApiConfig.Key
    if #key < 24 then return false end
    local h = req.headers or {}
    local given = h['Authorization'] or h['authorization'] or ''
    given = given:gsub('^Bearer%s+', '')
    if given == '' then given = h['X-Api-Key'] or h['x-api-key'] or '' end
    if #given ~= #key then return false end
    local diff = 0
    for i = 1, #key do
        if given:byte(i) ~= key:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function rateLimited(ip)
    local now = os.time()
    local r = rate[ip]
    if not r or now - r.start >= ApiConfig.RateLimit.Window then
        rate[ip] = { start = now, count = 1 }
        return false
    end
    r.count = r.count + 1
    return r.count > ApiConfig.RateLimit.Requests
end

local function parseQuery(path)
    local route, qs = path:match('^([^?]*)%??(.*)$')
    local query = {}
    for k, v in qs:gmatch('([^&=]+)=?([^&]*)') do
        v = v:gsub('%+', ' '):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        query[k] = v
    end
    return route, query
end

local function urldecode(s)
    return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local routes = {}

local function route(method, pattern, handler)
    routes[#routes + 1] = { method = method, pattern = '^' .. API_BASE .. pattern .. '$', handler = handler }
end

local function apiError(status, message)
    error({ status = status, message = message }, 0)
end

local function requireUser(number)
    -- exact match first, then the same digits in the server's number format ("5551234" -> "555-1234")
    local user = MySQL.single.await('SELECT identifier, phone_number, email, settings, created_at, char_first, char_last, char_job, char_grade FROM opslabs_phone_users WHERE phone_number IN (?, ?) LIMIT 1',
        { number, NormalizeNumber(number) })
    if not user then apiError(404, 'Phone number not found') end
    return user
end

local function paging(q, default)
    local limit = math.min(math.max(tonumber(q.limit) or default or 50, 1), 200)
    local offset = math.max(tonumber(q.offset) or 0, 0)
    return limit, offset
end

-- shared with server/carrier.lua (loaded after this file)
ApiRoute, ApiError, ApiRequireUser, ApiPaging = route, apiError, requireUser, paging

local function onlineSource(identifier)
    for src, phone in pairs(Phones) do
        if phone.identifier == identifier then return src end
    end
end

---------------------------------------------------------------------------
-- routes
---------------------------------------------------------------------------

route('GET', '/health', function()
    return { ok = true, resource = GetCurrentResourceName(), version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) }
end)

route('GET', '/stats', function()
    local online = 0
    for _ in pairs(Phones) do online = online + 1 end
    return {
        online = online,
        users = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_users'),
        messages = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_messages'),
        calls = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_calls'),
        chirp_posts = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_chirp_posts'),
        mail = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_mail'),
    }
end)

route('GET', '/online', function()
    local list = {}
    for src, phone in pairs(Phones) do
        list[#list + 1] = { source = src, number = phone.number, name = phone.name, email = phone.email }
    end
    return list
end)

-- users ------------------------------------------------------------------

route('GET', '/users', function(_, q)
    local limit, offset = paging(q)
    local search = q.search and ('%' .. q.search .. '%') or '%'
    return MySQL.query.await([[
        SELECT p.phone_number AS number, p.email, p.created_at, p.char_first AS firstname, p.char_last AS lastname, p.char_job AS job
        FROM opslabs_phone_users p
        WHERE p.phone_number LIKE ? OR p.email LIKE ? OR CONCAT(COALESCE(p.char_first, ''), ' ', COALESCE(p.char_last, '')) LIKE ?
        ORDER BY p.created_at DESC LIMIT ? OFFSET ?]], { search, search, search, limit, offset })
end)

route('GET', '/users/([^/]+)', function(p)
    local user = requireUser(p[1])
    -- null when the phone has never seen the character (as before, when there was no framework row)
    local char = (user.char_first or user.char_job) and { firstname = user.char_first, lastname = user.char_last, job = user.char_job, job_grade = user.char_grade } or nil
    return {
        number = user.phone_number,
        email = user.email,
        created_at = user.created_at,
        settings = json.decode(user.settings or '{}'),
        character = char,
        online = onlineSource(user.identifier) ~= nil,
    }
end)

-- Update a phone: { number?, email?, settings? (merged) }
--- Changes a phone's number / email / settings and migrates its history.
--- Shared by the REST API and the in-game Developer app.
--- Returns result table, or nil + http status + message.
function ApplyPhoneUpdate(user, body, opts)
    local oldNumber = user.phone_number
    local newNumber = body.number and NormalizeNumber(body.number) or oldNumber
    local email = body.email and Clean(body.email, 100):lower() or user.email

    if newNumber ~= oldNumber then
        if newNumber == '' then return nil, 400, 'Invalid number' end
        if MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE phone_number = ?', { newNumber }) then return nil, 409, 'Number already in use' end
    end
    if email ~= user.email and MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE email = ?', { email }) then
        return nil, 409, 'Email already in use'
    end

    local settings = json.decode(user.settings or '{}') or {}
    if type(body.settings) == 'table' then
        for k, v in pairs(body.settings) do settings[k] = v end
    end

    local queries = {
        { query = 'UPDATE opslabs_phone_users SET phone_number = ?, email = ?, settings = ? WHERE identifier = ?', values = { newNumber, email, json.encode(settings), user.identifier } },
    }
    if newNumber ~= oldNumber then
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_contacts SET owner = ? WHERE owner = ?', values = { newNumber, oldNumber } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_contacts SET number = ? WHERE number = ?', values = { newNumber, oldNumber } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_messages SET sender = ? WHERE sender = ?', values = { newNumber, oldNumber } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_messages SET receiver = ? WHERE receiver = ?', values = { newNumber, oldNumber } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_calls SET caller = ? WHERE caller = ?', values = { newNumber, oldNumber } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_calls SET callee = ? WHERE callee = ?', values = { newNumber, oldNumber } }
    end
    if email ~= user.email then
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_mail SET receiver = ? WHERE receiver = ?', values = { email, user.email } }
        queries[#queries + 1] = { query = 'UPDATE opslabs_phone_mail SET sender = ? WHERE sender = ?', values = { email, user.email } }
    end
    if not MySQL.transaction.await(queries) then return nil, 500, 'Update failed' end

    -- online player: reload their phone
    local src = onlineSource(user.identifier)
    if src then
        ReloadPhone(src)
        if not (opts and opts.silent) then Push(src, 'reload') end
    end
    return { ok = true, number = newNumber, email = email }
end

route('PATCH', '/users/([^/]+)', function(p, _, body)
    local result, status, message = ApplyPhoneUpdate(requireUser(p[1]), body)
    if not result then apiError(status, message) end
    return result
end)

-- contacts ---------------------------------------------------------------

route('GET', '/users/([^/]+)/contacts', function(p)
    local user = requireUser(p[1])
    return MySQL.query.await('SELECT id, name, number, email, avatar, favorite, blocked FROM opslabs_phone_contacts WHERE owner = ? ORDER BY name', { user.phone_number })
end)

route('POST', '/users/([^/]+)/contacts', function(p, _, body)
    local user = requireUser(p[1])
    local name, number = Clean(body.name, 60), NormalizeNumber(body.number)
    if name == '' or number == '' then apiError(400, 'name and number are required') end
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_contacts (owner, name, number, email) VALUES (?, ?, ?, ?)',
        { user.phone_number, name, number, body.email and Clean(body.email, 100) or nil })
    return { id = id }
end)

route('DELETE', '/users/([^/]+)/contacts/(%d+)', function(p)
    local user = requireUser(p[1])
    local n = MySQL.update.await('DELETE FROM opslabs_phone_contacts WHERE id = ? AND owner = ?', { tonumber(p[2]), user.phone_number })
    if n == 0 then apiError(404, 'Contact not found') end
    return { ok = true }
end)

-- messages ---------------------------------------------------------------

-- ?with=<number> returns that thread, otherwise the latest messages
route('GET', '/users/([^/]+)/messages', function(p, q)
    local user = requireUser(p[1])
    local limit, offset = paging(q, 100)
    if q.with then
        local other = NormalizeNumber(q.with)
        return MySQL.query.await([[SELECT id, sender, receiver, message, attachment, is_read, created_at FROM opslabs_phone_messages
            WHERE (sender = ? AND receiver = ?) OR (sender = ? AND receiver = ?) ORDER BY id DESC LIMIT ? OFFSET ?]],
            { user.phone_number, other, other, user.phone_number, limit, offset })
    end
    return MySQL.query.await([[SELECT id, sender, receiver, message, attachment, is_read, created_at FROM opslabs_phone_messages
        WHERE sender = ? OR receiver = ? ORDER BY id DESC LIMIT ? OFFSET ?]], { user.phone_number, user.phone_number, limit, offset })
end)

-- { from, to, message } — "from" can be any number, e.g. a business line
route('POST', '/messages', function(_, _, body)
    local from, to = NormalizeNumber(body.from), NormalizeNumber(body.to)
    if from == '' or to == '' then apiError(400, 'from and to are required') end
    local id = SendMessage(from, to, body.message, nil, body.from_name)
    if not id then apiError(400, 'Message is empty') end
    return { id = id }
end)

route('DELETE', '/messages/(%d+)', function(p)
    local n = MySQL.update.await('DELETE FROM opslabs_phone_messages WHERE id = ?', { tonumber(p[1]) })
    if n == 0 then apiError(404, 'Message not found') end
    return { ok = true }
end)

-- calls / notes / photos ------------------------------------------------

route('GET', '/users/([^/]+)/calls', function(p, q)
    local user = requireUser(p[1])
    local limit, offset = paging(q)
    return MySQL.query.await('SELECT * FROM opslabs_phone_calls WHERE caller = ? OR callee = ? ORDER BY id DESC LIMIT ? OFFSET ?',
        { user.phone_number, user.phone_number, limit, offset })
end)

route('GET', '/users/([^/]+)/notes', function(p)
    local user = requireUser(p[1])
    return MySQL.query.await('SELECT id, title, body, updated_at FROM opslabs_phone_notes WHERE owner = ? ORDER BY updated_at DESC', { user.identifier })
end)

route('GET', '/users/([^/]+)/photos', function(p, q)
    local user = requireUser(p[1])
    local limit, offset = paging(q)
    return MySQL.query.await('SELECT id, url, favorite, created_at FROM opslabs_phone_photos WHERE owner = ? ORDER BY id DESC LIMIT ? OFFSET ?', { user.identifier, limit, offset })
end)

route('POST', '/users/([^/]+)/photos', function(p, _, body)
    local user = requireUser(p[1])
    local url = CleanUrl(body.url)
    if not url then apiError(400, 'A valid http(s) url is required') end
    return { id = MySQL.insert.await('INSERT INTO opslabs_phone_photos (owner, url) VALUES (?, ?)', { user.identifier, url }) }
end)

-- mail -------------------------------------------------------------------

route('GET', '/users/([^/]+)/mail', function(p, q)
    local user = requireUser(p[1])
    local limit, offset = paging(q)
    return MySQL.query.await('SELECT * FROM opslabs_phone_mail WHERE receiver = ? OR sender = ? ORDER BY id DESC LIMIT ? OFFSET ?',
        { user.email, user.email, limit, offset })
end)

-- { to: email | phone number, from_name, from_email?, subject, body }
route('POST', '/mail', function(_, _, body)
    local to = Clean(body.to, 100)
    if not to:find('@') then
        to = MySQL.scalar.await('SELECT email FROM opslabs_phone_users WHERE phone_number = ?', { NormalizeNumber(to) })
        if not to then apiError(404, 'Recipient not found') end
    end
    local id = SendMail(to, body.from_name or 'Los Santos', body.subject, body.body, body.from_email)
    return { id = id }
end)

-- notifications ----------------------------------------------------------

-- { number | "all", title, body, app?, icon? }
route('POST', '/notify', function(_, _, body)
    local notif = { app = Clean(body.app or 'system', 30), title = Clean(body.title, 80), body = Clean(body.body, 300), icon = body.icon }
    local sent = 0
    for src, phone in pairs(Phones) do
        if body.number == 'all' or phone.number == NormalizeNumber(body.number) then
            Notify(src, notif)
            sent = sent + 1
        end
    end
    return { delivered = sent }
end)

-- chirp ------------------------------------------------------------------

route('GET', '/chirp/posts', function(_, q)
    local limit, offset = paging(q)
    return MySQL.query.await([[SELECT p.id, p.content, p.image, p.reply_to, p.created_at, pr.handle, pr.display_name,
        (SELECT COUNT(*) FROM opslabs_phone_chirp_likes l WHERE l.post_id = p.id) AS likes
        FROM opslabs_phone_chirp_posts p JOIN opslabs_phone_chirp_profiles pr ON pr.identifier = p.author
        ORDER BY p.id DESC LIMIT ? OFFSET ?]], { limit, offset })
end)

-- Post as an existing handle: { handle, content, image? }
route('POST', '/chirp/posts', function(_, _, body)
    local identifier = MySQL.scalar.await('SELECT identifier FROM opslabs_phone_chirp_profiles WHERE handle = ?', { Clean(body.handle, 30) })
    if not identifier then apiError(404, 'Handle not found') end
    local content = Clean(body.content, 280)
    if content == '' then apiError(400, 'content is required') end
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_chirp_posts (author, content, image) VALUES (?, ?, ?)', { identifier, content, CleanUrl(body.image) })
    for src in pairs(Phones) do Push(src, 'chirpRefresh') end
    return { id = id }
end)

route('DELETE', '/chirp/posts/(%d+)', function(p)
    local id = tonumber(p[1])
    local n = MySQL.update.await('DELETE FROM opslabs_phone_chirp_posts WHERE id = ? OR reply_to = ?', { id, id })
    if n == 0 then apiError(404, 'Post not found') end
    MySQL.update('DELETE FROM opslabs_phone_chirp_likes WHERE post_id = ?', { id })
    return { ok = true }
end)

-- services ---------------------------------------------------------------

route('GET', '/services/requests', function(_, q)
    local limit, offset = paging(q)
    if q.service then
        return MySQL.query.await('SELECT * FROM opslabs_phone_service_requests WHERE service = ? ORDER BY id DESC LIMIT ? OFFSET ?', { q.service, limit, offset })
    end
    return MySQL.query.await('SELECT * FROM opslabs_phone_service_requests ORDER BY id DESC LIMIT ? OFFSET ?', { limit, offset })
end)

route('PATCH', '/services/requests/(%d+)', function(p, _, body)
    local status = body.status
    if status ~= 'open' and status ~= 'accepted' and status ~= 'closed' then apiError(400, 'status must be open, accepted or closed') end
    local n = MySQL.update.await('UPDATE opslabs_phone_service_requests SET status = ? WHERE id = ?', { status, tonumber(p[1]) })
    if n == 0 then apiError(404, 'Request not found') end
    return { ok = true }
end)

---------------------------------------------------------------------------
-- dispatcher
---------------------------------------------------------------------------

local function dispatch(req, res, rawBody)
    local h = req.headers or {}
    local origin = h['Origin'] or h['origin']

    local path, query = parseQuery(req.path)
    if req.method == 'OPTIONS' and not path:find('^/media/') then return send(res, 204, nil, origin) end
    if path:find('^/oauth/') and OAuthHttp then return OAuthHttp(req, res, path, query) end
    if path:find('^/media/') and MediaHttp then return MediaHttp(req, res, path, query, rawBody) end
    if not path:find('^' .. API_BASE) then return send(res, 404, { error = 'Not found' }, origin) end
    if #ApiConfig.Key < 24 then return send(res, 503, { error = 'API disabled: set opslabs_phone_api_key (24+ chars) in server.cfg' }, origin) end
    -- the rate limit stops key guessing; requests with the key (your website) aren't limited
    if not authorized(req) then
        if rateLimited(req.address or 'unknown') then return send(res, 429, { error = 'Too many requests' }, origin) end
        return send(res, 401, { error = 'Unauthorized' }, origin)
    end

    local body = {}
    if rawBody and rawBody ~= '' then
        local ok, decoded = pcall(json.decode, rawBody)
        if not ok or type(decoded) ~= 'table' then return send(res, 400, { error = 'Invalid JSON body' }, origin) end
        body = decoded
    end

    local methodMatched = false
    for _, r in ipairs(routes) do
        local captures = { path:match(r.pattern) }
        if captures[1] ~= nil then
            if r.method == req.method then
                for i, c in ipairs(captures) do captures[i] = urldecode(c) end
                local ok, result = pcall(r.handler, captures, query, body)
                if ok then return send(res, 200, { data = result }, origin) end
                if type(result) == 'table' and result.status then
                    return send(res, result.status, { error = result.message }, origin)
                end
                print(('^1[opslabs-phone] API error %s %s: %s^7'):format(req.method, path, tostring(result)))
                return send(res, 500, { error = 'Internal error' }, origin)
            end
            methodMatched = true
        end
    end
    send(res, methodMatched and 405 or 404, { error = methodMatched and 'Method not allowed' or 'Not found' }, origin)
end

local function safeDispatch(req, res, data)
    local ok, err = pcall(dispatch, req, res, data)
    if not ok then
        print(('^1[opslabs-phone] API request %s %s failed: %s^7'):format(tostring(req.method), tostring(req.path), tostring(err)))
        pcall(send, res, 500, { error = 'Internal error' }, nil)
    end
end

SetHttpHandler(function(req, res)
    if req.method == 'GET' or req.method == 'OPTIONS' or req.method == 'DELETE' then
        CreateThread(function() safeDispatch(req, res, nil) end)
        return
    end
    req.setDataHandler(function(data)
        CreateThread(function() safeDispatch(req, res, data) end)
    end)
end)

CreateThread(function()
    if #ApiConfig.Key < 24 then
        print('^3[opslabs-phone] REST API disabled — add  set opslabs_phone_api_key "<24+ char secret>"  to server.cfg^7')
    else
        print(('^2[opslabs-phone]^7 REST API ready at /%s%s'):format(GetCurrentResourceName(), API_BASE))
    end
end)
