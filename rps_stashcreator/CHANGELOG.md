# Changelog

All notable changes to this resource are documented here.

## [1.0.1]

### Added
- ACE permission/group support for the `/stashcreator` admin gate (`Config.AdminPermission`), checked via `rps_lib:HasPermission`, on top of the existing `Config.Admins` identifier allowlist.
- `Config.InteractionMode`: choose between `'3dtext'` (walk up, see a floating label, press E to open) and `'target'` (registers a zone per access point via `rps_lib`'s `AddBoxZone`, using whatever target system it detects — ox_target/qb-target/tgiann-target).
- Laser raycast tool for placing access points — aim the camera anywhere in view and press Enter to place at the hit point, instead of needing to physically stand on the spot.
- `DrawText3D`/`DrawText3DSimple` exports added to `rps_lib` (previously internal-only), including a new `fancy` mode (breathing glow halo, accent border frame, accent-tinted title line, optional pulsing ground marker) now used for the stash access-point label.
- Empty-state hints ("No job restrictions — accessible to any job.", etc.) for the Job Access / Character Access / Access Points lists in the Create and Edit forms.
- `dependency 'rps_lib'`. Deployed `rps_lib` itself (previously only present as an unpacked-nowhere `.zip`) to `[standalone]/rps_lib` so it can actually run.

### Changed
- Migrated from a hardcoded QBCore (`qb-core`) + `qs-inventory` integration to framework-agnostic `rps_lib` for player data, job lookups, admin permission checks, and notifications. The server this resource actually runs on is ESX Legacy + `tgiann-inventory` — neither of which the original QBCore/qs-inventory calls could ever reach, so the resource was non-functional before this migration.
- Stash registration/opening now targets `tgiann-inventory`'s real server/client API (`RegisterStash`/`OpenInventory`) directly, since `rps_lib` has no stash-registration abstraction for any inventory.
- Character search now uses `rps_lib`'s `GetAllCharacters` instead of a QBCore-shaped `players`/`charinfo` JSON query that didn't match this server's ESX `users` table schema.
- UI redesign: animated gradient border on the main and edit panels, glowing header icon, gradient tab underline, button shine-sweep hover effect.
- Cleaned up the stash ID badge formatting — it zero-padded on the assumption of a short numeric ID, which broke once IDs became random 8-character strings.

### Fixed
- Every NUI action (create/save/delete/close/search/capture) was silently doing nothing — `web/app.js` posted to the wrong resource name (`rps_stashecreator` instead of `rps_stashcreator`), a typo that made every `fetch()` call fail and get swallowed by its own error handler.
- Removed a full-viewport solid black background layer (`bg-particles`) that sat behind the whole UI at all times, blocking the game view even when nothing else needed it.
- Removed `backdrop-filter` from every panel/modal — FiveM's NUI browser (CEF) renders it as solid black instead of blurring the game behind it, which was blacking out the entire screen whenever any panel was open.
- Removed the remaining solid black scrims behind the delete-confirmation modal and the access-point capture overlay (blur only now, no black tint).
- Fixed vertical centering of `rps_lib`'s 3D text — the background box and the text lines were positioned from two independent approximations that didn't actually agree, most visible with multi-line "fancy" labels.
- Fixed the Edit Stash panel rendering as a narrow, mostly off-screen strip in-game. It centered itself via `position: absolute` + `transform`, a self-centering trick with no flex participation that FiveM's CEF apparently doesn't resolve the same way a desktop browser does. Restructured it as a full-viewport flex-centered overlay wrapping an inner card — the same proven pattern already used by the delete-confirmation modal, which never had this problem.

## [1.0.0] - Initial release

- QBCore/qs-inventory-based stash creator: admin UI (NUI) to create, edit, and delete job/character-gated stashes with in-game 3D-text access points.
