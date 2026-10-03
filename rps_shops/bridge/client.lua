-- ============================================
--  rps_lib Bridge (client)
--  Notifications go through rps_lib (ox_lib / codem / framework fallback).
--  Item images are resolved from the inventory rps_lib detected.
--  Targeting goes through rps_lib (ox_target / tgiann-target / qb-target).
-- ============================================
Bridge = {}

local rps = exports.rps_lib

--- type: 'success' | 'error' | 'inform'/'info'
function Bridge.Notify(msg, type, title)
    if type == 'inform' or not type then type = 'info' end
    rps:ShowNotification({ title = title or Config.DefaultLocale.ShopTitle, description = msg, type = type })
end

function Bridge.GetItemImage(item)
    local inventory = rps:GetInventoryName()
    local path = Config.ItemImages[inventory] or Config.ItemImages.default

    return path:format(item)
end

--- rps_lib detects the target resource asynchronously and reports 'none'
--- until it's done, so give it a moment before registering anything.
function Bridge.WaitForTarget()
    local timeout = GetGameTimer() + 5000

    while rps:GetTargetName() == 'none' and GetGameTimer() < timeout do
        Wait(100)
    end

    if rps:GetTargetName() == 'none' then
        print('^3[rps_shops]^7 No target resource detected by rps_lib - shops will not be interactable.')
    end
end

--- options: { { name, icon, label, distance?, canInteract?, onSelect? }, ... }
function Bridge.AddEntityTarget(entity, options, distance)
    rps:AddEntityTarget(entity, options, distance)
end

function Bridge.RemoveEntityTarget(entity, options)
    rps:RemoveEntityTarget(entity, options)
end

--- size: vec3(width, length, height). rps_lib uses its own zone height.
function Bridge.AddBoxZone(name, coords, size, heading, options, distance)
    return rps:AddBoxZone(name, coords, size.y, size.x, heading, options, distance)
end

function Bridge.RemoveZone(id)
    rps:RemoveZone(id)
end
