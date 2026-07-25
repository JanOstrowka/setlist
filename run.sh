#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Create the virtualenv on first run and install the app.
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -e . >/dev/null

# Read only PORT from .env, without executing the file. Sourcing the whole
# .env breaks on any unquoted space in a value (e.g. OUTPUT_DIR=~/Music/YouTube
# Sets), where bash would try to run "Sets" as a command. The Python app loads
# the rest of .env itself, so bash only needs PORT here.
PORT="$(sed -n 's/^[[:space:]]*PORT[[:space:]]*=[[:space:]]*//p' .env 2>/dev/null | tail -n1 | tr -d '"' | tr -d '[:space:]')"
PORT="${PORT:-8765}"

# The native wrapper supplies its own window.
if [ "${OPEN_BROWSER:-1}" = "1" ]; then
  ( sleep 1.5; open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true ) &
fi

exec uvicorn app.main:app --host 127.0.0.1 --port "${PORT}"
