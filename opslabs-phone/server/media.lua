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

-- base64 → bytes (ReadMediaBase64 in media.js)
local B64 = {}
for i, c in ipairs({ ('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'):byte(1, -1) }) do B64[c] = i - 1 end
local function fromBase64(s)
    s = s:gsub('[^%w%+/=]', '')
    local out, n = {}, 0
    for i = 1, #s - 3, 4 do
        local a, b, c, d = s:byte(i, i + 3)
        local A, Bv, C, D = B64[a], B64[b], B64[c], B64[d]
        if not A or not Bv then return nil end
        local v = A * 262144 + Bv * 4096 + (C or 0) * 64 + (D or 0)
        n = n + 1
        if c == 61 then out[n] = string.char(v >> 16)
        elseif d == 61 then out[n] = string.char(v >> 16, (v >> 8) & 255)
        else out[n] = string.char(v >> 16, (v >> 8) & 255, v & 255) end
    end
    return table.concat(out)
end

local function reply(res, status, body)
    -- a closed request must never take the server down
    local ok = pcall(res.writeHead, status, {
        ['Content-Type'] = 'application/json',
        ['Access-Control-Allow-Origin'] = '*',
        ['Access-Control-Allow-Headers'] = 'Content-Type',
        ['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS',
        ['Cache-Control'] = 'no-store',
    })
    if ok then pcall(res.send, json.encode(body)) end
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
        local b64 = exports[RES]:ReadMediaBase64(name)
        local data = type(b64) == 'string' and fromBase64(b64) or nil
        if not data then return reply(res, 404, { error = 'not_found' }) end
        local ok = pcall(res.writeHead, 200, {
            ['Content-Type'] = TYPES[name:match('%.(%a+)$')] or 'application/octet-stream',
            ['Cache-Control'] = 'public, max-age=2592000, immutable',
            ['Access-Control-Allow-Origin'] = '*',
        })
        if ok then pcall(res.send, data) end
        return
    end
    return reply(res, 404, { error = 'not_found' })
end
