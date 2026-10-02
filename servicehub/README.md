# ServiceHub

Flask app for managing systemd services on swift1 through a dark-themed web
UI at `services.opslabsystems.cloud`. Create a service by giving it a path,
a start command and (optionally) a port — ServiceHub generates the systemd
unit, and you get start/stop/restart/enable/disable buttons and live logs.

## How the privilege model works

The app process never runs as root. It runs as an ordinary user (`svchub`)
that has exactly one sudo right: running `/usr/local/bin/svcmgr.sh` with no
password. That script is the only thing that touches systemd, and it
hard-refuses to act on any unit that isn't named `opslab-*.service`. So even
if there's a bug in the web app, the blast radius is "start/stop/edit units
ServiceHub itself created" — not "run anything as root."

Every service ServiceHub manages gets a unit named `opslab-<slug>.service`.
ServiceHub's own systemd unit is deliberately named `servicehub.service`
(not `opslab-*`), so it's outside that allowlist and can't manage itself.

## Deploy to swift1

Do this from a normal user shell, not as root, and avoid pasting the whole
block at once if your terminal mangles multi-line pastes — do it in a few
smaller chunks, or drop each file in with `nano`.

**1. Create a dedicated user and app directory (not /root)**
```bash
sudo adduser --system --group --home /var/www/servicehub svchub
sudo mkdir -p /var/www/servicehub
sudo chown svchub:svchub /var/www/servicehub
```

**2. Ship the code**
Zip this folder locally and `scp` it up, or `git clone` it, into
`/var/www/servicehub`, then:
```bash
cd /var/www/servicehub
sudo -u svchub python3 -m venv venv
sudo -u svchub venv/bin/pip install -r requirements.txt
```

**3. Configure**
```bash
sudo -u svchub cp .env.example .env
python3 -c "import secrets; print(secrets.token_hex(32))"   # paste into SERVICEHUB_SECRET_KEY
sudo -u svchub nano .env
```

**4. Install the privileged helper**
```bash
sudo install -m 0755 deploy/svcmgr.sh /usr/local/bin/svcmgr.sh
sudo install -m 0440 deploy/servicehub-sudoers /etc/sudoers.d/servicehub
sudo visudo -c   # sanity-check the sudoers syntax before trusting it
```

**5. Install and start ServiceHub's own systemd unit**
```bash
sudo cp deploy/servicehub.service /etc/systemd/system/servicehub.service
sudo systemctl daemon-reload
sudo systemctl enable --now servicehub
sudo systemctl status servicehub
```

**6. nginx + TLS**
```bash
sudo cp deploy/nginx-services.opslabsystems.cloud.conf /etc/nginx/sites-available/services.opslabsystems.cloud
sudo ln -s /etc/nginx/sites-available/services.opslabsystems.cloud /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d services.opslabsystems.cloud
```

**7. First run**
Visit `https://services.opslabsystems.cloud` — you'll land on a one-time
setup wizard to create the admin account, then log in.

## Adding a service

On "New service" you give it:
- **Name** — used to derive the unit name
- **Path** — the working directory (e.g. `/var/www/directry`)
- **Start command** — full path to the executable systemd should run, e.g.
  `/var/www/directry/venv/bin/gunicorn -w2 -b 127.0.0.1:5001 app:app`
- **Port** — optional, gets exposed to the process as `$PORT`
- **User**, **restart policy**, extra env vars, notes

ServiceHub writes the unit, runs `daemon-reload`, enables it, and starts it.
The service detail page gives you a ready-to-paste nginx reverse-proxy
snippet for that port, live-tailed logs (`journalctl`), and toggles for
enable/disable at boot, start/stop/restart, and delete (which stops,
disables, and removes the unit cleanly).

## Notes / known gotchas already handled here

- CSRF protection is initialized app-wide from the start (`CSRFProtect(app)`
  in `create_app()`), and every POST form carries a token.
- New NOT-NULL columns in `models.py` all carry `server_default` values.
- The app deliberately never runs as root, and app-controlled paths never
  touch `/root` — everything lives under `/var/www/servicehub`.
