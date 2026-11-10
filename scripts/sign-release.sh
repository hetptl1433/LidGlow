#!/bin/zsh
set -euo pipefail

# Developer ID signing for a finished LidGlow.app. The regular build script
# deliberately keeps using ad-hoc signing for local development and CI.
APP="${1:?Usage: sign-release.sh /path/to/LidGlow.app identity}"
IDENTITY="${2:?Missing Developer ID Application identity (name or SHA-1 fingerprint)}"

if [[ ! -d "$APP/Contents/MacOS" || ! -f "$APP/Contents/Info.plist" ]]; then
  echo "Not a macOS app bundle: $APP" >&2
  exit 1
fi

# The native hook helper is a standalone executable inside the app. Sign it
# explicitly before signing the outer app, with Apple's required runtime.
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/MacOS/LidGlowSignal"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

for target in "$APP/Contents/MacOS/LidGlowSignal" "$APP"; do
  detail="$(codesign -dv --verbose=4 "$target" 2>&1)"
  if ! grep -q '^Authority=Developer ID Application:' <<< "$detail"; then
    echo "Expected Developer ID Application signature on $target" >&2
    exit 1
  fi
  if ! grep -q 'flags=.*runtime' <<< "$detail"; then
    echo "Expected hardened runtime on $target" >&2
    exit 1
  fi
  if ! grep -Eq '^Timestamp=[^ ]' <<< "$detail"; then
    echo "Expected secure timestamp on $target" >&2
    exit 1
  fi
done

echo "Developer ID signature, hardened runtime, and timestamps verified for $APP"
