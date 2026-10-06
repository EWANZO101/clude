RegisterCommand(Config.MigrateCommand, function(source, args)
    if IsAdmin(source) then
        MySQL.query('SELECT * FROM qs_doorlocks', {}, function(results)
            if not results or #results == 0 then
                exports.rps_lib:Notify(source, "No doors found in qs_doorlocks table.", "error")
                return
            end

            local migratedCount = 0
            local failedCount = 0
            
            for _, row in ipairs(results) do
                local success, err = pcall(function()
                    local oldData = json.decode(row.data)
                    if not oldData then return end
                    
                    local newData = {
                        state = row.state or oldData.state or 1,
                        isDouble = oldData.doors ~= nil,
                        doorType = oldData.doorType or (oldData.auto and 'automatic') or 'normal',
                        range = oldData.distance or oldData.maxDistance or 2.0,
                        keepOpen = oldData.keepOpen or false,
                        hideIcon = oldData.hideIcon or false,
                        lockpick = oldData.lockpick or false,
                        jobs = {},
                        gangs = {},
                        chars = {},
                        autolock = oldData.autolock or 0
                    }

                    if newData.isDouble and type(oldData.doors) == "table" then
                        newData.doors = {}
                        if oldData.doors[1] and type(oldData.doors[1].coords) == "table" then
                            table.insert(newData.doors, {
                                model = oldData.doors[1].model or oldData.doors[1].hash or 0,
                                coords = {x = oldData.doors[1].coords.x or 0, y = oldData.doors[1].coords.y or 0, z = oldData.doors[1].coords.z or 0},
                                heading = oldData.doors[1].heading or 0.0
                            })
                        end
                        if oldData.doors[2] and type(oldData.doors[2].coords) == "table" then
                            table.insert(newData.doors, {
                                model = oldData.doors[2].model or oldData.doors[2].hash or 0,
                                coords = {x = oldData.doors[2].coords.x or 0, y = oldData.doors[2].coords.y or 0, z = oldData.doors[2].coords.z or 0},
                                heading = oldData.doors[2].heading or 0.0
                            })
                        end
                        if #newData.doors == 0 then
                           newData.isDouble = false 
                           newData.doors = {
                               { model = 0, coords = {x=0,y=0,z=0}, heading = 0.0 }
                           }
                        end
                    else
                        newData.isDouble = false
                        local cx = (type(oldData.coords) == "table" and oldData.coords.x) or 0
                        local cy = (type(oldData.coords) == "table" and oldData.coords.y) or 0
                        local cz = (type(oldData.coords) == "table" and oldData.coords.z) or 0
                        newData.doors = {
                            {
                                model = oldData.model or oldData.hash or 0,
                                coords = {x = cx, y = cy, z = cz},
                                heading = oldData.heading or 0.0
                            }
                        }
                    end

                    if type(oldData.jobs) == "table" then
                        for k, v in pairs(oldData.jobs) do
                            if type(k) == "string" then
                                table.insert(newData.jobs, {job = k, grade = tonumber(v) or 0})
                            elseif type(v) == "string" then
                                table.insert(newData.jobs, {job = v, grade = 0})
                            end
                        end
                    end
                    
                    if type(oldData.gangs) == "table" then
                        for k, v in pairs(oldData.gangs) do
                            if type(k) == "string" then
                                table.insert(newData.gangs, {gang = k, grade = tonumber(v) or 0})
                            elseif type(v) == "string" then
                                table.insert(newData.gangs, {gang = v, grade = 0})
                            end
                        end
                    end

                    local encodedData = json.encode(newData)
                    local doorName = row.name or oldData.name or ("Migrated Door " .. migratedCount)
                    MySQL.insert('INSERT INTO rps_doorlocks (name, state, data) VALUES (?, ?, ?)', {doorName, newData.state, encodedData})
                    migratedCount = migratedCount + 1
                end)
                
                if not success then
                    print("^1[rps_doorlock] Migration failed for door ID " .. tostring(row.id) .. " - Error: " .. tostring(err) .. "^7")
                    failedCount = failedCount + 1
                end
            end
            
            exports.rps_lib:Notify(source, "Successfully migrated " .. migratedCount .. " doors. " .. failedCount .. " failed to parse.", "success")
        end)
    else
        exports.rps_lib:Notify(source, "You do not have permission to use this.", "error")
    end
end, false)
