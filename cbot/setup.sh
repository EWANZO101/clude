#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Email Discord Bot — Setup Script
#  Installs everything into /root/cbot/
# ═══════════════════════════════════════════════════════

set -e

DIR="/root/cbot"
VENV="$DIR/venv"
BOT="$DIR/email_discord_bot.py"
SERVICE="/etc/systemd/system/cbot.service"

echo ""
echo "═══════════════════════════════════════════"
echo "  Setting up Email Discord Bot in $DIR"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. Create directory ────────────────────────────────
mkdir -p "$DIR"
echo "✅  Created $DIR"

# ── 2. Python venv ─────────────────────────────────────
python3 -m venv "$VENV"
echo "✅  Virtual environment created at $VENV"

# ── 3. Install dependencies ────────────────────────────
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet discord.py
echo "✅  discord.py installed"

# ── 4. Install systemd service ─────────────────────────
cp "$(dirname "$0")/cbot.service" "$SERVICE"
systemctl daemon-reload
systemctl enable cbot
echo "✅  systemd service installed and enabled"

echo ""
echo "═══════════════════════════════════════════"
echo "  Done!  Next steps:"
echo ""
echo "  1. Edit /root/cbot/email_discord_bot.py"
echo "     and fill in BOT_TOKEN, CHANNEL_ID,"
echo "     and EMAIL_PASSWORD"
echo ""
echo "  2. Start the bot:"
echo "       systemctl start cbot"
echo ""
echo "  3. Watch the logs:"
echo "       journalctl -u cbot -f"
echo "═══════════════════════════════════════════"
echo ""
