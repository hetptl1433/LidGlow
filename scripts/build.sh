#!/bin/zsh
set -eu

LIDGLOW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIDGLOW_DEST="${1:-$LIDGLOW_ROOT/dist}"
mkdir -p "$LIDGLOW_ROOT/.build/module-cache" "$LIDGLOW_DEST"
export CLANG_MODULE_CACHE_PATH="$LIDGLOW_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LIDGLOW_ROOT/.build/module-cache"
cd "$LIDGLOW_ROOT"
swift build -c release --product LidGlow -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product LidGlowSignal -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox

LIDGLOW_APP="$LIDGLOW_DEST/LidGlow.app"
mkdir -p "$LIDGLOW_APP/Contents/MacOS" "$LIDGLOW_APP/Contents/Resources"
cp "$LIDGLOW_ROOT/.build/release/LidGlow" "$LIDGLOW_APP/Contents/MacOS/LidGlow"
cp "$LIDGLOW_ROOT/.build/release/LidGlowSignal" "$LIDGLOW_APP/Contents/MacOS/LidGlowSignal"
cp "$LIDGLOW_ROOT/Resources/lidglow-hook.py" "$LIDGLOW_APP/Contents/Resources/"
cp "$LIDGLOW_ROOT/Resources/HOOKS.md" "$LIDGLOW_APP/Contents/Resources/"
cp "$LIDGLOW_ROOT/THIRD_PARTY_NOTICES.md" "$LIDGLOW_APP/Contents/Resources/"
cp "$LIDGLOW_ROOT/LICENSE" "$LIDGLOW_APP/Contents/Resources/"
cp "$LIDGLOW_ROOT/SOURCES.md" "$LIDGLOW_APP/Contents/Resources/"

cat > "$LIDGLOW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LidGlow</string>
  <key>CFBundleIdentifier</key><string>local.lidglow.mac</string>
  <key>CFBundleName</key><string>LidGlow</string>
  <key>CFBundleDisplayName</key><string>LidGlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>LidGlow</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>LidGlow controls</string>
    <key>CFBundleURLSchemes</key><array><string>lidglow</string></array>
  </dict></array>
</dict></plist>
PLIST

swift -module-cache-path "$LIDGLOW_ROOT/.build/module-cache" "$LIDGLOW_ROOT/scripts/make-icon.swift" "$LIDGLOW_ROOT/.build/LidGlow.iconset"
/usr/bin/python3 "$LIDGLOW_ROOT/scripts/make-icns.py" "$LIDGLOW_ROOT/.build/LidGlow.iconset" "$LIDGLOW_APP/Contents/Resources/LidGlow.icns"
plutil -lint "$LIDGLOW_APP/Contents/Info.plist"
codesign --force --sign - "$LIDGLOW_APP/Contents/MacOS/LidGlowSignal"
codesign --force --sign - "$LIDGLOW_APP"
codesign --verify --deep --strict "$LIDGLOW_APP"
echo "Built $LIDGLOW_APP"
