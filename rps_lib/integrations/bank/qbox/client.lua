--[[
    integrations/bank/qbox/client.lua
    Qbox has no dedicated banking resource of its own — bank balance is just
    qbx_core's 'bank' money type on the player (see server.lua), and there's
    no bundled banking UI to open (players typically check their balance via
    the phone/HUD instead). OpenBank is a no-op here rather than an error.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks.qbox = lib.banks.qbox or {}

local impl = lib.banks.qbox

function impl.OpenBank(accountType) end
