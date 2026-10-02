#!/bin/bash

IP="154.117.150.254"

echo "Checking status for IP: $IP"
echo "----------------------------------"

# 1. Check web server logs (NGINX)
echo "[1] Checking NGINX logs..."
grep "$IP" /var/log/nginx/access.log 2>/dev/null | tail -n 5

grep "$IP" /var/log/nginx/error.log 2>/dev/null | tail -n 5

echo ""

# 2. Check Apache logs (if applicable)
echo "[2] Checking Apache logs..."
grep "$IP" /var/log/apache2/access.log 2>/dev/null | tail -n 5
grep "$IP" /var/log/apache2/error.log 2>/dev/null | tail -n 5

echo ""

# 3. Check for 403/denied responses
echo "[3] Checking for blocked responses (403)..."
grep "$IP" /var/log/nginx/access.log 2>/dev/null | grep " 403 " | tail -n 5

echo ""

# 4. Check iptables firewall
echo "[4] Checking iptables rules..."
iptables -L -n | grep "$IP"

echo ""

# 5. Check UFW (if used)
echo "[5] Checking UFW..."
ufw status | grep "$IP"

echo ""

# 6. Check Fail2Ban (if installed)
echo "[6] Checking Fail2Ban..."
fail2ban-client status 2>/dev/null | grep -i jail

echo "---- Checking banned IPs ----"
fail2ban-client status sshd 2>/dev/null | grep "$IP"

echo ""

echo "Done."
