--[[
    integrations/bank/qb-banking/client.lua
    Targets qb-banking (resource name 'qb-banking').
    https://qbcore.net/docs/resources/qb-banking
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks['qb-banking'] = lib.banks['qb-banking'] or {}

local impl = lib.banks['qb-banking']

--- Opens the banking UI, optionally to a given account type (e.g. 'personal').
function impl.OpenBank(accountType)
    exports['qb-banking']:OpenBankingMenu(accountType)
end
