#!/bin/zsh
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_ROOT/Codex Dashboard.app"

if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "Codex Dashboard is not installed at: $INSTALLED_APP"
  exit 0
fi

osascript -e 'tell application id "local.lawrenceawe.codex-dashboard" to quit' 2>/dev/null || true
TRASH_TARGET="$HOME/.Trash/Codex Dashboard.app"
if [[ -e "$TRASH_TARGET" ]]; then
  TRASH_TARGET="$HOME/.Trash/Codex Dashboard-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$INSTALLED_APP" "$TRASH_TARGET"
echo "Moved to Trash: $TRASH_TARGET"
