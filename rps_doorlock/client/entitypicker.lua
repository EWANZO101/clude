local isPicking = false
local capturedEntities = {}
local targetCount = 1

function StartEntityPicker(isDouble)
    if isPicking then return end
    isPicking = true
    capturedEntities = {}
    targetCount = isDouble and 2 or 1
    
    lib.showTextUI('Hover over a door and **left click** to select. Press **Right Click** to cancel.', { icon = 'fa-solid fa-crosshairs' })
    
    CreateThread(function()
        local lastEntity = 0
        
        repeat
            Wait(0)
            DisablePlayerFiring(PlayerId(), true)
            DisableControlAction(0, 25, true) -- Aim
            DisableControlAction(0, 24, true) -- Attack
            
            local hit, entity, coords = lib.raycast.cam(1|16)
            local changedEntity = lastEntity ~= entity
            local doorA = capturedEntities[1] and capturedEntities[1].entity
            
            if changedEntity and lastEntity ~= doorA and lastEntity ~= 0 then
                SetEntityDrawOutline(lastEntity, false)
            end
            
            lastEntity = entity
            
            if hit then
                DrawMarker(28, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.2, 0.2, 255, 42, 24, 100, false, false, 0, true, false, false, false)
            end
            
            if hit and entity > 0 and GetEntityType(entity) == 3 and (targetCount == 1 or doorA ~= entity) then
                if changedEntity then
                    SetEntityDrawOutline(entity, true)
                end
                
                if IsDisabledControlJustPressed(0, 24) then
                    local entCoords = GetEntityCoords(entity)
                    table.insert(capturedEntities, {
                        entity = entity,
                        model = GetEntityModel(entity),
                        coords = {x = entCoords.x, y = entCoords.y, z = entCoords.z},
                        heading = GetEntityHeading(entity)
                    })
                    
                    if #capturedEntities < targetCount then
                        lib.showTextUI('Now select the **second** door entity. Press **Right Click** to cancel.', { icon = 'fa-solid fa-crosshairs' })
                    end
                end
            end
            
            if IsDisabledControlJustPressed(0, 25) then
                if lastEntity ~= 0 then SetEntityDrawOutline(lastEntity, false) end
                
                if not doorA then
                    isPicking = false
                    lib.hideTextUI()
                    SendNUIMessage({ type = 'cancelEntityCapture' })
                    SetNuiFocus(true, true)
                    exports.rps_lib:Notify('Door selection cancelled.', 'error')
                    break
                else
                    SetEntityDrawOutline(doorA, false)
                    capturedEntities = {}
                    lib.showTextUI('Hover over a door and **left click** to select. Press **Right Click** to cancel.', { icon = 'fa-solid fa-crosshairs' })
                end
            end
            
        until #capturedEntities >= targetCount
        
        if isPicking and #capturedEntities >= targetCount then
            isPicking = false
            lib.hideTextUI()
            
            for _, ent in pairs(capturedEntities) do
                SetEntityDrawOutline(ent.entity, false)
            end
            
            SendNUIMessage({
                type = 'entityCaptured',
                data = capturedEntities
            })
            SetNuiFocus(true, true)
            exports.rps_lib:Notify('Door(s) selected!', 'success')
        end
    end)
end
