# OpsLab Migrate

Automated Python/Flask server migration toolkit. Discovers every Python web
application on a source Linux VPS, backs it up (code, databases, services,
nginx), transfers it over SSH, restores it on a destination server, verifies
it works, and self-heals common failures — in one command.

```
./migrate.sh
```

## Supported platforms

| | Source & destination servers | Operator machine |
|---|---|---|
| OS | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 | Linux, macOS, WSL |
| Python | any (venvs rebuilt to match) | 3.10+ (3.12 recommended) |

Detected frameworks: **Flask, FastAPI, Quart, Django**
Detected databases: **SQLite, MySQL, MariaDB, PostgreSQL, MongoDB, Redis**
Detected infra: **systemd, supervisor, Docker Compose, gunicorn, uWSGI,
nginx, apache, venv/Poetry/Pipenv**

## Installation

```bash
git clone <repo> opslab-migrate && cd opslab-migrate
cp config.example.yaml config.yaml
$EDITOR config.yaml          # set hosts, usernames, SSH keys
./migrate.sh                 # creates venv, installs deps, runs migration
```

Or without the launcher:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python migrate.py migrate --config config.yaml
```

### Requirements

- SSH access to both servers using **either a password or a key** per host:

  ```yaml
  source:
    host: 1.2.3.4
    username: root
    password: ask        # prompted at runtime (recommended), or put the
                         # password here directly
  ```

  With key auth instead, set `ssh_key:` (file must be mode 600 — the tool
  refuses insecure keys)
- `root`, or a user with **passwordless sudo**, on both servers
- Outbound SSH from the source to the destination is used for direct
  `rsync` push; if unavailable, the tool automatically relays archives
  through the operator machine instead

## Usage

```bash
python migrate.py discover      # dry scan: list what would be migrated
python migrate.py migrate       # full migration (asks to confirm; -y skips)
python migrate.py verify        # re-run health checks on the destination
python migrate.py reset         # clear resume state for a fresh run
```

Migrate a subset by listing projects in `config.yaml`:

```yaml
projects:
  - nginx-manager
  - /opt/stocktool
```

## What a migration does

For each discovered project, in order:

1. **Backup** — builds `project.tar.zst` on the source containing the app
   tree (source, `.env`, uploads, static, templates), database dumps
   (`mysqldump` / `pg_dump` / `mongodump` / SQLite `.backup` / Redis RDB),
   systemd units, supervisor configs, nginx/apache sites, and a manifest
   with full permission/ownership data. Venvs are excluded by default and
   rebuilt (set `backup.include_venv: true` to include them).
2. **Transfer** — pushes the archive via `rsync` with resume
   (`--partial-dir`), optional bandwidth limit, retries, and mandatory
   SHA-256 verification on arrival.
3. **Restore** — installs base packages, extracts the archive, snapshots any
   existing directory (rollback point), places files, restores ownership and
   per-file modes, recreates the virtualenv with a matching Python minor
   version, installs requirements (pip / Poetry / Pipenv), installs and
   restores databases, installs services and web server configs, reloads
   systemd, and starts everything.
4. **Verify** — services active, ports listening, HTTP responds < 500,
   framework imports inside the venv, database connectivity per engine,
   `nginx -t`, disk and memory headroom.
5. **Self-heal** — for failed checks: installs missing Python modules read
   from the journal, fixes ownership on permission errors, removes broken
   symlinks, reinstalls gunicorn, recreates broken venvs, disables
   syntactically broken nginx sites, restarts DB services, cleans disk.
   Repeats up to `heal.max_attempts`, re-verifying after each pass.
6. **Rollback** — if restore fails, installed units/sites are removed and
   the pre-migration snapshot of the directory is put back.

## Resume

All progress is checkpointed in `migration_state.json`. If the run is
interrupted (Ctrl-C, network drop, reboot), simply re-run `./migrate.sh` —
completed phases and completed projects are skipped. `python migrate.py
reset` starts over.

## Reports and logs

- `reports/migration-<timestamp>.html` — full styled report (duration,
  per-project status, checksums, transfer speed, verification detail,
  warnings, healing actions)
- `reports/migration-<timestamp>.json` — machine-readable equivalent
- `reports/migration-<timestamp>.txt` — plain summary
- `logs/migration.log` — everything; plus `backup.log`, `restore.log`,
  `verify.log`, `transfer.log`, `discovery.log`, `heal.log`, `errors.log`

## Security

- Password or key auth; `password: ask` prompts at runtime so nothing is stored on disk. With password auth, direct source→destination rsync uses `sshpass -e` (password via environment, never in process arguments)
- Every log line passes through a redaction filter — DB passwords,
  connection-string credentials, and `-p` flags are masked before writing
- Database passwords are never written into archive manifests; restore
  re-reads them from the project's own `.env`/config on the destination
- Database dump commands pass passwords via environment
  (`MYSQL_PWD`/`PGPASSWORD`), never on the command line
- `--strict-host-key` enforces known-hosts verification (recommended after
  the first run); first runs use accept-and-record
- All transfers checksum-verified end to end (SHA-256)

## Performance

`parallel_workers` migrates several projects concurrently; each worker gets
its own pair of SSH connections. `transfer.bandwidth_limit_kbps` caps rsync
throughput on shared links.

## Configuration reference

See `config.example.yaml` — every key is documented inline. Notable:

| Key | Default | Meaning |
|---|---|---|
| `backup.compression` | `zstd` | `zstd` \| `gzip` \| `xz` |
| `backup.keep_days` | 30 | prune old archives on the source |
| `restore.overwrite` | `false` | refuse to clobber existing dirs |
| `verify.enabled` | `true` | run post-restore checks |
| `heal.enabled` | `true` | attempt automated repair |
| `parallel_workers` | 2 | concurrent project migrations |
| `scan_roots` | `/opt /srv /var/www /home /root` | where to look |

## Developer notes

```
migratekit/
  cli.py            Typer CLI + Rich live dashboard
  orchestrator.py   pipeline coordination, parallelism, resume, rollback hooks
  config.py         YAML loading, validation, credential redaction
  ssh.py            Paramiko wrapper: retries, sudo, sftp, checksums
  discovery.py      project/framework/service/database detection
  backup.py         archive builder (tar + zstd/gzip/xz)
  database.py       per-engine dump & restore
  transfer.py       rsync push with SFTP relay fallback
  restore.py        extraction, venv, packages, services, nginx
  verify.py         health checks
  heal.py           automated repair strategies
  state.py          migration_state.json + rollback
  report.py         HTML/JSON/TXT reports
```

Run tests:

```bash
pip install pytest
python -m pytest tests/ -v
```

Tests are fully offline (config parsing, URI parsing, state resume,
redaction, report generation). Integration testing is done against two
disposable VPSes — see `docs/SAMPLE_MIGRATION.md` for a worked example.

## Limitations / not yet implemented

Optional-feature hooks (web dashboard, Slack/Discord notifications,
Cloudflare DNS, SSL cert migration, LXC/VM snapshots) are out of scope for
v1.0. Docker Compose apps are detected and restarted, but image transfer
relies on the registry (`docker compose up -d` pulls on the destination).
Let's Encrypt certs are carried inside nginx configs' paths but
`/etc/letsencrypt` is not copied — re-issue with certbot on the destination
or copy it manually.
