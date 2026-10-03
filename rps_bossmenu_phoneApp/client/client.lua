-- ============================================
--  LB Phone App Registration
--  Based on the structure of lbphone/lb-phone-app-template (React TS).
-- ============================================
while GetResourceState('lb-phone') ~= 'started' do
    Wait(500)
end

Wait(1000) -- wait for the AddCustomApp export to exist

local url = GetResourceMetadata(GetCurrentResourceName(), 'ui_page', 0)

local function AddApp()
    local added, errorMessage = exports['lb-phone']:AddCustomApp({
        identifier = Config.Identifier,

        name = Config.Name,
        description = Config.Description,
        developer = Config.Developer,

        defaultApp = Config.DefaultApp,
        size = 8000, -- app size in kb, shown in the App Store listing

        ui = url:find('http') and url or GetCurrentResourceName() .. '/' .. url,
        icon = url:find('http') and (url .. '/public/icon.svg') or ('https://cfx-nui-' .. GetCurrentResourceName() .. '/ui/dist/icon.svg'),

        fixBlur = true
    })

    if not added then
        print('[rps_bossmenu_phone] Could not add app:', errorMessage)
    end
end

AddApp()

AddEventHandler('onResourceStart', function(resource)
    if resource == 'lb-phone' then
        AddApp()
    end
end)
