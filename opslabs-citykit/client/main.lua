-- OPS City Kit — client: streams the placed dressing props in and out around the player, and the admin
-- placement/edit tool (/citykit). Same raycast-ghost-prop technique as opslabs-towers' PlacementMode, written
-- fresh here since that one isn't exported and is wired into the cabling/power data model, not this one.

local items, byModel = {}, {}
for _, c in ipairs(Config.Categories or {}) do
    for _, it in ipairs(c.items or {}) do byModel[it.model] = it end
end

local props = {}    -- id -> record from the server
local spawned = {}  -- id -> entity
local isAdmin = false

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(1000)
    TriggerServerEvent('opslabs-citykit:ready')
    isAdmin = lib.callback.await('opslabs-citykit:isAdmin', false)
end)

RegisterNetEvent('opslabs-citykit:list', function(list)
    props = {}
    for id, row in pairs(list or {}) do props[tonumber(id) or id] = row end
end)

---------------------------------------------------------------------------
-- streaming: spawn what's close, despawn what isn't
---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(1500)
        local pos = GetEntityCoords(PlayerPedId())
        for id, ent in pairs(spawned) do
            local row = props[id]
            if not row or #(pos - vector3(row.x, row.y, row.z)) > (Config.StreamDistance or 150.0) + 20.0 then
                if DoesEntityExist(ent) then DeleteEntity(ent) end
                spawned[id] = nil
            end
        end
        for id, row in pairs(props) do
            if not spawned[id] and #(pos - vector3(row.x, row.y, row.z)) < (Config.StreamDistance or 150.0) then
                local hash = joaat(row.model)
                if IsModelInCdimage(hash) then
                    lib.requestModel(hash, 5000)
                    local e = CreateObjectNoOffset(hash, row.x, row.y, row.z, false, false, false)
                    SetEntityHeading(e, row.heading or 0.0)
                    FreezeEntityPosition(e, true)
                    SetModelAsNoLongerNeeded(hash)
                    spawned[id] = e
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, e in pairs(spawned) do if DoesEntityExist(e) then DeleteEntity(e) end end
end)

---------------------------------------------------------------------------
-- placement tool: aim, rotate, raise/lower, confirm
---------------------------------------------------------------------------

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

--- returns { x, y, z, heading } or nil if cancelled
local function placeGhost(model, startHeading)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then
        lib.notify({ type = 'error', description = 'That model isn\'t available on this server' })
        return nil
    end
    lib.requestModel(hash, 5000)
    local pos0 = GetEntityCoords(PlayerPedId())
    local ghost = CreateObject(hash, pos0.x, pos0.y, pos0.z, false, false, false)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)
    local heading = startHeading or GetEntityHeading(PlayerPedId())
    local lift, result, shown = 0.0, nil, nil
    while true do
        Wait(0)
        for _, ctl in ipairs({ 14, 15, 16, 17, 24, 25, 37, 44, 38, 172, 173, 191, 199, 200 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)
        local fine = IsControlPressed(0, 21)
        local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
        local to = camPos + rotToDir(camRot) * (Config.PlaceReach or 20.0)
        local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, to.x, to.y, to.z, 1 + 16, ghost, 4)
        local _, hit, at = GetShapeTestResult(ray)
        if hit ~= 1 then at = to end
        if #(at - GetEntityCoords(PlayerPedId())) < 0.6 then at = GetEntityCoords(PlayerPedId()) - vector3(0.0, 0.0, 0.98) end
        local step = fine and 1.0 or 4.0
        if IsDisabledControlJustPressed(0, 14) then heading = heading - step * 3 end
        if IsDisabledControlJustPressed(0, 15) then heading = heading + step * 3 end
        if IsDisabledControlPressed(0, 44) then heading = heading + step * 0.6 end
        if IsDisabledControlPressed(0, 38) then heading = heading - step * 0.6 end
        if IsDisabledControlPressed(0, 172) then lift = lift + (fine and 0.004 or 0.02) end
        if IsDisabledControlPressed(0, 173) then lift = lift - (fine and 0.004 or 0.02) end
        local pos = vector3(at.x, at.y, at.z + lift)
        SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ghost, heading % 360)
        DrawMarker(28, pos.x, pos.y, pos.z, 0, 0, 0, 0, 0, 0, 0.08, 0.08, 0.08, 255, 255, 255, 220, false, false, 2, false, nil, nil, false)
        local text = ('[E] Place   [Backspace] Cancel   [A/D] Rotate   [Scroll] Fine rotate   [PgUp/PgDn] Height   Heading %d°   Height %+.2f m%s'):format(math.floor(heading % 360), lift, fine and '  (fine)' or '')
        if shown ~= text then lib.showTextUI(text) shown = text end
        if IsDisabledControlJustPressed(0, 191) then result = { x = pos.x, y = pos.y, z = pos.z, heading = heading % 360 } break end
        if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
    end
    lib.hideTextUI()
    if DoesEntityExist(ghost) then DeleteEntity(ghost) end
    return result
end

local function place(model)
    local spot = placeGhost(model)
    if not spot then return end
    local r = lib.callback.await('opslabs-citykit:save', false, { model = model, x = spot.x, y = spot.y, z = spot.z, heading = spot.heading })
    if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed to save' })
    else lib.notify({ type = 'success', description = 'Placed' }) end
end

---------------------------------------------------------------------------
-- /citykit menu
---------------------------------------------------------------------------

local function openCatalog()
    local options = {}
    for _, c in ipairs(Config.Categories or {}) do
        local n = #(c.items or {})
        options[#options + 1] = {
            title = ('%s (%d)'):format(c.label, n),
            description = c.note or (n == 0 and 'Nothing in this category yet' or nil),
            disabled = n == 0,
            onSelect = n > 0 and function()
                local itemOptions = {}
                for _, it in ipairs(c.items) do
                    itemOptions[#itemOptions + 1] = { title = it.label, description = it.note or it.model, onSelect = function() place(it.model) end }
                end
                lib.registerContext({ id = 'citykit_cat_' .. c.id, title = c.label, menu = 'citykit_root', options = itemOptions })
                lib.showContext('citykit_cat_' .. c.id)
            end or nil,
        }
    end
    lib.registerContext({ id = 'citykit_root', title = 'OPS City Kit', options = options })
    lib.showContext('citykit_root')
end

local function openIfAllowed()
    if not isAdmin then
        isAdmin = lib.callback.await('opslabs-citykit:isAdmin', false)
        if not isAdmin then return lib.notify({ type = 'error', description = 'You don\'t have access to the city kit' }) end
    end
    openCatalog()
end

RegisterCommand('citykit', openIfAllowed, false)

--- called by other resources (e.g. opslabs-towers' /towers → "Building materials") to open the same catalog —
--- does its own admin check regardless of who's calling, same as the /citykit command above
exports('OpenCatalog', openIfAllowed)

---------------------------------------------------------------------------
-- [E] at an already-placed prop: move or delete it
---------------------------------------------------------------------------

local function nearestProp()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, row in pairs(props) do
        local d = #(pos - vector3(row.x, row.y, row.z))
        if d < (bd or (Config.UseDistance or 3.0)) then best, bd = id, d end
    end
    return best
end

local function editMenu(id)
    local row = props[id]
    if not row then return end
    local it = byModel[row.model]
    lib.registerContext({ id = 'citykit_edit', title = (it and it.label) or row.model, options = {
        { title = 'Move', icon = 'arrows-up-down-left-right', onSelect = function()
            local spot = placeGhost(row.model, row.heading)
            if not spot then return end
            local r = lib.callback.await('opslabs-citykit:move', false, id, spot)
            if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' })
            else lib.notify({ type = 'success', description = 'Moved' }) end
        end },
        { title = 'Delete', icon = 'trash', iconColor = '#ff4d5e', onSelect = function()
            if lib.alertDialog({ header = 'Delete this prop?', content = (it and it.label) or row.model, centered = true, cancel = true }) ~= 'confirm' then return end
            local r = lib.callback.await('opslabs-citykit:delete', false, id)
            if not r or r.error then lib.notify({ type = 'error', description = (r and r.error) or 'Failed' })
            else lib.notify({ type = 'success', description = 'Removed' }) end
        end },
        { title = 'Placed by', description = row.created_by or 'unknown', readOnly = true },
    } })
    lib.showContext('citykit_edit')
end

CreateThread(function()
    local shown = nil
    while true do
        local id = isAdmin and not IsPedInAnyVehicle(PlayerPedId(), false) and nearestProp() or nil
        if id then
            if shown ~= id then lib.showTextUI('[E] City kit · edit this prop') shown = id end
            if IsControlJustPressed(0, 38) then editMenu(id) Wait(300) end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(400)
        end
    end
end)
