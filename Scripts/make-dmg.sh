#!/bin/bash
# Builds a Release app, signs it (helper first, then the app) and packages a DMG.
#
#   Scripts/make-dmg.sh                     ad-hoc signed DMG in ./dist
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=my-profile Scripts/make-dmg.sh
#                                           Developer ID signing + notarization
#
# Parameters (environment): ARCH (arm64 default, or x86_64), SIGN_IDENTITY (default "-", ad-hoc), NOTARY_PROFILE
# (a `notarytool store-credentials` profile; skipped when empty), OUT_DIR (default dist).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) SUFFIX=""; CORE_DIR=core ;;
  x86_64) SUFFIX="-intel"; CORE_DIR=core-x86_64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
BUILD_DIR="$ROOT/build$SUFFIX"
ENTITLEMENTS="$ROOT/App/Resources/v2mac.entitlements"

cd "$ROOT"
[[ -x "Vendor/$CORE_DIR/xray" ]] || ARCH="$ARCH" Scripts/fetch-core.sh
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$BUILD_DIR"
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  ARCHS="$ARCH" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build | tail -n 3

APP="$BUILD_DIR/Build/Products/Release/V2Mac.app"
[[ -d "$APP" ]] || { echo "error: build produced no app" >&2; exit 1; }

# The helper and the Control Center extension must be signed before the app that contains
# them. WidgetKit loads the extension only with its sandbox entitlement.
CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && CODESIGN_ARGS+=(--options runtime --timestamp)
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --identifier io.github.lordversa.v2mac.xray "$APP/Contents/Helpers/xray"
# The app accepts only a CLI signed with this identifier (CLIService.validClient).
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --identifier io.github.lordversa.v2mac.cli "$APP/Contents/Helpers/v2mac"
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --identifier io.github.lordversa.v2mac.privileged \
  "$APP/Contents/Library/HelperTools/V2MacPrivilegedHelper"
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --entitlements "$ROOT/Extensions/Control/V2MacControl.entitlements" \
  "$APP/Contents/PlugIns/V2MacControl.appex"
/usr/bin/codesign "${CODESIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
"$ROOT/Scripts/check-bundle.sh" "$APP" "$ARCH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/V2Mac-$VERSION$SUFFIX.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The window's background and icon positions, made once by Scripts/make-dmg-layout.sh. The
# layout finds its picture by volume name and path, so neither may change here.
mkdir "$STAGE/.background"
cp "$ROOT/Scripts/dmg/background.tiff" "$STAGE/.background/background.tiff"
cp "$ROOT/Scripts/dmg/DS_Store" "$STAGE/.DS_Store"
rm -f "$DMG"
hdiutil create -quiet -volname "V2Mac" -srcfolder "$STAGE" -format UDZO -ov "$DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
# The in-app updater only installs a DMG signed with the project's key (spec 11.3).
if [[ -n "${UPDATE_SIGNING_KEY:-}" ]]; then
  "$ROOT/Scripts/sign-update.swift" "$DMG"
fi
echo "Built $DMG"
