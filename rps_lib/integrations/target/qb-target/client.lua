--[[
    integrations/target/qb-target/client.lua
    qb-target's own option shape (icon/label/action/canInteract) differs
    from the canonical one this module accepts (icon/label/onSelect/
    canInteract), so each option is translated below. Uses qb-target's
    inline `action` callback field rather than its older event+type style —
    if your installed fork predates `action` support, wire the event-based
    style into translateOptions() instead.
]]

lib = lib or {}
lib.targets = lib.targets or {}
lib.targets['qb-target'] = lib.targets['qb-target'] or {}

local impl = lib.targets['qb-target']

local DEFAULT_DISTANCE = 2.5

local function translateOptions(options)
    local translated = {}
    for i, opt in ipairs(options) do
        translated[i] = {
            icon = opt.icon,
            label = opt.label,
            canInteract = opt.canInteract,
            action = function(entity)
                if opt.onSelect then
                    opt.onSelect({ entity = entity })
                end
            end,
        }
    end
    return translated
end

--- Returns `name` as the zone id.
function impl.AddBoxZone(name, coords, length, width, heading, options, distance)
    exports['qb-target']:AddBoxZone(name, coords, length, width, {
        name = name,
        heading = heading or 0.0,
        debugPoly = false,
        minZ = coords.z - 2.0,
        maxZ = coords.z + 2.0,
    }, {
        options = translateOptions(options),
        distance = distance or DEFAULT_DISTANCE,
    })
    return name
end

function impl.AddEntityTarget(entity, options, distance)
    exports['qb-target']:AddTargetEntity(entity, {
        options = translateOptions(options),
        distance = distance or DEFAULT_DISTANCE,
    })
end

function impl.AddModelTarget(models, options, distance)
    exports['qb-target']:AddTargetModel(models, {
        options = translateOptions(options),
        distance = distance or DEFAULT_DISTANCE,
    })
end

function impl.RemoveZone(id)
    exports['qb-target']:RemoveZone(id)
end

--- qb-target's RemoveTargetEntity only takes the entity — there's no
--- per-option removal, unlike ox_target, so `options` is accepted for
--- interface parity but ignored here.
function impl.RemoveEntityTarget(entity, options)
    exports['qb-target']:RemoveTargetEntity(entity)
end
