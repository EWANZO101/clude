--[[
    integrations/phone/none/client.lua
    Fallback used when no phone integration is detected/configured. All
    calls are no-ops rather than erroring.
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.none = lib.phones.none or {}

local impl = lib.phones.none

function impl.OpenPhone(app) end
function impl.SendNotification(options) end
function impl.AddContact(name, number) end
function impl.GetPhoneNumber() return nil end
