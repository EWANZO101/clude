#!/bin/bash
# Run this on your server to diagnose the "unknown error"
# Usage: bash debug_ticket.sh

echo "=== 1. Checking if new API route exists in deployed app.py ==="
grep -n "api/internal/discord-ticket\|api_discord_create_ticket" ~/cioda_commissions/cioda-commissions/app.py 2>/dev/null \
  && echo "✓ Route found in app.py" \
  || echo "✗ Route NOT found — you need to deploy the updated app.py"

echo ""
echo "=== 2. Testing the endpoint directly ==="
# Read secret from .env if it exists
SECRET=$(grep DISCORD_BOT_SECRET ~/cioda_commissions/cioda-commissions/.env 2>/dev/null | cut -d= -f2)
SITE="https://order.ciodrawz.space"

curl -s -o /tmp/ticket_test.json -w "HTTP %{http_code}" \
  -X POST "$SITE/api/internal/discord-ticket" \
  -H "Content-Type: application/json" \
  -d "{\"customer_name\":\"TestUser\",\"subject\":\"Test\",\"message\":\"Test message\",\"secret\":\"$SECRET\",\"channel_id\":\"1490109811394613380\"}"

echo ""
echo "Response body:"
cat /tmp/ticket_test.json 2>/dev/null

echo ""
echo "=== 3. Checking .env has the right values ==="
cat ~/cioda_commissions/cioda-commissions/.env 2>/dev/null || echo "No .env found"

echo ""
echo "=== 4. Recent bot logs ==="
journalctl -u cioda-discord-bot -n 20 --no-pager 2>/dev/null || echo "No systemd service found"
