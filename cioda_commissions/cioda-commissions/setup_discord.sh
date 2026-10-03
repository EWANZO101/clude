#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  setup_discord.sh  –  Discord ↔ Site ticket sync setup
#  Run with:  bash setup_discord.sh
# ══════════════════════════════════════════════════════════════

set -e

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   Discord ↔ Site Ticket Sync  Setup     ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Check Python ──────────────────────────────────────
echo -e "${BOLD}[1/7] Checking Python...${RESET}"
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}✗ Python3 not found. Please install Python 3.9+${RESET}"
    exit 1
fi
PYTHON=$(command -v python3)
echo -e "${GREEN}✓ Found Python: $($PYTHON --version)${RESET}"
echo ""

# ── Step 2: Install discord.py ────────────────────────────────
echo -e "${BOLD}[2/7] Installing discord.py...${RESET}"
$PYTHON -m pip install -q "discord.py>=2.3.0" requests
echo -e "${GREEN}✓ discord.py installed${RESET}"
echo ""

# ── Step 3: Collect credentials ───────────────────────────────
echo -e "${BOLD}[3/7] Enter your Discord credentials${RESET}"
echo -e "${YELLOW}  ➤  Go to https://discord.com/developers/applications${RESET}"
echo -e "${YELLOW}     Create an app → Bot → Reset Token → copy it${RESET}"
echo -e "${YELLOW}     Also enable: Message Content Intent (Bot → Privileged Gateway Intents)${RESET}"
echo ""
read -rp "  Bot Token: " BOT_TOKEN
echo ""

echo -e "${YELLOW}  ➤  In Discord: right-click your support channel → Copy Channel ID${RESET}"
echo -e "${YELLOW}     (Enable Developer Mode first: User Settings → Advanced)${RESET}"
echo ""
read -rp "  Ticket Channel ID: " CHANNEL_ID
echo ""

echo -e "${YELLOW}  ➤  What is the URL of your site? (no trailing slash)${RESET}"
echo -e "${YELLOW}     e.g.  https://order.ciodrawz.space${RESET}"
echo ""
read -rp "  Site URL: " SITE_URL
SITE_URL="${SITE_URL%/}"   # strip trailing slash if user added one
echo ""

# Generate a random secret automatically
BOT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
echo -e "${GREEN}  ✓ Auto-generated bot secret: ${BOLD}${BOT_SECRET}${RESET}"
echo -e "${YELLOW}    (You will paste this into Admin → Settings later)${RESET}"
echo ""

# ── Step 4: Write .env file ───────────────────────────────────
echo -e "${BOLD}[4/7] Writing .env file...${RESET}"
cat > .env <<EOF
DISCORD_BOT_TOKEN=$BOT_TOKEN
DISCORD_TICKET_CHANNEL_ID=$CHANNEL_ID
DISCORD_BOT_SECRET=$BOT_SECRET
SITE_URL=$SITE_URL
EOF
echo -e "${GREEN}✓ .env written${RESET}"
echo ""

# ── Step 5: Run database migration ───────────────────────────
echo -e "${BOLD}[5/7] Running database migration...${RESET}"
if [ ! -f "migrate_discord.py" ]; then
    echo -e "${RED}✗ migrate_discord.py not found in current directory.${RESET}"
    echo -e "${YELLOW}  Make sure you are running this script from your cio/ project folder.${RESET}"
    exit 1
fi
$PYTHON migrate_discord.py
echo ""

# ── Step 6: Check discord_bot.py is present ───────────────────
echo -e "${BOLD}[6/7] Checking discord_bot.py...${RESET}"
if [ ! -f "discord_bot.py" ]; then
    echo -e "${RED}✗ discord_bot.py not found in current directory.${RESET}"
    echo -e "${YELLOW}  Copy discord_bot.py into your cio/ project folder.${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ discord_bot.py found${RESET}"
echo ""

# ── Step 7: Create systemd service (optional) ─────────────────
echo -e "${BOLD}[7/7] Create a systemd service to keep the bot running?${RESET}"
read -rp "  Create systemd service? (y/n): " WANT_SERVICE
echo ""

if [[ "$WANT_SERVICE" =~ ^[Yy]$ ]]; then
    PROJECT_DIR=$(pwd)
    SERVICE_NAME="cioda-discord-bot"

    sudo bash -c "cat > /etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cioda Discord Ticket Bot
After=network.target

[Service]
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${PYTHON} ${PROJECT_DIR}/discord_bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl start  "$SERVICE_NAME"
    echo -e "${GREEN}✓ Service '${SERVICE_NAME}' created and started${RESET}"
    echo -e "${YELLOW}  Check status:  sudo systemctl status ${SERVICE_NAME}${RESET}"
    echo -e "${YELLOW}  View logs:     sudo journalctl -u ${SERVICE_NAME} -f${RESET}"
else
    echo -e "${YELLOW}  Skipped. To start the bot manually:${RESET}"
    echo ""
    echo -e "    ${CYAN}export \$(cat .env | xargs) && python3 discord_bot.py${RESET}"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Setup complete!  One last step:${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo ""
echo -e "  1. Open your site admin panel → ${BOLD}Settings${RESET}"
echo -e "  2. Fill in these three new fields:"
echo ""
echo -e "     ${BOLD}Discord Bot Token:${RESET}      ${BOT_TOKEN:0:20}...  (same as above)"
echo -e "     ${BOLD}Discord Channel ID:${RESET}     ${CHANNEL_ID}"
echo -e "     ${BOLD}Discord Bot Secret:${RESET}     ${BOT_SECRET}"
echo ""
echo -e "  3. Save settings — that's it! Tickets now sync both ways. 🎉"
echo ""
echo -e "${YELLOW}  Reminder: Invite your bot to your server if you haven't:${RESET}"
echo -e "  https://discord.com/oauth2/authorize?client_id=YOUR_APP_ID&permissions=326417403904&scope=bot+applications.commands"
echo ""
