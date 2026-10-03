-- opslabs-towers client: mast props, admin placement tool and map overlay.
-- Signal itself is worked out on the server and sent to the phone.

local towers = {}       -- id -> tower
local props = {}        -- id -> entity
TowerPropEntities = props -- shared with client/cabling.lua (plugging cables into devices)
TowerList = function() return towers end
local overlay = false
local blips = {}

local function setList(list)
    towers = {}
    for _, t in ipairs(list or {}) do towers[t.id] = t end
    if overlay then RefreshOverlay() end
end
RegisterNetEvent('opslabs-towers:list', setList)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(1500)
    TriggerServerEvent('opslabs-towers:ready')
end)

---------------------------------------------------------------------------
-- mast / router props (local objects, spawned near the player)
---------------------------------------------------------------------------

local function modelFor(t)
    local m = t.model or (t.type == 'wifi' and Config.Wifi.Prop or Config.Cell.Prop)
    if not m or not t.prop then return nil end
    local hash = joaat(m)
    return IsModelInCdimage(hash) and hash or nil
end

CreateThread(function()
    while true do
        Wait(2000)
        local pos = GetEntityCoords(PlayerPedId())
        for id, ent in pairs(props) do
            local t = towers[id]
            if not t or not t.prop or #(pos - vector3(t.x, t.y, t.z)) > 450.0 or (t.model and GetEntityModel(ent) ~= joaat(t.model)) then
                if DoesEntityExist(ent) then DeleteEntity(ent) end
                props[id] = nil
            end
        end
        for id, t in pairs(towers) do
            if t.prop and not props[id] and #(pos - vector3(t.x, t.y, t.z)) < 400.0 then
                local hash = modelFor(t)
                if hash then
                    lib.requestModel(hash, 5000)
                    local ent
                    if t.exact then
                        -- placed with the aim tool: exactly where it was put (desk, shelf, roof edge)
                        ent = CreateObject(hash, t.x, t.y, t.z, false, false, false)
                        SetEntityCoordsNoOffset(ent, t.x, t.y, t.z, false, false, false)
                        SetEntityHeading(ent, t.heading or 0.0)
                    else
                        -- placed where the admin stood (feet are ~1 m under the ped's position)
                        ent = CreateObject(hash, t.x, t.y, t.z - 0.98, false, false, false)
                        SetEntityHeading(ent, t.heading or 0.0)
                        PlaceObjectOnGroundProperly(ent)
                    end
                    FreezeEntityPosition(ent, true)
                    SetModelAsNoLongerNeeded(hash)
                    props[id] = ent
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, ent in pairs(props) do if DoesEntityExist(ent) then DeleteEntity(ent) end end
    for _, b in ipairs(blips) do RemoveBlip(b) end
end)

---------------------------------------------------------------------------
-- admin overlay: blips with range circles + 3D markers nearby
---------------------------------------------------------------------------

function RefreshOverlay()
    for _, b in ipairs(blips) do RemoveBlip(b) end
    blips = {}
    if not overlay then return end
    for _, t in pairs(towers) do
        local color = not t.active and 1 or t.type == 'wifi' and 2 or 3
        local r = AddBlipForRadius(t.x, t.y, t.z, t.range + 0.0)
        SetBlipColour(r, color)
        SetBlipAlpha(r, t.type == 'wifi' and 140 or 70)
        local b = AddBlipForCoord(t.x, t.y, t.z)
        SetBlipSprite(b, t.type == 'wifi' and 521 or 459)
        SetBlipColour(b, color)
        SetBlipScale(b, t.type == 'wifi' and 0.6 or 0.8)
        SetBlipAsShortRange(b, t.type == 'wifi')
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName((t.type == 'wifi' and 'Wi-Fi: ' or 'Tower: ') .. t.name .. (t.active and '' or ' (offline)'))
        EndTextCommandSetBlipName(b)
        blips[#blips + 1] = r
        blips[#blips + 1] = b
    end
end

local function draw3d(x, y, z, text)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

CreateThread(function()
    while true do
        if not overlay then Wait(1000) else
            Wait(0)
            local pos = GetEntityCoords(PlayerPedId())
            for _, t in pairs(towers) do
                local d = #(pos - vector3(t.x, t.y, t.z))
                if d < 250.0 then
                    local r, g, b = 60, 140, 255
                    if t.type == 'wifi' then r, g, b = 50, 210, 100 end
                    if not t.active then r, g, b = 230, 60, 60 end
                    DrawMarker(1, t.x, t.y, t.z - 1.0, 0, 0, 0, 0, 0, 0, 1.2, 1.2, t.type == 'wifi' and 1.5 or 30.0, r, g, b, 140, false, false, 2, false, nil, nil, false)
                    if t.type == 'wifi' and d < t.range + 30 then
                        DrawMarker(28, t.x, t.y, t.z, 0, 0, 0, 0, 0, 0, t.range + 0.0, t.range + 0.0, t.range + 0.0, r, g, b, 25, false, false, 2, false, nil, nil, false)
                    end
                    draw3d(t.x, t.y, t.z + (t.type == 'wifi' and 1.4 or 4.0), ('%s #%d %s~n~%s · %dm%s'):format(t.type == 'wifi' and '~g~Wi-Fi~w~' or '~b~Tower~w~', t.id, t.name,
                        t.type == 'wifi' and (t.ssid or '') or 'cell', t.range, t.active and '' or ' · ~r~OFFLINE'))
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- aim & place tool: a see-through preview follows where you look
---------------------------------------------------------------------------

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

--- returns { x, y, z, heading } or nil when cancelled
---------------------------------------------------------------------------
-- placement HUD: a status card at the top + GTA's own key hints (bottom right)
---------------------------------------------------------------------------

PlaceHud = {}

--- buttons = { { label, control | { controls } }, ... } (first = right-most). Returns a scaleform handle.
function PlaceHud.buttons(buttons)
    local sf = RequestScaleformMovie('instructional_buttons')
    local t = GetGameTimer()
    while not HasScaleformMovieLoaded(sf) and GetGameTimer() - t < 3000 do Wait(0) end
    BeginScaleformMovieMethod(sf, 'CLEAR_ALL') EndScaleformMovieMethod()
    BeginScaleformMovieMethod(sf, 'SET_CLEAR_SPACE') ScaleformMovieMethodAddParamInt(200) EndScaleformMovieMethod()
    for i, b in ipairs(buttons) do
        BeginScaleformMovieMethod(sf, 'SET_DATA_SLOT')
        ScaleformMovieMethodAddParamInt(i - 1)
        local ctls = type(b[2]) == 'table' and b[2] or { b[2] }
        for k = #ctls, 1, -1 do ScaleformMovieMethodAddParamPlayerNameString(GetControlInstructionalButton(0, ctls[k], true)) end
        BeginTextCommandScaleformString('STRING')
        AddTextComponentSubstringPlayerName(b[1])
        EndTextCommandScaleformString()
        EndScaleformMovieMethod()
    end
    BeginScaleformMovieMethod(sf, 'SET_BACKGROUND_COLOUR')
    for _, v in ipairs({ 0, 0, 0, 120 }) do ScaleformMovieMethodAddParamInt(v) end
    EndScaleformMovieMethod()
    BeginScaleformMovieMethod(sf, 'DRAW_INSTRUCTIONAL_BUTTONS') EndScaleformMovieMethod()
    return sf
end

local function hudText(text, x, y, scale, r, g, b, a, font)
    SetTextFont(font or 4)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextCentre(true)
    SetTextDropShadow()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

--- call every frame. accent = { r, g, b }; warn shows the subtitle in red
function PlaceHud.draw(sf, title, subtitle, accent, warn)
    accent = accent or { 10, 132, 255 }
    local x, y, w, h = 0.5, 0.075, 0.24, subtitle and 0.066 or 0.044
    DrawRect(x, y, w, h, 12, 12, 14, 205)
    DrawRect(x, y - h / 2 + 0.002, w, 0.004, accent[1], accent[2], accent[3], 255)
    hudText(title, x, y - h / 2 + 0.008, 0.5, 255, 255, 255, 255, 4)
    if subtitle then
        if warn then hudText(subtitle, x, y + 0.004, 0.36, 255, 110, 100, 255, 4)
        else hudText(subtitle, x, y + 0.004, 0.36, 200, 200, 205, 255, 4) end
    end
    if sf then DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0) end
end

function PlaceHud.release(sf)
    if sf then SetScaleformMovieAsNoLongerNeeded(sf) end
end

local PLACE_TITLES = { wifi = 'Placing Wi-Fi access point', cell = 'Placing cell tower', box = 'Placing cable box', fixture = 'Placing equipment' }

function PlacementMode(kind, model, range, startHeading, title)
    local hash = model and model ~= '' and joaat(model) or nil
    if hash and not IsModelInCdimage(hash) then hash = nil end
    local ghost
    if hash then
        lib.requestModel(hash, 5000)
        local c = GetEntityCoords(PlayerPedId())
        ghost = CreateObject(hash, c.x, c.y, c.z, false, false, false)
        SetEntityAlpha(ghost, 170, false)
        SetEntityCollision(ghost, false, false)
        FreezeEntityPosition(ghost, true)
        SetModelAsNoLongerNeeded(hash)
    end
    local heading = startHeading or GetEntityHeading(PlayerPedId())
    local lift = 0.0
    local result
    local sf = PlaceHud.buttons({
        { 'Place', { 24, 191 } }, { 'Cancel', { 25, 177 } }, { 'Rotate', { 44, 38 } }, { 'Raise / lower', { 172, 173 } }, { 'Fine', 21 },
    })
    title = title or PLACE_TITLES[kind] or 'Placing'
    while true do
        Wait(0)
        for _, ctl in ipairs({ 14, 15, 16, 17, 24, 25, 37, 44, 38, 140, 141, 142, 172, 173, 174, 175, 177, 191, 199, 200, 261, 262 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local fine = IsControlPressed(0, 21)
        local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local to = camPos + rotToDir(camRot) * 25.0
        local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1 + 16, ghost or PlayerPedId(), 4)
        local _, hit, at = GetShapeTestResult(ray)
        if hit ~= 1 then at = to end
        -- the player's own ped isn't a surface
        if #(at - GetEntityCoords(PlayerPedId())) < 0.6 then at = GetEntityCoords(PlayerPedId()) - vector3(0.0, 0.0, 0.98) end
        local step = fine and 1.0 or 4.0
        if IsDisabledControlJustPressed(0, 14) or IsDisabledControlJustPressed(0, 261) then heading = heading - step * 3 end
        if IsDisabledControlJustPressed(0, 15) or IsDisabledControlJustPressed(0, 262) then heading = heading + step * 3 end
        if IsDisabledControlPressed(0, 44) then heading = heading + step * 0.6 end
        if IsDisabledControlPressed(0, 38) then heading = heading - step * 0.6 end
        if IsDisabledControlPressed(0, 172) then lift = lift + (fine and 0.004 or 0.02) end
        if IsDisabledControlPressed(0, 173) then lift = lift - (fine and 0.004 or 0.02) end
        local pos = vector3(at.x, at.y, at.z + lift)
        if ghost then
            SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
            SetEntityHeading(ghost, heading)
        end
        -- target + live range preview
        DrawMarker(28, pos.x, pos.y, pos.z, 0, 0, 0, 0, 0, 0, 0.08, 0.08, 0.08, 255, 255, 255, 220, false, false, 2, false, nil, nil, false)
        if kind == 'wifi' then
            DrawMarker(28, pos.x, pos.y, pos.z, 0, 0, 0, 0, 0, 0, range + 0.0, range + 0.0, Config.Wifi.FloorTolerance + 0.0, 50, 210, 100, 30, false, false, 2, false, nil, nil, false)
        elseif kind ~= 'fixture' then
            DrawMarker(1, pos.x, pos.y, pos.z - 1.0, 0, 0, 0, 0, 0, 0, math.min(range, 300) * 2.0, math.min(range, 300) * 2.0, 2.0, 60, 140, 255, 60, false, false, 2, false, nil, nil, false)
        end
        PlaceHud.draw(sf, title, ('Heading %d°   ·   Height %+.2f m%s'):format(math.floor(heading % 360), lift, fine and '   ·   fine' or ''))
        if IsDisabledControlJustPressed(0, 24) or IsDisabledControlJustPressed(0, 191) then
            result = { x = pos.x, y = pos.y, z = pos.z, heading = heading % 360 }
            break
        end
        if IsDisabledControlJustPressed(0, 25) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    PlaceHud.release(sf)
    if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
    return result
end

---------------------------------------------------------------------------
-- /towers menu
---------------------------------------------------------------------------

local function save(data)
    local r = lib.callback.await('opslabs-towers:save', false, data)
    if not r or r.error then
        lib.notify({ type = 'error', description = (r and r.error) or 'Could not save tower' })
        return nil
    end
    lib.notify({ type = 'success', description = ('%s "%s" saved'):format(r.tower.type == 'wifi' and 'Wi-Fi' or 'Tower', r.tower.name) })
    return r.tower
end

local function editDialog(t, kind)
    kind = t and t.type or kind
    local lim = kind == 'wifi' and Config.Wifi or Config.Cell
    local fields = {
        { type = 'input', label = 'Name', icon = 'tag', default = t and t.name or (kind == 'wifi' and 'Building Wi-Fi' or 'New Tower'), required = true, max = 60 },
        { type = 'number', label = 'Range (metres)', icon = 'bullseye', description = ('%d – %d m'):format(lim.MinRange, lim.MaxRange), default = t and t.range or lim.DefaultRange, min = lim.MinRange, max = lim.MaxRange, required = true },
    }
    local function propOptions(list, fallback)
        local options, current = { { value = '', label = 'No prop' } }, ''
        for _, p in ipairs(list or {}) do
            if IsModelInCdimage(joaat(p.model)) then options[#options + 1] = { value = p.model, label = p.label } end
        end
        if t and t.prop then current = t.model or fallback or '' end
        return options, current
    end
    if kind == 'wifi' then
        local pw = t and t.secured and lib.callback.await('opslabs-towers:password', false, t.id) or ''
        local options, current = propOptions(Config.Wifi.Props, Config.Wifi.Prop)
        fields[#fields + 1] = { type = 'input', label = 'Network name (SSID)', icon = 'wifi', default = t and t.ssid or '', max = 40 }
        fields[#fields + 1] = { type = 'input', label = 'Password', icon = 'lock', description = ('Leave empty for an open network · at least %d characters'):format(Config.Wifi.PasswordMin or 4), default = pw, password = true, max = 64 }
        fields[#fields + 1] = { type = 'input', label = 'Restrict to jobs', icon = 'briefcase', description = 'Comma separated, e.g. police,ambulance · empty = everyone', default = t and t.jobs or '', max = 120 }
        fields[#fields + 1] = { type = 'select', label = 'Router / AP model', icon = 'cube', options = options, default = current, searchable = true }
    else
        local options, current = propOptions(Config.Cell.Props, Config.Cell.Prop)
        options[1].label = 'No prop (invisible tower)'
        fields[#fields + 1] = { type = 'select', label = 'Mast / dish model', icon = 'cube', options = options, default = current }
    end
    fields[#fields + 1] = { type = 'checkbox', label = 'Online (broadcasting)', checked = not t or t.active }
    local v = lib.inputDialog(t and ('Edit ' .. t.name) or (kind == 'wifi' and 'New Wi-Fi access point' or 'New cell tower'), fields)
    if not v then return nil end
    local data = { id = t and t.id, type = kind, name = v[1], range = v[2] }
    if kind == 'wifi' then data.ssid, data.password, data.jobs, data.model, data.active = v[3], v[4] or '', v[5], v[6] or '', v[7]
    else data.model, data.active = v[3] or '', v[4] end
    if not t then
        -- new tower: aim where it goes
        local spot = PlacementMode(kind, data.model, tonumber(data.range) or lim.DefaultRange)
        if not spot then lib.notify({ type = 'inform', description = 'Placing cancelled' }) return nil end
        data.x, data.y, data.z, data.heading, data.exact = spot.x, spot.y, spot.z, spot.heading, true
    end
    return save(data)
end

-- The menu stays open: every action re-opens the menu it came from. It only
-- closes with Esc / Backspace or the close button.
local TowerMenu, NearbyMenu, MainMenu, BulkMenuOpen

local function freshTower(t)
    return (t and towers[t.id]) or t
end

local GREEN, BLUE, ORANGE, RED, GREY = '#30d158', '#0a84ff', '#ff9f0a', '#ff453a', '#8e8e93'

local function propLabel(t)
    if not t.prop then return 'None' end
    for _, p in ipairs((t.type == 'wifi' and Config.Wifi.Props or Config.Cell.Props) or {}) do
        if p.model == t.model then return p.label end
    end
    return t.model or 'Default'
end

local function distText(d)
    return d >= 1000 and ('%.1f km'):format(d / 1000) or ('%d m'):format(math.floor(d))
end

TowerMenu = function(t)
    t = freshTower(t)
    if not t then return NearbyMenu() end
    local wifi = t.type == 'wifi'
    local d = #(GetEntityCoords(PlayerPedId()) - vector3(t.x, t.y, t.z))
    local meta = {
        { label = 'Status', value = t.active and 'Online' or 'Offline (outage)' },
        { label = 'Range', value = t.range .. ' m' },
        { label = 'Distance', value = distText(d) },
        { label = 'Prop', value = propLabel(t) },
    }
    if wifi then
        table.insert(meta, 2, { label = 'SSID', value = (t.ssid and t.ssid ~= '') and t.ssid or t.name })
        table.insert(meta, 3, { label = 'Security', value = t.secured and 'WPA2 · password' or 'Open' })
        if t.jobs and t.jobs ~= '' then table.insert(meta, 4, { label = 'Jobs', value = t.jobs }) end
    end
    meta[#meta + 1] = { label = 'Position', value = ('%.1f, %.1f, %.1f'):format(t.x, t.y, t.z) }
    lib.registerContext({
        id = 'towers_one', title = (wifi and 'Wi-Fi · ' or 'Cell tower · ') .. t.name, menu = 'towers_nearby',
        onBack = function() NearbyMenu() end,
        options = {
            { title = t.active and 'Online' or 'Offline', description = ('#%d · %s · %d m range'):format(t.id, wifi and ((t.ssid and t.ssid ~= '') and t.ssid or 'Wi-Fi') or 'Cell site', t.range),
              icon = wifi and 'wifi' or 'tower-cell', iconColor = t.active and GREEN or RED, metadata = meta, readOnly = true },
            { title = 'Edit details', description = wifi and 'Name, range, SSID, password, jobs, prop' or 'Name, range, prop', icon = 'pen-to-square', iconColor = BLUE, onSelect = function()
                TowerMenu(editDialog(t) or t)
            end },
            { title = t.active and 'Take offline' or 'Bring online', description = t.active and 'Simulate an outage — phones here lose this signal' or 'Restore the signal',
              icon = 'power-off', iconColor = t.active and ORANGE or GREEN, onSelect = function()
                TowerMenu(save({ id = t.id, active = not t.active }) or t)
            end },
            { title = 'Move · aim & place', description = 'Preview follows your aim · scroll rotates · arrows set height', icon = 'up-down-left-right', iconColor = BLUE, onSelect = function()
                local model = t.prop and (t.model or (wifi and Config.Wifi.Prop or Config.Cell.Prop)) or nil
                local spot = PlacementMode(t.type, model, t.range, t.heading)
                if spot then TowerMenu(save({ id = t.id, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading, exact = true }) or t)
                else TowerMenu(t) end
            end },
            { title = 'Move to my feet', icon = 'person-walking', onSelect = function()
                local c = GetEntityCoords(PlayerPedId())
                TowerMenu(save({ id = t.id, x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(PlayerPedId()), exact = false }) or t)
            end },
            { title = 'Set GPS waypoint', icon = 'map-location-dot', onSelect = function()
                SetNewWaypoint(t.x, t.y)
                lib.notify({ type = 'inform', description = 'Waypoint set to ' .. t.name })
                TowerMenu(t)
            end },
            { title = 'Teleport here', icon = 'location-arrow', onSelect = function()
                SetEntityCoords(PlayerPedId(), t.x, t.y, t.z + 0.2, false, false, false, false)
                TowerMenu(t)
            end },
            { title = 'Delete', description = 'Removes it for good', icon = 'trash', iconColor = RED, onSelect = function()
                if lib.alertDialog({ header = 'Delete ' .. t.name .. '?', content = 'Phones around it will lose this signal.', centered = true, cancel = true }) == 'confirm' then
                    if lib.callback.await('opslabs-towers:delete', false, t.id) then
                        lib.notify({ type = 'success', description = t.name .. ' deleted' })
                        towers[t.id] = nil
                        return NearbyMenu()
                    end
                end
                TowerMenu(t)
            end },
        },
    })
    lib.showContext('towers_one')
end

local listFilter = 'all'
local FILTERS = { all = 'All', cell = 'Cell towers', wifi = 'Wi-Fi', offline = 'Offline' }
local FILTER_NEXT = { all = 'cell', cell = 'wifi', wifi = 'offline', offline = 'all' }

NearbyMenu = function()
    local pos = GetEntityCoords(PlayerPedId())
    local list, total, off = {}, 0, 0
    for _, t in pairs(towers) do
        total = total + 1
        if not t.active then off = off + 1 end
        local keep = listFilter == 'all' or (listFilter == 'offline' and not t.active) or t.type == listFilter
        if keep then list[#list + 1] = { t = t, d = #(pos - vector3(t.x, t.y, t.z)) } end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local options = {
        { title = ('Showing: %s'):format(FILTERS[listFilter]), description = ('%d of %d · %d offline · click to change'):format(#list, total, off),
          icon = 'filter', iconColor = BLUE, onSelect = function() listFilter = FILTER_NEXT[listFilter] NearbyMenu() end },
    }
    for i = 1, math.min(#list, 40) do
        local t, d = list[i].t, list[i].d
        local wifi = t.type == 'wifi'
        local inside = d <= t.range
        options[#options + 1] = {
            title = t.name,
            description = ('%s · %s away%s'):format(wifi and ('Wi-Fi' .. (t.secured and ' · locked' or ' · open')) or 'Cell tower', distText(d), t.active and '' or ' · OFFLINE'),
            icon = wifi and 'wifi' or 'tower-cell', iconColor = not t.active and RED or wifi and GREEN or BLUE,
            progress = t.active and math.max(4, math.floor((1 - math.min(1, d / t.range)) * 100)) or nil,
            colorScheme = inside and 'green' or 'gray',
            metadata = {
                { label = 'Status', value = t.active and 'Online' or 'Offline' },
                { label = 'Range', value = t.range .. ' m' },
                { label = 'You are', value = inside and 'inside its coverage' or 'outside its coverage' },
                wifi and { label = 'SSID', value = (t.ssid and t.ssid ~= '') and t.ssid or t.name } or { label = 'Prop', value = propLabel(t) },
            },
            arrow = true,
            onSelect = function() TowerMenu(t) end,
        }
    end
    if #list == 0 then options[#options + 1] = { title = total == 0 and 'No towers yet — place one from the main menu' or 'Nothing matches this filter', icon = 'circle-info', readOnly = true } end
    lib.registerContext({ id = 'towers_nearby', title = 'Towers & access points', menu = 'towers_main', onBack = function() MainMenu() end, options = options })
    lib.showContext('towers_nearby')
end

local function bulk(sel, action, label)
    local r = lib.callback.await('opslabs-towers:bulk', false, sel, action)
    if not r or r.error then return lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    lib.notify({ type = 'success', description = ('%s %d tower%s'):format(label, r.count, r.count == 1 and '' or 's') })
    Wait(250) -- let the updated list arrive before the menu redraws
end

local function confirmBulk(text, sel, action, label)
    if lib.alertDialog({ header = text .. '?', content = 'Phones in those areas lose this signal. This cannot be undone.', centered = true, cancel = true }) == 'confirm' then
        bulk(sel, action, label)
    end
end

local function pickTowers(action, label)
    local pos = GetEntityCoords(PlayerPedId())
    local list = {}
    for _, t in pairs(towers) do list[#list + 1] = { t = t, d = #(pos - vector3(t.x, t.y, t.z)) } end
    table.sort(list, function(a, b) return a.d < b.d end)
    local options = {}
    for _, e in ipairs(list) do
        options[#options + 1] = { value = tostring(e.t.id), label = ('%s — %s, %s away%s'):format(e.t.name, e.t.type == 'wifi' and 'Wi-Fi' or 'cell', distText(e.d), e.t.active and '' or ' (offline)') }
    end
    if #options == 0 then return lib.notify({ type = 'inform', description = 'No towers' }) end
    local v = lib.inputDialog(label .. ' towers', { { type = 'multi-select', label = 'Towers (nearest first)', options = options, searchable = true, required = true } })
    if not v or not v[1] or #v[1] == 0 then return end
    if action == 'delete' then confirmBulk(('Delete %d towers'):format(#v[1]), { ids = v[1] }, action, 'Deleted')
    else bulk({ ids = v[1] }, action, label) end
end

BulkMenuOpen = function()
    local cells, wifis, offline = 0, 0, 0
    for _, t in pairs(towers) do
        if t.type == 'wifi' then wifis = wifis + 1 else cells = cells + 1 end
        if not t.active then offline = offline + 1 end
    end
    local function run(fn) return function() fn(); BulkMenuOpen() end end
    lib.registerContext({
        id = 'towers_bulk', title = 'Bulk actions', menu = 'towers_main', onBack = function() MainMenu() end,
        options = {
            { title = ('%d cell · %d Wi-Fi · %d offline'):format(cells, wifis, offline), description = 'Pick towers from a list, or act on a whole group', icon = 'layer-group', readOnly = true },
            { title = 'Take towers offline…', description = 'Tick towers from a list', icon = 'power-off', iconColor = ORANGE, onSelect = run(function() pickTowers('offline', 'Took offline') end) },
            { title = 'Bring towers online…', description = 'Tick towers from a list', icon = 'bolt', iconColor = GREEN, onSelect = run(function() pickTowers('online', 'Brought online') end) },
            { title = 'Delete towers…', description = 'Tick towers from a list', icon = 'list-check', iconColor = RED, onSelect = run(function() pickTowers('delete', 'Delete') end) },
            { title = ('Delete all offline (%d)'):format(offline), icon = 'trash', iconColor = RED, disabled = offline == 0, onSelect = run(function() confirmBulk('Delete all offline towers', { all = true, offline = true }, 'delete', 'Deleted') end) },
            { title = ('Delete all Wi-Fi (%d)'):format(wifis), icon = 'wifi', iconColor = RED, disabled = wifis == 0, onSelect = run(function() confirmBulk('Delete all Wi-Fi access points', { all = true, type = 'wifi' }, 'delete', 'Deleted') end) },
            { title = ('Delete all cell towers (%d)'):format(cells), icon = 'tower-cell', iconColor = RED, disabled = cells == 0, onSelect = run(function() confirmBulk('Delete all cell towers', { all = true, type = 'cell' }, 'delete', 'Deleted') end) },
            { title = ('Delete everything (%d)'):format(cells + wifis), description = 'Every tower and access point', icon = 'triangle-exclamation', iconColor = RED, disabled = cells + wifis == 0, onSelect = run(function() confirmBulk('Delete every tower and Wi-Fi', { all = true }, 'delete', 'Deleted') end) },
        },
    })
    lib.showContext('towers_bulk')
end
BulkMenu = BulkMenuOpen

MainMenu = function()
    local here = lib.callback.await('opslabs-towers:here', false) or { cell = 0 }
    local cells, wifis, off = 0, 0, 0
    for _, t in pairs(towers) do
        if t.type == 'wifi' then wifis = wifis + 1 else cells = cells + 1 end
        if not t.active then off = off + 1 end
    end
    local bars = here.cell or 0
    lib.registerContext({
        id = 'towers_main', title = 'OPS Mobile · Network',
        options = {
            { title = bars > 0 and ('Signal here · %d/4 bars · %s'):format(bars, here.net or 'LTE') or 'No signal here',
              description = here.tower and ('Served by ' .. here.tower) or 'Only emergency calls work here',
              icon = 'signal', iconColor = bars >= 3 and GREEN or bars >= 1 and ORANGE or RED,
              progress = math.max(3, bars * 25), colorScheme = bars >= 3 and 'green' or bars >= 1 and 'yellow' or 'red',
              metadata = {
                  { label = 'Cell', value = bars > 0 and (('%d/4 · %s'):format(bars, here.net or 'LTE')) or 'none' },
                  { label = 'Tower', value = here.tower or '—' },
                  { label = 'Wi-Fi', value = here.wifi and (here.wifi.ssid .. (here.wifi.secured and ' (locked)' or '')) or 'none in range' },
                  { label = 'Enforced', value = Config.Enforce and 'yes' or 'no (everyone has full signal)' },
              }, readOnly = true },
            { title = 'Place a cell tower', description = ('Set it up, then aim where it goes · %d m default range'):format(Config.Cell.DefaultRange), icon = 'tower-cell', iconColor = BLUE, onSelect = function()
                local t = editDialog(nil, 'cell')
                if t then Wait(250) return TowerMenu(t) end
                MainMenu()
            end },
            { title = 'Place a Wi-Fi access point', description = ('Aim at a desk, shelf or ceiling · %d m default · optional password'):format(Config.Wifi.DefaultRange), icon = 'wifi', iconColor = GREEN, onSelect = function()
                local t = editDialog(nil, 'wifi')
                if t then Wait(250) return TowerMenu(t) end
                MainMenu()
            end },
            { title = 'Towers & access points', description = ('%d cell · %d Wi-Fi%s'):format(cells, wifis, off > 0 and (' · %d offline'):format(off) or ''), icon = 'list-ul', arrow = true, onSelect = function() NearbyMenu() end },
            { title = 'Bulk actions', description = 'Switch off or delete many at once', icon = 'layer-group', arrow = true, onSelect = function() BulkMenuOpen() end },
            { title = 'Cabling & equipment', description = ('CAT6, fibre, trunking, poles, ladders, ONTs · also /%s'):format(Config.Cabling.Command), icon = 'ethernet', arrow = true, onSelect = function() if OpenCableMenu then OpenCableMenu() end end },
            { title = 'Coverage overlay', description = overlay and 'On — range circles on the map and markers in the world' or 'Off — show range circles on the map',
              icon = overlay and 'eye' or 'eye-slash', iconColor = overlay and GREEN or GREY, onSelect = function()
                overlay = not overlay
                RefreshOverlay()
                MainMenu()
            end },
        },
    })
    lib.showContext('towers_main')
end

RegisterCommand(Config.Command, function()
    if not lib.callback.await('opslabs-towers:isAdmin', false) then
        return lib.notify({ type = 'error', description = 'You are not allowed to manage towers' })
    end
    MainMenu()
end, false)
