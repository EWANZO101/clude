--[[
    integrations/phone/lb_phone/client.lua
    Targets lb-phone (resource name 'lb-phone'). Confirmed against the copy
    installed in resources/[phone]/lb-phone — its own exports.lua is
    precompiled, so the exact signatures here are taken from
    https://docs.lbscripts.com/phone/exports/client-exports/, cross-checked
    against real call sites elsewhere in that resource (e.g.
    ToggleOpen(true)/ToggleOpen(false) as an explicit open/close, not a
    stateless toggle, confirmed in its own client/custom/functions/item.lua).
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.lb_phone = lib.phones.lb_phone or {}

local impl = lib.phones.lb_phone

--- Opens the phone, or jumps straight to a given app identifier (e.g. 'messages').
function impl.OpenPhone(app)
    if app then
        exports['lb-phone']:OpenApp(app)
    else
        exports['lb-phone']:ToggleOpen(true)
    end
end

--- options: { app?, title?, text?, icon?, timeout? } — remapped to lb-phone's
--- own notification shape (title/content/thumbnail), which doesn't have a
--- direct timeout field of its own.
function impl.SendNotification(options)
    options = options or {}
    exports['lb-phone']:SendNotification({
        app = options.app,
        title = options.title,
        content = options.text,
        thumbnail = options.icon
    })
end

--- Adds a contact to the local player's own phone. lb-phone's own AddContact
--- takes a single data table (number/firstname/lastname/avatar/email/address)
--- rather than qb-phone's positional (name, number) — name is stored as
--- firstname here since this library's own AddPhoneContact has no separate
--- first/last name fields.
function impl.AddContact(name, number)
    exports['lb-phone']:AddContact({ number = number, firstname = name })
end

--- Returns the local player's own equipped phone number.
function impl.GetPhoneNumber()
    return exports['lb-phone']:GetEquippedPhoneNumber()
end
