#!/bin/bash
# Build Potyagus.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/Potyagus.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "→ компілюю…"
# INSPECT=1 ./build.sh вмикає Safari Web Inspector для вікна з гусем; у релізі його нема.
FLAGS=(); [ "${INSPECT:-0}" = 1 ] && FLAGS+=(-D INSPECTABLE) && echo "→ з Web Inspector"
swiftc -O ${FLAGS[@]+"${FLAGS[@]}"} \
  -framework Cocoa -framework WebKit \
  -o "$MACOS/potyagus" \
  "$ROOT/src/main.swift"

cp "$ROOT/web/overlay.html"     "$RES/overlay.html"
cp "$ROOT/data/exercises.json"  "$RES/exercises.json"
cp "$ROOT/art/icon/Potyagus.icns" "$RES/Potyagus.icns"
cp "$ROOT/art/icon/menubar/goose-menubar.png" "$ROOT/art/icon/menubar/goose-menubar@2x.png" "$RES/"
[ -d "$ROOT/web/clips" ] && cp -R "$ROOT/web/clips" "$RES/clips"
[ -d "$ROOT/web/sfx" ]   && cp -R "$ROOT/web/sfx"   "$RES/sfx"
[ -d "$ROOT/web/badges" ] && cp -R "$ROOT/web/badges" "$RES/badges"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Potyagus</string>
  <key>CFBundleDisplayName</key>        <string>Потягусь</string>
  <key>CFBundleExecutable</key>         <string>potyagus</string>
  <key>CFBundleIdentifier</key>         <string>com.alina.potyagus</string>
  <key>CFBundleIconFile</key>           <string>Potyagus</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.7.1</string>
  <key>CFBundleVersion</key>            <string>8</string>
  <key>LSMinimumSystemVersion</key>     <string>13.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

# Developer ID, якщо сертифікат є в Keychain (hardened runtime + timestamp — вимога нотаризації).
# Інакше ad-hoc: macOS не перепитує на кожному ребілді, але Gatekeeper просить правий клік.
ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -n "$ID" ]; then
  echo "→ підписую: $ID"
  codesign --force --options runtime --timestamp --sign "$ID" "$APP"
  codesign --verify --strict "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "✓ зібрано: $APP"
