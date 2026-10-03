#!/usr/bin/env bash
#
# fix_domain_env.sh — finds and corrects a leftover placeholder domain
# (e.g. "your-domain.com", "your-actual-domain.com", "yourdomain.com")
# in $APP_DIR/.env, which overrides the correct PUBLIC_DOMAIN that
# setup.sh already set inside each opslab-*.service unit file (systemd
# loads EnvironmentFile= AFTER the unit's own Environment= lines, so a
# stray line in .env silently wins over the correct value).
#
# Safe to re-run. Only ever edits $APP_DIR/.env (backing up the original
# first) and restarts opslab-* services — nothing else on the server is
# touched.
#
# Usage:
#   sudo bash fix_domain_env.sh /path/to/opslabswebsite your-real-domain.com
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo bash fix_domain_env.sh /path/to/opslabswebsite your-real-domain.com" >&2
  exit 1
fi

APP_DIR="${1:-}"
DOMAIN="${2:-}"

if [[ -z "$APP_DIR" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash fix_domain_env.sh /path/to/opslabswebsite your-real-domain.com" >&2
  exit 1
fi

ENV_FILE="$APP_DIR/.env"

echo "Target domain: $DOMAIN"
echo "Env file: $ENV_FILE"
echo

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No .env file found at $ENV_FILE — nothing to fix there."
  echo "The wrong value must be coming from somewhere else (a systemd"
  echo "override, or the domain you passed to setup.sh originally was"
  echo "itself wrong). Check with:"
  echo "  sudo systemctl show opslab-web -p Environment"
  exit 1
fi

cp "$ENV_FILE" "${ENV_FILE}.bak-$(date +%s)"
echo "✓ backed up existing .env"

# Any of these look like a copy-pasted placeholder rather than a real
# domain — replace them wherever they appear in .env (PUBLIC_DOMAIN,
# CONTACT_EMAIL, or anywhere else someone pasted an example value).
PLACEHOLDER_PATTERNS=(
  "your-actual-domain\.com"
  "your-domain\.com"
  "yourdomain\.com"
  "example\.com"
)

FOUND=0
for pat in "${PLACEHOLDER_PATTERNS[@]}"; do
  if grep -qE "$pat" "$ENV_FILE"; then
    echo "  found placeholder matching '$pat' in .env — replacing with $DOMAIN"
    sed -i -E "s/${pat}/${DOMAIN}/g" "$ENV_FILE"
    FOUND=1
  fi
done

# Make sure PUBLIC_DOMAIN is actually set correctly regardless (covers
# the case where it was missing entirely, or set to something odd that
# didn't match the patterns above).
if grep -q '^PUBLIC_DOMAIN=' "$ENV_FILE"; then
  sed -i -E "s/^PUBLIC_DOMAIN=.*/PUBLIC_DOMAIN=${DOMAIN}/" "$ENV_FILE"
else
  echo "PUBLIC_DOMAIN=${DOMAIN}" >> "$ENV_FILE"
fi
echo "✓ PUBLIC_DOMAIN=${DOMAIN} confirmed in .env"

if [[ "$FOUND" -eq 0 ]]; then
  echo
  echo "No obvious placeholder text was found in .env, but PUBLIC_DOMAIN"
  echo "has been set/confirmed as ${DOMAIN} anyway. If the site was showing"
  echo "a different wrong domain, check .env by hand:"
  echo "  cat $ENV_FILE"
fi

echo
echo "Current .env contents:"
echo "----------------------------------------"
cat "$ENV_FILE"
echo "----------------------------------------"

echo
echo "Restarting all opslab-* services so the fix takes effect..."
for svc in opslab-web opslab-websites opslab-fivem opslab-techsupport opslab-hosting opslab-sys-setup opslab-onsite; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    systemctl restart "$svc"
    echo "  ✓ restarted $svc"
  else
    echo "  (skipping $svc — not installed)"
  fi
done

sleep 2

echo
echo "Verifying the placeholder is gone from the live homepage..."
BAD=0
for pat in "${PLACEHOLDER_PATTERNS[@]}"; do
  if curl -sk --max-time 10 "https://web.${DOMAIN}/" | grep -qE "$pat"; then
    echo "  ✗ '$pat' is STILL showing up on the homepage"
    BAD=1
  fi
done
if [[ "$BAD" -eq 0 ]]; then
  echo "  ✓ no placeholder domain text found on https://web.${DOMAIN}/"
  echo
  echo "Spot-checking one subdomain link now points at the real domain:"
  curl -sk --max-time 10 "https://web.${DOMAIN}/" | grep -o "https://websites\.[a-zA-Z0-9.-]*" | head -n1
else
  echo
  echo "Still showing the placeholder — the value may be set directly in"
  echo "one of the systemd unit files themselves rather than .env. Check:"
  echo "  sudo systemctl show opslab-web -p Environment"
  echo "and fix the PUBLIC_DOMAIN= line there directly if needed, then:"
  echo "  sudo systemctl daemon-reload && sudo systemctl restart opslab-web"
fi
