--[[
    client/3dtext.lua
    Draws world-space "3D" text billboarded to face the camera, with
    distance-based scale/fade, an optional outline, and an optional
    background plate sized to fit the text. Call it every frame the text
    should be visible (e.g. from inside a CreateThread loop) — it draws a
    single frame and manages no state or thread of its own.

    Uses SetDrawOrigin rather than manual world-to-screen math: the game
    handles perspective/occlusion-correct projection for you, it's
    resolution-independent, and text naturally disappears behind geometry.
    Client-only — these natives don't exist server-side.

    Also exposes an "advanced" persistent mode further down (lib.addText3D/
    lib.removeText3D) for callers who'd rather register a point once than
    hand-roll their own CreateThread/Wait loop and distance check.
]]

lib = lib or {}

local DEFAULTS = {
    scale = 0.35,
    font = 4,
    color = { 255, 255, 255, 215 },
    outline = true,
    background = true,
    backgroundColor = { 0, 0, 0, 155 },
    maxDistance = 10.0,
    fadeDistance = 2.5,
    lineSpacing = 0.03,
    bobAmplitude = 0.05,
    bobSpeed = 2.0,
    accentColor = { 255, 205, 70 }
}

--- Draws 3D text at world coordinates. Call every frame the text should be
--- visible — it does not persist or manage its own thread. Supports '\n'
--- for multiple centered lines.
--- @param coords vector3|{x=, y=, z=}
--- @param text string
--- @param options table|nil {
---     scale           number   base text scale                  (default 0.35)
---     font            number   GTA text font id                 (default 4)
---     color           {r,g,b,a} text colour                     (default {255,255,255,215})
---     outline         boolean  adds an outline + drop shadow     (default true)
---     background      boolean  draws a plate sized to the text  (default true)
---     backgroundColor {r,g,b,a} plate colour                    (default {0,0,0,155})
---     maxDistance     number   stop drawing beyond this distance from the camera (default 10.0)
---     fadeDistance    number   fade out over this many units before maxDistance  (default 2.5)
---     lineSpacing     number   vertical gap between lines                       (default 0.03)
---     bob             boolean  gentle up/down floating animation               (default false)
---     bobAmplitude    number   how far it floats, in world units               (default 0.05)
---     bobSpeed        number   how fast it bobs                                (default 2.0)
---     marker          boolean  small pulsing ground marker beneath the text    (default false)
---     markerColor     {r,g,b}  marker tint                                     (default text color's rgb)
---     fancy           boolean  premium card look: breathing glow halo, an      (default false)
---                              accent border frame, and an accent-coloured
---                              title line (the first line if multi-line,
---                              otherwise the whole text)
---     accentColor     {r,g,b}  accent used by `fancy` (glow/border/title)      (default {255,205,70}, gold)
--- }
--- @return boolean drawn — false if culled by maxDistance or fully faded out
function lib.drawText3D(coords, text, options)
    options = options or {}
    local scale = options.scale or DEFAULTS.scale
    local font = options.font or DEFAULTS.font
    local color = options.color or DEFAULTS.color
    local outline = options.outline
    if outline == nil then outline = DEFAULTS.outline end
    local background = options.background
    if background == nil then background = DEFAULTS.background end
    local backgroundColor = options.backgroundColor or DEFAULTS.backgroundColor
    local maxDistance = options.maxDistance or DEFAULTS.maxDistance
    local fadeDistance = lib.math.clamp(options.fadeDistance or DEFAULTS.fadeDistance, 0.1, maxDistance)
    local lineSpacing = options.lineSpacing or DEFAULTS.lineSpacing
    local fancy = options.fancy == true
    local accentColor = options.accentColor or DEFAULTS.accentColor

    local textCoords = vector3(coords.x, coords.y, coords.z)

    if options.bob then
        local amplitude = options.bobAmplitude or DEFAULTS.bobAmplitude
        local speed = options.bobSpeed or DEFAULTS.bobSpeed
        local zOffset = math.sin((GetGameTimer() / 1000) * speed) * amplitude
        textCoords = vector3(textCoords.x, textCoords.y, textCoords.z + zOffset)
    end

    local dist = #(GetFinalRenderedCamCoord() - textCoords)

    if dist >= maxDistance then return false end

    -- Fade + shrink slightly as it approaches maxDistance, for a smoother
    -- pop-in/out than a hard cutoff.
    local fadeStart = maxDistance - fadeDistance
    local fadeMult = dist > fadeStart and lib.math.clamp(1 - (dist - fadeStart) / fadeDistance, 0, 1) or 1
    local drawScale = scale * lib.math.clamp(1 - (dist / maxDistance) * 0.35, 0.55, 1.0)
    local alpha = math.floor(color[4] * fadeMult)

    if alpha <= 0 then return false end

    local lines = lib.string.split(text, '\n')
    local lineCount = #lines
    local maxLineLen = 0
    for i = 1, lineCount do
        maxLineLen = math.max(maxLineLen, #lines[i])
    end

    SetDrawOrigin(textCoords.x, textCoords.y, textCoords.z, 0)

    local widthFactor = (maxLineLen * (drawScale / 0.35)) / 370
    local boxWidth = 0.018 + widthFactor + (fancy and 0.006 or 0)

    -- Each line's real rendered height (title line is scaled up under `fancy`,
    -- so it's taller than the rest — measure each individually rather than
    -- assuming they all match). Stacked with `lineSpacing` as the gap between
    -- lines, this total is what both the box and the text below derive their
    -- vertical position from, so they're guaranteed to agree instead of relying
    -- on two independent approximations lining up by luck.
    local titleScale = drawScale * 1.08
    local lineHeights = {}
    local totalTextHeight = 0
    for i = 1, lineCount do
        local isTitle = fancy and i == 1
        local h = GetTextScaleHeight(isTitle and titleScale or drawScale, font)
        lineHeights[i] = h
        totalTextHeight = totalTextHeight + h
    end
    local totalHeight = totalTextHeight + math.max(lineCount - 1, 0) * lineSpacing
    local boxHeight = totalHeight + 0.015

    -- Fancy: a soft halo that slowly breathes behind the plate, drawn first
    -- so everything else layers on top of it.
    if fancy then
        local pulse = 0.5 + 0.5 * math.sin((GetGameTimer() / 1000) * 2.2)
        local glowAlpha = math.floor(35 * fadeMult * (0.5 + 0.5 * pulse))
        if glowAlpha > 0 then
            local glowGrow = 0.008 + 0.006 * pulse
            DrawRect(0.0, 0.0, boxWidth + glowGrow, boxHeight + glowGrow, accentColor[1], accentColor[2], accentColor[3], glowAlpha)
        end
    end

    -- Background plate so the text draws on top of it, not under it.
    if background then
        local bgAlpha = math.floor((backgroundColor[4] or 155) * fadeMult)
        if bgAlpha > 0 then
            DrawRect(0.0, 0.0, boxWidth, boxHeight, backgroundColor[1], backgroundColor[2], backgroundColor[3], bgAlpha)
        end
    end

    -- Fancy: a thin accent border framing the plate — 4 edge strips rather
    -- than a single outlined rect, since DrawRect can't stroke-only.
    if fancy and background then
        local borderAlpha = math.floor(200 * fadeMult)
        local borderThickness = 0.0025
        DrawRect(0.0, -boxHeight / 2, boxWidth, borderThickness, accentColor[1], accentColor[2], accentColor[3], borderAlpha)
        DrawRect(0.0, boxHeight / 2, boxWidth, borderThickness, accentColor[1], accentColor[2], accentColor[3], borderAlpha)
        DrawRect(-boxWidth / 2, 0.0, borderThickness, boxHeight, accentColor[1], accentColor[2], accentColor[3], borderAlpha)
        DrawRect(boxWidth / 2, 0.0, borderThickness, boxHeight, accentColor[1], accentColor[2], accentColor[3], borderAlpha)
    end

    -- Text is drawn top-anchored (SetTextCentre only centers horizontally),
    -- so lines are stacked from the top of the block (-totalHeight/2) downward
    -- by each line's own real height, rather than centering each line's
    -- assumed-uniform box around a symmetric offset — that broke down as soon
    -- as the title line (fancy) had a different height than the rest.
    -- Fancy: the first line (or the whole text, if it's one line) is the
    -- "title" — drawn a touch larger, tinted in accentColor — everything
    -- after it is the "subtitle", in the normal text colour.
    --
    -- Every formatting setter (font/proportional/centre/outline/scale/colour)
    -- is re-applied inside the loop, immediately before each
    -- EndTextCommandDisplayText — the game resets that state after every
    -- Display call, so setting them once outside the loop only centered the
    -- first line and left the rest left-aligned.
    local cursorY = -totalHeight / 2
    for i = 1, lineCount do
        local lineY = cursorY
        local isTitle = fancy and i == 1
        local lineScale = isTitle and titleScale or drawScale
        local lineColor = isTitle and accentColor or color
        SetTextFont(font)
        SetTextProportional(true)
        SetTextCentre(true)
        if outline then
            SetTextOutline()
            SetTextDropshadow(1, 0, 0, 0, alpha)
        end
        SetTextScale(lineScale, lineScale)
        SetTextColour(lineColor[1], lineColor[2], lineColor[3], alpha)
        SetTextEntry('STRING')
        AddTextComponentString(lines[i])
        EndTextCommandDisplayText(0.0, lineY)
        cursorY = cursorY + lineHeights[i] + lineSpacing
    end

    ClearDrawOrigin()

    -- Marker is drawn in real world space (unlike the text/background above,
    -- which are relative to SetDrawOrigin), so it's drawn after ClearDrawOrigin.
    if options.marker then
        local mColor = options.markerColor or color
        DrawMarker(1, textCoords.x, textCoords.y, textCoords.z - 0.9,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.4, 0.4, 0.5,
            mColor[1], mColor[2], mColor[3], math.floor(120 * fadeMult),
            true, false, 2, false, nil, nil, false)
    end

    return true
end

--- Convenience wrapper for a plain label with no background plate — handy
--- for quick debug markers (ped names, waypoint labels, etc).
--- @param coords vector3|{x=, y=, z=}
--- @param text string
--- @param color {r,g,b,a}|nil
--- @return boolean drawn
function lib.drawText3DSimple(coords, text, color)
    return lib.drawText3D(coords, text, { background = false, color = color })
end

-- fxmanifest.lua lists 'DrawText3D'/'DrawText3DSimple' as exports, but
-- declaring a name there is only metadata — it doesn't register the
-- export by itself. These lib.* fields aren't plain globals (unlike
-- Notify/AddBoxZone/etc., which register themselves in client/client.lua),
-- so they need an explicit exports() call here to actually work.
exports('DrawText3D', lib.drawText3D)
exports('DrawText3DSimple', lib.drawText3DSimple)

-- ─────────────────────────────────────────────
-- Advanced: persistent registered points. Register once with lib.addText3D
-- instead of hand-rolling your own CreateThread/Wait loop — a single shared
-- thread redraws every registered point every frame, using lib.drawText3D
-- under the hood (so it inherits every option above, including bob/marker).
-- It sleeps at 0ms only while at least one point is actually being drawn
-- (in range and not culled), and backs off to 500ms otherwise, so idle
-- points registered far from the player cost almost nothing.
-- ─────────────────────────────────────────────

local points = {}
local pointCount = 0
local threadRunning = false

local function startPointsThread()
    if threadRunning then return end
    threadRunning = true
    CreateThread(function()
        while pointCount > 0 do
            local anyDrawn = false
            for _, point in pairs(points) do
                if lib.drawText3D(point.coords, point.text, point.options) then
                    anyDrawn = true
                end
            end
            Wait(anyDrawn and 0 or 500)
        end
        threadRunning = false
    end)
end

--- Registers a persistent 3D text point — the library redraws it every
--- frame on its own from here on, with no loop for you to manage. Calling
--- this again with the same id replaces that point's coords/text/options.
--- @param id string|number unique key for this point (pass to removeText3D)
--- @param coords vector3|{x=, y=, z=}
--- @param text string
--- @param options table|nil same shape as lib.drawText3D's options
function lib.addText3D(id, coords, text, options)
    if points[id] == nil then
        pointCount = pointCount + 1
    end
    points[id] = { coords = coords, text = text, options = options }
    startPointsThread()
end

--- Removes a point previously registered with lib.addText3D. Safe to call
--- on an id that was never registered (or already removed) — it's just a no-op.
--- @param id string|number
function lib.removeText3D(id)
    if points[id] ~= nil then
        points[id] = nil
        pointCount = pointCount - 1
    end
end

--- True if a point with this id is currently registered.
--- @param id string|number
--- @return boolean
function lib.hasText3D(id)
    return points[id] ~= nil
end
