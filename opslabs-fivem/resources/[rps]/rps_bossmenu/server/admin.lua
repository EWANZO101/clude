-- ============================================
--  Internal Helpers
-- ============================================
local function SetPlayerJobToMax(cid, jobName)
    if not cid or cid == 'Unassigned' or not jobName then return end

    local Player = Bridge.GetPlayerByCitizenId(cid)
    local maxGrade = 0
    local Jobs = Bridge.GetJobs() or {}
    if Jobs[jobName] and Jobs[jobName].grades then
        for grade, _ in pairs(Jobs[jobName].grades) do
            local g = tonumber(grade)
            if g and g > maxGrade then
                maxGrade = g
            end
        end
    end

    if Player then
        Player.Functions.SetJob(jobName, maxGrade)
    else
        local gradeName = (Jobs[jobName] and Jobs[jobName].grades[tostring(maxGrade)]) and Jobs[jobName].grades[tostring(maxGrade)].name or 'Boss'
        local jobData = {
            name = jobName,
            label = Jobs[jobName] and Jobs[jobName].label or jobName,
            payment = 0,
            type = (Jobs[jobName] and Jobs[jobName].type) or 'none',
            isboss = true,
            grade = { level = maxGrade, name = gradeName }
        }
        Bridge.SetOfflinePlayerJob(cid, jobData)
    end
end

-- ============================================
--  Admin UI
-- ============================================
RegisterNetEvent('rps-bossmenu:server:requestAdminUI', function()
    local src = source
    if not IsBossmenuAdmin(src) then
        Bridge.Notify(src, 'You do not have permission to open this.', 'error')
        return
    end

    MySQL.Async.fetchAll('SELECT * FROM rps_businesses', {}, function(biz)
        biz = biz or {}
        for i = 1, #biz do
            local b = biz[i]
            b.location = (b.coords and b.coords ~= '' and b.coords ~= 'null') and SafeDecode(b.coords) or nil
            b.deliveryLocation = (b.delivery_coords and b.delivery_coords ~= '' and b.delivery_coords ~= 'null') and SafeDecode(b.delivery_coords) or nil
        end

        MySQL.Async.fetchAll('SELECT * FROM rps_jungle_shops', {}, function(shops)
            Bridge.GetAllCharacters(function(chars)
                local characters = {}
                for _, c in ipairs(chars or {}) do
                    characters[#characters+1] = { cid = c.identifier, name = c.name }
                end

                local allItems = {}
                local itemsTable = Bridge.GetItems()

                if type(itemsTable) == 'table' then
                    for k, v in pairs(itemsTable) do
                        table.insert(allItems, { name = v.name or k, label = v.label or k })
                    end
                end
                
                TriggerClientEvent('rps-bossmenu:client:openAdminUI', src, {
                    businesses = biz,
                    shops = shops,
                    characters = characters,
                    itemsList = allItems,
                    inventoryImage = Config.InventoryImagePath
                })
            end)
        end)
    end)
end)

-- ============================================
--  Target Zones
-- ============================================
RegisterNetEvent('rps-bossmenu:server:requestTargets', function()
    local src = source
    MySQL.Async.fetchAll('SELECT job, coords FROM rps_businesses WHERE coords IS NOT NULL AND coords != \'\'', {}, function(result)
        if src == nil or src == 0 or src == '' then
            TriggerClientEvent('rps-bossmenu:client:initTargets', -1, result or {})
        else
            TriggerClientEvent('rps-bossmenu:client:initTargets', src, result or {})
        end
    end)
end)


-- ============================================
--  Business Management
-- ============================================
RegisterNetEvent('rps-bossmenu:server:createBusiness', function(data)
    local src = source
    if not CheckCooldown(src, 'createBusiness', 3000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.name or type(data.name) ~= 'string' or #data.name < 1 or #data.name > 50 then
        return Bridge.Notify(src, 'Invalid business name.', 'error')
    end
    
    local job = string.lower(string.gsub(data.name, "[^%a%d_]", "")):sub(1, 50)
    if job == '' then return Bridge.Notify(src, 'Invalid business name.', 'error') end
    local owner = data.owner
    local coords = data.location and (type(data.location) == 'table' and json.encode(data.location) or data.location) or nil
    local delivery_coords = data.deliveryLocation and (type(data.deliveryLocation) == 'table' and json.encode(data.deliveryLocation) or data.deliveryLocation) or nil
    local allowed_shops = data.allowedShops and json.encode(data.allowedShops) or '[]'
    
    MySQL.Async.execute('INSERT INTO rps_businesses (job, owner, coords, delivery_coords, allowed_shops) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE owner = VALUES(owner), coords = VALUES(coords), delivery_coords = VALUES(delivery_coords), allowed_shops = VALUES(allowed_shops)', {
        job, owner, coords, delivery_coords, allowed_shops
    }, function()
        SetPlayerJobToMax(owner, job)
        Bridge.Notify(src, 'Business created/updated successfully!', 'success')
        TriggerEvent('rps-bossmenu:server:requestTargets')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:editBusiness', function(data)
    local src = source
    if not CheckCooldown(src, 'editBusiness', 3000) then return end
    if not IsBossmenuAdmin(src) then return end
    
    local job = data.id
    local owner = data.owner
    local coords = data.location and (type(data.location) == 'table' and json.encode(data.location) or data.location) or nil
    local delivery_coords = data.deliveryLocation and (type(data.deliveryLocation) == 'table' and json.encode(data.deliveryLocation) or data.deliveryLocation) or nil
    local allowed_shops = data.allowedShops and json.encode(data.allowedShops) or '[]'
    
    MySQL.Async.execute('UPDATE rps_businesses SET owner = ?, coords = ?, delivery_coords = ?, allowed_shops = ? WHERE job = ?', {
        owner, coords, delivery_coords, allowed_shops, job
    }, function()
        SetPlayerJobToMax(owner, job)
        Bridge.Notify(src, 'Business updated successfully!', 'success')
        TriggerEvent('rps-bossmenu:server:requestTargets')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:deleteBusiness', function(data)
    local src = source
    if not CheckCooldown(src, 'deleteBusiness', 5000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.id or type(data.id) ~= 'string' then return end
    
    MySQL.Async.execute('DELETE FROM rps_businesses WHERE job = ?', {data.id}, function()
        Bridge.Notify(src, 'Business deleted.', 'success')
        TriggerEvent('rps-bossmenu:server:requestTargets')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:linkOnlineShop', function(data)
    local src = source
    if not CheckCooldown(src, 'linkOnlineShop', 2000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.job or type(data.job) ~= 'string' then return end
    
    local online_shop_id = data.shopId and tonumber(data.shopId) or nil
    MySQL.Async.execute('UPDATE rps_businesses SET online_shop_id = ? WHERE job = ?', {online_shop_id, data.job}, function()
        Bridge.Notify(src, 'Linked Online Shop successfully!', 'success')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:setDeliveryCoords', function(data)
    local src = source
    if not CheckCooldown(src, 'setDeliveryCoords', 2000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.job or type(data.job) ~= 'string' then return end
    if not data.coords or type(data.coords) ~= 'table' then return end
    if type(data.coords.x) ~= 'number' or type(data.coords.y) ~= 'number' or type(data.coords.z) ~= 'number' then return end
    
    local coords = type(data.coords) == 'table' and json.encode(data.coords) or data.coords
    MySQL.Async.execute('UPDATE rps_businesses SET delivery_coords = ? WHERE job = ?', {coords, data.job}, function()
        Bridge.Notify(src, 'Delivery Coords updated successfully!', 'success')
    end)
end)


-- ============================================
--  Shop Management
-- ============================================
RegisterNetEvent('rps-bossmenu:server:createJungleShop', function(data)
    local src = source
    if not CheckCooldown(src, 'createJungleShop', 3000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.name or type(data.name) ~= 'string' or #data.name < 1 then
        return Bridge.Notify(src, 'Invalid shop name.', 'error')
    end
    data.name = Sanitize(data.name, 100)
    data.domain = Sanitize(tostring(data.domain or ''), 100)
    data.logo = Sanitize(tostring(data.logo or ''), 255)
    data.template = Sanitize(tostring(data.template or ''), 50)
    
    local itemsJson = data.items and json.encode(data.items) or '[]'
    
    MySQL.Async.execute('INSERT INTO rps_jungle_shops (name, domain, template, logo, items) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), template = VALUES(template), logo = VALUES(logo), items = VALUES(items)', {
        data.name, data.domain, data.template, data.logo, itemsJson
    }, function()
        Bridge.Notify(src, 'Shop created/updated successfully.', 'success')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:editJungleShop', function(data)
    local src = source
    if not CheckCooldown(src, 'editJungleShop', 3000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.id then return end
    data.name = Sanitize(tostring(data.name or ''), 100)
    data.domain = Sanitize(tostring(data.domain or ''), 100)
    data.logo = Sanitize(tostring(data.logo or ''), 255)
    data.template = Sanitize(tostring(data.template or ''), 50)
    
    local itemsJson = data.items and json.encode(data.items) or '[]'
    
    MySQL.Async.execute('UPDATE rps_jungle_shops SET name = ?, domain = ?, template = ?, logo = ?, items = ? WHERE id = ?', {
        data.name, data.domain, data.template, data.logo, itemsJson, data.id
    }, function()
        Bridge.Notify(src, 'Shop updated successfully.', 'success')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:deleteJungleShop', function(data)
    local src = source
    if not CheckCooldown(src, 'deleteJungleShop', 5000) then return end
    if not IsBossmenuAdmin(src) then return end
    if not data or not data.id then return end
    MySQL.Async.execute('DELETE FROM rps_jungle_shops WHERE id = ?', {data.id})
end)
