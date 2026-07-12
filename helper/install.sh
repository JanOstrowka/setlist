#!/usr/bin/env bash
# Install the Setlist helper as a macOS LaunchAgent so it runs at login.
#
# What this does (single-user setup — no code-signing/notarization; that's a
# later, multi-user distribution step):
#   1. Creates the repo venv and installs the app (same as run.sh).
#   2. Writes ~/Library/LaunchAgents/com.setlist.helper.plist pointing at the
#      repo's venv uvicorn, with the repo as working directory (so .env loads).
#   3. Loads it via launchctl. Logs go to ~/Library/Logs/setlist-helper.log.
#
# Re-run after moving the repo or changing PORT in .env. Remove with
# helper/uninstall.sh.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.setlist.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/setlist-helper.log"
cd "$REPO_DIR"

# --- venv + install (mirrors run.sh) -----------------------------------------
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q -e . >/dev/null

# --- read PORT from .env without sourcing it (values may contain spaces) ------
PORT="$(sed -n 's/^[[:space:]]*PORT[[:space:]]*=[[:space:]]*//p' .env 2>/dev/null | tail -n1 | tr -d '"' | tr -d '[:space:]')"
PORT="${PORT:-8765}"

# --- refuse to fight an already-running server --------------------------------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  if [ "${SETLIST_INSTALL_FORCE:-0}" != "1" ]; then
    echo "Port $PORT is already in use (a manual ./run.sh session?)."
    echo "Stop that server first (Ctrl-C in its terminal), then re-run this script."
    echo "Or install without starting now: SETLIST_INSTALL_FORCE=1 helper/install.sh"
    echo "(with FORCE, the agent starts automatically once the port frees up / at next login)"
    exit 1
  fi
  START_NOW=0
else
  START_NOW=1
fi

# --- LaunchAgent plist ---------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO_DIR/.venv/bin/uvicorn</string>
    <string>app.main:app</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null

# --- (re)load ------------------------------------------------------------------
GUI_DOMAIN="gui/$(id -u)"
launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST"

echo "Installed LaunchAgent $LABEL"
echo "  runs:    $REPO_DIR/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PORT"
echo "  log:     $LOG"
if [ "$START_NOW" = "1" ]; then
  sleep 2
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "  status:  running — http://127.0.0.1:$PORT"
  else
    echo "  status:  starting… check: curl http://127.0.0.1:$PORT/health   (log: $LOG)"
  fi
else
  echo "  status:  installed; will start once port $PORT is free (or at next login)"
fi
