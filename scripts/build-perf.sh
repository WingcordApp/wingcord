#!/bin/bash
# Builds the copy that is recorded: build/perf/Wingcord.app.
#
# The same optimized release build as the stable one, from whatever is in the
# working tree, with two differences and no others:
#
#   - It is signed with `get-task-allow` beside the app's own entitlements, the
#     one flag that lets Instruments, `sample` and `leaks` attach. It adds no
#     code and costs nothing while nothing is attached.
#   - It keeps its symbols, so those tools print names rather than addresses.
#
# Same bundle id and signing identity as the stable build, so the account stays
# signed in — which also means **launching it signs in to the real account**.
# It is built here and never launched from a script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/Packaging/Wingcord.entitlements" "$STAGE/perf.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$STAGE/perf.entitlements"

mkdir -p "$ROOT/build/perf"
WINGCORD_APP="$ROOT/build/perf/Wingcord.app" \
WINGCORD_ENTITLEMENTS="$STAGE/perf.entitlements" \
WINGCORD_KEEP_SYMBOLS=1 \
    "$ROOT/scripts/build-app.sh" release
