--[[
    framework/esx/server.lua
    ESX server-side implementation of the lib.framework.impl interface.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.esx = lib.frameworks.esx or {}

local ESX = nil
local function getObject()
    if not ESX then
        ESX = exports['es_extended']:getSharedObject()
    end
    return ESX
end

local impl = lib.frameworks.esx

function impl.GetPlayerData(source)
    local px = getObject().GetPlayerFromId(source)
    if not px then return nil end
    return {
        source = source,
        identifier = px.identifier,
        name = px.getName and px.getName() or GetPlayerName(source),
        firstname = px.get and (px.get('firstName') or px.get('firstname')) or nil,
        lastname = px.get and (px.get('lastName') or px.get('lastname')) or nil,
        job = px.job and {
            name = px.job.name,
            label = px.job.label,
            grade = { level = px.job.grade, name = px.job.grade_label },
            isboss = (px.job.grade_name == 'boss')
        },
        -- Normalized to { cash, bank } to match QBCore/Qbox's native
        -- PlayerData.money shape, since callers rely on both keys (e.g. to
        -- balance-check before a RemoveMoney call) regardless of framework.
        money = {
            cash = px.getMoney and px.getMoney() or 0,
            bank = (px.getAccount and px.getAccount('bank') or {}).money or 0
        }
    }
end

--- Writes a full job assignment back to ESX. ESX has no per-player wage/isboss
--- override mechanism the way QBCore-family frameworks do (job pay/grades come
--- from the shared ESX.Jobs table, not per-player), so only jobData.name and
--- jobData.grade.level actually take effect here — jobData.payment/isboss/
--- grade.name are accepted for interface parity but silently ignored.
function impl.SetPlayerJob(source, jobData)
    local px = getObject().GetPlayerFromId(source)
    if not px or not jobData or not jobData.name then return false end
    local level = jobData.grade and jobData.grade.level or 0
    px.setJob(jobData.name, level)
    return true
end

--- ESX's own setJob already fully recomputes label/grade_label from the
--- shared ESX.Jobs table, so this is identical to SetPlayerJob's ESX path —
--- kept separate for interface parity with the QBCore-family integrations.
function impl.SetJob(source, jobName, grade)
    local px = getObject().GetPlayerFromId(source)
    if not px then return false end
    px.setJob(jobName, grade or 0)
    return true
end

function impl.GetJobs()
    return getObject().GetJobs()
end

--- ESX has no per-permission-string ACE check the way QBCore/Qbox's own
--- HasPermission does — `permission` is ignored and this just checks group
--- membership (admin/superadmin), matching how ESX-based admin gating is
--- conventionally done.
function impl.HasPermission(source, permission)
    local px = getObject().GetPlayerFromId(source)
    if not px then return false end
    local group = px.getGroup()
    return (group == 'admin' or group == 'superadmin')
end

--- Registers a server-side "use item" handler. handler(source, itemName) is
--- called when a player uses the item — ESX's own RegisterUsableItem has no
--- per-use item instance to pass through, only the name, so that's all
--- handler receives here (same on every framework, for interface parity).
function impl.CreateUseableItem(item, handler)
    getObject().RegisterUsableItem(item, function(source)
        handler(source, item)
    end)
end

function impl.Notify(source, message, notifyType)
    TriggerClientEvent('esx:showNotification', source, message)
end

function impl.GetIdentifier(source)
    local px = getObject().GetPlayerFromId(source)
    return px and px.identifier or nil
end

--- account: 'bank' | 'cash' (ESX has no 'cash' account — cash is the player's
--- own money, addressed via addMoney/removeMoney/getMoney rather than
--- addAccountMoney, so it's special-cased here to match the unified API).
function impl.AddMoney(source, amount, account)
    account = account or 'bank'
    local px = getObject().GetPlayerFromId(source)
    if not px then return false end
    if account == 'cash' then
        px.addMoney(amount)
    else
        px.addAccountMoney(account, amount)
    end
    return true
end

function impl.RemoveMoney(source, amount, account)
    account = account or 'bank'
    local px = getObject().GetPlayerFromId(source)
    if not px then return false end
    if account == 'cash' then
        px.removeMoney(amount)
    else
        px.removeAccountMoney(account, amount)
    end
    return true
end

function impl.GetMoney(source, account)
    account = account or 'bank'
    local px = getObject().GetPlayerFromId(source)
    if not px then return nil end
    if account == 'cash' then
        return px.getMoney()
    end
    local acc = px.getAccount(account)
    return acc and acc.money or 0
end

-- ─────────────────────────────────────────────
-- Offline / bulk player queries (DB-backed — requires oxmysql). Needed
-- because ESX's own Player object only exists for online players; these
-- work for offline ones too by querying the `users` table directly.
-- ─────────────────────────────────────────────

--- Reconstructs full job info (label, grade name, isboss) for a stored
--- job name/level pair from the shared ESX.Jobs catalog — the `users`
--- table only stores `job` (name) + `job_grade` (level), not the rest.
--- Mirrors the same grade_name == 'boss' convention GetPlayerData uses.
local function resolveEsxJob(jobName, level)
    local jobs = getObject().GetJobs()
    local jobDef = jobs and jobs[jobName]
    local gradeDef = jobDef and jobDef.grades and jobDef.grades[tostring(level or 0)]
    return {
        name = jobName or 'unemployed',
        label = jobDef and jobDef.label or (jobName or 'Unemployed'),
        grade = { level = level or 0, name = gradeDef and gradeDef.label or '' },
        isboss = (gradeDef and gradeDef.name == 'boss') or false
    }
end

local function esxRowToCharacter(row)
    return {
        identifier = row.identifier,
        name = ('%s %s'):format(row.firstname or 'Unknown', row.lastname or ''),
        firstname = row.firstname,
        lastname = row.lastname,
        job = resolveEsxJob(row.job, row.job_grade)
    }
end

--- cb(character | nil) — character = { identifier, name, firstname, lastname, job }.
--- Works for offline players too, unlike GetPlayerData.
function impl.GetOfflinePlayer(identifier, cb)
    exports.oxmysql:execute('SELECT identifier, firstname, lastname, job, job_grade FROM users WHERE identifier = ?', { identifier }, function(result)
        cb(result and result[1] and esxRowToCharacter(result[1]) or nil)
    end)
end

--- cb(characters) — every player (online or offline) currently in jobName.
function impl.GetEmployeesByJob(jobName, cb)
    exports.oxmysql:execute('SELECT identifier, firstname, lastname, job, job_grade FROM users WHERE job = ?', { jobName }, function(result)
        local characters = {}
        for _, row in ipairs(result or {}) do
            characters[#characters + 1] = esxRowToCharacter(row)
        end
        cb(characters)
    end)
end

--- cb(characters) — { { identifier, name, firstname, lastname }, ... }, the full character roster.
function impl.GetAllCharacters(cb)
    exports.oxmysql:execute('SELECT identifier, firstname, lastname FROM users', {}, function(result)
        local characters = {}
        for _, row in ipairs(result or {}) do
            characters[#characters + 1] = {
                identifier = row.identifier,
                name = ('%s %s'):format(row.firstname or 'Unknown', row.lastname or ''),
                firstname = row.firstname,
                lastname = row.lastname
            }
        end
        cb(characters)
    end)
end

--- Only jobData.name/grade.level take effect — same ESX limitation as
--- SetPlayerJob above. cb(success)
function impl.SetOfflinePlayerJob(identifier, jobData, cb)
    if not jobData or not jobData.name then
        if cb then cb(false) end
        return
    end
    local level = jobData.grade and jobData.grade.level or 0
    exports.oxmysql:update('UPDATE users SET job = ?, job_grade = ? WHERE identifier = ?', { jobData.name, level, identifier }, function(rowsChanged)
        if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
    end)
end

--- Only 'bank' is a real ESX account on this server (see AddMoney's caveat
--- above) — cash has no offline DB representation to add to (it's an
--- inventory item here, not a column), so account = 'cash' is a no-op
--- that returns false. cb(success)
function impl.AddOfflinePlayerMoney(identifier, amount, account, cb)
    account = account or 'bank'
    if account == 'cash' then
        if cb then cb(false) end
        return
    end
    exports.oxmysql:scalar('SELECT accounts FROM users WHERE identifier = ?', { identifier }, function(accountsJson)
        if not accountsJson then
            if cb then cb(false) end
            return
        end
        local ok, accounts = pcall(json.decode, accountsJson)
        if not ok or type(accounts) ~= 'table' then accounts = {} end
        accounts[account] = (accounts[account] or 0) + amount
        exports.oxmysql:update('UPDATE users SET accounts = ? WHERE identifier = ?', { json.encode(accounts), identifier }, function(rowsChanged)
            if cb then cb(rowsChanged ~= nil and rowsChanged > 0) end
        end)
    end)
end
