--[[
    integrations/phone/none/server.lua
    Fallback used when no phone integration is detected/configured. All
    calls are no-ops rather than erroring.
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.none = lib.phones.none or {}

local impl = lib.phones.none

function impl.SendMessage(senderNumber, receiverNumber, message) end
function impl.StartCall(callerNumber, receiveeNumber) end
function impl.AddTweet(identifier, message, image) end
function impl.SendBankingNotification(identifier, title, message, amount) end
