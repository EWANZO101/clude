-- Standalone: no framework. The phone still works — identifiers are FiveM license ids, names are the player's
-- FiveM name, and there are no jobs, money or items (Wallet shows $0, the item check is skipped). Admins are players
-- with the opslabs.admin ACE (add_ace group.admin opslabs.admin allow).

local A = { label = 'Standalone', status = 'verified', builtin = true }

function A.detect() return true end

function A.GetPlayer(src)
    local id = GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifierByType(src, 'fivem')
    if not id then return nil end
    return { identifier = id, name = GetPlayerName(src) }
end

function A.IsAdmin(src) return IsPlayerAceAllowed(src, 'command') end

-- standalone has no character select: a player is "loaded" once they're in the server
A.events = {
    loaded = { ['playerJoining'] = function() return source end },
    unloaded = {},
}

Bridge.RegisterFramework('standalone', A)
