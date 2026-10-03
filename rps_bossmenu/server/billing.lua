-- ============================================
--  Billing Tablet
-- ============================================


RegisterNetEvent('rps-bossmenu:server:requestBillingTablet', function()
    local src = source
    if not CheckCooldown(src, 'tablet', 1000) then return end
    local pData = GetPlayer(src)
    if not pData then return end
    
    local jobName = pData.PlayerData.job.name
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local myCid = pData.PlayerData.citizenid
    
    local nearby = getNearbyPlayers(coords)
    MySQL.Async.fetchAll('SELECT id, targetName, targetCid, senderSrc, amount, reason, status, time, job, org, senderName FROM rps_invoices WHERE job = ? ORDER BY id DESC LIMIT 100', {jobName}, function(results)
        local jobInvoices = {}
        for i=1, #results do
            table.insert(jobInvoices, {
                id = results[i].id,
                to = results[i].targetName,
                targetCid = results[i].targetCid,
                senderSrc = results[i].senderSrc,
                amount = results[i].amount,
                reason = results[i].reason,
                status = results[i].status,
                time = results[i].time,
                job = results[i].org or results[i].job,
                org = results[i].org,
                from = results[i].senderName
            })
        end
        
        ValidateAccess(src, jobName, myCid, pData.PlayerData.job.isboss, 'ledger', function(isOwner, actualBoss, perms)
            local hasLedgerAccess = isOwner or actualBoss or HasPerm(perms, 'ledger')
            TriggerClientEvent('rps-bossmenu:client:openBillingTablet', src, {
                nearby = nearby,
                invoices = jobInvoices,
                businessName = pData.PlayerData.job.label,
                isBoss = hasLedgerAccess
            })
        end)
    end)
end)

-- ============================================
--  Tablet - Employee Management (boss/owner only)
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:getEmployeesCallback', function(source, cb)
    local src = source
    local pData = GetPlayer(src)
    if not pData then return cb({ canManage = false, employees = {}, grades = {} }) end

    local jobName = pData.PlayerData.job.name
    local myCid = pData.PlayerData.citizenid

    ValidateAccess(src, jobName, myCid, pData.PlayerData.job.isboss, nil, function(isOwner, actualBoss)
        if not isOwner and not actualBoss then
            return cb({ canManage = false, employees = {}, grades = {} })
        end

        BuildEmployeeRoster(jobName, function(employees, grades)
            cb({
                canManage = true,
                employees = employees,
                grades = grades,
                myCid = myCid,
                isOwner = isOwner,
                isBoss = actualBoss
            })
        end)
    end)
end)

-- ============================================
--  Invoice - Send
-- ============================================
RegisterNetEvent('rps-bossmenu:server:sendInvoice', function(data)
    local src = source
    if not CheckCooldown(src, 'sendInvoice', 2000) then return end
    local pData = GetPlayer(src)
    if not pData then return end
    local amount = tonumber(data.amount)
    if not amount or amount ~= amount or math.abs(amount) == math.huge or amount <= 0 or amount > (Config.MaxInvoice or 1000000) then
        return Bridge.Notify(src, 'Invalid invoice amount.', 'error')
    end
    amount = math.floor(amount)

    local jobName = pData.PlayerData.job.name
    local orgName = pData.PlayerData.job.label
    local senderName = pData.PlayerData.charinfo.firstname .. ' ' .. pData.PlayerData.charinfo.lastname

    local targetSrc = tonumber(data.target)
    if targetSrc == src then return Bridge.Notify(src, 'You cannot invoice yourself.', 'error') end

    local T = GetPlayer(targetSrc)

    if not T then
        return Bridge.Notify(src, 'Player not found.', 'error')
    end
    local senderPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetSrc)
    local senderPos = GetEntityCoords(senderPed)
    local targetPos = GetEntityCoords(targetPed)
    if #(senderPos - targetPos) > (Config.InteractionDistance or 5.0) then
        return Bridge.Notify(src, 'Player is not nearby.', 'error')
    end

    local targetCid = T.PlayerData.citizenid
    local targetName = T.PlayerData.charinfo.firstname .. ' ' .. T.PlayerData.charinfo.lastname
    local invoiceId = tostring(os.time()) .. '-' .. tostring(math.random(100000, 999999))
    local reason = Sanitize(tostring(data.reason or 'No reason'), 128)

    MySQL.Async.execute('INSERT INTO rps_invoices (id, targetName, targetSrc, targetCid, senderSrc, amount, reason, status, time, job, org, senderName) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
        invoiceId, targetName, targetSrc, targetCid, src, amount, reason, 'pending', 'Just now', jobName, orgName, senderName
    })

    TriggerClientEvent('rps-bossmenu:client:receiveInvoice', targetSrc, {
        amount = amount,
        reason = reason,
        from = senderName,
        org = orgName,
        invoiceId = invoiceId,
        time = 'Just now'
    })

    Bridge.Notify(src, 'Sent $'..amount..' invoice to '..targetName, 'success')
end)

-- ============================================
--  Invoice - Pay
-- ============================================
RegisterNetEvent('rps-bossmenu:server:payInvoice', function(data)
    local src = source
    if not CheckCooldown(src, 'payInvoice', 2000) then return end
    local pData = GetPlayer(src)
    if not pData then return end
    if data.method ~= 'cash' and data.method ~= 'card' then
        return Bridge.Notify(src, 'Invalid payment method.', 'error')
    end
    MySQL.Async.execute('UPDATE rps_invoices SET status = "paid" WHERE id = ? AND status = "pending"', {data.invoiceId}, function(rowsChanged)
        if rowsChanged == 0 then
            return Bridge.Notify(src, 'Invoice already paid or not found.', 'error')
        end

        MySQL.Async.fetchAll('SELECT * FROM rps_invoices WHERE id = ?', {data.invoiceId}, function(result)
            if not result[1] then return end
            local inv = result[1]

            if inv.targetCid ~= pData.PlayerData.citizenid then
                MySQL.Async.execute('UPDATE rps_invoices SET status = "pending" WHERE id = ?', {data.invoiceId})
                return Bridge.Notify(src, 'This invoice is not addressed to you.', 'error')
            end

            local success = false
            local msg = ""

            if data.method == 'cash' then
                if pData.PlayerData.money.cash >= inv.amount then
                    pData.Functions.RemoveMoney('cash', inv.amount, "Paid Invoice: " .. inv.reason)
                    success = true
                else
                    msg = "Not enough cash on hand."
                end
            elseif data.method == 'card' then
                if pData.PlayerData.money.bank >= inv.amount then
                    pData.Functions.RemoveMoney('bank', inv.amount, "Paid Invoice: " .. inv.reason)
                    success = true
                else
                    msg = "Not enough money in bank."
                end
            end

            if success then
                local commissionPct = Config.Commission or 0
                local commissionCut = 0
                local businessCut = inv.amount

                if commissionPct >= 100 then commissionPct = 0 end
                if commissionPct > 0 then
                    commissionCut = math.floor((inv.amount * commissionPct) / 100)
                    businessCut = inv.amount - commissionCut
                end

                AddSocietyMoney(inv.job, businessCut, "Invoice Payment: " .. inv.reason)
                local freshData = GetPlayer(src)
                local payerName = freshData and (freshData.PlayerData.charinfo.firstname .. ' ' .. freshData.PlayerData.charinfo.lastname) or 'Unknown'
                SaveSocietyLog(inv.job, 'deposit', "Invoice Paid: " .. inv.reason, payerName, businessCut)

                Bridge.Notify(src, 'Invoice paid successfully.', 'success')
                local Sender = GetPlayer(inv.senderSrc)
                if Sender and (Sender.PlayerData.charinfo.firstname .. ' ' .. Sender.PlayerData.charinfo.lastname) == inv.senderName then
                    Bridge.Notify(inv.senderSrc, inv.targetName..' paid their invoice.', 'success')
                    if commissionCut > 0 then
                        Sender.Functions.AddMoney('bank', commissionCut, "Invoice Commission")
                        Bridge.Notify(inv.senderSrc, 'You received $' .. commissionCut .. ' as commission!', 'success')
                    end
                end
                TriggerClientEvent('rps-bossmenu:client:updateInvoiceStatus', src, inv.id, 'paid')
                TriggerClientEvent('rps-bossmenu:client:invoiceResult', src, true, { amount = inv.amount, method = data.method })
            else
                MySQL.Async.execute('UPDATE rps_invoices SET status = "pending" WHERE id = ?', {inv.id})
                TriggerClientEvent('rps-bossmenu:client:invoiceResult', src, false)
                Bridge.Notify(src, msg, 'error')
            end
        end)
    end)
end)

-- ============================================
--  Invoice - Decline
-- ============================================
RegisterNetEvent('rps-bossmenu:server:declineInvoice', function(data)
    local src = source
    if not CheckCooldown(src, 'declineInvoice', 2000) then return end
    local pData = GetPlayer(src)
    if not pData then return end

    local invoiceId = type(data) == 'table' and (data.id or data.invoiceId) or data
    MySQL.Async.execute('UPDATE rps_invoices SET status = "declined" WHERE id = ? AND status = "pending"', {invoiceId}, function(rowsChanged)
        if rowsChanged == 0 then return end
        
        MySQL.Async.fetchAll('SELECT * FROM rps_invoices WHERE id = ?', {invoiceId}, function(result)
            if not result[1] then return end
            local inv = result[1]

            if inv.targetCid ~= pData.PlayerData.citizenid then
                MySQL.Async.execute('UPDATE rps_invoices SET status = "pending" WHERE id = ?', {invoiceId})
                return Bridge.Notify(src, 'This invoice is not addressed to you.', 'error')
            end

            local Sender = GetPlayer(inv.senderSrc)
            if Sender and (Sender.PlayerData.charinfo.firstname .. ' ' .. Sender.PlayerData.charinfo.lastname) == inv.senderName then 
                Bridge.Notify(inv.senderSrc, inv.targetName..' declined the invoice.', 'error') 
            end
            TriggerClientEvent('rps-bossmenu:client:updateInvoiceStatus', src, invoiceId, 'declined')
        end)
    end)
end)

-- ============================================
--  Invoice - Cancel
-- ============================================
RegisterNetEvent('rps-bossmenu:server:cancelInvoice', function(data)
    local src = source
    if not CheckCooldown(src, 'cancelInvoice', 2000) then return end
    local pData = GetPlayer(src)
    if not pData then return end

    local invoiceId = type(data) == 'table' and (data.id or data.invoiceId) or data
    if not invoiceId then return end

    MySQL.Async.fetchAll('SELECT job FROM rps_invoices WHERE id = ?', {invoiceId}, function(result)
        if not result[1] then return Bridge.Notify(src, 'Could not find invoice to cancel.', 'error') end
        if result[1].job ~= pData.PlayerData.job.name then
            return Bridge.Notify(src, 'You cannot cancel another business\'s invoice.', 'error')
        end
        MySQL.Async.execute('UPDATE rps_invoices SET status = "canceled" WHERE id = ? AND status = "pending"', {invoiceId}, function(rowsChanged)
            if rowsChanged > 0 then
                TriggerClientEvent('rps-bossmenu:client:updateInvoiceStatus', src, invoiceId, 'canceled')
                Bridge.Notify(src, 'Invoice cancelled.', 'success')
            else
                Bridge.Notify(src, 'Could not find invoice to cancel or already processed.', 'error')
            end
        end)
    end)
end)

-- ============================================
--  Invoice - Refund
-- ============================================
RegisterNetEvent('rps-bossmenu:server:refundInvoice', function(invoiceId)
    local src = source
    if not CheckCooldown(src, 'refundInvoice', 2000) then return end
    local pData = GetPlayer(src)
    if not pData then return end
    local jobName = pData.PlayerData.job.name

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'ledger', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'ledger') then return end
        MySQL.Async.execute('UPDATE rps_invoices SET status = "refunded" WHERE id = ? AND status = "paid"', {invoiceId}, function(rowsChanged)
            if rowsChanged == 0 then return Bridge.Notify(src, 'Refund already processed or not paid.', 'error') end

            MySQL.Async.fetchAll('SELECT * FROM rps_invoices WHERE id = ?', {invoiceId}, function(result)
                if not result[1] then return end
                local inv = result[1]

                if inv.job ~= jobName then
                    MySQL.Async.execute('UPDATE rps_invoices SET status = "paid" WHERE id = ?', {invoiceId})
                    return Bridge.Notify(src, 'You cannot refund another business\'s invoice.', 'error')
                end

                local Target = Bridge.GetPlayerByCitizenId(inv.targetCid)
                if not Target then
                    MySQL.Async.execute('UPDATE rps_invoices SET status = "paid" WHERE id = ?', {invoiceId})
                    return Bridge.Notify(src, 'The player must be online to receive a refund.', 'error')
                end

                local commissionPct = Config.Commission or 0
                local businessCut = inv.amount
                if commissionPct >= 100 then commissionPct = 0 end
                if commissionPct > 0 then
                    businessCut = inv.amount - math.floor((inv.amount * commissionPct) / 100)
                end

                if RemoveSocietyMoney(inv.job, businessCut, "Refunded Invoice: " .. inv.reason) then
                    AddPersonalBank(Target.PlayerData.source, businessCut, "Refund from " .. (inv.org or inv.job))

                    local refundName = pData.PlayerData.charinfo.firstname .. ' ' .. pData.PlayerData.charinfo.lastname
                    SaveSocietyLog(inv.job, 'withdraw', "Refunded Invoice: " .. inv.reason, refundName, businessCut)

                    Bridge.Notify(src, 'Refunded $'..businessCut..' to '..inv.targetName, 'success')
                    Bridge.Notify(Target.PlayerData.source, 'Received $'..businessCut..' refund from '..(inv.org or inv.job), 'info')
                    TriggerClientEvent('rps-bossmenu:client:updateInvoiceStatus', src, inv.id, 'refunded')
                    TriggerClientEvent('rps-bossmenu:client:updateInvoiceStatus', Target.PlayerData.source, inv.id, 'refunded')
                else
                    MySQL.Async.execute('UPDATE rps_invoices SET status = "paid" WHERE id = ?', {invoiceId})
                    Bridge.Notify(src, 'Business account has insufficient funds.', 'error')
                end
            end)
        end)
    end)
end)


-- ============================================
--  Invoice - Ledger Callback
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:getInvoicesCallback', function(source, cb)
    local src = source
    local pData = GetPlayer(src)
    if not pData then return cb({}) end

    local jobName = pData.PlayerData.job.name
    if jobName == 'unemployed' then return cb({}) end

    MySQL.Async.fetchAll('SELECT id, targetName, targetCid, senderSrc, amount, reason, status, time, job, org, senderName FROM rps_invoices WHERE job = ? ORDER BY id DESC LIMIT 100', {jobName}, function(results)
        local invoices = {}
        for i = 1, #results do
            invoices[#invoices + 1] = {
                id = results[i].id,
                to = results[i].targetName,
                targetCid = results[i].targetCid,
                senderSrc = results[i].senderSrc,
                amount = results[i].amount,
                reason = results[i].reason,
                status = results[i].status,
                time = results[i].time,
                job = results[i].org or results[i].job,
                org = results[i].org,
                from = results[i].senderName
            }
        end
        cb(invoices)
    end)
end)

-- ============================================
--  Useable Item - Tablet
-- ============================================
if type(Config.TabletItem) == 'string' then
    Bridge.CreateUseableItem(Config.TabletItem, function(source, item)
        local pData = GetPlayer(source)
        if not pData then return end

        if pData.PlayerData.job.name == 'unemployed' then
            return Bridge.Notify(source, 'You do not have a business.', 'error')
        end

        TriggerClientEvent('rps-bossmenu:client:useTablet', source)
    end)
end
