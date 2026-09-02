#!/bin/bash
# Збирає Potyagus.app і пакує в dist/Potyagus-<версія>.dmg з посиланням на Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$ROOT/build.sh"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Potyagus.app/Contents/Info.plist")
DIST="$ROOT/dist"; STAGE="$DIST/stage"; DMG="$DIST/Potyagus-$VER.dmg"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$ROOT/Potyagus.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "→ пакую ${DMG}…"
hdiutil create -quiet -volname "Потягусь $VER" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG"
rm -rf "$STAGE"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
