#!/bin/bash
# Writes Metadata.appintents into an assembled Wingcord.app.
#
# Usage: scripts/extract-app-intents.sh APP CONFIG BUNDLE_ID
#   APP        the .app being assembled (before it is signed)
#   CONFIG     debug | release — whichever `swift build` just produced
#   BUNDLE_ID  the identifier the copy is launched under
#
# **What Xcode's "Extract app intents metadata" step does, run by hand.** The
# Focus filter and the Shortcuts actions exist for the system only once this
# bundle is in the app: without it they compile, link and are never offered
# anywhere. `swift build` here runs on Swift Build, which already writes
# everything the processor reads — the `.swiftconstvalues` (per source file in
# debug, one for the module in release) and the linker's dependency info — so
# this is one call. The recipe and the
# traps behind it are docs/CLIPS-PRESENCE.md, Phase 0.2.
#
# A failure here FAILS THE BUILD, like a missing icon: an app whose intents
# silently vanished would read as a Focus filter that does nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
CONFIG="$2"
BUNDLE_ID="$3"

case "$CONFIG" in
    debug) CONFIG_DIR=Debug ;;
    release) CONFIG_DIR=Release ;;
    *) echo "error: unknown configuration '$CONFIG'" >&2; exit 1 ;;
esac

OBJ="$ROOT/.build/out/Intermediates.noindex/Wingcord.build/$CONFIG_DIR/Wingcord-p.build/Objects-normal/arm64"
DEPENDENCY_INFO="$OBJ/Wingcord_dependency_info.dat"
if [ ! -f "$DEPENDENCY_INFO" ]; then
    echo "error: $DEPENDENCY_INFO is missing — the App Intents metadata cannot be extracted." >&2
    echo "       (Swift Build writes it; an older build layout would not.)" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The sources, and the const values that belong to them.
#
# **Two layouts.** A release build compiles the module whole, and Swift Build
# writes ONE file for it, `Wingcord-primary.swiftconstvalues`, rewritten every
# build. A debug build is incremental: one file per source, **matched by name**,
# because a file deleted since the last build leaves its `.swiftconstvalues`
# behind, and an intent described there but missing from the binary is an
# error the processor cannot recover from.
find "$ROOT/Sources/Wingcord" -name '*.swift' | sort > "$STAGE/sources.txt"
: > "$STAGE/constvals.txt"
if [ "$CONFIG" = release ]; then
    WHOLE="$OBJ/Wingcord-primary.swiftconstvalues"
    if [ ! -f "$WHOLE" ]; then
        echo "error: $WHOLE is missing — the App Intents metadata cannot be extracted." >&2
        exit 1
    fi
    echo "$WHOLE" > "$STAGE/constvals.txt"
else
    sed 's|.*/||; s|\.swift$||' "$STAGE/sources.txt" | sort -u > "$STAGE/stems.txt"
    for file in "$OBJ"/*.swiftconstvalues; do
        stem="$(basename "$file" .swiftconstvalues)"
        if grep -qxF "$stem" "$STAGE/stems.txt"; then
            echo "$file" >> "$STAGE/constvals.txt"
        fi
    done
fi

SWIFT="$(xcrun --find swift)"
TOOLCHAIN="${SWIFT%/usr/bin/swift}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ { print $3 }')"

rm -rf "$APP/Contents/Resources/Metadata.appintents"
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Wingcord \
    --sdk-root "$SDK" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target 27.0 \
    --bundle-identifier "$BUNDLE_ID" \
    --output "$APP/Contents/Resources" \
    --target-triple arm64-apple-macos27.0 \
    --binary-file "$APP/Contents/MacOS/Wingcord" \
    --dependency-file "$DEPENDENCY_INFO" \
    --stringsdata-file "$STAGE/ExtractedAppShortcutsMetadata.stringsdata" \
    --source-file-list "$STAGE/sources.txt" \
    --swift-const-vals-list "$STAGE/constvals.txt" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization \
    > "$STAGE/processor.log" 2>&1 \
    || { cat "$STAGE/processor.log" >&2; echo "error: App Intents metadata extraction failed." >&2; exit 1; }

if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    cat "$STAGE/processor.log" >&2
    echo "error: the processor wrote no Metadata.appintents — the Focus filter and Shortcuts would not exist." >&2
    exit 1
fi
