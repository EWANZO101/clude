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
    -- OneSync only sends a client the players / cars near its ped: a relay hops round the city, so it sees further
    pcall(SetPlayerCullingRadius, src, on and (CV.RelayCulling or 600.0) or 0.0)
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

--- an OPS Hub customer: their character's job (online → live job, else the saved one)
local jobCache = {}
local function jobOf(identifier)
    if not identifier then return nil end
    local src = FW.SourceOf and FW.SourceOf(identifier)
    if src then return FW.Job(src) end
    local c = jobCache[identifier]
    if c and os.time() - c.at < 60 then return c.job end
    local ok, j = pcall(MySQL.scalar.await, 'SELECT job FROM users WHERE identifier = ?', { identifier })
    jobCache[identifier] = { job = ok and j or nil, at = os.time() }
    return ok and j or nil
end

--- the cameras this viewer may see from OPS Hub (nil viewer = OPS Hub staff: all of them)
local function visibleCams(viewer)
    local cams = CctvAllCams and CctvAllCams() or {}
    if not viewer then return cams end
    local job, out = jobOf(viewer), {}
    for _, c in ipairs(cams) do
        if CctvRemoteAllowed and CctvRemoteAllowed(c.recorder, viewer, job) then out[#out + 1] = c end
    end
    return out
end

function CctvViewerMay(id, viewer)
    if not viewer then return true end
    for _, c in ipairs(visibleCams(viewer)) do if c.id == tonumber(id) then return true end end
    return false
end

--- OPS Hub: every camera with its status and how fresh its picture is; marks them wanted (and one focused).
--- `viewer` (a character identifier) limits it to that customer's own / shared / organisation cameras.
function CctvLive(want, focus, viewer)
    local now = os.time()
    local cams = visibleCams(viewer)
    local mine = {}
    for _, c in ipairs(cams) do mine[c.id] = true end
    if focus and not mine[tonumber(focus)] then focus = nil end
    for _, c in ipairs(cams) do
        if want == 'all' or (type(want) == 'table' and want[c.id]) then Wanted[c.id] = now end
        local fr = Frames[c.id]
        c.frameAt = fr and fr.at or nil
        c.frameBy = (not viewer and fr) and fr.by or nil      -- customers don't see who relayed it
    end
    focus = tonumber(focus)
    if focus then Focus[focus] = now Wanted[focus] = now end
    local relays, watchers = 0, 0
    for _ in pairs(Relays) do relays = relays + 1 end
    for _ in pairs(Watching) do watchers = watchers + 1 end
    return { cams = cams, relays = relays, watchers = watchers, now = now }
end

--- OPS Hub live map: what this camera can see right now, worked out on the server (no game needed to render it).
--- Positions are metres in the camera's frame: x right, y ahead. People inside vehicles show as the vehicle.
function CctvMap(id, viewer)
    id = tonumber(id)
    if not id or not CctvViewerMay(id, viewer) then return nil end
    local v = CctvCamView and CctvCamView(id)
    if not v then return nil end
    local range = CctvCamRange and CctvCamRange(id) or 30
    local h = math.rad(v.heading or 0)
    local fx, fy = math.sin(h), -math.cos(h)       -- the camera's front, as in server/cctv.lua inView
    local rx, ry = fy, -fx                          -- its right (seen from above)
    local function rel(p)
        local dx, dy = p.x - v.x, p.y - v.y
        return math.floor((dx * rx + dy * ry) * 10 + 0.5) / 10, math.floor((dx * fx + dy * fy) * 10 + 0.5) / 10
    end
    local people, cars = {}, {}
    local hour = tonumber(os.date('%H'))
    if v.online then
        for _, p in ipairs(GetPlayers()) do
            local ped = GetPlayerPed(p)
            if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == 0 then
                local pos = GetEntityCoords(ped)
                if CctvInView(v, pos) then
                    local x, y = rel(pos)
                    people[#people + 1] = { x = x, y = y, h = math.floor(GetEntityHeading(ped) - (v.heading or 0)), moving = GetEntitySpeed(ped) > 0.6 }
                end
            end
        end
        for _, veh in ipairs(GetAllVehicles()) do
            local pos = GetEntityCoords(veh)
            if CctvInView(v, pos) then
                local x, y = rel(pos)
                local c1 = GetVehicleColours and select(1, GetVehicleColours(veh)) or nil
                local plate = v.anpr and (GetVehicleNumberPlateText(veh) or ''):gsub('^%s+', ''):gsub('%s+$', '') or nil
                local occupied = GetPedInVehicleSeat(veh, -1) ~= 0
                cars[#cars + 1] = { x = x, y = y, h = math.floor(GetEntityHeading(veh) - (v.heading or 0)), type = GetVehicleType(veh) or 'automobile',
                    colour = c1, plate = plate ~= '' and plate or nil, speed = math.floor(GetEntitySpeed(veh) * 2.237), occupied = occupied }
            end
        end
    end
    return { id = id, name = v.name, online = v.online, statusText = v.statusText, fov = v.fov, ptz = v.ptz, anpr = v.anpr,
        range = range, people = people, cars = cars, now = os.time(), night = hour >= 20 or hour < 6 }
end

function CctvFrame(id, viewer)
    if not CctvViewerMay(id, viewer) then return nil end
    local fr = Frames[tonumber(id) or -1]
    if not fr then return nil end
    return { jpg = fr.jpg, at = fr.at, by = fr.by }
end
