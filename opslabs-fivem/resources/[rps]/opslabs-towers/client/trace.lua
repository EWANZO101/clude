-- Fibre trace tool: stand at any OPS fibre fixture (ONT, cabinet, splitter, joint, DP…) and press the
-- trace key (default K) to walk the real cable path, point by point, to whatever open fault is taking
-- it offline. Each point is a GPS waypoint + a floating marker; once you reach the last one you're at
-- the fault itself and the usual fault marker / repair key (client/faults.lua) take it from there.

local CF = Config.Faults or {}
local engineer = false
local tracing = false
local active = nil   -- { stops = {{x,y,z,label}...}, i, label, severity }

CreateThread(function()
    while true do
        engineer = lib.callback.await('opslabs-towers:cable:can', false) == true
        Wait(engineer and 300000 or 60000)
    end
end)

local function nearestFixture(range)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f and type(f.x) == 'number' and type(f.y) == 'number' and type(f.z) == 'number' then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d <= range and d < (bd or math.huge) then best, bd = f, d end
        end
    end
    return best
end

local function stopTrace() active = nil lib.hideTextUI() end

local function startTrace(f)
    if tracing then return end
    tracing = true
    local r = lib.callback.await('opslabs-towers:faults:trace', false, f.id)
    tracing = false
    if not r or r.error then
        lib.notify({ type = 'error', description = (r and r.error) or 'Could not trace from here' })
    elseif r.clear then
        lib.notify({ type = 'success', title = 'Trace', description = 'Line tests clear from here — no open fault downstream' })
    else
        active = { stops = r.stops or {}, i = 1, label = r.label or 'fault', severity = r.severity }
        lib.notify({ title = 'Tracing: ' .. active.label, description = ('%d point(s) to the fault — follow your GPS'):format(#active.stops) })
        if active.stops[1] then SetNewWaypoint(active.stops[1].x, active.stops[1].y) end
    end
end

RegisterCommand('opstrace', function()
    if not engineer or tracing then return end
    local f = nearestFixture(3.0)
    if not f then return lib.notify({ type = 'error', description = 'Stand at a piece of OPS network kit first' }) end
    startTrace(f)
end, false)
RegisterKeyMapping('opstrace', 'OPS Network: trace a fault from the kit in front of you', 'keyboard', 'K')

--- /towers → Fibre trace tool: same action as the K key, reachable from the menu
function TraceMenu()
    if tracing then return end
    local f = nearestFixture(3.0)
    if not f then
        return lib.alertDialog({ header = 'Fibre trace tool', centered = true,
            content = 'Stand at a piece of OPS fibre kit first — an ONT, cabinet, splitter, joint or DP — then open this again (or just press K next to it).' })
    end
    startTrace(f)
end

RegisterCommand('opstraceoff', function()
    if active then stopTrace() lib.notify({ type = 'inform', description = 'Stopped the trace' }) end
end, false)

-- marker + GPS at the current stop, auto-advancing as you reach each one
CreateThread(function()
    local shown = nil
    while true do
        if active and active.stops[active.i] then
            Wait(0)
            local pt = active.stops[active.i]
            DrawMarker(1, pt.x, pt.y, pt.z + 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.6, 1.6, 1.6, 255, 214, 10, 180, false, true, 2, false, nil, nil, false)
            if shown ~= active.i then
                lib.showTextUI(('Trace: %s — point %d of %d: %s'):format(active.label, active.i, #active.stops, pt.label), { icon = 'route' })
                shown = active.i
            end
            local pos = GetEntityCoords(PlayerPedId())
            if #(pos - vector3(pt.x, pt.y, pt.z)) < 2.5 then
                active.i = active.i + 1
                shown = nil
                local nxt = active.stops[active.i]
                if nxt then
                    SetNewWaypoint(nxt.x, nxt.y)
                else
                    lib.notify({ type = 'success', title = 'Trace complete', description = ('You are at the fault — press %s to repair it'):format(CF.RepairKey or 'U') })
                    stopTrace()
                end
            end
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then lib.hideTextUI() end end)
