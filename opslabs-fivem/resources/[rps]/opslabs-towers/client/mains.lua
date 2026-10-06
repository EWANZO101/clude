-- Mains electricity on the client: lights that come on, plug tops + flex leads drawn from plug-in kit to the
-- outlet it's plugged into, [E] at sockets / switches / consumer units / generators / meters / EV chargers,
-- EV charging, and ChargerNear() for opslabs-phone (is there a live phone charger beside me?).
-- What is live is worked out on the server (server/mains.lua) and pushed here.

local CM = Config.Mains or {}
if CM.Enabled == false then return end
local CS = Config.Solar or {}

-- the server has no game clock: it asks us (daylight for solar panels)
lib.callback.register('opslabs-towers:clock', function() return GetClockHours() + GetClockMinutes() / 60 end)

local Mains = {}        -- fixture id -> { live, off, plug, slot, unplugged, on }
local LaptopPw = {}     -- laptop fixture id -> { level, charging, plugged }

local function apply(p)
    Mains, LaptopPw = {}, {}
    for k, v in pairs(p or {}) do
        if type(k) == 'string' and k:sub(1, 1) == 'L' then
            LaptopPw[tonumber(k:sub(2))] = { level = v[1], charging = v[2] == 1, plugged = v[3] == 1 }
        else
            local live, off = v[1] == 1, v[2] == 1
            Mains[tonumber(k)] = { live = live, off = off, on = live and not off, plug = v[3] ~= 0 and v[3] or nil, slot = v[4], unplugged = v[5] == 1 }
        end
    end
end
RegisterNetEvent('opslabs-towers:mains', apply)
CreateThread(function()
    Wait(2000)
    apply(lib.callback.await('opslabs-towers:mains:state', false))
end)

function MainsLive(id) local s = Mains[id] return s and s.on or false end

--- street lights (client/lighting.lua): lit only with a live pole transformer within reach
local TX_MODEL = (Config.Grid or {}).Transformer or 'opslabs_power_transformer'
function StreetLightSupplied(f)
    for id, t in pairs(CablingFixtures and CablingFixtures() or {}) do
        if t.model == TX_MODEL and Mains[id] and Mains[id].live and math.abs(t.x - f.x) < 150 and math.abs(t.y - f.y) < 150
            and #(vector2(t.x, t.y) - vector2(f.x, f.y)) < 150.0 then return true end
    end
    return false
end
--- a built building has power when a live consumer unit sits inside it (Config.Power.BuildingReach)
local SUB_BUILDING = { opslabs_grid_subbuilding = true, opslabs_grid_subshell = true }
function BuildingPowered(f)
    -- substation buildings run off their own station supply when the 11 kV bus is live
    if SUB_BUILDING[f.model] and (GlobalState.gridSubsLive or {})[tostring(f.id)] then return true end
    local reach = ((Config.Power or {}).BuildingReach or {})[f.model] or 10.0
    for id, t in pairs(CablingFixtures and CablingFixtures() or {}) do
        if t.model == CM.ConsumerUnit and Mains[id] and Mains[id].live and math.abs(t.x - f.x) < reach and math.abs(t.y - f.y) < reach
            and #(vector3(t.x, t.y, t.z) - vector3(f.x, f.y, f.z)) < reach + 4.0 then return true end
    end
    return false
end
function LaptopPower(id) return LaptopPw[id] end

local function fixtures() return CablingFixtures and CablingFixtures() or {} end

--- a point in a fixture's own frame, in the world (and a direction, rotated only)
local function worldOf(f, o)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return vector3(f.x + o[1] * c - o[2] * s, f.y + o[1] * s + o[2] * c, f.z + o[3])
end
local function dirOf(f, o)
    local h = math.rad(f.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return vector3(o[1] * c - o[2] * s, o[1] * s + o[2] * c, o[3])
end

local function outletOf(fid, slot)
    local f = fixtures()[fid]
    if not f then return nil end
    local def = CM.Wired[f.model] or CM.PlugIn[f.model]
    local list = (def and def.o) or (f.model == CM.Generator and CM.GeneratorOutlets) or nil
    local o = list and list[slot]
    if not o then return nil end
    return worldOf(f, o), dirOf(f, { o[4], o[5], o[6] }), f
end

---------------------------------------------------------------------------
-- phone charging (opslabs-phone asks every few seconds)
---------------------------------------------------------------------------

--- 'wired' / 'wireless' when a live phone charger (or a USB socket) is within reach, else nil
local function chargerNear()
    local pos = GetEntityCoords(PlayerPedId())
    local reach = CM.PhoneChargeDistance or 1.2
    local best
    for id, f in pairs(fixtures()) do
        local def = CM.PlugIn[f.model]
        local wired = CM.Wired[f.model]
        if (def and def.charger) or (wired and wired.usb) then
            local s = Mains[id]
            if s and s.on and #(pos - vector3(f.x, f.y, f.z)) <= reach + 0.8 then
                local kind = def and def.charger or 'wired'
                if kind == 'wired' then return 'wired' end
                best = kind
            end
        end
    end
    return best
end
exports('ChargerNear', chargerNear)

--- the nearest wireless charger (Qi pad / stand) within reach, live or not: opslabs-phone puts a phone down on it
--- → { id, model, x, y, z, heading, live } or nil
local function wirelessChargerNear(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local reach = maxDist or ((CM.PhoneChargeDistance or 1.2) + 0.8)
    local best, bestD
    for id, f in pairs(fixtures()) do
        local def = CM.PlugIn[f.model]
        if def and def.charger == 'wireless' then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d <= reach and (not bestD or d < bestD) then
                local s = Mains[id]
                best, bestD = { id = id, model = f.model, x = f.x, y = f.y, z = f.z, heading = f.heading or 0.0, live = s and s.on or false }, d
            end
        end
    end
    return best
end
exports('WirelessChargerNear', wirelessChargerNear)
exports('IsMainsLive', MainsLive)

---------------------------------------------------------------------------
-- lights + glow models, plug tops + leads
---------------------------------------------------------------------------

local glows = {}        -- fixture id -> entity
local leads = {}        -- fixture id -> { sig, ents }
local lamps = {}        -- { pos, range, brightness } drawn every frame

local function spawnGlow(f)
    local h = joaat(f.model .. '_on')
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    local e = CreateObjectNoOffset(h, f.x, f.y, f.z, false, false, false)
    SetEntityHeading(e, f.heading or 0.0)
    SetEntityCoordsNoOffset(e, f.x, f.y, f.z, false, false, false)
    FreezeEntityPosition(e, true)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(h)
    return e
end

local function dropList(list) for _, e in ipairs(list or {}) do if DoesEntityExist(e) then DeleteEntity(e) end end end

local PIECES = { { 2.0, '200' }, { 1.0, '100' }, { 0.5, '050' }, { 0.25, '025' }, { 0.1, '010' }, { 0.05, '005' } }

--- a flex lead hanging from a to b (sags a little, never below the lower end by more than the sag)
local function drawLead(list, a, b, colour)
    local prefix = ('opslabs_power_%s_'):format(colour)
    local span = #(b - a)
    local sag = math.min(0.25, 0.04 + span * 0.08)
    local n = math.max(2, math.min(10, math.floor(span / 0.25) + 2))
    local prev = a
    for i = 1, n do
        local t = i / n
        local p = a + (b - a) * t - vector3(0.0, 0.0, sag * 4 * t * (1 - t))
        local d = p - prev
        if #d > 0.01 then
            CableFillLine(list, prev, p, vector3(0.0, 0.0, 1.0), PIECES, prefix)   -- the placer squares 'up' off itself
            if i < n then CablePlace(list, prefix:sub(1, -2) .. '_joint', p, vector3(0.0, 1.0, 0.0), vector3(0.0, 0.0, 1.0)) end
        end
        prev = p
    end
end

local function buildLead(f, s)
    local def = CM.PlugIn[f.model]
    local pos, n = outletOf(s.plug, s.slot)
    if not pos then return {} end
    local list = {}
    local up = math.abs(n.z) > 0.9 and dirOf(f, { 0.0, -1.0, 0.0 }) or vector3(0.0, 0.0, 1.0)
    CablePlace(list, def.plug or 'opslabs_mains_plug', pos, -n, up)
    local exit
    if (def.plug or ''):find('usb') then exit = pos + n * 0.03 - up * 0.016
    else exit = pos + n * 0.012 - up * 0.045 end
    drawLead(list, exit, worldOf(f, def.lead_at or { 0, 0, 0 }), def.lead or 'flex')
    return list
end

CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local wantGlow, wantLead, list = {}, {}, {}
        for id, f in pairs(fixtures()) do
            local def = CM.Wired[f.model] or CM.PlugIn[f.model]
            if def then
                local d = #(pos - vector3(f.x, f.y, f.z))
                local s = Mains[id]
                if def.lamp and s and s.on and d < 60.0 then
                    wantGlow[id] = f
                    local L = def.light
                    if L then list[#list + 1] = { p = worldOf(f, L), range = L[4], bright = L[5], d = d } end
                end
                if CM.PlugIn[f.model] and s and s.plug and d < (CM.LeadDrawDistance or 40.0) then
                    local o = fixtures()[s.plug]
                    if o then
                        local sig = ('%d:%d:%.2f:%.2f:%.2f:%.1f|%.2f:%.2f:%.2f:%.1f'):format(s.plug, s.slot or 0, f.x, f.y, f.z, f.heading or 0, o.x, o.y, o.z, o.heading or 0)
                        wantLead[id] = sig
                        if not leads[id] or leads[id].sig ~= sig then
                            if leads[id] then dropList(leads[id].ents) end
                            leads[id] = { sig = sig, ents = buildLead(f, s) }
                        end
                    end
                end
            end
        end
        for id, e in pairs(glows) do if not wantGlow[id] then if DoesEntityExist(e) then DeleteEntity(e) end glows[id] = nil end end
        for id, f in pairs(wantGlow) do if not glows[id] then glows[id] = spawnGlow(f) end end
        for id, l in pairs(leads) do if not wantLead[id] then dropList(l.ents) leads[id] = nil end end
        table.sort(list, function(a, b) return a.d < b.d end)
        for i = 17, #list do list[i] = nil end
        lamps = list
        Wait(1000)
    end
end)

CreateThread(function()
    while true do
        if #lamps == 0 then Wait(500) else
            for _, l in ipairs(lamps) do
                DrawLightWithRange(l.p.x, l.p.y, l.p.z, 255, 244, 228, l.range, l.bright)
            end
            Wait(0)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, e in pairs(glows) do if DoesEntityExist(e) then DeleteEntity(e) end end
    for _, l in pairs(leads) do dropList(l.ents) end
end)

---------------------------------------------------------------------------
-- [E] at kit
---------------------------------------------------------------------------

local TOUCH = { opslabs_solar_inverter = 0.3, opslabs_solar_battery = 0.6, opslabs_solar_dciso = 0.07, opslabs_mains_meterbox = 0.3, opslabs_mains_generator = 0.3, opslabs_mains_ev_post = 1.25, opslabs_mains_ev_wall = 0.17,
    opslabs_mains_cu = 0.11, opslabs_mains_meter = 0.1, opslabs_mains_cutout = 0.12, opslabs_mains_isolator = 0.06 }

local evSession = nil   -- { id, veh }

local function promptFor(id, f)
    local s = Mains[id] or {}
    local wired, plug = CM.Wired[f.model], CM.PlugIn[f.model]
    if f.model == CM.Generator then return s.live and '[E] Stop the generator' or '[E] Start the generator', 'gas-pump' end
    if f.model == CS.Inverter or f.model == CS.Battery then return f.model == CS.Inverter and '[E] Inverter readout' or '[E] Battery readout', 'solar-panel' end
    if CM.Meters[f.model] then return '[E] Read the meter', 'gauge-high' end
    if f.model == CM.ConsumerUnit then
        return ('Consumer unit · %s · [E] main switch %s'):format(not s.live and 'no supply' or s.off and 'OFF' or 'ON', s.off and 'on' or 'off'), 'toggle-on'
    end
    if CM.Switchable[f.model] then return ('Isolator %s · [E] %s'):format(s.off and 'OFF' or 'ON', s.off and 'switch on' or 'isolate'), 'power-off' end
    if wired and wired.lightSwitch then return '[E] Lights', 'lightbulb' end
    if wired and wired.ev then
        if evSession and evSession.id == id then return '[E] Stop charging', 'car-battery' end
        return s.on and '[E] Charge a vehicle' or 'EV charger · no power', 'car-battery'
    end
    if wired and (wired.o or f.model == 'opslabs_mains_spur') then
        return ('%s · [E] switch %s'):format(not s.live and 'No power' or s.off and 'Off' or 'Live', s.off and 'on' or 'off'), 'plug'
    end
    if plug and plug.switch then
        return ('%s · [E] switch %s'):format(not s.plug and 'Not plugged in' or not s.live and 'No power' or s.off and 'Off' or 'On', s.off and 'on' or 'off'), 'plug'
    end
    if plug then
        if s.unplugged then return '[E] Plug in', 'plug' end
        return ('%s · [E] unplug'):format(not s.plug and 'No socket in reach' or s.live and 'Charging point live' or 'No power'), 'plug'
    end
    return nil
end

local function nearestKit()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, f in pairs(fixtures()) do
        local m = f.model
        if CM.Wired[m] or CM.PlugIn[m] or CM.Switchable[m] or CM.Meters[m] or m == CM.Generator or m == CS.Inverter or m == CS.Battery then
            local def = CM.Wired[m]
            if not (def and def.lamp) then           -- ceiling lights work from a light switch
                local c = vector3(f.x, f.y, f.z + (TOUCH[m] or 0.05))
                local d = #(vector2(pos.x, pos.y) - vector2(c.x, c.y))
                if d < (bd or (CM.UseDistance or 1.3)) and math.abs(pos.z - c.z) < 2.0 then best, bd = id, d end
            end
        end
    end
    return best
end

local function stopEv(msg)
    if not evSession then return end
    lib.callback('opslabs-towers:mains:ev', false, function() end, evSession.id, false)
    evSession = nil
    if msg then lib.notify({ type = 'inform', description = msg }) end
end

local function setFuel(veh, level)
    SetVehicleFuelLevel(veh, level + 0.0)
    Entity(veh).state:set('fuel', level + 0.0, true)
    if GetResourceState('LegacyFuel') == 'started' then pcall(function() exports.LegacyFuel:SetFuel(veh, level + 0.0) end) end
end

local function startEv(id, f)
    local c = vector3(f.x, f.y, f.z)
    local veh, vd
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(v) - c)
        if d < (vd or ((CM.EV or {}).CarDistance or 6.0)) then veh, vd = v, d end
    end
    if not veh then return lib.notify({ type = 'error', description = 'Park a car beside the charger first' }) end
    local r = lib.callback.await('opslabs-towers:mains:ev', false, id, true)
    if not r or r.error then return lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    evSession = { id = id, veh = veh }
    lib.notify({ type = 'success', description = 'Charging — the cable is plugged into the car' })
    CreateThread(function()
        local ping = GetGameTimer()
        while evSession and evSession.id == id do
            Wait(1000)
            if not evSession then break end
            if not DoesEntityExist(veh) or #(GetEntityCoords(veh) - c) > ((CM.EV or {}).CarDistance or 6.0) + 2.0 then stopEv('Charging stopped — the car moved away') break end
            if not MainsLive(id) then stopEv('Charging stopped — the charger lost power') break end
            local level = math.min(100.0, GetVehicleFuelLevel(veh) + ((CM.EV or {}).Rate or 0.8))
            setFuel(veh, level)
            if level >= 100.0 then stopEv('Fully charged') break end
            if GetGameTimer() - ping > 10000 then
                ping = GetGameTimer()
                lib.callback('opslabs-towers:mains:ev', false, function() end, id, true)
            end
        end
    end)
end

CreateThread(function()
    local shown = nil
    while true do
        local ped = PlayerPedId()
        local id = not IsPedInAnyVehicle(ped, false) and not IsPauseMenuActive() and not NearLaptopId and nearestKit() or nil
        local f = id and fixtures()[id]
        local text, icon
        if f then text, icon = promptFor(id, f) end
        if text then
            if evSession and evSession.id == id and DoesEntityExist(evSession.veh) then
                text = ('Charging %d%% · [E] stop'):format(math.floor(GetVehicleFuelLevel(evSession.veh)))
            end
            if shown ~= text then lib.showTextUI(text, { icon = icon or 'plug' }) shown = text end
            if IsControlJustPressed(0, 38) then
                if f.model == CS.Inverter or f.model == CS.Battery then
                    local r = lib.callback.await('opslabs-towers:mains:solar', false, id)
                    if not r then lib.notify({ type = 'error', description = f.model == CS.Battery and 'This battery isn’t next to an inverter' or 'No reading yet' })
                    else
                        lib.notify({ title = 'San Andreas Solar', type = 'inform', duration = 9000, description = ('Solar %.2f kW of %.1f kWp (%d panel%s)%s · %s%s'):format(
                            (r.gen or 0) / 1000, (r.peak or 0) / 1000, r.panels or 0, (r.panels or 0) == 1 and '' or 's', r.isolated and ' · DC ISOLATED' or '',
                            r.soc and ('battery %d%% (%.1f kWh)'):format(math.floor(r.soc / r.cap * 100 + 0.5), r.soc) or 'no battery',
                            r.on and ' · supplying the house' or ' · not supplying') })
                    end
                elseif CM.Meters[f.model] then
                    local r = lib.callback.await('opslabs-towers:mains:read', false, id)
                    if r then
                        lib.notify({ title = 'Electricity meter', type = 'inform', duration = 7000,
                            description = ('%09.1f kWh · using %.2f kW now%s'):format(r.kwh, (r.watts or 0) / 1000, r.live and '' or ' · NO SUPPLY') })
                    end
                elseif CM.Wired[f.model] and CM.Wired[f.model].ev then
                    if evSession and evSession.id == id then stopEv('Charging stopped') else startEv(id, f) end
                else
                    local r = lib.callback.await('opslabs-towers:mains:toggle', false, id)
                    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' })
                    else lib.notify({ type = 'inform', description = r.text }) end
                end
                Wait(300)
            end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(400)
        end
    end
end)

---------------------------------------------------------------------------
-- city blackout (Config.Power.CityBlackout): GTA's buildings and lamps have no power; cars keep their lights
---------------------------------------------------------------------------
CreateThread(function()
    if not (Config.Power or {}).CityBlackout then return end
    while true do
        SetArtificialLightsState(true)
        SetArtificialLightsStateAffectsVehicles(false)
        Wait(2000)
    end
end)
