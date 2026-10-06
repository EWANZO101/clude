-- OPS Track (client): fit a GPS tracker inside a vehicle step by step (under the dash, with the installer tool case),
-- check its LEDs, cut / reconnect its power, the immobiliser, and /track for owners. Server: server/track.lua.

local CT = Config.Track or {}
if not CT.Enabled then return end
local UNITS = CT.Units or {}
local GREEN, RED, ORANGE, BLUE, GREY = '#30d158', '#ff453a', '#ff9f0a', '#0a84ff', '#8e8e93'

local function plateOf(v) return (GetVehicleNumberPlateText(v) or ''):gsub('^%s+', ''):gsub('%s+$', ''):upper() end
local function err(r) lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
local function myVehicle()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh ~= 0 then return veh end
    return nil
end
local function vehName(v) return GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(v))) end
local function volts(v) local c = GetVehicleClass(v) return (c == 10 or c == 20 or c == 17 or c == 19) and 24 or 12 end

---------------------------------------------------------------------------
-- immobiliser: a wired Pro unit holding the starter relay open
---------------------------------------------------------------------------
CreateThread(function()
    local told = 0
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and Entity(veh).state.opsImmob and GetEntitySpeed(veh) < 2.0 then
            SetVehicleEngineOn(veh, false, true, true)
            if GetGameTimer() - told > 8000 then told = GetGameTimer() lib.notify({ type = 'error', description = 'The engine cranks but won’t start (immobilised)', icon = 'lock' }) end
            Wait(0)
        else Wait(400) end
    end
end)

---------------------------------------------------------------------------
-- install: real steps, each with its tools
---------------------------------------------------------------------------
local STEPS = {
    { id = 'trim', title = 'Remove the dash lower trim', tools = 'Trim-removal tools · screwdriver set', ms = 7000, both = true },
    { id = 'meter', title = 'Find permanent +, ignition + and a good earth', tools = 'Multimeter', ms = 8000, both = true, reading = true },
    { id = 'fuse', title = 'Fit the fuse tap / inline fuse holder', tools = 'Fuse tap · inline fuse holder · crimping tool', ms = 6000, both = true },
    { id = 'loom', title = 'Strip, crimp & heat-shrink the loom', tools = 'Wire cutters / strippers · crimping tool · heat-shrink tubing', ms = 9000, pro = true },
    { id = 'io', title = 'Wire inputs & output: ignition sense, door switch, immobiliser relay in the starter feed', tools = 'Wire strippers · crimping tool · multimeter', ms = 10000, pro = true },
    { id = 'mount', title = 'Mount the tracking unit out of sight', tools = 'Cable ties · small socket set (drill only if the bracket needs it)', ms = 7000, both = true },
    { id = 'battery', title = 'Fit the backup battery', tools = 'Cable ties · electrical tape', ms = 5000, pro = true },
    { id = 'ant', title = 'Route the GPS / LTE antenna under the dash top (sky view)', tools = 'Trim-removal tools · cable ties', ms = 7000, pro = true },
    { id = 'tidy', title = 'Tape and tie the loom away from moving parts', tools = 'Electrical tape · cable ties', ms = 5000, both = true },
    { id = 'test', title = 'Power up: check PWR / GNSS / GSM LEDs and the first report', tools = 'Multimeter · phone (OPS Track app / hub)', ms = 6000, both = true, final = true },
    { id = 'refit', title = 'Refit the trim and hand it over', tools = 'Trim-removal tools · screwdriver set', ms = 6000, both = true },
}
local job = nil          -- { veh, plate, unit, done = { id = true }, case = entity }

local function stepsFor(unit)
    local out = {}
    for _, s in ipairs(STEPS) do if s.both or (s.pro and UNITS[unit] and UNITS[unit].io) then out[#out + 1] = s end end
    return out
end

local function dropCase(veh)
    local m = joaat('opslabs_trk_toolcase')
    if not IsModelInCdimage(m) then return nil end
    lib.requestModel(m)
    local p = GetOffsetFromEntityInWorldCoords(veh, -1.6, 0.6, 0.0)
    local _, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
    local o = CreateObject(m, p.x, p.y, (gz and gz > 0 and gz or p.z - 0.4), false, false, false)
    SetEntityHeading(o, GetEntityHeading(veh) + 90.0)
    FreezeEntityPosition(o, true)
    SetModelAsNoLongerNeeded(m)
    return o
end
local function endJob()
    if job and job.case and DoesEntityExist(job.case) then DeleteEntity(job.case) end
    job = nil
end

local function ledReport(veh, info)
    local unit = info and UNITS[info.unit] or {}
    local inside = GetInteriorFromEntity(PlayerPedId()) ~= 0
    local pwr = not info and 'off' or (info.cut and (info.online and 'flashing (backup battery)' or 'off')) or 'on'
    local gnss = not info and 'off' or not info.online and 'off' or inside and 'flashing (searching — no sky view)' or 'solid (fix)'
    local gsm = not info and 'off' or not info.online and 'off' or (info.bars or 0) > 0 and ('solid (OPS Mobile %d/4)'):format(info.bars) or 'flashing (no signal)'
    return { ('**PWR** %s'):format(pwr), ('**GNSS** %s'):format(gnss), ('**GSM** %s'):format(gsm),
        info and ('IMEI %s · %s'):format(info.imei or '?', unit.label or info.unit) or 'No tracker found in this vehicle',
        info and info.at and ('Last report: %s'):format(info.pending and 'waiting for signal' or 'live') or '' }
end

local function installMenu()
    if not job then return end
    local veh, steps = job.veh, stepsFor(job.unit)
    if not DoesEntityExist(veh) or GetVehiclePedIsIn(PlayerPedId(), false) ~= veh then
        lib.notify({ type = 'error', description = 'Get back in the vehicle to carry on the install' }) return
    end
    local options = {}
    local nextUp = nil
    for _, s in ipairs(steps) do if not job.done[s.id] then nextUp = s.id break end end
    for i, s in ipairs(steps) do
        local done = job.done[s.id]
        options[#options + 1] = { title = ('%d. %s'):format(i, s.title), description = s.tools, icon = done and 'circle-check' or (s.id == nextUp and 'screwdriver-wrench' or 'circle'),
            iconColor = done and GREEN or (s.id == nextUp and BLUE or GREY), disabled = s.id ~= nextUp, onSelect = function()
                if not lib.progressBar({ duration = s.ms, label = s.title, canCancel = true, disable = { move = true, car = true, combat = true },
                    anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 } }) then return installMenu() end
                if s.reading then
                    local v = volts(veh)
                    lib.alertDialog({ header = 'Multimeter', centered = true, content = ('Permanent feed: **%.1f V** (%d V system)  \nIgnition feed: **0.0 V** off · **%.1f V** on  \nEarth to chassis: **0.1 Ω**  \nUse a %s fuse in the tap.'):format(v + 0.6, v, v + 1.8, v == 24 and '3 A' or '5 A') })
                end
                if s.final then
                    local r = lib.callback.await('opslabs-towers:track:install', false, job.plate, job.unit, vehName(veh), nil)
                    if not r or r.error then err(r) return installMenu() end
                    job.imei = r.imei
                    Wait(1500)
                    local info = lib.callback.await('opslabs-towers:track:get', false, job.plate)
                    lib.alertDialog({ header = 'Tracker powered up · IMEI ' .. r.imei, centered = true, content = table.concat(ledReport(veh, info), '  \n') ..
                        (r.owner and ('  \nLinked to ' .. r.owner .. ' — they can use /track') or '  \nNo registered owner found for this plate') })
                end
                job.done[s.id] = true
                if s.id == steps[#steps].id then
                    lib.notify({ type = 'success', description = ('%s fitted to %s (%s)'):format(UNITS[job.unit].label, vehName(veh), job.plate), duration = 8000 })
                    endJob()
                    return
                end
                installMenu()
            end }
    end
    options[#options + 1] = { title = 'Stop the install', description = 'Put the tools away (start again later)', icon = 'xmark', iconColor = RED, onSelect = endJob }
    lib.registerContext({ id = 'track_install', title = ('Installing %s · %s'):format(UNITS[job.unit].label, job.plate), options = options })
    lib.showContext('track_install')
end

function TrackInstall()
    local veh = myVehicle()
    if not veh then return lib.notify({ type = 'error', description = 'Sit in the vehicle — trackers go in under the dash' }) end
    if GetEntitySpeed(veh) > 1.0 then return lib.notify({ type = 'error', description = 'Stop the vehicle first' }) end
    local plate = plateOf(veh)
    if job and job.plate == plate then return installMenu() end
    local existing = lib.callback.await('opslabs-towers:track:get', false, plate)
    if existing then return lib.notify({ type = 'inform', description = ('%s already has a tracker (IMEI %s)'):format(plate, existing.imei or '?') }) end
    local opts = {}
    for id, u in pairs(UNITS) do opts[#opts + 1] = { value = id, label = u.label .. ' — ' .. u.sub } end
    table.sort(opts, function(a, b) return a.value > b.value end)
    local v = lib.inputDialog(('Fit a tracker · %s (%s) · %d V'):format(vehName(veh), plate, volts(veh)), { { type = 'select', label = 'Unit', options = opts, default = 'pro', required = true } })
    if not v then return end
    endJob()
    job = { veh = veh, plate = plate, unit = v[1], done = {} }
    job.case = dropCase(veh)
    installMenu()
end

function TrackDiagnose()
    local veh = myVehicle()
    if not veh then return lib.notify({ type = 'error', description = 'Sit in the vehicle to check its tracker' }) end
    if not lib.progressBar({ duration = 4000, label = 'Checking the tracker LEDs under the dash', canCancel = true, disable = { car = true } }) then return end
    local plate = plateOf(veh)
    local info = lib.callback.await('opslabs-towers:track:get', false, plate)
    lib.alertDialog({ header = 'OPS Track · ' .. plate, centered = true, content = table.concat(ledReport(veh, info), '  \n') ..
        (info and info.cut and '  \n**Vehicle power to the unit is disconnected**' or '') })
end

function TrackCut(reconnect)
    local veh = myVehicle()
    if not veh then return lib.notify({ type = 'error', description = 'Sit in the vehicle' }) end
    local label = reconnect and 'Reconnecting the tracker supply' or 'Hunting behind the dash for a tracker and cutting its feed'
    if not lib.progressBar({ duration = reconnect and 6000 or 20000, label = label, canCancel = true, disable = { car = true, move = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 } }) then return end
    local r = lib.callback.await('opslabs-towers:track:cut', false, plateOf(veh), reconnect)
    if reconnect then lib.notify({ type = r and r.ok and 'success' or 'error', description = r and r.ok and 'Tracker supply reconnected' or 'No tracker here' }) return end
    if not r or not r.found then lib.notify({ type = 'inform', description = 'You don’t find any tracker in this vehicle' })
    else lib.notify({ type = 'success', description = r.backup and 'Feed cut — but the unit has its own battery…' or 'Feed cut — the tracker is dead' }) end
end

function TrackRemove()
    local veh = myVehicle()
    if not veh then return lib.notify({ type = 'error', description = 'Sit in the vehicle' }) end
    local plate = plateOf(veh)
    local ok = lib.alertDialog({ header = 'Decommission tracker · ' .. plate, content = 'Remove the unit, battery, antenna and loom, and close the account?', centered = true, cancel = true })
    if ok ~= 'confirm' then return end
    if not lib.progressBar({ duration = 15000, label = 'Removing the tracker and making good the wiring', canCancel = true, disable = { car = true, move = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 } }) then return end
    local r = lib.callback.await('opslabs-towers:track:remove', false, plate)
    if r and r.ok then lib.notify({ type = 'success', description = 'Tracker removed' }) else err(r) end
end

---------------------------------------------------------------------------
-- owners: /track
---------------------------------------------------------------------------
local function ago(t, n) if not t then return 'never' end local s = math.max(0, n - t) return s < 60 and (s .. ' s ago') or s < 3600 and (math.floor(s / 60) .. ' min ago') or (math.floor(s / 3600) .. ' h ago') end

function TrackList()
    local r = lib.callback.await('opslabs-towers:track:mine', false)
    local list = r and r.list or {}
    local options = {}
    local now = GlobalState.opsTime or 0
    for _, t in ipairs(list) do
        options[#options + 1] = { title = ('%s · %s'):format(t.label or t.model or 'Vehicle', t.plate), arrow = true,
            description = (not t.online and 'Offline' or t.pending and 'No signal — last known position' or (t.speed or 0) > 3 and ('Moving · %d km/h'):format(t.speed) or 'Parked')
                .. (t.armed and ' · ARMED' or '') .. (t.immob and ' · IMMOBILISED' or '') .. (t.cut and ' · POWER CUT' or ''),
            icon = 'location-crosshairs', iconColor = not t.online and GREY or t.armed and ORANGE or GREEN, onSelect = function()
                local function act(a, msg) local res = lib.callback.await('opslabs-towers:track:act', false, t.plate, a) if res and res.ok then lib.notify({ type = 'success', description = msg }) else err(res) end TrackList() end
                local o = {
                    { title = 'Show on the map', description = t.x and ('Waypoint set · %s'):format(t.pending and 'last known' or 'live') or 'No position yet', icon = 'map-location-dot', disabled = not t.x,
                      onSelect = function() SetNewWaypoint(t.x + 0.0, t.y + 0.0) lib.notify({ type = 'success', description = 'Waypoint set to ' .. t.plate }) end },
                    { title = t.armed and 'Disarm theft alerts' or 'Arm theft alerts', description = 'Armed: alerts you if it moves' .. (t.io and ' or the ignition comes on' or ''), icon = t.armed and 'shield' or 'shield-halved',
                      onSelect = function() act(t.armed and 'disarm' or 'arm', t.armed and 'Disarmed' or 'Armed — you’ll be alerted if it moves') end },
                }
                if t.io then
                    o[#o + 1] = { title = t.immob and 'Release immobiliser' or 'Immobilise', description = 'Stops it starting again once it’s stationary (Pro relay)', icon = 'lock', iconColor = t.immob and GREEN or RED,
                        onSelect = function() act(t.immob and 'release' or 'immobilise', t.immob and 'Immobiliser released' or 'Immobiliser on') end }
                end
                o[#o + 1] = { title = 'Name this vehicle', icon = 'pen', onSelect = function()
                    local v = lib.inputDialog('Name', { { type = 'input', label = 'Name', default = t.label or '' } })
                    if v then lib.callback.await('opslabs-towers:track:act', false, t.plate, 'label', v[1]) TrackList() end
                end }
                o[#o + 1] = { title = ('%s · IMEI %s'):format(t.unitLabel or t.unit, t.imei or '?'), description = ('OPS Mobile %d/4 · battery %d %%%s'):format(t.bars or 0, t.battery or 100, t.backup and '' or ' (no backup)'), icon = 'microchip', readOnly = true }
                lib.registerContext({ id = 'track_one', title = t.plate, menu = 'track_list', options = o })
                lib.showContext('track_one')
            end }
    end
    if #options == 0 then options[1] = { title = 'No tracked vehicles', description = 'OPS Track installers fit trackers — ask at a fitting bay', icon = 'location-crosshairs', readOnly = true } end
    lib.registerContext({ id = 'track_list', title = r and r.staff and 'OPS Track · all trackers' or 'My tracked vehicles', options = options })
    lib.showContext('track_list')
end
RegisterCommand('track', function() TrackList() end, false)

RegisterNetEvent('opslabs-towers:track:alert', function(a)
    lib.notify({ type = (a.kind == 'theft' or a.kind == 'tamper') and 'error' or 'inform', title = 'OPS Track · ' .. (a.label or a.plate), description = a.text, duration = 12000, icon = 'location-crosshairs' })
    if a.x then
        local b = AddBlipForCoord(a.x + 0.0, a.y + 0.0, 0.0)
        SetBlipSprite(b, 326) SetBlipColour(b, 1) SetBlipFlashes(b, true)
        BeginTextCommandSetBlipName('STRING') AddTextComponentSubstringPlayerName('Tracked: ' .. a.plate) EndTextCommandSetBlipName(b)
        SetTimeout(120000, function() RemoveBlip(b) end)
    end
end)
