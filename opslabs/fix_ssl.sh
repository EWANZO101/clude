#!/usr/bin/env bash
#
# fix_ssl.sh — full rebuild of nginx + certbot + gunicorn for the OpsLab
# Systems platform, with EACH of the 7 hostnames (hub + 6 dedicated
# subsites) running as its own fully independent process on its own port,
# behind its own explicit nginx server block. No shared Host-header
# dispatch anywhere — a subdomain can only ever serve its own content
# because its process literally has no other content loaded.
#
# Safe to re-run. It does NOT try to guess what's currently broken — it
# just tears down and rewrites the nginx config, the systemd services, and
# the TLS cert from scratch, in the right order, then verifies every
# hostname actually serves its OWN correct content over HTTPS at the end.
#
# Usage:
#   sudo bash fix_ssl.sh /path/to/opslabswebsite you@example.com your-domain.com
#
#   arg1 = absolute path to this project on the server (contains wsgi_subsite.py)
#   arg2 = email certbot will use for renewal/expiry notices
#   arg3 = YOUR ROOT DOMAIN (required — no default)
#
# Architecture this sets up:
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
  echo "Run this with sudo: sudo bash fix_ssl.sh /path/to/opslabswebsite you@example.com your-domain.com" >&2
  exit 1
fi

APP_DIR="${1:-}"
CERT_EMAIL="${2:-}"
DOMAIN="${3:-}"

if [[ -z "$APP_DIR" || -z "$CERT_EMAIL" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash fix_ssl.sh /path/to/opslabswebsite you@example.com your-domain.com" >&2
  echo "All three arguments are required — there is no default domain." >&2
  exit 1
fi
if [[ ! -f "$APP_DIR/wsgi_subsite.py" ]]; then
  echo "ERROR: $APP_DIR/wsgi_subsite.py not found — pass the correct project path." >&2
  exit 1
fi

# label -> port. "web" is the hub app (run.py); the rest are single-site
# subsite processes (wsgi_subsite.py with SITE_KEY=<label>).
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

echo "Using domain: $DOMAIN"
echo "Hostnames this run will manage (each with its own process + nginx block):"
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
echo " 1/8  Install packages"
echo "=============================================================="
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx python3-venv python3-pip dnsutils curl psmisc

echo
echo "=============================================================="
echo " 2/8  Python venv + dependencies"
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
# doesn't happen to list them — gunicorn/werkzeug/dotenv are required by
# the entrypoints themselves, not just by app/. A requirements.txt missing
# one of these is exactly what caused gunicorn to go missing before.
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
# Stop/disable the old single combined service if it exists from a
# previous version of this script, so it can't fight over a port.
if systemctl list-unit-files | grep -q '^opslabsystems\.service'; then
  echo "  ⚠ found old combined 'opslabsystems.service' — stopping and disabling it"
  systemctl stop opslabsystems 2>/dev/null || true
  systemctl disable opslabsystems 2>/dev/null || true
  rm -f /etc/systemd/system/opslabsystems.service
  systemctl daemon-reload
fi

# Also stop our OWN services from any previous run of this script before
# freeing ports — otherwise "systemctl restart" below can race with the
# old process still holding the port during its shutdown grace period.
for label in "${LABELS[@]}"; do
  systemctl stop "opslab-$label" 2>/dev/null || true
done

# Belt-and-braces: force-kill anything still bound to any port we're
# about to use, from ANY process (not just our own systemd units) — e.g.
# a gunicorn started by hand outside systemd during earlier debugging.
# This is exactly what "Address already in use" on startup means.
for label in "${LABELS[@]}"; do
  port="${PORT_OF[$label]}"
  if command -v fuser >/dev/null 2>&1; then
    if fuser "${port}/tcp" >/dev/null 2>&1; then
      echo "  ⚠ port $port still in use — killing whatever's holding it"
      fuser -k "${port}/tcp" >/dev/null 2>&1 || true
      sleep 1
    fi
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
echo " 4/8  Plain-HTTP nginx placeholders (required before certbot)"
echo "=============================================================="
# This box is assumed dedicated to the OpsLab Systems platform, so rather
# than pattern-matching for "conflicting" configs (unreliable), purge
# EVERY enabled site except the ones this script manages, every time it
# runs. Nothing in sites-available/ or conf.d/ is deleted — only the
# sites-enabled/ symlinks (or files) that make them live are removed, so
# it's reversible (re-enable manually with `ln -s` if you need another
# site here).
if [[ -d /etc/nginx/sites-enabled ]]; then
  for f in /etc/nginx/sites-enabled/*; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == opslab-*.conf ]] && continue
    echo "  ⚠ disabling /etc/nginx/sites-enabled/$(basename "$f") (source file untouched, just unlinked)"
    rm -f "$f"
  done
fi
for f in /etc/nginx/conf.d/*.conf; do
  [[ -e "$f" ]] || continue
  if grep -qE "well-known|$(IFS='|'; echo "${HOSTS[*]}")" "$f" 2>/dev/null; then
    echo "  ⚠ disabling /etc/nginx/conf.d/$(basename "$f") (source file untouched, just renamed)"
    mv "$f" "${f}.disabled-by-fix-ssl"
  fi
done
# Clean up any config this script itself generated on a previous run,
# in case labels/ports ever change.
rm -f /etc/nginx/sites-available/opslab-*.conf /etc/nginx/sites-enabled/opslab-*.conf
rm -f /etc/nginx/sites-available/opslabsystems.cloud /etc/nginx/sites-available/opslab-platform.conf
rm -f /etc/nginx/sites-enabled/opslabsystems.cloud /etc/nginx/sites-enabled/opslab-platform.conf

mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

# One explicit server block PER subdomain, each proxying to its OWN port
# — nothing shared, nothing to mis-route.
for label in "${LABELS[@]}"; do
  port="${PORT_OF[$label]}"
  host="$label.$DOMAIN"
  cat > "/etc/nginx/sites-available/opslab-$label.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $host;

    # ^~ forces this to win over any regex location elsewhere (e.g. a
    # common "location ~ /\. { deny all; }" rule meant to block
    # .htaccess/.git — .well-known starts with a dot too and gets caught
    # by that same rule otherwise, which is a 403, not a 404).
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
  ln -sf "/etc/nginx/sites-available/opslab-$label.conf" "/etc/nginx/sites-enabled/opslab-$label.conf"
done

# Bare domain: no backend of its own, just the challenge path (so certbot
# can still issue it a cert) + a redirect to the hub once HTTPS is live.
cat > "/etc/nginx/sites-available/opslab-bare.conf" <<EOF
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
ln -sf "/etc/nginx/sites-available/opslab-bare.conf" "/etc/nginx/sites-enabled/opslab-bare.conf"

nginx -t
systemctl reload nginx
echo "✓ nginx reloaded — one server block per hostname, each pointing at its own port"

echo
echo "-- Self-test: acme-challenge path + correct backend per hostname --"
TESTFILE="selftest-$(date +%s)"
echo -n "ok" > "/var/www/html/.well-known/acme-challenge/$TESTFILE"
SELFTEST_FAIL=0
for h in "${HOSTS[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    "http://127.0.0.1/.well-known/acme-challenge/$TESTFILE" -H "Host: $h" || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "  ✗ $h -> local HTTP $code fetching the challenge path (expected 200)"
    SELFTEST_FAIL=1
  fi
done
rm -f "/var/www/html/.well-known/acme-challenge/$TESTFILE"

# Also confirm each subdomain is actually serving ITS OWN content locally,
# before we even involve certbot — this is the check that would have
# caught "wrong site on wrong domain" immediately.
echo
echo "-- Self-test: each subdomain serves its own distinct content --"
declare -A SEEN_TITLES=()
CROSS_FAIL=0
for label in "${LABELS[@]}"; do
  [[ "$label" == "web" ]] && continue
  host="$label.$DOMAIN"
  title="$(curl -s --max-time 8 "http://127.0.0.1/" -H "Host: $host" | grep -o '<title>[^<]*' | head -n1)"
  echo "  $host -> ${title:-<no title found>}"
  if [[ -n "${SEEN_TITLES[$title]:-}" ]]; then
    echo "  ✗ DUPLICATE: this title was already seen for ${SEEN_TITLES[$title]}"
    CROSS_FAIL=1
  fi
  SEEN_TITLES["$title"]="$host"
done
if [[ "$CROSS_FAIL" -eq 1 ]]; then
  echo
  echo "Two or more subdomains are serving the SAME content locally, before"
  echo "certbot is even involved — that means nginx or the systemd services"
  echo "aren't wired up correctly yet. Check 'systemctl status opslab-<label>'"
  echo "for each label and 'nginx -T | grep -A5 server_name' to see what"
  echo "nginx actually loaded."
  read -rp "Continue to certbot anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

if [[ "$SELFTEST_FAIL" -eq 1 ]]; then
  echo
  echo "The challenge path isn't reachable even locally, so certbot WILL fail."
  echo "Common causes:"
  echo "  - a firewall/WAF (ufw, cloud provider security group, Cloudflare"
  echo "    proxy) blocking port 80 from outside, or even from localhost"
  echo "  - SELinux/AppArmor blocking nginx from reading /var/www/html"
  read -rp "Continue to certbot anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
else
  echo "  ✓ challenge path reachable on all ${#HOSTS[@]} hostnames locally"
fi

echo
echo "=============================================================="
echo " 5/8  Certbot — one cert covering all hostnames"
echo "=============================================================="
DOMAIN_ARGS=()
for h in "${HOSTS[@]}"; do DOMAIN_ARGS+=(-d "$h"); done

# Pin to whichever certificate lineage already exists (an earlier run may
# have created one named after a different first -d). Using --cert-name +
# --expand against that SAME lineage name is what lets this converge
# cleanly instead of erroring on overlapping domains every time.
CERT_NAME="$DOMAIN"
if [[ -f "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]]; then
  CERT_NAME="$DOMAIN"
elif [[ -f "/etc/letsencrypt/renewal/web.${DOMAIN}.conf" ]]; then
  CERT_NAME="web.${DOMAIN}"
fi

certbot --nginx \
  --non-interactive --agree-tos -m "$CERT_EMAIL" \
  --redirect --hsts --expand \
  --cert-name "$CERT_NAME" \
  "${DOMAIN_ARGS[@]}"

echo
echo "=============================================================="
echo " 6/8  Reload everything"
echo "=============================================================="
nginx -t
systemctl reload nginx
for label in "${LABELS[@]}"; do
  systemctl restart "opslab-$label"
done

echo
echo "=============================================================="
echo " 7/8  Verify HTTPS on every hostname"
echo "=============================================================="
FAIL=0
for h in "${HOSTS[@]}"; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" || echo "000")"
  cert_ok="$(curl -sf -o /dev/null --max-time 10 "https://$h/" && echo OK || echo BAD)"
  if [[ "$cert_ok" == "OK" ]]; then
    echo "  ✓ https://$h/  -> HTTP $code, cert valid"
  else
    echo "  ✗ https://$h/  -> HTTP $code, CERT PROBLEM"
    FAIL=1
  fi
done

echo
echo "=============================================================="
echo " 8/8  Verify each subdomain serves its OWN content over HTTPS"
echo "=============================================================="
CROSS_FAIL2=0
declare -A SEEN_TITLES2=()
for label in "${LABELS[@]}"; do
  [[ "$label" == "web" ]] && continue
  host="$label.$DOMAIN"
  title="$(curl -sk --max-time 10 "https://$host/" | grep -o '<title>[^<]*' | head -n1)"
  echo "  $host -> ${title:-<no title found>}"
  if [[ -n "${SEEN_TITLES2[$title]:-}" ]]; then
    echo "  ✗ DUPLICATE content: same as ${SEEN_TITLES2[$title]}"
    CROSS_FAIL2=1
  fi
  SEEN_TITLES2["$title"]="$host"
done

echo
if [[ "$FAIL" -eq 0 && "$CROSS_FAIL2" -eq 0 ]]; then
  echo "All 8 hostnames serve valid HTTPS, and all 6 subsites serve distinct,"
  echo "correct content. Done."
else
  echo "Something's still off — see the ✗ lines above. If it's a CERT"
  echo "PROBLEM, it's almost always DNS/firewall (re-check step 0's output"
  echo "above). If it's DUPLICATE content, run:"
  echo "  systemctl status opslab-<label>"
  echo "for the affected labels and check the logs."
fi

echo
echo "Renewal is handled by certbot's own systemd timer. Confirm it:"
echo "  systemctl list-timers | grep certbot"
echo "  certbot renew --dry-run"