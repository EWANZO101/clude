-- ===== settings =====
local toggleCommand = ''
local enabledByDefault = true

local dotSize = 0.0014             -- center dot size (screen-relative)
local lineLength = 0.0075          -- arm length (normal)
local lineLengthAiming = 0.0035    -- arm length while aiming (tighter = "zoomed" look)
local lineThickness = 0.0016
local gap = 0.0028                 -- gap between center and each arm (normal)
local gapAiming = 0.0012           -- gap while aiming

local mainColor = { r = 255, g = 255, b = 255, a = 220 }
local aimColor = { r = 90, g = 235, b = 140, a = 235 }   -- accent color while aiming
local outlineColor = { r = 0, g = 0, b = 0, a = 160 }    -- soft dark outline for contrast on any background
local outlinePadding = 0.0007      -- how much bigger the outline is than the main shape

-- EXPERIMENTAL: attempts to zoom the actual gameplay camera while aiming
-- using an undocumented native. Behavior isn't officially confirmed, so
-- it's off by default -- test it yourself and tune cameraZoomDistance if
-- you turn it on. Leaving this false just gives you the crosshair-tighten
-- visual above, which always works.
local useCameraZoom = false
local cameraZoomDistance = 5.0     -- lower = more "zoomed in" look, tune to taste
-- =====================

local enabled = enabledByDefault
local isCameraZoomed = false

-- draws a rect with a soft dark outline behind it so the crosshair stays
-- visible against light or dark backgrounds
local function drawOutlinedRect(x, y, w, h, c)
    DrawRect(x, y, w + outlinePadding, h + outlinePadding, outlineColor.r, outlineColor.g, outlineColor.b, outlineColor.a)
    DrawRect(x, y, w, h, c.r, c.g, c.b, c.a)
end

local function drawCrosshair(aiming)
    local aspect = GetAspectRatio(false)
    local cx, cy = 0.5, 0.5
    local len = aiming and lineLengthAiming or lineLength
    local g = aiming and gapAiming or gap
    local c = aiming and aimColor or mainColor

    -- center dot
    drawOutlinedRect(cx, cy, dotSize, dotSize * aspect, c)

    -- top / bottom / left / right arms
    drawOutlinedRect(cx, cy - g - len * 0.5, lineThickness, len, c)
    drawOutlinedRect(cx, cy + g + len * 0.5, lineThickness, len, c)
    drawOutlinedRect(cx - g - len * 0.5, cy, len, lineThickness * aspect, c)
    drawOutlinedRect(cx + g + len * 0.5, cy, len, lineThickness * aspect, c)
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weaponHash = GetSelectedPedWeapon(ped)
        local hasWeapon = weaponHash ~= `WEAPON_UNARMED`
        local aiming = hasWeapon and IsPlayerFreeAiming(PlayerId())

        if enabled and hasWeapon then
            drawCrosshair(aiming)
        end

        if useCameraZoom then
            if aiming and not isCameraZoomed then
                isCameraZoomed = true
                AnimateGameplayCamZoom(0.2, cameraZoomDistance)
            elseif not aiming and isCameraZoomed then
                isCameraZoomed = false
                AnimateGameplayCamZoom(0.2, 60.0)
            end
        end

        Wait((enabled and hasWeapon) and 0 or 250)
    end
end)

RegisterCommand(toggleCommand, function()
    enabled = not enabled
    exports.rps_lib:Notify(enabled and 'Crosshair enabled.' or 'Crosshair disabled.', 'inform')
end, false)
