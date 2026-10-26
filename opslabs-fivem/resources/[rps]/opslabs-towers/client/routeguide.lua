-- Pole route guide: an engineer with a pole_route job accepted (opslabs-phone), or who was sent a route straight
-- to their phone (OPS Hub → Routes → Text to engineer, server/routes.lua), gets an ordered GPS point through
-- every planned pole spot — a marker at the current target, ticked off as poles go up. Progress is checked
-- server-side (same "is there a pole here" rule the job's own completion check uses) so it's never fooled by
-- someone else's pole, or wrong about one that was already there.
-- /routeguide: see progress, or stop tracking a route you were texted (a job is left the normal way, via OPS Work).

local active = nil          -- { network, points, done = {bool,...}, label, jobType }
local checking = false

local function poleLabel(network) return network == 'power' and 'power pole' or 'telecom pole' end

local function nextIndex()
    if not active then return nil end
    for i, d in ipairs(active.done) do if not d then return i end end
    return nil
end

local function refresh()
    if not active or checking then return end
    checking = true
    -- captured before the await yields: `active` can be cleared (job released / route stopped) while this is in flight
    local net, pts = active.network, active.points
    local done = lib.callback.await('opslabs-towers:routes:progress', false, net, pts, 15)
    if active then active.done = done or active.done end
    checking = false
end

local function startRoute(network, points, label, jobType)
    if type(points) ~= 'table' or #points == 0 then return end
    active = { network = network, points = points, done = {}, label = type(label) == 'string' and label or 'Pole route', jobType = jobType }
    for i in ipairs(points) do active.done[i] = false end
    lib.notify({ title = active.label, description = ('%d point(s) — follow your GPS'):format(#points) })
    refresh()
end

local function stopRoute()
    active = nil
    lib.hideTextUI()
end

RegisterNetEvent('opslabs-towers:route:assign', function(d)
    if type(d) == 'table' then startRoute(d.network, d.points, d.name) end
end)

RegisterNetEvent('ops:jobAccepted', function(j)
    if type(j) == 'table' and type(j.verify) == 'table' and j.verify.kind == 'pole_route' then
        startRoute(j.verify.network, j.verify.points, j.title, j.type)
    end
end)

RegisterNetEvent('ops:jobReleased', function(j)
    if active and active.jobType and type(j) == 'table' and j.type == active.jobType then stopRoute() end
end)

CreateThread(function()
    while true do
        Wait(active and 1500 or 2500)
        if active then refresh() end
    end
end)

--- /towers → Pole route guide: same status/stop dialog as the /routeguide command, reachable from the menu
function RouteGuideStatus()
    if not active then return lib.notify({ type = 'error', description = 'No pole route assigned right now' }) end
    local done = 0
    for _, d in ipairs(active.done) do if d then done = done + 1 end end
    local r = lib.alertDialog({ header = active.label, content = ('%d of %d points done.'):format(done, #active.points), centered = true,
        cancel = true, labels = { confirm = 'OK', cancel = active.jobType and 'OK (leave the job in OPS Work to stop)' or 'Stop tracking it' } })
    if r == 'cancel' and not active.jobType then stopRoute() lib.notify({ description = 'Stopped tracking the route' }) end
end
function RouteGuideActive() return active ~= nil end

RegisterCommand('routeguide', RouteGuideStatus, false)

-- marker + GPS at the current target point
CreateThread(function()
    local shown = nil
    while true do
        Wait(0)
        if active then
            local i = nextIndex()
            if not i then
                if shown ~= 'done' then
                    lib.notify({ type = 'success', title = active.label, description = active.jobType and 'Every point has a pole — go complete the job in OPS Work' or 'Every point has a pole — all done' })
                    shown = 'done'
                end
                Wait(2000)
            else
                local pt = active.points[i]
                local gz = pt.z
                if not gz then local ok, z = GetGroundZFor_3dCoord(pt.x, pt.y, 300.0, false) gz = ok and z or 0.0 end
                DrawMarker(1, pt.x, pt.y, gz + 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.5, 2.5, 2.5, 255, 159, 10, 160, false, true, 2, false, nil, nil, false)
                if shown ~= i then
                    lib.showTextUI(('%s — point %d of %d: place a %s here'):format(active.label, i, #active.points, poleLabel(active.network)), { icon = 'location-dot' })
                    SetNewWaypoint(pt.x, pt.y)
                    shown = i
                end
            end
        elseif shown then
            lib.hideTextUI()
            shown = nil
        end
    end
end)

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then lib.hideTextUI() end end)
