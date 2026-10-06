--[[
    framework/esx/client.lua
    ESX client-side implementation of the lib.framework.impl interface.
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

function impl.GetPlayerData()
    local px = getObject().GetPlayerData()
    -- ESX doesn't expose separate first/last name fields on the client
    -- PlayerData object the way it does server-side (xPlayer.get('firstName')),
    -- so this is a best-effort split of the full display name.
    local firstname, lastname = px.name, nil
    if px.name then
        local first, rest = px.name:match('^(%S+)%s*(.*)$')
        if first then firstname, lastname = first, (rest ~= '' and rest or nil) end
    end
    return {
        source = PlayerId(),
        identifier = px.identifier,
        name = px.name,
        firstname = firstname,
        lastname = lastname,
        job = px.job and {
            name = px.job.name,
            label = px.job.label,
            grade = { level = px.job.grade, name = px.job.grade_label },
            isboss = (px.job.grade_name == 'boss')
        },
        money = px.money
    }
end

function impl.Notify(message, notifyType)
    getObject().ShowNotification(message)
end
