-- Gunshot detection, client side: report your own gunfire (batched every half second; the server decides
-- which OPS Sentinel sensors heard it), and — for police — show incidents on the map.

local CG = Config.Gunshot or {}
if CG.Enabled == false then return end

local GROUPS = {}
for name, key in pairs({ GROUP_PISTOL = 'pistol', GROUP_SMG = 'smg', GROUP_RIFLE = 'rifle', GROUP_MG = 'mg', GROUP_SHOTGUN = 'shotgun',
    GROUP_SNIPER = 'sniper', GROUP_HEAVY = 'heavy' }) do GROUPS[joaat(name) & 0xFFFFFFFF] = key end
local LABEL = { pistol = 'Handgun', smg = 'SMG', rifle = 'Rifle', mg = 'Machine gun', shotgun = 'Shotgun', sniper = 'Sniper rifle', heavy = 'Heavy weapon', mixed = 'Several weapons', other = 'Firearm' }

CreateThread(function()
    local rounds, weapon, silenced, last = 0, nil, false, 0
    while true do
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local w = GetSelectedPedWeapon(ped)
            rounds = rounds + 1
            weapon = GROUPS[GetWeapontypeGroup(w) & 0xFFFFFFFF] or 'other'
            silenced = IsPedCurrentWeaponSilenced(ped)
        end
        if rounds > 0 and GetGameTimer() - last > 500 then
            last = GetGameTimer()
            local c = GetEntityCoords(ped)
            local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(c.x, c.y, c.z))
            TriggerServerEvent('opslabs-towers:gunshot', rounds, weapon, silenced, street ~= '' and street or nil)
            rounds = 0
        end
        Wait(rounds > 0 and 0 or (IsPedArmed(ped, 4) and 0 or 250))
    end
end)

---------------------------------------------------------------------------
-- police: incidents on the map
---------------------------------------------------------------------------

local blips = {}   -- incident id -> { area, centre, expires }

local function drop(id)
    local b = blips[id]
    if not b then return end
    if DoesBlipExist(b.area) then RemoveBlip(b.area) end
    if DoesBlipExist(b.centre) then RemoveBlip(b.centre) end
    blips[id] = nil
end

RegisterNetEvent('opslabs-towers:gunshotAlert', function(i, update)
    drop(i.id)
    local area = AddBlipForRadius(i.x, i.y, i.z, math.max(15.0, i.accuracy + 0.0))
    SetBlipColour(area, 1)
    SetBlipAlpha(area, 110)
    local centre = AddBlipForCoord(i.x, i.y, i.z)
    SetBlipSprite(centre, 110)
    SetBlipColour(centre, 1)
    SetBlipScale(centre, 1.0)
    SetBlipFlashes(centre, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('Shots fired · %d'):format(i.rounds))
    EndTextCommandSetBlipName(centre)
    blips[i.id] = { area = area, centre = centre, expires = GetGameTimer() + (CG.AlertBlipSeconds or 180) * 1000 }
    if not update then
        PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
        lib.notify({ title = 'OPS Sentinel · shots fired', type = 'error', duration = 9000,
            description = ('%d round%s · %s · %s · located to ±%d m by %d sensor%s'):format(i.rounds, i.rounds == 1 and '' or 's', LABEL[i.weapon] or 'Firearm',
                i.street or 'unknown street', math.floor(i.accuracy), i.sensors, i.sensors == 1 and '' or 's') })
    end
end)

RegisterCommand('shotsgps', function()
    local best, bt
    for id, b in pairs(blips) do if not bt or b.expires > bt then best, bt = id, b.expires end end
    if not best then return lib.notify({ type = 'inform', description = 'No recent gunshot alerts' }) end
    local c = GetBlipCoords(blips[best].centre)
    SetNewWaypoint(c.x, c.y)
    lib.notify({ type = 'inform', description = 'GPS set to the latest gunshot alert' })
end, false)

CreateThread(function()
    while true do
        Wait(5000)
        local now = GetGameTimer()
        for id, b in pairs(blips) do if now > b.expires then drop(id) end end
    end
end)
