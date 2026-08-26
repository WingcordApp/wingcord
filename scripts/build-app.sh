#!/bin/bash
# Builds Wingcord.app.
#
# Release by default. A debug build is not evidence of anything: SwiftUI's own
# machinery and every generic in the app are unoptimised there, so a debug
# profile measures the compiler's output rather than the app's design.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Wingcord.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Wingcord

BIN="$(swift build -c "$CONFIG" --product Wingcord --show-bin-path)/Wingcord"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wingcord"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── App icon ───────────────────────────────────────────────────────────────
# The icon is an Icon Composer document, not a pre-rendered .icns. `actool`
# compiles it into an Assets.car carrying the light / dark / tinted / clear
# appearance variants macOS renders in the Dock and Finder, plus a flattened
# .icns for anything that still asks for one by file.
#
# It is staged as "AppIcon.icon" because actool names its output after the
# INPUT FILENAME, and CFBundleIconName has to match.
#
# A missing icon FAILS THE BUILD rather than warning. The failure mode of a
# warning here is a build that ships without an icon while printing one line
# nobody reads — which is exactly how a stale icon survives for weeks.
ICON_SRC="$ROOT/Packaging/AppIcon.icon"
if [ ! -d "$ICON_SRC" ]; then
    echo "error: $ICON_SRC is missing — refusing to ship an iconless build." >&2
    exit 1
fi

ICON_STAGE="$(mktemp -d)"
trap 'rm -rf "$ICON_STAGE"' EXIT
cp -R "$ICON_SRC" "$ICON_STAGE/AppIcon.icon"
xcrun actool "$ICON_STAGE/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 27.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_STAGE/icon.plist" \
    > /dev/null

# Point the bundle at the catalog entry, so macOS uses the appearance-aware
# variants rather than only the flat .icns.
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" \
    "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$APP/Contents/Info.plist"

# Ad-hoc signing with entitlements. Unsigned, the app cannot hold the microphone
# or camera permissions it will eventually ask for, and macOS re-prompts for
# network access on every rebuild.
codesign --force --sign - \
    --entitlements "$ROOT/Packaging/Wingcord.entitlements" \
    --timestamp=none "$APP" 2>/dev/null

echo "App: $APP"
