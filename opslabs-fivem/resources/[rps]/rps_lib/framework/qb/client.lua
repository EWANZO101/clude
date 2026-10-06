--[[
    framework/qb/client.lua
    QBCore client-side implementation of the lib.framework.impl interface.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.qb = lib.frameworks.qb or {}

local QBCore = nil
local function getObject()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

local impl = lib.frameworks.qb

function impl.GetPlayerData()
    local px = getObject().Functions.GetPlayerData()
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
    getObject().Functions.Notify(message, notifyType)
end
