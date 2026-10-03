-- ============================================
--  Order Callbacks
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:orderItems', function(source, cb, data)
    local src = source
    local pData = GetPlayer(src)
    if not pData then return cb(false, 'Not logged in') end

    local jobName = pData.PlayerData.job.name
    local cartItems = data.items
    local sellerShopId = tonumber(data.shopId)

    if not cartItems or next(cartItems) == nil then
        Bridge.Notify(src, 'Your cart is empty.', 'error')
        return cb(false, 'Your cart is empty.')
    end
    if not sellerShopId then
        return cb(false, 'Invalid shop')
    end

    -- Prices are never trusted from the client — recompute the total here
    -- from the shop's own catalog so a modified NUI/client can't submit an
    -- arbitrary total for whatever items it puts in the cart.
    MySQL.Async.fetchScalar('SELECT items FROM rps_jungle_shops WHERE id = ?', {sellerShopId}, function(catalogJson)
        local catalog = SafeDecode(catalogJson)
        local priceByItem = {}
        for _, entry in ipairs(catalog) do
            if type(entry) == 'table' and entry.id then
                priceByItem[entry.id] = tonumber(entry.price) or 0
            end
        end

        local items = {}
        local total = 0
        for itemName, count in pairs(cartItems) do
            count = tonumber(count)
            local price = priceByItem[itemName]
            if type(itemName) ~= 'string' or not price or not count or count <= 0 or count ~= math.floor(count) then
                return cb(false, 'Invalid item in cart')
            end
            items[itemName] = count
            total = total + (price * count)
        end

        if total <= 0 or total > (Config.MaxOrderTotal or 5000000) then
            return cb(false, 'Invalid order total')
        end
        total = math.floor(total)

        ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
            if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then
                return cb(false, 'No permission')
            end

            MySQL.Async.fetchAll('SELECT job FROM rps_businesses WHERE online_shop_id = ?', {sellerShopId}, function(res)
                local linkedSellerJob = res[1] and res[1].job or nil

                if linkedSellerJob then
                    if RemoveSocietyMoney(jobName, total, "Jungle Order") then
                        MySQL.Async.insert('INSERT INTO rps_orders (seller_shop_id, buyer_job, items, total_price, status) VALUES (?, ?, ?, ?, ?)', {
                            sellerShopId, jobName, json.encode(items), total, 'pending'
                        }, function(insertId)
                            SaveSocietyLog(jobName, 'webshop', "Jungle Order #"..insertId, pData.PlayerData.charinfo.firstname, total)
                            Bridge.Notify(src, 'Order placed! Waiting for seller to accept.', 'success')
                            cb(true)
                        end)
                    else
                        Bridge.Notify(src, 'Card Declined: Insufficient society funds.', 'error')
                        cb(false, 'Card Declined: Insufficient Funds')
                    end
                else
                    if RemoveSocietyMoney(jobName, total, "Jungle Order (Auto)") then
                        MySQL.Async.fetchAll('SELECT delivery_coords FROM rps_businesses WHERE job = ?', {jobName}, function(buyerRes)
                            local coordsStr = buyerRes[1] and buyerRes[1].delivery_coords or nil
                            if not coordsStr or coordsStr == 'null' or coordsStr == '' then
                                AddSocietyMoney(jobName, total, "Refund: No Delivery Spot")
                                SaveSocietyLog(jobName, 'deposit', "Refund: No Delivery Zone", pData.PlayerData.charinfo.firstname, total)
                                Bridge.Notify(src, 'Your business has no delivery zone set by admins!', 'error')
                                return cb(false, 'No delivery zone set by admins!')
                            end

                            local deliveryCoords = SafeDecode(coordsStr)
                            if not deliveryCoords.x then
                                AddSocietyMoney(jobName, total, "Refund: Bad Delivery Coords")
                                SaveSocietyLog(jobName, 'deposit', "Refund: Bad Delivery Zone Data", pData.PlayerData.charinfo.firstname, total)
                                Bridge.Notify(src, 'Your business delivery zone data is corrupted. Ask an admin to re-set it!', 'error')
                                return cb(false, 'Corrupted delivery zone data!')
                            end
                            print("^2[rps_bossmenu] Attempting to auto-process order for", jobName, "^7")
                            MySQL.Async.insert('INSERT INTO rps_orders (seller_shop_id, buyer_job, items, total_price, status) VALUES (?, ?, ?, ?, ?)', {
                                sellerShopId, jobName, json.encode(items), total, 'accepted'
                            }, function(insertId)
                                if not insertId or insertId == 0 then
                                    print("^1[rps_bossmenu] Failed to insert auto-order into DB!^7")
                                else
                                    print("^2[rps_bossmenu] Inserted auto-order #"..tostring(insertId).."! Triggering client...^7")
                                    local orderId = insertId
                                    SaveSocietyLog(jobName, 'webshop', "Jungle Auto-Order #"..orderId, pData.PlayerData.charinfo.firstname, total)
                                    TriggerClientEvent('rps-bossmenu:client:spawnAutoDeliveryTruck', src, orderId, deliveryCoords, jobName)
                                    cb(true)
                                end
                            end)
                        end)
                    else
                        Bridge.Notify(src, 'Card Declined: Insufficient society funds.', 'error')
                        cb(false, 'Card Declined: Insufficient Funds')
                    end
                end
            end)
        end)
    end)
end)

Bridge.RegisterCallback('rps-bossmenu:server:getOrdersCallback', function(source, cb, shopId)
    local src = source
    if not shopId then return cb({}) end
    local pData = GetPlayer(src)
    if not pData then return cb({}) end
    local jobName = pData.PlayerData.job.name

    MySQL.Async.fetchAll('SELECT job FROM rps_businesses WHERE online_shop_id = ?', {shopId}, function(res)
        if not res or not res[1] or res[1].job ~= jobName then return cb({}) end
        
        ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
            if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then return cb({}) end
            MySQL.Async.fetchAll('SELECT * FROM rps_orders WHERE seller_shop_id = ? ORDER BY time DESC', {shopId}, function(results)
                cb(results or {})
            end)
        end)
    end)
end)

Bridge.RegisterCallback('rps-bossmenu:server:getMessagesCallback', function(source, cb, jobId)
    local src = source
    if not jobId then return cb({}) end
    local pData = GetPlayer(src)
    if not pData or pData.PlayerData.job.name ~= jobId then return cb({}) end
    
    MySQL.Async.fetchAll('SELECT * FROM rps_messages WHERE job = ? ORDER BY time DESC LIMIT 20', {jobId}, function(results)
        cb(results or {})
    end)
end)

-- ============================================
--  Order Management
-- ============================================
RegisterNetEvent('rps-bossmenu:server:acceptOrder', function(data)
    local src = source
    if not CheckCooldown(src, 'acceptOrder', 3000) then return end
    local orderId = tonumber(data.orderId)
    if not orderId then return end
    local sellerJob = data.jobId
    local pData = Bridge.GetPlayer(src)
    if not pData or pData.PlayerData.job.name ~= sellerJob then return end

    MySQL.Async.fetchAll('SELECT seller_shop_id, status FROM rps_orders WHERE id = ?', {orderId}, function(orderRes)
        if not orderRes or not orderRes[1] or orderRes[1].status ~= 'pending' then return end

        MySQL.Async.fetchAll('SELECT job FROM rps_businesses WHERE online_shop_id = ?', {orderRes[1].seller_shop_id}, function(bizRes)
            if not bizRes or not bizRes[1] or bizRes[1].job ~= sellerJob then return end

            ValidateAccess(src, sellerJob, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
                if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then
                    return Bridge.Notify(src, 'You do not have permission to accept orders.', 'error')
                end

                MySQL.Async.execute('UPDATE rps_orders SET status = "accepted" WHERE id = ? AND status = "pending"', {orderId}, function(rows)
                    if rows == 0 then return end

                    MySQL.Async.fetchAll('SELECT delivery_coords FROM rps_businesses WHERE job = ?', {sellerJob}, function(sellerRes)
                        local sellerCoordsStr = sellerRes[1] and sellerRes[1].delivery_coords or nil
                        if sellerCoordsStr and sellerCoordsStr ~= 'null' and sellerCoordsStr ~= '' then
                            local sellerCoords = SafeDecode(sellerCoordsStr)
                            if not sellerCoords.x then
                                return Bridge.Notify(src, 'Your loading dock data is corrupted. Ask an admin to re-set it!', 'error')
                            end

                            MySQL.Async.fetchAll('SELECT buyer_job FROM rps_orders WHERE id = ?', {orderId}, function(orderRow)
                                local buyerJob = orderRow[1] and orderRow[1].buyer_job
                                MySQL.Async.fetchAll('SELECT delivery_coords FROM rps_businesses WHERE job = ?', {buyerJob}, function(buyerRes)
                                    local buyerCoordsStr = buyerRes[1] and buyerRes[1].delivery_coords or nil
                                    local buyerCoords = nil
                                    if buyerCoordsStr and buyerCoordsStr ~= 'null' and buyerCoordsStr ~= '' then
                                        local decoded = SafeDecode(buyerCoordsStr)
                                        buyerCoords = decoded.x and decoded or nil
                                    end

                                    TriggerClientEvent('rps-bossmenu:client:spawnDeliveryTruck', src, orderId, sellerCoords, buyerCoords, buyerJob)
                                    Bridge.Notify(src, 'Order Accepted! Truck arrived at loading dock.', 'success')
                                end)
                            end)
                        else
                            Bridge.Notify(src, 'Your business has no loading dock set! Contact Admin.', 'error')
                        end
                    end)
                end)
            end)
        end)
    end)
end)

-- ============================================
--  Permission Callbacks
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:hasWebshopPerm', function(source, cb, jobName)
    local src = source
    local pData = GetPlayer(src)
    if not pData or pData.PlayerData.job.name ~= jobName then return cb(false) end
    
    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
        if actualBoss or isOwner or HasPerm(perms, 'webshop') then
            cb(true)
        else
            cb(false)
        end
    end)
end)

-- ============================================
--  Item Verification & Removal
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:checkAndRemoveOrderItems', function(source, cb, orderId)
    local src = source
    local pData = GetPlayer(src)
    if not pData then return cb(false, "Player not found") end
    
    MySQL.Async.fetchAll('SELECT items FROM rps_orders WHERE id = ?', {orderId}, function(res)
        if res and res[1] then
            local items = SafeDecode(res[1].items)

            local hasAll = true
            local missingMsg = ""

            local function getItemCount(itemName)
                return exports.rps_lib:GetItemCount(src, itemName) or 0
            end

            for itemName, count in pairs(items) do
                if getItemCount(itemName) < count then
                    hasAll = false
                    local iData = Bridge.GetItemData(itemName)
                    missingMsg = "Missing " .. count .. "x " .. (iData and iData.label or itemName)
                    break
                end
            end
            
            if hasAll then
                for itemName, count in pairs(items) do
                    RemoveItem(src, itemName, count)
                    Bridge.NotifyItem(src, Bridge.GetItemData(itemName), 'remove')
                end
                cb(true)
            else
                cb(false, missingMsg)
            end
        else
            cb(false, "Order not found in database")
        end
    end)
end)

-- ============================================
--  Dispatch Shipped Order
-- ============================================
RegisterNetEvent('rps-bossmenu:server:dispatchShippedOrder', function(orderId, buyerJob, buyerCoords)
    local sellerSrc = source
    if not CheckCooldown(sellerSrc, 'dispatchShipped', 3000) then return end
    orderId = tonumber(orderId)
    if not orderId then return end
    local pData = Bridge.GetPlayer(sellerSrc)
    if not pData then return end
    
    local sellerJob = pData.PlayerData.job.name
    MySQL.Async.fetchAll('SELECT seller_shop_id, buyer_job, status FROM rps_orders WHERE id = ?', {orderId}, function(res)
        if not res or not res[1] or res[1].status ~= 'accepted' then return end
        
        local trueBuyerJob = res[1].buyer_job
        
        MySQL.Async.fetchAll('SELECT job FROM rps_businesses WHERE online_shop_id = ?', {res[1].seller_shop_id}, function(bizRes)
            if not bizRes or not bizRes[1] or bizRes[1].job ~= sellerJob then return end
            
            MySQL.Async.execute('UPDATE rps_orders SET status = "shipped" WHERE id = ? AND status = "accepted"', {orderId}, function(rows)
                if rows == 0 then return end
                
                local sellerJobLabel = Bridge.GetJobs()[sellerJob] and Bridge.GetJobs()[sellerJob].label or sellerJob
                
                local messageContent = {
                    text = 'Your package from ' .. sellerJobLabel .. ' has been shipped! Please let us know when you are available for delivery.',
                    action = 'dispatchDelivery',
                    orderId = orderId
                }
                
                MySQL.Async.execute('INSERT INTO rps_messages (job, title, content) VALUES (?, ?, ?)', {
                    trueBuyerJob, 
                    'Go Postal Delivery Update', 
                    json.encode(messageContent)
                })
                
                for _, playerIdStr in ipairs(GetPlayers()) do
                    local Target = GetPlayer(tonumber(playerIdStr))
                    if Target and Target.PlayerData.job.name == trueBuyerJob then
                        Bridge.Notify(tonumber(playerIdStr), 'You received a new Go Postal message regarding a delivery!', 'primary')
                        break
                    end
                end
            end)
        end)
    end)
end)

-- ============================================
--  Delivery Spawn
-- ============================================
RegisterNetEvent('rps-bossmenu:server:triggerDeliverySpawn', function(orderId, msgId)
    local src = source
    if not CheckCooldown(src, 'deliverySpawn', 5000) then return end
    orderId = tonumber(orderId)
    if not orderId then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    
    local buyerJob = pData.PlayerData.job.name
    
    MySQL.Async.fetchAll('SELECT buyer_job, status FROM rps_orders WHERE id = ?', {orderId}, function(orderRes)
        if orderRes and orderRes[1] and orderRes[1].status == 'shipped' and orderRes[1].buyer_job == buyerJob then
            MySQL.Async.fetchAll('SELECT delivery_coords FROM rps_businesses WHERE job = ?', {buyerJob}, function(bizRes)
                local coordsStr = bizRes[1] and bizRes[1].delivery_coords or nil
                if coordsStr and coordsStr ~= 'null' and coordsStr ~= '' then
                    local buyerCoords = SafeDecode(coordsStr)
                    if not buyerCoords.x then
                        return Bridge.Notify(src, 'Your loading dock data is corrupted. Ask an admin to re-set it!', 'error')
                    end

                    if msgId then
                        MySQL.Async.execute('DELETE FROM rps_messages WHERE id = ? AND job = ?', {msgId, buyerJob})
                    end
                    
                    TriggerClientEvent('rps-bossmenu:client:spawnAutoDeliveryTruck', src, orderId, buyerCoords, buyerJob)
                    Bridge.Notify(src, 'A delivery truck has been dispatched to your loading dock!', 'success')
                else
                    Bridge.Notify(src, 'Your business has no loading dock set!', 'error')
                end
            end)
        else
            Bridge.Notify(src, 'Invalid order or already dispatched.', 'error')
        end
    end)
end)

-- ============================================
--  Refund Logic
-- ============================================
local function RefundOrder(src, orderId, newStatus)
    MySQL.Async.fetchAll('SELECT buyer_job, total_price FROM rps_orders WHERE id = ?', {orderId}, function(res)
        if res and res[1] then
            local buyerJob = res[1].buyer_job
            local total = res[1].total_price
            
            AddSocietyMoney(buyerJob, total, "Refund: Order " .. orderId)
            SaveSocietyLog(buyerJob, 'deposit', "Refund: Order #"..orderId, 'System', total)
            MySQL.Async.execute('UPDATE rps_orders SET status = ? WHERE id = ?', {newStatus, orderId})
            
            local title = newStatus == 'declined' and 'Order Declined' or 'Order Refunded'
            local content = 'Your Jungle order #' .. orderId .. ' was ' .. newStatus .. ' and $' .. total .. ' was refunded to your society account.'
            MySQL.Async.execute('INSERT INTO rps_messages (job, title, content) VALUES (?, ?, ?)', {buyerJob, title, content})
            
            if src then
                Bridge.Notify(src, 'Order ' .. newStatus .. ' and refunded.', 'success')
            end
        end
    end)
end

-- ============================================
--  Decline & Refund Events
-- ============================================
local function ValidateOrderOwner(src, orderId, allowedStatus, cb)
    local pData = Bridge.GetPlayer(src)
    if not pData then return cb(false) end
    local jobName = pData.PlayerData.job.name

    MySQL.Async.fetchAll('SELECT seller_shop_id, status FROM rps_orders WHERE id = ?', {orderId}, function(res)
        if not res or not res[1] then return cb(false) end
        if res[1].status ~= allowedStatus then return cb(false) end

        MySQL.Async.fetchAll('SELECT job FROM rps_businesses WHERE online_shop_id = ?', {res[1].seller_shop_id}, function(bizRes)
            if not bizRes or not bizRes[1] or bizRes[1].job ~= jobName then return cb(false) end
            cb(true, pData)
        end)
    end)
end

RegisterNetEvent('rps-bossmenu:server:declineOrder', function(data)
    local src = source
    if not CheckCooldown(src, 'declineOrder', 3000) then return end
    if not data or not data.orderId then return end
    ValidateOrderOwner(src, data.orderId, 'pending', function(valid, pData)
        if not valid then return end
        ValidateAccess(src, pData.PlayerData.job.name, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
            if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then return end
            RefundOrder(src, data.orderId, 'declined')
        end)
    end)
end)

RegisterNetEvent('rps-bossmenu:server:refundOrder', function(data)
    local src = source
    if not CheckCooldown(src, 'refundOrder', 3000) then return end
    if not data or not data.orderId then return end
    ValidateOrderOwner(src, data.orderId, 'completed', function(valid, pData)
        if not valid then return end
        ValidateAccess(src, pData.PlayerData.job.name, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
            if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then return end
            RefundOrder(src, data.orderId, 'refunded')
        end)
    end)
end)



-- ============================================
--  Useable Items - Packaging
-- ============================================
local createUseable = Bridge.CreateUseableItem
createUseable('packaging', function(source, item)
    local src = source
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    
    TriggerClientEvent('rps-bossmenu:client:usePackaging', src)
end)

RegisterNetEvent('rps-bossmenu:server:consumePackaging', function()
    local src = source
    if not CheckCooldown(src, 'consumePackaging', 2000) then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    
    local jobName = pData.PlayerData.job.name
    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then return end
        
        pData.Functions.RemoveItem('packaging', 1)
        Bridge.NotifyItem(src, Bridge.GetItemData('packaging'), 'remove')
    end)
end)

-- ============================================
--  Delivery Completion
-- ============================================
RegisterNetEvent('rps-bossmenu:server:deliveryComplete', function(orderId, buyerJob)
    local src = source
    if not CheckCooldown(src, 'deliveryComplete', 5000) then return end
    orderId = tonumber(orderId)
    if not orderId then
        print(('^1[rps_bossmenu] deliveryComplete: invalid orderId from src %s^7'):format(src))
        return
    end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    if pData.PlayerData.job.name ~= buyerJob then
        return Bridge.Notify(src, 'This delivery is not for your business.', 'error')
    end

    ValidateAccess(src, buyerJob, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'webshop', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'webshop') then
            return Bridge.Notify(src, 'You lack permission to receive deliveries for this business.', 'error')
        end
        MySQL.Async.fetchAll(
            'SELECT items FROM rps_orders WHERE id = ? AND buyer_job = ? AND status IN ("shipped", "accepted")',
            {orderId, buyerJob},
            function(res)
                if not res or not res[1] then
                    print(('^1[rps_bossmenu] deliveryComplete: order #%s not found for buyer_job=%s in status shipped/accepted (already completed, wrong job, or missing)^7'):format(orderId, buyerJob))
                    return Bridge.Notify(src, 'This delivery was already received or could not be found.', 'error')
                end
                local items = SafeDecode(res[1].items)
                if type(items) ~= 'table' or next(items) == nil then
                    print(('^1[rps_bossmenu] deliveryComplete: order #%s has empty/corrupt items payload^7'):format(orderId))
                    return Bridge.Notify(src, 'This order has no items on record.', 'error')
                end
                MySQL.Async.execute(
                    'UPDATE rps_orders SET status = "completed" WHERE id = ? AND status IN ("shipped", "accepted")',
                    {orderId},
                    function(rows)
                        if rows == 0 then
                            print(('^1[rps_bossmenu] deliveryComplete: order #%s status flip to completed affected 0 rows (race with another completion attempt)^7'):format(orderId))
                            return Bridge.Notify(src, 'This delivery was already received.', 'error')
                        end

                        local Target = Bridge.GetPlayer(src)
                        if not Target then return end

                        local anyFailed = false
                        for itemName, count in pairs(items) do
                            local isUnique = Bridge.GetItemData(itemName) and Bridge.GetItemData(itemName).unique or false
                            if isUnique then
                                for i = 1, count do
                                    local ok = Target.Functions.AddItem(itemName, 1)
                                    if ok then
                                        Bridge.NotifyItem(src, Bridge.GetItemData(itemName), 'add')
                                    else
                                        anyFailed = true
                                        print(('^1[rps_bossmenu] deliveryComplete: AddItem failed for "%s" x1 (order #%s, src %s)^7'):format(itemName, orderId, src))
                                    end
                                end
                            else
                                local ok = Target.Functions.AddItem(itemName, count)
                                if ok then
                                    Bridge.NotifyItem(src, Bridge.GetItemData(itemName), 'add')
                                else
                                    anyFailed = true
                                    print(('^1[rps_bossmenu] deliveryComplete: AddItem failed for "%s" x%s (order #%s, src %s)^7'):format(itemName, count, orderId, src))
                                end
                            end
                        end

                        if anyFailed then
                            Bridge.Notify(src, 'Some items could not be added — check your inventory space.', 'error')
                        else
                            Bridge.Notify(src, 'You received your ordered items!', 'success')
                        end
                    end
                )
            end
        )
    end)
end)

-- ============================================
--  Delivery Box Handler
-- ============================================
local function handleDeliveryBox(source, item)
    local src = source
    local pData = Bridge.GetPlayer(src)
    if not pData then return end

    local metadata = type(item) == 'table' and (item.info or item.metadata) or nil

    if not metadata or type(metadata) ~= 'table' or not metadata.items then
        Bridge.Notify(src, 'This box is empty or corrupted!', 'error')
        return
    end

    local items = metadata.items
    local addedAny = false
    for itemName, count in pairs(items) do
        local itemData = Bridge.GetItemData(itemName)
        if itemData then
            if itemData.unique then
                for i = 1, count do
                    -- AddItem (server/main.lua) auto-fills weapon metadata when info is nil.
                    AddItem(src, itemName, 1)
                    Bridge.NotifyItem(src, itemData, 'add')
                end
            else
                AddItem(src, itemName, count)
                Bridge.NotifyItem(src, itemData, 'add')
            end
            addedAny = true
        end
    end

    if not addedAny then
        Bridge.Notify(src, 'The box was completely empty!', 'error')
    else
        Bridge.Notify(src, 'You unpacked the delivery box!', 'success')
    end

    RemoveItem(src, 'delivery_box', 1, item.slot)
    Bridge.NotifyItem(src, Bridge.GetItemData('delivery_box'), 'remove')
end

local createUseable = Bridge.CreateUseableItem
createUseable('delivery_box', handleDeliveryBox)
RegisterNetEvent('rps-bossmenu:server:useDeliveryBox', function()
    local src = source
    local serverItem = nil

    for _, entry in ipairs(exports.rps_lib:GetInventory(src) or {}) do
        if entry.name == 'delivery_box' then
            serverItem = { metadata = entry.metadata }
            break
        end
    end

    if not serverItem then
        return Bridge.Notify(src, 'You do not have a delivery box.', 'error')
    end

    handleDeliveryBox(src, serverItem)
end)


-- ============================================
--  Exports
-- ============================================
exports('PlaceJungleOrder', function(sellerShopId, buyerJob, items, totalPrice, skipPayment)
    local invoker = GetInvokingResource()
    if not invoker then return false, "Cannot be called directly" end
    if Config.AllowedExportResources and #Config.AllowedExportResources > 0 then
        local allowed = false
        for _, res in ipairs(Config.AllowedExportResources) do
            if res == invoker then allowed = true break end
        end
        if not allowed then return false, "Resource not authorized" end
    end

    if not sellerShopId or not buyerJob or type(items) ~= 'table' or type(totalPrice) ~= 'number' then 
        return false, "Invalid parameters"
    end
    
    if totalPrice < 0 then return false, "Invalid total price" end
    totalPrice = math.floor(totalPrice)
    if next(items) == nil then return false, "Order must contain items" end
    for k, v in pairs(items) do
        if type(k) ~= 'string' or type(v) ~= 'number' or v <= 0 then
            return false, "Invalid item format or quantity"
        end
    end
    
    local p = promise.new()
    
    local function executeOrder()
        MySQL.Async.insert('INSERT INTO rps_orders (seller_shop_id, buyer_job, items, total_price, status) VALUES (?, ?, ?, ?, ?)', {
            sellerShopId, buyerJob, json.encode(items), totalPrice, 'pending'
        }, function(insertId)
            if insertId and insertId > 0 then
                p:resolve(insertId)
            else
                p:resolve(false)
            end
        end)
    end
    
    if skipPayment then
        executeOrder()
    else
        if RemoveSocietyMoney(buyerJob, totalPrice, "Jungle API Order") then
            SaveSocietyLog(buyerJob, 'webshop', "Jungle API Order", 'System', totalPrice)
            executeOrder()
        else
            p:resolve(false)
        end
    end
    
    local orderId = Citizen.Await(p)
    if orderId then
        return true, orderId
    else
        return false, "Database insertion or payment failed"
    end
end)
