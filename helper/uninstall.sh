#!/usr/bin/env bash
# Remove the Setlist helper LaunchAgent installed by helper/install.sh.
# Stops the background server and deletes the plist; the repo, venv, .env, and
# your downloaded music are untouched.
set -euo pipefail

LABEL="com.setlist.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Stopped $LABEL" || echo "$LABEL was not running"
if [ -f "$PLIST" ]; then
  rm "$PLIST"
  echo "Removed $PLIST"
else
  echo "No plist at $PLIST (already uninstalled?)"
fi
echo "Log file left at ~/Library/Logs/setlist-helper.log — delete it if you like."
