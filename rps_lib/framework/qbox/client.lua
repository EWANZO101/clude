--[[
    framework/qbox/client.lua
    QBox (qbx_core) client-side implementation of the lib.framework.impl interface.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.qbox = lib.frameworks.qbox or {}

local impl = lib.frameworks.qbox

function impl.GetPlayerData()
    local px = exports['qbx_core']:GetPlayerData()
    return {
        source = PlayerId(),
        identifier = px.citizenid,
        name = ('%s %s'):format(px.charinfo.firstname, px.charinfo.lastname),
        firstname = px.charinfo.firstname,
        lastname = px.charinfo.lastname,
        job = px.job and {
            name = px.job.name,
            label = px.job.label,
            grade = { level = px.job.grade.level, name = px.job.grade.name },
            isboss = px.job.isboss
        },
        money = px.money
    }
end

function impl.Notify(message, notifyType)
    notifyType = notifyType or 'info'
    exports['qbx_core']:Notify(message, notifyType)
end
