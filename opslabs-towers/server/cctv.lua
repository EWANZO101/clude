-- OPS Secure CCTV (Config.Cctv). Works out from the real kit and cabling which cameras are live on which recorder,
-- records what they see (motion, ANPR plate reads, doorbell rings), breaks now and then (OPS Secure fault jobs),
-- and lets the right people watch: at a monitor / video wall wired to the system, or remotely on the phone when the
-- NVR is on the internet and remote viewing is on.
--   A system = a recorder (NVR / DVR) fixture. Owner: a player (identifier), shared viewers, and/or an organisation
--   job (e.g. police) whose members can watch it. Staff (cabling engineers / admins) can configure any system.

local CV = Config.Cctv or {}
if not CV.Enabled then return end
local CAM, REC, VIEW, POESW = CV.Cameras or {}, CV.Recorders or {}, CV.Viewers or {}, CV.PoESwitches or {}

Cctv = { systems = {}, cams = {}, state = { cams = {}, recs = {} } }
local S = Cctv
local dirty = true
function CctvDirty() dirty = true end

local function now() return os.time() end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end

---------------------------------------------------------------------------
-- persistence
---------------------------------------------------------------------------
MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_cctv_systems (
        recorder_id INT NOT NULL PRIMARY KEY, name VARCHAR(60) NULL, owner_identifier VARCHAR(60) NULL, owner_name VARCHAR(80) NULL,
        org_job VARCHAR(40) NULL, shared TEXT NULL, remote TINYINT(1) NOT NULL DEFAULT 0, mode VARCHAR(12) NOT NULL DEFAULT 'motion',
        retention INT NOT NULL DEFAULT 7, hdd_fault TINYINT(1) NOT NULL DEFAULT 0, configured TINYINT(1) NOT NULL DEFAULT 0, created_at INT NOT NULL DEFAULT 0)]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_cctv_cams (
        fixture_id INT NOT NULL PRIMARY KEY, name VARCHAR(40) NULL, fault VARCHAR(12) NULL, fault_at INT NULL)]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS opslabs_towers_cctv_events (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, recorder_id INT NOT NULL, camera_id INT NULL, kind VARCHAR(12) NOT NULL,
        detail VARCHAR(160) NULL, x FLOAT NULL, y FLOAT NULL, at INT NOT NULL, KEY rec_at (recorder_id, at), KEY kind_at (kind, at))]])
    for _, r in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_cctv_systems') or {}) do r.shared = decode(r.shared, {}) S.systems[r.recorder_id] = r end
    for _, c in ipairs(MySQL.query.await('SELECT * FROM opslabs_towers_cctv_cams') or {}) do S.cams[c.fixture_id] = c end
    dirty = true
end)

local function system(id)
    id = tonumber(id)
    local s = S.systems[id]
    if not s then
        s = { recorder_id = id, name = nil, shared = {}, remote = 0, mode = 'motion', retention = CV.RetentionDays or 7, hdd_fault = 0, configured = 0, created_at = now() }
        S.systems[id] = s
        MySQL.insert('INSERT IGNORE INTO opslabs_towers_cctv_systems (recorder_id, created_at) VALUES (?, ?)', { id, now() })
    end
    return s
end
local function saveSystem(s)
    MySQL.update('UPDATE opslabs_towers_cctv_systems SET name = ?, owner_identifier = ?, owner_name = ?, org_job = ?, shared = ?, remote = ?, mode = ?, retention = ?, hdd_fault = ?, configured = ? WHERE recorder_id = ?',
        { s.name, s.owner_identifier, s.owner_name, s.org_job, json.encode(s.shared or {}), s.remote, s.mode, s.retention, s.hdd_fault, s.configured, s.recorder_id })
end
local function cam(id)
    id = tonumber(id)
    local c = S.cams[id]
    if not c then c = { fixture_id = id } S.cams[id] = c end
    return c
end
local function saveCam(c)
    MySQL.query('INSERT INTO opslabs_towers_cctv_cams (fixture_id, name, fault, fault_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), fault = VALUES(fault), fault_at = VALUES(fault_at)',
        { c.fixture_id, c.name, c.fault, c.fault_at })
end

---------------------------------------------------------------------------
-- what is live where
---------------------------------------------------------------------------
local function socketNear(f, reach)
    for _, o in ipairs(LiveOutlets or {}) do if d3(o, f) <= (reach or CV.PlugReach or 3.0) then return true end end
    return false
end

local function compute()
    dirty = false
    local fx = Cabling.fixtures
    local recs, cams = {}, {}
    for id, f in pairs(fx) do
        if REC[f.model] then recs[id] = f elseif CAM[f.model] then cams[id] = f end
    end
    -- CAT6 graph: fixtures (f<id>) and towers (t<id>); crimped ends, or an end lying on the kit
    local adj = {}
    local function link(a, b) if a and b and a ~= b then adj[a] = adj[a] or {} adj[b] = adj[b] or {} adj[a][b] = true adj[b][a] = true end end
    local function endNode(r, which)
        local f, t = r[which .. '_fixture'], r[which .. '_tower']
        if f and fx[f] then return 'f' .. f end
        if t and Towers[t] then return 't' .. t end
        local p = which == 'start' and r.points[1] or r.points[#r.points]
        if not p then return nil end
        for id, c in pairs(cams) do if d3(c, p) <= 0.9 then return 'f' .. id end end
        for id, c in pairs(recs) do if d3(c, p) <= 0.9 then return 'f' .. id end end
        for id, t in pairs(Towers) do if t.z and d3(t, p) <= 0.9 then return 't' .. id end end
        return nil
    end
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and type(r.points) == 'table' and #r.points >= 2 and not (r.loose and next(r.loose)) then
            link(endNode(r, 'start'), endNode(r, 'end'))
        end
    end
    local rs = {}
    for id, f in pairs(recs) do
        local s = system(id)
        local def = REC[f.model]
        local powered = socketNear(f)
        -- on the internet: through any cabled towers to an online gateway
        local internet, seen, q = false, { ['f' .. id] = true }, { 'f' .. id }
        while #q > 0 do
            local n = table.remove(q)
            local tid = tonumber(n:match('^t(%d+)$'))
            if tid and Uplinked and Uplinked[tid] then internet = true break end
            for m in pairs(adj[n] or {}) do if not seen[m] and m:sub(1, 1) == 't' then seen[m] = true q[#q + 1] = m end end
        end
        rs[id] = { id = id, powered = powered, cams = {}, channels = def.channels or 8, poeUsed = 0, poeBudget = def.poeBudget or 0, poePorts = def.poePorts or 0,
            portsUsed = 0, internet = powered and internet, recording = powered and s.hdd_fault ~= 1 and s.mode ~= 'off', kind = def.kind }
    end
    local switchUse = {}
    local cs = {}
    local order = {}
    for id in pairs(cams) do order[#order + 1] = id end
    table.sort(order)
    for _, id in ipairs(order) do
        local f = cams[id]
        local def = CAM[f.model]
        local c = cam(id)
        local st = { id = id, online = false, status = 'no_link' }
        if def.kind == 'ip' or def.kind == 'analog' then
            for n in pairs(adj['f' .. id] or {}) do
                local rid = tonumber(n:match('^f(%d+)$'))
                local tid = tonumber(n:match('^t(%d+)$'))
                if rid and rs[rid] then
                    local r = rs[rid]
                    if def.kind == 'analog' and r.kind ~= 'dvr' then st.status = 'wrong_recorder'
                    elseif def.kind == 'ip' and r.kind ~= 'nvr' then st.status = 'wrong_recorder'
                    elseif not r.powered then st.status = 'no_power'
                    elseif def.kind == 'ip' and (r.portsUsed >= r.poePorts or r.poeUsed + (def.poe or 6) > r.poeBudget) then st.status = 'no_poe'
                    else
                        if def.kind == 'ip' then r.portsUsed = r.portsUsed + 1 r.poeUsed = r.poeUsed + (def.poe or 6) st.via = 'nvr_poe' else st.via = 'dvr' end
                        st.online, st.rec = true, rid
                        break
                    end
                elseif tid and def.kind == 'ip' and Towers[tid] and POESW[Towers[tid].model] then
                    -- PoE switch: powered, budget left, and cabled (through towers) to a powered NVR
                    local sw = Towers[tid]
                    local pw = TowerPowered and TowerPowered(tid)
                    if pw == false then st.status = 'no_power'
                    elseif (switchUse[tid] or 0) + (def.poe or 6) > POESW[sw.model] then st.status = 'no_poe'
                    else
                        local found, seen, q = nil, { [n] = true }, { n }
                        while #q > 0 and not found do
                            local x = table.remove(q)
                            for m in pairs(adj[x] or {}) do
                                local mr = tonumber(m:match('^f(%d+)$'))
                                if mr and rs[mr] and rs[mr].kind == 'nvr' and rs[mr].powered then found = mr break end
                                if not seen[m] and m:sub(1, 1) == 't' then seen[m] = true q[#q + 1] = m end
                            end
                        end
                        if found then
                            switchUse[tid] = (switchUse[tid] or 0) + (def.poe or 6)
                            st.online, st.rec, st.via = true, found, 'switch'
                            break
                        else st.status = 'no_recorder' end
                    end
                end
            end
        else
            -- wireless: a powered recorder on site and Wi-Fi in range
            local best, bd
            for rid, r in pairs(rs) do
                local d = d2(recs[rid], f)
                if r.powered and r.kind == 'nvr' and d <= (CV.SiteRadius or 60) and (not bd or d < bd) then best, bd = rid, d end
            end
            local wifi = false
            for tid, t in pairs(Towers) do
                if t.type == 'wifi' and t.active and t.z and d3(t, f) <= (CV.WifiRange or 40) and (not TowerPowered or TowerPowered(tid)) then wifi = true break end
            end
            if def.plug and not socketNear(f) then st.status = 'no_power'
            elseif not best then st.status = 'no_recorder'
            elseif not wifi then st.status = 'no_wifi'
            else st.online, st.rec, st.via = true, best, 'wifi' end
        end
        if st.online then
            local r = rs[st.rec]
            if #r.cams >= r.channels then st.online, st.status = false, 'no_channel'
            else r.cams[#r.cams + 1] = id st.status = 'ok' end
        end
        -- faults override
        if c.fault == 'dead' or c.fault == 'cable' then st.online = false st.status = 'fault_' .. c.fault
            if st.rec and rs[st.rec] then for i, x in ipairs(rs[st.rec].cams) do if x == id then table.remove(rs[st.rec].cams, i) break end end end
        elseif c.fault == 'lens' and st.online then st.status = 'fault_lens' end
        cs[id] = st
    end
    S.state = { cams = cs, recs = rs }
end

CreateThread(function()
    Wait(9000)
    while true do
        compute()
        Wait(10000)
        while not dirty do Wait(500) break end
    end
end)

---------------------------------------------------------------------------
-- who may watch / configure
---------------------------------------------------------------------------
local function isStaff(src) return src == 0 or (IsTowerAdmin and IsTowerAdmin(src)) or (CanCable and CanCable(src)) end
local function canWatch(src, s)
    if isStaff(src) then return true end
    local ident = FW.Identifier(src)
    if ident and s.owner_identifier == ident then return true end
    for _, x in ipairs(s.shared or {}) do if x.id == ident then return true end end
    if s.org_job and s.org_job ~= '' and FW.Job(src) == s.org_job then return true end
    return false
end
local function canConfigure(src, s)
    if isStaff(src) then return true end
    local ident = FW.Identifier(src)
    return ident ~= nil and s.owner_identifier == ident
end

local STATUS = { ok = 'Live', no_link = 'No cable / not connected', no_power = 'No power', no_poe = 'PoE budget or ports full', no_recorder = 'No recorder on the network',
    no_wifi = 'No Wi-Fi in range', no_channel = 'Recorder has no free channel', wrong_recorder = 'Wrong recorder (IP → NVR, analogue → DVR)',
    fault_lens = 'Picture degraded — dirty / fogged lens', fault_dead = 'Camera failed', fault_cable = 'Cable fault' }

local function camView(id)
    local f = Cabling.fixtures[id]
    if not f then return nil end
    local def = CAM[f.model] or {}
    local st = S.state.cams[id] or { status = 'no_link' }
    local c = S.cams[id] or {}
    local h = math.rad(f.heading or 0)
    local l = def.lens or { 0, -0.2, 0.06 }
    local lx, ly = l[1] * math.cos(h) - l[2] * math.sin(h), l[1] * math.sin(h) + l[2] * math.cos(h)
    return { id = id, name = c.name or ((def.label or 'Camera'):gsub(' %(.*%)', '') .. ' #' .. id), model = f.model, kind = def.kind,
        x = f.x + lx, y = f.y + ly, z = f.z + l[3], heading = f.heading or 0, fov = def.fov or 90, ptz = def.ptz or false, thermal = def.thermal or false,
        anpr = def.anpr or false, ir = def.ir or false, online = st.online or false, status = st.status, statusText = STATUS[st.status] or st.status, via = st.via, rec = st.rec }
end

local function systemView(id, src)
    local f = Cabling.fixtures[id]
    local s = system(id)
    local r = S.state.recs[id] or {}
    local cams = {}
    for cid, st in pairs(S.state.cams) do
        if st.rec == id or (not st.rec and Cabling.fixtures[cid] and f and d2(Cabling.fixtures[cid], f) <= (CV.SiteRadius or 60)) then
            local v = camView(cid)
            if v then cams[#cams + 1] = v end
        end
    end
    table.sort(cams, function(a, b) return a.id < b.id end)
    local def = f and REC[f.model] or {}
    return { id = id, name = s.name or ((def.label or 'Recorder'):gsub(' ·.*', '') .. ' #' .. id), model = f and f.model, kind = def.kind, x = f and f.x, y = f and f.y,
        owner = s.owner_name, org_job = s.org_job, shared = s.shared, remote = s.remote == 1, mode = s.mode, retention = s.retention,
        hddFault = s.hdd_fault == 1, configured = s.configured == 1, powered = r.powered or false, internet = r.internet or false, recording = r.recording or false,
        channels = r.channels, used = #(r.cams or {}), poeUsed = r.poeUsed, poeBudget = r.poeBudget, portsUsed = r.portsUsed, poePorts = r.poePorts,
        cams = cams, canConfigure = src and canConfigure(src, s) or false }
end

local function nearestRecorder(pos, radius)
    local best, bd
    for id, f in pairs(Cabling.fixtures) do
        if REC[f.model] then
            local d = d2(f, pos)
            if d <= (radius or CV.SiteRadius or 60) and (not bd or d < bd) then best, bd = id, d end
        end
    end
    return best
end

local function event(rid, camId, kind, detail, x, y)
    local s = S.systems[rid]
    local r = S.state.recs[rid]
    if not r or not r.recording then return end
    if s and s.mode == 'off' then return end
    MySQL.insert('INSERT INTO opslabs_towers_cctv_events (recorder_id, camera_id, kind, detail, x, y, at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { rid, camId, kind, detail and tostring(detail):sub(1, 160), x, y, now() })
end
CctvEvent = event

local function notifyViewers(s, title, body)
    local ids = {}
    if s.owner_identifier then ids[#ids + 1] = s.owner_identifier end
    for _, x in ipairs(s.shared or {}) do ids[#ids + 1] = x.id end
    for _, ident in ipairs(ids) do
        local src = FW.SourceOf(ident)
        if src then
            TriggerClientEvent('ox_lib:notify', src, { title = title, description = body, type = 'inform', icon = 'video', duration = 9000 })
            if GetResourceState('opslabs-phone') == 'started' then
                pcall(function() exports['opslabs-phone']:Notify(src, title, body, 'system', 'fa-solid fa-video') end)
            end
        end
    end
end

---------------------------------------------------------------------------
-- what the cameras see: motion and plates (every few seconds)
---------------------------------------------------------------------------
local lastMotion, lastPlate = {}, {}
local function inView(v, p)
    local dx, dy = p.x - v.x, p.y - v.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local def = CAM[Cabling.fixtures[v.id].model] or {}
    if dist > (def.range or 30) or math.abs(p.z - v.z) > 15 then return false end
    if dist < 1.0 then return true end
    local h = math.rad(v.heading)
    local fx, fy = math.sin(h), -math.cos(h)                  -- the camera's front (-Y), turned to its heading
    if def.ptz then return true end                            -- a PTZ covers all round
    local dot = (dx * fx + dy * fy) / dist
    return dot >= math.cos(math.rad((def.fov or 90) / 2))
end

CreateThread(function()
    Wait(15000)
    while true do
        Wait((CV.EventEvery or 5) * 1000)
        local t = now()
        local peds = {}
        for _, p in ipairs(GetPlayers()) do
            local ped = GetPlayerPed(p)
            if ped and ped ~= 0 then peds[#peds + 1] = { pos = GetEntityCoords(ped), name = GetPlayerName(p) } end
        end
        local vehs = {}
        for _, v in ipairs(GetAllVehicles()) do
            local sp = GetEntitySpeed(v)
            if sp > 1.0 then vehs[#vehs + 1] = { pos = GetEntityCoords(v), plate = (GetVehicleNumberPlateText(v) or ''):gsub('^%s+', ''):gsub('%s+$', ''), speed = sp } end
        end
        for id, st in pairs(S.state.cams) do
            if st.online and st.rec then
                local v = camView(id)
                if v then
                    local def = CAM[v.model] or {}
                    if def.anpr then
                        for _, x in ipairs(vehs) do
                            if inView(v, x.pos) and x.plate ~= '' then
                                local k = id .. ':' .. x.plate
                                if (lastPlate[k] or 0) + (CV.AnprCooldown or 90) < t then
                                    lastPlate[k] = t
                                    event(st.rec, id, 'anpr', ('%s · %d km/h'):format(x.plate, math.floor(x.speed * 3.6)), x.pos.x, x.pos.y)
                                end
                            end
                        end
                    else
                        local n = 0
                        for _, p in ipairs(peds) do if inView(v, p.pos) then n = n + 1 end end
                        for _, x in ipairs(vehs) do if inView(v, x.pos) then n = n + 1 end end
                        if n > 0 and (lastMotion[id] or 0) + (CV.MotionCooldown or 30) < t then
                            lastMotion[id] = t
                            event(st.rec, id, def.thermal and 'heat' or 'motion', ('%d moving'):format(n), v.x, v.y)
                        end
                    end
                end
            end
        end
    end
end)

-- faults: cameras get dirty, cables get cut, cameras die — OPS Secure gets a job
CreateThread(function()
    Wait(60000)
    while true do
        local p = (CV.FaultsPerCameraHour or 0.01) / 60
        for id, st in pairs(S.state.cams) do
            local c = cam(id)
            if st.online and not c.fault and math.random() < p then
                local r = math.random()
                c.fault = r < 0.5 and 'lens' or r < 0.8 and 'cable' or 'dead'
                c.fault_at = now()
                saveCam(c)
                dirty = true
                local f = Cabling.fixtures[id]
                local s = st.rec and S.systems[st.rec]
                if s then notifyViewers(s, 'CCTV fault', ('%s: %s'):format(camView(id).name, STATUS['fault_' .. c.fault])) end
                if f and GetResourceState('opslabs-phone') == 'started' then
                    pcall(function()
                        exports['opslabs-phone']:CreatePlatformJob(exports['opslabs-phone']:CompanyForRole('secure') or 'secure', 'cctv_fault', { name = (s and s.name or 'CCTV system') .. ' · ' .. camView(id).name, x = f.x, y = f.y, z = f.z },
                            { title = 'CCTV fault · ' .. STATUS['fault_' .. c.fault], emergency = s and s.org_job ~= nil and s.org_job ~= '' })
                    end)
                end
            end
        end
        -- tidy: events past each system's retention
        MySQL.query([[DELETE e FROM opslabs_towers_cctv_events e LEFT JOIN opslabs_towers_cctv_systems s ON s.recorder_id = e.recorder_id
            WHERE e.at < ? - COALESCE(s.retention, 7) * 86400]], { now() })
        Wait(60000)
    end
end)

---------------------------------------------------------------------------
-- callbacks
---------------------------------------------------------------------------
local function near(src, f, r) local p = GetEntityCoords(GetPlayerPed(src)) return d3(p, f) <= (r or 4.0) end

--- [E] at a recorder, monitor, video wall or keyboard
lib.callback.register('opslabs-towers:cctv:site', function(src, fid)
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f or not near(src, f, 6) then return { error = 'Too far away' } end
    if dirty then compute() end
    local rid = REC[f.model] and f.id or nearestRecorder(f)
    if not rid then return { error = 'No CCTV recorder on this site' } end
    local s = system(rid)
    if not canWatch(src, s) and not REC[f.model] then return { error = 'This system isn’t yours — ask the owner or OPS Secure for access' } end
    local v = systemView(rid, src)
    v.access = canWatch(src, s)
    if not v.access then v.cams = {} end
    return v
end)

--- watch: the cameras of a system (local at the site, or remote from the phone)
lib.callback.register('opslabs-towers:cctv:watch', function(src, rid, remote)
    rid = tonumber(rid)
    local f = rid and Cabling.fixtures[rid]
    if not f or not REC[f.model] then return { error = 'No such system' } end
    if dirty then compute() end
    local s = system(rid)
    if not canWatch(src, s) then return { error = 'You don’t have access to this system' } end
    local r = S.state.recs[rid] or {}
    if not r.powered then return { error = 'The recorder has no power' } end
    if remote then
        if s.remote ~= 1 then return { error = 'Remote viewing is off for this system' } end
        if not r.internet then return { error = 'The recorder isn’t connected to the internet' } end
    end
    event(rid, nil, 'view', ('%s watched%s'):format(GetPlayerName(src), remote and ' remotely' or ''))
    local v = systemView(rid, src)
    if CctvLiveWatching then CctvLiveWatching(src, v.cams) end      -- server/cctvlive.lua: their view feeds OPS Hub
    return v
end)

--- systems you can watch remotely (phone app); staff see every system
lib.callback.register('opslabs-towers:cctv:mine', function(src)
    if dirty then compute() end
    local out = {}
    for id, f in pairs(Cabling.fixtures) do
        if REC[f.model] then
            local s = system(id)
            if canWatch(src, s) then
                local v = systemView(id, src)
                v.cams = #v.cams
                out[#out + 1] = v
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

lib.callback.register('opslabs-towers:cctv:events', function(src, rid, kind)
    rid = tonumber(rid)
    local s = rid and S.systems[rid]
    if not s or not canWatch(src, s) then return {} end
    local rows = MySQL.query.await(('SELECT * FROM opslabs_towers_cctv_events WHERE recorder_id = ? %s ORDER BY id DESC LIMIT 60'):format(kind and 'AND kind = ?' or ''),
        kind and { rid, kind } or { rid }) or {}
    for _, e in ipairs(rows) do local v = e.camera_id and camView(e.camera_id) e.camera = v and v.name or nil end
    return rows
end)

lib.callback.register('opslabs-towers:cctv:config', function(src, rid, d)
    rid = tonumber(rid)
    local f = rid and Cabling.fixtures[rid]
    if not f or not REC[f.model] or type(d) ~= 'table' then return { error = 'No such system' } end
    local s = system(rid)
    if not canConfigure(src, s) then return { error = 'Only the owner or OPS Secure can change this system' } end
    if d.name then s.name = tostring(d.name):sub(1, 60) end
    if d.mode and (d.mode == 'motion' or d.mode == 'continuous' or d.mode == 'off') then s.mode = d.mode end
    if d.retention then s.retention = math.max(1, math.min(90, math.floor(tonumber(d.retention) or 7))) end
    if d.remote ~= nil then s.remote = d.remote and 1 or 0 end
    if d.org_job ~= nil then s.org_job = (tostring(d.org_job):gsub('[^%w_]', '')):sub(1, 40) if s.org_job == '' then s.org_job = nil end end
    if d.owner == 'me' then s.owner_identifier, s.owner_name = FW.Identifier(src), GetPlayerName(src)
    elseif tonumber(d.owner) then
        local t = tonumber(d.owner)
        if GetPlayerName(t) then s.owner_identifier, s.owner_name = FW.Identifier(t), GetPlayerName(t) else return { error = 'No player with that ID' } end
    end
    if tonumber(d.share) then
        local t = tonumber(d.share)
        if not GetPlayerName(t) then return { error = 'No player with that ID' } end
        local ident = FW.Identifier(t)
        local have = false
        for _, x in ipairs(s.shared) do if x.id == ident then have = true end end
        if not have then s.shared[#s.shared + 1] = { id = ident, name = GetPlayerName(t) } end
    end
    if d.unshare then for i, x in ipairs(s.shared) do if x.id == d.unshare then table.remove(s.shared, i) break end end end
    if d.camera and d.cameraName then
        local c = cam(d.camera)
        c.name = tostring(d.cameraName):sub(1, 40)
        saveCam(c)
    end
    s.configured = 1
    saveSystem(s)
    dirty = true
    return { ok = true, system = systemView(rid, src) }
end)

--- engineers on site: fix the camera / the recorder
lib.callback.register('opslabs-towers:cctv:repair', function(src, fid, action)
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f or not near(src, f, 4) then return { error = 'Get to the kit first' } end
    if not isStaff(src) then return { error = 'Only OPS Secure engineers can repair CCTV' } end
    if REC[f.model] then
        local s = system(f.id)
        if action ~= 'hdd' then return { error = 'Nothing to do' } end
        s.hdd_fault = 0 saveSystem(s)
    else
        local c = cam(f.id)
        if not c.fault then return { error = 'This camera has no fault' } end
        local need = { lens = 'clean', cable = 'reterminate', dead = 'replace' }
        if need[c.fault] ~= action then return { error = 'That won’t fix it — check the fault first' } end
        c.fault, c.fault_at = nil, nil
        saveCam(c)
    end
    dirty = true
    return { ok = true }
end)

lib.callback.register('opslabs-towers:cctv:camera', function(src, fid)
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f or not CAM[f.model] then return nil end
    if dirty then compute() end
    local v = camView(f.id)
    v.fault = (S.cams[f.id] or {}).fault
    v.staff = isStaff(src)
    return v
end)

--- someone rings a video doorbell
local rang = {}
lib.callback.register('opslabs-towers:cctv:ring', function(src, fid)
    local f = Cabling.fixtures[tonumber(fid) or -1]
    if not f or f.model ~= 'opslabs_cctv_doorbell' or not near(src, f, 3) then return { error = 'No doorbell here' } end
    if (rang[f.id] or 0) + 15 > now() then return { ok = true } end
    rang[f.id] = now()
    local st = S.state.cams[f.id]
    if not st or not st.online then return { ok = true, offline = true } end
    local s = S.systems[st.rec]
    event(st.rec, f.id, 'ring', 'Doorbell rung', f.x, f.y)
    if s then notifyViewers(s, '🔔 Doorbell', ('Someone is at the door · %s'):format(s.name or 'your doorbell')) end
    return { ok = true }
end)

---------------------------------------------------------------------------
-- OPS Hub + the job checks
---------------------------------------------------------------------------
function CctvState()
    if dirty then compute() end
    local out = { systems = {}, anpr = {}, stats = { cameras = 0, online = 0, faults = 0 } }
    for id, f in pairs(Cabling.fixtures) do if REC[f.model] then out.systems[#out.systems + 1] = systemView(id) end end
    table.sort(out.systems, function(a, b) return a.id < b.id end)
    for _, st in pairs(S.state.cams) do
        out.stats.cameras = out.stats.cameras + 1
        if st.online then out.stats.online = out.stats.online + 1 end
        if tostring(st.status):find('^fault') then out.stats.faults = out.stats.faults + 1 end
    end
    out.events = MySQL.query.await('SELECT * FROM opslabs_towers_cctv_events ORDER BY id DESC LIMIT 80') or {}
    for _, e in ipairs(out.events) do local v = e.camera_id and camView(e.camera_id) e.camera = v and v.name or nil end
    return out
end
function CctvAction(rid, d, actor)
    rid = tonumber(rid)
    local f = rid and Cabling.fixtures[rid]
    if not f or not REC[f.model] then return nil, 'No such system' end
    local s = system(rid)
    if d.name then s.name = tostring(d.name):sub(1, 60) end
    if d.remote ~= nil then s.remote = d.remote and 1 or 0 end
    if d.mode then s.mode = d.mode end
    if d.org_job ~= nil then s.org_job = d.org_job ~= '' and tostring(d.org_job):sub(1, 40) or nil end
    s.configured = 1
    saveSystem(s)
    dirty = true
    return true
end
function CctvCamStates() if dirty then compute() end return S.state end
--- server/cctvlive.lua: one camera / every camera, as the viewer sees them (with the system each is on)
function CctvCamView(id) if dirty then compute() end return camView(tonumber(id)) end
function CctvAllCams()
    if dirty then compute() end
    local out = {}
    for cid, st in pairs(S.state.cams) do
        local v = camView(cid)
        if v then
            local rf = st.rec and Cabling.fixtures[st.rec]
            v.system = st.rec and (system(st.rec).name or ('Recorder #' .. st.rec)) or nil
            v.recorder = st.rec
            out[#out + 1] = v
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
exports('CctvState', CctvState)
