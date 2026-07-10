#!/usr/bin/env bash
# Pull GoodGuyBadGuy's on-device debug log (written by DebugLog.swift) off the
# paired iPhone. No console attach needed; the app keeps running.
#
#   tools/pulllog.sh [udid]     # prints the log to stdout
set -euo pipefail
UDID="${1:-8B053FBC-B638-548F-B045-F5DDE25D3BDD}"
DEST=$(mktemp -d)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier com.clawd.goodguybadguy \
  --source Documents/goodguybadguy.log --destination "$DEST/goodguybadguy.log" --quiet
cat "$DEST/goodguybadguy.log"
