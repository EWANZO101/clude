--[[
    integrations/target/init.lua
    Selects which targeting ("third-eye") integration to use. Client-only —
    unlike progressbar/notifications, targeting has no server-side piece at
    all (there's no meaningful "server asks a client to add a target zone"
    use case the way there is for progress bars), so this whole module,
    including this detector, only ever loads client-side.

    Controlled by Config.Target in config.lua:
        Config.Target = 'auto'           -- auto-detect ox_target, then tgiann-target, then qb-target, else none (default)
        Config.Target = 'ox_target'      -- force integrations/target/ox_target
        Config.Target = 'tgiann-target'  -- force integrations/target/tgiann-target
        Config.Target = 'qb-target'      -- force integrations/target/qb-target
        Config.Target = 'none'           -- no targeting integration
]]

lib = lib or {}
lib.targets = lib.targets or {} -- registry, filled by integrations/target/<name>/client.lua
lib.target = {
    name = 'none',
    impl = nil,
    ready = false
}

local TARGET_LABELS = {
    ox_target = 'ox_target',
    ['tgiann-target'] = 'tgiann-target',
    ['qb-target'] = 'qb-target',
    none = 'None'
}

-- Checked in this order when Config.Target is 'auto'.
local TARGET_RESOURCES = { 'ox_target', 'tgiann-target', 'qb-target' }

local function printBanner()
    lib.printBanner('rps_lib - target detection', {
        { 'Resource', GetCurrentResourceName() },
        { 'Side',     'client' },
        { 'Target',   TARGET_LABELS[lib.target.name] or lib.target.name }
    })
end

local function detect()
    local forced = (Config and Config.Target) or 'auto'

    if forced ~= 'auto' then
        lib.target.name = forced
    else
        lib.target.name = 'none'
        for _, name in ipairs(TARGET_RESOURCES) do
            if GetResourceState(name) == 'started' then
                lib.target.name = name
                break
            end
        end
    end

    lib.target.impl = lib.targets[lib.target.name] or lib.targets.none
    lib.target.ready = true
    printBanner()
end

-- Wait for any candidate target resource to finish starting before detecting.
CreateThread(function()
    local function anyStarting()
        for _, name in ipairs(TARGET_RESOURCES) do
            if GetResourceState(name) == 'starting' then return true end
        end
        return false
    end

    while anyStarting() do
        Wait(50)
    end
    detect()
end)

--- Returns the selected target integration name: 'ox_target' | 'tgiann-target' | 'qb-target' | 'none'
function GetTargetName()
    return lib.target.name
end

exports('GetTargetName', GetTargetName)
