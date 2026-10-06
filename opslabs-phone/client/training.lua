-- OPS training & job assistant (client): /jobhelp, the OPS Academy practical, OPS depots (items mode) and their blips.
-- Server: server/training.lua.

local function W() return Config.Work or {} end
local function notify(t, d, ty) lib.notify({ title = t, description = d, type = ty or 'inform' }) end

---------------------------------------------------------------------------
-- /jobhelp — the job assistant without opening the phone
---------------------------------------------------------------------------
local function jobHelp()
    local r = lib.callback.await('opslabs-phone:jobhelp', false)
    if not r or r.error then return notify('Job assistant', r and r.error or 'Try again', 'error') end
    local o = {}
    local cur = r.steps[r.current]
    if r.needRA and not r.ra then
        o[#o + 1] = { title = 'Do the risk assessment first', description = 'OPS Work → the job → Guide me → Risk assessment', icon = 'helmet-safety', iconColor = '#ff9f0a', readOnly = true }
    end
    if cur then
        o[#o + 1] = { title = ('Next: %s'):format(cur.title), description = cur.detail, icon = 'circle-play', iconColor = '#0a84ff', onSelect = function() OpsStepBar(cur.title, cur.secs or 6, cur.anim) end }
        if cur.where then o[#o + 1] = { title = 'Where', description = cur.where, icon = 'location-dot', readOnly = true } end
    end
    if r.check then o[#o + 1] = { title = ('Work check: %s'):format(r.check.label or ''), description = ('%s / %s %s'):format(r.check.have or 0, r.check.need or 1, r.check.detail or ''), icon = r.check.ok and 'circle-check' or 'hourglass-half', iconColor = r.check.ok and '#30d158' or '#ff9f0a', readOnly = true } end
    if #r.missing > 0 then
        o[#o + 1] = { title = 'Missing: ' .. table.concat(r.missing, ', '), description = r.depot and ('Collect at ' .. r.depot.label) or 'Collect at an OPS depot', icon = 'toolbox', iconColor = '#ff453a',
            onSelect = function() if r.depot then SetNewWaypoint(r.depot.x, r.depot.y) notify('GPS', 'Waypoint set to ' .. r.depot.label) end end }
    end
    if r.job.x then o[#o + 1] = { title = 'GPS to the job', description = r.job.ref .. ' · ' .. r.job.title, icon = 'route', onSelect = function() SetNewWaypoint(r.job.x, r.job.y) end } end
    o[#o + 1] = { title = 'All steps', icon = 'list-ol', arrow = true, onSelect = function()
        local s = {}
        for i, st in ipairs(r.steps) do
            s[#s + 1] = { title = ('%s%d. %s'):format(i == r.current and '▶ ' or (i < r.current and '✓ ' or ''), i, st.title), description = st.detail, icon = i < r.current and 'check' or 'circle',
                iconColor = i < r.current and '#30d158' or (i == r.current and '#0a84ff' or '#8e8e93'), onSelect = function() OpsStepBar(st.title, st.secs or 6, st.anim) end }
        end
        lib.registerContext({ id = 'ops_jobhelp_steps', title = r.family, menu = 'ops_jobhelp', options = s })
        lib.showContext('ops_jobhelp_steps')
    end }
    lib.registerContext({ id = 'ops_jobhelp', title = ('%s · %s'):format(r.job.ref, r.family), options = o })
    lib.showContext('ops_jobhelp')
end
RegisterCommand('jobhelp', jobHelp, false)
TriggerEvent('chat:addSuggestion', '/jobhelp', 'OPS job assistant: your next step, tools and where to get them')

---------------------------------------------------------------------------
-- the OPS Academy practical (started from OPS Work → Training)
---------------------------------------------------------------------------
RegisterNUICallback('opsPractical', function(b, cb)
    local r = lib.callback.await('opslabs-phone:opsPracticalStart', false, { code = b and b.code })
    if not r or r.error then
        if r and r.centres and r.centres[1] then SetNewWaypoint(r.centres[1].x, r.centres[1].y) end
        cb(r or { error = 'Try again' })
        return
    end
    cb({ ok = true })
    if ClosePhone then ClosePhone() end
    CreateThread(function()
        notify('Practical · ' .. r.name, ('%d steps — do each one properly'):format(#r.steps))
        local fails = 0
        for i, s in ipairs(r.steps) do
            lib.showTextUI(('%d/%d %s'):format(i, #r.steps, s.title), { icon = 'graduation-cap' })
            Wait(1200)
            if not OpsStepBar(('%d/%d · %s'):format(i, #r.steps, s.title), s.secs or 6, s.anim) then
                lib.hideTextUI()
                return notify('Practical', 'Stopped — start again from OPS Work → Training', 'warning')
            end
            if r.skillChecks and (s.anim == 'crimp' or s.anim == 'splice' or s.anim == 'test' or s.anim == 'drill') then
                if not lib.skillCheck({ 'easy', 'medium' }, { 'e' }) then fails = fails + 1 notify('Practical', 'Not quite — the assessor noted it', 'warning') end
            end
        end
        lib.hideTextUI()
        local done = lib.callback.await('opslabs-phone:opsPracticalDone', false, { code = b.code, token = r.token, fails = fails })
        if done and done.ok then
            notify('Practical passed', done.certified and ('Certified: ' .. r.name) or 'Now pass the exam to get certified', 'success')
        else
            notify('Practical', (done and (done.error or ('Score %d%% — try again'):format(done.score or 0))) or 'Try again', 'error')
        end
    end)
end)

---------------------------------------------------------------------------
-- blips + the depot counter (items mode)
---------------------------------------------------------------------------
local blips = {}
local function makeBlips()
    for _, b in ipairs(blips) do RemoveBlip(b) end
    blips = {}
    for _, c in ipairs(W().TrainingCentres or {}) do
        local b = AddBlipForCoord(c.x, c.y, c.z) SetBlipSprite(b, 498) SetBlipColour(b, 27) SetBlipScale(b, 0.75) SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING') AddTextComponentSubstringPlayerName(c.label or 'OPS Academy') EndTextCommandSetBlipName(b)
        blips[#blips + 1] = b
    end
    if W().Mode == 'items' then
        for _, d in ipairs(W().Depots or {}) do
            local b = AddBlipForCoord(d.x, d.y, d.z) SetBlipSprite(b, 478) SetBlipColour(b, 3) SetBlipScale(b, 0.75) SetBlipAsShortRange(b, true)
            BeginTextCommandSetBlipName('STRING') AddTextComponentSubstringPlayerName(d.label or 'OPS Depot') EndTextCommandSetBlipName(b)
            blips[#blips + 1] = b
        end
    end
end
CreateThread(function() Wait(2000) makeBlips() end)
AddEventHandler('opslabs:configChanged', function(res) if res == GetCurrentResourceName() then makeBlips() end end)

local function depotMenu()
    local r = lib.callback.await('opslabs-phone:depot', false, 'list')
    if not r or r.error then return notify('OPS Depot', r and r.error or 'Try again', 'error') end
    local o = {}
    for _, j in ipairs(r.jobs) do
        o[#o + 1] = { title = ('%s · %s'):format(j.ref, j.title), description = ('%s · %d tool(s) / %d part line(s) missing'):format(j.family or '', #j.tools, #j.parts), icon = 'briefcase', arrow = true,
            onSelect = function()
                lib.registerContext({ id = 'ops_depot_job', title = j.ref, menu = 'ops_depot', options = {
                    { title = 'Collect tools & PPE', icon = 'toolbox', onSelect = function()
                        local x = lib.callback.await('opslabs-phone:depot', false, 'tools', j.id)
                        notify('OPS Depot', x and x.ok and (#x.given > 0 and ('Issued: ' .. table.concat(x.given, ', ')) or 'You already have everything') or (x and x.error) or 'Failed', x and x.ok and 'success' or 'error')
                    end },
                    { title = 'Collect parts for this job', description = 'Taken from company stock', icon = 'boxes-stacked', onSelect = function()
                        local x = lib.callback.await('opslabs-phone:depot', false, 'parts', j.id)
                        notify('OPS Depot', x and x.ok and (#x.given > 0 and ('Collected: ' .. table.concat(x.given, ', ')) or 'You already have the parts') or (x and x.error) or 'Failed', x and x.ok and 'success' or 'error')
                    end },
                } })
                lib.showContext('ops_depot_job')
            end }
    end
    if #o == 0 then o[1] = { title = 'No jobs on', description = 'Accept a job in OPS Work, then collect what it needs here', icon = 'circle-info', readOnly = true } end
    lib.registerContext({ id = 'ops_depot', title = 'OPS Depot', options = o })
    lib.showContext('ops_depot')
end

CreateThread(function()
    local shown
    while true do
        local sleep = 1000
        if W().Mode == 'items' then
            local p = GetEntityCoords(PlayerPedId())
            local near
            for _, d in ipairs(W().Depots or {}) do if #(p - vector3(d.x, d.y, d.z)) < (W().DepotRadius or 3.0) then near = d end end
            if near then
                sleep = 0
                if not shown then lib.showTextUI('[E] ' .. (near.label or 'OPS Depot'), { icon = 'warehouse' }) shown = true end
                if IsControlJustPressed(0, 38) then lib.hideTextUI() shown = nil depotMenu() Wait(500) end
            elseif shown then lib.hideTextUI() shown = nil end
        elseif shown then lib.hideTextUI() shown = nil end
        Wait(sleep)
    end
end)
