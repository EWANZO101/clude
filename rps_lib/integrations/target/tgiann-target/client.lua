--[[
    integrations/target/tgiann-target/client.lua
    Uses tgiann-target's own client exports directly — its TargetOptions
    shape (label/name/icon/distance/canInteract/onSelect) matches this
    module's canonical options shape almost exactly, so options pass
    through with no translation needed (unlike qb-target). Unlike
    ox_target, tgiann-target's entity exports take network ids rather than
    local entity handles, so that conversion happens here.
    https://tgiann.gitbook.io/tgiann/free/tgiann-target/exports
]]

lib = lib or {}
lib.targets = lib.targets or {}
lib.targets['tgiann-target'] = lib.targets['tgiann-target'] or {}

local impl = lib.targets['tgiann-target']

--- length maps to size.y, width to size.x — same size-axis assumption used
--- for ox_target; verify against your installed version if a zone comes
--- out an unexpected shape/orientation.
--- Returns `name` as the zone id (tgiann-target accepts a caller-supplied
--- name as an alternative to the id it generates internally).
function impl.AddBoxZone(name, coords, length, width, heading, options, distance)
    exports['tgiann-target']:addBoxZone({
        name = name,
        coords = coords,
        size = vector3(width, length, 2.0),
        rotation = heading or 0.0,
        debug = false,
        options = options,
    })
    return name
end

function impl.AddEntityTarget(entity, options, distance)
    exports['tgiann-target']:addEntity(NetworkGetNetworkIdFromEntity(entity), options)
end

function impl.AddModelTarget(models, options, distance)
    exports['tgiann-target']:addModel(models, options)
end

function impl.RemoveZone(id)
    exports['tgiann-target']:removeZone(id)
end

--- tgiann-target's removeEntity takes an array of option *names* to remove,
--- not the full option table — extracts .name from each entry that has
--- one. Options added without a name can't be individually targeted this
--- way; pass no `options` at all to remove everything on the entity instead.
function impl.RemoveEntityTarget(entity, options)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not options then
        exports['tgiann-target']:removeEntity(netId)
        return
    end
    local optionNames = {}
    for _, opt in ipairs(options) do
        if opt.name then optionNames[#optionNames + 1] = opt.name end
    end
    exports['tgiann-target']:removeEntity(netId, optionNames)
end
