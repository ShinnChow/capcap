#!/bin/bash
set -euo pipefail

INFO_PLIST="${1:?Usage: inject-build-metadata.sh <Info.plist>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_COMMIT="${CAPCAP_BUILD_COMMIT:-}"

if [ ! -f "$INFO_PLIST" ]; then
    echo "error: Info.plist not found at $INFO_PLIST" >&2
    exit 1
fi

if [ -z "$BUILD_COMMIT" ]; then
    BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
fi

if [[ ! "$BUILD_COMMIT" =~ ^[0-9a-fA-F]{7,}$ ]]; then
    echo "error: invalid Git build commit: $BUILD_COMMIT" >&2
    exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Set :CapcapGitCommit $BUILD_COMMIT" "$INFO_PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CapcapGitCommit string $BUILD_COMMIT" "$INFO_PLIST"
fi

echo "Injected Git build commit: $BUILD_COMMIT"
