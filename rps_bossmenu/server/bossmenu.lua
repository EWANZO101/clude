-- ============================================
--  Active Session State
-- ============================================
local ActiveBossMenus = {}
local PendingJobOffers = {}

AddEventHandler('playerDropped', function()
    local src = source
    for job, ownerSrc in pairs(ActiveBossMenus) do
        if ownerSrc == src then ActiveBossMenus[job] = nil end
    end
    PendingJobOffers[src] = nil
end)

-- ============================================
--  Boss Menu Core
-- ============================================
function RefreshBossMenu(src, targetJob)
    local pData = GetPlayer(src)
    if not pData then return end

    local jobName = targetJob or pData.PlayerData.job.name
    
    if ActiveBossMenus[jobName] and ActiveBossMenus[jobName] ~= src then
        local targetPed = GetPlayerPed(ActiveBossMenus[jobName])
        if targetPed > 0 then
            return Bridge.Notify(src, 'Someone else is already using this business terminal!', 'error')
        else
            ActiveBossMenus[jobName] = nil
        end
    end

    local myCid = pData.PlayerData.citizenid
    local isMyJob = (pData.PlayerData.job.name == jobName)
    local myGradeLevel = isMyJob and (tonumber(pData.PlayerData.job.grade.level) or 0) or 0
    local isBoss = isMyJob and pData.PlayerData.job.isboss == true

    ValidateAccess(src, jobName, myCid, isBoss, nil, function(isOwner, actualBoss, myPerms)
        local hasActivePerms = actualBoss or isOwner or HasPerm(myPerms, 'manage') or HasPerm(myPerms, 'hire') or HasPerm(myPerms, 'fire') or HasPerm(myPerms, 'deposit') or HasPerm(myPerms, 'withdraw') or HasPerm(myPerms, 'bonus') or HasPerm(myPerms, 'ledger') or HasPerm(myPerms, 'webshop')

        if hasActivePerms then
            ActiveBossMenus[jobName] = src

            BuildEmployeeRoster(jobName, function(employees, grades)
                local bRes = MySQL.Sync.fetchAll('SELECT min_boss_grade, online_shop_id, allowed_shops FROM rps_businesses WHERE job = ?', {jobName})
                local biz = (bRes and bRes[1]) and bRes[1] or {}

                MySQL.Async.fetchAll('SELECT * FROM rps_society_logs WHERE job = ? ORDER BY time DESC LIMIT 50', {jobName}, function(logs)
                    local jobs = GetJobs()

                    local srcCoords = GetEntityCoords(GetPlayerPed(src))
                    local nearby = {}
                    for _, id in ipairs(GetPlayers()) do
                        id = tonumber(id)
                        if id ~= src then
                            local tPed = GetPlayerPed(id)
                            if tPed and tPed ~= 0 then
                                local tCoords = GetEntityCoords(tPed)
                                if #(srcCoords - tCoords) < 5.0 then
                                    local tPlayer = GetPlayer(id)
                                    if tPlayer then
                                        nearby[#nearby+1] = { id = id, src = id, cid = tPlayer.PlayerData.citizenid, name = tPlayer.PlayerData.charinfo.firstname .. ' ' .. tPlayer.PlayerData.charinfo.lastname }
                                    end
                                end
                            end
                        end
                    end

                    local allowedDomains = biz.allowed_shops and SafeDecode(biz.allowed_shops) or {}

                    local function sendResponse(shops)
                        TriggerClientEvent('rps-bossmenu:client:openBossMenu', src, {
                            employees = employees,
                            logs = logs,
                            grades = grades,
                            nearby = nearby,
                            businessName = jobs[jobName] and jobs[jobName].label or "Unknown",
                            jobId = jobName,
                            rank = pData.PlayerData.job.grade.name,
                            balance = GetSocietyBalance(jobName),
                            isOwner = isOwner,
                            isBoss = isBoss,
                            myCid = myCid,
                            myPermissions = myPerms,
                            allowedShops = shops,
                            onlineShopId = biz.online_shop_id,
                            deliveryCoords = biz.delivery_coords,
                            inventoryImage = Config.InventoryImagePath
                        })
                    end

                    if #allowedDomains > 0 then
                        local placeholder = (('?,'):rep(#allowedDomains)):sub(1, -2)
                        local query = string.format('SELECT * FROM rps_jungle_shops WHERE domain IN (%s)', placeholder)
                        MySQL.Async.fetchAll(query, allowedDomains, function(fetchedShops)
                            sendResponse(fetchedShops or {})
                        end)
                    else
                        sendResponse({})
                    end
                end)
            end)

        else
            Bridge.Notify(src, 'You do not have permission to access management.', 'error')
        end
    end)
end

-- ============================================
--  Network Events - Menu Open & Close
-- ============================================
RegisterNetEvent('rps-bossmenu:server:requestBossMenu', function()
    local src = source
    if not CheckCooldown(src, 'requestBossMenu', 2000) then return end
    RefreshBossMenu(src)
end)
RegisterNetEvent('rps-bossmenu:server:closeBossMenu', function()
    local src = source
    for job, ownerSrc in pairs(ActiveBossMenus) do
        if ownerSrc == src then
            ActiveBossMenus[job] = nil
        end
    end
end)


-- ============================================
--  Employee Management
-- ============================================
RegisterNetEvent('rps-bossmenu:server:manageEmployee', function(data)
    local src = source
    if not CheckCooldown(src, 'manageEmployee', 1000) then return end
    local pData = GetPlayer(src)
    if not pData then return end
    
    local jobName = pData.PlayerData.job.name
    local bossLevel = tonumber(pData.PlayerData.job.grade.level) or 0
    local isBoss = pData.PlayerData.job.isboss
    local myCid = pData.PlayerData.citizenid

    ValidateAccess(src, jobName, myCid, isBoss, nil, function(isOwner, actualBoss, perms)
        local hasAllPerms = HasPerm(perms, 'all_perms')
        local hasMaster = HasPerm(perms, 'master')
        
        if not isOwner and not actualBoss and not HasPerm(perms, 'manage') and not HasPerm(perms, 'rank') and not HasPerm(perms, 'wage') and not hasAllPerms and not hasMaster then
            return Bridge.Notify(src, 'You lack permission to edit employees.', 'error')
        end

        local targetNewLevel = nil
        local jobs = GetJobs()
        
        if jobs[jobName] and jobs[jobName].grades then
            for k, v in pairs(jobs[jobName].grades) do
                if v.name == data.rank then targetNewLevel = tonumber(k); break end
            end
        end
        
        if not targetNewLevel then 
            return Bridge.Notify(src, 'Invalid Rank Selected.', 'error')
        end

        MySQL.Async.fetchScalar('SELECT owner FROM rps_businesses WHERE job = ?', {jobName}, function(ownerString)
            local targetCid = tostring(data.id or '')
            if targetCid == '' then return Bridge.Notify(src, 'Invalid employee ID.', 'error') end
            local isTargetOwner = ownerString and (string.lower(ownerString) == string.lower(targetCid))
            
            if isTargetOwner and not isOwner then
                return Bridge.Notify(src, 'You cannot modify the business owner.', 'error')
            end

            local Target = GetPlayerByCitizenId(data.id)
            
            local function ExecuteUpdate(targetCurrentLevel)
                local tLevel = tonumber(targetCurrentLevel) or 0
                
                local bypassRankCheck = false
                if isOwner or hasMaster or hasAllPerms then bypassRankCheck = true end
                
                if not bypassRankCheck then
                    if tLevel >= bossLevel or targetNewLevel >= bossLevel then
                        return Bridge.Notify(src, 'Cannot manage ranks equal or higher than yours.', 'error')
                    end
                end
                local wage = math.max(0, math.min(tonumber(data.wage) or 100, Config.MaxWage or 100000))
                local function sanitizePerms(rawPerms)
                    local allowed = {manage=true, hire=true, fire=true, bonus=true, deposit=true, withdraw=true, ledger=true, webshop=true}
                    local clean = {}
                    for k, v in pairs(rawPerms or {}) do
                        if allowed[k] then clean[k] = (v == true) end
                    end
                    return clean
                end

                if bypassRankCheck and data.perms then
                    MySQL.Async.fetchScalar('SELECT permissions FROM rps_employee_permissions WHERE citizenid = ? AND job = ?', {data.id, jobName}, function(targetPermJson)
                        local targetPerms = SafeDecode(targetPermJson)
                        local cleanPerms = sanitizePerms(data.perms)
                        if not isOwner and not hasMaster then
                            cleanPerms.all_perms = HasPerm(targetPerms, 'all_perms') or nil
                            cleanPerms.master    = HasPerm(targetPerms, 'master')    or nil
                        end
                        MySQL.Async.execute('INSERT INTO rps_employee_permissions (citizenid, job, permissions) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE permissions = VALUES(permissions)', {
                            data.id, jobName, json.encode(cleanPerms)
                        })
                    end)
                elseif data.perms and (HasPerm(perms, 'manage') or actualBoss) then
                    MySQL.Async.fetchScalar('SELECT permissions FROM rps_employee_permissions WHERE citizenid = ? AND job = ?', {data.id, jobName}, function(targetPermJson)
                        local targetPerms = SafeDecode(targetPermJson)
                        local cleanPerms = sanitizePerms(data.perms)
                        cleanPerms.all_perms = HasPerm(targetPerms, 'all_perms') or nil
                        cleanPerms.master    = HasPerm(targetPerms, 'master')    or nil
                        MySQL.Async.execute('INSERT INTO rps_employee_permissions (citizenid, job, permissions) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE permissions = VALUES(permissions)', {
                            data.id, jobName, json.encode(cleanPerms)
                        })
                    end)
                end

                MySQL.Async.execute('INSERT INTO rps_employee_wages (citizenid, job, wage) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE wage = VALUES(wage)', {
                    data.id, jobName, wage
                })

                local newJobData = { 
                    name = jobName, 
                    label = jobs[jobName].label, 
                    payment = wage, 
                    type = jobs[jobName].type or "none", 
                    isboss = (actualBoss and targetNewLevel >= bossLevel), 
                    grade = {name = data.rank, level = targetNewLevel} 
                }

                if Target then
                    Bridge.SetPlayerJob(Target.PlayerData.source, newJobData)
                end

                Bridge.SetOfflinePlayerJob(data.id, newJobData)

                Bridge.Notify(src, 'Employee updated.', 'success')
                Wait(100)
                RefreshBossMenu(src)
            end

            if Target then
                ExecuteUpdate(Target.PlayerData.job.grade.level)
            else
                Bridge.GetOfflinePlayer(data.id, function(character)
                    local offlineJob = character and character.job
                    ExecuteUpdate(offlineJob and offlineJob.grade and offlineJob.grade.level or 0)
                end)
            end
        end)
    end)
end)

-- ============================================
--  Employee Termination
-- ============================================
RegisterNetEvent('rps-bossmenu:server:fireEmployee', function(data)
    local src = source
    if not CheckCooldown(src, 'fireEmployee', 2000) then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    local jobName = pData.PlayerData.job.name
    local targetCid = tostring(data.id or '')
    if targetCid == '' then return end

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'fire', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'fire') then return end
        local Target = Bridge.GetPlayerByCitizenId(targetCid)
        if Target then
            if Target.PlayerData.job.name ~= jobName then
                return Bridge.Notify(src, 'That player is not in your business.', 'error')
            end
            Target.Functions.SetJob("unemployed", 0)
        else
            Bridge.GetOfflinePlayer(targetCid, function(character)
                local offlineJob = character and character.job
                if not offlineJob or offlineJob.name ~= jobName then
                    return Bridge.Notify(src, 'That player is not in your business.', 'error')
                end
                Bridge.SetOfflinePlayerJob(targetCid, {name="unemployed",label="Unemployed",payment=10,type="none",isboss=false,grade={name="Freelancer",level=0}})
            end)
        end

        MySQL.Async.execute('DELETE FROM rps_employee_permissions WHERE citizenid = ? AND job = ?', {targetCid, jobName})
        MySQL.Async.execute('DELETE FROM rps_employee_wages WHERE citizenid = ? AND job = ?', {targetCid, jobName})
        Bridge.Notify(src, 'Employee Terminated.', 'success')
        Wait(100)
        RefreshBossMenu(src)
    end)
end)

-- ============================================
--  Financial - Bonuses
-- ============================================
RegisterNetEvent('rps-bossmenu:server:giveBonus', function(data)
    local src = source
    if not CheckCooldown(src, 'giveBonus', 2000) then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    local jobName = pData.PlayerData.job.name
    local amount = tonumber(data.amount)
    if not amount or amount ~= amount or math.abs(amount) == math.huge or amount <= 0 then
        return Bridge.Notify(src, 'Invalid bonus amount.', 'error')
    end
    amount = math.floor(amount)
    local targetCid = tostring(data.id or '')
    if targetCid == '' then return Bridge.Notify(src, 'Invalid employee.', 'error') end

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'bonus', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'bonus') then return end
        local Target = Bridge.GetPlayerByCitizenId(targetCid)
        if Target and Target.PlayerData.job.name ~= jobName then
            return Bridge.Notify(src, 'That player is not in your business.', 'error')
        end

        if RemoveSocietyMoney(jobName, amount, "Bonus") then
            if Target then
                Target.Functions.AddMoney('bank', amount, "Bonus")
                Bridge.Notify(Target.PlayerData.source, 'You received $'..amount..' bonus!', 'success')
            else
                Bridge.AddOfflinePlayerMoney(targetCid, amount, 'bank')
            end
            SaveSocietyLog(jobName, 'bonus', 'Bonus Paid', pData.PlayerData.charinfo.firstname, amount)
            Bridge.Notify(src, 'Bonus paid.', 'success')
            RefreshBossMenu(src)
        else
            Bridge.Notify(src, 'Insufficient society funds.', 'error')
        end
    end)
end)


-- ============================================
--  Financial - Deposits & Withdrawals
-- ============================================
RegisterNetEvent('rps-bossmenu:server:deposit', function(data)
    local src = source
    if not CheckCooldown(src, 'deposit', 1000) then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    local amount = tonumber(data.amount)
    if not amount or amount <= 0 or amount > (Config.MaxDeposit or 10000000) then
        return Bridge.Notify(src, 'Invalid amount.', 'error')
    end
    amount = math.floor(amount)
    local jobName = pData.PlayerData.job.name

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'deposit', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'deposit') then return end
        local freshData = Bridge.GetPlayer(src)
        if not freshData then return end
        if freshData.PlayerData.money.bank >= amount then
            freshData.Functions.RemoveMoney('bank', amount, 'Business Deposit')
            AddSocietyMoney(jobName, amount, 'Deposit')
            SaveSocietyLog(jobName, 'deposit', 'Manual Deposit', freshData.PlayerData.charinfo.firstname, amount)
            RefreshBossMenu(src)
        else
            Bridge.Notify(src, 'Not enough money in bank.', 'error')
        end
    end)
end)

RegisterNetEvent('rps-bossmenu:server:withdraw', function(data)
    local src = source
    if not CheckCooldown(src, 'withdraw', 1000) then return end
    local pData = Bridge.GetPlayer(src)
    if not pData then return end
    local amount = tonumber(data.amount)
    if not amount or amount <= 0 or amount > (Config.MaxWithdraw or 10000000) then
        return Bridge.Notify(src, 'Invalid amount.', 'error')
    end
    amount = math.floor(amount)
    local jobName = pData.PlayerData.job.name

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'withdraw', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'withdraw') then return end
        if RemoveSocietyMoney(jobName, amount, 'Withdrawal') then
            AddPersonalBank(src, amount, 'Business Withdrawal')
            SaveSocietyLog(jobName, 'withdraw', 'Manual Withdrawal', pData.PlayerData.charinfo.firstname, amount)
            RefreshBossMenu(src)
        else
            Bridge.Notify(src, 'Not enough society funds.', 'error')
        end
    end)
end)

-- ============================================
--  Callbacks
-- ============================================
Bridge.RegisterCallback('rps-bossmenu:server:getNearbyPlayers', function(source, cb)
    local src = source
    local srcCoords = GetEntityCoords(GetPlayerPed(src))
    local nearby = {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        if id ~= src then
            local tPed = GetPlayerPed(id)
            if tPed and tPed ~= 0 then
                local tCoords = GetEntityCoords(tPed)
                if #(srcCoords - tCoords) < 5.0 then
                    local tPlayer = GetPlayer(id)
                    if tPlayer then
                        nearby[#nearby+1] = { id = id, src = id, cid = tPlayer.PlayerData.citizenid, name = tPlayer.PlayerData.charinfo.firstname .. ' ' .. tPlayer.PlayerData.charinfo.lastname }
                    end
                end
            end
        end
    end
    cb(nearby)
end)

-- ============================================
--  Job Offers
-- ============================================
RegisterNetEvent('rps-bossmenu:server:sendJobOffer', function(data)
    local src = source
    if not CheckCooldown(src, 'sendJobOffer', 3000) then return end
    local pData = GetPlayer(src)
    if not pData then return end

    local jobName = pData.PlayerData.job.name
    local targetId = tonumber(data.player)
    if not targetId then return end

    local tPlayer = GetPlayer(targetId)
    if not tPlayer then return Bridge.Notify(src, 'Target player not found.', 'error') end

    local jobs = GetJobs()
    if not jobs[jobName] then return end

    local rankExists = false
    local rankLevel = 0
    if jobs[jobName].grades then
        for k, v in pairs(jobs[jobName].grades) do
            if v.name == data.rank then
                rankExists = true
                rankLevel = tonumber(k)
                break
            end
        end
    end
    if not rankExists then
        return Bridge.Notify(src, 'Invalid rank selected.', 'error')
    end

    local wage = math.max(0, math.min(tonumber(data.wage) or 100, Config.MaxWage or 100000))

    ValidateAccess(src, jobName, pData.PlayerData.citizenid, pData.PlayerData.job.isboss, 'hire', function(isOwner, actualBoss, perms)
        if not actualBoss and not isOwner and not HasPerm(perms, 'hire') then
            return Bridge.Notify(src, 'You do not have permission to send job offers.', 'error')
        end

        PendingJobOffers[targetId] = {
            jobId   = jobName,
            rank    = data.rank,
            level   = rankLevel,
            wage    = wage,
            senderSrc = src,
            expires = GetGameTimer() + 60000
        }

        local targetName = tPlayer.PlayerData.charinfo.firstname .. ' ' .. tPlayer.PlayerData.charinfo.lastname
        TriggerClientEvent('rps-bossmenu:client:receiveJobOffer', targetId, {
            targetSrc    = targetId,
            senderSrc    = src,
            senderName   = pData.PlayerData.charinfo.firstname .. ' ' .. pData.PlayerData.charinfo.lastname,
            businessName = pData.PlayerData.job.label,
            jobId        = jobName,
            rank         = data.rank,
            wage         = wage,
            playerName   = targetName
        })
        Bridge.Notify(src, 'Job offer sent.', 'success')
    end)
end)

RegisterNetEvent('rps-bossmenu:server:jobOfferResponse', function(data)
    local src = source
    if not CheckCooldown(src, 'jobOfferResponse', 5000) then return end

    local offer = PendingJobOffers[src]
    if not offer then
        return Bridge.Notify(src, 'No pending job offer found.', 'error')
    end
    if GetGameTimer() > offer.expires then
        PendingJobOffers[src] = nil
        return Bridge.Notify(src, 'Job offer has expired.', 'error')
    end
    PendingJobOffers[src] = nil

    local targetPlayer = GetPlayer(src)
    local senderPlayer = GetPlayer(offer.senderSrc)

    if data.accepted then
        local jobs = GetJobs()
        if not jobs[offer.jobId] then
            return Bridge.Notify(src, 'Job no longer exists.', 'error')
        end

        local newJobData = {
            name    = offer.jobId,
            label   = jobs[offer.jobId].label or offer.jobId,
            payment = offer.wage,
            type    = jobs[offer.jobId].type or 'none',
            isboss  = false,
            grade   = { name = offer.rank, level = offer.level }
        }

        if targetPlayer then
            Bridge.SetPlayerJob(src, newJobData)

            MySQL.Async.execute(
                'INSERT INTO rps_employee_wages (citizenid, job, wage) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE wage = VALUES(wage)',
                {targetPlayer.PlayerData.citizenid, offer.jobId, offer.wage}
            )
            Bridge.SetOfflinePlayerJob(targetPlayer.PlayerData.citizenid, newJobData)
        end

        if senderPlayer then
            local acceptName = targetPlayer and (targetPlayer.PlayerData.charinfo.firstname .. ' accepted the job offer!') or 'Offer accepted!'
            Bridge.Notify(senderPlayer.PlayerData.source, acceptName, 'success')
            RefreshBossMenu(senderPlayer.PlayerData.source)
        end
        Bridge.Notify(src, 'You accepted the job offer!', 'success')
    else
        if senderPlayer then
            Bridge.Notify(senderPlayer.PlayerData.source, 'Job offer declined.', 'error')
        end
        Bridge.Notify(src, 'Job offer declined.', 'error')
    end
end)
