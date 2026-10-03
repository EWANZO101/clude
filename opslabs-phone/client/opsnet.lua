-- Ops-Networks Wi-Fi range test: casts horizontal rays from the player at
-- access-point height, cuts the range for every wall / object a ray passes
-- through, and draws the estimated coverage in the world for a short while.
-- (The server only hands out the model list to engineers with rangetest.use.)

local RAYS_MIN, RAYS_MAX = 16, 24
local AP_HEIGHT = 1.4          -- metres above the ped's root (~2.4 m above the floor)
local WALL_FACTOR = 0.5        -- signal left after passing through an obstacle
local WALL_LOSS = 3.0          -- plus a fixed loss in metres per obstacle
local MAX_HITS = 5
local SHOW_SECONDS = 30
local FLAGS = 1 | 16           -- world + objects

local drawing = nil            -- { origin, points, untilAt }

local function probe(from, to, ped)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, FLAGS, ped, 7)
    local _, hit, endCoords = GetShapeTestResult(handle)
    return hit == 1 or hit == true, endCoords
end

local function castRay(origin, dir, range, ped)
    local pos, budget, travelled, walls = origin, range, 0.0, 0
    while budget > 0.5 do
        local target = pos + dir * budget
        local hit, at = probe(pos, target, ped)
        if not hit or not at then
            travelled = travelled + budget
            break
        end
        local d = #(at - pos)
        travelled = travelled + d
        walls = walls + 1
        if walls >= MAX_HITS then break end
        budget = (budget - d) * WALL_FACTOR - WALL_LOSS
        pos = at + dir * 0.4
        travelled = travelled + 0.4
    end
    return math.min(travelled, range), walls
end

local function drawLoop()
    local mine = drawing
    CreateThread(function()
        while drawing == mine and GetGameTimer() < mine.untilAt do
            local o, pts = drawing.origin, drawing.points
            local n = #pts
            for i = 1, n do
                local a, b = pts[i], pts[i % n + 1]
                local r, g = a.color[1], a.color[2]
                DrawLine(a.pos.x, a.pos.y, a.pos.z, b.pos.x, b.pos.y, b.pos.z, r, g, 60, 230)
                DrawLine(a.pos.x, a.pos.y, a.pos.z - 1.2, b.pos.x, b.pos.y, b.pos.z - 1.2, r, g, 60, 120)
                DrawLine(o.x, o.y, o.z, a.pos.x, a.pos.y, a.pos.z, 80, 170, 255, 50)
                DrawMarker(1, a.pos.x, a.pos.y, a.pos.z - 1.6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.25, 1.6, r, g, 60, 140, false, false, 2, false, nil, nil, false)
            end
            DrawMarker(28, o.x, o.y, o.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3, 80, 170, 255, 200, false, false, 2, false, nil, nil, false)
            Wait(0)
        end
        if drawing == mine then drawing = nil end
    end)
end

RegisterNUICallback('opsnetRangeTest', function(body, cb)
    local range = math.max(5.0, math.min(1000.0, tonumber(body and body.range) or 40.0))
    local rays = math.floor(math.max(RAYS_MIN, math.min(RAYS_MAX, tonumber(body and body.rays) or 20)))
    CreateThread(function()
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        local origin = vector3(c.x, c.y, c.z + AP_HEIGHT)
        local results, points = {}, {}
        local sum, minD, maxD = 0.0, range, 0.0
        for i = 1, rays do
            local ang = (i - 1) * (360.0 / rays)
            local rad = math.rad(ang)
            local dir = vector3(math.sin(rad), math.cos(rad), 0.0) -- 0° = north
            local d, walls = castRay(origin, dir, range, ped)
            results[#results + 1] = { angle = ang, distance = math.floor(d * 10 + 0.5) / 10, walls = walls }
            sum = sum + d
            if d < minD then minD = d end
            if d > maxD then maxD = d end
            local q = d / range
            points[#points + 1] = { pos = origin + dir * d, color = { math.floor(255 * (1 - q)), math.floor(200 * q + 55) } }
            if i % 4 == 0 then Wait(0) end
        end
        drawing = { origin = origin, points = points, untilAt = GetGameTimer() + SHOW_SECONDS * 1000 }
        drawLoop()
        cb({
            range = range, rays = results, seconds = SHOW_SECONDS,
            min = math.floor(minD * 10 + 0.5) / 10, max = math.floor(maxD * 10 + 0.5) / 10,
            avg = math.floor(sum / rays * 10 + 0.5) / 10,
            x = origin.x, y = origin.y, z = origin.z,
        })
    end)
end)

RegisterNUICallback('opsnetRangeClear', function(_, cb)
    drawing = nil
    cb(true)
end)
