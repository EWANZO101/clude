# MotoGuard Recovery Network

Community-powered motorcycle & moped registration, stolen-bike alerting, sightings and forum platform. Flask + SQLite + Flowbite/Tailwind (dark).

## Quick install

```bash
unzip motoguard.zip -d motoguard && cd motoguard
ADMIN_EMAIL=you@example.com ADMIN_PASSWORD='strongpass' PUBLIC_BASE_URL=https://moto.example.com ./install.sh
```

The installer runs preflight checks (Python ≥3.10, venv, free port, disk, files), creates a venv, installs deps, generates `.env` with a random `SECRET_KEY`, initialises + seeds the DB, runs a smoke test, then launches via systemd (auto-detected) or gunicorn.

### Useful overrides
`PORT` (default 5060) · `WORKERS` (3) · `USE_SYSTEMD=yes|no|auto` · `SERVICE_NAME` · `APP_USER`

### Manage
```bash
sudo systemctl {status,restart,stop} motoguard
```

## Email alerts
Alert emails are **logged to the journal** until you add SMTP creds to `.env` (`SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`) and restart. Stolen alerts go only to users who **opted in** and sit within their alert radius of the bike's last-known coords; capped per stolen event.

## Notes
- Messages are server-readable so moderation/reporting works (encrypt the volume/disk for at-rest protection — there's no fake E2EE).
- Precise lat/lng is used only for radius matching, never shown publicly (city/region only).
- nginx: reverse-proxy `proxy_pass http://127.0.0.1:5060;` and set `PUBLIC_BASE_URL` to the public https URL so alert email links are correct.

## Stack notes for future expansion
SocketIO live chat, Celery for async dispatch, push notifications, and image matching are all left as documented hooks — current alert dispatch already runs off-thread so it won't block requests.
