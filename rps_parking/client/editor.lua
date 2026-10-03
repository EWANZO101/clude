-- Parking lot editor: create / edit lots in-game.
--   Zone    – laser-draw the lot's box / polygon
--   Machine – place the parking machine with a ghost prop
--   Bays    – place bays with a ghost car, remove bays, fill whole rows

local function notify(msg, t) Bridge.Notify(msg, t, 'Lot Editor') end

local draft, isNew, dirty = nil, false, false
local editorOpen = false
local OpenLotMenu

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function CopyLot(l)
    local d = {
        name = l.name, label = l.label, pricePerHour = l.pricePerHour or 0, maxFee = l.maxFee or 0,
        blip = l.blip ~= false, machine = l.machine, coords = l.coords, radius = l.radius, spots = {},
    }
    for i, s in ipairs(l.spots or {}) do d.spots[i] = s end
    if LotUtil.HasZone(l) then
        d.zone = { minZ = l.zone.minZ, maxZ = l.zone.maxZ, points = {} }
        for i, p in ipairs(l.zone.points) do d.zone.points[i] = p end
    end
    return d
end

local function CamDir()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local c = math.abs(math.cos(rx))
    return vec3(-math.sin(rz) * c, math.cos(rz) * c, math.sin(rx))
end

-- Laser from the camera onto the world. Returns hit, coords
local function Laser()
    local from = GetGameplayCamCoord()
    local to = from + CamDir() * 80.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1, PlayerPedId(), 4)
    local _, hit, coords = GetShapeTestResult(ray)
    return hit == 1, coords
end

local function DrawLaser(hit, coords, r, g, b)
    if not hit then return end
    local p = GetPedBoneCoords(PlayerPedId(), 57005, 0.0, 0.0, 0.0) -- right hand
    DrawLine(p.x, p.y, p.z, coords.x, coords.y, coords.z, r, g, b, 255)
    DrawMarker(28, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12, r, g, b, 220, false, false, 2, false, nil, nil, false)
end

local function Text3D(x, y, z, text)
    local onScreen, sx, sy = World3dToScreen2d(x, y, z)
    if not onScreen then return end
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextColour(255, 255, 255, 230)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end

local function DrawBay(s, r, g, b, label)
    DrawMarker(1, s.x, s.y, s.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, s.w, 2.4, 4.6, 0.25, r, g, b, 110, false, false, 2, false, nil, nil, false)
    DrawMarker(2, s.x, s.y, s.z + 0.3, 0.0, 0.0, 0.0, 90.0, s.w, 0.0, 0.5, 0.5, 0.5, r, g, b, 170, false, false, 2, false, nil, nil, false)
    if label then Text3D(s.x, s.y, s.z + 0.8, label) end
end

local function DrawPolyBoth(a, b, c, r, g, bl, al)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, al)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, r, g, bl, al)
end

-- Walls of a polygon zone (closed) or an open outline while drawing
local function DrawZone(points, minZ, maxZ, closed, r, g, b)
    local n = #points
    for i = 1, n do
        local a = points[i]
        DrawLine(a.x, a.y, minZ, a.x, a.y, maxZ, r, g, b, 255)
        if i < n or (closed and n > 2) then
            local c = points[i % n + 1]
            DrawLine(a.x, a.y, minZ, c.x, c.y, minZ, r, g, b, 255)
            DrawLine(a.x, a.y, maxZ, c.x, c.y, maxZ, r, g, b, 255)
            local a1, a2, c1, c2 = vec3(a.x, a.y, minZ), vec3(a.x, a.y, maxZ), vec3(c.x, c.y, minZ), vec3(c.x, c.y, maxZ)
            DrawPolyBoth(a1, c1, c2, r, g, b, 35)
            DrawPolyBoth(a1, c2, a2, r, g, b, 35)
        end
    end
end

local function ZoneHeights(points)
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(points) do lo, hi = math.min(lo, p.z), math.max(hi, p.z) end
    return lo - 2.0, hi + 6.0
end

local HELP_KEYS = { 24, 25, 37, 38, 44, 45, 73, 86, 140, 141, 142, 257, 263, 14, 15, 16, 17, 200 }
local function DisableKeys()
    for _, k in ipairs(HELP_KEYS) do DisableControlAction(0, k, true) end
end

local function Pressed(k) return IsControlJustPressed(0, k) or IsDisabledControlJustPressed(0, k) end
local function Done() return Pressed(191) or Pressed(194) end -- ENTER / BACKSPACE

local function Help(lines) lib.showTextUI(table.concat(lines, '  \n'), { position = 'left-center' }) end

---------------------------------------------------------------------------
-- Live preview of the draft while the editor is open
---------------------------------------------------------------------------
local mode -- nil | 'zone' | 'machine' | 'bays'

CreateThread(function()
    while true do
        if editorOpen and draft then
            local pc = GetEntityCoords(PlayerPedId())
            local center = draft.coords or (draft.zone and draft.zone.points[1]) or (draft.spots[1] and draft.spots[1].xyz)
            if center and #(pc - vec3(center.x, center.y, center.z)) < 250.0 then
                if mode ~= 'zone' and LotUtil.HasZone(draft) then
                    DrawZone(draft.zone.points, draft.zone.minZ, draft.zone.maxZ, true, 80, 200, 255)
                end
                if mode ~= 'bays' then
                    for i, s in ipairs(draft.spots) do DrawBay(s, 60, 140, 255, ('~b~%d'):format(i)) end
                end
                if mode ~= 'machine' and draft.machine then
                    local m = draft.machine
                    DrawMarker(0, m.x, m.y, m.z + 1.6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.4, 0.4, 0.4, 255, 205, 70, 200, true, true, 2, false, nil, nil, false)
                    Text3D(m.x, m.y, m.z + 2.1, '~y~Parking machine')
                end
                Wait(0)
            else
                Wait(500)
            end
        else
            Wait(750)
        end
    end
end)

---------------------------------------------------------------------------
-- Zone mode (laser)
---------------------------------------------------------------------------
local function ZoneMode()
    mode = 'zone'
    local points = {}
    if LotUtil.HasZone(draft) then for i, p in ipairs(draft.zone.points) do points[i] = p end end
    Help({ '**Draw zone**', '[E] add corner', '[X] remove last corner', '[DEL] clear all',
        '2 corners = box from opposite corners', '[ENTER] done' })

    while true do
        DisableKeys()
        local hit, c = Laser()
        DrawLaser(hit, c, 80, 200, 255)

        local preview = {}
        for i, p in ipairs(points) do preview[i] = p end
        if hit then preview[#preview + 1] = c end
        if #preview > 0 then
            local lo, hi = ZoneHeights(preview)
            DrawZone(preview, lo, hi, #preview > 2, 80, 200, 255)
        end
        for i, p in ipairs(points) do Text3D(p.x, p.y, p.z + 0.4, ('~b~%d'):format(i)) end

        if Pressed(38) and hit then points[#points + 1] = c end
        if Pressed(73) and #points > 0 then points[#points] = nil end
        if Pressed(178) then points = {} end
        if Done() then break end
        Wait(0)
    end
    lib.hideTextUI()
    mode = nil

    if #points == 2 then -- box from 2 opposite corners
        local a, b = points[1], points[2]
        local z = (a.z + b.z) / 2
        points = { vec3(a.x, a.y, z), vec3(b.x, a.y, z), vec3(b.x, b.y, z), vec3(a.x, b.y, z) }
    end
    if #points >= 3 then
        local lo, hi = ZoneHeights(points)
        draft.zone = { points = points, minZ = lo, maxZ = hi }
        LotUtil.Finalize(draft)
        dirty = true
        notify(('Zone set (%d corners).'):format(#points), 'success')
    elseif #points > 0 then
        notify('A zone needs at least 2 (box) or 3 corners – zone not changed.', 'error')
    end
end

---------------------------------------------------------------------------
-- Machine mode (ghost prop)
---------------------------------------------------------------------------
local function MachineMode()
    mode = 'machine'
    local model = lib.requestModel(Config.ParkingMachine.model)
    local ghost = CreateObject(model, 0.0, 0.0, -100.0, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    local heading = draft.machine and draft.machine.w or GetEntityHeading(PlayerPedId())
    Help({ '**Place parking machine**', '[E] place here', '[SCROLL] rotate (hold SHIFT = fine)', '[Q] rotate 90°', '[ENTER] cancel' })

    while true do
        DisableKeys()
        local hit, c = Laser()
        DrawLaser(hit, c, 255, 205, 70)
        local step = IsControlPressed(0, 21) and 1.0 or 7.5
        if Pressed(15) then heading = (heading + step) % 360.0 end
        if Pressed(14) then heading = (heading - step) % 360.0 end
        if Pressed(44) then heading = (heading + 90.0) % 360.0 end
        if hit then
            SetEntityCoordsNoOffset(ghost, c.x, c.y, c.z, false, false, false)
            SetEntityHeading(ghost, heading)
            if Pressed(38) then
                draft.machine = vec4(c.x, c.y, c.z, heading)
                dirty = true
                notify('Parking machine placed.', 'success')
                break
            end
        end
        if Done() then break end
        Wait(0)
    end
    DeleteEntity(ghost)
    SetModelAsNoLongerNeeded(model)
    lib.hideTextUI()
    mode = nil
end

---------------------------------------------------------------------------
-- Bay mode (ghost car)
---------------------------------------------------------------------------
local function BayMode()
    mode = 'bays'
    local ped = PlayerPedId()
    local cur = GetVehiclePedIsIn(ped, false)
    local model = cur ~= 0 and GetEntityModel(cur) or joaat(Config.Admin.ghostModel)
    lib.requestModel(model)
    local minDim = GetModelDimensions(model)
    local lift = -minDim.z

    local ghost = CreateVehicle(model, 0.0, 0.0, -100.0, 0.0, false, false)
    SetEntityAlpha(ghost, 150, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetEntityInvincible(ghost, true)
    SetVehicleDoorsLocked(ghost, 2)
    SetEntityNoCollisionEntity(ghost, ped, false)

    local heading = draft.spots[#draft.spots] and draft.spots[#draft.spots].w or GetEntityHeading(ped)
    local gap = Config.Admin.bayMinGap
    Help({ '**Place bays**', '[E] place bay', '[SCROLL] rotate (hold SHIFT = fine)', '[Q] rotate 90°',
        '[DEL] remove aimed bay', '[X] undo last bay', '[R] fill row between last 2 bays', '[ENTER] done' })

    while true do
        DisableKeys()
        local hit, c = Laser()
        local step = IsControlPressed(0, 21) and 1.0 or 7.5
        if Pressed(15) then heading = (heading + step) % 360.0 end
        if Pressed(14) then heading = (heading - step) % 360.0 end
        if Pressed(44) then heading = (heading + 90.0) % 360.0 end

        -- nearest existing bay to the laser (for delete + overlap check)
        local aimed, aimedDist = nil, math.huge
        if hit then
            for i, s in ipairs(draft.spots) do
                local d = #(s.xy - c.xy)
                if d < aimedDist then aimed, aimedDist = i, d end
            end
        end

        for i, s in ipairs(draft.spots) do
            if i == aimed and aimedDist < gap then DrawBay(s, 230, 60, 60, ('~r~%d'):format(i))
            else DrawBay(s, 60, 140, 255, ('~b~%d'):format(i)) end
        end

        local valid, reason = hit, nil
        if hit then
            local spot = vec4(c.x, c.y, c.z + lift, heading)
            if aimedDist < gap then valid, reason = false, 'too close to bay ' .. aimed
            elseif LotUtil.HasZone(draft) and not LotUtil.InLot(draft, spot.xyz) then valid, reason = false, 'outside the zone' end

            SetEntityCoordsNoOffset(ghost, spot.x, spot.y, spot.z, false, false, false)
            SetEntityHeading(ghost, heading)
            DrawLaser(true, c, valid and 60 or 230, valid and 200 or 60, valid and 90 or 60)
            DrawBay(spot, valid and 60 or 230, valid and 200 or 60, valid and 90 or 60,
                valid and ('~g~Bay %d'):format(#draft.spots + 1) or ('~r~%s'):format(reason))

            if Pressed(38) then
                if valid then
                    draft.spots[#draft.spots + 1] = spot
                    dirty = true
                else
                    notify(('Can\'t place bay here: %s.'):format(reason), 'error')
                end
            end
            if Pressed(178) and aimed and aimedDist < gap then
                table.remove(draft.spots, aimed)
                dirty = true
                notify(('Bay %d removed (bays after it are renumbered).'):format(aimed))
            end
        end

        if Pressed(73) and #draft.spots > 0 then
            draft.spots[#draft.spots] = nil
            dirty = true
        end

        if Pressed(45) then
            if #draft.spots < 2 then
                notify('Place the first and last bay of the row first.', 'error')
            else
                lib.hideTextUI()
                local input = lib.inputDialog('Fill row', {
                    { type = 'number', label = 'Total bays in this row (incl. first & last)', min = 3, max = 60, required = true, default = 6 },
                })
                if input and input[1] then
                    local count = math.floor(input[1])
                    local b = table.remove(draft.spots)
                    local a = table.remove(draft.spots)
                    for i = 0, count - 1 do
                        local t = i / (count - 1)
                        draft.spots[#draft.spots + 1] = vec4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w)
                    end
                    dirty = true
                    notify(('Row filled with %d bays.'):format(count), 'success')
                end
                Help({ '**Place bays**', '[E] place bay', '[SCROLL] rotate (hold SHIFT = fine)', '[Q] rotate 90°',
                    '[DEL] remove aimed bay', '[X] undo last bay', '[R] fill row between last 2 bays', '[ENTER] done' })
            end
        end

        if Done() then break end
        Wait(0)
    end
    DeleteEntity(ghost)
    SetModelAsNoLongerNeeded(model)
    lib.hideTextUI()
    mode = nil
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------
local function RunMode(fn)
    CreateThread(function()
        editorOpen = true
        ParkingEditorActive = true -- blocks the park key while placing
        fn()
        ParkingEditorActive = false
        OpenLotMenu()
    end)
end

local function EditDetails()
    local input = lib.inputDialog(isNew and 'New parking lot' or 'Lot details', {
        { type = 'input', label = 'ID (letters, numbers, _)', default = draft.name, required = true, disabled = not isNew, min = 2, max = 30 },
        { type = 'input', label = 'Name shown to players', default = draft.label, required = true, max = 60 },
        { type = 'number', label = 'Price per hour ($, 0 = free)', default = draft.pricePerHour, min = 0, max = 100000 },
        { type = 'number', label = 'Max fee ($, 0 = no cap)', default = draft.maxFee, min = 0, max = 1000000 },
        { type = 'checkbox', label = 'Show map blip', checked = draft.blip },
    })
    if not input then return false end
    if isNew then
        local name = tostring(input[1] or ''):lower():gsub('%s+', '_')
        if not name:match('^[%w_]+$') or #name < 2 then notify('ID may only contain letters, numbers and _.', 'error') return false end
        for _, l in ipairs(Config.ParkingLots) do
            if l.name == name then notify('A lot with that ID already exists.', 'error') return false end
        end
        draft.name = name
    end
    draft.label = input[2]
    draft.pricePerHour = math.floor(tonumber(input[3]) or 0)
    draft.maxFee = math.floor(tonumber(input[4]) or 0)
    draft.blip = input[5] == true
    dirty = true
    return true
end

local function Save()
    if not LotUtil.HasZone(draft) and not draft.coords then return notify('Draw a zone first.', 'error') end
    if #draft.spots == 0 then return notify('Add at least one bay.', 'error') end
    if not draft.machine then
        local res = lib.alertDialog({ header = 'No parking machine', centered = true, cancel = true,
            content = 'Players can\'t unpark at a lot without a machine. Save anyway?' })
        if res ~= 'confirm' then return end
    end
    LotUtil.Finalize(draft)
    local ok, msg = lib.callback.await('rps_parking:editor:save', false, LotUtil.Encode(draft), isNew)
    notify(msg, ok and 'success' or 'error')
    if ok then isNew, dirty = false, false end
end

local function Delete()
    local res = lib.alertDialog({ header = ('Delete %s?'):format(draft.label), centered = true, cancel = true,
        content = 'This removes the lot, its bays and machine for everyone. This cannot be undone.' })
    if res ~= 'confirm' then return OpenLotMenu() end
    local ok, msg = lib.callback.await('rps_parking:editor:delete', false, draft.name)
    notify(msg, ok and 'success' or 'error')
    if ok then draft, editorOpen = nil, false; return OpenLotEditor() end
    OpenLotMenu()
end

local function Leave()
    if dirty then
        local res = lib.alertDialog({ header = 'Discard changes?', centered = true, cancel = true,
            content = 'You have unsaved changes to this lot.' })
        if res ~= 'confirm' then return OpenLotMenu() end
    end
    draft, editorOpen, dirty = nil, false, false
    OpenLotEditor()
end

OpenLotMenu = function()
    if not draft then return end
    editorOpen = true
    local zoneText = LotUtil.HasZone(draft) and ('%d corners'):format(#draft.zone.points)
        or (draft.coords and ('radius %.0fm – draw a zone to replace it'):format(draft.radius or 0) or 'not set')
    local price = draft.pricePerHour > 0 and ('$%d/hr, max $%d'):format(draft.pricePerHour, draft.maxFee) or 'Free'

    local options = {
        { title = ('%s%s'):format(draft.label ~= '' and draft.label or draft.name, dirty and '  (unsaved)' or ''),
          description = ('ID: %s • %s • %s'):format(draft.name, price, draft.blip and 'blip on' or 'no blip'),
          icon = 'pen', onSelect = function() EditDetails(); OpenLotMenu() end },
        { title = 'Draw zone', description = ('Laser the corners of the lot • %s'):format(zoneText),
          icon = 'draw-polygon', onSelect = function() RunMode(ZoneMode) end },
        { title = 'Place parking machine', description = draft.machine and 'Placed – select to move it' or 'Not placed yet',
          icon = 'receipt', onSelect = function() RunMode(MachineMode) end },
        { title = ('Bays (%d)'):format(#draft.spots), description = 'Place / remove bays with a ghost car, fill rows',
          icon = 'car', onSelect = function() RunMode(BayMode) end },
        { title = 'Teleport to lot', icon = 'location-dot', disabled = not (draft.coords or draft.spots[1]),
          onSelect = function()
              local c = draft.coords or draft.spots[1].xyz
              SetEntityCoords(PlayerPedId(), c.x, c.y, c.z + 1.0, false, false, false, false)
              OpenLotMenu()
          end },
        { title = 'Save lot', description = 'Publish changes to all players', icon = 'floppy-disk',
          iconColor = dirty and '#4ade80' or nil, onSelect = function() Save(); OpenLotMenu() end },
    }
    if not isNew then
        options[#options + 1] = { title = 'Delete lot', icon = 'trash', iconColor = '#f87171', onSelect = Delete }
    end
    options[#options + 1] = { title = 'Back to lot list', icon = 'arrow-left', onSelect = Leave }

    lib.registerContext({ id = 'rps_parking_lot_edit', title = isNew and 'New Parking Lot' or 'Edit Parking Lot',
        options = options, onExit = function() if not mode then editorOpen = false end end })
    lib.showContext('rps_parking_lot_edit')
end

function OpenLotEditor()
    if not lib.callback.await('rps_parking:editor:canUse', false) then return notify('You are not allowed to use this.', 'error') end

    local options = {}
    if draft and dirty then
        options[1] = { title = ('Resume unsaved: %s'):format(draft.label ~= '' and draft.label or draft.name),
            icon = 'clock-rotate-left', iconColor = '#facc15', arrow = true, onSelect = OpenLotMenu }
    end
    options[#options + 1] =
        { title = 'Create new lot', description = 'Stand at the new lot, then draw its zone, machine and bays',
          icon = 'plus', onSelect = function()
              draft = { name = '', label = '', pricePerHour = 0, maxFee = 0, blip = true, spots = {} }
              isNew, dirty = true, false
              if EditDetails() then OpenLotMenu() else draft = nil; OpenLotEditor() end
          end }
    for _, lot in ipairs(Config.ParkingLots) do
        options[#options + 1] = {
            title = lot.label,
            description = ('%s • %d bays • %s%s'):format(lot.name, #lot.spots,
                (lot.pricePerHour or 0) > 0 and ('$%d/hr'):format(lot.pricePerHour) or 'Free',
                lot.machine and '' or ' • no machine!'),
            icon = 'square-parking', arrow = true,
            onSelect = function()
                if draft and dirty then
                    local res = lib.alertDialog({ header = 'Discard changes?', centered = true, cancel = true,
                        content = ('You have unsaved changes to %s.'):format(draft.label) })
                    if res ~= 'confirm' then return OpenLotEditor() end
                end
                draft, isNew, dirty = CopyLot(lot), false, false
                OpenLotMenu()
            end,
        }
    end
    lib.registerContext({ id = 'rps_parking_lot_list', title = 'Parking Lot Editor', options = options })
    lib.showContext('rps_parking_lot_list')
end


AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and mode then lib.hideTextUI() end
end)
