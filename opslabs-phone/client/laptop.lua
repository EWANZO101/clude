-- Laptop: OPS OS desktop on a placed laptop (opslabs-towers finds the laptop and calls
-- OpenLaptop). Same apps and accounts as the phone; online only over the laptop's Ethernet.

local PREFIX = 'opslabs-phone:'
LaptopOpen = false
local laptopId, laptopPos

local ANIM_DICT, ANIM = 'anim@heists@prison_heiststation@cop_reactions', 'cop_b_idle'

local function stopAnim()
    StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM, 2.0)
end

function CloseLaptop()
    if not LaptopOpen then return end
    LaptopOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'laptop', data = { open = false } })
    LocalPlayer.state:set('opsLaptop', false, false)
    stopAnim()
    lib.callback('opslabs-phone:laptopClose', false, function() end)
    laptopId, laptopPos = nil, nil
end

local function canUse()
    local ped = PlayerPedId()
    if IsPauseMenuActive() or IsEntityDead(ped) or LocalPlayer.state.isDead or IsPedCuffed(ped) then return false end
    if IsPedInAnyVehicle(ped, false) then return false end
    return true
end

local opening = false
local function openLaptop(id, pos)
    if LaptopOpen or opening or not canUse() then return end
    opening = true
    if PhoneOpen then ClosePhone() end
    if not Preload() then
        opening = false
        lib.notify({ type = 'error', description = 'OPS OS is still starting — try again in a moment' })
        return
    end
    local res = lib.callback.await('opslabs-phone:laptopOpen', false, id)
    opening = false
    if not res or res.error then
        local why = res and res.error
        lib.notify({ type = 'error', description = why == 'too_far' and 'Get closer to the laptop'
            or why == 'battery' and 'The laptop\'s battery is flat. Put a laptop charger beside it, plugged into a live socket.'
            or 'This laptop isn\'t working' })
        return
    end
    LaptopOpen = true
    laptopId, laptopPos = id, pos
    LocalPlayer.state:set('opsLaptop', id, false)

    local ped = PlayerPedId()
    TaskTurnPedToFaceCoord(ped, pos.x, pos.y, pos.z, 700)
    SetTimeout(700, function()
        if not LaptopOpen then return end
        lib.requestAnimDict(ANIM_DICT)
        TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM, 3.0, 3.0, -1, 49, 0, false, false, false)
    end)

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'laptop', data = { open = true, id = id, net = res.net } })

    CreateThread(function()
        local nextCheck = 0
        while LaptopOpen do
            DisableControlAction(0, 200, true)   -- ESC is handled by the desktop
            DisableControlAction(0, 199, true)
            local now = GetGameTimer()
            if now >= nextCheck then
                nextCheck = now + 400
                local p = GetEntityCoords(PlayerPedId())
                if not canUse() or #(p - laptopPos) > 3.0 then CloseLaptop() end
                -- keep typing if something interrupted the animation
                if LaptopOpen and not IsEntityPlayingAnim(PlayerPedId(), ANIM_DICT, ANIM, 3) then
                    if HasAnimDictLoaded(ANIM_DICT) then TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM, 3.0, 3.0, -1, 49, 0, false, false, false) end
                end
            end
            Wait(0)
        end
    end)
end
-- called from opslabs-towers ([E] at a laptop): waits on the server, so it runs in its own thread
exports('OpenLaptop', function(id, pos) CreateThread(function() openLaptop(tonumber(id), vector3(pos.x, pos.y, pos.z)) end) end)
exports('CloseLaptop', CloseLaptop)
exports('IsLaptopOpen', function() return LaptopOpen end)

RegisterNUICallback('laptopClose', function(_, cb)
    CloseLaptop()
    cb(true)
end)

RegisterNetEvent('esx:onPlayerLogout', CloseLaptop)
RegisterNetEvent('esx:playerLoaded', CloseLaptop)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and LaptopOpen then
        SetNuiFocus(false, false)
        stopAnim()
        LocalPlayer.state:set('opsLaptop', false, false)
    end
end)
