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

# Load PORT (and any other settings) from .env if present.
set -a
[ -f .env ] && source .env
set +a
PORT="${PORT:-8765}"

# Open the browser shortly after the server starts.
( sleep 1.5; open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true ) &

exec uvicorn app.main:app --host 127.0.0.1 --port "${PORT}"
