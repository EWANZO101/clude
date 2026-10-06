-- Sends the server's branding (GlobalState['ops:brand'], server/brand.lua) to the phone / laptop UI, live.
AddStateBagChangeHandler('ops:brand', 'global', function(_, _, value)
    if value then SendNUIMessage({ action = 'brand', data = value }) end
end)
