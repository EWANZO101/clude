#!/bin/bash

IP="154.117.150.254"
URL="https://web.cfrp.co.za"

echo "Checking if IP $IP is blocked on $URL"
echo "--------------------------------------"

# 1. Try request with spoofed IP headers
echo "[1] Testing via X-Forwarded-For header..."

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "X-Forwarded-For: $IP" \
  -H "Client-IP: $IP" \
  "$URL")

echo "HTTP Status Code: $STATUS"

if [[ "$STATUS" == "403" || "$STATUS" == "401" ]]; then
  echo "⚠️ Possible block detected (Forbidden/Unauthorized)"
elif [[ "$STATUS" == "200" ]]; then
  echo "✅ Request successful (likely NOT blocked via header check)"
else
  echo "❓ Unexpected response (could indicate filtering): $STATUS"
fi

echo ""

# 2. Try connection test (basic reachability)
echo "[2] Testing connection..."

curl -I --connect-timeout 5 "$URL" 2>/dev/null | head -n 1

echo ""

# 3. Optional: Check using verbose output
echo "[3] Verbose test (manual inspection)..."
curl -v -H "X-Forwarded-For: $IP" "$URL" -o /dev/null 2>&1 | grep "< HTTP"

echo ""
echo "Done."
