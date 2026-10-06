local doors = {}

MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `rps_doorlocks` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(128) NOT NULL,
            `state` TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `data` LONGTEXT NOT NULL,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]], {}, function()
        LoadDoors()
    end)
end)

function LoadDoors()
    doors = {}
    local result = MySQL.query.await('SELECT * FROM rps_doorlocks')
    if result then
        for _, row in ipairs(result) do
            local success, err = pcall(function()
                local doorData = json.decode(row.data)
                if doorData then
                    doorData.id = row.id
                    doorData.name = row.name
                    doorData.state = row.state
                    
                    if doorData.isDouble and (not doorData.doors or not doorData.doors[1] or not doorData.doors[2]) then
                        doorData.isDouble = false
                    end

                    if doorData.isDouble then
                        doorData.doors[1].hash = joaat(('rps_door_%s_1'):format(row.id))
                        doorData.doors[2].hash = joaat(('rps_door_%s_2'):format(row.id))
                        if not doorData.coords then
                            doorData.coords = {
                                x = doorData.doors[1].coords.x - ((doorData.doors[1].coords.x - doorData.doors[2].coords.x) / 2),
                                y = doorData.doors[1].coords.y - ((doorData.doors[1].coords.y - doorData.doors[2].coords.y) / 2),
                                z = doorData.doors[1].coords.z - ((doorData.doors[1].coords.z - doorData.doors[2].coords.z) / 2)
                            }
                        end
                    else
                        if not doorData.doors or not doorData.doors[1] then
                            doorData.doors = {{model = 0, coords = {x=0,y=0,z=0}, heading = 0.0}}
                        end
                        doorData.hash = joaat(('rps_door_%s'):format(row.id))
                    end

                    doors[tostring(row.id)] = doorData
                end
            end)
            if not success then
                print("^1[rps_doorlock] Failed to load door ID " .. tostring(row.id) .. " - Error: " .. tostring(err) .. "^7")
            end
        end
    end
    print('^2[rps_doorlock]^7 Loaded ' .. #result .. ' doors.')
end

RegisterNetEvent('rps_doorlock:server:RequestDoors', function()
    local src = source
    TriggerClientEvent('rps_doorlock:client:SyncDoors', src, doors)
end)

RegisterNetEvent('rps_doorlock:server:CreateDoor', function(data)
    local src = source
    if not IsAdmin(src) then return end
    
    local name = data.name
    data.name = nil
    local encodedData = json.encode(data)
    
    MySQL.insert('INSERT INTO rps_doorlocks (name, state, data) VALUES (?, ?, ?)', {name, 1, encodedData}, function(id)
        if id then
            data.id = id
            data.name = name
            data.state = 1
            
            if data.isDouble and data.doors then
                data.doors[1].hash = joaat(('rps_door_%s_1'):format(id))
                data.doors[2].hash = joaat(('rps_door_%s_2'):format(id))
            else
                data.hash = joaat(('rps_door_%s'):format(id))
            end
            
            doors[tostring(id)] = data
            TriggerClientEvent('rps_doorlock:client:UpdateDoor', -1, tostring(id), data)
        end
    end)
end)

RegisterNetEvent('rps_doorlock:server:UpdateDoor', function(id, data)
    local src = source
    if not IsAdmin(src) then return end
    
    local name = data.name
    data.name = nil
    data.id = nil
    
    local state = doors[tostring(id)] and doors[tostring(id)].state or 1
    data.state = state
    
    local encodedData = json.encode(data)
    
    MySQL.update('UPDATE rps_doorlocks SET name = ?, data = ? WHERE id = ?', {name, encodedData, id}, function(affectedRows)
        if affectedRows > 0 then
            data.id = id
            data.name = name
            if data.isDouble and data.doors then
                data.doors[1].hash = joaat(('rps_door_%s_1'):format(id))
                data.doors[2].hash = joaat(('rps_door_%s_2'):format(id))
            else
                data.hash = joaat(('rps_door_%s'):format(id))
            end
            doors[tostring(id)] = data
            TriggerClientEvent('rps_doorlock:client:UpdateDoor', -1, tostring(id), data)
        end
    end)
end)

RegisterNetEvent('rps_doorlock:server:DeleteDoor', function(id)
    local src = source
    if not IsAdmin(src) then return end
    
    MySQL.update('DELETE FROM rps_doorlocks WHERE id = ?', {id}, function(affectedRows)
        if affectedRows > 0 then
            doors[tostring(id)] = nil
            TriggerClientEvent('rps_doorlock:client:DeleteDoor', -1, tostring(id))
        end
    end)
end)

RegisterNetEvent('rps_doorlock:server:ToggleState', function(id)
    local src = source
    local door = doors[tostring(id)]
    if not door then return end
    
    local newState = door.state == 1 and 0 or 1
    door.state = newState
    
    MySQL.update('UPDATE rps_doorlocks SET state = ? WHERE id = ?', {newState, id})
    TriggerClientEvent('rps_doorlock:client:SetState', -1, tostring(id), newState)
    
    if newState == 0 and door.autolock and tonumber(door.autolock) > 0 then
        local autolockTime = tonumber(door.autolock) * 1000
        SetTimeout(autolockTime, function()
            if doors[tostring(id)] and doors[tostring(id)].state == 0 then
                doors[tostring(id)].state = 1
                MySQL.update('UPDATE rps_doorlocks SET state = 1 WHERE id = ?', {id})
                TriggerClientEvent('rps_doorlock:client:SetState', -1, tostring(id), 1)
            end
        end)
    end
end)

RegisterNetEvent('rps_doorlock:server:LockpickSuccess', function(id)
    local src = source
    local door = doors[tostring(id)]
    if not door or not door.lockpick then return end
    
    door.state = 0
    MySQL.update('UPDATE rps_doorlocks SET state = 0 WHERE id = ?', {id})
    TriggerClientEvent('rps_doorlock:client:SetState', -1, tostring(id), 0)
    exports.rps_lib:Notify(src, 'Door successfully lockpicked!', 'success')
    
    SetTimeout(Config.LockpickTempUnlockTime * 1000, function()
        if doors[tostring(id)] and doors[tostring(id)].state == 0 then
            doors[tostring(id)].state = 1
            MySQL.update('UPDATE rps_doorlocks SET state = 1 WHERE id = ?', {id})
            TriggerClientEvent('rps_doorlock:client:SetState', -1, tostring(id), 1)
        end
    end)
end)

function IsAdmin(source)
    for _, group in ipairs(Config.AdminGroups or {}) do
        if IsPlayerAceAllowed(source, "group." .. group) then
            return true
        end
    end

    local identifiers = GetPlayerIdentifiers(source)
    for _, id in ipairs(identifiers) do
        for _, adminId in ipairs(Config.Admins) do
            if id == adminId then
                return true
            end
        end
    end
    return false
end

RegisterNetEvent('rps_doorlock:server:RemoveLockpick', function()
    local src = source
    exports.rps_lib:RemoveItem(src, Config.LockpickItem, 1)
end)
