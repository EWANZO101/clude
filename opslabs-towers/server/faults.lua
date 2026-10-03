-- Network faults: once poles and kit are live they develop faults at random over days and
-- weeks (Config.Faults). A fault really breaks things (light stops at a broken span, a wet
-- CBT, a dead cabinet...), lists the customers it took down, and stays until an engineer goes
-- to the spot and repairs it in game (or it's closed from the website / Ops-Networks app).
-- Settings: Config.Faults defaults, overridden by what the dev app / Ops-Networks admin saves.

local CF = Config.Faults or { Types = {} }
Faults = {}                         -- [id] = fault (active ones + recently fixed / closed)
FaultEffects = { fixtures = {}, runs = {}, loss = {}, towers = {} }
local LiveSince = {}                -- asset key -> unix time it first went live
local LastFixed = {}                -- asset key -> unix time its last fault was fixed
local Saved = { types = {} }        -- settings saved in game (override the config file)
local ready = false
local ACTIVE = { open = true, acknowledged = true, in_progress = true }
local ORDER = { 'pole_lean', 'pole_rot', 'fibre_break', 'dropwire_down', 'cbt_water', 'splice_loss', 'ont_failure', 'cabinet_power', 'olt_card', 'tower_power' }
local SEV = { critical = 4, high = 3, medium = 2, low = 1 }

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------

local function typeSetting(id)
    local t, s = CF.Types[id], Saved.types[id] or {}
    if not t then return nil end
    local function pick(k) if s[k] ~= nil then return s[k] end return t[k] end
    return { id = id, label = t.label, category = t.category, severity = t.severity, at_height = t.at_height == true,
        enabled = pick('enabled') ~= false, perWeek = tonumber(pick('perWeek')) or 0, minLiveHours = tonumber(pick('minLiveHours')) or 0,
        description = (t.symptoms or {})[1] }
end

function GetFaultSettings()
    local types = {}
    for _, id in ipairs(ORDER) do if CF.Types[id] then types[#types + 1] = typeSetting(id) end end
    for id in pairs(CF.Types) do
        local known = false
        for _, o in ipairs(ORDER) do if o == id then known = true end end
        if not known then types[#types + 1] = typeSetting(id) end
    end
    local enabled = Saved.enabled
    if enabled == nil then enabled = CF.Enabled ~= false end
    return { enabled = enabled, maxOpen = tonumber(Saved.maxOpen) or CF.MaxOpen or 6, types = types }
end

function SetFaultSettings(s, actor)
    if type(s) ~= 'table' then return nil, 'bad settings' end
    if s.enabled ~= nil then Saved.enabled = s.enabled == true end
    if s.maxOpen ~= nil then
        local n = math.tointeger(tonumber(s.maxOpen))
        if not n or n < 0 or n > 100 then return nil, 'maxOpen must be 0-100' end
        Saved.maxOpen = n
    end
    for id, t in pairs(type(s.types) == 'table' and s.types or {}) do
        if CF.Types[id] and type(t) == 'table' then
            local cur = Saved.types[id] or {}
            if t.enabled ~= nil then cur.enabled = t.enabled == true end
            if t.perWeek ~= nil then
                local n = tonumber(t.perWeek)
                if not n or n < 0 or n > 500 then return nil, 'perWeek must be 0-500' end
                cur.perWeek = n
            end
            if t.minLiveHours ~= nil then
                local n = tonumber(t.minLiveHours)
                if not n or n < 0 or n > 8760 then return nil, 'minLiveHours must be 0-8760' end
                cur.minLiveHours = n
            end
            Saved.types[id] = cur
        end
    end
    MySQL.update.await('REPLACE INTO opslabs_towers_faults_cfg (k, v) VALUES (?, ?)', { 'settings', json.encode(Saved) })
    print(('[opslabs-towers] fault settings changed by %s'):format(tostring(actor or '?')))
    return true
end

---------------------------------------------------------------------------
-- render range for network & power kit (Config.Render, overridable from the dev app)
---------------------------------------------------------------------------

local Render = {}
function GetRenderSettings()
    local d = Config.Render or {}
    return { Distance = tonumber(Render.Distance) or d.Distance or 400.0, Behind = tonumber(Render.Behind) or d.Behind or 80.0,
        ViewAngle = tonumber(Render.ViewAngle) or d.ViewAngle or 130.0, Margin = tonumber(Render.Margin) or d.Margin or 25.0 }
end

function SetRenderSettings(r, actor)
    if type(r) ~= 'table' then return nil, 'bad settings' end
    local limits = { Distance = { 50, 1500 }, Behind = { 10, 400 }, ViewAngle = { 60, 360 }, Margin = { 0, 100 } }
    for k, lim in pairs(limits) do
        if r[k] ~= nil then
            local n = tonumber(r[k])
            if not n or n < lim[1] or n > lim[2] then return nil, ('%s must be %d-%d'):format(k, lim[1], lim[2]) end
            Render[k] = n
        end
    end
    MySQL.update.await('REPLACE INTO opslabs_towers_faults_cfg (k, v) VALUES (?, ?)', { 'render', json.encode(Render) })
    TriggerClientEvent('opslabs-towers:render', -1, GetRenderSettings())
    print(('[opslabs-towers] render range changed by %s'):format(tostring(actor or '?')))
    return true
end
exports('GetRenderSettings', GetRenderSettings)
exports('SetRenderSettings', SetRenderSettings)

---------------------------------------------------------------------------
-- addresses shown to engineers (stable per ONT)
---------------------------------------------------------------------------

local NET = { opsfibre = 81, velocity = 86, lumen = 92 }
function OntAddress(id, providerId)
    local a = NET[providerId or ''] or 82
    local b = 2 + (id * 37) % 250
    local c = (id * 101 + 17) % 254
    local d = 2 + (id * 53) % 252
    local h = (id * 2654435761) % 0xFFFFFF
    return {
        ip = ('%d.%d.%d.%d'):format(a, b, c, d),
        gateway = ('%d.%d.%d.1'):format(a, b, c),
        mac = ('D8:3A:F1:%02X:%02X:%02X'):format((h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF),
        lan_subnet = '192.168.1.0/24',
    }
end

---------------------------------------------------------------------------
-- what can go wrong where
---------------------------------------------------------------------------

local function eqLabel(model)
    for _, e in ipairs(Config.Cabling.Equipment or {}) do
        if e.model == model then return (e.label:gsub(' %(.*%)', '')) end
        for _, sz in ipairs(e.sizes or {}) do if sz.model == model then return (e.label:gsub(' %(.*%)', '')) .. ' · ' .. sz.label end end
    end
    return model
end

-- nearest pole within reach of a point (kit strapped to a pole, a cable clamped on one)
local POLE_H = { opslabs_pole_07m = 7.0, opslabs_pole_10m = 10.0, opslabs_pole_13m = 13.0, opslabs_pole_metal = 9.0, opslabs_power_pole_10m = 10.0, opslabs_power_pole_12m = 12.0 }
local function poleAt(x, y, reach)
    local best, bd
    for id, f in pairs(Cabling.fixtures) do
        if POLE_H[f.model] then
            local d = math.sqrt((f.x - x) ^ 2 + (f.y - y) ^ 2)
            if d < (bd or reach or 0.6) then best, bd = id, d end
        end
    end
    return best
end

local function runLit(r)
    return r.kind == 'fibre' and r.start_term and r.end_term and r.start_fixture and r.end_fixture
        and (LitFixtures[r.start_fixture] or LitFixtures[r.end_fixture]) and true or false
end

--- every live asset a fault type can land on: { key, kind, id, label, model, x, y, z, pole_id }
local function candidates(typeId, polesLive)
    local t = CF.Types[typeId]
    local out = {}
    local tg = t.targets
    if tg == 'poles' then
        for _, p in ipairs(polesLive) do
            out[#out + 1] = { key = 'p:' .. p.id, kind = 'pole', id = p.id, label = p.label .. ' #' .. p.id, model = p.model, x = p.x, y = p.y, z = p.z + 1.0, pole_id = p.id }
        end
    elseif tg == 'aerial_fibre' or tg == 'drop_fibre' then
        for id, r in pairs(Cabling.runs) do
            if runLit(r) then
                local sm, em = Cabling.fixtures[r.start_fixture], Cabling.fixtures[r.end_fixture]
                local house = (sm and (sm.model == 'opslabs_csp' or sm.model == Config.Isp.Ont)) or (em and (em.model == 'opslabs_csp' or em.model == Config.Isp.Ont))
                if tg == 'drop_fibre' and house then
                    local hm = (em and (em.model == 'opslabs_csp' or em.model == Config.Isp.Ont)) and em or sm
                    out[#out + 1] = { key = 'r:' .. id, kind = 'run', id = id, label = ('Dropwire (fibre run #%d)'):format(id), model = 'fibre', x = hm.x, y = hm.y, z = hm.z, pole_id = poleAt(hm.x, hm.y, 30) }
                elseif tg == 'aerial_fibre' and not house then
                    for _, pt in ipairs(r.points or {}) do
                        if pt.p and Cabling.fixtures[pt.p] then
                            out[#out + 1] = { key = 'r:' .. id, kind = 'run', id = id, label = ('Aerial fibre span (run #%d)'):format(id), model = 'fibre', x = pt.x, y = pt.y, z = pt.z, pole_id = pt.p }
                            break
                        end
                    end
                end
            end
        end
    elseif tg == 'cell_towers' then
        for id, tw in pairs(Towers or {}) do
            if tw.type == 'cell' and tw.active then
                out[#out + 1] = { key = 't:' .. id, kind = 'tower', id = id, label = tw.name or ('Mast #' .. id), model = tw.model or 'mast', x = tw.x, y = tw.y, z = tw.z }
            end
        end
    elseif type(tg) == 'table' then
        local set = {}
        for _, m in ipairs(tg) do set[m] = true end
        local ont = IspPayload and IspPayload() or {}
        for id, f in pairs(Cabling.fixtures) do
            if set[f.model] and LitFixtures[id] and (f.model ~= Config.Isp.Ont or (ont[id] and ont[id].internet == 'on')) then
                out[#out + 1] = { key = 'f:' .. id, kind = 'fixture', id = id, label = eqLabel(f.model) .. ' #' .. id, model = f.model, x = f.x, y = f.y, z = f.z, pole_id = poleAt(f.x, f.y) }
            end
        end
    end
    return out
end

local function busy(key)
    for _, f in pairs(Faults) do if ACTIVE[f.status] and f._key == key then return true end end
    return false
end

local function openCount()
    local n = 0
    for _, f in pairs(Faults) do if ACTIVE[f.status] then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- effects on the network
---------------------------------------------------------------------------

local function rebuildEffects()
    local e = { fixtures = {}, runs = {}, loss = {}, towers = {} }
    for _, f in pairs(Faults) do
        if ACTIVE[f.status] then
            local a = f.asset
            if f.type == 'fibre_break' or f.type == 'dropwire_down' then e.runs[a.id] = true
            elseif f.type == 'cbt_water' then e.fixtures[a.id] = 'nopass'
            elseif f.type == 'ont_failure' or f.type == 'cabinet_power' or f.type == 'olt_card' then e.fixtures[a.id] = 'dead'
            elseif f.type == 'splice_loss' then e.loss[a.id] = (e.loss[a.id] or 0) + ((CF.Types.splice_loss or {}).lossDb or 8.0)
            elseif f.type == 'tower_power' then e.towers[a.id] = true end
        end
    end
    FaultEffects = e
end

local function onlineOnts()
    local on = {}
    for id, s in pairs(IspPayload and IspPayload() or {}) do
        if s.internet == 'on' then on[id] = s.rx or 0 end
    end
    return on
end

local function customerRow(id)
    local s = (IspPayload and IspPayload() or {})[id] or {}
    local f = Cabling.fixtures[id]
    local addr = OntAddress(id, IspServiceProvider and IspServiceProvider(id))
    return { ont_id = id, customer = s.customer, username = s.username, provider = s.provider, plan = s.plan, ip = addr.ip,
        x = f and f.x, y = f and f.y }
end

local function public(f)
    local o = {}
    for k, v in pairs(f) do if k:sub(1, 1) ~= '_' then o[k] = v end end
    return o
end

local function push()
    -- every client gets the active faults (engineers see markers and repair them)
    local list = {}
    for _, f in pairs(Faults) do
        if ACTIVE[f.status] then
            list[#list + 1] = { id = f.id, type = f.type, label = f.label, severity = f.severity, status = f.status, x = f.x, y = f.y, z = f.z,
                at_height = f.at_height, pole_id = f.pole_id, asset = f.asset.label }
        end
    end
    TriggerClientEvent('opslabs-towers:faults', -1, list)
end

local function save(f)
    MySQL.update.await('UPDATE opslabs_towers_faults SET status = ?, data = ?, ack_at = ?, ack_by = ?, fixed_at = ?, fixed_by = ? WHERE id = ?',
        { f.status, json.encode(public(f)), f.ack_at, f.ack_by, f.fixed_at, f.fixed_by, f.id })
end

---------------------------------------------------------------------------
-- opening / fixing
---------------------------------------------------------------------------

local function openFault(typeId, a, actor)
    local t = CF.Types[typeId]
    local before = onlineOnts()
    local cause = t.causes and t.causes[math.random(#t.causes)] or nil
    local where = a.pole_id and (' (pole #%d)'):format(a.pole_id) or ''
    local f = {
        type = typeId, label = t.label, category = t.category, severity = t.severity, status = 'open',
        asset = { kind = a.kind, id = a.id, label = a.label, model = a.model }, pole_id = a.pole_id,
        x = math.floor(a.x * 100 + 0.5) / 100, y = math.floor(a.y * 100 + 0.5) / 100, z = math.floor(a.z * 100 + 0.5) / 100,
        at_height = t.at_height == true and a.pole_id ~= nil,
        cause = cause, symptoms = t.symptoms or {}, diagnosis = (t.diagnosis or '') .. (cause and (' Cause: ' .. cause:lower() .. '.') or ''),
        fix_steps = t.fix or {}, tools = t.tools or {}, needs_guy = t.needsGuy == true,
        affected = {}, affected_count = 0, created_at = os.time(), notes = {},
        location = a.label .. where, _key = a.key,
    }
    if actor then f.notes[1] = { at = f.created_at, by = actor, text = 'Test fault raised from the dev tools' } end
    local id = MySQL.insert.await('INSERT INTO opslabs_towers_faults (type, asset, status, data) VALUES (?, ?, ?, ?)', { typeId, a.key, 'open', '{}' })
    f.id = id
    Faults[id] = f
    rebuildEffects()
    if CablingChanged then CablingChanged() end
    -- who lost service (or got noticeably worse light) because of it
    local after = onlineOnts()
    for oid, rx in pairs(before) do
        if not after[oid] or (after[oid] < rx - 1.0) then
            local row = customerRow(oid)
            row.impact = after[oid] and 'degraded' or 'down'
            f.affected[#f.affected + 1] = row
        end
    end
    f.affected_count = #f.affected
    if f.affected_count > 0 then
        f.symptoms = { table.unpack(f.symptoms) }
        f.symptoms[#f.symptoms + 1] = ('%d customer%s affected'):format(f.affected_count, f.affected_count == 1 and '' or 's')
    end
    save(f)
    print(('[opslabs-towers] FAULT #%d %s on %s (%d customers affected)'):format(id, typeId, a.label, f.affected_count))
    push()
    TriggerEvent('opslabs-towers:faultOpened', public(f))
    return f
end

local function finish(f, status, src, actor, note)
    f.status = status
    f.fixed_at = os.time()
    f.fixed_by = actor
    if note and note ~= '' then f.notes[#f.notes + 1] = { at = f.fixed_at, by = actor, text = note } end
    LastFixed[f._key] = f.fixed_at
    save(f)
    rebuildEffects()
    if CablingChanged then CablingChanged() end
    push()
    TriggerEvent('opslabs-towers:faultFixed', public(f), src)
end

---------------------------------------------------------------------------
-- the dice
---------------------------------------------------------------------------

local function livePoles()
    local out = {}
    local poles = IspPoles and select(1, IspPoles()) or {}
    for _, p in ipairs(poles) do if p.status == 'live' and not p.house then out[#out + 1] = p end end
    return out
end

local function trackLive(polesLive)
    local now = os.time()
    local function mark(key)
        if not LiveSince[key] then
            LiveSince[key] = now
            MySQL.insert('INSERT IGNORE INTO opslabs_towers_live (asset, since) VALUES (?, ?)', { key, now })
        end
    end
    for _, p in ipairs(polesLive) do mark('p:' .. p.id) end
    for id in pairs(LitFixtures) do mark('f:' .. id) end
    for id, r in pairs(Cabling.runs) do if runLit(r) then mark('r:' .. id) end end
    for id, tw in pairs(Towers or {}) do if tw.type == 'cell' and tw.active then mark('t:' .. id) end end
end

local function eligible(typeId, polesLive, ignoreAge)
    local s = typeSetting(typeId)
    local now = os.time()
    local out = {}
    for _, a in ipairs(candidates(typeId, polesLive)) do
        local since = LiveSince[a.key]
        if since and not busy(a.key)
            and (ignoreAge or now - since >= s.minLiveHours * 3600)
            and (ignoreAge or not LastFixed[a.key] or now - LastFixed[a.key] >= (CF.CooldownHours or 72) * 3600) then
            out[#out + 1] = a
        end
    end
    return out
end

local function tick()
    local polesLive = livePoles()
    trackLive(polesLive)
    local st = GetFaultSettings()
    if not st.enabled then return end
    local dt = (CF.TickMinutes or 5) * 60
    for _, s in ipairs(st.types) do
        if openCount() >= st.maxOpen then return end
        if s.enabled and s.perWeek > 0 then
            -- chance this tick that one happens somewhere: rate per week spread over the ticks
            local p = 1 - math.exp(-s.perWeek * dt / 604800)
            if math.random() < p then
                local list = eligible(s.id, polesLive)
                if #list > 0 then openFault(s.id, list[math.random(#list)]) end
            end
        end
    end
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_faults` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `type` VARCHAR(24) NOT NULL,
        `asset` VARCHAR(24) NOT NULL,
        `status` VARCHAR(12) NOT NULL DEFAULT 'open',
        `data` MEDIUMTEXT NOT NULL,
        `ack_at` INT DEFAULT NULL, `ack_by` VARCHAR(60) DEFAULT NULL,
        `fixed_at` INT DEFAULT NULL, `fixed_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `status` (`status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_live` (
        `asset` VARCHAR(24) NOT NULL, `since` INT NOT NULL, PRIMARY KEY (`asset`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_towers_faults_cfg` (
        `k` VARCHAR(40) NOT NULL, `v` TEXT NOT NULL, PRIMARY KEY (`k`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    local cfg = MySQL.scalar.await('SELECT v FROM opslabs_towers_faults_cfg WHERE k = ?', { 'settings' })
    if cfg then
        local ok, d = pcall(json.decode, cfg)
        if ok and type(d) == 'table' then Saved = d Saved.types = Saved.types or {} end
    end
    local rcfg = MySQL.scalar.await('SELECT v FROM opslabs_towers_faults_cfg WHERE k = ?', { 'render' })
    if rcfg then
        local ok, d = pcall(json.decode, rcfg)
        if ok and type(d) == 'table' then Render = d end
    end
    TriggerClientEvent('opslabs-towers:render', -1, GetRenderSettings())
    for _, r in ipairs(MySQL.query.await('SELECT asset, since FROM opslabs_towers_live') or {}) do LiveSince[r.asset] = r.since end
    local cutoff = os.time() - 14 * 86400
    for _, r in ipairs(MySQL.query.await("SELECT * FROM opslabs_towers_faults WHERE status IN ('open','acknowledged','in_progress') OR fixed_at >= ?", { cutoff }) or {}) do
        local ok, f = pcall(json.decode, r.data)
        if ok and type(f) == 'table' and f.type then
            f.id, f.status, f._key = r.id, r.status, r.asset
            f.ack_at, f.ack_by, f.fixed_at, f.fixed_by = r.ack_at, r.ack_by, r.fixed_at, r.fixed_by
            f.notes = f.notes or {}
            Faults[r.id] = f
            if r.fixed_at then LastFixed[r.asset] = math.max(LastFixed[r.asset] or 0, r.fixed_at) end
        end
    end
    rebuildEffects()
    ready = true
    Wait(5000)
    if CablingChanged then CablingChanged() end
    push()
    while true do
        local ok, err = pcall(tick)
        if not ok then print('^1[opslabs-towers] fault tick failed: ' .. tostring(err) .. '^7') end
        Wait((CF.TickMinutes or 5) * 60000)
    end
end)

RegisterNetEvent('opslabs-towers:ready', function()
    if not ready then return end
    TriggerClientEvent('opslabs-towers:render', source, GetRenderSettings())
    push()
end)

---------------------------------------------------------------------------
-- queries + actions (exports, website API, phone apps)
---------------------------------------------------------------------------

local function sorted(filter)
    local out = {}
    for _, f in pairs(Faults) do if filter(f) then out[#out + 1] = public(f) end end
    table.sort(out, function(a, b)
        local aa, ba = ACTIVE[a.status] and 1 or 0, ACTIVE[b.status] and 1 or 0
        if aa ~= ba then return aa > ba end
        if (SEV[a.severity] or 0) ~= (SEV[b.severity] or 0) then return (SEV[a.severity] or 0) > (SEV[b.severity] or 0) end
        return a.created_at > b.created_at
    end)
    return out
end

function GetFaults(opts)
    opts = type(opts) == 'table' and opts or {}
    local all = opts.status == 'all'
    local list = sorted(function(f) return all or ACTIVE[f.status] end)
    if opts.limit and #list > opts.limit then for i = #list, opts.limit + 1, -1 do list[i] = nil end end
    local open, critical, affected = 0, 0, {}
    for _, f in pairs(Faults) do
        if ACTIVE[f.status] then
            open = open + 1
            if f.severity == 'critical' then critical = critical + 1 end
            for _, a in ipairs(f.affected or {}) do affected[a.ont_id] = true end
        end
    end
    local n = 0
    for _ in pairs(affected) do n = n + 1 end
    return { faults = list, stats = { open = open, critical = critical, affected = n } }
end

function FaultOnOnt(ontId)
    for _, f in pairs(Faults) do
        if ACTIVE[f.status] then
            if f.asset.kind == 'fixture' and f.asset.id == ontId then return f.id end
            for _, a in ipairs(f.affected or {}) do if a.ont_id == ontId then return f.id end end
        end
    end
end

function FaultsOnPole(poleId)
    local ids = {}
    for _, f in pairs(Faults) do if ACTIVE[f.status] and f.pole_id == poleId then ids[#ids + 1] = f.id end end
    return ids
end

function TriggerFault(typeId, actor)
    if not CF.Types[typeId] then return nil, 'Unknown fault type' end
    local pl = livePoles()
    trackLive(pl)
    local list = eligible(typeId, pl, true)
    if #list == 0 then return nil, 'Nothing live on the network can get that fault yet' end
    return public(openFault(typeId, list[math.random(#list)], actor or 'dev'))
end

function AckFault(id, actor)
    local f = Faults[tonumber(id)]
    if not f or not ACTIVE[f.status] then return nil, 'Fault not found or already closed' end
    if f.status == 'open' then f.status = 'acknowledged' end
    f.ack_at, f.ack_by = os.time(), tostring(actor or 'NOC')
    save(f) push()
    TriggerEvent('opslabs-towers:faultUpdated', public(f))
    return true
end

function AddFaultNote(id, actor, text)
    local f = Faults[tonumber(id)]
    if not f then return nil, 'Fault not found' end
    text = type(text) == 'string' and text:sub(1, 500) or ''
    if text:gsub('%s', '') == '' then return nil, 'Note is empty' end
    f.notes[#f.notes + 1] = { at = os.time(), by = tostring(actor or 'NOC'), text = text }
    save(f)
    TriggerEvent('opslabs-towers:faultUpdated', public(f))
    return true
end

function CloseFault(id, actor, note)
    local f = Faults[tonumber(id)]
    if not f or not ACTIVE[f.status] then return nil, 'Fault not found or already closed' end
    finish(f, 'closed', nil, tostring(actor or 'NOC'), note)
    return true
end

-- Wi-Fi kit and its nominal indoor range (metres), for the range tester in Ops-Networks
local WIFI_RANGE = { opslabs_unifi_ap_ceiling = 45, opslabs_unifi_ap = 38, opslabs_ucg_ultra = 30, opslabs_udm_pro = 32, opslabs_omada_eap_ceiling = 45,
    opslabs_omada_eap = 38, opslabs_omada_er605 = 0, opslabs_omada_er7206 = 0, opslabs_omada_switch = 0, opslabs_omada_oc200 = 0,
    opslabs_tplink_deco = 30, opslabs_tplink_archer = 35, opslabs_tplink_extender = 18, h4_prop_h4_router_01a = 30 }
exports('GetWifiModels', function()
    local out = {}
    for _, p in ipairs(Config.Wifi.Props or {}) do
        local r = WIFI_RANGE[p.model]
        if r == nil then r = Config.Wifi.DefaultRange or 40 end
        if r > 0 then out[#out + 1] = { model = p.model, label = p.label, range = r } end
    end
    return out
end)

exports('GetFaultSettings', GetFaultSettings)
exports('SetFaultSettings', SetFaultSettings)
exports('GetFaults', GetFaults)
exports('GetFault', function(id) local f = Faults[tonumber(id)] return f and public(f) or nil end)
exports('TriggerFault', TriggerFault)
exports('AckFault', AckFault)
exports('AddFaultNote', AddFaultNote)
exports('CloseFault', CloseFault)

---------------------------------------------------------------------------
-- repairs in game
---------------------------------------------------------------------------

local function nearFault(src, f)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    local range = (CF.RepairRange or 3.0) + (f.at_height and 1.0 or 0.0) + (f.asset.kind == 'tower' and 12.0 or 0.0)
    return #(c - vector3(f.x, f.y, f.z)) <= range
end

lib.callback.register('opslabs-towers:faults:diagnose', function(src, id)
    if not CanCable(src) then return { error = 'Only network engineers can work on faults' } end
    local f = Faults[tonumber(id)]
    if not f or not ACTIVE[f.status] then return { error = 'That fault has already been cleared' } end
    if not nearFault(src, f) then return { error = 'Get closer to the fault first' } end
    if f.status ~= 'in_progress' then
        f.status = 'in_progress'
        f.notes[#f.notes + 1] = { at = os.time(), by = GetPlayerName(src), text = 'On site, diagnosing' }
        save(f) push()
        TriggerEvent('opslabs-towers:faultUpdated', public(f))
    end
    return { ok = true, fault = public(f) }
end)

lib.callback.register('opslabs-towers:faults:repair', function(src, id)
    if not CanCable(src) then return { error = 'Only network engineers can work on faults' } end
    local f = Faults[tonumber(id)]
    if not f or not ACTIVE[f.status] then return { error = 'That fault has already been cleared' } end
    if not nearFault(src, f) then return { error = 'You moved away from the fault' } end
    if f.at_height and CF.RequireHarness ~= false then
        local h = Player(src).state.opsHarness
        if not (type(h) == 'table' and h.clipped and (not f.pole_id or h.pole == f.pole_id)) then
            return { error = 'Clip your harness on to this pole before you work at height' }
        end
    end
    if f.needs_guy and f.pole_id and GuyOnPole and not GuyOnPole(f.pole_id) then
        return { error = 'The pole needs a guild wire to the next pole before you can straighten it' }
    end
    finish(f, 'fixed', src, GetPlayerName(src), 'Repaired on site')
    print(('[opslabs-towers] %s repaired fault #%d (%s)'):format(GetPlayerName(src), f.id, f.type))
    return { ok = true }
end)
