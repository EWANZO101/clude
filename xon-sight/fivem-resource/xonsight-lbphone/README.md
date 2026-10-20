# xonsight-lbphone

Adds Xon Sight to [LB Phone](https://docs.lbscripts.com/phone/custom-apps/)
as an installable app, using lb-phone's own `AddCustomApp` export rather
than editing `lb-phone/config/config.lua` - this whole integration is one
drop-in resource. It does two things:

1. **Viewer** - the app itself is just an iframe onto your real site, not a
   reimplementation of it. Log in once inside the app and it stays logged
   in between opens (the phone's NUI browser keeps its own cookie storage).
2. **Capture** (optional, on by default) - a "Record evidence" button that
   uses LB Phone's own camera (`useCamera`, documented in LB Phone's
   client-exports) to record video and submit it straight to Xon Sight's
   evidence webhook. **Xon Sight doesn't require OPS Phone / opslabs-bodycam
   specifically** - its webhook contract is generic, any resource that
   POSTs the right fields works, and this is a second, independent way in.
   Turn it off with `Config.AllowCapture = false` if you'd rather evidence
   only ever come from a dedicated bodycam resource.

## Install (do this yourself - nothing here does it automatically)

1. Make sure `lb-phone` is already installed and running on your server.
2. Copy the `xonsight-lbphone` folder into your FiveM server's `resources/` directory.
3. Edit `config.lua`:
   - `Config.SiteUrl` — the evidence portal's base URL (e.g. `http://1.2.3.4:5010`), same value as `xonsight-livesync` / `xonsight-tablet`.
   - `Config.StartPath` — which page opens first (`/dashboard` by default).
   - `Config.DefaultApp` — `true` to install it on every phone automatically; leave `false` to make players download it from the app store.
   - `Config.Price` — leave `nil` for a free download, or set an amount to charge in-game money.
   - `Config.WebhookKey` — must match `XONSIGHT_WEBHOOK_KEY` in the portal's `.env`, or leave blank if the portal has no key configured. Only used by the capture path (`server.lua`'s webhook POST) - the viewer doesn't need it.
   - `Config.AllowCapture` — `false` to hide the capture button and ship this as a viewer-only app.
4. Add `ensure xonsight-lbphone` to `server.cfg`, **after** `ensure lb-phone`.
5. Restart the resource (or the server).

## Notes

- `ui/assets/icon.svg` is the app store icon (the Xon Sight reticle mark).
  Swap it for your own art if you want something else - any image URL
  works, it doesn't have to be this file.
- The viewer only opens pages Xon Sight already serves over HTTP(S) - it
  doesn't add new routes, store any data itself, or need a database. If
  `Config.SiteUrl` is left as the placeholder, the app shows a "not
  configured" message instead of a blank screen.
- The capture path's webhook POST happens in `server.lua`, not the NUI -
  `Config.WebhookKey` never reaches client-side/NUI code.
- `server.lua` has no shared counter to generate the evidence webhook's
  required `id` from, so it derives one from a timestamp + the player's
  server id - good enough to avoid collisions between captures, nothing
  more meaningful than that.
- This resource is independent of `xonsight-tablet` (the standalone
  in-hand prop version, viewer-only) - install either, both, or neither
  depending on whether your server uses LB Phone at all.
