# opslabs-license — OPSHUB licensing

    OPSHUB licensing API → license → customer → this server (instance) → the modules it may run

The **only** place an OPS installation keeps its license. Every other OPS resource asks this one
(`exports['opslabs-license']:HasModule('pos')`, `:IsLicensed()`, `:State()`); none has its own key or check.

## Setting it up
- **Key:** `set opshub_license "OPSHUB-XXXX-XXXX-XXXX-XXXX"` in server.cfg (preferred — keeps it out of the resource files),
  or `Config.LicenseKey` in config.lua, or leave both empty and an admin enters it once on the OPS Phone's
  **OPSHUB License Setup** screen (`add_ace group.admin opshub.license allow`).
- **Console:** `opshub status` · `opshub activate OPSHUB-…` · `opshub refresh` · `opshub release`

## How it works
1. Activation sends the key and this server's instance id (random, kept in this resource's KVP) to
   `https://opsphone-store.opslabsystems.cloud/license/api/v1/activate`. OPSHUB checks the license (status, expiry,
   IP rules, instance limit), registers the instance and answers with a check-in secret and an **Ed25519-signed
   certificate** listing the modules.
2. The certificate is only believed if its signature verifies against `Config.PublicKey` (server/verify.js) and it was
   issued to this instance — editing the cached copy or copying another server's breaks it.
3. Every `Config.CheckEvery` seconds the server checks in and gets a fresh certificate, so modules switched on/off,
   suspensions and revocations on OPSHUB apply within ~10 minutes. If OPSHUB can't be reached the cached certificate
   keeps working until it runs out (OPSHUB grants 72 h).
4. **Resource modules** (opslabs-towers, -props, -pos, -guide, -animations, -connect, -bodycam) are started / stopped
   to match the license (`Config.Enforce`) *and* whether they're switched on (below). **OPS Phone** is never stopped:
   it shows the license screen when unlicensed and gates each app's calls by its module (opslabs-phone/server/license.lua).

## Enabled / disabled — separate from the license
Being entitled to a resource module only means the license *may* run it — it still starts switched **off**
on every server until someone turns it on, either at the customer portal's `/license/<id>/scripts` tab (or
the admin portal's matching section on a license's page), or locally per-server regardless of the portal in
`Config.ForceEnabled` here (e.g. `Config.ForceEnabled = { towers = true }`) — that can only switch ON a
module the license already covers, never grant one it doesn't. This is why the certificate carries two
separate lists: `modules` (entitled - unaffected, still what feature-level gates like `HasModule()` use) and
`enabled` (entitled **and** switched on - what actually starts/stops a whole resource).

## Managing licenses
- Admin portal: `/license/admin` on OPS Hub (licenses, keys, Allow All, per-module entitlements, expiry, instance and
  IP limits, customers, modules, logs, suspicious attempts, API tokens).
- Client portal: `/license` (customers see their keys, status, expiry, instances and modules).

## Auto-updates (`tools/ops-update-companion.py`)
A resource module's files can update themselves: an admin publishes a new version at
`/license/admin/modules/<code>/releases` (version, release notes, a .zip of that resource's own files), and
`tools/ops-update-companion.py` — a separate process run alongside FXServer, same reasoning as
`opslabs-bodycam/tools/upload-companion.py` (no unzip native and no proven-safe way to pull a multi-MB
binary HTTP response in-process) — polls for it, verifies the signed manifest plus a sha256 of the
download, and swaps the resource's files on disk. It then drops a `.opshub-update-pending` marker in the
resource's own folder; this resource's own check-in loop (above) notices it and does the actual
`StopResource`/`StartResource`. `--rollback <code>` swaps the previous local copy back. See the script's own
`--help`/docstring for the systemd unit to keep it running.

## No companion process possible? (`server/installer.lua`)
Some hosts only give you the txAdmin panel + SFTP - no shell, no way to run
`ops-update-companion.py` at all. For those, this resource installs updates **itself**: every
check-in it also asks `/updates/check` for each entitled-and-enabled resource module, and if one's
available, downloads a small derived artifact (`/updates/<code>/pack` - not the .zip; FXServer's Lua
has no .zip parser), verifies its sha256 against the same signed manifest, decompresses it with the
vendored `libs/LibDeflate.lua` (zlib-licensed), and writes the files with `SaveResourceFile` - rejecting
any entry whose path tries to escape the resource's own folder before writing anything. It then drops
the same `.opshub-update-pending` marker as the companion script, so the restart happens through that
one shared path either way. A plain server restart is then enough to pick it up - nothing else to run.
This can only add/overwrite files, not delete ones removed in a newer version, and keeps no rollback
copy - `ops-update-companion.py` is still the fuller-featured path for anyone with real OS access.

Note: Lua resources can always be edited by whoever runs the server. The signed certificate stops a copied or tampered
installation from *granting itself* modules through the license; protecting the code itself needs Cfx asset escrow.
