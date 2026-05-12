#!/usr/bin/env bash
# Build the .app, then package it into a draggable DMG and pop the install
# window for quick testing.
#
# Usage: scripts/package-dmg.sh
# Env:   OPEN_DMG_ON_SUCCESS=0   skip the auto-open at the end
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="capcap"
VOLNAME="capcap"
APP="$ROOT/build/${APP_NAME}.app"
DIST="$ROOT/dist"
STAGE="$ROOT/build/dmg-root"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/capcap/App/Info.plist")
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

echo "==> building .app (release, universal arm64 + x86_64)"
CONFIG=release UNIVERSAL=1 bash "$ROOT/scripts/bundle.sh"
[[ -d "$APP" ]] || { echo "error: $APP missing after build" >&2; exit 1; }

# Sanity-check: DMGs are shipped to users, so the binary must be universal.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/capcap" 2>/dev/null || true)"
if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
    echo "error: bundled binary is not universal (archs: $ARCHS)" >&2
    exit 1
fi
echo "==> binary archs: $ARCHS"

echo "==> staging dmg contents"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

echo "==> creating $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | awk '{print $1}')
echo ""
echo "SUCCESS: $DMG ($SIZE)"
echo "    drag ${APP_NAME}.app into Applications when the window opens."

if [[ "${OPEN_DMG_ON_SUCCESS:-1}" == "1" ]]; then
    echo "==> opening DMG"
    open "$DMG" || true
fi
