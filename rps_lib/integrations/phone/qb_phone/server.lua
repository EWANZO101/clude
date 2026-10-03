--[[
    integrations/phone/qb_phone/server.lua
    Targets qb-phone (resource name 'qb-phone'). SMS/calls are addressed by
    phone number (not source), and AddTweet/SendBankingNotification are keyed
    by citizenid — on the QBCore/Qbox frameworks this library's own
    GetIdentifier(source) already returns citizenid, so pass that through
    as-is rather than translating it here.
    https://qbcore.net/docs/resources/qb-phone
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.qb_phone = lib.phones.qb_phone or {}

local impl = lib.phones.qb_phone

--- Sends an SMS from senderNumber to receiverNumber.
function impl.SendMessage(senderNumber, receiverNumber, message)
    exports['qb-phone']:SendMessage(senderNumber, receiverNumber, message)
end

--- Starts a phone call from callerNumber to receiveeNumber.
function impl.StartCall(callerNumber, receiveeNumber)
    exports['qb-phone']:StartCall(callerNumber, receiveeNumber)
end

--- Posts a tweet as the given citizenid. image is an optional URL.
function impl.AddTweet(identifier, message, image)
    exports['qb-phone']:AddTweet(identifier, message, image)
end

--- Pushes a banking alert (e.g. "-$500 at the pawn shop") to that citizenid's banking app.
function impl.SendBankingNotification(identifier, title, message, amount)
    exports['qb-phone']:SendBankingNotification(identifier, title, message, amount)
end
