-- Bodycam server: who is recording (sessions), the uploads of each recorded part, the evidence record and the
-- Xon Sight hand-off. The client records; this side decides who may, stores the video and tells the portal.
--
-- A recording is one session (start → stop). Its video arrives in parts (Config.Video.SegmentSeconds), each part
-- uploaded in chunks over latent events, saved as a .webm and sent to Xon Sight as one evidence item.

local RES = GetCurrentResourceName()
-- server/audio.lua (voice); missing until the server re-reads the manifest (`refresh`): carry on without sound
local Audio = Audio or { Enabled = function() return false end, Start = function() end, Mark = function() end, Stop = function() end, Mux = function() end }
local SC = ServerConfig or {}
local storageCfg = SC.Storage or {}
local xsCfg = SC.XonSight or {}

local sessions = {}      -- src → live session
local byId = {}          -- session id → session (kept a while after stop, for parts still uploading)
local uploads = {}       -- upload id → upload in progress
local recent = {}        -- identifier → recordings, newest first (without a database)
local retryQueue = {}    -- recordings Xon Sight didn't take (without a database)
local liveStreams = {}   -- src → live video (MediaMTX WHIP) session - entirely separate from sessions above:
                         -- no recording, no evidence item, just a real-time feed. See handlers.liveStart/liveStop.
local useDb = false
local publicBase = ''
local roster           -- forward-declared: startSession/stopSession push an immediate sync, defined further down

-- helpers ---------------------------------------------------------------------------------------------------------

local function dbAwait(kind, query, params)
    local p = promise.new()
    exports.oxmysql[kind](exports.oxmysql, query, params or {}, function(r) p:resolve(r) end)
    return Citizen.Await(p)
end

local function serialFor(lic)
    local h = 5381
    for i = 1, #lic do h = (h * 33 + lic:byte(i)) % 100000000 end
    return ('X%08d'):format(h)
end

local function officerLabel(p)
    return (p.callsign and (p.callsign .. ' ') or '') .. (p.name or '')
end

local function jobText(p)
    if not p.job then return '' end
    return (p.jobLabel or p.job) .. (p.gradeLabel and (' · ' .. p.gradeLabel) or '')
end

local function clientState(src)
    local s = sessions[src]
    if not s then return { recording = false } end
    local p = s.player
    return {
        recording = true, id = s.id, startedAt = s.startedAt, trigger = s.trigger, note = s.note, serial = s.serial, officer = s.officer,
        name = p.name, callsign = p.callsign, dept = p.jobLabel or p.job, rank = p.gradeLabel,
    }
end

local function nextEvidenceId()
    local n = GetResourceKvpInt('evidence_seq')
    if n < 1 then n = 1 end
    SetResourceKvpInt('evidence_seq', n + 1)
    return (xsCfg.EvidenceIdOffset or 0) + n
end

-- sessions --------------------------------------------------------------------------------------------------------

local lastSessionTs = {}   -- src → last id timestamp issued, so a same-second stop/restart never reuses an id

local function startSession(src, trigger)
    if sessions[src] then return { ok = true, session = clientState(src) } end
    local ok, why = Bridge.CanUse(src)
    if not ok then return { ok = false, reason = why } end
    local p = Bridge.Player(src)
    local now = os.time()
    -- a fast manual stop/restart within the same second would otherwise mint the same 'bc-<src>-<ts>' id twice;
    -- the bridge (recorder.js) treats a repeated id as *resuming* the old, not-yet-torn-down recorder entry,
    -- bleeding its buffered audio into the new recording. Ids stay strictly increasing per src to prevent that.
    now = math.max(now, (lastSessionTs[src] or 0) + 1)
    lastSessionTs[src] = now
    local s = {
        id = ('bc-%d-%d'):format(src, now), src = src, startedAt = now, trigger = trigger or 'manual', note = '',
        player = p, officer = officerLabel(p), serial = serialFor(p.license), frame = nil, street = nil, parts = 0,
    }
    sessions[src], byId[s.id] = s, s
    Audio.Start(s.id, src)
    print(('[opslabs-bodycam] %s started recording (%s)'):format(s.officer, s.trigger))
    TriggerEvent('opslabs-bodycam:started', src, s.id, s.trigger)
    XonSight.SyncRoster(roster())      -- don't wait for the periodic thread - the Live page should show this now
    XonSight.SendAlert(s.id, s.officer, s.trigger)
    return { ok = true, session = clientState(src) }
end

local function stopSession(src, reason)
    local s = sessions[src]
    if not s then return false end
    sessions[src] = nil
    s.endedAt = os.time()
    Audio.Stop(s.id)
    XonSight.SyncRoster(roster())      -- same - the officer should disappear from /live immediately, not up to SyncSeconds later
    print(('[opslabs-bodycam] %s stopped recording (%s, %ds)'):format(s.officer, reason or 'manual', s.endedAt - s.startedAt))
    TriggerEvent('opslabs-bodycam:stopped', src, s.id, reason or 'manual')
    -- parts still uploading may arrive for a while
    SetTimeout(30 * 60000, function() if byId[s.id] == s and not sessions[src] then byId[s.id] = nil end end)
    return true
end

--- roster for Xon Sight /live and the phone app
function roster()
    local list = {}
    for _, s in pairs(sessions) do
        local f = s.frame
        list[#list + 1] = {
            id = s.id, name = s.officer, job = jobText(s.player), startedAt = s.startedAt, status = 'recording',
            lastFrame = f and { x = f.x, y = f.y, z = f.z, heading = f.heading, pitch = f.pitch, fov = f.fov } or nil,
        }
    end
    table.sort(list, function(a, b) return a.startedAt < b.startedAt end)
    return list
end

-- evidence --------------------------------------------------------------------------------------------------------

local function remember(rec)
    local l = recent[rec.identifier] or {}
    table.insert(l, 1, rec)
    if #l > 20 then l[#l] = nil end
    recent[rec.identifier] = l
end

local function deliver(rec)
    XonSight.SendEvidence(rec, function(ok)
        rec.sent = ok
        if useDb then
            exports.oxmysql:update('UPDATE opslabs_bodycam_recordings SET sent = ?, attempts = attempts + 1 WHERE id = ?', { ok and 1 or 0, rec.dbId })
        elseif not ok then
            rec.attempts = (rec.attempts or 0) + 1
            if rec.attempts < 10 then retryQueue[#retryQueue + 1] = rec end
        end
        local s = rec.src and GetPlayerName(rec.src) and rec.src
        if s then TriggerClientEvent('opslabs-bodycam:uploaded', s, { part = rec.part, evidenceId = rec.evidenceId, sent = ok }) end
    end)
end

local function caption(s, u)
    local bits = { s.officer }
    local job = jobText(s.player)
    if job ~= '' then bits[#bits + 1] = job end
    if u.street and u.street ~= '' then bits[#bits + 1] = u.street end
    if u.preroll then
        bits[#bits + 1] = ('PRE-EVENT BUFFER %d/%d · %s'):format(u.segIndex or 1, u.segCount or 1, os.date('%H:%M', u.startedAt))
    else
        bits[#bits + 1] = ('part %d · %s'):format(u.part, os.date('%H:%M', u.startedAt))
    end
    if s.trigger ~= 'manual' then bits[#bits + 1] = 'auto: ' .. s.trigger end
    if s.note and s.note ~= '' then bits[#bits + 1] = s.note end
    return table.concat(bits, ' · '):sub(1, 255)
end

local function finishUpload(id)
    local u = uploads[id]
    uploads[id] = nil
    local s = byId[u.session]
    local saved = exports[RES]:SaveVideo(table.concat(u.chunks))
    u.chunks = nil
    if type(saved) ~= 'table' or not saved.name then
        print(('^1[opslabs-bodycam] part %d of %s was not saved: %s^7'):format(u.part, u.session, saved and saved.error or '?'))
        TriggerClientEvent('opslabs-bodycam:uploaded', u.src, { part = u.part, error = saved and saved.error or 'save_failed' })
        return
    end
    local url, file = publicBase .. '/' .. saved.name, saved.name
    -- voice from the OPS Voice bridge: a new file with the sound mixed in; the silent one isn't needed any more
    local avUrl, avFile = Audio.Mux(u.session, u.part, saved.name, u.durationMs or u.duration * 1000)
    if avUrl then
        url, file = avUrl, avFile
        if (ServerConfig.Audio or {}).KeepSilentCopy ~= true then exports[RES]:DeleteVideo(saved.name) end
    end
    local rec = {
        src = u.src, session = u.session, part = u.part, identifier = s.player.identifier, license = s.player.license,
        name = s.officer, job = jobText(s.player), file = file, url = url, bytes = saved.bytes, sound = avUrl ~= nil,
        duration = u.duration, startedAt = u.startedAt, caption = caption(s, u), serial = s.serial,
    }
    if useDb then
        rec.dbId = dbAwait('insert', [[INSERT INTO opslabs_bodycam_recordings
            (session, part, identifier, license, name, job, file, url, bytes, duration, caption, trigger_reason, started_at, serial)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), ?)]],
            { rec.session, rec.part, rec.identifier, rec.license, rec.name, rec.job, rec.file, rec.url, rec.bytes, rec.duration, rec.caption, s.trigger, rec.startedAt, rec.serial })
        rec.evidenceId = (xsCfg.EvidenceIdOffset or 0) + rec.dbId
        exports.oxmysql:update('UPDATE opslabs_bodycam_recordings SET evidence_id = ? WHERE id = ?', { rec.evidenceId, rec.dbId })
    else
        rec.evidenceId = nextEvidenceId()
    end
    remember(rec)
    TriggerEvent('opslabs-bodycam:recorded', rec)     -- for other scripts (MDT, CAD, logs)
    deliver(rec)
end

-- client requests -------------------------------------------------------------------------------------------------

local handlers = {}

handlers.canUse = function(src)
    local ok, why = Bridge.CanUse(src)
    return { allowed = ok, reason = why, state = clientState(src) }
end

-- first-spawn call sign prompt: whichever jobs are configured for a camera (Config.Access.Jobs —
-- police / fire / ems or whatever a server names them), independent of Config.Access.Mode, so this
-- still offers a call sign even on an 'item' or 'everyone' server. Never prompts someone who already
-- has one (framework metadata, or set here before).
handlers.checkCallsignPrompt = function(src)
    local p = Bridge.Player(src)
    local jobs = (Config.Access or {}).Jobs or {}
    if not p.job or not jobs[p.job] then return { prompt = false } end
    if p.callsign and p.callsign:match('%S') then return { prompt = false } end
    return { prompt = true, jobLabel = p.jobLabel or p.job }
end

handlers.setCallsign = function(src, d)
    local p = Bridge.Player(src)
    local jobs = (Config.Access or {}).Jobs or {}
    if not p.job or not jobs[p.job] then return { ok = false } end
    local callsign = tostring(type(d) == 'table' and d.callsign or ''):gsub('[%c]', ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 24)
    if callsign == '' then return { ok = false } end
    Player(src).state:set('callsign', callsign, true)
    return { ok = true, callsign = callsign }
end

handlers.start = function(src, d) return startSession(src, type(d) == 'table' and d.trigger or 'manual') end

handlers.stop = function(src, d)
    stopSession(src, type(d) == 'table' and d.reason or 'manual')
    return { ok = true }
end

handlers.note = function(src, d)
    local s = sessions[src]
    if not s then return { ok = false } end
    s.note = tostring(type(d) == 'table' and d.note or ''):gsub('[%c]', ' '):sub(1, 80)
    return { ok = true, note = s.note }
end

handlers.live = function() return roster() end

-- live video (MediaMTX WHIP) -----------------------------------------------------------------------------------
--
-- Uses the same access gate as recorded bodycam (Config.Access) - this is the same camera, just a different
-- destination for the picture - and Bridge.Player's identifier as the recorder id, not a per-session id like
-- `sessions` above: a live broadcast isn't a recording, it has nothing to resume or append to, and a stable id
-- lets Xon Sight's /live/start upsert the same row if an officer's client reconnects mid-broadcast.

local function liveStartAwait(recorderId, kind, name, job)
    local p = promise.new()
    XonSight.StartLive(recorderId, kind, name, job, function(ok, path, token) p:resolve({ ok = ok, path = path, token = token }) end)
    return Citizen.Await(p)
end

handlers.liveStart = function(src, d)
    local lsc = ServerConfig.LiveStream or {}
    if lsc.Enabled ~= true or not lsc.WhipUrlFormat or lsc.WhipUrlFormat == '' then
        return { ok = false, reason = 'not_configured' }
    end
    if liveStreams[src] then
        return { ok = true, whip = lsc.WhipUrlFormat:format(liveStreams[src].path), token = liveStreams[src].token }
    end
    local ok, why = Bridge.CanUse(src)
    if not ok then return { ok = false, reason = why } end
    if not XonSight.Configured() then return { ok = false, reason = 'not_configured' } end
    local p = Bridge.Player(src)
    local kind = (type(d) == 'table' and d.kind) or (Config.LiveStream or {}).Kind or 'dashcam'
    local r = liveStartAwait(p.identifier, kind, officerLabel(p), jobText(p))
    if not r.ok then return { ok = false, reason = 'portal_unreachable' } end
    liveStreams[src] = { recorderId = p.identifier, path = r.path, token = r.token, kind = kind }
    print(('[opslabs-bodycam] %s started a live %s broadcast (%s)'):format(officerLabel(p), kind, r.path))
    return { ok = true, whip = lsc.WhipUrlFormat:format(r.path), token = r.token }
end

handlers.liveStop = function(src)
    local s = liveStreams[src]
    if not s then return { ok = true } end
    liveStreams[src] = nil
    XonSight.StopLive(s.recorderId)
    print(('[opslabs-bodycam] live broadcast stopped (%s)'):format(s.path))
    return { ok = true }
end

handlers.recent = function(src)
    local p = Bridge.Player(src)
    if useDb then
        return dbAwait('query', [[SELECT part, evidence_id AS evidenceId, url, duration, caption, sent, UNIX_TIMESTAMP(started_at) AS startedAt
            FROM opslabs_bodycam_recordings WHERE identifier = ? ORDER BY id DESC LIMIT 15]], { p.identifier }) or {}
    end
    local out = {}
    for i, r in ipairs(recent[p.identifier] or {}) do
        out[i] = { part = r.part, evidenceId = r.evidenceId, url = r.url, duration = r.duration, caption = r.caption, sent = r.sent, startedAt = r.startedAt }
    end
    return out
end

handlers.uploadBegin = function(src, d)
    if type(d) ~= 'table' then return { ok = false } end
    local s = byId[d.session]
    if not s or s.src ~= src then return { ok = false, reason = 'no_session' } end
    local max = (storageCfg.MaxSegmentMB or 64) * 1024 * 1024
    local size = tonumber(d.size) or 0
    if size <= 0 or size > max then return { ok = false, reason = 'too_large' } end
    local mine = 0
    for _, u in pairs(uploads) do if u.src == src then mine = mine + 1 end end
    if mine >= 3 then return { ok = false, reason = 'busy' } end
    s.parts = s.parts + 1
    local id = ('%s-%d-%d'):format(s.id, s.parts, math.random(100000, 999999))
    uploads[id] = {
        src = src, session = s.id, part = tonumber(d.part) or s.parts, total = tonumber(d.chunks) or 0, chunks = {}, received = 0, bytes = 0,
        max = math.ceil(max * 4 / 3) + 16, duration = tonumber(d.duration) or 0, durationMs = tonumber(d.durationMs), startedAt = tonumber(d.startedAt) or os.time(),
        street = type(d.street) == 'string' and d.street:sub(1, 80) or nil, touched = os.time(),
        preroll = d.preroll == true, segIndex = tonumber(d.segIndex), segCount = tonumber(d.segCount),
    }
    return { ok = true, upload = id }
end

RegisterNetEvent('opslabs-bodycam:request', function(reqId, action, data)
    local src = source
    local h = handlers[action]
    local ok, result = false, nil
    if h then ok, result = pcall(h, src, data) end
    if h and not ok then print(('^1[opslabs-bodycam] %s failed: %s^7'):format(action, result)) result = nil end
    TriggerClientEvent('opslabs-bodycam:reply', src, reqId, result)
end)

RegisterNetEvent('opslabs-bodycam:chunk', function(id, index, data)
    local src = source
    local u = uploads[id]
    if not u or u.src ~= src or type(data) ~= 'string' or index ~= u.received + 1 or index > u.total then
        return TriggerClientEvent('opslabs-bodycam:ack', src, id, index, false)
    end
    u.bytes = u.bytes + #data
    if u.bytes > u.max then
        uploads[id] = nil
        return TriggerClientEvent('opslabs-bodycam:ack', src, id, index, false)
    end
    u.chunks[index], u.received, u.touched = data, index, os.time()
    TriggerClientEvent('opslabs-bodycam:ack', src, id, index, true)
    if u.received == u.total then finishUpload(id) end
end)

-- a video part started on the client: time zero for its voice
RegisterNetEvent('opslabs-bodycam:partStarted', function(id, part)
    local s = byId[id]
    if s and s.src == source and tonumber(part) then Audio.Mark(id, tonumber(part)) end
end)

RegisterNetEvent('opslabs-bodycam:micResult', function(d)
    if type(d) == 'table' then print(('[opslabs-bodycam] mic test from %s: %s'):format(GetPlayerName(source) or source, json.encode(d))) end
end)

RegisterNetEvent('opslabs-bodycam:frame', function(f)
    local s = sessions[source]
    if not s or type(f) ~= 'table' then return end
    local n = function(v, d) v = tonumber(v) return v and v == v and v or d end
    s.frame = { x = n(f.x, 0.0), y = n(f.y, 0.0), z = n(f.z, 0.0), heading = n(f.heading, 0.0), pitch = n(f.pitch, 0.0), fov = n(f.fov, 50.0) }
end)

AddEventHandler('playerDropped', function()
    local src = source
    stopSession(src, 'left the server')
    for id, u in pairs(uploads) do if u.src == src then uploads[id] = nil end end
    local live = liveStreams[src]
    if live then liveStreams[src] = nil XonSight.StopLive(live.recorderId) end
end)

-- other scripts: start someone's camera (taser, panic button, pursuit…) — TriggerEvent('opslabs-bodycam:trigger', src, 'panic')
AddEventHandler('opslabs-bodycam:trigger', function(src, reason)
    if not sessions[src] and Bridge.CanUse(src) then TriggerClientEvent('opslabs-bodycam:remoteStart', src, reason or 'external') end
end)

exports('CanUse', function(src) return (Bridge.CanUse(src)) end)
exports('IsRecording', function(src) return sessions[src] ~= nil end)
--- is `id` the session currently live for `src`? (server/storage.js's voice-command handler: a stale/delayed
--- "off", or a src FiveM has since recycled onto someone else, must never match a different, newer session)
exports('IsLiveSession', function(src, id) local s = sessions[tonumber(src)] return s ~= nil and s.id == id end)
exports('StartRecording', function(src, reason)
    if sessions[src] or not Bridge.CanUse(src) then return false end
    TriggerClientEvent('opslabs-bodycam:remoteStart', src, reason or 'external')
    return true
end)
exports('StopRecording', function(src) if not sessions[src] then return false end TriggerClientEvent('opslabs-bodycam:remoteStop', src, 'external') return true end)
exports('GetActiveRecorders', roster)      -- same name as XonSight's export

-- start-up --------------------------------------------------------------------------------------------------------

local function initDb()
    if SC.Database == false or GetResourceState('oxmysql') ~= 'started' then return false end
    local ok = pcall(dbAwait, 'query', [[CREATE TABLE IF NOT EXISTS opslabs_bodycam_recordings (
        id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        evidence_id BIGINT NULL,
        session VARCHAR(48) NOT NULL,
        part SMALLINT UNSIGNED NOT NULL DEFAULT 1,
        identifier VARCHAR(80) NOT NULL,
        license VARCHAR(80) NOT NULL DEFAULT '',
        name VARCHAR(128) NOT NULL DEFAULT '',
        job VARCHAR(96) NOT NULL DEFAULT '',
        file VARCHAR(64) NOT NULL,
        url VARCHAR(255) NOT NULL,
        bytes INT UNSIGNED NOT NULL DEFAULT 0,
        duration INT UNSIGNED NOT NULL DEFAULT 0,
        caption VARCHAR(255) NOT NULL DEFAULT '',
        trigger_reason VARCHAR(32) NOT NULL DEFAULT 'manual',
        started_at DATETIME NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        sent TINYINT(1) NOT NULL DEFAULT 0,
        attempts SMALLINT UNSIGNED NOT NULL DEFAULT 0,
        serial VARCHAR(16) NOT NULL DEFAULT '',
        KEY idx_identifier (identifier),
        KEY idx_unsent (sent, attempts)
    )]])
    -- column added after some servers already had this table - CREATE TABLE IF NOT EXISTS above doesn't touch an
    -- existing one, so add it here too. MySQL (unlike MariaDB) has no ADD COLUMN IF NOT EXISTS, and oxmysql logs
    -- a query error to console even when pcall catches it Lua-side - so check first instead of attempting-and-
    -- swallowing, which was spamming "Duplicate column name 'serial'" on every single restart.
    local hasSerial = dbAwait('scalar', [[SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'opslabs_bodycam_recordings' AND COLUMN_NAME = 'serial']])
    if tonumber(hasSerial) == 0 then
        pcall(dbAwait, 'query', [[ALTER TABLE opslabs_bodycam_recordings ADD COLUMN serial VARCHAR(16) NOT NULL DEFAULT '']])
    end
    return ok
end

CreateThread(function()
    Wait(1000)      -- let the framework start first
    Bridge.Init()
    local dir = exports[RES]:ConfigureStorage(storageCfg.Dir or '', storageCfg.MaxSegmentMB or 64)
    publicBase = (storageCfg.PublicUrl or ''):gsub('/+$', '')
    if publicBase == '' then
        print('^3[opslabs-bodycam] No public address for the videos: set ServerConfig.Storage.PublicUrl — the portal cannot play them otherwise^7')
    end
    useDb = initDb()
    print(('[opslabs-bodycam] Videos: %s → %s · database: %s · Xon Sight: %s · voice: %s'):format(dir, publicBase ~= '' and publicBase or '(none)',
        useDb and 'yes' or 'no', XonSight.Configured() and xsCfg.Url or 'not set', Audio.Enabled() and 'OPS Voice bridge' or 'off'))
end)

-- live roster → Xon Sight
CreateThread(function()
    Wait(5000)
    while true do
        XonSight.SyncRoster(roster())
        Wait(math.max(2, xsCfg.SyncSeconds or 5) * 1000)
    end
end)

-- live video heartbeats → Xon Sight (keeps a /live/start registration from going stale) + drop anyone no
-- longer issued a camera, same gate as the recording thread below
CreateThread(function()
    Wait(5000)
    while true do
        for src, s in pairs(liveStreams) do
            if GetPlayerName(src) and Bridge.CanUse(src) then
                XonSight.LiveHeartbeat(s.recorderId)
            else
                liveStreams[src] = nil
                XonSight.StopLive(s.recorderId)
                if GetPlayerName(src) then TriggerClientEvent('opslabs-bodycam:remoteStopLive', src, 'no longer issued a bodycam') end
            end
        end
        Wait(math.max(2, (Config.LiveStream or {}).HeartbeatSeconds or 5) * 1000)
    end
end)

-- going off duty / losing the job or item stops the camera; stalled uploads are dropped
CreateThread(function()
    while true do
        Wait(20000)
        for src in pairs(sessions) do
            if not Bridge.CanUse(src) then
                TriggerClientEvent('opslabs-bodycam:remoteStop', src, 'no longer issued a bodycam')
            end
        end
        local now = os.time()
        for id, u in pairs(uploads) do if now - u.touched > 180 then uploads[id] = nil end end
    end
end)

-- evidence the portal didn't take is sent again
CreateThread(function()
    while true do
        Wait(120000)
        if useDb then
            local rows = dbAwait('query', [[SELECT id, evidence_id, identifier, name, url, caption, serial, UNIX_TIMESTAMP(started_at) AS startedAt
                FROM opslabs_bodycam_recordings WHERE sent = 0 AND attempts < 10 AND evidence_id IS NOT NULL ORDER BY id LIMIT 20]]) or {}
            for _, r in ipairs(rows) do
                deliver({ dbId = r.id, evidenceId = r.evidence_id, identifier = r.identifier, name = r.name, url = r.url, caption = r.caption, serial = r.serial, startedAt = r.startedAt })
            end
        elseif #retryQueue > 0 then
            local q = retryQueue
            retryQueue = {}
            for _, rec in ipairs(q) do deliver(rec) end
        end
    end
end)

AddEventHandler('onResourceStop', function(r)
    if r ~= RES then return end
    -- tell the OPS Voice bridge too, or its listening bot (and any voice-command STT stream) for every session
    -- live right now is leaked forever - nothing else ever sends it a matching /ctl/rec/stop once this table is gone
    for _, s in pairs(sessions) do Audio.Stop(s.id) end
    sessions = {}
    XonSight.SyncRoster({})
    for _, s in pairs(liveStreams) do XonSight.StopLive(s.recorderId) end
    liveStreams = {}
end)
