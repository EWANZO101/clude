-- Laptops: walk up to a placed laptop and press E to use it. OPS OS itself runs in
-- opslabs-phone (same apps and accounts as the phone); this only finds the laptop.

local CL = Config.Laptop or {}
local MODELS = {}
for _, m in ipairs(CL.Models or { 'opslabs_laptop' }) do MODELS[m] = true end
local DIST = CL.UseDistance or 1.3

local function nearestLaptop()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if MODELS[f.model] then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d < (bd or DIST) and math.abs(pos.z - f.z) < 1.8 then best, bd = id, d end
        end
    end
    return best
end

local function phoneReady() return GetResourceState('opslabs-phone') == 'started' end

CreateThread(function()
    local shown = nil
    while true do
        local ped = PlayerPedId()
        local id = phoneReady() and not IsPedInAnyVehicle(ped, false) and not IsPauseMenuActive()
            and not (LocalPlayer.state.opsLaptop) and nearestLaptop()
        NearLaptopId = id or nil              -- client/mains.lua leaves [E] to the laptop
        if id then
            local pw = LaptopPower and LaptopPower(id)
            local text = pw and ('[E] Use laptop · %d%%%s'):format(pw.level, pw.charging and ' charging' or pw.plugged and ' on charger' or '') or '[E] Use laptop'
            if shown ~= text then lib.showTextUI(text, { icon = 'laptop' }) shown = text end
            if IsControlJustPressed(0, 38) then
                lib.hideTextUI() shown = nil
                local f = CablingFixtures()[id]
                exports['opslabs-phone']:OpenLaptop(id, vector3(f.x, f.y, f.z), f.heading or 0.0)
                Wait(500)
            end
            Wait(0)
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(500)
        end
    end
end)
