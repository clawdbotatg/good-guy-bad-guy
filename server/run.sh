#!/usr/bin/env bash
# Load .env and run the classifier in the foreground (systemd calls this).
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
exec python3 classifier.py
