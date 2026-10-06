# Changelog

## v1.0.3 - 2026-10-01

### rps_carry
- Added a permission step: carrying someone now sends them a request instead of starting instantly. The target gets an `exports.rps_lib:Notify` and two new `rps_lib` target options — "Accept Carry Request" / "Decline Carry Request" — added to the requester's ped (`AddEntityTarget`/`RemoveEntityTarget`, same API `rps_parking`'s `PoliceOptions` already uses), and the carry only starts once they accept.
- New `config.lua` (shared, loaded before `cl_carry.lua`/`sv_carry.lua`): `Config.RequirePermission` (default `true`) toggles the whole feature on/off — set `false` to restore the old instant-carry behavior — and `Config.RequestTimeout` (default `15000`ms) controls how long a request stays valid before auto-declining.
- The "Waiting for them to accept..." notification only shows when `Config.RequirePermission` is `true`; the "No one nearby to carry!" check is unconditional either way.
- Range/busy checks are re-validated both when the request is sent and again when it's accepted, so moving out of range or being grabbed by someone else mid-request fails safely instead of attaching to stale coordinates.
- `config.lua` added to `fxmanifest.lua`'s `shared_scripts` and `escrow_ignore`.

## v1.0.2 - 2026-09-15

### rps_lib integration fix (all modules)
- `rps_handsup`, `rps_vehicleradio`, `rps_crosshair`, `rps_carry` were all calling `exports['rps_lib']:GetLibObject()`, which no longer exists on the current `rps_lib` (it only exposes exports, not a shared object) — every one of these scripts would hard-error on resource start. Switched all four to call `exports.rps_lib:FunctionName(...)` directly.
- Removed a dead `RPS_Lib.AddGlobalPlayer(...)` target-menu block from `rps_carry` — `rps_lib` has no targeting module, and no `ox_target`/`qb-target` is installed on this server, so the call would have errored before the file's `RegisterNetEvent` handlers even registered. The proximity-based `carry` command/keybind is unaffected.

### rps_handsup
- Added a watchdog thread so the hands-up/kneel animation stays continuous — it only re-applies the anim when the ped has actually fallen out of it (e.g. from movement), instead of resetting on every tick.
- Hands-up animation changed to `missminuteman_1ig_2` / `handsup_base` (kneel animation unchanged: `random@arrests` / `kneeling_arrest_idle`).
- Removed all `Notify` calls (hands up / hands down / kneeling / standing messages) — the script now toggles silently.

### rps_point (new)
- Added a new "point" module: press **B** to toggle a full-arm pointing gesture on/off (rebindable in FiveM's Key Bindings menu under "Point").
- Uses the same move-network task GTA Online itself uses for pointing (`task_mp_pointing` on `anim@mp_point`), so the point direction tracks the camera continuously for as long as it's toggled on, rather than playing a fixed clip.
- Fixed a stop-toggle bug: the "stop pointing" native copy-pasted from every public reference for this feature (`0xD01015C7316AE176`) doesn't actually stop anything — FiveM's own native docs resolve that hash to `SET_PED_CLOTH_PACKAGE_INDEX`. Replaced it with `ClearPedTasks`, so pressing B a second time now actually stops the point instead of leaving the pose running underneath.
- Removed all `Notify` calls — toggles silently, same as hands-up.
- Registered in `fxmanifest.lua`'s `client_scripts`.

### rps_carry
- Reviewed for notification cleanup — no change needed. It only ever had the single "No one nearby to carry!" error notification, which stays.
