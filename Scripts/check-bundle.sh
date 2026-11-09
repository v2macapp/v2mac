#!/bin/bash
# Verify both thin distributions before packaging or uploading them.
set -euo pipefail
APP="$1"; ARCH="$2"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
source "$(dirname "$0")/core.lock"
[[ "$ARCH" == x86_64 ]] && SHA256="$SHA256_X86_64"
[[ "$(/usr/libexec/PlistBuddy -c 'Print V2MacCoreSHA256' "$APP/Contents/Info.plist")" == "$SHA256" ]]
[[ ! -e "$APP/Contents/Resources/v2mac" && ! -e "$APP/Contents/Resources/V2MacPrivilegedHelper" ]]
for path in MacOS/V2Mac Helpers/xray Helpers/v2mac Library/HelperTools/V2MacPrivilegedHelper PlugIns/V2MacControl.appex/Contents/MacOS/V2MacControl; do
  [[ "$(lipo -archs "$APP/Contents/$path")" == "$ARCH" ]] || { echo "Wrong architecture: $path" >&2; exit 1; }
  codesign --verify --strict "$APP/Contents/$path"
done
codesign --verify --deep --strict "$APP"
"$APP/Contents/Helpers/v2mac" --help >/dev/null
