-- LB Phone module (was xonsight-lbphone): registers Xon Sight as a custom LB Phone app via the exported
-- AddCustomApp API (https://docs.lbscripts.com/phone/custom-apps/). Also runs unchanged under Sky Phone's
-- lb-phone compatibility alias (https://github.com/sky-systems/sky_phone#external-custom-apps) - start Sky
-- Phone instead of lb-phone, never both. Settings: config_server.lua → ServerConfig.Modules.LbPhone. The app
-- UI is html/lbphone/ (bootstrap) + html/app/ (shared viewer/capture UI, also used by GKSPHONE and
-- 17Movement).

local RES = GetCurrentResourceName()
local cfg

local function addApp()
    local added, errorMessage = exports["lb-phone"]:AddCustomApp({
        identifier = cfg.identifier,

        name = cfg.name,
        description = cfg.description,
        developer = cfg.developer,

        defaultApp = cfg.defaultApp,
        size = cfg.size,
        price = cfg.price,

        ui = RES .. "/html/lbphone/index.html",
        icon = "https://cfx-nui-" .. RES .. "/html/app/assets/icon.svg",

        fixBlur = true, -- the UI uses rem/em units, not just px
    })

    if not added then
        print("[opslabs-bodycam:lbphone] Could not add app:", errorMessage)
    end
end

CreateThread(function()
    cfg = ModuleConfig('lbphone')
    if not cfg then return end

    while GetResourceState("lb-phone") ~= "started" do
        Wait(500)
    end
    addApp()
end)

-- lb-phone (and Sky Phone acting as it) forgets custom apps added by other resources when it restarts on its
-- own (e.g. during development) - re-register when that happens.
AddEventHandler("onResourceStart", function(resource)
    if resource == "lb-phone" and cfg then
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

-- Stops gameplay input while the player types the caption. Real LB Phone handles this on its own; Sky
-- Phone's lb-phone alias needs it reported explicitly (https://github.com/sky-systems/sky_phone/blob/dev/
-- docs/custom-app-input.md) - a no-op pcall so this stays harmless on real LB Phone and on any server that
-- doesn't run Sky Phone at all.
RegisterNUICallback("xonsight:inputFocus", function(data, cb)
    if GetResourceState("sky_phone") == "started" then
        pcall(function()
            exports["sky_phone"]:SetPhoneGameInputEnabled(data and data.focused == true and false or nil)
        end)
    end
    cb({ ok = true })
end)

-- The actual webhook POST happens in modules/evidence.lua (keeps the key out of NUI-reachable code). Only
-- one capture can be in flight per client at a time - the UI disables the Record button while submitting.
local pendingSubmit = nil

RegisterNetEvent("opslabs-bodycam:lbphone:submitResult", function(ok, message)
    if pendingSubmit then
        pendingSubmit:resolve({ ok = ok, message = message })
        pendingSubmit = nil
    end
end)

RegisterNUICallback("xonsight:submitEvidence", function(data, cb)
    pendingSubmit = promise.new()
    TriggerServerEvent("opslabs-bodycam:lbphone:submitEvidence", data)
    cb(Citizen.Await(pendingSubmit))
end)
