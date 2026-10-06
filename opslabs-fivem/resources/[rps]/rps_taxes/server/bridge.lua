--- rps_lib Bridge Module
--- Thin wrappers around exports.rps_lib so the tax logic runs on whatever
--- framework / phone / bank / notification resource rps_lib detects
--- (ESX, QBCore, QBox, standalone). Requires rps_lib started before this resource.
--- @module bridge

Bridge = {}

local rps = exports.rps_lib

-- ════════════════════════════════════════════════════════════════════════════════════
-- READINESS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Block until rps_lib is started and has finished framework detection
--- @return nil
function Bridge.WaitForLib()
    while GetResourceState('rps_lib') ~= 'started' do
        Wait(100)
    end
    -- rps_lib's own detection threads run right after it starts
    Wait(500)
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- FRAMEWORK / PLAYER
-- ════════════════════════════════════════════════════════════════════════════════════

--- @return string 'esx' | 'qb' | 'qbox' | 'standalone'
function Bridge.GetFrameworkName()
    return rps:GetFrameworkName()
end

--- Get normalized tax-relevant player data
--- @param source number Player server ID
--- @return table|nil { source, name, identifier, job, bank }
function Bridge.GetPlayer(source)
    local data = rps:GetPlayerData(source)
    if not data or not data.identifier then return nil end

    return {
        source = source,
        name = GetPlayerName(source) or data.name,
        identifier = data.identifier,
        job = data.job and data.job.name or 'unemployed',
        bank = (data.money and data.money.bank) or rps:GetMoney(source, 'bank') or 0
    }
end

--- Remove money from a player's bank account
--- @param source number Player server ID
--- @param amount number Amount to remove
--- @return boolean Success
function Bridge.RemoveBankMoney(source, amount)
    local ok, result = pcall(function()
        return rps:RemoveMoney(source, amount, 'bank')
    end)
    if not ok then
        DebugPrint('RemoveMoney failed: ' .. tostring(result))
        return false
    end
    return result == true
end

--- Admin check that works across frameworks (console always allowed)
--- @param source number Player server ID (0 = console)
--- @return boolean
function Bridge.IsAdmin(source)
    if source == 0 then return true end
    return rps:HasPermission(source, 'admin')
end

--- Resolve the owned-vehicles table/column for the detected framework
--- @return table|nil { table, ownerColumn } or nil if unsupported
function Bridge.GetVehicleDatabase()
    local db = Config.VehicleTax.database
    if db.table ~= 'auto' then
        return { table = db.table, ownerColumn = db.ownerColumn }
    end

    local framework = Bridge.GetFrameworkName()
    if framework == 'esx' then
        return { table = 'owned_vehicles', ownerColumn = 'owner' }
    elseif framework == 'qb' or framework == 'qbox' then
        return { table = 'player_vehicles', ownerColumn = 'citizenid' }
    end

    return nil
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- NOTIFICATIONS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Show a notification via rps_lib (codem / ox_lib / framework fallback)
--- @param source number Player server ID
--- @param title string Notification title
--- @param description string Notification description
--- @param type string 'success' | 'error' | 'info'
--- @return nil
function Bridge.Notify(source, title, description, type)
    if not Config.Notifications.enabled or source == 0 then return end

    rps:ShowNotification(source, {
        title = title,
        description = description,
        type = Config.Notifications.types[type] or 'inform',
        position = Config.Notifications.position,
        duration = Config.Notifications.duration
    })
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- PHONE
-- ════════════════════════════════════════════════════════════════════════════════════

--- Resolve the key the active phone integration addresses players by
--- (lb-phone: phone number, qb-phone: citizenid)
--- @param source number Player server ID
--- @param identifier string Framework identifier
--- @return string|nil phoneName, string|nil key
local function GetPhoneKey(source, identifier)
    local phone = rps:GetPhoneName()

    if phone == 'lb_phone' then
        return phone, exports['lb-phone']:GetEquippedPhoneNumber(source)
    elseif phone == 'qb_phone' then
        return phone, identifier
    end

    return nil, nil
end

--- Send a tax notice to the player's phone (mail, with SMS fallback on lb-phone)
--- @param source number Player server ID
--- @param identifier string Framework identifier
--- @param subject string Mail subject
--- @param message string Mail body
--- @return nil
function Bridge.SendPhoneMail(source, identifier, subject, message)
    if not Config.Phone.enabled or not Config.Phone.mail then return end

    CreateThread(function()
        local ok, err = pcall(function()
            local phone, key = GetPhoneKey(source, identifier)
            if not key then return end

            if phone == 'lb_phone' then
                local address = exports['lb-phone']:GetEmailAddress(key)
                if address then
                    exports['lb-phone']:SendMail({
                        to = address,
                        sender = Config.Phone.sender,
                        subject = subject,
                        message = message
                    })
                else
                    rps:SendPhoneMessage(Config.Phone.senderNumber, key, subject .. '\n\n' .. message)
                end
            elseif phone == 'qb_phone' then
                exports['qb-phone']:sendNewMailToOffline(key, {
                    sender = Config.Phone.sender,
                    subject = subject,
                    message = message
                })
            end
        end)

        if ok then
            DebugPrint('Sent phone mail to player ' .. source)
        else
            DebugPrint('Failed to send phone mail: ' .. tostring(err))
        end
    end)
end

--- Push a banking alert to the player's phone banking/wallet app
--- @param source number Player server ID
--- @param identifier string Framework identifier
--- @param amount number Amount taken (positive)
--- @param message string Alert message
--- @return nil
function Bridge.SendPhoneBankingAlert(source, identifier, amount, message)
    if not Config.Phone.enabled or not Config.Phone.bankingAlert then return end

    CreateThread(function()
        local ok, err = pcall(function()
            local _, key = GetPhoneKey(source, identifier)
            if not key then return end
            rps:SendPhoneBankingNotification(key, Config.Phone.bankingAlertTitle, message, -math.abs(amount))
        end)

        if not ok then
            DebugPrint('Failed to send phone banking alert: ' .. tostring(err))
        end
    end)
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- BANKING
-- ════════════════════════════════════════════════════════════════════════════════════

--- Deposit money into a single society/government account.
--- Uses rps_lib's bank integration (qb-banking / Renewed-Banking); on ESX
--- (no rps_lib bank integration) falls back to esx_addonaccount societies.
--- @param account string Account / society name
--- @param amount number Amount to deposit
--- @param reason string|nil Transaction reason
--- @return boolean Success
function Bridge.DepositToAccount(account, amount, reason)
    if amount <= 0 then return false end

    local bank = rps:GetBankName()

    -- 'qbox' bank integration is per-player only, it can't hold a society account
    if bank ~= 'none' and bank ~= 'qbox' then
        local ok, result = pcall(function()
            return rps:AddAccountMoney(account, amount, reason or Config.Banking.reason)
        end)
        if ok and result then
            DebugPrint(string.format('Deposited %s to %s via %s', FormatNumber(amount), account, bank))
            return true
        end
        WarnPrint(string.format('Failed to deposit tax into account "%s" via %s', account, bank))
        return false
    end

    if GetResourceState('esx_addonaccount') == 'started' then
        local society = account:find('^society_') and account or ('society_' .. account)
        local p = promise.new()
        TriggerEvent('esx_addonaccount:getSharedAccount', society, function(shared)
            if shared then
                shared.addMoney(amount)
                p:resolve(true)
            else
                p:resolve(false)
            end
        end)
        local success = Citizen.Await(p)
        if success then
            DebugPrint(string.format('Deposited %s to %s via esx_addonaccount', FormatNumber(amount), society))
        else
            WarnPrint(string.format('Society account "%s" not found in esx_addonaccount', society))
        end
        return success
    end

    WarnPrint('Banking deposit enabled but no supported bank resource was found')
    return false
end

--- Split a cycle's revenue across Config.Banking.accounts by share
--- @param totals table { all = number, bank = number, vehicle = number }
--- @return table Array of { account, amount, success }
function Bridge.DistributeRevenue(totals)
    local results = {}
    if not Config.Banking.enabled then return results end

    for _, entry in ipairs(Config.Banking.accounts) do
        local pool = totals[entry.from or 'all'] or 0
        local amount = Round(pool * (entry.share or 0), 2)

        if amount > 0 then
            results[#results + 1] = {
                account = entry.account,
                amount = amount,
                success = Bridge.DepositToAccount(entry.account, amount, entry.reason)
            }
        end
    end

    return results
end
