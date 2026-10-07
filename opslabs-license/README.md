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
4. **Resource modules** (opslabs-towers, -props, -pos, -guide, -animations, -connect) are started / stopped to match
   the license (`Config.Enforce`). **OPS Phone** is never stopped: it shows the license screen when unlicensed and
   gates each app's calls by its module (opslabs-phone/server/license.lua).

## Managing licenses
- Admin portal: `/license/admin` on OPS Hub (licenses, keys, Allow All, per-module entitlements, expiry, instance and
  IP limits, customers, modules, logs, suspicious attempts, API tokens).
- Client portal: `/license` (customers see their keys, status, expiry, instances and modules).

Note: Lua resources can always be edited by whoever runs the server. The signed certificate stops a copied or tampered
installation from *granting itself* modules through the license; protecting the code itself needs Cfx asset escrow.
