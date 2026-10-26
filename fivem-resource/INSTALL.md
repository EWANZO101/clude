# Xon Sight — FiveM resource bundle

Two FiveM resources for the Xon Sight bodycam evidence portal.

| Resource            | What it does                                                        | Requires           |
|----------------------|----------------------------------------------------------------------|---------------------|
| **`opslabs-bodycam`** | **Everything** — records the officer's view and uploads it, plus the in-game tablet, LB Phone app and live sync modules, all built in. One `config_server.lua` to connect to your portal (paste your `/integration` setup block in) — leave `Storage.PublicUrl` blank and videos upload straight to the portal, no web server of your own needed. Auto-triggers, voice and live video are optional extras, off by default (see below) | **`opslabs-license`**, with this license's Xon Sight module entitled — won't start without it |
| `opslabs-license`   | OPSHUB licensing client — activates this server with your license key and tells every other OPS resource what it's entitled to | Nothing extra (talks to OPSHUB itself) |

That's it — just the two folders. The tablet, LB Phone app and live-roster sync that used to be separate
resources are now modules inside `opslabs-bodycam` itself (`config_server.lua` → `ServerConfig.Modules`) —
turn any of them off there if you don't want them, nothing extra to install either way.

**Barebones by default.** Out of the box, the bodycam does exactly one thing: record the officer's view and
upload the finished clip to your portal. Live video streaming, voice-in-recordings and voice commands are
all optional extras that ship **off** — each needs its own separate thing you run yourself (MediaMTX, the
OPS Voice bridge) that most servers don't have. Turn them on later in `config_server.lua`'s clearly marked
"OPTIONAL" section once you actually want them; nothing about day-one recording/uploading depends on any of it.

## Quick start

1. Copy `opslabs-bodycam` and `opslabs-license` into your FiveM server's `resources/` directory.
2. Go to your portal's **`/integration`** page (after creating a community at `/get-started`, or
   `/admin/communities` if you run the portal yourself) and copy the setup block shown there.
3. Paste it into `opslabs-bodycam/config_server.lua`'s `ServerConfig.XonSight` block (`Url` and `Token`).
   That's the entire connection — done, and every bundled module picks it up automatically.
4. Set up `opslabs-license`: in its `config.lua` set `Config.LicenseKey`, or `set opshub_license "OPSHUB-…"`
   in `server.cfg`, or leave both blank and enter it once on the OPS Phone's license screen in-game. See
   `opslabs-license/README.md`.
5. That's it for video — leave `Storage.PublicUrl` blank in `config_server.lua` and recordings upload
   straight to your portal automatically. Only set it if you'd rather host the files yourself on a web
   server you run (see `opslabs-bodycam/README.md`'s Install section). Everything else can stay as-is; turn
   `ServerConfig.Modules.Tablet` / `.LbPhone` off there if you don't want them.
6. Add to `server.cfg`, in this order: `ensure opslabs-license` then `ensure opslabs-bodycam`.
7. Restart the resource (or the server).

Full docs: `/docs` on your portal (or `https://xonsight.opslabsystems.cloud/docs`
if you're using the hosted one) — or the short version at `/docs/install`.
