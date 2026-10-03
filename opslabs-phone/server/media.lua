-- Camera uploads. The phone UI renders the game view itself (no screenshot
-- resource needed) and uploads the photo/video straight to this server:
--   1. RPC cameraUploadToken -> one-time token (60s)
--   2. POST <PublicUrl>/opslabs-phone/media/upload?t=<token>&type=jpg|webm  (base64 body)
--   3. the file is stored in <resource>/media and added to the player's Photos

local RES = GetCurrentResourceName()
local tokens = {}   -- token -> { identifier, expires }

local function mediaBase()
    local base = PhonePublicUrl and PhonePublicUrl() or ''
    if base == '' then return nil end
    return base .. '/' .. RES .. '/media/'
end

--- file name of one of our own uploads, from its URL
function MediaFileFromUrl(url)
    local base = mediaBase()
    if not base or type(url) ~= 'string' or url:sub(1, #base) ~= base then return nil end
    return url:sub(#base + 1):match('^([%w_%-]+%.%a+)$')
end

function CameraStorageReady()
    return mediaBase() ~= nil
end

Register('cameraUploadToken', function(_, phone)
    if not mediaBase() then return { error = 'no_public_url' } end
    local now = os.time()
    for t, v in pairs(tokens) do if v.expires < now then tokens[t] = nil end end
    local t = exports[RES]:RandomToken(24)
    tokens[t] = { identifier = phone.identifier, expires = now + 60 }
    return { url = mediaBase() .. 'upload?t=' .. t }
end)

local function reply(res, status, body)
    res.writeHead(status, {
        ['Content-Type'] = 'application/json',
        ['Access-Control-Allow-Origin'] = '*',
        ['Access-Control-Allow-Headers'] = 'Content-Type',
        ['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS',
        ['Cache-Control'] = 'no-store',
    })
    res.send(json.encode(body))
end

local TYPES = { jpg = 'image/jpeg', webm = 'video/webm' }

--- /media/... requests (routed here from the HTTP dispatcher in api.lua)
function MediaHttp(req, res, path, query, body)
    if req.method == 'OPTIONS' then return reply(res, 204, {}) end

    if path == '/media/upload' and req.method == 'POST' then
        local t = tokens[query.t or '']
        tokens[query.t or ''] = nil
        if not t or t.expires < os.time() then return reply(res, 403, { error = 'expired' }) end
        local ext = TYPES[query.type or ''] and query.type or 'jpg'
        local name = exports[RES]:SaveMedia(body or '', ext)
        if not name then return reply(res, 400, { error = 'invalid_file' }) end
        local url = mediaBase() .. name
        local id = MySQL.insert.await('INSERT INTO opslabs_phone_photos (owner, url) VALUES (?, ?)', { t.identifier, url })
        return reply(res, 200, { id = id, url = url })
    end

    -- normally nginx serves these straight from disk; this is the fallback
    local name = path:match('^/media/([%w_%-]+%.%a+)$')
    if name and req.method == 'GET' then
        local data = exports[RES]:ReadMedia(name)
        if not data then return reply(res, 404, { error = 'not_found' }) end
        res.writeHead(200, {
            ['Content-Type'] = TYPES[name:match('%.(%a+)$')] or 'application/octet-stream',
            ['Cache-Control'] = 'public, max-age=2592000, immutable',
            ['Access-Control-Allow-Origin'] = '*',
        })
        return res.send(data)
    end
    return reply(res, 404, { error = 'not_found' })
end
