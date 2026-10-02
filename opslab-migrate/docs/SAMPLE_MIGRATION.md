# Sample migration walkthrough

Scenario: move `nginx-manager` (Flask + SQLite + gunicorn + systemd + nginx)
and `stocktool` (Flask + MariaDB) from `old-vps` to `swift2`.

## 1. Config

```yaml
source:
  host: old-vps.example.com
  username: root
  ssh_key: ~/.ssh/id_ed25519
destination:
  host: swift2.example.com
  username: root
  ssh_key: ~/.ssh/id_ed25519
restore:
  overwrite: false
parallel_workers: 2
```

## 2. Dry scan

```
$ python migrate.py discover
✓ Connected to old-vps.example.com
        Discovered projects on old-vps.example.com
┏━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┳━━━━━━━┓
┃ Project       ┃ Path              ┃ Framework ┃ Python ┃ Services             ┃ Databases        ┃ Ports ┃
┡━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━╇━━━━━━━┩
│ nginx-manager │ /opt/nginx-manager│ flask     │ 3.12.3 │ nginx-manager.service│ sqlite:app.db    │ 8090  │
│ stocktool     │ /opt/stocktool    │ flask     │ 3.10.12│ stocktool.service    │ mysql:stock      │ 8000  │
└───────────────┴───────────────────┴───────────┴────────┴──────────────────────┴──────────────────┴───────┘
```

## 3. Migrate

```
$ ./migrate.sh -y
╭──────────────────────────────────────────────╮
│ OpsLab Migrate v1.0.0  old-vps → swift2      │
╰──────────────────────────────────────────────╯
╭─ Projects ───────────────────────────────────╮
│ nginx-manager  ✓ Done                        │
│ stocktool      → Restoring databases         │
╰──────────────────────────────────────────────╯
⠸ Overall ██████████████░░░░░ 74%  0:03:12  0:01:05
╭─ Log ────────────────────────────────────────╮
│ 14:02:11 stocktool: Transferring             │
│ 14:03:40 stocktool: Restoring                │
│ 14:04:02 nginx-manager: Verifying            │
│ 14:04:19 nginx-manager: Done                 │
╰──────────────────────────────────────────────╯
```

## 4. Result

```
          Migration summary
┏━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┓
┃ Project       ┃ Framework ┃ Status ┃ Checks ┃
┡━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━┩
│ nginx-manager │ flask     │ ✓ done │ 9/9    │
│ stocktool     │ flask     │ ✓ done │ 11/11  │
└───────────────┴───────────┴────────┴────────┘

✓ Reports written:
   HTML  reports/migration-20260704-140501.html
   JSON  reports/migration-20260704-140501.json
   TXT   reports/migration-20260704-140501.txt
```

## 5. If it dies mid-run

Just run it again. `migration_state.json` records which phase each project
reached; a re-run skips finished work and resumes the incomplete project
(rsync itself resumes the partial file).

## Common gotchas

- **`restore.overwrite: false` and the path exists on the destination** —
  the project is failed and rolled back. Set `overwrite: true` to snapshot
  the existing directory (`<path>.pre-migrate.<ts>`) and proceed.
- **DNS still points at the old server** — the tool verifies via
  `127.0.0.1:<port>` on the destination, so verification passes before you
  flip DNS. Flip when the report is green.
- **Let's Encrypt** — re-run `certbot --nginx` on the destination after
  DNS cutover, or rsync `/etc/letsencrypt` yourself.
