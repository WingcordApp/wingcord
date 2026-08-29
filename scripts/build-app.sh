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

# ── Resource bundle ────────────────────────────────────────────────────────
# SwiftPM emits declared resources into a bundle beside the binary and
# `Bundle.module` looks for it inside the app's Resources. Copying it is not
# optional: without it every styled display name silently falls back to the
# system face, which looks like a rendering bug rather than a missing file.
#
# A MISSING bundle fails the build. It is only absent when the target declares
# no resources, and the target does — so its absence means the manifest changed
# and something downstream is about to fail quietly.
BUNDLE="$(dirname "$BIN")/Wingcord_Wingcord.bundle"
if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE is missing — the app would ship without its fonts." >&2
    exit 1
fi
cp -R "$BUNDLE" "$APP/Contents/Resources/"

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

# ── Code signing ───────────────────────────────────────────────────────────
# Signed with entitlements. Unsigned, the app cannot hold the microphone or
# camera permissions it will eventually ask for, and macOS re-prompts for
# network access on every rebuild.
#
# **Signed with an identity that carries a TEAM ID, and that is what keeps the
# account signed in across a rebuild.** There are TWO independent gates on a
# Keychain item and it is easy to fix only the first:
#
#   1. The trusted-application ACL. An ad-hoc signature's designated
#      requirement is a literal `cdhash` of the binary, so a rebuild stops
#      matching. A certificate-backed one names the identifier and the
#      certificate, and survives. Any certificate fixes this half.
#
#   2. The **partition list** — a second gate added in macOS Sierra, stored as
#      its own ACL entry. Its ids are `apple:`, `teamid:<TEAMID>`, or
#      `cdhash:<hash>` for signed code with no team. **A self-signed
#      certificate has no team id**, so it falls back to cdhash, which changes
#      on every build — and the prompt comes back even though the ACL above
#      matches perfectly. Read it with:
#
#        security dump-keychain -a ~/Library/Keychains/login.keychain-db
#
# So the identity has to be Apple-issued. **This does not mean a paid
# membership**: a free Apple ID added in Xcode ▸ Settings ▸ Accounts issues an
# "Apple Development" certificate with a personal team id, and that is enough.
# The team id also survives certificate renewal, where a self-signed
# replacement would not.
#
# A self-signed certificate is still better than ad-hoc — it fixes gate 1 and
# leaves one prompt per build instead of a login screen — so it stays as the
# fallback.
#
# On the first launch after switching, macOS asks once whether Wingcord may
# read the item the previous build stored. Answer **Always Allow**; that adds
# both the requirement and `teamid:` to the item, and neither moves again.
#
# **The lookup deliberately omits `-v`.** A self-signed root is untrusted by
# definition, so `find-identity -v` reports `CSSMERR_TP_NOT_TRUSTED` and filters
# out the exact identity the fallback is for. Trust governs verification, not
# signing.
# **Counted by certificate hash, not by matching lines.** `find-identity` prints
# every identity twice — once under "Matching identities" and again under "Valid
# identities only" — so a naive `grep -c` reports two for a single certificate
# and every lookup looks ambiguous. Resolving to the SHA-1 and signing with that
# also removes any chance of a substring matching the wrong identity.
for CANDIDATE in "${WINGCORD_SIGN_IDENTITY:-}" "Apple Development" "Wingcord Dev"; do
    [ -n "$CANDIDATE" ] || continue
    HASHES=$(security find-identity -p codesigning 2>/dev/null \
        | grep -F "$CANDIDATE" | awk '{ print $2 }' | sort -u)
    COUNT=$(printf '%s' "$HASHES" | grep -c . || true)
    if [ "$COUNT" -eq 1 ]; then
        SIGN_IDENTITY="$HASHES"
        SIGN_NAME="$CANDIDATE"
        break
    elif [ "$COUNT" -gt 1 ]; then
        echo "note: '$CANDIDATE' matches $COUNT certificates; set WINGCORD_SIGN_IDENTITY" >&2
        echo "      to the exact name or SHA-1 to disambiguate." >&2
    fi
done

if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "note: no code-signing identity found; falling back to ad-hoc." >&2
    echo "      the app will ask you to sign in again after every build." >&2
    SIGN_IDENTITY="-"
elif [ "${SIGN_NAME:-}" = "Wingcord Dev" ]; then
    echo "note: signing with a self-signed identity, which has no team id." >&2
    echo "      expect one Keychain prompt per build. See the comment above." >&2
fi

codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Packaging/Wingcord.entitlements" \
    --timestamp=none "$APP" \
    || echo "warning: codesign failed with identity '$SIGN_IDENTITY'." >&2

echo "App: $APP"
