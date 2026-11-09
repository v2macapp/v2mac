#!/bin/bash
# Downloads the pinned Xray-core, verifies it against core.lock, unpacks to Vendor/core/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/core.lock"
case "${ARCH:-arm64}" in
  arm64) DEST="$ROOT/Vendor/core" ;;
  x86_64) DEST="$ROOT/Vendor/core-x86_64"; ASSET="$ASSET_X86_64"; SHA256="$SHA256_X86_64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

if [[ -x "$DEST/xray" && -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$VERSION" ]]; then
  echo "Xray $VERSION already present."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$ASSET"

echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/$ASSET"

ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "Checksum mismatch: expected $SHA256, got $ACTUAL" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
/usr/bin/ditto -x -k "$TMP/$ASSET" "$DEST"
chmod +x "$DEST/xray"
echo "$VERSION" > "$DEST/.version"
"$DEST/xray" version | head -1
