--[[
    integrations/target/none/client.lua
    Fallback used when no targeting module is detected/configured. Zone/
    entity/model adds just log a reminder via lib.print rather than erroring
    or silently pretending to work; removals are safe no-ops.
]]

lib = lib or {}
lib.targets = lib.targets or {}
lib.targets.none = lib.targets.none or {}

local impl = lib.targets.none

function impl.AddBoxZone(name, coords, length, width, heading, options, distance)
    lib.print(('AddBoxZone("%s") called but no target module is configured (Config.Target = "none")'):format(name))
    return name
end

function impl.AddEntityTarget(entity, options, distance)
    lib.print('AddEntityTarget called but no target module is configured (Config.Target = "none")')
end

function impl.AddModelTarget(models, options, distance)
    lib.print('AddModelTarget called but no target module is configured (Config.Target = "none")')
end

function impl.RemoveZone(id) end
function impl.RemoveEntityTarget(entity, options) end
