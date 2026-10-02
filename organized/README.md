# Nginx sites-available — reorganized

This is your `backupwebsite.zip` cleaned up and reorganized. It's an Nginx
`sites-available` folder for a server running ~20 subdomains, mostly under
`opslabsystems.cloud`, plus `docs.realplayscripts.co.za` and
`order.ciodrawz.space`.

## What changed

**Naming:** every file is now named consistently as `<domain>.conf`, so it's
obvious what each one is without opening it (some originals had no extension,
e.g. `Directry`, `linkshare`, `remote`, `cloudloader`).

**Deleted, no risk:**
- `web.opslabsystems.cloud` — an empty (0-byte) stray file.

**Merged duplicates (same backend, just redundant files):**
- `linkshare` + `linkshare.opslabsystems.cloud` → `linkshare.opslabsystems.cloud.conf`
- `stocktoolsetup` + `stocktoolsetup.opslabsystems.cloud.conf` → one file, keeping the larger 2G upload limit and extended timeouts
- `api-stocktool.conf` + the API block inside `stocktool.conf` → `api-stocktool.opslabsystems.cloud.conf`, keeping the extra `proxy_buffering off` / long timeout tuning

**Cleaned:**
- `default` — removed a stray `server {}` block for `stocktool.opslabsystems.cloud` that had been accidentally left in the system default file (looks like Certbot was run against it directly instead of a dedicated site file). It now only contains the standard Debian default server.

## ⚠️ Three real conflicts — in `CONFLICTS_NEEDS_YOUR_INPUT/`, need your decision

These aren't formatting issues — each domain had **two configs pointing at
different backend ports**, which is a genuine "which one is actually live"
question I can't safely answer for you. Nginx would have thrown
`conflicting server name` warnings and served only one of them, silently.

| Domain | Option A | Option B | I made active |
|---|---|---|---|
| `stocktool.opslabsystems.cloud` | broken static-file block in `default` | `:8000` (HTTPS, "Admin frontend") | `:5035` (HTTP only, same port as `client-stock`) → **B** kept, extra broken option removed |
| `web.opslabsystems.cloud` | `:5800` (HTTP only) | `:5041` (HTTPS) | **HTTPS version (:5041)** |
| `websites.opslabsystems.cloud` | `:5801` (HTTP only) | `:8000` (HTTPS, but using the wrong SSL cert — `web.opslabsystems.cloud`'s cert instead of its own) | **HTTPS version (:8000)**, cert path fixed to point at its own domain |

For each, I kept the HTTPS/Certbot-managed side active (losing SSL is the
worse failure mode) and left the other option commented out in the same file
so nothing is deleted outright. **Before deploying these**, please confirm on
the actual server which backend process is currently running on each port —
that's the only way to know for certain which config is correct. Once
confirmed, move the file into `sites-available/` and delete the commented-out
block.

## Layout

```
organized/
├── README.md
├── sites-available/                     ← ready to use as-is
│   ├── default
│   ├── opslabsystems.cloud.conf         (bare domain → redirects to web.)
│   ├── web... (all the clean, non-conflicting domains)
│   └── ...
└── CONFLICTS_NEEDS_YOUR_INPUT/          ← review before deploying
    ├── stocktool.opslabsystems.cloud.conf
    ├── web.opslabsystems.cloud.conf
    └── websites.opslabsystems.cloud.conf
```

## Deploying

On the actual server, each file in `sites-available/` (and the conflict files
once you've confirmed them) would go to `/etc/nginx/sites-available/`, then
be symlinked into `/etc/nginx/sites-enabled/`. Always run `nginx -t` before
reloading:

```bash
sudo cp sites-available/*.conf sites-available/default /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/*.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```
