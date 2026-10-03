# Changelog

## v2.0.5 - 2026-10-01

### Added
- **Employees app on the Billing Tablet**: bosses/owners can now manage staff directly from the tablet (roster, hire nearby, fire, manage rank/wage/permissions, bonuses) — reuses the exact same `Employees` component and permission checks as the desktop Boss Menu. Gated strictly to `isOwner`/actual boss, not the broader granular-perm set the desktop allows. New `BuildEmployeeRoster` shared helper (`server/main.lua`) backs both surfaces so they can't drift out of sync; new `rps-bossmenu:server:getEmployeesCallback` (`server/billing.lua`) and `getEmployees` NUI callback (`client/billing.lua`).
- **Companion LB Phone app** (`rps_bossmenu_phone`, separate sibling resource): the same Employees management screen as a phone app instead of a physical tablet. It carries no business logic of its own — every action forwards to this resource's existing server events/callbacks, so the phone app and the tablet always see identical data and permissions. Built fresh in React + TypeScript against the [lb-phone-app-template](https://github.com/lbphone/lb-phone-app-template) structure (there's no source for the tablet's compiled UI to port from). Requires `lb-phone` installed and running; see `rps_bossmenu_phone/README.md` for build steps.

### Changed
- `giveBonus` (`server/bossmenu.lua`) no longer enforces an upper cap — removed the now-unused `Config.MaxBonus`. The real ceiling is just whatever's actually in the society account, same as every other money flow.

## v2.0.4 - 2026-09-29

### Fixed
- `Config.TabletItem` (`config.lua`) was never actually respected server-side — `server/billing.lua` registered the `tablet` useable item unconditionally (`Config.TabletItem or 'tablet'` always evaluated truthy even when the config was `false`), so command-only setups still had a working item hand-out path. The item now only registers when `Config.TabletItem` is a string, and it's enabled by default.
- The compiled UI (`ui/dist/assets/index-B200Eyr7.js`) shipped with roughly 8,400 corrupted character sequences across ~10 strings — the menu-bar icon, the roster's "rank • wage" line, the calculator's `÷`/`×`/`−`/`±` buttons, a typing-animation placeholder, a number-formatting ellipsis, the society log separator, and the tablet settings header icon were all mangled multi-generation mojibake baked into the shipped bundle. Decoded and corrected in place; verified no corruption or replacement characters remain.
- The Billing Tablet's device frame was shrunk to a fixed height that clipped the POS Terminal's numpad — the `0`, `.`, `C` keys and the "Send Invoice" button were cut off below the visible frame. Frame height increased so the full keypad fits.

### Changed
- Society/business bank money (`GetSocietyBalance`/`AddSocietyMoney`/`RemoveSocietyMoney` in `server/main.lua`) now lives in ESX's own `society_<job>` shared account (`esx_addonaccount`) instead of a private `rps_businesses.balance` column, so other ESX resources reading/writing society funds stay in sync with this menu. A one-time startup migration sweeps any existing `rps_businesses.balance` into the real account and zeroes the old column.
- Billing Tablet device frame reworked from its original fixed 900×600 box into a properly sized, repositioned tablet mockup (900×600 → fullscreen → 850×620), with the camera dot and home button restored to the left/right side bezel.

## v2.0.3 - 2026-09-28

### Security
- `rps-bossmenu:server:orderItems` (`server/delivery.lua`) no longer trusts the client-supplied `total` for Jungle Shop checkouts — a modified NUI/client could previously submit any cart with any total, letting a business pay far less than the real catalog price for goods (an economy dupe). The server now looks up the seller shop's own catalog (`rps_jungle_shops.items`) and recomputes the total itself from item price × quantity, rejecting the order if a cart item isn't in the catalog or has an invalid quantity.

### Added
- New ACE-permission path to the `/bossadmin` panel: `Config.AdminAce` (`config.lua`, default `'rps_bossmenu.admin'`) grants admin-panel access via `add_ace <group> rps_bossmenu.admin allow` in `server.cfg`, on top of the existing framework admin/god rank check. Set it to `false` to disable the ACE path. All checks now go through a single `IsBossmenuAdmin(src)` helper (`server/main.lua`).

### Fixed
- `checkAndRemoveOrderItems` and `deliveryComplete` (`server/delivery.lua`) used a raw `json.decode` on the stored order `items` column, which would throw if a row were ever corrupted. Both now use the existing `SafeDecode` helper and fail gracefully instead.

## v2.0.2 - 2026-09-15

### rps_lib migration
- Replaced every direct ESX/QBCore/QBox, `ox_target`/`qb-target`, and `ox_inventory`/`qs-inventory`/`qb-inventory`/`tgiann-inventory` call with `exports.rps_lib:...` — `client/bridge.lua` and `server/bridge.lua` are now thin wrappers around `rps_lib`, and `Config.Framework`/`Config.Inventory`/`Config.Target` are gone from `config.lua` entirely. The resource now runs on whatever `rps_lib` detects, with no per-server config needed here.
- Extended `rps_lib` itself with capabilities it didn't previously have, since it's the sole framework/inventory/target layer now: `SetPlayerJob`/`SetJob` (job writes for hire/promote/fire), `GetJobs`, `HasPermission` (gates `/bossadmin`), `CreateUseableItem`, `GetItemDefinition`/`GetItemCatalog` (item-label lookups), and an enriched `GetPlayerData` with `isboss`, full grade `{level, name}`, and `firstname`/`lastname` (previously missing entirely — `rps_lib` only exposed a bare grade-level number).
- Dropped `fxmanifest.lua`'s hard-coded `@qb-core/shared/locale.lua` include (unused `Lang` global, and would have broken startup on a non-QBCore server) and the direct `@ox_lib/init.lua` includes (now covered transitively through `rps_lib`'s own dependency); added `dependency 'rps_lib'`.

### Fixed
- The delivery truck's "Receive Delivery" target interaction broke during the `rps_lib` migration — the client-side target-option converter was triggering the event with just the raw entity handle instead of the full `{ entity, ... }` data table the handler reads `data.entity` from.
- `rps-bossmenu:server:deliveryComplete` unconditionally notified "You received your ordered items!" even when every item failed to add, and returned silently (no notification at all) on several earlier failure paths — wrong business, no permission, order already completed/not found, corrupted item payload. All of these now notify the player and log a tagged reason to the server console.
- Weapon items (`weapon_*`) delivered through the Jungle order system or unpacked from a delivery box silently failed to add — `tgiann-inventory` requires `serie`/`ammo`/`usedTotalAmmo`/`durabilityPercent` metadata for any firearm, which this resource never supplied. Added `BuildItemMetadata` (`server/main.lua`) to auto-generate it for any `weapon_*`-named item; every `AddItem` call path now goes through it.

### Notes
- `BuildItemMetadata`'s field names match `tgiann-inventory`'s documented weapon-metadata requirement specifically — if this server ever switches inventories, that's the one place to update.
