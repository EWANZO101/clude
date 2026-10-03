--[[
    framework/qbox/server.lua
    QBox (qbx_core) server-side implementation of the lib.framework.impl interface.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.qbox = lib.frameworks.qbox or {}

local impl = lib.frameworks.qbox

function impl.GetPlayerData(source)
    local px = exports['qbx_core']:GetPlayer(source)
    if not px then return nil end
    return {
        source = source,
        identifier = px.PlayerData.citizenid,
        name = ('%s %s'):format(px.PlayerData.charinfo.firstname, px.PlayerData.charinfo.lastname),
        firstname = px.PlayerData.charinfo.firstname,
        lastname = px.PlayerData.charinfo.lastname,
        job = px.PlayerData.job and {
            name = px.PlayerData.job.name,
            label = px.PlayerData.job.label,
            grade = { level = px.PlayerData.job.grade.level, name = px.PlayerData.job.grade.name },
            isboss = px.PlayerData.job.isboss
        },
        money = px.PlayerData.money
    }
end

--- Same shape/behavior as the QBCore SetPlayerJob above — Qbox's Functions.SetJob
--- and SetPlayerData exports mirror QBCore's here.
function impl.SetPlayerJob(source, jobData)
    local px = exports['qbx_core']:GetPlayer(source)
    if not px or not jobData or not jobData.name then return false end
    local level = jobData.grade and jobData.grade.level or 0
    px.Functions.SetJob(jobData.name, level)
    exports['qbx_core']:SetPlayerData(source, 'job', jobData)
    return true
end

--- Plain job/grade assignment — no custom-field overlay, unlike SetPlayerJob
--- above.
function impl.SetJob(source, jobName, grade)
    local px = exports['qbx_core']:GetPlayer(source)
    if not px then return false end
    px.Functions.SetJob(jobName, grade or 0)
    return true
end

function impl.GetJobs()
    return exports['qbx_core']:GetJobs()
end

function impl.HasPermission(source, permission)
    return exports['qbx_core']:HasPermission(source, permission)
end

function impl.CreateUseableItem(item, handler)
    exports['qbx_core']:CreateUseableItem(item, function(source, itemInstance)
        handler(source, itemInstance.name)
    end)
end

function impl.Notify(source, message, notifyType)
    notifyType = notifyType or 'info'
    exports['qbx_core']:Notify(source, message, notifyType)
end

function impl.GetIdentifier(source)
    local px = exports['qbx_core']:GetPlayer(source)
    return px and px.PlayerData.citizenid or nil
end

--- account: 'bank' | 'cash'
function impl.AddMoney(source, amount, account)
    account = account or 'bank'
    local px = exports['qbx_core']:GetPlayer(source)
    if not px then return false end
    px.Functions.AddMoney(account, amount)
    return true
end

function impl.RemoveMoney(source, amount, account)
    account = account or 'bank'
    local px = exports['qbx_core']:GetPlayer(source)
    if not px then return false end
    px.Functions.RemoveMoney(account, amount)
    return true
end

function impl.GetMoney(source, account)
    account = account or 'bank'
    local px = exports['qbx_core']:GetPlayer(source)
    if not px then return nil end
    return px.Functions.GetMoney(account)
end

-- ─────────────────────────────────────────────
-- Offline / bulk player queries (DB-backed — requires oxmysql). Qbox uses
-- the same `players` table schema as QBCore (it's a compatible fork), so
-- these are identical to framework/qb/server.lua's versions.
-- ─────────────────────────────────────────────

local function qbRowToCharacter(row)
    local charOk, charinfo = pcall(json.decode, row.charinfo or '{}')
    if not charOk or type(charinfo) ~= 'table' then charinfo = {} end
    local job = nil
    if row.job then
        local jobOk, decoded = pcall(json.decode, row.job)
        if jobOk and type(decoded) == 'table' then job = decoded end
    end
    return {
        identifier = row.citizenid,
        name = ('%s %s'):format(charinfo.firstname or 'Unknown', charinfo.lastname or ''),
        firstname = charinfo.firstname,
        lastname = charinfo.lastname,
        job = job and {
            name = job.name,
            label = job.label,
            grade = { level = job.grade and job.grade.level or 0, name = job.grade and job.grade.name or '' },
            isboss = job.isboss == true
        } or nil
    }
end

--- cb(character | nil) — character = { identifier, name, firstname, lastname, job }.
--- Works for offline players too, unlike GetPlayerData.
function impl.GetOfflinePlayer(identifier, cb)
    exports.oxmysql:execute('SELECT citizenid, charinfo, job FROM players WHERE citizenid = ?', { identifier }, function(result)
        cb(result and result[1] and qbRowToCharacter(result[1]) or nil)
    end)
end

--- cb(characters) — every player (online or offline) currently in jobName.
function impl.GetEmployeesByJob(jobName, cb)
    exports.oxmysql:execute('SELECT citizenid, charinfo, job FROM players WHERE job LIKE ?', { '%"name":"' .. jobName .. '"%' }, function(result)
        local characters = {}
        for _, row in ipairs(result or {}) do
            characters[#characters + 1] = qbRowToCharacter(row)
        end
        cb(characters)
    end)
end

--- cb(characters) — { { identifier, name, firstname, lastname }, ... }, the full character roster.
function impl.GetAllCharacters(cb)
    exports.oxmysql:execute('SELECT citizenid, charinfo FROM players', {}, function(result)
        local characters = {}
        for _, row in ipairs(result or {}) do
            local ok, charinfo = pcall(json.decode, row.charinfo or '{}')
            if not ok or type(charinfo) ~= 'table' then charinfo = {} end
            characters[#characters + 1] = {
                identifier = row.citizenid,
                name = ('%s %s'):format(charinfo.firstname or 'Unknown', charinfo.lastname or ''),
                firstname = charinfo.firstname,
                lastname = charinfo.lastname
            }
        end
        cb(characters)
    end)
end

--- Full jobData write (name/label/payment/type/isboss/grade), matching
--- QBCore/Qbox's own job JSON shape. cb(success)
function impl.SetOfflinePlayerJob(identifier, jobData, cb)
    if not jobData or not jobData.name then
        if cb then cb(false) end
        return
    end
    exports.oxmysql:update('UPDATE players SET job = ? WHERE citizenid = ?', { json.encode(jobData), identifier }, function(rowsChanged)
        if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
    end)
end

--- account: 'bank' | 'cash'. cb(success)
function impl.AddOfflinePlayerMoney(identifier, amount, account, cb)
    account = account or 'bank'
    exports.oxmysql:scalar('SELECT money FROM players WHERE citizenid = ?', { identifier }, function(moneyJson)
        if not moneyJson then
            if cb then cb(false) end
            return
        end
        local ok, money = pcall(json.decode, moneyJson)
        if not ok or type(money) ~= 'table' then money = {} end
        money[account] = (money[account] or 0) + amount
        exports.oxmysql:update('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(money), identifier }, function(rowsChanged)
            if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
        end)
    end)
end
