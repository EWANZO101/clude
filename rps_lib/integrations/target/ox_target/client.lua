--[[
    integrations/target/ox_target/client.lua
    Uses ox_target's own client exports directly. `options` here IS
    ox_target's native option-array shape, so it passes straight through
    with no translation — see the canonical shape documented on
    AddBoxZone/AddEntityTarget/AddModelTarget in client/client.lua.
]]

lib = lib or {}
lib.targets = lib.targets or {}
lib.targets.ox_target = lib.targets.ox_target or {}

local impl = lib.targets.ox_target

--- length maps to size.y, width to size.x — verify against your installed
--- ox_target version if a zone comes out an unexpected shape/orientation.
--- Returns `name` as the zone id (ox_target accepts a caller-supplied name).
function impl.AddBoxZone(name, coords, length, width, heading, options, distance)
    exports.ox_target:addBoxZone({
        name = name,
        coords = coords,
        size = vector3(width, length, 2.0),
        rotation = heading or 0.0,
        debug = false,
        options = options,
    })
    return name
end

--- Uses addLocalEntity (this client's own entity handle) rather than
--- addEntity (networked entity id) — matches how callers of this module
--- normally already have a local entity handle in hand.
function impl.AddEntityTarget(entity, options, distance)
    exports.ox_target:addLocalEntity(entity, options)
end

function impl.AddModelTarget(models, options, distance)
    exports.ox_target:addModel(models, options)
end

function impl.RemoveZone(id)
    exports.ox_target:removeZone(id)
end

function impl.RemoveEntityTarget(entity, options)
    exports.ox_target:removeLocalEntity(entity, options)
end
