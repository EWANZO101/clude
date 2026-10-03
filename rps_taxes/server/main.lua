--- Main Tax System Module
--- Handles the core tax collection logic and player processing
--- @module main

-- ════════════════════════════════════════════════════════════════════════════════════
-- LOCAL VARIABLES
-- ════════════════════════════════════════════════════════════════════════════════════

local taxCollectionActive = false
local _vehicleCountCache = nil

-- ════════════════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Get the number of vehicles owned by a player
--- @param citizenid string Player's framework identifier (citizenid / ESX identifier)
--- @return number Number of vehicles owned
local function GetPlayerVehicleCount(citizenid)
    -- Use cache if available for current cycle to avoid per-player awaits
    if _vehicleCountCache and _vehicleCountCache[citizenid] ~= nil then
        return _vehicleCountCache[citizenid]
    end

    local db = Bridge.GetVehicleDatabase()
    if not db then return 0 end

    -- Fallback to direct query (should be rare if cache is used)
    local t0 = GetGameTimer()
    local result = MySQL.query.await(
        string.format('SELECT COUNT(*) as count FROM %s WHERE %s = ?', db.table, db.ownerColumn),
        {citizenid}
    )
    local dt = GetGameTimer() - t0
    DebugPrint(string.format('Vehicle count DB (no-cache) for %s took %d ms', citizenid, dt))
    
    if result and result[1] then
        return result[1].count or 0
    end
    
    return 0
end

--- Check if a player is exempt from bank tax
--- @param job string Player's job name
--- @return boolean True if exempt
local function IsExemptFromBankTax(job)
    return TableContains(Config.BankTax.exemptJobs, job)
end

--- Check if a player is exempt from vehicle tax
--- @param job string Player's job name
--- @return boolean True if exempt
local function IsExemptFromVehicleTax(job)
    return TableContains(Config.VehicleTax.exemptJobs, job)
end

local SendNotification = Bridge.Notify

--- Calculate bank tax for a player
--- @param bankBalance number Player's current bank balance
--- @return number Tax amount
local function CalculateBankTax(bankBalance)
    if not Config.BankTax.enabled then return 0 end
    if bankBalance < Config.BankTax.minBalance then return 0 end
    
    local taxAmount = CalculatePercentage(Config.BankTax.percentage, bankBalance)
    
    -- Apply max tax limit if configured
    if Config.BankTax.maxTaxAmount > 0 then
        taxAmount = math.min(taxAmount, Config.BankTax.maxTaxAmount)
    end
    
    return Round(taxAmount, 2)
end

--- Calculate vehicle tax for a player
--- @param vehicleCount number Number of vehicles owned
--- @return number Tax amount
local function CalculateVehicleTax(vehicleCount)
    if not Config.VehicleTax.enabled then return 0 end
    if vehicleCount < Config.VehicleTax.minVehicles then return 0 end
    
    local taxAmount = vehicleCount * Config.VehicleTax.perVehicle
    
    -- Apply max tax limit if configured
    if Config.VehicleTax.maxTaxAmount > 0 then
        taxAmount = math.min(taxAmount, Config.VehicleTax.maxTaxAmount)
    end
    
    return Round(taxAmount, 2)
end

--- Process tax collection for a single player
--- @param source number Player server ID
--- @return table Result containing success status and tax information
local function ProcessPlayerTax(source)
    local Player = Bridge.GetPlayer(source)

    if not Player then
        DebugPrint('Player not found: ' .. source)
        return {success = false, reason = 'Player not found'}
    end

    local playerData = {
        source = source,
        name = Player.name,
        citizenid = Player.identifier,
        job = Player.job,
        identifiers = {} -- Skip GetPlayerIdentifiers - it's blocking and not essential
    }
    
    -- Check exemptions
    local bankTaxExempt = IsExemptFromBankTax(playerData.job)
    local vehicleTaxExempt = IsExemptFromVehicleTax(playerData.job)
    
    if bankTaxExempt and vehicleTaxExempt then
        DebugPrint(playerData.name .. ' is exempt from all taxes')
        SendNotification(source, 'Tax Exempt', Config.Messages.taxExempt, 'info')
        LogTaxExempt(playerData, 'Job exemption: ' .. playerData.job)
        return {success = true, exempt = true}
    end
    
    -- Get player's bank balance
    local bankBalance = Player.bank

    -- Get player's vehicle count
    local vehicleCount = GetPlayerVehicleCount(playerData.citizenid)
    
    -- Calculate taxes
    local bankTax = bankTaxExempt and 0 or CalculateBankTax(bankBalance)
    local vehicleTax = vehicleTaxExempt and 0 or CalculateVehicleTax(vehicleCount)
    local totalTax = bankTax + vehicleTax
    
    DebugPrint(string.format('%s | Bank: $%s | Vehicles: %d | Bank Tax: $%s | Vehicle Tax: $%s | Total: $%s',
        playerData.name, FormatNumber(bankBalance), vehicleCount, 
        FormatNumber(bankTax), FormatNumber(vehicleTax), FormatNumber(totalTax)))
    
    -- Skip if no tax to collect
    if totalTax == 0 then
        DebugPrint('No tax to collect from ' .. playerData.name)
        return {success = true, noTax = true}
    end
    
    -- Check if player has enough funds
    if bankBalance < totalTax then
        if not Config.AllowNegativeBalance then
            WarnPrint(playerData.name .. ' has insufficient funds for tax payment')
            
            SendNotification(source, 'Tax Collection Failed', 
                string.format(Config.Messages.taxFailed, FormatCurrency(totalTax)), 
                'error')
            
            Bridge.SendPhoneMail(source, playerData.citizenid, Config.Phone.subjects.taxFailed,
                string.format(Config.Messages.emailTaxFailed, FormatCurrency(totalTax)))
            
            LogTaxFailed(playerData, totalTax, 'Insufficient funds')

            return {success = false, reason = 'Insufficient funds', amountDue = totalTax}
        end
    end
    
    -- Remove money from player (via rps_lib, framework-agnostic)
    local tRemove0 = GetGameTimer()
    local success = Bridge.RemoveBankMoney(source, totalTax)
    local tRemoveDt = GetGameTimer() - tRemove0
    DebugPrint(string.format('RemoveMoney for %s took %d ms (amount %s)', playerData.citizenid, tRemoveDt, FormatNumber(totalTax)))
    
    if not success then
        ErrorPrint('Failed to remove money from ' .. playerData.name)
        LogTaxFailed(playerData, totalTax, 'Money removal failed')
        return {success = false, reason = 'Money removal failed'}
    end
    
    -- Send notifications
    SendNotification(source, 'Tax Collected',
        string.format(Config.Messages.taxCollected, 
            FormatCurrency(totalTax), 
            FormatCurrency(bankTax), 
            FormatCurrency(vehicleTax)),
        'success')
    
    -- Send phone mail
    if Config.Phone.detailedBreakdown then
        Bridge.SendPhoneMail(source, playerData.citizenid, Config.Phone.subjects.taxCollected,
            string.format(Config.Messages.emailTaxCollected,
                FormatCurrency(bankTax),
                FormatCurrency(vehicleTax),
                FormatCurrency(totalTax)))
    end

    -- Phone banking app alert
    Bridge.SendPhoneBankingAlert(source, playerData.citizenid, totalTax,
        string.format('Tax Collection - Bank: %s, Vehicles: %s',
            FormatCurrency(bankTax), FormatCurrency(vehicleTax)))
    
    -- Discord log (queued + throttled, see server/webhook.lua)
    LogTaxCollected(playerData, bankTax, vehicleTax, totalTax)

    return {
        success = true,
        bankTax = bankTax,
        vehicleTax = vehicleTax,
        totalTax = totalTax,
        playerData = playerData
    }
end

--- Run tax collection for all online players
--- @return table Summary of tax collection cycle
local function RunTaxCollection()
    if taxCollectionActive then
        WarnPrint('Tax collection is already running!')
        return
    end
    
    taxCollectionActive = true
    BeginWebhookCycle()
    InfoPrint('Starting tax collection cycle...')
    
    local players = GetOnlinePlayers()
    local summary = {
        totalPlayers = #players,
        successful = 0,
        failed = 0,
        exempt = 0,
        noTax = 0,
        totalCollected = 0,
        bankCollected = 0,
        vehicleCollected = 0
    }
    
    -- Prefetch vehicle counts for all players in one query
    _vehicleCountCache = {}
    local db = Bridge.GetVehicleDatabase()
    if db then
        local ids = {}
        for _, pid in ipairs(players) do
            local identifier = exports.rps_lib:GetIdentifier(pid)
            if identifier then ids[#ids+1] = identifier end
        end
        if #ids > 0 then
            local t0 = GetGameTimer()
            local result = MySQL.query.await(
                string.format('SELECT %s as citizenid, COUNT(*) as count FROM %s WHERE %s IN (?) GROUP BY %s',
                    db.ownerColumn, db.table, db.ownerColumn, db.ownerColumn
                ),
                {ids}
            )
            local dt = GetGameTimer() - t0
            DebugPrint(string.format('Prefetch vehicle counts for %d players took %d ms', #ids, dt))
            if result then
                for _, row in ipairs(result) do
                    _vehicleCountCache[row.citizenid] = row.count or 0
                end
            end
            -- Players with no rows own 0 vehicles; cache that too so they skip the fallback query
            for _, id in ipairs(ids) do
                if _vehicleCountCache[id] == nil then _vehicleCountCache[id] = 0 end
            end
        end
    end

    -- Process players sequentially to avoid race conditions on summary
    for i, playerId in ipairs(players) do
        local result = ProcessPlayerTax(playerId)
        
        if result.success then
            if result.exempt then
                summary.exempt = summary.exempt + 1
            elseif result.noTax then
                summary.noTax = summary.noTax + 1
            else
                summary.successful = summary.successful + 1
                summary.totalCollected = summary.totalCollected + (result.totalTax or 0)
                summary.bankCollected = summary.bankCollected + (result.bankTax or 0)
                summary.vehicleCollected = summary.vehicleCollected + (result.vehicleTax or 0)
            end
        else
            summary.failed = summary.failed + 1
        end
        
        -- Small non-blocking yield every player to prevent svMain stall
        Wait(10)
    end
    
    InfoPrint(string.format('Tax collection complete! Players: %d | Collected: $%s | Failed: %d | Exempt: %d',
        summary.totalPlayers, FormatNumber(summary.totalCollected), summary.failed, summary.exempt))

    -- Split the cycle's revenue across the configured society accounts
    local deposits = Bridge.DistributeRevenue({
        all = summary.totalCollected,
        bank = summary.bankCollected,
        vehicle = summary.vehicleCollected
    })
    summary.deposits = deposits

    -- Log summary to Discord
    LogCollectionSummary(summary.totalPlayers, summary.totalCollected, summary.failed, summary.exempt, deposits)
    
    _vehicleCountCache = nil
    taxCollectionActive = false
    return summary
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- COMMANDS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Admin command to manually trigger tax collection
lib.addCommand('collecttaxes', {
    help = 'Manually trigger tax collection (Admin only)'
}, function(source, args, raw)
    if not Bridge.IsAdmin(source) then
        SendNotification(source, 'Error', 'You do not have permission to use this', 'error')
        return
    end
    local triggeredBy = source == 0 and 'Console' or GetPlayerName(source)
    InfoPrint(triggeredBy .. ' manually triggered tax collection')
    LogManualCollection(triggeredBy)
    CreateThread(function()
        RunTaxCollection()
    end)
end)

--- Admin command to send a test message to the Discord webhook
lib.addCommand('testtaxwebhook', {
    help = 'Send a test message to the tax Discord webhook (Admin only)'
}, function(source, args, raw)
    if not Bridge.IsAdmin(source) then
        SendNotification(source, 'Error', 'You do not have permission to use this', 'error')
        return
    end

    if SendTestWebhook() then
        InfoPrint('Test webhook queued')
        SendNotification(source, 'Webhook', 'Test message sent to Discord', 'success')
    else
        WarnPrint('Webhook is disabled or has no URL configured')
        SendNotification(source, 'Webhook', 'Webhook is disabled or has no URL configured', 'error')
    end
end)

--- Admin command to check player tax information
lib.addCommand('checktax', {
    help = 'Check tax information for a player (Admin only)',
    params = {
        {name = 'id', type = 'playerId', help = 'Player ID'}
    }
}, function(source, args, raw)
    if not Bridge.IsAdmin(source) then
        SendNotification(source, 'Error', 'You do not have permission to use this', 'error')
        return
    end

    local targetId = args.id
    local Player = Bridge.GetPlayer(targetId)

    if not Player then
        SendNotification(source, 'Error', 'Player not found', 'error')
        return
    end

    local bankBalance = Player.bank
    local vehicleCount = GetPlayerVehicleCount(Player.identifier)
    local bankTax = CalculateBankTax(bankBalance)
    local vehicleTax = CalculateVehicleTax(vehicleCount)
    local totalTax = bankTax + vehicleTax
    
    local message = string.format(
        'Player: %s\nBank: %s\nVehicles: %d\n\nBank Tax: %s\nVehicle Tax: %s\nTotal Tax: %s',
        GetPlayerName(targetId),
        FormatCurrency(bankBalance),
        vehicleCount,
        FormatCurrency(bankTax),
        FormatCurrency(vehicleTax),
        FormatCurrency(totalTax)
    )
    
    print('^3[Tax Check]^7\n' .. message)
    SendNotification(source, 'Tax Information', 'Check console for details', 'info')
end)

-- ════════════════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ════════════════════════════════════════════════════════════════════════════════════

CreateThread(function()
    Bridge.WaitForLib()

    -- Validate configuration
    local valid, error = ValidateConfig()
    if not valid then
        ErrorPrint('Configuration validation failed: ' .. error)
        LogSystemError('Configuration validation failed', error)
        return
    end
    
    InfoPrint('Configuration validated successfully')
    
    if not Config.Enabled then
        WarnPrint('Tax system is disabled in configuration')
        return
    end
    
    InfoPrint('Tax system initialized')
    InfoPrint(string.format('rps_lib | Framework: %s | Phone: %s | Bank: %s | Notify: %s',
        Bridge.GetFrameworkName(), exports.rps_lib:GetPhoneName(),
        exports.rps_lib:GetBankName(), exports.rps_lib:GetNotificationModuleName()))
    if Config.VehicleTax.enabled and not Bridge.GetVehicleDatabase() then
        WarnPrint('No vehicle table for this framework - vehicle tax will be 0. Set Config.VehicleTax.database manually.')
    end
    InfoPrint('Bank Tax: ' .. (Config.BankTax.enabled and 'Enabled (' .. (Config.BankTax.percentage * 100) .. '%)' or 'Disabled'))
    InfoPrint('Vehicle Tax: ' .. (Config.VehicleTax.enabled and 'Enabled ($' .. Config.VehicleTax.perVehicle .. ' per vehicle)' or 'Disabled'))
    InfoPrint('Collection Interval: ' .. Config.TaxInterval .. ' minutes')
    
    -- Log system start to Discord
    LogSystemStart(Config.TaxInterval)
    
    -- Initial collection if enabled
    if Config.CollectOnStart then
        InfoPrint('Waiting ' .. Config.StartDelay .. ' minutes before first collection...')
        Wait(MinutesToMs(Config.StartDelay))
        CreateThread(function()
            RunTaxCollection()
        end)
    end
    
    -- Set up recurring tax collection
    while Config.Enabled do
        Wait(MinutesToMs(Config.TaxInterval))
        CreateThread(function()
            RunTaxCollection()
        end)
    end
end)

-- ════════════════════════════════════════════════════════════════════════════════════
-- EXPORTS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Export: Manually collect taxes from all players
--- @return table Summary of collection
exports('CollectTaxes', RunTaxCollection)

--- Export: Process tax for a specific player
--- @param source number Player server ID
--- @return table Tax processing result
exports('ProcessPlayerTax', ProcessPlayerTax)

--- Export: Get player vehicle count
--- @param citizenid string Player's citizen ID
--- @return number Vehicle count
exports('GetPlayerVehicleCount', GetPlayerVehicleCount)

--- Export: Calculate tax for a player without collecting
--- @param source number Player server ID
--- @return table Tax calculation result
exports('CalculatePlayerTax', function(source)
    local Player = Bridge.GetPlayer(source)
    if not Player then return nil end

    local bankBalance = Player.bank
    local vehicleCount = GetPlayerVehicleCount(Player.identifier)
    
    return {
        bankTax = CalculateBankTax(bankBalance),
        vehicleTax = CalculateVehicleTax(vehicleCount),
        bankBalance = bankBalance,
        vehicleCount = vehicleCount
    }
end)

InfoPrint('^2Tax System Loaded Successfully!^7')
