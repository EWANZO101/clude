-- ============================================
--  rps_lib Bridge (server)
--  Framework (ESX / QBCore / QBox / standalone) and notifications are
--  handled by rps_lib. Requires rps_lib started before this resource.
--  Force a framework with: setr rps_lib:forceFramework "esx"
-- ============================================
Bridge = {}

local rps = exports.rps_lib

CreateThread(function()
    Wait(500) -- rps_lib detects the framework asynchronously on start
    print(('[rps_parking] Framework: %s (via rps_lib)'):format(rps:GetFrameworkName()))
end)

function Bridge.GetIdentifier(src)
    return rps:GetIdentifier(src)
end

function Bridge.GetJob(src)
    if rps:GetFrameworkName() == 'standalone' then
        -- standalone: use ACE permission 'rps_parking.police'
        return IsPlayerAceAllowed(src, 'rps_parking.police') and 'police' or nil
    end
    local p = rps:GetPlayerData(src)
    return p and p.job and p.job.name
end

function Bridge.IsVehicleOwner(src, plate)
    local fw = rps:GetFrameworkName()
    if not Config.RequireOwnership or fw == 'standalone' then return true end
    local id = Bridge.GetIdentifier(src)
    if not id then return false end

    local owner
    if fw == 'qb' or fw == 'qbox' then
        owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE TRIM(plate) = ? LIMIT 1', { plate })
    else
        owner = MySQL.scalar.await('SELECT owner FROM owned_vehicles WHERE TRIM(plate) = ? LIMIT 1', { plate })
    end
    return owner == id
end

--- Charges bank first, then cash. Standalone has no economy, so it's free.
function Bridge.RemoveMoney(src, amount, reason)
    if amount <= 0 then return true end
    local bank = rps:GetMoney(src, 'bank')
    if bank == nil then return true end -- standalone: no economy
    if bank >= amount then
        return rps:RemoveMoney(src, amount, 'bank') ~= false
    end
    if (rps:GetMoney(src, 'cash') or 0) >= amount then
        return rps:RemoveMoney(src, amount, 'cash') ~= false
    end
    return false
end

function Bridge.FindPlayer(identifier)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if Bridge.GetIdentifier(src) == identifier then return src end
    end
end

function Bridge.GetName(src)
    local p = rps:GetPlayerData(src)
    if p then
        if p.firstname then return ('%s %s'):format(p.firstname, p.lastname or '') end
        if p.name then return p.name end
    end
    return GetPlayerName(src) or ('ID %s'):format(src)
end

function Bridge.IsAdmin(src)
    if IsPlayerAceAllowed(src, Config.Admin.ace) then return true end
    if not Config.Admin.frameworkAdmin then return false end
    return rps:HasPermission(src, 'admin') == true or rps:HasPermission(src, 'god') == true
end

--- type: 'success' | 'error' | 'inform'/'info'
function Bridge.Notify(src, msg, type, title)
    if type == 'inform' or not type then type = 'info' end
    rps:ShowNotification(src, { title = title or 'Parking', description = msg, type = type })
end
