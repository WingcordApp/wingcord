#!/bin/bash
# Builds the vendored mediaremote-adapter into build/MediaRemoteAdapter.framework
# and prints its path.
#
# Usage: scripts/build-mediaremote-adapter.sh
#
# **Plain clang with the upstream CMake's own flags** (-O3 -fobjc-arc
# -fvisibility=default — the Perl loader calls exported symbols by name), so
# the build needs nothing beyond Xcode. A versioned framework bundle with an
# Info.plist, because it is signed as nested code inside the app and
# codesign refuses a bare directory. Rebuilt only when a source is newer than
# the binary: the app scripts call this on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Packaging/MediaRemoteAdapter"
FRAMEWORK="$ROOT/build/MediaRemoteAdapter.framework"
BINARY="$FRAMEWORK/Versions/A/MediaRemoteAdapter"

if [ -f "$BINARY" ] && [ -z "$(find "$SRC" -newer "$BINARY" -type f | head -1)" ]; then
    echo "$FRAMEWORK"
    exit 0
fi

rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Resources"
xcrun clang -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=27.0 -fPIC -fobjc-arc -fvisibility=default \
    -dynamiclib \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    -I "$SRC/include" -I "$SRC/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    "$SRC"/src/adapter/*.m "$SRC"/src/private/*.m "$SRC"/src/utility/*.m \
    -o "$BINARY"

cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
echo "$FRAMEWORK"
