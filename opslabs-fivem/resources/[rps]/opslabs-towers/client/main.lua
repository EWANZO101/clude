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

local propExtras = {}   -- tower id -> extra entities (Config.Cell.Extras)

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
                for _, e in ipairs(propExtras[id] or {}) do if DoesEntityExist(e) then DeleteEntity(e) end end
                props[id], propExtras[id] = nil, nil
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
                    -- ground kit that goes with a mast (lattice mast → cabin, gantry, fenced compound), same origin
                    local extras = {}
                    for _, m in ipairs(((Config.Cell or {}).Extras or {})[t.model or ''] or {}) do
                        local eh = joaat(m)
                        if IsModelInCdimage(eh) then
                            lib.requestModel(eh, 5000)
                            local at = GetEntityCoords(ent)
                            local x = CreateObjectNoOffset(eh, at.x, at.y, at.z, false, false, false)
                            SetEntityHeading(x, GetEntityHeading(ent))
                            FreezeEntityPosition(x, true)
                            SetModelAsNoLongerNeeded(eh)
                            extras[#extras + 1] = x
                        end
                    end
                    propExtras[id] = extras
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, ent in pairs(props) do if DoesEntityExist(ent) then DeleteEntity(ent) end end
    for _, list in pairs(propExtras) do for _, e in ipairs(list) do if DoesEntityExist(e) then DeleteEntity(e) end end end
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
    local near, nextScan = {}, 0
    while true do
        if not overlay then Wait(1000) nextScan = 0 else
            Wait(0)
            local pos = GetEntityCoords(PlayerPedId())
            -- only re-scan the tower list twice a second; draw the cached nearby ones every frame
            if GetGameTimer() >= nextScan then
                nextScan = GetGameTimer() + 500
                near = {}
                for _, t in pairs(towers) do
                    if #(pos - vector3(t.x, t.y, t.z)) < 260.0 then near[#near + 1] = t end
                end
            end
            for _, t in ipairs(near) do
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

function PlacementMode(kind, model, range, startHeading, title, opts)
    -- buildings are big: let the aim reach far enough to put one down without standing inside it
    local reach = (opts and opts.reach) or 25.0
    for _, e in ipairs((Config.Cabling or {}).Equipment or {}) do
        if e.building and e.model == model then reach = math.max(reach, 90.0) end
        if e.reach and e.model == model then reach = math.max(reach, e.reach) end
    end
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
        local to = camPos + rotToDir(camRot) * reach
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
        local extra = opts and opts.onFrame and opts.onFrame(pos, heading % 360)
        PlaceHud.draw(sf, title, ('Heading %d°   ·   Height %+.2f m%s%s'):format(math.floor(heading % 360), lift, fine and '   ·   fine' or '', extra and ('   ·   ' .. extra) or ''))
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
    if kind == 'wifi' then
        fields[#fields + 1] = { type = 'checkbox', label = 'Only online when connected to the fibre network', checked = t and t.fibre_only == true or false }
    end
    local v = lib.inputDialog(t and ('Edit ' .. t.name) or (kind == 'wifi' and 'New Wi-Fi access point' or 'New cell tower'), fields)
    if not v then return nil end
    local data = { id = t and t.id, type = kind, name = v[1], range = v[2] }
    if kind == 'wifi' then data.ssid, data.password, data.jobs, data.model, data.active, data.fibre_only = v[3], v[4] or '', v[5], v[6] or '', v[7], v[8] == true
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
        if t.fibre_only then
            local on = lib.callback.await('opslabs-towers:wifiFibre', false, t.id)
            table.insert(meta, 2, { label = 'Fibre', value = on and 'Connected — broadcasting' or 'Not connected — silent until it is cabled to a gateway with live fibre' })
        end
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
    lib.registerContext({ id = 'towers_nearby', title = 'Towers & access points', menu = 'towers_sec_mobile', onBack = function() if MobileSection then MobileSection() else MainMenu() end end, options = options })
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
        id = 'towers_bulk', title = 'Bulk actions', menu = 'towers_sec_mobile', onBack = function() if MobileSection then MobileSection() else MainMenu() end end,
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

local SectionMenu

--- one section per company / supplier
local function mobileSection()
    local here = lib.callback.await('opslabs-towers:here', false) or { cell = 0 }
    local cells, wifis, off = 0, 0, 0
    for _, t in pairs(towers) do
        if t.type == 'wifi' then wifis = wifis + 1 else cells = cells + 1 end
        if not t.active then off = off + 1 end
    end
    local bars = here.cell or 0
    lib.registerContext({ id = 'towers_sec_mobile', title = 'OPS Mobile · cell & Wi-Fi', menu = 'towers_main', onBack = function() MainMenu() end, options = {
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
            mobileSection()
        end },
        { title = 'Place a Wi-Fi access point', description = ('Aim at a desk, shelf or ceiling · %d m default · optional password'):format(Config.Wifi.DefaultRange), icon = 'wifi', iconColor = GREEN, onSelect = function()
            local t = editDialog(nil, 'wifi')
            if t then Wait(250) return TowerMenu(t) end
            mobileSection()
        end },
        { title = 'Towers & access points', description = ('%d cell · %d Wi-Fi%s'):format(cells, wifis, off > 0 and (' · %d offline'):format(off) or ''), icon = 'list-ul', arrow = true, onSelect = function() NearbyMenu() end },
        { title = 'Bulk actions', description = 'Switch off or delete many at once', icon = 'layer-group', arrow = true, onSelect = function() BulkMenuOpen() end },
        { title = 'Coverage overlay', description = overlay and 'On — range circles on the map and markers in the world' or 'Off — show range circles on the map',
          icon = overlay and 'eye' or 'eye-slash', iconColor = overlay and GREEN or GREY, onSelect = function()
            overlay = not overlay
            RefreshOverlay()
            mobileSection()
        end },
        { title = 'Open in OPS Hub', description = 'Live tower map: coverage, dead zones, players · opens in your browser', icon = 'arrow-up-right-from-square', iconColor = BLUE,
          onSelect = function() if OpenHub then OpenHub('mobile') end end },
    } })
    lib.showContext('towers_sec_mobile')
end

MobileSection = mobileSection

local function netById(id)
    for _, n in ipairs(Config.Cabling.Networks or {}) do if n.id == id then return n end end
end

local fieldMode = false   -- opened with /cable (engineers): no OPS Mobile section

local function buildingIcon(model)
    return model:find('house') and 'house' or model:find('depot') and 'warehouse' or 'building'
end

--- the page for this service on OPS Hub, opened in the player's browser
function OpenHub(section)
    local H = Config.Hub or {}
    local url = (H.Url or ''):gsub('/*$', '/') .. ((H.Pages or {})[section] or '')
    SendNUIMessage({ action = 'openUrl', url = url })
    lib.notify({ type = 'inform', description = 'Opening OPS Hub in your browser' })
end
local function hubLink(section, what)
    return { title = 'Open in OPS Hub', description = (what or 'The staff website') .. ' · opens in your browser', icon = 'arrow-up-right-from-square', iconColor = '#0a84ff',
        onSelect = function() OpenHub(section) end }
end

--- a section heading inside a menu (not selectable)
local function head(title, icon) return { title = title, icon = icon or 'minus', iconColor = '#636366', readOnly = true } end

--- ONTs within 150 m → their internet service (provision, change plan, suspend / resume, cease)
local function ontServiceList(back)
    local pos = GetEntityCoords(PlayerPedId())
    local ONT = (Config.Isp or {}).Ont or 'opslabs_ont'
    local list = {}
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f.model == ONT then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d <= 150.0 then list[#list + 1] = { f = f, d = d } end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local options = {}
    for _, n in ipairs(list) do
        local o = OntReading and OntReading(n.f.id) or {}
        local state = o.los and 'No light (LOS)' or o.service == 'none' and 'Fibre live · no service' or o.service == 'suspended' and 'Suspended'
            or (o.internet == 'on' and 'Online' or 'Not online')
        options[#options + 1] = { title = ('ONT #%d · %s'):format(n.f.id, o.customer or state), arrow = true,
            description = ('%d m away · %s%s'):format(math.floor(n.d), state, o.provider and (' · ' .. o.provider .. ' ' .. (o.plan or '')) or ''),
            icon = 'wifi', iconColor = o.los and RED or o.internet == 'on' and GREEN or ORANGE,
            onSelect = function() if IspMenu then IspMenu(n.f, function() ontServiceList(back) end) end end }
    end
    if #options == 0 then options[1] = { title = 'No ONTs within 150 m', description = 'Fit one: Telecom equipment → Customer premises · inside', readOnly = true } end
    lib.registerContext({ id = 'towers_onts', title = 'Internet service · nearby ONTs', options = options })
    lib.showContext('towers_onts')
end

--- every category of one network's equipment, as arrows (optionally only some)
local function cats(add, net, list)
    local A = CableActions or {}
    for _, c in ipairs(list) do
        local n = 0
        for _, e in ipairs(Config.Cabling.Equipment or {}) do if (e.net or 'openline') == net.id and e.cat == c[1] then n = n + 1 end end
        if n > 0 then
            add({ title = c[1], description = c[2], icon = c[3] or 'boxes-stacked', iconColor = c[4] or net.color, arrow = true, onSelect = function() A.equipmentCat(net, c[1]) end })
        end
    end
end

SectionMenu = function(id)
    local A = CableActions or {}
    local back = function() SectionMenu(id) end
    local net = netById(id)
    local options = {}
    local function add(o) options[#options + 1] = o end
    if id == 'openline' then
        add(head('Equipment', 'boxes-stacked'))
        add({ title = 'Telecom equipment', description = 'Poles · exchange kit & plant · cabinets & chambers · underground joints · pole kit · customer premises · copper', icon = 'boxes-stacked', iconColor = net.color, arrow = true, onSelect = function() A.equipment(net) end })
        add(head('Fibre & CAT6', 'ethernet'))
        add({ title = 'Place a cable box or drum', description = 'CAT6, black / yellow fibre, spine feed or ULW drop', icon = 'box-open', iconColor = BLUE, onSelect = function() A.placeBox(back) end })
        add({ title = 'Pull cable from the nearest box', description = 'Fix along walls and poles, finish on the kit · G puts it down', icon = 'ethernet', iconColor = BLUE, onSelect = function() A.pull(back) end })
        add({ title = 'Cable you put down', description = 'Loose ends lying nearby · waypoint to one, press E there to carry on', icon = 'hand', iconColor = BLUE, arrow = true, onSelect = function() if LooseEndsMenu then LooseEndsMenu() end end })
        add(head('Copper', 'phone'))
        add({ title = 'Run phone cable (copper)', description = 'Drop wire, internal CW1308 or 50-pair · punch down on DPs, sockets, cabinets, the MDF', icon = 'phone', iconColor = '#bf5af2', onSelect = function() A.copper(back) end })
        add(head('Overhead & containment', 'grip-lines'))
        add({ title = 'Guild wires', description = 'Steel support wire between poles · lash fibre to it · hook heights', icon = 'grip-lines', iconColor = '#98989d', arrow = true, onSelect = function() if GuyMenu then GuyMenu() end end })
        add({ title = 'Trunking, capping & ducts', description = 'Trunking, steel / plastic capping, sub-duct, blown fibre tubing', icon = 'grip-lines-vertical', iconColor = BLUE, onSelect = function() A.trunking(back) end })
        add(head('Customers', 'house-signal'))
        add({ title = 'Internet service', description = 'Nearby ONTs · provision, change plan, suspend / resume, cease', icon = 'globe', iconColor = GREEN, arrow = true, onSelect = function() ontServiceList(back) end })
        add(head('Public safety', 'shield-halved'))
        cats(add, net, { { 'Public safety', 'OPS Sentinel gunshot sensors — on poles or walls, alert police over LTE', 'shield-halved' } })
        add(hubLink('openline', 'Internet service, ONTs, poles & faults'))
        add(hubLink('gunshots', 'Gunshot detection: live incidents & sensor status'))
    elseif id == 'usfiber' then
        -- OPS America Fiber (US FTTH): OPS America Fiber · Outside Plant · Network Ops share this menu
        add(head('Central office · OPS America Network Ops', 'building'))
        cats(add, net, {
            { 'Central office · optical & routing', 'OLT · ODF · aggregation / core router · internet edge router / BNG', 'server' },
            { 'Central office · power & HVAC', 'Rectifiers · DC plant · battery string · standby generator · HVAC', 'car-battery' },
        })
        add(head('Outside plant · OPS America Outside Plant', 'person-digging'))
        cats(add, net, {
            { 'Utility poles', '25 / 35 / 45 ft poles', 'tower-observation' },
            { 'Outside plant · cabinets & underground', 'FDH · handholes · vaults · manholes · underground closures', 'box-archive' },
            { 'Outside plant · aerial', 'FDT · aerial & dome closures · snowshoe · brackets · drop hooks — also from the pole (G)', 'diagram-project' },
        })
        add({ title = 'Place a fiber reel', description = 'Feeder, distribution or drop fiber', icon = 'box-open', iconColor = net.color, onSelect = function() A.placeBox(back) end })
        add({ title = 'Pull fiber from the nearest reel', description = 'Lash to strand on poles, or through conduit · finish on the kit', icon = 'ethernet', iconColor = net.color, onSelect = function() A.pull(back) end })
        add({ title = 'Messenger strand & guy wires', description = 'Steel strand between poles · lash fiber to it · anchors & guys', icon = 'grip-lines', iconColor = '#98989d', arrow = true, onSelect = function() if GuyMenu then GuyMenu() end end })
        add({ title = 'Conduit & innerduct', description = 'Sub-duct, blown fiber tubing, trunking', icon = 'grip-lines-vertical', iconColor = net.color, onSelect = function() A.trunking(back) end })
        add({ title = 'Cable you put down', description = 'Loose ends lying nearby · waypoint to one, press E there to carry on', icon = 'hand', iconColor = net.color, arrow = true, onSelect = function() if LooseEndsMenu then LooseEndsMenu() end end })
        add(head('Customers · OPS America Fiber', 'house-signal'))
        cats(add, net, { { 'Customer premises', 'NID / drop box · drop clamp · feed-through · ONT · splice tray', 'house-signal' } })
        add({ title = 'Internet service (activation)', description = 'Nearby ONTs · register, provision an OPS America Fiber plan, suspend, cease', icon = 'globe', iconColor = GREEN, arrow = true, onSelect = function() ontServiceList(back) end })
        add(hubLink('openline', 'Internet service, ONTs, poles & faults'))
    elseif id == 'streamfibre' then
        add({ title = 'StreamFibre equipment', description = 'Alt-net CBT, provider tags, shared (PIA) brackets', icon = 'boxes-stacked', iconColor = net.color, arrow = true, onSelect = function() A.equipment(net) end })
        add({ title = 'Place a fibre drum', description = 'Black / yellow fibre, spine feed or ULW drop', icon = 'box-open', iconColor = net.color, onSelect = function() A.placeBox(back) end })
        add({ title = 'Pull fibre from the nearest drum', description = 'Shares the poles with OPS Openline', icon = 'ethernet', iconColor = net.color, onSelect = function() A.pull(back) end })
        add({ title = 'Cable you put down', description = 'Loose ends lying nearby · waypoint to one, press E there to pick it up', icon = 'hand', iconColor = net.color, arrow = true, onSelect = function() if LooseEndsMenu then LooseEndsMenu() end end })
        add(hubLink('streamfibre', 'Internet service & faults'))
    elseif id == 'sapl' then
        add(head('Bulk grid · generation & substations', 'industry'))
        cats(add, net, {
            { 'Generation', 'Gas power station (4 × 120 MW) · wind turbines', 'industry' },
            { 'Transmission', '400 kV lattice pylons — carry 400 kV conductor between stations and substations', 'tower-broadcast' },
            { 'Substations', 'Outdoor yard · substation building fully fitted · empty building · RTU pole (turns any building into a substation)', 'building-shield' },
            { 'Substation plant', 'Transformers, 400 kV GIS, 11 kV switchgear, busbars, protection, metering, DC battery, earth bar, control desk, cable ends', 'gears' },
        })
        add({ title = 'How a substation works', description = '400 kV line → GIS incomer → busbar → transformer → busbar → 11 kV switchgear → feeder. Needs protection, DC battery and earthing to energise; an RTU gives Grid control remote switching.', icon = 'circle-info', readOnly = true })
        add(hubLink('grid', 'Grid control: switching, load, faults'))
        add(head('Overhead network', 'tower-observation'))
        cats(add, net, {
            { 'Power poles', 'Wooden power poles with cross-arms & insulators', 'tower-observation' },
            { 'On the power pole', 'Transformer, cut-outs, PMAR, pothead, LV connectors — also fitted from the pole (G)', 'bolt' },
            { 'Safety & earthing', 'Earth tape, anti-climbing device, Danger of Death sign', 'triangle-exclamation' },
            { 'Street lighting', 'Lighting columns and pole-mounted lanterns', 'road' },
        })
        add({ title = 'Run power cable', description = 'HV conductor, LV bundled cable or a service drop to a house · clamps to power poles', icon = 'bolt', iconColor = net.color, onSelect = function() A.powerOverhead(back) end })
        add(head('Customer supply', 'gauge-high'))
        cats(add, net, { { 'Customer supply & metering', 'Service cut-out, smart meter, outside meter cabinet — where the service drop lands', 'gauge-high' } })
        add(head('Electrical installation', 'plug'))
        cats(add, net, {
            { 'Fuse boards & isolators', 'Consumer unit (feeds the sockets & lights around it) · rotary isolator', 'toggle-on' },
            { 'Sockets & switches', 'Twin / USB / steel / single / outdoor sockets, fused spur, light switch', 'plug' },
            { 'Lighting', 'LED ceiling panel and batten — worked from a light switch', 'lightbulb' },
            { 'EV charging', 'Wallbox and charging post', 'car-battery' },
        })
        add({ title = 'Run mains cable / flex', description = 'Grey twin & earth, white or black flex · joins supply kit, consumer units and sockets', icon = 'plug-circle-bolt', iconColor = net.color, onSelect = function() A.powerInside(back) end })
        add(head('Plug-in & portable', 'charging-station'))
        cats(add, net, {
            { 'Plug-in devices & chargers', 'Phone charging cable, wireless pad / stand, laptop charger, desk lamp — plug themselves into the nearest socket', 'charging-station' },
            { 'Temporary power', 'Portable generator, cable reel, extension lead', 'gas-pump' },
        })
        add(hubLink('sapl', 'Power: meters, load and solar'))
    elseif id == 'solar' then
        add(head('Install', 'solar-panel'))
        cats(add, net, {
            { 'Solar panels', 'Roof panels on rails · ground-mount arrays — feed the inverter within 30 m', 'solar-panel' },
            { 'Inverters & batteries', 'Hybrid inverter (feeds the consumer unit nearby) · home battery beside it', 'car-battery' },
            { 'Isolators & protection', 'PV DC isolator — make the array safe before working on it', 'power-off' },
        })
        add({ title = 'Run mains cable / flex', description = 'Only if the inverter is too far from the consumer unit to be wired through the walls', icon = 'plug-circle-bolt', iconColor = net.color, onSelect = function() A.powerInside(back) end })
        add(head('How it works', 'circle-info'))
        add({ title = 'Panels → DC isolator → inverter → consumer unit', description = 'Daytime the panels power the house (and charge the battery); after dark or in a power cut the battery takes over. [E] on the inverter shows output and charge.', icon = 'circle-info', readOnly = true })
        add(hubLink('solar', 'Solar output and batteries'))
    elseif id == 'secure' then
        add(head('Design & install', 'video'))
        cats(add, net, {
            { 'IP cameras (PoE)', 'Bullet, dome, turret, fisheye — CAT6 to the NVR or a PoE switch', 'video' },
            { 'Specialist cameras', 'PTZ speed dome, ANPR / LPR, thermal, analogue (DVR)', 'binoculars' },
            { 'Wireless & doorbells', 'Wi-Fi indoor camera, video doorbell', 'wifi' },
            { 'Recorders & viewing', 'NVR (PoE), DVR, monitors, video wall, PTZ keyboard', 'server' },
            { 'Access & signage', 'Access-control reader, CCTV warning sign', 'id-card' },
        })
        add({ title = 'Pull CAT6 from the nearest box', description = 'Camera → NVR (or PoE switch). Crimp both ends onto the kit.', icon = 'ethernet', iconColor = BLUE, onSelect = function() A.pull(back) end })
        add(head('How it works', 'circle-info'))
        add({ title = 'Camera → CAT6 → NVR (PoE) → monitor · router for remote viewing', description = 'NVR needs a socket within 3 m. [E] at the NVR: set up, watch, events, ANPR. Customers watch remotely in OPS Secure View on the phone.', icon = 'circle-info', readOnly = true })
        add(hubLink('secure', 'All CCTV systems, cameras, events and ANPR'))
    elseif id == 'track' then
        add(head('In the vehicle you’re sitting in', 'car'))
        add({ title = 'Install a tracker', description = 'Mini (plug-and-play) or Pro (hard-wired, antennas, backup battery, inputs, immobiliser) · step by step under the dash', icon = 'screwdriver-wrench', iconColor = net.color, onSelect = function() if TrackInstall then TrackInstall() end end })
        add({ title = 'Check the tracker (LEDs)', description = 'PWR · GNSS fix · GSM signal on OPS Mobile', icon = 'stethoscope', iconColor = BLUE, onSelect = function() if TrackDiagnose then TrackDiagnose() end end })
        add({ title = 'Reconnect tracker power', description = 'After a tamper / service', icon = 'plug', iconColor = GREEN, onSelect = function() if TrackCut then TrackCut(true) end end })
        add({ title = 'Decommission (remove) the tracker', description = 'Take it out and close the account', icon = 'trash-can', iconColor = RED, onSelect = function() if TrackRemove then TrackRemove() end end })
        add(head('Tracking', 'location-crosshairs'))
        add({ title = 'Tracked vehicles', description = 'Locate, arm theft alerts, immobilise (also /track for owners)', icon = 'location-crosshairs', iconColor = net.color, arrow = true, onSelect = function() if TrackList then TrackList() end end })
        add(head('Fitting bay', 'warehouse'))
        cats(add, net, { { 'Fitting bay', 'Bay sign, installer tool case, units, antennas, batteries, looms on the bench', 'warehouse' } })
        add(hubLink('track', 'Live map of every tracked vehicle, alerts'))
    elseif id == 'fuel' then
        add(head('Build a station', 'gas-pump'))
        cats(add, net, {
            { 'Storage tanks', 'Underground tanks (unleaded / super / diesel) · bunded above-ground diesel tank', 'oil-well' },
            { 'Dispensers & forecourt', 'Dispenser (needs power) · lit canopy · emergency stop', 'gas-pump' },
            { 'Deliveries & venting', 'Tanker fill point · vent stack', 'truck-droplet' },
            { 'Station control', 'Tank gauge & pump controller (ATG) — authorises the pumps', 'gauge' },
        })
        add({ title = 'Lay fuel pipe', description = 'Product lines tank ⇄ dispenser · fill lines fill point → tank · vent lines tank → vent stack', icon = 'faucet', iconColor = net.color, onSelect = function() A.pipe(back) end })
        add({ title = 'Run mains cable / flex', description = 'Only if the dispensers / gauge are too far from the consumer unit to be wired through the walls', icon = 'plug-circle-bolt', iconColor = '#ffd60a', onSelect = function() A.powerInside(back) end })
        add(head('Supply', 'truck'))
        cats(add, net, { { 'Bulk terminal', 'Loading gantry — road tankers fill up here', 'industry' } })
        add(head('How it works', 'circle-info'))
        add({ title = 'Tanker → fill point → tank → pipe → dispenser → nozzle → vehicle', description = 'Every tank needs a fill pipe and a vent pipe. Dispensers and the gauge need power from the grid. Vehicles only fill up at stations built here.', icon = 'circle-info', readOnly = true })
        add(hubLink('fuel', 'Fuel stations: stock, alarms, sales and prices'))
    elseif id == 'buildings' then
        local sites = Config.Cabling.Sites or { id = 'sites', label = 'Buildings & sites' }
        local pos = GetEntityCoords(PlayerPedId())
        add(head('Put down a building', 'city'))
        for _, e in ipairs(Config.Cabling.Equipment or {}) do
            if e.building then
                local ok = IsModelInCdimage(joaat(e.model))
                add({ title = e.label, description = ok and e.about or 'Restart opslabs-props to place this', disabled = not ok,
                    icon = buildingIcon(e.model), iconColor = '#5e5ce6', onSelect = function() A.placeBuilding(e, back) end })
            end
        end
        add(head('Civils & site', 'helmet-safety'))
        add({ title = 'Underground chambers & tunnels', description = 'Walk-in chambers with access hatches under the road · lay a tunnel line or place pieces one by one', icon = 'dungeon', iconColor = '#8e8e93', arrow = true,
            onSelect = function() if UndergroundMenu then UndergroundMenu() end end })
        add({ title = 'Security & fencing', description = 'Fencing & signs · auto gates, barriers & rising bollards with PIN locks · bollards', icon = 'shield-halved', iconColor = '#5e5ce6', arrow = true,
            onSelect = function() A.equipmentCat(sites, 'Security & fencing') end })
        cats(add, sites, { { 'Office & IT', 'Laptop (OPS OS, online over Ethernet)', 'laptop', '#5e5ce6' } })
        -- every placed building, wherever it is (they're saved and come back after restarts)
        local placed = {}
        for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
            for _, e in ipairs(Config.Cabling.Equipment or {}) do
                if e.building and e.model == f.model then placed[#placed + 1] = { f = f, e = e, d = #(pos - vector3(f.x, f.y, f.z)) } end
            end
        end
        table.sort(placed, function(a, b) return a.d < b.d end)
        if #placed > 0 then add(head(('Placed buildings (%d) · move, fine-tune, teleport or remove'):format(#placed), 'database')) end
        for _, n in ipairs(placed) do
            local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(n.f.x, n.f.y, n.f.z))
            add({ title = ('%s #%d'):format((n.e.label:gsub(' %(walk%-in%)', '')), n.f.id),
                description = ('%s away%s · placed by %s'):format(n.d < 1000 and (math.floor(n.d) .. ' m') or ('%.1f km'):format(n.d / 1000), street ~= '' and (' · ' .. street) or '', n.f.created_by or '?'),
                icon = buildingIcon(n.e.model), iconColor = '#5e5ce6', arrow = true, onSelect = function() A.fixture(n.f) end })
        end
    elseif id == 'roadworks' then
        return OpenRoadworksMenu and OpenRoadworksMenu()
    elseif id == 'tools' then
        add(head('You & your van', 'user-gear'))
        add({ title = 'Tool kit', description = 'Fibre & telecom (ONT tester & repair kit, splicer, OTDR…) · copper · electrical (power fault finder & restoration kit, voltage detector, earths, MEWP…)', icon = 'toolbox', iconColor = BLUE, arrow = true, onSelect = function() if ToolKitMenu then ToolKitMenu() end end })
        add({ title = 'Power repair tool', description = 'At broken power kit, a house or a street light: repairs it and its supply straight away (/powerrepair)', icon = 'screwdriver-wrench', iconColor = '#ffd60a', onSelect = function() if PowerRepairTool then PowerRepairTool() end end })
        add({ title = 'Power fault finder', description = 'At anything electrical: traces the supply back to the power station, says why there’s no power and can fix it (/powercheck)', icon = 'bolt', iconColor = '#ffd60a', onSelect = function() if PowerFaultFinder then PowerFaultFinder() end end })
        add({ title = 'Place a ladder', description = 'Telescopic 0.9 → 3.2 m, extension 6.9 m or 13 m · carry it, lean it, climb it (/' .. (Config.Cabling.LadderCommand or 'ladder') .. ')', icon = 'stairs', iconColor = BLUE, onSelect = function() if PlaceLadder then PlaceLadder() end end })
        add({ title = 'OPS Network van', description = 'Branded van with beacons (K) and stores at the back · use again to send it back (/' .. ((Config.Van or {}).Command or 'opsvan') .. ')', icon = 'truck', iconColor = BLUE, onSelect = function() if SpawnOpsVan then SpawnOpsVan() end end })
        add({ title = 'Uniform', description = 'OPS Network uniform & hard hat · admins can restyle it (/uniform)', icon = 'user-tie', iconColor = BLUE, arrow = true, onSelect = function() if UniformMenu then UniformMenu() end end })
        add(head('What’s around you', 'location-dot'))
        add({ title = 'Nearby equipment', description = 'Everything placed within 60 m · open one to move, remove, provision or brand it', icon = 'location-dot', iconColor = BLUE, arrow = true, onSelect = function() A.nearby() end })
        add({ title = 'Nearby cables & trunking', description = 'CAT6, fibre, phone, power cable and trunking within 80 m', icon = 'list', iconColor = BLUE, arrow = true, onSelect = function() A.runs() end })
        add({ title = 'Cable boxes & drums', description = 'See, teleport to or remove boxes and drums', icon = 'boxes-stacked', iconColor = BLUE, arrow = true, onSelect = function() A.boxes() end })
        add(head('Change what’s there', 'pen-ruler'))
        add({ title = 'Move cable, trunking or a box', description = 'Aim and click · reshape a route or carry a box', icon = 'up-down-left-right', iconColor = BLUE, onSelect = function() A.move(back) end })
        add({ title = 'Cut a cable', description = 'Aim anywhere along it · or press C up a pole / ladder', icon = 'scissors', iconColor = ORANGE, onSelect = function() A.cut(back) end })
        add({ title = 'Remove…', description = 'Aim & hold · an area you draw · everything within a range', icon = 'trash-can', iconColor = RED, arrow = true, onSelect = function()
            lib.registerContext({ id = 'towers_remove', title = 'Remove', options = {
                { title = 'Remove cable, trunking or a box', description = 'Aim and hold · Z puts it back', icon = 'trash-can', iconColor = RED, onSelect = function() A.remove(function() SectionMenu('tools') end) end },
                { title = 'Remove cable in an area (draw a box)', description = 'Click two corners · any size, every height · Tab picks what', icon = 'vector-square', iconColor = RED, onSelect = function() A.removeArea(function() SectionMenu('tools') end) end },
                { title = 'Remove all cable within a range…', description = 'Pick what (cable, fibre, power, trunking or everything) and how far', icon = 'circle-radiation', iconColor = RED, onSelect = function() A.removeRange(function() SectionMenu('tools') end) end },
            } })
            lib.showContext('towers_remove')
        end })
    elseif id == 'guides' then
        add({ title = 'Pole work guide — step by step', description = 'Fibre to a house · pole & ladder basics · power line — ticks off each step as you do it (F7)', icon = 'list-check', iconColor = GREEN,
            onSelect = function() if PoleGuideMenu then PoleGuideMenu() end end })
        add({ title = 'How it works — animated guide', description = 'Every system explained with animated slides (/guide)', icon = 'circle-play', iconColor = '#8e7dff', onSelect = function()
            if GetResourceState('opslabs-guide') == 'started' then ExecuteCommand('guide')
            else lib.notify({ type = 'error', description = 'The guide isn’t running — start opslabs-guide on the server' }) end
        end })
    end
    local titles = { secure = 'OPS Secure · CCTV & security', track = 'OPS Track · vehicle trackers', fuel = 'OPS Fuel · fuel stations', solar = 'San Andreas Solar · solar PV', buildings = 'Buildings & sites', openline = 'OPS Openline · fibre & copper', usfiber = 'OPS America Fiber · US FTTH', streamfibre = 'StreamFibre · alt-net fibre', sapl = 'San Andreas Power & Light · electricity', tools = 'Tools', guides = 'Guides' }
    lib.registerContext({ id = 'towers_sec_' .. id, title = titles[id] or id, options = options })
    lib.showContext('towers_sec_' .. id)
end

local adminCache = nil
MainMenu = function(field)
    if field ~= nil then fieldMode = field end
    local options = {}
    local function add(o) options[#options + 1] = o end
    add(head('Networks', 'diagram-project'))
    if not fieldMode then
        local cells, wifis = 0, 0
        for _, t in pairs(towers) do if t.type == 'wifi' then wifis = wifis + 1 else cells = cells + 1 end end
        add({ title = 'OPS Mobile · cell & Wi-Fi', description = ('Mobile coverage · %d cell towers · %d Wi-Fi access points'):format(cells, wifis), icon = 'tower-cell', iconColor = BLUE, arrow = true, onSelect = function() mobileSection() end })
    end
    local subs = {
        openline = 'Fibre & copper · poles, exchange, cabinets, pole kit, customer premises, cable, guild wires, internet service',
        streamfibre = 'Alt-net fibre on shared poles',
        usfiber = 'OPS America (US) · central office, outside plant (FDH, FDT, strand, handholes), drops, ONTs & activation',
        sapl = 'Electricity · power poles & pole kit, supply & meters, fuse boards, sockets, lighting, EV, chargers, generators',
        solar = 'Solar PV installs · roof & ground panels, hybrid inverters, home batteries, DC isolators',
        secure = 'CCTV & security · IP / PTZ / ANPR / thermal cameras, NVR / DVR, monitors, doorbells, remote viewing',
        track = 'Vehicle GPS trackers · install under the dash, LED checks, live tracking, theft alerts, immobiliser',
        fuel = 'Fuel stations · underground tanks, pipework, dispensers, canopy, e-stop, tank gauge, tanker deliveries',
    }
    for _, n in ipairs(Config.Cabling.Networks or {}) do
        if n.id ~= 'sites' then
            add({ title = n.label, description = subs[n.id] or n.sub, icon = n.icon or 'network-wired', iconColor = n.color, arrow = true, onSelect = function() SectionMenu(n.id) end })
        end
    end
    add({ title = 'Network faults', description = FaultSummary and FaultSummary() or 'Open faults on every network · go there and repair them', icon = 'triangle-exclamation', iconColor = '#ff453a', arrow = true, onSelect = function() if FaultsMenu then FaultsMenu() end end })
    add(head('On site', 'helmet-safety'))
    add({ title = 'OPS Hub', description = 'The staff website for every service · lines, towers, internet, power & solar, gunshot detection', icon = 'arrow-up-right-from-square', iconColor = '#0a84ff', onSelect = function() OpenHub() end })
    add({ title = 'Buildings & sites', description = 'Walk-in house, depot & exchange · underground · fencing & gates · office & IT', icon = 'city', iconColor = '#5e5ce6', arrow = true, onSelect = function() SectionMenu('buildings') end })
    add({ title = 'Road safety', description = 'Cones, barriers, works signs, traffic lights, cordon tape', icon = 'triangle-exclamation', iconColor = ORANGE, arrow = true, onSelect = function() SectionMenu('roadworks') end })
    add({ title = 'Tools', description = 'Tool kit · ladders · van · uniform · nearby kit & cable · move, cut, remove', icon = 'screwdriver-wrench', iconColor = GREY, arrow = true, onSelect = function() SectionMenu('tools') end })
    add({ title = 'Guides', description = 'Step-by-step pole work coach (F7) · animated how-it-works guide', icon = 'circle-question', iconColor = '#8e7dff', arrow = true, onSelect = function() SectionMenu('guides') end })
    add(head('Settings', 'gear'))
    local style = MenuStyle and MenuStyle() or 'console'
    add({ title = 'Menu style: ' .. (style == 'classic' and 'Classic (small menus)' or 'Console (full screen)'),
        description = 'Switch to ' .. (style == 'classic' and 'the full-screen engineer console' or 'the small classic menus') .. ' · just for you · up a pole Z always opens the small quick menu',
        icon = 'table-columns', iconColor = GREY, onSelect = function()
            if SetMenuStyle then SetMenuStyle(style == 'classic' and 'console' or 'classic') end
            if lib.hideContext then lib.hideContext(false) end
            SetTimeout(150, function() MainMenu() end)
        end })
    if adminCache == nil then adminCache = lib.callback.await('opslabs-towers:isAdmin', false) == true end
    if adminCache and OpenDangerZone then
        add({ title = 'Danger zone', description = 'Mass delete parts of the power network or anything else · needs the danger zone username & password', icon = 'radiation', iconColor = '#ff453a',
            onSelect = function() OpenDangerZone() end })
    end
    lib.registerContext({ id = 'towers_main', title = fieldMode and 'Field engineering' or 'OPS Network · control', options = options, root = true })
    lib.showContext('towers_main')
end

RegisterCommand(Config.Command, function()
    if not lib.callback.await('opslabs-towers:isAdmin', false) then
        return lib.notify({ type = 'error', description = 'You are not allowed to manage towers' })
    end
    MainMenu(false)
end, false)
