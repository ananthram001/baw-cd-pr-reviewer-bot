#!/bin/bash
# =============================================================================
# install.sh — Install baw-cd-pr-reviewer-bot on RHEL
# Run as root: bash install.sh
# =============================================================================

set -euo pipefail

BOT_NAME="baw-cd-pr-reviewer-bot"
BASE_DIR="/opt/$BOT_NAME"
CONFIG_DIR="/etc/$BOT_NAME"

echo "======================================================"
echo "  Installing $BOT_NAME"
echo "======================================================"

# ── 1. System packages ────────────────────────────────────────────────────────
echo "[1/7] Installing system dependencies..."

# Node.js 20
if ! command -v node &>/dev/null; then
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  dnf install -y nodejs
fi

# GitHub CLI
if ! command -v gh &>/dev/null; then
  dnf install -y 'dnf-command(config-manager)' || true
  dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
  dnf install -y gh
fi

# jq (used in poll script)
if ! command -v jq &>/dev/null; then
  dnf install -y jq
fi

echo "  ✓ node $(node --version), gh $(gh --version | head -1), jq $(jq --version)"

# ── 2. Bob Shell ─────────────────────────────────────────────────────────────
echo "[2/7] Installing Bob Shell..."
npm install -g @bob-shell/cli
echo "  ✓ bob $(bob --version 2>/dev/null || echo 'installed')"

# ── 3. Directory layout ───────────────────────────────────────────────────────
echo "[3/7] Creating directory layout..."
mkdir -p "$BASE_DIR/logs" "$BASE_DIR/state" "$CONFIG_DIR"

# ── 4. Copy bot files ─────────────────────────────────────────────────────────
echo "[4/7] Installing bot script..."
cp poll-prs.sh "$BASE_DIR/poll-prs.sh"
chmod +x "$BASE_DIR/poll-prs.sh"

# ── 5. Config template ────────────────────────────────────────────────────────
echo "[5/7] Writing config template..."

if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
cat > "$CONFIG_DIR/config.env" << 'EOF'
# baw-cd-pr-reviewer-bot configuration
# Edit this file then run: systemctl restart baw-cd-pr-reviewer-bot (if using systemd)

# IBM Bob Shell API key (required)
BOBSHELL_API_KEY=REPLACE_WITH_YOUR_BOB_TOKEN

# GitHub bot account Personal Access Token (required)
# Must have repo scope on all watched repos
GH_TOKEN=REPLACE_WITH_BOT_GITHUB_TOKEN
EOF
  echo "  ✓ Config written to $CONFIG_DIR/config.env — EDIT THIS FILE"
else
  echo "  ℹ Config already exists at $CONFIG_DIR/config.env — not overwritten"
fi

# Repos list
if [[ ! -f "$BASE_DIR/repos.txt" ]]; then
cat > "$BASE_DIR/repos.txt" << 'EOF'
# List of GitHub repos to watch — one per line
# Format: owner/repo
# Lines starting with # are ignored
#
# Example:
# ibm/my-baw-repo
# myorg/cp4ba-automation
EOF
  echo "  ✓ Repos list written to $BASE_DIR/repos.txt — ADD YOUR REPOS"
fi

# ── 6. Cron job ───────────────────────────────────────────────────────────────
echo "[6/7] Setting up cron job (every 20 minutes)..."
CRON_LINE="*/20 * * * * source $CONFIG_DIR/config.env && $BASE_DIR/poll-prs.sh >> $BASE_DIR/logs/cron.log 2>&1"

# Remove old entry if exists, then add fresh
(crontab -l 2>/dev/null | grep -v "poll-prs.sh" || true) | { cat; echo "$CRON_LINE"; } | crontab -
echo "  ✓ Cron installed"

# ── 7. Log rotation ───────────────────────────────────────────────────────────
echo "[7/7] Setting up log rotation..."
cp logrotate.conf /etc/logrotate.d/$BOT_NAME
echo "  ✓ Log rotation configured"

# ── Accept Bob license ────────────────────────────────────────────────────────
echo ""
echo "Accepting Bob Shell license..."
source "$CONFIG_DIR/config.env" 2>/dev/null || true
if [[ "${BOBSHELL_API_KEY:-REPLACE}" != "REPLACE_WITH_YOUR_BOB_TOKEN" ]]; then
  BOBSHELL_API_KEY="$BOBSHELL_API_KEY" bob --accept-license --auth-method api-key -p "hello" >/dev/null 2>&1 && \
    echo "  ✓ Bob license accepted" || echo "  ⚠ Bob license accept failed — run manually after setting token"
else
  echo "  ⚠ Skipped Bob license (token not yet configured)"
fi

echo ""
echo "======================================================"
echo "  Installation complete!"
echo "======================================================"
echo ""
echo "  NEXT STEPS:"
echo "  1. Edit credentials:  vi $CONFIG_DIR/config.env"
echo "  2. Add repos to watch: vi $BASE_DIR/repos.txt"
echo "  3. Run manually first: source $CONFIG_DIR/config.env && $BASE_DIR/poll-prs.sh"
echo "  4. Check logs:         tail -f $BASE_DIR/logs/review.log"
echo ""
