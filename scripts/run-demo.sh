#!/bin/bash
# Builds and launches an isolated demo copy of Wingcord with its `--demo`
# fixtures.
#
# **Its own bundle id, so it never touches the real app.** `dev.wingcord.Wingcord.demo`
# has its own defaults domain and its own Application Support folder, and the
# bundle lives in build/demo/ — so a demo run cannot change the reader's real
# settings, overwrite the real build/Wingcord.app (which may be running), or
# collide with its single-window scene. Ad-hoc signed: `--demo` makes no
# requests and needs no Keychain.
#
# Usage: scripts/run-demo.sh [debug|release] [extra launch arguments…]
# Debug by default — this is for looking at the design, not for measuring it
# (build-app.sh's note: a debug build is not evidence of performance).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
shift || true
APP="$ROOT/build/demo/Wingcord Demo.app"
DEMO_ID="dev.wingcord.Wingcord.demo"

cd "$ROOT"
swift build -c "$CONFIG" --product Wingcord
BIN_DIR="$(swift build -c "$CONFIG" --product Wingcord --show-bin-path)"

# A copy already running would keep the old binary on screen. Asked to quit
# first, so it exits cleanly (a killed run leaves a header-only crash report
# behind in its own diagnostics folder); killed only if it will not.
if pgrep -f "$APP/Contents/MacOS/Wingcord" >/dev/null 2>&1; then
    osascript -e "tell application id \"$DEMO_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$APP/Contents/MacOS/Wingcord" >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -f "$APP/Contents/MacOS/Wingcord" 2>/dev/null || true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Wingcord" "$APP/Contents/MacOS/Wingcord"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Wingcord Demo" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Wingcord Demo" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

BUNDLE="$BIN_DIR/Wingcord_Wingcord.bundle"
if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE is missing — the demo would run without its fonts." >&2
    exit 1
fi
cp -R "$BUNDLE" "$APP/Contents/Resources/"

# The icon, borrowed from the last full build when there is one: compiling the
# Icon Composer document on every demo run is seconds spent on a Dock tile.
if [ -f "$ROOT/build/Wingcord.app/Contents/Resources/Assets.car" ]; then
    cp "$ROOT/build/Wingcord.app/Contents/Resources/Assets.car" "$APP/Contents/Resources/"
    cp "$ROOT/build/Wingcord.app/Contents/Resources/"*.icns "$APP/Contents/Resources/" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$APP/Contents/Info.plist"
fi

codesign --force --sign - \
    --entitlements "$ROOT/Packaging/Wingcord.entitlements" \
    --timestamp=none "$APP" 2>/dev/null \
    || echo "warning: ad-hoc signing failed." >&2

open -n "$APP" --args --demo "$@"
echo "Demo: $APP ($DEMO_ID)"
