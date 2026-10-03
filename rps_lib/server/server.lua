--[[
    lib (server)
    Unified server-side API that works the same regardless of framework.
    All framework-specific behavior lives in framework/*.lua — this file
    just delegates to lib.framework.impl.
]]

lib = lib or {}

-- ─────────────────────────────────────────────
-- Player data
-- ─────────────────────────────────────────────

--- Returns a normalized player data table for a given server id, or nil
--- if the player/framework object can't be resolved.
function GetPlayerData(source)
    return lib.framework.impl.GetPlayerData(source)
end

--- Returns just the primary identifier (license/citizenid) for a player.
function GetIdentifier(source)
    return lib.framework.impl.GetIdentifier(source)
end

-- ─────────────────────────────────────────────
-- Notifications
-- ─────────────────────────────────────────────

function Notify(source, message, notifyType)
    lib.framework.impl.Notify(source, message, notifyType or 'info')
end

-- ─────────────────────────────────────────────
-- Money helpers (bank account by default; pass 'cash' for cash)
-- ─────────────────────────────────────────────

function AddMoney(source, amount, account)
    return lib.framework.impl.AddMoney(source, amount, account or 'bank')
end

function RemoveMoney(source, amount, account)
    return lib.framework.impl.RemoveMoney(source, amount, account or 'bank')
end

function GetMoney(source, account)
    return lib.framework.impl.GetMoney(source, account or 'bank')
end

-- ─────────────────────────────────────────────
-- Jobs
-- ─────────────────────────────────────────────

--- Returns the framework's shared job table (name -> job definition). Shape
--- varies by framework (matches QBCore.Shared.Jobs / ESX.GetJobs() / Qbox's
--- own GetJobs() export as-is) — this is a passthrough, not normalized.
function GetJobs()
    return lib.framework.impl.GetJobs()
end

--- Writes a full job assignment to a player. jobData: { name, label, payment,
--- type, isboss, grade = { name, level } }. Applies the real job/grade via the
--- framework's own job-assignment call, then (QBCore/Qbox only) overlays the
--- full jobData table so custom fields like payment/isboss ride along the same
--- way those frameworks' own job objects already support — see the caveat in
--- framework/esx/server.lua: ESX has no per-player job-metadata override, so
--- only jobData.name/grade.level actually take effect there.
function SetPlayerJob(source, jobData)
    return lib.framework.impl.SetPlayerJob(source, jobData)
end

--- Plain job/grade assignment (name + grade level only) — no custom-field
--- overlay, unlike SetPlayerJob above. Leaves label/isboss/grade.name exactly
--- as the framework's own job-assignment call derives them from its shared
--- job table.
function SetJob(source, jobName, grade)
    return lib.framework.impl.SetJob(source, jobName, grade)
end

--- Permission/ACE check — semantics vary by framework: QBCore/Qbox check
--- `permission` as an ACE string via their own HasPermission; ESX ignores it
--- and just checks admin/superadmin group membership; standalone falls back
--- to a native IsPlayerAceAllowed check.
function HasPermission(source, permission)
    return lib.framework.impl.HasPermission(source, permission) == true
end

--- Registers a server-side "use item" handler: handler(source, itemName).
--- Framework detection finishes asynchronously (see framework/init.lua), but
--- registering a useable item is conventionally done at the very top level
--- of a resource's server script — i.e. potentially before that finishes —
--- so a call that arrives too early is queued and flushed automatically
--- once lib.framework.impl becomes available, rather than erroring or
--- silently dropping the registration.
local pendingUseableItems = {}

function CreateUseableItem(item, handler)
    if lib.framework.ready then
        lib.framework.impl.CreateUseableItem(item, handler)
    else
        pendingUseableItems[#pendingUseableItems + 1] = { item, handler }
    end
end

CreateThread(function()
    while not lib.framework.ready do
        Wait(0)
    end
    for _, entry in ipairs(pendingUseableItems) do
        lib.framework.impl.CreateUseableItem(entry[1], entry[2])
    end
    pendingUseableItems = {}
end)

-- ─────────────────────────────────────────────
-- Offline / bulk player queries (delegates to lib.framework.impl). Unlike
-- GetPlayerData, these query the database directly and work for offline
-- players too — requires oxmysql. Character shape:
-- { identifier, name, firstname, lastname, job? }
-- ─────────────────────────────────────────────

--- cb(character | nil)
function GetOfflinePlayer(identifier, cb)
    lib.framework.impl.GetOfflinePlayer(identifier, cb)
end

--- cb(characters) — every player (online or offline) currently in jobName.
function GetEmployeesByJob(jobName, cb)
    lib.framework.impl.GetEmployeesByJob(jobName, cb)
end

--- cb(characters) — the full character roster.
function GetAllCharacters(cb)
    lib.framework.impl.GetAllCharacters(cb)
end

--- Writes a job assignment to an offline player — same per-framework
--- caveats as SetPlayerJob (see above) apply here too. cb(success) is optional.
function SetOfflinePlayerJob(identifier, jobData, cb)
    lib.framework.impl.SetOfflinePlayerJob(identifier, jobData, cb)
end

--- Adds money to an offline player's account (account: 'bank' | 'cash',
--- default 'bank'; ESX has no offline 'cash' representation — see the
--- caveat in framework/esx/server.lua). cb(success) is optional.
function AddOfflinePlayerMoney(identifier, amount, account, cb)
    lib.framework.impl.AddOfflinePlayerMoney(identifier, amount, account or 'bank', cb)
end

-- ─────────────────────────────────────────────
-- Garage (delegates to lib.garage.impl — see integrations/garages/)
-- ─────────────────────────────────────────────

--- cb(vehicles) — vehicles = { { plate, vehicle = <decoded props or nil>, stored (bool), garage? } }
--- Returns an empty list if no garage integration is active.
function GetPlayerVehicles(identifier, cb)
    lib.garage.impl.GetPlayerVehicles(identifier, cb)
end

--- cb(bool)
function IsVehicleStored(plate, cb)
    lib.garage.impl.IsVehicleStored(plate, cb)
end

--- stored: true = mark stored/garaged, false = mark out. cb(success) is optional.
function SetVehicleStored(plate, stored, cb)
    lib.garage.impl.SetVehicleStored(plate, stored, cb)
end

-- ─────────────────────────────────────────────
-- Progress bar (delegates to lib.progressbar.impl — see integrations/progressbar/)
-- ─────────────────────────────────────────────

--- Asks `source`'s client to run a progress bar. cb(completed) is optional —
--- completed is true if the bar finished, false if cancelled.
function ServerProgressBar(source, options, cb)
    lib.progressbar.impl.ProgressBar(source, options, cb)
end

-- ─────────────────────────────────────────────
-- Ambulance job (delegates to lib.ambulance.impl — see integrations/ambulancejob/)
-- ─────────────────────────────────────────────

--- True if that player is dead or downed, per the detected ambulance job
--- integration. Returns false if the player/framework object can't be resolved.
function IsPlayerDead(source)
    return lib.ambulance.impl.IsPlayerDead(source)
end

--- Asks that client to revive itself via the detected ambulance job integration.
function RevivePlayer(source)
    lib.ambulance.impl.RevivePlayer(source)
end

-- ─────────────────────────────────────────────
-- Rich notifications (delegates to lib.notification.impl — see integrations/notifications/)
-- ─────────────────────────────────────────────

--- Shows `source` a rich notification via the detected notification module.
function ShowNotification(source, options)
    lib.notification.impl.Notify(source, options)
end

-- ─────────────────────────────────────────────
-- Inventory (delegates to lib.inventory.impl — see integrations/inventory/)
-- ─────────────────────────────────────────────

function HasItem(source, item, count)
    return lib.inventory.impl.HasItem(source, item, count)
end

function GetItemCount(source, item)
    return lib.inventory.impl.GetItemCount(source, item)
end

--- metadata is optional and passed through to the underlying inventory.
function AddItem(source, item, count, metadata)
    return lib.inventory.impl.AddItem(source, item, count, metadata)
end

function RemoveItem(source, item, count, metadata)
    return lib.inventory.impl.RemoveItem(source, item, count, metadata)
end

--- Returns a normalized list of every item that player is carrying:
--- { { name, count, metadata }, ... }
function GetInventory(source)
    return lib.inventory.impl.GetInventory(source)
end

--- keep (optional): array of item names to leave untouched — only
--- meaningfully honored by ox_inventory, see the caveat in
--- integrations/inventory/qb-inventory/server.lua for the others.
function ClearInventory(source, keep)
    return lib.inventory.impl.ClearInventory(source, keep)
end

--- Only actually validates capacity on ox_inventory — always true on the
--- QBCore-family integrations, see the caveat in
--- integrations/inventory/qb-inventory/server.lua.
function CanCarryItem(source, item, count)
    return lib.inventory.impl.CanCarryItem(source, item, count)
end

--- Returns the item catalog definition for one item name, or nil if unknown /
--- no catalog is available for the active inventory (e.g. 'none', or a
--- framework with no item table at all). Shape varies by inventory — matches
--- ox_inventory's Items() entry or QBCore.Shared.Items' entry as-is.
function GetItemDefinition(item)
    return lib.inventory.impl.GetItemDefinition(item)
end

--- Returns the full item catalog (item name -> definition), or an empty table
--- if none is available for the active inventory.
function GetItemCatalog()
    return lib.inventory.impl.GetItemCatalog()
end

-- ─────────────────────────────────────────────
-- Phone (delegates to lib.phone.impl — see integrations/phone/). Addressed
-- by phone number / identifier rather than source, matching how the
-- underlying phone resources address these actions themselves.
-- ─────────────────────────────────────────────

--- Sends an SMS from senderNumber to receiverNumber.
function SendPhoneMessage(senderNumber, receiverNumber, message)
    lib.phone.impl.SendMessage(senderNumber, receiverNumber, message)
end

--- Starts a phone call from callerNumber to receiveeNumber.
function StartPhoneCall(callerNumber, receiveeNumber)
    lib.phone.impl.StartCall(callerNumber, receiveeNumber)
end

--- Posts a tweet as the given identifier (citizenid/license — same shape as
--- GetIdentifier(source)). image is an optional URL.
function AddPhoneTweet(identifier, message, image)
    lib.phone.impl.AddTweet(identifier, message, image)
end

--- Pushes a banking alert to that identifier's phone banking app.
function SendPhoneBankingNotification(identifier, title, message, amount)
    lib.phone.impl.SendBankingNotification(identifier, title, message, amount)
end

-- ─────────────────────────────────────────────
-- Bank (delegates to lib.bank.impl — see integrations/bank/). Accounts are
-- addressed by `accountName` (a citizenid, job/gang name, or whatever the
-- active integration itself uses to key an account), not `source` — see
-- the per-integration caveats in integrations/bank/qbox/server.lua.
-- ─────────────────────────────────────────────

function GetAccountBalance(accountName)
    return lib.bank.impl.GetAccountBalance(accountName)
end

function AddAccountMoney(accountName, amount, reason)
    return lib.bank.impl.AddAccountMoney(accountName, amount, reason)
end

function RemoveAccountMoney(accountName, amount, reason)
    return lib.bank.impl.RemoveAccountMoney(accountName, amount, reason)
end

function TransferAccountMoney(fromAccount, toAccount, amount, reason)
    return lib.bank.impl.TransferAccountMoney(fromAccount, toAccount, amount, reason)
end

-- ─────────────────────────────────────────────
-- Server callback registry (paired with client TriggerServerCallback)
-- ─────────────────────────────────────────────

local registeredCallbacks = {}

--- Registers a named callback the client can invoke with TriggerServerCallback.
--- handler receives (source, ...args) and must return the result(s) to send back.
function RegisterServerCallback(name, handler)
    registeredCallbacks[name] = handler
end

RegisterNetEvent('rps_lib:triggerServerCallback', function(name, id, ...)
    local src = source
    local handler = registeredCallbacks[name]
    if not handler then
        lib.print(('no server callback registered for "%s"'):format(name))
        return
    end
    -- Isolate a misbehaving handler (e.g. a consumer resource bug) so it
    -- can't throw up through this shared event and break the callback
    -- system for every other resource using it.
    local args = { ... }
    local ok, results = pcall(function() return { handler(src, table.unpack(args)) } end)
    if not ok then
        -- Always printed (not gated on Config.Debug) — this is a genuine bug
        -- in whichever resource registered this callback, not routine debug noise.
        print(('^1[rps_lib] server callback "%s" errored: %s^7'):format(name, tostring(results)))
        return
    end
    TriggerClientEvent('rps_lib:serverCallbackResult', src, id, table.unpack(results))
end)

-- ─────────────────────────────────────────────
-- Client callbacks (server asks a specific client for data)
-- ─────────────────────────────────────────────

local pendingClientCallbacks = {}
local clientCallbackId = 0

function TriggerClientCallback(source, name, cb, ...)
    clientCallbackId = clientCallbackId + 1
    local id = clientCallbackId
    pendingClientCallbacks[id] = cb
    TriggerClientEvent('rps_lib:triggerClientCallback', source, name, id, ...)
end

RegisterNetEvent('rps_lib:clientCallbackResult', function(id, ...)
    local cb = pendingClientCallbacks[id]
    if cb then
        pendingClientCallbacks[id] = nil
        cb(...)
    end
end)

exports('GetPlayerData', GetPlayerData)
exports('GetIdentifier', GetIdentifier)
exports('Notify', Notify)
exports('AddMoney', AddMoney)
exports('RemoveMoney', RemoveMoney)
exports('GetMoney', GetMoney)
exports('RegisterServerCallback', RegisterServerCallback)
exports('TriggerClientCallback', TriggerClientCallback)
exports('GetPlayerVehicles', GetPlayerVehicles)
exports('IsVehicleStored', IsVehicleStored)
exports('SetVehicleStored', SetVehicleStored)
exports('ServerProgressBar', ServerProgressBar)
exports('IsPlayerDead', IsPlayerDead)
exports('RevivePlayer', RevivePlayer)
exports('ShowNotification', ShowNotification)
exports('GetInventoryName', GetInventoryName)
exports('HasItem', HasItem)
exports('GetItemCount', GetItemCount)
exports('AddItem', AddItem)
exports('RemoveItem', RemoveItem)
exports('GetInventory', GetInventory)
exports('ClearInventory', ClearInventory)
exports('CanCarryItem', CanCarryItem)
exports('GetItemDefinition', GetItemDefinition)
exports('GetItemCatalog', GetItemCatalog)
exports('GetJobs', GetJobs)
exports('SetPlayerJob', SetPlayerJob)
exports('SetJob', SetJob)
exports('HasPermission', HasPermission)
exports('CreateUseableItem', CreateUseableItem)
exports('GetOfflinePlayer', GetOfflinePlayer)
exports('GetEmployeesByJob', GetEmployeesByJob)
exports('GetAllCharacters', GetAllCharacters)
exports('SetOfflinePlayerJob', SetOfflinePlayerJob)
exports('AddOfflinePlayerMoney', AddOfflinePlayerMoney)
exports('SendPhoneMessage', SendPhoneMessage)
exports('StartPhoneCall', StartPhoneCall)
exports('AddPhoneTweet', AddPhoneTweet)
exports('SendPhoneBankingNotification', SendPhoneBankingNotification)
exports('GetBankName', GetBankName)
exports('GetAccountBalance', GetAccountBalance)
exports('AddAccountMoney', AddAccountMoney)
exports('RemoveAccountMoney', RemoveAccountMoney)
exports('TransferAccountMoney', TransferAccountMoney)
