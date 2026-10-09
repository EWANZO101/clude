-- OPS Voice: OPS Hub has phone numbers too — one per company and one per Hub user (table ops_voip_lines, made on
-- OPS Hub). Phones call them like any number and the Hub's browser softphone rings; the Hub calls phones the same way.
-- The OPS Voice bridge (/opt/opsvoip-bridge) carries the audio: it listens to the player in their own pma-voice
-- channel and the phone plays the Hub caller (html/js/apps/phone.js: HubAudio). Call state stays in server/calls.lua.

local RES = GetCurrentResourceName()
local CFG = Config.Voip or {}
local URL = GetConvar('opsvoip_url', 'http://127.0.0.1:5131')
local KEY = GetConvar('opsvoip_key', '')
local route, apiError = ApiRoute, ApiError

Voip = {}
local lines = {}      -- [number] = { number, label, kind, company_id }

local function enabled() return CFG.Enabled ~= false and #KEY >= 24 end

local function loadLines()
    local ok, rows = pcall(MySQL.query.await, 'SELECT number, label, kind, company_id FROM ops_voip_lines WHERE active = 1')
    if not ok or not rows then return end
    local t = {}
    for _, r in ipairs(rows) do t[r.number] = r end
    lines = t
end

--- the OPS Hub line with this number, if any
function Voip.Line(number)
    if not enabled() then return nil end
    return lines[number]
end

local function bridge(path, body, cb)
    PerformHttpRequest(URL .. '/ctl/' .. path, function(status, text)
        local ok, data = pcall(json.decode, text or '')
        if status ~= 200 then print(('^3[opslabs-phone] OPS Voice bridge %s: HTTP %s^7'):format(path, tostring(status))) end
        if cb then cb(status, ok and data or nil) end
    end, 'POST', json.encode(body or {}), { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. KEY })
end

--- a player is calling a Hub line: ring its softphones (no softphone open: the call rings out)
function Voip.Incoming(call, phone)
    bridge('incoming', { gameCallId = call.id, from = call.callerNumber, fromName = phone.name, to = call.calleeNumber }, function(status, data)
        if status == 200 and data and data.ok then HubCalls.SetBridge(call.id, data.id) end
    end)
end

--- the player answered a call from the Hub: the bridge joins their voice channel
function Voip.Answered(bridgeId, src)
    bridge('answered', { id = bridgeId, serverId = src, channel = Player(src).state.assignedChannel })
end

function Voip.Ended(bridgeId, status)
    if bridgeId then bridge('ended', { id = bridgeId, status = status }) end
end

--- where the phone hears the Hub caller (a signed, call-bound token)
function Voip.Playback(bridgeId)
    if not bridgeId then return nil end
    local token = exports[RES]:VoipToken(json.encode({ kind = 'player', call = bridgeId, exp = os.time() + 4 * 3600 }), KEY)
    return { url = CFG.PublicUrl, token = token, volume = CFG.Volume or 1.0 }
end

---------------------------------------------------------------------------
-- REST for the bridge (same key as the rest of the API)
---------------------------------------------------------------------------
-- everyone on the server, including players still loading in (their voice connects before GetPlayers lists them):
-- the bridge's guard lets their voice connections ("[id] name") through
local joining = {}    -- [server id] = os.time() since playerJoining
AddEventHandler('playerJoining', function() joining[source] = os.time() end)
AddEventHandler('playerDropped', function() joining[source] = nil end)

route('GET', '/voip/players', function()
    local list, seen = {}, {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        seen[id] = true
        joining[id] = nil
        list[#list + 1] = { id = id, name = GetPlayerName(id) }
    end
    for id, at in pairs(joining) do
        if os.time() - at > 600 then joining[id] = nil
        elseif not seen[id] then list[#list + 1] = { id = id, name = GetPlayerName(id), joining = true } end
    end
    return list
end)

route('POST', '/voip/dial', function(_, _, body)
    if not enabled() then apiError(503, 'OPS Voice is off') end
    local from = tostring(body.from or '')
    local line = Voip.Line(from)
    if not line or not body.bridgeId then apiError(400, 'unknown line') end
    local call, err = HubCalls.Dial(tostring(body.bridgeId), from, tostring(body.label or line.label), tostring(body.to or ''))
    if not call then apiError(err == 'no_number' and 404 or 400, err or 'invalid') end
    return { id = call.id, number = call.calleeNumber }
end)

route('POST', '/voip/calls/(%d+)/answer', function(p, _, body)
    local src = HubCalls.Answer(p[1], tostring(body.bridgeId or ''))
    if not src then apiError(409, 'not ringing') end
    return { serverId = src, channel = Player(src).state.assignedChannel }
end)

route('POST', '/voip/calls/(%d+)/end', function(p, _, body)
    return HubCalls.End(p[1], tostring(body.bridgeId or ''), body.reason)
end)

-- the bridge started: calls it was carrying are gone
route('POST', '/voip/reset', function()
    return { ended = HubCalls.Reset() }
end)

-- OPS Hub added, renamed or switched off a line
route('POST', '/voip/lines/reload', function()
    loadLines()
    local n = 0
    for _ in pairs(lines) do n = n + 1 end
    return { lines = n }
end)

CreateThread(function()
    if CFG.Enabled == false then return end
    AwaitDatabase()
    local sql = LoadResourceFile(RES, 'sql/ops_voip.sql') or ''
    for stmt in sql:gmatch('CREATE TABLE.-;') do pcall(MySQL.query.await, stmt) end
    if #KEY < 24 then print('^3[opslabs-phone] OPS Voice is off: set opsvoip_key (24+ characters) and opsvoip_url in server.cfg^7') end
    while true do
        loadLines()
        Wait(30000)
    end
end)
