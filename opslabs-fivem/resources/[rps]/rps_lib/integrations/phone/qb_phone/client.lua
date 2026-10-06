--[[
    integrations/phone/qb_phone/client.lua
    Targets qb-phone (resource name 'qb-phone'). Client-side phone actions —
    opening the UI, alerting the player, managing contacts — are exports on
    the client side of that resource.
    https://qbcore.net/docs/resources/qb-phone
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.qb_phone = lib.phones.qb_phone or {}

local impl = lib.phones.qb_phone

--- Opens the phone UI, optionally jumping straight to a given app (e.g. 'messages').
function impl.OpenPhone(app)
    exports['qb-phone']:OpenPhone(app)
end

--- options: { app?, title?, text?, icon?, timeout? } — shown as an in-phone
--- alert, distinct from this library's own plain Notify/rich ShowNotification.
function impl.SendNotification(options)
    options = options or {}
    exports['qb-phone']:SendNotification(options)
end

--- Adds a contact to the local player's own phone.
function impl.AddContact(name, number)
    exports['qb-phone']:AddContact(name, number)
end

--- Returns the local player's own phone number.
function impl.GetPhoneNumber()
    return exports['qb-phone']:GetPhoneNumber()
end
