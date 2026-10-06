--[[
    integrations/bank/renewed-banking/server.lua
    Targets Renewed-Banking (resource name 'Renewed-Banking', note the
    capitalization — unlike every other integration's resource name in this
    library, FXServer export lookups are case-sensitive on some builds).
    Accounts are addressed by a single `account` string (job name, citizenid,
    or a custom account name) — the same "one name, no separate account
    number" shape this module's own `accountName` already uses, so no
    remapping is needed here.
    https://renewed.dev/banking/exports

    handleTransaction (the richer "record a labeled transaction" export,
    taking title/message/issuer/receiver/type) is intentionally not wired to
    anything here — addAccountMoney/removeAccountMoney already cover this
    category's AddAccountMoney/RemoveAccountMoney contract, and
    handleTransaction's extra fields don't have an equivalent in that
    contract to map from. Call it directly if you need that richer shape.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks['renewed-banking'] = lib.banks['renewed-banking'] or {}

local impl = lib.banks['renewed-banking']

function impl.GetAccountBalance(accountName)
    local amount = exports['Renewed-Banking']:getAccountMoney(accountName)
    return amount or 0
end

function impl.AddAccountMoney(accountName, amount, reason)
    return exports['Renewed-Banking']:addAccountMoney(accountName, amount) == true
end

function impl.RemoveAccountMoney(accountName, amount, reason)
    return exports['Renewed-Banking']:removeAccountMoney(accountName, amount) == true
end

--- Renewed-Banking has no native account-to-account transfer export, so
--- this is a remove-then-add — if the add fails, the removed amount is
--- refunded back to fromAccount rather than being lost.
function impl.TransferAccountMoney(fromAccount, toAccount, amount, reason)
    if not impl.RemoveAccountMoney(fromAccount, amount, reason) then return false end
    if not impl.AddAccountMoney(toAccount, amount, reason) then
        impl.AddAccountMoney(fromAccount, amount, reason)
        return false
    end
    return true
end
