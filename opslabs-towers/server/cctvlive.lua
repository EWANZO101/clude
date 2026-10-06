-- OPS Secure CCTV live on OPS Hub. A camera's picture only exists while a game client renders it, so frames come from:
--   · anyone watching cameras in game (monitor, video wall, phone Secure View): ~1 frame a second of what they see
--   · CCTV relays (/cctvrelay, staff): a game that cycles through the cameras OPS Hub viewers are looking at, so every
--     watched camera stays live — the Hub's "focus" camera most often
-- The latest JPEG per camera is kept in memory and served to OPS Hub (GET /api/cctv/live, /api/cctv/frame/<id>).

local CV = Config.Cctv or {}
if not CV.Enabled then return end

local Frames = {}       -- camera id -> { jpg = base64, at = unix, by = name }
local Wanted = {}       -- camera id -> unix time an OPS Hub viewer last showed it
local Focus = {}        -- camera id -> unix time an OPS Hub viewer last had it open big
local Watching = {}     -- src -> { [cameraId] = true } (in-game viewers)
local Relays = {}       -- src -> true
local MAX_B64 = 400000

function CctvLiveWatching(src, cams)
    local set = {}
    for _, c in ipairs(cams or {}) do set[c.id] = true end
    Watching[src] = set
end

AddEventHandler('playerDropped', function() Watching[source] = nil Relays[source] = nil end)

RegisterNetEvent('opslabs-towers:cctv:frame', function(camId, b64)
    local src = source
    camId = tonumber(camId)
    if not camId or type(b64) ~= 'string' or #b64 < 200 or #b64 > MAX_B64 then return end
    if not (Relays[src] or (Watching[src] and Watching[src][camId])) then return end
    if not b64:match('^[A-Za-z0-9+/=]+$') then return end
    local c = CctvCamView and CctvCamView(camId)
    if not c then return end
    Frames[camId] = { jpg = b64, at = os.time(), by = GetPlayerName(src), online = c.online }
end)

-- in-game viewer stopped watching
RegisterNetEvent('opslabs-towers:cctv:stopWatching', function() Watching[source] = nil end)

local function staff(src)
    return (IsTowerAdmin and IsTowerAdmin(src)) or (CanCable and CanCable(src))
end

lib.callback.register('opslabs-towers:cctv:relay', function(src, on)
    if on and not staff(src) then return { error = 'Only OPS Secure staff and admins can run a CCTV relay' } end
    Relays[src] = on and true or nil
    return { ok = true }
end)

--- the cameras a relay should show next: what OPS Hub viewers have open (big ones first), stalest frame first
lib.callback.register('opslabs-towers:cctv:relayNext', function(src)
    if not Relays[src] then return {} end
    local now = os.time()
    local list = {}
    for _, c in ipairs(CctvAllCams and CctvAllCams() or {}) do
        local f = Focus[c.id] and now - Focus[c.id] < 12
        local w = f or (Wanted[c.id] and now - Wanted[c.id] < 20)
        if w and c.online then
            local fr = Frames[c.id]
            c.age = fr and now - fr.at or 9999
            c.focus = f or nil
            list[#list + 1] = c
        end
    end
    table.sort(list, function(a, b)
        if (a.focus ~= nil) ~= (b.focus ~= nil) then return a.focus ~= nil end
        return a.age > b.age
    end)
    local out = {}
    for i = 1, math.min(8, #list) do out[i] = list[i] end
    -- a focused camera comes round twice as often
    if out[1] and out[1].focus and #out > 2 then table.insert(out, 3, out[1]) end
    return out
end)

--- OPS Hub: every camera with its status and how fresh its picture is; marks them wanted (and one focused)
function CctvLive(want, focus)
    local now = os.time()
    local cams = CctvAllCams and CctvAllCams() or {}
    for _, c in ipairs(cams) do
        if want == 'all' or (type(want) == 'table' and want[c.id]) then Wanted[c.id] = now end
        local fr = Frames[c.id]
        c.frameAt = fr and fr.at or nil
        c.frameBy = fr and fr.by or nil
    end
    focus = tonumber(focus)
    if focus then Focus[focus] = now Wanted[focus] = now end
    local relays, watchers = 0, 0
    for _ in pairs(Relays) do relays = relays + 1 end
    for _ in pairs(Watching) do watchers = watchers + 1 end
    return { cams = cams, relays = relays, watchers = watchers, now = now }
end

function CctvFrame(id)
    local fr = Frames[tonumber(id) or -1]
    if not fr then return nil end
    return { jpg = fr.jpg, at = fr.at, by = fr.by }
end
