-- Your own framework adapter (server). Files in bridge/custom/server/ load automatically — nothing else to edit.
-- This example does nothing until you set ENABLED = true. Copy it (e.g. myframework.lua), fill in the functions for
-- your framework and restart opslabs-phone: the console prints "Framework: My Framework (detected) · custom adapter".
-- Full reference: bridge/README.md. Every function is optional except detect and GetPlayer; missing ones fall back
-- to safe defaults (no money, no admin, …). Errors inside them are caught and reported once.

local ENABLED = false
if not ENABLED then return end

local A = {
    label = 'My Framework',      -- shown in the console
    resource = 'my_core',        -- the framework's resource (detection waits while it is starting)
}

-- true when this framework is running (custom adapters are checked before the built-in ones)
function A.detect() return GetResourceState('my_core') == 'started' end

-- optional: check the framework really works; return false, 'why' to fall back to standalone
function A.init()
    return exports.my_core ~= nil
end

-- REQUIRED: the player's character. identifier must be stable per character (it keys their phone number).
function A.GetPlayer(src)
    local p = exports.my_core:GetPlayer(src)
    if not p then return nil end
    return {
        identifier = p.citizenId,
        firstname = p.firstName, lastname = p.lastName,          -- or name = 'Full Name'
        job = { name = p.job, label = p.jobLabel, grade = { level = p.grade, name = p.gradeLabel } },
    }
end

-- money (account is 'bank' or 'cash'). Return true when done. RemoveMoney is only called after GetMoney said
-- there's enough, but it should still refuse an overdraft itself.
function A.GetMoney(src, account) return exports.my_core:GetMoney(src, account) end
function A.AddMoney(src, amount, account, reason) return exports.my_core:AddMoney(src, account, amount) end
function A.RemoveMoney(src, amount, account, reason) return exports.my_core:RemoveMoney(src, account, amount) end

-- admins: groups is a list of extra group names some callers accept (e.g. { 'owner', 'god' })
function A.IsAdmin(src, groups) return IsPlayerAceAllowed(src, 'command') end

-- character loaded / logged out (character switch). Map each event to the player's server id.
A.events = {
    loaded = { ['my_core:characterLoaded'] = function(src) return src end },
    unloaded = { ['my_core:characterUnloaded'] = function(src) return src end },
}

-- Optional, see bridge/README.md for each:
--   A.GetSource(identifier)                          online server id of a character
--   A.GetOfflineMoney / AddOfflineMoney / RemoveOfflineMoney(identifier, amount, account)   bank transfers to offline players
--   A.AddSocietyMoney / RemoveSocietyMoney(society, amount)                                 business accounts
--   A.ItemCount / AddItem / RemoveItem(src, item, count) and A.UsableItem(item, handler)    if the framework owns items
--   A.Notify(src, message, kind)
--   A.GetBills / TakeBill / RestoreBill / SettleBill,  A.GetVehicles(identifier)            Wallet bills, Garage app
--   A.BackfillNames()                                 one-off: copy names of offline phone owners

Bridge.RegisterFramework('myframework', A)    -- the name you'd put in Config.Framework
