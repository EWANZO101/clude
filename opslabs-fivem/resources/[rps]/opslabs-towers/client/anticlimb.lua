-- Anti-climb zones: next to any fence panel, post or gate you can't jump, climb or vault over it.
-- If the game starts a climb anyway (e.g. from a run-up), it is cancelled and you're nudged back.

local AC = Config.AntiClimb or {}
if AC.Enabled == false then return end
local SEG = AC.Segments or {}
local DIST = AC.Distance or 1.4
local near = {}             -- world segments close enough to matter: { ax, ay, bx, by, z, fixtureId }
local sides = {}            -- fixtureId -> which side of it you were on before trying to climb

CreateThread(function()
    while true do
        Wait(500)
        local p = GetEntityCoords(PlayerPedId())
        local list = {}
        for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
            local s = SEG[f.model]
            if s and math.abs(f.x - p.x) < 25.0 and math.abs(f.y - p.y) < 25.0 and math.abs(f.z - p.z) < 6.0 then
                local h = math.rad(f.heading or 0.0)
                local c, sn = math.cos(h), math.sin(h)
                list[#list + 1] = { f.x + s[1] * c, f.y + s[1] * sn, f.x + s[2] * c, f.y + s[2] * sn, f.z, f.id }
            end
        end
        near = list
    end
end)

local function distToSeg(px, py, s)
    local ax, ay, bx, by = s[1], s[2], s[3], s[4]
    local dx, dy = bx - ax, by - ay
    local L2 = dx * dx + dy * dy
    local t = L2 > 0 and math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2)) or 0.0
    local cx, cy = ax + dx * t, ay + dy * t
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2), cx, cy
end

CreateThread(function()
    local warned = 0
    while true do
        if #near == 0 then
            Wait(400)
        else
            Wait(0)
            local ped = PlayerPedId()
            local p = GetEntityCoords(ped)
            local hit, hx, hy, seg
            for _, s in ipairs(near) do
                if p.z > s[5] - 1.0 and p.z < s[5] + 4.0 then
                    local d, cx, cy = distToSeg(p.x, p.y, s)
                    if d < DIST then hit, hx, hy, seg = d, cx, cy, s break end
                end
            end
            if hit and not IsPedInAnyVehicle(ped, false) then
                DisableControlAction(0, 22, true)                    -- jump / climb
                -- which side of the fence you're on (remembered while you're not climbing)
                local nx, ny = -(seg[4] - seg[2]), seg[3] - seg[1]
                local nl = math.sqrt(nx * nx + ny * ny)
                nx, ny = nx / nl, ny / nl
                local climbing = IsPedClimbing(ped) or IsPedVaulting(ped)
                if not climbing then
                    sides[seg[6]] = ((p.x - hx) * nx + (p.y - hy) * ny) >= 0 and 1 or -1
                else
                    ClearPedTasksImmediately(ped)
                    local side = sides[seg[6]] or (((p.x - hx) * nx + (p.y - hy) * ny) >= 0 and 1 or -1)
                    SetEntityCoordsNoOffset(ped, hx + nx * side * (DIST + 0.2), hy + ny * side * (DIST + 0.2), p.z, false, false, false)
                    if GetGameTimer() - warned > 4000 then
                        warned = GetGameTimer()
                        lib.notify({ type = 'error', description = 'Anti-climb fence — you can’t get over it. Use the gate.' })
                    end
                end
            end
        end
    end
end)
