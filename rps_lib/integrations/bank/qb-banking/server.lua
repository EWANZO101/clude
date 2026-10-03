--[[
    integrations/bank/qb-banking/server.lua
    Targets qb-banking (resource name 'qb-banking'). Accounts are addressed
    by a single `accountName` string throughout this module — qb-banking
    itself uses a player's citizenid as their personal account's name, and a
    job/gang's own name for shared accounts, so there's no separate
    "account type" needed to read/add/remove/transfer balance once you
    already have the right name.

    CreateAccount (CreatePlayerAccount/CreateJobAccount/CreateGangAccount)
    is deliberately NOT exposed here — qb-banking auto-creates personal and
    job/gang accounts the first time a bank is opened, and its exact
    creation export signature differs between documented versions of this
    resource, so wiring to the wrong one would silently do the wrong thing
    rather than error. If you need explicit account creation, call the
    qb-banking export your installed copy actually has directly.
    https://qbcore.net/docs/resources/qb-banking
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks['qb-banking'] = lib.banks['qb-banking'] or {}

local impl = lib.banks['qb-banking']

function impl.GetAccountBalance(accountName)
    return exports['qb-banking']:GetAccountBalance(accountName) or 0
end

function impl.AddAccountMoney(accountName, amount, reason)
    return exports['qb-banking']:AddMoney(accountName, amount, reason) == true
end

function impl.RemoveAccountMoney(accountName, amount, reason)
    return exports['qb-banking']:RemoveMoney(accountName, amount, reason) == true
end

--- fromAccount/toAccount are both citizenids on qb-banking's own TransferMoney.
function impl.TransferAccountMoney(fromAccount, toAccount, amount, reason)
    return exports['qb-banking']:TransferMoney(fromAccount, toAccount, amount, reason) == true
end
