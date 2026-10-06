--- Utility Functions Module
--- Contains helper functions for the tax system
--- @module utils

--- Format a number with thousand separators
--- @param number number The number to format
--- @return string Formatted number string
function FormatNumber(number)
    if not number then return '0' end
    local formatted = tostring(math.floor(number))
    local k
    while true do
        formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

--- Format currency with currency symbol and separators
--- @param amount number The amount to format
--- @return string Formatted currency string
function FormatCurrency(amount)
    return Config.CurrencySymbol .. FormatNumber(amount)
end

--- Round a number to specified decimal places
--- @param number number The number to round
--- @param decimals number Number of decimal places
--- @return number Rounded number
function Round(number, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(number * mult + 0.5) / mult
end

--- Check if a table contains a value
--- @param table table The table to search
--- @param value any The value to find
--- @return boolean True if value exists in table
function TableContains(table, value)
    for _, v in pairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

--- Get player identifiers
--- (named so it doesn't shadow the GetPlayerIdentifiers native)
--- @param source number Player server ID
--- @return table Table of identifiers
function GetPlayerIdentifierTable(source)
    return {
        steam = GetPlayerIdentifierByType(source, 'steam') or '',
        license = GetPlayerIdentifierByType(source, 'license') or '',
        discord = GetPlayerIdentifierByType(source, 'discord') or '',
        ip = GetPlayerIdentifierByType(source, 'ip') or ''
    }
end

--- Print debug message if debug mode is enabled
--- @param message string The message to print
--- @param ... any Additional arguments to print
--- @return nil
function DebugPrint(message, ...)
    if Config.Debug then
        print('^3[Rps Taxes - Debug]^7 ' .. message, ...)
    end
end

--- Print info message
--- @param message string The message to print
--- @return nil
function InfoPrint(message)
    print('^2[Rps Taxes]^7 ' .. message)
end

--- Print error message
--- @param message string The message to print
--- @return nil
function ErrorPrint(message)
    print('^1[Rps Taxes - Error]^7 ' .. message)
end

--- Print warning message
--- @param message string The message to print
--- @return nil
function WarnPrint(message)
    print('^3[Rps Taxes - Warning]^7 ' .. message)
end

--- Calculate percentage of a number
--- @param percentage number The percentage (0.01 = 1%)
--- @param amount number The amount to calculate from
--- @return number The calculated percentage amount
function CalculatePercentage(percentage, amount)
    return Round(amount * percentage, 2)
end

--- Clamp a number between min and max values
--- @param value number The value to clamp
--- @param min number Minimum value
--- @param max number Maximum value
--- @return number Clamped value
function Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Convert minutes to milliseconds
--- @param minutes number Minutes to convert
--- @return number Milliseconds
function MinutesToMs(minutes)
    return minutes * 60 * 1000
end

--- Get current timestamp in readable format
--- @return string Formatted timestamp
function GetTimestamp()
    return os.date('%Y-%m-%d %H:%M:%S')
end

--- Deep copy a table
--- @param original table The table to copy
--- @return table The copied table
function DeepCopy(original)
    local copy
    if type(original) == 'table' then
        copy = {}
        for k, v in next, original, nil do
            copy[DeepCopy(k)] = DeepCopy(v)
        end
        setmetatable(copy, DeepCopy(getmetatable(original)))
    else
        copy = original
    end
    return copy
end

--- Check if a player is online
--- @param source number Player server ID
--- @return boolean True if player is online
function IsPlayerOnline(source)
    return GetPlayerName(source) ~= nil
end

--- Get all online players
--- @return table Array of player sources
function GetOnlinePlayers()
    local players = {}
    for _, playerId in ipairs(GetPlayers()) do
        table.insert(players, tonumber(playerId))
    end
    return players
end

--- Validate configuration on resource start
--- @return boolean, string True if valid, false and error message if invalid
function ValidateConfig()
    -- Check if tax system is properly configured
    if not Config.BankTax.enabled and not Config.VehicleTax.enabled then
        return false, 'Both bank tax and vehicle tax are disabled. Enable at least one.'
    end
    
    -- Validate percentages
    if Config.BankTax.enabled and (Config.BankTax.percentage < 0 or Config.BankTax.percentage > 1) then
        return false, 'Bank tax percentage must be between 0 and 1 (0% to 100%)'
    end
    
    -- Validate vehicle tax
    if Config.VehicleTax.enabled and Config.VehicleTax.perVehicle < 0 then
        return false, 'Vehicle tax per vehicle cannot be negative'
    end
    
    -- Validate tax interval
    if Config.TaxInterval < 1 then
        return false, 'Tax interval must be at least 1 minute'
    end
    
    -- Validate banking account shares
    if Config.Banking.enabled then
        if type(Config.Banking.accounts) ~= 'table' or #Config.Banking.accounts == 0 then
            return false, 'Banking is enabled but Config.Banking.accounts is empty'
        end

        local totals = { all = 0, bank = 0, vehicle = 0 }
        for i, entry in ipairs(Config.Banking.accounts) do
            local from = entry.from or 'all'
            if IsStringEmpty(entry.account) then
                return false, string.format('Config.Banking.accounts[%d] has no account name', i)
            end
            if totals[from] == nil then
                return false, string.format('Config.Banking.accounts[%d] has invalid from "%s" (use all, bank or vehicle)', i, tostring(from))
            end
            if type(entry.share) ~= 'number' or entry.share < 0 then
                return false, string.format('Config.Banking.accounts[%d] (%s) needs a share of 0 or more', i, entry.account)
            end
            totals[from] = totals[from] + entry.share
        end

        for from, total in pairs(totals) do
            if total > 1.0001 then
                return false, string.format('Banking shares for "%s" add up to %d%% (max 100%%)', from, math.floor(total * 100 + 0.5))
            end
        end
    end

    -- Validate webhook URL if enabled
    if Config.Webhook.enabled and (not Webhooks or IsStringEmpty(Webhooks.default)) then
        WarnPrint('Webhook is enabled but no default URL is set in server/webhooks.lua (events without their own URL will not be logged)')
    end
    
    return true, 'Configuration is valid'
end

--- Get a random element from a table
--- @param table table The table to get from
--- @return any Random element
function GetRandomFromTable(table)
    return table[math.random(#table)]
end

--- Check if a string is empty or nil
--- @param str string|nil The string to check
--- @return boolean True if empty or nil
function IsStringEmpty(str)
    return not str or str == ''
end
