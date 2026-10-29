-- Admin menu action for server/fencefix.lua: surveys and corrects every placed fence's height in one go.
-- Takes over the camera briefly (same hidden-ped ground survey client/showcase.lua already uses) - warn
-- before running it, same as any other menu action that affects the whole map at once.

function RegradeFences()
    if lib.alertDialog({ header = 'Re-ground all fencing?', centered = true, cancel = true,
        content = 'Surveys every placed fence panel/post on the map and drops the ones floating or buried back onto the real ground. Takes over your camera (frozen, invisible, screen faded) while it surveys — if fencing is spread across many separate areas of the map this can take a while, not just a few seconds. Don\'t alt-tab or disconnect mid-survey; wait for the "Fixed X of Y" notification.' }) ~= 'confirm' then return end
    lib.notify({ type = 'inform', description = 'Surveying fencing…' })
    local r = lib.callback.await('opslabs-towers:fence:regrade', false)
    if not r or r.error then return lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    lib.notify({ type = 'success', description = r.fixed > 0 and ('Fixed %d of %d fence fixture(s)'):format(r.fixed, r.checked)
        or ('Checked %d fence fixture(s) — all already on the ground'):format(r.checked) })
end

---------------------------------------------------------------------------
-- remove fencing: walk up to a panel - the nearest one highlights - [E] removes just it,
-- [G] removes the whole line it's part of (server/fencetracker.lua's FenceState grouping, same lines
-- the maps show). Same walk-up-and-highlight idiom as the Line Tool (client/powerline.lua aimLoop),
-- just proximity-based instead of camera-aim since a fence panel is a thin, easy-to-stand-next-to thing.
---------------------------------------------------------------------------

local function fenceFixtures()
    local out = {}
    for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f.model:find('^opslabs_fence_') then out[id] = f end
    end
    return out
end

local function nearestFence(maxD)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, f in pairs(fenceFixtures()) do
        local d = #(vector2(pos.x, pos.y) - vector2(f.x, f.y))
        if d <= maxD and (not bd or d < bd) then best, bd = f, d end
    end
    return best
end

local function fenceLabel(at, text)
    SetDrawOrigin(at.x, at.y, at.z, 0)
    SetTextFont(4) SetTextScale(0.0, 0.32) SetTextColour(255, 69, 58, 255) SetTextCentre(true) SetTextOutline()
    BeginTextCommandDisplayText('STRING') AddTextComponentSubstringPlayerName(text) EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function deleteIds(ids)
    local removed = 0
    for _, id in ipairs(ids) do if lib.callback.await('opslabs-towers:fixture:delete', false, id) then removed = removed + 1 end end
    return removed
end

function RemoveFencing()
    local lineOf = {}
    local function refreshLines()
        lineOf = {}
        for _, f in ipairs(lib.callback.await('opslabs-towers:fence:lines', false) or {}) do
            for _, id in ipairs(f.ids) do lineOf[id] = f end
        end
    end
    refreshLines()

    lib.showTextUI('**Remove fencing**  \nWalk up to a panel  \n[E] Remove this panel  ·  [G] Remove the whole line  ·  [Backspace] Stop', { position = 'top-center', icon = 'ban' })
    while true do
        Wait(0)
        DisableControlAction(0, 38, true)    -- E
        DisableControlAction(0, 47, true)    -- G
        local f = nearestFence(3.0)
        if f then
            DrawMarker(25, f.x, f.y, f.z + 0.3, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.9, 255, 69, 58, 170, false, false, 2, false, nil, nil, false)
            local line = lineOf[f.id]
            fenceLabel(vector3(f.x, f.y, f.z + 1.2), line and ('Fence panel · line of %d'):format(#line.ids) or 'Fence panel')
        end
        if f and IsDisabledControlJustPressed(0, 38) then
            if lib.alertDialog({ header = 'Remove this panel?', centered = true, cancel = true }) == 'confirm' then
                local ok = lib.callback.await('opslabs-towers:fixture:delete', false, f.id)
                lib.notify({ type = ok and 'success' or 'error', description = ok and 'Removed' or 'Failed to remove it' })
                if ok then refreshLines() end
            end
        end
        if f and IsDisabledControlJustPressed(0, 47) then
            local line = lineOf[f.id]
            local ids = line and line.ids or { f.id }
            if lib.alertDialog({ header = ('Remove the whole line (%d panels)?'):format(#ids), centered = true, cancel = true,
                content = 'This can\'t be undone.' }) == 'confirm' then
                local removed = deleteIds(ids)
                lib.notify({ type = removed > 0 and 'success' or 'error', description = ('Removed %d of %d panel(s)'):format(removed, #ids) })
                refreshLines()
            end
        end
        if IsDisabledControlJustPressed(0, 177) or IsPedInAnyVehicle(PlayerPedId(), false) then break end
    end
    lib.hideTextUI()
end
