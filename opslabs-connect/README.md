# opslabs-connect — connect a server to the OPS Hub

Multi-server OPS: register your server on **https://opsphone-store.opslabsystems.cloud/new-hub** (the Server Owner Hub),
then connect it with this resource. Your OPS data gets its own private database on the OPS Hub, and your server gets its
own OPS Hub at `yourname.opslabsystems.cloud` (or your own domain).

Without a token this resource does nothing and OPS keeps using your local database (self-hosted set-ups).

## Install

```cfg
set ops_api_url "https://opsphone-store.opslabsystems.cloud"
set ops_server_token "opsk_…"            # from /new-hub → your server → Connect (or pair from the Dev App, below)
# set ops_public_url "https://play.example.com"   # only if your server isn't listed on cfx.re (the Hub calls your REST API here)

ensure oxmysql
ensure opslabs-connect                   # BEFORE opslabs-towers and opslabs-phone
ensure opslabs-towers
ensure [rps]
```

**Pairing instead of a token:** start the server with opslabs-connect (no token), open the phone → **Developer** app →
**OPS Hub Connection** → **Get a pairing code**, and enter the code on `/new-hub/pair`. The token is stored in this
resource's KVP. Restart the server to switch OPS over. Console: `opsconnect pair`.

## What happens in hosted mode

- opslabs-phone and opslabs-towers load `lib/db.lua` (through their `server/opsconnect.lua`). Every query that touches an
  OPS table (`ops_*`, `opslabs_*`) goes to your hosted database over HTTPS (`POST /api/v1/db`, your token); everything
  else (`users`, `billing`, `owned_vehicles`, `items` …) stays on your local oxmysql database. Same API, same results.
- Player names and jobs (never money or inventory) are mirrored to the hosted `users` table every 15 minutes and on
  login, so staff lists and reports show names.
- The Hub reaches your server's REST API (`opslabs_phone_api_key` — created for you if missing) at your cfx.re address or
  `ops_public_url`.
- A heartbeat every 60 s keeps your server "online" on `/new-hub`. If the Hub is unreachable, reads retry; writes fail
  like a database outage would (printed in the console).

## Moving an existing server

If the server already ran OPS on its own database: connect, restart, then run once in the server console

    opsconnect upload          # copies every local ops_* / opslabs_* table to the hosted database
    opsconnect upload force    # also into tables that already have rows (existing keys are left alone)

then restart opslabs-towers and opslabs-phone.

## Console

| Command | |
|---|---|
| `opsconnect` | status: token, connection, database, server, Hub address, last error |
| `opsconnect pair` | get a pairing code |
| `opsconnect forget` | remove a paired token (not one from server.cfg) |
| `opsconnect upload [force]` | copy local OPS tables to the hosted database |

## Exports (server)

`isHosted()`, `status()`, `awaitReady(ms)`, `startPairing()`, `forget()`, `db(op, sql, params, cb)`.
