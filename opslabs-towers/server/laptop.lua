-- Laptops (opslabs_laptop): placed like any equipment, online over Ethernet OR Wi-Fi.
-- Ethernet: a CAT6 run terminated at both ends from the laptop's port to
--   · a router / switch / AP that has an uplink (cabled through to a gateway) → internet, or
--   · straight into an ONT's LAN port with an active service (PPPoE) → internet.
-- Wi-Fi (no cable needed): the nearest Wi-Fi access point in range (same range/floor-tolerance rule as a
-- phone's signal, server/main.lua ComputeCoverage) that's powered, not faulted, has an uplink, and isn't
-- password-protected — a shared desk laptop can't "know" a password the way a player's phone can, so it only
-- ever joins an open network, same as it never needed a password to use a wired connection either.
-- opslabs-phone asks GetLaptopNet(fixtureId) when someone uses a laptop and on every
-- online action, so unplugging/cutting the cable or losing Wi-Fi range takes it offline straight away.

local CL = Config.Laptop or {}
local LAPTOP = {}
for _, m in ipairs(CL.Models or { 'opslabs_laptop' }) do LAPTOP[m] = true end
local ONT = Config.Isp and Config.Isp.Ont or 'opslabs_ont'

function IsLaptopModel(model) return LAPTOP[model] == true end

local function isGateway(t)
    if not t or t.type ~= 'wifi' or not t.prop then return false end
    for _, m in ipairs(Config.Cabling.Gateways or {}) do if t.model == m then return true end end
    return false
end

--- the best open, in-range, uplinked Wi-Fi access point for a laptop sitting at (x, y, z) — same range and
--- floor-tolerance rule server/main.lua's ComputeCoverage uses for a player's phone signal, minus the
--- job-lock/password checks (those are about a specific player's phone, not a shared desk laptop)
local function wifiFor(f)
    local WF = Config.Wifi or {}
    local best, bestS
    for _, t in pairs(Towers) do
        if t.type == 'wifi' and t.active and not t.password and not (FaultEffects and FaultEffects.towers[t.id])
            and not (TowerPowered and not TowerPowered(t.id)) and not (t.fibre_only and not WifiOnFibre(t.id)) then
            local dx, dy = f.x - t.x, f.y - t.y
            local d2 = math.sqrt(dx * dx + dy * dy)
            if d2 <= (t.range or WF.DefaultRange or 40) and math.abs(f.z - t.z) <= (WF.FloorTolerance or 14) and WifiHasUplink(t.id) then
                local s = 1 - d2 / (t.range or WF.DefaultRange or 40)
                if not best or s > bestS then best, bestS = t, s end
            end
        end
    end
    return best
end

--- terminated CAT6 links: tower <-> tower adjacency, plus which tower each ONT's LAN feeds
local function lanGraph()
    local adj, ontOf = {}, {}
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and r.start_term and r.end_term then
            if r.start_tower and r.end_tower then
                adj[r.start_tower] = adj[r.start_tower] or {}
                adj[r.end_tower] = adj[r.end_tower] or {}
                table.insert(adj[r.start_tower], r.end_tower)
                table.insert(adj[r.end_tower], r.start_tower)
            else
                local f, t = r.start_fixture or r.end_fixture, r.end_tower or r.start_tower
                if f and t and Cabling.fixtures[f] and Cabling.fixtures[f].model == ONT then ontOf[t] = f end
            end
        end
    end
    return adj, ontOf
end

local function ontService(ontId)
    local s = ontId and IspPayload and IspPayload()[ontId]
    if not s then return nil end
    return { provider = s.provider, providerColor = s.providerColor, plan = s.plan, down = s.down, up = s.up, live = s.internet == 'on' }
end

--- fill `out` from a router/AP tower the laptop reaches — wired to it, or (via.kind == 'wifi') just in its range.
--- Shared by both paths in LaptopNet below since "is this tower itself usable" is identical either way.
local function fromTower(out, id, t, via)
    if not t then out.reason = 'no_device' return out end
    out.link = t.active and not (FaultEffects and FaultEffects.towers[t.id]) or false
    out.via = via
    if not out.link then out.reason = 'router_off' return out end
    out.speed = 1000
    out.ip = ('192.168.%d.%d'):format(t.id % 250, 100 + id % 150)
    out.router_ip = ('192.168.%d.1'):format(t.id % 250)
    if Uplinked[t.id] ~= true then out.reason = 'no_uplink' return out end
    out.internet = true
    local adj, ontOf = lanGraph()
    local seen, queue = { [t.id] = true }, { t.id }
    while #queue > 0 do
        local cur = table.remove(queue, 1)
        local ct = Towers[cur]
        if isGateway(ct) then
            out.gateway = ct.name or ('Gateway #' .. cur)
            out.isp = ontService(ontOf[cur])
            break
        end
        for _, nb in ipairs(adj[cur] or {}) do
            if not seen[nb] then seen[nb] = true; queue[#queue + 1] = nb end
        end
    end
    return out
end

local function mac(id)
    local n = (id * 2654435761) % 0xFFFFFF
    return ('3C:A6:2F:%02X:%02X:%02X'):format((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

--- { link, internet, via = { kind = 'router'|'ont', name }, gateway, isp, ip, router_ip, mac, speed, reason }
function LaptopNet(id)
    id = tonumber(id)
    local f = id and Cabling.fixtures[id]
    if not f or not LAPTOP[f.model] then return nil end
    local out = { id = id, mac = mac(id), x = f.x, y = f.y, z = f.z, link = false, internet = false }
    -- battery (server/mains.lua): a flat laptop with no charger beside it won't start
    local pw = MainsLaptop and MainsLaptop(id)
    out.power = pw and { level = pw.level, charging = pw.charging, plugged = pw.plugged } or nil
    out.dead = pw and pw.dead or nil
    -- the cable in the laptop's Ethernet port
    local run, other
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and (r.start_fixture == id or r.end_fixture == id) then
            run = r
            local mine = r.start_fixture == id and 'start' or 'end'
            local far = mine == 'start' and 'end' or 'start'
            if not (r.start_term and r.end_term) then other = nil
            else other = { tower = r[far .. '_tower'], fixture = r[far .. '_fixture'] } end
            if other and (other.tower or other.fixture) then break end
        end
    end
    if not run or not other or not (other.tower or other.fixture) then
        -- no usable wired connection: an open, in-range, uplinked Wi-Fi access point does just as well
        local wt = wifiFor(f)
        if wt then return fromTower(out, id, wt, { kind = 'wifi', name = wt.ssid or wt.name or ('Wi-Fi #' .. wt.id) }) end
        out.reason = not run and 'unplugged' or 'not_terminated'
        return out
    end

    if other.fixture then
        local of = Cabling.fixtures[other.fixture]
        if not of or of.model ~= ONT then out.reason = 'no_device' return out end
        out.link, out.via = true, { kind = 'ont', name = 'ONT #' .. other.fixture }
        local svc = ontService(other.fixture)
        out.isp = svc
        out.internet = svc ~= nil and svc.live == true
        if out.internet then
            out.ip = ('100.%d.%d.%d'):format(64 + id % 60, (id * 7) % 250 + 1, (id * 13) % 250 + 2)
            out.router_ip = '100.64.0.1'
            out.speed = 1000
        else
            out.reason = svc and 'no_service' or 'ont_dark'
        end
        return out
    end

    local t = Towers[other.tower]
    return fromTower(out, id, t, t and { kind = 'router', name = t.name or ('Router #' .. t.id) } or nil)
end

exports('GetLaptopNet', LaptopNet)
lib.callback.register('opslabs-towers:laptop:net', function(_, id) return LaptopNet(id) end)
