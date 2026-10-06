-- Poles: the ones placed with /cable plus the GTA map's own telegraph poles
-- (Config.Cabling.WorldPoles). Everything that climbs, leans ladders, clamps cable or fits
-- kit goes through AllPoles(), so both kinds behave the same.

local CC = Config.Cabling
local SET = {}
for _, m in ipairs(CC.WorldPoles or {}) do SET[joaat(m)] = m end
local PLACED_H = Config.Cabling.PoleHeights
local world, dims = {}, {}

-- map poles near the player, refreshed every 2 s (cheap: one pass over the object pool)
CreateThread(function()
    while true do
        if next(SET) then
            local pos = GetEntityCoords(PlayerPedId())
            local list = {}
            for _, e in ipairs(GetGamePool('CObject')) do
                local h = GetEntityModel(e)
                if SET[h] then
                    local c = GetEntityCoords(e)
                    if #(pos - c) < 150.0 then
                        local d = dims[h]
                        if not d then
                            local mn, mx = GetModelDimensions(h)
                            d = { mn.z, mx.z - mn.z }
                            dims[h] = d
                        end
                        list[#list + 1] = { world = true, id = -e, ent = e, model = SET[h], x = c.x, y = c.y, z = c.z + d[1], H = d[2] }
                    end
                end
            end
            world = list
        end
        Wait(2000)
    end
end)

--- every pole near enough to matter: { id, model, x, y, z (base), H (height), world? }
function AllPoles()
    local out = {}
    for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        local H = PLACED_H[f.model]
        if H then
            out[#out + 1] = { id = id, model = f.model, x = f.x, y = f.y, z = f.z, H = H, heading = f.heading }
        elseif f.model == 'opslabs_wall_anchor' then
            -- eyebolt in the brickwork: cable clamps to its eye, 6 cm out from the wall
            local h = math.rad(f.heading or 0.0)
            out[#out + 1] = { id = id, model = f.model, x = f.x + 0.06 * math.sin(h), y = f.y - 0.06 * math.cos(h), z = f.z, H = 0.08, house = true, anchor = true }
        elseif f.model == 'opslabs_house_pole' then
            -- short pole on a wall bracket: its tube stands 12 cm out from the wall
            local h = math.rad(f.heading or 0.0)
            out[#out + 1] = { id = id, model = f.model, x = f.x + 0.12 * math.sin(h), y = f.y - 0.12 * math.cos(h), z = f.z, H = 1.63, house = true }
        end
    end
    for _, p in ipairs(world) do
        if DoesEntityExist(p.ent) then out[#out + 1] = p end
    end
    return out
end

--- pole radius at a height above its base (map poles are a steady ~13 cm)
function PoleRadius(p, zAbove)
    if p.anchor then return 0.01 end
    if p.house then return 0.026 end
    if p.world then return 0.13 end
    local rb, rt = 0.115 + p.H * 0.002, 0.075
    if p.model == 'opslabs_pole_metal' then rb, rt = 0.11, 0.065 elseif p.model == 'opslabs_pole_roof' then rb, rt = 0.09, 0.065 elseif p.model and p.model:find('^opslabs_power_pole_') then rb, rt = 0.14, 0.09 end
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, (zAbove or 0) / p.H))
end
