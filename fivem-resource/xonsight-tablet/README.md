# xonsight-tablet

An in-game tablet officers can pull out to open the Xon Sight evidence
portal without tabbing out of GTA. It's a stock GTA V prop (no custom
model) held in-hand, paired with an NUI window that iframes your actual
site - so it's always showing the real portal, not a reimplementation of
it. Log in once inside the tablet; the NUI browser keeps its own cookie
storage between uses, same as a normal browser tab.

## Install (do this yourself - nothing here does it automatically)

1. Copy the `xonsight-tablet` folder into your FiveM server's `resources/` directory.
2. Edit `config.lua`:
   - `Config.SiteUrl` — the evidence portal's base URL (e.g. `http://1.2.3.4:5010`), same value as `xonsight-livesync`'s `Config.SiteUrl`.
   - `Config.StartPath` — which page opens first (`/dashboard` by default).
   - `Config.ToggleKey` — the keybind that opens/closes it (`F6` by default; players can rebind it themselves too, it's registered as a real FiveM keymapping).
   - `Config.AllowedJobs` — leave empty to let anyone open it, or wire `GetPlayerJob()` in `client.lua` to your framework (ESX/QBCore/etc) and list job names here to restrict it to on-duty officers.
3. Add `ensure xonsight-tablet` to `server.cfg`.
4. Restart the resource (or the server).

## Notes

- Uses `prop_cs_tablet`, a vanilla GTA V prop - nothing to stream in. If
  you'd rather use a different tablet-shaped prop, change
  `Config.PropModel` (and re-tune `Config.AttachBone` /
  `Config.AttachOffset` / `Config.AttachRotation` if the new model's
  pivot point is different).
- The window is a resizable bezel (not fullscreen) so it reads as "holding
  a device," not a menu — sized to roughly match a tablet's aspect ratio.
  At that width Xon Sight's own responsive layout switches to its compact
  mobile header automatically; no separate "tablet mode" page is needed.
- `Config.DisableAttackWhileOpen` stops the player from firing/aiming
  while the tablet is up (they're holding it with both hands). Movement
  stays enabled on purpose, same as most phone resources.
- This resource only opens a browser window onto pages Xon Sight already
  serves — it doesn't add any new site routes or APIs. Anything you can
  reach by logging into the portal normally, you can reach from the
  tablet.
