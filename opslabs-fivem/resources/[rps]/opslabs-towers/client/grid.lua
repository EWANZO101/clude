-- Grid control, client side:
--   · tell the server the game time + weather (load follows the clock, storms raise fault rates)
--   · crews: control panels at the kit — [E] in a power station or substation yard, or under a pole recloser —
--     working the same breakers / units as OPS Hub → Grid control
--   · crews: grid fault jobs (blip, yellow marker, [E] repair) and dispatches / notices from control

local CG = Config.Grid or {}
if CG.Enabled == false then return end
local ST, SU = CG.Station or {}, CG.Substation or {}
local SITES, SKP = CG.SubSites or {}, (CG.SubKit or {}).parts or {}
-- where [E] opens substation control: the yard, the fitted building, an empty building / RTU pole, and the plant you work it from
local SUB_E = { [SU.model or 'opslabs_grid_substation'] = 15.0, opslabs_grid_subbuilding = 11.0, opslabs_grid_subshell = 11.0, opslabs_grid_rtu = 2.5,
    opslabs_sub_control = 2.0, opslabs_sub_swgr = 2.4, opslabs_sub_gis = 2.4, opslabs_sub_relay = 1.6 }
local function isSub(m) return SUB_E[m] ~= nil end

local WEATHERS = { 'CLEAR', 'EXTRASUNNY', 'CLOUDS', 'OVERCAST', 'RAIN', 'CLEARING', 'THUNDER', 'SMOG', 'FOGGY', 'XMAS', 'SNOW', 'SNOWLIGHT', 'BLIZZARD', 'HALLOWEEN', 'NEUTRAL' }
local WH = {}
for _, w in ipairs(WEATHERS) do WH[joaat(w) & 0xFFFFFFFF] = w end
lib.callback.register('opslabs-towers:sky', function()
    return GetClockHours() + GetClockMinutes() / 60, WH[GetPrevWeatherTypeHashName() & 0xFFFFFFFF] or 'CLEAR'
end)

local crew = false
local function checkCrew() crew = lib.callback.await('opslabs-towers:grid:isCrew', false) == true end
CreateThread(function() Wait(4000) checkCrew() end)
RegisterNetEvent('esx:setJob', function() SetTimeout(1500, checkCrew) end)

local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function mw(v) return ('%.1f MW'):format(v or 0) end

---------------------------------------------------------------------------
-- control panels at the kit
---------------------------------------------------------------------------

local openPanel

local function act(at, body, after)
    body.at = at
    local r = lib.callback.await('opslabs-towers:grid:act', false, body)
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' })
    else PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true) end
    Wait(300)
    if after then after() end
end

local function brkLabel(b) return b.lockout and 'LOCKED OUT' or b.shed and ('SHED · ' .. b.shed) or b.closed and 'CLOSED' or 'OPEN' end
local function brkColor(b) return b.lockout and '#ff453a' or b.shed and '#ff9f0a' or b.closed and '#30d158' or '#8e8e93' end

local function breakerMenu(at, b, title, extra, back)
    local options = {
        { title = ('%s · %s'):format(title, brkLabel(b)), description = extra, icon = 'circle', iconColor = brkColor(b), readOnly = true },
    }
    if b.closed then
        options[#options + 1] = { title = 'Open the breaker', icon = 'toggle-off', iconColor = '#ff453a', onSelect = function()
            if lib.alertDialog({ header = 'Open ' .. title .. '?', content = 'Everything it supplies goes dead.', centered = true, cancel = true }) == 'confirm' then
                act(at, { action = 'open', key = b.key }, back)
            else back() end
        end }
    else
        options[#options + 1] = { title = b.lockout and 'Reset the lockout and close' or 'Close the breaker', icon = 'toggle-on', iconColor = '#30d158',
            onSelect = function() act(at, { action = 'close', key = b.key }, back) end }
    end
    if b.key:sub(1, 1) == 'F' then
        options[#options + 1] = { title = 'Rename this feeder', icon = 'pen', onSelect = function()
            local v = lib.inputDialog('Feeder name', { { type = 'input', label = 'Name', default = b.name or '', max = 48 } })
            if v then act(at, { action = 'name', key = b.key, name = v[1] }, back) else back() end
        end }
        options[#options + 1] = { title = 'Load-shedding priority', description = '1 = shed first · 3 = keep on (hospitals, services)', icon = 'list-ol', onSelect = function()
            local v = lib.inputDialog('Priority', { { type = 'select', label = 'Priority', options = { { value = '1', label = '1 · shed first' }, { value = '2', label = '2 · normal' }, { value = '3', label = '3 · essential' } }, default = '2' } })
            if v then act(at, { action = 'priority', key = b.key, priority = tonumber(v[1]) }, back) else back() end
        end }
    end
    lib.registerContext({ id = 'grid_brk', title = title, menu = 'grid_panel', onBack = back, options = options })
    lib.showContext('grid_brk')
end

local function stationPanel(f, p)
    local st = p.station or {}
    local back = function() openPanel(f) end
    local options = {
        { title = ('%s · %s'):format(st.name or 'Power station', st.energized and 'RUNNING' or 'NO UNITS RUNNING'),
          description = ('Output %s of %s available · %.2f Hz · system %s'):format(mw(st.out), mw(st.avail), p.freq or 0, (p.level or 'normal'):upper()),
          icon = 'industry', iconColor = st.energized and '#30d158' or '#8e8e93', readOnly = true },
    }
    for i, u in ipairs(st.units or {}) do
        local col = u.state == 'online' and '#30d158' or u.state == 'starting' and '#ff9f0a' or u.state == 'tripped' and '#ff453a' or '#8e8e93'
        local running = u.state == 'online' or u.state == 'starting'
        options[#options + 1] = { title = ('Unit %d · %s%s'):format(i, u.state:upper(), u.maint and ' · MAINTENANCE' or ''), description = ('%d MW · %s'):format(st.unitMW or 120, running and 'select to stop' or 'select to start'),
            icon = 'gear', iconColor = col, onSelect = function()
                if running then
                    if lib.alertDialog({ header = ('Stop unit %d?'):format(i), content = ('Takes %d MW off the grid.'):format(st.unitMW or 120), centered = true, cancel = true }) == 'confirm' then
                        act(f.id, { action = 'unit_stop', id = f.id, unit = i }, back)
                    else back() end
                else act(f.id, { action = 'unit_start', id = f.id, unit = i }, back) end
            end }
    end
    for _, l in ipairs(p.lines or {}) do
        options[#options + 1] = { title = ('%s · %s'):format(l.name, brkLabel(l.breaker)), description = l.fault and ('Fault on the line (%s)'):format(l.fault) or ('400 kV · %s of %d MW'):format(mw(l.flow), l.rating or 0),
            icon = 'bolt', iconColor = brkColor(l.breaker), arrow = true, onSelect = function() breakerMenu(f.id, l.breaker, l.name, ('400 kV · %s'):format(mw(l.flow)), back) end }
    end
    if #(p.lines or {}) == 0 then options[#options + 1] = { title = 'No 400 kV lines connected', description = 'Run 400 kV transmission conductor to the gantry (Run power cable → 400 kV)', icon = 'circle-info', readOnly = true } end
    lib.registerContext({ id = 'grid_panel', title = 'Power station control', options = options })
    lib.showContext('grid_panel')
end

local function substationPanel(f, p)
    local s = p.sub or {}
    local back = function() openPanel(f) end
    local options = {}
    if s.missing and #s.missing > 0 then
        options[#options + 1] = { title = 'Not ready to energise', description = 'Missing: ' .. table.concat(s.missing, ' · '), icon = 'triangle-exclamation', iconColor = '#ff9f0a', readOnly = true }
    end
    if s.kind and s.kind ~= 'yard' then
        local k = s.kit or {}
        options[#options + 1] = { title = ('Plant · %d × 30 MVA transformer%s · %s feeder ways'):format(s.tx or 0, (s.tx or 0) == 1 and '' or 's', s.ways or '—'),
            description = ('SCADA %s · control desk %s · metering %s%s'):format(s.scada and 'yes' or 'NO (local only)', s.control and 'yes' or 'no', s.metered and 'yes' or 'no',
                s.noWay and (' · %d feeder(s) with no free breaker'):format(s.noWay) or ''), icon = 'list-check', iconColor = '#0a84ff', readOnly = true }
    end
    local head = {
        { title = ('%s · %s'):format(s.name or 'Substation', s.fire and 'FIRE' or s.energized and 'ENERGISED' or 'DEAD'),
          description = ('400 kV %s · transformers %d/%d · load %s of %d MVA firm · %.2f Hz'):format(s.hv400 and 'live' or 'dead', s.txOk or 0, s.tx or 2, mw(s.load), ((s.tx or 0) > 0) and math.floor((s.mva or 60) * (s.txOk or 0) / s.tx) or 0, p.freq or 0),
          icon = 'bolt-lightning', iconColor = s.fire and '#ff453a' or s.energized and '#30d158' or '#ff453a', readOnly = true },
    }
    table.insert(options, 1, head[1])
    if s.incomer then
        options[#options + 1] = { title = ('Incomer (400 / 11 kV) · %s'):format(brkLabel(s.incomer)), description = 'Feeds the 11 kV busbar from the transformers', icon = 'toggle-on',
            iconColor = brkColor(s.incomer), arrow = true, onSelect = function() breakerMenu(f.id, s.incomer, 'Incomer', 'Transformers → 11 kV bus', back) end }
    end
    for _, fd in ipairs(p.feeders or {}) do
        options[#options + 1] = { title = ('%s · %s'):format(fd.name, brkLabel(fd.breaker)),
            description = fd.fault and 'Fault on the feeder cable' or ('%s · %d / %d transformers live · priority %d'):format(mw(fd.load), fd.liveTx or 0, fd.transformers or 0, fd.priority or 2),
            icon = 'plug-circle-bolt', iconColor = brkColor(fd.breaker), arrow = true, onSelect = function() breakerMenu(f.id, fd.breaker, fd.name, ('11 kV feeder · %s'):format(mw(fd.load)), back) end }
    end
    if #(p.feeders or {}) == 0 then options[#options + 1] = { title = 'No 11 kV feeders yet', description = 'Run 11 kV (HV) conductor out of the yard to your power poles — each run is a feeder', icon = 'circle-info', readOnly = true } end
    for _, l in ipairs(p.lines or {}) do
        options[#options + 1] = { title = ('%s · %s'):format(l.name, brkLabel(l.breaker)), description = ('400 kV in · %s'):format(mw(l.flow)), icon = 'bolt', iconColor = brkColor(l.breaker), arrow = true,
            onSelect = function() breakerMenu(f.id, l.breaker, l.name, '400 kV line', back) end }
    end
    lib.registerContext({ id = 'grid_panel', title = 'Substation control', options = options })
    lib.showContext('grid_panel')
end

local function recloserPanel(f, p)
    local r = p.recloser
    if not r then return lib.notify({ type = 'error', description = 'This recloser is not on a power pole' }) end
    breakerMenu(f.id, r, r.name, ('%s · %s'):format(r.energized and 'line live' or 'line dead', r.feeder and ('on ' .. r.feeder) or 'not on a feeder'), function() openPanel(f) end)
end

openPanel = function(f)
    local p = lib.callback.await('opslabs-towers:grid:panel', false, f.id)
    if not p or p.error then return lib.notify({ type = 'error', description = (p and p.error) or 'Failed' }) end
    if f.model == ST.model then stationPanel(f, p)
    elseif p.sub then substationPanel(f, p)
    else recloserPanel(f, p) end
end

--- client/target.lua: the control panel of a recloser (or station / substation) from the third eye
function GridOpenPanel(f) openPanel(f) end
function GridCrew() return crew end

local function nearestKit()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd, label
    for _, f in pairs(fixtures()) do
        -- the recloser is on the third eye at the bottom of its pole when a target resource runs (client/target.lua)
        local reach = f.model == ST.model and 26.0 or SUB_E[f.model] or (f.model == CG.Recloser and not (TargetOn and TargetOn())) and 4.0 or nil
        if reach then
            local d = #(vector2(pos.x, pos.y) - vector2(f.x, f.y))
            if d <= reach and (f.model ~= CG.Recloser or math.abs(pos.z - f.z) < 14) and (not bd or d < bd) then
                best, bd = f, d
                label = f.model == ST.model and '[E] Power station control' or isSub(f.model) and '[E] Substation control' or '[E] Recloser control'
            end
        end
    end
    return best, label
end

CreateThread(function()
    local shown
    while true do
        local sleep = 600
        if crew and not IsPedInAnyVehicle(PlayerPedId(), false) and not IsPauseMenuActive() and not NearLaptopId then
            local f, label = nearestKit()
            if f then
                sleep = 0
                if shown ~= label then lib.showTextUI(label, { icon = 'bolt' }) shown = label end
                if IsControlJustPressed(0, 38) then lib.hideTextUI() shown = nil openPanel(f) Wait(400) end
            elseif shown then lib.hideTextUI() shown = nil end
        elseif shown then lib.hideTextUI() shown = nil end
        Wait(sleep)
    end
end)

---------------------------------------------------------------------------
-- crews: fault jobs
---------------------------------------------------------------------------

local blips = {}
local function syncBlips(jobs)
    local want = {}
    for _, j in ipairs(crew and jobs or {}) do
        want[j.id] = true
        if not blips[j.id] then
            local b = AddBlipForCoord(j.x, j.y, 0.0)
            SetBlipSprite(b, 354)
            SetBlipColour(b, 5)
            SetBlipScale(b, 0.9)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName('Grid fault: ' .. j.title)
            EndTextCommandSetBlipName(b)
            blips[j.id] = b
        end
    end
    for id, b in pairs(blips) do if not want[id] then RemoveBlip(b) blips[id] = nil end end
end
AddStateBagChangeHandler('gridJobs', 'global', function(_, _, value) syncBlips(value or {}) end)
CreateThread(function() Wait(6000) syncBlips(GlobalState.gridJobs or {}) end)

CreateThread(function()
    local shown = nil
    while true do
        local sleep = 1000
        if crew then
            local p = GetEntityCoords(PlayerPedId())
            local near, nd
            for _, j in ipairs(GlobalState.gridJobs or {}) do
                local d = #(vector2(p.x, p.y) - vector2(j.x, j.y))
                if d < 60.0 then
                    sleep = 0
                    local _, gz = GetGroundZFor_3dCoord(j.x, j.y, p.z + 50.0, false)
                    DrawMarker(1, j.x, j.y, (gz ~= 0 and gz or p.z) - 0.9, 0, 0, 0, 0, 0, 0, 8.0, 8.0, 1.2, 255, 200, 0, 90, false, false, 2, false, nil, nil, false)
                end
                if d < 20.0 and (not nd or d < nd) then near, nd = j, d end
            end
            if near then
                local text = '[E] Repair: ' .. near.title
                if shown ~= text then lib.showTextUI(text, { icon = 'screwdriver-wrench' }) shown = text end
                if IsControlJustPressed(0, 38) then
                    lib.hideTextUI() shown = nil
                    if lib.progressBar({ duration = (CG.RepairSeconds or 25) * 1000, label = 'Repairing: ' .. near.title, canCancel = true,
                        disable = { move = true, combat = true, car = true }, anim = { dict = 'mini@repair', clip = 'fixing_a_ped', flag = 49 } }) then
                        local r = lib.callback.await('opslabs-towers:grid:repair', false, near.id)
                        lib.notify({ type = r and r.ok and 'success' or 'error', description = r and (r.text or r.error) or 'Failed' })
                    end
                end
            elseif shown then lib.hideTextUI() shown = nil end
        elseif shown then lib.hideTextUI() shown = nil end
        Wait(sleep)
    end
end)

RegisterNetEvent('opslabs-towers:gridDispatch', function(j)
    SetNewWaypoint(j.x, j.y)
    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
    lib.notify({ title = 'Grid control · crew dispatched', type = 'warning', duration = 10000, description = j.title .. ' — GPS set. [E] at the yellow marker to repair.' })
end)

RegisterNetEvent('opslabs-towers:gridNotice', function(n)
    lib.notify({ title = n.from or 'San Andreas Power & Light', type = 'inform', duration = 12000, description = n.text })
end)
