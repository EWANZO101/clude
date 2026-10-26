-- 17Movement phone module: registers Xon Sight as a custom app via the exported AddApplication API
-- (https://docs.17movement.net/phone/building-custom-apps/registering-the-application). Also runs under Sky
-- Phone's 17mov_Phone compatibility alias (https://github.com/sky-systems/sky_phone#external-custom-apps) -
-- start Sky Phone instead of 17mov_Phone, never both. Settings: config_server.lua →
-- ServerConfig.Modules.Movement. The app UI is html/movement/ (bootstrap) + html/app/ (shared viewer/capture
-- UI, also used by LB Phone and GKSPHONE).
--
-- 17Movement's own boilerplate (github.com/17movement-net/17mov_Phone_app_boilerplate) is a React app built
-- with npm/pnpm, but the registered `ui` only ever needs to be a cfx-nui URL to a built index.html
-- (confirmed by its "Building for Production" doc: the production step just swaps the manifest's ui_page for
-- `web/build/index.html`) - so our existing plain HTML/JS app works unchanged as the `ui` value, no Node
-- build step required on our side.

local RES = GetCurrentResourceName()
local cfg

local function addApp()
    exports["17mov_Phone"]:AddApplication({
        name = cfg.identifier, -- unique identifier
        label = cfg.name, -- shown beneath the icon
        resourceName = RES,

        ui = "https://cfx-nui-" .. RES .. "/html/movement/index.html",
        icon = "https://cfx-nui-" .. RES .. "/html/app/assets/icon.svg",

        default = cfg.defaultApp,
    })
end

CreateThread(function()
    cfg = ModuleConfig('movement')
    if not cfg then return end

    while GetResourceState("17mov_Phone") ~= "started" do
        Wait(500)
    end
    addApp()
end)

AddEventHandler("onResourceStart", function(resource)
    if resource == "17mov_Phone" and cfg then
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

-- 17Movement's docs don't cover a plain-JS input-focus report the way GKSPHONE and Sky Phone do - ack only,
-- so the UI's fetchNui call doesn't fail. Revisit once that's confirmed against a live 17Movement app.
RegisterNUICallback("xonsight:inputFocus", function(_, cb)
    cb({ ok = true })
end)

-- The actual webhook POST happens in modules/evidence.lua (keeps the key out of NUI-reachable code). Only
-- one capture can be in flight per client at a time - the UI disables the Record button while submitting
-- (moot today since html/movement doesn't wire up PhoneBridge.captureVideo yet, but the plumbing matches the
-- other modules so turning it on later is a client.lua-only change).
local pendingSubmit = nil

RegisterNetEvent("opslabs-bodycam:movement:submitResult", function(ok, message)
    if pendingSubmit then
        pendingSubmit:resolve({ ok = ok, message = message })
        pendingSubmit = nil
    end
end)

RegisterNUICallback("xonsight:submitEvidence", function(data, cb)
    pendingSubmit = promise.new()
    TriggerServerEvent("opslabs-bodycam:movement:submitEvidence", data)
    cb(Citizen.Await(pendingSubmit))
end)
