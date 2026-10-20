-- Xon Sight evidence portal (https://github.com/EWANZO101/xonsight):
--   POST /api/xonsight/evidence          { id, submitterIdentifier, submitterName, caption, videoUrl, createdAt,
--                                           deviceSerial }
--                                        one per recorded part; the portal keeps the link, the video stays with us
--   POST /api/xonsight/recorders/sync    { recorders = [{ id, name, job, status, startedAt, lastFrame }], syncedAt }
--                                        the whole live roster each time (anyone missing is taken off /live)
--   POST /api/xonsight/alerts            { recorderId, recorderName, type, message }
--                                        emergency trigger banner on the portal's Live page - see AlertTriggers
--                                        below; extension endpoint, not guaranteed on every Xon Sight deployment
-- All three carry the X-XonSight-Key header (XONSIGHT_WEBHOOK_KEY in the portal's .env).

XonSight = {}

local cfg = ServerConfig.XonSight or {}

local function post(path, body, cb)
    if not cfg.Url or cfg.Url == '' then return cb and cb(0, 'no_url') end
    PerformHttpRequest(cfg.Url .. path, function(status, text)
        if cb then cb(status or 0, text) end
    end, 'POST', json.encode(body), {
        ['Content-Type'] = 'application/json',
        ['X-XonSight-Key'] = cfg.Key or '',
    })
end

local function iso(t) return os.date('!%Y-%m-%dT%H:%M:%SZ', t) end

local function get(path, cb)
    if not cfg.Url or cfg.Url == '' then return cb and cb(0, nil) end
    PerformHttpRequest(cfg.Url .. path, function(status, text)
        local ok, data = pcall(json.decode, text or '')
        cb(status or 0, (ok and type(data) == 'table') and data or nil)
    end, 'GET', '', { ['X-XonSight-Key'] = cfg.Key or '' })
end

--- send one recording; cb(ok, status)
function XonSight.SendEvidence(rec, cb)
    local caption = rec.caption or ''
    if cfg.ServerTag and cfg.ServerTag ~= '' then caption = '[' .. cfg.ServerTag .. '] ' .. caption end
    post('/api/xonsight/evidence', {
        id = rec.evidenceId,
        submitterIdentifier = rec.identifier,
        submitterName = rec.name,
        caption = caption:sub(1, 255),
        videoUrl = rec.url,
        createdAt = iso(rec.startedAt),
        deviceSerial = rec.serial,     -- already computed per-officer (serialFor() in server/main.lua)
    }, function(status, text)
        local ok = status >= 200 and status < 300
        if not ok then
            print(('^3[opslabs-bodycam] Xon Sight did not take evidence #%s (HTTP %s%s)^7'):format(rec.evidenceId, status,
                status == 401 and ': the key in config_server.lua does not match XONSIGHT_WEBHOOK_KEY' or ''))
        end
        if cb then cb(ok, status) end
    end)
end

-- alerts (emergency trigger banner) ---------------------------------------------------------------------------------

--- reason (session.trigger, e.g. 'shots fired') -> { type, message } sent to the portal; anything not listed here
--- never fires an alert (routine triggers like 'lights and siren' would just be noise on the Live page)
local alertTriggers = cfg.AlertTriggers or {
    ['shots fired'] = { type = 'weapon_fired', message = 'Shots fired' },
    ['weapon drawn'] = { type = 'weapon_drawn', message = 'Weapon drawn' },
}

--- fire-and-forget; call right when a session starts (see server/main.lua)
function XonSight.SendAlert(recorderId, recorderName, trigger)
    local mapped = alertTriggers[trigger]
    if not mapped then return end
    post('/api/xonsight/alerts', {
        recorderId = recorderId,
        recorderName = recorderName,
        type = mapped.type,
        message = mapped.message,
    }, function(status)
        if status == 401 then print('^3[opslabs-bodycam] Xon Sight refused the alert (401): check the key in config_server.lua^7') end
    end)
end

-- live roster -----------------------------------------------------------------------------------------------------

local lastSent, lastAt = nil, 0

--- recorders: list from server/main.lua; sent when it changes, every SyncSeconds while anyone records, and once a
--- minute when nobody does (clears a roster left behind by a restart)
function XonSight.SyncRoster(recorders)
    if cfg.LiveSync == false then return end
    local body = json.encode(recorders)
    local now = os.time()
    if #recorders == 0 and body == lastSent and now - lastAt < 60 then return end
    lastSent, lastAt = body, now
    post('/api/xonsight/recorders/sync', { recorders = recorders, syncedAt = now }, function(status)
        if status < 200 or status >= 300 then
            lastSent = nil      -- try again next round
            if status == 401 then print('^3[opslabs-bodycam] Xon Sight refused the live roster (401): check the key in config_server.lua^7') end
        end
    end)
end

function XonSight.Configured() return cfg.Url and cfg.Url ~= '' end

-- remote feature flags (GET /api/xonsight/features) ------------------------------------------------------------
--
-- Polled, not checked live: the phone (opslabs-phone) asks every player's config every few seconds, far too
-- often for an HTTP round trip each time. Fails open (stays at whatever it last knew, true until the first
-- poll ever completes) - a network hiccup shouldn't suddenly hide a feature that's actually meant to be on;
-- if the portal is unreachable for good, that's exactly as visible in the console as any other failed send here.
local phoneAppEnabled = true

function XonSight.IsPhoneAppEnabled() return phoneAppEnabled end

local function pollFeatures()
    get('/api/xonsight/features', function(status, data)
        if status >= 200 and status < 300 and data and data.phoneAppEnabled ~= nil then
            phoneAppEnabled = data.phoneAppEnabled == true
        elseif status == 401 then
            print('^3[opslabs-bodycam] Xon Sight refused the feature check (401): check the key in config_server.lua^7')
        end
    end)
end

CreateThread(function()
    if not XonSight.Configured() then return end
    while true do
        pollFeatures()
        Wait(5 * 60000)
    end
end)

-- opslabs-phone checks this before showing the Bodycam app's "My footage"/"Live" tabs at all (its own
-- server/main.lua config.bodycam) - keeps the Xon Sight relationship entirely inside this resource rather
-- than duplicating the portal URL/key into opslabs-phone's own config too.
exports('IsPhoneAppEnabled', XonSight.IsPhoneAppEnabled)
