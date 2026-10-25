-- The real SnailyCAD API (not the limited /integrations/fivem namespace snailycad-framework uses) - verified
-- against this CAD's own OpenAPI doc (<cad url>/api-docs) and its source schemas. Two kinds of request:
--   Cad.Global(...)  - the server-wide CAD API token (same one snailycad-framework / snailycad-radio already
--                       use). Confirmed that token acts as a user with every permission, so it's used here
--                       ONLY for read-only reference data (penal codes) an ordinary officer's own token often
--                       can't read.
--   Cad.AsOfficer(...) - an officer's personal "User API Token" (CAD: Account Settings > API Tokens), sent as
--                       snaily-cad-user-api-token. The CAD accepts that header anywhere a login session would
--                       work, and the action is attributed to, and limited by the permissions of, that real
--                       CAD user - this is what every search, BOLO, citation and warrant uses.

Cad = {}

local function trimUrl(url)
    url = (url or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('/+$', '')
    if url ~= '' and not url:match('/v1$') then url = url .. '/v1' end
    return url
end

--- url, globalToken - from server.cfg, same convars snailycad-framework / snailycad-radio read
function Cad.Settings()
    local url = trimUrl(GetConvar('snailycad_framework_api_url', ''))
    local token = GetConvar('snailycad_framework_api_token', '')
    if url ~= '' and token ~= '' then return url, token end
    url = trimUrl(GetConvar('snailycad_radio_api_url', ''))
    token = GetConvar('snailycad_radio_api_token', '')
    if url ~= '' then return url, token end
    return '', ''
end

function Cad.Configured() local url = Cad.Settings() return url ~= '' end

local function request(method, path, token, header, body)
    local url = Cad.Settings()
    if url == '' then Dbg('cad request: not configured (no URL from server.cfg convars)') return nil, -1, 'not_configured' end
    Dbg('cad request: %s %s%s (header=%s)', method, url, path, header)
    local p = promise.new()
    PerformHttpRequest(url .. path, function(status, text)
        Dbg('cad response: %s %s -> %s', method, path, status)
        local ok, data = pcall(json.decode, text or '')
        p:resolve({ status = status, data = (ok and data) or nil, raw = text })
    end, method, body and json.encode(body) or '', {
        ['Content-Type'] = 'application/json',
        [header] = token,
    })
    SetTimeout((Config.Cad or {}).RequestTimeoutMs or 10000, function() p:resolve({ status = 0, data = nil, raw = 'timeout' }) end)
    local r = Citizen.Await(p)
    return r.data, r.status, r.raw
end

--- read-only reference data, the server-wide token
function Cad.Global(method, path, body)
    local _, token = Cad.Settings()
    if token == '' then return nil, -1, 'no_global_token' end
    return request(method, path, token, 'snaily-cad-api-token', body)
end

--- everything an officer does, their own personal CAD token
function Cad.AsOfficer(cadToken, method, path, body)
    if not cadToken or cadToken == '' then return nil, -1, 'not_linked' end
    return request(method, path, cadToken, 'snaily-cad-user-api-token', body)
end

--- a human reason for the console / NUI
function Cad.DescribeError(status, data)
    if status == 401 or status == 403 then return 'That CAD account token was rejected - re-link it (it may have been regenerated or revoked).' end
    if status == 404 then return 'Not found in the CAD.' end
    if status == 429 then return 'The CAD is rate-limiting this server right now - try again shortly.' end
    if status == 400 then return (data and data.message) or 'The CAD refused that request.' end
    if status == -1 then return 'SnailyCAD is not configured on this server (set snailycad_framework_api_url / _api_token).' end
    if status == 0 or not status then return 'Could not reach the CAD.' end
    return ('CAD error %s'):format(tostring(status))
end
