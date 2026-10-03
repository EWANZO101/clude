-- Street lights (San Andreas Power & Light) and road works lighting (OPS Openline): at night every
-- placed light nearby gets its `<model>_on` glow model on top (same origin, lenses only) and each
-- lamp throws a real spotlight. Layouts and colours live in Config.Lighting.

local LT = Config.Lighting or { Models = {}, Kinds = {} }
local glows = {}   -- fixture id -> glow entity
local lamps = {}   -- { x, y, z, dx, dy, dz, kind } for the lights currently on

local function isNight()
    local h = GetClockHours()
    if LT.On > LT.Off then return h >= LT.On or h < LT.Off end
    return h >= LT.On and h < LT.Off
end

local function spawnGlow(f)
    local h = joaat(f.model .. '_on')
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 5000)
    local e = CreateObjectNoOffset(h, f.x, f.y, f.z, false, false, false)
    SetEntityHeading(e, f.heading or 0.0)
    SetEntityCoordsNoOffset(e, f.x, f.y, f.z, false, false, false)
    FreezeEntityPosition(e, true)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(h)
    return e
end

local function dropGlow(id)
    if glows[id] and DoesEntityExist(glows[id]) then DeleteEntity(glows[id]) end
    glows[id] = nil
end

-- once a second: which lights are near and lit, glow models in / out, lamp list for the draw loop
CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local night = isNight()
        local want, list = {}, {}
        if night then
            for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
                local L = LT.Models[f.model]
                if L then
                    local dist = #(pos - vector3(f.x, f.y, f.z))
                    if dist < LT.Distance then
                        want[id] = f
                        local h = math.rad(f.heading or 0.0)
                        local c, s = math.cos(h), math.sin(h)
                        for _, p in ipairs(L.pts) do
                            local pr = math.rad(p[4])
                            local ly, lz = -math.cos(pr), -math.sin(pr)        -- lamp faces -Y, tilted down
                            list[#list + 1] = {
                                x = f.x + p[1] * c - p[2] * s, y = f.y + p[1] * s + p[2] * c, z = f.z + p[3],
                                dx = -ly * s, dy = ly * c, dz = lz, kind = LT.Kinds[L.kind], d = dist,
                            }
                        end
                    end
                end
            end
        end
        for id in pairs(glows) do if not want[id] then dropGlow(id) end end
        for id, f in pairs(want) do
            local e = glows[id]
            if not (e and DoesEntityExist(e)) then glows[id] = spawnGlow(f) end
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        for i = #list, (LT.MaxLights or 24) + 1, -1 do list[i] = nil end
        lamps = list
        Wait(1000)
    end
end)

CreateThread(function()
    while true do
        if #lamps == 0 then Wait(500) else
            for _, l in ipairs(lamps) do
                local k = l.kind
                DrawSpotLight(l.x, l.y, l.z, l.dx, l.dy, l.dz, k.rgb[1], k.rgb[2], k.rgb[3], k.range, k.brightness, 0.0, k.cone, k.falloff)
            end
            Wait(0)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(glows) do dropGlow(id) end
end)
