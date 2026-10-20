# xonsight-lbphone

Adds Xon Sight to [LB Phone](https://docs.lbscripts.com/phone/custom-apps/)
as an installable app, using lb-phone's own `AddCustomApp` export rather
than editing `lb-phone/config/config.lua` - this whole integration is one
drop-in resource. Like `xonsight-tablet`, the app itself is just an iframe
onto your real site, not a reimplementation of it - log in once inside
the app and it stays logged in between opens (the phone's NUI browser
keeps its own cookie storage).

## Install (do this yourself - nothing here does it automatically)

1. Make sure `lb-phone` is already installed and running on your server.
2. Copy the `xonsight-lbphone` folder into your FiveM server's `resources/` directory.
3. Edit `config.lua`:
   - `Config.SiteUrl` — the evidence portal's base URL (e.g. `http://1.2.3.4:5010`), same value as `xonsight-livesync` / `xonsight-tablet`.
   - `Config.StartPath` — which page opens first (`/dashboard` by default).
   - `Config.DefaultApp` — `true` to install it on every phone automatically; leave `false` to make players download it from the app store.
   - `Config.Price` — leave `nil` for a free download, or set an amount to charge in-game money.
4. Add `ensure xonsight-lbphone` to `server.cfg`, **after** `ensure lb-phone`.
5. Restart the resource (or the server).

## Notes

- `ui/assets/icon.svg` is the app store icon (the Xon Sight reticle mark).
  Swap it for your own art if you want something else - any image URL
  works, it doesn't have to be this file.
- The app only opens pages Xon Sight already serves over HTTP(S) - it
  doesn't add new routes, store any data itself, or need a database. If
  `Config.SiteUrl` is left as the placeholder, the app shows a "not
  configured" message instead of a blank screen.
- This resource is independent of `xonsight-tablet` (the standalone
  in-hand prop version) - install either, both, or neither depending on
  whether your server uses LB Phone at all.
