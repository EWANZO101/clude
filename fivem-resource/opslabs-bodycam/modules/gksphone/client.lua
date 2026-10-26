-- GKSPHONE V2 module: registers Xon Sight as a custom GKSPHONE app via the exported AddCustomApp API
-- (https://docs.gkshop.org/gksphone-v2/custom-app). Settings: config_server.lua →
-- ServerConfig.Modules.GksPhone. The app UI is html/gksphone/ (bootstrap) + html/app/ (shared viewer/capture
-- UI, also used by LB Phone and 17Movement).

local RES = GetCurrentResourceName()
local cfg

local function addApp()
    -- AddCustomApp's docs don't describe a return value (unlike LB's added/errorMessage pair) - nothing to
    -- check here beyond the call itself.
    exports["gksphone"]:AddCustomApp({
        name = cfg.identifier, -- required, unique

        appurl = "https://cfx-nui-" .. RES .. "/html/gksphone/index.html",
        icons = "https://cfx-nui-" .. RES .. "/html/app/assets/icon.svg",
        description = cfg.description,

        show = true,
        startapp = cfg.defaultApp,
        blockedjobs = {},
        allowjob = {},
        labelLangs = { en = cfg.name },
    })
end

CreateThread(function()
    cfg = ModuleConfig('gksphone')
    if not cfg then return end

    while GetResourceState("gksphone") ~= "started" do
        Wait(500)
    end
    addApp()
end)

-- Registering the same name again just replaces the previous entry, so re-adding on every start (including
-- gksphone's own) is safe and keeps the app registered across its restarts during development.
AddEventHandler("onResourceStart", function(resource)
    if resource == "gksphone" and cfg then
        addApp()
    end
end)

-- The UI asks for this instead of hardcoding the site URL into its script.
RegisterNUICallback("xonsight:getConfig", function(_, cb)
    if not cfg then return cb({}) end
    cb({
        siteUrl = cfg.siteUrl,
        startPath = cfg.startPath,
        allowCapture = cfg.allowCapture,
    })
end)

-- Stops gameplay input while the player types the caption (https://docs.gkshop.org/gksphone-v2/custom-app).
RegisterNUICallback("xonsight:inputFocus", function(data, cb)
    pcall(function()
        exports["gksphone"]:InputChange(data and data.focused == true)
    end)
    cb({ ok = true })
end)

-- The actual webhook POST happens in modules/evidence.lua (keeps the key out of NUI-reachable code). Only
-- one capture can be in flight per client at a time - the UI disables the Record button while submitting.
local pendingSubmit = nil

RegisterNetEvent("opslabs-bodycam:gksphone:submitResult", function(ok, message)
    if pendingSubmit then
        pendingSubmit:resolve({ ok = ok, message = message })
        pendingSubmit = nil
    end
end)

RegisterNUICallback("xonsight:submitEvidence", function(data, cb)
    pendingSubmit = promise.new()
    TriggerServerEvent("opslabs-bodycam:gksphone:submitEvidence", data)
    cb(Citizen.Await(pendingSubmit))
end)
