#!/usr/bin/env bash
# Build Mac .app + .dmg and Android APK, copy into website/downloads/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/website/downloads"
mkdir -p "$DEST"

echo "==> Android APK"
(
  cd "$ROOT/android_app"
  flutter build apk --release
)
cp "$ROOT/android_app/build/app/outputs/flutter-apk/app-release.apk" "$DEST/Clipboard-Sync.apk"

echo "==> macOS .app"
(
  cd "$ROOT/desktop_app"
  flutter build macos --release
)

APP="$ROOT/desktop_app/build/macos/Build/Products/Release/Clipboard Sync.app"
if [[ ! -d "$APP" ]]; then
  echo "Expected app at: $APP"
  ls -la "$ROOT/desktop_app/build/macos/Build/Products/Release/" || true
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

echo "==> Zip of .app"
ditto -c -k --keepParent "$APP" "$DEST/Clipboard-Sync-macOS.zip"

echo "==> .dmg"
DMG="$DEST/Clipboard-Sync.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "Clipboard Sync" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo "==> Done"
ls -lh "$DEST"
