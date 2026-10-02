#!/usr/bin/env bash
#
# self_fix_https.sh — checks whether each of this platform's 7 hostnames
# is ACTUALLY serving its own correct content over HTTPS right now, and
# only touches the nginx config for a hostname that's genuinely broken.
# A hostname that's already working is left 100% untouched — no rewrite,
# not even a harmless-looking one. This is the fix for the bug in the
# previous script, which rewrote every file unconditionally as its first
# step and could be left in a broken half-written state if anything
# after that failed.
#
# Safe to re-run anytime, including on a schedule (cron) — every run
# re-verifies live behavior from scratch rather than trusting file state.
#
# SAFE ON A SHARED SERVER: only ever touches nginx configs for this
# platform's own 7 hostnames, never anything else in sites-available/ or
# sites-enabled/, never disables or deletes anything.
#
# Usage:
#   sudo bash self_fix_https.sh you@example.com your-domain.com
#
set -uo pipefail  # NOTE: no -e — a single host's failure must not abort the rest

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo bash self_fix_https.sh you@example.com your-domain.com" >&2
  exit 1
fi

CERT_EMAIL="${1:-}"
DOMAIN="${2:-}"

if [[ -z "$CERT_EMAIL" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash self_fix_https.sh you@example.com your-domain.com" >&2
  exit 1
fi

LABELS=(web websites fivem techsupport hosting sys-setup onsite)
declare -A PORT_OF=(
  [web]=5800 [websites]=5801 [fivem]=5802 [techsupport]=5803
  [hosting]=5804 [sys-setup]=5805 [onsite]=5806
)

mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

get_title() {
  # $1 = URL. Empty output if unreachable or no <title> found.
  curl -sk --max-time 8 "$1" 2>/dev/null | grep -o '<title>[^<]*' | head -n1
}

echo "Domain: $DOMAIN"
echo "Checking all 7 hostnames — only fixing what's actually broken."
echo

BROKEN=()
for label in "${LABELS[@]}"; do
  host="$label.$DOMAIN"
  port="${PORT_OF[$label]}"

  backend_title="$(get_title "http://127.0.0.1:$port/")"
  public_title="$(get_title "https://$host/")"

  if [[ -n "$backend_title" && "$backend_title" == "$public_title" ]]; then
    echo "  ✓ $host — already correct (\"$backend_title\"), leaving untouched"
  else
    echo "  ✗ $host — broken (backend: \"${backend_title:-<none>}\", public: \"${public_title:-<none>}\")"
    BROKEN+=("$label")
  fi
done

if [[ ${#BROKEN[@]} -eq 0 ]]; then
  echo
  echo "All 7 hostnames already correct. Nothing to do."
  exit 0
fi

echo
echo "Fixing: ${BROKEN[*]}"
echo

for label in "${BROKEN[@]}"; do
  host="$label.$DOMAIN"
  port="${PORT_OF[$label]}"
  conf="/etc/nginx/sites-available/${host}.conf"
  cert="/etc/letsencrypt/live/$host"

  echo "=============================================================="
  echo " Fixing $host"
  echo "=============================================================="

  if [[ -f "$cert/fullchain.pem" ]]; then
    echo "  ✓ valid certificate already on disk — reusing it"
  else
    echo "  no certificate yet — need to request one"
    # Need a plain-80 block reachable first for the ACME webroot challenge.
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
    nginx -t && systemctl reload nginx

    TESTFILE="selftest-$(date +%s)"
    echo -n "ok" > "/var/www/html/.well-known/acme-challenge/$TESTFILE"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      "http://127.0.0.1/.well-known/acme-challenge/$TESTFILE" -H "Host: $host")"
    rm -f "/var/www/html/.well-known/acme-challenge/$TESTFILE"
    if [[ "$code" != "200" ]]; then
      echo "  ✗ challenge path unreachable (HTTP $code) — skipping $host, can't get a cert"
      continue
    fi

    if ! certbot certonly --webroot -w /var/www/html \
        --non-interactive --agree-tos -m "$CERT_EMAIL" -d "$host"; then
      echo "  ✗ certbot failed for $host — skipping, left on plain HTTP"
      continue
    fi
  fi

  if [[ ! -f "$cert/fullchain.pem" ]]; then
    echo "  ✗ still no certificate for $host after all steps — skipping"
    continue
  fi

  # Write the final combined HTTP+HTTPS block, unconditionally at this
  # point — we KNOW the cert exists and this host was confirmed broken,
  # so overwriting here is always safe and always moves it forward.
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
    ssl_certificate $cert/fullchain.pem;
    ssl_certificate_key $cert/privkey.pem;
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
  ln -sf "$conf" "/etc/nginx/sites-enabled/${host}.conf"
  nginx -t && systemctl reload nginx
  echo "  ✓ wrote and enabled HTTPS config for $host"
done

echo
echo "=============================================================="
echo " Final verification — re-checking live behavior for all 7"
echo "=============================================================="
sleep 2
ALL_OK=1
for label in "${LABELS[@]}"; do
  host="$label.$DOMAIN"
  port="${PORT_OF[$label]}"
  backend_title="$(get_title "http://127.0.0.1:$port/")"
  public_title="$(get_title "https://$host/")"
  if [[ -n "$backend_title" && "$backend_title" == "$public_title" ]]; then
    echo "  ✓ $host -> $public_title"
  else
    echo "  ✗ $host -> backend: \"${backend_title:-<none>}\", public: \"${public_title:-<none>}\" — still broken"
    ALL_OK=0
  fi
done

echo
if [[ "$ALL_OK" -eq 1 ]]; then
  echo "All 7 hostnames are confirmed serving their own correct content over HTTPS."
else
  echo "Some hosts are still broken — see the ✗ lines above. Re-running this"
  echo "script is always safe; it will only retry what's still actually broken."
fi
