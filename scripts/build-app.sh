#!/bin/bash
# Builds Wingcord.app.
#
# Release by default. A debug build is not evidence of anything: SwiftUI's own
# machinery and every generic in the app are unoptimised there, so a debug
# profile measures the compiler's output rather than the app's design.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
# Where the app is put, and what it is signed with. The defaults are the stable
# build's; `scripts/build-perf.sh` overrides all three for the copy that is
# recorded, so making that copy can never write over this one.
APP="${WINGCORD_APP:-$ROOT/build/Wingcord.app}"
ENTITLEMENTS="${WINGCORD_ENTITLEMENTS:-$ROOT/Packaging/Wingcord.entitlements}"

cd "$ROOT"
swift build -c "$CONFIG" --product Wingcord

BIN="$(swift build -c "$CONFIG" --product Wingcord --show-bin-path)/Wingcord"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wingcord"

# ── Where the app looks for frameworks ─────────────────────────────────────
# **One place only: its own Contents/Frameworks.** SwiftPM links a binary
# framework (Sparkle) with two more search paths — `@loader_path`, and the
# build folder on this Mac, written out in full. The second spells this Mac's
# home folder, and with it its owner's name, into every copy; `strip` keeps
# load commands, so it would ship. And either is somewhere else a framework
# could be planted for the app to load in Sparkle's place.
otool -l "$APP/Contents/MacOS/Wingcord" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' \
    | while IFS= read -r RPATH; do
        [ "$RPATH" = "@executable_path/../Frameworks" ] && continue
        install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/Wingcord" 2>/dev/null
    done
if ! otool -l "$APP/Contents/MacOS/Wingcord" | grep -q "@executable_path/../Frameworks"; then
    echo "error: the binary has no rpath to Contents/Frameworks (see Package.swift)." >&2
    exit 1
fi
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── What only a release carries ────────────────────────────────────────────
# `scripts/release.sh` builds through this script and passes these; a plain
# build passes none, so it never has a feed and never updates itself
# (docs/UPDATES.md D4) — the stable copy replacing itself with a release signed
# by another certificate would lose its Keychain access and its permissions.
# Written before anything is signed: the Info.plist is part of the seal.
#
#   WINGCORD_FEED_URL          SUFeedURL — the appcast; the updater starts only with one
#   WINGCORD_ED_PUBLIC_KEY     SUPublicEDKey, when it isn't already in Packaging/Info.plist
#   WINGCORD_SHORT_VERSION     CFBundleShortVersionString
#   WINGCORD_BUILD_NUMBER      CFBundleVersion
#   WINGCORD_PRERELEASE        WingcordPrerelease ("Beta 2"); set but empty removes it
#   WINGCORD_BUNDLE_ID         a test copy's own identifier, defaults domain and folders
#   WINGCORD_BUNDLE_NAME       its name in Finder, the Dock and macOS's prompts
#   WINGCORD_KEYCHAIN_SERVICE  its own Keychain service (TokenStore)
#   WINGCORD_ALLOW_LOCAL_HTTP  1 lets a test copy read a feed served from 127.0.0.1
PLIST="$APP/Contents/Info.plist"
plist_set() { # key type value
    /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
[ -n "${WINGCORD_FEED_URL:-}" ] && plist_set SUFeedURL string "$WINGCORD_FEED_URL"
[ -n "${WINGCORD_ED_PUBLIC_KEY:-}" ] && plist_set SUPublicEDKey string "$WINGCORD_ED_PUBLIC_KEY"
[ -n "${WINGCORD_SHORT_VERSION:-}" ] && plist_set CFBundleShortVersionString string "$WINGCORD_SHORT_VERSION"
[ -n "${WINGCORD_BUILD_NUMBER:-}" ] && plist_set CFBundleVersion string "$WINGCORD_BUILD_NUMBER"
if [ -n "${WINGCORD_PRERELEASE+set}" ]; then
    if [ -n "$WINGCORD_PRERELEASE" ]; then
        plist_set WingcordPrerelease string "$WINGCORD_PRERELEASE"
    else
        /usr/libexec/PlistBuddy -c "Delete :WingcordPrerelease" "$PLIST" 2>/dev/null || true
    fi
fi
[ -n "${WINGCORD_BUNDLE_ID:-}" ] && plist_set CFBundleIdentifier string "$WINGCORD_BUNDLE_ID"
if [ -n "${WINGCORD_BUNDLE_NAME:-}" ]; then
    plist_set CFBundleName string "$WINGCORD_BUNDLE_NAME"
    plist_set CFBundleDisplayName string "$WINGCORD_BUNDLE_NAME"
fi
[ -n "${WINGCORD_KEYCHAIN_SERVICE:-}" ] && plist_set WingcordKeychainService string "$WINGCORD_KEYCHAIN_SERVICE"
if [ "${WINGCORD_ALLOW_LOCAL_HTTP:-}" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST" 2>/dev/null || true
    plist_set NSAppTransportSecurity:NSAllowsLocalNetworking bool true
fi

# ── Symbols ────────────────────────────────────────────────────────────────
# The binary SwiftPM links carries the name of every function in it and a map
# back to the object files on this Mac: 84 MB of a 125 MB file (measured
# 2026-11-10), with some 1,400 paths that spell out the folder it was built in.
# None of it is needed to run. The shipped copy is stripped, and the names are
# kept beside it in a dSYM filed under the build's own id — which is what turns
# the addresses in a tester's crash report back into names
# (`scripts/symbolicate.sh`).
#
# **The dSYM first, and the strip only if it was made.** A stripped build with
# no dSYM is a build whose crashes can never be read.
#
# Release only: a debug build is for stepping through, and wants them.
#
# **Not the copy that is recorded** (`WINGCORD_KEEP_SYMBOLS=1`): `sample`,
# `leaks` and Instruments read names straight from the binary, and a profile of
# addresses is one more step between a recording and its answer.
if [ "$CONFIG" = "release" ] && [ -z "${WINGCORD_KEEP_SYMBOLS:-}" ]; then
    DSYM_DIR="$ROOT/build/dSYMs"
    mkdir -p "$DSYM_DIR"
    BUILD_UUID="$(dwarfdump --uuid "$BIN" | awk '{ print $2; exit }')"
    DSYM="$DSYM_DIR/Wingcord-$BUILD_UUID.dSYM"
    if [ -n "$BUILD_UUID" ] && dsymutil "$BIN" -o "$DSYM" 2> "$DSYM_DIR/dsymutil.log" \
        && [ -s "$DSYM/Contents/Resources/DWARF/Wingcord" ]; then
        strip -x "$APP/Contents/MacOS/Wingcord"
        echo "Symbols: $DSYM"
    else
        echo "warning: no dSYM was made (see $DSYM_DIR/dsymutil.log); shipping the binary unstripped." >&2
    fi
fi

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

# ── Acknowledgements ───────────────────────────────────────────────────────
# The licences of what the app is built with travel with it: Apache 2.0 and
# the BSD licences all ask for their notice to go wherever the binary does.
# Plain text, so Help › Acknowledgements opens it on any Mac.
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/Acknowledgements.txt"
# Wingcord's own licence, which Settings › About opens.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licence.txt"

# ── Release notes ──────────────────────────────────────────────────────────
# A release carries its own notes, which Settings › About shows (`release.sh`
# passes WINGCORD_RELEASE_NOTES). A build of the working tree has none.
if [ -n "${WINGCORD_RELEASE_NOTES:-}" ]; then
    cp "$WINGCORD_RELEASE_NOTES" "$APP/Contents/Resources/ReleaseNotes.md"
fi

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
#
# **Vice City until Discord's Grand Theft Auto VI campaign ends** (Alex,
# 2026-11-16: "replace the current Wingcord icon for now until the campaign is
# over"). A build made before 2027-02-20 18:00 UTC, the moment Discord hides the
# campaign from everyone (`DiscordTheme.ViceCity.nitroUntil`), takes
# Packaging/AppIcon-ViceCity.icon; any later build is back on the standard icon
# with nothing to undo. Only the app icon: the wings everywhere else stay as
# they are. WINGCORD_ICON=standard or WINGCORD_ICON=vice-city overrides the date.
ICON_SRC="$ROOT/Packaging/AppIcon.icon"
VICE_CITY_ENDS=1803146400  # 2027-02-20T18:00:00Z
case "${WINGCORD_ICON:-}" in
    vice-city) ICON_SRC="$ROOT/Packaging/AppIcon-ViceCity.icon" ;;
    standard) ;;
    "") [ "$(date -u +%s)" -lt "$VICE_CITY_ENDS" ] && ICON_SRC="$ROOT/Packaging/AppIcon-ViceCity.icon" ;;
    *) echo "error: WINGCORD_ICON is standard or vice-city, not \"$WINGCORD_ICON\"." >&2; exit 1 ;;
esac
echo "Icon: $(basename "$ICON_SRC" .icon)"
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

# ── Now Playing ────────────────────────────────────────────────────────────
# The vendored mediaremote-adapter: the framework /usr/bin/perl loads to read
# what macOS says is playing, and the script that loads it. See
# Packaging/MediaRemoteAdapter/README.md.
ADAPTER="$("$ROOT/scripts/build-mediaremote-adapter.sh")"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$ADAPTER" "$APP/Contents/Frameworks/"
cp "$ROOT/Packaging/MediaRemoteAdapter/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"

# ── Updates ────────────────────────────────────────────────────────────────
# Sparkle is a binary framework SwiftPM puts beside the binary; the app finds it
# in Contents/Frameworks through the rpath Package.swift adds. `ditto`, not
# `cp`: the framework is versioned, and its symlinks and modes must survive.
#
# **Without its XPC services.** They exist for sandboxed apps, which can't run
# Sparkle's installer themselves; Wingcord isn't sandboxed, and Sparkle's own
# documentation says such an app may remove them. Two fewer programs to sign,
# and none shipped that can't be used.
#
# A MISSING framework fails the build, as the fonts do: the app links it, so a
# bundle without it would not even launch.
SPARKLE="$(dirname "$BIN")/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
    echo "error: $SPARKLE is missing — the app links Sparkle and would not launch." >&2
    exit 1
fi
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# ── App Intents ────────────────────────────────────────────────────────────
# The Focus filter and the Shortcuts actions, described for the system. Before
# signing, because the bundle it writes is part of what is signed.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
"$ROOT/scripts/extract-app-intents.sh" "$APP" "$CONFIG" "$BUNDLE_ID"

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
#
# **A name matches exactly, or as "Name: …"** (Apple's identities carry the
# account after a colon), **or the SHA-1 itself** — never as a substring, now
# that release builds are signed "Wingcord" and that would also match
# "Wingcord Dev" (docs/UPDATES.md D1). `WINGCORD_SIGN_KEYCHAIN` names a keychain
# to look in and sign from, instead of the search list: the throwaway
# certificate `release.sh make --test` signs with lives in one of its own.
identities() {
    security find-identity -p codesigning ${WINGCORD_SIGN_KEYCHAIN:+"$WINGCORD_SIGN_KEYCHAIN"} 2>/dev/null \
        | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "([^"]*)".*$/\1	\2/p' | sort -u
}
for CANDIDATE in "${WINGCORD_SIGN_IDENTITY:-}" "Apple Development" "Wingcord Dev"; do
    [ -n "$CANDIDATE" ] || continue
    HASHES=$(identities | awk -F'\t' -v c="$CANDIDATE" \
        '$1 == c || $2 == c || index($2, c ": ") == 1 { print $1 }' | sort -u)
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

sign() { # path, then any extra codesign options
    local target="$1"
    shift
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
        ${WINGCORD_SIGN_KEYCHAIN:+--keychain "$WINGCORD_SIGN_KEYCHAIN"} "$@" "$target"
}

# ── The hardened runtime (docs/UPDATES.md D2) ──────────────────────────────
# On for every release build, self-signed ones included. It is what stops
# another program from starting Wingcord with its own code injected
# (`DYLD_INSERT_LIBRARIES` and the like) and reading the Keychain AS Wingcord,
# whose identity the token's item trusts. A debug build stays without it: it is
# for stepping through. The perf copy keeps it and adds `get-task-allow`, which
# is all Instruments and `sample` need to attach.
#
# Its exceptions are written here rather than in Packaging/, because one of them
# depends on the certificate:
#
# - `cs.disable-library-validation`, **only for an identity with no Apple team
#   id** (the self-signed release one, or ad hoc). Library validation lets a
#   process load only Apple's code and code from its own team, and code with no
#   team has none to share — so without it a self-signed Wingcord could not load
#   its own Sparkle.framework. An Apple-issued identity signs both with the same
#   team, and keeps the check.
RUNTIME=""
SIGN_ENTITLEMENTS="$ICON_STAGE/sign.entitlements"
cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"

# Nested code first, from the inside out: the app's signature seals each
# framework as it stands, and a framework's seals its helpers. Never `--deep`,
# which would re-sign Sparkle's helpers without their own options.
sign "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" \
    || echo "warning: signing MediaRemoteAdapter.framework failed." >&2

TEAM="$(codesign -dv "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p')"
if [ "$CONFIG" = "release" ]; then
    RUNTIME="runtime"
    if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" \
            "$SIGN_ENTITLEMENTS" 2>/dev/null || true
    fi
fi

SPARKLE_IN="$APP/Contents/Frameworks/Sparkle.framework"
for PART in "$SPARKLE_IN/Versions/B/Autoupdate" "$SPARKLE_IN/Versions/B/Updater.app" "$SPARKLE_IN"; do
    sign "$PART" ${RUNTIME:+--options "$RUNTIME"} \
        || { echo "error: signing $PART failed." >&2; exit 1; }
done

sign "$APP" ${RUNTIME:+--options "$RUNTIME"} --entitlements "$SIGN_ENTITLEMENTS" \
    || echo "warning: codesign failed with identity '$SIGN_IDENTITY'." >&2

echo "App: $APP"
