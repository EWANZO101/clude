-- ============================================
--  rps_lib Bridge (server)
--  Every Bridge function here is a thin wrapper around exports.rps_lib.
--  Requires the standalone rps_lib resource started before this one.
-- ============================================
Bridge = {}

local DEFAULT_JOB = { name = 'unemployed', label = 'Unemployed', grade = { level = 0, name = 'Freelancer' }, isboss = false }

-- ============================================
--  Player Functions
-- ============================================
function Bridge.GetPlayer(src)
    local px = exports.rps_lib:GetPlayerData(src)
    if not px then return nil end
    local job = px.job or DEFAULT_JOB

    return {
        PlayerData = {
            source = px.source or src,
            citizenid = px.identifier,
            charinfo = {
                firstname = px.firstname or 'Unknown',
                lastname = px.lastname or ''
            },
            job = {
                name = job.name,
                label = job.label,
                grade = {
                    level = job.grade and job.grade.level or 0,
                    name = job.grade and job.grade.name or ''
                },
                isboss = job.isboss == true
            },
            money = {
                cash = px.money and px.money.cash or 0,
                bank = px.money and px.money.bank or 0
            }
        },
        Functions = {
            AddItem = function(item, amount, slot, info)
                -- Weapons need special metadata (serial/ammo/durability) to
                -- register on most inventories — see BuildItemMetadata in
                -- server/main.lua. Falls back to it only when the caller
                -- didn't already supply its own info/metadata.
                return exports.rps_lib:AddItem(src, item, amount, info or BuildItemMetadata(item))
            end,
            RemoveItem = function(item, amount, slot)
                return exports.rps_lib:RemoveItem(src, item, amount)
            end,
            AddMoney = function(moneyType, amount, reason)
                return exports.rps_lib:AddMoney(src, amount, moneyType)
            end,
            RemoveMoney = function(moneyType, amount, reason)
                return exports.rps_lib:RemoveMoney(src, amount, moneyType)
            end,
            -- Plain name+grade assignment only — no custom wage/isboss/rank
            -- overlay. Use Bridge.SetPlayerJob for the full custom job write
            -- (hire/promote/fire flows).
            SetJob = function(jobName, grade)
                return exports.rps_lib:SetJob(src, jobName, grade)
            end
        }
    }
end

--- Online-only lookup (matches ESX.GetPlayerFromIdentifier/QBCore.Functions.GetPlayerByCitizenId
--- behavior — rps_lib has no reverse citizenid->source export, so this scans
--- connected players).
function Bridge.GetPlayerByCitizenId(cid)
    if not cid then return nil end
    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        if src and exports.rps_lib:GetIdentifier(src) == cid then
            return Bridge.GetPlayer(src)
        end
    end
    return nil
end

function Bridge.GetJobs()
    return exports.rps_lib:GetJobs() or {}
end

--- Full custom job write (name, label, payment, type, isboss, grade = { name,
--- level }) for hire/promote/fire flows. See rps_lib's SetPlayerJob for the
--- per-framework caveats (ESX only applies name/grade.level).
function Bridge.SetPlayerJob(src, jobData)
    return exports.rps_lib:SetPlayerJob(src, jobData)
end

--- Offline-capable lookup (works for online or offline players, unlike
--- Bridge.GetPlayer/GetPlayerByCitizenId) — queries the database directly.
--- cb(character | nil) — character = { identifier, name, firstname, lastname, job }
function Bridge.GetOfflinePlayer(identifier, cb)
    exports.rps_lib:GetOfflinePlayer(identifier, cb)
end

--- cb(characters) — every player (online or offline) currently in jobName.
function Bridge.GetEmployeesByJob(jobName, cb)
    exports.rps_lib:GetEmployeesByJob(jobName, cb)
end

--- cb(characters) — the full character roster.
function Bridge.GetAllCharacters(cb)
    exports.rps_lib:GetAllCharacters(cb)
end

--- Writes a job assignment to an offline player. cb(success) is optional.
function Bridge.SetOfflinePlayerJob(identifier, jobData, cb)
    exports.rps_lib:SetOfflinePlayerJob(identifier, jobData, cb)
end

--- Adds money to an offline player's account. cb(success) is optional.
function Bridge.AddOfflinePlayerMoney(identifier, amount, account, cb)
    exports.rps_lib:AddOfflinePlayerMoney(identifier, amount, account, cb)
end

-- ============================================
--  Item Functions
-- ============================================
function Bridge.GetItemData(itemName)
    local def = exports.rps_lib:GetItemDefinition(itemName)
    return def or { name = itemName, label = itemName }
end

function Bridge.GetItems()
    return exports.rps_lib:GetItemCatalog() or {}
end

-- ============================================
--  Notification Functions
-- ============================================
function Bridge.Notify(src, msg, type)
    local rpsType = type
    if rpsType == 'primary' or rpsType == 'inform' then rpsType = 'info' end
    exports.rps_lib:Notify(src, msg, rpsType or 'info')
end

function Bridge.NotifyItem(src, itemData, action)
    -- ox_inventory shows its own popup on item changes already.
    if exports.rps_lib:GetInventoryName() == 'ox_inventory' then return end
    TriggerClientEvent('inventory:client:ItemBox', src, itemData, action)
end

-- ============================================
--  Callback System
-- ============================================
function Bridge.RegisterCallback(name, cb)
    -- rps_lib's RegisterServerCallback expects handler(source, ...) to return
    -- its result synchronously, but this bridge's callbacks are written
    -- async-style (cb(source, respond, ...)), often resolving inside a
    -- MySQL.Async callback — so park it in a promise and await it.
    exports.rps_lib:RegisterServerCallback(name, function(source, ...)
        local p = promise.new()
        cb(source, function(result)
            p:resolve(result)
        end, ...)
        return Citizen.Await(p)
    end)
end

-- ============================================
--  Permissions & Useable Items
-- ============================================
function Bridge.HasPermission(src, perm)
    return exports.rps_lib:HasPermission(src, perm) == true
end

function Bridge.CreateUseableItem(item, cb)
    exports.rps_lib:CreateUseableItem(item, cb)
end
