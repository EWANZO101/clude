--[[
    integrations/bank/init.lua
    Selects which bank integration to use. Hybrid detection, unlike the
    purely resource-based modules (inventory/target/phone) or the purely
    framework-based ones (garage/ambulancejob): qb-banking and
    Renewed-Banking are specific resources (named personal/job/gang
    accounts, transfers, boss-managed access — strictly more than plain
    framework money), so either is checked first regardless of framework.
    Qbox has no equivalent dedicated banking resource — "bank account"
    there is just qbx_core's own 'bank' money type — so it's only picked as
    a framework-based fallback, and only supports per-player balances, not
    named job/gang accounts (see the caveat in integrations/bank/qbox/server.lua).

    Controlled by Config.Bank in config.lua:
        Config.Bank = 'auto'             -- auto-detect qb-banking, then Renewed-Banking, else qbox (if that's the framework), else none (default)
        Config.Bank = 'qb-banking'       -- force integrations/bank/qb-banking
        Config.Bank = 'renewed-banking'  -- force integrations/bank/renewed-banking
        Config.Bank = 'qbox'             -- force integrations/bank/qbox (qbx_core money, 'bank' type)
        Config.Bank = 'none'             -- no bank integration
]]

lib = lib or {}
lib.banks = lib.banks or {} -- registry, filled by integrations/bank/<name>/*.lua
lib.bank = {
    name = 'none',
    impl = nil,
    ready = false
}

local BANK_LABELS = {
    ['qb-banking'] = 'qb-banking',
    ['renewed-banking'] = 'Renewed-Banking',
    qbox = 'QBox (qbx_core bank money)',
    none = 'None'
}

-- Resource-based candidates checked (in order) before falling back to the
-- framework-based qbox integration. The resource name itself is
-- 'Renewed-Banking' (capitalized) even though this integration's own
-- key/folder uses the lowercase-hyphenated spelling every other provider
-- in this library uses.
local BANK_RESOURCES = {
    { key = 'qb-banking',      resourceName = 'qb-banking' },
    { key = 'renewed-banking', resourceName = 'Renewed-Banking' }
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = BANK_LABELS[lib.bank.name] or lib.bank.name

    lib.printBanner('rps_lib - bank detection', {
        { 'Resource', resourceName },
        { 'Side',     side },
        { 'Bank',     label }
    })
end

local function detect()
    local forced = (Config and Config.Bank) or 'auto'

    if forced ~= 'auto' then
        lib.bank.name = forced
    else
        lib.bank.name = 'none'
        for _, candidate in ipairs(BANK_RESOURCES) do
            if GetResourceState(candidate.resourceName) == 'started' then
                lib.bank.name = candidate.key
                break
            end
        end
        if lib.bank.name == 'none' and lib.framework.name == 'qbox' then
            lib.bank.name = 'qbox'
        end
    end

    lib.bank.impl = lib.banks[lib.bank.name] or lib.banks.none
    lib.bank.ready = true
    printBanner()
end

-- Framework detection must finish first (auto mode falls back on
-- lib.framework.name), and each resource-based candidate needs the chance
-- to leave 'starting'.
CreateThread(function()
    while not (lib.framework and lib.framework.ready) do
        Wait(50)
    end

    local function anyStarting()
        for _, candidate in ipairs(BANK_RESOURCES) do
            if GetResourceState(candidate.resourceName) == 'starting' then return true end
        end
        return false
    end

    while anyStarting() do
        Wait(50)
    end
    detect()
end)

--- Returns the selected bank integration name: 'qb-banking' | 'renewed-banking' | 'qbox' | 'none'
function GetBankName()
    return lib.bank.name
end

exports('GetBankName', GetBankName)
