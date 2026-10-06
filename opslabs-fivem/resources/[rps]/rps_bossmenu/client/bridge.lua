-- ============================================
--  rps_lib Bridge (client)
--  Every Bridge function here is a thin wrapper around exports.rps_lib.
--  Requires the standalone rps_lib resource started before this one.
-- ============================================
Bridge = {}

-- ============================================
--  Player Data
-- ============================================
function Bridge.GetPlayerData()
    -- rps_lib's shape: { source, identifier, name, firstname, lastname,
    -- job = { name, label, grade = { level, name }, isboss }, money }
    return exports.rps_lib:GetPlayerData()
end

-- ============================================
--  Notifications
-- ============================================
function Bridge.Notify(msg, type)
    local rpsType = type
    if rpsType == 'primary' or rpsType == 'inform' then rpsType = 'info' end
    exports.rps_lib:Notify(msg, rpsType or 'info')
end

-- ============================================
--  Callbacks
-- ============================================
function Bridge.TriggerCallback(name, cb, ...)
    exports.rps_lib:TriggerServerCallback(name, cb, ...)
end

-- ============================================
--  Progress Bar
-- ============================================
function Bridge.Progressbar(name, label, duration, useWhileDead, canCancel, disableControls, animation, prop, propTwo, onFinish, onCancel)
    local completed = exports.rps_lib:ProgressBar({
        duration = duration,
        label = label,
        useWhileDead = useWhileDead,
        canCancel = canCancel,
        disable = {
            car = disableControls.disableCar,
            move = disableControls.disableMovement,
            combat = disableControls.disableCombat
        },
        anim = animation and {
            dict = animation.animDict,
            clip = animation.anim
        } or nil
    })
    if completed then
        if onFinish then onFinish() end
    else
        if onCancel then onCancel() end
    end
end

-- ============================================
--  Vehicle Utilities
--  (native FiveM calls — no framework/rps_lib export needed)
-- ============================================
function Bridge.SpawnVehicle(model, cb, coords, isNetworked)
    local hash = type(model) == 'string' and joaat(model) or model
    RequestModel(hash)
    while not HasModelLoaded(hash) do Wait(10) end
    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, coords.w or 0.0, isNetworked ~= false, false)
    SetModelAsNoLongerNeeded(hash)
    cb(veh)
end

function Bridge.GetPlate(vehicle)
    return string.gsub(GetVehicleNumberPlateText(vehicle), '^%s*(.-)%s*$', '%1')
end

-- ============================================
--  Targeting
--  rps_lib's target module uses the canonical
--  { name, icon, label, distance?, canInteract?, onSelect? } shape, with no
--  event/serverEvent passthrough (only onSelect survives translation when
--  rps_lib picks qb-target under the hood) — so event-style options are
--  converted into an onSelect that fires the event itself.
-- ============================================
local function ConvertOptions(optionsTable)
    local converted = {}
    local options = optionsTable.options or optionsTable
    local distance = optionsTable.distance or 2.5

    for _, opt in ipairs(options) do
        local newOpt = {
            name = opt.name or opt.label,
            label = opt.label,
            icon = opt.icon,
            distance = opt.distance or distance,
            canInteract = opt.canInteract,
        }
        if opt.action then
            newOpt.onSelect = function(data)
                opt.action(data.entity)
            end
        elseif opt.event then
            -- Pass the full data table (matches ox_target's own native
            -- behavior for event/serverEvent options: it triggers the event
            -- with { entity, coords, ... } as the single argument), not just
            -- the entity — event handlers in this resource read data.entity.
            if opt.type == 'server' then
                newOpt.onSelect = function(data)
                    TriggerServerEvent(opt.event, data)
                end
            else
                newOpt.onSelect = function(data)
                    TriggerEvent(opt.event, data)
                end
            end
        end
        table.insert(converted, newOpt)
    end
    return converted
end

function Bridge.AddCircleZone(name, coords, radius, zoneOptions, targetOptions)
    -- rps_lib only exposes AddBoxZone (no sphere zone), so the circle is
    -- approximated with a square footprint sized off the radius.
    exports.rps_lib:AddBoxZone(name, coords, radius * 2, radius * 2, 0.0, ConvertOptions(targetOptions), targetOptions.distance)
end

function Bridge.AddTargetEntity(entity, targetOptions)
    exports.rps_lib:AddEntityTarget(entity, ConvertOptions(targetOptions), targetOptions.distance)
end

function Bridge.RemoveTargetEntity(entity, labels)
    -- Passed straight through: rps_lib forwards this to ox_target's own
    -- removeLocalEntity (which accepts label names) when ox_target is the
    -- detected backend, and its qb-target integration ignores the second
    -- argument entirely, so plain label strings are safe either way.
    exports.rps_lib:RemoveEntityTarget(entity, labels)
end

function Bridge.AddTargetModel(models, targetOptions)
    exports.rps_lib:AddModelTarget(models, ConvertOptions(targetOptions), targetOptions.distance)
end
