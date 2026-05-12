#!/bin/bash
set -e

# Build configuration
# - CONFIG=debug|release  (default: debug)
# - UNIVERSAL=1           build a fat arm64+x86_64 binary (default: host arch only)
CONFIG="${CONFIG:-debug}"
UNIVERSAL="${UNIVERSAL:-0}"

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --release)   CONFIG="release" ;;
        --debug)     CONFIG="debug" ;;
    esac
done

# Paths
APP_NAME="capcap.app"
APP_DIR="build/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build binary
if [ "$UNIVERSAL" = "1" ]; then
    echo "Building capcap ($CONFIG, universal: arm64 + x86_64)..."
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    # SwiftPM emits the merged universal binary under .build/apple/Products/<Config>/
    CONFIG_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
    BUILD_BIN=".build/apple/Products/$CONFIG_CAP/capcap"
    if [ ! -f "$BUILD_BIN" ]; then
        # Fallback: merge per-arch binaries with lipo
        ARM_BIN=".build/arm64-apple-macosx/$CONFIG/capcap"
        X86_BIN=".build/x86_64-apple-macosx/$CONFIG/capcap"
        if [ -f "$ARM_BIN" ] && [ -f "$X86_BIN" ]; then
            BUILD_BIN=".build/$CONFIG/capcap-universal"
            lipo -create -output "$BUILD_BIN" "$ARM_BIN" "$X86_BIN"
        else
            echo "error: universal binary not found at $BUILD_BIN and per-arch fallbacks missing" >&2
            exit 1
        fi
    fi
else
    echo "Building capcap ($CONFIG, host arch only)..."
    swift build -c "$CONFIG"
    BUILD_BIN=".build/$CONFIG/capcap"
fi

# Clean previous bundle
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$BUILD_BIN" "$MACOS/capcap"

# Copy Info.plist
cp "capcap/App/Info.plist" "$CONTENTS/Info.plist"

# Copy app icon
cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# Code sign with ad-hoc signature (stable identity for macOS permissions)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
codesign --force --sign "Apple Development: cnskyrin@gmail.com" --entitlements "$SCRIPT_DIR/capcap.entitlements" "$APP_DIR"

echo "✅ Built and signed $APP_DIR"
ARCHS=$(lipo -archs "$MACOS/capcap" 2>/dev/null || echo "unknown")
echo "   Architectures: $ARCHS"
echo ""
echo "To run:"
echo "  open build/$APP_NAME"
echo ""
echo "To install to /Applications:"
echo "  cp -r build/$APP_NAME /Applications/"
