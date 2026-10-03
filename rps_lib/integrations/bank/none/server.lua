--[[
    integrations/bank/none/server.lua
    Fallback used when no bank integration is detected/configured. All calls
    return empty/false rather than erroring.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks.none = lib.banks.none or {}

local impl = lib.banks.none

function impl.GetAccountBalance(accountName) return 0 end
function impl.AddAccountMoney(accountName, amount, reason) return false end
function impl.RemoveAccountMoney(accountName, amount, reason) return false end
function impl.TransferAccountMoney(fromAccount, toAccount, amount, reason) return false end
