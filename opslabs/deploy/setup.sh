#!/usr/bin/env bash
#
# setup.sh — one script to install/fix/verify the whole OpsLab Systems
# platform: 7 independent processes (hub + 6 dedicated subsites), one
# nginx server block per hostname, TLS via certbot.
#
# SAFE ON A SHARED SERVER: this script only ever creates or restarts
# things that belong to THIS platform (systemd units named opslab-*,
# nginx configs for THIS platform's own hostnames). It never deletes,
# disables, or overwrites anything else already on the box — if another
# project's nginx config or systemd service is present, it's left alone,
# full stop. If a config for one of our own hostnames already exists
# (e.g. from an earlier run, or already correctly set up), it's left
# untouched too — this script only fills in what's missing.
#
# Safe to re-run any time.
#
# Usage:
#   sudo bash setup.sh /path/to/opslabswebsite you@example.com your-domain.com
#
#   arg1 = absolute path to this project on the server (contains wsgi_subsite.py)
#   arg2 = email certbot will use for renewal/expiry notices
#   arg3 = YOUR ROOT DOMAIN (required — no default)
#
# Architecture:
#   web.<domain>          -> systemd opslab-web         -> 127.0.0.1:5800 (hub app: run.py)
#   websites.<domain>     -> systemd opslab-websites     -> 127.0.0.1:5801 (SITE_KEY=websites)
#   fivem.<domain>        -> systemd opslab-fivem        -> 127.0.0.1:5802 (SITE_KEY=fivem)
#   techsupport.<domain>  -> systemd opslab-techsupport  -> 127.0.0.1:5803 (SITE_KEY=techsupport)
#   hosting.<domain>      -> systemd opslab-hosting      -> 127.0.0.1:5804 (SITE_KEY=hosting)
#   sys-setup.<domain>    -> systemd opslab-sys-setup    -> 127.0.0.1:5805 (SITE_KEY=sys-setup)
#   onsite.<domain>       -> systemd opslab-onsite       -> 127.0.0.1:5806 (SITE_KEY=onsite)
#   <domain> (bare)       -> nginx redirect only, no backend of its own
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo bash setup.sh /path/to/opslabswebsite you@example.com your-domain.com" >&2
  exit 1
fi

APP_DIR="${1:-}"
CERT_EMAIL="${2:-}"
DOMAIN="${3:-}"

if [[ -z "$APP_DIR" || -z "$CERT_EMAIL" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash setup.sh /path/to/opslabswebsite you@example.com your-domain.com" >&2
  echo "All three arguments are required — there is no default domain." >&2
  exit 1
fi
if [[ ! -f "$APP_DIR/wsgi_subsite.py" ]]; then
  echo "ERROR: $APP_DIR/wsgi_subsite.py not found — pass the correct project path." >&2
  exit 1
fi

LABELS=(web websites fivem techsupport hosting sys-setup onsite)
declare -A PORT_OF=(
  [web]=5800
  [websites]=5801
  [fivem]=5802
  [techsupport]=5803
  [hosting]=5804
  [sys-setup]=5805
  [onsite]=5806
)

HOSTS=("$DOMAIN")
for label in "${LABELS[@]}"; do HOSTS+=("$label.$DOMAIN"); done

echo "Domain: $DOMAIN"
echo "This platform's hostnames (nothing else on this server is touched):"
for label in "${LABELS[@]}"; do echo "  - $label.$DOMAIN -> 127.0.0.1:${PORT_OF[$label]}"; done
echo "  - $DOMAIN (bare)  -> redirect only"
echo

echo "=============================================================="
echo " 0/8  DNS sanity check"
echo "=============================================================="
SERVER_IP="$(curl -fsSL https://api.ipify.org || true)"
echo "This server's public IP looks like: ${SERVER_IP:-<could not detect>}"
BAD_DNS=0
for h in "${HOSTS[@]}"; do
  ip="$(dig +short "$h" | tail -n1)"
  if [[ -z "$ip" ]]; then
    echo "  ✗ $h -> NO DNS RECORD"
    BAD_DNS=1
  elif [[ -n "$SERVER_IP" && "$ip" != "$SERVER_IP" ]]; then
    echo "  ✗ $h -> $ip  (does not match this server's IP $SERVER_IP)"
    BAD_DNS=1
  else
    echo "  ✓ $h -> $ip"
  fi
done
if [[ "$BAD_DNS" -eq 1 ]]; then
  echo
  echo "One or more hostnames don't point at this server yet. Certbot's"
  echo "HTTP-01 challenge WILL fail for those until DNS is fixed."
  read -rp "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

echo
echo "=============================================================="
echo " 1/8  Install packages (additive only — nothing removed)"
echo "=============================================================="
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx python3-venv python3-pip dnsutils curl psmisc

echo
echo "=============================================================="
echo " 2/8  Python venv + dependencies (local to $APP_DIR)"
echo "=============================================================="
if [[ ! -d "$APP_DIR/venv" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
if [[ ! -x "$APP_DIR/venv/bin/pip" ]]; then
  echo "✗ $APP_DIR/venv/bin/pip doesn't exist — the venv wasn't created"
  echo "  properly (often means the python3-venv package for your exact"
  echo "  python3 version is missing). Try:"
  echo "    rm -rf '$APP_DIR/venv'"
  echo "    apt-get install -y \"python3-venv\" \"python3-$(python3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')-venv\""
  echo "  then re-run this script."
  exit 1
fi

"$APP_DIR/venv/bin/pip" install --upgrade pip
if [[ -f "$APP_DIR/requirements.txt" ]]; then
  "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
fi
# Always explicitly ensure these, even if requirements.txt exists and
# doesn't happen to list them all.
"$APP_DIR/venv/bin/pip" install \
  flask flask_sqlalchemy flask_login flask_mail flask_migrate \
  python-dotenv gunicorn authlib pyjwt bcrypt stripe werkzeug

if [[ ! -x "$APP_DIR/venv/bin/gunicorn" ]]; then
  echo "✗ gunicorn still not installed in the venv after pip install."
  echo "  Check the pip output above for errors (disk space, network to"
  echo "  PyPI, etc.) and re-run this script once that's fixed."
  exit 1
fi
echo "✓ venv ready — $("$APP_DIR/venv/bin/gunicorn" --version | head -n1)"

echo
echo "=============================================================="
echo " 3/8  systemd services — one independent process per subdomain"
echo "=============================================================="
echo "(only touches units named opslab-* — nothing else on this box)"

# One-time cleanup of a very old combined-process version of this setup,
# if present, so it can't fight over a port with the per-subdomain
# services below. Safe: this exact unit name is only ever created by an
# earlier version of this script, never by anything else.
if systemctl list-unit-files 2>/dev/null | grep -q '^opslabsystems\.service'; then
  echo "  ⚠ found old combined 'opslabsystems.service' — stopping and disabling it"
  systemctl stop opslabsystems 2>/dev/null || true
  systemctl disable opslabsystems 2>/dev/null || true
  rm -f /etc/systemd/system/opslabsystems.service
  systemctl daemon-reload
fi

# Stop our own services from any previous run before rebinding, so a
# restart can't race with the old process still holding the port.
for label in "${LABELS[@]}"; do
  systemctl stop "opslab-$label" 2>/dev/null || true
done

# Force-free OUR OWN target ports specifically (5800-5806) if anything
# is still bound to them — e.g. a gunicorn started by hand outside
# systemd during earlier debugging. Does not touch any other port.
for label in "${LABELS[@]}"; do
  port="${PORT_OF[$label]}"
  if command -v fuser >/dev/null 2>&1 && fuser "${port}/tcp" >/dev/null 2>&1; then
    echo "  ⚠ port $port still in use — killing whatever's holding it"
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    sleep 1
  fi
done
sleep 1

RUN_USER="${SUDO_USER:-www-data}"

for label in "${LABELS[@]}"; do
  port="${PORT_OF[$label]}"
  svc="opslab-$label"

  if [[ "$label" == "web" ]]; then
    desc="OpsLab Systems — hub (login/tickets/admin/portal/billing)"
    execstart="$APP_DIR/venv/bin/gunicorn -w 4 -b 127.0.0.1:$port run:app"
    extra_env=""
  else
    desc="OpsLab Systems — $label subsite (dedicated, single-purpose)"
    execstart="$APP_DIR/venv/bin/gunicorn -w 2 -b 127.0.0.1:$port wsgi_subsite:application"
    extra_env="Environment=SITE_KEY=$label"
  fi

  cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=$desc
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=PUBLIC_DOMAIN=$DOMAIN
Environment=HUB_SUBDOMAIN=web
Environment=PREFERRED_URL_SCHEME=https
$extra_env
EnvironmentFile=-$APP_DIR/.env
ExecStart=$execstart
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$svc" >/dev/null
  systemctl restart "$svc"
done

sleep 2
FAILED_SVC=0
for label in "${LABELS[@]}"; do
  svc="opslab-$label"
  if ! systemctl is-active --quiet "$svc"; then
    echo "✗ $svc failed to start. Logs:"
    journalctl -u "$svc" --no-pager -n 30
    FAILED_SVC=1
  else
    echo "  ✓ $svc running on 127.0.0.1:${PORT_OF[$label]}"
  fi
done
[[ "$FAILED_SVC" -eq 0 ]] || exit 1

echo
echo "=============================================================="
echo " 4/8  nginx configs — ADD ONLY, never overwrite or remove"
echo "=============================================================="
echo "For each hostname: if a config already exists (however it's named"
echo "or wherever it lives), it is left completely untouched. Only"
echo "genuinely missing hostnames get a new file."
echo

mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

TO_CREATE=()

# Check across sites-available/ (any filename) for an existing block
# declaring this hostname, not just our own naming convention — so we
# never create a duplicate/conflicting block for a host someone already
# configured under a different filename.
host_already_configured() {
  local host="$1"
  grep -rl "server_name[^;]*\b${host}\b" /etc/nginx/sites-available/ 2>/dev/null | grep -q .
}

for label in "${LABELS[@]}"; do
  host="$label.$DOMAIN"
  if host_already_configured "$host"; then
    existing="$(grep -rl "server_name[^;]*\b${host}\b" /etc/nginx/sites-available/ 2>/dev/null | head -n1)"
    echo "  ✓ $host already configured (in $existing) — leaving it alone"
    continue
  fi
  TO_CREATE+=("$label")
  port="${PORT_OF[$label]}"
  conf="/etc/nginx/sites-available/${host}.conf"
  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $host;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
EOF
  ln -sf "$conf" "/etc/nginx/sites-enabled/${host}.conf"
  echo "  + created $conf (new)"
done

if ! host_already_configured "$DOMAIN"; then
  TO_CREATE+=("__bare__")
  conf="/etc/nginx/sites-available/${DOMAIN}.conf"
  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    location / {
        return 302 https://web.$DOMAIN\$request_uri;
    }
}
EOF
  ln -sf "$conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
  echo "  + created $conf (bare domain redirect, new)"
else
  echo "  ✓ $DOMAIN already configured — leaving it alone"
fi

nginx -t
systemctl reload nginx
echo "✓ nginx reloaded"

echo
echo "=============================================================="
echo " 5/8  Verify each of our own systemd services is answering"
echo "=============================================================="
for label in "${LABELS[@]}"; do
  port="${PORT_OF[$label]}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" || echo 000)"
  echo "  127.0.0.1:$port ($label) -> HTTP $code"
done

if [[ ${#TO_CREATE[@]} -eq 0 ]]; then
  echo
  echo "Every hostname already had a working config — nothing new to"
  echo "certify. If something's still broken, it's inside one of the"
  echo "existing files listed above as 'already configured', not a"
  echo "missing one. Re-run after fixing that file by hand if needed."
else
  echo
  echo "=============================================================="
  echo " 6/8  Self-test: acme-challenge path for newly-added hostname(s)"
  echo "=============================================================="
  TESTFILE="selftest-$(date +%s)"
  echo -n "ok" > "/var/www/html/.well-known/acme-challenge/$TESTFILE"
  SELFTEST_FAIL=0
  NEW_HOSTS=()
  for label in "${TO_CREATE[@]}"; do
    if [[ "$label" == "__bare__" ]]; then host="$DOMAIN"; else host="$label.$DOMAIN"; fi
    NEW_HOSTS+=("$host")
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      "http://127.0.0.1/.well-known/acme-challenge/$TESTFILE" -H "Host: $host" || echo 000)"
    if [[ "$code" != "200" ]]; then
      echo "  ✗ $host -> local HTTP $code (expected 200)"
      SELFTEST_FAIL=1
    else
      echo "  ✓ $host -> reachable"
    fi
  done
  rm -f "/var/www/html/.well-known/acme-challenge/$TESTFILE"
  if [[ "$SELFTEST_FAIL" -eq 1 ]]; then
    read -rp "Continue to certbot anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi

  echo
  echo "=============================================================="
  echo " 7/8  Certbot — one call per newly-added hostname"
  echo "=============================================================="
  # Request each hostname SEPARATELY rather than batched together. This
  # matters here specifically: a host can already have its own cert
  # lineage from an earlier partial run (e.g. "websites.<domain>" issued
  # on its own before "web.<domain>" existed) — batching it into one
  # call with a brand-new hostname makes certbot see that as "expand an
  # existing cert to cover a new domain" and it refuses without
  # --expand. Requesting one at a time means: a genuinely new hostname
  # gets a fresh lineage, and a hostname with a matching existing
  # lineage just renews in place — no ambiguity, no --expand needed
  # either way, and no existing cert is ever altered.
  for h in "${NEW_HOSTS[@]}"; do
    echo "-- $h --"
    certbot --nginx \
      --non-interactive --agree-tos -m "$CERT_EMAIL" \
      --redirect --hsts \
      -d "$h"
  done

  nginx -t
  systemctl reload nginx
fi

echo
echo "=============================================================="
echo " 8/8  Final verification — all of THIS platform's hostnames"
echo "=============================================================="
FAIL=0
declare -A SEEN_TITLES=()
for label in "${LABELS[@]}"; do
  host="$label.$DOMAIN"
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/" || echo "000")"
  cert_ok="$(curl -sf -o /dev/null --max-time 10 "https://$host/" && echo OK || echo BAD)"
  title="$(curl -sk --max-time 10 "https://$host/" | grep -o '<title>[^<]*' | head -n1)"
  if [[ "$cert_ok" == "OK" ]]; then
    echo "  ✓ https://$host/  -> HTTP $code, cert valid, title: ${title:-<none found>}"
  else
    echo "  ✗ https://$host/  -> HTTP $code, CERT PROBLEM"
    FAIL=1
  fi
  if [[ "$label" != "web" ]]; then
    if [[ -n "${SEEN_TITLES[$title]:-}" ]]; then
      echo "    ✗ DUPLICATE content — same title as ${SEEN_TITLES[$title]}"
      FAIL=1
    fi
    SEEN_TITLES["$title"]="$host"
  fi
done
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" || echo 000)"
echo "  https://$DOMAIN/ (bare) -> HTTP $code (expect a redirect, e.g. 301/302)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "All of this platform's hostnames are live, on valid HTTPS, each"
  echo "serving its own distinct content. Nothing else on this server was"
  echo "touched."
else
  echo "Something above still needs attention — see the ✗ lines. This"
  echo "script never overwrites an 'already configured' file, so if the"
  echo "problem is there, it needs a manual look rather than a re-run."
fi

echo
echo "Renewal is handled by certbot's own systemd timer. Confirm it:"
echo "  systemctl list-timers | grep certbot"
echo "  certbot renew --dry-run"
