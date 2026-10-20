-- ESX's own /giveweapon is permanently disabled server-wide by `if not Config.CustomInventory then` in
-- es_extended/server/modules/commands.lua, since this server runs ox_inventory instead. `restricted = true`
-- below makes FXServer gate this the same way every other admin command here already is - via the standard
-- add_ace/add_principal group.admin grants in server.cfg, nothing new to configure.
local rps = exports.rps_lib

local function reply(source, msg)
    if source == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', source, { args = { 'Admin', msg } })
    end
end

RegisterCommand('giveweapon', function(source, args)
    local targetId = tonumber(args[1])
    local weapon = args[2] and args[2]:upper() or nil
    local ammo = tonumber(args[3]) or 250

    if not targetId or not weapon then
        reply(source, 'Usage: giveweapon <playerId> <weaponName> [ammo]  e.g. giveweapon 1 WEAPON_COMBATPISTOL 250')
        return
    end

    if GetPlayerName(targetId) == nil then
        reply(source, ('No such player id: %s'):format(args[1]))
        return
    end

    local ok = rps:AddItem(targetId, weapon, 1, { ammo = ammo })

    if ok then
        reply(source, ('Gave %s (%d ammo) to player %s.'):format(weapon, ammo, targetId))
        if targetId ~= source then
            reply(targetId, ('You were given a %s.'):format(weapon))
        end
    else
        reply(source, ('Failed to give %s to player %s - check the weapon name (e.g. WEAPON_COMBATPISTOL) and that they have inventory room.'):format(weapon, targetId))
    end
end, true)
