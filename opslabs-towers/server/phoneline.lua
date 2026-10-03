-- Copper phone lines: a socket has dial tone when copper runs punched down at both ends join it, through
-- DPs, joints, junction boxes and cabinets, to an MDF in a powered exchange. The tool kit asks here.
local PL = Config.PhoneLine or {}

local function setOf(list) local s = {} for _, v in ipairs(list or {}) do s[v] = true end return s end
local EXCHANGE, PASS, SOCKET = setOf(PL.Exchange), setOf(PL.PassThrough), setOf(PL.Sockets)

local function equipLabel(model)
    for _, e in ipairs(Config.Cabling.Equipment or {}) do if e.model == model then return (e.label:gsub(' %(.*%)', '')) end end
    return model
end

local function lineNumber(id) return ('%s%04d'):format(PL.NumberPrefix or '01632 96', id % 10000) end

--- copper graph: fixture -> { { to, run } } over runs punched down at both ends with nothing hanging loose
local function graph()
    local adj = {}
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'copper' and r.start_term and r.end_term and r.start_fixture and r.end_fixture and not (r.loose and next(r.loose)) then
            adj[r.start_fixture] = adj[r.start_fixture] or {}
            adj[r.end_fixture] = adj[r.end_fixture] or {}
            table.insert(adj[r.start_fixture], { to = r.end_fixture, run = r })
            table.insert(adj[r.end_fixture], { to = r.start_fixture, run = r })
        end
    end
    return adj
end

--- trace a fixture back to the exchange (shortest copper path). Returns what the test kit shows.
function PhoneLineTrace(id)
    local fixtures = Cabling.fixtures
    local start = fixtures[id]
    if not start then return { error = 'not found' } end
    local adj = graph()
    local dist, prev, done = { [id] = 0.0 }, {}, {}
    local exchange, far, farD = nil, id, 0.0
    while true do
        local u, du
        for k, d in pairs(dist) do if not done[k] and (not du or d < du) then u, du = k, d end end
        if not u then break end
        done[u] = true
        if du > farD then far, farD = u, du end
        local f = fixtures[u]
        if f and EXCHANGE[f.model] and u ~= id then exchange = u break end
        if u == id or (f and (PASS[f.model] or SOCKET[f.model])) then
            for _, e in ipairs(adj[u] or {}) do
                local nd = du + (e.run.length or 0)
                if fixtures[e.to] and (not dist[e.to] or nd < dist[e.to]) then dist[e.to], prev[e.to] = nd, { from = u, run = e.run.id } end
            end
        end
    end
    local out = { id = id, label = equipLabel(start.model), number = lineNumber(id), runs = {}, hops = {} }
    if EXCHANGE[start.model] then
        out.exchange, out.metres = id, 0.0
    elseif exchange then
        out.exchange, out.metres = exchange, dist[exchange]
        local n = exchange
        while prev[n] do
            out.runs[#out.runs + 1] = prev[n].run
            if prev[n].from ~= id then table.insert(out.hops, 1, equipLabel(fixtures[prev[n].from].model)) end
            n = prev[n].from
        end
    end
    -- the cable this socket sits on, nearest first (for the tone tracer)
    out.direct = {}
    for _, e in ipairs(adj[id] or {}) do out.direct[#out.direct + 1] = e.run.id end
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'copper' and (r.start_fixture == id or r.end_fixture == id) then
            local dup = false
            for _, x in ipairs(out.direct) do if x == r.id then dup = true end end
            if not dup then out.direct[#out.direct + 1] = r.id end
        end
    end
    if out.exchange then
        local ex = fixtures[out.exchange]
        out.power = ExchangePower and ExchangePower(ex.x, ex.y) or {}
        out.dialtone = not PL.NeedsPower or #out.power > 0
        out.exchangeLabel = ('%s #%d'):format(equipLabel(ex.model), out.exchange)
        out.loop = math.floor(out.metres / 1000 * (PL.OhmsPerKm or 168) * 2 + 0.5) / 2
    else
        out.dialtone = false
        out.open = math.floor(farD + 0.5)                -- copper runs out this far from the socket
        out.openAt = far ~= id and equipLabel(fixtures[far].model) or nil
    end
    return out
end

lib.callback.register('opslabs-towers:phoneline:trace', function(src, id)
    id = tonumber(id)
    if not CanCable(src) then return { error = 'Only engineers can test lines' } end
    local f = Cabling.fixtures[id or -1]
    if not f then return { error = 'not found' } end
    if #(GetEntityCoords(GetPlayerPed(src)) - vector3(f.x, f.y, f.z)) > 30.0 then return { error = 'Too far away' } end
    return PhoneLineTrace(id)
end)

exports('PhoneLineTrace', function(id) return PhoneLineTrace(tonumber(id)) end)
