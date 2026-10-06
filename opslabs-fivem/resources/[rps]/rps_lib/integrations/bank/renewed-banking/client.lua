--[[
    integrations/bank/renewed-banking/client.lua
    Renewed-Banking's documented export list (https://renewed.dev/banking/exports)
    is server-only — it doesn't expose a client export for opening its own
    banking UI from another resource. OpenBank is a no-op here rather than
    an error; players open it the way that resource's own UI/keybind intends.
]]

lib = lib or {}
lib.banks = lib.banks or {}
lib.banks['renewed-banking'] = lib.banks['renewed-banking'] or {}

local impl = lib.banks['renewed-banking']

function impl.OpenBank(accountType) end
