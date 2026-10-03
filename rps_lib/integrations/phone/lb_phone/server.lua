--[[
    integrations/phone/lb_phone/server.lua
    Targets lb-phone (resource name 'lb-phone'). Signatures confirmed against
    https://docs.lbscripts.com/phone/exports/server-exports/ (that resource's
    own server/misc/exports.lua is precompiled, so it can't be read directly).

    IMPORTANT identifier caveat: lb-phone addresses everything by phone
    number, not by citizenid/license — unlike qb-phone (see
    integrations/phone/qb_phone/server.lua), it has no concept of the
    framework identifier this library's own GetIdentifier(source) returns.
    So for THIS integration only, the `identifier` parameter documented on
    AddPhoneTweet/SendPhoneBankingNotification in server/server.lua must
    actually be that player's phone number, not their citizenid/license —
    callers switching between phone integrations need to account for that
    difference themselves.
]]

lib = lib or {}
lib.phones = lib.phones or {}
lib.phones.lb_phone = lib.phones.lb_phone or {}

local impl = lib.phones.lb_phone

--- Sends an SMS from senderNumber to receiverNumber.
function impl.SendMessage(senderNumber, receiverNumber, message)
    exports['lb-phone']:SendMessage(senderNumber, receiverNumber, message)
end

--- Starts a call from callerNumber to receiveeNumber via lb-phone's
--- non-UI/payphone call API. lb-phone's own CreateCall(caller, callee,
--- options) is documented only as "requires callee or company parameter" —
--- this is a best-effort mapping of both ends to phone numbers, not verified
--- against an actual installed call flow; check integrations/phone/lb_phone/
--- against your installed copy if calls don't connect as expected.
function impl.StartCall(callerNumber, receiveeNumber)
    exports['lb-phone']:CreateCall(callerNumber, receiveeNumber)
end

--- Posts to lb-phone's Birdy app (its X/Twitter-style social app) as the
--- given phone number — see the identifier caveat above. image is passed
--- through as Birdy's single attachment.
function impl.AddTweet(identifier, message, image)
    local username = exports['lb-phone']:GetSocialMediaUsername(identifier, 'birdy')
    if not username then return false end
    return exports['lb-phone']:PostBirdy(username, message, image and { image } or nil)
end

--- Records a wallet transaction as a banking alert — see the identifier
--- caveat above. lb-phone's AddTransaction only has a single label field, so
--- title/message are combined into one when both are given.
function impl.SendBankingNotification(identifier, title, message, amount)
    local label = (title and message) and (title .. ' - ' .. message) or (title or message or '')
    exports['lb-phone']:AddTransaction(identifier, amount, label)
end
