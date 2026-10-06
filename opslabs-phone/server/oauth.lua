-- Spotify / TIDAL account linking (OAuth 2.0 authorization code flow).
-- The player taps "Connect" in a music app -> their own browser opens the
-- provider's login page -> the provider redirects back to
--   <PublicUrl>/opslabs-phone/oauth/<provider>/callback
-- where the code is exchanged for tokens. Tokens stay on the server; the
-- phone only talks to a small whitelist of API endpoints through it.

local RES = GetCurrentResourceName()
local cfg = ServerConfig.OAuth or { PublicUrl = '', Spotify = {}, Tidal = {} }
local pending = {}          -- state -> { identifier, src, provider, verifier, expires }
local apiRate = {}          -- src -> { start, count }
local tidalCountries = {}   -- identifier -> TIDAL account country

local PROVIDERS = {
    spotify = {
        name = 'Spotify', conf = cfg.Spotify or {},
        authorize = 'https://accounts.spotify.com/authorize',
        token = 'https://accounts.spotify.com/api/token',
        api = 'https://api.spotify.com',
    },
    tidal = {
        name = 'TIDAL', conf = cfg.Tidal or {}, pkce = true,
        authorize = 'https://login.tidal.com/authorize',
        token = 'https://auth.tidal.com/v1/oauth2/token',
        api = 'https://openapi.tidal.com',
    },
}

--- PublicUrl from config, otherwise the server's cfx.re Nucleus address (web_baseUrl)
local function publicUrl()
    local url = cfg.PublicUrl or ''
    if url == '' then
        local base = GetConvar('web_baseUrl', '')
        if base ~= '' then url = base:find('^https?://') and base or 'https://' .. base end
    end
    return (url:gsub('/+$', ''))
end

PhonePublicUrl = publicUrl -- also used for camera media URLs

local function configured(p)
    return publicUrl() ~= '' and (p.conf.ClientId or '') ~= '' and (p.pkce or (p.conf.ClientSecret or '') ~= '')
end

local function redirectUri(id)
    return publicUrl() .. '/' .. RES .. '/oauth/' .. id .. '/callback'
end

local function urlencode(s)
    return (tostring(s):gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

local function form(t)
    local out = {}
    for k, v in pairs(t) do out[#out + 1] = urlencode(k) .. '=' .. urlencode(v) end
    return table.concat(out, '&')
end

--- synchronous HTTP (inside a thread)
local function http(method, url, body, headers)
    local p = promise.new()
    PerformHttpRequest(url, function(status, text, respHeaders)
        p:resolve({ status = status, text = text, headers = respHeaders })
    end, method, body or '', headers or {})
    local r = Citizen.Await(p)
    local ok, data = pcall(json.decode, r.text or '')
    return r.status, ok and data or nil, r.text
end

local function saveTokens(identifier, provider, tok, profile)
    MySQL.query.await([[INSERT INTO opslabs_phone_oauth (identifier, provider, access_token, refresh_token, expires_at, account_id, account_name, product)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE access_token = VALUES(access_token), refresh_token = COALESCE(VALUES(refresh_token), refresh_token),
            expires_at = VALUES(expires_at), account_id = COALESCE(VALUES(account_id), account_id),
            account_name = COALESCE(VALUES(account_name), account_name), product = COALESCE(VALUES(product), product)]],
        { identifier, provider, tok.access_token, tok.refresh_token, os.time() + (tonumber(tok.expires_in) or 3600),
          profile and profile.id, profile and profile.name, profile and profile.product })
end

local function tokenRequest(p, params)
    local headers = { ['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8' }
    -- TIDAL's auth SDK sends the scopes again on both the code exchange and the refresh
    if p.pkce then params.scope = p.conf.Scopes or '' end
    if (p.conf.ClientSecret or '') ~= '' and not p.pkce then
        headers['Authorization'] = 'Basic ' .. exports[RES]:Base64(p.conf.ClientId .. ':' .. p.conf.ClientSecret)
    else
        params.client_id = p.conf.ClientId
        if (p.conf.ClientSecret or '') ~= '' then params.client_secret = p.conf.ClientSecret end
    end
    return http('POST', p.token, form(params), headers)
end

--- valid access token for a player (refreshes when it's about to expire)
local function accessToken(identifier, provider)
    local row = MySQL.single.await('SELECT * FROM opslabs_phone_oauth WHERE identifier = ? AND provider = ?', { identifier, provider })
    if not row then return nil end
    if (row.expires_at or 0) - 60 > os.time() then return row.access_token end
    if not row.refresh_token then return nil end
    local status, tok = tokenRequest(PROVIDERS[provider], { grant_type = 'refresh_token', refresh_token = row.refresh_token })
    if status ~= 200 or not tok or not tok.access_token then
        print(('^3[opslabs-phone] %s token refresh failed (%s) for %s^7'):format(provider, status, identifier))
        return nil
    end
    saveTokens(identifier, provider, tok)
    return tok.access_token
end

local function fetchProfile(provider, access)
    local p = PROVIDERS[provider]
    if provider == 'spotify' then
        local status, me = http('GET', p.api .. '/v1/me', nil, { Authorization = 'Bearer ' .. access })
        if status == 200 and me then return { id = me.id, name = me.display_name or me.id, product = me.product } end
    else
        local status, me = http('GET', p.api .. '/v2/users/me', nil, { Authorization = 'Bearer ' .. access, Accept = 'application/vnd.api+json' })
        if status == 200 and me and me.data then
            local a = me.data.attributes or {}
            -- TIDAL has no product tier here, so the account country goes in the product column
            return { id = me.data.id, name = a.username or a.firstName or a.email or 'TIDAL', product = a.country }
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- browser callback page
---------------------------------------------------------------------------

local function page(res, status, title, message, ok)
    local html = ([[<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0b10;color:#fff;font-family:-apple-system,Segoe UI,Inter,Arial,sans-serif}
.c{max-width:420px;padding:36px;text-align:center}.i{width:72px;height:72px;border-radius:50%%;margin:0 auto 18px;display:grid;place-items:center;font-size:36px;background:%s}
h1{font-size:24px;margin:0 0 10px}p{color:#b8b8c0;line-height:1.5;margin:0}</style></head>
<body><div class="c"><div class="i">%s</div><h1>%s</h1><p>%s</p></div></body></html>]]):format(
        title, ok and '#34c759' or '#ff3b30', ok and '&#10003;' or '!', title, message)
    if pcall(res.writeHead, status, { ['Content-Type'] = 'text/html; charset=utf-8', ['Cache-Control'] = 'no-store' }) then pcall(res.send, html) end
end

local function htmlEscape(s) return (tostring(s or ''):gsub('[<>&"]', { ['<'] = '&lt;', ['>'] = '&gt;', ['&'] = '&amp;', ['"'] = '&quot;' })) end

--- called by the resource's HTTP handler (server/api.lua) for /oauth/...
function OAuthHttp(req, res, path, query)
    local id = path:match('^/oauth/(%w+)/callback$')
    local p = id and PROVIDERS[id]
    if not p then return page(res, 404, 'Not found', 'This link is not valid.', false) end
    if query.error then
        return page(res, 200, 'Sign-in cancelled', ('You did not connect %s. You can close this tab and try again from the phone.'):format(p.name), false)
    end
    local st = query.state and pending[query.state]
    if not st or st.provider ~= id or st.expires < os.time() then
        return page(res, 400, 'Link expired', 'This sign-in link has expired. Tap Connect again on the phone.', false)
    end
    pending[query.state] = nil

    local params = { grant_type = 'authorization_code', code = query.code or '', redirect_uri = redirectUri(id) }
    if p.pkce then params.code_verifier = st.verifier end
    local status, tok, raw = tokenRequest(p, params)
    if status ~= 200 or not tok or not tok.access_token then
        print(('^1[opslabs-phone] %s token exchange failed (%s): %s^7'):format(id, status, tostring(raw):sub(1, 200)))
        return page(res, 502, 'Could not connect', ('%s did not accept the sign-in. Check the Client ID, Secret and Redirect URI in config_server.lua.'):format(p.name), false)
    end
    local profile = fetchProfile(id, tok.access_token)
    saveTokens(st.identifier, id, tok, profile)
    tidalCountries[st.identifier] = nil
    print(('^2[opslabs-phone]^7 %s connected %s (%s)'):format(st.identifier, p.name, profile and profile.name or '?'))

    local src = GetSourceByIdentifier(st.identifier)
    if src then
        Push(src, 'oauthConnected', { provider = id, name = profile and profile.name })
        Notify(src, { app = id == 'spotify' and 'soundwave' or 'tide', title = p.name, body = ('Connected as %s'):format(profile and profile.name or 'you'), icon = 'fa-circle-check' })
    end
    return page(res, 200, ('Connected to %s'):format(p.name),
        ('Signed in as <b>%s</b>. You can close this tab and go back to the game.'):format(htmlEscape(profile and profile.name or 'your account')), true)
end

---------------------------------------------------------------------------
-- phone callbacks
---------------------------------------------------------------------------

Register('oauthStatus', function(_, phone)
    local out = {}
    for id, p in pairs(PROVIDERS) do
        local row = MySQL.single.await('SELECT account_name, product FROM opslabs_phone_oauth WHERE identifier = ? AND provider = ?', { phone.identifier, id })
        out[id] = { configured = configured(p), connected = row ~= nil, name = row and row.account_name, product = row and row.product }
    end
    return out
end)

Register('oauthStart', function(src, phone, data)
    local id = tostring(data.provider or '')
    local p = PROVIDERS[id]
    if not p then return { error = 'Unknown service' } end
    if not configured(p) then return { error = ('%s sign-in has not been set up on this server yet.'):format(p.name) } end
    -- one pending sign-in per player and provider
    for state, s in pairs(pending) do
        if s.identifier == phone.identifier and s.provider == id or s.expires < os.time() then pending[state] = nil end
    end
    local state = exports[RES]:RandomToken(32)
    local entry = { identifier = phone.identifier, src = src, provider = id, expires = os.time() + 600 }
    local params = {
        client_id = p.conf.ClientId, response_type = 'code', redirect_uri = redirectUri(id),
        scope = p.conf.Scopes or '', state = state,
    }
    if id == 'spotify' then params.show_dialog = 'true' end
    if p.pkce then
        entry.verifier = exports[RES]:RandomToken(48)
        params.code_challenge_method = 'S256'
        params.code_challenge = exports[RES]:PkceChallenge(entry.verifier)
    end
    pending[state] = entry
    return { url = p.authorize .. '?' .. form(params) }
end)

Register('oauthDisconnect', function(_, phone, data)
    MySQL.update.await('DELETE FROM opslabs_phone_oauth WHERE identifier = ? AND provider = ?', { phone.identifier, tostring(data.provider or '') })
    tidalCountries[phone.identifier] = nil
    return true
end)

-- only these endpoints can be reached from the phone
local SPOTIFY_ALLOW = {
    GET = { '^/v1/me$', '^/v1/me/playlists$', '^/v1/playlists/%w+$', '^/v1/playlists/%w+/tracks$', '^/v1/me/tracks$', '^/v1/search$',
        '^/v1/me/player$', '^/v1/me/player/devices$', '^/v1/me/player/recently%-played$', '^/v1/me/player/currently%-playing$' },
    PUT = { '^/v1/me/player$', '^/v1/me/player/play$', '^/v1/me/player/pause$', '^/v1/me/player/shuffle$', '^/v1/me/player/repeat$',
        '^/v1/me/player/volume$', '^/v1/me/player/seek$' },
    POST = { '^/v1/me/player/next$', '^/v1/me/player/previous$' },
}
local TIDAL_ALLOW = { '^/v2/users/me$', '^/v2/searchResults$', '^/v2/searchResults/[%w%-_]+/relationships/%a+$',
    '^/v2/tracks$', '^/v2/tracks/%w+$', '^/v2/albums/%w+$', '^/v2/albums/%w+/relationships/items$',
    '^/v2/playlists$', '^/v2/playlists/[%w%-]+$', '^/v2/playlists/[%w%-]+/relationships/items$',
    '^/v2/userCollection%a+/me/relationships/items$' }

--- TIDAL catalogue results depend on the account's country
local function tidalCountry(identifier, token)
    if tidalCountries[identifier] then return tidalCountries[identifier] end
    local c = MySQL.scalar.await("SELECT product FROM opslabs_phone_oauth WHERE identifier = ? AND provider = 'tidal'", { identifier })
    if not (c and tostring(c):match('^%u%u$')) and token then
        -- accounts linked before the country was stored
        local profile = fetchProfile('tidal', token)
        c = profile and profile.product
        if c then MySQL.update.await("UPDATE opslabs_phone_oauth SET product = ? WHERE identifier = ? AND provider = 'tidal'", { c, identifier }) end
    end
    c = (c and tostring(c):match('^%u%u$')) or PROVIDERS.tidal.conf.CountryCode or 'US'
    tidalCountries[identifier] = c
    return c
end

local function allowed(list, path)
    for _, pat in ipairs(list or {}) do if path:match(pat) then return true end end
    return false
end

local function rateOk(src)
    local now = GetGameTimer()
    local r = apiRate[src]
    if not r or now - r.start > 1000 then apiRate[src] = { start = now, count = 1 } return true end
    r.count = r.count + 1
    return r.count <= 10
end
AddEventHandler('playerDropped', function() apiRate[source] = nil end)

local function queryString(q, extra)
    local t = {}
    for k, v in pairs(type(q) == 'table' and q or {}) do t[tostring(k)] = tostring(v) end
    for k, v in pairs(extra or {}) do if t[k] == nil then t[k] = v end end
    local s = form(t)
    return s ~= '' and ('?' .. s) or ''
end

local function callApi(phone, id, method, path, query, body)
    local p = PROVIDERS[id]
    for attempt = 1, 2 do
        local token = accessToken(phone.identifier, id)
        if not token then return { status = 401, error = 'not_connected' } end
        local headers = { Authorization = 'Bearer ' .. token }
        local payload = ''
        if id == 'tidal' then headers.Accept = 'application/vnd.api+json' end
        if body ~= nil then headers['Content-Type'] = 'application/json'; payload = json.encode(body) end
        local extra = id == 'tidal' and { countryCode = tidalCountry(phone.identifier, token) } or nil
        local status, data = http(method, p.api .. path .. queryString(query, extra), payload, headers)
        if status == 401 and attempt == 1 then
            MySQL.update.await('UPDATE opslabs_phone_oauth SET expires_at = 0 WHERE identifier = ? AND provider = ?', { phone.identifier, id })
        else
            return { status = status, data = data }
        end
    end
end

Register('spotifyApi', function(src, phone, data)
    local method = tostring(data.method or 'GET'):upper()
    local path = tostring(data.path or '')
    if not allowed(SPOTIFY_ALLOW[method], path) then return { status = 400, error = 'not_allowed' } end
    if not rateOk(src) then return { status = 429, error = 'slow_down' } end
    return callApi(phone, 'spotify', method, path, data.query, data.body)
end)

Register('tidalApi', function(src, phone, data)
    local path = tostring(data.path or '')
    if not allowed(TIDAL_ALLOW, path) then return { status = 400, error = 'not_allowed' } end
    if not rateOk(src) then return { status = 429, error = 'slow_down' } end
    return callApi(phone, 'tidal', 'GET', path, data.query)
end)

-- expire abandoned sign-ins
CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        for state, s in pairs(pending) do if s.expires < now then pending[state] = nil end end
    end
end)

-- print the redirect addresses to paste into the Spotify / TIDAL developer dashboards
CreateThread(function()
    for _ = 1, 30 do
        if publicUrl() ~= '' then break end
        Wait(2000) -- Nucleus can take a few seconds after boot
    end
    if publicUrl() == '' then
        print('^3[opslabs-phone] No public address yet for Spotify/TIDAL sign-in. Set ServerConfig.OAuth.PublicUrl in config_server.lua.^7')
        return
    end
    print(('^2[opslabs-phone] Music sign-in address: %s^7'):format(publicUrl()))
    print(('^2[opslabs-phone]   Spotify Redirect URI: %s^7'):format(redirectUri('spotify')))
    print(('^2[opslabs-phone]   TIDAL Redirect URI:   %s^7'):format(redirectUri('tidal')))
end)
