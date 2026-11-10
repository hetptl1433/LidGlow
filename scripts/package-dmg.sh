#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/LidGlow.app}"

if [[ ! -d "$APP/Contents/MacOS" || ! -f "$APP/Contents/Info.plist" ]]; then
  echo "LidGlow.app not found at: $APP" >&2
  echo "Build it first: ./scripts/build.sh \"$ROOT/dist\"" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
OUTPUT="${2:-$ROOT/dist/LidGlow-$VERSION-macOS-$ARCH.dmg}"
mkdir -p "$(dirname "$OUTPUT")"

# A drag-to-Applications image, preserving the entire signed app bundle.
codesign --verify --deep --strict "$APP"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/lidglow-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/LidGlow.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "LidGlow" -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT"
echo "Created $OUTPUT"
