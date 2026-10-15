-- Xon Sight evidence portal (https://github.com/EWANZO101/xonsight):
--   POST /api/xonsight/evidence        { id, submitterIdentifier, submitterName, caption, videoUrl, createdAt }
--                                      one per recorded part; the portal keeps the link, the video stays with us
--   POST /api/xonsight/recorders/sync  { recorders = [{ id, name, job, startedAt, lastFrame }], syncedAt }
--                                      the whole live roster each time (anyone missing is taken off /live)
-- Both carry the X-XonSight-Key header (XONSIGHT_WEBHOOK_KEY in the portal's .env).

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
    }, function(status, text)
        local ok = status >= 200 and status < 300
        if not ok then
            print(('^3[opslabs-bodycam] Xon Sight did not take evidence #%s (HTTP %s%s)^7'):format(rec.evidenceId, status,
                status == 401 and ': the key in config_server.lua does not match XONSIGHT_WEBHOOK_KEY' or ''))
        end
        if cb then cb(ok, status) end
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
