-- Phone battery: drains with use, charges only on a live charger (opslabs-towers: charging cable, wireless pad,
-- USB socket) or a power bank. At 0 % the phone switches off until it's charged. The level is reported to the
-- server (kept with the phone settings) and pushed to the UI's status bar.

local CB = Config.Battery or {}
BatteryLevel = 100.0
BatteryCharging = nil       -- 'wired' | 'wireless' | 'powerbank' | nil
local loaded = false
local bank = 0.0            -- % still to come from a power bank
local warned = {}
local lastReport, lastSent = 0, -1

local function push()
    SendNUIMessage({ action = 'battery', data = { level = math.floor(BatteryLevel + 0.5), charging = BatteryCharging } })
end

local function report(force)
    local now = GetGameTimer()
    local lvl = math.floor(BatteryLevel * 10 + 0.5) / 10
    if force or (now - lastReport > 30000 and lvl ~= lastSent) then
        lastReport, lastSent = now, lvl
        TriggerServerEvent('opslabs-phone:battery', lvl, BatteryCharging ~= nil)
    end
end

--- the saved level arrives with the phone data (main.lua Preload)
function BatteryLoad(level)
    BatteryLevel = tonumber(level) or 100.0
    loaded = true
    warned = {}
    for _, w in ipairs(CB.Warnings or {}) do if BatteryLevel <= w then warned[w] = true end end
    push()
end

function PhoneIsDead() return CB.Enabled ~= false and loaded and BatteryLevel <= 0 end

--- a live charger beside the player (what a power bank / OPS Buds case charges from)
function TowersChargerNear()
    if GetResourceState('opslabs-towers') ~= 'started' then return nil end
    local ok, kind = pcall(function() return exports['opslabs-towers']:ChargerNear() end)
    return ok and kind or nil
end

local function chargerNear()
    -- docked on a wireless charger (client/dock.lua): it charges there, wherever you are
    if MyDock and MyDock() then return DockCharging() end
    return TowersChargerNear()
end

local function hasPhone()
    if not Config.RequireItem then return true end
    return HasPhoneCached == nil or HasPhoneCached()
end

CreateThread(function()
    if CB.Enabled == false then return end
    local step = 5
    while true do
        Wait(step * 1000)
        if loaded and hasPhone() then
            local before = BatteryLevel
            local charger = chargerNear()
            local rate
            if bank > 0 then
                local add = math.min(bank, (CB.PowerBank or 4.0) * step / 60)
                bank = bank - add
                BatteryCharging = 'powerbank'
                rate = add
            elseif charger then
                BatteryCharging = charger
                rate = (charger == 'wireless' and (CB.Wireless or 2.2) or (CB.Wired or 3.5)) * step / 60
            else
                BatteryCharging = nil
                local drain = InCall and (CB.InCall or 1.0) or PhoneOpen and (CB.ScreenOn or 0.7) or (CB.Standby or 0.2)
                rate = -drain * step / 60
            end
            BatteryLevel = math.max(0.0, math.min(100.0, BatteryLevel + rate))
            if BatteryLevel >= 100.0 and BatteryCharging and BatteryCharging ~= 'powerbank' then BatteryCharging = 'full' end
            -- low battery warnings, and the phone dying
            if rate < 0 then
                for _, w in ipairs(CB.Warnings or {}) do
                    if before > w and BatteryLevel <= w and not warned[w] then
                        warned[w] = true
                        SendNUIMessage({ action = 'notify', data = { app = 'settings', title = 'Low Battery', body = ('%d%% battery remaining'):format(w) } })
                    end
                end
            else
                for w in pairs(warned) do if BatteryLevel > w + 2 then warned[w] = nil end end
            end
            if before > 0 and BatteryLevel <= 0 then
                if PhoneOpen then ClosePhone() end
                lib.notify({ type = 'error', title = 'Phone', description = 'Your phone battery died. Charge it at a charger or with a power bank.' })
                report(true)
            elseif before <= 0 and BatteryLevel > 0 then
                lib.notify({ type = 'success', title = 'Phone', description = 'Your phone is turning back on' })
                report(true)
            end
            if math.floor(before) ~= math.floor(BatteryLevel) or (BatteryCharging ~= nil) ~= (rate > 0) then push() end
            report(false)
        end
    end
end)

-- a status push when charging starts / stops feels instant
CreateThread(function()
    if CB.Enabled == false then return end
    local last
    while true do
        Wait(1500)
        if loaded and hasPhone() and bank <= 0 then
            local c = chargerNear()
            local state = c and (BatteryLevel >= 100 and 'full' or c) or nil
            if state ~= last then
                last = state
                BatteryCharging = state
                push()
                if c and state ~= 'full' then lib.notify({ type = 'inform', description = c == 'wireless' and 'Charging wirelessly' or 'Charging' }) end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- power banks (items, server/battery.lua)
---------------------------------------------------------------------------

RegisterNetEvent('opslabs-phone:powerbank', function(amount)
    bank = bank + (tonumber(amount) or 50)
    lib.notify({ type = 'success', description = 'Power bank connected — charging your phone' })
end)

RegisterNetEvent('opslabs-phone:powerbankRecharge', function(seconds)
    if not TowersChargerNear() then
        lib.notify({ type = 'error', description = 'Stand beside a live charger (charging cable, wireless pad or USB socket) to recharge the power bank' })
        TriggerServerEvent('opslabs-phone:powerbankCharged', false)
        return
    end
    local ok = lib.progressBar({ duration = (tonumber(seconds) or 60) * 1000, label = 'Recharging the power bank', useWhileDead = false, canCancel = true,
        disable = { move = true, combat = true } })
    ok = ok and TowersChargerNear() ~= nil
    TriggerServerEvent('opslabs-phone:powerbankCharged', ok)
    lib.notify({ type = ok and 'success' or 'error', description = ok and 'Power bank charged' or 'Recharge stopped' })
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and loaded then report(true) end
end)
