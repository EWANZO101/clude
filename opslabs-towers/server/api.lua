-- HTTP API for the OPS Mobile store's live tower map.
--   http://<server>:30120/opslabs-towers/api/...   (Authorization: Bearer <opslabs_phone_api_key>)
-- GET /towers · POST /towers · PATCH /towers/:id · DELETE /towers/:id · GET /live
-- GET /isp · POST /isp/:id/provision { provider, plan, customer } · POST /isp/:id/status { status = active|suspended|cease }
-- POST /poles/:id/status { status = auto|planned|building|maintenance }
-- GET /faults?status=active|all · POST /faults/:id/ack { actor } · /faults/:id/close { actor, note } · /faults/:id/note { actor, text }

local KEY = GetConvar('opslabs_towers_api_key', '') ~= '' and GetConvar('opslabs_towers_api_key', '') or GetConvar('opslabs_phone_api_key', '')
local numbers = {}  -- identifier -> phone number (cache)

local function authorized(req)
    if #KEY < 24 then return false end
    local h = req.headers or {}
    local given = (h['Authorization'] or h['authorization'] or ''):gsub('^Bearer%s+', '')
    if #given ~= #KEY then return false end
    local diff = 0
    for i = 1, #KEY do if given:byte(i) ~= KEY:byte(i) then diff = diff + 1 end end
    return diff == 0
end

local function reply(res, status, body)
    res.writeHead(status, { ['Content-Type'] = 'application/json', ['Cache-Control'] = 'no-store' })
    res.send(json.encode(body))
end

local function list()
    local out = {}
    for _, t in pairs(Towers) do out[#out + 1] = t end  -- includes the Wi-Fi password (admin website only)
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function numberFor(identifier)
    if numbers[identifier] == nil then
        local ok, n = pcall(MySQL.scalar.await, 'SELECT phone_number FROM opslabs_phone_users WHERE identifier = ?', { identifier })
        numbers[identifier] = ok and n or false
    end
    return numbers[identifier] or nil
end

local function live()
    local players = {}
    local withSignal, onWifi = 0, 0
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            local cov = ComputeCoverage(c, src)
            local p = FW.Player(src)
            if cov.cell > 0 then withSignal = withSignal + 1 end
            if cov.wifi then onWifi = onWifi + 1 end
            players[#players + 1] = {
                id = src, name = p and p.name or GetPlayerName(src),
                number = p and numberFor(p.identifier) or nil,
                x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped),
                vehicle = GetVehiclePedIsIn(ped, false) ~= 0,
                cell = cov.cell, net = cov.net, tower = cov.tower, wifi = cov.wifi and cov.wifi.ssid or nil,
            }
        end
    end
    return { towers = list(), players = players, enforce = Config.Enforce, time = os.time(),
        props = { cell = Config.Cell.Props or {}, wifi = Config.Wifi.Props or {} },
        stats = { players = #players, with_signal = withSignal, on_wifi = onWifi } }
end

SetHttpHandler(function(req, res)
    local query = (req.path or ''):match('%?(.*)$') or ''
    local path = (req.path or ''):gsub('%?.*$', '')
    local function handle(body)
        if not authorized(req) then return reply(res, 401, { error = 'Unauthorized' }) end
        local data = {}
        if body and body ~= '' then
            local ok, d = pcall(json.decode, body)
            if not ok or type(d) ~= 'table' then return reply(res, 400, { error = 'Invalid JSON' }) end
            data = d
        end
        if path == '/api/live' and req.method == 'GET' then return reply(res, 200, { data = live() }) end
        if path == '/api/towers' and req.method == 'GET' then return reply(res, 200, { data = list() }) end
        if path == '/api/towers' and req.method == 'POST' then
            local t, err = SaveTower(nil, data, data.actor or 'website')
            if not t then return reply(res, 400, { error = err }) end
            return reply(res, 200, { data = t })
        end
        -- bulk: { action = 'delete'|'offline'|'online', ids = {..} } or { action, all = true, type, offline }
        if path == '/api/towers/bulk' and req.method == 'POST' then
            local n
            if data.action == 'delete' then n = DeleteTowers(data)
            elseif data.action == 'offline' then n = SetTowersActive(data, false)
            elseif data.action == 'online' then n = SetTowersActive(data, true)
            else return reply(res, 400, { error = 'action must be delete, offline or online' }) end
            return reply(res, 200, { data = { ok = true, count = n } })
        end
        -- network faults
        if path == '/api/faults' and req.method == 'GET' then
            local r = GetFaults({ status = query:match('status=(%a+)') == 'all' and 'all' or 'active' })
            r.settings = GetFaultSettings()
            return reply(res, 200, { data = r })
        end
        local faultId, faultAction = path:match('^/api/faults/(%d+)/(%a+)$')
        if faultId and req.method == 'POST' then
            local actor = type(data.actor) == 'string' and data.actor:sub(1, 60) or 'website'
            local ok, err
            if faultAction == 'ack' then ok, err = AckFault(faultId, actor)
            elseif faultAction == 'close' then ok, err = CloseFault(faultId, actor, type(data.note) == 'string' and data.note:sub(1, 500) or nil)
            elseif faultAction == 'note' then ok, err = AddFaultNote(faultId, actor, data.text)
            else return reply(res, 404, { error = 'Not found' }) end
            if not ok then return reply(res, 400, { error = err }) end
            return reply(res, 200, { data = { ok = true } })
        end
        -- internet service (fibre broadband on ONTs)
        if path == '/api/isp' and req.method == 'GET' then return reply(res, 200, { data = IspList() }) end
        local poleId = tonumber(path:match('^/api/poles/(%d+)/status$'))
        if poleId and req.method == 'POST' then
            local ok, err = IspSetPoleStatus(poleId, data.status)
            if not ok then return reply(res, 400, { error = err }) end
            return reply(res, 200, { data = { ok = true } })
        end
        local ontId, action = path:match('^/api/isp/(%d+)/(%a+)$')
        if ontId and req.method == 'POST' then
            local ok, err
            if action == 'provision' then ok, err = IspProvision(ontId, data.provider, data.plan, data.customer, data.actor or 'website')
            elseif action == 'status' then ok, err = IspSetStatus(ontId, data.status)
            else return reply(res, 404, { error = 'Not found' }) end
            if not ok then return reply(res, 400, { error = err }) end
            return reply(res, 200, { data = { ok = true } })
        end
        local id = tonumber(path:match('^/api/towers/(%d+)$'))
        if id then
            if not Towers[id] then return reply(res, 404, { error = 'Tower not found' }) end
            if req.method == 'PATCH' then
                -- a real move on the map is 2D: the prop drops to the ground there.
                -- Saving other fields (same x/y) keeps an aim-placed prop where it is.
                local cur = Towers[id]
                local moved = (data.x and math.abs(tonumber(data.x) - cur.x) > 0.05) or (data.y and math.abs(tonumber(data.y) - cur.y) > 0.05)
                if moved and data.exact == nil then data.exact = false end
                if not moved then data.z = nil end
                local t, err = SaveTower(id, data)
                if not t then return reply(res, 400, { error = err }) end
                return reply(res, 200, { data = t })
            elseif req.method == 'DELETE' then
                DeleteTower(id)
                return reply(res, 200, { data = { ok = true } })
            end
        end
        return reply(res, 404, { error = 'Not found' })
    end
    if req.method == 'GET' or req.method == 'DELETE' then
        CreateThread(function() handle(nil) end)
    else
        req.setDataHandler(function(body) CreateThread(function() handle(body) end) end)
    end
end)

CreateThread(function()
    Wait(2000)
    if #KEY < 24 then print('^3[opslabs-towers] API disabled: set opslabs_phone_api_key (or opslabs_towers_api_key) in server.cfg^7')
    else print(('^2[opslabs-towers]^7 API ready at /%s/api'):format(GetCurrentResourceName())) end
end)
