# xonsight-livesync

A small standalone FiveM resource that automatically keeps the Evidence
Portal's `/live` page in sync with who's currently recording. Xon Sight
itself has no webhook for this (only for evidence), so this resource polls
`exports.XonSight:GetActiveRecorders()` on an interval and pushes the roster
to the site's `/api/xonsight/recorders/sync` extension endpoint.

## Install (do this yourself - nothing here does it automatically)

1. Copy the `xonsight-livesync` folder into your FiveM server's `resources/` directory.
2. Edit `config.lua`:
   - `Config.SiteUrl` — the evidence portal's base URL (e.g. `http://1.2.3.4:5010`).
   - `Config.ApiKey` — must match `XONSIGHT_WEBHOOK_KEY` in the site's `.env`.
3. Add `ensure xonsight-livesync` to `server.cfg`, **after** `ensure XonSight`.
4. Restart the resource (or the server).

Set `Config.Debug = true` temporarily if recorders aren't showing up on
`/live`, then check the server console for sync failures.
