#!/usr/bin/env bash
# install.sh - Install warm-start for Claude Code
# Usage: bash install.sh
#
# What it does:
#   1. Copies warm-start.sh to ~/.claude/scripts/
#   2. Installs the /warm skill to ~/.claude/skills/warm/
#   3. Adds SessionStart hook to ~/.claude/settings.json
#   4. Verifies the installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
dim()  { echo -e "${DIM}    $1${NC}"; }

echo ""
echo "  warm-start installer"
echo "  Project intelligence for Claude Code"
echo ""

# ── Check dependencies ───────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  warn "jq is required but not installed."
  echo "  Install it: brew install jq (macOS) or apt install jq (Linux)"
  exit 1
fi

# ── Install script ───────────────────────────────────────────────────────

info "Installing warm-start.sh to ~/.claude/scripts/"
mkdir -p ~/.claude/scripts
cp "$SCRIPT_DIR/warm-start.sh" ~/.claude/scripts/warm-start.sh
chmod +x ~/.claude/scripts/warm-start.sh
dim "~/.claude/scripts/warm-start.sh"

# ── Install skill ────────────────────────────────────────────────────────

info "Installing /warm skill to ~/.claude/skills/warm/"
mkdir -p ~/.claude/skills/warm
cp "$SCRIPT_DIR/skills/warm/SKILL.md" ~/.claude/skills/warm/SKILL.md
dim "~/.claude/skills/warm/SKILL.md"

# ── Configure hook ───────────────────────────────────────────────────────

SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  info "Creating ~/.claude/settings.json"
  echo '{}' > "$SETTINGS_FILE"
fi

# Check if hook already exists
if jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command == "~/.claude/scripts/warm-start.sh")' "$SETTINGS_FILE" &>/dev/null; then
  info "SessionStart hook already configured (skipping)"
else
  info "Adding SessionStart hook to ~/.claude/settings.json"

  # Build the hook entry
  HOOK_ENTRY='{
    "hooks": [
      {
        "type": "command",
        "command": "~/.claude/scripts/warm-start.sh",
        "timeout": 5
      }
    ]
  }'

  # Add to settings, preserving existing hooks
  UPDATED=$(jq --argjson hook "$HOOK_ENTRY" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.SessionStart += [$hook]
  ' "$SETTINGS_FILE")

  echo "$UPDATED" > "$SETTINGS_FILE"
  dim "Added SessionStart hook"
fi

# ── Verify ───────────────────────────────────────────────────────────────

echo ""
info "Verifying installation..."

ERRORS=0

if [ ! -x "$HOME/.claude/scripts/warm-start.sh" ]; then
  warn "warm-start.sh not executable"
  ERRORS=$((ERRORS + 1))
fi

if [ ! -f "$HOME/.claude/skills/warm/SKILL.md" ]; then
  warn "/warm skill not found"
  ERRORS=$((ERRORS + 1))
fi

if ! jq -e '.hooks.SessionStart' "$SETTINGS_FILE" &>/dev/null; then
  warn "SessionStart hook not configured"
  ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
  echo ""
  info "Installation complete."
  echo ""
  echo "  What happens now:"
  echo "  - Every new Claude Code session starts with project context injected"
  echo "  - After compaction, context is automatically re-injected"
  echo "  - Use /warm mid-session to manually refresh"
  echo ""
  echo "  Optional: create .claude/warm-learnings.md in any project"
  echo "  to persist notes across sessions (e.g. build quirks, patterns)."
  echo ""
  echo "  To test it now:"
  dim "echo '{\"source\":\"startup\",\"cwd\":\"'\"$(pwd)\"'\"}' | ~/.claude/scripts/warm-start.sh"
  echo ""
else
  warn "$ERRORS issues found. Check the warnings above."
  exit 1
fi
