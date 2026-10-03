--[[
    integrations/bank/none/client.lua
    Fallback used when no bank integration is detected/configured. No-op.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks.none = lib.banks.none or {}

local impl = lib.banks.none

function impl.OpenBank(accountType) end
