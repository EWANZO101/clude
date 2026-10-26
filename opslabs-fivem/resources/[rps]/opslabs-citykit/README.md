# opslabs-citykit

Outdoor dressing props for custom maps / MLOs — concrete, kerbs, fences, gates, street lighting, barriers and
landscaping — built entirely from **real, verified vanilla GTA V models** (no new 3D art). Same raycast
ghost-prop placement feel as opslabs-towers, written fresh here since that tool is wired into its own
cabling/power data model and isn't exported for other resources to call.

## Setup

1. Run `sql/install.sql` against your database.
2. Grant yourself access — either:
   - `add_ace group.admin opslabs.citykit allow` in `server.cfg` (recommended, matches `Config.AdminAce`), or
   - add your license to `Config.AdminLicenses` in `config.lua`.
3. **Grant this resource a module in opslabs-license (OPSHUB).** Like every OPS/`[rps]` resource, every server
   event, callback and command here is gated by `@opslabs-license/guard.lua` — until `opslabs-citykit` is
   licensed the same way your other resources are, nothing will respond, even to an admin.
4. Add `ensure opslabs-citykit` to `server.cfg` after `opslabs-license`, `ox_lib`, `oxmysql` and `rps_lib`.
5. In game: `/citykit` opens the catalog.

## Using it

- `/citykit` → pick a category → pick an item → aim where you want it.
- While placing: **E** place, **Backspace** cancel, **A/D** rotate, mouse wheel (held) fine-rotate, **Page Up /
  Page Down** raise/lower (hold **Shift** for fine height steps).
- Stand next to an already-placed prop and press **E** to move or delete it.

## What's in the catalog, and what isn't

Every model in `config.lua` was checked against the live game's actual object list (the `DurtyFree/gta-v-data-dumps`
`ObjectList.ini` dump) and cross-referenced on `gtahash.com` / `forge.plebmasters.de` for a description — nothing
was added from memory or guessed. A few categories you'd reasonably expect are **genuinely absent from vanilla
GTA V** and are left in the catalog as empty, documented categories rather than silently dropped or filled with
a guess:

- **Road markings / line decals** — baked into the road texture in GTA V, not a placeable prop. Would need a
  custom decal/material (e.g. a ytyp archetype), not an object in this catalog.
- **Drainage** (manhole covers, drain grates, gutters) — no equivalent prop exists at all.
- **Fake/artificial grass mats** — only sparse natural grass tufts exist; nothing reads as astroturf.
- **Pavement / footpath tiles** — baked into the sidewalk mesh, not a standalone prop.
- **Garden walls / wall panels** and a **picket or wrought-iron fence family** — also absent (the "wall" props
  that do exist are single blocks/fragments, not panel sections).

If you get custom `opslabs_*` art made for any of these later, drop it straight into that category's `items`
list in `config.lua` — nothing else about the resource needs to change.

### A note on the "kerb" category

The kerb props (`m23_2_prop_m32_curb_*`, `m24_1_prop_m41_curb_*`) come from DLC map-authoring sets and are
flagged by their own community documentation as integrated road geometry rather than freestanding props. They
do respond to `CreateObject`, but test placement and collision in game before relying on them for anything
load-bearing.

### Gates

The gates in this catalog are **static/decorative** — good for dressing a compound entrance, a farm gate, a
driveway, etc. They don't open, lock, or take a PIN. For a *functional* animated gate (auto-open, lock, PIN
keypad, live brand board), that's what opslabs-towers' `Config.Buildings` gate-frame system (`opslabs_gate_*`
models in `client/doors.lua`) already does — this resource is a complement to that, not a replacement.
