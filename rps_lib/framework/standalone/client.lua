--[[
    framework/standalone/client.lua
    Fallback client-side implementation of the lib.framework.impl interface
    for servers running no supported framework.
]]

lib = lib or {}
lib.frameworks = lib.frameworks or {}
lib.frameworks.standalone = lib.frameworks.standalone or {}

local impl = lib.frameworks.standalone

function impl.GetPlayerData()
    return { source = PlayerId(), name = GetPlayerName(PlayerId()) }
end

function impl.Notify(message, notifyType)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end
