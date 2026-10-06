-- Uses the 'rps_lib' resource (exports.rps_lib) for player data, money, and
-- ambulance-job dead/revive detection, so this resource works unmodified on
-- ESX, QBCore, QBox, or standalone (see [standalone]/rps_lib/INTEGRATION_GUIDE.md).
--
-- The one piece rps_lib doesn't abstract is paying a job/society account (that
-- varies too much between frameworks), so the ambulance payout below is
-- still framework-specific, gated on GetFrameworkName().

local pendingRequest = {}
local lastRequest = {}

local function PayAmbulanceSociety(amount)
    if exports.rps_lib:GetFrameworkName() == 'esx' then
        TriggerEvent('esx_addonaccount:getSharedAccount', 'society_ambulance', function(account)
            if account then account.addMoney(amount) end
        end)
    end
    -- Add a QBCore/QBox job-account payout here if this server ever runs those frameworks.
end

local function RefundAmbulanceSociety(amount)
    if exports.rps_lib:GetFrameworkName() == 'esx' then
        TriggerEvent('esx_addonaccount:getSharedAccount', 'society_ambulance', function(account)
            if account then account.removeMoney(amount) end
        end)
    end
end

local function CountOnlineEMS()
    local count = 0
    for _, playerId in ipairs(GetPlayers()) do
        local pdata = exports.rps_lib:GetPlayerData(tonumber(playerId))
        if pdata and pdata.job and pdata.job.name == Config.AmbulanceJobName then
            count = count + 1
        end
    end
    return count
end

AddEventHandler('playerDropped', function()
    pendingRequest[source] = nil
    lastRequest[source] = nil
end)

exports.rps_lib:RegisterServerCallback('aimedic:request', function(source)
    local pdata = exports.rps_lib:GetPlayerData(source)
    if not pdata then
        return false, 'genericError'
    end

    if not exports.rps_lib:IsPlayerDead(source) then
        return false, 'notDowned'
    end

    if pendingRequest[source] then
        return false, 'alreadyRequested'
    end

    local now = os.time()
    if lastRequest[source] and (now - lastRequest[source]) * 1000 < Config.Cooldown then
        local remaining = math.ceil((Config.Cooldown - (now - lastRequest[source]) * 1000) / 1000)
        return false, 'onCooldown', remaining
    end

    local doctorCount = CountOnlineEMS()
    if doctorCount > Config.Doctor then
        return false, 'tooManyEMS', doctorCount
    end

    if (exports.rps_lib:GetMoney(source, Config.PaymentMethod) or 0) < Config.Price then
        return false, 'notEnoughMoney'
    end

    -- Charge atomically before telling the client to proceed, so there is no
    -- window where the medic spawns without the player having actually paid.
    exports.rps_lib:RemoveMoney(source, Config.Price, Config.PaymentMethod)
    PayAmbulanceSociety(Config.Price)

    lastRequest[source] = now
    pendingRequest[source] = true

    -- The client now recovers a stuck medic by teleporting the player to it
    -- at Config.MedicTimeout and running the full revive from there, so this
    -- safety net has to wait out the pathing window AND the revive itself
    -- (plus a buffer) before assuming it truly never happened.
    SetTimeout(Config.MedicTimeout + Config.ReviveTime + 10000, function()
        -- If the request never completed and they're still (per the real
        -- ambulance-job state) downed, the medic never made it: refund.
        if pendingRequest[source] and exports.rps_lib:IsPlayerDead(source) then
            pendingRequest[source] = nil
            exports.rps_lib:AddMoney(source, Config.Price, Config.PaymentMethod)
            RefundAmbulanceSociety(Config.Price)
            TriggerClientEvent('aimedic:notify', source, Config.Messages.medicTimedOut, "error")
        end
    end)

    return true
end)

RegisterServerEvent('aimedic:treatmentComplete')
AddEventHandler('aimedic:treatmentComplete', function()
    pendingRequest[source] = nil
end)
