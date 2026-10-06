-- ONT repair kit (Tool kit → OPS Openline fibre & telecom → ONT repair kit). At an ONT it inspects
-- everything that can stop the line working and fixes what can be fixed from the ONT itself:
--   swap      failed ONT (hardware fault) → new ONT + power supply, new serial, fault cleared
--   psu       power supply only (a failed ONT also gets this) — cosmetic when the ONT is fine
--   splice    fibre into the ONT not spliced / end lying beside it → fusion splice it in
--   patch     CAT6 from the router lying at the ONT not terminated → crimp + plug into the LAN port
--   reboot    power-cycle: ranging + PPP login start again (clears a stuck PON / login)
--   resume    a suspended service → resumed
--   provision no service → the provisioning menu (client)
-- Faults further up the line (broken span, wet CBT, dead cabinet...) can't be fixed here: they're
-- reported with where they are so the engineer can go and repair them.

local REACH = 3.5

local function ont(id)
    local f = Cabling.fixtures[tonumber(id) or -1]
    if f and f.model == ((Config.Isp or {}).Ont or 'opslabs_ont') then return f end
end

local function near(src, f)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(p - vector3(f.x, f.y, f.z)) <= REACH
end

local function d3(p, f) return math.sqrt((p.x - f.x) ^ 2 + (p.y - f.y) ^ 2 + (p.z - f.z) ^ 2) end

--- cable ends that belong in this ONT: { run, which, state = 'unterminated' | 'loose' | 'unattached' }
local function endsAt(f, kind)
    local out = {}
    for _, r in pairs(Cabling.runs) do
        if r.kind == kind and type(r.points) == 'table' and #r.points >= 1 then
            for _, which in ipairs({ 'start', 'end' }) do
                local attached = r[which .. '_fixture'] == f.id
                local p = which == 'start' and r.points[1] or r.points[#r.points]
                local close = p and d3(p, f) <= 1.2 and not r[which .. '_fixture'] and not r[which .. '_tower']
                if (attached or close) and not (which == 'start' and r.box_id) then
                    local state = (r.loose and r.loose[which]) and 'loose' or not attached and 'unattached' or not r[which .. '_term'] and 'unterminated' or 'ok'
                    out[#out + 1] = { run = r, which = which, state = state }
                end
            end
        end
    end
    return out
end

local function inspect(f)
    local s = (IspPayload and IspPayload()[f.id]) or {}
    local issues = {}
    local function add(t) issues[#issues + 1] = t end
    local dead = s.hardware == 'failed' or (FaultEffects and FaultEffects.fixtures[f.id] == 'dead')

    if dead then
        add({ id = 'hardware', sev = 'high', title = 'ONT has failed', text = 'POWER light off — the unit and its power supply need replacing.', action = 'swap', label = 'Replace the ONT + power supply', secs = 20 })
    end

    -- fibre into the ONT
    local fibres = endsAt(f, 'fibre')
    local hasGood = false
    for _, e in ipairs(fibres) do
        if e.state == 'ok' then hasGood = true
        elseif e.state == 'loose' then
            add({ id = 'fibre_loose', sev = 'high', title = ('Fibre #%d is lying loose'):format(e.run.id), text = 'The end was cut free. Pick it up and fix it to the wall first (walk to it and press E).' })
        else
            add({ id = 'fibre_' .. e.run.id, sev = 'high', title = ('Fibre #%d isn’t spliced into the ONT'):format(e.run.id),
                text = e.state == 'unattached' and 'Its end lies beside the ONT — strip, clean, cleave and fusion splice it in.' or 'Its end is at the ONT but was never spliced.',
                action = 'splice', arg = e.run.id .. ':' .. e.which, label = 'Fusion splice it into the ONT', secs = 14 })
        end
    end
    if #fibres == 0 then
        add({ id = 'no_fibre', sev = 'high', title = 'No fibre to this ONT', text = 'Run fibre (yellow patch / drop) from the CSP or splice tray to the ONT, then use the kit to splice it in.' })
    end

    -- light on the line: faults further up
    local up = FaultOnOnt and FaultOnOnt(f.id)
    local fb = up and FaultBrief and FaultBrief(up)
    if fb and not (fb.kind == 'fixture' and fb.fixture == f.id) then
        add({ id = 'upstream', sev = 'high', title = 'Fault up the line: ' .. (fb.label or 'network fault'),
            text = ('%s — it can’t be fixed from here. Go there and repair it (repair key).'):format(fb.asset or 'Somewhere upstream'),
            action = 'locate', arg = tostring(fb.id), label = 'Set a waypoint to the fault', x = fb.x, y = fb.y, instant = true })
    elseif hasGood and s.los and not dead then
        add({ id = 'los', sev = 'high', title = 'No light reaching the ONT', text = 'The fibre is spliced here but no light arrives: a break or an unspliced joint between the cabinet and this house. Use the VFL / OTDR on the route.' })
    end
    if s.lowLight and not dead then
        add({ id = 'lowlight', sev = 'medium', title = ('Light too weak (%s dBm)'):format(s.rx and string.format('%.1f', s.rx) or '?'), text = 'Below −28 dBm the ONT drops out. Clean and re-splice the ONT end; if it’s still low there are too many joints / a bad splice up the line.',
            action = 'resplice', label = 'Clean optics + re-splice the ONT pigtail', secs = 16 })
    end

    -- service
    local svc = IspServiceStatus and IspServiceStatus(f.id) or 'none'
    if not dead and not s.los then
        if svc == 'none' then
            add({ id = 'service', sev = 'medium', title = 'No broadband service on this line', text = 'The fibre is good but nothing is provisioned.', action = 'provision', label = 'Provision internet service', instant = true })
        elseif svc == 'suspended' then
            add({ id = 'suspended', sev = 'medium', title = 'Service suspended', text = (s.provider or 'The provider') .. ' has suspended this account.', action = 'resume', label = 'Resume the service', secs = 4 })
        elseif s.pon == 'on' and s.internet ~= 'on' then
            add({ id = 'login', sev = 'low', title = 'Not logged in yet', text = 'PON is up but the PPP login hasn’t finished. Reboot the ONT if it stays like this.', action = 'reboot', label = 'Reboot the ONT', secs = 8 })
        end
    end

    -- LAN
    local lans = endsAt(f, 'cable')
    local lanOk = false
    for _, e in ipairs(lans) do
        if e.state == 'ok' then lanOk = true
        elseif e.state ~= 'loose' then
            add({ id = 'lan_' .. e.run.id, sev = 'low', title = ('CAT6 #%d isn’t plugged into the LAN port'):format(e.run.id), text = 'Terminate it (T568B, crimp an RJ45) and plug it into the ONT.',
                action = 'patch', arg = e.run.id .. ':' .. e.which, label = 'Crimp an RJ45 and plug it in', secs = 10 })
        end
    end
    if not lanOk and #lans == 0 and s.internet == 'on' then
        add({ id = 'nolan', sev = 'low', title = 'No router on the LAN port', text = 'Internet is up at the ONT. Pull CAT6 from the ONT to the customer’s router.' })
    end
    return {
        id = f.id, serial = s.serial, provider = s.provider, plan = s.plan, rx = s.rx, service = svc,
        leds = { power = dead and 'off' or 'on', pon = s.pon or 'off', los = s.los and true or false, lan = s.lan or 'off', internet = s.internet or 'off' },
        issues = issues,
    }
end

lib.callback.register('opslabs-towers:ont:inspect', function(src, id)
    if not CanCable(src) then return { error = 'Only network engineers carry the ONT repair kit' } end
    local f = ont(id)
    if not f then return { error = 'That isn’t an ONT' } end
    if not near(src, f) then return { error = 'Get closer to the ONT' } end
    return inspect(f)
end)

local function terminate(r, which, fixtureId)
    r[which .. '_term'], r[which .. '_fixture'], r[which .. '_tower'] = true, fixtureId, nil
    MySQL.update.await(('UPDATE opslabs_towers_cables SET %s_term = 1, %s_fixture = ?, %s_tower = NULL WHERE id = ?'):format(which, which, which), { fixtureId, r.id })
end

local function endArg(f, arg, kind)
    local rid, which = tostring(arg or ''):match('^(%d+):(%a+)$')
    local r = Cabling.runs[tonumber(rid) or -1]
    if not r or r.kind ~= kind or (which ~= 'start' and which ~= 'end') then return nil, 'That cable has gone' end
    if r.loose and r.loose[which] then return nil, 'That end is lying loose — pick it up and fix it first' end
    if which == 'start' and r.box_id then return nil, 'Cut the cable from its box first' end
    local p = which == 'start' and r.points[1] or r.points[#r.points]
    if r[which .. '_fixture'] ~= f.id and (not p or d3(p, f) > 1.5) then return nil, 'That end isn’t at this ONT' end
    return r, which
end

lib.callback.register('opslabs-towers:ont:repair', function(src, id, action, arg)
    if not CanCable(src) then return { error = 'Only network engineers can repair ONTs' } end
    local f = ont(id)
    if not f then return { error = 'That isn’t an ONT' } end
    if not near(src, f) then return { error = 'You moved away from the ONT' } end
    local who = GetPlayerName(src)
    local text
    if action == 'swap' then
        local n = RepairFixtureFaults and RepairFixtureFaults(f.id, src, 'ONT and power supply replaced (ONT repair kit)') or 0
        local serial = IspNewSerial and IspNewSerial(f.id)
        if IspRebootOnt then IspRebootOnt(f.id) end
        text = ('New ONT fitted%s%s — it will range and log in now'):format(serial and (' · serial ' .. serial) or '', n > 0 and (' · %d fault%s cleared'):format(n, n == 1 and '' or 's') or '')
    elseif action == 'psu' then
        if IspRebootOnt then IspRebootOnt(f.id) end
        text = 'Power supply replaced — the ONT is starting up'
    elseif action == 'splice' or action == 'patch' then
        local r, which = endArg(f, arg, action == 'splice' and 'fibre' or 'cable')
        if not r then return { error = which } end
        terminate(r, which, f.id)
        if CablingChanged then CablingChanged() end
        text = action == 'splice' and ('Fibre #%d spliced into the ONT (0.05 dB)'):format(r.id) or ('CAT6 #%d plugged into the LAN port'):format(r.id)
    elseif action == 'resplice' then
        local n = RepairFixtureFaults and RepairFixtureFaults(f.id, src, 'ONT pigtail re-spliced (ONT repair kit)') or 0
        if IspRebootOnt then IspRebootOnt(f.id) end
        text = 'Optics cleaned and the ONT pigtail re-spliced' .. (n > 0 and ' · fault cleared' or '')
    elseif action == 'reboot' then
        if IspRebootOnt then IspRebootOnt(f.id) end
        text = 'ONT rebooting — PON flashes while it ranges, then INTERNET while it logs in'
    elseif action == 'resume' then
        if not IspSetStatus then return { error = 'Provisioning is offline' } end
        local ok, err = IspSetStatus(f.id, 'active')
        if not ok then return { error = err or 'Could not resume' } end
        text = 'Service resumed'
    else
        return { error = 'Unknown repair' }
    end
    print(('[opslabs-towers] %s ONT repair kit on ONT #%d: %s'):format(who, f.id, action))
    return { ok = true, text = text, after = inspect(f) }
end)
