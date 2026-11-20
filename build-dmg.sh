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

# Підпис і нотаризація DMG — тільки коли є Developer ID і профіль notarytool «potyagus»
# (xcrun notarytool store-credentials potyagus --apple-id … --team-id …).
ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -n "$ID" ]; then
  codesign --force --timestamp --sign "$ID" "$DMG"
  if xcrun notarytool history --keychain-profile potyagus >/dev/null 2>&1; then
    echo "→ нотаризую (кілька хвилин)…"
    xcrun notarytool submit "$DMG" --keychain-profile potyagus --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
  else
    echo "! профілю notarytool «potyagus» нема — DMG підписаний, але не нотаризований"
  fi
fi
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
