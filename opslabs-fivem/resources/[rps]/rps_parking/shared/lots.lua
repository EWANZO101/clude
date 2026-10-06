-- Shared helpers for parking lots (stored in the ParkingLots table, edited in-game with the lot editor)
LotUtil = {}

-- Filled from the database (server) / GlobalState (clients)
Config.ParkingLots = {}

local function num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function HasZone(lot)
    return lot.zone and lot.zone.points and #lot.zone.points >= 3
end
LotUtil.HasZone = HasZone

--- Derives coords/radius (used for "near lot" checks, blips, markers) from the zone.
function LotUtil.Finalize(lot)
    lot.spots = lot.spots or {}
    if HasZone(lot) then
        local pts, cx, cy, cz = lot.zone.points, 0.0, 0.0, 0.0
        for _, p in ipairs(pts) do cx, cy, cz = cx + p.x, cy + p.y, cz + p.z end
        cx, cy, cz = cx / #pts, cy / #pts, cz / #pts
        local r = 0.0
        for _, p in ipairs(pts) do r = math.max(r, #(vec2(p.x, p.y) - vec2(cx, cy))) end
        lot.coords = vec3(cx, cy, cz)
        lot.radius = r + 5.0
    end
    lot.coords = lot.coords or (lot.spots[1] and lot.spots[1].xyz) or vec3(0.0, 0.0, 0.0)
    lot.radius = lot.radius or 50.0
    return lot
end

--- Is p inside the lot? Polygon zone if the lot has one, otherwise coords + radius.
function LotUtil.InLot(lot, p)
    if not HasZone(lot) then return #(p - lot.coords) < lot.radius end
    local z = lot.zone
    if p.z < z.minZ or p.z > z.maxZ then return false end
    local inside, pts = false, z.points
    local j = #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if (a.y > p.y) ~= (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Lot -> plain table (for JSON / state bags / callbacks)
function LotUtil.Encode(lot)
    local t = {
        name = lot.name, label = lot.label, pricePerHour = lot.pricePerHour or 0, maxFee = lot.maxFee or 0,
        blip = lot.blip ~= false,
        coords = lot.coords and { lot.coords.x, lot.coords.y, lot.coords.z }, radius = lot.radius,
        machine = lot.machine and { lot.machine.x, lot.machine.y, lot.machine.z, lot.machine.w },
        spots = {},
    }
    for i, s in ipairs(lot.spots or {}) do t.spots[i] = { s.x, s.y, s.z, s.w } end
    if HasZone(lot) then
        t.zone = { minZ = lot.zone.minZ, maxZ = lot.zone.maxZ, points = {} }
        for i, p in ipairs(lot.zone.points) do t.zone.points[i] = { p.x, p.y, p.z } end
    end
    return t
end

--- Plain table -> lot (validated). Returns lot | nil, error
function LotUtil.Decode(t)
    if type(t) ~= 'table' then return nil, 'Invalid lot.' end
    local name = type(t.name) == 'string' and t.name or ''
    if not name:match('^[%w_]+$') or #name < 2 or #name > 30 then return nil, 'Name must be 2-30 letters, numbers or _.' end
    local label = type(t.label) == 'string' and t.label:sub(1, 60) or ''
    if label == '' then return nil, 'Label is required.' end

    local lot = {
        name = name, label = label,
        pricePerHour = math.floor(math.max(0, math.min(100000, num(t.pricePerHour) or 0))),
        maxFee = math.floor(math.max(0, math.min(1000000, num(t.maxFee) or 0))),
        blip = t.blip ~= false, spots = {},
    }

    local function v3(a) local x, y, z = num(a and a[1]), num(a and a[2]), num(a and a[3]); return x and y and z and vec3(x, y, z) end
    local function v4(a) local p, w = v3(a), num(a and a[4]); return p and w and vec4(p.x, p.y, p.z, w % 360.0) end

    if type(t.spots) == 'table' then
        if #t.spots > 250 then return nil, 'Too many bays (max 250).' end
        for _, s in ipairs(t.spots) do
            local v = v4(s)
            if not v then return nil, 'Invalid bay.' end
            lot.spots[#lot.spots + 1] = v
        end
    end
    if t.machine then
        lot.machine = v4(t.machine)
        if not lot.machine then return nil, 'Invalid machine position.' end
    end
    if type(t.zone) == 'table' and type(t.zone.points) == 'table' and #t.zone.points >= 3 then
        if #t.zone.points > 50 then return nil, 'Too many zone points (max 50).' end
        local zone = { points = {}, minZ = num(t.zone.minZ), maxZ = num(t.zone.maxZ) }
        for _, p in ipairs(t.zone.points) do
            local v = v3(p)
            if not v then return nil, 'Invalid zone point.' end
            zone.points[#zone.points + 1] = v
        end
        if not zone.minZ or not zone.maxZ then return nil, 'Invalid zone height.' end
        lot.zone = zone
    else
        lot.coords = v3(t.coords)
        lot.radius = num(t.radius)
        if not lot.coords or not lot.radius then return nil, 'Draw a zone for this lot first.' end
    end
    return LotUtil.Finalize(lot)
end
