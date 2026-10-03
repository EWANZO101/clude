#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Cape Flats Roleplay — Bot Installer
# ─────────────────────────────────────────────────────────────────────────────

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

print_banner() {
    echo -e "${CYAN}"
    echo "  ██████╗███████╗██████╗ ██████╗ "
    echo " ██╔════╝██╔════╝██╔══██╗██╔══██╗"
    echo " ██║     █████╗  ██████╔╝██████╔╝"
    echo " ██║     ██╔══╝  ██╔══██╗██╔═══╝ "
    echo " ╚██████╗██║     ██║  ██║██║     "
    echo "  ╚═════╝╚═╝     ╚═╝  ╚═╝╚═╝     "
    echo -e "${NC}"
    echo -e "${BOLD}  Cape Flats Roleplay — Discord Bot Installer${NC}"
    echo "  ─────────────────────────────────────────"
    echo ""
}

step() { echo -e "${CYAN}[STEP]${NC} $1"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

print_banner

# ── 1. Check Python ────────────────────────────────────────────────────────
step "Checking Python version..."
if ! command -v python3 &>/dev/null; then
    fail "Python 3 is not installed. Install it with: apt install python3"
fi

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo $PY_VER | cut -d. -f1)
PY_MINOR=$(echo $PY_VER | cut -d. -f2)

if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    fail "Python 3.10+ required. You have $PY_VER"
fi
ok "Python $PY_VER found"

# ── 2. Create virtual environment ──────────────────────────────────────────
step "Setting up virtual environment..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
    ok "Virtual environment created"
else
    ok "Virtual environment already exists — skipping"
fi

source venv/bin/activate

# ── 3. Upgrade pip silently ────────────────────────────────────────────────
step "Upgrading pip..."
pip install --upgrade pip -q
ok "pip up to date"

# ── 4. Install dependencies ────────────────────────────────────────────────
step "Installing Python dependencies..."
pip install -r requirements.txt -q
ok "Dependencies installed"

# ── 5. Create data directory ───────────────────────────────────────────────
step "Creating data directory..."
mkdir -p data
ok "data/ ready"

# ── 6. Set up .env ─────────────────────────────────────────────────────────
step "Configuring environment..."
if [ -f ".env" ]; then
    warn ".env already exists — skipping creation"
else
    cp .env.example .env
    ok ".env created from template"
fi

# ── 7. Prompt for Discord token ────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Discord Bot Token ──────────────────────────────────────${NC}"
echo "  Get yours from: https://discord.com/developers/applications"
echo "  App → Bot → Reset Token → copy the full token"
echo ""
read -rp "  Paste your Discord bot token (leave blank to set manually later): " TOKEN

if [ -n "$TOKEN" ]; then
    # Works on both Linux and macOS
    sed -i "s|DISCORD_TOKEN=.*|DISCORD_TOKEN=$TOKEN|" .env
    ok "Token saved to .env"
else
    warn "Token not set. Edit .env manually before running the bot."
fi

# ── 8. Check / install Ollama ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Ollama AI ───────────────────────────────────────────────${NC}"
if command -v ollama &>/dev/null; then
    ok "Ollama is already installed"
else
    step "Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
    ok "Ollama installed"
fi

# ── 9. Pull the AI model ───────────────────────────────────────────────────
MODEL=$(grep "^OLLAMA_MODEL=" .env | cut -d= -f2)
MODEL=${MODEL:-llama3}

if ollama list 2>/dev/null | grep -q "^$MODEL"; then
    ok "Model '$MODEL' already pulled"
else
    step "Pulling Ollama model '$MODEL' (this may take a few minutes)..."
    ollama pull "$MODEL"
    ok "Model '$MODEL' ready"
fi

# ── 10. Done ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "  Start the bot:   ${CYAN}source venv/bin/activate && python bot.py${NC}"
echo ""
echo -e "  ${YELLOW}Before starting, make sure:${NC}"
echo "  • .env has a valid DISCORD_TOKEN"
echo "  • Message Content Intent is enabled in the Discord Developer Portal"
echo "  • Ollama is running  (it auto-starts on most systems after install)"
echo ""
