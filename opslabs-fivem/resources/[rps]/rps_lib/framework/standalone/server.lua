--[[
    framework/standalone/server.lua
    Fallback server-side implementation of the lib.framework.impl interface
    for servers running no supported framework. Money/job data isn't
    available, so those calls safely return false/nil rather than erroring.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.standalone = lib.frameworks.standalone or {}

local impl = lib.frameworks.standalone

function impl.GetPlayerData(source)
    return { source = source, name = GetPlayerName(source) }
end

function impl.Notify(source, message, notifyType)
    TriggerClientEvent('chat:addMessage', source, { args = { 'Server', message } })
end

--- Falls back to the license identifier.
function impl.GetIdentifier(source)
    for _, id in ipairs(GetPlayerIdentifiers(source)) do
        if id:find('license:') then return id end
    end
    return nil
end

-- No generic money system to hook into without a framework.
function impl.AddMoney(source, amount, account) return false end
function impl.RemoveMoney(source, amount, account) return false end
function impl.GetMoney(source, account) return nil end

-- No job system without a framework.
function impl.SetPlayerJob(source, jobData)
    lib.print('SetPlayerJob is not supported without a framework (Config.Framework is standalone)')
    return false
end

function impl.SetJob(source, jobName, grade)
    lib.print('SetJob is not supported without a framework (Config.Framework is standalone)')
    return false
end

function impl.GetJobs() return {} end

--- Falls back to a native ACE permission check since there's no framework
--- permission-group system to defer to.
function impl.HasPermission(source, permission)
    return IsPlayerAceAllowed(source, permission) == true
end

function impl.CreateUseableItem(item, handler)
    lib.print(('CreateUseableItem(%s) is not supported without a framework (Config.Framework is standalone)'):format(item))
end

-- No player database to query without a framework.
function impl.GetOfflinePlayer(identifier, cb) cb(nil) end
function impl.GetEmployeesByJob(jobName, cb) cb({}) end
function impl.GetAllCharacters(cb) cb({}) end
function impl.SetOfflinePlayerJob(identifier, jobData, cb) if cb then cb(false) end end
function impl.AddOfflinePlayerMoney(identifier, amount, account, cb) if cb then cb(false) end end
