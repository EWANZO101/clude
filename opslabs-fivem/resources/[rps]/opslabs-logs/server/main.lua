-- OPS Logs — command, HTTP dashboard and Discord webhook. Kept in Lua (not the JS tailer in
-- server/logtail.js) specifically so every player/admin-facing entry point loads through
-- opslabs-license/guard.lua, which only wraps Lua's RegisterCommand / SetHttpHandler / events.
local RES = GetCurrentResourceName()

---------------------------------------------------------------------------
-- dashboard API key: auto-generated and persisted on first run, like opslabs-license's own signing key,
-- so the dashboard is never left open by default just because an admin forgot to set one.
---------------------------------------------------------------------------
local KEY_FILE = 'data/api_key.txt'

local function loadOrCreateKey()
    local existing = LoadResourceFile(RES, KEY_FILE)
    if existing and #existing >= 32 then return existing:gsub('%s+$', '') end
    local chars = '0123456789abcdef'
    local out = {}
    math.randomseed(os.time() + GetGameTimer())
    for i = 1, 48 do out[i] = chars:sub(math.random(1, #chars), math.random(1, #chars)) end
    local key = table.concat(out)
    SaveResourceFile(RES, KEY_FILE, key, -1)
    print(('^3[opslabs-logs] dashboard key (keep this private): %s^7'):format(key))
    print(('^3[opslabs-logs] dashboard: http://<your-server-ip>:<http-port>/%s/?key=%s^7'):format(RES, key))
    return key
end

local ApiKey = loadOrCreateKey()

local function authorized(req)
    local given = (req.path or ''):match('[?&]key=([^&]+)') or (req.headers and (req.headers['Authorization'] or req.headers['authorization']) or ''):gsub('^Bearer%s+', '')
    return given == ApiKey
end

---------------------------------------------------------------------------
-- /serverlog — quick in-game/console summary
---------------------------------------------------------------------------
local function levelColor(level)
    if level == 'error' then return '^1' end
    if level == 'warn' then return '^3' end
    return '^7'
end

local function reply(src, lines)
    if src == 0 then
        for _, l in ipairs(lines) do print(l) end
    else
        for _, l in ipairs(lines) do
            TriggerClientEvent('chat:addMessage', src, { args = { '[OPS Logs]', l } })
        end
    end
end

RegisterCommand('serverlog', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(tostring(src), Config.AdminAce) then
        reply(src, { 'You are not allowed to run this (missing ACE ' .. Config.AdminAce .. ')' })
        return
    end
    local tagFilter, levelFilter, limit = nil, nil, 15
    for _, a in ipairs(args) do
        if a == 'error' or a == 'warn' or a == 'info' then levelFilter = a
        elseif tonumber(a) then limit = math.min(tonumber(a), 50)
        else tagFilter = a end
    end
    local rows = exports[RES]:GetRecent({ tag = tagFilter, level = levelFilter, limit = limit })
    if #rows == 0 then
        reply(src, { 'Nothing matching that yet.' })
        return
    end
    local out = { ('%d most recent%s%s:'):format(#rows, tagFilter and (' from ' .. tagFilter) or '', levelFilter and (' [' .. levelFilter .. ']') or '') }
    for _, e in ipairs(rows) do
        local countTxt = e.count > 1 and (' x' .. e.count) or ''
        out[#out + 1] = ('%s[%s]^7 %s%s'):format(levelColor(e.level), e.tag or '(server)', e.lastText, countTxt)
    end
    reply(src, out)
end, false)

---------------------------------------------------------------------------
-- Discord webhook: one embed per brand-new distinct warning/error signature.
-- Polls server/logtail.js's PopPendingAlerts export rather than listening for a cross-runtime event —
-- same-resource exports are the one Lua<->JS call this codebase already relies on elsewhere (see
-- opslabs-phone/server/media.lua calling media.js), so alerts go out the same well-trodden door.
---------------------------------------------------------------------------
local function postAlert(payload)
    local color = payload.level == 'error' and 15158332 or 16098851 -- red / amber
    local body = json.encode({
        embeds = { {
            title = ('New %s from %s'):format(payload.level, payload.tag or '(server)'),
            description = ('```%s```'):format((payload.text or ''):sub(1, 1500)),
            color = color,
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor((payload.at or (os.time() * 1000)) / 1000)),
        } },
    })
    PerformHttpRequest(Config.DiscordWebhook, function() end, 'POST', body, { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    while true do
        Wait(3000)
        if Config.DiscordWebhook ~= '' then
            local ok, alerts = pcall(function() return exports[RES]:PopPendingAlerts() end)
            if ok and alerts then
                for _, payload in ipairs(alerts) do postAlert(payload) end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- HTTP: GET /                 -> dashboard page
--       GET /api/recent       -> ?tag=&level=&q=&limit=  (key required, see authorized())
--       GET /api/stats        -> per-tag counts
---------------------------------------------------------------------------
local function send(res, status, body, contentType)
    local ok, err = pcall(res.writeHead, status, { ['Content-Type'] = contentType or 'application/json', ['Cache-Control'] = 'no-store' })
    if ok then ok, err = pcall(res.send, body) end
    if not ok then print(('^3[opslabs-logs] HTTP reply dropped (%s)^7'):format(tostring(err))) end
end

local function queryParam(path, name)
    return (path or ''):match('[?&]' .. name .. '=([^&]+)')
end

SetHttpHandler(function(req, res)
    local path = (req.path or ''):gsub('%?.*$', '')

    if path == '/' or path == '' then
        if not authorized(req) then return send(res, 401, 'Missing or wrong ?key=', 'text/plain') end
        local html = LoadResourceFile(RES, 'web/dashboard.html') or '<h1>dashboard.html missing</h1>'
        return send(res, 200, html, 'text/html')
    end

    if not authorized(req) then return send(res, 401, json.encode({ error = 'Unauthorized' })) end

    if path == '/api/recent' and req.method == 'GET' then
        local full = req.path or ''
        local rows = exports[RES]:GetRecent({
            tag = queryParam(full, 'tag'),
            level = queryParam(full, 'level'),
            q = queryParam(full, 'q'),
            limit = tonumber(queryParam(full, 'limit')) or 200,
        })
        return send(res, 200, json.encode({ data = rows }))
    end

    if path == '/api/stats' and req.method == 'GET' then
        return send(res, 200, json.encode({ data = exports[RES]:GetStats() }))
    end

    send(res, 404, json.encode({ error = 'Not found' }))
end)

print(('^2[opslabs-logs] ready — /serverlog in-game, or the HTTP dashboard above^7'))
