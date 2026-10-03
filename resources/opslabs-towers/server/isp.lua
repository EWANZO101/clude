-- Internet service on top of the cabling network: which ONTs have light (and how much), which
-- router each ONT's LAN feeds, and the ISP service provisioned on it.

local CI = Config.Isp
local Services = {}         -- [fixtureId] = row from opslabs_towers_isp
local OntStatus = {}        -- [fixtureId] = computed status (sent to clients)
local Since = {}            -- [fixtureId] = { lit = os.time() when light arrived, auth = when the service came up }
local GatewayOnline = {}    -- [towerId] = true when its LAN cable reaches a live ONT

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
            if r.kind == 'fibre' and r.start_fixture and r.end_fixture then
                link(r.start_fixture, r.end_fixture, r)
            elseif r.kind == 'cable' then
                local f, t = r.start_fixture or r.end_fixture, r.end_tower or r.start_tower
                if f and t and fixtures[f] and fixtures[f].model == CI.Ont then lanOf[f] = t end
            end
        end
    end
    -- light spreads out from every head-end; keep the best path (fewest joints, shortest fibre)
    local best, queue = {}, {}
    for id, f in pairs(fixtures) do
        if HEADEND[f.model] then best[id] = { joints = 0, metres = 0.0 } queue[#queue + 1] = id end
    end
    while #queue > 0 do
        local id = table.remove(queue, 1)
        local cur = best[id]
        local f = fixtures[id]
        -- light only passes on through joints (an ONT is the end of the line)
        if f and (HEADEND[f.model] or PASS[f.model]) then
            for _, e in ipairs(adj[id] or {}) do
                local nf = fixtures[e.to]
                if nf then
                    local cand = { joints = cur.joints + 1, metres = cur.metres + (e.run.length or 0) }
                    local old = best[e.to]
                    if not old or cand.joints < old.joints or (cand.joints == old.joints and cand.metres < old.metres) then
                        best[e.to] = cand
                        queue[#queue + 1] = e.to
                    end
                end
            end
        end
    end
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
            local live = path and svc and svc.status == 'active'
            if live then s.auth = s.auth or now else s.auth = nil end
            -- optical budget: launch +3 dBm, 0.35 dB/km, 0.1 dB per splice, 1:8 splitter at each CBT ≈ 10.5 dB
            local rx
            if path then rx = 3.0 - 0.35 * (path.metres / 1000) - 0.1 * path.joints - 10.5 * math.min(2, math.max(1, path.joints - 1)) - 4.0 end
            local p = svc and provider(svc.provider)
            local pl = svc and plan(p, svc.plan)
            local lan = lanOf[id]
            local lanTower = lan and Towers[lan]
            if live and lan then GatewayOnline[lan] = true end
            status[id] = {
                pon = path and 'on' or 'off',
                ponBlink = path and math.max(0, 20 - (now - s.lit)) or 0,
                los = not path,
                lan = lan and (live and 'traffic' or 'on') or 'off',
                lanName = lanTower and (lanTower.name or ('Router #' .. lan)) or nil,
                internet = live and 'on' or (svc and svc.status == 'suspended' and path and 'red') or 'off',
                authBlink = live and math.max(0, 12 - (now - s.auth)) or 0,
                rx = rx and math.floor(rx * 10 + 0.5) / 10 or nil,
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

lib.callback.register('opslabs-towers:isp:provision', function(src, fixtureId, providerId, planId, customer)
    if not canProvision(src) then return { error = 'Only network engineers can provision lines' } end
    local id = tonumber(fixtureId)
    local f = id and Cabling.fixtures[id]
    if not f or f.model ~= CI.Ont then return { error = 'That is not an ONT' } end
    local p = provider(providerId)
    if not p or not plan(p, planId) then return { error = 'Unknown provider or plan' } end
    customer = type(customer) == 'string' and customer:sub(1, 80) or nil
    local user = ('%s-%06d@%s'):format(p.id:sub(1, 4), math.random(0, 999999), p.id)
    local serial = serialFor(id)
    MySQL.query.await([[INSERT INTO opslabs_towers_isp (fixture_id, provider, plan, customer, username, serial, status, created_by)
        VALUES (?, ?, ?, ?, ?, ?, 'active', ?) ON DUPLICATE KEY UPDATE provider = VALUES(provider), plan = VALUES(plan),
        customer = VALUES(customer), username = VALUES(username), status = 'active']], { id, p.id, planId, customer, user, serial, GetPlayerName(src) })
    Services[id] = { fixture_id = id, provider = p.id, plan = planId, customer = customer, username = user, serial = serial, status = 'active' }
    Since[id] = Since[id] or {}
    Since[id].auth = nil
    CablingChanged()
    return { ok = true }
end)

lib.callback.register('opslabs-towers:isp:setStatus', function(src, fixtureId, status)
    if not canProvision(src) then return { error = 'Only network engineers can change lines' } end
    local id = tonumber(fixtureId)
    local svc = id and Services[id]
    if not svc then return { error = 'No service on this ONT' } end
    if status == 'cease' then
        Services[id] = nil
        MySQL.update.await('DELETE FROM opslabs_towers_isp WHERE fixture_id = ?', { id })
    elseif status == 'active' or status == 'suspended' then
        svc.status = status
        MySQL.update.await('UPDATE opslabs_towers_isp SET status = ? WHERE fixture_id = ?', { status, id })
    else
        return { error = 'bad status' }
    end
    CablingChanged()
    return { ok = true }
end)

exports('GetOntStatus', function(id) return OntStatus[tonumber(id)] end)
