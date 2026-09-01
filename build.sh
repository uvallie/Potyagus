#!/bin/bash
# Build Розімнись.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/Розімнись.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "→ компілюю…"
swiftc -O \
  -framework Cocoa -framework WebKit \
  -o "$MACOS/rozimnys" \
  "$ROOT/src/main.swift"

cp "$ROOT/web/overlay.html"     "$RES/overlay.html"
cp "$ROOT/data/exercises.json"  "$RES/exercises.json"
[ -d "$ROOT/web/clips" ] && cp -R "$ROOT/web/clips" "$RES/clips"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Розімнись</string>
  <key>CFBundleDisplayName</key>        <string>Розімнись</string>
  <key>CFBundleExecutable</key>         <string>rozimnys</string>
  <key>CFBundleIdentifier</key>         <string>com.alina.rozimnys</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>            <string>1</string>
  <key>LSMinimumSystemVersion</key>     <string>13.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps macOS from re-prompting on every rebuild.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ зібрано: $APP"
