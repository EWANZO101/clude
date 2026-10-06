--[[
    integrations/phone/init.lua
    Selects which phone integration to use, mirroring how
    integrations/inventory/init.lua picks the inventory module — selection is
    based on which phone resource is actually running, not the detected
    framework.

    Controlled by Config.Phone in config.lua:
        Config.Phone = 'auto'     -- auto-detect lb-phone, then qb-phone, else none (default)
        Config.Phone = 'lb_phone' -- force integrations/phone/lb_phone
        Config.Phone = 'qb_phone' -- force integrations/phone/qb_phone
        Config.Phone = 'none'     -- no phone integration
]]

lib = lib or {}
lib.phones = lib.phones or {} -- registry, filled by integrations/phone/<name>/*.lua
lib.phone = {
    name = 'none',
    impl = nil,
    ready = false
}

local PHONE_LABELS = {
    lb_phone = 'lb-phone',
    qb_phone = 'qb-phone',
    none = 'None'
}

-- Checked in this order when Config.Phone is 'auto'. Only one phone resource
-- is realistically installed at once; the resource names themselves are
-- hyphenated ('lb-phone'/'qb-phone') even though these integration
-- folders/keys use the underscore spelling the caller asked for.
-- lb-phone listed first since it's the actively-installed/maintained one of
-- the two on this server; qb-phone is effectively unmaintained upstream.
local PHONE_RESOURCES = {
    { key = 'lb_phone', resourceName = 'lb-phone' },
    { key = 'qb_phone', resourceName = 'qb-phone' }
}

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = PHONE_LABELS[lib.phone.name] or lib.phone.name

    lib.printBanner('rps_lib - phone detection', {
        { 'Resource', resourceName },
        { 'Side',     side },
        { 'Phone',    label }
    })
end

local function detect()
    local forced = (Config and Config.Phone) or 'auto'

    if forced ~= 'auto' then
        lib.phone.name = forced
    else
        lib.phone.name = 'none'
        for _, candidate in ipairs(PHONE_RESOURCES) do
            if GetResourceState(candidate.resourceName) == 'started' then
                lib.phone.name = candidate.key
                break
            end
        end
    end

    lib.phone.impl = lib.phones[lib.phone.name] or lib.phones.none
    lib.phone.ready = true
    printBanner()
end

-- Wait for any candidate phone resource to finish starting before detecting.
CreateThread(function()
    local function anyStarting()
        for _, candidate in ipairs(PHONE_RESOURCES) do
            if GetResourceState(candidate.resourceName) == 'starting' then return true end
        end
        return false
    end

    while anyStarting() do
        Wait(50)
    end
    detect()
end)

--- Returns the selected phone integration name: 'lb_phone' | 'qb_phone' | 'none'
function GetPhoneName()
    return lib.phone.name
end

exports('GetPhoneName', GetPhoneName)
