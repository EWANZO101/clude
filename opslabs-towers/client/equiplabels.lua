-- Floating name labels over anything OPS has placed nearby (poles, boxes, cabinets, substation and
-- exchange kit, CCTV, solar, POS...) - up close a lot of this equipment looks the same, so this just
-- names whichever fixture you're near, out to a decent distance.

local RANGE = 100.0
local MAX_LABELS = 30   -- nearest-first cap, so a dense area doesn't turn into a wall of text

local function text3d(x, y, z, txt)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.3, 0.3)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(txt)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- defensive: one malformed fixture record anywhere in the whole (large, long-lived) world
-- shouldn't be able to kill this thread forever — wrap each tick and self-heal if it ever does
CreateThread(function()
    while true do
        local ok, err = pcall(function()
            local pos = GetEntityCoords(PlayerPedId())
            local near = {}
            for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
                if f and type(f.x) == 'number' and type(f.y) == 'number' and type(f.z) == 'number' then
                    local d = #(pos - vector3(f.x, f.y, f.z))
                    if d < RANGE then near[#near + 1] = { f = f, d = d } end
                end
            end
            table.sort(near, function(a, b) return a.d < b.d end)
            for i = 1, math.min(#near, MAX_LABELS) do
                local f = near[i].f
                text3d(f.x, f.y, f.z + 1.0, equipLabelFor and equipLabelFor(f.model) or f.model)
            end
            Wait(#near > 0 and 0 or 500)
        end)
        if not ok then
            print(('^1[opslabs-towers] equiplabels: %s^7'):format(tostring(err)))
            Wait(1000)
        end
    end
end)
