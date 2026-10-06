-- OPS Data centres (client): draws what is installed in each rack (servers, storage, switches, blanking panels and a
-- status LED per unit) and the [E] rack menu — install, repair, power, roles. Server: server/datacentre.lua.

local DC = Config.DataCentre or {}
if not DC.Enabled then return end
local KINDS = DC.Kinds or {}
local GREEN, RED, ORANGE, BLUE, GREY, PURPLE = '#30d158', '#ff453a', '#ff9f0a', '#0a84ff', '#8e8e93', '#5e5ce6'
local LEDS = { [1] = 'opslabs_dc_led_ok', [2] = 'opslabs_dc_led_warn', [3] = 'opslabs_dc_led_bad' }
local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function err(r) lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end

---------------------------------------------------------------------------
-- rack contents
---------------------------------------------------------------------------
local spawned = {}           -- rack id -> { sig, ents = {} }

local function offset(f, lx, ly, lz)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return f.x + lx * c - ly * s, f.y + lx * s + ly * c, f.z + lz
end

local function obj(model, x, y, z, heading)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local t = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t < 3000 do Wait(0) end
    local e = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    SetEntityHeading(e, heading or 0.0)
    FreezeEntityPosition(e, true)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(hash)
    return e
end

local function clear(rid)
    local s = spawned[rid]
    if not s then return end
    for _, e in ipairs(s.ents) do if DoesEntityExist(e) then DeleteEntity(e) end end
    spawned[rid] = nil
end

local function draw(rid, f, list)
    clear(rid)
    local s = { sig = json.encode(list), ents = {} }
    for _, it in ipairs(list) do
        local u, kind, led = it[1], it[2], it[3]
        local k = KINDS[kind]
        if k then
            local z = (DC.U0 or 0.10) + (u - 1) * (DC.UH or 0.04445)
            local x, y, zz = offset(f, 0.0, DC.FrontY or -0.452, z)
            local e = obj(k.model, x, y, zz, f.heading)
            if e then s.ents[#s.ents + 1] = e end
            if LEDS[led] and (k.watts or 0) > 0 then
                local lx, ly, lz = offset(f, DC.LedX or -0.215, (DC.FrontY or -0.452) - 0.006, z + (DC.UH or 0.04445) * k.u / 2 - 0.004)
                local l = obj(LEDS[led], lx, ly, lz, f.heading)
                if l then s.ents[#s.ents + 1] = l end
            end
        end
    end
    spawned[rid] = s
end

CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local all = GlobalState.opsDcRacks or {}
        local fx = fixtures()
        local want = {}
        for sid, list in pairs(all) do
            local rid = tonumber(sid)
            local f = fx[rid]
            if f and f.model == DC.Rack and #(pos - vector3(f.x, f.y, f.z)) < 60.0 then
                want[rid] = true
                local s = spawned[rid]
                if not s or s.sig ~= json.encode(list) or not s.ents[1] or not DoesEntityExist(s.ents[1]) then draw(rid, f, list) end
            end
        end
        for rid in pairs(spawned) do if not want[rid] then clear(rid) end end
        Wait(1500)
    end
end)

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then for rid in pairs(spawned) do clear(rid) end end end)

---------------------------------------------------------------------------
-- [E] at a rack
---------------------------------------------------------------------------
local STATUS = { ok = { 'Running', GREEN }, degraded = { 'Degraded', ORANGE }, down = { 'Down', RED }, thermal = { 'Thermal shutdown', RED }, off = { 'Off', GREY } }
local POWER = { ups = 'UPS · mains', battery = 'UPS · ON BATTERY', mains = 'Mains (no UPS)', none = 'NO POWER' }
local RackMenu

local function unitMenu(v, unit)
    local st = STATUS[unit.status] or { unit.status, GREY }
    local o = {
        { title = unit.label, description = ('U%d%s · serial %s'):format(unit.u, unit.size > 1 and ('–' .. (unit.u + unit.size - 1)) or '', unit.serial or '?'), icon = 'server', readOnly = true },
        { title = st[1] .. (unit.reachable and ' · on the network' or (unit.status == 'off' and '' or ' · not reachable')), description = ('%d °C%s'):format(unit.temp or 0, unit.compute and (' · role: ' .. (v.roles[unit.role or 'cloud'] or unit.role or 'cloud')) or ''),
          icon = 'circle', iconColor = st[2], readOnly = true },
    }
    if unit.compute then o[#o + 1] = { title = ('%d cloud server(s) running here'):format(unit.vms or 0), icon = 'cloud', iconColor = BLUE, readOnly = true } end
    if unit.fault then
        o[#o + 1] = { title = 'Fault: ' .. (unit.faultLabel or unit.fault), description = v.staff and ('Fix it: ' .. (unit.fix or 'repair')) or 'An OPS Data engineer has been called', icon = 'triangle-exclamation', iconColor = RED,
            disabled = not v.staff, onSelect = function()
                if lib.progressBar({ duration = (unit.secs or 25) * 1000, label = unit.fix or 'Repairing', canCancel = true, disable = { move = true, car = true, combat = true },
                    anim = { dict = 'mini@repair', clip = 'fixing_a_ped' } }) then
                    local r = lib.callback.await('opslabs-towers:dc:repair', false, v.id, unit.u)
                    if r and r.ok then lib.notify({ type = 'success', description = 'Fixed — it’s coming back up' }) else err(r) end
                end
                RackMenu(v.id)
            end }
    end
    if v.staff then
        o[#o + 1] = { title = unit.off and 'Power on' or 'Power off', icon = 'power-off', iconColor = unit.off and GREEN or ORANGE, onSelect = function()
            local r = lib.callback.await('opslabs-towers:dc:power', false, v.id, unit.u, unit.off == true)
            if not (r and r.ok) then err(r) end
            Wait(300) RackMenu(v.id)
        end }
        if unit.compute then
            o[#o + 1] = { title = 'Change role', description = 'What this server runs', icon = 'sliders', arrow = true, onSelect = function()
                local opts = {}
                for code, label in pairs(v.roles or {}) do
                    opts[#opts + 1] = { title = label, icon = code == (unit.role or 'cloud') and 'circle-check' or 'circle', iconColor = PURPLE, onSelect = function()
                        local r = lib.callback.await('opslabs-towers:dc:role', false, v.id, unit.u, code)
                        if r and r.ok then lib.notify({ type = 'success', description = 'Role set: ' .. label }) else err(r) end
                        RackMenu(v.id)
                    end }
                end
                lib.registerContext({ id = 'dc_role', title = 'Role · U' .. unit.u, menu = 'dc_unit', options = opts })
                lib.showContext('dc_role')
            end }
        end
        o[#o + 1] = { title = 'Remove from the rack', description = unit.vms and unit.vms > 0 and 'Its cloud servers will be restarted elsewhere' or nil, icon = 'trash-can', iconColor = RED, onSelect = function()
            if lib.alertDialog({ header = 'Remove ' .. unit.label .. '?', content = 'U' .. unit.u .. ' · ' .. (unit.serial or ''), centered = true, cancel = true }) ~= 'confirm' then return RackMenu(v.id) end
            if lib.progressBar({ duration = 8000, label = 'Un-racking', canCancel = true, disable = { move = true }, anim = { dict = 'mini@repair', clip = 'fixing_a_ped' } }) then
                local r = lib.callback.await('opslabs-towers:dc:remove', false, v.id, unit.u)
                if not (r and r.ok) then err(r) end
            end
            RackMenu(v.id)
        end }
    end
    lib.registerContext({ id = 'dc_unit', title = ('U%d · %s'):format(unit.u, unit.kind), menu = 'dc_rack', options = o })
    lib.showContext('dc_unit')
end

local function installMenu(v)
    local o = {}
    local order = { 'srv1u', 'srv2u', 'storage', 'switch', 'fw', 'blank' }
    for _, kind in ipairs(order) do
        local k = v.kinds[kind]
        if k then
            o[#o + 1] = { title = k.label, description = ('%dU · %d W%s'):format(k.u, k.watts or 0, k.vcpu and (' · %d cores · %d GB'):format(k.vcpu, k.ram) or ''), icon = k.switch and 'network-wired' or k.firewall and 'shield-halved' or k.tb and 'hard-drive' or 'server',
                iconColor = PURPLE, onSelect = function()
                    local input = lib.inputDialog('Install ' .. k.label, { { type = 'number', label = 'Bottom unit (U1–U42) — empty = first free from the top', min = 1, max = DC.Units or 42 } })
                    if input == nil then return RackMenu(v.id) end
                    if lib.progressBar({ duration = 6000 + k.u * 2000, label = 'Racking ' .. k.label, canCancel = true, disable = { move = true, combat = true }, anim = { dict = 'mini@repair', clip = 'fixing_a_ped' } }) then
                        local r = lib.callback.await('opslabs-towers:dc:install', false, v.id, kind, input[1])
                        if r and r.ok then lib.notify({ type = 'success', description = ('Installed in U%d · %s'):format(r.u, r.serial) }) else err(r) end
                    end
                    RackMenu(v.id)
                end }
        end
    end
    lib.registerContext({ id = 'dc_install', title = ('Install · %d U free'):format(v.free or 0), menu = 'dc_rack', options = o })
    lib.showContext('dc_install')
end

RackMenu = function(rid)
    local v = lib.callback.await('opslabs-towers:dc:rack', false, rid)
    if not v then return err({ error = 'Rack not found' }) end
    local hot = v.temp and v.temp >= (DC.TempWarn or 32)
    local o = {
        { title = POWER[v.power] or v.power, description = (v.ups and v.ups > 0) and ('UPS battery %d%%'):format(v.charge or 0) or 'No UPS in this hall — a power cut drops the rack',
          icon = v.power == 'battery' and 'car-battery' or 'plug', iconColor = (v.power == 'none' or v.power == 'battery') and RED or GREEN, readOnly = true },
        { title = v.online and 'Online' or 'Offline', description = v.online and 'Switch up, uplinked to the internet' or 'Needs a working ToR switch here and CAT6 from the rack to a router with internet',
          icon = 'network-wired', iconColor = v.online and GREEN or RED, readOnly = true },
        { title = ('Hall %s °C'):format(v.temp or '?'), description = ('%.1f kW of servers · %d kW cooling'):format(v.load or 0, v.cooling or 0), icon = 'temperature-half', iconColor = hot and RED or BLUE, readOnly = true },
    }
    for _, unit in ipairs(v.units) do
        local st = STATUS[unit.status] or { unit.status, GREY }
        o[#o + 1] = { title = ('U%d · %s'):format(unit.u, unit.label), description = ('%s%s · %d °C%s'):format(st[1], unit.fault and (' · ' .. (unit.faultLabel or unit.fault)) or '', unit.temp or 0, unit.compute and ((' · %d VM'):format(unit.vms or 0)) or ''),
            icon = 'circle', iconColor = unit.fault and RED or st[2], arrow = true, onSelect = function() unitMenu(v, unit) end }
    end
    if #v.units == 0 then o[#o + 1] = { title = 'Empty rack', description = 'Install a ToR switch first, then servers', icon = 'box-open', readOnly = true } end
    if v.staff then
        o[#o + 1] = { title = 'Install kit', description = ('%d U free'):format(v.free or 0), icon = 'plus', iconColor = GREEN, arrow = true, onSelect = function() installMenu(v) end }
        o[#o + 1] = { title = 'Name & region', description = ('%s · %s'):format(v.name, v.region or '?'), icon = 'pen', onSelect = function()
            local input = lib.inputDialog('Rack', { { type = 'input', label = 'Name', default = v.name, max = 40 }, { type = 'input', label = 'Region (cloud zone)', default = v.region, max = 16 } })
            if input then
                local r = lib.callback.await('opslabs-towers:dc:config', false, v.id, input[1], input[2])
                if not (r and r.ok) then err(r) end
            end
            RackMenu(v.id)
        end }
    end
    lib.registerContext({ id = 'dc_rack', title = ('%s · %s'):format(v.name, v.region or ''), options = o })
    lib.showContext('dc_rack')
end

CreateThread(function()
    local shown
    while true do
        local sleep = 700
        local ped = PlayerPedId()
        if not IsPedInAnyVehicle(ped, false) then
            local pos = GetEntityCoords(ped)
            local best, bd
            for id, f in pairs(fixtures()) do
                if f.model == DC.Rack and math.abs(f.x - pos.x) < 4 and math.abs(f.y - pos.y) < 4 then
                    local fx, fy = offset(f, 0.0, -0.7, 1.0)
                    local d = #(pos - vector3(fx, fy, f.z + 1.0))
                    if d < 1.6 and (not bd or d < bd) then best, bd = id, d end
                end
            end
            if best then
                sleep = 0
                if not shown then lib.showTextUI('[E] Server rack', { icon = 'server' }) shown = true end
                if IsControlJustPressed(0, 38) then lib.hideTextUI() shown = nil RackMenu(best) Wait(400) end
            elseif shown then lib.hideTextUI() shown = nil end
        elseif shown then lib.hideTextUI() shown = nil end
        Wait(sleep)
    end
end)
