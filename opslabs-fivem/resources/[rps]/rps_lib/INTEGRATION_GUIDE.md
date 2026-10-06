# Integration Guide — adding `rps_lib` to your own resource

This is the deeper, worked-example companion to the [README](README.md) quick-start. Read this if you're wiring `rps_lib` into a real resource and want to see the full picture: server.cfg order, the full API surface with runnable snippets, and the gotchas that bite people in practice.

## 1. Prerequisites

- `ox_lib` must be present — `rps_lib` depends on it (`dependency 'ox_lib'` in `rps_lib`'s own `fxmanifest.lua`) and won't start without it.
- One of ESX / QBCore / QBox, or nothing (`standalone` fallback works, with money/job calls returning `nil`/`false`).
- `oxmysql` if you'll use the `qb-garage` or `esx-garage` integrations (they query the DB directly).

## 2. `server.cfg` order

Load order matters — `ox_lib` and `rps_lib` must start before any resource that uses them:

```
ensure ox_lib
ensure rps_lib
ensure your_resource
```

If `your_resource` starts above `rps_lib`, `dependency 'rps_lib'` in its own `fxmanifest.lua` should force the correct order regardless — but keep the explicit `ensure` order above anyway, since it's what actually runs and is easiest to reason about when debugging startup issues.

## 3. Consuming `rps_lib` — exports

Add `dependency 'rps_lib'` to **your resource's** `fxmanifest.lua`, then call everything through `exports.rps_lib:`:

```lua
exports.rps_lib:Notify('Hello!', 'success')
local player = exports.rps_lib:GetPlayerData()
exports.rps_lib:AddMoney(source, 500, 'cash')
```

> This resource previously also supported a `shared_script '@rps_lib/init.lua'` "quick include" that copied its full source into your resource as plain globals. That relied on dynamically loading every module file via `LoadResourceFile` at runtime, which turned out to be unreliable in practice (intermittent "could not load module" failures on some setups) — every file is now declared directly in `rps_lib`'s own `fxmanifest.lua` instead, which is far more robust, but `init.lua` no longer pulls in the rest of the library when included by another resource. **Exports are the only supported way to consume `rps_lib` now.**

## 4. Full API reference

All of these are called as `exports.rps_lib:FunctionName(...)`. The `lib.table`/`lib.string`/`lib.math`/`lib.print`/`lib.awaitCallback` helpers listed in the README's "Shared helpers" section are used internally by `rps_lib`'s own modules but are **not** individually exported, so they aren't reachable from your resource. `lib.drawText3D`/`lib.drawText3DSimple` are the exception — they *are* exported, under the capitalized names `DrawText3D`/`DrawText3DSimple` (see §6a) — everything else follows the exports-only rule.

### Shared (either side)

| Function | Signature | Notes |
|---|---|---|
| `lib.table.deepcopy` | `(tbl) -> table` | Recursive copy, ignores metatables |
| `lib.table.contains` | `(tbl, value) -> bool` | Array-style search |
| `lib.table.count` | `(tbl) -> number` | Works on non-sequential tables |
| `lib.table.merge` | `(target, source) -> target` | Mutates and returns `target` |
| `lib.table.wipe` | `(tbl)` | Clears all keys in place |
| `lib.string.split` | `(str, sep?) -> table` | `sep` is literal, not a Lua pattern |
| `lib.string.trim` | `(str) -> str` | |
| `lib.string.random` | `(length?) -> str` | Alphanumeric, default length 8 |
| `lib.math.round` | `(value, decimals?) -> number` | |
| `lib.math.clamp` | `(value, min, max) -> number` | |
| `lib.math.distance` | `(a, b) -> number` | `a`/`b` = `{x=, y=, z=}` |
| `lib.print` | `(...)` | Only prints when `Config.Debug` is true |
| `GetFrameworkName` | `() -> 'esx'\|'qb'\|'qbox'\|'standalone'` | |
| `GetGarageName` | `() -> 'qb-garage'\|'qbox-garage'\|'esx-garage'\|'none'` | |
| `GetProgressBarName` | `() -> 'ox_lib'\|'none'` | |
| `GetAmbulanceJobName` | `() -> 'esx_ambulancejob'\|'qb-ambulancejob'\|'qbx_ambulancejob'\|'none'` | |
| `GetNotificationModuleName` | `() -> 'ox_lib'\|'codem'\|'none'` | |
| `GetInventoryName` | `() -> 'ox_inventory'\|'tgiann-inventory'\|'qb-inventory'\|'ps-inventory'\|'lj-inventory'\|'none'` | |
| `GetPhoneName` | `() -> 'lb_phone'\|'qb_phone'\|'none'` | See §6g |
| `GetBankName` | `() -> 'qb-banking'\|'renewed-banking'\|'qbox'\|'none'` | See §6h |
| `GetJobs` | `() -> table` | Framework's shared job table, passthrough (not normalized) |

### Client only

| Function | Signature | Notes |
|---|---|---|
| `GetPlayerData` | `() -> { source, identifier, name, job, money }` | Fields not applicable to the active framework are `nil` |
| `Notify` | `(message, type?)` | `type`: `'success'\|'error'\|'info'`, default `'info'` |
| `OpenGarage` | `(garageName)` | See §6 — behavior varies by garage integration |
| `ProgressBar` | `(options) -> bool` | Runs locally, returns `true` if completed, `false` if cancelled |
| `TriggerServerCallback` | `(name, cb, ...)` | Async style |
| `lib.awaitCallback` | `(name, ...) -> ...` | Sync-style wrapper, must run inside `CreateThread` |
| `RegisterClientCallback` | `(name, handler)` | Lets the server ask this client for data — see §7 |
| `DrawText3D` | `(coords, text, options?) -> bool` | Camera-facing 3D text; call every frame it should be visible — see §6a |
| `DrawText3DSimple` | `(coords, text, color?) -> bool` | `DrawText3D` with the background plate disabled |
| `IsPlayerDead` | `() -> bool` | Local player's dead/downed state — see §6b |
| `RevivePlayer` | `()` | Revives the local player |
| `ShowNotification` | `(options)` | Rich notification (ox_lib shape) — see §6c |
| `HasItem` | `(item, count?) -> bool` | **Not authoritative** — UI gating only, count defaults to 1 — see §6d |
| `GetItemCount` | `(item) -> number` | **Not authoritative** — UI gating only — see §6d |
| `GetTargetName` | `() -> 'ox_target'\|'tgiann-target'\|'qb-target'\|'none'` | Client-only, no server export exists — see §6e |
| `AddBoxZone` | `(name, coords, length, width, heading, options, distance?) -> id` | Canonical `options` shape documented in §6e |
| `AddEntityTarget` / `AddModelTarget` | `(entity\|models, options, distance?)` | Same canonical `options` shape |
| `RemoveZone` | `(id)` | |
| `RemoveEntityTarget` | `(entity, options?)` | |
| `OpenPhone` | `(app?)` | Opens the phone UI, optionally to a given app — see §6g |
| `PhoneNotification` | `(options)` | In-phone alert, `{ app?, title?, text?, icon?, timeout? }` — see §6g |
| `AddPhoneContact` | `(name, number)` | Adds a contact to the local player's own phone — see §6g |
| `GetPhoneNumber` | `() -> string\|nil` | Local player's own phone number — see §6g |
| `OpenBank` | `(accountType?)` | Opens the banking UI; no-op on integrations with none of their own — see §6h |

### Server only

| Function | Signature | Notes |
|---|---|---|
| `GetPlayerData` | `(source) -> table\|nil` | |
| `GetIdentifier` | `(source) -> string\|nil` | citizenid / esx identifier / license |
| `Notify` | `(source, message, type?)` | |
| `AddMoney` / `RemoveMoney` | `(source, amount, account?)` | `account`: `'bank'\|'cash'`, default `'bank'` |
| `GetMoney` | `(source, account?) -> number\|nil` | |
| `GetPlayerVehicles` | `(identifier, cb)` | `cb({ { plate, vehicle, stored, garage? }, ... })` |
| `IsVehicleStored` | `(plate, cb)` | `cb(bool)` |
| `SetVehicleStored` | `(plate, stored, cb?)` | `cb(success)` |
| `ServerProgressBar` | `(source, options, cb?)` | Asks that client to run a bar, `cb(completed)` |
| `RegisterServerCallback` | `(name, handler)` | `handler(source, ...)` must return the result |
| `TriggerClientCallback` | `(source, name, cb, ...)` | Ask a specific client for data — see §7 |
| `IsPlayerDead` | `(source) -> bool` | That player's dead/downed state — see §6b |
| `RevivePlayer` | `(source)` | Asks that client to revive itself |
| `ShowNotification` | `(source, options)` | Rich notification (ox_lib shape) — see §6c |
| `HasItem` | `(source, item, count?) -> bool` | Count defaults to 1 — see §6d |
| `GetItemCount` | `(source, item) -> number` | See §6d |
| `AddItem` / `RemoveItem` | `(source, item, count?, metadata?)` | Count defaults to 1, metadata optional — see §6d |
| `GetInventory` | `(source) -> { { name, count, metadata }, ... }` | Every item that player is carrying |
| `ClearInventory` | `(source, keep?) -> bool` | `keep` (array of item names) only honored by `ox_inventory`/`tgiann-inventory` — see §6d |
| `CanCarryItem` | `(source, item, count?) -> bool` | Only actually validates on `ox_inventory`/`tgiann-inventory`, always `true` elsewhere — see §6d |
| `GetItemDefinition` | `(item) -> table\|nil` | Item catalog entry, or `nil` if unknown/unavailable — see §6d |
| `GetItemCatalog` | `() -> table` | Full item catalog (name -> definition), `{}` if unavailable |
| `SetPlayerJob` | `(source, jobData) -> bool` | Full custom job write (name/label/payment/type/isboss/grade) — see §6f |
| `SetJob` | `(source, jobName, grade) -> bool` | Plain name+grade assignment, no custom-field overlay — see §6f |
| `HasPermission` | `(source, permission) -> bool` | ACE check on QBCore/Qbox, admin/superadmin group on ESX — see §6f |
| `CreateUseableItem` | `(item, handler)` | Registers `handler(source, itemName)` for using an item — see §6f |
| `SendPhoneMessage` | `(senderNumber, receiverNumber, message)` | SMS, addressed by number not `source` — see §6g |
| `StartPhoneCall` | `(callerNumber, receiveeNumber)` | See §6g |
| `AddPhoneTweet` | `(identifier, message, image?)` | `identifier` = same shape as `GetIdentifier(source)` — see §6g |
| `SendPhoneBankingNotification` | `(identifier, title, message, amount)` | See §6g |
| `GetAccountBalance` | `(accountName) -> number` | See §6h for what `accountName` means per integration |
| `AddAccountMoney` / `RemoveAccountMoney` | `(accountName, amount, reason?) -> bool` | See §6h |
| `TransferAccountMoney` | `(fromAccount, toAccount, amount, reason?) -> bool` | See §6h |

## 5. Worked example: a full resource using `rps_lib`

A small "vehicle repair" resource — client opens a garage-style menu, runs a progress bar, and the server verifies + pays out. This exercises money, garage, progress bar, and the callback bridge together.

**`your_resource/fxmanifest.lua`**
```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rps_lib'

client_scripts { 'client.lua' }
server_scripts { 'server.lua' }
```

**`your_resource/client.lua`**
```lua
RegisterCommand('repairjob', function()
    local completed = exports.rps_lib:ProgressBar({
        duration = 8000,
        label = 'Repairing vehicle...',
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })

    if not completed then
        exports.rps_lib:Notify('Repair cancelled.', 'error')
        return
    end

    -- Ask the server to verify + pay out (never trust the client for the reward itself)
    exports.rps_lib:TriggerServerCallback('your_resource:finishRepair', function(paid)
        if paid then
            exports.rps_lib:Notify('Repair complete, paid out.', 'success')
        else
            exports.rps_lib:Notify('Repair finished, but payout failed.', 'error')
        end
    end)
end, false)

RegisterCommand('opengarage', function()
    exports.rps_lib:OpenGarage('downtown')
end, false)
```

**`your_resource/server.lua`**
```lua
exports.rps_lib:RegisterServerCallback('your_resource:finishRepair', function(source)
    local ok = exports.rps_lib:AddMoney(source, 250, 'bank')
    return ok
end)

-- Example: server-initiated progress bar (e.g. from an admin command or a
-- scheduled event, not the player's own request)
RegisterCommand('forcerepair', function(source, args)
    local target = tonumber(args[1])
    if not target then return end

    exports.rps_lib:ServerProgressBar(target, {
        duration = 5000,
        label = 'Vehicle being serviced remotely...',
    }, function(completed)
        if completed then
            exports.rps_lib:AddMoney(target, 100, 'bank')
        end
    end)
end, true)

-- Example: server-side vehicle lookup
RegisterCommand('myvehicles', function(source)
    local identifier = exports.rps_lib:GetIdentifier(source)
    exports.rps_lib:GetPlayerVehicles(identifier, function(vehicles)
        for _, v in ipairs(vehicles) do
            print(v.plate, v.stored)
        end
    end)
end, false)
```

## 6. Garage module notes for integrators

`OpenGarage(garageName)` behavior depends entirely on which garage script is actually installed and detected — `rps_lib` doesn't ship a garage UI itself, it only bridges to one:

- On `qb-garage`, it fires the standard `qb-garages:openGarage` event, which works immediately against qb-garages and most forks.
- On `qbox-garage` and `esx-garage`, there's no universal "open menu" event across forks, so the stub just logs a reminder via `lib.print` — you're expected to either edit `integrations/garages/<name>/client.lua` inside `rps_lib` directly, or just skip `OpenGarage` and hook your own UI into whatever target/zone system you already use, and use `exports.rps_lib:GetPlayerVehicles`/`SetVehicleStored` from your own resource for the data side.

Don't assume `OpenGarage` "just works" for every setup — check `exports.rps_lib:GetGarageName()` first if you need to branch on it.

## 6a. 3D text (client) — DrawText3D/DrawText3DSimple exported, the rest is not

`lib.drawText3D`/`lib.drawText3DSimple` (see `client/3dtext.lua`) draw camera-facing world-space text and have no framework/integration dependency. Unlike the `lib.*`-namespaced helpers in the README's "Shared helpers" section, these two specifically **are** exported — call them as `exports.rps_lib:DrawText3D(coords, text, options)` / `exports.rps_lib:DrawText3DSimple(coords, text, color)` (capitalized, matching the export name, not the internal `lib.drawText3D` field name). `lib.addText3D`/`lib.removeText3D`/`lib.hasText3D` (the persistent-point API below) are **not** exported yet — ask for them to be added if you need them from another resource, or copy the approach in `client/3dtext.lua`.

`DrawText3D` is the one-shot primitive — call it every frame yourself (typically from a `CreateThread` loop gated on proximity, same pattern as everywhere else in this guide) — and it also supports:
- `bob` / `bobAmplitude` / `bobSpeed` — a gentle sine-wave float on the text's Z position, purely cosmetic, off by default.
- `marker` / `markerColor` — a small pulsing ground marker (`DrawMarker` type 1) drawn beneath the text, off by default; defaults to the text's own colour if `markerColor` isn't given.
- `fancy` / `accentColor` — opt-in "premium card" look, off by default: a breathing glow halo behind the plate, a thin accent-coloured border frame around it, and two-tone text where the first line (or the whole text, if single-line) is drawn slightly larger and tinted in `accentColor` as a "title", with any remaining lines in the normal `color` as the "subtitle". `accentColor` defaults to gold (`{255, 205, 70}`). Purely cosmetic — combines freely with `bob`/`marker`.

```lua
-- Client
local completed = exports.rps_lib:DrawText3D(vector3(123.4, 456.7, 79.5), 'Mechanic Shop\nPress ~g~E~w~ to interact', {
    marker = true,
    bob = true,
    fancy = true,
})
```

For the common case of a text label that should just always be visible near a fixed point, `lib.addText3D(id, coords, text, options)` is the "advanced" alternative (internal-only, see above): register it once (any code path, not necessarily a loop) and a single shared internal thread redraws it every frame using `lib.drawText3D` under the hood, so it gets every option above for free. That shared thread only ticks at `Wait(0)` while at least one registered point is actually being drawn (in range, not culled) — otherwise it backs off to `Wait(500)`, so registering points scattered across the map doesn't cost meaningfully more than one. `lib.removeText3D(id)` unregisters (safe to call on an id that was never registered), and `lib.hasText3D(id)` checks registration state. Calling `lib.addText3D` again with the same `id` replaces that point's coords/text/options in place.

## 6b. Ambulance job (dead/downed state + revive)

`IsPlayerDead`/`RevivePlayer` bridge to whichever ambulance/EMS job is detected (`esx_ambulancejob`, `qb-ambulancejob`, `qbx_ambulancejob`, or the native-ped-death `none` fallback). The `esx_ambulancejob` integration was verified against an installed copy (`isDead` statebag, `esx_ambulancejob:revive` event); `qb-ambulancejob`/`qbx_ambulancejob` are **best-effort against the common convention, not verified against an installed copy** — same spirit as the garage module's DB-schema assumptions. Check `integrations/ambulancejob/<name>/*.lua` and verify against your installed job if death/revive behaves unexpectedly.

```lua
-- Client: gate an action on the player being alive
if not exports.rps_lib:IsPlayerDead() then
    exports.rps_lib:ProgressBar({ duration = 3000, label = 'Bandaging wound...' })
end

-- Server: revive a player as an admin action, then notify them
RegisterCommand('revive', function(source, args)
    local target = tonumber(args[1])
    if target and exports.rps_lib:IsPlayerDead(target) then
        exports.rps_lib:RevivePlayer(target)
        exports.rps_lib:Notify(target, 'You have been revived.', 'success')
    end
end, true)
```

## 6c. Rich notifications

`ShowNotification` is a separate, optional upgrade over the plain `Notify` — it takes ox_lib's richer options shape (`title`, `description`, `type`, `duration`, `icon`, `position`, ...) and degrades automatically depending on what's detected (`ox_lib` → full shape, `codem` → `type`/`description`/`duration` via [codem-supreme-notification](https://codem.gitbook.io/codem-documentation/supreme-series/essentials/notification/usage)'s own export, `none` → plain `Notify`) so you never have to branch on `GetNotificationModuleName()` yourself:

```lua
-- Client
exports.rps_lib:ShowNotification({
    title = 'Vehicle repaired',
    description = 'Your car is ready for pickup.',
    type = 'success',
    duration = 6000,
})

-- Server — e.g. after ServerProgressBar's callback confirms completion
exports.rps_lib:ShowNotification(source, {
    title = 'Payment received',
    description = ('$%d added to your bank.'):format(250),
    type = 'success',
})
```

Only `title`/`description`/`type` survive the `codem`/`none` fallbacks (folded into a single message string, plus `duration` for `codem`) — don't rely on `icon`/`position`/etc. actually doing anything unless you know ox_lib is active (`GetNotificationModuleName() == 'ox_lib'`).

## 6d. Inventory

`HasItem`/`GetItemCount`/`AddItem`/`RemoveItem` bridge to whichever inventory is detected (`ox_inventory`, `tgiann-inventory`, `qb-inventory`, `ps-inventory`, `lj-inventory`, or `none`). `ox_inventory` and `tgiann-inventory` both have real, complete server exports for everything this module needs (including actual `CanCarryItem`/`ClearInventory` support). The three QBCore-family integrations are genuinely identical under the hood — none of them replace QBCore's own `Player.Functions` item API, they only change the UI/stash layer, so `rps_lib` calls the exact same `Player.Functions.AddItem`/`RemoveItem`/`GetItemByName` regardless of which one is actually installed.

**Client-side `HasItem`/`GetItemCount` are not authoritative** — a client can freely lie about its own state, so only use them for UI gating (show/hide a prompt, grey out a button). Always re-verify with the server-side versions before actually granting anything:

```lua
-- Client: gate a UI prompt only
if exports.rps_lib:HasItem('lockpick') then
    -- show a "pick the lock" interact prompt
end

-- Server: the actual authoritative check + consume, inside whatever
-- server callback/event handles the interact
if exports.rps_lib:HasItem(source, 'lockpick') then
    exports.rps_lib:RemoveItem(source, 'lockpick', 1)
    -- ... do the lockpicking
else
    exports.rps_lib:Notify(source, 'You need a lockpick.', 'error')
end
```

`metadata` on `AddItem`/`RemoveItem` is optional and passed straight through to whichever inventory is active — its shape isn't portable across inventories (ox_inventory's metadata table vs. QBCore's item `info` table are different shapes), so don't build metadata you expect to work unchanged if the server ever switches inventories.

`GetInventory`/`ClearInventory`/`CanCarryItem` round out the module:

```lua
-- Dump everything a player is carrying (e.g. for an admin panel or a death-drop system)
for _, item in ipairs(exports.rps_lib:GetInventory(source)) do
    print(item.name, item.count)
end

-- Check capacity before an item-giving flow bothers doing anything else
-- (only meaningful on ox_inventory/tgiann-inventory — always true on the
-- QBCore-family integrations, so treat a `false` here as UX specific to
-- those two, not something to depend on for QBCore setups)
if exports.rps_lib:CanCarryItem(source, 'heavy_crate', 1) then
    exports.rps_lib:AddItem(source, 'heavy_crate', 1)
end

-- Wipe a player's inventory on death, keeping their ID card
-- (ox_inventory/tgiann-inventory only — this still clears everything on
-- the QBCore-family integrations)
exports.rps_lib:ClearInventory(source, { 'id_card' })
```

## 6e. Target / third-eye — client-only

Unlike every other module in this guide, `AddBoxZone`/`AddEntityTarget`/`AddModelTarget`/`RemoveZone`/`RemoveEntityTarget`/`GetTargetName` exist **only** as client exports — there is no server-side piece to `rps_lib`'s target module at all, since there's no real "server asks a client to add a target zone" use case the way there is for progress bars or notifications.

`options` is one canonical shape regardless of which integration (`ox_target`/`tgiann-target`/`qb-target`/`none`) is active — an array of `{ name, icon, label, distance?, canInteract?(entity, distance, coords, name), onSelect?(data) }`. `ox_target` and `tgiann-target` both get this passed straight through (it matches both of their native shapes closely enough to need no translation — `tgiann-target` just needs entity handles converted to network ids internally, which `AddEntityTarget`/`RemoveEntityTarget` do transparently); `qb-target` gets each option translated into its own `icon`/`label`/`action`/`canInteract` shape internally.

```lua
-- Client only
local zoneId = exports.rps_lib:AddBoxZone('shop_counter', vector3(123.4, 456.7, 78.9), 1.5, 1.5, 0.0, {
    {
        name = 'shop_buy',
        icon = 'fas fa-shopping-cart',
        label = 'Browse shop',
        onSelect = function(data)
            TriggerEvent('myresource:openShop')
        end,
    },
}, 2.0)

-- later, e.g. when the shop resource stops
exports.rps_lib:RemoveZone(zoneId)
```

Since it's a canonical shape rather than a direct pass-through of ox_target's or qb-target's own documentation, double check `integrations/target/qb-target/client.lua` if you're targeting a qb-target fork that predates its `action`-callback support — you'd need to adjust the translation there to the older event+type style instead.

## 6f. Jobs, permissions, and useable items

`GetJobs`/`SetPlayerJob`/`SetJob`/`HasPermission`/`CreateUseableItem` round out the server API for resources (like a boss/job-management menu) that need to read the shared job table, write a player's job, gate an action behind admin/permission checks, or hook a "use item" handler — all without touching ESX/QBCore/Qbox directly:

```lua
-- Server: look up the shared job table (shape varies by framework — passthrough, not normalized)
local jobs = exports.rps_lib:GetJobs()
if jobs['police'] then print(jobs['police'].label) end

-- Server: full custom job write — applies name/grade.level via the framework's
-- own job-assignment call, then (QBCore/Qbox only) overlays the rest of the
-- table (payment/isboss/grade.name/...) the same way those frameworks' own
-- job objects already support. ESX only applies name/grade.level — see the
-- caveat in framework/esx/server.lua.
exports.rps_lib:SetPlayerJob(target, {
    name = 'police', label = 'Police', payment = 500, type = 'leo',
    isboss = true, grade = { name = 'Chief', level = 4 },
})

-- Server: plain job/grade assignment only, no custom-field overlay
exports.rps_lib:SetJob(target, 'unemployed', 0)

-- Server: gate an admin action
RegisterCommand('forcerevive', function(source, args)
    if not exports.rps_lib:HasPermission(source, 'admin') then return end
    exports.rps_lib:RevivePlayer(tonumber(args[1]))
end, true)

-- Server: hook a "use item" handler
exports.rps_lib:CreateUseableItem('lockpick', function(source, itemName)
    exports.rps_lib:Notify(source, 'You used a ' .. itemName, 'info')
end)
```

`HasPermission`'s `permission` string is checked as a real ACE permission on QBCore/Qbox (via their own `HasPermission`); ESX has no equivalent per-permission-string system, so it's ignored there and the check just falls back to admin/superadmin group membership. `CreateUseableItem`'s `handler` only ever receives the item's name (a string), not a full item instance — none of the three frameworks' native useable-item registration passes through per-instance metadata/slot to the handler, so if you need that (e.g. reading a specific item stack's metadata), look it up separately with `GetInventory(source)` inside the handler.

**`CreateUseableItem` is the one function in this whole API that's safe to call at the very top level of your resource's server script** (i.e. outside any event handler, command, or thread) — which matters, because that's the conventional place every framework registers useable items. Every other framework-delegating function (`GetJobs`, `AddMoney`, `HasPermission`, ...) reads `lib.framework.impl` directly and **will error if called before `rps_lib`'s async framework detection finishes** (usually within a tick of resource start, but not guaranteed to have happened yet at your own resource's top level). `CreateUseableItem` specifically queues a too-early call and flushes it once detection completes, so it doesn't have that restriction — don't assume the same safety for the others; call those from inside a command/event/callback handler, which by definition runs well after startup.

## 6g. Phone

`lb_phone`, `qb_phone`, `none`. Unlike the other integration modules, phone actions are addressed by phone number (SMS/calls) or by identifier (tweets/banking alerts — the same shape `GetIdentifier(source)` returns, i.e. citizenid on QBCore/Qbox), not by `source`, because that's how the underlying phone resource itself addresses them.

**`lb_phone` identifier caveat:** lb-phone addresses everything by phone number — it has no concept of citizenid/license at all. So for `AddPhoneTweet`/`SendPhoneBankingNotification` specifically, when `lb_phone` is the active integration, `identifier` must actually be that player's **phone number**, not the value `GetIdentifier(source)` returns. This only matters if your resource needs to support switching between phone integrations; if you're only ever running one, just pass whatever that one expects. See `integrations/phone/lb_phone/server.lua` for the full caveat.

```lua
-- Client: open the phone, optionally to a specific app
exports.rps_lib:OpenPhone('messages')

-- Client: an in-phone alert (distinct from Notify/ShowNotification — this
-- shows inside the phone UI itself, not as a screen toast)
exports.rps_lib:PhoneNotification({ app = 'messages', title = 'New Message', text = 'Hey!', timeout = 5000 })

-- Client: contacts / own number
exports.rps_lib:AddPhoneContact('John Doe', '555-0123')
local myNumber = exports.rps_lib:GetPhoneNumber()

-- Server: SMS, calls, tweets, banking alerts
exports.rps_lib:SendPhoneMessage('555-0123', '555-0456', 'On my way')
exports.rps_lib:StartPhoneCall('555-0123', '555-0456')
exports.rps_lib:AddPhoneTweet(exports.rps_lib:GetIdentifier(source), 'Spotted a cop!', nil)
exports.rps_lib:SendPhoneBankingNotification(exports.rps_lib:GetIdentifier(source), 'Purchase', '-$500 at the pawn shop', -500)
```

`Config.Phone` picks the integration the same way `Config.Inventory`/`Config.Target` do (`'auto'` detects `qb-phone`, else falls back to `'none'`, whose calls are safe no-ops). Only `qb_phone` is implemented — if you're running a different phone resource (`lb-phone`, `qs-smartphone`, ...), ask for it to be added or copy the shape in `integrations/phone/qb_phone/`.

## 6h. Bank

`qb-banking`, `renewed-banking`, `qbox`, `none`. Accounts are addressed by a single `accountName` string, not `source` — what that string actually means depends on the active integration:

- **`qb-banking`**: `accountName` is a citizenid (personal accounts) or a job/gang name (shared accounts) — whatever qb-banking itself uses to key that account. `Config.Bank = 'auto'` picks this whenever the `qb-banking` resource is running, regardless of framework.
- **`renewed-banking`**: `accountName` is a job name, citizenid, or custom account name — same "one name, no separate account number" shape. Checked in `'auto'` mode right after `qb-banking`. Its export list (`https://renewed.dev/banking/exports`) is server-only, so `OpenBank` is a no-op here rather than an error.
- **`qbox`**: Qbox has no dedicated banking resource — "bank account" is just `qbx_core`'s own `'bank'` money type on a player, so `accountName` must be a player identifier (`source` or citizenid), **not** a job/gang name — Qbox has no shared-account concept at all. Only picked as a fallback when the detected framework is `qbox` and neither `qb-banking` nor `Renewed-Banking` is running.
- **`none`**: every call is a safe no-op/`0`/`false`.

```lua
-- Client: open the banking UI (no-op on integrations with no UI of their own, e.g. qbox)
exports.rps_lib:OpenBank('personal')

-- Server
local balance = exports.rps_lib:GetAccountBalance(citizenid)
exports.rps_lib:AddAccountMoney(citizenid, 500, 'Paycheck')
exports.rps_lib:RemoveAccountMoney(citizenid, 200, 'Rent')
exports.rps_lib:TransferAccountMoney(citizenid, 'police', 1000, 'Fine payment')
```

Explicit account creation (qb-banking's `CreatePlayerAccount`/`CreateJobAccount`/`CreateGangAccount`) is **not** exposed here — its exact export signature differs between documented versions of qb-banking, and the resource auto-creates personal/job/gang accounts on first use anyway, so wiring to the wrong signature would silently misbehave rather than error. Call the matching export on your installed copy directly if you need it.

## 7. The callback bridge, explained

`rps_lib` includes a lightweight promise-style callback system (same shape as ox_lib's callbacks) so you don't need to hand-roll `TriggerServerEvent`/`RegisterNetEvent` pairs for simple request/response patterns:

- **Client asks server for something:** `RegisterServerCallback` (server) + `TriggerServerCallback` (client). `lib.awaitCallback` is the sync-style wrapper `rps_lib` uses internally around the same mechanism, but it isn't exported, so from another resource you always use the async callback style shown in §5.
- **Server asks a specific client for something:** `RegisterClientCallback` (client) + `TriggerClientCallback` (server).

Both directions are independent — you can use one without the other. IDs are generated per-call and aren't reused, so concurrent in-flight callbacks with the same name are safe.

## 8. Debugging

- Set `Config.Debug = true` in `rps_lib`'s own `config.lua` to see `lib.print(...)` output (framework detection details, missing-callback warnings, etc.) — this is a resource-wide setting, not per-consumer.
- Regardless of `Config.Debug`, `rps_lib` always prints a boxed banner on startup showing which framework, garage, progress-bar, ambulance-job, notification, inventory, and target module got selected — check this first if something isn't behaving as expected. This only prints in `rps_lib`'s own console output, not your consuming resource's. The target banner only prints client-side, since target detection never runs server-side.
- Force a framework at runtime without editing `config.lua`: `setr rps_lib:forceFramework "qb"` (or `"esx"`, `"qbox"`, `"standalone"`, `"auto"`).

## 9. Gotchas

- Money/job helpers silently return `nil`/`false` on `standalone` — always check the return value if you support servers without a framework.
- `lib.awaitCallback` and the persistent-point 3D text API (`lib.addText3D`/`lib.removeText3D`/`lib.hasText3D`) are used internally by `rps_lib` but aren't in the exports list — see §6a and §7 for what that means for you. (`DrawText3D`/`DrawText3DSimple` *are* exported — see §6a.)
- If you're editing `rps_lib`'s own source (not just consuming it): don't reassign `lib.table`, `lib.string`, `lib.math`, or `lib.print` anywhere that runs in the same script context as `ox_lib` — both populate a global literally named `lib`, and these four fields exist on both. See the main README's "Notes" section for the full explanation of load order and why `rps_lib`'s own versions win. This doesn't affect your consuming resource, which has its own separate `lib` global (if it uses one at all).

## 10. Extending `rps_lib` itself

If you need a new framework, garage script, or progress bar library supported, that's a change to `rps_lib` itself, not to your consuming resource — see the "To add support for..." sections at the bottom of the main [README](README.md).
