# Changelog

All notable changes to this resource are documented here.

## [1.0.3]

### Changed
- `Config.MedicTimeout`: if the medic can't path to the player in time, the player is now faded out, teleported to the medic, and treatment starts immediately from there — instead of the request being abandoned and refunded.
- Extended the server-side safety-net refund from `Config.MedicTimeout + 5s` to `Config.MedicTimeout + Config.ReviveTime + 10s`, since the client now continues straight into a full revive after teleporting; the old, shorter buffer would have fired mid-CPR and wrongly refunded a player who was actually being treated.

### Removed
- The water-detection/teleport-to-land logic added mid-development (`IsPlayerInWater`/`FindNearestLandCoord`) — the pull-to-medic behavior above already covers a medic stuck in/blocked by water, along with every other "can't path here" case, so the water-specific code was redundant.

### Known issues
- The revive progress bar can still fail immediately with the generic error message in some cases; added `useWhileDead = true` to the `ProgressBar` call as a likely fix (ox_lib cancels progress bars on a "dead" player by default) but this is not yet confirmed resolved — under investigation.

## [1.0.2]

### Changed
- Converted the resource from QBCore to ESX Legacy, then migrated again to `rps_lib` (framework-agnostic layer) for notifications, the progress bar, money, and ambulance-job dead/revive detection. The resource now runs unmodified on ESX, QBCore, QBox, or standalone.
- EMS-online counting is now framework-agnostic too, via `rps_lib`'s `GetPlayerData` plus a new `Config.AmbulanceJobName` (loops `GetPlayers()` instead of calling an ESX-only job-count API).
- Payment now happens atomically inside the server-side request callback, before the client is told to proceed — closes a dupe where a modified client could spawn the AI medic without ever paying.
- The "are you downed" check moved fully server-side after discovering `ESX.PlayerData.dead` is never synced by this server's `esx_ambulancejob` on a normal death; a client-side pre-check based on it was falsely blocking legitimate downed players. It was later restored client-side once `rps_lib`'s `IsPlayerDead()` (backed by the real `isDead` statebag) proved reliable.
- Renamed the resource folder from `uj-aimedic` to `rps_aimedic` (and the `lib` dependency to `rps_lib`) to match this pack's naming convention.

### Added
- `Config.Cooldown` and a server-tracked pending-request flag to stop spamming `/aimedic` or double-spawning medics.
- `Config.MedicTimeout`: if the medic can't path to the player in time, the request is abandoned and automatically refunded (verified server-side, not client-reported).
- Cleanup on player disconnect and on resource stop (previously a medic ped/blip could be orphaned).
- `Config.Messages` — all notification text moved out of code and into config.

### Fixed
- `RemovePedElegantly` was called but never defined, so every completed treatment threw a runtime error instead of cleaning up the medic ped/blip.

### Notes
- Society/job-account payout (`society_ambulance`) has no generic equivalent in `rps_lib`, so it remains ESX-specific, gated on `GetFrameworkName() == 'esx'`, with a marked extension point for QBCore/QBox.

## [1.0.1] - Initial release

- QBCore-based `/aimedic` command: spawns an AI medic when too few EMS are online, walks it to the downed player, plays a revive animation with a progress bar, and charges a configurable price.
