-- Registers Xon Sight as a custom LB Phone app via the exported
-- AddCustomApp API (lb-phone's own documented pattern - see
-- https://docs.lbscripts.com/phone/custom-apps/), rather than editing
-- lb-phone's config.lua directly. That keeps this whole integration a
-- single drop-in resource.
local function addApp()
    local added, errorMessage = exports["lb-phone"]:AddCustomApp({
        identifier = Config.Identifier,

        name = Config.Name,
        description = Config.Description,
        developer = Config.Developer,

        defaultApp = Config.DefaultApp,
        size = Config.Size,
        price = Config.Price,

        ui = GetCurrentResourceName() .. "/ui/index.html",
        icon = "https://cfx-nui-" .. GetCurrentResourceName() .. "/ui/assets/icon.svg",

        fixBlur = true, -- the UI uses rem/em units, not just px
    })

    if not added then
        print("[xonsight-lbphone] Could not add app:", errorMessage)
    end
end

CreateThread(function()
    while GetResourceState("lb-phone") ~= "started" do
        Wait(500)
    end
    addApp()
end)

-- lb-phone forgets custom apps added by other resources when it restarts
-- on its own (e.g. during development) - re-register when that happens.
AddEventHandler("onResourceStart", function(resource)
    if resource == "lb-phone" then
        addApp()
    end
end)

-- The UI asks for this instead of hardcoding the site URL into ui/script.js,
-- so server owners only ever edit config.lua.
RegisterNUICallback("xonsight:getConfig", function(_, cb)
    cb({
        siteUrl = Config.SiteUrl,
        startPath = Config.StartPath,
        allowCapture = Config.AllowCapture,
    })
end)

-- The actual webhook POST happens in server.lua (keeps the webhook key
-- out of NUI-reachable code) - this just relays the captured media URL
-- there and acks the UI immediately so it isn't left waiting on the
-- HTTP round trip.
RegisterNUICallback("xonsight:submitEvidence", function(data, cb)
    TriggerServerEvent("xonsight-lbphone:submitEvidence", data)
    cb({ ok = true })
end)

RegisterNetEvent("xonsight-lbphone:submitResult", function(ok, message)
    SendNUIMessage({ action = "submitResult", ok = ok, message = message })
end)
