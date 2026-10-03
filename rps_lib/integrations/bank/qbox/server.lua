--[[
    integrations/bank/qbox/server.lua
    Qbox has no separate banking resource/account system — a player's "bank
    account" is just qbx_core's own 'bank' money type, addressed by
    identifier (source or citizenid), via its GetMoney/AddMoney/RemoveMoney
    exports. https://docs.qbox.re/resources/qbx_core/exports/server

    IMPORTANT accountName caveat: unlike qb-banking, qbx_core has no concept
    of named job/gang/shared accounts — only a per-player balance. So
    `accountName` here must actually be a player identifier (source or
    citizenid), not a job/gang name; passing a job/gang name will just fail
    to resolve a player and return false/0. If you need real shared
    job/gang accounts on Qbox, you need an actual banking resource (there's
    no qb-banking equivalent bundled with qbx_core) — ask for support to be
    added once you've picked one.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks.qbox = lib.banks.qbox or {}

local impl = lib.banks.qbox

function impl.GetAccountBalance(accountName)
    return exports['qbx_core']:GetMoney(accountName, 'bank') or 0
end

function impl.AddAccountMoney(accountName, amount, reason)
    return exports['qbx_core']:AddMoney(accountName, 'bank', amount, reason) == true
end

function impl.RemoveAccountMoney(accountName, amount, reason)
    return exports['qbx_core']:RemoveMoney(accountName, 'bank', amount, reason) == true
end

--- qbx_core has no native account-to-account transfer, so this is a
--- remove-then-add — if the add fails (e.g. invalid toAccount), the removed
--- amount is refunded back to fromAccount rather than being lost.
function impl.TransferAccountMoney(fromAccount, toAccount, amount, reason)
    if not impl.RemoveAccountMoney(fromAccount, amount, reason) then return false end
    if not impl.AddAccountMoney(toAccount, amount, reason) then
        impl.AddAccountMoney(fromAccount, amount, reason)
        return false
    end
    return true
end
