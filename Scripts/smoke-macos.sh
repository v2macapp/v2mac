#!/bin/bash
# Only the isolated dev app is allowed in this runtime check.
set -euo pipefail
APP="$1"; SNAPSHOT="$2"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" == io.github.lordversa.v2mac.dev ]] || exit 1
"$APP/Contents/Helpers/xray" version
"$APP/Contents/Helpers/v2mac" --help
"$APP/Contents/MacOS/V2MacDev" -tunEnabled NO -systemProxy NO -killSwitch NO -debugDemoData YES -debugSnapshot "$SNAPSHOT" > "$SNAPSHOT.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for ((i=0; i<60; i++)); do
  kill -0 "$PID" 2>/dev/null || { cat "$SNAPSHOT.log"; exit 1; }
  if grep -q '\[v2mac-debug\] snapshot: [1-9]' "$SNAPSHOT.log" && compgen -G "$SNAPSHOT-*.png" >/dev/null; then
    exit 0
  fi
  sleep 1
done
cat "$SNAPSHOT.log"
echo "No snapshot within 60 seconds" >&2
exit 1
