--[[
    integrations/inventory/init.lua
    Selects which inventory integration to use, mirroring how
    integrations/notifications/init.lua picks the notification module —
    selection is based on which inventory resource is actually running, not
    on the detected framework: ox_inventory works on any framework, and the
    qb-family ones (qb-inventory / ps-inventory / lj-inventory) all key off
    QBCore's own Player.Functions item API rather than exports of their own,
    so which specific one is installed mostly only matters for detection.

    Controlled by Config.Inventory in config.lua:
        Config.Inventory = 'auto'             -- auto-detect, else none (default)
        Config.Inventory = 'ox_inventory'     -- force integrations/inventory/ox_inventory
        Config.Inventory = 'tgiann-inventory' -- force integrations/inventory/tgiann-inventory
        Config.Inventory = 'qb-inventory'     -- force integrations/inventory/qb-inventory
        Config.Inventory = 'ps-inventory'     -- force integrations/inventory/ps-inventory
        Config.Inventory = 'lj-inventory'     -- force integrations/inventory/lj-inventory
        Config.Inventory = 'none'             -- no inventory integration
]]

lib = lib or {}
lib.inventories = lib.inventories or {} -- registry, filled by integrations/inventory/<name>/*.lua
lib.inventory = {
    name = 'none',
    impl = nil,
    ready = false
}

local INVENTORY_LABELS = {
    ox_inventory = 'ox_inventory',
    ['tgiann-inventory'] = 'tgiann-inventory',
    ['qb-inventory'] = 'qb-inventory',
    ['ps-inventory'] = 'ps-inventory (Project Sloth)',
    ['lj-inventory'] = 'lj-inventory',
    none = 'None'
}

-- Checked in this order when Config.Inventory is 'auto'. Only one of these
-- is ever realistically installed at once, so the order mostly just needs
-- to be deterministic — ox_inventory and tgiann-inventory listed first
-- since they're the two that work across every framework this library
-- supports (and have the most complete export sets).
local INVENTORY_RESOURCES = { 'ox_inventory', 'tgiann-inventory', 'qb-inventory', 'ps-inventory', 'lj-inventory' }

local function printBanner()
    local resourceName = GetCurrentResourceName()
    local side = IsDuplicityVersion() and 'server' or 'client'
    local label = INVENTORY_LABELS[lib.inventory.name] or lib.inventory.name

    lib.printBanner('rps_lib - inventory detection', {
        { 'Resource',  resourceName },
        { 'Side',      side },
        { 'Inventory', label }
    })
end

local function detect()
    local forced = (Config and Config.Inventory) or 'auto'

    if forced ~= 'auto' then
        lib.inventory.name = forced
    else
        lib.inventory.name = 'none'
        for _, name in ipairs(INVENTORY_RESOURCES) do
            if GetResourceState(name) == 'started' then
                lib.inventory.name = name
                break
            end
        end
    end

    lib.inventory.impl = lib.inventories[lib.inventory.name] or lib.inventories.none
    lib.inventory.ready = true
    printBanner()
end

-- Wait for any candidate inventory resource to finish starting before detecting.
CreateThread(function()
    local function anyStarting()
        for _, name in ipairs(INVENTORY_RESOURCES) do
            if GetResourceState(name) == 'starting' then return true end
        end
        return false
    end

    while anyStarting() do
        Wait(50)
    end
    detect()
end)

--- Returns the selected inventory integration name:
--- 'ox_inventory' | 'qb-inventory' | 'ps-inventory' | 'lj-inventory' | 'none'
function GetInventoryName()
    return lib.inventory.name
end

exports('GetInventoryName', GetInventoryName)
