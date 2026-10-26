-- OPS Access (client): [E] taps the nearest reader (grant/deny, opens every door linked to it); [G] opens its
-- management menu (link nearby doors, set which companies' staff tap straight in, issue/revoke individual cards,
-- arm/disarm). Server: server/access.lua. Alarms: server/sensors.lua.
-- Third eye (client/target.lua): when a target resource is running, look at any hub & reader instead - Tap and
-- OPS Access menu are target options on it, and the [E]/[G] prompt below steps aside.

local CA = Config.Access or {}
if CA.Enabled == false then return end

local function fixtures() return CablingFixtures and CablingFixtures() or {} end

local function nearestReader(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, f in pairs(fixtures()) do
        if f.model == (CA.ReaderModel or 'opslabs_cctv_reader') then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d < (bd or maxDist) then best, bd = id, d end
        end
    end
    return best, bd
end

local function split(s)
    local out = {}
    for part in (s or ''):gmatch('[^,]+') do
        local t = part:match('^%s*(.-)%s*$')
        if t ~= '' then out[#out + 1] = t end
    end
    return out
end

local function linkDoor(fid)
    local lr = lib.callback.await('opslabs-towers:access:linkable', false, fid)
    if not lr or lr.error or #(lr.doors or {}) == 0 then return lib.notify({ type = 'error', description = 'No doors found nearby' }) end
    local opts = {}
    for _, d in ipairs(lr.doors) do opts[#opts + 1] = { value = ('%d:%d'):format(d.fid, d.idx), label = ('%s (%d m)'):format(d.label, math.floor(d.dist)) } end
    local v = lib.inputDialog('Link a door', { { type = 'select', label = 'Door', options = opts, required = true } })
    if not v then return end
    local dfid, didx = v[1]:match('^(%d+):(%d+)$')
    local res = lib.callback.await('opslabs-towers:access:link', false, fid, dfid, didx)
    if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
    else lib.notify({ type = 'success', description = 'Linked' }) end
end

local function manageMenu(fid)
    local r = lib.callback.await('opslabs-towers:access:menu', false, fid)
    if not r or r.error then return lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    if not r.canManage then return lib.notify({ type = 'error', description = 'You don\'t have access to manage this hub' }) end
    local h = r.hub
    local options = {
        { title = h.armed and 'Disarm' or 'Arm', icon = h.armed and 'shield' or 'shield-halved', iconColor = h.armed and '#30d158' or '#ff453a', onSelect = function()
            local res = lib.callback.await('opslabs-towers:access:arm', false, fid, not h.armed)
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
            else lib.notify({ type = 'success', description = res.armed and 'Armed' or 'Disarmed' }) end
        end },
        { title = 'Companies', description = #h.companies > 0 and table.concat(h.companies, ', ') or 'None set — individual cards only', icon = 'building', onSelect = function()
            local v = lib.inputDialog('Authorized companies', {
                { type = 'input', label = 'Job names, comma-separated', description = 'Anyone employed by one of these taps straight in', default = table.concat(h.companies, ', ') },
            })
            if not v then return end
            local res = lib.callback.await('opslabs-towers:access:setCompanies', false, fid, split(v[1]))
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
            else lib.notify({ type = 'success', description = 'Companies saved' }) end
        end },
        { title = 'Link a door', description = ('%d linked now'):format(#r.doors), icon = 'link', onSelect = function() linkDoor(fid) end },
    }
    for _, d in ipairs(r.doors) do
        options[#options + 1] = { title = 'Unlink ' .. d.label, icon = 'link-slash', iconColor = '#ff453a', onSelect = function()
            local res = lib.callback.await('opslabs-towers:access:unlink', false, fid, d.link)
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) else lib.notify({ type = 'success', description = 'Unlinked' }) end
        end }
    end
    options[#options + 1] = { title = 'Issue a card', description = 'Stand next to who you\'re issuing it to', icon = 'id-card', onSelect = function()
        local res = lib.callback.await('opslabs-towers:access:issueCard', false, fid)
        if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' })
        else lib.notify({ type = 'success', description = 'Card issued to ' .. res.name }) end
    end }
    for _, c in ipairs(r.cards) do
        options[#options + 1] = { title = 'Revoke ' .. (c.holder_name or c.identifier), icon = 'id-card', iconColor = '#ff453a', onSelect = function()
            local res = lib.callback.await('opslabs-towers:access:revokeCard', false, fid, c.id)
            if not res or res.error then lib.notify({ type = 'error', description = (res and res.error) or 'Failed' }) else lib.notify({ type = 'success', description = 'Revoked' }) end
        end }
    end
    lib.registerContext({ id = 'access_menu', title = 'OPS Access hub #' .. fid, options = options })
    lib.showContext('access_menu')
end

local function tap(id)
    local res = lib.callback.await('opslabs-towers:access:tap', false, id)
    if res and res.ok then
        if res.granted then lib.notify({ type = 'success', description = res.note or 'Access granted' })
        else lib.notify({ type = 'error', description = 'Access denied' }) end
    elseif res then lib.notify({ type = 'error', description = res.error or 'Failed' }) end
end

-- fallback [E]/[G] prompt - the third eye (client/target.lua) replaces this entirely once it's running
CreateThread(function()
    local shown = nil
    local reach = math.max(CA.UseDistance or 2.0, CA.ManageDistance or 3.0)
    while true do
        if TargetOn and TargetOn() then
            if shown then lib.hideTextUI() shown = nil end
            Wait(500)
            goto continue
        end
        local ped = PlayerPedId()
        local id, dist = nil, nil
        if not IsPedInAnyVehicle(ped, false) and not IsPauseMenuActive() then id, dist = nearestReader(reach) end
        if id then
            local canTap = dist <= (CA.UseDistance or 2.0)
            local text = canTap and '[E] Tap · [G] OPS Access menu' or '[G] OPS Access menu'
            if shown ~= text then lib.showTextUI(text) shown = text end
            if canTap and IsControlJustPressed(0, 38) then
                tap(id)
                Wait(300)
            end
            if IsControlJustPressed(0, 47) then manageMenu(id) Wait(300) end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(400)
        end
        ::continue::
    end
end)

---------------------------------------------------------------------------
-- third eye (client/target.lua): Tap · OPS Access menu, on any hub & reader
---------------------------------------------------------------------------
local function readerFixtureAt(entity)
    if not entity or entity == 0 then return nil end
    local c = GetEntityCoords(entity)
    local best, bd
    for id, f in pairs(fixtures()) do
        if f.model == (CA.ReaderModel or 'opslabs_cctv_reader') then
            local d = #(c - vector3(f.x, f.y, f.z))
            if d < 0.8 and (not bd or d < bd) then best, bd = id, d end
        end
    end
    return best
end

local accessTargetRegistered = false
local function registerAccessTarget()
    if accessTargetRegistered or not TargetAddModel then return end
    accessTargetRegistered = TargetAddModel({ CA.ReaderModel or 'opslabs_cctv_reader' }, {
        { name = 'ops_access_tap', label = 'Tap', icon = 'fa-solid fa-key', distance = CA.UseDistance or 2.0,
          onSelect = function(data) local id = readerFixtureAt(data.entity) if id then tap(id) end end },
        { name = 'ops_access_menu', label = 'OPS Access menu', icon = 'fa-solid fa-sliders', distance = CA.ManageDistance or 3.0,
          onSelect = function(data) local id = readerFixtureAt(data.entity) if id then manageMenu(id) end end },
    })
end

CreateThread(function() Wait(1500) registerAccessTarget() end)
AddEventHandler('onClientResourceStart', function(res) if res == 'tgiann-target' or res == 'ox_target' then accessTargetRegistered = false SetTimeout(1000, registerAccessTarget) end end)

RegisterNetEvent('opslabs-towers:access:alert', function(text)
    lib.notify({ title = 'OPS Access alert', description = text, type = 'error', duration = 9000 })
    PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)
end)
