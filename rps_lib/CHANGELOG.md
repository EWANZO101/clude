# Changelog

All notable changes to `rps_lib` are documented here.

## v3.1.2 — phone module, bank module, 3D text centering fix

### Added

- **Phone module** — `lb_phone`, `qb_phone`, `none`. `GetPhoneName`. Client: `OpenPhone`, `PhoneNotification`, `AddPhoneContact`, `GetPhoneNumber`. Server: `SendPhoneMessage`, `StartPhoneCall`, `AddPhoneTweet`, `SendPhoneBankingNotification` — addressed by phone number (SMS/calls) or identifier (tweets/banking alerts), matching how the underlying phone resource addresses those actions itself, not by `source` like the rest of this library. `Config.Phone` picks the integration (`'auto'` checks `lb-phone` before `qb-phone`, else `'lb_phone'`/`'qb_phone'`/`'none'`), same convention as `Config.Inventory`/`Config.Target`. Signatures confirmed against each resource's real docs — `docs.lbscripts.com` for lb-phone (its own `exports.lua` files are precompiled; cross-checked against real call sites in the installed copy where possible, e.g. `ToggleOpen(true/false)` as an explicit open/close) and qbcore.net for qb-phone.
- **Bank module** — `qb-banking`, `renewed-banking`, `qbox`, `none`. `GetBankName`. Client: `OpenBank`. Server: `GetAccountBalance`, `AddAccountMoney`, `RemoveAccountMoney`, `TransferAccountMoney` — addressed by `accountName`, not `source` (a citizenid or job/gang name on `qb-banking`/`renewed-banking`; a player identifier only on `qbox`, which has no job/gang account concept — see the caveat in `integrations/bank/qbox/server.lua`). `Config.Bank` picks the integration: `'auto'` prefers `qb-banking`, then `renewed-banking`, else falls back to `qbox` if that's the detected framework, else `none`. `renewed-banking` targets `getAccountMoney`/`addAccountMoney`/`removeAccountMoney` (confirmed against `renewed.dev/banking/exports`); `OpenBank` is a no-op under it since that resource's documented export list is server-only. Account creation (`CreatePlayerAccount`/`CreateJobAccount`/`CreateGangAccount`) is deliberately not exposed — qb-banking auto-creates accounts on first use, and its documented creation export signature varies between versions of that resource; call it directly on your installed copy if you need it explicitly.

### Fixed/Caveats

- `lib.drawText3D` only centered the first line of multi-line text — every line after it silently fell back to left-aligned. `SetTextFont`/`SetTextProportional`/`SetTextCentre`/outline were only being set once before the line-drawing loop, but the game resets that formatting state after every `EndTextCommandDisplayText` call, so it only applied to the first `EndTextCommandDisplayText` in the loop. They're now re-applied for every line, right before its own `EndTextCommandDisplayText`.
- lb-phone addresses everything by phone number, with no concept of citizenid/license — so for `AddPhoneTweet`/`SendPhoneBankingNotification`, `identifier` means that player's phone number under `lb_phone`, not the value `GetIdentifier(source)` returns like it does under `qb_phone`. Documented in `integrations/phone/lb_phone/server.lua` and INTEGRATION_GUIDE.md §6g.

## v3.1.0 — advanced 3D text

### Added

- `lib.drawText3D` gained two new opt-in options: `bob`/`bobAmplitude`/`bobSpeed` (a gentle sine-wave float on the text's Z position) and `marker`/`markerColor` (a small pulsing ground marker drawn beneath the text). Both default to off — existing calls are unaffected.
- `lib.addText3D(id, coords, text, options)` / `lib.removeText3D(id)` / `lib.hasText3D(id)` — a persistent alternative to calling `lib.drawText3D` in your own `CreateThread` loop every frame. Register a point once and a single shared internal thread redraws it from then on, using `lib.drawText3D` itself under the hood (so it gets every option, including the new `bob`/`marker`, for free). That shared thread only runs at `Wait(0)` while at least one registered point is actually being drawn (in range, not culled) and backs off to `Wait(500)` otherwise, so idle points cost almost nothing. Calling `lib.addText3D` again with the same `id` replaces that point in place.
- `DrawText3D`/`DrawText3DSimple` added to `fxmanifest.lua`'s client exports, so `lib.drawText3D`/`lib.drawText3DSimple` are now reachable from other resources via `exports.rps_lib:DrawText3D(...)`/`exports.rps_lib:DrawText3DSimple(...)` (capitalized, matching the export name) — previously internal-only.
- `lib.drawText3D` gained a `fancy` / `accentColor` opt-in "premium card" style: a breathing glow halo behind the plate, a thin accent-coloured border frame, and two-tone title/subtitle text (first line drawn larger in `accentColor`, defaulting to gold). Off by default — existing calls are unaffected — and stacks with `bob`/`marker`.

### Fixed

- `DrawText3D`/`DrawText3DSimple` being listed in `fxmanifest.lua`'s `exports` block didn't actually register them — that block is just a name list, not the registration itself. `client/3dtext.lua` now has the matching `exports('DrawText3D', ...)`/`exports('DrawText3DSimple', ...)` calls, so `exports.rps_lib:DrawText3D(...)` from another resource no longer fails with "No such export."

## v3.0.0 — the rewrite

### Breaking changes

- **Removed the `@rps_lib/init.lua` "quick include."** The old architecture dynamically loaded every module file at runtime via `LoadResourceFile` + `load()`, the same trick ox_lib uses — but it turned out to be unreliable in practice (intermittent "could not load module" failures on some setups). Every file is now declared directly in `fxmanifest.lua`'s `shared_scripts`/`client_scripts`/`server_scripts`, which is far more robust. **Exports (`exports.rps_lib:FunctionName(...)`) are now the only supported way to consume this resource** — `init.lua` no longer pulls the rest of the library into another resource's environment as plain globals.
- `init.lua` is no longer the resource's loader — it's reduced to the one thing that still has to run first: pre-seeding this resource's own `lib.*` registries so they don't collide with ox_lib's lazy-loading metatable (see below).

### Added

- `dependency 'ox_lib'` + `@ox_lib/init.lua` inclusion, sharing the `lib` global with ox_lib itself. This surfaced a real bug (ox_lib's metatable poisoning any of this resource's own registries on first read) which is fixed with a documented `rawset` pre-seed in `init.lua`.
- **Garage module** — `qb-garage`, `qbox-garage`, `esx-garage`, `none`. `GetGarageName`, `OpenGarage`, `GetPlayerVehicles`, `IsVehicleStored`, `SetVehicleStored`.
- **Progress bar module** — `ox_lib`, `none`. `GetProgressBarName`, `ProgressBar` (client), `ServerProgressBar` (server-initiated).
- **3D text** (client-only) — `lib.drawText3D` / `lib.drawText3DSimple`, distance-faded camera-facing world text with an outline and background plate.
- **Ambulance job module** — `esx_ambulancejob`, `qb-ambulancejob`, `qbx_ambulancejob`, `none`. `GetAmbulanceJobName`, `IsPlayerDead`, `RevivePlayer`.
- **Rich notifications module** — `ox_lib`, `codem-supreme-notification`, `none`. `GetNotificationModuleName`, `ShowNotification` — a richer, optional upgrade over the plain `Notify`.
- **Inventory module** — `ox_inventory`, `tgiann-inventory`, `qb-inventory`, `ps-inventory` (Project Sloth), `lj-inventory`, `none`. `GetInventoryName`, `HasItem`, `GetItemCount`, `AddItem`, `RemoveItem`, `GetInventory`, `ClearInventory`, `CanCarryItem`, `GetItemDefinition`, `GetItemCatalog`.
- **Target module** (client-only) — `ox_target`, `tgiann-target`, `qb-target`, `none`. `GetTargetName`, `AddBoxZone`, `AddEntityTarget`, `AddModelTarget`, `RemoveZone`, `RemoveEntityTarget`, with one canonical options shape across every integration.
- **Framework layer additions** — `GetJobs`, `SetPlayerJob`, `SetJob`, `HasPermission`, `CreateUseableItem`.
- **Offline / bulk player queries** (DB-backed, work regardless of online status) — `GetOfflinePlayer`, `GetEmployeesByJob`, `GetAllCharacters`, `SetOfflinePlayerJob`, `AddOfflinePlayerMoney`.
- `INTEGRATION_GUIDE.md` — full API reference tables and worked examples for resources consuming `rps_lib`.

### Fixed

- `CreateUseableItem` no longer errors when called at the very top level of a resource's server script (the conventional place to register useable items) before framework detection finishes — a too-early call is now queued and flushed automatically instead of hitting a nil `lib.framework.impl`.
- The server and client callback dispatchers (`RegisterServerCallback`/`TriggerServerCallback`, `RegisterClientCallback`/`TriggerClientCallback`) now isolate a misbehaving registered handler with `pcall` and print a clear diagnostic, instead of letting one buggy consumer crash the shared event handler for every other resource using it.
- Notification auto-detection now checks `codem-supreme-notification` *before* `ox_lib`. `ox_lib` is a hard dependency of this resource for unrelated reasons (always installed), so checking it first meant a server that installed `codem-supreme-notification` specifically for notifications would never actually get it.
- `esx_ambulancejob`'s `IsPlayerDead` now reads the `isDead` statebag (confirmed against an installed copy of the job) — it previously read a `dead` statebag that this job never actually sets.

## v1.0.0 — initial release

Framework-agnostic core: auto-detects ESX / QBCore / QBox / standalone. `GetFrameworkName`, `GetPlayerData`, `Notify`, `AddMoney`/`RemoveMoney`/`GetMoney`, `GetIdentifier`, plus the client↔server callback bridge (`RegisterServerCallback`/`TriggerServerCallback`, `RegisterClientCallback`/`TriggerClientCallback`) and the `lib.table`/`lib.string`/`lib.math`/`lib.print` shared helpers. Consumed via the `@rps_lib/init.lua` quick-include or classic `exports.rps_lib:` calls.
