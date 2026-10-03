-- Internet service on top of the cabling network: which ONTs have light (and how much), which
-- router each ONT's LAN feeds, and the ISP service provisioned on it.

local CI = Config.Isp
local Services = {}         -- [fixtureId] = row from opslabs_towers_isp
local OntStatus = {}        -- [fixtureId] = computed status (sent to clients)
local Since = {}            -- [fixtureId] = { lit = os.time() when light arrived, auth = when the service came up }
local GatewayOnline = {}    -- [towerId] = true when its LAN cable reaches a live ONT
LitFixtures = {}            -- [fixtureId] = true when light reaches it (cabinets, joints, CBTs, CSPs, ONTs)

local function setOf(list) local s = {} for _, v in ipairs(list or {}) do s[v] = true end return s end
local HEADEND, PASS = setOf(CI.Headends), setOf(CI.PassThrough)

local function provider(id) for _, p in ipairs(CI.Providers) do if p.id == id then return p end end end
local function plan(p, id) for _, x in ipairs(p and p.plans or {}) do if x.id == id then return x end end end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_isp` (
        `fixture_id` INT NOT NULL,
        `provider` VARCHAR(32) NOT NULL,
        `plan` VARCHAR(32) NOT NULL,
        `customer` VARCHAR(80) DEFAULT NULL,
        `username` VARCHAR(80) NOT NULL,
        `serial` VARCHAR(24) NOT NULL,
        `status` VARCHAR(12) NOT NULL DEFAULT 'active',
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`fixture_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_isp') or {}) do Services[r.fixture_id] = r end
    if CablingChanged then CablingChanged() end
end)

local function serialFor(id) return ('OPSN%08X'):format((id * 40503 + 0x1A2B3C) % 0x7FFFFFFF) end

--- recompute light, LAN links and status for every ONT (called whenever the cabling changes)
--- which OLTs have backhaul: patched on a core router whose uplink is up and that has power
--- (a rectifier, battery bank or generator) in the same exchange
local POWER_PLANT = { opslabs_rectifier = 'rectifier', opslabs_battery_bank = 'batteries', opslabs_generator = 'generator', opslabs_dc_power = 'DC power plant' }
function ExchangePower(x, y)
    local found = {}
    for _, f in pairs(Cabling.fixtures) do
        if POWER_PLANT[f.model] and math.sqrt((f.x - x) ^ 2 + (f.y - y) ^ 2) <= (CI.ExchangeRadius or 60) then found[#found + 1] = POWER_PLANT[f.model] end
    end
    return found
end
function OltBackhaul()
    local ok = {}
    for _, r in pairs(Cabling.fixtures) do
        if r.model == 'opslabs_core_router' and r.data and r.data.uplink and #ExchangePower(r.x, r.y) > 0 then
            for _, oid in ipairs(r.data.patched or {}) do
                local o = Cabling.fixtures[oid]
                if o and o.model == 'opslabs_olt' and math.sqrt((o.x - r.x) ^ 2 + (o.y - r.y) ^ 2) <= (CI.ExchangeRadius or 60) then ok[oid] = r.id end
            end
        end
    end
    return ok
end

lib.callback.register('opslabs-towers:exchange:status', function(src, routerId)
    local r = Cabling.fixtures[tonumber(routerId)]
    if not r then return nil end
    local olts = {}
    for id, f in pairs(Cabling.fixtures) do
        if f.model == 'opslabs_olt' and math.sqrt((f.x - r.x) ^ 2 + (f.y - r.y) ^ 2) <= (CI.ExchangeRadius or 60) then
            olts[#olts + 1] = { id = id, lit = LitFixtures[id] == true, backhaul = (Backhaul or {})[id] }
        end
    end
    table.sort(olts, function(a, b) return a.id < b.id end)
    return { power = ExchangePower(r.x, r.y), olts = olts }
end)

function RecomputeIsp()
    local fixtures, runs = Cabling.fixtures, Cabling.runs
    -- fibre graph between equipment: only runs spliced at both ends count
    local adj = {}
    local function link(a, b, run)
        adj[a] = adj[a] or {}
        adj[b] = adj[b] or {}
        table.insert(adj[a], { to = b, run = run })
        table.insert(adj[b], { to = a, run = run })
    end
    local lanOf = {}            -- ont fixture id -> tower id on the other end of a CAT6 run
    for _, r in pairs(runs) do
        if r.start_term and r.end_term then
            if r.kind == 'fibre' and r.start_fixture and r.end_fixture and not (FaultEffects and FaultEffects.runs[r.id]) then
                link(r.start_fixture, r.end_fixture, r)
            elseif r.kind == 'cable' then
                local f, t = r.start_fixture or r.end_fixture, r.end_tower or r.start_tower
                if f and t and fixtures[f] and fixtures[f].model == CI.Ont then lanOf[f] = t end
            end
        end
    end
    -- light spreads out from every head-end; keep the best path (fewest joints, shortest fibre)
    local best, queue = {}, {}
    local FE = FaultEffects or { fixtures = {}, loss = {} }
    Backhaul = OltBackhaul()
    for id, f in pairs(fixtures) do
        if HEADEND[f.model] and FE.fixtures[id] ~= 'dead' and (f.model ~= 'opslabs_olt' or not CI.OltNeedsBackhaul or Backhaul[id]) then
            best[id] = { joints = 0, metres = 0.0, loss = 0.0 } queue[#queue + 1] = id
        end
    end
    while #queue > 0 do
        local id = table.remove(queue, 1)
        local cur = best[id]
        local f = fixtures[id]
        -- light only passes on through joints (an ONT is the end of the line)
        if f and (HEADEND[f.model] or PASS[f.model]) and not FE.fixtures[id] then
            for _, e in ipairs(adj[id] or {}) do
                local nf = fixtures[e.to]
                if nf and (FE.fixtures[e.to] ~= 'dead' or nf.model == CI.Ont) then
                    local cand = { joints = cur.joints + 1, metres = cur.metres + (e.run.length or 0), loss = cur.loss + (FE.loss[e.to] or 0) }
                    local old = best[e.to]
                    if not old or cand.joints < old.joints or (cand.joints == old.joints and cand.metres < old.metres) then
                        best[e.to] = cand
                        queue[#queue + 1] = e.to
                    end
                end
            end
        end
    end
    LitFixtures = {}
    for fid in pairs(best) do LitFixtures[fid] = true end
    local now = os.time()
    local status = {}
    GatewayOnline = {}
    for id, f in pairs(fixtures) do
        if f.model == CI.Ont then
            local path = best[id]
            local svc = Services[id]
            Since[id] = Since[id] or {}
            local s = Since[id]
            if path then s.lit = s.lit or now else s.lit = nil end
            local dead = FE.fixtures[id] == 'dead'                   -- ONT hardware fault
            local rx
            if path then rx = 3.0 - 0.35 * (path.metres / 1000) - 0.1 * path.joints - 10.5 * math.min(2, math.max(1, path.joints - 1)) - 4.0 - (path.loss or 0) end
            local lowLight = rx and rx < -28.0                        -- below the ONT's sensitivity: drops out
            if dead or lowLight then path = nil end
            local live = path and svc and svc.status == 'active'
            if live then s.auth = s.auth or now else s.auth = nil end
            -- optical budget (above): launch +3 dBm, 0.35 dB/km, 0.1 dB per splice, 1:8 splitter at each CBT ≈ 10.5 dB, + fault loss
            local p = svc and provider(svc.provider)
            local pl = svc and plan(p, svc.plan)
            local lan = lanOf[id]
            local lanTower = lan and Towers[lan]
            if live and lan then GatewayOnline[lan] = true end
            status[id] = {
                hardware = dead and 'failed' or nil, lowLight = lowLight or nil,
                pon = dead and 'off' or path and 'on' or 'off',
                ponBlink = path and math.max(0, 20 - (now - s.lit)) or 0,
                los = not path,
                lan = lan and (live and 'traffic' or 'on') or 'off',
                lanName = lanTower and (lanTower.name or ('Router #' .. lan)) or nil,
                internet = live and 'on' or (svc and svc.status == 'suspended' and path and 'red') or 'off',
                authBlink = live and math.max(0, 12 - (now - s.auth)) or 0,
                rx = (not dead and rx) and math.floor(rx * 10 + 0.5) / 10 or nil,
                distance = path and math.floor(path.metres + 0.5) or nil,
                joints = path and path.joints or nil,
                serial = svc and svc.serial or serialFor(id),
                provider = p and p.name or nil, providerColor = p and p.color or nil,
                plan = pl and pl.name or nil, down = pl and pl.down or nil, up = pl and pl.up or nil,
                customer = svc and svc.customer or nil, username = svc and svc.username or nil,
                service = svc and svc.status or 'none',
                uptime = live and (now - s.auth) or 0,
            }
        end
    end
    OntStatus = status
    TriggerClientEvent('opslabs-towers:ont', -1, OntStatus)
end

function IspPayload() return OntStatus end

function IspGatewayOnline(towerId)
    if not CI.RequireIspForGateways then return true end
    return GatewayOnline[towerId] == true
end

--- is this gateway's WAN cabled to an ONT with internet right now (whatever RequireIspForGateways says)
function IspGatewayLive(towerId) return GatewayOnline[towerId] == true end

function IspFixtureRemoved(id)
    if Services[id] then
        Services[id] = nil
        MySQL.update.await('DELETE FROM opslabs_towers_isp WHERE fixture_id = ?', { id })
    end
    Since[id] = nil
end

-- players joining get the current lights (blink timers are counted down on the client)
RegisterNetEvent('opslabs-towers:ready', function() TriggerClientEvent('opslabs-towers:ont', source, OntStatus) end)

---------------------------------------------------------------------------
-- provisioning (engineers / admins)
---------------------------------------------------------------------------

local function canProvision(src)
    if IsTowerAdmin(src) then return true end
    local xPlayer = ESX.GetPlayerFromId(src)
    local job = xPlayer and xPlayer.getJob() and xPlayer.getJob().name
    for _, j in ipairs(Config.Cabling.Jobs or {}) do if j == job then return true end end
    return false
end

--- provision (or change) the service on an ONT. Shared by the in-game menu and the website API.
function IspProvision(fixtureId, providerId, planId, customer, actor)
    local id = tonumber(fixtureId)
    local f = id and Cabling.fixtures[id]
    if not f or f.model ~= CI.Ont then return nil, 'That is not an ONT' end
    local p = provider(providerId)
    if not p or not plan(p, planId) then return nil, 'Unknown provider or plan' end
    customer = type(customer) == 'string' and customer ~= '' and customer:sub(1, 80) or nil
    local user = ('%s-%06d@%s'):format(p.id:sub(1, 4), math.random(0, 999999), p.id)
    local serial = serialFor(id)
    MySQL.query.await([[INSERT INTO opslabs_towers_isp (fixture_id, provider, plan, customer, username, serial, status, created_by)
        VALUES (?, ?, ?, ?, ?, ?, 'active', ?) ON DUPLICATE KEY UPDATE provider = VALUES(provider), plan = VALUES(plan),
        customer = VALUES(customer), username = VALUES(username), status = 'active']], { id, p.id, planId, customer, user, serial, actor })
    Services[id] = { fixture_id = id, provider = p.id, plan = planId, customer = customer, username = user, serial = serial, status = 'active' }
    Since[id] = Since[id] or {}
    Since[id].auth = nil
    CablingChanged()
    return true
end

--- 'active' | 'suspended' | 'cease'
function IspSetStatus(fixtureId, status)
    local id = tonumber(fixtureId)
    local svc = id and Services[id]
    if not svc then return nil, 'No service on this ONT' end
    if status == 'cease' then
        Services[id] = nil
        MySQL.update.await('DELETE FROM opslabs_towers_isp WHERE fixture_id = ?', { id })
    elseif status == 'active' or status == 'suspended' then
        svc.status = status
        MySQL.update.await('UPDATE opslabs_towers_isp SET status = ? WHERE fixture_id = ?', { status, id })
    else
        return nil, 'bad status'
    end
    CablingChanged()
    return true
end

--- every ONT with its position, lights and service (for the website)
function IspList()
    local out, live, none, down = {}, 0, 0, 0
    for id, f in pairs(Cabling.fixtures) do
        if f.model == CI.Ont then
            local st = OntStatus[id] or {}
            local row = { id = id, x = f.x, y = f.y, z = f.z, created_by = f.created_by }
            for k, v in pairs(st) do row[k] = v end
            row.provider_id = Services[id] and Services[id].provider or nil
            row.plan_id = Services[id] and Services[id].plan or nil
            if OntAddress then for k, v in pairs(OntAddress(id, row.provider_id)) do row[k] = v end end
            row.fault = FaultOnOnt and FaultOnOnt(id) or nil
            out[#out + 1] = row
            if st.service == 'active' and not st.los then live = live + 1 elseif st.service == 'none' or not st.service then none = none + 1 end
            if st.los then down = down + 1 end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    local poles, links, kit = IspPoles()
    for _, p in ipairs(poles) do p.faults = FaultsOnPole and FaultsOnPole(p.id) or {} end
    return { onts = out, poles = poles, links = links, kit = kit, providers = CI.Providers,
        faults = GetFaults and GetFaults().faults or {},
        stats = { total = #out, live = live, no_service = none, los = down } }
end

local POLE_H = { opslabs_house_pole = 1.63 }
for m, h in pairs(Config.Cabling.PoleHeights) do POLE_H[m] = h end
local POLE_STATUS = { planned = true, building = true, maintenance = true }

local function equipLabel(model)
    for _, e in ipairs(Config.Cabling.Equipment or {}) do if e.model == model then return (e.label:gsub(' %(.*%)', '')) end end
    return model
end

--- poles for the website map: position, height, kit on it, cables clamped to it, light and status
function IspPoles()
    local fixtures, runs = Cabling.fixtures, Cabling.runs
    local poles = {}
    for id, f in pairs(fixtures) do
        local H = POLE_H[f.model]
        if H then
            local ax, ay = f.x, f.y
            if f.model == 'opslabs_house_pole' then
                local h = math.rad(f.heading or 0.0)
                ax, ay = f.x + 0.12 * math.sin(h), f.y - 0.12 * math.cos(h)
            end
            local p = { id = id, model = f.model, label = equipLabel(f.model), x = ax, y = ay, z = f.z, height = H, created_by = f.created_by,
                house = f.model == 'opslabs_house_pole', equipment = {}, cables = 0, fibres = 0, lit = false,
                manual = f.data and f.data.status or nil }
            for kid, k in pairs(fixtures) do
                if kid ~= id and not POLE_H[k.model] and math.sqrt((k.x - ax) ^ 2 + (k.y - ay) ^ 2) < 0.5 and k.z >= f.z - 0.5 and k.z <= f.z + H + 0.5 then
                    local lit = LitFixtures[kid] == true
                    p.equipment[#p.equipment + 1] = { id = kid, model = k.model, label = equipLabel(k.model), height = math.floor((k.z - f.z) * 10 + 0.5) / 10, lit = lit }
                    if lit then p.lit = true end
                end
            end
            table.sort(p.equipment, function(a, b) return a.height > b.height end)
            for _, r in pairs(runs) do
                if r.kind == 'cable' or r.kind == 'fibre' then
                    for _, pt in ipairs(r.points or {}) do
                        if pt.p == id or math.sqrt((pt.x - ax) ^ 2 + (pt.y - ay) ^ 2) < 0.4 then
                            if r.kind == 'fibre' then p.fibres = p.fibres + 1 else p.cables = p.cables + 1 end
                            break
                        end
                    end
                end
            end
            p.status = p.manual or (p.lit and 'live') or ((#p.equipment > 0 or p.cables + p.fibres > 0) and 'building') or 'planned'
            poles[#poles + 1] = p
        end
    end
    table.sort(poles, function(a, b) return a.id < b.id end)
    -- cable / fibre routes for drawing (thinned to at most ~24 points each)
    local links = {}
    for _, r in pairs(runs) do
        if r.kind ~= 'trunk' and #(r.points or {}) >= 2 then
            local pts, n = {}, #r.points
            local step = math.max(1, math.floor(n / 24))
            for i = 1, n, step do pts[#pts + 1] = { math.floor(r.points[i].x * 10) / 10, math.floor(r.points[i].y * 10) / 10 } end
            if (n - 1) % step ~= 0 then pts[#pts + 1] = { math.floor(r.points[n].x * 10) / 10, math.floor(r.points[n].y * 10) / 10 } end
            local lit = r.kind == 'fibre' and r.start_term and r.end_term and ((r.start_fixture and LitFixtures[r.start_fixture]) or (r.end_fixture and LitFixtures[r.end_fixture])) or false
            links[#links + 1] = { id = r.id, kind = r.kind, color = r.color, pts = pts, length = math.floor((r.length or 0) + 0.5), lit = lit and true or false }
        end
    end
    -- other network kit for context (cabinets, joints, CBTs, CSPs) — ONTs come in their own list
    local kit = {}
    for id, k in pairs(fixtures) do
        if (HEADEND[k.model] or PASS[k.model]) then
            kit[#kit + 1] = { id = id, model = k.model, label = equipLabel(k.model), x = k.x, y = k.y, lit = LitFixtures[id] == true, headend = HEADEND[k.model] == true }
        end
    end
    return poles, links, kit
end

--- 'auto' (worked out from the network) | 'planned' | 'building' | 'maintenance'
function IspSetPoleStatus(poleId, status)
    local id = tonumber(poleId)
    local f = id and Cabling.fixtures[id]
    if not f or not POLE_H[f.model] then return nil, 'That is not a pole' end
    if status ~= 'auto' and not POLE_STATUS[status] then return nil, 'Status must be auto, planned, building or maintenance' end
    f.data = f.data or {}
    f.data.status = status ~= 'auto' and status or nil
    if not next(f.data) then f.data = nil end
    MySQL.update.await('UPDATE opslabs_towers_fixtures SET data = ? WHERE id = ?', { f.data and json.encode(f.data) or nil, id })
    CablingChanged()
    return true
end

lib.callback.register('opslabs-towers:isp:provision', function(src, fixtureId, providerId, planId, customer)
    if not canProvision(src) then return { error = 'Only network engineers can provision lines' } end
    local ok, err = IspProvision(fixtureId, providerId, planId, customer, GetPlayerName(src))
    return ok and { ok = true } or { error = err }
end)

lib.callback.register('opslabs-towers:isp:setStatus', function(src, fixtureId, status)
    if not canProvision(src) then return { error = 'Only network engineers can change lines' } end
    local ok, err = IspSetStatus(fixtureId, status)
    return ok and { ok = true } or { error = err }
end)

lib.callback.register('opslabs-towers:pole:status', function(src, poleId, status)
    if not canProvision(src) then return { error = 'Only network engineers can change pole status' } end
    local ok, err = IspSetPoleStatus(poleId, status)
    return ok and { ok = true } or { error = err }
end)

exports('GetOntStatus', function(id) return OntStatus[tonumber(id)] end)
exports('GetIspList', function() return IspList() end)
function IspServiceProvider(id) return Services[id] and Services[id].provider or nil end
