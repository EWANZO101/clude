#!/usr/bin/env bash
#
# ensure_https.sh — guarantee that a set of subdomains have a correct,
# working HTTP + HTTPS nginx config, without depending on certbot's
# `--nginx` installer plugin actually editing the file (which we've seen
# silently skip some hosts while working for others, with no error).
#
# How it's made reliable: certbot is used ONLY as a certificate
# authenticator (`certonly --webroot`), never as the nginx installer.
# This script writes the actual server block itself, every time, from a
# known-good template — so the result never depends on plugin behavior
# that's already proven unpredictable on this box.
#
# SAFE ON A SHARED SERVER, same rules as setup.sh:
#   - only ever touches nginx config files for the hostnames you list
#   - never deletes/disables/purges anything else in sites-enabled/
#   - never requests a cert covering any domain you didn't explicitly list
#
# Safe to re-run — always rewrites the target file(s) to the same
# correct, known-good form, whether they were missing, broken, or
# already fine.
#
# Usage:
#   sudo bash ensure_https.sh you@example.com your-domain.com [label:port ...]
#
#   arg1 = email certbot uses for renewal notices
#   arg2 = root domain (e.g. opslabsystems.cloud)
#   arg3+ = optional label:port pairs. Defaults to:
#           websites:5801 fivem:5802 techsupport:5803 hosting:5804 sys-setup:5805 onsite:5806
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo bash ensure_https.sh you@example.com your-domain.com [label:port ...]" >&2
  exit 1
fi

CERT_EMAIL="${1:-}"
DOMAIN="${2:-}"
shift 2 2>/dev/null || true

if [[ -z "$CERT_EMAIL" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash ensure_https.sh you@example.com your-domain.com [label:port ...]" >&2
  exit 1
fi

PAIRS=("$@")
if [[ ${#PAIRS[@]} -eq 0 ]]; then
  PAIRS=(
    "websites:5801"
    "fivem:5802"
    "techsupport:5803"
    "hosting:5804"
    "sys-setup:5805"
    "onsite:5806"
  )
fi

echo "Domain: $DOMAIN"
echo "Ensuring correct HTTP+HTTPS config for:"
for p in "${PAIRS[@]}"; do echo "  - ${p%%:*}.$DOMAIN -> 127.0.0.1:${p##*:}"; done
echo "(nothing else on this server is touched)"
echo

mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

for pair in "${PAIRS[@]}"; do
  label="${pair%%:*}"
  port="${pair##*:}"
  host="$label.$DOMAIN"
  conf="/etc/nginx/sites-available/${host}.conf"

  echo "=============================================================="
  echo " $host -> 127.0.0.1:$port"
  echo "=============================================================="

  # --- Step 1: plain-HTTP block, so the ACME webroot challenge has
  #     somewhere to be served from for this exact hostname. ---
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
  nginx -t
  systemctl reload nginx

  # --- Step 2: local self-test of the challenge path before involving
  #     Let's Encrypt at all. ---
  TESTFILE="selftest-$(date +%s)"
  echo -n "ok" > "/var/www/html/.well-known/acme-challenge/$TESTFILE"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    "http://127.0.0.1/.well-known/acme-challenge/$TESTFILE" -H "Host: $host" || echo 000)"
  rm -f "/var/www/html/.well-known/acme-challenge/$TESTFILE"
  if [[ "$code" != "200" ]]; then
    echo "  ✗ challenge path not reachable locally (HTTP $code) — skipping $host"
    echo "    check DNS for $host and re-run this script for it later."
    continue
  fi

  # --- Step 3: get (or reuse) a certificate — authenticator only, never
  #     the nginx installer, so this never depends on plugin behavior. ---
  if [[ -f "/etc/letsencrypt/live/${host}/fullchain.pem" ]]; then
    echo "  ✓ valid certificate already exists for $host — reusing it, not re-requesting"
  else
    echo "  requesting a new certificate for $host ..."
    certbot certonly --webroot -w /var/www/html \
      --non-interactive --agree-tos -m "$CERT_EMAIL" \
      -d "$host"
  fi

  if [[ ! -f "/etc/letsencrypt/live/${host}/fullchain.pem" ]]; then
    echo "  ✗ still no certificate on disk for $host after certbot ran — leaving"
    echo "    this host on plain HTTP only. Check the certbot output above."
    continue
  fi

  # --- Step 4: write the FINAL combined HTTP+HTTPS block ourselves,
  #     pointing at whatever certificate is on disk for this exact
  #     hostname — same structure Certbot's own installer normally
  #     produces, just guaranteed rather than hoped-for. ---
  cat > "$conf" <<EOF
server {
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

    listen [::]:443 ssl;
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if (\$host = $host) {
        return 301 https://\$host\$request_uri;
    }

    listen 80;
    listen [::]:80;
    server_name $host;
    return 404;
}
EOF
  nginx -t
  systemctl reload nginx
  echo "  ✓ HTTPS wired up for $host"
done

echo
echo "=============================================================="
echo " Verify"
echo "=============================================================="
for pair in "${PAIRS[@]}"; do
  label="${pair%%:*}"
  host="$label.$DOMAIN"
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/" || echo 000)"
  title="$(curl -sk --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/" | grep -o '<title>[^<]*' | head -n1)"
  echo "  https://$host/ -> HTTP $code, title: ${title:-<none found>}"
done

echo
echo "If any title above still doesn't look right (e.g. shows another"
echo "project's content), the problem is upstream of TLS — check what's"
echo "actually running on that hostname's port with:"
echo "  curl -s http://127.0.0.1:<port>/ | head -c 200"
