-- Framework access for the OPS Network resources, through rps_lib (ESX / QBCore / QBox / standalone).
-- Everything that needs a player's identifier, name, job, admin rights, money or items goes through FW, so the
-- resource doesn't care which framework the server runs. If rps_lib isn't running it falls back to ESX directly.
-- (The same file lives in opslabs-towers/server/framework.lua — keep them in step.)

FW = {}

local function rps() return GetResourceState('rps_lib') == 'started' and exports.rps_lib or nil end

local ESXObj
local function esx()
    if not ESXObj and GetResourceState('es_extended') == 'started' then ESXObj = exports['es_extended']:getSharedObject() end
    return ESXObj
end

--- { identifier, name, firstname, lastname, job = { name, label, grade = { level, name } } } or nil
function FW.Player(src)
    src = tonumber(src)
    if not src then return nil end
    local L = rps()
    if L then
        local ok, p = pcall(L.GetPlayerData, L, src)
        if ok then return p end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    if not x then return nil end
    return { identifier = x.identifier, name = x.getName and x.getName() or GetPlayerName(src),
        firstname = x.get and x.get('firstName') or nil, lastname = x.get and x.get('lastName') or nil,
        job = x.job and { name = x.job.name, label = x.job.label, grade = { level = x.job.grade, name = x.job.grade_label } } }
end

function FW.Identifier(src)
    local p = FW.Player(src)
    return p and p.identifier or nil
end

function FW.Name(src)
    local p = FW.Player(src)
    return p and p.name or GetPlayerName(src)
end

function FW.Job(src)
    local p = FW.Player(src)
    return p and p.job and p.job.name or nil
end

function FW.JobLabel(src)
    local p = FW.Player(src)
    return p and p.job and p.job.label or nil
end

--- online player with this identifier, or nil
function FW.SourceOf(identifier)
    if not identifier then return nil end
    for _, id in ipairs(GetPlayers()) do
        local s = tonumber(id)
        if FW.Identifier(s) == identifier then return s end
    end
    return nil
end

--- framework admin: rps_lib's HasPermission (QB / QBox permissions, ESX admin / superadmin), or an ESX group in `groups`
function FW.IsAdmin(src, groups)
    local L = rps()
    if L then
        local ok, yes = pcall(L.HasPermission, L, src, 'admin')
        if ok and yes then return true end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    local g = x and x.getGroup and x.getGroup()
    for _, want in ipairs(groups or {}) do if g == want then return true end end
    return false
end

-- money: account 'bank' or 'cash' (ESX calls cash 'money')
local function esxAccount(account) return account == 'cash' and 'money' or account end

function FW.GetMoney(src, account)
    account = account or 'bank'
    local L = rps()
    if L then
        local ok, n = pcall(L.GetMoney, L, src, account)
        if ok and n then return n end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    local a = x and x.getAccount(esxAccount(account))
    return a and a.money or 0
end

function FW.AddMoney(src, amount, account, reason)
    account = account or 'bank'
    if (amount or 0) <= 0 then return false end
    local L = rps()
    if L then
        local ok, done = pcall(L.AddMoney, L, src, amount, account)
        if ok then return done ~= false end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    if not x then return false end
    x.addAccountMoney(esxAccount(account), amount, reason)
    return true
end

--- takes money only if they have enough; returns true when taken
function FW.RemoveMoney(src, amount, account, reason)
    account = account or 'bank'
    if (amount or 0) <= 0 then return false end
    if FW.GetMoney(src, account) < amount then return false end
    local L = rps()
    if L then
        local ok, done = pcall(L.RemoveMoney, L, src, amount, account)
        if ok then return done ~= false end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    if not x then return false end
    x.removeAccountMoney(esxAccount(account), amount, reason)
    return true
end

--- item count. rps_lib's inventory integrations cover ox / qb / ps / lj / tgiann; ESX's own inventory isn't one of
--- them, so when rps_lib reports 'none' the ESX inventory is read directly
function FW.ItemCount(src, item)
    local L = rps()
    if L then
        local okName, name = pcall(L.GetInventoryName, L)
        if okName and name and name ~= 'none' then
            local ok, n = pcall(L.GetItemCount, L, src, item)
            if ok then return tonumber(n) or 0 end
        end
    end
    local x = esx() and esx().GetPlayerFromId(src)
    local inv = x and x.getInventoryItem and x.getInventoryItem(item)
    return inv and (inv.count or inv.amount or 0) or 0
end

--- run handler(src) when a player uses this item
function FW.UsableItem(item, handler)
    local L = rps()
    if L and pcall(L.CreateUseableItem, L, item, function(src) handler(src) end) then return end
    if esx() then esx().RegisterUsableItem(item, function(src) handler(src) end) end
end
