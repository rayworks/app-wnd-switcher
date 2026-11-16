#!/bin/bash
# Builds build/WndSwitcher.app. Usage: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WndSwitcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/WndSwitcher" Sources/main.swift

# Sign with the local self-signed identity when it exists, so the Accessibility
# grant survives rebuilds; ad-hoc signatures change on every build.
IDENTITY="WndSwitcher Local Signing"
security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" || IDENTITY=""
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--run" ]]; then
    # Wait for the old instance to exit, or `open` can fail with error -600.
    pkill -x WndSwitcher 2>/dev/null || true
    for _ in {1..50}; do pgrep -x WndSwitcher >/dev/null || break; sleep 0.1; done
    open "$APP" || { sleep 1; open "$APP"; }
fi
