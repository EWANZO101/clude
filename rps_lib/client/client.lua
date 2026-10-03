--[[
    lib (client)
    Unified client-side API that works the same regardless of framework.
    All framework-specific behavior lives in framework/*.lua — this file
    just delegates to lib.framework.impl.
]]

lib = lib or {}

-- ─────────────────────────────────────────────
-- Notifications
-- ─────────────────────────────────────────────

--- Shows a notification using whichever framework is active, falling back
--- to the native GTA notification if standalone.
--- @param message string
--- @param notifyType string|nil 'success' | 'error' | 'info' (default 'info')
function Notify(message, notifyType)
    lib.framework.impl.Notify(message, notifyType or 'info')
end

exports('Notify', Notify)

-- ─────────────────────────────────────────────
-- Player data
-- ─────────────────────────────────────────────

--- Returns a normalized player data table:
--- { source, identifier, name, firstname, lastname,
---   job = { name, label, grade = { level, name }, isboss }, money }
--- Fields that don't apply to standalone/other frameworks are left nil.
function GetPlayerData()
    return lib.framework.impl.GetPlayerData()
end

exports('GetPlayerData', GetPlayerData)

-- ─────────────────────────────────────────────
-- Garage (delegates to lib.garage.impl — see integrations/garages/)
-- ─────────────────────────────────────────────

--- Opens the garage menu/UI via the detected garage integration.
--- Does nothing (logs via lib.print) if Config.Garage is 'none' or nothing was detected.
function OpenGarage(garageName)
    if not lib.garage.impl.OpenGarage then
        lib.print('OpenGarage is not supported by the active garage module')
        return
    end
    lib.garage.impl.OpenGarage(garageName)
end

exports('OpenGarage', OpenGarage)

-- ─────────────────────────────────────────────
-- Server callbacks (promise-based, works like a lightweight ox_lib callback)
-- ─────────────────────────────────────────────

local callbackId = 0
local pendingCallbacks = {}

--- Triggers a server callback and returns a promise you can `await`
--- or resolve with a completion handler.
--- Usage:
---   local result = lib.awaitCallback('myresource:getSomething', arg1, arg2)
--- or
---   TriggerServerCallback('myresource:getSomething', function(result) ... end, arg1, arg2)
function TriggerServerCallback(name, cb, ...)
    callbackId = callbackId + 1
    local id = callbackId
    pendingCallbacks[id] = cb
    TriggerServerEvent('rps_lib:triggerServerCallback', name, id, ...)
end

RegisterNetEvent('rps_lib:serverCallbackResult', function(id, ...)
    local cb = pendingCallbacks[id]
    if cb then
        pendingCallbacks[id] = nil
        cb(...)
    end
end)

exports('TriggerServerCallback', TriggerServerCallback)

--- Synchronous-style wrapper around TriggerServerCallback using promises.
--- Must be called from inside a thread (CreateThread), not directly in the main scope.
function lib.awaitCallback(name, ...)
    local p = promise.new()
    TriggerServerCallback(name, function(...)
        p:resolve({ ... })
    end, ...)
    return table.unpack(Citizen.Await(p))
end

-- ─────────────────────────────────────────────
-- Client callback registry (paired with server TriggerClientCallback)
-- ─────────────────────────────────────────────

local registeredClientCallbacks = {}

--- Registers a named callback the server can invoke with TriggerClientCallback.
function RegisterClientCallback(name, handler)
    registeredClientCallbacks[name] = handler
end

RegisterNetEvent('rps_lib:triggerClientCallback', function(name, id, ...)
    local handler = registeredClientCallbacks[name]
    if not handler then
        lib.print(('no client callback registered for "%s"'):format(name))
        return
    end
    -- Isolate a misbehaving handler (e.g. a consumer resource bug) so it
    -- can't throw up through this shared event and break the callback
    -- system for every other resource using it.
    local args = { ... }
    local ok, results = pcall(function() return { handler(table.unpack(args)) } end)
    if not ok then
        print(('^1[rps_lib] client callback "%s" errored: %s^7'):format(name, tostring(results)))
        return
    end
    TriggerServerEvent('rps_lib:clientCallbackResult', id, table.unpack(results))
end)

exports('RegisterClientCallback', RegisterClientCallback)

-- ─────────────────────────────────────────────
-- Progress bar (delegates to lib.progressbar.impl — see integrations/progressbar/)
-- ─────────────────────────────────────────────

--- Runs a progress bar locally via the detected progress bar module.
--- `options` is passed straight through to that module (see the ox_lib
--- integration for the shape ox_lib expects). Returns true if it completed,
--- false if cancelled.
function ProgressBar(options)
    return lib.progressbar.impl.ProgressBar(options)
end

exports('ProgressBar', ProgressBar)

-- Responds to a server-initiated progress bar (see server's ServerProgressBar).
RegisterNetEvent('rps_lib:progressbar:start', function(id, options)
    local completed = ProgressBar(options)
    TriggerServerEvent('rps_lib:progressbar:result', id, completed)
end)

-- ─────────────────────────────────────────────
-- Ambulance job (delegates to lib.ambulance.impl — see integrations/ambulancejob/)
-- ─────────────────────────────────────────────

--- True if the local player is dead or downed, per the detected ambulance
--- job integration (falls back to the native ped-death check if none).
function IsPlayerDead()
    return lib.ambulance.impl.IsPlayerDead()
end

exports('IsPlayerDead', IsPlayerDead)

--- Revives the local player via the detected ambulance job integration.
--- Does nothing (logs via lib.print) if Config.Ambulance is 'none'.
function RevivePlayer()
    lib.ambulance.impl.RevivePlayer()
end

exports('RevivePlayer', RevivePlayer)

-- ─────────────────────────────────────────────
-- Rich notifications (delegates to lib.notification.impl — see integrations/notifications/)
-- ─────────────────────────────────────────────

--- Shows a rich notification (title/description/type/duration/icon/position,
--- ... — see the ox_lib integration for the shape ox_lib expects) via the
--- detected notification module. Falls back to the plain Notify(message, type)
--- above if no rich notification module (e.g. ox_lib) is active.
function ShowNotification(options)
    lib.notification.impl.Notify(options)
end

exports('ShowNotification', ShowNotification)

-- Responds to a server-initiated rich notification (see server's ShowNotification).
RegisterNetEvent('rps_lib:notification:show', function(options)
    ShowNotification(options)
end)

-- ─────────────────────────────────────────────
-- Inventory (delegates to lib.inventory.impl — see integrations/inventory/)
-- ─────────────────────────────────────────────

--- Client-side convenience check only — NOT authoritative (a client can lie
--- about its own inventory state). Fine for UI gating (show/hide a prompt),
--- never for anything that grants a reward — always re-verify with the
--- server-side HasItem/GetItemCount before actually giving anything.
function HasItem(item, count)
    return lib.inventory.impl.HasItem(item, count)
end

exports('HasItem', HasItem)

--- Same "not authoritative" caveat as HasItem above.
function GetItemCount(item)
    return lib.inventory.impl.GetItemCount(item)
end

exports('GetItemCount', GetItemCount)

-- ─────────────────────────────────────────────
-- Target / third-eye (delegates to lib.target.impl — see integrations/target/)
-- ─────────────────────────────────────────────

--- Adds a box-shaped interaction zone. `options` is the canonical shape:
---   { { name, icon, label, distance?, canInteract?(entity, distance, coords, name), onSelect?(data) }, ... }
--- `distance` (optional) sets a default interaction distance for the zone.
--- Returns a zone id you can pass to RemoveZone.
function AddBoxZone(name, coords, length, width, heading, options, distance)
    return lib.target.impl.AddBoxZone(name, coords, length, width, heading, options, distance)
end

exports('AddBoxZone', AddBoxZone)

--- Adds target options (same canonical shape as AddBoxZone) to a specific entity.
function AddEntityTarget(entity, options, distance)
    return lib.target.impl.AddEntityTarget(entity, options, distance)
end

exports('AddEntityTarget', AddEntityTarget)

--- Adds target options to every entity using any of the given model(s)
--- (a single model hash/name, or an array of them).
function AddModelTarget(models, options, distance)
    return lib.target.impl.AddModelTarget(models, options, distance)
end

exports('AddModelTarget', AddModelTarget)

--- Removes a zone previously created with AddBoxZone (pass the id it returned).
function RemoveZone(id)
    return lib.target.impl.RemoveZone(id)
end

exports('RemoveZone', RemoveZone)

--- Removes target options from a specific entity (added via AddEntityTarget).
function RemoveEntityTarget(entity, options)
    return lib.target.impl.RemoveEntityTarget(entity, options)
end

exports('RemoveEntityTarget', RemoveEntityTarget)

-- DrawText3D/DrawText3DSimple (and the persistent addText3D/removeText3D/
-- hasText3D API) are exported directly from client/3dtext.lua, next to
-- their lib.* implementations.

-- ─────────────────────────────────────────────
-- Phone (delegates to lib.phone.impl — see integrations/phone/)
-- ─────────────────────────────────────────────

--- Opens the phone UI, optionally jumping straight to a given app (e.g. 'messages').
function OpenPhone(app)
    lib.phone.impl.OpenPhone(app)
end

exports('OpenPhone', OpenPhone)

--- options: { app?, title?, text?, icon?, timeout? } — an in-phone alert,
--- distinct from the plain Notify/rich ShowNotification above.
function PhoneNotification(options)
    lib.phone.impl.SendNotification(options)
end

exports('PhoneNotification', PhoneNotification)

--- Adds a contact to the local player's own phone.
function AddPhoneContact(name, number)
    lib.phone.impl.AddContact(name, number)
end

exports('AddPhoneContact', AddPhoneContact)

--- Returns the local player's own phone number, or nil if unavailable.
function GetPhoneNumber()
    return lib.phone.impl.GetPhoneNumber()
end

exports('GetPhoneNumber', GetPhoneNumber)

-- ─────────────────────────────────────────────
-- Bank (delegates to lib.bank.impl — see integrations/bank/)
-- ─────────────────────────────────────────────

--- Opens the banking UI, optionally to a given account type (e.g. 'personal').
--- No-op on integrations with no banking UI of their own (e.g. 'qbox') — see §6h.
function OpenBank(accountType)
    lib.bank.impl.OpenBank(accountType)
end

exports('OpenBank', OpenBank)
