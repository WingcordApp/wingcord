#!/bin/bash
# Puts the function names back into a crash report from a shipped build.
#
#   scripts/symbolicate.sh <crash-report.txt> [path/to/Wingcord.dSYM]
#
# A release build is stripped (`scripts/build-app.sh`), so the stack in a
# tester's report is addresses. Two lines of the report say how to read them:
# `image-base`, where the binary was loaded, and its `uuid`, which names the
# dSYM `build-app.sh` kept for that exact build in `build/dSYMs/`. A dSYM from
# any other build gives confident, wrong names — so it is found by id, and an
# explicit path is only for a dSYM kept somewhere else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${1:?usage: scripts/symbolicate.sh <crash-report.txt> [Wingcord.dSYM]}"

IMAGE_LINE="$(grep -m1 '^image-base 0x' "$REPORT" || true)"
if [ -z "$IMAGE_LINE" ]; then
    echo "error: this report has no image-base line, so its addresses cannot be placed." >&2
    echo "       (Reports from builds before 2026-11-10 carry names already.)" >&2
    exit 1
fi
BASE="$(printf '%s' "$IMAGE_LINE" | awk '{ print $2 }')"
UUID="$(printf '%s' "$IMAGE_LINE" | awk '{ print $4 }')"

DSYM="${2:-$ROOT/build/dSYMs/Wingcord-$UUID.dSYM}"
DWARF="$DSYM/Contents/Resources/DWARF/Wingcord"

# **A published build's dSYM is also in the private bucket** (docs/UPDATES.md
# D10), filed by the same id — so a report from a release this Mac has no copy
# of is fetched, unzipped beside the others and kept. Wrangler signs in as Alex;
# `WINGCORD_SYMBOLS_LOCAL=<folder>` reads Wrangler's local R2 there instead,
# which is how the release command's own test puts one.
if [ ! -f "$DWARF" ] && [ -z "${2:-}" ]; then
    ARCHIVE="$(mktemp -d)/Wingcord-$UUID.dSYM.zip"
    if [ -n "${WINGCORD_SYMBOLS_LOCAL:-}" ]; then
        WHERE=(--local --persist-to "$WINGCORD_SYMBOLS_LOCAL")
    else
        WHERE=(--remote)
    fi
    echo "Fetching the dSYM for $UUID from wingcord-symbols…" >&2
    if (cd "$ROOT/ReportsWorker" && npx --no-install wrangler r2 object get \
            "wingcord-symbols/Wingcord-$UUID.dSYM.zip" --file "$ARCHIVE" "${WHERE[@]}") > /dev/null 2>&1 \
        && [ -s "$ARCHIVE" ]; then
        mkdir -p "$ROOT/build/dSYMs"
        ditto -x -k "$ARCHIVE" "$ROOT/build/dSYMs"
    fi
    rm -rf "$(dirname "$ARCHIVE")"
fi

if [ ! -f "$DWARF" ]; then
    echo "error: no dSYM for build $UUID at $DSYM, nor in wingcord-symbols" >&2
    exit 1
fi

# A frame reads `3   Wingcord   0x0000000104a3c1d4 something + 56`. Only the
# app's own frames are looked up: the system's are named already.
while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9]+[[:space:]]+Wingcord[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
        name="$(atos -o "$DWARF" -l "$BASE" "${BASH_REMATCH[1]}" 2>/dev/null || true)"
        printf '%s\n        => %s\n' "$line" "${name:-?}"
    else
        printf '%s\n' "$line"
    fi
done < "$REPORT"
